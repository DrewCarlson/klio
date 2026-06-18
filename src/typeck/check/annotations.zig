//! Annotation-related checks: `@Suppress` regions, deprecation, opt-in,
//! `@Target` / `@Repeatable` enforcement, DSL markers. Free functions over
//! `*Checker` plus standalone collectors.

const std = @import("std");

const span = @import("span");
const ast = @import("ast");
const diagnostics = @import("diagnostics");

const root = @import("../check.zig");
const helpers = @import("helpers.zig");

const Allocator = std.mem.Allocator;
const Span = span.Span;

const KotlinFile = ast.KotlinFile;
const Decl = ast.Decl;
const Class = ast.Class;
const Function = ast.Function;
const Property = ast.Property;
const Block = ast.Block;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const FunctionBody = ast.FunctionBody;
const StringPart = ast.StringPart;
const WhenPatternKind = ast.WhenPatternKind;
const Annotation = ast.Annotation;

const Diagnostic = diagnostics.Diagnostic;
const DiagnosticSink = diagnostics.DiagnosticSink;

const Checker = root.Checker;
const codes = root.codes;

/// Severity of an opt-in requirement; parallels `DeprecationLevel`.
pub const OptInLevel = enum {
    Warning,
    Error,
};

pub const OptInMarker = struct {
    level: OptInLevel,
    message: ?[]const u8,
};

pub fn parseRequiresOptIn(anns: []const Annotation) ?OptInMarker {
    for (anns) |*a| {
        const leaf = if (a.path.len > 0) a.path[a.path.len - 1].name else "";
        if (!std.mem.eql(u8, leaf, "RequiresOptIn")) {
            continue;
        }
        var info: OptInMarker = .{
            .level = .Error,
            .message = null,
        };
        var positional: usize = 0;
        for (a.args, 0..) |*arg, i| {
            const name: ?[]const u8 = if (i < a.arg_names.len) a.arg_names[i] else null;
            const slot: []const u8 = blk: {
                if (name) |nm| {
                    if (std.mem.eql(u8, nm, "message")) break :blk "message";
                    if (std.mem.eql(u8, nm, "level")) break :blk "level";
                    continue;
                } else {
                    switch (positional) {
                        0 => {
                            positional += 1;
                            break :blk "message";
                        },
                        1 => {
                            positional += 1;
                            break :blk "level";
                        },
                        else => continue,
                    }
                }
            };
            if (std.mem.eql(u8, slot, "message")) {
                info.message = extractStringLiteral(arg);
            } else if (std.mem.eql(u8, slot, "level")) {
                if (extractOptInLevel(arg)) |lv| {
                    info.level = lv;
                }
            }
        }
        return info;
    }
    return null;
}

pub fn extractOptInLevel(e: *const Expr) ?OptInLevel {
    const name: []const u8 = switch (e.*) {
        .Path => |p| if (p.segments.len > 0) p.segments[p.segments.len - 1].name else return null,
        .Member => |m| m.name.name,
        else => return null,
    };
    if (std.mem.eql(u8, name, "WARNING")) return .Warning;
    if (std.mem.eql(u8, name, "ERROR")) return .Error;
    return null;
}

/// Build the per-declaration map of opt-in markers applied at the
/// declaration site. Only markers known in `markers` count.
pub fn collectRequiredOptIns(
    allocator: Allocator,
    decls: []const Decl,
    markers: *const std.StringHashMap(OptInMarker),
    out: *std.StringHashMap([][]const u8),
) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Function => |*f| {
                const m = try markerNamesIn(allocator, f.annotations, markers);
                if (m.len != 0) {
                    try out.put(f.name.name, m);
                } else {
                    allocator.free(m);
                }
            },
            .Property => |p| {
                const m = try markerNamesIn(allocator, p.annotations, markers);
                if (m.len != 0) {
                    try out.put(p.name.name, m);
                } else {
                    allocator.free(m);
                }
            },
            .Class => |*c| {
                const m = try markerNamesIn(allocator, c.annotations, markers);
                if (m.len != 0) {
                    try out.put(c.name.name, m);
                } else {
                    allocator.free(m);
                }
                try collectRequiredOptIns(allocator, c.members, markers, out);
            },
            .Object => |*o| {
                try collectRequiredOptIns(allocator, o.members, markers, out);
            },
            .TypeAlias => |*a| {
                const m = try markerNamesIn(allocator, a.annotations, markers);
                if (m.len != 0) {
                    try out.put(a.name.name, m);
                } else {
                    allocator.free(m);
                }
            },
        }
    }
}

pub fn markerNamesIn(
    allocator: Allocator,
    anns: []const Annotation,
    markers: *const std.StringHashMap(OptInMarker),
) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (anns) |*a| {
        if (a.path.len > 0) {
            const leaf = a.path[a.path.len - 1].name;
            if (markers.contains(leaf)) {
                try out.append(allocator, leaf);
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Read marker classes named in `@OptIn(M1::class, M2::class)` on the
/// given annotation set. Returns the set of marker simple names.
pub fn optInMarkersIn(allocator: Allocator, anns: []const Annotation) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (anns) |*a| {
        const leaf = if (a.path.len > 0) a.path[a.path.len - 1].name else "";
        if (!std.mem.eql(u8, leaf, "OptIn")) {
            continue;
        }
        for (a.args) |*arg| {
            if (arg.* == .MemberRef) {
                const mr = arg.MemberRef;
                if (std.mem.eql(u8, mr.name.name, "class") and mr.receiver.* == .Path) {
                    const segments = mr.receiver.Path.segments;
                    if (segments.len > 0) {
                        try out.append(allocator, segments[segments.len - 1].name);
                    }
                }
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn collectOptInDiagnostics(
    allocator: Allocator,
    file: *const KotlinFile,
    markers: *const std.StringHashMap(OptInMarker),
    required: *const std.StringHashMap([][]const u8),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    var scope: std.ArrayList([]const u8) = .empty;
    defer scope.deinit(allocator);
    for (file.decls) |*d| {
        try walkDeclForOptIn(allocator, d, markers, required, &scope, out);
    }
}

pub fn walkDeclForOptIn(
    allocator: Allocator,
    d: *const Decl,
    markers: *const std.StringHashMap(OptInMarker),
    required: *const std.StringHashMap([][]const u8),
    scope: *std.ArrayList([]const u8),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| {
            const added = try pushScope(allocator, scope, f.annotations);
            // A function annotated with the marker itself also "opts
            // in" to the marker for its own body.
            const self_markers = try markerNamesIn(allocator, f.annotations, markers);
            defer allocator.free(self_markers);
            for (self_markers) |m| {
                try scope.append(allocator, m);
            }
            if (f.body) |*body| {
                switch (body.*) {
                    .Expr => |*e| try walkExprForOptIn(allocator, e, markers, required, scope, out),
                    .Block => |*b| try walkBlockForOptIn(allocator, b, markers, required, scope, out),
                }
            }
            for (f.params) |*p| {
                if (p.default) |def| {
                    try walkExprForOptIn(allocator, def, markers, required, scope, out);
                }
            }
            for (0..self_markers.len) |_| _ = scope.pop();
            for (0..added) |_| _ = scope.pop();
        },
        .Property => |p| {
            const added = try pushScope(allocator, scope, p.annotations);
            const self_markers = try markerNamesIn(allocator, p.annotations, markers);
            defer allocator.free(self_markers);
            for (self_markers) |m| {
                try scope.append(allocator, m);
            }
            if (p.init) |*init| {
                try walkExprForOptIn(allocator, init, markers, required, scope, out);
            }
            const accessors = [_]?*const ast.Accessor{
                if (p.getter) |g| g else null,
                if (p.setter) |s| s else null,
            };
            for (accessors) |maybe_acc| {
                const acc = maybe_acc orelse continue;
                switch (acc.body) {
                    .Expr => |*e| try walkExprForOptIn(allocator, e, markers, required, scope, out),
                    .Block => |*b| try walkBlockForOptIn(allocator, b, markers, required, scope, out),
                }
            }
            for (0..self_markers.len) |_| _ = scope.pop();
            for (0..added) |_| _ = scope.pop();
        },
        .Class => |*c| {
            const added = try pushScope(allocator, scope, c.annotations);
            const self_markers = try markerNamesIn(allocator, c.annotations, markers);
            defer allocator.free(self_markers);
            for (self_markers) |m| {
                try scope.append(allocator, m);
            }
            for (c.init_blocks) |*ib| {
                try walkBlockForOptIn(allocator, ib, markers, required, scope, out);
            }
            for (c.primary_params) |*p| {
                if (p.default) |*def| {
                    try walkExprForOptIn(allocator, def, markers, required, scope, out);
                }
            }
            for (c.secondary_ctors) |*sc| {
                if (sc.body) |*body| {
                    try walkBlockForOptIn(allocator, body, markers, required, scope, out);
                }
            }
            for (c.enum_entries) |*ee| {
                for (ee.args) |*a| {
                    try walkExprForOptIn(allocator, a, markers, required, scope, out);
                }
                for (ee.body_members) |*m| {
                    try walkDeclForOptIn(allocator, m, markers, required, scope, out);
                }
            }
            for (c.members) |*m| {
                try walkDeclForOptIn(allocator, m, markers, required, scope, out);
            }
            for (0..self_markers.len) |_| _ = scope.pop();
            for (0..added) |_| _ = scope.pop();
        },
        .Object => |*o| {
            for (o.members) |*m| {
                try walkDeclForOptIn(allocator, m, markers, required, scope, out);
            }
        },
        .TypeAlias => {},
    }
}

pub fn pushScope(
    allocator: Allocator,
    scope: *std.ArrayList([]const u8),
    anns: []const Annotation,
) Allocator.Error!usize {
    const added = try optInMarkersIn(allocator, anns);
    defer allocator.free(added);
    const n = added.len;
    for (added) |a| {
        try scope.append(allocator, a);
    }
    return n;
}

pub fn walkBlockForOptIn(
    allocator: Allocator,
    b: *const Block,
    markers: *const std.StringHashMap(OptInMarker),
    required: *const std.StringHashMap([][]const u8),
    scope: *std.ArrayList([]const u8),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    for (b.stmts) |*s| {
        switch (s.*) {
            .Expr => |*e| try walkExprForOptIn(allocator, e, markers, required, scope, out),
            .Decl => |*d| try walkDeclForOptIn(allocator, d, markers, required, scope, out),
            .Assign => |*a| {
                try walkExprForOptIn(allocator, &a.target, markers, required, scope, out);
                try walkExprForOptIn(allocator, &a.value, markers, required, scope, out);
            },
            .DestructuringDecl => |*dd| {
                try walkExprForOptIn(allocator, &dd.init, markers, required, scope, out);
            },
        }
    }
}

// Single recursive walk over every Expr variant.
pub fn walkExprForOptIn(
    allocator: Allocator,
    e: *const Expr,
    markers: *const std.StringHashMap(OptInMarker),
    required: *const std.StringHashMap([][]const u8),
    scope: *std.ArrayList([]const u8),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1) {
                _ = try emitOptInAt(allocator, p.segments[0].name, p.span, markers, required, scope.items, out);
            }
        },
        .Call => |c| {
            var emitted = false;
            if (c.callee.* == .Path and c.callee.Path.segments.len == 1) {
                emitted = try emitOptInAt(allocator, c.callee.Path.segments[0].name, c.span, markers, required, scope.items, out);
            }
            if (!emitted) {
                try walkExprForOptIn(allocator, c.callee, markers, required, scope, out);
            }
            for (c.args) |*a| {
                try walkExprForOptIn(allocator, a, markers, required, scope, out);
            }
        },
        .Binary => |b| {
            try walkExprForOptIn(allocator, b.lhs, markers, required, scope, out);
            try walkExprForOptIn(allocator, b.rhs, markers, required, scope, out);
        },
        .Member => |m| try walkExprForOptIn(allocator, m.receiver, markers, required, scope, out),
        .MemberRef => |m| try walkExprForOptIn(allocator, m.receiver, markers, required, scope, out),
        .Unary => |x| try walkExprForOptIn(allocator, x.expr, markers, required, scope, out),
        .Postfix => |x| try walkExprForOptIn(allocator, x.expr, markers, required, scope, out),
        .As => |x| try walkExprForOptIn(allocator, x.expr, markers, required, scope, out),
        .IsCheck => |x| try walkExprForOptIn(allocator, x.expr, markers, required, scope, out),
        .Spread => |x| try walkExprForOptIn(allocator, x.expr, markers, required, scope, out),
        .Labeled => |x| try walkExprForOptIn(allocator, x.expr, markers, required, scope, out),
        .Return => |r| {
            if (r.value) |v| try walkExprForOptIn(allocator, v, markers, required, scope, out);
        },
        .Throw => |x| try walkExprForOptIn(allocator, x.value, markers, required, scope, out),
        .Index => |x| {
            try walkExprForOptIn(allocator, x.receiver, markers, required, scope, out);
            for (x.args) |*a| {
                try walkExprForOptIn(allocator, a, markers, required, scope, out);
            }
        },
        .If => |i| {
            try walkExprForOptIn(allocator, i.cond, markers, required, scope, out);
            try walkExprForOptIn(allocator, i.then_branch, markers, required, scope, out);
            if (i.else_branch) |eb| {
                try walkExprForOptIn(allocator, eb, markers, required, scope, out);
            }
        },
        .While => |w| {
            try walkExprForOptIn(allocator, w.cond, markers, required, scope, out);
            try walkExprForOptIn(allocator, w.body, markers, required, scope, out);
        },
        .DoWhile => |w| {
            try walkExprForOptIn(allocator, w.cond, markers, required, scope, out);
            if (w.body) |b| {
                try walkExprForOptIn(allocator, b, markers, required, scope, out);
            }
        },
        .For => |f| {
            try walkExprForOptIn(allocator, f.iter, markers, required, scope, out);
            try walkExprForOptIn(allocator, f.body, markers, required, scope, out);
        },
        .When => |w| {
            if (w.subject) |s| {
                try walkExprForOptIn(allocator, s, markers, required, scope, out);
            }
            for (w.branches) |*br| {
                for (br.patterns) |*p| {
                    switch (p.kind) {
                        .Value, .InRange, .NotInRange => |*pe| {
                            try walkExprForOptIn(allocator, pe, markers, required, scope, out);
                        },
                        else => {},
                    }
                }
                try walkExprForOptIn(allocator, &br.body, markers, required, scope, out);
            }
        },
        .Try => |t| {
            try walkBlockForOptIn(allocator, &t.body, markers, required, scope, out);
            for (t.catches) |*c| {
                try walkBlockForOptIn(allocator, &c.body, markers, required, scope, out);
            }
            if (t.finally) |*f| {
                try walkBlockForOptIn(allocator, f, markers, required, scope, out);
            }
        },
        .Block => |*blk| try walkBlockForOptIn(allocator, blk, markers, required, scope, out),
        .Lambda => |lam| try walkBlockForOptIn(allocator, &lam.body, markers, required, scope, out),
        .AnonFun => |af| {
            if (af.body) |b| {
                switch (b.*) {
                    .Expr => |*e2| try walkExprForOptIn(allocator, e2, markers, required, scope, out),
                    .Block => |*blk| try walkBlockForOptIn(allocator, blk, markers, required, scope, out),
                }
            }
        },
        .ObjectExpr => |oe| {
            for (oe.members) |*m| {
                try walkDeclForOptIn(allocator, m, markers, required, scope, out);
            }
            for (oe.init_blocks) |*ib| {
                try walkBlockForOptIn(allocator, ib, markers, required, scope, out);
            }
            for (oe.supertype_args) |maybe_args| {
                if (maybe_args) |args| {
                    for (args) |*a| {
                        try walkExprForOptIn(allocator, a, markers, required, scope, out);
                    }
                }
            }
            for (oe.supertype_delegates) |maybe_d| {
                if (maybe_d) |*dexpr| {
                    try walkExprForOptIn(allocator, dexpr, markers, required, scope, out);
                }
            }
        },
        .StringTemplate => |st| {
            for (st.parts) |*part| {
                if (part.* == .Interp) {
                    try walkExprForOptIn(allocator, part.Interp, markers, required, scope, out);
                }
            }
        },
        else => {},
    }
}

pub fn emitOptInAt(
    allocator: Allocator,
    name: []const u8,
    sp: Span,
    markers: *const std.StringHashMap(OptInMarker),
    required: *const std.StringHashMap([][]const u8),
    scope: []const []const u8,
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!bool {
    const needed = required.get(name) orelse return false;
    var emitted = false;
    for (needed) |marker| {
        var in_scope = false;
        for (scope) |m| {
            if (std.mem.eql(u8, m, marker)) {
                in_scope = true;
                break;
            }
        }
        if (in_scope) continue;
        const info = markers.get(marker) orelse continue;
        const suffix: []const u8 = if (info.message) |m|
            (if (m.len != 0) try std.fmt.allocPrint(allocator, ": {s}", .{m}) else "")
        else
            "";
        const body = try std.fmt.allocPrint(
            allocator,
            "`{s}` requires opt-in via `@OptIn({s}::class)`{s}",
            .{ name, marker, suffix },
        );
        switch (info.level) {
            .Warning => {
                var d = Diagnostic.warning(body, sp);
                _ = d.withCode(codes.WARN_OPT_IN);
                try out.append(allocator, d);
            },
            .Error => {
                var d = Diagnostic.err(body, sp);
                _ = d.withCode(codes.TYPE_OPT_IN_REQUIRED);
                try out.append(allocator, d);
            },
        }
        emitted = true;
    }
    return emitted;
}

/// A `@Suppress("code", ...)` annotation on a declaration silences each
/// named diagnostic emitted anywhere inside that declaration's span. Scope
/// is lexical: an inner `@Suppress` adds to the enclosing one.
pub fn applySuppressAnnotations(
    allocator: Allocator,
    file: *const KotlinFile,
    sink: *DiagnosticSink,
) Allocator.Error!void {
    var regions: std.ArrayList(SuppressRegion) = .empty;
    defer {
        for (regions.items) |*r| allocator.free(r.codes);
        regions.deinit(allocator);
    }
    try collectSuppressRegions(allocator, file, &regions);
    if (regions.items.len == 0) {
        return;
    }
    var i: usize = 0;
    while (i < sink.diagnostics.items.len) {
        const d = &sink.diagnostics.items[i];
        if (suppressed(d, regions.items)) {
            var removed = sink.diagnostics.orderedRemove(i);
            removed.deinit(allocator);
        } else {
            i += 1;
        }
    }
}

fn suppressed(d: *const Diagnostic, regions: []const SuppressRegion) bool {
    const code = d.code() orelse return false;
    const sp = d.primary.span;
    for (regions) |r| {
        if (r.span.file != sp.file) {
            continue;
        }
        if (r.span.start <= sp.start and sp.end <= r.span.end) {
            for (r.codes) |c| {
                if (std.mem.eql(u8, c, code)) return true;
            }
        }
    }
    return false;
}

pub const SuppressRegion = struct {
    span: Span,
    codes: [][]const u8,
};

pub fn collectSuppressRegions(
    allocator: Allocator,
    file: *const KotlinFile,
    out: *std.ArrayList(SuppressRegion),
) Allocator.Error!void {
    // `@file:Suppress(...)` on the KotlinFile covers the whole file.
    // The parser currently lifts `@file:` annotations onto the
    // top-level declaration that follows, so file-level suppression is
    // handled via the decls below.
    for (file.decls) |*d| {
        try collectSuppressDecl(allocator, d, out);
    }
}

pub fn collectSuppressDecl(
    allocator: Allocator,
    d: *const Decl,
    out: *std.ArrayList(SuppressRegion),
) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| {
            try pushSuppress(allocator, f.annotations, f.span, out);
            for (f.params) |*p| {
                try pushSuppress(allocator, p.annotations, p.span, out);
            }
        },
        .Property => |p| {
            try pushSuppress(allocator, p.annotations, p.span, out);
        },
        .Class => |*c| {
            try pushSuppress(allocator, c.annotations, c.span, out);
            for (c.primary_params) |*cp| {
                try pushSuppress(allocator, cp.annotations, cp.span, out);
            }
            for (c.secondary_ctors) |*sc| {
                try pushSuppress(allocator, sc.annotations, sc.span, out);
            }
            for (c.enum_entries) |*ee| {
                try pushSuppress(allocator, ee.annotations, ee.span, out);
            }
            for (c.members) |*m| {
                try collectSuppressDecl(allocator, m, out);
            }
        },
        .Object => |*o| {
            for (o.members) |*m| {
                try collectSuppressDecl(allocator, m, out);
            }
        },
        .TypeAlias => |*a| {
            try pushSuppress(allocator, a.annotations, a.span, out);
        },
    }
}

pub fn pushSuppress(
    allocator: Allocator,
    anns: []const Annotation,
    sp: Span,
    out: *std.ArrayList(SuppressRegion),
) Allocator.Error!void {
    for (anns) |*a| {
        const leaf = if (a.path.len > 0) a.path[a.path.len - 1].name else "";
        if (!std.mem.eql(u8, leaf, "Suppress")) {
            continue;
        }
        var supp_codes: std.ArrayList([]const u8) = .empty;
        for (a.args) |*arg| {
            if (extractStringLiteral(arg)) |s| {
                try supp_codes.append(allocator, s);
            }
        }
        if (supp_codes.items.len != 0) {
            try out.append(allocator, .{ .span = sp, .codes = try supp_codes.toOwnedSlice(allocator) });
        } else {
            supp_codes.deinit(allocator);
        }
    }
}

/// Deprecation levels.
pub const DeprecationLevel = enum {
    Warning,
    Error,
    Hidden,
};

pub const DeprecationInfo = struct {
    level: DeprecationLevel,
    message: ?[]const u8,
};

pub fn parseDeprecation(anns: []const Annotation) ?DeprecationInfo {
    for (anns) |*a| {
        const leaf = if (a.path.len > 0) a.path[a.path.len - 1].name else "";
        if (!std.mem.eql(u8, leaf, "Deprecated")) {
            continue;
        }
        var info: DeprecationInfo = .{
            .level = .Warning,
            .message = null,
        };
        // Positional first arg is `message: String` unless an explicit
        // `message = ...` named arg is also given. ReplaceWith / level
        // can appear in any position by name.
        var positional_idx: usize = 0;
        for (a.args, 0..) |*arg, i| {
            const name: ?[]const u8 = if (i < a.arg_names.len) a.arg_names[i] else null;
            const slot: []const u8 = blk: {
                if (name) |nm| {
                    if (std.mem.eql(u8, nm, "message")) break :blk "message";
                    if (std.mem.eql(u8, nm, "level")) break :blk "level";
                    if (std.mem.eql(u8, nm, "replaceWith")) break :blk "replaceWith";
                    continue;
                } else {
                    switch (positional_idx) {
                        0 => {
                            positional_idx += 1;
                            break :blk "message";
                        },
                        1 => {
                            positional_idx += 1;
                            break :blk "replaceWith";
                        },
                        2 => {
                            positional_idx += 1;
                            break :blk "level";
                        },
                        else => continue,
                    }
                }
            };
            if (std.mem.eql(u8, slot, "message")) {
                info.message = extractStringLiteral(arg);
            } else if (std.mem.eql(u8, slot, "level")) {
                if (extractDeprecationLevel(arg)) |lv| {
                    info.level = lv;
                }
            }
        }
        return info;
    }
    return null;
}

/// A string-template expression made entirely of literal text yields its
/// text; any interpolation makes it non-constant and returns null. The
/// lexer coalesces contiguous text into a single `Text` part, so a plain
/// literal is one part and an empty literal is zero parts.
pub fn extractStringLiteral(e: *const Expr) ?[]const u8 {
    if (e.* == .StringTemplate) {
        const parts = e.StringTemplate.parts;
        if (parts.len == 0) {
            return "";
        }
        for (parts) |part| {
            if (part != .Text) return null;
        }
        return parts[0].Text;
    }
    return null;
}

pub fn extractDeprecationLevel(e: *const Expr) ?DeprecationLevel {
    const name: []const u8 = switch (e.*) {
        .Path => |p| if (p.segments.len > 0) p.segments[p.segments.len - 1].name else return null,
        .Member => |m| m.name.name,
        else => return null,
    };
    if (std.mem.eql(u8, name, "WARNING")) return .Warning;
    if (std.mem.eql(u8, name, "ERROR")) return .Error;
    if (std.mem.eql(u8, name, "HIDDEN")) return .Hidden;
    return null;
}

pub fn collectDeprecationInfo(
    decls: []const Decl,
    out: *std.StringHashMap(DeprecationInfo),
) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Function => |*f| {
                if (parseDeprecation(f.annotations)) |info| {
                    try out.put(f.name.name, info);
                }
            },
            .Property => |p| {
                if (parseDeprecation(p.annotations)) |info| {
                    try out.put(p.name.name, info);
                }
            },
            .Class => |*c| {
                if (parseDeprecation(c.annotations)) |info| {
                    try out.put(c.name.name, info);
                }
            },
            .Object => |*o| {
                // Object name acts as a value reference; recurse into
                // members for top-level-like decls.
                for (o.members) |*m| {
                    try collectDeprecationInfo(m[0..1], out);
                }
            },
            .TypeAlias => |*a| {
                if (parseDeprecation(a.annotations)) |info| {
                    try out.put(a.name.name, info);
                }
            },
        }
    }
}

pub fn collectDeprecationDiagnostics(
    allocator: Allocator,
    file: *const KotlinFile,
    info: *const std.StringHashMap(DeprecationInfo),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    for (file.decls) |*d| {
        try walkDeclForDeprecation(allocator, d, info, out);
    }
}

pub fn walkDeclForDeprecation(
    allocator: Allocator,
    d: *const Decl,
    info: *const std.StringHashMap(DeprecationInfo),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| {
            if (f.body) |*body| {
                switch (body.*) {
                    .Expr => |*e| try walkExprForDeprecation(allocator, e, info, out),
                    .Block => |*b| try walkBlockForDeprecation(allocator, b, info, out),
                }
            }
            for (f.params) |*p| {
                if (p.default) |def| {
                    try walkExprForDeprecation(allocator, def, info, out);
                }
            }
        },
        .Property => |p| {
            if (p.init) |*init| {
                try walkExprForDeprecation(allocator, init, info, out);
            }
            const accessors = [_]?*const ast.Accessor{
                if (p.getter) |g| g else null,
                if (p.setter) |s| s else null,
            };
            for (accessors) |maybe_acc| {
                const acc = maybe_acc orelse continue;
                switch (acc.body) {
                    .Expr => |*e| try walkExprForDeprecation(allocator, e, info, out),
                    .Block => |*b| try walkBlockForDeprecation(allocator, b, info, out),
                }
            }
        },
        .Class => |*c| {
            for (c.init_blocks) |*ib| {
                try walkBlockForDeprecation(allocator, ib, info, out);
            }
            for (c.primary_params) |*p| {
                if (p.default) |*def| {
                    try walkExprForDeprecation(allocator, def, info, out);
                }
            }
            for (c.secondary_ctors) |*sc| {
                if (sc.body) |*body| {
                    try walkBlockForDeprecation(allocator, body, info, out);
                }
            }
            for (c.enum_entries) |*ee| {
                for (ee.args) |*a| {
                    try walkExprForDeprecation(allocator, a, info, out);
                }
                for (ee.body_members) |*m| {
                    try walkDeclForDeprecation(allocator, m, info, out);
                }
            }
            for (c.members) |*m| {
                try walkDeclForDeprecation(allocator, m, info, out);
            }
        },
        .Object => |*o| {
            for (o.members) |*m| {
                try walkDeclForDeprecation(allocator, m, info, out);
            }
        },
        .TypeAlias => {},
    }
}

pub fn walkBlockForDeprecation(
    allocator: Allocator,
    b: *const Block,
    info: *const std.StringHashMap(DeprecationInfo),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    for (b.stmts) |*s| {
        try walkStmtForDeprecation(allocator, s, info, out);
    }
}

pub fn walkStmtForDeprecation(
    allocator: Allocator,
    s: *const Stmt,
    info: *const std.StringHashMap(DeprecationInfo),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    switch (s.*) {
        .Expr => |*e| try walkExprForDeprecation(allocator, e, info, out),
        .Decl => |*d| try walkDeclForDeprecation(allocator, d, info, out),
        .Assign => |*a| {
            try walkExprForDeprecation(allocator, &a.target, info, out);
            try walkExprForDeprecation(allocator, &a.value, info, out);
        },
        .DestructuringDecl => |*dd| {
            try walkExprForDeprecation(allocator, &dd.init, info, out);
        },
    }
}

// Single recursive walk over every Expr variant.
pub fn walkExprForDeprecation(
    allocator: Allocator,
    e: *const Expr,
    info: *const std.StringHashMap(DeprecationInfo),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1) {
                try emitDeprecationAt(allocator, p.segments[0].name, p.span, info, out);
            }
        },
        .Call => |c| {
            // Recurse into the callee unless it's a bare-name reference
            // to a deprecated symbol — we emit once for the call as a
            // whole using the call's span.
            var emitted_at_call = false;
            if (c.callee.* == .Path and c.callee.Path.segments.len == 1 and
                info.contains(c.callee.Path.segments[0].name))
            {
                try emitDeprecationAt(allocator, c.callee.Path.segments[0].name, c.span, info, out);
                emitted_at_call = true;
            }
            if (!emitted_at_call) {
                try walkExprForDeprecation(allocator, c.callee, info, out);
            }
            for (c.args) |*a| {
                try walkExprForDeprecation(allocator, a, info, out);
            }
        },
        .Binary => |b| {
            try walkExprForDeprecation(allocator, b.lhs, info, out);
            try walkExprForDeprecation(allocator, b.rhs, info, out);
        },
        .Member => |m| try walkExprForDeprecation(allocator, m.receiver, info, out),
        .MemberRef => |m| try walkExprForDeprecation(allocator, m.receiver, info, out),
        .Unary => |x| try walkExprForDeprecation(allocator, x.expr, info, out),
        .Postfix => |x| try walkExprForDeprecation(allocator, x.expr, info, out),
        .As => |x| try walkExprForDeprecation(allocator, x.expr, info, out),
        .IsCheck => |x| try walkExprForDeprecation(allocator, x.expr, info, out),
        .Spread => |x| try walkExprForDeprecation(allocator, x.expr, info, out),
        .Labeled => |x| try walkExprForDeprecation(allocator, x.expr, info, out),
        .Return => |r| {
            if (r.value) |v| try walkExprForDeprecation(allocator, v, info, out);
        },
        .Throw => |x| try walkExprForDeprecation(allocator, x.value, info, out),
        .Index => |x| {
            try walkExprForDeprecation(allocator, x.receiver, info, out);
            for (x.args) |*a| {
                try walkExprForDeprecation(allocator, a, info, out);
            }
        },
        .If => |i| {
            try walkExprForDeprecation(allocator, i.cond, info, out);
            try walkExprForDeprecation(allocator, i.then_branch, info, out);
            if (i.else_branch) |eb| {
                try walkExprForDeprecation(allocator, eb, info, out);
            }
        },
        .While => |w| {
            try walkExprForDeprecation(allocator, w.cond, info, out);
            try walkExprForDeprecation(allocator, w.body, info, out);
        },
        .DoWhile => |w| {
            try walkExprForDeprecation(allocator, w.cond, info, out);
            if (w.body) |b| {
                try walkExprForDeprecation(allocator, b, info, out);
            }
        },
        .For => |f| {
            try walkExprForDeprecation(allocator, f.iter, info, out);
            try walkExprForDeprecation(allocator, f.body, info, out);
        },
        .When => |w| {
            if (w.subject) |s| {
                try walkExprForDeprecation(allocator, s, info, out);
            }
            for (w.branches) |*br| {
                for (br.patterns) |*p| {
                    switch (p.kind) {
                        .Value, .InRange, .NotInRange => |*pe| {
                            try walkExprForDeprecation(allocator, pe, info, out);
                        },
                        else => {},
                    }
                }
                try walkExprForDeprecation(allocator, &br.body, info, out);
            }
        },
        .Try => |t| {
            try walkBlockForDeprecation(allocator, &t.body, info, out);
            for (t.catches) |*c| {
                try walkBlockForDeprecation(allocator, &c.body, info, out);
            }
            if (t.finally) |*f| {
                try walkBlockForDeprecation(allocator, f, info, out);
            }
        },
        .Block => |*blk| try walkBlockForDeprecation(allocator, blk, info, out),
        .Lambda => |lam| try walkBlockForDeprecation(allocator, &lam.body, info, out),
        .AnonFun => |af| {
            if (af.body) |b| {
                switch (b.*) {
                    .Expr => |*e2| try walkExprForDeprecation(allocator, e2, info, out),
                    .Block => |*blk| try walkBlockForDeprecation(allocator, blk, info, out),
                }
            }
        },
        .ObjectExpr => |oe| {
            for (oe.members) |*m| {
                try walkDeclForDeprecation(allocator, m, info, out);
            }
            for (oe.init_blocks) |*ib| {
                try walkBlockForDeprecation(allocator, ib, info, out);
            }
            for (oe.supertype_args) |maybe_args| {
                if (maybe_args) |args| {
                    for (args) |*a| {
                        try walkExprForDeprecation(allocator, a, info, out);
                    }
                }
            }
            for (oe.supertype_delegates) |maybe_d| {
                if (maybe_d) |*dexpr| {
                    try walkExprForDeprecation(allocator, dexpr, info, out);
                }
            }
        },
        .StringTemplate => |st| {
            for (st.parts) |*part| {
                if (part.* == .Interp) {
                    try walkExprForDeprecation(allocator, part.Interp, info, out);
                }
            }
        },
        else => {},
    }
}

pub fn emitDeprecationAt(
    allocator: Allocator,
    name: []const u8,
    sp: Span,
    info: *const std.StringHashMap(DeprecationInfo),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    const d = info.get(name) orelse return;
    const suffix: []const u8 = if (d.message) |m|
        (if (m.len != 0) try std.fmt.allocPrint(allocator, ": {s}", .{m}) else "")
    else
        "";
    const body = try std.fmt.allocPrint(allocator, "`{s}` is deprecated{s}", .{ name, suffix });
    switch (d.level) {
        .Warning => {
            var diag = Diagnostic.warning(body, sp);
            _ = diag.withCode(codes.WARN_DEPRECATED);
            try out.append(allocator, diag);
        },
        .Error, .Hidden => {
            var diag = Diagnostic.err(body, sp);
            _ = diag.withCode(codes.TYPE_DEPRECATED_ERROR);
            try out.append(allocator, diag);
        },
    }
}

/// Annotation target kinds.
pub const AnnotationTarget = enum {
    Class,
    AnnotationClass,
    TypeParameter,
    Property,
    Field,
    LocalVariable,
    ValueParameter,
    Constructor,
    Function,
    PropertyGetter,
    PropertySetter,
    Type,
    Expression,
    File,
    TypeAlias,

    pub fn fromName(name: []const u8) ?AnnotationTarget {
        const map = .{
            .{ "CLASS", AnnotationTarget.Class },
            .{ "ANNOTATION_CLASS", AnnotationTarget.AnnotationClass },
            .{ "TYPE_PARAMETER", AnnotationTarget.TypeParameter },
            .{ "PROPERTY", AnnotationTarget.Property },
            .{ "FIELD", AnnotationTarget.Field },
            .{ "LOCAL_VARIABLE", AnnotationTarget.LocalVariable },
            .{ "VALUE_PARAMETER", AnnotationTarget.ValueParameter },
            .{ "CONSTRUCTOR", AnnotationTarget.Constructor },
            .{ "FUNCTION", AnnotationTarget.Function },
            .{ "PROPERTY_GETTER", AnnotationTarget.PropertyGetter },
            .{ "PROPERTY_SETTER", AnnotationTarget.PropertySetter },
            .{ "TYPE", AnnotationTarget.Type },
            .{ "EXPRESSION", AnnotationTarget.Expression },
            .{ "FILE", AnnotationTarget.File },
            .{ "TYPEALIAS", AnnotationTarget.TypeAlias },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    pub fn display(self: AnnotationTarget) []const u8 {
        return switch (self) {
            .Class => "CLASS",
            .AnnotationClass => "ANNOTATION_CLASS",
            .TypeParameter => "TYPE_PARAMETER",
            .Property => "PROPERTY",
            .Field => "FIELD",
            .LocalVariable => "LOCAL_VARIABLE",
            .ValueParameter => "VALUE_PARAMETER",
            .Constructor => "CONSTRUCTOR",
            .Function => "FUNCTION",
            .PropertyGetter => "PROPERTY_GETTER",
            .PropertySetter => "PROPERTY_SETTER",
            .Type => "TYPE",
            .Expression => "EXPRESSION",
            .File => "FILE",
            .TypeAlias => "TYPEALIAS",
        };
    }
};

pub const AnnotationMeta = struct {
    /// `@Repeatable` set on the annotation class.
    repeatable: bool = false,
    /// `@Target(...)` set on the annotation class. `null` means no
    /// explicit `@Target` — application sites are not restricted.
    targets: ?[]AnnotationTarget = null,
};

pub fn extractAnnotationTargets(
    allocator: Allocator,
    e: *const Expr,
    out: *std.ArrayList(AnnotationTarget),
) Allocator.Error!void {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len > 0) {
                if (AnnotationTarget.fromName(p.segments[p.segments.len - 1].name)) |t| {
                    try out.append(allocator, t);
                }
            }
        },
        .Member => |m| {
            if (AnnotationTarget.fromName(m.name.name)) |t| {
                try out.append(allocator, t);
            }
        },
        else => {},
    }
}

pub const AnnotationWalker = struct {
    ch: *Checker,
    meta: *const std.StringHashMap(AnnotationMeta),

    pub fn walkFile(self: *AnnotationWalker, file: *const KotlinFile) Allocator.Error!void {
        try self.checkSet(&.{}, .File);
        for (file.decls) |*d| {
            try self.walkDecl(d);
        }
    }

    pub fn walkDecl(self: *AnnotationWalker, d: *const Decl) Allocator.Error!void {
        switch (d.*) {
            .Function => |*f| try self.walkFunction(f),
            .Property => |p| try self.walkProperty(p, false),
            .Class => |*c| try self.walkClass(c),
            .Object => |*o| {
                for (o.members) |*m| {
                    try self.walkDecl(m);
                }
            },
            .TypeAlias => |*a| {
                try self.checkSet(a.annotations, .TypeAlias);
            },
        }
    }

    pub fn walkFunction(self: *AnnotationWalker, f: *const Function) Allocator.Error!void {
        try self.checkSet(f.annotations, .Function);
        for (f.type_params) |*tp| {
            try self.checkSet(tp.annotations, .TypeParameter);
        }
        for (f.params) |*p| {
            try self.checkSet(p.annotations, .ValueParameter);
        }
    }

    pub fn walkProperty(self: *AnnotationWalker, p: *const Property, local: bool) Allocator.Error!void {
        const site: AnnotationTarget = if (local) .LocalVariable else .Property;
        try self.checkSet(p.annotations, site);
        if (p.getter) |g| {
            try self.checkSet(g.annotations, .PropertyGetter);
        }
        if (p.setter) |s| {
            try self.checkSet(s.annotations, .PropertySetter);
        }
    }

    pub fn walkClass(self: *AnnotationWalker, c: *const Class) Allocator.Error!void {
        const site: AnnotationTarget = if (c.is_annotation) .AnnotationClass else .Class;
        try self.checkSet(c.annotations, site);
        for (c.type_params) |*tp| {
            try self.checkSet(tp.annotations, .TypeParameter);
        }
        for (c.primary_params) |*p| {
            try self.checkSet(p.annotations, .ValueParameter);
        }
        for (c.secondary_ctors) |*sc| {
            try self.checkSet(sc.annotations, .Constructor);
            for (sc.params) |*p| {
                try self.checkSet(p.annotations, .ValueParameter);
            }
        }
        for (c.enum_entries) |*e| {
            try self.checkSet(e.annotations, .Property);
        }
        for (c.members) |*m| {
            try self.walkDecl(m);
        }
    }

    pub fn checkSet(
        self: *AnnotationWalker,
        anns: []const Annotation,
        site: AnnotationTarget,
    ) Allocator.Error!void {
        const a = self.ch.allocator;
        var counts = std.StringHashMap(Span).init(a);
        defer counts.deinit();
        for (anns) |*ann| {
            const leaf = if (ann.path.len > 0) ann.path[ann.path.len - 1].name else continue;
            // @Target check — only when we know the annotation class and
            // it carries a @Target list.
            if (self.meta.get(leaf)) |m| {
                if (m.targets) |targets| {
                    if (!containsTarget(targets, site)) {
                        const list = try joinTargets(a, targets);
                        const msg = try std.fmt.allocPrint(
                            a,
                            "annotation `@{s}` cannot be applied to {s} — declared @Target list is {{{s}}}",
                            .{ leaf, site.display(), list },
                        );
                        var d = Diagnostic.err(msg, ann.span);
                        _ = d.withCode(codes.TYPE_ANNOTATION_TARGET_MISMATCH);
                        try self.ch.diagnostics.emit(a, d);
                    }
                }
            }
            // Duplicate detection — only when the annotation class is
            // known to be non-repeatable (it lives in `self.meta` and its
            // `repeatable` flag is `false`).
            if (counts.get(leaf)) |prev_span| {
                if (self.meta.get(leaf)) |m| {
                    if (!m.repeatable) {
                        const msg = try std.fmt.allocPrint(
                            a,
                            "annotation `@{s}` is not repeatable but is applied more than once",
                            .{leaf},
                        );
                        var d = Diagnostic.err(msg, ann.span);
                        _ = d.withCode(codes.TYPE_ANNOTATION_NOT_REPEATABLE);
                        _ = try d.withLabel(a, prev_span, "previously applied here");
                        try self.ch.diagnostics.emit(a, d);
                    }
                }
            } else {
                try counts.put(leaf, ann.span);
            }
        }
    }
};

fn containsTarget(targets: []const AnnotationTarget, site: AnnotationTarget) bool {
    for (targets) |t| {
        if (t == site) return true;
    }
    return false;
}

fn joinTargets(allocator: Allocator, targets: []const AnnotationTarget) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    for (targets, 0..) |t, i| {
        if (i > 0) aw.writer.writeAll(", ") catch return error.OutOfMemory;
        aw.writer.writeAll(t.display()) catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}

pub fn collectAnnotationClasses(decls: []const Decl, out: *std.ArrayList(*const Class), allocator: Allocator) Allocator.Error!void {
    for (decls) |*d| {
        if (d.* == .Class) {
            const c = &d.Class;
            if (c.is_annotation) {
                try out.append(allocator, c);
            }
            try collectAnnotationClasses(c.members, out, allocator);
        }
    }
}

pub fn collectAllClasses(decls: []const Decl, out: *std.ArrayList(*const Class), allocator: Allocator) Allocator.Error!void {
    for (decls) |*d| {
        if (d.* == .Class) {
            const c = &d.Class;
            try out.append(allocator, c);
            try collectAllClasses(c.members, out, allocator);
        }
    }
}

pub fn annotationSimpleName(a: *const Annotation) []const u8 {
    if (a.path.len > 0) return a.path[a.path.len - 1].name;
    return "";
}

pub fn collectEnumClasses(decls: []const Decl, out: *std.ArrayList(*const Class), allocator: Allocator) Allocator.Error!void {
    for (decls) |*d| {
        if (d.* == .Class) {
            const c = &d.Class;
            if (c.is_enum) {
                try out.append(allocator, c);
            }
            try collectEnumClasses(c.members, out, allocator);
        }
    }
}

pub fn annotationReachesSelf(
    allocator: Allocator,
    start: []const u8,
    current: []const u8,
    deps: *const std.StringHashMap([][]const u8),
    seen: *std.StringHashMap(void),
) Allocator.Error!bool {
    if ((try seen.getOrPut(current)).found_existing) {
        return false;
    }
    const targets = deps.get(current) orelse return false;
    for (targets) |t| {
        if (std.mem.eql(u8, t, start)) {
            return true;
        }
        if (try annotationReachesSelf(allocator, start, t, deps, seen)) {
            return true;
        }
    }
    return false;
}

pub fn isAnnotationParamType(name: []const u8) bool {
    return helpers.isPrimitiveTypeName(name) or
        std.mem.eql(u8, name, "String") or
        std.mem.eql(u8, name, "KClass") or
        std.mem.eql(u8, name, "kotlin.reflect.KClass") or
        std.mem.eql(u8, name, "Array");
}

test {
    std.testing.refAllDecls(@This());
}
