//! Declaration-checking phase. Free functions over `*Checker`.
//!
//! Top-level declaration
//! intake, class-info collection, and the per-declaration body / shape
//! checks (override rules, data/enum/value class shapes, supertype
//! validity, lateinit, operator signatures, circular bounds, diamond
//! inheritance, abstract-member implementation).

const std = @import("std");

const span = @import("span");
const ast = @import("ast");
const diagnostics = @import("diagnostics");
const types = @import("types");
const cfa = @import("cfa");

const root = @import("../check.zig");
const helpers = @import("helpers.zig");
const expr = @import("expr.zig");
const expr_calls = @import("expr_calls.zig");
const narrowing = @import("narrowing.zig");
const phases = @import("phases.zig");

const Allocator = std.mem.Allocator;
const Span = span.Span;

const Checker = root.Checker;
const Binding = root.Binding;
const Frame = root.Frame;
const ClassInfo = root.ClassInfo;
const FnSig = root.FnSig;
const MemberSig = root.MemberSig;
const MemberFlags = root.MemberFlags;
const ExtensionSig = root.ExtensionSig;
const ExtensionPropSig = root.ExtensionPropSig;
const TypeAliasInfo = root.TypeAliasInfo;
const TypedSupertype = root.TypedSupertype;
const VisFile = root.VisFile;
const codes = root.codes;

const Diagnostic = diagnostics.Diagnostic;

const Type = types.Type;
const GenericArg = types.GenericArg;
const Variance = types.Variance;
const builtinByName = types.builtinByName;
const convertTypeRefLossy = types.convertTypeRefLossy;

const Decl = ast.Decl;
const Class = ast.Class;
const Function = ast.Function;
const Property = ast.Property;
const ObjectDecl = ast.ObjectDecl;
const Param = ast.Param;
const Accessor = ast.Accessor;
const Block = ast.Block;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const FunctionBody = ast.FunctionBody;
const TypeRef = ast.TypeRef;
const TypeParam = ast.TypeParam;
const WhereBound = ast.WhereBound;
const Visibility = ast.Visibility;
const EnumEntry = ast.EnumEntry;
const SecondaryCtor = ast.SecondaryCtor;
const CtorDelegation = ast.CtorDelegation;

const classNameFromTyperef = helpers.classNameFromTyperef;
const convertTypeRefWithTparams = helpers.convertTypeRefWithTparams;
const substituteTypeParams = helpers.substituteTypeParams;
const describeParams = helpers.describeParams;
const isBuiltinOverridable = helpers.isBuiltinOverridable;
const isPrimitiveTypeName = helpers.isPrimitiveTypeName;
const stmtSpan = helpers.stmtSpan;
const typeDisplay = helpers.typeDisplay;

// ---- diagnostic helpers ------------------------------------------------

fn emitError(self: *Checker, msg: []const u8, sp: Span, code: []const u8) Allocator.Error!void {
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(code);
    try self.diagnostics.emit(self.allocator, d);
}

fn emitWarning(self: *Checker, msg: []const u8, sp: Span, code: []const u8) Allocator.Error!void {
    var d = Diagnostic.warning(msg, sp);
    _ = d.withCode(code);
    try self.diagnostics.emit(self.allocator, d);
}

// ---- env helpers (owned by narrowing.zig) ------------------------------

const pushFrame = narrowing.pushFrame;
const popFrame = narrowing.popFrame;
const currentFrame = narrowing.currentFrame;
const checkBlock = expr.checkBlock;
const checkAssignable = expr_calls.checkAssignable;
const synthesizeClassInitBody = narrowing.synthesizeClassInitBody;
const cfgViaUnassignedAtExit = narrowing.cfgViaUnassignedAtExit;
const checkInlineParamEscape = phases.checkInlineParamEscape;
const checkAnonymousObjectEscape = phases.checkAnonymousObjectEscape;

// ---- top-level declaration intake -------------------------------------

pub fn declareTopLevel(self: *Checker, decl: *const Decl) Allocator.Error!void {
    switch (decl.*) {
        .Function => |*f| {
            const sig = try signatureOf(self, f);
            if (f.receiver_type) |*recv| {
                var return_class: ?[]const u8 = null;
                if (f.return_type) |*rt| return_class = classNameFromTyperef(rt);
                const gop = try self.extensions.getOrPut(recv.name.name);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, .{
                    .name = f.name.name,
                    .sig = sig,
                    .return_class = return_class,
                });
            } else {
                try pushFnSig(self, f.name.name, sig, f.is_expect or f.is_actual);
                {
                    const gop = try self.fn_visibility.getOrPut(f.name.name);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.allocator, .{ .visibility = f.visibility, .file = f.name.span.file });
                }
                {
                    const gop = try self.fn_annotations.getOrPut(f.name.name);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.allocator, f.annotations);
                }
            }
        },
        .Property => |p| {
            const ty = if (p.ty) |*pt| try convertTypeRefLossy(self.allocator, pt) else Type.Unresolved;
            const cn = if (p.ty) |*pt| classNameFromTyperef(pt) else null;
            if (p.receiver_type) |*recv| {
                const gop = try self.extension_properties.getOrPut(recv.name.name);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, .{
                    .name = p.name.name,
                    .ty = ty,
                    .mutable = p.mutable,
                    .return_class = cn,
                });
            } else {
                try self.frames.items[0].bindings.put(p.name.name, .{
                    .ty = ty,
                    .mutable = p.mutable,
                    .decl_span = p.name.span,
                    .class_name = cn,
                    .decl_type_name = null,
                });
                try self.prop_visibility.put(p.name.name, .{ .visibility = p.visibility, .file = p.name.span.file });
                if (p.setter_visibility) |sv| {
                    try self.setter_visibility.put(p.name.name, .{ .visibility = sv, .file = p.name.span.file });
                } else if (p.setter) |*setter| {
                    if (setter.visibility) |sv| {
                        try self.setter_visibility.put(p.name.name, .{ .visibility = sv, .file = p.name.span.file });
                    }
                }
                try self.prop_annotations.put(p.name.name, p.annotations);
            }
        },
        .Class => |*c| {
            const info = try classInfo(self, c);
            try self.classes.put(c.name.name, info);
        },
        .Object => |*o| {
            // Treat object singleton like a class with no ctor.
            var info = ClassInfo.init(self.allocator);
            info.is_object = true;
            info.decl_file = o.name.span.file;
            try collectMembers(self, o.members, &info);
            for (o.supertypes) |*s| {
                try info.supertypes.append(self.allocator, s.name.name);
            }
            try self.classes.put(o.name.name, info);
            // Bind the singleton name itself so `Foo.bar` reads pass.
            try self.frames.items[0].bindings.put(o.name.name, .{
                .ty = Type.Unresolved,
                .mutable = false,
                .decl_span = o.name.span,
                .class_name = o.name.name,
                .decl_type_name = null,
            });
        },
        .TypeAlias => |*a| {
            const tp_names = try self.allocator.alloc([]const u8, a.type_params.len);
            for (a.type_params, tp_names) |*p, *dst| dst.* = p.name.name;
            try self.aliases.put(a.name.name, .{
                .type_params = tp_names,
                .target = a.target,
                .name_span = a.name.span,
            });
        },
    }
}

/// Materializes the per-type-parameter upper-bound list for a
/// declaration. The inline `<T : Foo>` bound contributes one entry;
/// every `where T : ...` clause that names the parameter appends
/// another. Bounds that lower to `Type.Unresolved` are dropped because
/// they would render the subtype check vacuously true.
pub fn collectTypeParamBounds(
    self: *Checker,
    type_params: []const TypeParam,
    where_bounds: []const WhereBound,
) Allocator.Error!struct { names: [][]const u8, bounds: [][]Type } {
    var names: std.ArrayList([]const u8) = .empty;
    var bounds: std.ArrayList([]Type) = .empty;
    for (type_params) |*tp| {
        try names.append(self.allocator, tp.name.name);
        var v: std.ArrayList(Type) = .empty;
        if (tp.upper_bound) |*b| {
            const ty = try convertTypeRefLossy(self.allocator, b);
            if (ty != .Unresolved) {
                try v.append(self.allocator, ty);
            }
        }
        for (where_bounds) |*wb| {
            if (std.mem.eql(u8, wb.name.name, tp.name.name)) {
                const ty = try convertTypeRefLossy(self.allocator, &wb.bound);
                if (ty != .Unresolved) {
                    try v.append(self.allocator, ty);
                }
            }
        }
        try bounds.append(self.allocator, try v.toOwnedSlice(self.allocator));
    }
    return .{
        .names = try names.toOwnedSlice(self.allocator),
        .bounds = try bounds.toOwnedSlice(self.allocator),
    };
}

/// Register a top-level function signature under `name`. An
/// `expect`/`actual` pair (or the same declaration visible from two
/// curated source roots) is one logical function, not an overload set:
/// when the function is `expect`/`actual` and an identical parameter
/// signature is already registered, skip the duplicate so overload
/// resolution does not see a spurious `(T), (T)` ambiguity.
pub fn pushFnSig(self: *Checker, name: []const u8, sig: FnSig, expect_or_actual: bool) Allocator.Error!void {
    const gop = try self.fns.getOrPut(name);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    const entry = gop.value_ptr;
    if (expect_or_actual) {
        const key = try describeParams(self.allocator, sig.params);
        defer self.allocator.free(key);
        for (entry.items) |*e| {
            if (e.params.len == sig.params.len) {
                const ek = try describeParams(self.allocator, e.params);
                defer self.allocator.free(ek);
                if (std.mem.eql(u8, ek, key)) return;
            }
        }
    }
    try entry.append(self.allocator, sig);
}

pub fn signatureOf(self: *Checker, f: *const Function) Allocator.Error!FnSig {
    var tparams = std.StringHashMap(void).init(self.allocator);
    defer tparams.deinit();
    for (f.type_params) |*tp| try tparams.put(tp.name.name, {});

    const params = try self.allocator.alloc(Type, f.params.len);
    const has_default = try self.allocator.alloc(bool, f.params.len);
    const names = try self.allocator.alloc([]const u8, f.params.len);
    const is_vararg = try self.allocator.alloc(bool, f.params.len);
    for (f.params, 0..) |*p, i| {
        params[i] = try convertTypeRefWithTparams(self.allocator, &p.ty, &tparams);
        has_default[i] = p.default != null;
        names[i] = p.name.name;
        is_vararg[i] = p.is_vararg;
    }
    const return_ty = if (f.return_type) |*rt|
        try convertTypeRefWithTparams(self.allocator, rt, &tparams)
    else
        Type.Unit;
    const param_class_names = try self.allocator.alloc(?[]const u8, f.params.len);
    for (f.params, 0..) |*p, i| param_class_names[i] = classNameFromTyperef(&p.ty);
    const bounds = try collectTypeParamBounds(self, f.type_params, f.where_bounds);
    const is_crossinline_param = try self.allocator.alloc(bool, f.params.len);
    if (f.is_inline) {
        for (f.params, 0..) |*p, i| is_crossinline_param[i] = p.is_crossinline;
    } else {
        @memset(is_crossinline_param, false);
    }
    return .{
        .params = params,
        .has_default = has_default,
        .param_names = names,
        .is_vararg = is_vararg,
        .return_ty = return_ty,
        .is_infix = f.is_infix,
        .type_param_count = f.type_params.len,
        .type_param_names = bounds.names,
        .type_param_bounds = bounds.bounds,
        .param_class_names = param_class_names,
        .decl_span = f.name.span,
        .is_suspend = f.is_suspend,
        .is_crossinline_param = is_crossinline_param,
    };
}

pub fn classInfo(self: *Checker, c: *const Class) Allocator.Error!ClassInfo {
    var info = ClassInfo.init(self.allocator);
    info.is_abstract = c.is_abstract;
    info.is_interface = c.is_interface;
    info.is_sealed = c.is_sealed;
    info.is_enum = c.is_enum;
    info.is_open = c.is_open or c.is_abstract or c.is_sealed;
    info.has_secondary_ctors = c.secondary_ctors.len != 0;
    info.decl_visibility = c.visibility;
    info.decl_file = c.name.span.file;
    info.primary_ctor_visibility = c.primary_ctor_visibility;
    // Primary ctor params that are properties become members.
    for (c.primary_params) |*p| {
        const ty = try convertTypeRefLossy(self.allocator, &p.ty);
        if (p.property) |mutable| {
            try info.members.put(p.name.name, try ty.clone(self.allocator));
            try info.member_mutable.put(p.name.name, mutable);
            try info.concrete_members.append(self.allocator, p.name.name);
            if (classNameFromTyperef(&p.ty)) |cn| {
                try info.member_class.put(p.name.name, cn);
            }
            try info.member_visibility.put(p.name.name, p.visibility);
            try info.member_sigs.put(p.name.name, .{ .Property = .{
                .ty = try ty.clone(self.allocator),
                .mutable = mutable,
                .visibility = p.visibility,
            } });
        }
    }
    const ctor_bounds = try collectTypeParamBounds(self, c.type_params, c.where_bounds);
    const ctor_params = try self.allocator.alloc(Type, c.primary_params.len);
    const ctor_has_default = try self.allocator.alloc(bool, c.primary_params.len);
    const ctor_param_names = try self.allocator.alloc([]const u8, c.primary_params.len);
    const ctor_is_vararg = try self.allocator.alloc(bool, c.primary_params.len);
    const ctor_param_class_names = try self.allocator.alloc(?[]const u8, c.primary_params.len);
    const ctor_is_crossinline = try self.allocator.alloc(bool, c.primary_params.len);
    for (c.primary_params, 0..) |*p, i| {
        ctor_params[i] = try convertTypeRefLossy(self.allocator, &p.ty);
        ctor_has_default[i] = p.default != null;
        ctor_param_names[i] = p.name.name;
        ctor_is_vararg[i] = p.is_vararg;
        ctor_param_class_names[i] = classNameFromTyperef(&p.ty);
        ctor_is_crossinline[i] = false;
    }
    const ctor_sig = FnSig{
        .params = ctor_params,
        .has_default = ctor_has_default,
        .param_names = ctor_param_names,
        .is_vararg = ctor_is_vararg,
        .return_ty = Type.Unresolved,
        .is_infix = false,
        .type_param_count = c.type_params.len,
        .type_param_names = ctor_bounds.names,
        .type_param_bounds = ctor_bounds.bounds,
        .param_class_names = ctor_param_class_names,
        .decl_span = null,
        .is_suspend = false,
        .is_crossinline_param = ctor_is_crossinline,
    };
    if (c.primary_params.len != 0 or !c.is_interface) {
        info.ctor = ctor_sig;
    }
    try collectMembers(self, c.members, &info);
    {
        for (c.type_params) |*tp| {
            try info.type_param_names.append(self.allocator, tp.name.name);
        }
    }
    for (c.supertypes) |*s| {
        try info.supertypes.append(self.allocator, s.name.name);
        const type_args = try self.allocator.alloc(Type, s.type_args.len);
        for (s.type_args, 0..) |*ta, i| {
            type_args[i] = if (ta.is_star) Type.Unresolved else try convertTypeRefLossy(self.allocator, &ta.ty);
        }
        try info.typed_supertypes.append(self.allocator, .{ .name = s.name.name, .args = type_args });
    }
    return info;
}

/// GADT supertype walk: given a `subclass` and a `target` class name,
/// find the type-arg list `subclass` declares for `target` in its
/// supertype chain. Returns the args when a match is found anywhere
/// along the transitive supertype chain; `null` when the chain has no
/// link to `target`. The result owns its heap data.
pub fn walkSupertypeArgs(self: *Checker, subclass: []const u8, target: []const u8) Allocator.Error!?[]Type {
    const info = self.classes.get(subclass) orelse return null;
    if (std.mem.eql(u8, subclass, target)) {
        const out = try self.allocator.alloc(Type, info.type_param_names.items.len);
        for (info.type_param_names.items, 0..) |n, i| out[i] = .{ .TypeParam = try self.allocator.dupe(u8, n) };
        return out;
    }
    for (info.typed_supertypes.items) |s| {
        if (std.mem.eql(u8, s.name, target)) {
            const out = try self.allocator.alloc(Type, s.args.len);
            for (s.args, 0..) |*a, i| out[i] = try a.clone(self.allocator);
            return out;
        }
        if (try walkSupertypeArgs(self, s.name, target)) |deeper| {
            defer self.allocator.free(deeper);
            const mid_info = self.classes.get(s.name) orelse return null;
            var subst = std.StringHashMap(Type).init(self.allocator);
            defer subst.deinit();
            const n = @min(mid_info.type_param_names.items.len, s.args.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try subst.put(mid_info.type_param_names.items[i], s.args[i]);
            }
            const substituted = try self.allocator.alloc(Type, deeper.len);
            for (deeper, 0..) |*t, j| substituted[j] = try substituteTypeParams(self.allocator, t, &subst);
            for (deeper) |*t| {
                var tt = t.*;
                tt.deinit(self.allocator);
            }
            return substituted;
        }
    }
    return null;
}

pub fn collectMembers(self: *Checker, members: []const Decl, info: *ClassInfo) Allocator.Error!void {
    for (members) |*m| {
        switch (m.*) {
            .Function => |*f| {
                const sig = try signatureOf(self, f);
                {
                    const gop = try info.member_methods.getOrPut(f.name.name);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.allocator, sig);
                }
                const param_types = try self.allocator.alloc(Type, sig.params.len);
                for (sig.params, 0..) |*p, i| param_types[i] = try p.clone(self.allocator);
                try info.member_sigs.put(f.name.name, .{ .Function = .{
                    .param_types = param_types,
                    .return_ty = try sig.return_ty.clone(self.allocator),
                    .visibility = f.visibility,
                    .is_suspend = f.is_suspend,
                } });
                const ret = try self.allocator.create(Type);
                ret.* = try sig.return_ty.clone(self.allocator);
                const fn_params = try self.allocator.alloc(Type, sig.params.len);
                for (sig.params, 0..) |*p, i| fn_params[i] = try p.clone(self.allocator);
                const ty = Type{ .Function = .{
                    .params = fn_params,
                    .return_type = ret,
                    .is_suspend = f.is_suspend,
                } };
                try info.members.put(f.name.name, ty);
                if (f.return_type) |*rt| {
                    if (classNameFromTyperef(rt)) |cn| try info.member_class.put(f.name.name, cn);
                }
                // Interface members and abstract members are implicitly
                // `open` in Kotlin.
                const implicit_open = info.is_interface or info.is_abstract or f.is_abstract;
                try info.member_flags.put(f.name.name, .{
                    .is_open = f.is_open or implicit_open,
                    .is_override = f.is_override,
                    .is_abstract = f.is_abstract,
                    .is_operator = f.is_operator,
                    .is_infix = f.is_infix,
                    .has_default_body = f.body != null and !f.is_abstract,
                });
                if (f.is_abstract) {
                    try info.abstract_members.append(self.allocator, f.name.name);
                } else {
                    try info.concrete_members.append(self.allocator, f.name.name);
                }
                try info.member_visibility.put(f.name.name, f.visibility);
            },
            .Property => |p| {
                const ty = if (p.ty) |*pt| try convertTypeRefLossy(self.allocator, pt) else Type.Unresolved;
                try info.member_sigs.put(p.name.name, .{ .Property = .{
                    .ty = try ty.clone(self.allocator),
                    .mutable = p.mutable,
                    .visibility = p.visibility,
                } });
                try info.members.put(p.name.name, ty);
                try info.member_mutable.put(p.name.name, p.mutable);
                if (p.ty) |*pt| {
                    if (classNameFromTyperef(pt)) |cn| try info.member_class.put(p.name.name, cn);
                }
                const implicit_open = info.is_interface or info.is_abstract or p.is_abstract or p.is_override;
                try info.member_flags.put(p.name.name, .{
                    .is_open = p.is_open or implicit_open,
                    .is_override = p.is_override,
                    .is_abstract = p.is_abstract,
                    .is_operator = false,
                    .is_infix = false,
                    .has_default_body = false,
                });
                if (p.is_abstract) {
                    try info.abstract_members.append(self.allocator, p.name.name);
                } else {
                    try info.concrete_members.append(self.allocator, p.name.name);
                }
                try info.member_visibility.put(p.name.name, p.visibility);
            },
            .Class, .Object, .TypeAlias => {},
        }
    }
}

// ---- decl bodies ------------------------------------------------------

pub fn checkDecl(self: *Checker, decl: *const Decl) Allocator.Error!void {
    switch (decl.*) {
        .Function => |*f| try checkFunction(self, f),
        .Property => |p| try checkTopLevelProperty(self, p),
        .Class => |*c| try checkClass(self, c),
        .Object => |*o| try checkObject(self, o),
        .TypeAlias => {},
    }
}

pub fn checkTopLevelProperty(self: *Checker, p: *const Property) Allocator.Error!void {
    if (p.init) |*init| {
        var annot: ?Type = if (p.ty) |*pt| try convertTypeRefLossy(self.allocator, pt) else null;
        defer if (annot) |*a| a.deinit(self.allocator);
        var init_ty = try self.checkExpr(init, if (annot) |*a| a else null);
        defer init_ty.deinit(self.allocator);
        if (annot) |*a| {
            try checkAssignable(self, &init_ty, a, init.span());
        } else {
            // Infer from initializer.
            if (self.frames.items[0].bindings.getPtr(p.name.name)) |b| {
                if (b.ty == .Unresolved) {
                    b.ty = try init_ty.clone(self.allocator);
                }
            }
        }
    }
    if (p.delegate) |*d| {
        var dt = try self.checkExpr(d, null);
        dt.deinit(self.allocator);
        try checkDelegateOperator(self, p, d);
    }
    try checkLateinit(self, p);
    try checkAccessorReturnTypes(self, p);
}

/// Spec ch.9: validate the signature of an `operator fun` declaration
/// against its name. Each well-known operator name has a fixed shape
/// (arity / return type). T0088 is a warning so existing programs keep
/// running while authors fix shapes.
pub fn checkOperatorSignature(self: *Checker, f: *const Function) Allocator.Error!void {
    if (!f.is_operator) return;
    const name = f.name.name;
    if (f.is_suspend and (std.mem.eql(u8, name, "getValue") or std.mem.eql(u8, name, "setValue") or std.mem.eql(u8, name, "provideDelegate"))) {
        const msg = try std.fmt.allocPrint(self.allocator, "delegation operator `{s}` cannot be `suspend`", .{name});
        try emitError(self, msg, f.name.span, codes.TYPE_SUSPEND_NOT_ALLOWED);
    }
    const n = f.params.len;
    var expected: ?[]const u8 = null;
    var returns_bool = false;
    var returns_int = false;
    if (eqAny(name, &.{ "inc", "dec", "unaryPlus", "unaryMinus", "not" })) {
        expected = "0 args";
    } else if (eqAny(name, &.{ "iterator", "hasNext", "next" })) {
        expected = "0 args";
        returns_bool = std.mem.eql(u8, name, "hasNext");
    } else if (eqAny(name, &.{ "plus", "minus", "times", "div", "rem", "rangeTo", "rangeUntil", "plusAssign", "minusAssign", "timesAssign", "divAssign", "remAssign" })) {
        expected = "1 arg";
    } else if (std.mem.eql(u8, name, "compareTo")) {
        expected = "1 arg";
        returns_int = true;
    } else if (eqAny(name, &.{ "contains", "equals" })) {
        expected = "1 arg";
        returns_bool = true;
    } else if (std.mem.eql(u8, name, "get")) {
        if (n < 1) try emitOpSig(self, f, "`get` operator requires at least 1 argument");
    } else if (std.mem.eql(u8, name, "set")) {
        if (n < 2) try emitOpSig(self, f, "`set` operator requires at least 2 arguments (last is the value)");
    } else if (eqAny(name, &.{ "invoke", "componentN" })) {
        // no checks
    } else if (eqAny(name, &.{ "provideDelegate", "getValue" })) {
        expected = "2 args";
    } else if (std.mem.eql(u8, name, "setValue")) {
        expected = "3 args";
    } else {
        // componentN: digits after "component"
        if (std.mem.startsWith(u8, name, "component")) {
            const rest = name["component".len..];
            if (rest.len != 0 and allAsciiDigit(rest) and n != 0) {
                const msg = try std.fmt.allocPrint(self.allocator, "`{s}` operator must take no arguments", .{name});
                try emitOpSig(self, f, msg);
            }
        }
    }
    if (expected) |shape| {
        const want: ?usize = if (std.mem.eql(u8, shape, "0 args"))
            0
        else if (std.mem.eql(u8, shape, "1 arg"))
            1
        else if (std.mem.eql(u8, shape, "2 args"))
            2
        else if (std.mem.eql(u8, shape, "3 args"))
            3
        else
            null;
        if (want) |w| {
            if (n != w) {
                const msg = try std.fmt.allocPrint(self.allocator, "`{s}` operator must take exactly {s}, got {d}", .{ name, shape, n });
                try emitOpSig(self, f, msg);
            }
        }
    }
    if (returns_bool) {
        if (f.return_type) |*rt| {
            var ty = try convertTypeRefLossy(self.allocator, rt);
            defer ty.deinit(self.allocator);
            const nn = ty.nonNull();
            if (!(nn.* == .Boolean or nn.* == .Unresolved)) {
                const msg = try std.fmt.allocPrint(self.allocator, "`{s}` operator must return Boolean", .{name});
                try emitOpSig(self, f, msg);
            }
        }
    }
    if (returns_int) {
        if (f.return_type) |*rt| {
            var ty = try convertTypeRefLossy(self.allocator, rt);
            defer ty.deinit(self.allocator);
            const nn = ty.nonNull();
            if (!(nn.* == .Int or nn.* == .Unresolved)) {
                const msg = try std.fmt.allocPrint(self.allocator, "`{s}` operator must return Int", .{name});
                try emitOpSig(self, f, msg);
            }
        }
    }
}

fn eqAny(name: []const u8, options: []const []const u8) bool {
    for (options) |o| {
        if (std.mem.eql(u8, name, o)) return true;
    }
    return false;
}

fn allAsciiDigit(s: []const u8) bool {
    for (s) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// Head name of a type reference — i.e. the top-level classifier name,
/// ignoring generic args.
pub fn headName(t: *const TypeRef) []const u8 {
    return t.name.name;
}

/// Detects cycles in the type-parameter bound graph for a declaration.
pub fn checkCircularBounds(
    self: *Checker,
    type_params: []const TypeParam,
    where_bounds: []const WhereBound,
) Allocator.Error!void {
    if (type_params.len == 0) return;
    var tp_set = std.StringHashMap(void).init(self.allocator);
    defer tp_set.deinit();
    for (type_params) |*tp| try tp_set.put(tp.name.name, {});

    var graph = std.StringHashMap(std.ArrayList([]const u8)).init(self.allocator);
    defer {
        var it = graph.valueIterator();
        while (it.next()) |v| v.deinit(self.allocator);
        graph.deinit();
    }
    var spans = std.StringHashMap(Span).init(self.allocator);
    defer spans.deinit();

    for (type_params) |*tp| {
        try spans.put(tp.name.name, tp.name.span);
        const gop = try graph.getOrPut(tp.name.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (tp.upper_bound) |*b| {
            const head = headName(b);
            if (tp_set.contains(head)) {
                const g = try graph.getOrPut(tp.name.name);
                if (!g.found_existing) g.value_ptr.* = .empty;
                try g.value_ptr.append(self.allocator, head);
            }
        }
    }
    for (where_bounds) |*wb| {
        if (!tp_set.contains(wb.name.name)) continue;
        const head = headName(&wb.bound);
        if (tp_set.contains(head)) {
            const g = try graph.getOrPut(wb.name.name);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(self.allocator, head);
        }
    }
    // Tarjan-lite: DFS, mark gray/black, any back-edge to gray is a cycle.
    var color = std.StringHashMap(u8).init(self.allocator);
    defer color.deinit();
    for (type_params) |*tp| {
        if ((color.get(tp.name.name) orelse 0) != 0) continue;
        if (try findCycleDfs(self, tp.name.name, &graph, &color)) |start| {
            const sp = spans.get(start) orelse tp.name.span;
            const msg = try std.fmt.allocPrint(self.allocator, "type parameter `{s}` has a circular bound", .{start});
            try emitError(self, msg, sp, codes.TYPE_CIRCULAR_TYPE_BOUND);
            return;
        }
    }
}

pub fn findCycleDfs(
    self: *Checker,
    node: []const u8,
    graph: *std.StringHashMap(std.ArrayList([]const u8)),
    color: *std.StringHashMap(u8),
) Allocator.Error!?[]const u8 {
    try color.put(node, 1);
    if (graph.get(node)) |succs| {
        for (succs.items) |s| {
            switch (color.get(s) orelse 0) {
                1 => return s,
                0 => {
                    if (try findCycleDfs(self, s, graph, color)) |c| return c;
                },
                else => {},
            }
        }
    }
    try color.put(node, 2);
    return null;
}

/// Validates that each user-supplied explicit type argument satisfies
/// the declared upper bounds of the corresponding type parameter.
pub fn checkTypeArgBounds(self: *Checker, sig: *const FnSig, type_args: []const TypeRef) Allocator.Error!void {
    if (type_args.len != sig.type_param_count or sig.type_param_bounds.len == 0) return;
    const supplied = try self.allocator.alloc(Type, type_args.len);
    defer {
        for (supplied) |*t| t.deinit(self.allocator);
        self.allocator.free(supplied);
    }
    for (type_args, 0..) |*ta, i| supplied[i] = try convertTypeRefLossy(self.allocator, ta);

    var subst = std.StringHashMap(Type).init(self.allocator);
    defer subst.deinit();
    for (sig.type_param_names, 0..) |nm, i| {
        if (i < supplied.len) try subst.put(nm, supplied[i]);
    }
    for (sig.type_param_bounds, 0..) |bounds, i| {
        if (bounds.len == 0) continue;
        if (i >= supplied.len) continue;
        const arg_ty = &supplied[i];
        for (bounds) |*b| {
            var bound = try substituteTypeParams(self.allocator, b, &subst);
            defer bound.deinit(self.allocator);
            if (bound == .Unresolved) continue;
            if (!arg_ty.isSubtypeOf(bound)) {
                const sp = type_args[i].span;
                const arg_s = try arg_ty.toString(self.allocator);
                defer self.allocator.free(arg_s);
                const bound_s = try bound.toString(self.allocator);
                defer self.allocator.free(bound_s);
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "type argument `{s}` does not satisfy upper bound `{s}` on `{s}`",
                    .{ arg_s, bound_s, sig.type_param_names[i] },
                );
                try emitError(self, msg, sp, codes.TYPE_BOUND_NOT_SATISFIED);
                break;
            }
        }
    }
}

pub fn emitOpSig(self: *Checker, f: *const Function, msg: []const u8) Allocator.Error!void {
    try emitWarning(self, msg, f.name.span, codes.TYPE_OPERATOR_SIGNATURE_MISMATCH);
}

pub fn checkFunction(self: *Checker, f: *const Function) Allocator.Error!void {
    try checkInlineParamEscape(self, f);
    try checkAnonymousObjectEscape(self, f);
    try checkOperatorSignature(self, f);
    try checkCircularBounds(self, f.type_params, f.where_bounds);
    try pushFrame(self);
    for (f.params) |*p| {
        const ty = try convertTypeRefLossy(self.allocator, &p.ty);
        const cn = classNameFromTyperef(&p.ty);
        const decl_type_name: ?[]const u8 = if (builtinByName(p.ty.name.name) == null) p.ty.name.name else null;
        try currentFrame(self).bindings.put(p.name.name, .{
            .ty = ty,
            .mutable = false,
            .decl_span = p.name.span,
            .class_name = cn,
            .decl_type_name = decl_type_name,
        });
        if (p.default) |default| {
            var want = try convertTypeRefLossy(self.allocator, &p.ty);
            defer want.deinit(self.allocator);
            var dty = try self.checkExpr(default, &want);
            defer dty.deinit(self.allocator);
            try checkAssignable(self, &dty, &want, default.span());
        }
    }
    var declared_return = if (f.return_type) |*rt| try convertTypeRefLossy(self.allocator, rt) else Type.Unit;
    defer declared_return.deinit(self.allocator);

    try self.fn_return_stack.append(self.allocator, try declared_return.clone(self.allocator));
    try self.label_stack.append(self.allocator, f.name.name);
    const is_public_inline = f.is_inline and f.visibility == .Public;
    try self.public_inline_stack.append(self.allocator, is_public_inline);
    try self.suspend_context_stack.append(self.allocator, f.is_suspend);
    var reified = std.StringHashMap(void).init(self.allocator);
    for (f.type_params) |*tp| {
        if (tp.is_reified) try reified.put(tp.name.name, {});
    }
    try self.reified_type_params.append(self.allocator, reified);
    var all_tps = std.StringHashMap(void).init(self.allocator);
    for (f.type_params) |*tp| try all_tps.put(tp.name.name, {});
    try self.type_params_in_scope.append(self.allocator, all_tps);

    if (f.body) |*body| {
        try checkFunctionBody(self, f, body, &declared_return);
    }

    {
        var t = self.fn_return_stack.pop().?;
        t.deinit(self.allocator);
    }
    _ = self.label_stack.pop();
    _ = self.public_inline_stack.pop();
    _ = self.suspend_context_stack.pop();
    {
        var s = self.reified_type_params.pop().?;
        s.deinit();
    }
    {
        var s = self.type_params_in_scope.pop().?;
        s.deinit();
    }
    popFrame(self);
    if (f.body != null) {
        _ = self.cfg_fn_stack.pop();
    }
}

fn checkFunctionBody(self: *Checker, f: *const Function, body: *const FunctionBody, declared_return: *const Type) Allocator.Error!void {
    // Build a CFG for the body alongside type checking.
    var body_block: Block = switch (body.*) {
        .Block => |b| b,
        .Expr => |e| Block{
            .stmts = blk: {
                const s = try self.allocator.alloc(Stmt, 1);
                s[0] = .{ .Expr = e };
                break :blk s;
            },
            .span = e.span(),
        },
    };
    var lowered = try cfa.lower.lowerFunction(self.allocator, &body_block, f.span);
    try cfa.dataflow.inferKillDataFlow(self.allocator, &lowered.cfg);
    try self.cfgs.put(f.span, lowered.cfg);
    const low = try self.allocator.create(root.Lowered);
    low.* = lowered;
    try self.lowerings.put(f.span, low);
    try self.cfg_fn_stack.append(self.allocator, f.span);

    switch (body.*) {
        .Block => |*b| {
            var body_ty = try checkBlock(self, b, declared_return);
            defer body_ty.deinit(self.allocator);
            // Block-body functions with a declared non-`Unit` / non-`Nothing`
            // return require every path to terminate. Defer to the CFG.
            const normal_exit_reachable = blk: {
                const scratch = narrowing.queryScratch(self);
                // Reachability only consults divergent (`Nothing`-typed)
                // spans in this function's CFG, so feed it the function's
                // bucket rather than a snapshot of the whole types map.
                var type_map = cfa.analyses.reachable.TypeMap.init(scratch);
                if (self.nothing_by_fn.getPtr(f.span)) |bucket| {
                    var it = bucket.keyIterator();
                    while (it.next()) |sp| {
                        if (!self.nothing_spans.contains(sp.*)) continue;
                        try type_map.put(.{ .start = sp.start, .end = sp.end }, .Nothing);
                    }
                }
                const cfg = self.cfgs.getPtr(f.span) orelse break :blk true;
                const r = try cfa.analyses.reachable.analyseWithTypes(scratch, cfg, &type_map);
                if (cfg.exits.items.len == 0) break :blk true;
                for (cfg.exits.items) |e| {
                    if (r.isReachable(e)) break :blk true;
                }
                break :blk false;
            };
            if (!f.is_abstract and f.return_type != null and
                !(declared_return.* == .Unit or declared_return.* == .Nothing or declared_return.* == .Unresolved) and
                body_ty != .Nothing and normal_exit_reachable)
            {
                const sp = if (b.stmts.len != 0) stmtSpan(&b.stmts[b.stmts.len - 1]) else f.name.span;
                try emitError(
                    self,
                    "a 'return' expression is required in a function with a block body and a non-`Unit` return type",
                    sp,
                    codes.TYPE_MISSING_RETURN,
                );
            }
        },
        .Expr => |*e| {
            var ety = try self.checkExpr(e, declared_return);
            defer ety.deinit(self.allocator);
            if (f.return_type != null and declared_return.* != .Unit) {
                try checkAssignable(self, &ety, declared_return, e.span());
            }
        },
    }
}

// Sequential class validation passes share balanced scope-stack
// push/pop discipline, so they stay in one function.
pub fn checkClass(self: *Checker, c: *const Class) Allocator.Error!void {
    try self.class_stack.append(self.allocator, c.name.name);
    // Track class type parameters in the same scope as function type
    // params. Class type params are never `reified`, so we push an empty
    // set into `reified_type_params` to keep depth in lock-step.
    var class_tps = std.StringHashMap(void).init(self.allocator);
    for (c.type_params) |*tp| try class_tps.put(tp.name.name, {});
    try self.type_params_in_scope.append(self.allocator, class_tps);
    try self.reified_type_params.append(self.allocator, std.StringHashMap(void).init(self.allocator));
    try checkCircularBounds(self, c.type_params, c.where_bounds);
    // Spec §5.1: data, enum, and annotation classes are always closed.
    if (c.is_data or c.is_enum) {
        const kind = if (c.is_data) "data" else "enum";
        const mods = [_]struct { set: bool, name: []const u8 }{
            .{ .set = c.is_open, .name = "open" },
            .{ .set = c.is_abstract, .name = "abstract" },
            .{ .set = c.is_sealed, .name = "sealed" },
        };
        for (mods) |m| {
            if (m.set) {
                const msg = try std.fmt.allocPrint(self.allocator, "`{s} class {s}` cannot be declared `{s}`", .{ kind, c.name.name, m.name });
                try emitError(self, msg, c.name.span, codes.TYPE_DATA_OR_ENUM_CLASS_OPEN_OR_ABSTRACT);
            }
        }
    }
    // Spec §4.1.1: secondary constructor delegation must not form a cycle.
    if (c.secondary_ctors.len != 0) {
        const n = c.secondary_ctors.len;
        var edges = try self.allocator.alloc(std.ArrayList(usize), n);
        defer {
            for (edges) |*e| e.deinit(self.allocator);
            self.allocator.free(edges);
        }
        for (edges) |*e| e.* = .empty;
        for (c.secondary_ctors, 0..) |*sc, i| {
            switch (sc.delegation) {
                .This => |args| {
                    const arity = args.len;
                    for (c.secondary_ctors, 0..) |*other, j| {
                        if (other.params.len == arity) try edges[i].append(self.allocator, j);
                    }
                },
                else => {},
            }
        }
        var start: usize = 0;
        while (start < n) : (start += 1) {
            var stack: std.ArrayList(usize) = .empty;
            defer stack.deinit(self.allocator);
            try stack.append(self.allocator, start);
            const seen = try self.allocator.alloc(bool, n);
            defer self.allocator.free(seen);
            @memset(seen, false);
            var hit_self = false;
            while (stack.pop()) |cur| {
                for (edges[cur].items) |nx| {
                    if (nx == start) {
                        hit_self = true;
                        break;
                    }
                    if (!seen[nx]) {
                        seen[nx] = true;
                        try stack.append(self.allocator, nx);
                    }
                }
                if (hit_self) break;
            }
            if (hit_self) {
                const msg = try std.fmt.allocPrint(self.allocator, "secondary constructor of `{s}` participates in a delegation cycle", .{c.name.name});
                try emitError(self, msg, c.secondary_ctors[start].span, codes.TYPE_CONSTRUCTOR_DELEGATION_CYCLE);
            }
        }
    }
    // Spec §4.1.2: `data class` shape.
    if (c.is_data) {
        var n_props: usize = 0;
        for (c.primary_params) |*p| {
            if (p.property != null) n_props += 1;
        }
        if (n_props == 0) {
            const msg = try std.fmt.allocPrint(self.allocator, "data class `{s}` must declare at least one primary-constructor property", .{c.name.name});
            try emitError(self, msg, c.name.span, codes.TYPE_DATA_CLASS_NO_PROPERTIES);
        }
        for (c.primary_params) |*p| {
            if (p.is_vararg and p.property != null) {
                const msg = try std.fmt.allocPrint(self.allocator, "data class `{s}` cannot declare a `vararg` property parameter", .{c.name.name});
                try emitError(self, msg, p.span, codes.TYPE_DATA_CLASS_VARARG_PROPERTY);
            }
        }
    }
    // Spec §4.1.2: `data class` cannot explicify `copy` or `componentN`.
    if (c.is_data) {
        var n_props: usize = 0;
        for (c.primary_params) |*p| {
            if (p.property != null) n_props += 1;
        }
        for (c.members) |*m| {
            if (m.* == .Function) {
                const f = &m.Function;
                const nm = f.name.name;
                if (std.mem.eql(u8, nm, "copy")) {
                    const msg = try std.fmt.allocPrint(self.allocator, "`copy` is auto-generated for data class `{s}` and cannot be explicified", .{c.name.name});
                    try emitError(self, msg, f.name.span, codes.TYPE_DATA_CLASS_FORBIDS_COPY_OVERRIDE);
                } else if (std.mem.startsWith(u8, nm, "component")) {
                    const rest = nm["component".len..];
                    const idx = std.fmt.parseInt(usize, rest, 10) catch null;
                    if (idx) |i| {
                        if (i >= 1 and i <= n_props and f.params.len == 0) {
                            const msg = try std.fmt.allocPrint(self.allocator, "`{s}` is auto-generated for data class `{s}` and cannot be explicified", .{ nm, c.name.name });
                            try emitError(self, msg, f.name.span, codes.TYPE_DATA_CLASS_FORBIDS_COMPONENT_OVERRIDE);
                        }
                    }
                }
            }
        }
    }
    // Spec §3.9: `kotlin.Enum<T>` declares `equals`, `hashCode`, `compareTo`
    // as `final`. `toString` remains overridable.
    if (c.is_enum) {
        for (c.members) |*m| {
            if (m.* == .Function) {
                const f = &m.Function;
                const nm = f.name.name;
                if ((std.mem.eql(u8, nm, "equals") or std.mem.eql(u8, nm, "hashCode") or std.mem.eql(u8, nm, "compareTo")) and f.is_override) {
                    const msg = try std.fmt.allocPrint(self.allocator, "`{s}` is `final` on `kotlin.Enum` and cannot be overridden (enum class `{s}`)", .{ nm, c.name.name });
                    try emitError(self, msg, f.name.span, codes.TYPE_ENUM_FORBIDS_FINAL_OVERRIDE);
                }
            }
        }
    }
    // Spec §3.12: subtypes of `kotlin.Throwable` cannot have type params.
    if (c.type_params.len != 0 and try isThrowableSubtype(self, c)) {
        const msg = try std.fmt.allocPrint(self.allocator, "Subclasses of `kotlin.Throwable` cannot declare type parameters; `{s}` does", .{c.name.name});
        try emitError(self, msg, c.name.span, codes.TYPE_THROWABLE_TYPE_PARAMS);
    }
    // Spec §5.4: `private` is mutually exclusive with `open` / `abstract` /
    // `override` on a member declaration.
    for (c.members) |*m| {
        switch (m.*) {
            .Function => |*f| {
                if (f.visibility == .Private) {
                    try checkPrivateOpenOrOverride(self, f.name.name, f.name.span, f.is_open, f.is_abstract, f.is_override);
                }
            },
            .Property => |p| {
                if (p.visibility == .Private) {
                    try checkPrivateOpenOrOverride(self, p.name.name, p.name.span, false, p.is_abstract, p.is_override);
                }
            },
            else => {},
        }
    }
    // Spec §5.1: supertype validity.
    try checkSupertypeValidity(self, c.name.name, c.supertypes);
    // Soft override diagnostics.
    var inherited = try collectInheritedMemberFlags(self, c);
    defer inherited.deinit();
    {
        var sigs_tmp = std.StringHashMap(MemberSig).init(self.allocator);
        defer sigs_tmp.deinit();
        try injectFunctionTypeSupertypes(self, c, &inherited, &sigs_tmp);
    }
    // A supertype whose declaration is not visible to this type-check unit
    // may legitimately declare the overridden member.
    var has_opaque_supertype = false;
    for (c.supertypes) |*s| {
        if (s.function == null and !self.classes.contains(s.name.name)) {
            has_opaque_supertype = true;
            break;
        }
    }
    for (c.members) |*m| {
        var mname: []const u8 = undefined;
        var mspan: Span = undefined;
        var mflags: MemberFlags = undefined;
        switch (m.*) {
            .Function => |*f| {
                mname = f.name.name;
                mspan = f.name.span;
                mflags = .{
                    .is_open = f.is_open,
                    .is_override = f.is_override,
                    .is_abstract = f.is_abstract,
                    .is_operator = f.is_operator,
                    .is_infix = f.is_infix,
                    .has_default_body = f.body != null and !f.is_abstract,
                };
            },
            .Property => |p| {
                mname = p.name.name;
                mspan = p.name.span;
                mflags = .{
                    .is_open = p.is_open or p.is_override or p.is_abstract,
                    .is_override = p.is_override,
                    .is_abstract = p.is_abstract,
                    .is_operator = false,
                    .is_infix = false,
                    .has_default_body = false,
                };
            },
            else => continue,
        }
        if (inherited.get(mname)) |parent_flags| {
            // Member exists in a parent.
            if (mflags.is_override) {
                if (!parent_flags.is_open and !parent_flags.is_abstract and !has_opaque_supertype) {
                    const msg = try std.fmt.allocPrint(self.allocator, "`{s}` overrides nothing — parent member is not `open`", .{mname});
                    try emitError(self, msg, mspan, codes.TYPE_OVERRIDE_BUT_PARENT_NOT_OPEN);
                }
            } else {
                if (parent_flags.is_open or parent_flags.is_abstract) {
                    const msg = try std.fmt.allocPrint(self.allocator, "`{s}` hides a member from a supertype; add `override` modifier", .{mname});
                    try emitError(self, msg, mspan, codes.TYPE_OVERRIDE_NEEDED);
                }
            }
        } else {
            if (mflags.is_override and !isBuiltinOverridable(mname) and !has_opaque_supertype) {
                const msg = try std.fmt.allocPrint(self.allocator, "`{s}` is marked `override` but does not override any supertype member", .{mname});
                try emitError(self, msg, mspan, codes.TYPE_OVERRIDE_BUT_NO_BASE);
            }
        }
    }
    // Spec §5.4 override-rule diagnostics.
    var inherited_sigs = try collectInheritedMemberSigs(self, c);
    defer deinitMemberSigMap(self, &inherited_sigs);
    try injectFunctionTypeSupertypes(self, c, &inherited, &inherited_sigs);
    for (c.members) |*m| {
        switch (m.*) {
            .Function => |*f| {
                if (!f.is_override) continue;
                const got = inherited_sigs.get(f.name.name) orelse continue;
                if (got != .Function) continue;
                const base = got.Function;
                if (base.is_suspend != f.is_suspend) {
                    const msg = if (f.is_suspend)
                        try std.fmt.allocPrint(self.allocator, "override `{s}` is `suspend` but the overridden function is not", .{f.name.name})
                    else
                        try std.fmt.allocPrint(self.allocator, "override `{s}` is not `suspend` but the overridden function is", .{f.name.name});
                    try emitError(self, msg, f.name.span, codes.TYPE_OVERRIDE_SUSPEND_MISMATCH);
                }
                // Only check when both ends have explicit return types.
                if (f.return_type) |*rt| {
                    var derived_ret = try convertTypeRefLossy(self.allocator, rt);
                    defer derived_ret.deinit(self.allocator);
                    if (!derived_ret.isSubtypeOf(base.return_ty)) {
                        const d_s = try derived_ret.toString(self.allocator);
                        defer self.allocator.free(d_s);
                        const b_s = try base.return_ty.toString(self.allocator);
                        defer self.allocator.free(b_s);
                        const msg = try std.fmt.allocPrint(self.allocator, "return type `{s}` of override `{s}` is not a subtype of overridden return type `{s}`", .{ d_s, f.name.name, b_s });
                        try emitError(self, msg, f.name.span, codes.TYPE_OVERRIDE_RETURN_TYPE_MISMATCH);
                    }
                }
                try checkOverrideVisibility(self, f.name.name, f.name.span, f.visibility, base.visibility);
            },
            .Property => |p| {
                if (!p.is_override) continue;
                const got = inherited_sigs.get(p.name.name) orelse continue;
                if (got != .Property) continue;
                const base = got.Property;
                var derived_ty = if (p.ty) |*pt| try convertTypeRefLossy(self.allocator, pt) else Type.Unresolved;
                defer derived_ty.deinit(self.allocator);
                // T0066: mutability cannot strengthen.
                if (base.mutable and !p.mutable) {
                    const msg = try std.fmt.allocPrint(self.allocator, "property `{s}` overrides `var` base with `val`: mutability cannot strengthen", .{p.name.name});
                    try emitError(self, msg, p.name.span, codes.TYPE_OVERRIDE_PROPERTY_MUTABILITY);
                }
                // T0067: type subtype, except both `var` requires equivalent types.
                const type_ok = if (base.mutable and p.mutable)
                    (derived_ty.eql(base.ty) or derived_ty == .Unresolved or base.ty == .Unresolved)
                else
                    derived_ty.isSubtypeOf(base.ty);
                if (!type_ok) {
                    const d_s = try derived_ty.toString(self.allocator);
                    defer self.allocator.free(d_s);
                    const b_s = try base.ty.toString(self.allocator);
                    defer self.allocator.free(b_s);
                    const msg = if (base.mutable and p.mutable)
                        try std.fmt.allocPrint(self.allocator, "property `{s}` overrides `var` base of type `{s}` with non-equivalent type `{s}`", .{ p.name.name, b_s, d_s })
                    else
                        try std.fmt.allocPrint(self.allocator, "type `{s}` of override property `{s}` is not a subtype of overridden type `{s}`", .{ d_s, p.name.name, b_s });
                    try emitError(self, msg, p.name.span, codes.TYPE_OVERRIDE_PROPERTY_TYPE);
                }
                try checkOverrideVisibility(self, p.name.name, p.name.span, p.visibility, base.visibility);
            },
            else => {},
        }
    }
    // Abstract-member check for concrete classes.
    if (!c.is_abstract and !c.is_interface) {
        var required: std.ArrayList([]const u8) = .empty;
        defer required.deinit(self.allocator);
        for (c.supertypes, 0..) |*s, i| {
            const is_delegated = i < c.supertype_delegates.len and c.supertype_delegates[i] != null;
            if (is_delegated) continue;
            if (self.classes.get(s.name.name)) |parent| {
                if (parent.is_abstract or parent.is_interface) {
                    for (parent.abstract_members.items) |am| try required.append(self.allocator, am);
                }
            }
        }
        if (required.items.len != 0) {
            var provided = std.StringHashMap(void).init(self.allocator);
            defer provided.deinit();
            if (self.classes.get(c.name.name)) |info| {
                for (info.concrete_members.items) |n| try provided.put(n, {});
            }
            var missing: std.ArrayList([]const u8) = .empty;
            defer missing.deinit(self.allocator);
            for (required.items) |n| {
                if (!provided.contains(n)) try missing.append(self.allocator, n);
            }
            if (missing.items.len != 0) {
                const joined = try joinNames(self.allocator, missing.items);
                defer self.allocator.free(joined);
                const msg = try std.fmt.allocPrint(self.allocator, "Class `{s}` is not abstract and does not implement abstract member(s): {s}", .{ c.name.name, joined });
                try emitError(self, msg, c.name.span, codes.TYPE_ABSTRACT_MEMBER_NOT_IMPLEMENTED);
            }
        }
    }

    // Diamond inheritance.
    if (!c.is_interface) {
        var providers = try collectDefaultProviders(self, c);
        defer deinitProviders(self, &providers);
        var class_overrides = std.StringHashMap(void).init(self.allocator);
        defer class_overrides.deinit();
        for (c.members) |*m| {
            switch (m.*) {
                .Function => |*f| if (f.is_override) try class_overrides.put(f.name.name, {}),
                .Property => |p| if (p.is_override) try class_overrides.put(p.name.name, {}),
                else => {},
            }
        }
        var pit = providers.iterator();
        while (pit.next()) |entry| {
            const member = entry.key_ptr.*;
            const supplying = entry.value_ptr.items;
            // Filter out suppliers shadowed by a subtype supplier.
            var leaves: std.ArrayList(Provider) = .empty;
            defer leaves.deinit(self.allocator);
            for (supplying) |sp| {
                var shadowed = false;
                for (supplying) |other| {
                    if (!std.mem.eql(u8, other.name, sp.name) and try isSubtypeOf(self, other.name, sp.name)) {
                        shadowed = true;
                        break;
                    }
                }
                if (!shadowed) try leaves.append(self.allocator, sp);
            }
            if (leaves.items.len == 0) continue;
            var concrete_count: usize = 0;
            var abstract_count: usize = 0;
            for (leaves.items) |l| {
                if (l.concrete) concrete_count += 1 else abstract_count += 1;
            }
            const needs_override = concrete_count >= 2 or (concrete_count != 0 and abstract_count != 0);
            if (!needs_override) continue;
            if (class_overrides.contains(member)) continue;
            var names_list: std.ArrayList([]const u8) = .empty;
            defer names_list.deinit(self.allocator);
            for (leaves.items) |l| try names_list.append(self.allocator, l.name);
            const names = try joinNames(self.allocator, names_list.items);
            defer self.allocator.free(names);
            const msg = try std.fmt.allocPrint(self.allocator, "Class `{s}` inherits conflicting members for `{s}` from supertypes ({s}); explicit `override` required", .{ c.name.name, member, names });
            try emitError(self, msg, c.name.span, codes.TYPE_DIAMOND_CONFLICT);
        }
    }

    // `lateinit` compile-time rules.
    for (c.members) |*m| {
        if (m.* == .Property) try checkLateinit(self, m.Property);
    }
    // Accessor return-type annotation.
    for (c.members) |*m| {
        if (m.* == .Property) try checkAccessorReturnTypes(self, m.Property);
    }

    try pushFrame(self);
    // Bind primary-ctor params.
    for (c.primary_params) |*p| {
        const ty = try convertTypeRefLossy(self.allocator, &p.ty);
        const cn = classNameFromTyperef(&p.ty);
        try currentFrame(self).bindings.put(p.name.name, .{
            .ty = ty,
            .mutable = p.property != null and p.property.? == true,
            .decl_span = p.name.span,
            .class_name = cn,
            .decl_type_name = null,
        });
        if (p.default) |*default| {
            var want = try convertTypeRefLossy(self.allocator, &p.ty);
            defer want.deinit(self.allocator);
            var dty = try self.checkExpr(default, &want);
            defer dty.deinit(self.allocator);
            try checkAssignable(self, &dty, &want, default.span());
        }
    }
    // Body properties bind in declaration order.
    var uninitialized_properties: std.ArrayList(struct { name: []const u8, sp: Span }) = .empty;
    defer uninitialized_properties.deinit(self.allocator);
    for (c.members) |*m| {
        if (m.* != .Property) continue;
        const p = m.Property;
        if (p.init) |*init| {
            var want: ?Type = if (p.ty) |*pt| try convertTypeRefLossy(self.allocator, pt) else null;
            var ity = try self.checkExpr(init, if (want) |*a| a else null);
            defer ity.deinit(self.allocator);
            if (want) |*a| {
                try checkAssignable(self, &ity, a, init.span());
                a.deinit(self.allocator);
            }
        }
        const has_init = p.init != null or p.delegate != null or p.is_lateinit or p.is_abstract or p.getter != null or c.is_interface or c.is_abstract;
        if (!has_init) {
            const pty = if (p.ty) |*pt| try convertTypeRefLossy(self.allocator, pt) else Type.Unresolved;
            try currentFrame(self).bindings.put(p.name.name, .{
                .ty = pty,
                .mutable = p.mutable,
                .decl_span = p.name.span,
                .class_name = if (p.ty) |*pt| classNameFromTyperef(pt) else null,
                .decl_type_name = null,
            });
            try uninitialized_properties.append(self.allocator, .{ .name = p.name.name, .sp = p.name.span });
        }
        try handleAccessors(self, p);
    }
    // Inheritance-delegation diagnostics.
    for (c.supertypes, 0..) |*s, i| {
        if (i >= c.supertype_delegates.len) continue;
        const delegate_expr = c.supertype_delegates[i] orelse continue;
        const target_name = s.name.name;
        const target_is_interface = if (self.classes.get(target_name)) |info| info.is_interface else false;
        if (!target_is_interface) {
            const msg = try std.fmt.allocPrint(self.allocator, "Only interfaces can be delegated to; `{s}` is not an interface", .{target_name});
            try emitError(self, msg, s.span, codes.TYPE_DELEGATION_TARGET_NOT_INTERFACE);
        }
        var dexpr = delegate_expr;
        var de_ty = try self.checkExpr(&dexpr, null);
        de_ty.deinit(self.allocator);
        const delegate_class = self.expr_class.get(dexpr.span());
        if (target_is_interface) {
            if (delegate_class) |dcn| {
                if (!std.mem.eql(u8, dcn, target_name) and !try isSubtypeOf(self, dcn, target_name)) {
                    const msg = try std.fmt.allocPrint(self.allocator, "Delegate expression of type `{s}` is not a subtype of `{s}`", .{ dcn, target_name });
                    try emitError(self, msg, dexpr.span(), codes.TYPE_DELEGATION_TYPE_MISMATCH);
                }
            }
        }
    }
    // Build the synthetic class-init CFG.
    const init_cfg_span = c.name.span;
    var init_body = try synthesizeClassInitBody(self, c);
    var init_lowered = try cfa.lower.lowerFunction(self.allocator, &init_body, init_cfg_span);
    try cfa.dataflow.inferKillDataFlow(self.allocator, &init_lowered.cfg);
    try self.cfgs.put(init_cfg_span, init_lowered.cfg);
    const init_low = try self.allocator.create(root.Lowered);
    init_low.* = init_lowered;
    try self.lowerings.put(init_cfg_span, init_low);
    try self.cfg_fn_stack.append(self.allocator, init_cfg_span);
    for (c.init_blocks) |*b| {
        var bty = try checkBlock(self, b, null);
        bty.deinit(self.allocator);
    }
    _ = self.cfg_fn_stack.pop();
    // VIA: every uninitialized property must be definitely assigned.
    if (c.secondary_ctors.len != 0) {
        // Secondary-ctor flow runs its own path; skip to avoid false positives.
    } else if (c.is_expect) {
        // An `expect class` declares members without bodies or initializers.
    } else {
        for (uninitialized_properties.items) |up| {
            const cfg_says_unassigned = (try cfgViaUnassignedAtExit(self, init_cfg_span, up.name)) orelse true;
            if (cfg_says_unassigned) {
                const msg = try std.fmt.allocPrint(self.allocator, "Property `{s}` must be initialized", .{up.name});
                try emitError(self, msg, up.sp, codes.TYPE_VAR_NOT_DEFINITELY_ASSIGNED);
            }
        }
    }
    // Secondary ctors.
    for (c.secondary_ctors) |*sc| try checkSecondaryCtor(self, sc);
    // Method bodies.
    for (c.members) |*m| {
        if (m.* == .Function) try checkFunction(self, &m.Function);
    }
    for (c.enum_entries) |*entry| try checkEnumEntry(self, entry);
    popFrame(self);
    _ = self.class_stack.pop();
    {
        var s = self.type_params_in_scope.pop().?;
        s.deinit();
    }
    {
        var s = self.reified_type_params.pop().?;
        s.deinit();
    }
}

fn joinNames(allocator: Allocator, names: []const []const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    for (names, 0..) |n, i| {
        if (i > 0) aw.writer.writeAll(", ") catch return error.OutOfMemory;
        aw.writer.writeAll(n) catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}

/// Spec §5.4: an explicit override visibility must not be stronger than
/// the overridden declaration's visibility. Strength order:
/// public < internal < protected < private.
pub fn checkOverrideVisibility(self: *Checker, name: []const u8, sp: Span, derived: Visibility, base: Visibility) Allocator.Error!void {
    if (visStrength(derived) > visStrength(base)) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "override `{s}` cannot weaken visibility: declared `{s}` is stronger than overridden `{s}`",
            .{ name, visName(derived), visName(base) },
        );
        try emitError(self, msg, sp, codes.TYPE_OVERRIDE_VISIBILITY_STRONGER);
    }
}

fn visStrength(v: Visibility) u8 {
    return switch (v) {
        .Public => 0,
        .Internal => 1,
        .Protected => 2,
        .Private => 3,
    };
}

fn visName(v: Visibility) []const u8 {
    return switch (v) {
        .Public => "public",
        .Internal => "internal",
        .Protected => "protected",
        .Private => "private",
    };
}

pub fn checkPrivateOpenOrOverride(self: *Checker, name: []const u8, sp: Span, is_open: bool, is_abstract: bool, is_override: bool) Allocator.Error!void {
    const modifier: ?[]const u8 = if (is_open)
        "open"
    else if (is_abstract)
        "abstract"
    else if (is_override)
        "override"
    else
        null;
    if (modifier) |mod| {
        const msg = try std.fmt.allocPrint(self.allocator, "`{s}` cannot be both `private` and `{s}`", .{ name, mod });
        try emitError(self, msg, sp, codes.TYPE_PRIVATE_AND_OPEN_OR_ABSTRACT_OR_OVERRIDE);
    }
}

/// Spec §5.1: check each declared supertype is legal to inherit from.
pub fn checkSupertypeValidity(self: *Checker, derived_name: []const u8, supertypes: []const TypeRef) Allocator.Error!void {
    const derived_local = if (self.classes.get(derived_name)) |i| i.is_local_or_anonymous else false;
    for (supertypes) |*s| {
        const name = s.name.name;
        const parent = self.classes.get(name) orelse continue;
        if (parent.is_sealed and derived_local) {
            const msg = try std.fmt.allocPrint(self.allocator, "local class `{s}` cannot inherit from sealed type `{s}`: sealed inheritors must have a fully-qualified name", .{ derived_name, name });
            try emitError(self, msg, s.span, codes.TYPE_SEALED_INHERITOR_NOT_QUALIFIED);
        }
        if (parent.is_object) {
            const msg = try std.fmt.allocPrint(self.allocator, "`{s}` cannot inherit from object `{s}`: object types cannot be inherited from", .{ derived_name, name });
            try emitError(self, msg, s.span, codes.TYPE_INHERIT_FROM_OBJECT);
            continue;
        }
        if (parent.is_interface) continue;
        const open = parent.is_open or parent.is_abstract or parent.is_sealed;
        if (!open) {
            const msg = try std.fmt.allocPrint(self.allocator, "`{s}` cannot inherit from final class `{s}`: declare it `open`, `abstract`, or `sealed`", .{ derived_name, name });
            try emitError(self, msg, s.span, codes.TYPE_INHERIT_FROM_FINAL_CLASS);
        }
    }
}

const BUILTIN_THROWABLES_FULL = [_][]const u8{
    "Throwable",                  "Exception",                       "RuntimeException",
    "Error",                      "IllegalArgumentException",        "IllegalStateException",
    "IndexOutOfBoundsException",  "NullPointerException",            "ArithmeticException",
    "ClassCastException",         "NoSuchElementException",          "UnsupportedOperationException",
    "NumberFormatException",      "NoWhenBranchMatchedException",    "UninitializedPropertyAccessException",
    "AssertionError",            "NotImplementedError",             "ConcurrentModificationException",
};

const BUILTIN_THROWABLES_CLASS = [_][]const u8{
    "Throwable",                  "Exception",                       "RuntimeException",
    "Error",                      "IllegalArgumentException",        "IllegalStateException",
    "IndexOutOfBoundsException",  "NullPointerException",            "ArithmeticException",
    "ClassCastException",         "NoSuchElementException",          "UnsupportedOperationException",
    "NumberFormatException",      "NoWhenBranchMatchedException",    "UninitializedPropertyAccessException",
};

/// Predicate used at `throw e` sites: is `ty` known to descend from
/// `kotlin.Throwable`?
pub fn typeIsThrowableSubtype(self: *Checker, ty: *const Type) bool {
    return switch (ty.*) {
        .Nothing, .Unresolved, .TypeParam => true,
        .Nullable => false,
        .Generic => |gen| nameIsThrowableSubtype(self, gen.name),
        .Intersection => |parts| blk: {
            for (parts) |*p| {
                if (typeIsThrowableSubtype(self, p)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn nameIsThrowableSubtype(self: *Checker, name: []const u8) bool {
    if (eqAny(name, &BUILTIN_THROWABLES_FULL)) return true;
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(self.allocator);
    stack.append(self.allocator, name) catch return false;
    while (stack.pop()) |n| {
        if ((seen.getOrPut(n) catch return false).found_existing) continue;
        if (eqAny(n, &BUILTIN_THROWABLES_FULL)) return true;
        if (self.classes.get(n)) |info| {
            for (info.supertypes.items) |s| stack.append(self.allocator, s) catch return false;
        }
    }
    return false;
}

pub fn isThrowableSubtype(self: *Checker, c: *const Class) Allocator.Error!bool {
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(self.allocator);
    for (c.supertypes) |*s| try stack.append(self.allocator, s.name.name);
    while (stack.pop()) |name| {
        if ((try seen.getOrPut(name)).found_existing) continue;
        if (eqAny(name, &BUILTIN_THROWABLES_CLASS)) return true;
        if (self.classes.get(name)) |info| {
            for (info.supertypes.items) |s| try stack.append(self.allocator, s);
        }
    }
    return false;
}

/// Synthesize the `invoke` slot for each function-type supertype.
pub fn injectFunctionTypeSupertypes(
    self: *Checker,
    c: *const Class,
    flags: *std.StringHashMap(MemberFlags),
    sigs: *std.StringHashMap(MemberSig),
) Allocator.Error!void {
    for (c.supertypes) |*s| {
        const fnref = s.function orelse continue;
        if (!flags.contains("invoke")) {
            try flags.put("invoke", .{
                .is_open = true,
                .is_override = false,
                .is_abstract = true,
                .is_operator = true,
                .is_infix = false,
                .has_default_body = false,
            });
        }
        if (!sigs.contains("invoke")) {
            const param_types = try self.allocator.alloc(Type, fnref.params.len);
            for (fnref.params, 0..) |*p, i| param_types[i] = try convertTypeRefLossy(self.allocator, p);
            const return_ty = try convertTypeRefLossy(self.allocator, &fnref.ret);
            try sigs.put("invoke", .{ .Function = .{
                .param_types = param_types,
                .return_ty = return_ty,
                .visibility = .Public,
                .is_suspend = fnref.is_suspend,
            } });
        }
    }
}

/// Collects the detailed inherited member signatures used by the
/// override-rule diagnostics. The first occurrence wins. The returned
/// map's `MemberSig` values own heap data.
pub fn collectInheritedMemberSigs(self: *Checker, c: *const Class) Allocator.Error!std.StringHashMap(MemberSig) {
    var out = std.StringHashMap(MemberSig).init(self.allocator);
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(self.allocator);
    for (c.supertypes) |*s| try frontier.append(self.allocator, s.name.name);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(self.allocator);
    try seen.append(self.allocator, c.name.name);
    var steps: usize = 0;
    while (frontier.pop()) |parent_name| {
        if (steps > 64) break;
        steps += 1;
        if (sliceContains(seen.items, parent_name)) continue;
        try seen.append(self.allocator, parent_name);
        const parent = self.classes.get(parent_name) orelse continue;
        var it = parent.member_sigs.iterator();
        while (it.next()) |entry| {
            if (!out.contains(entry.key_ptr.*)) {
                try out.put(entry.key_ptr.*, try cloneMemberSig(self.allocator, entry.value_ptr));
            }
        }
        for (parent.supertypes.items) |s| try frontier.append(self.allocator, s);
    }
    return out;
}

pub fn collectInheritedMemberFlags(self: *Checker, c: *const Class) Allocator.Error!std.StringHashMap(MemberFlags) {
    var out = std.StringHashMap(MemberFlags).init(self.allocator);
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(self.allocator);
    for (c.supertypes) |*s| try frontier.append(self.allocator, s.name.name);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(self.allocator);
    try seen.append(self.allocator, c.name.name);
    var steps: usize = 0;
    while (frontier.pop()) |parent_name| {
        if (steps > 64) break;
        steps += 1;
        if (sliceContains(seen.items, parent_name)) continue;
        try seen.append(self.allocator, parent_name);
        const parent = self.classes.get(parent_name) orelse continue;
        var it = parent.member_flags.iterator();
        while (it.next()) |entry| {
            var effective = entry.value_ptr.*;
            // An override member without explicit `final` is itself overridable.
            if (effective.is_override) effective.is_open = true;
            if (!out.contains(entry.key_ptr.*)) try out.put(entry.key_ptr.*, effective);
        }
        for (parent.supertypes.items) |s| try frontier.append(self.allocator, s);
    }
    return out;
}

pub fn checkEnumEntry(self: *Checker, e: *const EnumEntry) Allocator.Error!void {
    for (e.args) |*a| {
        var t = try self.checkExpr(a, null);
        t.deinit(self.allocator);
    }
    for (e.body_members) |*m| try checkDecl(self, m);
}

pub fn handleAccessors(self: *Checker, p: *const Property) Allocator.Error!void {
    if (p.getter) |*g| try checkAccessor(self, g);
    if (p.setter) |*s| try checkAccessor(self, s);
    if (p.delegate) |*d| {
        var t = try self.checkExpr(d, null);
        t.deinit(self.allocator);
        try checkDelegateOperator(self, p, d);
    }
}

/// For `val/var x by EXPR`, when EXPR resolves to a constructor call on
/// a user class, require that class's `getValue` (and `setValue` for
/// `var`) carry the `operator` modifier. Emitted as a warning (T0012).
pub fn checkDelegateOperator(self: *Checker, p: *const Property, delegate: *const Expr) Allocator.Error!void {
    const class_name: ?[]const u8 = switch (delegate.*) {
        .Call => |call| switch (call.callee.*) {
            .Path => |path| if (path.segments.len != 0) path.segments[path.segments.len - 1].name else null,
            else => null,
        },
        .Path => |path| if (path.segments.len != 0) path.segments[path.segments.len - 1].name else null,
        else => null,
    };
    const cn = class_name orelse return;
    const info = self.classes.get(cn) orelse return;
    const needed: []const []const u8 = if (p.mutable)
        &.{ "getValue", "setValue" }
    else
        &.{"getValue"};
    for (needed) |member| {
        const flags = info.member_flags.get(member) orelse continue;
        if (!flags.is_operator) {
            const msg = try std.fmt.allocPrint(self.allocator, "`{s}.{s}` is used as a property-delegate convention but is missing the `operator` modifier", .{ cn, member });
            try emitWarning(self, msg, delegate.span(), codes.TYPE_DELEGATE_OPERATOR_REQUIRED);
        }
    }
}

/// Compile-time rules for `lateinit`. Kotlin restricts `lateinit` to:
/// non-null, non-primitive, `var` properties with no initializer.
pub fn checkLateinit(self: *Checker, p: *const Property) Allocator.Error!void {
    if (!p.is_lateinit) return;
    if (!p.mutable) {
        const msg = try std.fmt.allocPrint(self.allocator, "`lateinit` modifier is not allowed on `val` (use `lateinit var` for `{s}`)", .{p.name.name});
        try emitError(self, msg, p.name.span, codes.TYPE_LATEINIT_VAL);
    }
    if (p.init) |*init| {
        const msg = try std.fmt.allocPrint(self.allocator, "`lateinit` property `{s}` cannot have an initializer", .{p.name.name});
        try emitError(self, msg, init.span(), codes.TYPE_LATEINIT_WITH_INITIALIZER);
    }
    if (p.ty) |*ty| {
        if (ty.nullable) {
            const msg = try std.fmt.allocPrint(self.allocator, "`lateinit` property `{s}` may not have a nullable type", .{p.name.name});
            try emitError(self, msg, ty.span, codes.TYPE_LATEINIT_NULLABLE);
        }
        if (isPrimitiveTypeName(ty.name.name)) {
            const msg = try std.fmt.allocPrint(self.allocator, "`lateinit` modifier is not allowed on properties of primitive type `{s}`", .{ty.name.name});
            try emitError(self, msg, ty.span, codes.TYPE_LATEINIT_PRIMITIVE);
        }
    }
}

/// Enforce that an accessor's explicit return-type annotation matches
/// the property's declared type.
pub fn checkAccessorReturnTypes(self: *Checker, p: *const Property) Allocator.Error!void {
    const prop_ty_ref = if (p.ty) |*pt| pt else return;
    var prop_ty = try convertTypeRefLossy(self.allocator, prop_ty_ref);
    defer prop_ty.deinit(self.allocator);
    const accessors = [_]struct { a: ?*const Accessor, label: []const u8 }{
        .{ .a = if (p.getter) |*g| g else null, .label = "getter" },
        .{ .a = if (p.setter) |*s| s else null, .label = "setter" },
    };
    for (accessors) |item| {
        const a = item.a orelse continue;
        const rt = if (a.return_type) |*r| r else continue;
        var rty = try convertTypeRefLossy(self.allocator, rt);
        defer rty.deinit(self.allocator);
        if (!typesMatchForAccessor(&rty, &prop_ty)) {
            const rty_s = try typeDisplay(self.allocator, &rty);
            defer self.allocator.free(rty_s);
            const prop_s = try typeDisplay(self.allocator, &prop_ty);
            defer self.allocator.free(prop_s);
            const msg = try std.fmt.allocPrint(self.allocator, "{s} return type `{s}` does not match property type `{s}`", .{ item.label, rty_s, prop_s });
            try emitError(self, msg, rt.span, codes.TYPE_ACCESSOR_RETURN_TYPE_MISMATCH);
        }
    }
}

pub fn typesMatchForAccessor(a: *const Type, b: *const Type) bool {
    if (a.* == .Unresolved or b.* == .Unresolved) return true;
    return a.eql(b.*);
}

/// True when `sub` is a transitive supertype-walk descendant of `sup`.
pub fn isSubtypeOf(self: *Checker, sub: []const u8, sup: []const u8) Allocator.Error!bool {
    if (std.mem.eql(u8, sub, sup)) return false;
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(self.allocator);
    try frontier.append(self.allocator, sub);
    var steps: usize = 0;
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(self.allocator);
    while (frontier.pop()) |name| {
        if (steps > 64) return false;
        steps += 1;
        if (sliceContains(seen.items, name)) continue;
        try seen.append(self.allocator, name);
        const info = self.classes.get(name) orelse continue;
        for (info.supertypes.items) |s| {
            if (std.mem.eql(u8, s, sup)) return true;
            try frontier.append(self.allocator, s);
        }
    }
    return false;
}

const Provider = struct { name: []const u8, concrete: bool };

/// For diamond detection: for every member name supplied by some
/// supertype, list `(supertype, has_default_body)` pairs.
pub fn collectDefaultProviders(self: *Checker, c: *const Class) Allocator.Error!std.StringHashMap(std.ArrayList(Provider)) {
    var out = std.StringHashMap(std.ArrayList(Provider)).init(self.allocator);
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(self.allocator);
    for (c.supertypes) |*s| try frontier.append(self.allocator, s.name.name);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(self.allocator);
    try seen.append(self.allocator, c.name.name);
    var steps: usize = 0;
    while (frontier.pop()) |parent_name| {
        if (steps > 64) break;
        steps += 1;
        if (sliceContains(seen.items, parent_name)) continue;
        try seen.append(self.allocator, parent_name);
        const parent = self.classes.get(parent_name) orelse continue;
        var it = parent.member_flags.iterator();
        while (it.next()) |entry| {
            const flags = entry.value_ptr.*;
            const is_abstract_slot = flags.is_abstract or (parent.is_interface and !flags.has_default_body);
            if (flags.has_default_body or is_abstract_slot) {
                const gop = try out.getOrPut(entry.key_ptr.*);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                var already = false;
                for (gop.value_ptr.items) |pv| {
                    if (std.mem.eql(u8, pv.name, parent_name)) {
                        already = true;
                        break;
                    }
                }
                if (!already) try gop.value_ptr.append(self.allocator, .{ .name = parent_name, .concrete = flags.has_default_body });
            }
        }
        for (parent.supertypes.items) |s| try frontier.append(self.allocator, s);
    }
    return out;
}

fn deinitProviders(self: *Checker, m: *std.StringHashMap(std.ArrayList(Provider))) void {
    var it = m.valueIterator();
    while (it.next()) |v| v.deinit(self.allocator);
    m.deinit();
}

pub fn checkAccessor(self: *Checker, a: *const Accessor) Allocator.Error!void {
    try pushFrame(self);
    for (a.params) |p| {
        try currentFrame(self).bindings.put(p.name, .{
            .ty = Type.Unresolved,
            .mutable = false,
            .decl_span = p.span,
            .class_name = null,
            .decl_type_name = null,
        });
    }
    switch (a.body) {
        .Block => |*b| {
            var t = try checkBlock(self, b, null);
            t.deinit(self.allocator);
        },
        .Expr => |*e| {
            var t = try self.checkExpr(e, null);
            t.deinit(self.allocator);
        },
    }
    popFrame(self);
}

pub fn checkSecondaryCtor(self: *Checker, sc: *const SecondaryCtor) Allocator.Error!void {
    try pushFrame(self);
    for (sc.params) |*p| {
        const ty = try convertTypeRefLossy(self.allocator, &p.ty);
        const cn = classNameFromTyperef(&p.ty);
        try currentFrame(self).bindings.put(p.name.name, .{
            .ty = ty,
            .mutable = false,
            .decl_span = p.name.span,
            .class_name = cn,
            .decl_type_name = null,
        });
    }
    switch (sc.delegation) {
        .This, .Super => |args| {
            for (args) |*a| {
                var t = try self.checkExpr(a, null);
                t.deinit(self.allocator);
            }
        },
        .None => {},
    }
    if (sc.body) |*b| {
        var t = try checkBlock(self, b, null);
        t.deinit(self.allocator);
    }
    popFrame(self);
}

pub fn checkObject(self: *Checker, o: *const ObjectDecl) Allocator.Error!void {
    try self.class_stack.append(self.allocator, o.name.name);
    try checkSupertypeValidity(self, o.name.name, o.supertypes);
    try pushFrame(self);
    for (o.members) |*m| {
        switch (m.*) {
            .Property => |p| {
                if (p.init) |*init| {
                    var want: ?Type = if (p.ty) |*pt| try convertTypeRefLossy(self.allocator, pt) else null;
                    var ity = try self.checkExpr(init, if (want) |*a| a else null);
                    defer ity.deinit(self.allocator);
                    if (want) |*a| {
                        try checkAssignable(self, &ity, a, init.span());
                        a.deinit(self.allocator);
                    }
                }
                try handleAccessors(self, p);
            },
            .Function => |*f| try checkFunction(self, f),
            else => {},
        }
    }
    popFrame(self);
    _ = self.class_stack.pop();
}

// ---- small utilities --------------------------------------------------

fn sliceContains(slice: []const []const u8, needle: []const u8) bool {
    for (slice) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

fn cloneMemberSig(allocator: Allocator, sig: *const MemberSig) Allocator.Error!MemberSig {
    return switch (sig.*) {
        .Function => |fnc| blk: {
            const params = try allocator.alloc(Type, fnc.param_types.len);
            for (fnc.param_types, 0..) |*p, i| params[i] = try p.clone(allocator);
            break :blk .{ .Function = .{
                .param_types = params,
                .return_ty = try fnc.return_ty.clone(allocator),
                .visibility = fnc.visibility,
                .is_suspend = fnc.is_suspend,
            } };
        },
        .Property => |prop| .{ .Property = .{
            .ty = try prop.ty.clone(allocator),
            .mutable = prop.mutable,
            .visibility = prop.visibility,
        } },
    };
}

fn deinitMemberSig(self: *Checker, sig: *MemberSig) void {
    switch (sig.*) {
        .Function => |*fnc| {
            for (fnc.param_types) |*p| p.deinit(self.allocator);
            self.allocator.free(fnc.param_types);
            fnc.return_ty.deinit(self.allocator);
        },
        .Property => |*prop| prop.ty.deinit(self.allocator),
    }
}

fn deinitMemberSigMap(self: *Checker, m: *std.StringHashMap(MemberSig)) void {
    var it = m.valueIterator();
    while (it.next()) |v| deinitMemberSig(self, v);
    m.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
