//! IR evaluator tests.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");


const Value = runtime.Value;

const BinOp = ir.BinOp;
const Const = ir.Const;
const Func = ir.Func;
const Inst = ir.Inst;
const Module = ir.Module;
const testing = std.testing;

const ev_activation = @import("activation.zig");
const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_host = @import("host.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");
const ev_exec = @import("exec.zig");

const NullHost = ev_host.NullHost;
const SuspendState = ev_snapshot.SuspendState;
const TryFrame = ev_snapshot.TryFrame;
const eval = ev_enter.eval;
const nullHost = ev_host.nullHost;
const ok = ev_flow.ok;
const resetSuspendLivenessCache = ev_snapshot.resetSuspendLivenessCache;
const resumeContinuation = ev_activation.resumeContinuation;
const suspendLiveRegs = ev_snapshot.suspendLiveRegs;

const hand = @import("hand.zig");
const Hand = hand.Hand;

const type_int: ir.TypeRef = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };

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

test "a resumed frame finds its block's entry span: the one every path leaves, or the one it parked with where paths leave two" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    const file = @import("span").FileId.from(2);
    const s1: ir.Span = .{ .file = file, .start = 1, .end = 5 };
    const s2: ir.Span = .{ .file = file, .start = 9, .end = 14 };
    // b0 (s1) and b1 (s2) both go on to b2, which calls the host before any statement of
    // its own: a frame parked there and resumed stands in the span it entered b2 with. b3,
    // which only b1 goes on to, finds s2 wherever the frame came from.
    const b0 = [_]Inst{.{ .Trace = .{ .span = s1 } }};
    const b1 = [_]Inst{.{ .Trace = .{ .span = s2 } }};
    const call = [_]Inst{.{ .CallNative = .{ .dst = .from(0), .native = .from(0), .args = .from(0), .n_args = 0, .direct = true } }};
    const blocks = [_]ir.Block{
        .{ .id = .from(0), .insts = @constCast(&b0), .terminator = .{ .Branch = .{ .cond = .from(0), .t = .from(1), .f = .from(2) } } },
        .{ .id = .from(1), .insts = @constCast(&b1), .terminator = .{ .Branch = .{ .cond = .from(0), .t = .from(2), .f = .from(3) } } },
        .{ .id = .from(2), .insts = @constCast(&call), .terminator = .{ .Return = .from(0) } },
        .{ .id = .from(3), .insts = @constCast(&call), .terminator = .{ .Return = .from(0) } },
    };
    try m.funcs.append(testing.allocator, .{
        .id = .from(0),
        .name = "resumeSpan",
        .fqn = "test.resumeSpan",
        .params = &.{},
        .return_ty = type_int,
        .n_locals = 1,
        .blocks = @constCast(&blocks),
        .entry = .from(0),
        .is_suspend = true,
    });
    for ([_]struct { block: u32, saved: ?ir.Span }{ .{ .block = 2, .saved = s2 }, .{ .block = 3, .saved = null } }) |c| {
        var state = SuspendState{ .token = 1 };
        try state.frames.append(testing.allocator, .{
            .func = .from(0),
            .module = null,
            .block = .from(c.block),
            .inst_idx = 0,
            .span = c.saved,
            .regs = .{ .dense = try testing.allocator.dupe(Value, &.{Value.Unit}) },
            .params = try testing.allocator.alloc(Value, 0),
            .captures = try testing.allocator.alloc(Value, 0),
            .try_stack = try testing.allocator.alloc(TryFrame, 0),
            .is_lambda = false,
            .resume_reg = null,
        });
        var host = nullHost();
        _ = try resumeContinuation(NullHost, testing.allocator, &m, &state, .Unit, &host);
        state.frames = .empty;
        try testing.expectEqual(@as(?ir.Span, s2), host.native_span);
    }
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

test "the scalar paths' floating-point arithmetic answers as applyBinop does" {
    const nan64 = std.math.nan(f64);
    const nan32 = std.math.nan(f32);
    const ops = [_]BinOp{ .Add, .Sub, .Mul, .Div, .Mod, .Less, .LessEq, .Greater, .GreaterEq, .Eq, .NotEq };
    const pairs = [_][2]Value{
        .{ .{ .Double = 1.5 }, .{ .Double = -0.25 } },
        .{ .{ .Double = 0.0 }, .{ .Double = -0.0 } },
        .{ .{ .Double = nan64 }, .{ .Double = nan64 } },
        .{ .{ .Double = 7.0 }, .{ .Double = 0.0 } },
        .{ .{ .Float = 2.5 }, .{ .Float = 0.1 } },
        .{ .{ .Float = nan32 }, .{ .Float = 1.0 } },
        .{ .{ .Float = -3.0 }, .{ .Float = 0.0 } },
        .{ .{ .Double = 2.5 }, .{ .Int = 3 } },
        .{ .{ .Long = -4 }, .{ .Double = 0.5 } },
    };
    for (pairs) |p| for (ops) |op| {
        const fast = ev_exec.scalarBin(op, p[0], p[1]) orelse ev_exec.wideScalarBin(op, p[0], p[1]) orelse continue;
        const r = try ev_values.applyBinop(testing.allocator, op, &p[0], &p[1]);
        try testing.expect(r == .ok);
        try testing.expect(Value.structuralEqBoxed(&fast, &r.ok));
        // The stream ops' path with no call in it answers the same where it answers.
        const quick = if (p[0] == .Float and p[1] == .Float)
            ev_exec.floatBinQuick(f32, op, p[0].Float, p[1].Float)
        else if (p[0] == .Double and p[1] == .Double)
            ev_exec.floatBinQuick(f64, op, p[0].Double, p[1].Double)
        else
            null;
        if (quick) |q| try testing.expect(Value.structuralEqBoxed(&q, &r.ok));
    };
    // The kind-keeping boxed equality is left to the generic arm.
    try testing.expect(ev_exec.floatScalarBin(.BoxedEq, .{ .Double = 0.0 }, .{ .Double = -0.0 }) == null);
}

test "the scalar path's conversions and Long shifts answer as the generic arms do" {
    const convs = [_]ir.UnOp{ .ToByte, .ToShort, .ToInt, .ToLong, .ToFloat, .ToDouble, .ToChar };
    const vals = [_]Value{
        .{ .Int = -1 },               .{ .Int = 70000 },          .{ .Long = 0x1_8000_0001 },
        .{ .Long = std.math.minInt(i64) }, .{ .Short = -300 },    .{ .Byte = -7 },
        .{ .Char = 0xFFFF },          .{ .Double = -2.9 },        .{ .Double = std.math.nan(f64) },
        .{ .Double = 1e300 },         .{ .Float = 4e9 },          .{ .Float = -0.5 },
    };
    for (vals) |v| for (convs) |op| {
        const fast = runtime.numconv.convert(op.conversion().?, v) orelse return error.TestUnexpectedResult;
        const r = try ev_values.applyUnop(testing.allocator, op, &v);
        try testing.expect(r == .ok);
        try testing.expect(Value.structuralEqBoxed(&fast, &r.ok));
    };
    // A shift over a count widened from `Int` is the shift by the `Int`.
    const x: Value = .{ .Long = -0x1234_5678_9ABC };
    for ([_]i32{ 0, 1, 31, 32, 63, 64, 65, -1 }) |n| for ([_]BinOp{ .Shl, .Shr, .UShr }) |op| {
        const fast = ev_exec.wideScalarBin(op, x, .{ .Long = n }) orelse return error.TestUnexpectedResult;
        const r = try ev_values.applyBinop(testing.allocator, op, &x, &Value{ .Int = n });
        try testing.expect(r == .ok);
        try testing.expect(Value.structuralEqBoxed(&fast, &r.ok));
    };
}

test "an operation with a constant operand its op carries answers as applyBinop does" {
    const ops = [_]BinOp{ .Add, .Sub, .Mul, .Div, .Mod, .Less, .LessEq, .Greater, .GreaterEq, .Eq, .NotEq, .BoxedEq, .BoxedNotEq, .And, .Or, .Xor, .Shl, .Shr, .UShr };
    const ks = [_]Const{
        .{ .Int = 0 },                     .{ .Int = 1 },     .{ .Int = -1 },   .{ .Int = 3 },          .{ .Int = 33 },
        .{ .Int = 0xff },                  .{ .Int = std.math.minInt(i32) }, .{ .Long = 0 }, .{ .Long = -1 }, .{ .Long = 64 },
        .{ .Long = std.math.minInt(i64) }, .{ .Long = 1 << 40 },           .{ .Float = 0.0 }, .{ .Float = -0.0 }, .{ .Float = 2.5 },
        .{ .Double = -0.0 },               .{ .Double = 1e300 },           .{ .ULong = std.math.maxInt(u64) }, .{ .UInt = 7 },
    };
    const xs = [_]Value{
        .{ .Int = 0 },     .{ .Int = -7 },    .{ .Int = std.math.minInt(i32) }, .{ .Int = std.math.maxInt(i32) },
        .{ .Long = 0 },    .{ .Long = -7 },   .{ .Long = std.math.minInt(i64) }, .{ .Long = 1 << 41 },
        .{ .Float = 0.0 }, .{ .Float = -0.0 }, .{ .Float = std.math.nan(f32) }, .{ .Float = std.math.inf(f32) },
        .{ .Double = 0.0 }, .{ .Double = std.math.nan(f64) }, .{ .Double = -2.5 },
        .{ .ULong = 0 },   .{ .ULong = std.math.maxInt(u64) }, .{ .UInt = 7 }, .{ .Short = 3 }, .{ .Bool = true },
    };
    var answered: usize = 0;
    for (ks) |k| for (ops) |op| {
        if (!ir.bc.foldable(op, k)) continue;
        const bits = ir.bc.kBits(k);
        const lo: u32 = @truncate(bits);
        const hi: u32 = @truncate(bits >> 32);
        const kv = ev_exec.kValue(ir.bc.kWord(.{ .reg = 0, .value = k, .op = op }), lo, hi);
        for ([_]bool{ false, true }) |left| {
            // A constant on the left is computed with the operator's mirror.
            const as_op = if (left) ir.bc.mirrored(op) orelse continue else op;
            const kw = ir.bc.kWord(.{ .reg = 0, .value = k, .op = as_op });
            for (xs) |x| {
                const fast = ev_exec.binK(kw, x, lo, hi) orelse continue;
                const r = if (left)
                    try ev_values.applyBinop(testing.allocator, op, &kv, &x)
                else
                    try ev_values.applyBinop(testing.allocator, op, &x, &kv);
                try testing.expect(r == .ok);
                try testing.expect(Value.structuralEqBoxed(&fast, &r.ok));
                answered += 1;
            }
        }
    };
    try testing.expect(answered > 500);
    // The constant written for the general path is the one its Const loads.
    const k: Const = .{ .Double = -0.0 };
    const bits = ir.bc.kBits(k);
    const v = ev_exec.kValue(ir.bc.kWord(.{ .reg = 0, .value = k, .op = .Add }), @truncate(bits), @truncate(bits >> 32));
    try testing.expect(v == .Double and std.math.signbit(v.Double));
}

test "a string concatenation made in one allocation reads as rendering both sides would, its length and ASCII-ness included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sides: std.ArrayList(Value) = .empty;
    for ([_][]const u8{ "", "v=", "日本", "a😀" }) |w| try sides.append(a, .{ .String = try runtime.strInit(a, w) });
    try sides.appendSlice(a, &.{
        .{ .Int = -7 },     .{ .Long = std.math.minInt(i64) }, .{ .ULong = std.math.maxInt(u64) }, .{ .Bool = true },
        .Null,              .{ .Char = 'x' },                  .{ .Short = -3 },                     .{ .UByte = 200 },
    });
    for (sides.items) |*l| for (sides.items) |*r| {
        const s = (try ev_values.concatInPlace(a, l, r)) orelse return error.TestUnexpectedResult;
        const want = try std.mem.concat(a, u8, &.{ try ev_values.renderValue(a, l), try ev_values.renderValue(a, r) });
        const d = s.asPtrConst();
        try testing.expectEqualStrings(want, d.bytes);
        const m = runtime.strMeta(want);
        try testing.expectEqual(m.u16_len, d.u16_len);
        try testing.expectEqual(m.ascii, d.ascii);
    };
    // A Char past ASCII and a Double are rendered.
    try testing.expect((try ev_values.concatInPlace(a, &Value{ .Char = 0xE9 }, &sides.items[0])) == null);
    try testing.expect((try ev_values.concatInPlace(a, &Value{ .Double = 1.5 }, &sides.items[0])) == null);
}
