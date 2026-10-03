//! An arena whose large allocations are blocks of their own. A plain arena
//! keeps every buffer a growing list outgrew: a table that grows by half to
//! its final size leaves twice that size behind. Here an allocation of
//! `threshold` bytes or more is mapped by itself, unmapped when it is freed,
//! and grown in place where the system can (`mremap` on Linux). Everything
//! smaller is the wrapped arena's, and `deinit` frees both.
//!
//! Thread safe, as the wrapped arena is: large blocks are listed under a
//! lock, which only their allocation, move and free take.
//!
//! `KLIO_ARENA_GUARD=1` keeps a freed large block mapped with no access
//! until `deinit`: a read through a pointer into it faults at once instead
//! of reading whatever the address is mapped for next.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const LargeArena = struct {
    arena: std.heap.ArenaAllocator,
    /// Every large block not yet freed, newest first.
    blocks: ?*Block = null,
    lock: std.atomic.Value(bool) = .init(false),
    /// `KLIO_ARENA_GUARD`: freed large blocks stay mapped without access.
    guard: bool = false,
    /// The mappings `guard` kept, unmapped by `deinit`.
    guarded: std.ArrayList([]u8) = .empty,

    /// The smallest allocation that is a block of its own.
    pub const threshold: usize = 64 * 1024;

    /// Sits right before a large allocation's bytes, at the end of the
    /// header space its alignment rounds up to.
    const Block = struct {
        prev: ?*Block,
        next: ?*Block,
        /// The mapping's length, header space included.
        len: usize,
        /// The header space: where the mapping starts, before the bytes.
        head: usize,
    };

    const block_align: Alignment = .of(Block);

    pub fn init(child: Allocator) LargeArena {
        const guard = builtin.os.tag != .windows and builtin.link_libc and std.c.getenv("KLIO_ARENA_GUARD") != null;
        return .{ .arena = .init(child), .guard = guard };
    }

    pub fn allocator(self: *LargeArena) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    pub fn deinit(self: *LargeArena) void {
        var it = self.blocks;
        while (it) |b| {
            it = b.next;
            std.heap.page_allocator.rawFree(mapping(b), block_align, @returnAddress());
        }
        self.blocks = null;
        for (self.guarded.items) |m| std.heap.page_allocator.rawFree(m, block_align, @returnAddress());
        self.arena.deinit();
    }

    /// Bytes in large blocks now: what the arena holds outside its own.
    pub fn largeBytes(self: *LargeArena) usize {
        self.acquire();
        defer self.release();
        var n: usize = 0;
        var it = self.blocks;
        while (it) |b| : (it = b.next) n += b.len;
        return n;
    }

    fn isLarge(len: usize, alignment: Alignment) bool {
        return len >= threshold and alignment.toByteUnits() <= std.heap.page_size_min;
    }

    /// The header space before a large allocation's bytes: room for the
    /// block, rounded to the allocation's alignment, so the bytes land
    /// aligned on the page-aligned mapping.
    fn headerLen(alignment: Alignment) usize {
        return std.mem.alignForward(usize, @sizeOf(Block), @max(alignment.toByteUnits(), @alignOf(Block)));
    }

    fn blockOf(memory: [*]u8) *Block {
        return @ptrCast(@alignCast(memory - @sizeOf(Block)));
    }

    fn mapping(b: *Block) []u8 {
        const at: [*]u8 = @ptrCast(b);
        return (at + @sizeOf(Block) - b.head)[0..b.len];
    }

    fn acquire(self: *LargeArena) void {
        while (self.lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn release(self: *LargeArena) void {
        self.lock.store(false, .release);
    }

    fn link(self: *LargeArena, b: *Block) void {
        b.prev = null;
        b.next = self.blocks;
        if (self.blocks) |h| h.prev = b;
        self.blocks = b;
    }

    fn unlink(self: *LargeArena, b: *Block) void {
        if (b.prev) |p| p.next = b.next else self.blocks = b.next;
        if (b.next) |n| n.prev = b.prev;
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *LargeArena = @ptrCast(@alignCast(ctx));
        if (!isLarge(n, alignment)) return self.arena.allocator().rawAlloc(n, alignment, ra);
        const h = headerLen(alignment);
        const base = std.heap.page_allocator.rawAlloc(h + n, block_align, ra) orelse return null;
        const payload = base + h;
        const b = blockOf(payload);
        b.len = h + n;
        b.head = h;
        self.acquire();
        defer self.release();
        self.link(b);
        return payload;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        const self: *LargeArena = @ptrCast(@alignCast(ctx));
        // An allocation stays on the side it was made on: its length says
        // which, when it is freed.
        if (isLarge(memory.len, alignment) != isLarge(new_len, alignment)) return false;
        if (!isLarge(memory.len, alignment)) return self.arena.allocator().rawResize(memory, alignment, new_len, ra);
        const b = blockOf(memory.ptr);
        if (!std.heap.page_allocator.rawResize(mapping(b), block_align, b.head + new_len, ra)) return false;
        b.len = b.head + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *LargeArena = @ptrCast(@alignCast(ctx));
        if (isLarge(memory.len, alignment) != isLarge(new_len, alignment)) return null;
        if (!isLarge(memory.len, alignment)) return self.arena.allocator().rawRemap(memory, alignment, new_len, ra);
        const old = blockOf(memory.ptr);
        const h = old.head;
        // A move rewrites the block where its neighbors point to it.
        self.acquire();
        defer self.release();
        self.unlink(old);
        const base = std.heap.page_allocator.rawRemap(mapping(old), block_align, h + new_len, ra) orelse {
            self.link(old);
            return null;
        };
        const b = blockOf(base + h);
        b.len = h + new_len;
        b.head = h;
        self.link(b);
        return base + h;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *LargeArena = @ptrCast(@alignCast(ctx));
        if (!isLarge(memory.len, alignment)) return self.arena.allocator().rawFree(memory, alignment, ra);
        const b = blockOf(memory.ptr);
        const m = mapping(b);
        {
            self.acquire();
            defer self.release();
            self.unlink(b);
            if (self.guard) {
                if (builtin.os.tag != .windows and builtin.link_libc) {
                    self.guarded.append(self.arena.allocator(), m) catch {};
                    _ = std.c.mprotect(@ptrCast(@alignCast(m.ptr)), m.len, .{});
                }
                return;
            }
        }
        std.heap.page_allocator.rawFree(m, block_align, ra);
    }
};

test "a list grown past the threshold keeps only its last buffer" {
    var la = LargeArena.init(std.heap.page_allocator);
    defer la.deinit();
    const a = la.allocator();
    var list: std.ArrayList(u64) = .empty;
    var i: u64 = 0;
    while (i < 200_000) : (i += 1) try list.append(a, i);
    for (list.items, 0..) |v, j| try std.testing.expectEqual(@as(u64, j), v);
    // One block holds the list, however many it outgrew.
    var blocks: usize = 0;
    var it = la.blocks;
    while (it) |b| : (it = b.next) blocks += 1;
    try std.testing.expectEqual(@as(usize, 1), blocks);
    try std.testing.expect(la.largeBytes() >= list.capacity * @sizeOf(u64));
    list.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), la.largeBytes());
}

test "large allocations of any alignment free in any order, small ones stay in the arena" {
    var la = LargeArena.init(std.heap.page_allocator);
    defer la.deinit();
    const a = la.allocator();
    const x = try a.alloc(u8, LargeArena.threshold);
    const y = try a.alignedAlloc(u8, .@"64", LargeArena.threshold * 3);
    const z = try a.alloc(u32, LargeArena.threshold);
    const small = try a.alloc(u8, 100);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(y.ptr), 64));
    @memset(x, 1);
    @memset(y, 2);
    @memset(z, 3);
    @memset(small, 4);
    a.free(y);
    try std.testing.expectEqual(@as(u8, 1), x[x.len - 1]);
    try std.testing.expectEqual(@as(u32, 3), z[z.len - 1]);
    a.free(x);
    a.free(z);
    try std.testing.expectEqual(@as(usize, 0), la.largeBytes());
    try std.testing.expectEqual(@as(u8, 4), small[99]);
}

test "a page-aligned large allocation frees its whole mapping" {
    var la = LargeArena.init(std.heap.page_allocator);
    defer la.deinit();
    const a = la.allocator();
    const p = try a.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), LargeArena.threshold);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(p.ptr), std.heap.page_size_min));
    @memset(p, 7);
    try std.testing.expectEqual(LargeArena.threshold + std.heap.page_size_min, la.largeBytes());
    a.free(p);
    try std.testing.expectEqual(@as(usize, 0), la.largeBytes());
}

test "an allocation does not cross the threshold in place" {
    var la = LargeArena.init(std.heap.page_allocator);
    defer la.deinit();
    const a = la.allocator();
    const small = try a.alloc(u8, 1000);
    try std.testing.expect(!a.resize(small, LargeArena.threshold));
    const big = try a.alloc(u8, LargeArena.threshold * 2);
    try std.testing.expect(!a.resize(big, 1000));
    try std.testing.expect(a.resize(big, LargeArena.threshold));
    const shrunk: []u8 = big[0..LargeArena.threshold];
    a.free(shrunk);
    try std.testing.expectEqual(@as(usize, 0), la.largeBytes());
}
