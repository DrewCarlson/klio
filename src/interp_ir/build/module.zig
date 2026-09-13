//! The file-set build drivers: the single-file and multi-file entry points, the
//! per-file package/FQN override scan, and the whole-file-set lowering pass.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const compose_pass = @import("compose_pass");
const serialization_pass = @import("serialization_pass");
const span = @import("span");

const Allocator = std.mem.Allocator;
const KotlinFile = ast.KotlinFile;
const Decl = ast.Decl;
const StringSet = std.StringHashMap(void);

const build_base = @import("base.zig");
const composeBaseComposableGetterProps = build_base.composeBaseComposableGetterProps;
const composeBaseDecls = build_base.composeBaseDecls;
const composeBaseInlineFns = build_base.composeBaseInlineFns;
const composeBaseNames = build_base.composeBaseNames;
const composeBaseSinks = build_base.composeBaseSinks;
const StdlibBase = build_base.StdlibBase;

const build_overrides = @import("overrides.zig");
const buildModuleWithOverrides = build_overrides.buildModuleWithOverrides;

const build_scan = @import("scan.zig");
const collectClassifierFqns = build_scan.collectClassifierFqns;
const collectDeclPkgs = build_scan.collectDeclPkgs;
const joinIdents = build_scan.joinIdents;
const packagePrefix = build_scan.packagePrefix;

const build_types = @import("types.zig");
const BuiltModule = build_types.BuiltModule;
const Span = build_types.Span;
const SpanStrMap = build_types.SpanStrMap;

pub fn buildModule(allocator: Allocator, file: *const KotlinFile) Allocator.Error!BuiltModule {
    var fqn = SpanStrMap.init(allocator);
    defer fqn.deinit();
    var func_fqn = SpanStrMap.init(allocator);
    defer func_fqn.deinit();
    var decl_pkg = SpanStrMap.init(allocator);
    defer decl_pkg.deinit();
    return buildModuleWithOverrides(
        allocator,
        file,
        &fqn,
        &func_fqn,
        &decl_pkg,
        null,
        null,
        null,
        null,
    );
}

/// Declarations from every file are concatenated into one synthesised file and
/// lowered as a single program.
pub fn buildModuleFiles(allocator: Allocator, files: []const KotlinFile) Allocator.Error!BuiltModule {
    return buildModuleFilesInner(allocator, files, null, null);
}

/// The base's lowered module and tables are cloned onto `allocator` and only the
/// user declarations are lifted on top. Callers must have verified `canExtendBase`.
pub fn buildModuleFilesExtend(allocator: Allocator, base: *const StdlibBase, user_files: []const KotlinFile) Allocator.Error!BuiltModule {
    return buildModuleFilesInner(allocator, user_files, base, null);
}

/// Files where a bare `@Composable` is the program's own annotation class: the package
/// declares `annotation class Composable` and the file imports no other `Composable`.
pub fn collectUserComposableFiles(allocator: Allocator, files: []const KotlinFile) Allocator.Error!std.AutoHashMap(ir.FileId, void) {
    var out = std.AutoHashMap(ir.FileId, void).init(allocator);
    errdefer out.deinit();
    var own_pkgs = std.StringHashMap(void).init(allocator);
    defer own_pkgs.deinit();
    for (files) |*f| {
        const pkg = try packagePrefix(allocator, f.package);
        if (std.mem.eql(u8, pkg, "androidx.compose.runtime")) continue;
        for (f.decls) |*d| {
            if (d.* != .Class or !d.Class.is_annotation) continue;
            if (!std.mem.eql(u8, d.Class.name.name, "Composable")) continue;
            try own_pkgs.put(pkg, {});
        }
    }
    if (own_pkgs.count() == 0) return out;
    for (files) |*f| {
        const pkg = try packagePrefix(allocator, f.package);
        if (!own_pkgs.contains(pkg)) continue;
        var imports_other = false;
        for (f.imports) |imp| {
            if (imp.wildcard or imp.path.len == 0) continue;
            const visible = if (imp.alias) |al| al.name else imp.path[imp.path.len - 1].name;
            if (std.mem.eql(u8, visible, "Composable")) imports_other = true;
        }
        if (!imports_other) try out.put(f.span.file, {});
    }
    return out;
}

pub fn buildModuleFilesInner(allocator: Allocator, files_in: []const KotlinFile, base: ?*const StdlibBase, out_lifted: ?*[]Decl) Allocator.Error!BuiltModule {
    ir.build.localClassScopeReset();
    const ComposeMaps = struct {
        names: std.StringHashMap(void),
        sinks: std.StringHashMap(void),
        comp_getter_props: std.StringHashMap(void),
        inline_fns: std.StringHashMap(void),
        stability: std.StringHashMap(compose_pass.Stability),

        fn deinit(self: *@This()) void {
            self.names.deinit();
            self.sinks.deinit();
            self.comp_getter_props.deinit();
            self.inline_fns.deinit();
            self.stability.deinit();
        }
    };
    var compose_maps: ?ComposeMaps = null;
    defer {
        compose_pass.active_composable_names = null;
        compose_pass.active_composable_sinks = null;
        compose_pass.active_composable_getter_props = null;
        compose_pass.active_inline_fns = null;
        compose_pass.active_stability = null;
        if (compose_maps) |*maps| maps.deinit();
    }
    var decls: std.ArrayList(Decl) = .empty;
    defer decls.deinit(allocator);
    var imports: std.ArrayList(ast.ImportDecl) = .empty;
    defer imports.deinit(allocator);

    var fqn_overrides = SpanStrMap.init(allocator);
    defer fqn_overrides.deinit();
    var func_fqn_overrides = SpanStrMap.init(allocator);
    defer func_fqn_overrides.deinit();
    var decl_pkg = SpanStrMap.init(allocator);
    defer decl_pkg.deinit();

    var file_pkgs = std.AutoHashMap(ir.FileId, []const u8).init(allocator);
    defer file_pkgs.deinit();
    var file_modules = std.AutoHashMap(ir.FileId, u32).init(allocator);
    defer file_modules.deinit();
    const compilation_module: u32 = if (base) |bs| blk: {
        const module_guard = bs.built.module.borrow();
        defer module_guard.deinit();
        var next: u32 = 0;
        var module_it = module_guard.get().registry.file_modules.valueIterator();
        while (module_it.next()) |module_id| {
            next = @max(next, module_id.* +| 1);
        }
        break :blk next;
    } else 0;
    // `@Serializable` lowering: each serializable class's generated serializer
    // declarations are synthesized as ordinary Kotlin before anything reads the decls.
    const files: []KotlinFile = try serialization_pass.transformFiles(allocator, files_in);
    // Typealias expansion: every alias reference becomes its target before any phase
    // reads the declarations (`KLIO_ALIAS_EXPAND=0` skips it).
    const alias_expand_off = if (runtime.envOnce("KLIO_ALIAS_EXPAND")) |v| std.mem.eql(u8, v, "0") else false;
    if (!alias_expand_off) try ast.alias_expand.expandFiles(allocator, files);
    var user_composable_files = try collectUserComposableFiles(allocator, files);
    defer user_composable_files.deinit();
    compose_pass.user_composable_files = &user_composable_files;
    defer compose_pass.user_composable_files = null;
    for (files) |*f| {
        try file_modules.put(f.span.file, compilation_module);
        const prefix = try packagePrefix(allocator, f.package);
        if (prefix.len != 0) {
            try file_pkgs.put(f.span.file, prefix);
        }
        for (f.decls) |*d| {
            try collectClassifierFqns(allocator, d, prefix, &fqn_overrides);
            try collectDeclPkgs(allocator, d, prefix, &decl_pkg);
            if (d.* == .Function and prefix.len != 0) {
                try func_fqn_overrides.put(d.Function.span, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, d.Function.name.name }));
            }
            if (d.* == .Property and prefix.len != 0) {
                try func_fqn_overrides.put(d.Property.span, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, d.Property.name.name }));
            }
        }
        try decls.appendSlice(allocator, f.decls);
        try imports.appendSlice(allocator, f.imports);
    }

    // `@Composable` lowering: composable functions are rewritten to thread the composer per
    // the Compose plugin ABI. The oracle spans this module's decls plus the baked base.
    {
        var names = try compose_pass.collectComposableNames(allocator, decls.items);
        defer names.deinit();
        var sinks = try compose_pass.collectComposableLambdaSinks(allocator, decls.items);
        defer sinks.deinit();
        var comp_getter_props = try compose_pass.collectComposableGetterProps(allocator, decls.items);
        defer comp_getter_props.deinit();
        var inline_fns = try compose_pass.collectInlineFnNames(allocator, decls.items);
        defer inline_fns.deinit();
        if (base) |bsp| {
            // An image-loaded base leaves `lifted_decls` empty, so collectors read the decoded section.
            const base_decls = try composeBaseDecls(allocator, bsp);
            try composeBaseNames(&names, base_decls);
            try composeBaseSinks(&sinks, base_decls);
            try composeBaseComposableGetterProps(&comp_getter_props, base_decls);
            try composeBaseInlineFns(&inline_fns, base_decls);
        }
        if (runtime.envOnce("KLIO_COMPOSE_DBG") != null) {
            compose_pass.dbg_groups = true;
            std.debug.print("[compose-pass] enabled, {d} composable names, {d} lambda sinks, {d} decls\n", .{ names.count(), sinks.count(), decls.items.len });
            if (std.mem.eql(u8, runtime.envOnce("KLIO_COMPOSE_DBG").?, "sinks")) {
                var sit = sinks.keyIterator();
                while (sit.next()) |k| std.debug.print("[compose-sink] {s}\n", .{k.*});
            }
        }
        compose_pass.active_composable_getter_props = &comp_getter_props;
        defer compose_pass.active_composable_getter_props = null;
        compose_pass.active_inline_fns = &inline_fns;
        defer compose_pass.active_inline_fns = null;
        var stability = try compose_pass.collectClassStability(
            allocator,
            decls.items,
            if (base) |bsp| bsp.lifted_decls else &.{},
        );
        defer stability.deinit();
        compose_pass.active_stability = &stability;
        defer compose_pass.active_stability = null;
        var comp_params = try compose_pass.collectComposableParamNames(allocator, decls.items);
        defer comp_params.deinit();
        compose_pass.active_composable_params = &comp_params;
        defer compose_pass.active_composable_params = null;
        compose_pass.memo_trace_enabled = runtime.envOnce("KLIO_MEMO_TRACE") != null;
        var memo_lifts: std.ArrayList(ast.Decl) = .empty;
        defer memo_lifts.deinit(allocator);
        compose_pass.pending_memo_lifts = &memo_lifts;
        compose_pass.pending_lift_alloc = allocator;
        defer {
            compose_pass.pending_memo_lifts = null;
            compose_pass.pending_lift_alloc = null;
        }
        try compose_pass.transformDecls(allocator, decls.items, &names, &sinks);
        try decls.appendSlice(allocator, memo_lifts.items);
        compose_maps = .{
            .names = names,
            .sinks = sinks,
            .comp_getter_props = comp_getter_props,
            .inline_fns = inline_fns,
            .stability = stability,
        };
        names = std.StringHashMap(void).init(allocator);
        sinks = std.StringHashMap(void).init(allocator);
        comp_getter_props = std.StringHashMap(void).init(allocator);
        inline_fns = std.StringHashMap(void).init(allocator);
        stability = std.StringHashMap(compose_pass.Stability).init(allocator);
    }
    if (compose_maps) |*maps| {
        compose_pass.active_composable_names = &maps.names;
        compose_pass.active_composable_sinks = &maps.sinks;
        compose_pass.active_composable_getter_props = &maps.comp_getter_props;
        compose_pass.active_inline_fns = &maps.inline_fns;
        compose_pass.active_stability = &maps.stability;
    }

    // Kotlin gives same-named top-level properties distinct storage per declaration (a
    // `private` one is file-scoped, non-private ones in different packages are distinct)
    // but the lowered globals table is flat, so colliding declarations are renamed and a
    // per-file rename table drives bare reads. Scope order: own-file private, own package,
    // named import, wildcard import.
    var private_prop_renames = ir.build.FilePrivateRenames.init(allocator);
    defer {
        var it = private_prop_renames.valueIterator();
        while (it.next()) |inner| inner.deinit();
        private_prop_renames.deinit();
    }
    var private_func_renames = ir.build.FilePrivateRenames.init(allocator);
    defer {
        var it = private_func_renames.valueIterator();
        while (it.next()) |inner| inner.deinit();
        private_func_renames.deinit();
    }
    {
        var name_files = std.StringHashMap(u32).init(allocator);
        defer name_files.deinit();
        var name_counts = std.StringHashMap(u32).init(allocator);
        defer name_counts.deinit();
        for (decls.items) |*d| {
            if (d.* != .Property) continue;
            const p = d.Property;
            if (p.receiver_type != null) continue;
            const fid = p.span.file.int();
            const gop = try name_counts.getOrPut(p.name.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = 1;
                try name_files.put(p.name.name, fid);
            } else if (name_files.get(p.name.name).? != fid) {
                gop.value_ptr.* += 1;
            }
        }
        // Private decls: per-file mangled slots, and declaring-file bare reads rewrite to them.
        for (decls.items) |*d| {
            if (d.* != .Property) continue;
            const p = d.Property;
            if (p.receiver_type != null) continue;
            if (p.visibility != .Private or p.is_expect or p.is_actual) continue;
            const count = name_counts.get(p.name.name) orelse 0;
            if (count < 2) continue;
            const fid = p.span.file.int();
            const mangled = try std.fmt.allocPrint(allocator, "{s}$f{d}", .{ p.name.name, fid });
            const gop = try private_prop_renames.getOrPut(fid);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
            try gop.value_ptr.put(p.name.name, mangled);
            p.name = .{ .name = mangled, .span = p.name.span };
        }
        // File-private top-level FUNCTIONS: file-scoped in Kotlin but flat here, so two files
        // declaring `private fun debugLog(...)` read as conflicting overloads without a mangle.
        {
            var fn_files = std.StringHashMap(u32).init(allocator);
            defer fn_files.deinit();
            var fn_counts = std.StringHashMap(u32).init(allocator);
            defer fn_counts.deinit();
            for (decls.items) |*d| {
                if (d.* != .Function) continue;
                const fdec = d.Function;
                if (fdec.receiver_type != null) continue;
                const fid = fdec.span.file.int();
                const gop = try fn_counts.getOrPut(fdec.name.name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = 1;
                    try fn_files.put(fdec.name.name, fid);
                } else if (fn_files.get(fdec.name.name).? != fid) {
                    gop.value_ptr.* += 1;
                }
            }
            for (decls.items) |*d| {
                if (d.* != .Function) continue;
                const fdec = &d.Function;
                if (fdec.receiver_type != null) continue;
                if (fdec.visibility != .Private or fdec.is_expect or fdec.is_actual) continue;
                const count = fn_counts.get(fdec.name.name) orelse 0;
                if (count < 2) continue;
                const fid = fdec.span.file.int();
                const mangled = try std.fmt.allocPrint(allocator, "{s}$f{d}", .{ fdec.name.name, fid });
                const gop = try private_func_renames.getOrPut(fid);
                if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
                try gop.value_ptr.put(fdec.name.name, mangled);
                fdec.name = .{ .name = mangled, .span = fdec.name.span };
            }
        }
        // A simple name declared non-privately by two or more packages: each gets its FQN slot.
        const FqnCand = struct { pkg: []const u8, fqn: []const u8 };
        var fqn_renamed = std.StringHashMap(std.ArrayList(FqnCand)).init(allocator);
        defer {
            var it = fqn_renamed.valueIterator();
            while (it.next()) |list| list.deinit(allocator);
            fqn_renamed.deinit();
        }
        for (decls.items) |*d| {
            if (d.* != .Property) continue;
            const p = d.Property;
            if (p.receiver_type != null) continue;
            if (p.visibility == .Private or p.is_expect or p.is_actual) continue;
            const count = name_counts.get(p.name.name) orelse 0;
            if (count < 2) continue;
            const pkg = decl_pkg.get(p.span) orelse "";
            if (pkg.len == 0) continue;
            // Rename only when another package also declares the name non-privately: a same-package
            // duplicate is a redeclaration error, a private-only collision is file-scoped above.
            var other_pkg = false;
            for (decls.items) |*d2| {
                if (d2.* != .Property) continue;
                const q = d2.Property;
                if (q.receiver_type != null or q.is_expect or q.is_actual) continue;
                if (q.visibility == .Private) continue;
                if (!std.mem.eql(u8, q.name.name, p.name.name)) continue;
                const qpkg = decl_pkg.get(q.span) orelse "";
                if (!std.mem.eql(u8, qpkg, pkg)) other_pkg = true;
            }
            if (!other_pkg) continue;
            const simple = p.name.name;
            const fqn = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ pkg, simple });
            const fid = p.span.file.int();
            const gop = try private_prop_renames.getOrPut(fid);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
            // A file-private decl of the same name wins for its own file's references.
            if (gop.value_ptr.get(simple) == null) try gop.value_ptr.put(simple, fqn);
            const lgop = try fqn_renamed.getOrPut(simple);
            if (!lgop.found_existing) lgop.value_ptr.* = .empty;
            try lgop.value_ptr.append(allocator, .{ .pkg = pkg, .fqn = fqn });
            p.name = .{ .name = fqn, .span = p.name.span };
        }
        // Bare references from other files resolve own package, then a named import of a
        // declaring FQN, then a wildcard import; otherwise the name-keyed read stands.
        if (fqn_renamed.count() != 0) {
            for (files) |*f| {
                const fid = f.span.file.int();
                const fpkg = try packagePrefix(allocator, f.package);
                var it = fqn_renamed.iterator();
                while (it.next()) |e| {
                    const simple = e.key_ptr.*;
                    {
                        const fgop = try private_prop_renames.getOrPut(fid);
                        if (!fgop.found_existing) fgop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
                        if (fgop.value_ptr.get(simple) != null) continue;
                    }
                    var pick: ?[]const u8 = null;
                    for (e.value_ptr.items) |cand| {
                        if (std.mem.eql(u8, cand.pkg, fpkg)) pick = cand.fqn;
                    }
                    if (pick == null) {
                        for (f.imports) |*imp| {
                            if (imp.wildcard or imp.path.len == 0) continue;
                            if (imp.alias != null) continue;
                            if (!std.mem.eql(u8, imp.path[imp.path.len - 1].name, simple)) continue;
                            const imp_fqn = try joinIdents(allocator, imp.path, ".");
                            for (e.value_ptr.items) |cand| {
                                if (std.mem.eql(u8, cand.fqn, imp_fqn)) pick = cand.fqn;
                            }
                        }
                    }
                    if (pick == null) {
                        for (f.imports) |*imp| {
                            if (!imp.wildcard) continue;
                            const imp_pkg = try joinIdents(allocator, imp.path, ".");
                            for (e.value_ptr.items) |cand| {
                                if (std.mem.eql(u8, cand.pkg, imp_pkg) and pick == null) pick = cand.fqn;
                            }
                        }
                    }
                    if (pick) |fqn| {
                        const fgop = try private_prop_renames.getOrPut(fid);
                        if (!fgop.found_existing) fgop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
                        try fgop.value_ptr.put(simple, fqn);
                    }
                }
            }
        }
    }
    const prev_renames = ir.build.setLowerFilePrivateRenames(&private_prop_renames);
    defer _ = ir.build.setLowerFilePrivateRenames(prev_renames);
    const prev_fn_renames = ir.build.setLowerFilePrivateFuncRenames(&private_func_renames);
    defer _ = ir.build.setLowerFilePrivateFuncRenames(prev_fn_renames);

    // Kotlin scopes a file-`private` top-level class or typealias to its declaring file, but
    // the lowered type namespace is flat, so one whose simple name another file also claims
    // as a type is mangled and its reference sites rewritten through their span file.
    var file_type_renames = ir.build.FileTypeRenames.init(allocator);
    defer {
        var it = file_type_renames.valueIterator();
        while (it.next()) |inner| inner.deinit();
        file_type_renames.deinit();
    }
    var pkg_type_renames = ir.build.PkgTypeRenames.init(allocator);
    defer {
        var it = pkg_type_renames.valueIterator();
        while (it.next()) |inner| inner.deinit();
        pkg_type_renames.deinit();
    }
    {
        var name_files = std.StringHashMap(u32).init(allocator);
        defer name_files.deinit();
        var name_counts = std.StringHashMap(u32).init(allocator);
        defer name_counts.deinit();
        // A name any expect/actual declaration claims is shared by design and never mangles.
        var ea_names = StringSet.init(allocator);
        defer ea_names.deinit();
        for (decls.items) |*d| {
            const claim: ?struct { name: []const u8, fid: u32, ea: bool } = switch (d.*) {
                .Class => |*c| .{ .name = c.name.name, .fid = c.span.file.int(), .ea = c.is_expect or c.is_actual },
                .Object => |*o| .{ .name = o.name.name, .fid = o.span.file.int(), .ea = o.is_expect or o.is_actual },
                .TypeAlias => |*t| .{ .name = t.name.name, .fid = t.span.file.int(), .ea = false },
                else => null,
            };
            const cl = claim orelse continue;
            if (cl.ea) try ea_names.put(cl.name, {});
            const gop = try name_counts.getOrPut(cl.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = 1;
                try name_files.put(cl.name, cl.fid);
            } else if (name_files.get(cl.name).? != cl.fid) {
                gop.value_ptr.* += 1;
            }
        }
        for (decls.items) |*d| {
            const target: ?struct { name: *ast.Ident, vis: ast.Visibility, is_ea: bool, fid: u32 } = switch (d.*) {
                .Class => |*c| .{ .name = &c.name, .vis = c.visibility, .is_ea = c.is_expect or c.is_actual, .fid = c.span.file.int() },
                .TypeAlias => |*t| .{ .name = &t.name, .vis = t.visibility, .is_ea = false, .fid = t.span.file.int() },
                else => null,
            };
            const tg = target orelse continue;
            if ((tg.vis != .Private and tg.vis != .Internal) or tg.is_ea) continue;
            if (ea_names.contains(tg.name.name)) continue;
            if ((name_counts.get(tg.name.name) orelse 0) < 2) continue;
            // A file-`private` classifier is file-scoped, so the per-file map serves every legal
            // reference. An `internal` one cannot be named from another pack, leaving the declaring
            // file, same-package files, and imports, which resolve by FQN through the fqn override.
            const mangled = try std.fmt.allocPrint(allocator, "{s}$f{d}", .{ tg.name.name, tg.fid });
            const gop = try file_type_renames.getOrPut(tg.fid);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
            try gop.value_ptr.put(tg.name.name, mangled);
            if (tg.vis == .Internal) {
                if (file_pkgs.get(span.FileId.from(tg.fid))) |pkg| {
                    const pgop = try pkg_type_renames.getOrPut(pkg);
                    if (!pgop.found_existing) pgop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
                    try pgop.value_ptr.put(tg.name.name, mangled);
                }
            }
            tg.name.* = .{ .name = mangled, .span = tg.name.span };
        }
    }
    const prev_ty_renames = ir.build.setLowerFileTypeRenames(&file_type_renames);
    defer _ = ir.build.setLowerFileTypeRenames(prev_ty_renames);
    const prev_pkg_renames = ir.build.setLowerPkgTypeRenames(&pkg_type_renames);
    defer _ = ir.build.setLowerPkgTypeRenames(prev_pkg_renames);
    const prev_file_pkgs = ir.build.setLowerFilePkgs(&file_pkgs);
    defer _ = ir.build.setLowerFilePkgs(prev_file_pkgs);

    const combined = KotlinFile{
        .package = null,
        .imports = try imports.toOwnedSlice(allocator),
        .decls = try decls.toOwnedSlice(allocator),
        .span = Span.init(span.FileId.from(0), 0, 0),
    };
    const built = try buildModuleWithOverrides(
        allocator,
        &combined,
        &fqn_overrides,
        &func_fqn_overrides,
        &decl_pkg,
        &file_pkgs,
        &file_modules,
        base,
        out_lifted,
    );
    if (compose_pass.composeAuditOn()) {
        const ca = &compose_pass.compose_audit;
        std.debug.print(
            "[KLIO_RESOLVE_AUDIT] compose summary (cumulative): agree={d} pair-stripped={d} pair-completed={d} lambda-arity={d} disagreements={d}\n",
            .{ ca.threaded_agree, ca.pair_stripped, ca.pair_completed, ca.lambda_arity_mismatch, ca.disagreements() },
        );
    }
    return built;
}
