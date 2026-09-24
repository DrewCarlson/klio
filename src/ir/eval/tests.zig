//! IR evaluator tests.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BinOp = ir.BinOp;
const Const = ir.Const;
const Func = ir.Func;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;
const testing = std.testing;

const ev_activation = @import("activation.zig");
const ev_chain = @import("chain.zig");
const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_host = @import("host.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");
const ev_exec = @import("exec.zig");

const EnclosingEntry = ev_state.EnclosingEntry;
const NullHost = ev_host.NullHost;
const SuspendState = ev_snapshot.SuspendState;
const TryFrame = ev_snapshot.TryFrame;
const chainAllocator = ev_chain.chainAllocator;
const enclosingEntriesAlloc = ev_chain.enclosingEntriesAlloc;
const enclosingThisChainAlloc = ev_chain.enclosingThisChainAlloc;
const enclosingThisLast = ev_chain.enclosingThisLast;
const eval = ev_enter.eval;
const nullHost = ev_host.nullHost;
const ok = ev_flow.ok;
const popEnclosing = ev_chain.popEnclosing;
const pushEnclosing = ev_chain.pushEnclosing;
const pushEnclosingSubject = ev_chain.pushEnclosingSubject;
const resetSuspendLivenessCache = ev_snapshot.resetSuspendLivenessCache;
const resumeContinuation = ev_activation.resumeContinuation;
const suspendLiveRegs = ev_snapshot.suspendLiveRegs;

const hand = @import("hand.zig");
const Hand = hand.Hand;

const type_int: ir.TypeRef = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
const type_bool: ir.TypeRef = .{ .name = "kotlin.Boolean", .nullable = false, .args = &.{} };

test "eval_int_const" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const f = try h.func("f", 0);
    const c7 = try h.constant(.{ .Int = 7 });
    try h.body(f, &.{.{ .insts = &.{hand.konst(0, c7)}, .term = hand.ret(0) }});
    try h.finish();
    const res = try eval(a, h.m, h.funcPtr(f), .empty);
    try testing.expect(res == .ok);
    try testing.expect(res.ok == .Int and res.ok.Int == 7);
}

test "eval reports a bodyless function instead of indexing empty blocks" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const f = try h.func("missing", 0);
    try h.finish();
    const result = try eval(a, h.m, h.funcPtr(f), .empty);
    try testing.expect(result == .err);
    try testing.expect(result.err == .CalleeFailed);
    try testing.expectEqualStrings("virtual method target is not executable", result.err.CalleeFailed);
}

test "eval_int_add" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const f = try h.func("f", 0);
    const c2 = try h.constant(.{ .Int = 2 });
    const c40 = try h.constant(.{ .Int = 40 });
    try h.body(f, &.{.{ .insts = &.{ hand.konst(0, c2), hand.konst(1, c40), hand.bin(2, .Add, 0, 1) }, .term = hand.ret(2) }});
    try h.finish();
    const result = try eval(a, h.m, h.funcPtr(f), .empty);
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .Int and result.ok.Int == 42);
}

test "eval_load_param" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const f = try h.func("f", 1);
    try h.body(f, &.{.{ .insts = &.{hand.param(0, 0)}, .term = hand.ret(0) }});
    try h.finish();
    var args: std.ArrayList(Value) = .empty;
    try args.append(a, .{ .Int = 99 });
    const v = try eval(a, h.m, h.funcPtr(f), args);
    try testing.expect(v == .ok);
    try testing.expect(v.ok == .Int and v.ok.Int == 99);
}

test "eval_branch" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const f = try h.func("f", 0);
    const t = try h.constant(.{ .Bool = true });
    const c1 = try h.constant(.{ .Int = 1 });
    const c0 = try h.constant(.{ .Int = 0 });
    try h.body(f, &.{
        .{ .insts = &.{hand.konst(0, t)}, .term = .{ .Branch = .{ .cond = hand.reg(0), .t = .from(1), .f = .from(2) } } },
        .{ .insts = &.{hand.konst(1, c1)}, .term = hand.ret(1) },
        .{ .insts = &.{hand.konst(2, c0)}, .term = hand.ret(2) },
    });
    try h.finish();
    const v = try eval(a, h.m, h.funcPtr(f), .empty);
    try testing.expect(v == .ok);
    try testing.expect(v.ok == .Int and v.ok.Int == 1);
}

test "suspend liveness keeps only values read on reachable resume paths" {
    resetSuspendLivenessCache();
    defer resetSuspendLivenessCache();

    const entry_insts = [_]Inst{
        .{ .Const = .{ .dst = .from(0), .value = .from(0) } },
        .{ .Const = .{ .dst = .from(1), .value = .from(1) } },
        .{ .Move = .{ .dst = .from(2), .src = .from(0) } },
        .{ .Const = .{ .dst = .from(3), .value = .from(2) } },
    };
    const blocks = [_]ir.Block{
        .{
            .id = .from(0),
            .insts = @constCast(&entry_insts),
            .terminator = .{ .Branch = .{ .cond = .from(2), .t = .from(1), .f = .from(2) } },
        },
        .{ .id = .from(1), .insts = &.{}, .terminator = .{ .Return = .from(0) } },
        .{ .id = .from(2), .insts = &.{}, .terminator = .{ .Return = .from(1) } },
    };
    const func: Func = .{
        .id = .from(0),
        .name = "resumePaths",
        .fqn = "test.resumePaths",
        .params = &.{},
        .return_ty = .{ .name = "Int", .nullable = false, .args = &.{} },
        .n_locals = 4,
        .blocks = @constCast(&blocks),
        .entry = .from(0),
        .is_suspend = true,
    };

    // Before the move both branch results are live; the move's destination and the dead fourth register are not.
    const before_move = try suspendLiveRegs(&func, .from(0), 2);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, before_move);
    const before_term = try suspendLiveRegs(&func, .from(0), entry_insts.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, before_term);
}

test "resumed labeled return reaches its snapshotted target frame" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);

    const inner_blocks = [_]ir.Block{.{
        .id = .from(0),
        .insts = &.{},
        .terminator = .{ .LabeledReturn = .{
            .label = "hasNext",
            .value = .from(0),
        } },
    }};
    const outer_blocks = [_]ir.Block{.{
        .id = .from(0),
        .insts = &.{},
        .terminator = .{ .Return = .from(0) },
    }};
    try m.funcs.append(testing.allocator, .{
        .id = .from(0),
        .name = "<lambda>",
        .fqn = "test.hasNext.<lambda>",
        .params = &.{},
        .return_ty = type_bool,
        .n_locals = 1,
        .blocks = @constCast(&inner_blocks),
        .entry = .from(0),
        .is_suspend = false,
        .is_lambda = true,
    });
    try m.funcs.append(testing.allocator, .{
        .id = .from(1),
        .name = "hasNext",
        .fqn = "test.hasNext",
        .params = &.{},
        .return_ty = type_bool,
        .n_locals = 1,
        .blocks = @constCast(&outer_blocks),
        .entry = .from(0),
        .is_suspend = true,
    });

    var state = SuspendState{ .token = 1 };
    const inner_regs = try testing.allocator.dupe(Value, &.{.{ .Bool = true }});
    const outer_regs = try testing.allocator.dupe(Value, &.{Value.Unit});
    const inner_params = try testing.allocator.alloc(Value, 0);
    const inner_captures = try testing.allocator.alloc(Value, 0);
    const inner_enclosing = try testing.allocator.alloc(EnclosingEntry, 0);
    const inner_try = try testing.allocator.alloc(TryFrame, 0);
    const outer_params = try testing.allocator.alloc(Value, 0);
    const outer_captures = try testing.allocator.alloc(Value, 0);
    const outer_enclosing = try testing.allocator.alloc(EnclosingEntry, 0);
    const outer_try = try testing.allocator.alloc(TryFrame, 0);
    try state.frames.append(testing.allocator, .{
        .func = .from(0),
        .module = null,
        .block = .from(0),
        .inst_idx = 0,
        .regs = .{ .dense = inner_regs },
        .params = inner_params,
        .captures = inner_captures,
        .enclosing_this = inner_enclosing,
        .try_stack = inner_try,
        .is_lambda = true,
        .resume_reg = null,
    });
    try state.frames.append(testing.allocator, .{
        .func = .from(1),
        .module = null,
        .block = .from(0),
        .inst_idx = 0,
        .regs = .{ .dense = outer_regs },
        .params = outer_params,
        .captures = outer_captures,
        .enclosing_this = outer_enclosing,
        .try_stack = outer_try,
        .is_lambda = false,
        .resume_reg = .from(0),
    });

    var host = nullHost();
    const result = try resumeContinuation(
        NullHost,
        testing.allocator,
        &m,
        &state,
        Value.Unit,
        &host,
    );
    // `resumeContinuation` consumes the frame list; clear the moved handle.
    state.frames = .empty;
    try testing.expect(result == .ok);
    try testing.expect(result.ok == .Bool and result.ok.Bool);
}

test "a resume value is made while the parked frames are rooted" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    const blocks = [_]ir.Block{.{
        .id = .from(0),
        .insts = &.{},
        .terminator = .{ .Return = .from(0) },
    }};
    try m.funcs.append(testing.allocator, .{
        .id = .from(0),
        .name = "awaitValue",
        .fqn = "test.awaitValue",
        .params = &.{},
        .return_ty = type_int,
        .n_locals = 1,
        .blocks = @constCast(&blocks),
        .entry = .from(0),
        .is_suspend = true,
    });
    var state = SuspendState{ .token = 1 };
    try state.frames.append(testing.allocator, .{
        .func = .from(0),
        .module = null,
        .block = .from(0),
        .inst_idx = 0,
        .regs = .{ .dense = try testing.allocator.dupe(Value, &.{Value.Unit}) },
        .params = try testing.allocator.alloc(Value, 0),
        .captures = try testing.allocator.alloc(Value, 0),
        .enclosing_this = try testing.allocator.alloc(EnclosingEntry, 0),
        .try_stack = try testing.allocator.alloc(TryFrame, 0),
        .is_lambda = false,
        .resume_reg = .from(0),
    });
    var host = nullHost();
    host.resume_as = .{ .Int = 7 };
    const result = try resumeContinuation(NullHost, testing.allocator, &m, &state, .{ .Int = 1 }, &host);
    state.frames = .empty;
    try testing.expect(host.resume_rooted);
    try testing.expect(result == .ok and result.ok == .Int and result.ok.Int == 7);
    try testing.expect(ev_state.evtlsPtr().resuming == null);
}

test "mixed signed comparisons widen to Double, then Float, then Long" {
    const nan = std.math.nan(f32);
    const cases = [_]struct { op: BinOp, l: Value, r: Value, want: bool }{
        // `i2f` rounds 16777217 to 16777216f.
        .{ .op = .Greater, .l = .{ .Int = 16777217 }, .r = .{ .Float = 16777216.0 }, .want = false },
        .{ .op = .Greater, .l = .{ .Int = 16777217 }, .r = .{ .Double = 16777216.0 }, .want = true },
        .{ .op = .LessEq, .l = .{ .Float = 2.5 }, .r = .{ .Double = 2.5 }, .want = true },
        .{ .op = .Less, .l = .{ .Float = 0.1 }, .r = .{ .Double = 0.1 }, .want = false },
        .{ .op = .Less, .l = .{ .Short = 2 }, .r = .{ .Long = 3 }, .want = true },
        .{ .op = .Less, .l = .{ .Int = 1 }, .r = .{ .Float = nan }, .want = false },
        .{ .op = .Greater, .l = .{ .Int = 1 }, .r = .{ .Float = nan }, .want = false },
    };
    for (cases) |c| {
        const r = try ev_values.applyBinop(testing.allocator, c.op, &c.l, &c.r);
        try testing.expect(r == .ok and r.ok == .Bool);
        try testing.expectEqual(c.want, r.ok.Bool);
    }
}

test "a Double equals a Float as a number, and boxed equality keeps the kind" {
    const nan = std.math.nan(f32);
    const cases = [_]struct { op: BinOp, l: Value, r: Value, want: bool }{
        .{ .op = .Eq, .l = .{ .Double = 0.0 }, .r = .{ .Float = -0.0 }, .want = true },
        .{ .op = .NotEq, .l = .{ .Double = 0.0 }, .r = .{ .Float = -0.0 }, .want = false },
        .{ .op = .Eq, .l = .{ .Float = 1.0 }, .r = .{ .Double = 1.0 }, .want = true },
        .{ .op = .Eq, .l = .{ .Float = 0.1 }, .r = .{ .Double = 0.1 }, .want = false },
        .{ .op = .Eq, .l = .{ .Double = std.math.nan(f64) }, .r = .{ .Float = nan }, .want = false },
        .{ .op = .NotEq, .l = .{ .Float = nan }, .r = .{ .Double = 1.0 }, .want = true },
        .{ .op = .BoxedEq, .l = .{ .Double = 1.0 }, .r = .{ .Float = 1.0 }, .want = false },
    };
    for (cases) |c| {
        const r = try ev_values.applyBinop(testing.allocator, c.op, &c.l, &c.r);
        try testing.expect(r == .ok and r.ok == .Bool);
        try testing.expectEqual(c.want, r.ok.Bool);
        // The scalar path every tier tries first answers the same.
        if (ev_exec.scalarBin(c.op, c.l, c.r)) |v| try testing.expectEqual(c.want, v.Bool);
    }
}

test "enclosing chain tags subjects and projects innermost-first" {
    var chain: std.ArrayList(EnclosingEntry) = .empty;
    defer chain.deinit(chainAllocator());
    const prev = ev_state.evtlsPtr().active_chain;
    ev_state.evtlsPtr().active_chain = &chain;
    defer ev_state.evtlsPtr().active_chain = prev;

    const receiver = Value{ .Int = 1 };
    const subject = Value{ .Int = 2 };
    pushEnclosing(&receiver);
    pushEnclosingSubject(&subject);

    const vals = try enclosingThisChainAlloc(testing.allocator);
    defer testing.allocator.free(vals);
    try testing.expectEqual(@as(usize, 2), vals.len);
    try testing.expect(vals[0] == .Int and vals[0].Int == 2);
    try testing.expect(vals[1] == .Int and vals[1].Int == 1);
    try testing.expect(enclosingThisLast().? == .Int and enclosingThisLast().?.Int == 2);

    const entries = try enclosingEntriesAlloc(testing.allocator);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expect(entries[0].isSubject() and entries[0].v.Int == 2);
    try testing.expect(!entries[1].isSubject() and entries[1].v.Int == 1);

    popEnclosing();
    const rest = try enclosingEntriesAlloc(testing.allocator);
    defer testing.allocator.free(rest);
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expect(!rest[0].isSubject() and rest[0].v.Int == 1);
    popEnclosing();
    try testing.expectEqual(@as(usize, 0), chain.items.len);
}

test "enclosing chain pushes are dropped with no active frame" {
    const prev = ev_state.evtlsPtr().active_chain;
    ev_state.evtlsPtr().active_chain = null;
    defer ev_state.evtlsPtr().active_chain = prev;

    const v = Value{ .Int = 7 };
    pushEnclosing(&v);
    pushEnclosingSubject(&v);
    popEnclosing();
    try testing.expect(enclosingThisLast() == null);
    const entries = try enclosingEntriesAlloc(testing.allocator);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}
