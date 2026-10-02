//! Hashed membership for sets and for the builders that dedupe: each element's
//! `hashCode()` as Kotlin answers it (an instance's through the host, its own override
//! or its identity), taken once as the element joins, with equality as the sets compare
//! it (`eqBoxedH`) among the elements of one hash. A `HashSet` on the JVM is a
//! `HashMap` over its elements, and finds an element the same way. The index a set
//! keeps is `runtime.ValueIndex`, under its list's lock (`plans/hashed-collections.md`).

const std = @import("std");
const runtime = @import("runtime");
const Value = runtime.Value;
const ValueList = runtime.ValueList;
const ValueIndex = runtime.ValueIndex;
const ValueIndexRef = runtime.ValueIndexRef;
const SetData = runtime.SetData;
const EvalResult = runtime.EvalResult;
const IntrinsicHost = runtime.IntrinsicHost;
const Output = runtime.Output;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const common = @import("common.zig");
const eqBoxedH = common.eqBoxedH;

/// A set below this many elements keeps no index: comparing each is cheaper.
pub const index_min = 8;

pub const Hash = union(enum) {
    hash: u64,
    thrown: EvalResult,
};

/// `v.hashCode()` as Kotlin answers it, spread over 64 bits for the buckets;
/// `ValueIndex.no_hash` for a value whose hash a lookup cannot use (it is then compared
/// with every element), the exception when a `hashCode` override threw.
pub fn elementHash(host: ?IntrinsicHost, out: Output, v: *const Value) Error!Hash {
    return switch (try hashCode(host, out, v)) {
        .code => |c| .{ .hash = spread(c) },
        .none => .{ .hash = ValueIndex.no_hash },
        .thrown => |e| .{ .thrown = e },
    };
}

const Code = union(enum) {
    code: i32,
    none,
    thrown: EvalResult,
};

fn hashCode(host: ?IntrinsicHost, out: Output, v: *const Value) Error!Code {
    if (v.javaHashCode()) |c| return .{ .code = c };
    switch (v.*) {
        .Instance => {
            // With no host, an instance compares structurally (`eqBoxed`): it is compared
            // with every element.
            const ho = host orelse return .none;
            // A class keeping `Any`'s members is equal only to itself: any hash of its own.
            if (ho.identityKey(v)) |id| return .{ .code = @bitCast(id) };
            const r = (try ho.callWellKnown(v, .hash_code, &.{}, out)) orelse return .none;
            return switch (r) {
                .ok => |x| if (x == .Int) .{ .code = x.Int } else .none,
                .err => .{ .thrown = r },
            };
        },
        // A data class's `hashCode`: each component's, times 31, plus the next.
        .Pair => |p| {
            const a = try hashCode(host, out, p.first.asPtrConst());
            if (a != .code) return a;
            const b = try hashCode(host, out, p.second.asPtrConst());
            if (b != .code) return b;
            return .{ .code = a.code *% 31 +% b.code };
        },
        .Triple => |t| {
            const a = try hashCode(host, out, t.first.asPtrConst());
            if (a != .code) return a;
            const b = try hashCode(host, out, t.second.asPtrConst());
            if (b != .code) return b;
            const c = try hashCode(host, out, t.third.asPtrConst());
            if (c != .code) return c;
            return .{ .code = (a.code *% 31 +% b.code) *% 31 +% c.code };
        },
        // `Map.Entry`'s contract: the key's hash xor the value's.
        .MapEntry => |e| {
            const a = try hashCode(host, out, &e.key);
            if (a != .code) return a;
            const value = e.getValue();
            const b = try hashCode(host, out, &value);
            if (b != .code) return b;
            return .{ .code = a.code ^ b.code };
        },
        else => return .none,
    }
}

/// A 32-bit hash spread over 64 (splitmix64's finalizer), never `no_hash`.
fn spread(c: i32) u64 {
    var z: u64 = @as(u64, @as(u32, @bitCast(c))) ^ 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z ^= z >> 31;
    return if (z == ValueIndex.no_hash) z - 1 else z;
}

pub const Found = union(enum) {
    at: usize,
    none,
    thrown: EvalResult,
};

/// Equality as the sets compare elements: `eqBoxedH` through the host, `eqBoxed` with none.
fn eq(host: ?IntrinsicHost, out: Output, x: *const Value, y: *const Value) Error!bool {
    if (host) |ho| return eqBoxedH(ho, out, x, y);
    return common.eqBoxed(x, y);
}

/// Where `needle` is among `items`, comparing only the `positions` given.
fn compareAt(host: ?IntrinsicHost, out: Output, items: []const Value, positions: []const u32, needle: *const Value) Error!?usize {
    for (positions) |p| {
        if (p >= items.len) continue;
        if (try eq(host, out, &items[p], needle)) return p;
    }
    return null;
}

/// A dedupe the builders run: the elements kept, in order, and their index, which a set
/// made from them keeps (`intoSet`).
pub const Seen = struct {
    items: std.ArrayList(Value) = .empty,
    ix: ValueIndex = .{},
    /// The keepalive mark the kept elements are rooted above while user `hashCode` and
    /// `equals` run (`init`).
    mark: usize,

    pub fn init() Seen {
        return .{ .mark = runtime.keepaliveMark() };
    }

    pub const Add = union(enum) {
        added,
        /// Where the equal element kept before is.
        present: usize,
        thrown: EvalResult,
    };

    pub fn deinit(self: *Seen, a: Allocator) void {
        self.items.deinit(a);
        self.ix.deinit(a);
        runtime.keepaliveRestore(self.mark);
    }

    /// Keeps `v` unless an equal element is kept already; `host` null compares
    /// structurally, `out` then unused.
    pub fn add(self: *Seen, host: ?IntrinsicHost, out: Output, a: Allocator, v: Value) Error!Add {
        const h = switch (try elementHash(host, out, &v)) {
            .hash => |x| x,
            .thrown => |e| return .{ .thrown = e },
        };
        var sfa = std.heap.stackFallback(256, a);
        const sa = sfa.get();
        var at: std.ArrayList(u32) = .empty;
        defer at.deinit(sa);
        try self.ix.candidates(h, &at, sa);
        // The kept elements do not move while an `equals` runs: no one else holds them.
        if (try compareAt(host, out, self.items.items, at.items, &v)) |p| return .{ .present = p };
        try self.items.append(a, v);
        runtime.keepalivePush(v);
        try self.ix.push(h);
        return .added;
    }

    /// Where the kept element equal to `v` is, if any.
    pub fn find(self: *Seen, host: ?IntrinsicHost, out: Output, a: Allocator, v: Value) Error!Found {
        const h = switch (try elementHash(host, out, &v)) {
            .hash => |x| x,
            .thrown => |e| return .{ .thrown = e },
        };
        var sfa = std.heap.stackFallback(256, a);
        const sa = sfa.get();
        var at: std.ArrayList(u32) = .empty;
        defer at.deinit(sa);
        try self.ix.candidates(h, &at, sa);
        if (try compareAt(host, out, self.items.items, at.items, &v)) |p| return .{ .at = p };
        return .none;
    }

    /// A set of the kept elements, which keeps their index; `self` is left empty. The set
    /// takes one reference to each element where the backend counts them.
    pub fn intoSet(self: *Seen, a: Allocator, mutable: bool) Error!Value {
        if (runtime.reclaimEnabled()) for (self.items.items) |e| e.retain();
        const items = try ValueList.init(a, self.items);
        self.items = .empty;
        const v = try Value.newSet(a, .{
            .elems = items,
            .mutable = mutable,
            .backing = null,
            .mod_count = try common.modCountFor(a, mutable),
        });
        if (self.ix.len() >= index_min) {
            var ix = self.ix;
            self.ix = .{};
            ix.seq = items.cell.lock.seq.load(.monotonic);
            v.Set.setIndex(try ValueIndexRef.initOwned(a, ix));
        }
        return v;
    }
};

/// What a set's lookup found, with the list's write sequence it read and the needle's
/// hash, for a change that follows to check nothing moved in between.
pub const SetLookup = struct {
    found: Found,
    seq: u32,
    hash: u64,
};

/// Where `needle` is in set `sd`: through the set's index, built first when the set has
/// none for its list as it stands, or by comparing each element of a small set.
pub fn setFind(host: IntrinsicHost, out: Output, a: Allocator, sd: *SetData, needle: *const Value) Error!SetLookup {
    const h = switch (try elementHash(host, out, needle)) {
        .hash => |x| x,
        .thrown => |e| return .{ .found = .{ .thrown = e }, .seq = 0, .hash = 0 },
    };
    if (try ensureIndex(host, out, a, sd)) |e| return .{ .found = .{ .thrown = e }, .seq = 0, .hash = h };
    // The candidates and their elements, copied under the list's lock: an `equals`
    // re-enters the VM, which must not happen under it.
    var sfa = std.heap.stackFallback(512, a);
    const sa = sfa.get();
    var at: std.ArrayList(u32) = .empty;
    defer at.deinit(sa);
    var vals: std.ArrayList(Value) = .empty;
    defer vals.deinit(sa);
    const mark = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(mark);
    const seq = blk: {
        const g = sd.elems.borrow();
        defer g.deinit();
        const items = g.get().items;
        const s = sd.elems.cell.lock.seq.load(.monotonic);
        if (indexOf(sd)) |ix| if (ix.seq == s) {
            try ix.candidates(h, &at, sa);
            for (at.items) |p| try vals.append(sa, if (p < items.len) items[p] else Value.Unit);
            break :blk s;
        };
        // A small set, or one changed since its index was built (which holds no holes):
        // every element.
        for (items, 0..) |v, i| {
            try at.append(sa, @intCast(i));
            try vals.append(sa, v);
        }
        break :blk s;
    };
    runtime.keepalivePushSlice(vals.items);
    for (at.items, vals.items) |p, *v| {
        if (try eqBoxedH(host, out, v, needle)) return .{ .found = .{ .at = p }, .seq = seq, .hash = h };
    }
    return .{ .found = .none, .seq = seq, .hash = h };
}

/// Builds set `sd`'s index again when its list changed another way than through these
/// functions; none for a small set. The hashes are taken with no lock held (an override
/// re-enters the VM) and installed if the list did not change meanwhile.
fn ensureIndex(host: IntrinsicHost, out: Output, a: Allocator, sd: *SetData) Error!?EvalResult {
    while (true) {
        var snap: []Value = &.{};
        defer a.free(snap);
        const mark = runtime.keepaliveMark();
        defer runtime.keepaliveRestore(mark);
        const seq0 = blk: {
            const g = sd.elems.borrow();
            defer g.deinit();
            const s = sd.elems.cell.lock.seq.load(.monotonic);
            if (indexOf(sd)) |ix| if (ix.seq == s) return null;
            if (g.get().items.len < index_min) return null;
            snap = try a.dupe(Value, g.get().items);
            break :blk s;
        };
        runtime.keepalivePushSlice(snap);
        var hashes = try a.alloc(u64, snap.len);
        defer a.free(hashes);
        for (snap, 0..) |*v, i| switch (try elementHash(host, out, v)) {
            .hash => |x| hashes[i] = x,
            .thrown => |e| return e,
        };
        const g = sd.elems.borrowMut();
        defer g.deinit();
        const s = sd.elems.cell.lock.seq.load(.monotonic);
        // The writer's lock made the sequence odd: one more than it stood before.
        if (s -% 1 != seq0) continue;
        const ix = indexOf(sd) orelse blk: {
            sd.setIndex(try ValueIndexRef.initOwned(a, .{}));
            break :blk indexOf(sd).?;
        };
        ix.clear();
        for (hashes) |x| try ix.push(x);
        // Giving the lock back makes it one more again.
        ix.seq = s +% 1;
        return null;
    }
}

pub const Change = union(enum) {
    /// The set changed (or, for `add`, already held the element: `changed` false).
    done: bool,
    thrown: EvalResult,
};

/// `MutableSet.add`: `v` at the end unless an equal element is there.
pub fn setAdd(host: IntrinsicHost, out: Output, a: Allocator, sd: *SetData, v: Value) Error!Change {
    while (true) {
        const l = try setFind(host, out, a, sd, &v);
        switch (l.found) {
            .thrown => |e| return .{ .thrown = e },
            .at => return .{ .done = false },
            .none => {},
        }
        const g = sd.elems.borrowMut();
        defer g.deinit();
        const s = sd.elems.cell.lock.seq.load(.monotonic);
        if (s -% 1 != l.seq) continue;
        if (runtime.reclaimEnabled()) v.retain();
        try g.get().append(a, v);
        if (indexOf(sd)) |ix| if (ix.seq == l.seq) {
            try ix.push(l.hash);
            ix.seq = s +% 1;
        };
        return .{ .done = true };
    }
}

/// `MutableSet.remove`: the element equal to `v`, if any. In a set with an index it
/// leaves a hole and the others keep their places, the last element taking the holes
/// before it along; the holes close up once they are as many as the elements. A small
/// set's later elements move down.
pub fn setRemove(host: IntrinsicHost, out: Output, a: Allocator, sd: *SetData, v: Value) Error!Change {
    while (true) {
        const l = try setFind(host, out, a, sd, &v);
        const pos = switch (l.found) {
            .thrown => |e| return .{ .thrown = e },
            .none => return .{ .done = false },
            .at => |p| p,
        };
        const g = sd.elems.borrowMut();
        defer g.deinit();
        const s = sd.elems.cell.lock.seq.load(.monotonic);
        if (s -% 1 != l.seq) continue;
        const list = g.get();
        const r = sd.removeAtLocked(list, pos);
        if (runtime.reclaimEnabled()) r.gone.release(a);
        if (sd.holes * 2 >= list.items.len) sd.compactLocked(list);
        return .{ .done = true };
    }
}

/// Set `sd`'s index, its cell's payload; read and written under the set's list's lock.
fn indexOf(sd: *const SetData) ?*ValueIndex {
    return if (sd.index) |r| &r.cell.data else null;
}

/// The keys of a map's entries under construction, as `LinkedHashMap.put` finds them: a
/// hash index over the entries' keys by position, each key's `hashCode()` taken once.
/// `find` indexes the entries appended since it last ran, then answers the entry whose
/// key equals the one asked for; the caller appends an entry for a key it finds none for.
pub const KeyIndex = struct {
    ix: ValueIndex = .{},
    /// The key `find` last found no entry for, and its hash: the entry the caller appends
    /// for it takes the hash without asking the key again.
    pending: Value = .Null,
    pending_hash: u64 = ValueIndex.no_hash,
    /// For a builder with no way to throw: a key whose `hashCode` throws is compared with
    /// every entry, as one with no hash is (`findQuiet`).
    quiet: bool = false,

    pub fn deinit(self: *KeyIndex, a: Allocator) void {
        self.ix.deinit(a);
    }

    /// Where the entry whose key equals `key` is among `entries`; `host` null compares
    /// structurally, `out` then unused.
    pub fn find(self: *KeyIndex, host: ?IntrinsicHost, out: Output, a: Allocator, entries: []const runtime.MapPair, key: *const Value) Error!Found {
        while (self.ix.len() < entries.len) {
            const k = &entries[self.ix.len()].key;
            const h = if (sameBits(k, &self.pending)) self.pending_hash else switch (try elementHash(host, out, k)) {
                .hash => |x| x,
                .thrown => |e| if (self.quiet) ValueIndex.no_hash else return .{ .thrown = e },
            };
            self.pending = .Null;
            try self.ix.push(h);
        }
        const h = switch (try elementHash(host, out, key)) {
            .hash => |x| x,
            .thrown => |e| if (self.quiet) ValueIndex.no_hash else return .{ .thrown = e },
        };
        var sfa = std.heap.stackFallback(256, a);
        const sa = sfa.get();
        var at: std.ArrayList(u32) = .empty;
        defer at.deinit(sa);
        try self.ix.candidates(h, &at, sa);
        for (at.items) |p| {
            if (p >= entries.len) continue;
            if (try eq(host, out, &entries[p].key, key)) return .{ .at = p };
        }
        self.pending = key.*;
        self.pending_hash = h;
        return .none;
    }
};

/// `find` for a quiet index: the entry's position, or null.
pub fn findQuiet(keys: *KeyIndex, host: ?IntrinsicHost, out: Output, a: Allocator, entries: []const runtime.MapPair, key: *const Value) Error!?usize {
    keys.quiet = true;
    return switch (try keys.find(host, out, a, entries, key)) {
        .at => |p| p,
        .none, .thrown => null,
    };
}

/// Whether two values are the same bits: the same key passed back.
fn sameBits(x: *const Value, y: *const Value) bool {
    const xb: *const [@sizeOf(Value)]u8 = @ptrCast(x);
    const yb: *const [@sizeOf(Value)]u8 = @ptrCast(y);
    return std.mem.eql(u8, xb, yb);
}
