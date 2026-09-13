//! Path expression lowering: scope renames, lowered type names, and string
//! template interpolation.

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

/// A bare `name` an enclosing class declares as a value member (an enclosing
/// companion's `Default`) shadows an unrelated global classifier of the same
/// simple name. True when `name` is an enclosing member and is NOT a nested
/// Whether `name` is a known class that has a registered companion object.
/// Such a name in value position is its companion singleton (Kotlin: `C`
/// yields `C.Companion`), which must win over a folded classifier name that
/// would otherwise route the read to a non-existent `this.<name>` field.
pub fn classWithCompanion(b: *const FuncBuilder, name: []const u8) bool {
    return b.module.classId(name) != null and
        b.module.registry.companion_singletons.contains(name);
}

/// type reachable along the enclosing-owner chain (a nested type keeps the
/// classifier path so it names a class value).
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

/// The mangled lift name a type reference `name` resolves to in the
/// current scope: a (mangled) nested class/object aliased anywhere along
/// the enclosing-class chain — Kotlin makes a private nested class
/// visible throughout its declaring class's subtree, and a lifted
/// sibling/nested member keeps the outer on its chain — or a renamed
/// file-private class/typealias declared by the reference's own file.
/// Returns null when no rename applies.

/// Whether the own member overload of `name` with this arity declares a
/// NON-function parameter where the call passes a lambda literal — such a
/// member cannot bind the call, so it must not outrank a same-named
/// extension that can (`cast(value, name) { … }` picking the member
/// `cast(value, name, tag: String)` bound the lambda to `tag`).
/// Whether the enclosing class declares a member named `name` that a call
/// with `nargs` arguments can bind. The own-member arity mask decides when
/// it has an entry; a lazily lowered body carries none, and then the
/// registered signatures of the owner's same-named members decide
/// (`Json.encodeToString(value, mode)` never takes one argument). Unknown
/// stays applicable, as the mask's own default does.
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
    // The registration key is the SOURCE class name; a file-private class
    // lowers under a `$f<n>` mangle and a nested one under `Outer$Inner`.
    const mf = inline_state.exprBodyMemberAst(owner, name, args.len) orelse blk: {
        if (std.mem.indexOf(u8, owner, "$f")) |i| {
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

/// `scopeTypeRename` starting the enclosing-class walk at an explicit
/// owner: an inline splice binds its reified names AFTER pushing the
/// callee's frame (which drops the caller's owner), so the caller's
/// lexical owner is passed in to keep a nested class's lifted name.
pub fn scopeTypeRenameFrom(b: *const FuncBuilder, owner_start: ?[]const u8, name: []const u8, file: u32) ?[]const u8 {
    var owner = owner_start;
    var hops: usize = 0;
    while (owner) |o| : (hops += 1) {
        if (hops > 32) break;
        if (b.module.registry.nested_object_aliases.get(o)) |m| {
            if (m.get(name)) |renamed| return renamed;
        }
        // The class's own companion object named `name` is its static
        // scope's binding (`class DataElement : AbstractCoroutineContextElement(Key)
        // { companion object Key }`): a same-named classifier nested in a
        // supertype (`CoroutineContext.Key`) never outranks it.
        if (ownCompanionNamed(b, o, name)) return null;
        // A supertype's nested classifiers are in scope in the subclass
        // body (`Conflict("foo")` inside a test extending the base that
        // declares `class Conflict`), lifted names included.
        if (supertypeNestedAlias(b, o, name, 0)) |renamed| return renamed;
        owner = b.module.registry.enclosing_class.get(o);
    }
    // An anon-object member body lowering at runtime carries its lexical
    // site's flattened renames (the side module's registries are empty).
    if (build.anonScopeRename(name)) |renamed| return renamed;
    if (build.fileTypeRename(name, file)) |renamed| return renamed;
    // Same-package cross-file reference to a package-renamed internal
    // top-level classifier.
    if (b.module.packageOfFile(ir.FileId.from(file))) |pkg| {
        if (build.pkgTypeRename(name, pkg)) |renamed| return renamed;
    }
    // Cross-package reference through an import of the declaring package
    // (internal visibility spans the whole module).
    if (decl_mod.importedPkgTypeRename(b.module, name, ir.FileId.from(file))) |renamed| return renamed;
    return null;
}

/// The lifted name a supertype of `cls_name` registers for nested `name`,
/// walking the declared supertype chain.
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

/// Flatten every scope-true type rename visible at the current lexical
/// site — the enclosing-class chain's alias maps (nearest scope first),
/// the anon-scope renames when this site itself sits inside an anon-object
/// body lowering, and the declaring file's file-private type renames —
/// into one slice for a `BuildObject` instruction. First entry per name
/// wins on lookup, so nearer scopes shadow outer ones.
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

/// Resolve every bare classifier referenced by an anonymous-object subtree at
/// its lexical site. The object's bodies lower later in a side module, so these
/// exact identities must travel with the object instruction.
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

/// Reduce a dotted path to its last two segments (`a.b.C` -> `b.C`);
/// null when the path has fewer than two.
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

/// The lowered name for a type position (`as T` / `is T` / catch type):
/// a qualified nested reference (`Outer.Inner`) whose target the lift
/// mangled resolves to the mangled lift name, then the scope-true
/// rename ladder (`scopeTypeRename`), then the bare simple name.
pub fn loweredTypeName(b: *const FuncBuilder, ty: *const ast.TypeRef) []const u8 {
    if (ty.qualified_path) |qp| {
        if (lastTwoSegments(qp)) |key| {
            if (b.module.registry.mangled_nested.get(key)) |m| return m;
        }
    }
    if (scopeTypeRename(b, ty.name.name, ty.span.file.int())) |renamed| return renamed;
    // A function-local class (`@Serializable data class Outer(...)` declared
    // in the body) is keyed by its `$lc<fn>` alias; an explicit type argument
    // naming it (`decodeFromString<Outer>(...)`) binds that alias, not the
    // bare name another file's `Outer` would answer.
    var lc_buf: [160]u8 = undefined;
    if (std.fmt.bufPrint(&lc_buf, "{s}$lc{s}", .{ ty.name.name, build.currentRealFn() orelse "" }) catch null) |key| {
        if (b.module.registry.class_super_names.get(key) != null) {
            return b.allocator.dupe(u8, key) catch ty.name.name;
        }
    }
    return ty.name.name;
}

/// Lower a source type into an owned structural type for builder metadata.
/// The top-level head follows the same scope-aware classifier rename as
/// expression type positions.
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

/// Type name for an `is` / `as` check. Like `loweredTypeName`, but a
/// package-qualified reference (`b.Shape`) keeps its dotted path (normalised
/// to the class FQN when it resolves) instead of being stripped to the simple
/// name, so the runtime hierarchy walk can compare class identity and reject a
/// same-simple-name class from another package. A nested-class path
/// (`Outer.Inner`) still maps to its lifted/mangled name.
pub fn loweredCheckTypeName(b: *const FuncBuilder, ty: *const ast.TypeRef) []const u8 {
    if (ty.qualified_path) |qp| {
        if (lastTwoSegments(qp)) |key| {
            if (b.module.registry.mangled_nested.get(key)) |m| return m;
        }
        // The path's first segment may itself be a nested class lifted under
        // a mangled name (`S.A` written inside `Tests`, where the private
        // `S` lifted as `Tests$S`): the lift keyed `A` by that lifted owner,
        // so the reference resolves through the owner's scope alias.
        if (std.mem.indexOfScalar(u8, qp, '.')) |d| {
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
        // Normalise to the canonical FQN when the dotted path resolves to a
        // registered class; otherwise carry the dotted path through so the
        // runtime resolves (or strips) it once every class is registered.
        if (b.module.classIdByFqn(qp)) |cid| {
            if (cid.int() < b.module.classes.items.len) return b.module.classes.items[cid.int()].fqn;
        }
        return qp;
    }
    if (scopeTypeRename(b, ty.name.name, ty.span.file.int())) |renamed| return renamed;
    // A bare check type this file's explicit import names (`import
    // …Operation.Marker`; `x is Marker`) normalises to the imported class's
    // canonical FQN, so the runtime compares class identity — the simple
    // name alone cannot resolve a nested member two packages both declare
    // (its lifted name is shared, so a name compare matches either twin).
    // An enclosing class's own nested classifier still wins over the
    // import (inner scope first), keeping the simple-name compare.
    if (!enclosingDeclaresNestedClassifier(b, ty.name.name)) {
        if (b.module.classIdExactImport(ty.name.name, ty.span.file)) |cid| {
            if (cid.int() < b.module.classes.items.len) return b.module.classes.items[cid.int()].fqn;
        }
    }
    return ty.name.name;
}

/// Whether any class in the enclosing-class chain declares a NESTED
/// classifier named `name` — the scope where a bare check-type name binds
/// before the file's imports are consulted.
fn enclosingDeclaresNestedClassifier(b: *const FuncBuilder, name: []const u8) bool {
    const oc = b.ownerClass() orelse return false;
    const owner_id = b.module.classId(oc) orelse return false;
    return b.module.classIdNestedIn(owner_id, name) != null;
}

/// The mangled per-file global for a bare `name` referenced from the file
/// `file`, or null when the reference is not a read of a renamed
/// file-private top-level property. Locals, lambda/anon-object captures,
/// and own class members shadow the property (Kotlin scope order), so the
/// rename only applies when none of them bind the name.
pub fn filePrivatePropRename(b: *FuncBuilder, name: []const u8, file: u32) ?[]const u8 {
    const renamed = build.filePrivateRename(name, file) orelse return null;
    if (b.resolve(name) != null) return null;
    if (b.knowsOuter(name)) return null;
    if (decl_mod.isLowerAnonCapture(name)) return null;
    if (b.hasOwnMember(name)) return null;
    return renamed;
}

/// `Path` lowering — the full bare-name resolution ladder.
/// The DECLARED name a renamed import binds `seg` to for a bare READ, when
/// the caller's file imports something under a different leaf and nothing in
/// scope — a local, a parameter, an enclosing capture, a top-level of that
/// spelling — claims the name as written. Null leaves the spelling alone.
fn bareAliasTargetName(b: *FuncBuilder, seg: *const ast.Ident) ?[]const u8 {
    if (b.resolve(seg.name) != null or b.knowsOuter(seg.name) or b.isParam(seg.name)) return null;
    // A MEMBER of the enclosing class wins over an import, so the alias
    // decides only a name nothing in scope claims.
    if (b.hasOwnMember(seg.name) or b.hasEnclosingMember(seg.name)) return null;
    if (topLevelNameExists(b, seg.name)) return null;
    for (b.module.importAliasPathsIn(seg.span.file, seg.name)) |p| {
        if (p.segs.len == 0) continue;
        const target = p.segs[p.segs.len - 1];
        if (std.mem.eql(u8, target, seg.name)) continue;
        // The import itself is the evidence: Kotlin validated the path, and
        // the target may be a compiler intrinsic with no registry row of its
        // own (`kotlin.coroutines.coroutineContext`).
        return target;
    }
    return null;
}

/// Whether a top-level PROPERTY of this spelling exists — a stored global or a
/// custom-getter one. Only the property channel is consulted: a call and a
/// classifier already resolve through their own alias paths.
fn topLevelNameExists(b: *FuncBuilder, name: []const u8) bool {
    if (b.module.registry.top_level_prop_getters.contains(name)) return true;
    return b.module.registry.top_level_prop_pkgs.contains(name);
}

pub fn lowerPath(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const segments = expr.Path.segments;
    const span0 = expr.Path.span;

    // `var x by D` reads THROUGH the delegate: `D.getValue(null, ::x)` at every
    // read, not once at the declaration. A `MutableState` delegate hands back the
    // state's current value that way — and, in a composition, records the read on
    // the snapshot, which is what makes a later write invalidate the group that
    // read it. Reading a value cached at the declaration recorded no read at all,
    // so `var name by mutableStateOf(…)` never recomposed.
    if (segments.len == 1) {
        if (try lowerDelegateRead(b, segments[0].name)) |r| return r;
    }

    // File-private top-level property rename: a bare reference from the
    // declaring file resolves to the per-file mangled global. Locals,
    // captures, and own members keep shadowing it (Kotlin scope order).
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
        // SPLICED inline-fn body (not an inline-argument lambda, whose source
        // lives at the caller), the bare name means the intrinsic — the callee
        // could not see a caller local/param that happens to share it. Without
        // this, `currentCoroutineContext()` (body: bare `coroutineContext`)
        // spliced into a function with a `coroutineContext` PARAMETER answered
        // with the parameter.
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
        // A RENAMED import binds this spelling to another declaration
        // (`import kotlin.coroutines.coroutineContext as currentContext`). A
        // call and a classifier already resolve through the alias; a bare
        // PROPERTY read did not, and reached the runtime as the spelling — a
        // member probe on the enclosing receiver, then an unresolved global.
        // Nothing in scope claims the name, so the import decides it.
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
        // A bare read of a name the enclosing anon object closes over reads
        // the captured value. Whether the capture is a shared Cell (a
        // written-through outer `var`) is decided by the CAPTURE SITE's
        // builder, invisible here — so always read through CellGet, which
        // passes a non-cell value unchanged. Without this a captured
        // counter's `++` handed the raw Cell to UnOp.
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
        // An `it` written in a zero-parameter / receiver lambda whose
        // implicit `it` was suppressed, with no enclosing lambda supplying
        // one: kotlinc rejects this as an unresolved reference. Record the
        // diagnostic so the build driver fails the program before it runs.
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
        // Member read on `this` via GetField when the owning class declares
        // this name. A companioned class name is excepted: it is its companion
        // singleton, resolved by the classifier sentinel below, not a field.
        // A NESTED classifier of the enclosing class (`enum LayoutState` inside
        // `LayoutNode`, referenced bare) is also excepted: it is a class
        // reference, not an instance member, so it falls to the class-ref
        // lowering below (which loads the nested class and reads the enum entry).
        if (b.hasOwnMember(name0) and !classWithCompanion(b, name0) and
            !spliceSubjectHidesOwnMember(b, name0))
        {
            if (b.resolve("this")) |this_reg| {
                const dst = b.allocReg();
                const nm = try sgetterName(b, name0);
                try b.push(.{ .GetField = .{ .dst = dst, .receiver = this_reg, .field = nm } });
                return dst;
            }
            // Superclass-ctor delegation thunk: a bare own-member is a
            // companion access.
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
        // A bare reference to the enclosing type's own companion object
        // (`Key` inside `interface I { companion object Key; … = Key }`)
        // resolves to that companion singleton. Needed because a companion
        // that has a supertype (e.g. `companion object Key :
        // CoroutineContext.Key<I>`) is also registered as a classId under
        // its simple name, which would otherwise route the bare name to the
        // class reference below instead of the singleton. The owner is
        // loaded by its exact class id rather than re-resolving a
        // qualified `I.Key` path: inside the body of `interface Element :
        // CoroutineContext.Element` a bare `Element` head names the
        // inherited nested `CoroutineContext.Element`, not the enclosing
        // type itself.
        if (b.ownerClass()) |owner| {
            const comp_mangled: ?[]const u8 = b.module.registry.companion_singletons.get(owner);
            if (comp_mangled) |cm| {
                const simple = if (std.mem.lastIndexOfScalar(u8, cm, '$')) |i| cm[i + 1 ..] else cm;
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
        // Runtime-lowered anonymous-object bodies carry the exact classifier
        // identities visible at their lexical site. Their side modules do not
        // contain the program class index, so bind the classifier directly by
        // FQN after locals, captures, and receiver members have had priority.
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
        // A visible top-level `const val` outranks a class binding from a
        // less-visible scope: inside ScatterMap.kt the bare `Empty` is the
        // file's compile-time constant, never kotlinx-atomicfu's file-private
        // `object Empty` that shares the simple name in the flat class table.
        // Compare scope tiers and inline the literal when the constant wins
        // (Kotlin inlines const vals at every reference).
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
        // A NAMED companion-member import outranks a same-named class in
        // expression position (kotlinc: `import Layout.Companion.Marker`
        // binds the value `Marker` even when an `interface Marker` is in
        // scope — the classifier only matters in type position). Rewrite
        // to the qualified companion access before the class arm below
        // can capture the name.
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
        // A bare name that is a known class is a class reference. In a
        // receiver context a runtime receiver member shadows the
        // classifier (kotlinc: a property named like a class wins in
        // expression position), so the read decides at runtime with the
        // index-resolved class riding as the exact global arm; the
        // companion sentinel passes a member value through unchanged.
        // The flat `classId` is null when a same-simple-name class in another
        // package forced collision-mangling (both `gapbuffer` and `linkbuffer`
        // `InsertSlotsWithFixups` leave the simple name out of the index). An
        // explicit `import pkg.Outer.Name` in THIS file still names exactly one
        // of them, so treat the bare name as that class reference rather than
        // letting it fall to a by-name global read that binds first-registered.
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
        // A bare builtin type name used as a qualifier. Outside any
        // receiver context no member can shadow it, so the read is a
        // static global.
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
        // An imported member of a (possibly named) companion object →
        // rewrite to the qualified `C.MEMBER` companion access.
        if (b.resolve(name0) == null) {
            if (importCompanionRewrite(b, segments[0].span.file, name0)) |rw| {
                const sp = segments[0].span;
                const rsegs = try b.allocator.alloc(ast.Ident, rw.segs.len);
                for (rw.segs, 0..) |s, k| rsegs[k] = .{ .name = s, .span = sp };
                const qualified = Expr{ .Path = .{ .segments = rsegs, .span = sp } };
                return lowerExpr(b, &qualified);
            }
            // A member brought in bare by `import EnumOrObject.*`
            // (`import DurationUnit.*` → `MINUTES` == `DurationUnit.MINUTES`).
            // An implicit-receiver member shadows a star-import: a bare name
            // that is a member of `this` — or of any lexically enclosing
            // receiver, which is the case inside a lambda whose enclosing class
            // declares the name — resolves against that receiver, not the
            // star-imported class. `hasOwnMember` alone misses the lambda case
            // (a lambda body has no own class), so a bare `state` inside a
            // method's lambda was wrongly rewritten to `Enum.state`.
            // A same-scope top-level declaration also outranks a star-import:
            // a bare `STATE_COMPLETED` that names a top-level `val`/`fun` is
            // that declaration, not `Enum.STATE_COMPLETED` for some unrelated
            // `import Enum.*` whose enum does not even declare it (which would
            // wrongly qualify it onto the enum and read a bogus field).
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
        // A bare reference to a known top-level property is a global read
        // — unless a runtime implicit receiver could shadow it: kotlinc
        // resolves implicit-receiver members ahead of package-scope
        // properties, so where some class declares a member of this name
        // and a receiver is (or may be bound) in scope, the read decides
        // at runtime instead.
        // A class visible from this scope outranks a same-named top-level
        // property the file never imported (`E.serializer()` on a user
        // enum `E` is the class, never `kotlin.math.E`).
        // Only a REAL top-level property with a scope tier can lose to the
        // class; an `object` (published as a global, no property tier)
        // stays on the top-level path that loads its singleton.
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
            // Kotlin `const val` semantics: a reference to a visible
            // top-level compile-time constant inlines its literal value.
            // This also makes the read immune to the flat runtime global
            // table, where a same-simple-name value published by another
            // module can capture the name (androidx.collection's `Empty`
            // sentinel vs compose's `LocaleList.Empty`).
            if (b.module.topLevelConstLiteral(name0, b.self_package, segments[0].span.file)) |cv| {
                orEmitAudit(b, "top_level_prop", "ConstInline", name0);
                return try b.emitConst(cv);
            }
            // A bare read whose only declaration is an unimported
            // cross-package property is unresolved (kotlinc rejects it).
            if (b.module.topLevelPropFqn(name0)) |pfqn| {
                _ = try recordOutOfScopeRef(b, name0, segments[0].span, pfqn, b.module.topLevelPropRefTier(name0, b.self_package, segments[0].span.file));
            }
            orEmitAudit(b, "top_level_prop", "LoadGlobal", name0);
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
            return dst;
        }
        // Value-position bare reference to a top-level function, in a
        // context no receiver can shadow (no reachable `this`, no
        // enclosing member, no owner-class getter qualification): the
        // symbol index resolves it from the caller's scope and a unique
        // pick loads by exact FQN, so a same-simple-name function from
        // another package cannot swap in at runtime.
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
            // A bare name resolving to a known top-level fn is a
            // value-position function reference; skip the GetField shortcut.
            // A known top-level *property* skips it too: the shortcut's
            // lenient field resolution would adopt outer-chain members a
            // plain extension receiver does not lexically see — the
            // runtime walk below resolves member-vs-global with the right
            // receiver scope.
            const is_known_global =
                b.module.hasBareCallCandidate(name0, segments[0].span.file) or
                isTopLevelProp(name0);
            // A name declared only by an outer class must not become a plain
            // field read on the inner `this`. Defer it to the implicit-receiver
            // walk below, which carries the declaring class in the scoped
            // getter name. The same rule handles receiver lambdas, where the
            // innermost candidate may instead be a scope-function receiver.
            const enclosing_only_member = !b.hasOwnMember(name0) and b.hasEnclosingMember(name0);
            // Directly inside an inline extension splice the body was written
            // against the DECLARATION's scope, where the bound receiver's
            // members shadow any top-level candidate: `size == 0` in
            // IntArray.isEmpty means the receiver's size no matter what
            // same-named globals the CALLER's universe declares. The GetField
            // read keeps its runtime miss-fallback, so a spliced body whose
            // receiver lacks the name still reaches the global. A NESTED
            // lambda inside the splice is excluded — its bare names must keep
            // resolving against the runtime receiver walk (the
            // `setSpliceRecvTy` contract).
            // A SPLICED receiver lambda has no runtime closure: its receiver
            // exists only as the window's bound register, so the runtime
            // receiver walk the nested-lambda contract defers to cannot see
            // it. When the window head STATICALLY declares the name, the
            // member read wins here — a bare `parameters` inside
            // `URLBuilder(...).apply { … }` is the builder's property, never
            // the top-level `parameters(builder)` function value.
            const window_recv_declares = b.lambda_splice_resolve != null and
                // The head must describe the value actually BOUND as
                // `this` (the window's own subject). A member-inline
                // splice binds its OWNER while a nested plain-lambda
                // window carries the lambda's context head — pinning a
                // GetField on that mismatch read `currentGroup` off the
                // SlotTable instead of the writer.
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
            // ...unless the innermost receiver is statically the very class
            // the scoped getter names. A receiver lambda inside a COMPANION
            // binds `this` to the scope-function receiver
            // (`C(r).apply { raw }` in `C.Companion.mk`), and the deferred
            // walk cannot reach it: it rides the CAPTURE chain, which in a
            // companion function holds no `C` at all, so the read missed to
            // a global that does not exist. Where the receiver's class is
            // the declaring one, the field read on it is the answer.
            const receiver_is_owner = blk: {
                if (!enclosing_only_member) break :blk false;
                // The splice head may only vouch for the resolved `this`
                // when the window actually BOUND it (splice_recv_from_window)
                // — a bare member-inline splice binds nothing, so the ambient
                // `this` is whatever the enclosing lambda holds (a suspend
                // lambda's dispatch coroutine), and pinning a field read on
                // it with the OWNER's head read `job` off the runBlocking
                // coroutine instead of the enclosing class.
                const rh = (if (b.lambda_splice_resolve == null or b.splice_recv_from_window)
                    b.spliceRecvTy()
                else
                    null) orelse b.recvTy() orelse break :blk false;
                const decl_owner = sgetterOwner(b, name0) orelse break :blk false;
                const rhh = typeHead(std.mem.trimEnd(u8, rh, "?"));
                if (rhh.len == 0) break :blk false;
                if (b.module.classIsOrExtends(rhh, decl_owner)) break :blk true;
                // The declaring owner may carry a file-collision mangle
                // (`Operations$f429`) the receiver's SOURCE-spelled head
                // never does; compare the source names too.
                if (!inline_call.rfsEnabled()) break :blk false;
                break :blk std.mem.eql(u8, rhh, stripLowerFileMangle(decl_owner)) or
                    b.module.classIsOrExtends(rhh, stripLowerFileMangle(decl_owner));
            };
            // The EXTENSION receiver's own members shadow the enclosing
            // class's: inside `fun Scope.f()` declared in `class C`, a bare
            // name both `Scope` and `C` declare is `Scope`'s — kotlinc ranks
            // implicit receivers innermost first, and `this` is the receiver.
            // A smart-cast `this` (`when (this) { is ScatterSetWrapper<T> ->
            // set.forEach(block) }`) exposes the NARROWED class's members to
            // a bare read ahead of any same-named global: the name is that
            // class's property on `this`, never the top-level `set`.
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
                // The ambient `this` may be a spliced SUBJECT whose static
                // class does not declare the name (`descriptor` inside
                // `decoder.decodeStructure(descriptor) { … }`): kotlinc
                // ranks implicit receivers by static type, so the read
                // binds the innermost subject that declares it, else the
                // receiver beneath the subjects — never the runtime
                // object's same-named private field.
                const target = subjectCorrectedBareThis(b, name0, this_reg);
                try b.push(.{ .GetField = .{ .dst = dst, .receiver = target, .field = nm } });
                return dst;
            }
            // Inside a spliced receiver lambda whose subject's STATIC class
            // does not declare the name, the enclosing class's member is
            // the binding — kotlinc ranks implicit receivers by their
            // static types, never by what the runtime object happens to
            // hold (`descriptor` inside `decoder.decodeStructure(...) { }`
            // is the serializer's, not the decoder's private field).
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
        // Outside any receiver context no member can shadow the name, so
        // the read is a static global (kotlinc rejects resolving it
        // against a caller's receiver).
        if (!inReceiverContext(b)) {
            orEmitAudit(b, "bare_name_fallthrough", "LoadGlobal", name0);
            const dst = b.allocReg();
            // A RENAMED import binds this spelling to another declaration
            // (`import kotlin.coroutines.coroutineContext as currentContext`).
            // A call and a classifier already resolve through the alias; a
            // bare PROPERTY read reached the runtime as the spelled name and
            // found nothing. Resolve it at the emission only, so the spelling
            // the source wrote is what every diagnostic still reports.
            const nm = try b.module.internConst(b.allocator, .{ .String = name0 });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = nm } });
            return dst;
        }
        const this_idx = try b.recordCapture("this");
        const dst = b.allocReg();
        const name = try sgetterName(b, name0);
        // The index's unique pick rides as the exact global arm; the
        // runtime member probe still runs first, and a runtime-scoped
        // shadowing capture re-routes to the name lookup.
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
        // The const pool stores the slice by reference, so the joined FQN
        // must live for the module's lifetime — let the module allocator
        // own it rather than freeing it here.
        const fqn = try joinSegments(b.allocator, segments);
        // Ride the exact class id of the longest FQN prefix that names a class
        // so the runtime binds that declaration rather than re-resolving the
        // tail by simple name (two packages with a same-simple-name
        // `Operation.Ins` would otherwise both bind the first-registered one).
        if (try emitFqnWithClassPrefix(b, fqn)) |r| return r;
        const dst = b.allocReg();
        const n = try b.module.internConst(b.allocator, .{ .String = fqn });
        try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
        // A fully-qualified class-with-companion in value position resolves to
        // its companion singleton (Kotlin: `C` yields `C.Companion`), the same
        // forwarding the bare-name arm applies. Without it `pkg.C` loaded the
        // class value while bare `C` loaded the companion, so `pkg.C === C`
        // was false and `context[ContinuationInterceptor]` (an interface with a
        // named companion Key) missed the dispatcher element. The
        // `<class-companion-or-self>` sentinel returns the companion when one
        // exists and the class/object value otherwise, so a plain object or a
        // companion-less class is unaffected.
        const fqn_simple = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
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
        // Unresolved head: route through `this` / the enclosing receiver.
        // A head naming a known class carries the index-resolved class as
        // the exact global arm (a runtime receiver member still shadows
        // it, innermost first).
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

/// The nearest lexical class whose hierarchy declares `name`. A lambda keeps
/// its enclosing class as `ownerClass`, while a lifted inner class reaches its
/// outer classes through `enclosing_class`; consulting both gives a scoped
/// getter the class that actually contributes the bare property.
/// The source-level name behind a file-collision mangle (`X$f12` -> `X`).
pub fn stripLowerFileMangle(n: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, n, '$') orelse return n;
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

/// Intern the scope-qualified getter field name `$sgetter$<owner>\u{1f}<name>`
/// when an enclosing class is known, else the plain name.
fn sgetterName(b: *FuncBuilder, name: []const u8) Allocator.Error!ConstId {
    if (sgetterOwner(b, name)) |owner| {
        // The const pool stores the slice by reference, so the buffer must
        // live for the module's lifetime — let the module allocator own it
        // rather than freeing it here (which would leave a dangling field
        // name read back at dispatch time).
        const qual = try std.fmt.allocPrint(b.allocator, "$sgetter${s}\u{1f}{s}", .{ owner, name });
        return b.module.internConst(b.allocator, .{ .String = qual });
    }
    return b.module.internConst(b.allocator, .{ .String = name });
}

pub const ImportRewrite = struct { segs: []const []const u8 };

/// Resolve a bare name imported via `import a.b.C…MEMBER` into the qualified
/// access path starting at the rightmost segment naming a class this module
/// declares (dropping the leading package). Intermediate segments between the
/// class and the member are preserved (`import Outer.State.Idle` → the nested
/// `Outer.State.Idle`), EXCEPT an explicit `Companion` hop, which is dropped
/// because a companion member is reached through the class itself
/// (`import X.Companion.member` → `X.member`). Returns null when the path names
/// no declared class, or the class is the leaf (a bare type reference).
pub fn importCompanionRewrite(b: *FuncBuilder, file: ir.FileId, name: []const u8) ?ImportRewrite {
    const segs = b.module.importAliasIn(file, name) orelse return null;
    // Find the rightmost segment naming a class the module declares (skips the
    // leading package), then extend left across any enclosing-class chain so the
    // path starts at the OUTERMOST (top-level, globally loadable) class — a bare
    // nested class name (`LayoutState`) is not itself loadable, but the qualified
    // `Outer.LayoutState.Idle` resolves the nested classifier then the entry.
    // The scan excludes the LEAF segment: the leaf is the imported member,
    // and a same-named CLASS elsewhere in scope must not capture it —
    // `import Layout.Companion.Marker` next to an `interface Marker` still
    // rewrites to `Layout.Marker`. (A bare `import a.b.SomeClass` type
    // reference has no member segment and simply finds no class here.)
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

    // Keep the leading package segments when the class named by the import's
    // FQN is NOT the one its simple name resolves to in the flat class index
    // — either the simple name was collision-mangled out (two packages declare
    // a same-simple-name nested member, gapbuffer vs linkbuffer `Operation`)
    // or it resolves to a different, first-registered declaration. Dropping the
    // package would bind that wrong one; the full `pkg.Outer.Member` path
    // resolves the exact declaration the import named.
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
        // Drop an intermediate `Companion` hop — `X.member` resolves the
        // companion member — but keep a nested classifier (`Outer.State`).
        if (j != last and std.mem.eql(u8, segs[j], "Companion")) continue;
        out[n] = segs[j];
        n += 1;
    }
    return .{ .segs = out[0..n] };
}

/// A bare name brought into scope by `import EnumOrObject.*` resolves to that
/// class's member (`import DurationUnit.*` makes `MINUTES` mean
/// `DurationUnit.MINUTES`). Returns the simple class name to qualify with, or
/// null when no wildcard import targets a declared class with this surface.
/// The runtime `GetField` resolves the enum entry / companion member exactly as
/// it does for the written-out `Class.name`.
fn wildcardClassMemberRewrite(b: *FuncBuilder, file: ir.FileId) ?[]const u8 {
    const list = b.module.registry.import_wildcards.get(file) orelse return null;
    for (list.items) |path| {
        // The wildcard target names a class (enum / object) rather than a
        // package: its members are visible under their bare names. Match the
        // full FQN first, then the simple tail.
        if (b.module.classIdByFqn(path) != null) return lastPathSegment(path);
        const tail = lastPathSegment(path);
        if (b.module.classId(tail) != null) return tail;
    }
    return null;
}

fn lastPathSegment(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| return path[dot + 1 ..];
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
    // `$this` denotes the receiver itself — `this` is a keyword, never a
    // member or global name — so it lowers exactly like a bare `this`
    // expression: the bound `this`, or the captured slot in a lambda body.
    if (std.mem.eql(u8, ident.name, "this")) {
        if (b.resolve("this")) |r| return r;
        return b.loadCaptureHoisted("this");
    }
    // `"… $x …"` where `x` is a `var x by D` local reads THROUGH the delegate,
    // exactly as a bare `x` does.
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
    // A renamed file-private top-level property (`"$prefix.Derived"` beside
    // another file's same-named private `prefix`) reads its per-file mangled
    // global exactly as a bare reference does.
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
