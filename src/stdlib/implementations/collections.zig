//! Collection stdlib intrinsics (List / Set / Map / Iterable / Array /
//! Pair / Triple / Sequence).
//!
//! Each intrinsic is a `fn(*CallCtx) std.mem.Allocator.Error!EvalResult`.
//! `Ok(v)` becomes `EvalResult{ .ok = v }` and `Err(e)` becomes
//! `EvalResult{ .err = e }`. OOM is the only Zig `error`.
//!
//! Memory model: heap-owning containers (`StringRef`, `ValueList`,
//! `MapEntries`) are created via `ctx.allocator` and never freed
//! individually — the interpreter drives an arena per eval phase instead. A
//! plain `Value` copy shares the same backing handle.

const std = @import("std");
const runtime = @import("runtime");
const text = @import("../text.zig");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const MapEntries = runtime.MapEntries;
const MapPair = runtime.MapPair;
const CollBacking = runtime.CollBacking;
const CollBackingRef = runtime.CollBackingRef;
const MapViewKind = runtime.MapViewKind;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;
const PrimBuf = runtime.PrimBuf;
const RangeKind = runtime.RangeKind;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const IntrinsicHost = runtime.IntrinsicHost;
const Output = runtime.Output;
const SeqOp = runtime.SeqOp;

const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;
const Order = std.math.Order;

// =====================================================================
// Result/error helpers
// =====================================================================

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

/// Return a value that the accessor *borrowed* from its receiver (a stored
/// list/array element or map entry value, not a freshly built result). Host
/// calls return owned values — the dispatch writes the result into a register
/// that takes ownership — so a borrowed element must be retained first or it is
/// released one time too many when the register is overwritten/torn down. The
/// retain is a no-op under the arena fast path.
fn okElem(v: Value) EvalResult {
    v.retain();
    return .{ .ok = v };
}

fn typeErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Type = msg } };
}

fn arityErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Arity = msg } };
}

/// Build an owned, formatted message slice from the ctx allocator.
fn fmt(a: Allocator, comptime spec: []const u8, args: anytype) Error![]u8 {
    return std.fmt.allocPrint(a, spec, args);
}

/// Render a value the way Kotlin `toString` does, owned by `a`.
fn display(a: Allocator, v: Value) Error![]u8 {
    return v.display(a);
}

// =====================================================================
// Value construction helpers (Arc / ObjRef equivalents)
// =====================================================================

/// `Arc::new(string)` — wrap an already-owned slice in a `StringRef`.
fn makeStringOwned(a: Allocator, s: []const u8) Error!Value {
    return .{ .String = try runtime.strInit(a, s) };
}

/// `make_list(items, mutable)` — wrap a slice of values into a `List`.
/// A fresh structural-modification counter for a mutable list (so its
/// iterators can fail-fast), or null for a read-only list.
fn modCountFor(a: Allocator, mutable: bool) Error!?ObjRef(u64) {
    if (!mutable) return null;
    return try ObjRef(u64).init(a, 0);
}

/// A `List`/`Set` element count, or 0 for anything else — for the
/// structural-bump diff. (`Map` fail-fast is handled via its own counter.)
fn listLenOf(v: *const Value) usize {
    return switch (v.*) {
        .List => |l| listLen(l.items),
        .Set => |s| listLen(s.items),
        else => 0,
    };
}

/// The shared `mod_count` of a `List`/`Set` value, if any.
fn modCountOf(v: *const Value) ?ObjRef(u64) {
    return switch (v.*) {
        .List => |l| l.mod_count,
        .Set => |s| s.mod_count,
        else => null,
    };
}

/// Increment a collection's `mod_count` (no-op when absent). Use directly for a
/// structural op that does not change length (`trimToSize`/`ensureCapacity`).
pub fn bumpModCount(v: *const Value) void {
    if (modCountOf(v)) |mc| {
        const g = mc.borrowMut();
        defer g.deinit();
        g.get().* +%= 1;
    }
}

/// `defer structuralBump(&ctx.args[0], before)`: bump `mod_count` only when the
/// length actually changed, so `remove(absent)` / `removeAll([])` / `retainAll`
/// of an unchanged collection register no modification (Kotlin's contract).
fn structuralBump(v: *const Value, before: usize) void {
    if (listLenOf(v) != before) bumpModCount(v);
}

/// `entries.pairs.len` — captured before a map mutation for the size diff.
fn mapEntriesLen(entries: MapEntries) usize {
    const g = entries.borrow();
    defer g.deinit();
    return g.get().pairs.items.len;
}

/// `defer mapStructuralBump(entries, before)`: bump the map's `mod_count` only
/// when the entry count changed, so `put(existing)`/`putAll([])` register no
/// modification while a fresh key / `remove`/`clear` fail a concurrent view
/// iterator (which shares this counter).
fn mapStructuralBump(entries: MapEntries, before: usize) void {
    const g = entries.borrowMut();
    defer g.deinit();
    if (g.get().pairs.items.len == before) return;
    if (g.get().mod_count) |mc| {
        const mg = mc.borrowMut();
        defer mg.deinit();
        mg.get().* +%= 1;
    }
}

/// A new handle on the map's shared `mod_count`, for a `keys`/`values`/`entries`
/// view so its iterator fails fast when the source map mutates structurally.
/// Current structural counter of an entries store (0 when uncounted).
fn entriesCounterNow(entries: MapEntries) u64 {
    const g = entries.borrow();
    defer g.deinit();
    const cell = g.get().mod_count orelse return 0;
    const cg = cell.borrow();
    defer cg.deinit();
    return cg.get().*;
}

fn entriesModCountClone(entries: MapEntries) ?ObjRef(u64) {
    const g = entries.borrow();
    defer g.deinit();
    return if (g.get().mod_count) |mc| mc.clone() else null;
}

fn makeList(a: Allocator, items: []const Value, mutable: bool) Error!Value {
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(a, items);
    // `items` is a borrowed slice (call args, or a `snapshotItems`/`dupe` copy
    // that did not bump counts); the list owns one ref per element, so retain.
    if (runtime.reclaimEnabled()) for (list.items) |e| e.retain();
    return .{ .List = .{
        .items = try ValueList.init(a, list),
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
        .mod_count = try modCountFor(a, mutable),
    } };
}

/// `make_list` consuming an already-built ArrayList (no copy).
fn makeListFromArrayList(a: Allocator, list: std.ArrayList(Value), mutable: bool) Error!Value {
    return .{ .List = .{
        .items = try ValueList.init(a, list),
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
        .mod_count = try modCountFor(a, mutable),
    } };
}

/// Like `makeListFromArrayList`, but for a backing whose elements are *borrowed*
/// (copied in from `snapshotItems`/`iterableItems`/call args without bumping
/// counts). The new list owns one reference per element, so retain each before
/// adopting the backing — exactly as `makeList` does for a borrowed slice.
/// Callers that build the backing from freshly *owned* elements (a `makePair`
/// result, a block-invocation result, an explicitly pre-retained value) use
/// `makeListFromArrayList` instead so ownership transfers without a leak.
fn makeListBorrowed(a: Allocator, list: std.ArrayList(Value), mutable: bool) Error!Value {
    if (runtime.reclaimEnabled()) for (list.items) |e| e.retain();
    return makeListFromArrayList(a, list, mutable);
}

/// Build a new List from the live contents of a `ValueList`, copying under the
/// borrow. Replaces `makeList(a, try snapshotItems(a, vl), m)`: that idiom
/// allocates a `snapshotItems` dupe, has `makeList` copy it again, then orphans
/// the dupe (a per-call raw-temp leak under a freeing/gc backend — the arena
/// reclaimed it for free). One copy, no dangling intermediate.
fn makeListVL(a: Allocator, vl: ValueList, mutable: bool) Error!Value {
    const g = vl.borrow();
    defer g.deinit();
    return makeList(a, g.get().items, mutable);
}

/// `makeListVL` for sets.
fn makeSetVL(a: Allocator, vl: ValueList, mutable: bool) Error!Value {
    const g = vl.borrow();
    defer g.deinit();
    return makeSet(a, g.get().items, mutable);
}

/// Append a `ValueList`'s live elements to `dst`, copying under the borrow.
/// Replaces `dst.appendSlice(a, try snapshotItems(a, vl))`, which leaked the
/// `snapshotItems` dupe (the arena reclaimed it; a freeing/gc backend does not).
fn appendVL(dst: *std.ArrayList(Value), a: Allocator, vl: ValueList) Error!void {
    const g = vl.borrow();
    defer g.deinit();
    try dst.appendSlice(a, g.get().items);
}

/// `appendVL` for an `Array` receiver (boxed or packed).
fn appendArrItems(dst: *std.ArrayList(Value), a: Allocator, arr: runtime.ArrayData) Error!void {
    const snap = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(snap);
    try dst.appendSlice(a, snap);
}

/// `make_set(items, mutable)` — dedupe by boxed structural equality.
fn makeSet(a: Allocator, items: []const Value, mutable: bool) Error!Value {
    var deduped: std.ArrayList(Value) = .empty;
    for (items) |v| {
        if (!containsBoxed(deduped.items, &v)) {
            // Borrowed input element; the set owns one ref per kept element.
            if (runtime.reclaimEnabled()) v.retain();
            try deduped.append(a, v);
        }
    }
    return .{ .Set = .{
        .items = try ValueList.init(a, deduped),
        .mutable = mutable,
        .backing = null,
        .mod_count = try modCountFor(a, mutable),
    } };
}

fn makeArray(a: Allocator, items: []const Value, prim: ?PrimitiveArrayKind) Error!Value {
    if (prim) |k| return runtime.ArrayData.initPacked(a, k, items);
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(a, items);
    // Borrowed input slice; the array owns one ref per element.
    if (runtime.reclaimEnabled()) for (list.items) |e| e.retain();
    return runtime.ArrayData.fromBoxedList(try ValueList.init(a, list));
}

fn makeArrayFromArrayList(a: Allocator, list_in: std.ArrayList(Value), prim: ?PrimitiveArrayKind) Error!Value {
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

/// `makeArrayFromArrayList` for a backing whose elements are *borrowed* (see
/// `makeListBorrowed`): the new array owns one ref per element, so retain each.
fn makeArrayBorrowed(a: Allocator, list: std.ArrayList(Value), prim: ?PrimitiveArrayKind) Error!Value {
    if (runtime.reclaimEnabled()) for (list.items) |e| e.retain();
    return makeArrayFromArrayList(a, list, prim);
}

/// `make_map(entries, mutable)` — dedupe keys, last write wins. The input
/// entries are BORROWED (snapshotEntries copies / Pair-arg reads): the new map
/// owns one ref for each kept key and value, so retain them; on a last-write
/// overwrite release the dropped value (the key keeps its existing ref). Every
/// `makeMap` caller passes borrowed (or empty) entries. No-op under the arena.
fn makeMap(a: Allocator, entries: []const MapPair, mutable: bool) Error!Value {
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
    return .{ .Map = .{ .entries = try MapEntries.init(a, .{ .pairs = out, .mod_count = try modCountFor(a, mutable) }), .mutable = mutable } };
}

fn makeMapFromArrayList(a: Allocator, entries: std.ArrayList(MapPair), mutable: bool) Error!Value {
    return .{ .Map = .{ .entries = try MapEntries.init(a, .{ .pairs = entries, .mod_count = try modCountFor(a, mutable) }), .mutable = mutable } };
}

/// `makeMapFromArrayList` for entries whose key+value are *borrowed*: the new
/// map owns one ref for each key and value, so retain both. Mirrors
/// `makeListBorrowed` for map entries.
fn makeMapBorrowed(a: Allocator, entries: std.ArrayList(MapPair), mutable: bool) Error!Value {
    if (runtime.reclaimEnabled()) for (entries.items) |kv| {
        kv.key.retain();
        kv.value.retain();
    };
    return makeMapFromArrayList(a, entries, mutable);
}

fn makePair(a: Allocator, first: Value, second: Value) Error!Value {
    return .{ .Pair = .{ .first = try Value.boxRef(a, first), .second = try Value.boxRef(a, second) } };
}

fn makeTriple(a: Allocator, first: Value, second: Value, third: Value) Error!Value {
    return .{ .Triple = .{
        .first = try Value.boxRef(a, first),
        .second = try Value.boxRef(a, second),
        .third = try Value.boxRef(a, third),
    } };
}

/// `make_exception(fqn, message)` -> a thrown-ready `Value::Exception`.
fn makeException(a: Allocator, fqn: []const u8, message: ?[]const u8) Error!Value {
    const fqn_ref = try runtime.strInit(a, fqn);
    const msg_ref: ?StringRef = if (message) |m| try runtime.strInit(a, m) else null;
    return .{ .Exception = .{ .fqn = fqn_ref, .message = msg_ref, .cause = null } };
}

/// `Err(RuntimeError::Thrown(make_exception(...)))` as an EvalResult.
fn thrown(a: Allocator, fqn: []const u8, message: ?[]const u8) Error!EvalResult {
    return .{ .err = .{ .Thrown = try makeException(a, fqn, message) } };
}

/// A structural mutation on a read-only collection throws
/// `UnsupportedOperationException` (Kotlin: a `List`/`Set`/`Map` built read-only
/// rejects `add`/`remove`/`set`/`put`/`clear`). Returns the thrown result when
/// `args[0]` is an immutable collection, else null so the caller proceeds.
/// High bit of a shared `mod_count`: the builder that owned this counter
/// froze (`build*` returned), so every VIEW sharing the cell is
/// read-only from now on even though its own `mutable` flag was minted
/// while the builder was live.
pub const FROZEN_MOD_BIT: u64 = runtime.FROZEN_MOD_BIT;

pub fn modCountFrozen(mc: ?ObjRef(u64)) bool {
    const cell = mc orelse return false;
    const g = cell.borrow();
    defer g.deinit();
    return (g.get().* & FROZEN_MOD_BIT) != 0;
}

fn readOnlyMutationGuard(a: Allocator, args: []const Value) Error!?EvalResult {
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

// =====================================================================
// Borrow helpers over ObjRef containers
// =====================================================================

/// Snapshot the items of a `ValueList` into a freshly allocated slice.
fn snapshotItems(a: Allocator, items: ValueList) Error![]Value {
    const g = items.borrow();
    defer g.deinit();
    return a.dupe(Value, g.get().items);
}

fn listLen(items: ValueList) usize {
    const g = items.borrow();
    defer g.deinit();
    return g.get().items.len;
}

fn mapLen(entries: MapEntries) usize {
    const g = entries.borrow();
    defer g.deinit();
    return g.get().pairs.items.len;
}

/// Snapshot a `MapEntries` into a freshly allocated slice of pairs.
fn snapshotEntries(a: Allocator, entries: MapEntries) Error![]MapPair {
    const g = entries.borrow();
    defer g.deinit();
    return a.dupe(MapPair, g.get().pairs.items);
}

// =====================================================================
// Equality / search helpers
// =====================================================================

fn eqBoxed(x: *const Value, y: *const Value) bool {
    return Value.structuralEqBoxed(x, y);
}

/// Value equality that honours a user `equals` override: when either side is a
/// class Instance, dispatch `x.equals(y)` through the VM (as Kotlin's
/// membership/dedup do); otherwise structural equality. A non-data class with a
/// custom `equals` (e.g. klio's `LocalDate`) compares by value, not identity.
fn eqBoxedH(host: IntrinsicHost, out: Output, x: *const Value, y: *const Value) Error!bool {
    if (x.* == .Instance or y.* == .Instance) {
        if (try host.invokeMethod(x, "equals", &.{y.*}, out)) |m| {
            if (m == .ok and m.ok == .Bool) return m.ok.Bool;
        }
    }
    return eqBoxed(x, y);
}

fn containsBoxed(items: []const Value, needle: *const Value) bool {
    for (items) |*v| {
        if (eqBoxed(v, needle)) return true;
    }
    return false;
}

fn containsBoxedH(host: IntrinsicHost, out: Output, items: []const Value, needle: *const Value) Error!bool {
    for (items) |*v| {
        if (try eqBoxedH(host, out, v, needle)) return true;
    }
    return false;
}

fn indexOfBoxedH(host: IntrinsicHost, out: Output, items: []const Value, needle: *const Value) Error!?usize {
    for (items, 0..) |*v, i| {
        if (try eqBoxedH(host, out, v, needle)) return i;
    }
    return null;
}

fn findKeyIndexBoxedH(host: IntrinsicHost, out: Output, entries: []const MapPair, key: *const Value) Error!?usize {
    for (entries, 0..) |*kv, i| {
        if (try eqBoxedH(host, out, &kv.key, key)) return i;
    }
    return null;
}

/// `makeMap` honouring a user `equals` for key dedup (last write wins).
fn makeMapH(host: IntrinsicHost, out: Output, a: Allocator, entries: []const MapPair, mutable: bool) Error!Value {
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
    return .{ .Map = .{ .entries = try MapEntries.init(a, .{ .pairs = o, .mod_count = try modCountFor(a, mutable) }), .mutable = mutable } };
}

/// Dedup `items` honouring user `equals` (for setOf/toSet over user objects).
fn makeSetH(host: IntrinsicHost, out: Output, a: Allocator, items: []const Value, mutable: bool) Error!Value {
    var deduped: std.ArrayList(Value) = .empty;
    for (items) |v| {
        if (!try containsBoxedH(host, out, deduped.items, &v)) {
            if (runtime.reclaimEnabled()) v.retain();
            try deduped.append(a, v);
        }
    }
    return .{ .Set = .{
        .items = try ValueList.init(a, deduped),
        .mutable = mutable,
        .backing = null,
        .mod_count = try modCountFor(a, mutable),
    } };
}

/// Reinterpret a numeric `needle` into the element kind of a primitive
/// array, mirroring the call-site coercion Kotlin applies to a `contains`
/// argument typed as the array's element type (`uintArrayOf(...).contains(5u)`
/// passes a `UInt`, not the bare literal's default kind). Non-numeric needles
/// (objects, null) pass through so an `Any?` probe still compares as-is.
fn coerceNeedleToArrayKind(needle: Value, kind: ?PrimitiveArrayKind) Value {
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

fn indexOfBoxed(items: []const Value, needle: *const Value) ?usize {
    for (items, 0..) |*v, i| {
        if (eqBoxed(v, needle)) return i;
    }
    return null;
}

fn findKeyIndexBoxed(entries: []const MapPair, key: *const Value) ?usize {
    for (entries, 0..) |*kv, i| {
        if (eqBoxed(&kv.key, key)) return i;
    }
    return null;
}

fn isCallable(v: Value) bool {
    return switch (v) {
        .IrClosure, .Function, .Intrinsic, .Instance => true,
        else => false,
    };
}

/// Match the trailing-lambda detection the join/zip ops use.
fn isTransformCallable(v: Value) bool {
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

// =====================================================================
// Host call helper: thread a RuntimeError through as data
// =====================================================================

/// Invoke a callable; on a `RuntimeError` short-circuit by returning the
/// `EvalResult.err` to the caller. On success returns the produced Value.
const CallOutcome = union(enum) { value: Value, err: EvalResult };

fn invoke(ctx: *CallCtx, callable: *const Value, args: []const Value) Error!CallOutcome {
    const r = try ctx.host.invokeCallable(callable, args, ctx.out);
    return switch (r) {
        .ok => |v| .{ .value = v },
        .err => |e| .{ .err = .{ .err = e } },
    };
}

// =====================================================================
// Natural-order comparison
// =====================================================================

/// Either an ordering or a short-circuit error EvalResult.
const CompareOutcome = union(enum) { order: Order, err: EvalResult };

/// Kotlin's `Double`/`Float` total order (`java.lang.Double.compare`):
/// every `NaN` is greater than all other values, all `NaN`s equal, and
/// `-0.0 < 0.0`.
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

/// Compare two values by Kotlin's natural ordering.
fn compareValues(a: Allocator, x: Value, y: Value) Error!CompareOutcome {
    // Nullable ordering (Kotlin `compareValues`): null sorts before any
    // non-null value; two nulls are equal. A nullable selector
    // (`sortedBy { if (...) null else it.length }`) relies on this.
    if (x == .Null or y == .Null) {
        if (x == .Null and y == .Null) return .{ .order = .eq };
        return .{ .order = if (x == .Null) .lt else .gt };
    }
    if (x.isNumeric() and y.isNumeric()) {
        if (x.isIntegral() and y.isIntegral()) {
            // Unsigned operands compare by magnitude; reading them as i64 would
            // wrap (UInt.MAX -> -1) and misorder the sort.
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

fn reverseOrder(o: Order) Order {
    return switch (o) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

fn i32ToOrdering(n: i32) Order {
    return std.math.order(n, 0);
}

/// Stable natural-order sort over a slice. Returns a short-circuit
/// EvalResult when two elements are incomparable.
fn sortValuesNatural(a: Allocator, items: []Value) Error!?EvalResult {
    return sortValuesNaturalDesc(a, items, false);
}

fn sortValuesNaturalDesc(a: Allocator, items: []Value, descending: bool) Error!?EvalResult {
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

/// Replace a `ValueList`'s backing storage with a fresh slice's contents.
fn writeBackItems(items: ValueList, a: Allocator, src: []const Value) Error!void {
    const g = items.borrowMut();
    defer g.deinit();
    g.get().clearRetainingCapacity();
    try g.get().appendSlice(a, src);
}

// =====================================================================
// Receiver accessors
// =====================================================================

const ListItemsOutcome = union(enum) { items: ValueList, err: EvalResult };

fn recvListItems(a: Allocator, args: []const Value, what: []const u8) Error!ListItemsOutcome {
    if (args.len > 0 and args[0] == .List) {
        // A live subList view fails fast when its backing changed
        // structurally not through the view.
        if (try sublistComodGuard(a, &args[0])) |e| return .{ .err = e };
        // An array `.asList()` view re-reads its scalar source so later array
        // writes show through before any read of `items`.
        args[0].refreshArrayView();
        args[0].refreshSublistView();
        return .{ .items = args[0].List.items };
    }
    return .{ .err = typeErr(try fmt(a, "{s} requires a List receiver", .{what})) };
}

fn recvSetItems(a: Allocator, args: []const Value, what: []const u8) Error!ListItemsOutcome {
    if (args.len > 0 and args[0] == .Set) return .{ .items = args[0].Set.items };
    return .{ .err = typeErr(try fmt(a, "{s} requires a Set receiver", .{what})) };
}

const MapEntriesOutcome = union(enum) { entries: MapEntries, err: EvalResult };

fn recvMapEntries(a: Allocator, args: []const Value, what: []const u8) Error!MapEntriesOutcome {
    if (args.len > 0 and args[0] == .Map) return .{ .entries = args[0].Map.entries };
    return .{ .err = typeErr(try fmt(a, "{s} requires a Map receiver", .{what})) };
}

// =====================================================================
// Range iteration (local copy of ranges helpers; ranges.zig is not imported here)
// =====================================================================

/// Inclusive integer progression iterator state.
const RangeIter = struct {
    cur: i64,
    end: i64,
    step: i64,
    kind: RangeKind,
    done: bool,

    fn init(start: i64, end: i64, step: i64, kind: RangeKind) RangeIter {
        const empty = step == 0 or !kind.inBounds(start, end, step);
        return .{ .cur = start, .end = end, .step = step, .kind = kind, .done = empty };
    }

    fn next(self: *RangeIter) ?i64 {
        if (self.done) return null;
        // `inBounds` compares unsigned for ULong (`MaxUL..MinUL` is empty).
        if (!self.kind.inBounds(self.cur, self.end, self.step)) {
            self.done = true;
            return null;
        }
        const v = self.cur;
        // `end` is the exact final element; stop once yielded so the cursor
        // never advances past it (Long.MAX overflow, or a ULong wrap past MaxUL).
        if (self.cur == self.end) {
            self.done = true;
            return v;
        }
        const adv = self.cur +| self.step;
        if (adv == self.cur) self.done = true else self.cur = adv;
        return v;
    }
};

/// `range_endpoint(kind, v)` — narrow/reinterpret an i64 endpoint.
fn rangeEndpoint(kind: RangeKind, v: i64) Value {
    return switch (kind) {
        .Long => .{ .Long = v },
        .Int => .{ .Int = @truncate(v) },
        .Char => .{ .Char = @truncate(@as(u64, @bitCast(v))) },
        .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(v))) },
        .ULong => .{ .ULong = @bitCast(v) },
    };
}

/// `as_range_view(v)` — view a Range value or a `kotlin.ranges.*` Instance.
const RangeView = struct { start: i64, end: i64, step: i64, kind: RangeKind };

fn asRangeView(v: Value) ?RangeView {
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
            const kind: RangeKind = if (std.mem.indexOf(u8, fqn, "Long") != null)
                .Long
            else if (std.mem.indexOf(u8, fqn, "Char") != null)
                .Char
            else if (std.mem.indexOf(u8, fqn, "Int") != null)
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

// =====================================================================
// iterable_items: collect an iterable receiver into a fresh []Value
// =====================================================================

/// Either a collected slice of items or a short-circuit error EvalResult.
pub const ItemsOutcome = union(enum) { items: []Value, err: EvalResult };

/// Collect a List/Set/Array/Map/Range receiver into a freshly allocated
/// slice. Map yields `MapEntry` values. Returns an error EvalResult when
/// the receiver is not iterable.
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
                out[i] = .{ .MapEntry = .{
                    .key = try Value.boxRef(a, kv.key),
                    .value = try Value.boxRef(a, kv.value),
                    .backing = null,
                } };
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

/// As `iterableItems`, but also materialises a (possibly lazy) `Sequence`
/// argument, which needs the host to run its pipeline. Use this wherever a
/// bulk op accepts a `Sequence` operand (`list + aSequence`, `list - aSequence`).
pub fn iterableItemsCtx(ctx: *CallCtx, v: Value, what: []const u8) Error!ItemsOutcome {
    if (v == .Sequence) {
        return switch (try materialiseSequence(ctx.allocator, ctx.host, ctx.out, v)) {
            .items => |x| .{ .items = x },
            .err => |e| .{ .err = .{ .err = e } },
        };
    }
    // A user/anonymous `Iterable` (e.g. the object `CharSequence.asIterable()`
    // returns) has no built-in backing; drain it through its `iterator()`.
    if (v == .Instance) {
        if (try drainViaIterator(ctx, v)) |r| return r;
    }
    return iterableItems(ctx.allocator, v, what);
}

/// Drain any value that exposes `iterator()` / `hasNext()` / `next()` into a
/// flat element slice. Returns null when the value has no `iterator()` (so the
/// caller can fall back to the built-in extractor or a type error).
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

// =====================================================================
// random / randomOrNull / shuffled
// =====================================================================

var random_state: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x2545F4914F6CDD1D);

const IndexOutcome = union(enum) { idx: usize, err: RuntimeError };

/// A uniform index in `[0, n)`. When a `Random` argument was supplied (the
/// `random(Random)` / `shuffled(Random)` overloads, where it sits at
/// `args[1]`), draw from it through the host so a seeded source stays
/// deterministic; otherwise use the process RNG.
fn pickIndex(ctx: *CallCtx, n: usize) Error!IndexOutcome {
    if (n <= 1) return .{ .idx = 0 };
    if (ctx.args.len > 1 and ctx.args[1] == .Instance) {
        const arg = ctx.args[1];
        if (try ctx.host.invokeMethod(&arg, "nextInt", &.{Value.newInt(@intCast(n))}, ctx.out)) |res| {
            switch (res) {
                .ok => |v| if (v.asI64()) |iv| {
                    const m = @mod(iv, @as(i64, @intCast(n)));
                    return .{ .idx = @intCast(m) };
                },
                .err => |e| return .{ .err = e },
            }
        }
    }
    return .{ .idx = random_state.random().uintLessThan(usize, n) };
}

pub fn coll_random(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("random requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "random")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) return try thrown(a, "kotlin.NoSuchElementException", "Collection is empty.");
    const idx = switch (try pickIndex(ctx, items.len)) {
        .idx => |i| i,
        .err => |e| return .{ .err = e },
    };
    const v = items[idx];
    if (runtime.reclaimEnabled()) v.retain();
    return ok(v);
}

pub fn coll_random_or_null(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("randomOrNull requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "randomOrNull")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) return ok(.Null);
    const idx = switch (try pickIndex(ctx, items.len)) {
        .idx => |i| i,
        .err => |e| return .{ .err = e },
    };
    const v = items[idx];
    if (runtime.reclaimEnabled()) v.retain();
    return ok(v);
}

/// Fisher-Yates shuffle of `slice` in place, drawing indices via `pickIndex`.
fn shuffleInPlace(ctx: *CallCtx, slice: []Value) Error!?RuntimeError {
    var i: usize = slice.len;
    while (i > 1) {
        i -= 1;
        const j = switch (try pickIndex(ctx, i + 1)) {
            .idx => |x| x,
            .err => |e| return e,
        };
        const tmp = slice[i];
        slice[i] = slice[j];
        slice[j] = tmp;
    }
    return null;
}

pub fn coll_shuffled(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("shuffled requires a receiver");
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "shuffled")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (try shuffleInPlace(ctx, items)) |e| return .{ .err = e };
    return ok(try makeList(a, items, false));
}

/// `Array.shuffle()` (and the primitive/unsigned array variants) —
/// Fisher-Yates in place, optionally seeded by a `Random` argument.
pub fn array_shuffle(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("shuffle requires an array receiver");
    const arr = ctx.args[0].Array;
    const buf = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(buf);
    if (try shuffleInPlace(ctx, buf)) |e| return .{ .err = e };
    try arr.writeBack(a, buf);
    return ok(Value.Unit);
}

/// `MutableList.shuffle()` — shuffle in place.
pub fn coll_mut_list_shuffle(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.shuffle")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const g = it.borrowMut();
    defer g.deinit();
    if (try shuffleInPlace(ctx, g.get().items)) |e| return .{ .err = e };
    return ok(.Unit);
}

// =====================================================================
// Iterable transforms (filterNotNull, sumOf, max/min of, distinctBy,
// groupBy, groupingBy + terminals, associate*, sorted*, onEach, mapNotNull)
// =====================================================================

pub fn coll_iter_filter_not_null(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const items = switch (try iterableItems(a, ctx.args[0], "filterNotNull")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    var result: std.ArrayList(Value) = .empty;
    for (items) |v| {
        if (v != .Null) try result.append(a, v);
    }
    return ok(try makeListBorrowed(a, result, false));
}

/// Accumulator kind of a `sumOf` fold — mirrors the Kotlin overload set
/// (Int, Long, UInt, ULong, Double). The sum keeps the selector's kind:
/// Int wraps at 32 bits, UInt sums stay UInt, an empty receiver yields
/// the zero of the selector's declared return type.
const SumKind = enum { int, long, uint, ulong, double };

fn sumKindFromTyName(name: []const u8) ?SumKind {
    const simple = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| name[i + 1 ..] else name;
    if (std.mem.eql(u8, simple, "Int")) return .int;
    if (std.mem.eql(u8, simple, "Long")) return .long;
    if (std.mem.eql(u8, simple, "UInt")) return .uint;
    if (std.mem.eql(u8, simple, "ULong")) return .ulong;
    if (std.mem.eql(u8, simple, "Double")) return .double;
    return null;
}

fn sumKindOfValue(v: Value) ?SumKind {
    return switch (v) {
        .Int, .Short, .Byte => .int,
        .Long => .long,
        .UInt, .UShort, .UByte => .uint,
        .ULong => .ulong,
        .Double, .Float => .double,
        else => null,
    };
}

pub fn coll_iter_sum_of(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("sumOf expects (receiver, block)");
    const items = switch (try iterableItems(a, ctx.args[0], "sumOf")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var kind: ?SumKind = if (ctx.host.callableReturnTy(&block)) |n| sumKindFromTyName(n) else null;
    var ai: i32 = 0;
    var al: i64 = 0;
    var au: u32 = 0;
    var aul: u64 = 0;
    var ad: f64 = 0;
    for (items) |v| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        const rk = sumKindOfValue(r) orelse {
            const rd = try display(a, r);
            return typeErr(try fmt(a, "sumOf selector must return a numeric value, got {s}", .{rd}));
        };
        if (kind == null) kind = rk;
        // A wider result kind in the same family widens the running sum.
        switch (kind.?) {
            .int => switch (rk) {
                .long => {
                    al = ai;
                    kind = .long;
                },
                .double => {
                    ad = @floatFromInt(ai);
                    kind = .double;
                },
                else => {},
            },
            .uint => switch (rk) {
                .ulong => {
                    aul = au;
                    kind = .ulong;
                },
                .double => {
                    ad = @floatFromInt(au);
                    kind = .double;
                },
                else => {},
            },
            .long => if (rk == .double) {
                ad = @floatFromInt(al);
                kind = .double;
            },
            .ulong => if (rk == .double) {
                ad = @floatFromInt(aul);
                kind = .double;
            },
            .double => {},
        }
        switch (kind.?) {
            .int => ai +%= @as(i32, @truncate(r.asI64() orelse 0)),
            .long => al +%= r.asI64() orelse 0,
            .uint => au +%= @as(u32, @truncate(r.asU64() orelse 0)),
            .ulong => aul +%= r.asU64() orelse 0,
            .double => ad += r.asF64() orelse 0,
        }
    }
    return switch (kind orelse .int) {
        .int => ok(.{ .Int = ai }),
        .long => ok(.{ .Long = al }),
        .uint => ok(.{ .UInt = au }),
        .ulong => ok(.{ .ULong = aul }),
        .double => ok(.{ .Double = ad }),
    };
}

fn iterMaxMinOfOrNull(ctx: *CallCtx, want_max: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr(try fmt(a, "{s} expects (receiver, block)", .{what}));
    const items = switch (try iterableItems(a, ctx.args[0], what)) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var best: ?Value = null;
    for (items) |v| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        if (best) |b| {
            // A Double/Float selector uses Math.min/Math.max semantics (NaN
            // propagates, -0.0 < 0.0), NOT the generic Comparable total order.
            if (r == .Double and b == .Double) {
                const m = if (want_max) kotlinFloatMax(r.Double, b.Double) else kotlinFloatMin(r.Double, b.Double);
                best = .{ .Double = m };
            } else if (r == .Float and b == .Float) {
                const m = if (want_max)
                    kotlinFloatMax(@floatCast(r.Float), @floatCast(b.Float))
                else
                    kotlinFloatMin(@floatCast(r.Float), @floatCast(b.Float));
                best = .{ .Float = @floatCast(m) };
            } else {
                const o = switch (try compareValues(a, r, b)) {
                    .order => |o| o,
                    .err => |e| return e,
                };
                const take = if (want_max) o == .gt else o == .lt;
                if (take) best = r;
            }
        } else {
            best = r;
        }
    }
    return ok(best orelse Value.Null);
}

pub fn coll_iter_max_of_or_null(ctx: *CallCtx) Error!EvalResult {
    return iterMaxMinOfOrNull(ctx, true, "maxOfOrNull");
}

pub fn coll_iter_min_of_or_null(ctx: *CallCtx) Error!EvalResult {
    return iterMaxMinOfOrNull(ctx, false, "minOfOrNull");
}

pub fn coll_iter_distinct_by(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("distinctBy expects (receiver, block)");
    const items = switch (try iterableItems(a, ctx.args[0], "distinctBy")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var keys: std.ArrayList(Value) = .empty;
    var result: std.ArrayList(Value) = .empty;
    for (items) |v| {
        const key = switch (try invoke(ctx, &block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        if (!containsBoxed(keys.items, &key)) {
            try keys.append(a, key);
            try result.append(a, v);
        }
    }
    return ok(try makeListBorrowed(a, result, false));
}

pub fn coll_iter_group_by(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    // `groupBy(keySelector)` or `groupBy(keySelector, valueTransform)`.
    if (ctx.args.len != 2 and ctx.args.len != 3) return arityErr("groupBy expects (receiver, keySelector[, valueTransform])");
    const items = switch (try iterableItems(a, ctx.args[0], "groupBy")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const key_block = ctx.args[1];
    const has_value_transform = ctx.args.len == 3;
    const Group = struct { key: Value, vs: std.ArrayList(Value) };
    var groups: std.ArrayList(Group) = .empty;
    for (items) |v| {
        const key = switch (try invoke(ctx, &key_block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        var value = v;
        if (has_value_transform) {
            const value_block = ctx.args[2];
            value = switch (try invoke(ctx, &value_block, &.{v})) {
                .value => |val| val,
                .err => |e| return e,
            };
        }
        var found = false;
        for (groups.items) |*g| {
            if (eqBoxed(&g.key, &key)) {
                try g.vs.append(a, value);
                found = true;
                break;
            }
        }
        if (!found) {
            var vs: std.ArrayList(Value) = .empty;
            try vs.append(a, value);
            try groups.append(a, .{ .key = key, .vs = vs });
        }
    }
    // The `groups` spine is scratch — each `vs` is adopted by `makeListBorrowed`
    // and each `key` moves into `entries`, but the `Group` array itself is freed.
    defer if (runtime.freeScratch()) groups.deinit(a);
    var entries: std.ArrayList(MapPair) = .empty;
    for (groups.items) |g| {
        try entries.append(a, .{ .key = g.key, .value = try makeListBorrowed(a, g.vs, false) });
    }
    return ok(try makeMapFromArrayList(a, entries, false));
}

pub fn coll_iter_grouping_by(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("groupingBy expects (receiver, keySelector)");
    // `iterableItemsCtx` drains a Sequence / CharSequence / user Iterable too,
    // so Array/Sequence/CharSequence.groupingBy share this synth shape.
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], "groupingBy")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    const id = ctx.host.allocInstanceId();
    const src = try makeList(a, items, false);
    const fields = [_]InstanceData.Field{
        .{ .name = "__grouping_src", .value = src },
        .{ .name = "__grouping_key", .value = block },
    };
    return ok(try ctx.host.newSynthInstance("kotlin.collections.Grouping", id, &fields));
}

/// `Grouping.sourceIterator()` — the iterator over the captured source, used
/// by the upstream `foldTo`/`reduceTo`/`eachCountTo`/`aggregate` terminals.
pub fn coll_grouping_source_iterator(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Instance) return typeErr("sourceIterator expects a Grouping receiver");
    const src: Value = blk: {
        const g = ctx.args[0].Instance.borrow();
        defer g.deinit();
        break :blk (g.get().get("__grouping_src") orelse return typeErr("not a Grouping"));
    };
    return (try ctx.host.invokeMethod(&src, "iterator", &.{}, ctx.out)) orelse
        typeErr("Grouping source is not iterable");
}

/// `Grouping.keyOf(element)` — applies the captured key selector.
pub fn coll_grouping_key_of(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[0] != .Instance) return arityErr("keyOf expects (Grouping, element)");
    const key: Value = blk: {
        const g = ctx.args[0].Instance.borrow();
        defer g.deinit();
        break :blk (g.get().get("__grouping_key") orelse return typeErr("not a Grouping"));
    };
    return switch (try invoke(ctx, &key, &.{ctx.args[1]})) {
        .value => |v| ok(v),
        .err => |e| e,
    };
}

const GroupingParts = union(enum) { parts: struct { items: []Value, key: Value }, err: EvalResult };

fn groupingParts(a: Allocator, v: Value) Error!GroupingParts {
    if (v == .Instance) {
        const g = v.Instance.borrow();
        defer g.deinit();
        const inst = g.get();
        if (inst.get("__grouping_src")) |src| {
            if (src == .List) {
                if (inst.get("__grouping_key")) |key| {
                    // Escapes to the caller via `parts.items`; freed there.
                    const items = try snapshotItems(a, src.List.items);
                    return .{ .parts = .{ .items = items, .key = key } };
                }
            }
        }
    }
    return .{ .err = typeErr("expected a Grouping receiver") };
}

pub fn coll_grouping_each_count(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const gp = switch (try groupingParts(a, ctx.args[0])) {
        .parts => |p| p,
        .err => |e| return e,
    };
    const Count = struct { key: Value, n: i64 };
    var counts: std.ArrayList(Count) = .empty;
    for (gp.items) |v| {
        const k = switch (try invoke(ctx, &gp.key, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        var found = false;
        for (counts.items) |*c| {
            if (eqBoxed(&c.key, &k)) {
                c.n += 1;
                found = true;
                break;
            }
        }
        if (!found) try counts.append(a, .{ .key = k, .n = 1 });
    }
    var entries: std.ArrayList(MapPair) = .empty;
    for (counts.items) |c| {
        try entries.append(a, .{ .key = c.key, .value = Value.newInt(c.n) });
    }
    return ok(try makeMapFromArrayList(a, entries, false));
}

pub fn coll_grouping_fold(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const gp = switch (try groupingParts(a, ctx.args[0])) {
        .parts => |p| p,
        .err => |e| return e,
    };
    const initial = if (ctx.args.len > 1) ctx.args[1] else Value.Null;
    if (ctx.args.len <= 2) return arityErr("fold expects (initial, operation)");
    const op = ctx.args[2];
    var acc: std.ArrayList(MapPair) = .empty;
    for (gp.items) |v| {
        const k = switch (try invoke(ctx, &gp.key, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        const pos = try findKeyIndexBoxedH(ctx.host, ctx.out, acc.items, &k);
        const cur = if (pos) |p| acc.items[p].value else blk: {
            if (isCallable(initial)) {
                break :blk switch (try invoke(ctx, &initial, &.{ k, v })) {
                    .value => |val| val,
                    .err => |e| return e,
                };
            } else break :blk initial;
        };
        // The computed-initial overload's operation is keyed:
        // `fold(initialValueSelector: (K, T) -> R, operation: (K, R, T) -> R)`.
        const next = switch (if (isCallable(initial))
            try invoke(ctx, &op, &.{ k, cur, v })
        else
            try invoke(ctx, &op, &.{ cur, v })) {
            .value => |val| val,
            .err => |e| return e,
        };
        if (pos) |p| {
            acc.items[p].value = next;
        } else {
            try acc.append(a, .{ .key = k, .value = next });
        }
    }
    return ok(try makeMapFromArrayList(a, acc, false));
}

pub fn coll_grouping_reduce(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const gp = switch (try groupingParts(a, ctx.args[0])) {
        .parts => |p| p,
        .err => |e| return e,
    };
    if (ctx.args.len <= 1) return arityErr("reduce expects (operation)");
    const op = ctx.args[1];
    var acc: std.ArrayList(MapPair) = .empty;
    for (gp.items) |v| {
        const k = switch (try invoke(ctx, &gp.key, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        if (try findKeyIndexBoxedH(ctx.host, ctx.out, acc.items, &k)) |p| {
            const cur = acc.items[p].value;
            const next = switch (try invoke(ctx, &op, &.{ k, cur, v })) {
                .value => |val| val,
                .err => |e| return e,
            };
            // The reduced result is owned (invoke); drop the displaced value.
            if (runtime.reclaimEnabled()) cur.release(a);
            acc.items[p].value = next;
        } else {
            // k is owned (invoke); v is a borrowed source element, so retain it.
            if (runtime.reclaimEnabled()) v.retain();
            try acc.append(a, .{ .key = k, .value = v });
        }
    }
    return ok(try makeMapFromArrayList(a, acc, false));
}

pub fn coll_iter_associate(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("associate expects (receiver, block)");
    const items = switch (try iterableItems(a, ctx.args[0], "associate")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var entries: std.ArrayList(MapPair) = .empty;
    for (items) |v| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        if (r != .Pair) {
            if (runtime.reclaimEnabled()) r.release(a);
            return typeErr("associate selector must return Pair");
        }
        const key = r.Pair.first.asPtr().*;
        const val = r.Pair.second.asPtr().*;
        // key/val are borrowed reads of the owned Pair `r`'s boxes; the map owns
        // its own ref to each, so retain before storing, then release `r`.
        if (runtime.reclaimEnabled()) {
            key.retain();
            val.retain();
        }
        if (try findKeyIndexBoxedH(ctx.host, ctx.out, entries.items, &key)) |i| {
            if (runtime.reclaimEnabled()) {
                entries.items[i].value.release(a);
                key.release(a); // existing key kept; drop the duplicate's retain
            }
            entries.items[i].value = val;
        } else {
            try entries.append(a, .{ .key = key, .value = val });
        }
        if (runtime.reclaimEnabled()) r.release(a);
    }
    return ok(try makeMapFromArrayList(a, entries, false));
}

pub fn coll_iter_associate_by(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    // `associateBy(keySelector)` or `associateBy(keySelector, valueTransform)`.
    if (ctx.args.len != 2 and ctx.args.len != 3) return arityErr("associateBy expects (receiver, keySelector[, valueTransform])");
    const items = switch (try iterableItems(a, ctx.args[0], "associateBy")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const key_block = ctx.args[1];
    const has_value_transform = ctx.args.len == 3;
    var entries: std.ArrayList(MapPair) = .empty;
    for (items) |v| {
        const key = switch (try invoke(ctx, &key_block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
        // The value is `valueTransform(v)` (owned) or the element itself
        // (borrowed — the map takes its own ref). key is owned either way.
        var value = v;
        var value_owned = false;
        if (has_value_transform) {
            const value_block = ctx.args[2];
            value = switch (try invoke(ctx, &value_block, &.{v})) {
                .value => |val| val,
                .err => |e| return e,
            };
            value_owned = true;
        }
        if (try findKeyIndexBoxedH(ctx.host, ctx.out, entries.items, &key)) |i| {
            if (runtime.reclaimEnabled()) {
                entries.items[i].value.release(a);
                if (!value_owned) value.retain();
            }
            entries.items[i].value = value;
        } else {
            if (runtime.reclaimEnabled() and !value_owned) value.retain();
            try entries.append(a, .{ .key = key, .value = value });
        }
    }
    return ok(try makeMapFromArrayList(a, entries, false));
}

pub fn coll_iter_associate_with(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("associateWith expects (receiver, block)");
    const items = switch (try iterableItems(a, ctx.args[0], "associateWith")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var entries: std.ArrayList(MapPair) = .empty;
    for (items) |v| {
        const val = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        // val is owned (invoke result); v is a borrowed receiver element used as
        // the key, so the map owns its own ref to it.
        if (try findKeyIndexBoxedH(ctx.host, ctx.out, entries.items, &v)) |i| {
            if (runtime.reclaimEnabled()) entries.items[i].value.release(a);
            entries.items[i].value = val;
        } else {
            if (runtime.reclaimEnabled()) v.retain();
            try entries.append(a, .{ .key = v, .value = val });
        }
    }
    return ok(try makeMapFromArrayList(a, entries, false));
}

/// Insertion sort over a slice using a host-driven key comparison. The
/// callback maps each element to a key, then keys compare by natural
/// order (optionally reversed). On error short-circuits with the
/// EvalResult.
fn sortByKeyInsertion(ctx: *CallCtx, items: []Value, block: Value, descending: bool) Error!?EvalResult {
    const a = ctx.allocator;
    // Precompute keys.
    const keys = try a.alloc(Value, items.len);
    for (items, 0..) |v, i| {
        keys[i] = switch (try invoke(ctx, &block, &.{v})) {
            .value => |val| val,
            .err => |e| return e,
        };
    }
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const o = switch (try compareValues(a, keys[j - 1], keys[j])) {
                .order => |o| o,
                .err => |e| return e,
            };
            const flipped = if (descending) reverseOrder(o) else o;
            if (flipped == .gt) {
                std.mem.swap(Value, &items[j - 1], &items[j]);
                std.mem.swap(Value, &keys[j - 1], &keys[j]);
                j -= 1;
            } else break;
        }
    }
    return null;
}

fn iterSortedByImpl(ctx: *CallCtx, descending: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr(try fmt(a, "{s} expects (receiver, block)", .{what}));
    const items = switch (try iterableItems(a, ctx.args[0], what)) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    if (try sortByKeyInsertion(ctx, items, block, descending)) |e| return e;
    return ok(try makeList(a, items, false));
}

pub fn coll_iter_sorted_by(ctx: *CallCtx) Error!EvalResult {
    return iterSortedByImpl(ctx, false, "sortedBy");
}

pub fn coll_iter_sorted_by_desc(ctx: *CallCtx) Error!EvalResult {
    return iterSortedByImpl(ctx, true, "sortedByDescending");
}

fn iterMaxMinByImpl(ctx: *CallCtx, descending: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr(try fmt(a, "{s} expects (receiver, block)", .{what}));
    const items = switch (try iterableItems(a, ctx.args[0], what)) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) return ok(Value.Null);
    const block = ctx.args[1];
    var best_key = switch (try invoke(ctx, &block, &.{items[0]})) {
        .value => |v| v,
        .err => |e| return e,
    };
    var best = items[0];
    for (items[1..]) |v| {
        const key = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        const o = switch (try compareValues(a, key, best_key)) {
            .order => |o| o,
            .err => |e| return e,
        };
        const take = if (descending) o == .lt else o == .gt;
        if (take) {
            best_key = key;
            best = v;
        }
    }
    return ok(best);
}

pub fn coll_iter_max_by_or_null(ctx: *CallCtx) Error!EvalResult {
    return iterMaxMinByImpl(ctx, false, "maxByOrNull");
}

pub fn coll_iter_min_by_or_null(ctx: *CallCtx) Error!EvalResult {
    return iterMaxMinByImpl(ctx, true, "minByOrNull");
}

/// Dispatch `comparator.compare(a, b)` for a non-intrinsic Comparator
/// value (interpreted object / SAM / bare callable). Returns the i64
/// result or a short-circuit EvalResult.
const CmpResult = union(enum) { n: i64, err: EvalResult };

fn invokeComparatorCompare(ctx: *CallCtx, comparator: Value, x: Value, y: Value) Error!CmpResult {
    const args = [_]Value{ x, y };
    const r = if (try ctx.host.invokeMethod(&comparator, "compare", &args, ctx.out)) |m|
        m
    else
        try ctx.host.invokeCallable(&comparator, &args, ctx.out);
    return switch (r) {
        .ok => |v| if (v.asI64()) |n| .{ .n = n } else .{ .err = typeErr("Comparator.compare must return Int") },
        .err => |e| .{ .err = .{ .err = e } },
    };
}

pub fn coll_mut_list_sort(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.sort")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const copy = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(copy);
    // Host-aware so a list of user `Comparable` instances sorts through their
    // `compareTo` (sortValuesNatural only handles builtin scalars).
    if (try sortListHostAware(ctx, copy)) |e| return e;
    writeBackItems(it, a, copy) catch return error.OutOfMemory;
    return ok(Value.Unit);
}

/// Stable bottom-up merge sort driven by a Kotlin `Comparator` value: O(n log n)
/// comparator callbacks. An insertion sort is O(n²) and times out on large lists.
pub fn mergeSortComparator(ctx: *CallCtx, cmp: Value, items: []Value) Error!?EvalResult {
    const a = ctx.allocator;
    const n = items.len;
    if (n < 2) return null;
    const buf = try a.alloc(Value, n);
    defer if (runtime.freeScratch()) a.free(buf);
    var width: usize = 1;
    while (width < n) : (width *= 2) {
        var lo: usize = 0;
        while (lo < n) : (lo += 2 * width) {
            const mid = @min(lo + width, n);
            const hi = @min(lo + 2 * width, n);
            var i = lo;
            var j = mid;
            var k = lo;
            while (i < mid and j < hi) {
                const c = switch (try invokeComparatorCompare(ctx, cmp, items[i], items[j])) {
                    .n => |v| v,
                    .err => |e| return e,
                };
                // Take the left run on a tie so the sort stays stable.
                if (c <= 0) {
                    buf[k] = items[i];
                    i += 1;
                } else {
                    buf[k] = items[j];
                    j += 1;
                }
                k += 1;
            }
            while (i < mid) : ({
                i += 1;
                k += 1;
            }) buf[k] = items[i];
            while (j < hi) : ({
                j += 1;
                k += 1;
            }) buf[k] = items[j];
        }
        @memcpy(items[0..n], buf[0..n]);
    }
    return null;
}

pub fn coll_mut_list_sort_with(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.sortWith")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len <= 1) return arityErr("sortWith expects (comparator)");
    const cmp = ctx.args[1];
    const copy = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(copy);
    if (try mergeSortComparator(ctx, cmp, copy)) |e| return e;
    writeBackItems(it, a, copy) catch return error.OutOfMemory;
    return ok(Value.Unit);
}

pub fn coll_mut_list_fill(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.fill")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len <= 1) return arityErr("fill expects (value)");
    const value = ctx.args[1];
    const g = it.borrowMut();
    defer g.deinit();
    for (g.get().items) |*slot| slot.* = value;
    return ok(Value.Unit);
}

pub fn coll_mut_list_reverse(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.reverse")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const g = it.borrowMut();
    defer g.deinit();
    std.mem.reverse(Value, g.get().items);
    return ok(Value.Unit);
}

pub fn coll_iter_sorted_with(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("sortedWith expects (receiver, comparator)");
    const items = switch (try iterableItems(a, ctx.args[0], "sortedWith")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    const comparator = ctx.args[1];
    // An empty-steps natural Comparator sorts builtin scalars directly.
    if (comparator == .Comparator) {
        const descending = comparator.Comparator.descending;
        const empty = blk: {
            const steps_g = comparator.Comparator.steps.borrow();
            defer steps_g.deinit();
            break :blk steps_g.get().len == 0;
        };
        if (empty) {
            if (try sortListHostAwareDesc(ctx, items, descending)) |e| return e;
            return ok(try makeList(a, items, false));
        }
    }
    // Everything else (a `compare(a,b)` object or a multi-step Comparator, whose
    // `compare` the host evaluates) goes through the stable merge sort.
    if (try mergeSortComparator(ctx, comparator, items)) |e| return e;
    return ok(try makeList(a, items, false));
}

fn iterExtreme(ctx: *CallCtx, want_max: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr(try fmt(a, "{s} expects (receiver, block)", .{what}));
    const items = switch (try iterableItems(a, ctx.args[0], what)) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var best: ?Value = null;
    for (items) |v| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        if (best) |b| {
            const o = switch (try compareValues(a, b, r)) {
                .order => |o| o,
                .err => |e| return e,
            };
            const replace = (want_max and o == .lt) or (!want_max and o == .gt);
            best = if (replace) r else b;
        } else best = r;
    }
    if (best) |b| return ok(b);
    return try thrown(a, "kotlin.NoSuchElementException", "Collection is empty.");
}

pub fn coll_iter_max_of(ctx: *CallCtx) Error!EvalResult {
    return iterExtreme(ctx, true, "maxOf");
}

pub fn coll_iter_min_of(ctx: *CallCtx) Error!EvalResult {
    return iterExtreme(ctx, false, "minOf");
}

pub fn coll_iter_on_each(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("onEach expects (receiver, block)");
    const recv = ctx.args[0];
    const items = switch (try iterableItems(a, recv, "onEach")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    for (items) |v| {
        switch (try invoke(ctx, &block, &.{v})) {
            .value => {},
            .err => |e| return e,
        }
    }
    return ok(recv);
}

pub fn coll_iter_map_not_null(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 2) return arityErr("mapNotNull expects (receiver, block)");
    const items = switch (try iterableItems(a, ctx.args[0], "mapNotNull")) {
        .items => |xs| xs,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const block = ctx.args[1];
    var result: std.ArrayList(Value) = .empty;
    for (items) |v| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        if (r != .Null) try result.append(a, r);
    }
    return ok(try makeListFromArrayList(a, result, false));
}

// =====================================================================
// Map scope helpers
// =====================================================================

pub fn map_get_or_else(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 3) return arityErr("getOrElse expects (receiver, key, block)");
    if (ctx.args[0] != .Map) return typeErr("getOrElse requires a Map receiver");
    const key = ctx.args[1];
    {
        const g = ctx.args[0].Map.entries.borrowMut();
        defer g.deinit();
        // `getOrElse` is `get(key) ?: defaultValue()`: a present-but-null value
        // falls through to the default just like an absent key.
        if (try g.get().find(a, &key)) |i| {
            const v = g.get().pairs.items[i].value;
            if (v != .Null) return okElem(v);
        }
    }
    const block = ctx.args[2];
    return try ctx.host.invokeCallable(&block, &.{}, ctx.out);
}

pub fn map_get_or_put(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len != 3) return arityErr("getOrPut expects (receiver, key, block)");
    if (ctx.args[0] != .Map) return typeErr("getOrPut requires a MutableMap receiver");
    const entries_rc = ctx.args[0].Map.entries;
    const key = ctx.args[1];
    {
        const g = entries_rc.borrowMut();
        defer g.deinit();
        // `getOrPut` returns the stored value only when it is non-null; a
        // present-but-null value is recomputed and stored (Kotlin's `value
        // == null` branch).
        if (try g.get().find(a, &key)) |i| {
            const v = g.get().pairs.items[i].value;
            if (v != .Null) return okElem(v);
        }
    }
    const block = ctx.args[2];
    const new_v = switch (try invoke(ctx, &block, &.{})) {
        .value => |v| v,
        .err => |e| return e,
    };
    {
        const g = entries_rc.borrowMut();
        defer g.deinit();
        // The map takes ownership of one ref to the stored value; the block's
        // `new_v` is also returned, so retain it for the map and hand back the
        // block's owned ref untouched.
        if (runtime.reclaimEnabled()) new_v.retain();
        // A present key (its value was null, which is why we got here) is
        // updated in place; a genuinely absent key appends a new entry.
        if (try g.get().find(a, &key)) |i| {
            const old = g.get().pairs.items[i].value;
            g.get().pairs.items[i].value = new_v;
            if (runtime.reclaimEnabled()) old.release(a);
        } else {
            if (runtime.reclaimEnabled()) key.retain();
            try g.get().pairs.append(a, .{ .key = key, .value = new_v });
            try g.get().noteAppended(a, g.get().pairs.items.len - 1);
        }
    }
    return ok(new_v);
}

// =====================================================================
// Array constructors / isEmpty
// =====================================================================

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
    // A negative size is a catchable `NegativeArraySizeException`, not an
    // interpreter `.Type` error (which unwinds past `assertFailsWith`).
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
    // A bare ctor call inside an extension body routes through the member
    // walk, which prepends the implicit receiver — the constructor takes
    // none. Strip a leading array when the REMAINING args form a valid
    // ctor shape ((size), (size, init), or the storage-wrapping array).
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
    // Storage-wrapping unsigned-array constructor: `UIntArray(intArray)` (and
    // the UByte/UShort/ULong siblings, what `asUIntArray()` lowers to) shares
    // the signed array's packed buffer as an unsigned view — mutations through
    // either alias, matching Kotlin's inline value-class storage.
    if (call_args.len == 1 and prim != null and call_args[0] == .Array) {
        const arr = call_args[0].Array;
        if (arr.prim) |src| {
            const is_view = (prim.? == .UByte and src == .Byte) or
                (prim.? == .UShort and src == .Short) or
                (prim.? == .UInt and src == .Int) or
                (prim.? == .ULong and src == .Long) or
                // Same-kind wrap (`UIntArray(uintArray)`) passes through.
                prim.? == src;
            if (is_view) switch (arr.storage) {
                .scalars => |pb| return ok(.{ .Array = .{ .storage = .{ .scalars = pb.clone() }, .prim = prim.? } }),
                // A boxed signed buffer (a `copyOf` that materialized
                // Values) reinterprets element-wise: same bits, unsigned
                // tags, packed storage so indexed reads come back tagged.
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
                    return ok(.{ .Array = .{ .storage = .{ .scalars = try ObjRef(runtime.PrimBuf).initOwned(a, pb) }, .prim = k } });
                },
            };
        }
    }
    const n = switch (try arraySizeArg(a, call_args[0], name)) {
        .n => |v| v,
        .err => |e| return e,
    };

    // Primitive arrays store packed scalars directly — never materialize a boxed
    // `Value` list (a 10M `IntArray` would otherwise transiently allocate ~560MB
    // of 56-byte Values just to convert them away). The zeroed byte buffer is
    // already the Kotlin default for every primitive (0, false, 0.0, NUL char).
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
        return ok(.{ .Array = .{
            .storage = .{ .scalars = try ObjRef(runtime.PrimBuf).initOwned(a, pb) },
            .prim = k,
        } });
    }

    if (call_args.len == 1) {
        var list: std.ArrayList(Value) = .empty;
        var i: i64 = 0;
        while (i < n) : (i += 1) try list.append(a, default);
        return ok(try makeArrayFromArrayList(a, list, null));
    }
    const block = call_args[1];
    var list: std.ArrayList(Value) = .empty;
    // The accumulated results live only in `list` (no frame register holds
    // them) and the per-element `invoke` reaches a GC safe point, so pin the
    // accumulator across each call. Re-push after every append: the append may
    // reallocate `list.items`.
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

// =====================================================================
// Collection builders
// =====================================================================

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

/// `Array<T>.asList()` / `IntArray.asList()` build a read-only, fixed-size List
/// *view*: later array element writes show through. A reference array shares
/// its boxed buffer outright (inherently live); a primitive array carries an
/// `array` backing so each read re-reads the packed scalars.
pub fn arrayAsListView(a: Allocator, arr: runtime.ArrayData) Error!Value {
    switch (arr.storage) {
        .boxed => |vl| return .{ .List = .{
            .items = vl.clone(),
            .mutable = false,
            .enum_entries = false,
            .backing = null,
            .mod_count = null,
        } },
        .scalars => |buf| {
            const view_kind = arr.prim orelse blk: {
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
            return .{ .List = .{
                .items = try ValueList.init(a, snap),
                .mutable = false,
                .enum_entries = false,
                .backing = backing.cell,
                .mod_count = null,
            } };
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

// Shared empty read-only collection singletons: emptyList()/emptySet()/
// emptyMap() and an empty build*/listOf() result all denote one object,
// so `===`/`assertSame` hold across call sites (Kotlin's EmptyList/
// EmptySet/EmptyMap objects). Reset at run boundaries — the cells belong
// to the finished run's allocator.
var empty_singleton_lock: runtime.SpinMutex = .{};
var empty_list_singleton: ?Value = null;
var empty_set_singleton: ?Value = null;
var empty_map_singleton: ?Value = null;
var empty_singleton_root_registered = std.atomic.Value(bool).init(false);

fn gcMarkEmptySingletons(m: *runtime.gc.Marker) void {
    if (empty_list_singleton) |v| m.shade(&v.List.items.cell.hdr);
    if (empty_set_singleton) |v| m.shade(&v.Set.items.cell.hdr);
    if (empty_map_singleton) |v| m.shade(&v.Map.entries.cell.hdr);
}

fn registerEmptySingletonRoot() void {
    if (runtime.gc.gc_enabled and !empty_singleton_root_registered.swap(true, .monotonic))
        runtime.gc.registerRoot(gcMarkEmptySingletons);
}

pub fn sharedEmptyList(a: Allocator) Error!Value {
    // Under refcount reclaim (unit tests, leak-checked allocators) the
    // process cache would register as a leak; identity singletons serve
    // the arena profile, fresh values elsewhere.
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
    // Under refcount reclaim (unit tests, leak-checked allocators) the
    // process cache would register as a leak; identity singletons serve
    // the arena profile, fresh values elsewhere.
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
    // Under refcount reclaim (unit tests, leak-checked allocators) the
    // process cache would register as a leak; identity singletons serve
    // the arena profile, fresh values elsewhere.
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
    // Entries hold borrowed key/value (read from the Pair args the caller owns).
    // Dedupe over the still-borrowed entries, then makeMapBorrowed retains the
    // survivors so the map owns one ref per key+value.
    return ok(try makeMapBorrowed(a, try dedupeMapInPlace(a, entries), mutable));
}

/// Apply make_map dedupe semantics to an already-collected entry list.
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

pub fn coll_map_of(ctx: *CallCtx) Error!EvalResult {
    return mapOfImpl(ctx, false, "mapOf");
}
pub fn coll_mutable_map_of(ctx: *CallCtx) Error!EvalResult {
    return mapOfImpl(ctx, true, "mutableMapOf");
}
pub fn coll_empty_map(ctx: *CallCtx) Error!EvalResult {
    return ok(try sharedEmptyMap(ctx.allocator));
}

/// Drain any iterable `value` into a fresh slice. Native List/Set copy
/// directly; a user class is driven through iterator()/hasNext()/next().
fn materialiseIterableInstance(ctx: *CallCtx, value: Value) Error!ItemsOutcome {
    const a = ctx.allocator;
    switch (value) {
        .List => |l| return .{ .items = try snapshotItems(a, l.items) },
        .Set => |s| return .{ .items = try snapshotItems(a, s.items) },
        else => {},
    }
    const iter = (try ctx.host.invokeMethod(&value, "iterator", &.{}, ctx.out)) orelse
        return .{ .err = typeErr("value is not iterable") };
    const iter_v = switch (iter) {
        .ok => |v| v,
        .err => |e| return .{ .err = .{ .err = e } },
    };
    var items: std.ArrayList(Value) = .empty;
    while (true) {
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
        // `collectionToArray` dispatches through the collection's `toArray()`
        // override before falling back to iteration, so a user override
        // observes the call (AbstractCollection subclasses may cache or
        // instrument it).
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
    else switch (try iterableItems(a, recv, "toTypedArray")) {
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
    if (try sortValuesNatural(a, items)) |e| return e;
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

/// Insertion sort a map's entries by key (natural order, optional reverse).
fn sortMapByKey(a: Allocator, entries: []MapPair, descending: bool) Error!?EvalResult {
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
                    // A negative initial capacity is a catchable
                    // IllegalArgumentException (matching java.util.ArrayList).
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
    // `HashMap(initialCapacity)` / `(initialCapacity, loadFactor)` /
    // `LinkedHashMap(initialCapacity, loadFactor, accessOrder)` — the capacity,
    // load factor, and access-order flag do not change the observable behavior
    // of klio's insertion-ordered map beyond construction.
    if (ctx.args[0] == .Int) {
        // A negative initial capacity, or a non-positive load factor, is a
        // catchable IllegalArgumentException (matching java.util.HashMap).
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
                    // HashSet delegates to a backing HashMap, so a negative
                    // initial capacity is a catchable IllegalArgumentException.
                    if (arg.Int < 0) {
                        const msg = try fmt(a, "Illegal initial capacity: {d}", .{arg.Int});
                        const r = try thrown(a, "kotlin.IllegalArgumentException", msg);
                        if (runtime.freeScratch()) a.free(msg);
                        return r;
                    }
                    return ok(try makeSet(a, &.{}, true));
                },
                .List => |l| return ok(try makeSetVL(a, l.items, true)),
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
            // `HashSet(initialCapacity, loadFactor)` validates both like the
            // backing HashMap: a negative capacity or a non-positive / NaN load
            // factor is a catchable IllegalArgumentException.
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

// =====================================================================
// List / MutableList
// =====================================================================

pub fn coll_list_size(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.size")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(Value.newInt(@intCast(listLen(it))));
}
pub fn coll_list_is_empty(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.isEmpty")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = listLen(it) == 0 });
}
pub fn coll_list_is_not_empty(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.isNotEmpty")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = listLen(it) != 0 });
}
pub fn coll_list_get(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.get")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or ctx.args[1] != .Int) return typeErr("List.get requires an Int index");
    const i = ctx.args[1].Int;
    const g = it.borrow();
    defer g.deinit();
    const items = g.get().items;
    if (i < 0 or @as(usize, @intCast(i)) >= items.len) {
        const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, items.len });
        const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    return okElem(items[@intCast(i)]);
}
pub fn coll_list_contains(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.contains")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("contains requires an argument");
    const needle = ctx.args[1];
    // Snapshot before dispatching a user `equals` (re-entering the VM under the
    // list borrow is unsafe).
    const items = try snapshotItems(ctx.allocator, it);
    defer if (runtime.freeScratch()) ctx.allocator.free(items);
    return ok(.{ .Bool = try containsBoxedH(ctx.host, ctx.out, items, &needle) });
}
pub fn coll_list_index_of(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.indexOf")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("indexOf requires an argument");
    const needle = ctx.args[1];
    const items = try snapshotItems(ctx.allocator, it);
    defer if (runtime.freeScratch()) ctx.allocator.free(items);
    const pos = try indexOfBoxedH(ctx.host, ctx.out, items, &needle);
    return ok(Value.newInt(if (pos) |p| @intCast(p) else -1));
}
pub fn coll_iter_index_of_first(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const items = switch (try iterableItems(a, ctx.args[0], "indexOfFirst")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (ctx.args.len < 2) return arityErr("indexOfFirst requires a block");
    const block = ctx.args[1];
    for (items, 0..) |v, i| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        if (r == .Bool and r.Bool) return ok(Value.newInt(@intCast(i)));
    }
    return ok(Value.newInt(-1));
}
pub fn coll_iter_index_of_last(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const items = switch (try iterableItems(a, ctx.args[0], "indexOfLast")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (ctx.args.len < 2) return arityErr("indexOfLast requires a block");
    const block = ctx.args[1];
    var found: i64 = -1;
    for (items, 0..) |v, i| {
        const r = switch (try invoke(ctx, &block, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        if (r == .Bool and r.Bool) found = @intCast(i);
    }
    return ok(Value.newInt(found));
}
pub fn coll_list_fold_right(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const items = switch (try iterableItems(a, ctx.args[0], "foldRight")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (ctx.args.len < 2) return arityErr("foldRight requires an initial value");
    var acc = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("foldRight requires a block");
    const block = ctx.args[2];
    var i = items.len;
    while (i > 0) {
        i -= 1;
        acc = switch (try invoke(ctx, &block, &.{ items[i], acc })) {
            .value => |x| x,
            .err => |e| return e,
        };
    }
    return ok(acc);
}
fn reduceRightImpl(ctx: *CallCtx, or_null: bool) Error!EvalResult {
    const a = ctx.allocator;
    const items = switch (try iterableItems(a, ctx.args[0], "reduceRight")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (ctx.args.len < 2) return arityErr("reduceRight requires a block");
    const block = ctx.args[1];
    if (items.len == 0) {
        if (or_null) return ok(Value.Null);
        return try thrown(a, "kotlin.UnsupportedOperationException", "Empty collection can't be reduced.");
    }
    var acc = items[items.len - 1];
    var i = items.len - 1;
    while (i > 0) {
        i -= 1;
        acc = switch (try invoke(ctx, &block, &.{ items[i], acc })) {
            .value => |x| x,
            .err => |e| return e,
        };
    }
    return ok(acc);
}
pub fn coll_list_reduce_right(ctx: *CallCtx) Error!EvalResult {
    return reduceRightImpl(ctx, false);
}
pub fn coll_list_reduce_right_or_null(ctx: *CallCtx) Error!EvalResult {
    return reduceRightImpl(ctx, true);
}
fn listLastImpl(ctx: *CallCtx, or_null: bool) Error!EvalResult {
    const a = ctx.allocator;
    // Fast path: no predicate on a List/Array — index the last element directly
    // instead of snapshotting the whole collection (which made `last()` O(n)).
    if (ctx.args.len < 2) {
        switch (ctx.args[0]) {
            .List => |l| {
                const g = l.items.borrow();
                defer g.deinit();
                const items = g.get().items;
                if (items.len > 0) return okElem(items[items.len - 1]);
                if (or_null) return ok(Value.Null);
                return try thrown(a, "kotlin.NoSuchElementException", "Collection is empty.");
            },
            .Array => |ar| {
                const n = ar.len();
                if (n > 0) return okElem(ar.get(n - 1));
                if (or_null) return ok(Value.Null);
                return try thrown(a, "kotlin.NoSuchElementException", "Collection is empty.");
            },
            else => {},
        }
    }
    const items = switch (try iterableItems(a, ctx.args[0], "last")) {
        .items => |x| x,
        .err => |e| return e,
    };
    // `iterableItems` returns a scratch snapshot/array; the returned element is
    // copied out, so free the snapshot spine on exit.
    defer if (runtime.freeScratch()) a.free(items);
    if (ctx.args.len >= 2) {
        const block = ctx.args[1];
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const r = switch (try invoke(ctx, &block, &.{items[i]})) {
                .value => |x| x,
                .err => |e| return e,
            };
            if (r == .Bool and r.Bool) return okElem(items[i]);
        }
        if (or_null) return ok(Value.Null);
        return try thrown(a, "kotlin.NoSuchElementException", "Collection contains no element matching the predicate.");
    }
    if (items.len > 0) return okElem(items[items.len - 1]);
    if (or_null) return ok(Value.Null);
    return try thrown(a, "kotlin.NoSuchElementException", "Collection is empty.");
}
pub fn coll_list_last(ctx: *CallCtx) Error!EvalResult {
    return listLastImpl(ctx, false);
}
pub fn coll_list_last_or_null(ctx: *CallCtx) Error!EvalResult {
    return listLastImpl(ctx, true);
}
pub fn coll_list_last_index_of(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.lastIndexOf")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("lastIndexOf requires an argument");
    const needle = ctx.args[1];
    const items = try snapshotItems(ctx.allocator, it);
    defer if (runtime.freeScratch()) ctx.allocator.free(items);
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (try eqBoxedH(ctx.host, ctx.out, &items[i], &needle)) return ok(Value.newInt(@intCast(i)));
    }
    return ok(Value.newInt(-1));
}

fn joinOptStr(a: Allocator, args: []const Value, idx: usize, default: []const u8) Error![]const u8 {
    if (idx >= args.len) return default;
    return switch (args[idx]) {
        .Null => default,
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk g.get().bytes;
        },
        else => |other| try display(a, other),
    };
}

fn joinToStringImpl(ctx: *CallCtx, items: []const Value, allow_instance_to_string: bool) Error!EvalResult {
    const a = ctx.allocator;
    var effective = ctx.args[1..];
    var transform_slot: ?Value = null;
    if (effective.len > 0) {
        const last = effective[effective.len - 1];
        if (isTransformCallable(last)) {
            transform_slot = last;
            effective = effective[0 .. effective.len - 1];
        }
    }
    const sep = try joinOptStr(a, effective, 0, ", ");
    const prefix = try joinOptStr(a, effective, 1, "");
    const postfix = try joinOptStr(a, effective, 2, "");
    const limit: i64 = if (effective.len <= 3 or effective[3] == .Null)
        -1
    else
        (effective[3].asI64() orelse -1);
    const truncated = try joinOptStr(a, effective, 4, "...");
    const n = items.len;
    const take: usize = if (limit < 0) n else @min(@as(usize, @intCast(limit)), n);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, prefix);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const v = items[i];
        if (i > 0) try out.appendSlice(a, sep);
        const piece: []const u8 = if (transform_slot) |t| blk: {
            const r = switch (try invoke(ctx, &t, &.{v})) {
                .value => |x| x,
                .err => |e| return e,
            };
            break :blk switch (r) {
                .String => |s| sblk: {
                    const g = s.borrow();
                    defer g.deinit();
                    break :sblk try a.dupe(u8, g.get().bytes);
                },
                else => try display(a, r),
            };
        } else if (allow_instance_to_string and v == .Instance) blk: {
            const m = try ctx.host.invokeMethod(&v, "toString", &.{}, ctx.out);
            if (m) |mr| {
                if (mr == .ok and mr.ok == .String) {
                    const g = mr.ok.String.borrow();
                    defer g.deinit();
                    break :blk try a.dupe(u8, g.get().bytes);
                }
            }
            break :blk try display(a, v);
        } else try display(a, v);
        try out.appendSlice(a, piece);
        // `piece` is always a fresh `dupe`/`display` allocation, copied into
        // `out`; free it per element rather than leaking one per joined value.
        if (runtime.freeScratch()) a.free(piece);
    }
    if (limit >= 0 and n > take) {
        if (take > 0) try out.appendSlice(a, sep);
        try out.appendSlice(a, truncated);
    }
    try out.appendSlice(a, postfix);
    const buf = try out.toOwnedSlice(a);
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}

pub fn coll_list_join_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return arityErr("joinToString expects an iterable receiver");
    const items = switch (try iterableItems(a, ctx.args[0], "joinToString")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    return joinToStringImpl(ctx, items, true);
}

pub fn coll_array_join_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("Array.joinToString requires a receiver");
    const items = switch (try iterableItems(a, ctx.args[0], "Array.joinToString")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    return joinToStringImpl(ctx, items, false);
}

/// Render one collection element/key/value: a user Instance via its own
/// `toString()` (dispatched through the VM); everything else via `display`.
/// Caller owns the returned slice.
fn elemPiece(ctx: *CallCtx, v: Value) Error![]u8 {
    const a = ctx.allocator;
    if (v == .Instance) {
        if (try ctx.host.invokeMethod(&v, "toString", &.{}, ctx.out)) |mr| {
            if (mr == .ok and mr.ok == .String) {
                const g = mr.ok.String.borrow();
                defer g.deinit();
                return try a.dupe(u8, g.get().bytes);
            }
        }
    }
    return try display(a, v);
}

fn collToString(ctx: *CallCtx, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr(try fmt(a, "{s} requires a receiver", .{what}));
    if (try sublistComodGuard(a, &ctx.args[0])) |e| return e;
    const recv = ctx.args[0];
    if (recv == .Map) {
        const entries = try snapshotEntries(a, recv.Map.entries);
        defer a.free(entries);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.append(a, '{');
        for (entries, 0..) |kv, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            const kp = if (Value.referenceEq(&kv.key, &recv)) try a.dupe(u8, "(this Map)") else try elemPiece(ctx, kv.key);
            defer if (runtime.freeScratch()) a.free(kp);
            try out.appendSlice(a, kp);
            try out.append(a, '=');
            const vp = if (Value.referenceEq(&kv.value, &recv)) try a.dupe(u8, "(this Map)") else try elemPiece(ctx, kv.value);
            defer if (runtime.freeScratch()) a.free(vp);
            try out.appendSlice(a, vp);
        }
        try out.append(a, '}');
        return ok(try makeStringOwned(a, try out.toOwnedSlice(a)));
    }
    // A List/Set element that is a user Instance must render via its own
    // `toString()` (dispatched through the VM), not the Zig-level `display`
    // formatter, which prints `ClassName@id` for a non-data class. Primitives
    // and data classes fall back to `display` (already correct).
    const items: ?[]Value = switch (recv) {
        .List => |l| try snapshotItems(a, l.items),
        .Set => |s| try snapshotItems(a, s.items),
        else => null,
    };
    if (items) |elems| {
        defer a.free(elems);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.append(a, '[');
        for (elems, 0..) |v, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            // A collection that contains itself renders the self-slot as
            // `(this Collection)` rather than recursing (matches Kotlin).
            if (Value.referenceEq(&v, &recv)) {
                try out.appendSlice(a, "(this Collection)");
                continue;
            }
            const piece: []const u8 = if (v == .Instance) blk: {
                if (try ctx.host.invokeMethod(&v, "toString", &.{}, ctx.out)) |mr| {
                    if (mr == .ok and mr.ok == .String) {
                        const g = mr.ok.String.borrow();
                        defer g.deinit();
                        break :blk try a.dupe(u8, g.get().bytes);
                    }
                }
                break :blk try display(a, v);
            } else try display(a, v);
            try out.appendSlice(a, piece);
            if (runtime.freeScratch()) a.free(piece);
        }
        try out.append(a, ']');
        const buf = try out.toOwnedSlice(a);
        return ok(try makeStringOwned(a, buf));
    }
    const buf = try display(a, recv);
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}
pub fn coll_list_to_string(ctx: *CallCtx) Error!EvalResult {
    return collToString(ctx, "List.toString");
}

pub fn coll_mut_list_add(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (try readOnlyMutationGuard(a, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const it = switch (try recvListItems(a, ctx.args, "MutableList.add")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const user = ctx.args.len - 1;
    if (user == 1) {
        const g = it.borrowMut();
        defer g.deinit();
        // The list owns one ref to each element it stores.
        if (runtime.reclaimEnabled()) ctx.args[1].retain();
        try g.get().append(a, ctx.args[1]);
        return ok(.{ .Bool = true });
    }
    if (user >= 2) {
        if (ctx.args[1] != .Int) return typeErr("add(index, item) requires an Int index");
        const i = ctx.args[1].Int;
        const item = ctx.args[2];
        const g = it.borrowMut();
        defer g.deinit();
        const len = g.get().items.len;
        if (i < 0 or @as(usize, @intCast(i)) > len) {
            const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, len });
            const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
            if (runtime.freeScratch()) a.free(msg);
            return e;
        }
        if (runtime.reclaimEnabled()) item.retain();
        try g.get().insert(a, @intCast(i), item);
        return ok(Value.Unit);
    }
    return arityErr("add requires an argument");
}
pub fn coll_mut_list_add_first(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.addFirst")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("addFirst requires an argument");
    const g = it.borrowMut();
    defer g.deinit();
    if (runtime.reclaimEnabled()) ctx.args[1].retain();
    try g.get().insert(a, 0, ctx.args[1]);
    return ok(Value.Unit);
}
pub fn coll_mut_list_remove_first(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.removeFirst")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const g = it.borrowMut();
    defer g.deinit();
    if (g.get().items.len == 0) {
        return try thrown(a, "kotlin.NoSuchElementException", "ArrayDeque is empty.");
    }
    return ok(g.get().orderedRemove(0));
}
pub fn coll_mut_list_remove_last(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.removeLast")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const g = it.borrowMut();
    defer g.deinit();
    if (g.get().pop()) |v| return ok(v);
    return try thrown(a, "kotlin.NoSuchElementException", "ArrayDeque is empty.");
}
pub fn coll_mut_list_remove_at(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.removeAt")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or ctx.args[1] != .Int) return typeErr("removeAt requires an Int index");
    const i = ctx.args[1].Int;
    const g = it.borrowMut();
    defer g.deinit();
    const len = g.get().items.len;
    if (i < 0 or @as(usize, @intCast(i)) >= len) {
        const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, len });
        const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    return ok(g.get().orderedRemove(@intCast(i)));
}
pub fn coll_mut_list_clear(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.clear")) {
        .items => |x| x,
        .err => |e| return e,
    };
    {
        const g = it.borrowMut();
        defer g.deinit();
        // clear() discards every element; drop the list's owned references.
        if (runtime.reclaimEnabled()) for (g.get().items) |v| v.release(a);
        g.get().clearRetainingCapacity();
    }
    syncMapView(a, ctx.args[0]);
    return ok(Value.Unit);
}
pub fn coll_array_list_capacity_noop(ctx: *CallCtx) Error!EvalResult {
    // `ArrayList.trimToSize()` / `ensureCapacity(n)` are capacity-only no-ops
    // here (no backing-array capacity is tracked), but Java registers them as
    // structural modifications, so a concurrent iterator must still fail-fast.
    if (ctx.args.len > 0) bumpModCount(&ctx.args[0]);
    return ok(Value.Unit);
}

// =====================================================================
// Map-view sync (keys/values/entries live views)
// =====================================================================

const MapView = struct { entries: MapEntries, kind: MapViewKind };
const MapViewRef = struct { items: ValueList, backing: MapView };

/// Resolve a view value to its map-backing, or null when it is not a live map
/// view (a plain collection, a `subList`, or an array `.asList()`).
fn mapBackingOf(receiver: Value) ?MapView {
    const cell = switch (receiver) {
        .Set => |s| s.backing,
        .List => |l| l.backing,
        else => null,
    } orelse return null;
    return switch (cell.data) {
        .map => |m| .{ .entries = m.entries, .kind = m.kind },
        else => null,
    };
}

/// After a live `MutableMap.keys`/`.values`/`.entries` view mutated its
/// `items`, rebuild the backing map's entries to mirror the survivors.
/// Order-preserving subsequence match.
fn syncMapView(a: Allocator, receiver: Value) void {
    _ = a;
    const backing = mapBackingOf(receiver) orelse return;
    const items_vl = switch (receiver) {
        .Set => |s| s.items,
        .List => |l| l.items,
        else => return,
    };
    const view: MapViewRef = .{ .items = items_vl, .backing = backing };
    const items_g = view.items.borrow();
    defer items_g.deinit();
    const items = items_g.get().items;
    const kind = view.backing.kind;
    const entries_g = view.backing.entries.borrowMut();
    defer entries_g.deinit();
    const entries = entries_g.get();
    var j: usize = 0;
    var w: usize = 0;
    var r: usize = 0;
    while (r < entries.pairs.items.len) : (r += 1) {
        const kv = entries.pairs.items[r];
        const proj = switch (kind) {
            .Values => kv.value,
            else => kv.key,
        };
        var matched = false;
        if (j < items.len) {
            const it = items[j];
            const target = switch (kind) {
                .Entries => if (it == .MapEntry) it.MapEntry.key.asPtr().* else it,
                else => it,
            };
            matched = eqBoxed(&proj, &target);
        }
        if (matched) {
            entries.pairs.items[w] = kv;
            w += 1;
            j += 1;
        }
    }
    entries.pairs.shrinkRetainingCapacity(w);
    entries.invalidate();
}

// =====================================================================
// subList live-view write-through
// =====================================================================

/// Resolve a value to its live `subList` backing cell, or null when it is not a
/// `subList` view (a plain list, a map view, or an array `.asList()`).
fn sublistBackingOf(receiver: Value) ?*runtime.CollBackingRef.Cell {
    if (receiver != .List) return null;
    const cell = receiver.List.backing orelse return null;
    if (cell.data != .sublist) return null;
    return cell;
}

/// After a `subList` view mutated its own `items`, splice the new window back
/// into the parent list so the change shows through, and record the window's
/// new length. A no-op for any receiver that is not a live `subList`. Declared
/// as the *first* `defer` of every list mutator so it runs after the mutator's
/// own item-borrow guard has been released (no nested borrow of `items`).
fn syncSublist(a: Allocator, receiver: Value) void {
    const cell = sublistBackingOf(receiver) orelse return;
    const cur = counterNowOf(receiver.List.mod_count);
    syncSublistChain(a, cell, receiver.List.items, cur);
}

/// Splice a mutated view's cache into its parent window and recurse up
/// the ancestor chain, growing/shrinking each window and re-stamping each
/// ancestor's comod expectation. Siblings keep their stale stamp and fail
/// fast on their next access.
fn syncSublistChain(a: Allocator, cell: *runtime.CollBackingRef.Cell, view_items: ValueList, cur: u64) void {
    if (cell.data != .sublist) return;
    const sb = &cell.data.sublist;
    const from = sb.from;
    const old_len = sb.len;
    {
        const view_g = view_items.borrow();
        defer view_g.deinit();
        const new_items = view_g.get().items;
        const pg = sb.parent.borrowMut();
        defer pg.deinit();
        const plist = pg.get();
        if (from > plist.items.len) {
            sb.len = 0;
            return;
        }
        const span = @min(from + old_len, plist.items.len) - from;
        if (runtime.reclaimEnabled()) {
            for (plist.items[from .. from + span]) |v| v.release(a);
            for (new_items) |v| v.retain();
        }
        plist.replaceRange(a, from, span, new_items) catch return;
        sb.len = new_items.len;
        sb.exp_mod = cur;
    }
    if (sb.parent_backing) |pb| syncSublistChain(a, pb, sb.parent, cur);
}

/// Current value of a shared structural counter (0 when uncounted).
pub fn counterNowOf(mc: ?ObjRef(u64)) u64 {
    const cell = mc orelse return 0;
    const g = cell.borrow();
    defer g.deinit();
    return g.get().*;
}

/// Whether a live `subList` view's backing changed structurally not
/// through the view (or a descendant) — the CME predicate. The freeze bit
/// is masked so a leaked-but-unmodified builder view still reads after
/// `build()`.
pub fn sublistViewStale(v: *const Value) bool {
    return v.sublistViewStale();
}

/// ConcurrentModificationException when `sublistViewStale`; read choke
/// points call this before serving.
pub fn sublistComodGuard(a: Allocator, v: *const Value) Error!?EvalResult {
    if (!sublistViewStale(v)) return null;
    return try thrown(a, "kotlin.ConcurrentModificationException", null);
}

/// Live-entry prologue shared by the `Map.Entry` intrinsics: after a
/// structural map change every access throws CME; before that, the value
/// box is refreshed from the live pair so non-structural updates show
/// through.
pub fn mapEntryViewGuard(a: Allocator, v: *const Value) Error!?EvalResult {
    if (v.* != .MapEntry) return null;
    const me = &v.MapEntry;
    const entries = me.backing orelse return null;
    var stale = false;
    {
        const g = entries.borrow();
        defer g.deinit();
        if (g.get().mod_count) |cell| {
            const cg = cell.borrow();
            stale = cg.get().* != me.exp_mod;
            cg.deinit();
        }
        if (!stale) {
            for (g.get().pairs.items) |*slot| {
                if (Value.structuralEq(&slot.key, me.key.asPtr())) {
                    const live = slot.value;
                    if (!Value.structuralEq(me.value.asPtr(), &live)) {
                        if (runtime.reclaimEnabled()) {
                            live.retain();
                            me.value.asPtr().release(a);
                        }
                        me.value.asPtr().* = live;
                    }
                    break;
                }
            }
        }
    }
    if (stale) return try thrown(a, "kotlin.ConcurrentModificationException", null);
    return null;
}

// =====================================================================
// Companion constants & public comparison/sequence helpers
// =====================================================================

/// Result of the public natural-order comparison: an ordering or a
/// `RuntimeError` (as data).
pub const OrderResult = union(enum) { order: Order, err: RuntimeError };

/// Natural-order comparison exposed to the interpreter's higher-order
/// ops. Returns an ordering or a `RuntimeError` as data.
pub fn compareValuesPublic(a: Allocator, x: Value, y: Value) Error!OrderResult {
    return switch (try compareValues(a, x, y)) {
        .order => |o| .{ .order = o },
        .err => |e| .{ .err = e.err },
    };
}

/// `primitive_companion_const(ty, name)` — companion constants for the
/// built-in numeric/char primitive types.
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

// =====================================================================
// Sequence materialisation
// =====================================================================

const SeqOutcome = union(enum) { items: []Value, err: RuntimeError };

fn seqCall(host: IntrinsicHost, f: *const Value, args: []const Value, out: Output) Error!union(enum) { value: Value, err: RuntimeError } {
    const r = try host.invokeCallable(f, args, out);
    return switch (r) {
        .ok => |v| .{ .value = v },
        .err => |e| .{ .err = e },
    };
}

/// A one-shot sequence (`generateSequence { … }`) consumes once; the
/// second iteration throws, matching the source's `.constrainOnce()`.
/// Marks the sequence consumed on first use.
pub fn oneShotConsumeCheck(a: Allocator, seq_val: Value) Error!?RuntimeError {
    {
        const g = seq_val.Sequence.borrow();
        defer g.deinit();
        if (!g.get().one_shot) return null;
        if (g.get().consumed) {
            const exc = try makeException(a, "kotlin.IllegalStateException", "This sequence can be consumed only once.");
            return .{ .Thrown = exc };
        }
    }
    const gm = seq_val.Sequence.borrowMut();
    defer gm.deinit();
    gm.get().consumed = true;
    return null;
}

pub fn materialiseSequence(a: Allocator, host: IntrinsicHost, out: Output, seq_val: Value) Error!SeqOutcome {
    return materialiseSequenceBounded(a, host, out, seq_val, null);
}

pub fn materialiseSequenceBounded(a: Allocator, host: IntrinsicHost, out: Output, seq_val: Value, max: ?usize) Error!SeqOutcome {
    if (seq_val != .Sequence) {
        return .{ .err = .{ .Type = "materialise_sequence: not a Sequence" } };
    }
    if (try oneShotConsumeCheck(a, seq_val)) |e| return .{ .err = e };
    const seq_g = seq_val.Sequence.borrow();
    defer seq_g.deinit();
    const seq = seq_g.get().*;

    var all_streaming = true;
    for (seq.ops) |op| {
        switch (op) {
            .Map, .Filter, .FilterNot, .Take, .Drop, .TakeWhile, .DropWhile, .OnEach, .MapIndexed, .FilterIndexed => {},
            else => {
                all_streaming = false;
                break;
            },
        }
    }

    if (all_streaming) {
        return streamSequence(a, host, out, seq, max);
    }
    return bufferSequence(a, host, out, seq);
}

const PumpState = struct {
    taken: []usize,
    dropped: []usize,
    take_while_live: []bool,
    drop_while_live: []bool,
    indices: []usize,
};

/// Returns true to keep pulling source items, false when a Take cap was
/// reached (pipeline exhausted). On a callback error returns the error.
fn pumpItem(
    a: Allocator,
    host: IntrinsicHost,
    out: Output,
    start_value: Value,
    ops: []const SeqOp,
    st: *PumpState,
    output: *std.ArrayList(Value),
) Error!union(enum) { cont: bool, err: RuntimeError } {
    var current = start_value;
    // Pin the values the GC cannot otherwise reach across the re-entrant lambda
    // invocations below: the accumulated results so far (`output`, stable for
    // this pump — it is only appended to at the end) and the in-flight `current`
    // value threading through the ops. Without this, a collection during a later
    // element's `map`/`filter` lambda sweeps the earlier elements (e.g. the
    // `RoutingPathSegment`s a `splitToSequence().map{}.toList()` accumulates).
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    runtime.keepalivePushSlice(output.items);
    const ka_cur = runtime.keepaliveMark();
    for (ops, 0..) |op, idx| {
        runtime.keepaliveRestore(ka_cur);
        runtime.keepalivePush(current);
        switch (op) {
            .Map => |f| {
                current = switch (try seqCall(host, &f, &.{current}, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
            },
            .OnEach => |f| {
                switch (try seqCall(host, &f, &.{current}, out)) {
                    .value => {},
                    .err => |e| return .{ .err = e },
                }
            },
            .MapIndexed => |f| {
                const i = st.indices[idx];
                st.indices[idx] += 1;
                current = switch (try seqCall(host, &f, &.{ Value.newInt(@intCast(i)), current }, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
            },
            .FilterIndexed => |f| {
                const i = st.indices[idx];
                st.indices[idx] += 1;
                const r = switch (try seqCall(host, &f, &.{ Value.newInt(@intCast(i)), current }, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) return .{ .cont = true };
            },
            .Filter => |f| {
                const r = switch (try seqCall(host, &f, &.{current}, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) return .{ .cont = true };
            },
            .FilterNot => |f| {
                const r = switch (try seqCall(host, &f, &.{current}, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (r == .Bool and r.Bool) return .{ .cont = true };
            },
            .Take => |n| {
                if (st.taken[idx] >= @as(usize, @intCast(n))) return .{ .cont = false };
                st.taken[idx] += 1;
            },
            .Drop => |n| {
                if (st.dropped[idx] < @as(usize, @intCast(n))) {
                    st.dropped[idx] += 1;
                    return .{ .cont = true };
                }
            },
            .TakeWhile => |f| {
                if (!st.take_while_live[idx]) return .{ .cont = false };
                const r = switch (try seqCall(host, &f, &.{current}, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) {
                    st.take_while_live[idx] = false;
                    return .{ .cont = false };
                }
            },
            .DropWhile => |f| {
                if (st.drop_while_live[idx]) {
                    const r = switch (try seqCall(host, &f, &.{current}, out)) {
                        .value => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    if (r == .Bool and r.Bool) return .{ .cont = true };
                    st.drop_while_live[idx] = false;
                }
            },
            else => unreachable,
        }
    }
    try output.append(a, current);
    return .{ .cont = true };
}

fn takeCapReached(ops: []const SeqOp, taken: []const usize) bool {
    for (ops, 0..) |op, i| {
        if (op == .Take and taken[i] >= @as(usize, @intCast(op.Take))) return true;
    }
    return false;
}

/// One pull from a `Merged` (zip) source: advance the left iterator, then
/// the right, one element each; either side exhausting ends the merge. The
/// child iterators are created together on the first pull, so a
/// shared-state generator observes `MergingSequence`'s strict interleave.
pub fn mergedPullOne(
    a: Allocator,
    host: IntrinsicHost,
    out: Output,
    mz: runtime.MergedSource,
    iter_left: *?Value,
    iter_right: *?Value,
) Error!union(enum) { value: Value, done, err: RuntimeError } {
    if (iter_left.* == null) {
        const li = (try host.invokeMethod(&mz.left.asPtr().*, "iterator", &.{}, out)) orelse
            return .{ .err = .{ .Type = "zip: receiver lacks iterator()" } };
        switch (li) {
            .ok => |v| iter_left.* = v,
            .err => |e| return .{ .err = e },
        }
        const ri = (try host.invokeMethod(&mz.right.asPtr().*, "iterator", &.{}, out)) orelse
            return .{ .err = .{ .Type = "zip: argument lacks iterator()" } };
        switch (ri) {
            .ok => |v| iter_right.* = v,
            .err => |e| return .{ .err = e },
        }
    }
    const lit = iter_left.*.?;
    const rit = iter_right.*.?;
    const lh = (try host.invokeMethod(&lit, "hasNext", &.{}, out)) orelse
        return .{ .err = .{ .Type = "zip: iterator lacks hasNext" } };
    switch (lh) {
        .ok => |x| if (!(x == .Bool and x.Bool)) return .done,
        .err => |e| return .{ .err = e },
    }
    const rh = (try host.invokeMethod(&rit, "hasNext", &.{}, out)) orelse
        return .{ .err = .{ .Type = "zip: iterator lacks hasNext" } };
    switch (rh) {
        .ok => |x| if (!(x == .Bool and x.Bool)) return .done,
        .err => |e| return .{ .err = e },
    }
    const av = switch ((try host.invokeMethod(&lit, "next", &.{}, out)) orelse
        return .{ .err = .{ .Type = "zip: iterator lacks next" } }) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const bv = switch ((try host.invokeMethod(&rit, "next", &.{}, out)) orelse
        return .{ .err = .{ .Type = "zip: iterator lacks next" } }) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (mz.transform) |t| {
        return switch (try seqCall(host, t.asPtr(), &.{ av, bv }, out)) {
            .value => |v| .{ .value = v },
            .err => |e| .{ .err = e },
        };
    }
    return .{ .value = try makePair(a, av, bv) };
}

fn streamSequence(a: Allocator, host: IntrinsicHost, out: Output, seq: runtime.SequenceData, max: ?usize) Error!SeqOutcome {
    const n_ops = seq.ops.len;
    var st = PumpState{
        .taken = try a.alloc(usize, n_ops),
        .dropped = try a.alloc(usize, n_ops),
        .take_while_live = try a.alloc(bool, n_ops),
        .drop_while_live = try a.alloc(bool, n_ops),
        .indices = try a.alloc(usize, n_ops),
    };
    @memset(st.taken, 0);
    @memset(st.dropped, 0);
    @memset(st.take_while_live, true);
    @memset(st.drop_while_live, true);
    @memset(st.indices, 0);
    var output: std.ArrayList(Value) = .empty;

    const ka_src = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka_src);
    switch (seq.source) {
        .Items => |v| {
            const g = v.borrow();
            defer g.deinit();
            // Pin the not-yet-processed source items across the per-item pumps.
            runtime.keepalivePushSlice(g.get().*);
            for (g.get().*) |item| {
                if (takeCapReached(seq.ops, st.taken)) break;
                const res = try pumpItem(a, host, out, item, seq.ops, &st, &output);
                switch (res) {
                    .cont => |c| if (!c) break,
                    .err => |e| return .{ .err = e },
                }
                if (max) |m| {
                    if (output.items.len >= m) break;
                }
            }
        },
        .Builder => |bstate0| {
            // Drive a FRESH cursor so this materialisation is independent of any
            // other consumption of the same (re-iterable) Sequence.
            const bstate = try freshBuilderState(host, a, bstate0);
            try pinBuilderState(a, bstate);
            // Pull from the lazy builder one element at a time so an infinite
            // generator never materialises past the consumer's demand.
            while (true) {
                if (takeCapReached(seq.ops, st.taken)) break;
                const step = try host.builderStep(bstate, out);
                const item = switch (step) {
                    .value => |val| val,
                    .done => break,
                    .err => |e| return .{ .err = e },
                };
                const res = try pumpItem(a, host, out, item, seq.ops, &st, &output);
                switch (res) {
                    .cont => |c| if (!c) break,
                    .err => |e| return .{ .err = e },
                }
                if (max) |m| {
                    if (output.items.len >= m) break;
                }
            }
        },
        .Generate => |gen| {
            var cur: ?Value = if (gen.seed) |s| blk: {
                const sv = s.asPtr().*;
                if (gen.seed_is_fn) {
                    const r = switch (try seqCall(host, &sv, &.{}, out)) {
                        .value => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    if (r == .Null) return .{ .items = try a.alloc(Value, 0) };
                    break :blk r;
                }
                sv.retain();
                break :blk sv;
            } else null;
            const limit: usize = 1_000_000;
            var produced: usize = 0;
            while (true) {
                if (takeCapReached(seq.ops, st.taken)) break;
                const candidate = if (cur) |v| v else blk: {
                    const r = switch (try seqCall(host, gen.next.asPtr(), &.{}, out)) {
                        .value => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    if (r == .Null) break;
                    break :blk r;
                };
                produced += 1;
                if (produced > limit) {
                    return .{ .err = .{ .Type = "Sequence: generator exceeded 1,000,000 items" } };
                }
                const res = try pumpItem(a, host, out, candidate, seq.ops, &st, &output);
                switch (res) {
                    .cont => |c| if (!c) break,
                    .err => |e| return .{ .err = e },
                }
                if (max) |m| {
                    if (output.items.len >= m) break;
                }
                const nxt = switch (try seqCall(host, gen.next.asPtr(), &.{candidate}, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (nxt == .Null) break;
                cur = nxt;
            }
        },
        .IteratorFn => |fnbox| {
            const iter = switch (try seqCall(host, fnbox.asPtr(), &.{}, out)) {
                .value => |v| v,
                .err => |e| return .{ .err = e },
            };
            while (true) {
                if (takeCapReached(seq.ops, st.taken)) break;
                const hn = (try host.invokeMethod(&iter, "hasNext", &.{}, out)) orelse
                    return .{ .err = .{ .Type = "Sequence: iterator lacks hasNext" } };
                const has = switch (hn) {
                    .ok => |x| x == .Bool and x.Bool,
                    .err => |e| return .{ .err = e },
                };
                if (!has) break;
                const nx = (try host.invokeMethod(&iter, "next", &.{}, out)) orelse
                    return .{ .err = .{ .Type = "Sequence: iterator lacks next" } };
                const item = switch (nx) {
                    .ok => |x| x,
                    .err => |e| return .{ .err = e },
                };
                const res = try pumpItem(a, host, out, item, seq.ops, &st, &output);
                switch (res) {
                    .cont => |c| if (!c) break,
                    .err => |e| return .{ .err = e },
                }
                if (max) |m| {
                    if (output.items.len >= m) break;
                }
            }
        },
        .Merged => |mz| {
            var lit: ?Value = null;
            var rit: ?Value = null;
            while (true) {
                if (takeCapReached(seq.ops, st.taken)) break;
                const step = try mergedPullOne(a, host, out, mz, &lit, &rit);
                const item = switch (step) {
                    .value => |val| val,
                    .done => break,
                    .err => |e| return .{ .err = e },
                };
                const res = try pumpItem(a, host, out, item, seq.ops, &st, &output);
                switch (res) {
                    .cont => |c| if (!c) break,
                    .err => |e| return .{ .err = e },
                }
                if (max) |m| {
                    if (output.items.len >= m) break;
                }
            }
        },
    }
    return .{ .items = try output.toOwnedSlice(a) };
}

fn bufferSequence(a: Allocator, host: IntrinsicHost, out: Output, seq: runtime.SequenceData) Error!SeqOutcome {
    var items: std.ArrayList(Value) = .empty;
    switch (seq.source) {
        .Items => |v| {
            const g = v.borrow();
            defer g.deinit();
            try items.appendSlice(a, g.get().*);
        },
        .Builder => |bstate0| {
            const bstate = try freshBuilderState(host, a, bstate0);
            try pinBuilderState(a, bstate);
            while (true) {
                const step = try host.builderStep(bstate, out);
                switch (step) {
                    .value => |val| try items.append(a, val),
                    .done => break,
                    .err => |e| return .{ .err = e },
                }
            }
        },
        .Generate => |gen| {
            const limit: usize = 1024;
            var cur: ?Value = if (gen.seed) |s| blk: {
                const sv = s.asPtr().*;
                if (gen.seed_is_fn) {
                    const r = switch (try seqCall(host, &sv, &.{}, out)) {
                        .value => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    if (r == .Null) break :blk null;
                    break :blk r;
                }
                sv.retain();
                break :blk sv;
            } else null;
            while (items.items.len < limit) {
                const candidate = if (cur) |v| v else blk: {
                    const r = switch (try seqCall(host, gen.next.asPtr(), &.{}, out)) {
                        .value => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    if (r == .Null) break;
                    break :blk r;
                };
                try items.append(a, candidate);
                const nxt = switch (try seqCall(host, gen.next.asPtr(), &.{candidate}, out)) {
                    .value => |v| v,
                    .err => |e| return .{ .err = e },
                };
                if (nxt == .Null) break;
                cur = nxt;
            }
        },
        .IteratorFn => |fnbox| {
            const iter = switch (try seqCall(host, fnbox.asPtr(), &.{}, out)) {
                .value => |v| v,
                .err => |e| return .{ .err = e },
            };
            while (true) {
                const hn = (try host.invokeMethod(&iter, "hasNext", &.{}, out)) orelse
                    return .{ .err = .{ .Type = "Sequence: iterator lacks hasNext" } };
                const has = switch (hn) {
                    .ok => |x| x == .Bool and x.Bool,
                    .err => |e| return .{ .err = e },
                };
                if (!has) break;
                const nx = (try host.invokeMethod(&iter, "next", &.{}, out)) orelse
                    return .{ .err = .{ .Type = "Sequence: iterator lacks next" } };
                switch (nx) {
                    .ok => |item| try items.append(a, item),
                    .err => |e| return .{ .err = e },
                }
            }
        },
        .Merged => |mz| {
            var lit: ?Value = null;
            var rit: ?Value = null;
            while (true) {
                switch (try mergedPullOne(a, host, out, mz, &lit, &rit)) {
                    .value => |item| try items.append(a, item),
                    .done => break,
                    .err => |e| return .{ .err = e },
                }
            }
        },
    }
    var cur_items = try items.toOwnedSlice(a);
    for (seq.ops) |op| {
        cur_items = switch (try applySeqOp(a, host, out, op, cur_items)) {
            .items => |xs| xs,
            .err => |e| return .{ .err = e },
        };
    }
    return .{ .items = cur_items };
}

fn applySeqOp(a: Allocator, host: IntrinsicHost, out: Output, op: SeqOp, items: []Value) Error!SeqOutcome {
    switch (op) {
        .Map => |f| {
            var nx = try a.alloc(Value, items.len);
            // Pin the source and the already-mapped prefix across the lambda
            // calls (the GC cannot reach these host-locals); only `nx[0..i]` is
            // initialized, so never pin the undefined tail.
            const ka = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(ka);
            runtime.keepalivePushSlice(items);
            const ka2 = runtime.keepaliveMark();
            for (items, 0..) |v, i| {
                runtime.keepaliveRestore(ka2);
                runtime.keepalivePushSlice(nx[0..i]);
                nx[i] = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
            }
            return .{ .items = nx };
        },
        .OnEach => |f| {
            for (items) |v| {
                switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => {},
                    .err => |e| return .{ .err = e },
                }
            }
            return .{ .items = items };
        },
        .MapIndexed => |f| {
            var nx = try a.alloc(Value, items.len);
            const ka = runtime.keepaliveMark();
            defer runtime.keepaliveRestore(ka);
            runtime.keepalivePushSlice(items);
            const ka2 = runtime.keepaliveMark();
            for (items, 0..) |v, i| {
                runtime.keepaliveRestore(ka2);
                runtime.keepalivePushSlice(nx[0..i]);
                nx[i] = switch (try seqCall(host, &f, &.{ Value.newInt(@intCast(i)), v }, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
            }
            return .{ .items = nx };
        },
        .FilterIndexed => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items, 0..) |v, i| {
                const r = switch (try seqCall(host, &f, &.{ Value.newInt(@intCast(i)), v }, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (r == .Bool and r.Bool) try nx.append(a, v);
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .Filter => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items) |v| {
                const r = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (r == .Bool and r.Bool) try nx.append(a, v);
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .FilterNot => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items) |v| {
                const r = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) try nx.append(a, v);
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .Take => |n| {
            const k: usize = @intCast(n);
            return .{ .items = if (k < items.len) items[0..k] else items };
        },
        .Drop => |n| {
            const k: usize = @min(@as(usize, @intCast(n)), items.len);
            return .{ .items = items[k..] };
        },
        .TakeWhile => |f| {
            var cutoff: usize = items.len;
            for (items, 0..) |v, i| {
                const r = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) {
                    cutoff = i;
                    break;
                }
            }
            return .{ .items = items[0..cutoff] };
        },
        .DropWhile => |f| {
            var start: usize = 0;
            while (start < items.len) {
                const r = switch (try seqCall(host, &f, &.{items[start]}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (!(r == .Bool and r.Bool)) break;
                start += 1;
            }
            return .{ .items = items[start..] };
        },
        .FlatMap => |f| {
            var nx: std.ArrayList(Value) = .empty;
            for (items) |v| {
                const mapped = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                switch (mapped) {
                    .List => |xs| try appendVL(&nx, a, xs.items),
                    .Set => |xs| try appendVL(&nx, a, xs.items),
                    .Sequence => {
                        const sub = switch (try materialiseSequence(a, host, out, mapped)) {
                            .items => |xs| xs,
                            .err => |e| return .{ .err = e },
                        };
                        try nx.appendSlice(a, sub);
                    },
                    // Every other iterable transform result (Array, Range, Map,
                    // a user `Instance` Iterable) is flattened through the
                    // shared extractor; a non-iterable result degrades to a
                    // single element as before.
                    else => {
                        var ctx = runtime.CallCtx{ .args = &.{}, .out = out, .host = host, .allocator = a };
                        switch (try iterableItemsCtx(&ctx, mapped, "flatMap")) {
                            .items => |flat| {
                                try nx.appendSlice(a, flat);
                                if (runtime.freeScratch()) a.free(flat);
                            },
                            .err => try nx.append(a, mapped),
                        }
                    },
                }
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .Distinct => {
            var seen: std.ArrayList(Value) = .empty;
            var nx: std.ArrayList(Value) = .empty;
            for (items) |v| {
                if (!containsBoxed(seen.items, &v)) {
                    try seen.append(a, v);
                    try nx.append(a, v);
                }
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .DistinctBy => |f| {
            var seen: std.ArrayList(Value) = .empty;
            var nx: std.ArrayList(Value) = .empty;
            for (items) |v| {
                const key = switch (try seqCall(host, &f, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
                if (!containsBoxed(seen.items, &key)) {
                    try seen.append(a, key);
                    try nx.append(a, v);
                }
            }
            return .{ .items = try nx.toOwnedSlice(a) };
        },
        .Sorted => |descending| {
            if (try sortValuesNaturalDescErr(a, items, descending)) |e| return .{ .err = e };
            return .{ .items = items };
        },
        .SortedBy => |sb| {
            const keyed = try a.alloc(Value, items.len);
            for (items, 0..) |v, i| {
                keyed[i] = switch (try seqCall(host, &sb.selector, &.{v}, out)) {
                    .value => |x| x,
                    .err => |e| return .{ .err = e },
                };
            }
            // Insertion sort keyed pairs, moving items in lockstep.
            var i: usize = 1;
            while (i < items.len) : (i += 1) {
                var j = i;
                while (j > 0) {
                    const o = switch (try compareValues(a, keyed[j - 1], keyed[j])) {
                        .order => |o| o,
                        .err => |e| return .{ .err = e.err },
                    };
                    const flipped = if (sb.descending) reverseOrder(o) else o;
                    if (flipped == .gt) {
                        std.mem.swap(Value, &items[j - 1], &items[j]);
                        std.mem.swap(Value, &keyed[j - 1], &keyed[j]);
                        j -= 1;
                    } else break;
                }
            }
            return .{ .items = items };
        },
        .SortedWith => |comparator| {
            var i: usize = 1;
            while (i < items.len) : (i += 1) {
                var j = i;
                while (j > 0) {
                    const m = try host.invokeMethod(&comparator, "compare", &.{ items[j - 1], items[j] }, out);
                    const ord_val = if (m) |mr| switch (mr) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    } else return .{ .err = .{ .Type = "SortedWith: comparator has no `compare` method" } };
                    const n = ord_val.asI64() orelse 0;
                    if (n > 0) {
                        std.mem.swap(Value, &items[j - 1], &items[j]);
                        j -= 1;
                    } else break;
                }
            }
            return .{ .items = items };
        },
    }
}

fn sortValuesNaturalDescErr(a: Allocator, items: []Value, descending: bool) Error!?RuntimeError {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const o = switch (try compareValues(a, items[j - 1], items[j])) {
                .order => |o| o,
                .err => |e| return e.err,
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

// =====================================================================
// List sorting / transforms
// =====================================================================

/// host-aware comparison: defers to a user `compareTo` for Instance items.
fn compareHostAware(ctx: *CallCtx, x: Value, y: Value) Error!CompareOutcome {
    if (x == .Instance) {
        if (try ctx.host.invokeMethod(&x, "compareTo", &.{y}, ctx.out)) |m| {
            if (m == .ok and m.ok == .Int) return .{ .order = i32ToOrdering(m.ok.Int) };
        }
    }
    return compareValues(ctx.allocator, x, y);
}

/// Sort with optional host-aware compareTo for Instance items. Stable.
fn sortListHostAware(ctx: *CallCtx, items: []Value) Error!?EvalResult {
    return sortListHostAwareDesc(ctx, items, false);
}

/// `sortListHostAware` with a natural-order direction: `descending`
/// flips the comparison (the empty-step `reverseOrder()` comparator over
/// host-comparable elements), keeping the sort stable — equal elements
/// hold their original order in both directions, matching kotlinc.
fn sortListHostAwareDesc(ctx: *CallCtx, items: []Value, descending: bool) Error!?EvalResult {
    const a = ctx.allocator;
    var needs_host = false;
    for (items) |v| {
        if (v == .Instance) {
            needs_host = true;
            break;
        }
    }
    if (!needs_host) return sortValuesNaturalDesc(a, items, descending);
    // Stable bottom-up merge sort: O(n log n) host comparisons. An insertion
    // sort here is O(n²) and times out on large host-comparable lists.
    const n = items.len;
    if (n < 2) return null;
    const buf = try a.alloc(Value, n);
    defer if (runtime.freeScratch()) a.free(buf);
    var width: usize = 1;
    while (width < n) : (width *= 2) {
        var lo: usize = 0;
        while (lo < n) : (lo += 2 * width) {
            const mid = @min(lo + width, n);
            const hi = @min(lo + 2 * width, n);
            var i = lo;
            var j = mid;
            var k = lo;
            while (i < mid and j < hi) {
                const raw = switch (try compareHostAware(ctx, items[i], items[j])) {
                    .order => |o| o,
                    .err => |e| return e,
                };
                const o = if (descending) reverseOrder(raw) else raw;
                // Take the left run on a tie so the sort stays stable.
                if (o != .gt) {
                    buf[k] = items[i];
                    i += 1;
                } else {
                    buf[k] = items[j];
                    j += 1;
                }
                k += 1;
            }
            while (i < mid) : ({
                i += 1;
                k += 1;
            }) buf[k] = items[i];
            while (j < hi) : ({
                j += 1;
                k += 1;
            }) buf[k] = items[j];
        }
        @memcpy(items[0..n], buf[0..n]);
    }
    return null;
}

pub fn coll_list_sorted(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.sorted")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const copy = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(copy);
    if (try sortListHostAware(ctx, copy)) |e| return e;
    return ok(try makeList(a, copy, false));
}

pub fn coll_list_sorted_descending(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const v = try coll_list_sorted(ctx);
    if (v == .err) return v;
    const items = try snapshotItems(a, v.ok.List.items);
    defer if (runtime.freeScratch()) a.free(items);
    std.mem.reverse(Value, items);
    return ok(try makeList(a, items, false));
}

pub fn coll_list_reversed(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.reversed")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const out = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(out);
    std.mem.reverse(Value, out);
    return ok(try makeList(a, out, false));
}

pub fn coll_list_indices(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.indices")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const len: i64 = @intCast(listLen(it));
    return ok(.{ .Range = .{ .start = 0, .end = len - 1, .step = 1, .kind = .Int } });
}

pub fn coll_list_last_index(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvListItems(ctx.allocator, ctx.args, "List.lastIndex")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(Value.newInt(@as(i64, @intCast(listLen(it))) - 1));
}

pub fn coll_list_sum(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.sum")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const g = it.borrow();
    defer g.deinit();
    return sumValues(a, g.get().items, "List.sum");
}

/// Sum a numeric element slice, returning the Kotlin result type for the
/// element type: `Long` -> Long, `Double` -> Double, `Float` -> Float, and
/// Int/Short/Byte -> Int (wrapping, like Kotlin).
fn sumValues(a: Allocator, items: []const Value, what: []const u8) Error!EvalResult {
    var acc_i: i64 = 0;
    var acc_u: u64 = 0;
    var acc_f: f64 = 0;
    var any_long = false;
    var any_float = false;
    var any_double = false;
    // Unsigned sums keep their unsigned width (`Iterable<UInt>.sum()` is
    // UInt with u32 wrap; UByte/UShort widen to UInt; ULong stays ULong).
    var any_unsigned = false;
    var any_ulong = false;
    for (items) |v| {
        switch (v) {
            .Long => {
                any_long = true;
                acc_i +%= v.asI64().?;
            },
            .Int, .Short, .Byte => acc_i +%= v.asI64().?,
            .UByte, .UShort, .UInt => {
                any_unsigned = true;
                acc_u +%= v.asU64().?;
            },
            .ULong => {
                any_unsigned = true;
                any_ulong = true;
                acc_u +%= v.asU64().?;
            },
            .Float => {
                any_float = true;
                acc_f += v.asF64().?;
            },
            .Double => {
                any_double = true;
                acc_f += v.asF64().?;
            },
            else => {
                const vd = try display(a, v);
                return typeErr(try fmt(a, "{s} requires numeric elements, got {s}", .{ what, vd }));
            },
        }
    }
    if (any_double) return ok(.{ .Double = acc_f + @as(f64, @floatFromInt(acc_i)) });
    if (any_float) return ok(.{ .Float = @floatCast(acc_f + @as(f64, @floatFromInt(acc_i))) });
    if (any_unsigned) {
        if (any_ulong) return ok(.{ .ULong = acc_u });
        return ok(.{ .UInt = @truncate(acc_u) });
    }
    if (any_long) return ok(.{ .Long = acc_i });
    return ok(Value.newInt(@as(i32, @truncate(acc_i))));
}

pub fn coll_list_average(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("average requires a receiver");
    const items = switch (try iterableItems(a, ctx.args[0], "average")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) return ok(.{ .Double = std.math.nan(f64) });
    var sum: f64 = 0.0;
    var n: i64 = 0;
    for (items) |v| {
        sum += v.asF64() orelse {
            const vd = try display(a, v);
            return typeErr(try fmt(a, "List.average requires numeric elements, got {s}", .{vd}));
        };
        n += 1;
    }
    return ok(.{ .Double = sum / @as(f64, @floatFromInt(n)) });
}

pub fn coll_list_max_or_null(ctx: *CallCtx) Error!EvalResult {
    return collListMinMaxCore(ctx, true, true, "List.maxOrNull");
}

pub fn coll_list_min_or_null(ctx: *CallCtx) Error!EvalResult {
    return collListMinMaxCore(ctx, false, true, "List.minOrNull");
}

pub fn coll_list_max(ctx: *CallCtx) Error!EvalResult {
    return collListMinMaxCore(ctx, true, false, "List.max");
}

pub fn coll_list_min(ctx: *CallCtx) Error!EvalResult {
    return collListMinMaxCore(ctx, false, false, "List.min");
}

fn collListMinMaxCore(ctx: *CallCtx, want_max: bool, or_null: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    // Iterable-generic: the erased receiver-type-arg decline routes
    // Set/Array receivers here through the Iterable/Set-form probes.
    if (ctx.args.len == 0) return typeErr(try fmt(a, "{s} requires a receiver", .{what}));
    const items = switch (try iterableItems(a, ctx.args[0], what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) {
        if (or_null) return ok(Value.Null);
        const msg = try fmt(a, "{s}: empty", .{what});
        const e = try thrown(a, "kotlin.NoSuchElementException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    // Floating-point elements follow `Math.min`/`Math.max` (NaN propagates,
    // `-0.0 < 0.0`); the natural order cannot express either.
    if (items[0] == .Double or items[0] == .Float) {
        const is_float = items[0] == .Float;
        var acc: f64 = floatVal(items[0]) orelse return floatFallback(a, items, want_max);
        for (items[1..]) |v| {
            const x = floatVal(v) orelse return floatFallback(a, items, want_max);
            acc = if (want_max) kotlinFloatMax(acc, x) else kotlinFloatMin(acc, x);
        }
        return ok(if (is_float) .{ .Float = @floatCast(acc) } else .{ .Double = acc });
    }
    var best = items[0];
    for (items[1..]) |v| {
        const o = switch (try compareHostAware(ctx, v, best)) {
            .order => |o| o,
            .err => |e| return e,
        };
        const take = if (want_max) o == .gt else o == .lt;
        if (take) best = v;
    }
    return ok(best);
}

/// Collect (key, value) entries from a slice of Pair values; last write
/// wins on duplicate keys.
fn pairsFromValues(a: Allocator, items: []const Value, who: []const u8) Error!union(enum) { entries: std.ArrayList(MapPair), err: EvalResult } {
    var entries: std.ArrayList(MapPair) = .empty;
    for (items) |v| {
        if (v != .Pair) return .{ .err = typeErr(try fmt(a, "{s} requires a collection of Pair<K, V>", .{who})) };
        const key = v.Pair.first.asPtr().*;
        const val = v.Pair.second.asPtr().*;
        if (findKeyIndexBoxed(entries.items, &key)) |i| {
            entries.items[i].value = val;
        } else {
            try entries.append(a, .{ .key = key, .value = val });
        }
    }
    return .{ .entries = entries };
}

/// Read a user `Map` implementation (a `.Instance` whose class implements
/// `kotlin.collections.Map`) into a slice of `MapPair`. Drains the instance's
/// `entries` view, then extracts `key`/`value` from each entry through host
/// member dispatch (entries may be `Map.Entry` instances, builtin `MapEntry`
/// values, or `Pair`s). Returns an error EvalResult on a non-map instance.
fn userMapPairs(ctx: *CallCtx, inst: Value, who: []const u8) Error!union(enum) { entries: []MapPair, err: EvalResult } {
    const a = ctx.allocator;
    const entries_r = (try ctx.host.getProperty(&inst, "entries", ctx.out)) orelse
        return .{ .err = typeErr(try fmt(a, "{s} requires a Map or a collection of Pairs", .{who})) };
    const entries_val = switch (entries_r) {
        .ok => |v| v,
        .err => |e| return .{ .err = .{ .err = e } },
    };
    const items = switch (try materialiseIterableInstance(ctx, entries_val)) {
        .items => |x| x,
        .err => |e| return .{ .err = e },
    };
    var out: std.ArrayList(MapPair) = .empty;
    for (items) |entry| {
        var key: Value = undefined;
        var val: Value = undefined;
        switch (entry) {
            .MapEntry => |me| {
                key = me.key.asPtr().*;
                val = me.value.asPtr().*;
            },
            .Pair => |p| {
                key = p.first.asPtr().*;
                val = p.second.asPtr().*;
            },
            // A user `Map.Entry` instance: read its `key`/`value` properties.
            else => {
                const kr = (try ctx.host.getProperty(&entry, "key", ctx.out)) orelse
                    return .{ .err = typeErr(try fmt(a, "{s} entry is missing key", .{who})) };
                key = switch (kr) {
                    .ok => |v| v,
                    .err => |e| return .{ .err = .{ .err = e } },
                };
                const vr = (try ctx.host.getProperty(&entry, "value", ctx.out)) orelse
                    return .{ .err = typeErr(try fmt(a, "{s} entry is missing value", .{who})) };
                val = switch (vr) {
                    .ok => |v| v,
                    .err => |e| return .{ .err = .{ .err = e } },
                };
            },
        }
        if (try findKeyIndexBoxedH(ctx.host, ctx.out, out.items, &key)) |i| {
            out.items[i].value = val;
        } else {
            try out.append(a, .{ .key = key, .value = val });
        }
    }
    return .{ .entries = try out.toOwnedSlice(a) };
}

pub fn coll_list_to_map(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const recv = if (ctx.args.len > 0) ctx.args[0] else Value.Null;
    const items = switch (recv) {
        .Array => |arr| try arr.snapshot(a),
        // List/Set/Sequence and any user `.Instance` exposing `iterator()`.
        else => switch (try iterableItemsCtx(ctx, recv, "toMap")) {
            .items => |x| x,
            .err => |e| return e,
        },
    };
    defer if (runtime.freeScratch()) a.free(items);
    const entries = switch (try pairsFromValues(a, items, "toMap")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    // `toMap(destination)`: write the pairs into the supplied mutable map and
    // return it, rather than building a fresh read-only map.
    if (ctx.args.len >= 2 and ctx.args[1] == .Map) {
        const dest = ctx.args[1];
        const g = dest.Map.entries.borrowMut();
        defer g.deinit();
        for (entries.items) |kv| {
            var found = false;
            for (g.get().pairs.items) |*slot| {
                if (eqBoxed(&slot.key, &kv.key)) {
                    if (runtime.reclaimEnabled()) {
                        kv.value.retain();
                        slot.value.release(a);
                    }
                    slot.value = kv.value;
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (runtime.reclaimEnabled()) {
                    kv.key.retain();
                    kv.value.retain();
                }
                try g.get().pairs.append(a, kv);
                try g.get().noteAppended(a, g.get().pairs.items.len - 1);
            }
        }
        return ok(dest);
    }
    return ok(try makeMapH(ctx.host, ctx.out, a, entries.items, false));
}

pub fn coll_list_distinct(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.distinct")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    var out: std.ArrayList(Value) = .empty;
    for (items) |v| {
        if (!try containsBoxedH(ctx.host, ctx.out, out.items, &v)) try out.append(a, v);
    }
    return ok(try makeListBorrowed(a, out, false));
}

fn listTakeCount(ctx: *CallCtx, what: []const u8) Error!union(enum) { n: i64, err: EvalResult } {
    const a = ctx.allocator;
    const n = if (ctx.args.len > 1) (ctx.args[1].asI64() orelse return .{ .err = typeErr(try fmt(a, "{s} requires an Int", .{what})) }) else return .{ .err = typeErr(try fmt(a, "{s} requires an Int", .{what})) };
    if (n < 0) {
        const msg = try fmt(a, "Requested element count {d} is less than zero.", .{n});
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return .{ .err = e };
    }
    return .{ .n = n };
}

pub fn coll_list_take_last(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.takeLast")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const n: usize = @intCast(switch (try listTakeCount(ctx, "takeLast")) {
        .n => |v| v,
        .err => |e| return e,
    });
    const g = it.borrow();
    defer g.deinit();
    const items = g.get().items;
    const start = items.len -| n;
    return ok(try makeList(a, items[start..], false));
}

pub fn coll_list_drop_last(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.dropLast")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const n: usize = @intCast(switch (try listTakeCount(ctx, "dropLast")) {
        .n => |v| v,
        .err => |e| return e,
    });
    const g = it.borrow();
    defer g.deinit();
    const items = g.get().items;
    const end = items.len -| n;
    return ok(try makeList(a, items[0..end], false));
}

/// True when a `plusAssign`/`minusAssign` argument is a multi-element
/// collection (so it flattens via addAll/removeAll) rather than a single
/// element to add/remove.
fn isMultiElementArg(v: Value) bool {
    return switch (v) {
        .List, .Set, .Range, .Sequence, .Array => true,
        else => false,
    };
}

/// `MutableCollection += elements` — addAll for a collection argument, add
/// for a single element; mutates the receiver in place.
pub fn coll_mut_collection_plus_assign(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return arityErr("plusAssign requires an argument");
    const multi = isMultiElementArg(ctx.args[1]);
    return switch (ctx.args[0]) {
        .List => if (multi) coll_mut_list_add_all(ctx) else coll_mut_list_add(ctx),
        .Set => if (multi) coll_mut_set_add_all(ctx) else coll_mut_set_add(ctx),
        else => typeErr("plusAssign requires a mutable collection receiver"),
    };
}

/// `MutableCollection -= elements` — removeAll for a collection argument,
/// remove for a single element; mutates the receiver in place.
pub fn coll_mut_collection_minus_assign(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return arityErr("minusAssign requires an argument");
    const multi = isMultiElementArg(ctx.args[1]);
    return switch (ctx.args[0]) {
        .List => if (multi) coll_mut_list_remove_all(ctx) else coll_mut_list_remove(ctx),
        .Set => if (multi) coll_mut_set_remove_all(ctx) else coll_mut_set_remove(ctx),
        else => typeErr("minusAssign requires a mutable collection receiver"),
    };
}

pub fn coll_list_slice(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.slice")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const g = it.borrow();
    defer g.deinit();
    const items = g.get().items;
    const len: i64 = @intCast(items.len);
    var out: std.ArrayList(Value) = .empty;
    if (ctx.args.len > 1 and asRangeView(ctx.args[1]) != null) {
        const r = asRangeView(ctx.args[1]).?;
        var rit = RangeIter.init(r.start, r.end, r.step, r.kind);
        while (rit.next()) |i| {
            if (i < 0 or i >= len) {
                const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, len });
                const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
                if (runtime.freeScratch()) a.free(msg);
                return e;
            }
            try out.append(a, items[@intCast(i)]);
        }
    } else if (ctx.args.len > 1 and ctx.args[1] == .List) {
        const idx_g = ctx.args[1].List.items.borrow();
        defer idx_g.deinit();
        for (idx_g.get().items) |idx_val| {
            const i = idx_val.asI64() orelse return typeErr("slice indices must be Int");
            if (i < 0 or i >= len) {
                const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, len });
                const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
                if (runtime.freeScratch()) a.free(msg);
                return e;
            }
            try out.append(a, items[@intCast(i)]);
        }
    } else {
        return typeErr("slice requires an IntRange or List<Int>");
    }
    return ok(try makeListBorrowed(a, out, false));
}

pub fn coll_list_sublist(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .List) return typeErr("subList requires a List receiver");
    const recv = ctx.args[0];
    recv.refreshArrayView();
    recv.refreshSublistView();
    const from = if (ctx.args.len > 1) (ctx.args[1].asI64() orelse return typeErr("subList requires Int fromIndex")) else return typeErr("subList requires Int fromIndex");
    const to = if (ctx.args.len > 2) (ctx.args[2].asI64() orelse return typeErr("subList requires Int toIndex")) else return typeErr("subList requires Int toIndex");
    // A subList over a subList CHAINS: the new view's parent is the
    // receiver view itself, so growth through the child splices into every
    // ancestor window on the way to the root (Java's `SubList(parent)`).
    const parent_items = recv.List.items;
    const parent_backing = sublistBackingOf(recv);
    const recv_len: usize = listLen(recv.List.items);
    const len_i: i64 = @intCast(recv_len);
    if (from < 0 or to > len_i) {
        const msg = try fmt(a, "fromIndex: {d}, toIndex: {d}, size: {d}", .{ from, to, len_i });
        const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    if (from > to) {
        const msg = try fmt(a, "fromIndex: {d} > toIndex: {d}", .{ from, to });
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const new_from: usize = @intCast(from);
    const win_len: usize = @intCast(to - from);
    var window: std.ArrayList(Value) = .empty;
    {
        const rg = parent_items.borrow();
        defer rg.deinit();
        try window.appendSlice(a, rg.get().items[new_from .. new_from + win_len]);
    }
    if (runtime.reclaimEnabled()) for (window.items) |e| e.retain();
    const mutable = recv.List.mutable;
    const backing = try CollBackingRef.init(a, .{ .sublist = .{
        .parent = parent_items,
        .parent_backing = parent_backing,
        .from = new_from,
        .len = win_len,
        .exp_mod = counterNowOf(recv.List.mod_count),
    } });
    // Share the root list's structural counter so a modification of the parent
    // (not through this view) is observed as a ConcurrentModification by this
    // subList's iterators — matching Kotlin's SubList, which tracks root.modCount.
    const shared_mc = if (recv.List.mod_count) |mc| mc.clone() else try modCountFor(a, mutable);
    return ok(.{ .List = .{
        .items = try ValueList.init(a, window),
        .mutable = mutable,
        .enum_entries = false,
        .backing = backing.cell,
        .mod_count = shared_mc,
    } });
}

pub fn coll_list_plus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.plus")) {
        .items => |x| x,
        .err => |e| return e,
    };
    var out: std.ArrayList(Value) = .empty;
    try appendVL(&out, a, it);
    if (ctx.args.len < 2) return arityErr("plus requires an argument");
    const arg = ctx.args[1];
    switch (arg) {
        .List => |l| try appendVL(&out, a, l.items),
        .Set => |s| try appendVL(&out, a, s.items),
        .Range, .Sequence, .Array => {
            const xs = switch (try iterableItemsCtx(ctx, arg, "plus")) {
                .items => |x| x,
                .err => |e| return e,
            };
    defer if (runtime.freeScratch()) a.free(xs);
            try out.appendSlice(a, xs);
        },
        else => try out.append(a, arg),
    }
    return ok(try makeListBorrowed(a, out, false));
}

/// `Collection.plusElement(element)` always appends `element` as a single
/// element, even when it is itself a collection — unlike `plus`, which flattens
/// an Iterable/Array/Sequence argument.
pub fn coll_list_plus_element(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.plusElement")) {
        .items => |x| x,
        .err => |e| return e,
    };
    var out: std.ArrayList(Value) = .empty;
    try appendVL(&out, a, it);
    if (ctx.args.len < 2) return arityErr("plusElement requires an argument");
    try out.append(a, ctx.args[1]);
    return ok(try makeListBorrowed(a, out, false));
}

/// `Iterable<T>.minus` / `plus` — the STATIC-Iterable surface (returns a
/// List regardless of the runtime collection kind, as kotlinc resolves
/// for a receiver whose declared type is Iterable). Reads the receiver
/// through `iterableItems` and reuses the List core.
pub fn coll_iterable_minus(ctx: *CallCtx) Error!EvalResult {
    return iterableListOpAdapter(ctx, coll_list_minus, "Iterable.minus");
}

pub fn coll_iterable_plus(ctx: *CallCtx) Error!EvalResult {
    return iterableListOpAdapter(ctx, coll_list_plus, "Iterable.plus");
}

/// Adapt an arbitrary iterable receiver to the List-receiver core: the
/// receiver materializes to a fresh builtin List value, the remaining
/// args pass through.
fn iterableListOpAdapter(ctx: *CallCtx, comptime core: fn (*CallCtx) Error!EvalResult, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr(try fmt(a, "{s} requires a receiver", .{what}));
    if (ctx.args[0] == .List) return core(ctx);
    const items = switch (try iterableItems(a, ctx.args[0], what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(a, items);
    if (runtime.freeScratch()) a.free(items);
    const recv = try makeListFromArrayList(a, list, false);
    var new_args = try a.alloc(Value, ctx.args.len);
    defer if (runtime.freeScratch()) a.free(new_args);
    new_args[0] = recv;
    @memcpy(new_args[1..], ctx.args[1..]);
    var sub = ctx.*;
    sub.args = new_args;
    return core(&sub);
}

pub fn coll_list_minus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.minus")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("minus requires an argument");
    const arg = ctx.args[1];
    var removals: std.ArrayList(Value) = .empty;
    // `minus(elements: Collection/Array/Sequence)` removes every element that
    // is a member of `elements`; `minus(element)` removes only the first
    // occurrence of that single element.
    var is_collection = true;
    switch (arg) {
        .List => |l| try appendVL(&removals, a, l.items),
        .Set => |s| try appendVL(&removals, a, s.items),
        .Range, .Sequence, .Array => {
            const xs = switch (try iterableItemsCtx(ctx, arg, "minus")) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(xs);
            try removals.appendSlice(a, xs);
        },
        else => {
            is_collection = false;
            try removals.append(a, arg);
        },
    }
    var out: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| {
        if (is_collection) {
            if (!try containsBoxedH(ctx.host, ctx.out, removals.items, &v)) try out.append(a, v);
        } else if (indexOfBoxed(removals.items, &v)) |pos| {
            _ = removals.orderedRemove(pos);
        } else {
            try out.append(a, v);
        }
    }
    return ok(try makeListBorrowed(a, out, false));
}

pub fn coll_list_chunked(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.chunked")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or ctx.args[1] != .Int) return typeErr("chunked requires an Int size");
    const size_i = ctx.args[1].Int;
    if (size_i <= 0) {
        const msg = try fmt(a, "Size {d} must be greater than zero.", .{size_i});
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const size: usize = @intCast(size_i);
    const transform: ?Value = if (ctx.args.len > 2 and ctx.args[2] != .Null) ctx.args[2] else null;
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    var groups: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < items.len) {
        const end = @min(i + size, items.len);
        const chunk = try makeList(a, items[i..end], false);
        if (transform) |block| {
            const r = switch (try invoke(ctx, &block, &.{chunk})) {
                .value => |v| v,
                .err => |e| return e,
            };
            try groups.append(a, r);
        } else {
            try groups.append(a, chunk);
        }
        i += size;
    }
    return ok(try makeListFromArrayList(a, groups, false));
}

pub fn coll_list_windowed(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.windowed")) {
        .items => |x| x,
        .err => |e| return e,
    };
    // Peel a trailing callable as the `transform` (the `windowed(size, step,
    // partialWindows, transform)` overload). The scalar size/step/partialWindows
    // are then read positionally from the remaining args, so omitted middle
    // defaults (`windowed(2) { ... }`) bind correctly.
    var n = ctx.args.len;
    const transform: ?Value = if (n > 2 and isCallable(ctx.args[n - 1])) blk: {
        n -= 1;
        break :blk ctx.args[n];
    } else null;
    if (n < 2 or ctx.args[1] != .Int) return typeErr("windowed requires an Int size");
    const size_i = ctx.args[1].Int;
    if (size_i <= 0) {
        const msg = try fmt(a, "size {d} must be greater than zero.", .{size_i});
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const step_i: i64 = if (n <= 2) 1 else (if (ctx.args[2].isIntegral()) ctx.args[2].asI64().? else return typeErr("windowed step must be Int"));
    if (step_i <= 0) {
        const msg = try fmt(a, "step {d} must be greater than zero.", .{step_i});
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const partial_windows: bool = if (n <= 3) false else (if (ctx.args[3] == .Bool) ctx.args[3].Bool else return typeErr("windowed partialWindows must be Bool"));
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    const size: usize = @intCast(size_i);
    const step: usize = @intCast(step_i);
    var out: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < items.len) {
        const end = i + size;
        const window: ?Value = if (end <= items.len)
            try makeList(a, items[i..end], false)
        else if (partial_windows)
            try makeList(a, items[i..], false)
        else
            null;
        if (window) |w| {
            if (transform) |block| {
                const r = switch (try invoke(ctx, &block, &.{w})) {
                    .value => |v| v,
                    .err => |e| return e,
                };
                try out.append(a, r);
            } else {
                try out.append(a, w);
            }
        } else break;
        i += step;
    }
    return ok(try makeListFromArrayList(a, out, false));
}

pub fn coll_list_zip(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const lhs = switch (try recvListItems(a, ctx.args, "List.zip")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("zip requires a second collection");
    const rhs_val = ctx.args[1];
    const transform: ?Value = if (ctx.args.len > 2 and isZipTransform(ctx.args[2])) ctx.args[2] else null;
    var rhs: std.ArrayList(Value) = .empty;
    defer if (runtime.freeScratch()) rhs.deinit(a);
    switch (rhs_val) {
        .List => |l| try appendVL(&rhs, a, l.items),
        .Set => |s| try appendVL(&rhs, a, s.items),
        .Array => |arr| try appendArrItems(&rhs, a, arr),
        .Range => |r| {
            var rit = RangeIter.init(r.start, r.end, r.step, r.kind);
            while (rit.next()) |n| try rhs.append(a, Value.newInt(n));
        },
        else => {
            const rd = try display(a, rhs_val);
            return typeErr(try fmt(a, "zip requires a collection, got {s}", .{rd}));
        },
    }
    const lhs_items = try snapshotItems(a, lhs);
    defer if (runtime.freeScratch()) a.free(lhs_items);
    var result: std.ArrayList(Value) = .empty;
    const n = @min(lhs_items.len, rhs.items.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (transform) |t| {
            const r = switch (try invoke(ctx, &t, &.{ lhs_items[i], rhs.items[i] })) {
                .value => |v| v,
                .err => |e| return e,
            };
            try result.append(a, r);
        } else {
            lhs_items[i].retain();
            rhs.items[i].retain();
            try result.append(a, try makePair(a, lhs_items[i], rhs.items[i]));
        }
    }
    return ok(try makeListFromArrayList(a, result, false));
}

fn isZipTransform(v: Value) bool {
    return switch (v) {
        // Any callable third argument is the transform: a lambda, a bound or
        // user method, a function/intrinsic reference, a constructor reference
        // (`::SomeClass` evaluates to a `.Class`), or a functional Instance.
        .IrClosure, .BoundMethod, .BoundUserMethod, .Instance, .Class, .Function, .Intrinsic => true,
        else => false,
    };
}

// =====================================================================
// Set ops
// =====================================================================

fn setPlusImpl(ctx: *CallCtx, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    var out: std.ArrayList(Value) = .empty;
    try appendVL(&out, a, it);
    if (ctx.args.len < 2) return arityErr("plus requires an argument");
    const arg = ctx.args[1];
    switch (arg) {
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            for (g.get().items) |v| {
                if (!containsBoxed(out.items, &v)) try out.append(a, v);
            }
        },
        .Set => |s| {
            const g = s.items.borrow();
            defer g.deinit();
            for (g.get().items) |v| {
                if (!containsBoxed(out.items, &v)) try out.append(a, v);
            }
        },
        .Array, .Range, .Sequence => {
            const xs = switch (try iterableItemsCtx(ctx, arg, what)) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(xs);
            for (xs) |v| {
                if (!containsBoxed(out.items, &v)) try out.append(a, v);
            }
        },
        else => {
            if (!containsBoxed(out.items, &arg)) try out.append(a, arg);
        },
    }
    // `out` holds borrowed elements (snapshot/args); the new set owns one ref
    // per element, so retain each before adopting the backing.
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return ok(.{ .Set = .{ .items = try ValueList.init(a, out), .mutable = false, .backing = null } });
}

pub fn coll_set_plus(ctx: *CallCtx) Error!EvalResult {
    return setPlusImpl(ctx, "Set.plus");
}
pub fn coll_set_union(ctx: *CallCtx) Error!EvalResult {
    return setPlusImpl(ctx, "Set.plus");
}

pub fn coll_set_minus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.minus")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("minus requires an argument");
    const arg = ctx.args[1];
    var removals: std.ArrayList(Value) = .empty;
    defer if (runtime.freeScratch()) removals.deinit(a);
    switch (arg) {
        .List => |l| try appendVL(&removals, a, l.items),
        .Set => |s| try appendVL(&removals, a, s.items),
        .Array, .Range, .Sequence => {
            const xs = switch (try iterableItemsCtx(ctx, arg, "minus")) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(xs);
            try removals.appendSlice(a, xs);
        },
        else => try removals.append(a, arg),
    }
    var out: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| {
        if (!try containsBoxedH(ctx.host, ctx.out, removals.items, &v)) try out.append(a, v);
    }
    // `out` holds borrowed elements (snapshot/args); the new set owns one ref
    // per element, so retain each before adopting the backing.
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return ok(.{ .Set = .{ .items = try ValueList.init(a, out), .mutable = false, .backing = null } });
}
pub fn coll_set_subtract(ctx: *CallCtx) Error!EvalResult {
    return coll_set_minus(ctx);
}

pub fn coll_set_intersect(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.intersect")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("intersect requires an argument");
    const arg = ctx.args[1];
    var other: std.ArrayList(Value) = .empty;
    defer if (runtime.freeScratch()) other.deinit(a);
    switch (arg) {
        .List => |l| try appendVL(&other, a, l.items),
        .Set => |s| try appendVL(&other, a, s.items),
        else => return typeErr("intersect requires a collection"),
    }
    var out: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| {
        if (containsBoxed(other.items, &v)) try out.append(a, v);
    }
    // `out` holds borrowed elements (snapshot/args); the new set owns one ref
    // per element, so retain each before adopting the backing.
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return ok(.{ .Set = .{ .items = try ValueList.init(a, out), .mutable = false, .backing = null } });
}

pub fn coll_set_size(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvSetItems(ctx.allocator, ctx.args, "Set.size")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(Value.newInt(@intCast(listLen(it))));
}
pub fn coll_set_is_empty(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvSetItems(ctx.allocator, ctx.args, "Set.isEmpty")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = listLen(it) == 0 });
}
pub fn coll_set_is_not_empty(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvSetItems(ctx.allocator, ctx.args, "Set.isNotEmpty")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = listLen(it) != 0 });
}
pub fn coll_set_contains(ctx: *CallCtx) Error!EvalResult {
    const it = switch (try recvSetItems(ctx.allocator, ctx.args, "Set.contains")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("contains requires an argument");
    const needle = ctx.args[1];
    const items = try snapshotItems(ctx.allocator, it);
    defer if (runtime.freeScratch()) ctx.allocator.free(items);
    return ok(.{ .Bool = try containsBoxedH(ctx.host, ctx.out, items, &needle) });
}

pub fn coll_set_sorted(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.sorted")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const copy = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(copy);
    if (try sortValuesNatural(a, copy)) |e| return e;
    return ok(try makeList(a, copy, false));
}
pub fn coll_set_sorted_descending(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const v = try coll_set_sorted(ctx);
    if (v == .err) return v;
    const items = try snapshotItems(a, v.ok.List.items);
    defer if (runtime.freeScratch()) a.free(items);
    std.mem.reverse(Value, items);
    return ok(try makeList(a, items, false));
}
pub fn coll_set_to_string(ctx: *CallCtx) Error!EvalResult {
    return collToString(ctx, "Set.toString");
}

pub fn coll_mut_set_add(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.add")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("add requires an argument");
    const arg = ctx.args[1];
    const g = it.borrowMut();
    defer g.deinit();
    if (containsBoxed(g.get().items, &arg)) return ok(.{ .Bool = false });
    // The set owns one reference per element; retain the borrowed argument.
    if (runtime.reclaimEnabled()) arg.retain();
    try g.get().append(a, arg);
    return ok(.{ .Bool = true });
}
pub fn coll_mut_set_remove(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.remove")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("remove requires an argument");
    const arg = ctx.args[1];
    var removed = false;
    {
        const g = it.borrowMut();
        defer g.deinit();
        if (indexOfBoxed(g.get().items, &arg)) |pos| {
            const gone = g.get().orderedRemove(pos);
            // remove(element): Boolean discards the element; drop the
            // collection's owned reference to it.
            if (runtime.reclaimEnabled()) gone.release(a);
            removed = true;
        }
    }
    if (removed) syncMapView(a, ctx.args[0]);
    return ok(.{ .Bool = removed });
}
pub fn coll_mut_set_clear(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.clear")) {
        .items => |x| x,
        .err => |e| return e,
    };
    {
        const g = it.borrowMut();
        defer g.deinit();
        // clear() discards every element; drop the set's owned references.
        if (runtime.reclaimEnabled()) for (g.get().items) |v| v.release(a);
        g.get().clearRetainingCapacity();
    }
    syncMapView(a, ctx.args[0]);
    return ok(Value.Unit);
}

fn collectColl(a: Allocator, v: ?Value) Error!?[]Value {
    if (v) |val| {
        switch (val) {
            .List => |l| return try snapshotItems(a, l.items),
            .Set => |s| return try snapshotItems(a, s.items),
            .Array => |arr| return try arr.snapshot(a),
            else => {},
        }
    }
    return null;
}

/// A removeAll/retainAll argument that is a lambda/function reference (not a
/// collection or a callable user Collection instance) is the predicate form
/// `removeAll { (T) -> Boolean }`.
fn isPredicateArg(v: Value) bool {
    return switch (v) {
        .IrClosure, .BoundMethod, .BoundUserMethod, .Function, .Intrinsic => true,
        else => false,
    };
}

/// `MutableCollection.removeAll/retainAll { predicate }`: keep an element when
/// `retain == predicate(element)`.
fn mutCollRemoveRetainPred(ctx: *CallCtx, items: ValueList, recv: Value, retain: bool) Error!EvalResult {
    const a = ctx.allocator;
    const pred = ctx.args[1];
    const snap = try snapshotItems(a, items);
    defer if (runtime.freeScratch()) a.free(snap);
    const keep = try a.alloc(bool, snap.len);
    defer if (runtime.freeScratch()) a.free(keep);
    for (snap, 0..) |v, i| {
        const rv = switch (try invoke(ctx, &pred, &.{v})) {
            .value => |x| x,
            .err => |e| return e,
        };
        const truth = rv == .Bool and rv.Bool;
        keep[i] = if (retain) truth else !truth;
    }
    var changed = false;
    {
        const g = items.borrowMut();
        defer g.deinit();
        const list = g.get();
        const before = list.items.len;
        var w: usize = 0;
        for (list.items, 0..) |v, i| {
            const k = if (i < keep.len) keep[i] else true;
            if (k) {
                list.items[w] = v;
                w += 1;
            } else if (runtime.reclaimEnabled()) {
                v.release(a);
            }
        }
        list.shrinkRetainingCapacity(w);
        changed = list.items.len != before;
    }
    if (changed) syncMapView(a, recv);
    return ok(.{ .Bool = changed });
}

fn mutCollRemoveRetain(ctx: *CallCtx, items: ValueList, recv: Value, what: []const u8, retain: bool, allow_array: bool) Error!EvalResult {
    const a = ctx.allocator;
    const arg = if (ctx.args.len > 1) ctx.args[1] else Value.Null;
    if (isPredicateArg(arg)) return mutCollRemoveRetainPred(ctx, items, recv, retain);
    _ = allow_array; // `removeAll`/`retainAll` accept an Array overload too.
    const other = blk: {
        switch (arg) {
            .List => |l| break :blk try snapshotItems(a, l.items),
            .Set => |s| break :blk try snapshotItems(a, s.items),
            .Array => |arr| break :blk try arr.snapshot(a),
            // Any other Iterable (a `.Sequence`, or an `.Instance` exposing
            // `iterator()`): drain it.
            else => break :blk switch (try iterableItemsCtx(ctx, arg, what)) {
                .items => |x| x,
                .err => |e| return e,
            },
        }
    };
    var changed = false;
    {
        const g = it_mut: {
            break :it_mut items.borrowMut();
        };
        defer g.deinit();
        const list = g.get();
        const before = list.items.len;
        var w: usize = 0;
        var r: usize = 0;
        while (r < list.items.len) : (r += 1) {
            const v = list.items[r];
            const present = containsBoxed(other, &v);
            const keep = if (retain) present else !present;
            if (keep) {
                list.items[w] = v;
                w += 1;
            } else if (runtime.reclaimEnabled()) {
                // Dropped element: release the collection's owned reference.
                v.release(a);
            }
        }
        list.shrinkRetainingCapacity(w);
        changed = list.items.len != before;
    }
    if (changed) syncMapView(a, recv);
    return ok(.{ .Bool = changed });
}

pub fn coll_mut_set_remove_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.removeAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return mutCollRemoveRetain(ctx, it, ctx.args[0], "removeAll", false, true);
}
pub fn coll_mut_set_retain_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.retainAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return mutCollRemoveRetain(ctx, it, ctx.args[0], "retainAll", true, true);
}

// =====================================================================
// Map ops
// =====================================================================

pub fn coll_map_to_mutable_map(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Map) return typeErr("toMutableMap requires a Map receiver");
    return ok(try makeMap(a, try snapshotEntries(a, ctx.args[0].Map.entries), true));
}
pub fn coll_map_to_map(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Map) return typeErr("toMap requires a Map receiver");
    // `toMap(destination)`: merge into the supplied mutable map and
    // return IT (live, mutable), never a read-only snapshot.
    if (ctx.args.len >= 2 and ctx.args[1] == .Map) {
        const src = try snapshotEntries(a, ctx.args[0].Map.entries);
        defer if (runtime.freeScratch()) a.free(src);
        const dest = ctx.args[1];
        const g = dest.Map.entries.borrowMut();
        defer g.deinit();
        for (src) |kv| {
            var found = false;
            for (g.get().pairs.items) |*slot| {
                if (eqBoxed(&slot.key, &kv.key)) {
                    if (runtime.reclaimEnabled()) {
                        kv.value.retain();
                        slot.value.release(a);
                    }
                    slot.value = kv.value;
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (runtime.reclaimEnabled()) {
                    kv.key.retain();
                    kv.value.retain();
                }
                try g.get().pairs.append(a, kv);
                try g.get().noteAppended(a, g.get().pairs.items.len - 1);
            }
        }
        return ok(dest);
    }
    return ok(try makeMap(a, try snapshotEntries(a, ctx.args[0].Map.entries), false));
}

pub fn coll_map_plus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.plus")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    var out: std.ArrayList(MapPair) = .empty;
    try out.appendSlice(a, try snapshotEntries(a, entries));
    if (ctx.args.len < 2) return arityErr("plus requires an argument");
    const arg = ctx.args[1];
    switch (arg) {
        .Pair => try out.append(a, .{ .key = arg.Pair.first.asPtr().*, .value = arg.Pair.second.asPtr().* }),
        .Map => |e| try out.appendSlice(a, try snapshotEntries(a, e.entries)),
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            for (g.get().items) |p| {
                if (p == .Pair) try out.append(a, .{ .key = p.Pair.first.asPtr().*, .value = p.Pair.second.asPtr().* });
            }
        },
        .Set => |s| {
            const g = s.items.borrow();
            defer g.deinit();
            for (g.get().items) |p| {
                if (p == .Pair) try out.append(a, .{ .key = p.Pair.first.asPtr().*, .value = p.Pair.second.asPtr().* });
            }
        },
        .Array, .Sequence, .Range => {
            const items = switch (try iterableItemsCtx(ctx, arg, "Map.plus")) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(items);
            for (items) |p| {
                if (p == .Pair) try out.append(a, .{ .key = p.Pair.first.asPtr().*, .value = p.Pair.second.asPtr().* });
            }
        },
        else => return typeErr("Map.plus expects a Pair, Map, or Iterable<Pair>"),
    }
    return ok(try makeMapH(ctx.host, ctx.out, a, out.items, false));
}

pub fn coll_map_minus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.minus")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("minus requires an argument");
    const arg = ctx.args[1];
    var keys: std.ArrayList(Value) = .empty;
    switch (arg) {
        .List => |l| try appendVL(&keys, a, l.items),
        .Set => |s| try appendVL(&keys, a, s.items),
        .Array, .Sequence, .Range => {
            const items = switch (try iterableItemsCtx(ctx, arg, "Map.minus")) {
                .items => |x| x,
                .err => |e| return e,
            };
            defer if (runtime.freeScratch()) a.free(items);
            try keys.appendSlice(a, items);
        },
        else => try keys.append(a, arg),
    }
    var out: std.ArrayList(MapPair) = .empty;
    const src = try snapshotEntries(a, entries);
    for (src) |kv| {
        if (!containsBoxed(keys.items, &kv.key)) try out.append(a, kv);
    }
    return ok(try makeMapH(ctx.host, ctx.out, a, out.items, false));
}

pub fn coll_map_size(ctx: *CallCtx) Error!EvalResult {
    const entries = switch (try recvMapEntries(ctx.allocator, ctx.args, "Map.size")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    return ok(Value.newInt(@intCast(mapLen(entries))));
}
pub fn coll_map_is_empty(ctx: *CallCtx) Error!EvalResult {
    const entries = switch (try recvMapEntries(ctx.allocator, ctx.args, "Map.isEmpty")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = mapLen(entries) == 0 });
}
pub fn coll_map_is_not_empty(ctx: *CallCtx) Error!EvalResult {
    const entries = switch (try recvMapEntries(ctx.allocator, ctx.args, "Map.isNotEmpty")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    return ok(.{ .Bool = mapLen(entries) != 0 });
}

/// Index of `key`, honoring a class-instance key's custom `equals`.
fn mapKeyIndex(ctx: *CallCtx, entries: MapEntries, key: Value) Error!?usize {
    if (key != .Instance) {
        // `find` builds/uses the hash index (O(1) for large maps), falling back
        // to a linear scan for small maps or non-hashable keys.
        const g = entries.borrowMut();
        defer g.deinit();
        return try g.get().find(ctx.allocator, &key);
    }
    const keys = blk: {
        const g = entries.borrow();
        defer g.deinit();
        var ks = try ctx.allocator.alloc(Value, g.get().pairs.items.len);
        for (g.get().pairs.items, 0..) |kv, i| ks[i] = kv.key;
        break :blk ks;
    };
    // Scratch key snapshot (the key Values themselves stay owned by the map).
    defer if (runtime.freeScratch()) ctx.allocator.free(keys);
    for (keys, 0..) |k, i| {
        if (try ctx.host.invokeMethod(&k, "equals", &.{key}, ctx.out)) |m| {
            if (m == .ok and m.ok == .Bool) {
                if (m.ok.Bool) return i;
                continue;
            }
        }
        if (eqBoxed(&k, &key)) return i;
    }
    return null;
}

pub fn coll_map_get(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.get")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("get requires a key");
    const key = ctx.args[1];
    if (try mapKeyIndex(ctx, entries, key)) |i| {
        const g = entries.borrow();
        defer g.deinit();
        if (i < g.get().pairs.items.len) return okElem(g.get().pairs.items[i].value);
    }
    return ok(Value.Null);
}
pub fn coll_map_contains_key(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.containsKey")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("containsKey requires a key");
    const key = ctx.args[1];
    return ok(.{ .Bool = (try mapKeyIndex(ctx, entries, key)) != null });
}
pub fn coll_map_contains_value(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.containsValue")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("containsValue requires a value");
    const value = ctx.args[1];
    const g = entries.borrow();
    defer g.deinit();
    for (g.get().pairs.items) |kv| {
        if (eqBoxed(&kv.value, &value)) return ok(.{ .Bool = true });
    }
    return ok(.{ .Bool = false });
}

pub fn coll_map_keys(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    // A read-only map's keys view is read-only too, mirroring `entries`.
    const writable = ctx.args.len > 0 and ctx.args[0] == .Map and ctx.args[0].Map.mutable;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.keys")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    var keys: std.ArrayList(Value) = .empty;
    {
        const g = entries.borrow();
        defer g.deinit();
        // The keys view owns one ref per element (its teardown releases them
        // via releaseValueList regardless of `backing`); retain each borrowed
        // key, mirroring `coll_map_entries`.
        for (g.get().pairs.items) |kv| {
            if (runtime.reclaimEnabled()) kv.key.retain();
            try keys.append(a, kv.key);
        }
    }
    const backing = try CollBackingRef.init(a, .{ .map = .{ .entries = entries, .kind = .Keys } });
    return ok(.{ .Set = .{ .items = try ValueList.init(a, keys), .mutable = writable, .backing = backing.cell, .mod_count = entriesModCountClone(entries) } });
}
pub fn coll_map_values(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    // A read-only map's values view is read-only too, mirroring `entries`.
    const writable = ctx.args.len > 0 and ctx.args[0] == .Map and ctx.args[0].Map.mutable;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.values")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    var values: std.ArrayList(Value) = .empty;
    {
        const g = entries.borrow();
        defer g.deinit();
        // The values view owns one ref per element; retain each borrowed value.
        for (g.get().pairs.items) |kv| {
            if (runtime.reclaimEnabled()) kv.value.retain();
            try values.append(a, kv.value);
        }
    }
    const backing = try CollBackingRef.init(a, .{ .map = .{ .entries = entries, .kind = .Values } });
    return ok(.{ .List = .{ .items = try ValueList.init(a, values), .mutable = writable, .enum_entries = false, .backing = backing.cell, .mod_count = entriesModCountClone(entries) } });
}
pub fn coll_map_entries(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    // A read-only map's entries are read-only too: entries carry no
    // backing (setValue throws) and the view set refuses mutation.
    const writable = ctx.args.len > 0 and ctx.args[0] == .Map and ctx.args[0].Map.mutable;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.entries")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    var map_entries: std.ArrayList(Value) = .empty;
    const stamp = entriesCounterNow(entries);
    {
        const g = entries.borrow();
        defer g.deinit();
        for (g.get().pairs.items) |kv| {
            kv.key.retain();
            kv.value.retain();
            try map_entries.append(a, .{ .MapEntry = .{
                .key = try Value.boxRef(a, kv.key),
                .value = try Value.boxRef(a, kv.value),
                .backing = if (writable) entries else null,
                .exp_mod = stamp,
            } });
        }
    }
    const backing = try CollBackingRef.init(a, .{ .map = .{ .entries = entries, .kind = .Entries } });
    return ok(.{ .Set = .{ .items = try ValueList.init(a, map_entries), .mutable = writable, .backing = backing.cell, .mod_count = entriesModCountClone(entries) } });
}
pub fn coll_map_to_string(ctx: *CallCtx) Error!EvalResult {
    return collToString(ctx, "Map.toString");
}

pub fn coll_mut_map_put(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "MutableMap.put")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    const _mb = mapEntriesLen(entries);
    defer mapStructuralBump(entries, _mb);
    if (ctx.args.len < 2) return arityErr("put requires a key");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("put requires a value");
    const value = ctx.args[2];
    if (try mapKeyIndex(ctx, entries, key)) |i| {
        const g = entries.borrowMut();
        defer g.deinit();
        // The map owns the new value; the replaced value's ownership transfers
        // to the returned `prev` (Kotlin `put` returns the previous value).
        if (runtime.reclaimEnabled()) value.retain();
        const prev = g.get().pairs.items[i].value;
        g.get().pairs.items[i].value = value;
        return ok(prev);
    }
    const g = entries.borrowMut();
    defer g.deinit();
    // The map takes ownership of one ref to the stored key and value.
    if (runtime.reclaimEnabled()) {
        key.retain();
        value.retain();
    }
    try g.get().pairs.append(a, .{ .key = key, .value = value });
    try g.get().noteAppended(a, g.get().pairs.items.len - 1);
    return ok(Value.Null);
}
pub fn coll_mut_map_remove(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "MutableMap.remove")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    const _mb = mapEntriesLen(entries);
    defer mapStructuralBump(entries, _mb);
    if (ctx.args.len < 2) return arityErr("remove requires a key");
    const key = ctx.args[1];
    if (try mapKeyIndex(ctx, entries, key)) |pos| {
        const g = entries.borrowMut();
        defer g.deinit();
        const kv = g.get().pairs.orderedRemove(pos);
        g.get().invalidate();
        // `remove` transfers the entry out of the map: the value's owned ref
        // moves to the returned result (no retain), and the removed key — which
        // the map owned and which is not returned — must be released.
        if (runtime.reclaimEnabled()) kv.key.release(a);
        return ok(kv.value);
    }
    return ok(Value.Null);
}
pub fn coll_mut_map_clear(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const entries = switch (try recvMapEntries(ctx.allocator, ctx.args, "MutableMap.clear")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    const _mb = mapEntriesLen(entries);
    defer mapStructuralBump(entries, _mb);
    const g = entries.borrowMut();
    defer g.deinit();
    g.get().pairs.clearRetainingCapacity();
    g.get().invalidate();
    return ok(Value.Unit);
}

// ----- Map scope helpers (merge / putIfAbsent / replace / compute*) -----

fn mutMapEntriesRc(a: Allocator, recv: Value, who: []const u8) Error!MapEntriesOutcome {
    if (recv == .Map) return .{ .entries = recv.Map.entries };
    return .{ .err = typeErr(try fmt(a, "{s} requires a MutableMap receiver", .{who})) };
}

fn mapFind(entries: MapEntries, key: Value) ?Value {
    const g = entries.borrow();
    defer g.deinit();
    for (g.get().pairs.items) |kv| {
        if (eqBoxed(&kv.key, &key)) return kv.value;
    }
    return null;
}

fn mapSet(a: Allocator, entries: MapEntries, key: Value, value: Value) Error!void {
    const g = entries.borrowMut();
    defer g.deinit();
    for (g.get().pairs.items) |*kv| {
        if (eqBoxed(&kv.key, &key)) {
            // Replace: the map owns the new value and drops the replaced one
            // (the existing key is kept; the new key arg is discarded).
            if (runtime.reclaimEnabled()) {
                value.retain();
                kv.value.release(a);
            }
            kv.value = value;
            return;
        }
    }
    // Append: the map takes ownership of one ref to the stored key and value.
    if (runtime.reclaimEnabled()) {
        key.retain();
        value.retain();
    }
    try g.get().pairs.append(a, .{ .key = key, .value = value });
    try g.get().noteAppended(a, g.get().pairs.items.len - 1);
}

fn mapRemoveKey(entries: MapEntries, key: Value) void {
    const g = entries.borrowMut();
    defer g.deinit();
    for (g.get().pairs.items, 0..) |kv, i| {
        if (eqBoxed(&kv.key, &key)) {
            _ = g.get().pairs.orderedRemove(i);
            g.get().invalidate();
            return;
        }
    }
}

pub fn map_merge(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "merge")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("merge requires a key");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("merge requires a value");
    const value = ctx.args[2];
    if (ctx.args.len < 4) return arityErr("merge requires a remapping block");
    const block = ctx.args[3];
    const existing = mapFind(entries, key);
    const new_val = if (existing) |old| switch (try invoke(ctx, &block, &.{ old, value })) {
        .value => |v| v,
        .err => |e| return e,
    } else value;
    if (new_val == .Null) {
        mapRemoveKey(entries, key);
    } else {
        try mapSet(a, entries, key, new_val);
    }
    return ok(new_val);
}

pub fn map_put_if_absent(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "putIfAbsent")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("putIfAbsent requires a key");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("putIfAbsent requires a value");
    const value = ctx.args[2];
    // The present value is borrowed from the map; retain before returning it.
    if (mapFind(entries, key)) |old| return okElem(old);
    try mapSet(a, entries, key, value);
    return ok(Value.Null);
}

pub fn map_replace(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "replace")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("replace requires a key");
    const key = ctx.args[1];
    if (ctx.args.len >= 4) {
        const old = ctx.args[2];
        const new = ctx.args[3];
        if (mapFind(entries, key)) |cur| {
            if (eqBoxed(&cur, &old)) {
                try mapSet(a, entries, key, new);
                return ok(.{ .Bool = true });
            }
        }
        return ok(.{ .Bool = false });
    }
    if (ctx.args.len < 3) return arityErr("replace requires a value");
    const value = ctx.args[2];
    if (mapFind(entries, key)) |old| {
        // `replace` returns the previous value: retain it before `mapSet`
        // releases the map's reference, so the returned result carries an
        // owned ref instead of a freed one.
        if (runtime.reclaimEnabled()) old.retain();
        try mapSet(a, entries, key, value);
        return ok(old);
    }
    return ok(Value.Null);
}

pub fn map_compute_if_absent(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "computeIfAbsent")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("computeIfAbsent requires a key");
    const key = ctx.args[1];
    // The present value is borrowed from the map; the register adopting the
    // result must own its ref, so retain before returning.
    if (mapFind(entries, key)) |v| return okElem(v);
    if (ctx.args.len < 3) return arityErr("computeIfAbsent requires a block");
    const block = ctx.args[2];
    const v = switch (try invoke(ctx, &block, &.{key})) {
        .value => |x| x,
        .err => |e| return e,
    };
    try mapSet(a, entries, key, v);
    return ok(v);
}

pub fn map_compute_if_present(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "computeIfPresent")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("computeIfPresent requires a key");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("computeIfPresent requires a block");
    const block = ctx.args[2];
    const old = mapFind(entries, key) orelse return ok(Value.Null);
    const new_val = switch (try invoke(ctx, &block, &.{ key, old })) {
        .value => |x| x,
        .err => |e| return e,
    };
    if (new_val == .Null) {
        mapRemoveKey(entries, key);
    } else {
        try mapSet(a, entries, key, new_val);
    }
    return ok(new_val);
}

pub fn map_compute(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try mutMapEntriesRc(a, ctx.args[0], "compute")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("compute requires a key");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("compute requires a block");
    const block = ctx.args[2];
    const old = mapFind(entries, key) orelse Value.Null;
    const new_val = switch (try invoke(ctx, &block, &.{ key, old })) {
        .value => |x| x,
        .err => |e| return e,
    };
    if (new_val == .Null) {
        mapRemoveKey(entries, key);
    } else {
        try mapSet(a, entries, key, new_val);
    }
    return ok(new_val);
}

// =====================================================================
// Pair / Triple members
// =====================================================================

fn recvPair(a: Allocator, args: []const Value, what: []const u8) Error!union(enum) { pair: Value, err: EvalResult } {
    if (args.len > 0 and args[0] == .Pair) return .{ .pair = args[0] };
    return .{ .err = typeErr(try fmt(a, "{s} requires a Pair receiver", .{what})) };
}

pub fn pair_first(ctx: *CallCtx) Error!EvalResult {
    const p = switch (try recvPair(ctx.allocator, ctx.args, "Pair.first")) {
        .pair => |v| v,
        .err => |e| return e,
    };
    const out = p.Pair.first.asPtr().*;
    out.retain();
    return ok(out);
}
pub fn pair_second(ctx: *CallCtx) Error!EvalResult {
    const p = switch (try recvPair(ctx.allocator, ctx.args, "Pair.second")) {
        .pair => |v| v,
        .err => |e| return e,
    };
    const out = p.Pair.second.asPtr().*;
    out.retain();
    return ok(out);
}
pub fn pair_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const p = switch (try recvPair(a, ctx.args, "Pair.toString")) {
        .pair => |v| v,
        .err => |e| return e,
    };
    const buf = try display(a, p);
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}
pub fn pair_to_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const p = switch (try recvPair(a, ctx.args, "Pair.toList")) {
        .pair => |v| v,
        .err => |e| return e,
    };
    return ok(try makeList(a, &.{ p.Pair.first.asPtr().*, p.Pair.second.asPtr().* }, false));
}

fn recvTriple(a: Allocator, args: []const Value, what: []const u8) Error!union(enum) { triple: Value, err: EvalResult } {
    if (args.len > 0 and args[0] == .Triple) return .{ .triple = args[0] };
    return .{ .err = typeErr(try fmt(a, "{s} requires a Triple receiver", .{what})) };
}

pub fn coll_triple_ctor(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len != 3) return arityErr("Triple expects 3 arguments");
    ctx.args[0].retain();
    ctx.args[1].retain();
    ctx.args[2].retain();
    return ok(try makeTriple(ctx.allocator, ctx.args[0], ctx.args[1], ctx.args[2]));
}
pub fn triple_first(ctx: *CallCtx) Error!EvalResult {
    const t = switch (try recvTriple(ctx.allocator, ctx.args, "Triple.first")) {
        .triple => |v| v,
        .err => |e| return e,
    };
    const out = t.Triple.first.asPtr().*;
    out.retain();
    return ok(out);
}
pub fn triple_second(ctx: *CallCtx) Error!EvalResult {
    const t = switch (try recvTriple(ctx.allocator, ctx.args, "Triple.second")) {
        .triple => |v| v,
        .err => |e| return e,
    };
    const out = t.Triple.second.asPtr().*;
    out.retain();
    return ok(out);
}
pub fn triple_third(ctx: *CallCtx) Error!EvalResult {
    const t = switch (try recvTriple(ctx.allocator, ctx.args, "Triple.third")) {
        .triple => |v| v,
        .err => |e| return e,
    };
    const out = t.Triple.third.asPtr().*;
    out.retain();
    return ok(out);
}
pub fn triple_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const t = switch (try recvTriple(a, ctx.args, "Triple.toString")) {
        .triple => |v| v,
        .err => |e| return e,
    };
    const buf = try display(a, t);
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}
pub fn triple_to_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const t = switch (try recvTriple(a, ctx.args, "Triple.toList")) {
        .triple => |v| v,
        .err => |e| return e,
    };
    return ok(try makeList(a, &.{ t.Triple.first.asPtr().*, t.Triple.second.asPtr().*, t.Triple.third.asPtr().* }, false));
}

// =====================================================================
// Additional List ops
// =====================================================================

pub fn coll_list_flatten(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.flatten")) {
        .items => |x| x,
        .err => |e| return e,
    };
    var out: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| {
        switch (v) {
            .List => |l| try appendVL(&out, a, l.items),
            .Set => |s| try appendVL(&out, a, s.items),
            // Any other inner iterable (a range, array, sequence, map, or user
            // Iterable) is drained through the shared helper, which retains each
            // element it yields.
            else => {
                const inner = switch (try iterableItemsCtx(ctx, v, "flatten")) {
                    .items => |x| x,
                    .err => |e| return e,
                };
                defer if (runtime.freeScratch()) a.free(inner);
                try out.appendSlice(a, inner);
            },
        }
    }
    return ok(try makeListBorrowed(a, out, false));
}

pub fn coll_list_unzip(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.unzip")) {
        .items => |x| x,
        .err => |e| return e,
    };
    var firsts: std.ArrayList(Value) = .empty;
    var seconds: std.ArrayList(Value) = .empty;
    const src = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(src);
    for (src) |v| {
        if (v != .Pair) return typeErr("unzip requires List<Pair<A, B>>");
        try firsts.append(a, v.Pair.first.asPtr().*);
        try seconds.append(a, v.Pair.second.asPtr().*);
    }
    return ok(try makePair(a, try makeListBorrowed(a, firsts, false), try makeListBorrowed(a, seconds, false)));
}

pub fn coll_list_contains_all(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.containsAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const other = (try collectColl(a, if (ctx.args.len > 1) ctx.args[1] else null)) orelse
        return typeErr("containsAll requires a collection");
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    for (other) |o| {
        if (!try containsBoxedH(ctx.host, ctx.out, items, &o)) return ok(.{ .Bool = false });
    }
    return ok(.{ .Bool = true });
}

pub fn coll_list_to_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.toList")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeListVL(a, it, false));
}
pub fn coll_list_to_mutable_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.toMutableList")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeListVL(a, it, true));
}
pub fn coll_list_to_set(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.toSet")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    return ok(try makeSetH(ctx.host, ctx.out, a, items, false));
}
pub fn coll_list_to_mutable_set(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.toMutableSet")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeSetVL(a, it, true));
}

fn withIndexImpl(ctx: *CallCtx, items: []const Value) Error!Value {
    const a = ctx.allocator;
    var indexed: std.ArrayList(Value) = .empty;
    for (items, 0..) |v, i| {
        v.retain();
        const id = ctx.host.allocInstanceId();
        const fields = [_]InstanceData.Field{
            .{ .name = "index", .value = Value.newInt(@intCast(i)) },
            .{ .name = "value", .value = v },
        };
        try indexed.append(a, try ctx.host.newSynthInstance("kotlin.collections.IndexedValue", id, &fields));
    }
    return makeListFromArrayList(a, indexed, false);
}

pub fn coll_list_with_index(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "List.withIndex")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try withIndexImpl(ctx, try snapshotItems(a, it)));
}
pub fn coll_array_with_index(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("Array.withIndex requires a receiver");
    const items = switch (try iterableItems(a, ctx.args[0], "Array.withIndex")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    return ok(try withIndexImpl(ctx, items));
}

pub fn coll_mut_list_add_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    // `addAll` bumps the counter even when the argument is empty (JVM
    // `ArrayList.addAll` touches modCount via ensureCapacity before the
    // size check), so a live iterator fails fast afterwards.
    defer bumpModCount(&ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.addAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("addAll requires an argument");
    // Indexed overload `addAll(index: Int, elements)`: the collection is the
    // third argument and is inserted at `index` rather than appended.
    const indexed = ctx.args.len >= 3 and ctx.args[1] == .Int;
    const arg = if (indexed) ctx.args[2] else ctx.args[1];
    var to_add: []Value = undefined;
    switch (arg) {
        .List => |l| to_add = try snapshotItems(a, l.items),
        .Set => |s| to_add = try snapshotItems(a, s.items),
        // `MutableCollection<in T>.addAll(elements: Array<out T>)`.
        .Array => |arr| to_add = try arr.snapshot(a),
        // `addAll(elements: Sequence<T>)` and `addAll(elements: Iterable<T>)`
        // over a lazy sequence or a user/anonymous iterable.
        else => to_add = switch (try iterableItemsCtx(ctx, arg, "addAll")) {
            .items => |x| x,
            .err => |e| return e,
        },
    }
    // `to_add` is a shallow `snapshotItems` dupe; `appendSlice` copies its
    // elements into the list, so the dupe spine is scratch — free it on exit.
    defer if (runtime.freeScratch()) a.free(to_add);
    const changed = to_add.len != 0;
    const g = it.borrowMut();
    defer g.deinit();
    // The list owns one ref to each element it stores.
    if (runtime.reclaimEnabled()) for (to_add) |v| v.retain();
    if (indexed) {
        const idx: usize = @min(@as(usize, @intCast(@max(ctx.args[1].Int, 0))), g.get().items.len);
        try g.get().insertSlice(a, idx, to_add);
    } else {
        try g.get().appendSlice(a, to_add);
    }
    return ok(.{ .Bool = changed });
}

pub fn coll_mut_list_remove(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.remove")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("remove requires an argument");
    const arg = ctx.args[1];
    var removed = false;
    {
        const g = it.borrowMut();
        defer g.deinit();
        if (indexOfBoxed(g.get().items, &arg)) |pos| {
            const gone = g.get().orderedRemove(pos);
            // remove(element): Boolean discards the element; drop the
            // collection's owned reference to it.
            if (runtime.reclaimEnabled()) gone.release(a);
            removed = true;
        }
    }
    if (removed) syncMapView(a, ctx.args[0]);
    return ok(.{ .Bool = removed });
}

pub fn coll_mut_list_remove_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.removeAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return mutCollRemoveRetain(ctx, it, ctx.args[0], "removeAll", false, false);
}
pub fn coll_mut_list_retain_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.retainAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return mutCollRemoveRetain(ctx, it, ctx.args[0], "retainAll", true, false);
}

pub fn coll_mut_list_set(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    if (try sublistComodGuard(ctx.allocator, &ctx.args[0])) |e| return e;
    defer syncSublist(ctx.allocator, ctx.args[0]);
    const a = ctx.allocator;
    const it = switch (try recvListItems(a, ctx.args, "MutableList.set")) {
        .items => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2 or ctx.args[1] != .Int) return typeErr("set requires an Int index");
    const i = ctx.args[1].Int;
    if (ctx.args.len < 3) return arityErr("set requires (index, value)");
    const value = ctx.args[2];
    const g = it.borrowMut();
    defer g.deinit();
    const len = g.get().items.len;
    if (i < 0 or @as(usize, @intCast(i)) >= len) {
        const msg = try fmt(a, "Index {d} out of bounds for length {d}", .{ i, len });
        const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    // The list owns the new value; the replaced value's ownership transfers
    // to the returned `prev` (Kotlin `set` returns the previous element).
    if (runtime.reclaimEnabled()) value.retain();
    const prev = g.get().items[@intCast(i)];
    g.get().items[@intCast(i)] = value;
    return ok(prev);
}

// =====================================================================
// Additional Set ops
// =====================================================================

pub fn coll_set_contains_all(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.containsAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const other = (try collectColl(a, if (ctx.args.len > 1) ctx.args[1] else null)) orelse
        return typeErr("containsAll requires a collection");
    const items = try snapshotItems(a, it);
    defer if (runtime.freeScratch()) a.free(items);
    for (other) |o| {
        if (!try containsBoxedH(ctx.host, ctx.out, items, &o)) return ok(.{ .Bool = false });
    }
    return ok(.{ .Bool = true });
}

pub fn coll_set_to_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.toList")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeListVL(a, it, false));
}
pub fn coll_set_to_mutable_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.toMutableList")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeListVL(a, it, true));
}
pub fn coll_set_to_set_(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.toSet")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeSetVL(a, it, false));
}
pub fn coll_set_to_mutable_set_(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.toMutableSet")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try makeSetVL(a, it, true));
}
pub fn coll_set_with_index(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "Set.withIndex")) {
        .items => |x| x,
        .err => |e| return e,
    };
    return ok(try withIndexImpl(ctx, try snapshotItems(a, it)));
}
pub fn coll_mut_set_add_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const _szb = listLenOf(&ctx.args[0]);
    defer structuralBump(&ctx.args[0], _szb);
    const a = ctx.allocator;
    const it = switch (try recvSetItems(a, ctx.args, "MutableSet.addAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    const arg = if (ctx.args.len > 1) ctx.args[1] else Value.Null;
    const to_add = if (arg == .Sequence)
        switch (try materialiseSequence(a, ctx.host, ctx.out, arg)) {
            .items => |x| x,
            .err => |e| return .{ .err = e },
        }
    else
        (try collectColl(a, arg)) orelse switch (try iterableItemsCtx(ctx, arg, "MutableSet.addAll")) {
            .items => |x| x,
            .err => |e| return e,
        };
    const g = it.borrowMut();
    defer g.deinit();
    var changed = false;
    for (to_add) |v| {
        if (!containsBoxed(g.get().items, &v)) {
            // The set owns one ref per element; `to_add` is a borrowed snapshot.
            if (runtime.reclaimEnabled()) v.retain();
            try g.get().append(a, v);
            changed = true;
        }
    }
    return ok(.{ .Bool = changed });
}

// =====================================================================
// Additional Map ops
// =====================================================================

pub fn coll_map_get_or_default(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.getOrDefault")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("getOrDefault requires (key, default)");
    const key = ctx.args[1];
    if (ctx.args.len < 3) return arityErr("getOrDefault requires (key, default)");
    const default = ctx.args[2];
    const g = entries.borrowMut();
    defer g.deinit();
    if (try g.get().find(a, &key)) |i| return okElem(g.get().pairs.items[i].value);
    return ok(default);
}

pub fn coll_map_get_value(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.getValue")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) return arityErr("getValue requires a key");
    // Property-delegation form `getValue(thisRef, property)` keys by the
    // property name (`Map<String,V>.getValue` -> getOrImplicitDefault(name));
    // the plain `getValue(key)` form keys by the argument itself.
    const key: Value = if (ctx.args.len >= 3 and ctx.args[2] == .PropertyRef) blk: {
        const g = ctx.args[2].PropertyRef.name.borrow();
        defer g.deinit();
        break :blk .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, g.get().bytes)) };
    } else ctx.args[1];
    {
        const g = entries.borrowMut();
        defer g.deinit();
        if (try g.get().find(a, &key)) |i| return okElem(g.get().pairs.items[i].value);
    }
    const kd = try display(a, key);
    const msg = try fmt(a, "Key {s} is missing in the map.", .{kd});
    const e = try thrown(a, "kotlin.NoSuchElementException", msg);
    if (runtime.freeScratch()) a.free(msg);
    return e;
}

pub fn coll_map_to_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.toList")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    var pairs: std.ArrayList(Value) = .empty;
    {
        const g = entries.borrow();
        defer g.deinit();
        for (g.get().pairs.items) |kv| {
            kv.key.retain();
            kv.value.retain();
            try pairs.append(a, try makePair(a, kv.key, kv.value));
        }
    }
    return ok(try makeListFromArrayList(a, pairs, false));
}

pub fn coll_map_to_sorted_map(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Map) return typeErr("toSortedMap requires a Map receiver");
    const entries = try snapshotEntries(a, ctx.args[0].Map.entries);
    var descending = false;
    if (ctx.args.len > 1) {
        const cmp = ctx.args[1];
        if (cmp == .Comparator) {
            const sg = cmp.Comparator.steps.borrow();
            defer sg.deinit();
            if (sg.get().*.len == 0) {
                descending = cmp.Comparator.descending;
            } else {
                return typeErr("toSortedMap with a selector comparator is not yet supported");
            }
        } else {
            return typeErr("toSortedMap expects a Comparator argument");
        }
    }
    if (try sortMapByKey(a, entries, descending)) |e| return e;
    return ok(try makeMap(a, entries, false));
}

pub fn coll_map_count_no_pred(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len >= 2) {
        const items = switch (try iterableItems(a, ctx.args[0], "count")) {
            .items => |x| x,
            .err => |e| return e,
        };
    defer if (runtime.freeScratch()) a.free(items);
        const block = ctx.args[1];
        var n: i64 = 0;
        for (items) |v| {
            const r = switch (try invoke(ctx, &block, &.{v})) {
                .value => |x| x,
                .err => |e| return e,
            };
            if (r == .Bool and r.Bool) n += 1;
        }
        return ok(Value.newInt(n));
    }
    const entries = switch (try recvMapEntries(a, ctx.args, "Map.count")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    return ok(Value.newInt(@intCast(mapLen(entries))));
}

pub fn coll_mut_map_put_all(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const a = ctx.allocator;
    const entries = switch (try recvMapEntries(a, ctx.args, "MutableMap.putAll")) {
        .entries => |x| x,
        .err => |e| return e,
    };
    const _mb = mapEntriesLen(entries);
    defer mapStructuralBump(entries, _mb);
    if (ctx.args.len < 2) return arityErr("putAll requires a Map");
    const arg = ctx.args[1];
    var to_add: []MapPair = undefined;
    switch (arg) {
        .Pair => |p| {
            const one = try a.alloc(MapPair, 1);
            one[0] = .{ .key = p.first.asPtr().*, .value = p.second.asPtr().* };
            to_add = one;
        },
        .Map => |m| to_add = try snapshotEntries(a, m.entries),
        .Array => |arr| to_add = (switch (try pairsFromValues(a, try arr.snapshot(a), "putAll")) {
            .entries => |x| x,
            .err => |e| return e,
        }).items,
        .List => |l| to_add = (switch (try pairsFromValues(a, try snapshotItems(a, l.items), "putAll")) {
            .entries => |x| x,
            .err => |e| return e,
        }).items,
        .Set => |s| to_add = (switch (try pairsFromValues(a, try snapshotItems(a, s.items), "putAll")) {
            .entries => |x| x,
            .err => |e| return e,
        }).items,
        .Sequence => {
            const items = switch (try materialiseSequence(a, ctx.host, ctx.out, arg)) {
                .items => |x| x,
                .err => |e| return .{ .err = e },
            };
            to_add = (switch (try pairsFromValues(a, items, "putAll")) {
                .entries => |x| x,
                .err => |e| return e,
            }).items;
        },
        // An Instance is either a user `Map` (drain its `entries`) or an
        // `Iterable<Pair>` (e.g. an `asIterable()` view — drain it and read each
        // Pair). `MutableMap.putAll(pairs: Iterable<Pair>)` reaches here with the
        // latter, which has no `entries` property.
        .Instance => {
            const is_map = blk: {
                const er = (try ctx.host.getProperty(&arg, "entries", ctx.out)) orelse break :blk false;
                break :blk er == .ok;
            };
            if (is_map) {
                to_add = switch (try userMapPairs(ctx, arg, "putAll")) {
                    .entries => |x| x,
                    .err => |e| return e,
                };
            } else {
                const its = switch (try iterableItemsCtx(ctx, arg, "putAll")) {
                    .items => |x| x,
                    .err => |e| return e,
                };
                to_add = (switch (try pairsFromValues(ctx.allocator, its, "putAll")) {
                    .entries => |x| x,
                    .err => |e| return e,
                }).items;
            }
        },
        else => return typeErr("putAll requires a Map or a collection of Pairs"),
    }
    const g = entries.borrowMut();
    defer g.deinit();
    // `to_add` entries are borrowed (snapshotEntries of the source map, or
    // Pair-component reads); the destination owns one ref per key+value.
    for (to_add) |kv| {
        var found = false;
        for (g.get().pairs.items) |*slot| {
            if (eqBoxed(&slot.key, &kv.key)) {
                if (runtime.reclaimEnabled()) {
                    kv.value.retain();
                    slot.value.release(a);
                }
                slot.value = kv.value;
                found = true;
                break;
            }
        }
        if (!found) {
            if (runtime.reclaimEnabled()) {
                kv.key.retain();
                kv.value.retain();
            }
            try g.get().pairs.append(a, kv);
            try g.get().noteAppended(a, g.get().pairs.items.len - 1);
        }
    }
    return ok(Value.Unit);
}

pub fn coll_mut_map_set(ctx: *CallCtx) Error!EvalResult {
    if (try readOnlyMutationGuard(ctx.allocator, ctx.args)) |e| return e;
    const r = try coll_mut_map_put(ctx);
    if (r == .err) return r;
    return ok(Value.Unit);
}

// =====================================================================
// Array ops
// =====================================================================

fn arrayPrimDefault(prim: ?PrimitiveArrayKind) Value {
    return switch (prim orelse return Value.Null) {
        .Int => .{ .Int = 0 },
        .Long => .{ .Long = 0 },
        .Double => .{ .Double = 0.0 },
        .Float => .{ .Float = 0.0 },
        .Short => .{ .Short = 0 },
        .Byte => .{ .Byte = 0 },
        .Boolean => .{ .Bool = false },
        .Char => .{ .Char = 0 },
        .UInt => .{ .UInt = 0 },
        .ULong => .{ .ULong = 0 },
        .UShort => .{ .UShort = 0 },
        .UByte => .{ .UByte = 0 },
    };
}

fn arrayPrimOf(v: Value) ?PrimitiveArrayKind {
    return switch (v) {
        .Array => |arr| arr.prim,
        else => null,
    };
}

const IdxOutcome = union(enum) { idx: i64, err: EvalResult };

fn arrayOptIndex(a: Allocator, ctx: *CallCtx, idx: usize, default: i64, what: []const u8) Error!IdxOutcome {
    if (idx >= ctx.args.len) return .{ .idx = default };
    // A named-arg reorder pads omitted middle defaults with Null.
    if (ctx.args[idx] == .Null) return .{ .idx = default };
    if (ctx.args[idx].asI64()) |v| return .{ .idx = v };
    return .{ .err = typeErr(try fmt(a, "{s}: index argument must be an Int", .{what})) };
}

/// Every caller passes a freshly-`fmt`'d (owned) message; free it after
/// `thrown` has duped it into the StringRef under the reclaim path.
fn indexOob(a: Allocator, msg: []const u8) Error!EvalResult {
    const e = try thrown(a, "kotlin.IndexOutOfBoundsException", msg);
    if (runtime.freeScratch()) a.free(msg);
    return e;
}

fn illegalArg(a: Allocator, msg: []const u8) Error!EvalResult {
    const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
    if (runtime.freeScratch()) a.free(msg);
    return e;
}

pub fn array_slice_impl(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("sliceArray requires a receiver");
    const recv = ctx.args[0];
    if (recv != .Array) return typeErr("sliceArray requires an array receiver");
    const arr = recv.Array;
    const prim = arr.prim;
    if (ctx.args.len < 2) return arityErr("sliceArray expects (receiver, range)");
    const src = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(src);
    if (ctx.args[1] == .Range) {
        const rs = ctx.args[1].Range.start;
        const re = ctx.args[1].Range.end;
        const slen: i64 = @intCast(src.len);
        // An empty range yields an empty array; otherwise the range must be in
        // bounds (Kotlin's sliceArray throws for a negative/over-length range).
        if (rs > re) return ok(try makeArray(a, &.{}, prim));
        if (rs < 0 or re >= slen) {
            return indexOob(a, try fmt(a, "sliceArray: range {d}..{d} out of bounds for length {d}", .{ rs, re, src.len }));
        }
        return ok(try makeArray(a, src[@intCast(rs)..@intCast(re + 1)], prim));
    }
    // `sliceArray(indices: Collection<Int>)`: gather `this[indices[k]]`.
    const idxs = switch (try iterableItemsCtx(ctx, ctx.args[1], "sliceArray")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(idxs);
    const sel = try a.alloc(Value, idxs.len);
    defer if (runtime.freeScratch()) a.free(sel);
    for (idxs, 0..) |iv, k| {
        const i: i64 = switch (iv) {
            .Int => |x| x,
            .Long => |x| x,
            else => return typeErr("sliceArray index must be Int"),
        };
        if (i < 0 or i >= src.len) return indexOob(a, "sliceArray: index out of bounds");
        var e = src[@intCast(i)];
        if (runtime.reclaimEnabled()) e.retain();
        sel[k] = e;
    }
    return ok(try makeArray(a, sel, prim));
}

pub fn array_content_equals(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("contentEquals requires a receiver");
    const recv = ctx.args[0];
    if (ctx.args.len < 2) return arityErr("contentEquals expects (other)");
    const other = ctx.args[1];
    if (recv == .Null or other == .Null) {
        return ok(.{ .Bool = recv == .Null and other == .Null });
    }
    const xa = switch (try iterableItems(a, recv, "contentEquals")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(xa);
    const xb = switch (try iterableItems(a, other, "contentEquals")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(xb);
    if (xa.len != xb.len) return ok(.{ .Bool = false });
    for (xa, xb) |*x, *y| {
        if (!eqBoxed(x, y)) return ok(.{ .Bool = false });
    }
    return ok(.{ .Bool = true });
}

pub fn array_content_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("contentToString requires a receiver");
    const recv = ctx.args[0];
    if (recv == .Null) return ok(try makeStringOwned(a, "null"));
    const items = switch (try iterableItems(a, recv, "contentToString")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (items, 0..) |v, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, try display(a, v));
    }
    try out.append(a, ']');
    const buf = try out.toOwnedSlice(a);
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}

fn longHash(bits: i64) i32 {
    const u: u64 = @bitCast(bits);
    return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(bits ^ @as(i64, @bitCast(u >> 32)))))));
}

/// `kotlinValueHash` with member dispatch: a user instance's own
/// hashCode() override participates, as on the JVM.
fn valueHashDispatch(ctx: *CallCtx, v: Value) i32 {
    switch (v) {
        .Instance, .Exception => {
            const r = ctx.host.invokeMethod(&v, "hashCode", &.{}, ctx.out) catch return kotlinValueHash(v);
            if (r) |res| switch (res) {
                .ok => |hv| if (hv == .Int) return @truncate(hv.Int),
                .err => {},
            };
            return kotlinValueHash(v);
        },
        else => return kotlinValueHash(v),
    }
}

fn kotlinValueHash(v: Value) i32 {
    return switch (v) {
        .Null, .Unit => 0,
        .Int => |x| x,
        .Short => |x| @as(i32, x),
        .Byte => |x| @as(i32, x),
        .Char => |x| @as(i32, x),
        .Bool => |b| if (b) @as(i32, 1231) else @as(i32, 1237),
        .Long => |x| longHash(x),
        .UInt => |x| @bitCast(x),
        .UShort => |x| @as(i32, x),
        .UByte => |x| @as(i32, x),
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
        else => 0,
    };
}

pub fn array_content_hash_code(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("contentHashCode requires a receiver");
    const recv = ctx.args[0];
    if (recv == .Null) return ok(.{ .Int = 0 });
    const items = switch (try iterableItems(a, recv, "contentHashCode")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    var result: i32 = 1;
    for (items) |e| {
        result = result *% 31 +% valueHashDispatch(ctx, e);
    }
    return ok(.{ .Int = result });
}

pub fn array_or_empty(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len > 0 and ctx.args[0] == .Array) return ok(ctx.args[0]);
    return ok(try makeArray(a, &.{}, null));
}

fn deepToString(a: Allocator, v: Value) Error![]u8 {
    var path: std.ArrayList(usize) = .empty;
    defer path.deinit(a);
    return deepToStringRec(a, v, &path);
}

/// `contentDeepToString`, tracking the array-backing identities on the current
/// path so a reference cycle (`b[0] = a; a[0] = b`) renders as `[...]` instead
/// of recursing forever.
fn deepToStringRec(a: Allocator, v: Value, path: *std.ArrayList(usize)) Error![]u8 {
    switch (v) {
        .Array => |arr| {
            const id = arr.identity();
            for (path.items) |p| {
                if (p == id) return a.dupe(u8, "[...]");
            }
            try path.append(a, id);
            defer _ = path.pop();
            var out: std.ArrayList(u8) = .empty;
            try out.append(a, '[');
            const n = arr.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, try deepToStringRec(a, arr.get(i), path));
            }
            try out.append(a, ']');
            return out.toOwnedSlice(a);
        },
        .Null => return a.dupe(u8, "null"),
        else => return display(a, v),
    }
}

pub fn array_content_deep_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("contentDeepToString requires a receiver");
    const recv = ctx.args[0];
    if (recv == .Null) return ok(try makeStringOwned(a, "null"));
    const buf = try deepToString(a, recv);
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}

fn deepEq(x: Value, y: Value) bool {
    if (x == .Array and y == .Array) {
        const xa = x.Array;
        const ya = y.Array;
        const n = xa.len();
        if (n != ya.len()) return false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!deepEq(xa.get(i), ya.get(i))) return false;
        }
        return true;
    }
    return eqBoxed(&x, &y);
}

pub fn array_content_deep_equals(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("contentDeepEquals requires a receiver");
    const recv = ctx.args[0];
    if (ctx.args.len < 2) return arityErr("contentDeepEquals expects (other)");
    const other = ctx.args[1];
    return ok(.{ .Bool = deepEq(recv, other) });
}

fn deepHashElement(ctx: *CallCtx, v: Value) i32 {
    switch (v) {
        .Array => |arr| {
            var result: i32 = 1;
            const n = arr.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                result = result *% 31 +% deepHashElement(ctx, arr.get(i));
            }
            return result;
        },
        else => return valueHashDispatch(ctx, v),
    }
}

pub fn array_content_deep_hash_code(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("contentDeepHashCode requires a receiver");
    const recv = ctx.args[0];
    if (recv == .Null) return ok(.{ .Int = 0 });
    return ok(.{ .Int = deepHashElement(ctx, recv) });
}

pub fn array_contains(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len < 2) return arityErr("contains expects (element)");
    const items = switch (try iterableItems(a, ctx.args[0], "contains")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const needle = coerceNeedleToArrayKind(ctx.args[1], arrayPrimOf(ctx.args[0]));
    return ok(.{ .Bool = try containsBoxedH(ctx.host, ctx.out, items, &needle) });
}

pub fn array_contains_all(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len < 2) return arityErr("containsAll expects (elements)");
    const items = switch (try iterableItems(a, ctx.args[0], "containsAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const needles = switch (try iterableItems(a, ctx.args[1], "containsAll")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(needles);
    const kind = arrayPrimOf(ctx.args[0]);
    for (needles) |*n| {
        const needle = coerceNeedleToArrayKind(n.*, kind);
        if (!containsBoxed(items, &needle)) return ok(.{ .Bool = false });
    }
    return ok(.{ .Bool = true });
}

pub fn array_element_at(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("elementAt requires a receiver");
    const items = switch (try iterableItems(a, ctx.args[0], "elementAt")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    const index = switch (try arrayOptIndex(a, ctx, 1, -1, "elementAt")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (index < 0 or @as(usize, @intCast(index)) >= items.len) {
        return indexOob(a, try fmt(a, "index: {d}, size: {d}", .{ index, items.len }));
    }
    return okElem(items[@intCast(index)]);
}

pub fn array_plus(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("plus requires a receiver");
    const recv = ctx.args[0];
    if (ctx.args.len < 2) return arityErr("plus expects (element|elements)");
    const other = ctx.args[1];
    var items: std.ArrayList(Value) = .empty;
    {
        const xs = switch (try iterableItems(a, recv, "plus")) {
            .items => |x| x,
            .err => |e| return e,
        };
    defer if (runtime.freeScratch()) a.free(xs);
        try items.appendSlice(a, xs);
    }
    switch (other) {
        .Array, .List, .Set => {
            const xs = switch (try iterableItems(a, other, "plus")) {
                .items => |x| x,
                .err => |e| return e,
            };
    defer if (runtime.freeScratch()) a.free(xs);
            try items.appendSlice(a, xs);
        },
        else => try items.append(a, other),
    }
    return ok(try makeArrayBorrowed(a, items, arrayPrimOf(recv)));
}

pub fn array_plus_element(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("plusElement requires a receiver");
    const recv = ctx.args[0];
    if (ctx.args.len < 2) return arityErr("plusElement expects (element)");
    const other = ctx.args[1];
    var items: std.ArrayList(Value) = .empty;
    const xs = switch (try iterableItems(a, recv, "plusElement")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(xs);
    try items.appendSlice(a, xs);
    try items.append(a, other);
    return ok(try makeArrayBorrowed(a, items, arrayPrimOf(recv)));
}

pub fn array_copy_into(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("copyInto requires an array receiver");
    const src_arr = ctx.args[0].Array;
    if (ctx.args.len < 2) return arityErr("copyInto expects (destination, ...)");
    const dest_val = ctx.args[1];
    if (dest_val != .Array) return typeErr("copyInto destination must be an array");
    const dest_arr = dest_val.Array;
    const src_len: i64 = @intCast(src_arr.len());
    const dest_offset = switch (try arrayOptIndex(a, ctx, 2, 0, "copyInto")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const start = switch (try arrayOptIndex(a, ctx, 3, 0, "copyInto")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const end = switch (try arrayOptIndex(a, ctx, 4, src_len, "copyInto")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (start < 0 or end > src_len or start > end) {
        return indexOob(a, try fmt(a, "copyInto: source range [{d}, {d}) out of bounds for length {d}", .{ start, end, src_len }));
    }
    const count = end - start;
    const dest_len: i64 = @intCast(dest_arr.len());
    if (dest_offset < 0 or dest_offset + count > dest_len) {
        return indexOob(a, try fmt(a, "copyInto: destination range [{d}, {d}) out of bounds for length {d}", .{ dest_offset, dest_offset + count, dest_len }));
    }
    const snap = try src_arr.snapshot(a);
    // The snapshot bridges src->dest; free the spine on exit (`set` retains into
    // the destination under a reclaiming backend).
    defer if (runtime.freeScratch()) a.free(snap);
    const sub = snap[@intCast(start)..@intCast(end)];
    const base: usize = @intCast(dest_offset);
    for (sub, 0..) |v, i| dest_arr.set(a, base + i, v);
    return ok(dest_val);
}

pub fn array_copy_of(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("copyOf requires an array receiver");
    const arr = ctx.args[0].Array;
    const prim = arr.prim;
    const cur_len: i64 = @intCast(arr.len());
    const new_size = switch (try arrayOptIndex(a, ctx, 1, cur_len, "copyOf")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (new_size < 0) {
        const msg = try fmt(a, "{d}", .{new_size});
        const e = try thrown(a, "kotlin.IllegalArgumentException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const n: usize = @intCast(new_size);
    const default = arrayPrimDefault(prim);
    const cur = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(cur);
    var out: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try out.append(a, if (i < cur.len) cur[i] else default);
    }
    return ok(try makeArrayBorrowed(a, out, prim));
}

pub fn array_copy_of_range(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("copyOfRange requires an array receiver");
    const arr = ctx.args[0].Array;
    const prim = arr.prim;
    const len: i64 = @intCast(arr.len());
    const from = switch (try arrayOptIndex(a, ctx, 1, 0, "copyOfRange")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const to = switch (try arrayOptIndex(a, ctx, 2, len, "copyOfRange")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (from < 0 or to > len) {
        return indexOob(a, try fmt(a, "copyOfRange: [{d}, {d}) out of bounds for length {d}", .{ from, to, len }));
    }
    if (from > to) {
        return illegalArg(a, try fmt(a, "copyOfRange: fromIndex {d} > toIndex {d}", .{ from, to }));
    }
    const snap = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(snap);
    return ok(try makeArray(a, snap[@intCast(from)..@intCast(to)], prim));
}

pub fn array_fill(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("fill requires an array receiver");
    const arr = ctx.args[0].Array;
    if (ctx.args.len < 2) return arityErr("fill expects (element, ...)");
    const element = ctx.args[1];
    const len: i64 = @intCast(arr.len());
    const from = switch (try arrayOptIndex(a, ctx, 2, 0, "fill")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const to = switch (try arrayOptIndex(a, ctx, 3, len, "fill")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (from < 0 or to > len) {
        return indexOob(a, try fmt(a, "fill: [{d}, {d}) out of bounds for length {d}", .{ from, to, len }));
    }
    if (from > to) {
        return illegalArg(a, try fmt(a, "fill: fromIndex {d} > toIndex {d}", .{ from, to }));
    }
    var i: usize = @intCast(from);
    while (i < @as(usize, @intCast(to))) : (i += 1) arr.set(a, i, element);
    return ok(Value.Unit);
}

/// `UIntArray.asIntArray()` (and the U{Byte,Short,Long} siblings): a signed
/// VIEW sharing the unsigned array's packed buffer, so mutations through either
/// alias — the mirror of `IntArray.asUIntArray()` (the unsigned ctor). klio
/// otherwise falls to the stdlib body, which copies.
pub fn array_as_signed_view(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("asArray requires an array receiver");
    const arr = ctx.args[0].Array;
    const src = arr.prim orelse return typeErr("asArray requires a primitive array");
    const dst: PrimitiveArrayKind = switch (src) {
        .UByte => .Byte,
        .UShort => .Short,
        .UInt => .Int,
        .ULong => .Long,
        else => return typeErr("asArray: receiver is not an unsigned array"),
    };
    switch (arr.storage) {
        .scalars => |pb| return ok(.{ .Array = .{ .storage = .{ .scalars = pb.clone() }, .prim = dst } }),
        .boxed => return typeErr("asArray: unsigned array is not packed"),
    }
}

/// In-place `reverse()` / `reverse(fromIndex, toIndex)` for an array. The
/// unsigned `reverse()` stdlib body delegates to `storage.reverse()`, which
/// does not reach the array's elements here, so the unsigned arrays bind this.
pub fn array_reverse(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("reverse requires an array receiver");
    const arr = ctx.args[0].Array;
    const len: i64 = @intCast(arr.len());
    const from = switch (try arrayOptIndex(a, ctx, 1, 0, "reverse")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const to = switch (try arrayOptIndex(a, ctx, 2, len, "reverse")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (from < 0 or to > len) {
        return indexOob(a, try fmt(a, "reverse: range [{d}, {d}) out of bounds for length {d}", .{ from, to, len }));
    }
    if (from > to) {
        return illegalArg(a, try fmt(a, "reverse: fromIndex {d} > toIndex {d}", .{ from, to }));
    }
    const buf = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(buf);
    std.mem.reverse(Value, buf[@intCast(from)..@intCast(to)]);
    try arr.writeBack(a, buf);
    return ok(Value.Unit);
}

pub fn array_sort(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("sort requires an array receiver");
    const arr = ctx.args[0].Array;
    const len: i64 = @intCast(arr.len());
    const from = switch (try arrayOptIndex(a, ctx, 1, 0, "sort")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const to = switch (try arrayOptIndex(a, ctx, 2, len, "sort")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (from < 0 or to > len) {
        return indexOob(a, try fmt(a, "sort: range [{d}, {d}) out of bounds for length {d}", .{ from, to, len }));
    }
    if (from > to) {
        return illegalArg(a, try fmt(a, "sort: fromIndex {d} > toIndex {d}", .{ from, to }));
    }
    const buf = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(buf);
    const sub = buf[@intCast(from)..@intCast(to)];
    if (try sortListHostAware(ctx, sub)) |e| return e;
    try arr.writeBack(a, buf);
    return ok(Value.Unit);
}

pub fn array_sort_with(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("sortWith requires an array receiver");
    const arr = ctx.args[0].Array;
    if (ctx.args.len < 2) return arityErr("sortWith expects (comparator, ...)");
    const comparator = ctx.args[1];
    const len: i64 = @intCast(arr.len());
    const from = switch (try arrayOptIndex(a, ctx, 2, 0, "sortWith")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    const to = switch (try arrayOptIndex(a, ctx, 3, len, "sortWith")) {
        .idx => |v| v,
        .err => |e| return e,
    };
    if (from < 0 or to > len) {
        return indexOob(a, try fmt(a, "sortWith: range [{d}, {d}) out of bounds for length {d}", .{ from, to, len }));
    }
    if (from > to) {
        return illegalArg(a, try fmt(a, "sortWith: fromIndex {d} > toIndex {d}", .{ from, to }));
    }
    const buf = try arr.snapshot(a);
    defer if (runtime.freeScratch()) a.free(buf);
    const sub = buf[@intCast(from)..@intCast(to)];
    // An empty-step natural/reversed Comparator (`naturalOrder()`,
    // `reverseOrder()` — the body of `sortDescending`) sorts by the
    // elements' own order, host-aware so user `Comparable.compareTo`
    // dispatches; its `compare` surface cannot see the host.
    if (comparator == .Comparator) {
        const empty = blk: {
            const steps_g = comparator.Comparator.steps.borrow();
            defer steps_g.deinit();
            break :blk steps_g.get().len == 0;
        };
        if (empty) {
            if (try sortListHostAwareDesc(ctx, sub, comparator.Comparator.descending)) |e| return e;
            try arr.writeBack(a, buf);
            return ok(Value.Unit);
        }
    }
    var i: usize = 1;
    while (i < sub.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const n = switch (try invokeComparatorCompare(ctx, comparator, sub[j - 1], sub[j])) {
                .n => |v| v,
                .err => |e| return e,
            };
            if (n > 0) {
                std.mem.swap(Value, &sub[j - 1], &sub[j]);
                j -= 1;
            } else break;
        }
    }
    try arr.writeBack(a, buf);
    return ok(Value.Unit);
}

fn arraySumImpl(ctx: *CallCtx, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr(try fmt(a, "{s} requires a receiver", .{what}));
    const items = switch (try iterableItems(a, ctx.args[0], what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    return sumValues(a, items, what);
}

pub fn array_sum_int(ctx: *CallCtx) Error!EvalResult {
    return arraySumImpl(ctx, "Array.sum");
}

/// `U{Byte,Short,Int}Array.sum(): UInt` and `ULongArray.sum(): ULong`. The
/// generic sum widens unsigned elements but returns `Int`/`Long`; Kotlin's
/// unsigned sum widens to `UInt` (or `ULong` for a ULongArray).
pub fn array_sum_unsigned(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0 or ctx.args[0] != .Array) return typeErr("sum requires an array receiver");
    const prim = ctx.args[0].Array.prim orelse return typeErr("sum requires a primitive unsigned array");
    const items = switch (try iterableItems(a, ctx.args[0], "sum")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (prim == .ULong) {
        var acc: u64 = 0;
        for (items) |v| acc +%= v.asU64() orelse 0;
        return ok(.{ .ULong = acc });
    }
    var acc: u32 = 0;
    for (items) |v| acc +%= @as(u32, @truncate(v.asU64() orelse 0));
    return ok(.{ .UInt = acc });
}

pub fn array_average_impl(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr("Array.average requires a receiver");
    const items = switch (try iterableItems(a, ctx.args[0], "Array.average")) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) return ok(.{ .Double = std.math.nan(f64) });
    var acc: f64 = 0.0;
    for (items) |v| {
        acc += switch (v) {
            .Int, .Long, .Short, .Byte => @floatFromInt(v.asI64() orelse 0),
            .Double => |d| d,
            .Float => |f| @as(f64, f),
            else => return typeErr("Array.average: non-numeric element"),
        };
    }
    return ok(.{ .Double = acc / @as(f64, @floatFromInt(items.len)) });
}

fn arrayMaxMinImpl(ctx: *CallCtx, want_max: bool, what: []const u8) Error!EvalResult {
    return arrayMaxMinCore(ctx, want_max, false, what);
}

pub fn array_min_or_null(ctx: *CallCtx) Error!EvalResult {
    return arrayMaxMinCore(ctx, false, true, "Array.minOrNull");
}

pub fn array_max_or_null(ctx: *CallCtx) Error!EvalResult {
    return arrayMaxMinCore(ctx, true, true, "Array.maxOrNull");
}

fn arrayMaxMinCore(ctx: *CallCtx, want_max: bool, or_null: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len == 0) return typeErr(try fmt(a, "{s} requires a receiver", .{what}));
    const items = switch (try iterableItems(a, ctx.args[0], what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) {
        if (or_null) return ok(Value.Null);
        const msg = try fmt(a, "{s}: empty", .{what});
        const e = try thrown(a, "kotlin.NoSuchElementException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    // Floating-point arrays follow `Math.min`/`Math.max` semantics: NaN
    // propagates (any NaN element makes the result NaN) and signed zero is
    // ordered `-0.0 < 0.0`. The natural `compareValues` order expresses
    // neither, so fold the raw f64s directly.
    if (items[0] == .Double or items[0] == .Float) {
        const is_float = items[0] == .Float;
        var acc: f64 = floatVal(items[0]) orelse return floatFallback(a, items, want_max);
        for (items[1..]) |v| {
            const x = floatVal(v) orelse return floatFallback(a, items, want_max);
            acc = if (want_max) kotlinFloatMax(acc, x) else kotlinFloatMin(acc, x);
        }
        return ok(if (is_float) .{ .Float = @floatCast(acc) } else .{ .Double = acc });
    }
    return floatFallback(a, items, want_max);
}

fn floatVal(v: Value) ?f64 {
    return switch (v) {
        .Double => |d| d,
        .Float => |f| @floatCast(f),
        else => null,
    };
}

fn kotlinFloatMin(x: f64, y: f64) f64 {
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(f64);
    if (x == 0.0 and y == 0.0) return if (std.math.signbit(x) or std.math.signbit(y)) -0.0 else 0.0;
    return @min(x, y);
}

fn kotlinFloatMax(x: f64, y: f64) f64 {
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(f64);
    if (x == 0.0 and y == 0.0) return if (std.math.signbit(x) and std.math.signbit(y)) -0.0 else 0.0;
    return @max(x, y);
}

/// Natural-order min/max fold (non-float arrays, or a float array that turned
/// out to hold a non-float `Comparable` element).
fn floatFallback(a: Allocator, items: []const Value, want_max: bool) Error!EvalResult {
    var best = items[0];
    for (items[1..]) |v| {
        const o = switch (try compareValues(a, v, best)) {
            .order => |o| o,
            .err => |e| return e,
        };
        const take = if (want_max) o == .gt else o == .lt;
        if (take) best = v;
    }
    return ok(best);
}

pub fn array_max(ctx: *CallCtx) Error!EvalResult {
    return arrayMaxMinImpl(ctx, true, "Array.max");
}
pub fn array_min(ctx: *CallCtx) Error!EvalResult {
    return arrayMaxMinImpl(ctx, false, "Array.min");
}

/// `minWith`/`maxWith`(`OrNull`) over any iterable: fold by the Comparator
/// argument (args[1]) rather than natural order.
fn minMaxWithImpl(ctx: *CallCtx, want_max: bool, or_null: bool, what: []const u8) Error!EvalResult {
    const a = ctx.allocator;
    if (ctx.args.len < 2) return arityErr(try fmt(a, "{s} expects (comparator)", .{what}));
    // `iterableItemsCtx` drains a `.Sequence` receiver via the host (the plain
    // `iterableItems` only snapshots eager collections).
    const items = switch (try iterableItemsCtx(ctx, ctx.args[0], what)) {
        .items => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(items);
    if (items.len == 0) {
        if (or_null) return ok(Value.Null);
        const msg = try fmt(a, "{s}: empty", .{what});
        const e = try thrown(a, "kotlin.NoSuchElementException", msg);
        if (runtime.freeScratch()) a.free(msg);
        return e;
    }
    const comparator = ctx.args[1];
    var best = items[0];
    for (items[1..]) |v| {
        const n = switch (try invokeComparatorCompare(ctx, comparator, v, best)) {
            .n => |x| x,
            .err => |e| return e,
        };
        const take = if (want_max) n > 0 else n < 0;
        if (take) best = v;
    }
    return ok(best);
}

pub fn coll_min_with(ctx: *CallCtx) Error!EvalResult {
    return minMaxWithImpl(ctx, false, false, "minWith");
}
pub fn coll_max_with(ctx: *CallCtx) Error!EvalResult {
    return minMaxWithImpl(ctx, true, false, "maxWith");
}
pub fn coll_min_with_or_null(ctx: *CallCtx) Error!EvalResult {
    return minMaxWithImpl(ctx, false, true, "minWithOrNull");
}
pub fn coll_max_with_or_null(ctx: *CallCtx) Error!EvalResult {
    return minMaxWithImpl(ctx, true, true, "maxWithOrNull");
}

// =====================================================================
// Public re-exports for the interpreter's higher-order ops
// =====================================================================

/// Natural-order comparison. Returns an ordering or a `RuntimeError` (as
/// data) for incomparable values.
pub fn compare_values(a: Allocator, x: Value, y: Value) Error!OrderResult {
    return compareValuesPublic(a, x, y);
}

// `SequenceScope` field names (kept in sync with coroutines.zig's canonical
// copy, which lives in a higher module the stdlib cannot import).
pub const seq_has_value_field = "__seq_has_value";
pub const seq_value_field = "__seq_value";
pub const seq_yield_iter_field = "__seq_yield_iter";

/// A FRESH builder cursor cloned from `template`: a new `SequenceScope` and
/// reset flags, sharing the template's block closure. Kotlin's `sequence { }`
/// is re-iterable (a fresh coroutine per `iterator()`); klio embeds one cursor
/// in the Sequence, so each new consumption drives a clone, leaving the
/// embedded template pristine.
/// Pin a host-local fresh builder cursor for a drive loop: under the
/// tracing GC the state cell's ONLY reference is a Zig local (invisible
/// to the mark), so a collection during a pull would sweep it — and its
/// scope — out from under the loop. The keepalive wrapper makes it a
/// root for the enclosing mark/restore window.
pub fn pinBuilderState(a: Allocator, state: runtime.BuilderStateRef) Allocator.Error!void {
    if (!runtime.gc.gc_enabled) return;
    const data = try ObjRef(runtime.SequenceData).init(a, .{ .source = .{ .Builder = state.clone() }, .ops = &.{} });
    runtime.keepalivePush(.{ .Sequence = data });
}

pub fn freshBuilderState(host: IntrinsicHost, a: Allocator, template: runtime.BuilderStateRef) Allocator.Error!runtime.BuilderStateRef {
    const block: Value = blk: {
        const tg = template.borrow();
        defer tg.deinit();
        break :blk tg.get().block.asPtr().*;
    };
    const id = host.allocInstanceId();
    const fields = [_]InstanceData.Field{
        .{ .name = seq_has_value_field, .value = .{ .Bool = false } },
        .{ .name = seq_value_field, .value = .Unit },
        .{ .name = seq_yield_iter_field, .value = .Null },
    };
    const scope = try host.newSynthInstance("kotlin.sequences.SequenceScope", id, &fields);
    var blk_val = block;
    if (runtime.reclaimEnabled()) blk_val.retain();
    const block_box = try Value.boxRef(a, blk_val);
    if (runtime.reclaimEnabled()) scope.retain();
    const scope_box = try Value.boxRef(a, scope);
    return try runtime.BuilderStateRef.init(a, .{ .block = block_box, .scope = scope_box });
}

/// If `seq` is a `Builder`-source Sequence, a fresh Sequence with a cloned
/// cursor (sharing the op pipeline) for independent iteration; else null.
pub fn freshBuilderSeq(host: IntrinsicHost, a: Allocator, seq: Value) Allocator.Error!?Value {
    if (seq != .Sequence) return null;
    const sg = seq.Sequence.borrow();
    if (sg.get().source != .Builder) {
        sg.deinit();
        return null;
    }
    const tmpl = sg.get().source.Builder;
    const ops = sg.get().ops;
    sg.deinit();
    const state = try freshBuilderState(host, a, tmpl);
    const data = try ObjRef(runtime.SequenceData).init(a, .{ .source = .{ .Builder = state }, .ops = ops });
    return .{ .Sequence = data };
}

/// Drive a lazy `Value::Sequence` to completion. Returns the produced
/// items or a `RuntimeError` (as data).
pub fn materialise_sequence(a: Allocator, host: IntrinsicHost, out: Output, seq_val: Value) Error!SeqOutcome {
    return materialiseSequence(a, host, out, seq_val);
}

/// Bounded sequence materialisation (stops after `max` items on the
/// streaming fast path).
pub fn materialise_sequence_bounded(a: Allocator, host: IntrinsicHost, out: Output, seq_val: Value, max: ?usize) Error!SeqOutcome {
    return materialiseSequenceBounded(a, host, out, seq_val, max);
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// Minimal host that reports Unimplemented for callable invocations — the
/// pure (non-HOF) intrinsics under test never reach those paths.
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
    try testing.expectEqual(PrimitiveArrayKind.Int, r.ok.Array.prim.?);
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
}
