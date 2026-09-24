//! What a program's census site says to the person who wrote the program:
//! the problem and, where there is one, what to do about it. The census keeps
//! the analysis's own terms (`Site.detail`); a diagnostic is rendered from the
//! site's facts only when it is shown.

const std = @import("std");

const sema_mod = @import("sema.zig");
const Sema = sema_mod.Sema;
const census = @import("census.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const headers = @import("headers.zig");
const scope = @import("scope.zig");
const calls = @import("calls.zig");

const Allocator = std.mem.Allocator;
const Sym = symbols.Sym;
const TypeId = types.TypeId;
const Site = census.Site;

/// The message of `site`, in plain words.
pub fn message(s: *Sema, a: Allocator, site: Site) Allocator.Error![]const u8 {
    if (site.message.len != 0) return site.message;
    const n = if (site.name.len != 0) site.name else site.detail;
    return switch (site.reason) {
        .unresolved_type => std.fmt.allocPrint(a, "unresolved type `{s}`", .{n}),
        .unresolved_name, .unresolved_call => if (site.on.len != 0)
            std.fmt.allocPrint(a, "unresolved reference `{s}` on `{s}`", .{ n, site.on })
        else
            unresolvedReference(s, a, site.file, n),
        .unresolved_member => if (site.on.len != 0)
            std.fmt.allocPrint(a, "unresolved reference `{s}` on `{s}`", .{ n, site.on })
        else
            std.fmt.allocPrint(a, "unresolved reference `{s}`", .{n}),
        .no_applicable => noApplicable(s, a, n, site),
        .ambiguous => ambiguous(s, a, n, site.syms),
        .receiver_unresolved => std.fmt.allocPrint(a, "cannot resolve `{s}`: its receiver did not resolve", .{n}),
        .unresolved_receiver => std.fmt.allocPrint(a, "`{s}` names no receiver in scope", .{n}),
        .unresolved_operator => std.fmt.allocPrint(a, "`{s}` has no `operator fun {s}` that accepts ({s})", .{ site.on, n, try argsText(s, a, site.arg_types) }),
        .uninferred => uninferred(s, a, n, site.syms),
        .unresolved_import => std.fmt.allocPrint(a, "unresolved import `{s}`", .{n}),
        .unsupported => std.fmt.allocPrint(a, "klio does not support {s} yet", .{site.detail}),
        .missing_builtin => std.fmt.allocPrint(a, "the base declares no `{s}`", .{site.detail}),
        .unrecorded => std.fmt.allocPrint(a, "internal error: {s} was resolved without a record", .{site.detail}),
        .expect_actual_mismatch => site.detail,
        .conflicting_overloads => conflicting(s, a, site.syms),
        .expect_no_actual => std.fmt.allocPrint(a, "`{s}` is an `expect` with no `actual`", .{n}),
        .invisible => invisible(s, a, n, site.syms),
        .reified_param => std.fmt.allocPrint(a, "cannot use `{s}` as a reified type argument of `{s}`; use a class instead", .{ if (site.syms.len != 0) s.str(s.syms.name(site.syms[0])) else "?", n }),
    };
}

/// "unresolved reference `f`", with the import that would name it when
/// exactly one package the file does not import declares `f`.
fn unresolvedReference(s: *Sema, a: Allocator, file: u32, n: []const u8) Allocator.Error![]const u8 {
    if (try importHint(s, a, file, n)) |fqn| {
        return std.fmt.allocPrint(a, "unresolved reference `{s}`; add `import {s}`", .{ n, fqn });
    }
    return std.fmt.allocPrint(a, "unresolved reference `{s}`", .{n});
}

/// The one package, other than the file's own, whose public top-level
/// declarations include `n` (a function or property that is not an
/// extension, or a class): the import that makes `n` resolve. Null when no
/// package or several do.
pub fn importHint(s: *Sema, a: Allocator, file: u32, n: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.indexOfAny(u8, n, ".:( ") != null) return null;
    const name = s.names.lookup(n) orelse return null;
    const own = if (s.fileOf(file)) |fc| fc.package else Sym.none;
    var found: Sym = .none;
    var it = s.syms.package_by_fqn.valueIterator();
    while (it.next()) |p| {
        const pkg = p.*;
        if (pkg == own) continue;
        for (scope.membersOf(s, pkg, name)) |m| {
            if (!scope.visible(s, m) or s.syms.flags(m).visibility != .public) continue;
            if (!try importable(s, m)) continue;
            if (found != .none and found != pkg) return null;
            found = pkg;
            break;
        }
    }
    if (found == .none) return null;
    const fqn = s.str(s.syms.packageInfo(found).fqn);
    if (fqn.len == 0) return null;
    return try std.fmt.allocPrint(a, "{s}.{s}", .{ fqn, n });
}

fn importable(s: *Sema, m: Sym) Allocator.Error!bool {
    return switch (s.syms.kind(m)) {
        .class, .type_alias => true,
        .function => blk: {
            try headers.functionHeader(s, m);
            break :blk s.syms.functionInfo(m).receiver == .none;
        },
        .property => blk: {
            try headers.propertyHeader(s, m);
            break :blk s.syms.propertyInfo(m).receiver == .none;
        },
        else => false,
    };
}

fn noApplicable(s: *Sema, a: Allocator, n: []const u8, site: Site) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a, "none of the candidates for `{s}` accept ({s})", .{ n, try argsText(s, a, site.arg_types) });
    if (site.syms.len != 0) try buf.appendSlice(a, ":");
    for (site.syms) |c| {
        try buf.appendSlice(a, "\n    ");
        try writeSignature(s, a, &buf, c);
    }
    return buf.items;
}

fn ambiguous(s: *Sema, a: Allocator, n: []const u8, cands: []const Sym) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(a, "`{s}` is ambiguous", .{n});
    for (cands, 0..) |c, i| {
        try buf.appendSlice(a, if (i == 0) ": " else ", ");
        try buf.append(a, '`');
        try writeSignature(s, a, &buf, c);
        try buf.append(a, '`');
    }
    return buf.items;
}

fn invisible(s: *Sema, a: Allocator, n: []const u8, syms: []const Sym) Allocator.Error![]const u8 {
    if (syms.len == 0) return std.fmt.allocPrint(a, "cannot access `{s}`", .{n});
    const m = syms[0];
    const vis = if (s.syms.flags(m).visibility == .private) "private" else "protected";
    return std.fmt.allocPrint(a, "cannot access `{s}`: it is {s} in `{s}`", .{ n, vis, s.str(s.syms.name(s.syms.owner(m))) });
}

fn uninferred(s: *Sema, a: Allocator, n: []const u8, tps: []const Sym) Allocator.Error![]const u8 {
    if (tps.len == 0) return std.fmt.allocPrint(a, "cannot infer a type argument of `{s}`; write it explicitly", .{n});
    return std.fmt.allocPrint(a, "cannot infer the type argument `{s}` of `{s}`; write it explicitly", .{ s.str(s.syms.name(tps[0])), n });
}

/// `syms[0]` is the declaration reported; the rest are the ones it clashes
/// with. Functions are conflicting overloads, properties conflicting
/// declarations, classifiers redeclarations.
fn conflicting(s: *Sema, a: Allocator, syms: []const Sym) Allocator.Error![]const u8 {
    if (syms.len == 0) return "conflicting overloads";
    var buf: std.ArrayList(u8) = .empty;
    switch (s.syms.kind(syms[0])) {
        .function => {
            try buf.appendSlice(a, "conflicting overloads: `");
            try writeShortSignature(s, a, &buf, syms[0]);
        },
        .property => {
            try buf.appendSlice(a, "conflicting declarations: `");
            try buf.appendSlice(a, if (s.syms.flags(syms[0]).mutable) "var " else "val ");
            try headers.propertyHeader(s, syms[0]);
            const recv = s.syms.propertyInfo(syms[0]).receiver;
            if (recv != .none) {
                try writeType(s, a, &buf, recv);
                try buf.append(a, '.');
            }
            try buf.appendSlice(a, s.str(s.syms.name(syms[0])));
        },
        else => {
            try buf.appendSlice(a, "redeclaration: `");
            try buf.appendSlice(a, s.str(s.syms.name(syms[0])));
        },
    }
    const times = syms.len;
    if (times <= 2) {
        try buf.appendSlice(a, "` is declared twice");
    } else {
        try buf.print(a, "` is declared {d} times", .{times});
    }
    return buf.items;
}

fn argsText(s: *Sema, a: Allocator, ts: []const TypeId) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (ts, 0..) |t, i| {
        if (i != 0) try buf.appendSlice(a, ", ");
        if (t == .none) {
            try buf.appendSlice(a, "{ ... }");
        } else {
            try writeType(s, a, &buf, t);
        }
    }
    return buf.items;
}

/// `fun <T> f(a: Int, vararg b: T): String`, `constructor Box(v: Int)`,
/// `val x: Int`.
pub fn writeSignature(s: *Sema, a: Allocator, buf: *std.ArrayList(u8), sym: Sym) Allocator.Error!void {
    switch (s.syms.kind(sym)) {
        .function, .constructor => {
            try headers.functionHeader(s, sym);
            const info = s.syms.functionInfo(sym);
            const is_ctor = s.syms.kind(sym) == .constructor;
            try buf.appendSlice(a, if (is_ctor) "constructor " else "fun ");
            if (info.type_params.len != 0) {
                try buf.append(a, '<');
                for (info.type_params, 0..) |tp, i| {
                    if (i != 0) try buf.appendSlice(a, ", ");
                    try buf.appendSlice(a, s.str(s.syms.name(tp)));
                }
                try buf.appendSlice(a, "> ");
            }
            if (info.receiver != .none) {
                try writeType(s, a, buf, info.receiver);
                try buf.append(a, '.');
            }
            const name = if (is_ctor) s.syms.name(s.syms.owner(sym)) else s.syms.name(sym);
            try buf.appendSlice(a, s.str(name));
            try buf.append(a, '(');
            for (info.params, 0..) |p, i| {
                if (i != 0) try buf.appendSlice(a, ", ");
                if (s.syms.flags(p).vararg) try buf.appendSlice(a, "vararg ");
                try buf.print(a, "{s}: ", .{s.str(s.syms.name(p))});
                try writeType(s, a, buf, try headers.paramType(s, p));
            }
            try buf.append(a, ')');
            if (!is_ctor) {
                try buf.appendSlice(a, ": ");
                try writeType(s, a, buf, try headers.returnType(s, sym));
            }
        },
        .property => {
            try headers.propertyHeader(s, sym);
            const info = s.syms.propertyInfo(sym);
            try buf.appendSlice(a, if (s.syms.flags(sym).mutable) "var " else "val ");
            if (info.receiver != .none) {
                try writeType(s, a, buf, info.receiver);
                try buf.append(a, '.');
            }
            try buf.print(a, "{s}: ", .{s.str(s.syms.name(sym))});
            try writeType(s, a, buf, try headers.propertyType(s, sym));
        },
        else => try buf.appendSlice(a, s.str(s.syms.name(sym))),
    }
}

/// `greet(String)`: a function's name and parameter types.
fn writeShortSignature(s: *Sema, a: Allocator, buf: *std.ArrayList(u8), sym: Sym) Allocator.Error!void {
    if (s.syms.kind(sym) != .function and s.syms.kind(sym) != .constructor) {
        try buf.appendSlice(a, s.str(s.syms.name(sym)));
        return;
    }
    try headers.functionHeader(s, sym);
    const info = s.syms.functionInfo(sym);
    if (info.receiver != .none) {
        try writeType(s, a, buf, info.receiver);
        try buf.append(a, '.');
    }
    try buf.appendSlice(a, s.str(s.syms.name(sym)));
    try buf.append(a, '(');
    for (info.params, 0..) |p, i| {
        if (i != 0) try buf.appendSlice(a, ", ");
        if (s.syms.flags(p).vararg) try buf.appendSlice(a, "vararg ");
        try writeType(s, a, buf, try headers.paramType(s, p));
    }
    try buf.append(a, ')');
}

/// A type as the program writes it: classes by their simple names,
/// function types as `(A) -> R`.
pub fn typeText(s: *Sema, a: Allocator, t: TypeId) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try writeType(s, a, &buf, t);
    return buf.items;
}

pub fn writeType(s: *Sema, a: Allocator, buf: *std.ArrayList(u8), t: TypeId) Allocator.Error!void {
    switch (s.types.get(t)) {
        .none, .err => try buf.appendSlice(a, "?"),
        .variable => try buf.appendSlice(a, "?"),
        .int_lit => try buf.appendSlice(a, "Int"),
        .param => |p| {
            try buf.appendSlice(a, s.str(s.syms.name(p.sym)));
            if (p.dnn) try buf.appendSlice(a, " & Any");
            if (p.nullable) try buf.append(a, '?');
        },
        .intersection => |parts| {
            for (parts, 0..) |p, i| {
                if (i != 0) try buf.appendSlice(a, " & ");
                try writeType(s, a, buf, p);
            }
        },
        .class => |c| {
            if (calls.functionShape(s, t)) |shape| {
                if (shape.params + @intFromBool(shape.has_receiver) + shape.contexts + 1 == c.args.len) {
                    if (c.nullable) try buf.append(a, '(');
                    try writeFunctionType(s, a, buf, c.args, shape);
                    if (c.nullable) try buf.appendSlice(a, ")?");
                    return;
                }
            }
            try buf.appendSlice(a, s.str(s.syms.name(c.sym)));
            if (c.args.len != 0) {
                try buf.append(a, '<');
                for (c.args, 0..) |arg, i| {
                    if (i != 0) try buf.appendSlice(a, ", ");
                    switch (arg.variance) {
                        .star => {
                            try buf.append(a, '*');
                            continue;
                        },
                        .in => try buf.appendSlice(a, "in "),
                        .out => try buf.appendSlice(a, "out "),
                        .inv => {},
                    }
                    try writeType(s, a, buf, arg.ty);
                }
                try buf.append(a, '>');
            }
            if (c.nullable) try buf.append(a, '?');
        },
    }
}

fn writeFunctionType(s: *Sema, a: Allocator, buf: *std.ArrayList(u8), args: []const types.Arg, shape: calls.FnShape) Allocator.Error!void {
    if (shape.is_suspend) try buf.appendSlice(a, "suspend ");
    var i: usize = 0;
    if (shape.contexts != 0) {
        try buf.appendSlice(a, "context(");
        while (i < shape.contexts) : (i += 1) {
            if (i != 0) try buf.appendSlice(a, ", ");
            try writeType(s, a, buf, args[i].ty);
        }
        try buf.appendSlice(a, ") ");
    }
    if (shape.has_receiver) {
        try writeType(s, a, buf, args[i].ty);
        try buf.append(a, '.');
        i += 1;
    }
    try buf.append(a, '(');
    const first = i;
    while (i < args.len - 1) : (i += 1) {
        if (i != first) try buf.appendSlice(a, ", ");
        try writeType(s, a, buf, args[i].ty);
    }
    try buf.appendSlice(a, ") -> ");
    try writeType(s, a, buf, args[args.len - 1].ty);
}
