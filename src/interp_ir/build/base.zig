//! The once-per-process dependency base: building the immutable snapshot
//! of the stdlib (+ pack) files and the gate deciding whether a user
//! program may extend it instead of re-lowering the world.

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

// -------------------------------------------------------------------------
// Once-per-process dependency base: the stdlib (+ pack) files are lowered
// one time into an immutable snapshot; each program then extends an
// arena-backed clone with just its own declarations. The snapshot's
// BuiltModule is NEVER run — every runtime-mutable structure (the Vm's
// ClassDefs, enum-entry instances, companion/object cells) is deep-cloned
// per program, so nothing a run mutates is shared across programs.
// -------------------------------------------------------------------------

/// Immutable lowered snapshot of a program's dependency files. Owned by a
/// process-lifetime arena managed by the caller; safe to read from many
/// threads once built.
pub const StdlibBase = struct {
    /// The lowered dependency program. Cloned (never consumed) per run.
    built: BuiltModule,
    /// Post-lift, post-retain dependency decls: the context universe the
    /// extending build scans (file_classes, inline fns, top-level prop
    /// names) without re-lowering.
    lifted_decls: []const Decl,
    /// Every top-level simple name the base declares (functions,
    /// properties, classes, objects, typealiases — raw and post-lift).
    /// A user program redeclaring any of these falls back to the full
    /// whole-program build, because cross-boundary renames/mangles and
    /// resolution could differ from the snapshot's.
    decl_names: StringSet,
    /// The subset of `decl_names` declared in the ROOT package (files with
    /// no package header) plus every lifted/mangled decl. Only these can
    /// collide with a root-package user declaration under Kotlin scoping —
    /// a named-package base decl is invisible to bare references in other
    /// packages, so a user namesake cannot change any decision the base
    /// build settled and the extend gate lets it through.
    root_decl_names: StringSet,
    /// Packages the base files declare; a user file sharing one falls back
    /// (pack-private object aliasing scans sibling types per package).
    packages: StringSet,
    /// Every lowered base Func param type name. A user function-type
    /// typealias matching one would rewrite base param types in the
    /// whole-program build; the extend build falls back instead.
    param_type_names: StringSet,
    /// Top-level type simple names (post-lift), seeded into the extending
    /// build's nested-mangle collision universe.
    type_names: StringSet,
    /// (FuncId, AST) pairs replayed into the per-build inline-fn registry
    /// so user calls resolving to base inline fns still splice.
    inline_ids: []const InlineId,
    /// Simple-name -> base inline-fn forest refs (overloads in declaration
    /// order), the lazy replacement for walking `lifted_decls` with
    /// `collectInline` at load. Empty for a freshly-built base (which walks its
    /// own decls); populated only when loaded from an image. Includes class /
    /// object member inline fns, which carry no `inline_ids` stub.
    inline_by_name: []const InlineNames = &.{},
    /// Class simple-name -> base class forest ref, the lazy replacement for
    /// walking `lifted_decls` to seed `file_classes` at load. Empty for a
    /// freshly-built base. Used for hierarchy walks when a USER class reaches
    /// into a base class.
    file_classes: []const ClassRef = &.{},
    /// Base top-level (file-scope) property scope data — the lazy replacement for
    /// re-running `notePropScope` over `lifted_decls` at load. Empty for a
    /// freshly-built base. Strings only (no AST).
    top_props: []const TopProp = &.{},
    /// Baked top-level function return class heads (see `FnReturn`).
    fn_returns: []const FnReturn = &.{},
    /// Baked extension return class heads (see `ExtReturn`).
    ext_returns: []const ExtReturn = &.{},
    /// Baked eager call resolutions inside the base (see `EagerCall`).
    eager_calls: []const EagerCall = &.{},
    /// Base SourceMap files occupy ids [0..user_file_start).
    user_file_start: u32,
    /// Next enum-entry identity, continuing the base build's sequence so
    /// default toString/hashCode match the whole-program numbering.
    enum_id_next: u64,
    /// Side section holding the self-contained encodings of `inline`,
    /// object-free function bodies, decoded lazily on first splice. Empty for a
    /// freshly-built base (its `lifted_decls` keep full bodies); populated only
    /// when loaded from an image, where those bodies are markers. Borrows the
    /// image buffer.
    deferred_bodies: []const u8 = &.{},
    /// Per-decl self-contained encodings of `lifted_decls` and their byte
    /// offsets (decl `i` at `lifted_decl_offsets[i]`). Borrow the image buffer.
    /// Back the lazy forest: a decl decodes on first touch from here instead of
    /// the whole forest materialising at load. Empty for a freshly-built base.
    lifted_decl_section: []const u8 = &.{},
    lifted_decl_offsets: []const u32 = &.{},
    /// The process-lifetime allocator the base (and its `lifted_decls`) live in.
    /// A lazily-decoded deferred body must persist across per-program builds, so
    /// it is decoded here, not into a per-build arena.
    arena: Allocator = undefined,

    pub const InlineId = struct { id: u32, f: FF(ast.Function) };
    /// One simple name's base inline-fn forest refs (overloads in order).
    pub const InlineNames = struct { k: []const u8, v: []const runtime.forest.ForestRef };
    /// One class simple name -> its base-class forest ref.
    pub const ClassRef = struct { k: []const u8, v: runtime.forest.ForestRef };
    /// One base top-level property's scope identity.
    pub const TopProp = struct { name: []const u8, fqn: []const u8, package: []const u8, type_head: []const u8 = "" };
    /// A top-level function's simple name paired with the class head it
    /// returns. Baked because the funcs themselves are lazy in an image:
    /// nothing else can answer "what class does `listOf` return" without
    /// decoding the whole stdlib.
    pub const FnReturn = struct { name: []const u8, head: []const u8 };
    /// An EXTENSION's return class head, keyed `<receiver head>\x00<name>`.
    /// Declaration signatures keep parameters and no return type, so without
    /// this a chained call loses its receiver class at the first link.
    pub const ExtReturn = struct { key: []const u8, head: []const u8 };
    /// A call site inside the BASE and the declaration the checker picked
    /// for it. Collected while the base's sources exist (image bake) and
    /// replayed at load, because a cached run never parses them.
    pub const EagerCall = struct { call: span.Span, fid: u32 };
};

/// Build the dependency snapshot from already-parsed base files. The
/// allocator must be the process-lifetime base arena. Returns null when the
/// base program is not snapshot-safe (it has resolve diagnostics or a
/// `main`), in which case callers must use the full per-program build.
pub fn buildStdlibBase(allocator: Allocator, files: []const KotlinFile) Allocator.Error!?*StdlibBase {
    return buildBaseInner(allocator, files, false);
}

/// Whole-program variant of `buildStdlibBase` for `klio bundle`: the same
/// lowered snapshot, but `files` includes the user program so `main` is
/// present (and serialized). Boot then runs the loaded module directly —
/// no parse, no extend.
/// The declared type of the parent class's primary parameter at `idx`,
/// instantiated by the supertype's written type arguments
/// (`JsonTransformingSerializer<String>(serializer())` expects
/// `KSerializer<String>`). Null when the parent or its parameter is unknown.
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

    // Name universes for the reuse gate, over raw AND lifted decls (a
    // lifted/mangled name is a real top-level slot too).
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
    // Lifted decls: mangled names carry `$` (never a legal user identifier,
    // so never collidable), and plain-named lifts (member extensions and
    // company) originate from the named-package files noted above — their
    // bare-name visibility follows the same package scoping. They join the
    // general universe only; the root universe keeps the files-loop truth.
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

    // Continue the enum-entry identity sequence after the base's: identities
    // were assigned 1..N in build order over the base's unique class defs.
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

    // A non-inline base function never runs from its AST body (its lowered IR
    // does); strip those bodies so the baked image and the resident forest drop
    // the dead statement trees while keeping the metadata dispatch reads.
    prune.stripDeadBodies(@constCast(base.lifted_decls), true);

    return base;
}

/// Add the simple names of every `@Composable` function in the baked base
/// (pack composables the user calls) to the plugin oracle set.
/// The base's lifted decls for the compose-plugin collectors. A freshly-built
/// base carries the full forest in `lifted_decls`; an image-loaded base leaves
/// that empty (the forest decodes lazily per-decl) and holds the per-decl
/// `lifted_decl_section`/`lifted_decl_offsets` instead. The plugin collectors
/// below need the whole base surface, so decode every section decl here — an
/// image-loaded base otherwise reports zero base composables/sinks, and a
/// composable lambda passed to a base sink (`setContent { … }`, `key(…) { … }`)
/// never gets `$composer` threaded (`startRestartGroup on Nothing`). Returns
/// `base.lifted_decls` unchanged for a fresh base (no allocation).
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

/// Add the names of baked-base functions with a `@Composable`-typed lambda
/// parameter (composable-lambda sinks the user's composable calls pass into).
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
            // A class constructor taking a `@Composable` lambda is a sink
            // under the class name (`MovableContent({ … })`).
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

/// Whether `user_files` can extend `base` without changing any decision the
/// base build already settled. Conservative: any top-level simple-name
/// overlap (either namespace), any expect/actual decl, any package overlap,
/// or a function-type alias matching a base param type forces the full
/// whole-program build.
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
        // A root-package user FUNCTION or PROPERTY can only collide with a
        // base callable that is itself reachable from the root package
        // (root-package base files): named-package base callables are
        // invisible to bare references outside their package under Kotlin
        // scoping, and the callable dispatch tails are visibility-filtered,
        // so the user namesake cannot change any base decision. The TYPE
        // namespace (classes, objects, typealiases) stays on the whole-set
        // refusal: runtime casts / `is` checks / reified probes resolve
        // type names WITHOUT package scoping (a user `Node` broke the
        // kotlinx.coroutines-internal `as Node` cast), so a user type
        // namesake of ANY base type forces the full build. A user file
        // that DECLARES a package keeps the conservative whole-set refusal
        // for callables too.
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

/// Named refusal for the extend gate, surfaced under `KLIO_TRACE_STDLIB_IMAGE`
/// so a silent image fallback (a full source re-lower costing seconds) is
/// attributable to the exact colliding declaration.
pub fn extendRefused(reason: []const u8, name: []const u8) bool {
    if (runtime.envOnce("KLIO_TRACE_STDLIB_IMAGE")) |v| {
        if (v.len != 0 and !std.mem.eql(u8, v, "0")) {
            std.debug.print("[stdlib-image] extend refused: {s} `{s}`\n", .{ reason, name });
        }
    }
    return false;
}
