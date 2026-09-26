//! What using a declaration asks of the program: a deprecated declaration
//! is reported where it is used, at its level (`@Deprecated`, or
//! `@DeprecatedSinceKotlin` against the language version), and an override
//! of a deprecated member that is not deprecated itself is warned of. Each
//! finding is a `use` census site naming kotlinc's diagnostic.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

const sema_mod = @import("sema.zig");
const Sema = sema_mod.Sema;
const symbols = @import("symbols.zig");
const headers = @import("headers.zig");
const members = @import("members.zig");
const census = @import("census.zig");
const diagnose = @import("diagnose.zig");
const declcheck = @import("declcheck.zig");

const Allocator = std.mem.Allocator;
const Sym = symbols.Sym;
const Span = span.Span;

/// The language version the analysis stands for, which
/// `@DeprecatedSinceKotlin` versions are measured against.
pub const language_version = Version{ .major = 2, .minor = 4 };

pub const Level = enum { warning, err, hidden };

pub const Deprecation = struct {
    level: Level,
    message: []const u8,
};

pub fn checkProgram(s: *Sema) Allocator.Error!void {
    var c = Checker{ .s = s };
    // A constructor call names its class too; kotlinc reports the
    // constructor.
    var ctor_at: std.AutoHashMapUnmanaged(struct { u32, u32 }, void) = .empty;
    for (s.refs.items) |r| {
        if (r.kind == .ctor) try ctor_at.put(s.arena, .{ r.file, r.anchor.start }, {});
    }
    // Each use once: an assignment's read and write share their name.
    var seen: std.AutoHashMapUnmanaged(struct { u32, u32, Sym }, void) = .empty;
    for (s.refs.items) |r| {
        const fc = s.fileOf(r.file) orelse continue;
        if (!declcheck.checked(fc)) continue;
        switch (r.kind) {
            .decl, .this_, .return_ => continue,
            else => {},
        }
        if (r.target == .none) continue;
        if (r.kind != .ctor and s.syms.kind(r.target) == .class and ctor_at.contains(.{ r.file, r.anchor.start })) continue;
        if ((try seen.getOrPut(s.arena, .{ r.file, r.anchor.start, r.target })).found_existing) continue;
        try c.use(r.file, r.anchor, r.target);
    }
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = Sym.from(i);
        const info = s.syms.get(sym);
        const fc = s.fileOf(info.file) orelse continue;
        if (!declcheck.checked(fc) or info.flags.synthetic) continue;
        // The types a declaration's header names.
        switch (info.decl) {
            .function => |d| {
                if (d.receiver_type) |t| try c.typeUse(sym, t);
                if (d.return_type) |t| try c.typeUse(sym, t);
            },
            .property => |d| {
                if (d.receiver_type) |t| try c.typeUse(sym, t);
                if (d.ty) |t| try c.typeUse(sym, t);
            },
            .param => |d| try c.typeUse(sym, &d.ty),
            .class_param => |d| if (info.kind == .value_param) try c.typeUse(sym, &d.ty),
            .class => |d| for (d.supertypes) |*t| try c.typeUse(sym, t),
            .object => |d| for (d.supertypes) |*t| try c.typeUse(sym, t),
            .type_alias => |d| try c.typeUse(sym, &d.target),
            else => {},
        }
        if (!info.flags.override) continue;
        if (info.kind != .function and info.kind != .property) continue;
        try c.overrideDeprecation(sym);
    }
}

const Checker = struct {
    s: *Sema,
    cache: std.AutoHashMapUnmanaged(Sym, ?Deprecation) = .empty,
    /// Where a deprecation was reported: a site names it once, however many
    /// records share it.
    reported: std.AutoHashMapUnmanaged(struct { u32, u32, Sym }, void) = .empty,

    /// A use of `target` at `sp`: reported if it is deprecated.
    fn use(self: *Checker, file: u32, sp: Span, target: Sym) Allocator.Error!void {
        const s = self.s;
        if (try self.deprecation(target)) |dep| {
            if (dep.level != .hidden and !(try self.reported.getOrPut(s.arena, .{ file, sp.start, Sym.none })).found_existing) {
                try self.report(file, sp, target, dep);
            }
        }
    }

    fn report(self: *Checker, file: u32, sp: Span, target: Sym, dep: Deprecation) Allocator.Error!void {
        const s = self.s;
        const factory: census.Factory = if (dep.level == .err) .DEPRECATION_ERROR else .DEPRECATION;
        const msg = try std.fmt.allocPrint(s.arena, "'{s}' is deprecated. {s}{s}", .{
            try self.declText(target),
            dep.message,
            if (std.mem.endsWith(u8, dep.message, ".")) "" else ".",
        });
        try s.census.reportFacts(.use, file, sp, .{ .message = msg, .factory = factory, .severity = if (dep.level == .err) .err else .warning }, "{s}: {s}", .{ @tagName(factory), msg });
    }

    /// kotlinc's rendering of a deprecated declaration: `fun f(): Int`,
    /// `val p: Int`, `constructor(): C`, `class C : Any`.
    fn declText(self: *Checker, m: Sym) Allocator.Error![]const u8 {
        const s = self.s;
        switch (s.syms.kind(m)) {
            .class => {
                var buf: std.ArrayList(u8) = .empty;
                try buf.print(s.arena, "class {s} : ", .{s.str(s.syms.name(m))});
                for (try headers.supertypes(s, m), 0..) |st, i| {
                    if (i != 0) try buf.appendSlice(s.arena, ", ");
                    try buf.appendSlice(s.arena, try diagnose.typeText(s, s.arena, st));
                }
                return buf.items;
            },
            .constructor => return std.fmt.allocPrint(s.arena, "{s}: {s}", .{ try diagnose.declarationText(s, s.arena, m), s.str(s.syms.name(s.syms.owner(m))) }),
            else => return diagnose.declarationText(s, s.arena, m),
        }
    }

    /// A deprecated class named by a type written in `decl`'s header, or
    /// in its type arguments.
    fn typeUse(self: *Checker, decl: Sym, tr: *const ast.TypeRef) Allocator.Error!void {
        const s = self.s;
        if (tr.function) |f| {
            if (f.receiver) |*r| try self.typeUse(decl, r);
            for (f.params) |*p| try self.typeUse(decl, p);
            try self.typeUse(decl, &f.ret);
            return;
        }
        const ctx: headers.TypeCtx = .{ .decl = decl, .file = s.syms.get(decl).file, .header = s.syms.kind(decl) == .class };
        const c = try headers.resolveClassifierRef(s, ctx, tr);
        if (c != .none and s.syms.kind(c) == .class) try self.use(ctx.file, tr.name.span, c);
        for (tr.type_args) |*ta| if (!ta.is_star) try self.typeUse(decl, &ta.ty);
    }

    /// A member that overrides a deprecated one is deprecated itself, or
    /// kotlinc warns that it is not.
    fn overrideDeprecation(self: *Checker, m: Sym) Allocator.Error!void {
        const s = self.s;
        if ((try self.deprecation(m)) != null) return;
        for (try members.overridden(s, m)) |b| {
            const dep = (try self.deprecation(b)) orelse continue;
            if (dep.level == .hidden) continue;
            const msg = "This declaration overrides a deprecated member but is not marked as deprecated itself. Add the '@Deprecated' annotation or suppress the diagnostic.";
            try s.census.reportFacts(.use, s.syms.get(m).file, @import("decls.zig").declSpan(s, m), .{ .message = msg, .factory = .OVERRIDE_DEPRECATION, .severity = .warning }, "{s}", .{msg});
            return;
        }
    }

    /// How `m` is deprecated, if it is: by its own annotations, or, for a
    /// constructor, by its class's.
    pub fn deprecation(self: *Checker, m: Sym) Allocator.Error!?Deprecation {
        if (self.cache.get(m)) |d| return d;
        const s = self.s;
        // An `expect` is used through its platform's `actual`, whose
        // deprecation may differ: the JVM's `String(CharArray)` is not
        // deprecated where the common declaration is.
        var found = if (s.syms.flags(m).expect) null else try ownDeprecation(s, m);
        if (found == null and s.syms.kind(m) == .constructor) found = try self.deprecation(s.syms.owner(m));
        try self.cache.put(s.arena, m, found);
        return found;
    }
};

fn annotationsOf(s: *Sema, m: Sym) []const ast.Annotation {
    return switch (s.syms.get(m).decl) {
        .function => |d| d.annotations,
        .property => |d| d.annotations,
        .class => |d| d.annotations,
        .object => |d| d.annotations,
        .secondary_ctor => |d| d.annotations,
        .enum_entry => |d| d.annotations,
        .type_alias => |d| d.annotations,
        .class_param => |d| d.annotations,
        else => &.{},
    };
}

/// `@Deprecated(message, level = ...)` on `m`, its level decided by
/// `@DeprecatedSinceKotlin` against the language version when that is
/// there too.
fn ownDeprecation(s: *Sema, m: Sym) Allocator.Error!?Deprecation {
    const anns = annotationsOf(s, m);
    if (anns.len == 0 or s.builtins.deprecated == .none) return null;
    const ctx: headers.TypeCtx = .{ .decl = m, .file = s.syms.get(m).file };
    var dep: ?Deprecation = null;
    var since: ?*const ast.Annotation = null;
    for (anns) |*a| {
        const c = try headers.annotationClass(s, ctx, a);
        if (c == .none) continue;
        if (c == s.builtins.deprecated) {
            dep = .{ .level = deprecationLevel(a), .message = stringArg(a, "message", 0) orelse "" };
        } else if (std.mem.eql(u8, s.str(s.syms.classInfo(c).fqn), "kotlin.DeprecatedSinceKotlin")) {
            since = a;
        }
    }
    var d = dep orelse return null;
    if (since) |a| {
        const at = language_version;
        if (versionArg(a, "hiddenSince")) |v| if (!at.before(v)) {
            d.level = .hidden;
            return d;
        };
        if (versionArg(a, "errorSince")) |v| if (!at.before(v)) {
            d.level = .err;
            return d;
        };
        if (versionArg(a, "warningSince")) |v| if (!at.before(v)) {
            d.level = .warning;
            return d;
        };
        return null;
    }
    return d;
}

/// `level = DeprecationLevel.X`, named or third; a warning otherwise.
fn deprecationLevel(a: *const ast.Annotation) Level {
    for (a.args, 0..) |*arg, i| {
        const named: ?[]const u8 = if (i < a.arg_names.len) a.arg_names[i] else null;
        if (named) |nm| {
            if (!std.mem.eql(u8, nm, "level")) continue;
        } else if (i != 2) continue;
        const last: []const u8 = switch (arg.*) {
            .Path => |p| p.segments[p.segments.len - 1].name,
            .Member => |mb| mb.name.name,
            else => continue,
        };
        if (std.mem.eql(u8, last, "ERROR")) return .err;
        if (std.mem.eql(u8, last, "HIDDEN")) return .hidden;
        return .warning;
    }
    return .warning;
}

/// The string literal argument named `name`, or at `position` when
/// positional.
fn stringArg(a: *const ast.Annotation, name: []const u8, position: usize) ?[]const u8 {
    for (a.args, 0..) |*arg, i| {
        const named: ?[]const u8 = if (i < a.arg_names.len) a.arg_names[i] else null;
        if (named) |nm| {
            if (!std.mem.eql(u8, nm, name)) continue;
        } else if (i != position) continue;
        return switch (arg.*) {
            .StringTemplate => |t| blk: {
                if (t.parts.len == 0) break :blk "";
                for (t.parts) |p| if (p != .Text) break :blk null;
                break :blk if (t.parts.len == 1) t.parts[0].Text else null;
            },
            else => null,
        };
    }
    return null;
}

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32 = 0,

    fn before(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major < other.major;
        if (self.minor != other.minor) return self.minor < other.minor;
        return self.patch < other.patch;
    }

    fn parse(text: []const u8) ?Version {
        var it = std.mem.splitScalar(u8, text, '.');
        const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const minor = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch return null;
        const patch = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch return null;
        return .{ .major = major, .minor = minor, .patch = patch };
    }
};

fn versionArg(a: *const ast.Annotation, name: []const u8) ?Version {
    for (a.args, 0..) |*arg, i| {
        const named = (if (i < a.arg_names.len) a.arg_names[i] else null) orelse continue;
        if (!std.mem.eql(u8, named, name)) continue;
        const text = switch (arg.*) {
            .StringTemplate => |t| if (t.parts.len == 1 and t.parts[0] == .Text) t.parts[0].Text else continue,
            else => continue,
        };
        return Version.parse(text);
    }
    return null;
}
