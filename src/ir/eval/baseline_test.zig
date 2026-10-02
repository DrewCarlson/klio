//! The baseline JIT's compiled ops against the interpreter: each function
//! runs interpreted, then compiled at its first entry, and must answer the
//! same.

const std = @import("std");
const runtime = @import("runtime");
const jit = @import("jit");
const ir = @import("../ir.zig");

const baseline = @import("baseline.zig");
const masm = @import("masm.zig");
const ev_enter = @import("enter.zig");
const ev_host = @import("host.zig");
const hand = @import("hand.zig");
const ev_parent = @import("../eval.zig");

const Hand = hand.Hand;
const bc = ir.bc;
const Value = runtime.Value;
const testing = std.testing;

/// `f` run interpreted and then compiled: both answers, and whether it compiled.
/// Both runs take the calls' fast paths, which a run's diagnostic hooks turn off.
fn bothWays(a: std.mem.Allocator, h: *Hand, f: ir.FuncId, args: []const Value) !struct { Value, Value } {
    const hooks = ev_parent.call_hooks_on;
    ev_parent.call_hooks_on = false;
    defer ev_parent.call_hooks_on = hooks;
    var host: ev_host.NullHost = .{ .resolved_state = try ir.resolved.stateNew(a, h.r) };
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(a, args);
    const interpreted = try ev_enter.evalWith(ev_host.NullHost, a, h.m, h.funcPtr(f), list, &host);
    try testing.expect(interpreted == .ok);

    const was_enabled = baseline.enabled;
    const was_threshold = baseline.threshold;
    const was_min = baseline.min_native;
    baseline.enabled = true;
    baseline.threshold = 0;
    baseline.min_native = 0;
    defer {
        baseline.enabled = was_enabled;
        baseline.threshold = was_threshold;
        baseline.min_native = was_min;
    }
    const before = baseline.compiled_count.load(.monotonic);
    var list2: std.ArrayList(Value) = .empty;
    try list2.appendSlice(a, args);
    const compiled = try ev_enter.evalWith(ev_host.NullHost, a, h.m, h.funcPtr(f), list2, &host);
    try testing.expect(compiled == .ok);
    try testing.expect(baseline.compiled_count.load(.monotonic) > before);
    return .{ interpreted.ok, compiled.ok };
}

/// `f` compiled at its first entry and run: its answer, or null when it failed. The test
/// host runs no host function, so a run whose op went to a host function's handler fails.
fn compiledOnly(a: std.mem.Allocator, h: *Hand, f: ir.FuncId, args: []const Value) !?Value {
    return compiledWith(a, h, f, args, 0);
}

/// `compiledOnly` with the share of ops that must compile natively (`baseline.min_native`)
/// at `min_native` percent.
fn compiledWith(a: std.mem.Allocator, h: *Hand, f: ir.FuncId, args: []const Value, min_native: u32) !?Value {
    const hooks = ev_parent.call_hooks_on;
    ev_parent.call_hooks_on = false;
    defer ev_parent.call_hooks_on = hooks;
    var host: ev_host.NullHost = .{ .resolved_state = try ir.resolved.stateNew(a, h.r) };
    const was_enabled = baseline.enabled;
    const was_threshold = baseline.threshold;
    const was_min = baseline.min_native;
    baseline.enabled = true;
    baseline.threshold = 0;
    baseline.min_native = min_native;
    defer {
        baseline.enabled = was_enabled;
        baseline.threshold = was_threshold;
        baseline.min_native = was_min;
    }
    const before = baseline.compiled_count.load(.monotonic);
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(a, args);
    const r = try ev_enter.evalWith(ev_host.NullHost, a, h.m, h.funcPtr(f), list, &host);
    try testing.expect(baseline.compiled_count.load(.monotonic) > before);
    return if (r == .ok) r.ok else null;
}

/// A host function the compiled code must not reach.
fn notReached(ctx: *runtime.CallCtx) std.mem.Allocator.Error!runtime.EvalResult {
    _ = ctx;
    return .{ .err = .{ .Type = "the host function ran" } };
}

test "a compiled Int loop sums as the interpreter does, through its constants, compares and back edges" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const f = try h.func("sum", 1);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c3 = try h.constant(.{ .Int = 3 });
    // i = 0; s = 0; while (i < n) { s += i * 3 - 1 wrapping; s = s ^ i; i++ }; return s
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(2, c0) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = .{ .Branch = .{ .cond = hand.reg(3), .t = .from(2), .f = .from(3) } } },
        .{ .insts = &.{
            hand.konst(4, c3),       hand.bin(5, .Mul, 1, 4), hand.konst(6, c1), hand.bin(7, .Sub, 5, 6),
            hand.bin(2, .Add, 2, 7), hand.bin(2, .Xor, 2, 1), hand.konst(8, c1), hand.bin(1, .Add, 1, 8),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    try h.finish();
    const i, const c = try bothWays(a, &h, f, &.{.{ .Int = 70000 }});
    try testing.expect(i == .Int and c == .Int);
    try testing.expectEqual(i.Int, c.Int);
}

test "a compiled Long loop and its compares answer as the interpreter's" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const f = try h.func("longs", 1);
    const k0 = try h.constant(.{ .Long = 0 });
    const k1 = try h.constant(.{ .Long = 1 });
    const big = try h.constant(.{ .Long = 0x7fff_ffff_ffff });
    // i = 0; s = 0; while (i <= n) { s = s * 31 + i; if (s > big) s = s - big; i++ }; return s
    const k31 = try h.constant(.{ .Long = 31 });
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, k0), hand.konst(2, k0) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .LessEq, 1, 0)}, .term = .{ .Branch = .{ .cond = hand.reg(3), .t = .from(2), .f = .from(5) } } },
        .{ .insts = &.{ hand.konst(4, k31), hand.bin(2, .Mul, 2, 4), hand.bin(2, .Add, 2, 1), hand.konst(5, big), hand.bin(6, .Greater, 2, 5) }, .term = .{ .Branch = .{ .cond = hand.reg(6), .t = .from(3), .f = .from(4) } } },
        .{ .insts = &.{ hand.konst(7, big), hand.bin(2, .Sub, 2, 7) }, .term = hand.jump(4) },
        .{ .insts = &.{ hand.konst(8, k1), hand.bin(1, .Add, 1, 8) }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    try h.finish();
    const i, const c = try bothWays(a, &h, f, &.{.{ .Long = 50000 }});
    try testing.expect(i == .Long and c == .Long);
    try testing.expectEqual(i.Long, c.Long);
}

test "compiled field reads, null tests and moves answer as the interpreter's" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const k = try h.class("Pair", .{ .slot_names = &.{ "a", "b" }, .seeds = &.{ .int, .int } });
    const ctor = try h.func("<init>", 3);
    try h.body(ctor, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.param(2, 2), hand.setField(0, 0, 1), hand.setField(0, 1, 2) }, .term = hand.ret(0) }});
    const f = try h.func("fields", 1);
    const c10 = try h.constant(.{ .Int = 10 });
    const cnull = try h.constant(.Null);
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    // p = Pair(x, 10); r = p.a + p.b; q = p; if (q == null) r = 1 else r = r + 2; return r
    try h.body(f, &.{
        .{ .insts = &.{
            hand.param(0, 0),                                         hand.konst(1, c10),     hand.newInstance(2, k, ctor, 0, 2),
            hand.getField(3, 2, 0),                                   hand.getField(4, 2, 1), hand.bin(5, .Add, 3, 4),
            .{ .Move = .{ .dst = hand.reg(6), .src = hand.reg(2) } }, hand.konst(7, cnull),   hand.bin(8, .IdentEq, 6, 7),
        }, .term = .{ .Branch = .{ .cond = hand.reg(8), .t = .from(1), .f = .from(2) } } },
        .{ .insts = &.{hand.konst(5, c1)}, .term = hand.ret(5) },
        .{ .insts = &.{ hand.konst(9, c2), hand.bin(5, .Add, 5, 9) }, .term = hand.ret(5) },
    });
    try h.finish();
    const i, const c = try bothWays(a, &h, f, &.{.{ .Int = 32 }});
    try testing.expect(i == .Int and c == .Int);
    try testing.expectEqual(@as(i32, 44), c.Int);
    try testing.expectEqual(i.Int, c.Int);
}

test "an operand a compiled op's fast path does not take goes to its handler" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    // x + y, then (x + y) - y: Doubles take the handler, an Int that overflows wraps.
    const body: []const hand.Block = &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.bin(2, .Add, 0, 1), hand.bin(3, .Sub, 2, 1) }, .term = hand.ret(3) }};
    const doubles = try h.func("doubles", 2);
    try h.body(doubles, body);
    const ints = try h.func("ints", 2);
    try h.body(ints, body);
    try h.finish();
    {
        const i, const c = try bothWays(a, &h, doubles, &.{ .{ .Double = 1.25 }, .{ .Double = 2.5 } });
        try testing.expect(i == .Double and c == .Double);
        try testing.expectEqual(i.Double, c.Double);
    }
    {
        const i, const c = try bothWays(a, &h, ints, &.{ .{ .Int = std.math.maxInt(i32) }, .{ .Int = 5 } });
        try testing.expect(i == .Int and c == .Int);
        try testing.expectEqual(i.Int, c.Int);
    }
}

test "compiled float arithmetic and compares answer as the interpreter's, NaN included" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const half = try h.constant(.{ .Double = 0.5 });
    const quarter = try h.constant(.{ .Float = 0.25 });
    const ops = [_]ir.BinOp{ .Less, .LessEq, .Greater, .GreaterEq, .Eq, .NotEq };
    const cases = [_][2]f64{ .{ 1.5, 2.5 }, .{ 2.5, 2.5 }, .{ 3.0, -1.0 }, .{ std.math.nan(f64), 1.0 }, .{ 1.0, std.math.nan(f64) }, .{ 0.0, -0.0 } };
    // Per case and per width: one function per compare, answering x op y, and one
    // answering (x * y + k) / y - x with k a constant of the width.
    const Fn = struct { f: ir.FuncId, dbl: bool, case: usize };
    var fns: std.ArrayList(Fn) = .empty;
    for (cases, 0..) |_, ci| {
        for ([_]bool{ true, false }) |dbl| {
            for (ops) |op| {
                const f = try h.func("cmp", 2);
                try h.body(f, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.bin(2, op, 0, 1) }, .term = hand.ret(2) }});
                try fns.append(a, .{ .f = f, .dbl = dbl, .case = ci });
            }
            const f = try h.func("arith", 2);
            try h.body(f, &.{.{ .insts = &.{
                hand.param(0, 0),        hand.param(1, 1),        hand.bin(2, .Mul, 0, 1), hand.konst(3, if (dbl) half else quarter),
                hand.bin(4, .Add, 2, 3), hand.bin(5, .Div, 4, 1), hand.bin(6, .Sub, 5, 0),
            }, .term = hand.ret(6) }});
            try fns.append(a, .{ .f = f, .dbl = dbl, .case = ci });
        }
    }
    try h.finish();
    for (fns.items) |x| {
        const xy = cases[x.case];
        const args: [2]Value = if (x.dbl) .{ .{ .Double = xy[0] }, .{ .Double = xy[1] } } else .{ .{ .Float = @floatCast(xy[0]) }, .{ .Float = @floatCast(xy[1]) } };
        const i, const c = try bothWays(a, &h, x.f, &args);
        try testing.expectEqual(std.meta.activeTag(i), std.meta.activeTag(c));
        switch (i) {
            .Bool => |b| try testing.expectEqual(b, c.Bool),
            .Double => |d| try testing.expect(std.math.isNan(d) and std.math.isNan(c.Double) or d == c.Double),
            .Float => |d| try testing.expect(std.math.isNan(d) and std.math.isNan(c.Float) or d == c.Float),
            else => return error.TestUnexpectedResult,
        }
    }
}

fn branch(cond: u32, t: u32, f: u32) ir.Terminator {
    return .{ .Branch = .{ .cond = hand.reg(cond), .t = .from(t), .f = .from(f) } };
}

test "a compiled caller runs its small callees in place, callees within callees too" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const c5 = try h.constant(.{ .Int = 5 });
    // f(x) = if (x > 5) x * 2 else x + 1, its two arms joining at the return.
    const f = try h.func("f", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c5), hand.bin(2, .Greater, 0, 1) }, .term = branch(2, 1, 2) },
        .{ .insts = &.{ hand.konst(3, c2), hand.bin(4, .Mul, 0, 3) }, .term = hand.jump(3) },
        .{ .insts = &.{ hand.konst(3, c1), hand.bin(4, .Add, 0, 3) }, .term = hand.jump(3) },
        .{ .insts = &.{}, .term = hand.ret(4) },
    });
    // g(x) = f(x) + f(x + 1)
    const g = try h.func("g", 1);
    try h.body(g, &.{.{ .insts = &.{
        hand.param(0, 0), hand.callStatic(1, f, 0, 1), hand.konst(2, c1), hand.bin(3, .Add, 0, 2), hand.callStatic(4, f, 3, 1), hand.bin(5, .Add, 1, 4),
    }, .term = hand.ret(5) }});
    // i = 0; s = 0; while (i < n) { s = s + g(i); i++ }; return s
    const main = try h.func("main", 1);
    try h.body(main, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(2, c0) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
        .{ .insts = &.{ hand.callStatic(4, g, 1, 1), hand.bin(2, .Add, 2, 4), hand.konst(5, c1), hand.bin(1, .Add, 1, 5) }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    try h.finish();
    const before = baseline.inlined_count.load(.monotonic);
    const i, const c = try bothWays(a, &h, main, &.{.{ .Int = 20 }});
    try testing.expect(baseline.inlined_count.load(.monotonic) > before);
    try testing.expect(i == .Int and c == .Int);
    try testing.expectEqual(i.Int, c.Int);
}

test "a compiled call of the function itself goes to its direct entry, which opens the frame and goes on in its code" {
    if (comptime !jit.supported) return error.SkipZigTest;
    const runs = baseline.direct_entry_runs;
    try recursiveDirect(true);
    // r(18) makes 8,360 calls, nearly all of them past the first compile.
    try testing.expect(baseline.direct_entry_runs - runs > 8000);
}

test "a compiled call to a callee with no direct entry opens the frame in shared code and goes on in the callee's code" {
    if (comptime !jit.supported) return error.SkipZigTest;
    const runs = baseline.direct_runs;
    const shaped = baseline.direct_shaped_runs;
    const entry_runs = baseline.direct_entry_runs;
    try recursiveDirect(false);
    try testing.expect(baseline.direct_runs - runs > 8000);
    // Every call after the first finds the callee compiled and opens its frame from the record.
    try testing.expect(baseline.direct_shaped_runs - shaped > 8000);
    try testing.expectEqual(entry_runs, baseline.direct_entry_runs);
}

/// r(n) = if (n < 2) n else r(n - 1) + r(n - 2) for n = 18, compiled and interpreted, its calls
/// direct, going to its direct entry when `entries`.
fn recursiveDirect(entries: bool) !void {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    // A pooled frame, which a direct call opens, is the tracing collector's.
    const gc = runtime.gc;
    const prev_enabled = gc.gc_enabled;
    gc.gc_enabled = true;
    defer gc.gc_enabled = prev_enabled;
    gc.enterMutator();
    defer gc.exitMutator();
    const prev_direct = baseline.direct_calls;
    baseline.direct_calls = baseline.directLayoutHolds();
    defer baseline.direct_calls = prev_direct;
    const prev_entries = baseline.direct_entries;
    baseline.direct_entries = entries;
    defer baseline.direct_entries = prev_entries;
    // What the collector remembers of this test's memory goes before the memory does.
    defer runtime.gc.drainRemembered();
    var h = try Hand.init(a);
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    // A callee never compiled in place.
    const r = try h.func("r", 1);
    try h.body(r, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c2), hand.bin(2, .Less, 0, 1) }, .term = branch(2, 1, 2) },
        .{ .insts = &.{}, .term = hand.ret(0) },
        .{ .insts = &.{
            hand.konst(3, c1),            hand.bin(4, .Sub, 0, 3), hand.callStatic(5, r, 4, 1),
            hand.konst(6, c2),            hand.bin(7, .Sub, 0, 6), hand.callStatic(8, r, 7, 1),
            hand.bin(9, .Add, 5, 8),
        }, .term = hand.ret(9) },
    });
    try h.finish();
    const before = baseline.direct_count.load(.monotonic);
    const i, const c = try bothWays(a, &h, r, &.{.{ .Int = 18 }});
    try testing.expect(baseline.direct_count.load(.monotonic) > before);
    try testing.expect(i == .Int and c == .Int);
    try testing.expectEqual(@as(i32, 2584), c.Int);
    try testing.expectEqual(i.Int, c.Int);
}

test "a compiled virtual call of one class opens the implementation's frame itself, and a receiver of another class goes to its handler" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    const gc = runtime.gc;
    const prev_enabled = gc.gc_enabled;
    gc.gc_enabled = true;
    defer gc.gc_enabled = prev_enabled;
    gc.enterMutator();
    defer gc.exitMutator();
    const prev_direct = baseline.direct_calls;
    baseline.direct_calls = baseline.directLayoutHolds();
    defer baseline.direct_calls = prev_direct;
    // What the collector remembers of this test's memory goes before the memory does.
    defer runtime.gc.drainRemembered();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const ctor = try hand.ctorStoringMessage(&h);
    const ka = try h.class("A", .{ .seeds = &.{.int}, .slot_names = &.{"v"} });
    const kb = try h.class("B", .{ .seeds = &.{.int}, .slot_names = &.{"v"}, .supers = &.{ka} });
    // A.sum(n) = if (n < 1) 0 else n + this.sum(n - 1), through its virtual slot; B's the same
    // plus its field at the bottom, so a B receiver runs the other implementation.
    const a_sum = try h.func("A.sum", 2);
    const b_sum = try h.func("B.sum", 2);
    try h.body(a_sum, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.konst(2, c1), hand.bin(3, .Less, 1, 2) }, .term = branch(3, 1, 2) },
        .{ .insts = &.{hand.konst(4, c0)}, .term = hand.ret(4) },
        .{ .insts = &.{
            hand.bin(5, .Sub, 1, 2), .{ .Move = .{ .dst = hand.reg(6), .src = hand.reg(0) } }, .{ .Move = .{ .dst = hand.reg(7), .src = hand.reg(5) } },
            hand.callVirtual(8, a_sum, 6, 2), hand.bin(9, .Add, 1, 8),
        }, .term = hand.ret(9) },
    });
    try h.body(b_sum, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.konst(2, c1), hand.bin(3, .Less, 1, 2) }, .term = branch(3, 1, 2) },
        .{ .insts = &.{hand.getField(4, 0, 0)}, .term = hand.ret(4) },
        .{ .insts = &.{
            hand.bin(5, .Sub, 1, 2), .{ .Move = .{ .dst = hand.reg(6), .src = hand.reg(0) } }, .{ .Move = .{ .dst = hand.reg(7), .src = hand.reg(5) } },
            hand.callVirtual(8, a_sum, 6, 2), hand.bin(9, .Add, 1, 8),
        }, .term = hand.ret(9) },
    });
    try h.dispatch(ka, a_sum, a_sum);
    try h.dispatch(kb, a_sum, b_sum);
    // main(n) = A().sum(n) + B(1000).sum(n)
    const main = try h.func("main", 1);
    const c1000 = try h.constant(.{ .Int = 1000 });
    try h.body(main, &.{.{ .insts = &.{
        hand.param(0, 0),                     hand.konst(1, c0),                    hand.newInstance(2, ka, ctor, 1, 1),
        .{ .Move = .{ .dst = hand.reg(3), .src = hand.reg(2) } }, .{ .Move = .{ .dst = hand.reg(4), .src = hand.reg(0) } },
        hand.callVirtual(5, a_sum, 3, 2),     hand.konst(6, c1000),                 hand.newInstance(7, kb, ctor, 6, 1),
        .{ .Move = .{ .dst = hand.reg(8), .src = hand.reg(7) } }, .{ .Move = .{ .dst = hand.reg(9), .src = hand.reg(0) } },
        hand.callVirtual(10, a_sum, 8, 2),    hand.bin(11, .Add, 5, 10),
    }, .term = hand.ret(11) }});
    try h.finish();
    const before = baseline.direct_count.load(.monotonic);
    const runs = baseline.direct_entry_runs;
    const i, const c = try bothWays(a, &h, main, &.{.{ .Int = 60 }});
    try testing.expect(baseline.direct_count.load(.monotonic) > before);
    // `A.sum` calling itself goes to its direct entry.
    try testing.expect(baseline.direct_entry_runs - runs > 50);
    try testing.expect(i == .Int and c == .Int);
    // 1830 twice, and B's 1000 at the bottom.
    try testing.expectEqual(@as(i32, 1830 + 1830 + 1000), c.Int);
    try testing.expectEqual(i.Int, c.Int);
}

test "an op a callee compiled in place does not run there gets the callee's frames, and the calls finish" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c3 = try h.constant(.{ .Int = 3 });
    const c10 = try h.constant(.{ .Int = 10 });
    // q(x, y) = x / y + 1: an integer division leaves the compiled code.
    const q = try h.func("q", 2);
    try h.body(q, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.bin(2, .Div, 0, 1), hand.konst(3, c1), hand.bin(4, .Add, 2, 3) }, .term = hand.ret(4) }});
    // w(x) = q(x + 10, 3) * x
    const w = try h.func("w", 1);
    try h.body(w, &.{.{ .insts = &.{
        hand.param(0, 0), hand.konst(1, c10), hand.bin(2, .Add, 0, 1), hand.konst(3, c3), hand.callStatic(4, q, 2, 2), hand.bin(5, .Mul, 4, 0),
    }, .term = hand.ret(5) }});
    const main = try h.func("main", 1);
    try h.body(main, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(2, c0) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
        .{ .insts = &.{ hand.callStatic(4, w, 1, 1), hand.bin(2, .Add, 2, 4), hand.konst(5, c1), hand.bin(1, .Add, 1, 5) }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    try h.finish();
    const before = baseline.inlined_count.load(.monotonic);
    const i, const c = try bothWays(a, &h, main, &.{.{ .Int = 300 }});
    try testing.expect(baseline.inlined_count.load(.monotonic) >= before + 2);
    try testing.expect(i == .Int and c == .Int);
    try testing.expectEqual(i.Int, c.Int);
}

test "a callee compiled in place that leaves the code often is called from then on, and its caller compiles again" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    const was = baseline.exit_threshold;
    baseline.exit_threshold = 20;
    defer baseline.exit_threshold = was;
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c3 = try h.constant(.{ .Int = 3 });
    const c10 = try h.constant(.{ .Int = 10 });
    // q(x, y) = x / y + 1: an integer division leaves the compiled code.
    const q = try h.func("q", 2);
    try h.body(q, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.bin(2, .Div, 0, 1), hand.konst(3, c1), hand.bin(4, .Add, 2, 3) }, .term = hand.ret(4) }});
    // w(x) = q(x + 10, 3) * x
    const w = try h.func("w", 1);
    try h.body(w, &.{.{ .insts = &.{
        hand.param(0, 0), hand.konst(1, c10), hand.bin(2, .Add, 0, 1), hand.konst(3, c3), hand.callStatic(4, q, 2, 2), hand.bin(5, .Mul, 4, 0),
    }, .term = hand.ret(5) }});
    const main = try h.func("main", 1);
    try h.body(main, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(2, c0) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
        .{ .insts = &.{ hand.callStatic(4, w, 1, 1), hand.bin(2, .Add, 2, 4), hand.konst(5, c1), hand.bin(1, .Add, 1, 5) }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    try h.finish();
    const flagged = baseline.exits_hot_count.load(.monotonic);
    const recompiled = baseline.recompiled_count.load(.monotonic);
    const i, const c = try bothWays(a, &h, main, &.{.{ .Int = 300 }});
    try testing.expect(baseline.exits_hot_count.load(.monotonic) > flagged);
    try testing.expect(baseline.recompiled_count.load(.monotonic) > recompiled);
    try testing.expect(i == .Int and c == .Int);
    try testing.expectEqual(i.Int, c.Int);
}

test "a virtual call runs the implementations of the classes its site keeps in place, and any other class's as a call" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const c3 = try h.constant(.{ .Int = 3 });
    const c5 = try h.constant(.{ .Int = 5 });
    const c7 = try h.constant(.{ .Int = 7 });
    const c9 = try h.constant(.{ .Int = 9 });
    const c100 = try h.constant(.{ .Int = 100 });
    const ctor = try hand.ctorStoringMessage(&h);
    const ka = try h.class("A", .{ .seeds = &.{.int}, .slot_names = &.{"v"} });
    const kb = try h.class("B", .{ .seeds = &.{.int}, .slot_names = &.{"v"}, .supers = &.{ka} });
    const kc = try h.class("C", .{ .seeds = &.{.int}, .slot_names = &.{"v"}, .supers = &.{ka} });
    // A.get() = v + 100, B.get() = v * 2, C.get() = v - 1
    const a_get = try h.func("A.get", 1);
    try h.body(a_get, &.{.{ .insts = &.{ hand.param(0, 0), hand.getField(1, 0, 0), hand.konst(2, c100), hand.bin(3, .Add, 1, 2) }, .term = hand.ret(3) }});
    const b_get = try h.func("B.get", 1);
    try h.body(b_get, &.{.{ .insts = &.{ hand.param(0, 0), hand.getField(1, 0, 0), hand.konst(2, c2), hand.bin(3, .Mul, 1, 2) }, .term = hand.ret(3) }});
    const c_get = try h.func("C.get", 1);
    try h.body(c_get, &.{.{ .insts = &.{ hand.param(0, 0), hand.getField(1, 0, 0), hand.konst(2, c1), hand.bin(3, .Sub, 1, 2) }, .term = hand.ret(3) }});
    try h.dispatch(ka, a_get, a_get);
    try h.dispatch(kb, a_get, b_get);
    try h.dispatch(kc, a_get, c_get);
    // Receivers by i & 3: A, B, C, C. s = s + r.get().
    const main = try h.func("main", 1);
    try h.body(main, &.{
        .{ .insts = &.{
            hand.param(0, 0),                    hand.konst(1, c0),                   hand.konst(2, c0),
            hand.konst(4, c5),                   hand.newInstance(5, ka, ctor, 4, 1), hand.konst(6, c7),
            hand.newInstance(7, kb, ctor, 6, 1), hand.konst(8, c9),                   hand.newInstance(9, kc, ctor, 8, 1),
        }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(11, .Less, 1, 0)}, .term = branch(11, 2, 7) },
        .{ .insts = &.{ hand.konst(12, c3), hand.bin(13, .And, 1, 12), hand.konst(16, c0), hand.bin(17, .Eq, 13, 16) }, .term = branch(17, 3, 8) },
        .{ .insts = &.{.{ .Move = .{ .dst = hand.reg(14), .src = hand.reg(5) } }}, .term = hand.jump(6) },
        .{ .insts = &.{.{ .Move = .{ .dst = hand.reg(14), .src = hand.reg(7) } }}, .term = hand.jump(6) },
        .{ .insts = &.{.{ .Move = .{ .dst = hand.reg(14), .src = hand.reg(9) } }}, .term = hand.jump(6) },
        .{ .insts = &.{ hand.callVirtual(15, a_get, 14, 1), hand.bin(2, .Add, 2, 15), hand.konst(20, c1), hand.bin(1, .Add, 1, 20) }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
        .{ .insts = &.{ hand.konst(18, c1), hand.bin(19, .Eq, 13, 18) }, .term = branch(19, 4, 5) },
    });
    try h.finish();
    const before = baseline.inlined_count.load(.monotonic);
    const i, const c = try bothWays(a, &h, main, &.{.{ .Int = 400 }});
    try testing.expect(baseline.inlined_count.load(.monotonic) > before);
    try testing.expect(i == .Int and c == .Int);
    // 100 rounds of A (105), B (14) and two C (8 each).
    try testing.expectEqual(@as(i32, 100 * (105 + 14 + 8 + 8)), c.Int);
    try testing.expectEqual(i.Int, c.Int);
}

fn un(dst: u32, op: ir.UnOp, src: u32) ir.Inst {
    return .{ .UnOp = .{ .dst = hand.reg(dst), .op = op, .operand = hand.reg(src) } };
}

test "compiled identity, null and Bool equality, inversion and unsigned views answer as the interpreter's" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const ops = [_]ir.BinOp{ .IdentEq, .IdentNeq, .Eq, .NotEq, .BoxedEq };
    const pairs = [_][2]Value{
        .{ .Null, .Null },                          .{ .Null, .{ .Bool = true } },     .{ .{ .Bool = true }, .{ .Bool = true } },
        .{ .{ .Bool = true }, .{ .Bool = false } }, .{ .{ .Int = 3 }, .{ .Int = 3 } }, .{ .{ .Long = 7 }, .Null },
    };
    const Fn = struct { f: ir.FuncId, args: []const Value };
    var fns: std.ArrayList(Fn) = .empty;
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    // One function per case, each compiled at its first entry: as a value, and as a
    // branch's condition.
    for (ops) |op| {
        for (&pairs) |*p| {
            const v = try h.func("cmp", 2);
            try h.body(v, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.bin(2, op, 0, 1) }, .term = hand.ret(2) }});
            const b = try h.func("cmpBranch", 2);
            try h.body(b, &.{
                .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.bin(2, op, 0, 1) }, .term = branch(2, 1, 2) },
                .{ .insts = &.{hand.konst(3, c1)}, .term = hand.ret(3) },
                .{ .insts = &.{hand.konst(3, c2)}, .term = hand.ret(3) },
            });
            try fns.append(a, .{ .f = v, .args = p });
            try fns.append(a, .{ .f = b, .args = p });
        }
    }
    const signed = [_]Value{ .{ .Int = -6 }, .{ .Long = 0x1234_5678_9abc } };
    const unsigned = [_]Value{ .{ .ULong = 0xffff_0000_1234_5678 }, .{ .UInt = 0x8000_0001 } };
    for ([_]ir.UnOp{ .Inv, .ToULong, .ToUInt, .UnsignedBits }) |op| {
        for (if (op == .UnsignedBits) &unsigned else &signed) |*sc| {
            const f = try h.func("un", 1);
            try h.body(f, &.{.{ .insts = &.{ hand.param(0, 0), un(1, op, 0) }, .term = hand.ret(1) }});
            try fns.append(a, .{ .f = f, .args = sc[0..1] });
        }
    }
    try h.finish();
    for (fns.items) |x| {
        const i, const c = try bothWays(a, &h, x.f, x.args);
        try testing.expect(std.meta.eql(i, c));
    }
}

test "compiled Boolean and, or and xor answer as the interpreter's, as values and as conditions" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const bools = [_]Value{ .{ .Bool = false }, .{ .Bool = true } };
    const Fn = struct { f: ir.FuncId, args: [2]Value };
    var fns: std.ArrayList(Fn) = .empty;
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    for ([_]ir.BinOp{ .And, .Or, .Xor }) |op| {
        for (bools) |l| {
            for (bools) |r| {
                const v = try h.func("logic", 2);
                try h.body(v, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.bin(2, op, 0, 1) }, .term = hand.ret(2) }});
                const b = try h.func("logicBranch", 2);
                try h.body(b, &.{
                    .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.bin(2, op, 0, 1) }, .term = branch(2, 1, 2) },
                    .{ .insts = &.{hand.konst(3, c1)}, .term = hand.ret(3) },
                    .{ .insts = &.{hand.konst(3, c2)}, .term = hand.ret(3) },
                });
                try fns.append(a, .{ .f = v, .args = .{ l, r } });
                try fns.append(a, .{ .f = b, .args = .{ l, r } });
            }
        }
    }
    try h.finish();
    for (fns.items) |*x| {
        const i, const c = try bothWays(a, &h, x.f, &x.args);
        try testing.expect(std.meta.eql(i, c));
    }
}

test "compiled identity between instances answers by cell" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const ctor = try hand.ctorReturningThis(&h);
    const k = try h.class("K", .{});
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const c4 = try h.constant(.{ .Int = 4 });
    // p = K(); q = K(); r = p; bits: 1 when p === r, 2 when p === q, 4 when p !== q
    const f = try h.func("ident", 0);
    try h.body(f, &.{
        .{ .insts = &.{ hand.newInstance(0, k, ctor, 0, 0), hand.newInstance(1, k, ctor, 0, 0), .{ .Move = .{ .dst = hand.reg(2), .src = hand.reg(0) } }, hand.konst(3, c0), hand.bin(4, .IdentEq, 0, 2) }, .term = branch(4, 1, 2) },
        .{ .insts = &.{ hand.konst(5, c1), hand.bin(3, .Or, 3, 5) }, .term = hand.jump(2) },
        .{ .insts = &.{hand.bin(6, .IdentEq, 0, 1)}, .term = branch(6, 3, 4) },
        .{ .insts = &.{ hand.konst(5, c2), hand.bin(3, .Or, 3, 5) }, .term = hand.jump(4) },
        .{ .insts = &.{ hand.bin(7, .IdentNeq, 0, 1), hand.konst(8, c4), hand.konst(9, c0) }, .term = branch(7, 5, 6) },
        .{ .insts = &.{hand.bin(3, .Or, 3, 8)}, .term = hand.ret(3) },
        .{ .insts = &.{hand.bin(3, .Or, 3, 9)}, .term = hand.ret(3) },
    });
    try h.finish();
    const i, const c = try bothWays(a, &h, f, &.{});
    try testing.expectEqual(@as(i32, 5), c.Int);
    try testing.expectEqual(i.Int, c.Int);
}

test "the interpreter's hand-built programs answer the same compiled: statics, objects, type tests, boxing, arrays, throws" {
    if (comptime !jit.supported) return error.SkipZigTest;
    const programs = [_]*const fn (*Hand) std.mem.Allocator.Error!ir.FuncId{
        hand.staticChain, hand.dispatch, hand.seeds,        hand.statics,  hand.singleton,    hand.typeTests,
        hand.boxing,      hand.arrays,   hand.catchByClass, hand.vmThrows, hand.reusedThrows,
    };
    for (programs) |build| {
        var mem = hand.TestMemory.init();
        defer mem.deinit();
        const a = mem.allocator();
        var h = try Hand.init(a);
        const main = try build(&h);
        const hooks = ev_parent.call_hooks_on;
        ev_parent.call_hooks_on = false;
        defer ev_parent.call_hooks_on = hooks;
        // Each run from a fresh state: the programs write statics and build singletons.
        var host1: ev_host.NullHost = .{ .resolved_state = try ir.resolved.stateNew(a, h.r) };
        const interpreted = try ev_enter.evalWith(ev_host.NullHost, a, h.m, h.funcPtr(main), .empty, &host1);
        const was_enabled = baseline.enabled;
        const was_threshold = baseline.threshold;
        const was_min = baseline.min_native;
        baseline.enabled = true;
        baseline.threshold = 0;
        baseline.min_native = 0;
        defer {
            baseline.enabled = was_enabled;
            baseline.threshold = was_threshold;
            baseline.min_native = was_min;
        }
        var host2: ev_host.NullHost = .{ .resolved_state = try ir.resolved.stateNew(a, h.r) };
        const compiled = try ev_enter.evalWith(ev_host.NullHost, a, h.m, h.funcPtr(main), .empty, &host2);
        try testing.expect(interpreted == .ok and compiled == .ok);
        try testing.expect(std.meta.eql(interpreted.ok, compiled.ok));
    }
}

test "compiled type tests answer from their class cache as the interpreter does, across classes and nulls" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const ctor = try hand.ctorReturningThis(&h);
    const kb = try h.class("B", .{});
    const kd = try h.class("D", .{ .supers = &.{kb} });
    const ko = try h.class("O", .{});
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const c3 = try h.constant(.{ .Int = 3 });
    const c4 = try h.constant(.{ .Int = 4 });
    const cn = try h.constant(.Null);
    const mv = struct {
        fn f(dst: u32, src: u32) ir.Inst {
            return .{ .Move = .{ .dst = hand.reg(dst), .src = hand.reg(src) } };
        }
    }.f;
    // Receivers by i & 3: D, O, null, D. s += (x is B) + (x as? B !== null) * 2 + (x is B?) * 4
    const f = try h.func("tests", 1);
    try h.body(f, &.{
        // 0
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(2, c0), hand.newInstance(3, kd, ctor, 0, 0), hand.newInstance(4, ko, ctor, 0, 0), hand.konst(5, cn) }, .term = hand.jump(1) },
        // 1
        .{ .insts = &.{hand.bin(6, .Less, 1, 0)}, .term = branch(6, 2, 3) },
        // 2
        .{ .insts = &.{ hand.konst(7, c3), hand.bin(8, .And, 1, 7), hand.konst(9, c0), hand.bin(10, .Eq, 8, 9) }, .term = branch(10, 4, 5) },
        // 3
        .{ .insts = &.{}, .term = hand.ret(2) },
        // 4
        .{ .insts = &.{mv(11, 3)}, .term = hand.jump(8) },
        // 5
        .{ .insts = &.{ hand.konst(15, c1), hand.bin(16, .Eq, 8, 15) }, .term = branch(16, 6, 7) },
        // 6
        .{ .insts = &.{mv(11, 4)}, .term = hand.jump(8) },
        // 7
        .{ .insts = &.{ hand.konst(22, c2), hand.bin(23, .Eq, 8, 22) }, .term = branch(23, 9, 4) },
        // 8
        .{ .insts = &.{hand.instanceOf(12, 11, kb, false)}, .term = branch(12, 10, 11) },
        // 9
        .{ .insts = &.{mv(11, 5)}, .term = hand.jump(8) },
        // 10
        .{ .insts = &.{ hand.konst(13, c1), hand.bin(2, .Add, 2, 13) }, .term = hand.jump(11) },
        // 11
        .{ .insts = &.{ hand.cast(17, 11, kb, false, true), hand.konst(19, cn), hand.bin(20, .IdentNeq, 17, 19) }, .term = branch(20, 12, 13) },
        // 12
        .{ .insts = &.{ hand.konst(21, c2), hand.bin(2, .Add, 2, 21) }, .term = hand.jump(13) },
        // 13
        .{ .insts = &.{hand.instanceOf(18, 11, kb, true)}, .term = branch(18, 14, 15) },
        // 14
        .{ .insts = &.{ hand.konst(24, c4), hand.bin(2, .Add, 2, 24) }, .term = hand.jump(15) },
        // 15
        .{ .insts = &.{ hand.konst(25, c1), hand.bin(1, .Add, 1, 25) }, .term = hand.jump(1) },
    });
    try h.finish();
    const i, const c = try bothWays(a, &h, f, &.{.{ .Int = 400 }});
    try testing.expect(i == .Int and c == .Int);
    // 100 rounds: D twice (1 + 2 + 4 each), O none, null 4.
    try testing.expectEqual(@as(i32, 100 * (7 + 7 + 4)), c.Int);
    try testing.expectEqual(i.Int, c.Int);
}

test "the layouts compiled code reads hold in this build" {
    try testing.expect(baseline.layoutHolds());
    try testing.expect(baseline.objectLayoutHolds());
    try testing.expect(baseline.directLayoutHolds());
}

test "compiled reads of Int, Long and Double arrays answer as the interpreter's, and any other array reads through its handler" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const array_c = try h.class("Array", .{});
    h.r.host_class.array = array_c;
    const PK = runtime.PrimitiveArrayKind;
    var prim: [3]ir.ClassId = undefined;
    for ([_]PK{ .Int, .Long, .Double }, 0..) |k, i| {
        prim[i] = try h.class(@tagName(k), .{});
        h.r.host_class.prim_array[@intFromEnum(k)] = prim[i];
    }
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const k1 = try h.constant(.{ .Int = 11 });
    const k2 = try h.constant(.{ .Int = -7 });
    const l1 = try h.constant(.{ .Long = 1 << 40 });
    const l2 = try h.constant(.{ .Long = -3 });
    const d1 = try h.constant(.{ .Double = 0.25 });
    const d2 = try h.constant(.{ .Double = -8.5 });
    const Fn = struct { f: ir.FuncId, n: i32 };
    var fns: std.ArrayList(Fn) = .empty;
    // s = s + a[i % 2] over n turns, the elements' type throughout, for each kind and a boxed array.
    const elems = [_][2]ir.ConstId{ .{ k1, k2 }, .{ l1, l2 }, .{ d1, d2 }, .{ k1, k2 } };
    const classes = [_]ir.ClassId{ prim[0], prim[1], prim[2], array_c };
    const zeros = [_]ir.ConstId{ c0, try h.constant(.{ .Long = 0 }), try h.constant(.{ .Double = 0 }), c0 };
    for (elems, classes, zeros) |e, cls, z| {
        const f = try h.func("sum", 1);
        try h.body(f, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.konst(1, e[0]), hand.konst(2, e[1]), .{ .NewArray = .{ .dst = hand.reg(3), .class = cls, .args = hand.reg(1), .n_args = 2 } }, hand.konst(4, c0), hand.konst(5, z) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(6, .Less, 4, 0)}, .term = branch(6, 2, 3) },
            .{ .insts = &.{ hand.konst(7, c1), hand.bin(8, .And, 4, 7), .{ .ArrayGet = .{ .dst = hand.reg(9), .array = hand.reg(3), .index = hand.reg(8) } }, hand.bin(5, .Add, 5, 9), hand.bin(4, .Add, 4, 7) }, .term = hand.jump(1) },
            .{ .insts = &.{}, .term = hand.ret(5) },
        });
        try fns.append(a, .{ .f = f, .n = 301 });
    }
    try h.finish();
    for (fns.items) |x| {
        const i, const c = try bothWays(a, &h, x.f, &.{.{ .Int = x.n }});
        try testing.expect(std.meta.eql(i, c));
    }
}

test "a compiled Array<T> read takes no lock, and one overlapping a writer's turn reads through its handler" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c1 = try h.constant(.{ .Int = 1 });
    // a[1], twice: one function compiled with the turn closed, one with it open
    var fs: [2]ir.FuncId = undefined;
    for (&fs) |*f| {
        f.* = try h.func("second", 1);
        try h.body(f.*, &.{.{ .insts = &.{
            hand.param(0, 0), hand.konst(1, c1), .{ .ArrayGet = .{ .dst = hand.reg(2), .array = hand.reg(0), .index = hand.reg(1) } },
        }, .term = hand.ret(2) }});
    }
    try h.finish();
    var items: std.ArrayList(Value) = .empty;
    try items.appendSlice(a, &.{ .{ .Int = 4 }, .{ .Long = 9 } });
    const vl = try runtime.ValueList.initOwned(a, items);
    const arr = runtime.ArrayData.fromBoxedList(vl);
    const lock = &vl.cell.lock;
    try testing.expectEqual(@as(i64, 9), (try compiledOnly(a, &h, fs[0], &.{arr})).?.Long);
    try testing.expectEqual(@as(i32, 0), lock.state.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), lock.seq.load(.monotonic));
    // A turn left open, as a writer on another thread would hold it between its
    // stores: the handler reads under the lock, and the answer is the same.
    lock.seq.store(1, .monotonic);
    defer lock.seq.store(0, .monotonic);
    const i, const c = try bothWays(a, &h, fs[1], &.{arr});
    try testing.expectEqual(@as(i64, 9), i.Long);
    try testing.expect(std.meta.eql(i, c));
    try testing.expectEqual(@as(i32, 0), lock.state.load(.monotonic));
}

test "a compiled list read takes no lock where reads take none, and one overlapping a writer's turn leaves for its handler" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    const was = runtime.lockfreeReads();
    runtime.setLockfreeReads(true);
    defer runtime.setLockfreeReads(was);
    var h = try Hand.init(a);
    const get = try h.native("kotlin.collections.ArrayList.get", notReached);
    const c1 = try h.constant(.{ .Int = 1 });
    // list[1], twice: each case compiles a function of its own
    var fs: [2]ir.FuncId = undefined;
    for (&fs) |*f| {
        f.* = try h.func("second", 1);
        try h.body(f.*, &.{.{ .insts = &.{
            hand.param(0, 0), hand.konst(1, c1), .{ .CallNative = .{ .dst = hand.reg(2), .native = get, .args = hand.reg(0), .n_args = 2 } },
        }, .term = hand.ret(2) }});
    }
    try h.finish();
    var items: std.ArrayList(Value) = .empty;
    try items.appendSlice(a, &.{ .{ .Int = 4 }, .{ .Long = 9 } });
    const list = try Value.newList(a, .{ .items = try runtime.ValueList.initOwned(a, items), .mutable = true, .backing = null });
    const lock = &list.List.items.cell.lock;
    // The lock's state claims a writer, which the shared lock would wait on: only a
    // read that takes no lock answers.
    lock.state.store(std.math.minInt(i32), .monotonic);
    try testing.expectEqual(@as(i64, 9), (try compiledOnly(a, &h, fs[0], &.{list})).?.Long);
    lock.state.store(0, .monotonic);
    // A turn left open, as a writer on another thread would hold it: the compiled read
    // leaves for the handler, which reads under the lock.
    lock.seq.store(1, .monotonic);
    defer lock.seq.store(0, .monotonic);
    try testing.expect((try compiledOnly(a, &h, fs[1], &.{list})) == null);
    try testing.expectEqual(@as(i32, 0), lock.state.load(.monotonic));
}

test "a loop whose registers' kinds are known compiles without their tag checks, and answers the same" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const zero_l = try h.constant(.{ .Long = 0 });
    // var i = 0; var acc = 0L; while (i < n) { acc = acc + i.toLong(); i = i + 1 }; return acc
    var fs: [2]ir.FuncId = undefined;
    for (&fs) |*f| {
        f.* = try h.func("sum", 1);
        try h.body(f.*, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, zero_l) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
            .{ .insts = &.{
                .{ .UnOp = .{ .dst = hand.reg(4), .op = .ToLong, .operand = hand.reg(1) } },
                hand.bin(2, .Add, 2, 4),
                hand.konst(5, one),
                hand.bin(1, .Add, 1, 5),
            }, .term = hand.jump(1) },
            .{ .insts = &.{}, .term = hand.ret(2) },
        });
        h.m.funcByIdMut(f.*).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    }
    try h.finish();
    const was = baseline.use_kinds;
    defer baseline.use_kinds = was;
    // The checks and tag stores left out: none without the kinds; the counter's, the
    // compare's, the accumulator's and the parameter's with them.
    var known: [2]u32 = undefined;
    var pinned: [2]u32 = undefined;
    for (fs, [_]bool{ false, true }, &known, &pinned) |f, kinds, *k, *p| {
        baseline.use_kinds = kinds;
        const before = baseline.known_count.load(.monotonic);
        const pins_before = baseline.pinned_count.load(.monotonic);
        const i, const c = try bothWays(a, &h, f, &.{.{ .Int = 1000 }});
        k.* = baseline.known_count.load(.monotonic) - before;
        p.* = baseline.pinned_count.load(.monotonic) - pins_before;
        try testing.expectEqual(@as(i64, 499500), i.Long);
        try testing.expect(std.meta.eql(i, c));
    }
    try testing.expectEqual(@as(u32, 0), known[0]);
    try testing.expect(known[1] >= 4);
    // The counter, the bound and the accumulator stay in machine registers where the
    // backend has registers to keep them in.
    try testing.expectEqual(@as(u32, 0), pinned[0]);
    if (masm.Masm.n_pin_regs != 0) try testing.expect(pinned[1] >= 3);
}

test "a loop keeping its counter in a machine register gives it back across calls its handlers run" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    // inc(x): var j = 0; var s = x - 2; while (j < 3) { s = s + 1; j = j + 1 }; return s
    // A loop of its own, whose pins take the machine registers the caller's use.
    const three = try h.constant(.{ .Int = 3 });
    const two = try h.constant(.{ .Int = 2 });
    const inc = try h.func("inc", 1);
    try h.body(inc, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, two), hand.bin(3, .Sub, 0, 2), hand.konst(4, three) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(5, .Less, 1, 4)}, .term = branch(5, 2, 3) },
        .{ .insts = &.{ hand.konst(6, one), hand.bin(3, .Add, 3, 6), hand.konst(7, one), hand.bin(1, .Add, 1, 7) }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(3) },
    });
    h.m.funcByIdMut(inc).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    // var i = 0; var acc = 0; while (i < n) { acc = acc + inc(inc(i)); i = i + 1 }; return acc
    // Compiled at its first entry, both calls' sites are empty: each leaves for its handler,
    // and the second is entered from outside when the first returns.
    const f = try h.func("sum", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, zero) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
        .{ .insts = &.{
            .{ .Move = .{ .dst = hand.reg(4), .src = hand.reg(1) } },
            hand.callStatic(5, inc, 4, 1),
            hand.callStatic(6, inc, 5, 1),
            hand.bin(2, .Add, 2, 6),
            hand.konst(7, one),
            hand.bin(1, .Add, 1, 7),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const pins_before = baseline.pinned_count.load(.monotonic);
    const unpinned_before = baseline.unpinned_count.load(.monotonic);
    const got = (try compiledOnly(a, &h, f, &.{.{ .Int = 300 }})).?;
    try testing.expectEqual(@as(i32, 300 * 299 / 2 + 600), got.Int);
    if (masm.Masm.n_pin_regs != 0) try testing.expect(baseline.pinned_count.load(.monotonic) > pins_before);
    try testing.expectEqual(unpinned_before, baseline.unpinned_count.load(.monotonic));
}

test "an inner loop keeps its own pins, whatever its outer loop's head has not yet written" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const three = try h.constant(.{ .Int = 3 });
    // var i = 0; var acc = 0
    // while (i < n) { var j = 0; while (j < 3) { acc = acc + j; j = j + 1 }; i = i + 1 }
    // return acc
    // The inner loop's counter and bound are unwritten at the outer loop's head on its first
    // entry, so only a region of the inner loop's own can keep them.
    const f = try h.func("nested", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, zero) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 5) },
        .{ .insts = &.{ hand.konst(4, zero), hand.konst(9, three) }, .term = hand.jump(3) },
        .{ .insts = &.{hand.bin(5, .Less, 4, 9)}, .term = branch(5, 4, 6) },
        .{ .insts = &.{ hand.bin(2, .Add, 2, 4), hand.konst(6, one), hand.bin(4, .Add, 4, 6) }, .term = hand.jump(3) },
        .{ .insts = &.{}, .term = hand.ret(2) },
        .{ .insts = &.{ hand.konst(7, one), hand.bin(1, .Add, 1, 7) }, .term = hand.jump(1) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const pins_before = baseline.pinned_count.load(.monotonic);
    const i, const c = try bothWays(a, &h, f, &.{.{ .Int = 200 }});
    try testing.expectEqual(@as(i32, 600), c.Int);
    try testing.expect(std.meta.eql(i, c));
    // The outer loop's counter and bound, and the inner loop's counter and the sum; one
    // region over both loops keeps only the three written before the outer loop.
    if (masm.Masm.n_pin_regs != 0) try testing.expect(baseline.pinned_count.load(.monotonic) - pins_before >= 4);
}

test "a loop compiles whatever its exit block, laid out inside it, leaves to handlers" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const inc = try h.func("inc", 1);
    try h.body(inc, &.{.{ .insts = &.{ hand.param(0, 0), hand.konst(1, one), hand.bin(2, .Add, 0, 1) }, .term = hand.ret(2) }});
    // var i = 0; var acc = 0; while (i < n) { acc = acc + i; i = i + 1 }; return inc(inc(...inc(acc)))
    // The exit block lies between the loop's head and its back edge, and its calls, their
    // sites empty when the function compiles at its first entry, leave to their handlers:
    // they are no part of the loop.
    var calls: [12]ir.Inst = undefined;
    for (&calls, 0..) |*c, k| c.* = hand.callStatic(@intCast(6 + k), inc, @intCast(if (k == 0) 2 else 5 + k), 1);
    const f = try h.func("sumThenCalls", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, zero) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
        .{ .insts = &.{ hand.bin(2, .Add, 2, 1), hand.konst(4, one), hand.bin(1, .Add, 1, 4) }, .term = hand.jump(4) },
        .{ .insts = &calls, .term = hand.ret(17) },
        .{ .insts = &.{}, .term = hand.jump(1) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    // At the share a program compiles with: the loop's ops all compile natively, so
    // nothing is declined (`inc` compiles too, so the compiled count cannot say).
    const declined_before = baseline.declined_count.load(.monotonic);
    const got = (try compiledWith(a, &h, f, &.{.{ .Int = 100 }}, 70)).?;
    try testing.expectEqual(@as(i32, 100 * 99 / 2 + 12), got.Int);
    try testing.expectEqual(declined_before, baseline.declined_count.load(.monotonic));
}

test "a callee compiled in place skips the checks its call's arguments prove" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    // add2(x, y) = x + y, called as acc = add2(acc, i) in a loop over Ints
    const add2 = try h.func("add2", 2);
    try h.body(add2, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.bin(2, .Add, 0, 1) }, .term = hand.ret(2) }});
    const f = try h.func("sumByCalls", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, zero) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
        .{ .insts = &.{
            .{ .Move = .{ .dst = hand.reg(4), .src = hand.reg(2) } },
            .{ .Move = .{ .dst = hand.reg(5), .src = hand.reg(1) } },
            hand.callStatic(2, add2, 4, 2),
            hand.konst(6, one),
            hand.bin(1, .Add, 1, 6),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    // The interpreted run fills the call site, so the compile puts the callee in place,
    // its operands' kinds known from the arguments.
    const before = baseline.known_in_place_count.load(.monotonic);
    const i, const c = try bothWays(a, &h, f, &.{.{ .Int = 50 }});
    try testing.expectEqual(@as(i32, 49 * 50 / 2), c.Int);
    try testing.expect(std.meta.eql(i, c));
    try testing.expect(baseline.known_in_place_count.load(.monotonic) > before);
}

test "a loop keeps a temporary it writes before reading in a machine register, and gives it to a call's handler" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const inc = try h.func("inc", 1);
    try h.body(inc, &.{.{ .insts = &.{ hand.param(0, 0), hand.konst(1, one), hand.bin(2, .Add, 0, 1) }, .term = hand.ret(2) }});
    // var i = 0; var acc = 0; while (i < n) { t = i + i; acc = acc + inc(t); i = i + 1 }; return acc
    // `t` is unwritten at the loop's head on the way in; the call, its site empty when the
    // function compiles at its first entry, reads it from the frame in its handler.
    const f = try h.func("sumTemps", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, zero) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
        .{ .insts = &.{
            hand.bin(4, .Add, 1, 1),
            .{ .Move = .{ .dst = hand.reg(5), .src = hand.reg(4) } },
            hand.callStatic(6, inc, 5, 1),
            hand.bin(2, .Add, 2, 6),
            hand.konst(7, one),
            hand.bin(1, .Add, 1, 7),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const pins_before = baseline.pinned_count.load(.monotonic);
    const got = (try compiledOnly(a, &h, f, &.{.{ .Int = 100 }})).?;
    // sum of (2i + 1) for i below 100
    try testing.expectEqual(@as(i32, 100 * 100), got.Int);
    // The counter, the bound and the sum, and the temporaries `t` and the call's argument:
    // one region over the loop keeps only the first three with no temporaries.
    if (masm.Masm.n_pin_regs != 0) try testing.expect(baseline.pinned_count.load(.monotonic) - pins_before >= 4);
}

test "a register a loop also writes with what the kinds cannot tell is no temporary it keeps" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const big = try h.constant(.{ .Long = 1 << 40 });
    // var i = 0; var acc = 0
    // while (i < n) { t = i + i; u = t + t + t + t; if (i % 2 == 0) s = 2^40L; t = s; acc = acc + i; i = i + 1 }
    // `s` is written on one arm only, so the kinds call it unwritten where `t = s` reads it,
    // and `t` holds a Long there, not the Int its other write leaves.
    const two = try h.constant(.{ .Int = 2 });
    const f = try h.func("unwrittenMove", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, zero) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 6) },
        .{ .insts = &.{
            hand.bin(4, .Add, 1, 1), hand.bin(11, .Add, 4, 4), hand.bin(11, .Add, 4, 11), hand.bin(11, .Add, 4, 11),
            hand.konst(8, two),      hand.bin(9, .Mod, 1, 8),  hand.bin(10, .Eq, 9, 2),
        }, .term = branch(10, 3, 4) },
        .{ .insts = &.{hand.konst(5, big)}, .term = hand.jump(5) },
        .{ .insts = &.{}, .term = hand.jump(5) },
        .{ .insts = &.{
            .{ .Move = .{ .dst = hand.reg(4), .src = hand.reg(5) } },
            hand.bin(2, .Add, 2, 1),
            hand.konst(7, one),
            hand.bin(1, .Add, 1, 7),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const i, const c = try bothWays(a, &h, f, &.{.{ .Int = 10 }});
    try testing.expectEqual(@as(i32, 45), c.Int);
    try testing.expect(std.meta.eql(i, c));
}

test "a parameter declared an Int that arrives as another kind runs in the handlers, and answers as the interpreter does" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const one = try h.constant(.{ .Int = 1 });
    // n + 1 + n, with n declared an Int
    var fs: [2]ir.FuncId = undefined;
    for (&fs) |*f| {
        f.* = try h.func("twice", 1);
        try h.body(f.*, &.{.{ .insts = &.{ hand.param(0, 0), hand.konst(1, one), hand.bin(2, .Add, 0, 1), hand.bin(3, .Add, 2, 0) }, .term = hand.ret(3) }});
        h.m.funcByIdMut(f.*).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    }
    try h.finish();
    const i, const c = try bothWays(a, &h, fs[0], &.{.{ .Int = 20 }});
    try testing.expectEqual(@as(i32, 41), c.Int);
    try testing.expect(std.meta.eql(i, c));
    // A Long where the declaration says Int: nothing compiled for an Int may run on it.
    const li, const lc = try bothWays(a, &h, fs[1], &.{.{ .Long = 1 << 40 }});
    try testing.expect(std.meta.eql(li, lc));
}

test "a loop keeping a parameter declared a Long in a machine register answers as the interpreter does, given a Long or an Int" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const three = try h.constant(.{ .Int = 3 });
    // var i = 0; var acc = h; while (i < 3) { acc = acc + (h shr 1); i = i + 1 }; return acc
    // with h declared a Long, so the loop keeps it pinned, and passed an Int: taken for a
    // Long, a negative Int's word shifts in zeros where an Int shifts in its sign.
    var fs: [2]ir.FuncId = undefined;
    for (&fs) |*f| {
        f.* = try h.func("addTimes", 1);
        try h.body(f.*, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), .{ .Move = .{ .dst = hand.reg(2), .src = hand.reg(0) } }, hand.konst(3, three) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(4, .Less, 1, 3)}, .term = branch(4, 2, 3) },
            .{ .insts = &.{ hand.konst(6, one), hand.bin(7, .Shr, 0, 6), hand.bin(2, .Add, 2, 7), hand.konst(5, one), hand.bin(1, .Add, 1, 5) }, .term = hand.jump(1) },
            .{ .insts = &.{}, .term = hand.ret(2) },
        });
        h.m.funcByIdMut(f.*).?.params[0].ty = .{ .name = "kotlin.Long", .nullable = false, .args = &.{} };
    }
    // Each called, so the call enters it past its parameter loads, the frame holding them.
    var callers: [2]ir.FuncId = undefined;
    for (&callers, fs) |*cf, f| {
        cf.* = try h.func("caller", 1);
        try h.body(cf.*, &.{.{ .insts = &.{ hand.param(0, 0), hand.callStatic(1, f, 0, 1) }, .term = hand.ret(1) }});
    }
    try h.finish();
    const i, const c = try bothWays(a, &h, callers[0], &.{.{ .Long = 1 << 40 }});
    try testing.expectEqual(@as(i64, (1 << 40) + 3 * (1 << 39)), c.Long);
    try testing.expect(std.meta.eql(i, c));
    // An Int where the declaration says Long: the pinned code may not take it for one.
    // Compiled at the caller's first entry, its call site is empty and stays a call.
    const got = (try compiledOnly(a, &h, callers[1], &.{.{ .Int = -5 }})).?;
    try testing.expectEqual(Value{ .Int = -5 + 3 * -3 }, got);
}

test "compiled division and remainder by a constant answer as the interpreter's, -1 and the minimum included" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const Fn = struct { f: ir.FuncId, x: Value };
    var fns: std.ArrayList(Fn) = .empty;
    const ints = [_]i32{ std.math.minInt(i32), std.math.maxInt(i32), -7, 7, 0 };
    const longs = [_]i64{ std.math.minInt(i64), std.math.maxInt(i64), -7, 7, 0 };
    for ([_]ir.BinOp{ .Div, .Mod }) |op| {
        for ([_]i32{ 3, -3, -1, 7 }) |k| {
            const ki = try h.constant(.{ .Int = k });
            const kl = try h.constant(.{ .Long = k });
            for (ints) |x| {
                const f = try h.func("divInt", 1);
                try h.body(f, &.{.{ .insts = &.{ hand.param(0, 0), hand.konst(1, ki), hand.bin(2, op, 0, 1) }, .term = hand.ret(2) }});
                try fns.append(a, .{ .f = f, .x = .{ .Int = x } });
            }
            for (longs) |x| {
                const f = try h.func("divLong", 1);
                try h.body(f, &.{.{ .insts = &.{ hand.param(0, 0), hand.konst(1, kl), hand.bin(2, op, 0, 1) }, .term = hand.ret(2) }});
                try fns.append(a, .{ .f = f, .x = .{ .Long = x } });
            }
        }
    }
    try h.finish();
    for (fns.items) |x| {
        const i, const c = try bothWays(a, &h, x.f, &.{x.x});
        try testing.expect(std.meta.eql(i, c));
    }
}

test "compiled stores into Int, Long and Double arrays and into an Array<T> answer as the interpreter's" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const array_c = try h.class("Array", .{});
    h.r.host_class.array = array_c;
    const PK = runtime.PrimitiveArrayKind;
    var prim: [3]ir.ClassId = undefined;
    for ([_]PK{ .Int, .Long, .Double }, 0..) |k, i| {
        prim[i] = try h.class(@tagName(k), .{});
        h.r.host_class.prim_array[@intFromEnum(k)] = prim[i];
    }
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const steps = [_]ir.ConstId{ try h.constant(.{ .Int = 5 }), try h.constant(.{ .Long = 1 << 33 }), try h.constant(.{ .Double = 0.75 }), try h.constant(.{ .Int = 5 }) };
    const zeros = [_]ir.ConstId{ c0, try h.constant(.{ .Long = 0 }), try h.constant(.{ .Double = 0 }), c0 };
    const classes = [_]ir.ClassId{ prim[0], prim[1], prim[2], array_c };
    const Fn = struct { f: ir.FuncId };
    var fns: std.ArrayList(Fn) = .empty;
    // a = [z, z]; over n turns a[i & 1] = a[i & 1] + step; then a[0] + a[1]. The Array<T>'s
    // reads after its stores take its shared lock, so a store that left it held hangs.
    for (steps, zeros, classes) |st, z, cls| {
        const f = try h.func("fill", 1);
        try h.body(f, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.konst(1, z), hand.konst(2, z), .{ .NewArray = .{ .dst = hand.reg(3), .class = cls, .args = hand.reg(1), .n_args = 2 } }, hand.konst(4, c0) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(5, .Less, 4, 0)}, .term = branch(5, 2, 3) },
            .{ .insts = &.{
                hand.konst(6, c1),                                                                    hand.bin(7, .And, 4, 6),
                .{ .ArrayGet = .{ .dst = hand.reg(8), .array = hand.reg(3), .index = hand.reg(7) } }, hand.konst(9, st),
                hand.bin(10, .Add, 8, 9),                                                             .{ .ArraySet = .{ .array = hand.reg(3), .index = hand.reg(7), .value = hand.reg(10) } },
                hand.bin(4, .Add, 4, 6),
            }, .term = hand.jump(1) },
            .{ .insts = &.{ hand.konst(11, c0), .{ .ArrayGet = .{ .dst = hand.reg(12), .array = hand.reg(3), .index = hand.reg(11) } }, hand.konst(13, c1), .{ .ArrayGet = .{ .dst = hand.reg(14), .array = hand.reg(3), .index = hand.reg(13) } }, hand.bin(15, .Add, 12, 14) }, .term = hand.ret(15) },
        });
        try fns.append(a, .{ .f = f });
    }
    try h.finish();
    for (fns.items) |x| {
        const i, const c = try bothWays(a, &h, x.f, &.{.{ .Int = 301 }});
        try testing.expect(std.meta.eql(i, c));
    }
}

test "a compiled store into a tenured Array<T> stores in place once remembered, and otherwise records itself as the write barrier does" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c1 = try h.constant(.{ .Int = 1 });
    // a[1] = a[1] + 1
    const f = try h.func("bump", 1);
    try h.body(f, &.{.{ .insts = &.{
        hand.param(0, 0),                                                                       hand.konst(1, c1),
        .{ .ArrayGet = .{ .dst = hand.reg(2), .array = hand.reg(0), .index = hand.reg(1) } },   hand.bin(3, .Add, 2, 1),
        .{ .ArraySet = .{ .array = hand.reg(0), .index = hand.reg(1), .value = hand.reg(3) } },
    }, .term = hand.ret(3) }});
    try h.finish();
    var items: std.ArrayList(Value) = .empty;
    try items.appendSlice(a, &.{ .{ .Int = 0 }, .{ .Int = 0 } });
    const vl = try runtime.ValueList.initOwned(a, items);
    const arr = runtime.ArrayData.fromBoxedList(vl);
    const hdr = &vl.cell.hdr;
    hdr.gc_gen = 1;
    defer runtime.gc.drainRemembered();
    _ = try bothWays(a, &h, f, &.{arr});
    try testing.expect(hdr.gc_remembered);
    try testing.expectEqual(@as(i32, 2), vl.cell.data.items[1].Int);
    // Compiled, and forgotten by the collector: the store must be recorded again.
    runtime.gc.drainRemembered();
    const hooks = ev_parent.call_hooks_on;
    ev_parent.call_hooks_on = false;
    defer ev_parent.call_hooks_on = hooks;
    var host: ev_host.NullHost = .{ .resolved_state = try ir.resolved.stateNew(a, h.r) };
    var args: std.ArrayList(Value) = .empty;
    try args.append(a, arr);
    const again = try ev_enter.evalWith(ev_host.NullHost, a, h.m, h.funcPtr(f), args, &host);
    try testing.expect(again == .ok);
    try testing.expect(hdr.gc_remembered);
    try testing.expectEqual(@as(i32, 3), vl.cell.data.items[1].Int);
    try testing.expectEqual(@as(i32, 0), vl.cell.lock.state.load(.monotonic));
    // Every store took a turn of the write sequence and gave it back.
    const seq = vl.cell.lock.seq.load(.monotonic);
    try testing.expect(seq != 0 and seq & 1 == 0);
}

test "compiled list reads and sizes answer in place, and any other receiver or index goes to the host function" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const get = try h.native("kotlin.collections.ArrayList.get", notReached);
    const size = try h.native("kotlin.collections.ArrayList.size", notReached);
    // list[i] + list.size, one function per case
    const Case = struct { recv: Value, i: i32, want: ?i32 };
    var items: std.ArrayList(Value) = .empty;
    try items.appendSlice(a, &.{ .{ .Int = 10 }, .{ .Long = 7 }, .{ .Int = 30 } });
    const list = try Value.newList(a, .{ .items = try runtime.ValueList.initOwned(a, items), .mutable = true, .backing = null });
    const cases = [_]Case{
        .{ .recv = list, .i = 0, .want = 13 },
        .{ .recv = list, .i = 2, .want = 33 },
        .{ .recv = list, .i = 3, .want = null },
        .{ .recv = list, .i = -1, .want = null },
        .{ .recv = .{ .Int = 4 }, .i = 0, .want = null },
    };
    var fns: std.ArrayList(ir.FuncId) = .empty;
    for (cases) |cs| {
        const ki = try h.constant(.{ .Int = cs.i });
        const f = try h.func("readList", 1);
        try h.body(f, &.{.{ .insts = &.{
            hand.param(0, 0),                                                                             hand.konst(1, ki),
            .{ .CallNative = .{ .dst = hand.reg(2), .native = get, .args = hand.reg(0), .n_args = 2 } },  .{ .Move = .{ .dst = hand.reg(3), .src = hand.reg(0) } },
            .{ .CallNative = .{ .dst = hand.reg(4), .native = size, .args = hand.reg(3), .n_args = 1 } }, hand.bin(5, .Add, 2, 4),
        }, .term = hand.ret(5) }});
        try fns.append(a, f);
    }
    try h.finish();
    for (cases, fns.items) |cs, f| {
        const got = try compiledOnly(a, &h, f, &.{cs.recv});
        if (cs.want) |w| try testing.expectEqual(w, got.?.Int) else try testing.expect(got == null);
    }
    const cell = list.List.items.cell;
    try testing.expectEqual(@as(i32, 0), cell.lock.state.load(.monotonic));
}

test "compiled hashCode takes a fresh instance's identity in place, and answers it again after" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const k = try h.class("Plain", .{ .slot_names = &.{"a"}, .seeds = &.{.int} });
    const hash = try h.native("kotlin.Any.hashCode", notReached);
    // p.hashCode() - p.hashCode() + p.hashCode(), thrice over: the second sees it taken
    var fs: [3]ir.FuncId = undefined;
    for (&fs) |*f| {
        f.* = try h.func("hashTwice", 1);
        try h.body(f.*, &.{.{ .insts = &.{
            hand.param(0, 0),
            .{ .CallNative = .{ .dst = hand.reg(1), .native = hash, .args = hand.reg(0), .n_args = 1 } },
            .{ .CallNative = .{ .dst = hand.reg(2), .native = hash, .args = hand.reg(0), .n_args = 1 } },
            hand.bin(3, .Sub, 1, 2),
            hand.bin(4, .Add, 3, 1),
        }, .term = hand.ret(4) }});
    }
    try h.finish();
    const p = try ir.resolved.instantiate(a, h.r, k);
    try testing.expectEqual(@as(u32, 0), p.Instance.cell.hdr.gc_aux);
    const got = (try compiledOnly(a, &h, fs[0], &.{p})).?;
    // The number compiled code took is the one the instance keeps.
    const id: u64 = p.Instance.cell.hdr.gc_aux;
    try testing.expect(id != 0);
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, @truncate(id)))), got.Int);
    try testing.expectEqual(id, p.Instance.cell.data.identityOf());
    // One already taken is read, not taken again.
    const again = (try compiledOnly(a, &h, fs[1], &.{p})).?;
    try testing.expectEqual(got.Int, again.Int);
    try testing.expectEqual(id, @as(u64, p.Instance.cell.hdr.gc_aux));
    // A counter whose next low word is 0 gives 1: 0 is an identity not yet taken.
    const counter = runtime.InstanceData.identityCounter();
    const was = counter.load(.monotonic);
    defer counter.store(was, .monotonic);
    counter.store(0xFFFF_FFFF, .monotonic);
    const q = try ir.resolved.instantiate(a, h.r, k);
    try testing.expectEqual(@as(i32, 1), (try compiledOnly(a, &h, fs[2], &.{q})).?.Int);
    try testing.expectEqual(@as(u32, 1), q.Instance.cell.hdr.gc_aux);
}

test "compiled map reads and builder appends call their host code straight, and any other receiver goes to the host function" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const get = try h.native("kotlin.collections.HashMap.get", notReached);
    const append = try h.native("kotlin.text.StringBuilder.append", notReached);
    const length = try h.native("kotlin.text.StringBuilder.length", notReached);
    // Maps past the size a map indexes its keys at, and under it.
    var maps: [2]Value = undefined;
    for (&maps, [_]usize{ 40, 3 }) |*mp, n| {
        var pairs: std.ArrayList(runtime.MapPair) = .empty;
        for (0..n) |i| try pairs.append(a, .{ .key = .{ .Int = @intCast(i) }, .value = .{ .Long = @intCast(i * 10) } });
        mp.* = try Value.newMap(a, .{ .entries = try runtime.MapEntries.init(a, .{ .slots = pairs }), .mutable = true });
    }
    // A case left to the host function (`want` null) fails here, as it does not run.
    const Get = struct { recv: Value, key: Value, want: ?Value };
    const gets = [_]Get{
        .{ .recv = maps[0], .key = .{ .Int = 7 }, .want = .{ .Long = 70 } },
        .{ .recv = maps[0], .key = .{ .Int = 39 }, .want = .{ .Long = 390 } },
        .{ .recv = maps[0], .key = .{ .Int = 99 }, .want = .Null },
        .{ .recv = maps[1], .key = .{ .Int = 2 }, .want = .{ .Long = 20 } },
        .{ .recv = maps[1], .key = .{ .Long = 2 }, .want = .Null },
        .{ .recv = .{ .Int = 4 }, .key = .{ .Int = 2 }, .want = null },
    };
    var get_fns: std.ArrayList(ir.FuncId) = .empty;
    for (gets) |_| {
        const f = try h.func("mapGet", 2);
        try h.body(f, &.{.{ .insts = &.{
            hand.param(0, 0),                                                                            hand.param(1, 1),
            .{ .CallNative = .{ .dst = hand.reg(2), .native = get, .args = hand.reg(0), .n_args = 2 } },
        }, .term = hand.ret(2) }});
        try get_fns.append(a, f);
    }
    // sb.append(x).length: an Int, a Long and a String appended in place, a Bool by the host function.
    const text: Value = .{ .String = try runtime.strInit(a, "ab") };
    const Append = struct { x: Value, want: ?i32 };
    const appends = [_]Append{
        .{ .x = .{ .Int = -42 }, .want = 3 },
        .{ .x = .{ .Long = 1234567890123 }, .want = 16 },
        .{ .x = text, .want = 18 },
        .{ .x = .{ .Bool = true }, .want = null },
    };
    // sb.append(s, 0, 1): the host function's, not the whole string appended.
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const range = try h.func("appendRange", 2);
    try h.body(range, &.{.{ .insts = &.{
        hand.param(0, 0),                                                                               hand.param(1, 1), hand.konst(2, zero), hand.konst(3, one),
        .{ .CallNative = .{ .dst = hand.reg(4), .native = append, .args = hand.reg(0), .n_args = 4 } },
    }, .term = hand.ret(4) }});
    var append_fns: std.ArrayList(ir.FuncId) = .empty;
    for (appends) |_| {
        const f = try h.func("appendLength", 2);
        try h.body(f, &.{.{ .insts = &.{
            hand.param(0, 0),                                                                               hand.param(1, 1),
            .{ .CallNative = .{ .dst = hand.reg(2), .native = append, .args = hand.reg(0), .n_args = 2 } }, .{ .CallNative = .{ .dst = hand.reg(3), .native = length, .args = hand.reg(0), .n_args = 1 } },
        }, .term = hand.ret(3) }});
        try append_fns.append(a, f);
    }
    try h.finish();
    // Every `native` op compiles: none is left to its handler.
    const census = baseline.census_on;
    baseline.census_on = true;
    defer baseline.census_on = census;
    const left = baseline.census_compiled[@intFromEnum(bc.Op.native)];
    for (gets, get_fns.items) |cs, f| {
        const got = try compiledOnly(a, &h, f, &.{ cs.recv, cs.key });
        if (cs.want) |w| try testing.expect(std.meta.eql(w, got.?)) else try testing.expect(got == null);
    }
    const sb: Value = .{ .StringBuilder = try runtime.ObjRef(std.ArrayList(u8)).init(a, .empty) };
    for (appends, append_fns.items) |cs, f| {
        const got = try compiledOnly(a, &h, f, &.{ sb, cs.x });
        if (cs.want) |w| try testing.expectEqual(w, got.?.Int) else try testing.expect(got == null);
    }
    try testing.expectEqualStrings("-421234567890123ab", sb.StringBuilder.cell.data.items);
    try testing.expectEqual(left, baseline.census_compiled[@intFromEnum(bc.Op.native)]);
    try testing.expect(try compiledOnly(a, &h, range, &.{ sb, text }) == null);
    try testing.expectEqualStrings("-421234567890123ab", sb.StringBuilder.cell.data.items);
}

/// A function of `n` parameters returning native `nat` called over them.
fn nativeOver(h: *Hand, nat: ir.NativeId, n: u32) !ir.FuncId {
    const f = try h.func("nativeOver", n);
    var insts: std.ArrayList(ir.Inst) = .empty;
    for (0..n) |i| try insts.append(h.a, hand.param(@intCast(i), @intCast(i)));
    try insts.append(h.a, .{ .CallNative = .{ .dst = hand.reg(n), .native = nat, .args = hand.reg(0), .n_args = n } });
    try h.body(f, &.{.{ .insts = insts.items, .term = hand.ret(n) }});
    return f;
}

test "compiled rotations and counts of one bits answer as Kotlin's, and any other receiver goes to the host function" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const rotl = try h.native("kotlin.rotateLeft", notReached);
    const rotr = try h.native("kotlin.rotateRight", notReached);
    const ones = try h.native("kotlin.countOneBits", notReached);
    const Case = struct { f: ir.FuncId, args: [2]Value, n: u32, want: ?Value };
    var cases: std.ArrayList(Case) = .empty;
    const ints = [_]i32{ 0, 1, -1, std.math.minInt(i32), 0x1234_5678 };
    const longs = [_]i64{ 0, 1, -1, std.math.minInt(i64), 0x1234_5678_9abc_def0 };
    const counts = [_]i32{ 0, 1, 31, 32, 33, 63, 64, -1, -33, 100 };
    for ([_]ir.NativeId{ rotl, rotr }, 0..) |nat, which| {
        for (ints) |x| for (counts) |n| {
            const u: u32 = @bitCast(x);
            const sh: u5 = @intCast(@mod(n, 32));
            const r: u32 = if (which == 0) std.math.rotl(u32, u, sh) else std.math.rotr(u32, u, sh);
            try cases.append(a, .{ .f = try nativeOver(&h, nat, 2), .args = .{ .{ .Int = x }, .{ .Int = n } }, .n = 2, .want = .{ .Int = @bitCast(r) } });
        };
        for (longs) |x| for (counts) |n| {
            const u: u64 = @bitCast(x);
            const sh: u6 = @intCast(@mod(n, 64));
            const r: u64 = if (which == 0) std.math.rotl(u64, u, sh) else std.math.rotr(u64, u, sh);
            try cases.append(a, .{ .f = try nativeOver(&h, nat, 2), .args = .{ .{ .Long = x }, .{ .Int = n } }, .n = 2, .want = .{ .Long = @bitCast(r) } });
        };
        try cases.append(a, .{ .f = try nativeOver(&h, nat, 2), .args = .{ .{ .UInt = 5 }, .{ .Int = 1 } }, .n = 2, .want = null });
    }
    for (ints) |x| try cases.append(a, .{ .f = try nativeOver(&h, ones, 1), .args = .{ .{ .Int = x }, .Unit }, .n = 1, .want = .{ .Int = @popCount(@as(u32, @bitCast(x))) } });
    for (longs) |x| try cases.append(a, .{ .f = try nativeOver(&h, ones, 1), .args = .{ .{ .Long = x }, .Unit }, .n = 1, .want = .{ .Int = @popCount(@as(u64, @bitCast(x))) } });
    try cases.append(a, .{ .f = try nativeOver(&h, ones, 1), .args = .{ .{ .Short = 3 }, .Unit }, .n = 1, .want = null });
    try h.finish();
    for (cases.items) |*cs| {
        const got = try compiledOnly(a, &h, cs.f, cs.args[0..cs.n]);
        if (cs.want) |w| try testing.expect(std.meta.eql(w, got.?)) else try testing.expect(got == null);
    }
}

test "a compiled list store answers the element it replaces; a read-only or frozen list, and an index out of range, go to the host function" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const set = try h.native("kotlin.collections.ArrayList.set", notReached);
    const Case = struct { recv: Value, i: i32, want: ?Value };
    var items: std.ArrayList(Value) = .empty;
    try items.appendSlice(a, &.{ .{ .Int = 10 }, .{ .Long = 7 }, .Null });
    const list = try Value.newList(a, .{ .items = try runtime.ValueList.initOwned(a, items), .mutable = true, .backing = null });
    var ro_items: std.ArrayList(Value) = .empty;
    try ro_items.appendSlice(a, &.{.{ .Int = 1 }});
    const read_only = try Value.newList(a, .{ .items = try runtime.ValueList.initOwned(a, ro_items), .mutable = false, .backing = null });
    var fz_items: std.ArrayList(Value) = .empty;
    try fz_items.appendSlice(a, &.{.{ .Int = 1 }});
    const frozen_count = try runtime.ModCountRef.initOwned(a, .{ .n = .init(runtime.FROZEN_MOD_BIT | 3) });
    const frozen = try Value.newList(a, .{ .items = try runtime.ValueList.initOwned(a, fz_items), .mutable = true, .backing = null, .mod_count = runtime.OptRef(runtime.ModCount).from(frozen_count) });
    var ct_items: std.ArrayList(Value) = .empty;
    try ct_items.appendSlice(a, &.{.{ .Int = 1 }});
    const counted = try Value.newList(a, .{ .items = try runtime.ValueList.initOwned(a, ct_items), .mutable = true, .backing = null, .mod_count = runtime.OptRef(runtime.ModCount).from(try runtime.ModCountRef.initOwned(a, .{ .n = .init(3) })) });
    const cases = [_]Case{
        .{ .recv = list, .i = 1, .want = .{ .Long = 7 } },
        .{ .recv = list, .i = 2, .want = .Null },
        .{ .recv = counted, .i = 0, .want = .{ .Int = 1 } },
        .{ .recv = list, .i = 3, .want = null },
        .{ .recv = list, .i = -1, .want = null },
        .{ .recv = read_only, .i = 0, .want = null },
        .{ .recv = frozen, .i = 0, .want = null },
        .{ .recv = .{ .Int = 4 }, .i = 0, .want = null },
    };
    var fns: std.ArrayList(ir.FuncId) = .empty;
    for (cases) |_| try fns.append(a, try nativeOver(&h, set, 3));
    try h.finish();
    for (cases, fns.items, 0..) |cs, f, k| {
        const v: Value = .{ .Int = @intCast(100 + k) };
        const got = try compiledOnly(a, &h, f, &.{ cs.recv, .{ .Int = cs.i }, v });
        if (cs.want) |w| {
            try testing.expect(std.meta.eql(w, got.?));
            try testing.expect(std.meta.eql(v, cs.recv.List.items.cell.data.items[@intCast(cs.i)]));
        } else try testing.expect(got == null);
    }
    for ([_]Value{ list, read_only, frozen, counted }) |l| try testing.expectEqual(@as(i32, 0), l.List.items.cell.lock.state.load(.monotonic));
    try testing.expect(std.meta.eql(Value{ .Int = 1 }, read_only.List.items.cell.data.items[0]));
    try testing.expect(std.meta.eql(Value{ .Int = 1 }, frozen.List.items.cell.data.items[0]));
}

test "a compiled not-null assertion copies anything but null, which goes to its handler" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const vals = [_]Value{ .{ .Int = 5 }, .{ .Long = -9 }, .{ .Bool = false }, .{ .Double = 0.5 }, .Unit };
    var fns: std.ArrayList(ir.FuncId) = .empty;
    for (vals) |_| {
        const f = try h.func("sure", 1);
        try h.body(f, &.{.{ .insts = &.{ hand.param(0, 0), .{ .NotNullAssert = .{ .dst = hand.reg(1), .src = hand.reg(0) } } }, .term = hand.ret(1) }});
        try fns.append(a, f);
    }
    const nul = try h.func("sureNull", 1);
    try h.body(nul, &.{.{ .insts = &.{ hand.param(0, 0), .{ .NotNullAssert = .{ .dst = hand.reg(1), .src = hand.reg(0) } } }, .term = hand.ret(1) }});
    try h.finish();
    for (vals, fns.items) |v, f| {
        const i, const c = try bothWays(a, &h, f, &.{v});
        try testing.expect(std.meta.eql(v, i));
        try testing.expect(std.meta.eql(v, c));
    }
    try testing.expect((try compiledOnly(a, &h, nul, &.{.Null})) == null);
}

test "a compare with a constant whose compiled prefix does not take its operand runs the compare behind it, in place" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const k5 = try h.constant(.{ .Long = 5 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const Fn = struct { f: ir.FuncId, x: Value };
    var fns: std.ArrayList(Fn) = .empty;
    // if (x == 5L) 1 else 2, then + 10 either way, for operands of every kind the prefix leaves.
    const c10 = try h.constant(.{ .Int = 10 });
    for ([_]Value{ .{ .Long = 5 }, .{ .Long = 6 }, .{ .Int = 5 }, .{ .Double = 5.0 }, .Null, .{ .Bool = true } }) |x| {
        for ([_]ir.BinOp{ .Eq, .NotEq }) |op| {
            const f = try h.func("eqK", 1);
            try h.body(f, &.{
                .{ .insts = &.{ hand.param(0, 0), hand.konst(1, k5), hand.bin(2, op, 0, 1) }, .term = branch(2, 1, 2) },
                .{ .insts = &.{hand.konst(3, c1)}, .term = hand.jump(3) },
                .{ .insts = &.{hand.konst(3, c2)}, .term = hand.jump(3) },
                .{ .insts = &.{ hand.konst(4, c10), hand.bin(5, .Add, 3, 4) }, .term = hand.ret(5) },
            });
            try fns.append(a, .{ .f = f, .x = x });
        }
    }
    try h.finish();
    for (fns.items) |x| {
        const i, const c = try bothWays(a, &h, x.f, &.{x.x});
        try testing.expect(std.meta.eql(i, c));
    }
}

test "a compiled new copies its class's template into the region hole, as the interpreter's new makes it" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    const gc = runtime.gc;
    const prev_enabled = gc.gc_enabled;
    const prev_region = gc.region_on;
    gc.gc_enabled = true;
    gc.region_on = true;
    defer {
        gc.gc_enabled = prev_enabled;
        gc.region_on = prev_region;
    }
    const prev_perm = gc.allocPerm();
    gc.setAllocPerm(false);
    defer gc.setAllocPerm(prev_perm);
    gc.enterMutator();
    defer gc.exitMutator();
    var h = try Hand.init(a);
    const k = try h.class("Pair", .{ .slot_names = &.{ "a", "b", "c" }, .seeds = &.{ .int, .int, .null_ref } });
    const ctor = try h.func("<init>", 3);
    try h.body(ctor, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.param(2, 2), hand.setField(0, 0, 1), hand.setField(0, 1, 2) }, .term = hand.ret(0) }});
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c7 = try h.constant(.{ .Int = 7 });
    // i = 0; s = 0; last = null; while (i < n) { p = Pair(i, 7); s = s + p.a + p.b; last = p; i++ }; return last
    const f = try h.func("pairs", 1);
    const cnull = try h.constant(.Null);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(2, c0), hand.konst(9, cnull) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = .{ .Branch = .{ .cond = hand.reg(3), .t = .from(2), .f = .from(3) } } },
        .{ .insts = &.{
            .{ .Move = .{ .dst = hand.reg(10), .src = hand.reg(1) } }, hand.konst(11, c7),
            hand.newInstance(5, k, ctor, 10, 2),                       hand.getField(6, 5, 0),
            hand.getField(7, 5, 1),                                    hand.bin(2, .Add, 2, 6),
            hand.bin(2, .Add, 2, 7),                                   .{ .Move = .{ .dst = hand.reg(9), .src = hand.reg(5) } },
            hand.konst(8, c1),                                         hand.bin(1, .Add, 1, 8),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(9) },
    });
    try h.finish();
    const heap = runtime.slab.allocator;
    const i, const c = try bothWays(heap, &h, f, &.{.{ .Int = 50 }});
    for ([_]Value{ i, c }) |v| {
        try testing.expect(v == .Instance);
        const inst = v.Instance;
        try testing.expect(gc.isRegion(&inst.cell.hdr));
        try testing.expectEqual(@as(usize, 3), inst.cell.data.slots.len);
        try testing.expectEqual(@as(i32, 49), inst.cell.data.slots[0].Int);
        try testing.expectEqual(@as(i32, 7), inst.cell.data.slots[1].Int);
        try testing.expect(inst.cell.data.slots[2] == .Null);
        try testing.expectEqual(k.int(), inst.cell.data.class_id);
    }
    // Neither way takes an identity until one is asked for; each then takes its own.
    try testing.expectEqual(@as(u32, 0), i.Instance.cell.hdr.gc_aux);
    try testing.expectEqual(@as(u32, 0), c.Instance.cell.hdr.gc_aux);
    const id = i.Instance.cell.data.identityOf();
    try testing.expect(id != 0 and c.Instance.cell.data.identityOf() != id);
    try testing.expectEqual(id, i.Instance.cell.data.identityOf());
}

test "a compiled new of a primitive array bumps it out of the region hole zeroed, as the interpreter's new makes it" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    const gc = runtime.gc;
    const prev_enabled = gc.gc_enabled;
    const prev_region = gc.region_on;
    gc.gc_enabled = true;
    gc.region_on = true;
    defer {
        gc.gc_enabled = prev_enabled;
        gc.region_on = prev_region;
    }
    const prev_perm = gc.allocPerm();
    gc.setAllocPerm(false);
    defer gc.setAllocPerm(prev_perm);
    gc.enterMutator();
    defer gc.exitMutator();
    var h = try Hand.init(a);
    const PK = runtime.PrimitiveArrayKind;
    const kinds = [_]PK{ .Int, .Long, .Byte };
    var fns: [kinds.len]ir.FuncId = undefined;
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c7 = try h.constant(.{ .Int = 7 });
    const c9 = try h.constant(.{ .Int = 9 });
    for (kinds, &fns) |k, *f| {
        const cls = try h.class(@tagName(k), .{});
        h.r.host_class.prim_array[@intFromEnum(k)] = cls;
        // A constructor with no body: the host's, which `new` of a primitive array stands in for.
        const ctor = try h.func("<init>", 1);
        // i = 0; while (i < n) { arr = Kind(9); arr[i & 7] = i; i++ }; return arr
        f.* = try h.func("arrays", 1);
        try h.body(f.*, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(9, c9), hand.newInstance(3, cls, ctor, 9, 1) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(2, .Less, 1, 0)}, .term = branch(2, 2, 3) },
            .{ .insts = &.{
                hand.newInstance(3, cls, ctor, 9, 1),                                                   hand.konst(4, c7), hand.bin(5, .And, 1, 4),
                .{ .ArraySet = .{ .array = hand.reg(3), .index = hand.reg(5), .value = hand.reg(1) } }, hand.konst(6, c1), hand.bin(1, .Add, 1, 6),
            }, .term = hand.jump(1) },
            .{ .insts = &.{}, .term = hand.ret(3) },
        });
    }
    try h.finish();
    for (kinds, fns) |k, f| {
        const i, const c = try bothWays(runtime.slab.allocator, &h, f, &.{.{ .Int = 43 }});
        for ([_]Value{ i, c }) |v| {
            try testing.expect(v == .Array);
            try testing.expectEqual(@as(?PK, k), v.Array.primKind());
            try testing.expectEqual(@as(usize, 9), v.Array.len());
            const pb = v.Array.storage().scalars;
            try testing.expect(gc.isRegion(&pb.cell.hdr));
            for (0..9) |j| {
                const want: i64 = if (j == 42 & 7) 42 else 0;
                try testing.expectEqual(want, pb.asPtrConst().get(j).asI64().?);
            }
        }
    }
}

test "compiled field accesses leave out the checks a new or an earlier access proved, and answer the same" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const k = try h.class("Pair", .{ .slot_names = &.{ "a", "b" }, .seeds = &.{ .int, .int } });
    const ctor = try h.func("<init>", 3);
    try h.body(ctor, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.param(2, 2), hand.setField(0, 0, 1), hand.setField(0, 1, 2) }, .term = hand.ret(0) }});
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const ten = try h.constant(.{ .Int = 10 });
    // p = Pair(0, 10); i = 0; while (i < n) { p.a = p.a + p.b + i; i = i + 1 }; return p.a
    const f = try h.func("accumulate", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, ten), hand.newInstance(3, k, ctor, 1, 2), hand.konst(4, zero) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(5, .Less, 4, 0)}, .term = branch(5, 2, 3) },
        .{ .insts = &.{
            hand.getField(6, 3, 0),
            hand.getField(7, 3, 1),
            hand.bin(6, .Add, 6, 7),
            hand.bin(6, .Add, 6, 4),
            hand.setField(3, 0, 6),
            hand.konst(8, one),
            hand.bin(4, .Add, 4, 8),
        }, .term = hand.jump(1) },
        .{ .insts = &.{hand.getField(9, 3, 0)}, .term = hand.ret(9) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const before = baseline.fact_count.load(.monotonic);
    const i, const c = try bothWays(a, &h, f, &.{.{ .Int = 40 }});
    try testing.expectEqual(@as(i32, 40 * 10 + 39 * 40 / 2), c.Int);
    try testing.expect(std.meta.eql(i, c));
    try testing.expect(baseline.fact_count.load(.monotonic) > before);
}

test "a field read after one whose handler took a value no instance checks it at its entry" {
    if (comptime !jit.supported) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    // p.0 + p.0: the first read's handler answers an unsigned value's bits, and the second,
    // which the kinds show reading an instance, is entered from that handler.
    const f = try h.func("twiceData", 1);
    try h.body(f, &.{.{ .insts = &.{ hand.param(0, 0), hand.getField(1, 0, 0), hand.getField(2, 0, 0), hand.bin(3, .Add, 1, 2) }, .term = hand.ret(3) }});
    try h.finish();
    const i, const c = try bothWays(a, &h, f, &.{.{ .UInt = 21 }});
    try testing.expectEqual(@as(i32, 42), c.Int);
    try testing.expect(std.meta.eql(i, c));
}

/// Whether this machine runs the optimizing tier: AArch64 or x86-64 with plain slots.
fn optTierHere() bool {
    const arch = @import("builtin").cpu.arch;
    if (comptime !jit.supported or (arch != .aarch64 and arch != .x86_64) or !runtime.plain_slots) return false;
    return runtime.plainSlotsOn();
}

/// `bothWays` with the optimizing tier compiling the function's loops.
fn bothWaysOpt(a: std.mem.Allocator, h: *Hand, f: ir.FuncId, args: []const Value) !struct { Value, Value } {
    const was = baseline.opt_enabled;
    baseline.opt_enabled = true;
    defer baseline.opt_enabled = was;
    return bothWays(a, h, f, args);
}

test "an optimized loop sums as the interpreter does, and gives the frame its registers where it leaves" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const zero_l = try h.constant(.{ .Long = 0 });
    const three = try h.constant(.{ .Int = 3 });
    // var i = 0; var acc = 0L; while (i < n) { acc = acc + (i * 3).toLong(); i = i + 1 }; return acc + i
    const f = try h.func("sumOpt", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, zero_l) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
        .{ .insts = &.{
            hand.konst(6, three),
            hand.bin(7, .Mul, 1, 6),
            .{ .UnOp = .{ .dst = hand.reg(4), .op = .ToLong, .operand = hand.reg(7) } },
            hand.bin(2, .Add, 2, 4),
            hand.konst(5, one),
            hand.bin(1, .Add, 1, 5),
        }, .term = hand.jump(1) },
        .{ .insts = &.{
            .{ .UnOp = .{ .dst = hand.reg(8), .op = .ToLong, .operand = hand.reg(1) } },
            hand.bin(9, .Add, 2, 8),
        }, .term = hand.ret(9) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const before = baseline.opt_count.load(.monotonic);
    const i, const c = try bothWaysOpt(a, &h, f, &.{.{ .Int = 1000 }});
    try testing.expectEqual(@as(i64, 3 * 999 * 1000 / 2 + 1000), c.Long);
    try testing.expect(std.meta.eql(i, c));
    try testing.expect(baseline.opt_count.load(.monotonic) > before);
}

test "an optimized loop with fewer registers than values keeps some in stack slots, a swap between two of them too, and answers the same" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const two = try h.constant(.{ .Int = 2 });
    const three = try h.constant(.{ .Int = 3 });
    const ten = try h.constant(.{ .Int = 10 });
    const zero_l = try h.constant(.{ .Long = 0 });
    const zero_d = try h.constant(.{ .Double = 0.0 });
    const half = try h.constant(.{ .Double = 0.5 });
    // var i = 0; var x = 1; var y = 2; var acc = 0L; var d = 0.0
    // while (i < n) { val t = x; x = y; y = t; acc += (x * 3 + y).toLong(); d += 0.5; i += 1 }
    // return acc + (x * 10 + y).toLong() + d.toLong()
    var fs: [2]ir.FuncId = undefined;
    for (&fs) |*f| {
        f.* = try h.func("spillOpt", 1);
        try h.body(f.*, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, one), hand.konst(3, two), hand.konst(4, zero_l), hand.konst(5, zero_d) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(6, .Less, 1, 0)}, .term = branch(6, 2, 3) },
            .{ .insts = &.{
                .{ .Move = .{ .dst = hand.reg(7), .src = hand.reg(2) } },
                .{ .Move = .{ .dst = hand.reg(2), .src = hand.reg(3) } },
                .{ .Move = .{ .dst = hand.reg(3), .src = hand.reg(7) } },
                hand.konst(8, three),
                hand.bin(9, .Mul, 2, 8),
                hand.bin(9, .Add, 9, 3),
                .{ .UnOp = .{ .dst = hand.reg(10), .op = .ToLong, .operand = hand.reg(9) } },
                hand.bin(4, .Add, 4, 10),
                hand.konst(11, half),
                hand.bin(5, .Add, 5, 11),
                hand.konst(12, one),
                hand.bin(1, .Add, 1, 12),
            }, .term = hand.jump(1) },
            .{ .insts = &.{
                hand.konst(13, ten),
                hand.bin(14, .Mul, 2, 13),
                hand.bin(14, .Add, 14, 3),
                .{ .UnOp = .{ .dst = hand.reg(15), .op = .ToLong, .operand = hand.reg(14) } },
                hand.bin(16, .Add, 4, 15),
                .{ .UnOp = .{ .dst = hand.reg(17), .op = .ToLong, .operand = hand.reg(5) } },
                hand.bin(16, .Add, 16, 17),
            }, .term = hand.ret(16) },
        });
        h.m.funcByIdMut(f.*).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    }
    try h.finish();
    const want: i64 = 500 * 7 + 500 * 5 + 12 + 500;
    // Two registers of each set: the loop keeps values in its stack.
    const cap = baseline.opt_regs_cap;
    baseline.opt_regs_cap = 2;
    defer baseline.opt_regs_cap = cap;
    const spills = baseline.opt_spill_count.load(.monotonic);
    const before = baseline.opt_count.load(.monotonic);
    const i, const c = try bothWaysOpt(a, &h, fs[0], &.{.{ .Int = 1000 }});
    try testing.expectEqual(want, c.Long);
    try testing.expect(std.meta.eql(i, c));
    try testing.expect(baseline.opt_count.load(.monotonic) > before);
    try testing.expect(baseline.opt_spill_count.load(.monotonic) > spills);
    // An odd count leaves the pair swapped.
    const io, const co = try bothWaysOpt(a, &h, fs[1], &.{.{ .Int = 7 }});
    try testing.expectEqual(@as(i64, 4 * 7 + 3 * 5 + 21 + 3), co.Long);
    try testing.expect(std.meta.eql(io, co));
}

test "an optimized loop whose entry finds another kind than its code relies on runs in the baseline, and answers the same" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    // A field read in the loop: the instance's slot holds an Int on one run and a Long on
    // the other, so the loop's check of the Int leaves to the baseline, which goes on.
    const k = try h.class("Box", .{ .slot_names = &.{"v"}, .seeds = &.{.int} });
    h.classes.items[k.int()].def.asPtr().ordered_slots = false;
    const ctor = try h.func("<init>", 2);
    try h.body(ctor, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.setField(0, 0, 1) }, .term = hand.ret(0) }});
    // box = Box(v); i = 0; acc = 0; while (i < n) { acc = acc + box.v; i = i + 1 }; return acc
    var fs: [2]ir.FuncId = undefined;
    for (&fs) |*f| {
        f.* = try h.func("fieldSum", 2);
        try h.body(f.*, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.newInstance(2, k, ctor, 1, 1), hand.konst(3, zero), hand.konst(4, zero) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(5, .Less, 3, 0)}, .term = branch(5, 2, 3) },
            .{ .insts = &.{
                hand.getField(6, 2, 0),
                hand.bin(4, .Add, 4, 6),
                hand.konst(7, one),
                hand.bin(3, .Add, 3, 7),
            }, .term = hand.jump(1) },
            .{ .insts = &.{}, .term = hand.ret(4) },
        });
        h.m.funcByIdMut(f.*).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    }
    try h.finish();
    const before = baseline.opt_count.load(.monotonic);
    const ia, const ca = try bothWaysOpt(a, &h, fs[0], &.{ .{ .Int = 100 }, .{ .Int = 5 } });
    try testing.expectEqual(@as(i32, 500), ca.Int);
    try testing.expect(std.meta.eql(ia, ca));
    const ib, const cb = try bothWaysOpt(a, &h, fs[1], &.{ .{ .Int = 100 }, .{ .Long = 5 } });
    try testing.expect(std.meta.eql(ib, cb));
    try testing.expect(baseline.opt_count.load(.monotonic) >= before + 2);
}

test "an optimized Double loop compares NaN as Kotlin does" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const half = try h.constant(.{ .Double = 0.5 });
    const zero_d = try h.constant(.{ .Double = 0.0 });
    // d = x; i = 0; hits = 0; while (i < n) { if (0.0 < d) hits = hits + 1;
    // if (d <= e) hits = hits + 1; if (d < e) hits = hits + 1; d = d + 0.5; i = i + 1 }; return hits
    var fs: [2]ir.FuncId = undefined;
    const big = try h.constant(.{ .Double = 1e18 });
    for (&fs) |*f| {
        f.* = try h.func("nanLoop", 2);
        try h.body(f.*, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.konst(2, zero), hand.konst(3, zero), hand.konst(8, zero_d), hand.konst(10, big) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(4, .Less, 2, 0)}, .term = branch(4, 2, 9) },
            .{ .insts = &.{hand.bin(5, .Less, 8, 1)}, .term = branch(5, 3, 4) },
            .{ .insts = &.{ hand.konst(6, one), hand.bin(3, .Add, 3, 6) }, .term = hand.jump(4) },
            .{ .insts = &.{hand.bin(11, .LessEq, 1, 10)}, .term = branch(11, 5, 6) },
            .{ .insts = &.{ hand.konst(12, one), hand.bin(3, .Add, 3, 12) }, .term = hand.jump(6) },
            .{ .insts = &.{hand.bin(13, .Less, 1, 10)}, .term = branch(13, 7, 8) },
            .{ .insts = &.{ hand.konst(14, one), hand.bin(3, .Add, 3, 14) }, .term = hand.jump(8) },
            .{ .insts = &.{ hand.konst(7, half), hand.bin(1, .Add, 1, 7), hand.konst(9, one), hand.bin(2, .Add, 2, 9) }, .term = hand.jump(1) },
            .{ .insts = &.{}, .term = hand.ret(3) },
        });
        h.m.funcByIdMut(f.*).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
        h.m.funcByIdMut(f.*).?.params[1].ty = .{ .name = "kotlin.Double", .nullable = false, .args = &.{} };
    }
    try h.finish();
    // 0.0 < d for d from 0.5 on; NaN is less than nothing.
    const before = baseline.opt_count.load(.monotonic);
    const ia, const ca = try bothWaysOpt(a, &h, fs[0], &.{ .{ .Int = 50 }, .{ .Double = 0.0 } });
    try testing.expect(std.meta.eql(ia, ca));
    try testing.expectEqual(@as(i32, 49 + 50 + 50), ca.Int);
    const ib, const cb = try bothWaysOpt(a, &h, fs[1], &.{ .{ .Int = 50 }, .{ .Double = std.math.nan(f64) } });
    try testing.expect(std.meta.eql(ib, cb));
    try testing.expectEqual(@as(i32, 0), cb.Int);
    try testing.expect(baseline.opt_count.load(.monotonic) >= before + 2);
}

test "an optimized loop leaving at its back edge's guard gives the frame a register written just before the edge" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const zero_l = try h.constant(.{ .Long = 0 });
    // As a tail call made a loop: acc = 0L; while (n != 0) { m = n - 1; acc = acc + n.toLong(); n = m }; return acc
    // The copy into n comes last, just before the back edge: the guard, which runs out
    // of the loop every 65536 turns, must find n written.
    const f = try h.func("countDown", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero_l), hand.konst(2, zero) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .NotEq, 0, 2)}, .term = branch(3, 2, 3) },
        .{ .insts = &.{
            hand.konst(5, one),
            hand.bin(6, .Sub, 0, 5),
            .{ .UnOp = .{ .dst = hand.reg(8), .op = .ToLong, .operand = hand.reg(0) } },
            hand.bin(1, .Add, 1, 8),
            .{ .Move = .{ .dst = hand.reg(0), .src = hand.reg(6) } },
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(1) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const n: i64 = 300_000;
    const c = (try compiledOptWith(a, &h, f, &.{.{ .Int = @intCast(n) }})).?;
    try testing.expectEqual(@as(i64, n * (n + 1) / 2), c.Long);
}

/// `compiledOnly` with the optimizing tier compiling the function's loops.
fn compiledOptWith(a: std.mem.Allocator, h: *Hand, f: ir.FuncId, args: []const Value) !?Value {
    const was = baseline.opt_enabled;
    baseline.opt_enabled = true;
    defer baseline.opt_enabled = was;
    const before = baseline.opt_count.load(.monotonic);
    const r = try compiledOnly(a, h, f, args);
    try testing.expect(baseline.opt_count.load(.monotonic) > before);
    return r;
}

test "an optimized loop runs its static callees in place, callees within callees too" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const c5 = try h.constant(.{ .Int = 5 });
    // f(x) = if (x > 5) x * 2 else x + 1; g(x) = f(x) + f(x + 1)
    const f = try h.func("f", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c5), hand.bin(2, .Greater, 0, 1) }, .term = branch(2, 1, 2) },
        .{ .insts = &.{ hand.konst(3, c2), hand.bin(4, .Mul, 0, 3) }, .term = hand.jump(3) },
        .{ .insts = &.{ hand.konst(3, c1), hand.bin(4, .Add, 0, 3) }, .term = hand.jump(3) },
        .{ .insts = &.{}, .term = hand.ret(4) },
    });
    const g = try h.func("g", 1);
    try h.body(g, &.{.{ .insts = &.{
        hand.param(0, 0), hand.callStatic(1, f, 0, 1), hand.konst(2, c1), hand.bin(3, .Add, 0, 2), hand.callStatic(4, f, 3, 1), hand.bin(5, .Add, 1, 4),
    }, .term = hand.ret(5) }});
    // i = 0; s = 0; while (i < n) { s = s + g(i); i++ }; return s
    const main = try h.func("main", 1);
    try h.body(main, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(2, c0) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
        .{ .insts = &.{ hand.callStatic(4, g, 1, 1), hand.bin(2, .Add, 2, 4), hand.konst(5, c1), hand.bin(1, .Add, 1, 5) }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    h.m.funcByIdMut(main).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const before = baseline.opt_count.load(.monotonic);
    const i, const c = try bothWaysOpt(a, &h, main, &.{.{ .Int = 30 }});
    try testing.expect(std.meta.eql(i, c));
    var want: i32 = 0;
    for (0..30) |k| {
        const x: i32 = @intCast(k);
        const fx = if (x > 5) x * 2 else x + 1;
        const fy = if (x + 1 > 5) (x + 1) * 2 else x + 2;
        want += fx + fy;
    }
    try testing.expectEqual(want, c.Int);
    try testing.expect(baseline.opt_count.load(.monotonic) > before);
}

test "an optimized loop runs a virtual call's two classes in place, and a third leaves to the call" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const c3 = try h.constant(.{ .Int = 3 });
    const c5 = try h.constant(.{ .Int = 5 });
    const c7 = try h.constant(.{ .Int = 7 });
    const c9 = try h.constant(.{ .Int = 9 });
    const c100 = try h.constant(.{ .Int = 100 });
    const ctor = try hand.ctorStoringMessage(&h);
    const ka = try h.class("A", .{ .seeds = &.{.int}, .slot_names = &.{"v"} });
    const kb = try h.class("B", .{ .seeds = &.{.int}, .slot_names = &.{"v"}, .supers = &.{ka} });
    const kc = try h.class("C", .{ .seeds = &.{.int}, .slot_names = &.{"v"}, .supers = &.{ka} });
    // No volatile property: plain slots, which the tier reads in place.
    for ([_]ir.ClassId{ ka, kb, kc }) |k| h.classes.items[k.int()].def.asPtr().ordered_slots = false;
    // A.get() = v + 100, B.get() = v * 2, C.get() = v - 1
    const a_get = try h.func("A.get", 1);
    try h.body(a_get, &.{.{ .insts = &.{ hand.param(0, 0), hand.getField(1, 0, 0), hand.konst(2, c100), hand.bin(3, .Add, 1, 2) }, .term = hand.ret(3) }});
    const b_get = try h.func("B.get", 1);
    try h.body(b_get, &.{.{ .insts = &.{ hand.param(0, 0), hand.getField(1, 0, 0), hand.konst(2, c2), hand.bin(3, .Mul, 1, 2) }, .term = hand.ret(3) }});
    const c_get = try h.func("C.get", 1);
    try h.body(c_get, &.{.{ .insts = &.{ hand.param(0, 0), hand.getField(1, 0, 0), hand.konst(2, c1), hand.bin(3, .Sub, 1, 2) }, .term = hand.ret(3) }});
    try h.dispatch(ka, a_get, a_get);
    try h.dispatch(kb, a_get, b_get);
    try h.dispatch(kc, a_get, c_get);
    // Receivers by i & 1: A, B, A, B while i < m, then C for B; s = s + r.get().
    var mains: [2]ir.FuncId = undefined;
    for (&mains) |*main| {
        main.* = try h.func("main", 2);
        try h.body(main.*, &.{
            .{ .insts = &.{
                hand.param(0, 0),                    hand.param(21, 1),                   hand.konst(1, c0),
                hand.konst(2, c0),                   hand.konst(4, c5),                   hand.newInstance(5, ka, ctor, 4, 1),
                hand.konst(6, c7),                   hand.newInstance(7, kb, ctor, 6, 1), hand.konst(8, c9),
                hand.newInstance(9, kc, ctor, 8, 1),
            }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(11, .Less, 1, 0)}, .term = branch(11, 2, 7) },
            .{ .insts = &.{ hand.konst(12, c1), hand.bin(13, .And, 1, 12), hand.konst(16, c0), hand.bin(17, .Eq, 13, 16) }, .term = branch(17, 3, 8) },
            .{ .insts = &.{.{ .Move = .{ .dst = hand.reg(14), .src = hand.reg(5) } }}, .term = hand.jump(6) },
            .{ .insts = &.{.{ .Move = .{ .dst = hand.reg(14), .src = hand.reg(7) } }}, .term = hand.jump(6) },
            .{ .insts = &.{.{ .Move = .{ .dst = hand.reg(14), .src = hand.reg(9) } }}, .term = hand.jump(6) },
            .{ .insts = &.{ hand.callVirtual(15, a_get, 14, 1), hand.bin(2, .Add, 2, 15), hand.konst(20, c1), hand.bin(1, .Add, 1, 20) }, .term = hand.jump(1) },
            .{ .insts = &.{}, .term = hand.ret(2) },
            // odd i: C once i reaches m, else B
            .{ .insts = &.{ hand.konst(18, c3), hand.bin(19, .Less, 1, 21) }, .term = branch(19, 4, 5) },
        });
        h.m.funcByIdMut(main.*).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
        h.m.funcByIdMut(main.*).?.params[1].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    }
    try h.finish();
    const before = baseline.opt_count.load(.monotonic);
    // Only A and B: the loop's two classes, in place, leaving only where the loop ends.
    const sets = baseline.opt_exit_sets.items.len;
    baseline.opt_exits_on = true;
    const ia, const ca = try bothWaysOpt(a, &h, mains[0], &.{ .{ .Int = 400 }, .{ .Int = 1000 } });
    baseline.opt_exits_on = false;
    try testing.expectEqual(@as(i32, 200 * 105 + 200 * 14), ca.Int);
    try testing.expect(std.meta.eql(ia, ca));
    // The loop's own exit is its first (its head is read first); no other ran.
    try testing.expectEqual(sets + 1, baseline.opt_exit_sets.items.len);
    const x = baseline.opt_exit_sets.items[sets];
    try testing.expectEqual(@as(u64, 1), x.counts[0]);
    for (x.counts[1..]) |k| try testing.expectEqual(@as(u64, 0), k);
    // C from the middle on: the class test leaves to the call, which the baseline runs.
    const ib, const cb = try bothWaysOpt(a, &h, mains[1], &.{ .{ .Int = 400 }, .{ .Int = 200 } });
    try testing.expectEqual(@as(i32, 200 * 105 + 100 * 14 + 100 * 8), cb.Int);
    try testing.expect(std.meta.eql(ib, cb));
    try testing.expect(baseline.opt_count.load(.monotonic) >= before + 2);
}

test "an optimized loop reads Int, Long and Double arrays and an Array<T>, as the interpreter does" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    // i = 0; s = 0; while (i < n) { s = s + arr[i].toLong(); i++ }; return s, the elements
    // checked Ints (an Int array's, or an Array<T> holding Ints).
    var fs: [2]ir.FuncId = undefined;
    for (&fs) |*f| {
        f.* = try h.func("sumArray", 2);
        try h.body(f.*, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.konst(2, c0), hand.konst(3, c0) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(4, .Less, 2, 1)}, .term = branch(4, 2, 3) },
            .{ .insts = &.{
                .{ .ArrayGet = .{ .dst = hand.reg(5), .array = hand.reg(0), .index = hand.reg(2) } },
                hand.bin(3, .Add, 3, 5),
                hand.konst(6, c1),
                hand.bin(2, .Add, 2, 6),
            }, .term = hand.jump(1) },
            .{ .insts = &.{}, .term = hand.ret(3) },
        });
        h.m.funcByIdMut(f.*).?.params[1].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    }
    try h.finish();
    const before = baseline.opt_count.load(.monotonic);
    const ints = try runtime.PrimBuf.init(a, .Int, 50);
    for (0..50) |k| ints.cell.data.set(k, .{ .Int = @intCast(k * 3) });
    const ia, const ca = try bothWaysOpt(a, &h, fs[0], &.{ .{ .Array = runtime.ArrayData.scalars(ints, .Int) }, .{ .Int = 50 } });
    try testing.expectEqual(@as(i32, 3 * 49 * 50 / 2), ca.Int);
    try testing.expect(std.meta.eql(ia, ca));
    var items: std.ArrayList(Value) = .empty;
    for (0..50) |k| try items.append(a, .{ .Int = @intCast(k) });
    const boxed = runtime.ArrayData.fromBoxedList(try runtime.ValueList.init(a, items));
    const ib, const cb = try bothWaysOpt(a, &h, fs[1], &.{ boxed, .{ .Int = 50 } });
    try testing.expectEqual(@as(i32, 49 * 50 / 2), cb.Int);
    try testing.expect(std.meta.eql(ib, cb));
    try testing.expect(baseline.opt_count.load(.monotonic) >= before + 2);
}

test "an optimized loop whose callee in place writes the call's result register leaves it in the frame, the callee's constants its own" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const zero_l = try h.constant(.{ .Long = 0 });
    const seven_l = try h.constant(.{ .Long = 7 });
    // addl(a, b) = a + b + 7L; s = 0L; i = 0; while (i < n) { s = addl(s, i.toLong()); i++ }; return s
    const addl = try h.func("addl", 2);
    try h.body(addl, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.bin(2, .Add, 0, 1), hand.konst(3, seven_l), hand.bin(4, .Add, 2, 3) }, .term = hand.ret(4) }});
    const main = try h.func("main", 1);
    try h.body(main, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(2, zero_l) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
        .{ .insts = &.{
            .{ .UnOp = .{ .dst = hand.reg(5), .op = .ToLong, .operand = hand.reg(1) } },
            .{ .Move = .{ .dst = hand.reg(4), .src = hand.reg(2) } },
            hand.callStatic(2, addl, 4, 2),
            hand.konst(6, c1),
            hand.bin(1, .Add, 1, 6),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    h.m.funcByIdMut(main).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const before = baseline.opt_count.load(.monotonic);
    const i, const c = try bothWaysOpt(a, &h, main, &.{.{ .Int = 100 }});
    try testing.expectEqual(@as(i64, 99 * 100 / 2 + 700), c.Long);
    try testing.expect(std.meta.eql(i, c));
    try testing.expect(baseline.opt_count.load(.monotonic) > before);
}

/// The region heap on, as a compiled `new` needs it, for a test's life.
const RegionOn = struct {
    enabled: bool,
    region: bool,
    perm: bool,

    fn begin() RegionOn {
        const gc = runtime.gc;
        const r: RegionOn = .{ .enabled = gc.gc_enabled, .region = gc.region_on, .perm = gc.allocPerm() };
        gc.gc_enabled = true;
        gc.region_on = true;
        gc.setAllocPerm(false);
        gc.enterMutator();
        return r;
    }

    fn end(r: RegionOn) void {
        const gc = runtime.gc;
        gc.exitMutator();
        gc.setAllocPerm(r.perm);
        gc.gc_enabled = r.enabled;
        gc.region_on = r.region;
    }
};

test "an optimized loop makes the instances it keeps as the interpreter's new makes them, and sums the fields of one it does not keep" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    const region = RegionOn.begin();
    defer region.end();
    var h = try Hand.init(a);
    const k = try h.class("Pair", .{ .slot_names = &.{ "a", "b", "c" }, .seeds = &.{ .int, .int, .null_ref } });
    h.classes.items[k.int()].def.asPtr().ordered_slots = false;
    const ctor = try h.func("<init>", 3);
    try h.body(ctor, &.{.{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.param(2, 2), hand.setField(0, 0, 1), hand.setField(0, 1, 2) }, .term = hand.ret(0) }});
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c7 = try h.constant(.{ .Int = 7 });
    const cnull = try h.constant(.Null);
    // i = 0; s = 0; last = null; while (i < n) { p = Pair(i, 7); s = s + p.a + p.b; last = p; i++ };
    // return last (keeps) or s (keeps none)
    var fs: [2]ir.FuncId = undefined;
    for (&fs, 0..) |*f, keeps| {
        f.* = try h.func("pairs", 1);
        const keep: []const ir.Inst = if (keeps == 0) &.{.{ .Move = .{ .dst = hand.reg(9), .src = hand.reg(5) } }} else &.{};
        var body: std.ArrayList(ir.Inst) = .empty;
        try body.appendSlice(a, &.{
            .{ .Move = .{ .dst = hand.reg(10), .src = hand.reg(1) } }, hand.konst(11, c7),
            hand.newInstance(5, k, ctor, 10, 2),                       hand.getField(6, 5, 0),
            hand.getField(7, 5, 1),                                    hand.bin(2, .Add, 2, 6),
            hand.bin(2, .Add, 2, 7),
        });
        try body.appendSlice(a, keep);
        try body.appendSlice(a, &.{ hand.konst(8, c1), hand.bin(1, .Add, 1, 8) });
        try h.body(f.*, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(2, c0), hand.konst(9, cnull) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 3) },
            .{ .insts = body.items, .term = hand.jump(1) },
            .{ .insts = &.{}, .term = hand.ret(if (keeps == 0) 9 else 2) },
        });
        h.m.funcByIdMut(f.*).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    }
    try h.finish();
    const heap = runtime.slab.allocator;
    const before = baseline.opt_count.load(.monotonic);
    const i, const c = try bothWaysOpt(heap, &h, fs[0], &.{.{ .Int = 50 }});
    for ([_]Value{ i, c }) |v| {
        try testing.expect(v == .Instance);
        const inst = v.Instance;
        try testing.expect(runtime.gc.isRegion(&inst.cell.hdr));
        try testing.expectEqual(@as(usize, 3), inst.cell.data.slots.len);
        try testing.expectEqual(@as(i32, 49), inst.cell.data.slots[0].Int);
        try testing.expectEqual(@as(i32, 7), inst.cell.data.slots[1].Int);
        try testing.expect(inst.cell.data.slots[2] == .Null);
        try testing.expectEqual(k.int(), inst.cell.data.class_id);
    }
    const si, const sc = try bothWaysOpt(heap, &h, fs[1], &.{.{ .Int = 50 }});
    try testing.expectEqual(@as(i32, 49 * 50 / 2 + 7 * 50), sc.Int);
    try testing.expect(std.meta.eql(si, sc));
    try testing.expect(baseline.opt_count.load(.monotonic) >= before + 2);
}

test "an optimized loop makes primitive arrays zeroed, of a size it knows or one it computes, and reads their sizes" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    const region = RegionOn.begin();
    defer region.end();
    var h = try Hand.init(a);
    const PK = runtime.PrimitiveArrayKind;
    const kinds = [_]PK{ .Int, .Long, .Byte };
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c7 = try h.constant(.{ .Int = 7 });
    const c9 = try h.constant(.{ .Int = 9 });
    // Per kind: last = K(1); s = 0; i = 0; while (i < n) { arr = K(size); s = s + arr.size;
    // last = arr (or not); i++ }; return last, or s, or s + last.size, where size is 9 or
    // i & 7.
    const Shape = enum { keep_known, keep_computed, sum_computed, sum_kept };
    const shapes = [_]Shape{ .keep_known, .keep_computed, .sum_computed, .sum_kept };
    var fns: [kinds.len][shapes.len]ir.FuncId = undefined;
    for (kinds, &fns) |pk, *row| {
        const cls = try h.class(@tagName(pk), .{});
        h.r.host_class.prim_array[@intFromEnum(pk)] = cls;
        const ctor = try h.func("<init>", 1);
        const size_name = try std.fmt.allocPrint(a, "kotlin.{t}Array.size", .{pk});
        const size_native = try h.native(size_name, notReached);
        const size_fn = try h.func("size", 1);
        h.bindNative(size_fn, size_native);
        for (shapes, row) |shape, *f| {
            f.* = try h.func("arrays", 1);
            const make: []const ir.Inst = switch (shape) {
                .keep_known => &.{hand.newInstance(4, cls, ctor, 9, 1)},
                else => &.{ hand.konst(12, c7), hand.bin(13, .And, 1, 12), hand.newInstance(4, cls, ctor, 13, 1) },
            };
            var body: std.ArrayList(ir.Inst) = .empty;
            try body.appendSlice(a, make);
            try body.appendSlice(a, &.{ hand.callStatic(5, size_fn, 4, 1), hand.bin(2, .Add, 2, 5) });
            if (shape != .sum_computed) try body.append(a, .{ .Move = .{ .dst = hand.reg(3), .src = hand.reg(4) } });
            try body.appendSlice(a, &.{ hand.konst(6, c1), hand.bin(1, .Add, 1, 6) });
            const tail: []const ir.Inst = if (shape == .sum_kept) &.{ hand.callStatic(14, size_fn, 3, 1), hand.bin(15, .Add, 2, 14) } else &.{};
            const ret: u32 = switch (shape) {
                .keep_known, .keep_computed => 3,
                .sum_computed => 2,
                .sum_kept => 15,
            };
            try h.body(f.*, &.{
                .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(2, c0), hand.konst(9, c9), hand.konst(10, c1), hand.newInstance(3, cls, ctor, 10, 1) }, .term = hand.jump(1) },
                .{ .insts = &.{hand.bin(7, .Less, 1, 0)}, .term = branch(7, 2, 3) },
                .{ .insts = body.items, .term = hand.jump(1) },
                .{ .insts = tail, .term = hand.ret(ret) },
            });
            h.m.funcByIdMut(f.*).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
        }
    }
    try h.finish();
    const before = baseline.opt_count.load(.monotonic);
    const n = 43;
    var sum: i32 = 0;
    for (0..n) |j| sum += @intCast(j & 7);
    for (kinds, fns) |pk, row| for (shapes, row) |shape, f| {
        const i, const c = try bothWaysOpt(runtime.slab.allocator, &h, f, &.{.{ .Int = n }});
        switch (shape) {
            .keep_known, .keep_computed => for ([_]Value{ i, c }) |v| {
                try testing.expect(v == .Array);
                try testing.expectEqual(@as(?PK, pk), v.Array.primKind());
                const len: usize = if (shape == .keep_known) 9 else (n - 1) & 7;
                try testing.expectEqual(len, v.Array.len());
                const pb = v.Array.storage().scalars;
                try testing.expect(runtime.gc.isRegion(&pb.cell.hdr));
                for (0..len) |j| try testing.expectEqual(@as(i64, 0), pb.asPtrConst().get(j).asI64().?);
            },
            .sum_computed => try testing.expectEqual(sum, c.Int),
            .sum_kept => try testing.expectEqual(sum + ((n - 1) & 7), c.Int),
        }
        if (shape != .keep_known and shape != .keep_computed) try testing.expect(std.meta.eql(i, c));
    };
    try testing.expect(baseline.opt_count.load(.monotonic) >= before + kinds.len * shapes.len);
}

test "an optimized loop runs a lambda's body in place, its captures read from its closure, and a closure over another lambda leaves to the call" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const c3 = try h.constant(.{ .Int = 3 });
    const c5 = try h.constant(.{ .Int = 5 });
    // lam(x) = x * k + c, over its captures k and c; other(x) = x - d, over d and e: two Ints
    // of its own, which lam's body would read as well as its own.
    const lam = try h.func("lam", 1);
    try h.body(lam, &.{.{ .insts = &.{
        hand.param(0, 0),                                      .{ .LoadCapture = .{ .dst = hand.reg(1), .idx = 0 } },
        .{ .LoadCapture = .{ .dst = hand.reg(2), .idx = 1 } }, hand.bin(3, .Mul, 0, 1),
        hand.bin(4, .Add, 3, 2),
    }, .term = hand.ret(4) }});
    const other = try h.func("other", 1);
    try h.body(other, &.{.{ .insts = &.{ hand.param(0, 0), .{ .LoadCapture = .{ .dst = hand.reg(1), .idx = 0 } }, hand.bin(2, .Sub, 0, 1) }, .term = hand.ret(2) }});
    h.m.funcByIdMut(lam).?.is_lambda = true;
    h.m.funcByIdMut(other).?.is_lambda = true;
    // f = { x -> x * 3 + 5 }; g = { x -> x - 1 } over (1, 2); s = 0; i = 0;
    // while (i < n) { s = s + (if (i < m) f else g)(i); i++ }; return s
    const main = try h.func("main", 2);
    try h.body(main, &.{
        .{ .insts = &.{
            hand.param(0, 0),                                                                                     hand.param(1, 1),
            hand.konst(2, c3),                                                                                    hand.konst(3, c5),
            hand.konst(15, c1),                                                                                   hand.konst(16, c2),
            .{ .MakeClosure = .{ .dst = hand.reg(4), .func = lam, .captures = &.{ hand.reg(2), hand.reg(3) } } }, .{ .MakeClosure = .{ .dst = hand.reg(5), .func = other, .captures = &.{ hand.reg(15), hand.reg(16) } } },
            hand.konst(6, c0),                                                                                    hand.konst(7, c0),
        }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(8, .Less, 6, 0)}, .term = branch(8, 2, 6) },
        .{ .insts = &.{hand.bin(9, .Less, 6, 1)}, .term = branch(9, 3, 4) },
        .{ .insts = &.{.{ .Move = .{ .dst = hand.reg(10), .src = hand.reg(4) } }}, .term = hand.jump(5) },
        .{ .insts = &.{.{ .Move = .{ .dst = hand.reg(10), .src = hand.reg(5) } }}, .term = hand.jump(5) },
        .{ .insts = &.{
            .{ .Move = .{ .dst = hand.reg(11), .src = hand.reg(6) } },
            .{ .RCallValue = .{ .dst = hand.reg(12), .callee = hand.reg(10), .args = hand.reg(11), .n_args = 1 } },
            hand.bin(7, .Add, 7, 12),
            hand.konst(13, c1),
            hand.bin(6, .Add, 6, 13),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(7) },
    });
    h.m.funcByIdMut(main).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    h.m.funcByIdMut(main).?.params[1].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const before = baseline.opt_count.load(.monotonic);
    // f alone: its body in place, the loop leaving only where it ends.
    const sets = baseline.opt_exit_sets.items.len;
    baseline.opt_exits_on = true;
    const ia, const ca = try bothWaysOpt(a, &h, main, &.{ .{ .Int = 100 }, .{ .Int = 1000 } });
    baseline.opt_exits_on = false;
    try testing.expectEqual(@as(i32, 3 * 99 * 100 / 2 + 5 * 100), ca.Int);
    try testing.expect(std.meta.eql(ia, ca));
    try testing.expect(baseline.opt_exit_sets.items.len > sets);
    const x = baseline.opt_exit_sets.items[baseline.opt_exit_sets.items.len - 1];
    var ran: u64 = 0;
    for (x.counts) |k| ran += k;
    try testing.expectEqual(@as(u64, 1), ran);
    // g from the middle on: the closure's test leaves to the call.
    const ib, const cb = try bothWaysOpt(a, &h, main, &.{ .{ .Int = 100 }, .{ .Int = 50 } });
    try testing.expectEqual(@as(i32, 3 * 49 * 50 / 2 + 5 * 50 + (50 + 99) * 50 / 2 - 50), cb.Int);
    try testing.expect(std.meta.eql(ib, cb));
    try testing.expect(baseline.opt_count.load(.monotonic) >= before + 1);
}

test "an optimized loop takes a cast to Int as a check of the value's tag" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const int_class = try h.class("kotlin.Int", .{});
    h.r.host_class.int = int_class;
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    // i = 0; s = 0; while (i < n) { s = s + (arr[i] as Int); i++ }; return s
    const f = try h.func("casts", 2);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.konst(2, c0), hand.konst(3, c0) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(4, .Less, 2, 1)}, .term = branch(4, 2, 3) },
        .{ .insts = &.{
            .{ .ArrayGet = .{ .dst = hand.reg(5), .array = hand.reg(0), .index = hand.reg(2) } },
            hand.cast(6, 5, int_class, false, false),
            hand.bin(3, .Add, 3, 6),
            hand.konst(7, c1),
            hand.bin(2, .Add, 2, 7),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(3) },
    });
    h.m.funcByIdMut(f).?.params[1].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const before = baseline.opt_count.load(.monotonic);
    var items: std.ArrayList(Value) = .empty;
    for (0..40) |k| try items.append(a, .{ .Int = @intCast(k) });
    const ints = runtime.ArrayData.fromBoxedList(try runtime.ValueList.init(a, items));
    const ia, const ca = try bothWaysOpt(a, &h, f, &.{ ints, .{ .Int = 40 } });
    try testing.expectEqual(@as(i32, 39 * 40 / 2), ca.Int);
    try testing.expect(std.meta.eql(ia, ca));
    try testing.expect(baseline.opt_count.load(.monotonic) > before);
}

test "an optimized loop calls a map's lookup and a builder's append straight, the values it holds across the calls kept" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const get = try h.native("kotlin.collections.HashMap.get", notReached);
    const append = try h.native("kotlin.text.StringBuilder.append", notReached);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c7 = try h.constant(.{ .Int = 7 });
    const d0 = try h.constant(.{ .Double = 0 });
    const d15 = try h.constant(.{ .Double = 1.5 });
    // i = 0; s = 0; d = 0.0; a1..a8 = 0
    // while (i < n) { k = i & 7; s = s + map[k]!!; sb.append(k); d = d + 1.5; aj = aj + j; i++ }
    // return (s + a1 + .. + a8).toLong() + d.toLong()
    // More Ints held across both calls than the registers a call keeps, and a Double.
    const f = try h.func("hostLoop", 3);
    var init_insts: std.ArrayList(ir.Inst) = .empty;
    try init_insts.appendSlice(a, &.{ hand.param(0, 0), hand.param(1, 1), hand.param(2, 2), hand.konst(3, c0), hand.konst(4, c0), hand.konst(5, d0) });
    var body: std.ArrayList(ir.Inst) = .empty;
    try body.appendSlice(a, &.{
        hand.konst(6, c7),
        hand.bin(7, .And, 3, 6),
        .{ .Move = .{ .dst = hand.reg(8), .src = hand.reg(0) } },
        .{ .Move = .{ .dst = hand.reg(9), .src = hand.reg(7) } },
        .{ .CallNative = .{ .dst = hand.reg(10), .native = get, .args = hand.reg(8), .n_args = 2 } },
        .{ .NotNullAssert = .{ .dst = hand.reg(11), .src = hand.reg(10) } },
        hand.bin(4, .Add, 4, 11),
        .{ .Move = .{ .dst = hand.reg(12), .src = hand.reg(1) } },
        .{ .Move = .{ .dst = hand.reg(13), .src = hand.reg(7) } },
        .{ .CallNative = .{ .dst = hand.reg(14), .native = append, .args = hand.reg(12), .n_args = 2 } },
        hand.konst(15, d15),
        hand.bin(5, .Add, 5, 15),
    });
    var tail: std.ArrayList(ir.Inst) = .empty;
    try tail.append(a, hand.konst(40, c0));
    for (0..8) |j| {
        const acc: u32 = 20 + @as(u32, @intCast(j));
        const kj = try h.constant(.{ .Int = @intCast(j + 1) });
        try init_insts.append(a, hand.konst(acc, c0));
        try body.appendSlice(a, &.{ hand.konst(30 + @as(u32, @intCast(j)), kj), hand.bin(acc, .Add, acc, 30 + @as(u32, @intCast(j))) });
        try tail.append(a, hand.bin(40, .Add, 40, acc));
    }
    try body.appendSlice(a, &.{ hand.konst(16, c1), hand.bin(3, .Add, 3, 16) });
    try tail.appendSlice(a, &.{
        hand.bin(45, .Add, 4, 40),
        .{ .UnOp = .{ .dst = hand.reg(42), .op = .ToLong, .operand = hand.reg(45) } },
        .{ .UnOp = .{ .dst = hand.reg(43), .op = .ToLong, .operand = hand.reg(5) } },
        hand.bin(44, .Add, 42, 43),
    });
    try h.body(f, &.{
        .{ .insts = init_insts.items, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(17, .Less, 3, 2)}, .term = branch(17, 2, 3) },
        .{ .insts = body.items, .term = hand.jump(1) },
        .{ .insts = tail.items, .term = hand.ret(44) },
    });
    h.m.funcByIdMut(f).?.params[2].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    var pairs: std.ArrayList(runtime.MapPair) = .empty;
    for (0..8) |i| try pairs.append(a, .{ .key = .{ .Int = @intCast(i) }, .value = .{ .Int = @intCast(i * 10) } });
    const map = try Value.newMap(a, .{ .entries = try runtime.MapEntries.init(a, .{ .slots = pairs }), .mutable = true });
    const n = 64;
    var want: i64 = 0;
    for (0..n) |i| want += @intCast((i & 7) * 10);
    want += 36 * n + @as(i64, @intFromFloat(1.5 * n));
    const sets = baseline.opt_exit_sets.items.len;
    baseline.opt_exits_on = true;
    const sb: Value = .{ .StringBuilder = try runtime.ObjRef(std.ArrayList(u8)).init(a, .empty) };
    // The test host runs no host function: the answer is the intrinsics' alone.
    const got = try compiledOptWith(a, &h, f, &.{ map, sb, .{ .Int = n } });
    baseline.opt_exits_on = false;
    try testing.expectEqual(want, got.?.Long);
    var text: std.ArrayList(u8) = .empty;
    for (0..n) |k| try text.print(a, "{d}", .{k & 7});
    try testing.expectEqualStrings(text.items, sb.StringBuilder.cell.data.items);
    // The loop ran in the tier to its end: only its own exit ran.
    const x = baseline.opt_exit_sets.items[baseline.opt_exit_sets.items.len - 1];
    try testing.expect(baseline.opt_exit_sets.items.len > sets);
    var ran: u64 = 0;
    for (x.counts) |k| ran += k;
    try testing.expectEqual(@as(u64, 1), ran);
}

test "an optimized loop reads a list's elements and size in place" {
    if (!optTierHere()) return error.SkipZigTest;
    // Lists read between readings of their write sequence, as a program's are.
    const lockfree = runtime.lockfreeReads();
    runtime.setLockfreeReads(true);
    defer runtime.setLockfreeReads(lockfree);
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const get = try h.native("kotlin.collections.ArrayList.get", notReached);
    const size = try h.native("kotlin.collections.ArrayList.size", notReached);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c7 = try h.constant(.{ .Int = 7 });
    // i = 0; s = 0; while (i < n) { s = s + list[i & 7] + list.size; i++ }; return s
    const f = try h.func("listLoop", 2);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.konst(2, c0), hand.konst(3, c0) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(4, .Less, 2, 1)}, .term = branch(4, 2, 3) },
        .{ .insts = &.{
            hand.konst(5, c7),
            hand.bin(6, .And, 2, 5),
            .{ .Move = .{ .dst = hand.reg(7), .src = hand.reg(0) } },
            .{ .Move = .{ .dst = hand.reg(8), .src = hand.reg(6) } },
            .{ .CallNative = .{ .dst = hand.reg(9), .native = get, .args = hand.reg(7), .n_args = 2 } },
            .{ .Move = .{ .dst = hand.reg(10), .src = hand.reg(0) } },
            .{ .CallNative = .{ .dst = hand.reg(11), .native = size, .args = hand.reg(10), .n_args = 1 } },
            hand.bin(3, .Add, 3, 9),
            hand.bin(3, .Add, 3, 11),
            hand.konst(12, c1),
            hand.bin(2, .Add, 2, 12),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(3) },
    });
    h.m.funcByIdMut(f).?.params[1].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    var items: std.ArrayList(Value) = .empty;
    for (0..8) |k| try items.append(a, .{ .Int = @intCast(k * 3) });
    const list = try Value.newList(a, .{ .items = try runtime.ValueList.initOwned(a, items), .mutable = true, .backing = null });
    const n = 50;
    var want: i32 = 0;
    for (0..n) |k| want += @intCast((k & 7) * 3 + 8);
    const sets = baseline.opt_exit_sets.items.len;
    baseline.opt_exits_on = true;
    const got = try compiledOptWith(a, &h, f, &.{ list, .{ .Int = n } });
    baseline.opt_exits_on = false;
    try testing.expectEqual(want, got.?.Int);
    // The loop ran in the tier to its end: only its own exit ran.
    try testing.expect(baseline.opt_exit_sets.items.len > sets);
    const x = baseline.opt_exit_sets.items[baseline.opt_exit_sets.items.len - 1];
    var ran: u64 = 0;
    for (x.counts) |k| ran += k;
    try testing.expectEqual(@as(u64, 1), ran);
}

test "an optimized loop leaves at an op it does not take and goes on in its code, and one that leaves every turn gives way to the baseline" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const cfalse = try h.constant(.{ .Bool = false });
    const ctext = try h.constant(.{ .String = "text" });
    // i = 0; s = 0; x = false; while (i < n) { if (i & m == 0) { t = "text"; x = !x }; if (x) s = s + 1; s = s + i; i++ }; return s
    // A String constant is an op the tier does not take: with m = 63 it runs every 64th turn, with m = 0 every turn.
    var fs: [2]ir.FuncId = undefined;
    for (&fs) |*f| {
        f.* = try h.func("seldom", 2);
        try h.body(f.*, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.konst(2, c0), hand.konst(3, c0), hand.konst(4, cfalse) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(5, .Less, 2, 0)}, .term = branch(5, 2, 6) },
            .{ .insts = &.{ hand.bin(6, .And, 2, 1), hand.konst(7, c0), hand.bin(8, .Eq, 6, 7) }, .term = branch(8, 3, 4) },
            .{ .insts = &.{ hand.konst(11, ctext), hand.not(4, 4) }, .term = hand.jump(4) },
            .{ .insts = &.{}, .term = branch(4, 5, 7) },
            .{ .insts = &.{ hand.konst(9, c1), hand.bin(3, .Add, 3, 9) }, .term = hand.jump(7) },
            .{ .insts = &.{}, .term = hand.ret(3) },
            .{ .insts = &.{ hand.bin(3, .Add, 3, 2), hand.konst(10, c1), hand.bin(2, .Add, 2, 10) }, .term = hand.jump(1) },
        });
        h.m.funcByIdMut(f.*).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
        h.m.funcByIdMut(f.*).?.params[1].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    }
    try h.finish();
    const Want = struct {
        fn of(n: i32, m: i32) i32 {
            var s: i32 = 0;
            var x = false;
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                if (i & m == 0) x = !x;
                if (x) s += 1;
                s += i;
            }
            return s;
        }
    };
    const n = 4096;
    const before = baseline.opt_count.load(.monotonic);
    baseline.opt_exits_on = true;
    defer baseline.opt_exits_on = false;
    // Seldom: the loop leaves at `!` 64 times and comes back each time.
    const sets = baseline.opt_exit_sets.items.len;
    const ia, const ca = try bothWaysOpt(a, &h, fs[0], &.{ .{ .Int = n }, .{ .Int = 63 } });
    try testing.expectEqual(Want.of(n, 63), ca.Int);
    try testing.expect(std.meta.eql(ia, ca));
    try testing.expect(baseline.opt_count.load(.monotonic) > before);
    try testing.expect(baseline.opt_exit_sets.items.len > sets);
    const x = baseline.opt_exit_sets.items[baseline.opt_exit_sets.items.len - 1];
    var leaves: u64 = 0;
    for (x.counts[0 .. x.counts.len - 1]) |k| leaves += k;
    // Each `!` leaves, and the loop's end: its code ran every other turn.
    try testing.expectEqual(@as(u64, n / 64 + 1), leaves);
    // Every turn: the loop leaves until its budget is spent, then runs in the baseline.
    const ib, const cb = try bothWaysOpt(a, &h, fs[1], &.{ .{ .Int = n }, .{ .Int = 0 } });
    try testing.expectEqual(Want.of(n, 0), cb.Int);
    try testing.expect(std.meta.eql(ib, cb));
    const y = baseline.opt_exit_sets.items[baseline.opt_exit_sets.items.len - 1];
    var bounces: u64 = 0;
    for (y.counts) |k| bounces += k;
    try testing.expectEqual(@as(u64, @import("opt/emit.zig").bounce_budget), bounces);
}

test "an optimized loop storing a reference into an old instance leaves for the write barrier, and stores it" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const k = try h.class("Box", .{ .slot_names = &.{"v"}, .seeds = &.{.null_ref} });
    h.classes.items[k.int()].def.asPtr().ordered_slots = false;
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    // i = 0; while (i < n) { box.v = x; i++ }; return box.v
    const f = try h.func("store", 3);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.param(2, 2), hand.konst(3, c0) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(4, .Less, 3, 2)}, .term = branch(4, 2, 3) },
        .{ .insts = &.{ hand.setField(0, 0, 1), hand.konst(5, c1), hand.bin(3, .Add, 3, 5) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.getField(6, 0, 0)}, .term = hand.ret(6) },
    });
    h.m.funcByIdMut(f).?.params[2].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const def = h.classes.items[k.int()].def;
    const box = try runtime.InstanceData.new(a, def.clone(), &.{.Null}, 1);
    const x = try runtime.InstanceData.new(a, def.clone(), &.{.Null}, 2);
    // Old, and not in the remembered set.
    box.cell.hdr.gc_gen = 1;
    box.cell.hdr.gc_remembered = false;
    const before = baseline.opt_count.load(.monotonic);
    const i, const c = try bothWaysOpt(a, &h, f, &.{ .{ .Instance = box }, .{ .Instance = x }, .{ .Int = 100 } });
    try testing.expect(std.meta.eql(i, c));
    try testing.expect(c == .Instance and c.Instance.cell == x.cell);
    try testing.expect(baseline.opt_count.load(.monotonic) > before);
}

test "an optimized loop leaves at a try frame's push, so a throw in the region is caught" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const ctor = try hand.ctorStoringMessage(&h);
    const throwable = try hand.throwableClass(&h, "Throwable", &.{});
    const bad = try h.constant(.{ .String = "bad" });
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c15 = try h.constant(.{ .Int = 15 });
    const c100 = try h.constant(.{ .Int = 100 });
    const boom = try h.func("boom", 0);
    try h.body(boom, &.{.{ .insts = &.{ hand.konst(0, bad), hand.newInstance(1, throwable, ctor, 0, 1) }, .term = .{ .Throw = hand.reg(1) } }});
    // i = 0; s = 0; while (i < n) { if (i & 15 == 0) try { boom(); s += 100 } catch (e: Throwable) { s += 1 }; s += i; i++ }; return s
    const f = try h.func("tries", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, c0), hand.konst(2, c0) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branch(3, 2, 5) },
        .{ .insts = &.{ hand.konst(10, c15), hand.bin(11, .And, 1, 10), hand.konst(12, c0), hand.bin(13, .Eq, 11, 12) }, .term = branch(13, 3, 6) },
        .{ .insts = &.{hand.callStatic(4, boom, 0, 0)}, .term = hand.jump(7), .catches = &.{hand.catchClass(throwable, 4, 9)} },
        .{ .insts = &.{ hand.konst(6, c1), hand.bin(2, .Add, 2, 6) }, .term = hand.jump(6) },
        .{ .insts = &.{}, .term = hand.ret(2) },
        .{ .insts = &.{ hand.bin(2, .Add, 2, 1), hand.konst(7, c1), hand.bin(1, .Add, 1, 7) }, .term = hand.jump(1) },
        .{ .insts = &.{ hand.konst(5, c100), hand.bin(2, .Add, 2, 5) }, .term = hand.jump(6) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const before = baseline.opt_count.load(.monotonic);
    const i, const c = try bothWaysOpt(a, &h, f, &.{.{ .Int = 50 }});
    try testing.expectEqual(@as(i32, 49 * 50 / 2 + 4), c.Int);
    try testing.expect(std.meta.eql(i, c));
    try testing.expect(baseline.opt_count.load(.monotonic) > before);
}

test "an optimized loop takes a value class's unbox of its underlying value and box of an instance as the value itself" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const ctor = try hand.ctorStoringMessage(&h);
    const rgb = try h.class("Rgb", .{ .slot_names = &.{"packed"}, .seeds = &.{.null_ref} });
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const l0 = try h.constant(.{ .Long = 0 });
    // o = Rgb(k); i = 0; s = 0L; while (i < n) { v = unbox(i.toLong()); s = s + v; b = box(o); i++ }; return b
    // plus s: the unbox takes a Long, the box an instance, each itself.
    const f = try h.func("values", 2);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.newInstance(8, rgb, ctor, 1, 1), hand.konst(2, c0), hand.konst(3, l0), hand.konst(7, c0) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(4, .Less, 2, 0)}, .term = branch(4, 2, 3) },
        .{ .insts = &.{
            .{ .UnOp = .{ .dst = hand.reg(5), .op = .ToLong, .operand = hand.reg(2) } },
            .{ .UnboxValue = .{ .dst = hand.reg(6), .src = hand.reg(5), .class = rgb, .slot = 0 } },
            hand.bin(3, .Add, 3, 6),
            .{ .BoxValue = .{ .dst = hand.reg(7), .src = hand.reg(8), .class = rgb, .slot = 0 } },
            hand.konst(9, c1),
            hand.bin(2, .Add, 2, 9),
        }, .term = hand.jump(1) },
        .{ .insts = &.{hand.getField(10, 7, 0)}, .term = hand.ret(10) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const before = baseline.opt_count.load(.monotonic);
    const sets = baseline.opt_exit_sets.items.len;
    baseline.opt_exits_on = true;
    const i, const c = try bothWaysOpt(a, &h, f, &.{ .{ .Int = 40 }, .{ .Long = 7 } });
    baseline.opt_exits_on = false;
    try testing.expectEqual(@as(i64, 7), c.Long);
    try testing.expect(std.meta.eql(i, c));
    try testing.expect(baseline.opt_count.load(.monotonic) > before);
    // Only the loop's end left its code.
    try testing.expect(baseline.opt_exit_sets.items.len > sets);
    const x = baseline.opt_exit_sets.items[baseline.opt_exit_sets.items.len - 1];
    var ran: u64 = 0;
    for (x.counts) |k| ran += k;
    try testing.expectEqual(@as(u64, 1), ran);
}

test "an optimized loop divides, takes remainders, negates Booleans and compares with null as Kotlin does" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const c3 = try h.constant(.{ .Int = 3 });
    const c7 = try h.constant(.{ .Int = 7 });
    const cm9 = try h.constant(.{ .Int = -9 });
    const cnull = try h.constant(.Null);
    const cfalse = try h.constant(.{ .Bool = false });
    // i = 0; s = 0; x = false; p = null
    // while (i < n) { s += (i - 9) / 7 + (i - 9) % 3 + 1000 / (i & 3 + 1) % 7; x = !x; if (x) s += 1;
    //   p = if (i & 1 == 0) null else o; if (p == null) s += 2; i++ }; return s
    const f = try h.func("ops", 2);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.konst(2, c0), hand.konst(3, c0), hand.konst(4, cfalse), hand.konst(5, cnull) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(6, .Less, 2, 0)}, .term = branch(6, 2, 7) },
        .{ .insts = &.{
            hand.konst(10, cm9),        hand.bin(11, .Add, 2, 10),                        hand.konst(12, c7),         hand.bin(13, .Div, 11, 12), hand.bin(3, .Add, 3, 13),
            hand.konst(14, c3),         hand.bin(15, .Mod, 11, 14),                       hand.bin(3, .Add, 3, 15),   hand.bin(16, .And, 2, 14),  hand.konst(29, c1),
            hand.bin(17, .Add, 16, 29), hand.konst(18, try h.constant(.{ .Int = 1000 })), hand.bin(19, .Div, 18, 17), hand.bin(20, .Mod, 19, 12), hand.bin(3, .Add, 3, 20),
            hand.not(4, 4),
        }, .term = branch(4, 3, 4) },
        .{ .insts = &.{ hand.konst(21, c1), hand.bin(3, .Add, 3, 21) }, .term = hand.jump(4) },
        .{ .insts = &.{ hand.bin(22, .And, 2, 29), hand.konst(23, c0), hand.bin(24, .Eq, 22, 23) }, .term = branch(24, 5, 6) },
        .{ .insts = &.{hand.konst(5, cnull)}, .term = hand.jump(8) },
        .{ .insts = &.{.{ .Move = .{ .dst = hand.reg(5), .src = hand.reg(1) } }}, .term = hand.jump(8) },
        .{ .insts = &.{}, .term = hand.ret(3) },
        .{ .insts = &.{ hand.konst(25, cnull), hand.bin(26, .Eq, 5, 25) }, .term = branch(26, 9, 10) },
        .{ .insts = &.{ hand.konst(27, c2), hand.bin(3, .Add, 3, 27) }, .term = hand.jump(10) },
        .{ .insts = &.{ hand.konst(28, c1), hand.bin(2, .Add, 2, 28) }, .term = hand.jump(1) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    var want: i32 = 0;
    var x = false;
    for (0..60) |k| {
        const i: i32 = @intCast(k);
        want += @divTrunc(i - 9, 7) + @rem(i - 9, 3) + @rem(@divTrunc(1000, (i & 3) + 1), 7);
        x = !x;
        if (x) want += 1;
        if (i & 1 == 0) want += 2;
    }
    const k = try h.class("K", .{});
    const o = try runtime.InstanceData.new(a, h.classes.items[k.int()].def.clone(), &.{}, 1);
    const before = baseline.opt_count.load(.monotonic);
    const sets = baseline.opt_exit_sets.items.len;
    baseline.opt_exits_on = true;
    const i, const c = try bothWaysOpt(a, &h, f, &.{ .{ .Int = 60 }, .{ .Instance = o } });
    baseline.opt_exits_on = false;
    try testing.expectEqual(want, c.Int);
    try testing.expect(std.meta.eql(i, c));
    try testing.expect(baseline.opt_count.load(.monotonic) > before);
    try testing.expect(baseline.opt_exit_sets.items.len > sets);
    const xs = baseline.opt_exit_sets.items[baseline.opt_exit_sets.items.len - 1];
    var ran: u64 = 0;
    for (xs.counts) |n| ran += n;
    try testing.expectEqual(@as(u64, 1), ran);
}

test "an optimized loop's division by zero leaves to the op, which throws" {
    if (!optTierHere()) return error.SkipZigTest;
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c0 = try h.constant(.{ .Int = 0 });
    const c1 = try h.constant(.{ .Int = 1 });
    const c100 = try h.constant(.{ .Int = 100 });
    // i = 0; s = 0; while (i < n) { s += 100 / (i - m); i++ }; return s: m past n divides by no zero.
    var fs: [2]ir.FuncId = undefined;
    for (&fs) |*f| {
        f.* = try h.func("divs", 2);
        try h.body(f.*, &.{
            .{ .insts = &.{ hand.param(0, 0), hand.param(1, 1), hand.konst(2, c0), hand.konst(3, c0), hand.konst(4, c100) }, .term = hand.jump(1) },
            .{ .insts = &.{hand.bin(5, .Less, 2, 0)}, .term = branch(5, 2, 3) },
            .{ .insts = &.{ hand.bin(6, .Sub, 2, 1), hand.bin(7, .Div, 4, 6), hand.bin(3, .Add, 3, 7), hand.konst(8, c1), hand.bin(2, .Add, 2, 8) }, .term = hand.jump(1) },
            .{ .insts = &.{}, .term = hand.ret(3) },
        });
        h.m.funcByIdMut(f.*).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
        h.m.funcByIdMut(f.*).?.params[1].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    }
    try h.finish();
    // No zero: the quotients' sum.
    var want: i32 = 0;
    for (0..20) |i| want += @divTrunc(100, @as(i32, @intCast(i)) - 30);
    try testing.expectEqual(want, (try compiledOptWith(a, &h, fs[0], &.{ .{ .Int = 20 }, .{ .Int = 30 } })).?.Int);
    // A zero at i = 5: the op throws, which the test host cannot, and the run fails.
    try testing.expect(try compiledOptWith(a, &h, fs[1], &.{ .{ .Int = 20 }, .{ .Int = 5 } }) == null);
}
