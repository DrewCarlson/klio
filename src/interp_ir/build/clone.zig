//! Per-run cloning of the dependency snapshot: every runtime-mutable
//! structure the base holds is deep-copied so nothing a run mutates is
//! shared across programs.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;
const Module = ir.Module;
const FuncId = ir.FuncId;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const Env = runtime.Env;
const ObjRef = runtime.ObjRef;
const Value = runtime.Value;

const build_types = @import("types.zig");
const BuiltModule = build_types.BuiltModule;
const ClassTable = build_types.ClassTable;
const emptyBuilt = build_types.emptyBuilt;
const PairFuncMap = build_types.PairFuncMap;
const SecondaryCtorEntry = build_types.SecondaryCtorEntry;
const StrFunc = build_types.StrFunc;

/// Per-run clone of the base's BuiltModule onto `a`. Spines are copied;
/// lowered leaf data (instructions, strings, thunk-id slices) is shared
/// with the immutable base. Runtime-mutable graphs (the ClassDef table,
/// enum-entry instances, companion/object/captured-env cells) are deep
/// cloned so a run can never write through to the base.
pub fn cloneBuiltForRun(a: Allocator, base: *const BuiltModule) Allocator.Error!BuiltModule {
    const module_clone = blk: {
        const mg = base.module.borrow();
        defer mg.deinit();
        break :blk try mg.get().cloneForExtend(a);
    };
    const module_ref = try ObjRef(Module).init(a, module_clone);
    var out = emptyBuilt(a, module_ref, base.main);

    out.classes.deinit();
    out.classes = try cloneClassTableForRun(a, &base.classes);

    try copyPairMap(&out.body_prop_inits, &base.body_prop_inits);
    try copyPairMap(&out.instance_prop_getters, &base.instance_prop_getters);
    {
        var it = base.getter_prop_names.keyIterator();
        while (it.next()) |k| try out.getter_prop_names.put(k.*, {});
    }
    try copyPairMap(&out.instance_prop_setters, &base.instance_prop_setters);
    try copyPairMap(&out.instance_prop_private, &base.instance_prop_private);
    try copyStrMap([]FuncId, &out.parent_ctor_args, &base.parent_ctor_args);
    // Parallel to `parent_ctor_args`: without this a class inherited from the
    // base loses its super-constructor argument labels, so a named super-ctor
    // argument that skips an earlier defaulted parameter (`Operation(objects =
    // 2)`) binds positionally onto the wrong parameter.
    try copyStrMap([]const ?[]const u8, &out.parent_ctor_arg_names, &base.parent_ctor_arg_names);
    try copyStrMap([]FuncId, &out.init_blocks, &base.init_blocks);
    try out.top_level_props.appendSlice(a, base.top_level_props.items);
    try copyPairMap(&out.extension_props, &base.extension_props);
    {
        var it = base.owner_keyed_ext_names.keyIterator();
        while (it.next()) |k| try out.owner_keyed_ext_names.put(k.*, {});
    }
    {
        var it = base.nullable_ext_props.iterator();
        while (it.next()) |e| try out.nullable_ext_props.put(e.key_ptr.*, e.value_ptr.*);
    }
    try copyPairMap(&out.extension_prop_delegates, &base.extension_prop_delegates);
    try copyPairMap(&out.extension_prop_setters, &base.extension_prop_setters);
    try out.object_names.appendSlice(a, base.object_names.items);
    try copyStrMap([]const u8, &out.companion_singletons, &base.companion_singletons);
    try out.enum_entry_arg_inits.appendSlice(a, base.enum_entry_arg_inits.items);
    try copyStrMap([]SecondaryCtorEntry, &out.secondary_ctors, &base.secondary_ctors);
    try copyStrMap([]?FuncId, &out.primary_ctor_default_thunks, &base.primary_ctor_default_thunks);
    try copyStrMap([]StrFunc, &out.class_delegates, &base.class_delegates);
    {
        var it = base.func_defaults.iterator();
        while (it.next()) |e| try out.func_defaults.put(e.key_ptr.*, e.value_ptr.*);
    }
    try copyStrMap([]const u8, &out.enclosing_class, &base.enclosing_class);
    {
        var it = base.enum_entry_methods.iterator();
        while (it.next()) |e| try out.enum_entry_methods.put(e.key_ptr.*, e.value_ptr.*);
    }
    {
        var it = base.enum_entry_synth_class.iterator();
        while (it.next()) |e| try out.enum_entry_synth_class.put(e.key_ptr.*, e.value_ptr.*);
    }
    {
        var it = base.func_type_params.iterator();
        while (it.next()) |e| try out.func_type_params.put(e.key_ptr.*, e.value_ptr.*);
    }
    {
        var it = base.top_level_delegated_props.keyIterator();
        while (it.next()) |k| try out.top_level_delegated_props.put(k.*, {});
    }
    {
        var it = base.delegated_body_props.keyIterator();
        while (it.next()) |k| try out.delegated_body_props.put(k.*, {});
    }
    return out;
}

pub fn copyPairMap(dst: *PairFuncMap, src: *const PairFuncMap) Allocator.Error!void {
    var it = src.iterator();
    while (it.next()) |e| try dst.put(e.key_ptr.*, e.value_ptr.*);
}

pub fn copyStrMap(comptime V: type, dst: *std.StringHashMap(V), src: *const std.StringHashMap(V)) Allocator.Error!void {
    var it = src.iterator();
    while (it.next()) |e| try dst.put(e.key_ptr.*, e.value_ptr.*);
}

/// Resolve a class written with a dotted qualifier (`Outer.Inner`) by matching
/// it as a `.`-aligned suffix of a registered class's FQN, preferring the
/// shortest (least-nested) match. The table holds each class under both its
/// simple name and FQN, so scanning values (not keys) avoids double-counting.
pub fn classTableByQualifiedSuffix(classes: *const ClassTable, qualified: []const u8) ?ObjRef(ClassDef) {
    if (std.mem.findScalar(u8, qualified, '.') == null) return null;
    var best: ?ObjRef(ClassDef) = null;
    var best_len: usize = std.math.maxInt(usize);
    var it = classes.valueIterator();
    while (it.next()) |d| {
        const dg = d.borrow();
        const fqn = dg.get().fqn;
        const ok = std.mem.endsWith(u8, fqn, qualified) and
            (fqn.len == qualified.len or fqn[fqn.len - qualified.len - 1] == '.');
        const flen = fqn.len;
        dg.deinit();
        if (ok and flen < best_len) {
            best_len = flen;
            best = d.*;
        }
    }
    return best;
}

/// Deep-clone the runtime ClassDef graph: a run mutates ClassDefs (startup
/// patches enum-entry instance fields; companions and object singletons
/// fill lazily), so per-run defs must be private. Lowered/AST leaf slices
/// (methods, properties, ctor metadata) stay shared with the base.
pub fn cloneClassTableForRun(a: Allocator, src: *const ClassTable) Allocator.Error!ClassTable {
    var remap = std.AutoHashMap(usize, ObjRef(ClassDef)).init(a);
    defer remap.deinit();

    // Pass 1: shells for every unique def cell.
    {
        var it = src.valueIterator();
        while (it.next()) |def| {
            const key = @intFromPtr(def.cell);
            if (remap.contains(key)) continue;
            const g = def.borrow();
            var copy: ClassDef = g.get().*;
            g.deinit();
            copy.companion = try ObjRef(?ObjRef(InstanceData)).init(a, null);
            copy.object_singleton = try ObjRef(?ObjRef(InstanceData)).init(a, null);
            copy.enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(a, null);
            copy.captured_env = try ObjRef(Env).init(a, Env.init(a));
            copy.parent = null;
            copy.interfaces = &.{};
            copy.nested_classes = &.{};
            copy.enum_entries = &.{};
            try remap.put(key, try ObjRef(ClassDef).init(a, copy));
        }
    }

    // Pass 2: re-link the graph through the remap and deep-clone the
    // runtime-mutable payloads.
    {
        var it = src.valueIterator();
        while (it.next()) |def| {
            const key = @intFromPtr(def.cell);
            const cloned = remap.get(key).?;
            const sg = def.borrow();
            defer sg.deinit();
            const s = sg.get();
            const cg = cloned.borrowMut();
            defer cg.deinit();
            const c = cg.get();

            if (s.parent) |p| {
                if (remap.get(@intFromPtr(p.cell))) |np| c.parent = np.clone();
            }
            if (s.interfaces.len != 0) {
                const ifaces = try a.alloc(ObjRef(ClassDef), s.interfaces.len);
                for (s.interfaces, 0..) |iface, i| {
                    ifaces[i] = if (remap.get(@intFromPtr(iface.cell))) |ni| ni.clone() else iface.clone();
                }
                c.interfaces = ifaces;
            }
            if (s.nested_classes.len != 0) {
                const nested = try a.alloc(ClassDef.NestedClass, s.nested_classes.len);
                for (s.nested_classes, 0..) |nc, i| {
                    nested[i] = .{
                        .name = nc.name,
                        .class = if (remap.get(@intFromPtr(nc.class.cell))) |nn| nn.clone() else nc.class.clone(),
                    };
                }
                c.nested_classes = nested;
            }
            {
                const eg = s.enclosing_class.borrow();
                const enc = eg.get().*;
                eg.deinit();
                if (enc) |ec| {
                    const mapped = if (remap.get(@intFromPtr(ec.cell))) |ne| ne.clone() else ec.clone();
                    const cgi = c.enclosing_class.borrowMut();
                    cgi.get().* = mapped;
                    cgi.deinit();
                }
            }
            if (s.enum_entries.len != 0) {
                const entries = try a.alloc(ClassDef.EnumEntry, s.enum_entries.len);
                for (s.enum_entries, 0..) |entry, i| {
                    entries[i] = .{ .name = entry.name, .value = try cloneBuildValue(a, &remap, entry.value) };
                }
                c.enum_entries = entries;
            }
        }
    }

    var out = ClassTable.init(a);
    var kit = src.iterator();
    while (kit.next()) |e| {
        try out.put(e.key_ptr.*, remap.get(@intFromPtr(e.value_ptr.cell)).?.clone());
    }
    // Drop the construction handles; the table's clones keep the cells live.
    var rit = remap.valueIterator();
    while (rit.next()) |r| r.deinit();
    return out;
}

/// Clone a build-time Value reachable from an enum entry. Instances are
/// deep-cloned (their fields are patched at startup); every other variant
/// is shared — at build time those are immutable payloads (entry-name
/// strings, ordinals) the run never writes through.
pub fn cloneBuildValue(a: Allocator, remap: *const std.AutoHashMap(usize, ObjRef(ClassDef)), v: Value) Allocator.Error!Value {
    switch (v) {
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            const s = g.get();
            var fields: std.ArrayList(InstanceData.Field) = .empty;
            for (s.fields.items) |f| {
                try fields.append(a, .{ .name = f.name, .value = try cloneBuildValue(a, remap, f.value) });
            }
            const cls = if (remap.get(@intFromPtr(s.class.cell))) |nc| nc.clone() else s.class.clone();
            const copy = try ObjRef(InstanceData).init(a, .{
                .class = cls,
                .fields = fields,
                .outer = s.outer,
                .identity = s.identity,
                .native_state = s.native_state,
            });
            return .{ .Instance = copy };
        },
        else => return v,
    }
}
