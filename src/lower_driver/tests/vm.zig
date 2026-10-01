//! Package A's tests: hand-built modules run through the VM, one per
//! instruction lowered from sema, and the tiers that decline them.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const interp_ir = @import("interp_ir");
const stdlib = @import("stdlib");

const hand = ir.eval.hand;
const Hand = hand.Hand;
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const FuncId = ir.FuncId;
const MethodSlotId = ir.MethodSlotId;
const Inst = ir.Inst;
const reg = hand.reg;
const konst = hand.konst;
const param = hand.param;
const bin = hand.bin;
const ret = hand.ret;
const testing = std.testing;

const Run = struct {
    res: interp_ir.VmResult,
    /// What the program printed, each line "\n"-terminated.
    out: []const u8,
};

/// Runs `main` of the hand-built module through `Vm.new` and `vm.run`.
fn runVm(a: Allocator, h: *Hand, main: FuncId) !Run {
    // Each program is its own run: the caches keyed by the addresses of an
    // earlier test's IR must not answer for this one's. They are left filled
    // after it, for a test that reads them.
    interp_ir.resetRunGlobalCaches();
    const module_ref = try runtime.ObjRef(ir.Module).init(a, h.m.*);
    var vm = try interp_ir.Vm.new(a, module_ref);
    defer vm.deinit();
    var cap = runtime.CaptureOutput.init(a);
    const res = try vm.run(main, cap.output());
    var out: std.ArrayList(u8) = .empty;
    for (cap.lines.items) |l| {
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    try out.appendSlice(a, cap.partial.items);
    return .{ .res = res, .out = out.items };
}

fn runProgram(a: Allocator, build: *const fn (*Hand) Allocator.Error!FuncId) !Value {
    var h = try Hand.init(a);
    const main = try build(&h);
    const run = try runVm(a, &h, main);
    if (run.res == .err) std.debug.print("run failed: {any}\n", .{run.res.err});
    try testing.expect(run.res == .ok);
    return run.res.ok;
}

fn expectTrue(v: Value) !void {
    try testing.expect(v == .Bool and v.Bool);
}

fn slot(f: FuncId) MethodSlotId {
    return MethodSlotId.fromFunc(f);
}

test "a static call chain runs through the VM" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try testing.expectEqual(@as(i32, 42), (try runProgram(mem.allocator(), hand.staticChain)).Int);
}

test "virtual dispatch through two overrides and a diamond of interfaces" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try testing.expectEqual(@as(i32, 790123), (try runProgram(mem.allocator(), hand.dispatch)).Int);
}

test "construction seeds every slot before the constructor writes" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectTrue(try runProgram(mem.allocator(), hand.seeds));
}

test "statics initialize on first touch and an init unit reads its own static's seed" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try testing.expectEqual(@as(i32, 1471), (try runProgram(mem.allocator(), hand.statics)).Int);
}

test "a singleton reads itself in its constructor and is built once" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectTrue(try runProgram(mem.allocator(), hand.singleton));
}

test "casts and type tests, nullable ones included" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectTrue(try runProgram(mem.allocator(), hand.typeTests));
}

test "a catch handler matches by class" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try testing.expectEqual(@as(i32, 2), (try runProgram(mem.allocator(), hand.catchByClass)).Int);
}

test "array access past the end throws a catchable IndexOutOfBoundsException" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try testing.expectEqual(@as(i32, 129), (try runProgram(mem.allocator(), hand.arrays)).Int);
}

test "the VM's null and cast failures throw the tables' exception classes" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try testing.expectEqual(@as(i32, 7), (try runProgram(mem.allocator(), hand.vmThrows)).Int);
}

test "!!, integer division by zero and lateinit throw the base's classes" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectTrue(try runProgram(mem.allocator(), hand.reusedThrows));
}

fn writeLine(ctx: *runtime.CallCtx) Allocator.Error!runtime.EvalResult {
    const v = ctx.args[0];
    if (v != .String) return .{ .err = .{ .Type = "writeLine takes a String" } };
    const g = v.String.borrow();
    defer g.deinit();
    ctx.out.writeln(g.get().bytes);
    return .{ .ok = .Unit };
}

/// A native answering a host exception as its value.
fn hostException(ctx: *runtime.CallCtx) Allocator.Error!runtime.EvalResult {
    return .{ .ok = try Value.newException(ctx.allocator, .{
        .fqn = try runtime.strInit(ctx.allocator, "kotlin.RuntimeException"),
        .message = .from(try runtime.strInit(ctx.allocator, "from the host")),
        .cause = null,
    }) };
}

test "a host exception thrown into a catch is bound as an instance of its class" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const ctor = try hand.ctorStoringMessage(&h);
    const throwable = try hand.throwableClass(&h, "Throwable", &.{});
    const rte = try hand.throwableClass(&h, "RuntimeException", &.{throwable});
    try h.r.exceptions.by_fqn.put(a, "kotlin.RuntimeException", .{ .class = rte, .ctor = ctor });
    const make = try h.native("hostException", hostException);
    // `raise` throws the host's value; `main` catches it and reads its
    // message field, which only an instance has.
    const raise = try h.func("raise", 0);
    try h.body(raise, &.{.{
        .insts = &.{.{ .CallNative = .{ .dst = reg(0), .native = make, .args = reg(0), .n_args = 0 } }},
        .term = .{ .Throw = reg(0) },
    }});
    const nothing = try h.constant(.Null);
    const main = try h.func("main", 0);
    try h.body(main, &.{
        .{ .insts = &.{hand.callStatic(0, raise, 0, 0)}, .term = hand.jump(2), .catches = &.{hand.catchClass(rte, 1, 1)} },
        .{ .insts = &.{hand.getField(2, 1, 0)}, .term = ret(2) },
        .{ .insts = &.{konst(3, nothing)}, .term = ret(3) },
    });
    try h.finish();
    const run = try runVm(a, &h, main);
    try testing.expect(run.res == .ok);
    const msg = run.res.ok;
    try testing.expect(msg == .String);
    const g = msg.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("from the host", g.get().bytes);
}

/// The host function of a native the VM's member implementation stands in
/// for; never called.
fn unboundNative(ctx: *runtime.CallCtx) Allocator.Error!runtime.EvalResult {
    _ = ctx;
    return .{ .err = .{ .Unimplemented = "a member's native was called without its member" } };
}

/// A native binding the member the VM implements under `key`.
fn hostMember(h: *Hand, key: []const u8) !ir.NativeId {
    const f = interp_ir.hostMemberFn(key) orelse {
        std.debug.print("the VM implements no {s}\n", .{key});
        return error.TestUnexpectedResult;
    };
    const n = try h.native(key, unboundNative);
    h.natives.items[n.int()].host_fn = f;
    h.natives.items[n.int()].table = .members;
    h.natives.items[n.int()].receiver = true;
    return n;
}

test "a host list's members and its iterator's slots run the members the VM implements" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const list_of = try h.native("mutableListOf", stdlib.implementation("kotlin.collections.mutableListOf").?);
    const add = try h.func("ArrayList.add", 2);
    h.bindNative(add, try hostMember(&h, "kotlin.collections.ArrayList.add"));
    const size = try h.func("ArrayList.<get-size>", 1);
    h.bindNative(size, try hostMember(&h, "get kotlin.collections.ArrayList.size"));
    const iterator = try h.func("ArrayList.iterator", 1);
    h.bindNative(iterator, try hostMember(&h, "kotlin.collections.ArrayList.iterator"));
    // A host iterator's class leaves `hasNext` and `next` to the VM.
    const iter_c = try h.class("Iterator", .{});
    h.r.host_class.by_tag[@intFromEnum(std.meta.Tag(Value).Iterator)] = iter_c;
    const has_next = try h.func("Iterator.hasNext", 1);
    const next = try h.func("Iterator.next", 1);
    const slots = try a.alloc(ir.NativeId, 16);
    @memset(slots, .none);
    slots[has_next.int()] = try hostMember(&h, "kotlin.collections.Iterator.hasNext");
    slots[next.int()] = try hostMember(&h, "kotlin.collections.Iterator.next");
    h.r.host_slot = slots;
    const c1 = try h.constant(.{ .Int = 1 });
    const c2 = try h.constant(.{ .Int = 2 });
    const c4 = try h.constant(.{ .Int = 4 });
    const c10 = try h.constant(.{ .Int = 10 });
    const main = try h.func("main", 0);
    try h.body(main, &.{
        .{ .insts = &.{
            konst(0, c1),
            konst(1, c2),
            .{ .CallNative = .{ .dst = reg(2), .native = list_of, .args = reg(0), .n_args = 2 } },
            .{ .Move = .{ .dst = reg(3), .src = reg(2) } },
            konst(4, c4),
            hand.callStatic(5, add, 3, 2),
            hand.callStatic(6, size, 3, 1),
            hand.callStatic(7, iterator, 3, 1),
            konst(8, c10),
            konst(9, c1),
        }, .term = hand.jump(1) },
        // Sums the elements, each times ten, onto the size.
        .{ .insts = &.{hand.callInterface(10, iter_c, has_next, 7, 1)}, .term = .{ .Branch = .{ .cond = reg(10), .t = ir.BlockId.from(2), .f = ir.BlockId.from(3) } } },
        .{ .insts = &.{
            hand.callInterface(11, iter_c, next, 7, 1),
            bin(12, .Mul, 11, 8),
            bin(6, .Add, 6, 12),
        }, .term = hand.jump(1) },
        .{ .term = ret(6) },
    });
    try h.finish();
    const run = try runVm(a, &h, main);
    if (run.res == .err) std.debug.print("run failed: {any}\n", .{run.res.err});
    try testing.expect(run.res == .ok);
    // Three elements after the add: 3 + (1 + 2 + 4) * 10.
    try testing.expectEqual(@as(i32, 73), run.res.ok.Int);
}

test "a native writes output, called directly and through a bound declaration" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const write = try h.native("writeLine", writeLine);
    const println = try h.func("println", 1);
    h.bindNative(println, write);
    const hello = try h.constant(.{ .String = "hello" });
    const bye = try h.constant(.{ .String = "bye" });
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        konst(0, hello),
        .{ .CallNative = .{ .dst = reg(1), .native = write, .args = reg(0), .n_args = 1 } },
        konst(2, bye),
        hand.callStatic(3, println, 2, 1),
    }, .term = ret(3) }});
    try h.finish();
    const run = try runVm(a, &h, main);
    try testing.expect(run.res == .ok);
    try testing.expectEqualStrings("hello\nbye\n", run.out);
}

/// Answers `half(x)` for an even `x` and declines an odd one.
fn tryHalf(host: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!?ir.eval.EvalResult {
    _ = host;
    _ = a;
    if (args.len != 1 or args[0] != .Int or @mod(args[0].Int, 2) != 0) return null;
    return .{ .ok = .{ .Int = @divExact(args[0].Int, 2) } };
}

test "a fast path in front of a body answers, and one that declines runs the body" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    // The body answers -1, so the result tells which one ran.
    const half = try h.func("half", 1);
    const neg = try h.constant(.{ .Int = -1 });
    try h.body(half, &.{.{ .insts = &.{konst(1, neg)}, .term = ret(1) }});
    const t = try h.native("half", unboundNative);
    h.natives.items[t.int()].host_try = tryHalf;
    h.natives.items[t.int()].table = .tries;
    const c8 = try h.constant(.{ .Int = 8 });
    const c3 = try h.constant(.{ .Int = 3 });
    const c10 = try h.constant(.{ .Int = 10 });
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        konst(0, c8),
        hand.callStatic(1, half, 0, 1),
        konst(2, c3),
        hand.callStatic(3, half, 2, 1),
        konst(4, c10),
        bin(5, .Mul, 1, 4),
        bin(6, .Add, 5, 3),
    }, .term = ret(6) }});
    try h.finish();
    const tries = try a.alloc(ir.NativeId, h.m.funcs.items.len);
    @memset(tries, .none);
    tries[half.int()] = t;
    h.r.func_try = tries;
    const run = try runVm(a, &h, main);
    if (run.res == .err) std.debug.print("run failed: {any}\n", .{run.res.err});
    try testing.expect(run.res == .ok);
    // half(8) answered by the fast path, half(3) by the body: 4 * 10 - 1.
    try testing.expectEqual(@as(i32, 39), run.res.ok.Int);
}

/// A host member answering 5 for any receiver.
fn five(ctx: *runtime.CallCtx) Allocator.Error!runtime.EvalResult {
    _ = ctx;
    return .{ .ok = .{ .Int = 5 } };
}

test "a native call site runs a Kotlin receiver's override of the member, and a super call runs the native" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const ctor = try hand.ctorReturningThis(&h);
    // `Host.get` is the member a native implements, its own slot's root.
    const get = try h.func("Host.get", 1);
    const n = try h.native("Host.get", five);
    h.bindNative(get, n);
    h.natives.items[n.int()].receiver = true;
    h.natives.items[n.int()].slot = get.int();
    // `Sub.get` overrides it as `super.get() + 1`.
    const sub_get = try h.func("Sub.get", 1);
    const c1 = try h.constant(.{ .Int = 1 });
    try h.body(sub_get, &.{.{ .insts = &.{
        .{ .LoadParam = .{ .dst = reg(0), .idx = 0 } },
        .{ .CallNative = .{ .dst = reg(1), .native = n, .args = reg(0), .n_args = 1, .direct = true } },
        konst(2, c1),
        bin(3, .Add, 1, 2),
    }, .term = ret(3) }});
    const host_c = try h.class("Host", .{});
    const sub_c = try h.class("Sub", .{ .supers = &.{host_c} });
    try h.dispatch(host_c, get, get);
    try h.dispatch(sub_c, get, sub_get);
    const c10 = try h.constant(.{ .Int = 10 });
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        hand.newInstance(0, sub_c, ctor, 0, 0),
        hand.newInstance(1, host_c, ctor, 0, 0),
        // Bound to the native statically, the call site runs Sub's override.
        .{ .CallNative = .{ .dst = reg(2), .native = n, .args = reg(0), .n_args = 1 } },
        hand.callStatic(3, get, 0, 1),
        // An instance of the host class itself, and a direct call, run the native.
        .{ .CallNative = .{ .dst = reg(4), .native = n, .args = reg(1), .n_args = 1 } },
        .{ .CallNative = .{ .dst = reg(5), .native = n, .args = reg(0), .n_args = 1, .direct = true } },
        konst(6, c10),
        bin(7, .Mul, 2, 6),
        bin(8, .Add, 7, 3),
        bin(9, .Mul, 8, 6),
        bin(10, .Add, 9, 4),
        bin(11, .Mul, 10, 6),
        bin(12, .Add, 11, 5),
    }, .term = ret(12) }});
    try h.finish();
    const run = try runVm(a, &h, main);
    if (run.res == .err) std.debug.print("run failed: {any}\n", .{run.res.err});
    try testing.expect(run.res == .ok);
    try testing.expectEqual(@as(i32, 6655), run.res.ok.Int);
}

test "a closure and its creator share a captured cell" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c1 = try h.constant(.{ .Int = 1 });
    const c10 = try h.constant(.{ .Int = 10 });
    // { x -> total += x; total }
    const lam = try h.func("main$lambda", 1);
    try h.body(lam, &.{.{ .insts = &.{
        hand.capture(0, 0),
        .{ .CellGet = .{ .dst = reg(1), .cell = reg(0) } },
        param(2, 0),
        bin(3, .Add, 1, 2),
        .{ .CellSet = .{ .cell = reg(0), .value = reg(3) } },
    }, .term = ret(3) }});
    const function1 = try h.class("Function1", .{});
    const function0 = try h.class("Function0", .{});
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        konst(0, c1),
        .{ .MakeCell = .{ .dst = reg(1), .src = reg(0) } },
        .{ .MakeClosure = .{ .dst = reg(2), .func = lam, .captures = try h.regs(&.{reg(1)}) } },
        konst(3, c10),
        .{ .RCallValue = .{ .dst = reg(4), .callee = reg(2), .args = reg(3), .n_args = 1 } },
        .{ .RCallValue = .{ .dst = reg(5), .callee = reg(2), .args = reg(3), .n_args = 1 } },
        .{ .CellGet = .{ .dst = reg(6), .cell = reg(1) } },
        bin(7, .Add, 5, 6),
        hand.instanceOf(8, 2, function1, false),
        hand.instanceOf(9, 2, function0, false),
        hand.not(10, 9),
        bin(11, .And, 8, 10),
    }, .term = .{ .Branch = .{ .cond = reg(11), .t = ir.BlockId.from(1), .f = ir.BlockId.from(2) } } }, .{ .term = ret(7) }, .{ .term = ret(0) } });
    h.r.host_class.function = &.{ function0, function1 };
    try h.finish();
    const run = try runVm(a, &h, main);
    try testing.expect(run.res == .ok);
    try testing.expectEqual(@as(i32, 42), run.res.ok.Int);
}

test "an instance of a class implementing a function type is invoked through its slot" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const ctor = try hand.ctorReturningThis(&h);
    const c5 = try h.constant(.{ .Int = 5 });
    const c100 = try h.constant(.{ .Int = 100 });
    const invoke0 = try h.func("Function0.invoke", 1);
    const invoke1 = try h.func("Function1.invoke", 2);
    const adder_invoke = try h.func("Adder.invoke", 2);
    try h.body(adder_invoke, &.{.{ .insts = &.{ param(0, 1), konst(1, c100), bin(2, .Add, 0, 1) }, .term = ret(2) }});
    const function1 = try h.class("Function1", .{});
    const adder = try h.class("Adder", .{ .supers = &.{function1} });
    try h.dispatch(adder, invoke1, adder_invoke);
    h.r.host_class.invoke_slot = &.{ slot(invoke0), slot(invoke1) };
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        hand.newInstance(0, adder, ctor, 0, 0),
        konst(1, c5),
        .{ .RCallValue = .{ .dst = reg(2), .callee = reg(0), .args = reg(1), .n_args = 1 } },
    }, .term = ret(2) }});
    try h.finish();
    const run = try runVm(a, &h, main);
    try testing.expect(run.res == .ok);
    try testing.expectEqual(@as(i32, 105), run.res.ok.Int);
}

/// A `Box(v)` with `add(x) = v + x`, a `var v` with its accessors, and the
/// `KProperty0`/`KMutableProperty0`/`KCallable` roots the VM answers.
const Refs = struct {
    box: ir.ClassId,
    ctor: FuncId,
    add: FuncId,
    adapter: FuncId,
    get_v: FuncId,
    set_v: FuncId,
    kprop_get: FuncId,
    kprop_set: FuncId,
    name_get: FuncId,
    mutable_property: ir.ClassId,

    fn build(h: *Hand) !Refs {
        var r: Refs = undefined;
        r.box = try h.class("Box", .{ .seeds = &.{.int}, .slot_names = &.{"v"} });
        r.ctor = try h.func("Box.<init>", 2);
        try h.body(r.ctor, &.{.{ .insts = &.{ param(0, 0), param(1, 1), hand.setField(0, 0, 1) }, .term = ret(0) }});
        r.add = try h.func("add", 2);
        try h.body(r.add, &.{.{ .insts = &.{ param(0, 0), hand.getField(1, 0, 0), param(2, 1), bin(3, .Add, 1, 2) }, .term = ret(3) }});
        // The adapter of `box::add`: the bound receiver is capture 0.
        r.adapter = try h.func("add$ref", 1);
        try h.body(r.adapter, &.{.{ .insts = &.{ hand.capture(0, 0), param(1, 0), hand.callStatic(2, r.add, 0, 2) }, .term = ret(2) }});
        r.get_v = try h.func("<get-v>", 1);
        try h.body(r.get_v, &.{.{ .insts = &.{ param(0, 0), hand.getField(1, 0, 0) }, .term = ret(1) }});
        r.set_v = try h.func("<set-v>", 2);
        try h.body(r.set_v, &.{.{ .insts = &.{ param(0, 0), param(1, 1), hand.setField(0, 0, 1) }, .term = .{ .Return = null } }});
        r.kprop_get = try h.func("KProperty0.get", 1);
        r.kprop_set = try h.func("KMutableProperty0.set", 2);
        r.name_get = try h.func("KCallable.<get-name>", 1);
        const kprop = try h.class("KProperty0", .{});
        r.mutable_property = try h.class("KMutableProperty0", .{ .supers = &.{kprop} });
        const function0 = try h.class("Function0", .{});
        const function1 = try h.class("Function1", .{});
        const hc = &h.r.host_class;
        hc.function = try h.a.dupe(ir.ClassId, &.{ function0, function1 });
        hc.property = try h.a.dupe(ir.ClassId, &.{kprop});
        hc.mutable_property = try h.a.dupe(ir.ClassId, &.{r.mutable_property});
        hc.property_get = try h.a.dupe(MethodSlotId, &.{slot(r.kprop_get)});
        hc.property_set = try h.a.dupe(MethodSlotId, &.{slot(r.kprop_set)});
        hc.callable_name = slot(r.name_get);
        return r;
    }
};

test "function and property references call their targets and answer name" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const r = try Refs.build(&h);
    const c5 = try h.constant(.{ .Int = 5 });
    const c7 = try h.constant(.{ .Int = 7 });
    const c10 = try h.constant(.{ .Int = 10 });
    const c15 = try h.constant(.{ .Int = 15 });
    const v_name = try h.constant(.{ .String = "v" });
    const add_name = try h.constant(.{ .String = "add" });
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        konst(0, c5),
        hand.newInstance(1, r.box, r.ctor, 0, 1),
        .{ .FunctionRef = .{ .dst = reg(2), .adapter = r.adapter, .target = r.add, .bound = reg(1) } },
        konst(3, c10),
        .{ .RCallValue = .{ .dst = reg(4), .callee = reg(2), .args = reg(3), .n_args = 1 } },
        .{ .RPropertyRef = .{ .dst = reg(5), .getter = r.get_v, .setter = r.set_v.int(), .bound = reg(1), .name = v_name } },
        hand.callInterface(6, r.mutable_property, r.kprop_get, 5, 1),
        .{ .Move = .{ .dst = reg(8), .src = reg(5) } },
        konst(9, c7),
        hand.callInterface(10, r.mutable_property, r.kprop_set, 8, 2),
        .{ .RCallValue = .{ .dst = reg(11), .callee = reg(5), .args = reg(0), .n_args = 0 } },
        hand.callVirtual(12, r.name_get, 5, 1),
        hand.callVirtual(13, r.name_get, 2, 1),
        hand.instanceOf(14, 5, r.mutable_property, false),
        konst(15, c15),
        bin(16, .Eq, 4, 15),
        bin(17, .Eq, 6, 0),
        bin(18, .Eq, 11, 9),
        konst(19, v_name),
        bin(20, .Eq, 12, 19),
        konst(21, add_name),
        bin(22, .Eq, 13, 21),
        bin(23, .And, 16, 17),
        bin(24, .And, 23, 18),
        bin(25, .And, 24, 20),
        bin(26, .And, 25, 22),
        bin(27, .And, 26, 14),
    }, .term = ret(27) }});
    try h.finish();
    const run = try runVm(a, &h, main);
    if (run.res == .err) std.debug.print("run failed: {any}\n", .{run.res.err});
    try testing.expect(run.res == .ok);
    try expectTrue(run.res.ok);
}

test "two references to one target are equal, a capturing lambda equals only itself, and one capturing nothing is one instance" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const r = try Refs.build(&h);
    const array_c = try h.class("Array", .{});
    h.r.host_class.array = array_c;
    const c5 = try h.constant(.{ .Int = 5 });
    const lam = try h.func("main$lambda", 0);
    try h.body(lam, &.{.{ .insts = &.{konst(0, c5)}, .term = ret(0) }});
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        konst(0, c5),
        hand.newInstance(1, r.box, r.ctor, 0, 1),
        hand.newInstance(2, r.box, r.ctor, 0, 1),
        .{ .FunctionRef = .{ .dst = reg(3), .adapter = r.adapter, .target = r.add, .bound = reg(1) } },
        .{ .FunctionRef = .{ .dst = reg(4), .adapter = r.adapter, .target = r.add, .bound = reg(1) } },
        .{ .FunctionRef = .{ .dst = reg(5), .adapter = r.adapter, .target = r.add, .bound = reg(2) } },
        .{ .MakeClosure = .{ .dst = reg(6), .func = lam, .captures = &.{reg(0)} } },
        .{ .MakeClosure = .{ .dst = reg(7), .func = lam, .captures = &.{reg(0)} } },
        .{ .MakeClosure = .{ .dst = reg(8), .func = lam, .captures = &.{} } },
        .{ .MakeClosure = .{ .dst = reg(9), .func = lam, .captures = &.{} } },
        .{ .NewArray = .{ .dst = reg(10), .class = array_c, .args = reg(3), .n_args = 7 } },
    }, .term = ret(10) }});
    try h.finish();
    const module_ref = try runtime.ObjRef(ir.Module).init(a, h.m.*);
    var vm = try interp_ir.Vm.new(a, module_ref);
    defer vm.deinit();
    var cap = runtime.CaptureOutput.init(a);
    const res = try vm.run(main, cap.output());
    try testing.expect(res == .ok);
    const items = try res.ok.Array.snapshot(a);
    var host = vm.makeHost(cap.output());
    try testing.expect(try host.deepValueEquals(a, &items[0], &items[1]));
    try testing.expect(!try host.deepValueEquals(a, &items[0], &items[2]));
    try testing.expect(!try host.deepValueEquals(a, &items[3], &items[4]));
    try testing.expect(try host.deepValueEquals(a, &items[3], &items[3]));
    try testing.expect(try host.deepValueEquals(a, &items[5], &items[6]));
}

test "a host map entry equals an entry instance by the key and value its getters answer" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    // A program run of its own, as `runMain` makes one: the host's per-thread
    // caches keyed by another run's addresses must not answer here.
    interp_ir.resetRunGlobalCaches();
    defer interp_ir.resetRunGlobalCaches();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const entry = try h.class("Map.Entry", .{});
    // `value` is a getter over a field of another name.
    const stored = try h.class("Stored", .{ .slot_names = &.{ "key", "_value" }, .seeds = &.{ .null_ref, .null_ref }, .supers = &.{entry} });
    const other = try h.class("Other", .{ .slot_names = &.{ "key", "value" }, .seeds = &.{ .null_ref, .null_ref } });
    const root_key = try h.func("Map.Entry.<get-key>", 1);
    const root_value = try h.func("Map.Entry.<get-value>", 1);
    const get_key = try h.func("Stored.<get-key>", 1);
    try h.body(get_key, &.{.{ .insts = &.{ param(0, 0), hand.getField(1, 0, 0) }, .term = ret(1) }});
    const get_value = try h.func("Stored.<get-value>", 1);
    try h.body(get_value, &.{.{ .insts = &.{ param(0, 0), hand.getField(1, 0, 1) }, .term = ret(1) }});
    try h.dispatch(stored, root_key, get_key);
    try h.dispatch(stored, root_value, get_value);
    h.r.host_class.map_entry = entry;
    h.r.host_class.entry_key_slot = slot(root_key);
    h.r.host_class.entry_value_slot = slot(root_value);
    try h.finish();

    const module_ref = try runtime.ObjRef(ir.Module).init(a, h.m.*);
    var vm = try interp_ir.Vm.new(a, module_ref);
    defer vm.deinit();
    try vm.prepareResolved();
    var cap = runtime.CaptureOutput.init(a);
    var host = vm.makeHost(cap.output());
    const r = module_ref.asPtrConst().resolved.?;
    const str = struct {
        fn of(al: Allocator, t: []const u8) !Value {
            return .{ .String = try runtime.strInit(al, t) };
        }
    }.of;
    const make = struct {
        fn of(al: Allocator, tables: *const ir.Resolved, c: ir.ClassId, k: Value, v: Value) !Value {
            const inst = try ir.resolved.instantiate(al, tables, c);
            _ = runtime.InstanceData.slotSet(inst.Instance, 0, k);
            _ = runtime.InstanceData.slotSet(inst.Instance, 1, v);
            return inst;
        }
    }.of;
    const host_entry = try Value.newMapEntry(a, .{ .key = try Value.boxRef(a, try str(a, "Foo")), .value = try Value.boxRef(a, try str(a, "bar")) });
    const same = try make(a, r, stored, try str(a, "Foo"), try str(a, "bar"));
    const other_value = try make(a, r, stored, try str(a, "Foo"), try str(a, "baz"));
    const not_entry = try make(a, r, other, try str(a, "Foo"), try str(a, "bar"));
    const answers = [_]struct { v: Value, want: bool }{
        .{ .v = same, .want = true },
        .{ .v = other_value, .want = false },
        .{ .v = not_entry, .want = false },
    };
    const any_equals = interp_ir.hostMemberFn("kotlin.Any.equals").?;
    for (answers) |c| {
        const res = try any_equals(&host, a, &.{ host_entry, c.v });
        try testing.expect(res == .ok and res.ok == .Bool);
        try testing.expectEqual(c.want, res.ok.Bool);
    }
}

test "a well-known member runs the instance's own implementation, and none the class lacks" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const text = try h.constant(.{ .String = "a Shown" });
    const size = try h.constant(.{ .Int = 7 });
    // `Any.toString` and `Map.get` roots, and a class implementing both.
    const to_string = try h.func("Any.toString", 1);
    const map_get = try h.func("Map.get", 2);
    const list_get = try h.func("List.get", 2);
    const shown = try h.class("Shown", .{});
    const shown_to_string = try h.func("Shown.toString", 1);
    try h.body(shown_to_string, &.{.{ .insts = &.{konst(0, text)}, .term = ret(0) }});
    const shown_get = try h.func("Shown.get", 2);
    try h.body(shown_get, &.{.{ .insts = &.{konst(0, size)}, .term = ret(0) }});
    try h.dispatch(shown, to_string, shown_to_string);
    try h.dispatch(shown, map_get, shown_get);
    h.r.well_known.set(.to_string, slot(to_string));
    h.r.well_known.set(.map_get, slot(map_get));
    h.r.well_known.set(.list_get, slot(list_get));
    try h.finish();

    const module_ref = try runtime.ObjRef(ir.Module).init(a, h.m.*);
    var vm = try interp_ir.Vm.new(a, module_ref);
    defer vm.deinit();
    try vm.prepareResolved();
    var cap = runtime.CaptureOutput.init(a);
    var host = vm.makeHost(cap.output());
    const inst = try ir.resolved.instantiate(a, module_ref.asPtrConst().resolved.?, shown);
    const r = (try host.callWellKnown(a, &inst, .to_string, &.{})).?;
    try testing.expect(r == .ok and r.ok == .String);
    try testing.expectEqualStrings("a Shown", r.ok.String.asPtr().bytes);
    // A host value is the native's to serve.
    const n: Value = .{ .Int = 3 };
    try testing.expect((try host.callWellKnown(a, &n, .to_string, &.{})) == null);
    // `Map.get` is the class's own; it implements no `List.get`.
    const g = (try host.callWellKnown(a, &inst, .map_get, &.{.{ .Int = 0 }})).?;
    try testing.expect(g == .ok);
    try testing.expectEqual(@as(i32, 7), g.ok.Int);
    try testing.expect((try host.callWellKnown(a, &inst, .list_get, &.{.{ .Int = 0 }})) == null);
}

test "a host value whose class declares a well-known member with a Kotlin body runs the VM's member of the root" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    // `Pair.toString` has a Kotlin body, which never reads a host pair.
    const text = try h.constant(.{ .String = "the body" });
    const to_string = try h.func("Any.toString", 1);
    const pair_c = try h.class("Pair", .{});
    h.r.host_class.by_tag[@intFromEnum(std.meta.Tag(Value).Pair)] = pair_c;
    const pair_to_string = try h.func("Pair.toString", 1);
    try h.body(pair_to_string, &.{.{ .insts = &.{konst(0, text)}, .term = ret(0) }});
    try h.dispatch(pair_c, to_string, pair_to_string);
    const slots = try a.alloc(ir.NativeId, 16);
    @memset(slots, .none);
    slots[to_string.int()] = try hostMember(&h, "kotlin.Any.toString");
    h.r.host_slot = slots;
    h.r.well_known.set(.to_string, slot(to_string));
    try h.finish();

    const module_ref = try runtime.ObjRef(ir.Module).init(a, h.m.*);
    var vm = try interp_ir.Vm.new(a, module_ref);
    defer vm.deinit();
    try vm.prepareResolved();
    var cap = runtime.CaptureOutput.init(a);
    var host = vm.makeHost(cap.output());
    const pair = try Value.newPair(a, .{ .first = try Value.boxRef(a, .{ .Int = 1 }), .second = try Value.boxRef(a, .{ .Int = 2 }) });
    const r = (try host.callWellKnown(a, &pair, .to_string, &.{})).?;
    try testing.expect(r == .ok and r.ok == .String);
    try testing.expectEqualStrings("(1, 2)", r.ok.String.asPtr().bytes);
}

test "a well-known static reads its property, its file initialized first" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    // The file's init unit writes 41 into the property.
    const unit_fn = try h.func("<file init>", 0);
    const unit = try h.initUnit(unit_fn);
    const st = try h.static("sync", .int, unit);
    const c41 = try h.constant(.{ .Int = 41 });
    try h.body(unit_fn, &.{.{ .insts = &.{ konst(0, c41), hand.storeStatic(st, 0) }, .term = .{ .Return = null } }});
    h.r.well_known_statics.set(.compose_snapshot_map_sync, st);
    try h.finish();

    const module_ref = try runtime.ObjRef(ir.Module).init(a, h.m.*);
    var vm = try interp_ir.Vm.new(a, module_ref);
    defer vm.deinit();
    try vm.prepareResolved();
    var cap = runtime.CaptureOutput.init(a);
    var host = vm.makeHost(cap.output());
    const r = (try host.wellKnownStatic(a, .compose_snapshot_map_sync)).?;
    try testing.expect(r == .ok);
    try testing.expectEqual(@as(i32, 41), r.ok.Int);
    // A property the tables do not name has no value.
    try testing.expect((try host.wellKnownStatic(a, .compose_global_snapshot)) == null);
}

test "an instance the tables make carries its class in its header" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c = try h.class("C", .{ .slot_names = &.{"x"}, .seeds = &.{.int} });
    try h.finish();
    const inst = try ir.resolved.instantiate(a, h.r, c);
    try testing.expectEqual(c.int(), inst.Instance.asPtrConst().class_id);
    // The header answers, not the def.
    h.r.classes[c.int()].def.asPtr().ir_class = std.math.maxInt(u32);
    try testing.expectEqual(c, ir.resolved.classOf(h.r, &inst).?);
}

test "a well-known object is the tables' object, made once" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const key = try h.class("CoroutineExceptionHandler.Key", .{});
    h.object(key, try hand.ctorReturningThis(&h));
    h.r.well_known_objects.set(.coroutine_exception_handler_key, key);
    try h.finish();
    const module_ref = try runtime.ObjRef(ir.Module).init(a, h.m.*);
    var vm = try interp_ir.Vm.new(a, module_ref);
    defer vm.deinit();
    try vm.prepareResolved();
    var cap = runtime.CaptureOutput.init(a);
    var host = vm.makeHost(cap.output());
    const first = (try host.wellKnownObject(a, .coroutine_exception_handler_key)).?;
    const second = (try host.wellKnownObject(a, .coroutine_exception_handler_key)).?;
    try testing.expect(first == .ok and first.ok == .Instance);
    try testing.expect(runtime.ObjRef(runtime.InstanceData).ptrEq(first.ok.Instance, second.ok.Instance));
    try testing.expectEqual(key, ir.resolved.classOf(module_ref.asPtrConst().resolved.?, &first.ok).?);
}

test "the host displays a closure as its toString answers" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    // A program run of its own, as `runMain` makes one: the host's per-thread
    // caches keyed by another run's addresses must not answer here.
    interp_ir.resetRunGlobalCaches();
    defer interp_ir.resetRunGlobalCaches();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const target = try h.func("foo", 1);
    const c1 = try h.constant(.{ .Int = 1 });
    try h.body(target, &.{.{ .insts = &.{konst(0, c1)}, .term = ret(0) }});
    const adapter = try h.func("foo$ref", 1);
    try h.body(adapter, &.{.{ .insts = &.{konst(0, c1)}, .term = ret(0) }});
    try h.finish();
    const module_ref = try runtime.ObjRef(ir.Module).init(a, h.m.*);
    var vm = try interp_ir.Vm.new(a, module_ref);
    defer vm.deinit();
    try vm.prepareResolved();
    var cap = runtime.CaptureOutput.init(a);
    var host = vm.makeHost(cap.output());
    const module = module_ref.asPtrConst();
    interp_ir.gcInstallClosureHook(vm.closures, module);
    defer interp_ir.gcResetProgramHooks();
    const made = try host.makeResolvedClosure(a, module, adapter, &.{}, .{ .function_ref = target });
    try testing.expect(made == .ok);
    const text = try made.ok.display(a);
    try testing.expectEqualStrings("function foo (Kotlin reflection is not available)", text);
}

fn suspendHere(ctx: *runtime.CallCtx) Allocator.Error!runtime.EvalResult {
    _ = ctx;
    return .{ .err = .{ .Suspend = 0 } };
}

test "a call that suspends resumes into its call's register" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const susp = try h.native("suspendHere", suspendHere);
    const await_value = try h.func("awaitValue", 0);
    h.bindNative(await_value, susp);
    // A native that suspends is a `suspend fun`: its callers stay framed.
    h.m.funcs.items[await_value.int()].is_suspend = true;
    const c1 = try h.constant(.{ .Int = 1 });
    // The native suspends inside a `CallNative` of a flat activation.
    const via_native = try h.func("viaNative", 0);
    try h.body(via_native, &.{.{ .insts = &.{
        .{ .CallNative = .{ .dst = reg(0), .native = susp, .args = reg(0), .n_args = 0 } },
        konst(1, c1),
        bin(2, .Add, 0, 1),
    }, .term = ret(2) }});
    // The native suspends inside a `CallStatic` of a native-bound declaration.
    const via_static = try h.func("viaStatic", 0);
    try h.body(via_static, &.{.{ .insts = &.{
        hand.callStatic(0, await_value, 0, 0),
        konst(1, c1),
        bin(2, .Add, 0, 1),
    }, .term = ret(2) }});
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        hand.callStatic(0, via_native, 0, 0),
        hand.callStatic(1, via_static, 0, 0),
        bin(2, .Add, 0, 1),
    }, .term = ret(2) }});
    try h.finish();

    const module_ref = try runtime.ObjRef(ir.Module).init(a, h.m.*);
    var vm = try interp_ir.Vm.new(a, module_ref);
    defer vm.deinit();
    try vm.prepareResolved();
    var cap = runtime.CaptureOutput.init(a);
    var host = vm.makeHost(cap.output());
    const module = module_ref.asPtrConst();
    const first = try ir.eval.evalWith(interp_ir.VmHost, a, module, module.funcById(main).?, .empty, &host);
    try testing.expect(first == .err and first.err == .Suspended);
    const second = try ir.eval.resumeContinuation(interp_ir.VmHost, a, module, first.err.Suspended, .{ .Int = 20 }, &host);
    try testing.expect(second == .err and second.err == .Suspended);
    const third = try ir.eval.resumeContinuation(interp_ir.VmHost, a, module, second.err.Suspended, .{ .Int = 30 }, &host);
    if (third == .err) std.debug.print("resume failed: {any}\n", .{third.err});
    try testing.expect(third == .ok);
    try testing.expectEqual(@as(i32, 52), third.ok.Int);
}

test "a chain of static calls runs in the stream, each call site keeping its callee" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const main = try hand.staticChain(&h);
    const run = try runVm(a, &h, main);
    try testing.expect(run.res == .ok);
    try testing.expectEqual(@as(i32, 42), run.res.ok.Int);
    // Every call ran from a stream, which kept the callee's streams at its site.
    for (h.m.funcs.items) |*f| {
        const fs = ir.bc.funcStreams(f, h.m.consts.items) orelse return error.TestUnexpectedResult;
        for (fs.callees) |*c| try testing.expect(c.load(.acquire) != null);
    }
}

test "an uncaught throw fails the run with the throwable's class" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const ctor = try hand.ctorStoringMessage(&h);
    const ise = try hand.throwableClass(&h, "IllegalStateException", &.{});
    const bad = try h.constant(.{ .String = "bad state" });
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{ konst(0, bad), hand.newInstance(1, ise, ctor, 0, 1) }, .term = .{ .Throw = reg(1) } }});
    try h.finish();
    const run = try runVm(a, &h, main);
    try testing.expect(run.res == .err);
    try testing.expect(std.mem.find(u8, run.res.err.Eval, "IllegalStateException") != null);
    // The slot's display name labels the field the message is in.
    try testing.expect(std.mem.find(u8, run.res.err.Eval, "bad state") != null);
}

/// A VM over `h`'s tables, for a test that calls the host directly.
const HostRig = struct {
    vm: interp_ir.Vm,
    host: interp_ir.VmHost,
    view: interp_ir.VmIntrinsicHost,
    cap: runtime.CaptureOutput,

    fn init(self: *HostRig, a: Allocator, h: *Hand) !void {
        const module_ref = try runtime.ObjRef(ir.Module).init(a, h.m.*);
        self.vm = try interp_ir.Vm.new(a, module_ref);
        try self.vm.prepareResolved();
        self.cap = runtime.CaptureOutput.init(a);
        self.host = self.vm.makeHost(self.cap.output());
        self.view = interp_ir.VmIntrinsicHost.borrowedFrom(&self.host);
    }

    fn deinit(self: *HostRig) void {
        self.vm.deinit();
    }

    fn natives(self: *HostRig) runtime.IntrinsicHost {
        return self.view.intrinsicHost();
    }

    fn module(self: *HostRig) *const ir.Module {
        return self.host.module.asPtrConst();
    }
};

test "a native invokes an instance of a class implementing a function type through its invoke, never a member named invoke" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const c100 = try h.constant(.{ .Int = 100 });
    const invoke0 = try h.func("Function0.invoke", 1);
    const invoke1 = try h.func("Function1.invoke", 2);
    const adder_invoke = try h.func("Adder.invoke", 2);
    try h.body(adder_invoke, &.{.{ .insts = &.{ param(0, 1), konst(1, c100), bin(2, .Add, 0, 1) }, .term = ret(2) }});
    const function1 = try h.class("Function1", .{});
    const adder = try h.class("Adder", .{ .supers = &.{function1} });
    try h.dispatch(adder, invoke1, adder_invoke);
    // A class declaring a function called `invoke` but no function type.
    const plain = try h.class("Plain", .{});
    const plain_invoke = try h.func("Plain.invoke", 2);
    try h.body(plain_invoke, &.{.{ .insts = &.{param(0, 1)}, .term = ret(0) }});
    h.r.host_class.invoke_slot = &.{ slot(invoke0), slot(invoke1) };
    try h.finish();

    var rig: HostRig = undefined;
    try rig.init(a, &h);
    defer rig.deinit();
    const r = rig.module().resolved.?;
    const fn_inst = try ir.resolved.instantiate(a, r, adder);
    const got = try rig.natives().invokeCallable(&fn_inst, &.{.{ .Int = 5 }}, rig.cap.output());
    try testing.expect(got == .ok);
    try testing.expectEqual(@as(i32, 105), got.ok.Int);
    const plain_inst = try ir.resolved.instantiate(a, r, plain);
    const refused = try rig.natives().invokeCallable(&plain_inst, &.{.{ .Int = 5 }}, rig.cap.output());
    try expectNotCallable(refused, "Vm::invoke_callable on");
}

/// A callable the host refused as not callable, rather than a call it tried.
fn expectNotCallable(r: runtime.EvalResult, what: []const u8) !void {
    try testing.expect(r == .err and r.err == .Unimplemented);
    try testing.expect(std.mem.startsWith(u8, r.err.Unimplemented, what));
}

test "a native invoking a host comparator runs Comparator.compare through its slot" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const compare = try h.func("Comparator.compare", 3);
    const comparator = try h.class("Comparator", .{});
    h.r.host_class.by_tag[@intFromEnum(std.meta.Tag(Value).Comparator)] = comparator;
    const slots = try a.alloc(ir.NativeId, 16);
    @memset(slots, .none);
    slots[compare.int()] = try hostMember(&h, "kotlin.Comparator.compare");
    h.r.host_slot = slots;
    h.r.well_known.set(.compare, slot(compare));
    try h.finish();

    var rig: HostRig = undefined;
    try rig.init(a, &h);
    defer rig.deinit();
    const steps = try a.alloc(runtime.ComparatorStep, 0);
    const reverse = try Value.newComparator(a, .{ .steps = try runtime.ObjRef([]runtime.ComparatorStep).init(a, steps), .descending = true });
    const got = try rig.natives().invokeCallable(&reverse, &.{ .{ .Int = 1 }, .{ .Int = 2 } }, rig.cap.output());
    try testing.expect(got == .ok);
    try testing.expect(got.ok.asI64().? > 0);
}

test "a class value is constructed by the class its def names by id, never by its name" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    _ = try h.class("Box", .{});
    try h.finish();

    var rig: HostRig = undefined;
    try rig.init(a, &h);
    defer rig.deinit();
    // A def naming `Box` but no class in the tables.
    const stray = try runtime.ClassDef.minimal(a, "Box", "Box", std.math.maxInt(u32));
    const class_value: Value = .{ .Class = stray };
    try expectNotCallable(try rig.natives().invokeCallable(&class_value, &.{}, rig.cap.output()), "Vm::invoke_callable on");
    const recv: Value = .{ .Int = 65 };
    try expectNotCallable(try rig.natives().invokeCallableWithThis(&class_value, &.{}, &recv, rig.cap.output()), "Vm::invoke_callable_with_this on");
}

test "a native builds a well-known class through its primary constructor" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    const iv = try h.class("IndexedValue", .{ .seeds = &.{ .int, .null_ref }, .slot_names = &.{ "index", "value" } });
    const ctor = try h.func("IndexedValue.<init>", 3);
    try h.body(ctor, &.{.{ .insts = &.{ param(0, 0), param(1, 1), param(2, 2), hand.setField(0, 0, 1), hand.setField(0, 1, 2) }, .term = ret(0) }});
    try h.finish();

    var rig: HostRig = undefined;
    try rig.init(a, &h);
    defer rig.deinit();
    // Before the tables name the class, a native has nothing to build.
    try testing.expect((try rig.natives().constructWellKnown(.indexed_value, &.{ .{ .Int = 3 }, .{ .Int = 9 } }, rig.cap.output())) == null);
    h.r.well_known_classes.set(.indexed_value, .{ .class = iv, .ctor = ctor });
    const got = (try rig.natives().constructWellKnown(.indexed_value, &.{ .{ .Int = 3 }, .{ .Int = 9 } }, rig.cap.output())).?;
    try testing.expect(got == .ok and got.ok == .Instance);
    try testing.expectEqual(iv, ir.resolved.classOf(h.r, &got.ok).?);
    try testing.expectEqual(@as(i32, 3), runtime.InstanceData.slotGet(got.ok.Instance, 0).?.Int);
    try testing.expectEqual(@as(i32, 9), runtime.InstanceData.slotGet(got.ok.Instance, 1).?.Int);
}

test "a host instance holds the native's state and has no class in the tables" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try Hand.init(a);
    // A class of the name the host instance stands for, which it must not become.
    _ = try h.class("SequenceScope", .{});
    try h.finish();

    var rig: HostRig = undefined;
    try rig.init(a, &h);
    defer rig.deinit();
    const fields = [_]runtime.InstanceData.Field{.{ .name = "__seq_has_value", .value = .{ .Bool = false } }};
    const scope = try rig.natives().newHostInstance(.sequence_scope, 7, &fields);
    try testing.expect(scope == .Instance);
    try testing.expect(ir.resolved.classOf(h.r, &scope) == null);
    const g = scope.Instance.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(u64, 7), g.get().identityOf());
    try testing.expect(g.get().get("__seq_has_value").?.Bool == false);
    const cg = g.get().class.borrow();
    defer cg.deinit();
    try testing.expectEqualStrings("kotlin.sequences.SequenceScope", cg.get().fqn);
}
