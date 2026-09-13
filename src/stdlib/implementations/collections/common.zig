//! Shared helpers for the collection intrinsics: result wrappers, value
//! construction, borrows, equality and search, natural-order comparison,
//! receiver accessors, range views and `iterableItems`.

const std = @import("std");
const runtime = @import("runtime");
const text = @import("../../text.zig");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const MapEntries = runtime.MapEntries;
const MapPair = runtime.MapPair;
const CollBackingRef = runtime.CollBackingRef;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;
const RangeKind = runtime.RangeKind;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const IntrinsicHost = runtime.IntrinsicHost;
const Output = runtime.Output;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;
const Order = std.math.Order;

const sequence_mod = @import("sequence.zig");
const materialiseSequence = sequence_mod.materialiseSequence;

const views_mod = @import("views.zig");
const sublistComodGuard = views_mod.sublistComodGuard;

pub fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

/// Return a value borrowed from the receiver (a stored element or entry value).
/// Dispatch takes ownership of a host result, so the borrow is retained first.
pub fn okElem(v: Value) EvalResult {
    v.retain();
    return .{ .ok = v };
}

pub fn typeErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Type = msg } };
}

pub fn arityErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Arity = msg } };
}

pub fn fmt(a: Allocator, comptime spec: []const u8, args: anytype) Error![]u8 {
    return std.fmt.allocPrint(a, spec, args);
}

pub fn display(a: Allocator, v: Value) Error![]u8 {
    return v.display(a);
}

pub fn makeStringOwned(a: Allocator, s: []const u8) Error!Value {
    return .{ .String = try runtime.strInit(a, s) };
}

/// Wrap a slice of values into a `List`. A mutable list gets a fresh
/// structural-modification counter so its iterators fail fast.
pub fn modCountFor(a: Allocator, mutable: bool) Error!runtime.OptRef(u64) {
    if (!mutable) return .{};
    return .from(try ObjRef(u64).init(a, 0));
}

pub fn listLenOf(v: *const Value) usize {
    return switch (v.*) {
        .List => |l| listLen(l.items),
        .Set => |s| listLen(s.items),
        else => 0,
    };
}

fn modCountOf(v: *const Value) runtime.OptRef(u64) {
    return switch (v.*) {
        .List => |l| l.mod_count,
        .Set => |s| s.mod_count,
        else => .{},
    };
}

/// Increment a collection's `mod_count`. Called directly for a structural op
/// that leaves the length unchanged (`trimToSize`, `ensureCapacity`).
pub fn bumpModCount(v: *const Value) void {
    if (modCountOf(v).get()) |mc| {
        const g = mc.borrowMut();
        defer g.deinit();
        g.get().* +%= 1;
    }
}

/// Bumps `mod_count` only when the length changed, so `remove(absent)` and
/// `retainAll` of an unchanged collection register no modification.
pub fn structuralBump(v: *const Value, before: usize) void {
    if (listLenOf(v) != before) bumpModCount(v);
}

pub fn mapEntriesLen(entries: MapEntries) usize {
    const g = entries.borrow();
    defer g.deinit();
    return g.get().pairs.items.len;
}

/// Bumps the map's `mod_count` only when the entry count changed, so
/// `put(existing)` registers no modification while a fresh key or `remove`
/// fails a concurrent view iterator sharing this counter.
pub fn mapStructuralBump(entries: MapEntries, before: usize) void {
    const g = entries.borrowMut();
    defer g.deinit();
    if (g.get().pairs.items.len == before) return;
    if (g.get().mod_count.get()) |mc| {
        const mg = mc.borrowMut();
        defer mg.deinit();
        mg.get().* +%= 1;
    }
}

/// A new handle on the map's shared `mod_count` for a view, so the view's
/// iterator fails fast when the source map mutates structurally.
pub fn entriesCounterNow(entries: MapEntries) u64 {
    const g = entries.borrow();
    defer g.deinit();
    const cell = g.get().mod_count.get() orelse return 0;
    const cg = cell.borrow();
    defer cg.deinit();
    return cg.get().*;
}

pub fn entriesModCountClone(entries: MapEntries) runtime.OptRef(u64) {
    const g = entries.borrow();
    defer g.deinit();
    return if (g.get().mod_count.get()) |mc| .from(mc.clone()) else .{};
}

pub fn makeList(a: Allocator, items: []const Value, mutable: bool) Error!Value {
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(a, items);
    // `items` is borrowed; the list owns one ref per element, so retain.
    if (runtime.reclaimEnabled()) for (list.items) |e| e.retain();
    return try Value.newList(a, .{
        .items = try ValueList.init(a, list),
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
        .mod_count = try modCountFor(a, mutable),
    });
}

pub fn makeListFromArrayList(a: Allocator, list: std.ArrayList(Value), mutable: bool) Error!Value {
    return try Value.newList(a, .{
        .items = try ValueList.init(a, list),
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
        .mod_count = try modCountFor(a, mutable),
    });
}

/// As `makeListFromArrayList`, for a backing whose elements are borrowed: the
/// new list retains each before adopting it. Callers whose backing holds freshly
/// owned elements use `makeListFromArrayList` so ownership transfers instead.
pub fn makeListBorrowed(a: Allocator, list: std.ArrayList(Value), mutable: bool) Error!Value {
    if (runtime.reclaimEnabled()) for (list.items) |e| e.retain();
    return makeListFromArrayList(a, list, mutable);
}

pub fn makeListVL(a: Allocator, vl: ValueList, mutable: bool) Error!Value {
    const g = vl.borrow();
    defer g.deinit();
    return makeList(a, g.get().items, mutable);
}

pub fn makeSetVL(a: Allocator, vl: ValueList, mutable: bool) Error!Value {
    const g = vl.borrow();
    defer g.deinit();
    return makeSet(a, g.get().items, mutable);
}

pub fn appendVL(dst: *std.ArrayList(Value), a: Allocator, vl: ValueList) Error!void {
    const g = vl.borrow();
    defer g.deinit();
    try dst.appendSlice(a, g.get().items);
}

pub fn appendArrItems(dst: *std.ArrayList(Value), a: Allocator, arr: runtime.ArrayData) Error!void {
    const snap = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(snap);
    try dst.appendSlice(a, snap);
}

/// Build a `Set`, deduping by boxed structural equality.
pub fn makeSet(a: Allocator, items: []const Value, mutable: bool) Error!Value {
    var deduped: std.ArrayList(Value) = .empty;
    for (items) |v| {
        if (!containsBoxed(deduped.items, &v)) {
            // Borrowed input element; the set owns one ref per kept element.
            if (runtime.reclaimEnabled()) v.retain();
            try deduped.append(a, v);
        }
    }
    return try Value.newSet(a, .{
        .items = try ValueList.init(a, deduped),
        .mutable = mutable,
        .backing = null,
        .mod_count = try modCountFor(a, mutable),
    });
}

pub fn makeArray(a: Allocator, items: []const Value, prim: ?PrimitiveArrayKind) Error!Value {
    if (prim) |k| return runtime.ArrayData.initPacked(a, k, items);
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(a, items);
    // Borrowed input slice; the array owns one ref per element.
    if (runtime.reclaimEnabled()) for (list.items) |e| e.retain();
    return runtime.ArrayData.fromBoxedList(try ValueList.init(a, list));
}

pub fn makeArrayFromArrayList(a: Allocator, list_in: std.ArrayList(Value), prim: ?PrimitiveArrayKind) Error!Value {
    if (prim) |k| {
        var list = list_in;
        const v = try runtime.ArrayData.initPacked(a, k, list.items);
        // Packed copy owns the scalars now; drop the boxed input buffer.
        if (runtime.reclaimEnabled()) for (list.items) |e| e.release(a);
        list.deinit(a);
        return v;
    }
    return runtime.ArrayData.fromBoxedList(try ValueList.init(a, list_in));
}

/// As `makeListBorrowed`, for an array: the new array retains each element.
pub fn makeArrayBorrowed(a: Allocator, list: std.ArrayList(Value), prim: ?PrimitiveArrayKind) Error!Value {
    if (runtime.reclaimEnabled()) for (list.items) |e| e.retain();
    return makeArrayFromArrayList(a, list, prim);
}

pub fn makeMap(a: Allocator, entries: []const MapPair, mutable: bool) Error!Value {
    var out: std.ArrayList(MapPair) = .empty;
    for (entries) |kv| {
        if (findKeyIndexBoxed(out.items, &kv.key)) |i| {
            if (runtime.reclaimEnabled()) {
                out.items[i].value.release(a);
                kv.value.retain();
            }
            out.items[i].value = kv.value;
        } else {
            if (runtime.reclaimEnabled()) {
                kv.key.retain();
                kv.value.retain();
            }
            try out.append(a, kv);
        }
    }
    return try Value.newMap(a, .{ .entries = try MapEntries.init(a, .{ .pairs = out, .mod_count = try modCountFor(a, mutable) }), .mutable = mutable });
}

pub fn makeMapFromArrayList(a: Allocator, entries: std.ArrayList(MapPair), mutable: bool) Error!Value {
    return try Value.newMap(a, .{ .entries = try MapEntries.init(a, .{ .pairs = entries, .mod_count = try modCountFor(a, mutable) }), .mutable = mutable });
}

pub fn makeMapBorrowed(a: Allocator, entries: std.ArrayList(MapPair), mutable: bool) Error!Value {
    if (runtime.reclaimEnabled()) for (entries.items) |kv| {
        kv.key.retain();
        kv.value.retain();
    };
    return makeMapFromArrayList(a, entries, mutable);
}

pub fn makePair(a: Allocator, first: Value, second: Value) Error!Value {
    return try Value.newPair(a, .{ .first = try Value.boxRef(a, first), .second = try Value.boxRef(a, second) });
}

pub fn makeTriple(a: Allocator, first: Value, second: Value, third: Value) Error!Value {
    return try Value.newTriple(a, .{
        .first = try Value.boxRef(a, first),
        .second = try Value.boxRef(a, second),
        .third = try Value.boxRef(a, third),
    });
}

pub fn makeException(a: Allocator, fqn: []const u8, message: ?[]const u8) Error!Value {
    const fqn_ref = try runtime.strInit(a, fqn);
    const msg_ref: ?StringRef = if (message) |m| try runtime.strInit(a, m) else null;
    return try Value.newException(a, .{ .fqn = fqn_ref, .message = .from(msg_ref), .cause = null });
}

pub fn thrown(a: Allocator, fqn: []const u8, message: ?[]const u8) Error!EvalResult {
    return .{ .err = .{ .Thrown = try makeException(a, fqn, message) } };
}

/// A structural mutation on a read-only collection throws
/// `UnsupportedOperationException`, as Kotlin does for a read-only
/// `List`/`Set`/`Map`. Null when `args[0]` is mutable.
pub const FROZEN_MOD_BIT: u64 = runtime.FROZEN_MOD_BIT;

pub fn modCountFrozen(mc: runtime.OptRef(u64)) bool {
    const cell = mc.get() orelse return false;
    const g = cell.borrow();
    defer g.deinit();
    return (g.get().* & FROZEN_MOD_BIT) != 0;
}

/// A live `MutableMap` view supports write-through removal but never insertion:
/// Kotlin's map views throw from `add` and `addAll`.
pub fn mapViewAddGuard(a: Allocator, args: []const Value) Error!?EvalResult {
    if (args.len == 0) return null;
    const backing: ?*CollBackingRef.Cell = switch (args[0]) {
        .Set => |x| x.backing,
        .List => |x| x.backing,
        else => null,
    };
    const cell = backing orelse return null;
    const ref = CollBackingRef{ .cell = cell };
    const g = ref.borrow();
    defer g.deinit();
    if (g.get().* == .map) {
        return try thrown(a, "kotlin.UnsupportedOperationException", null);
    }
    return null;
}

pub fn readOnlyMutationGuard(a: Allocator, args: []const Value) Error!?EvalResult {
    if (args.len == 0) return null;
    const read_only = switch (args[0]) {
        .List => |l| !l.mutable or modCountFrozen(l.mod_count),
        .Set => |s| !s.mutable or modCountFrozen(s.mod_count),
        .Map => |m| blk: {
            if (!m.mutable) break :blk true;
            const g = m.entries.borrow();
            defer g.deinit();
            break :blk modCountFrozen(g.get().mod_count);
        },
        else => false,
    };
    if (!read_only) return null;
    return try thrown(a, "kotlin.UnsupportedOperationException", null);
}

pub fn snapshotItems(a: Allocator, items: ValueList) Error![]Value {
    const g = items.borrow();
    defer g.deinit();
    return a.dupe(Value, g.get().items);
}

pub fn listLen(items: ValueList) usize {
    const g = items.borrow();
    defer g.deinit();
    return g.get().items.len;
}

pub fn mapLen(entries: MapEntries) usize {
    const g = entries.borrow();
    defer g.deinit();
    return g.get().pairs.items.len;
}

pub fn snapshotEntries(a: Allocator, entries: MapEntries) Error![]MapPair {
    const g = entries.borrow();
    defer g.deinit();
    return a.dupe(MapPair, g.get().pairs.items);
}

pub fn eqBoxed(x: *const Value, y: *const Value) bool {
    return Value.structuralEqBoxed(x, y);
}

/// Value equality honouring a user `equals` override: with an Instance on
/// either side the VM dispatches `x.equals(y)`, as Kotlin's membership and dedup
/// do; otherwise structural equality.
pub fn eqBoxedH(host: IntrinsicHost, out: Output, x: *const Value, y: *const Value) Error!bool {
    if (x.* == .Instance or y.* == .Instance) {
        if (try host.invokeMethod(x, "equals", &.{y.*}, out)) |m| {
            if (m == .ok and m.ok == .Bool) return m.ok.Bool;
        }
    }
    // Tuple shapes compare component-wise through the host so an Instance
    // component's user `equals` dispatches.
    if (x.* == .Pair and y.* == .Pair) {
        return (try eqBoxedH(host, out, x.Pair.first.asPtr(), y.Pair.first.asPtr())) and
            (try eqBoxedH(host, out, x.Pair.second.asPtr(), y.Pair.second.asPtr()));
    }
    if (x.* == .Triple and y.* == .Triple) {
        return (try eqBoxedH(host, out, x.Triple.first.asPtr(), y.Triple.first.asPtr())) and
            (try eqBoxedH(host, out, x.Triple.second.asPtr(), y.Triple.second.asPtr())) and
            (try eqBoxedH(host, out, x.Triple.third.asPtr(), y.Triple.third.asPtr()));
    }
    if (x.* == .MapEntry and y.* == .MapEntry) {
        return (try eqBoxedH(host, out, x.MapEntry.key.asPtr(), y.MapEntry.key.asPtr())) and
            (try eqBoxedH(host, out, x.MapEntry.value.asPtr(), y.MapEntry.value.asPtr()));
    }
    return eqBoxed(x, y);
}

pub fn containsBoxed(items: []const Value, needle: *const Value) bool {
    for (items) |*v| {
        if (eqBoxed(v, needle)) return true;
    }
    return false;
}

pub fn containsBoxedH(host: IntrinsicHost, out: Output, items: []const Value, needle: *const Value) Error!bool {
    for (items) |*v| {
        if (try eqBoxedH(host, out, v, needle)) return true;
    }
    return false;
}

pub fn indexOfBoxedH(host: IntrinsicHost, out: Output, items: []const Value, needle: *const Value) Error!?usize {
    for (items, 0..) |*v, i| {
        if (try eqBoxedH(host, out, v, needle)) return i;
    }
    return null;
}

pub fn findKeyIndexBoxedH(host: IntrinsicHost, out: Output, entries: []const MapPair, key: *const Value) Error!?usize {
    for (entries, 0..) |*kv, i| {
        if (try eqBoxedH(host, out, &kv.key, key)) return i;
    }
    return null;
}

pub fn makeMapH(host: IntrinsicHost, out: Output, a: Allocator, entries: []const MapPair, mutable: bool) Error!Value {
    var o: std.ArrayList(MapPair) = .empty;
    for (entries) |kv| {
        if (try findKeyIndexBoxedH(host, out, o.items, &kv.key)) |i| {
            if (runtime.reclaimEnabled()) {
                o.items[i].value.release(a);
                kv.value.retain();
            }
            o.items[i].value = kv.value;
        } else {
            if (runtime.reclaimEnabled()) {
                kv.key.retain();
                kv.value.retain();
            }
            try o.append(a, kv);
        }
    }
    return try Value.newMap(a, .{ .entries = try MapEntries.init(a, .{ .pairs = o, .mod_count = try modCountFor(a, mutable) }), .mutable = mutable });
}

pub fn makeSetH(host: IntrinsicHost, out: Output, a: Allocator, items: []const Value, mutable: bool) Error!Value {
    var deduped: std.ArrayList(Value) = .empty;
    for (items) |v| {
        if (!try containsBoxedH(host, out, deduped.items, &v)) {
            if (runtime.reclaimEnabled()) v.retain();
            try deduped.append(a, v);
        }
    }
    return try Value.newSet(a, .{
        .items = try ValueList.init(a, deduped),
        .mutable = mutable,
        .backing = null,
        .mod_count = try modCountFor(a, mutable),
    });
}

/// Reinterpret a numeric `needle` into a primitive array's element kind, the
/// coercion Kotlin applies to a `contains` argument typed as the element type.
/// A non-numeric needle passes through so an `Any?` probe compares as-is.
pub fn coerceNeedleToArrayKind(needle: Value, kind: ?PrimitiveArrayKind) Value {
    const k = kind orelse return needle;
    const bits: u64 = switch (needle) {
        .Int => |x| @bitCast(@as(i64, x)),
        .Long => |x| @bitCast(x),
        .Short => |x| @bitCast(@as(i64, x)),
        .Byte => |x| @bitCast(@as(i64, x)),
        .UInt => |x| x,
        .ULong => |x| x,
        .UShort => |x| x,
        .UByte => |x| x,
        else => return needle,
    };
    return switch (k) {
        .UInt => .{ .UInt = @truncate(bits) },
        .ULong => .{ .ULong = bits },
        .UShort => .{ .UShort = @truncate(bits) },
        .UByte => .{ .UByte = @truncate(bits) },
        else => needle,
    };
}

pub fn indexOfBoxed(items: []const Value, needle: *const Value) ?usize {
    for (items, 0..) |*v, i| {
        if (eqBoxed(v, needle)) return i;
    }
    return null;
}

pub fn findKeyIndexBoxed(entries: []const MapPair, key: *const Value) ?usize {
    for (entries, 0..) |*kv, i| {
        if (eqBoxed(&kv.key, key)) return i;
    }
    return null;
}

pub fn isCallable(v: Value) bool {
    return switch (v) {
        .IrClosure, .Intrinsic, .Instance => true,
        else => false,
    };
}

pub fn isTransformCallable(v: Value) bool {
    return switch (v) {
        .IrClosure, .BoundMethod => true,
        .Instance => |inst| blk: {
            const g = inst.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk std.mem.startsWith(u8, cg.get().name, "$bound_ref$");
        },
        else => false,
    };
}

/// Invoke a callable, short-circuiting a `RuntimeError` back to the caller.
const CallOutcome = union(enum) { value: Value, err: EvalResult };

pub fn invoke(ctx: *CallCtx, callable: *const Value, args: []const Value) Error!CallOutcome {
    const r = try ctx.host.invokeCallable(callable, args, ctx.out);
    return switch (r) {
        .ok => |v| .{ .value = v },
        .err => |e| .{ .err = .{ .err = e } },
    };
}

pub const CompareOutcome = union(enum) { order: Order, err: EvalResult };

/// Kotlin's `Double`/`Float` total order: every NaN is greater than every other
/// value, all NaNs are equal, and `-0.0 < 0.0`.
fn kotlinFloatTotalCmp(x: f64, y: f64) Order {
    if (x < y) return .lt;
    if (x > y) return .gt;
    const bits = struct {
        fn f(v: f64) i64 {
            if (std.math.isNan(v)) return @bitCast(@as(u64, 0x7ff8_0000_0000_0000));
            return @bitCast(v);
        }
    }.f;
    return std.math.order(bits(x), bits(y));
}

pub fn compareValues(a: Allocator, x: Value, y: Value) Error!CompareOutcome {
    // Kotlin's `compareValues` sorts null before any non-null value.
    if (x == .Null or y == .Null) {
        if (x == .Null and y == .Null) return .{ .order = .eq };
        return .{ .order = if (x == .Null) .lt else .gt };
    }
    if (x.isNumeric() and y.isNumeric()) {
        if (x.isIntegral() and y.isIntegral()) {
            // Unsigned operands compare by magnitude; read as i64 they wrap.
            if (x.isUnsigned() and y.isUnsigned()) {
                return .{ .order = std.math.order(x.asU64().?, y.asU64().?) };
            }
            return .{ .order = std.math.order(x.asI64().?, y.asI64().?) };
        }
        return .{ .order = kotlinFloatTotalCmp(x.asF64().?, y.asF64().?) };
    }
    switch (x) {
        .String => |sx| if (y == .String) {
            const gx = sx.borrow();
            defer gx.deinit();
            const gy = y.String.borrow();
            defer gy.deinit();
            return .{ .order = text.compareUtf16(gx.get().bytes, gy.get().bytes) };
        },
        .Char => |cx| if (y == .Char) return .{ .order = std.math.order(cx, y.Char) },
        .Bool => |bx| if (y == .Bool) return .{ .order = std.math.order(@intFromBool(bx), @intFromBool(y.Bool)) },
        else => {},
    }
    const xd = try display(a, x);
    const yd = try display(a, y);
    return .{ .err = typeErr(try fmt(a, "values are not comparable: {s}, {s}", .{ xd, yd })) };
}

pub fn reverseOrder(o: Order) Order {
    return switch (o) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

pub fn i32ToOrdering(n: i32) Order {
    return std.math.order(n, 0);
}

/// Stable natural-order sort. Returns a short-circuit EvalResult when two
/// elements are incomparable.
fn sortValuesNatural(a: Allocator, items: []Value) Error!?EvalResult {
    return sortValuesNaturalDesc(a, items, false);
}

pub fn sortValuesNaturalDesc(a: Allocator, items: []Value, descending: bool) Error!?EvalResult {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const o = switch (try compareValues(a, items[j - 1], items[j])) {
                .order => |o| o,
                .err => |e| return e,
            };
            const flipped = if (descending) reverseOrder(o) else o;
            if (flipped == .gt) {
                std.mem.swap(Value, &items[j - 1], &items[j]);
                j -= 1;
            } else break;
        }
    }
    return null;
}

pub fn writeBackItems(items: ValueList, a: Allocator, src: []const Value) Error!void {
    const g = items.borrowMut();
    defer g.deinit();
    g.get().clearRetainingCapacity();
    try g.get().appendSlice(a, src);
}

const ListItemsOutcome = union(enum) { items: ValueList, err: EvalResult };

pub fn recvListItems(a: Allocator, args: []const Value, what: []const u8) Error!ListItemsOutcome {
    if (args.len > 0 and args[0] == .List) {
        // A live subList view fails fast when its backing changed structurally
        // other than through the view.
        if (try sublistComodGuard(a, &args[0])) |e| return .{ .err = e };
        // An array `.asList()` view re-reads its scalar source, so a later array
        // write shows through.
        args[0].refreshArrayView();
        args[0].refreshSublistView();
        return .{ .items = args[0].List.items };
    }
    return .{ .err = typeErr(try fmt(a, "{s} requires a List receiver", .{what})) };
}

pub fn recvSetItems(a: Allocator, args: []const Value, what: []const u8) Error!ListItemsOutcome {
    if (args.len > 0 and args[0] == .Set) return .{ .items = args[0].Set.items };
    return .{ .err = typeErr(try fmt(a, "{s} requires a Set receiver", .{what})) };
}

pub const MapEntriesOutcome = union(enum) { entries: MapEntries, err: EvalResult };

pub fn recvMapEntries(a: Allocator, args: []const Value, what: []const u8) Error!MapEntriesOutcome {
    if (args.len > 0 and args[0] == .Map) return .{ .entries = args[0].Map.entries };
    return .{ .err = typeErr(try fmt(a, "{s} requires a Map receiver", .{what})) };
}

// Range iteration, a local copy since ranges.zig is not imported here.

pub const RangeIter = struct {
    cur: i64,
    end: i64,
    step: i64,
    kind: RangeKind,
    done: bool,

    pub fn init(start: i64, end: i64, step: i64, kind: RangeKind) RangeIter {
        const empty = step == 0 or !kind.inBounds(start, end, step);
        return .{ .cur = start, .end = end, .step = step, .kind = kind, .done = empty };
    }

    pub fn next(self: *RangeIter) ?i64 {
        if (self.done) return null;
        // `inBounds` compares unsigned for ULong (`MaxUL..MinUL` is empty).
        if (!self.kind.inBounds(self.cur, self.end, self.step)) {
            self.done = true;
            return null;
        }
        const v = self.cur;
        // `end` is the exact final element, so stop once it is yielded and the
        // cursor never overflows past it.
        if (self.cur == self.end) {
            self.done = true;
            return v;
        }
        const adv = self.cur +| self.step;
        if (adv == self.cur) self.done = true else self.cur = adv;
        return v;
    }
};

fn rangeEndpoint(kind: RangeKind, v: i64) Value {
    return switch (kind) {
        .Long => .{ .Long = v },
        .Int => .{ .Int = @truncate(v) },
        .Char => .{ .Char = @truncate(@as(u64, @bitCast(v))) },
        .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(v))) },
        .ULong => .{ .ULong = @bitCast(v) },
    };
}

const RangeView = struct { start: i64, end: i64, step: i64, kind: RangeKind };

pub fn asRangeView(v: Value) ?RangeView {
    switch (v) {
        .Range => |r| return .{ .start = r.start, .end = r.end, .step = r.step, .kind = r.kind },
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            const b = g.get();
            const cg = b.class.borrow();
            defer cg.deinit();
            const fqn = cg.get().fqn;
            if (!std.mem.startsWith(u8, fqn, "kotlin.ranges.")) return null;
            const kind: RangeKind = if (std.mem.find(u8, fqn, "Long") != null)
                .Long
            else if (std.mem.find(u8, fqn, "Char") != null)
                .Char
            else if (std.mem.find(u8, fqn, "Int") != null)
                .Int
            else
                return null;
            const start = instNum(b, &.{ "first", "start" }) orelse return null;
            const end = instNum(b, &.{ "last", "endInclusive" }) orelse return null;
            const step = instNum(b, &.{"step"}) orelse 1;
            return .{ .start = start, .end = end, .step = step, .kind = kind };
        },
        else => return null,
    }
}

fn instNum(inst: *const InstanceData, names: []const []const u8) ?i64 {
    for (names) |n| {
        if (inst.get(n)) |val| {
            if (val.asI64()) |i| return i;
            if (val == .Char) return @as(i64, val.Char);
        }
    }
    return null;
}

pub const ItemsOutcome = union(enum) { items: []Value, err: EvalResult };

/// Collect a List/Set/Array/Map/Range receiver into a fresh slice; a Map yields
/// `MapEntry` values. An error EvalResult when the receiver is not iterable.
pub fn iterableItems(a: Allocator, v: Value, what: []const u8) Error!ItemsOutcome {
    switch (v) {
        .List, .Set, .Array => {
            if (v == .List) (&v).refreshArrayView();
            if (v == .List) (&v).refreshSublistView();
            const items = switch (v) {
                .List => |l| try snapshotItems(a, l.items),
                .Set => |s| try snapshotItems(a, s.items),
                .Array => |arr| try arr.snapshot(a),
                else => unreachable,
            };
            return .{ .items = items };
        },
        .Map => |m| {
            const g = m.entries.borrow();
            defer g.deinit();
            const src = g.get().pairs.items;
            var out = try a.alloc(Value, src.len);
            for (src, 0..) |kv, i| {
                kv.key.retain();
                kv.value.retain();
                out[i] = try Value.newMapEntry(a, .{
                    .key = try Value.boxRef(a, kv.key),
                    .value = try Value.boxRef(a, kv.value),
                    .backing = .{},
                });
            }
            return .{ .items = out };
        },
        .Range => {
            const view = asRangeView(v) orelse {
                return .{ .err = typeErr(try fmt(a, "{s} requires an iterable receiver", .{what})) };
            };
            var list: std.ArrayList(Value) = .empty;
            var it = RangeIter.init(view.start, view.end, view.step, view.kind);
            while (it.next()) |n| try list.append(a, rangeEndpoint(view.kind, n));
            return .{ .items = try list.toOwnedSlice(a) };
        },
        else => return .{ .err = typeErr(try fmt(a, "{s} requires an iterable receiver", .{what})) },
    }
}

/// As `iterableItems`, but also materialises a lazy `Sequence` argument through
/// the host, for any bulk op that accepts one.
pub fn iterableItemsCtx(ctx: *CallCtx, v: Value, what: []const u8) Error!ItemsOutcome {
    if (v == .Sequence) {
        return switch (try materialiseSequence(ctx.allocator, ctx.host, ctx.out, v)) {
            .items => |x| .{ .items = x },
            .err => |e| .{ .err = .{ .err = e } },
        };
    }
    // A user `Iterable` has no built-in backing; drain its `iterator()`.
    if (v == .Instance) {
        if (try drainViaIterator(ctx, v)) |r| return r;
    }
    return iterableItems(ctx.allocator, v, what);
}

/// Drain any value exposing `iterator()`, `hasNext()` and `next()` into a flat
/// slice. Null when it has no `iterator()`, so the caller can fall back.
fn drainViaIterator(ctx: *CallCtx, v: Value) Error!?ItemsOutcome {
    const a = ctx.allocator;
    const iter_opt = try ctx.host.invokeMethod(&v, "iterator", &.{}, ctx.out);
    const iter_res = iter_opt orelse return null;
    const iter = switch (iter_res) {
        .ok => |x| x,
        .err => |e| return ItemsOutcome{ .err = .{ .err = e } },
    };
    var out: std.ArrayList(Value) = .empty;
    while (true) {
        const hn = (try ctx.host.invokeMethod(&iter, "hasNext", &.{}, ctx.out)) orelse return null;
        const has = switch (hn) {
            .ok => |x| x == .Bool and x.Bool,
            .err => |e| return ItemsOutcome{ .err = .{ .err = e } },
        };
        if (!has) break;
        const nx = (try ctx.host.invokeMethod(&iter, "next", &.{}, ctx.out)) orelse return null;
        switch (nx) {
            .ok => |item| try out.append(a, item),
            .err => |e| return ItemsOutcome{ .err = .{ .err = e } },
        }
    }
    return ItemsOutcome{ .items = try out.toOwnedSlice(a) };
}

pub const OrderResult = union(enum) { order: Order, err: RuntimeError };

pub fn compareValuesPublic(a: Allocator, x: Value, y: Value) Error!OrderResult {
    return switch (try compareValues(a, x, y)) {
        .order => |o| .{ .order = o },
        .err => |e| .{ .err = e.err },
    };
}

pub fn primitive_companion_const(ty: []const u8, name: []const u8) ?Value {
    const T = struct {
        fn eq(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    };
    if (T.eq(ty, "Int")) {
        if (T.eq(name, "MAX_VALUE")) return Value.newInt(@as(i64, std.math.maxInt(i32)));
        if (T.eq(name, "MIN_VALUE")) return Value.newInt(@as(i64, std.math.minInt(i32)));
        if (T.eq(name, "SIZE_BITS")) return Value.newInt(32);
        if (T.eq(name, "SIZE_BYTES")) return Value.newInt(4);
    } else if (T.eq(ty, "Long")) {
        if (T.eq(name, "MAX_VALUE")) return .{ .Long = std.math.maxInt(i64) };
        if (T.eq(name, "MIN_VALUE")) return .{ .Long = std.math.minInt(i64) };
        if (T.eq(name, "SIZE_BITS")) return Value.newInt(64);
        if (T.eq(name, "SIZE_BYTES")) return Value.newInt(8);
    } else if (T.eq(ty, "Short")) {
        if (T.eq(name, "MAX_VALUE")) return .{ .Short = std.math.maxInt(i16) };
        if (T.eq(name, "MIN_VALUE")) return .{ .Short = std.math.minInt(i16) };
        if (T.eq(name, "SIZE_BITS")) return Value.newInt(16);
        if (T.eq(name, "SIZE_BYTES")) return Value.newInt(2);
    } else if (T.eq(ty, "Byte")) {
        if (T.eq(name, "MAX_VALUE")) return .{ .Byte = std.math.maxInt(i8) };
        if (T.eq(name, "MIN_VALUE")) return .{ .Byte = std.math.minInt(i8) };
        if (T.eq(name, "SIZE_BITS")) return Value.newInt(8);
        if (T.eq(name, "SIZE_BYTES")) return Value.newInt(1);
    } else if (T.eq(ty, "Double")) {
        if (T.eq(name, "MAX_VALUE")) return .{ .Double = std.math.floatMax(f64) };
        if (T.eq(name, "MIN_VALUE")) return .{ .Double = std.math.floatMin(f64) };
        if (T.eq(name, "POSITIVE_INFINITY")) return .{ .Double = std.math.inf(f64) };
        if (T.eq(name, "NEGATIVE_INFINITY")) return .{ .Double = -std.math.inf(f64) };
        if (T.eq(name, "NaN")) return .{ .Double = std.math.nan(f64) };
        if (T.eq(name, "SIZE_BITS")) return Value.newInt(64);
        if (T.eq(name, "SIZE_BYTES")) return Value.newInt(8);
    } else if (T.eq(ty, "Float")) {
        if (T.eq(name, "MAX_VALUE")) return .{ .Float = std.math.floatMax(f32) };
        if (T.eq(name, "MIN_VALUE")) return .{ .Float = std.math.floatMin(f32) };
        if (T.eq(name, "POSITIVE_INFINITY")) return .{ .Float = std.math.inf(f32) };
        if (T.eq(name, "NEGATIVE_INFINITY")) return .{ .Float = -std.math.inf(f32) };
        if (T.eq(name, "NaN")) return .{ .Float = std.math.nan(f32) };
        if (T.eq(name, "SIZE_BITS")) return Value.newInt(32);
        if (T.eq(name, "SIZE_BYTES")) return Value.newInt(4);
    } else if (T.eq(ty, "Char")) {
        if (T.eq(name, "MAX_VALUE")) return .{ .Char = 0xFFFF };
        if (T.eq(name, "MIN_VALUE")) return .{ .Char = 0 };
        if (T.eq(name, "SIZE_BITS")) return Value.newInt(16);
        if (T.eq(name, "SIZE_BYTES")) return Value.newInt(2);
    } else if (T.eq(ty, "UInt")) {
        if (T.eq(name, "MAX_VALUE")) return .{ .UInt = std.math.maxInt(u32) };
        if (T.eq(name, "MIN_VALUE")) return .{ .UInt = 0 };
        if (T.eq(name, "SIZE_BITS")) return Value.newInt(32);
        if (T.eq(name, "SIZE_BYTES")) return Value.newInt(4);
    } else if (T.eq(ty, "ULong")) {
        if (T.eq(name, "MAX_VALUE")) return .{ .ULong = std.math.maxInt(u64) };
        if (T.eq(name, "MIN_VALUE")) return .{ .ULong = 0 };
        if (T.eq(name, "SIZE_BITS")) return Value.newInt(64);
        if (T.eq(name, "SIZE_BYTES")) return Value.newInt(8);
    } else if (T.eq(ty, "UShort")) {
        if (T.eq(name, "MAX_VALUE")) return .{ .UShort = std.math.maxInt(u16) };
        if (T.eq(name, "MIN_VALUE")) return .{ .UShort = 0 };
        if (T.eq(name, "SIZE_BITS")) return Value.newInt(16);
        if (T.eq(name, "SIZE_BYTES")) return Value.newInt(2);
    } else if (T.eq(ty, "UByte")) {
        if (T.eq(name, "MAX_VALUE")) return .{ .UByte = std.math.maxInt(u8) };
        if (T.eq(name, "MIN_VALUE")) return .{ .UByte = 0 };
        if (T.eq(name, "SIZE_BITS")) return Value.newInt(8);
        if (T.eq(name, "SIZE_BYTES")) return Value.newInt(1);
    }
    return null;
}
