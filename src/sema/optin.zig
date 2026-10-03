//! Opt-in: a declaration a `@RequiresOptIn` marker class annotates, or one
//! whose value's class a marker annotates, is used only where the use opts
//! in: inside a declaration or file annotated with the marker itself or
//! with `@OptIn(Marker::class)`. An override of a marked member opts in
//! too. Each finding is a `use` census site naming kotlinc's diagnostic, an
//! error or a warning as the marker's level says.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

const sema_mod = @import("sema.zig");
const Sema = sema_mod.Sema;
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const headers = @import("headers.zig");
const members = @import("members.zig");
const census = @import("census.zig");
const declcheck = @import("declcheck.zig");
const decls = @import("decls.zig");

const Allocator = std.mem.Allocator;
const Sym = symbols.Sym;
const TypeId = types.TypeId;
const Span = span.Span;

pub const Level = enum(u8) { warning, err };

/// The level the marker class `cls` asks its opt-in at; null for a class
/// that is not a marker. Found once (`Sema.opt_in_markers`), and read back
/// from a base image for the base's classes.
pub fn markerLevel(s: *Sema, cls: Sym) Allocator.Error!?Level {
    if (s.opt_in_markers.get(cls)) |l| return l;
    if (s.syms.kind(cls) != .class) return null;
    const c = switch (s.syms.get(cls).decl) {
        .class => |d| d orelse return null,
        else => return null,
    };
    var found: ?Level = null;
    if (c.is_annotation) {
        const ctx = headers.ctxOf(s, cls);
        for (c.annotations) |*a| {
            const ac = try headers.annotationClass(s, ctx, a);
            if (ac == .none or !std.mem.eql(u8, s.str(s.syms.classInfo(ac).fqn), "kotlin.RequiresOptIn")) continue;
            found = levelArg(a);
        }
    }
    try s.opt_in_markers.put(s.arena, cls, found);
    return found;
}

/// `@RequiresOptIn(message, level)`: its level, `ERROR` when not written.
fn levelArg(a: *const ast.Annotation) Level {
    for (a.args, 0..) |*arg, i| {
        const named = i < a.arg_names.len and a.arg_names[i] != null;
        if (named and !std.mem.eql(u8, a.arg_names[i].?, "level")) continue;
        if (!named and i != 1) continue;
        const name = switch (arg.*) {
            .Member => |m| m.name.name,
            .Path => |p| p.segments[p.segments.len - 1].name,
            else => continue,
        };
        return if (std.mem.eql(u8, name, "WARNING")) .warning else .err;
    }
    return .err;
}

/// Markers the whole compilation opts in to (`--opt-in=`, kotlinc's
/// `-opt-in`), by qualified name; set before an analysis starts.
var everywhere: [32][]const u8 = undefined;
var everywhere_len: usize = 0;

pub fn optInEverywhere(fqn: []const u8) void {
    if (everywhere_len == everywhere.len) return;
    everywhere[everywhere_len] = fqn;
    everywhere_len += 1;
}

fn optedInEverywhere(s: *Sema, marker: Sym) bool {
    const fqn = s.str(s.syms.classInfo(marker).fqn);
    for (everywhere[0..everywhere_len]) |e| if (std.mem.eql(u8, e, fqn)) return true;
    return false;
}

/// Where a use opts in: a declaration's span and the markers it opts in to.
const Region = struct { start: u32, end: u32, markers: []const Sym };

pub fn checkProgram(s: *Sema) Allocator.Error!void {
    var c = Checker{ .s = s };
    try c.collectRegions();
    for (s.refs.items) |r| {
        const fc = s.fileOf(r.file) orelse continue;
        if (!declcheck.checked(fc)) continue;
        switch (r.kind) {
            .decl, .this_, .return_ => continue,
            else => {},
        }
        if (r.target == .none) continue;
        if (pluginNode(fc, r.node)) continue;
        try c.use(r.file, r.anchor, r.target, true);
    }
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = Sym.from(i);
        const info = s.syms.get(sym);
        const fc = s.fileOf(info.file) orelse continue;
        if (!declcheck.checked(fc) or info.flags.synthetic) continue;
        if (pluginNode(fc, declNode(info.decl))) continue;
        // The types a declaration writes.
        switch (info.decl) {
            .function => |d| {
                if (d.?.receiver_type) |t| try c.typeUse(sym, t);
                if (d.?.return_type) |t| try c.typeUse(sym, t);
            },
            .property, .local_prop => |d| {
                if (d.?.receiver_type) |t| try c.typeUse(sym, t);
                if (d.?.ty) |t| try c.typeUse(sym, t);
            },
            .param => |d| try c.typeUse(sym, &d.?.ty),
            .class_param => |d| if (info.kind == .value_param) try c.typeUse(sym, &d.?.ty),
            .class => |d| if (info.kind == .class) for (d.?.supertypes) |*t| try c.typeUse(sym, t),
            .object => |d| for (d.?.supertypes) |*t| try c.typeUse(sym, t),
            .type_alias => |d| try c.typeUse(sym, &d.?.target),
            else => {},
        }
        if (info.flags.override and (info.kind == .function or info.kind == .property)) try c.override(sym);
    }
}

const Checker = struct {
    s: *Sema,
    /// Per file, the regions that opt in.
    regions: std.AutoHashMapUnmanaged(u32, std.ArrayList(Region)) = .empty,
    /// Where a marker was reported: a site names it once.
    reported: std.AutoHashMapUnmanaged(struct { u32, u32, Sym }, void) = .empty,

    fn collectRegions(self: *Checker) Allocator.Error!void {
        const s = self.s;
        var i: u32 = 1;
        while (i < s.syms.count()) : (i += 1) {
            const sym = Sym.from(i);
            const info = s.syms.get(sym);
            const fc = s.fileOf(info.file) orelse continue;
            if (!declcheck.checked(fc)) continue;
            const whole = fullSpan(info.decl) orelse continue;
            const anns = headers.writtenAnnotations(s, sym, .decl) orelse continue;
            const opted = try self.optedIn(headers.ctxOf(s, sym), anns);
            if (opted.len == 0) continue;
            try self.addRegion(info.file, .{ .start = whole.start, .end = whole.end, .markers = opted });
        }
        // `@file:OptIn(M::class)` opts the whole file in, and `@OptIn` on
        // an expression the expression.
        for (s.files.items, 0..) |fc, fi| {
            if (!declcheck.checked(&fc)) continue;
            const file = fc.ast orelse continue;
            const ctx: headers.TypeCtx = .{ .decl = .none, .file = @intCast(fi) };
            if (file.file_annotations.len != 0) {
                const opted = try self.optedIn(ctx, file.file_annotations);
                if (opted.len != 0) try self.addRegion(@intCast(fi), .{ .start = 0, .end = std.math.maxInt(u32), .markers = opted });
            }
            for (file.annotated_exprs) |ae| {
                const opted = try self.optedIn(ctx, ae.annotations);
                if (opted.len != 0) try self.addRegion(@intCast(fi), .{ .start = ae.span.start, .end = ae.span.end, .markers = opted });
            }
        }
    }

    fn addRegion(self: *Checker, file: u32, r: Region) Allocator.Error!void {
        const gop = try self.regions.getOrPut(self.s.arena, file);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.s.arena, r);
    }

    /// The markers `anns` opt in to: a marker written itself, or one named
    /// by `@OptIn(M::class)`.
    fn optedIn(self: *Checker, ctx: headers.TypeCtx, anns: []const ast.Annotation) Allocator.Error![]const Sym {
        const s = self.s;
        var out: std.ArrayList(Sym) = .empty;
        for (anns) |*a| {
            const c = try headers.annotationClass(s, ctx, a);
            if (c == .none) continue;
            if (try markerLevel(s, c) != null) {
                try out.append(s.arena, c);
                continue;
            }
            if (!std.mem.eql(u8, s.str(s.syms.classInfo(c).fqn), "kotlin.OptIn")) continue;
            for (a.args) |*arg| try self.classLiterals(ctx, arg, &out);
        }
        return out.items;
    }

    fn classLiterals(self: *Checker, ctx: headers.TypeCtx, e: *const ast.Expr, out: *std.ArrayList(Sym)) Allocator.Error!void {
        const s = self.s;
        switch (e.*) {
            .MemberRef => |m| {
                if (!std.mem.eql(u8, m.name.name, "class")) return;
                var segs: std.ArrayList(ast.Ident) = .empty;
                if (!try qualifiedName(s, m.receiver, &segs)) return;
                const c = try headers.resolveQualifiedClassifier(s, ctx, segs.items);
                if (c != .none) try out.append(s.arena, c);
            },
            .Spread => |x| try self.classLiterals(ctx, x.expr, out),
            .Call => |c| for (c.args) |*arg| try self.classLiterals(ctx, arg, out),
            else => {},
        }
    }

    fn optsIn(self: *Checker, file: u32, at: u32, marker: Sym) bool {
        if (optedInEverywhere(self.s, marker)) return true;
        const list = self.regions.get(file) orelse return false;
        for (list.items) |r| {
            if (at < r.start or at >= r.end) continue;
            if (std.mem.indexOfScalar(Sym, r.markers, marker) != null) return true;
        }
        return false;
    }

    /// A use of `target` at `sp`: its own markers (a constructor's class's
    /// too) and, for a value, its class's.
    fn use(self: *Checker, file: u32, sp: Span, target: Sym, value: bool) Allocator.Error!void {
        const s = self.s;
        try self.markersOf(file, sp, target);
        switch (s.syms.kind(target)) {
            .constructor => try self.markersOf(file, sp, s.syms.owner(target)),
            // `EC.make()` names the class whose companion it reaches.
            .class => if (s.syms.classInfo(target).kind == .companion) try self.markersOf(file, sp, s.syms.owner(target)),
            else => {},
        }
        if (!value) return;
        const t: TypeId = switch (s.syms.kind(target)) {
            .local => s.syms.localInfo(target).ty,
            .value_param => try headers.paramType(s, target),
            .property => try headers.propertyType(s, target),
            .function => try headers.returnType(s, target),
            else => .none,
        };
        if (t == .none or s.types.isErr(t)) return;
        const cls = s.types.classSym(try s.types.makeNotNull(t));
        if (cls != .none and s.syms.kind(cls) == .class) try self.markersOf(file, sp, cls);
    }

    fn markersOf(self: *Checker, file: u32, sp: Span, sym: Sym) Allocator.Error!void {
        const s = self.s;
        for (try headers.annotationClasses(s, sym, .decl)) |m| {
            if (m == .none) continue;
            const level = (try markerLevel(s, m)) orelse continue;
            if (self.optsIn(file, sp.start, m)) continue;
            if ((try self.reported.getOrPut(s.arena, .{ file, sp.start, m })).found_existing) continue;
            const name = s.str(s.syms.classInfo(m).fqn);
            const msg = try std.fmt.allocPrint(s.arena, "This declaration needs opt-in. Its usage {s} be marked with '@{s}' or '@OptIn({s}::class)'", .{ if (level == .err) "must" else "should", name, name });
            try self.report(file, sp, if (level == .err) .OPT_IN_USAGE_ERROR else .OPT_IN_USAGE, level, msg);
        }
    }

    fn report(self: *Checker, file: u32, sp: Span, factory: census.Factory, level: Level, msg: []const u8) Allocator.Error!void {
        try self.s.census.reportFacts(.use, file, sp, .{ .message = msg, .factory = factory, .severity = if (level == .err) .err else .warning }, "{s}: {s}", .{ @tagName(factory), msg });
    }

    /// A class named by a type `decl` writes, or in its type arguments.
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
        if (c != .none and s.syms.kind(c) == .class) try self.use(ctx.file, tr.span, c, false);
        for (tr.type_args) |*ta| if (!ta.is_star) try self.typeUse(decl, &ta.ty);
    }

    /// An override of a member a marker annotates opts in to it.
    fn override(self: *Checker, m: Sym) Allocator.Error!void {
        const s = self.s;
        const file = s.syms.get(m).file;
        const at = decls.declSpan(s, m);
        for (try members.overridden(s, m)) |b| {
            for (try headers.annotationClasses(s, b, .decl)) |mk| {
                if (mk == .none) continue;
                const level = (try markerLevel(s, mk)) orelse continue;
                if (self.optsIn(file, at.start, mk)) continue;
                if ((try self.reported.getOrPut(s.arena, .{ file, at.start, mk })).found_existing) continue;
                const name = s.str(s.syms.classInfo(mk).fqn);
                const msg = try std.fmt.allocPrint(s.arena, "Base declaration of supertype '{s}' needs opt-in. The declaration override {s} be annotated with '@{s}' or '@OptIn({s}::class)'", .{ s.str(s.syms.name(s.syms.owner(b))), if (level == .err) "must" else "should", name, name });
                try self.report(file, at, if (level == .err) .OPT_IN_OVERRIDE_ERROR else .OPT_IN_OVERRIDE, level, msg);
            }
        }
    }
};

/// `a.b.C` as its segments: a name, or names joined by `.`.
fn qualifiedName(s: *Sema, e: *const ast.Expr, out: *std.ArrayList(ast.Ident)) Allocator.Error!bool {
    switch (e.*) {
        .Path => |p| try out.appendSlice(s.arena, p.segments),
        .Member => |m| {
            if (m.safe or !try qualifiedName(s, m.receiver, out)) return false;
            try out.append(s.arena, m.name);
        },
        else => return false,
    }
    return true;
}

/// Whether `node` was added to the file after its parse: a compiler
/// plugin's code, which kotlinc checks for no opt-in.
fn pluginNode(fc: *const sema_mod.FileCtx, node: ast.NodeId) bool {
    const file = fc.ast orelse return false;
    if (node == .none or file.parsed_node_count == 0) return false;
    return node.int() >= file.parsed_node_count;
}

fn declNode(d: symbols.Decl) ast.NodeId {
    return switch (d) {
        inline .class, .object, .function, .property, .local_prop, .secondary_ctor, .type_alias, .enum_entry, .param, .class_param => |x| blk: {
            const v = x orelse break :blk .none;
            break :blk if (@hasField(@TypeOf(v.*), "id")) v.id else .none;
        },
        else => .none,
    };
}

/// The whole of a declaration that has its syntax.
fn fullSpan(d: symbols.Decl) ?Span {
    return switch (d) {
        .class => |x| (x orelse return null).span,
        .object => |x| (x orelse return null).span,
        .function => |x| (x orelse return null).span,
        .property, .local_prop => |x| (x orelse return null).span,
        .secondary_ctor => |x| (x orelse return null).span,
        .type_alias => |x| (x orelse return null).span,
        .enum_entry => |x| (x orelse return null).span,
        .lambda => |x| (x orelse return null).span,
        else => null,
    };
}
