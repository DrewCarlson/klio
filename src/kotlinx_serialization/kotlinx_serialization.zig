//! Native bindings for `kotlinx-serialization-core`.
//!
//! kotlinx-serialization's compiler plugin synthesizes a `KSerializer`
//! for every `@Serializable` class. klio has no compiler plugin, so
//! the pack supplies a *reflective* replacement: `T.serializer()`
//! resolves (via an interpreter hook in interp_ir) to a klioMain
//! `ReflectiveKSerializer`, whose `serialize` / `deserialize` walk the
//! target class's primary-constructor properties using these
//! reflection helpers:
//!
//! - `__klsx_ctorParamNames(kClass)` — ordered names of the
//!   primary-constructor `val`/`var` properties.
//! - `__klsx_ctorParamSerialNames(kClass)` — the same properties' WIRE
//!   names, honouring `@SerialName`.
//! - `__klsx_classSerialNameOverride(kClass)` — the class's own
//!   `@SerialName` value, or null.
//! - `__klsx_classAnnotations(kClass)` / `__klsx_paramAnnotations(kClass, i)`
//!   — the `@SerialInfo` annotation instances a descriptor reports.
//! - `__klsx_get(obj, name)` — read a named property off an instance.
//! - `__klsx_construct(kClass, args)` — build an instance by calling
//!   the primary constructor with the (ordered) argument list.
//! - `__klsx_ctorParamTypes(kClass)` — each property's rendered declared
//!   type, so the descriptor can name a concrete element descriptor.
//! - `__klsx_ctorParamOptional(kClass)` — whether each property has a
//!   default, which is kotlinx's definition of an optional element.
//! - `__klsx_typeParamNames(kClass)` — the declaration's type-parameter
//!   names, which pair a generic `serializer(...)`'s arguments with the
//!   elements they describe.
//!
//! Everything else in serialization-core is pure Kotlin consumed
//! straight from the upstream submodule.

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const TypeShape = runtime.TypeShape;
const ClassDef = runtime.ClassDef;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const MapEntries = runtime.MapEntries;
const MapPair = runtime.MapPair;
const ObjRef = runtime.ObjRef;
const HostBindings = stdlib.HostBindings;

/// JSON document model used as the encode/decode intermediate (the
/// `serde_json::Value` analog). Object key order is preserved.
const Json = std.json.Value;
const JsonObjectMap = std.json.ObjectMap;
const JsonArray = std.json.Array;

const Error = std.mem.Allocator.Error;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn typeErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Type = msg } };
}

/// Build the registry of native bindings this crate supplies, mapping
/// each host symbol to its implementing intrinsic.
pub fn hostBindings(allocator: std.mem.Allocator) Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("kotlinx.serialization.__klsx_ctorParamNames", ctorParamNames);
    try b.register("kotlinx.serialization.__klsx_ctorParamSerialNames", ctorParamSerialNames);
    try b.register("kotlinx.serialization.__klsx_classSerialNameOverride", classSerialNameOverride);
    try b.register("kotlinx.serialization.__klsx_classAnnotations", classAnnotations);
    try b.register("kotlinx.serialization.__klsx_paramAnnotations", paramAnnotations);
    try b.register("kotlinx.serialization.__klsx_ctorParamTypes", ctorParamTypes);
    try b.register("kotlinx.serialization.__klsx_typeParamNames", typeParamNames);
    try b.register("kotlinx.serialization.__klsx_ctorParamClasses", ctorParamClasses);
    try b.register("kotlinx.serialization.__klsx_ctorParamOptional", ctorParamOptional);
    try b.register("kotlinx.serialization.__klsx_get", propGet);
    try b.register("kotlinx.serialization.__klsx_construct", construct);
    // Compiler-plugin replacement: the shape questions the generated
    // serializer would have been synthesized from.
    try b.register("kotlinx.serialization.__klsx_isSerializable", isSerializable);
    try b.register("kotlinx.serialization.__klsx_customSerializer", customSerializer);
    try b.register("kotlinx.serialization.__klsx_isEnum", isEnumClass);
    try b.register("kotlinx.serialization.__klsx_enumValues", enumEntryValues);
    try b.register("kotlinx.serialization.__klsx_enumEntryAnnotations", enumEntryAnnotations);
    try b.register("kotlinx.serialization.__klsx_enumEntrySerialNames", enumEntrySerialNames);
    // JSON format: reflective encode (runtime-value driven) and
    // type-driven decode (guided by each ctor param's declared type).
    try b.register("kotlinx.serialization.json.__klsx_jsonEncode", jsonEncode);
    try b.register("kotlinx.serialization.json.__klsx_jsonDecode", jsonDecode);
    return b;
}

// ----- JSON encode (reflective over the runtime value) -----

/// `Result<Json, RuntimeError>` as data: encode walks the runtime value
/// and either yields a JSON node or surfaces a `RuntimeError`.
const JsonResult = union(enum) {
    ok: Json,
    err: RuntimeError,
};

fn jsonString(allocator: std.mem.Allocator, s: []const u8) Error!Json {
    return .{ .string = try allocator.dupe(u8, s) };
}

/// Build a `std.json.Value` tree for `v`. Tree nodes (maps, arrays, duped
/// strings) come from `tree` — a call-scoped arena the caller frees wholesale
/// after stringifying — so the intermediate tree never leaks onto the collector's
/// heap. Host re-entry (`readProp`) still runs on `ctx.allocator`, so any cells a
/// property getter mints stay GC-managed.
fn valueToJson(v: *const Value, ctx: *CallCtx, tree: std.mem.Allocator) Error!JsonResult {
    const a = tree;
    switch (v.*) {
        .Null, .Unit => return .{ .ok = .null },
        .Bool => |b| return .{ .ok = .{ .bool = b } },
        .Int => |i| return .{ .ok = .{ .integer = @intCast(i) } },
        .Long => |l| return .{ .ok = .{ .integer = l } },
        .Short => |s| return .{ .ok = .{ .integer = @intCast(s) } },
        .Byte => |b| return .{ .ok = .{ .integer = @intCast(b) } },
        .Double => |d| return .{ .ok = numberFromF64(d) },
        .Float => |f| return .{ .ok = numberFromF64(@floatCast(f)) },
        .Char => |c| {
            var buf: [4]u8 = undefined;
            const cp: u21 = c;
            const n = std.unicode.utf8Encode(cp, &buf) catch blk: {
                // A lone surrogate / invalid code unit renders as U+FFFD.
                const rep = std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
                break :blk rep;
            };
            return .{ .ok = try jsonString(a, buf[0..n]) };
        },
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            return .{ .ok = try jsonString(a, g.get().bytes) };
        },
        .Instance => |inst| {
            const ig = inst.borrow();
            const cls_ref = ig.get().class.clone();
            ig.deinit();
            defer cls_ref.deinit();
            const cls = cls_ref.asPtr();
            if (cls.is_enum) {
                const ig2 = inst.borrow();
                const nm = ig2.get().get("name");
                ig2.deinit();
                if (nm) |nv| {
                    if (nv == .String) {
                        const sg = nv.String.borrow();
                        defer sg.deinit();
                        return .{ .ok = try jsonString(a, sg.get().bytes) };
                    }
                }
                return .{ .ok = try jsonString(a, cls.name) };
            }
            var map: JsonObjectMap = .empty;
            for (cls.primary_params) |*p| {
                if (p.property == null) continue;
                const pv_r = try readProp(v, p.name, ctx);
                const pv = switch (pv_r) {
                    .ok => |val| val,
                    .err => |e| return .{ .err = e },
                };
                const jv_r = try valueToJson(&pv, ctx, tree);
                const jv = switch (jv_r) {
                    .ok => |val| val,
                    .err => |e| return .{ .err = e },
                };
                try map.put(a, try a.dupe(u8, serialFieldName(p)), jv);
            }
            return .{ .ok = .{ .object = map } };
        },
        .List => |l| return listToJson(l.items, ctx, tree),
        .Array => |arr| return arrayToJson(arr, ctx, tree),
        .Set => |s| return listToJson(s.items, ctx, tree),
        .Map => |m| {
            var map: JsonObjectMap = .empty;
            const g = m.entries.borrow();
            // Snapshot the pairs to avoid holding the borrow across recursion.
            const pairs = try a.dupe(MapPair, g.get().pairs.items);
            g.deinit();
            for (pairs) |pair| {
                const jv_r = try valueToJson(&pair.value, ctx, tree);
                const jv = switch (jv_r) {
                    .ok => |val| val,
                    .err => |e| return .{ .err = e },
                };
                try map.put(a, try mapKey(a, &pair.key), jv);
            }
            return .{ .ok = .{ .object = map } };
        },
        else => {
            const s = try v.display(a);
            return .{ .ok = .{ .string = s } };
        },
    }
}

fn listToJson(items: ValueList, ctx: *CallCtx, tree: std.mem.Allocator) Error!JsonResult {
    const g = items.borrow();
    const elems = try tree.dupe(Value, g.get().items);
    g.deinit();
    return elemsToJson(elems, ctx, tree);
}

fn arrayToJson(arr: runtime.ArrayData, ctx: *CallCtx, tree: std.mem.Allocator) Error!JsonResult {
    return elemsToJson(try arr.snapshot(tree), ctx, tree);
}

fn elemsToJson(elems: []const Value, ctx: *CallCtx, tree: std.mem.Allocator) Error!JsonResult {
    var arr = JsonArray.init(tree);
    try arr.ensureTotalCapacity(elems.len);
    for (elems) |*e| {
        const jv_r = try valueToJson(e, ctx, tree);
        switch (jv_r) {
            .ok => |val| arr.appendAssumeCapacity(val),
            .err => |er| return .{ .err = er },
        }
    }
    return .{ .ok = .{ .array = arr } };
}

/// A finite f64 becomes a JSON float; a non-finite one becomes JSON null
/// (mirrors `serde_json::Number::from_f64` returning `None`).
fn numberFromF64(d: f64) Json {
    if (std.math.isFinite(d)) return .{ .float = d };
    return .null;
}

/// Read property `name` off `obj` (instance field first, then a getter).
fn readProp(obj: *const Value, name: []const u8, ctx: *CallCtx) Error!EvalResult {
    if (obj.* == .Instance) {
        const g = obj.Instance.borrow();
        const v = g.get().get(name);
        g.deinit();
        if (v) |val| return ok(val);
    }
    const res = try ctx.host.invokeMethod(obj, name, &.{}, ctx.out);
    if (res) |r| return r;
    return ok(.Null);
}

fn mapKey(allocator: std.mem.Allocator, k: *const Value) Error![]u8 {
    switch (k.*) {
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            return allocator.dupe(u8, g.get().bytes);
        },
        .Int => |i| return std.fmt.allocPrint(allocator, "{d}", .{i}),
        .Long => |l| return std.fmt.allocPrint(allocator, "{d}", .{l}),
        .Bool => |b| return allocator.dupe(u8, if (b) "true" else "false"),
        else => return k.display(allocator),
    }
}

fn jsonEncode(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_jsonEncode: missing value");
    const value = ctx.args[0];
    const pretty = ctx.args.len > 1 and ctx.args[1] == .Bool and ctx.args[1].Bool;
    // The intermediate json.Value tree is pure scratch — build it in a call-scoped
    // arena so it is freed wholesale, instead of leaking every map/array/string
    // node onto the collector's heap on each encode.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const jv_r = try valueToJson(&value, ctx, arena.allocator());
    const jv = switch (jv_r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const opts: std.json.Stringify.Options = if (pretty)
        .{ .whitespace = .indent_2 }
    else
        .{};
    const s = std.json.Stringify.valueAlloc(ctx.allocator, jv, opts) catch
        return error.OutOfMemory;
    return ok(.{ .String = try runtime.strInitOwned(ctx.allocator, s) });
}

// ----- JSON decode (driven by the target class's declared types) -----

fn isPrimitiveTy(t: []const u8) bool {
    const names = [_][]const u8{
        "Int", "Long", "Short", "Byte", "Double", "Float", "Boolean", "Char", "String",
    };
    for (names) |n| {
        if (std.mem.eql(u8, t, n)) return true;
    }
    return false;
}

fn isMapTy(t: []const u8) bool {
    const names = [_][]const u8{
        "Map", "MutableMap", "HashMap", "LinkedHashMap", "MutableMap.MutableEntry",
    };
    for (names) |n| {
        if (std.mem.eql(u8, t, n)) return true;
    }
    return false;
}

/// Resolve a declared simple type name to a user/runtime class value, if
/// it names one (and isn't a primitive).
fn resolveClass(t: []const u8, ctx: *CallCtx) ?Value {
    if (isPrimitiveTy(t)) return null;
    const cls_val = ctx.host.lookupGlobal(t) orelse return null;
    if (classOf(&cls_val) == null) return null;
    return cls_val;
}

/// `Result<Value, RuntimeError>` as data, used by the decode helpers.
const DecodeResult = union(enum) {
    ok: Value,
    err: RuntimeError,
};

/// Decode a JSON value into a klio `Value`, guided by the declared type
/// `shape` (head name plus generic arguments and nullability). `shape ==
/// null` means the target type is unknown, in which case numbers/strings
/// decode to their natural klio kind and objects become a generic map.
fn decodeField(
    j: *const Json,
    shape: ?*const TypeShape,
    ctx: *CallCtx,
) Error!DecodeResult {
    const a = ctx.allocator;
    const ty: ?[]const u8 = if (shape) |s| s.name else null;
    switch (j.*) {
        .null => return .{ .ok = .Null },
        .bool => |b| return .{ .ok = .{ .Bool = b } },
        .integer => |i| return .{ .ok = decodeNumber(@floatFromInt(i), i, true, ty) },
        .float => |f| return .{ .ok = decodeNumber(f, 0, false, ty) },
        .number_string => |ns| {
            // A number too large/precise for i64/f64: parse best-effort.
            if (std.fmt.parseInt(i64, ns, 10)) |i| {
                return .{ .ok = decodeNumber(@floatFromInt(i), i, true, ty) };
            } else |_| {
                const f = std.fmt.parseFloat(f64, ns) catch 0.0;
                return .{ .ok = decodeNumber(f, 0, false, ty) };
            }
        },
        .string => |s| {
            // An enum-typed field decodes the entry by name.
            if (ty) |t| {
                if (resolveClass(t, ctx)) |cls_val| {
                    if (classOf(&cls_val)) |cls_ref| {
                        defer cls_ref.deinit();
                        const cls = cls_ref.asPtr();
                        if (cls.is_enum) {
                            for (cls.enum_entries) |entry| {
                                if (std.mem.eql(u8, entry.name, s)) {
                                    // The enum singleton is owned by the immutable
                                    // ClassDef; the decoded value escapes into an
                                    // owning container, so retain (host-returns-owned).
                                    if (runtime.reclaimEnabled()) entry.value.retain();
                                    return .{ .ok = entry.value };
                                }
                            }
                        }
                    }
                }
            }
            return .{ .ok = .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, s)) } };
        },
        .array => |arr| {
            // The element type is the first generic argument of the
            // declared collection type (e.g. `List<Item>` → `Item`).
            const elem: ?*const TypeShape = if (shape) |s|
                (if (s.args.len > 0) &s.args[0] else null)
            else
                null;
            var items: std.ArrayList(Value) = .empty;
            try items.ensureTotalCapacity(a, arr.items.len);
            for (arr.items) |*e| {
                const r = try decodeField(e, elem, ctx);
                switch (r) {
                    .ok => |val| items.appendAssumeCapacity(val),
                    .err => |er| return .{ .err = er },
                }
            }
            return .{ .ok = try Value.newList(a, .{
                .items = try ValueList.init(a, items),
                .mutable = false,
                .enum_entries = false,
                .backing = null,
            }) };
        },
        .object => |map| {
            if (ty) |t| {
                if (isMapTy(t)) {
                    // A declared map: keys come straight from JSON object
                    // keys, values decode by the map's second generic arg.
                    const val_shape: ?*const TypeShape = if (shape) |s|
                        (if (s.args.len > 1) &s.args[1] else null)
                    else
                        null;
                    return decodeMap(map, val_shape, ctx);
                }
                if (resolveClass(t, ctx)) |cls_val| {
                    // A nested @Serializable class: construct it.
                    return decodeObject(map, &cls_val, ctx);
                }
            }
            // Unknown target type: a generic string-keyed map.
            return decodeMap(map, null, ctx);
        },
    }
}

/// Decode every entry of a JSON object into a string-keyed klio `Map`,
/// decoding each value by `val_shape`.
fn decodeMap(map: JsonObjectMap, val_shape: ?*const TypeShape, ctx: *CallCtx) Error!DecodeResult {
    const a = ctx.allocator;
    var entries: std.ArrayList(MapPair) = .empty;
    try entries.ensureTotalCapacity(a, map.count());
    var it = map.iterator();
    while (it.next()) |entry| {
        const r = try decodeField(entry.value_ptr, val_shape, ctx);
        const v = switch (r) {
            .ok => |val| val,
            .err => |er| return .{ .err = er },
        };
        entries.appendAssumeCapacity(.{
            .key = .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, entry.key_ptr.*)) },
            .value = v,
        });
    }
    return .{ .ok = try Value.newMap(a, .{
        .entries = try MapEntries.init(a, .{ .pairs = entries }),
        .mutable = false,
    }) };
}

/// Decode a JSON number into the klio kind named by `ty`, or the natural
/// kind when the declared type is unknown.
fn decodeNumber(f: f64, i: i64, is_int: bool, ty: ?[]const u8) Value {
    if (ty) |t| {
        if (std.mem.eql(u8, t, "Long")) return .{ .Long = if (is_int) i else @intFromFloat(f) };
        if (std.mem.eql(u8, t, "Int")) return .{ .Int = @truncate(if (is_int) i else @as(i64, @intFromFloat(f))) };
        if (std.mem.eql(u8, t, "Short")) return .{ .Short = @truncate(if (is_int) i else @as(i64, @intFromFloat(f))) };
        if (std.mem.eql(u8, t, "Byte")) return .{ .Byte = @truncate(if (is_int) i else @as(i64, @intFromFloat(f))) };
        if (std.mem.eql(u8, t, "Double")) return .{ .Double = if (is_int) @floatFromInt(i) else f };
        if (std.mem.eql(u8, t, "Float")) return .{ .Float = @floatCast(if (is_int) @as(f64, @floatFromInt(i)) else f) };
    }
    if (is_int) {
        if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32)) {
            return .{ .Int = @intCast(i) };
        }
        return .{ .Long = i };
    }
    return .{ .Double = f };
}

/// The wire name of a constructor property: the value of a
/// `@SerialName("...")` on the property anchor (where the LV 2.4 target
/// assignment puts a target-less, `@property:`, or `@all:` entry —
/// `SerialName` is `@Target(PROPERTY, CLASS)`), else the property name.
fn serialFieldName(p: *const runtime.ClassParamDef) []const u8 {
    for (p.anchors.property) |*rec| {
        if (rec.is("kotlinx.serialization.SerialName") or rec.is("SerialName")) {
            if (rec.stringArg("value")) |s| return s;
        }
    }
    return p.name;
}

/// Construct an instance of `cls_val` from a JSON object, decoding each
/// primary-constructor property by its declared type shape.
fn decodeObject(map: JsonObjectMap, cls_val: *const Value, ctx: *CallCtx) Error!DecodeResult {
    const a = ctx.allocator;
    const cls_ref = classOf(cls_val) orelse
        return .{ .err = .{ .Type = "__klsx_jsonDecode: expected a class" } };
    defer cls_ref.deinit();
    const cls = cls_ref.asPtr();
    var args: std.ArrayList(Value) = .empty;
    for (cls.primary_params) |*p| {
        if (p.property == null) continue;
        const shape: ?*const TypeShape = if (p.declared_shape) |*s| s else null;
        const v: Value = blk: {
            if (map.get(serialFieldName(p))) |jv| {
                const r = try decodeField(&jv, shape, ctx);
                switch (r) {
                    .ok => |val| break :blk val,
                    .err => |er| return .{ .err = er },
                }
            } else {
                break :blk .Null;
            }
        };
        try args.append(a, v);
    }
    const r = try ctx.host.invokeCallable(cls_val, args.items, ctx.out);
    // `decodeField` returns OWNED values; the constructor reached through
    // `invokeCallable` BORROWS its args (it retains each into a field via
    // `newInstance`), so release the decoder's owned refs here — on both paths —
    // or every non-primitive @Serializable field leaks. No-op under the arena.
    if (runtime.reclaimEnabled()) for (args.items) |av| av.release(a);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = e },
    };
}

fn jsonDecode(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .String) {
        return typeErr("__klsx_jsonDecode: first arg must be a String");
    }
    // `src` and the parsed tree are scratch consumed entirely within this call —
    // the decoder copies every string it keeps into freshly-owned cells — so hold
    // them in a call-scoped arena instead of leaking them (and every node the
    // leaky parser allocates) onto the collector's heap on each decode.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const pa = arena.allocator();

    const sg = ctx.args[0].String.borrow();
    const src = try pa.dupe(u8, sg.get().bytes);
    sg.deinit();

    const cls_val: Value = if (ctx.args.len > 1) ctx.args[1] else .Null;

    const j = std.json.parseFromSliceLeaky(Json, pa, src, .{}) catch |e| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "json decode: {s}", .{@errorName(e)});
        return typeErr(msg);
    };

    if (j == .object) {
        if (classOf(&cls_val)) |cls_ref| {
            const is_enum = cls_ref.asPtr().is_enum;
            cls_ref.deinit();
            if (!is_enum) {
                const r = try decodeObject(j.object, &cls_val, ctx);
                return switch (r) {
                    .ok => |v| ok(v),
                    .err => |er| .{ .err = er },
                };
            }
        }
    }

    var shape_storage: TypeShape = undefined;
    var shape_ptr: ?*const TypeShape = null;
    if (classOf(&cls_val)) |cls_ref| {
        shape_storage = .{
            .name = cls_ref.asPtr().name,
            .nullable = false,
            .args = &.{},
        };
        cls_ref.deinit();
        shape_ptr = &shape_storage;
    }
    const r = try decodeField(&j, shape_ptr, ctx);
    return switch (r) {
        .ok => |v| ok(v),
        .err => |er| .{ .err = er },
    };
}

/// Extract the `ClassDef` handle a value names (class, bound inner class,
/// or instance), incrementing the refcount; caller `deinit`s the handle.
fn classOf(v: *const Value) ?ObjRef(ClassDef) {
    return switch (v.*) {
        .Class => |c| c.clone(),
        .Instance => |inst| blk: {
            const g = inst.borrow();
            const c = g.get().class.clone();
            g.deinit();
            break :blk c;
        },
        else => null,
    };
}

/// Whether `name` is one of the recorded annotation-name candidates for
/// `kotlinx.serialization.Serializable` (the resolver records both the bare
/// name and every import-derived fqn).
fn isSerializableAnnotation(name: []const u8) bool {
    return std.mem.eql(u8, name, "Serializable") or
        std.mem.eql(u8, name, "kotlinx.serialization.Serializable");
}

/// `@Serializable` presence on the class. This is what the compiler plugin
/// keys generation off; klio answers it from the retained annotation names so
/// `serializerOrNull()` returns null for a class that never opted in.
fn isSerializable(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return ok(.{ .Bool = false });
    const cls_ref = classOf(&ctx.args[0]) orelse return ok(.{ .Bool = false });
    defer cls_ref.deinit();
    for (cls_ref.asPtr().annotation_names) |n| {
        if (isSerializableAnnotation(n)) return ok(.{ .Bool = true });
    }
    return ok(.{ .Bool = false });
}

/// The serializer a declaration NAMES for itself: `@Serializable(with =
/// Custom::class)` — written positionally in most sources — hands the whole
/// job to `Custom`, and the plugin's `serializer()` returns that instead of
/// generating one. Answers the object singleton when `Custom` is an object
/// declaration (the usual shape) and the class value otherwise, leaving the
/// caller to construct it.
fn customSerializer(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return ok(.Null);
    const cls_ref = classOf(&ctx.args[0]) orelse return ok(.Null);
    defer cls_ref.deinit();
    for (cls_ref.asPtr().annotation_records) |rec| {
        if (!isSerializableAnnotation(rec.names[rec.names.len - 1]) and
            !recIsSerializable(&rec)) continue;
        for (rec.args) |arg| {
            if (arg != .ClassRef) continue;
            const v = ctx.host.lookupGlobal(arg.ClassRef) orelse continue;
            // An `object` answers its singleton; a CLASS answers the class,
            // and the plugin instantiates it through its no-arg constructor.
            if (v == .Class) {
                const is_object = blk: {
                    const g = v.Class.borrow();
                    defer g.deinit();
                    break :blk g.get().is_object;
                };
                if (!is_object) {
                    switch (try ctx.host.invokeCallable(&v, &.{}, ctx.out)) {
                        .ok => |built| return ok(built),
                        .err => |e| return .{ .err = e },
                    }
                }
            }
            return ok(v);
        }
    }
    return ok(.Null);
}

fn recIsSerializable(rec: *const runtime.AnnotationRecord) bool {
    for (rec.names) |n| {
        if (isSerializableAnnotation(n)) return true;
    }
    return false;
}

/// Whether the class is an `enum class`.
fn isEnumClass(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return ok(.{ .Bool = false });
    const cls_ref = classOf(&ctx.args[0]) orelse return ok(.{ .Bool = false });
    defer cls_ref.deinit();
    return ok(.{ .Bool = cls_ref.asPtr().is_enum });
}

/// The enum entry singletons in declaration order; empty for a non-enum.
fn enumEntryValues(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    if (ctx.args.len != 0) {
        if (classOf(&ctx.args[0])) |cls_ref| {
            defer cls_ref.deinit();
            for (cls_ref.asPtr().enum_entries) |e| try items.append(a, e.value);
        }
    }
    return ok(try Value.newList(a, .{
        .items = try ValueList.init(a, items),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    }));
}


/// Rendered declared type of each primary-constructor property, in the same
/// order as `__klsx_ctorParamNames`: `"Int"`, `"String?"`, `"List<Int>"`. An
/// empty string means the declaration carried no type the runtime retained,
/// and the Kotlin side falls back to its neutral element descriptor.
///
/// The plugin-generated descriptor names a concrete descriptor per element;
/// the reflective one could not, because this shape was never exposed.
fn ctorParamTypes(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_ctorParamTypes: expected a class");
    const cls_ref = classOf(&ctx.args[0]) orelse
        return typeErr("__klsx_ctorParamTypes: expected a class");
    defer cls_ref.deinit();
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    for (cls_ref.asPtr().primary_params) |p| {
        if (p.property == null) continue;
        var buf: std.ArrayList(u8) = .empty;
        if (p.declared_shape) |shape| {
            try renderShape(a, &buf, shape);
        } else if (p.declared_type) |t| {
            try buf.appendSlice(a, t);
        }
        items.append(a, .{ .String = try runtime.strInitOwned(a, try buf.toOwnedSlice(a)) }) catch |e| return e;
    }
    return ok(try Value.newList(a, .{
        .items = try ValueList.init(a, items),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    }));
}

/// The class each primary-constructor property's declared type names, in the
/// same order as `__klsx_ctorParamNames`, or null where the type is a
/// primitive, a type parameter, or names nothing the runtime knows. This is
/// what lets a descriptor report an element's REAL descriptor rather than the
/// neutral one — an element declared as another `@Serializable` class is
/// described by that class's own serializer.
fn ctorParamClasses(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_ctorParamClasses: expected a class");
    const cls_ref = classOf(&ctx.args[0]) orelse
        return typeErr("__klsx_ctorParamClasses: expected a class");
    defer cls_ref.deinit();
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    for (cls_ref.asPtr().primary_params) |p| {
        if (p.property == null) continue;
        // The HEAD of the declared type: `List<Foo>` names `List`, which is
        // not itself a serializable declaration, so only a bare head resolves.
        const head: ?[]const u8 = if (p.declared_shape) |shape|
            (if (shape.args.len == 0) shape.name else null)
        else
            p.declared_type;
        const resolved: Value = blk: {
            const h = head orelse break :blk .Null;
            const v = siblingClassNamed(cls_ref.asPtr(), h, ctx) orelse break :blk .Null;
            // An `object` resolves to its singleton; the descriptor needs the
            // declaration itself.
            if (v == .Instance) {
                const cls2 = classOf(&v) orelse break :blk .Null;
                defer cls2.deinit();
                if (!cls2.asPtr().is_object) break :blk .Null;
                break :blk .{ .Class = cls2.clone() };
            }
            break :blk v;
        };
        try items.append(a, resolved);
    }
    return ok(try Value.newList(a, .{
        .items = try ValueList.init(a, items),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    }));
}

/// Resolve a type name written inside `owner`'s declaration, Kotlin-style:
/// the enclosing scopes from innermost outward, then the bare name. A
/// declaration nested beside the owner (`class Outer { class A; class B(val
/// a: A) }`) is written unqualified but registered under its qualified name,
/// and resolving the bare name first would reach an unrelated same-named
/// declaration — `Result` beside `kotlin.Result` being the case that matters.
fn siblingClassNamed(owner: *const ClassDef, name: []const u8, ctx: *CallCtx) ?Value {
    var scope = owner.fqn;
    var hops: u8 = 0;
    while (hops < 16) : (hops += 1) {
        const dot = std.mem.lastIndexOfScalar(u8, scope, '.') orelse break;
        scope = scope[0..dot];
        var buf: [512]u8 = undefined;
        const probe = std.fmt.bufPrint(&buf, "{s}.{s}", .{ scope, name }) catch break;
        if (resolveClass(probe, ctx)) |v| return v;
    }
    return resolveClass(name, ctx);
}

/// The declaration's type-parameter names in declaration order, so a caller
/// handed one serializer per type argument can tell which rendered declared
/// type (`"T"`, `"List<T>"`) that argument stands for.
fn typeParamNames(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_typeParamNames: expected a class");
    const cls_ref = classOf(&ctx.args[0]) orelse
        return typeErr("__klsx_typeParamNames: expected a class");
    defer cls_ref.deinit();
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    for (cls_ref.asPtr().type_params) |tp| {
        try items.append(a, .{ .String = try runtime.strInit(a, tp) });
    }
    return ok(try Value.newList(a, .{
        .items = try ValueList.init(a, items),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    }));
}

/// Render a `TypeShape` back to source form, generic args included.
fn renderShape(a: std.mem.Allocator, buf: *std.ArrayList(u8), shape: TypeShape) !void {
    try buf.appendSlice(a, shape.name);
    if (shape.args.len != 0) {
        try buf.append(a, '<');
        for (shape.args, 0..) |arg, i| {
            if (i != 0) try buf.appendSlice(a, ", ");
            try renderShape(a, buf, arg);
        }
        try buf.append(a, '>');
    }
    if (shape.nullable) try buf.append(a, '?');
}

/// Whether each primary-constructor property carries a default value, in the
/// same order as `__klsx_ctorParamNames`. This is exactly kotlinx's notion of
/// an *optional* element: the plugin marks a defaulted parameter optional so a
/// decoder may leave it absent. The reflective descriptor previously answered
/// `false` for every element because the fact was never exposed.
fn ctorParamOptional(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_ctorParamOptional: expected a class");
    const cls_ref = classOf(&ctx.args[0]) orelse
        return typeErr("__klsx_ctorParamOptional: expected a class");
    defer cls_ref.deinit();
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    for (cls_ref.asPtr().primary_params) |p| {
        if (p.property == null) continue;
        try items.append(a, .{ .Bool = p.default != null });
    }
    return ok(try Value.newList(a, .{
        .items = try ValueList.init(a, items),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    }));
}

/// Ordered names of the primary-constructor properties (`val`/`var`
/// params). Plugin-generated serializers serialize exactly these, in
/// declaration order.
fn ctorParamNames(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_ctorParamNames: expected a class");
    const cls_ref = classOf(&ctx.args[0]) orelse
        return typeErr("__klsx_ctorParamNames: expected a class");
    defer cls_ref.deinit();
    const cls = cls_ref.asPtr();
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    for (cls.primary_params) |p| {
        if (p.property == null) continue;
        try items.append(a, .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, p.name)) });
    }
    return ok(try Value.newList(a, .{
        .items = try ValueList.init(a, items),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    }));
}

/// Resolve the annotation class named by `rec` to its `Class` value, trying
/// each resolved candidate in turn. Null when none names a class in scope.
fn annotationClassValue(ctx: *CallCtx, rec: *const runtime.AnnotationRecord) ?Value {
    for (rec.names) |n| {
        const v = ctx.host.lookupGlobal(n) orelse continue;
        if (v == .Class) return v;
    }
    return null;
}

/// Whether an annotation class is itself `@SerialInfo`. kotlinx surfaces only
/// those on a descriptor, so a plain Kotlin annotation stays invisible.
fn annotationIsSerialInfo(cls: *const ClassDef) bool {
    for (cls.annotation_names) |n| {
        if (std.mem.eql(u8, n, "kotlinx.serialization.SerialInfo") or
            std.mem.eql(u8, n, "SerialInfo") or
            std.mem.eql(u8, n, "kotlinx.serialization.InheritableSerialInfo") or
            std.mem.eql(u8, n, "InheritableSerialInfo")) return true;
    }
    return false;
}

/// An `@InheritableSerialInfo` annotation reaches a descriptor from the
/// declaration's SUPERTYPES as well as from the declaration itself; a plain
/// `@SerialInfo` one does not.
fn annotationIsInheritable(cls: *const ClassDef) bool {
    for (cls.annotation_names) |n| {
        if (std.mem.eql(u8, n, "kotlinx.serialization.InheritableSerialInfo") or
            std.mem.eql(u8, n, "InheritableSerialInfo")) return true;
    }
    return false;
}

/// Append the `@InheritableSerialInfo` annotations `cls` inherits, walking its
/// supertype closure. Kotlin requires every occurrence of one annotation to
/// agree, so the FIRST reached wins and later duplicates are skipped.
fn collectInheritedAnnotations(
    ctx: *CallCtx,
    cls: *const ClassDef,
    out: *std.ArrayList(runtime.AnnotationRecord),
    seen: *std.ArrayList([]const u8),
    depth: u8,
) Error!void {
    if (depth > 16) return;
    const a = ctx.allocator;
    var supers: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (supers.items) |sc| sc.deinit();
        supers.deinit(a);
    }
    if (cls.parent) |p| try supers.append(a, p.clone());
    for (cls.interfaces) |i| try supers.append(a, i.clone());
    for (supers.items) |sup| {
        const sp = sup.asPtr();
        for (sp.annotation_records) |*rec| {
            const cls_val = annotationClassValue(ctx, rec) orelse continue;
            const cls_ref = classOf(&cls_val) orelse continue;
            const inheritable = annotationIsInheritable(cls_ref.asPtr());
            const fqn = cls_ref.asPtr().fqn;
            cls_ref.deinit();
            if (!inheritable) continue;
            var dup = false;
            for (seen.items) |n| {
                if (std.mem.eql(u8, n, fqn)) dup = true;
            }
            if (dup) continue;
            try seen.append(a, fqn);
            try out.append(a, rec.*);
        }
        try collectInheritedAnnotations(ctx, sp, out, seen, depth + 1);
    }
}

/// One recorded annotation argument as a runtime value. An `EnumEntry` names
/// only its trailing segment, so the owning enum comes from the constructor
/// parameter's declared type. Null for anything the lowering left unresolved —
/// the caller then skips the whole annotation rather than fabricate a value.
fn annotationArgValue(
    ctx: *CallCtx,
    arg: runtime.AnnotationArg,
    param: ?*const runtime.ClassParamDef,
) Error!?Value {
    switch (arg) {
        .Str => |s| return Value{ .String = try runtime.strInitOwned(
            ctx.allocator,
            try ctx.allocator.dupe(u8, s),
        ) },
        .Int => |i| return Value.newInt(i),
        .Bool => |b| return Value{ .Bool = b },
        .EnumEntry => |name| {
            const p = param orelse return null;
            const ty = p.declared_type orelse return null;
            const cls_val = ctx.host.lookupGlobal(ty) orelse return null;
            if (cls_val != .Class) return null;
            const got = try ctx.host.getProperty(&cls_val, name, ctx.out) orelse return null;
            return switch (got) {
                .ok => |v| v,
                .err => null,
            };
        },
        .ClassRef => |name| {
            const cls_val = ctx.host.lookupGlobal(name) orelse return null;
            if (cls_val != .Class) return null;
            return cls_val;
        },
        .Other => return null,
    }
}

/// The recorded arguments as a positional argument list for the annotation
/// class's constructor, so unsupplied parameters take their declared defaults.
/// Null when an argument cannot be represented, or when named arguments leave
/// an earlier parameter unfilled (which no positional call can express).
fn annotationArgList(
    ctx: *CallCtx,
    rec: *const runtime.AnnotationRecord,
    cls: *const ClassDef,
) Error!?[]Value {
    const a = ctx.allocator;
    var any_named = false;
    for (rec.arg_names) |n| {
        if (n != null) any_named = true;
    }
    if (!any_named) {
        const out = try a.alloc(Value, rec.args.len);
        for (rec.args, out, 0..) |arg, *slot, i| {
            const p: ?*const runtime.ClassParamDef =
                if (i < cls.primary_params.len) &cls.primary_params[i] else null;
            slot.* = (try annotationArgValue(ctx, arg, p)) orelse {
                a.free(out);
                return null;
            };
        }
        return out;
    }
    var filled = try a.alloc(?Value, cls.primary_params.len);
    defer a.free(filled);
    @memset(filled, null);
    for (rec.args, 0..) |arg, i| {
        const nm: ?[]const u8 = if (i < rec.arg_names.len) rec.arg_names[i] else null;
        const pos: usize = if (nm) |n| blk: {
            for (cls.primary_params, 0..) |p, j| {
                if (std.mem.eql(u8, p.name, n)) break :blk j;
            }
            return null;
        } else i;
        if (pos >= filled.len) return null;
        filled[pos] = (try annotationArgValue(ctx, arg, &cls.primary_params[pos])) orelse return null;
    }
    var last: usize = 0;
    for (filled, 0..) |v, i| {
        if (v != null) last = i + 1;
    }
    for (filled[0..last]) |v| {
        if (v == null) return null;
    }
    const out = try a.alloc(Value, last);
    for (filled[0..last], out) |v, *slot| slot.* = v.?;
    return out;
}

/// Build annotation INSTANCES for `records` by running each annotation class's
/// own constructor, so declared defaults apply.
fn annotationInstanceList(ctx: *CallCtx, records: []const runtime.AnnotationRecord) Error!Value {
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    for (records) |*rec| {
        const cls_val = annotationClassValue(ctx, rec) orelse continue;
        const cls_ref = classOf(&cls_val) orelse continue;
        const keep = annotationIsSerialInfo(cls_ref.asPtr());
        const args: ?[]Value = if (keep) try annotationArgList(ctx, rec, cls_ref.asPtr()) else null;
        cls_ref.deinit();
        if (!keep) continue;
        const arg_slice = args orelse continue;
        defer a.free(arg_slice);
        const r = try ctx.host.invokeCallable(&cls_val, arg_slice, ctx.out);
        switch (r) {
            .ok => |v| try items.append(a, v),
            .err => {},
        }
    }
    return try Value.newList(a, .{
        .items = try ValueList.init(a, items),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    });
}

/// The `@SerialInfo` annotations applied to the class itself.
fn classAnnotations(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_classAnnotations: expected a class");
    const cls_ref = classOf(&ctx.args[0]) orelse
        return ok(try annotationInstanceList(ctx, &.{}));
    defer cls_ref.deinit();
    const a = ctx.allocator;
    var records: std.ArrayList(runtime.AnnotationRecord) = .empty;
    defer records.deinit(a);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(a);
    for (cls_ref.asPtr().annotation_records) |*rec| {
        try records.append(a, rec.*);
        const cls_val = annotationClassValue(ctx, rec) orelse continue;
        const acls = classOf(&cls_val) orelse continue;
        defer acls.deinit();
        if (annotationIsInheritable(acls.asPtr())) try seen.append(a, acls.asPtr().fqn);
    }
    // An `@InheritableSerialInfo` annotation on a supertype is reported here
    // too — that is what makes it inheritable.
    try collectInheritedAnnotations(ctx, cls_ref.asPtr(), &records, &seen, 0);
    return ok(try annotationInstanceList(ctx, records.items));
}

/// The `@SerialInfo` annotations applied to the primary-constructor property
/// at `index`, counting only the properties the descriptor reports.
fn paramAnnotations(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return typeErr("__klsx_paramAnnotations: expected a class and an index");
    const cls_ref = classOf(&ctx.args[0]) orelse
        return ok(try annotationInstanceList(ctx, &.{}));
    defer cls_ref.deinit();
    const want: i64 = switch (ctx.args[1]) {
        .Int => |i| i,
        .Long => |l| l,
        else => return typeErr("__klsx_paramAnnotations: index must be Int"),
    };
    var seen: i64 = 0;
    for (cls_ref.asPtr().primary_params) |*p| {
        if (p.property == null) continue;
        if (seen == want) return ok(try annotationInstanceList(ctx, p.anchors.property));
        seen += 1;
    }
    return ok(try annotationInstanceList(ctx, &.{}));
}

/// The `@SerialInfo` annotations applied to the enum entry at `index`.
fn enumEntryAnnotations(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return typeErr("__klsx_enumEntryAnnotations: expected a class and an index");
    const cls_ref = classOf(&ctx.args[0]) orelse
        return ok(try annotationInstanceList(ctx, &.{}));
    defer cls_ref.deinit();
    const want: i64 = switch (ctx.args[1]) {
        .Int => |i| i,
        .Long => |l| l,
        else => return typeErr("__klsx_enumEntryAnnotations: index must be Int"),
    };
    const entries = cls_ref.asPtr().enum_entries;
    if (want < 0 or want >= entries.len) return ok(try annotationInstanceList(ctx, &.{}));
    return ok(try annotationInstanceList(ctx, entries[@intCast(want)].annotation_records));
}

/// The WIRE name of each enum entry: its `@SerialName` when it carries one,
/// otherwise the declared entry name.
fn enumEntrySerialNames(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_enumEntrySerialNames: expected a class");
    const cls_ref = classOf(&ctx.args[0]) orelse
        return typeErr("__klsx_enumEntrySerialNames: expected a class");
    defer cls_ref.deinit();
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    for (cls_ref.asPtr().enum_entries) |entry| {
        var wire: []const u8 = entry.name;
        for (entry.annotation_records) |*rec| {
            if (rec.is("kotlinx.serialization.SerialName") or rec.is("SerialName")) {
                if (rec.stringArg("value")) |s| wire = s;
            }
        }
        try items.append(a, .{ .String = try runtime.strInit(a, wire) });
    }
    return ok(try Value.newList(a, .{
        .items = try ValueList.init(a, items),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    }));
}

/// The value of a `@SerialName("...")` on the CLASS itself, or null when it
/// carries none. kotlinx's default serial name is the qualified class name;
/// the annotation replaces it wholesale.
fn classSerialNameOverride(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_classSerialNameOverride: expected a class");
    const cls_ref = classOf(&ctx.args[0]) orelse return ok(.Null);
    defer cls_ref.deinit();
    const cls = cls_ref.asPtr();
    for (cls.annotation_records) |*rec| {
        if (rec.is("kotlinx.serialization.SerialName") or rec.is("SerialName")) {
            if (rec.stringArg("value")) |s| {
                return ok(.{ .String = try runtime.strInitOwned(
                    ctx.allocator,
                    try ctx.allocator.dupe(u8, s),
                ) });
            }
        }
    }
    return ok(.Null);
}

/// The WIRE names of the primary-constructor properties: each property's
/// `@SerialName("...")` where it carries one, else its declared name. The
/// descriptor reports these, while `ctorParamNames` keeps the declared names
/// that `__klsx_get` and `__klsx_construct` address the instance by.
fn ctorParamSerialNames(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_ctorParamSerialNames: expected a class");
    const cls_ref = classOf(&ctx.args[0]) orelse
        return typeErr("__klsx_ctorParamSerialNames: expected a class");
    defer cls_ref.deinit();
    const cls = cls_ref.asPtr();
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    for (cls.primary_params) |*p| {
        if (p.property == null) continue;
        try items.append(a, .{ .String = try runtime.strInitOwned(a, try a.dupe(u8, serialFieldName(p))) });
    }
    return ok(try Value.newList(a, .{
        .items = try ValueList.init(a, items),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    }));
}

/// Read property `name` off instance `obj`. Routes through
/// `invoke_method` so a custom getter / data-class accessor still
/// applies; falls back to the raw field.
fn propGet(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_get: missing receiver");
    const obj = ctx.args[0];
    if (ctx.args.len < 2 or ctx.args[1] != .String) {
        return typeErr("__klsx_get: name must be String");
    }
    const ng = ctx.args[1].String.borrow();
    const name = try ctx.allocator.dupe(u8, ng.get().bytes);
    ng.deinit();

    if (obj == .Instance) {
        const g = obj.Instance.borrow();
        const v = g.get().get(name);
        g.deinit();
        if (v) |val| return ok(val);
    }
    // Defer to a getter via the host (data-class / custom accessor).
    const res = try ctx.host.invokeMethod(&obj, name, &.{}, ctx.out);
    if (res) |r| return r;
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "__klsx_get: `{s}` not found on instance",
        .{name},
    );
    return typeErr(msg);
}

/// Construct an instance of `kClass` by invoking its primary
/// constructor with the supplied (ordered) argument list.
fn construct(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return typeErr("__klsx_construct: expected a class");
    const cls_val = ctx.args[0];
    const cls_ref = classOf(&cls_val) orelse
        return typeErr("__klsx_construct: expected a class");
    // `cls_ref` becomes the constructed callable; keep the handle alive in it.
    const a = ctx.allocator;
    var args: std.ArrayList(Value) = .empty;
    if (ctx.args.len > 1) {
        const arg1 = ctx.args[1];
        switch (arg1) {
            .List => |l| {
                const g = l.items.borrow();
                try args.appendSlice(a, g.get().items);
                g.deinit();
            },
            .Array => |arr| {
                const snap = try arr.snapshot(a);
                defer if (runtime.freeScratch()) a.free(snap);
                try args.appendSlice(a, snap);
            },
            else => try args.append(a, arg1),
        }
    }
    const class_value = Value{ .Class = cls_ref };
    const r = try ctx.host.invokeCallable(&class_value, args.items, ctx.out);
    cls_ref.deinit();
    return r;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const ast = @import("ast");
const span = @import("span");
const InstanceData = runtime.InstanceData;
const Env = runtime.Env;

fn makeClass(
    a: std.mem.Allocator,
    name: []const u8,
    is_enum: bool,
    params: []runtime.ClassParamDef,
) !ObjRef(ClassDef) {
    const cd: ClassDef = .{
        .name = name,
        .fqn = name,
        .annotation_names = &.{},
        .primary_params = params,
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = is_enum,
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
        .companion = try ObjRef(?ObjRef(InstanceData)).init(a, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(a, null),
        .nested_classes = &.{},
        .captured_env = try ObjRef(Env).init(a, Env.init(a)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(a, null),
    };
    return ObjRef(ClassDef).init(a, cd);
}

fn prop(name: []const u8) runtime.ClassParamDef {
    return .{
        .property = false,
        .name = name,
        .default = null,
        .declared_type = null,
        .declared_shape = null,
    };
}

fn noopCtx(a: std.mem.Allocator, args: []const Value, out: runtime.Output, host: runtime.IntrinsicHost) CallCtx {
    return .{ .args = args, .out = out, .host = host, .allocator = a };
}

test "isPrimitiveTy and isMapTy classify type names" {
    try testing.expect(isPrimitiveTy("Int"));
    try testing.expect(isPrimitiveTy("String"));
    try testing.expect(!isPrimitiveTy("Foo"));
    try testing.expect(isMapTy("Map"));
    try testing.expect(isMapTy("LinkedHashMap"));
    try testing.expect(!isMapTy("List"));
}

test "decodeNumber respects declared kind and natural fallback" {
    try testing.expectEqual(Value{ .Long = 7 }, decodeNumber(7.0, 7, true, "Long"));
    try testing.expectEqual(Value{ .Int = 3 }, decodeNumber(3.0, 3, true, "Int"));
    try testing.expectEqual(Value{ .Double = 1.5 }, decodeNumber(1.5, 0, false, "Double"));
    // Natural: small int -> Int, large -> Long, fractional -> Double.
    try testing.expectEqual(Value{ .Int = 42 }, decodeNumber(42.0, 42, true, null));
    try testing.expectEqual(Value{ .Long = 5_000_000_000 }, decodeNumber(0, 5_000_000_000, true, null));
    try testing.expectEqual(Value{ .Double = 2.25 }, decodeNumber(2.25, 0, false, null));
}

test "numberFromF64 maps non-finite to null" {
    try testing.expect(numberFromF64(1.0) == .float);
    try testing.expect(numberFromF64(std.math.inf(f64)) == .null);
    try testing.expect(numberFromF64(std.math.nan(f64)) == .null);
}

test "valueToJson encodes scalars and collections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var noop = runtime.NoopHost.init(a);
    defer noop.deinit();
    var cap = runtime.CaptureOutput.init(a);
    defer cap.deinit();

    {
        var ctx = noopCtx(a, &.{}, cap.output(), noop.host());
        const v = Value{ .Int = 5 };
        const r = try valueToJson(&v, &ctx, a);
        try testing.expect(r == .ok);
        try testing.expectEqual(@as(i64, 5), r.ok.integer);
    }
    {
        var ctx = noopCtx(a, &.{}, cap.output(), noop.host());
        const v = Value{ .String = try runtime.strInit(a, "hi") };
        const r = try valueToJson(&v, &ctx, a);
        try testing.expectEqualStrings("hi", r.ok.string);
    }
    {
        var ctx = noopCtx(a, &.{}, cap.output(), noop.host());
        var items: std.ArrayList(Value) = .empty;
        try items.append(a, .{ .Int = 1 });
        try items.append(a, .{ .Int = 2 });
        const v = try Value.newList(a, .{
            .items = try ValueList.init(a, items),
            .mutable = false,
            .enum_entries = false,
            .backing = null,
        });
        const r = try valueToJson(&v, &ctx, a);
        try testing.expect(r.ok == .array);
        try testing.expectEqual(@as(usize, 2), r.ok.array.items.len);
    }
}

test "jsonEncode emits compact and pretty JSON for a map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var noop = runtime.NoopHost.init(a);
    defer noop.deinit();
    var cap = runtime.CaptureOutput.init(a);
    defer cap.deinit();

    var entries: std.ArrayList(MapPair) = .empty;
    try entries.append(a, .{
        .key = .{ .String = try runtime.strInit(a, "a") },
        .value = .{ .Int = 1 },
    });
    const map = try Value.newMap(a, .{
        .entries = try MapEntries.init(a, .{ .pairs = entries }),
        .mutable = false,
    });

    {
        const args = [_]Value{map};
        var ctx = noopCtx(a, &args, cap.output(), noop.host());
        const r = try jsonEncode(&ctx);
        try testing.expect(r == .ok);
        const g = r.ok.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("{\"a\":1}", g.get().bytes);
    }
    {
        const args = [_]Value{ map, .{ .Bool = true } };
        var ctx = noopCtx(a, &args, cap.output(), noop.host());
        const r = try jsonEncode(&ctx);
        const g = r.ok.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("{\n  \"a\": 1\n}", g.get().bytes);
    }
}

test "jsonEncode rejects a missing value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var noop = runtime.NoopHost.init(a);
    defer noop.deinit();
    var cap = runtime.CaptureOutput.init(a);
    defer cap.deinit();
    var ctx = noopCtx(a, &.{}, cap.output(), noop.host());
    const r = try jsonEncode(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
    try testing.expectEqualStrings("__klsx_jsonEncode: missing value", r.err.Type);
}

test "decodeField decodes scalars and arrays without a target type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var noop = runtime.NoopHost.init(a);
    defer noop.deinit();
    var cap = runtime.CaptureOutput.init(a);
    defer cap.deinit();
    var ctx = noopCtx(a, &.{}, cap.output(), noop.host());

    {
        const j = try std.json.parseFromSliceLeaky(Json, a, "42", .{});
        const r = try decodeField(&j, null, &ctx);
        try testing.expectEqual(Value{ .Int = 42 }, r.ok);
    }
    {
        const j = try std.json.parseFromSliceLeaky(Json, a, "\"hi\"", .{});
        const r = try decodeField(&j, null, &ctx);
        try testing.expect(r.ok == .String);
        const g = r.ok.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("hi", g.get().bytes);
    }
    {
        const j = try std.json.parseFromSliceLeaky(Json, a, "[1,2,3]", .{});
        const r = try decodeField(&j, null, &ctx);
        try testing.expect(r.ok == .List);
        const g = r.ok.List.items.borrow();
        defer g.deinit();
        try testing.expectEqual(@as(usize, 3), g.get().items.len);
    }
}

test "decodeField decodes an unknown object to a string-keyed map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var noop = runtime.NoopHost.init(a);
    defer noop.deinit();
    var cap = runtime.CaptureOutput.init(a);
    defer cap.deinit();
    var ctx = noopCtx(a, &.{}, cap.output(), noop.host());

    const j = try std.json.parseFromSliceLeaky(Json, a, "{\"x\":1,\"y\":2}", .{});
    const r = try decodeField(&j, null, &ctx);
    try testing.expect(r.ok == .Map);
    const g = r.ok.Map.entries.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(usize, 2), g.get().pairs.items.len);
}

test "serialFieldName reads @SerialName from the property anchor" {
    const recs = [_]runtime.AnnotationRecord{.{
        .names = &.{ "kotlinx.serialization.SerialName", "SerialName" },
        .args = &.{.{ .Str = "years" }},
        .arg_names = &.{null},
    }};
    var p = prop("age");
    p.property = true;
    p.anchors = .{ .property = &recs };
    try testing.expectEqualStrings("years", serialFieldName(&p));

    // A record on another anchor (param) does not rename the field.
    var q = prop("name");
    q.property = true;
    q.anchors = .{ .param = &recs };
    try testing.expectEqualStrings("name", serialFieldName(&q));

    // A different annotation on the property anchor is ignored.
    const other = [_]runtime.AnnotationRecord{.{
        .names = &.{"Wide"},
        .args = &.{},
        .arg_names = &.{},
    }};
    var r = prop("id");
    r.property = true;
    r.anchors = .{ .property = &other };
    try testing.expectEqualStrings("id", serialFieldName(&r));
}

test "ctorParamNames returns property names in declaration order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var noop = runtime.NoopHost.init(a);
    defer noop.deinit();
    var cap = runtime.CaptureOutput.init(a);
    defer cap.deinit();

    var params = [_]runtime.ClassParamDef{ prop("id"), prop("name") };
    const cls = try makeClass(a, "User", false, &params);
    const args = [_]Value{.{ .Class = cls }};
    var ctx = noopCtx(a, &args, cap.output(), noop.host());

    const r = try ctorParamNames(&ctx);
    try testing.expect(r == .ok);
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(usize, 2), g.get().items.len);
    const n0 = g.get().items[0].String.borrow();
    defer n0.deinit();
    try testing.expectEqualStrings("id", n0.get().bytes);
}

test "ctorParamNames rejects a non-class argument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var noop = runtime.NoopHost.init(a);
    defer noop.deinit();
    var cap = runtime.CaptureOutput.init(a);
    defer cap.deinit();
    const args = [_]Value{.{ .Int = 1 }};
    var ctx = noopCtx(a, &args, cap.output(), noop.host());
    const r = try ctorParamNames(&ctx);
    try testing.expect(r == .err);
    try testing.expectEqualStrings("__klsx_ctorParamNames: expected a class", r.err.Type);
}

test "propGet reads a raw instance field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var noop = runtime.NoopHost.init(a);
    defer noop.deinit();
    var cap = runtime.CaptureOutput.init(a);
    defer cap.deinit();

    const cls = try makeClass(a, "Box", false, &.{});
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(a, .{ .name = "v", .value = .{ .Int = 99 } });
    const inst = try ObjRef(InstanceData).init(a, .{
        .class = cls,
        .fields = fields,
        .outer = null,
        .identity = 1,
        .native_state = null,
    });
    const args = [_]Value{ .{ .Instance = inst }, .{ .String = try runtime.strInit(a, "v") } };
    var ctx = noopCtx(a, &args, cap.output(), noop.host());

    const r = try propGet(&ctx);
    try testing.expect(r == .ok);
    try testing.expectEqual(Value{ .Int = 99 }, r.ok);
}

test "propGet rejects a non-String name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var noop = runtime.NoopHost.init(a);
    defer noop.deinit();
    var cap = runtime.CaptureOutput.init(a);
    defer cap.deinit();
    const args = [_]Value{ .{ .Int = 1 }, .{ .Int = 2 } };
    var ctx = noopCtx(a, &args, cap.output(), noop.host());
    const r = try propGet(&ctx);
    try testing.expect(r == .err);
    try testing.expectEqualStrings("__klsx_get: name must be String", r.err.Type);
}

test "classOf extracts the handle from class and instance values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cls = try makeClass(a, "C", false, &.{});
    const cv = Value{ .Class = cls };
    {
        const got = classOf(&cv);
        try testing.expect(got != null);
        try testing.expectEqualStrings("C", got.?.asPtr().name);
        got.?.deinit();
    }
    {
        const nope = Value{ .Int = 1 };
        try testing.expect(classOf(&nope) == null);
    }
}

test "hostBindings registers every serialization symbol" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_ctorParamNames") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_get") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_construct") != null);
    try testing.expect(b.resolve("kotlinx.serialization.json.__klsx_jsonEncode") != null);
    try testing.expect(b.resolve("kotlinx.serialization.json.__klsx_jsonDecode") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_isSerializable") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_customSerializer") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_isEnum") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_enumValues") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_ctorParamTypes") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_ctorParamOptional") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_ctorParamSerialNames") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_classSerialNameOverride") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_classAnnotations") != null);
    try testing.expect(b.resolve("kotlinx.serialization.__klsx_paramAnnotations") != null);
    try testing.expectEqual(@as(usize, 19), b.len());
}

test "renderShape round-trips nullability and generic args" {
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);

    try renderShape(a, &buf, .{ .name = "Int", .nullable = false, .args = &.{} });
    try testing.expectEqualStrings("Int", buf.items);

    buf.clearRetainingCapacity();
    try renderShape(a, &buf, .{ .name = "String", .nullable = true, .args = &.{} });
    try testing.expectEqualStrings("String?", buf.items);

    buf.clearRetainingCapacity();
    var inner = [_]TypeShape{.{ .name = "Int", .nullable = false, .args = &.{} }};
    try renderShape(a, &buf, .{ .name = "List", .nullable = false, .args = &inner });
    try testing.expectEqualStrings("List<Int>", buf.items);

    // A nullable generic keeps the `?` outside the argument list.
    buf.clearRetainingCapacity();
    var pair = [_]TypeShape{
        .{ .name = "String", .nullable = false, .args = &.{} },
        .{ .name = "Int", .nullable = true, .args = &.{} },
    };
    try renderShape(a, &buf, .{ .name = "Map", .nullable = true, .args = &pair });
    try testing.expectEqualStrings("Map<String, Int?>?", buf.items);
}

test {
    testing.refAllDecls(@This());
}
