//! The frame dispatch loop and its instruction fast paths.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const bc = @import("../bc.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BinOp = ir.BinOp;
const BlockId = ir.BlockId;
const ClassId = ir.ClassId;
const Func = ir.Func;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;
const Terminator = ir.Terminator;


const envVarSet = ev_values.envVarSet;

const parent = @import("../eval.zig");
const ev_diag = @import("diag.zig");
const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_inst = @import("inst.zig");
const ev_activation = @import("activation.zig");
const ev_resolved = @import("resolved.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");

const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const Activation = ev_flow.Activation;
const actFree = ev_activation.actFree;
const discardFlatReq = ev_activation.discardFlatReq;
const dumpFrameChainForDiag = ev_diag.dumpFrameChainForDiag;
const frameBoundary = ev_enter.frameBoundary;
const funcOwnedBy = ev_enter.funcOwnedBy;
const liveParkActivation = ev_activation.liveParkActivation;
const openActivation = ev_activation.openActivation;
const openStreamActivation = ev_activation.openStreamActivation;
const closeStreamActivation = ev_activation.closeStreamActivation;
const snapshotSuspendedFrame = ev_activation.snapshotSuspendedFrame;
const teardownActivation = ev_activation.teardownActivation;
const argRun = ev_frame.argRun;
const FlatCallSite = ev_flow.FlatCallSite;
const Frame = ev_frame.Frame;
const ParkPoint = ev_flow.ParkPoint;
const PendingFinallyState = ev_snapshot.PendingFinallyState;
const RegMask = ev_frame.RegMask;
const Step = ev_flow.Step;
const TryFrame = ev_snapshot.TryFrame;
const attachStackTrace = ev_diag.attachStackTrace;
const cmgTraceWant = ev_flow.cmgTraceWant;
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
const nowMonotonicMs = ev_diag.nowMonotonicMs;
const ok = ev_flow.ok;
const remTruncI32 = ev_values.remTruncI32;
const remTruncI64 = ev_values.remTruncI64;
const spinDumpMaybe = ev_diag.spinDumpMaybe;
const unwindTerminal = ev_enter.unwindTerminal;
const valueTruthy = ev_values.valueTruthy;
const wallCapFire = ev_diag.wallCapFire;

/// The one interpreter loop: runs `root` from `cur_in` and every activation its calls open, switching
/// frames in place rather than returning to a driver. `resume_throw`: a continuation resumed with
/// `Result.failure(e)` routes the exception through the frame's restored try-stack instead of
/// delivering it as the suspending call's value, so a cancellation preempts a parked `delay`.
/// `resume_unwind` is the same for a non-local return from a resumed inner frame. `root_act` marks a
/// root frame that is itself a resumed live activation, which a suspension live-parks rather than
/// snapshots.
pub fn runFlatLoop(
    comptime H: type,
    allocator: Allocator,
    root: *Frame,
    root_ts: *std.ArrayList(TryFrame),
    cur_in: BlockId,
    resume_idx_in: usize,
    resume_throw_in: ?Value,
    resume_unwind_in: ?EvalError,
    root_act: ?*Activation,
    host: *H,
) Allocator.Error!EvalResult {
    // The reclaim flag is fixed for the run, so each setting gets a loop of its own: under the
    // tracing collector no stream op tests it or keeps an old value to release.
    if (runtime.reclaimEnabled())
        return runLoop(H, true, allocator, root, root_ts, cur_in, resume_idx_in, resume_throw_in, resume_unwind_in, root_act, host);
    return runLoop(H, false, allocator, root, root_ts, cur_in, resume_idx_in, resume_throw_in, resume_unwind_in, root_act, host);
}

fn runLoop(
    comptime H: type,
    comptime reclaim: bool,
    allocator: Allocator,
    root: *Frame,
    root_ts: *std.ArrayList(TryFrame),
    cur_in: BlockId,
    resume_idx_in: usize,
    resume_throw_in: ?Value,
    resume_unwind_in: ?EvalError,
    root_act: ?*Activation,
    host: *H,
) Allocator.Error!EvalResult {
    const ev: *EvalTls = ev_state.evtlsPtr();
    // The innermost open activation; each links to the one that called it.
    var top: ?*Activation = null;
    // On an allocation failure, unwind every open activation so no frame dangles on the GC chain.
    errdefer while (top) |act| {
        top = act.caller;
        ev.eval_depth -= 1;
        teardownActivation(allocator, act);
        actFree(ev, allocator, act);
    };
    // KLIO_FN_PROF: the caller's attribution is restored on exit, so samples are self-time.
    const fn_prof_prev: u32 = if (runtime.prof.fn_prof_active) fnProfEnter(root.func.id.int()) else 0;
    defer if (runtime.prof.fn_prof_active) fnProfLeave(fn_prof_prev);
    const ftls: *EvalTls = ev;
    var frame: *Frame = root;
    var try_stack: *std.ArrayList(TryFrame) = root_ts;
    var cur = cur_in;
    var resume_idx = resume_idx_in;
    var resume_throw = resume_throw_in;
    var resume_unwind = resume_unwind_in;
    frames: while (true) {
        // A suspended coroutine resumes on whatever thread the dispatcher hands it.
        if (frame.tls != ev) frame.tls = ev;
        if (parent.frame_count_on) parent.frame_count_total += 1;
        if (runtime.prof.fn_prof_active) _ = fnProfEnter(frame.func.id.int());
        var func: *const Func = frame.func;
        var flat_site: ?FlatCallSite = null;
        var park_point: ?ParkPoint = null;
        const flat_out = &flat_site;
        const park_out = &park_point;
        var res: EvalResult = blocks: {
            // Lazy IR: materialise a deferred function's blocks first.
            if (func.blocks.len == 0 and !frame.module.ensureFuncBody(@constCast(func))) {
                if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
                    std.debug.print("[empty-frame] fqn={s} params={d} caller={s}\n", .{
                        func.fqn, func.params.len,
                        if (currentFrameFunc()) |cf| cf.fqn else "<none>",
                    });
                    dumpFrameChainForDiagAlways();
                }
                break :blocks errResult(.{ .Type = "virtual method target is not executable" });
            }
            dumpFnIfRequested(func);
            // The function's code: a null table is an allocation that failed or an edge to no block.
            var bc_streams: *const bc.FuncStreams = bc.funcStreams(func, frame.module.consts.items) orelse return error.OutOfMemory;
            block_loop: while (true) {
                // A block entry is a safe point: no cell lock may be held across it.
                runtime.assertNoCellLock();
                // Daemon abandonment: a pool task at the run boundary stops at its next block, bypassing user catch/finally.
                if (runtime.shouldAbandon()) {
                    break :blocks errResult(.{ .Type = "daemon task abandoned at run boundary" });
                }
                // Spin diagnostic (KLIO_SPIN_TRACE): cheap counter gate, wall-clock check inside.
                ftls.spin_check_counter +%= 1;
                if (ftls.spin_check_counter & 0xFFFF == 0) {
                    spinDumpMaybe();
                    if (runtime.gc.gc_enabled) runtime.gc.idleProbeNow();
                    const wall_dl = parent.test_wall_deadline_ms.load(.monotonic);
                    if (wall_dl != 0 and nowMonotonicMs() > wall_dl) {
                        // Dump the live frame chain so a caught hang names where it looped.
                        break :blocks try wallCapFire(allocator);
                    }
                }
                // GC safe point: at an opcode boundary every live Value sits in a registered frame or
                // global; route a resumed throw/return payload first so it stays rooted.
                if (runtime.gc.gc_enabled and runtime.gc.pendingFlag() and
                    resume_throw == null and resume_unwind == null)
                {
                    runtime.gc.safePoint();
                }
                const block = &func.blocks[cur.int()];
                if (resume_idx == 0) {
                    try enterTryBlock(allocator, try_stack, block, cur);
                } else if (block.h().catch_done_for) |body| {
                    // A resume into a catch-only try's join pops the body's frame, as an entry does.
                    if (rpositionByBody(try_stack.items, body)) |p| _ = try_stack.orderedRemove(p);
                }
                const insts: []const Inst = block.insts;
                const term = block.terminator;
                var thrown: ?Value = null;
                var unwound: ?EvalError = null;
                var start_idx = resume_idx;
                resume_idx = 0;
                if (resume_throw) |exc| {
                    resume_throw = null;
                    // Resumed with an exception: route it through the restored try-stack as a mid-block throw.
                    thrown = exc;
                    start_idx = insts.len;
                } else if (resume_unwind) |e| {
                    resume_unwind = null;
                    // Resume the caller as though its suspending call raised this non-local return.
                    unwound = e;
                    start_idx = insts.len;
                }
                var idx: usize = 0;
                var ret_v: EvalResult = ok(.Unit);
                // A stream exit that leaves only its block's terminator to the frame loop.
                // The block's stream: its ops run the instructions, every other one escapes to its
                // arm in `execInst`, and control flow funnels through `afterStep`. A mid-block resume
                // enters at the instruction's pc.
                bc_run: {
                    var bs = bc_streams;
                    // A resume carrying a throw/unwind runs no instruction of the block: an EMPTY
                    // block's `start_idx` is 0 too, and a terminator op must not run first.
                    if (thrown != null or unwound != null) break :bc_run;
                    // The one bounds check the stream ops rely on; every operand was validated at build.
                    if (frame.regs.len < func.n_locals) break :blocks errResult(.{ .Type = "a register window shorter than its function's registers" });
                    var bcur = cur;
                    const bl = bs.blocks[bcur.int()];
                    var code = bs.code;
                    // Every block's ops end in an `end` op; a resume at the terminator starts on it.
                    var pc: usize = if (start_idx == 0)
                        bl.start
                    else if (start_idx >= insts.len)
                        bl.end
                    else
                        bl.idx_pc[start_idx];
                    // Each op dispatches the next itself, so every op's successor has a branch of its own.
                    bc_loop: {
                        sw: switch (opAt(code, pc)) {
                            .end => {
                                leaveSpan(frame, code, pc + 1);
                                break :bc_loop;
                            },
                            .block_entry => {
                                try enterTryBlock(allocator, try_stack, &frame.func.blocks[bcur.int()], bcur);
                                pc += 1;
                                continue :sw opAt(code, pc);
                            },
                            .goto_try => {
                                leaveSpan(frame, code, pc + 3);
                                // A return, a throw or a non-local return passing through a finally takes the
                                // frame loop's routing.
                                if (frame.pending) |p| if (p.tryDepth() != null) {
                                    cur = bcur;
                                    resume_idx = std.math.maxInt(usize);
                                    continue :block_loop;
                                };
                                leaveTryBlock(try_stack, &frame.func.blocks[bcur.int()], bcur);
                                const target = code[pc + 1];
                                if (target <= bcur.int()) if (edgeGuard(allocator, ftls)) |er| {
                                    cur = bcur;
                                    break :blocks er;
                                };
                                bcur = @enumFromInt(target);
                                pc = code[pc + 2];
                                continue :sw opAt(code, pc);
                            },
                            .const_val => {
                                writeFastR(frame, @enumFromInt(code[pc + 1]), bs.values[code[pc + 2]], allocator, reclaim);
                                pc += 3;
                                continue :sw opAt(code, pc);
                            },
                            .const_load => {
                                const v = try constToValue(allocator, &frame.module.consts.items[code[pc + 2]]);
                                writeFastR(frame, @enumFromInt(code[pc + 1]), v, allocator, reclaim);
                                pc += 3;
                                continue :sw opAt(code, pc);
                            },
                            .const_str => {
                                const slot = &bs.strings[code[pc + 3]];
                                const raw = slot.load(.acquire);
                                const v: Value = if (raw != 0)
                                    .{ .String = .{ .cell = @ptrFromInt(raw) } }
                                else
                                    try internString(allocator, frame, code[pc + 2], slot);
                                if (reclaim) v.retain();
                                writeFastR(frame, @enumFromInt(code[pc + 1]), v, allocator, reclaim);
                                pc += 4;
                                continue :sw opAt(code, pc);
                            },
                            .const_int => {
                                const v: Value = .{ .Int = @bitCast(code[pc + 2]) };
                                writeFastR(frame, @enumFromInt(code[pc + 1]), v, allocator, reclaim);
                                pc += 3;
                                continue :sw opAt(code, pc);
                            },
                            .move => {
                                const v = frame.regs.ptr[code[pc + 2]];
                                if (reclaim) v.retain();
                                writeFastR(frame, @enumFromInt(code[pc + 1]), v, allocator, reclaim);
                                pc += 3;
                                continue :sw opAt(code, pc);
                            },
                            .load_param => {
                                const pidx: usize = code[pc + 2];
                                const v = if (pidx < frame.params.len) frame.params[pidx] else Value.Unit;
                                if (reclaim) v.retain();
                                writeFastR(frame, @enumFromInt(code[pc + 1]), v, allocator, reclaim);
                                pc += 3;
                                continue :sw opAt(code, pc);
                            },
                            .make_cell => {
                                const v = frame.regs.ptr[code[pc + 2]];
                                v.retain();
                                writeFastR(frame, @enumFromInt(code[pc + 1]), try Value.newCell(allocator, v), allocator, reclaim);
                                pc += 3;
                                continue :sw opAt(code, pc);
                            },
                            .cell_set => {
                                const cell = frame.regs.ptr[code[pc + 2]];
                                if (cell == .Cell) {
                                    const v = frame.regs.ptr[code[pc + 3]];
                                    v.retain();
                                    const g = cell.Cell.borrowMut();
                                    const old = g.get().*;
                                    g.get().* = v;
                                    g.deinit();
                                    if (reclaim) old.release(allocator);
                                    pc += 4;
                                    continue :sw opAt(code, pc);
                                }
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 4,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .store_static => {
                                if (ev_resolved.storeReadyStatic(H, allocator, frame, host, code[pc + 2], frame.regs.ptr[code[pc + 3]])) {
                                    pc += 4;
                                    continue :sw opAt(code, pc);
                                }
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 4,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            inline .make_closure, .new_array => |op| {
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                // The arm itself, without the instruction switch in front of it.
                                const r = if (op == .make_closure)
                                    try ev_resolved.execMakeClosure(H, allocator, frame, inst.MakeClosure, host)
                                else
                                    try ev_resolved.execNewArray(H, allocator, frame, inst.NewArray, host);
                                if (r == .cont) {
                                    pc += 2;
                                    continue :sw opAt(code, pc);
                                }
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 2,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .load_capture => {
                                const cidx: usize = code[pc + 2];
                                const v = if (cidx < frame.captures.len) frame.captures[cidx] else Value.Unit;
                                if (reclaim) v.retain();
                                writeFastR(frame, @enumFromInt(code[pc + 1]), v, allocator, reclaim);
                                pc += 3;
                                continue :sw opAt(code, pc);
                            },
                            .load_static => {
                                if (ev_resolved.readyStatic(H, frame, host, code[pc + 3])) |v| {
                                    if (reclaim) v.retain();
                                    writeFastR(frame, @enumFromInt(code[pc + 2]), v, allocator, reclaim);
                                    pc += 4;
                                    continue :sw opAt(code, pc);
                                }
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 4,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .is, .cast => |op| {
                                const v = frame.regs.ptr[code[pc + 3]];
                                const flags = code[pc + 5];
                                if (ev_resolved.quickIsA(frame, &v, code[pc + 4], flags & 1 != 0)) |yes| {
                                    const dst: Reg = @enumFromInt(code[pc + 2]);
                                    if (op == .is) {
                                        writeFastR(frame, dst, .{ .Bool = yes }, allocator, reclaim);
                                        pc += 6;
                                        continue :sw opAt(code, pc);
                                    }
                                    // A failing `as` throws from its arm.
                                    if (yes or flags & 2 != 0) {
                                        const out: Value = if (yes) v else .Null;
                                        if (reclaim) out.retain();
                                        writeFastR(frame, dst, out, allocator, reclaim);
                                        pc += 6;
                                        continue :sw opAt(code, pc);
                                    }
                                }
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 6,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .cell_get => {
                                const v = switch (frame.regs.ptr[code[pc + 2]]) {
                                    .Cell => |c| vblk: {
                                        const g = c.borrow();
                                        defer g.deinit();
                                        break :vblk g.get().*;
                                    },
                                    else => |other| other,
                                };
                                if (reclaim) v.retain();
                                writeFastR(frame, @enumFromInt(code[pc + 1]), v, allocator, reclaim);
                                pc += 3;
                                continue :sw opAt(code, pc);
                            },
                            .bin => {
                                // Same-tag scalar operands take an inline path with the exact `applyBinop`
                                // semantics; anything else, a zero divisor included, falls through.
                                if (binFast(
                                    frame,
                                    @enumFromInt(code[pc + 2] & 0xff),
                                    @enumFromInt(code[pc + 3]),
                                    @enumFromInt(code[pc + 4]),
                                    @enumFromInt(code[pc + 5]),
                                    allocator,
                                    reclaim,
                                )) {
                                    pc += 6;
                                    continue :sw opAt(code, pc);
                                }
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execArmBinOp(H, allocator, frame, inst.BinOp, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 6,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            inline .add, .sub => |op| {
                                const regs = frame.regs.ptr;
                                const l = regs[code[pc + 4]];
                                const r = regs[code[pc + 5]];
                                if (l == .Int and r == .Int) {
                                    const v = if (op == .add) l.Int +% r.Int else l.Int -% r.Int;
                                    writeFastR(frame, @enumFromInt(code[pc + 3]), .{ .Int = v }, allocator, reclaim);
                                    pc += 6;
                                    continue :sw opAt(code, pc);
                                }
                                if (l == .Long and r == .Long) {
                                    const v = if (op == .add) l.Long +% r.Long else l.Long -% r.Long;
                                    writeFastR(frame, @enumFromInt(code[pc + 3]), .{ .Long = v }, allocator, reclaim);
                                    pc += 6;
                                    continue :sw opAt(code, pc);
                                }
                                continue :sw .bin;
                            },
                            .cmp => {
                                const regs = frame.regs.ptr;
                                const l = regs[code[pc + 4]];
                                const r = regs[code[pc + 5]];
                                const mask = code[pc + 2] >> 8;
                                if (l == .Int and r == .Int) {
                                    writeFastR(frame, @enumFromInt(code[pc + 3]), .{ .Bool = holds(mask, l.Int, r.Int) }, allocator, reclaim);
                                    pc += 6;
                                    continue :sw opAt(code, pc);
                                }
                                if (l == .Long and r == .Long) {
                                    writeFastR(frame, @enumFromInt(code[pc + 3]), .{ .Bool = holds(mask, l.Long, r.Long) }, allocator, reclaim);
                                    pc += 6;
                                    continue :sw opAt(code, pc);
                                }
                                continue :sw .bin;
                            },
                            .un => {
                                if (unopFast(frame, @enumFromInt(code[pc + 2]), @enumFromInt(code[pc + 3]), @enumFromInt(code[pc + 4]), allocator, reclaim)) {
                                    pc += 5;
                                    continue :sw opAt(code, pc);
                                }
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 5,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .call, .vcall => |op| {
                                idx = code[pc + 1];
                                const op_len: usize = if (op == .call) 8 else 6;
                                const fid: u32 = if (op == .call) code[pc + 2] else virtualTarget(frame, code[pc + 2], code[pc + 3]) orelse NO_TARGET;
                                const callee: ?*const bc.FuncStreams = if (op == .call)
                                    staticCallee(H, host, frame, ev, bs, fid, code[pc + 6], code[pc + 7])
                                else
                                    streamCallee(frame, ev, fid);
                                if (callee) |sc| {
                                    frame.at(bcur, idx);
                                    // The call is a block edge for the loop's guards.
                                    if (edgeGuard(allocator, ftls)) |er| {
                                        cur = bcur;
                                        break :blocks er;
                                    }
                                    const params = argRun(frame, @enumFromInt(code[pc + 3]), code[pc + 4]);
                                    ev.eval_depth += 1;
                                    const act = openStreamActivation(ev, allocator, frame.module, sc.func, params, &.{}, null, null, null, @enumFromInt(code[pc + 5]), sc.no_fill, reclaim) catch |e| {
                                        ev.eval_depth -= 1;
                                        return e;
                                    };
                                    act.ret_block = bcur;
                                    act.ret_idx = idx + 1;
                                    // A caller whose every block ends in a stream op goes on in its stream at the return.
                                    act.ret_streams = bs;
                                    act.ret_pc = @intCast(pc + op_len);
                                    act.caller = top;
                                    top = act;
                                    frame = &act.frame;
                                    try_stack = &act.try_stack;
                                    func = sc.func;
                                    if (parent.call_hooks_on) {
                                        if (runtime.prof.fn_prof_active) _ = fnProfEnter(func.id.int());
                                        if (parent.frame_count_on) parent.frame_count_total += 1;
                                        dumpFnIfRequested(func);
                                    }
                                    bc_streams = sc;
                                    bs = sc;
                                    bcur = func.entry;
                                    code = sc.code;
                                    pc = sc.entry_pc;
                                    continue :sw opAt(code, pc);
                                }
                                // A host function the tables bind runs here over the argument run, once the
                                // unit a static call must see run has.
                                if (nativeOf(frame, fid)) |nid| if (op == .vcall or ev_resolved.unitReady(H, host, code[pc + 7])) {
                                    frame.at(bcur, idx);
                                    if (try hostCall(H, allocator, frame, host, nid, code[pc + 3], code[pc + 4], code[pc + 5], reclaim)) |e| {
                                        frame.tls.step_err = e;
                                        const inst = instAt(frame, bcur, idx);
                                        switch (try afterStep(allocator, frame, .raised, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                            .cont, .brk => break :bc_loop,
                                            .ret => break :blocks ret_v,
                                        }
                                    }
                                    pc += op_len;
                                    continue :sw opAt(code, pc);
                                };
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += op_len,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .new, .callv => |op| {
                                idx = code[pc + 1];
                                const op_len: usize = if (op == .new) 8 else 6;
                                frame.at(bcur, idx);
                                const target: ?StreamTarget = if (op == .new)
                                    try constructTarget(H, allocator, frame, ev, host, bs, code[pc..][0..8], reclaim)
                                else
                                    try closureTarget(H, frame, ev, host, code[pc..][0..6]);
                                if (target) |t| {
                                    const sc = t.streams;
                                    // The call is a block edge for the loop's guards.
                                    if (edgeGuard(allocator, ftls)) |er| {
                                        if (t.area) |m| ev.vstack.restore(m);
                                        cur = bcur;
                                        break :blocks er;
                                    }
                                    ev.eval_depth += 1;
                                    const act = openStreamActivation(ev, allocator, t.run_module orelse frame.module, sc.func, t.params, t.captures, t.area, t.closure_id, t.owning, t.dst, sc.no_fill, reclaim) catch |e| {
                                        ev.eval_depth -= 1;
                                        if (t.area) |m| ev.vstack.restore(m);
                                        return e;
                                    };
                                    act.ret_block = bcur;
                                    act.ret_idx = idx + 1;
                                    // A caller whose every block ends in a stream op goes on in its stream at the return.
                                    act.ret_streams = bs;
                                    act.ret_pc = @intCast(pc + op_len);
                                    act.caller = top;
                                    top = act;
                                    frame = &act.frame;
                                    try_stack = &act.try_stack;
                                    func = sc.func;
                                    if (parent.call_hooks_on) {
                                        if (runtime.prof.fn_prof_active) _ = fnProfEnter(func.id.int());
                                        if (parent.frame_count_on) parent.frame_count_total += 1;
                                        dumpFnIfRequested(func);
                                    }
                                    bc_streams = sc;
                                    bs = sc;
                                    bcur = func.entry;
                                    code = sc.code;
                                    pc = sc.entry_pc;
                                    continue :sw opAt(code, pc);
                                }
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += op_len,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .native => {
                                idx = code[pc + 1];
                                frame.at(bcur, idx);
                                const run = argRun(frame, @enumFromInt(code[pc + 3]), code[pc + 4]);
                                const nid: ir.NativeId = @enumFromInt(code[pc + 2]);
                                // A Kotlin receiver's own override of the member answers; `super` runs the native.
                                const res = if (comptime @hasDecl(H, "callNativeSite"))
                                    (if (code[pc + 6] == 0 and run.len != 0 and run[0] == .Instance)
                                        try host.callNativeSite(allocator, nid, run)
                                    else
                                        try host.callNative(allocator, nid, run))
                                else
                                    try host.callNative(allocator, nid, run);
                                switch (res) {
                                    .ok => |v| {
                                        writeFastR(frame, @enumFromInt(code[pc + 5]), v, allocator, reclaim);
                                        pc += 7;
                                        continue :sw opAt(code, pc);
                                    },
                                    .err => |e| {
                                        frame.tls.step_err = e;
                                        const inst = instAt(frame, bcur, idx);
                                        switch (try afterStep(allocator, frame, .raised, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                            .cont, .brk => break :bc_loop,
                                            .ret => break :blocks ret_v,
                                        }
                                    },
                                }
                            },
                            .array_get => {
                                const arr = frame.regs.ptr[code[pc + 3]];
                                if (arr == .Array or arr == .String) {
                                    const idx_v = frame.regs.ptr[code[pc + 4]];
                                    if (ev_values.fastIndexGet(&arr, &idx_v)) |v| {
                                        writeFastR(frame, @enumFromInt(code[pc + 2]), v, allocator, reclaim);
                                        pc += 5;
                                        continue :sw opAt(code, pc);
                                    }
                                }
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 5,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .array_set => {
                                const arr = frame.regs.ptr[code[pc + 2]];
                                if (arr == .Array) {
                                    const idx_v = frame.regs.ptr[code[pc + 3]];
                                    if (ev_values.fastIndexSet(allocator, &arr, &idx_v, frame.regs.ptr[code[pc + 4]]) != null) {
                                        pc += 5;
                                        continue :sw opAt(code, pc);
                                    }
                                }
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 5,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .load_object => {
                                if (ev_resolved.builtObject(H, frame, host, code[pc + 3])) |v| {
                                    if (reclaim) v.retain();
                                    writeFastR(frame, @enumFromInt(code[pc + 2]), v, allocator, reclaim);
                                    pc += 4;
                                    continue :sw opAt(code, pc);
                                }
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 4,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .not => {
                                const v = frame.regs.ptr[code[pc + 3]];
                                if (v == .Bool) {
                                    writeFastR(frame, @enumFromInt(code[pc + 2]), .{ .Bool = !v.Bool }, allocator, reclaim);
                                    pc += 4;
                                    continue :sw opAt(code, pc);
                                }
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 4,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .get_field => {
                                const obj = frame.regs.ptr[code[pc + 3]];
                                if (obj == .Instance) if (runtime.InstanceData.slotGet(obj.Instance, code[pc + 4])) |v| {
                                    if (reclaim) v.retain();
                                    writeFastR(frame, @enumFromInt(code[pc + 2]), v, allocator, reclaim);
                                    pc += 5;
                                    continue :sw opAt(code, pc);
                                };
                                // A null, a host value or a slot past the fields: the instruction's arm.
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 5,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .set_field => {
                                const obj = frame.regs.ptr[code[pc + 2]];
                                if (obj == .Instance) {
                                    const v = frame.regs.ptr[code[pc + 4]];
                                    if (reclaim) v.retain();
                                    if (runtime.InstanceData.slotSet(obj.Instance, code[pc + 3], v)) |old| {
                                        if (reclaim) old.release(allocator);
                                        pc += 5;
                                        continue :sw opAt(code, pc);
                                    }
                                    if (reclaim) v.release(allocator);
                                }
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 5,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .escape => {
                                idx = code[pc + 1];
                                const inst = instAt(frame, bcur, idx);
                                frame.at(bcur, idx);
                                const r = try execInst(H, allocator, frame, inst, host);
                                switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                    .cont => pc += 2,
                                    .brk => break :bc_loop,
                                    .ret => break :blocks ret_v,
                                }
                                continue :sw opAt(code, pc);
                            },
                            .jump => {
                                leaveSpan(frame, code, pc + 3);
                                const target = code[pc + 1];
                                if (target <= bcur.int()) if (edgeGuard(allocator, ftls)) |er| {
                                    cur = bcur;
                                    break :blocks er;
                                };
                                bcur = @enumFromInt(target);
                                pc = code[pc + 2];
                                continue :sw opAt(code, pc);
                            },
                            .br => {
                                leaveSpan(frame, code, pc + 6);
                                const cv = frame.regs.ptr[code[pc + 1]];
                                if (cv != .Bool) {
                                    // Cell-carried or coercing condition: the frame loop's Branch runs `valueTruthy`.
                                    cur = bcur;
                                    resume_idx = std.math.maxInt(usize);
                                    continue :block_loop;
                                }
                                // Each edge is its own path, so the next pc waits on a predicted branch
                                // rather than on the condition's value.
                                if (cv.Bool) {
                                    const target = code[pc + 2];
                                    if (target <= bcur.int()) if (edgeGuard(allocator, ftls)) |er| {
                                        cur = bcur;
                                        break :blocks er;
                                    };
                                    bcur = @enumFromInt(target);
                                    pc = code[pc + 3];
                                    continue :sw opAt(code, pc);
                                }
                                const target = code[pc + 4];
                                if (target <= bcur.int()) if (edgeGuard(allocator, ftls)) |er| {
                                    cur = bcur;
                                    break :blocks er;
                                };
                                bcur = @enumFromInt(target);
                                pc = code[pc + 5];
                                continue :sw opAt(code, pc);
                            },
                            .cmp_br => {
                                // The block's last BinOp fused with its Branch: the compare computes inline, still
                                // writes dst so register state matches the unfused form, and branches.
                                var taken: ?bool = null;
                                {
                                    const regs = frame.regs.ptr;
                                    const di: Reg = @enumFromInt(code[pc + 3]);
                                    const l = regs[code[pc + 4]];
                                    const r = regs[code[pc + 5]];
                                    const kw = code[pc + 2];
                                    const mask = kw >> 8;
                                    if (mask != 0 and l == .Int and r == .Int) {
                                        const b = holds(mask, l.Int, r.Int);
                                        writeFastR(frame, di, .{ .Bool = b }, allocator, reclaim);
                                        taken = b;
                                    } else if (mask != 0 and l == .Long and r == .Long) {
                                        const b = holds(mask, l.Long, r.Long);
                                        writeFastR(frame, di, .{ .Bool = b }, allocator, reclaim);
                                        taken = b;
                                    } else if (scalarBin(@enumFromInt(kw & 0xff), l, r)) |out| {
                                        if (out == .Bool) {
                                            writeFastR(frame, di, out, allocator, reclaim);
                                            taken = out.Bool;
                                        }
                                    }
                                }
                                if (taken == null) {
                                    idx = code[pc + 1];
                                    const inst = instAt(frame, bcur, idx);
                                    frame.at(bcur, idx);
                                    const r = try execArmBinOp(H, allocator, frame, inst.BinOp, host);
                                    switch (try afterStep(allocator, frame, r, inst, idx, bcur, flat_out, park_out, &thrown, &unwound, &ret_v)) {
                                        .cont => {},
                                        .brk => break :bc_loop,
                                        .ret => break :blocks ret_v,
                                    }
                                    const cv = frame.read(@enumFromInt(code[pc + 3]));
                                    if (cv != .Bool) {
                                        leaveSpan(frame, code, pc + 10);
                                        cur = bcur;
                                        resume_idx = std.math.maxInt(usize);
                                        continue :block_loop;
                                    }
                                    taken = cv.Bool;
                                }
                                leaveSpan(frame, code, pc + 10);
                                // As `br`: each edge is its own path.
                                if (taken.?) {
                                    const target = code[pc + 6];
                                    if (target <= bcur.int()) if (edgeGuard(allocator, ftls)) |er| {
                                        cur = bcur;
                                        break :blocks er;
                                    };
                                    bcur = @enumFromInt(target);
                                    pc = code[pc + 7];
                                    continue :sw opAt(code, pc);
                                }
                                const target = code[pc + 8];
                                if (target <= bcur.int()) if (edgeGuard(allocator, ftls)) |er| {
                                    cur = bcur;
                                    break :blocks er;
                                };
                                bcur = @enumFromInt(target);
                                pc = code[pc + 9];
                                continue :sw opAt(code, pc);
                            },
                            .ret_try => {
                                // A return inside a try region, or with a finally's flow pending, takes
                                // the frame loop's routing through the finallys.
                                if (try_stack.items.len != 0 or (if (frame.pending) |p| p.tryDepth() != null else false)) {
                                    cur = bcur;
                                    resume_idx = std.math.maxInt(usize);
                                    continue :block_loop;
                                }
                                continue :sw .ret;
                            },
                            .ret => {
                                const v: Value = if (code[pc + 1] != 0)
                                    frame.regs.ptr[code[pc + 2]]
                                else
                                    .Unit;
                                if (reclaim) v.retain();
                                // Back into the caller's stream when it called from one it can go on in.
                                if (top) |act| if (act.ret_streams) |rs| {
                                    top = act.caller;
                                    ev.eval_depth -= 1;
                                    const rb = act.ret_block;
                                    const rpc = act.ret_pc;
                                    const rd = act.ret_dst;
                                    closeStreamActivation(ev, allocator, act, reclaim);
                                    frame = if (top) |a| &a.frame else root;
                                    try_stack = if (top) |a| &a.try_stack else root_ts;
                                    // The caller's stream validated `rd` against its window.
                                    writeFastR(frame, rd, v, allocator, reclaim);
                                    func = frame.func;
                                    if (parent.call_hooks_on and runtime.prof.fn_prof_active) _ = fnProfEnter(func.id.int());
                                    bc_streams = rs;
                                    bs = rs;
                                    bcur = rb;
                                    code = rs.code;
                                    pc = rpc;
                                    continue :sw opAt(code, pc);
                                };
                                break :blocks ok(v);
                            },
                            .term_exit => {
                                leaveSpan(frame, code, pc + 1);
                                cur = bcur;
                                resume_idx = std.math.maxInt(usize);
                                continue :block_loop;
                            },
                        }
                    }
                    // Fused flow may have advanced blocks; the routing below keys on `cur`.
                    cur = bcur;
                }
                if (unwound) |e| {
                    // Mid-block non-local return: route through the armed finally blocks only, never a
                    // catch.
                    frame.pfRelease(allocator);
                    var routed = false;
                    while (try_stack.pop()) |tf| {
                        if (tf.finally_entry) |fin| {
                            if (std.meta.eql(fin, cur)) continue;
                            const key = tf.finally_done orelse fin;
                            (try frame.pfMut()).unwind = .{ .key = key, .err = e, .depth = try_stack.items.len };
                            cur = fin;
                            routed = true;
                            break;
                        }
                    }
                    if (!routed) break :blocks unwindTerminal(frame, e);
                    continue;
                }
                if (thrown) |exc| {
                    // Mid-block throw: the same try-stack walk as Terminator.Throw.
                    const pending_depth = frame.pf().tryDepth();
                    var routed = false;
                    while (try_stack.pop()) |tf| {
                        // A throw raised inside this frame's own finally body must not route back into that
                        // finally or the frame's catches: control left the try region when the finally began.
                        if (tf.finally_entry) |fin0| {
                            if (std.meta.eql(fin0, cur)) continue;
                        }
                        if (findCatch(frame.module, &exc, tf.catches)) |h| {
                            // A catch belonging to a try nested inside the active finally handles the new throw
                            // without replacing the exception or return that caused the finally. Once the scan
                            // crosses the saved depth the throw is escaping, and Kotlin replaces the prior flow.
                            if (pending_depth) |depth| {
                                if (try_stack.items.len < depth) frame.pfRelease(allocator);
                            }
                            try frame.write(h.exception_reg, try caughtValue(H, host, allocator, exc));
                            cur = h.handler;
                            routed = true;
                            break;
                        } else if (tf.finally_entry) |fin| {
                            // An uncaught throw entering a nested finally supersedes the pending control flow.
                            frame.pfRelease(allocator);
                            const key = tf.finally_done orelse fin;
                            (try frame.pfMut()).rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                            cur = fin;
                            routed = true;
                            break;
                        }
                    }
                    if (!routed) {
                        frame.pfRelease(allocator);
                        break :blocks errResult(.{ .Throw = exc });
                    }
                    continue;
                }
                if (term == .Goto) {
                    if (frame.pf().tryDepth() == null) {
                        leaveTryBlock(try_stack, block, cur);
                    } else {
                        // With a flow pending, only an inline return's frames pop here.
                        popOnExit(try_stack, block);
                    }
                }
                // Finally exit with a pending return: replay through any outer finally, else complete it.
                // The pinned key is the done sentinel, so an `if` inside the finally resolves here.
                if (frame.pf().return_value) |pr| {
                    if (std.meta.eql(pr.key, cur) and term == .Goto) {
                        const v = pr.val;
                        (try frame.pfMut()).return_value = null;
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
                            (try frame.pfMut()).return_value = .{ .key = c.key, .val = v, .depth = try_stack.items.len };
                            cur = c.jump;
                            continue;
                        }
                        break :blocks ok(v);
                    }
                    if (std.meta.eql(pr.key, cur) and isReturnLike(term)) {
                        pr.val.release(allocator);
                        (try frame.pfMut()).return_value = null;
                    }
                }
                // Finally re-throw: a plain Goto exit re-raises the saved exception through the enclosing stack.
                if (frame.pf().rethrow) |pr| {
                    if (std.meta.eql(pr.key, cur) and term == .Goto) {
                        const exc = pr.exc;
                        (try frame.pfMut()).rethrow = null;
                        // Drop try-frames the finally body pushed and did not pop, so they cannot intercept.
                        if (try_stack.items.len > pr.depth) try_stack.shrinkRetainingCapacity(pr.depth);
                        var routed = false;
                        while (try_stack.pop()) |tf| {
                            if (findCatch(frame.module, &exc, tf.catches)) |h| {
                            try frame.write(h.exception_reg, try caughtValue(H, host, allocator, exc));
                                cur = h.handler;
                                routed = true;
                                break;
                            } else if (tf.finally_entry) |fin2| {
                                const key = tf.finally_done orelse fin2;
                            (try frame.pfMut()).rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                                cur = fin2;
                                routed = true;
                                break;
                            }
                        }
                        if (!routed) {
                            break :blocks errResult(.{ .Throw = exc });
                        }
                        continue;
                    }
                    // A `return`/`throw` inside finally clears the pending re-throw: its exit replaces the original.
                    if (std.meta.eql(pr.key, cur) and isReturnLike(term)) {
                        pr.exc.release(allocator);
                        (try frame.pfMut()).rethrow = null;
                    }
                }
                // Finally exit with a pending non-local return: replay through an outer finally, else unwind.
                if (frame.pf().unwind) |pu| {
                    if (std.meta.eql(pu.key, cur) and term == .Goto) {
                        const e = pu.err;
                        (try frame.pfMut()).unwind = null;
                        if (try_stack.items.len > pu.depth) try_stack.shrinkRetainingCapacity(pu.depth);
                        var routed = false;
                        while (try_stack.pop()) |tf| {
                            if (tf.finally_entry) |fin2| {
                                const key = tf.finally_done orelse fin2;
                                (try frame.pfMut()).unwind = .{ .key = key, .err = e, .depth = try_stack.items.len };
                                cur = fin2;
                                routed = true;
                                break;
                            }
                        }
                        if (!routed) break :blocks unwindTerminal(frame, e);
                        continue;
                    }
                    // A `return`/`throw` inside the finally replaces the pending non-local return.
                    if (std.meta.eql(pu.key, cur) and isReturnLike(term)) {
                        if (PendingFinallyState.payloadOfError(pu.err)) |v| v.release(allocator);
                        (try frame.pfMut()).unwind = null;
                    }
                }
                // A return or throw inside a finally replaces the flow that entered it, sentinel or not.
                if (replacesPendingBeforeRouting(term)) frame.pfRelease(allocator);
                switch (term) {
                    .Goto => |next| cur = next,
                    .Branch => |br| {
                        const v = frame.read(br.cond);
                        switch (try valueTruthy(allocator, &v)) {
                            .ok => |b| cur = if (b) br.t else br.f,
                            .err => |e| break :blocks errResult(e),
                        }
                    },
                    .Return => |maybe_r| {
                        const v = if (maybe_r) |r| frame.read(r) else Value.Unit;
                        // The value escapes this frame; retain so teardown does not free it under the caller.
                        v.retain();
                        var chosen: ?struct { i: usize, jump: BlockId, key: BlockId } = null;
                        var i: usize = try_stack.items.len;
                        while (i > 0) {
                            i -= 1;
                            if (try_stack.items[i].finally_entry) |fin| {
                                // A return from inside this frame's own finally exits through OUTER finallys only.
                                if (std.meta.eql(fin, cur)) continue;
                                const key = try_stack.items[i].finally_done orelse fin;
                                chosen = .{ .i = i, .jump = fin, .key = key };
                                break;
                            }
                        }
                        if (chosen) |c| {
                            try_stack.shrinkRetainingCapacity(c.i);
                            (try frame.pfMut()).return_value = .{ .key = c.key, .val = v, .depth = try_stack.items.len };
                            cur = c.jump;
                            continue;
                        }
                        break :blocks ok(v);
                    },
                    .Throw => |r| {
                        var exc = frame.read(r);
                        exc.retain();
                        frame.at(cur, insts.len);
                        // Capture the call stack here, in the throwing frame, before it unwinds: the
                        // instruction-loop seam sees the value only once it surfaces into the caller.
                        try attachStackTrace(allocator, &exc);
                        if (envVarSet("KLIO_THROW_TRACE")) {
                            const s = displayThrow(allocator, &exc) catch "";
                            std.debug.print("[throw-trace] from fn {s} (fqn={s}): {s}\n", .{ frame.func.name, frame.func.fqn, s });
                            if (envVarSet("KLIO_THROW_STACK")) dumpFrameChainForDiagAlways();
                        }
                        const pending_depth = frame.pf().tryDepth();
                        var routed = false;
                        while (try_stack.pop()) |tf| {
                            // Same own-finally guard as the mid-block walk: a throw from inside the finally skips the frame.
                            if (tf.finally_entry) |fin0| {
                                if (std.meta.eql(fin0, cur)) continue;
                            }
                            if (findCatch(frame.module, &exc, tf.catches)) |h| {
                                if (pending_depth) |depth| {
                                    if (try_stack.items.len < depth) frame.pfRelease(allocator);
                                }
                            try frame.write(h.exception_reg, try caughtValue(H, host, allocator, exc));
                                cur = h.handler;
                                routed = true;
                                break;
                            } else if (tf.finally_entry) |fin| {
                                frame.pfRelease(allocator);
                                const key = tf.finally_done orelse fin;
                            (try frame.pfMut()).rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                                cur = fin;
                                routed = true;
                                break;
                            }
                        }
                        if (!routed) {
                            frame.pfRelease(allocator);
                            break :blocks errResult(.{ .Throw = exc });
                        }
                    },
                    .Unreachable => {
                        break :blocks errResult(.{ .Type = "reached Terminator.Unreachable" });
                    },
                }
            }
        };
        resume_throw = null;
        resume_unwind = null;
        if (flat_site) |site| {
            // The module the callee's body must be READ against: a request that names one is
            // authoritative, the caller's module only when it actually owns this `Func`.
            const callee_mod: *const Module = site.req.run_module orelse blk_cm: {
                if (funcOwnedBy(frame.module, site.req.func)) break :blk_cm frame.module;
                if (comptime @hasDecl(H, "ownerModuleForFunc")) {
                    if (host.ownerModuleForFunc(site.req.func)) |m| break :blk_cm m;
                }
                break :blk_cm frame.module;
            };
            cur = site.ret_block;
            resume_idx = site.ret_idx;
            // Same depth bound as the recursive path: unbounded recursion becomes a catchable StackOverflowError.
            if (ev.eval_depth >= ev_state.evalDepthCap(ev)) {
                dumpFrameChainForDiag();
                discardFlatReq(ev, site.req);
                // Kotlin code catches it as `java.lang.StackOverflowError`.
                if (try ev_resolved.stackOverflowError(H, allocator, frame.module, host)) |exc| {
                    resume_throw = exc;
                } else {
                    resume_unwind = .{ .StackOverflow = "Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)" };
                }
                continue :frames;
            }
            ev.eval_depth += 1;
            const act = openActivation(ev, allocator, callee_mod, site.req) catch |e| {
                ev.eval_depth -= 1;
                discardFlatReq(ev, site.req);
                return e;
            };
            act.ret_block = site.ret_block;
            act.ret_idx = site.ret_idx;
            act.caller = top;
            top = act;
            frame = &act.frame;
            try_stack = &act.try_stack;
            cur = site.req.func.entry;
            resume_idx = 0;
            continue :frames;
        }
        // A suspension parks the current frame at its suspension point, then every outer activation
        // at its call-return point. Flat activations park LIVE by pointer; a native root snapshots.
        if (park_point) |pp| {
            const state = res.err.Suspended;
            var pb = pp.block;
            var pi = pp.inst_idx;
            var pd = pp.resume_reg;
            while (top) |a| {
                top = a.caller;
                ev.eval_depth -= 1;
                const rb = a.ret_block;
                const rix = a.ret_idx;
                const rd = a.ret_dst;
                try liveParkActivation(allocator, a, pb, pi, pd, state);
                pb = rb;
                pi = rix;
                pd = rd;
            }
            if (root_act) |ra| {
                try liveParkActivation(allocator, ra, pb, pi, pd, state);
            } else {
                try snapshotSuspendedFrame(allocator, root, root_ts, pb, pi, pd, state);
            }
            return res;
        }
        // The frame exited: deliver its result through each popped frame's boundary transforms.
        while (true) {
            const act = top orelse return res;
            top = act.caller;
            ev.eval_depth -= 1;
            if (act.frame.module.resolved == null) res = frameBoundary(act.frame.func, res);
            const rb = act.ret_block;
            const rix = act.ret_idx;
            const rd = act.ret_dst;
            teardownActivation(allocator, act);
            actFree(ev, allocator, act);
            frame = if (top) |a| &a.frame else root;
            try_stack = if (top) |a| &a.try_stack else root_ts;
            switch (res) {
                .ok => |v| try frame.write(rd, v),
                .err => |e| switch (e) {
                    .Throw => |v| resume_throw = v,
                    .NonLocalReturn, .LabeledReturn, .CalleeFailed, .StackOverflow => resume_unwind = e,
                    // Anything else exits the calling frame as-is; keep popping so each boundary applies.
                    else => continue,
                },
            }
            cur = rb;
            resume_idx = rix;
            continue :frames;
        }
    }
}

/// A function id no module has, so `streamCallee` declines it.
const NO_TARGET: u32 = std.math.maxInt(u32);

/// The implementation a virtual or interface call of `slot` runs for the instance in `args`, by
/// its class's tables; null for any other receiver, which the instruction's arm answers.
inline fn virtualTarget(frame: *const Frame, slot: u32, args: u32) ?u32 {
    const r = frame.module.resolved orelse return null;
    const recv = &frame.regs.ptr[args];
    // A null throws, and a function value or a property name answers some slots itself: the arm.
    switch (recv.*) {
        .Null, .IrClosure, .PropertyRef => return null,
        else => {},
    }
    const cls = ir.resolved.classOf(r, recv) orelse return null;
    const f = ir.resolved.slotTarget(r, cls, ir.MethodSlotId.from(slot)) orelse return null;
    return f.int();
}

/// Host function `nid` over the argument run at `args`, its result written to `dst`; what it
/// raised, if it did. A Kotlin receiver's own override of the member answers.
noinline fn hostCall(comptime H: type, allocator: Allocator, frame: *Frame, host: *H, nid: ir.NativeId, args: u32, n: u32, dst: u32, comptime reclaim: bool) Allocator.Error!?EvalError {
    const run = argRun(frame, @enumFromInt(args), n);
    const res = if (comptime @hasDecl(H, "callNativeSite"))
        (if (run.len != 0 and run[0] == .Instance)
            try host.callNativeSite(allocator, nid, run)
        else
            try host.callNative(allocator, nid, run))
    else
        try host.callNative(allocator, nid, run);
    switch (res) {
        .ok => |v| {
            writeFastR(frame, @enumFromInt(dst), v, allocator, reclaim);
            return null;
        },
        .err => |e| return e,
    }
}

/// The host function the tables bind to `fid`, when a call runs it as it is: null for an
/// interpreted body, one a host fast path fronts, or while the call hooks may inject a fault.
inline fn nativeOf(frame: *const Frame, fid: u32) ?ir.NativeId {
    const r = frame.module.resolved orelse return null;
    if (fid >= r.func_native.len or r.func_native[fid] == .none) return null;
    if (fid < r.func_try.len and r.func_try[fid] != .none) return null;
    if (parent.call_hooks_on) return null;
    return r.func_native[fid];
}

/// The callee of the static call to `fid` when the loop can run it without leaving the stream: an
/// interpreted body of a module lowered from sema, with no native or host fast path in front of
/// it, and streams whose every block ends in a stream op, so no try machinery waits at a block's
/// entry. Null sends the call through its instruction's arm.
inline fn streamCallee(frame: *const Frame, ev: *EvalTls, fid: u32) ?*const bc.FuncStreams {
    const r = frame.module.resolved orelse return null;
    if (fid == NO_TARGET) return null;
    if (fid < r.func_try.len and r.func_try[fid] != .none) return null;
    if (fid < r.func_native.len and r.func_native[fid] != .none) return null;
    if (ev.eval_depth >= ev_state.evalDepthCap(ev)) return null;
    if (parent.call_hooks_on) {
        if (!ev_flow.flatEnabled()) return null;
        if (runtime.envOnce("KLIO_FAULT_INJECT") != null) return null;
    }
    const f = frame.module.funcById(ir.FuncId.from(fid)) orelse return null;
    if (f.blocks.len == 0 and !frame.module.ensureFuncBody(@constCast(f))) return null;
    return bc.funcStreams(f, frame.module.consts.items);
}

/// A call the loop runs in the stream: the callee's streams, its parameters and captures, the
/// argument area the call pushed for them if it pushed one, and where the result goes.
const StreamTarget = struct {
    streams: *const bc.FuncStreams,
    params: []const Value,
    captures: []const Value = &.{},
    area: ?ev_state.VsMark = null,
    run_module: ?*const Module = null,
    owning: ?*const Module = null,
    closure_id: ?u64 = null,
    dst: Reg,
};

/// The constructor call `op` (`new`: inst_idx, class, ctor, args, n_args, dst, site) in the stream:
/// the instance made and held in `dst`, an argument area of it and the arguments, and the
/// constructor's streams. Null, having made nothing, for a native constructor, a throwable class
/// (its trace is taken where it is made, by the instruction's arm) or anything the arm reports.
inline fn constructTarget(
    comptime H: type,
    allocator: Allocator,
    frame: *Frame,
    ev: *EvalTls,
    host: *H,
    bs: *const bc.FuncStreams,
    op: *const [8]u32,
    comptime reclaim: bool,
) Allocator.Error!?StreamTarget {
    const r = frame.module.resolved orelse return null;
    const class = op[2];
    if (class >= r.classes.len or r.classes[class].throwable) return null;
    const st = host.resolvedState() orelse return null;
    const cfs = staticCallee(H, host, frame, ev, bs, op[3], op[7], ir.resolved.NONE) orelse return null;
    const inst = try ir.resolved.instantiate(allocator, r, ir.ClassId.from(class), ev_resolved.nextIdentity(st));
    // The register holds the instance while the constructor runs; its result, `this`, replaces it.
    writeFastR(frame, @enumFromInt(op[6]), inst, allocator, reclaim);
    const ar = try ev_frame.ArgArea.push(ev, &.{inst}, argRun(frame, @enumFromInt(op[4]), op[5]));
    return .{ .streams = cfs, .params = ar.vals, .area = ar.mark, .dst = @enumFromInt(op[6]) };
}

/// The function-value invoke `op` (`callv`: inst_idx, callee, args, n_args, dst) in the stream: a
/// lambda made from sema, taking the call's arguments, whose body's streams run in the loop, over
/// an argument area holding a copy of its captures. Null for anything else.
inline fn closureTarget(comptime H: type, frame: *Frame, ev: *EvalTls, host: *H, op: *const [6]u32) Allocator.Error!?StreamTarget {
    const callee = frame.regs.ptr[op[2]];
    if (callee != .IrClosure) return null;
    const body = host.resolvedClosure(&callee) orelse return null;
    if (body.kind != .lambda or body.arity() != op[4]) return null;
    if (ev.eval_depth >= ev_state.evalDepthCap(ev)) return null;
    if (parent.call_hooks_on and !ev_flow.flatEnabled()) return null;
    if (body.func.blocks.len == 0 and !body.module.ensureFuncBody(@constCast(body.func))) return null;
    const cfs = bc.funcStreams(body.func, body.module.consts.items) orelse return null;
    const caps = blk: {
        const g = callee.IrClosure.borrow();
        defer g.deinit();
        break :blk try ev_frame.ArgArea.push(ev, &.{}, g.get().captures);
    };
    return .{
        .streams = cfs,
        .params = argRun(frame, @enumFromInt(op[3]), op[4]),
        .captures = caps.vals,
        .area = caps.mark,
        .run_module = body.module,
        .owning = body.owning,
        .closure_id = body.id,
        .dst = @enumFromInt(op[5]),
    };
}

/// `streamCallee` for the static call at `site` of the running function's streams `bs`, which keep
/// the callee the site's first run resolved: a callee's tables and streams do not change, so a
/// later run only checks the depth and the hooks.
inline fn staticCallee(comptime H: type, host: *H, frame: *const Frame, ev: *EvalTls, bs: *const bc.FuncStreams, fid: u32, site: u32, init: u32) ?*const bc.FuncStreams {
    if (bs.callees[site].load(.acquire)) |cfs| {
        if (ev.eval_depth < ev_state.evalDepthCap(ev) and !parent.call_hooks_on) return cfs;
    }
    // A unit, once run, stays run: the site keeps its callee only after the call's has.
    if (!ev_resolved.unitReady(H, host, init)) return null;
    const cfs = streamCallee(frame, ev, fid) orelse return null;
    bs.callees[site].store(cfs, .release);
    return cfs;
}

/// `KLIO_FN_PROF`'s attribution swap, out of line: `current_fn` is a threadlocal, and an
/// inline read is hoisted above the flag test into every frame entry.
noinline fn fnProfEnter(fid: u32) u32 {
    const prev = runtime.prof.current_fn;
    runtime.prof.current_fn = fid;
    return prev;
}

noinline fn fnProfLeave(prev: u32) void {
    runtime.prof.current_fn = prev;
}

fn isReturnLike(term: Terminator) bool {
    return switch (term) {
        .Return, .Throw => true,
        else => false,
    };
}

fn replacesPendingBeforeRouting(term: Terminator) bool {
    return term == .Return;
}

/// What entering block `cur` does to the try stack. Normal flow into a catch-only try's join
/// pops the body's frame (`Block.catch_done_for`). Entering a finally disarms its try frame:
/// the region's catches and the finally itself must not capture anything raised inside it, and
/// a frame still armed here is the normal-completion entry; keyed on block entry, since a
/// multi-block finally leaves the exit-side pop unreached while later blocks run. A block that
/// opens a try region pushes its frame.
fn enterTryBlock(allocator: Allocator, try_stack: *std.ArrayList(TryFrame), block: *const ir.Block, cur: BlockId) Allocator.Error!void {
    const h = block.h();
    if (h.catch_done_for) |body| {
        if (rpositionByBody(try_stack.items, body)) |p| _ = try_stack.orderedRemove(p);
    }
    if (rpositionByFinallyEntry(try_stack.items, cur)) |p| _ = try_stack.orderedRemove(p);
    if (h.catches.len != 0 or h.finally != null) {
        try try_stack.append(allocator, .{
            .body = cur,
            .catches = h.catches,
            .finally_entry = h.finally,
            .finally_done = h.finally_done,
        });
    }
}

/// What a Goto out of block `cur` does to the try stack with no finally flow pending: normal
/// flow through a finally pops its frame, at the done sentinel or the finally's own entry, and
/// an inline `return` jumping to its join pops the frames it bypassed the sentinels of.
fn leaveTryBlock(try_stack: *std.ArrayList(TryFrame), block: *const ir.Block, cur: BlockId) void {
    const pos: ?usize = if (block.h().finally_done_for) |body|
        rpositionByBody(try_stack.items, body)
    else
        rpositionByFinallyEntry(try_stack.items, cur);
    if (pos) |p| _ = try_stack.orderedRemove(p);
    popOnExit(try_stack, block);
}

fn popOnExit(try_stack: *std.ArrayList(TryFrame), block: *const ir.Block) void {
    for (block.h().pop_on_exit) |body| {
        if (rpositionByBody(try_stack.items, body)) |p| _ = try_stack.orderedRemove(p);
    }
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

/// The first handler that takes `exc`. A handler lowered from sema names its
/// class and matches by the class tables; any other matches by type name.
/// The value a catch handler binds: what was thrown, or for a host
/// exception caught in code lowered from sema, the instance the host makes
/// of it, which that code reads like any other.
fn caughtValue(comptime H: type, host: *H, allocator: Allocator, exc: Value) Allocator.Error!Value {
    if (comptime @hasDecl(H, "caughtValue")) return host.caughtValue(allocator, exc);
    return exc;
}

fn findCatch(module: *const Module, exc: *const Value, catches: []const ir.CatchHandler) ?ir.CatchHandler {
    const r = module.resolved orelse return null;
    const have = ir.resolved.classOf(r, exc) orelse return null;
    for (catches) |h| {
        if (ir.resolved.isA(module, have, h.class)) return h;
    }
    return null;
}

/// Destination register of a value-producing instruction, for routing a resume value back.
fn instDst(inst: *const Inst) ?Reg {
    return switch (inst.*) {
        .CallStatic => |x| x.dst,
        .RCallVirtual => |x| x.dst,
        .CallInterface => |x| x.dst,
        .CallNative => |x| x.dst,
        .RCallValue => |x| x.dst,
        .RNewInstance => |x| x.dst,
        .LoadObject => |x| x.dst,
        .LoadStatic => |x| x.dst,
        else => null,
    };
}

/// Shared post-step control flow for both instruction loops: flat-call handoff, throw and
/// non-local-return capture, suspension parking. `.brk` breaks to the block's unwind
/// handling with `thrown`/`unwound` set; `.ret` returns `ret.*` from the frame.
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
        const req = frame.tls.flat_call.?;
        frame.tls.flat_call = null;
        flat_out.* = .{ .req = req, .ret_block = cur, .ret_idx = idx + 1 };
        ret.* = ok(.Unit);
        return .ret;
    }
    if (r == .raised) {
        const e = frame.tls.step_err.?;
        frame.tls.step_err = null;
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

/// The bytecode tier's inline BinOp path: same-tag Int/Long scalar arithmetic and
/// comparison written into the register file with `applyBinop`'s exact same-tag
/// semantics. Every other shape returns false, so the generic arm runs.
pub inline fn binFast(frame: *Frame, op: BinOp, dst: Reg, lhs: Reg, rhs: Reg, allocator: Allocator, reclaim: bool) bool {
    // Register indices are proven in bounds by stream build and the entry length check.
    const regs = frame.regs.ptr;
    const lv = regs[lhs.int()];
    const rv = regs[rhs.int()];
    const out: Value = scalarBin(op, lv, rv) orelse return false;
    const old = regs[dst.int()];
    regs[dst.int()] = out;
    frame.wmask.setInWindow(dst.int());
    if (reclaim) old.release(allocator);
    return true;
}

/// The scalar UnOp core, mirroring `binFast`.
pub inline fn unopFast(frame: *Frame, op: ir.UnOp, dst: Reg, src: Reg, allocator: Allocator, reclaim: bool) bool {
    const regs = frame.regs.ptr;
    const out: Value = scalarUn(op, regs[src.int()]) orelse return false;
    const old = regs[dst.int()];
    regs[dst.int()] = out;
    frame.wmask.setInWindow(dst.int());
    if (reclaim) old.release(allocator);
    return true;
}

/// `applyUnop`'s exact semantics for the scalar tags; null for everything else,
/// including the widening `Byte`/`Short` negations and the NaN sign rules the
/// arm spells out.
pub inline fn scalarUn(op: ir.UnOp, v: Value) ?Value {
    return switch (op) {
        .Inc => switch (v) {
            .Int => |i| .{ .Int = i +% 1 },
            .Long => |l| .{ .Long = l +% 1 },
            .Char => |c| .{ .Char = c +% 1 },
            .UInt => |x| .{ .UInt = x +% 1 },
            .ULong => |x| .{ .ULong = x +% 1 },
            else => null,
        },
        .Dec => switch (v) {
            .Int => |i| .{ .Int = i -% 1 },
            .Long => |l| .{ .Long = l -% 1 },
            .Char => |c| .{ .Char = c -% 1 },
            .UInt => |x| .{ .UInt = x -% 1 },
            .ULong => |x| .{ .ULong = x -% 1 },
            else => null,
        },
        .Neg => switch (v) {
            .Int => |i| .{ .Int = -%i },
            .Long => |l| .{ .Long = -%l },
            else => null,
        },
        .Plus => switch (v) {
            .Int, .Long, .Double, .Float => v,
            else => null,
        },
    };
}

/// The shared same-tag scalar BinOp core with `applyBinop`'s exact semantics. Null for
/// every shape the generic arm must handle (mixed non-integer tags, zero divisors,
/// boxed equality on mixed widths, Cells, ===).
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
        // A Double against a Float compares as Double under IEEE, so `0.0 != -0.0F` is false.
        // Boxed equality stays tag-sensitive and falls through.
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
        // Mixed widths promote to Long, as `applyBinop` does. Boxed equality stays
        // tag-sensitive (`(1 as Any) != (1L as Any)`) and falls through.
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
            // The logical trio lowers to a BinOp only when the static types agree, but a literal's
            // runtime tag can be narrower than its declared Long: compute wide.
            .And => .{ .Long = a & b },
            .Or => .{ .Long = a | b },
            .Xor => .{ .Long = a ^ b },
            // Long shifts take an Int count and use its low 6 bits, JVM-style.
            .Shl => if (lv == .Long) .{ .Long = @as(i64, @bitCast(@as(u64, @bitCast(a)) << @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)))) } else break :blk null,
            .Shr => if (lv == .Long) .{ .Long = a >> @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)) } else break :blk null,
            .UShr => if (lv == .Long) .{ .Long = @as(i64, @bitCast(@as(u64, @bitCast(a)) >> @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)))) } else break :blk null,
            else => break :blk null,
        };
    } else null;
}

/// The frame loop's per-block-entry guards, run on a call and on an edge a stream takes itself to
/// its own or an earlier block: every cycle has such an edge and every recursion a call, so each
/// loop reaches abandonment, the spin/wall diagnostic and the GC safe point, and a run between
/// two polls is bounded by one function. Non-null aborts the frame.
pub inline fn edgeGuard(allocator: Allocator, ftls: *EvalTls) ?EvalResult {
    runtime.assertNoCellLock();
    if (runtime.shouldAbandon()) {
        return errResult(.{ .Type = "daemon task abandoned at run boundary" });
    }
    ftls.spin_check_counter +%= 1;
    if (ftls.spin_check_counter & 0xFFFF == 0) {
        spinDumpMaybe();
        if (runtime.gc.gc_enabled) runtime.gc.idleProbeNow();
        const wall_dl = parent.test_wall_deadline_ms.load(.monotonic);
        if (wall_dl != 0 and nowMonotonicMs() > wall_dl) {
            return wallCapFire(allocator) catch
                errResult(.{ .Type = "test wall-clock deadline exceeded" });
        }
    }
    if (runtime.gc.gc_enabled and runtime.gc.pendingFlag()) {
        runtime.gc.safePoint();
    }
    return null;
}

/// The instruction an op stands for, for the op's slow path: the op itself carries its operands.
inline fn instAt(frame: *const Frame, block: BlockId, idx: usize) *const Inst {
    return &frame.func.blocks[block.int()].insts[idx];
}

/// Whether comparing `a` with `b` gives an outcome in `mask`, a compare's order mask.
inline fn holds(mask: u32, a: anytype, b: @TypeOf(a)) bool {
    const order: u5 = @as(u5, @intFromBool(a >= b)) + @intFromBool(a > b);
    return (mask >> order) & 1 != 0;
}

/// Unchecked register store for the bytecode loop's simple ops; the index was validated
/// at stream build. Takes ownership of `v`; `reclaim` is the run's reclaim flag.
pub inline fn writeFastR(frame: *Frame, r: Reg, v: Value, allocator: Allocator, reclaim: bool) void {
    const idx = r.int();
    const old = frame.regs.ptr[idx];
    frame.regs.ptr[idx] = v;
    frame.wmask.setInWindow(idx);
    if (reclaim) old.release(allocator);
}

/// The string of constant `cid` for a `const_str` site whose `slot` holds none yet: made in the
/// permanent generation, as the image's constants are, and published to the slot. A site two
/// threads fill at once keeps the first string; the other is left to the permanent generation.
noinline fn internString(allocator: Allocator, frame: *const Frame, cid: u32, slot: *std.atomic.Value(usize)) Allocator.Error!Value {
    const saved = runtime.gc.alloc_perm;
    runtime.gc.alloc_perm = true;
    defer runtime.gc.alloc_perm = saved;
    const v = try constToValue(allocator, &frame.module.consts.items[cid]);
    if (slot.cmpxchgStrong(0, @intFromPtr(v.String.cell), .release, .acquire)) |won| {
        return .{ .String = .{ .cell = @ptrFromInt(won) } };
    }
    return v;
}

/// Leave the exit span the op carries at `at` on the frame, when its block has one.
inline fn leaveSpan(frame: *Frame, code: []const u32, at: usize) void {
    if (code[at] == bc.NO_SPAN) return;
    frame.cur_span = .{ .file = @enumFromInt(code[at]), .start = code[at + 1], .end = code[at + 2] };
}

/// The op at `pc`: every stream ends in an `end` op, so the read stays in bounds.
inline fn opAt(code: []const u32, pc: usize) bc.Op {
    return @enumFromInt(code[pc]);
}
