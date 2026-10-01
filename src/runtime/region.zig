//! The region heap. Most cells a mutator makes are bumped out of 256 KB
//! blocks of 128-byte lines instead of being allocated one by one: the
//! thread takes a run of free lines (a hole) and hands out consecutive
//! addresses from it. A cell's trace marks every line the cell overlaps, and
//! a line no live cell overlaps is free again once the collection that left
//! it unmarked has swept its block. Cells never move.
//!
//! A line's mark is the collection cycle that last found a live cell on it.
//! The cycle advances when a major begins, and a line is live while its mark
//! lies between the cycle of the last major that finished and the current
//! one. A minor marks the lines of the cells it tenures; the tenured cells it
//! does not look at keep the lines their last major or minor marked, so only
//! the lines of the nursery cells it missed come free. A major marks every
//! live cell's lines anew, so the lines of tenured cells it did not reach
//! fall behind the cycle and come free once it finishes. A dead line reads 0
//! after its block is swept, which keeps every mark within a cycle or two of
//! the current one.
//!
//! Blocks are on one of five lists: `used` (taken by a mutator since the last
//! collection), `recyclable` (at least `recycle_min_lines` free), `full`,
//! `free` (no live line) and `cold` (free, its pages returned to the OS). A
//! collection's stop takes `used`, and a major's also `recyclable` and
//! `full`, for its sweep; the sweeper reads each block's marks and files it.
//! A block in a sweep is on no list, so no mutator allocates in it until the
//! sweeper has read it. The marking thread, tracing a major between stops,
//! writes only lines of tenured cells, which every sweep reads as live.

const std = @import("std");
const slab = @import("slab.zig");
const platform = @import("platform.zig");

pub const block_size: usize = 256 * 1024;
pub const line_size: usize = 128;
const line_shift: u6 = 7;
pub const lines_per_block: usize = block_size / line_size;
/// A larger cell is allocated one slab cell at a time.
pub const max_cell: usize = 8 * 1024;
/// A swept block with fewer free lines is full until the next major.
const recycle_min_lines: u32 = 8;
/// A hole with at least this much left is kept for smaller cells when a
/// cell over a line does not fit it; a smaller rest is given up, so a run of
/// such cells bumps the hole compiled code bumps rather than the overflow.
const keep_hole_bytes: usize = 4 * line_size;
/// Free blocks kept warm; `trim` returns the pages of the rest to the OS.
const warm_blocks: usize = 32;

pub const Block = extern struct {
    /// Where a slab's header keeps its class index: a small allocation's
    /// block, masked from its address, says whose memory it is (`slab.free`).
    tag: u32 = slab.region_tag,
    free_lines: u32 = 0,
    next: ?*Block = null,
    marks: [lines_per_block]u8,
};

/// The block's header and marks fill its first lines, which never hold cells.
pub const first_line: usize = (@sizeOf(Block) + line_size - 1) / line_size;

comptime {
    std.debug.assert(block_size == slab.block_size);
    std.debug.assert(first_line < lines_per_block / 64);
}

inline fn blockOf(addr: usize) *Block {
    return @ptrFromInt(addr & ~(block_size - 1));
}

inline fn blockBase(b: *Block) usize {
    return @intFromPtr(b);
}

// The cycle. Both change only inside a collection's stop; a marker and a
// sweep take their values when they begin.
var cycle_cur: u8 = 1;
var cycle_base: u8 = 1;

fn nextCycle(c: u8) u8 {
    const n = c +% 1;
    return if (n == 0) 1 else n; // 0 marks a free line
}

/// The mark a collection beginning now writes.
pub fn cycle() u8 {
    return cycle_cur;
}

/// The cycle of the last major that finished.
pub fn baseCycle() u8 {
    return cycle_base;
}

/// A major begins. One begun and dropped left the cycle advanced, and the
/// next major reuses it: lines the dropped one marked stay live through it,
/// so nothing it marked is freed early, and the cycle never runs more than
/// one ahead of the base.
pub fn beginMajor() void {
    if (cycle_cur == cycle_base) cycle_cur = nextCycle(cycle_cur);
}

/// The major finished: lines it did not mark fall behind.
pub fn finishMajor() void {
    cycle_base = cycle_cur;
}

inline fn lineLive(mark: u8, base: u8, cur: u8) bool {
    return mark != 0 and (mark -% base) <= (cur -% base);
}

/// Marks every line `[addr, addr + size)` overlaps with `mark`.
pub inline fn markLines(addr: usize, size: usize, mark: u8) void {
    const b = blockOf(addr);
    const off = addr - blockBase(b);
    var i = off >> line_shift;
    const last = (off + size - 1) >> line_shift;
    while (i <= last) : (i += 1) @atomicStore(u8, &b.marks[i], mark, .monotonic);
}

/// Whether `addr` is region memory that the last sweep left on a live line,
/// for tests.
pub fn lineMarkAt(addr: usize) u8 {
    const b = blockOf(addr);
    return @atomicLoad(u8, &b.marks[(addr - blockBase(b)) >> line_shift], .monotonic);
}

/// A run of free lines being bumped through, and where in its block the
/// search for the next one starts.
pub const Run = struct {
    cursor: usize = 0,
    limit: usize = 0,
    block: ?*Block = null,
    line: usize = 0,

    /// Moves to the next hole of at least `min` bytes, in this block or the
    /// next one taken. Returns the hole's bytes, or null when no block can
    /// be mapped. Holes passed over stay free for the next sweep to count.
    fn next(r: *Run, min: usize) ?usize {
        while (true) {
            if (r.block) |b| {
                while (r.line < lines_per_block) {
                    var i = r.line;
                    while (i < lines_per_block and @atomicLoad(u8, &b.marks[i], .monotonic) != 0) i += 1;
                    if (i >= lines_per_block) {
                        r.line = lines_per_block;
                        break;
                    }
                    var j = i + 1;
                    while (j < lines_per_block and @atomicLoad(u8, &b.marks[j], .monotonic) == 0) j += 1;
                    r.line = j;
                    const len = (j - i) * line_size;
                    if (len < min) continue;
                    r.cursor = blockBase(b) + i * line_size;
                    r.limit = blockBase(b) + j * line_size;
                    return len;
                }
            }
            r.block = acquire() orelse return null;
            r.line = first_line;
        }
    }
};

/// A mutator's allocation state: the hole it bumps cells through, and a
/// second run for a cell over a line that does not fit the rest of a hole
/// still worth keeping for smaller cells (`keep_hole_bytes`).
pub const Tlab = struct {
    main: Run = .{},
    overflow: Run = .{},
    /// Bytes of the holes taken since the owner last counted them.
    taken: usize = 0,

    /// Stops allocating from the current holes; the blocks stay on `used`
    /// for the next sweep.
    pub fn retire(t: *Tlab) void {
        t.* = .{ .taken = t.taken };
    }

    /// Bumps `n` bytes, a multiple of 16 no larger than `max_cell`, once
    /// the current hole does not hold them. Null when no block can be
    /// mapped.
    pub fn allocSlow(t: *Tlab, n: usize) ?usize {
        std.debug.assert(n <= max_cell and n % 16 == 0);
        while (true) {
            const left = t.main.limit - t.main.cursor;
            if (left >= n) {
                const p = t.main.cursor;
                t.main.cursor += n;
                return p;
            }
            if (n > line_size and left >= keep_hole_bytes) return t.allocOverflow(n);
            t.taken += t.main.next(0) orelse return null;
        }
    }

    fn allocOverflow(t: *Tlab, n: usize) ?usize {
        if (t.overflow.limit - t.overflow.cursor < n) t.taken += t.overflow.next(n) orelse return null;
        const p = t.overflow.cursor;
        t.overflow.cursor += n;
        return p;
    }
};

const SpinLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *SpinLock) void {
        while (self.state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

const Pool = struct {
    lock: SpinLock = .{},
    used: ?*Block = null,
    recyclable: ?*Block = null,
    full: ?*Block = null,
    free: ?*Block = null,
    free_count: usize = 0,
    cold: ?*Block = null,
    /// Blocks mapped, for the reports.
    mapped: usize = 0,
};
var pool: Pool = .{};

fn push(list: *?*Block, b: *Block) void {
    b.next = list.*;
    list.* = b;
}

fn pop(list: *?*Block) ?*Block {
    const b = list.* orelse return null;
    list.* = b.next;
    return b;
}

/// Every block the region has mapped, by address: two levels of bits over
/// the 48-bit address space, a leaf of 64 K blocks (16 GB) made on the first
/// block in its span. Bits are only ever set, so `owns` reads them with no
/// lock.
const leaf_blocks: usize = 1 << 16;
const Leaf = [leaf_blocks / 64]std.atomic.Value(u64);
var leaves: [1 << 14]std.atomic.Value(?*Leaf) = [_]std.atomic.Value(?*Leaf){.init(null)} ** (1 << 14);
/// False once a block could not be noted (an address past 48 bits, or no
/// memory for a leaf): the region then holds no buffers, since an owner
/// could not tell its buffer's lines were its to mark.
pub var buffers_ok: bool = true;

fn note(b: *Block) void {
    const idx = blockBase(b) >> 18;
    const hi = idx / leaf_blocks;
    if (hi >= leaves.len) {
        buffers_ok = false;
        return;
    }
    const leaf = leaves[hi].load(.acquire) orelse blk: {
        const fresh = std.heap.page_allocator.create(Leaf) catch {
            buffers_ok = false;
            return;
        };
        for (fresh) |*w| w.* = .init(0);
        if (leaves[hi].cmpxchgStrong(null, fresh, .acq_rel, .acquire)) |won| {
            std.heap.page_allocator.destroy(fresh);
            break :blk won.?;
        }
        break :blk fresh;
    };
    const lo = idx % leaf_blocks;
    _ = leaf[lo / 64].fetchOr(@as(u64, 1) << @intCast(lo % 64), .release);
}

/// Whether `addr` is in a block the region mapped: memory from any allocator
/// may be asked about.
pub fn owns(addr: usize) bool {
    const idx = addr >> 18;
    const hi = idx / leaf_blocks;
    if (hi >= leaves.len) return false;
    const leaf = leaves[hi].load(.acquire) orelse return false;
    const lo = idx % leaf_blocks;
    return leaf[lo / 64].load(.acquire) & (@as(u64, 1) << @intCast(lo % 64)) != 0;
}

/// A block to allocate in, onto `used`: a recyclable one, else a free one,
/// a cold one, or a new mapping.
fn acquire() ?*Block {
    pool.lock.lock();
    var b: ?*Block = pop(&pool.recyclable);
    if (b == null) {
        b = pop(&pool.free);
        if (b != null) pool.free_count -= 1;
    }
    if (b == null) b = pop(&pool.cold);
    if (b) |x| push(&pool.used, x);
    pool.lock.unlock();
    if (b) |x| return x;
    const fresh: *Block = @ptrFromInt(slab.mapBlock() orelse return null);
    note(fresh);
    fresh.tag = slab.region_tag;
    fresh.next = null;
    fresh.free_lines = @intCast(lines_per_block - first_line);
    @memset(&fresh.marks, 0);
    pool.lock.lock();
    push(&pool.used, fresh);
    pool.mapped += 1;
    pool.lock.unlock();
    return fresh;
}

/// The blocks a collection sweeps, taken inside its stop after every
/// mutator's holes are retired: those taken since the last collection, and
/// for a major every block that holds a line.
pub fn takeForSweep(major: bool) ?*Block {
    pool.lock.lock();
    defer pool.lock.unlock();
    var head = pool.used;
    pool.used = null;
    if (major) {
        inline for (.{ &pool.recyclable, &pool.full }) |list| {
            while (pop(list)) |b| push(&head, b);
        }
    }
    return head;
}

pub const SweepCounts = struct { blocks: usize = 0, free_blocks: usize = 0, free_lines: usize = 0 };

/// Reads the marks of every block on `head`, zeroes its dead lines and files
/// it. `base` and `cur` are the cycles the collection that took the blocks
/// left: a line is live when its mark is between them. Runs on the sweeper,
/// or inside the stop, after the dead cells on the lists are finalized.
pub fn sweepBlocks(head: ?*Block, base: u8, cur: u8) SweepCounts {
    var counts: SweepCounts = .{};
    var free: ?*Block = null;
    var free_n: usize = 0;
    var recyclable: ?*Block = null;
    var full: ?*Block = null;
    const V = @Vector(16, u8);
    const vbase: V = @splat(base);
    const vspan: V = @splat(cur -% base);
    const zero: V = @splat(0);
    var cur_b = head;
    while (cur_b) |b| {
        cur_b = b.next;
        var free_lines: u32 = 0;
        // The header's lines are skipped; the first chunk starts on the
        // first line whole chunks of 16 reach.
        var i: usize = first_line;
        while (i % 16 != 0) : (i += 1) {
            const m = @atomicLoad(u8, &b.marks[i], .monotonic);
            if (lineLive(m, base, cur)) continue;
            if (m != 0) @atomicStore(u8, &b.marks[i], 0, .monotonic);
            free_lines += 1;
        }
        while (i < lines_per_block) : (i += 16) {
            // A plain vector read: a concurrent mark only rewrites a live
            // line with another live value, and only dead lines are written.
            const m: V = b.marks[i..][0..16].*;
            const nonzero: u16 = @bitCast(m != zero);
            const in_span: u16 = @bitCast((m -% vbase) <= vspan);
            const live = nonzero & in_span;
            const dead_n = 16 - @as(u32, @popCount(live));
            if (dead_n == 0) continue;
            free_lines += dead_n;
            var stale = nonzero & ~live;
            while (stale != 0) : (stale &= stale - 1) {
                @atomicStore(u8, &b.marks[i + @ctz(stale)], 0, .monotonic);
            }
        }
        b.free_lines = free_lines;
        counts.blocks += 1;
        counts.free_lines += free_lines;
        if (free_lines == lines_per_block - first_line) {
            push(&free, b);
            free_n += 1;
            counts.free_blocks += 1;
        } else if (free_lines >= recycle_min_lines) {
            push(&recyclable, b);
        } else {
            push(&full, b);
        }
    }
    pool.lock.lock();
    defer pool.lock.unlock();
    inline for (.{ .{ &free, &pool.free }, .{ &recyclable, &pool.recyclable }, .{ &full, &pool.full } }) |pair| {
        while (pop(pair[0])) |b| push(pair[1], b);
    }
    pool.free_count += free_n;
    return counts;
}

/// Once twice the warm blocks are free, returns the pages of the ones past
/// the warm ones to the OS; they stay mapped and are taken after the warm
/// ones.
pub fn trim() void {
    var extra: ?*Block = null;
    {
        pool.lock.lock();
        defer pool.lock.unlock();
        if (pool.free_count < 2 * warm_blocks) return;
        while (pool.free_count > warm_blocks) {
            push(&extra, pop(&pool.free).?);
            pool.free_count -= 1;
        }
    }
    if (extra == null) return;
    var cur_b = extra;
    var cold_head: ?*Block = null;
    while (cur_b) |b| {
        cur_b = b.next;
        // The header and marks stay; every line after them is zero-filled
        // on its next touch.
        const start = std.mem.alignForward(usize, blockBase(b) + first_line * line_size, std.heap.page_size_min);
        platform.discard(start, blockBase(b) + block_size - start);
        push(&cold_head, b);
    }
    pool.lock.lock();
    defer pool.lock.unlock();
    while (pop(&cold_head)) |b| push(&pool.cold, b);
}

/// A forked child has only the forking thread, which may have forked while
/// another held the lock; the lists stay as they were.
pub fn resetLockInChild() void {
    pool.lock = .{};
}

pub fn mappedBlocks() usize {
    return pool.mapped;
}

const testing = std.testing;

test "a line's mark is live from the last finished major's cycle to the current one" {
    try testing.expect(lineLive(3, 3, 3));
    try testing.expect(!lineLive(2, 3, 3));
    try testing.expect(!lineLive(0, 3, 3));
    try testing.expect(lineLive(3, 3, 4));
    try testing.expect(lineLive(4, 3, 4));
    try testing.expect(!lineLive(5, 3, 4));
    // Across the wrap, which skips 0.
    try testing.expect(lineLive(255, 255, 1));
    try testing.expect(lineLive(1, 255, 1));
    try testing.expect(!lineLive(254, 255, 1));
    try testing.expectEqual(@as(u8, 1), nextCycle(255));
}

test "a dropped major's cycle is reused by the next one" {
    const saved_cur = cycle_cur;
    const saved_base = cycle_base;
    defer {
        cycle_cur = saved_cur;
        cycle_base = saved_base;
    }
    cycle_cur = 7;
    cycle_base = 7;
    beginMajor();
    try testing.expectEqual(@as(u8, 8), cycle());
    beginMajor(); // the first was dropped
    try testing.expectEqual(@as(u8, 8), cycle());
    finishMajor();
    try testing.expectEqual(@as(u8, 8), baseCycle());
    beginMajor();
    try testing.expectEqual(@as(u8, 9), cycle());
}

test "holes skip marked lines and a sweep files blocks by their free lines" {
    const saved = pool;
    pool = .{};
    defer pool = saved;
    var t: Tlab = .{};
    const a = t.allocSlow(64).?;
    const b0 = blockOf(a);
    try testing.expectEqual(blockBase(b0) + first_line * line_size, a);
    // A cell over a line boundary marks both lines.
    const c = t.allocSlow(96).?;
    try testing.expectEqual(a + 64, c);
    markLines(c, 96, 5);
    try testing.expectEqual(@as(u8, 5), b0.marks[first_line]);
    try testing.expectEqual(@as(u8, 5), b0.marks[first_line + 1]);
    try testing.expectEqual(@as(u8, 0), b0.marks[first_line + 2]);
    t.retire();
    try testing.expectEqual(b0, takeForSweep(false).?);
    // Cycle 5 is live, so two lines stay marked.
    const counts = sweepBlocks(b0, 5, 5);
    try testing.expectEqual(@as(usize, 1), counts.blocks);
    try testing.expectEqual(@as(usize, lines_per_block - first_line - 2), counts.free_lines);
    try testing.expectEqual(b0, pool.recyclable.?);
    // The next hole starts after the live lines.
    t.taken = 0;
    const d = t.allocSlow(16).?;
    try testing.expectEqual(blockBase(b0) + (first_line + 2) * line_size, d);
    try testing.expectEqual((lines_per_block - first_line - 2) * line_size, t.taken);
    t.retire();
    // A major that did not reach the cell frees its lines.
    try testing.expectEqual(b0, takeForSweep(true).?);
    const after = sweepBlocks(b0, 6, 6);
    try testing.expectEqual(@as(usize, 1), after.free_blocks);
    try testing.expectEqual(@as(u8, 0), b0.marks[first_line]);
    try testing.expectEqual(b0, pool.free.?);
    try testing.expectEqual(@as(usize, 1), mappedBlocks());
}

test "a cell over a line goes to the overflow run only while the hole is worth keeping" {
    const saved = pool;
    pool = .{};
    defer pool = saved;
    var t: Tlab = .{};
    const a = t.allocSlow(16).?;
    const b0 = blockOf(a);
    const end = blockBase(b0) + block_size;
    // Six lines left: eight do not fit, and the six are kept for smaller cells.
    t.main.cursor = end - 6 * line_size;
    const big = t.allocSlow(8 * line_size).?;
    try testing.expect(big < t.main.cursor or big >= end);
    try testing.expectEqual(end - 6 * line_size, t.main.cursor);
    // A small cell still bumps the kept hole.
    const small = t.allocSlow(32).?;
    try testing.expectEqual(end - 6 * line_size, small);
    // Under `keep_hole_bytes` left, a cell that does not fit moves the hole on
    // instead: a run of cells a little over a line keeps to the main hole.
    t.main.cursor = end - line_size;
    const next = t.allocSlow(line_size + 32).?;
    try testing.expectEqual(t.main.cursor - (line_size + 32), next);
    try testing.expect(next < blockBase(b0) or next >= end);
    t.retire();
    _ = sweepBlocks(takeForSweep(true), 1, 1);
}
