//! Lazy `Sequence` materialisation: the pump, the streaming and
//! buffering drivers, the op pipeline, and the builder-cursor helpers.

const std = @import("std");
const runtime = @import("runtime");
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const IntrinsicHost = runtime.IntrinsicHost;
const Output = runtime.Output;
const SeqOp = runtime.SeqOp;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const common_mod = @import("common.zig");
const OrderResult = common_mod.OrderResult;
const appendVL = common_mod.appendVL;
const compareValues = common_mod.compareValues;
const compareValuesPublic = common_mod.compareValuesPublic;
const containsBoxedH = common_mod.containsBoxedH;
const iterableItemsCtx = common_mod.iterableItemsCtx;
const makeException = common_mod.makeException;
const makePair = common_mod.makePair;
const reverseOrder = common_mod.reverseOrder;

// =====================================================================
// Sequence materialisation
// =====================================================================

const SeqOutcome = union(enum) { items: []Value, err: RuntimeError };

fn seqCall(host: IntrinsicHost, f: *const Value, args: []const Value, out: Output) Error!union(enum) { value: Value, err: RuntimeError } {
    const r = try host.invokeCallable(f, args, out);
    return switch (r) {
        .ok => |v| .{ .value = v },
        .err => |e| .{ .err = e },
    };
}

/// A one-shot sequence (`generateSequence { … }`) consumes once; the
/// second iteration throws, matching the source's `.constrainOnce()`.
/// Marks the sequence consumed on first use.
pub fn oneShotConsumeCheck(a: Allocator, seq_val: Value) Error!?RuntimeError {
    {
        const g = seq_val.Sequence.borrow();
        defer g.deinit();
        if (!g.get().one_shot) return null;
        if (g.get().consumed) {
            const exc = try makeException(a, "kotlin.IllegalStateException", "This sequence can be consumed only once.");
            return .{ .Thrown = exc };
        }
    }
    const gm = seq_val.Sequence.borrowMut();
    defer gm.deinit();
    gm.get().consumed = true;
    return null;
}

pub fn materialiseSequence(a: Allocator, host: IntrinsicHost, out: Output, seq_val: Value) Error!SeqOutcome {
    return materialiseSequenceBounded(a, host, out, seq_val, null);
}

pub fn materialiseSequenceBounded(a: Allocator, host: IntrinsicHost, out: Output, seq_val: Value, max: ?usize) Error!SeqOutcome {
    if (seq_val != .Sequence) {
        return .{ .err = .{ .Type = "materialise_sequence: not a Sequence" } };
    }
    if (try oneShotConsumeCheck(a, seq_val)) |e| return .{ .err = e };
    const seq_g = seq_val.Sequence.borrow();
    defer seq_g.deinit();
    const seq = seq_g.get().*;

    var all_streaming = true;
    for (seq.ops) |op| {
        switch (op) {
            .Map, .Filter, .FilterNot, .Take, .Drop, .TakeWhile, .DropWhile, .OnEach, .MapIndexed, .FilterIndexed => {},
            else => {
                all_streaming = false;
                break;
            },
        }
    }

    if (all_streaming) {
        return streamSequence(a, host, out, seq, max);
    }
    return bufferSequence(a, host, out, seq);
}

const PumpState = struct {
    taken: []usize,
    dropped: []usize,
    take_while_live: []bool,
    drop_while_live: []bool,
    indices: []usize,
};

/// Returns true to keep pulling source items, false when a Take cap was
/// reached (pipeline exhausted). On a callback error returns the error.
fn pumpItem(
    a: Allocator,
    host: IntrinsicHost,
    out: Output,
    start_value: Value,
    ops: []const SeqOp,
    st: *PumpState,
    output: *std.ArrayList(Value),
) Error!union(enum) { cont: bool, err: RuntimeError } {
    var current = start_value;
    // Pin the values the GC cannot otherwise reach across the re-entrant lambda
    // invocations below: the accumulated results so far (`output`, stable for
    // this pump — it is only appended to at the end) and the in-flight `current`
    // value threading through the ops. Without this, a collection during a later
    // element's `map`/`filter` lambda sweeps the earlier elements (e.g. the
    // `RoutingPathSegment`s a `splitToSequence().map{}.toList()` accumulates).
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    runtime.keepalivePushSlice(output.items);
    const ka_cur = runtime.keepaliveMark();
    for (ops, 0..) |op, idx| {
        runtime.keepaliveRestore(ka_cur);
        runtime.keepalivePush(current);
        switch (op) {
            .Map => |f| {
                current = switch (try seqCall(host, &f, &.{current}, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
            },
            .OnEach => |f| {
                switch (try seqCall(host, &f, &.{current}, out)) {
                    .value => {},
                    .err => |e| return .{ .err = e },
                }
            },
            .MapIndexed => |f| {
                const i = st.indices[idx];
                st.indices[idx] += 1;
                current = switch (try seqCall(host, &f, &.{ Value.newInt(@intCast(i)), current }, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
            },
            .FilterIndexed => |f| {
                const i = st.indices[idx];
                st.indices[idx] += 1;
                const r = switch (try seqCall(host, &f, &.{ Value.newInt(@intCast(i)), current }, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) return .{ .cont = true };
            },
            .Filter => |f| {
                const r = switch (try seqCall(host, &f, &.{current}, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) return .{ .cont = true };
            },
            .FilterNot => |f| {
                const r = switch (try seqCall(host, &f, &.{current}, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (r == .Bool and r.Bool) return .{ .cont = true };
            },
            .Take => |n| {
                if (st.taken[idx] >= @as(usize, @intCast(n))) return .{ .cont = false };
                st.taken[idx] += 1;
            },
            .Drop => |n| {
                if (st.dropped[idx] < @as(usize, @intCast(n))) {
                    st.dropped[idx] += 1;
                    return .{ .cont = true };
                }
            },
            .TakeWhile => |f| {
                if (!st.take_while_live[idx]) return .{ .cont = false };
                const r = switch (try seqCall(host, &f, &.{current}, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) {
                    st.take_while_live[idx] = false;
                    return .{ .cont = false };
                }
            },
            .DropWhile => |f| {
                if (st.drop_while_live[idx]) {
                    const r = switch (try seqCall(host, &f, &.{current}, out)) {
                        .value => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    if (r == .Bool and r.Bool) return .{ .cont = true };
                    st.drop_while_live[idx] = false;
                }
            },
            else => unreachable,
        }
    }
    try output.append(a, current);
    return .{ .cont = true };
}

fn takeCapReached(ops: []const SeqOp, taken: []const usize) bool {
    for (ops, 0..) |op, i| {
        if (op == .Take and taken[i] >= @as(usize, @intCast(op.Take))) return true;
    }
    return false;
}

/// One pull from a `Merged` (zip) source: advance the left iterator, then
/// the right, one element each; either side exhausting ends the merge. The
/// child iterators are created together on the first pull, so a
/// shared-state generator observes `MergingSequence`'s strict interleave.
pub fn mergedPullOne(
    a: Allocator,
    host: IntrinsicHost,
    out: Output,
    mz: runtime.MergedSource,
    iter_left: *?Value,
    iter_right: *?Value,
) Error!union(enum) { value: Value, done, err: RuntimeError } {
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    if (iter_left.*) |v| runtime.keepalivePush(v);
    if (iter_right.*) |v| runtime.keepalivePush(v);
    if (iter_left.* == null) {
        const li = (try host.invokeMethod(&mz.left.asPtr().*, "iterator", &.{}, out)) orelse
            return .{ .err = .{ .Type = "zip: receiver lacks iterator()" } };
        switch (li) {
            .ok => |v| {
                iter_left.* = v;
                runtime.keepalivePush(v);
            },
            .err => |e| return .{ .err = e },
        }
        const ri = (try host.invokeMethod(&mz.right.asPtr().*, "iterator", &.{}, out)) orelse
            return .{ .err = .{ .Type = "zip: argument lacks iterator()" } };
        switch (ri) {
            .ok => |v| {
                iter_right.* = v;
                runtime.keepalivePush(v);
            },
            .err => |e| return .{ .err = e },
        }
    }
    const lit = iter_left.*.?;
    const rit = iter_right.*.?;
    runtime.keepalivePush(lit);
    runtime.keepalivePush(rit);
    const lh = (try host.invokeMethod(&lit, "hasNext", &.{}, out)) orelse
        return .{ .err = .{ .Type = "zip: iterator lacks hasNext" } };
    switch (lh) {
        .ok => |x| if (!(x == .Bool and x.Bool)) return .done,
        .err => |e| return .{ .err = e },
    }
    const rh = (try host.invokeMethod(&rit, "hasNext", &.{}, out)) orelse
        return .{ .err = .{ .Type = "zip: iterator lacks hasNext" } };
    switch (rh) {
        .ok => |x| if (!(x == .Bool and x.Bool)) return .done,
        .err => |e| return .{ .err = e },
    }
    const av = switch ((try host.invokeMethod(&lit, "next", &.{}, out)) orelse
        return .{ .err = .{ .Type = "zip: iterator lacks next" } }) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    runtime.keepalivePush(av);
    const bv = switch ((try host.invokeMethod(&rit, "next", &.{}, out)) orelse
        return .{ .err = .{ .Type = "zip: iterator lacks next" } }) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    runtime.keepalivePush(bv);
    if (mz.transform) |t| {
        return switch (try seqCall(host, t.asPtr(), &.{ av, bv }, out)) {
            .value => |v| .{ .value = v },
            .err => |e| .{ .err = e },
        };
    }
    return .{ .value = try makePair(a, av, bv) };
}

fn streamSequence(a: Allocator, host: IntrinsicHost, out: Output, seq: runtime.SequenceData, max: ?usize) Error!SeqOutcome {
    const n_ops = seq.ops.len;
    var st = PumpState{
        .taken = try a.alloc(usize, n_ops),
        .dropped = try a.alloc(usize, n_ops),
        .take_while_live = try a.alloc(bool, n_ops),
        .drop_while_live = try a.alloc(bool, n_ops),
        .indices = try a.alloc(usize, n_ops),
    };
    @memset(st.taken, 0);
    @memset(st.dropped, 0);
    @memset(st.take_while_live, true);
    @memset(st.drop_while_live, true);
    @memset(st.indices, 0);
    var output: std.ArrayList(Value) = .empty;

    const ka_src = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka_src);
    switch (seq.source) {
        .Items => |v| {
            const g = v.borrow();
            defer g.deinit();
            // Pin the not-yet-processed source items across the per-item pumps.
            runtime.keepalivePushSlice(g.get().*);
            for (g.get().*) |item| {
                if (takeCapReached(seq.ops, st.taken)) break;
                const res = try pumpItem(a, host, out, item, seq.ops, &st, &output);
                switch (res) {
                    .cont => |c| if (!c) break,
                    .err => |e| return .{ .err = e },
                }
                if (max) |m| {
                    if (output.items.len >= m) break;
                }
            }
        },
        .Builder => |bstate0| {
            // Drive a FRESH cursor so this materialisation is independent of any
            // other consumption of the same (re-iterable) Sequence.
            const bstate = try freshBuilderState(host, a, bstate0);
            try pinBuilderState(a, bstate);
            // Pull from the lazy builder one element at a time so an infinite
            // generator never materialises past the consumer's demand.
            while (true) {
                if (takeCapReached(seq.ops, st.taken)) break;
                const output_keepalive = runtime.keepaliveMark();
                runtime.keepalivePushSlice(output.items);
                const stepped = host.builderStep(bstate, out);
                runtime.keepaliveRestore(output_keepalive);
                const step = try stepped;
                const item = switch (step) {
                    .value => |val| val,
                    .done => break,
                    .err => |e| return .{ .err = e },
                };
                const res = try pumpItem(a, host, out, item, seq.ops, &st, &output);
                switch (res) {
                    .cont => |c| if (!c) break,
                    .err => |e| return .{ .err = e },
                }
                if (max) |m| {
                    if (output.items.len >= m) break;
                }
            }
        },
        .Generate => |gen| {
            var cur: ?Value = if (gen.seed) |s| blk: {
                const sv = s.asPtr().*;
                if (gen.seed_is_fn) {
                    const r = switch (try seqCall(host, &sv, &.{}, out)) {
                        .value => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    if (r == .Null) return .{ .items = try a.alloc(Value, 0) };
                    break :blk r;
                }
                sv.retain();
                break :blk sv;
            } else null;
            const limit: usize = 1_000_000;
            var produced: usize = 0;
            while (true) {
                if (takeCapReached(seq.ops, st.taken)) break;
                const candidate = if (cur) |v| v else blk: {
                    const output_keepalive = runtime.keepaliveMark();
                    runtime.keepalivePushSlice(output.items);
                    const called = seqCall(host, gen.next.asPtr(), &.{}, out);
                    runtime.keepaliveRestore(output_keepalive);
                    const r = switch (try called) {
                        .value => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    if (r == .Null) break;
                    break :blk r;
                };
                produced += 1;
                if (produced > limit) {
                    return .{ .err = .{ .Type = "Sequence: generator exceeded 1,000,000 items" } };
                }
                const res = try pumpItem(a, host, out, candidate, seq.ops, &st, &output);
                switch (res) {
                    .cont => |c| if (!c) break,
                    .err => |e| return .{ .err = e },
                }
                if (max) |m| {
                    if (output.items.len >= m) break;
                }
                const output_keepalive = runtime.keepaliveMark();
                runtime.keepalivePushSlice(output.items);
                const called = seqCall(host, gen.next.asPtr(), &.{candidate}, out);
                runtime.keepaliveRestore(output_keepalive);
                const nxt = switch (try called) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (nxt == .Null) break;
                cur = nxt;
            }
        },
        .IteratorFn => |fnbox| {
            const iter = switch (try seqCall(host, fnbox.asPtr(), &.{}, out)) {
                .value => |v| v,
                .err => |e| return .{ .err = e },
            };
            const iter_keepalive = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(iter_keepalive);
            runtime.keepalivePush(iter);
            while (true) {
                const loop_keepalive = runtime.keepaliveMark();
                runtime.keepalivePushSlice(output.items);
                defer runtime.keepaliveRestore(loop_keepalive);
                if (takeCapReached(seq.ops, st.taken)) break;
                const hn = (try host.invokeMethod(&iter, "hasNext", &.{}, out)) orelse {
                    if (runtime.envSetOnce("KLIO_SEQ_DIAG")) {
                        std.debug.print("[seq-diag] iterator lacks hasNext: iter kind={s} fqn={s}\n", .{ @tagName(std.meta.activeTag(iter)), iter.typeFqn() });
                    }
                    return .{ .err = .{ .Type = "Sequence: iterator lacks hasNext" } };
                };
                const has = switch (hn) {
                    .ok => |x| x == .Bool and x.Bool,
                    .err => |e| return .{ .err = e },
                };
                if (!has) break;
                const nx = (try host.invokeMethod(&iter, "next", &.{}, out)) orelse
                    return .{ .err = .{ .Type = "Sequence: iterator lacks next" } };
                const item = switch (nx) {
                    .ok => |x| x,
                    .err => |e| return .{ .err = e },
                };
                const res = try pumpItem(a, host, out, item, seq.ops, &st, &output);
                switch (res) {
                    .cont => |c| if (!c) break,
                    .err => |e| return .{ .err = e },
                }
                if (max) |m| {
                    if (output.items.len >= m) break;
                }
            }
        },
        .Merged => |mz| {
            var lit: ?Value = null;
            var rit: ?Value = null;
            while (true) {
                if (takeCapReached(seq.ops, st.taken)) break;
                const step = try mergedPullOne(a, host, out, mz, &lit, &rit);
                const item = switch (step) {
                    .value => |val| val,
                    .done => break,
                    .err => |e| return .{ .err = e },
                };
                const res = try pumpItem(a, host, out, item, seq.ops, &st, &output);
                switch (res) {
                    .cont => |c| if (!c) break,
                    .err => |e| return .{ .err = e },
                }
                if (max) |m| {
                    if (output.items.len >= m) break;
                }
            }
        },
    }
    return .{ .items = try output.toOwnedSlice(a) };
}

fn bufferSequence(a: Allocator, host: IntrinsicHost, out: Output, seq: runtime.SequenceData) Error!SeqOutcome {
    var items: std.ArrayList(Value) = .empty;
    switch (seq.source) {
        .Items => |v| {
            const g = v.borrow();
            defer g.deinit();
            try items.appendSlice(a, g.get().*);
        },
        .Builder => |bstate0| {
            const bstate = try freshBuilderState(host, a, bstate0);
            try pinBuilderState(a, bstate);
            while (true) {
                const items_keepalive = runtime.keepaliveMark();
                runtime.keepalivePushSlice(items.items);
                const stepped = host.builderStep(bstate, out);
                runtime.keepaliveRestore(items_keepalive);
                const step = try stepped;
                switch (step) {
                    .value => |val| try items.append(a, val),
                    .done => break,
                    .err => |e| return .{ .err = e },
                }
            }
        },
        .Generate => |gen| {
            const limit: usize = 1024;
            var cur: ?Value = if (gen.seed) |s| blk: {
                const sv = s.asPtr().*;
                if (gen.seed_is_fn) {
                    const r = switch (try seqCall(host, &sv, &.{}, out)) {
                        .value => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    if (r == .Null) break :blk null;
                    break :blk r;
                }
                sv.retain();
                break :blk sv;
            } else null;
            while (items.items.len < limit) {
                const candidate = if (cur) |v| v else blk: {
                    const items_keepalive = runtime.keepaliveMark();
                    runtime.keepalivePushSlice(items.items);
                    const called = seqCall(host, gen.next.asPtr(), &.{}, out);
                    runtime.keepaliveRestore(items_keepalive);
                    const r = switch (try called) {
                        .value => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    if (r == .Null) break;
                    break :blk r;
                };
                try items.append(a, candidate);
                const items_keepalive = runtime.keepaliveMark();
                runtime.keepalivePushSlice(items.items);
                const called = seqCall(host, gen.next.asPtr(), &.{candidate}, out);
                runtime.keepaliveRestore(items_keepalive);
                const nxt = switch (try called) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (nxt == .Null) break;
                cur = nxt;
            }
        },
        .IteratorFn => |fnbox| {
            const iter = switch (try seqCall(host, fnbox.asPtr(), &.{}, out)) {
                .value => |v| v,
                .err => |e| return .{ .err = e },
            };
            const iter_keepalive = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(iter_keepalive);
            runtime.keepalivePush(iter);
            while (true) {
                const loop_keepalive = runtime.keepaliveMark();
                runtime.keepalivePushSlice(items.items);
                defer runtime.keepaliveRestore(loop_keepalive);
                const hn = (try host.invokeMethod(&iter, "hasNext", &.{}, out)) orelse {
                    if (runtime.envSetOnce("KLIO_SEQ_DIAG")) {
                        std.debug.print("[seq-diag] iterator lacks hasNext: iter kind={s} fqn={s}\n", .{ @tagName(std.meta.activeTag(iter)), iter.typeFqn() });
                    }
                    return .{ .err = .{ .Type = "Sequence: iterator lacks hasNext" } };
                };
                const has = switch (hn) {
                    .ok => |x| x == .Bool and x.Bool,
                    .err => |e| return .{ .err = e },
                };
                if (!has) break;
                const nx = (try host.invokeMethod(&iter, "next", &.{}, out)) orelse
                    return .{ .err = .{ .Type = "Sequence: iterator lacks next" } };
                switch (nx) {
                    .ok => |item| try items.append(a, item),
                    .err => |e| return .{ .err = e },
                }
            }
        },
        .Merged => |mz| {
            var lit: ?Value = null;
            var rit: ?Value = null;
            while (true) {
                const items_keepalive = runtime.keepaliveMark();
                runtime.keepalivePushSlice(items.items);
                const pulled = mergedPullOne(a, host, out, mz, &lit, &rit);
                runtime.keepaliveRestore(items_keepalive);
                switch (try pulled) {
                    .value => |item| try items.append(a, item),
                    .done => break,
                    .err => |e| return .{ .err = e },
                }
            }
        },
    }
    var cur_items = try items.toOwnedSlice(a);
    for (seq.ops) |op| {
        cur_items = switch (try applySeqOp(a, host, out, op, cur_items)) {
            .items => |xs| xs,
            .err => |e| return .{ .err = e },
        };
    }
    return .{ .items = cur_items };
}

fn applySeqOp(a: Allocator, host: IntrinsicHost, out: Output, op: SeqOp, items: []Value) Error!SeqOutcome {
    switch (op) {
        .Map => |f| {
            var nx = try a.alloc(Value, items.len);
            // Pin the source and the already-mapped prefix across the lambda
            // calls (the GC cannot reach these host-locals); only `nx[0..i]` is
            // initialized, so never pin the undefined tail.
            const ka = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(ka);
            runtime.keepalivePushSlice(items);
            const ka2 = runtime.keepaliveMark();
            for (items, 0..) |v, i| {
                runtime.keepaliveRestore(ka2);
                runtime.keepalivePushSlice(nx[0..i]);
                nx[i] = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
            }
            return .{ .items = nx };
        },
        .OnEach => |f| {
            for (items) |v| {
                switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => {},
                    .err => |e| return .{ .err = e },
                }
            }
            return .{ .items = items };
        },
        .MapIndexed => |f| {
            var nx = try a.alloc(Value, items.len);
            const ka = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(ka);
            runtime.keepalivePushSlice(items);
            const ka2 = runtime.keepaliveMark();
            for (items, 0..) |v, i| {
                runtime.keepaliveRestore(ka2);
                runtime.keepalivePushSlice(nx[0..i]);
                nx[i] = switch (try seqCall(host, &f, &.{ Value.newInt(@intCast(i)), v }, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
            }
            return .{ .items = nx };
        },
        .FilterIndexed => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items, 0..) |v, i| {
                const r = switch (try seqCall(host, &f, &.{ Value.newInt(@intCast(i)), v }, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (r == .Bool and r.Bool) try nx.append(a, v);
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .Filter => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items) |v| {
                const r = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (r == .Bool and r.Bool) try nx.append(a, v);
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .FilterNot => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items) |v| {
                const r = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) try nx.append(a, v);
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .Take => |n| {
            const k: usize = @intCast(n);
            return .{ .items = if (k < items.len) items[0..k] else items };
        },
        .Drop => |n| {
            const k: usize = @min(@as(usize, @intCast(n)), items.len);
            return .{ .items = items[k..] };
        },
        .TakeWhile => |f| {
            var cutoff: usize = items.len;
            for (items, 0..) |v, i| {
                const r = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) {
                    cutoff = i;
                    break;
                }
            }
            return .{ .items = items[0..cutoff] };
        },
        .DropWhile => |f| {
            var start: usize = 0;
            while (start < items.len) {
                const r = switch (try seqCall(host, &f, &.{items[start]}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) break;
                start += 1;
            }
            return .{ .items = items[start..] };
        },
        .FlatMap => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items) |v| {
                const mapped = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                switch (mapped) {
                    .List => |xs| try appendVL(&nx, a, xs.items),
                    .Set => |xs| try appendVL(&nx, a, xs.items),
                    .Sequence => {
                        const sub = switch (try materialiseSequence(a, host, out, mapped)) {
                            .items => |xs| xs,
                            .err => |e| return .{ .err = e },
                        };
                        try nx.appendSlice(a, sub);
                    },
                    // Every other iterable transform result (Array, Range, Map,
                    // a user `Instance` Iterable) is flattened through the
                    // shared extractor; a non-iterable result degrades to a
                    // single element as before.
                    else => {
                        var ctx = runtime.CallCtx{ .args = &.{}, .out = out, .host = host, .allocator = a };
                        switch (try iterableItemsCtx(&ctx, mapped, "flatMap")) {
                            .items => |flat| {
                                try nx.appendSlice(a, flat);
                                if (runtime.freeScratch()) a.free(flat);
                            },
                            .err => try nx.append(a, mapped),
                        }
                    },
                }
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .Distinct => {
            var seen: std.ArrayList(Value) = .empty;
            var nx: std.ArrayList(Value) = .empty;
            for (items) |v| {
                if (!try containsBoxedH(host, out, seen.items, &v)) {
                    try seen.append(a, v);
                    try nx.append(a, v);
                }
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .DistinctBy => |f| {
            var seen: std.ArrayList(Value) = .empty;
            var nx: std.ArrayList(Value) = .empty;
            for (items) |v| {
                const key = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (!try containsBoxedH(host, out, seen.items, &key)) {
                    try seen.append(a, key);
                    try nx.append(a, v);
                }
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .Sorted => |descending| {
            if (try sortValuesNaturalDescErr(a, items, descending)) |e| return .{ .err = e };
            return .{ .items = items };
        },
        .SortedBy => |sb| {
            const keyed = try a.alloc(Value, items.len);
            for (items, 0..) |v, i| {
                keyed[i] = switch (try seqCall(host, &sb.selector, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
            }
            // Insertion sort keyed pairs, moving items in lockstep.
            var i: usize = 1;
            while (i < items.len) : (i += 1) {
                var j = i;
                while (j > 0) {
                    const o = switch (try compareValues(a, keyed[j - 1], keyed[j])) {
                        .order => |o| o,
                        .err => |e| return .{ .err = e.err },
                    };
                    const flipped = if (sb.descending) reverseOrder(o) else o;
                    if (flipped == .gt) {
                        std.mem.swap(Value, &items[j - 1], &items[j]);
                        std.mem.swap(Value, &keyed[j - 1], &keyed[j]);
                        j -= 1;
                    } else break;
                }
            }
            return .{ .items = items };
        },
        .SortedWith => |comparator| {
            var i: usize = 1;
            while (i < items.len) : (i += 1) {
                var j = i;
                while (j > 0) {
                    const m = try host.invokeMethod(&comparator, "compare", &.{ items[j - 1], items[j] }, out);
                    const ord_val = if (m) |mr| switch (mr) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    } else return .{ .err = .{ .Type = "SortedWith: comparator has no `compare` method" } };
                    const n = ord_val.asI64() orelse 0;
                    if (n > 0) {
                        std.mem.swap(Value, &items[j - 1], &items[j]);
                        j -= 1;
                    } else break;
                }
            }
            return .{ .items = items };
        },
    }
}

fn sortValuesNaturalDescErr(a: Allocator, items: []Value, descending: bool) Error!?RuntimeError {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const o = switch (try compareValues(a, items[j - 1], items[j])) {
                .order => |o| o,
                .err => |e| return e.err,
            };
            const flipped = if (descending) reverseOrder(o) else o;
            if (flipped == .gt) {
                std.mem.swap(Value, &items[j - 1], &items[j]);
                j -= 1;
            } else break;
        }
    }
    return null;
}

// =====================================================================
// Public re-exports for the interpreter's higher-order ops
// =====================================================================

/// Natural-order comparison. Returns an ordering or a `RuntimeError` (as
/// data) for incomparable values.
pub fn compare_values(a: Allocator, x: Value, y: Value) Error!OrderResult {
    return compareValuesPublic(a, x, y);
}

// `SequenceScope` field names (kept in sync with coroutines.zig's canonical
// copy, which lives in a higher module the stdlib cannot import).
pub const seq_has_value_field = "__seq_has_value";
pub const seq_value_field = "__seq_value";
pub const seq_yield_iter_field = "__seq_yield_iter";

/// A FRESH builder cursor cloned from `template`: a new `SequenceScope` and
/// reset flags, sharing the template's block closure. Kotlin's `sequence { }`
/// is re-iterable (a fresh coroutine per `iterator()`); klio embeds one cursor
/// in the Sequence, so each new consumption drives a clone, leaving the
/// embedded template pristine.
/// Pin a host-local fresh builder cursor for a drive loop: under the
/// tracing GC the state cell's ONLY reference is a Zig local (invisible
/// to the mark), so a collection during a pull would sweep it — and its
/// scope — out from under the loop. The keepalive wrapper makes it a
/// root for the enclosing mark/restore window.
pub fn pinBuilderState(a: Allocator, state: runtime.BuilderStateRef) Allocator.Error!void {
    if (!runtime.gc.gc_enabled) return;
    const data = try ObjRef(runtime.SequenceData).init(a, .{ .source = .{ .Builder = state.clone() }, .ops = &.{} });
    runtime.keepalivePush(.{ .Sequence = data });
}

pub fn freshBuilderState(host: IntrinsicHost, a: Allocator, template: runtime.BuilderStateRef) Allocator.Error!runtime.BuilderStateRef {
    const block: Value = blk: {
        const tg = template.borrow();
        defer tg.deinit();
        break :blk tg.get().block.asPtr().*;
    };
    const id = host.allocInstanceId();
    const fields = [_]InstanceData.Field{
        .{ .name = seq_has_value_field, .value = .{ .Bool = false } },
        .{ .name = seq_value_field, .value = .Unit },
        .{ .name = seq_yield_iter_field, .value = .Null },
    };
    const scope = try host.newSynthInstance("kotlin.sequences.SequenceScope", id, &fields);
    var blk_val = block;
    if (runtime.reclaimEnabled()) blk_val.retain();
    const block_box = try Value.boxRef(a, blk_val);
    if (runtime.reclaimEnabled()) scope.retain();
    const scope_box = try Value.boxRef(a, scope);
    return try runtime.BuilderStateRef.init(a, .{ .block = block_box, .scope = scope_box });
}

/// If `seq` is a `Builder`-source Sequence, a fresh Sequence with a cloned
/// cursor (sharing the op pipeline) for independent iteration; else null.
pub fn freshBuilderSeq(host: IntrinsicHost, a: Allocator, seq: Value) Allocator.Error!?Value {
    if (seq != .Sequence) return null;
    const sg = seq.Sequence.borrow();
    if (sg.get().source != .Builder) {
        sg.deinit();
        return null;
    }
    const tmpl = sg.get().source.Builder;
    const ops = sg.get().ops;
    sg.deinit();
    const state = try freshBuilderState(host, a, tmpl);
    const data = try ObjRef(runtime.SequenceData).init(a, .{ .source = .{ .Builder = state }, .ops = ops });
    return .{ .Sequence = data };
}

/// Drive a lazy `Value::Sequence` to completion. Returns the produced
/// items or a `RuntimeError` (as data).
pub fn materialise_sequence(a: Allocator, host: IntrinsicHost, out: Output, seq_val: Value) Error!SeqOutcome {
    return materialiseSequence(a, host, out, seq_val);
}

/// Bounded sequence materialisation (stops after `max` items on the
/// streaming fast path).
pub fn materialise_sequence_bounded(a: Allocator, host: IntrinsicHost, out: Output, seq_val: Value, max: ?usize) Error!SeqOutcome {
    return materialiseSequenceBounded(a, host, out, seq_val, max);
}
