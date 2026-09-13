//! Array constructors and the collection builder intrinsics.

const std = @import("std");
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const ValueList = runtime.ValueList;
const MapPair = runtime.MapPair;
const CollBackingRef = runtime.CollBackingRef;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;
const ObjRef = runtime.ObjRef;
const IntrinsicHost = runtime.IntrinsicHost;
const Output = runtime.Output;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const common_mod = @import("common.zig");
const ItemsOutcome = common_mod.ItemsOutcome;
const arityErr = common_mod.arityErr;
const compareValues = common_mod.compareValues;
const findKeyIndexBoxed = common_mod.findKeyIndexBoxed;
const findKeyIndexBoxedH = common_mod.findKeyIndexBoxedH;
const fmt = common_mod.fmt;
const invoke = common_mod.invoke;
const iterableItemsCtx = common_mod.iterableItemsCtx;
const listLen = common_mod.listLen;
const makeArray = common_mod.makeArray;
const makeArrayFromArrayList = common_mod.makeArrayFromArrayList;
const makeList = common_mod.makeList;
const makeListFromArrayList = common_mod.makeListFromArrayList;
const makeListVL = common_mod.makeListVL;
const makeMap = common_mod.makeMap;
const makeMapBorrowed = common_mod.makeMapBorrowed;
const makeMapH = common_mod.makeMapH;
const makePair = common_mod.makePair;
const makeSet = common_mod.makeSet;
const makeSetH = common_mod.makeSetH;
const makeSetVL = common_mod.makeSetVL;
const ok = common_mod.ok;
const reverseOrder = common_mod.reverseOrder;
const snapshotEntries = common_mod.snapshotEntries;
const snapshotItems = common_mod.snapshotItems;
const thrown = common_mod.thrown;
const typeErr = common_mod.typeErr;

const list_transforms_mod = @import("list_transforms.zig");
const sortListHostAware = list_transforms_mod.sortListHostAware;
const userMapPairs = list_transforms_mod.userMapPairs;

fn arrayLen(recv: Value) ?usize {
    return switch (recv) {
        .Array => |arr| arr.len(),
        .List => |l| listLen(l.items),
        else => null,
    };
}

pub fn array_is_empty(ctx: *CallCtx) Error!EvalResult {
    const r = if (ctx.args.len > 0) arrayLen(ctx.args[0]) else null;
    if (r) |n| return ok(.{ .Bool = n == 0 });
    return typeErr("isEmpty requires an array");
}

pub fn array_is_not_empty(ctx: *CallCtx) Error!EvalResult {
    const r = if (ctx.args.len > 0) arrayLen(ctx.args[0]) else null;
    if (r) |n| return ok(.{ .Bool = n != 0 });
    return typeErr("isNotEmpty requires an array");
}

const SizeOutcome = union(enum) { n: i64, err: EvalResult };

fn arraySizeArg(a: Allocator, v: Value, what: []const u8) Error!SizeOutcome {
    const n = v.asI64() orelse return .{ .err = typeErr(try fmt(a, "{s} expects an Int size", .{what})) };
    // A negative size is a catchable `NegativeArraySizeException`, not a `.Type`
    // error, which would unwind past `assertFailsWith`.
    if (n < 0) {
        const msg = try fmt(a, "{d}", .{n});
        const e = try thrown(a, "kotlin.NegativeArraySizeException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return .{ .err = e };
    }
    return .{ .n = n };
}

fn arrayCtorImpl(ctx: *CallCtx, name: []const u8, prim: ?PrimitiveArrayKind, default: Value) Error!EvalResult {
    const a = ctx.allocator;
    // A bare ctor call routes through the member walk, which prepends an implicit
    // receiver the constructor does not take; strip it when the remaining args
    // form a valid ctor shape.
    var call_args = ctx.args;
    if (call_args.len >= 2 and call_args[0] == .Array) {
        const rest = call_args[1..];
        const rest_valid = (rest.len == 1 and (rest[0] == .Array or rest[0].asI64() != null)) or
            (rest.len == 2 and rest[0].asI64() != null);
        if (rest_valid) call_args = rest;
    }
    if (call_args.len == 0 or call_args.len > 2) {
        return arityErr(try fmt(a, "{s} expects (size) or (size, init)", .{name}));
    }
    // `UIntArray(intArray)` shares the signed array's packed buffer as an
    // unsigned view, so mutations through either alias.
    if (call_args.len == 1 and prim != null and call_args[0] == .Array) {
        const arr = call_args[0].Array;
        if (arr.primKind()) |src| {
            const is_view = (prim.? == .UByte and src == .Byte) or
                (prim.? == .UShort and src == .Short) or
                (prim.? == .UInt and src == .Int) or
                (prim.? == .ULong and src == .Long) or
                prim.? == src;
            if (is_view) switch (arr.storage()) {
                .scalars => |pb| return ok(.{ .Array = runtime.ArrayData.scalars(pb.clone(), prim.?) }),
                .boxed => {
                    const buf = try arr.snapshot(a);
                    defer if (runtime.freeScratch()) a.free(buf);
                    const k = prim.?;
                    var pb = runtime.PrimBuf{ .kind = k };
                    errdefer pb.bytes.deinit(a);
                    try pb.bytes.appendNTimes(a, 0, buf.len * k.elemSize());
                    for (buf, 0..) |v, i| {
                        pb.setAs(i, v, src);
                    }
                    return ok(.{ .Array = runtime.ArrayData.scalars(try ObjRef(runtime.PrimBuf).initOwned(a, pb), k) });
                },
            };
        }
    }
    const n = switch (try arraySizeArg(a, call_args[0], name)) {
        .n => |v| v,
        .err => |e| return e,
    };

    // Primitive arrays store packed scalars, never boxed `Value`s, and a zeroed
    // buffer is already the Kotlin default for every primitive.
    if (prim) |k| {
        const un: usize = @intCast(n);
        var pb = runtime.PrimBuf{ .kind = k };
        errdefer pb.bytes.deinit(a);
        try pb.bytes.appendNTimes(a, 0, un * k.elemSize());
        if (call_args.len == 2) {
            const block = call_args[1];
            var i: usize = 0;
            while (i < un) : (i += 1) {
                const v = switch (try invoke(ctx, &block, &.{Value.newInt(@intCast(i))})) {
                    .value => |x| x,
                    .err => |e| return e,
                };
                pb.set(i, v);
            }
        }
        return ok(.{ .Array = runtime.ArrayData.scalars(try ObjRef(runtime.PrimBuf).initOwned(a, pb), k) });
    }

    if (call_args.len == 1) {
        var list: std.ArrayList(Value) = .empty;
        var i: i64 = 0;
        while (i < n) : (i += 1) try list.append(a, default);
        return ok(try makeArrayFromArrayList(a, list, null));
    }
    const block = call_args[1];
    var list: std.ArrayList(Value) = .empty;
    // Only `list` holds the results and `invoke` reaches a GC safe point, so pin
    // the accumulator across each call; an append may reallocate `list.items`.
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        runtime.keepaliveRestore(ka);
        runtime.keepalivePushSlice(list.items);
        const v = switch (try invoke(ctx, &block, &.{Value.newInt(i)})) {
            .value => |x| x,
            .err => |e| return e,
        };
        try list.append(a, v);
    }
    return ok(try makeArrayFromArrayList(a, list, null));
}

pub fn array_ctor_generic(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "Array", null, Value.Null);
}
pub fn array_ctor_int(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "IntArray", .Int, .{ .Int = 0 });
}
pub fn array_ctor_long(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "LongArray", .Long, .{ .Long = 0 });
}
pub fn array_ctor_double(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "DoubleArray", .Double, .{ .Double = 0.0 });
}
pub fn array_ctor_float(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "FloatArray", .Float, .{ .Float = 0.0 });
}
pub fn array_ctor_short(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "ShortArray", .Short, .{ .Short = 0 });
}
pub fn array_ctor_byte(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "ByteArray", .Byte, .{ .Byte = 0 });
}
pub fn array_ctor_boolean(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "BooleanArray", .Boolean, .{ .Bool = false });
}
pub fn array_ctor_char(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "CharArray", .Char, .{ .Char = 0 });
}
pub fn array_ctor_uint(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "UIntArray", .UInt, .{ .UInt = 0 });
}
pub fn array_ctor_ulong(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "ULongArray", .ULong, .{ .ULong = 0 });
}
pub fn array_ctor_ushort(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "UShortArray", .UShort, .{ .UShort = 0 });
}
pub fn array_ctor_ubyte(ctx: *CallCtx) Error!EvalResult {
    return arrayCtorImpl(ctx, "UByteArray", .UByte, .{ .UByte = 0 });
}

fn pairArgs(ctx: *CallCtx) union(enum) { pair: struct { a: Value, b: Value }, err: EvalResult } {
    if (ctx.args.len == 2) return .{ .pair = .{ .a = ctx.args[0], .b = ctx.args[1] } };
    return .{ .err = arityErr("Pair expects 2 arguments") };
}

pub fn coll_pair_ctor(ctx: *CallCtx) Error!EvalResult {
    const p = switch (pairArgs(ctx)) {
        .pair => |p| p,
        .err => |e| return e,
    };
    p.a.retain();
    p.b.retain();
    return ok(try makePair(ctx.allocator, p.a, p.b));
}

pub fn coll_to_infix(ctx: *CallCtx) Error!EvalResult {
    return coll_pair_ctor(ctx);
}

pub fn coll_list_of(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return ok(try sharedEmptyList(ctx.allocator));
    return ok(try makeList(ctx.allocator, ctx.args, false));
}

pub fn coll_list_of_not_null(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    for (ctx.args) |v| {
        if (v != .Null) {
            if (runtime.reclaimEnabled()) v.retain();
            try items.append(a, v);
        }
    }
    return ok(try makeListFromArrayList(a, items, false));
}

pub fn coll_array_of(ctx: *CallCtx) Error!EvalResult {
    return ok(try makeArray(ctx.allocator, ctx.args, null));
}

pub fn coll_array_of_nulls(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 2 and ctx.args[0] == .Array) {
        const n = switch (try arraySizeArg(a, ctx.args[1], "arrayOfNulls")) {
            .n => |v| v,
            .err => |e| return e,
        };
        var list: std.ArrayList(Value) = .empty;
        var i: i64 = 0;
        while (i < n) : (i += 1) try list.append(a, Value.Null);
        return ok(try makeArrayFromArrayList(a, list, null));
    }
    return arrayCtorImpl(ctx, "arrayOfNulls", null, Value.Null);
}

pub fn coll_empty_array(ctx: *CallCtx) Error!EvalResult {
    return ok(try makeArray(ctx.allocator, &.{}, null));
}

fn primArrayOf(ctx: *CallCtx, prim: PrimitiveArrayKind) Error!EvalResult {
    return ok(try makeArray(ctx.allocator, ctx.args, prim));
}
pub fn coll_int_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .Int);
}
pub fn coll_long_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .Long);
}
pub fn coll_short_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .Short);
}
pub fn coll_byte_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .Byte);
}
pub fn coll_double_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .Double);
}
pub fn coll_float_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .Float);
}
pub fn coll_bool_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .Boolean);
}
pub fn coll_char_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .Char);
}
pub fn coll_uint_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .UInt);
}
pub fn coll_ulong_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .ULong);
}
pub fn coll_ushort_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .UShort);
}
pub fn coll_ubyte_array_of(ctx: *CallCtx) Error!EvalResult {
    return primArrayOf(ctx, .UByte);
}

pub fn coll_mutable_list_of(ctx: *CallCtx) Error!EvalResult {
    return ok(try makeList(ctx.allocator, ctx.args, true));
}

fn arrayRecvItems(a: Allocator, ctx: *CallCtx, who: []const u8) Error!ItemsOutcome {
    if (ctx.args.len > 0) {
        switch (ctx.args[0]) {
            .Array => |arr| return .{ .items = try arr.snapshot(a) },
            .List => |l| return .{ .items = try snapshotItems(a, l.items) },
            .Set => |s| return .{ .items = try snapshotItems(a, s.items) },
            else => {},
        }
    }
    return .{ .err = typeErr(try fmt(a, "{s} requires an array receiver", .{who})) };
}

pub fn coll_array_as_array_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const items = switch (try arrayRecvItems(a, ctx, "asArrayList")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeList(a, items, true));
}

/// `asList()` is a read-only fixed-size view: later array writes show through.
pub fn arrayAsListView(a: Allocator, arr: runtime.ArrayData) Error!Value {
    switch (arr.storage()) {
        .boxed => |vl| return try Value.newList(a, .{
            .items = vl.clone(),
            .mutable = false,
            .enum_entries = false,
            .backing = null,
            .mod_count = .{},
        }),
        .scalars => |buf| {
            const view_kind = arr.primKind() orelse blk: {
                const g = buf.borrow();
                defer g.deinit();
                break :blk g.get().kind;
            };
            var snap: std.ArrayList(Value) = .empty;
            {
                const g = buf.borrow();
                defer g.deinit();
                const n = g.get().len();
                var i: usize = 0;
                while (i < n) : (i += 1) try snap.append(a, g.get().getAs(i, view_kind));
            }
            const backing = try CollBackingRef.init(a, .{ .array = .{ .buf = buf, .view_kind = view_kind } });
            return try Value.newList(a, .{
                .items = try ValueList.init(a, snap),
                .mutable = false,
                .enum_entries = false,
                .backing = backing.cell,
                .mod_count = .{},
            });
        },
    }
}

pub fn coll_array_as_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len > 0 and ctx.args[0] == .Array) {
        return ok(try arrayAsListView(a, ctx.args[0].Array));
    }
    const items = switch (try arrayRecvItems(a, ctx, "asList")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeList(a, items, false));
}

// Shared empty read-only singletons, so `===` holds across call sites as it does
// for Kotlin's EmptyList. Reset at run boundaries, since the cells belong to the
// finished run's allocator.
var empty_singleton_lock: runtime.SpinMutex = .{};
var empty_list_singleton: ?Value = null;
var empty_set_singleton: ?Value = null;
var empty_map_singleton: ?Value = null;
var empty_singleton_root_registered = std.atomic.Value(bool).init(false);

fn gcMarkEmptySingletons(m: *runtime.gc.Marker) void {
    // Mark through the Value: shading only the items leaves the box unmarked.
    if (empty_list_singleton) |v| v.gcMark(m);
    if (empty_set_singleton) |v| v.gcMark(m);
    if (empty_map_singleton) |v| v.gcMark(m);
}

fn registerEmptySingletonRoot() void {
    if (runtime.gc.gc_enabled and !empty_singleton_root_registered.swap(true, .monotonic))
        runtime.gc.registerRoot(gcMarkEmptySingletons);
}

pub fn sharedEmptyList(a: Allocator) Error!Value {
    // Under refcount reclaim the process cache reads as a leak, so only the arena
    // profile serves identity singletons.
    if (runtime.reclaimEnabled()) return makeList(a, &.{}, false);
    empty_singleton_lock.lock();
    defer empty_singleton_lock.unlock();
    if (empty_list_singleton == null) {
        empty_list_singleton = try makeList(a, &.{}, false);
        registerEmptySingletonRoot();
    }
    const v = empty_list_singleton.?;
    v.retain();
    return v;
}

pub fn sharedEmptySet(a: Allocator) Error!Value {
    if (runtime.reclaimEnabled()) return makeSet(a, &.{}, false);
    empty_singleton_lock.lock();
    defer empty_singleton_lock.unlock();
    if (empty_set_singleton == null) {
        empty_set_singleton = try makeSet(a, &.{}, false);
        registerEmptySingletonRoot();
    }
    const v = empty_set_singleton.?;
    v.retain();
    return v;
}

pub fn sharedEmptyMap(a: Allocator) Error!Value {
    if (runtime.reclaimEnabled()) return makeMap(a, &.{}, false);
    empty_singleton_lock.lock();
    defer empty_singleton_lock.unlock();
    if (empty_map_singleton == null) {
        empty_map_singleton = try makeMap(a, &.{}, false);
        registerEmptySingletonRoot();
    }
    const v = empty_map_singleton.?;
    v.retain();
    return v;
}

pub fn resetEmptyCollectionSingletons() void {
    empty_singleton_lock.lock();
    defer empty_singleton_lock.unlock();
    empty_list_singleton = null;
    empty_set_singleton = null;
    empty_map_singleton = null;
}

pub fn coll_empty_list(ctx: *CallCtx) Error!EvalResult {
    return ok(try sharedEmptyList(ctx.allocator));
}

pub fn coll_set_of(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return ok(try sharedEmptySet(ctx.allocator));
    return ok(try makeSetH(ctx.host, ctx.out, ctx.allocator, ctx.args, false));
}
pub fn coll_mutable_set_of(ctx: *CallCtx) Error!EvalResult {
    return ok(try makeSetH(ctx.host, ctx.out, ctx.allocator, ctx.args, true));
}
pub fn coll_empty_set(ctx: *CallCtx) Error!EvalResult {
    return ok(try sharedEmptySet(ctx.allocator));
}

fn mapOfImpl(ctx: *CallCtx, mutable: bool, who: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    var entries: std.ArrayList(MapPair) = .empty;
    for (ctx.args) |v| {
        if (v != .Pair) return typeErr(try fmt(a, "{s} expects Pair arguments (use `key to value` or `Pair(k, v)`)", .{who}));
        try entries.append(a, .{ .key = v.Pair.first.asPtr().*, .value = v.Pair.second.asPtr().* });
    }
    // Dedupe over the borrowed entries first; makeMapBorrowed then retains the
    // survivors.
    return ok(try makeMapBorrowed(a, try dedupeMapInPlaceH(ctx.host, ctx.out, a, entries), mutable));
}

fn dedupeMapInPlace(a: Allocator, entries: std.ArrayList(MapPair)) Error!std.ArrayList(MapPair) {
    var out: std.ArrayList(MapPair) = .empty;
    for (entries.items) |kv| {
        if (findKeyIndexBoxed(out.items, &kv.key)) |i| {
            out.items[i].value = kv.value;
        } else {
            try out.append(a, kv);
        }
    }
    return out;
}

fn dedupeMapInPlaceH(host: IntrinsicHost, out_w: Output, a: Allocator, entries: std.ArrayList(MapPair)) Error!std.ArrayList(MapPair) {
    var out: std.ArrayList(MapPair) = .empty;
    for (entries.items) |kv| {
        if (try findKeyIndexBoxedH(host, out_w, out.items, &kv.key)) |i| {
            out.items[i].value = kv.value;
        } else {
            try out.append(a, kv);
        }
    }
    return out;
}

pub fn coll_map_of(ctx: *CallCtx) Error!EvalResult {
    return mapOfImpl(ctx, false, "mapOf");
}
pub fn coll_mutable_map_of(ctx: *CallCtx) Error!EvalResult {
    return mapOfImpl(ctx, true, "mutableMapOf");
}
pub fn coll_empty_map(ctx: *CallCtx) Error!EvalResult {
    return ok(try sharedEmptyMap(ctx.allocator));
}

pub fn materialiseIterableInstance(ctx: *CallCtx, value: Value) Error!ItemsOutcome {
    const a = ctx.allocator;
    switch (value) {
        .List => |l| return .{ .items = try snapshotItems(a, l.items) },
        .Set => |s| return .{ .items = try snapshotItems(a, s.items) },
        else => {},
    }
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePush(value);
    const iter = (try ctx.host.invokeMethod(&value, "iterator", &.{}, ctx.out)) orelse
        return .{ .err = typeErr("value is not iterable") };
    const iter_v = switch (iter) {
        .ok => |v| v,
        .err => |e| return .{ .err = .{ .err = e } },
    };
    runtime.keepalivePush(iter_v);
    const loop_keepalive = runtime.keepaliveMark();
    var items: std.ArrayList(Value) = .empty;
    while (true) {
        runtime.keepaliveRestore(loop_keepalive);
        runtime.keepalivePushSlice(items.items);
        const has_r = (try ctx.host.invokeMethod(&iter_v, "hasNext", &.{}, ctx.out)) orelse
            return .{ .err = typeErr("iterator is missing hasNext()") };
        const has = switch (has_r) {
            .ok => |v| v,
            .err => |e| return .{ .err = .{ .err = e } },
        };
        if (!(has == .Bool and has.Bool)) break;
        const item_r = (try ctx.host.invokeMethod(&iter_v, "next", &.{}, ctx.out)) orelse
            return .{ .err = typeErr("iterator is missing next()") };
        const item = switch (item_r) {
            .ok => |v| v,
            .err => |e| return .{ .err = .{ .err = e } },
        };
        try items.append(a, item);
        if (items.items.len > 1_000_000) {
            return .{ .err = typeErr("iterator produced over 1,000,000 items") };
        }
    }
    return .{ .items = try items.toOwnedSlice(a) };
}

pub fn coll_to_typed_array(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("toTypedArray requires a receiver");
    const recv = ctx.args[0];
    if (recv == .Instance) {
        // Dispatch through the collection's `toArray()` override before falling
        // back to iteration, so a user override observes the call.
        if (try ctx.host.invokeMethod(&recv, "toArray", &.{}, ctx.out)) |r| switch (r) {
            .ok => |v| {
                if (v == .Array) return ok(v);
            },
            .err => |e| return .{ .err = e },
        };
    }
    const items = if (recv == .Instance)
        switch (try materialiseIterableInstance(ctx, recv)) {
            .items => |x| x,
            .err => |e| return e,
        }
    else switch (try iterableItemsCtx(ctx, recv, "toTypedArray")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeArray(a, items, null));
}

pub fn coll_set_of_not_null(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    for (ctx.args) |v| {
        if (v != .Null) try items.append(a, v);
    }
    return ok(try makeSet(a, items.items, false));
}

pub fn coll_sorted_set_of(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const items = try a.dupe(Value, ctx.args);
    if (try sortListHostAware(ctx, items)) |e| return e;
    return ok(try makeSet(a, items, true));
}

pub fn coll_sorted_map_of(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    var entries: std.ArrayList(MapPair) = .empty;
    for (ctx.args) |v| {
        if (v != .Pair) return typeErr("sortedMapOf expects Pair arguments");
        try entries.append(a, .{ .key = v.Pair.first.asPtr().*, .value = v.Pair.second.asPtr().* });
    }
    if (try sortMapByKey(a, entries.items, false)) |e| return e;
    return ok(try makeMapH(ctx.host, ctx.out, a, entries.items, true));
}

pub fn sortMapByKey(a: Allocator, entries: []MapPair, descending: bool) Error!?EvalResult {
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const o = switch (try compareValues(a, entries[j - 1].key, entries[j].key)) {
                .order => |o| o,
                .err => |e| return e,
            };
            const flipped = if (descending) reverseOrder(o) else o;
            if (flipped == .gt) {
                std.mem.swap(MapPair, &entries[j - 1], &entries[j]);
                j -= 1;
            } else break;
        }
    }
    return null;
}

pub fn coll_array_list_ctor(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    switch (ctx.args.len) {
        0 => return ok(try makeList(a, &.{}, true)),
        1 => {
            const arg = ctx.args[0];
            switch (arg) {
                .Int => {
                    if (arg.Int < 0) {
                        const msg = try fmt(a, "Illegal Capacity: {d}", .{arg.Int});
                        const r = try thrown(a, "kotlin.IllegalArgumentException", msg);
                        if (runtime.freeScratch()) a.free(msg);
                        return r;
                    }
                    var list: std.ArrayList(Value) = .empty;
                    if (arg.Int > 0) try list.ensureTotalCapacityPrecise(a, @intCast(arg.Int));
                    return ok(try makeListFromArrayList(a, list, true));
                },
                .List => |l| return ok(try makeListVL(a, l.items, true)),
                .Set => |s| return ok(try makeListVL(a, s.items, true)),
                .Array => |arr| {
                    var list: std.ArrayList(Value) = .empty;
                    const n = arr.len();
                    try list.ensureTotalCapacityPrecise(a, n);
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        const v = arr.get(i);
                        v.retain();
                        list.appendAssumeCapacity(v);
                    }
                    return ok(try makeListFromArrayList(a, list, true));
                },
                .Instance => {
                    const items = switch (try materialiseIterableInstance(ctx, arg)) {
                        .items => |x| x,
                        .err => |e| return e,
                    };
                    return ok(try makeList(a, items, true));
                },
                else => return typeErr("ArrayList expects no args, an Int capacity, or a Collection"),
            }
        },
        else => return arityErr("ArrayList expects 0 or 1 args"),
    }
}

pub fn coll_hash_map_ctor(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return ok(try makeMap(a, &.{}, true));
    if (ctx.args.len == 1 and ctx.args[0] == .Map) {
        return ok(try makeMap(a, try snapshotEntries(a, ctx.args[0].Map.entries), true));
    }
    // An interpreted Map implementation copies through its `entries` view.
    if (ctx.args.len == 1 and ctx.args[0] == .Instance) {
        switch (try userMapPairs(ctx, ctx.args[0], "HashMap")) {
            .entries => |pairs| return ok(try makeMap(a, pairs, true)),
            .err => |e| return e,
        }
    }
    if (ctx.args[0] == .Int) {
        // A negative capacity or a non-positive load factor is a catchable
        // IllegalArgumentException, as in java.util.HashMap.
        if (ctx.args[0].asI64()) |cap| {
            if (cap < 0) {
                const msg = try fmt(a, "Negative initial capacity: {d}", .{cap});
                const r = try thrown(a, "kotlin.IllegalArgumentException", msg);
                if (runtime.freeScratch()) a.free(msg);
                return r;
            }
        }
        if (ctx.args.len >= 2) {
            const lf: ?f64 = switch (ctx.args[1]) {
                .Float => |x| x,
                .Double => |x| x,
                else => null,
            };
            if (lf) |v| {
                if (!(v > 0)) {
                    const msg = try fmt(a, "Illegal load factor: {d}", .{v});
                    const r = try thrown(a, "kotlin.IllegalArgumentException", msg);
                    if (runtime.freeScratch()) a.free(msg);
                    return r;
                }
            }
        }
        return ok(try makeMap(a, &.{}, true));
    }
    return typeErr("HashMap expects no args, an Int capacity, or a Map");
}

pub fn coll_hash_set_ctor(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    switch (ctx.args.len) {
        0 => return ok(try makeSet(a, &.{}, true)),
        1 => {
            const arg = ctx.args[0];
            switch (arg) {
                .Int => {
                    if (arg.Int < 0) {
                        const msg = try fmt(a, "Illegal initial capacity: {d}", .{arg.Int});
                        const r = try thrown(a, "kotlin.IllegalArgumentException", msg);
                        if (runtime.freeScratch()) a.free(msg);
                        return r;
                    }
                    return ok(try makeSet(a, &.{}, true));
                },
                .List => |l| {
                    const items = try snapshotItems(a, l.items);
                    defer if (runtime.freeScratch()) a.free(items);
                    return ok(try makeSetH(ctx.host, ctx.out, a, items, true));
                },
                .Set => |s| return ok(try makeSetVL(a, s.items, true)),
                .Instance => {
                    const items = switch (try materialiseIterableInstance(ctx, arg)) {
                        .items => |x| x,
                        .err => |e| return e,
                    };
                    return ok(try makeSet(a, items, true));
                },
                else => return typeErr("HashSet expects no args, an Int capacity, or a Collection"),
            }
        },
        else => {
            // A negative capacity or a non-positive or NaN load factor is a
            // catchable IllegalArgumentException.
            if (ctx.args.len == 2 and ctx.args[0] == .Int) {
                if (ctx.args[0].Int < 0) {
                    const msg = try fmt(a, "Illegal initial capacity: {d}", .{ctx.args[0].Int});
                    const r = try thrown(a, "kotlin.IllegalArgumentException", msg);
                    if (runtime.freeScratch()) a.free(msg);
                    return r;
                }
                const lf: ?f64 = switch (ctx.args[1]) {
                    .Float => |x| x,
                    .Double => |x| x,
                    else => null,
                };
                if (lf) |v| {
                    if (!(v > 0)) {
                        const msg = try fmt(a, "Illegal load factor: {d}", .{v});
                        const r = try thrown(a, "kotlin.IllegalArgumentException", msg);
                        if (runtime.freeScratch()) a.free(msg);
                        return r;
                    }
                }
                return ok(try makeSet(a, &.{}, true));
            }
            return arityErr("HashSet expects 0, 1, or 2 args");
        },
    }
}
