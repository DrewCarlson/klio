//! Unit tests for the collection intrinsics.

const std = @import("std");
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const Value = runtime.Value;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;
const testing = std.testing;

const array_mod = @import("array.zig");
const EvalResult = runtime.EvalResult;
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
    try testing.expectEqual(@as(usize, 2), r.ok.Set.len());
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

fn thrownText(r: EvalResult) ![2][]const u8 {
    try testing.expect(r == .err and r.err == .Thrown and r.err.Thrown == .Exception);
    const e = r.err.Thrown.Exception;
    const msg = e.message.get() orelse return error.TestUnexpectedResult;
    return .{ e.fqn.asPtrConst().bytes, msg.asPtrConst().bytes };
}

test "copyInto out of range throws as System.arraycopy does, naming the array's type" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const objs = try makeArray(a, &.{ Value.newInt(1), Value.newInt(2), Value.newInt(3) }, null);
    const packed_ints = try runtime.ArrayData.initPacked(a, .Int, &.{ Value.newInt(1), Value.newInt(2) });
    const cases = [_]struct { args: []const Value, want: []const u8 }{
        .{ .args = &.{ objs, objs, Value.newInt(2), Value.newInt(0), Value.newInt(2) }, .want = "arraycopy: last destination index 4 out of bounds for object array[3]" },
        .{ .args = &.{ objs, objs, Value.newInt(0), Value.newInt(2), Value.newInt(1) }, .want = "arraycopy: length -1 is negative" },
        .{ .args = &.{ packed_ints, packed_ints, Value.newInt(0), Value.newInt(-1), Value.newInt(1) }, .want = "arraycopy: source index -1 out of bounds for int[2]" },
        .{ .args = &.{ packed_ints, packed_ints, Value.newInt(0), Value.newInt(0), Value.newInt(3) }, .want = "arraycopy: last source index 3 out of bounds for int[2]" },
    };
    for (cases) |cs| {
        var c = h.ctx(cs.args);
        const got = try thrownText(try array_mod.array_copy_into(&c));
        try testing.expectEqualStrings("klio.ArrayIndexOutOfBoundsException", got[0]);
        try testing.expectEqualStrings(cs.want, got[1]);
    }
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

fn intsOf(arr: Value) ![6]i32 {
    var out: [6]i32 = undefined;
    for (&out, 0..) |*o, i| o.* = arr.Array.get(i).Int;
    return out;
}

test "a host sort of a range answers true for the natural order or its reverse over one kind of value, false otherwise" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const xs = [_]Value{ Value.newInt(9), Value.newInt(3), Value.newInt(1), Value.newInt(2), Value.newInt(8), Value.newInt(0) };
    const arr = try makeArray(a, &xs, null);
    var c = h.ctx(&.{ arr, Value.newInt(1), Value.newInt(5), .Null });
    const r = try array_mod.array_sort_natively(&c);
    try testing.expect(r == .ok and r.ok.Bool);
    try testing.expectEqual([6]i32{ 9, 1, 2, 3, 8, 0 }, try intsOf(arr));
    // A comparator the host does not know, and elements of two kinds, are the Kotlin sort's.
    var other = h.ctx(&.{ arr, Value.newInt(0), Value.newInt(6), Value.newInt(1) });
    const r2 = try array_mod.array_sort_natively(&other);
    try testing.expect(r2 == .ok and !r2.ok.Bool);
    const mixed = try makeArray(a, &.{ Value.newInt(2), .{ .Long = 1 }, Value.newInt(0), Value.newInt(5), Value.newInt(4), Value.newInt(3) }, null);
    var m = h.ctx(&.{ mixed, Value.newInt(0), Value.newInt(6), .Null });
    const r3 = try array_mod.array_sort_natively(&m);
    try testing.expect(r3 == .ok and !r3.ok.Bool);
    try testing.expectEqual(@as(i64, 1), mixed.Array.get(1).Long);
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

/// A host whose `equals` and `hashCode` calls are counted and answer nothing, and which
/// says every instance hashes by identity when `identity` is set.
const CountingHost = struct {
    identity: bool,
    calls: u32 = 0,

    fn vtInvoke(ctx: *anyopaque, callable: *const Value, args: []const Value, out: runtime.Output) std.mem.Allocator.Error!runtime.EvalResult {
        _ = .{ ctx, callable, args, out };
        return .{ .err = .{ .Unimplemented = "CountingHost::invoke_callable" } };
    }
    fn vtInvokeThis(ctx: *anyopaque, callable: *const Value, args: []const Value, this_value: *const Value, out: runtime.Output) std.mem.Allocator.Error!runtime.EvalResult {
        _ = .{ ctx, callable, args, this_value, out };
        return .{ .err = .{ .Unimplemented = "CountingHost::invoke_callable_with_this" } };
    }
    fn vtCallWellKnown(ctx: *anyopaque, receiver: *const Value, member: runtime.WellKnown, args: []const Value, out: runtime.Output) std.mem.Allocator.Error!?runtime.EvalResult {
        _ = .{ receiver, member, args, out };
        const self: *CountingHost = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return null;
    }
    fn vtIdentityKey(ctx: *anyopaque, key: *const Value) ?u32 {
        const self: *CountingHost = @ptrCast(@alignCast(ctx));
        if (!self.identity or key.* != .Instance) return null;
        return @truncate(key.Instance.asPtrConst().identityOf());
    }
    const vtable: runtime.IntrinsicHost.VTable = .{
        .invoke_callable = vtInvoke,
        .invoke_callable_with_this = vtInvokeThis,
        .call_well_known = vtCallWellKnown,
        .identity_key = vtIdentityKey,
    };
    fn host(self: *CountingHost) runtime.IntrinsicHost {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// An instance of a class with no members and identity `id`.
fn bareInstance(a: std.mem.Allocator, class: runtime.ObjRef(runtime.ClassDef), id: u64) !Value {
    return .{ .Instance = try runtime.InstanceData.new(a, class.clone(), &.{}, id) };
}

fn bareClass(a: std.mem.Allocator) !runtime.ObjRef(runtime.ClassDef) {
    const env = try runtime.ObjRef(runtime.Env).init(a, runtime.Env.init(a));
    return runtime.ObjRef(runtime.ClassDef).init(a, .{
        .name = "K",
        .fqn = "K",
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = false,
        .is_sealed = false,
        .supertype_names = &.{},
        .parent = null,
        .interfaces = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = false,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try runtime.ObjRef(?runtime.ObjRef(runtime.InstanceData)).init(a, null),
        .enclosing_class = try runtime.ObjRef(?runtime.ObjRef(runtime.ClassDef)).init(a, null),
        .nested_classes = &.{},
        .captured_env = env,
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try runtime.ObjRef(?runtime.ObjRef(runtime.InstanceData)).init(a, null),
    });
}

test "a map over instance keys that hash by identity puts, finds and removes them with no call into the VM" {
    for ([_]bool{ true, false }) |identity| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var sink = runtime.CaptureOutput.init(std.heap.page_allocator);
        defer sink.deinit();
        var counting: CountingHost = .{ .identity = identity };
        const class = try bareClass(a);
        var keys: [40]Value = undefined;
        for (&keys, 0..) |*k, i| k.* = try bareInstance(a, class, 1000 + i);
        const map = try common_mod.makeMapH(counting.host(), sink.output(), a, &.{}, true);
        // A map past the index's size hashes its keys, one below it scans them.
        for (&keys, 0..) |k, i| {
            const args = [_]Value{ map, k, Value.newInt(@intCast(i)) };
            var c: CallCtx = .{ .args = &args, .out = sink.output(), .host = counting.host(), .allocator = a };
            const r = try map_mod.coll_mut_map_put(&c);
            try testing.expect(r == .ok);
        }
        for (&keys, 0..) |k, i| {
            const args = [_]Value{ map, k };
            var c: CallCtx = .{ .args = &args, .out = sink.output(), .host = counting.host(), .allocator = a };
            const r = try coll_map_get(&c);
            try testing.expect(r == .ok and r.ok == .Int and r.ok.Int == i);
        }
        const other = try bareInstance(a, class, 5000);
        const args = [_]Value{ map, other };
        var c: CallCtx = .{ .args = &args, .out = sink.output(), .host = counting.host(), .allocator = a };
        const miss = try coll_map_get(&c);
        try testing.expect(miss == .ok and miss.ok == .Null);
        for (keys[0..10], 0..) |k, i| {
            const rargs = [_]Value{ map, k };
            var rc: CallCtx = .{ .args = &rargs, .out = sink.output(), .host = counting.host(), .allocator = a };
            const r = try map_mod.coll_mut_map_remove(&rc);
            try testing.expect(r == .ok and r.ok == .Int and r.ok.Int == i);
        }
        try testing.expectEqual(@as(usize, 30), mapLen(map.Map.entries));
        if (identity) try testing.expectEqual(@as(u32, 0), counting.calls) else try testing.expect(counting.calls > 0);
    }
}

const set_mod = @import("set.zig");

fn setOfInts(h: *TestHarness, n: usize) !Value {
    const a = h.arena.allocator();
    const args = try a.alloc(Value, n);
    for (args, 0..) |*v, i| v.* = Value.newInt(@intCast(i * 3));
    var c = h.ctx(args);
    const r = try builders_mod.coll_mutable_set_of(&c);
    try testing.expect(r == .ok and r.ok == .Set);
    return r.ok;
}

fn setCall(h: *TestHarness, f: anytype, set: Value, arg: Value) !Value {
    var c = h.ctx(&.{ set, arg });
    const r = try f(&c);
    try testing.expect(r == .ok);
    return r.ok;
}

fn indexLen(set: Value) ?usize {
    const ix = set.Set.index orelse return null;
    const seq = set.Set.elems.cell.lock.seq.load(.monotonic);
    if (ix.cell.data.seq != seq) return null;
    return ix.cell.data.len();
}

test "a set past a few elements keeps a hash index, which add, contains and remove keep in step" {
    var h = TestHarness.init();
    defer h.deinit();
    const small = try setOfInts(&h, 4);
    try testing.expect(small.Set.index == null);
    const s = try setOfInts(&h, 100);
    try testing.expectEqual(@as(?usize, 100), indexLen(s));
    try testing.expect((try setCall(&h, set_mod.coll_set_contains, s, Value.newInt(297))).Bool);
    try testing.expect(!(try setCall(&h, set_mod.coll_set_contains, s, Value.newInt(298))).Bool);
    try testing.expect((try setCall(&h, set_mod.coll_mut_set_add, s, Value.newInt(298))).Bool);
    try testing.expect(!(try setCall(&h, set_mod.coll_mut_set_add, s, Value.newInt(3))).Bool);
    try testing.expectEqual(@as(?usize, 101), indexLen(s));
    try testing.expect((try setCall(&h, set_mod.coll_mut_set_remove, s, Value.newInt(0))).Bool);
    try testing.expect(!(try setCall(&h, set_mod.coll_mut_set_remove, s, Value.newInt(0))).Bool);
    // The first element out leaves a hole at its position.
    try testing.expectEqual(@as(?usize, 101), indexLen(s));
    try testing.expectEqual(@as(u32, 1), s.Set.holes);
    try testing.expectEqual(@as(usize, 100), s.Set.len());
    // Every element is still found where it now stands.
    for (1..100) |i| try testing.expect((try setCall(&h, set_mod.coll_set_contains, s, Value.newInt(@intCast(i * 3)))).Bool);
    try testing.expect((try setCall(&h, set_mod.coll_set_contains, s, Value.newInt(298))).Bool);
}

fn setInts(h: *TestHarness, set: Value) ![]i32 {
    var c = h.ctx(&.{set});
    const r = try set_mod.coll_set_to_list(&c);
    try testing.expect(r == .ok and r.ok == .List);
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    const out = try h.arena.allocator().alloc(i32, g.get().items.len);
    for (g.get().items, out) |v, *o| o.* = if (v == .Int) v.Int else -1;
    return out;
}

test "a set's removal leaves a hole that lookups, its size and its elements in order pass over" {
    var h = TestHarness.init();
    defer h.deinit();
    const s = try setOfInts(&h, 20);
    try testing.expect((try setCall(&h, set_mod.coll_mut_set_remove, s, Value.newInt(3))).Bool);
    try testing.expect((try setCall(&h, set_mod.coll_mut_set_remove, s, Value.newInt(6))).Bool);
    try testing.expectEqual(@as(u32, 2), s.Set.holes);
    try testing.expectEqual(@as(usize, 18), s.Set.len());
    try testing.expect(!(try setCall(&h, set_mod.coll_set_contains, s, Value.newInt(3))).Bool);
    try testing.expect((try setCall(&h, set_mod.coll_set_contains, s, Value.newInt(9))).Bool);
    // `Unit`, which a hole holds, is no element until it is added, and then the one added.
    try testing.expect(!(try setCall(&h, set_mod.coll_set_contains, s, .Unit)).Bool);
    try testing.expect((try setCall(&h, set_mod.coll_mut_set_add, s, .Unit)).Bool);
    try testing.expect((try setCall(&h, set_mod.coll_set_contains, s, .Unit)).Bool);
    try testing.expectEqual(@as(usize, 19), s.Set.len());
    // The last element out takes no hole.
    try testing.expect((try setCall(&h, set_mod.coll_mut_set_remove, s, .Unit)).Bool);
    try testing.expectEqual(@as(u32, 2), s.Set.holes);
    // A removed element added again goes last, as in a `LinkedHashSet`.
    try testing.expect((try setCall(&h, set_mod.coll_mut_set_add, s, Value.newInt(3))).Bool);
    const xs = try setInts(&h, s);
    try testing.expectEqual(@as(u32, 0), s.Set.holes);
    try testing.expectEqualSlices(i32, &.{ 0, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48, 51, 54, 57, 3 }, xs);
    for (0..19) |i| try testing.expect((try setCall(&h, set_mod.coll_set_contains, s, Value.newInt(xs[i]))).Bool);
}

test "a set's last element out takes the holes before it, and holes as many as the elements close up" {
    var h = TestHarness.init();
    defer h.deinit();
    const s = try setOfInts(&h, 20);
    _ = try setCall(&h, set_mod.coll_mut_set_remove, s, Value.newInt(51));
    _ = try setCall(&h, set_mod.coll_mut_set_remove, s, Value.newInt(54));
    try testing.expectEqual(@as(u32, 2), s.Set.holes);
    _ = try setCall(&h, set_mod.coll_mut_set_remove, s, Value.newInt(57));
    try testing.expectEqual(@as(u32, 0), s.Set.holes);
    try testing.expectEqual(@as(?usize, 17), indexLen(s));
    // Seventeen elements: the ninth hole is as many as the eight left.
    for (0..8) |i| _ = try setCall(&h, set_mod.coll_mut_set_remove, s, Value.newInt(@intCast(i * 3)));
    try testing.expectEqual(@as(u32, 8), s.Set.holes);
    _ = try setCall(&h, set_mod.coll_mut_set_remove, s, Value.newInt(24));
    try testing.expectEqual(@as(u32, 0), s.Set.holes);
    try testing.expectEqual(@as(?usize, 8), indexLen(s));
    try testing.expectEqualSlices(i32, &.{ 27, 30, 33, 36, 39, 42, 45, 48 }, try setInts(&h, s));
    for ([_]i32{ 27, 48 }) |x| try testing.expect((try setCall(&h, set_mod.coll_set_contains, s, Value.newInt(x))).Bool);
    try testing.expect(!(try setCall(&h, set_mod.coll_set_contains, s, Value.newInt(24))).Bool);
}

test "a set whose list changed another way builds its index again before a lookup" {
    var h = TestHarness.init();
    defer h.deinit();
    const s = try setOfInts(&h, 20);
    {
        const g = s.Set.dense().borrowMut();
        defer g.deinit();
        g.get().items[5] = Value.newInt(1000);
    }
    try testing.expectEqual(@as(?usize, null), indexLen(s));
    try testing.expect((try setCall(&h, set_mod.coll_set_contains, s, Value.newInt(1000))).Bool);
    try testing.expect(!(try setCall(&h, set_mod.coll_set_contains, s, Value.newInt(15))).Bool);
    try testing.expectEqual(@as(?usize, 20), indexLen(s));
}

test "a set finds pairs by value, and the builders keep the first of equal elements and the last value of equal keys" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    var elems: [40]Value = undefined;
    for (&elems, 0..) |*v, i| v.* = try makePair(a, Value.newInt(@intCast(i % 20)), Value.newInt(7));
    var c = h.ctx(&elems);
    const r = try coll_set_of(&c);
    try testing.expect(r == .ok and r.ok == .Set);
    try testing.expectEqual(@as(usize, 20), r.ok.Set.len());
    const probe = try makePair(a, Value.newInt(13), Value.newInt(7));
    try testing.expect((try setCall(&h, set_mod.coll_set_contains, r.ok, probe)).Bool);
    var pairs: [30]Value = undefined;
    for (&pairs, 0..) |*v, i| v.* = try makePair(a, Value.newInt(@intCast(i % 10)), Value.newInt(@intCast(i)));
    var mc = h.ctx(&pairs);
    const m = try coll_map_of(&mc);
    try testing.expect(m == .ok and m.ok == .Map);
    try testing.expectEqual(@as(usize, 10), mapLen(m.ok.Map.entries));
    var gc = h.ctx(&.{ m.ok, Value.newInt(4) });
    const got = try coll_map_get(&gc);
    try testing.expectEqual(@as(i32, 24), got.ok.Int);
}

fn mapOfInts(h: *TestHarness, n: usize) !Value {
    const map = try common_mod.makeMapH(h.noop.host(), h.sink.output(), h.arena.allocator(), &.{}, true);
    for (0..n) |i| _ = try setCall2(h, map_mod.coll_mut_map_put, map, Value.newInt(@intCast(i)), Value.newInt(@intCast(i * 10)));
    return map;
}

fn setCall2(h: *TestHarness, f: anytype, recv: Value, x: Value, y: Value) !Value {
    var c = h.ctx(&.{ recv, x, y });
    const r = try f(&c);
    try testing.expect(r == .ok);
    return r.ok;
}

fn viewOf(h: *TestHarness, f: anytype, map: Value) !Value {
    var c = h.ctx(&.{map});
    const r = try f(&c);
    try testing.expect(r == .ok);
    return r.ok;
}

fn ints(h: *TestHarness, v: Value) ![]i32 {
    var c = h.ctx(&.{v});
    const items = switch (try common_mod.iterableItemsCtx(&c, v, "test")) {
        .items => |xs| xs,
        .err => return error.TestUnexpectedResult,
    };
    const out = try h.arena.allocator().alloc(i32, items.len);
    for (items, out) |x, *o| o.* = x.Int;
    return out;
}

fn mapKeys(h: *TestHarness, map: Value) ![]i32 {
    const g = map.Map.entries.borrow();
    defer g.deinit();
    var out: std.ArrayList(i32) = .empty;
    var it = g.get().live();
    while (it.next()) |kv| try out.append(h.arena.allocator(), kv.key.Int);
    return out.items;
}

test "pairs and maps put into a map go through its lookup, and a new map from one is one copy of it" {
    var h = TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const dest = try mapOfInts(&h, 20);
    const before = dest.Map.entries.cell.data.mod_count.get().?.cell.data.load();
    // `toMap(destination)` over pairs: a key the map holds keeps its place, a new one goes last.
    const pairs = [_]Value{ try makePair(a, Value.newInt(3), Value.newInt(-3)), try makePair(a, Value.newInt(40), Value.newInt(400)), try makePair(a, Value.newInt(3), Value.newInt(-4)) };
    const list = try common_mod.makeList(a, &pairs, false);
    var c = h.ctx(&.{ list, dest });
    try testing.expect((try list_transforms_mod.coll_list_to_map(&c)) == .ok);
    try testing.expectEqual(@as(usize, 21), mapLen(dest.Map.entries));
    try testing.expectEqual(@as(i32, 40), (try mapKeys(&h, dest))[20]);
    try testing.expectEqual(@as(i32, -4), (try setCall(&h, map_mod.coll_map_get, dest, Value.newInt(3))).Int);
    try testing.expect(dest.Map.entries.cell.data.mod_count.get().?.cell.data.load() != before);
    // `plus` and `minus` leave the map as it was and answer a map of their own.
    const plus = try setCall(&h, map_mod.coll_map_plus, dest, try makePair(a, Value.newInt(0), Value.newInt(99)));
    try testing.expect(plus.Map.entries.cell != dest.Map.entries.cell);
    try testing.expectEqual(@as(i32, 99), (try setCall(&h, map_mod.coll_map_get, plus, Value.newInt(0))).Int);
    try testing.expectEqual(@as(i32, 0), (try setCall(&h, map_mod.coll_map_get, dest, Value.newInt(0))).Int);
    const minus = try setCall(&h, map_mod.coll_map_minus, dest, Value.newInt(3));
    try testing.expectEqual(@as(usize, 20), mapLen(minus.Map.entries));
    try testing.expectEqual(@as(usize, 21), mapLen(dest.Map.entries));
    // `putAll` of a map into itself changes nothing.
    _ = try setCall(&h, map_mod.coll_mut_map_put_all, dest, dest);
    try testing.expectEqual(@as(usize, 21), mapLen(dest.Map.entries));
    try testing.expectEqualSlices(i32, try mapKeys(&h, dest), try mapKeys(&h, try setCall(&h, map_mod.coll_map_to_mutable_map, dest, .Null)));
}

test "a map's keys remove a key whatever its value, answering whether the map held it" {
    var h = TestHarness.init();
    defer h.deinit();
    const map = try mapOfInts(&h, 3);
    _ = try setCall2(&h, map_mod.coll_mut_map_put, map, Value.newInt(7), .Null);
    try testing.expect((try setCall(&h, map_mod.map_remove_key, map, Value.newInt(7))).Bool);
    try testing.expect(!(try setCall(&h, map_mod.map_remove_key, map, Value.newInt(7))).Bool);
    try testing.expect((try setCall(&h, map_mod.map_remove_key, map, Value.newInt(1))).Bool);
    {
        const g = map.Map.entries.borrow();
        defer g.deinit();
        var it = g.get().live();
        try testing.expectEqual(@as(i32, 0), it.next().?.key.Int);
        try testing.expectEqual(@as(i32, 2), it.next().?.key.Int);
        try testing.expect(it.next() == null);
    }
    try testing.expect((try setCall(&h, map_mod.map_view_iterator, map, Value.newInt(1))) == .Iterator);
    // A read-only map refuses, and the iterator takes only the three kinds.
    map.Map.mutable = false;
    var c = h.ctx(&.{ map, Value.newInt(0) });
    try testing.expect((try map_mod.map_remove_key(&c)) == .err);
    c = h.ctx(&.{ map, Value.newInt(3) });
    try testing.expect((try map_mod.map_view_iterator(&c)) == .err);
}
