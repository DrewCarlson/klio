//! The stream loop: every op of a function's code (`bc.Op`) is a function of its own, which runs
//! the op and tail-calls the next op's function. The state every op reads travels in argument
//! registers: the running frame, its registers, the code, the pc and the block. Everything else
//! the loop keeps (the open activations, the try stack, the running function's streams, what an
//! exit hands the frame loop) is in `Ctx`, in memory. An op's function decides only its own
//! registers, so a change to one op leaves the code of every other as it was.
//!
//! An op leaves the loop by returning an `Exit`, which the frame loop in `exec.zig` acts on.
//!
//! A compiler backend that emits no tail calls (Zig's own x86_64 backend, a Debug build's default
//! on Linux) runs the same functions from `run`'s loop instead: each returns `.cont` with the next
//! op's state in `Ctx.then`.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const bc = @import("../bc.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const BinOp = ir.BinOp;
const BlockId = ir.BlockId;
const Func = ir.Func;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;

const parent = @import("../eval.zig");
const ev_exec = @import("exec.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_inst = @import("inst.zig");
const ev_activation = @import("activation.zig");
const ev_enter = @import("enter.zig");
const ev_resolved = @import("resolved.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");
const ev_diag = @import("diag.zig");

const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const Activation = ev_flow.Activation;
const FlatCallSite = ev_flow.FlatCallSite;
const Frame = ev_frame.Frame;
const ParkPoint = ev_flow.ParkPoint;
const Step = ev_flow.Step;
const TryFrame = ev_snapshot.TryFrame;
const argRun = ev_frame.argRun;
const ok = ev_flow.ok;

/// Whether the compiler emits the ops' tail calls.
const tail_calls = @import("builtin").zig_backend == .stage2_llvm;
const errResult = ev_flow.errResult;
const attachStackTrace = ev_diag.attachStackTrace;
const constToValue = ev_values.constToValue;
const nowMonotonicMs = ev_diag.nowMonotonicMs;
const spinDumpMaybe = ev_diag.spinDumpMaybe;
const wallCapFire = ev_diag.wallCapFire;

/// Why a stream left the loop, for the frame loop to act on.
pub const Exit = enum(u8) {
    /// A throw or a non-local return to route (`Ctx.thrown`, `Ctx.unwound`), or the block's
    /// terminator to run: the frame loop goes on from the block's routing.
    brk,
    /// The frame's result is `Ctx.ret_v`, a flat call or a suspension set by `afterStep`.
    ret,
    /// The frame's result is `Ctx.result`: its return, or what an edge's guard aborted with.
    result,
    /// The frame loop runs block `Ctx.blk` from `Ctx.resume_idx`.
    block,
    /// An allocation failed.
    oom,
    /// Where tail calls are not emitted: the next op to run is `Ctx.then`.
    cont,
};

pub fn Stream(comptime H: type, comptime reclaim: bool) type {
    return struct {
        const S = @This();

        /// What the loop keeps besides the hot state, and what an exit hands back.
        pub const Ctx = struct {
            allocator: Allocator,
            host: *H,
            ev: *EvalTls,
            root: *Frame,
            root_ts: *std.ArrayList(TryFrame),
            /// The innermost open activation; each links to the one that called it.
            top: ?*Activation = null,
            try_stack: *std.ArrayList(TryFrame),
            func: *const Func,
            /// The running function's streams.
            bs: *const bc.FuncStreams,
            flat_out: *?FlatCallSite = undefined,
            park_out: *?ParkPoint = undefined,
            thrown: ?Value = null,
            unwound: ?EvalError = null,
            ret_v: EvalResult = ok(.Unit),
            result: EvalResult = ok(.Unit),
            /// The frame and block the stream stood in when it left.
            frame: *Frame,
            blk: u32 = 0,
            resume_idx: usize = 0,
            /// The block an edge whose guards run goes to.
            edge_blk: u32 = 0,
            /// A call on its way to `enterSlow`.
            target: Target = undefined,
            /// The host function a `vcall` site keeps, on its way to `vcallNative`.
            native: ir.NativeId = undefined,
            /// A callee whose body only stores fields, on its way to `callLeaf` or `vcallLeaf`.
            leaf: *const bc.FuncStreams = undefined,
            /// Where tail calls are not emitted: the op `run`'s loop runs next, and its state.
            then: Then = undefined,
        };

        const Then = struct {
            h: Handler,
            frame: *Frame,
            regs: [*]Value,
            code: [*]const u32,
            pc: usize,
            blk: u32,
        };

        /// A call the stream makes: the callee's streams and module, its parameters and captures,
        /// the argument area the call pushed for them if it pushed one, the closure it runs, where
        /// its result goes, the call's instruction and where the caller goes on.
        const Target = struct {
            sc: *const bc.FuncStreams,
            module: *const Module,
            params: []const Value,
            captures: []const Value = &.{},
            area: ?ev_state.VsMark = null,
            closure: ?runtime.IrClosureRef = null,
            owning: ?*const Module = null,
            dst: Reg,
            idx: usize,
            ret_pc: usize,
        };

        const Handler = *const fn (c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit;

        const table: [@typeInfo(bc.Op).@"enum".fields.len]Handler = blk: {
            var t: [@typeInfo(bc.Op).@"enum".fields.len]Handler = undefined;
            for (@typeInfo(bc.Op).@"enum".fields) |f| t[f.value] = handlerOf(@enumFromInt(f.value));
            break :blk t;
        };

        /// The ops' slow paths. Read through a volatile pointer, which the optimizer cannot read
        /// ahead of time, so none is folded into the op that leaves for it and a fast path makes
        /// no call.
        const Cold = enum { slow2, slow4, slow5, slow6, slow8, bin_wide, bin_arm, bin_k_wide, cmp_br_wide, cmp_br_k_wide, call_host, vcall_host, edge_slow, array_get_wide, enter_slow, call_slow, ret_slow, vcall_slow, vcall_native, call_leaf, vcall_leaf };
        var cold: [@typeInfo(Cold).@"enum".fields.len]Handler = .{
            Slow(2).f, Slow(4).f, Slow(5).f, Slow(6).f, Slow(8).f, binWide, binArm, binKWide, cmpBrWide, cmpBrKWide, callHost, vcallHost, edgeSlow, arrayGetWide, enterSlow, callSlow, retSlow, vcallSlow, vcallNative, callLeaf, vcallLeaf,
        };

        inline fn toCold(comptime which: Cold, c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const t: *volatile const @TypeOf(cold) = &cold;
            return jump(t[@intFromEnum(which)], c, frame, regs, code, pc, blk);
        }

        fn handlerOf(comptime op: bc.Op) Handler {
            return switch (op) {
                .end => opEnd,
                .block_entry => opBlockEntry,
                .goto_try => opGotoTry,
                .const_val => opConstVal,
                .const_load => opConstLoad,
                .const_str => opConstStr,
                .const_int => opConstInt,
                .move => opMove,
                .load_param => opLoadParam,
                .load_params => opLoadParams,
                .make_cell => opMakeCell,
                .cell_set => opCellSet,
                .store_static => opStoreStatic,
                .make_closure => opMakeClosure,
                .new_array => opNewArray,
                .box_value => opBoxValue,
                .unbox_value => opUnboxValue,
                .load_capture => opLoadCapture,
                .load_static => opLoadStatic,
                .is => opIs,
                .cast => opCast,
                .cell_get => opCellGet,
                .bin => opBin,
                .add => opAdd,
                .sub => opSub,
                .cmp => opCmp,
                .un => opUn,
                inline .bin_mul, .bin_div, .bin_mod, .bin_and, .bin_or, .bin_xor, .bin_shl, .bin_shr, .bin_ushr, .bin_ident_eq, .bin_ident_neq => |o| BinH(bc.binOperator(o).?).f,
                inline .un_inc, .un_dec, .un_neg => |o| UnH(bc.unOperator(o).?).f,
                inline .conv_byte, .conv_short, .conv_int, .conv_long, .conv_float, .conv_double, .conv_char => |o| ConvH(bc.convTarget(o).?).f,
                inline .fn_inv, .fn_to_raw_bits, .fn_to_bits, .fn_float_from_bits, .fn_double_from_bits, .fn_count_trailing_zero_bits, .fn_uint_to_float, .fn_uint_to_double, .fn_ulong_to_float, .fn_ulong_to_double, .fn_sin, .fn_cos, .fn_sqrt, .fn_to_ulong, .fn_to_uint, .fn_to_ushort, .fn_to_ubyte, .fn_unsigned_bits => |o| FnH(bc.fnOf(o).?).f,
                .call => opCall,
                .vcall => opVcall,
                .new => opNew,
                .callv => opCallv,
                .native => opNative,
                .array_get => opArrayGet,
                .array_set => opArraySet,
                .load_object => opLoadObject,
                .not => opNot,
                .get_field => opGetField,
                .set_field => opSetField,
                .escape => opEscape,
                .jump => opJump,
                .br => opBr,
                .cmp_br => opCmpBr,
                .ret_try => opRetTry,
                .ret => opRet,
                .term_exit => opTermExit,
                inline .bin_k_add, .bin_k_sub, .bin_k_mul, .bin_k_div, .bin_k_mod, .bin_k_less, .bin_k_less_eq, .bin_k_greater, .bin_k_greater_eq, .bin_k_eq, .bin_k_not_eq, .bin_k_boxed_eq, .bin_k_boxed_not_eq, .bin_k_and, .bin_k_or, .bin_k_xor, .bin_k_shl, .bin_k_shr, .bin_k_ushr, .bin_k_ident_eq, .bin_k_ident_neq => |o| BinK(bc.kOperator(o).?).f,
                inline .cmp_br_k_less, .cmp_br_k_less_eq, .cmp_br_k_greater, .cmp_br_k_greater_eq, .cmp_br_k_eq, .cmp_br_k_not_eq, .cmp_br_k_boxed_eq, .cmp_br_k_boxed_not_eq, .cmp_br_k_ident_eq, .cmp_br_k_ident_neq => |o| CmpBrK(bc.kOperator(o).?).f,
            };
        }

        /// Runs the stream from `pc` of `code` in block `blk` of `frame`'s function until an op
        /// leaves the loop.
        pub fn run(c: *Ctx, frame: *Frame, code: [*]const u32, pc: usize, blk: u32) Exit {
            var e = table[code[pc]](c, frame, frame.regs.ptr, code, pc, blk);
            if (tail_calls) return e;
            while (e == .cont) {
                const t = c.then;
                e = t.h(c, t.frame, t.regs, t.code, t.pc, t.blk);
            }
            return e;
        }

        /// The op at `pc`, run in place of the caller.
        inline fn next(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            return jump(table[code[pc]], c, frame, regs, code, pc, blk);
        }

        /// Handler `h`, run in place of the caller: a tail call, or where none is emitted, the next
        /// turn of `run`'s loop.
        inline fn jump(h: Handler, c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            if (tail_calls) return @call(.always_tail, h, .{ c, frame, regs, code, pc, blk });
            c.then = .{ .h = h, .frame = frame, .regs = regs, .code = code, .pc = pc, .blk = blk };
            return .cont;
        }

        inline fn leave(c: *Ctx, e: Exit, frame: *Frame, blk: u32) Exit {
            c.frame = frame;
            c.blk = blk;
            return e;
        }

        /// Writes `v` to register `dst`, taking ownership of it; the index was validated when the
        /// stream was built.
        inline fn put(c: *Ctx, frame: *Frame, regs: [*]Value, dst: u32, v: Value) void {
            const old = regs[dst];
            regs[dst] = v;
            frame.wmask.setInWindow(dst);
            if (reclaim) old.release(c.allocator);
        }

        inline fn leaveSpan(frame: *Frame, code: [*]const u32, at: usize) void {
            if (code[at] == bc.NO_SPAN) return;
            frame.cur_span = .{ .file = @enumFromInt(code[at]), .start = code[at + 1], .end = code[at + 2] };
        }

        inline fn instAt(frame: *const Frame, blk: u32, idx: usize) *const Inst {
            return &frame.func.blocks[blk].insts[idx];
        }

        /// An edge to block `target` at `tpc`: one to the same or an earlier block runs the loop's
        /// guards first, `edgeGuard`'s test here and its work in `edgeSlow`.
        inline fn edge(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, target: u32, tpc: usize, blk: u32) Exit {
            if (target <= blk) {
                runtime.assertNoCellLock();
                c.ev.spin_check_counter +%= 1;
                if (runtime.gc.edgeFlagsWord() != 0 or c.ev.spin_check_counter & 0xFFFF == 0) {
                    c.edge_blk = target;
                    return toCold(.edge_slow, c, frame, regs, code, tpc, blk);
                }
            }
            return next(c, frame, regs, code, tpc, target);
        }

        /// An edge from `blk` to block `Ctx.edge_blk` at `pc` whose guards have work to do.
        fn edgeSlow(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            @branchHint(.cold);
            _ = regs;
            if (edgeGuardSlow(c.allocator, c.ev)) |er| {
                c.result = er;
                return leave(c, .result, frame, blk);
            }
            return next(c, frame, frame.regs.ptr, code, pc, c.edge_blk);
        }

        /// What an instruction's arm left: the next op at `npc`, or an exit.
        inline fn after(c: *Ctx, frame: *Frame, code: [*]const u32, npc: usize, blk: u32, r: Step, inst: *const Inst, idx: usize) Exit {
            const a = afterStep(c.allocator, frame, r, inst, idx, @enumFromInt(blk), c.flat_out, c.park_out, &c.thrown, &c.unwound, &c.ret_v) catch return .oom;
            return switch (a) {
                .cont => next(c, frame, frame.regs.ptr, code, npc, blk),
                .brk => leave(c, .brk, frame, blk),
                .ret => leave(c, .ret, frame, blk),
            };
        }

        /// The instruction of an op `len` words long, run by its arm in `execInst`.
        fn Slow(comptime len: usize) type {
            return struct {
                fn f(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
                    @branchHint(.cold);
                    _ = regs;
                    const idx: usize = code[pc + 1];
                    const inst = instAt(frame, blk, idx);
                    frame.at(@enumFromInt(blk), idx);
                    const r = ev_inst.execInst(H, c.allocator, frame, inst, c.host) catch return .oom;
                    return after(c, frame, code, pc + len, blk, r, inst, idx);
                }
            };
        }

        inline fn slow(comptime len: usize, c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const which: Cold = switch (len) {
                2 => .slow2,
                4 => .slow4,
                5 => .slow5,
                6 => .slow6,
                8 => .slow8,
                else => @compileError("no slow path for an op of this length"),
            };
            return toCold(which, c, frame, regs, code, pc, blk);
        }

        fn opEnd(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            leaveSpan(frame, code, pc + 1);
            return leave(c, .brk, frame, blk);
        }

        fn opBlockEntry(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            ev_exec.enterTryBlock(c.try_stack, &frame.func.blocks[blk], @enumFromInt(blk)) catch return .oom;
            return next(c, frame, regs, code, pc + 1, blk);
        }

        fn opGotoTry(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            leaveSpan(frame, code, pc + 3);
            // A return, a throw or a non-local return passing through a finally takes the frame
            // loop's routing.
            if (frame.pending) |p| if (p.tryDepth() != null) {
                c.resume_idx = std.math.maxInt(usize);
                return leave(c, .block, frame, blk);
            };
            ev_exec.leaveTryBlock(c.try_stack, &frame.func.blocks[blk], @enumFromInt(blk));
            return edge(c, frame, regs, code, code[pc + 1], code[pc + 2], blk);
        }

        fn opConstVal(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            put(c, frame, regs, code[pc + 1], c.bs.values[code[pc + 2]]);
            return next(c, frame, regs, code, pc + 3, blk);
        }

        fn opConstLoad(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const v = constToValue(c.allocator, &frame.module.consts.items[code[pc + 2]]) catch return .oom;
            put(c, frame, regs, code[pc + 1], v);
            return next(c, frame, regs, code, pc + 3, blk);
        }

        fn opConstStr(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const slot = &c.bs.strings[code[pc + 3]];
            const raw = slot.load(.acquire);
            const v: Value = if (raw != 0)
                .{ .String = .{ .cell = @ptrFromInt(raw) } }
            else
                internString(c.allocator, frame, code[pc + 2], slot) catch return .oom;
            if (reclaim) v.retain();
            put(c, frame, regs, code[pc + 1], v);
            return next(c, frame, regs, code, pc + 4, blk);
        }

        fn opConstInt(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            if (reclaim) regs[code[pc + 1]].release(c.allocator);
            regs[code[pc + 1]] = .{ .Int = @bitCast(code[pc + 2]) };
            frame.wmask.setInWindow(code[pc + 1]);
            return next(c, frame, regs, code, pc + 3, blk);
        }

        fn opMove(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const v = regs[code[pc + 2]];
            if (reclaim) v.retain();
            put(c, frame, regs, code[pc + 1], v);
            return next(c, frame, regs, code, pc + 3, blk);
        }

        fn opLoadParam(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const pidx: usize = code[pc + 2];
            const v = if (pidx < frame.params.len) frame.params[pidx] else Value.Unit;
            if (reclaim) v.retain();
            put(c, frame, regs, code[pc + 1], v);
            return next(c, frame, regs, code, pc + 3, blk);
        }

        fn opLoadParams(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const n: usize = code[pc + 1];
            loadParams(c, frame, regs, code[pc + 2 .. pc + 2 + 2 * n]);
            return next(c, frame, regs, code, pc + 2 + 2 * n, blk);
        }

        /// Writes each (dst, idx) pair's parameter into its register, as the entry block's
        /// `LoadParam`s would.
        inline fn loadParams(c: *Ctx, frame: *Frame, regs: [*]Value, pairs: []const u32) void {
            var k: usize = 0;
            while (k < pairs.len) : (k += 2) {
                const idx = pairs[k + 1];
                const v = if (idx < frame.params.len) frame.params[idx] else Value.Unit;
                if (reclaim) v.retain();
                put(c, frame, regs, pairs[k], v);
            }
        }

        fn opMakeCell(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const v = regs[code[pc + 2]];
            v.retain();
            const cell = Value.newCell(c.allocator, v) catch return .oom;
            put(c, frame, regs, code[pc + 1], cell);
            return next(c, frame, regs, code, pc + 3, blk);
        }

        fn opCellSet(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const cell = regs[code[pc + 2]];
            if (cell == .Cell) {
                const v = regs[code[pc + 3]];
                v.retain();
                const g = cell.Cell.borrowMut();
                const old = g.get().*;
                g.get().* = v;
                g.deinit();
                if (reclaim) old.release(c.allocator);
                return next(c, frame, regs, code, pc + 4, blk);
            }
            return slow(4, c, frame, regs, code, pc, blk);
        }

        fn opStoreStatic(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            if (ev_resolved.storeReadyStatic(H, c.allocator, frame, c.host, code[pc + 2], regs[code[pc + 3]]))
                return next(c, frame, regs, code, pc + 4, blk);
            return slow(4, c, frame, regs, code, pc, blk);
        }

        fn opMakeClosure(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            const idx: usize = code[pc + 1];
            const inst = instAt(frame, blk, idx);
            frame.at(@enumFromInt(blk), idx);
            // The arm itself, without the instruction switch in front of it.
            const r = ev_resolved.execMakeClosure(H, c.allocator, frame, inst.MakeClosure, c.host) catch return .oom;
            if (r == .cont) return next(c, frame, frame.regs.ptr, code, pc + 2, blk);
            return after(c, frame, code, pc + 2, blk, r, inst, idx);
        }

        fn opNewArray(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            const idx: usize = code[pc + 1];
            const inst = instAt(frame, blk, idx);
            frame.at(@enumFromInt(blk), idx);
            const r = ev_resolved.execNewArray(H, c.allocator, frame, inst.NewArray, c.host) catch return .oom;
            if (r == .cont) return next(c, frame, frame.regs.ptr, code, pc + 2, blk);
            return after(c, frame, code, pc + 2, blk, r, inst, idx);
        }

        /// `BoxValue` on an instance or a null, which is itself; a number takes the arm, which
        /// makes the instance.
        fn opBoxValue(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const v = regs[code[pc + 3]];
            if (v != .Instance and v != .Null) return slow(6, c, frame, regs, code, pc, blk);
            if (reclaim) v.retain();
            put(c, frame, regs, code[pc + 2], v);
            return next(c, frame, regs, code, pc + 6, blk);
        }

        fn opUnboxValue(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const v = ev_resolved.unboxValue(regs[code[pc + 3]], code[pc + 4], code[pc + 5]);
            if (reclaim) v.retain();
            put(c, frame, regs, code[pc + 2], v);
            return next(c, frame, regs, code, pc + 6, blk);
        }

        fn opLoadCapture(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const cidx: usize = code[pc + 2];
            const v = if (cidx < frame.captures.len) frame.captures[cidx] else Value.Unit;
            if (reclaim) v.retain();
            put(c, frame, regs, code[pc + 1], v);
            return next(c, frame, regs, code, pc + 3, blk);
        }

        fn opLoadStatic(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            if (ev_resolved.readyStatic(H, frame, c.host, code[pc + 3])) |v| {
                if (reclaim) v.retain();
                put(c, frame, regs, code[pc + 2], v);
                return next(c, frame, regs, code, pc + 4, blk);
            }
            return slow(4, c, frame, regs, code, pc, blk);
        }

        /// `is` (`as` when `is_cast`) on a value the tables classify; a failing `as` and a function
        /// value take the instruction's arm.
        inline fn isOrCast(comptime is_cast: bool, c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const v = regs[code[pc + 3]];
            const flags = code[pc + 5];
            if (ev_resolved.quickIsA(frame, &v, code[pc + 4], flags & 1 != 0)) |yes| {
                if (!is_cast) {
                    put(c, frame, regs, code[pc + 2], .{ .Bool = yes });
                    return next(c, frame, regs, code, pc + 6, blk);
                }
                if (yes or flags & 2 != 0) {
                    const out: Value = if (yes) v else .Null;
                    if (reclaim) out.retain();
                    put(c, frame, regs, code[pc + 2], out);
                    return next(c, frame, regs, code, pc + 6, blk);
                }
            }
            return slow(6, c, frame, regs, code, pc, blk);
        }

        fn opIs(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            return isOrCast(false, c, frame, regs, code, pc, blk);
        }

        fn opCast(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            return isOrCast(true, c, frame, regs, code, pc, blk);
        }

        fn opCellGet(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const v = switch (regs[code[pc + 2]]) {
                .Cell => |cl| vblk: {
                    const g = cl.borrow();
                    defer g.deinit();
                    break :vblk g.get().*;
                },
                else => |other| other,
            };
            if (reclaim) v.retain();
            put(c, frame, regs, code[pc + 1], v);
            return next(c, frame, regs, code, pc + 3, blk);
        }

        fn opBin(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            // Same-tag scalar operands take an inline path with the exact `applyBinop` semantics;
            // anything else, a zero divisor included, falls through.
            const op: BinOp = @enumFromInt(code[pc + 2] & 0xff);
            const l = regs[code[pc + 4]];
            const r = regs[code[pc + 5]];
            if (ev_exec.scalarBin(op, l, r) orelse floatQuick(op, l, r) orelse eqQuick(op, l, r)) |out| {
                put(c, frame, regs, code[pc + 3], out);
                return next(c, frame, regs, code, pc + 6, blk);
            }
            return toCold(.bin_wide, c, frame, regs, code, pc, blk);
        }

        fn isIdentity(op: BinOp) bool {
            return op == .IdentEq or op == .IdentNeq;
        }

        /// `===` (`!==` negated) where one side is null or both are instances, as `referenceEq`
        /// answers it; null for anything else, a captured variable's cell included, which the
        /// instruction's arm reads through.
        inline fn identQuick(op: BinOp, l: Value, r: Value) ?Value {
            if (l == .Cell or r == .Cell) return null;
            const same = if (l == .Null or r == .Null)
                l == .Null and r == .Null
            else if (l == .Instance and r == .Instance)
                runtime.ObjRef(runtime.InstanceData).ptrEq(l.Instance, r.Instance)
            else
                return null;
            return .{ .Bool = same != (op == .IdentNeq) };
        }

        /// `==` and `!=`, boxed or not, between two unsigned numbers of one type, two Bools, or a
        /// null and anything but a captured variable's cell, which the instruction's arm reads
        /// through; null for any other operator or pair.
        inline fn eqQuick(op: BinOp, l: Value, r: Value) ?Value {
            const neg = switch (op) {
                .Eq, .BoxedEq => false,
                .NotEq, .BoxedNotEq => true,
                else => return null,
            };
            if (l == .Cell or r == .Cell) return null;
            const eq = if (l == .Null or r == .Null)
                l == .Null and r == .Null
            else switch (l) {
                .ULong => |x| if (r == .ULong) x == r.ULong else return null,
                .UInt => |x| if (r == .UInt) x == r.UInt else return null,
                .UShort => |x| if (r == .UShort) x == r.UShort else return null,
                .UByte => |x| if (r == .UByte) x == r.UByte else return null,
                .Bool => |x| if (r == .Bool) x == r.Bool else return null,
                else => return null,
            };
            return .{ .Bool = eq != neg };
        }

        /// Two Floats or two Doubles under `ev_exec.floatBinQuick`; null for any other pair.
        inline fn floatQuick(op: BinOp, l: Value, r: Value) ?Value {
            if (l == .Float and r == .Float) return ev_exec.floatBinQuick(f32, op, l.Float, r.Float);
            if (l == .Double and r == .Double) return ev_exec.floatBinQuick(f64, op, l.Double, r.Double);
            return null;
        }

        /// `bin`'s floating-point operands and `Long` shifts by a widened count, then its arm.
        fn binWide(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const op: BinOp = @enumFromInt(code[pc + 2] & 0xff);
            if (ev_exec.wideScalarBin(op, regs[code[pc + 4]], regs[code[pc + 5]])) |out| {
                put(c, frame, regs, code[pc + 3], out);
                return next(c, frame, regs, code, pc + 6, blk);
            }
            return toCold(.bin_arm, c, frame, regs, code, pc, blk);
        }

        fn binArm(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            @branchHint(.cold);
            _ = regs;
            const idx: usize = code[pc + 1];
            const inst = instAt(frame, blk, idx);
            frame.at(@enumFromInt(blk), idx);
            const r = ev_inst.execArmBinOp(H, c.allocator, frame, inst.BinOp, c.host) catch return .oom;
            return after(c, frame, code, pc + 6, blk, r, inst, idx);
        }

        inline fn addSub(comptime is_add: bool, c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const l = regs[code[pc + 4]];
            const r = regs[code[pc + 5]];
            if (l == .Int and r == .Int) {
                put(c, frame, regs, code[pc + 3], .{ .Int = if (is_add) l.Int +% r.Int else l.Int -% r.Int });
                return next(c, frame, regs, code, pc + 6, blk);
            }
            if (l == .Long and r == .Long) {
                put(c, frame, regs, code[pc + 3], .{ .Long = if (is_add) l.Long +% r.Long else l.Long -% r.Long });
                return next(c, frame, regs, code, pc + 6, blk);
            }
            return jump(opBin, c, frame, regs, code, pc, blk);
        }

        fn opAdd(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            return addSub(true, c, frame, regs, code, pc, blk);
        }

        fn opSub(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            return addSub(false, c, frame, regs, code, pc, blk);
        }

        fn opCmp(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const l = regs[code[pc + 4]];
            const r = regs[code[pc + 5]];
            const mask = code[pc + 2] >> 8;
            if (l == .Int and r == .Int) {
                put(c, frame, regs, code[pc + 3], .{ .Bool = holds(mask, l.Int, r.Int) });
                return next(c, frame, regs, code, pc + 6, blk);
            }
            if (l == .Long and r == .Long) {
                put(c, frame, regs, code[pc + 3], .{ .Bool = holds(mask, l.Long, r.Long) });
                return next(c, frame, regs, code, pc + 6, blk);
            }
            return jump(opBin, c, frame, regs, code, pc, blk);
        }

        fn opUn(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            if (ev_exec.scalarUn(@enumFromInt(code[pc + 2]), regs[code[pc + 4]])) |out| {
                put(c, frame, regs, code[pc + 3], out);
                return next(c, frame, regs, code, pc + 5, blk);
            }
            return slow(5, c, frame, regs, code, pc, blk);
        }

        /// `bin` for operator `op`: two Ints, two Longs, two Floats or two Doubles compute here;
        /// anything else takes `bin`'s slow paths.
        fn BinH(comptime op: BinOp) type {
            return struct {
                fn f(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
                    const l = regs[code[pc + 4]];
                    const r = regs[code[pc + 5]];
                    const quick = if (comptime isIdentity(op))
                        identQuick(op, l, r)
                    else if (comptime (op == .Shl or op == .Shr or op == .UShr))
                        ev_exec.scalarBin(op, l, r) orelse ev_exec.longShift(op, l, r)
                    else
                        ev_exec.scalarBin(op, l, r) orelse floatQuick(op, l, r);
                    if (quick) |out| {
                        put(c, frame, regs, code[pc + 3], out);
                        return next(c, frame, regs, code, pc + 6, blk);
                    }
                    return toCold(.bin_wide, c, frame, regs, code, pc, blk);
                }
            };
        }

        /// `un` for operator `op`: the scalar tags compute here; anything else takes the arm.
        fn UnH(comptime op: ir.UnOp) type {
            return struct {
                fn f(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
                    if (ev_exec.scalarUn(op, regs[code[pc + 4]])) |out| {
                        put(c, frame, regs, code[pc + 3], out);
                        return next(c, frame, regs, code, pc + 5, blk);
                    }
                    return slow(5, c, frame, regs, code, pc, blk);
                }
            };
        }

        /// A conversion to `t`: a number or a `Char` converts here; anything else takes `un`.
        fn ConvH(comptime t: runtime.numconv.Target) type {
            return struct {
                fn f(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
                    if (runtime.numconv.convert(t, regs[code[pc + 4]])) |out| {
                        put(c, frame, regs, code[pc + 3], out);
                        return next(c, frame, regs, code, pc + 5, blk);
                    }
                    return jump(opUn, c, frame, regs, code, pc, blk);
                }
            };
        }

        /// Numeric function `fun`: a value it takes computes here; anything else takes `un`.
        /// Only `sin` and `cos` call out, so only their ops save registers.
        fn FnH(comptime fun: runtime.numfn.Fn) type {
            return struct {
                fn f(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
                    if (runtime.numfn.apply(fun, regs[code[pc + 4]])) |out| {
                        put(c, frame, regs, code[pc + 3], out);
                        return next(c, frame, regs, code, pc + 5, blk);
                    }
                    return jump(opUn, c, frame, regs, code, pc, blk);
                }
            };
        }

        /// Opens an activation for call `t` and goes on in the callee's stream: here when every
        /// step takes its common path (`openFast`), else in `enterSlow`. `pc` is the call's.
        inline fn enter(c: *Ctx, frame: *Frame, code: [*]const u32, pc: usize, blk: u32, t: Target) Exit {
            // The call is a block edge for the loop's guards: their test here, their work in
            // `enterSlow`.
            runtime.assertNoCellLock();
            c.ev.spin_check_counter +%= 1;
            if (runtime.gc.edgeFlagsWord() == 0 and c.ev.spin_check_counter & 0xFFFF != 0) {
                if (openFast(c, t)) |act| return entered(c, blk, t, act);
            }
            c.target = t;
            return toCold(.enter_slow, c, frame, frame.regs.ptr, code, pc, blk);
        }

        /// An activation of call `t` opened from the thread's pool over a window on its value
        /// stack, when neither needs to grow, the collector's frame root is installed and no
        /// diagnostic hook runs: what `openStreamActivation` does then, with nothing that can
        /// fail. Null, having done nothing, otherwise.
        inline fn openFast(c: *Ctx, t: Target) ?*Activation {
            if (reclaim or parent.call_hooks_on or !runtime.gc.gc_enabled) return null;
            const ev = c.ev;
            if (ev.act_pool_len == 0 or !ev.frame_root_installed) return null;
            const act = ev.act_pool[ev.act_pool_len - 1];
            // A mask whose use counter would wrap clears its bytes first.
            if (act.frame.wmask.use == std.math.maxInt(u8)) return null;
            const vs = &ev.vstack;
            const seg = vs.seg orelse return null;
            const n = t.sc.func.n_locals;
            if (seg.buf.len - vs.top < n) return null;
            const mark = t.area orelse vs.mark();
            const window = seg.buf[vs.top..][0..n];
            vs.top += n;
            ev.act_pool_len -= 1;
            ev.eval_depth += 1;
            act.frame.enterWindow(ev, c.allocator, t.module, t.sc.func, window, t.params, t.captures, mark, t.sc.no_fill);
            act.frame.closure = t.closure;
            act.frame.module_arc = t.owning;
            act.try_stack.clearRetainingCapacity();
            act.ret_dst = t.dst;
            act.frame.gc_link = ev.frame_chain;
            ev.frame_chain = &act.frame;
            return act;
        }

        /// The callee's activation, open: links it above the caller and goes on in its stream.
        inline fn entered(c: *Ctx, blk: u32, t: Target, act: *Activation) Exit {
            act.ret_block = @enumFromInt(blk);
            act.ret_idx = t.idx + 1;
            // A caller whose every block ends in a stream op goes on in its stream at the return.
            act.ret_streams = c.bs;
            act.ret_pc = @intCast(t.ret_pc);
            act.caller = c.top;
            c.top = act;
            const nf = &act.frame;
            c.try_stack = &act.try_stack;
            c.func = t.sc.func;
            c.bs = t.sc;
            const npc = enterAt(c, nf, t.sc);
            return next(c, nf, nf.regs.ptr, t.sc.code.ptr, npc, t.sc.func.entry.int());
        }

        /// `enter` for `Ctx.target` when the edge's guards have work or the activation takes a
        /// path `openFast` leaves: the guards, then `openStreamActivation`.
        fn enterSlow(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            _ = code;
            _ = pc;
            const t = c.target;
            if (edgeGuardSlow(c.allocator, c.ev)) |er| {
                if (t.area) |m| c.ev.vstack.restore(m);
                c.result = er;
                return leave(c, .result, frame, blk);
            }
            c.ev.eval_depth += 1;
            const act = ev_activation.openStreamActivation(c.ev, c.allocator, t.module, t.sc.func, t.params, t.captures, t.area, t.closure, t.owning, t.dst, t.sc.no_fill, reclaim) catch {
                c.ev.eval_depth -= 1;
                if (t.area) |m| c.ev.vstack.restore(m);
                return leave(c, .oom, frame, blk);
            };
            if (parent.call_hooks_on) {
                if (runtime.prof.fn_prof_active) _ = ev_exec.fnProfEnter(t.sc.func.id.int());
                if (parent.frame_count_on) parent.frame_count_total += 1;
                ev_enter.dumpFnIfRequested(t.sc.func);
            }
            return entered(c, blk, t, act);
        }

        /// Where a call the stream makes enters `sc`'s frame, just opened: past its `load_params`
        /// op, whose loads it does here, when it has one.
        inline fn enterAt(c: *Ctx, frame: *Frame, sc: *const bc.FuncStreams) usize {
            if (sc.param_map.len == 0) return sc.entry_pc;
            loadParams(c, frame, frame.regs.ptr, sc.param_map);
            return sc.body_pc;
        }

        /// A static call: the callee its site keeps, run in place (`runCallee`); a site with no
        /// callee yet or a call past the depth bound or with the hooks on takes `callSlow`.
        fn opCall(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const ev = c.ev;
            if (c.bs.callees[code[pc + 6]].load(.acquire)) |sc| if (ev.eval_depth < ev.eval_depth_cap and !parent.call_hooks_on)
                return runCallee(true, c, frame, regs, code, pc, blk, sc);
            return toCold(.call_slow, c, frame, regs, code, pc, blk);
        }

        /// A virtual or interface call whose receiver has a class its site keeps: that class's
        /// implementation, an interpreted body run in place (`runCallee`) or a host function
        /// (`vcallNative`); anything else takes `vcallSlow`.
        fn opVcall(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const ev = c.ev;
            const lo: usize = code[pc + 3];
            if (lo < frame.regs.len) if (c.bs.vcallees[code[pc + 6]].load(.acquire)) |e| {
                if (ev.eval_depth < ev.eval_depth_cap and !parent.call_hooks_on) if (siteClass(frame, &regs[lo])) |class| {
                    // A site of one class keeps it twice.
                    const i: usize = if (e.classes[0] == class) 0 else if (e.classes[1] == class) 1 else return toCold(.vcall_slow, c, frame, regs, code, pc, blk);
                    if (e.streams[i]) |sc| return runCallee(false, c, frame, regs, code, pc, blk, sc);
                    c.native = e.natives[i];
                    return toCold(.vcall_native, c, frame, regs, code, pc, blk);
                };
            };
            return toCold(.vcall_slow, c, frame, regs, code, pc, blk);
        }

        /// A `call` or `vcall` of `sc` run in place: its field read here when it only reads one of
        /// its receiver's, its field stores in `callLeaf` when it only stores its parameters,
        /// else entered; an argument run reaching past the window takes the slow path.
        inline fn runCallee(comptime is_call: bool, c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32, sc: *const bc.FuncStreams) Exit {
            const op_len: usize = if (is_call) 8 else 7;
            const lo: usize = code[pc + 3];
            const n: usize = code[pc + 4];
            if (lo + n <= frame.regs.len) {
                const params = regs[lo..][0..n];
                switch (sc.leaf) {
                    .get_field => |slot| if (n != 0 and params[0] == .Instance) {
                        if (runtime.InstanceData.slotGet(params[0].Instance, slot)) |v| {
                            if (reclaim) v.retain();
                            put(c, frame, regs, code[pc + 5], v);
                            return next(c, frame, regs, code, pc + op_len, blk);
                        }
                    },
                    .none => {
                        frame.at(@enumFromInt(blk), code[pc + 1]);
                        return enter(c, frame, code, pc, blk, .{ .sc = sc, .module = frame.module, .params = params, .dst = @enumFromInt(code[pc + 5]), .idx = code[pc + 1], .ret_pc = pc + op_len });
                    },
                    .set_fields => {
                        c.leaf = sc;
                        return toCold(if (is_call) .call_leaf else .vcall_leaf, c, frame, regs, code, pc, blk);
                    },
                }
            }
            return toCold(if (is_call) .call_slow else .vcall_slow, c, frame, regs, code, pc, blk);
        }

        fn callLeaf(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            return leafCall(true, c, frame, regs, code, pc, blk);
        }

        fn vcallLeaf(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            return leafCall(false, c, frame, regs, code, pc, blk);
        }

        /// A `call` or `vcall` of `c.leaf`, a body that only stores its parameters in fields of
        /// its receiver (`runCallee`): the stores done here, or the body entered when they
        /// cannot be (`leafStores`).
        inline fn leafCall(comptime is_call: bool, c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const sc = c.leaf;
            const op_len: usize = if (is_call) 8 else 7;
            const params = regs[code[pc + 3]..][0..code[pc + 4]];
            if (params.len != 0 and leafStores(c, frame, sc, params)) {
                const this = params[0];
                if (reclaim) this.retain();
                put(c, frame, regs, code[pc + 5], this);
                return next(c, frame, regs, code, pc + op_len, blk);
            }
            frame.at(@enumFromInt(blk), code[pc + 1]);
            return enter(c, frame, code, pc, blk, .{ .sc = sc, .module = frame.module, .params = params, .dst = @enumFromInt(code[pc + 5]), .idx = code[pc + 1], .ret_pc = pc + op_len });
        }

        fn callSlow(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            // A host function the tables bind keeps no callee at its site: straight to it.
            if (nativeOf(frame, code[pc + 2]) != null) return hostOrArm(true, c, frame, code, pc, blk);
            return callOrVcall(true, c, frame, regs, code, pc, blk);
        }

        fn vcallSlow(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            return callOrVcall(false, c, frame, regs, code, pc, blk);
        }

        inline fn callOrVcall(comptime is_call: bool, c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            const idx: usize = code[pc + 1];
            const op_len: usize = if (is_call) 8 else 7;
            const fid: u32 = if (is_call) code[pc + 2] else virtualTarget(frame, code[pc + 2], code[pc + 3]) orelse NO_TARGET;
            const callee: ?*const bc.FuncStreams = if (is_call)
                staticCallee(H, c.host, frame, c.ev, c.bs, fid, code[pc + 6], code[pc + 7])
            else
                streamCallee(frame, c.ev, fid);
            if (callee) |sc| {
                if (!is_call) keepVcallee(c, frame, code, pc, sc, .none);
                if (sc.leaf != .none and !parent.call_hooks_on) {
                    const run_ = argRun(frame, @enumFromInt(code[pc + 3]), code[pc + 4]);
                    if (runLeaf(c, frame, sc, run_, @enumFromInt(code[pc + 5])))
                        return next(c, frame, frame.regs.ptr, code, pc + op_len, blk);
                }
                frame.at(@enumFromInt(blk), idx);
                const params = argRun(frame, @enumFromInt(code[pc + 3]), code[pc + 4]);
                return enter(c, frame, code, pc, blk, .{ .sc = sc, .module = frame.module, .params = params, .dst = @enumFromInt(code[pc + 5]), .idx = idx, .ret_pc = pc + op_len });
            }
            return toCold(if (is_call) .call_host else .vcall_host, c, frame, frame.regs.ptr, code, pc, blk);
        }

        /// Keeps the implementation a `vcall` resolved, the streams `sc` or else the host function
        /// `nid`, at its site for the receiver's class (`siteClass`), while the site keeps fewer
        /// than two classes; a call of a third class resolves as it did. A site's entries are
        /// never freed (a caller may still read the one a second class replaced), so each site
        /// makes at most two, kept as long as the streams they belong to, which live for the
        /// process.
        inline fn keepVcallee(c: *Ctx, frame: *const Frame, code: [*]const u32, pc: usize, sc: ?*const bc.FuncStreams, nid: ir.NativeId) void {
            const class = siteClass(frame, &frame.regs[code[pc + 3]]) orelse return;
            const site = &c.bs.vcallees[code[pc + 6]];
            const old = site.load(.acquire);
            var e: bc.VEntry = .{ .classes = .{ class, class }, .streams = .{ sc, sc }, .natives = .{ nid, nid }, .n = 1 };
            if (old) |o| {
                if (o.n > 1 or o.classes[0] == class) return;
                e = .{ .classes = .{ o.classes[0], class }, .streams = .{ o.streams[0], sc }, .natives = .{ o.natives[0], nid }, .n = 2 };
            }
            const p = std.heap.smp_allocator.create(bc.VEntry) catch return;
            p.* = e;
            if (site.cmpxchgStrong(old, p, .release, .acquire) != null) std.heap.smp_allocator.destroy(p);
        }

        /// A call the stream does not run in place: a host function the tables bind, over the
        /// argument run, once the unit a static call must see run has; else the instruction's arm.
        inline fn hostOrArm(comptime is_call: bool, c: *Ctx, frame: *Frame, code: [*]const u32, pc: usize, blk: u32) Exit {
            const idx: usize = code[pc + 1];
            const op_len: usize = if (is_call) 8 else 7;
            const fid: u32 = if (is_call) code[pc + 2] else virtualTarget(frame, code[pc + 2], code[pc + 3]) orelse NO_TARGET;
            if (nativeOf(frame, fid)) |nid| if (!is_call or ev_resolved.unitReady(H, c.host, code[pc + 7])) {
                if (!is_call) keepVcallee(c, frame, code, pc, null, nid);
                return runNative(c, frame, code, pc, blk, nid, op_len);
            };
            const inst = instAt(frame, blk, idx);
            frame.at(@enumFromInt(blk), idx);
            const r = ev_inst.execInst(H, c.allocator, frame, inst, c.host) catch return leave(c, .oom, frame, blk);
            return after(c, frame, code, pc + op_len, blk, r, inst, idx);
        }

        /// Host function `nid` over the call's argument run, its result in the call's `dst`; what
        /// it raised goes to the catch that takes it, as the instruction's arm would send it.
        inline fn runNative(c: *Ctx, frame: *Frame, code: [*]const u32, pc: usize, blk: u32, nid: ir.NativeId, op_len: usize) Exit {
            const idx: usize = code[pc + 1];
            frame.at(@enumFromInt(blk), idx);
            const err = hostCall(H, c.allocator, frame, c.host, nid, code[pc + 3], code[pc + 4], code[pc + 5], reclaim) catch return leave(c, .oom, frame, blk);
            if (err) |e| {
                frame.tls.step_err = e;
                const inst = instAt(frame, blk, idx);
                const a = afterStep(c.allocator, frame, .raised, inst, idx, @enumFromInt(blk), c.flat_out, c.park_out, &c.thrown, &c.unwound, &c.ret_v) catch return leave(c, .oom, frame, blk);
                return leave(c, if (a == .ret) .ret else .brk, frame, blk);
            }
            return next(c, frame, frame.regs.ptr, code, pc + op_len, blk);
        }

        /// A `vcall` whose site keeps a host function for its receiver's class.
        fn vcallNative(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            return runNative(c, frame, code, pc, blk, c.native, 7);
        }

        fn callHost(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            return hostOrArm(true, c, frame, code, pc, blk);
        }

        fn vcallHost(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            return hostOrArm(false, c, frame, code, pc, blk);
        }

        fn opNew(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            const idx: usize = code[pc + 1];
            frame.at(@enumFromInt(blk), idx);
            const target = constructTarget(H, c.allocator, frame, c.ev, c.host, c.bs, code[pc..][0..8], reclaim) catch return leave(c, .oom, frame, blk);
            if (target) |t| {
                const sc = t.streams;
                // A constructor that only takes its properties stores them in the instance the
                // register already holds.
                if (sc.leaf == .set_fields and !parent.call_hooks_on and leafStores(c, frame, sc, t.params))
                {
                    if (t.area) |m| c.ev.vstack.restore(m);
                    return next(c, frame, frame.regs.ptr, code, pc + 8, blk);
                }
                return enter(c, frame, code, pc, blk, .{ .sc = sc, .module = t.run_module orelse frame.module, .params = t.params, .captures = t.captures, .area = t.area, .closure = t.closure, .owning = t.owning, .dst = t.dst, .idx = idx, .ret_pc = pc + 8 });
            }
            return slow(8, c, frame, frame.regs.ptr, code, pc, blk);
        }

        /// Runs a call of `sc`'s `bc.Leaf` body over `params` without a frame, its result in
        /// `dst`, as the body's own `Return` would leave it. False, having done nothing, when
        /// the body must run (`leafStores`) or the receiver is not an instance with the fields.
        inline fn runLeaf(c: *Ctx, frame: *Frame, sc: *const bc.FuncStreams, params: []const Value, dst: Reg) bool {
            if (params.len == 0 or params[0] != .Instance) return false;
            switch (sc.leaf) {
                .none => return false,
                .get_field => |slot| {
                    const v = runtime.InstanceData.slotGet(params[0].Instance, slot) orelse return false;
                    if (reclaim) v.retain();
                    writeFastR(frame, dst, v, c.allocator, reclaim);
                    return true;
                },
                .set_fields => {
                    if (!leafStores(c, frame, sc, params)) return false;
                    const this = params[0];
                    if (reclaim) this.retain();
                    writeFastR(frame, dst, this, c.allocator, reclaim);
                    return true;
                },
            }
        }

        /// Runs the field stores of `sc`'s `set_fields` leaf over `params`, its superclass
        /// constructor's first, as the bodies would. False, having stored nothing, when the
        /// bodies must run: an object one loads to initialize is not built yet (the body
        /// builds it), a superclass constructor is not at its site yet (the body's call puts
        /// it there) or is no such leaf, or the stores do not fit the receiver.
        inline fn leafStores(c: *Ctx, frame: *const Frame, sc: *const bc.FuncStreams, params: []const Value) bool {
            const sf = sc.leaf.set_fields;
            if (sf.super != null) return chainStores(c, frame, sc, params, 0);
            if (sf.object != bc.NO_OBJECT and ev_resolved.builtObject(H, frame, c.host, sf.object) == null) return false;
            return storeLeafFields(sf.stores, params, c.allocator, reclaim);
        }

        fn chainStores(c: *Ctx, frame: *const Frame, sc: *const bc.FuncStreams, params: []const Value, depth: u8) bool {
            const sf = sc.leaf.set_fields;
            if (sf.object != bc.NO_OBJECT and ev_resolved.builtObject(H, frame, c.host, sf.object) == null) return false;
            if (params.len == 0 or params[0] != .Instance) return false;
            const n = params[0].Instance.cell.data.slots.len;
            for (sf.stores) |st| if (st.param >= params.len or st.slot >= n) return false;
            if (sf.super) |sup| {
                if (depth == 16) return false;
                const callee = sc.callees[sup.site].load(.acquire) orelse return false;
                if (callee.leaf != .set_fields) return false;
                var args: [16]Value = undefined;
                for (sup.args, 0..) |p, j| {
                    if (p >= params.len) return false;
                    args[j] = params[p];
                }
                if (!chainStores(c, frame, callee, args[0..sup.args.len], depth + 1)) return false;
            }
            return storeLeafFields(sf.stores, params, c.allocator, reclaim);
        }

        fn opCallv(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            const idx: usize = code[pc + 1];
            frame.at(@enumFromInt(blk), idx);
            const target = closureTarget(H, frame, c.ev, c.host, code[pc..][0..6]) catch return leave(c, .oom, frame, blk);
            if (target) |t|
                return enter(c, frame, code, pc, blk, .{ .sc = t.streams, .module = t.run_module orelse frame.module, .params = t.params, .captures = t.captures, .area = t.area, .closure = t.closure, .owning = t.owning, .dst = t.dst, .idx = idx, .ret_pc = pc + 6 });
            return slow(6, c, frame, frame.regs.ptr, code, pc, blk);
        }

        fn opNative(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            const idx: usize = code[pc + 1];
            frame.at(@enumFromInt(blk), idx);
            const run_ = argRun(frame, @enumFromInt(code[pc + 3]), code[pc + 4]);
            const nid: ir.NativeId = @enumFromInt(code[pc + 2]);
            // A Kotlin receiver's own override of the member answers; `super` runs the native.
            const res = (if (comptime @hasDecl(H, "callNativeSite"))
                (if (code[pc + 6] == 0 and run_.len != 0 and run_[0] == .Instance)
                    c.host.callNativeSite(c.allocator, nid, run_)
                else
                    c.host.callNative(c.allocator, nid, run_))
            else
                c.host.callNative(c.allocator, nid, run_)) catch return leave(c, .oom, frame, blk);
            switch (res) {
                .ok => |v| {
                    const regs2 = frame.regs.ptr;
                    put(c, frame, regs2, code[pc + 5], v);
                    return next(c, frame, regs2, code, pc + 7, blk);
                },
                .err => |e| {
                    frame.tls.step_err = e;
                    const inst = instAt(frame, blk, idx);
                    const a = afterStep(c.allocator, frame, .raised, inst, idx, @enumFromInt(blk), c.flat_out, c.park_out, &c.thrown, &c.unwound, &c.ret_v) catch return leave(c, .oom, frame, blk);
                    return leave(c, if (a == .ret) .ret else .brk, frame, blk);
                },
            }
        }

        fn opArrayGet(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const arr = regs[code[pc + 3]];
            const iv = regs[code[pc + 4]];
            // A primitive array's element, read in place as `fastIndexGet` reads it.
            if (arr == .Array and iv == .Int and iv.Int >= 0) if (arr.Array.primKind()) |kind| {
                const buf = &arr.Array.storage().scalars.cell.data;
                const i: usize = @intCast(iv.Int);
                if ((i + 1) * kind.elemSize() <= buf.bytes.items.len) {
                    put(c, frame, regs, code[pc + 2], buf.getAs(i, kind));
                    return next(c, frame, regs, code, pc + 5, blk);
                }
            };
            return toCold(.array_get_wide, c, frame, regs, code, pc, blk);
        }

        /// `array_get` on any other array or a string, then the instruction's arm.
        fn arrayGetWide(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const arr = regs[code[pc + 3]];
            if (arr == .Array or arr == .String) {
                const idx_v = regs[code[pc + 4]];
                if (ev_values.fastIndexGet(&arr, &idx_v)) |v| {
                    put(c, frame, regs, code[pc + 2], v);
                    return next(c, frame, regs, code, pc + 5, blk);
                }
            }
            return slow(5, c, frame, regs, code, pc, blk);
        }

        fn opArraySet(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const arr = regs[code[pc + 2]];
            if (arr == .Array) {
                const idx_v = regs[code[pc + 3]];
                if (ev_values.fastIndexSet(c.allocator, &arr, &idx_v, regs[code[pc + 4]]) != null)
                    return next(c, frame, regs, code, pc + 5, blk);
            }
            return slow(5, c, frame, regs, code, pc, blk);
        }

        fn opLoadObject(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            if (ev_resolved.builtObject(H, frame, c.host, code[pc + 3])) |v| {
                if (reclaim) v.retain();
                put(c, frame, regs, code[pc + 2], v);
                return next(c, frame, regs, code, pc + 4, blk);
            }
            return slow(4, c, frame, regs, code, pc, blk);
        }

        fn opNot(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const v = regs[code[pc + 3]];
            if (v == .Bool) {
                put(c, frame, regs, code[pc + 2], .{ .Bool = !v.Bool });
                return next(c, frame, regs, code, pc + 4, blk);
            }
            return slow(4, c, frame, regs, code, pc, blk);
        }

        fn opGetField(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const obj = regs[code[pc + 3]];
            if (obj == .Instance) if (runtime.InstanceData.slotGet(obj.Instance, code[pc + 4])) |v| {
                if (reclaim) v.retain();
                put(c, frame, regs, code[pc + 2], v);
                return next(c, frame, regs, code, pc + 5, blk);
            };
            // A null, a host value or a slot past the fields: the instruction's arm.
            return slow(5, c, frame, regs, code, pc, blk);
        }

        fn opSetField(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const obj = regs[code[pc + 2]];
            if (obj == .Instance) {
                const v = regs[code[pc + 4]];
                if (reclaim) v.retain();
                if (runtime.InstanceData.slotSet(obj.Instance, code[pc + 3], v)) |old| {
                    if (reclaim) old.release(c.allocator);
                    return next(c, frame, regs, code, pc + 5, blk);
                }
                if (reclaim) v.release(c.allocator);
            }
            return slow(5, c, frame, regs, code, pc, blk);
        }

        fn opEscape(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            return slow(2, c, frame, regs, code, pc, blk);
        }

        fn opJump(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            leaveSpan(frame, code, pc + 3);
            return edge(c, frame, regs, code, code[pc + 1], code[pc + 2], blk);
        }

        fn opBr(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            leaveSpan(frame, code, pc + 6);
            const cv = regs[code[pc + 1]];
            if (cv != .Bool) {
                // A cell-carried or coercing condition: the frame loop's Branch runs `valueTruthy`.
                c.resume_idx = std.math.maxInt(usize);
                return leave(c, .block, frame, blk);
            }
            // Each edge is its own path, so the next pc waits on a predicted branch rather than on
            // the condition's value.
            if (cv.Bool) return edge(c, frame, regs, code, code[pc + 2], code[pc + 3], blk);
            return edge(c, frame, regs, code, code[pc + 4], code[pc + 5], blk);
        }

        /// A fused compare's branch, its dst written: `at` is the pc of the `cmp_br`.
        inline fn branchOn(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, at: usize, blk: u32, taken: bool) Exit {
            put(c, frame, regs, code[at + 3], .{ .Bool = taken });
            leaveSpan(frame, code, at + 10);
            // As `br`: each edge is its own path.
            if (taken) return edge(c, frame, regs, code, code[at + 6], code[at + 7], blk);
            return edge(c, frame, regs, code, code[at + 8], code[at + 9], blk);
        }

        fn opCmpBr(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            // The block's last BinOp fused with its Branch: the compare computes inline, still
            // writes dst so register state matches the unfused form, and branches.
            const l = regs[code[pc + 4]];
            const r = regs[code[pc + 5]];
            const kw = code[pc + 2];
            const mask = kw >> 8;
            if (mask != 0 and l == .Int and r == .Int) return branchOn(c, frame, regs, code, pc, blk, holds(mask, l.Int, r.Int));
            if (mask != 0 and l == .Long and r == .Long) return branchOn(c, frame, regs, code, pc, blk, holds(mask, l.Long, r.Long));
            const op: BinOp = @enumFromInt(kw & 0xff);
            if ((if (isIdentity(op)) identQuick(op, l, r) else floatQuick(op, l, r) orelse eqQuick(op, l, r))) |out| if (out == .Bool) return branchOn(c, frame, regs, code, pc, blk, out.Bool);
            return toCold(.cmp_br_wide, c, frame, regs, code, pc, blk);
        }

        /// `cmp_br` over any other operands: the scalar paths, then the compare's arm.
        fn cmpBrWide(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const kw = code[pc + 2];
            if (ev_exec.scalarBin(@enumFromInt(kw & 0xff), regs[code[pc + 4]], regs[code[pc + 5]])) |out| {
                if (out == .Bool) return branchOn(c, frame, regs, code, pc, blk, out.Bool);
            }
            const idx: usize = code[pc + 1];
            const inst = instAt(frame, blk, idx);
            frame.at(@enumFromInt(blk), idx);
            const r = ev_inst.execArmBinOp(H, c.allocator, frame, inst.BinOp, c.host) catch return leave(c, .oom, frame, blk);
            const a = afterStep(c.allocator, frame, r, inst, idx, @enumFromInt(blk), c.flat_out, c.park_out, &c.thrown, &c.unwound, &c.ret_v) catch return leave(c, .oom, frame, blk);
            switch (a) {
                .cont => {},
                .brk => return leave(c, .brk, frame, blk),
                .ret => return leave(c, .ret, frame, blk),
            }
            const cv = frame.read(@enumFromInt(code[pc + 3]));
            if (cv != .Bool) {
                leaveSpan(frame, code, pc + 10);
                c.resume_idx = std.math.maxInt(usize);
                return leave(c, .block, frame, blk);
            }
            const regs2 = frame.regs.ptr;
            leaveSpan(frame, code, pc + 10);
            if (cv.Bool) return edge(c, frame, regs2, code, code[pc + 6], code[pc + 7], blk);
            return edge(c, frame, regs2, code, code[pc + 8], code[pc + 9], blk);
        }

        fn opRetTry(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            // A return inside a try region, or with a finally's flow pending, takes the frame
            // loop's routing through the finallys.
            if (c.try_stack.items.len != 0 or (if (frame.pending) |p| p.tryDepth() != null else false)) {
                c.resume_idx = std.math.maxInt(usize);
                return leave(c, .block, frame, blk);
            }
            return jump(opRet, c, frame, regs, code, pc, blk);
        }

        /// A return into the caller's stream: here when closing the activation takes its common
        /// path (`closeable`), else in `retSlow`.
        fn opRet(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            if (c.top) |act| if (act.ret_streams) |rs| if (closeable(c, act)) {
                const v: Value = if (code[pc + 1] != 0) regs[code[pc + 2]] else .Unit;
                const ev = c.ev;
                c.top = act.caller;
                ev.eval_depth -= 1;
                const rb = act.ret_block;
                const rpc = act.ret_pc;
                const rd = act.ret_dst;
                // What `closeStreamActivation` does for it.
                ev.frame_chain = act.frame.gc_link;
                if (act.frame.vs_mark) |m| ev.vstack.restore(m);
                act.frame.vs_mark = null;
                ev.act_pool[ev.act_pool_len] = act;
                ev.act_pool_len += 1;
                const nf = if (c.top) |a| &a.frame else c.root;
                c.try_stack = if (c.top) |a| &a.try_stack else c.root_ts;
                const nregs = nf.regs.ptr;
                // The caller's stream validated `rd` against its window.
                put(c, nf, nregs, rd.int(), v);
                c.func = nf.func;
                c.bs = rs;
                return next(c, nf, nregs, rs.code.ptr, rpc, rb.int());
            };
            return toCold(.ret_slow, c, frame, regs, code, pc, blk);
        }

        /// Whether `act` closes by going back to the pool and giving its window back to the value
        /// stack, and nothing else: no finally flow pending, no heap block, room in the pool, no
        /// diagnostic hook, and a collector that frees what it held. Its try stack is empty by
        /// its return and keeps its buffer.
        inline fn closeable(c: *Ctx, act: *const Activation) bool {
            if (reclaim or parent.call_hooks_on or !runtime.gc.gc_enabled) return false;
            const f = &act.frame;
            return f.pending == null and f.heap.len == 0 and c.ev.act_pool_len < ev_activation.ACT_POOL_MAX;
        }

        fn retSlow(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const v: Value = if (code[pc + 1] != 0) regs[code[pc + 2]] else .Unit;
            if (reclaim) v.retain();
            // Back into the caller's stream when it called from one it can go on in.
            if (c.top) |act| if (act.ret_streams) |rs| {
                c.top = act.caller;
                c.ev.eval_depth -= 1;
                const rb = act.ret_block;
                const rpc = act.ret_pc;
                const rd = act.ret_dst;
                ev_activation.closeStreamActivation(c.ev, c.allocator, act, reclaim);
                const nf = if (c.top) |a| &a.frame else c.root;
                c.try_stack = if (c.top) |a| &a.try_stack else c.root_ts;
                const nregs = nf.regs.ptr;
                put(c, nf, nregs, rd.int(), v);
                c.func = nf.func;
                if (parent.call_hooks_on and runtime.prof.fn_prof_active) _ = ev_exec.fnProfEnter(nf.func.id.int());
                c.bs = rs;
                return next(c, nf, nregs, rs.code.ptr, rpc, rb.int());
            };
            c.result = ok(v);
            return leave(c, .result, frame, blk);
        }

        fn opTermExit(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            _ = regs;
            leaveSpan(frame, code, pc + 1);
            c.resume_idx = std.math.maxInt(usize);
            return leave(c, .block, frame, blk);
        }

        /// `bin_k` for operator `op`: an operation with a constant operand the op carries. A
        /// register of the constant's type computes here; any other writes the constant and runs
        /// the op behind it.
        fn BinK(comptime op: BinOp) type {
            return struct {
                fn f(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
                    if (binKQuick(op, code[pc + 1], regs[code[pc + 2]], code[pc + 4], code[pc + 5])) |out| {
                        put(c, frame, regs, code[pc + 9], out);
                        return next(c, frame, regs, code, pc + 12, blk);
                    }
                    return toCold(.bin_k_wide, c, frame, regs, code, pc, blk);
                }
            };
        }

        /// `cmp_br_k` for compare `op`: `bin_k` over a fused compare, which writes its dst and
        /// branches, as `cmp_br` does.
        fn CmpBrK(comptime op: BinOp) type {
            return struct {
                fn f(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
                    const x = regs[code[pc + 2]];
                    const kw = code[pc + 1];
                    if (x == .Int and (kw >> 8) & 0xff == @intFromEnum(bc.KType.int))
                        return branchOn(c, frame, regs, code, pc + 6, blk, holds(comptime bc.orderMask(op), x.Int, @as(i32, @bitCast(code[pc + 4]))));
                    if (binKQuick(op, kw, x, code[pc + 4], code[pc + 5])) |out| if (out == .Bool)
                        return branchOn(c, frame, regs, code, pc + 6, blk, out.Bool);
                    return toCold(.cmp_br_k_wide, c, frame, regs, code, pc, blk);
                }
            };
        }

        /// `ev_exec.binK` for operator `op`, with no call in it: an Int or Long register with an
        /// Int or Long constant, shifts included, a Float or Double register with a constant of
        /// its type (but for `%`, whose `@rem` is a call), an unsigned register compared with a
        /// constant of its type, and any register but a cell compared with `null`; null for the
        /// rest.
        inline fn binKQuick(comptime op: BinOp, kw: u32, x: Value, lo: u32, hi: u32) ?Value {
            const shift = comptime (op == .Shl or op == .Shr or op == .UShr);
            return switch (@as(bc.KType, @enumFromInt((kw >> 8) & 0xff))) {
                .int => switch (x) {
                    .Int, .Long => ev_exec.scalarBin(op, x, .{ .Int = @bitCast(lo) }),
                    else => null,
                },
                .long => switch (x) {
                    .Long => if (shift)
                        ev_exec.longShift(op, x, .{ .Long = @bitCast(@as(u64, hi) << 32 | lo) })
                    else
                        ev_exec.scalarBin(op, x, .{ .Long = @bitCast(@as(u64, hi) << 32 | lo) }),
                    .Int => ev_exec.scalarBin(op, x, .{ .Long = @bitCast(@as(u64, hi) << 32 | lo) }),
                    else => null,
                },
                .float => if (x == .Float) ev_exec.floatBinQuick(f32, op, x.Float, @bitCast(lo)) else null,
                .double => if (x == .Double) ev_exec.floatBinQuick(f64, op, x.Double, @bitCast(@as(u64, hi) << 32 | lo)) else null,
                .ulong => if (x == .ULong) ev_exec.unsignedEq(op, x.ULong == @as(u64, hi) << 32 | lo) else null,
                .uint => if (x == .UInt) ev_exec.unsignedEq(op, x.UInt == lo) else null,
                // A captured variable's cell is read through by the instruction's arm.
                .null => if (x == .Cell) null else ev_exec.nullEq(op, x == .Null),
            };
        }

        fn binKWide(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const kw = code[pc + 1];
            if (ev_exec.binK(kw, regs[code[pc + 2]], code[pc + 4], code[pc + 5])) |out| {
                put(c, frame, regs, code[pc + 9], out);
                return next(c, frame, regs, code, pc + 12, blk);
            }
            put(c, frame, regs, code[pc + 3], ev_exec.kValue(kw, code[pc + 4], code[pc + 5]));
            return next(c, frame, regs, code, pc + 6, blk);
        }

        fn cmpBrKWide(c: *Ctx, frame: *Frame, regs: [*]Value, code: [*]const u32, pc: usize, blk: u32) Exit {
            const kw = code[pc + 1];
            if (ev_exec.binK(kw, regs[code[pc + 2]], code[pc + 4], code[pc + 5])) |out| if (out == .Bool)
                return branchOn(c, frame, regs, code, pc + 6, blk, out.Bool);
            put(c, frame, regs, code[pc + 3], ev_exec.kValue(kw, code[pc + 4], code[pc + 5]));
            return next(c, frame, regs, code, pc + 6, blk);
        }
    };
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

/// The class `ir.resolved.classOf` gives the receiver `v`, where it reads with no call or borrow,
/// as the key of a `vcall` site's cache; null for a receiver whose call always resolves in full:
/// a null, a function value or a property name (which answer some slots themselves), an
/// exception, a range, and an instance of no class in the tables.
inline fn siteClass(frame: *const Frame, v: *const Value) ?u32 {
    if (v.* == .Instance) {
        const id = v.Instance.asPtrConst().class_id;
        return if (id == std.math.maxInt(u32)) null else id;
    }
    const r = frame.module.resolved orelse return null;
    const h = &r.host_class;
    const cls: ?ir.ClassId = switch (v.*) {
        .Null, .IrClosure, .PropertyRef, .Exception, .Range, .Cell => null,
        .Unit => h.unit,
        .Bool => h.boolean,
        .Char => h.char,
        .Byte => h.byte,
        .Short => h.short,
        .Int => h.int,
        .Long => h.long,
        .Float => h.float,
        .Double => h.double,
        .UByte => h.ubyte,
        .UShort => h.ushort,
        .UInt => h.uint,
        .ULong => h.ulong,
        .String => h.string,
        .Array => |arr| if (arr.primKind()) |k| h.prim_array[@intFromEnum(k)] else h.array,
        else => h.by_tag[@intFromEnum(std.meta.activeTag(v.*))],
    };
    return if (cls) |x| x.int() else null;
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
    closure: ?runtime.IrClosureRef = null,
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

/// Stores each of `stores`' parameters in its field of `params[0]`, as the
/// body's `SetFieldSlot`s do. False, having stored nothing, for a receiver
/// or a parameter the stores do not fit.
inline fn storeLeafFields(stores: []const bc.FieldStore, params: []const Value, allocator: Allocator, comptime reclaim: bool) bool {
    if (params.len == 0 or params[0] != .Instance) return false;
    const inst = params[0].Instance;
    const n = inst.cell.data.slots.len;
    for (stores) |st| if (st.param >= params.len or st.slot >= n) return false;
    for (stores) |st| {
        const v = params[st.param];
        if (reclaim) v.retain();
        const old = runtime.InstanceData.slotSet(inst, st.slot, v).?;
        if (reclaim) old.release(allocator);
    }
    return true;
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
        .closure = callee.IrClosure,
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

/// The frame loop's per-block-entry guards, run on a call and on an edge a stream takes itself to
/// its own or an earlier block: every cycle has such an edge and every recursion a call, so each
/// loop reaches abandonment, the spin/wall diagnostic and the GC safe point, and a run between
/// two polls is bounded by one function. Non-null aborts the frame.
pub inline fn edgeGuard(allocator: Allocator, ftls: *EvalTls) ?EvalResult {
    runtime.assertNoCellLock();
    ftls.spin_check_counter +%= 1;
    if (runtime.gc.edgeFlagsWord() == 0 and ftls.spin_check_counter & 0xFFFF != 0) return null;
    return edgeGuardSlow(allocator, ftls);
}

/// `edgeGuard` when a flag is up or the periodic checks are due.
noinline fn edgeGuardSlow(allocator: Allocator, ftls: *EvalTls) ?EvalResult {
    if (runtime.shouldAbandon()) {
        return errResult(.{ .Type = "daemon task abandoned at run boundary" });
    }
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
