//! The runtime `Value` model: the tagged union every interpreter and stdlib
//! path evaluates against, its helper types, and `RuntimeError`. `ObjRef(T)` is
//! the refcounted, lock-mediated cell; `*Value` an owning pointer to one boxed
//! value; `*const ast.X` a borrow from the parse/lower arena.

const std = @import("std");
const ast = @import("ast");
const objcell = @import("objcell.zig");
const tls_fast = @import("tls_fast.zig");
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

/// Scratch arena for the supertype walks below; the walk is bounded. Held
/// thread-local rather than on the stack, so the safety fill of an `undefined`
/// stack array does not run on every call.
threadlocal var subtype_scratch: [16 * 1024]u8 align(16) = undefined;
threadlocal var subtype_scratch_busy: bool = false;

/// A class's `Map.Entry`-ness is fixed by its supertype graph.
const MapEntryMemoSlot = struct { key: usize = 0, val: bool = false };
threadlocal var map_entry_memo: [512]MapEntryMemoSlot = @splat(.{});

/// A nested walk finds the buffer lent out and uses the page allocator.
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

/// Backing of a `String`. `u16_len` is Kotlin's `String.length` in UTF-16 code
/// units and `ascii` means no byte is >= 0x80; a Kotlin string is immutable, so
/// both are computed once at construction.
pub const StringData = struct {
    bytes: []const u8,
    u16_len: u32,
    ascii: bool,
    /// UTF-16 index and the byte offset of the same boundary, packed into one
    /// atomic word so a reader on another thread never sees a torn pair. A walk
    /// with advancing positions resumes from it, keeping indexing linear.
    cursor: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub const Cursor = struct { u16_pos: usize, byte_pos: usize };

    pub fn cursorGet(self: *const StringData) Cursor {
        const w = self.cursor.load(.monotonic);
        return .{ .u16_pos = @intCast(w >> 32), .byte_pos = @intCast(w & 0xFFFF_FFFF) };
    }

    pub fn cursorSet(self: *const StringData, u16_pos: usize, byte_pos: usize) void {
        if (u16_pos > 0xFFFF_FFFF or byte_pos > 0xFFFF_FFFF) return;
        const w = (@as(u64, @intCast(u16_pos)) << 32) | @as(u64, @intCast(byte_pos));
        @constCast(&self.cursor).store(w, .monotonic);
    }

    /// Nothing ever takes an exclusive borrow of an immutable string, so this
    /// marker elides the reader lock; see `objcell.LockFor`.
    pub const objref_immutable = true;

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

pub const StringRef = ObjRef(StringData);

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

/// Under the GC and reclaim backends the cell owns a private copy of `bytes`;
/// under the pure arena the slice is adopted as-is.
pub fn strInit(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!StringRef {
    const owned = if (objcell.reclaimEnabled() or objcell.gc.gc_enabled) try allocator.dupe(u8, bytes) else bytes;
    const m = strMeta(owned);
    return StringRef.initOwned(allocator, .{ .bytes = owned, .u16_len = m.u16_len, .ascii = m.ascii });
}

pub fn strInitOwned(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!StringRef {
    const m = strMeta(bytes);
    return StringRef.initOwned(allocator, .{ .bytes = bytes, .u16_len = m.u16_len, .ascii = m.ascii });
}
/// One captured call-stack entry. `file_id` and `offset` are raw `Span`
/// components, kept as integers so this module need not import `span`. `fqn`
/// borrows program-lifetime module memory.
pub const StackFrame = struct {
    fqn: []const u8,
    file_id: u32,
    offset: u32,
    has_pos: bool,
};

/// Innermost frame first. Each `fqn` borrows the module.
pub const StackTraceData = struct {
    frames: []StackFrame,

    /// Set once at throw time and only read after, so never write-locked.
    pub const objref_immutable = true;

    pub fn gcFinalize(self: *StackTraceData, a: std.mem.Allocator) void {
        a.free(self.frames);
    }
    pub fn deinit(self: *StackTraceData, a: std.mem.Allocator) void {
        a.free(self.frames);
    }
};

pub const StackRef = ObjRef(StackTraceData);

pub const ValueList = ObjRef(std.ArrayList(Value));
pub const ValueSlice = ObjRef([]Value);
/// A closure's identity and captured values in one cell, so the `Value` payload
/// is one pointer and closure identity is cell identity. `id` is immutable and
/// reads through `asPtr()` without a lock; `captures` is rebindable, since a
/// closure's `this` can be re-bound, so it keeps the cell's borrow.
pub const IrClosureData = struct {
    id: u64,
    captures: []Value,

    /// Without this hook the captures read as a leaf and are swept while live.
    pub fn gcTrace(self: *const IrClosureData, m: *objcell.gc.Marker) void {
        for (self.captures) |*c| c.gcMark(m);
    }

    pub fn gcFinalize(self: *IrClosureData, a: std.mem.Allocator) void {
        a.free(self.captures);
    }
};
pub const IrClosureRef = ObjRef(IrClosureData);
pub const MapPair = struct {
    key: Value,
    value: Value,
    /// A map entry owns one reference to its key and one to its value.
    pub fn gcTrace(self: *const MapPair, m: *objcell.gc.Marker) void {
        self.key.gcMark(m);
        self.value.gcMark(m);
    }
};
/// Backing store for `Map`/`MutableMap`: the insertion-ordered entry list
/// Kotlin's `LinkedHashMap` semantics require, plus an optional hash index. The
/// index is a chained hash over entry positions: `head` maps a key hash to the
/// first entry index + 1 (0 means empty) and `chain[i]` links to the next entry
/// in `pairs[i]`'s bucket, biased the same way. It holds no `Value`s. Maps
/// below `index_threshold` skip it, and a non-hashable key disables it.
pub const MapStore = struct {
    pairs: std.ArrayList(MapPair) = .empty,
    head: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    chain: std.ArrayListUnmanaged(u32) = .empty,
    /// A mismatch with `pairs.len` means entries were appended without
    /// maintenance, so `find` rebuilds.
    indexed_len: usize = 0,
    built: bool = false,
    indexable: bool = true,
    /// Structural-modification counter for fail-fast iteration, shared with
    /// every `keys`, `values` and `entries` view. Null for a read-only map.
    mod_count: objcell.OptRef(u64) = .{},

    /// Below this count a linear scan beats a hash table, so no index is built.
    pub const index_threshold: usize = 16;

    pub fn deinit(self: *MapStore, a: std.mem.Allocator) void {
        self.pairs.deinit(a);
        self.head.deinit(a);
        self.chain.deinit(a);
        if (self.mod_count.get()) |mc| mc.deinit();
    }

    pub fn gcFinalize(self: *MapStore, a: std.mem.Allocator) void {
        self.deinit(a);
    }

    pub fn gcTrace(self: *const MapStore, m: *objcell.gc.Marker) void {
        for (self.pairs.items) |*kv| kv.gcTrace(m);
        if (self.mod_count.get()) |mc| m.shade(&mc.cell.hdr);
    }

    /// Consistent with `Value.structuralEqBoxed`: equal keys hash equal, and
    /// the type tag is mixed in so `5` and `5L` differ. Null for a key that is
    /// not simple-hashable, which makes the caller disable the index.
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

    /// Maintains a live index incrementally; otherwise the index builds lazily
    /// on the next `find`.
    pub fn noteAppended(self: *MapStore, a: std.mem.Allocator, i: usize) std.mem.Allocator.Error!void {
        if (!self.built or !self.indexable) return;
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

    pub fn invalidate(self: *MapStore) void {
        self.built = false;
        self.indexed_len = 0;
        self.head.clearRetainingCapacity();
        self.chain.clearRetainingCapacity();
    }
};

/// One shared cell, so `hasNext` and `next` take a single snapshot borrow.
pub const RangeIterState = struct {
    cur: i64,
    end: i64,
    step: i64,
    kind: RangeKind,
    done: bool = false,
};

pub const MapEntries = ObjRef(MapStore);

pub const MapData = struct {
    entries: MapEntries,
    mutable: bool,
    /// Declared key and value type heads; see `ListData.declared_elem`.
    declared_key: ?[]const u8 = null,
    declared_value: ?[]const u8 = null,

    /// Releases the entries' keys and values when this was their last owner.
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

    pub fn gcTrace(self: *const MapData, m: *objcell.gc.Marker) void {
        m.shade(&self.entries.cell.hdr);
    }
};

pub const MapRef = ObjRef(MapData);

pub inline fn mapRefOf(m: *MapData) MapRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", m)) };
}

/// Immutable after construction.
pub const RangeData = struct {
    start: i64,
    end: i64,
    step: i64,
    kind: RangeKind,
    /// Built as a progression (`step`, `downTo`, `reversed`). Even at step 1 a
    /// progression is not an `IntRange`: it renders as `1..10 step 1`, hashes by
    /// the progression formula, and fails `is IntRange`.
    progression: bool = false,
};

pub const RangeRef = ObjRef(RangeData);

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

pub const MapEntryData = struct {
    key: ValueBox,
    value: ValueBox,
    /// When set, the live map's entries: `setValue` writes through.
    backing: objcell.OptRef(MapStore) = .{},
    /// The backing counter when this entry was handed out; a later structural
    /// change makes every member access throw ConcurrentModificationException.
    exp_mod: u64 = 0,

    pub fn deinit(self: *MapEntryData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.key.deinit();
        self.value.deinit();
        // `backing` is a non-owning write-through reference.
    }

    pub fn gcTrace(self: *const MapEntryData, m: *objcell.gc.Marker) void {
        // Shade the box cells, whose own tracers reach the inner values:
        // marking through the interior would leave the boxes unmarked.
        m.shade(&self.key.cell.hdr);
        m.shade(&self.value.cell.hdr);
        if (self.backing.get()) |b| m.shade(&b.cell.hdr);
    }
};

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

pub const ResultRef = ObjRef(ResultData);

pub inline fn resultRefOf(r: *ResultData) ResultRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", r)) };
}

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

pub const ComparatorRef = ObjRef(ComparatorData);

pub inline fn comparatorRefOf(c: *ComparatorData) ComparatorRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", c)) };
}

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

pub const PairRef = ObjRef(PairData);

pub inline fn pairRefOf(p: *PairData) PairRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", p)) };
}

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

/// Program-lifetime, never freed, invisible to the refcount and collector.
pub const IntrinsicData = struct {
    fqn: []const u8,
    func: StdlibFn,
};

var intrinsic_intern_mutex: objcell.SpinMutex = .{};
var intrinsic_intern: ?std.StringHashMap(*const IntrinsicData) = null;

pub const MatchGroupRef = ObjRef(MatchGroupData);

pub inline fn matchGroupRefOf(g: *MatchGroupData) MatchGroupRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", g)) };
}

pub const TripleRef = ObjRef(TripleData);

pub inline fn tripleRefOf(t: *TripleData) TripleRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", t)) };
}

pub const MapEntryRef = ObjRef(MapEntryData);

pub inline fn mapEntryRefOf(e: *MapEntryData) MapEntryRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", e)) };
}

pub const BoundMethodRef = ObjRef(BoundMethodData);

pub inline fn boundMethodRefOf(b: *BoundMethodData) BoundMethodRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", b)) };
}

pub inline fn rangeRefOf(r: *RangeData) RangeRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", r)) };
}

/// A `Value` as compiled code passes it: two opaque words. A tagged union has
/// no guaranteed layout, so the conversion is a byte copy, not a bitcast.
pub const CValue = extern struct { lo: u64, hi: u64 };

pub inline fn toC(v: Value) CValue {
    var tmp = v;
    var out: CValue = undefined;
    @memcpy(std.mem.asBytes(&out), std.mem.asBytes(&tmp));
    return out;
}

pub inline fn fromC(v: CValue) Value {
    var tmp = v;
    var out: Value = undefined;
    @memcpy(std.mem.asBytes(&out), std.mem.asBytes(&tmp));
    return out;
}

/// The emitted resume function and the heap frame it resumes into. Answers the
/// result, or `CoroutineSuspended`.
pub const NativeResume = struct {
    call: *const fn (?*anyopaque, CValue) callconv(.c) CValue,
    frame: ?*anyopaque,
};

/// Copies of the `Value` share one record, so `fillInStackTrace`,
/// `addSuppressed` and cause writes are visible through every copy, matching
/// JVM reference semantics.
pub const ExceptionData = struct {
    fqn: StringRef,
    message: objcell.OptRef(StringData) = .{},
    /// A bare cell pointer, since `?ObjRef` is not null-optimized.
    cause: ?*ValueBox.Cell,
    /// Captured at the first throw. Borrows program-lifetime frame labels; the
    /// slice belongs to the `StackRef`.
    stack: ?*StackRef.Cell = null,
    /// Reference identity for `===`. 0 for exceptions built outside the
    /// constructor, which then compare structurally.
    identity: u64 = 0,
    /// Shared so every copy of the exception value sees the same set.
    suppressed: ?*ValueList.Cell = null,
    /// Preorder number of this throwable's type in a compiled program's
    /// hierarchy: a handler carries the interval its own type spans, so `catch`
    /// is two comparisons. Zero for every value the interpreter makes.
    type_id: u32 = 0,

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

pub const ExceptionRef = ObjRef(ExceptionData);

pub inline fn exceptionRefOf(e: *ExceptionData) ExceptionRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", e)) };
}

pub const ListData = struct {
    items: ValueList,
    mutable: bool,
    enum_entries: bool = false,
    /// Set for a live view; see `CollBacking`.
    backing: ?*CollBackingCell,
    /// Declared element-type head from a call-site type argument, borrowing the
    /// module's interned consts. Dispatch reads it to type an empty list.
    declared_elem: ?[]const u8 = null,
    /// Structural-modification counter for fail-fast iteration, shared across
    /// every copy of the list value and the iterators it spawns.
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

pub const ListRef = ObjRef(ListData);

pub inline fn listRefOf(l: *ListData) ListRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", l)) };
}

pub const SetData = struct {
    items: ValueList,
    mutable: bool,
    backing: ?*CollBackingCell,
    /// See `ListData.declared_elem`.
    declared_elem: ?[]const u8 = null,
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

pub const SetRef = ObjRef(SetData);

pub inline fn setRefOf(s: *SetData) SetRef {
    return .{ .cell = @alignCast(@fieldParentPtr("data", s)) };
}
/// A refcounted box holding one `Value`, so a copy of the enclosing value
/// shares the box and the last release frees the `Value`.
pub const ValueBox = ObjRef(Value);

pub const MapViewKind = enum { Keys, Values, Entries };

/// Back-reference carried by a live collection view so reads and mutations
/// resolve through the source: a `MutableMap` view edits the map, a `subList`
/// splices through the parent's items, and a primitive-array `.asList()`
/// reflects later element writes. A reference `Array<T>.asList()` shares the
/// boxed buffer outright and carries no backing.
pub const CollBacking = union(enum) {
    map: struct { entries: MapEntries, kind: MapViewKind },
    sublist: struct {
        /// The parent view's cache in a `subList` chain, or the root list.
        parent: ValueList,
        /// The parent's own backing when it is itself a view: write-through
        /// and refresh recurse to the root. Non-owning.
        parent_backing: ?*CollBackingRef.Cell = null,
        /// Window start and length, parent-relative.
        from: usize,
        len: usize,
        /// A mismatch is a ConcurrentModificationException.
        exp_mod: u64 = 0,
    },
    array: struct { buf: objcell.ObjRef(PrimBuf), view_kind: PrimitiveArrayKind },

    /// Keeps the source cell reachable while a live view references it; the
    /// handle is non-owning, so refcount teardown never releases the source.
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

/// The view owns this cell but not the source it points at.
pub const CollBackingRef = objcell.ObjRef(CollBacking);
/// `List` and `Set` store `?*Cell` rather than a `CollBackingRef`: one pointer,
/// null-optimized to 8 bytes, which keeps `Value` at 64.
pub const CollBackingCell = CollBackingRef.Cell;

/// A Char kind writes the character, a ULong kind the unsigned value.
pub fn writeRangeEndpoint(writer: anytype, kind: RangeKind, v: i64) !void {
    switch (kind) {
        .Char => {
            var buf: [4]u8 = undefined;
            const cp: u21 = if (v >= 0 and v <= 0x10FFFF) @intCast(v) else 0xFFFD;
            const n = std.unicode.utf8Encode(cp, &buf) catch {
                try writer.writeAll("\u{FFFD}");
                return;
            };
            try writer.writeAll(buf[0..n]);
        },
        .ULong => try writer.print("{d}", .{@as(u64, @bitCast(v))}),
        else => try writer.print("{d}", .{v}),
    }
}

pub const RangeKind = enum {
    Int,
    Long,
    Char,
    UInt,
    ULong,

    pub const default: RangeKind = .Int;

    /// Whether `cur` has not yet passed `end` in the step's direction. `ULong`
    /// spans the full u64 range stored in an i64, so it compares unsigned. The
    /// emptiness check uses it too, so `MaxUL..MinUL` reads as empty.
    pub fn inBounds(self: RangeKind, cur: i64, end: i64, step: i64) bool {
        if (self == .ULong) {
            const uc: u64 = @bitCast(cur);
            const ue: u64 = @bitCast(end);
            return if (step > 0) uc <= ue else uc >= ue;
        }
        return if (step > 0) cur <= end else cur >= end;
    }

    /// Empty exactly when `to` is the kind's MIN_VALUE.
    pub fn untilEmpty(self: RangeKind, to: i64) bool {
        return switch (self) {
            .Int => to <= std.math.minInt(i32),
            .Long => to == std.math.minInt(i64),
            .Char, .UInt, .ULong => to == 0,
        };
    }

    /// The kind's empty range: `1..0` signed, `MAX..0` unsigned.
    pub fn emptyBounds(self: RangeKind) [2]i64 {
        return switch (self) {
            .Int, .Long, .Char => .{ 1, 0 },
            .UInt => .{ std.math.maxInt(u32), 0 },
            .ULong => .{ -1, 0 },
        };
    }
};

/// Wider types win in mixed arithmetic.
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

    pub fn elemSize(self: PrimitiveArrayKind) usize {
        return switch (self) {
            .Byte, .UByte, .Boolean => 1,
            .Short, .UShort, .Char => 2,
            .Int, .UInt, .Float => 4,
            .Long, .ULong, .Double => 8,
        };
    }

    /// `UByteArray.storage` is a `ByteArray` over the same bytes.
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

/// Packed scalar storage for a Kotlin primitive array: a flat byte buffer of 1
/// to 8 bytes per element, with no per-element retain, release or tracing.
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

    pub fn get(self: *const PrimBuf, i: usize) Value {
        return self.getAs(i, self.kind);
    }

    /// `view_kind` differs from the storage kind only for an unsigned view over
    /// signed backing, where only the boxed tag changes.
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

    /// `i` must be in bounds. The destination kind defines the stored width.
    pub fn set(self: *PrimBuf, i: usize, v: Value) void {
        self.setAs(i, v, self.kind);
    }

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

    /// Scalars have no out-edges, so the payload is a leaf and mutable access
    /// needs no write barrier.
    pub const gc_pointer_free = true;
    pub fn gcTrace(self: *const PrimBuf, m: *objcell.gc.Marker) void {
        _ = self;
        _ = m;
    }
    pub fn gcFinalize(self: *PrimBuf, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
    }
    /// Bytes owned beyond the control block, for the collection threshold.
    pub fn gcExternalBytes(self: *const PrimBuf) usize {
        return self.bytes.capacity;
    }
    pub fn deinit(self: *PrimBuf, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
    }
};

/// A union rather than two fields, so every access site is compiler-flagged
/// when the representation changes.
pub const ArrayStore = union(enum) {
    boxed: ValueList,
    scalars: ObjRef(PrimBuf),
};

pub const ArrayData = struct {
    /// The storage cell with its element kind tagged into the low four bits.
    /// Every control block is 16-byte aligned, so the pair fits in one pointer
    /// and `Value` stays 16 bytes. Tag 0 is a reference `Array<T>` over an
    /// `ObjRef(std.ArrayList(Value))`; tag `k + 1` is an `ObjRef(PrimBuf)` of
    /// kind `k`. Every reader goes through `cellPtr`, so the collector and the
    /// refcount only ever see the untagged pointer.
    tagged: usize,

    const TAG_MASK: usize = 0xF;

    pub fn boxed(vl: ValueList) ArrayData {
        return .{ .tagged = @intFromPtr(vl.cell) };
    }

    pub fn scalars(pb: ObjRef(PrimBuf), kind: PrimitiveArrayKind) ArrayData {
        return .{ .tagged = @intFromPtr(pb.cell) | (@as(usize, @intFromEnum(kind)) + 1) };
    }

    pub inline fn cellPtr(self: ArrayData) *anyopaque {
        return @ptrFromInt(self.tagged & ~TAG_MASK);
    }

    /// Null for a reference `Array<T>`.
    pub inline fn primKind(self: ArrayData) ?PrimitiveArrayKind {
        const t = self.tagged & TAG_MASK;
        if (t == 0) return null;
        return @enumFromInt(t - 1);
    }

    pub fn storage(self: ArrayData) ArrayStore {
        if (self.primKind() == null) return .{ .boxed = .{ .cell = @ptrCast(@alignCast(self.cellPtr())) } };
        return .{ .scalars = .{ .cell = @ptrCast(@alignCast(self.cellPtr())) } };
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

    /// A boxed element is returned as stored, so the caller retains it to keep
    /// a copy.
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
                return g.get().getAs(i, self.primKind() orelse g.get().kind);
            },
        }
    }

    /// Under a reclaiming backend a boxed array releases the previous element
    /// and retains the new one.
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
                g.get().setAs(i, v, self.primKind() orelse g.get().kind);
            },
        }
    }

    /// The caller owns the slice and the elements are not retained.
    pub fn snapshot(self: ArrayData, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Value {
        return self.snapshotRange(allocator, 0, self.len());
    }

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
                const view_kind = self.primKind() orelse g.get().kind;
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

    /// Null for a packed array; use `snapshot` there.
    pub fn boxedList(self: ArrayData) ?ValueList {
        return switch (self.storage()) {
            .boxed => |vl| vl,
            .scalars => null,
        };
    }

    pub fn deinitStorage(self: ArrayData) void {
        switch (self.storage()) {
            .boxed => |vl| vl.deinit(),
            .scalars => |pb| pb.deinit(),
        }
    }

    /// Backing-cell address, for reference equality and `===`.
    pub fn identity(self: ArrayData) usize {
        return switch (self.storage()) {
            .boxed => |vl| vl.identity(),
            .scalars => |pb| pb.identity(),
        };
    }

    pub fn initPacked(a: std.mem.Allocator, kind: PrimitiveArrayKind, items: []const Value) std.mem.Allocator.Error!Value {
        var pb = PrimBuf{ .kind = kind };
        try pb.bytes.appendNTimes(a, 0, items.len * kind.elemSize());
        for (items, 0..) |v, i| pb.set(i, v);
        return .{ .Array = ArrayData.scalars(try ObjRef(PrimBuf).initOwned(a, pb), kind) };
    }

    pub fn fromBoxedList(vl: ValueList) Value {
        return .{ .Array = ArrayData.boxed(vl) };
    }

    /// `src.len` must equal `len()`; a permutation is refcount-neutral.
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

pub const DelegateKind = union(enum) {
    Lazy: struct { producer: Value, cached: ?Value },
    Observable: struct { value: Value, on_change: Value },
    NotNull: struct { value: ?Value, name: []const u8 },

    /// These live only here, so a delegate held across a collection must keep
    /// them reachable.
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

pub const SuspendBody = struct {
    states: []SuspendState,
};

pub const SuspendState = struct {
    resume_target: ?[]const u8,
    stmts: []ast.Stmt,
    transition: SuspendTransition,
};

pub const SuspendTransition = union(enum) {
    Goto: usize,
    Return,
    Branch: struct { then_state: usize, else_state: usize },
};

pub const PausedResume = union(enum) {
    Resumed: Value,
    Failed: Value,
};

pub const SuspendCallerCont = union(enum) {
    Frame: ObjRef(SuspendFrame),
    HostSlot: ObjRef(?HostSlotResult),
};

pub const HostSlotResult = union(enum) {
    ok: Value,
    err: Value,
};

pub const SuspendFrame = struct {
    decl: *const ast.Function,
    body: ObjRef(SuspendBody),
    env: ObjRef(Env),
    locals: std.ArrayList(Local),
    state: usize,
    caller: ?SuspendCallerCont,
    paused_resume: ?PausedResume,

    pub const Local = struct { name: []const u8, value: Value };
};

/// The lazy coroutine state of a `sequence {}` or `iterator {}` builder. Each
/// `yield(x)` suspends the block, parking the continuation in `cont`, opaque
/// because `runtime` cannot import `ir`. `builderStep` drives one step per pull
/// and reads the yielded value off `scope`'s fields.
pub const BuilderState = struct {
    block: ValueBox,
    /// Carries the pending yielded value or `yieldAll` iterator between steps.
    scope: ValueBox,
    /// Host-owned `*ir.eval.SuspendState`, null before the first pull, after
    /// completion, and while a pull is in flight.
    cont: ?*anyopaque = null,
    started: bool = false,
    done: bool = false,
    /// Every later pull throws IllegalStateException, matching
    /// `SequenceBuilderIterator`'s failed state.
    failed: bool = false,

    /// All are reachable only through a held `Sequence` or `Iterator`.
    pub fn gcTrace(self: *const BuilderState, m: *objcell.gc.Marker) void {
        m.shade(&self.block.cell.hdr);
        m.shade(&self.scope.cell.hdr);
        if (self.cont) |c| {
            if (objcell.gc.markSuspendHook) |h| h(c, m);
        }
    }

    /// A `Sequence` swept before completion still owns its parked continuation
    /// box, freed here through the host hook.
    pub fn gcFinalize(self: *BuilderState, a: std.mem.Allocator) void {
        self.freeCont(a);
    }

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

/// Pulls one element at a time through the source and op pipeline, so an
/// infinite source never materialises.
pub const SeqIterState = struct {
    seq: Value,
    /// Produced by `hasNext()`, consumed by `next()`.
    buffered: ?Value = null,
    done: bool = false,
    src_pos: usize = 0,
    /// The next seed to emit, null before the first pull and once done.
    gen_cur: ?Value = null,
    gen_started: bool = false,
    /// This iteration's Iterator, made on the first pull.
    iter_obj: ?Value = null,
    /// Created together on the first pull.
    iter_left: ?Value = null,
    iter_right: ?Value = null,
    /// Indexed by op position, allocated lazily.
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

/// Behind one shared handle, so it survives the by-value copies a `Value`
/// undergoes.
pub const IterCursor = struct {
    pos: usize = 0,
    /// The `ListIterator` set and remove target. -1 before the first move and
    /// after an `add` or `remove`.
    last_ret: i64 = -1,
    /// Meaningful only when the iterator carries a `mod_count`.
    exp_mod: u64 = 0,
    /// Shared with a mutable source or snapshotted. They ride in the cursor
    /// cell every step already borrows.
    items: ValueList,
    prim: ?PrimitiveArrayKind = null,
    /// Shared with the source: `next` and `hasNext` throw
    /// `ConcurrentModificationException` once it stops matching `exp_mod`, and
    /// the iterator's own `add` and `remove` resync it.
    mod_count: objcell.OptRef(u64) = .{},
    /// True only when the iterator shares a mutable collection's backing, so
    /// `MutableIterator.remove` and the `MutableListIterator` writes reach the
    /// source. Kotlin throws `UnsupportedOperationException` otherwise.
    mutable: bool = false,

    pub fn deinit(self: *IterCursor, allocator: std.mem.Allocator) void {
        // The last handle releases the contained elements before the list.
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
    /// The nullary `generateSequence {}` consumes once, as `.constrainOnce()`
    /// does: a second iteration throws IllegalStateException.
    one_shot: bool = false,
    consumed: bool = false,

    /// The source and each op's lambda are reachable only through here.
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
    Items: ValueSlice,
    /// `seed` is null for the nullary form. `seed_is_fn` marks
    /// `generateSequence(seedFn, next)`, where the seed is a producer invoked
    /// at each iteration start.
    Generate: struct { seed: ?ValueBox, next: ValueBox, seed_is_fn: bool = false },
    Builder: BuilderStateRef,
    /// Each iteration invokes the factory for a fresh Iterator, so the sequence
    /// stays lazy and re-iterable.
    IteratorFn: ValueBox,
    /// Each pull advances both children, left before right, so shared-state
    /// generators observe `MergingSequence`'s interleave. A non-null `transform`
    /// maps each `(a, b)` instead of building a Pair.
    Merged: MergedSource,
};

pub const MergedSource = struct { left: ValueBox, right: ValueBox, transform: ?ValueBox = null };

pub const SeqOp = union(enum) {
    Map: Value,
    Filter: Value,
    FilterNot: Value,
    OnEach: Value,
    MapIndexed: Value,
    FilterIndexed: Value,
    Take: i64,
    Drop: i64,
    TakeWhile: Value,
    DropWhile: Value,
    FlatMap: Value,
    Distinct,
    DistinctBy: Value,
    /// Natural order; the payload flips the comparison.
    Sorted: bool,
    /// Key-selector order; `descending` flips the comparison.
    SortedBy: struct { selector: Value, descending: bool },
    SortedWith: Value,
};

/// Compiled regex and its pattern. The engine is not in the Zig standard
/// library, so `engine` is an opaque host handle.
pub const RegexData = struct {
    /// Immutable once published: `regex_ctor` attaches `options` through
    /// `asPtr` after the cell is minted but before the value escapes the
    /// constructor, so the reader lock is elided. Any new mutation site must
    /// stay inside that pre-escape window.
    pub const objref_immutable = true;

    pattern: StringRef,
    engine: ?*anyopaque,
    /// The caller's enum singletons, so `options` reads are identity-equal.
    options: ?ValueList = null,

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

/// Carries enough state to resume scanning from `MatchResult.next()`.
pub const MatchData = struct {
    input: StringRef,
    /// Index 0 is the whole match. Null for a non-participating group.
    groups: []?MatchGroupData,
    /// Byte offset in `input` just after the matched span.
    end_byte: usize,
    regex: ObjRef(RegexData),

    pub fn gcTrace(self: *const MatchData, m: *objcell.gc.Marker) void {
        m.shade(&self.input.cell.hdr);
        m.shade(&self.regex.cell.hdr);
        for (self.groups) |g| if (g) |grp| m.shade(&grp.value.cell.hdr);
    }
};

// Host-op temporary keepalive, a GC root. A stdlib op that iterates a
// host-built slice and calls a user callable holds its accumulator in native
// storage with no frame register pinning it, and the nested eval reaches a safe
// point, so those Values must be rooted for that window. It lives here because
// the stdlib layer cannot import `ir`.

/// `many` and `pairs` root a whole slice in O(1); `cell` pins a raw object cell
/// whose own `gc_trace` reaches its contents.
const KeepEntry = union(enum) {
    one: Value,
    many: []const Value,
    pairs: []const MapPair,
    cell: *objcell.gc.GcHeader,
};
/// One threadlocal, not three: Darwin resolves each access through a
/// `_tlv_get_addr` call, so this costs one fetch per host re-entry.
const KeepaliveTls = struct {
    stack: std.ArrayListUnmanaged(KeepEntry) = .empty,
    troot: objcell.gc.ThreadRoot = undefined,
    troot_inited: bool = false,
};
/// The owner thread reads the global copy, every other its own.
var keepalive_owner: KeepaliveTls = .{};
threadlocal var keepalive_other: KeepaliveTls = .{};
inline fn keepaliveTls() *KeepaliveTls {
    return if (tls_fast.isOwner()) &keepalive_owner else &keepalive_other;
}

fn gcMarkKeepaliveCtx(ctx: *anyopaque, m: *objcell.gc.Marker) void {
    const stack: *const std.ArrayListUnmanaged(KeepEntry) = @ptrCast(@alignCast(ctx));
    for (stack.items) |e| switch (e) {
        .one => |v| v.gcMark(m),
        .many => |vs| for (vs) |v| v.gcMark(m),
        .pairs => |ps| for (ps) |*p| p.gcTrace(m),
        .cell => |h| m.shade(h),
    };
}

pub fn gcUninstallKeepaliveRoot() void {
    const k = keepaliveTls();
    if (!k.troot_inited) return;
    objcell.gc.unregisterThreadRoot(&k.troot);
    k.troot_inited = false;
}

/// Resolved once: a body that pins across a host re-entry would otherwise
/// resolve the threadlocal three times.
pub const KeepaliveHandle = struct {
    k: *KeepaliveTls,

    pub inline fn mark(self: KeepaliveHandle) usize {
        return self.k.stack.items.len;
    }

    pub inline fn pushSlice(self: KeepaliveHandle, vs: []const Value) void {
        if (!objcell.gc.gc_enabled) return;
        ensureKeepaliveRoot(self.k);
        self.k.stack.append(std.heap.page_allocator, .{ .many = vs }) catch
            @panic("KGC: host_keepalive push failed");
    }

    pub inline fn push(self: KeepaliveHandle, v: Value) void {
        if (!objcell.gc.gc_enabled) return;
        ensureKeepaliveRoot(self.k);
        self.k.stack.append(std.heap.page_allocator, .{ .one = v }) catch
            @panic("KGC: host_keepalive push failed");
    }

    pub inline fn restore(self: KeepaliveHandle, m: usize) void {
        if (!objcell.gc.gc_enabled) return;
        self.k.stack.items.len = m;
    }
};

pub fn keepaliveHandle() KeepaliveHandle {
    return .{ .k = keepaliveTls() };
}

/// Pass the result to `keepaliveRestore`. Valid with the GC off.
pub inline fn keepaliveMark() usize {
    return keepaliveTls().stack.items.len;
}

/// Registered on the first push. The root reads that thread's own stack.
inline fn ensureKeepaliveRoot(k: *KeepaliveTls) void {
    if (k.troot_inited) return;
    k.troot_inited = true;
    k.troot = .{ .ctx = @ptrCast(&k.stack), .mark = gcMarkKeepaliveCtx };
    objcell.gc.registerThreadRoot(&k.troot);
}

/// No-op unless GC is on.
pub fn keepalivePush(v: Value) void {
    if (!objcell.gc.gc_enabled) return;
    const k = keepaliveTls();
    ensureKeepaliveRoot(k);
    k.stack.append(std.heap.page_allocator, .{ .one = v }) catch
        @panic("KGC: host_keepalive push failed");
}

/// The slice must stay valid until the matching restore.
pub fn keepalivePushSlice(vs: []const Value) void {
    if (!objcell.gc.gc_enabled) return;
    const k = keepaliveTls();
    ensureKeepaliveRoot(k);
    k.stack.append(std.heap.page_allocator, .{ .many = vs }) catch
        @panic("KGC: host_keepalive push failed");
}

pub fn keepalivePushPairs(ps: []const MapPair) void {
    if (!objcell.gc.gc_enabled) return;
    const k = keepaliveTls();
    ensureKeepaliveRoot(k);
    k.stack.append(std.heap.page_allocator, .{ .pairs = ps }) catch
        @panic("KGC: host_keepalive push failed");
}

/// For a transient cell in a stack local that no frame register or Vm-graph
/// root reaches. The cell's own `gc_trace` reaches its contents.
pub fn keepalivePushCell(h: *objcell.gc.GcHeader) void {
    if (!objcell.gc.gc_enabled) return;
    const k = keepaliveTls();
    ensureKeepaliveRoot(k);
    k.stack.append(std.heap.page_allocator, .{ .cell = h }) catch
        @panic("KGC: host_keepalive push failed");
}

pub inline fn keepaliveRestore(mark: usize) void {
    if (!objcell.gc.gc_enabled) return;
    keepaliveTls().stack.items.len = mark;
}

/// An `instance` classifier uses numeric virtual slots; a `specialized` one
/// uses the host member ABI.
pub const ReceiverAbi = enum {
    instance,
    specialized,
};

/// An interface is listed whenever at least one specialized value implements
/// it, so a call through that static interface never assumes `Value.Instance`.
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

/// The runtime value: a tagged union over every Kotlin value.
pub const Value = union(enum) {
    Unit,
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
    Float: f32,
    Bool: bool,
    String: StringRef,
    /// A single UTF-16 code unit, possibly a lone surrogate.
    Char: u16,
    Null,
    /// Immutable after construction; construct with `Value.newRange`.
    Range: *RangeData,
    /// Interned for the life of the program, so neither the refcount nor the
    /// collector touches it.
    Intrinsic: *const IntrinsicData,
    IrClosure: IrClosureRef,
    BoundMethod: *BoundMethodData,
    Exception: *ExceptionData,
    List: *ListData,
    Array: ArrayData,
    Set: *SetData,
    /// The pointer targets the `data` field of an `ObjRef(MapData)` control
    /// block, recovered with `mapRefOf`, so a `Value` copy moves 8 bytes and
    /// shares the payload. Every other boxed payload follows this scheme.
    Map: *MapData,
    Pair: *PairData,
    Triple: *TripleData,
    /// Copies share the record, the JVM's reference semantics for an entry.
    MapEntry: *MapEntryData,
    Result: *ResultData,
    Comparator: *ComparatorData,
    Class: ObjRef(ClassDef),
    Instance: ObjRef(InstanceData),
    Sequence: ObjRef(SequenceData),
    /// The whole state lives in the one `IterCursor` cell every step borrows.
    Iterator: ObjRef(IterCursor),
    /// `done` is needed because the cursor saturates at the integer boundary
    /// (`MaxL +| 1 == MaxL`), so `cur <= end` alone would loop forever on a
    /// range ending at `Long.MAX_VALUE`.
    RangeIter: ObjRef(RangeIterState),
    SeqIter: SeqIterStateRef,
    Delegate: ObjRef(DelegateKind),
    PropertyRef: struct {
        name: StringRef,
    },
    Regex: ObjRef(RegexData),
    Match: ObjRef(MatchData),
    MatchGroup: *MatchGroupData,
    StringBuilder: ObjRef(std.ArrayList(u8)),
    Cell: ObjRef(Value),

    pub fn newCell(allocator: std.mem.Allocator, v: Value) !Value {
        return .{ .Cell = try ObjRef(Value).init(allocator, v) };
    }

    pub fn box(allocator: std.mem.Allocator, v: Value) std.mem.Allocator.Error!*Value {
        const p = try allocator.create(Value);
        p.* = v;
        return p;
    }

    /// The box owns `v`; the last release frees it.
    pub fn boxRef(allocator: std.mem.Allocator, v: Value) std.mem.Allocator.Error!ValueBox {
        return ValueBox.init(allocator, v);
    }

    /// Single source of truth for the value graph's out-edges, one level only.
    /// Retain, release and the mark phase all drive this walk, so they cannot
    /// diverge. `backing` write-through views are non-owning and not visited.
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
            .IrClosure => |c| visitor.visit(c),
            .Comparator => |c| visitor.visit(comparatorRefOf(c)),
            .List => |x| visitor.visit(listRefOf(x)),
            .Set => |x| visitor.visit(setRefOf(x)),
            .Array => |x| switch (x.storage()) {
                .boxed => |vl| visitor.visit(vl),
                .scalars => |pb| visitor.visit(pb),
            },
            // The box cell is the one owned edge.
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

    /// Listed conservatively, so a heap variant omitted here still takes the
    /// full path rather than leaking.
    pub inline fn isPrimitive(self: Value) bool {
        return switch (self) {
            .Unit, .CoroutineSuspended, .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Bool, .Char, .Null => true,
            else => false,
        };
    }

    /// The only way to construct a `.Map`.
    pub fn newMap(allocator: std.mem.Allocator, data: MapData) std.mem.Allocator.Error!Value {
        const ref = try MapRef.initOwned(allocator, data);
        return .{ .Map = &ref.cell.data };
    }

    pub fn newRange(allocator: std.mem.Allocator, data: RangeData) std.mem.Allocator.Error!Value {
        const ref = try RangeRef.initOwned(allocator, data);
        return .{ .Range = &ref.cell.data };
    }

    pub fn newIterator(allocator: std.mem.Allocator, data: IterCursor) std.mem.Allocator.Error!Value {
        return .{ .Iterator = try ObjRef(IterCursor).init(allocator, data) };
    }

    /// The interned entry is immortal; allocation failure here is fatal.
    pub fn internIntrinsic(fqn: []const u8, func: StdlibFn) Value {
        intrinsic_intern_mutex.lock();
        defer intrinsic_intern_mutex.unlock();
        const a = std.heap.page_allocator;
        if (intrinsic_intern == null) intrinsic_intern = std.StringHashMap(*const IntrinsicData).init(a);
        const gop = intrinsic_intern.?.getOrPut(fqn) catch @panic("intrinsic intern");
        if (!gop.found_existing) {
            // Own the key bytes: the caller's slice is typically a module
            // constant a multi-program driver frees at that program's teardown.
            const owned = a.dupe(u8, fqn) catch @panic("intrinsic intern");
            gop.key_ptr.* = owned;
            const d = a.create(IntrinsicData) catch @panic("intrinsic intern");
            d.* = .{ .fqn = owned, .func = func };
            gop.value_ptr.* = d;
        }
        return .{ .Intrinsic = gop.value_ptr.* };
    }

    pub fn newMatchGroup(allocator: std.mem.Allocator, data: MatchGroupData) std.mem.Allocator.Error!Value {
        const ref = try MatchGroupRef.initOwned(allocator, data);
        return .{ .MatchGroup = &ref.cell.data };
    }

    pub fn newResult(allocator: std.mem.Allocator, data: ResultData) std.mem.Allocator.Error!Value {
        const ref = try ResultRef.initOwned(allocator, data);
        return .{ .Result = &ref.cell.data };
    }

    pub fn newComparator(allocator: std.mem.Allocator, data: ComparatorData) std.mem.Allocator.Error!Value {
        const ref = try ComparatorRef.initOwned(allocator, data);
        return .{ .Comparator = &ref.cell.data };
    }

    pub fn newPair(allocator: std.mem.Allocator, data: PairData) std.mem.Allocator.Error!Value {
        const ref = try PairRef.initOwned(allocator, data);
        return .{ .Pair = &ref.cell.data };
    }

    pub fn newTriple(allocator: std.mem.Allocator, data: TripleData) std.mem.Allocator.Error!Value {
        const ref = try TripleRef.initOwned(allocator, data);
        return .{ .Triple = &ref.cell.data };
    }

    pub fn newMapEntry(allocator: std.mem.Allocator, data: MapEntryData) std.mem.Allocator.Error!Value {
        const ref = try MapEntryRef.initOwned(allocator, data);
        return .{ .MapEntry = &ref.cell.data };
    }

    pub fn newBoundMethod(allocator: std.mem.Allocator, data: BoundMethodData) std.mem.Allocator.Error!Value {
        const ref = try BoundMethodRef.initOwned(allocator, data);
        return .{ .BoundMethod = &ref.cell.data };
    }

    pub fn newSet(allocator: std.mem.Allocator, data: SetData) std.mem.Allocator.Error!Value {
        const ref = try SetRef.initOwned(allocator, data);
        return .{ .Set = &ref.cell.data };
    }

    pub fn newList(allocator: std.mem.Allocator, data: ListData) std.mem.Allocator.Error!Value {
        const ref = try ListRef.initOwned(allocator, data);
        return .{ .List = &ref.cell.data };
    }

    pub fn newException(allocator: std.mem.Allocator, data: ExceptionData) std.mem.Allocator.Error!Value {
        const ref = try ExceptionRef.initOwned(allocator, data);
        return .{ .Exception = &ref.cell.data };
    }

    /// Dual of `release`.
    pub fn retain(self: Value) void {
        // Gated to match `release`: under reclaim-off both are skipped.
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

    /// Shade each cell this value directly references. Covers the same owning
    /// edges as `retain` plus the non-owning view-to-source `backing` edges
    /// retain and release skip: a live view must keep the source entries cell
    /// reachable. It cannot leak, since once the view is gone nothing marks it.
    pub fn gcMark(self: Value, m: *objcell.gc.Marker) void {
        self.forEachChildCell(MarkVisitor{ .m = m });
        switch (self) {
            // Most declared classes are minted permanent, but a synthetic or
            // local one can be created after the program starts, and a live
            // KClass must keep either kind reachable.
            .Class => |c| m.shade(&c.cell.hdr),
            // Keep the side-table's capture store and receiver chain alive. A
            // closure no live value marks never reaches here.
            .IrClosure => |c| if (objcell.gc.markClosureHook) |f| f(c.asPtr().id, m),
            else => {},
        }
    }

    /// Kotlin's `hashCode()` where it is a pure function of the value: scalars
    /// as kotlinc boxes them (Long folds its halves, Bool is 1231/1237, unsigned
    /// types hash their signed storage, NaN canonicalizes) and String as the
    /// UTF-16 31-polynomial. Null where hashing could dispatch. Every host fast
    /// path and hashing intrinsic shares it, or bucket placement diverges.
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

    /// At strong count zero the payload `deinit` releases what it owns.
    pub fn release(self: Value, allocator: std.mem.Allocator) void {
        // Gated identically to `retain`: the arena frees en masse and the GC
        // reclaims by reachability, while refcount teardown here is O(n).
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
            // The closure cell owns its captures: release each element, then
            // drop the cell, whose finalize frees the slice.
            .IrClosure => |c| {
                if (c.cell.refcount.load(.monotonic) == 1) {
                    const g = c.borrow();
                    for (g.get().captures) |*e| e.release(allocator);
                    g.deinit();
                }
                c.deinit();
            },
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
            // `MapData.deinit` releases the entries when it was the last owner.
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

    /// Releases each element first when this was the last handle.
    /// `strongCount() == 1` means no other thread holds one, so no lock.
    fn releaseValueList(items: ValueList, allocator: std.mem.Allocator) void {
        if (items.strongCount() == 1) {
            const g = items.borrow();
            for (g.get().items) |e| e.release(allocator);
            g.deinit();
        }
        items.deinit();
    }

    fn releaseSliceElems(slice: ValueSlice, allocator: std.mem.Allocator) void {
        if (slice.strongCount() == 1) {
            const g = slice.borrow();
            for (g.get().*) |e| e.release(allocator);
            g.deinit();
        }
        slice.deinit();
    }

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

    /// Floating returns null.
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

    /// Negative signed values wrap.
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

    /// Wraps to 32-bit width.
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

    /// Long is returned as-is.
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

    pub fn wrapUnsigned(rank: NumericRank, v: u64) Value {
        return switch (rank) {
            .UByte => .{ .UByte = @truncate(v) },
            .UShort => .{ .UShort = @truncate(v) },
            .UInt => .{ .UInt = @truncate(v) },
            .ULong => .{ .ULong = v },
            else => .{ .ULong = v },
        };
    }

    /// The key prefix for member lookups in the stdlib registry.
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
            .Array => |a| if (a.primKind()) |k| k.typeFqn() else "kotlin.Array",
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

    pub fn renderDouble(allocator: std.mem.Allocator, d: f64) ![]u8 {
        return float_fmt.kotlinDoubleToString(allocator, d);
    }

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

    /// `name` may be simple or fully-qualified. Shared by `isRuntimeType` and
    /// the VM's `instanceOf`.
    pub fn builtinThrowableIsA(fqn: []const u8, name: []const u8) bool {
        const tail = lastSegment(fqn);
        if (std.mem.eql(u8, tail, name)) return true;
        if (matchesAny(name, &.{ "Throwable", "Any" })) return true;
        if (std.mem.eql(u8, fqn, name)) return true;
        // `Error`-side throwables are not `Exception`s, and the reverse.
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
        // `NumberFormatException : IllegalArgumentException`, so a `catch (e:
        // IllegalArgumentException)` around `toInt()` takes the host failure.
        if (std.mem.eql(u8, name, "IllegalArgumentException") and std.mem.eql(u8, tail, "NumberFormatException")) return true;
        return false;
    }

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
            // A step-1 `..` range is an XRange and a ClosedRange; a stepped
            // progression is only an XProgression.
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
            .MapEntry => matchesAny(name, &.{ "Entry", "MapEntry", "Map.Entry", "MutableEntry", "MutableMap.MutableEntry", "Any" }),
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
                // The shared scratch buffer avoids threading an allocator in.
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
                break :blk if (a.primKind()) |p| switch (p) {
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

    /// Kotlin `isEmpty()`: a positive step needs `start <= end`.
    fn rangeIsEmptyVal(r: anytype) bool {
        return !r.kind.inBounds(r.start, r.end, r.step);
    }

    /// Whether it takes part in the `Map.Entry` equality contract.
    fn instanceImplementsMapEntry(inst: ObjRef(InstanceData)) bool {
        const cls = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().class;
        };
        // A property of the class, and every `==` between instances asks it.
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

    /// The returned values are copies of the component slots, whose handles
    /// stay owned by the source value; the caller keeps that alive.
    fn mapEntryParts(v: *const Value) ?struct { key: Value, value: Value } {
        switch (v.*) {
            .MapEntry => |e| return .{ .key = e.key.asPtr().*, .value = e.value.asPtr().* },
            .Instance => |inst| {
                if (!instanceImplementsMapEntry(inst)) return null;
                const g = inst.borrow();
                defer g.deinit();
                // These come from the primary constructor's `override val`s.
                const k = g.get().get("key") orelse return null;
                const val = g.get().get("value") orelse return null;
                return .{ .key = k, .value = val };
            },
            else => return null,
        }
    }

    /// Two entries are equal iff their keys and values are, in either
    /// direction. Null when the contract does not apply.
    pub fn mapEntryContractEq(a: *const Value, b: *const Value) ?bool {
        const ap = mapEntryParts(a) orelse return null;
        const bp = mapEntryParts(b) orelse return null;
        return structuralEqBoxed(&ap.key, &bp.key) and structuralEqBoxed(&ap.value, &bp.value);
    }

    /// A boxed type matches only its own type, elements included.
    pub fn structuralEqBoxed(a: *const Value, b: *const Value) bool {
        // A builtin `MapEntry` and a user `Map.Entry` instance compare by key
        // and value, so `map.entries.contains(e)` works across concrete types.
        // Gated on one side being builtin, so two instances keep `equals`.
        if (a.* == .MapEntry or b.* == .MapEntry) {
            if (mapEntryContractEq(a, b)) |eq| return eq;
        }
        switch (a.*) {
            // `Double.equals` compares `toBits`: NaNs are equal, `0.0 != -0.0`.
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
            // Kotlin does not override `Throwable.equals`.
            .Exception => if (b.* == .Exception) return referenceEq(a, b),
            else => {},
        }
        if (a.isNumeric() and b.isNumeric()) return false;
        return structuralEq(a, b);
    }

    /// The callable a `fun interface` SAM wrapper holds, else null.
    pub fn samTargetOf(v: *const Value) ?Value {
        if (v.* != .Instance) return null;
        const g = v.Instance.borrow();
        defer g.deinit();
        return g.get().get("__sam_target__");
    }

    pub fn structuralEq(a: *const Value, b: *const Value) bool {
        // A SAM wrapper equals the callable it wraps: conversion happens at
        // call boundaries and is timing-dependent, so equality must see through
        // it exactly as Kotlin sees one converted value.
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
                if (IrClosureRef.ptrEq(x, b.IrClosure)) break :blk true;
                // A non-capturing lambda literal is a singleton in Kotlin, but
                // klio gives each evaluation its own closure id.
                if (objcell.gc.closureSingletonHook) |h| {
                    const sa = h(x.asPtr().id);
                    if (sa != 0 and sa == h(b.IrClosure.asPtr().id)) break :blk true;
                }
                break :blk false;
            },
            .Comparator => |x| b.* == .Comparator and
                ObjRef([]ComparatorStep).ptrEq(x.steps, b.Comparator.steps) and
                x.descending == b.Comparator.descending,
            .BoundMethod => |x| b.* == .BoundMethod and std.mem.eql(u8, x.fqn, b.BoundMethod.fqn) and structuralEq(x.receiver.asPtr(), b.BoundMethod.receiver.asPtr()),
            .Instance => |x| b.* == .Instance and instanceEq(x, b.Instance),
            // StringBuilder declares no equals override, so identity.
            .StringBuilder => |x| b.* == .StringBuilder and x.identity() == b.StringBuilder.identity(),
            // `intArrayOf(1) == intArrayOf(1)` is false; `contentEquals`
            // compares content.
            .Array => |x| b.* == .Array and x.identity() == b.Array.identity(),
            .Sequence => |x| b.* == .Sequence and ObjRef(SequenceData).ptrEq(x, b.Sequence),
            else => false,
        };
    }

    /// Kotlin referential identity (`===`).
    pub fn referenceEq(a: *const Value, b: *const Value) bool {
        switch (a.*) {
            .Instance => |x| return b.* == .Instance and ObjRef(InstanceData).ptrEq(x, b.Instance),
            .Exception => |x| {
                if (b.* != .Exception) return false;
                // A throwable built through a constructor carries a fresh
                // identity; one built elsewhere has identity 0.
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

    /// Address-stable identity, for use as a `synchronized` monitor key.
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
                // Endpoints render in the element type: a Char range shows
                // characters, a ULong range unsigned values.
                try writeRangeEndpoint(writer, r.kind, r.start);
                if (r.step == 1 and !r.progression) {
                    try writer.writeAll("..");
                    try writeRangeEndpoint(writer, r.kind, r.end);
                } else if (r.step > 0) {
                    try writer.writeAll("..");
                    try writeRangeEndpoint(writer, r.kind, r.end);
                    try writer.print(" step {d}", .{r.step});
                } else {
                    try writer.writeAll(" downTo ");
                    try writeRangeEndpoint(writer, r.kind, r.end);
                    try writer.print(" step {d}", .{-r.step});
                }
            },
            .IrClosure => |c| try writer.print("{{ir-closure#{d}}}", .{c.asPtr().id}),
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
                const tag = if (a.primKind()) |k| k.typeFqn() else "kotlin.Array";
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
                // `KClass.toString()` renders the qualified name.
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

    /// Re-read a primitive-array `.asList()` view's element cache from the
    /// backing array, so a later array write shows through. Fixed-size, so it
    /// overwrites the scalar slots in place. A no-op for anything else: a
    /// reference `Array<T>.asList()` shares the boxed buffer and has no
    /// backing.
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

    /// Whether the backing changed structurally other than through this view
    /// or a descendant.
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

    /// Re-read a `subList` window's cache from the parent, so a parent write
    /// shows through. In place and clamped; a parent structural change made
    /// elsewhere fails fast via the shared mod_count.
    pub fn refreshSublistView(self: *const Value) void {
        if (self.* != .List) return;
        // Overwriting owned slots under a borrow is correct only where retain
        // and release are no-ops: the arena, and the GC, which reaches the
        // parent through the backing edge.
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

pub const ComparatorStep = struct {
    selector: Value,
    descending: bool,
    /// Compares the selected keys with this comparator rather than in natural
    /// order. Null for the plain `compareBy(selector)` forms.
    key_comparator: ?Value = null,
    pub fn gcTrace(self: *const ComparatorStep, m: *objcell.gc.Marker) void {
        self.selector.gcMark(m);
        if (self.key_comparator) |kc| kc.gcMark(m);
    }
};

/// High bit of a shared structural counter, set when a builder freezes its live
/// views at `build()`. Masked out of comparisons, so a leaked but unmodified
/// builder view still reads.
pub const FROZEN_MOD_BIT: u64 = 1 << 63;

/// Refreshes the parent view first, so a root write shows through a whole
/// `subList().subList()` chain. Structural growth flows the other way.
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
        // Kotlin's AbstractCollection.toString prints `(this Collection)` for
        // an element that is the collection itself, bounding the recursion.
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

/// A nested class lifts to a flat mangle (`Outer$Data`) while Kotlin shows
/// `Data`, and `$` cannot occur in a source class name, so the tail after the
/// last `$` then `.` is that name.
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

/// One class can sit in the class table under two spellings of its fqn, the
/// dotted nesting (`Outer.B`) and the lifted mangle (`Outer$B`).
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

/// Runtime error data, never a Zig `error`: the control-flow signals are
/// variants of it. Heap-owning payloads borrow the interpreter's arena.
pub const RuntimeError = union(enum) {
    Unbound: []const u8,
    Type: []const u8,
    Arity: []const u8,
    NoMain,
    Unimplemented: []const u8,
    /// A function body was entered and failed to resolve an operation. Distinct
    /// from the `Unimplemented` dispatch-miss sentinel, so a candidate that
    /// already ran is never retried; this error always propagates.
    CalleeFailed: []const u8,

    Return: Value,
    LabeledReturn: struct { label: []const u8, value: Value },
    Break,
    LabeledBreak: []const u8,
    Continue,
    LabeledContinue: []const u8,
    Thrown: Value,
    /// Evaluated arguments and optional names for the next iteration.
    TailContinue: struct { args: []Value, names: []?[]const u8 },
    TailJump: struct { callee: Value, args: []Value, names: []?[]const u8 },
    /// Wakes after that many virtual ms.
    Suspend: i64,
};

/// OOM stays a Zig `error`; this carries the `RuntimeError` path.
pub const EvalResult = union(enum) {
    ok: Value,
    err: RuntimeError,
};

/// Stdlib container creators whose call-site type arguments name the element
/// type they build. That is the only place an empty container's element type is
/// written, so the value records the head name for receiver proofs and overload
/// refinement. Head names only.
const elem_typed_creators = [_][]const u8{
    "listOf",       "mutableListOf", "emptyList",     "arrayListOf", "listOfNotNull",
    "buildList",    "setOf",         "mutableSetOf",  "emptySet",    "hashSetOf",
    "linkedSetOf",  "sortedSetOf",   "buildSet",      "arrayOf",     "emptyArray",
    "arrayOfNulls", "sequenceOf",    "emptySequence",
};

const pair_typed_creators = [_][]const u8{
    "mapOf", "mutableMapOf", "emptyMap", "hashMapOf", "linkedMapOf", "sortedMapOf", "buildMap",
};

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

/// Coerce a numeric literal element to the container's explicit element type,
/// so `listOf<Byte>(1, 2)` stores `Byte`s. This is kotlinc's type-directed
/// conversion, without which a `List<Byte>` would not equal one built from a
/// `ByteArray`.
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

/// Only `kotlin*` creators qualify, so a user `listOf` does not, and the
/// `type_args` strings must outlive the value.
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



