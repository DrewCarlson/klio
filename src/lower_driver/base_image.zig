//! The base image of the sema pipeline: what a build over the base alone
//! leaves in the bridge and its module once the base is lowered, so a run
//! extends it (`bridge.buildOver`) instead of analyzing and lowering the base
//! again. The run checks the symbol prefix it collects against the digest
//! the image carries. A function's blocks decode on its first use.
//!
//! Ids below the bake's counts are final. Symbols a base body made (lambdas,
//! local classes, adapters' targets) are past the prefix: the run's program
//! symbols reuse those indices, so a `Sym` stored in a base entry at or past
//! `prefix` is stale and nothing reads it through sema.

const std = @import("std");
const sema = @import("sema");
const ir = @import("ir");
const interp_ir = @import("interp_ir");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;
const bridge = ir.bridge;
const resolved = ir.resolved;
const codec = interp_ir.codec;
const Sym = sema.Sym;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;

const magic = "KLIOSEMB";

/// Bumped with any change to the layout below.
pub const version: u32 = 19;

fn KV(comptime K: type, comptime V: type) type {
    return struct { k: K, v: V };
}

/// What the image says about the base it was baked from.
pub const Header = extern struct {
    version: u32,
    codec: u32,
    /// Symbols of the base layer: the by-symbol tables mean something below
    /// it only.
    prefix: u32,
    reserved: u32 = 0,
    /// `Sema.prefixDigest(prefix)` at the bake.
    digest: u64,
};

/// `Bridge`'s tables, with its maps and bit sets flattened to slices.
const BridgeImage = struct {
    origin: []const bridge.FuncOrigin,
    func_of: []const FuncId,
    getter_of: []const FuncId,
    setter_of: []const FuncId,
    defaults_of: []const FuncId,
    restart_of: []const FuncId,
    singleton_of: []const ir.StaticId,
    class_of: []const ClassId,
    static_of: []const ir.StaticId,
    field_of: []const u32,
    delegate_field_of: []const u32,
    native_of: []const ir.NativeId,
    sam_class_of: []const ClassId,
    sam_funcs_of: []const KV(Sym, bridge.SamFuncs),
    class_origin: []const bridge.ClassOrigin,
    outer_slot: []const u32,
    class_captures: []const []const bridge.CaptureKey,
    capture_base: []const u32,
    layout: []const []const bridge.Slot,
    by_slots: []const []const u32,
    slot_of: []const ir.MethodSlotId,
    captures_of: []const []const bridge.CaptureKey,
    adapters: []const bridge.Adapter,
    adapter_at: []const KV(u64, FuncId),
    units: []const bridge.Unit,
    layer_ends: []const bridge.LayerEnd,
    /// The symbols whose locals live in a cell.
    cells: []const u32,
};

/// Fields of `Bridge` the image does not carry: the run's own sema, the
/// module (carried on its own), the records and the body files, which the
/// run makes for its program, and what the run over the image sets up for
/// itself: where the image's functions and header symbols end, and the
/// JVM frame names it makes on demand.
const bridge_not_carried = [_][]const u8{ "s", "m", "records", "body_files", "image_funcs", "image_prefix", "frame_names" };

comptime {
    for (@typeInfo(bridge.Bridge).@"struct".fields) |f| {
        const carried = @hasField(BridgeImage, f.name);
        var skipped = false;
        for (bridge_not_carried) |n| {
            if (std.mem.eql(u8, n, f.name)) skipped = true;
        }
        if (!carried and !skipped) @compileError("the base image does not carry Bridge." ++ f.name);
    }
}

/// The module parts the bridge and lowering write. A function's blocks are
/// in the body section, found by `Func.deferred_offset`.
const ModuleImage = struct {
    funcs: []const ir.Func,
    classes: []const ir.Class,
    consts: []const ir.Const,
    method_dispatch: []const KV(u64, FuncId),
    class_ancestors: []const []const ClassId,
    body_section: []const u8,
};

/// A class's run-time record: its `ClassDef` is rebuilt at load from the
/// `ir.Class`, the layout and these flags (`bridge.classDefOf`).
const ClassRtImage = struct {
    seeds: []const ir.SlotSeed,
    object_ctor: u32,
    init_name: []const u8,
    jvm_name: []const u8,
    host_slot: u32,
    vtable: []const resolved.VSlot,
    itables: []const resolved.ITable,
    throwable: bool,
    flags: bridge.ClassDefFlags,
};

comptime {
    for (@typeInfo(resolved.ClassRt).@"struct".fields) |f| {
        if (!std.mem.eql(u8, f.name, "def") and !@hasField(ClassRtImage, f.name)) @compileError("the base image does not carry ClassRt." ++ f.name);
    }
}

/// `T` without its fields named in `skip`.
fn Without(comptime T: type, comptime skip: []const []const u8) type {
    const src = @typeInfo(T).@"struct".fields;
    var names: [src.len - skip.len][]const u8 = undefined;
    var types: [src.len - skip.len]type = undefined;
    var n: usize = 0;
    outer: for (src) |f| {
        for (skip) |sk| if (std.mem.eql(u8, f.name, sk)) continue :outer;
        names[n] = f.name;
        types[n] = f.type;
        n += 1;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

/// Copies every field `Out` has from `in`.
fn project(comptime Out: type, in: anytype) Out {
    var out: Out = undefined;
    inline for (@typeInfo(Out).@"struct".fields) |f| @field(out, f.name) = @field(in, f.name);
    return out;
}

/// A native's record without its host functions, which are bound again at
/// load from `table` and `key` (`bridge.rebindNative`).
const NativeRtImage = Without(resolved.NativeRt, &.{ "func", "host_fn", "host_try" });

const ExceptionsImage = struct {
    fixed: Without(resolved.Exceptions, &.{"by_fqn"}),
    by_fqn: []const KV([]const u8, resolved.Raised),
};

/// `Resolved` with its classes' and natives' host parts left for the load
/// to make, and its map flattened.
const ResolvedImage = struct {
    classes: []const ClassRtImage,
    statics: []const resolved.StaticRt,
    init_units: []const resolved.InitUnitRt,
    facade_unit: []const u32,
    natives: []const NativeRtImage,
    func_native: []const ir.NativeId,
    func_try: []const ir.NativeId,
    host_slot: []const ir.NativeId,
    slot_index: []const u32,
    slot_iface: []const u32,
    well_known: resolved.WellKnownSlots,
    well_known_objects: resolved.WellKnownObjects,
    host_class: resolved.HostClasses,
    exceptions: ExceptionsImage,
    base: resolved.BaseClasses,
    serializers: []const ?resolved.SerializerRt,
};

comptime {
    for (@typeInfo(ir.Resolved).@"struct".fields) |f| {
        // The frame namer is the run's bridge, which the run sets.
        if (std.mem.eql(u8, f.name, "frame_namer")) continue;
        if (!@hasField(ResolvedImage, f.name)) @compileError("the base image does not carry Resolved." ++ f.name);
    }
}

const Image = struct {
    bridge: BridgeImage,
    module: ModuleImage,
    resolved: ResolvedImage,
    /// The functions whose bodies the bake lowered; inline calls in the
    /// program instantiate them.
    lowered: []const u32,
};

// ------------------------------------------------------------- encoding --

/// Serializes the base: `br` as a build over the base alone left it, with
/// its bodies lowered. `prefix` is the symbol count at the base layer's end.
/// The result is owned by `gpa`.
pub fn encode(gpa: Allocator, scratch: Allocator, s: *const sema.Sema, br: *const bridge.Bridge, lowered: *const std.DynamicBitSetUnmanaged, prefix: u32) ![]u8 {
    const m = br.m;
    var lowered_ids: std.ArrayList(u32) = .empty;
    var lit = lowered.iterator(.{});
    while (lit.next()) |i| try lowered_ids.append(scratch, @intCast(i));
    // Bodies go to a section of their own, each self-contained, so a run
    // decodes only the ones it calls.
    var section: std.ArrayList(u8) = .empty;
    defer section.deinit(gpa);
    const funcs = try scratch.alloc(ir.Func, m.funcs.items.len);
    for (m.funcs.items, funcs) |*f, *out| {
        out.* = f.*;
        out.deferred_offset = 0;
        if (f.blocks.len == 0) continue;
        const bytes = try codec.encodeBytes([]ir.Block, gpa, &f.blocks);
        defer gpa.free(bytes);
        out.deferred_offset = @intCast(section.items.len + 1);
        try section.appendSlice(gpa, bytes);
        out.blocks = &.{};
    }
    var dispatch: std.ArrayList(KV(u64, FuncId)) = .empty;
    var it = m.method_dispatch.iterator();
    while (it.next()) |e| try dispatch.append(scratch, .{ .k = e.key_ptr.*, .v = e.value_ptr.* });
    std.mem.sort(KV(u64, FuncId), dispatch.items, {}, struct {
        fn lt(_: void, x: KV(u64, FuncId), y: KV(u64, FuncId)) bool {
            return x.k < y.k;
        }
    }.lt);
    const img: Image = .{
        .lowered = lowered_ids.items,
        .resolved = try resolvedImage(scratch, m),
        .bridge = try bridgeImage(scratch, br),
        .module = .{
            .funcs = funcs,
            .classes = m.classes.items,
            .consts = m.consts.items,
            .method_dispatch = dispatch.items,
            .class_ancestors = m.class_ancestors.items,
            .body_section = section.items,
        },
    };
    const payload = try codec.encodeBytes(Image, gpa, &img);
    defer gpa.free(payload);
    const hdr: Header = .{ .version = version, .codec = codec.FORMAT_VERSION, .prefix = prefix, .digest = s.prefixDigest(prefix) };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, magic);
    try out.appendSlice(gpa, std.mem.asBytes(&hdr));
    try out.appendSlice(gpa, payload);
    return out.toOwnedSlice(gpa);
}

fn bridgeImage(a: Allocator, br: *const bridge.Bridge) !BridgeImage {
    var sam: std.ArrayList(KV(Sym, bridge.SamFuncs)) = .empty;
    var sit = br.sam_funcs_of.iterator();
    while (sit.next()) |e| try sam.append(a, .{ .k = e.key_ptr.*, .v = e.value_ptr.* });
    std.mem.sort(KV(Sym, bridge.SamFuncs), sam.items, {}, struct {
        fn lt(_: void, x: KV(Sym, bridge.SamFuncs), y: KV(Sym, bridge.SamFuncs)) bool {
            return x.k.int() < y.k.int();
        }
    }.lt);
    var at: std.ArrayList(KV(u64, FuncId)) = .empty;
    var ait = br.adapter_at.iterator();
    while (ait.next()) |e| try at.append(a, .{ .k = e.key_ptr.*, .v = e.value_ptr.* });
    std.mem.sort(KV(u64, FuncId), at.items, {}, struct {
        fn lt(_: void, x: KV(u64, FuncId), y: KV(u64, FuncId)) bool {
            return x.k < y.k;
        }
    }.lt);
    var cells: std.ArrayList(u32) = .empty;
    var cit = br.cells.iterator(.{});
    while (cit.next()) |i| try cells.append(a, @intCast(i));
    var img: BridgeImage = undefined;
    inline for (@typeInfo(BridgeImage).@"struct".fields) |f| {
        if (comptime !isFlattened(f.name)) @field(img, f.name) = @field(br, f.name);
    }
    img.sam_funcs_of = sam.items;
    img.adapter_at = at.items;
    img.cells = cells.items;
    return img;
}

fn resolvedImage(a: Allocator, m: *const ir.Module) !ResolvedImage {
    const r = m.resolved orelse return error.Unresolved;
    const classes = try a.alloc(ClassRtImage, r.classes.len);
    for (r.classes, classes) |rt, *out| {
        const def = rt.def.asPtrConst();
        const primary = try a.alloc(bridge.PrimaryProperty, def.primary_params.len);
        for (def.primary_params, primary) |p, *pp| pp.* = .{ .name = p.name, .mutable = p.property orelse false };
        out.* = .{ .seeds = rt.seeds, .object_ctor = rt.object_ctor, .init_name = rt.init_name, .jvm_name = rt.jvm_name, .host_slot = rt.host_slot, .vtable = rt.vtable, .itables = rt.itables, .throwable = rt.throwable, .flags = .{ .is_data = def.is_data, .is_sealed = def.is_sealed, .is_anonymous = def.is_anonymous, .primary = primary } };
    }
    const natives = try a.alloc(NativeRtImage, r.natives.len);
    for (r.natives, natives) |rt, *out| out.* = project(NativeRtImage, rt);
    var by_fqn: std.ArrayList(KV([]const u8, resolved.Raised)) = .empty;
    var it = r.exceptions.by_fqn.iterator();
    while (it.next()) |e| try by_fqn.append(a, .{ .k = e.key_ptr.*, .v = e.value_ptr.* });
    std.mem.sort(KV([]const u8, resolved.Raised), by_fqn.items, {}, struct {
        fn lt(_: void, x: KV([]const u8, resolved.Raised), y: KV([]const u8, resolved.Raised)) bool {
            return std.mem.lessThan(u8, x.k, y.k);
        }
    }.lt);
    const fixed = project(@FieldType(ExceptionsImage, "fixed"), r.exceptions);
    return .{
        .classes = classes,
        .statics = r.statics,
        .init_units = r.init_units,
        .facade_unit = r.facade_unit,
        .natives = natives,
        .func_native = r.func_native,
        .func_try = r.func_try,
        .host_slot = r.host_slot,
        .slot_index = r.slot_index,
        .slot_iface = r.slot_iface,
        .well_known = r.well_known,
        .well_known_objects = r.well_known_objects,
        .host_class = r.host_class,
        .exceptions = .{ .fixed = fixed, .by_fqn = by_fqn.items },
        .base = r.base,
        .serializers = r.serializers,
    };
}

fn isFlattened(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "sam_funcs_of") or std.mem.eql(u8, name, "adapter_at") or std.mem.eql(u8, name, "cells");
}

// ------------------------------------------------------------- decoding --

pub const Loaded = struct {
    header: Header,
    br: *bridge.Bridge,
    /// By base function: its body was lowered at the bake.
    lowered: std.DynamicBitSetUnmanaged,
};

pub const LoadError = error{ OutOfMemory, Malformed, Stale };

/// The header of an image, or null when `bytes` is not one this build reads.
pub fn header(bytes: []const u8) ?Header {
    if (bytes.len < magic.len + @sizeOf(Header)) return null;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
    var h: Header = undefined;
    @memcpy(std.mem.asBytes(&h), bytes[magic.len .. magic.len + @sizeOf(Header)]);
    if (h.version != version or h.codec != codec.FORMAT_VERSION) return null;
    return h;
}

/// Where a native's host function is found again at load.
pub const Rebind = struct {
    natives: bridge.NativeResolver,
    constructors: ?bridge.NativeResolver = null,
    host_fns: ?resolved.HostFnResolver = null,
    host_tries: ?resolved.HostTryResolver = null,
};

/// Decodes the image into `a` as a bridge over `s`, whose base layer must
/// be the one the image was baked from, and whose natives `rebind` still
/// has (`error.Stale` otherwise). `bytes` must outlive the result: names and
/// the body section point into it.
pub fn decode(a: Allocator, bytes: []const u8, s: *sema.Sema, rebind: Rebind) LoadError!Loaded {
    const h = header(bytes) orelse return error.Malformed;
    if (s.syms.count() < h.prefix or s.prefixDigest(h.prefix) != h.digest) return error.Stale;
    const img = codec.decodeBytes(Image, a, bytes[magic.len + @sizeOf(Header) ..]) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Malformed => error.Malformed,
    };
    const m = try a.create(ir.Module);
    m.* = ir.Module.init(a);
    try m.funcs.appendSlice(a, img.module.funcs);
    try m.classes.appendSlice(a, img.module.classes);
    try m.consts.appendSlice(a, img.module.consts);
    try m.class_ancestors.appendSlice(a, img.module.class_ancestors);
    for (img.module.method_dispatch) |e| try m.method_dispatch.put(e.k, e.v);
    m.deferred_func_section = img.module.body_section;
    m.deferred_func_arena = a;
    // A body decodes once, into `a`, and stays on its `Func`.
    m.deferred_func_decode = codec.decodeFuncBlocks;

    const br = try a.create(bridge.Bridge);
    br.* = .{ .s = s, .m = m };
    inline for (@typeInfo(BridgeImage).@"struct".fields) |f| {
        if (comptime !isFlattened(f.name)) @field(br, f.name) = @constCast(@field(img.bridge, f.name));
    }
    for (img.bridge.sam_funcs_of) |e| try br.sam_funcs_of.put(a, e.k, e.v);
    for (img.bridge.adapter_at) |e| try br.adapter_at.put(a, e.k, e.v);
    br.cells = try std.DynamicBitSetUnmanaged.initEmpty(a, br.func_of.len);
    for (img.bridge.cells) |i| {
        if (i < br.cells.bit_length) br.cells.set(i);
    }
    m.resolved = try loadResolved(a, &img.resolved, m, br, rebind);
    var lowered = try std.DynamicBitSetUnmanaged.initEmpty(a, m.funcs.items.len);
    for (img.lowered) |i| {
        if (i >= lowered.bit_length) return error.Malformed;
        lowered.set(i);
    }
    return .{ .header = h, .br = br, .lowered = lowered };
}

fn loadResolved(a: Allocator, img: *const ResolvedImage, m: *const ir.Module, br: *const bridge.Bridge, rebind: Rebind) LoadError!*ir.Resolved {
    const r = try a.create(ir.Resolved);
    r.* = .{};
    const classes = try a.alloc(resolved.ClassRt, img.classes.len);
    for (img.classes, classes, 0..) |ci, *rt, i| {
        if (i >= m.classes.items.len or i >= br.layout.len) return error.Malformed;
        rt.* = .{
            .def = try bridge.classDefOf(a, m, i, br.layout[i], ci.flags),
            .seeds = ci.seeds,
            .object_ctor = ci.object_ctor,
            .init_name = ci.init_name,
            .jvm_name = ci.jvm_name,
            .host_slot = ci.host_slot,
            .vtable = ci.vtable,
            .itables = ci.itables,
            .throwable = ci.throwable,
        };
    }
    r.classes = classes;
    const natives = try a.alloc(resolved.NativeRt, img.natives.len);
    for (img.natives, natives) |ni, *rt| {
        rt.* = .{ .func = undefined, .name = undefined };
        inline for (@typeInfo(NativeRtImage).@"struct".fields) |f| @field(rt, f.name) = @field(ni, f.name);
        if (!bridge.rebindNative(rt, rebind.natives, rebind.constructors, rebind.host_fns, rebind.host_tries)) return error.Stale;
    }
    r.natives = natives;
    var exceptions: resolved.Exceptions = .{};
    inline for (@typeInfo(@FieldType(ExceptionsImage, "fixed")).@"struct".fields) |f| @field(exceptions, f.name) = @field(img.exceptions.fixed, f.name);
    for (img.exceptions.by_fqn) |e| try exceptions.by_fqn.put(a, e.k, e.v);
    r.exceptions = exceptions;
    r.statics = @constCast(img.statics);
    r.init_units = @constCast(img.init_units);
    r.facade_unit = img.facade_unit;
    r.func_native = @constCast(img.func_native);
    r.func_try = img.func_try;
    r.host_slot = img.host_slot;
    r.slot_index = img.slot_index;
    r.slot_iface = img.slot_iface;
    r.well_known = img.well_known;
    r.well_known_objects = img.well_known_objects;
    r.host_class = img.host_class;
    r.base = img.base;
    r.serializers = img.serializers;
    return r;
}
