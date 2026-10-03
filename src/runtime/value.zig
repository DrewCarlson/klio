//! The runtime `Value` model: the tagged union every interpreter and stdlib
//! path evaluates against, its helper types, and `RuntimeError`. `ObjRef(T)` is
//! the refcounted, lock-mediated cell; `*Value` an owning pointer to one boxed
//! value; `*const ast.X` a borrow from the parse/lower arena.

const std = @import("std");
const ast = @import("ast");
const objcell = @import("objcell.zig");
const weak_mod = @import("weak.zig");
const slab = @import("slab.zig");
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
const SubtypeTls = struct {
    scratch: [16 * 1024]u8 align(16) = undefined,
    /// A class's `Map.Entry`-ness is fixed by its supertype graph.
    map_entry_memo: [512]MapEntryMemoSlot = @splat(.{}),
};
const subtype_tls = @import("tls_fast.zig").PerThread(SubtypeTls);
threadlocal var subtype_scratch_busy: bool = false;

const MapEntryMemoSlot = struct { key: usize = 0, val: bool = false };

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
        self.fba = std.heap.FixedBufferAllocator.init(&subtype_tls.get().scratch);
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

    /// The UTF-16 code unit at index `i`, or null when `i` is past the end.
    ///
    /// The walk resumes from `cursor`, so a sequential `s[i]` loop over a
    /// non-ASCII string stays linear rather than quadratic.
    pub fn utf16UnitAt(self: *const StringData, i: usize) ?u16 {
        if (self.ascii) return if (i < self.bytes.len) @as(u16, self.bytes[i]) else null;
        var n: usize = 0;
        var it = Utf16View{ .bytes = self.bytes };
        const c = self.cursorGet();
        if (c.u16_pos <= i and c.byte_pos <= self.bytes.len) {
            n = c.u16_pos;
            it.pos = c.byte_pos;
        }
        while (true) {
            const start = it.pos;
            const u = it.next() orelse return null;
            if (it.pending_low) |low| {
                if (n == i or n + 1 == i) {
                    self.cursorSet(n, start);
                    return if (n == i) u else low;
                }
                _ = it.next();
                n += 2;
            } else {
                if (n == i) {
                    self.cursorSet(n, start);
                    return u;
                }
                n += 1;
            }
        }
    }

    /// Nothing ever takes an exclusive borrow of an immutable string, so this
    /// marker elides the reader lock; see `objcell.LockFor`.
    pub const objref_immutable = true;

    /// A string made in one allocation keeps its bytes after its cell (`strInitTrailing`).
    pub const Trailing = u8;

    pub fn adoptTrailing(self: *StringData, elems: []u8) void {
        self.bytes = elems;
    }

    /// The bytes after the cell that go with it when it is freed.
    pub fn trailingBytes(self: *const StringData) usize {
        return if (self.inCell()) self.bytes.len else 0;
    }

    /// Whether the bytes are the ones after the string's own cell, which go with it.
    fn inCell(self: *const StringData) bool {
        const cell: *const StringRef.Cell = @alignCast(@fieldParentPtr("data", self));
        return self.bytes.ptr == @as([*]const u8, @ptrCast(cell)) + @sizeOf(StringRef.Cell);
    }

    pub fn gcFinalize(self: *StringData, a: std.mem.Allocator) void {
        if (!self.inCell()) a.free(self.bytes);
    }
    pub fn gcNeedsFinalize(self: *const StringData) bool {
        return self.bytes.len != 0 and !self.inCell();
    }
    pub fn deinit(self: *StringData, a: std.mem.Allocator) void {
        if (!self.inCell()) a.free(self.bytes);
    }
    pub fn gcExternalBytes(self: *const StringData) usize {
        return if (self.inCell()) 0 else self.bytes.len;
    }
};

/// A string's UTF-16 code units, decoded from its WTF-8 bytes. An astral
/// scalar yields its surrogate pair across two `next` calls.
pub const Utf16View = struct {
    bytes: []const u8,
    pos: usize = 0,
    pending_low: ?u16 = null,

    pub fn next(self: *Utf16View) ?u16 {
        if (self.pending_low) |low| {
            self.pending_low = null;
            return low;
        }
        if (self.pos >= self.bytes.len) return null;
        if (float_fmt.isWtf8SurrogateAt(self.bytes, self.pos)) {
            const unit = float_fmt.wtf8SurrogateUnit(self.bytes, self.pos);
            self.pos += 3;
            return unit;
        }
        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.pos]) catch {
            const unit: u16 = self.bytes[self.pos];
            self.pos += 1;
            return unit;
        };
        if (self.pos + len > self.bytes.len) {
            const unit: u16 = self.bytes[self.pos];
            self.pos += 1;
            return unit;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.pos .. self.pos + len]) catch {
            const unit: u16 = self.bytes[self.pos];
            self.pos += 1;
            return unit;
        };
        self.pos += len;
        if (cp <= 0xFFFF) return @intCast(cp);
        const adjusted = cp - 0x10000;
        const high: u16 = @intCast(0xD800 + (adjusted >> 10));
        const low: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
        self.pending_low = low;
        return high;
    }
};

/// Reader-side memo for one string builder: ASCII-ness, UTF-16 length and a
/// cursor, keyed by the builder's cell and buffer identity. Every mutating
/// builtin and every construction invalidates it, so a read-only phase costs
/// O(1) per read instead of re-encoding the whole buffer.
///
/// A builder has no immutable header to hang this on the way `StringData`
/// does, so it lives here, beside the walk both readers share.
pub const SbMemo = struct {
    cell: usize = 0,
    ptr: [*]const u8 = undefined,
    len: usize = 0,
    ascii: bool = false,
    u16_len: usize = 0,
    u16_pos: usize = 0,
    byte_pos: usize = 0,
};
/// Per thread, the owner's an ordinary global (`tls_fast`): a builder append
/// reads it a few times.
const sb_memo_tls = tls_fast.PerThread(SbMemo);

/// A builder whose header word (`GcHeader.gc_aux`) equals its length in bytes is ASCII
/// throughout, so that length is its length in UTF-16 units with no scan and no
/// memo. An ASCII append to such a builder keeps it so, and a length that scanned
/// sets it; every other change forgets it (`sbMemoInvalidate`). An empty builder
/// starts known.
const sb_unknown: u32 = std.math.maxInt(u32);

/// The builder at `cell`'s length when its bytes are known ASCII.
pub inline fn sbAsciiLen(cell: usize, len: usize) ?usize {
    const h: *const objcell.gc.GcHeader = @ptrFromInt(cell);
    if (len >= sb_unknown or @atomicLoad(u32, &h.gc_aux, .monotonic) != len) return null;
    return len;
}

inline fn sbSetAscii(cell: usize, len: usize) void {
    const h: *objcell.gc.GcHeader = @ptrFromInt(cell);
    @atomicStore(u32, &h.gc_aux, if (len < sb_unknown) @intCast(len) else sb_unknown, .monotonic);
}

/// After a change that left builder `cell` ASCII throughout and `len` bytes long: its length
/// known with no scan, and a memo of what it held before dropped.
pub fn sbMemoAscii(cell: usize, len: usize) void {
    sbSetAscii(cell, len);
    const sb_memo = sb_memo_tls.get();
    if (sb_memo.cell == cell) sb_memo.cell = 0;
}

pub fn sbMemoInvalidate(cell: usize) void {
    sbSetAscii(cell, sb_unknown);
    const sb_memo = sb_memo_tls.get();
    if (sb_memo.cell == cell) sb_memo.cell = 0;
}

/// Carries the memo over an append of `piece` to builder `cell`, whose
/// buffer was `before_ptr`/`before_len` and is `after` now: the length and
/// the ASCII flag follow from the memo's and the piece's, and the cursor's
/// position is unmoved. A memo of another builder, or of the buffer as it
/// was before some other change, is dropped.
pub fn sbMemoAppended(cell: usize, before_ptr: [*]const u8, before_len: usize, after: []const u8, piece: []const u8) void {
    var ascii = true;
    for (piece) |b| {
        if (b >= 0x80) {
            ascii = false;
            break;
        }
    }
    if (ascii and sbAsciiLen(cell, before_len) != null) {
        // Known ASCII answers the length; a memo left behind no longer
        // matches the buffer, so it is not read again.
        sbSetAscii(cell, after.len);
        return;
    }
    sbSetAscii(cell, sb_unknown);
    const sb_memo = sb_memo_tls.get();
    if (sb_memo.cell != cell) return;
    if (sb_memo.ptr != before_ptr or sb_memo.len != before_len) {
        sb_memo.cell = 0;
        return;
    }
    sb_memo.ptr = after.ptr;
    sb_memo.len = after.len;
    sb_memo.u16_len += if (ascii) piece.len else sbCharCount(piece);
    sb_memo.ascii = sb_memo.ascii and ascii;
}

pub fn sbMemoFor(cell: usize, items: []const u8) *SbMemo {
    const sb_memo = sb_memo_tls.get();
    if (sb_memo.cell == cell and sb_memo.ptr == items.ptr and sb_memo.len == items.len) return sb_memo;
    var ascii = true;
    for (items) |b| {
        if (b >= 0x80) {
            ascii = false;
            break;
        }
    }
    if (ascii) sbSetAscii(cell, items.len);
    sb_memo.* = .{
        .cell = cell,
        .ptr = items.ptr,
        .len = items.len,
        .ascii = ascii,
        .u16_len = if (ascii) items.len else sbCharCount(items),
    };
    return sb_memo;
}

const decimal_pairs = blk: {
    var t: [200]u8 = undefined;
    for (0..100) |i| {
        t[2 * i] = '0' + @as(u8, @intCast(i / 10));
        t[2 * i + 1] = '0' + @as(u8, @intCast(i % 10));
    }
    break :blk t;
};

/// `x` in decimal, as `toString` writes it, at the end of `buf`: two digits a
/// division.
pub fn decimal(buf: *[20]u8, x: i64) []const u8 {
    var u: u64 = if (x < 0) 0 -% @as(u64, @bitCast(x)) else @intCast(x);
    var i: usize = buf.len;
    while (u >= 100) {
        const r: usize = @intCast(u % 100);
        u /= 100;
        i -= 2;
        buf[i..][0..2].* = decimal_pairs[2 * r ..][0..2].*;
    }
    if (u >= 10) {
        i -= 2;
        buf[i..][0..2].* = decimal_pairs[2 * u ..][0..2].*;
    } else {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(u));
    }
    if (x < 0) {
        i -= 1;
        buf[i] = '-';
    }
    return buf[i..];
}

test "decimal writes every Long as toString does" {
    var buf: [20]u8 = undefined;
    for ([_]i64{ 0, 7, -7, 10, 99, 100, -100, 12345, std.math.maxInt(i32), std.math.minInt(i32), std.math.maxInt(i64), std.math.minInt(i64) }) |x| {
        var want: [24]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{d}", .{x}), decimal(&buf, x));
    }
}

test "a builder appended only ASCII is known ASCII at its length, and any other change forgets it" {
    const a = testing.allocator;
    const sb = try ObjRef(std.ArrayList(u8)).init(a, .empty);
    defer sb.deinit();
    const cell = @intFromPtr(sb.cell);
    const buf = &sb.cell.data;
    try testing.expectEqual(@as(?usize, 0), sbAsciiLen(cell, 0));
    for ([_][]const u8{ "ab", "cde" }) |piece| {
        const before_ptr = buf.items.ptr;
        const before_len = buf.items.len;
        try buf.appendSlice(a, piece);
        sbMemoAppended(cell, before_ptr, before_len, buf.items, piece);
    }
    try testing.expectEqual(@as(?usize, 5), sbAsciiLen(cell, buf.items.len));
    // A non-ASCII piece: the length is the memo's to count.
    const before_len = buf.items.len;
    try buf.appendSlice(a, "é");
    sbMemoAppended(cell, buf.items.ptr, before_len, buf.items, "é");
    try testing.expect(sbAsciiLen(cell, buf.items.len) == null);
    try testing.expectEqual(@as(usize, 6), sbMemoFor(cell, buf.items).u16_len);
    // Back to ASCII by a change the memo is told of; a count of it knows it again.
    sbMemoInvalidate(cell);
    buf.shrinkRetainingCapacity(2);
    try testing.expect(sbAsciiLen(cell, buf.items.len) == null);
    try testing.expectEqual(@as(usize, 2), sbMemoFor(cell, buf.items).u16_len);
    try testing.expectEqual(@as(?usize, 2), sbAsciiLen(cell, buf.items.len));
}

/// The builder's length in UTF-16 code units.
pub fn sbCharCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (float_fmt.isWtf8SurrogateAt(s, i)) {
            n += 1;
            i += 3;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch s[i];
        n += if (cp > 0xFFFF) 2 else 1;
        i = end;
    }
    return n;
}

/// The UTF-16 code unit at `idx` in a builder's buffer, resuming from the
/// memo's cursor so a sequential read stays linear.
pub fn sbUnitAt(m: *SbMemo, s: []const u8, idx: usize) ?u16 {
    var n: usize = 0;
    var i: usize = 0;
    if (m.u16_pos <= idx and m.byte_pos <= s.len) {
        n = m.u16_pos;
        i = m.byte_pos;
    }
    while (i < s.len) {
        if (float_fmt.isWtf8SurrogateAt(s, i)) {
            if (n == idx) {
                m.u16_pos = n;
                m.byte_pos = i;
                return (@as(u16, s[i] & 0x0F) << 12) | (@as(u16, s[i + 1] & 0x3F) << 6) | @as(u16, s[i + 2] & 0x3F);
            }
            n += 1;
            i += 3;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch s[i];
        const units: usize = if (cp > 0xFFFF) 2 else 1;
        if (idx < n + units) {
            m.u16_pos = n;
            m.byte_pos = i;
            if (cp <= 0xFFFF) return @intCast(cp);
            const v = cp - 0x10000;
            return if (idx == n) @intCast(0xD800 + (v >> 10)) else @intCast(0xDC00 + (v & 0x3FF));
        }
        n += units;
        i = end;
    }
    return null;
}

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

/// A string of `len` bytes after its cell, in one allocation, for the caller to write, with
/// its UTF-16 length and whether it is ASCII, before any other thread can see it.
pub fn strInitTrailing(allocator: std.mem.Allocator, len: usize) std.mem.Allocator.Error!StringRef {
    return StringRef.initTrailing(allocator, .{ .bytes = &.{}, .u16_len = 0, .ascii = true }, len);
}

/// Under the GC and reclaim backends the cell owns a private copy of `bytes`, after it in the
/// same allocation; under the pure arena the slice is adopted as-is.
pub fn strInit(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!StringRef {
    if (objcell.reclaimEnabled() or objcell.gc.gc_enabled) {
        const ref = try strInitTrailing(allocator, bytes.len);
        const d = ref.asPtr();
        @memcpy(@constCast(d.bytes), bytes);
        const m = strMeta(bytes);
        d.u16_len = m.u16_len;
        d.ascii = m.ascii;
        return ref;
    }
    const m = strMeta(bytes);
    return StringRef.initOwned(allocator, .{ .bytes = bytes, .u16_len = m.u16_len, .ascii = m.ascii });
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
/// is one pointer and closure identity is cell identity. Both are set when the
/// closure is made and never written after, so the cell takes no lock.
pub const IrClosureData = struct {
    pub const objref_immutable = true;

    /// The closure's slot in its program's closure table. This cell is the
    /// id's only holder, so the slot is released when the cell is swept.
    id: u64,
    /// The generation of the closure table `id` indexes: a sweep releases the
    /// slot only into that table, never into a later program's. 0 names none.
    table: u64 = 0,
    captures: []Value,
    /// The record of the function literal or reference the closure was made from, shared
    /// by every closure of it and held by the program; null for a closure whose table
    /// slot holds its record.
    body: ?*const anyopaque = null,

    /// A closure made in one allocation keeps its captures after its cell
    /// (`IrClosureRef.initTrailing`).
    pub const Trailing = Value;

    pub fn adoptTrailing(self: *IrClosureData, elems: []Value) void {
        self.captures = elems;
    }

    /// Whether the captures are the ones after the closure's own cell, which go with it.
    fn inCell(self: *const IrClosureData) bool {
        const cell: *const IrClosureRef.Cell = @alignCast(@fieldParentPtr("data", self));
        return @intFromPtr(self.captures.ptr) == @intFromPtr(cell) + @sizeOf(IrClosureRef.Cell);
    }

    /// The captures after the cell that go with it when it is freed.
    pub fn trailingBytes(self: *const IrClosureData) usize {
        return if (self.inCell()) self.captures.len * @sizeOf(Value) else 0;
    }

    /// Without this hook the captures read as a leaf and are swept while live.
    pub fn gcTrace(self: *const IrClosureData, m: *objcell.gc.Marker) void {
        for (self.captures) |*c| c.gcMark(m);
    }

    pub fn gcFinalize(self: *IrClosureData, a: std.mem.Allocator) void {
        if (closureReleaseHook) |f| f(self.table, self.id);
        if (!self.inCell()) a.free(self.captures);
    }
    /// A closure over a function literal's record holds no table slot.
    pub fn gcNeedsFinalize(self: *const IrClosureData) bool {
        return self.table != 0 or (self.captures.len != 0 and !self.inCell());
    }
};
pub const IrClosureRef = ObjRef(IrClosureData);

/// Frees the closure-table slot of a swept closure: `(table generation, id)`.
/// Set by the interpreter; it runs on whichever thread sweeps the cell.
pub var closureReleaseHook: ?*const fn (table: u64, id: u64) void = null;
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
/// Kotlin's `LinkedHashMap` semantics require, plus a hash index over entry
/// slots. `hashes[i]` is the hash of `slots[i].key` for each slot below
/// `hashes.len`: `keyHash` for a simple key, else the hash the host gave for
/// it (an instance's `hashCode()`), taken once as a `HashMap` node keeps it.
/// Entries past it are hashed on the next lookup that needs them. `buckets`,
/// a power of two long, maps a hash's low bits to one past the newest indexed
/// slot whose hash has them, and `chain[i]` links slot `i` to one past the
/// next older one in its bucket, 0 ending it; a lookup compares the stored
/// hash before the key. They cover the first `chain.len` hashes. Maps below
/// `index_threshold` are scanned instead.
///
/// Removing an indexed entry leaves a hole in its slot, as a `LinkedHashMap`
/// unlinks a node without touching the others: the slot leaves its bucket, its
/// `chain` link becomes `hole` and its key and value `Unit`. The entries in
/// order are the slots that are not holes (`live`, `len`); `compact` closes the
/// holes up, and a reader that wants the entries as one slice (`dense`) reads
/// them after it.
pub const MapStore = struct {
    slots: std.ArrayList(MapPair) = .empty,
    hashes: std.ArrayList(u64) = .empty,
    buckets: []u32 = &.{},
    chain: std.ArrayList(u32) = .empty,
    /// How many of `slots` are holes, all below `chain.len`.
    holes: usize = 0,
    /// How many of the first slots are holes: a walk in order starts past them.
    head: usize = 0,
    /// Counts the times the entries moved to other slots (`compact`, `clear`, a removal
    /// past the index), so a walk over the slots finds its place again by how many
    /// entries it has passed.
    epoch: u32 = 0,
    /// Per slot, once an entry object was made of one (`tracking`), the entry object of
    /// the node standing there, null until one is made (`nodeEntry`). A node is a key's
    /// place from its insertion until its removal, which a later insertion of the key
    /// does not take over, as a JVM `HashMap`'s node, which is its own `Map.Entry`: every
    /// walk over the entries hands out the same object, and when the node leaves the map
    /// the object takes its last value and the store lets it go.
    nodes: std.ArrayList(?*MapEntryRef.Cell) = .empty,
    tracking: bool = false,
    /// The map a `buildMap` builds, while it builds: its entries fail fast after a
    /// structural change, as `MapBuilder`'s do.
    builder: bool = false,
    /// A key neither `keyHash` nor the host can hash (a lambda): lookups scan
    /// until the map is cleared.
    unhashable: bool = false,
    /// Structural-modification counter for fail-fast iteration, shared with
    /// every `keys`, `values` and `entries` view. Null for a read-only map.
    mod_count: objcell.OptRef(ModCount) = .{},

    /// Below this count a linear scan beats a hash table, so no index is built.
    pub const index_threshold: usize = 16;

    /// A hole's `chain` link, which no slot of a map that fits in memory reaches.
    pub const hole: u32 = std.math.maxInt(u32);

    /// Writers turn the cell's sequence, so a lookup takes no lock
    /// (`lookupNoLock`).
    pub const objref_sequenced = true;

    pub fn deinit(self: *MapStore, a: std.mem.Allocator) void {
        for (self.nodes.items) |n| if (n) |c| (MapEntryRef{ .cell = c }).deinit();
        self.nodes.deinit(a);
        self.slots.deinit(a);
        self.hashes.deinit(a);
        a.free(self.buckets);
        self.chain.deinit(a);
        if (self.mod_count.get()) |mc| mc.deinit();
    }

    pub fn gcFinalize(self: *MapStore, a: std.mem.Allocator) void {
        self.deinit(a);
    }

    pub fn gcTrace(self: *const MapStore, m: *objcell.gc.Marker) void {
        // A hole holds `Unit`, which marks nothing.
        for (self.slots.items) |*kv| kv.gcTrace(m);
        for (self.nodes.items) |n| if (n) |c| m.shade(&c.hdr);
        if (self.mod_count.get()) |mc| m.shade(&mc.cell.hdr);
        // The lines of the arrays the region holds (`gc.buffer_allocator`).
        m.markBuffer(@intFromPtr(self.slots.items.ptr), self.slots.capacity * @sizeOf(MapPair));
        m.markBuffer(@intFromPtr(self.nodes.items.ptr), self.nodes.capacity * @sizeOf(?*MapEntryRef.Cell));
        m.markBuffer(@intFromPtr(self.hashes.items.ptr), self.hashes.capacity * @sizeOf(u64));
        m.markBuffer(@intFromPtr(self.chain.items.ptr), self.chain.capacity * @sizeOf(u32));
        m.markBuffer(@intFromPtr(self.buckets.ptr), self.buckets.len * @sizeOf(u32));
    }

    /// Consistent with `Value.structuralEqBoxed`: equal keys hash equal, and
    /// the type tag is mixed in so `5` and `5L` differ. Null for a key that is
    /// not simple-hashable, which only the host can hash.
    pub fn keyHash(k: *const Value) ?u64 {
        return switch (k.*) {
            .Int => |x| intHash(x),
            .Long => |x| mixKey(2, @bitCast(x)),
            .Short => |x| mixKey(3, @as(u16, @bitCast(x))),
            .Byte => |x| mixKey(4, @as(u8, @bitCast(x))),
            .UInt => |x| mixKey(5, x),
            .ULong => |x| mixKey(6, x),
            .UShort => |x| mixKey(7, x),
            .UByte => |x| mixKey(8, x),
            .Bool => |x| mixKey(9, @intFromBool(x)),
            .Char => |x| mixKey(10, x),
            .Double => |x| mixKey(11, @bitCast(x)),
            .Float => |x| mixKey(12, @as(u32, @bitCast(x))),
            .Null => mixKey(13, 0),
            .String => |sref| blk: {
                const sg = sref.borrow();
                defer sg.deinit();
                break :blk std.hash.Wyhash.hash(14, sg.get().bytes);
            },
            // A pair or triple of simple values compares component by component
            // (`structuralEqBoxed`): its components' hashes, mixed in order.
            .Pair => |p| mixKey(15, (keyHash(p.first.asPtrConst()) orelse return null) ^
                std.math.rotl(u64, keyHash(p.second.asPtrConst()) orelse return null, 23)),
            .Triple => |t| mixKey(16, (keyHash(t.first.asPtrConst()) orelse return null) ^
                std.math.rotl(u64, keyHash(t.second.asPtrConst()) orelse return null, 23) ^
                std.math.rotl(u64, keyHash(t.third.asPtrConst()) orelse return null, 46)),
            else => null,
        };
    }

    /// An Int key's hash, as `keyHash` answers it.
    pub inline fn intHash(x: i32) u64 {
        return mixKey(1, @as(u32, @bitCast(x)));
    }

    /// A scalar key's hash: its bits and its kind, mixed (splitmix64's
    /// finalizer), so an Int and a Long of one value land apart.
    inline fn mixKey(kind: u64, bits: u64) u64 {
        var z = bits ^ (kind << 56) ^ 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// How many entries the map holds: its slots that are not holes.
    pub inline fn len(self: *const MapStore) usize {
        return self.slots.items.len - self.holes;
    }

    /// Whether slot `i` is a hole a removal left.
    pub inline fn isHole(self: *const MapStore, i: usize) bool {
        return self.holes != 0 and i < self.chain.items.len and self.chain.items[i] == hole;
    }

    /// The entries in order as one slice, for a store that holds no holes: after
    /// `compact` under the write lock, or under a borrow `borrowDense` took.
    pub fn dense(self: *const MapStore) []MapPair {
        std.debug.assert(self.holes == 0);
        return self.slots.items;
    }

    /// The entries in order, skipping holes.
    pub fn live(self: *const MapStore) Live {
        return .{ .store = self };
    }

    pub const Live = struct {
        store: *const MapStore,
        i: usize = 0,

        /// The next entry's slot.
        pub fn nextSlot(self: *Live) ?usize {
            const st = self.store;
            while (self.i < st.slots.items.len) {
                const i = self.i;
                self.i += 1;
                if (!st.isHole(i)) return i;
            }
            return null;
        }

        pub fn next(self: *Live) ?*MapPair {
            const i = self.nextSlot() orelse return null;
            return &self.store.slots.items[i];
        }
    };

    /// The entries in order, copied into a slice of their own from `a`.
    pub fn liveCopy(self: *const MapStore, a: std.mem.Allocator) std.mem.Allocator.Error![]MapPair {
        if (self.holes == 0) return a.dupe(MapPair, self.slots.items);
        const out = try a.alloc(MapPair, self.len());
        var it = self.live();
        var k: usize = 0;
        while (it.next()) |kv| : (k += 1) out[k] = kv.*;
        return out;
    }

    /// A new store holding this one's entries in order, with the hashes this one keeps for
    /// them, for a map made as a copy of this one (`HashMap(map)`, `toMutableMap`); a
    /// lookup builds its index when it first needs one. The caller retains the entries
    /// where values are counted.
    pub fn copyLive(self: *const MapStore, a: std.mem.Allocator) std.mem.Allocator.Error!MapStore {
        var out: MapStore = .{ .unhashable = self.unhashable };
        errdefer out.deinit(a);
        try out.slots.ensureTotalCapacityPrecise(a, self.len());
        // The hashes cover a run of the first slots, the holes among them.
        try out.hashes.ensureTotalCapacityPrecise(a, @min(self.hashes.items.len, self.len()));
        var it = self.live();
        while (it.nextSlot()) |i| {
            out.slots.appendAssumeCapacity(self.slots.items[i]);
            if (i < self.hashes.items.len) out.hashes.appendAssumeCapacity(self.hashes.items[i]);
        }
        return out;
    }

    /// The first slot from `i` on that is not a hole, or the slots' length.
    pub fn pastHoles(self: *const MapStore, i: usize) usize {
        var p = i;
        if (self.holes != 0) {
            while (p < self.slots.items.len and self.isHole(p)) p += 1;
        }
        return p;
    }

    /// The slot of the entry `n` places from the first, null past the last.
    pub fn slotAt(self: *const MapStore, n: usize) ?usize {
        if (self.holes == 0) return if (n < self.slots.items.len) n else null;
        var it = self.live();
        var k: usize = 0;
        while (it.nextSlot()) |i| : (k += 1) {
            if (k == n) return i;
        }
        return null;
    }

    fn linearFind(self: *const MapStore, key: *const Value) ?usize {
        for (self.slots.items, 0..) |*kv, i| {
            if (!self.isHole(i) and Value.structuralEqBoxed(&kv.key, key)) return i;
        }
        return null;
    }

    /// Adds `kv` after the last entry, hashed now when its key is simple.
    pub fn append(self: *MapStore, a: std.mem.Allocator, kv: MapPair) std.mem.Allocator.Error!void {
        try self.appendHashed(a, kv, keyHash(&kv.key));
    }

    /// Adds `kv` after the last entry, `h` being its key's hash when the
    /// caller took it. A map below `index_threshold` keeps no hashes.
    pub fn appendHashed(self: *MapStore, a: std.mem.Allocator, kv: MapPair, h: ?u64) std.mem.Allocator.Error!void {
        if (self.tracking) try self.nodes.ensureUnusedCapacity(a, 1);
        try self.slots.append(a, kv);
        if (self.tracking) self.nodes.appendAssumeCapacity(null);
        const hsh = h orelse return;
        if (self.slots.items.len < index_threshold or self.hashes.items.len + 1 != self.slots.items.len) return;
        try self.hashes.append(a, hsh);
        if (self.chain.items.len + 1 == self.hashes.items.len) try self.bucket(a, self.chain.items.len);
    }

    /// Removes the entry in slot `i`. An indexed entry leaves a hole and every
    /// other keeps its slot, the last slot's going with the holes before it; one
    /// past the index (in a map too small for one) is taken out, the slots after
    /// it moving down one.
    pub fn removeAt(self: *MapStore, i: usize) MapPair {
        const kv = self.slots.items[i];
        if (self.tracking) self.letGo(i);
        if (i >= self.chain.items.len) {
            _ = self.slots.orderedRemove(i);
            if (self.tracking) _ = self.nodes.orderedRemove(i);
            if (i < self.hashes.items.len) _ = self.hashes.orderedRemove(i);
            // The entries after it moved down a slot.
            self.epoch +%= 1;
            return kv;
        }
        self.unlink(i);
        // An indexed last slot ends all three arrays.
        if (i + 1 == self.slots.items.len) {
            self.dropLast();
            while (self.holes != 0 and self.chain.items[self.chain.items.len - 1] == hole) {
                self.dropLast();
                self.holes -= 1;
            }
            if (self.head > self.slots.items.len) self.head = self.slots.items.len;
            return kv;
        }
        self.chain.items[i] = hole;
        self.slots.items[i] = .{ .key = .Unit, .value = .Unit };
        self.holes += 1;
        // The last slot is never a hole, so the run of leading holes ends before it.
        if (i == self.head) {
            var h = i + 1;
            while (self.isHole(h)) h += 1;
            self.head = h;
        }
        return kv;
    }

    fn dropLast(self: *MapStore) void {
        self.slots.items.len -= 1;
        if (self.tracking) self.nodes.items.len -= 1;
        self.hashes.items.len -= 1;
        self.chain.items.len -= 1;
    }

    /// Takes indexed slot `i` out of its bucket.
    fn unlink(self: *MapStore, i: usize) void {
        const pos: u32 = @intCast(i + 1);
        const next = self.chain.items[i];
        // A bucket runs from its newest slot to its oldest, so what links to
        // `i` is newer than it.
        const first = &self.buckets[self.hashes.items[i] & (self.buckets.len - 1)];
        if (first.* == pos) {
            first.* = next;
            return;
        }
        var slot = first.*;
        while (slot != 0) : (slot = self.chain.items[slot - 1]) {
            if (self.chain.items[slot - 1] == pos) {
                self.chain.items[slot - 1] = next;
                return;
            }
        }
    }

    /// Closes the holes up: each entry moves down past the holes before it, in
    /// order, and the buckets are built again over the slots as they now stand.
    /// The entries' positions change, so a caller walking slots stops first.
    pub fn compact(self: *MapStore) void {
        if (self.holes == 0) return;
        const hashed = self.hashes.items.len - self.holes;
        const indexed = self.chain.items.len - self.holes;
        var w: usize = 0;
        for (0..self.slots.items.len) |r| {
            if (r < self.chain.items.len and self.chain.items[r] == hole) continue;
            self.slots.items[w] = self.slots.items[r];
            if (self.tracking) self.nodes.items[w] = self.nodes.items[r];
            // The holes are all indexed, so the hashed slots stay first.
            if (r < self.hashes.items.len) self.hashes.items[w] = self.hashes.items[r];
            w += 1;
        }
        self.slots.items.len = w;
        if (self.tracking) self.nodes.items.len = w;
        self.hashes.items.len = hashed;
        self.chain.items.len = indexed;
        self.holes = 0;
        self.head = 0;
        self.epoch +%= 1;
        @memset(self.buckets, 0);
        for (self.hashes.items[0..indexed], 0..) |h, j| {
            const b = &self.buckets[h & (self.buckets.len - 1)];
            self.chain.items[j] = b.*;
            b.* = @intCast(j + 1);
        }
    }

    /// `compact` once the holes are as many as the entries, so a removal's share
    /// of the copying stays constant.
    pub fn compactIfSparse(self: *MapStore) void {
        if (self.holes != 0 and self.holes * 2 >= self.slots.items.len) self.compact();
    }

    /// Removes every entry.
    pub fn clear(self: *MapStore) void {
        if (self.tracking) for (0..self.nodes.items.len) |i| self.letGo(i);
        self.slots.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.holes = 0;
        self.head = 0;
        self.epoch +%= 1;
        self.forgetHashes();
    }

    /// The entry object of the node in slot `slot`, which every walk over the entries hands
    /// out (a new reference to it), its value the node's now and `exp_mod` taken as
    /// `stamp`; made through `a` for `entries`, this store, the first time. The store
    /// tracks every slot's node from the first one on, in an array `buf_a` grows, as its
    /// others.
    pub fn nodeEntry(self: *MapStore, buf_a: std.mem.Allocator, a: std.mem.Allocator, entries: MapEntries, slot: usize, stamp: u64) std.mem.Allocator.Error!Value {
        if (!self.tracking) {
            try self.nodes.appendNTimes(buf_a, null, self.slots.items.len);
            self.tracking = true;
        }
        const n = &self.nodes.items[slot];
        const kv = self.slots.items[slot];
        if (n.*) |c| {
            const entry: MapEntryRef = .{ .cell = c };
            const me = &c.data;
            me.exp_mod = stamp;
            me.at = @intCast(slot);
            // The value the entry read last: the node's now.
            me.putValue(kv.value);
            return .{ .MapEntry = &entry.clone().cell.data };
        }
        if (objcell.reclaimEnabled()) {
            kv.key.retain();
            kv.value.retain();
        }
        const entry = try MapEntryRef.init(a, .{
            .key = kv.key,
            .value = kv.value,
            .backing = .from(entries),
            .exp_mod = stamp,
            .at = @intCast(slot),
        });
        // The caller's write borrow of the store took the barrier this store needs.
        n.* = entry.cell;
        return .{ .MapEntry = &entry.clone().cell.data };
    }

    /// The node in slot `i` leaves the map: its entry object, if one was made, takes the
    /// value the node has, and the store's reference to it goes.
    pub fn letGo(self: *MapStore, i: usize) void {
        const c = self.nodes.items[i] orelse return;
        self.nodes.items[i] = null;
        const entry: MapEntryRef = .{ .cell = c };
        c.data.putValue(self.slots.items[i].value);
        entry.deinit();
    }

    /// Drops every hash, for entries rearranged in place (the store holding no
    /// holes): the next lookup through the index hashes them again.
    pub fn forgetHashes(self: *MapStore) void {
        std.debug.assert(self.holes == 0);
        self.hashes.clearRetainingCapacity();
        @memset(self.buckets, 0);
        self.chain.clearRetainingCapacity();
        self.unhashable = false;
    }

    /// The first entry the index lacks a hash for.
    pub fn hashedLen(self: *const MapStore) usize {
        return self.hashes.items.len;
    }

    /// Takes `hs` as the hashes of the entries from `from` on; false when
    /// the entries changed since `from` was read.
    pub fn addHashes(self: *MapStore, a: std.mem.Allocator, from: usize, hs: []const u64) std.mem.Allocator.Error!bool {
        if (self.hashes.items.len != from or from + hs.len > self.slots.items.len) return false;
        try self.hashes.appendSlice(a, hs);
        return true;
    }

    /// The positions of the hashed entries whose hash is `h`, oldest first, into `out`,
    /// which grows through `out_a`; the map's index grows through `a`.
    pub fn bucketOf(self: *MapStore, a: std.mem.Allocator, h: u64, out: *std.ArrayList(u32), out_a: std.mem.Allocator) std.mem.Allocator.Error!void {
        try self.indexHashed(a);
        var slot = self.bucketHead(h);
        while (slot != 0) : (slot = self.chain.items[slot - 1]) {
            if (self.hashes.items[slot - 1] == h) try out.append(out_a, slot - 1);
        }
        std.mem.reverse(u32, out.items);
    }

    /// One past the newest indexed entry in `h`'s bucket, 0 for none; `chain`
    /// gives each next older one. Their hashes share `h`'s low bits only.
    pub inline fn bucketHead(self: *const MapStore, h: u64) u32 {
        if (self.buckets.len == 0) return 0;
        return self.buckets[h & (self.buckets.len - 1)];
    }

    /// Slot `i`, the next to index, into its bucket: the buckets double first
    /// when they would hold more than three slots for every four of them, and
    /// every indexed slot but a hole is put in its new bucket again.
    fn bucket(self: *MapStore, a: std.mem.Allocator, i: usize) std.mem.Allocator.Error!void {
        try self.chain.ensureUnusedCapacity(a, 1);
        if ((i + 1) * 4 > self.buckets.len * 3) {
            const n = @max(64, std.math.ceilPowerOfTwoAssert(usize, (i + 1) * 2));
            const grown = try a.alloc(u32, n);
            a.free(self.buckets);
            self.buckets = grown;
            @memset(self.buckets, 0);
            for (self.hashes.items[0..i], 0..) |h, j| {
                if (self.chain.items[j] == hole) continue;
                const b = &self.buckets[h & (n - 1)];
                self.chain.items[j] = b.*;
                b.* = @intCast(j + 1);
            }
        }
        const b = &self.buckets[self.hashes.items[i] & (self.buckets.len - 1)];
        self.chain.appendAssumeCapacity(b.*);
        b.* = @intCast(i + 1);
    }

    /// Puts every hashed entry in its bucket.
    fn indexHashed(self: *MapStore, a: std.mem.Allocator) std.mem.Allocator.Error!void {
        try self.chain.ensureTotalCapacity(a, self.hashes.items.len);
        while (self.chain.items.len < self.hashes.items.len) try self.bucket(a, self.chain.items.len);
    }

    /// The entry whose key equals `key`, as `find` answers it, reading only:
    /// null when the buckets do not index every entry or the key has no hash,
    /// and `find` must run.
    pub fn findIndexed(self: *const MapStore, key: *const Value) ?(?usize) {
        const n = self.slots.items.len;
        if (self.unhashable or n < index_threshold or self.hashes.items.len != n or self.chain.items.len != n) return null;
        const hsh = keyHash(key) orelse return null;
        var slot = self.bucketHead(hsh);
        while (slot != 0) {
            const i = slot - 1;
            if (self.hashes.items[i] == hsh and Value.structuralEqBoxed(&self.slots.items[i].key, key)) return i;
            slot = self.chain.items[i];
        }
        return @as(?usize, null);
    }

    /// Hashes the entries past the hashes while their keys are simple and puts every hashed
    /// one in its bucket, as a lookup does first: a removal from slot `i` then leaves a
    /// hole where an index covers it. Nothing for a map below `index_threshold`.
    pub fn indexSimple(self: *MapStore, a: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.unhashable or self.slots.items.len < index_threshold) return;
        while (self.hashes.items.len < self.slots.items.len) {
            const kh = keyHash(&self.slots.items[self.hashes.items.len].key) orelse break;
            try self.hashes.append(a, kh);
        }
        try self.indexHashed(a);
    }

    /// The entry whose key equals `key` structurally: through the buckets
    /// for the hashed entries, by a scan of those after them. The entries
    /// with simple keys are hashed first.
    pub fn find(self: *MapStore, a: std.mem.Allocator, key: *const Value) std.mem.Allocator.Error!?usize {
        if (self.unhashable or self.slots.items.len < index_threshold) return self.linearFind(key);
        const hsh = keyHash(key) orelse return self.linearFind(key);
        try self.indexSimple(a);
        var slot = self.bucketHead(hsh);
        while (slot != 0) {
            const i = slot - 1;
            if (self.hashes.items[i] == hsh and Value.structuralEqBoxed(&self.slots.items[i].key, key)) return i;
            slot = self.chain.items[i];
        }
        // No hole is past the hashes.
        const from = self.hashes.items.len;
        for (self.slots.items[from..], from..) |*kv, i| {
            if (Value.structuralEqBoxed(&kv.key, key)) return i;
        }
        return null;
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

/// A walk over a map's entries where they stand, as the JVM's iterator over a map's
/// `entrySet()` walks it: each step takes the store's lock only to read the next entry, so
/// the caller may run Kotlin code between steps (an element's `toString`, a put into
/// another map) with no lock held, and no copy of the entries is made. A step after a
/// structural change since the walk began ends it (`changed`), where the JVM's iterator
/// throws `ConcurrentModificationException`, unless the entry before was the map's last
/// then (`IterCursor.ended`); a compaction, which moves the entries without changing the
/// map, it follows by how many entries it has passed. The caller roots an entry it holds
/// across Kotlin code (`keepalivePushPairs`).
pub const MapWalk = struct {
    entries: MapEntries,
    pos: usize,
    passed: usize = 0,
    epoch: u32,
    stamp: u64,
    ended: bool,

    pub const Step = union(enum) { pair: MapPair, end, changed };

    pub fn init(entries: MapEntries) MapWalk {
        const g = entries.borrow();
        defer g.deinit();
        const st = g.get();
        return .{ .entries = entries, .pos = st.head, .epoch = st.epoch, .stamp = structuralCount(st), .ended = st.len() == 0 };
    }

    pub fn next(self: *MapWalk) Step {
        if (self.ended) return .end;
        const g = self.entries.borrow();
        defer g.deinit();
        const st = g.get();
        if (structuralCount(st) != self.stamp) return .changed;
        if (st.epoch != self.epoch) {
            self.pos = st.slotAt(self.passed) orelse st.slots.items.len;
            self.epoch = st.epoch;
        }
        self.pos = st.pastHoles(self.pos);
        if (self.pos >= st.slots.items.len) return .end;
        const kv = st.slots.items[self.pos];
        self.pos += 1;
        self.passed += 1;
        self.ended = st.pastHoles(self.pos) >= st.slots.items.len;
        return .{ .pair = kv };
    }

    fn structuralCount(st: *const MapStore) u64 {
        const mc = st.mod_count.get() orelse return 0;
        return mc.cell.data.load() & ~FROZEN_MOD_BIT;
    }
};

/// A read borrow of `entries` under which the store holds no holes, so its entries read
/// as one slice (`MapStore.dense`): a store holding some is compacted under the write
/// lock first.
pub fn mapBorrowDense(entries: MapEntries) objcell.ObjGuard(MapStore) {
    while (true) {
        const g = entries.borrow();
        if (g.get().holes == 0) return g;
        g.deinit();
        const w = entries.borrowMut();
        w.get().compact();
        w.deinit();
    }
}

/// The value of the entry whose stored hash is `hsh` and whose key `eq(ctx, key)` says
/// is the one looked up, read with no lock where `objcell.lockfree_reads` holds, in a
/// map whose every entry is in its index. The store's arrays are read between two
/// equal even readings of its write sequence, and each candidate entry again before
/// `eq` looks through its key, so `eq` only sees an entry the map held; arrays a writer
/// replaced stay mapped until a stop, which no lookup spans. Null when a writer
/// overlapped the read, the map is not all indexed, or `eq` gives up (null), which
/// sends the lookup to the lock; `.Null` when no entry matches. An `eq` that
/// dereferences nothing (`derefs` false) compares a candidate as read, the last
/// reading of the sequence vouching for what it answered.
pub fn lookupNoLock(entries: MapEntries, hsh: u64, ctx: anytype, comptime eq: fn (@TypeOf(ctx), *const Value) ?bool, comptime derefs: bool) ?Value {
    const cell = entries.cell;
    const seq = &cell.lock.seq;
    const before = seq.load(.acquire);
    if (before & 1 != 0) return null;
    const st = &cell.data;
    const pairs = sliceWords(&st.slots.items);
    const hashes = sliceWords(&st.hashes.items);
    const buckets = sliceWords(&st.buckets);
    const chain = sliceWords(&st.chain.items);
    const unhashable = @atomicLoad(bool, &st.unhashable, .monotonic);
    objcell.loadFence();
    if (seq.load(.monotonic) != before) return null;
    const n = pairs[1];
    if (unhashable or n < MapStore.index_threshold or hashes[1] != n or chain[1] != n or buckets[1] == 0) return null;
    const pair_at: [*]const MapPair = @ptrFromInt(pairs[0]);
    const hash_at: [*]const u64 = @ptrFromInt(hashes[0]);
    const chain_at: [*]const u32 = @ptrFromInt(chain[0]);
    const bucket_at: [*]const u32 = @ptrFromInt(buckets[0]);
    var slot: usize = @atomicLoad(u32, &bucket_at[@intCast(hsh & (buckets[1] - 1))], .monotonic);
    var steps: usize = 0;
    while (slot != 0) : (steps += 1) {
        // Past the entries, or a chain longer than they are: arrays a writer replaced.
        if (slot > n or steps > n) return null;
        const i = slot - 1;
        if (@atomicLoad(u64, &hash_at[i], .monotonic) == hsh) {
            const words: *const [4]u64 = @ptrCast(&pair_at[i]);
            var kv: MapPair = undefined;
            const out: *[4]u64 = @ptrCast(&kv);
            inline for (0..4) |w| out[w] = @atomicLoad(u64, &words[w], .monotonic);
            if (derefs) {
                objcell.loadFence();
                if (seq.load(.monotonic) != before) return null;
            }
            if (eq(ctx, &kv.key)) |same| {
                if (same) {
                    if (!derefs) {
                        objcell.loadFence();
                        if (seq.load(.monotonic) != before) return null;
                    }
                    return kv.value;
                }
            } else return null;
        }
        slot = @atomicLoad(u32, &chain_at[i], .monotonic);
    }
    objcell.loadFence();
    if (seq.load(.monotonic) != before) return null;
    return .Null;
}

/// How many entries `entries` holds, read with no lock between two equal even readings
/// of its write sequence; null when a writer overlapped the read.
pub fn mapLenNoLock(entries: MapEntries) ?usize {
    const seq = &entries.cell.lock.seq;
    const before = seq.load(.acquire);
    if (before & 1 != 0) return null;
    const st = &entries.cell.data;
    const n = @atomicLoad(usize, &st.slots.items.len, .monotonic) -% @atomicLoad(usize, &st.holes, .monotonic);
    objcell.loadFence();
    if (seq.load(.monotonic) != before) return null;
    return n;
}

/// `lookupNoLock` of Int key `x`: its hash and its compare in line, the rest of a
/// numeric key's lookup.
pub fn lookupIntNoLock(entries: MapEntries, x: i32) ?Value {
    const Eq = struct {
        fn eq(want: i32, k: *const Value) ?bool {
            if (k.* == .Int) return k.Int == want;
            return if (k.isNumeric()) false else null;
        }
    };
    return lookupNoLock(entries, MapStore.intHash(x), x, Eq.eq, false);
}

/// Whether stored key `k` equals the numeric `key` as `structuralEqBoxed`
/// answers it, looking through neither: null where only it can say (a stored
/// key of a kind that is no number).
pub fn numericKeyEq(key: *const Value, k: *const Value) ?bool {
    switch (key.*) {
        .Double => |x| if (k.* == .Double) return (std.math.isNan(x) and std.math.isNan(k.Double)) or @as(u64, @bitCast(x)) == @as(u64, @bitCast(k.Double)),
        .Float => |x| if (k.* == .Float) return (std.math.isNan(x) and std.math.isNan(k.Float)) or @as(u32, @bitCast(x)) == @as(u32, @bitCast(k.Float)),
        .Int => |x| if (k.* == .Int) return x == k.Int,
        .Long => |x| if (k.* == .Long) return x == k.Long,
        .Short => |x| if (k.* == .Short) return x == k.Short,
        .Byte => |x| if (k.* == .Byte) return x == k.Byte,
        .UInt => |x| if (k.* == .UInt) return x == k.UInt,
        .ULong => |x| if (k.* == .ULong) return x == k.ULong,
        .UShort => |x| if (k.* == .UShort) return x == k.UShort,
        .UByte => |x| if (k.* == .UByte) return x == k.UByte,
        else => return null,
    }
    return if (k.isNumeric()) false else null;
}

/// A slice's pointer and length, each read whole.
inline fn sliceWords(s: anytype) [2]usize {
    const w: *const [2]usize = @ptrCast(s);
    return .{ @atomicLoad(usize, &w[0], .monotonic), @atomicLoad(usize, &w[1], .monotonic) };
}

pub const MapData = struct {
    entries: MapEntries,
    mutable: bool,
    /// Declared key and value type heads; see `ListData.declared_elem`.
    declared_key: ?[]const u8 = null,
    declared_value: ?[]const u8 = null,
    /// The map's `keys`, `values` and `entries` views (`MapViews.kt`), by `MapViewKind`,
    /// made on first use and kept, as the JVM's maps keep theirs.
    views: [3]?Value = @splat(null),

    /// Releases the entries' keys and values when this was their last owner.
    pub fn deinit(self: *MapData, allocator: std.mem.Allocator) void {
        // A view holds the entries: the views go first.
        for (&self.views) |*v| if (v.*) |x| {
            x.release(allocator);
            v.* = null;
        };
        if (self.entries.strongCount() == 1) {
            const g = self.entries.borrow();
            // A hole holds `Unit`, which releases nothing.
            for (g.get().slots.items) |pair| {
                pair.key.release(allocator);
                pair.value.release(allocator);
            }
            g.deinit();
        }
        self.entries.deinit();
    }

    pub fn gcTrace(self: *const MapData, m: *objcell.gc.Marker) void {
        m.shade(&self.entries.cell.hdr);
        for (self.views) |v| if (v) |x| x.gcMark(m);
    }

    /// Keeps `v` as the map's view of `kind`, as the collector must see a reference stored
    /// in a cell.
    pub fn setView(self: *MapData, kind: MapViewKind, v: Value) void {
        self.views[@intFromEnum(kind)] = v;
        const cell: *MapRef.Cell = @alignCast(@fieldParentPtr("data", self));
        objcell.gc.writeBarrier(&cell.hdr);
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
    key: Value,
    /// The value it keeps once its node left the map, or with no map behind it; read and
    /// written under the entry's own lock (`putValue`). `getValue` is the entry's value.
    value: Value,
    /// When set, the live map's entries: `setValue` writes through.
    backing: objcell.OptRef(MapStore) = .{},
    /// The backing counter when this entry was handed out; a later structural
    /// change makes every member access throw ConcurrentModificationException.
    exp_mod: u64 = 0,
    /// The slot the key was last in in the backing store: checked before a scan.
    at: u32 = 0,

    /// The slot of this live entry's key in its backing store: where it last was
    /// when that slot still holds the key, else found by a scan, which moves `at`.
    pub fn slotIn(self: *MapEntryData, store: *const MapStore) ?usize {
        const key = &self.key;
        const slots = store.slots.items;
        if (self.at < slots.len and !store.isHole(self.at) and Value.structuralEq(&slots[self.at].key, key)) return self.at;
        var it = store.live();
        while (it.nextSlot()) |i| {
            if (Value.structuralEq(&slots[i].key, key)) {
                self.at = @intCast(i);
                return i;
            }
        }
        return null;
    }

    pub const Read = union(enum) {
        /// The node's value as the map holds it.
        live: Value,
        /// A builder's map changed structurally since the entry was handed out.
        stale,
        /// The node left the map: the entry's own value stands.
        detached,
    };

    /// What a read of this entry finds in `store`, read under its lock: a `buildMap`
    /// builder's entry fails fast once the map changed structurally, as `MapBuilder`'s
    /// do; any other is its node, as a JVM `HashMap`'s entry is.
    pub fn read(self: *MapEntryData, store: *const MapStore) Read {
        if (store.builder) if (store.mod_count.get()) |mc| if (mc.cell.data.load() != self.exp_mod) return .stale;
        const i = self.nodeSlot(store) orelse return .detached;
        return .{ .live = store.slots.items[i].value };
    }

    /// The slot this entry's node stands in, the one whose entry object it is (`MapStore.nodeEntry`),
    /// null once the node left the map (a removal, a `clear`), as a JVM `HashMap`'s entry
    /// outlives its node's place. An entry with no node of its own finds its key.
    pub fn nodeSlot(self: *MapEntryData, store: *const MapStore) ?usize {
        if (!store.tracking) return self.slotIn(store);
        const nodes = store.nodes.items;
        const mine = mapEntryRefOf(self).cell;
        if (self.at < nodes.len and nodes[self.at] == mine) return self.at;
        for (nodes, 0..) |n, i| {
            if (n != mine) continue;
            self.at = @intCast(i);
            return i;
        }
        return null;
    }

    /// Its value: its node's while the node is in the map, its own once it left, as a JVM
    /// `HashMap`'s entry is its node. Takes the store's lock: not for a caller holding it.
    pub fn getValue(self: *MapEntryData) Value {
        if (self.backing.get()) |entries| {
            const sg = entries.borrow();
            defer sg.deinit();
            if (self.nodeSlot(sg.get())) |i| return sg.get().slots.items[i].value;
        }
        const g = mapEntryRefOf(self).borrow();
        defer g.deinit();
        return g.get().value;
    }

    /// Makes `v` the value it holds, under its lock; the same value stays.
    pub fn putValue(self: *MapEntryData, v: Value) void {
        const g = mapEntryRefOf(self).borrowMut();
        defer g.deinit();
        const cur = &g.get().value;
        if (Value.structuralEq(cur, &v)) return;
        if (objcell.reclaimEnabled()) {
            v.retain();
            cur.release(std.heap.page_allocator);
        }
        cur.* = v;
    }

    pub fn deinit(self: *MapEntryData, allocator: std.mem.Allocator) void {
        self.key.release(allocator);
        self.value.release(allocator);
        // `backing` is a non-owning write-through reference.
    }

    pub fn gcTrace(self: *const MapEntryData, m: *objcell.gc.Marker) void {
        self.key.gcMark(m);
        self.value.gcMark(m);
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

    /// Attach `s` as the stack captured at the first throw, under the cell's
    /// exclusive borrow, which records the write barrier; false, attaching
    /// nothing, when a stack is already attached.
    pub fn attachStackOnce(self: *ExceptionData, s: StackRef) bool {
        const g = exceptionRefOf(self).borrowMut();
        defer g.deinit();
        if (g.get().stack != null) return false;
        g.get().stack = s.cell;
        return true;
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
    mod_count: objcell.OptRef(ModCount) = .{},

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

/// A hash index over the elements of a list by position, for a set's membership
/// (`stdlib`'s `collections/hashing.zig`): each element's hash, taken once as the element
/// joins, as a `HashSet`'s node keeps it, and buckets of positions over them. An element
/// with no hash a lookup can use (`no_hash`) is compared by every lookup. It is read and
/// written under the lock of the list it indexes, and `seq` is the list's write sequence
/// it covers, so a change made to the list another way is seen and the index built again.
/// A removed element's position can stay behind as a hole (`removeHole`), which no
/// lookup offers, until `compact` closes it up as the list's elements move down.
pub const ValueIndex = struct {
    hashes: std.ArrayList(u64) = .empty,
    /// One past the newest position in each bucket, 0 for none: a power of two long, at
    /// least twice the positions.
    buckets: []u32 = &.{},
    /// Per position: one past the next older position in its bucket, 0 ending it, or
    /// `hole`.
    chain: std.ArrayList(u32) = .empty,
    /// The positions whose element has no hash.
    loose: std.ArrayList(u32) = .empty,
    seq: u32 = 0,

    pub const no_hash: u64 = std.math.maxInt(u64);

    /// A removed element's `chain` link: its position is in no bucket and not loose.
    pub const hole: u32 = std.math.maxInt(u32);

    /// The allocator an index's arrays live in, apart from the collector's heap: the index
    /// frees them as its cell goes.
    pub const allocator = std.heap.c_allocator;

    pub fn deinit(self: *ValueIndex, a: std.mem.Allocator) void {
        _ = a;
        self.hashes.deinit(allocator);
        allocator.free(self.buckets);
        self.buckets = &.{};
        self.chain.deinit(allocator);
        self.loose.deinit(allocator);
    }

    pub fn gcFinalize(self: *ValueIndex, a: std.mem.Allocator) void {
        self.deinit(a);
    }

    pub fn len(self: *const ValueIndex) usize {
        return self.hashes.items.len;
    }

    pub fn clear(self: *ValueIndex) void {
        self.hashes.clearRetainingCapacity();
        self.chain.clearRetainingCapacity();
        self.loose.clearRetainingCapacity();
        @memset(self.buckets, 0);
    }

    /// Indexes one more element, of hash `h`, at the next position.
    pub fn push(self: *ValueIndex, h: u64) std.mem.Allocator.Error!void {
        const a = allocator;
        const pos: u32 = @intCast(self.hashes.items.len);
        try self.hashes.append(a, h);
        try self.chain.append(a, 0);
        if (h == no_hash) return self.loose.append(a, pos);
        if (self.hashes.items.len * 2 > self.buckets.len) return self.rebucket();
        self.link(pos, h);
    }

    inline fn link(self: *ValueIndex, pos: u32, h: u64) void {
        const b = &self.buckets[@intCast(h & (self.buckets.len - 1))];
        self.chain.items[pos] = b.*;
        b.* = pos + 1;
    }

    /// The buckets again, for every position, at least twice as many as positions.
    fn rebucket(self: *ValueIndex) std.mem.Allocator.Error!void {
        const a = allocator;
        const want = @max(16, std.math.ceilPowerOfTwoAssert(usize, self.hashes.items.len * 2));
        if (want != self.buckets.len) {
            a.free(self.buckets);
            self.buckets = &.{};
            self.buckets = try a.alloc(u32, want);
        }
        @memset(self.buckets, 0);
        self.loose.clearRetainingCapacity();
        for (self.hashes.items, 0..) |h, i| {
            const pos: u32 = @intCast(i);
            if (self.chain.items[i] == hole) continue;
            if (h == no_hash) {
                self.chain.items[i] = 0;
                try self.loose.append(a, pos);
            } else self.link(pos, h);
        }
    }

    /// Takes position `i` out of every lookup and leaves a hole there, the other
    /// positions keeping theirs.
    pub fn removeHole(self: *ValueIndex, i: usize) void {
        const pos: u32 = @intCast(i);
        const h = self.hashes.items[i];
        if (h == no_hash) {
            if (std.mem.indexOfScalar(u32, self.loose.items, pos)) |at| _ = self.loose.orderedRemove(at);
        } else {
            // A bucket runs from its newest position to its oldest, so what links to
            // `i` is newer than it.
            const first = &self.buckets[@intCast(h & (self.buckets.len - 1))];
            if (first.* == pos + 1) {
                first.* = self.chain.items[i];
            } else {
                var slot = first.*;
                while (slot != 0) : (slot = self.chain.items[slot - 1]) {
                    if (self.chain.items[slot - 1] == pos + 1) {
                        self.chain.items[slot - 1] = self.chain.items[i];
                        break;
                    }
                }
            }
        }
        self.chain.items[i] = hole;
    }

    /// Whether position `i` is a hole.
    pub inline fn isHole(self: *const ValueIndex, i: usize) bool {
        return self.chain.items[i] == hole;
    }

    /// Drops the positions from `n` on, every one a hole.
    pub fn truncate(self: *ValueIndex, n: usize) void {
        self.hashes.items.len = n;
        self.chain.items.len = n;
    }

    /// Closes the holes up: each position moves down past the holes before it, as the
    /// list's elements do, and the buckets are linked again over them.
    pub fn compact(self: *ValueIndex) void {
        var w: usize = 0;
        for (self.chain.items, 0..) |c, r| {
            if (c == hole) continue;
            self.hashes.items[w] = self.hashes.items[r];
            w += 1;
        }
        self.truncate(w);
        // As many buckets as before, and the loose positions no more than before.
        @memset(self.buckets, 0);
        self.loose.clearRetainingCapacity();
        for (self.hashes.items, 0..) |h, i| {
            const pos: u32 = @intCast(i);
            if (h == no_hash) {
                self.chain.items[i] = 0;
                self.loose.appendAssumeCapacity(pos);
            } else self.link(pos, h);
        }
    }

    /// The positions an element of hash `h` may be at: those of its bucket holding that
    /// hash, then every loose one. `h` `no_hash` answers every position.
    pub fn candidates(self: *const ValueIndex, h: u64, out: *std.ArrayList(u32), a: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (h == no_hash) {
            for (0..self.hashes.items.len) |i| if (!self.isHole(i)) try out.append(a, @intCast(i));
            return;
        }
        if (self.buckets.len != 0) {
            var slot = self.buckets[@intCast(h & (self.buckets.len - 1))];
            while (slot != 0) : (slot = self.chain.items[slot - 1]) {
                if (self.hashes.items[slot - 1] == h) try out.append(a, slot - 1);
            }
        }
        try out.appendSlice(a, self.loose.items);
    }
};

pub const ValueIndexRef = ObjRef(ValueIndex);

pub const SetData = struct {
    /// The elements in order. Removing one from a set with an index leaves a hole in its
    /// place (`Unit`, its index position a `ValueIndex.hole`), as a `LinkedHashSet` unlinks
    /// a node without moving the others; `dense` closes the holes up for a reader that
    /// takes the list as the set's elements.
    elems: ValueList,
    mutable: bool,
    backing: ?*CollBackingCell,
    /// See `ListData.declared_elem`.
    declared_elem: ?[]const u8 = null,
    mod_count: objcell.OptRef(ModCount) = .{},
    /// The hash index over `elems` a set of a few elements or more keeps
    /// (`stdlib`'s `collections/hashing.zig`), read and written under `elems`'s lock.
    index: ?ValueIndexRef = null,
    /// How many of `elems` are holes, changed under its lock; never more than none for a
    /// set with no index that covers its list.
    holes: u32 = 0,
    /// How many of `elems`' first positions are holes, so an iterator starts past them.
    head: u32 = 0,
    /// Counts the times `compact` moved the elements, so an iterator over the list finds
    /// its place again by how many elements it has passed.
    epoch: u32 = 0,

    pub fn deinit(self: *SetData, allocator: std.mem.Allocator) void {
        Value.releaseValueList(self.elems, allocator);
        if (self.backing) |b| (CollBackingRef{ .cell = b }).deinit();
        if (self.mod_count.get()) |mc| mc.deinit();
        if (self.index) |ix| ix.deinit();
    }

    pub fn gcTrace(self: *const SetData, m: *objcell.gc.Marker) void {
        m.shade(&self.elems.cell.hdr);
        if (self.backing) |b| m.shade(&b.hdr);
        if (self.mod_count.get()) |mc| m.shade(&mc.cell.hdr);
        if (self.index) |ix| m.shade(&ix.cell.hdr);
    }

    /// Gives the set index `ix`, as the collector must see a reference stored in a cell.
    pub fn setIndex(self: *SetData, ix: ValueIndexRef) void {
        self.index = ix;
        const cell: *SetRef.Cell = @alignCast(@fieldParentPtr("data", self));
        objcell.gc.writeBarrier(&cell.hdr);
    }

    /// The set's list with no holes in it: its elements in order, for a reader that takes
    /// them by position or a writer that changes the list another way than the set's
    /// own lookups (`collections/hashing.zig`).
    pub fn dense(self: *SetData) ValueList {
        if (@atomicLoad(u32, &self.holes, .monotonic) != 0) self.compact();
        return self.elems;
    }

    /// How many elements the set holds.
    pub fn len(self: *const SetData) usize {
        const g = self.elems.borrow();
        defer g.deinit();
        return g.get().items.len - self.holes;
    }

    /// Closes the holes in the list up, the index's positions moving with the elements,
    /// so the index still covers the list.
    pub fn compact(self: *SetData) void {
        const g = self.elems.borrowMut();
        defer g.deinit();
        self.compactLocked(g.get());
    }

    /// Takes the element at position `pos` out of the list, whose write lock the caller
    /// holds, and answers it. With an index covering the list it leaves a hole and every
    /// other element keeps its position, the last position going with the holes before
    /// it; with none the elements after it move down one (`shifted`).
    pub fn removeAtLocked(self: *SetData, list: *std.ArrayList(Value), pos: usize) struct { gone: Value, shifted: bool } {
        const gone = list.items[pos];
        // The writer's lock made the sequence odd: one more than the index's.
        const s = self.elems.cell.lock.seq.load(.monotonic);
        if (self.index) |ixr| if (ixr.cell.data.seq == s -% 1 and self.backing == null) {
            const ix = &ixr.cell.data;
            ix.removeHole(pos);
            if (pos + 1 == list.items.len) {
                var n = pos;
                while (n > 0 and ix.isHole(n - 1)) n -= 1;
                @atomicStore(u32, &self.holes, self.holes - @as(u32, @intCast(pos - n)), .monotonic);
                list.items.len = n;
                ix.truncate(n);
                if (self.head > n) self.head = @intCast(n);
            } else {
                list.items[pos] = .Unit;
                @atomicStore(u32, &self.holes, self.holes + 1, .monotonic);
                // The last position is never a hole, so the run of holes ends before it.
                if (pos == self.head) {
                    var h = pos + 1;
                    while (ix.isHole(h)) h += 1;
                    self.head = @intCast(h);
                }
            }
            ix.seq = s +% 1;
            return .{ .gone = gone, .shifted = false };
        };
        std.debug.assert(self.holes == 0);
        _ = list.orderedRemove(pos);
        return .{ .gone = gone, .shifted = true };
    }

    /// `compact` under the list's write lock, which the caller holds.
    pub fn compactLocked(self: *SetData, list: *std.ArrayList(Value)) void {
        if (self.holes == 0) return;
        const ix = &self.index.?.cell.data;
        var w: usize = 0;
        for (list.items, 0..) |v, r| {
            if (ix.isHole(r)) continue;
            list.items[w] = v;
            w += 1;
        }
        list.items.len = w;
        ix.compact();
        // The writer's lock made the sequence odd; giving it back makes it one more.
        ix.seq = self.elems.cell.lock.seq.load(.monotonic) +% 1;
        @atomicStore(u32, &self.holes, 0, .monotonic);
        self.head = 0;
        @atomicStore(u32, &self.epoch, self.epoch +% 1, .monotonic);
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
/// resolve through the source: a `subList` splices through the parent's items,
/// and a primitive-array `.asList()`
/// reflects later element writes. A reference `Array<T>.asList()` shares the
/// boxed buffer outright and carries no backing.
pub const CollBacking = union(enum) {
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
    bytes: std.ArrayList(u8) = .empty,
    /// The bytes after the cell it was made with (`init`), which stay with
    /// the cell after an append moves the elements out.
    trailing: u32 = 0,

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
    pub inline fn getAs(self: *const PrimBuf, i: usize, view_kind: PrimitiveArrayKind) Value {
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
        if (self.inCell()) {
            // The elements after the cell cannot grow in place.
            var moved: std.ArrayList(u8) = .empty;
            try moved.ensureTotalCapacity(a, self.bytes.items.len + es);
            moved.appendSliceAssumeCapacity(self.bytes.items);
            self.bytes = moved;
        }
        try self.bytes.appendNTimes(a, 0, es);
        self.set(self.len() - 1, v);
    }

    /// `n` zeroed elements of `kind` after the array's own cell, in one
    /// allocation: a zeroed element is every primitive's default.
    pub fn init(a: std.mem.Allocator, kind: PrimitiveArrayKind, n: usize) std.mem.Allocator.Error!ObjRef(PrimBuf) {
        const r = try make(a, kind, n * kind.elemSize());
        @memset(r.cell.data.bytes.items, 0);
        return r;
    }

    /// `bytes` copied after the array's own cell.
    pub fn initBytes(a: std.mem.Allocator, kind: PrimitiveArrayKind, bytes: []const u8) std.mem.Allocator.Error!ObjRef(PrimBuf) {
        const r = try make(a, kind, bytes.len);
        @memcpy(r.cell.data.bytes.items, bytes);
        return r;
    }

    /// An array whose elements take `size` bytes, left undefined: after its
    /// cell, or in a buffer of their own past what `trailing` counts.
    fn make(a: std.mem.Allocator, kind: PrimitiveArrayKind, size: usize) std.mem.Allocator.Error!ObjRef(PrimBuf) {
        if (size <= std.math.maxInt(u32)) return ObjRef(PrimBuf).initTrailing(a, .{ .kind = kind }, size);
        var pb: PrimBuf = .{ .kind = kind };
        try pb.bytes.resize(a, size);
        errdefer pb.bytes.deinit(a);
        return ObjRef(PrimBuf).initOwned(a, pb);
    }

    pub const Trailing = u8;

    pub fn adoptTrailing(self: *PrimBuf, elems: []u8) void {
        self.bytes = .{ .items = elems, .capacity = elems.len };
        self.trailing = @intCast(elems.len);
    }

    /// Whether the elements are the ones after the array's own cell, which go with it.
    fn inCell(self: *const PrimBuf) bool {
        const Cell = ObjRef(PrimBuf).Cell;
        const cell: *const Cell = @alignCast(@fieldParentPtr("data", self));
        return self.bytes.capacity != 0 and @intFromPtr(self.bytes.items.ptr) == @intFromPtr(cell) + @sizeOf(Cell);
    }

    pub fn trailingBytes(self: *const PrimBuf) usize {
        return self.trailing;
    }

    /// Scalars have no out-edges, so the payload is a leaf and mutable access
    /// needs no write barrier.
    pub const gc_pointer_free = true;
    pub fn gcTrace(self: *const PrimBuf, m: *objcell.gc.Marker) void {
        _ = self;
        _ = m;
    }
    pub fn gcFinalize(self: *PrimBuf, a: std.mem.Allocator) void {
        if (!self.inCell()) self.bytes.deinit(a);
    }
    pub fn gcNeedsFinalize(self: *const PrimBuf) bool {
        return self.bytes.capacity != 0 and !self.inCell();
    }
    /// Bytes owned beyond the control block, for the collection threshold.
    pub fn gcExternalBytes(self: *const PrimBuf) usize {
        return if (self.inCell()) 0 else self.bytes.capacity;
    }
    pub fn deinit(self: *PrimBuf, a: std.mem.Allocator) void {
        if (!self.inCell()) self.bytes.deinit(a);
    }
};

/// A union rather than two fields, so every access site is compiler-flagged
/// when the representation changes.
pub const ArrayStore = union(enum) {
    boxed: ValueList,
    scalars: ObjRef(PrimBuf),
};

/// `from`'s values into `to`, the two overlapping or not; where values are counted, each
/// taken before the ones it replaces are let go.
fn moveValues(a: std.mem.Allocator, to: []Value, from: []const Value) void {
    if (objcell.reclaimEnabled()) {
        for (from) |v| v.retain();
        for (to) |v| v.release(a);
    }
    if (@intFromPtr(to.ptr) <= @intFromPtr(from.ptr)) std.mem.copyForwards(Value, to, from) else std.mem.copyBackwards(Value, to, from);
}

fn moveBytes(to: []u8, from: []const u8) void {
    if (@intFromPtr(to.ptr) <= @intFromPtr(from.ptr)) std.mem.copyForwards(u8, to, from) else std.mem.copyBackwards(u8, to, from);
}

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
                const g = vl.borrowMutAt(i);
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

    /// Copies the `count` elements of `src` from `start` into this array from `at`, as
    /// `System.arraycopy` copies them whether or not the ranges overlap: under one lock on
    /// each array, taken in address order so two copies the other way round never wait on
    /// each other, and for a reference array with the write barrier of the range it writes.
    /// False, copying nothing, for arrays of two kinds of storage; the caller checked both
    /// ranges.
    pub fn copyRangeFrom(self: ArrayData, allocator: std.mem.Allocator, at: usize, src: ArrayData, start: usize, count: usize) bool {
        switch (self.storage()) {
            .boxed => |to| {
                const from = switch (src.storage()) {
                    .boxed => |vl| vl,
                    .scalars => return false,
                };
                if (count == 0) return true;
                if (to.cell == from.cell) {
                    const g = to.borrowMutRange(at, at + count - 1);
                    defer g.deinit();
                    moveValues(allocator, g.get().items[at..][0..count], g.get().items[start..][0..count]);
                    return true;
                }
                const to_first = @intFromPtr(to.cell) < @intFromPtr(from.cell);
                const gt = if (to_first) to.borrowMutRange(at, at + count - 1) else null;
                const gf = from.borrow();
                defer gf.deinit();
                const gt2 = gt orelse to.borrowMutRange(at, at + count - 1);
                defer gt2.deinit();
                moveValues(allocator, gt2.get().items[at..][0..count], gf.get().items[start..][0..count]);
                return true;
            },
            .scalars => |to| {
                const from = switch (src.storage()) {
                    .scalars => |pb| pb,
                    .boxed => return false,
                };
                if (count == 0) return true;
                if (to.cell == from.cell) {
                    const g = to.borrowMut();
                    defer g.deinit();
                    const size = g.get().kind.elemSize();
                    const bytes = g.get().bytes.items;
                    moveBytes(bytes[at * size ..][0 .. count * size], bytes[start * size ..][0 .. count * size]);
                    return true;
                }
                const to_first = @intFromPtr(to.cell) < @intFromPtr(from.cell);
                const gt = if (to_first) to.borrowMut() else null;
                const gf = from.borrow();
                defer gf.deinit();
                const gt2 = gt orelse to.borrowMut();
                defer gt2.deinit();
                const size = gt2.get().kind.elemSize();
                if (gf.get().kind.elemSize() != size) return false;
                @memcpy(gt2.get().bytes.items[at * size ..][0 .. count * size], gf.get().bytes.items[start * size ..][0 .. count * size]);
                return true;
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
        const pb = try PrimBuf.init(a, kind, items.len);
        for (items, 0..) |v, i| pb.cell.data.set(i, v);
        return .{ .Array = ArrayData.scalars(pb, kind) };
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
/// infinite source never materialises. A pull runs user code (the source's
/// iterator, each op's lambda), so it holds no lock across the pull: the
/// thread that set `pulling` owns the counters and flags, and each store of a
/// value field takes the cell's exclusive borrow for that store (`setValue`).
pub const SeqIterState = struct {
    /// Set for the length of one `hasNext` or `next`. A second pull that finds
    /// it set, from another thread or from the pull's own user code, fails
    /// rather than interleaving with it.
    pulling: std.atomic.Value(bool) = .init(false),
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

    /// Store `v` in the value field `field`, under the cell's exclusive borrow.
    pub fn setValue(self: *SeqIterState, comptime field: []const u8, v: @FieldType(SeqIterState, field)) void {
        const ref: SeqIterStateRef = .{ .cell = @alignCast(@fieldParentPtr("data", self)) };
        const g = ref.borrowMut();
        defer g.deinit();
        @field(g.get(), field) = v;
    }

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
/// What made a host iterator, which says its class as the JVM's: a collection's own
/// iterator is a `MutableIterator`, as every one of a JVM collection is, whether the
/// collection may change or not; a list's `listIterator()` a `MutableListIterator`; any
/// other (an array's, a string's) a plain `Iterator`, as Kotlin's own are.
pub const IterSource = enum(u8) { other, collection, list };

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
    mod_count: objcell.OptRef(ModCount) = .{},
    /// True only when the iterator shares a mutable collection's backing, so
    /// `MutableIterator.remove` and the `MutableListIterator` writes reach the
    /// source. Kotlin throws `UnsupportedOperationException` otherwise.
    mutable: bool = false,
    /// For an iterator over a map or a view of it, the store whose slots it walks, from
    /// `pos` over the holes, yielding `map_kind` of each entry: its key, its value, or its
    /// node's entry object. `items` is empty. `map_epoch` is the store's `epoch` where it
    /// last stood, and `seen` how many entries it has passed, where it stands again once
    /// the entries moved.
    map_store: objcell.OptRef(MapStore) = .{},
    map_kind: ?MapViewKind = null,
    map_epoch: u32 = 0,
    /// For an iterator over a mutable set's own list, which can hold holes: `next` passes
    /// over them and `remove` leaves one. `seen` counts the elements before `pos`, which
    /// is where the iterator stands again once the set's `epoch` moves past `set_epoch`.
    set: objcell.OptRef(SetData) = .{},
    set_epoch: u32 = 0,
    seen: usize = 0,
    /// What made the iterator, which says the class it is an instance of (`IterSource`).
    source: IterSource = .other,
    /// For an iterator over a map or a set's own list: set when `next` gave the last element
    /// the collection held then, or the collection was empty when the iterator was made.
    /// `hasNext` answers from it alone, as a JVM `LinkedHashMap` iterator answers from the
    /// node it took to come next, so an element added after the last one ends the walk and
    /// any other change throws from `next`.
    ended: bool = false,

    pub fn deinit(self: *IterCursor, allocator: std.mem.Allocator) void {
        // The last handle releases the contained elements before the list.
        if (self.items.strongCount() == 1) {
            const g = self.items.borrow();
            for (g.get().items) |e| e.release(allocator);
            g.deinit();
        }
        self.items.deinit();
        if (self.mod_count.get()) |mc| mc.deinit();
        if (self.map_store.get()) |ms| ms.deinit();
        if (self.set.get()) |st| st.deinit();
    }

    pub fn gcTrace(self: *const IterCursor, m: *objcell.gc.Marker) void {
        m.shade(&self.items.cell.hdr);
        if (self.mod_count.get()) |mc| m.shade(&mc.cell.hdr);
        if (self.map_store.get()) |ms| m.shade(&ms.cell.hdr);
        if (self.set.get()) |st| m.shade(&st.cell.hdr);
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
    stack: std.ArrayList(KeepEntry) = .empty,
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
    const stack: *const std.ArrayList(KeepEntry) = @ptrCast(@alignCast(ctx));
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
    /// A weak reference's cell: it holds its referent without keeping it
    /// alive, and the collector clears it once the referent is garbage.
    Weak: weak_mod.WeakRef,

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
            .Weak => |w| visitor.visit(w),
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

    /// A number or a boolean: the tags up to `Bool`, one compare. Every one of
    /// them is primitive; `Char` and `Null` are too but answer false here.
    pub inline fn isNumberOrBool(self: Value) bool {
        comptime {
            for (std.meta.fields(std.meta.Tag(Value))) |f| {
                if (f.value <= @intFromEnum(std.meta.Tag(Value).Bool) and
                    !(Value.isPrimitive(@unionInit(Value, f.name, undefined))))
                    @compileError("a tag up to Bool is not primitive: " ++ f.name);
            }
        }
        return @intFromEnum(std.meta.activeTag(self)) <= @intFromEnum(std.meta.Tag(Value).Bool);
    }

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
        const a = slab.allocator;
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

    /// Dual of `release`. Gated to match it: under reclaim-off both are
    /// skipped, and the check is all a caller pays then.
    pub inline fn retain(self: Value) void {
        if (!objcell.reclaimEnabled()) return;
        self.retainSlow();
    }

    fn retainSlow(self: Value) void {
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
            .IrClosure => |c| if (objcell.gc.markClosureHook) |f| f(c.asPtrConst().id, c.asPtrConst().body, m),
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
    /// Gated identically to `retain`: the arena frees en masse and the GC
    /// reclaims by reachability, while refcount teardown here is O(n).
    pub inline fn release(self: Value, allocator: std.mem.Allocator) void {
        if (!objcell.reclaimEnabled()) return;
        self.releaseSlow(allocator);
    }

    fn releaseSlow(self: Value, allocator: std.mem.Allocator) void {
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
                if (c.strongCount() == 1) {
                    const g = c.borrow();
                    for (g.get().captures) |*e| e.release(allocator);
                    g.deinit();
                }
                c.deinit();
            },
            .Comparator => |c| comparatorRefOf(c).deinit(),
            .List => |x| {
                if (objcell.envSetOnce("KLIO_BOXDIE_TRACE") and x.backing != null and
                    listRefOf(x).strongCount() == 1)
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
            .Weak => "kotlin.Any",
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
            .Weak => std.mem.eql(u8, name, "Any"),
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
                if (matchesAny(name, &.{ "Iterator", "Any" })) break :blk true;
                const snap = sblk: {
                    const g = it.borrow();
                    defer g.deinit();
                    break :sblk .{ .source = g.get().source, .prim = g.get().prim };
                };
                // As `IterSource` gives the class: the list iterators' names for a list's
                // `listIterator()`, `MutableIterator` for any collection's.
                switch (snap.source) {
                    .list => if (matchesAny(name, &.{ "MutableIterator", "ListIterator", "MutableListIterator" })) break :blk true,
                    .collection => if (std.mem.eql(u8, name, "MutableIterator")) break :blk true,
                    .other => {},
                }
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
        const memo = &subtype_tls.get().map_entry_memo;
        const slot = &memo[(key >> 4) % memo.len];
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
            .MapEntry => |e| return .{ .key = e.key, .value = e.getValue() },
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

    /// Whether a key's `hashCode` and `equals` are the host's to answer, not
    /// its value's: an instance, a callable reference, or a pair, triple or
    /// entry holding one.
    pub fn hostKeyed(v: *const Value) bool {
        return switch (v.*) {
            .Instance, .IrClosure => true,
            .Pair => |p| hostKeyed(p.first.asPtrConst()) or hostKeyed(p.second.asPtrConst()),
            .Triple => |t| hostKeyed(t.first.asPtrConst()) or hostKeyed(t.second.asPtrConst()) or hostKeyed(t.third.asPtrConst()),
            .MapEntry => |e| blk: {
                const value = e.getValue();
                break :blk hostKeyed(&e.key) or hostKeyed(&value);
            },
            else => false,
        };
    }

    /// A boxed type matches only its own type, elements included.
    /// `hashCode()` of a number, a `Char`, a `Boolean`, a string or null, as the JVM
    /// answers it; null for any other value, whose hash depends on what it holds or on a
    /// class's override.
    pub fn javaHashCode(v: *const Value) ?i32 {
        return switch (v.*) {
            .Null => 0,
            .Bool => |b| if (b) @as(i32, 1231) else @as(i32, 1237),
            .Char => |c| @as(i32, c),
            .Byte => |x| @as(i32, x),
            .Short => |x| @as(i32, x),
            .Int => |x| x,
            // An unsigned value class hashes its signed storage: 65535u hashes as -1.
            .UByte => |x| @as(i32, @as(i8, @bitCast(x))),
            .UShort => |x| @as(i32, @as(i16, @bitCast(x))),
            .UInt => |x| @bitCast(x),
            .Long => |l| @truncate(l ^ @as(i64, @bitCast(@as(u64, @bitCast(l)) >> 32))),
            .ULong => |u| @truncate(@as(i64, @bitCast(u ^ (u >> 32)))),
            // `floatToIntBits` and `doubleToLongBits` make every NaN the canonical one.
            .Float => |f| if (std.math.isNan(f)) @as(i32, @bitCast(@as(u32, 0x7fc0_0000))) else @bitCast(f),
            .Double => |d| blk: {
                const b: i64 = if (std.math.isNan(d)) @bitCast(@as(u64, 0x7ff8_0000_0000_0000)) else @bitCast(d);
                break :blk @truncate(b ^ @as(i64, @bitCast(@as(u64, @bitCast(b)) >> 32)));
            },
            .String => |s| blk: {
                const g = s.borrow();
                defer g.deinit();
                break :blk javaStringHash(g.get().bytes);
            },
            else => null,
        };
    }

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
            .Set => |x| if (b.* == .Set) return setEqBoxed(x.dense(), b.Set.dense()),
            .Map => |x| if (b.* == .Map) return mapEqBoxed(x.entries, b.Map.entries),
            .Pair => |x| if (b.* == .Pair)
                return structuralEqBoxed(x.first.asPtrConst(), b.Pair.first.asPtrConst()) and structuralEqBoxed(x.second.asPtrConst(), b.Pair.second.asPtrConst()),
            .Triple => |x| if (b.* == .Triple)
                return structuralEqBoxed(x.first.asPtrConst(), b.Triple.first.asPtrConst()) and
                    structuralEqBoxed(x.second.asPtrConst(), b.Triple.second.asPtrConst()) and
                    structuralEqBoxed(x.third.asPtrConst(), b.Triple.third.asPtrConst()),
            .MapEntry => |x| if (b.* == .MapEntry) {
                const xv = x.getValue();
                const yv = b.MapEntry.getValue();
                return structuralEqBoxed(&x.key, &b.MapEntry.key) and structuralEqBoxed(&xv, &yv);
            },
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
            .Set => |x| b.* == .Set and setEqBoxed(x.dense(), b.Set.dense()),
            .Map => |x| b.* == .Map and mapEqBoxed(x.entries, b.Map.entries),
            .Pair => |x| b.* == .Pair and
                structuralEqBoxed(x.first.asPtrConst(), b.Pair.first.asPtrConst()) and structuralEqBoxed(x.second.asPtrConst(), b.Pair.second.asPtrConst()),
            .Triple => |x| b.* == .Triple and
                structuralEqBoxed(x.first.asPtrConst(), b.Triple.first.asPtrConst()) and
                structuralEqBoxed(x.second.asPtrConst(), b.Triple.second.asPtrConst()) and
                structuralEqBoxed(x.third.asPtrConst(), b.Triple.third.asPtrConst()),
            .MapEntry => |x| b.* == .MapEntry and structuralEqBoxed(&x.key, &b.MapEntry.key) and blk: {
                const xv = x.getValue();
                const yv = b.MapEntry.getValue();
                break :blk structuralEqBoxed(&xv, &yv);
            },
            .Result => |x| b.* == .Result and x.ok == b.Result.ok and structuralEq(x.payload.asPtrConst(), b.Result.payload.asPtrConst()),
            .Class => |x| b.* == .Class and classFqnEq(x, b.Class),
            .IrClosure => |x| b.* == .IrClosure and blk: {
                if (IrClosureRef.ptrEq(x, b.IrClosure)) break :blk true;
                // A non-capturing lambda literal is a singleton in Kotlin, but
                // klio gives each evaluation its own closure id.
                if (objcell.gc.closureSingletonHook) |h| {
                    const sa = h(x.asPtrConst().id, x.asPtrConst().body);
                    if (sa != 0 and sa == h(b.IrClosure.asPtrConst().id, b.IrClosure.asPtrConst().body)) break :blk true;
                }
                break :blk false;
            },
            .Comparator => |x| b.* == .Comparator and
                ObjRef([]ComparatorStep).ptrEq(x.steps, b.Comparator.steps) and
                x.descending == b.Comparator.descending,
            .BoundMethod => |x| b.* == .BoundMethod and std.mem.eql(u8, x.fqn, b.BoundMethod.fqn) and structuralEq(x.receiver.asPtrConst(), b.BoundMethod.receiver.asPtrConst()),
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
            .Set => |x| if (b.* == .Set) return ValueList.ptrEq(x.elems, b.Set.elems),
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

    /// A stable per-object hash, as the JVM's `System.identityHashCode` and
    /// Kotlin/Native's `identityHashCode()` answer: a boxed scalar hashes by
    /// its value, null to 0, an object by its identity.
    pub fn identityHashCode(self: Value) i32 {
        return switch (self) {
            .Null, .Unit => 0,
            .Int => |i| @truncate(i),
            .Long => |i| @truncate(i),
            .Short => |i| i,
            .Byte => |i| i,
            .UInt => |i| @bitCast(i),
            .Char => |c| @intCast(c),
            .Bool => |b| if (b) 1231 else 1237,
            else => {
                const id = self.lockIdentity() orelse return 0;
                const h: i32 = @truncate(@as(i64, @bitCast(@as(u64, id) *% 0x9E3779B97F4A7C15)));
                return h & 0x7FFFFFFF;
            },
        };
    }

    /// Address-stable identity, for use as a `synchronized` monitor key.
    pub fn lockIdentity(self: Value) ?usize {
        return switch (self) {
            .Instance => |i| i.identity(),
            .List => |l| l.items.identity(),
            .Array => |a| a.identity(),
            .Set => |s| s.elems.identity(),
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
            .Weak => |w| try writer.print("kotlin.native.ref.WeakCell@{x}", .{w.identity()}),
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
            .IrClosure => |c| {
                if (objcell.gc.closureTextHook) |h| if (try h(c.asPtrConst().id, c.asPtrConst().body, writer)) return;
                try writer.print("{{ir-closure#{d}}}", .{c.asPtrConst().id});
            },
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
            .Set => |coll| {
                try writeElements(writer, coll.dense(), &self);
            },
            .Array => |a| {
                const tag = if (a.primKind()) |k| k.typeFqn() else "kotlin.Array";
                try writer.print("{s}@<…>", .{tag});
            },
            .Map => |m| {
                const g = m.entries.borrow();
                defer g.deinit();
                try writer.writeByte('{');
                var it = g.get().live();
                var i: usize = 0;
                while (it.next()) |e| : (i += 1) {
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
                try p.first.asPtrConst().writeTo(writer);
                try writer.writeAll(", ");
                try p.second.asPtrConst().writeTo(writer);
                try writer.writeByte(')');
            },
            .Triple => |t| {
                try writer.writeByte('(');
                try t.first.asPtrConst().writeTo(writer);
                try writer.writeAll(", ");
                try t.second.asPtrConst().writeTo(writer);
                try writer.writeAll(", ");
                try t.third.asPtrConst().writeTo(writer);
                try writer.writeByte(')');
            },
            .MapEntry => |e| {
                try e.key.writeTo(writer);
                try writer.writeByte('=');
                try e.getValue().writeTo(writer);
            },
            .Result => |r| {
                try writer.writeAll(if (r.ok) "Success(" else "Failure(");
                try r.payload.asPtrConst().writeTo(writer);
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
        const cur = mc.cell.data.load();
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

/// A collection's count of structural changes, shared with its iterators and
/// views so they fail fast (`FROZEN_MOD_BIT` marks one a builder froze). Read
/// and changed with atomics alone, so it takes no lock.
pub const ModCount = struct {
    n: std.atomic.Value(u64) = .init(0),

    pub const objref_atomic = true;

    pub fn new(a: std.mem.Allocator) std.mem.Allocator.Error!ModCountRef {
        return ModCountRef.init(a, .{});
    }

    pub inline fn load(self: *const ModCount) u64 {
        return self.n.load(.monotonic);
    }

    pub inline fn bump(self: *ModCount) void {
        _ = self.n.fetchAdd(1, .monotonic);
    }

    pub inline fn freeze(self: *ModCount) void {
        _ = self.n.fetchOr(FROZEN_MOD_BIT, .monotonic);
    }

    pub inline fn frozen(self: *const ModCount) bool {
        return self.load() & FROZEN_MOD_BIT != 0;
    }
};
pub const ModCountRef = ObjRef(ModCount);

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
    try writer.print("{s}@{x}", .{ cls.fqn, inst.identityOf() });
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
    if (std.mem.findScalarLast(u8, fqn, '.')) |i| return fqn[i + 1 ..];
    return fqn;
}

fn lastDotSegment(name: []const u8) ?[]const u8 {
    if (std.mem.findScalarLast(u8, name, '.')) |i| return name[i + 1 ..];
    return null;
}

/// A nested class lifts to a flat mangle (`Outer$Data`) while Kotlin shows
/// `Data`, and `$` cannot occur in a source class name, so the tail after the
/// last `$` then `.` is that name.
fn classDisplayName(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.findScalarLast(u8, n, '$')) |i| n = n[i + 1 ..];
    if (std.mem.findScalarLast(u8, n, '.')) |i| n = n[i + 1 ..];
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
    const x = ga.get();
    const y = gb.get();
    if (!classFqnSpellingEq(x.fqn, y.fqn)) return false;
    // Every object expression and every local class is a class of its own,
    // though sema names them all `<anonymous>` or `<local>.Name`.
    return classFqnIsUnique(x.fqn) or x.ir_class == y.ir_class;
}

/// Whether a class's fqn names only it: a local class's and an object
/// expression's are shared by every such class in the program.
pub fn classFqnIsUnique(fqn: []const u8) bool {
    return std.mem.indexOf(u8, fqn, "<local>") == null and std.mem.indexOf(u8, fqn, "<anonymous>") == null;
}

/// A hash consistent with `KClass` equality: the fqn with both nesting
/// spellings folded together, and the IR class of one whose fqn is shared.
pub fn classHash(c: ObjRef(ClassDef)) u64 {
    const g = c.borrow();
    defer g.deinit();
    const d = g.get();
    var h = std.hash.Wyhash.init(0x6b636c);
    for (d.fqn) |ch| h.update(&.{if (ch == '$') '.' else ch});
    if (!classFqnIsUnique(d.fqn)) h.update(std.mem.asBytes(&d.ir_class));
    return h.final();
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
    if (ga.get().len() != gb.get().len()) return false;
    var xs = ga.get().live();
    while (xs.next()) |kv| {
        var found = false;
        var ys = gb.get().live();
        while (ys.next()) |kv2| {
            if (Value.structuralEqBoxed(&kv.key, &kv2.key) and Value.structuralEqBoxed(&kv.value, &kv2.value)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// `String.hashCode()` over the UTF-16 units of `bytes`, UTF-8; a byte sequence that is
/// not UTF-8 hashes byte by byte.
pub fn javaStringHash(bytes: []const u8) i32 {
    var h: i32 = 0;
    const view = std.unicode.Utf8View.init(bytes) catch {
        for (bytes) |ch| h = h *% 31 +% @as(i32, ch);
        return h;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0xFFFF) {
            h = h *% 31 +% @as(i32, @intCast(cp));
        } else {
            const c = cp - 0x10000;
            h = h *% 31 +% @as(i32, @intCast(0xD800 + (c >> 10)));
            h = h *% 31 +% @as(i32, @intCast(0xDC00 + (c & 0x3FF)));
        }
    }
    return h;
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

    /// Shade the cells of every value the error carries.
    pub fn gcMark(self: RuntimeError, m: *objcell.gc.Marker) void {
        switch (self) {
            .Return, .Thrown => |v| v.gcMark(m),
            .LabeledReturn => |r| r.value.gcMark(m),
            .TailContinue => |t| for (t.args) |v| v.gcMark(m),
            .TailJump => |t| {
                t.callee.gcMark(m);
                for (t.args) |v| v.gcMark(m);
            },
            else => {},
        }
    }
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
    const name = if (std.mem.findScalarLast(u8, fqn, '.')) |i| fqn[i + 1 ..] else fqn;
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
                coerceListElems(s.dense(), elem_arg);
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

test "a stack attached to a tenured exception records the barrier, once" {
    const a = std.testing.allocator;
    const ev = try Value.newException(a, .{
        .fqn = try strInit(a, "kotlin.IllegalStateException"),
        .cause = null,
    });
    const ref = exceptionRefOf(ev.Exception);
    defer ref.deinit();
    const hdr = &ref.cell.hdr;
    defer objcell.gc.forgetRanges(&.{.{ .start = @intFromPtr(hdr), .len = @sizeOf(objcell.gc.GcHeader) }});
    hdr.gc_gen = 1;
    hdr.gc_remembered = false;
    const first = try StackRef.init(a, .{ .frames = try a.alloc(StackFrame, 0) });
    try std.testing.expect(ev.Exception.attachStackOnce(first));
    try std.testing.expect(hdr.gc_remembered);
    try std.testing.expectEqual(first.cell, ev.Exception.stack.?);
    const second = try StackRef.init(a, .{ .frames = try a.alloc(StackFrame, 0) });
    defer second.deinit();
    try std.testing.expect(!ev.Exception.attachStackOnce(second));
    try std.testing.expectEqual(first.cell, ev.Exception.stack.?);
}

test "classifier receiver ABI separates host values from source classes" {
    try testing.expectEqual(ReceiverAbi.specialized, classifierReceiverAbi("kotlin.collections.Collection"));
    try testing.expectEqual(ReceiverAbi.specialized, classifierReceiverAbi("kotlin.collections.Grouping"));
    try testing.expectEqual(ReceiverAbi.specialized, classifierReceiverAbi("kotlin.sequences.Sequence"));
    try testing.expectEqual(ReceiverAbi.specialized, classifierReceiverAbi("kotlin.Function2"));
    try testing.expectEqual(ReceiverAbi.instance, classifierReceiverAbi("kotlin.sequences.DropTakeSequence"));
    try testing.expectEqual(ReceiverAbi.instance, classifierReceiverAbi("sample.Collection"));
}

test "a map finds its keys through the index across appends and removals" {
    const a = std.testing.allocator;
    var m: MapStore = .{};
    defer m.deinit(a);
    for (0..100) |i| try m.append(a, .{ .key = Value.newInt(@intCast(i)), .value = Value.newInt(@intCast(i * 10)) });
    try std.testing.expectEqual(@as(?usize, 42), try m.find(a, &Value.newInt(42)));
    try std.testing.expectEqual(@as(usize, 100), m.hashedLen());
    // Every third entry out, the rest renumbered in their buckets.
    var i: usize = 99;
    while (true) : (i -= 1) {
        if (i % 3 == 0) _ = m.removeAt(i);
        if (i == 0) break;
    }
    try std.testing.expectEqual(@as(usize, 66), m.len());
    for (0..100) |k| {
        const at = try m.find(a, &Value.newInt(@intCast(k)));
        if (k % 3 == 0) {
            try std.testing.expectEqual(@as(?usize, null), at);
        } else {
            try std.testing.expectEqual(@as(i32, @intCast(k * 10)), m.slots.items[at.?].value.Int);
        }
    }
    try m.append(a, .{ .key = Value.newInt(0), .value = Value.newInt(-1) });
    try std.testing.expectEqual(@as(?usize, 99), try m.find(a, &Value.newInt(0)));
    m.compact();
    try std.testing.expectEqual(@as(usize, 67), m.slots.items.len);
    try std.testing.expectEqual(@as(?usize, 66), try m.find(a, &Value.newInt(0)));
    try std.testing.expectEqual(@as(i32, 10), m.slots.items[0].value.Int);
    m.clear();
    try std.testing.expectEqual(@as(?usize, null), try m.find(a, &Value.newInt(1)));
}

test "a map's removal leaves a hole that lookups, the walk in order and compaction pass over" {
    const a = std.testing.allocator;
    var m: MapStore = .{};
    defer m.deinit(a);
    for (0..40) |i| try m.append(a, .{ .key = Value.newInt(@intCast(i)), .value = Value.newInt(@intCast(i * 10)) });
    _ = try m.find(a, &Value.newInt(0));
    // A `Unit` key, which a hole holds too, after them, past the hashes.
    try m.append(a, .{ .key = .Unit, .value = Value.newInt(-1) });
    _ = m.removeAt(5);
    _ = m.removeAt(6);
    try std.testing.expectEqual(@as(usize, 2), m.holes);
    try std.testing.expectEqual(@as(usize, 39), m.len());
    try std.testing.expectEqual(@as(?usize, null), try m.find(a, &Value.newInt(5)));
    try std.testing.expectEqual(@as(?usize, 7), try m.find(a, &Value.newInt(7)));
    try std.testing.expectEqual(@as(?usize, 40), try m.find(a, &@as(Value, .Unit)));
    var it = m.live();
    var n: usize = 0;
    var sum: i64 = 0;
    while (it.next()) |kv| : (n += 1) {
        if (kv.key == .Int) sum += kv.key.Int;
    }
    try std.testing.expectEqual(@as(usize, 39), n);
    try std.testing.expectEqual(@as(i64, 780 - 11), sum);
    try std.testing.expectEqual(@as(?usize, 7), m.slotAt(5));
    try std.testing.expectEqual(@as(?usize, 40), m.slotAt(38));
    try std.testing.expectEqual(@as(?usize, null), m.slotAt(39));
    m.compact();
    try std.testing.expectEqual(@as(usize, 0), m.holes);
    try std.testing.expectEqual(@as(usize, 39), m.slots.items.len);
    try std.testing.expectEqual(@as(?usize, 5), try m.find(a, &Value.newInt(7)));
    try std.testing.expectEqual(@as(?usize, 38), try m.find(a, &@as(Value, .Unit)));
    for (0..40) |k| {
        if (k == 5 or k == 6) continue;
        const at = (try m.find(a, &Value.newInt(@intCast(k)))).?;
        try std.testing.expectEqual(@as(i32, @intCast(k * 10)), m.slots.items[at].value.Int);
    }
}

test "a map's last slot out takes the holes before it, and a sparse map compacts" {
    const a = std.testing.allocator;
    var m: MapStore = .{};
    defer m.deinit(a);
    for (0..20) |i| try m.append(a, .{ .key = Value.newInt(@intCast(i)), .value = Value.newInt(@intCast(i)) });
    _ = try m.find(a, &Value.newInt(0));
    _ = m.removeAt(17);
    _ = m.removeAt(18);
    _ = m.removeAt(19);
    try std.testing.expectEqual(@as(usize, 0), m.holes);
    try std.testing.expectEqual(@as(usize, 17), m.slots.items.len);
    try std.testing.expectEqual(@as(?usize, 16), try m.find(a, &Value.newInt(16)));
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = m.removeAt(i);
        m.compactIfSparse();
    }
    // Eight holes of seventeen slots, then the ninth makes them as many as the entries.
    try std.testing.expectEqual(@as(usize, 8), m.holes);
    _ = m.removeAt(8);
    m.compactIfSparse();
    try std.testing.expectEqual(@as(usize, 0), m.holes);
    try std.testing.expectEqual(@as(usize, 8), m.slots.items.len);
    try std.testing.expectEqual(@as(?usize, 0), try m.find(a, &Value.newInt(9)));
    try std.testing.expectEqual(@as(?usize, 7), try m.find(a, &Value.newInt(16)));
}

test "a map entry is its node: one object for every walk, found through holes and compaction, keeping its last value once it leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try MapEntries.init(a, .{});
    const m = &entries.cell.data;
    for (0..20) |i| try m.append(a, .{ .key = Value.newInt(@intCast(i)), .value = Value.newInt(@intCast(i * 10)) });
    _ = try m.find(a, &Value.newInt(0));
    const e5 = (try m.nodeEntry(a, a, entries, 5, 0)).MapEntry;
    const e9 = (try m.nodeEntry(a, a, entries, 9, 0)).MapEntry;
    // Another walk hands out the same object, its value the node's now.
    m.slots.items[9].value = Value.newInt(91);
    const again = (try m.nodeEntry(a, a, entries, 9, 0)).MapEntry;
    try std.testing.expect(again == e9);
    try std.testing.expectEqual(@as(i32, 91), e9.getValue().Int);
    // A put over node 5, then its removal: the entry takes the value it had.
    m.slots.items[5].value = Value.newInt(55);
    _ = m.removeAt(5);
    try std.testing.expectEqual(@as(?usize, null), e5.nodeSlot(m));
    try std.testing.expectEqual(@as(i32, 55), e5.getValue().Int);
    // The key back is a new node, which the old entry is not.
    try m.append(a, .{ .key = Value.newInt(5), .value = Value.newInt(-5) });
    try std.testing.expectEqual(@as(?usize, null), e5.nodeSlot(m));
    // Node 9 found where compaction moved it; the leading holes counted until then.
    for ([_]usize{ 0, 1, 2, 3, 4, 6, 7 }) |i| _ = m.removeAt(i);
    try std.testing.expectEqual(@as(usize, 8), m.head);
    const epoch = m.epoch;
    for ([_]usize{ 8, 10, 11 }) |i| _ = m.removeAt(i);
    m.compactIfSparse();
    try std.testing.expectEqual(@as(usize, 0), m.holes);
    try std.testing.expectEqual(@as(usize, 0), m.head);
    try std.testing.expect(m.epoch != epoch);
    const at9 = e9.nodeSlot(m).?;
    try std.testing.expectEqual(@as(i32, 9), m.slots.items[at9].key.Int);
    try std.testing.expectEqual(@as(usize, 0), at9);
    // A clear lets every node go, each entry with its value.
    m.slots.items[at9].value = Value.newInt(99);
    m.clear();
    try std.testing.expectEqual(@as(?usize, null), e9.nodeSlot(m));
    try std.testing.expectEqual(@as(i32, 99), e9.getValue().Int);
}

test "a removal past a map's index moves the entries after it, which the epoch counts" {
    const a = std.testing.allocator;
    var m: MapStore = .{};
    defer m.deinit(a);
    for (0..3) |i| try m.append(a, .{ .key = Value.newInt(@intCast(i)), .value = .Null });
    const epoch = m.epoch;
    _ = m.removeAt(0);
    try std.testing.expect(m.epoch != epoch);
    // The first entry a walk passes is where the second stood.
    try std.testing.expectEqual(@as(?usize, 0), m.slotAt(0));
    try std.testing.expectEqual(@as(i32, 1), m.slots.items[0].key.Int);
}

test "a walk over a map passes over holes, follows a compaction, and ends at a change unless it gave the last entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try MapEntries.init(a, .{ .mod_count = .from(try ModCount.new(a)) });
    const m = &entries.cell.data;
    for (0..20) |i| try m.append(a, .{ .key = Value.newInt(@intCast(i)), .value = Value.newInt(@intCast(i * 10)) });
    _ = try m.find(a, &Value.newInt(0));
    _ = m.removeAt(0);
    _ = m.removeAt(5);
    var walk = MapWalk.init(entries);
    var keys: std.ArrayList(i32) = .empty;
    while (true) {
        switch (walk.next()) {
            .pair => |kv| try keys.append(a, kv.key.Int),
            .end => break,
            .changed => return error.TestUnexpectedResult,
        }
        // The entries close up under the walk: it goes on from the one it would have read.
        if (keys.items.len == 3) m.compact();
    }
    try std.testing.expectEqual(@as(usize, 18), keys.items.len);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 6, 7 }, keys.items[0..6]);
    // A change before the last entry: the next step ends the walk as changed.
    var mid = MapWalk.init(entries);
    _ = mid.next();
    m.mod_count.get().?.cell.data.bump();
    try std.testing.expect(mid.next() == .changed);
    // A change after the last entry was given: the walk is over.
    var tail = MapWalk.init(entries);
    var n: usize = 0;
    while (tail.next() == .pair) : (n += 1) {
        if (n == 17) m.mod_count.get().?.cell.data.bump();
    }
    try std.testing.expectEqual(@as(usize, 18), n);
}

test "a copy of a map's store holds its entries in order with the hashes kept for them" {
    const a = std.testing.allocator;
    var m: MapStore = .{};
    defer m.deinit(a);
    for (0..20) |i| try m.append(a, .{ .key = Value.newInt(@intCast(i)), .value = .Null });
    _ = try m.find(a, &Value.newInt(0));
    for ([_]usize{ 0, 7 }) |i| _ = m.removeAt(i);
    try m.append(a, .{ .key = Value.newInt(20), .value = .Null });
    var c = try m.copyLive(a);
    defer c.deinit(a);
    try std.testing.expectEqual(@as(usize, 19), c.slots.items.len);
    try std.testing.expectEqual(@as(usize, 0), c.holes);
    try std.testing.expectEqual(@as(i32, 1), c.slots.items[0].key.Int);
    try std.testing.expectEqual(@as(i32, 8), c.slots.items[6].key.Int);
    // Each entry carries the hash its slot kept, the holes' left behind.
    try std.testing.expectEqual(@as(usize, 19), c.hashes.items.len);
    try std.testing.expectEqual(MapStore.keyHash(&Value.newInt(8)).?, c.hashes.items[6]);
    try std.testing.expectEqual(MapStore.keyHash(&Value.newInt(20)).?, c.hashes.items[18]);
    try std.testing.expectEqual(@as(?usize, 18), try c.find(a, &Value.newInt(20)));
}

test "a map hashes a host-hashed key only when given its hash" {
    const a = std.testing.allocator;
    var m: MapStore = .{};
    defer m.deinit(a);
    for (0..20) |i| try m.append(a, .{ .key = Value.newInt(@intCast(i)), .value = .Null });
    try std.testing.expectEqual(@as(?usize, 3), try m.find(a, &Value.newInt(3)));
    // A key only the host hashes waits for its hash; later ones queue behind it.
    try m.appendHashed(a, .{ .key = .Unit, .value = .Null }, null);
    try m.append(a, .{ .key = Value.newInt(20), .value = .Null });
    try std.testing.expectEqual(@as(usize, 20), m.hashedLen());
    try std.testing.expectEqual(@as(?usize, 21), try m.find(a, &Value.newInt(20)));
    try std.testing.expect(try m.addHashes(a, 20, &.{ 7, MapStore.keyHash(&Value.newInt(20)).? }));
    try std.testing.expect(!try m.addHashes(a, 20, &.{7}));
    var at: std.ArrayList(u32) = .empty;
    defer at.deinit(a);
    try m.bucketOf(a, 7, &at, a);
    try std.testing.expectEqualSlices(u32, &.{20}, at.items);
    try std.testing.expectEqual(@as(?usize, 21), try m.find(a, &Value.newInt(20)));
}

test "identity hash of a scalar is its value, of null zero" {
    try testing.expectEqual(@as(i32, 0), (Value{ .Null = {} }).identityHashCode());
    try testing.expectEqual(@as(i32, 42), Value.newInt(42).identityHashCode());
    try testing.expectEqual(@as(i32, -1), (Value{ .Long = -1 }).identityHashCode());
    try testing.expectEqual(@as(i32, 1231), (Value{ .Bool = true }).identityHashCode());
    try testing.expectEqual(@as(i32, 1237), (Value{ .Bool = false }).identityHashCode());
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

test "each object expression and local class is a KClass of its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const anon1 = Value{ .Class = try ClassDef.minimal(a, "<anonymous>", "<anonymous>", 3) };
    const anon1_again = Value{ .Class = try ClassDef.minimal(a, "<anonymous>", "<anonymous>", 3) };
    const anon2 = Value{ .Class = try ClassDef.minimal(a, "<anonymous>", "<anonymous>", 4) };
    const local1 = Value{ .Class = try ClassDef.minimal(a, "L", "<local>.L", 5) };
    const local2 = Value{ .Class = try ClassDef.minimal(a, "L", "<local>.L", 6) };
    const nested = Value{ .Class = try ClassDef.minimal(a, "B", "Outer.B", 7) };
    const lifted = Value{ .Class = try ClassDef.minimal(a, "B", "Outer$B", 8) };
    try testing.expect(Value.structuralEq(&anon1, &anon1_again));
    try testing.expect(!Value.structuralEq(&anon1, &anon2));
    try testing.expect(!Value.structuralEq(&local1, &local2));
    try testing.expect(Value.structuralEq(&nested, &lifted));
    try testing.expectEqual(classHash(anon1.Class), classHash(anon1_again.Class));
    try testing.expect(classHash(anon1.Class) != classHash(anon2.Class));
    try testing.expectEqual(classHash(nested.Class), classHash(lifted.Class));
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




test "a string made in one allocation keeps its bytes in its cell and frees them with it" {
    const ref = try strInitTrailing(std.testing.allocator, 5);
    const d = ref.asPtr();
    @memcpy(@constCast(d.bytes), "hello");
    try std.testing.expect(d.inCell());
    try std.testing.expectEqual(@as(usize, 5), d.trailingBytes());
    try std.testing.expectEqual(@as(usize, 0), d.gcExternalBytes());
    ref.deinit();
    // One whose bytes were allocated apart frees them apart.
    const apart = try StringRef.initOwned(std.testing.allocator, .{ .bytes = try std.testing.allocator.dupe(u8, "abc"), .u16_len = 3, .ascii = true });
    try std.testing.expect(!apart.asPtr().inCell());
    try std.testing.expectEqual(@as(usize, 3), apart.asPtr().gcExternalBytes());
    apart.deinit();
}

fn boxedInts(a: std.mem.Allocator, xs: []const i32) !ArrayData {
    var list: std.ArrayList(Value) = .empty;
    for (xs) |x| try list.append(a, .{ .Int = x });
    return ArrayData.boxed(try ValueList.init(a, list));
}

fn arrayInts(a: std.mem.Allocator, arr: ArrayData) ![]i32 {
    const vs = try arr.snapshot(a);
    const out = try a.alloc(i32, vs.len);
    for (vs, out) |v, *o| o.* = v.Int;
    return out;
}

test "an array's block copy moves a range within it either way, or from another array, as arraycopy does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const xs = try boxedInts(a, &.{ 0, 1, 2, 3, 4, 5, 6, 7 });
    // Up within one array: the elements read are the ones before the copy.
    try std.testing.expect(xs.copyRangeFrom(a, 2, xs, 0, 5));
    try std.testing.expectEqualSlices(i32, &.{ 0, 1, 0, 1, 2, 3, 4, 7 }, try arrayInts(a, xs));
    // Down within one array.
    try std.testing.expect(xs.copyRangeFrom(a, 0, xs, 3, 5));
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 7, 3, 4, 7 }, try arrayInts(a, xs));
    // From another array, and nothing for no elements.
    const ys = try boxedInts(a, &.{ 9, 8, 7 });
    try std.testing.expect(xs.copyRangeFrom(a, 5, ys, 0, 3));
    try std.testing.expect(ys.copyRangeFrom(a, 0, xs, 0, 0));
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 7, 9, 8, 7 }, try arrayInts(a, xs));
    // A primitive array's bytes, within one and from another; storage of another kind is refused.
    const ps = (try ArrayData.initPacked(a, .Int, &.{ .{ .Int = 1 }, .{ .Int = 2 }, .{ .Int = 3 }, .{ .Int = 4 } })).Array;
    try std.testing.expect(ps.copyRangeFrom(a, 1, ps, 0, 3));
    try std.testing.expectEqualSlices(i32, &.{ 1, 1, 2, 3 }, try arrayInts(a, ps));
    const qs = (try ArrayData.initPacked(a, .Int, &.{ .{ .Int = 7 }, .{ .Int = 8 } })).Array;
    try std.testing.expect(ps.copyRangeFrom(a, 2, qs, 0, 2));
    try std.testing.expectEqualSlices(i32, &.{ 1, 1, 7, 8 }, try arrayInts(a, ps));
    try std.testing.expect(!ps.copyRangeFrom(a, 0, ys, 0, 1));
    try std.testing.expect(!ys.copyRangeFrom(a, 0, ps, 0, 1));
}

test "a primitive array made in one allocation keeps its elements in its cell and needs no finalizer" {
    const a = std.testing.allocator;
    const pb = try PrimBuf.init(a, .Int, 4);
    try std.testing.expect(pb.asPtrConst().inCell());
    try std.testing.expectEqual(@as(usize, 16), pb.asPtrConst().trailingBytes());
    try std.testing.expectEqual(@as(usize, 0), pb.asPtrConst().gcExternalBytes());
    try std.testing.expect(!pb.asPtrConst().gcNeedsFinalize());
    for (0..4) |i| try std.testing.expectEqual(@as(i32, 0), pb.asPtrConst().get(i).Int);
    pb.asPtr().set(3, .{ .Int = -9 });
    // An append moves the elements out of the cell, and they are freed apart.
    try pb.asPtr().append(a, .{ .Int = 5 });
    try std.testing.expect(!pb.asPtrConst().inCell());
    try std.testing.expect(pb.asPtrConst().gcNeedsFinalize());
    try std.testing.expectEqual(@as(usize, 5), pb.asPtrConst().len());
    try std.testing.expectEqual(@as(i32, -9), pb.asPtrConst().get(3).Int);
    try std.testing.expectEqual(@as(i32, 5), pb.asPtrConst().get(4).Int);
    pb.deinit();
    const bytes = try PrimBuf.initBytes(a, .Byte, "xyz");
    try std.testing.expectEqualStrings("xyz", bytes.asPtrConst().bytes.items);
    bytes.deinit();
}

test "a string or closure needs its finalizer only for what is outside its cell" {
    const a = std.testing.allocator;
    const s = try strInitTrailing(a, 2);
    try std.testing.expect(!s.asPtrConst().gcNeedsFinalize());
    s.deinit();
    const apart = try StringRef.initOwned(a, .{ .bytes = try a.dupe(u8, "abc"), .u16_len = 3, .ascii = true });
    try std.testing.expect(apart.asPtrConst().gcNeedsFinalize());
    apart.deinit();
    const rec = try IrClosureRef.initTrailing(a, .{ .id = 1, .captures = &.{}, .body = @ptrCast(&a) }, 1);
    try std.testing.expect(!rec.asPtrConst().gcNeedsFinalize());
    rec.deinit();
    const slot = try IrClosureRef.initTrailing(a, .{ .id = 1, .table = 3, .captures = &.{} }, 0);
    try std.testing.expect(slot.asPtrConst().gcNeedsFinalize());
    slot.deinit();
}

test "a closure made in one allocation keeps its captures in its cell and frees them with it" {
    const ref = try IrClosureRef.initTrailing(std.testing.allocator, .{ .id = 1, .captures = &.{} }, 2);
    ref.cell.data.captures[0] = .{ .Int = 4 };
    ref.cell.data.captures[1] = .Null;
    try std.testing.expect(ref.asPtrConst().inCell());
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(Value)), ref.asPtrConst().trailingBytes());
    ref.deinit();
    // One whose captures were allocated apart has none after its cell.
    const caps = try std.testing.allocator.dupe(Value, &.{Value{ .Int = 1 }});
    defer std.testing.allocator.free(caps);
    const apart = try IrClosureRef.init(std.testing.allocator, .{ .id = 2, .captures = caps });
    try std.testing.expect(!apart.asPtrConst().inCell());
    try std.testing.expectEqual(@as(usize, 0), apart.asPtrConst().trailingBytes());
    apart.deinit();
}

test "an Array element is read with no lock, and a reader overlapping a writer's turn is sent to the lock" {
    const a = testing.allocator;
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(a, &.{ .{ .Int = 1 }, .{ .Int = 2 } });
    const vl = try ValueList.init(a, list);
    defer vl.deinit();
    try testing.expectEqual(@as(i32, 2), vl.readAt(1).?.Int);
    try testing.expect(vl.readAt(2) == null);
    {
        const g = vl.borrowMutAt(0);
        defer g.deinit();
        try testing.expectEqual(@as(u32, 1), vl.cell.lock.seq.load(.monotonic));
        try testing.expect(vl.readAt(1) == null);
        g.get().items[0] = .{ .Long = 5 };
    }
    try testing.expectEqual(@as(u32, 2), vl.cell.lock.seq.load(.monotonic));
    try testing.expectEqual(@as(i64, 5), vl.readAt(0).?.Long);
    // A shared borrow is no write: the sequence stays.
    {
        const g = vl.borrow();
        defer g.deinit();
        try testing.expectEqual(@as(i32, 2), vl.readAt(1).?.Int);
    }
    try testing.expectEqual(@as(u32, 2), vl.cell.lock.seq.load(.monotonic));
}

test "list reads with no lock racing writers that grow and free the buffer see only stored elements" {
    const a = @import("slab.zig").allocator;
    var list: std.ArrayList(Value) = .empty;
    try list.append(a, .{ .Int = 0 });
    const vl = try ValueList.init(a, list);
    // Element i always holds i, whichever buffer holds it: a read of a freed
    // buffer, or of a length paired with another buffer, would find otherwise.
    const Race = struct {
        vl: ValueList,
        a: std.mem.Allocator,
        stop: std.atomic.Value(bool) = .init(false),
        wrong: std.atomic.Value(usize) = .init(0),
        reads: std.atomic.Value(usize) = .init(0),
        hits: std.atomic.Value(usize) = .init(0),

        fn write(self: *@This()) void {
            var n: usize = 0;
            while (!self.stop.load(.monotonic)) : (n += 1) {
                const g = self.vl.borrowMut();
                defer g.deinit();
                const items = g.get();
                if (items.items.len >= 2 + n % 6) {
                    items.clearAndFree(self.a);
                } else {
                    items.append(self.a, .{ .Int = @intCast(items.items.len) }) catch return;
                }
            }
        }

        fn read(self: *@This()) void {
            var i: usize = 0;
            while (!self.stop.load(.monotonic)) : (i += 1) {
                _ = self.reads.fetchAdd(1, .monotonic);
                const at = i % 8;
                const v = self.vl.readAtMoving(at) orelse continue;
                _ = self.hits.fetchAdd(1, .monotonic);
                if (v != .Int or v.Int != @as(i32, @intCast(at))) _ = self.wrong.fetchAdd(1, .monotonic);
            }
        }
    };
    var race: Race = .{ .vl = vl, .a = a };
    var threads: [6]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, Race.write, .{&race});
    for (threads[1..]) |*t| t.* = try std.Thread.spawn(.{}, Race.read, .{&race});
    while (race.reads.load(.monotonic) < 2_000_000 or race.hits.load(.monotonic) < 100_000) std.atomic.spinLoopHint();
    race.stop.store(true, .monotonic);
    for (threads) |t| t.join();
    try testing.expectEqual(@as(usize, 0), race.wrong.load(.monotonic));
    vl.cell.data.deinit(a);
}

fn testSameKey(key: *const Value, k: *const Value) ?bool {
    return Value.structuralEqBoxed(k, key);
}

test "a map lookup with no lock finds an indexed entry, answers Null for a missing one, and leaves a writer's turn to the lock" {
    const a = @import("slab.zig").allocator;
    const entries = try MapEntries.init(a, .{});
    defer entries.cell.data.deinit(a);
    const st = &entries.cell.data;
    var k: i32 = 0;
    while (k < 40) : (k += 1) try st.append(a, .{ .key = .{ .Int = k }, .value = .{ .Int = k * 2 } });
    const probe: Value = .{ .Int = 7 };
    // Not yet indexed: the lock's lookup hashes the entries first.
    try testing.expect(lookupNoLock(entries, MapStore.keyHash(&probe).?, &probe, testSameKey, true) == null);
    _ = try st.find(a, &probe);
    try testing.expectEqual(@as(i32, 14), lookupNoLock(entries, MapStore.keyHash(&probe).?, &probe, testSameKey, true).?.Int);
    const absent: Value = .{ .Int = 99 };
    try testing.expect(lookupNoLock(entries, MapStore.keyHash(&absent).?, &absent, testSameKey, true).? == .Null);
    entries.cell.lock.seq.store(1, .monotonic);
    try testing.expect(lookupNoLock(entries, MapStore.keyHash(&probe).?, &probe, testSameKey, true) == null);
    entries.cell.lock.seq.store(0, .monotonic);
}

test "an Int key's lookup with no lock finds its entry, not a Long's of the same number, and answers Null for a missing one" {
    const a = @import("slab.zig").allocator;
    const entries = try MapEntries.init(a, .{});
    defer entries.cell.data.deinit(a);
    const st = &entries.cell.data;
    var k: i32 = 0;
    while (k < 40) : (k += 1) try st.append(a, .{ .key = .{ .Int = k }, .value = .{ .Int = k * 2 } });
    try st.append(a, .{ .key = .{ .Long = 50 }, .value = .{ .Int = -1 } });
    const probe: Value = .{ .Int = 7 };
    _ = try st.find(a, &probe);
    try testing.expectEqual(@as(i32, 14), lookupIntNoLock(entries, 7).?.Int);
    try testing.expectEqual(@as(i32, 78), lookupIntNoLock(entries, 39).?.Int);
    // `50L` is another key than `50`, as Kotlin's maps take them.
    try testing.expect(lookupIntNoLock(entries, 50).? == .Null);
    try testing.expect(lookupIntNoLock(entries, -3).? == .Null);
    // A writer's turn: the lock's.
    entries.cell.lock.seq.store(1, .monotonic);
    try testing.expect(lookupIntNoLock(entries, 7) == null);
    entries.cell.lock.seq.store(0, .monotonic);
}

test "map lookups with no lock racing a writer that grows, rehashes and frees see only stored values" {
    // Candidates checked before their keys are compared, and after.
    try raceMapLookups(true);
    try raceMapLookups(false);
}

fn raceMapLookups(derefs: bool) !void {
    const a = @import("slab.zig").allocator;
    const entries = try MapEntries.init(a, .{});
    const other = try MapEntries.init(a, .{});
    // Key k always maps to 2k, whichever arrays hold it. The other map, grown and
    // freed in turn, maps k to -k-1 in arrays of the same sizes, so a read of arrays
    // the first map freed and the other took finds a value no version held.
    const Race = struct {
        entries: MapEntries,
        other: MapEntries,
        a: std.mem.Allocator,
        derefs: bool,
        stop: std.atomic.Value(bool) = .init(false),
        wrong: std.atomic.Value(usize) = .init(0),
        reads: std.atomic.Value(usize) = .init(0),
        hits: std.atomic.Value(usize) = .init(0),

        fn write(self: *@This()) void {
            var n: usize = 0;
            while (!self.stop.load(.monotonic)) : (n += 1) {
                const which = if (n % 2 == 0) self.entries else self.other;
                const g = which.borrowMut();
                defer g.deinit();
                const st = g.get();
                const len = st.slots.items.len;
                // Now and then an entry out, leaving a hole the lookups must not land on.
                if (len >= MapStore.index_threshold and n % 5 == 0) {
                    const i = (n / 5) % len;
                    if (!st.isHole(i)) {
                        _ = st.removeAt(i);
                        st.compactIfSparse();
                    }
                    continue;
                }
                if (len >= 20 + (n / 2) % 40) {
                    st.deinit(self.a);
                    st.* = .{};
                    continue;
                }
                const k: i32 = @intCast(len);
                const v: i32 = if (n % 2 == 0) k * 2 else -k - 1;
                st.append(self.a, .{ .key = .{ .Int = k }, .value = .{ .Int = v } }) catch return;
                if (len + 1 >= MapStore.index_threshold) _ = st.find(self.a, &.{ .Int = k }) catch return;
            }
        }

        fn read(self: *@This()) void {
            var i: usize = 0;
            while (!self.stop.load(.monotonic)) : (i += 1) {
                _ = self.reads.fetchAdd(1, .monotonic);
                const key: Value = .{ .Int = @intCast(i % 24) };
                const hsh = MapStore.keyHash(&key).?;
                const got = if (self.derefs) lookupNoLock(self.entries, hsh, &key, testSameKey, true) else lookupNoLock(self.entries, hsh, &key, numericKeyEq, false);
                const v = got orelse continue;
                _ = self.hits.fetchAdd(1, .monotonic);
                if (v == .Null) continue;
                if (v != .Int or v.Int != key.Int * 2) _ = self.wrong.fetchAdd(1, .monotonic);
            }
        }
    };
    var race: Race = .{ .entries = entries, .other = other, .a = a, .derefs = derefs };
    var threads: [6]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, Race.write, .{&race});
    for (threads[1..]) |*t| t.* = try std.Thread.spawn(.{}, Race.read, .{&race});
    while (race.reads.load(.monotonic) < 2_000_000 or race.hits.load(.monotonic) < 100_000) std.atomic.spinLoopHint();
    race.stop.store(true, .monotonic);
    for (threads) |t| t.join();
    try testing.expectEqual(@as(usize, 0), race.wrong.load(.monotonic));
    entries.cell.data.deinit(a);
    other.cell.data.deinit(a);
}

test "reads with no lock racing writers that rewrite a whole Array see only whole stored values" {
    const a = std.heap.smp_allocator;
    const text = try strInit(a, "whole");
    defer text.deinit();
    // Each writer rewrites every element with one kind, byte by byte, so a
    // read that paired one kind's tag with another's payload is caught.
    const kinds = [_]Value{ .{ .Int = 0x5a5a5a5a }, .{ .String = text }, .Null, .{ .Long = -1 }, .{ .Double = 0.5 } };
    var list: std.ArrayList(Value) = .empty;
    try list.appendNTimes(a, kinds[0], 8);
    const vl = try ValueList.init(a, list);
    defer {
        for (vl.cell.data.items) |*v| v.* = .Null;
        vl.deinit();
    }
    const Race = struct {
        vl: ValueList,
        kinds: []const Value,
        stop: std.atomic.Value(bool) = .init(false),
        torn: std.atomic.Value(usize) = .init(0),
        reads: std.atomic.Value(usize) = .init(0),

        fn write(self: *@This(), which: usize) void {
            var n: usize = 0;
            while (!self.stop.load(.monotonic)) : (n += 1) {
                const g = self.vl.borrowMut();
                defer g.deinit();
                const v = self.kinds[(which + n) % self.kinds.len];
                const src = std.mem.asBytes(&v);
                for (g.get().items) |*e| {
                    const dst: *volatile [16]u8 = @ptrCast(e);
                    for (src, 0..) |b, i| dst[i] = b;
                }
            }
        }

        fn read(self: *@This()) void {
            var i: usize = 0;
            while (!self.stop.load(.monotonic)) : (i += 1) {
                const v = self.vl.readAt(i % 8) orelse continue;
                const whole = for (self.kinds) |k| {
                    if (std.mem.eql(u8, std.mem.asBytes(&k), std.mem.asBytes(&v))) break true;
                } else false;
                if (!whole) _ = self.torn.fetchAdd(1, .monotonic);
                _ = self.reads.fetchAdd(1, .monotonic);
            }
        }
    };
    var race: Race = .{ .vl = vl, .kinds = &kinds };
    var threads: [5]std.Thread = undefined;
    for (threads[0..2], 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Race.write, .{ &race, i });
    for (threads[2..]) |*t| t.* = try std.Thread.spawn(.{}, Race.read, .{&race});
    while (race.reads.load(.monotonic) < 200_000) std.atomic.spinLoopHint();
    race.stop.store(true, .monotonic);
    for (threads) |t| t.join();
    try testing.expectEqual(@as(usize, 0), race.torn.load(.monotonic));
}

test "javaHashCode answers as the JVM's hashCode for numbers, chars, booleans, strings and null" {
    const a = std.testing.allocator;
    const s = struct {
        fn str(al: std.mem.Allocator, text: []const u8) !Value {
            return .{ .String = try strInit(al, text) };
        }
    };
    const cases = [_]struct { []const u8, i32 }{ .{ "a", 97 }, .{ "hello", 99162322 }, .{ "\u{1F600}x", 54959989 }, .{ "\u{e4}", 228 } };
    for (cases) |c| {
        const v = try s.str(a, c[0]);
        defer v.release(a);
        try std.testing.expectEqual(@as(?i32, c[1]), v.javaHashCode());
    }
    try std.testing.expectEqual(@as(?i32, -1097262584), (Value{ .Long = 123456789012 }).javaHashCode());
    try std.testing.expectEqual(@as(?i32, 0), (Value{ .Long = -1 }).javaHashCode());
    try std.testing.expectEqual(@as(?i32, 1073217536), (Value{ .Double = 1.5 }).javaHashCode());
    try std.testing.expectEqual(@as(?i32, 2146959360), (Value{ .Double = std.math.nan(f64) }).javaHashCode());
    try std.testing.expectEqual(@as(?i32, -2147483648), (Value{ .Double = -0.0 }).javaHashCode());
    try std.testing.expectEqual(@as(?i32, 1075838976), (Value{ .Float = 2.5 }).javaHashCode());
    try std.testing.expectEqual(@as(?i32, 1231), (Value{ .Bool = true }).javaHashCode());
    try std.testing.expectEqual(@as(?i32, 1237), (Value{ .Bool = false }).javaHashCode());
    try std.testing.expectEqual(@as(?i32, 90), (Value{ .Char = 'Z' }).javaHashCode());
    try std.testing.expectEqual(@as(?i32, -1), (Value{ .UShort = 65535 }).javaHashCode());
    try std.testing.expectEqual(@as(?i32, -294967296), (Value{ .UInt = 4000000000 }).javaHashCode());
    try std.testing.expectEqual(@as(?i32, 0), (@as(Value, .Null)).javaHashCode());
}

test "a value index finds positions by hash, keeps the loose ones for every lookup, and closes removals' holes up" {
    var ix: ValueIndex = .{};
    defer ix.deinit(std.testing.allocator);
    // Forty positions: hashes 0..39 with 7 twice, and position 5 without one.
    for (0..40) |i| try ix.push(if (i == 5) ValueIndex.no_hash else if (i == 30) 7 else @as(u64, i));
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(std.testing.allocator);
    try ix.candidates(7, &out, std.testing.allocator);
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &.{ 5, 7, 30 }, out.items);
    // Positions 3 and 30 go as holes: no lookup offers them, the others stay where they are.
    ix.removeHole(3);
    ix.removeHole(30);
    out.clearRetainingCapacity();
    try ix.candidates(7, &out, std.testing.allocator);
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &.{ 5, 7 }, out.items);
    out.clearRetainingCapacity();
    try ix.candidates(ValueIndex.no_hash, &out, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 38), out.items.len);
    // Closed up: 7 moves to 6, the loose one to 4, 31 to 29.
    ix.compact();
    try std.testing.expectEqual(@as(usize, 38), ix.len());
    out.clearRetainingCapacity();
    try ix.candidates(7, &out, std.testing.allocator);
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &.{ 4, 6 }, out.items);
    out.clearRetainingCapacity();
    try ix.candidates(31, &out, std.testing.allocator);
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &.{ 4, 29 }, out.items);
    // A needle with no hash may equal any element.
    out.clearRetainingCapacity();
    try ix.candidates(ValueIndex.no_hash, &out, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 38), out.items.len);
    ix.clear();
    out.clearRetainingCapacity();
    try ix.candidates(7, &out, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "a map finds a pair key by its components' hashes" {
    var mem = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer mem.deinit();
    const a = mem.allocator();
    const prev = objcell.reclaimEnabled();
    objcell.setReclaim(false);
    defer objcell.setReclaim(prev);
    const p1 = try Value.newPair(a, .{ .first = try Value.boxRef(a, Value.newInt(3)), .second = try Value.boxRef(a, .{ .String = try strInit(a, "x") }) });
    const p2 = try Value.newPair(a, .{ .first = try Value.boxRef(a, Value.newInt(3)), .second = try Value.boxRef(a, .{ .String = try strInit(a, "x") }) });
    const p3 = try Value.newPair(a, .{ .first = try Value.boxRef(a, Value.newInt(4)), .second = try Value.boxRef(a, .{ .String = try strInit(a, "x") }) });
    try std.testing.expect(MapStore.keyHash(&p1) != null);
    try std.testing.expectEqual(MapStore.keyHash(&p1), MapStore.keyHash(&p2));
    try std.testing.expect(MapStore.keyHash(&p1).? != MapStore.keyHash(&p3).?);
    // Past the scan threshold the store looks keys up by hash.
    var store: MapStore = .{};
    for (0..40) |i| {
        const k = try Value.newPair(a, .{ .first = try Value.boxRef(a, Value.newInt(@intCast(i))), .second = try Value.boxRef(a, .{ .String = try strInit(a, "x") }) });
        try store.append(a, .{ .key = k, .value = Value.newInt(@intCast(i)) });
    }
    try std.testing.expectEqual(@as(?usize, 3), try store.find(a, &p1));
    try std.testing.expectEqual(@as(?usize, 4), try store.find(a, &p3));
    try std.testing.expectEqual(@as(usize, 40), store.hashes.items.len);
}
