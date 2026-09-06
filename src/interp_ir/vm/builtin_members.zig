//! The member surface the host serves for builtin value shapes.
//!
//! `host_call_member.zig` walks a receiver's dispatch routes in order; several
//! of those routes never consult a user declaration at all. They live here:
//! Kotlin-faithful structural equality, hashing and natural ordering; the
//! comparator, collection, array and `componentN` member ops; the data-class
//! conventions (`equals`/`hashCode`/`toString`); and the iteration protocol —
//! builtin iterators with their concurrent-modification counters, range
//! iterators, and the lazy `Sequence` puller that streams one element per step.
//!
//! Nothing here owns dispatch state. The method caches, name-identity slots,
//! permanent bind slots and fallback flags all stay in `host_call_member.zig`
//! and are reached through it, so there is exactly one copy of each.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const vmhost = @import("vmhost.zig");
const host_call_member = @import("host_call_member.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ClassDef = runtime.ClassDef;
const MapPair = runtime.MapPair;
const RangeKind = runtime.RangeKind;
const SeqOp = runtime.SeqOp;
const SequenceData = runtime.SequenceData;
const ComparatorStep = runtime.ComparatorStep;

const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const VmHost = vmhost.VmHost;

// Shared dispatch plumbing that stays in host_call_member.zig, including every
// piece of module-level dispatch state.
const boolVal = host_call_member.boolVal;
const callMember = host_call_member.callMember;
const callMemberRec = host_call_member.callMemberRec;
const callValueRec = host_call_member.callValueRec;
const classDisplayName = host_call_member.classDisplayName;
const cloneItemsList = host_call_member.cloneItemsList;
const deinitIntrinsicHost = host_call_member.deinitIntrinsicHost;
const funcAt = host_call_member.funcAt;
const getFieldRec = host_call_member.getFieldRec;
const isIteratorNext = host_call_member.isIteratorNext;
const listOf = host_call_member.listOf;
const makeIntrinsicHost = host_call_member.makeIntrinsicHost;
const mapRuntimeError = host_call_member.mapRuntimeError;
const receiverImplementsHead = host_call_member.receiverImplementsHead;
const receiverImplementsType = host_call_member.receiverImplementsType;
const reconstructDataClass = host_call_member.reconstructDataClass;
const strVal = host_call_member.strVal;
const throwExc = host_call_member.throwExc;
const typeErr = host_call_member.typeErr;

/// Recursive value equality: dispatches a user `equals` override for Instance
/// operands and compares List/Set/Map element/entry-wise (so `setOf(P)==setOf(P)`
/// and nested collections honour element `equals`, which bare structural
/// equality — identity for a non-data Instance — does not). Collections are
/// compared under a live borrow (never a heap snapshot, which the GC would not
/// root across the nested VM dispatch), mirroring `collectionsEqualHostAware`.
pub fn deepValueEquals(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) Allocator.Error!bool {
    // A property reference (`::x`) is equal to another reference to the
    // same property.
    if (a.* == .PropertyRef and b.* == .PropertyRef) {
        const ga = a.PropertyRef.name.borrow();
        defer ga.deinit();
        const gb = b.PropertyRef.name.borrow();
        defer gb.deinit();
        return std.mem.eql(u8, ga.get().bytes, gb.get().bytes);
    }
    if (a.* == .IrClosure and b.* == .IrClosure) return closureRefEquals(self, allocator, a, b);
    // A NATIVE collection on the left compares against a user Instance
    // implementing the matching collection interface by the Kotlin
    // collection contract (same size, equal elements/entries) — that is
    // what the native receiver's own `equals` does. The instance side
    // need not override `equals` for `setOf(x) == wrapper` to hold.
    if (a.* != .Instance and b.* == .Instance) {
        switch (a.*) {
            .Set => if (receiverImplementsHead(self, b, "Set")) {
                const dr = try drainIterableToList(self, allocator, b);
                const drained = switch (dr) {
                    .ok => |v| v,
                    .err => return false,
                };
                defer if (runtime.reclaimEnabled()) drained.release(allocator);
                const ga = a.Set.items.borrow();
                defer ga.deinit();
                const gb = drained.List.items.borrow();
                defer gb.deinit();
                const xa = ga.get().items;
                const xb = gb.get().items;
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
            .List => if (receiverImplementsHead(self, b, "List")) {
                const dr = try drainIterableToList(self, allocator, b);
                const drained = switch (dr) {
                    .ok => |v| v,
                    .err => return false,
                };
                defer if (runtime.reclaimEnabled()) drained.release(allocator);
                a.refreshArrayView();
                a.refreshSublistView();
                const ga = a.List.items.borrow();
                defer ga.deinit();
                const gb = drained.List.items.borrow();
                defer gb.deinit();
                const xa = ga.get().items;
                const xb = gb.get().items;
                if (xa.len != xb.len) return false;
                for (xa, xb) |*ea, *eb| {
                    if (!try deepValueEquals(self, allocator, ea, eb)) return false;
                }
                return true;
            },
            .Map => if (receiverImplementsHead(self, b, "Map")) {
                const er = try self.callMember(allocator, b, "entries", &.{});
                const entries_val = switch (er) {
                    .ok => |v| v,
                    .err => return false,
                };
                defer if (runtime.reclaimEnabled()) entries_val.release(allocator);
                const dr = try drainIterableToList(self, allocator, &entries_val);
                const drained = switch (dr) {
                    .ok => |v| v,
                    .err => return false,
                };
                defer if (runtime.reclaimEnabled()) drained.release(allocator);
                const ga = a.Map.entries.borrow();
                defer ga.deinit();
                const gb = drained.List.items.borrow();
                defer gb.deinit();
                const pa = ga.get().pairs.items;
                const xb = gb.get().items;
                if (pa.len != xb.len) return false;
                for (pa) |*ka| {
                    var found = false;
                    for (xb) |*eb| {
                        const kr = try self.getField(allocator, eb, "key");
                        const key = switch (kr) {
                            .ok => |v| v,
                            .err => continue,
                        };
                        defer if (runtime.reclaimEnabled()) key.release(allocator);
                        if (!try deepValueEquals(self, allocator, &ka.key, &key)) continue;
                        const vr = try self.getField(allocator, eb, "value");
                        const val = switch (vr) {
                            .ok => |v| v,
                            .err => continue,
                        };
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
    if (a.* == .Instance or b.* == .Instance) {
        if (a.* == .Instance and b.* == .Instance) {
            switch (try callMemberRec(self, allocator, a, "equals", &.{b.*})) {
                .ok => |v| return v == .Bool and v.Bool,
                .err => {},
            }
        }
        return Value.structuralEqBoxed(a, b);
    }
    switch (a.*) {
        .List => {
            if (b.* != .List) return Value.structuralEqBoxed(a, b);
            // Sync array-backed / sublist views to their live backing store
            // before reading (mirrors structuralEqBoxed); otherwise an
            // `IntArray.asList()` view or a `subList` compares stale contents.
            a.refreshArrayView();
            b.refreshArrayView();
            a.refreshSublistView();
            b.refreshSublistView();
            const ga = a.List.items.borrow();
            defer ga.deinit();
            const gb = b.List.items.borrow();
            defer gb.deinit();
            const xa = ga.get().items;
            const xb = gb.get().items;
            if (xa.len != xb.len) return false;
            for (xa, xb) |*ea, *eb| {
                if (!try deepValueEquals(self, allocator, ea, eb)) return false;
            }
            return true;
        },
        .Set => {
            if (b.* != .Set) return Value.structuralEqBoxed(a, b);
            const ga = a.Set.items.borrow();
            defer ga.deinit();
            const gb = b.Set.items.borrow();
            defer gb.deinit();
            const xa = ga.get().items;
            const xb = gb.get().items;
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
            const ga = a.Map.entries.borrow();
            defer ga.deinit();
            const gb = b.Map.entries.borrow();
            defer gb.deinit();
            const pa = ga.get().pairs.items;
            const pb = gb.get().pairs.items;
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
        // Pair/Triple recurse component-wise so a nested native-vs-instance
        // collection (a `snapshot to setOf(state)` against a
        // `snapshot to ScatterSetWrapper`) compares by the same rules.
        .Pair => |x| {
            if (b.* != .Pair) return Value.structuralEqBoxed(a, b);
            return try deepValueEquals(self, allocator, x.first.asPtr(), b.Pair.first.asPtr()) and
                try deepValueEquals(self, allocator, x.second.asPtr(), b.Pair.second.asPtr());
        },
        .Triple => |x| {
            if (b.* != .Triple) return Value.structuralEqBoxed(a, b);
            return try deepValueEquals(self, allocator, x.first.asPtr(), b.Triple.first.asPtr()) and
                try deepValueEquals(self, allocator, x.second.asPtr(), b.Triple.second.asPtr()) and
                try deepValueEquals(self, allocator, x.third.asPtr(), b.Triple.third.asPtr());
        },
        else => return Value.structuralEqBoxed(a, b),
    }
}

/// `kotlinHashCode` with member dispatch for user instances: containers
/// fold their elements' USER hashCode() overrides, exactly as the JVM
/// does. Non-container scalars delegate to the pure hash.
pub fn hashWithDispatch(self: *VmHost, allocator: Allocator, v: *const Value) Allocator.Error!i32 {
    switch (v.*) {
        .IrClosure => return closureRefHash(self, allocator, v),
        .PropertyRef => |pr| {
            const g = pr.name.borrow();
            defer g.deinit();
            return javaStringHash(g.get().bytes);
        },
        .Instance, .Exception => {
            const r = try callMember(self, allocator, v, "hashCode", &.{});
            switch (r) {
                .ok => |hv| {
                    if (hv == .Int) return @truncate(hv.Int);
                    return kotlinHashCode(v);
                },
                .err => return kotlinHashCode(v),
            }
        },
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            var h: i32 = 1;
            for (g.get().items) |*e| h = h *% 31 +% try hashWithDispatch(self, allocator, e);
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
            const g = st.items.borrow();
            defer g.deinit();
            var h: i32 = 0;
            for (g.get().items) |*e| h = h +% try hashWithDispatch(self, allocator, e);
            return h;
        },
        .Map => |m| {
            const g = m.entries.borrow();
            defer g.deinit();
            var h: i32 = 0;
            for (g.get().pairs.items) |*kv| h = h +% ((try hashWithDispatch(self, allocator, &kv.key)) ^ (try hashWithDispatch(self, allocator, &kv.value)));
            return h;
        },
        .Pair => |pr| return (try hashWithDispatch(self, allocator, pr.first.asPtr())) *% 31 +% try hashWithDispatch(self, allocator, pr.second.asPtr()),
        .Triple => |t| return ((try hashWithDispatch(self, allocator, t.first.asPtr())) *% 31 +% try hashWithDispatch(self, allocator, t.second.asPtr())) *% 31 +% try hashWithDispatch(self, allocator, t.third.asPtr()),
        .MapEntry => |e| return (try hashWithDispatch(self, allocator, e.key.asPtr())) ^ (try hashWithDispatch(self, allocator, e.value.asPtr())),
        else => return kotlinHashCode(v),
    }
}

/// Kotlin-faithful `hashCode()` for builtin value types.
pub fn kotlinHashCode(v: *const Value) i32 {
    return switch (v.*) {
        .Null => 0,
        .Bool => |b| if (b) @as(i32, 1231) else @as(i32, 1237),
        .Char => |c| @as(i32, c),
        .Byte => |x| @as(i32, x),
        .Short => |x| @as(i32, x),
        .Int => |x| x,
        // An unsigned value class synthesizes hashCode from its SIGNED
        // storage (`UShort.data: Short`), so kotlinc hashes 65535u as -1 —
        // the sign-extended data, never the magnitude.
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
        .Pair => |p| kotlinHashCode(p.first.asPtr()) *% 31 +% kotlinHashCode(p.second.asPtr()),
        .Triple => |t| (kotlinHashCode(t.first.asPtr()) *% 31 +% kotlinHashCode(t.second.asPtr())) *% 31 +% kotlinHashCode(t.third.asPtr()),
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
            // Elements hash with their own Kotlin hashCode first: Long/ULong
            // fold high and low words (`v xor (v ushr 32)`), Int/Char/UInt
            // truncate. `(10L downTo 1L).hashCode()` needs step -1L to hash
            // as 0, not -1.
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
        // `Map.Entry.hashCode()` is `key.hashCode() xor value.hashCode()`, so a
        // Set-of-entries (a map's `entries`) folds to the map's hashCode.
        .MapEntry => |e| kotlinHashCode(e.key.asPtr()) ^ kotlinHashCode(e.value.asPtr()),
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
        else => h.update(std.mem.asBytes(&@as(i32, 7))),
    }
    return @truncate(@as(i64, @bitCast(h.final())));
}

/// Materialise an integer/char progression's elements.
pub fn materialiseRangeItems(allocator: Allocator, start: i64, end: i64, step: i64, kind: RangeKind) Allocator.Error!std.ArrayList(Value) {
    var out: std.ArrayList(Value) = .empty;
    if (step == 0) return out;
    var cur = start;
    // `inBounds` compares unsigned for ULong (so `MaxUL..MinUL` is empty). `end`
    // is the exact final element (normalized), so stop once it is yielded —
    // advancing past it would overflow/wrap (Long.MAX, or a ULong past MaxUL).
    while (kind.inBounds(cur, end, step)) {
        try out.append(allocator, rangeElem(cur, kind));
        if (cur == end) break;
        const adv = cur +| step;
        if (adv == cur) break;
        cur = adv;
    }
    return out;
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

/// `map.containsKey(needle)` honoring a key instance's custom `equals`.
pub fn mapContainsKeyEq(self: *VmHost, allocator: Allocator, entries: runtime.MapEntries, needle: *const Value) Allocator.Error!union(enum) { ok: bool, err: EvalError } {
    if (needle.* != .Instance) {
        const g = entries.borrow();
        defer g.deinit();
        for (g.get().pairs.items) |kv| {
            if (Value.structuralEqBoxed(&kv.key, needle)) return .{ .ok = true };
        }
        return .{ .ok = false };
    }
    // Snapshot keys so the `equals` call can't conflict with the borrow.
    var keys: std.ArrayList(Value) = .empty;
    defer keys.deinit(allocator);
    {
        const g = entries.borrow();
        defer g.deinit();
        for (g.get().pairs.items) |kv| try keys.append(allocator, kv.key);
    }
    for (keys.items) |k| {
        const r = try callMemberRec(self, allocator, &k, "equals", &.{needle.*});
        switch (r) {
            .ok => |rv| switch (rv) {
                .Bool => |b| if (b) return .{ .ok = true },
                else => if (Value.structuralEqBoxed(&k, needle)) return .{ .ok = true },
            },
            .err => if (Value.structuralEqBoxed(&k, needle)) return .{ .ok = true },
        }
    }
    return .{ .ok = false };
}

/// Build a builtin `Value::Map` from a user `Map` implementation.
pub fn materializeUserMap(self: *VmHost, allocator: Allocator, recv: *const Value) Allocator.Error!EvalResult {
    // `entries` is a property (custom getter), so read it through the field
    // path; a plain method dispatch would not resolve a property getter.
    const entries_r = try getFieldRec(self, allocator, recv, "entries");
    const entries_val = switch (entries_r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    // `entries_val` is an owned container (host-returns-owned). entry_items only
    // borrows its elements; the pairs loop retains what it keeps, so release it
    // at function exit. No-op under the arena fast path.
    defer if (runtime.reclaimEnabled()) entries_val.release(allocator);
    // The Instance arm drains into an owned list whose elements `entry_items`
    // borrows; keep it alive until after the pairs loop, then release.
    var drained: ?Value = null;
    defer if (runtime.reclaimEnabled()) if (drained) |d| d.release(allocator);
    var entry_items: std.ArrayList(Value) = .empty;
    defer entry_items.deinit(allocator);
    switch (entries_val) {
        .Set => |s| {
            const g = s.items.borrow();
            defer g.deinit();
            try entry_items.appendSlice(allocator, g.get().items);
        },
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            try entry_items.appendSlice(allocator, g.get().items);
        },
        .Instance => {
            const dr = try drainIterableToList(self, allocator, &entries_val);
            switch (dr) {
                .ok => |dv| {
                    drained = dv; // released after the pairs loop (see defer)
                    switch (dv) {
                        .List => |l| {
                            const g = l.items.borrow();
                            defer g.deinit();
                            try entry_items.appendSlice(allocator, g.get().items);
                        },
                        else => {},
                    }
                },
                .err => |e| return .{ .err = e },
            }
        },
        else => {},
    }
    var pairs: std.ArrayList(MapPair) = .empty;
    for (entry_items.items) |e| {
        const kv = try mapEntryKv(self, allocator, &e);
        switch (kv) {
            .ok => |pair| try pairs.append(allocator, pair),
            .err => |err| {
                pairs.deinit(allocator);
                return .{ .err = err };
            },
        }
    }
    return .{ .ok = try Value.newMap(allocator, .{ .entries = try runtime.MapEntries.init(allocator, .{ .pairs = pairs }), .mutable = false }) };
}

/// Extract `(key, value)` from a map-entry value.
fn mapEntryKv(self: *VmHost, allocator: Allocator, e: *const Value) Allocator.Error!union(enum) { ok: MapPair, err: EvalError } {
    switch (e.*) {
        .MapEntry => |me| {
            const k = me.key.asPtr().*;
            const v = me.value.asPtr().*;
            k.retain();
            v.retain();
            return .{ .ok = .{ .key = k, .value = v } };
        },
        .Pair => |p| {
            const k = p.first.asPtr().*;
            const v = p.second.asPtr().*;
            k.retain();
            v.retain();
            return .{ .ok = .{ .key = k, .value = v } };
        },
        else => {
            const kr = try callMemberRec(self, allocator, e, "key", &.{});
            const k = switch (kr) {
                .ok => |v| v,
                .err => |err| return .{ .err = err },
            };
            const vr = try callMemberRec(self, allocator, e, "value", &.{});
            const v = switch (vr) {
                .ok => |v| v,
                .err => |err| return .{ .err = err },
            };
            return .{ .ok = .{ .key = k, .value = v } };
        },
    }
}

/// Read a boxed component slot and return an owned copy to the interpreter.
/// The boxed `Value` stays in its slot; the caller receives its own ref.
fn extractOwned(box: runtime.ObjRef(Value)) EvalResult {
    const out = box.asPtr().*;
    out.retain();
    return .{ .ok = out };
}

// -------------------------------------------------------------------------
// `drainIterableToList` — used by the Iterable fallback and
// `materializeUserMap`. Drains a user `iterator()` into a builtin List.
// -------------------------------------------------------------------------

pub fn drainIterableToList(self: *VmHost, allocator: Allocator, receiver: *const Value) Allocator.Error!EvalResult {
    const iter_r = try callMemberRec(self, allocator, receiver, "iterator", &.{});
    const iter = switch (iter_r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    // `iter` is an owned iterator container (host-returns-owned); release it on
    // every exit path. The per-next() elements are transferred into `items`.
    defer if (runtime.reclaimEnabled()) iter.release(allocator);
    var items: std.ArrayList(Value) = .empty;
    var guard: usize = 0;
    while (guard < 1_000_000) : (guard += 1) {
        const hn_r = try callMemberRec(self, allocator, &iter, "hasNext", &.{});
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
        const nx_r = try callMemberRec(self, allocator, &iter, "next", &.{});
        switch (nx_r) {
            .ok => |v| try items.append(allocator, v),
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

/// Materialise a lazy sequence pipeline into a list. Delegates to the
/// stdlib sequence materialiser through a `VmIntrinsicHost`.
fn materialiseSequence(self: *VmHost, allocator: Allocator, seq_val: *const Value) Allocator.Error!union(enum) { ok: std.ArrayList(Value), err: EvalError } {
    var sink = self.out_sink;
    var intrinsic = makeIntrinsicHost(self);
    defer deinitIntrinsicHost(&intrinsic);
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

/// `cloneItemsList` for an `Array` receiver (boxed or packed): an owned,
/// element-retained `ArrayList` copy for a new wrapper (iterator, list, …).
fn cloneArrayItems(allocator: Allocator, arr: runtime.ArrayData) Allocator.Error!std.ArrayList(Value) {
    const snap = try arr.snapshot(allocator);
    defer if (runtime.freeScratch()) allocator.free(snap);
    var out: std.ArrayList(Value) = .empty;
    try out.appendSlice(allocator, snap);
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return out;
}

pub fn builtinIterator(self: *VmHost, allocator: Allocator, receiver: *const Value) Allocator.Error!?EvalResult {
    _ = self;
    // An array `.asList()` view re-reads its scalar source so the iterator
    // snapshot reflects later array writes.
    receiver.refreshArrayView();
    receiver.refreshSublistView();
    switch (receiver.*) {
        .List => |l| {
            if (stdlib.implementations.collections.sublistViewStale(receiver)) {
                return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
            }
            // A mutable list shares its backing so `MutableIterator.remove()`
            // mutates the source (and the iterating loop observes it); an
            // immutable list snapshots, as before. A live map `values` view is
            // also mutable (no read-only error; CME still fires on concurrent
            // map modification); only a genuinely read-only list snapshots.
            if (l.mutable and !stdlib.implementations.collections.modCountFrozen(l.mod_count)) {
                const cap = try captureModCount(allocator, l.mod_count.get());
                return .{ .ok = try Value.newIterator(allocator, .{ .items = l.items.clone(), .prim = null, .mod_count = .from(cap.mod_count), .mutable = true, .pos = 0, .exp_mod = cap.exp_mod }) };
            }
            // A snapshot iterator (immutable list, or a live map `values` view):
            // still capture `mod_count` so a concurrent structural change to the
            // source (the map) fails the iterator fast.
            const items = try cloneItemsList(allocator, l.items);
            const cap = try captureModCount(allocator, l.mod_count.get());
            return .{ .ok = try Value.newIterator(allocator, .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .prim = null, .mod_count = .from(cap.mod_count), .pos = 0, .exp_mod = cap.exp_mod }) };
        },
        .Set => |s| {
            // A mutable set shares its backing so `MutableIterator.remove()`
            // mutates the source set (the `filterInPlace` removeAll/retainAll
            // path iterates + removes); an immutable set snapshots. A live map
            // `keys`/`entries` view is also mutable (its iterator supports
            // remove and reports CME on concurrent map modification); only a
            // genuinely read-only set yields a read-only iterator.
            if (s.mutable and !stdlib.implementations.collections.modCountFrozen(s.mod_count)) {
                const cap = try captureModCount(allocator, s.mod_count.get());
                return .{ .ok = try Value.newIterator(allocator, .{ .items = s.items.clone(), .prim = null, .mod_count = .from(cap.mod_count), .mutable = true, .pos = 0, .exp_mod = cap.exp_mod }) };
            }
            // Snapshot iterator (immutable set, or a live map `keys`/`entries`
            // view): capture `mod_count` so a concurrent map mutation fails fast.
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
                // A mutable map's iterator yields live entries: `setValue`
                // writes through, and `MutableIterator.remove` deletes from the
                // backing via this reference (the `items` list is a snapshot).
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
            return .{ .ok = try Value.newIterator(allocator, .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .prim = arr.prim, .pos = 0, .exp_mod = 0 }) };
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

pub fn sequenceMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const seq = receiver.Sequence;
    // `Sequence.iterator()` is lazy: a `SeqIter` pulls one element at a time so
    // an infinite source never materialises (`sequence{}` / `generateSequence`).
    if (std.mem.eql(u8, name, "iterator") and args.len == 0) {
        // A `sequence{}`/`iterator{}` builder Sequence is re-iterable: each
        // `iterator()` drives a fresh coroutine cursor (clone), leaving the
        // embedded template untouched so a second consumption is not empty.
        {
            var intrinsic = makeIntrinsicHost(self);
            defer deinitIntrinsicHost(&intrinsic);
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
    // `zip` with a Sequence argument is lazy: a `Merged` source pulls both
    // children alternately (left, then right, one element per output pair),
    // so shared-state builders observe `MergingSequence`'s interleave
    // instead of two full materialisations back to back.
    if (std.mem.eql(u8, name, "zip") and (args.len == 1 or args.len == 2) and args[0] == .Sequence) {
        var left = receiver.*;
        var right = args[0];
        if (runtime.reclaimEnabled()) {
            left.retain();
            right.retain();
        }
        const transform: ?runtime.ValueBox = if (args.len == 2) blk: {
            var t = args[1];
            if (runtime.reclaimEnabled()) t.retain();
            break :blk try Value.boxRef(allocator, t);
        } else null;
        return .{ .ok = .{ .Sequence = try ObjRef(SequenceData).init(allocator, .{
            .source = .{ .Merged = .{
                .left = try Value.boxRef(allocator, left),
                .right = try Value.boxRef(allocator, right),
                .transform = transform,
            } },
            .ops = &.{},
        }) } };
    }
    const terminal = isSequenceTerminal(name);
    if (terminal) {
        const m = try materialiseSequence(self, allocator, receiver);
        const items = switch (m) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
        const as_list = try listOf(allocator, items, false);
        var margs = try allocator.alloc(Value, args.len);
        for (args, 0..) |a, i| {
            if (a == .Sequence) {
                const ms = try materialiseSequence(self, allocator, &a);
                switch (ms) {
                    .ok => |it| margs[i] = try listOf(allocator, it, false),
                    .err => |e| return .{ .err = e },
                }
            } else margs[i] = a;
        }
        return try callMemberRec(self, allocator, &as_list, name, margs);
    }
    // Pipeline ops.
    const new_op: ?SeqOp = blk: {
        if (std.mem.eql(u8, name, "map") and args.len == 1) break :blk .{ .Map = args[0] };
        if (std.mem.eql(u8, name, "onEach") and args.len == 1) break :blk .{ .OnEach = args[0] };
        if (std.mem.eql(u8, name, "mapIndexed") and args.len == 1) break :blk .{ .MapIndexed = args[0] };
        if (std.mem.eql(u8, name, "filterIndexed") and args.len == 1) break :blk .{ .FilterIndexed = args[0] };
        if (std.mem.eql(u8, name, "filter") and args.len == 1) break :blk .{ .Filter = args[0] };
        if (std.mem.eql(u8, name, "filterNot") and args.len == 1) break :blk .{ .FilterNot = args[0] };
        if (std.mem.eql(u8, name, "take") and args.len == 1) {
            if (args[0].asI64()) |n| {
                if (n < 0) {
                    const msg = try std.fmt.allocPrint(allocator, "Requested element count {d} is less than zero.", .{n});
                    return .{ .err = try throwExc(allocator, "kotlin.IllegalArgumentException", msg) };
                }
                break :blk .{ .Take = n };
            }
        }
        if (std.mem.eql(u8, name, "drop") and args.len == 1) {
            if (args[0].asI64()) |n| {
                if (n < 0) {
                    const msg = try std.fmt.allocPrint(allocator, "Requested element count {d} is less than zero.", .{n});
                    return .{ .err = try throwExc(allocator, "kotlin.IllegalArgumentException", msg) };
                }
                break :blk .{ .Drop = n };
            }
        }
        if (std.mem.eql(u8, name, "takeWhile") and args.len == 1) break :blk .{ .TakeWhile = args[0] };
        if (std.mem.eql(u8, name, "dropWhile") and args.len == 1) break :blk .{ .DropWhile = args[0] };
        if (std.mem.eql(u8, name, "flatMap") and args.len == 1) break :blk .{ .FlatMap = args[0] };
        if (std.mem.eql(u8, name, "distinct") and args.len == 0) break :blk .Distinct;
        if (std.mem.eql(u8, name, "distinctBy") and args.len == 1) break :blk .{ .DistinctBy = args[0] };
        if (std.mem.eql(u8, name, "sorted") and args.len == 0) break :blk .{ .Sorted = false };
        if (std.mem.eql(u8, name, "sortedDescending") and args.len == 0) break :blk .{ .Sorted = true };
        if (std.mem.eql(u8, name, "sortedBy") and args.len == 1) break :blk .{ .SortedBy = .{ .selector = args[0], .descending = false } };
        if (std.mem.eql(u8, name, "sortedByDescending") and args.len == 1) break :blk .{ .SortedBy = .{ .selector = args[0], .descending = true } };
        if (std.mem.eql(u8, name, "sortedWith") and args.len == 1) break :blk .{ .SortedWith = args[0] };
        break :blk null;
    };
    if (new_op) |op| {
        const g = seq.borrow();
        const src = g.get().source;
        const old_ops = g.get().ops;
        var ops = try allocator.alloc(SeqOp, old_ops.len + 1);
        @memcpy(ops[0..old_ops.len], old_ops);
        ops[old_ops.len] = op;
        g.deinit();
        return .{ .ok = .{ .Sequence = try ObjRef(SequenceData).init(allocator, .{ .source = src, .ops = ops }) } };
    }
    return null;
}

pub fn isSequenceTerminal(name: []const u8) bool {
    const terms = [_][]const u8{
        "toList",    "toMutableList", "toSet",        "count",        "sum",         "average",
        "sumOf",     "last",          "lastOrNull",   "forEach",      "fold",        "reduce",
        "iterator",  "max",           "maxOrNull",    "min",          "minOrNull",   "maxBy",
        "minBy",     "maxByOrNull",   "minByOrNull",  "maxOf",        "minOf",       "joinToString",
        "all",       "contains",      "groupBy",      "associate",    "associateBy", "associateWith",
        "partition", "indexOf",       "indexOfFirst", "toMap",        "toHashSet",   "toMutableSet",
        "zip",       "unzip",         "plus",         "reduceOrNull", "foldRight",   "reduceRight",
    };
    for (terms) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

pub fn sortedInstances(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    var snap = try cloneItemsList(allocator, receiver.List.items);
    defer snap.deinit(allocator);
    var has_inst = false;
    for (snap.items) |v| {
        if (v == .Instance) has_inst = true;
    }
    if (!has_inst) return null;
    var sorted: std.ArrayList(Value) = .empty;
    try sorted.appendSlice(allocator, snap.items);
    const descending = std.mem.eql(u8, name, "sortedDescending");
    var i: usize = 1;
    while (i < sorted.items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const a = sorted.items[j - 1];
            const b = sorted.items[j];
            const cmp_r = try callMemberRec(self, allocator, &a, "compareTo", &.{b});
            const ncmp: i64 = switch (cmp_r) {
                .ok => |v| v.asI64() orelse 0,
                .err => |e| {
                    sorted.deinit(allocator);
                    return .{ .err = e };
                },
            };
            const greater = if (descending) ncmp < 0 else ncmp > 0;
            if (greater) {
                std.mem.swap(Value, &sorted.items[j - 1], &sorted.items[j]);
                j -= 1;
            } else break;
        }
    }
    return .{ .ok = try listOf(allocator, sorted, false) };
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

/// Natural-order compare falling back to the user `compareTo` when the
/// pair is not builtin-comparable (Uuid, user Comparable classes).
fn compareValuesHostAware(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) Allocator.Error!union(enum) { ord: Ordering, err: EvalError } {
    if (compareValuesBuiltin(a, b)) |o| return .{ .ord = o };
    const r = try callMemberRec(self, allocator, a, "compareTo", &.{b.*});
    switch (r) {
        .ok => |v| {
            const i = v.asI64() orelse return .{ .err = try typeErr(allocator, "incomparable values", .{}) };
            return .{ .ord = if (i < 0) .lt else if (i > 0) .gt else .eq };
        },
        .err => |e| return .{ .err = e },
    }
}

/// Builtin natural-order comparison. `null` when the pair is not
/// builtin-comparable (mirrors `compare_values` rejecting Instances).
pub fn compareValuesBuiltin(a: *const Value, b: *const Value) ?Ordering {
    // Kotlin `compareValues`: null is ordered first (null < non-null, null ==
    // null). A `compareBy { selectorReturningNull }` relies on this.
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
    // `Comparator` is a `fun interface`, so `comparator(a, b)` and an explicit
    // `comparator.invoke(a, b)` both call `compare`.
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
                        if (self.closures.get(@intCast(c.id))) |info| break :blk info.n_params;
                        break :blk 1;
                    },
                    else => 1,
                };
                const o: Ordering = if (n_params >= 2) blk: {
                    const r = try callValueRec(self, allocator, &sel, &.{ a, b });
                    const nval: i64 = switch (r) {
                        .ok => |v| v.asI64() orelse 0,
                        .err => |e| return .{ .err = e },
                    };
                    break :blk if (nval < 0) .lt else if (nval > 0) .gt else .eq;
                } else blk: {
                    const ka_r = try callValueRec(self, allocator, &sel, &.{a});
                    const ka = switch (ka_r) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    const kb_r = try callValueRec(self, allocator, &sel, &.{b});
                    const kb = switch (kb_r) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    // `compareBy(comparator, selector)`: order the selected keys
                    // by the step's comparator rather than their natural order.
                    if (step.key_comparator) |kc| {
                        const r = try callMemberRec(self, allocator, &kc, "compare", &.{ ka, kb });
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
        // Read-only, fixed-size live view over the array (element writes show
        // through); not a copy.
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
            // `CharArray.concatToString(startIndex, endIndex)` validates via
            // `checkBoundsIndexes`: out-of-range bounds throw
            // IndexOutOfBoundsException, an inverted range throws
            // IllegalArgumentException.
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

pub fn collectionMutators(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    // `+= elements` / `-= elements` over a multi-element collection argument
    // flattens (addAll / removeAll); a single element add/removes that one
    // element. Delegate the collection case so dedup / element semantics stay
    // in one place.
    const arg_is_multi = args.len == 1 and switch (args[0]) {
        .List, .Set, .Range, .Sequence, .Array => true,
        else => false,
    };
    switch (receiver.*) {
        .List => |l| {
            if (!l.mutable) return null;
            if (std.mem.eql(u8, name, "plusAssign") and args.len == 1) {
                if (arg_is_multi) return try self.callMember(allocator, receiver, "addAll", args);
                const g = l.items.borrowMut();
                defer g.deinit();
                try g.get().append(allocator, args[0]);
                return .{ .ok = .Unit };
            }
            if (std.mem.eql(u8, name, "minusAssign") and args.len == 1) {
                if (arg_is_multi) return try self.callMember(allocator, receiver, "removeAll", args);
                const g = l.items.borrowMut();
                defer g.deinit();
                for (g.get().items, 0..) |x, idx| {
                    if (Value.structuralEq(&x, &args[0])) {
                        _ = g.get().orderedRemove(idx);
                        break;
                    }
                }
                return .{ .ok = .Unit };
            }
        },
        .Set => |s| {
            if (!s.mutable) return null;
            if (std.mem.eql(u8, name, "plusAssign") and args.len == 1) {
                if (arg_is_multi) return try self.callMember(allocator, receiver, "addAll", args);
                const g = s.items.borrowMut();
                defer g.deinit();
                var present = false;
                for (g.get().items) |x| {
                    if (Value.structuralEq(&x, &args[0])) present = true;
                }
                if (!present) try g.get().append(allocator, args[0]);
                return .{ .ok = .Unit };
            }
            if (std.mem.eql(u8, name, "minusAssign") and args.len == 1) {
                if (arg_is_multi) return try self.callMember(allocator, receiver, "removeAll", args);
                const g = s.items.borrowMut();
                defer g.deinit();
                for (g.get().items, 0..) |x, idx| {
                    if (Value.structuralEq(&x, &args[0])) {
                        _ = g.get().orderedRemove(idx);
                        break;
                    }
                }
                return .{ .ok = .Unit };
            }
        },
        .Map => |m| {
            if (!m.mutable) return null;
            if (std.mem.eql(u8, name, "plusAssign") and args.len == 1) {
                var to_put: std.ArrayList(MapPair) = .empty;
                defer to_put.deinit(allocator);
                const a2 = args[0];
                switch (a2) {
                    .Pair => |p| {
                        const k = p.first.asPtr().*;
                        const v = p.second.asPtr().*;
                        k.retain();
                        v.retain();
                        try to_put.append(allocator, .{ .key = k, .value = v });
                    },
                    .Map => |other| {
                        const og = other.entries.borrow();
                        defer og.deinit();
                        // Entries are borrowed from `other`; the destination map
                        // owns its own ref per key+value, so retain each.
                        for (og.get().pairs.items) |kv| {
                            if (runtime.reclaimEnabled()) {
                                kv.key.retain();
                                kv.value.retain();
                            }
                            try to_put.append(allocator, kv);
                        }
                    },
                    .List => |lst| try collectPairs(allocator, &to_put, lst.items),
                    .Set => |st| try collectPairs(allocator, &to_put, st.items),
                    .Array => |arr| if (arr.boxedList()) |bl| try collectPairs(allocator, &to_put, bl),
                    .Sequence => {
                        const ms = try materialiseSequence(self, allocator, &a2);
                        var items = switch (ms) {
                            .ok => |it| it,
                            .err => |e| return .{ .err = e },
                        };
                        defer items.deinit(allocator);
                        for (items.items) |v| {
                            if (v == .Pair) {
                                const k = v.Pair.first.asPtr().*;
                                const val = v.Pair.second.asPtr().*;
                                k.retain();
                                val.retain();
                                try to_put.append(allocator, .{ .key = k, .value = val });
                            }
                        }
                    },
                    else => {},
                }
                const g = m.entries.borrowMut();
                defer g.deinit();
                for (to_put.items) |kv| {
                    var found = false;
                    for (g.get().pairs.items) |*slot| {
                        if (Value.structuralEq(&slot.key, &kv.key)) {
                            // Overwrite: release the displaced value and the
                            // staged (now-orphaned) key; transfer the staged value.
                            if (runtime.reclaimEnabled()) {
                                slot.value.release(allocator);
                                kv.key.release(allocator);
                            }
                            slot.value = kv.value;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try g.get().pairs.append(allocator, kv);
                        try g.get().noteAppended(allocator, g.get().pairs.items.len - 1);
                    }
                }
                return .{ .ok = .Unit };
            }
        },
        else => {},
    }
    return null;
}

fn collectPairs(allocator: Allocator, out: *std.ArrayList(MapPair), items: runtime.ValueList) Allocator.Error!void {
    const g = items.borrow();
    defer g.deinit();
    for (g.get().items) |v| {
        if (v == .Pair) {
            const k = v.Pair.first.asPtr().*;
            const val = v.Pair.second.asPtr().*;
            k.retain();
            val.retain();
            try out.append(allocator, .{ .key = k, .value = val });
        }
    }
}

/// Element-wise equality for builtin Lists whose elements include user
/// INSTANCES (a `windowed` tail yields the raw `RingBuffer`, a List on
/// the JVM). Pure structural equality cannot dispatch the element's
/// `equals`; this walks pairs, dispatching through the member walk when
/// either side is an Instance. Returns null when neither operand needs
/// host dispatch (caller falls back to the pure compare).
pub fn collectionsEqualHostAware(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) ?bool {
    if (a.* != .List or b.* != .List) return null;
    const needs_host = blk: {
        inline for ([_]*const Value{ a, b }) |v| {
            const g = v.List.items.borrow();
            defer g.deinit();
            for (g.get().items) |e| {
                if (e == .Instance) break :blk true;
            }
        }
        break :blk false;
    };
    if (!needs_host) return null;
    const ga = a.List.items.borrow();
    defer ga.deinit();
    const gb = b.List.items.borrow();
    defer gb.deinit();
    const ia = ga.get().items;
    const ib = gb.get().items;
    if (ia.len != ib.len) return false;
    for (ia, ib) |ea, eb| {
        if (ea == .Instance or eb == .Instance) {
            const recv = if (ea == .Instance) &ea else &eb;
            const arg = if (ea == .Instance) eb else ea;
            const r = callMemberRec(self, allocator, recv, "equals", &.{arg}) catch return false;
            switch (r) {
                .ok => |v| {
                    if (!(v == .Bool and v.Bool)) return false;
                },
                .err => return false,
            }
            continue;
        }
        if (ea == .List or eb == .List) {
            if (collectionsEqualHostAware(self, allocator, &ea, &eb)) |eq| {
                if (!eq) return false;
                continue;
            }
        }
        if (!Value.structuralEqBoxed(&ea, &eb)) return false;
    }
    return true;
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
            // A live entry (backing set) is a view: after a structural map
            // change every member access throws CME; before that, reads
            // resolve the live pair so non-structural value updates show
            // through (JVM HashMap.Node semantics for reads, common-code
            // fail-fast semantics for structural changes).
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
                for (g.get().pairs.items) |*slot| {
                    if (Value.structuralEq(&slot.key, me.key.asPtr())) {
                        const live = slot.value;
                        if (!Value.structuralEq(me.value.asPtr(), &live)) {
                            if (runtime.reclaimEnabled()) {
                                live.retain();
                                me.value.asPtr().release(allocator);
                            }
                            me.value.asPtr().* = live;
                        }
                        break;
                    }
                }
                g.deinit();
            }
            if (std.mem.eql(u8, name, "component1") or std.mem.eql(u8, name, "key")) return extractOwned(me.key);
            if (std.mem.eql(u8, name, "component2") or std.mem.eql(u8, name, "value")) return extractOwned(me.value);
            // `Map.Entry` equality contract: compare by key and value, so a
            // builtin entry equals a user `Map.Entry` instance with the same
            // key/value (`structuralEqBoxed` applies the contract).
            if (std.mem.eql(u8, name, "equals") and args.len == 1) return .{ .ok = boolVal(Value.structuralEqBoxed(receiver, &args[0])) };
            if (std.mem.eql(u8, name, "hashCode") and args.len == 0) return .{ .ok = .{ .Int = kotlinHashCode(receiver) } };
            if (std.mem.eql(u8, name, "setValue")) {
                // No backing = a read-only map's entry: mutation throws
                // instead of silently succeeding on the snapshot.
                if (!me.backing.isSome()) {
                    return .{ .err = try throwExc(allocator, "kotlin.UnsupportedOperationException", null) };
                }
                const new_v = if (args.len > 0) args[0] else Value.Unit;
                const prev = me.value.asPtr().*;
                // host-returns-owned: the old value escapes as the result.
                if (runtime.reclaimEnabled()) prev.retain();
                if (me.backing.get()) |entries| {
                    const g = entries.borrowMut();
                    defer g.deinit();
                    for (g.get().pairs.items) |*slot| {
                        if (Value.structuralEq(&slot.key, me.key.asPtr())) {
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
                (receiverImplementsType(self, receiver, "Entry") or receiverImplementsType(self, receiver, "MutableEntry")))
            {
                // getFieldRec returns the field borrowed; this result escapes
                // through callMember, so retain (host-returns-owned).
                var r = try getFieldRec(self, allocator, receiver, "key");
                if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
                return r;
            }
            if (std.mem.eql(u8, name, "component2") and
                (receiverImplementsType(self, receiver, "Entry") or receiverImplementsType(self, receiver, "MutableEntry")))
            {
                var r = try getFieldRec(self, allocator, receiver, "value");
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

/// Capture a list's `mod_count` (shared) plus its current value (the iterator's
/// expectation), so the iterator can fail-fast. `mod_count` is null for a
/// read-only / un-counted source, which makes the expectation meaningless.
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

/// A fresh cursor box for an iterator starting at `start`.
/// `ConcurrentModificationException` when the source mutated structurally since
/// the iterator captured it (`null` when consistent or uncounted).
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

/// After the iterator's OWN structural mutation, resync its expectation so the
/// next `next`/`hasNext` does not flag its own change as concurrent.
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

/// The iterator's own `add`/`remove` is a structural change of the backing list
/// (it mutates `items` directly, bypassing the list intrinsics): bump the shared
/// `mod_count` so OTHER iterators fail-fast, then resync this one's expectation.
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

/// Copy the iterator state cell's field handles/scalars out of one borrow.
/// The returned handles are unretained copies — valid while the caller's
/// `ObjRef(IterCursor)` keeps the cell alive (the receiver does).
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

pub fn iteratorMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    _ = self;
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
        // A live map entry is re-stamped at yield time, so entries handed
        // out after an iterator-driven structural change stay readable while
        // earlier ones fail fast.
        if (v == .MapEntry) {
            if (v.MapEntry.backing.get()) |entries| {
                v.MapEntry.exp_mod = mapEntriesCounter(entries);
            }
        }
        // Borrowed element: the backing list still owns it, so retain before
        // handing it to the register that will own the iteration result.
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
    // `ListIterator` navigation over the same `items`/`pos` cursor.
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
    // `MutableListIterator.set(x)` — overwrite the element last returned.
    if (std.mem.eql(u8, name, "set") and args.len == 1) {
        // Check concurrent modification before the read-only guard: a
        // mutable collection's view iterator modified during iteration must
        // report CME, while a genuinely immutable iterator (whose mod count
        // never advances) still falls through to UnsupportedOperationException.
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
    // `MutableListIterator.add(x)` — insert before the element a subsequent
    // `next()` would return (at the cursor) and advance the cursor past it,
    // so the inserted element is skipped by the following `next()`.
    if (std.mem.eql(u8, name, "add") and args.len == 1) {
        // Check concurrent modification before the read-only guard: a
        // mutable collection's view iterator modified during iteration must
        // report CME, while a genuinely immutable iterator (whose mod count
        // never advances) still falls through to UnsupportedOperationException.
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
    // `MutableIterator.remove()` — drop the element last returned by `next()`
    // (at `pos - 1`) from the backing list and rewind the cursor so the
    // following `next()` resumes correctly. A no-op before the first `next()`.
    if (std.mem.eql(u8, name, "remove") and args.len == 0) {
        // Check concurrent modification before the read-only guard: a
        // mutable collection's view iterator modified during iteration must
        // report CME, while a genuinely immutable iterator (whose mod count
        // never advances) still falls through to UnsupportedOperationException.
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
            // A map iterator's element is a live MapEntry over a snapshot list;
            // also delete the entry from the backing map (by key).
            if (removed == .MapEntry) {
                if (removed.MapEntry.backing.get()) |entries| {
                    const eg = entries.borrowMut();
                    defer eg.deinit();
                    const key = removed.MapEntry.key.asPtr();
                    for (eg.get().pairs.items, 0..) |*slot, i| {
                        if (Value.structuralEq(&slot.key, key)) {
                            if (runtime.reclaimEnabled()) {
                                slot.key.release(allocator);
                                slot.value.release(allocator);
                            }
                            _ = eg.get().pairs.orderedRemove(i);
                            break;
                        }
                    }
                }
            }
            _ = g.get().orderedRemove(lu);
            // The cursor slides back only when the removed slot was
            // BEFORE it (remove-after-next); after previous() the cursor
            // already sits at the removed index.
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

pub fn rangeIterMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    _ = self;
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
        const adv = c +| snap.step;
        // `end` is the exact final element; once it is yielded, stop. Also stop
        // if the cursor saturates (`adv == c`). Both avoid advancing past the
        // end — a Long.MAX overflow or a ULong wrap past MaxUL that `more`
        // (unsigned for ULong) would otherwise read as still in-bounds.
        const sg = ri.borrowMut();
        if (c == snap.end or adv == c) {
            sg.get().done = true;
        } else {
            sg.get().cur = adv;
        }
        sg.deinit();
        return .{ .ok = rangeElem(c, snap.kind) };
    }
    return null;
}

// -------------------------------------------------------------------------
// Lazy `SeqIter` — one-element-at-a-time iteration over a `Sequence` (the
// `Sequence.iterator()` / `iterator { }` result). Pulls a single source
// element per step and runs it through the op pipeline, so an infinite source
// is never materialised.
// -------------------------------------------------------------------------

const SeqIterState = runtime.SeqIterState;

/// Lazily allocate the per-op streaming counters on first use.
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

/// Pull one raw element from the sequence source (no ops). Returns the element,
/// `null` at exhaustion, or an error.
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
            var intrinsic = makeIntrinsicHost(self);
            defer deinitIntrinsicHost(&intrinsic);
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
            var intrinsic = makeIntrinsicHost(self);
            defer deinitIntrinsicHost(&intrinsic);
            const ihost = intrinsic.intrinsicHost();
            if (st.iter_obj == null) {
                const r = try ihost.invokeCallable(&fnbox.asPtr().*, &.{}, out);
                switch (r) {
                    .ok => |v| st.iter_obj = v,
                    .err => |re| return .{ .err = try mapRuntimeError(allocator, re) },
                }
            }
            const iter = st.iter_obj.?;
            const hn = try callMemberRec(self, allocator, &iter, "hasNext", &.{});
            const has = switch (hn) {
                .ok => |x| x == .Bool and x.Bool,
                .err => |e| return .{ .err = e },
            };
            if (!has) {
                st.done = true;
                return .done;
            }
            const nx = try callMemberRec(self, allocator, &iter, "next", &.{});
            return switch (nx) {
                .ok => |v| .{ .value = v },
                .err => |e| .{ .err = e },
            };
        },
        .Merged => |mz| {
            if (st.done) return .done;
            if (st.iter_left == null) {
                switch (try callMemberRec(self, allocator, &mz.left.asPtr().*, "iterator", &.{})) {
                    .ok => |v| st.iter_left = v,
                    .err => |e| return .{ .err = e },
                }
                switch (try callMemberRec(self, allocator, &mz.right.asPtr().*, "iterator", &.{})) {
                    .ok => |v| st.iter_right = v,
                    .err => |e| return .{ .err = e },
                }
            }
            const lit = st.iter_left.?;
            const rit = st.iter_right.?;
            // Strict interleave: left hasNext, right hasNext, left next,
            // right next — the order `MergingSequence` pulls in.
            const lh = switch (try callMemberRec(self, allocator, &lit, "hasNext", &.{})) {
                .ok => |x| x == .Bool and x.Bool,
                .err => |e| return .{ .err = e },
            };
            if (!lh) {
                st.done = true;
                return .done;
            }
            const rh = switch (try callMemberRec(self, allocator, &rit, "hasNext", &.{})) {
                .ok => |x| x == .Bool and x.Bool,
                .err => |e| return .{ .err = e },
            };
            if (!rh) {
                st.done = true;
                return .done;
            }
            const av = switch (try callMemberRec(self, allocator, &lit, "next", &.{})) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            const bv = switch (try callMemberRec(self, allocator, &rit, "next", &.{})) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            if (mz.transform) |t| {
                var intrinsic = makeIntrinsicHost(self);
                defer deinitIntrinsicHost(&intrinsic);
                const ihost = intrinsic.intrinsicHost();
                const r = try ihost.invokeCallable(&t.asPtr().*, &.{ av, bv }, out);
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
                    var sv = s.asPtr().*;
                    if (gen.seed_is_fn) {
                        var intr = makeIntrinsicHost(self);
                        defer deinitIntrinsicHost(&intr);
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
                                st.gen_cur = v;
                                return .{ .value = v };
                            },
                            .err => |re| return .{ .err = try mapRuntimeError(allocator, re) },
                        }
                    }
                    if (runtime.reclaimEnabled()) sv.retain();
                    st.gen_cur = sv;
                    return .{ .value = sv };
                }
                // Nullary form: first element comes from next().
            }
            var intrinsic = makeIntrinsicHost(self);
            defer deinitIntrinsicHost(&intrinsic);
            const ihost = intrinsic.intrinsicHost();
            const arg: []const Value = if (st.gen_cur) |c| &.{c} else &.{};
            const r = try ihost.invokeCallable(&gen.next.asPtr().*, arg, out);
            switch (r) {
                .ok => |nv| {
                    if (nv == .Null) {
                        st.done = true;
                        return .done;
                    }
                    var v = nv;
                    if (runtime.reclaimEnabled()) v.retain();
                    st.gen_cur = v;
                    return .{ .value = v };
                },
                .err => |re| return .{ .err = try mapRuntimeError(allocator, re) },
            }
        },
    }
}

/// Pull one OUTPUT element: pull source elements and run each through the ops
/// until one passes (or the source is exhausted / a Take cap is hit).
fn seqIterPull(self: *VmHost, allocator: Allocator, st: *SeqIterState, out: runtime.Output) Allocator.Error!union(enum) { value: Value, done, err: EvalError } {
    const n_ops = blk: {
        const sg = st.seq.Sequence.borrow();
        defer sg.deinit();
        break :blk sg.get().ops.len;
    };
    try seqIterEnsureState(allocator, st, n_ops);

    var intrinsic = makeIntrinsicHost(self);
    defer deinitIntrinsicHost(&intrinsic);
    const ihost = intrinsic.intrinsicHost();

    outer: while (true) {
        // Stop pulling the source once any Take cap is reached.
        {
            const sg = st.seq.Sequence.borrow();
            const ops = sg.get().ops;
            var capped = false;
            for (ops, 0..) |op, i| {
                if (op == .Take and st.taken[i] >= @as(usize, @intCast(@max(op.Take, 0)))) capped = true;
            }
            sg.deinit();
            if (capped) return .done;
        }

        var current = switch (try seqIterSourcePull(self, allocator, st, out)) {
            .value => |v| v,
            .done => return .done,
            .err => |e| return .{ .err = e },
        };

        const sg = st.seq.Sequence.borrow();
        const ops = sg.get().ops;
        for (ops, 0..) |op, idx| {
            switch (op) {
                .Map => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| current = rv,
                        .err => |e| {
                            sg.deinit();
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .OnEach => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    if (r == .err) {
                        sg.deinit();
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
                            sg.deinit();
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
                            sg.deinit();
                            continue :outer;
                        },
                        .err => |e| {
                            sg.deinit();
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .Filter => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| if (!(rv == .Bool and rv.Bool)) {
                            sg.deinit();
                            continue :outer;
                        },
                        .err => |e| {
                            sg.deinit();
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .FilterNot => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| if (rv == .Bool and rv.Bool) {
                            sg.deinit();
                            continue :outer;
                        },
                        .err => |e| {
                            sg.deinit();
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .Take => |n| {
                    if (st.taken[idx] >= @as(usize, @intCast(@max(n, 0)))) {
                        sg.deinit();
                        return .done;
                    }
                    st.taken[idx] += 1;
                },
                .Drop => |n| {
                    if (st.dropped[idx] < @as(usize, @intCast(@max(n, 0)))) {
                        st.dropped[idx] += 1;
                        sg.deinit();
                        continue :outer;
                    }
                },
                .TakeWhile => |f| {
                    if (!st.take_while_live[idx]) {
                        sg.deinit();
                        return .done;
                    }
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| if (!(rv == .Bool and rv.Bool)) {
                            st.take_while_live[idx] = false;
                            sg.deinit();
                            return .done;
                        },
                        .err => |e| {
                            sg.deinit();
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
                                    sg.deinit();
                                    continue :outer;
                                }
                                st.drop_while_live[idx] = false;
                            },
                            .err => |e| {
                                sg.deinit();
                                return .{ .err = try mapRuntimeError(allocator, e) };
                            },
                        }
                    }
                },
                // Buffering ops (sort/flatMap/distinct/...) cannot stream one at
                // a time; iterating such a sequence materialises it eagerly.
                else => {
                    sg.deinit();
                    const mr = try materialiseSequence(self, allocator, &st.seq);
                    switch (mr) {
                        .ok => |list| {
                            // Replace the source with the buffered items and clear
                            // ops so subsequent pulls stream from the buffer.
                            var owned = list;
                            const slice = try owned.toOwnedSlice(allocator);
                            const items_ref = try runtime.ValueSlice.init(allocator, slice);
                            const data = try ObjRef(runtime.SequenceData).init(allocator, .{
                                .source = .{ .Items = items_ref },
                                .ops = &.{},
                            });
                            if (runtime.reclaimEnabled()) st.seq.release(allocator);
                            st.seq = .{ .Sequence = data };
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
        sg.deinit();
        return .{ .value = current };
    }
}

/// Ensure `st.buffered` holds the next element (or marks done). Returns whether
/// an element is available, or an error.
fn seqIterEnsure(self: *VmHost, allocator: Allocator, st: *SeqIterState, out: runtime.Output) Allocator.Error!union(enum) { has: bool, err: EvalError } {
    if (st.buffered != null) return .{ .has = true };
    if (st.done) return .{ .has = false };
    switch (try seqIterPull(self, allocator, st, out)) {
        .value => |v| {
            st.buffered = v;
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
    const ref = receiver.SeqIter;
    if (std.mem.eql(u8, name, "hasNext") and args.len == 0) {
        const g = ref.borrowMut();
        defer g.deinit();
        return switch (try seqIterEnsure(self, allocator, g.get(), self.out)) {
            .has => |b| .{ .ok = boolVal(b) },
            .err => |e| .{ .err = e },
        };
    }
    if (isIteratorNext(name) and args.len == 0) {
        const g = ref.borrowMut();
        defer g.deinit();
        const st = g.get();
        switch (try seqIterEnsure(self, allocator, st, self.out)) {
            .has => |b| if (!b) return .{ .err = try throwExc(allocator, "kotlin.NoSuchElementException", "iterator exhausted") },
            .err => |e| return .{ .err = e },
        }
        const v = st.buffered.?;
        st.buffered = null;
        return .{ .ok = v };
    }
    return null;
}

/// Whether the class `name` (or any supertype, breadth-first) declares an
/// IR method named `mname`.
/// Whether the instance's own runtime ClassDef (or a supertype ClassDef
/// reachable through resolved interface handles) declares a member method
/// named `mname`. Authoritative where a name-keyed registry collides.
/// True when the module's member index records a user-declared member `mname`
/// on the class named by `owner_fqn`. `@JvmInline value class` (and other)
/// members live in the member index, not the runtime ClassDef.methods list
/// (a value class carries an empty methods list), so a value class's own
/// `toString`/`equals` override is invisible to the ClassDef walk and the
/// auto-generated structural form would wrongly preempt it.
fn moduleMemberDeclares(self: *VmHost, owner_fqn: []const u8, mname: []const u8) bool {
    if (owner_fqn.len == 0) return false;
    const mg = self.module.borrow();
    defer mg.deinit();
    return mg.get().memberDecls(owner_fqn, mname).len != 0;
}

fn instanceClassDeclaresMethod(inst: ObjRef(InstanceData), mname: []const u8) bool {
    const g = inst.borrow();
    const cd = g.get().class.clone();
    g.deinit();
    defer cd.deinit();
    const dg = cd.borrow();
    defer dg.deinit();
    return classDefDeclaresMethod(dg.get(), mname, 0);
}

fn classDefDeclaresMethod(d: *const ClassDef, mname: []const u8, depth: u32) bool {
    if (depth > 24) return false;
    for (d.methods) |m| {
        if (std.mem.eql(u8, m.name, mname)) return true;
    }
    for (d.interfaces) |iface| {
        const fg = iface.borrow();
        defer fg.deinit();
        if (classDefDeclaresMethod(fg.get(), mname, depth + 1)) return true;
    }
    return false;
}

/// Memo for `classHasUserMethod` past the precomputed `hierarchy_methods`
/// sets: one hierarchy walk per (class, method) per dispatch generation.
/// Every builtin member call on a data/value/object instance asks this
/// question, and a class without a precomputed set (a pack class, a
/// runtime-registered local class) otherwise paid the walk on each call:
/// with a linear scan of every module class per hierarchy hop, 11% of the
/// `LocalDateTest.fromEpochDays` wall went to `memset`/`eqlBytes` alone.
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
var user_method_memo: ?std.StringHashMap(UserMethodMemoEntry) = null;

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
    if (user_method_memo == null) user_method_memo = std.StringHashMap(UserMethodMemoEntry).init(std.heap.page_allocator);
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
    // A newer generation invalidates the answer; the walk runs again.
    try std.testing.expectEqual(@as(?bool, null), userMethodMemoGet("pkg.C\x1fequals", 8));
    userMethodMemoPut("pkg.C\x1fequals", 8, false);
    try std.testing.expectEqual(@as(?bool, false), userMethodMemoGet("pkg.C\x1fequals", 8));
    try std.testing.expectEqual(@as(?bool, null), userMethodMemoGet("pkg.C\x1fhashCode", 8));
}

fn classHasUserMethod(self: *VmHost, allocator: Allocator, start_in: []const u8, mname: []const u8) bool {
    const start = if (std.mem.lastIndexOfScalar(u8, start_in, '.')) |d| start_in[d + 1 ..] else start_in;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.hierarchy_methods.get(start_in)) |set| {
            return set.contains(mname);
        }
        if (mg.get().registry.hierarchy_methods.get(start)) |set| {
            return set.contains(mname);
        }
    }
    const gen = host_call_member.dispatch_cache_gen.load(.monotonic);
    var key_buf: [512]u8 = undefined;
    const key: ?[]const u8 = std.fmt.bufPrint(&key_buf, "{s}\x1f{s}", .{ start_in, mname }) catch null;
    if (key) |k| {
        if (userMethodMemoGet(k, gen)) |has| return has;
    }
    const has = classHasUserMethodWalk(self, allocator, start, mname);
    if (key) |k| userMethodMemoPut(k, gen, has);
    return has;
}

/// The uncached answer: breadth-first over the runtime class defs'
/// supertype names, each class looked up through the module's class index
/// (never a scan of every class).
fn classHasUserMethodWalk(self: *VmHost, allocator: Allocator, start: []const u8, mname: []const u8) bool {
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    queue.append(allocator, start) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur_raw = queue.items[head];
        const cur = if (std.mem.lastIndexOfScalar(u8, cur_raw, '.')) |d| cur_raw[d + 1 ..] else cur_raw;
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch {};
        {
            const mg = self.module.borrow();
            defer mg.deinit();
            const mod = mg.get();
            if (mod.registry.hierarchy_methods.get(cur)) |set| {
                if (set.contains(mname)) return true;
            } else if (mod.classId(cur)) |cid| {
                if (cid.int() < mod.classes.items.len) {
                    for (mod.classes.items[cid.int()].methods) |fid| {
                        if (funcAt(mod, fid)) |f| {
                            if (std.mem.eql(u8, f.name, mname)) return true;
                        }
                    }
                }
            }
        }
        const cg = self.classes.borrow();
        if (cg.get().get(cur)) |def| {
            const dg = def.borrow();
            for (dg.get().supertype_names) |sup| queue.append(allocator, sup) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

pub fn dataValueInstanceEquals(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), other: *const Value) Allocator.Error!bool {
    if (other.* != .Instance) return false;
    const rhs = other.Instance;
    const lg = inst.borrow();
    const lcg = lg.get().class.borrow();
    const rg = rhs.borrow();
    const rcg = rg.get().class.borrow();
    defer {
        rcg.deinit();
        rg.deinit();
        lcg.deinit();
        lg.deinit();
    }
    if (!std.mem.eql(u8, lcg.get().fqn, rcg.get().fqn)) return false;
    for (lcg.get().primary_params) |p| {
        const left = lg.get().get(p.name) orelse Value.Null;
        const right = rg.get().get(p.name) orelse Value.Null;
        if (!try deepValueEquals(self, allocator, &left, &right)) return false;
    }
    return true;
}

pub fn dataClassAutoMembers(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var is_data = false;
    var is_value = false;
    var is_object = false;
    var is_annotation = false;
    var class_name: []const u8 = undefined;
    var class_fqn: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        is_data = cg.get().is_data;
        is_value = cg.get().is_value;
        is_object = cg.get().is_object;
        is_annotation = cg.get().is_annotation;
        class_name = cg.get().name;
        class_fqn = cg.get().fqn;
        cg.deinit();
        g.deinit();
    }
    // Auto members are only synthesized for data/value/object/annotation
    // classes; a plain class has none, so skip the per-call hierarchy walk
    // (which allocates a queue + seen-set) that only feeds the
    // `has_user_override` guards below.
    if (!is_data and !is_value and !is_object and !is_annotation) return null;
    // The registry answer can be wrong when a simple class name collides
    // across packs (geometry Size vs the annotation Size); the instance's
    // OWN ClassDef is authoritative for whether it declares an override.
    const has_user_override = classHasUserMethod(self, allocator, if (class_fqn.len != 0) class_fqn else class_name, name) or
        instanceClassDeclaresMethod(inst, name) or
        moduleMemberDeclares(self, class_fqn, name);

    if (is_data and is_object and !has_user_override and std.mem.eql(u8, name, "toString")) {
        return .{ .ok = try strVal(allocator, classDisplayName(class_name)) };
    }
    if (is_annotation and !has_user_override) {
        if (args.len == 0 and std.mem.eql(u8, name, "toString")) {
            return .{ .ok = try renderAnnotation(self, allocator, inst) };
        }
        if (args.len == 0 and std.mem.eql(u8, name, "hashCode")) {
            return .{ .ok = Value.newInt(@as(i64, try annotationHash(self, allocator, inst))) };
        }
        if (args.len == 1 and std.mem.eql(u8, name, "equals")) {
            return .{ .ok = boolVal(try annotationInstanceEquals(self, allocator, inst, &args[0])) };
        }
        return null;
    }
    if ((is_data or is_value) and !has_user_override and args.len == 0) {
        if (is_data and std.mem.startsWith(u8, name, "component")) {
            const rest = name["component".len..];
            if (std.fmt.parseInt(usize, rest, 10) catch null) |n| {
                if (n >= 1) {
                    const g = inst.borrow();
                    const cg = g.get().class.borrow();
                    if (n - 1 < cg.get().primary_params.len) {
                        const pname = cg.get().primary_params[n - 1].name;
                        if (g.get().get(pname)) |v| {
                            cg.deinit();
                            g.deinit();
                            // Borrowed instance field; the register owns the
                            // result, so retain before returning (host-returns-owned).
                            if (runtime.reclaimEnabled()) v.retain();
                            return .{ .ok = v };
                        }
                    }
                    cg.deinit();
                    g.deinit();
                }
            }
        }
        if (std.mem.eql(u8, name, "toString")) {
            return .{ .ok = try renderStructural(self, allocator, inst) };
        }
        if (std.mem.eql(u8, name, "hashCode")) {
            // Kotlin folds each property's OWN `hashCode()`, so a property
            // whose class overrides it decides the result — androidx's
            // `value class TestValueClassList(val list: LongList)` hashes as
            // `LongList.hashCode()`, which walks `_size` elements. A pure
            // structural hash instead read the fixed-capacity backing array,
            // so `removeAt`/`clear` left the hash unchanged.
            //
            // The fold dispatches back into the interpreter, so the field
            // values are collected (and kept alive) first: the instance and
            // its class must not stay borrowed across a member call.
            var fields: std.ArrayList(Value) = .empty;
            defer {
                if (runtime.reclaimEnabled()) {
                    for (fields.items) |v| v.release(allocator);
                }
                fields.deinit(allocator);
            }
            {
                const g = inst.borrow();
                const cg = g.get().class.borrow();
                defer {
                    cg.deinit();
                    g.deinit();
                }
                try fields.ensureTotalCapacity(allocator, cg.get().primary_params.len);
                for (cg.get().primary_params) |p| {
                    const v = g.get().get(p.name) orelse Value.Null;
                    if (runtime.reclaimEnabled()) v.retain();
                    fields.appendAssumeCapacity(v);
                }
            }
            var h: i32 = 0;
            for (fields.items) |*v| h = h *% 31 +% try hashWithDispatch(self, allocator, v);
            return .{ .ok = Value.newInt(@as(i64, h)) };
        }
    }
    if (is_data and !has_user_override and std.mem.eql(u8, name, "copy")) {
        var n_params: usize = undefined;
        {
            const g = inst.borrow();
            const cg = g.get().class.borrow();
            n_params = cg.get().primary_params.len;
            cg.deinit();
            g.deinit();
        }
        if (args.len <= n_params) {
            var new_args: std.ArrayList(Value) = .empty;
            defer new_args.deinit(allocator);
            const g = inst.borrow();
            const cg = g.get().class.borrow();
            for (cg.get().primary_params, 0..) |p, idx| {
                if (idx < args.len) {
                    try new_args.append(allocator, args[idx]);
                } else {
                    try new_args.append(allocator, g.get().get(p.name) orelse Value.Null);
                }
            }
            cg.deinit();
            g.deinit();
            return try reconstructDataClass(self, allocator, inst, new_args.items);
        }
    }
    if ((is_data or is_value) and !has_user_override and args.len == 1 and std.mem.eql(u8, name, "equals")) {
        return .{ .ok = boolVal(try dataValueInstanceEquals(self, allocator, inst, &args[0])) };
    }
    return null;
}

/// The parameter names and values of an annotation instance, collected
/// under one borrow so the comparisons and hashes that dispatch back into
/// the interpreter never run with the instance or its class borrowed. The
/// values are retained; the caller releases them.
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

/// Annotation instances follow Kotlin's rules for an instantiated
/// annotation: `equals` holds when every parameter is equal, arrays by
/// content and floating-point values by bit pattern (NaN equals NaN, 0.0
/// differs from -0.0); `hashCode` is the sum over parameters of
/// `(127 * name.hashCode()) xor value.hashCode()` with arrays hashed by
/// content; `toString` renders `@fqn(name=value, ...)`.
pub fn annotationInstanceEquals(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), other: *const Value) Allocator.Error!bool {
    if (other.* != .Instance) return false;
    const rhs = other.Instance;
    var lhs_fields = try AnnotationFields.collect(allocator, inst);
    defer lhs_fields.release(allocator);
    var rhs_fields = try AnnotationFields.collect(allocator, rhs);
    defer rhs_fields.release(allocator);
    if (!std.mem.eql(u8, lhs_fields.fqn, rhs_fields.fqn)) return false;
    if (lhs_fields.values.items.len != rhs_fields.values.items.len) return false;
    for (lhs_fields.values.items, rhs_fields.values.items) |*l, *r| {
        if (!try annotationValueEquals(self, allocator, l, r)) return false;
    }
    return true;
}

fn annotationValueEquals(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) Allocator.Error!bool {
    switch (a.*) {
        .Float => |x| {
            if (b.* == .Float) return @as(u32, @bitCast(x)) == @as(u32, @bitCast(b.Float));
        },
        .Double => |x| {
            if (b.* == .Double) return @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.Double));
        },
        .Array => |xa| {
            if (b.* == .Array) {
                const ya = b.Array;
                const n = xa.len();
                if (n != ya.len()) return false;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    var ex = xa.get(i);
                    var ey = ya.get(i);
                    if (!try annotationValueEquals(self, allocator, &ex, &ey)) return false;
                }
                return true;
            }
        },
        else => {},
    }
    return deepValueEquals(self, allocator, a, b);
}

fn annotationHash(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData)) Allocator.Error!i32 {
    var fields = try AnnotationFields.collect(allocator, inst);
    defer fields.release(allocator);
    var h: i32 = 0;
    for (fields.names.items, fields.values.items) |n, *v| {
        h +%= (javaStringHash(n) *% 127) ^ (try hashWithDispatch(self, allocator, v));
    }
    return h;
}

/// Callable references compare by target, captures and adaptation: two
/// loads of `::f` are the same function, and two forwarding wrappers of
/// the same adaptation of the same target carry the same reference key.
pub fn closureRefEquals(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) Allocator.Error!bool {
    const ca = a.IrClosure;
    const cb = b.IrClosure;
    if (ca.id != cb.id) {
        // Distinct closure records: the same body function is the same
        // reference (two loads of `::f`); otherwise only two wrappers with
        // the same reference key are.
        const ia = self.closures.get(@intCast(ca.id)) orelse return Value.structuralEq(a, b);
        const ib = self.closures.get(@intCast(cb.id)) orelse return Value.structuralEq(a, b);
        if (ia.body_func != ib.body_func) {
            const key_eq = blk: {
                const mg = self.module.borrow();
                defer mg.deinit();
                const ma = ia.module orelse mg.get();
                const mb = ib.module orelse mg.get();
                const fa = ma.funcById(ia.body_func) orelse break :blk false;
                const fb = mb.funcById(ib.body_func) orelse break :blk false;
                break :blk fa.ref_key.len != 0 and std.mem.eql(u8, fa.ref_key, fb.ref_key);
            };
            if (!key_eq) return false;
        }
    }
    const ga = ca.captures.borrow();
    defer ga.deinit();
    const gb = cb.captures.borrow();
    defer gb.deinit();
    const xa = ga.get().*;
    const xb = gb.get().*;
    if (xa.len != xb.len) return false;
    for (xa, xb) |*x, *y| {
        if (!try deepValueEquals(self, allocator, x, y)) return false;
    }
    return true;
}

/// The hash of a callable reference, consistent with `closureRefEquals`.
pub fn closureRefHash(self: *VmHost, allocator: Allocator, v: *const Value) Allocator.Error!i32 {
    const c = v.IrClosure;
    var h: i32 = blk: {
        const info = self.closures.get(@intCast(c.id)) orelse break :blk kotlinHashCode(v);
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = info.module orelse mg.get();
        if (mod.funcById(info.body_func)) |f| {
            if (f.ref_key.len != 0) break :blk javaStringHash(f.ref_key);
        }
        break :blk @as(i32, @truncate(@as(i64, @intCast(info.body_func.int()))));
    };
    const g = c.captures.borrow();
    defer g.deinit();
    for (g.get().*) |*x| h = h *% 31 +% try hashWithDispatch(self, allocator, x);
    return h;
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

fn renderAnnotation(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData)) Allocator.Error!Value {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try renderAnnotationInto(self, allocator, inst, &buf);
    return .{ .String = try runtime.strInitOwned(allocator, try buf.toOwnedSlice(allocator)) };
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
            switch (try callMember(self, allocator, v, "toString", &.{})) {
                .ok => |sv| try buf.appendSlice(allocator, try sv.display(allocator)),
                .err => try buf.appendSlice(allocator, try v.display(allocator)),
            }
        },
        else => try buf.appendSlice(allocator, try v.display(allocator)),
    }
}

/// `Name(p1=v1, …)` structural rendering of a data class.
fn renderStructural(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData)) Allocator.Error!Value {
    const g = inst.borrow();
    const cg = g.get().class.borrow();
    defer {
        cg.deinit();
        g.deinit();
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, classDisplayName(cg.get().name));
    try buf.append(allocator, '(');
    for (cg.get().primary_params, 0..) |p, idx| {
        if (idx > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, p.name);
        try buf.append(allocator, '=');
        const v = g.get().get(p.name) orelse Value.Null;
        const s = try v.display(allocator);
        try buf.appendSlice(allocator, s);
    }
    try buf.append(allocator, ')');
    _ = self;
    return .{ .String = try runtime.strInitOwned(allocator, try buf.toOwnedSlice(allocator)) };
}
