//! The frame dispatch loop and its instruction fast paths.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const jit_loop = @import("../jit_loop.zig");
const bc = @import("../bc.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BinOp = ir.BinOp;
const BlockId = ir.BlockId;
const Func = ir.Func;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;
const Terminator = ir.Terminator;

const exec_call = @import("../exec_call.zig");

const envVarSet = exec_call.envVarSet;

const parent = @import("../eval.zig");
const ev_diag = @import("diag.zig");
const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_inst = @import("inst.zig");
const ev_loop = @import("loop.zig");
const ev_native = @import("native.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");

const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const FlatCallSite = ev_flow.FlatCallSite;
const Frame = ev_frame.Frame;
const LoopTramp = ev_loop.LoopTramp;
const NATIVE_RECURSE_MAX_DEPTH = ev_native.NATIVE_RECURSE_MAX_DEPTH;
const NativeCtx = ev_native.NativeCtx;
const NativeFn = ev_native.NativeFn;
const NativeGlue = ev_native.NativeGlue;
const ParkPoint = ev_flow.ParkPoint;
const PendingFinallyState = ev_snapshot.PendingFinallyState;
const RegMask = ev_frame.RegMask;
const Step = ev_flow.Step;
const TryFrame = ev_snapshot.TryFrame;
const attachStackTrace = ev_diag.attachStackTrace;
const cmgTraceWant = ev_flow.cmgTraceWant;
const coerceIntArgsToLong = ev_enter.coerceIntArgsToLong;
const constMatches = ev_values.constMatches;
const constToValue = ev_values.constToValue;
const currentFrameFunc = ev_state.currentFrameFunc;
const displayThrow = ev_state.displayThrow;
const divTruncI32 = ev_values.divTruncI32;
const divTruncI64 = ev_values.divTruncI64;
const dumpFnIfRequested = ev_enter.dumpFnIfRequested;
const dumpFrameChainForDiagAlways = ev_diag.dumpFrameChainForDiagAlways;
const errResult = ev_flow.errResult;
const execArmBinOp = ev_inst.execArmBinOp;
const execInst = ev_inst.execInst;
const lrTraceOn = ev_flow.lrTraceOn;
const nativeFor = ev_native.nativeFor;
const nativeModuleOk = ev_native.nativeModuleOk;
const nearestFinally = ev_enter.nearestFinally;
const nowMonotonicMs = ev_diag.nowMonotonicMs;
const ok = ev_flow.ok;
const regsAlloc = ev_state.regsAlloc;
const remTruncI32 = ev_values.remTruncI32;
const remTruncI64 = ev_values.remTruncI64;
const spinDumpMaybe = ev_diag.spinDumpMaybe;
const truncChainTo = ev_flow.truncChainTo;
const typeRefName = ev_loop.typeRefName;
const unwindTerminal = ev_enter.unwindTerminal;
const valueTruthy = ev_values.valueTruthy;
const wallCapFire = ev_diag.wallCapFire;

/// `resume_throw`: when a continuation is resumed with
/// `Result.failure(e)` (Kotlin's `resumeWith(failure)` = "resume by
/// throwing at the suspension point"), the exception is routed through
/// this frame's restored try-stack instead of being delivered as the
/// suspending call's value. This makes a cancellation actually preempt
/// a parked `delay` / acquire.
/// `resume_unwind` is the corresponding path for a non-local return raised
/// by a resumed inner frame; it crosses the restored frame's finally stack
/// and is absorbed when this frame carries its target label.
/// `flat_out`: when the frame hits a direct interpreted call the flat driver
/// can run, the executor parks the request there and returns; the returned
/// `EvalResult` is meaningless in that case (the driver checks `flat_out`
/// first).
pub fn runFrameExec(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    cur_in: BlockId,
    resume_idx_in: usize,
    resume_throw_in: ?Value,
    resume_unwind_in: ?EvalError,
    flat_out: *?FlatCallSite,
    park_out: *?ParkPoint,
    host: *H,
) Allocator.Error!EvalResult {
    if (parent.frame_count_on) parent.frame_count_total += 1;
    // KLIO_FN_PROF: attribute samples to the interpreted function running
    // here, restoring the caller's on exit so the histogram is self-time.
    const fn_prof_prev = runtime.prof.current_fn;
    if (runtime.prof.fn_prof_active) runtime.prof.current_fn = frame.func.id.int();
    defer if (runtime.prof.fn_prof_active) {
        runtime.prof.current_fn = fn_prof_prev;
    };
    // Resolved once: the per-instruction gates below would otherwise pay a
    // dynamic thread-local lookup each, which the compiler cannot hoist past
    // the dispatch calls between them.
    //
    // Re-bound to the RUNNING thread first. A frame's `tls` is captured when
    // it is built, but a suspended coroutine resumes on whatever thread the
    // dispatcher hands it, and the state behind this pointer — the register
    // free-list, the receiver chain, the frame chain — is per-thread and
    // unsynchronized. A migrated frame that kept its origin thread's pointer
    // raced that thread's pool (an intermittent `integer overflow` from the
    // free list's length going negative under concurrent snapshot tests).
    //
    // A migrated frame's CHAIN activation also happened against the
    // constructing thread's context: its prev_chain points into that
    // thread's stack, and deactivating here would transplant the foreign
    // pointer into THIS thread's active chain — which then outlives the
    // frame it names, and the next fresh call on this thread merges its
    // enclosing chain from freed memory (the cross-thread yield GPF).
    // Re-home the activation: this frame's chain becomes the running
    // thread's active chain, and its deactivate restores the running
    // thread's own current chain.
    if (frame.tls != &ev_state.evtls) {
        frame.tls = &ev_state.evtls;
        frame.prev_chain = ev_state.evtls.active_chain;
        frame.prev_chain_base = ev_state.evtls.active_chain_base;
        ev_state.evtls.active_chain = &frame.enclosing_this;
        ev_state.evtls.active_chain_base = frame.enclosing_this.items.len;
    }
    const ftls: *EvalTls = frame.tls;
    var cur = cur_in;
    var resume_idx = resume_idx_in;
    var resume_throw = resume_throw_in;
    var resume_unwind = resume_unwind_in;
    // Pending throw/return state lives on `frame`: a finally body may suspend,
    // and the frame snapshot must carry both its continuation point and the
    // control flow that caused the finally to run.
    const func: *const Func = frame.func;
    // Lazy IR: materialise a deferred function's blocks before the dispatch
    // loop reads them. `TailCallFunc` is self-recursive (same func), so `func`
    // stays current for the whole loop.
    if (func.blocks.len == 0 and !frame.module.ensureFuncBody(@constCast(func))) {
        if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
            std.debug.print("[empty-frame] fqn={s} params={d} caller={s}\n", .{
                func.fqn, func.params.len,
                if (currentFrameFunc()) |cf| cf.fqn else "<none>",
            });
            dumpFrameChainForDiagAlways();
        }
        return errResult(.{ .Type = "virtual method target is not executable" });
    }
    dumpFnIfRequested(frame.module, func);
    const jit_on = jit_loop.enabled();
    // Loop-JIT call trampoline wiring (only hosts that can run a callee qualify).
    const tramp_ok = comptime @hasDecl(H, "callFunc");
    var loop_ctx: if (tramp_ok) LoopTramp(H).Ctx else void =
        if (tramp_ok) .{ .host = host, .allocator = allocator, .module = frame.module, .frame = frame } else {};
    const tramp_fn: ?jit_loop.TrampFn = if (comptime tramp_ok) &LoopTramp(H).call else null;
    const tramp_user: ?*anyopaque = if (comptime tramp_ok) @ptrCast(&loop_ctx) else null;
    const member_resolver: ?jit_loop.MemberResolver =
        if (comptime tramp_ok and @hasDecl(H, "resolveMemberFuncId")) &LoopTramp(H).resolveMember else null;
    const virt_resolver: ?jit_loop.VirtResolver =
        if (comptime tramp_ok and @hasDecl(H, "resolveVirtualFuncId")) &LoopTramp(H).resolveVirtual else null;
    // The bytecode tier's per-func stream table, hoisted to one lookup per
    // activation; per block entry it is a plain array index.
    // Fused terminator ops only when the loop JIT is off: the JIT's
    // compile trigger lives at this loop's block entry, and fused edges
    // would starve it.
    // Fusion is per FUNCTION, not per process: only a function the loop JIT has
    // compiled into needs the unfused stream (its deopts resume at instruction
    // indices). Gating on `jit_on` slowed every un-compiled function in the
    // program the moment the JIT was enabled.
    var bc_streams: ?*const bc.FuncStreams = if (bc.enabled()) bc.funcStreams(func, !func.bc_jit_owned, module.consts.items) else null;
    // The C transpiler's native table: a registered function's blocks run
    // as emitted C instead of the stream (one lookup per activation; the
    // table is empty in every non-transpiled process).
    const native_fn: ?NativeFn = if (nativeModuleOk(module)) nativeFor(func.id.int(), func.fqn) else null;
    if (native_fn == null and ev_native.native_any.load(.acquire) and
        func.package.len == 0 and runtime.envOnce("KLIO_NATIVE_TRACE") != null)
    {
        std.debug.print("[native-miss] fn={s} fid={d}\n", .{ func.fqn, func.id.int() });
    }
    // The loop JIT's per-function state, hoisted to one lookup per
    // activation; the per-block-entry probe is then two array loads.
    const jit_fj: ?*jit_loop.FuncJit = if (jit_on) jit_loop.forFunc(func) else null;
    const field_resolver: ?jit_loop.FieldResolver =
        if (comptime tramp_ok and @hasDecl(H, "plainStoredFieldIndex")) &LoopTramp(H).resolveField else null;
    const field_nn_resolver: ?jit_loop.FieldResolver =
        if (comptime tramp_ok and @hasDecl(H, "plainStoredScalarFieldNN")) &LoopTramp(H).resolveFieldNN else null;
    while (true) {
        // Daemon abandonment: a dispatcher pool task still running at the
        // run boundary stops at its next block instead of completing (or
        // looping forever). The unwind bypasses user catch/finally frames
        // deliberately — the task is being torn down, not failing.
        if (runtime.shouldAbandon()) {
            return errResult(.{ .Type = "daemon task abandoned at run boundary" });
        }
        // Spin diagnostic (KLIO_SPIN_TRACE): cheap counter gate, then a
        // wall-clock check inside.
        ftls.spin_check_counter +%= 1;
        if (ftls.spin_check_counter & 0xFFFF == 0) {
            spinDumpMaybe();
            const wall_dl = parent.test_wall_deadline_ms.load(.monotonic);
            if (wall_dl != 0 and nowMonotonicMs() > wall_dl) {
                // A caught hang should say WHERE it looped, not just that it did.
                // Dump the live frame chain (innermost first, with file:line) so
                // the culprit function/recursion is named at the abort point.
                return try wallCapFire(allocator);
            }
        }
        // GC safe point: at an opcode boundary all live Values are in registered
        // frames/globals (no host op mid-flight), so the collector can run.
        // A resumed throw/return payload is transiently held by this native
        // activation until it is moved into a frame register or pending-finally
        // state. Route it before collecting so the payload remains rooted.
        if (runtime.gc.gc_enabled and runtime.gc.pending() and
            resume_throw == null and resume_unwind == null)
        {
            runtime.gc.safePoint();
        }
        // Loop JIT (KLIO_JIT): a hot loop header compiles to native code; on
        // success the loop runs natively and we resume at its exit block with
        // registers reboxed. Only at a fresh, non-resumed block entry.
        if (jit_fj != null and resume_idx == 0 and resume_throw == null and resume_unwind == null) {
            // Compiled code reads and writes the raw register slice with no
            // mask maintenance; hand it a fully-defined file. One fill per
            // frame at most — the mask saturates.
            frame.materializeRegs();
            if (jit_loop.maybeRunHotPre(jit_fj.?, frame.module, func, &frame.regs, allocator, cur, tramp_fn, tramp_user, member_resolver, virt_resolver, field_resolver, field_nn_resolver)) |res| {
                if (res.inst == jit_loop.THROW_INST) {
                    // A trampolined call left an error pending: re-raise it. A
                    // throw resumes through the try-stack at the call's block;
                    // any other error propagates straight out of the frame.
                    if (comptime tramp_ok) {
                        const e = loop_ctx.pending.?;
                        loop_ctx.pending = null;
                        switch (e) {
                            .Throw => |exc| {
                                resume_throw = exc;
                                cur = res.block;
                                continue;
                            },
                            // A trampolined callee SUSPENDED mid-loop: park
                            // this frame at the call site exactly as the
                            // interpreted path would — the native exit has
                            // already reboxed the loop registers, so the
                            // snapshot resumes the loop right after the
                            // call with the resume value in its dst.
                            // Propagating it as a plain error dropped the
                            // loop frame from the continuation (a JITted
                            // `for` sending into a channel lost every
                            // element after the tier-up).
                            .Suspended => {
                                park_out.* = .{
                                    .block = res.block,
                                    .inst_idx = @as(usize, loop_ctx.pending_suspend_inst) + 1,
                                    .resume_reg = loop_ctx.pending_suspend_dst,
                                };
                                return errResult(e);
                            },
                            else => return errResult(e),
                        }
                    } else unreachable;
                }
                if (res.inst == jit_loop.DEOPT_INST) {
                    // A field read deopted: re-execute it in the interpreter.
                    if (comptime tramp_ok) {
                        cur = res.block;
                        resume_idx = loop_ctx.pending_deopt_inst;
                        continue;
                    } else unreachable;
                }
                cur = res.block;
                resume_idx = res.inst;
                continue;
            }
            // Whole-function JIT: at the function entry, run the entire body
            // natively (scalar functions; recursion stays native through the call
            // trampoline). A `Return` yields the value; a callee throw / div-by-
            // zero deopt resumes interpretation with registers reboxed.
            if (comptime tramp_ok) {
                // FRESH entry only: a deopt/throw resume (or a loop whose
                // back-edge targets the entry block) arrives here with
                // resume state set, and re-running the whole body from
                // scratch would double its effects and drop the pending
                // throw.
                if (cur.int() == func.entry.int() and resume_idx == 0 and
                    resume_throw == null and resume_unwind == null)
                {
                    if (jit_loop.maybeRunHotFunc(frame.module, func, &frame.regs, frame.params.items, frame.captures.items, allocator, tramp_fn, tramp_user, member_resolver, virt_resolver, field_resolver, field_nn_resolver)) |fo| {
                        if (fo.code.inst == jit_loop.RETURN_INST) {
                            return ok(fo.value);
                        }
                        if (fo.code.inst == jit_loop.THROW_INST) {
                            const e = loop_ctx.pending.?;
                            loop_ctx.pending = null;
                            switch (e) {
                                .Throw => |exc| {
                                    resume_throw = exc;
                                    cur = fo.code.block;
                                    continue;
                                },
                                else => return errResult(e),
                            }
                        }
                        // Deopt: a handler-issued one carries the sentinel and
                        // records the resume instruction on the context; a
                        // native one (div by zero) encodes it directly.
                        cur = fo.code.block;
                        resume_idx = if (fo.code.inst == jit_loop.DEOPT_INST) loop_ctx.pending_deopt_inst else fo.code.inst;
                        continue;
                    }
                }
            }
        }
        const block = &func.blocks[cur.int()];
        // Normal flow into a catch-only try's join: pop the body's
        // entry (a throw path already consumed it — the scan then finds
        // nothing). See `Block.catch_done_for`.
        if (block.catch_done_for) |body| {
            if (rpositionByBody(try_stack.items, body)) |p| {
                _ = try_stack.orderedRemove(p);
            }
        }
        // Control entering a finally body disarms its try-frame: once the
        // finally has begun, the region's catches and the finally itself must
        // not capture anything raised inside it (a throw or return in the
        // finally would otherwise re-enter and run the block twice). The
        // exception/return entry paths pop the frame before jumping here, so
        // a frame still armed at this point is the normal-completion entry.
        // Keyed on block entry (not the entry block's Goto exit) because a
        // multi-block finally — a Branch terminator, a suspension — leaves
        // the exit-side pop unreached while later blocks run.
        if (resume_idx == 0) {
            if (rpositionByFinallyEntry(try_stack.items, cur)) |p| {
                _ = try_stack.orderedRemove(p);
            }
        }
        const insts: []const Inst = block.insts;
        const term = block.terminator;
        const finally = block.finally;
        const finally_done = block.finally_done;
        const has_catches = block.catches.len != 0;
        if (resume_idx == 0 and (has_catches or finally != null or block.lr_absorb != null)) {
            try try_stack.append(allocator, .{
                .body = cur,
                .chain_len = frame.enclosing_this.items.len,
                .catches = block.catches,
                .finally_entry = finally,
                .finally_done = finally_done,
                .lr_absorb = block.lr_absorb,
            });
        }
        var thrown: ?Value = null;
        var unwound: ?EvalError = null;
        var start_idx = resume_idx;
        resume_idx = 0;
        if (resume_throw) |exc| {
            resume_throw = null;
            // Resumed with an exception: skip the remaining instructions
            // of the suspending block and route the throw through the
            // restored try-stack exactly as a mid-block throw would.
            thrown = exc;
            start_idx = insts.len;
        } else if (resume_unwind) |e| {
            resume_unwind = null;
            // Resume the caller as though its suspending call instruction
            // raised this non-local return. Catch clauses do not intercept it;
            // the ordinary unwind path below runs finally blocks and checks
            // whether this frame owns the label.
            unwound = e;
            start_idx = insts.len;
        }
        var idx: usize = 0;
        var ret_v: EvalResult = ok(.Unit);
        var ran_bc = false;
        // Fused-flow exits back to the frame loop: run this block from its
        // top / run only this block's terminator.
        var bc_goto: ?BlockId = null;
        var bc_term: ?BlockId = null;
        // The bytecode tier: the dense per-block stream replaces this
        // instruction loop's union dispatch; every non-simple op escapes
        // to `execInst`, and all control flow funnels through the same
        // `afterStep` the walker uses. In a FUSED function (no try
        // machinery, JIT off) the streams carry jump/br/ret terminator
        // ops, so straight-line control flow never surfaces to the frame
        // loop's per-block bookkeeping; each taken edge runs the same
        // abandon/spin/GC guards the frame loop runs per block entry.
        // A registered native function runs its emitted C for this block
        // (and, fused, every block it flows into) with the exact exits the
        // stream loop has. Fresh block entries only: a resume mid-block
        // (start_idx != 0) or one carrying a throw/unwind goes through the
        // stream's idx_pc machinery — the coordinates are shared, so a
        // parked transpiled function resumes exactly like an interpreted
        // one.
        var native_ran = false;
        if (native_fn) |nf| native_run: {
            if (thrown != null or unwound != null) break :native_run;
            if (start_idx != 0) break :native_run;
            if (frame.regs.items.len < func.n_locals) break :native_run;
            // The emitted C's hot view reads and writes raw register bytes
            // with no mask maintenance; hand it a fully-defined file.
            frame.materializeRegs();
            // Every native level stacks kf + glue + serve frames for ANY
            // call form (member escapes included, not just the quickened
            // static op), far heavier than an interpreter frame — past
            // this depth a deep chain runs the stream instead, so the C
            // stack stays bounded and the eval-depth cap keeps raising
            // its catchable StackOverflow first.
            if (ev_state.evtls.eval_depth > NATIVE_RECURSE_MAX_DEPTH) break :native_run;
            var nctx: NativeCtx = .{
                .frame = frame,
                .allocator = allocator,
                .ftls = ftls,
                .host = @ptrCast(host),
                .flat_out = flat_out,
                .park_out = park_out,
                .thrown = &thrown,
                .unwound = &unwound,
                .ret_v = &ret_v,
                .arm_bin = &NativeGlue(H).armBin,
                .escape = &NativeGlue(H).escape,
                .call = &NativeGlue(H).call,
                .field_route = &NativeGlue(H).fieldRoute,
                .field_write_route = &NativeGlue(H).fieldWriteRoute,
            };
            nf(@ptrCast(&nctx), cur.int());
            if (runtime.envOnce("KLIO_NATIVE_TRACE") != null) {
                std.debug.print("[native] fn={s} entry=b{d} outcome={s}\n", .{
                    func.fqn, cur.int(), @tagName(nctx.outcome),
                });
            }
            switch (nctx.outcome) {
                .none => break :native_run,
                .term => bc_term = @enumFromInt(nctx.out_block),
                .goto => bc_goto = @enumFromInt(nctx.out_block),
                .brk => cur = @enumFromInt(nctx.out_block),
                .ret => return ret_v,
                .oom => return error.OutOfMemory,
            }
            ran_bc = true;
            native_ran = true;
        }
        if (!native_ran and bc_streams != null) bc_run: {
            const bs = bc_streams.?;
            // A resume that arrived carrying a throw/unwind skips the
            // instruction surface entirely — for an EMPTY block its
            // `start_idx = insts.len` is 0, indistinguishable from a
            // fresh entry, and a fused terminator op must not run
            // before the routing below.
            if (thrown != null or unwound != null) break :bc_run;
            // The one bounds check the stream ops rely on: build-time
            // validation proved every operand `< n_locals`.
            if (frame.regs.items.len < func.n_locals) break :bc_run;
            var bcur = cur;
            var binsts = insts;
            const stream0 = bs.streams[bcur.int()] orelse break :bc_run;
            ran_bc = true;
            var code = stream0.code;
            var pc: usize = if (start_idx == 0)
                0
            else if (start_idx >= binsts.len)
                code.len
            else
                stream0.idx_pc[start_idx];
            bc_loop: while (pc < code.len) {
                const op: bc.Op = @enumFromInt(code[pc]);
                switch (op) {
                    .const_load => {
                        const v = try constToValue(allocator, &frame.module.consts.items[code[pc + 2]]);
                        writeFastU(frame, @enumFromInt(code[pc + 1]), v, allocator);
                        pc += 3;
                    },
                    .const_int => {
                        const v: Value = .{ .Int = @bitCast(code[pc + 2]) };
                        writeFastU(frame, @enumFromInt(code[pc + 1]), v, allocator);
                        pc += 3;
                    },
                    .move => {
                        const v = frame.regs.items.ptr[code[pc + 2]];
                        v.retain();
                        writeFastU(frame, @enumFromInt(code[pc + 1]), v, allocator);
                        pc += 3;
                    },
                    .load_param => {
                        const pidx: usize = code[pc + 2];
                        const v = if (pidx < frame.params.items.len) frame.params.items[pidx] else Value.Unit;
                        v.retain();
                        writeFastU(frame, @enumFromInt(code[pc + 1]), v, allocator);
                        pc += 3;
                    },
                    .cell_get => {
                        const v = switch (frame.regs.items.ptr[code[pc + 2]]) {
                            .Cell => |c| vblk: {
                                const g = c.borrow();
                                defer g.deinit();
                                break :vblk g.get().*;
                            },
                            else => |other| other,
                        };
                        v.retain();
                        writeFastU(frame, @enumFromInt(code[pc + 1]), v, allocator);
                        pc += 3;
                    },
                    .trace => {
                        frame.cur_span = .{
                            .file = @enumFromInt(code[pc + 1]),
                            .start = code[pc + 2],
                            .end = code[pc + 3],
                        };
                        pc += 4;
                    },
                    .bin => {
                        // Same-tag scalar operands take an inline path with
                        // the exact `applyBinop` semantics (wrap arithmetic,
                        // truncated div/rem, numeric compare); anything else
                        // — including a zero divisor, whose exception the
                        // generic arm constructs — falls through. The
                        // operands ride in the stream, so the fast path
                        // never loads the Inst union.
                        if (binFast(
                            frame,
                            @enumFromInt(code[pc + 2]),
                            @enumFromInt(code[pc + 3]),
                            @enumFromInt(code[pc + 4]),
                            @enumFromInt(code[pc + 5]),
                            allocator,
                        )) {
                            pc += 6;
                            continue :bc_loop;
                        }
                        idx = code[pc + 1];
                        const inst = &binsts[idx];
                        const r = try execArmBinOp(H, allocator, frame, inst.BinOp, host);
                        switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                            .cont => pc += 6,
                            .brk => break :bc_loop,
                            .ret => return ret_v,
                        }
                    },
                    .escape => {
                        idx = code[pc + 1];
                        const inst = &binsts[idx];
                        const r = try execInst(H, allocator, frame, inst, host);
                        switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                            .cont => pc += 2,
                            .brk => break :bc_loop,
                            .ret => return ret_v,
                        }
                    },
                    .jump, .br => {
                        var target: u32 = undefined;
                        if (op == .jump) {
                            target = code[pc + 1];
                        } else {
                            const cv = frame.regs.items.ptr[code[pc + 1]];
                            if (cv != .Bool) {
                                // Cell-carried or coercing condition: the
                                // frame loop's Branch runs `valueTruthy`.
                                bc_term = bcur;
                                break :bc_loop;
                            }
                            target = if (cv.Bool) code[pc + 2] else code[pc + 3];
                        }
                        if (fusedEdgeGuard(allocator, ftls)) |er| {
                            cur = bcur;
                            return er;
                        }
                        const nb: BlockId = @enumFromInt(target);
                        if (jit_fj) |fj| {
                            // A back edge the stream would follow itself: the
                            // frame loop's JIT probe never sees it, so count it
                            // here and give the block back once it is hot.
                            if (nb.int() <= bcur.int() and jit_loop.streamBackEdge(fj, nb.int())) {
                                if (bs.fused) bc_streams = bc.funcStreams(func, false, module.consts.items);
                                cur = bcur;
                                bc_goto = nb;
                                break :bc_loop;
                            }
                        }
                        if (bs.streams[nb.int()]) |ns| {
                            bcur = nb;
                            binsts = frame.func.blocks[nb.int()].insts;
                            code = ns.code;
                            pc = 0;
                        } else {
                            bc_goto = nb;
                            break :bc_loop;
                        }
                    },
                    .cmp_br => {
                        // The block's last BinOp fused with its Branch: the
                        // scalar compare computes inline, still writes dst
                        // (register state matches the unfused form), and
                        // branches without another fetch. Non-scalar
                        // operands run the generic arm, then branch on dst.
                        var taken: ?bool = null;
                        {
                            const regs = frame.regs.items.ptr;
                            const di = code[pc + 3];
                            if (scalarBin(@enumFromInt(code[pc + 2]), regs[code[pc + 4]], regs[code[pc + 5]])) |out| {
                                if (out == .Bool) {
                                    const old = regs[di];
                                    regs[di] = out;
                                    frame.wmask.set(di);
                                    if (runtime.reclaimEnabled()) old.release(allocator);
                                    taken = out.Bool;
                                }
                            }
                        }
                        if (taken == null) {
                            idx = code[pc + 1];
                            const inst = &binsts[idx];
                            const r = try execArmBinOp(H, allocator, frame, inst.BinOp, host);
                            switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                .cont => {},
                                .brk => break :bc_loop,
                                .ret => return ret_v,
                            }
                            const cv = frame.read(@enumFromInt(code[pc + 3]));
                            if (cv != .Bool) {
                                bc_term = bcur;
                                break :bc_loop;
                            }
                            taken = cv.Bool;
                        }
                        if (fusedEdgeGuard(allocator, ftls)) |er| {
                            cur = bcur;
                            return er;
                        }
                        const nb: BlockId = @enumFromInt(if (taken.?) code[pc + 6] else code[pc + 7]);
                        if (jit_fj) |fj| {
                            // A back edge the stream would follow itself: the
                            // frame loop's JIT probe never sees it, so count it
                            // here and give the block back once it is hot.
                            if (nb.int() <= bcur.int() and jit_loop.streamBackEdge(fj, nb.int())) {
                                if (bs.fused) bc_streams = bc.funcStreams(func, false, module.consts.items);
                                cur = bcur;
                                bc_goto = nb;
                                break :bc_loop;
                            }
                        }
                        if (bs.streams[nb.int()]) |ns| {
                            bcur = nb;
                            binsts = frame.func.blocks[nb.int()].insts;
                            code = ns.code;
                            pc = 0;
                        } else {
                            bc_goto = nb;
                            break :bc_loop;
                        }
                    },
                    .ret => {
                        const v: Value = if (code[pc + 1] != 0)
                            frame.regs.items.ptr[code[pc + 2]]
                        else
                            .Unit;
                        v.retain();
                        return ok(v);
                    },
                    .term_exit => {
                        bc_term = bcur;
                        break :bc_loop;
                    },
                }
            }
            // Fused flow may have advanced blocks; the walker fallback and
            // the mid-block throw/unwind routing below key on `cur`.
            cur = bcur;
        }
        if (bc_goto) |nb| {
            cur = nb;
            continue;
        }
        if (bc_term) |nb| {
            // Re-enter the frame loop to run ONLY this block's real
            // terminator: the sentinel skips the instruction loop and the
            // stream (including its fused terminator ops — an empty block
            // entered at index 0 would otherwise replay them).
            cur = nb;
            resume_idx = std.math.maxInt(usize);
            continue;
        }
        if (!ran_bc) {
            while (idx < insts.len) : (idx += 1) {
                if (idx < start_idx) continue;
                const inst = &insts[idx];
                const r = try execInst(H, allocator, frame, inst, host);
                switch (try afterStep(allocator, frame, r, inst, idx, cur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                    .cont => {},
                    .brk => break,
                    .ret => return ret_v,
                }
            }
        }
        if (unwound) |e| {
            // Mid-block non-local return -- route through the armed finally
            // blocks only (never a catch), then keep unwinding. A splice
            // region's labeled-return absorption catches a `LabeledReturn`
            // whose label it owns: control resumes at the region's join with
            // the value delivered, exactly the exit the label meant.
            frame.pending_finally.release(allocator);
            var routed = false;
            while (try_stack.pop()) |tf| {
                if (e == .LabeledReturn) if (tf.lr_absorb) |ab| {
                    if (std.mem.eql(u8, ab.label, e.LabeledReturn.label)) {
                        try frame.write(ab.value_reg, e.LabeledReturn.value);
                        cur = ab.handler;
                        routed = true;
                        break;
                    }
                };
                if (tf.finally_entry) |fin| {
                    if (std.meta.eql(fin, cur)) continue;
                    const key = tf.finally_done orelse fin;
                    frame.pending_finally.unwind = .{ .key = key, .err = e, .depth = try_stack.items.len };
                    cur = fin;
                    routed = true;
                    break;
                }
            }
            if (!routed) return unwindTerminal(frame, e);
            continue;
        }
        if (thrown) |exc| {
            // Mid-block throw — same try-stack walk as Terminator.Throw.
            const pending_depth = frame.pending_finally.tryDepth();
            var routed = false;
            while (try_stack.pop()) |tf| {
                // A throw raised inside this frame's own finally body must not
                // route back into that finally, nor into the frame's catches:
                // control already left the try region when the finally began.
                // The frame is still armed here only on the normal-completion
                // entry (the symmetric pop runs when the entry block exits).
                if (tf.finally_entry) |fin0| {
                    if (std.meta.eql(fin0, cur)) continue;
                }
                if (findCatch(H, host, &exc, tf.catches)) |h| {
                    // A catch belonging to a try nested inside the active
                    // finally handles the new throw without replacing the
                    // exception / return that caused the finally to run.
                    // Once the scan crosses the saved stack depth, the throw
                    // is escaping that finally and Kotlin replaces the prior
                    // control flow with it.
                    if (pending_depth) |depth| {
                        if (try_stack.items.len < depth) frame.pending_finally.release(allocator);
                    }
                    truncChainTo(frame, tf.chain_len);
                    try frame.write(h.exception_reg, exc);
                    cur = h.handler;
                    routed = true;
                    break;
                } else if (tf.finally_entry) |fin| {
                    // An uncaught throw entering a nested finally will escape
                    // its surrounding finally (or itself be replaced there),
                    // so it supersedes the already-pending control flow.
                    frame.pending_finally.release(allocator);
                    const key = tf.finally_done orelse fin;
                    truncChainTo(frame, tf.chain_len);
                    frame.pending_finally.rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                    cur = fin;
                    routed = true;
                    break;
                }
            }
            if (!routed) {
                frame.pending_finally.release(allocator);
                return errResult(.{ .Throw = exc });
            }
            continue;
        }
        // Symmetric try-stack pop on normal flow through finally.
        if (term == .Goto and frame.pending_finally.rethrow == null and frame.pending_finally.return_value == null and frame.pending_finally.unwind == null) {
            const done_for = frame.block(cur).finally_done_for;
            const pos: ?usize = if (done_for) |body|
                rpositionByBody(try_stack.items, body)
            else
                rpositionByFinallyEntry(try_stack.items, cur);
            if (pos) |p| {
                _ = try_stack.orderedRemove(p);
            }
        }
        // An inline `return` that replayed its enclosing finallys inline and
        // is jumping to its join bypasses the finally sentinel, so pop the
        // try-region frames it just unwound (`Block.pop_on_exit`) here — else
        // they linger and a later plain return re-enters the finally.
        if (term == .Goto) {
            for (block.pop_on_exit) |body| {
                if (rpositionByBody(try_stack.items, body)) |p| {
                    _ = try_stack.orderedRemove(p);
                }
            }
        }
        // Finally exit with a pending return: replay the return through
        // any outer finally, otherwise complete it. The key pinned in
        // `pending_finally.return_value` is the *done sentinel* — the synthesized exit
        // block of the user finally body, so an `if`/`when` inside the
        // finally still resolves here once its join reaches the sentinel.
        if (frame.pending_finally.return_value) |pr| {
            if (std.meta.eql(pr.key, cur) and term == .Goto) {
                const v = pr.val;
                frame.pending_finally.return_value = null;
                var chosen: ?struct { i: usize, jump: BlockId, key: BlockId } = null;
                var i: usize = try_stack.items.len;
                while (i > 0) {
                    i -= 1;
                    if (try_stack.items[i].finally_entry) |fin2| {
                        const key = try_stack.items[i].finally_done orelse fin2;
                        chosen = .{ .i = i, .jump = fin2, .key = key };
                        break;
                    }
                }
                if (chosen) |c| {
                    try_stack.shrinkRetainingCapacity(c.i);
                    frame.pending_finally.return_value = .{ .key = c.key, .val = v, .depth = try_stack.items.len };
                    cur = c.jump;
                    continue;
                }
                return ok(v);
            }
            if (std.meta.eql(pr.key, cur) and isReturnLike(term)) {
                pr.val.release(allocator);
                frame.pending_finally.return_value = null;
            }
        }
        // Finally re-throw: if we entered the current block as a finally
        // on the uncaught-throw path, and the block exits via a plain
        // Goto (no `return` / `throw` swallowed the pending exception),
        // re-raise the saved exception through the enclosing try-stack
        // just like a fresh throw.
        if (frame.pending_finally.rethrow) |pr| {
            if (std.meta.eql(pr.key, cur) and term == .Goto) {
                const exc = pr.exc;
                frame.pending_finally.rethrow = null;
                // Drop any try-frames the finally body pushed (and did not pop)
                // so they cannot intercept the re-raised exception.
                if (try_stack.items.len > pr.depth) try_stack.shrinkRetainingCapacity(pr.depth);
                var routed = false;
                while (try_stack.pop()) |tf| {
                    if (findCatch(H, host, &exc, tf.catches)) |h| {
                        truncChainTo(frame, tf.chain_len);
                    try frame.write(h.exception_reg, exc);
                        cur = h.handler;
                        routed = true;
                        break;
                    } else if (tf.finally_entry) |fin2| {
                        const key = tf.finally_done orelse fin2;
                        truncChainTo(frame, tf.chain_len);
                    frame.pending_finally.rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                        cur = fin2;
                        routed = true;
                        break;
                    }
                }
                if (!routed) {
                    return errResult(.{ .Throw = exc });
                }
                continue;
            }
            // A `return` / `throw` inside finally clears the pending
            // re-throw (Kotlin: finally's exit replaces the original).
            if (std.meta.eql(pr.key, cur) and isReturnLike(term)) {
                pr.exc.release(allocator);
                frame.pending_finally.rethrow = null;
            }
        }
        // Finally exit with a pending non-local return: replay it through any
        // outer finally, otherwise resume the unwind out of this frame.
        if (frame.pending_finally.unwind) |pu| {
            if (std.meta.eql(pu.key, cur) and term == .Goto) {
                const e = pu.err;
                frame.pending_finally.unwind = null;
                if (try_stack.items.len > pu.depth) try_stack.shrinkRetainingCapacity(pu.depth);
                var routed = false;
                while (try_stack.pop()) |tf| {
                    if (e == .LabeledReturn) if (tf.lr_absorb) |ab| {
                        if (std.mem.eql(u8, ab.label, e.LabeledReturn.label)) {
                            try frame.write(ab.value_reg, e.LabeledReturn.value);
                            cur = ab.handler;
                            routed = true;
                            break;
                        }
                    };
                    if (tf.finally_entry) |fin2| {
                        const key = tf.finally_done orelse fin2;
                        frame.pending_finally.unwind = .{ .key = key, .err = e, .depth = try_stack.items.len };
                        cur = fin2;
                        routed = true;
                        break;
                    }
                }
                if (!routed) return unwindTerminal(frame, e);
                continue;
            }
            // A `return` / `throw` inside the finally replaces the pending
            // non-local return.
            if (std.meta.eql(pu.key, cur) and isReturnLike(term)) {
                if (PendingFinallyState.payloadOfError(pu.err)) |v| v.release(allocator);
                frame.pending_finally.unwind = null;
            }
        }
        // A return/throw written inside a finally replaces the control flow
        // that entered it, even when the finally spans several IR blocks and
        // the exit is not its synthesized done sentinel.
        if (replacesPendingBeforeRouting(term)) frame.pending_finally.release(allocator);
        switch (term) {
            .Goto => |next| cur = next,
            .Branch => |br| {
                const v = frame.read(br.cond);
                switch (try valueTruthy(allocator, &v)) {
                    .ok => |b| cur = if (b) br.t else br.f,
                    .err => |e| return errResult(e),
                }
            },
            .Return => |maybe_r| {
                const v = if (maybe_r) |r| frame.read(r) else Value.Unit;
                // The value escapes this frame; retain so frame teardown does
                // not free it from under the caller.
                v.retain();
                // Walk the try-stack for the nearest finally; route the
                // return through it.
                var chosen: ?struct { i: usize, jump: BlockId, key: BlockId } = null;
                var i: usize = try_stack.items.len;
                while (i > 0) {
                    i -= 1;
                    if (try_stack.items[i].finally_entry) |fin| {
                        // A return from inside this frame's own finally body
                        // exits through OUTER finallys only; re-entering its
                        // own finally would run the block twice.
                        if (std.meta.eql(fin, cur)) continue;
                        const key = try_stack.items[i].finally_done orelse fin;
                        chosen = .{ .i = i, .jump = fin, .key = key };
                        break;
                    }
                }
                if (chosen) |c| {
                    try_stack.shrinkRetainingCapacity(c.i);
                    frame.pending_finally.return_value = .{ .key = c.key, .val = v, .depth = try_stack.items.len };
                    cur = c.jump;
                    continue;
                }
                return ok(v);
            },
            .NonLocalReturn => |maybe_r| {
                const v = if (maybe_r) |r| frame.read(r) else Value.Unit;
                v.retain();
                const e = EvalError{ .NonLocalReturn = v };
                if (nearestFinally(try_stack, cur)) |c| {
                    frame.pending_finally.unwind = .{ .key = c.key, .err = e, .depth = try_stack.items.len };
                    cur = c.jump;
                    continue;
                }
                return unwindTerminal(frame, e);
            },
            .LabeledReturn => |lr| {
                if (lrTraceOn()) {
                    if (frame.cur_span) |sp| std.debug.print("[lr-raise] label={s} span={d}:{d} in_fn={s}\n", .{ lr.label, sp.file.int(), sp.start, frame.func.name });
                    dumpFrameChainForDiagAlways();
                }
                const v = if (lr.value) |r| frame.read(r) else Value.Unit;
                v.retain();
                const e = EvalError{ .LabeledReturn = .{ .label = lr.label, .value = v } };
                // Innermost-first: a splice region's absorption for this
                // label ends the unwind at its join; armed finallys inside
                // it still run first (they sit deeper on the stack).
                var routed = false;
                while (try_stack.pop()) |tf| {
                    if (tf.lr_absorb) |ab| {
                        if (std.mem.eql(u8, ab.label, lr.label)) {
                            try frame.write(ab.value_reg, v);
                            cur = ab.handler;
                            routed = true;
                            break;
                        }
                        continue;
                    }
                    if (tf.finally_entry) |fin| {
                        if (std.meta.eql(fin, cur)) continue;
                        const key = tf.finally_done orelse fin;
                        frame.pending_finally.unwind = .{ .key = key, .err = e, .depth = try_stack.items.len };
                        cur = fin;
                        routed = true;
                        break;
                    }
                }
                if (!routed) return unwindTerminal(frame, e);
                continue;
            },
            .Throw => |r| {
                var exc = frame.read(r);
                exc.retain();
                // Capture the call stack here, in the throwing frame, before it
                // unwinds (`fillInStackTrace`): the instruction-loop seam only
                // sees the value once it has already surfaced into the caller,
                // by which point this frame is gone. Attach-once, so a re-throw
                // keeps the original trace.
                try attachStackTrace(allocator, &exc);
                if (envVarSet("KLIO_THROW_TRACE")) {
                    const s = displayThrow(allocator, &exc) catch "";
                    std.debug.print("[throw-trace] from fn {s} (fqn={s}): {s}\n", .{ frame.func.name, frame.func.fqn, s });
                    if (envVarSet("KLIO_THROW_STACK")) dumpFrameChainForDiagAlways();
                }
                // Walk the try stack for a matching handler.
                const pending_depth = frame.pending_finally.tryDepth();
                var routed = false;
                while (try_stack.pop()) |tf| {
                    // Same own-finally guard as the mid-block walk: a throw
                    // from inside this frame's finally body skips the frame.
                    if (tf.finally_entry) |fin0| {
                        if (std.meta.eql(fin0, cur)) continue;
                    }
                    if (findCatch(H, host, &exc, tf.catches)) |h| {
                        if (pending_depth) |depth| {
                            if (try_stack.items.len < depth) frame.pending_finally.release(allocator);
                        }
                        truncChainTo(frame, tf.chain_len);
                    try frame.write(h.exception_reg, exc);
                        cur = h.handler;
                        routed = true;
                        break;
                    } else if (tf.finally_entry) |fin| {
                        frame.pending_finally.release(allocator);
                        const key = tf.finally_done orelse fin;
                        truncChainTo(frame, tf.chain_len);
                    frame.pending_finally.rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                        cur = fin;
                        routed = true;
                        break;
                    }
                }
                if (!routed) {
                    frame.pending_finally.release(allocator);
                    return errResult(.{ .Throw = exc });
                }
            },
            .Unreachable => {
                return errResult(.{ .Type = "reached Terminator.Unreachable" });
            },
            .TailJump => |tj| {
                var new_params: std.ArrayList(Value) = .empty;
                var k: u8 = 0;
                while (k < tj.n_args) : (k += 1) {
                    try new_params.append(allocator, frame.read(Reg.from(tj.args.int() + @as(u32, k))));
                }
                coerceIntArgsToLong(frame.func, new_params.items);
                frame.params.deinit(allocator);
                frame.params = new_params;
                const n = frame.regs.items.len;
                frame.regs.clearRetainingCapacity();
                if (!runtime.reclaimEnabled() and frame.func.frameNoFill()) {
                    frame.regs.items.len = n;
                    frame.wmask = RegMask.none;
                } else {
                    try frame.regs.appendNTimes(regsAlloc(allocator), .Unit, n);
                    frame.wmask.setAll();
                }
                try_stack.clearRetainingCapacity();
                cur = frame.func.entry;
            },
            .TailCallFunc => |tc| {
                var new_params: std.ArrayList(Value) = .empty;
                var k: u8 = 0;
                while (k < tc.n_args) : (k += 1) {
                    try new_params.append(allocator, frame.read(Reg.from(tc.args.int() + @as(u32, k))));
                }
                const new_func = module.funcById(tc.func).?;
                coerceIntArgsToLong(@constCast(new_func), new_params.items);
                frame.func = new_func;
                frame.params.deinit(allocator);
                frame.params = new_params;
                frame.regs.clearRetainingCapacity();
                if (!runtime.reclaimEnabled() and new_func.frameNoFill()) {
                    try frame.regs.ensureTotalCapacity(regsAlloc(allocator), new_func.n_locals);
                    frame.regs.items.len = new_func.n_locals;
                    frame.wmask = RegMask.none;
                } else {
                    try frame.regs.appendNTimes(regsAlloc(allocator), .Unit, new_func.n_locals);
                    frame.wmask.setAll();
                }
                try_stack.clearRetainingCapacity();
                cur = new_func.entry;
            },
            .Switch => |sw| {
                const v = frame.read(sw.reg);
                var next = sw.default;
                for (sw.arms) |arm| {
                    if (constMatches(frame.module, arm.key, &v)) {
                        next = arm.target;
                        break;
                    }
                }
                if (cmgTraceWant()) |w| if (std.mem.eql(u8, w, frame.func.name)) {
                    std.debug.print("[switch] {s} v={s}", .{ frame.func.name, @tagName(std.meta.activeTag(v)) });
                    if (v == .Int) std.debug.print(":{d}", .{v.Int});
                    std.debug.print(" -> b{d} (default b{d}, {d} arms)\n", .{ next.int(), sw.default.int(), sw.arms.len });
                };
                cur = next;
            },
        }
    }
}

fn isReturnLike(term: Terminator) bool {
    return switch (term) {
        .Return, .NonLocalReturn, .LabeledReturn, .Throw => true,
        else => false,
    };
}

fn replacesPendingBeforeRouting(term: Terminator) bool {
    return switch (term) {
        .Return, .NonLocalReturn, .LabeledReturn => true,
        else => false,
    };
}

fn rpositionByBody(items: []const TryFrame, body: BlockId) ?usize {
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        if (std.meta.eql(items[i].body, body)) return i;
    }
    return null;
}

fn rpositionByFinallyEntry(items: []const TryFrame, cur: BlockId) ?usize {
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        if (items[i].finally_entry) |b| {
            if (std.meta.eql(b, cur)) return i;
        }
    }
    return null;
}

fn findCatch(comptime H: type, host: *H, exc: *const Value, catches: []const ir.CatchHandler) ?ir.CatchHandler {
    for (catches) |h| {
        if (host.instanceOf(exc, typeRefName(h.type_name))) return h;
    }
    return null;
}

/// Destination register of a value-producing instruction, used to route
/// a coroutine resume value back to the suspending call site.
fn instDst(inst: *const Inst) ?Reg {
    return switch (inst.*) {
        .Call => |x| x.dst,
        .CallValue => |x| x.dst,
        .CallValueWithThis => |x| x.dst,
        .CallSpread => |x| x.dst,
        .CallSuper => |x| x.dst,
        .CallMember => |x| x.dst,
        .CallVirtual => |x| x.dst,
        .CallMemberOrGlobal => |x| x.dst,
        .CallValueOrMember => |x| x.dst,
        .CallMemberOrValue => |x| x.dst,
        .NewInstance => |x| x.dst,
        .CtxScope => |x| x.dst,
        .CtxCall => |x| x.dst,
        else => null,
    };
}

/// Every arm is OUTLINED and `execInst` itself stays `noinline`. Zig does not
/// reclaim block-scoped stack allocations (ziglang/zig#23475), so all 49 arms'
/// locals lived in ONE frame — the SUM, not the max — held live across the
/// interpreter's recursion. On the INTERPRETED path (the JIT off, or any
/// function not yet hot) that was 35,834 bytes of native stack per call; it is
/// 14,299 now, and the recursion ceiling went 7.5k -> 18.8k frames.
///
/// `noinline` is required, not cosmetic: outlining the arms alone lets LLVM
/// inline `execInst` into `runFrameInner`, so the arm frame is ADDED rather than
/// substituted and the ceiling gets WORSE.
///
/// This does nothing for the JIT'd path — once a function is hot the recursive
/// call runs native code -> `LoopTramp.call` -> `callFunc` and never reaches
/// here. That path is served by outlining the trampoline's bulky sites.
/// The shared post-step control-flow handling for both instruction loops
/// (the tree walker's and the bytecode tier's): flat-call handoff, throw /
/// non-local-return capture, suspension parking. `.brk` breaks to the
/// block's unwind handling with `thrown`/`unwound` set; `.ret` returns
/// `ret.*` from the frame.
const AfterStep = enum { cont, brk, ret };

pub fn afterStep(
    allocator: Allocator,
    frame: *Frame,
    r: Step,
    inst: *const Inst,
    idx: usize,
    cur: BlockId,
    flat_out: *?FlatCallSite,
    park_out: *?ParkPoint,
    thrown: *?Value,
    unwound: *?EvalError,
    ret: *EvalResult,
) Allocator.Error!AfterStep {
    if (r == .flat_call) {
        const req = frame.flat_call.?;
        frame.flat_call = null;
        flat_out.* = .{ .req = req, .ret_block = cur, .ret_idx = idx + 1 };
        ret.* = ok(.Unit);
        return .ret;
    }
    if (r == .raised) {
        const e = frame.step_err.?;
        frame.step_err = null;
        switch (e) {
            .Throw => |v| {
                var tv = v;
                try attachStackTrace(allocator, &tv);
                thrown.* = tv;
                return .brk;
            },
            .NonLocalReturn, .LabeledReturn => {
                unwound.* = e;
                return .brk;
            },
            .CalleeFailed, .StackOverflow => {
                unwound.* = e;
                return .brk;
            },
            .Suspended => |state| {
                const resume_reg = if (state.pending_resume_reg) |rr| blk: {
                    state.pending_resume_reg = null;
                    break :blk rr;
                } else instDst(inst);
                park_out.* = .{ .block = cur, .inst_idx = idx + 1, .resume_reg = resume_reg };
                ret.* = errResult(.{ .Suspended = state });
                return .ret;
            },
            else => {
                ret.* = errResult(e);
                return .ret;
            },
        }
    }
    return .cont;
}

/// The bytecode tier's inline BinOp path: same-tag Int/Long scalar
/// arithmetic and comparison (and Bool And/Or) with results written
/// straight into the register file. Semantics mirror `applyBinop`'s
/// same-tag cases exactly — wrap arithmetic, `divTruncI32/64` /
/// `remTruncI32/64`, numeric equality — and every other shape
/// (mixed tags, zero divisors, Cells, user operators) returns false
/// so the generic arm runs.
pub inline fn binFast(frame: *Frame, op: BinOp, dst: Reg, lhs: Reg, rhs: Reg, allocator: Allocator) bool {
    // Register indices are PROVEN in bounds: validated `< n_locals` at
    // stream build, and the bytecode section checked
    // `regs.len >= n_locals` once at entry.
    const regs = frame.regs.items.ptr;
    const lv = regs[lhs.int()];
    const rv = regs[rhs.int()];
    const out: Value = scalarBin(op, lv, rv) orelse return false;
    const old = regs[dst.int()];
    regs[dst.int()] = out;
    frame.wmask.set(dst.int());
    if (runtime.reclaimEnabled()) old.release(allocator);
    return true;
}

/// The shared same-tag scalar BinOp core: Int/Int, Long/Long, Bool/Bool
/// and mixed Int/Long pairs with `applyBinop`'s exact semantics. Null
/// for every shape the generic arm must handle (mixed non-integer tags,
/// zero divisors, boxed equality on mixed widths, Cells, ===).
pub inline fn scalarBin(op: BinOp, lv: Value, rv: Value) ?Value {
    return if (lv == .Int and rv == .Int) blk: {
        const a = lv.Int;
        const b = rv.Int;
        break :blk switch (op) {
            .Add => .{ .Int = a +% b },
            .Sub => .{ .Int = a -% b },
            .Mul => .{ .Int = a *% b },
            .Div => if (b == 0) break :blk null else .{ .Int = divTruncI32(a, b) },
            .Mod => if (b == 0) break :blk null else .{ .Int = remTruncI32(a, b) },
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq, .BoxedEq => .{ .Bool = a == b },
            .NotEq, .BoxedNotEq => .{ .Bool = a != b },
            .And => .{ .Int = a & b },
            .Or => .{ .Int = a | b },
            .Xor => .{ .Int = a ^ b },
            .Shl => .{ .Int = @as(i32, @bitCast(@as(u32, @bitCast(a)) << @as(u5, @intCast(@as(u32, @bitCast(b)) & 31)))) },
            .Shr => .{ .Int = a >> @as(u5, @intCast(@as(u32, @bitCast(b)) & 31)) },
            .UShr => .{ .Int = @as(i32, @bitCast(@as(u32, @bitCast(a)) >> @as(u5, @intCast(@as(u32, @bitCast(b)) & 31)))) },
            else => break :blk null,
        };
    } else if (lv == .Long and rv == .Long) blk: {
        const a = lv.Long;
        const b = rv.Long;
        break :blk switch (op) {
            .Add => .{ .Long = a +% b },
            .Sub => .{ .Long = a -% b },
            .Mul => .{ .Long = a *% b },
            .Div => if (b == 0) break :blk null else .{ .Long = divTruncI64(a, b) },
            .Mod => if (b == 0) break :blk null else .{ .Long = remTruncI64(a, b) },
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq, .BoxedEq => .{ .Bool = a == b },
            .NotEq, .BoxedNotEq => .{ .Bool = a != b },
            .And => .{ .Long = a & b },
            .Or => .{ .Long = a | b },
            .Xor => .{ .Long = a ^ b },
            else => break :blk null,
        };
    } else if (lv == .Bool and rv == .Bool) blk: {
        break :blk switch (op) {
            .And => .{ .Bool = lv.Bool and rv.Bool },
            .Or => .{ .Bool = lv.Bool or rv.Bool },
            .Xor => .{ .Bool = lv.Bool != rv.Bool },
            .Eq, .BoxedEq => .{ .Bool = lv.Bool == rv.Bool },
            .NotEq, .BoxedNotEq => .{ .Bool = lv.Bool != rv.Bool },
            else => break :blk null,
        };
    } else if ((lv == .Double and rv == .Float) or (lv == .Float and rv == .Double)) blk: {
        // A Double against a Float (a smart cast to each in one condition)
        // compares as Double under IEEE: `0.0 != -0.0F` is false. Boxed
        // equality stays tag-sensitive and falls through.
        const a: f64 = if (lv == .Double) lv.Double else @floatCast(lv.Float);
        const b: f64 = if (rv == .Double) rv.Double else @floatCast(rv.Float);
        break :blk switch (op) {
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq => .{ .Bool = a == b },
            .NotEq => .{ .Bool = a != b },
            else => break :blk null,
        };
    } else if ((lv == .Int or lv == .Long) and (rv == .Int or rv == .Long)) blk: {
        // Mixed widths promote to Long, as `applyBinop` does. Boxed
        // equality stays tag-sensitive (`(1 as Any) != (1L as Any)`)
        // and falls through.
        const a: i64 = if (lv == .Int) lv.Int else lv.Long;
        const b: i64 = if (rv == .Int) rv.Int else rv.Long;
        break :blk switch (op) {
            .Add => .{ .Long = a +% b },
            .Sub => .{ .Long = a -% b },
            .Mul => .{ .Long = a *% b },
            .Div => if (b == 0) break :blk null else .{ .Long = divTruncI64(a, b) },
            .Mod => if (b == 0) break :blk null else .{ .Long = remTruncI64(a, b) },
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq => .{ .Bool = a == b },
            .NotEq => .{ .Bool = a != b },
            // The logical trio only lowers to a BinOp when the STATIC
            // types agree, but a literal's runtime tag can be narrower
            // than its declared Long; compute wide, return Long as the
            // declared type promised.
            .And => .{ .Long = a & b },
            .Or => .{ .Long = a | b },
            .Xor => .{ .Long = a ^ b },
            // Long shifts take an Int count (`Long.shl(bitCount: Int)`);
            // the count uses its low 6 bits, JVM-style.
            .Shl => if (lv == .Long) .{ .Long = @as(i64, @bitCast(@as(u64, @bitCast(a)) << @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)))) } else break :blk null,
            .Shr => if (lv == .Long) .{ .Long = a >> @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)) } else break :blk null,
            .UShr => if (lv == .Long) .{ .Long = @as(i64, @bitCast(@as(u64, @bitCast(a)) >> @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)))) } else break :blk null,
            else => break :blk null,
        };
    } else null;
}

/// The frame loop's per-block-entry guards, run on every taken FUSED
/// edge: daemon abandonment, the spin/wall diagnostic, and the GC safe
/// point. Non-null = abort the frame with this result.
pub inline fn fusedEdgeGuard(allocator: Allocator, ftls: *EvalTls) ?EvalResult {
    if (runtime.shouldAbandon()) {
        return errResult(.{ .Type = "daemon task abandoned at run boundary" });
    }
    ftls.spin_check_counter +%= 1;
    if (ftls.spin_check_counter & 0xFFFF == 0) {
        spinDumpMaybe();
        const wall_dl = parent.test_wall_deadline_ms.load(.monotonic);
        if (wall_dl != 0 and nowMonotonicMs() > wall_dl) {
            return wallCapFire(allocator) catch
                errResult(.{ .Type = "test wall-clock deadline exceeded" });
        }
    }
    if (runtime.gc.gc_enabled and runtime.gc.pending()) {
        runtime.gc.safePoint();
    }
    return null;
}

/// Unchecked register store for the bytecode loop's simple ops: the
/// index was validated `< n_locals` at stream build and the section
/// checked `regs.len >= n_locals` once at entry. Takes ownership of `v`.
pub inline fn writeFastU(frame: *Frame, r: Reg, v: Value, allocator: Allocator) void {
    const idx = r.int();
    const old = frame.regs.items.ptr[idx];
    frame.regs.items.ptr[idx] = v;
    frame.wmask.set(idx);
    if (runtime.reclaimEnabled()) old.release(allocator);
}
