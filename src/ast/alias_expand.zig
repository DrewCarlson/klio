//! Typealias expansion: a `typealias` is transparent in Kotlin, so this pass
//! rewrites every reference to the aliased type, with type parameters
//! substituted, before lowering. It covers type positions, constructor calls,
//! value positions (`Alias.member` for an alias of an object) and callable
//! references.
//!
//! Name resolution follows Kotlin scoping: enclosing class bodies, explicit
//! imports, the file's own package (a private alias only within its own file),
//! then star imports. An alias's target resolves in the scope of its
//! declaration, so the declaring file's imports govern the name. A name the
//! program also declares as a classifier, function or value is left to
//! lowering's scope model.

const std = @import("std");
const ast = @import("ast.zig");
const span_mod = @import("span");
const Allocator = std.mem.Allocator;
const Span = span_mod.Span;
const Expr = ast.Expr;
const Decl = ast.Decl;
const Stmt = ast.Stmt;
const Block = ast.Block;
const TypeRef = ast.TypeRef;
const TypeArg = ast.TypeArg;
const Ident = ast.Ident;
const KotlinFile = ast.KotlinFile;

const Alias = struct {
    name: []const u8,
    type_params: []const []const u8,
    target: *const TypeRef,
    file: usize,
    pkg: []const u8,
    /// Dotted path of the declaring class; empty for a top-level alias.
    owner: []const u8,
    fqn: []const u8,
    private: bool,
};

const ClassInfo = struct {
    path: []const u8,
    pkg: []const u8,
    is_inner: bool,
};

const Index = struct {
    a: Allocator,
    files: []const KotlinFile,
    file_pkgs: [][]const u8,
    aliases: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Alias)) = .empty,
    classes: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(ClassInfo)) = .empty,
    /// Simple names the program declares as something other than an alias.
    blocked: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *Index) void {
        var ait = self.aliases.valueIterator();
        while (ait.next()) |l| l.deinit(self.a);
        self.aliases.deinit(self.a);
        var cit = self.classes.valueIterator();
        while (cit.next()) |l| l.deinit(self.a);
        self.classes.deinit(self.a);
        self.blocked.deinit(self.a);
        self.a.free(self.file_pkgs);
    }

    fn addAlias(self: *Index, al: Alias) Allocator.Error!void {
        const gop = try self.aliases.getOrPut(self.a, al.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.a, al);
    }

    fn addClass(self: *Index, name: []const u8, info: ClassInfo) Allocator.Error!void {
        const gop = try self.classes.getOrPut(self.a, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.a, info);
    }

    fn block(self: *Index, name: []const u8) Allocator.Error!void {
        try self.blocked.put(self.a, name, {});
    }

    fn classIsInner(self: *const Index, pkg: []const u8, path: []const u8) bool {
        const simple = lastSegment(path);
        const list = self.classes.get(simple) orelse return false;
        for (list.items) |info| {
            if (!info.is_inner) continue;
            if (std.mem.eql(u8, info.path, path)) return true;
            if (std.mem.eql(u8, info.pkg, pkg) and std.mem.endsWith(u8, info.path, path) and
                (info.path.len == path.len or info.path[info.path.len - path.len - 1] == '.'))
            {
                return true;
            }
        }
        return false;
    }
};

fn lastSegment(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| return path[dot + 1 ..];
    return path;
}

fn joinPath(a: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    for (parts) |p| {
        if (p.len == 0) continue;
        if (out.items.len != 0) try out.append(a, '.');
        try out.appendSlice(a, p);
    }
    return out.toOwnedSlice(a);
}

fn joinIdents(a: Allocator, idents: []const Ident) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    for (idents, 0..) |id, i| {
        if (i != 0) try out.append(a, '.');
        try out.appendSlice(a, id.name);
    }
    return out.toOwnedSlice(a);
}

fn packageOf(a: Allocator, f: *const KotlinFile) Allocator.Error![]const u8 {
    const pkg = f.package orelse return "";
    return joinIdents(a, pkg.path);
}

/// A package of the shipped stdlib or a library pack, not of the program.
fn shippedPackage(pkg: []const u8) bool {
    for ([_][]const u8{ "kotlin", "kotlinx", "androidx", "io.ktor", "org.jetbrains" }) |root| {
        if (std.mem.eql(u8, pkg, root)) return true;
        if (pkg.len > root.len and std.mem.startsWith(u8, pkg, root) and pkg[root.len] == '.') return true;
    }
    return false;
}

pub fn expandFiles(a: Allocator, files: []const KotlinFile) Allocator.Error!void {
    var any = false;
    for (files) |*f| {
        if (declsDeclareAlias(f.decls)) {
            any = true;
            break;
        }
    }
    if (!any) return;

    var idx = Index{ .a = a, .files = files, .file_pkgs = try a.alloc([]const u8, files.len) };
    defer idx.deinit();
    for (files, 0..) |*f, i| idx.file_pkgs[i] = try packageOf(a, f);
    for (files, 0..) |*f, i| try collectDecls(&idx, f.decls, "", idx.file_pkgs[i], i);
    if (idx.aliases.count() == 0) return;
    {
        var collector = Walker{ .idx = &idx, .a = a, .mode = .collect, .file = 0, .pkg = "", .imports = &.{} };
        defer collector.deinit();
        for (files, 0..) |*f, i| {
            if (shippedPackage(idx.file_pkgs[i])) continue;
            collector.file = i;
            collector.pkg = idx.file_pkgs[i];
            collector.imports = f.imports;
            for (f.decls) |*d| try collector.walkDecl(d);
        }
    }
    var w = Walker{ .idx = &idx, .a = a, .mode = .rewrite, .file = 0, .pkg = "", .imports = &.{} };
    defer w.deinit();
    for (files, 0..) |*f, i| {
        // A shipped library keeps its source spelling, its aliases still
        // collected so a program using them expands them, because a library's
        // private extension on an aliased scalar resolves by the alias head.
        if (shippedPackage(idx.file_pkgs[i])) continue;
        w.file = i;
        w.pkg = idx.file_pkgs[i];
        w.imports = f.imports;
        for (f.decls) |*d| try w.walkDecl(d);
    }
}

fn declsDeclareAlias(decls: []const Decl) bool {
    for (decls) |*d| {
        switch (d.*) {
            .TypeAlias => return true,
            .Class => |*c| if (declsDeclareAlias(c.members)) return true,
            .Object => |*o| if (declsDeclareAlias(o.members)) return true,
            else => {},
        }
    }
    return false;
}

fn collectDecls(idx: *Index, decls: []const Decl, owner: []const u8, pkg: []const u8, file: usize) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .TypeAlias => |*ta| {
                const params = try idx.a.alloc([]const u8, ta.type_params.len);
                for (ta.type_params, params) |*tp, *out| out.* = tp.name.name;
                try idx.addAlias(.{
                    .name = ta.name.name,
                    .type_params = params,
                    .target = &ta.target,
                    .file = file,
                    .pkg = pkg,
                    .owner = owner,
                    .fqn = try joinPath(idx.a, &.{ pkg, owner, ta.name.name }),
                    .private = ta.visibility == .Private,
                });
            },
            .Class => |*c| {
                const path = try joinPath(idx.a, &.{ owner, c.name.name });
                try idx.addClass(c.name.name, .{ .path = path, .pkg = pkg, .is_inner = c.is_inner });
                try idx.block(c.name.name);
                for (c.enum_entries) |*e| {
                    try idx.block(e.name.name);
                    try collectDecls(idx, e.body_members, path, pkg, file);
                }
                try collectDecls(idx, c.members, path, pkg, file);
            },
            .Object => |*o| {
                const path = try joinPath(idx.a, &.{ owner, o.name.name });
                try idx.addClass(o.name.name, .{ .path = path, .pkg = pkg, .is_inner = false });
                try idx.block(o.name.name);
                try collectDecls(idx, o.members, path, pkg, file);
            },
            .Function => |*f| try idx.block(f.name.name),
            .Property => |p| try idx.block(p.name.name),
        }
    }
}

const Mode = enum { collect, rewrite };

const Walker = struct {
    idx: *Index,
    a: Allocator,
    mode: Mode,
    file: usize,
    pkg: []const u8,
    imports: []const ast.ImportDecl,
    /// Dotted paths of the lexically enclosing classes, innermost last.
    class_stack: std.ArrayListUnmanaged([]const u8) = .empty,
    type_params: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(w: *Walker) void {
        for (w.class_stack.items) |p| w.a.free(p);
        w.class_stack.deinit(w.a);
        w.type_params.deinit(w.a);
    }

    fn declare(w: *Walker, name: []const u8) Allocator.Error!void {
        if (w.mode == .collect) try w.idx.block(name);
    }

    fn typeParamInScope(w: *const Walker, name: []const u8) bool {
        for (w.type_params.items) |tp| if (std.mem.eql(u8, tp, name)) return true;
        return false;
    }

    fn pushTypeParams(w: *Walker, params: []const ast.TypeParam) Allocator.Error!usize {
        const mark = w.type_params.items.len;
        for (params) |*tp| try w.type_params.append(w.a, tp.name.name);
        return mark;
    }

    fn popTypeParams(w: *Walker, mark: usize) void {
        w.type_params.shrinkRetainingCapacity(mark);
    }

    fn pushClass(w: *Walker, name: []const u8) Allocator.Error!void {
        const parent = if (w.class_stack.items.len != 0) w.class_stack.items[w.class_stack.items.len - 1] else "";
        try w.class_stack.append(w.a, try joinPath(w.a, &.{ parent, name }));
    }

    fn popClass(w: *Walker) void {
        const p = w.class_stack.pop().?;
        w.a.free(p);
    }

    fn packageVisible(w: *const Walker, pkg: []const u8, head: []const u8) bool {
        if (std.mem.eql(u8, pkg, w.pkg)) return true;
        for (w.imports) |imp| {
            if (imp.path.len == 0) continue;
            if (imp.wildcard) {
                if (identPathEql(imp.path, pkg)) return true;
                continue;
            }
            if (imp.path.len < 2) continue;
            const leaf = imp.path[imp.path.len - 1].name;
            if (!std.mem.eql(u8, leaf, head)) continue;
            if (identPathEqlPrefix(imp.path[0 .. imp.path.len - 1], pkg)) return true;
        }
        return false;
    }

    fn findAlias(w: *const Walker, name: []const u8) ?Alias {
        if (w.typeParamInScope(name)) return null;
        if (w.idx.blocked.contains(name)) return null;
        const list = w.idx.aliases.get(name) orelse return null;
        const cands = list.items;
        var depth = w.class_stack.items.len;
        while (depth > 0) {
            depth -= 1;
            const path = w.class_stack.items[depth];
            for (cands) |al| {
                if (al.owner.len != 0 and std.mem.eql(u8, al.owner, path) and std.mem.eql(u8, al.pkg, w.pkg)) return al;
            }
        }
        var found: ?Alias = null;
        var ambiguous = false;
        for (w.imports) |imp| {
            if (imp.wildcard or imp.path.len == 0) continue;
            const visible = if (imp.alias) |al| al.name else imp.path[imp.path.len - 1].name;
            if (!std.mem.eql(u8, visible, name)) continue;
            for (cands) |al| {
                if (!identPathEql(imp.path, al.fqn)) continue;
                if (found != null and !std.mem.eql(u8, found.?.fqn, al.fqn)) ambiguous = true;
                found = al;
            }
        }
        if (ambiguous) return null;
        if (found) |al| return al;
        for (cands) |al| {
            if (al.owner.len != 0 or !std.mem.eql(u8, al.pkg, w.pkg)) continue;
            if (al.private and al.file != w.file) continue;
            if (found != null) return null;
            found = al;
        }
        if (found) |al| return al;
        for (w.imports) |imp| {
            if (!imp.wildcard) continue;
            for (cands) |al| {
                if (al.owner.len != 0 or al.private) continue;
                if (!identPathEql(imp.path, al.pkg)) continue;
                if (found != null and !std.mem.eql(u8, found.?.fqn, al.fqn)) return null;
                found = al;
            }
        }
        return found;
    }

    /// Fully qualified, class-qualified (`Owner.Alias`), or relative to an enclosing class body.
    fn findAliasByPath(w: *const Walker, path: []const u8) ?Alias {
        const name = lastSegment(path);
        if (name.len == path.len) return w.findAlias(name);
        if (w.idx.blocked.contains(name)) return null;
        const list = w.idx.aliases.get(name) orelse return null;
        for (list.items) |al| {
            if (std.mem.eql(u8, al.fqn, path)) return al;
            if (al.owner.len == 0) continue;
            if (pathEndsWith(al.fqn, path)) {
                // `Owner.Alias` relative to the package: the owner class must be visible here.
                const rel = al.fqn[al.fqn.len - path.len ..];
                const head = rel[0 .. std.mem.indexOfScalar(u8, rel, '.') orelse rel.len];
                if (al.pkg.len == 0 or al.fqn.len == path.len or w.packageVisible(al.pkg, head)) return al;
            }
            for (w.class_stack.items) |encl| {
                if (!std.mem.eql(u8, al.pkg, w.pkg)) continue;
                if (std.mem.eql(u8, al.owner, encl)) continue;
                if (std.mem.startsWith(u8, al.owner, encl) and al.owner.len > encl.len and al.owner[encl.len] == '.' and
                    std.mem.eql(u8, al.owner[encl.len + 1 ..], path[0 .. path.len - name.len - 1]))
                {
                    return al;
                }
            }
        }
        return null;
    }

    fn pathEndsWith(fqn: []const u8, path: []const u8) bool {
        if (fqn.len < path.len) return false;
        if (!std.mem.endsWith(u8, fqn, path)) return false;
        return fqn.len == path.len or fqn[fqn.len - path.len - 1] == '.';
    }

    fn identPathEql(idents: []const Ident, dotted: []const u8) bool {
        var pos: usize = 0;
        for (idents, 0..) |id, i| {
            if (i != 0) {
                if (pos >= dotted.len or dotted[pos] != '.') return false;
                pos += 1;
            }
            if (!std.mem.startsWith(u8, dotted[pos..], id.name)) return false;
            pos += id.name.len;
        }
        return pos == dotted.len;
    }

    fn identPathEqlPrefix(idents: []const Ident, dotted: []const u8) bool {
        return identPathEql(idents, dotted);
    }

    /// Its declaring file and class body, with no type parameters of the use site in view.
    fn declScope(w: *const Walker, al: Alias) Allocator.Error!Walker {
        var s = Walker{
            .idx = w.idx,
            .a = w.a,
            .mode = .rewrite,
            .file = al.file,
            .pkg = al.pkg,
            .imports = w.idx.files[al.file].imports,
        };
        errdefer s.deinit();
        var it = std.mem.splitScalar(u8, al.owner, '.');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            try s.pushClass(seg);
        }
        return s;
    }

    const Expanded = struct {
        ty: TypeRef,
        /// The alias is generic and the use site gave no arguments, so every
        /// parameter position became a star projection.
        inferred: bool,
    };

    /// `null` when the argument count does not fit, or the target is a bare
    /// parameter the use site leaves unbound.
    fn expandAlias(w: *Walker, al: Alias, args: []const TypeArg, use_span: Span) Allocator.Error!?Expanded {
        if (args.len != 0 and args.len != al.type_params.len) return null;
        const inferred = args.len == 0 and al.type_params.len != 0;
        if (al.target.function == null and al.target.qualified_path == null and al.target.type_args.len == 0) {
            if (paramIndex(al, al.target.name.name)) |i| {
                if (inferred or args[i].is_star) return null;
                var out = try cloneType(w.a, &args[i].ty);
                out.nullable = out.nullable or al.target.nullable;
                return .{ .ty = out, .inferred = false };
            }
        }
        var out = try substituteType(w.a, al, al.target, args);
        var scope = try w.declScope(al);
        defer scope.deinit();
        _ = try scope.expandType(&out, 1);
        _ = use_span;
        return .{ .ty = out, .inferred = inferred };
    }

    fn paramIndex(al: Alias, name: []const u8) ?usize {
        for (al.type_params, 0..) |p, i| if (std.mem.eql(u8, p, name)) return i;
        return null;
    }

    fn substituteType(a: Allocator, al: Alias, ty: *const TypeRef, args: []const TypeArg) Allocator.Error!TypeRef {
        var out = ty.*;
        if (ty.function) |ft| {
            const nf = try a.create(ast.FunctionTypeRef);
            nf.* = ft.*;
            if (ft.receiver) |*r| nf.receiver = try substituteType(a, al, r, args);
            nf.params = try a.alloc(TypeRef, ft.params.len);
            for (ft.params, nf.params) |*p, *o| o.* = try substituteType(a, al, p, args);
            nf.ret = try substituteType(a, al, &ft.ret, args);
            nf.context_params = try a.alloc(TypeRef, ft.context_params.len);
            for (ft.context_params, nf.context_params) |*p, *o| o.* = try substituteType(a, al, p, args);
            out.function = nf;
            return out;
        }
        if (ty.qualified_path == null and ty.type_args.len == 0) {
            if (paramIndex(al, ty.name.name)) |i| {
                if (i < args.len and !args[i].is_star) {
                    var sub = try cloneType(a, &args[i].ty);
                    sub.nullable = sub.nullable or ty.nullable;
                    sub.definitely_non_null = sub.definitely_non_null or ty.definitely_non_null;
                    if (ty.annotations.len != 0) sub.annotations = ty.annotations;
                    return sub;
                }
                // Unbound: keep the parameter name; the enclosing type argument
                // becomes a star projection below.
                return out;
            }
        }
        out.type_args = try a.alloc(TypeArg, ty.type_args.len);
        for (ty.type_args, out.type_args) |*ta, *o| {
            o.* = ta.*;
            if (ta.is_star) continue;
            const bare = ta.ty.function == null and ta.ty.qualified_path == null and ta.ty.type_args.len == 0;
            if (bare) {
                if (paramIndex(al, ta.ty.name.name)) |i| {
                    if (i >= args.len or args[i].is_star) {
                        o.is_star = true;
                        continue;
                    }
                    if (args[i].variance != .Invariant and ta.variance == .Invariant) o.variance = args[i].variance;
                }
            }
            o.ty = try substituteType(a, al, &ta.ty, args);
        }
        return out;
    }

    fn cloneType(a: Allocator, ty: *const TypeRef) Allocator.Error!TypeRef {
        var out = ty.*;
        if (ty.function) |ft| {
            const nf = try a.create(ast.FunctionTypeRef);
            nf.* = ft.*;
            if (ft.receiver) |*r| nf.receiver = try cloneType(a, r);
            nf.params = try a.alloc(TypeRef, ft.params.len);
            for (ft.params, nf.params) |*p, *o| o.* = try cloneType(a, p);
            nf.ret = try cloneType(a, &ft.ret);
            nf.context_params = try a.alloc(TypeRef, ft.context_params.len);
            for (ft.context_params, nf.context_params) |*p, *o| o.* = try cloneType(a, p);
            out.function = nf;
            return out;
        }
        out.type_args = try a.alloc(TypeArg, ty.type_args.len);
        for (ty.type_args, out.type_args) |*ta, *o| {
            o.* = ta.*;
            if (!ta.is_star) o.ty = try cloneType(a, &ta.ty);
        }
        return out;
    }

    /// Type arguments are expanded first, so the substituted target carries expanded arguments.
    fn expandType(w: *Walker, ty: *TypeRef, depth: u8) Allocator.Error!bool {
        if (ty.function) |ft| {
            if (ft.receiver) |*r| _ = try w.expandType(r, depth);
            for (ft.params) |*p| _ = try w.expandType(p, depth);
            _ = try w.expandType(&ft.ret, depth);
            for (ft.context_params) |*p| _ = try w.expandType(p, depth);
            return false;
        }
        for (ty.type_args) |*ta| {
            if (!ta.is_star) _ = try w.expandType(&ta.ty, depth);
        }
        if (w.mode != .rewrite or depth > 16) return false;
        const al = (if (ty.qualified_path) |qp| w.findAliasByPath(qp) else w.findAlias(ty.name.name)) orelse return false;
        const expanded = (try w.expandAlias(al, ty.type_args, ty.span)) orelse return false;
        var out = expanded.ty;
        out.nullable = out.nullable or ty.nullable;
        out.definitely_non_null = out.definitely_non_null or ty.definitely_non_null;
        if (ty.annotations.len != 0) {
            if (out.annotations.len == 0) {
                out.annotations = ty.annotations;
            } else {
                const merged = try w.a.alloc(ast.Annotation, ty.annotations.len + out.annotations.len);
                @memcpy(merged[0..ty.annotations.len], ty.annotations);
                @memcpy(merged[ty.annotations.len..], out.annotations);
                out.annotations = merged;
            }
        }
        ty.* = out;
        return true;
    }

    /// Path segments naming the expanded target's classifier. An inner class
    /// collapses to its own name: its outer part is the receiver, never a path
    /// prefix.
    fn targetSegments(w: *Walker, al: Alias, target: *const TypeRef, collapse_inner: bool) Allocator.Error![]Ident {
        const path = target.qualified_path orelse target.name.name;
        if (collapse_inner and target.qualified_path != null and w.idx.classIsInner(al.pkg, path)) {
            const segs = try w.a.alloc(Ident, 1);
            segs[0] = .{ .name = target.name.name, .span = target.name.span };
            return segs;
        }
        var count: usize = 1;
        for (path) |ch| if (ch == '.') {
            count += 1;
        };
        const segs = try w.a.alloc(Ident, count);
        var it = std.mem.splitScalar(u8, path, '.');
        var i: usize = 0;
        while (it.next()) |seg| : (i += 1) segs[i] = .{ .name = seg, .span = target.name.span };
        return segs;
    }

    fn callTypeArgs(w: *Walker, expanded: Expanded) Allocator.Error![]TypeRef {
        if (expanded.inferred) return &.{};
        for (expanded.ty.type_args) |*ta| if (ta.is_star) return &.{};
        const out = try w.a.alloc(TypeRef, expanded.ty.type_args.len);
        for (expanded.ty.type_args, out) |*ta, *o| o.* = ta.ty;
        return out;
    }

    /// `Alias(args)`: the aliased constructor, with the type arguments mapped.
    fn rewriteCalleePath(w: *Walker, c: anytype, p: anytype) Allocator.Error!bool {
        const al: Alias = if (p.segments.len == 1)
            w.findAlias(p.segments[0].name) orelse return false
        else blk: {
            const path = try joinIdents(w.a, p.segments);
            defer w.a.free(path);
            break :blk w.findAliasByPath(path) orelse return false;
        };
        const args = try typeRefsAsArgs(w.a, c.type_args);
        const expanded = (try w.expandAlias(al, args, p.span)) orelse return false;
        if (expanded.ty.function != null) return false;
        if (expanded.ty.qualified_path == null and w.typeParamInScope(expanded.ty.name.name)) return false;
        p.segments = try w.targetSegments(al, &expanded.ty, true);
        c.type_args = try w.callTypeArgs(expanded);
        return true;
    }

    /// An alias of an inner or nested class constructed through the receiver
    /// takes the target's own name.
    fn rewriteCalleeMember(w: *Walker, c: anytype, m: anytype) Allocator.Error!void {
        const al = w.findAlias(m.name.name) orelse return;
        const args = try typeRefsAsArgs(w.a, c.type_args);
        const expanded = (try w.expandAlias(al, args, m.name.span)) orelse return;
        if (expanded.ty.function != null or expanded.ty.qualified_path == null) return;
        m.name = .{ .name = expanded.ty.name.name, .span = expanded.ty.name.span };
        c.type_args = try w.callTypeArgs(expanded);
    }

    fn typeRefsAsArgs(a: Allocator, refs: []const TypeRef) Allocator.Error![]TypeArg {
        const out = try a.alloc(TypeArg, refs.len);
        for (refs, out) |*r, *o| o.* = .{ .variance = .Invariant, .is_star = false, .ty = r.*, .span = r.span };
        return out;
    }

    /// `Alias.member` or bare `Alias`: an alias of an object denotes it.
    fn rewritePath(w: *Walker, p: anytype) Allocator.Error!void {
        var consumed: usize = 0;
        var al: ?Alias = null;
        if (p.segments.len >= 2) {
            const two = try joinIdents(w.a, p.segments[0..2]);
            defer w.a.free(two);
            if (w.findAliasByPath(two)) |found| {
                if (found.owner.len != 0) {
                    al = found;
                    consumed = 2;
                }
            }
        }
        if (al == null) {
            al = w.findAlias(p.segments[0].name) orelse return;
            consumed = 1;
        }
        const alias = al.?;
        if (alias.type_params.len != 0) return;
        const expanded = (try w.expandAlias(alias, &.{}, p.span)) orelse return;
        if (expanded.ty.function != null or expanded.ty.type_args.len != 0) return;
        const head = try w.targetSegments(alias, &expanded.ty, false);
        const rest = p.segments[consumed..];
        const segs = try w.a.alloc(Ident, head.len + rest.len);
        @memcpy(segs[0..head.len], head);
        @memcpy(segs[head.len..], rest);
        p.segments = segs;
    }

    /// `::Alias` / `Recv::Alias`: a reference to the aliased constructor.
    fn rewriteRefName(w: *Walker, name: *Ident) Allocator.Error!void {
        const al = w.findAlias(name.name) orelse return;
        const expanded = (try w.expandAlias(al, &.{}, name.span)) orelse return;
        if (expanded.ty.function != null) return;
        name.* = .{ .name = expanded.ty.name.name, .span = expanded.ty.name.span };
    }

    fn walkType(w: *Walker, ty: *TypeRef) Allocator.Error!void {
        _ = try w.expandType(ty, 0);
    }

    fn walkOptType(w: *Walker, ty: *?TypeRef) Allocator.Error!void {
        if (ty.*) |*t| try w.walkType(t);
    }

    fn walkTypeParams(w: *Walker, params: []ast.TypeParam) Allocator.Error!void {
        for (params) |*tp| try w.walkOptType(&tp.upper_bound);
    }

    fn walkWhereBounds(w: *Walker, bounds: []ast.WhereBound) Allocator.Error!void {
        for (bounds) |*b| try w.walkType(&b.bound);
    }

    fn walkParams(w: *Walker, params: []ast.Param) Allocator.Error!void {
        for (params) |*p| {
            try w.declare(p.name.name);
            try w.walkType(&p.ty);
            if (p.default) |d| try w.walkExpr(d);
        }
    }

    fn walkContextParams(w: *Walker, params: []ast.ContextParam) Allocator.Error!void {
        for (params) |*cp| {
            try w.declare(cp.name.name);
            try w.walkType(&cp.ty);
        }
    }

    fn walkBody(w: *Walker, body: *ast.FunctionBody) Allocator.Error!void {
        switch (body.*) {
            .Block => |*b| try w.walkBlock(b),
            .Expr => |*e| try w.walkExpr(e),
        }
    }

    fn walkAccessor(w: *Walker, acc: *ast.Accessor) Allocator.Error!void {
        for (acc.params) |p| try w.declare(p.name);
        try w.walkOptType(&acc.return_type);
        try w.walkBody(&acc.body);
    }

    fn walkSupertypes(w: *Walker, types: []TypeRef, args: []?[]Expr, delegates: []?Expr) Allocator.Error!void {
        for (types) |*t| try w.walkType(t);
        for (args) |maybe| {
            if (maybe) |list| for (list) |*e| try w.walkExpr(e);
        }
        for (delegates) |*maybe| {
            if (maybe.*) |*e| try w.walkExpr(e);
        }
    }

    fn walkDecl(w: *Walker, d: *Decl) Allocator.Error!void {
        switch (d.*) {
            .Function => |*f| {
                try w.declare(f.name.name);
                const mark = try w.pushTypeParams(f.type_params);
                defer w.popTypeParams(mark);
                try w.walkTypeParams(f.type_params);
                try w.walkWhereBounds(f.where_bounds);
                try w.walkOptType(&f.receiver_type);
                try w.walkContextParams(f.context_params);
                try w.walkParams(f.params);
                try w.walkOptType(&f.return_type);
                if (f.body) |*b| try w.walkBody(b);
            },
            .Property => |p| {
                try w.declare(p.name.name);
                try w.walkContextParams(p.context_params);
                try w.walkOptType(&p.receiver_type);
                try w.walkOptType(&p.ty);
                if (p.init) |*e| try w.walkExpr(e);
                if (p.delegate) |e| try w.walkExpr(e);
                if (p.getter) |g| try w.walkAccessor(g);
                if (p.setter) |s| try w.walkAccessor(s);
                if (p.explicit_field) |ef| {
                    try w.walkOptType(&ef.ty);
                    if (ef.init) |*e| try w.walkExpr(e);
                }
            },
            .Class => |*c| {
                try w.declare(c.name.name);
                const mark = try w.pushTypeParams(c.type_params);
                defer w.popTypeParams(mark);
                try w.walkTypeParams(c.type_params);
                try w.walkWhereBounds(c.where_bounds);
                try w.pushClass(c.name.name);
                defer w.popClass();
                for (c.primary_params) |*p| {
                    try w.declare(p.name.name);
                    try w.walkType(&p.ty);
                    if (p.default) |*e| try w.walkExpr(e);
                }
                try w.walkSupertypes(c.supertypes, c.supertype_args, c.supertype_delegates);
                for (c.init_blocks) |*b| try w.walkBlock(b);
                for (c.secondary_ctors) |*sc| {
                    try w.walkParams(sc.params);
                    switch (sc.delegation) {
                        .This, .Super => |list| for (list) |*e| try w.walkExpr(e),
                        .None => {},
                    }
                    if (sc.body) |*b| try w.walkBlock(b);
                }
                for (c.enum_entries) |*e| {
                    try w.declare(e.name.name);
                    for (e.args) |*arg| try w.walkExpr(arg);
                    for (e.body_members) |*m| try w.walkDecl(m);
                }
                for (c.members) |*m| try w.walkDecl(m);
            },
            .Object => |*o| {
                try w.declare(o.name.name);
                try w.pushClass(o.name.name);
                defer w.popClass();
                try w.walkSupertypes(o.supertypes, o.supertype_args, o.supertype_delegates);
                for (o.init_blocks) |*b| try w.walkBlock(b);
                for (o.members) |*m| try w.walkDecl(m);
            },
            .TypeAlias => {},
        }
    }

    fn walkBlock(w: *Walker, b: *Block) Allocator.Error!void {
        for (b.stmts) |*s| try w.walkStmt(s);
    }

    fn walkStmt(w: *Walker, s: *Stmt) Allocator.Error!void {
        switch (s.*) {
            .Expr => |*e| try w.walkExpr(e),
            .Decl => |*d| try w.walkDecl(d),
            .Assign => |*asg| {
                try w.walkExpr(&asg.target);
                try w.walkExpr(&asg.value);
            },
            .DestructuringDecl => |*dd| {
                for (dd.names) |n| try w.declare(n.name);
                try w.walkExpr(&dd.init);
            },
        }
    }

    fn walkExpr(w: *Walker, e: *Expr) Allocator.Error!void {
        switch (e.*) {
            .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit, .Break, .Continue => {},
            .StringTemplate => |*st| for (st.parts) |*part| {
                if (part.* == .Interp) try w.walkExpr(part.Interp);
            },
            .Path => |*p| if (w.mode == .rewrite) try w.rewritePath(p),
            .Member => |*m| try w.walkExpr(m.receiver),
            .Call => |*c| {
                for (c.type_args) |*t| try w.walkType(t);
                switch (c.callee.*) {
                    .Path => |*p| {
                        if (w.mode != .rewrite or !(try w.rewriteCalleePath(c, p))) try w.walkExpr(c.callee);
                    },
                    .Member => |*m| {
                        try w.walkExpr(m.receiver);
                        if (w.mode == .rewrite) try w.rewriteCalleeMember(c, m);
                    },
                    else => try w.walkExpr(c.callee),
                }
                for (c.args) |*arg| try w.walkExpr(arg);
            },
            .Index => |*ix| {
                try w.walkExpr(ix.receiver);
                for (ix.args) |*arg| try w.walkExpr(arg);
            },
            .Binary => |*b| {
                try w.walkExpr(b.lhs);
                try w.walkExpr(b.rhs);
            },
            .Unary => |*u| try w.walkExpr(u.expr),
            .Postfix => |*p| try w.walkExpr(p.expr),
            .If => |*i| {
                try w.walkExpr(i.cond);
                try w.walkExpr(i.then_branch);
                if (i.else_branch) |eb| try w.walkExpr(eb);
            },
            .While => |*wh| {
                try w.walkExpr(wh.cond);
                try w.walkExpr(wh.body);
            },
            .DoWhile => |*dw| {
                if (dw.body) |b| try w.walkExpr(b);
                try w.walkExpr(dw.cond);
            },
            .For => |*f| {
                for (f.vars) |v| try w.declare(v.name);
                try w.walkOptType(&f.var_ty);
                try w.walkExpr(f.iter);
                try w.walkExpr(f.body);
            },
            .Return => |*r| if (r.value) |v| try w.walkExpr(v),
            .Labeled => |*l| try w.walkExpr(l.expr),
            .Block => |*b| try w.walkBlock(b),
            .Throw => |*t| try w.walkExpr(t.value),
            .Try => |*t| {
                try w.walkBlock(&t.body);
                for (t.catches) |*c| {
                    try w.declare(c.binding.name);
                    try w.walkType(&c.ty);
                    try w.walkBlock(&c.body);
                }
                if (t.finally) |*f| try w.walkBlock(f);
            },
            .Lambda => |*l| {
                for (l.params) |p| try w.declare(p.name);
                for (l.param_tys) |*pt| try w.walkOptType(pt);
                try w.walkBlock(&l.body);
            },
            .This => {},
            .Super => |*s| try w.walkOptType(&s.qualifier),
            .PropertyRef => |*pr| if (w.mode == .rewrite) try w.rewriteRefName(&pr.name),
            .MemberRef => |*mr| {
                try w.walkExpr(mr.receiver);
                if (w.mode == .rewrite) try w.rewriteRefName(&mr.name);
            },
            .When => |*wn| {
                if (wn.subject) |s| try w.walkExpr(s);
                if (wn.subject_binding) |*sb| {
                    try w.declare(sb.name.name);
                    try w.walkOptType(&sb.ty);
                }
                for (wn.branches) |*br| {
                    for (br.patterns) |*pat| switch (pat.kind) {
                        .Value, .InRange, .NotInRange => |*v| try w.walkExpr(v),
                        .IsType, .NotIsType => |*t| try w.walkType(t),
                        .Else => {},
                    };
                    try w.walkExpr(&br.body);
                }
            },
            .IsCheck => |*ic| {
                try w.walkExpr(ic.expr);
                try w.walkType(&ic.ty);
            },
            .As => |*as| {
                try w.walkExpr(as.expr);
                try w.walkType(&as.ty);
            },
            .AnonFun => |*af| {
                try w.walkOptType(&af.receiver_ty);
                try w.walkContextParams(af.context_params);
                try w.walkParams(af.params);
                try w.walkOptType(&af.return_ty);
                if (af.body) |b| try w.walkBody(b);
            },
            .Spread => |*s| try w.walkExpr(s.expr),
            .ObjectExpr => |*o| {
                try w.walkSupertypes(o.supertypes, o.supertype_args, o.supertype_delegates);
                for (o.init_blocks) |*b| try w.walkBlock(b);
                for (o.members) |*m| try w.walkDecl(m);
            },
        }
    }
};

// Tests

const testing = std.testing;

fn testFileId() span_mod.FileId {
    return span_mod.FileId.from(0);
}

fn tIdent(name: []const u8) Ident {
    return .{ .name = name, .span = Span.init(testFileId(), 0, 0) };
}

fn tType(a: Allocator, name: []const u8, args: []const []const u8) Allocator.Error!TypeRef {
    const targs = try a.alloc(TypeArg, args.len);
    for (args, targs) |n, *o| {
        o.* = .{ .variance = .Invariant, .is_star = false, .ty = try tType(a, n, &.{}), .span = Span.init(testFileId(), 0, 0) };
    }
    return .{
        .name = tIdent(name),
        .nullable = false,
        .span = Span.init(testFileId(), 0, 0),
        .type_args = targs,
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

fn tAlias(a: Allocator, name: []const u8, params: []const []const u8, target: TypeRef) Allocator.Error!Decl {
    const tps = try a.alloc(ast.TypeParam, params.len);
    for (params, tps) |n, *o| {
        o.* = .{ .name = tIdent(n), .variance = .Invariant, .upper_bound = null, .is_reified = false, .annotations = &.{}, .span = Span.init(testFileId(), 0, 0) };
    }
    return .{ .TypeAlias = .{
        .name = tIdent(name),
        .type_params = tps,
        .target = target,
        .visibility = .Public,
        .annotations = &.{},
        .span = Span.init(testFileId(), 0, 0),
    } };
}

fn tFun(a: Allocator, name: []const u8, param_ty: TypeRef, body: Expr) Allocator.Error!Decl {
    const params = try a.alloc(ast.Param, 1);
    params[0] = .{ .name = tIdent("p"), .ty = param_ty, .default = null, .is_vararg = false, .is_crossinline = false, .is_noinline = false, .annotations = &.{}, .span = Span.init(testFileId(), 0, 0) };
    return .{ .Function = .{
        .name = tIdent(name),
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = params,
        .return_type = null,
        .body = .{ .Expr = body },
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = Span.init(testFileId(), 0, 0),
    } };
}

fn tCall(a: Allocator, callee_name: []const u8, type_args: []const []const u8) Allocator.Error!Expr {
    const callee = try a.create(Expr);
    const segs = try a.alloc(Ident, 1);
    segs[0] = tIdent(callee_name);
    callee.* = .{ .Path = .{ .segments = segs, .span = Span.init(testFileId(), 0, 0) } };
    const targs = try a.alloc(TypeRef, type_args.len);
    for (type_args, targs) |n, *o| o.* = try tType(a, n, &.{});
    return .{ .Call = .{
        .callee = callee,
        .args = &.{},
        .arg_names = &.{},
        .type_args = targs,
        .is_infix = false,
        .span = Span.init(testFileId(), 0, 0),
    } };
}

fn tFile(a: Allocator, decls: []const Decl) Allocator.Error!KotlinFile {
    return .{
        .package = null,
        .imports = &.{},
        .decls = try a.dupe(Decl, decls),
        .span = Span.init(testFileId(), 0, 0),
    };
}

test "generic alias in a type position substitutes its arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // typealias ST<T> = Pair<String, T>; fun f(p: ST<Int>) = 0
    const decls = [_]Decl{
        try tAlias(a, "ST", &.{"T"}, try tType(a, "Pair", &.{ "String", "T" })),
        try tFun(a, "f", try tType(a, "ST", &.{"Int"}), .{ .IntLit = .{ .value = 0, .kind = .Int, .span = Span.init(testFileId(), 0, 0) } }),
    };
    const files = [_]KotlinFile{try tFile(a, &decls)};
    try expandFiles(a, &files);
    const p = files[0].decls[1].Function.params[0].ty;
    try testing.expectEqualStrings("Pair", p.name.name);
    try testing.expectEqual(@as(usize, 2), p.type_args.len);
    try testing.expectEqualStrings("String", p.type_args[0].ty.name.name);
    try testing.expectEqualStrings("Int", p.type_args[1].ty.name.name);
}

test "alias constructor call takes the target's name and mapped type arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // typealias ST<T> = Pair<String, T>; fun f(p: Int) = ST<Boolean>()
    const decls = [_]Decl{
        try tAlias(a, "ST", &.{"T"}, try tType(a, "Pair", &.{ "String", "T" })),
        try tFun(a, "f", try tType(a, "Int", &.{}), try tCall(a, "ST", &.{"Boolean"})),
    };
    const files = [_]KotlinFile{try tFile(a, &decls)};
    try expandFiles(a, &files);
    const call = files[0].decls[1].Function.body.?.Expr.Call;
    try testing.expectEqualStrings("Pair", call.callee.Path.segments[0].name);
    try testing.expectEqual(@as(usize, 2), call.type_args.len);
    try testing.expectEqualStrings("String", call.type_args[0].name.name);
    try testing.expectEqualStrings("Boolean", call.type_args[1].name.name);
}

test "implicit type arguments on a generic alias constructor leave the call to inference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // typealias Cell2<T> = Cell<T>; fun f(p: Int) = Cell2()
    const decls = [_]Decl{
        try tAlias(a, "Cell2", &.{"T"}, try tType(a, "Cell", &.{"T"})),
        try tFun(a, "f", try tType(a, "Int", &.{}), try tCall(a, "Cell2", &.{})),
    };
    const files = [_]KotlinFile{try tFile(a, &decls)};
    try expandFiles(a, &files);
    const call = files[0].decls[1].Function.body.?.Expr.Call;
    try testing.expectEqualStrings("Cell", call.callee.Path.segments[0].name);
    try testing.expectEqual(@as(usize, 0), call.type_args.len);
}

test "an alias name the program also declares as a function is left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // typealias Node = ListNode; fun Node(p: Int) = 0; fun f(p: Node) = Node()
    const decls = [_]Decl{
        try tAlias(a, "Node", &.{}, try tType(a, "ListNode", &.{})),
        try tFun(a, "Node", try tType(a, "Int", &.{}), .{ .IntLit = .{ .value = 0, .kind = .Int, .span = Span.init(testFileId(), 0, 0) } }),
        try tFun(a, "f", try tType(a, "Node", &.{}), try tCall(a, "Node", &.{})),
    };
    const files = [_]KotlinFile{try tFile(a, &decls)};
    try expandFiles(a, &files);
    try testing.expectEqualStrings("Node", files[0].decls[2].Function.params[0].ty.name.name);
    try testing.expectEqualStrings("Node", files[0].decls[2].Function.body.?.Expr.Call.callee.Path.segments[0].name);
}

test "a function type alias expands to its function type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // typealias F<T, R> = T.() -> R; fun f(p: F<String, Int>) = 0
    const ft = try a.create(ast.FunctionTypeRef);
    ft.* = .{
        .receiver = try tType(a, "T", &.{}),
        .params = &.{},
        .ret = try tType(a, "R", &.{}),
        .is_suspend = false,
        .span = Span.init(testFileId(), 0, 0),
    };
    var target = try tType(a, "<function>", &.{});
    target.function = ft;
    const decls = [_]Decl{
        try tAlias(a, "F", &.{ "T", "R" }, target),
        try tFun(a, "f", try tType(a, "F", &.{ "String", "Int" }), .{ .IntLit = .{ .value = 0, .kind = .Int, .span = Span.init(testFileId(), 0, 0) } }),
    };
    const files = [_]KotlinFile{try tFile(a, &decls)};
    try expandFiles(a, &files);
    const p = files[0].decls[1].Function.params[0].ty;
    try testing.expect(p.function != null);
    try testing.expectEqualStrings("String", p.function.?.receiver.?.name.name);
    try testing.expectEqualStrings("Int", p.function.?.ret.name.name);
}
