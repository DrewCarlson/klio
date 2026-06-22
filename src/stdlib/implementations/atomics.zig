//! `kotlin.concurrent.atomics` read-modify-write bindings.
//!
//! KLIO runs real worker threads, so a composite atomic operation
//! (`compareAndSet`, `exchange`, `fetchAndAdd`, `addAndFetch`,
//! `compareAndExchange`) must observe its read, compute, and write-back as one
//! step. Each runs under a single exclusive borrow of the receiver's cell — the
//! same per-object writer lock `kotlinx.atomicfu` and `kotlin.synchronized`
//! use — so concurrent workers never interleave within an operation. `load` and
//! `store` stay as the class's plain field access: a single field read/write is
//! already atomic under the cell lock.
//!
//! The class shapes (the `value` cell and the `array` backing) come from the
//! wasm `actual` declarations; these bindings shadow the non-atomic method
//! bodies at dispatch time.

const std = @import("std");
const runtime = @import("runtime");

const Value = runtime.Value;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}
fn typeErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Type = msg } };
}

fn asI64(v: Value) ?i64 {
    return switch (v) {
        .Int => |x| @as(i64, x),
        .Long => |x| x,
        else => null,
    };
}

/// Compare for atomic compare-and-set: by value for the primitives a cell
/// holds, and (since the expected operand is the loaded reference itself)
/// structurally for boxed references.
fn atomicEq(a: Value, b: Value) bool {
    return Value.structuralEq(&a, &b);
}

// -------------------------------------------------------------------------
// Scalar cells (`value` field).
// -------------------------------------------------------------------------

const ScalarStep = struct { next: Value, out: Value };

fn withValueMut(
    ctx: *CallCtx,
    comptime Ctx: type,
    fctx: Ctx,
    f: *const fn (Ctx, Value) ScalarStep,
) EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .Instance) {
        return typeErr("atomic op requires a receiver");
    }
    const g = ctx.args[0].Instance.borrowMut();
    defer g.deinit();
    const cur = g.get().get("value") orelse return typeErr("atomic receiver missing `value`");
    const step = f(fctx, cur);
    // `out` escapes to the caller and `next` is stored; both need a reference
    // independent of the cell's. `cur` was borrowed from the cell.
    if (runtime.reclaimEnabled()) {
        step.out.retain();
        step.next.retain();
        cur.release(ctx.allocator);
    }
    g.get().define(ctx.allocator, "value", step.next) catch return typeErr("atomic store failed");
    return ok(step.out);
}

pub fn exchange(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return typeErr("exchange requires a value");
    const step = struct {
        fn run(n: Value, cur: Value) ScalarStep {
            return .{ .next = n, .out = cur };
        }
    }.run;
    return withValueMut(ctx, Value, ctx.args[1], step);
}

pub fn compareAndSet(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 3) return typeErr("compareAndSet requires expected + new");
    const Cap = struct { expected: Value, update: Value };
    const cap = Cap{ .expected = ctx.args[1], .update = ctx.args[2] };
    const step = struct {
        fn run(c: Cap, cur: Value) ScalarStep {
            if (atomicEq(cur, c.expected)) return .{ .next = c.update, .out = .{ .Bool = true } };
            return .{ .next = cur, .out = .{ .Bool = false } };
        }
    }.run;
    return withValueMut(ctx, Cap, cap, step);
}

pub fn compareAndExchange(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 3) return typeErr("compareAndExchange requires expected + new");
    const Cap = struct { expected: Value, update: Value };
    const cap = Cap{ .expected = ctx.args[1], .update = ctx.args[2] };
    const step = struct {
        fn run(c: Cap, cur: Value) ScalarStep {
            if (atomicEq(cur, c.expected)) return .{ .next = c.update, .out = cur };
            return .{ .next = cur, .out = cur };
        }
    }.run;
    return withValueMut(ctx, Cap, cap, step);
}

fn addStep(delta: i64, cur: Value, comptime fetch_first: bool) ScalarStep {
    const c = asI64(cur) orelse return .{ .next = cur, .out = cur };
    const sum = c +% delta;
    const nv: Value = switch (cur) {
        .Long => .{ .Long = sum },
        else => .{ .Int = @truncate(sum) },
    };
    const out: Value = if (fetch_first) cur else nv;
    return .{ .next = nv, .out = out };
}

pub fn fetchAndAdd(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const delta = if (ctx.args.len >= 2) asI64(ctx.args[1]) orelse 0 else 0;
    const step = struct {
        fn run(d: i64, cur: Value) ScalarStep {
            return addStep(d, cur, true);
        }
    }.run;
    return withValueMut(ctx, i64, delta, step);
}

pub fn addAndFetch(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const delta = if (ctx.args.len >= 2) asI64(ctx.args[1]) orelse 0 else 0;
    const step = struct {
        fn run(d: i64, cur: Value) ScalarStep {
            return addStep(d, cur, false);
        }
    }.run;
    return withValueMut(ctx, i64, delta, step);
}

// -------------------------------------------------------------------------
// Array cells (`array` field over an `ArrayData`).
// -------------------------------------------------------------------------

const ArrayStep = struct { next: Value, out: Value };

fn withArrayElemMut(
    ctx: *CallCtx,
    comptime Ctx: type,
    fctx: Ctx,
    f: *const fn (Ctx, Value) ArrayStep,
) EvalResult {
    if (ctx.args.len < 2 or ctx.args[0] != .Instance) {
        return typeErr("atomic array op requires a receiver + index");
    }
    const idx = asI64(ctx.args[1]) orelse return typeErr("atomic array index must be Int");
    // Hold the receiver's writer lock across the element read-modify-write so
    // the backing array cannot be observed mid-operation.
    const g = ctx.args[0].Instance.borrowMut();
    defer g.deinit();
    const arr_v = g.get().get("array") orelse return typeErr("atomic array missing `array`");
    if (arr_v != .Array) return typeErr("atomic array backing is not an array");
    const arr = arr_v.Array;
    if (idx < 0 or idx >= arr.len()) return typeErr("atomic array index out of bounds");
    const cur = arr.get(@intCast(idx));
    const step = f(fctx, cur);
    if (runtime.reclaimEnabled()) step.out.retain();
    arr.set(ctx.allocator, @intCast(idx), step.next);
    return ok(step.out);
}

pub fn exchangeAt(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 3) return typeErr("exchangeAt requires a value");
    const step = struct {
        fn run(n: Value, cur: Value) ArrayStep {
            return .{ .next = n, .out = cur };
        }
    }.run;
    return withArrayElemMut(ctx, Value, ctx.args[2], step);
}

pub fn compareAndSetAt(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 4) return typeErr("compareAndSetAt requires expected + new");
    const Cap = struct { expected: Value, update: Value };
    const cap = Cap{ .expected = ctx.args[2], .update = ctx.args[3] };
    const step = struct {
        fn run(c: Cap, cur: Value) ArrayStep {
            if (atomicEq(cur, c.expected)) return .{ .next = c.update, .out = .{ .Bool = true } };
            return .{ .next = cur, .out = .{ .Bool = false } };
        }
    }.run;
    return withArrayElemMut(ctx, Cap, cap, step);
}

pub fn compareAndExchangeAt(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 4) return typeErr("compareAndExchangeAt requires expected + new");
    const Cap = struct { expected: Value, update: Value };
    const cap = Cap{ .expected = ctx.args[2], .update = ctx.args[3] };
    const step = struct {
        fn run(c: Cap, cur: Value) ArrayStep {
            if (atomicEq(cur, c.expected)) return .{ .next = c.update, .out = cur };
            return .{ .next = cur, .out = cur };
        }
    }.run;
    return withArrayElemMut(ctx, Cap, cap, step);
}

pub fn fetchAndAddAt(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const delta = if (ctx.args.len >= 3) asI64(ctx.args[2]) orelse 0 else 0;
    const step = struct {
        fn run(d: i64, cur: Value) ArrayStep {
            const s = addStep(d, cur, true);
            return .{ .next = s.next, .out = s.out };
        }
    }.run;
    return withArrayElemMut(ctx, i64, delta, step);
}

pub fn addAndFetchAt(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const delta = if (ctx.args.len >= 3) asI64(ctx.args[2]) orelse 0 else 0;
    const step = struct {
        fn run(d: i64, cur: Value) ArrayStep {
            const s = addStep(d, cur, false);
            return .{ .next = s.next, .out = s.out };
        }
    }.run;
    return withArrayElemMut(ctx, i64, delta, step);
}
