//! The bump allocator a resolution works in (`Sema.scratch`). It is emptied
//! whole (`reset`), keeping its first chunks mapped for the next
//! declaration up to a limit, so a declaration does not fault fresh pages
//! in. Freeing or resizing in place works for the latest allocation only.
//! Not thread safe: an analysis resolves its bodies on one thread.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Scratch = struct {
    /// Mapped chunks; those after `cur` are empty, ready for reuse. The list
    /// itself is held by the page allocator.
    chunks: std.ArrayList([]u8) = .empty,
    cur: usize = 0,
    /// Bytes of `chunks[cur]` in use.
    used: usize = 0,
    /// The most bytes in use when it was emptied.
    high: usize = 0,

    const min_chunk: usize = 256 * 1024;
    const chunk_align: Alignment = .fromByteUnits(std.heap.page_size_min);

    pub fn allocator(self: *Scratch) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Bytes in use: every chunk before the current one, and the current
    /// one's used part.
    pub fn inUse(self: *const Scratch) usize {
        var n: usize = self.used;
        for (self.chunks.items[0..@min(self.cur, self.chunks.items.len)]) |c| n += c.len;
        return n;
    }

    /// Empties it, keeping its first chunks while they total at most
    /// `keep` bytes.
    pub fn reset(self: *Scratch, keep: usize) void {
        self.high = @max(self.high, self.inUse());
        var total: usize = 0;
        var kept: usize = 0;
        for (self.chunks.items) |c| {
            if (total + c.len <= keep) {
                total += c.len;
                self.chunks.items[kept] = c;
                kept += 1;
            } else {
                std.heap.page_allocator.rawFree(c, chunk_align, @returnAddress());
            }
        }
        self.chunks.shrinkRetainingCapacity(kept);
        self.cur = 0;
        self.used = 0;
    }

    pub fn deinit(self: *Scratch) void {
        self.reset(0);
        self.chunks.deinit(std.heap.page_allocator);
        self.* = .{ .high = self.high };
    }

    fn startIn(c: []u8, used: usize, alignment: Alignment) usize {
        const base = @intFromPtr(c.ptr);
        return alignment.forward(base + used) - base;
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        while (true) {
            if (self.cur < self.chunks.items.len) {
                const c = self.chunks.items[self.cur];
                const start = startIn(c, self.used, alignment);
                if (start + n <= c.len) {
                    self.used = start + n;
                    return c.ptr + start;
                }
                // The next empty chunk, when it holds the allocation.
                if (self.cur + 1 < self.chunks.items.len) {
                    const next = self.chunks.items[self.cur + 1];
                    if (startIn(next, 0, alignment) + n <= next.len) {
                        self.cur += 1;
                        self.used = 0;
                        continue;
                    }
                }
            }
            // A new chunk, at least half again what is mapped so far, goes
            // after the current one: the ones after that stay for reuse.
            var mapped: usize = 0;
            for (self.chunks.items) |c| mapped += c.len;
            const want = @max(min_chunk, n + alignment.toByteUnits(), mapped / 2);
            const size = std.mem.alignForward(usize, want, std.heap.page_size_min);
            const p = std.heap.page_allocator.rawAlloc(size, chunk_align, ra) orelse return null;
            const at = if (self.chunks.items.len == 0) 0 else self.cur + 1;
            self.chunks.insert(std.heap.page_allocator, at, p[0..size]) catch {
                std.heap.page_allocator.rawFree(p[0..size], chunk_align, ra);
                return null;
            };
            self.cur = at;
            self.used = 0;
        }
    }

    /// Whether `memory` ends where the current chunk's used part does.
    fn isLatest(self: *const Scratch, memory: []u8) bool {
        if (self.cur >= self.chunks.items.len) return false;
        const c = self.chunks.items[self.cur];
        return memory.ptr + memory.len == c.ptr + self.used;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        _ = alignment;
        _ = ra;
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (!self.isLatest(memory)) return new_len <= memory.len;
        const c = self.chunks.items[self.cur];
        const start = self.used - memory.len;
        if (start + new_len > c.len) return false;
        self.used = start + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        _ = alignment;
        _ = ra;
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (self.isLatest(memory)) self.used -= memory.len;
    }
};

test "allocations bump through chunks, and a reset keeps the first chunks warm" {
    var s: Scratch = .{};
    defer s.deinit();
    const a = s.allocator();
    var total: usize = 0;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const m = try a.alloc(u64, 100 + i % 50);
        @memset(m, i);
        total += m.len * 8;
    }
    try std.testing.expect(s.chunks.items.len > 1);
    try std.testing.expect(s.inUse() >= total);
    const first = s.chunks.items[0];
    s.reset(Scratch.min_chunk);
    try std.testing.expectEqual(@as(usize, 1), s.chunks.items.len);
    try std.testing.expectEqual(first.ptr, s.chunks.items[0].ptr);
    try std.testing.expectEqual(@as(usize, 0), s.inUse());
    try std.testing.expect(s.high >= total);
    // The kept chunk serves the next allocation.
    const m = try a.alloc(u8, 16);
    try std.testing.expect(@intFromPtr(m.ptr) >= @intFromPtr(first.ptr) and @intFromPtr(m.ptr) < @intFromPtr(first.ptr) + first.len);
}

test "the latest allocation grows, shrinks and frees in place" {
    var s: Scratch = .{};
    defer s.deinit();
    const a = s.allocator();
    var list: std.ArrayList(u32) = .empty;
    var i: u32 = 0;
    while (i < 100_000) : (i += 1) try list.append(a, i);
    for (list.items, 0..) |v, j| try std.testing.expectEqual(@as(u32, @intCast(j)), v);
    const before = s.inUse();
    const x = try a.alloc(u8, 64);
    try std.testing.expect(a.resize(x, 128));
    const grown: []u8 = x.ptr[0..128];
    a.free(grown);
    try std.testing.expectEqual(before, s.inUse());
}

test "an allocation larger than any chunk gets one of its own, aligned" {
    var s: Scratch = .{};
    defer s.deinit();
    const a = s.allocator();
    _ = try a.alloc(u8, 10);
    const big = try a.alignedAlloc(u8, .@"64", 3 * Scratch.min_chunk);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(big.ptr), 64));
    @memset(big, 1);
    const small = try a.alloc(u8, 10);
    @memset(small, 2);
    try std.testing.expectEqual(@as(u8, 1), big[big.len - 1]);
}
