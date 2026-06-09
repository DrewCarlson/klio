//! Native bindings for `kotlinx.atomicfu`.
//!
//! klio runs single-threaded, so the "atomic" operations are
//! trivially atomic: every binding mutates the instance's `value`
//! field directly. The pack consumes upstream atomicfu commonMain
//! `expect` declarations plus klio `actual`s (under `klioMain/`)
//! that declare the class shapes; these bindings shadow the actual
//! method bodies at dispatch time via the `installed_bindings`
//! table on the interpreter.

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const StdlibFn = runtime.StdlibFn;
const InstanceData = runtime.InstanceData;
const ObjRef = runtime.ObjRef;
const HostBindings = stdlib.HostBindings;

const InstanceRef = ObjRef(InstanceData);

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn typeErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Type = msg } };
}

pub fn hostBindings(allocator: std.mem.Allocator) std.mem.Allocator.Error!HostBindings {
    var b = HostBindings.init(allocator);
    const bindings = [_]struct { []const u8, StdlibFn }{
        .{ "kotlinx.atomicfu.AtomicInt.compareAndSet", atomicIntCas },
        .{ "kotlinx.atomicfu.AtomicInt.getAndSet", atomicIntGetAndSet },
        .{ "kotlinx.atomicfu.AtomicInt.getAndIncrement", atomicIntGetAndIncrement },
        .{ "kotlinx.atomicfu.AtomicInt.getAndDecrement", atomicIntGetAndDecrement },
        .{ "kotlinx.atomicfu.AtomicInt.incrementAndGet", atomicIntIncrementAndGet },
        .{ "kotlinx.atomicfu.AtomicInt.decrementAndGet", atomicIntDecrementAndGet },
        .{ "kotlinx.atomicfu.AtomicInt.getAndAdd", atomicIntGetAndAdd },
        .{ "kotlinx.atomicfu.AtomicInt.addAndGet", atomicIntAddAndGet },
        .{ "kotlinx.atomicfu.AtomicInt.plusAssign", atomicIntPlusAssign },
        .{ "kotlinx.atomicfu.AtomicInt.minusAssign", atomicIntMinusAssign },
        .{ "kotlinx.atomicfu.AtomicLong.compareAndSet", atomicLongCas },
        .{ "kotlinx.atomicfu.AtomicLong.getAndSet", atomicLongGetAndSet },
        .{ "kotlinx.atomicfu.AtomicLong.getAndIncrement", atomicLongGetAndIncrement },
        .{ "kotlinx.atomicfu.AtomicLong.getAndDecrement", atomicLongGetAndDecrement },
        .{ "kotlinx.atomicfu.AtomicLong.incrementAndGet", atomicLongIncrementAndGet },
        .{ "kotlinx.atomicfu.AtomicLong.decrementAndGet", atomicLongDecrementAndGet },
        .{ "kotlinx.atomicfu.AtomicLong.getAndAdd", atomicLongGetAndAdd },
        .{ "kotlinx.atomicfu.AtomicLong.addAndGet", atomicLongAddAndGet },
        .{ "kotlinx.atomicfu.AtomicLong.plusAssign", atomicLongPlusAssign },
        .{ "kotlinx.atomicfu.AtomicLong.minusAssign", atomicLongMinusAssign },
        .{ "kotlinx.atomicfu.AtomicBoolean.compareAndSet", atomicBoolCas },
        .{ "kotlinx.atomicfu.AtomicBoolean.getAndSet", atomicBoolGetAndSet },
        .{ "kotlinx.atomicfu.AtomicRef.compareAndSet", atomicRefCas },
        .{ "kotlinx.atomicfu.AtomicRef.getAndSet", atomicRefGetAndSet },
    };
    for (bindings) |entry| {
        try b.register(entry[0], entry[1]);
    }
    return b;
}

/// `Result<&InstanceRef, RuntimeError>` for the receiver lookup. On the
/// error path it carries the `RuntimeError` data; on success the receiver
/// handle.
const ReceiverResult = union(enum) {
    inst: InstanceRef,
    err: RuntimeError,
};

fn receiverInstance(ctx: *const CallCtx) ReceiverResult {
    if (ctx.args.len > 0) {
        switch (ctx.args[0]) {
            .Instance => |inst| return .{ .inst = inst },
            else => {},
        }
    }
    return .{ .err = .{ .Type = "kotlinx.atomicfu binding expected an instance receiver" } };
}

/// `Result<i64, RuntimeError>` for primitive field/argument reads.
const IntResult = union(enum) {
    val: i64,
    err: RuntimeError,
};

/// `Result<bool, RuntimeError>` for boolean field/argument reads.
const BoolResult = union(enum) {
    val: bool,
    err: RuntimeError,
};

fn intField(inst: InstanceRef) IntResult {
    const g = inst.borrow();
    defer g.deinit();
    if (g.get().get("value")) |v| {
        switch (v) {
            .Int => |i| return .{ .val = @as(i64, i) },
            .Long => |l| return .{ .val = l },
            else => {},
        }
    }
    return .{ .err = .{ .Type = "AtomicInt: receiver missing `value: Int`" } };
}

fn longField(inst: InstanceRef) IntResult {
    const g = inst.borrow();
    defer g.deinit();
    if (g.get().get("value")) |v| {
        switch (v) {
            .Long => |l| return .{ .val = l },
            .Int => |i| return .{ .val = @as(i64, i) },
            else => {},
        }
    }
    return .{ .err = .{ .Type = "AtomicLong: receiver missing `value: Long`" } };
}

fn boolField(inst: InstanceRef) BoolResult {
    const g = inst.borrow();
    defer g.deinit();
    if (g.get().get("value")) |v| {
        switch (v) {
            .Bool => |b| return .{ .val = b },
            else => {},
        }
    }
    return .{ .err = .{ .Type = "AtomicBoolean: receiver missing `value: Boolean`" } };
}

fn argInt(ctx: *const CallCtx, idx: usize) std.mem.Allocator.Error!IntResult {
    if (idx < ctx.args.len) {
        switch (ctx.args[idx]) {
            .Int => |i| return .{ .val = @as(i64, i) },
            .Long => |l| return .{ .val = l },
            else => {},
        }
    }
    const msg = try std.fmt.allocPrint(ctx.allocator, "kotlinx.atomicfu: argument {d} must be Int/Long", .{idx});
    return .{ .err = .{ .Type = msg } };
}

fn argBool(ctx: *const CallCtx, idx: usize) std.mem.Allocator.Error!BoolResult {
    if (idx < ctx.args.len) {
        switch (ctx.args[idx]) {
            .Bool => |b| return .{ .val = b },
            else => {},
        }
    }
    const msg = try std.fmt.allocPrint(ctx.allocator, "kotlinx.atomicfu: argument {d} must be Boolean", .{idx});
    return .{ .err = .{ .Type = msg } };
}

fn storeInt(allocator: std.mem.Allocator, inst: InstanceRef, v: i64) std.mem.Allocator.Error!void {
    const g = inst.borrowMut();
    defer g.deinit();
    try g.get().define(allocator, "value", Value.newInt(v));
}

fn storeLong(allocator: std.mem.Allocator, inst: InstanceRef, v: i64) std.mem.Allocator.Error!void {
    const g = inst.borrowMut();
    defer g.deinit();
    try g.get().define(allocator, "value", .{ .Long = v });
}

fn storeBool(allocator: std.mem.Allocator, inst: InstanceRef, v: bool) std.mem.Allocator.Error!void {
    const g = inst.borrowMut();
    defer g.deinit();
    try g.get().define(allocator, "value", .{ .Bool = v });
}

// ---------- AtomicInt ----------

/// Outcome of an int read-modify-write closure: the value to store back
/// plus the call's result `Value`.
const IntStep = struct { next: i64, out: Value };

/// `Result<Value, RuntimeError>` for the read-modify-write helper.
const StepResult = union(enum) {
    val: Value,
    err: RuntimeError,
};

/// Run `f` under a single exclusive borrow of the receiver instance so
/// the read-modify-write is observed atomically. `f` receives the current
/// `Int`/`Long` value and returns the new value plus the call's result
/// `Value`.
fn withIntFieldMut(
    allocator: std.mem.Allocator,
    inst: InstanceRef,
    comptime ctxType: type,
    fctx: ctxType,
    f: *const fn (ctxType, i64) IntStep,
) std.mem.Allocator.Error!StepResult {
    const g = inst.borrowMut();
    defer g.deinit();
    const guard = g.get();
    var cur: i64 = undefined;
    if (guard.get("value")) |v| {
        switch (v) {
            .Int => |i| cur = @as(i64, i),
            .Long => |l| cur = l,
            else => return .{ .err = .{ .Type = "AtomicInt: receiver missing `value: Int`" } },
        }
    } else {
        return .{ .err = .{ .Type = "AtomicInt: receiver missing `value: Int`" } };
    }
    const step = f(fctx, cur);
    try guard.define(allocator, "value", Value.newInt(step.next));
    return .{ .val = step.out };
}

fn atomicIntCas(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const expected = switch (try argInt(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const update = switch (try argInt(ctx, 2)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const Cap = struct { expected: i64, update: i64 };
    const cap = Cap{ .expected = expected, .update = update };
    const step = struct {
        fn run(c: Cap, cur: i64) IntStep {
            if (cur == c.expected) {
                return .{ .next = c.update, .out = .{ .Bool = true } };
            } else {
                return .{ .next = cur, .out = .{ .Bool = false } };
            }
        }
    }.run;
    return switch (try withIntFieldMut(ctx.allocator, inst, Cap, cap, step)) {
        .val => |v| ok(v),
        .err => |e| .{ .err = e },
    };
}

fn atomicIntGetAndSet(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const next = switch (try argInt(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const step = struct {
        fn run(n: i64, cur: i64) IntStep {
            return .{ .next = n, .out = Value.newInt(cur) };
        }
    }.run;
    return switch (try withIntFieldMut(ctx.allocator, inst, i64, next, step)) {
        .val => |v| ok(v),
        .err => |e| .{ .err = e },
    };
}

fn atomicIntGetAndIncrement(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const step = struct {
        fn run(_: void, cur: i64) IntStep {
            return .{ .next = cur +% 1, .out = Value.newInt(cur) };
        }
    }.run;
    return switch (try withIntFieldMut(ctx.allocator, inst, void, {}, step)) {
        .val => |v| ok(v),
        .err => |e| .{ .err = e },
    };
}

fn atomicIntGetAndDecrement(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const step = struct {
        fn run(_: void, cur: i64) IntStep {
            return .{ .next = cur -% 1, .out = Value.newInt(cur) };
        }
    }.run;
    return switch (try withIntFieldMut(ctx.allocator, inst, void, {}, step)) {
        .val => |v| ok(v),
        .err => |e| .{ .err = e },
    };
}

fn atomicIntIncrementAndGet(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const step = struct {
        fn run(_: void, cur: i64) IntStep {
            const n = cur +% 1;
            return .{ .next = n, .out = Value.newInt(n) };
        }
    }.run;
    return switch (try withIntFieldMut(ctx.allocator, inst, void, {}, step)) {
        .val => |v| ok(v),
        .err => |e| .{ .err = e },
    };
}

fn atomicIntDecrementAndGet(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const step = struct {
        fn run(_: void, cur: i64) IntStep {
            const n = cur -% 1;
            return .{ .next = n, .out = Value.newInt(n) };
        }
    }.run;
    return switch (try withIntFieldMut(ctx.allocator, inst, void, {}, step)) {
        .val => |v| ok(v),
        .err => |e| .{ .err = e },
    };
}

fn atomicIntGetAndAdd(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const delta = switch (try argInt(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const step = struct {
        fn run(d: i64, cur: i64) IntStep {
            return .{ .next = cur +% d, .out = Value.newInt(cur) };
        }
    }.run;
    return switch (try withIntFieldMut(ctx.allocator, inst, i64, delta, step)) {
        .val => |v| ok(v),
        .err => |e| .{ .err = e },
    };
}

fn atomicIntAddAndGet(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const delta = switch (try argInt(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const step = struct {
        fn run(d: i64, cur: i64) IntStep {
            const n = cur +% d;
            return .{ .next = n, .out = Value.newInt(n) };
        }
    }.run;
    return switch (try withIntFieldMut(ctx.allocator, inst, i64, delta, step)) {
        .val => |v| ok(v),
        .err => |e| .{ .err = e },
    };
}

fn atomicIntPlusAssign(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = try atomicIntAddAndGet(ctx);
    return switch (r) {
        .ok => ok(.Unit),
        .err => |e| .{ .err = e },
    };
}

fn atomicIntMinusAssign(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const delta = switch (try argInt(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const cur = switch (intField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    try storeInt(ctx.allocator, inst, cur -% delta);
    return ok(.Unit);
}

// ---------- AtomicLong ----------

fn atomicLongCas(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const cur = switch (longField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const expected = switch (try argInt(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const update = switch (try argInt(ctx, 2)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (cur == expected) {
        try storeLong(ctx.allocator, inst, update);
        return ok(.{ .Bool = true });
    } else {
        return ok(.{ .Bool = false });
    }
}

fn atomicLongGetAndSet(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const prev = switch (longField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const next = switch (try argInt(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    try storeLong(ctx.allocator, inst, next);
    return ok(.{ .Long = prev });
}

fn atomicLongGetAndIncrement(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const prev = switch (longField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    try storeLong(ctx.allocator, inst, prev +% 1);
    return ok(.{ .Long = prev });
}

fn atomicLongGetAndDecrement(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const prev = switch (longField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    try storeLong(ctx.allocator, inst, prev -% 1);
    return ok(.{ .Long = prev });
}

fn atomicLongIncrementAndGet(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const cur = switch (longField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const next = cur +% 1;
    try storeLong(ctx.allocator, inst, next);
    return ok(.{ .Long = next });
}

fn atomicLongDecrementAndGet(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const cur = switch (longField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const next = cur -% 1;
    try storeLong(ctx.allocator, inst, next);
    return ok(.{ .Long = next });
}

fn atomicLongGetAndAdd(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const prev = switch (longField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const delta = switch (try argInt(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    try storeLong(ctx.allocator, inst, prev +% delta);
    return ok(.{ .Long = prev });
}

fn atomicLongAddAndGet(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const delta = switch (try argInt(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const cur = switch (longField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const next = cur +% delta;
    try storeLong(ctx.allocator, inst, next);
    return ok(.{ .Long = next });
}

fn atomicLongPlusAssign(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = try atomicLongAddAndGet(ctx);
    return switch (r) {
        .ok => ok(.Unit),
        .err => |e| .{ .err = e },
    };
}

fn atomicLongMinusAssign(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const delta = switch (try argInt(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const cur = switch (longField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    try storeLong(ctx.allocator, inst, cur -% delta);
    return ok(.Unit);
}

// ---------- AtomicBoolean ----------

fn atomicBoolCas(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const cur = switch (boolField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const expected = switch (try argBool(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const update = switch (try argBool(ctx, 2)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (cur == expected) {
        try storeBool(ctx.allocator, inst, update);
        return ok(.{ .Bool = true });
    } else {
        return ok(.{ .Bool = false });
    }
}

fn atomicBoolGetAndSet(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const prev = switch (boolField(inst)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    const next = switch (try argBool(ctx, 1)) {
        .val => |v| v,
        .err => |e| return .{ .err = e },
    };
    try storeBool(ctx.allocator, inst, next);
    return ok(.{ .Bool = prev });
}

// ---------- AtomicRef<T> ----------

fn atomicRefCas(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const cur = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().get("value") orelse Value.Null;
    };
    const expected = if (ctx.args.len > 1) ctx.args[1] else Value.Null;
    const update = if (ctx.args.len > 2) ctx.args[2] else Value.Null;
    // atomicfu `compareAndSet` is a CAS: it compares by *referential
    // identity* for reference types (and by value for primitives /
    // null), exactly like Kotlin `===`. The lock-free channel /
    // coroutine algorithms swap on sentinel-object identity (e.g.
    // `_closeCause.compareAndSet(NO_CLOSE_CAUSE, cause)`); structural
    // equality mis-CASes distinct-but-equal objects and corrupts
    // that state.
    if (Value.referenceEq(&cur, &expected)) {
        const g = inst.borrowMut();
        defer g.deinit();
        try g.get().define(ctx.allocator, "value", update);
        return ok(.{ .Bool = true });
    } else {
        return ok(.{ .Bool = false });
    }
}

fn atomicRefGetAndSet(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const inst = switch (receiverInstance(ctx)) {
        .inst => |i| i,
        .err => |e| return .{ .err = e },
    };
    const prev = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().get("value") orelse Value.Null;
    };
    const next = if (ctx.args.len > 1) ctx.args[1] else Value.Null;
    {
        const g = inst.borrowMut();
        defer g.deinit();
        try g.get().define(ctx.allocator, "value", next);
    }
    return ok(prev);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const Env = runtime.Env;
const ClassDef = runtime.ClassDef;

fn makeClass(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!ObjRef(ClassDef) {
    const cd: ClassDef = .{
        .name = name,
        .fqn = name,
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = false,
        .is_sealed = false,
        .supertype_names = &.{},
        .parent = null,
        .interfaces = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = false,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .nested_classes = &.{},
        .captured_env = try ObjRef(Env).init(allocator, Env.init(allocator)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    };
    return ObjRef(ClassDef).init(allocator, cd);
}

fn makeInstance(allocator: std.mem.Allocator, name: []const u8, value: Value) std.mem.Allocator.Error!InstanceRef {
    const cls = try makeClass(allocator, name);
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(allocator, .{ .name = "value", .value = value });
    return ObjRef(InstanceData).init(allocator, .{
        .class = cls,
        .fields = fields,
        .outer = null,
        .identity = 1,
        .native_state = null,
    });
}

const testing = std.testing;

fn makeCtx(allocator: std.mem.Allocator, args: []const Value, host_ptr: *runtime.NoopHost, cap: *runtime.CaptureOutput) CallCtx {
    return .{
        .args = args,
        .out = cap.output(),
        .host = host_ptr.host(),
        .allocator = allocator,
    };
}

fn fieldInt(inst: InstanceRef) i64 {
    const g = inst.borrow();
    defer g.deinit();
    return switch (g.get().get("value").?) {
        .Int => |i| @as(i64, i),
        .Long => |l| l,
        else => unreachable,
    };
}

test "host bindings registers every atomicfu symbol" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 24), b.len());
    try testing.expect(b.resolve("kotlinx.atomicfu.AtomicInt.compareAndSet") != null);
    try testing.expect(b.resolve("kotlinx.atomicfu.AtomicRef.getAndSet") != null);
    try testing.expect(b.resolve("kotlinx.atomicfu.AtomicBoolean.getAndSet") != null);
}

test "AtomicInt compareAndSet succeeds and fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = runtime.NoopHost.init(a);
    var cap = runtime.CaptureOutput.init(a);

    const inst = try makeInstance(a, "AtomicInt", .{ .Int = 7 });

    var args = [_]Value{ .{ .Instance = inst }, .{ .Int = 7 }, .{ .Int = 9 } };
    var ctx = makeCtx(a, &args, &h, &cap);
    const r = try atomicIntCas(&ctx);
    try testing.expect(r == .ok and r.ok.Bool == true);
    try testing.expectEqual(@as(i64, 9), fieldInt(inst));

    var args2 = [_]Value{ .{ .Instance = inst }, .{ .Int = 7 }, .{ .Int = 11 } };
    var ctx2 = makeCtx(a, &args2, &h, &cap);
    const r2 = try atomicIntCas(&ctx2);
    try testing.expect(r2 == .ok and r2.ok.Bool == false);
    try testing.expectEqual(@as(i64, 9), fieldInt(inst));
}

test "AtomicInt getAndSet returns previous and stores next" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = runtime.NoopHost.init(a);
    var cap = runtime.CaptureOutput.init(a);

    const inst = try makeInstance(a, "AtomicInt", .{ .Int = 3 });
    var args = [_]Value{ .{ .Instance = inst }, .{ .Int = 42 } };
    var ctx = makeCtx(a, &args, &h, &cap);
    const r = try atomicIntGetAndSet(&ctx);
    try testing.expect(r == .ok and r.ok.Int == 3);
    try testing.expectEqual(@as(i64, 42), fieldInt(inst));
}

test "AtomicInt increment/decrement variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = runtime.NoopHost.init(a);
    var cap = runtime.CaptureOutput.init(a);

    const inst = try makeInstance(a, "AtomicInt", .{ .Int = 0 });
    var args = [_]Value{.{ .Instance = inst }};
    var ctx = makeCtx(a, &args, &h, &cap);

    const gi = try atomicIntGetAndIncrement(&ctx);
    try testing.expect(gi.ok.Int == 0);
    try testing.expectEqual(@as(i64, 1), fieldInt(inst));

    const ig = try atomicIntIncrementAndGet(&ctx);
    try testing.expect(ig.ok.Int == 2);

    const gd = try atomicIntGetAndDecrement(&ctx);
    try testing.expect(gd.ok.Int == 2);
    try testing.expectEqual(@as(i64, 1), fieldInt(inst));

    const dg = try atomicIntDecrementAndGet(&ctx);
    try testing.expect(dg.ok.Int == 0);
}

test "AtomicInt getAndAdd/addAndGet and plus/minus assign" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = runtime.NoopHost.init(a);
    var cap = runtime.CaptureOutput.init(a);

    const inst = try makeInstance(a, "AtomicInt", .{ .Int = 10 });
    var args = [_]Value{ .{ .Instance = inst }, .{ .Int = 5 } };
    var ctx = makeCtx(a, &args, &h, &cap);

    const ga = try atomicIntGetAndAdd(&ctx);
    try testing.expect(ga.ok.Int == 10);
    try testing.expectEqual(@as(i64, 15), fieldInt(inst));

    const ag = try atomicIntAddAndGet(&ctx);
    try testing.expect(ag.ok.Int == 20);

    const pa = try atomicIntPlusAssign(&ctx);
    try testing.expect(pa == .ok and pa.ok == .Unit);
    try testing.expectEqual(@as(i64, 25), fieldInt(inst));

    const ma = try atomicIntMinusAssign(&ctx);
    try testing.expect(ma == .ok and ma.ok == .Unit);
    try testing.expectEqual(@as(i64, 20), fieldInt(inst));
}

test "AtomicLong arithmetic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = runtime.NoopHost.init(a);
    var cap = runtime.CaptureOutput.init(a);

    const inst = try makeInstance(a, "AtomicLong", .{ .Long = 100 });
    var cas_args = [_]Value{ .{ .Instance = inst }, .{ .Long = 100 }, .{ .Long = 200 } };
    var cas_ctx = makeCtx(a, &cas_args, &h, &cap);
    const cas = try atomicLongCas(&cas_ctx);
    try testing.expect(cas.ok.Bool == true);

    var inc_args = [_]Value{.{ .Instance = inst }};
    var inc_ctx = makeCtx(a, &inc_args, &h, &cap);
    const ig = try atomicLongIncrementAndGet(&inc_ctx);
    try testing.expect(ig.ok.Long == 201);

    const gd = try atomicLongGetAndDecrement(&inc_ctx);
    try testing.expect(gd.ok.Long == 201);

    var add_args = [_]Value{ .{ .Instance = inst }, .{ .Long = 9 } };
    var add_ctx = makeCtx(a, &add_args, &h, &cap);
    const ag = try atomicLongAddAndGet(&add_ctx);
    try testing.expect(ag.ok.Long == 209);

    const pa = try atomicLongPlusAssign(&add_ctx);
    try testing.expect(pa.ok == .Unit);
    const ma = try atomicLongMinusAssign(&add_ctx);
    try testing.expect(ma.ok == .Unit);
}

test "AtomicBoolean compareAndSet and getAndSet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = runtime.NoopHost.init(a);
    var cap = runtime.CaptureOutput.init(a);

    const inst = try makeInstance(a, "AtomicBoolean", .{ .Bool = false });
    var cas_args = [_]Value{ .{ .Instance = inst }, .{ .Bool = false }, .{ .Bool = true } };
    var cas_ctx = makeCtx(a, &cas_args, &h, &cap);
    const cas = try atomicBoolCas(&cas_ctx);
    try testing.expect(cas.ok.Bool == true);

    var gs_args = [_]Value{ .{ .Instance = inst }, .{ .Bool = false } };
    var gs_ctx = makeCtx(a, &gs_args, &h, &cap);
    const gs = try atomicBoolGetAndSet(&gs_ctx);
    try testing.expect(gs.ok.Bool == true);
}

test "AtomicRef compareAndSet by identity and getAndSet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = runtime.NoopHost.init(a);
    var cap = runtime.CaptureOutput.init(a);

    const inst = try makeInstance(a, "AtomicRef", Value.Null);

    const sentinel = try makeInstance(a, "Sentinel", .{ .Int = 1 });
    const other = try makeInstance(a, "Other", .{ .Int = 2 });

    // CAS Null -> sentinel succeeds.
    var cas_args = [_]Value{ .{ .Instance = inst }, Value.Null, .{ .Instance = sentinel } };
    var cas_ctx = makeCtx(a, &cas_args, &h, &cap);
    const cas = try atomicRefCas(&cas_ctx);
    try testing.expect(cas.ok.Bool == true);

    // CAS against a distinct instance fails (identity, not structural).
    var cas2_args = [_]Value{ .{ .Instance = inst }, .{ .Instance = other }, .{ .Instance = other } };
    var cas2_ctx = makeCtx(a, &cas2_args, &h, &cap);
    const cas2 = try atomicRefCas(&cas2_ctx);
    try testing.expect(cas2.ok.Bool == false);

    // getAndSet returns prior (sentinel) and stores `other`.
    var gs_args = [_]Value{ .{ .Instance = inst }, .{ .Instance = other } };
    var gs_ctx = makeCtx(a, &gs_args, &h, &cap);
    const gs = try atomicRefGetAndSet(&gs_ctx);
    try testing.expect(gs.ok == .Instance);
    try testing.expect(InstanceRef.ptrEq(gs.ok.Instance, sentinel));
}

test "missing receiver and bad args yield Type errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = runtime.NoopHost.init(a);
    var cap = runtime.CaptureOutput.init(a);

    var no_recv = [_]Value{.{ .Int = 1 }};
    var ctx = makeCtx(a, &no_recv, &h, &cap);
    const r = try atomicIntCas(&ctx);
    try testing.expect(r == .err and r.err == .Type);

    const inst = try makeInstance(a, "AtomicInt", .{ .Int = 0 });
    var bad_arg = [_]Value{ .{ .Instance = inst }, .{ .Bool = true }, .{ .Int = 1 } };
    var ctx2 = makeCtx(a, &bad_arg, &h, &cap);
    const r2 = try atomicIntCas(&ctx2);
    try testing.expect(r2 == .err and r2.err == .Type);
}
