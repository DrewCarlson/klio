//! A stable sort whose comparison may fail: what the stdlib's sorts run, as the JVM
//! runs `TimSort` for `sort`, `sorted` and the rest. Short runs are sorted by insertion
//! and then merged pairwise, so `n` elements take O(n log n) comparisons where an
//! insertion sort takes O(n²). A comparison is a user `compareTo` or `Comparator`, which
//! may run the collector or throw. The merges move positions, not elements, so `items`
//! holds every element during each comparison (a caller that roots `items` roots them
//! all), and a comparison that throws leaves `items` as it was.

const std = @import("std");

/// What a comparison answers: how its two elements order, or the error `E` it raised.
pub fn Order(comptime E: type) type {
    return union(enum) {
        order: std.math.Order,
        err: E,
    };
}

/// The span sorted by insertion before the merges.
const run = 16;

/// Sorts `items` stably by `cmp(ctx, x, y)`, how `x` orders against `y`; null when done,
/// else the error the comparison raised.
pub fn stableSort(
    comptime T: type,
    comptime E: type,
    a: std.mem.Allocator,
    items: []T,
    ctx: anytype,
    comptime cmp: fn (@TypeOf(ctx), *const T, *const T) std.mem.Allocator.Error!Order(E),
) std.mem.Allocator.Error!?E {
    const n = items.len;
    if (n < 2) return null;
    if (n <= run) {
        // Swaps keep every element in `items`; a throw leaves a permutation of them.
        var i: usize = 1;
        while (i < n) : (i += 1) {
            var j = i;
            while (j > 0) {
                switch (try cmp(ctx, &items[j - 1], &items[j])) {
                    .err => |e| return e,
                    .order => |o| if (o == .gt) {
                        std.mem.swap(T, &items[j - 1], &items[j]);
                        j -= 1;
                    } else break,
                }
            }
        }
        return null;
    }
    const perm = try a.alloc(u32, 2 * n);
    defer a.free(perm);
    var src = perm[0..n];
    var dst = perm[n..];
    for (src, 0..) |*p, i| p.* = @intCast(i);
    var lo: usize = 0;
    while (lo < n) : (lo += run) {
        const hi = @min(lo + run, n);
        var i = lo + 1;
        while (i < hi) : (i += 1) {
            var j = i;
            while (j > lo) {
                switch (try cmp(ctx, &items[src[j - 1]], &items[src[j]])) {
                    .err => |e| return e,
                    .order => |o| if (o == .gt) {
                        std.mem.swap(u32, &src[j - 1], &src[j]);
                        j -= 1;
                    } else break,
                }
            }
        }
    }
    var width: usize = run;
    while (width < n) : (width *= 2) {
        var start: usize = 0;
        while (start < n) : (start += 2 * width) {
            const mid = @min(start + width, n);
            const hi = @min(start + 2 * width, n);
            var i = start;
            var j = mid;
            var k = start;
            while (i < mid and j < hi) : (k += 1) {
                const o = switch (try cmp(ctx, &items[src[i]], &items[src[j]])) {
                    .order => |x| x,
                    .err => |e| return e,
                };
                // The left run first on a tie: the sort stays stable.
                if (o != .gt) {
                    dst[k] = src[i];
                    i += 1;
                } else {
                    dst[k] = src[j];
                    j += 1;
                }
            }
            @memcpy(dst[k..][0 .. mid - i], src[i..mid]);
            k += mid - i;
            @memcpy(dst[k..][0 .. hi - j], src[j..hi]);
        }
        const t = src;
        src = dst;
        dst = t;
    }
    const was = try a.dupe(T, items);
    defer a.free(was);
    for (items, src) |*x, p| x.* = was[p];
    return null;
}

test "the sort orders by the comparison, keeps equal elements in their order, and compares O(n log n) times" {
    const E = struct { at: usize };
    const Pair = struct { key: u32, seq: u32 };
    const Ctx = struct {
        calls: *usize,
        fn cmp(c: @This(), x: *const Pair, y: *const Pair) std.mem.Allocator.Error!Order(E) {
            c.calls.* += 1;
            return .{ .order = std.math.order(x.key, y.key) };
        }
    };
    var prng = std.Random.DefaultPrng.init(7);
    const n = 5000;
    var items: [n]Pair = undefined;
    for (&items, 0..) |*p, i| p.* = .{ .key = prng.random().uintLessThan(u32, 100), .seq = @intCast(i) };
    var calls: usize = 0;
    try std.testing.expectEqual(@as(?E, null), try stableSort(Pair, E, std.testing.allocator, &items, Ctx{ .calls = &calls }, Ctx.cmp));
    for (items[1..], items[0 .. n - 1]) |b, a| {
        try std.testing.expect(a.key < b.key or (a.key == b.key and a.seq < b.seq));
    }
    // 5,000 elements: an insertion sort compares about six million times.
    try std.testing.expect(calls < 80_000);
}

test "a comparison that fails stops the sort and leaves the slice as it was" {
    const E = struct { at: u32 };
    const Ctx = struct {
        calls: *usize,
        fn cmp(c: @This(), x: *const u32, y: *const u32) std.mem.Allocator.Error!Order(E) {
            c.calls.* += 1;
            if (c.calls.* == 300) return .{ .err = .{ .at = x.* } };
            return .{ .order = std.math.order(x.*, y.*) };
        }
    };
    var items: [200]u32 = undefined;
    for (&items, 0..) |*v, i| v.* = @intCast((i * 37) % 200);
    var calls: usize = 0;
    const r = try stableSort(u32, E, std.testing.allocator, &items, Ctx{ .calls = &calls }, Ctx.cmp);
    try std.testing.expect(r != null);
    for (items, 0..) |v, i| try std.testing.expectEqual(@as(u32, @intCast((i * 37) % 200)), v);
}
