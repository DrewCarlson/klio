//! The member surface the host serves for builtin value shapes, behind the
//! natives in `host_members.zig`: Kotlin structural equality, hashing and
//! ordering; comparator, collection, array and `componentN` ops; and the
//! iteration protocol.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const host_util = @import("host_util.zig");
const host_resolved = @import("host_resolved.zig");
const host_call_value = @import("host_call_value.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const RangeKind = runtime.RangeKind;
const SequenceData = runtime.SequenceData;
const ComparatorStep = runtime.ComparatorStep;

const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const boolVal = host_util.boolVal;
const cloneItemsList = host_util.cloneItemsList;
const isIteratorNext = host_util.isIteratorNext;
const listOf = host_util.listOf;
const mapRuntimeError = host_util.mapRuntimeError;
const throwExc = host_util.throwExc;
const typeErr = host_util.typeErr;

/// Recursive value equality: dispatches a user `equals` for Instance operands and
/// compares List/Set/Map element-wise over copies of their elements.
pub fn deepValueEquals(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) Allocator.Error!bool {
    if (a.* == .PropertyRef and b.* == .PropertyRef) {
        const ga = a.PropertyRef.name.borrow();
        defer ga.deinit();
        const gb = b.PropertyRef.name.borrow();
        defer gb.deinit();
        return std.mem.eql(u8, ga.get().bytes, gb.get().bytes);
    }
    if (a.* == .IrClosure and b.* == .IrClosure) return closureRefEquals(self, allocator, a, b);
    // A native collection on the left compares to a user Instance by size and elements.
    if (a.* != .Instance and b.* == .Instance) {
        switch (a.*) {
            .Set => if (host_resolved.instanceImplements(self, b, hostClasses(self).set)) {
                // What the host holds across the Kotlin calls below is rooted
                // for the collector: the drained elements have no other owner.
                const mark = runtime.keepaliveMark();
                defer runtime.keepaliveRestore(mark);
                const dr = try drainIterableToList(self, allocator, b);
                const drained = switch (dr) {
                    .ok => |v| v,
                    .err => return false,
                };
                runtime.keepalivePush(drained);
                defer if (runtime.reclaimEnabled()) drained.release(allocator);
                const xa = try rootedItems(allocator, a.Set.items);
                defer if (runtime.freeScratch()) allocator.free(xa);
                const xb = try rootedItems(allocator, drained.List.items);
                defer if (runtime.freeScratch()) allocator.free(xb);
                if (xa.len != xb.len) return false;
                for (xa) |*ea| {
                    var found = false;
                    for (xb) |*eb| {
                        if (try deepValueEquals(self, allocator, ea, eb)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                }
                return true;
            },
            .List => if (host_resolved.instanceImplements(self, b, hostClasses(self).list)) {
                const mark = runtime.keepaliveMark();
                defer runtime.keepaliveRestore(mark);
                const dr = try drainIterableToList(self, allocator, b);
                const drained = switch (dr) {
                    .ok => |v| v,
                    .err => return false,
                };
                runtime.keepalivePush(drained);
                defer if (runtime.reclaimEnabled()) drained.release(allocator);
                a.refreshArrayView();
                a.refreshSublistView();
                const xa = try rootedItems(allocator, a.List.items);
                defer if (runtime.freeScratch()) allocator.free(xa);
                const xb = try rootedItems(allocator, drained.List.items);
                defer if (runtime.freeScratch()) allocator.free(xb);
                if (xa.len != xb.len) return false;
                for (xa, xb) |*ea, *eb| {
                    if (!try deepValueEquals(self, allocator, ea, eb)) return false;
                }
                return true;
            },
            .Map => if (host_resolved.instanceImplements(self, b, hostClasses(self).map)) {
                // `entries` is a property: read as one, a class lowered from
                // sema answers it through its slot.
                const mark = runtime.keepaliveMark();
                defer runtime.keepaliveRestore(mark);
                const er = try host_resolved.wellKnownMember(self, allocator, b, .entries, &.{});
                const entries_val = switch (er) {
                    .ok => |v| v,
                    .err => return false,
                };
                runtime.keepalivePush(entries_val);
                defer if (runtime.reclaimEnabled()) entries_val.release(allocator);
                const dr = try drainIterableToList(self, allocator, &entries_val);
                const drained = switch (dr) {
                    .ok => |v| v,
                    .err => return false,
                };
                runtime.keepalivePush(drained);
                defer if (runtime.reclaimEnabled()) drained.release(allocator);
                const pa = try rootedPairs(allocator, a.Map.entries);
                defer if (runtime.freeScratch()) allocator.free(pa);
                const xb = try rootedItems(allocator, drained.List.items);
                defer if (runtime.freeScratch()) allocator.free(xb);
                if (pa.len != xb.len) return false;
                for (pa) |*ka| {
                    var found = false;
                    for (xb) |*eb| {
                        const entry_mark = runtime.keepaliveMark();
                        defer runtime.keepaliveRestore(entry_mark);
                        const kr = try host_resolved.wellKnownMember(self, allocator, eb, .entry_key, &.{});
                        const key = switch (kr) {
                            .ok => |v| v,
                            .err => continue,
                        };
                        runtime.keepalivePush(key);
                        defer if (runtime.reclaimEnabled()) key.release(allocator);
                        if (!try deepValueEquals(self, allocator, &ka.key, &key)) continue;
                        const vr = try host_resolved.wellKnownMember(self, allocator, eb, .entry_value, &.{});
                        const val = switch (vr) {
                            .ok => |v| v,
                            .err => continue,
                        };
                        runtime.keepalivePush(val);
                        defer if (runtime.reclaimEnabled()) val.release(allocator);
                        if (try deepValueEquals(self, allocator, &ka.value, &val)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                }
                return true;
            },
            else => {},
        }
    }
    // An instance on the left answers with its own `equals`, whatever the
    // right side is: a ring buffer compares with a host list as a list.
    if (a.* == .Instance) {
        switch (try host_resolved.wellKnownMember(self, allocator, a, .equals, &.{b.*})) {
            .ok => |v| return v == .Bool and v.Bool,
            .err => {},
        }
        return Value.structuralEqBoxed(a, b);
    }
    if (b.* == .Instance) return Value.structuralEqBoxed(a, b);
    switch (a.*) {
        .List => {
            if (b.* != .List) return Value.structuralEqBoxed(a, b);
            // Sync array-backed and sublist views, or they read stale contents.
            a.refreshArrayView();
            b.refreshArrayView();
            a.refreshSublistView();
            b.refreshSublistView();
            const mark = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(mark);
            const xa = try rootedItems(allocator, a.List.items);
            defer if (runtime.freeScratch()) allocator.free(xa);
            const xb = try rootedItems(allocator, b.List.items);
            defer if (runtime.freeScratch()) allocator.free(xb);
            if (xa.len != xb.len) return false;
            for (xa, xb) |*ea, *eb| {
                if (!try deepValueEquals(self, allocator, ea, eb)) return false;
            }
            return true;
        },
        .Set => {
            if (b.* != .Set) return Value.structuralEqBoxed(a, b);
            const mark = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(mark);
            const xa = try rootedItems(allocator, a.Set.items);
            defer if (runtime.freeScratch()) allocator.free(xa);
            const xb = try rootedItems(allocator, b.Set.items);
            defer if (runtime.freeScratch()) allocator.free(xb);
            if (xa.len != xb.len) return false;
            for (xa) |*ea| {
                var found = false;
                for (xb) |*eb| {
                    if (try deepValueEquals(self, allocator, ea, eb)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        },
        .Map => {
            if (b.* != .Map) return Value.structuralEqBoxed(a, b);
            const mark = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(mark);
            const pa = try rootedPairs(allocator, a.Map.entries);
            defer if (runtime.freeScratch()) allocator.free(pa);
            const pb = try rootedPairs(allocator, b.Map.entries);
            defer if (runtime.freeScratch()) allocator.free(pb);
            if (pa.len != pb.len) return false;
            for (pa) |*ka| {
                var found = false;
                for (pb) |*kb| {
                    if (try deepValueEquals(self, allocator, &ka.key, &kb.key) and
                        try deepValueEquals(self, allocator, &ka.value, &kb.value))
                    {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        },
        .Pair => |x| {
            if (b.* != .Pair) return Value.structuralEqBoxed(a, b);
            return try deepValueEquals(self, allocator, x.first.asPtrConst(), b.Pair.first.asPtrConst()) and
                try deepValueEquals(self, allocator, x.second.asPtrConst(), b.Pair.second.asPtrConst());
        },
        .Triple => |x| {
            if (b.* != .Triple) return Value.structuralEqBoxed(a, b);
            return try deepValueEquals(self, allocator, x.first.asPtrConst(), b.Triple.first.asPtrConst()) and
                try deepValueEquals(self, allocator, x.second.asPtrConst(), b.Triple.second.asPtrConst()) and
                try deepValueEquals(self, allocator, x.third.asPtrConst(), b.Triple.third.asPtrConst());
        },
        else => return Value.structuralEqBoxed(a, b),
    }
}

/// The elements of `items`, copied out of its borrow and rooted until the
/// caller restores its keepalive mark: user `equals` and `hashCode` run between
/// them and may reach a safe point, where no cell lock may be held, and may
/// change the collection.
fn rootedItems(allocator: Allocator, items: runtime.ValueList) Allocator.Error![]Value {
    const g = items.borrow();
    defer g.deinit();
    const xs = try allocator.dupe(Value, g.get().items);
    runtime.keepalivePushSlice(xs);
    return xs;
}

/// `rootedItems` for a map's entries.
fn rootedPairs(allocator: Allocator, entries: runtime.MapEntries) Allocator.Error![]runtime.MapPair {
    const g = entries.borrow();
    defer g.deinit();
    const ps = try allocator.dupe(runtime.MapPair, g.get().pairs.items);
    runtime.keepalivePushPairs(ps);
    return ps;
}

/// `kotlinHashCode` plus member dispatch: a container folds its elements' USER
/// `hashCode()`.
pub fn hashWithDispatch(self: *VmHost, allocator: Allocator, v: *const Value) Allocator.Error!i32 {
    switch (v.*) {
        .IrClosure => return closureRefHash(self, allocator, v),
        .PropertyRef => |pr| {
            const g = pr.name.borrow();
            defer g.deinit();
            return javaStringHash(g.get().bytes);
        },
        .Instance, .Exception => {
            const r = try host_resolved.wellKnownMember(self, allocator, v, .hash_code, &.{});
            switch (r) {
                .ok => |hv| {
                    if (hv == .Int) return @truncate(hv.Int);
                    return kotlinHashCode(v);
                },
                .err => return kotlinHashCode(v),
            }
        },
        .List => |l| {
            const mark = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(mark);
            const xs = try rootedItems(allocator, l.items);
            defer if (runtime.freeScratch()) allocator.free(xs);
            var h: i32 = 1;
            for (xs) |*e| h = h *% 31 +% try hashWithDispatch(self, allocator, e);
            return h;
        },
        .Array => |arr| {
            var h: i32 = 1;
            const n = arr.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var e = arr.get(i);
                h = h *% 31 +% try hashWithDispatch(self, allocator, &e);
            }
            return h;
        },
        .Set => |st| {
            const mark = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(mark);
            const xs = try rootedItems(allocator, st.items);
            defer if (runtime.freeScratch()) allocator.free(xs);
            var h: i32 = 0;
            for (xs) |*e| h = h +% try hashWithDispatch(self, allocator, e);
            return h;
        },
        .Map => |m| {
            const mark = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(mark);
            const ps = try rootedPairs(allocator, m.entries);
            defer if (runtime.freeScratch()) allocator.free(ps);
            var h: i32 = 0;
            for (ps) |*kv| h = h +% ((try hashWithDispatch(self, allocator, &kv.key)) ^ (try hashWithDispatch(self, allocator, &kv.value)));
            return h;
        },
        .Pair => |pr| return (try hashWithDispatch(self, allocator, pr.first.asPtrConst())) *% 31 +% try hashWithDispatch(self, allocator, pr.second.asPtrConst()),
        .Triple => |t| return ((try hashWithDispatch(self, allocator, t.first.asPtrConst())) *% 31 +% try hashWithDispatch(self, allocator, t.second.asPtrConst())) *% 31 +% try hashWithDispatch(self, allocator, t.third.asPtrConst()),
        .MapEntry => |e| return (try hashWithDispatch(self, allocator, e.key.asPtrConst())) ^ (try hashWithDispatch(self, allocator, e.value.asPtrConst())),
        else => return kotlinHashCode(v),
    }
}

pub fn kotlinHashCode(v: *const Value) i32 {
    return switch (v.*) {
        .Null => 0,
        .Bool => |b| if (b) @as(i32, 1231) else @as(i32, 1237),
        .Char => |c| @as(i32, c),
        .Byte => |x| @as(i32, x),
        .Short => |x| @as(i32, x),
        .Int => |x| x,
        // An unsigned value class hashes its SIGNED storage: 65535u hashes as -1.
        .UByte => |x| @as(i32, @as(i8, @bitCast(x))),
        .UShort => |x| @as(i32, @as(i16, @bitCast(x))),
        .UInt => |x| @bitCast(x),
        .Long => |l| @truncate(l ^ @as(i64, @bitCast(@as(u64, @bitCast(l)) >> 32))),
        .ULong => |u| @truncate(@as(i64, @bitCast(u ^ (u >> 32)))),
        // Java's to*Bits canonicalizes every NaN payload before hashing.
        .Float => |f| if (std.math.isNan(f)) @as(i32, @bitCast(@as(u32, 0x7fc0_0000))) else @bitCast(f),
        .Double => |d| blk: {
            const b: i64 = if (std.math.isNan(d)) @bitCast(@as(u64, 0x7ff8_0000_0000_0000)) else @bitCast(d);
            break :blk @truncate(b ^ @as(i64, @bitCast(@as(u64, @bitCast(b)) >> 32)));
        },
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            const bytes = g.get().bytes;
            var h: i32 = 0;
            const view = std.unicode.Utf8View.init(bytes) catch {
                for (bytes) |ch| h = h *% 31 +% @as(i32, ch);
                break :blk h;
            };
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp <= 0xFFFF) {
                    h = h *% 31 +% @as(i32, @intCast(cp));
                } else {
                    const v2 = cp - 0x10000;
                    const hi: i32 = @intCast(0xD800 + (v2 >> 10));
                    const lo: i32 = @intCast(0xDC00 + (v2 & 0x3FF));
                    h = h *% 31 +% hi;
                    h = h *% 31 +% lo;
                }
            }
            break :blk h;
        },
        .List => |l| blk: {
            const g = l.items.borrow();
            defer g.deinit();
            var h: i32 = 1;
            for (g.get().items) |e| h = h *% 31 +% kotlinHashCode(&e);
            break :blk h;
        },
        // Kotlin data-class hashCode: first*31 + second (+ *31 + third).
        .Pair => |p| kotlinHashCode(p.first.asPtrConst()) *% 31 +% kotlinHashCode(p.second.asPtrConst()),
        .Triple => |t| (kotlinHashCode(t.first.asPtrConst()) *% 31 +% kotlinHashCode(t.second.asPtrConst())) *% 31 +% kotlinHashCode(t.third.asPtrConst()),
        .Set => |s| blk: {
            const g = s.items.borrow();
            defer g.deinit();
            var h: i32 = 0;
            for (g.get().items) |e| h = h +% kotlinHashCode(&e);
            break :blk h;
        },
        .Map => |m| blk: {
            const g = m.entries.borrow();
            defer g.deinit();
            var h: i32 = 0;
            for (g.get().pairs.items) |kv| h = h +% (kotlinHashCode(&kv.key) ^ kotlinHashCode(&kv.value));
            break :blk h;
        },
        .Array => |arr| blk: {
            var h: i32 = 1;
            const n = arr.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var e = arr.get(i);
                h = h *% 31 +% kotlinHashCode(&e);
            }
            break :blk h;
        },
        .Range => |r| blk: {
            // Long/ULong fold high and low words (`v xor (v ushr 32)`); others truncate.
            const elem = struct {
                fn hash(kind: RangeKind, x: i64) i32 {
                    return switch (kind) {
                        .Long, .ULong => @truncate(x ^ @as(i64, @bitCast(@as(u64, @bitCast(x)) >> 32))),
                        .Int, .Char, .UInt => @truncate(x),
                    };
                }
            };
            const f: i32 = elem.hash(r.kind, r.start);
            const l: i32 = elem.hash(r.kind, r.end);
            const s: i32 = elem.hash(r.kind, r.step);
            const empty = if (r.step > 0) r.start > r.end else r.start < r.end;
            if (empty) break :blk @as(i32, -1);
            if (r.step == 1 and !r.progression) break :blk @as(i32, 31) *% f +% l;
            break :blk (@as(i32, 31) *% (@as(i32, 31) *% f +% l)) +% s;
        },
        // `Map.Entry.hashCode()` is `key xor value`; a Set of entries folds to the map's.
        .MapEntry => |e| kotlinHashCode(e.key.asPtrConst()) ^ kotlinHashCode(e.value.asPtrConst()),
        else => valueStructuralHash(v),
    };
}

/// Structural digest matching `Value.structuralEq`, folded to i32.
pub fn valueStructuralHash(v: *const Value) i32 {
    var h = std.hash.Wyhash.init(0);
    switch (v.*) {
        .Unit => h.update(std.mem.asBytes(&@as(i32, 0))),
        .Null => h.update(std.mem.asBytes(&@as(i32, 1))),
        .Bool => |b| {
            h.update(std.mem.asBytes(&@as(i32, 2)));
            h.update(std.mem.asBytes(&b));
        },
        .Char => |c| {
            h.update(std.mem.asBytes(&@as(i32, 3)));
            h.update(std.mem.asBytes(&c));
        },
        .Int => |i| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, i)));
        },
        .Long => |l| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&l));
        },
        .Short => |s| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, s)));
        },
        .Byte => |b| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, b)));
        },
        .UInt => |u| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, u)));
        },
        .ULong => |u| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&u));
        },
        .UShort => |u| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, u)));
        },
        .UByte => |u| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, u)));
        },
        .Float => |f| {
            h.update(std.mem.asBytes(&@as(i32, 5)));
            const bits: u32 = @bitCast(f);
            h.update(std.mem.asBytes(&bits));
        },
        .Double => |d| {
            h.update(std.mem.asBytes(&@as(i32, 5)));
            const bits: u64 = @bitCast(d);
            h.update(std.mem.asBytes(&bits));
        },
        .String => |s| {
            h.update(std.mem.asBytes(&@as(i32, 6)));
            const g = s.borrow();
            defer g.deinit();
            h.update(g.get().bytes);
        },
        .Class => |c| {
            h.update(std.mem.asBytes(&@as(i32, 8)));
            const ch = runtime.classHash(c);
            h.update(std.mem.asBytes(&ch));
        },
        else => h.update(std.mem.asBytes(&@as(i32, 7))),
    }
    return @truncate(@as(i64, @bitCast(h.final())));
}

fn rangeElem(cur: i64, kind: RangeKind) Value {
    return switch (kind) {
        .Int => Value.newInt(cur),
        .Long => .{ .Long = cur },
        .Char => .{ .Char = @truncate(@as(u64, @bitCast(cur))) },
        .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(cur))) },
        .ULong => .{ .ULong = @bitCast(cur) },
    };
}

/// Read a boxed component slot: the box keeps its `Value`, the caller gets a ref.
fn extractOwned(box: runtime.ObjRef(Value)) EvalResult {
    const out = box.asPtrConst().*;
    out.retain();
    return .{ .ok = out };
}

pub fn drainIterableToList(self: *VmHost, allocator: Allocator, receiver: *const Value) Allocator.Error!EvalResult {
    const iter_r = try host_resolved.wellKnownMember(self, allocator, receiver, .iterator, &.{});
    const iter = switch (iter_r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    // `iter` is owned (host-returns-owned): release it on every exit path.
    defer if (runtime.reclaimEnabled()) iter.release(allocator);
    // The iterator and the elements drained so far have no other owner
    // across the `hasNext`/`next` calls, which may collect.
    const mark = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(mark);
    runtime.keepalivePush(iter);
    var items: std.ArrayList(Value) = .empty;
    var guard: usize = 0;
    while (guard < 1_000_000) : (guard += 1) {
        const hn_r = try host_resolved.wellKnownMember(self, allocator, &iter, .has_next, &.{});
        const has = switch (hn_r) {
            .ok => |v| switch (v) {
                .Bool => |b| b,
                else => false,
            },
            .err => |e| {
                items.deinit(allocator);
                return .{ .err = e };
            },
        };
        if (!has) break;
        const nx_r = try host_resolved.wellKnownMember(self, allocator, &iter, .next, &.{});
        switch (nx_r) {
            .ok => |v| {
                runtime.keepalivePush(v);
                try items.append(allocator, v);
            },
            .err => |e| {
                items.deinit(allocator);
                return .{ .err = e };
            },
        }
    }
    return .{ .ok = try Value.newList(allocator, .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    }) };
}

fn materialiseSequence(self: *VmHost, allocator: Allocator, seq_val: *const Value) Allocator.Error!union(enum) { ok: std.ArrayList(Value), err: EvalError } {
    var sink = self.out_sink;
    var intrinsic = VmIntrinsicHost.owning(self);
    defer intrinsic.release();
    const ihost = intrinsic.intrinsicHost();
    const outcome = try stdlib.materialise_sequence(allocator, ihost, sink.output(), seq_val.*);
    switch (outcome) {
        .items => |items| {
            var list: std.ArrayList(Value) = .empty;
            try list.appendSlice(allocator, items);
            return .{ .ok = list };
        },
        .err => |e| return .{ .err = try mapRuntimeError(allocator, e) },
    }
}

/// Owned, element-retained `ArrayList` copy of an `Array` for a new wrapper.
fn cloneArrayItems(allocator: Allocator, arr: runtime.ArrayData) Allocator.Error!std.ArrayList(Value) {
    const snap = try arr.snapshot(allocator);
    defer if (runtime.freeScratch()) allocator.free(snap);
    var out: std.ArrayList(Value) = .empty;
    try out.appendSlice(allocator, snap);
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return out;
}

pub fn builtinIterator(allocator: Allocator, receiver: *const Value) Allocator.Error!?EvalResult {
    // An array `.asList()` view re-reads its source, so writes show through.
    receiver.refreshArrayView();
    receiver.refreshSublistView();
    switch (receiver.*) {
        .List => |l| {
            if (stdlib.implementations.collections.sublistViewStale(receiver)) {
                return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
            }
            // A mutable list shares its backing, so `remove()` mutates the source.
            if (l.mutable and !stdlib.implementations.collections.modCountFrozen(l.mod_count)) {
                const cap = try captureModCount(allocator, l.mod_count.get());
                return .{ .ok = try Value.newIterator(allocator, .{ .items = l.items.clone(), .prim = null, .mod_count = .from(cap.mod_count), .mutable = true, .pos = 0, .exp_mod = cap.exp_mod }) };
            }
            // A snapshot iterator still captures `mod_count` to fail fast.
            const items = try cloneItemsList(allocator, l.items);
            const cap = try captureModCount(allocator, l.mod_count.get());
            return .{ .ok = try Value.newIterator(allocator, .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .prim = null, .mod_count = .from(cap.mod_count), .pos = 0, .exp_mod = cap.exp_mod }) };
        },
        .Set => |s| {
            // A mutable set, including a live map view, shares its backing.
            if (s.mutable and !stdlib.implementations.collections.modCountFrozen(s.mod_count)) {
                const cap = try captureModCount(allocator, s.mod_count.get());
                return .{ .ok = try Value.newIterator(allocator, .{ .items = s.items.clone(), .prim = null, .mod_count = .from(cap.mod_count), .mutable = true, .pos = 0, .exp_mod = cap.exp_mod }) };
            }
            const items = try cloneItemsList(allocator, s.items);
            const cap = try captureModCount(allocator, s.mod_count.get());
            return .{ .ok = try Value.newIterator(allocator, .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .prim = null, .mod_count = .from(cap.mod_count), .pos = 0, .exp_mod = cap.exp_mod }) };
        },
        .Map => |m| {
            const g = m.entries.borrow();
            const src_mc = g.get().mod_count;
            const live = m.mutable and !stdlib.implementations.collections.modCountFrozen(src_mc);
            const stamp: u64 = blk: {
                const cell = src_mc.get() orelse break :blk 0;
                const cg = cell.borrow();
                defer cg.deinit();
                break :blk cg.get().*;
            };
            var items: std.ArrayList(Value) = .empty;
            for (g.get().pairs.items) |kv| {
                kv.key.retain();
                kv.value.retain();
                const k = try Value.boxRef(allocator, kv.key);
                const v = try Value.boxRef(allocator, kv.value);
                // Live entries: `setValue` writes through, `remove` deletes.
                try items.append(allocator, try Value.newMapEntry(allocator, .{ .key = k, .value = v, .backing = if (live) .from(m.entries) else .{}, .exp_mod = stamp }));
            }
            g.deinit();
            const cap = try captureModCount(allocator, src_mc.get());
            return .{ .ok = try Value.newIterator(allocator, .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .prim = null, .mod_count = .from(cap.mod_count), .mutable = live, .pos = 0, .exp_mod = cap.exp_mod }) };
        },
        .Range => |r| {
            return .{ .ok = .{ .RangeIter = try ObjRef(runtime.RangeIterState).init(allocator, .{ .cur = r.start, .end = r.end, .step = r.step, .kind = r.kind }) } };
        },
        .Array => |arr| {
            const items = try cloneArrayItems(allocator, arr);
            return .{ .ok = try Value.newIterator(allocator, .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .prim = arr.primKind(), .pos = 0, .exp_mod = 0 }) };
        },
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            var items: std.ArrayList(Value) = .empty;
            const view = std.unicode.Utf8View.init(g.get().bytes) catch {
                for (g.get().bytes) |b| try items.append(allocator, .{ .Char = b });
                return .{ .ok = try Value.newIterator(allocator, .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .prim = null, .pos = 0, .exp_mod = 0 }) };
            };
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp <= 0xFFFF) {
                    try items.append(allocator, .{ .Char = @intCast(cp) });
                } else {
                    const v2 = cp - 0x10000;
                    try items.append(allocator, .{ .Char = @intCast(0xD800 + (v2 >> 10)) });
                    try items.append(allocator, .{ .Char = @intCast(0xDC00 + (v2 & 0x3FF)) });
                }
            }
            return .{ .ok = try Value.newIterator(allocator, .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .prim = null, .pos = 0, .exp_mod = 0 }) };
        },
        else => return null,
    }
}

/// `Sequence.iterator()`: a builder sequence gets a fresh coroutine cursor
/// per call; any other sequence is iterated once.
pub fn sequenceIterator(self: *VmHost, allocator: Allocator, receiver: *const Value) Allocator.Error!EvalResult {
    {
        var intrinsic = VmIntrinsicHost.owning(self);
        defer intrinsic.release();
        const ihost = intrinsic.intrinsicHost();
        if (try stdlib.freshBuilderSeq(ihost, allocator, receiver.*)) |fresh| {
            return .{ .ok = try stdlib.makeSeqIter(allocator, fresh) };
        }
    }
    if (stdlib.oneShotConsumeCheck(allocator, receiver.*) catch null) |re| {
        return .{ .err = try mapRuntimeError(allocator, re) };
    }
    var sv = receiver.*;
    if (runtime.reclaimEnabled()) sv.retain();
    return .{ .ok = try stdlib.makeSeqIter(allocator, sv) };
}

pub const Ordering = enum { lt, eq, gt };

fn flipOrd(o: Ordering) Ordering {
    return switch (o) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

fn ordToInt(o: Ordering) i64 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// Natural-order compare, falling back to a user `compareTo` for non-builtins.
fn compareValuesHostAware(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) Allocator.Error!union(enum) { ord: Ordering, err: EvalError } {
    if (compareValuesBuiltin(a, b)) |o| return .{ .ord = o };
    const r = try host_resolved.wellKnownMember(self, allocator, a, .compare_to, &.{b.*});
    switch (r) {
        .ok => |v| {
            const i = v.asI64() orelse return .{ .err = try typeErr(allocator, "incomparable values", .{}) };
            return .{ .ord = if (i < 0) .lt else if (i > 0) .gt else .eq };
        },
        .err => |e| return .{ .err = e },
    }
}

/// Builtin natural-order comparison; null when the pair is not builtin-comparable.
pub fn compareValuesBuiltin(a: *const Value, b: *const Value) ?Ordering {
    // Kotlin `compareValues` orders null first (null < non-null, null == null).
    if (a.* == .Null or b.* == .Null) {
        if (a.* == .Null and b.* == .Null) return .eq;
        return if (a.* == .Null) .lt else .gt;
    }
    if (a.* == .String and b.* == .String) {
        const ag = a.String.borrow();
        defer ag.deinit();
        const bg = b.String.borrow();
        defer bg.deinit();
        return switch (std.mem.order(u8, ag.get().bytes, bg.get().bytes)) {
            .lt => .lt,
            .eq => .eq,
            .gt => .gt,
        };
    }
    if (a.* == .Bool and b.* == .Bool) {
        const x: u8 = @intFromBool(a.Bool);
        const y: u8 = @intFromBool(b.Bool);
        return if (x < y) .lt else if (x > y) .gt else .eq;
    }
    if (a.isFloating() or b.isFloating()) {
        const x = floatOf(a) orelse return null;
        const y = floatOf(b) orelse return null;
        return kotlinFloatTotalCmp(x, y);
    }
    if (a.isUnsigned() and b.isUnsigned()) {
        const x = a.asU64() orelse return null;
        const y = b.asU64() orelse return null;
        return if (x < y) .lt else if (x > y) .gt else .eq;
    }
    const x = a.asI64() orelse (if (a.* == .Char) @as(i64, a.Char) else return null);
    const y = b.asI64() orelse (if (b.* == .Char) @as(i64, b.Char) else return null);
    return if (x < y) .lt else if (x > y) .gt else .eq;
}

/// Total order over IEEE-754 doubles matching Kotlin's `Double.compareTo`:
/// `-0.0 < 0.0` and every `NaN` sorts above `+Infinity`.
fn kotlinFloatTotalCmp(a: f64, b: f64) Ordering {
    if (a < b) return .lt;
    if (a > b) return .gt;
    const bits = struct {
        fn of(x: f64) i64 {
            if (std.math.isNan(x)) return @bitCast(@as(u64, 0x7ff8_0000_0000_0000));
            return @bitCast(x);
        }
    };
    return switch (std.math.order(bits.of(a), bits.of(b))) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

fn floatOf(v: *const Value) ?f64 {
    return switch (v.*) {
        .Double => |d| d,
        .Float => |f| @as(f64, f),
        else => if (v.asI64()) |i| @as(f64, @floatFromInt(i)) else null,
    };
}

pub fn comparatorMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const cmp = receiver.Comparator;
    // `Comparator` is a `fun interface`, so `invoke` also calls `compare`.
    if ((std.mem.eql(u8, name, "compare") or std.mem.eql(u8, name, "invoke")) and args.len == 2) {
        const a = args[0];
        const b = args[1];
        var ord: Ordering = .eq;
        const sg = cmp.steps.borrow();
        const steps = sg.get().*;
        const descending = cmp.descending;
        sg.deinit();
        if (steps.len == 0) {
            ord = switch (try compareValuesHostAware(self, allocator, &a, &b)) {
                .ord => |o| o,
                .err => |e| return .{ .err = e },
            };
        } else {
            for (steps) |step| {
                const sel = step.selector;
                const n_params: usize = switch (sel) {
                    .IrClosure => |c| blk: {
                        if (self.closures.get(@intCast(c.asPtrConst().id))) |info| break :blk info.n_params;
                        break :blk 1;
                    },
                    else => 1,
                };
                const o: Ordering = if (n_params >= 2) blk: {
                    const r = try host_call_value.callValue(self, allocator, &sel, &.{ a, b });
                    const nval: i64 = switch (r) {
                        .ok => |v| v.asI64() orelse 0,
                        .err => |e| return .{ .err = e },
                    };
                    break :blk if (nval < 0) .lt else if (nval > 0) .gt else .eq;
                } else blk: {
                    const ka_r = try host_call_value.callValue(self, allocator, &sel, &.{a});
                    const ka = switch (ka_r) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    const kb_r = try host_call_value.callValue(self, allocator, &sel, &.{b});
                    const kb = switch (kb_r) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    if (step.key_comparator) |kc| {
                        const r = try host_resolved.wellKnownMember(self, allocator, &kc, .compare, &.{ ka, kb });
                        const nval: i64 = switch (r) {
                            .ok => |v| v.asI64() orelse 0,
                            .err => |e| return .{ .err = e },
                        };
                        break :blk if (nval < 0) .lt else if (nval > 0) .gt else .eq;
                    }
                    break :blk switch (try compareValuesHostAware(self, allocator, &ka, &kb)) {
                        .ord => |o| o,
                        .err => |e| return .{ .err = e },
                    };
                };
                const flipped = if (step.descending) flipOrd(o) else o;
                if (flipped != .eq) {
                    ord = flipped;
                    break;
                }
            }
        }
        if (descending) ord = flipOrd(ord);
        return .{ .ok = Value.newInt(ordToInt(ord)) };
    }
    if ((std.mem.eql(u8, name, "thenBy") or std.mem.eql(u8, name, "thenByDescending")) and args.len == 1) {
        const sg = cmp.steps.borrow();
        var chain = try allocator.alloc(ComparatorStep, sg.get().len + 1);
        @memcpy(chain[0..sg.get().len], sg.get().*);
        chain[sg.get().len] = .{ .selector = args[0], .descending = std.mem.eql(u8, name, "thenByDescending") };
        sg.deinit();
        return .{ .ok = try Value.newComparator(allocator, .{ .steps = try ObjRef([]ComparatorStep).init(allocator, chain), .descending = cmp.descending }) };
    }
    if ((std.mem.eql(u8, name, "then") or std.mem.eql(u8, name, "thenComparing") or
        std.mem.eql(u8, name, "thenDescending") or std.mem.eql(u8, name, "thenComparator")) and args.len == 1)
    {
        const invert = std.mem.eql(u8, name, "thenDescending");
        switch (args[0]) {
            .Comparator => |other| {
                const sg = cmp.steps.borrow();
                const og = other.steps.borrow();
                var chain = try allocator.alloc(ComparatorStep, sg.get().len + og.get().len);
                @memcpy(chain[0..sg.get().len], sg.get().*);
                for (og.get().*, 0..) |st, i| {
                    chain[sg.get().len + i] = .{ .selector = st.selector, .descending = (st.descending != other.descending) != invert };
                }
                og.deinit();
                sg.deinit();
                return .{ .ok = try Value.newComparator(allocator, .{ .steps = try ObjRef([]ComparatorStep).init(allocator, chain), .descending = cmp.descending }) };
            },
            .IrClosure => {
                const sg = cmp.steps.borrow();
                var chain = try allocator.alloc(ComparatorStep, sg.get().len + 1);
                @memcpy(chain[0..sg.get().len], sg.get().*);
                chain[sg.get().len] = .{ .selector = args[0], .descending = invert };
                sg.deinit();
                return .{ .ok = try Value.newComparator(allocator, .{ .steps = try ObjRef([]ComparatorStep).init(allocator, chain), .descending = cmp.descending }) };
            },
            else => {},
        }
    }
    if (std.mem.eql(u8, name, "reversed") and args.len == 0) {
        return .{ .ok = try Value.newComparator(allocator, .{ .steps = cmp.steps.clone(), .descending = !cmp.descending }) };
    }
    return null;
}

pub fn arrayShapeOps(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    _ = self;
    const arr = receiver.Array;
    if (std.mem.eql(u8, name, "toList") and args.len == 0) {
        const items = try cloneArrayItems(allocator, arr);
        return .{ .ok = try listOf(allocator, items, false) };
    }
    if (std.mem.eql(u8, name, "toMutableList") and args.len == 0) {
        const items = try cloneArrayItems(allocator, arr);
        return .{ .ok = try listOf(allocator, items, true) };
    }
    if (std.mem.eql(u8, name, "asList") and args.len == 0) {
        // Read-only fixed-size live view; element writes show through.
        return .{ .ok = try stdlib.implementations.collections.arrayAsListView(allocator, arr) };
    }
    if (std.mem.eql(u8, name, "toTypedArray") and args.len == 0) {
        const items = try cloneArrayItems(allocator, arr);
        return .{ .ok = runtime.ArrayData.fromBoxedList(try ObjRef(std.ArrayList(Value)).init(allocator, items)) };
    }
    if (std.mem.eql(u8, name, "toSet") and args.len == 0) {
        const items = try cloneArrayItems(allocator, arr);
        return .{ .ok = try Value.newSet(allocator, .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .mutable = false, .backing = null }) };
    }
    if (std.mem.eql(u8, name, "concatToString") and (args.len == 0 or args.len == 2)) {
        const chars = try arr.snapshot(allocator);
        defer if (runtime.freeScratch()) allocator.free(chars);
        var start: usize = 0;
        var end: usize = chars.len;
        if (args.len == 2) {
            const si = args[0].asI64() orelse 0;
            const ei = args[1].asI64() orelse @as(i64, @intCast(chars.len));
            const size: i64 = @intCast(chars.len);
            // `checkBoundsIndexes`: out-of-range bounds throw
            // IndexOutOfBoundsException, an inverted range IllegalArgumentException.
            if (si < 0 or ei > size) {
                const msg = try std.fmt.allocPrint(allocator, "startIndex: {d}, endIndex: {d}, size: {d}", .{ si, ei, size });
                return .{ .err = try throwExc(allocator, "kotlin.IndexOutOfBoundsException", msg) };
            }
            if (si > ei) {
                const msg = try std.fmt.allocPrint(allocator, "startIndex: {d} > endIndex: {d}", .{ si, ei });
                return .{ .err = try throwExc(allocator, "kotlin.IllegalArgumentException", msg) };
            }
            start = @intCast(si);
            end = @intCast(ei);
        }
        var units: std.ArrayList(u16) = .empty;
        defer units.deinit(allocator);
        var i = start;
        while (i < @max(end, start)) : (i += 1) {
            if (chars[i] == .Char) try units.append(allocator, chars[i].Char);
        }
        const s = try runtime.charUnitsToString(allocator, units.items);
        return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
    }
    return null;
}

pub fn componentMembers(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    switch (receiver.*) {
        .Pair => |p| {
            if (std.mem.eql(u8, name, "component1") or std.mem.eql(u8, name, "first")) return extractOwned(p.first);
            if (std.mem.eql(u8, name, "component2") or std.mem.eql(u8, name, "second")) return extractOwned(p.second);
            if (std.mem.eql(u8, name, "equals") and args.len == 1) return .{ .ok = boolVal(Value.structuralEq(receiver, &args[0])) };
            if (std.mem.eql(u8, name, "hashCode") and args.len == 0) return .{ .ok = .{ .Int = kotlinHashCode(receiver) } };
        },
        .Triple => |t| {
            if (std.mem.eql(u8, name, "component1") or std.mem.eql(u8, name, "first")) return extractOwned(t.first);
            if (std.mem.eql(u8, name, "component2") or std.mem.eql(u8, name, "second")) return extractOwned(t.second);
            if (std.mem.eql(u8, name, "component3") or std.mem.eql(u8, name, "third")) return extractOwned(t.third);
            if (std.mem.eql(u8, name, "equals") and args.len == 1) return .{ .ok = boolVal(Value.structuralEq(receiver, &args[0])) };
            if (std.mem.eql(u8, name, "hashCode") and args.len == 0) return .{ .ok = .{ .Int = kotlinHashCode(receiver) } };
        },
        .MapEntry => |me| {
            // A live entry views the backing set: a structural map change makes
            // every access throw CME, and reads before that see the live pair.
            if (me.backing.get()) |entries| {
                const g = entries.borrow();
                var stale = false;
                if (g.get().mod_count.get()) |cell| {
                    const cg = cell.borrow();
                    stale = cg.get().* != me.exp_mod;
                    cg.deinit();
                }
                if (stale) {
                    g.deinit();
                    return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
                }
                var live: ?Value = null;
                for (g.get().pairs.items) |*slot| {
                    if (Value.structuralEq(&slot.key, me.key.asPtrConst())) {
                        live = slot.value;
                        break;
                    }
                }
                g.deinit();
                // The box is a cell of its own: the refreshed value is stored under its lock.
                if (live) |lv| {
                    const vg = me.value.borrowMut();
                    defer vg.deinit();
                    if (!Value.structuralEq(vg.get(), &lv)) {
                        if (runtime.reclaimEnabled()) {
                            lv.retain();
                            vg.get().release(allocator);
                        }
                        vg.get().* = lv;
                    }
                }
            }
            if (std.mem.eql(u8, name, "component1") or std.mem.eql(u8, name, "key")) return extractOwned(me.key);
            if (std.mem.eql(u8, name, "component2") or std.mem.eql(u8, name, "value")) return extractOwned(me.value);
            // `Map.Entry` equality is by key and value, builtin or user alike.
            if (std.mem.eql(u8, name, "equals") and args.len == 1) {
                if (try host_resolved.entryEquals(self, allocator, me.key.asPtrConst(), me.value.asPtrConst(), &args[0])) |r| return r;
                return .{ .ok = boolVal(Value.structuralEqBoxed(receiver, &args[0])) };
            }
            if (std.mem.eql(u8, name, "hashCode") and args.len == 0) return .{ .ok = .{ .Int = kotlinHashCode(receiver) } };
            if (std.mem.eql(u8, name, "setValue")) {
                // No backing means a read-only map's entry: mutation throws.
                if (!me.backing.isSome()) {
                    return .{ .err = try throwExc(allocator, "kotlin.UnsupportedOperationException", null) };
                }
                const new_v = if (args.len > 0) args[0] else Value.Unit;
                const prev = me.value.asPtrConst().*;
                // host-returns-owned: the old value escapes as the result.
                if (runtime.reclaimEnabled()) prev.retain();
                if (me.backing.get()) |entries| {
                    const g = entries.borrowMut();
                    defer g.deinit();
                    for (g.get().pairs.items) |*slot| {
                        if (Value.structuralEq(&slot.key, me.key.asPtrConst())) {
                            // The slot owns its value: release the old, retain the new.
                            if (runtime.reclaimEnabled()) {
                                new_v.retain();
                                slot.value.release(allocator);
                            }
                            slot.value = new_v;
                            break;
                        }
                    }
                }
                return .{ .ok = prev };
            }
        },
        .Instance => {
            if (std.mem.eql(u8, name, "component1") and
                host_resolved.instanceImplements(self, receiver, hostClasses(self).map_entry))
            {
                // getFieldRec borrows; this escapes, so retain.
                var r = try host_resolved.wellKnownMember(self, allocator, receiver, .entry_key, &.{});
                if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
                return r;
            }
            if (std.mem.eql(u8, name, "component2") and
                host_resolved.instanceImplements(self, receiver, hostClasses(self).map_entry))
            {
                var r = try host_resolved.wellKnownMember(self, allocator, receiver, .entry_value, &.{});
                if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
                return r;
            }
        },
        else => {},
    }
    return null;
}

/// Current structural counter of a map's entries store (0 when uncounted).
fn mapEntriesCounter(entries: runtime.MapEntries) u64 {
    const g = entries.borrow();
    defer g.deinit();
    const cell = g.get().mod_count.get() orelse return 0;
    const cg = cell.borrow();
    defer cg.deinit();
    return cg.get().*;
}

const ModCapture = struct { mod_count: ?ObjRef(u64), exp_mod: u64 };

/// A list's shared `mod_count` and its value, the iterator's expectation.
pub fn captureModCount(allocator: Allocator, src: ?ObjRef(u64)) Allocator.Error!ModCapture {
    _ = allocator;
    const mc = src orelse return .{ .mod_count = null, .exp_mod = 0 };
    const cur = blk: {
        const g = mc.borrow();
        defer g.deinit();
        break :blk g.get().*;
    };
    return .{ .mod_count = mc.clone(), .exp_mod = cur };
}

/// `ConcurrentModificationException` when the source mutated since capture.
fn iteratorCheckMod(allocator: Allocator, it: anytype) Allocator.Error!?EvalResult {
    const mc = iterModCount(it).get() orelse return null;
    const cur = blk: {
        const g = mc.borrow();
        defer g.deinit();
        break :blk g.get().*;
    };
    const exp = blk: {
        const g = it.borrow();
        defer g.deinit();
        break :blk g.get().exp_mod;
    };
    if (cur != exp) return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
    return null;
}

/// Resync the expectation after the iterator's OWN structural mutation.
fn iteratorResyncMod(it: anytype) void {
    const mc = iterModCount(it).get() orelse return;
    const cur = blk: {
        const g = mc.borrow();
        defer g.deinit();
        break :blk g.get().*;
    };
    const g = it.borrowMut();
    defer g.deinit();
    g.get().exp_mod = cur;
}

/// The iterator's own `add`/`remove` bypasses the list intrinsics: bump the
/// shared `mod_count`, then resync this iterator.
fn iteratorOwnStructuralMod(it: anytype) void {
    if (iterModCount(it).get()) |mc| {
        const g = mc.borrowMut();
        g.get().* +%= 1;
        g.deinit();
    }
    iteratorResyncMod(it);
}

fn iteratorSetLast(it: anytype, idx: i64) void {
    const g = it.borrowMut();
    defer g.deinit();
    g.get().last_ret = idx;
}

/// Index the last `next()`/`previous()` returned, or -1 when none.
fn iteratorLastRet(it: anytype) i64 {
    const g = it.borrow();
    defer g.deinit();
    return g.get().last_ret;
}

/// Unretained handle copies out of one borrow, valid while the receiver's
/// `ObjRef(IterCursor)` keeps the cell alive.
inline fn iterItems(it: ObjRef(runtime.IterCursor)) runtime.ValueList {
    const g = it.borrow();
    defer g.deinit();
    return g.get().items;
}

inline fn iterModCount(it: ObjRef(runtime.IterCursor)) @FieldType(runtime.IterCursor, "mod_count") {
    const g = it.borrow();
    defer g.deinit();
    return g.get().mod_count;
}

inline fn iterMutable(it: ObjRef(runtime.IterCursor)) bool {
    const g = it.borrow();
    defer g.deinit();
    return g.get().mutable;
}

pub fn iteratorMember(allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const it = receiver.Iterator;
    if (std.mem.eql(u8, name, "hasNext") and args.len == 0) {
        const pg = it.borrow();
        const p = pg.get().pos;
        pg.deinit();
        const ig = iterItems(it).borrow();
        const len = ig.get().items.len;
        ig.deinit();
        return .{ .ok = boolVal(p < len) };
    }
    if (isIteratorNext(name) and args.len == 0) {
        if (try iteratorCheckMod(allocator, it)) |e| return e;
        const pg = it.borrow();
        const p = pg.get().pos;
        pg.deinit();
        const ig = iterItems(it).borrow();
        if (p >= ig.get().items.len) {
            ig.deinit();
            return .{ .err = try throwExc(allocator, "kotlin.NoSuchElementException", "iterator exhausted") };
        }
        var v = ig.get().items[p];
        // A live map entry is re-stamped at yield, so later ones stay readable.
        if (v == .MapEntry) {
            if (v.MapEntry.backing.get()) |entries| {
                v.MapEntry.exp_mod = mapEntriesCounter(entries);
            }
        }
        // Borrowed element: retain before the register takes ownership.
        if (runtime.reclaimEnabled()) v.retain();
        ig.deinit();
        const pmg = it.borrowMut();
        pmg.get().pos = p + 1;
        pmg.deinit();
        iteratorSetLast(it, @intCast(p));
        if (runtime.envSetOnce("KLIO_ITER_TRACE")) {
            std.debug.print("[iter-next] kind={s}\n", .{@tagName(std.meta.activeTag(v))});
        }
        return .{ .ok = v };
    }
    if (std.mem.eql(u8, name, "hasPrevious") and args.len == 0) {
        const pg = it.borrow();
        defer pg.deinit();
        return .{ .ok = boolVal(pg.get().pos > 0) };
    }
    if (std.mem.eql(u8, name, "nextIndex") and args.len == 0) {
        const pg = it.borrow();
        defer pg.deinit();
        return .{ .ok = Value.newInt(@intCast(pg.get().pos)) };
    }
    if (std.mem.eql(u8, name, "previousIndex") and args.len == 0) {
        const pg = it.borrow();
        defer pg.deinit();
        return .{ .ok = Value.newInt(@as(i64, @intCast(pg.get().pos)) - 1) };
    }
    if (std.mem.eql(u8, name, "previous") and args.len == 0) {
        if (try iteratorCheckMod(allocator, it)) |e| return e;
        const pg = it.borrow();
        const p = pg.get().pos;
        pg.deinit();
        if (p == 0) {
            return .{ .err = try throwExc(allocator, "kotlin.NoSuchElementException", "iterator at start") };
        }
        const ig = iterItems(it).borrow();
        const v = ig.get().items[p - 1];
        if (runtime.reclaimEnabled()) v.retain();
        ig.deinit();
        const pmg = it.borrowMut();
        pmg.get().pos = p - 1;
        pmg.deinit();
        iteratorSetLast(it, @as(i64, @intCast(p)) - 1);
        return .{ .ok = v };
    }
    // `MutableListIterator.set(x)` overwrites the element last returned.
    if (std.mem.eql(u8, name, "set") and args.len == 1) {
        // CME before the read-only guard: an immutable iterator falls through.
        if (try iteratorCheckMod(allocator, it)) |e| return e;
        if (!iterMutable(it)) return .{ .err = try throwExc(allocator, "kotlin.UnsupportedOperationException", null) };
        const li = iteratorLastRet(it);
        if (li < 0) {
            return .{ .err = try throwExc(allocator, "kotlin.IllegalStateException", "set() called before next()/previous()") };
        }
        const lu: usize = @intCast(li);
        const g = iterItems(it).borrowMut();
        defer g.deinit();
        if (lu < g.get().items.len) {
            if (runtime.reclaimEnabled()) g.get().items[lu].release(allocator);
            var nv = args[0];
            if (runtime.reclaimEnabled()) nv.retain();
            g.get().items[lu] = nv;
        }
        return .{ .ok = .Unit };
    }
    // `add(x)` inserts at the cursor and advances, so the next `next()` skips it.
    if (std.mem.eql(u8, name, "add") and args.len == 1) {
        if (try iteratorCheckMod(allocator, it)) |e| return e;
        if (!iterMutable(it)) return .{ .err = try throwExc(allocator, "kotlin.UnsupportedOperationException", null) };
        const pg = it.borrow();
        const p = pg.get().pos;
        pg.deinit();
        const g = iterItems(it).borrowMut();
        defer g.deinit();
        var nv = args[0];
        if (runtime.reclaimEnabled()) nv.retain();
        const idx = if (p <= g.get().items.len) p else g.get().items.len;
        try g.get().insert(allocator, idx, nv);
        const pmg = it.borrowMut();
        pmg.get().pos = p + 1;
        pmg.deinit();
        iteratorSetLast(it, -1);
        iteratorOwnStructuralMod(it);
        return .{ .ok = .Unit };
    }
    // `remove()` drops the element last returned (`pos - 1`) and rewinds.
    if (std.mem.eql(u8, name, "remove") and args.len == 0) {
        if (try iteratorCheckMod(allocator, it)) |e| return e;
        if (!iterMutable(it)) return .{ .err = try throwExc(allocator, "kotlin.UnsupportedOperationException", null) };
        const pg = it.borrow();
        const p = pg.get().pos;
        pg.deinit();
        const li = iteratorLastRet(it);
        if (li < 0) {
            return .{ .err = try throwExc(allocator, "kotlin.IllegalStateException", "remove() called before next()") };
        }
        const lu: usize = @intCast(li);
        const g = iterItems(it).borrowMut();
        defer g.deinit();
        if (lu < g.get().items.len) {
            const removed = g.get().items[lu];
            // A live entry: delete it from the backing map by key as well.
            if (removed == .MapEntry) {
                if (removed.MapEntry.backing.get()) |entries| {
                    const eg = entries.borrowMut();
                    defer eg.deinit();
                    const key = removed.MapEntry.key.asPtrConst();
                    for (eg.get().pairs.items, 0..) |*slot, i| {
                        if (Value.structuralEq(&slot.key, key)) {
                            if (runtime.reclaimEnabled()) {
                                slot.key.release(allocator);
                                slot.value.release(allocator);
                            }
                            _ = eg.get().removeAt(i);
                            break;
                        }
                    }
                }
            }
            _ = g.get().orderedRemove(lu);
            // The cursor slides back only when the removed slot was BEFORE it.
            if (lu < p) {
                const pmg = it.borrowMut();
                pmg.get().pos = p - 1;
                pmg.deinit();
            }
            iteratorSetLast(it, -1);
            iteratorOwnStructuralMod(it);
        }
        return .{ .ok = .Unit };
    }
    return null;
}

pub fn rangeIterMember(allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const ri = receiver.RangeIter;
    const snap = blk: {
        const sg = ri.borrow();
        defer sg.deinit();
        break :blk sg.get().*;
    };
    const more = !snap.done and snap.step != 0 and snap.kind.inBounds(snap.cur, snap.end, snap.step);
    if (std.mem.eql(u8, name, "hasNext") and args.len == 0) {
        return .{ .ok = boolVal(more) };
    }
    if (isIteratorNext(name) and args.len == 0) {
        if (!more) return .{ .err = try throwExc(allocator, "kotlin.NoSuchElementException", "iterator exhausted") };
        const c = snap.cur;
        // A ULong cursor wraps in the unsigned domain; `wrapped` detects that.
        const adv = if (snap.kind == .ULong) c +% snap.step else c +| snap.step;
        const wrapped = snap.kind == .ULong and
            (if (snap.step > 0) @as(u64, @bitCast(adv)) < @as(u64, @bitCast(c)) else @as(u64, @bitCast(adv)) > @as(u64, @bitCast(c)));
        // Stop once `end` (the exact final element) is yielded or the cursor
        // saturates: `more` is unsigned for ULong and would miss the wrap.
        const sg = ri.borrowMut();
        if (c == snap.end or adv == c or wrapped) {
            sg.get().done = true;
        } else {
            sg.get().cur = adv;
        }
        sg.deinit();
        return .{ .ok = rangeElem(c, snap.kind) };
    }
    return null;
}

// Lazy `SeqIter`: the `Sequence.iterator()` / `iterator { }` result, one pull per step.

const SeqIterState = runtime.SeqIterState;

fn seqIterEnsureState(allocator: Allocator, st: *SeqIterState, n_ops: usize) Allocator.Error!void {
    if (st.taken.len == n_ops or n_ops == 0) return;
    st.taken = try allocator.alloc(usize, n_ops);
    st.dropped = try allocator.alloc(usize, n_ops);
    st.take_while_live = try allocator.alloc(bool, n_ops);
    st.drop_while_live = try allocator.alloc(bool, n_ops);
    st.indices = try allocator.alloc(usize, n_ops);
    @memset(st.taken, 0);
    @memset(st.dropped, 0);
    @memset(st.take_while_live, true);
    @memset(st.drop_while_live, true);
    @memset(st.indices, 0);
}

/// Pull one raw element from the sequence source, before ops; null at exhaustion.
fn seqIterSourcePull(self: *VmHost, allocator: Allocator, st: *SeqIterState, out: runtime.Output) Allocator.Error!union(enum) { value: Value, done, err: EvalError } {
    const sg = st.seq.Sequence.borrow();
    const src = sg.get().source;
    sg.deinit();
    switch (src) {
        .Items => |v| {
            const g = v.borrow();
            defer g.deinit();
            const items = g.get().*;
            const i = st.src_pos;
            if (i >= items.len) return .done;
            st.src_pos = i + 1;
            var e = items[i];
            if (runtime.reclaimEnabled()) e.retain();
            return .{ .value = e };
        },
        .Builder => |bstate| {
            var intrinsic = VmIntrinsicHost.owning(self);
            defer intrinsic.release();
            const ihost = intrinsic.intrinsicHost();
            const step = try ihost.builderStep(bstate, out);
            return switch (step) {
                .value => |val| .{ .value = val },
                .done => .done,
                .err => |re| .{ .err = try mapRuntimeError(allocator, re) },
            };
        },
        .IteratorFn => |fnbox| {
            if (st.done) return .done;
            var intrinsic = VmIntrinsicHost.owning(self);
            defer intrinsic.release();
            const ihost = intrinsic.intrinsicHost();
            if (st.iter_obj == null) {
                const r = try ihost.invokeCallable(fnbox.asPtrConst(), &.{}, out);
                switch (r) {
                    .ok => |v| st.setValue("iter_obj", v),
                    .err => |re| return .{ .err = try mapRuntimeError(allocator, re) },
                }
            }
            const iter = st.iter_obj.?;
            const hn = try host_resolved.wellKnownMember(self, allocator, &iter, .has_next, &.{});
            const has = switch (hn) {
                .ok => |x| x == .Bool and x.Bool,
                .err => |e| return .{ .err = e },
            };
            if (!has) {
                st.done = true;
                return .done;
            }
            const nx = try host_resolved.wellKnownMember(self, allocator, &iter, .next, &.{});
            return switch (nx) {
                .ok => |v| .{ .value = v },
                .err => |e| .{ .err = e },
            };
        },
        .Merged => |mz| {
            if (st.done) return .done;
            if (st.iter_left == null) {
                switch (try host_resolved.wellKnownMember(self, allocator, mz.left.asPtrConst(), .iterator, &.{})) {
                    .ok => |v| st.setValue("iter_left", v),
                    .err => |e| return .{ .err = e },
                }
                switch (try host_resolved.wellKnownMember(self, allocator, mz.right.asPtrConst(), .iterator, &.{})) {
                    .ok => |v| st.setValue("iter_right", v),
                    .err => |e| return .{ .err = e },
                }
            }
            const lit = st.iter_left.?;
            const rit = st.iter_right.?;
            // Strict interleave, in `MergingSequence`'s pull order.
            const lh = switch (try host_resolved.wellKnownMember(self, allocator, &lit, .has_next, &.{})) {
                .ok => |x| x == .Bool and x.Bool,
                .err => |e| return .{ .err = e },
            };
            if (!lh) {
                st.done = true;
                return .done;
            }
            const rh = switch (try host_resolved.wellKnownMember(self, allocator, &rit, .has_next, &.{})) {
                .ok => |x| x == .Bool and x.Bool,
                .err => |e| return .{ .err = e },
            };
            if (!rh) {
                st.done = true;
                return .done;
            }
            const av = switch (try host_resolved.wellKnownMember(self, allocator, &lit, .next, &.{})) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            // The left element is held only here while the right iterator's
            // `next` runs user code.
            const ka = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(ka);
            runtime.keepalivePush(av);
            const bv = switch (try host_resolved.wellKnownMember(self, allocator, &rit, .next, &.{})) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            if (mz.transform) |t| {
                var intrinsic = VmIntrinsicHost.owning(self);
                defer intrinsic.release();
                const ihost = intrinsic.intrinsicHost();
                const r = try ihost.invokeCallable(t.asPtrConst(), &.{ av, bv }, out);
                return switch (r) {
                    .ok => |v| .{ .value = v },
                    .err => |re| .{ .err = try mapRuntimeError(allocator, re) },
                };
            }
            return .{ .value = try Value.newPair(allocator, .{
                .first = try Value.boxRef(allocator, av),
                .second = try Value.boxRef(allocator, bv),
            }) };
        },
        .Generate => |gen| {
            if (st.done) return .done;
            if (!st.gen_started) {
                st.gen_started = true;
                if (gen.seed) |s| {
                    var sv = s.asPtrConst().*;
                    if (gen.seed_is_fn) {
                        var intr = VmIntrinsicHost.owning(self);
                        defer intr.release();
                        const ih = intr.intrinsicHost();
                        const r = try ih.invokeCallable(&sv, &.{}, out);
                        switch (r) {
                            .ok => |rv| {
                                if (rv == .Null) {
                                    st.done = true;
                                    return .done;
                                }
                                var v = rv;
                                if (runtime.reclaimEnabled()) v.retain();
                                st.setValue("gen_cur", v);
                                return .{ .value = v };
                            },
                            .err => |re| return .{ .err = try mapRuntimeError(allocator, re) },
                        }
                    }
                    if (runtime.reclaimEnabled()) sv.retain();
                    st.setValue("gen_cur", sv);
                    return .{ .value = sv };
                }
                // Nullary form: first element comes from next().
            }
            var intrinsic = VmIntrinsicHost.owning(self);
            defer intrinsic.release();
            const ihost = intrinsic.intrinsicHost();
            // The nullary form's `next` takes nothing; the seeded forms' the
            // previous element.
            const arg: []const Value = if (gen.seed == null) &.{} else if (st.gen_cur) |c| &.{c} else &.{};
            const r = try ihost.invokeCallable(gen.next.asPtrConst(), arg, out);
            switch (r) {
                .ok => |nv| {
                    if (nv == .Null) {
                        st.done = true;
                        return .done;
                    }
                    var v = nv;
                    if (runtime.reclaimEnabled()) v.retain();
                    st.setValue("gen_cur", v);
                    return .{ .value = v };
                },
                .err => |re| return .{ .err = try mapRuntimeError(allocator, re) },
            }
        },
    }
}

/// Pull one OUTPUT element: run source elements through the ops until one passes.
fn seqIterPull(self: *VmHost, allocator: Allocator, st: *SeqIterState, out: runtime.Output) Allocator.Error!union(enum) { value: Value, done, err: EvalError } {
    // A sequence's ops are fixed when it is made. They are read out of its
    // borrow here, since each op may run a lambda, and no cell lock may be
    // held across user code.
    const ops = blk: {
        const sg = st.seq.Sequence.borrow();
        defer sg.deinit();
        break :blk sg.get().ops;
    };
    try seqIterEnsureState(allocator, st, ops.len);

    var intrinsic = VmIntrinsicHost.owning(self);
    defer intrinsic.release();
    const ihost = intrinsic.intrinsicHost();

    outer: while (true) {
        // Stop pulling the source once any Take cap is reached.
        {
            var capped = false;
            for (ops, 0..) |op, i| {
                if (op == .Take and st.taken[i] >= @as(usize, @intCast(@max(op.Take, 0)))) capped = true;
            }
            if (capped) return .done;
        }

        var current = switch (try seqIterSourcePull(self, allocator, st, out)) {
            .value => |v| v,
            .done => return .done,
            .err => |e| return .{ .err = e },
        };

        for (ops, 0..) |op, idx| {
            switch (op) {
                .Map => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| current = rv,
                        .err => |e| {
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .OnEach => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    if (r == .err) {
                        return .{ .err = try mapRuntimeError(allocator, r.err) };
                    }
                },
                .MapIndexed => |f| {
                    const i = st.indices[idx];
                    st.indices[idx] += 1;
                    const r = try ihost.invokeCallable(&f, &.{ Value.newInt(@intCast(i)), current }, out);
                    switch (r) {
                        .ok => |rv| current = rv,
                        .err => |e| {
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .FilterIndexed => |f| {
                    const i = st.indices[idx];
                    st.indices[idx] += 1;
                    const r = try ihost.invokeCallable(&f, &.{ Value.newInt(@intCast(i)), current }, out);
                    switch (r) {
                        .ok => |rv| if (!(rv == .Bool and rv.Bool)) {
                            continue :outer;
                        },
                        .err => |e| {
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .Filter => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| if (!(rv == .Bool and rv.Bool)) {
                            continue :outer;
                        },
                        .err => |e| {
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .FilterNot => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| if (rv == .Bool and rv.Bool) {
                            continue :outer;
                        },
                        .err => |e| {
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .Take => |n| {
                    if (st.taken[idx] >= @as(usize, @intCast(@max(n, 0)))) {
                        return .done;
                    }
                    st.taken[idx] += 1;
                },
                .Drop => |n| {
                    if (st.dropped[idx] < @as(usize, @intCast(@max(n, 0)))) {
                        st.dropped[idx] += 1;
                        continue :outer;
                    }
                },
                .TakeWhile => |f| {
                    if (!st.take_while_live[idx]) {
                        return .done;
                    }
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| if (!(rv == .Bool and rv.Bool)) {
                            st.take_while_live[idx] = false;
                            return .done;
                        },
                        .err => |e| {
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .DropWhile => |f| {
                    if (st.drop_while_live[idx]) {
                        const r = try ihost.invokeCallable(&f, &.{current}, out);
                        switch (r) {
                            .ok => |rv| {
                                if (rv == .Bool and rv.Bool) {
                                    continue :outer;
                                }
                                st.drop_while_live[idx] = false;
                            },
                            .err => |e| {
                                return .{ .err = try mapRuntimeError(allocator, e) };
                            },
                        }
                    }
                },
                // Buffering ops cannot stream: iterating materialises eagerly.
                else => {
                    const mr = try materialiseSequence(self, allocator, &st.seq);
                    switch (mr) {
                        .ok => |list| {
                            var owned = list;
                            const slice = try owned.toOwnedSlice(allocator);
                            const items_ref = try runtime.ValueSlice.init(allocator, slice);
                            const data = try ObjRef(runtime.SequenceData).init(allocator, .{
                                .source = .{ .Items = items_ref },
                                .ops = &.{},
                            });
                            if (runtime.reclaimEnabled()) st.seq.release(allocator);
                            st.setValue("seq", .{ .Sequence = data });
                            st.src_pos = 0;
                            st.taken = &.{};
                            st.dropped = &.{};
                            st.take_while_live = &.{};
                            st.drop_while_live = &.{};
                            st.indices = &.{};
                            return seqIterPull(self, allocator, st, out);
                        },
                        .err => |e| return .{ .err = e },
                    }
                },
            }
        }
        return .{ .value = current };
    }
}

fn seqIterEnsure(self: *VmHost, allocator: Allocator, st: *SeqIterState, out: runtime.Output) Allocator.Error!union(enum) { has: bool, err: EvalError } {
    if (st.buffered != null) return .{ .has = true };
    if (st.done) return .{ .has = false };
    switch (try seqIterPull(self, allocator, st, out)) {
        .value => |v| {
            st.setValue("buffered", v);
            return .{ .has = true };
        },
        .done => {
            st.done = true;
            return .{ .has = false };
        },
        .err => |e| return .{ .err = e },
    }
}

pub fn seqIterMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const has_next = std.mem.eql(u8, name, "hasNext") and args.len == 0;
    const next = isIteratorNext(name) and args.len == 0;
    if (!has_next and !next) return null;
    // The pull runs user code, so it takes no lock for its length: it owns the
    // state while `pulling` is set, and stores each value field under a
    // borrow of its own (`SeqIterState.setValue`).
    const st = &receiver.SeqIter.cell.data;
    if (st.pulling.swap(true, .acquire)) {
        return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", "the sequence iterator is already being advanced") };
    }
    defer st.pulling.store(false, .release);
    if (has_next) {
        return switch (try seqIterEnsure(self, allocator, st, self.out)) {
            .has => |b| .{ .ok = boolVal(b) },
            .err => |e| .{ .err = e },
        };
    }
    switch (try seqIterEnsure(self, allocator, st, self.out)) {
        .has => |b| if (!b) return .{ .err = try throwExc(allocator, "kotlin.NoSuchElementException", "iterator exhausted") },
        .err => |e| return .{ .err = e },
    }
    const v = st.buffered.?;
    st.setValue("buffered", null);
    return .{ .ok = v };
}

/// Memo for `classHasUserMethod`: one hierarchy walk per (class, method) per gen.
const UserMethodMemoEntry = struct { has: bool, gen: u32 };
const UserMethodMemoLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *UserMethodMemoLock) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *UserMethodMemoLock) void {
        self.locked.store(false, .release);
    }
};
var user_method_memo_lock: UserMethodMemoLock = .{};
var user_method_memo: ?runtime.NameHashMap(UserMethodMemoEntry) = null;

fn userMethodMemoGet(key: []const u8, gen: u32) ?bool {
    user_method_memo_lock.lock();
    defer user_method_memo_lock.unlock();
    const memo = &(user_method_memo orelse return null);
    const e = memo.get(key) orelse return null;
    if (e.gen != gen) return null;
    return e.has;
}

fn userMethodMemoPut(key: []const u8, gen: u32, has: bool) void {
    user_method_memo_lock.lock();
    defer user_method_memo_lock.unlock();
    if (user_method_memo == null) user_method_memo = runtime.NameHashMap(UserMethodMemoEntry).init(std.heap.page_allocator);
    const memo = &user_method_memo.?;
    if (memo.getPtr(key)) |e| {
        e.* = .{ .has = has, .gen = gen };
        return;
    }
    if (memo.count() >= 65536) return;
    const owned = std.heap.page_allocator.dupe(u8, key) catch return;
    memo.put(owned, .{ .has = has, .gen = gen }) catch {};
}

test "user-method memo answers per dispatch generation" {
    userMethodMemoPut("pkg.C\x1fequals", 7, true);
    try std.testing.expectEqual(@as(?bool, true), userMethodMemoGet("pkg.C\x1fequals", 7));
    try std.testing.expectEqual(@as(?bool, null), userMethodMemoGet("pkg.C\x1fequals", 8));
    userMethodMemoPut("pkg.C\x1fequals", 8, false);
    try std.testing.expectEqual(@as(?bool, false), userMethodMemoGet("pkg.C\x1fequals", 8));
    try std.testing.expectEqual(@as(?bool, null), userMethodMemoGet("pkg.C\x1fhashCode", 8));
}

/// An annotation instance's parameter names and values; values are retained for the caller.
const AnnotationFields = struct {
    names: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList(Value) = .empty,
    fqn: []const u8 = "",

    fn collect(allocator: Allocator, inst: ObjRef(InstanceData)) Allocator.Error!AnnotationFields {
        var out: AnnotationFields = .{};
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        defer {
            cg.deinit();
            g.deinit();
        }
        out.fqn = if (cg.get().fqn.len != 0) cg.get().fqn else cg.get().name;
        try out.names.ensureTotalCapacity(allocator, cg.get().primary_params.len);
        try out.values.ensureTotalCapacity(allocator, cg.get().primary_params.len);
        for (cg.get().primary_params) |p| {
            const v = g.get().get(p.name) orelse Value.Null;
            if (runtime.reclaimEnabled()) v.retain();
            out.names.appendAssumeCapacity(p.name);
            out.values.appendAssumeCapacity(v);
        }
        return out;
    }

    fn release(self: *AnnotationFields, allocator: Allocator) void {
        if (runtime.reclaimEnabled()) {
            for (self.values.items) |v| v.release(allocator);
        }
        self.names.deinit(allocator);
        self.values.deinit(allocator);
    }
};

/// Callable references compare by target, captures and adaptation: two loads of
/// `::f` are the same function, as are two wrappers of the same adaptation.
pub fn closureRefEquals(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) Allocator.Error!bool {
    const ca = a.IrClosure;
    const cb = b.IrClosure;
    if (ca.asPtrConst().id == cb.asPtrConst().id) return true;
    const ia = self.closures.get(@intCast(ca.asPtrConst().id)) orelse return Value.structuralEq(a, b);
    const ib = self.closures.get(@intCast(cb.asPtrConst().id)) orelse return Value.structuralEq(a, b);
    if (ia.resolved != null or ib.resolved != null) {
        if (!resolvedSameTarget(ia, ib)) return false;
        const ga = ca.borrow();
        defer ga.deinit();
        const gb = cb.borrow();
        defer gb.deinit();
        const xa = ga.get().captures;
        const xb = gb.get().captures;
        if (xa.len != xb.len) return false;
        for (xa, xb) |*x, *y| {
            if (!try deepValueEquals(self, allocator, x, y)) return false;
        }
        return true;
    }
    const same_body = ia.body_func == ib.body_func and
        (@intFromPtr(ia.module orelse @as(*const ir.Module, @ptrFromInt(8))) == @intFromPtr(ib.module orelse @as(*const ir.Module, @ptrFromInt(8))));
    if (ia.is_ref and ib.is_ref) return same_body;
    const ga = ca.borrow();
    defer ga.deinit();
    const gb = cb.borrow();
    defer gb.deinit();
    const xa = ga.get().captures;
    const xb = gb.get().captures;
    const key_eq = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const ma = ia.module orelse mg.get();
        const mb = ib.module orelse mg.get();
        const fa = ma.funcById(ia.body_func) orelse break :blk false;
        const fb = mb.funcById(ib.body_func) orelse break :blk false;
        break :blk fa.x().ref_key.len != 0 and std.mem.eql(u8, fa.x().ref_key, fb.x().ref_key);
    };
    if (key_eq) {
        if (xa.len != xb.len) return false;
        for (xa, xb) |*x, *y| {
            if (!try deepValueEquals(self, allocator, x, y)) return false;
        }
        return true;
    }
    if (same_body and xa.len == 0 and xb.len == 0 and ia.capture_names.len == 0 and ib.capture_names.len == 0) return true;
    return false;
}

/// Whether two closures lowered from sema reference one declaration: a
/// function reference its target, a property reference its getter. A lambda
/// equals only itself.
fn resolvedSameTarget(ia: root.ClosureInfo, ib: root.ClosureInfo) bool {
    const ka = ia.resolved orelse return false;
    const kb = ib.resolved orelse return false;
    return switch (ka) {
        .lambda => false,
        .function_ref => |ta| kb == .function_ref and kb.function_ref == ta,
        .property_ref => kb == .property_ref and ia.body_func == ib.body_func and ia.module == ib.module,
    };
}

/// Hash of a callable reference, consistent with `closureRefEquals`.
pub fn closureRefHash(self: *VmHost, allocator: Allocator, v: *const Value) Allocator.Error!i32 {
    const c = v.IrClosure;
    const info = self.closures.get(@intCast(c.asPtrConst().id)) orelse return kotlinHashCode(v);
    if (info.resolved) |kind| {
        const target: u32 = switch (kind) {
            .lambda => return kotlinHashCode(v),
            .function_ref => |t| t.int(),
            .property_ref => info.body_func.int(),
        };
        var h: i32 = @truncate(@as(i64, target) *% 31 +% 17);
        const g = c.borrow();
        defer g.deinit();
        for (g.get().captures) |*x| h = h *% 31 +% try hashWithDispatch(self, allocator, x);
        return h;
    }
    const by_body: i32 = @truncate(@as(i64, @intCast(info.body_func.int())) *% 31 +% 17);
    if (info.is_ref) return by_body;
    const key_hash: ?i32 = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = info.module orelse mg.get();
        const f = mod.funcById(info.body_func) orelse break :blk null;
        if (f.x().ref_key.len == 0) break :blk null;
        break :blk javaStringHash(f.x().ref_key);
    };
    if (key_hash) |kh| {
        var h = kh;
        const g = c.borrow();
        defer g.deinit();
        for (g.get().captures) |*x| h = h *% 31 +% try hashWithDispatch(self, allocator, x);
        return h;
    }
    const g = c.borrow();
    defer g.deinit();
    if (g.get().captures.len == 0 and info.capture_names.len == 0) return by_body;
    return kotlinHashCode(v);
}

/// `String.hashCode()` over UTF-16 code units.
pub fn javaStringHash(s: []const u8) i32 {
    var h: i32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            const c = cp - 0x10000;
            h = h *% 31 +% @as(i32, @intCast(0xD800 + (c >> 10)));
            h = h *% 31 +% @as(i32, @intCast(0xDC00 + (c & 0x3FF)));
        } else {
            h = h *% 31 +% @as(i32, @intCast(cp));
        }
    }
    return h;
}

fn renderAnnotationInto(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), buf: *std.ArrayList(u8)) Allocator.Error!void {
    var fields = try AnnotationFields.collect(allocator, inst);
    defer fields.release(allocator);
    try buf.append(allocator, '@');
    try buf.appendSlice(allocator, fields.fqn);
    try buf.append(allocator, '(');
    for (fields.names.items, fields.values.items, 0..) |n, *v, idx| {
        if (idx > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, n);
        try buf.append(allocator, '=');
        try renderAnnotationValue(self, allocator, v, buf);
    }
    try buf.append(allocator, ')');
}

fn renderAnnotationValue(self: *VmHost, allocator: Allocator, v: *const Value, buf: *std.ArrayList(u8)) Allocator.Error!void {
    switch (v.*) {
        .Array => |arr| {
            try buf.append(allocator, '[');
            const n = arr.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                var e = arr.get(i);
                try renderAnnotationValue(self, allocator, &e, buf);
            }
            try buf.append(allocator, ']');
        },
        .Instance => |ii| {
            const nested = blk: {
                const g = ii.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                break :blk cg.get().is_annotation;
            };
            if (nested) return renderAnnotationInto(self, allocator, ii, buf);
            switch (try host_resolved.wellKnownMember(self, allocator, v, .to_string, &.{})) {
                .ok => |sv| try buf.appendSlice(allocator, try sv.display(allocator)),
                .err => try buf.appendSlice(allocator, try v.display(allocator)),
            }
        },
        else => try buf.appendSlice(allocator, try v.display(allocator)),
    }
}

/// The host class table of the program's tables.
fn hostClasses(self: *VmHost) *const ir.resolved.HostClasses {
    const empty = struct {
        const table: ir.resolved.HostClasses = .{};
    };
    const r = self.module.asPtrConst().resolved orelse return &empty.table;
    return &r.host_class;
}
