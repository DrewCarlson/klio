//! Path expression lowering: scope renames, lowered type names, interpolation.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");
const literals = @import("../literals.zig");
const inline_state = @import("../inline_state.zig");
const decl_mod = @import("../decl.zig");
const ast_scan = @import("../ast_scan.zig");
const inline_call = @import("../inline_call.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const ConstId = ir.ConstId;
const Reg = ir.Reg;
const TypeRef = ir.TypeRef;
const StringSet = std.StringHashMap(void);
const collectPathIdents = ast_scan.collectPathIdents;
const isPackageHead = literals.isPackageHead;
const isTopLevelProp = inline_state.isTopLevelProp;
const isLowerAnonCapture = decl_mod.isLowerAnonCapture;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const emit_mod = @import("emit.zig");
const classIdAtLexicalSite = emit_mod.classIdAtLexicalSite;
const emitFqnWithClassPrefix = emit_mod.emitFqnWithClassPrefix;
const narrowedThisDeclares = emit_mod.narrowedThisDeclares;
const scopedClassIdForRead = emit_mod.scopedClassIdForRead;
const subjectCorrectedBareThis = emit_mod.subjectCorrectedBareThis;

const type_probe_mod = @import("type_probe.zig");
const lateinitLocalRead = type_probe_mod.lateinitLocalRead;
const lowerDelegateRead = type_probe_mod.lowerDelegateRead;

const probe_mod = @import("probe.zig");
const anyReceiverClassDeclares = probe_mod.anyReceiverClassDeclares;
const inReceiverContext = probe_mod.inReceiverContext;
const ownCompanionNamed = probe_mod.ownCompanionNamed;
const recordOutOfScopeRef = probe_mod.recordOutOfScopeRef;
const spliceSubjectHidesOwnMember = probe_mod.spliceSubjectHidesOwnMember;
const typeHead = probe_mod.typeHead;

const audit_mod = @import("audit.zig");
const orEmitAudit = audit_mod.orEmitAudit;
const refAudit = audit_mod.refAudit;

const block_mod = @import("block.zig");
const headIsPackage = block_mod.headIsPackage;
const joinSegments = block_mod.joinSegments;

/// Whether `name` is a known class with a registered companion object; in value
/// position such a name is its companion singleton.
pub fn classWithCompanion(b: *const FuncBuilder, name: []const u8) bool {
    return b.module.classId(name) != null and
        b.module.registry.companion_singletons.contains(name);
}

/// A bare `name` an enclosing class declares as a value member shadows an
/// unrelated global classifier, unless it is a nested type on the owner chain.
pub fn enclosingMemberShadowsClass(b: *const FuncBuilder, name: []const u8) bool {
    if (!b.hasEnclosingMember(name)) return false;
    var owner = b.ownerClass();
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        if (b.module.registry.nested_object_aliases.get(o)) |m| {
            if (m.contains(name)) return false;
        }
        owner = b.module.registry.enclosing_class.get(o);
    }
    return true;
}

/// Whether the own member overload at this arity declares a non-function
/// parameter where the call passes a lambda, so it cannot outrank an extension.

/// Whether the enclosing class declares a member named `name` a call with
/// `nargs` arguments can bind. The own-member arity mask decides where it has an
/// entry, else the owner's registered signatures; unknown stays applicable.
pub fn enclosingMemberTakes(b: *const FuncBuilder, name: []const u8, nargs: usize) bool {
    const tr = if (runtime.envOnce("KLIO_INLINE_PICK")) |w| std.mem.eql(u8, w, name) else false;
    if (b.own_member_arity.get(name) != null) {
        if (tr) std.debug.print("[emt] {s} mask -> {}\n", .{ name, b.ownMemberApplicable(name, nargs) });
        return b.ownMemberApplicable(name, nargs);
    }
    const owner = b.ownerClass() orelse build.currentOwnerClass() orelse {
        if (tr) std.debug.print("[emt] {s} no owner -> true\n", .{name});
        return true;
    };
    var found_any = false;
    for (b.module.funcsBySimpleName(name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.fqn.len <= name.len + 1) continue;
        const prefix = f.fqn[0 .. f.fqn.len - name.len - 1];
        if (!std.mem.endsWith(u8, prefix, owner)) continue;
        found_any = true;
        var required: usize = 0;
        var total: usize = 0;
        for (f.params, 0..) |*p, i| {
            if (i == 0 and std.mem.eql(u8, p.name, "this")) continue;
            if (p.is_vararg) return true;
            total += 1;
            if (!p.has_default) required += 1;
        }
        if (nargs >= required and nargs <= total) {
            if (tr) std.debug.print("[emt] {s} owner={s} sig {s} takes {d}\n", .{ name, owner, f.fqn, nargs });
            return true;
        }
    }
    if (tr) std.debug.print("[emt] {s} owner={s} found_any={} -> {}\n", .{ name, owner, found_any, !found_any });
    return !found_any;
}

pub fn ownMemberRejectsLambdas(b: *const FuncBuilder, name: []const u8, args: []const Expr) bool {
    const owner = b.ownerClass() orelse return false;
    // The registration key is the source class name; a file-private class lowers
    // under a `$f<n>` mangle and a nested one under `Outer$Inner`.
    const mf = inline_state.exprBodyMemberAst(owner, name, args.len) orelse blk: {
        if (std.mem.find(u8, owner, "$f")) |i| {
            if (inline_state.exprBodyMemberAst(owner[0..i], name, args.len)) |m| break :blk m;
        }
        return false;
    };
    for (args, 0..) |*a, i| {
        const is_lambda = switch (a.*) {
            .Lambda, .AnonFun => true,
            else => false,
        };
        if (!is_lambda) continue;
        if (i >= mf.params.len) return false;
        if (mf.params[i].ty.function == null and !std.mem.eql(u8, mf.params[i].ty.name.name, "Any")) return true;
    }
    return false;
}

pub fn scopeTypeRename(b: *const FuncBuilder, name: []const u8, file: u32) ?[]const u8 {
    return scopeTypeRenameFrom(b, b.ownerClass(), name, file);
}

/// `scopeTypeRename` starting the walk at an explicit owner: an inline splice
/// binds its reified names after pushing the callee's frame, which drops the
/// caller's owner.
pub fn scopeTypeRenameFrom(b: *const FuncBuilder, owner_start: ?[]const u8, name: []const u8, file: u32) ?[]const u8 {
    var owner = owner_start;
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        if (b.module.registry.nested_object_aliases.get(o)) |m| {
            if (m.get(name)) |renamed| return renamed;
        }
        // A class's own companion named `name` outranks a supertype's same-named
        // nested classifier.
        if (ownCompanionNamed(b, o, name)) return null;
        // A supertype's nested classifiers are in scope in the subclass body.
        if (supertypeNestedAlias(b, o, name, 0)) |renamed| return renamed;
        owner = b.module.registry.enclosing_class.get(o);
    }
    // An anon-object body lowering at runtime carries its lexical site's renames;
    // the side module's registries are empty.
    if (build.anonScopeRename(name)) |renamed| return renamed;
    if (build.fileTypeRename(name, file)) |renamed| return renamed;
    // Same-package cross-file reference to a package-renamed internal classifier.
    if (b.module.packageOfFile(ir.FileId.from(file))) |pkg| {
        if (build.pkgTypeRename(name, pkg)) |renamed| return renamed;
    }
    // Cross-package reference through an import of the declaring package.
    if (decl_mod.importedPkgTypeRename(b.module, name, ir.FileId.from(file))) |renamed| return renamed;
    return null;
}

/// The lifted name a supertype of `cls_name` registers for nested `name`.
fn supertypeNestedAlias(b: *const FuncBuilder, cls_name: []const u8, name: []const u8, depth: usize) ?[]const u8 {
    if (depth > 16) return null;
    const cid = b.module.classId(cls_name) orelse return null;
    if (cid.int() >= b.module.classes.items.len) return null;
    const cls = &b.module.classes.items[cid.int()];
    for (cls.supertypes) |sid| {
        if (sid.int() >= b.module.classes.items.len) continue;
        const sup = &b.module.classes.items[sid.int()];
        if (b.module.registry.nested_object_aliases.get(sup.name)) |m| {
            if (m.get(name)) |renamed| return renamed;
        }
        if (supertypeNestedAlias(b, sup.name, name, depth + 1)) |renamed| return renamed;
    }
    return null;
}

/// Flatten every scope-true type rename visible at this lexical site into one
/// slice for a `BuildObject`. First entry per name wins, so nearer scopes shadow.
pub fn collectScopeRenames(b: *FuncBuilder, file: u32) Allocator.Error![]const ir.ScopeRename {
    var out: std.ArrayList(ir.ScopeRename) = .empty;
    var owner = b.ownerClass();
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        if (b.module.registry.nested_object_aliases.get(o)) |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                try out.append(b.allocator, .{ .name = e.key_ptr.*, .renamed = e.value_ptr.* });
            }
        }
        owner = b.module.registry.enclosing_class.get(o);
    }
    for (build.anonScopeRenames()) |r| try out.append(b.allocator, r);
    if (build.fileTypeRenamesFor(file)) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            try out.append(b.allocator, .{ .name = e.key_ptr.*, .renamed = e.value_ptr.* });
        }
    }
    if (b.module.packageOfFile(ir.FileId.from(file))) |pkg| {
        if (build.pkgTypeRenamesFor(pkg)) |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                try out.append(b.allocator, .{ .name = e.key_ptr.*, .renamed = e.value_ptr.* });
            }
        }
    }
    return out.toOwnedSlice(b.allocator);
}

/// Resolve every bare classifier an anonymous-object subtree references at its
/// lexical site; its bodies lower later in a side module, so the identities must
/// travel with the object instruction.
pub fn collectScopeClasses(b: *FuncBuilder, expr: *const Expr) Allocator.Error![]const ir.ScopeClassRef {
    var names = StringSet.init(b.allocator);
    defer names.deinit();
    try collectPathIdents(expr, &names);

    var out: std.ArrayList(ir.ScopeClassRef) = .empty;
    var it = names.keyIterator();
    while (it.next()) |name_ptr| {
        const name = name_ptr.*;
        const cid = classIdAtLexicalSite(b, name, expr.span().file) orelse continue;
        if (cid.int() >= b.module.classes.items.len) continue;
        const cls = b.module.classes.items[cid.int()];
        const has_companion = b.module.registry.companion_singletons.contains(name) or
            b.module.registry.companion_singletons.contains(cls.name) or
            b.module.registry.companion_singletons.contains(cls.fqn);
        try out.append(b.allocator, .{
            .name = name,
            .fqn = cls.fqn,
            .has_companion = has_companion,
        });
    }
    return out.toOwnedSlice(b.allocator);
}

/// Reduce a dotted path to its last two segments; null below two.
fn lastTwoSegments(path: []const u8) ?[]const u8 {
    var last: ?usize = null;
    var prev: ?usize = null;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '.') {
            prev = last;
            last = i;
        }
    }
    if (last == null) return null;
    const start = if (prev) |p| p + 1 else 0;
    return path[start..];
}

/// The lowered name for a type position: a qualified nested reference resolves to
/// its mangled lift name, then the `scopeTypeRename` ladder, then the simple name.
pub fn loweredTypeName(b: *const FuncBuilder, ty: *const ast.TypeRef) []const u8 {
    if (ty.qualified_path) |qp| {
        if (lastTwoSegments(qp)) |key| {
            if (b.module.registry.mangled_nested.get(key)) |m| return m;
        }
    }
    if (scopeTypeRename(b, ty.name.name, ty.span.file.int())) |renamed| return renamed;
    // A function-local class is keyed by its `$lc<fn>` alias, which an explicit
    // type argument naming it must bind.
    var lc_buf: [160]u8 = undefined;
    if (std.fmt.bufPrint(&lc_buf, "{s}$lc{s}", .{ ty.name.name, build.currentRealFn() orelse "" }) catch null) |key| {
        if (b.module.registry.class_super_names.get(key) != null) {
            return b.allocator.dupe(u8, key) catch ty.name.name;
        }
    }
    return ty.name.name;
}

/// Lower a source type into an owned structural type for builder metadata, the
/// head following the same scope-aware rename as expression positions.
pub fn loweredOwnedLocalTypeRef(b: *const FuncBuilder, ty: *const ast.TypeRef) Allocator.Error!TypeRef {
    var lowered = try decl_mod.loweredTypeRef(b.allocator, ty, true);
    errdefer lowered.deinit(b.allocator);
    const resolved_head = loweredTypeName(b, ty);
    if (!std.mem.eql(u8, lowered.name, resolved_head)) {
        const owned_head = try b.allocator.dupe(u8, resolved_head);
        b.allocator.free(lowered.name);
        lowered.name = owned_head;
    }
    if (ty.qualified_path == null) {
        var alias_fqn: ?[]const u8 = null;
        const imports = b.module.importAliasPathsIn(ty.span.file, ty.name.name);
        for (imports) |imported| {
            if (!b.module.registry.type_alias_types.contains(imported.fqn)) continue;
            if (alias_fqn != null and !std.mem.eql(u8, alias_fqn.?, imported.fqn)) {
                alias_fqn = null;
                break;
            }
            alias_fqn = imported.fqn;
        }
        const package = b.module.packageOfFile(ty.span.file) orelse b.self_package;
        const own_fqn = if (package.len == 0)
            try b.allocator.dupe(u8, ty.name.name)
        else
            try std.fmt.allocPrint(b.allocator, "{s}.{s}", .{ package, ty.name.name });
        defer b.allocator.free(own_fqn);
        if (alias_fqn == null and b.module.registry.type_alias_types.contains(own_fqn)) {
            alias_fqn = own_fqn;
        }
        if (alias_fqn) |fqn| {
            const marker = try std.fmt.allocPrint(b.allocator, "#qual:{s}", .{fqn});
            errdefer b.allocator.free(marker);
            const args = try b.allocator.alloc(ir.TypeRef, lowered.args.len + 1);
            errdefer b.allocator.free(args);
            @memcpy(args[0..lowered.args.len], lowered.args);
            args[args.len - 1] = .{
                .name = marker,
                .nullable = false,
                .args = &.{},
            };
            b.allocator.free(lowered.args);
            lowered.args = args;
        }
    }
    return lowered;
}

/// Type name for an `is` or `as` check. A package-qualified reference keeps its
/// dotted path, normalised to the class FQN, so the runtime walk can reject a
/// same-simple-name class from another package.
pub fn loweredCheckTypeName(b: *const FuncBuilder, ty: *const ast.TypeRef) []const u8 {
    if (ty.qualified_path) |qp| {
        if (lastTwoSegments(qp)) |key| {
            if (b.module.registry.mangled_nested.get(key)) |m| return m;
        }
        // The first segment may itself be a nested class lifted under a mangled
        // name, so resolve it through the owner's scope alias.
        if (std.mem.findScalar(u8, qp, '.')) |d| {
            if (scopeTypeRename(b, qp[0..d], ty.span.file.int())) |owner| {
                if (std.fmt.allocPrint(b.allocator, "{s}.{s}", .{ owner, qp[d + 1 ..] })) |aliased| {
                    if (lastTwoSegments(aliased)) |key| {
                        if (b.module.registry.mangled_nested.get(key)) |m| return m;
                    }
                    if (b.module.classIdByFqn(aliased)) |cid| {
                        if (cid.int() < b.module.classes.items.len) return b.module.classes.items[cid.int()].fqn;
                    }
                } else |_| {}
            }
        }
        // Normalise to the canonical FQN when the path resolves; otherwise carry
        // it through for the runtime to resolve once every class is registered.
        if (b.module.classIdByFqn(qp)) |cid| {
            if (cid.int() < b.module.classes.items.len) return b.module.classes.items[cid.int()].fqn;
        }
        return qp;
    }
    if (scopeTypeRename(b, ty.name.name, ty.span.file.int())) |renamed| return renamed;
    // A bare check type this file explicitly imports normalises to the imported
    // class's FQN, since a lifted name is shared between nested members two
    // packages both declare. An enclosing nested classifier still wins.
    if (!enclosingDeclaresNestedClassifier(b, ty.name.name)) {
        if (b.module.classIdExactImport(ty.name.name, ty.span.file)) |cid| {
            if (cid.int() < b.module.classes.items.len) return b.module.classes.items[cid.int()].fqn;
        }
    }
    return ty.name.name;
}

/// Whether the enclosing-class chain declares a nested classifier named `name`,
/// the scope a bare check-type name binds in before imports.
fn enclosingDeclaresNestedClassifier(b: *const FuncBuilder, name: []const u8) bool {
    const oc = b.ownerClass() orelse return false;
    const owner_id = b.module.classId(oc) orelse return false;
    return b.module.classIdNestedIn(owner_id, name) != null;
}

/// The mangled per-file global for a bare read of a renamed file-private
/// top-level property. Locals, captures, and own members shadow it.
pub fn filePrivatePropRename(b: *FuncBuilder, name: []const u8, file: u32) ?[]const u8 {
    const renamed = build.filePrivateRename(name, file) orelse return null;
    if (b.resolve(name) != null) return null;
    if (b.knowsOuter(name)) return null;
    if (decl_mod.isLowerAnonCapture(name)) return null;
    if (b.hasOwnMember(name)) return null;
    return renamed;
}

/// The declared name a renamed import binds `seg` to for a bare read, when
/// nothing in scope claims the name as written.
fn bareAliasTargetName(b: *FuncBuilder, seg: *const ast.Ident) ?[]const u8 {
    if (b.resolve(seg.name) != null or b.knowsOuter(seg.name) or b.isParam(seg.name)) return null;
    // A member of the enclosing class wins over an import.
    if (b.hasOwnMember(seg.name) or b.hasEnclosingMember(seg.name)) return null;
    if (topLevelNameExists(b, seg.name)) return null;
    for (b.module.importAliasPathsIn(seg.span.file, seg.name)) |p| {
        if (p.segs.len == 0) continue;
        const target = p.segs[p.segs.len - 1];
        if (std.mem.eql(u8, target, seg.name)) continue;
    // The import itself is the evidence: the target may be a compiler intrinsic
    // with no registry row.
        return target;
    }
    return null;
}

/// Whether a top-level property of this spelling exists; calls and classifiers
/// resolve through their own alias paths.
fn topLevelNameExists(b: *FuncBuilder, name: []const u8) bool {
    if (b.module.registry.top_level_prop_getters.contains(name)) return true;
    return b.module.registry.top_level_prop_pkgs.contains(name);
}

pub fn lowerPath(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const segments = expr.Path.segments;
    const span0 = expr.Path.span;

    // `var x by D` reads through the delegate at every read, which in a
    // composition records the read on the snapshot so a later write invalidates.
    if (segments.len == 1) {
        if (try lowerDelegateRead(b, segments[0].name)) |r| return r;
    }

    // A bare reference from the declaring file resolves to the per-file mangled
    // global, unless shadowed.
    if (filePrivatePropRename(b, segments[0].name, segments[0].span.file.int())) |renamed| {
        const new_segs = try b.allocator.dupe(ast.Ident, segments);
        defer b.allocator.free(new_segs);
        new_segs[0] = .{ .name = renamed, .span = segments[0].span };
        const rewritten = Expr{ .Path = .{ .segments = new_segs, .span = span0 } };
        return lowerExpr(b, &rewritten);
    }

    // `const val name = <literal>` inline.
    if (segments.len == 1 and b.ownerClass() != null and b.resolve(segments[0].name) == null) {
        const owner = b.ownerClass().?;
        if (b.module.registry.class_const_inits.get(.{ .a = owner, .b = segments[0].name })) |c| {
            return b.emitConst(c);
        }
    }
    // Mangled nested-class/object alias and file-private type rewrite.
    {
        const renamed = scopeTypeRename(b, segments[0].name, segments[0].span.file.int());
        if (renamed != null and b.resolve(segments[0].name) == null) {
            const new_segs = try b.allocator.dupe(ast.Ident, segments);
            defer b.allocator.free(new_segs);
            new_segs[0] = .{ .name = renamed.?, .span = segments[0].span };
            const rewritten = Expr{ .Path = .{ .segments = new_segs, .span = span0 } };
            return lowerExpr(b, &rewritten);
        }
    }

    if (segments.len == 1) {
        const name0 = segments[0].name;
        // Bare `Unit` is the Unit singleton value.
        if (std.mem.eql(u8, name0, "Unit") and b.resolve("Unit") == null) {
            return b.emitConst(.Unit);
        }
        // Splice hygiene for the suspend-implicit `coroutineContext`: inside a
        // spliced inline-fn body, the bare name means the intrinsic, since the
        // callee could not see a caller local sharing it.
        if (std.mem.eql(u8, name0, "coroutineContext") and b.lambda_splice_resolve == null) {
            if (b.inlineLambdaCallerDepth()) |base| {
                if (b.resolveSpliceLocal(name0, base) == null) {
                    const dst = b.allocReg();
                    const n = try b.module.internConst(b.allocator, .{ .String = "coroutineContext" });
                    try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
                    return dst;
                }
            }
        }
        // A renamed import binds this spelling to another declaration, and a bare
        // property read has no other alias path.
        if (bareAliasTargetName(b, &segments[0])) |target| {
            const dst = b.allocReg();
            const n = try b.module.internConst(b.allocator, .{ .String = target });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
            return dst;
        }
        if (b.resolve(name0)) |r| {
            if (runtime.envOnce("KLIO_BARE_TRACE")) |w| if (std.mem.eql(u8, w, name0)) {
                std.debug.print("[bare-read-local] {s} reg={d} in={s} window={}\n", .{ name0, r.int(), build.currentRealFn() orelse "-", b.lambda_splice_resolve != null });
            };
            if (b.isBoxed(name0)) {
                const dst = b.allocReg();
                try b.push(.{ .CellGet = .{ .dst = dst, .cell = r } });
                return lateinitLocalRead(b, name0, dst, r);
            }
            return lateinitLocalRead(b, name0, r, r);
        }
        // Whether a capture is a shared Cell is decided by the capture site's
        // builder, invisible here, so always read through CellGet, which passes a
        // non-cell value unchanged.
        if (isLowerAnonCapture(name0)) {
            const cell = try b.loadCaptureHoisted(name0);
            const dst = b.allocReg();
            try b.push(.{ .CellGet = .{ .dst = dst, .cell = cell } });
            return lateinitLocalRead(b, name0, dst, null);
        }
        // Lambda-body capture.
        if (b.knowsOuter(name0)) {
            const cell = try b.loadCaptureHoisted(name0);
            if (b.isBoxed(name0)) {
                const dst = b.allocReg();
                try b.push(.{ .CellGet = .{ .dst = dst, .cell = cell } });
                return lateinitLocalRead(b, name0, dst, null);
            }
            return lateinitLocalRead(b, name0, cell, null);
        }
        // An `it` with no lambda supplying one is an unresolved reference in
        // Kotlin; record the diagnostic so the driver fails before the run.
        if (b.it_suppressed and std.mem.eql(u8, name0, "it")) {
            try b.module.resolve_diags.append(b.allocator, .{
                .name = "it",
                .fqn_a = "",
                .fqn_b = "",
                .span = segments[0].span,
                .kind = .unresolved_local,
            });
            return b.emitConst(.Unit);
        }
        // A bare `coroutineContext` member of the implicit receiver.
        if (std.mem.eql(u8, name0, "coroutineContext") and b.hasOwnMember("coroutineContext")) {
            if (b.resolve("this")) |this_reg| {
                const dst = b.allocReg();
                const field = try b.module.internConst(b.allocator, .{ .String = "$coroutineContext$explicit" });
                try b.push(.{ .GetField = .{ .dst = dst, .receiver = this_reg, .field = field } });
                return dst;
            }
        }
        // Member read on `this` when the owning class declares the name. A
        // companioned class name is its companion singleton, and a nested
        // classifier is a class reference, so both are excepted.
        if (b.hasOwnMember(name0) and !classWithCompanion(b, name0) and
            !spliceSubjectHidesOwnMember(b, name0))
        {
            if (b.resolve("this")) |this_reg| {
                const dst = b.allocReg();
                const nm = try sgetterName(b, name0);
                try b.push(.{ .GetField = .{ .dst = dst, .receiver = this_reg, .field = nm } });
                return dst;
            }
        // Superclass-ctor delegation thunk: a bare own-member is a companion access.
            if (b.isParamThunk()) {
                if (b.ownerClass()) |owner| {
                    const cls = b.allocReg();
                    const on = try b.module.internConst(b.allocator, .{ .String = owner });
                    try b.push(.{ .LoadGlobal = .{ .dst = cls, .name = on } });
                    const dst = b.allocReg();
                    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
                    try b.push(.{ .GetField = .{ .dst = dst, .receiver = cls, .field = nm } });
                    return dst;
                }
            }
        }
        // A bare reference to the enclosing type's own companion resolves to that
        // singleton; a companion with a supertype is also a classId under its
        // simple name and would otherwise route to the class reference. Loaded by
        // exact class id, since a bare head inside a body extending a same-named
        // nested type names the inherited one.
        if (b.ownerClass()) |owner| {
            const comp_mangled: ?[]const u8 = b.module.registry.companion_singletons.get(owner);
            if (comp_mangled) |cm| {
                const simple = if (std.mem.findScalarLast(u8, cm, '$')) |i| cm[i + 1 ..] else cm;
                if (std.mem.eql(u8, simple, name0)) {
                    const cls = b.allocReg();
                    const on = try b.module.internConst(b.allocator, .{ .String = owner });
                    const cid = b.module.classIdIndexed(owner, b.self_package, segments[0].span.file);
                    try b.push(.{ .LoadGlobal = .{ .dst = cls, .name = on, .class = cid } });
                    const dst = b.allocReg();
                    const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
                    try b.push(.{ .GetField = .{ .dst = dst, .receiver = cls, .field = nm } });
                    return dst;
                }
            }
        }
        // Runtime-lowered anon-object bodies carry the classifier identities
        // visible at their lexical site, and their side modules have no class
        // index, so bind by FQN after locals, captures, and members.
        if (build.anonScopeClass(name0)) |class_ref| {
            const cls = b.allocReg();
            const fqn = try b.module.internConst(b.allocator, .{ .String = class_ref.fqn });
            try b.push(.{ .LoadGlobal = .{ .dst = cls, .name = fqn } });
            if (!class_ref.has_companion) return cls;
            const dst = b.allocReg();
            const sentinel = try b.module.internConst(b.allocator, .{ .String = "<class-companion-or-self>" });
            try b.push(.{ .GetField = .{ .dst = dst, .receiver = cls, .field = sentinel } });
            return dst;
        }
        // Kotlin inlines a visible top-level `const val` at every reference, and
        // it outranks a class binding from a less-visible scope.
        if (b.resolve(name0) == null and !b.knowsOuter(name0) and
            !b.hasOwnMember(name0) and !b.hasEnclosingMember(name0) and
            !build.anonCaptureBinds(name0))
        {
            if (b.module.topLevelConstLiteral(name0, b.self_package, segments[0].span.file)) |cv| {
                const ptier = b.module.topLevelPropRefTier(name0, b.self_package, segments[0].span.file) orelse 255;
                const ctier = b.module.classRefTier(name0, b.self_package, segments[0].span.file) orelse 255;
                if (ptier < ctier) {
                    orEmitAudit(b, "top_level_prop", "ConstInline", name0);
                    return try b.emitConst(cv);
                }
            }
        }
        // A named companion-member import outranks a same-named class in
        // expression position, where the classifier only matters in type position.
        if (b.resolve(name0) == null and !b.knowsOuter(name0) and
            !b.hasOwnMember(name0) and !b.hasEnclosingMember(name0))
        {
            if (importCompanionRewrite(b, segments[0].span.file, name0)) |rw| {
                const sp = segments[0].span;
                const rsegs = try b.allocator.alloc(ast.Ident, rw.segs.len);
                for (rw.segs, 0..) |s2, k| rsegs[k] = .{ .name = s2, .span = sp };
                const qualified = Expr{ .Path = .{ .segments = rsegs, .span = sp } };
                return lowerExpr(b, &qualified);
            }
        }
        // A bare name that is a known class is a class reference, but in a receiver
        // context a runtime member shadows the classifier, so the read decides at
        // runtime with the index-resolved class as the exact global arm. `classId`
        // is null under collision-mangling, where an explicit import still names one.
        if ((b.module.classId(name0) != null or
            b.module.classIdExactImport(name0, segments[0].span.file) != null) and
            (!enclosingMemberShadowsClass(b, name0) or classWithCompanion(b, name0)))
        {
            const n = try b.module.internConst(b.allocator, .{ .String = name0 });
            const cls = b.allocReg();
            if (inReceiverContext(b)) {
                const this_idx = try b.recordCapture("this");
                orEmitAudit(b, "class_name_value", "LoadFromThisOrGlobal", name0);
                try b.push(.{ .LoadFromThisOrGlobal = .{
                    .dst = cls,
                    .this_idx = this_idx,
                    .name = n,
                    .class = scopedClassIdForRead(b, name0, segments[0].span.file),
                } });
            } else {
                orEmitAudit(b, "class_name_value", "LoadGlobal", name0);
                try b.push(.{ .LoadGlobal = .{
                    .dst = cls,
                    .name = n,
                    .class = scopedClassIdForRead(b, name0, segments[0].span.file),
                } });
            }
            const dst = b.allocReg();
            const sentinel = try b.module.internConst(b.allocator, .{ .String = "<class-companion-or-self>" });
            try b.push(.{ .GetField = .{ .dst = dst, .receiver = cls, .field = sentinel } });
            return dst;
        }
        // Outside any receiver context nothing can shadow a builtin type name.
        if (isBuiltinTypeName(name0)) {
            const name = try b.module.internConst(b.allocator, .{ .String = name0 });
            const dst = b.allocReg();
            if (inReceiverContext(b)) {
                const this_idx = try b.recordCapture("this");
                orEmitAudit(b, "builtin_type_name", "LoadFromThisOrGlobal", name0);
                try b.push(.{ .LoadFromThisOrGlobal = .{ .dst = dst, .this_idx = this_idx, .name = name } });
            } else {
                orEmitAudit(b, "builtin_type_name", "LoadGlobal", name0);
                try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = name } });
            }
            return dst;
        }
        // An imported companion member rewrites to the qualified `C.MEMBER` access.
        if (b.resolve(name0) == null) {
            if (importCompanionRewrite(b, segments[0].span.file, name0)) |rw| {
                const sp = segments[0].span;
                const rsegs = try b.allocator.alloc(ast.Ident, rw.segs.len);
                for (rw.segs, 0..) |s, k| rsegs[k] = .{ .name = s, .span = sp };
                const qualified = Expr{ .Path = .{ .segments = rsegs, .span = sp } };
                return lowerExpr(b, &qualified);
            }
        // A member brought in bare by `import EnumOrObject.*`. An implicit-receiver
        // member shadows a star-import, including one of a lexically enclosing
        // receiver that `hasOwnMember` misses inside a lambda, and so does a
        // same-scope top-level declaration.
            if (!b.hasEnclosingMember(name0) and !isTopLevelProp(name0) and
                !b.module.hasBareCallCandidate(name0, segments[0].span.file))
            {
                if (wildcardClassMemberRewrite(b, segments[0].span.file)) |cls| {
                    const sp = segments[0].span;
                    var rsegs = [_]ast.Ident{
                        .{ .name = cls, .span = sp },
                        .{ .name = name0, .span = sp },
                    };
                    const qualified = Expr{ .Path = .{ .segments = &rsegs, .span = sp } };
                    return lowerExpr(b, &qualified);
                }
            }
        }
        // A known top-level property is a global read unless a runtime implicit
        // receiver could shadow it, since kotlinc resolves implicit-receiver
        // members ahead of package-scope properties. A class visible from this
        // scope also outranks a top-level property the file never imported; an
        // `object` has no property tier and stays on the top-level path.
        const class_over_unimported_prop = b.module.classIdIndexed(name0, b.self_package, segments[0].span.file) != null and
            (b.module.topLevelPropRefTier(name0, b.self_package, segments[0].span.file) orelse 0) >= 4;
        if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
            if (std.mem.eql(u8, w, name0) and isTopLevelProp(name0)) std.debug.print("[tlp] {s} narrow={?s} recvTy={?s} in_recv_ctx={} narrowed_declares={}\n", .{ name0, b.thisNarrow(), b.recvTy(), inReceiverContext(b), narrowedThisDeclares(b, name0, segments[0].span.file) });
        }
        if (isTopLevelProp(name0) and !b.hasOwnMember(name0) and !b.hasEnclosingMember(name0) and
            !narrowedThisDeclares(b, name0, segments[0].span.file) and
            !build.anonCaptureBinds(name0) and !class_over_unimported_prop and
            b.module.classIdExactImport(name0, segments[0].span.file) == null and
            !(inReceiverContext(b) and anyReceiverClassDeclares(b, name0)))
        {
            // Kotlin inlines a visible `const val` at every reference, which also
            // keeps the read out of the flat runtime global table.
            if (b.module.topLevelConstLiteral(name0, b.self_package, segments[0].span.file)) |cv| {
                orEmitAudit(b, "top_level_prop", "ConstInline", name0);
                return try b.emitConst(cv);
            }
            // A bare read whose only declaration is an unimported cross-package
            // property is unresolved.
            if (b.module.topLevelPropFqn(name0)) |pfqn| {
                _ = try recordOutOfScopeRef(b, name0, segments[0].span, pfqn, b.module.topLevelPropRefTier(name0, b.self_package, segments[0].span.file));
            }
            orEmitAudit(b, "top_level_prop", "LoadGlobal", name0);
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
            return dst;
        }
        // Value-position reference to a top-level function no receiver can shadow:
        // the symbol index resolves it from the caller's scope and a unique pick
        // loads by exact FQN.
        if (!inReceiverContext(b) and
            !b.hasOwnMember(name0) and !b.hasEnclosingMember(name0) and !isTopLevelProp(name0))
        {
            const ref_pick = b.module.resolveBareRefIndexed(name0, b.self_package, segments[0].span.file);
            refAudit(b, name0, ref_pick);
            if (ref_pick) |fid| {
                if (b.module.funcById(fid)) |f| {
                    if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
                        if (std.mem.eql(u8, w, name0)) {
                            std.debug.print("[bare-value-arm] {s} -> {s}#{d} self_pkg={s} file={d} fn={s}\n", .{ name0, f.fqn, fid.int(), b.self_package, segments[0].span.file.int(), build.currentRealFn() orelse "-" });
                        }
                    }
                    _ = try recordOutOfScopeRef(b, name0, segments[0].span, f.fqn, b.module.bareRefTier(name0, b.self_package, segments[0].span.file));
                    const dst = b.allocReg();
                    const n = try b.module.internConst(b.allocator, .{ .String = f.fqn });
                    try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n, .func = fid } });
                    return dst;
                }
            }
        }
        if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
            if (std.mem.eql(u8, w, name0)) {
                std.debug.print("[bare-read-pre] {s} this={} splice_recv={s} window={} in={s} own={} encl={} owner={s}\n", .{
                    name0,
                    b.resolve("this") != null,
                    b.spliceRecvTy() orelse "-",
                    b.lambda_splice_resolve != null,
                    build.currentRealFn() orelse "-",
                    b.hasOwnMember(name0),
                    b.enclosing_members.contains(name0),
                    b.ownerClass() orelse "-",
                });
                if (b.enclosing_members.contains(name0)) {
                    std.debug.print("[bare-read-encl]", .{});
                    var eit = b.enclosing_members.keyIterator();
                    var n: usize = 0;
                    while (eit.next()) |k| : (n += 1) {
                        if (n < 40) std.debug.print(" {s}", .{k.*});
                    }
                    std.debug.print(" (total {d})\n", .{n});
                }
            }
        }
        if (b.resolve("this")) |this_reg| {
            // A known top-level fn is a value-position function reference, and a
            // known top-level property likewise skips the GetField shortcut, whose
            // lenient field resolution adopts outer-chain members.
            const is_known_global =
                b.module.hasBareCallCandidate(name0, segments[0].span.file) or
                isTopLevelProp(name0);
            // A name declared only by an outer class defers to the
            // implicit-receiver walk, which carries the declaring class in the
            // scoped getter name.
            const enclosing_only_member = !b.hasOwnMember(name0) and b.hasEnclosingMember(name0);
            // Directly inside an inline extension splice the body was written
            // against the declaration's scope, where the bound receiver's members
            // shadow any top-level candidate; the GetField read keeps its runtime
            // miss-fallback. A nested lambda inside the splice is excluded.
            // A spliced receiver lambda has no runtime closure, its receiver being
            // only the window's bound register, so when the window head statically
            // declares the name the member read wins.
            const window_recv_declares = b.lambda_splice_resolve != null and
                // The head must describe the value actually bound as `this`: a
                // member-inline splice binds its owner while a nested plain-lambda
                // window carries the lambda's context head.
                b.splice_recv_from_window and blk: {
                const rh = b.spliceRecvTy() orelse break :blk false;
                const h = typeHead(std.mem.trimEnd(u8, rh, "?"));
                const hs = b.module.registry.hierarchy_shadow_names.get(h) orelse break :blk false;
                if (!hs.complete) break :blk false;
                break :blk hs.names.contains(name0);
            };
            const splice_receiver_first = (b.lambda_splice_resolve == null and b.spliceRecvTy() != null) or
                window_recv_declares;
            if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
                if (std.mem.eql(u8, w, name0)) {
                    std.debug.print("[bare-read] {s} in={s} known_global={} own={} encl={} splice_recv={s} owner={s} narrow={s} recvTy={s}\n", .{
                        name0,
                        build.currentRealFn() orelse "-",
                        is_known_global,
                        b.hasOwnMember(name0),
                        b.hasEnclosingMember(name0),
                        b.spliceRecvTy() orelse "-",
                        b.ownerClass() orelse "-",
                        b.thisNarrow() orelse "-",
                        b.recvTy() orelse "-",
                    });
                }
            }
            // Unless the innermost receiver is statically the class the scoped
            // getter names. A receiver lambda inside a companion binds `this` to
            // the scope-function receiver, unreachable by the deferred walk, which
            // rides a capture chain holding no instance.
            const receiver_is_owner = blk: {
                if (!enclosing_only_member) break :blk false;
                // The splice head vouches for the resolved `this` only when the
                // window bound it; a bare member-inline splice binds nothing, so
                // the ambient `this` is whatever the enclosing lambda holds.
                const rh = (if (b.lambda_splice_resolve == null or b.splice_recv_from_window)
                    b.spliceRecvTy()
                else
                    null) orelse b.recvTy() orelse break :blk false;
                const decl_owner = sgetterOwner(b, name0) orelse break :blk false;
                const rhh = typeHead(std.mem.trimEnd(u8, rh, "?"));
                if (rhh.len == 0) break :blk false;
                if (b.module.classIsOrExtends(rhh, decl_owner)) break :blk true;
                // The declaring owner may carry a file-collision mangle the
                // receiver's source-spelled head never does.
                if (!inline_call.rfsEnabled()) break :blk false;
                break :blk std.mem.eql(u8, rhh, stripLowerFileMangle(decl_owner)) or
                    b.module.classIsOrExtends(rhh, stripLowerFileMangle(decl_owner));
            };
            // kotlinc ranks implicit receivers innermost first, so the extension
            // receiver's members shadow the enclosing class's; a smart-cast `this`
            // likewise exposes the narrowed class's members ahead of any global.
            const narrow_declares = narrowedThisDeclares(b, name0, segments[0].span.file);
            const recv_declares = narrow_declares or blk: {
                const rh = b.recvTy() orelse break :blk false;
                const h = typeHead(std.mem.trimEnd(u8, rh, "?"));
                const hs = b.module.registry.hierarchy_shadow_names.get(h) orelse break :blk false;
                if (!hs.complete) break :blk false;
                break :blk hs.names.contains(name0);
            };
            if ((!is_known_global or splice_receiver_first or recv_declares) and
                (!enclosing_only_member or receiver_is_owner or recv_declares))
            {
                const dst = b.allocReg();
                const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
                // The ambient `this` may be a spliced subject whose static class
                // lacks the name; kotlinc ranks implicit receivers by static type,
                // so the read binds the innermost subject that declares it.
                const target = subjectCorrectedBareThis(b, name0, this_reg);
                try b.push(.{ .GetField = .{ .dst = dst, .receiver = target, .field = nm } });
                return dst;
            }
            // Inside a spliced receiver lambda whose subject's static class lacks
            // the name, the enclosing class's member is the binding: kotlinc ranks
            // implicit receivers by static type, not by the runtime object.
            const window_head_lacks = b.lambda_splice_resolve != null and b.splice_recv_from_window and blk: {
                const rh = b.spliceRecvTy() orelse break :blk false;
                const h = typeHead(std.mem.trimEnd(u8, rh, "?"));
                const hs = b.module.registry.hierarchy_shadow_names.get(h) orelse break :blk false;
                if (!hs.complete) break :blk false;
                break :blk !hs.names.contains(name0);
            };
            if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
                if (std.mem.eql(u8, w, name0)) {
                    const rh0 = b.spliceRecvTy() orelse "-";
                    const hs0 = b.module.registry.hierarchy_shadow_names.get(typeHead(std.mem.trimEnd(u8, rh0, "?")));
                    std.debug.print("[bare-read-corr] {s} window_lacks={} encl_only={} window={} from_window={} recv={s} hs={} complete={} subjects={d} known_global={} recv_declares={}\n", .{ name0, window_head_lacks, enclosing_only_member, b.lambda_splice_resolve != null, b.splice_recv_from_window, rh0, hs0 != null, if (hs0) |h| h.complete else false, b.subject_binds.items.len, is_known_global, recv_declares });
                }
            }
            if ((enclosing_only_member or window_head_lacks) and !recv_declares and !is_known_global) blk: {
                const oc = b.ownerClass() orelse break :blk;
                const ocid = b.module.classIdIndexed(oc, b.self_package, segments[0].span.file) orelse
                    b.module.classId(oc) orelse break :blk;
                if (!b.module.classHierarchyDeclaresMember(ocid, name0)) break :blk;
                const corrected = subjectCorrectedBareThis(b, name0, this_reg);
                if (corrected == this_reg) break :blk;
                orEmitAudit(b, "subject_corrected_read", "GetField", name0);
                const dst = b.allocReg();
                const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
                try b.push(.{ .GetField = .{ .dst = dst, .receiver = corrected, .field = nm } });
                return dst;
            }
        }
        // Outside any receiver context no member can shadow the name; kotlinc
        // rejects resolving it against a caller's receiver.
        if (!inReceiverContext(b)) {
            orEmitAudit(b, "bare_name_fallthrough", "LoadGlobal", name0);
            const dst = b.allocReg();
            // A renamed import binds this spelling to another declaration, and a
            // bare property read has no other alias path. Resolved at emission
            // only, so diagnostics report the source spelling.
            const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
            return dst;
        }
        const this_idx = try b.recordCapture("this");
        const dst = b.allocReg();
        const name = try sgetterName(b, name0);
        // The index's unique pick rides as the exact global arm; the runtime member
        // probe still runs first.
        const ref_pick = b.module.resolveBareRefIndexed(name0, b.self_package, segments[0].span.file);
        orEmitAudit(b, "bare_name_fallthrough", "LoadFromThisOrGlobal", name0);
        try b.push(.{ .LoadFromThisOrGlobal = .{
            .dst = dst,
            .this_idx = this_idx,
            .name = name,
            .func = ref_pick,
        } });
        return dst;
    }

    // Multi-segment paths. Try the full FQN against the host first.
    if (segments.len >= 2 and
        isPackageHead(segments[0].name) and
        headIsPackage(b, segments[0].name) and
        b.resolve(segments[0].name) == null and
        !b.knowsOuter(segments[0].name) and
        !b.hasEnclosingMember(segments[0].name) and
        b.module.classId(segments[0].name) == null)
    {
        // The const pool stores the slice by reference, so the module allocator
        // must own the joined FQN.
        const fqn = try joinSegments(b.allocator, segments);
        // Ride the exact class id of the longest FQN prefix naming a class, so the
        // runtime binds that declaration rather than re-resolving the tail.
        if (try emitFqnWithClassPrefix(b, fqn)) |r| return r;
        const dst = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = fqn });
        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
        // A fully-qualified class-with-companion in value position resolves to its
        // companion singleton, as the bare-name arm does, so `pkg.C === C` holds.
        // The sentinel returns the class or object value when no companion exists.
        const fqn_simple = if (std.mem.findScalarLast(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
        if (classWithCompanion(b, fqn_simple) and b.module.funcIdByFqn(fqn) == null) {
            const comp = b.allocReg();
            const sentinel = try b.module.internConst(b.allocator, .{ .String = "<class-companion-or-self>" });
            try b.push(.{ .GetField = .{ .dst = comp, .receiver = dst, .field = sentinel } });
            return comp;
        }
        return dst;
    }

    const first = segments[0];
    var cur: Reg = undefined;
    if (b.resolve(first.name)) |r| {
        cur = r;
    } else if (inReceiverContext(b)) {
        // Unresolved head: route through `this` or the enclosing receiver, with a
        // known class riding as the exact global arm.
        const this_idx = try b.recordCapture("this");
        const dst = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = first.name });
        orEmitAudit(b, "multi_seg_head", "LoadFromThisOrGlobal", first.name);
        try b.push(.{ .LoadFromThisOrGlobal = .{
            .dst = dst,
            .this_idx = this_idx,
            .name = n,
            .class = b.module.classIdIndexed(first.name, b.self_package, first.span.file),
        } });
        cur = dst;
    } else {
        // No receiver context: the head is a static global.
        const dst = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = first.name });
        orEmitAudit(b, "multi_seg_head", "LoadGlobal", first.name);
        try b.push(.{ .LoadGlobal = .{
            .dst = dst,
            .name = n,
            .class = b.module.classIdIndexed(first.name, b.self_package, first.span.file),
        } });
        cur = dst;
    }
    for (segments[1..]) |seg| {
        const next = b.allocReg();
        const field = try b.module.internConst(b.allocator, .{ .String = seg.name });
        try b.push(.{ .GetField = .{ .dst = next, .receiver = cur, .field = field } });
        cur = next;
    }
    return cur;
}

/// The source-level name behind a file-collision mangle (`X$f12` -> `X`).
pub fn stripLowerFileMangle(n: []const u8) []const u8 {
    const i = std.mem.findScalarLast(u8, n, '$') orelse return n;
    if (i + 2 >= n.len or n[i + 1] != 'f') return n;
    for (n[i + 2 ..]) |c| {
        if (c < '0' or c > '9') return n;
    }
    return n[0..i];
}

pub fn sgetterOwner(b: *const FuncBuilder, name: []const u8) ?[]const u8 {
    const lexical_owner = b.ownerClass() orelse return null;
    var owner: ?[]const u8 = lexical_owner;
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        const own = std.mem.eql(u8, o, lexical_owner) and b.hasOwnMember(name);
        const hierarchy_has = if (b.module.registry.hierarchy_shadow_names.get(o)) |hierarchy|
            hierarchy.names.contains(name)
        else
            false;
        if (own) return o;
        if (hierarchy_has) return o;
        owner = b.module.registry.enclosing_class.get(o);
    }
    return lexical_owner;
}

/// Intern the scope-qualified getter field `$sgetter$<owner>\u{1f}<name>` when an
/// enclosing class is known, else the plain name.
fn sgetterName(b: *FuncBuilder, name: []const u8) Allocator.Error!ConstId {
    if (sgetterOwner(b, name)) |owner| {
        // The const pool stores the slice by reference, so the module allocator
        // owns the buffer; freeing it here would dangle at dispatch time.
        const qual = try std.fmt.allocPrint(b.allocator, "$sgetter${s}\u{1f}{s}", .{ owner, name });
        return b.module.internConst(b.allocator, .{ .String = qual });
    }
    return b.module.internConst(b.allocator, .{ .String = name });
}

pub const ImportRewrite = struct { segs: []const []const u8 };

/// Resolve a bare name imported via `import a.b.C…MEMBER` into the qualified
/// access path starting at the rightmost segment naming a declared class.
/// Intermediate segments are kept except an explicit `Companion` hop, since a
/// companion member is reached through the class itself.
pub fn importCompanionRewrite(b: *FuncBuilder, file: ir.FileId, name: []const u8) ?ImportRewrite {
    const segs = b.module.importAliasIn(file, name) orelse return null;
    // Extend left across the enclosing-class chain so the path starts at the
    // outermost, globally loadable class; a bare nested class name is not
    // loadable. The scan excludes the leaf, the imported member, so a same-named
    // class elsewhere cannot capture it.
    var cls_idx: ?usize = null;
    var i = segs.len - 1;
    while (i > 0) {
        i -= 1;
        if (b.module.classId(segs[i]) != null) {
            cls_idx = i;
            break;
        }
    }
    const ci = cls_idx orelse return null;

    var start = ci;
    while (start > 0 and b.module.classId(segs[start - 1]) != null) start -= 1;

    // Keep the leading package segments when the import's FQN names a different
    // class than its simple name resolves to in the flat index; the full
    // `pkg.Outer.Member` path names the exact declaration.
    if (start > 0) {
        const fqn_parts = segs[0 .. ci + 1];
        const fqn = std.mem.join(b.allocator, ".", fqn_parts) catch return null;
        if (b.module.classIdByFqn(fqn)) |fqn_cid| {
            const simple_cid = b.module.classId(segs[ci]);
            if (simple_cid == null or simple_cid.?.int() != fqn_cid.int()) start = 0;
        }
    }

    const last = segs.len - 1;
    var out = b.allocator.alloc([]const u8, segs.len - start) catch return null;
    var n: usize = 0;
    var j = start;
    while (j < segs.len) : (j += 1) {
        // Drop an intermediate `Companion` hop but keep a nested classifier.
        if (j != last and std.mem.eql(u8, segs[j], "Companion")) continue;
        out[n] = segs[j];
        n += 1;
    }
    return .{ .segs = out[0..n] };
}

/// The simple class name to qualify a bare name brought into scope by
/// `import EnumOrObject.*`, or null when no wildcard import targets such a class.
fn wildcardClassMemberRewrite(b: *FuncBuilder, file: ir.FileId) ?[]const u8 {
    const list = b.module.registry.import_wildcards.get(file) orelse return null;
    for (list.items) |path| {
        // A wildcard target naming a class, not a package, makes its members
        // visible bare. Match the full FQN first, then the simple tail.
        if (b.module.classIdByFqn(path) != null) return lastPathSegment(path);
        const tail = lastPathSegment(path);
        if (b.module.classId(tail) != null) return tail;
    }
    return null;
}

fn lastPathSegment(path: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, path, '.')) |dot| return path[dot + 1 ..];
    return path;
}

fn isBuiltinTypeName(name: []const u8) bool {
    const names = [_][]const u8{
        "Int",   "Long",    "Short",  "Byte", "Double", "Float",
        "Char",  "Boolean", "String", "UInt", "ULong",  "UShort",
        "UByte",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

pub fn lowerStringTemplate(b: *FuncBuilder, parts: []const ast.StringPart) Allocator.Error!Reg {
    var cur = try b.emitConst(.{ .String = "" });
    for (parts) |part| {
        const piece = switch (part) {
            .Text => |s| try b.emitConst(.{ .String = s }),
            .ShortInterp => |ident| try lowerShortInterp(b, ident),
            .Interp => |e| try lowerExpr(b, e),
        };
        const dst = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = dst, .op = .StringConcat, .lhs = cur, .rhs = piece } });
        cur = dst;
    }
    return cur;
}

fn lowerShortInterp(b: *FuncBuilder, ident: ast.Ident) Allocator.Error!Reg {
    // `$this` lowers exactly like a bare `this`: the bound register, or the
    // captured slot in a lambda body.
    if (std.mem.eql(u8, ident.name, "this")) {
        if (b.resolve("this")) |r| return r;
        return b.loadCaptureHoisted("this");
    }
    // `"… $x …"` for a `var x by D` local reads through the delegate.
    if (try lowerDelegateRead(b, ident.name)) |r| return r;
    if (b.resolve(ident.name)) |r| {
        if (b.isBoxed(ident.name)) {
            const dst = b.allocReg();
            try b.push(.{ .CellGet = .{ .dst = dst, .cell = r } });
            return lateinitLocalRead(b, ident.name, dst, r);
        }
        return lateinitLocalRead(b, ident.name, r, r);
    }
    if (b.knowsOuter(ident.name)) {
        const cell = try b.loadCaptureHoisted(ident.name);
        if (b.isBoxed(ident.name)) {
            const dst = b.allocReg();
            try b.push(.{ .CellGet = .{ .dst = dst, .cell = cell } });
            return lateinitLocalRead(b, ident.name, dst, null);
        }
        return lateinitLocalRead(b, ident.name, cell, null);
    }
    // A renamed file-private top-level property reads its per-file mangled global.
    if (filePrivatePropRename(b, ident.name, ident.span.file.int())) |renamed| {
        var segs = [_]ast.Ident{.{ .name = renamed, .span = ident.span }};
        const path = Expr{ .Path = .{ .segments = &segs, .span = ident.span } };
        return lowerExpr(b, &path);
    }
    // `$x` for an `import Object.x` member reads the object's property.
    if (!b.hasOwnMember(ident.name)) {
        if (importCompanionRewrite(b, ident.span.file, ident.name)) |rw| {
            const rsegs = try b.allocator.alloc(ast.Ident, rw.segs.len);
            for (rw.segs, 0..) |sname, k| rsegs[k] = .{ .name = sname, .span = ident.span };
            const path = Expr{ .Path = .{ .segments = rsegs, .span = ident.span } };
            return lowerExpr(b, &path);
        }
    }
    if (b.hasOwnMember(ident.name) and b.resolve("this") != null) {
        const this_reg = b.resolve("this").?;
        const dst = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = ident.name });
        try b.push(.{ .GetField = .{ .dst = dst, .receiver = this_reg, .field = nm } });
        return dst;
    }
    if (b.resolve("this")) |this_reg| {
        const dst = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = ident.name });
        try b.push(.{ .GetField = .{ .dst = dst, .receiver = this_reg, .field = n } });
        return dst;
    }
    const n = try b.module.internConst(b.allocator, .{ .String = ident.name });
    const dst = b.allocReg();
    if (inReceiverContext(b)) {
        const this_idx = try b.recordCapture("this");
        orEmitAudit(b, "short_interp", "LoadFromThisOrGlobal", ident.name);
        try b.push(.{ .LoadFromThisOrGlobal = .{ .dst = dst, .this_idx = this_idx, .name = n } });
    } else {
        orEmitAudit(b, "short_interp", "LoadGlobal", ident.name);
        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
    }
    return dst;
}
