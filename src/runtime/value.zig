//! The runtime `Value` model: the tagged union every interpreter and
//! stdlib path evaluates against, its helper enums/structs, and the
//! `RuntimeError` data type.
//!
//! Reference handles: `ObjRef(T)` is the refcounted, interior-mutable,
//! lock-mediated cell; `*Value` is an owning pointer to a single boxed
//! value. Shared-immutable AST nodes map to `*const ast.X` pointers,
//! owned by the parse/lower arena.

const std = @import("std");
const ast = @import("ast");
const objcell = @import("objcell.zig");
const trace_mod = @import("trace.zig");
const float_fmt = @import("float_fmt.zig");
const class_mod = @import("class.zig");
const env_mod = @import("env.zig");

const ObjRef = objcell.ObjRef;
const ClassDef = class_mod.ClassDef;
const InstanceData = class_mod.InstanceData;
const MethodDef = class_mod.MethodDef;
const Env = env_mod.Env;

const StdlibFn = @import("host.zig").StdlibFn;

/// Scratch arena for the supertype walks below. The walk is bounded (64 steps
/// over two `[]const u8` lists), so a fixed buffer covers it; keeping the
/// buffer in thread-local storage instead of on the stack means the safety
/// fill of an `undefined` stack array does not run on every call, which is
/// what made object equality pay a 16 KiB `memset` per comparison.
threadlocal var subtype_scratch: [16 * 1024]u8 align(16) = undefined;
threadlocal var subtype_scratch_busy: bool = false;

/// Direct-mapped per-class memo for `instanceImplementsMapEntry`. A class's
/// `Map.Entry`-ness is fixed by its supertype graph, so one walk per class is
/// enough no matter how many comparisons ask.
const MapEntryMemoSlot = struct { key: usize = 0, val: bool = false };
threadlocal var map_entry_memo: [512]MapEntryMemoSlot = @splat(.{});

/// A borrowed allocator for one supertype walk. A nested walk (the buffer is
/// already lent out) falls back to the page allocator rather than aliasing the
/// lender's frontier.
const SubtypeScratch = struct {
    fba: std.heap.FixedBufferAllocator = undefined,
    owned: bool = false,

    fn acquire(self: *SubtypeScratch) std.mem.Allocator {
        if (subtype_scratch_busy) {
            self.owned = false;
            return std.heap.page_allocator;
        }
        subtype_scratch_busy = true;
        self.owned = true;
        self.fba = std.heap.FixedBufferAllocator.init(&subtype_scratch);
        return self.fba.allocator();
    }

    fn reset(self: *SubtypeScratch) void {
        if (self.owned) self.fba.reset();
    }

    fn release(self: *SubtypeScratch) void {
        if (self.owned) subtype_scratch_busy = false;
    }
};

/// Backing of a `String`: the owned UTF-8 `bytes` plus metadata computed once at
/// creation — `u16_len` (Kotlin `String.length`, in UTF-16 code units) and
/// `ascii` (no byte ≥ 0x80). Because a Kotlin string is immutable, these never
/// change, so caching them turns `length`/indexing/`substring` from per-call
/// O(n) UTF-16 walks into O(1) reads (and ASCII indexing into a direct byte
/// load), at the cost of one scan when the string is built.
pub const StringData = struct {
    bytes: []const u8,
    u16_len: u32,
    ascii: bool,

    /// A Kotlin `String` is immutable: `bytes`/`u16_len`/`ascii` are set once at
    /// construction and only ever read until teardown frees the bytes. Nothing
    /// takes an exclusive borrow of a string cell, so its `ObjRef` reader lock
    /// guards against a writer that never exists — this marker elides it (see
    /// `objcell.LockFor`), removing the per-borrow atomic on every string read.
    pub const objref_immutable = true;

    /// The cell owns its bytes (see `ObjRef.init`/`initOwned` for `[]const u8`),
    /// so teardown frees them — same contract the bare `[]const u8` payload had.
    pub fn gcFinalize(self: *StringData, a: std.mem.Allocator) void {
        a.free(self.bytes);
    }
    pub fn deinit(self: *StringData, a: std.mem.Allocator) void {
        a.free(self.bytes);
    }
    pub fn gcExternalBytes(self: *const StringData) usize {
        return self.bytes.len;
    }
};

/// `Arc<String>` — a shared, refcounted, immutable string (UTF-8 + cached meta).
pub const StringRef = ObjRef(StringData);

/// UTF-16 length + ASCII flag for `bytes` (computed once per string).
pub fn strMeta(bytes: []const u8) struct { u16_len: u32, ascii: bool } {
    for (bytes) |b| {
        if (b >= 0x80) break;
    } else return .{ .u16_len = @intCast(bytes.len), .ascii = true };
    var n: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        const end = @min(i + len, bytes.len);
        const cp = std.unicode.utf8Decode(bytes[i..end]) catch bytes[i];
        n += if (cp > 0xFFFF) 2 else 1;
        i = end;
    }
    return .{ .u16_len = n, .ascii = false };
}

/// `StringRef` constructor mirroring `ObjRef([]const u8).init`: under the GC /
/// reclaim backends the cell owns a private copy of `bytes` (duped); under the
/// pure-arena fast path the slice is adopted as-is (the arena reclaims it).
pub fn strInit(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!StringRef {
    const owned = if (objcell.reclaimEnabled() or objcell.gc.gc_enabled) try allocator.dupe(u8, bytes) else bytes;
    const m = strMeta(owned);
    return StringRef.initOwned(allocator, .{ .bytes = owned, .u16_len = m.u16_len, .ascii = m.ascii });
}

/// `StringRef` constructor mirroring `ObjRef([]const u8).initOwned`: adopt `bytes`
/// verbatim (caller transfers ownership; freed on teardown under reclaim/GC).
pub fn strInitOwned(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!StringRef {
    const m = strMeta(bytes);
    return StringRef.initOwned(allocator, .{ .bytes = bytes, .u16_len = m.u16_len, .ascii = m.ascii });
}
/// One captured call-stack entry: the function's display label plus the
/// source position the frame was executing. `file_id`/`offset` are the raw
/// `Span` components (kept as plain integers so this module need not depend on
/// `span`); they resolve to a path + line through the `SourceMap` at render
/// time, which works uniformly for user, pack, and stdlib frames. `has_pos` is
/// false when the frame had no recorded position yet (e.g. before its first
/// statement ran). `fqn` borrows program-lifetime module memory — never freed.
pub const StackFrame = struct {
    fqn: []const u8,
    file_id: u32,
    offset: u32,
    has_pos: bool,
};

/// A captured throwable stack trace: the frames innermost-first. Owns only the
/// `frames` slice; each frame's `fqn` borrows the module.
pub const StackTraceData = struct {
    frames: []StackFrame,

    /// A captured stack trace is set once at throw time and only read
    /// thereafter, so its cell is never write-locked; elide the reader lock.
    pub const objref_immutable = true;

    pub fn gcFinalize(self: *StackTraceData, a: std.mem.Allocator) void {
        a.free(self.frames);
    }
    pub fn deinit(self: *StackTraceData, a: std.mem.Allocator) void {
        a.free(self.frames);
    }
};

/// Shared, refcounted captured stack trace attached to a thrown value.
pub const StackRef = ObjRef(StackTraceData);

/// `ObjRef<Vec<Value>>` — shared, growable element storage.
pub const ValueList = ObjRef(std.ArrayList(Value));
/// `Arc<Vec<Value>>` — shared, frozen element storage.
pub const ValueSlice = ObjRef([]Value);
/// One key/value pair inside a `Map`.
pub const MapPair = struct {
    key: Value,
    value: Value,
    /// GC tracer: a map entry owns one ref to its key and value.
    pub fn gcTrace(self: *const MapPair, m: *objcell.gc.Marker) void {
        self.key.gcMark(m);
        self.value.gcMark(m);
    }
};
/// Backing store for a `Map`/`MutableMap`: the insertion-ordered entry list
/// (Kotlin `LinkedHashMap` semantics) plus an optional hash index over the keys.
///
/// The list alone gives O(n) `get`/`put`/`containsKey` — quadratic for any
/// map-heavy loop. The index is a chained hash over entry positions: `head`
/// maps a key hash to the first entry index (+1; 0 = empty) and `chain[i]` links
/// to the next entry sharing `pairs[i]`'s hash bucket (+1; 0 = end). It holds no
/// `Value`s (the pairs own the keys/values), so it needs no refcount or GC
/// tracing — only freeing. Small maps skip the index entirely (linear scan is
/// cheaper than a hash table below `index_threshold`). A non-hashable key
/// (Instance / collection / etc.) disables the index and falls back to linear
/// scan, preserving exact `equals` semantics.
pub const MapStore = struct {
    pairs: std.ArrayList(MapPair) = .empty,
    head: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    chain: std.ArrayListUnmanaged(u32) = .empty,
    /// Entry count the index currently reflects. A mismatch with `pairs.len`
    /// means entries were appended without incremental maintenance (a non-hot
    /// path), so `find` rebuilds — keeping the index correct everywhere while the
    /// hot put path stays O(1) via `noteAppended`.
    indexed_len: usize = 0,
    built: bool = false,
    indexable: bool = true,
    /// Structural-modification counter for fail-fast iteration over a mutable
    /// map's `keys`/`values`/`entries` views. Shared (ObjRef handle) with every
    /// such view; the map's structural mutations bump it on a size change and a
    /// view iterator captures it. Null for a read-only map.
    mod_count: objcell.OptRef(u64) = .{},

    /// Below this entry count, a linear scan beats a hash table (and avoids the
    /// table's allocation), so the index is not built.
    pub const index_threshold: usize = 16;

    pub fn deinit(self: *MapStore, a: std.mem.Allocator) void {
        self.pairs.deinit(a);
        self.head.deinit(a);
        self.chain.deinit(a);
        if (self.mod_count.get()) |mc| mc.deinit();
    }

    /// GC teardown (no allocator-bound buffers escape the cell): free the same
    /// backing the refcount `deinit` frees.
    pub fn gcFinalize(self: *MapStore, a: std.mem.Allocator) void {
        self.deinit(a);
    }

    /// Out-edges: only the entry list owns `Value`s; the index is index-only.
    pub fn gcTrace(self: *const MapStore, m: *objcell.gc.Marker) void {
        for (self.pairs.items) |*kv| kv.gcTrace(m);
        if (self.mod_count.get()) |mc| m.shade(&mc.cell.hdr);
    }

    /// Hash for a key, consistent with `Value.structuralEqBoxed` (equal keys
    /// hash equal; types are kept distinct so `5` (Int) and `5L` (Long) differ).
    /// `null` for a key that is not simple-hashable (caller disables the index).
    fn keyHash(k: *const Value) ?u64 {
        var h = std.hash.Wyhash.init(0);
        switch (k.*) {
            .Int => |x| {
                h.update("i");
                h.update(std.mem.asBytes(&x));
            },
            .Long => |x| {
                h.update("l");
                h.update(std.mem.asBytes(&x));
            },
            .Short => |x| {
                h.update("s");
                h.update(std.mem.asBytes(&x));
            },
            .Byte => |x| {
                h.update("b");
                h.update(std.mem.asBytes(&x));
            },
            .UInt => |x| {
                h.update("ui");
                h.update(std.mem.asBytes(&x));
            },
            .ULong => |x| {
                h.update("ul");
                h.update(std.mem.asBytes(&x));
            },
            .UShort => |x| {
                h.update("us");
                h.update(std.mem.asBytes(&x));
            },
            .UByte => |x| {
                h.update("ub");
                h.update(std.mem.asBytes(&x));
            },
            .Bool => |x| {
                h.update("o");
                h.update(std.mem.asBytes(&x));
            },
            .Char => |x| {
                h.update("c");
                h.update(std.mem.asBytes(&x));
            },
            .Double => |x| {
                h.update("d");
                const bits: u64 = @bitCast(x);
                h.update(std.mem.asBytes(&bits));
            },
            .Float => |x| {
                h.update("f");
                const bits: u32 = @bitCast(x);
                h.update(std.mem.asBytes(&bits));
            },
            .String => |sref| {
                h.update("S");
                const sg = sref.borrow();
                defer sg.deinit();
                h.update(sg.get().bytes);
            },
            .Null => h.update("z"),
            else => return null,
        }
        return h.final();
    }

    fn linearFind(self: *const MapStore, key: *const Value) ?usize {
        for (self.pairs.items, 0..) |*kv, i| {
            if (Value.structuralEqBoxed(&kv.key, key)) return i;
        }
        return null;
    }

    /// (Re)build the hash index from the entry list. Disables indexing if any
    /// key is not simple-hashable.
    fn build(self: *MapStore, a: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.head.clearRetainingCapacity();
        self.chain.clearRetainingCapacity();
        try self.chain.ensureTotalCapacity(a, self.pairs.items.len);
        self.chain.items.len = self.pairs.items.len;
        for (self.pairs.items, 0..) |*kv, i| {
            const hsh = keyHash(&kv.key) orelse {
                self.indexable = false;
                self.head.clearRetainingCapacity();
                self.chain.clearRetainingCapacity();
                return;
            };
            const gop = try self.head.getOrPut(a, hsh);
            if (gop.found_existing) {
                self.chain.items[i] = gop.value_ptr.*;
            } else {
                self.chain.items[i] = 0;
            }
            gop.value_ptr.* = @intCast(i + 1);
        }
        self.built = true;
        self.indexed_len = self.pairs.items.len;
    }

    /// Find the entry index for `key`, or null. O(1) amortized for large maps
    /// with hashable keys; linear for small maps or non-hashable keys.
    pub fn find(self: *MapStore, a: std.mem.Allocator, key: *const Value) std.mem.Allocator.Error!?usize {
        if (!self.indexable or self.pairs.items.len < index_threshold) return self.linearFind(key);
        if (!self.built or self.indexed_len != self.pairs.items.len) {
            try self.build(a);
            if (!self.indexable) return self.linearFind(key);
        }
        const hsh = keyHash(key) orelse return self.linearFind(key);
        var slot = self.head.get(hsh) orelse return null;
        while (slot != 0) {
            const i = slot - 1;
            if (Value.structuralEqBoxed(&self.pairs.items[i].key, key)) return i;
            slot = self.chain.items[i];
        }
        return null;
    }

    /// Record that `pairs[i]` was just appended (a new key). Maintains the index
    /// incrementally when it is live so a put-heavy loop stays O(1); otherwise a
    /// no-op (the index builds lazily on the next `find`).
    pub fn noteAppended(self: *MapStore, a: std.mem.Allocator, i: usize) std.mem.Allocator.Error!void {
        if (!self.built or !self.indexable) return;
        // Only maintain incrementally when `i` is exactly the next uncovered
        // entry; a gap means other entries were appended without maintenance, so
        // drop to a lazy rebuild rather than silently miss them.
        if (self.indexed_len != i) {
            self.invalidate();
            return;
        }
        const hsh = keyHash(&self.pairs.items[i].key) orelse {
            self.indexable = false;
            self.head.clearRetainingCapacity();
            self.chain.clearRetainingCapacity();
            return;
        };
        if (self.chain.items.len <= i) {
            try self.chain.resize(a, i + 1);
        }
        const gop = try self.head.getOrPut(a, hsh);
        self.chain.items[i] = if (gop.found_existing) gop.value_ptr.* else 0;
        gop.value_ptr.* = @intCast(i + 1);
        self.indexed_len = self.pairs.items.len;
    }

    /// Invalidate the index after a structural change that shifts entry indices
    /// (removal / clear); it rebuilds lazily on the next `find`.
    pub fn invalidate(self: *MapStore) void {
        self.built = false;
        self.indexed_len = 0;
        self.head.clearRetainingCapacity();
        self.chain.clearRetainingCapacity();
    }
};

/// The whole state of a `Value.RangeIter`: the advancing cursor and
/// yielded-last flag PLUS the fixed end/step/kind. The fixed fields ride
/// in the same shared cell because every `hasNext`/`next` already takes
/// one snapshot borrow of it — folding them here costs nothing per step
/// and shrinks the `Value` payload to the one handle.
pub const RangeIterState = struct {
    cur: i64,
    end: i64,
    step: i64,
    kind: RangeKind,
    done: bool = false,
};

/// `ObjRef<MapStore>` — shared, growable map entry storage with a hash index.
pub const MapEntries = ObjRef(MapStore);

/// The boxed payload of `Value.Map` (see the union field). One control block
/// per map VALUE; copies of the `Value` share it by pointer, and the box's
/// refcount teardown releases what the map owns.
pub const MapData = struct {
    entries: MapEntries,
    mutable: bool,
    /// Declared key/value type heads from explicit call-site type
    /// arguments on the creating stdlib function; see `List`.
    declared_key: ?[]const u8 = null,
    declared_value: ?[]const u8 = null,

    /// Refcount teardown (the box's last handle): release each entry's key
    /// and value when this box was the entries' last owner, then the
    /// entries handle itself. Mirrors what `Value.release` did in-line
    /// before the payload was boxed.
    pub fn deinit(self: *MapData, allocator: std.mem.Allocator) void {
        if (self.entries.strongCount() == 1) {
            const g = self.entries.borrow();
            for (g.get().pairs.items) |pair| {
                pair.key.release(allocator);
                pair.value.release(allocator);
            }
            g.deinit();
        }
        self.entries.deinit();
    }

    /// GC out-edge: the entries cell (its own trace reaches the pairs).
    pub fn gcTrace(self: *const MapData, m: *objcell.gc.Marker) void {
        m.shade(&self.entries.cell.hdr);
    }
};

/// The control-block handle behind a boxed `Value.Map` payload.
pub const MapRef = ObjRef(MapData);

/// Recover the owning control block from a boxed map payload pointer.
pub inline fn mapRefOf(m: *MapData) MapRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", m)) };
}

/// The boxed payload of `Value.Range` (see `MapData` for the scheme).
/// Immutable after construction.
pub const RangeData = struct {
    start: i64,
    end: i64,
    step: i64,
    kind: RangeKind,
    /// True when built as a progression (`step`, `downTo`, `reversed`)
    /// rather than a `..` / `until` range. A step-1 progression is NOT
    /// an `IntRange`: it renders as `1..10 step 1`, hashes with the
    /// progression formula, and fails `is IntRange`.
    progression: bool = false,
};

/// The control-block handle behind a boxed `Value.Range` payload.
pub const RangeRef = ObjRef(RangeData);

/// The boxed payload of `Value.BoundMethod` (see `MapData` for the scheme).
pub const BoundMethodData = struct {
    fqn: []const u8,
    func: StdlibFn,
    receiver: ValueBox,

    pub fn deinit(self: *BoundMethodData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.receiver.deinit();
    }

    pub fn gcTrace(self: *const BoundMethodData, m: *objcell.gc.Marker) void {
        m.shade(&self.receiver.cell.hdr);
    }
};

/// The boxed payload of `Value.MapEntry` (see `MapData` for the scheme).
pub const MapEntryData = struct {
    key: ValueBox,
    value: ValueBox,
    /// When set, the live map's entries: `setValue` writes through and
    /// reads resolve the live pair by key.
    backing: objcell.OptRef(MapStore) = .{},
    /// The backing counter observed when this entry was handed out
    /// (creation or iterator `next()`). A later structural change to
    /// the map makes every member access throw
    /// ConcurrentModificationException. Meaningful only with `backing`.
    exp_mod: u64 = 0,

    pub fn deinit(self: *MapEntryData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.key.deinit();
        self.value.deinit();
        // `backing` is a non-owning write-through reference; not released.
    }

    pub fn gcTrace(self: *const MapEntryData, m: *objcell.gc.Marker) void {
        // Shade the value-box CELLS (whose own tracers mark the inner
        // values) — dereferencing the interior here would leave the box
        // cells unmarked and swept while the entry lives.
        m.shade(&self.key.cell.hdr);
        m.shade(&self.value.cell.hdr);
        if (self.backing.get()) |b| m.shade(&b.cell.hdr);
    }
};

/// The boxed payload of `Value.Result` (see `MapData` for the scheme).
pub const ResultData = struct {
    ok: bool,
    payload: ValueBox,

    pub fn deinit(self: *ResultData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.payload.deinit();
    }

    pub fn gcTrace(self: *const ResultData, m: *objcell.gc.Marker) void {
        m.shade(&self.payload.cell.hdr);
    }
};

/// The control-block handle behind a boxed `Value.Result` payload.
pub const ResultRef = ObjRef(ResultData);

/// Recover the owning control block from a boxed payload pointer.
pub inline fn resultRefOf(r: *ResultData) ResultRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", r)) };
}

/// The boxed payload of `Value.Comparator` (see `MapData` for the scheme).
pub const ComparatorData = struct {
    steps: ObjRef([]ComparatorStep),
    descending: bool,

    pub fn deinit(self: *ComparatorData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.steps.deinit();
    }

    pub fn gcTrace(self: *const ComparatorData, m: *objcell.gc.Marker) void {
        m.shade(&self.steps.cell.hdr);
    }
};

/// The control-block handle behind a boxed `Value.Comparator` payload.
pub const ComparatorRef = ObjRef(ComparatorData);

/// Recover the owning control block from a boxed payload pointer.
pub inline fn comparatorRefOf(c: *ComparatorData) ComparatorRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", c)) };
}

/// The boxed payload of `Value.Pair` (see `MapData` for the scheme).
pub const PairData = struct {
    first: ValueBox,
    second: ValueBox,

    pub fn deinit(self: *PairData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.first.deinit();
        self.second.deinit();
    }

    pub fn gcTrace(self: *const PairData, m: *objcell.gc.Marker) void {
        m.shade(&self.first.cell.hdr);
        m.shade(&self.second.cell.hdr);
    }
};

/// The control-block handle behind a boxed `Value.Pair` payload.
pub const PairRef = ObjRef(PairData);

/// Recover the owning control block from a boxed payload pointer.
pub inline fn pairRefOf(p: *PairData) PairRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", p)) };
}

/// The boxed payload of `Value.Triple` (see `MapData` for the scheme).
pub const TripleData = struct {
    first: ValueBox,
    second: ValueBox,
    third: ValueBox,

    pub fn deinit(self: *TripleData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.first.deinit();
        self.second.deinit();
        self.third.deinit();
    }

    pub fn gcTrace(self: *const TripleData, m: *objcell.gc.Marker) void {
        m.shade(&self.first.cell.hdr);
        m.shade(&self.second.cell.hdr);
        m.shade(&self.third.cell.hdr);
    }
};

/// The interned payload of `Value.Intrinsic`: program-lifetime, never
/// freed, invisible to the refcount and the collector.
pub const IntrinsicData = struct {
    fqn: []const u8,
    func: StdlibFn,
};

var intrinsic_intern_mutex: objcell.SpinMutex = .{};
var intrinsic_intern: ?std.StringHashMap(*const IntrinsicData) = null;

/// The control-block handle behind a boxed `Value.MatchGroup` payload
/// (the payload struct is `MatchGroupData`, shared with `MatchData`'s
/// group descriptors).
pub const MatchGroupRef = ObjRef(MatchGroupData);

/// Recover the owning control block from a boxed payload pointer.
pub inline fn matchGroupRefOf(g: *MatchGroupData) MatchGroupRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", g)) };
}

/// The control-block handle behind a boxed `Value.Triple` payload.
pub const TripleRef = ObjRef(TripleData);

/// Recover the owning control block from a boxed payload pointer.
pub inline fn tripleRefOf(t: *TripleData) TripleRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", t)) };
}

/// The control-block handle behind a boxed `Value.MapEntry` payload.
pub const MapEntryRef = ObjRef(MapEntryData);

/// Recover the owning control block from a boxed payload pointer.
pub inline fn mapEntryRefOf(e: *MapEntryData) MapEntryRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", e)) };
}

/// The control-block handle behind a boxed `Value.BoundMethod` payload.
pub const BoundMethodRef = ObjRef(BoundMethodData);

/// Recover the owning control block from a boxed payload pointer.
pub inline fn boundMethodRefOf(b: *BoundMethodData) BoundMethodRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", b)) };
}

/// Recover the owning control block from a boxed range payload pointer.
pub inline fn rangeRefOf(r: *RangeData) RangeRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", r)) };
}

/// The boxed payload of `Value.Exception` (see `MapData` for the scheme).
/// Copies of the `Value` share one record, so `fillInStackTrace`,
/// `addSuppressed`, and cause writes are visible through every copy — the
/// JVM's reference semantics.
pub const ExceptionData = struct {
    fqn: StringRef,
    message: objcell.OptRef(StringData) = .{},
    /// Stored as a bare nullable cell pointer (`?*ValueBox.Cell`, 8 bytes —
    /// `?ObjRef` is not null-optimized) and reconstructed as `ValueBox` at
    /// each use. Mirrors `ListData.backing`.
    cause: ?*ValueBox.Cell,
    /// The call stack captured when this throwable was first thrown
    /// (`fillInStackTrace`). Null until thrown. Borrows program-lifetime
    /// frame labels; the frame slice is owned by the `StackRef` cell.
    /// Stored as `?*StackRef.Cell`; reconstructed as `StackRef` at use.
    stack: ?*StackRef.Cell = null,
    /// Reference identity for `===` / `assertSame`. Assigned fresh at the
    /// throwable construction site (`host.allocInstanceId()`); 0 for
    /// exceptions built outside that path, which then compare structurally.
    identity: u64 = 0,
    /// Suppressed throwables (`addSuppressed`/`suppressedExceptions`). A
    /// shared list allocated at the constructor site so every value-copy
    /// of the exception observes the same suppressed set; null for
    /// exceptions built outside that path. Stored as `?*ValueList.Cell`;
    /// reconstructed as `ValueList` at use.
    suppressed: ?*ValueList.Cell = null,

    pub fn deinit(self: *ExceptionData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.fqn.deinit();
        if (self.message.get()) |m| m.deinit();
        if (self.cause) |c| (ValueBox{ .cell = c }).deinit();
        if (self.stack) |st| (StackRef{ .cell = st }).deinit();
        if (self.suppressed) |sl| (ValueList{ .cell = sl }).deinit();
    }

    pub fn gcTrace(self: *const ExceptionData, m: *objcell.gc.Marker) void {
        m.shade(&self.fqn.cell.hdr);
        if (self.message.get()) |msg| m.shade(&msg.cell.hdr);
        if (self.cause) |c| m.shade(&c.hdr);
        if (self.stack) |st| m.shade(&st.hdr);
        if (self.suppressed) |sl| m.shade(&sl.hdr);
    }
};

/// The control-block handle behind a boxed `Value.Exception` payload.
pub const ExceptionRef = ObjRef(ExceptionData);

/// Recover the owning control block from a boxed exception payload pointer.
pub inline fn exceptionRefOf(e: *ExceptionData) ExceptionRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", e)) };
}

/// The boxed payload of `Value.List` (see `MapData` for the scheme).
pub const ListData = struct {
    items: ValueList,
    mutable: bool,
    /// Set for `EnumName.entries` / `.values()` lists. Only ever queried as
    /// a boolean ("is this the enum-entries list"), so a flag suffices — no
    /// StringRef allocation.
    enum_entries: bool = false,
    /// Set for a live view: a `MutableMap.values` view, a `subList` window,
    /// or a primitive-array `.asList()` (see `CollBacking`).
    backing: ?*CollBackingCell,
    /// Declared element-type head from an explicit call-site type
    /// argument on the creating stdlib function (`listOf<String>()`).
    /// Head name only; borrows the module's interned consts, which
    /// outlive every value. Dispatch reads it to type an empty list;
    /// `null` everywhere the creation site carried no annotation.
    declared_elem: ?[]const u8 = null,
    /// Structural-modification counter for fail-fast iteration. Allocated
    /// when a mutable list is created; shared (by ObjRef handle) across
    /// every value-copy of the list and the iterators it spawns. A
    /// structural mutation (add/remove/clear/…) bumps it; an iterator
    /// captures it and throws `ConcurrentModificationException` when it
    /// changes underneath. Null for read-only lists / views.
    mod_count: objcell.OptRef(u64) = .{},

    pub fn deinit(self: *ListData, allocator: std.mem.Allocator) void {
        Value.releaseValueList(self.items, allocator);
        if (self.backing) |b| (CollBackingRef{ .cell = b }).deinit();
        if (self.mod_count.get()) |mc| mc.deinit();
    }

    pub fn gcTrace(self: *const ListData, m: *objcell.gc.Marker) void {
        m.shade(&self.items.cell.hdr);
        if (self.backing) |b| m.shade(&b.hdr);
        if (self.mod_count.get()) |mc| m.shade(&mc.cell.hdr);
    }
};

/// The control-block handle behind a boxed `Value.List` payload.
pub const ListRef = ObjRef(ListData);

/// Recover the owning control block from a boxed list payload pointer.
pub inline fn listRefOf(l: *ListData) ListRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", l)) };
}

/// The boxed payload of `Value.Set` (see `MapData` for the scheme).
pub const SetData = struct {
    items: ValueList,
    mutable: bool,
    /// Set when this is a live `MutableMap.keys`/`.entries` view.
    backing: ?*CollBackingCell,
    /// Declared element-type head from an explicit call-site type
    /// argument on the creating stdlib function; see `List`.
    declared_elem: ?[]const u8 = null,
    /// Structural-modification counter for fail-fast iteration; see `List`.
    mod_count: objcell.OptRef(u64) = .{},

    pub fn deinit(self: *SetData, allocator: std.mem.Allocator) void {
        Value.releaseValueList(self.items, allocator);
        if (self.backing) |b| (CollBackingRef{ .cell = b }).deinit();
        if (self.mod_count.get()) |mc| mc.deinit();
    }

    pub fn gcTrace(self: *const SetData, m: *objcell.gc.Marker) void {
        m.shade(&self.items.cell.hdr);
        if (self.backing) |b| m.shade(&b.hdr);
        if (self.mod_count.get()) |mc| m.shade(&mc.cell.hdr);
    }
};

/// The control-block handle behind a boxed `Value.Set` payload.
pub const SetRef = ObjRef(SetData);

/// Recover the owning control block from a boxed set payload pointer.
pub inline fn setRefOf(s: *SetData) SetRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", s)) };
}
/// A refcounted box holding a single `Value`, shared by handle. Used for
/// the component slots of `Pair`/`Triple`/`MapEntry`/
/// `Result`/`Exception.cause`/`BoundMethod.receiver`/`Sequence` generators so a
/// copy of the enclosing value shares the box by refcount and releasing the
/// last copy recursively frees the boxed `Value` (via `ObjRef(Value).deinit` →
/// `Value.deinit`). Same backing type as a capture `Cell`.
pub const ValueBox = ObjRef(Value);

/// Which face of a `MutableMap` a live view exposes.
pub const MapViewKind = enum { Keys, Values, Entries };

/// Back-reference carried by a live collection view so its reads and mutations
/// resolve through the originating source.
///   - `map`: a `MutableMap.keys`/`.values`/`.entries` view edits the map.
///   - `sublist`: a `List.subList(from, to)` window into `parent`; reads and
///     structural ops splice through the parent list's items.
///   - `array`: a primitive-array `.asList()` over packed scalar storage; reads
///     reflect later array element writes (a reference `Array<T>.asList()`
///     instead shares the boxed buffer outright and carries no backing).
pub const CollBacking = union(enum) {
    map: struct { entries: MapEntries, kind: MapViewKind },
    sublist: struct {
        /// The immediate parent's element storage: the parent VIEW's cache
        /// for a `sub.subList(...)` chain, or the root list itself.
        parent: ValueList,
        /// The immediate parent's own sublist backing when the parent is
        /// itself a view — write-through and refresh recurse through it to
        /// the root, updating each ancestor's window (Java's
        /// `SubList(parent)` chain). Non-owning, like `List.backing`.
        parent_backing: ?*CollBackingRef.Cell = null,
        /// Window start/length, PARENT-relative.
        from: usize,
        len: usize,
        /// Shared structural counter value this view last observed. A
        /// mismatch on access means the backing changed structurally not
        /// through this view (or a descendant) —
        /// ConcurrentModificationException.
        exp_mod: u64 = 0,
    },
    array: struct { buf: objcell.ObjRef(PrimBuf), view_kind: PrimitiveArrayKind },

    /// GC out-edge: keep the source cell reachable while a live view references
    /// it. The handle is a non-owning write-through reference (no `deinit`), so
    /// refcount teardown of this cell never releases the borrowed source; only
    /// the GC keeps it marked.
    pub fn gcTrace(self: *const CollBacking, m: *objcell.gc.Marker) void {
        switch (self.*) {
            .map => |x| m.shade(&x.entries.cell.hdr),
            .sublist => |x| {
                m.shade(&x.parent.cell.hdr);
                if (x.parent_backing) |pb| m.shade(&pb.hdr);
            },
            .array => |x| m.shade(&x.buf.cell.hdr),
        }
    }
};

/// A heap-managed `CollBacking`: the view owns this cell (retained/released and
/// GC-swept with the view) but not the source it points at.
pub const CollBackingRef = objcell.ObjRef(CollBacking);
/// The control block behind a `CollBackingRef`. `List`/`Set` store `?*Cell`
/// (a single pointer, so `?` is null-optimized to 8 bytes — keeping `Value`
/// pinned at 64) and reconstruct the `CollBackingRef` at each use.
pub const CollBackingCell = CollBackingRef.Cell;

/// Distinguishes integer ranges (`IntRange`) from long/char ranges.
pub const RangeKind = enum {
    Int,
    Long,
    Char,
    UInt,
    ULong,

    pub const default: RangeKind = .Int;

    /// Whether `cur` has not yet passed `end` in the step's direction — the
    /// "keep iterating" test. `ULong` values span the full u64 range stored as
    /// i64, so they compare unsigned; every other kind fits a signed i64 (UInt
    /// is 0..2^32-1). Used by every progression cursor and the emptiness check
    /// so `MaxUL..MinUL` reads as empty rather than a wrapped, huge range.
    pub fn inBounds(self: RangeKind, cur: i64, end: i64, step: i64) bool {
        if (self == .ULong) {
            const uc: u64 = @bitCast(cur);
            const ue: u64 = @bitCast(end);
            return if (step > 0) uc <= ue else uc >= ue;
        }
        return if (step > 0) cur <= end else cur >= end;
    }

    /// `a until to` / `a ..< to` is empty exactly when `to` is the kind's
    /// MIN_VALUE (Char/UInt/ULong: 0).
    pub fn untilEmpty(self: RangeKind, to: i64) bool {
        return switch (self) {
            .Int => to <= std.math.minInt(i32),
            .Long => to == std.math.minInt(i64),
            .Char, .UInt, .ULong => to == 0,
        };
    }

    /// Stored `(start, end)` bounds of the kind's EMPTY range: signed kinds use
    /// `1..0`, unsigned kinds `MAX..0` (matching `IntRange.EMPTY` /
    /// `UIntRange.EMPTY`).
    pub fn emptyBounds(self: RangeKind) [2]i64 {
        return switch (self) {
            .Int, .Long, .Char => .{ 1, 0 },
            .UInt => .{ std.math.maxInt(u32), 0 },
            .ULong => .{ -1, 0 },
        };
    }
};

/// Numeric promotion rank — wider types win in mixed arithmetic.
pub const NumericRank = enum(u8) {
    Byte = 0,
    Short = 1,
    Int = 2,
    Long = 3,
    UByte = 4,
    UShort = 5,
    UInt = 6,
    ULong = 7,
    Float = 8,
    Double = 9,
};

/// Identifies the typed Kotlin primitive-array variants.
pub const PrimitiveArrayKind = enum {
    Int,
    Long,
    Double,
    Float,
    Short,
    Byte,
    Boolean,
    Char,
    UInt,
    ULong,
    UShort,
    UByte,

    pub fn typeFqn(self: PrimitiveArrayKind) []const u8 {
        return switch (self) {
            .Int => "kotlin.IntArray",
            .Long => "kotlin.LongArray",
            .Double => "kotlin.DoubleArray",
            .Float => "kotlin.FloatArray",
            .Short => "kotlin.ShortArray",
            .Byte => "kotlin.ByteArray",
            .Boolean => "kotlin.BooleanArray",
            .Char => "kotlin.CharArray",
            .UInt => "kotlin.UIntArray",
            .ULong => "kotlin.ULongArray",
            .UShort => "kotlin.UShortArray",
            .UByte => "kotlin.UByteArray",
        };
    }

    pub fn simpleName(self: PrimitiveArrayKind) []const u8 {
        return switch (self) {
            .Int => "Int",
            .Long => "Long",
            .Double => "Double",
            .Float => "Float",
            .Short => "Short",
            .Byte => "Byte",
            .Boolean => "Boolean",
            .Char => "Char",
            .UInt => "UInt",
            .ULong => "ULong",
            .UShort => "UShort",
            .UByte => "UByte",
        };
    }

    /// Byte width of one packed element of this kind.
    pub fn elemSize(self: PrimitiveArrayKind) usize {
        return switch (self) {
            .Byte, .UByte, .Boolean => 1,
            .Short, .UShort, .Char => 2,
            .Int, .UInt, .Float => 4,
            .Long, .ULong, .Double => 8,
        };
    }

    /// The signed array kind backing an unsigned array (`UByteArray.storage`
    /// is a `ByteArray` over the same bytes), or null for a non-unsigned kind.
    pub fn signedCounterpart(self: PrimitiveArrayKind) ?PrimitiveArrayKind {
        return switch (self) {
            .UByte => .Byte,
            .UShort => .Short,
            .UInt => .Int,
            .ULong => .Long,
            else => null,
        };
    }
};

/// Packed scalar storage for a Kotlin primitive array (`IntArray`,
/// `BooleanArray`, `ByteArray`, …). Replaces the 64-byte-per-element boxed
/// `ArrayList(Value)` with a flat byte buffer (1–8 bytes/element): ~8–64× less
/// memory, cache-resident, no per-element retain/release, and the GC traces
/// nothing (scalars have no out-edges). Elements box/unbox at the boundary.
pub const PrimBuf = struct {
    kind: PrimitiveArrayKind,
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    pub fn len(self: *const PrimBuf) usize {
        return self.bytes.items.len / self.kind.elemSize();
    }

    fn scalarPtr(self: anytype, i: usize) [*]u8 {
        return self.bytes.items.ptr + i * self.kind.elemSize();
    }

    fn readAs(comptime T: type, p: [*]const u8) T {
        var v: T = undefined;
        @memcpy(std.mem.asBytes(&v), p[0..@sizeOf(T)]);
        return v;
    }
    fn writeAs(comptime T: type, p: [*]u8, v: T) void {
        @memcpy(p[0..@sizeOf(T)], std.mem.asBytes(&v));
    }

    /// Box element `i` into the `Value` the boxed array would have held.
    pub fn get(self: *const PrimBuf, i: usize) Value {
        return self.getAs(i, self.kind);
    }

    /// As `get`, but boxes according to `view_kind` rather than the storage
    /// kind. The two differ only for an unsigned-array view over signed
    /// backing (`IntArray.asUIntArray()`), where the byte layout is identical
    /// and only the boxed tag changes (`Int` -> `UInt`).
    pub fn getAs(self: *const PrimBuf, i: usize, view_kind: PrimitiveArrayKind) Value {
        const p: [*]const u8 = self.bytes.items.ptr + i * view_kind.elemSize();
        return switch (view_kind) {
            .Int => .{ .Int = readAs(i32, p) },
            .Long => .{ .Long = readAs(i64, p) },
            .Double => .{ .Double = readAs(f64, p) },
            .Float => .{ .Float = readAs(f32, p) },
            .Short => .{ .Short = readAs(i16, p) },
            .Byte => .{ .Byte = readAs(i8, p) },
            .Boolean => .{ .Bool = readAs(u8, p) != 0 },
            .Char => .{ .Char = readAs(u16, p) },
            .UInt => .{ .UInt = readAs(u32, p) },
            .ULong => .{ .ULong = readAs(u64, p) },
            .UShort => .{ .UShort = readAs(u16, p) },
            .UByte => .{ .UByte = readAs(u8, p) },
        };
    }

    /// Unbox `v` into element `i`. `i` must be in bounds. Numeric values are
    /// read through the widening accessors so a coerced argument still stores
    /// correctly; the destination kind defines the stored width.
    pub fn set(self: *PrimBuf, i: usize, v: Value) void {
        self.setAs(i, v, self.kind);
    }

    /// As `set`, but unboxes according to `view_kind` (see `getAs`).
    pub fn setAs(self: *PrimBuf, i: usize, v: Value, view_kind: PrimitiveArrayKind) void {
        const p: [*]u8 = self.bytes.items.ptr + i * view_kind.elemSize();
        switch (view_kind) {
            .Int => writeAs(i32, p, @truncate(v.asI64() orelse 0)),
            .Long => writeAs(i64, p, v.asI64() orelse 0),
            .Double => writeAs(f64, p, v.asF64() orelse 0),
            .Float => writeAs(f32, p, @floatCast(v.asF64() orelse 0)),
            .Short => writeAs(i16, p, @truncate(v.asI64() orelse 0)),
            .Byte => writeAs(i8, p, @truncate(v.asI64() orelse 0)),
            .Boolean => writeAs(u8, p, if (v == .Bool and v.Bool) 1 else 0),
            .Char => writeAs(u16, p, if (v == .Char) v.Char else @truncate(@as(u64, @bitCast(v.asI64() orelse 0)))),
            .UInt => writeAs(u32, p, @truncate(@as(u64, @bitCast(v.asI64() orelse 0)))),
            .ULong => writeAs(u64, p, @bitCast(v.asI64() orelse 0)),
            .UShort => writeAs(u16, p, @truncate(@as(u64, @bitCast(v.asI64() orelse 0)))),
            .UByte => writeAs(u8, p, @truncate(@as(u64, @bitCast(v.asI64() orelse 0)))),
        }
    }

    pub fn append(self: *PrimBuf, a: std.mem.Allocator, v: Value) std.mem.Allocator.Error!void {
        const es = self.kind.elemSize();
        try self.bytes.appendNTimes(a, 0, es);
        self.set(self.len() - 1, v);
    }

    /// GC: scalars have no out-edges, so tracing is a no-op (the decl makes the
    /// generic tracer treat this as a leaf rather than guessing), and mutable
    /// access needs no write barrier.
    pub const gc_pointer_free = true;
    pub fn gcTrace(self: *const PrimBuf, m: *objcell.gc.Marker) void {
        _ = self;
        _ = m;
    }
    pub fn gcFinalize(self: *PrimBuf, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
    }
    /// Bytes owned beyond the control block (for the GC collection threshold).
    pub fn gcExternalBytes(self: *const PrimBuf) usize {
        return self.bytes.capacity;
    }
    pub fn deinit(self: *PrimBuf, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
    }
};

/// Storage for `kotlin.Array<T>` and the primitive-array siblings. `boxed`
/// holds reference types and `Array<T>`; `packed` holds primitive scalars. A
/// union (not two fields) so every access site is compiler-flagged when the
/// representation changes — primitive arrays must never be silently read as an
/// empty boxed list.
pub const ArrayStore = union(enum) {
    boxed: ValueList,
    scalars: ObjRef(PrimBuf),
};

/// `kotlin.Array<T>` and the primitive-array siblings. `prim` is the element
/// kind (`null` for a reference `Array<T>`) and matches `storage`: `.boxed`
/// when `prim == null`, `.scalars` when `prim != null`.
pub const ArrayData = struct {
    /// The storage cell: an `ObjRef(std.ArrayList(Value))` cell when
    /// `prim == null` (a reference `Array<T>`), an `ObjRef(PrimBuf)` cell
    /// otherwise — the invariant that lets the payload drop the union tag
    /// and pack to (pointer, prim).
    cell: *anyopaque,
    prim: ?PrimitiveArrayKind,

    pub fn boxed(vl: ValueList) ArrayData {
        return .{ .cell = vl.cell, .prim = null };
    }

    pub fn scalars(pb: ObjRef(PrimBuf), kind: PrimitiveArrayKind) ArrayData {
        return .{ .cell = pb.cell, .prim = kind };
    }

    /// Rebuild the typed storage view from the packed cell pointer.
    pub fn storage(self: ArrayData) ArrayStore {
        if (self.prim == null) return .{ .boxed = .{ .cell = @ptrCast(@alignCast(self.cell)) } };
        return .{ .scalars = .{ .cell = @ptrCast(@alignCast(self.cell)) } };
    }

    pub fn len(self: ArrayData) usize {
        switch (self.storage()) {
            .boxed => |vl| {
                const g = vl.borrow();
                defer g.deinit();
                return g.get().items.len;
            },
            .scalars => |pb| {
                const g = pb.borrow();
                defer g.deinit();
                return g.get().len();
            },
        }
    }

    /// Box element `i` (0-based, must be in bounds). Boxed elements are returned
    /// as stored (caller retains if it keeps a copy); packed elements are fresh
    /// scalars with no out-edges.
    pub fn get(self: ArrayData, i: usize) Value {
        switch (self.storage()) {
            .boxed => |vl| {
                const g = vl.borrow();
                defer g.deinit();
                return g.get().items[i];
            },
            .scalars => |pb| {
                const g = pb.borrow();
                defer g.deinit();
                return g.get().getAs(i, self.prim orelse g.get().kind);
            },
        }
    }

    /// Write element `i` (must be in bounds). For a boxed array the previous
    /// element is released and the new one retained under a reclaiming backend;
    /// packed elements are plain scalars.
    pub fn set(self: ArrayData, allocator: std.mem.Allocator, i: usize, v: Value) void {
        switch (self.storage()) {
            .boxed => |vl| {
                const g = vl.borrowMut();
                defer g.deinit();
                const items = g.get().items;
                if (objcell.reclaimEnabled()) {
                    items[i].release(allocator);
                    v.retain();
                }
                items[i] = v;
            },
            .scalars => |pb| {
                const g = pb.borrowMut();
                defer g.deinit();
                g.get().setAs(i, v, self.prim orelse g.get().kind);
            },
        }
    }

    /// A freshly allocated boxed copy of every element (caller owns the slice;
    /// elements are NOT retained — matches the prior `a.dupe(Value, items)` of
    /// boxed arrays). For packed arrays the scalars are boxed into the copy; the
    /// array stays packed.
    pub fn snapshot(self: ArrayData, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Value {
        return self.snapshotRange(allocator, 0, self.len());
    }

    /// `snapshot` of the half-open element range `[start, end)` only. A range
    /// copy (`copyInto` of a slice out of a large backing array) pays for the
    /// elements it moves rather than for the whole source.
    pub fn snapshotRange(self: ArrayData, allocator: std.mem.Allocator, start: usize, end: usize) std.mem.Allocator.Error![]Value {
        switch (self.storage()) {
            .boxed => |vl| {
                const g = vl.borrow();
                defer g.deinit();
                const items = g.get().items;
                const lo = @min(start, items.len);
                const hi = @min(end, items.len);
                return allocator.dupe(Value, items[lo..@max(lo, hi)]);
            },
            .scalars => |pb| {
                const g = pb.borrow();
                defer g.deinit();
                const view_kind = self.prim orelse g.get().kind;
                const n = g.get().len();
                const lo = @min(start, n);
                const hi = @max(lo, @min(end, n));
                const out = try allocator.alloc(Value, hi - lo);
                var i: usize = lo;
                while (i < hi) : (i += 1) out[i - lo] = g.get().getAs(i, view_kind);
                return out;
            },
        }
    }

    /// The boxed `ValueList` ObjRef when this is a reference array, else `null`.
    /// For sites that genuinely need to alias the backing list (iterators); a
    /// packed array has no such list (use `snapshot`).
    pub fn boxedList(self: ArrayData) ?ValueList {
        return switch (self.storage()) {
            .boxed => |vl| vl,
            .scalars => null,
        };
    }

    /// Drop one reference to the backing storage (boxed list or packed buffer).
    pub fn deinitStorage(self: ArrayData) void {
        switch (self.storage()) {
            .boxed => |vl| vl.deinit(),
            .scalars => |pb| pb.deinit(),
        }
    }

    /// Identity (backing-cell address) for reference equality and `===`.
    pub fn identity(self: ArrayData) usize {
        return switch (self.storage()) {
            .boxed => |vl| vl.identity(),
            .scalars => |pb| pb.identity(),
        };
    }

    /// Build a primitive (packed) array Value from boxed `items` (unboxed into
    /// the scalar buffer; the caller still owns/relinquishes `items`).
    pub fn initPacked(a: std.mem.Allocator, kind: PrimitiveArrayKind, items: []const Value) std.mem.Allocator.Error!Value {
        var pb = PrimBuf{ .kind = kind };
        try pb.bytes.appendNTimes(a, 0, items.len * kind.elemSize());
        for (items, 0..) |v, i| pb.set(i, v);
        return .{ .Array = ArrayData.scalars(try ObjRef(PrimBuf).initOwned(a, pb), kind) };
    }

    /// Build a reference `Array<T>` Value from a boxed `ValueList`.
    pub fn fromBoxedList(vl: ValueList) Value {
        return .{ .Array = ArrayData.boxed(vl) };
    }

    /// Overwrite every element from `src` (length must equal `len()`). Mirrors a
    /// snapshot→reorder→write-back (no net refcount change for a permutation):
    /// boxed elements are replaced as-is, packed scalars are unboxed.
    pub fn writeBack(self: ArrayData, a: std.mem.Allocator, src: []const Value) std.mem.Allocator.Error!void {
        switch (self.storage()) {
            .boxed => |vl| {
                const g = vl.borrowMut();
                defer g.deinit();
                g.get().clearRetainingCapacity();
                try g.get().appendSlice(a, src);
            },
            .scalars => |pb| {
                const g = pb.borrowMut();
                defer g.deinit();
                for (src, 0..) |v, i| g.get().set(i, v);
            },
        }
    }
};

/// Built-in property delegates (`lazy`, `Delegates.observable`,
/// `Delegates.notNull`).
pub const DelegateKind = union(enum) {
    /// `lazy { producer }`.
    Lazy: struct { producer: Value, cached: ?Value },
    /// `Delegates.observable(initial) { property, old, new -> … }`.
    Observable: struct { value: Value, on_change: Value },
    /// `Delegates.notNull<T>()`.
    NotNull: struct { value: ?Value, name: []const u8 },

    /// GC out-edges: a delegate held across a collection must keep its producer
    /// / change lambda and stored/cached value reachable (they live only here).
    pub fn gcTrace(self: *const DelegateKind, m: *objcell.gc.Marker) void {
        switch (self.*) {
            .Lazy => |l| {
                l.producer.gcMark(m);
                if (l.cached) |c| c.gcMark(m);
            },
            .Observable => |o| {
                o.value.gcMark(m);
                o.on_change.gcMark(m);
            },
            .NotNull => |n| if (n.value) |v| v.gcMark(m),
        }
    }
};

/// State-machine representation of a `suspend fun` body.
pub const SuspendBody = struct {
    states: []SuspendState,
};

/// One "basic block" in a suspend state machine.
pub const SuspendState = struct {
    /// Optional local to bind the resumed value to before the stmts run.
    resume_target: ?[]const u8,
    /// Statements to execute in order.
    stmts: []ast.Stmt,
    /// What to do after the last stmt finishes.
    transition: SuspendTransition,
};

pub const SuspendTransition = union(enum) {
    /// Move to the named state.
    Goto: usize,
    /// Function returns.
    Return,
    /// Branch on a boolean register: jump to `then_state` if true.
    Branch: struct { then_state: usize, else_state: usize },
};

/// Result of a previously-suspended `suspendCoroutine` call.
pub const PausedResume = union(enum) {
    Resumed: Value,
    Failed: Value,
};

/// Where a finished suspend frame hands its result.
pub const SuspendCallerCont = union(enum) {
    Frame: ObjRef(SuspendFrame),
    HostSlot: ObjRef(?HostSlotResult),
};

/// `Result<Value, Value>` payload delivered to a `runBlocking` host slot.
pub const HostSlotResult = union(enum) {
    ok: Value,
    err: Value,
};

/// A live `suspend fun` invocation.
pub const SuspendFrame = struct {
    decl: *const ast.Function,
    body: ObjRef(SuspendBody),
    env: ObjRef(Env),
    /// Locals introduced by val/var statements in earlier states.
    locals: std.ArrayList(Local),
    /// Index into `body.states` for the next state to run.
    state: usize,
    /// The caller's continuation chain, when this frame is active.
    caller: ?SuspendCallerCont,
    /// Result of a paused async `suspendCoroutine`, read on re-entry.
    paused_resume: ?PausedResume,

    pub const Local = struct { name: []const u8, value: Value };
};

/// The lazy coroutine state of a `sequence { yield(...) }` / `iterator { ... }`
/// builder. The builder block runs as a restricted-suspension coroutine: each
/// `yield(x)` suspends it, capturing the block's continuation as an
/// `ir.eval.SuspendState` box held here through `cont` (an `*anyopaque` because
/// `runtime` cannot import `ir`). The host drives one step per consumer pull
/// (`builderStep`): the first pull starts the block, a later pull resumes the
/// continuation. `scope` is the `SequenceScope` Instance the block runs against;
/// the host reads the yielded value off its fields after each suspension.
pub const BuilderState = struct {
    /// The `suspend SequenceScope<T>.() -> Unit` block (an `IrClosure` Value).
    block: ValueBox,
    /// The `SequenceScope` Instance the block runs against; carries the pending
    /// yielded value / yieldAll iterator between steps.
    scope: ValueBox,
    /// Host-owned `*ir.eval.SuspendState` — the parked continuation between
    /// pulls. `null` before the first pull, after completion, and while a pull
    /// is in flight.
    cont: ?*anyopaque = null,
    /// The block has been started (the first pull ran `evalClosureRaw`).
    started: bool = false,
    /// The block ran to completion (no more elements).
    done: bool = false,
    /// The block threw. The throw itself propagated out of the pull that
    /// observed it; every later pull throws IllegalStateException, matching
    /// `SequenceBuilderIterator`'s failed state.
    failed: bool = false,

    /// GC out-edges: the builder block, the scope Instance, and every Value
    /// the parked continuation's frames keep live (through the suspend-mark
    /// hook). All are reachable only through a held `Sequence`/`Iterator`.
    pub fn gcTrace(self: *const BuilderState, m: *objcell.gc.Marker) void {
        m.shade(&self.block.cell.hdr);
        m.shade(&self.scope.cell.hdr);
        if (self.cont) |c| {
            if (objcell.gc.markSuspendHook) |h| h(c, m);
        }
    }

    /// Finalize an abandoned builder: a `Sequence` swept without being driven
    /// to completion still owns its parked continuation box (frames with
    /// retained values + raw slice buffers). Release and free it through the
    /// host hook so the run allocator reclaims it.
    pub fn gcFinalize(self: *BuilderState, a: std.mem.Allocator) void {
        self.freeCont(a);
    }

    /// Refcount teardown: same as `gcFinalize` (the continuation box must be
    /// freed when the last handle to an undriven builder drops).
    pub fn deinit(self: *BuilderState, a: std.mem.Allocator) void {
        self.freeCont(a);
    }

    fn freeCont(self: *BuilderState, a: std.mem.Allocator) void {
        if (self.cont) |c| {
            self.cont = null;
            if (objcell.gc.freeSuspendHook) |h| h(c, a);
        }
    }
};

pub const BuilderStateRef = ObjRef(BuilderState);

/// Lazy iterator over a `Sequence` (the `Sequence.iterator()` / `iterator{}`
/// result). Pulls one output element at a time from the underlying source +
/// op pipeline, so an infinite source never materialises. Holds the `Sequence`
/// value, a one-element lookahead, the done flag, and the per-op streaming
/// counters (mirrors the materialiser's `PumpState`).
pub const SeqIterState = struct {
    /// The `Value.Sequence` being iterated.
    seq: Value,
    /// One-element lookahead produced by `hasNext()` and consumed by `next()`.
    buffered: ?Value = null,
    /// The pipeline is exhausted.
    done: bool = false,
    /// For an `Items` source: the cursor into the eager element slice.
    src_pos: usize = 0,
    /// For a `Generate` source: the next seed to emit (the seed initially,
    /// then each step's result), or null before the first pull / once done.
    gen_cur: ?Value = null,
    gen_started: bool = false,
    /// For an `IteratorFn` source: the Iterator the factory produced for
    /// THIS iteration (invoked lazily on first pull).
    iter_obj: ?Value = null,
    /// For a `Merged` source: the two child iterators, created together on
    /// the first pull.
    iter_left: ?Value = null,
    iter_right: ?Value = null,
    /// Per-op streaming counters, indexed by op position. Allocated lazily to
    /// `ops.len`. `Take`/`Drop` counts and `takeWhile`/`dropWhile`/index state.
    taken: []usize = &.{},
    dropped: []usize = &.{},
    take_while_live: []bool = &.{},
    drop_while_live: []bool = &.{},
    indices: []usize = &.{},

    pub fn gcTrace(self: *const SeqIterState, m: *objcell.gc.Marker) void {
        self.seq.gcMark(m);
        if (self.buffered) |b| b.gcMark(m);
        if (self.gen_cur) |g| g.gcMark(m);
        if (self.iter_obj) |v| v.gcMark(m);
        if (self.iter_left) |v| v.gcMark(m);
        if (self.iter_right) |v| v.gcMark(m);
    }

    pub fn gcFinalize(self: *SeqIterState, a: std.mem.Allocator) void {
        self.freeBufs(a);
    }

    pub fn deinit(self: *SeqIterState, a: std.mem.Allocator) void {
        if (objcell.reclaimEnabled()) {
            self.seq.release(a);
            if (self.buffered) |b| b.release(a);
            if (self.gen_cur) |g| g.release(a);
            if (self.iter_obj) |v| v.release(a);
            if (self.iter_left) |v| v.release(a);
            if (self.iter_right) |v| v.release(a);
        }
        self.freeBufs(a);
    }

    fn freeBufs(self: *SeqIterState, a: std.mem.Allocator) void {
        if (self.taken.len != 0) a.free(self.taken);
        if (self.dropped.len != 0) a.free(self.dropped);
        if (self.take_while_live.len != 0) a.free(self.take_while_live);
        if (self.drop_while_live.len != 0) a.free(self.drop_while_live);
        if (self.indices.len != 0) a.free(self.indices);
        self.taken = &.{};
        self.dropped = &.{};
        self.take_while_live = &.{};
        self.drop_while_live = &.{};
        self.indices = &.{};
    }
};

pub const SeqIterStateRef = ObjRef(SeqIterState);

/// The advancing state of a `Value.Iterator`, held behind one shared handle so
/// it survives the by-value copies a `Value` undergoes.
pub const IterCursor = struct {
    /// Index of the next element to yield.
    pos: usize = 0,
    /// Index of the element the LAST `next()`/`previous()` returned (the
    /// ListIterator set/remove target), or -1 when none — before the first
    /// move, and after `add`/`remove`.
    last_ret: i64 = -1,
    /// The source's `mod_count` as captured when the iterator was created.
    /// Meaningful only when the iterator carries a `mod_count` handle.
    exp_mod: u64 = 0,
    /// The elements (shared with the mutable source, or a snapshot). The
    /// fixed iterator fields ride in the cursor cell every step already
    /// borrows, so `Value.Iterator` is the one handle.
    items: ValueList,
    prim: ?PrimitiveArrayKind = null,
    /// The source collection's `mod_count`, shared with it. `next`/`hasNext`
    /// throw `ConcurrentModificationException` when it no longer matches
    /// `exp_mod`; the iterator's own `add`/`remove` resync it. Null when
    /// the source had no `mod_count`.
    mod_count: objcell.OptRef(u64) = .{},
    /// True only when the iterator shares a *mutable* collection's backing,
    /// so `MutableIterator.remove`/`MutableListIterator.set`/`.add` mutate
    /// the source. A snapshot iterator over a read-only collection (or an
    /// array/string) is false: those mutating ops throw
    /// `UnsupportedOperationException`, matching Kotlin.
    mutable: bool = false,

    pub fn deinit(self: *IterCursor, allocator: std.mem.Allocator) void {
        // Mirrors `Value.releaseValueList`: the last handle releases the
        // contained elements before dropping the list itself.
        if (self.items.strongCount() == 1) {
            const g = self.items.borrow();
            for (g.get().items) |e| e.release(allocator);
            g.deinit();
        }
        self.items.deinit();
        if (self.mod_count.get()) |mc| mc.deinit();
    }

    pub fn gcTrace(self: *const IterCursor, m: *objcell.gc.Marker) void {
        m.shade(&self.items.cell.hdr);
        if (self.mod_count.get()) |mc| m.shade(&mc.cell.hdr);
    }
};

pub const SequenceData = struct {
    source: SequenceSource,
    ops: []SeqOp,
    /// `generateSequence { … }` (nullary form) consumes once: the second
    /// iteration throws IllegalStateException, matching the source's
    /// `.constrainOnce()`.
    one_shot: bool = false,
    consumed: bool = false,

    /// GC out-edges: the lazy source (eager items, or the seed/step generator
    /// closures) and every pipeline op's lambda. Without this a `Sequence` held
    /// across a collection sweeps its generator/op closures and source elements
    /// (they are reachable only through here), so reads after the collection hit
    /// freed cells.
    pub fn gcTrace(self: *const SequenceData, m: *objcell.gc.Marker) void {
        switch (self.source) {
            .Items => |items| m.shade(&items.cell.hdr),
            .Generate => |g| {
                if (g.seed) |s| m.shade(&s.cell.hdr);
                m.shade(&g.next.cell.hdr);
            },
            .Builder => |b| m.shade(&b.cell.hdr),
            .IteratorFn => |f| m.shade(&f.cell.hdr),
            .Merged => |z| {
                m.shade(&z.left.cell.hdr);
                m.shade(&z.right.cell.hdr);
                if (z.transform) |t| m.shade(&t.cell.hdr);
            },
        }
        for (self.ops) |op| switch (op) {
            .Map,
            .Filter,
            .FilterNot,
            .OnEach,
            .MapIndexed,
            .FilterIndexed,
            .TakeWhile,
            .DropWhile,
            .FlatMap,
            .DistinctBy,
            .SortedWith,
            => |v| v.gcMark(m),
            .SortedBy => |sb| sb.selector.gcMark(m),
            .Take, .Drop, .Distinct, .Sorted => {},
        };
    }
};

pub const SequenceSource = union(enum) {
    /// Eager-known elements (`asSequence` / `sequenceOf`).
    Items: ValueSlice,
    /// `generateSequence(seed) { it -> next }`. `seed` is null for the
    /// nullary form. `seed_is_fn` marks the `generateSequence(seedFn,
    /// next)` form: the boxed seed is a producer invoked at each
    /// iteration start.
    Generate: struct { seed: ?ValueBox, next: ValueBox, seed_is_fn: bool = false },
    /// `sequence { yield(...) }` / `iterator { ... }` — a lazy coroutine
    /// builder driven one element at a time.
    Builder: BuilderStateRef,
    /// `Sequence { () -> Iterator<T> }` — the SAM factory. Each iteration
    /// invokes the factory for a fresh Iterator and pulls it element by
    /// element (lazy, re-iterable).
    IteratorFn: ValueBox,
    /// `seq.zip(other)` — the merging source. Each pull advances BOTH child
    /// iterators one element (left first, then right), so shared-state
    /// generators observe the strict alternating interleave of
    /// `MergingSequence`. `transform` (when non-null) maps each (a, b)
    /// instead of building a Pair.
    Merged: MergedSource,
};

pub const MergedSource = struct { left: ValueBox, right: ValueBox, transform: ?ValueBox = null };

pub const SeqOp = union(enum) {
    Map: Value,
    Filter: Value,
    FilterNot: Value,
    /// `onEach { }` — run the lambda for its side effect, pass through.
    OnEach: Value,
    /// `mapIndexed { index, value -> }`.
    MapIndexed: Value,
    /// `filterIndexed { index, value -> }`.
    FilterIndexed: Value,
    Take: i64,
    Drop: i64,
    TakeWhile: Value,
    DropWhile: Value,
    FlatMap: Value,
    Distinct,
    DistinctBy: Value,
    /// Sort in natural order; `descending` flips the comparison.
    Sorted: bool,
    /// Sort by a key-selector lambda; the bool flips the comparison.
    SortedBy: struct { selector: Value, descending: bool },
    /// Sort with a user-supplied `Value::Comparator`.
    SortedWith: Value,
};

/// Compiled regex + the original pattern source. The compiled engine is
/// not in the Zig std; `engine` is an opaque host-provided handle.
pub const RegexData = struct {
    /// A compiled regex is immutable once PUBLISHED: `regex_ctor` attaches
    /// `options` through `asPtr` after `compileRegexFlags` mints the cell but
    /// before the value escapes the constructor, so no reader can observe a
    /// mutation and the cell is never write-locked; elide the reader lock.
    /// Any new mutation site must stay inside that pre-escape window.
    pub const objref_immutable = true;

    pattern: StringRef,
    /// Opaque compiled-regex handle owned by the host regex binding.
    engine: ?*anyopaque,
    /// The RegexOption values the regex was constructed with (the
    /// caller's enum singletons, for identity-equal `options` reads).
    options: ?ValueList = null,

    /// GC out-edge: a live regex keeps its pattern bytes reachable.
    pub fn gcTrace(self: *const RegexData, m: *objcell.gc.Marker) void {
        m.shade(&self.pattern.cell.hdr);
        if (self.options) |ol| m.shade(&ol.cell.hdr);
    }
};

pub const MatchGroupData = struct {
    value: StringRef,
    start: i64,
    end_inclusive: i64,

    pub fn deinit(self: *MatchGroupData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.value.deinit();
    }

    pub fn gcTrace(self: *const MatchGroupData, m: *objcell.gc.Marker) void {
        m.shade(&self.value.cell.hdr);
    }
};

/// A single regex match outcome — full match plus capture groups, with
/// enough state to resume scanning via `MatchResult.next()`.
pub const MatchData = struct {
    input: StringRef,
    /// Index 0 is the whole match; later indices are capture groups.
    /// `null` means a group did not participate.
    groups: []?MatchGroupData,
    /// Byte offset in `input` immediately after the matched span.
    end_byte: usize,
    regex: ObjRef(RegexData),

    /// GC out-edges: the matched input, the originating regex, and each capture
    /// group's text — all reachable only through a held `MatchResult`.
    pub fn gcTrace(self: *const MatchData, m: *objcell.gc.Marker) void {
        m.shade(&self.input.cell.hdr);
        m.shade(&self.regex.cell.hdr);
        for (self.groups) |g| if (g) |grp| m.shade(&grp.value.cell.hdr);
    }
};

// ---------------------------------------------------------------------------
// Host-op temporary keepalive (a GC root). A pure-host re-entry — a stdlib op
// iterating a host-built slice and calling a user callable via `invoke*` /
// `callValueRec` — holds its accumulator/snapshot in a native `ArrayList`/slice
// with NO calling frame register pinning it. The nested eval the callable runs
// reaches a safe point, so those host-local Values must be a root for that
// window. Each such op marks the stack depth on entry, pushes its in-progress
// contents before each re-entrant call, and restores to the entry mark at exit.
// Lives here (not in `ir/eval`) because the stdlib layer cannot import `ir`; it
// reaches the API through `runtime`.
// ---------------------------------------------------------------------------

/// `many`/`pairs` keep a whole slice rooted in O(1) (no per-element copy);
/// `cell` pins a raw object cell (e.g. a transient scope `Env` the host swapped
/// into place) whose own `gc_trace` then reaches its contents.
const KeepEntry = union(enum) {
    one: Value,
    many: []const Value,
    pairs: []const MapPair,
    cell: *objcell.gc.GcHeader,
};
threadlocal var host_keepalive: std.ArrayListUnmanaged(KeepEntry) = .empty;
threadlocal var keepalive_troot: objcell.gc.ThreadRoot = undefined;
threadlocal var keepalive_troot_inited: bool = false;

fn gcMarkKeepaliveCtx(ctx: *anyopaque, m: *objcell.gc.Marker) void {
    const stack: *const std.ArrayListUnmanaged(KeepEntry) = @ptrCast(@alignCast(ctx));
    for (stack.items) |e| switch (e) {
        .one => |v| v.gcMark(m),
        .many => |vs| for (vs) |v| v.gcMark(m),
        .pairs => |ps| for (ps) |*p| p.gcTrace(m),
        .cell => |h| m.shade(h),
    };
}

/// Unlink this thread's keepalive root node at its exit seam.
pub fn gcUninstallKeepaliveRoot() void {
    if (!keepalive_troot_inited) return;
    objcell.gc.unregisterThreadRoot(&keepalive_troot);
    keepalive_troot_inited = false;
}

/// Snapshot the keepalive depth; pass to `keepaliveRestore` to pop everything
/// pushed since. Valid (and cheap) even when the GC is off.
pub inline fn keepaliveMark() usize {
    return host_keepalive.items.len;
}

/// Register the keepalive root provider once. Lazy: the first push on any thread
/// installs it (idempotent across threads). The threadlocal stack it reads is
/// the collecting thread's — sufficient single-threaded; per-thread records
/// extend it across worker threads.
inline fn ensureKeepaliveRoot() void {
    if (keepalive_troot_inited) return;
    keepalive_troot_inited = true;
    keepalive_troot = .{ .ctx = @ptrCast(&host_keepalive), .mark = gcMarkKeepaliveCtx };
    objcell.gc.registerThreadRoot(&keepalive_troot);
}

/// Pin a single Value across a re-entrant host call. No-op unless GC is on.
pub fn keepalivePush(v: Value) void {
    if (!objcell.gc.gc_enabled) return;
    ensureKeepaliveRoot();
    host_keepalive.append(std.heap.page_allocator, .{ .one = v }) catch
        @panic("KGC: host_keepalive push failed");
}

/// Pin a whole slice of Values (an accumulator's live contents, a snapshot)
/// across a re-entrant host call. The slice must stay valid until the matching
/// restore. No-op unless GC is on.
pub fn keepalivePushSlice(vs: []const Value) void {
    if (!objcell.gc.gc_enabled) return;
    ensureKeepaliveRoot();
    host_keepalive.append(std.heap.page_allocator, .{ .many = vs }) catch
        @panic("KGC: host_keepalive push failed");
}

/// Pin a slice of `MapPair`s (a map/grouping accumulator's live contents)
/// across a re-entrant host call. No-op unless GC is on.
pub fn keepalivePushPairs(ps: []const MapPair) void {
    if (!objcell.gc.gc_enabled) return;
    ensureKeepaliveRoot();
    host_keepalive.append(std.heap.page_allocator, .{ .pairs = ps }) catch
        @panic("KGC: host_keepalive push failed");
}

/// Pin a raw object cell across a re-entrant host call — for a transient cell
/// the host holds in a stack local that no frame register or Vm-graph root
/// reaches (a scope `Env` swapped into the host's active globals). The cell's
/// own `gc_trace` reaches its contents. No-op unless GC is on.
pub fn keepalivePushCell(h: *objcell.gc.GcHeader) void {
    if (!objcell.gc.gc_enabled) return;
    ensureKeepaliveRoot();
    host_keepalive.append(std.heap.page_allocator, .{ .cell = h }) catch
        @panic("KGC: host_keepalive push failed");
}

/// Pop the keepalive stack back to a depth from `keepaliveMark`.
pub inline fn keepaliveRestore(mark: usize) void {
    if (!objcell.gc.gc_enabled) return;
    host_keepalive.items.len = mark;
}

/// The runtime value: a tagged union over every Kotlin value the
/// interpreter manipulates.
/// Receiver ABI required by a Kotlin classifier at the IR/runtime call
/// boundary. `instance` classifiers use numeric virtual slots. `specialized`
/// classifiers use the host member ABI, either because they have a dedicated
/// `Value` tag or because they are host-synthesized `Value.Instance` values.
pub const ReceiverAbi = enum {
    instance,
    specialized,
};

/// Canonical manifest of classifiers whose receivers have a specialized host
/// representation. Interface entries are included whenever at least one
/// specialized value implements them, so a call through that static interface
/// never assumes `Value.Instance`.
pub fn classifierReceiverAbi(fqn: []const u8) ReceiverAbi {
    if (std.mem.eql(u8, fqn, "kotlin.Function")) return .specialized;
    if (std.mem.startsWith(u8, fqn, "kotlin.Function") and
        allAsciiDigits(fqn["kotlin.Function".len..])) return .specialized;

    const specialized = [_][]const u8{
        "kotlin.Any",
        "kotlin.Nothing",
        "kotlin.Unit",
        "kotlin.Boolean",
        "kotlin.Byte",
        "kotlin.Short",
        "kotlin.Int",
        "kotlin.Long",
        "kotlin.UByte",
        "kotlin.UShort",
        "kotlin.UInt",
        "kotlin.ULong",
        "kotlin.Float",
        "kotlin.Double",
        "kotlin.Char",
        "kotlin.Number",
        "kotlin.Comparable",
        "kotlin.String",
        "kotlin.CharSequence",
        "kotlin.Pair",
        "kotlin.Triple",
        "kotlin.Result",
        "kotlin.Array",
        "kotlin.BooleanArray",
        "kotlin.ByteArray",
        "kotlin.ShortArray",
        "kotlin.IntArray",
        "kotlin.LongArray",
        "kotlin.UByteArray",
        "kotlin.UShortArray",
        "kotlin.UIntArray",
        "kotlin.ULongArray",
        "kotlin.FloatArray",
        "kotlin.DoubleArray",
        "kotlin.CharArray",
        "kotlin.Throwable",
        "kotlin.Exception",
        "kotlin.RuntimeException",
        "kotlin.Error",
        "kotlin.IllegalArgumentException",
        "kotlin.IllegalStateException",
        "kotlin.IndexOutOfBoundsException",
        "kotlin.ArrayIndexOutOfBoundsException",
        "kotlin.StringIndexOutOfBoundsException",
        "kotlin.NullPointerException",
        "kotlin.ArithmeticException",
        "kotlin.ClassCastException",
        "kotlin.NoSuchElementException",
        "kotlin.NumberFormatException",
        "kotlin.UnsupportedOperationException",
        "kotlin.UninitializedPropertyAccessException",
        "kotlin.ConcurrentModificationException",
        "kotlin.NoWhenBranchMatchedException",
        "kotlin.AssertionError",
        "kotlin.NegativeArraySizeException",
        "kotlin.collections.Iterable",
        "kotlin.collections.MutableIterable",
        "kotlin.collections.Collection",
        "kotlin.collections.MutableCollection",
        "kotlin.collections.List",
        "kotlin.collections.MutableList",
        "kotlin.collections.ArrayList",
        "kotlin.collections.Set",
        "kotlin.collections.MutableSet",
        "kotlin.collections.HashSet",
        "kotlin.collections.LinkedHashSet",
        "kotlin.collections.Map",
        "kotlin.collections.MutableMap",
        "kotlin.collections.HashMap",
        "kotlin.collections.LinkedHashMap",
        "kotlin.collections.Map.Entry",
        "kotlin.collections.MutableMap.MutableEntry",
        "kotlin.collections.Grouping",
        "kotlin.collections.Iterator",
        "kotlin.collections.MutableIterator",
        "kotlin.collections.ListIterator",
        "kotlin.collections.MutableListIterator",
        "kotlin.collections.BooleanIterator",
        "kotlin.collections.ByteIterator",
        "kotlin.collections.ShortIterator",
        "kotlin.collections.IntIterator",
        "kotlin.collections.LongIterator",
        "kotlin.collections.UByteIterator",
        "kotlin.collections.UShortIterator",
        "kotlin.collections.UIntIterator",
        "kotlin.collections.ULongIterator",
        "kotlin.collections.FloatIterator",
        "kotlin.collections.DoubleIterator",
        "kotlin.collections.CharIterator",
        "kotlin.collections.RandomAccess",
        "kotlin.enums.EnumEntries",
        "kotlin.sequences.Sequence",
        "kotlin.ranges.ClosedRange",
        "kotlin.ranges.OpenEndRange",
        "kotlin.ranges.IntProgression",
        "kotlin.ranges.LongProgression",
        "kotlin.ranges.UIntProgression",
        "kotlin.ranges.ULongProgression",
        "kotlin.ranges.CharProgression",
        "kotlin.ranges.IntRange",
        "kotlin.ranges.LongRange",
        "kotlin.ranges.UIntRange",
        "kotlin.ranges.ULongRange",
        "kotlin.ranges.CharRange",
        "kotlin.reflect.KClassifier",
        "kotlin.reflect.KClass",
        "kotlin.reflect.KCallable",
        "kotlin.reflect.KFunction",
        "kotlin.reflect.KProperty",
        "kotlin.reflect.KProperty0",
        "kotlin.reflect.KProperty1",
        "kotlin.reflect.KMutableProperty",
        "kotlin.reflect.KMutableProperty0",
        "kotlin.reflect.KMutableProperty1",
        "kotlin.text.Appendable",
        "kotlin.text.StringBuilder",
        "kotlin.text.Regex",
        "kotlin.text.MatchResult",
        "kotlin.text.MatchGroup",
        "kotlin.properties.ReadOnlyProperty",
        "kotlin.properties.ReadWriteProperty",
        "kotlin.time.TimeMark",
        "kotlin.time.ComparableTimeMark",
    };
    for (specialized) |name| {
        if (std.mem.eql(u8, fqn, name)) return .specialized;
    }
    return .instance;
}

fn allAsciiDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

pub const Value = union(enum) {
    Unit,
    /// The `COROUTINE_SUSPENDED` singleton.
    CoroutineSuspended,
    Int: i32,
    Long: i64,
    Short: i16,
    Byte: i8,
    UInt: u32,
    ULong: u64,
    UShort: u16,
    UByte: u8,
    Double: f64,
    /// Kotlin `Float`, stored as `f32`.
    Float: f32,
    Bool: bool,
    String: StringRef,
    /// Kotlin `Char` is a single UTF-16 code unit (may be a lone surrogate).
    Char: u16,
    Null,
    /// Inclusive integer progression with a signed step. Boxed like `Map`
    /// (see `RangeData`); construct with `Value.newRange`. Immutable after
    /// construction, so copies sharing the record is invisible.
    Range: *RangeData,
    /// A stdlib function value. The payload is an INTERNED program-
    /// lifetime record (`Value.internIntrinsic`): the fqn is a static
    /// string and the pair never dies, so copies carry one pointer and
    /// neither the refcount nor the collector ever touches it.
    Intrinsic: *const IntrinsicData,
    /// IR-side closure handle.
    IrClosure: struct {
        id: u64,
        captures: ValueSlice,
    },
    /// A method intrinsic bound to a specific receiver. Boxed like `Map`
    /// (see `BoundMethodData`); construct with `Value.newBoundMethod`.
    BoundMethod: *BoundMethodData,
    /// A thrown value, modeled as a Kotlin Throwable. Boxed like `Map` (see
    /// `ExceptionData`); construct with `Value.newException`.
    Exception: *ExceptionData,
    /// `kotlin.collections.List` / `MutableList`. Boxed like `Map` (see
    /// `ListData`); construct with `Value.newList`.
    List: *ListData,
    /// `kotlin.Array<T>` and primitive-array siblings.
    Array: ArrayData,
    /// `kotlin.collections.Set` / `MutableSet`. Boxed like `Map` (see
    /// `SetData`); construct with `Value.newSet`.
    Set: *SetData,
    /// `kotlin.collections.Map` / `MutableMap`. Boxed: the pointer targets
    /// the `data` field of an `ObjRef(MapData)` control block (recovered
    /// with `mapRefOf`), so a `Value` copy moves 8 bytes and shares the
    /// payload. Construct with `Value.newMap`.
    Map: *MapData,
    /// `kotlin.Pair`. Boxed like `Map` (see `PairData`); construct with
    /// `Value.newPair`.
    Pair: *PairData,
    /// `kotlin.Triple`.
    /// `kotlin.Triple`. Boxed like `Map` (see `TripleData`); construct
    /// with `Value.newTriple`.
    Triple: *TripleData,
    /// `kotlin.collections.Map.Entry`.
    /// `kotlin.collections.Map.Entry`. Boxed like `Map` (see
    /// `MapEntryData`); construct with `Value.newMapEntry`. Copies share
    /// the record — the JVM's reference semantics for an entry.
    MapEntry: *MapEntryData,
    /// `kotlin.Result<T>`.
    /// `kotlin.Result<T>`. Boxed like `Map` (see `ResultData`); construct
    /// with `Value.newResult`.
    Result: *ResultData,
    /// `kotlin.Comparator<T>`. Boxed like `Map` (see `ComparatorData`);
    /// construct with `Value.newComparator`.
    Comparator: *ComparatorData,
    /// A user-declared class.
    Class: ObjRef(ClassDef),
    /// A live instance of a user-declared class.
    Instance: ObjRef(InstanceData),
    /// `kotlin.sequences.Sequence<T>`.
    Sequence: ObjRef(SequenceData),
    /// `kotlin.collections.Iterator<T>` and primitive specializations.
    /// Snapshot/live iterator over materialised elements. The whole state
    /// (elements, cursor, prim kind, mod-count handle, mutability) lives
    /// in the ONE `IterCursor` cell every step already borrows; construct
    /// with `Value.newIterator`.
    Iterator: ObjRef(IterCursor),
    /// Lazy O(1)-memory iterator over a `Range`/progression. The whole
    /// state — cursor, yielded-last flag, and the fixed end/step/kind —
    /// lives in ONE shared cell (`RangeIterState`) so it survives the
    /// iterator value being copied between reads and costs a single lock
    /// per step. `done` exists because the cursor saturates at the
    /// integer boundary (`MaxL +| 1 == MaxL`), so a `cur <= end` test
    /// alone would loop forever on a range ending at
    /// `Long.MAX_VALUE`/`MIN_VALUE`.
    RangeIter: ObjRef(RangeIterState),
    /// Lazy iterator over a `Sequence` (the `Sequence.iterator()` / lazy
    /// `iterator { }` result), pulling one element at a time.
    SeqIter: SeqIterStateRef,
    /// A built-in property delegate.
    Delegate: ObjRef(DelegateKind),
    /// `::foo` — a lightweight property/function reference.
    PropertyRef: struct {
        name: StringRef,
    },
    /// `kotlin.text.Regex`.
    Regex: ObjRef(RegexData),
    /// `kotlin.text.MatchResult`.
    Match: ObjRef(MatchData),
    /// `kotlin.text.MatchGroup`. Boxed like `Map` (see `MatchGroupData`);
    /// construct with `Value.newMatchGroup`.
    MatchGroup: *MatchGroupData,
    /// `kotlin.text.StringBuilder` — mutable string buffer.
    StringBuilder: ObjRef(std.ArrayList(u8)),
    /// Boxed local `var` captured by a closure (`Ref.ObjectRef`).
    Cell: ObjRef(Value),

    /// Wrap a value in a fresh capture cell.
    pub fn newCell(allocator: std.mem.Allocator, v: Value) !Value {
        return .{ .Cell = try ObjRef(Value).init(allocator, v) };
    }

    /// Heap-box a `Value` so it can fill a `*Value` payload slot
    /// (`Box::new(v)` -> `*Value`).
    pub fn box(allocator: std.mem.Allocator, v: Value) std.mem.Allocator.Error!*Value {
        const p = try allocator.create(Value);
        p.* = v;
        return p;
    }

    /// Box a `Value` into a refcounted `ValueBox` (the owning component slot of
    /// `Pair`/`Triple`/`MapEntry`/`Result`/etc.). The box owns `v`; copies of
    /// the enclosing value clone the box, and the last release frees `v`.
    pub fn boxRef(allocator: std.mem.Allocator, v: Value) std.mem.Allocator.Error!ValueBox {
        return ValueBox.init(allocator, v);
    }

    /// Reference-counting increment: bump the strong count of
    /// every refcounted handle this value holds, returning another owning
    /// copy of the same value graph. Primitives and the immutable program
    /// graph (`Class`) are no-ops. Owning-`*Value` variants
    /// (`Pair`/`Triple`/`MapEntry`/`Result`/`BoundMethod`/`Exception.cause`)
    /// are not yet refcounted — they share their boxes on copy and are
    /// retained/released as no-ops here until they are converted to `ObjRef`.
    /// Single source of truth for the value graph's out-edges: invokes
    /// `visitor.visit(objref)` for every refcounted `ObjRef` handle this value
    /// *directly* holds (one level — the handle's own cell, not its transitive
    /// elements; a container backing cell's own children are reached through the
    /// cell's GC `trace_fn`). `retain` (incref), `release` (decref), and the GC
    /// mark phase all drive this same walk, so they cannot diverge. `backing`
    /// write-through views are non-owning and intentionally not visited.
    pub fn forEachChildCell(self: Value, visitor: anytype) void {
        switch (self) {
            .String => |s| visitor.visit(s),
            .Instance => |i| visitor.visit(i),
            .Sequence => |s| visitor.visit(s),
            .Delegate => |d| visitor.visit(d),
            .Regex => |r| visitor.visit(r),
            .Match => |m| visitor.visit(m),
            .StringBuilder => |s| visitor.visit(s),
            .Cell => |c| visitor.visit(c),
            .IrClosure => |c| visitor.visit(c.captures),
            .Comparator => |c| visitor.visit(comparatorRefOf(c)),
            .List => |x| visitor.visit(listRefOf(x)),
            .Set => |x| visitor.visit(setRefOf(x)),
            .Array => |x| switch (x.storage()) {
                .boxed => |vl| visitor.visit(vl),
                .scalars => |pb| visitor.visit(pb),
            },
            // Boxed payload: the BOX cell is the one owned edge (its own
            // trace/teardown reaches the entries).
            .Map => |x| visitor.visit(mapRefOf(x)),
            .Range => |x| visitor.visit(rangeRefOf(x)),
            .Iterator => |x| visitor.visit(x),
            .RangeIter => |x| visitor.visit(x),
            .SeqIter => |s| visitor.visit(s),
            .PropertyRef => |p| visitor.visit(p.name),
            .MatchGroup => |g| visitor.visit(matchGroupRefOf(g)),
            .Exception => |e| visitor.visit(exceptionRefOf(e)),
            .Pair => |p| visitor.visit(pairRefOf(p)),
            .Triple => |t| visitor.visit(tripleRefOf(t)),
            .MapEntry => |e| visitor.visit(mapEntryRefOf(e)),
            .Result => |r| visitor.visit(resultRefOf(r)),
            .BoundMethod => |m| visitor.visit(boundMethodRefOf(m)),
            else => {},
        }
    }

    const RetainVisitor = struct {
        inline fn visit(_: RetainVisitor, objref: anytype) void {
            _ = objref.clone();
        }
    };

    /// A non-owning leaf value: no cell to retain/release. Listed conservatively
    /// (only the unambiguous primitives) so a heap variant accidentally omitted
    /// still takes the full path — never the reverse, which would leak.
    pub inline fn isPrimitive(self: Value) bool {
        return switch (self) {
            .Unit, .CoroutineSuspended, .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Bool, .Char, .Null => true,
            else => false,
        };
    }

    /// Allocate the boxed `Map` payload (one control block, refcount 1) and
    /// return the `Value` holding it. The only way to construct a `.Map`.
    pub fn newMap(allocator: std.mem.Allocator, data: MapData) std.mem.Allocator.Error!Value {
        const ref = try MapRef.initOwned(allocator, data);
        return .{ .Map = &ref.cell.data };
    }

    /// Allocate the boxed `Range` payload; the only way to construct a
    /// `.Range`.
    pub fn newRange(allocator: std.mem.Allocator, data: RangeData) std.mem.Allocator.Error!Value {
        const ref = try RangeRef.initOwned(allocator, data);
        return .{ .Range = &ref.cell.data };
    }

    /// Allocate the iterator's single state cell; the only way to
    /// construct an `.Iterator`.
    pub fn newIterator(allocator: std.mem.Allocator, data: IterCursor) std.mem.Allocator.Error!Value {
        return .{ .Iterator = try ObjRef(IterCursor).init(allocator, data) };
    }

    /// Intern the (fqn, func) pair; the only way to construct an
    /// `.Intrinsic`. Immortal: allocation failure here is fatal.
    pub fn internIntrinsic(fqn: []const u8, func: StdlibFn) Value {
        intrinsic_intern_mutex.lock();
        defer intrinsic_intern_mutex.unlock();
        const a = std.heap.page_allocator;
        if (intrinsic_intern == null) intrinsic_intern = std.StringHashMap(*const IntrinsicData).init(a);
        const gop = intrinsic_intern.?.getOrPut(fqn) catch @panic("intrinsic intern");
        if (!gop.found_existing) {
            // Own the key bytes: the caller's slice is typically a module's
            // constant, which an in-process multi-program driver frees at
            // that program's teardown — a borrowed key then dangles and the
            // next program's probe compares against freed memory. The dup is
            // immortal, matching the entry's own lifetime.
            const owned = a.dupe(u8, fqn) catch @panic("intrinsic intern");
            gop.key_ptr.* = owned;
            const d = a.create(IntrinsicData) catch @panic("intrinsic intern");
            d.* = .{ .fqn = owned, .func = func };
            gop.value_ptr.* = d;
        }
        return .{ .Intrinsic = gop.value_ptr.* };
    }

    /// Allocate the boxed `MatchGroup` payload; the only way to construct
    /// a `.MatchGroup`.
    pub fn newMatchGroup(allocator: std.mem.Allocator, data: MatchGroupData) std.mem.Allocator.Error!Value {
        const ref = try MatchGroupRef.initOwned(allocator, data);
        return .{ .MatchGroup = &ref.cell.data };
    }

    /// Allocate the boxed `Result` payload; the only way to construct a
    /// `.Result`.
    pub fn newResult(allocator: std.mem.Allocator, data: ResultData) std.mem.Allocator.Error!Value {
        const ref = try ResultRef.initOwned(allocator, data);
        return .{ .Result = &ref.cell.data };
    }

    /// Allocate the boxed `Comparator` payload; the only way to construct
    /// a `.Comparator`.
    pub fn newComparator(allocator: std.mem.Allocator, data: ComparatorData) std.mem.Allocator.Error!Value {
        const ref = try ComparatorRef.initOwned(allocator, data);
        return .{ .Comparator = &ref.cell.data };
    }

    /// Allocate the boxed `Pair` payload; the only way to construct a
    /// `.Pair`.
    pub fn newPair(allocator: std.mem.Allocator, data: PairData) std.mem.Allocator.Error!Value {
        const ref = try PairRef.initOwned(allocator, data);
        return .{ .Pair = &ref.cell.data };
    }

    /// Allocate the boxed `Triple` payload; the only way to construct a
    /// `.Triple`.
    pub fn newTriple(allocator: std.mem.Allocator, data: TripleData) std.mem.Allocator.Error!Value {
        const ref = try TripleRef.initOwned(allocator, data);
        return .{ .Triple = &ref.cell.data };
    }

    /// Allocate the boxed `MapEntry` payload; the only way to construct a
    /// `.MapEntry`.
    pub fn newMapEntry(allocator: std.mem.Allocator, data: MapEntryData) std.mem.Allocator.Error!Value {
        const ref = try MapEntryRef.initOwned(allocator, data);
        return .{ .MapEntry = &ref.cell.data };
    }

    /// Allocate the boxed `BoundMethod` payload; the only way to construct
    /// a `.BoundMethod`.
    pub fn newBoundMethod(allocator: std.mem.Allocator, data: BoundMethodData) std.mem.Allocator.Error!Value {
        const ref = try BoundMethodRef.initOwned(allocator, data);
        return .{ .BoundMethod = &ref.cell.data };
    }

    /// Allocate the boxed `Set` payload; the only way to construct a `.Set`.
    pub fn newSet(allocator: std.mem.Allocator, data: SetData) std.mem.Allocator.Error!Value {
        const ref = try SetRef.initOwned(allocator, data);
        return .{ .Set = &ref.cell.data };
    }

    /// Allocate the boxed `List` payload; the only way to construct a `.List`.
    pub fn newList(allocator: std.mem.Allocator, data: ListData) std.mem.Allocator.Error!Value {
        const ref = try ListRef.initOwned(allocator, data);
        return .{ .List = &ref.cell.data };
    }

    /// Allocate the boxed `Exception` payload; the only way to construct a
    /// `.Exception`.
    pub fn newException(allocator: std.mem.Allocator, data: ExceptionData) std.mem.Allocator.Error!Value {
        const ref = try ExceptionRef.initOwned(allocator, data);
        return .{ .Exception = &ref.cell.data };
    }

    pub fn retain(self: Value) void {
        // Gated to match `release` (whose `ObjRef.deinit` is a no-op under the
        // arena fast path): under reclaim-off retains and releases are both
        // skipped, so the arena reclaims everything and production pays no
        // refcount traffic. Under reclaim-on both run and stay balanced.
        if (!objcell.reclaimEnabled()) return;
        if (self.isPrimitive()) return;
        self.forEachChildCell(RetainVisitor{});
    }

    const MarkVisitor = struct {
        m: *objcell.gc.Marker,
        inline fn visit(self: MarkVisitor, objref: anytype) void {
            self.m.shade(&objref.cell.hdr);
        }
    };

    /// GC tracer for a `Value`: shade each cell this value directly references
    /// (one level; the shaded cell's own `gc_trace` reaches the next level).
    /// Covers the same owning edges as `retain`, PLUS the non-owning
    /// view->source `backing` edges that retain/release intentionally skip: a
    /// live `MutableMap.keys`/`.values`/`.entries` view or a `Map.Entry` write-
    /// through must keep the source map's entries cell reachable, or the
    /// collector frees the map out from under a live view. It cannot leak the
    /// map: once the view is gone, nothing marks the backing.
    pub fn gcMark(self: Value, m: *objcell.gc.Marker) void {
        self.forEachChildCell(MarkVisitor{ .m = m });
        switch (self) {
            // Most declared classes are minted in the permanent generation,
            // but synthetic class literals and local class declarations can
            // be created after program start. A live KClass value must keep
            // either kind reachable. A bound inner-class constructor also
            // owns the outer instance it will pass to construction.
            .Class => |c| m.shade(&c.cell.hdr),
            // `List`/`Set` view `backing` is shaded by `forEachChildCell` above
            // (the `CollBacking` cell's own `gcTrace` reaches the source).
            // Keep the side-table's canonical capture store + receiver chain for
            // this closure alive (the dup'd `captures` ValueSlice is already
            // shaded by `forEachChildCell` above). A closure no live value marks
            // never reaches here, so its slot's captures go white and are swept.
            .IrClosure => |c| if (objcell.gc.markClosureHook) |f| f(c.id, m),
            else => {},
        }
    }

    /// Kotlin's `hashCode()` for the value shapes whose hash is a pure
    /// function of the value itself: scalars per kotlinc's boxed hash
    /// (Long folds halves, Bool is 1231/1237, unsigned types hash their
    /// signed storage, NaN canonicalizes) and String as the UTF-16
    /// 31-polynomial. Null when the shape's hash could involve dispatch
    /// (instances) — the one definition every host fast path and the
    /// stdlib hashing intrinsics must share, or trie/bucket placement
    /// diverges between served and interpreted operations.
    pub fn kotlinScalarHash(v: *const Value) ?i32 {
        const longHash = struct {
            fn f(x: i64) i32 {
                return @truncate(x ^ (x >> 32));
            }
        }.f;
        return switch (v.*) {
            .Null, .Unit => 0,
            .Int => |x| x,
            .Short => |x| @as(i32, x),
            .Byte => |x| @as(i32, x),
            .Char => |x| @as(i32, @intCast(x)),
            .Bool => |b| if (b) @as(i32, 1231) else @as(i32, 1237),
            .Long => |x| longHash(x),
            .UInt => |x| @bitCast(x),
            .UShort => |x| @as(i32, @as(i16, @bitCast(x))),
            .UByte => |x| @as(i32, @as(i8, @bitCast(x))),
            .ULong => |x| longHash(@bitCast(x)),
            .Float => |f| if (std.math.isNan(f)) @as(i32, @bitCast(@as(u32, 0x7fc0_0000))) else @as(i32, @bitCast(f)),
            .Double => |d| blk: {
                const bits: i64 = if (std.math.isNan(d)) @bitCast(@as(u64, 0x7ff8_0000_0000_0000)) else @bitCast(d);
                break :blk longHash(bits);
            },
            .String => |s| blk: {
                const g = s.borrow();
                defer g.deinit();
                var h: i32 = 0;
                const str = g.get().bytes;
                var i: usize = 0;
                while (i < str.len) {
                    const cp_len = std.unicode.utf8ByteSequenceLength(str[i]) catch {
                        h = h *% 31 +% @as(i32, str[i]);
                        i += 1;
                        continue;
                    };
                    const slice_end = @min(i + cp_len, str.len);
                    const cp = std.unicode.utf8Decode(str[i..slice_end]) catch {
                        h = h *% 31 +% @as(i32, str[i]);
                        i += 1;
                        continue;
                    };
                    if (cp <= 0xFFFF) {
                        h = h *% 31 +% @as(i32, @intCast(cp));
                    } else {
                        const cp_v = cp - 0x10000;
                        const high: u16 = @intCast(0xD800 + (cp_v >> 10));
                        const low: u16 = @intCast(0xDC00 + (cp_v & 0x3FF));
                        h = h *% 31 +% @as(i32, high);
                        h = h *% 31 +% @as(i32, low);
                    }
                    i = slice_end;
                }
                break :blk h;
            },
            else => null,
        };
    }

    /// Reference-counting decrement: drop one owning handle to
    /// this value graph. When a handle's strong count reaches zero its
    /// payload `deinit` recursively releases what it owns. The dual of
    /// `retain`; primitives, `Class`, and the not-yet-refcounted
    /// owning-`*Value` variants are no-ops.
    pub fn release(self: Value, allocator: std.mem.Allocator) void {
        // Gated identically to `retain`: under reclaim-off (the arena and the
        // tracing GC) both are skipped — the arena frees en masse and the GC
        // reclaims by reachability, so refcount teardown is not just wasted but
        // actively O(n) here (releasing a collection whose `strongCount` reads 1
        // walks every element). Only the reference-counting modes run it.
        if (!objcell.reclaimEnabled()) return;
        if (self.isPrimitive()) return;
        switch (self) {
            .String => |s| s.deinit(),
            .Instance => |i| i.deinit(),
            .Sequence => |s| s.deinit(),
            .Delegate => |d| d.deinit(),
            .Regex => |r| r.deinit(),
            .Match => |m| m.deinit(),
            .StringBuilder => |s| s.deinit(),
            .Cell => |c| c.deinit(),
            // `releaseSliceElems` already drops the slice handle (its tail
            // `slice.deinit()`); do not deinit it again.
            .IrClosure => |c| releaseSliceElems(c.captures, allocator),
            .Comparator => |c| comparatorRefOf(c).deinit(),
            .List => |x| {
                if (objcell.envSetOnce("KLIO_BOXDIE_TRACE") and x.backing != null and
                    listRefOf(x).cell.refcount.load(.monotonic) == 1)
                {
                    std.debug.print("\n[boxdie] view List box dying (backing={s})\n", .{@tagName(x.backing.?.data)});
                    trace_mod.dumpCurrent(.{});
                }
                listRefOf(x).deinit();
            },
            .Set => |x| setRefOf(x).deinit(),
            .Array => |x| switch (x.storage()) {
                .boxed => |vl| releaseValueList(vl, allocator),
                .scalars => |pb| pb.deinit(),
            },
            // Boxed payload: drop the box handle; its last-owner teardown
            // (`MapData.deinit`) releases the entries and their pairs.
            .Map => |x| mapRefOf(x).deinit(),
            .Range => |x| rangeRefOf(x).deinit(),
            .Iterator => |x| x.deinit(),
            .RangeIter => |x| x.deinit(),
            .SeqIter => |s| s.deinit(),
            .PropertyRef => |p| p.name.deinit(),
            .MatchGroup => |g| matchGroupRefOf(g).deinit(),
            .Exception => |e| exceptionRefOf(e).deinit(),
            .Pair => |p| pairRefOf(p).deinit(),
            .Triple => |t| tripleRefOf(t).deinit(),
            .MapEntry => |e| mapEntryRefOf(e).deinit(),
            .Result => |r| resultRefOf(r).deinit(),
            .BoundMethod => |m| boundMethodRefOf(m).deinit(),
            else => {},
        }
    }

    /// Drop one owning handle to a `ValueList` and, when it was the last,
    /// release each contained element first. Safe without locking the count:
    /// `strongCount() == 1` means this is the only handle, so no other thread
    /// can hold one to clone from concurrently.
    fn releaseValueList(items: ValueList, allocator: std.mem.Allocator) void {
        if (items.strongCount() == 1) {
            const g = items.borrow();
            for (g.get().items) |e| e.release(allocator);
            g.deinit();
        }
        items.deinit();
    }

    /// `releaseValueList` for an `ObjRef([]Value)` capture slice.
    fn releaseSliceElems(slice: ValueSlice, allocator: std.mem.Allocator) void {
        if (slice.strongCount() == 1) {
            const g = slice.borrow();
            for (g.get().*) |e| e.release(allocator);
            g.deinit();
        }
        slice.deinit();
    }

    /// `ObjRef(Value)` (capture `Cell`) payload teardown: a boxed value is
    /// released when its cell's strong count reaches zero.
    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        self.release(allocator);
    }

    pub fn isIntegral(self: Value) bool {
        return switch (self) {
            .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte => true,
            else => false,
        };
    }

    pub fn isUnsigned(self: Value) bool {
        return switch (self) {
            .UInt, .ULong, .UShort, .UByte => true,
            else => false,
        };
    }

    pub fn isFloating(self: Value) bool {
        return switch (self) {
            .Double, .Float => true,
            else => false,
        };
    }

    pub fn isNumeric(self: Value) bool {
        return self.isIntegral() or self.isFloating();
    }

    /// Widen any integral variant to `i64`. Floating returns null.
    pub fn asI64(self: Value) ?i64 {
        return switch (self) {
            .Int => |v| @as(i64, v),
            .Long => |v| v,
            .Short => |v| @as(i64, v),
            .Byte => |v| @as(i64, v),
            .UInt => |v| @as(i64, v),
            .ULong => |v| @bitCast(v),
            .UShort => |v| @as(i64, v),
            .UByte => |v| @as(i64, v),
            else => null,
        };
    }

    /// Widen any integral variant to `u64`. Negative signed values wrap.
    pub fn asU64(self: Value) ?u64 {
        return switch (self) {
            .Int => |v| @bitCast(@as(i64, v)),
            .Long => |v| @bitCast(v),
            .Short => |v| @bitCast(@as(i64, v)),
            .Byte => |v| @bitCast(@as(i64, v)),
            .UInt => |v| @as(u64, v),
            .ULong => |v| v,
            .UShort => |v| @as(u64, v),
            .UByte => |v| @as(u64, v),
            else => null,
        };
    }

    /// Widen any numeric variant to `f64`.
    pub fn asF64(self: Value) ?f64 {
        return switch (self) {
            .Int => |v| @floatFromInt(v),
            .Long => |v| @floatFromInt(v),
            .Short => |v| @floatFromInt(v),
            .Byte => |v| @floatFromInt(v),
            .UInt => |v| @floatFromInt(v),
            .ULong => |v| @floatFromInt(v),
            .UShort => |v| @floatFromInt(v),
            .UByte => |v| @floatFromInt(v),
            .Double => |v| v,
            .Float => |v| @as(f64, v),
            else => null,
        };
    }

    /// Widen any numeric variant to `f32`.
    pub fn asF32(self: Value) ?f32 {
        return switch (self) {
            .Int => |v| @floatFromInt(v),
            .Long => |v| @floatFromInt(v),
            .Short => |v| @floatFromInt(v),
            .Byte => |v| @floatFromInt(v),
            .UInt => |v| @floatFromInt(v),
            .ULong => |v| @floatFromInt(v),
            .UShort => |v| @floatFromInt(v),
            .UByte => |v| @floatFromInt(v),
            .Double => |v| @floatCast(v),
            .Float => |v| v,
            else => null,
        };
    }

    /// Construct an `Int`, wrapping to 32-bit width.
    pub fn newInt(v: i64) Value {
        return .{ .Int = @truncate(v) };
    }

    pub fn newLong(v: i64) Value {
        return .{ .Long = v };
    }

    pub fn newShort(v: i64) Value {
        return .{ .Short = @truncate(v) };
    }

    pub fn newByte(v: i64) Value {
        return .{ .Byte = @truncate(v) };
    }

    /// Promotion rank used to determine a mixed-numeric result type.
    pub fn numericRank(self: Value) ?NumericRank {
        return switch (self) {
            .Byte => .Byte,
            .Short => .Short,
            .Int => .Int,
            .Long => .Long,
            .UByte => .UByte,
            .UShort => .UShort,
            .UInt => .UInt,
            .ULong => .ULong,
            .Float => .Float,
            .Double => .Double,
            else => null,
        };
    }

    /// Convert this numeric value to the variant matching `rank`.
    pub fn promoteTo(self: Value, rank: NumericRank) ?Value {
        return switch (rank) {
            .Byte => if (self.asI64()) |v| Value{ .Byte = @truncate(v) } else null,
            .Short => if (self.asI64()) |v| Value{ .Short = @truncate(v) } else null,
            .Int => if (self.asI64()) |v| Value{ .Int = @truncate(v) } else null,
            .Long => if (self.asI64()) |v| Value{ .Long = v } else null,
            .UByte => if (self.asU64()) |v| Value{ .UByte = @truncate(v) } else null,
            .UShort => if (self.asU64()) |v| Value{ .UShort = @truncate(v) } else null,
            .UInt => if (self.asU64()) |v| Value{ .UInt = @truncate(v) } else null,
            .ULong => if (self.asU64()) |v| Value{ .ULong = v } else null,
            .Float => if (self.asF32()) |v| Value{ .Float = v } else null,
            .Double => if (self.asF64()) |v| Value{ .Double = v } else null,
        };
    }

    /// Truncate an `i64` arithmetic result back to the storage range of the
    /// requested integer rank. Long is returned as-is.
    pub fn wrapInteger(rank: NumericRank, v: i64) Value {
        return switch (rank) {
            .Byte => .{ .Byte = @truncate(v) },
            .Short => .{ .Short = @truncate(v) },
            .Int => .{ .Int = @truncate(v) },
            .Long => .{ .Long = v },
            .UByte => .{ .UByte = @truncate(@as(u64, @bitCast(v))) },
            .UShort => .{ .UShort = @truncate(@as(u64, @bitCast(v))) },
            .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(v))) },
            .ULong => .{ .ULong = @bitCast(v) },
            else => .{ .Long = v },
        };
    }

    /// Wrap a `u64` arithmetic result into the unsigned variant for `rank`.
    pub fn wrapUnsigned(rank: NumericRank, v: u64) Value {
        return switch (rank) {
            .UByte => .{ .UByte = @truncate(v) },
            .UShort => .{ .UShort = @truncate(v) },
            .UInt => .{ .UInt = @truncate(v) },
            .ULong => .{ .ULong = v },
            else => .{ .ULong = v },
        };
    }

    /// Fully-qualified Kotlin type name, used as the key prefix for member
    /// lookups in the stdlib registry.
    pub fn typeFqn(self: Value) []const u8 {
        return switch (self) {
            .Cell => "kotlin.Any",
            .Unit => "kotlin.Unit",
            .CoroutineSuspended => "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED",
            .Int => "kotlin.Int",
            .Long => "kotlin.Long",
            .Short => "kotlin.Short",
            .Byte => "kotlin.Byte",
            .UInt => "kotlin.UInt",
            .ULong => "kotlin.ULong",
            .UShort => "kotlin.UShort",
            .UByte => "kotlin.UByte",
            .Double => "kotlin.Double",
            .Float => "kotlin.Float",
            .Bool => "kotlin.Boolean",
            .String => "kotlin.String",
            .Char => "kotlin.Char",
            .Null => "kotlin.Nothing",
            .Range => |r| switch (r.kind) {
                .Int => if (r.step == 1 and !r.progression) "kotlin.ranges.IntRange" else "kotlin.ranges.IntProgression",
                .Long => if (r.step == 1 and !r.progression) "kotlin.ranges.LongRange" else "kotlin.ranges.LongProgression",
                .Char => if (r.step == 1 and !r.progression) "kotlin.ranges.CharRange" else "kotlin.ranges.CharProgression",
                .UInt => if (r.step == 1 and !r.progression) "kotlin.ranges.UIntRange" else "kotlin.ranges.UIntProgression",
                .ULong => if (r.step == 1 and !r.progression) "kotlin.ranges.ULongRange" else "kotlin.ranges.ULongProgression",
            },
            .IrClosure, .Intrinsic, .BoundMethod => "kotlin.Function",
            .Exception => "kotlin.Throwable",
            .List => |l| if (l.mutable) "kotlin.collections.MutableList" else "kotlin.collections.List",
            .Array => |a| if (a.prim) |k| k.typeFqn() else "kotlin.Array",
            .Set => |s| if (s.mutable) "kotlin.collections.MutableSet" else "kotlin.collections.Set",
            .Map => |m| if (m.mutable) "kotlin.collections.MutableMap" else "kotlin.collections.Map",
            .Pair => "kotlin.Pair",
            .Triple => "kotlin.Triple",
            .MapEntry => "kotlin.collections.Map.Entry",
            .Result => "kotlin.Result",
            .Comparator => "kotlin.Comparator",
            .Sequence => "kotlin.sequences.Sequence",
            .SeqIter => "kotlin.collections.Iterator",
            .Iterator => |it| if (blk: {
                const g = it.borrow();
                defer g.deinit();
                break :blk g.get().prim;
            }) |p| switch (p) {
                .Int => "kotlin.collections.IntIterator",
                .Long => "kotlin.collections.LongIterator",
                .Double => "kotlin.collections.DoubleIterator",
                .Float => "kotlin.collections.FloatIterator",
                .Short => "kotlin.collections.ShortIterator",
                .Byte => "kotlin.collections.ByteIterator",
                .Boolean => "kotlin.collections.BooleanIterator",
                .Char => "kotlin.collections.CharIterator",
                .UInt => "kotlin.collections.UIntIterator",
                .ULong => "kotlin.collections.ULongIterator",
                .UShort => "kotlin.collections.UShortIterator",
                .UByte => "kotlin.collections.UByteIterator",
            } else "kotlin.collections.Iterator",
            .RangeIter => |ri| switch (blk: {
                const g = ri.borrow();
                defer g.deinit();
                break :blk g.get().kind;
            }) {
                .Int => "kotlin.collections.IntIterator",
                .Long => "kotlin.collections.LongIterator",
                .Char => "kotlin.collections.CharIterator",
                .UInt => "kotlin.collections.UIntIterator",
                .ULong => "kotlin.collections.ULongIterator",
            },
            .Class => "kotlin.reflect.KClass",
            .Instance => "<instance>",
            .Delegate => "<delegate>",
            .PropertyRef => "kotlin.reflect.KProperty",
            .Regex => "kotlin.text.Regex",
            .Match => "kotlin.text.MatchResult",
            .MatchGroup => "kotlin.text.MatchGroup",
            .StringBuilder => "kotlin.text.StringBuilder",
        };
    }

    /// Render a `Double` the way Kotlin's `Double.toString` does. Caller
    /// owns the returned string.
    pub fn renderDouble(allocator: std.mem.Allocator, d: f64) ![]u8 {
        return float_fmt.kotlinDoubleToString(allocator, d);
    }

    /// Live exception fqn — for catch-clause matching by type name.
    pub fn exceptionFqn(self: Value) ?[]const u8 {
        return switch (self) {
            .Exception => |e| {
                const g = e.fqn.borrow();
                defer g.deinit();
                return g.get().bytes;
            },
            else => null,
        };
    }

    /// Whether a builtin `Throwable` whose fully-qualified name is `fqn` is an
    /// instance of the type named `name` (simple or fully-qualified) per the
    /// `kotlin.*` exception hierarchy. The single source of truth shared by
    /// `isRuntimeType` (the `is`/`as` and `KClass.isInstance` paths) and the
    /// VM's `instanceOf`.
    pub fn builtinThrowableIsA(fqn: []const u8, name: []const u8) bool {
        const tail = lastSegment(fqn);
        if (std.mem.eql(u8, tail, name)) return true;
        if (matchesAny(name, &.{ "Throwable", "Any" })) return true;
        if (std.mem.eql(u8, fqn, name)) return true;
        // `Error`-side throwables (AssertionError, OutOfMemoryError, ...) are
        // not `Exception`s; `Exception`-side are not `Error`s.
        if (std.mem.eql(u8, name, "Exception")) return !throwableIsErrorSide(tail);
        if (std.mem.eql(u8, name, "Error")) return throwableIsErrorSide(tail);
        const runtime_exc = [_][]const u8{
            "IllegalArgumentException",        "IllegalStateException",
            "IndexOutOfBoundsException",       "ArrayIndexOutOfBoundsException",
            "StringIndexOutOfBoundsException", "NullPointerException",
            "ArithmeticException",             "ClassCastException",
            "NoSuchElementException",          "NumberFormatException",
            "UnsupportedOperationException",   "UninitializedPropertyAccessException",
            "ConcurrentModificationException", "NoWhenBranchMatchedException",
            "NegativeArraySizeException",      "CancellationException",
        };
        if (std.mem.eql(u8, name, "RuntimeException") and matchesAny(tail, &runtime_exc)) return true;
        if (std.mem.eql(u8, name, "IndexOutOfBoundsException") and
            matchesAny(tail, &.{ "ArrayIndexOutOfBoundsException", "StringIndexOutOfBoundsException" })) return true;
        // CancellationException : IllegalStateException : RuntimeException.
        if (std.mem.eql(u8, name, "IllegalStateException") and std.mem.eql(u8, tail, "CancellationException")) return true;
        // `NumberFormatException : IllegalArgumentException` — a
        // `catch (e: IllegalArgumentException)` around `toInt()`/`toDouble()`
        // (kotlinx's `parseString`) must take the host-thrown failure.
        if (std.mem.eql(u8, name, "IllegalArgumentException") and std.mem.eql(u8, tail, "NumberFormatException")) return true;
        return false;
    }

    /// Runtime `is` check against a simple type name.
    pub fn isRuntimeType(self: Value, name: []const u8) bool {
        return switch (self) {
            .Cell => |c| blk: {
                const g = c.borrow();
                defer g.deinit();
                break :blk g.get().isRuntimeType(name);
            },
            .CoroutineSuspended => false,
            .Int => matchesAny(name, &.{ "Int", "Number", "Any", "Comparable" }),
            .Long => matchesAny(name, &.{ "Long", "Number", "Any", "Comparable" }),
            .Short => matchesAny(name, &.{ "Short", "Number", "Any", "Comparable" }),
            .Byte => matchesAny(name, &.{ "Byte", "Number", "Any", "Comparable" }),
            .UInt => matchesAny(name, &.{ "UInt", "Number", "Any", "Comparable" }),
            .ULong => matchesAny(name, &.{ "ULong", "Number", "Any", "Comparable" }),
            .UShort => matchesAny(name, &.{ "UShort", "Number", "Any", "Comparable" }),
            .UByte => matchesAny(name, &.{ "UByte", "Number", "Any", "Comparable" }),
            .Double => matchesAny(name, &.{ "Double", "Number", "Any", "Comparable" }),
            .Float => matchesAny(name, &.{ "Float", "Number", "Any", "Comparable" }),
            .Bool => matchesAny(name, &.{ "Boolean", "Any", "Comparable" }),
            .String => matchesAny(name, &.{ "String", "CharSequence", "Any", "Comparable" }),
            .Char => matchesAny(name, &.{ "Char", "Any", "Comparable" }),
            .Unit => matchesAny(name, &.{ "Unit", "Any" }),
            .Null => false,
            // A `..` range (step 1) is an XRange and a ClosedRange; a `downTo`
            // or `step`ped progression (step != 1) is only an XProgression.
            .Range => |r| switch (r.kind) {
                .Int => matchesAny(name, &.{ "IntProgression", "Iterable", "Any" }) or
                    (r.step == 1 and !r.progression and matchesAny(name, &.{ "IntRange", "ClosedRange" })),
                .Long => matchesAny(name, &.{ "LongProgression", "Iterable", "Any" }) or
                    (r.step == 1 and !r.progression and matchesAny(name, &.{ "LongRange", "ClosedRange" })),
                .Char => matchesAny(name, &.{ "CharProgression", "Iterable", "Any" }) or
                    (r.step == 1 and !r.progression and matchesAny(name, &.{ "CharRange", "ClosedRange" })),
                .UInt => matchesAny(name, &.{ "UIntProgression", "Iterable", "Any" }) or
                    (r.step == 1 and !r.progression and matchesAny(name, &.{ "UIntRange", "ClosedRange" })),
                .ULong => matchesAny(name, &.{ "ULongProgression", "Iterable", "Any" }) or
                    (r.step == 1 and !r.progression and matchesAny(name, &.{ "ULongRange", "ClosedRange" })),
            },
            .List => |l| blk: {
                if (std.mem.eql(u8, name, "EnumEntries")) break :blk l.enum_entries;
                if (l.mutable) {
                    break :blk matchesAny(name, &.{ "MutableList", "List", "Collection", "MutableCollection", "Iterable", "MutableIterable", "RandomAccess", "Any" });
                } else {
                    break :blk matchesAny(name, &.{ "List", "Collection", "Iterable", "RandomAccess", "Any" });
                }
            },
            .Set => |s| if (s.mutable)
                matchesAny(name, &.{ "MutableSet", "Set", "Collection", "Iterable", "Any" })
            else
                matchesAny(name, &.{ "Set", "Collection", "Iterable", "Any" }),
            .Map => |m| if (m.mutable)
                matchesAny(name, &.{ "MutableMap", "Map", "Any" })
            else
                matchesAny(name, &.{ "Map", "Any" }),
            .Pair => matchesAny(name, &.{ "Pair", "Any" }),
            .Triple => matchesAny(name, &.{ "Triple", "Any" }),
            .MapEntry => matchesAny(name, &.{ "Entry", "MapEntry", "Map.Entry", "Any" }),
            .Result => matchesAny(name, &.{ "Result", "Any" }),
            .Sequence => matchesAny(name, &.{ "Sequence", "Any" }),
            .SeqIter => matchesAny(name, &.{ "Iterator", "Any" }),
            .Iterator => |it| blk: {
                if (matchesAny(name, &.{ "Iterator", "ListIterator", "Any" })) break :blk true;
                const snap = sblk: {
                    const g = it.borrow();
                    defer g.deinit();
                    break :sblk .{ .mutable = g.get().mutable, .prim = g.get().prim };
                };
                // Mutable-backed iterators satisfy the mutable interfaces.
                if (snap.mutable and matchesAny(name, &.{ "MutableIterator", "MutableListIterator" })) break :blk true;
                if (snap.prim) |p| {
                    break :blk simpleNameMatchesIterator(name, p.simpleName());
                }
                break :blk false;
            },
            .RangeIter => |ri| blk: {
                if (matchesAny(name, &.{ "Iterator", "Any" })) break :blk true;
                const rkind = kblk: {
                    const g = ri.borrow();
                    defer g.deinit();
                    break :kblk g.get().kind;
                };
                break :blk switch (rkind) {
                    .Int => std.mem.eql(u8, name, "IntIterator"),
                    .Long => std.mem.eql(u8, name, "LongIterator"),
                    .Char => std.mem.eql(u8, name, "CharIterator"),
                    .UInt => std.mem.eql(u8, name, "UIntIterator"),
                    .ULong => std.mem.eql(u8, name, "ULongIterator"),
                };
            },
            .Comparator => matchesAny(name, &.{ "Comparator", "Any" }),
            .IrClosure, .Intrinsic, .BoundMethod => isFunctionType(self, name),
            .Exception => |e| blk: {
                const g = e.fqn.borrow();
                defer g.deinit();
                break :blk builtinThrowableIsA(g.get().bytes, name);
            },
            .Class => matchesAny(name, &.{ "KClass", "kotlin.reflect.KClass", "KClassifier", "kotlin.reflect.KClassifier", "Any" }),
            .Instance => |i| blk: {
                if (std.mem.eql(u8, name, "Any")) break :blk true;
                const g = i.borrow();
                defer g.deinit();
                const inst = g.get();
                const cg = inst.class.borrow();
                defer cg.deinit();
                // The subtype walk needs an allocator for its frontier; use the
                // shared scratch buffer to avoid threading one through the
                // predicate.
                var scratch: SubtypeScratch = .{};
                const a = scratch.acquire();
                defer scratch.release();
                if (cg.get().isSubtypeOf(a, name)) break :blk true;
                if (lastDotSegment(name)) |simple| {
                    scratch.reset();
                    if (cg.get().isSubtypeOf(a, simple)) break :blk true;
                }
                break :blk false;
            },
            .Delegate => matchesAny(name, &.{"Any"}),
            .PropertyRef => matchesAny(name, &.{ "KProperty", "KProperty0", "KProperty1", "KCallable", "kotlin.reflect.KProperty", "kotlin.reflect.KProperty0", "kotlin.reflect.KProperty1", "kotlin.reflect.KCallable", "Any" }),
            .Array => |a| blk: {
                if (std.mem.eql(u8, name, "Any")) break :blk true;
                break :blk if (a.prim) |p| switch (p) {
                    .Int => std.mem.eql(u8, name, "IntArray"),
                    .Long => std.mem.eql(u8, name, "LongArray"),
                    .Double => std.mem.eql(u8, name, "DoubleArray"),
                    .Float => std.mem.eql(u8, name, "FloatArray"),
                    .Short => std.mem.eql(u8, name, "ShortArray"),
                    .Byte => std.mem.eql(u8, name, "ByteArray"),
                    .Boolean => std.mem.eql(u8, name, "BooleanArray"),
                    .Char => std.mem.eql(u8, name, "CharArray"),
                    .UInt => std.mem.eql(u8, name, "UIntArray"),
                    .ULong => std.mem.eql(u8, name, "ULongArray"),
                    .UShort => std.mem.eql(u8, name, "UShortArray"),
                    .UByte => std.mem.eql(u8, name, "UByteArray"),
                } else std.mem.eql(u8, name, "Array");
            },
            .Regex => matchesAny(name, &.{ "Regex", "Any" }),
            .Match => matchesAny(name, &.{ "MatchResult", "Any" }),
            .MatchGroup => matchesAny(name, &.{ "MatchGroup", "Any" }),
            .StringBuilder => matchesAny(name, &.{ "StringBuilder", "Appendable", "CharSequence", "Any" }),
        };
    }

    /// Whether a range/progression value covers no elements (Kotlin
    /// `isEmpty()`): a positive step needs `start <= end`, a negative one
    /// `start >= end`.
    fn rangeIsEmptyVal(r: anytype) bool {
        return !r.kind.inBounds(r.start, r.end, r.step);
    }

    /// Whether a user `Instance` implements `kotlin.collections.Map.Entry`,
    /// so it participates in the `Map.Entry` equality contract (compare by
    /// key and value regardless of concrete type).
    fn instanceImplementsMapEntry(inst: ObjRef(InstanceData)) bool {
        const cls = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().class;
        };
        // The answer is a property of the class, not the instance, and the
        // supertype graph is fixed once the class is registered. Every `==`
        // between instances asks this question, so memoize it per class.
        const key = cls.identity();
        const slot = &map_entry_memo[(key >> 4) % map_entry_memo.len];
        if (slot.key == key) return slot.val;
        const cg = cls.borrow();
        defer cg.deinit();
        var scratch: SubtypeScratch = .{};
        const a = scratch.acquire();
        defer scratch.release();
        const candidates = [_][]const u8{ "Entry", "MutableEntry", "Map.Entry", "MutableMap.MutableEntry", "kotlin.collections.Map.Entry" };
        var found = false;
        for (candidates) |name| {
            scratch.reset();
            if (cg.get().isSubtypeOf(a, name)) {
                found = true;
                break;
            }
        }
        slot.* = .{ .key = key, .val = found };
        return found;
    }

    /// The `key`/`value` pair of any value that satisfies the `Map.Entry`
    /// contract: a builtin `MapEntry` box, or a user `Instance` implementing
    /// `Map.Entry` (its `key`/`value` are read as stored fields). Returns
    /// `null` for anything else. The returned values are copies of the
    /// component slots; the underlying handles stay owned by the source value,
    /// which the caller keeps alive across the comparison.
    fn mapEntryParts(v: *const Value) ?struct { key: Value, value: Value } {
        switch (v.*) {
            .MapEntry => |e| return .{ .key = e.key.asPtr().*, .value = e.value.asPtr().* },
            .Instance => |inst| {
                if (!instanceImplementsMapEntry(inst)) return null;
                const g = inst.borrow();
                defer g.deinit();
                // `key`/`value` come from the primary-ctor `override val`s, so
                // they are stored fields read directly.
                const k = g.get().get("key") orelse return null;
                const val = g.get().get("value") orelse return null;
                return .{ .key = k, .value = val };
            },
            else => return null,
        }
    }

    /// `Map.Entry` equality contract: two entries are equal iff their keys and
    /// values are equal, regardless of concrete type (builtin `MapEntry` vs a
    /// user `Instance` implementing `Map.Entry`, in either direction). Returns
    /// `null` when the contract does not apply (so the normal equality paths
    /// handle the operands), `true`/`false` once it does.
    pub fn mapEntryContractEq(a: *const Value, b: *const Value) ?bool {
        const ap = mapEntryParts(a) orelse return null;
        const bp = mapEntryParts(b) orelse return null;
        return structuralEqBoxed(&ap.key, &bp.key) and structuralEqBoxed(&ap.value, &bp.value);
    }

    /// Equality with boxed `Number` semantics (each boxed type only matches
    /// its own type; collections compare elements boxed too).
    pub fn structuralEqBoxed(a: *const Value, b: *const Value) bool {
        // A builtin `MapEntry` and a user `Map.Entry` instance compare by key
        // and value (the `Map.Entry` contract), so `map.entries.contains(e)`
        // and `entry == e` work across concrete types. Only fires when at
        // least one side is a builtin `MapEntry`; two plain instances keep
        // their own `equals`/structural semantics.
        if (a.* == .MapEntry or b.* == .MapEntry) {
            if (mapEntryContractEq(a, b)) |eq| return eq;
        }
        switch (a.*) {
            // `Double.equals` collapses every NaN to one canonical bit pattern
            // (`toBits`), so any two NaNs compare equal while `0.0 != -0.0`.
            .Double => |x| if (b.* == .Double) return (std.math.isNan(x) and std.math.isNan(b.Double)) or @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.Double)),
            .Float => |x| if (b.* == .Float) return (std.math.isNan(x) and std.math.isNan(b.Float)) or @as(u32, @bitCast(x)) == @as(u32, @bitCast(b.Float)),
            .Int => |x| if (b.* == .Int) return x == b.Int,
            .Long => |x| if (b.* == .Long) return x == b.Long,
            .Short => |x| if (b.* == .Short) return x == b.Short,
            .Byte => |x| if (b.* == .Byte) return x == b.Byte,
            .UInt => |x| if (b.* == .UInt) return x == b.UInt,
            .ULong => |x| if (b.* == .ULong) return x == b.ULong,
            .UShort => |x| if (b.* == .UShort) return x == b.UShort,
            .UByte => |x| if (b.* == .UByte) return x == b.UByte,
            .List => |x| if (b.* == .List) {
                a.refreshArrayView();
                b.refreshArrayView();
                a.refreshSublistView();
                b.refreshSublistView();
                return listEqBoxed(x.items, b.List.items);
            },
            .Set => |x| if (b.* == .Set) return setEqBoxed(x.items, b.Set.items),
            .Map => |x| if (b.* == .Map) return mapEqBoxed(x.entries, b.Map.entries),
            .Pair => |x| if (b.* == .Pair)
                return structuralEqBoxed(x.first.asPtr(), b.Pair.first.asPtr()) and structuralEqBoxed(x.second.asPtr(), b.Pair.second.asPtr()),
            .Triple => |x| if (b.* == .Triple)
                return structuralEqBoxed(x.first.asPtr(), b.Triple.first.asPtr()) and
                    structuralEqBoxed(x.second.asPtr(), b.Triple.second.asPtr()) and
                    structuralEqBoxed(x.third.asPtr(), b.Triple.third.asPtr()),
            .MapEntry => |x| if (b.* == .MapEntry)
                return structuralEqBoxed(x.key.asPtr(), b.MapEntry.key.asPtr()) and structuralEqBoxed(x.value.asPtr(), b.MapEntry.value.asPtr()),
            // `Throwable.equals` is reference identity (Kotlin does not override
            // it), so `==`/`assertEquals` on exceptions is `===`.
            .Exception => if (b.* == .Exception) return referenceEq(a, b),
            else => {},
        }
        // Any other mix of two numerics is a cross-type boxed comparison.
        if (a.isNumeric() and b.isNumeric()) return false;
        return structuralEq(a, b);
    }

    /// The callable wrapped by a `fun interface` SAM wrapper, else null.
    pub fn samTargetOf(v: *const Value) ?Value {
        if (v.* != .Instance) return null;
        const g = v.Instance.borrow();
        defer g.deinit();
        return g.get().get("__sam_target__");
    }

    pub fn structuralEq(a: *const Value, b: *const Value) bool {
        // A `fun interface` SAM wrapper equals the callable it wraps.
        // Conversion happens at klio's call boundaries and is
        // timing-dependent (a mask-cache eviction can wrap one
        // composition's argument and not another's), so equality must see
        // through the wrapper exactly as Kotlin sees one converted value —
        // compose's `remember { compute }` memo comparison depends on it.
        if (samTargetOf(a)) |ta| {
            if (!(b.* == .Instance and ObjRef(InstanceData).ptrEq(a.Instance, b.Instance))) {
                return structuralEq(&ta, b);
            }
        } else if (samTargetOf(b)) |tb| {
            return structuralEq(a, &tb);
        }
        if (a.isNumeric() and b.isNumeric()) {
            return switch (a.*) {
                .Int => |x| b.* == .Int and x == b.Int,
                .Long => |x| b.* == .Long and x == b.Long,
                .Short => |x| b.* == .Short and x == b.Short,
                .Byte => |x| b.* == .Byte and x == b.Byte,
                .UInt => |x| b.* == .UInt and x == b.UInt,
                .ULong => |x| b.* == .ULong and x == b.ULong,
                .UShort => |x| b.* == .UShort and x == b.UShort,
                .UByte => |x| b.* == .UByte and x == b.UByte,
                .Double => |x| b.* == .Double and x == b.Double,
                .Float => |x| b.* == .Float and x == b.Float,
                else => false,
            };
        }
        return switch (a.*) {
            .Bool => |x| b.* == .Bool and x == b.Bool,
            .String => |x| b.* == .String and strEq(x, b.String),
            .Char => |x| b.* == .Char and x == b.Char,
            .Null => b.* == .Null,
            .Unit => b.* == .Unit,
            .CoroutineSuspended => b.* == .CoroutineSuspended,
            .Range => |x| b.* == .Range and x.kind == b.Range.kind and
                ((rangeIsEmptyVal(x) and rangeIsEmptyVal(b.Range)) or
                    (x.start == b.Range.start and x.end == b.Range.end and x.step == b.Range.step)),
            .List => |x| b.* == .List and blk: {
                a.refreshArrayView();
                b.refreshArrayView();
                a.refreshSublistView();
                b.refreshSublistView();
                break :blk listEqBoxed(x.items, b.List.items);
            },
            .Set => |x| b.* == .Set and setEqBoxed(x.items, b.Set.items),
            .Map => |x| b.* == .Map and mapEqBoxed(x.entries, b.Map.entries),
            .Pair => |x| b.* == .Pair and
                structuralEqBoxed(x.first.asPtr(), b.Pair.first.asPtr()) and structuralEqBoxed(x.second.asPtr(), b.Pair.second.asPtr()),
            .Triple => |x| b.* == .Triple and
                structuralEqBoxed(x.first.asPtr(), b.Triple.first.asPtr()) and
                structuralEqBoxed(x.second.asPtr(), b.Triple.second.asPtr()) and
                structuralEqBoxed(x.third.asPtr(), b.Triple.third.asPtr()),
            .MapEntry => |x| b.* == .MapEntry and
                structuralEqBoxed(x.key.asPtr(), b.MapEntry.key.asPtr()) and structuralEqBoxed(x.value.asPtr(), b.MapEntry.value.asPtr()),
            .Result => |x| b.* == .Result and x.ok == b.Result.ok and structuralEq(x.payload.asPtr(), b.Result.payload.asPtr()),
            .Class => |x| b.* == .Class and classFqnEq(x, b.Class),
            .IrClosure => |x| b.* == .IrClosure and blk: {
                // The same materialised closure object.
                if (x.id == b.IrClosure.id and ValueSlice.ptrEq(x.captures, b.IrClosure.captures)) break :blk true;
                // A non-capturing lambda literal is a singleton in Kotlin: two
                // evaluations of the same literal (which klio gives distinct
                // closure ids) are the same value. Compare by the literal's
                // (module, body-function) identity when neither captures.
                if (objcell.gc.closureSingletonHook) |h| {
                    const sa = h(x.id);
                    if (sa != 0 and sa == h(b.IrClosure.id)) break :blk true;
                }
                break :blk false;
            },
            .Comparator => |x| b.* == .Comparator and
                ObjRef([]ComparatorStep).ptrEq(x.steps, b.Comparator.steps) and
                x.descending == b.Comparator.descending,
            .BoundMethod => |x| b.* == .BoundMethod and std.mem.eql(u8, x.fqn, b.BoundMethod.fqn) and structuralEq(x.receiver.asPtr(), b.BoundMethod.receiver.asPtr()),
            .Instance => |x| b.* == .Instance and instanceEq(x, b.Instance),
            // StringBuilder declares no equals override: identity, as on
            // the JVM — the same builder equals itself, never a sibling
            // with equal contents.
            .StringBuilder => |x| b.* == .StringBuilder and x.identity() == b.StringBuilder.identity(),
            .Sequence => |x| b.* == .Sequence and ObjRef(SequenceData).ptrEq(x, b.Sequence),
            else => false,
        };
    }

    /// Kotlin referential identity (`===` / `!==`).
    pub fn referenceEq(a: *const Value, b: *const Value) bool {
        switch (a.*) {
            .Instance => |x| return b.* == .Instance and ObjRef(InstanceData).ptrEq(x, b.Instance),
            .Exception => |x| {
                if (b.* != .Exception) return false;
                // A throwable built through a constructor carries a fresh
                // identity, so `===` is true only between the same object.
                // Exceptions built outside that path (identity 0) fall back to
                // structural equality so test-only throwables still compare.
                if (x.identity != 0 and x.identity == b.Exception.identity) return true;
                if (x.identity != 0 or b.Exception.identity != 0) return false;
                return structuralEq(a, b);
            },
            .Cell => |x| if (b.* == .Cell) return ObjRef(Value).ptrEq(x, b.Cell),
            .List => |x| if (b.* == .List) return ValueList.ptrEq(x.items, b.List.items),
            .Set => |x| if (b.* == .Set) return ValueList.ptrEq(x.items, b.Set.items),
            .Map => |x| if (b.* == .Map) return MapEntries.ptrEq(x.entries, b.Map.entries),
            .Array => |x| if (b.* == .Array) return x.identity() == b.Array.identity(),
            .StringBuilder => |x| if (b.* == .StringBuilder) return x.identity() == b.StringBuilder.identity(),
            .Sequence => |x| if (b.* == .Sequence) return ObjRef(SequenceData).ptrEq(x, b.Sequence),
            .Intrinsic => |x| {
                if (b.* == .Intrinsic) return std.mem.eql(u8, x.fqn, b.Intrinsic.fqn);
                if (b.* == .CoroutineSuspended) return std.mem.eql(u8, x.fqn, "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED");
            },
            .CoroutineSuspended => if (b.* == .Intrinsic) return std.mem.eql(u8, b.Intrinsic.fqn, "kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED"),
            else => {},
        }
        if (a.* == .Instance or b.* == .Instance) return false;
        return structuralEq(a, b);
    }

    /// Address-stable identity for use as a `synchronized` monitor key.
    pub fn lockIdentity(self: Value) ?usize {
        return switch (self) {
            .Instance => |i| i.identity(),
            .List => |l| l.items.identity(),
            .Array => |a| a.identity(),
            .Set => |s| s.items.identity(),
            .Map => |m| m.entries.identity(),
            .Cell => |c| c.identity(),
            .StringBuilder => |s| s.identity(),
            else => null,
        };
    }

    /// Render this value the way Kotlin's `toString` / string templates do,
    /// writing into `writer`.
    pub fn writeTo(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .Cell => |c| {
                const g = c.borrow();
                defer g.deinit();
                try g.get().writeTo(writer);
            },
            .Unit => try writer.writeAll("kotlin.Unit"),
            .CoroutineSuspended => try writer.writeAll("COROUTINE_SUSPENDED"),
            .Int => |v| try writer.print("{d}", .{v}),
            .Long => |v| try writer.print("{d}", .{v}),
            .Short => |v| try writer.print("{d}", .{v}),
            .Byte => |v| try writer.print("{d}", .{v}),
            .UInt => |v| try writer.print("{d}", .{v}),
            .ULong => |v| try writer.print("{d}", .{v}),
            .UShort => |v| try writer.print("{d}", .{v}),
            .UByte => |v| try writer.print("{d}", .{v}),
            .Double => |v| try writeFloat64(writer, v),
            .Float => |v| try writeFloat32(writer, v),
            .Bool => |v| try writer.writeAll(if (v) "true" else "false"),
            .String => |s| {
                const g = s.borrow();
                defer g.deinit();
                try writer.writeAll(g.get().bytes);
            },
            .Char => |v| try writeChar(writer, v),
            .Null => try writer.writeAll("null"),
            .Range => |r| {
                if (r.step == 1 and !r.progression) {
                    try writer.print("{d}..{d}", .{ r.start, r.end });
                } else if (r.step > 0) {
                    try writer.print("{d}..{d} step {d}", .{ r.start, r.end, r.step });
                } else {
                    try writer.print("{d} downTo {d} step {d}", .{ r.start, r.end, -r.step });
                }
            },
            .IrClosure => |c| try writer.print("{{ir-closure#{d}}}", .{c.id}),
            .Intrinsic => |i| try writer.print("fun {s}(...)", .{i.fqn}),
            .BoundMethod => |m| try writer.print("fun {s}(...)", .{m.fqn}),
            .Exception => |e| {
                const fg = e.fqn.borrow();
                defer fg.deinit();
                if (e.message.get()) |m| {
                    const mg = m.borrow();
                    defer mg.deinit();
                    try writer.print("{s}: {s}", .{ fg.get().bytes, mg.get().bytes });
                } else {
                    try writer.writeAll(fg.get().bytes);
                }
            },
            .List => |coll| {
                self.refreshArrayView();
                self.refreshSublistView();
                try writeElements(writer, coll.items, &self);
            },
            .Set => |coll| try writeElements(writer, coll.items, &self),
            .Array => |a| {
                const tag = if (a.prim) |k| k.typeFqn() else "kotlin.Array";
                try writer.print("{s}@<…>", .{tag});
            },
            .Map => |m| {
                const g = m.entries.borrow();
                defer g.deinit();
                try writer.writeByte('{');
                for (g.get().pairs.items, 0..) |e, i| {
                    if (i > 0) try writer.writeAll(", ");
                    if (Value.referenceEq(&e.key, &self)) {
                        try writer.writeAll("(this Map)");
                    } else {
                        try e.key.writeTo(writer);
                    }
                    try writer.writeByte('=');
                    if (Value.referenceEq(&e.value, &self)) {
                        try writer.writeAll("(this Map)");
                    } else {
                        try e.value.writeTo(writer);
                    }
                }
                try writer.writeByte('}');
            },
            .Pair => |p| {
                try writer.writeByte('(');
                try p.first.asPtr().writeTo(writer);
                try writer.writeAll(", ");
                try p.second.asPtr().writeTo(writer);
                try writer.writeByte(')');
            },
            .Triple => |t| {
                try writer.writeByte('(');
                try t.first.asPtr().writeTo(writer);
                try writer.writeAll(", ");
                try t.second.asPtr().writeTo(writer);
                try writer.writeAll(", ");
                try t.third.asPtr().writeTo(writer);
                try writer.writeByte(')');
            },
            .MapEntry => |e| {
                try e.key.asPtr().writeTo(writer);
                try writer.writeByte('=');
                try e.value.asPtr().writeTo(writer);
            },
            .Result => |r| {
                try writer.writeAll(if (r.ok) "Success(" else "Failure(");
                try r.payload.asPtr().writeTo(writer);
                try writer.writeByte(')');
            },
            .Comparator => try writer.writeAll("Comparator"),
            .Sequence => try writer.writeAll("kotlin.sequences.Sequence"),
            .SeqIter => try writer.writeAll("kotlin.collections.Iterator"),
            .Iterator => |it| if (blk: {
                const g = it.borrow();
                defer g.deinit();
                break :blk g.get().prim;
            }) |p|
                try writer.print("{s}Iterator", .{p.simpleName()})
            else
                try writer.writeAll("kotlin.collections.Iterator"),
            .RangeIter => |ri| switch (blk: {
                const g = ri.borrow();
                defer g.deinit();
                break :blk g.get().kind;
            }) {
                .Int => try writer.writeAll("kotlin.ranges.IntProgressionIterator"),
                .Long => try writer.writeAll("kotlin.ranges.LongProgressionIterator"),
                .Char => try writer.writeAll("kotlin.ranges.CharProgressionIterator"),
                .UInt => try writer.writeAll("kotlin.ranges.UIntProgressionIterator"),
                .ULong => try writer.writeAll("kotlin.ranges.ULongProgressionIterator"),
            },
            .Class => |c| {
                const g = c.borrow();
                defer g.deinit();
                // `KClass.toString()` renders the QUALIFIED name (`class
                // kotlin.Any`), as Kotlin's common/native surface does — a
                // packageless class's fqn is its simple name, unchanged.
                try writer.print("class {s}", .{g.get().fqn});
            },
            .Delegate => try writer.writeAll("<delegate>"),
            .PropertyRef => |p| {
                const g = p.name.borrow();
                defer g.deinit();
                try writer.print("property {s} (Kotlin reflection is not available)", .{g.get().bytes});
            },
            .Regex => |r| {
                const rg = r.borrow();
                defer rg.deinit();
                const pg = rg.get().pattern.borrow();
                defer pg.deinit();
                try writer.writeAll(pg.get().bytes);
            },
            .Match => |m| {
                const mg = m.borrow();
                defer mg.deinit();
                const groups = mg.get().groups;
                if (groups.len > 0) {
                    if (groups[0]) |g0| {
                        const vg = g0.value.borrow();
                        defer vg.deinit();
                        try writer.writeAll(vg.get().bytes);
                    }
                }
            },
            .MatchGroup => |g| {
                const vg = g.value.borrow();
                defer vg.deinit();
                try writer.writeAll(vg.get().bytes);
            },
            .StringBuilder => |s| {
                const g = s.borrow();
                defer g.deinit();
                try writer.writeAll(g.get().items);
            },
            .Instance => |i| try writeInstance(writer, i),
        }
    }

    /// Render to an owned string via `writeTo`.
    /// Re-read a primitive-array `.asList()` view's element cache from the
    /// backing array so a later array write shows through on the next read.
    /// The view is fixed-size, so this only overwrites the existing (scalar,
    /// non-refcounted) slots in place — no allocation, no retain/release. A
    /// no-op for any value that is not an `array`-backed list. Reference
    /// `Array<T>.asList()` views share the boxed buffer directly and carry no
    /// backing, so they are inherently live and never reach here.
    pub fn refreshArrayView(self: *const Value) void {
        if (self.* != .List) return;
        const b = self.List.backing orelse return;
        if (b.data != .array) return;
        const av = b.data.array;
        const bg = av.buf.borrow();
        defer bg.deinit();
        const n = bg.get().len();
        const ig = self.List.items.borrowMut();
        defer ig.deinit();
        const items = ig.get().items;
        var i: usize = 0;
        while (i < n and i < items.len) : (i += 1) {
            items[i] = bg.get().getAs(i, av.view_kind);
        }
    }

    /// Re-read a live `subList` window's element cache from the parent
    /// list so a parent element write shows through on the next view
    /// access. In-place, clamped to the window; parent structural
    /// changes not made through the view are undefined in Kotlin and
    /// fail fast via the shared mod_count.
    /// Whether a live `subList` view's backing changed structurally not
    /// through the view (or a descendant) — the CME predicate.
    pub fn sublistViewStale(self: *const Value) bool {
        if (self.* != .List) return false;
        const cell = self.List.backing orelse return false;
        if (cell.data != .sublist) return false;
        const mc = self.List.mod_count.get() orelse return false;
        const cur = blk: {
            const g = mc.borrow();
            defer g.deinit();
            break :blk g.get().*;
        };
        return (cur & ~FROZEN_MOD_BIT) != (cell.data.sublist.exp_mod & ~FROZEN_MOD_BIT);
    }

    pub fn refreshSublistView(self: *const Value) void {
        if (self.* != .List) return;
        // Borrow-overwrite of owned slots: correct only where retain/
        // release are no-ops (the arena profile; the GC traces the
        // parent through the backing edge).
        if (objcell.reclaimEnabled()) return;
        const b = self.List.backing orelse return;
        refreshSublistCell(b, self.List.items);
    }

    pub fn display(self: Value, allocator: std.mem.Allocator) ![]u8 {
        var alloc_writer = std.Io.Writer.Allocating.init(allocator);
        errdefer alloc_writer.deinit();
        self.writeTo(&alloc_writer.writer) catch return error.OutOfMemory;
        return alloc_writer.toOwnedSlice();
    }
};

/// One key-selector step of a `Comparator`: a callable plus a per-step
/// descending flag.
pub const ComparatorStep = struct {
    selector: Value,
    descending: bool,
    /// `compareBy(comparator, selector)`: compare the selected keys with this
    /// comparator instead of their natural order. Null for the plain
    /// `compareBy(selector)` / `compareByDescending(selector)` forms.
    key_comparator: ?Value = null,
    pub fn gcTrace(self: *const ComparatorStep, m: *objcell.gc.Marker) void {
        self.selector.gcMark(m);
        if (self.key_comparator) |kc| kc.gcMark(m);
    }
};

/// High bit of a shared structural counter: set when a builder freezes its
/// live views at `build()`. Masked out of comod comparisons so a
/// leaked-but-unmodified builder view still reads.
pub const FROZEN_MOD_BIT: u64 = 1 << 63;

/// Recursive body of `refreshSublistView`: refresh the parent view first
/// (so a root write shows through a whole `subList().subList()` chain),
/// then copy this window from the parent cache. In-place and clamped —
/// structural growth flows the other way (`syncSublist`), and structural
/// changes not made through the view fail fast via the comod stamp.
fn refreshSublistCell(cell: *CollBackingRef.Cell, view_items: ValueList) void {
    if (cell.data != .sublist) return;
    const sb = cell.data.sublist;
    if (sb.parent_backing) |pb| refreshSublistCell(pb, sb.parent);
    const pg = sb.parent.borrow();
    defer pg.deinit();
    const pitems = pg.get().items;
    if (sb.from >= pitems.len) return;
    const avail = @min(sb.from + sb.len, pitems.len) - sb.from;
    const ig = view_items.borrowMut();
    defer ig.deinit();
    const items = ig.get().items;
    var i: usize = 0;
    while (i < avail and i < items.len) : (i += 1) {
        items[i] = pitems[sb.from + i];
    }
}

fn writeElements(writer: *std.Io.Writer, items: ValueList, container: *const Value) std.Io.Writer.Error!void {
    const g = items.borrow();
    defer g.deinit();
    try writer.writeByte('[');
    for (g.get().items, 0..) |v, i| {
        if (i > 0) try writer.writeAll(", ");
        // Kotlin's AbstractCollection.toString prints `(this Collection)` for an
        // element that is the collection itself; matching it avoids unbounded
        // recursion on a self-referential collection.
        if (Value.referenceEq(&v, container)) {
            try writer.writeAll("(this Collection)");
        } else {
            try v.writeTo(writer);
        }
    }
    try writer.writeByte(']');
}

fn writeInstance(writer: *std.Io.Writer, inst_ref: ObjRef(InstanceData)) std.Io.Writer.Error!void {
    const g = inst_ref.borrow();
    defer g.deinit();
    const inst = g.get();
    const cg = inst.class.borrow();
    defer cg.deinit();
    const cls = cg.get();
    if (cls.is_enum) {
        if (inst.get("name")) |nv| {
            if (nv == .String) {
                const sg = nv.String.borrow();
                defer sg.deinit();
                try writer.writeAll(sg.get().bytes);
                return;
            }
        }
        try writer.writeAll(cls.name);
        return;
    }
    if (cls.is_object) {
        try writer.writeAll(cls.name);
        return;
    }
    if (cls.is_data or cls.is_value) {
        try writer.print("{s}(", .{classDisplayName(cls.name)});
        var first = true;
        for (cls.primary_params) |p| {
            if (!first) try writer.writeAll(", ");
            first = false;
            try writer.print("{s}=", .{p.name});
            if (inst.get(p.name)) |v| {
                try v.writeTo(writer);
            } else {
                try writer.writeAll("null");
            }
        }
        try writer.writeByte(')');
        return;
    }
    try writer.print("{s}@{x}", .{ cls.fqn, inst.identity });
}

fn writeFloat64(writer: *std.Io.Writer, v: f64) std.Io.Writer.Error!void {
    var buf: [float_fmt.MAX_LEN]u8 = undefined;
    try writer.writeAll(float_fmt.formatDouble(&buf, v));
}

fn writeFloat32(writer: *std.Io.Writer, v: f32) std.Io.Writer.Error!void {
    var buf: [float_fmt.MAX_LEN]u8 = undefined;
    try writer.writeAll(float_fmt.formatFloat(&buf, v));
}

fn writeChar(writer: *std.Io.Writer, unit: u16) std.Io.Writer.Error!void {
    var buf: [8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const s = float_fmt.charUnitToString(fba.allocator(), unit) catch return;
    try writer.writeAll(s);
}

fn matchesAny(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, name, c)) return true;
    }
    return false;
}

fn throwableIsErrorSide(tail: []const u8) bool {
    return matchesAny(tail, &.{
        "Error",               "AssertionError",
        "NotImplementedError", "OutOfMemoryError",
        "StackOverflowError",  "FileFailedToInitializeException",
    });
}

fn simpleNameMatchesIterator(name: []const u8, simple: []const u8) bool {
    // name == "{simple}Iterator"
    if (!std.mem.endsWith(u8, name, "Iterator")) return false;
    const head = name[0 .. name.len - "Iterator".len];
    return std.mem.eql(u8, head, simple);
}

fn lastSegment(fqn: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |i| return fqn[i + 1 ..];
    return fqn;
}

fn lastDotSegment(name: []const u8) ?[]const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return null;
}

/// The Kotlin source simple name to print for a class. A nested class lifts
/// to a flat top-level mangle (`Outer$Data`); Kotlin's `toString` shows just
/// `Data`. `$` cannot occur in a source class name, so the tail after the
/// last `$` (then the last `.`) is the source simple name.
fn classDisplayName(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.lastIndexOfScalar(u8, n, '$')) |i| n = n[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, n, '.')) |i| n = n[i + 1 ..];
    return n;
}

fn isFunctionType(self: Value, name: []const u8) bool {
    _ = self;
    if (matchesAny(name, &.{ "Function", "Any", "kotlin.Function", "KFunction", "KCallable", "kotlin.reflect.KFunction", "kotlin.reflect.KCallable" })) {
        return true;
    }
    const stripped: ?[]const u8 = if (std.mem.startsWith(u8, name, "kotlin.Function"))
        name["kotlin.Function".len..]
    else if (std.mem.startsWith(u8, name, "Function"))
        name["Function".len..]
    else
        null;
    if (stripped) |s| {
        _ = std.fmt.parseInt(usize, s, 10) catch return false;
        // Arity-suffixed FunctionN matching answered only for the retired
        // AST-interpreter function value; live callables match through the
        // un-aritied names above, exactly as before.
        return false;
    }
    return false;
}

fn strEq(a: StringRef, b: StringRef) bool {
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    if (ga.get().u16_len != gb.get().u16_len) return false; // cheap length pre-check
    return std.mem.eql(u8, ga.get().bytes, gb.get().bytes);
}

fn classFqnEq(a: ObjRef(ClassDef), b: ObjRef(ClassDef)) bool {
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    return classFqnSpellingEq(ga.get().fqn, gb.get().fqn);
}

/// One class may sit in the class table under two spellings of its fqn:
/// the dotted nesting (`Outer.B`) and the lifted mangle (`Outer$B`). Both
/// name the same class, so `KClass` equality reads them alike.
pub fn classFqnSpellingEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x == y) continue;
        const xs = if (x == '$') '.' else x;
        const ys = if (y == '$') '.' else y;
        if (xs != ys) return false;
    }
    return true;
}

fn listEqBoxed(a: ValueList, b: ValueList) bool {
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    const xs = ga.get().items;
    const ys = gb.get().items;
    if (xs.len != ys.len) return false;
    for (xs, ys) |*x, *y| {
        if (!Value.structuralEqBoxed(x, y)) return false;
    }
    return true;
}

fn setEqBoxed(a: ValueList, b: ValueList) bool {
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    const xs = ga.get().items;
    const ys = gb.get().items;
    if (xs.len != ys.len) return false;
    for (xs) |*x| {
        var found = false;
        for (ys) |*y| {
            if (Value.structuralEqBoxed(x, y)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn mapEqBoxed(a: MapEntries, b: MapEntries) bool {
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    const xs = ga.get().pairs.items;
    const ys = gb.get().pairs.items;
    if (xs.len != ys.len) return false;
    for (xs) |*kv| {
        var found = false;
        for (ys) |*kv2| {
            if (Value.structuralEqBoxed(&kv.key, &kv2.key) and Value.structuralEqBoxed(&kv.value, &kv2.value)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn instanceEq(a: ObjRef(InstanceData), b: ObjRef(InstanceData)) bool {
    if (ObjRef(InstanceData).ptrEq(a, b)) return true;
    const ga = a.borrow();
    defer ga.deinit();
    const gb = b.borrow();
    defer gb.deinit();
    const ai = ga.get();
    const bi = gb.get();
    const ca = ai.class.borrow();
    defer ca.deinit();
    const cb = bi.class.borrow();
    defer cb.deinit();
    if (!std.mem.eql(u8, ca.get().fqn, cb.get().fqn)) return false;
    if (!ca.get().is_data and !ca.get().is_value) return false;
    for (ca.get().primary_params) |p| {
        const v1 = ai.get(p.name) orelse Value.Null;
        const v2 = bi.get(p.name) orelse Value.Null;
        if (!Value.structuralEq(&v1, &v2)) return false;
    }
    return true;
}

/// Runtime error data. RuntimeError is DATA, never a Zig `error`; the
/// control-flow signals (`Return`, `Break`, …) are modeled as variants.
/// Heap-owning payloads borrow the interpreter's arena; the message
/// strings are borrowed slices.
pub const RuntimeError = union(enum) {
    Unbound: []const u8,
    Type: []const u8,
    Arity: []const u8,
    NoMain,
    Unimplemented: []const u8,
    /// A function body was entered and failed to resolve an operation.
    /// Distinct from `Unimplemented` (the dispatch-miss sentinel) so a
    /// candidate that ran — possibly with side effects — is never retried
    /// or treated as inapplicable; this error always propagates.
    CalleeFailed: []const u8,

    // Control-flow signals — caught by the appropriate frame.
    Return: Value,
    /// `return@label value`.
    LabeledReturn: struct { label: []const u8, value: Value },
    Break,
    /// `break@label`.
    LabeledBreak: []const u8,
    Continue,
    /// `continue@label`.
    LabeledContinue: []const u8,
    /// A thrown Kotlin Throwable.
    Thrown: Value,
    /// `tailrec` trampoline signal: evaluated args + optional names for the
    /// next iteration.
    TailContinue: struct { args: []Value, names: []?[]const u8 },
    /// Mutual `tailrec` hop: callee value, args, optional names.
    TailJump: struct { callee: Value, args: []Value, names: []?[]const u8 },
    /// Coroutine suspension request (wake after `wake_in_millis` virtual ms).
    Suspend: i64,
};

/// `Result<Value, RuntimeError>` as data. OOM stays a Zig `error`; this
/// carries the RuntimeError data path.
pub const EvalResult = union(enum) {
    ok: Value,
    err: RuntimeError,
};

// -------------------------------------------------------------------------
// Declared element types on container creators.
// -------------------------------------------------------------------------

/// Stdlib container creators whose call-site type arguments name the
/// element type of the value they build. Explicit type arguments on these
/// calls are the only place an empty container's element type is ever
/// written, so the value records the head name for receiver proofs and
/// overload refinement (`with(listOf<String>()) { … }` can then bind a
/// `List<String>` extension). Head names only — the lowering records what
/// the source wrote, without nested generic arguments.
const elem_typed_creators = [_][]const u8{
    "listOf",       "mutableListOf", "emptyList",     "arrayListOf", "listOfNotNull",
    "buildList",    "setOf",         "mutableSetOf",  "emptySet",    "hashSetOf",
    "linkedSetOf",  "sortedSetOf",   "buildSet",      "arrayOf",     "emptyArray",
    "arrayOfNulls", "sequenceOf",    "emptySequence",
};

const pair_typed_creators = [_][]const u8{
    "mapOf", "mutableMapOf", "emptyMap", "hashMapOf", "linkedMapOf", "sortedMapOf", "buildMap",
};

/// Record the call-site type-argument heads on a container a stdlib
/// creator just built. `fqn` is the creator's declared FQN (only
/// `kotlin*` creators qualify — a user function named `listOf` does not),
/// and the `type_args` strings must outlive the value (they are the
/// module's interned consts).
/// Coerce a numeric literal element to the container's explicit element type
/// (`listOf<Byte>(1, 2)` stores `Byte`s, not the `Int` literals). Returns null
/// when no coercion applies — the element is already that type, the type is
/// not a numeric primitive, or the element is non-numeric. Mirrors the
/// type-directed conversion kotlinc applies to integer/float literals so a
/// `List<Byte>` compares equal to one built from a `ByteArray`.
fn elemAsU64(v: Value) ?u64 {
    return switch (v) {
        .UByte => |x| x,
        .UShort => |x| x,
        .UInt => |x| x,
        .ULong => |x| x,
        .Byte, .Short, .Int, .Long => if (v.asI64()) |n| (if (n >= 0) @as(u64, @intCast(n)) else null) else null,
        else => null,
    };
}

fn coerceNumericElem(val: Value, head: []const u8) ?Value {
    const eq = std.mem.eql;
    if (eq(u8, head, "Byte")) {
        if (val != .Byte and val.isIntegral()) if (val.asI64()) |n| return .{ .Byte = @truncate(n) };
    } else if (eq(u8, head, "Short")) {
        if (val != .Short and val.isIntegral()) if (val.asI64()) |n| return .{ .Short = @truncate(n) };
    } else if (eq(u8, head, "Long")) {
        if (val != .Long and val.isIntegral()) if (val.asI64()) |n| return .{ .Long = n };
    } else if (eq(u8, head, "Float")) {
        if (val != .Float and (val.isIntegral() or val.isFloating())) if (val.asF64()) |f| return .{ .Float = @floatCast(f) };
    } else if (eq(u8, head, "Double")) {
        if (val != .Double and (val.isIntegral() or val.isFloating())) if (val.asF64()) |f| return .{ .Double = f };
    } else if (eq(u8, head, "UByte")) {
        if (val != .UByte) if (elemAsU64(val)) |n| return .{ .UByte = @truncate(n) };
    } else if (eq(u8, head, "UShort")) {
        if (val != .UShort) if (elemAsU64(val)) |n| return .{ .UShort = @truncate(n) };
    } else if (eq(u8, head, "UInt")) {
        if (val != .UInt) if (elemAsU64(val)) |n| return .{ .UInt = @truncate(n) };
    } else if (eq(u8, head, "ULong")) {
        if (val != .ULong) if (elemAsU64(val)) |n| return .{ .ULong = n };
    }
    return null;
}

fn coerceListElems(items: ValueList, head: []const u8) void {
    const g = items.borrowMut();
    defer g.deinit();
    for (g.get().items) |*slot| {
        if (coerceNumericElem(slot.*, head)) |c| slot.* = c;
    }
}

pub fn attachDeclaredElemTypes(fqn: []const u8, type_args: []const []const u8, v: *Value) void {
    if (type_args.len == 0) return;
    if (!std.mem.startsWith(u8, fqn, "kotlin")) return;
    const name = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |i| fqn[i + 1 ..] else fqn;
    const elem_arg = type_args[0];
    if (elem_arg.len == 0) return;
    for (elem_typed_creators) |c| {
        if (!std.mem.eql(u8, c, name)) continue;
        switch (v.*) {
            .List => |l| {
                if (l.declared_elem == null) l.declared_elem = elem_arg;
                coerceListElems(l.items, elem_arg);
            },
            .Set => |s| {
                if (s.declared_elem == null) s.declared_elem = elem_arg;
                coerceListElems(s.items, elem_arg);
            },
            else => {},
        }
        return;
    }
    if (type_args.len < 2 or type_args[1].len == 0) return;
    for (pair_typed_creators) |c| {
        if (!std.mem.eql(u8, c, name)) continue;
        if (v.* == .Map) {
            if (v.Map.declared_key == null) v.Map.declared_key = type_args[0];
            if (v.Map.declared_value == null) v.Map.declared_value = type_args[1];
        }
        return;
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "classifier receiver ABI separates host values from source classes" {
    try testing.expectEqual(ReceiverAbi.specialized, classifierReceiverAbi("kotlin.collections.Collection"));
    try testing.expectEqual(ReceiverAbi.specialized, classifierReceiverAbi("kotlin.collections.Grouping"));
    try testing.expectEqual(ReceiverAbi.specialized, classifierReceiverAbi("kotlin.sequences.Sequence"));
    try testing.expectEqual(ReceiverAbi.specialized, classifierReceiverAbi("kotlin.Function2"));
    try testing.expectEqual(ReceiverAbi.instance, classifierReceiverAbi("kotlin.sequences.DropTakeSequence"));
    try testing.expectEqual(ReceiverAbi.instance, classifierReceiverAbi("sample.Collection"));
}

test "numeric type fqn and rank" {
    try testing.expectEqualStrings("kotlin.Int", (Value{ .Int = 1 }).typeFqn());
    try testing.expectEqualStrings("kotlin.Long", (Value{ .Long = 1 }).typeFqn());
    try testing.expectEqual(NumericRank.Int, (Value{ .Int = 1 }).numericRank().?);
    try testing.expectEqual(NumericRank.Double, (Value{ .Double = 1 }).numericRank().?);
}

test "as_i64 widens and ulong wraps" {
    try testing.expectEqual(@as(i64, 5), (Value{ .Int = 5 }).asI64().?);
    try testing.expectEqual(@as(i64, -1), (Value{ .ULong = std.math.maxInt(u64) }).asI64().?);
    try testing.expect((Value{ .Double = 1.0 }).asI64() == null);
}

test "structural eq is type-strict across numerics" {
    const a = Value{ .Int = 1 };
    const b = Value{ .Long = 1 };
    try testing.expect(!Value.structuralEq(&a, &b));
    const c = Value{ .Int = 1 };
    try testing.expect(Value.structuralEq(&a, &c));
}

test "is_runtime_type basic primitives" {
    try testing.expect((Value{ .Int = 1 }).isRuntimeType("Number"));
    try testing.expect((Value{ .Int = 1 }).isRuntimeType("Any"));
    try testing.expect(!(Value{ .Int = 1 }).isRuntimeType("Long"));
}

test "range display forms" {
    var buf: [64]u8 = undefined;
    {
        var w = std.Io.Writer.fixed(&buf);
        const r1 = try Value.newRange(testing.allocator, .{ .start = 1, .end = 10, .step = 1, .kind = .Int });
        defer rangeRefOf(r1.Range).deinit();
        try r1.writeTo(&w);
        try testing.expectEqualStrings("1..10", w.buffered());
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        const r2 = try Value.newRange(testing.allocator, .{ .start = 10, .end = 1, .step = -2, .kind = .Int });
        defer rangeRefOf(r2.Range).deinit();
        try r2.writeTo(&w);
        try testing.expectEqualStrings("10 downTo 1 step 2", w.buffered());
    }
}

test "string value round-trips through a refcounted handle" {
    const s = try strInit(testing.allocator, "hi");
    defer s.deinit();
    const v = Value{ .String = s };
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try v.writeTo(&w);
    try testing.expectEqualStrings("hi", w.buffered());
    try testing.expectEqualStrings("kotlin.String", v.typeFqn());
}

test "display produces an owned string" {
    const v = Value{ .Int = 42 };
    const s = try v.display(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("42", s);
}

test "value layout census" {
    std.debug.print("\nValue size={d} align={d}\n", .{ @sizeOf(Value), @alignOf(Value) });
    inline for (@typeInfo(Value).@"union".fields) |f| {
        if (@sizeOf(f.type) > 8) std.debug.print("  {s}: {d}\n", .{ f.name, @sizeOf(f.type) });
    }
}
