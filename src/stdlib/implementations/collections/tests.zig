//! Unit tests for the collection intrinsics.

const std = @import("std");
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const Value = runtime.Value;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;
const testing = std.testing;

const array_mod = @import("array.zig");
const array_content_equals = array_mod.array_content_equals;

const builders_mod = @import("builders.zig");
const coll_int_array_of = builders_mod.coll_int_array_of;
const coll_list_of = builders_mod.coll_list_of;
const coll_map_of = builders_mod.coll_map_of;
const coll_pair_ctor = builders_mod.coll_pair_ctor;
const coll_set_of = builders_mod.coll_set_of;

const common_mod = @import("common.zig");
const listLen = common_mod.listLen;
const makeArray = common_mod.makeArray;
const makeList = common_mod.makeList;
const makePair = common_mod.makePair;
const makeStringOwned = common_mod.makeStringOwned;
const mapLen = common_mod.mapLen;
const primitive_companion_const = common_mod.primitive_companion_const;

const list_mod = @import("list.zig");
const coll_list_get = list_mod.coll_list_get;
const coll_mut_list_add = list_mod.coll_mut_list_add;

const list_transforms_mod = @import("list_transforms.zig");
const coll_list_reversed = list_transforms_mod.coll_list_reversed;
const coll_list_sorted = list_transforms_mod.coll_list_sorted;
const coll_list_sum = list_transforms_mod.coll_list_sum;

const map_mod = @import("map.zig");
const coll_map_get = map_mod.coll_map_get;

const sequence_mod = @import("sequence.zig");
const compare_values = sequence_mod.compare_values;

const tuple_mod = @import("tuple.zig");
const coll_triple_ctor = tuple_mod.coll_triple_ctor;
const pair_first = tuple_mod.pair_first;
const pair_second = tuple_mod.pair_second;

/// Minimal host reporting Unimplemented for callable invocations, which the
/// non-higher-order intrinsics under test never reach.
const TestHarness = struct {
    arena: std.heap.ArenaAllocator,
    noop: runtime.NoopHost,
    sink: runtime.CaptureOutput,

    fn init() TestHarness {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .noop = runtime.NoopHost.init(std.heap.page_allocator),
            .sink = runtime.CaptureOutput.init(std.heap.page_allocator),
        };
    }
    fn deinit(self: *TestHarness) void {
        self.arena.deinit();
        self.noop.deinit();
        self.sink.deinit();
    }
    fn ctx(self: *TestHarness, args: []const Value) CallCtx {
        return .{
            .args = args,
            .out = self.sink.output(),
            .host = self.noop.host(),
            .allocator = self.arena.allocator(),
        };
    }
};

test "listOf builds a read-only list" {
    var h = TestHarness.init();
    defer h.deinit();
    const args = [_]Value{ Value.newInt(1), Value.newInt(2), Value.newInt(3) };
    var c = h.ctx(&args);
    const r = try coll_list_of(&c);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .List);
    try testing.expect(!r.ok.List.mutable);
    try testing.expectEqual(@as(usize, 3), listLen(r.ok.List.items));
}

test "setOf dedupes structurally" {
    var h = TestHarness.init();
    defer h.deinit();
    const args = [_]Value{ Value.newInt(1), Value.newInt(1), Value.newInt(2) };
    var c = h.ctx(&args);
    const r = try coll_set_of(&c);
    try testing.expect(r == .ok and r.ok == .Set);
    try testing.expectEqual(@as(usize, 2), listLen(r.ok.Set.items));
}

test "list get out of bounds throws IndexOutOfBoundsException" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const list = try makeList(a, &.{ Value.newInt(10), Value.newInt(20) }, false);
    const args = [_]Value{ list, Value.newInt(5) };
    var c = h.ctx(&args);
    const r = try coll_list_get(&c);
    try testing.expect(r == .err and r.err == .Thrown);
    try testing.expect(r.err.Thrown == .Exception);
}

test "list get returns the element" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const list = try makeList(a, &.{ Value.newInt(10), Value.newInt(20) }, false);
    const args = [_]Value{ list, Value.newInt(1) };
    var c = h.ctx(&args);
    const r = try coll_list_get(&c);
    try testing.expect(r == .ok and r.ok == .Int and r.ok.Int == 20);
}

test "mapOf builds entries and get finds the value" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const p1 = try makePair(a, try makeStringOwned(a, "a"), Value.newInt(1));
    const p2 = try makePair(a, try makeStringOwned(a, "b"), Value.newInt(2));
    {
        const args = [_]Value{ p1, p2 };
        var c = h.ctx(&args);
        const m = try coll_map_of(&c);
        try testing.expect(m == .ok and m.ok == .Map);
        try testing.expectEqual(@as(usize, 2), mapLen(m.ok.Map.entries));
        const get_args = [_]Value{ m.ok, try makeStringOwned(a, "b") };
        var gc = h.ctx(&get_args);
        const gv = try coll_map_get(&gc);
        try testing.expect(gv == .ok and gv.ok == .Int and gv.ok.Int == 2);
    }
}

test "list sorted orders ascending" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const list = try makeList(a, &.{ Value.newInt(3), Value.newInt(1), Value.newInt(2) }, false);
    const args = [_]Value{list};
    var c = h.ctx(&args);
    const r = try coll_list_sorted(&c);
    try testing.expect(r == .ok and r.ok == .List);
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(i32, 1), g.get().items[0].Int);
    try testing.expectEqual(@as(i32, 2), g.get().items[1].Int);
    try testing.expectEqual(@as(i32, 3), g.get().items[2].Int);
}

test "list reversed reverses" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const list = try makeList(a, &.{ Value.newInt(1), Value.newInt(2), Value.newInt(3) }, false);
    const args = [_]Value{list};
    var c = h.ctx(&args);
    const r = try coll_list_reversed(&c);
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(i32, 3), g.get().items[0].Int);
    try testing.expectEqual(@as(i32, 1), g.get().items[2].Int);
}

test "mutable list add appends" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const list = try makeList(a, &.{Value.newInt(1)}, true);
    const args = [_]Value{ list, Value.newInt(2) };
    var c = h.ctx(&args);
    const r = try coll_mut_list_add(&c);
    try testing.expect(r == .ok and r.ok == .Bool and r.ok.Bool);
    try testing.expectEqual(@as(usize, 2), listLen(list.List.items));
}

test "pair ctor and accessors" {
    var h = TestHarness.init();
    defer h.deinit();
    const args = [_]Value{ Value.newInt(7), Value.newInt(8) };
    var c = h.ctx(&args);
    const p = try coll_pair_ctor(&c);
    try testing.expect(p == .ok and p.ok == .Pair);
    const fa = [_]Value{p.ok};
    var fc = h.ctx(&fa);
    const f = try pair_first(&fc);
    try testing.expect(f == .ok and f.ok.Int == 7);
    const s = try pair_second(&fc);
    try testing.expect(s == .ok and s.ok.Int == 8);
}

test "triple ctor requires three args" {
    var h = TestHarness.init();
    defer h.deinit();
    const args = [_]Value{ Value.newInt(1), Value.newInt(2) };
    var c = h.ctx(&args);
    const r = try coll_triple_ctor(&c);
    try testing.expect(r == .err and r.err == .Arity);
}

test "int array of tags primitive kind" {
    var h = TestHarness.init();
    defer h.deinit();
    const args = [_]Value{ Value.newInt(1), Value.newInt(2) };
    var c = h.ctx(&args);
    const r = try coll_int_array_of(&c);
    try testing.expect(r == .ok and r.ok == .Array);
    try testing.expectEqual(PrimitiveArrayKind.Int, r.ok.Array.primKind().?);
}

test "array content equals" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const x = try makeArray(a, &.{ Value.newInt(1), Value.newInt(2) }, .Int);
    const y = try makeArray(a, &.{ Value.newInt(1), Value.newInt(2) }, .Int);
    const args = [_]Value{ x, y };
    var c = h.ctx(&args);
    const r = try array_content_equals(&c);
    try testing.expect(r == .ok and r.ok == .Bool and r.ok.Bool);
}

test "list sum mixes int and double" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const list = try makeList(a, &.{ Value.newInt(1), .{ .Double = 2.5 } }, false);
    const args = [_]Value{list};
    var c = h.ctx(&args);
    const r = try coll_list_sum(&c);
    try testing.expect(r == .ok and r.ok == .Double);
    try testing.expectEqual(@as(f64, 3.5), r.ok.Double);
}

test "iterable sum accepts an array-backed iterable" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const array = try makeArray(a, &.{ .{ .UByte = 200 }, .{ .UByte = 200 } }, null);
    const args = [_]Value{array};
    var c = h.ctx(&args);
    const r = try coll_list_sum(&c);
    try testing.expect(r == .ok and r.ok == .UInt);
    try testing.expectEqual(@as(u32, 400), r.ok.UInt);
}

test "primitive companion const for Int" {
    const v = primitive_companion_const("Int", "MAX_VALUE").?;
    try testing.expect(v == .Int and v.Int == std.math.maxInt(i32));
    try testing.expect(primitive_companion_const("Int", "NOPE") == null);
}

test "compare values natural order" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try compare_values(a, Value.newInt(1), Value.newInt(2));
    try testing.expect(r == .order and r.order == .lt);
    const unsigned = try compare_values(
        a,
        .{ .ULong = std.math.maxInt(u64) },
        .{ .ULong = 0 },
    );
    try testing.expect(unsigned == .order and unsigned.order == .gt);
}
