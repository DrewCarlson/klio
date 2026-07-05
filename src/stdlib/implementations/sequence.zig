//! Sequence (lazy) stdlib intrinsics.
//!
//! Each intrinsic is a `fn(*CallCtx) !EvalResult`. The receiver, when
//! present, is `args[0]`. A `RuntimeError` surfaces as data through
//! `EvalResult.err`; OOM stays a Zig error.

const std = @import("std");
const runtime = @import("runtime");
const collections = @import("collections.zig");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const ObjRef = runtime.ObjRef;
const ValueBox = ObjRef(Value);
const ValueSlice = runtime.ValueSlice;
const ValueList = runtime.ValueList;
const SequenceData = runtime.SequenceData;
const SequenceSource = runtime.SequenceSource;
const SeqOp = runtime.SeqOp;
const IntrinsicHost = runtime.IntrinsicHost;
const Output = runtime.Output;
const InstanceData = runtime.InstanceData;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}
fn err(e: RuntimeError) EvalResult {
    return .{ .err = e };
}

/// `Result<[]Value, RuntimeError>` for the materialiser helpers: OOM stays
/// a Zig error, a `RuntimeError` rides back as data.
const Materialised = union(enum) {
    ok: []Value,
    err: RuntimeError,
};

// ============================================================
// Constructors / receiver helpers (mirror the `super::` imports)
// ============================================================

/// Build an items-only Sequence from an owned `[]Value`. Used by
/// `asSequence`, `sequenceOf`, and `emptySequence`.
fn makeSequence(allocator: std.mem.Allocator, items: []Value) std.mem.Allocator.Error!Value {
    const src = try ValueSlice.init(allocator, items);
    const data = try ObjRef(SequenceData).init(allocator, .{
        .source = .{ .Items = src },
        .ops = &.{},
    });
    return .{ .Sequence = data };
}

fn makeList(allocator: std.mem.Allocator, items: []Value, mutable: bool) std.mem.Allocator.Error!Value {
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(allocator, items);
    const ref = try ValueList.init(allocator, list);
    return .{ .List = .{ .items = ref, .mutable = mutable, .enum_entries = false, .backing = null } };
}

fn makeSet(allocator: std.mem.Allocator, items: []Value, mutable: bool) std.mem.Allocator.Error!Value {
    var deduped: std.ArrayList(Value) = .empty;
    for (items) |v| {
        var seen = false;
        for (deduped.items) |*x| {
            if (Value.structuralEqBoxed(x, &v)) {
                seen = true;
                break;
            }
        }
        if (!seen) try deduped.append(allocator, v);
    }
    const ref = try ValueList.init(allocator, deduped);
    return .{ .Set = .{ .items = ref, .mutable = mutable, .backing = null } };
}

fn recvListItems(args: []const Value, what: []const u8) union(enum) { items: ValueList, err: RuntimeError } {
    if (args.len > 0 and args[0] == .List) {
        return .{ .items = args[0].List.items.clone() };
    }
    return .{ .err = .{ .Type = typeMsg(what, "a List receiver") } };
}

fn recvSetItems(args: []const Value, what: []const u8) union(enum) { items: ValueList, err: RuntimeError } {
    if (args.len > 0 and args[0] == .Set) {
        return .{ .items = args[0].Set.items.clone() };
    }
    return .{ .err = .{ .Type = typeMsg(what, "a Set receiver") } };
}

fn recvString(args: []const Value, what: []const u8) union(enum) { s: Value, err: RuntimeError } {
    if (args.len > 0 and args[0] == .String) return .{ .s = args[0] };
    return .{ .err = .{ .Type = typeMsg(what, "a String receiver") } };
}

/// `"<what> requires <suffix>"`. The message is owned by a small static
/// table when possible; the dynamic forms used here are all comptime
/// concatenations at the call sites, so the slices live for the program.
fn typeMsg(comptime_what: []const u8, comptime_suffix: []const u8) []const u8 {
    _ = comptime_suffix;
    return comptime_what;
}

/// `range_iter_int`: collect the inclusive progression `start..end step` into
/// an owned `[]i64`. Empty when the step points away from `end`.
fn rangeIterInt(allocator: std.mem.Allocator, start: i64, end: i64, step: i64) std.mem.Allocator.Error![]i64 {
    var acc: std.ArrayList(i64) = .empty;
    if (step == 0) return acc.toOwnedSlice(allocator);
    if (step > 0) {
        if (start > end) return acc.toOwnedSlice(allocator);
        var cur = start;
        while (cur <= end) {
            try acc.append(allocator, cur);
            cur +|= step;
        }
    } else {
        if (start < end) return acc.toOwnedSlice(allocator);
        var cur = start;
        while (cur >= end) {
            try acc.append(allocator, cur);
            cur +|= step;
        }
    }
    return acc.toOwnedSlice(allocator);
}

// ============================================================
// Sequence builder (`sequence { yield(...) }`)
// ============================================================

const BuilderState = runtime.BuilderState;
const BuilderStateRef = runtime.BuilderStateRef;
const SeqIterState = runtime.SeqIterState;
const SeqIterStateRef = runtime.SeqIterStateRef;

// Scope-instance field names shared with the host builder driver
// (`coroutines.builderStep`).
const seq_has_value_field = "__seq_has_value";
const seq_value_field = "__seq_value";
const seq_yield_iter_field = "__seq_yield_iter";

/// Build the lazy `Builder`-source Sequence for `sequence { ... }` /
/// `iterator { ... }`. The `suspend SequenceScope<T>.() -> Unit` block is NOT
/// run here — the host drives it one `yield` at a time as the consumer pulls
/// (`builderStep`). The scope is a synthetic `SequenceScope` instance carrying
/// the pending yield value / yieldAll iterator between pulls.
fn makeBuilderSequence(ctx: *CallCtx) std.mem.Allocator.Error!union(enum) { seq: Value, err: RuntimeError } {
    if (ctx.args.len < 1) return .{ .err = .{ .Arity = "sequence builder expects a block" } };
    const block = ctx.args[0];
    const id = ctx.host.allocInstanceId();
    const fields = [_]InstanceData.Field{
        .{ .name = seq_has_value_field, .value = .{ .Bool = false } },
        .{ .name = seq_value_field, .value = .Unit },
        .{ .name = seq_yield_iter_field, .value = .Null },
    };
    const scope = try ctx.host.newSynthInstance("kotlin.sequences.SequenceScope", id, &fields);
    if (runtime.reclaimEnabled()) block.retain();
    const block_box = try Value.boxRef(ctx.allocator, block);
    if (runtime.reclaimEnabled()) scope.retain();
    const scope_box = try Value.boxRef(ctx.allocator, scope);
    const state = try BuilderStateRef.init(ctx.allocator, .{
        .block = block_box,
        .scope = scope_box,
    });
    const data = try ObjRef(SequenceData).init(ctx.allocator, .{
        .source = .{ .Builder = state },
        .ops = &.{},
    });
    return .{ .seq = .{ .Sequence = data } };
}

pub fn seq_builder(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return switch (try makeBuilderSequence(ctx)) {
        .seq => |s| ok(s),
        .err => |e| err(e),
    };
}

pub fn seq_iterator_builder(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const seq = switch (try makeBuilderSequence(ctx)) {
        .seq => |s| s,
        .err => |e| return err(e),
    };
    return ok(try makeSeqIter(ctx.allocator, seq));
}

/// A lazy `SeqIter` over `seq` (the `Sequence.iterator()` / `iterator{}`
/// result). Adopts one owned reference to `seq`.
pub fn makeSeqIter(allocator: std.mem.Allocator, seq: Value) std.mem.Allocator.Error!Value {
    const state = try SeqIterStateRef.init(allocator, .{ .seq = seq });
    return .{ .SeqIter = state };
}

/// `SequenceScope.yield(value)` — stash the value on the scope and suspend the
/// builder coroutine. The host's `builderStep` reads the value and resumes the
/// block on the next pull.
pub fn seq_scope_yield(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .Instance) return err(.{ .Type = "yield: not a SequenceScope" });
    const g = ctx.args[0].Instance.borrowMut();
    const inst = g.get();
    const v = if (ctx.args.len > 1) ctx.args[1] else Value.Unit;
    if (runtime.reclaimEnabled()) v.retain();
    try inst.define(ctx.allocator, seq_value_field, v);
    _ = inst.set(seq_has_value_field, .{ .Bool = true });
    g.deinit();
    return err(.{ .Suspend = -1 });
}

/// `SequenceScope.yieldAll(iterator/iterable/sequence)` — stash an Iterator on
/// the scope and suspend; the host drains it lazily before resuming the block.
pub fn seq_scope_yield_all(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .Instance) return err(.{ .Type = "yieldAll: not a SequenceScope" });
    if (ctx.args.len <= 1) return ok(.Unit);
    const arg = ctx.args[1];
    // Obtain a fresh Iterator over the argument so the host can pull lazily.
    var iter: Value = undefined;
    switch (arg) {
        .Iterator, .RangeIter, .SeqIter => iter = arg,
        .List, .Set, .Array, .Sequence, .Map, .String, .Range => {
            const r = (try ctx.host.invokeMethod(&arg, "iterator", &.{}, ctx.out)) orelse
                return err(.{ .Type = "yieldAll: argument is not iterable" });
            switch (r) {
                .ok => |it| iter = it,
                .err => |e| return err(e),
            }
        },
        .Instance => {
            const r = (try ctx.host.invokeMethod(&arg, "iterator", &.{}, ctx.out)) orelse
                return err(.{ .Type = "yieldAll: argument is not iterable" });
            switch (r) {
                .ok => |it| iter = it,
                .err => |e| return err(e),
            }
        },
        else => return err(.{ .Type = "yieldAll: expected an Iterable/Iterator/Sequence" }),
    }
    {
        const g = ctx.args[0].Instance.borrowMut();
        defer g.deinit();
        if (runtime.reclaimEnabled()) iter.retain();
        try g.get().define(ctx.allocator, seq_yield_iter_field, iter);
    }
    return err(.{ .Suspend = -1 });
}

// ============================================================
// asSequence / sequenceOf / emptySequence / generateSequence
// ============================================================

pub fn seq_from_list(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = recvListItems(ctx.args, "asSequence");
    const items_ref = switch (r) {
        .items => |it| it,
        .err => |e| return err(e),
    };
    const items = try cloneItems(ctx.allocator, items_ref);
    return ok(try makeSequence(ctx.allocator, items));
}

pub fn seq_from_set(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = recvSetItems(ctx.args, "asSequence");
    const items_ref = switch (r) {
        .items => |it| it,
        .err => |e| return err(e),
    };
    const items = try cloneItems(ctx.allocator, items_ref);
    return ok(try makeSequence(ctx.allocator, items));
}

pub fn seq_from_string(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = recvString(ctx.args, "asSequence");
    const sval = switch (r) {
        .s => |s| s,
        .err => |e| return err(e),
    };
    const sg = sval.String.borrow();
    defer sg.deinit();
    const bytes = sg.get().bytes;
    var chars: std.ArrayList(Value) = .empty;
    var view = std.unicode.Utf8View.initUnchecked(bytes);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0xFFFF) {
            try chars.append(ctx.allocator, .{ .Char = @intCast(cp) });
        } else {
            const c = cp - 0x10000;
            const hi: u16 = @intCast(0xD800 + (c >> 10));
            const lo: u16 = @intCast(0xDC00 + (c & 0x3FF));
            try chars.append(ctx.allocator, .{ .Char = hi });
            try chars.append(ctx.allocator, .{ .Char = lo });
        }
    }
    return ok(try makeSequence(ctx.allocator, try chars.toOwnedSlice(ctx.allocator)));
}

pub fn seq_from_range(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .Range) {
        return err(.{ .Type = "asSequence requires an IntRange" });
    }
    const r = ctx.args[0].Range;
    const ints = try rangeIterInt(ctx.allocator, r.start, r.end, r.step);
    defer ctx.allocator.free(ints);
    var items = try ctx.allocator.alloc(Value, ints.len);
    for (ints, 0..) |n, i| items[i] = Value.newInt(n);
    return ok(try makeSequence(ctx.allocator, items));
}

pub fn seq_of(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const items = try ctx.allocator.dupe(Value, ctx.args);
    return ok(try makeSequence(ctx.allocator, items));
}

pub fn seq_empty(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const items = try ctx.allocator.alloc(Value, 0);
    return ok(try makeSequence(ctx.allocator, items));
}

/// `Sequence { () -> Iterator<T> }` — the SAM factory. Lazy and
/// re-iterable: each iteration invokes the factory for a fresh Iterator.
pub fn seq_from_iterator_fn(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const args = ctx.args;
    // The factory lambda is the last callable argument (a receiver may be
    // prepended by the member walk).
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        if (isLambdaLike(args[i])) {
            args[i].retain();
            const f = try Value.boxRef(ctx.allocator, args[i]);
            const data = try ObjRef(SequenceData).init(ctx.allocator, .{
                .source = .{ .IteratorFn = f },
                .ops = &.{},
            });
            return ok(.{ .Sequence = data });
        }
    }
    return err(.{ .Type = "Sequence factory expects an iterator-producing function" });
}

pub fn seq_generate_sequence(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const args = ctx.args;
    if (args.len == 1 and isLambdaLike(args[0])) {
        args[0].retain();
        const next = try Value.boxRef(ctx.allocator, args[0]);
        const data = try ObjRef(SequenceData).init(ctx.allocator, .{
            .source = .{ .Generate = .{ .seed = null, .next = next } },
            .ops = &.{},
            // The nullary form is stateful: the source constrains it to
            // one consumption.
            .one_shot = true,
        });
        return ok(.{ .Sequence = data });
    }
    if (args.len == 2 and isLambdaLike(args[1])) {
        var seed: ?ValueBox = null;
        // `generateSequence(seedFunction, nextFunction)`: the seed is a
        // producer invoked at each iteration start.
        const seed_is_fn = isLambdaLike(args[0]);
        if (args[0] != .Null) {
            args[0].retain();
            seed = try Value.boxRef(ctx.allocator, args[0]);
        }
        args[1].retain();
        const next = try Value.boxRef(ctx.allocator, args[1]);
        const data = try ObjRef(SequenceData).init(ctx.allocator, .{
            .source = .{ .Generate = .{ .seed = seed, .next = next, .seed_is_fn = seed_is_fn } },
            .ops = &.{},
        });
        return ok(.{ .Sequence = data });
    }
    return err(.{ .Type = "generateSequence expects `(seed, next)` or `(next)` with `next` a lambda" });
}

fn isLambdaLike(v: Value) bool {
    return v == .IrClosure;
}

// ============================================================
// Eager fast-path terminals
// ============================================================

const EagerResult = union(enum) {
    /// `Items`-source Sequence with no ops: the frozen elements.
    some: ValueSlice,
    /// Has ops or a non-trivial source — caller routes through the lazy path.
    none,
    err: RuntimeError,
};

/// Fast-path Sequence terminal ops handle the special case of an
/// `Items`-source Sequence with no ops. Anything more (intermediate ops,
/// generator sources) goes through the lazy materialize path.
fn recvSeqEager(args: []const Value, what: []const u8) EagerResult {
    if (args.len < 1 or args[0] != .Sequence) {
        _ = what;
        return .{ .err = .{ .Type = "Sequence terminal requires a Sequence receiver" } };
    }
    const g = args[0].Sequence.borrow();
    defer g.deinit();
    const data = g.get();
    if (data.ops.len != 0) return .none;
    return switch (data.source) {
        .Items => |items| .{ .some = items.clone() },
        .Generate, .Builder, .IteratorFn => .none,
    };
}

pub fn seq_to_list(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    switch (recvSeqEager(ctx.args, "Sequence.toList")) {
        .some => |items| {
            const xs = try cloneSlice(ctx.allocator, items);
            return ok(try makeList(ctx.allocator, xs, false));
        },
        .none => return err(.{ .Unimplemented = "Sequence.toList on a non-trivial source/op chain (dispatch via the interpreter)" }),
        .err => |e| return err(e),
    }
}

pub fn seq_to_mutable_list(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    switch (recvSeqEager(ctx.args, "Sequence.toMutableList")) {
        .some => |items| {
            const xs = try cloneSlice(ctx.allocator, items);
            return ok(try makeList(ctx.allocator, xs, true));
        },
        .none => return err(.{ .Unimplemented = "Sequence.toMutableList on a non-trivial source/op chain" }),
        .err => |e| return err(e),
    }
}

pub fn seq_to_set(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    switch (recvSeqEager(ctx.args, "Sequence.toSet")) {
        .some => |items| {
            const xs = try cloneSlice(ctx.allocator, items);
            return ok(try makeSet(ctx.allocator, xs, false));
        },
        .none => return err(.{ .Unimplemented = "Sequence.toSet on a non-trivial source/op chain" }),
        .err => |e| return err(e),
    }
}

pub fn seq_count_no_pred(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    switch (recvSeqEager(ctx.args, "Sequence.count")) {
        .some => |items| {
            const g = items.borrow();
            defer g.deinit();
            return ok(Value.newInt(@intCast(g.get().len)));
        },
        .none => return err(.{ .Unimplemented = "Sequence.count on a non-trivial source/op chain" }),
        .err => |e| return err(e),
    }
}

pub fn seq_last(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    switch (recvSeqEager(ctx.args, "Sequence.last")) {
        .some => |items| {
            const g = items.borrow();
            defer g.deinit();
            const xs = g.get().*;
            if (xs.len == 0) return err(try noSuchElement(ctx.allocator, "Sequence is empty."));
            return ok(xs[xs.len - 1]);
        },
        .none => return err(.{ .Unimplemented = "Sequence.last on a non-trivial source/op chain" }),
        .err => |e| return err(e),
    }
}

// ============================================================
// Short-circuiting predicate terminals
// ============================================================

/// Append one more op to a Sequence, returning a new lazy Sequence value.
fn seqWithExtraOp(allocator: std.mem.Allocator, seq_val: Value, op: SeqOp) std.mem.Allocator.Error!Value {
    if (seq_val != .Sequence) return seq_val;
    const g = seq_val.Sequence.borrow();
    defer g.deinit();
    const d = g.get();
    var ops = try allocator.alloc(SeqOp, d.ops.len + 1);
    @memcpy(ops[0..d.ops.len], d.ops);
    ops[d.ops.len] = op;
    const data = try ObjRef(SequenceData).init(allocator, .{
        .source = d.source,
        .ops = ops,
    });
    return .{ .Sequence = data };
}

const FilterTarget = union(enum) {
    seq: Value,
    err: RuntimeError,
};

/// The receiver Sequence, with a trailing `Filter(predicate)` op when the
/// call supplies one (the `first { p }` / `find { p }` / `any { p }` shape).
fn seqWithOptionalFilter(ctx: *CallCtx, who: []const u8) std.mem.Allocator.Error!FilterTarget {
    if (ctx.args.len < 1 or ctx.args[0] != .Sequence) {
        _ = who;
        return .{ .err = .{ .Type = "Sequence predicate terminal requires a Sequence receiver" } };
    }
    const seq = ctx.args[0];
    if (ctx.args.len > 1) {
        return .{ .seq = try seqWithExtraOp(ctx.allocator, seq, .{ .Filter = ctx.args[1] }) };
    }
    return .{ .seq = seq };
}

pub fn seq_first(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const t = switch (try seqWithOptionalFilter(ctx, "Sequence.first")) {
        .seq => |s| s,
        .err => |e| return err(e),
    };
    const m = try materialiseSequenceBounded(ctx.allocator, ctx.host, ctx.out, &t, 1);
    const items = switch (m) {
        .ok => |xs| xs,
        .err => |e| return err(e),
    };
    defer ctx.allocator.free(items);
    if (items.len == 0) {
        return err(try noSuchElement(ctx.allocator, "Sequence contains no element matching the predicate."));
    }
    return ok(items[0]);
}

pub fn seq_first_or_null(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const t = switch (try seqWithOptionalFilter(ctx, "Sequence.firstOrNull")) {
        .seq => |s| s,
        .err => |e| return err(e),
    };
    const m = try materialiseSequenceBounded(ctx.allocator, ctx.host, ctx.out, &t, 1);
    const items = switch (m) {
        .ok => |xs| xs,
        .err => |e| return err(e),
    };
    defer ctx.allocator.free(items);
    if (items.len == 0) return ok(.Null);
    return ok(items[0]);
}

pub fn seq_any(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const t = switch (try seqWithOptionalFilter(ctx, "Sequence.any")) {
        .seq => |s| s,
        .err => |e| return err(e),
    };
    const m = try materialiseSequenceBounded(ctx.allocator, ctx.host, ctx.out, &t, 1);
    const items = switch (m) {
        .ok => |xs| xs,
        .err => |e| return err(e),
    };
    defer ctx.allocator.free(items);
    return ok(.{ .Bool = items.len != 0 });
}

pub fn seq_none(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const t = switch (try seqWithOptionalFilter(ctx, "Sequence.none")) {
        .seq => |s| s,
        .err => |e| return err(e),
    };
    const m = try materialiseSequenceBounded(ctx.allocator, ctx.host, ctx.out, &t, 1);
    const items = switch (m) {
        .ok => |xs| xs,
        .err => |e| return err(e),
    };
    defer ctx.allocator.free(items);
    return ok(.{ .Bool = items.len == 0 });
}

pub fn seq_to_string(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    // Kotlin returns an opaque id like `kotlin.sequences.TransformingSequence@…`.
    // Stable parity for that string is meaningless (it embeds the heap
    // address), so we emit a deterministic placeholder. Programs that need a
    // useful value should call `.toList()` before printing.
    const s = try runtime.strInit(ctx.allocator, "kotlin.sequences.Sequence");
    return ok(.{ .String = s });
}

// ============================================================
// Map.Entry members
// ============================================================

pub fn map_entry_key(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .MapEntry) {
        return err(.{ .Type = "Map.Entry.key requires a Map.Entry receiver" });
    }
    const out = ctx.args[0].MapEntry.key.asPtr().*;
    out.retain();
    return ok(out);
}

pub fn map_entry_value(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .MapEntry) {
        return err(.{ .Type = "Map.Entry.value requires a Map.Entry receiver" });
    }
    const out = ctx.args[0].MapEntry.value.asPtr().*;
    out.retain();
    return ok(out);
}

pub fn map_entry_to_string(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .MapEntry) {
        return err(.{ .Type = "Map.Entry.toString requires a Map.Entry receiver" });
    }
    const s = try ctx.args[0].display(ctx.allocator);
    const ref = try runtime.strInitOwned(ctx.allocator, s);
    return ok(.{ .String = ref });
}

// ============================================================
// Lazy materialiser (faithful port of the `super::` driver)
// ============================================================

fn materialiseSequence(
    allocator: std.mem.Allocator,
    host: IntrinsicHost,
    out: Output,
    seq_val: *const Value,
) std.mem.Allocator.Error!Materialised {
    return materialiseSequenceBounded(allocator, host, out, seq_val, null);
}

/// Materialize a Sequence, optionally stopping once `max` items have been
/// produced. The bound makes short-circuiting terminals (`first`, `find`,
/// `any`, `take(n).toList()`) pull only as far as needed instead of running
/// the whole (possibly infinite) source. The bound applies on the streaming
/// fast path; ops that must buffer (sort, flatMap, distinct) fall back to
/// full materialization, as in Kotlin.
fn materialiseSequenceBounded(
    allocator: std.mem.Allocator,
    host: IntrinsicHost,
    out: Output,
    seq_val: *const Value,
    max: ?usize,
) std.mem.Allocator.Error!Materialised {
    if (seq_val.* != .Sequence) {
        return .{ .err = .{ .Type = "materialise_sequence: not a Sequence" } };
    }
    if (try collections.oneShotConsumeCheck(allocator, seq_val.*)) |e| return .{ .err = e };
    const sg = seq_val.Sequence.borrow();
    defer sg.deinit();
    const seq = sg.get();

    const all_streaming = blk: {
        for (seq.ops) |op| {
            switch (op) {
                .Map, .Filter, .FilterNot, .Take, .Drop, .TakeWhile, .DropWhile, .OnEach, .MapIndexed, .FilterIndexed => {},
                else => break :blk false,
            }
        }
        break :blk true;
    };

    if (all_streaming) {
        const n_ops = seq.ops.len;
        var st = try StreamState.init(allocator, n_ops);
        defer st.deinit(allocator);
        var output: std.ArrayList(Value) = .empty;

        switch (seq.source) {
            .Items => |v| {
                const g = v.borrow();
                defer g.deinit();
                for (g.get().*) |item| {
                    if (takeCapReached(seq.ops, st.taken)) break;
                    const pr = try pump(allocator, host, out, item, seq.ops, &st, &output);
                    switch (pr) {
                        .cont => |c| if (!c) break,
                        .err => |e| {
                            output.deinit(allocator);
                            return .{ .err = e };
                        },
                    }
                    if (max) |m| if (output.items.len >= m) break;
                }
            },
            .Builder => |bstate0| {
                // Drive a FRESH cursor so this materialisation is independent of
                // any other consumption of the same (re-iterable) Sequence.
                const bstate = try collections.freshBuilderState(host, allocator, bstate0);
                while (true) {
                    if (takeCapReached(seq.ops, st.taken)) break;
                    const step = try host.builderStep(bstate, out);
                    const item = switch (step) {
                        .value => |v| v,
                        .done => break,
                        .err => |e| {
                            output.deinit(allocator);
                            return .{ .err = e };
                        },
                    };
                    const pr = try pump(allocator, host, out, item, seq.ops, &st, &output);
                    switch (pr) {
                        .cont => |c| if (!c) break,
                        .err => |e| {
                            output.deinit(allocator);
                            return .{ .err = e };
                        },
                    }
                    if (max) |m| if (output.items.len >= m) break;
                }
            },
            .Generate => |gen| {
                var cur: ?Value = if (gen.seed) |s| blk: {
                    const sv = s.asPtr().*;
                    if (gen.seed_is_fn) {
                        const r = try invokeCallable(host, &sv, &.{}, out);
                        switch (r) {
                            .ok => |rv| {
                                if (rv == .Null) break :blk null;
                                break :blk rv;
                            },
                            .err => |e| {
                                output.deinit(allocator);
                                return .{ .err = e };
                            },
                        }
                    }
                    sv.retain();
                    break :blk sv;
                } else null;
                const limit: usize = 1_000_000;
                var produced: usize = 0;
                while (true) {
                    if (takeCapReached(seq.ops, st.taken)) break;
                    var candidate: Value = undefined;
                    if (cur) |v| {
                        candidate = v;
                    } else {
                        const r = try invokeCallable(host, gen.next.asPtr(), &.{}, out);
                        switch (r) {
                            .ok => |rv| {
                                if (rv == .Null) break;
                                candidate = rv;
                            },
                            .err => |e| {
                                output.deinit(allocator);
                                return .{ .err = e };
                            },
                        }
                    }
                    produced += 1;
                    if (produced > limit) {
                        output.deinit(allocator);
                        return .{ .err = .{ .Type = "Sequence: generator exceeded 1,000,000 items" } };
                    }
                    const pr = try pump(allocator, host, out, candidate, seq.ops, &st, &output);
                    switch (pr) {
                        .cont => |c| if (!c) break,
                        .err => |e| {
                            output.deinit(allocator);
                            return .{ .err = e };
                        },
                    }
                    if (max) |m| if (output.items.len >= m) break;
                    const nr = try invokeCallable(host, gen.next.asPtr(), &.{candidate}, out);
                    switch (nr) {
                        .ok => |nv| {
                            if (nv == .Null) break;
                            cur = nv;
                        },
                        .err => |e| {
                            output.deinit(allocator);
                            return .{ .err = e };
                        },
                    }
                }
            },
            .IteratorFn => |fnbox| {
                const ir = try invokeCallable(host, fnbox.asPtr(), &.{}, out);
                const iter = switch (ir) {
                    .ok => |v| v,
                    .err => |e| {
                        output.deinit(allocator);
                        return .{ .err = e };
                    },
                };
                while (true) {
                    if (takeCapReached(seq.ops, st.taken)) break;
                    const hn = (try host.invokeMethod(&iter, "hasNext", &.{}, out)) orelse
                        return .{ .err = .{ .Type = "Sequence: iterator lacks hasNext" } };
                    const has = switch (hn) {
                        .ok => |x| x == .Bool and x.Bool,
                        .err => |e| {
                            output.deinit(allocator);
                            return .{ .err = e };
                        },
                    };
                    if (!has) break;
                    const nx = (try host.invokeMethod(&iter, "next", &.{}, out)) orelse
                        return .{ .err = .{ .Type = "Sequence: iterator lacks next" } };
                    const item = switch (nx) {
                        .ok => |x| x,
                        .err => |e| {
                            output.deinit(allocator);
                            return .{ .err = e };
                        },
                    };
                    const pr = try pump(allocator, host, out, item, seq.ops, &st, &output);
                    switch (pr) {
                        .cont => |c| if (!c) break,
                        .err => |e| {
                            output.deinit(allocator);
                            return .{ .err = e };
                        },
                    }
                    if (max) |m| if (output.items.len >= m) break;
                }
            },
        }
        return .{ .ok = try output.toOwnedSlice(allocator) };
    }

    // Buffered path: materialize the source fully, then apply each op.
    var items: std.ArrayList(Value) = .empty;
    switch (seq.source) {
        .Items => |v| {
            const g = v.borrow();
            defer g.deinit();
            try items.appendSlice(allocator, g.get().*);
        },
        .Builder => |bstate0| {
            const bstate = try collections.freshBuilderState(host, allocator, bstate0);
            while (true) {
                const step = try host.builderStep(bstate, out);
                switch (step) {
                    .value => |v| try items.append(allocator, v),
                    .done => break,
                    .err => |e| {
                        items.deinit(allocator);
                        return .{ .err = e };
                    },
                }
            }
        },
        .Generate => |gen| {
            const limit: usize = 1024;
            var cur: ?Value = if (gen.seed) |s| blk: {
                const sv = s.asPtr().*;
                if (gen.seed_is_fn) {
                    const r = try invokeCallable(host, &sv, &.{}, out);
                    switch (r) {
                        .ok => |rv| {
                            if (rv == .Null) break :blk null;
                            break :blk rv;
                        },
                        .err => |e| {
                            items.deinit(allocator);
                            return .{ .err = e };
                        },
                    }
                }
                sv.retain();
                break :blk sv;
            } else null;
            while (items.items.len < limit) {
                var candidate: Value = undefined;
                if (cur) |v| {
                    candidate = v;
                } else {
                    const r = try invokeCallable(host, gen.next.asPtr(), &.{}, out);
                    switch (r) {
                        .ok => |rv| {
                            if (rv == .Null) break;
                            candidate = rv;
                        },
                        .err => |e| {
                            items.deinit(allocator);
                            return .{ .err = e };
                        },
                    }
                }
                try items.append(allocator, candidate);
                const nr = try invokeCallable(host, gen.next.asPtr(), &.{candidate}, out);
                switch (nr) {
                    .ok => |nv| {
                        if (nv == .Null) break;
                        cur = nv;
                    },
                    .err => |e| {
                        items.deinit(allocator);
                        return .{ .err = e };
                    },
                }
            }
        },
        .IteratorFn => |fnbox| {
            const ir = try invokeCallable(host, fnbox.asPtr(), &.{}, out);
            const iter = switch (ir) {
                .ok => |v| v,
                .err => |e| {
                    items.deinit(allocator);
                    return .{ .err = e };
                },
            };
            while (true) {
                const hn = (try host.invokeMethod(&iter, "hasNext", &.{}, out)) orelse
                    return .{ .err = .{ .Type = "Sequence: iterator lacks hasNext" } };
                const has = switch (hn) {
                    .ok => |x| x == .Bool and x.Bool,
                    .err => |e| {
                        items.deinit(allocator);
                        return .{ .err = e };
                    },
                };
                if (!has) break;
                const nx = (try host.invokeMethod(&iter, "next", &.{}, out)) orelse
                    return .{ .err = .{ .Type = "Sequence: iterator lacks next" } };
                switch (nx) {
                    .ok => |item| try items.append(allocator, item),
                    .err => |e| {
                        items.deinit(allocator);
                        return .{ .err = e };
                    },
                }
            }
        },
    }

    for (seq.ops) |op| {
        const stepped = try applyBufferedOp(allocator, host, out, &items, op);
        if (stepped) |e| {
            items.deinit(allocator);
            return .{ .err = e };
        }
    }
    return .{ .ok = try items.toOwnedSlice(allocator) };
}

/// Apply one buffered op in place. Returns a `RuntimeError` on failure.
/// Outcome of expanding a `flatMap` transform result.
const FlatMapOutcome = union(enum) { expanded: void, single: void, err: RuntimeError };

/// Flatten a `flatMap` transform result that is neither a List/Set/Sequence
/// (handled inline by the caller). Built-in iterable shapes (Array, Range,
/// Map) expand directly through the shared `iterableItems` extractor; any
/// other value (a user `Instance` that is `Iterable`) drains through the host
/// `iterator()`/`hasNext()`/`next()` protocol. Returns `.single` when the
/// value is not iterable, so the caller appends it as one element.
fn flatMapExpand(
    allocator: std.mem.Allocator,
    host: IntrinsicHost,
    out: Output,
    mapped: Value,
    nx: *std.ArrayList(Value),
) std.mem.Allocator.Error!FlatMapOutcome {
    var ctx = runtime.CallCtx{ .args = &.{}, .out = out, .host = host, .allocator = allocator };
    switch (try collections.iterableItemsCtx(&ctx, mapped, "flatMap")) {
        .items => |items| {
            try nx.appendSlice(allocator, items);
            if (runtime.freeScratch()) allocator.free(items);
            return .expanded;
        },
        .err => return .single,
    }
}

fn applyBufferedOp(
    allocator: std.mem.Allocator,
    host: IntrinsicHost,
    out: Output,
    items: *std.ArrayList(Value),
    op: SeqOp,
) std.mem.Allocator.Error!?RuntimeError {
    switch (op) {
        .Map => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items.items) |v| {
                const r = try invokeCallable(host, &f, &.{v}, out);
                switch (r) {
                    .ok => |rv| try nx.append(allocator, rv),
                    .err => |e| {
                        nx.deinit(allocator);
                        return e;
                    },
                }
            }
            items.deinit(allocator);
            items.* = nx;
        },
        .OnEach => |f| {
            for (items.items) |v| {
                const r = try invokeCallable(host, &f, &.{v}, out);
                if (r == .err) return r.err;
            }
        },
        .MapIndexed => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items.items, 0..) |v, i| {
                const r = try invokeCallable(host, &f, &.{ Value.newInt(@intCast(i)), v }, out);
                switch (r) {
                    .ok => |rv| try nx.append(allocator, rv),
                    .err => |e| {
                        nx.deinit(allocator);
                        return e;
                    },
                }
            }
            items.deinit(allocator);
            items.* = nx;
        },
        .FilterIndexed => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items.items, 0..) |v, i| {
                const r = try invokeCallable(host, &f, &.{ Value.newInt(@intCast(i)), v }, out);
                switch (r) {
                    .ok => |rv| if (isTrue(rv)) try nx.append(allocator, v),
                    .err => |e| {
                        nx.deinit(allocator);
                        return e;
                    },
                }
            }
            items.deinit(allocator);
            items.* = nx;
        },
        .Filter => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items.items) |v| {
                const r = try invokeCallable(host, &f, &.{v}, out);
                switch (r) {
                    .ok => |rv| if (isTrue(rv)) try nx.append(allocator, v),
                    .err => |e| {
                        nx.deinit(allocator);
                        return e;
                    },
                }
            }
            items.deinit(allocator);
            items.* = nx;
        },
        .FilterNot => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items.items) |v| {
                const r = try invokeCallable(host, &f, &.{v}, out);
                switch (r) {
                    .ok => |rv| if (!isTrue(rv)) try nx.append(allocator, v),
                    .err => |e| {
                        nx.deinit(allocator);
                        return e;
                    },
                }
            }
            items.deinit(allocator);
            items.* = nx;
        },
        .Take => |n| {
            const cap: usize = if (n < 0) 0 else @intCast(n);
            if (cap < items.items.len) items.shrinkRetainingCapacity(cap);
        },
        .Drop => |n| {
            const d: usize = @min(if (n < 0) 0 else @as(usize, @intCast(n)), items.items.len);
            drainFront(allocator, items, d);
        },
        .TakeWhile => |f| {
            var cutoff: usize = items.items.len;
            for (items.items, 0..) |v, i| {
                const r = try invokeCallable(host, &f, &.{v}, out);
                switch (r) {
                    .ok => |rv| if (!isTrue(rv)) {
                        cutoff = i;
                        break;
                    },
                    .err => |e| return e,
                }
            }
            if (cutoff < items.items.len) items.shrinkRetainingCapacity(cutoff);
        },
        .DropWhile => |f| {
            var start: usize = 0;
            while (start < items.items.len) {
                const v = items.items[start];
                const r = try invokeCallable(host, &f, &.{v}, out);
                switch (r) {
                    .ok => |rv| if (!isTrue(rv)) break,
                    .err => |e| return e,
                }
                start += 1;
            }
            drainFront(allocator, items, start);
        },
        .FlatMap => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items.items) |v| {
                const r = try invokeCallable(host, &f, &.{v}, out);
                const mapped = switch (r) {
                    .ok => |rv| rv,
                    .err => |e| {
                        nx.deinit(allocator);
                        return e;
                    },
                };
                switch (mapped) {
                    .List => |xs| {
                        const g = xs.items.borrow();
                        defer g.deinit();
                        try nx.appendSlice(allocator, g.get().items);
                    },
                    .Set => |xs| {
                        const g = xs.items.borrow();
                        defer g.deinit();
                        try nx.appendSlice(allocator, g.get().items);
                    },
                    .Sequence => {
                        const m = try materialiseSequence(allocator, host, out, &mapped);
                        switch (m) {
                            .ok => |sub| {
                                try nx.appendSlice(allocator, sub);
                                allocator.free(sub);
                            },
                            .err => |e| {
                                nx.deinit(allocator);
                                return e;
                            },
                        }
                    },
                    else => switch (try flatMapExpand(allocator, host, out, mapped, &nx)) {
                        .expanded => {},
                        .single => try nx.append(allocator, mapped),
                        .err => |e| {
                            nx.deinit(allocator);
                            return e;
                        },
                    },
                }
            }
            items.deinit(allocator);
            items.* = nx;
        },
        .Distinct => {
            var seen: std.ArrayList(Value) = .empty;
            defer seen.deinit(allocator);
            var nx: std.ArrayList(Value) = .empty;
            for (items.items) |v| {
                if (!containsEq(seen.items, &v)) {
                    try seen.append(allocator, v);
                    try nx.append(allocator, v);
                }
            }
            items.deinit(allocator);
            items.* = nx;
        },
        .DistinctBy => |f| {
            var seen: std.ArrayList(Value) = .empty;
            defer seen.deinit(allocator);
            var nx: std.ArrayList(Value) = .empty;
            for (items.items) |v| {
                const r = try invokeCallable(host, &f, &.{v}, out);
                const key = switch (r) {
                    .ok => |rv| rv,
                    .err => |e| {
                        nx.deinit(allocator);
                        return e;
                    },
                };
                if (!containsEq(seen.items, &key)) {
                    try seen.append(allocator, key);
                    try nx.append(allocator, v);
                }
            }
            items.deinit(allocator);
            items.* = nx;
        },
        .Sorted => |descending| {
            if (sortNatural(items.items, descending)) |e| return e;
        },
        .SortedBy => |sb| {
            var keyed = try allocator.alloc(Value, items.items.len);
            defer allocator.free(keyed);
            for (items.items, 0..) |v, i| {
                const r = try invokeCallable(host, &sb.selector, &.{v}, out);
                switch (r) {
                    .ok => |k| keyed[i] = k,
                    .err => |e| return e,
                }
            }
            if (sortByKey(items.items, keyed, sb.descending)) |e| return e;
        },
        .SortedWith => |comparator| {
            // Insertion sort so the comparator callback can dispatch back
            // through the host.
            var i: usize = 1;
            while (i < items.items.len) : (i += 1) {
                var j = i;
                while (j > 0) {
                    const a = items.items[j - 1];
                    const b = items.items[j];
                    const mr = try host.invokeMethod(&comparator, "compare", &.{ a, b }, out);
                    if (mr) |res| {
                        switch (res) {
                            .ok => |v| {
                                const n = v.asI64() orelse 0;
                                if (n > 0) {
                                    std.mem.swap(Value, &items.items[j - 1], &items.items[j]);
                                    j -= 1;
                                } else break;
                            },
                            .err => |e| return e,
                        }
                    } else {
                        return .{ .Type = "SortedWith: comparator has no `compare` method" };
                    }
                }
            }
        },
    }
    return null;
}

// ----- streaming pump state -----

const StreamState = struct {
    taken: []usize,
    dropped: []usize,
    take_while_live: []bool,
    drop_while_live: []bool,
    indices: []usize,

    fn init(allocator: std.mem.Allocator, n: usize) std.mem.Allocator.Error!StreamState {
        const taken = try allocator.alloc(usize, n);
        const dropped = try allocator.alloc(usize, n);
        const tw = try allocator.alloc(bool, n);
        const dw = try allocator.alloc(bool, n);
        const idx = try allocator.alloc(usize, n);
        @memset(taken, 0);
        @memset(dropped, 0);
        @memset(tw, true);
        @memset(dw, true);
        @memset(idx, 0);
        return .{ .taken = taken, .dropped = dropped, .take_while_live = tw, .drop_while_live = dw, .indices = idx };
    }

    fn deinit(self: *StreamState, allocator: std.mem.Allocator) void {
        allocator.free(self.taken);
        allocator.free(self.dropped);
        allocator.free(self.take_while_live);
        allocator.free(self.drop_while_live);
        allocator.free(self.indices);
    }
};

const PumpResult = union(enum) {
    /// `true` keep pulling the source, `false` stop entirely.
    cont: bool,
    err: RuntimeError,
};

fn pump(
    allocator: std.mem.Allocator,
    host: IntrinsicHost,
    out: Output,
    start: Value,
    ops: []const SeqOp,
    st: *StreamState,
    output: *std.ArrayList(Value),
) std.mem.Allocator.Error!PumpResult {
    var current = start;
    for (ops, 0..) |op, idx| {
        switch (op) {
            .Map => |f| {
                const r = try invokeCallable(host, &f, &.{current}, out);
                switch (r) {
                    .ok => |rv| current = rv,
                    .err => |e| return .{ .err = e },
                }
            },
            .OnEach => |f| {
                const r = try invokeCallable(host, &f, &.{current}, out);
                if (r == .err) return .{ .err = r.err };
            },
            .MapIndexed => |f| {
                const i = st.indices[idx];
                st.indices[idx] += 1;
                const r = try invokeCallable(host, &f, &.{ Value.newInt(@intCast(i)), current }, out);
                switch (r) {
                    .ok => |rv| current = rv,
                    .err => |e| return .{ .err = e },
                }
            },
            .FilterIndexed => |f| {
                const i = st.indices[idx];
                st.indices[idx] += 1;
                const r = try invokeCallable(host, &f, &.{ Value.newInt(@intCast(i)), current }, out);
                switch (r) {
                    .ok => |rv| if (!isTrue(rv)) return .{ .cont = true },
                    .err => |e| return .{ .err = e },
                }
            },
            .Filter => |f| {
                const r = try invokeCallable(host, &f, &.{current}, out);
                switch (r) {
                    .ok => |rv| if (!isTrue(rv)) return .{ .cont = true },
                    .err => |e| return .{ .err = e },
                }
            },
            .FilterNot => |f| {
                const r = try invokeCallable(host, &f, &.{current}, out);
                switch (r) {
                    .ok => |rv| if (isTrue(rv)) return .{ .cont = true },
                    .err => |e| return .{ .err = e },
                }
            },
            .Take => |n| {
                const cap: usize = if (n < 0) 0 else @intCast(n);
                if (st.taken[idx] >= cap) return .{ .cont = false };
                st.taken[idx] += 1;
            },
            .Drop => |n| {
                const cap: usize = if (n < 0) 0 else @intCast(n);
                if (st.dropped[idx] < cap) {
                    st.dropped[idx] += 1;
                    return .{ .cont = true };
                }
            },
            .TakeWhile => |f| {
                if (!st.take_while_live[idx]) return .{ .cont = false };
                const r = try invokeCallable(host, &f, &.{current}, out);
                switch (r) {
                    .ok => |rv| if (!isTrue(rv)) {
                        st.take_while_live[idx] = false;
                        return .{ .cont = false };
                    },
                    .err => |e| return .{ .err = e },
                }
            },
            .DropWhile => |f| {
                if (st.drop_while_live[idx]) {
                    const r = try invokeCallable(host, &f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| {
                            if (isTrue(rv)) return .{ .cont = true };
                            st.drop_while_live[idx] = false;
                        },
                        .err => |e| return .{ .err = e },
                    }
                }
            },
            else => unreachable, // filtered above
        }
    }
    try output.append(allocator, current);
    return .{ .cont = true };
}

/// Has any Take stage reached its cap? If so the pipeline is exhausted and
/// the source must NOT be pulled again.
fn takeCapReached(ops: []const SeqOp, taken: []const usize) bool {
    for (ops, 0..) |op, i| {
        switch (op) {
            .Take => |n| {
                const cap: usize = if (n < 0) 0 else @intCast(n);
                if (taken[i] >= cap) return true;
            },
            else => {},
        }
    }
    return false;
}

// ----- shared small helpers -----

fn invokeCallable(host: IntrinsicHost, f: *const Value, args: []const Value, out: Output) std.mem.Allocator.Error!EvalResult {
    return host.invokeCallable(f, args, out);
}

fn isTrue(v: Value) bool {
    return v == .Bool and v.Bool;
}

fn containsEq(haystack: []const Value, needle: *const Value) bool {
    for (haystack) |*x| {
        if (Value.structuralEqBoxed(x, needle)) return true;
    }
    return false;
}

fn drainFront(allocator: std.mem.Allocator, items: *std.ArrayList(Value), n: usize) void {
    if (n == 0) return;
    if (n >= items.items.len) {
        items.clearRetainingCapacity();
        _ = allocator;
        return;
    }
    const remaining = items.items.len - n;
    std.mem.copyForwards(Value, items.items[0..remaining], items.items[n..]);
    items.shrinkRetainingCapacity(remaining);
}

fn cloneItems(allocator: std.mem.Allocator, ref: ValueList) std.mem.Allocator.Error![]Value {
    const g = ref.borrow();
    defer g.deinit();
    return allocator.dupe(Value, g.get().items);
}

fn cloneSlice(allocator: std.mem.Allocator, ref: ValueSlice) std.mem.Allocator.Error![]Value {
    const g = ref.borrow();
    defer g.deinit();
    return allocator.dupe(Value, g.get().*);
}

fn noSuchElement(allocator: std.mem.Allocator, message: []const u8) std.mem.Allocator.Error!RuntimeError {
    const fqn = try runtime.strInit(allocator, "kotlin.NoSuchElementException");
    const msg = try runtime.strInit(allocator, message);
    return .{ .Thrown = .{ .Exception = .{ .fqn = fqn, .message = msg, .cause = null } } };
}

// ----- comparison / sort (faithful `compare_values`) -----

/// Kotlin's `Double`/`Float` total order (matching `java.lang.Double.compare`):
/// every `NaN` is greater than all other values and all `NaN`s are equal, and
/// `-0.0 < 0.0`.
fn kotlinFloatTotalCmp(a: f64, b: f64) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    const bits = struct {
        fn f(x: f64) i64 {
            if (std.math.isNan(x)) return @bitCast(@as(u64, 0x7ff8_0000_0000_0000));
            return @bitCast(x);
        }
    }.f;
    return std.math.order(bits(a), bits(b));
}

const CmpResult = union(enum) {
    order: std.math.Order,
    err: RuntimeError,
};

fn compareValues(a: *const Value, b: *const Value) CmpResult {
    if (a.isNumeric() and b.isNumeric()) {
        if (a.isIntegral() and b.isIntegral()) {
            return .{ .order = std.math.order(a.asI64().?, b.asI64().?) };
        }
        return .{ .order = kotlinFloatTotalCmp(a.asF64().?, b.asF64().?) };
    }
    if (a.* == .String and b.* == .String) {
        const ga = a.String.borrow();
        defer ga.deinit();
        const gb = b.String.borrow();
        defer gb.deinit();
        return .{ .order = compareUtf16(ga.get().bytes, gb.get().bytes) };
    }
    if (a.* == .Char and b.* == .Char) {
        return .{ .order = std.math.order(a.Char, b.Char) };
    }
    if (a.* == .Bool and b.* == .Bool) {
        return .{ .order = std.math.order(@intFromBool(a.Bool), @intFromBool(b.Bool)) };
    }
    return .{ .err = .{ .Type = "values are not comparable" } };
}

/// Compare two strings the way Kotlin's `String.compareTo` does:
/// lexicographically over UTF-16 code units.
fn compareUtf16(a: []const u8, b: []const u8) std.math.Order {
    var ai = Utf16Iter{ .bytes = a };
    var bi = Utf16Iter{ .bytes = b };
    while (true) {
        const x = ai.next();
        const y = bi.next();
        if (x != null and y != null) {
            const o = std.math.order(x.?, y.?);
            if (o != .eq) return o;
        } else if (x != null and y == null) {
            return .gt;
        } else if (x == null and y != null) {
            return .lt;
        } else {
            return .eq;
        }
    }
}

/// Streams UTF-16 code units from a UTF-8 byte slice.
const Utf16Iter = struct {
    bytes: []const u8,
    pos: usize = 0,
    pending_low: ?u16 = null,

    fn next(self: *Utf16Iter) ?u16 {
        if (self.pending_low) |lo| {
            self.pending_low = null;
            return lo;
        }
        if (self.pos >= self.bytes.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.pos]) catch {
            self.pos += 1;
            return 0xFFFD;
        };
        if (self.pos + len > self.bytes.len) {
            self.pos = self.bytes.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.pos .. self.pos + len]) catch {
            self.pos += len;
            return 0xFFFD;
        };
        self.pos += len;
        if (cp <= 0xFFFF) return @intCast(cp);
        const c = cp - 0x10000;
        const hi: u16 = @intCast(0xD800 + (c >> 10));
        self.pending_low = @intCast(0xDC00 + (c & 0x3FF));
        return hi;
    }
};

fn sortNatural(items: []Value, descending: bool) ?RuntimeError {
    // Insertion sort: the comparison is fallible (returns RuntimeError data),
    // so a borrow-free total-order sort that can bail out is simplest.
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            switch (compareValues(&items[j - 1], &items[j])) {
                .order => |o| {
                    const ord = if (descending) o.invert() else o;
                    if (ord == .gt) {
                        std.mem.swap(Value, &items[j - 1], &items[j]);
                        j -= 1;
                    } else break;
                },
                .err => |e| return e,
            }
        }
    }
    return null;
}

fn sortByKey(items: []Value, keys: []Value, descending: bool) ?RuntimeError {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            switch (compareValues(&keys[j - 1], &keys[j])) {
                .order => |o| {
                    const ord = if (descending) o.invert() else o;
                    if (ord == .gt) {
                        std.mem.swap(Value, &items[j - 1], &items[j]);
                        std.mem.swap(Value, &keys[j - 1], &keys[j]);
                        j -= 1;
                    } else break;
                },
                .err => |e| return e,
            }
        }
    }
    return null;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const NoopHost = runtime.NoopHost;
const CaptureOutput = runtime.CaptureOutput;

/// Per-test harness: an arena (so an intrinsic's allocations are reclaimed
/// in one shot, exactly as the runtime drives them), a NoopHost, and a
/// capture sink. Drop with `deinit`.
const Harness = struct {
    arena: std.heap.ArenaAllocator,
    host: NoopHost,
    cap: CaptureOutput,

    fn init() Harness {
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .host = NoopHost.init(testing.allocator),
            .cap = CaptureOutput.init(testing.allocator),
        };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        self.host.deinit();
        self.cap.deinit();
    }

    fn allocator(self: *Harness) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn ctx(self: *Harness, args: []const Value) CallCtx {
        return .{
            .args = args,
            .out = self.cap.output(),
            .host = self.host.host(),
            .allocator = self.arena.allocator(),
        };
    }
};

test "sequenceOf builds an items source with no ops" {
    var h = Harness.init();
    defer h.deinit();

    var args = [_]Value{ .{ .Int = 1 }, .{ .Int = 2 }, .{ .Int = 3 } };
    var ctx = h.ctx(&args);
    const r = try seq_of(&ctx);
    try testing.expect(r == .ok);
    const g = r.ok.Sequence.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(usize, 0), g.get().ops.len);
    try testing.expect(g.get().source == .Items);
    const sg = g.get().source.Items.borrow();
    defer sg.deinit();
    try testing.expectEqual(@as(usize, 3), sg.get().len);
}

test "emptySequence is empty" {
    var h = Harness.init();
    defer h.deinit();
    var ctx = h.ctx(&.{});
    const r = try seq_empty(&ctx);
    const g = r.ok.Sequence.borrow();
    defer g.deinit();
    const sg = g.get().source.Items.borrow();
    defer sg.deinit();
    try testing.expectEqual(@as(usize, 0), sg.get().len);
}

test "asSequence from a list copies items" {
    var h = Harness.init();
    defer h.deinit();

    var list_items = [_]Value{ .{ .Int = 10 }, .{ .Int = 20 } };
    const list = try makeList(h.allocator(), &list_items, false);

    var args = [_]Value{list};
    var ctx = h.ctx(&args);
    const r = try seq_from_list(&ctx);
    const g = r.ok.Sequence.borrow();
    defer g.deinit();
    const sg = g.get().source.Items.borrow();
    defer sg.deinit();
    try testing.expectEqual(@as(usize, 2), sg.get().len);
    try testing.expectEqual(@as(i32, 10), sg.get().*[0].Int);
}

test "asSequence from a range enumerates the progression" {
    var h = Harness.init();
    defer h.deinit();

    var args = [_]Value{.{ .Range = .{ .start = 1, .end = 5, .step = 2, .kind = .Int } }};
    var ctx = h.ctx(&args);
    const r = try seq_from_range(&ctx);
    const g = r.ok.Sequence.borrow();
    defer g.deinit();
    const sg = g.get().source.Items.borrow();
    defer sg.deinit();
    // 1, 3, 5
    try testing.expectEqual(@as(usize, 3), sg.get().len);
    try testing.expectEqual(@as(i32, 1), sg.get().*[0].Int);
    try testing.expectEqual(@as(i32, 3), sg.get().*[1].Int);
    try testing.expectEqual(@as(i32, 5), sg.get().*[2].Int);
}

test "asSequence from a string yields utf-16 code units" {
    var h = Harness.init();
    defer h.deinit();

    const s = try runtime.strInit(h.allocator(), "ab");
    var args = [_]Value{.{ .String = s }};
    var ctx = h.ctx(&args);
    const r = try seq_from_string(&ctx);
    const g = r.ok.Sequence.borrow();
    defer g.deinit();
    const sg = g.get().source.Items.borrow();
    defer sg.deinit();
    try testing.expectEqual(@as(usize, 2), sg.get().len);
    try testing.expectEqual(@as(u16, 'a'), sg.get().*[0].Char);
    try testing.expectEqual(@as(u16, 'b'), sg.get().*[1].Char);
}

test "Sequence.toList on an items source returns the elements" {
    var h = Harness.init();
    defer h.deinit();

    var items = [_]Value{ .{ .Int = 7 }, .{ .Int = 8 } };
    const seq = try makeSequence(h.allocator(), try h.allocator().dupe(Value, &items));
    var args = [_]Value{seq};
    var ctx = h.ctx(&args);
    const r = try seq_to_list(&ctx);
    const list = r.ok;
    const lg = list.List.items.borrow();
    defer lg.deinit();
    try testing.expectEqual(@as(usize, 2), lg.get().items.len);
    try testing.expect(!list.List.mutable);
}

test "Sequence.toList on a non-trivial chain is routed to the interpreter" {
    var h = Harness.init();
    defer h.deinit();

    const empty = try h.allocator().alloc(Value, 0);
    const seq = try makeSequence(h.allocator(), empty);
    // Attach a Filter op so the fast path declines.
    const target = try seqWithExtraOp(h.allocator(), seq, .{ .Filter = .Unit });
    var args = [_]Value{target};
    var ctx = h.ctx(&args);
    const r = try seq_to_list(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Unimplemented);
}

test "Sequence.count and last on items source" {
    var h = Harness.init();
    defer h.deinit();

    var items = [_]Value{ .{ .Int = 1 }, .{ .Int = 2 }, .{ .Int = 3 } };
    const seq = try makeSequence(h.allocator(), try h.allocator().dupe(Value, &items));

    var args = [_]Value{seq};
    var ctx = h.ctx(&args);
    const c = try seq_count_no_pred(&ctx);
    try testing.expectEqual(@as(i32, 3), c.ok.Int);
    const l = try seq_last(&ctx);
    try testing.expectEqual(@as(i32, 3), l.ok.Int);
}

test "Sequence.last on an empty items source throws NoSuchElementException" {
    var h = Harness.init();
    defer h.deinit();

    const empty = try h.allocator().alloc(Value, 0);
    const seq = try makeSequence(h.allocator(), empty);
    var args = [_]Value{seq};
    var ctx = h.ctx(&args);
    const r = try seq_last(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Thrown);
    const e = r.err.Thrown.Exception;
    const fg = e.fqn.borrow();
    defer fg.deinit();
    try testing.expectEqualStrings("kotlin.NoSuchElementException", fg.get().bytes);
}

test "Sequence.first on a streaming items source pulls the first element" {
    var h = Harness.init();
    defer h.deinit();

    var items = [_]Value{ .{ .Int = 5 }, .{ .Int = 6 } };
    const seq = try makeSequence(h.allocator(), try h.allocator().dupe(Value, &items));
    var args = [_]Value{seq};
    var ctx = h.ctx(&args);
    const r = try seq_first(&ctx);
    try testing.expectEqual(@as(i32, 5), r.ok.Int);
}

test "Sequence.first on an empty source throws" {
    var h = Harness.init();
    defer h.deinit();

    const empty = try h.allocator().alloc(Value, 0);
    const seq = try makeSequence(h.allocator(), empty);
    var args = [_]Value{seq};
    var ctx = h.ctx(&args);
    const r = try seq_first(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Thrown);
}

test "Sequence.any and none on items source" {
    var h = Harness.init();
    defer h.deinit();

    var items = [_]Value{.{ .Int = 1 }};
    const seq = try makeSequence(h.allocator(), try h.allocator().dupe(Value, &items));
    var args = [_]Value{seq};
    var ctx = h.ctx(&args);
    const any_r = try seq_any(&ctx);
    try testing.expect(any_r.ok.Bool);
    const none_r = try seq_none(&ctx);
    try testing.expect(!none_r.ok.Bool);

    const empty = try h.allocator().alloc(Value, 0);
    const eseq = try makeSequence(h.allocator(), empty);
    var eargs = [_]Value{eseq};
    var ectx = h.ctx(&eargs);
    const any_e = try seq_any(&ectx);
    try testing.expect(!any_e.ok.Bool);
    const none_e = try seq_none(&ectx);
    try testing.expect(none_e.ok.Bool);
}

test "generateSequence requires a lambda" {
    var h = Harness.init();
    defer h.deinit();
    var args = [_]Value{.{ .Int = 1 }};
    var ctx = h.ctx(&args);
    const r = try seq_generate_sequence(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
}

test "Sequence.toString is a stable placeholder" {
    var h = Harness.init();
    defer h.deinit();
    var ctx = h.ctx(&.{});
    const r = try seq_to_string(&ctx);
    const g = r.ok.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("kotlin.sequences.Sequence", g.get().bytes);
}

test "Map.Entry key and value accessors" {
    var h = Harness.init();
    defer h.deinit();

    const key: Value = .{ .Int = 3 };
    const val: Value = .{ .Int = 9 };
    const entry: Value = .{ .MapEntry = .{
        .key = try Value.boxRef(h.allocator(), key),
        .value = try Value.boxRef(h.allocator(), val),
        .backing = null,
    } };
    var args = [_]Value{entry};
    var ctx = h.ctx(&args);
    const k = try map_entry_key(&ctx);
    try testing.expectEqual(@as(i32, 3), k.ok.Int);
    const v = try map_entry_value(&ctx);
    try testing.expectEqual(@as(i32, 9), v.ok.Int);
    const s = try map_entry_to_string(&ctx);
    const g = s.ok.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("3=9", g.get().bytes);
}

test "Map.Entry accessors reject a non-entry receiver" {
    var h = Harness.init();
    defer h.deinit();
    var args = [_]Value{.{ .Int = 1 }};
    var ctx = h.ctx(&args);
    const k = try map_entry_key(&ctx);
    try testing.expect(k == .err);
    try testing.expect(k.err == .Type);
}

test "range_iter_int handles forward, backward, and empty progressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, try rangeIterInt(a, 1, 3, 1));
    try testing.expectEqualSlices(i64, &.{ 5, 3, 1 }, try rangeIterInt(a, 5, 1, -2));
    try testing.expectEqual(@as(usize, 0), (try rangeIterInt(a, 3, 1, 1)).len);
    try testing.expectEqual(@as(usize, 0), (try rangeIterInt(a, 1, 5, 0)).len);
}

test "compare_utf16 orders bmp and supplementary chars" {
    try testing.expectEqual(std.math.Order.lt, compareUtf16("abc", "abd"));
    try testing.expectEqual(std.math.Order.eq, compareUtf16("abc", "abc"));
    try testing.expectEqual(std.math.Order.gt, compareUtf16("abd", "abc"));
    try testing.expectEqual(std.math.Order.lt, compareUtf16("", "a"));
    try testing.expectEqual(std.math.Order.lt, compareUtf16("hello", "hello!"));
}
