//! The once-per-process dependency base: stdlib and pack files are lowered one time
//! into an immutable snapshot, and each program extends an arena-backed clone with its
//! own declarations. The snapshot is never run and every runtime-mutable structure is
//! deep-cloned per program, so nothing a run mutates is shared.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const FF = runtime.forest.ForestField;
const ast = @import("ast");
const compose_pass = @import("compose_pass");
const span = @import("span");
const prune = @import("../prune.zig");
const image = @import("../image.zig");

const Allocator = std.mem.Allocator;
const KotlinFile = ast.KotlinFile;
const Decl = ast.Decl;
const StringSet = std.StringHashMap(void);

const build_module = @import("module.zig");
const buildModuleFilesInner = build_module.buildModuleFilesInner;

const build_types = @import("types.zig");
const BuiltModule = build_types.BuiltModule;

/// Owned by a process-lifetime arena; safe to read from many threads once built.
pub const StdlibBase = struct {
    /// The lowered dependency program. Cloned, never consumed, per run.
    built: BuiltModule,
    /// Post-lift, post-retain decls: the universe the extending build scans, un-lowered.
    lifted_decls: []const Decl,
    /// Every top-level simple name the base declares, raw and post-lift; a user program
    /// redeclaring one falls back to the whole-program build.
    decl_names: StringSet,
    /// The `decl_names` subset in the ROOT package plus every lifted or mangled decl: only
    /// these collide with a root-package user declaration, a named-package base decl being
    /// invisible to bare references elsewhere.
    root_decl_names: StringSet,
    /// Packages the base files declare; a user file sharing one falls back.
    packages: StringSet,
    /// A user function-type typealias matching one would rewrite base param types, so the
    /// extend build falls back.
    param_type_names: StringSet,
    /// Top-level type simple names, seeded into the extending build's collision universe.
    type_names: StringSet,
    /// Replayed into the per-build inline-fn registry so user calls to base inline fns splice.
    inline_ids: []const InlineId,
    /// Simple name to base inline-fn forest refs, overloads in declaration order. Empty for
    /// a freshly-built base; an image's also covers member inline fns, which have no stub.
    inline_by_name: []const InlineNames = &.{},
    /// Class simple name to forest ref, for a user class reaching into a base class.
    file_classes: []const ClassRef = &.{},
    /// Base file-scope property scope data, strings only. Empty for a freshly-built base.
    top_props: []const TopProp = &.{},
    fn_returns: []const FnReturn = &.{},
    ext_returns: []const ExtReturn = &.{},
    eager_calls: []const EagerCall = &.{},
    /// Base SourceMap files occupy ids [0..user_file_start).
    user_file_start: u32,
    /// Continues the base build's sequence so default toString/hashCode numbering matches.
    enum_id_next: u64,
    /// Encoded `inline`, object-free function bodies, decoded lazily on first splice and
    /// borrowing the image buffer. Empty for a freshly-built base, which keeps full bodies.
    deferred_bodies: []const u8 = &.{},
    /// Per-decl encodings of `lifted_decls` with byte offsets (decl `i` at
    /// `lifted_decl_offsets[i]`), decoded on first touch. Borrow the image buffer.
    lifted_decl_section: []const u8 = &.{},
    lifted_decl_offsets: []const u32 = &.{},
    /// The process-lifetime allocator the base lives in: a lazily decoded deferred body
    /// must outlive a per-program build, so it decodes here.
    arena: Allocator = undefined,

    pub const InlineId = struct { id: u32, f: FF(ast.Function) };
    pub const InlineNames = struct { k: []const u8, v: []const runtime.forest.ForestRef };
    pub const ClassRef = struct { k: []const u8, v: runtime.forest.ForestRef };
    pub const TopProp = struct { name: []const u8, fqn: []const u8, package: []const u8, type_head: []const u8 = "" };
    /// Baked because an image's funcs are lazy: nothing else can say what `listOf` returns.
    pub const FnReturn = struct { name: []const u8, head: []const u8 };
    /// An EXTENSION's return class head, keyed `<receiver head>\x00<name>`. Declaration
    /// signatures carry no return type, so a chained call would lose its receiver class.
    pub const ExtReturn = struct { key: []const u8, head: []const u8 };
    /// A base call site and the declaration the checker picked, replayed at load because a
    /// cached run never parses the sources.
    pub const EagerCall = struct { call: span.Span, fid: u32 };
};

/// The allocator must be the process-lifetime base arena. Null when the base is not
/// snapshot-safe (resolve diagnostics or a `main`), leaving the full per-program build.
pub fn buildStdlibBase(allocator: Allocator, files: []const KotlinFile) Allocator.Error!?*StdlibBase {
    return buildBaseInner(allocator, files, false);
}

/// The parent's primary parameter at `idx`, instantiated by the supertype's written
/// type arguments. Null when the parent or parameter is unknown.
pub fn parentCtorParamExpected(a: Allocator, module: *ir.Module, c: *const ast.Class, sup_idx: usize, idx: usize) ?ast.TypeRef {
    if (sup_idx >= c.supertypes.len) return null;
    const sup = &c.supertypes[sup_idx];
    const file = sup.name.span.file;
    const pkg = module.packageOfFile(file) orelse "";
    const cid = (if (sup.qualified_path) |qp| module.classIdByQualifiedSuffix(qp) else null) orelse
        module.classIdIndexed(sup.name.name, pkg, file) orelse module.classId(sup.name.name) orelse return null;
    if (cid.int() >= module.classes.items.len) return null;
    const pc = &module.classes.items[cid.int()];
    if (idx >= pc.primary_params.len) return null;
    const pty = pc.primary_params[idx].ty;
    return irTypeToAstInstantiated(a, pty, pc.type_params, sup.type_args, sup.name.span) catch null;
}

pub fn irTypeToAstInstantiated(a: Allocator, ty: ir.TypeRef, tps: []const []const u8, written: []const ast.TypeArg, sp: ast.Span) Allocator.Error!ast.TypeRef {
    var nm = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.startsWith(u8, nm, "in#")) nm = nm[3..];
    if (std.mem.startsWith(u8, nm, "out#")) nm = nm[4..];
    if (std.mem.findScalar(u8, nm, '<')) |lt| nm = nm[0..lt];
    // The parent's own type parameter: the written argument at its position.
    for (tps, 0..) |tp, i| {
        if (std.mem.eql(u8, tp, nm) and i < written.len and !written[i].is_star) {
            var out = written[i].ty;
            out.nullable = out.nullable or ty.nullable;
            return out;
        }
    }
    const args = try a.alloc(ast.TypeArg, ty.args.len);
    for (ty.args, args) |arg, *out| {
        out.* = .{ .variance = .Invariant, .is_star = false, .ty = try irTypeToAstInstantiated(a, arg, tps, written, sp), .span = sp };
    }
    return .{
        .name = .{ .name = try a.dupe(u8, nm), .span = sp },
        .nullable = ty.nullable,
        .span = sp,
        .type_args = args,
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

pub fn buildProgramBase(allocator: Allocator, files: []const KotlinFile) Allocator.Error!?*StdlibBase {
    return buildBaseInner(allocator, files, true);
}

pub fn buildBaseInner(allocator: Allocator, files: []const KotlinFile, allow_main: bool) Allocator.Error!?*StdlibBase {
    var lifted: []Decl = &.{};
    var built = try buildModuleFilesInner(allocator, files, null, &lifted);
    {
        const mg = built.module.borrow();
        defer mg.deinit();
        const main_ok = if (allow_main) built.main != null else built.main == null;
        if (mg.get().resolve_diags.items.len != 0 or !main_ok) {
            built.deinit();
            return null;
        }
    }

    const base = try allocator.create(StdlibBase);
    base.* = .{
        .built = built,
        .lifted_decls = lifted,
        .decl_names = StringSet.init(allocator),
        .root_decl_names = StringSet.init(allocator),
        .packages = StringSet.init(allocator),
        .param_type_names = StringSet.init(allocator),
        .type_names = StringSet.init(allocator),
        .inline_ids = &.{},
        .user_file_start = 0,
        .enum_id_next = 1,
        .arena = allocator,
    };

    // Name universes for the reuse gate span raw AND lifted decls: a lifted or mangled
    // name is a real top-level slot too.
    for (files) |*f| {
        if (f.package) |p| {
            var dotted: std.ArrayList(u8) = .empty;
            for (p.path, 0..) |id, i| {
                if (i != 0) try dotted.append(allocator, '.');
                try dotted.appendSlice(allocator, id.name);
            }
            try base.packages.put(try dotted.toOwnedSlice(allocator), {});
        }
        for (f.decls) |*d| try noteBaseDeclNames(base, d, f.package == null);
    }
    // Mangled lift names carry `$`, never a legal user identifier, and plain-named lifts
    // follow their package scoping; both join the general universe only.
    for (base.lifted_decls) |*d| try noteBaseDeclNames(base, d, false);

    {
        const mg = base.built.module.borrow();
        defer mg.deinit();
        const module = mg.get();
        var inline_ids: std.ArrayList(StdlibBase.InlineId) = .empty;
        for (module.funcs.items) |*f| {
            for (f.params) |*p| try base.param_type_names.put(p.ty.name, {});
            if (f.is_inline) {
                if (ir.lower.inline_state.inlineAstById(f.id.int())) |fn_ast| {
                    try inline_ids.append(allocator, .{ .id = f.id.int(), .f = FF(ast.Function).fromPtr(fn_ast) });
                }
            }
        }
        base.inline_ids = try inline_ids.toOwnedSlice(allocator);
    }

    // Continue the enum-entry identity sequence: identities run 1..N in build order.
    {
        var counted = std.AutoHashMap(usize, void).init(allocator);
        defer counted.deinit();
        var n: u64 = 0;
        var it = base.built.classes.valueIterator();
        while (it.next()) |def| {
            const gop = try counted.getOrPut(@intFromPtr(def.cell));
            if (gop.found_existing) continue;
            const g = def.borrow();
            n += g.get().enum_entries.len;
            g.deinit();
        }
        base.enum_id_next = 1 + n;
    }

    // A non-inline base function runs from its lowered IR, never its AST body, so stripping
    // those bodies drops dead trees while keeping dispatch metadata.
    prune.stripDeadBodies(@constCast(base.lifted_decls), true);

    return base;
}

/// The base's lifted decls for the compose-plugin collectors, which need the whole base
/// surface: an image-loaded base decodes every section decl here.
pub fn composeBaseDecls(allocator: Allocator, base: *const StdlibBase) Allocator.Error![]const Decl {
    if (base.lifted_decls.len != 0) return base.lifted_decls;
    if (base.lifted_decl_section.len == 0 or base.lifted_decl_offsets.len == 0) return &.{};
    const out = try allocator.alloc(Decl, base.lifted_decl_offsets.len);
    var n: usize = 0;
    for (base.lifted_decl_offsets) |off| {
        if (image.decodeLiftedDecl(allocator, base.lifted_decl_section, off)) |d| {
            out[n] = d;
            n += 1;
        }
    }
    return out[0..n];
}

pub fn composeBaseNames(names: *std.StringHashMap(void), base_decls: []const Decl) Allocator.Error!void {
    for (base_decls) |*d| try composeBaseNameDecl(names, d);
}

pub fn composeBaseNameDecl(names: *std.StringHashMap(void), d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| if (compose_pass.isComposable(f.annotations)) try names.put(f.name.name, {}),
        .Class => |*c| for (c.members) |*m| try composeBaseNameDecl(names, m),
        .Object => |*o| for (o.members) |*m| try composeBaseNameDecl(names, m),
        else => {},
    }
}

/// Base functions taking a `@Composable` lambda parameter: the sinks user composable
/// calls pass into.
pub fn composeBaseSinks(sinks: *std.StringHashMap(void), base_decls: []const Decl) Allocator.Error!void {
    for (base_decls) |*d| try composeBaseSinkDecl(sinks, d);
}

pub fn composeBaseInlineFns(set: *std.StringHashMap(void), base_decls: []const Decl) Allocator.Error!void {
    for (base_decls) |*d| {
        try compose_pass.collectInlineFnNamesInto(set, @as([*]const Decl, @ptrCast(d))[0..1]);
    }
}

pub fn composeBaseComposableGetterProps(props: *std.StringHashMap(void), base_decls: []const Decl) Allocator.Error!void {
    for (base_decls) |*d| {
        try compose_pass.collectComposableGetterPropsInto(props, @as([*]const Decl, @ptrCast(d))[0..1]);
    }
}

pub fn composeBaseFactoryDecl(factories: *std.StringHashMap(void), d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| {
            if (f.return_type) |*rt| {
                if (rt.function != null and compose_pass.isComposable(rt.annotations)) {
                    try factories.put(f.name.name, {});
                }
            }
        },
        .Class => |*c| for (c.members) |*m| try composeBaseFactoryDecl(factories, m),
        .Object => |*o| for (o.members) |*m| try composeBaseFactoryDecl(factories, m),
        else => {},
    }
}

pub fn composeBaseSinkDecl(sinks: *std.StringHashMap(void), d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| for (f.params) |*p| {
            if (p.ty.function != null and compose_pass.isComposable(p.ty.annotations)) {
                try sinks.put(f.name.name, {});
                break;
            }
        },
        .Class => |*c| {
            // A class constructor taking a `@Composable` lambda is a sink under the class name.
            for (c.primary_params) |*p| {
                if (p.ty.function != null and compose_pass.isComposable(p.ty.annotations)) {
                    try sinks.put(c.name.name, {});
                    break;
                }
            }
            for (c.members) |*m| try composeBaseSinkDecl(sinks, m);
        },
        .Object => |*o| for (o.members) |*m| try composeBaseSinkDecl(sinks, m),
        else => {},
    }
}

pub fn noteBaseDeclNames(base: *StdlibBase, d: *const Decl, root_pkg: bool) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| try base.decl_names.put(f.name.name, {}),
        .Property => |p| try base.decl_names.put(p.name.name, {}),
        .Class => |*c| {
            try base.decl_names.put(c.name.name, {});
            try base.type_names.put(c.name.name, {});
        },
        .Object => |*o| {
            try base.decl_names.put(o.name.name, {});
            try base.type_names.put(o.name.name, {});
        },
        .TypeAlias => |*t| {
            try base.decl_names.put(t.name.name, {});
            try base.type_names.put(t.name.name, {});
        },
    }
    if (root_pkg) {
        switch (d.*) {
            .Function => |*f| try base.root_decl_names.put(f.name.name, {}),
            .Property => |p| try base.root_decl_names.put(p.name.name, {}),
            .Class => |*c| try base.root_decl_names.put(c.name.name, {}),
            .Object => |*o| try base.root_decl_names.put(o.name.name, {}),
            .TypeAlias => |*t| try base.root_decl_names.put(t.name.name, {}),
        }
    }
}

/// Conservative: any top-level simple-name overlap in either namespace, any expect or
/// actual decl, any package overlap, or a function-type alias matching a base param type.
pub fn canExtendBase(base: *const StdlibBase, user_files: []const KotlinFile) bool {
    for (user_files) |*f| {
        if (f.package) |p| {
            var buf: [256]u8 = undefined;
            var n: usize = 0;
            for (p.path, 0..) |id, i| {
                if (i != 0) {
                    if (n >= buf.len) return false;
                    buf[n] = '.';
                    n += 1;
                }
                if (n + id.name.len > buf.len) return false;
                @memcpy(buf[n .. n + id.name.len], id.name);
                n += id.name.len;
            }
            if (base.packages.contains(buf[0..n])) return extendRefused("package overlap", buf[0..n]);
        }
        // A root-package user callable collides only with a base callable reachable from the root
        // package. The TYPE namespace keeps the whole-set refusal, since casts, `is` checks and
        // reified probes resolve type names WITHOUT package scoping.
        const callable_names: *const StringSet = if (f.package == null) &base.root_decl_names else &base.decl_names;
        for (f.decls) |*d| {
            switch (d.*) {
                .Function => |*fd| {
                    if (fd.is_expect or fd.is_actual) return extendRefused("expect/actual fn", fd.name.name);
                    if (callable_names.contains(fd.name.name)) return extendRefused("fn name", fd.name.name);
                },
                .Property => |pd| {
                    if (pd.is_expect or pd.is_actual) return extendRefused("expect/actual prop", pd.name.name);
                    if (callable_names.contains(pd.name.name)) return extendRefused("prop name", pd.name.name);
                },
                .Class => |*cd| {
                    if (cd.is_expect or cd.is_actual) return extendRefused("expect/actual class", cd.name.name);
                    if (base.decl_names.contains(cd.name.name)) return extendRefused("class name", cd.name.name);
                },
                .Object => |*od| {
                    if (od.is_expect or od.is_actual) return extendRefused("expect/actual object", od.name.name);
                    if (base.decl_names.contains(od.name.name)) return extendRefused("object name", od.name.name);
                },
                .TypeAlias => |*td| {
                    if (base.decl_names.contains(td.name.name)) return extendRefused("alias name", td.name.name);
                    if (td.target.function != null and base.param_type_names.contains(td.name.name)) return extendRefused("fn alias vs base param type", td.name.name);
                },
            }
        }
    }
    return true;
}

/// Named refusal surfaced under `KLIO_TRACE_STDLIB_IMAGE`, so a silent fallback to a
/// full source re-lower names the colliding declaration.
pub fn extendRefused(reason: []const u8, name: []const u8) bool {
    if (runtime.envOnce("KLIO_TRACE_STDLIB_IMAGE")) |v| {
        if (v.len != 0 and !std.mem.eql(u8, v, "0")) {
            std.debug.print("[stdlib-image] extend refused: {s} `{s}`\n", .{ reason, name });
        }
    }
    return false;
}
