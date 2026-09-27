//! Static scopes: what a name means at file level and in a declaration's
//! lexical context. Precedence follows the language: explicit imports, then
//! the file's own package, then star imports, then the default imports.
//! Within a declaration, type parameters and nested classifiers of the
//! enclosing classes (and of their supertypes) come first.

const std = @import("std");
const ast = @import("ast");

const sema_mod = @import("sema.zig");
const symbols = @import("symbols.zig");
const names_mod = @import("names.zig");
const headers = @import("headers.zig");
const members = @import("members.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;
const Sym = symbols.Sym;
const Name = names_mod.Name;
const Span = @import("span").Span;

/// Packages every file imports implicitly, in two levels: the common set,
/// then below it klio's own `klio` (the throwables and types Kotlin has no
/// common name for), `kotlin.jvm` and `kotlin.native`, which the JVM's and
/// the native targets' sources klio runs name unqualified. A name the first
/// level declares is never looked up in the second (`IllegalStateException`
/// is `kotlin.IllegalStateException` even where `klio` declares one too).
pub const default_imports = [_][]const u8{
    "kotlin",
    "kotlin.annotation",
    "kotlin.collections",
    "kotlin.comparisons",
    "kotlin.io",
    "kotlin.ranges",
    "kotlin.sequences",
    "kotlin.text",
};

pub const default_low_imports = [_][]const u8{
    "klio",
    "kotlin.jvm",
    "kotlin.native",
};

/// What `import a.b.C` binds `C` (or its alias) to: every declaration named
/// `member` in `container`, a package or a class. An object's members
/// include those it inherits (`import Obj.f` for an `f` its superclass
/// declares).
pub const ImportTarget = struct {
    container: Sym,
    member: Name,
    /// An object's functions and properties named `member`, found once.
    on_object: ?[]const Sym = null,
};

/// A member imported from an object: the object it is called or read on,
/// and its declaring class's type parameters as the object sees them.
pub const ObjectImport = struct {
    object: Sym,
    subst: *const types.Subst,
};

/// An import from an object of a name the object does not declare, which
/// its supertypes may: checked once they are resolved.
pub const InheritedImport = struct {
    container: Sym,
    member: Name,
    span: Span,
    text: []const u8,
};

pub const FileImports = struct {
    explicit: std.AutoHashMapUnmanaged(Name, std.ArrayList(ImportTarget)) = .empty,
    /// Packages and classes imported with `.*`.
    star: std.ArrayList(Sym) = .empty,
    /// The object each member imported from an object is used on.
    object_members: std.AutoHashMapUnmanaged(Sym, ObjectImport) = .empty,
    inherited: std.ArrayList(InheritedImport) = .empty,
};

/// Default-import packages that exist, resolved once per analysis.
pub fn defaultPackages(s: *Sema) Allocator.Error![2][]const Sym {
    if (s.default_packages) |d| return d;
    var out: [2][]const Sym = undefined;
    for ([_][]const []const u8{ &default_imports, &default_low_imports }, &out) |fqns, *level| {
        var list: std.ArrayList(Sym) = .empty;
        for (fqns) |fqn| {
            const n = s.names.lookup(fqn) orelse continue;
            if (s.syms.package_by_fqn.get(n)) |p| try list.append(s.arena, p);
        }
        level.* = list.items;
    }
    s.default_packages = out;
    return out;
}

/// The container a dotted path names: the longest package prefix, then
/// nested classes. Returns the container and how many segments it consumed.
pub fn resolvePathContainer(s: *Sema, path: []const ast.Ident) Allocator.Error!struct { container: Sym, used: usize } {
    var pkg = s.syms.root_package;
    var used: usize = 0;
    while (used < path.len) : (used += 1) {
        const n = s.names.lookup(path[used].name) orelse break;
        const sub = s.syms.packageInfo(pkg).subpackages.get(n) orelse break;
        pkg = sub;
    }
    var container = pkg;
    while (used < path.len) {
        const n = s.names.lookup(path[used].name) orelse break;
        const cls = classifierIn(s, container, n);
        if (cls == .none or s.syms.kind(cls) != .class) break;
        container = cls;
        used += 1;
    }
    return .{ .container = container, .used = used };
}

pub fn fileImports(s: *Sema, file: u32) Allocator.Error!*FileImports {
    const fc = s.fileOf(file).?;
    if (fc.imports) |fi| return fi;
    const fi = try s.arena.create(FileImports);
    fi.* = .{};
    // A base image's files resolve nothing in their own scope: their
    // headers were resolved at the bake.
    for (fc.ast.?.imports) |*imp| {
        if (imp.wildcard) {
            const r = try resolvePathContainer(s, imp.path);
            if (r.used != imp.path.len) {
                try s.census.reportFmt(.unresolved_import, file, imp.span, "{s}.*", .{try pathStr(s, imp.path)});
                continue;
            }
            // Importing a package twice is allowed and imports it once.
            if (std.mem.indexOfScalar(Sym, fi.star.items, r.container) == null) {
                try fi.star.append(s.arena, r.container);
            }
            continue;
        }
        if (imp.path.len == 0) continue;
        const head = imp.path[0 .. imp.path.len - 1];
        const last = imp.path[imp.path.len - 1];
        const r = try resolvePathContainer(s, head);
        const member = try s.names.intern(last.name);
        if (r.used != head.len) {
            try s.census.reportFmt(.unresolved_import, file, imp.span, "{s}", .{try pathStr(s, imp.path)});
            continue;
        }
        if (!containerDeclares(s, r.container, member)) {
            if (!isObject(s, r.container)) {
                try s.census.reportFmt(.unresolved_import, file, imp.span, "{s}", .{try pathStr(s, imp.path)});
                continue;
            }
            try fi.inherited.append(s.arena, .{ .container = r.container, .member = member, .span = imp.span, .text = try pathStr(s, imp.path) });
        }
        const bound = if (imp.alias) |a| try s.names.intern(a.name) else member;
        const gop = try fi.explicit.getOrPut(s.arena, bound);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const target: ImportTarget = .{ .container = r.container, .member = member };
        for (gop.value_ptr.items) |t| {
            if (t.container == target.container and t.member == target.member) break;
        } else try gop.value_ptr.append(s.arena, target);
    }
    fc.imports = fi;
    return fi;
}

pub fn pathStr(s: *Sema, path: []const ast.Ident) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (path, 0..) |seg, i| {
        if (i != 0) try buf.append(s.arena, '.');
        try buf.appendSlice(s.arena, seg.name);
    }
    return buf.items;
}

fn containerDeclares(s: *Sema, container: Sym, n: Name) bool {
    return membersOf(s, container, n).len != 0;
}

/// An object or a companion object: a container whose members can be
/// imported.
fn isObject(s: *Sema, sym: Sym) bool {
    if (s.syms.kind(sym) != .class) return false;
    const k = s.syms.classInfo(sym).kind;
    return k == .object or k == .companion;
}

/// The functions and properties an import from an object names, the ones
/// it inherits included; null for a target that is not an object. Each is
/// recorded in `fi.object_members` with the object it is used on.
pub fn objectMembers(s: *Sema, fi: *FileImports, t: *ImportTarget) Allocator.Error!?[]const Sym {
    if (!isObject(s, t.container)) return null;
    if (t.on_object) |hit| return hit;
    var out: std.ArrayList(Sym) = .empty;
    for (try members.lookup(s, try headers.selfType(s, t.container), t.member, .callable)) |m| {
        if (!visible(s, m.sym)) continue;
        try out.append(s.arena, m.sym);
        try fi.object_members.put(s.arena, m.sym, .{ .object = t.container, .subst = m.subst });
    }
    t.on_object = out.items;
    return out.items;
}

/// Reports the imports from an object of a name neither it nor its
/// supertypes declare, once the supertypes can be resolved.
pub fn checkInheritedImports(s: *Sema, file: u32) Allocator.Error!void {
    const fi = try fileImports(s, file);
    for (fi.inherited.items) |imp| {
        if ((try members.lookup(s, try headers.selfType(s, imp.container), imp.member, .callable)).len != 0) continue;
        try s.census.reportFmt(.unresolved_import, file, imp.span, "{s}", .{imp.text});
    }
    fi.inherited.clearRetainingCapacity();
}

/// Everything `container` (a package or a class) declares under `n`,
/// including superseded `expect` declarations; callers filter.
pub fn membersOf(s: *Sema, container: Sym, n: Name) []const Sym {
    return switch (s.syms.kind(container)) {
        .package => symbols.Symbols.members(&s.syms.packageInfo(container).members, n),
        .class => symbols.Symbols.members(&s.syms.classInfo(container).members, n),
        else => &.{},
    };
}

pub fn isClassifier(s: *Sema, sym: Sym) bool {
    const k = s.syms.kind(sym);
    return k == .class or k == .type_alias;
}

pub fn visible(s: *Sema, sym: Sym) bool {
    const f = s.syms.flags(sym);
    return !f.superseded and !f.hidden;
}

/// The classifier `container` declares under `n`, preferring an `actual`
/// over its `expect`.
pub fn classifierIn(s: *Sema, container: Sym, n: Name) Sym {
    var found: Sym = .none;
    for (membersOf(s, container, n)) |m| {
        if (!isClassifier(s, m)) continue;
        if (!visible(s, m)) continue;
        found = m;
        if (!s.syms.flags(m).expect) break;
    }
    return found;
}

/// Which classifiers a search takes; null takes every one.
pub const Accept = ?*const fn (s: *Sema, sym: Sym) Allocator.Error!bool;

fn classifierInWhere(s: *Sema, container: Sym, n: Name, accept: Accept) Allocator.Error!Sym {
    const a = accept orelse return classifierIn(s, container, n);
    var found: Sym = .none;
    for (membersOf(s, container, n)) |m| {
        if (!isClassifier(s, m)) continue;
        if (!visible(s, m)) continue;
        if (!try a(s, m)) continue;
        found = m;
        if (!s.syms.flags(m).expect) break;
    }
    return found;
}

/// A classifier by simple name in a file's static scope.
pub fn classifierInFile(s: *Sema, file: u32, n: Name) Allocator.Error!Sym {
    return classifierInFileWhere(s, file, n, null);
}

/// `classifierInFile` among the classifiers `accept` takes: a level with
/// none it takes does not end the search.
pub fn classifierInFileWhere(s: *Sema, file: u32, n: Name, accept: Accept) Allocator.Error!Sym {
    const fi = try fileImports(s, file);
    if (fi.explicit.getPtr(n)) |targets| {
        for (targets.items) |t| {
            const c = try classifierInWhere(s, t.container, t.member, accept);
            if (c != .none) return c;
        }
    }
    const fc = s.fileOf(file).?;
    const own = try classifierInWhere(s, fc.package, n, accept);
    if (own != .none) return own;
    var star_hit: Sym = .none;
    for (fi.star.items) |c| {
        const hit = try classifierInWhere(s, c, n, accept);
        if (hit != .none) {
            star_hit = hit;
            break;
        }
    }
    if (star_hit != .none) return star_hit;
    for (try defaultPackages(s)) |level| for (level) |p| {
        const hit = try classifierInWhere(s, p, n, accept);
        if (hit != .none) return hit;
    };
    return .none;
}

/// A classifier by simple name from inside the declaration `ctx`: type
/// parameters of the enclosing declarations, nested classifiers of the
/// enclosing classes and their supertypes and companions, then the file.
pub fn classifierInContext(s: *Sema, ctx: Sym, file: u32, n: Name) Allocator.Error!Sym {
    return classifierInContextOf(s, ctx, file, n, .none);
}

/// `classifierInContext`, where class `header` contributes its type
/// parameters only: a class's supertypes are written in its header, where
/// its own nested classifiers are not in scope (`class C : Base<Base<Int>>
/// { interface Base }` extends the outer `Base`).
pub fn classifierInContextOf(s: *Sema, ctx: Sym, file: u32, n: Name, header: Sym) Allocator.Error!Sym {
    var cur = ctx;
    // A nested (non-inner) class does not see its outer class's type
    // parameters; it does see the outer's nested classifiers.
    var type_params_visible = true;
    while (cur != .none) {
        const sym = s.syms.get(cur);
        // Classes declared in this declaration's body (local classes are
        // registered under the function, lambda or class that owns them).
        if (cur != header) if (s.local_classifiers.getPtr(cur)) |idx| {
            const hits = symbols.Symbols.members(idx, n);
            if (hits.len != 0) return hits[hits.len - 1];
        };
        switch (sym.kind) {
            .package => break,
            .function, .constructor => {
                const info = s.syms.functionInfo(cur);
                if (type_params_visible) for (info.type_params) |tp| {
                    if (s.syms.name(tp) == n) return tp;
                };
                // A constructor sees its class's type parameters.
            },
            .property => {
                const info = s.syms.propertyInfo(cur);
                if (type_params_visible) for (info.type_params) |tp| {
                    if (s.syms.name(tp) == n) return tp;
                };
            },
            .type_alias => {
                for (s.syms.aliasInfo(cur).type_params) |tp| {
                    if (s.syms.name(tp) == n) return tp;
                }
            },
            .class => {
                const info = s.syms.classInfo(cur);
                if (type_params_visible) for (info.type_params) |tp| {
                    if (s.syms.name(tp) == n) return tp;
                };
                const nested = if (cur == header) .none else try nestedClassifier(s, cur, n);
                if (nested != .none) return nested;
                // A nested class does not see its outer class's type
                // parameters; a class declared in a body (a function's, an
                // accessor's, an initializer's) sees the ones in scope there.
                if (!sym.flags.inner and info.kind != .anonymous and isMemberClass(s, cur)) type_params_visible = false;
            },
            else => {},
        }
        cur = sym.owner;
    }
    return classifierInFile(s, file, n);
}

/// Whether `cls` is declared as a member of a class, not in a body.
pub fn isMemberClass(s: *Sema, cls: Sym) bool {
    const owner = s.syms.owner(cls);
    if (owner == .none or s.syms.kind(owner) != .class) return false;
    return std.mem.indexOfScalar(Sym, membersOf(s, owner, s.syms.name(cls)), cls) != null;
}

/// A classifier nested in `cls`, in its companion, or inherited from a
/// supertype.
pub fn nestedClassifier(s: *Sema, cls: Sym, n: Name) Allocator.Error!Sym {
    var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
    return nestedClassifierWalk(s, cls, n, &seen);
}

fn nestedClassifierWalk(s: *Sema, cls: Sym, n: Name, seen: *std.AutoHashMapUnmanaged(Sym, void)) Allocator.Error!Sym {
    if ((try seen.getOrPut(s.arena, cls)).found_existing) return .none;
    const own = classifierIn(s, cls, n);
    if (own != .none) return own;
    const comp = s.syms.classInfo(cls).companion;
    if (comp != .none) {
        const c = classifierIn(s, comp, n);
        if (c != .none) return c;
    }
    for (try headers.supertypes(s, cls)) |st| {
        const sc = s.types.classSym(st);
        if (sc == .none) continue;
        const hit = try nestedClassifierWalk(s, sc, n, seen);
        if (hit != .none) return hit;
    }
    return .none;
}
