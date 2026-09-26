//! What kotlinc refuses in the program's annotations: an annotation class
//! with members, parameters of a type an annotation cannot hold, defaults
//! that are not constant or parameters that cycle back to their class; and
//! an annotation written twice that is not repeatable. Each finding is an
//! `annotation` census site naming kotlinc's diagnostic.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

const sema_mod = @import("sema.zig");
const Sema = sema_mod.Sema;
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const headers = @import("headers.zig");
const census = @import("census.zig");
const declcheck = @import("declcheck.zig");

const Allocator = std.mem.Allocator;
const Sym = symbols.Sym;
const TypeId = types.TypeId;
const Span = span.Span;

/// Checks every annotation class and annotated declaration of the
/// program's files.
pub fn checkProgram(s: *Sema) Allocator.Error!void {
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = Sym.from(i);
        const info = s.syms.get(sym);
        const fc = s.fileOf(info.file) orelse continue;
        if (!declcheck.checked(fc)) continue;
        if (info.flags.synthetic) continue;
        const c = Checker{ .s = s, .file = info.file };
        const anns: []const ast.Annotation = switch (info.decl) {
            .class => |d| blk: {
                if (info.kind == .class and d.is_annotation) try c.annotationClass(sym, d);
                try c.repeated(sym, d.x().primary_ctor_annotations);
                break :blk d.annotations;
            },
            .object => |d| d.annotations,
            .function => |d| d.annotations,
            .property => |d| d.annotations,
            .param => |d| d.annotations,
            .class_param => |d| if (info.kind == .value_param) d.annotations else &.{},
            .secondary_ctor => |d| d.annotations,
            .accessor => |d| d.annotations,
            .enum_entry => |d| d.annotations,
            .type_alias => |d| d.annotations,
            else => &.{},
        };
        try c.repeated(sym, anns);
    }
}

const Checker = struct {
    s: *Sema,
    file: u32,

    fn report(self: Checker, sp: Span, factory: census.Factory, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.s.arena, fmt, args);
        try self.s.census.reportFacts(.annotation, self.file, sp, .{ .message = msg, .factory = factory }, "{s}: {s}", .{ @tagName(factory), msg });
    }

    /// An annotation class holds constants only: `val` parameters of the
    /// types an annotation can carry, with constant defaults, and no other
    /// member.
    fn annotationClass(self: Checker, cls: Sym, c: *const ast.Class) Allocator.Error!void {
        const s = self.s;
        for (c.members) |*m| switch (m.*) {
            .Function => |*f| try self.report(f.name.span, .ANNOTATION_CLASS_MEMBER, "Members are prohibited in annotation classes.", .{}),
            .Property => |p| try self.report(p.name.span, .ANNOTATION_CLASS_MEMBER, "Members are prohibited in annotation classes.", .{}),
            else => {},
        };
        const ctor = s.syms.classInfo(cls).primary_ctor;
        if (ctor == .none) return;
        try headers.functionHeader(s, ctor);
        const params = s.syms.functionInfo(ctor).params;
        if (params.len != c.primary_params.len) return;
        for (params, c.primary_params) |p, *cp| {
            if (cp.property == null) {
                try self.report(cp.span, .MISSING_VAL_ON_ANNOTATION_PARAMETER, "'val' keyword is missing in annotation parameter.", .{});
            } else if (cp.property == true) {
                try self.report(cp.span, .VAR_ANNOTATION_PARAMETER, "An annotation parameter cannot be 'var'.", .{});
            }
            const t = try headers.paramType(s, p);
            if (!s.types.isErr(t)) {
                if (s.types.isNullable(t)) {
                    try self.report(cp.ty.span, .NULLABLE_TYPE_OF_ANNOTATION_MEMBER, "Annotation parameters cannot be nullable.", .{});
                } else if (!try self.memberType(t)) {
                    try self.report(cp.ty.span, .INVALID_TYPE_OF_ANNOTATION_MEMBER, "Invalid type of annotation member.", .{});
                }
            }
            if (cp.default) |*d| {
                if (!try annotationValue(s, self.file, d)) {
                    try self.report(d.span(), .ANNOTATION_PARAMETER_DEFAULT_VALUE_MUST_BE_CONSTANT, "Default value of annotation parameter must be a compile-time constant.", .{});
                }
            }
            if (try self.cycles(cls, t)) {
                try self.report(cp.span, .CYCLE_IN_ANNOTATION_PARAMETER_ERROR, "Cycle formed by one or more annotations and their parameter types.", .{});
            }
        }
    }

    /// Whether an annotation can carry a value of type `t`: a primitive,
    /// unsigned or string value, a `KClass`, an enum entry, another
    /// annotation, or an array of these.
    fn memberType(self: Checker, t: TypeId) Allocator.Error!bool {
        const s = self.s;
        if (s.types.isErr(t)) return true;
        if (s.types.isNullable(t)) return false;
        const ct = switch (s.types.get(t)) {
            .class => |ct| ct,
            else => return false,
        };
        const cls = ct.sym;
        if (declcheck.primitive(s, cls) or declcheck.unsigned(s, cls) or cls == s.builtins.string) return true;
        if (cls == s.builtins.kclass) return true;
        switch (s.syms.classInfo(cls).kind) {
            .enum_class, .annotation => return true,
            else => {},
        }
        if (cls == s.builtins.array) {
            if (ct.args.len != 1 or ct.args[0].ty == .none) return false;
            return self.memberType(ct.args[0].ty);
        }
        const fqn = s.str(s.syms.classInfo(cls).fqn);
        for ([_][]const u8{
            "kotlin.IntArray",     "kotlin.LongArray",  "kotlin.ShortArray",  "kotlin.ByteArray",
            "kotlin.FloatArray",   "kotlin.DoubleArray", "kotlin.CharArray",  "kotlin.BooleanArray",
            "kotlin.UIntArray",    "kotlin.ULongArray", "kotlin.UShortArray", "kotlin.UByteArray",
        }) |a| if (std.mem.eql(u8, fqn, a)) return true;
        return false;
    }

    /// Whether a parameter of type `t` leads back to the annotation class
    /// `cls` through annotation-typed parameters. An array of annotations
    /// breaks the cycle, as kotlinc has it.
    fn cycles(self: Checker, cls: Sym, t: TypeId) Allocator.Error!bool {
        const s = self.s;
        var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
        var work: std.ArrayList(Sym) = .empty;
        const first = annotationOf(s, t);
        if (first == .none) return false;
        try work.append(s.arena, first);
        while (work.pop()) |a| {
            if (a == cls) return true;
            if ((try seen.getOrPut(s.arena, a)).found_existing) continue;
            const ctor = s.syms.classInfo(a).primary_ctor;
            if (ctor == .none) continue;
            try headers.functionHeader(s, ctor);
            for (s.syms.functionInfo(ctor).params) |p| {
                const next = annotationOf(s, try headers.paramType(s, p));
                if (next != .none) try work.append(s.arena, next);
            }
        }
        return false;
    }

    /// An annotation kotlinc does not let a declaration carry twice: one
    /// whose class is not `@Repeatable`, written again with the same
    /// use-site target.
    fn repeated(self: Checker, sym: Sym, anns: []const ast.Annotation) Allocator.Error!void {
        const s = self.s;
        if (anns.len < 2) return;
        const ctx: headers.TypeCtx = .{ .decl = sym, .file = self.file };
        var classes: std.ArrayList(Sym) = .empty;
        for (anns) |*a| try classes.append(s.arena, try headers.annotationClass(s, ctx, a));
        for (anns, 0..) |*a, i| {
            const c = classes.items[i];
            if (c == .none) continue;
            for (anns[0..i], classes.items[0..i]) |*b, bc| {
                if (bc != c or a.use_site != b.use_site) continue;
                if (try repeatable(s, c)) break;
                try self.report(a.span, .REPEATED_ANNOTATION, "This annotation is not repeatable.", .{});
                break;
            }
        }
    }
};

/// The annotation class `t` is, or `.none`.
fn annotationOf(s: *Sema, t: TypeId) Sym {
    if (s.types.isErr(t)) return .none;
    const cls = s.types.classSym(t);
    if (cls == .none or s.syms.kind(cls) != .class) return .none;
    return if (s.syms.classInfo(cls).kind == .annotation) cls else .none;
}

/// Whether an annotation class is marked `kotlin.annotation.Repeatable`
/// (or the JVM's `@JvmRepeatable`).
fn repeatable(s: *Sema, cls: Sym) Allocator.Error!bool {
    const d = switch (s.syms.get(cls).decl) {
        .class => |d| d,
        else => return true,
    };
    const ctx: headers.TypeCtx = .{ .decl = cls, .file = s.syms.get(cls).file };
    for (d.annotations) |*a| {
        const ac = try headers.annotationClass(s, ctx, a);
        if (ac == .none) continue;
        const fqn = s.str(s.syms.classInfo(ac).fqn);
        if (std.mem.eql(u8, fqn, "kotlin.annotation.Repeatable") or std.mem.eql(u8, fqn, "kotlin.jvm.JvmRepeatable")) return true;
    }
    return false;
}

/// Whether an expression is a value an annotation argument may be: a
/// constant, an enum entry, a class literal, another annotation, or an
/// array of these.
pub fn annotationValue(s: *Sema, file: u32, e: *const ast.Expr) Allocator.Error!bool {
    switch (e.*) {
        .MemberRef => |m| if (std.mem.eql(u8, m.name.name, "class")) return true,
        .Path => |p| {
            const target = try declcheck.refTarget(s, file, declcheck.pathAnchor(s, file, p.span, p.segments));
            if (target != .none and s.syms.kind(target) == .enum_entry) return true;
        },
        .Member => |m| {
            const target = try declcheck.refTarget(s, file, m.name.span);
            if (target != .none and s.syms.kind(target) == .enum_entry) return true;
        },
        .Call => |c| {
            const name_span: Span = switch (c.callee.*) {
                .Path => |p| declcheck.pathAnchor(s, file, p.span, p.segments),
                .Member => |m| m.name.span,
                else => return declcheck.constant(s, file, e),
            };
            const target = try declcheck.refTarget(s, file, name_span);
            const array_call = c.collection_literal or (target != .none and arrayFactory(s, target));
            const annotation_call = target != .none and s.syms.kind(target) == .constructor and
                s.syms.classInfo(s.syms.owner(target)).kind == .annotation;
            if (array_call or annotation_call) {
                for (c.args) |*arg| {
                    const inner: *const ast.Expr = switch (arg.*) {
                        .Spread => |sp| sp.expr,
                        else => arg,
                    };
                    if (!try annotationValue(s, file, inner)) return false;
                }
                return true;
            }
        },
        else => {},
    }
    return declcheck.constant(s, file, e);
}

/// `arrayOf`, `intArrayOf` and the rest, and `emptyArray`, of package
/// `kotlin`.
fn arrayFactory(s: *Sema, f: Sym) bool {
    if (s.syms.kind(f) != .function) return false;
    const owner = s.syms.owner(f);
    if (owner == .none or s.syms.kind(owner) != .package) return false;
    if (!std.mem.eql(u8, s.str(s.syms.packageInfo(owner).fqn), "kotlin")) return false;
    const n = s.str(s.syms.name(f));
    return std.mem.endsWith(u8, n, "rrayOf") or std.mem.eql(u8, n, "emptyArray");
}
