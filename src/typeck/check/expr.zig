//! Expression-checking phase. Free functions over `*Checker`.

const std = @import("std");

const span = @import("span");
const ast = @import("ast");
const types = @import("types");
const diagnostics = @import("diagnostics");

const root = @import("../check.zig");
const helpers = @import("helpers.zig");
const narrowing = @import("narrowing.zig");
const expr_calls = @import("expr_calls.zig");
const visibility = @import("visibility.zig");
const decl_mod = @import("decl.zig");

const Allocator = std.mem.Allocator;
const Checker = root.Checker;
const ClassInfo = root.ClassInfo;
const FnSig = root.FnSig;
const ExtensionPropSig = root.ExtensionPropSig;
const codes = root.codes;

const Span = span.Span;
const Type = types.Type;
const convertTypeRefLossy = types.convertTypeRefLossy;
const builtinByName = types.builtinByName;

const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Block = ast.Block;
const Decl = ast.Decl;
const AssignOp = ast.AssignOp;

const Diagnostic = diagnostics.Diagnostic;
const factories = diagnostics.generated;

const classNameFromTyperef = helpers.classNameFromTyperef;
const convertTypeRefLossyH = convertTypeRefLossy;
const dotPathKey = helpers.dotPathKey;
const isLabelableTarget = helpers.isLabelableTarget;
const isNumeric = helpers.isNumeric;
const lub = helpers.lub;
const singlePathName = helpers.singlePathName;
const stmtSpan = helpers.stmtSpan;
const substituteTypeParams = helpers.substituteTypeParams;
const typeHasCompoundAssign = helpers.typeHasCompoundAssign;

const boolean_ty: Type = .Boolean;

fn emitErr(self: *Checker, msg: []const u8, sp: Span, code: []const u8) Allocator.Error!void {
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(code);
    try self.diagnostics.emit(self.allocator, d);
}

fn emitWarn(self: *Checker, msg: []const u8, sp: Span, code: []const u8) Allocator.Error!void {
    var d = Diagnostic.warning(msg, sp);
    _ = d.withCode(code);
    try self.diagnostics.emit(self.allocator, d);
}

/// Frees any prior entry, so repeated checks of one span do not leak. The map
/// owns the stored value.
fn recordType(self: *Checker, sp: Span, ty: *const Type) Allocator.Error!void {
    if (self.generic_body_depth != 0) {
        try self.types_instantiation_dependent.put(sp, {});
    }
    const owned = try ty.clone(self.allocator);
    const gop = try self.types.getOrPut(sp);
    if (gop.found_existing) gop.value_ptr.deinit(self.allocator);
    gop.value_ptr.* = owned;
    if (owned == .Nothing) {
        const ng = try self.nothing_spans.getOrPut(sp);
        if (!ng.found_existing) self.nothing_epoch += 1;
        // Membership is per (function, span): one span can be re-typed.
        if (self.cfg_fn_stack.items.len != 0) {
            const fn_span = self.cfg_fn_stack.items[self.cfg_fn_stack.items.len - 1];
            const bucket = try self.nothing_by_fn.getOrPut(fn_span);
            if (!bucket.found_existing) {
                bucket.value_ptr.* = std.AutoHashMap(Span, void).init(self.allocator);
            }
            const bg = try bucket.value_ptr.getOrPut(sp);
            if (!bg.found_existing) self.nothing_epoch += 1;
        }
    } else if (gop.found_existing) {
        if (self.nothing_spans.remove(sp)) self.nothing_epoch += 1;
    }
}

pub fn checkBlock(self: *Checker, block: *const Block, expected: ?*const Type) Allocator.Error!Type {
    try narrowing.pushFrame(self);
    var last: Type = .Unit;
    var warned = false;
    for (block.stmts, 0..) |*s, i| {
        const is_last = i + 1 == block.stmts.len;
        // The typed reachability variant also picks up `Nothing`-returning
        // expressions in earlier statements.
        const cfg_dead = (try narrowing.cfgIsUnreachableAt(self, stmtSpan(s))) orelse false;
        if (cfg_dead and !warned) {
            var d = Diagnostic.warning("Unreachable code", stmtSpan(s));
            _ = d.withCode(codes.WARN_UNREACHABLE_CODE);
            _ = d.withFactory(&factories.UNREACHABLE_CODE);
            try self.diagnostics.emit(self.allocator, d);
            warned = true;
        }
        last.deinit(self.allocator);
        last = try checkStmt(self, s, if (is_last) expected else null);
    }
    narrowing.popFrame(self);
    return last;
}

pub fn checkStmt(self: *Checker, stmt: *const Stmt, expected: ?*const Type) Allocator.Error!Type {
    switch (stmt.*) {
        .Expr => |*e| return self.checkExpr(e, expected),
        .Decl => |*d| {
            try checkLocalDecl(self, d);
            return .Unit;
        },
        .Assign => |a| {
            try checkAssign(self, &a.target, a.op, &a.value, a.span);
            return .Unit;
        },
        .DestructuringDecl => |d| {
            var init_ty = try self.checkExpr(&d.init, null);
            init_ty.deinit(self.allocator);
            // Each non-`_` slot dispatches `componentN`.
            const init_cls = self.expr_class.get(d.init.span());
            for (d.names, 0..) |*n, idx| {
                if (std.mem.eql(u8, n.name, "_")) continue;
                if (!d.by_name) {
                    const comp = try std.fmt.allocPrint(self.allocator, "component{d}", .{idx + 1});
                    defer self.allocator.free(comp);
                    try expr_calls.checkUserOperatorKeyword(self, init_cls, comp, n.span);
                }
                try narrowing.currentFrame(self).bindings.put(n.name, .{
                    .ty = .Unresolved,
                    .mutable = d.mutable,
                    .decl_span = n.span,
                    .class_name = null,
                    .decl_type_name = null,
                });
            }
            return .Unit;
        },
    }
}

pub fn checkLocalDecl(self: *Checker, decl: *const Decl) Allocator.Error!void {
    const a = self.allocator;
    switch (decl.*) {
        .Property => |p| {
            // A local property has no constructor parameter, backing field or
            // accessors for this meta-target to expand over.
            for (p.annotations) |*ann| {
                if (ann.use_site != null and ann.use_site.? == .All) {
                    var d = Diagnostic.err(
                        "'@all:' annotations cannot be applied to local properties, only member or top-level properties are allowed.",
                        ann.span,
                    );
                    _ = d.withCode(codes.TYPE_INAPPLICABLE_ALL_TARGET);
                    _ = d.withFactory(&factories.INAPPLICABLE_ALL_TARGET);
                    try self.diagnostics.emit(a, d);
                }
            }
            var annot: ?Type = if (p.ty) |*t| try convertTypeRefLossyH(a, t) else null;
            defer if (annot) |*an| an.deinit(a);

            var init_ty: Type = blk: {
                if (p.init) |*init| {
                    break :blk try self.checkExpr(init, if (annot) |*an| an else null);
                } else if (p.delegate) |dexpr| {
                    var dt = try self.checkExpr(dexpr, null);
                    dt.deinit(a);
                    break :blk .Unresolved;
                } else {
                    break :blk .Unresolved;
                }
            };
            defer init_ty.deinit(a);

            const declared: Type = if (annot) |*an| try an.clone(a) else try init_ty.clone(a);

            if (annot != null and p.init != null) {
                try expr_calls.checkAssignable(self, &init_ty, &annot.?, p.init.?.span());
            }

            var cn: ?[]const u8 = if (p.ty) |*t| classNameFromTyperef(t) else null;
            if (cn == null) {
                if (p.init) |*init| {
                    cn = self.expr_class.get(init.span());
                }
            }

            const decl_type_name: ?[]const u8 = if (p.ty) |*t|
                (if (builtinByName(t.name.name) == null) t.name.name else null)
            else
                null;

            try narrowing.currentFrame(self).bindings.put(p.name.name, .{
                .ty = declared,
                .mutable = p.mutable,
                .decl_span = p.name.span,
                .class_name = cn,
                .decl_type_name = decl_type_name,
            });

            // A mutable binding could be reassigned, breaking the alias.
            if (!p.mutable) {
                if (p.init) |*init| {
                    if (singlePathName(init)) |src| {
                        // The alias itself lives in the CFG lowering's `aliases`
                        // map, read by `cfgNarrowedAt`.
                        const src_is_stable = if (narrowing.lookup(self, src)) |b| !b.mutable else false;
                        _ = src_is_stable;
                    }
                }
            }
        },
        .Function => |*f| {
            const sig = try decl_mod.signatureOf(self, f);
            const params = try a.alloc(Type, sig.params.len);
            for (sig.params, params) |*p, *dst| dst.* = try p.clone(a);
            const ret = try a.create(Type);
            ret.* = try sig.return_ty.clone(a);
            const fn_ty: Type = .{ .Function = .{
                .params = params,
                .return_type = ret,
                .is_suspend = f.is_suspend,
            } };
            try narrowing.currentFrame(self).bindings.put(f.name.name, .{
                .ty = fn_ty,
                .mutable = false,
                .decl_span = f.name.span,
                .class_name = null,
                .decl_type_name = null,
            });
            try decl_mod.pushFnSig(self, f.name.name, sig, f.is_expect or f.is_actual);
            try decl_mod.checkFunction(self, f);
        },
        .Class => |*c| {
            var info = try decl_mod.classInfo(self, c);
            info.is_local_or_anonymous = true;
            try root.putClassChecked(self, c.name.name, info, c.name.span.file);
            try decl_mod.checkClass(self, c);
        },
        .Object => |*o| {
            var info = ClassInfo.init(a);
            info.is_object = true;
            info.is_local_or_anonymous = true;
            info.decl_file = o.name.span.file;
            try decl_mod.collectMembers(self, o.members, &info);
            try root.putClassChecked(self, o.name.name, info, o.name.span.file);
            try decl_mod.checkObject(self, o);
        },
        .TypeAlias => {},
    }
}

pub fn checkAssign(self: *Checker, target: *const Expr, op: AssignOp, value: *const Expr, sp: Span) Allocator.Error!void {
    const a = self.allocator;
    // Ambiguous when both the `*Assign` and binary forms apply.
    if (op != .Assign) {
        try visibility.checkCompoundAssignAmbiguity(self, target, op, sp);
    }
    if (target.* == .Path and target.Path.segments.len == 1) {
        const name = target.Path.segments[0].name;
        const target_span = target.Path.span;
        // `var x; private set`: reject a write from outside that scope.
        if (self.setter_visibility.get(name)) |sv| {
            if (sv.visibility == .Private and target_span.file != sv.file) {
                const msg = try std.fmt.allocPrint(
                    a,
                    "Cannot assign to `{s}`: setter is `private` in its declaring file",
                    .{name},
                );
                try emitErr(self, msg, target_span, codes.TYPE_INVISIBLE_REFERENCE);
            }
        }
        if (narrowing.lookup(self, name)) |b| {
            const want = try b.ty.clone(a);
            const mutable = b.mutable;
            defer {
                var w = want;
                w.deinit(a);
            }
            // VIA reporting `x` unassigned marks this its first and only legal
            // write; no fact at all means a parameter, never a first write.
            const is_first_write = ((try narrowing.cfgViaUnassignedAt(self, name, target_span)) orelse false);
            // Legal on a `val` when the LHS carries a matching `*Assign`,
            // which mutates in place and never rebinds the name.
            const compound_with_assign = op != .Assign and typeHasCompoundAssign(&want, op);
            if (!mutable and !is_first_write and !compound_with_assign) {
                const msg = try std.fmt.allocPrint(a, "Val cannot be reassigned: `{s}`", .{name});
                try emitErr(self, msg, target_span, codes.TYPE_VAL_REASSIGN);
            }
            var got = try self.checkExpr(value, &want);
            defer got.deinit(a);
            // Against the operator's parameter (`list += 100` feeds
            // `plusAssign(element)`), not the receiver type.
            if (!compound_with_assign) {
                try expr_calls.checkAssignable(self, &got, &want, value.span());
            }
            // A KillDataFlow node at each loop head handles reassignment.
            return;
        }
    }
    var t = try self.checkExpr(target, null);
    t.deinit(a);
    var v = try self.checkExpr(value, null);
    v.deinit(a);
}

pub fn checkExpr(self: *Checker, expr: *const Expr, expected: ?*const Type) Allocator.Error!Type {
    // A call's type at a span is fixed and every check of it carries the same
    // expected type, since a call is a receiver or an argument but never both,
    // so reuse turns a deep `a.f().g().h()` chain from 2^depth into depth.
    if (expected == null and expr.* == .Call) {
        if (self.types.getPtr(expr.span())) |cached| {
            return try cached.clone(self.allocator);
        }
    }
    const ty = try computeExprTy(self, expr, expected);
    try recordType(self, expr.span(), &ty);
    return ty;
}

pub fn computeExprTy(self: *Checker, expr: *const Expr, expected: ?*const Type) Allocator.Error!Type {
    const a = self.allocator;
    switch (expr.*) {
        .IntLit => |lit| return tyOfIntLit(self, lit, expected),
        .FloatLit => |lit| return tyOfFloatLit(self, lit, expected),
        .BoolLit => return .Boolean,
        .CharLit => return .Char,
        .NullLit => {
            const inner = try a.create(Type);
            inner.* = .Nothing;
            return .{ .Nullable = inner };
        },
        .StringTemplate => |st| {
            for (st.parts) |*part| {
                if (part.* == .Interp) {
                    var t = try self.checkExpr(part.Interp, null);
                    t.deinit(a);
                }
            }
            return .String;
        },
        .Path => |p| return tyOfPath(self, p),
        .Member => |m| return tyOfMember(self, expr, m),
        .Call => |c| return tyOfCall(self, c),
        .Index => |x| return tyOfIndex(self, x),
        .Binary => |b| return expr_calls.checkBinary(self, b.op, b.lhs, b.rhs, b.span),
        .Unary => |u| return tyOfUnary(self, u),
        .Postfix => |pf| return tyOfPostfix(self, pf),
        .If => |i| return tyOfIf(self, i, expected),
        .While => |w| {
            var ct = try self.checkExpr(w.cond, &boolean_ty);
            ct.deinit(a);
            // Body facts reach the surrounding scope via the CFG.
            var bt = try self.checkExpr(w.body, null);
            bt.deinit(a);
            return .Unit;
        },
        .DoWhile => |w| {
            if (w.body) |b| {
                var bt = try self.checkExpr(b, null);
                bt.deinit(a);
            }
            var ct = try self.checkExpr(w.cond, &boolean_ty);
            ct.deinit(a);
            return .Unit;
        },
        .For => |f| return tyOfFor(self, f),
        .Return => |r| return tyOfReturn(self, r),
        .Break => |br| {
            try checkLabelBound(self, br.label, br.span);
            return .Nothing;
        },
        .Continue => |co| {
            try checkLabelBound(self, co.label, co.span);
            return .Nothing;
        },
        .Labeled => |lab| return tyOfLabeled(self, lab, expected),
        .Block => |*b| return checkBlock(self, b, expected),
        .Throw => |th| return tyOfThrow(self, th),
        .Try => |tr| return tyOfTry(self, tr, expected),
        .Lambda => |l| return expr_calls.checkLambdaShaped(self, l.params, &l.body, expected, l.implicit_it),
        .This => |t| {
            const target: ?[]const u8 = if (t.qualifier) |q|
                q.name
            else if (self.class_stack.items.len > 0)
                self.class_stack.items[self.class_stack.items.len - 1]
            else
                null;
            if (target) |cn| {
                try self.expr_class.put(t.span, cn);
            }
            return .Unresolved;
        },
        .Super, .PropertyRef => return .Unresolved,
        .MemberRef => |mr| return tyOfMemberRef(self, mr),
        .When => |w| return tyOfWhen(self, w, expected),
        .IsCheck => |ic| return tyOfIsCheck(self, ic),
        .As => |as_e| return tyOfAs(self, as_e),
        .AnonFun => |af| return tyOfAnonFun(self, af),
        .Spread => |sp_e| {
            // Invalid outside an argument position, which the call site
            // handles. Recurse so sub-expression diagnostics still surface.
            var t = try self.checkExpr(sp_e.expr, null);
            t.deinit(a);
            return .Unresolved;
        },
        .ObjectExpr => |oe| return tyOfObjectExpr(self, oe),
    }
}

fn tyOfIntLit(self: *Checker, lit: @FieldType(Expr, "IntLit"), expected: ?*const Type) Allocator.Error!Type {
    const a = self.allocator;
    // A suffix pins the type unconditionally; an unsuffixed integer
    // literal coerces to whatever the expected type asks for.
    switch (lit.kind) {
        .Long => return .Long,
        .UInt => return .UInt,
        .ULong => return .ULong,
        .Int => {},
    }
    if (expected) |t| {
        switch (t.nonNull().*) {
            .Long, .Short, .Byte, .Int, .UInt, .ULong, .UShort, .UByte => return t.nonNull().clone(a),
            else => {},
        }
    }
    return .Int;
}

fn tyOfFloatLit(self: *Checker, lit: @FieldType(Expr, "FloatLit"), expected: ?*const Type) Allocator.Error!Type {
    const a = self.allocator;
    if (lit.kind == .Float) return .Float;
    if (expected) |t| {
        switch (t.nonNull().*) {
            .Float, .Double => return t.nonNull().clone(a),
            else => {},
        }
    }
    return .Double;
}

fn tyOfPath(self: *Checker, p: @FieldType(Expr, "Path")) Allocator.Error!Type {
    const a = self.allocator;
    const sp = p.span;
    if (p.segments.len == 1) {
        const name = p.segments[0].name;
        try visibility.enforceDslScopeForMember(self, name, sp);
        // One solve serves both the narrowings and the GADT subst.
        var facts = try narrowing.cfgSmartFactsAt(self, name, sp, true);
        defer {
            var git = facts.gadt.valueIterator();
            while (git.next()) |gt| gt.deinit(a);
            facts.gadt.deinit();
        }
        if (facts.narrowed_class) |cn| {
            try self.expr_class.put(sp, cn);
        }
        if (facts.narrowed) |narrowed| {
            return narrowed;
        }
        if (narrowing.lookup(self, name)) |b| {
            const cn = b.class_name;
            const ty = try b.ty.clone(a);
            if (self.prop_visibility.get(name)) |vf| {
                try visibility.checkTopLevelVisibility(self, name, vf.visibility, vf.file, sp);
                const anns: []const ast.Annotation = self.prop_annotations.get(name) orelse &.{};
                try visibility.checkPublishedApiUse(self, name, vf.visibility, anns, sp);
            }
            // Outside the declaring file, or with narrowing off, the
            // read serves the public type and is recorded so member
            // calls check against it.
            if (b.ebf) |ebf| {
                if (sp.file.int() != ebf.file.int() or self.field_narrow_off > 0) {
                    if (ebf.public_class) |c| {
                        try self.expr_class.put(sp, c);
                    }
                    try self.ebf_outside.put(sp, .{
                        .head = ebf.public_class,
                        .display = ebf.public_display,
                    });
                    var owned = ty;
                    owned.deinit(a);
                    return ebf.public_ty.clone(a);
                }
            }
            // VIA answers nothing for an untracked place, true when no
            // Assign reaches this read, false when every path assigns.
            if (((try narrowing.cfgViaUnassignedAt(self, name, sp)) orelse false)) {
                const msg = try std.fmt.allocPrint(a, "Variable '{s}' must be initialized", .{name});
                try emitErr(self, msg, sp, codes.TYPE_VAR_NOT_DEFINITELY_ASSIGNED);
            }
            if (cn) |c| {
                try self.expr_class.put(sp, c);
            }
            // Inside a branch narrowing a generic receiver, fold the
            // implied type-parameter substitution into the type.
            if (facts.gadt.count() == 0) {
                return ty;
            }
            var owned = ty;
            defer owned.deinit(a);
            return substituteTypeParams(a, &owned, &facts.gadt);
        }
        if (self.fns.get(name)) |sigs| {
            // A reference, not a call: the first overload materializes
            // the function type.
            if (sigs.items.len > 0) {
                const sig = &sigs.items[0];
                const params = try a.alloc(Type, sig.params.len);
                for (sig.params, params) |*pp, *dst| dst.* = try pp.clone(a);
                const ret = try a.create(Type);
                ret.* = try sig.return_ty.clone(a);
                return .{ .Function = .{
                    .params = params,
                    .return_type = ret,
                    .is_suspend = sig.is_suspend,
                } };
            }
        }
        if (self.classes.contains(name)) {
            try self.expr_class.put(sp, name);
            return .Unresolved;
        }
        // Resolved by name but absent from these tables, as stdlib
        // names are. Stay tolerant.
        return .Unresolved;
    }
    return .Unresolved;
}

fn tyOfMember(self: *Checker, expr: *const Expr, m: @FieldType(Expr, "Member")) Allocator.Error!Type {
    const a = self.allocator;
    const sp = m.span;
    if (try dotPathKey(a, expr)) |key| {
        defer a.free(key);
        var facts = try narrowing.cfgSmartFactsAt(self, key, sp, false);
        defer facts.gadt.deinit();
        if (facts.narrowed_class) |cn| {
            try self.expr_class.put(sp, cn);
        }
        if (facts.narrowed) |narrowed| {
            var rt = try self.checkExpr(m.receiver, null);
            rt.deinit(a);
            return narrowed;
        }
    }
    // Rejected when a closer DSL receiver shares a marker with
    // `Outer` and also exposes the member.
    if (m.receiver.* == .This) {
        if (m.receiver.This.qualifier) |q| {
            try visibility.enforceDslScopeForQualifiedThis(self, q.name, m.name.name, m.name.span);
        }
    }
    var recv_ty = try self.checkExpr(m.receiver, null);
    defer recv_ty.deinit(a);
    const recv_class = self.expr_class.get(m.receiver.span());
    return checkMemberAccess(self, &recv_ty, m.name.name, m.safe, m.receiver.span(), recv_class, sp);
}

fn tyOfCall(self: *Checker, c: @FieldType(Expr, "Call")) Allocator.Error!Type {
    const a = self.allocator;
    const sp = c.span;
    if (c.callee.* == .Path and c.callee.Path.segments.len == 1) {
        const name = c.callee.Path.segments[0].name;
        if (self.classes.contains(name)) {
            try self.expr_class.put(sp, name);
        }
    }
    // Unqualified `super.f(...)` needs exactly one contributing direct
    // supertype; more require `super<Type>.f(...)`.
    if (c.callee.* == .Member and c.callee.Member.receiver.* == .Super) {
        const sup = c.callee.Member.receiver.Super;
        const mname = c.callee.Member.name;
        if (sup.qualifier) |*q| {
            try visibility.checkSuperQualifier(self, q, sup.span);
        } else {
            try visibility.checkAmbiguousSuper(self, mname.name, sup.span);
        }
    }
    // So `xs.forEach { return@forEach }` checks.
    const implicit_label: ?[]const u8 = switch (c.callee.*) {
        .Path => |pp| if (pp.segments.len > 0) pp.segments[pp.segments.len - 1].name else null,
        .Member => |mm| mm.name.name,
        else => null,
    };
    if (implicit_label) |l| {
        try self.label_stack.append(a, l);
    }
    const result = try self.checkCall(c.callee, c.args, c.arg_names, c.type_args, sp);
    if (implicit_label != null) {
        _ = self.label_stack.pop();
    }
    if (c.is_infix) {
        try visibility.checkInfixModifier(self, c.callee, c.args, sp);
    }
    return result;
}

fn tyOfIndex(self: *Checker, x: @FieldType(Expr, "Index")) Allocator.Error!Type {
    const a = self.allocator;
    var rt = try self.checkExpr(x.receiver, null);
    rt.deinit(a);
    for (x.args) |*arg| {
        var at = try self.checkExpr(arg, null);
        at.deinit(a);
    }
    // `xs[i]` dispatches `operator fun get`.
    const cls = self.expr_class.get(x.receiver.span());
    try expr_calls.checkUserOperatorKeyword(self, cls, "get", x.span);
    return .Unresolved;
}

fn tyOfUnary(self: *Checker, u: @FieldType(Expr, "Unary")) Allocator.Error!Type {
    const a = self.allocator;
    const t = try self.checkExpr(u.expr, null);
    const cls = self.expr_class.get(u.expr.span());
    const op_name: ?[]const u8 = switch (u.op) {
        .Pos => "unaryPlus",
        .Neg => "unaryMinus",
        .Not => "not",
        .PreInc => "inc",
        .PreDec => "dec",
    };
    if (op_name) |nm| {
        try expr_calls.checkUserOperatorKeyword(self, cls, nm, u.span);
    }
    switch (u.op) {
        .Neg, .Pos => {
            if (isNumeric(&t)) {
                return t;
            } else {
                var owned = t;
                owned.deinit(a);
                return .Unresolved;
            }
        },
        .Not => {
            var owned = t;
            owned.deinit(a);
            return .Boolean;
        },
        .PreInc, .PreDec => return t,
    }
}

fn tyOfPostfix(self: *Checker, pf: @FieldType(Expr, "Postfix")) Allocator.Error!Type {
    const a = self.allocator;
    const t = try self.checkExpr(pf.expr, null);
    const cls = self.expr_class.get(pf.expr.span());
    const op_name: ?[]const u8 = switch (pf.op) {
        .Inc => "inc",
        .Dec => "dec",
        .NotNull => null,
    };
    if (op_name) |nm| {
        try expr_calls.checkUserOperatorKeyword(self, cls, nm, pf.span);
    }
    switch (pf.op) {
        .Inc, .Dec => return t,
        .NotNull => {
            // Narrowing comes from the AssumeNull the lowering emits.
            switch (t) {
                .Nullable => |inner| {
                    const out = try inner.clone(a);
                    var owned = t;
                    owned.deinit(a);
                    return out;
                },
                else => return t,
            }
        },
    }
}

fn tyOfIf(self: *Checker, i: @FieldType(Expr, "If"), expected: ?*const Type) Allocator.Error!Type {
    const a = self.allocator;
    var ct = try self.checkExpr(i.cond, &boolean_ty);
    ct.deinit(a);
    try narrowing.pushFrame(self);
    // Each arm contributes an Assume on its branch and the analyses
    // join at the if's join block.
    var then_ty = try self.checkExpr(i.then_branch, expected);
    defer then_ty.deinit(a);
    narrowing.popFrame(self);
    var else_ty: Type = blk: {
        if (i.else_branch) |e| {
            try narrowing.pushFrame(self);
            const t = try self.checkExpr(e, expected);
            narrowing.popFrame(self);
            break :blk t;
        } else {
            break :blk .Unit;
        }
    };
    defer else_ty.deinit(a);
    return lub(a, &then_ty, &else_ty);
}

fn tyOfFor(self: *Checker, f: @FieldType(Expr, "For")) Allocator.Error!Type {
    const a = self.allocator;
    var it = try self.checkExpr(f.iter, null);
    it.deinit(a);
    // Only the iterable's class is known here, not the iterator's, so
    // the check covers `iterator` alone.
    const cls = self.expr_class.get(f.iter.span());
    try expr_calls.checkUserOperatorKeyword(self, cls, "iterator", f.span);
    try narrowing.pushFrame(self);
    for (f.vars) |*v| {
        try narrowing.currentFrame(self).bindings.put(v.name, .{
            .ty = .Unresolved,
            .mutable = false,
            .decl_span = v.span,
            .class_name = null,
            .decl_type_name = null,
        });
    }
    var bt = try self.checkExpr(f.body, null);
    bt.deinit(a);
    narrowing.popFrame(self);
    return .Unit;
}

fn tyOfReturn(self: *Checker, r: @FieldType(Expr, "Return")) Allocator.Error!Type {
    const a = self.allocator;
    if (r.value) |v| {
        const exp: ?Type = if (self.fn_return_stack.items.len > 0)
            self.fn_return_stack.items[self.fn_return_stack.items.len - 1]
        else
            null;
        var vt = try self.checkExpr(v, if (exp) |*e| e else null);
        vt.deinit(a);
    }
    try checkLabelBound(self, r.label, r.span);
    return .Nothing;
}

fn tyOfLabeled(self: *Checker, lab: @FieldType(Expr, "Labeled"), expected: ?*const Type) Allocator.Error!Type {
    const a = self.allocator;
    if (!isLabelableTarget(lab.expr)) {
        const msg = try std.fmt.allocPrint(
            a,
            "Label `{s}@` can only be attached to a lambda literal, a loop, or a call with a trailing lambda",
            .{lab.label.name},
        );
        try emitErr(self, msg, lab.label.span, codes.TYPE_LABEL_TARGET_NOT_LABELABLE);
    }
    try self.label_stack.append(a, lab.label.name);
    const ty = try self.checkExpr(lab.expr, expected);
    _ = self.label_stack.pop();
    return ty;
}

fn tyOfThrow(self: *Checker, th: @FieldType(Expr, "Throw")) Allocator.Error!Type {
    const a = self.allocator;
    var vty = try self.checkExpr(th.value, null);
    defer vty.deinit(a);
    if (!decl_mod.typeIsThrowableSubtype(self, &vty)) {
        const msg = try std.fmt.allocPrint(
            a,
            "`throw` requires a value whose type is a subtype of `kotlin.Throwable`, but got `{f}`.",
            .{vty},
        );
        try emitErr(self, msg, th.span, codes.TYPE_THROW_NON_THROWABLE);
    }
    // A non-reified type parameter is erased at runtime, so throwing
    // a value of one is unsafe.
    if (th.value.* == .Path and th.value.Path.segments.len == 1) {
        const name = th.value.Path.segments[0].name;
        const decl_ty_name: ?[]const u8 = blk: {
            var idx: usize = self.frames.items.len;
            while (idx > 0) {
                idx -= 1;
                if (self.frames.items[idx].bindings.get(name)) |b| {
                    break :blk b.decl_type_name;
                }
            }
            break :blk null;
        };
        if (decl_ty_name) |tname| {
            const is_type_param = typeParamInScope(self, tname);
            const is_reified = reifiedTypeParam(self, tname);
            if (is_type_param and !is_reified) {
                const msg = try std.fmt.allocPrint(
                    a,
                    "Cannot throw a value of erased type parameter `{s}` — the type must be runtime-available. Mark `{s}` as `reified` on an `inline fun` or throw a concrete exception type.",
                    .{ tname, tname },
                );
                try emitErr(self, msg, th.span, codes.TYPE_RUNTIME_UNAVAILABLE_CATCH_TYPE);
            }
        }
    }
    return .Nothing;
}

fn tyOfTry(self: *Checker, tr: @FieldType(Expr, "Try"), expected: ?*const Type) Allocator.Error!Type {
    const a = self.allocator;
    var acc = try checkBlock(self, &tr.body, expected);
    for (tr.catches) |*c| {
        // Dispatch can match neither an erased type parameter nor a
        // generic exception type with non-star arguments.
        {
            const tname = c.ty.name.name;
            const is_type_param = typeParamInScope(self, tname);
            const is_reified = reifiedTypeParam(self, tname);
            if (is_type_param and !is_reified) {
                const msg = try std.fmt.allocPrint(
                    a,
                    "Cannot catch by an erased type parameter `{s}` — exception types must be runtime-available. Mark it as `reified` on an `inline fun` or use a concrete exception type.",
                    .{tname},
                );
                try emitErr(self, msg, c.ty.span, codes.TYPE_RUNTIME_UNAVAILABLE_CATCH_TYPE);
            }
            var has_concrete_arg = false;
            for (c.ty.type_args) |arg| {
                if (!arg.is_star) {
                    has_concrete_arg = true;
                    break;
                }
            }
            if (has_concrete_arg) {
                const msg = try std.fmt.allocPrint(
                    a,
                    "Cannot catch by a generic exception type `{s}<…>` with concrete type arguments — the arguments are erased at runtime. Use the raw form or star projections.",
                    .{tname},
                );
                try emitErr(self, msg, c.ty.span, codes.TYPE_RUNTIME_UNAVAILABLE_CATCH_TYPE);
            }
        }
        try narrowing.pushFrame(self);
        const cbind = try convertTypeRefLossyH(a, &c.ty);
        try narrowing.currentFrame(self).bindings.put(c.binding.name, .{
            .ty = cbind,
            .mutable = false,
            .decl_span = c.binding.span,
            .class_name = null,
            .decl_type_name = null,
        });
        var cty = try checkBlock(self, &c.body, expected);
        narrowing.popFrame(self);
        defer cty.deinit(a);
        const merged = try lub(a, &acc, &cty);
        acc.deinit(a);
        acc = merged;
    }
    // It runs on the normal continuation, so if it diverges the whole
    // try expression does and the body's normal exit is suppressed.
    if (tr.finally) |fb| {
        var fty = try checkBlock(self, &fb, null);
        defer fty.deinit(a);
        if (fty == .Nothing) {
            acc.deinit(a);
            acc = .Nothing;
        }
    }
    return acc;
}

fn tyOfMemberRef(self: *Checker, mr: @FieldType(Expr, "MemberRef")) Allocator.Error!Type {
    const a = self.allocator;
    // Only a non-nullable runtime-available type, or a `reified`
    // parameter, may appear here.
    if (std.mem.eql(u8, mr.name.name, "class")) {
        if (mr.receiver.* == .Path and mr.receiver.Path.segments.len == 1) {
            const tname = mr.receiver.Path.segments[0].name;
            const is_type_param = typeParamInScope(self, tname);
            if (is_type_param) {
                const is_reified = reifiedTypeParam(self, tname);
                if (!is_reified) {
                    const msg = try std.fmt.allocPrint(
                        a,
                        "`{s}::class` is not allowed — type parameter is erased at runtime. Mark it as `reified` on an `inline fun` to make the class literal available.",
                        .{tname},
                    );
                    try emitErr(self, msg, mr.receiver.span(), codes.TYPE_NON_REIFIED_CLASS_LITERAL);
                }
                // A receiver pass would type `T` as a path and report
                // a misleading unresolved reference.
                return .Unresolved;
            }
        }
        var rty = try self.checkExpr(mr.receiver, null);
        defer rty.deinit(a);
        if (rty == .Nullable) {
            try emitErr(
                self,
                "LHS of `::class` cannot have a nullable type — class literals require a non-nullable runtime type.",
                mr.receiver.span(),
                codes.TYPE_NULLABLE_CLASS_LITERAL_LHS,
            );
        }
        return .Unresolved;
    }
    var rt = try self.checkExpr(mr.receiver, null);
    rt.deinit(a);
    return .Unresolved;
}

fn tyOfWhen(self: *Checker, w: @FieldType(Expr, "When"), expected: ?*const Type) Allocator.Error!Type {
    const a = self.allocator;
    var subj_class: ?[]const u8 = null;
    if (w.subject) |s| {
        var st = try self.checkExpr(s, null);
        st.deinit(a);
        subj_class = self.expr_class.get(s.span());
    }
    // `when (val v = …)` binds `v` for the branch bodies.
    var pushed_binding = false;
    if (w.subject_binding) |b| {
        try narrowing.pushFrame(self);
        pushed_binding = true;
        const ty: Type = blk: {
            if (b.ty) |*t| {
                break :blk try convertTypeRefLossyH(a, t);
            } else if (w.subject) |s| {
                if (self.types.get(s.span())) |t| break :blk try t.clone(a);
                break :blk .Unresolved;
            } else {
                break :blk .Unresolved;
            }
        };
        const class_name: ?[]const u8 = if (w.subject) |s| self.expr_class.get(s.span()) else null;
        try narrowing.currentFrame(self).bindings.put(b.name.name, .{
            .ty = ty,
            .mutable = false,
            .decl_span = b.name.span,
            .class_name = class_name,
            .decl_type_name = null,
        });
    }
    var has_else = false;
    var acc: ?Type = null;
    errdefer if (acc) |*x| x.deinit(a);
    for (w.branches) |*b| {
        for (b.patterns) |*p| {
            switch (p.kind) {
                .Value, .InRange, .NotInRange => |*e| {
                    var et = try self.checkExpr(e, null);
                    et.deinit(a);
                },
                else => {},
            }
        }
        for (b.patterns) |*p| {
            if (p.kind == .Else) has_else = true;
        }
        // `lowerWhenPattern` emits an Assume before each body, so
        // queries inside the arm see refined types with no frame push.
        var t = try self.checkExpr(&b.body, expected);
        if (acc) |*prev| {
            const merged = try lub(a, prev, &t);
            prev.deinit(a);
            t.deinit(a);
            acc = merged;
        } else {
            acc = t;
        }
    }
    _ = &has_else;
    if (subj_class) |cn| {
        try narrowing.checkWhenExhaustive(self, cn, w.branches, w.span);
    }
    if (pushed_binding) {
        narrowing.popFrame(self);
    }
    return acc orelse .Unit;
}

fn tyOfIsCheck(self: *Checker, ic: @FieldType(Expr, "IsCheck")) Allocator.Error!Type {
    const a = self.allocator;
    var lhs_ty = try self.checkExpr(ic.expr, null);
    defer lhs_ty.deinit(a);
    // `null is T?` is always true and `null is T` always false. A
    // null-typed value counts too, not just the literal.
    const lhs_is_null = (ic.expr.* == .NullLit) or
        (lhs_ty == .Nullable and lhs_ty.Nullable.* == .Nothing);
    if (lhs_is_null) {
        const always = if (ic.ty.nullable) !ic.negated else ic.negated;
        const label = if (always) "true" else "false";
        const msg = try std.fmt.allocPrint(
            a,
            "`{s}` is always `{s}`: `null` {s} `{s}`",
            .{
                if (ic.negated) "!is" else "is",
                label,
                if (always) "is" else "is not",
                ic.ty.name.name,
            },
        );
        try emitWarn(self, msg, ic.span, codes.TYPE_UNCHECKED_CAST);
    }
    const target_name = ic.ty.name.name;
    const is_type_param = typeParamInScope(self, target_name);
    const is_reified = reifiedTypeParam(self, target_name);
    if (is_type_param and !is_reified) {
        const op = if (ic.negated) "!is" else "is";
        const msg = try std.fmt.allocPrint(
            a,
            "Cannot check for an instance of an erased type parameter `{s}`. Mark it as `reified` on an `inline fun` to allow `{s}`.",
            .{ target_name, op },
        );
        try emitErr(self, msg, ic.ty.span, codes.TYPE_CANNOT_CHECK_FOR_ERASED_TYPE_PARAMETER);
    }
    return .Boolean;
}

fn tyOfAs(self: *Checker, as_e: @FieldType(Expr, "As")) Allocator.Error!Type {
    const a = self.allocator;
    var subj_ty = try self.checkExpr(as_e.expr, null);
    defer subj_ty.deinit(a);
    var target_ty = try convertTypeRefLossyH(a, &as_e.ty);
    defer target_ty.deinit(a);
    if (subj_ty != .Unresolved and target_ty != .Unresolved and subj_ty.isSubtypeOf(target_ty)) {
        const msg = try std.fmt.allocPrint(
            a,
            "No cast needed: `{f}` is already `{f}`",
            .{ subj_ty, target_ty },
        );
        var d = Diagnostic.warning(msg, as_e.span);
        _ = d.withCode(codes.WARN_USELESS_CAST);
        _ = d.withFactory(&factories.USELESS_CAST);
        try self.diagnostics.emit(self.allocator, d);
    }
    var has_concrete_arg = false;
    for (as_e.ty.type_args) |arg| {
        if (!arg.is_star) {
            has_concrete_arg = true;
            break;
        }
    }
    if (has_concrete_arg) {
        const msg = try std.fmt.allocPrint(
            a,
            "Unchecked cast: target type `{s}` has erased type arguments",
            .{as_e.ty.name.name},
        );
        try emitWarn(self, msg, as_e.ty.span, codes.TYPE_UNCHECKED_CAST);
    }
    // Unchecked at runtime. `as?` can never observe a failure, since
    // it succeeds for any non-null value, so it reports separately.
    {
        const target_name = as_e.ty.name.name;
        const is_type_param = typeParamInScope(self, target_name);
        const is_reified = reifiedTypeParam(self, target_name);
        if (is_type_param and !is_reified) {
            if (as_e.safe) {
                const msg = try std.fmt.allocPrint(
                    a,
                    "Safe cast `as? {s}` cannot be checked at runtime — type parameter is not `reified`",
                    .{target_name},
                );
                try emitWarn(self, msg, as_e.ty.span, codes.TYPE_CAST_TO_NON_REIFIED_TYPE_PARAMETER);
            } else {
                const msg = try std.fmt.allocPrint(
                    a,
                    "Unchecked cast: target type parameter `{s}` is not `reified` and is erased at runtime",
                    .{target_name},
                );
                try emitWarn(self, msg, as_e.ty.span, codes.TYPE_UNCHECKED_CAST);
            }
        }
    }
    var target = try convertTypeRefLossyH(a, &as_e.ty);
    if (classNameFromTyperef(&as_e.ty)) |cn| {
        try self.expr_class.put(as_e.span, cn);
    }
    // Narrowing comes from the AssumeIs emitted for the cast.
    if (as_e.safe) {
        return target.asNullable(a);
    }
    return target;
}

fn tyOfAnonFun(self: *Checker, af: @FieldType(Expr, "AnonFun")) Allocator.Error!Type {
    const a = self.allocator;
    try narrowing.pushFrame(self);
    var receiver_class: ?[]const u8 = null;
    var pushed_receiver_class = false;
    defer {
        if (pushed_receiver_class) {
            _ = self.class_stack.pop();
            var popped = self.dsl_receiver_stack.pop().?;
            popped.markers.deinit();
        }
    }
    if (af.receiver_ty) |*receiver_ty| {
        const receiver_type = try convertTypeRefLossyH(a, receiver_ty);
        receiver_class = classNameFromTyperef(receiver_ty);
        try narrowing.currentFrame(self).bindings.put("this", .{
            .ty = receiver_type,
            .mutable = false,
            .decl_span = null,
            .class_name = receiver_class,
            .decl_type_name = receiver_class,
        });
        if (receiver_class) |cn| {
            var markers = std.StringHashMap(void).init(a);
            if (self.dsl_class_markers.get(cn)) |m| {
                var marker_it = m.keyIterator();
                while (marker_it.next()) |k| try markers.put(k.*, {});
            }
            try self.dsl_receiver_stack.append(a, .{ .name = cn, .markers = markers });
            try self.class_stack.append(a, cn);
            pushed_receiver_class = true;
        }
    }
    for (af.params) |*p| {
        const pty = try convertTypeRefLossyH(a, &p.ty);
        const decl_type_name: ?[]const u8 = if (builtinByName(p.ty.name.name) == null)
            p.ty.name.name
        else
            null;
        try narrowing.currentFrame(self).bindings.put(p.name.name, .{
            .ty = pty,
            .mutable = false,
            .decl_span = p.span,
            .class_name = null,
            .decl_type_name = decl_type_name,
        });
    }
    var ret_expected: Type = if (af.return_ty) |*rt|
        try convertTypeRefLossyH(a, rt)
    else
        .Unresolved;
    defer ret_expected.deinit(a);
    if (af.body) |b| {
        switch (b.*) {
            .Block => |*blk| {
                var bt = try checkBlock(self, blk, &ret_expected);
                bt.deinit(a);
            },
            .Expr => |*e| {
                var et = try self.checkExpr(e, &ret_expected);
                et.deinit(a);
            },
        }
    }
    narrowing.popFrame(self);
    const params_out = try a.alloc(Type, af.params.len);
    for (af.params, params_out) |*p, *dst| dst.* = try convertTypeRefLossyH(a, &p.ty);
    const r = try a.create(Type);
    r.* = if (ret_expected == .Unresolved) .Unit else try ret_expected.clone(a);
    return .{ .Function = .{
        .params = params_out,
        .return_type = r,
        .is_suspend = af.is_suspend,
        .receiver_head = receiver_class,
    } };
}

fn tyOfObjectExpr(self: *Checker, oe: @FieldType(Expr, "ObjectExpr")) Allocator.Error!Type {
    const a = self.allocator;
    // A sealed type's inheritors need a name, so an anonymous object
    // cannot be one. Also catches object and final-class parents.
    for (oe.supertypes) |*s| {
        const pname = s.name.name;
        const parent = root.classNamed(self, pname) orelse continue;
        if (parent.is_sealed) {
            const msg = try std.fmt.allocPrint(
                a,
                "anonymous object cannot inherit from sealed type `{s}`: sealed inheritors must have a fully-qualified name",
                .{pname},
            );
            try emitErr(self, msg, s.span, codes.TYPE_SEALED_INHERITOR_NOT_QUALIFIED);
        }
        if (parent.is_object) {
            const msg = try std.fmt.allocPrint(
                a,
                "anonymous object cannot inherit from object `{s}`: object types cannot be inherited from",
                .{pname},
            );
            try emitErr(self, msg, s.span, codes.TYPE_INHERIT_FROM_OBJECT);
            continue;
        }
        if (!parent.is_interface and !parent.is_open and !parent.is_abstract and !parent.is_sealed) {
            const msg = try std.fmt.allocPrint(
                a,
                "anonymous object cannot inherit from final class `{s}`: declare it `open`, `abstract`, or `sealed`",
                .{pname},
            );
            try emitErr(self, msg, s.span, codes.TYPE_INHERIT_FROM_FINAL_CLASS);
        }
    }
    for (oe.supertype_delegates) |maybe_d| {
        if (maybe_d) |*d| {
            var dt = try self.checkExpr(d, null);
            dt.deinit(a);
        }
    }
    for (oe.supertype_args) |maybe_args| {
        if (maybe_args) |args| {
            for (args) |*arg| {
                var at = try self.checkExpr(arg, null);
                at.deinit(a);
            }
        }
    }
    for (oe.members) |*m| {
        switch (m.*) {
            .Function => |*f| try decl_mod.checkFunction(self, f),
            .Property => |p| {
                if (p.init) |*init| {
                    var it = try self.checkExpr(init, null);
                    it.deinit(a);
                }
                try decl_mod.handleAccessors(self, p);
            },
            else => {},
        }
    }
    return .Unresolved;
}

/// A `break`/`continue`/`return` label must name an enclosing labelable target.
fn checkLabelBound(self: *Checker, label: ?ast.Ident, sp: Span) Allocator.Error!void {
    const l = label orelse return;
    if (!labelStackContains(self, l.name)) {
        const msg = try std.fmt.allocPrint(self.allocator, "label `{s}` is not bound here", .{l.name});
        try emitErr(self, msg, sp, codes.TYPE_UNRESOLVED_LABEL);
    }
}

fn labelStackContains(self: *const Checker, name: []const u8) bool {
    for (self.label_stack.items) |l| {
        if (std.mem.eql(u8, l, name)) return true;
    }
    return false;
}

fn typeParamInScope(self: *const Checker, name: []const u8) bool {
    for (self.type_params_in_scope.items) |*s| {
        if (s.contains(name)) return true;
    }
    return false;
}

fn reifiedTypeParam(self: *const Checker, name: []const u8) bool {
    for (self.reified_type_params.items) |*s| {
        if (s.contains(name)) return true;
    }
    return false;
}

pub fn checkMemberAccess(
    self: *Checker,
    recv_ty: *const Type,
    name: []const u8,
    safe: bool,
    recv_span: Span,
    recv_class: ?[]const u8,
    member_span: Span,
) Allocator.Error!Type {
    const a = self.allocator;
    // Null-safety: dereferencing a known nullable without `?.` or `!!`.
    if (!safe and recv_ty.* == .Nullable) {
        const msg = try std.fmt.allocPrint(
            a,
            "Only safe (?.) or non-null asserted (!!.) calls are allowed on a nullable receiver of type `{f}`",
            .{recv_ty.*},
        );
        try emitErr(self, msg, recv_span, codes.TYPE_NULL_SAFETY);
    }
    // `Nothing` admits no member callable, so only extensions resolve here.
    const recv_is_nothing = (recv_ty.* == .Nothing) or
        (recv_ty.* == .Nullable and recv_ty.Nullable.* == .Nothing);
    var result: Type = .Unresolved;
    errdefer result.deinit(a);
    var found_as_member = false;
    if (recv_class) |class| {
        if (!recv_is_nothing) {
            if (try visibility.lookupMemberThroughChain(self, a, class, name)) |found| {
                result.deinit(a);
                result = found[0];
                found_as_member = true;
                if (found[1]) |cn| {
                    try self.expr_class.put(member_span, cn);
                }
                // Inside the declaring scope the read narrows to the field
                // type; outside, the public type stands and is recorded.
                if (try lookupMemberEbf(self, class, name)) |hit| {
                    const inside = self.field_narrow_off == 0 and classStackContains(self, hit.decl_class);
                    if (inside) {
                        result.deinit(a);
                        result = try hit.ebf.field_ty.clone(a);
                        if (hit.ebf.field_class) |cn| {
                            try self.expr_class.put(member_span, cn);
                        }
                    } else {
                        const head: ?[]const u8 = switch (result.nonNull().*) {
                            .Generic => |g| g.name,
                            else => found[1],
                        };
                        try self.ebf_outside.put(member_span, .{
                            .head = head,
                            .display = hit.ebf.public_display,
                        });
                    }
                }
            }
            try visibility.checkMemberVisibility(self, class, name, class, member_span);
        }
    }
    if (!found_as_member) {
        if (try lookupExtensionProperty(self, recv_ty, recv_class, name)) |ep| {
            result.deinit(a);
            result = try ep.ty.clone(a);
            if (ep.return_class) |cn| {
                try self.expr_class.put(member_span, cn);
            }
        }
    }
    if (safe) {
        return result.asNullable(a);
    }
    return result;
}

/// Returns the record with its declaring class, which anchors the narrowing
/// scope.
pub fn lookupMemberEbf(
    self: *const Checker,
    class: []const u8,
    name: []const u8,
) Allocator.Error!?struct { decl_class: []const u8, ebf: root.EbfMember } {
    const a = self.allocator;
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(a);
    try frontier.append(a, class);
    var steps: usize = 0;
    while (frontier.pop()) |c| {
        if (steps > 64) break;
        steps += 1;
        if ((try seen.getOrPut(c)).found_existing) continue;
        const info = root.classNamed(self, c) orelse continue;
        if (info.member_ebf.get(name)) |hit| {
            return .{ .decl_class = c, .ebf = hit };
        }
        if (info.members.contains(name)) return null;
        for (info.supertypes.items) |s| try frontier.append(a, s);
    }
    return null;
}

/// Its body, methods, init blocks and companions all count as enclosed.
pub fn classStackContains(self: *const Checker, name: []const u8) bool {
    for (self.class_stack.items) |c| {
        if (std.mem.eql(u8, c, name)) return true;
    }
    return false;
}

pub fn lookupExtensionProperty(
    self: *const Checker,
    recv_ty: *const Type,
    recv_class: ?[]const u8,
    name: []const u8,
) Allocator.Error!?ExtensionPropSig {
    const a = self.allocator;
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(a);
    if (recv_class) |c| {
        try keys.append(a, c);
        var seen = std.StringHashMap(void).init(a);
        defer seen.deinit();
        try seen.put(c, {});
        var frontier: std.ArrayList([]const u8) = .empty;
        defer frontier.deinit(a);
        try frontier.append(a, c);
        var steps: usize = 0;
        while (frontier.pop()) |cn| {
            if (steps > 64) break;
            steps += 1;
            const info = root.classNamed(self, cn) orelse continue;
            for (info.supertypes.items) |s| {
                if (!(try seen.getOrPut(s)).found_existing) {
                    try keys.append(a, s);
                    try frontier.append(a, s);
                }
            }
        }
    }
    const head: ?[]const u8 = switch (recv_ty.nonNull().*) {
        .Int => "Int",
        .Long => "Long",
        .Double => "Double",
        .Float => "Float",
        .Boolean => "Boolean",
        .String => "String",
        .Char => "Char",
        .Byte => "Byte",
        .Short => "Short",
        .Generic => |g| g.name,
        else => null,
    };
    if (head) |h| {
        var present = false;
        for (keys.items) |k| {
            if (std.mem.eql(u8, k, h)) {
                present = true;
                break;
            }
        }
        if (!present) try keys.append(a, h);
    }
    try keys.append(a, "Any");
    for (keys.items) |key| {
        const list = self.extension_properties.get(key) orelse continue;
        for (list.items) |*ep| {
            if (std.mem.eql(u8, ep.name, name)) {
                return ep.*;
            }
        }
    }
    return null;
}

/// Walks the receiver's supertype chain, then `Any`, matching name and arity.
pub fn lookupExtension(
    self: *const Checker,
    recv_class: []const u8,
    name: []const u8,
    args: []const Expr,
) Allocator.Error!?struct { sig: FnSig, return_class: ?[]const u8 } {
    const a = self.allocator;
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(a);
    try keys.append(a, recv_class);
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    try seen.put(recv_class, {});
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(a);
    try frontier.append(a, recv_class);
    var steps: usize = 0;
    while (frontier.pop()) |c| {
        if (steps > 64) break;
        steps += 1;
        const info = root.classNamed(self, c) orelse continue;
        for (info.supertypes.items) |s| {
            if (!(try seen.getOrPut(s)).found_existing) {
                try keys.append(a, s);
                try frontier.append(a, s);
            }
        }
    }
    try keys.append(a, "Any");
    for (keys.items) |key| {
        const list = self.extensions.get(key) orelse continue;
        for (list.items) |*ext| {
            if (!std.mem.eql(u8, ext.name, name)) continue;
            if (!extensionArityFits(&ext.sig, args.len)) continue;
            return .{ .sig = ext.sig, .return_class = ext.return_class };
        }
    }
    return null;
}

fn extensionArityFits(sig: *const root.FnSig, n_args: usize) bool {
    var min: usize = 0;
    var has_vararg = false;
    for (sig.has_default, 0..) |h, i| {
        const va = i < sig.is_vararg.len and sig.is_vararg[i];
        if (va) has_vararg = true;
        if (!h and !va) min += 1;
    }
    if (has_vararg) return n_args >= min;
    return n_args >= min and n_args <= sig.params.len;
}

/// Every arity-admitting extension reachable from `recv_class`, its chain and
/// `Any`, most-specific receiver first; the caller then runs full selection.
pub fn lookupExtensionCandidates(
    self: *const Checker,
    recv_class: []const u8,
    name: []const u8,
    n_args: usize,
    out: *std.ArrayList(ExtensionCandidate),
) Allocator.Error!void {
    const a = self.allocator;
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(a);
    try keys.append(a, recv_class);
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    try seen.put(recv_class, {});
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(a);
    try frontier.append(a, recv_class);
    var steps: usize = 0;
    while (frontier.pop()) |c| {
        if (steps > 64) break;
        steps += 1;
        const info = root.classNamed(self, c) orelse continue;
        for (info.supertypes.items) |s| {
            if (!(try seen.getOrPut(s)).found_existing) {
                try keys.append(a, s);
                try frontier.append(a, s);
            }
        }
    }
    try keys.append(a, "Any");
    // Members outrank extensions.
    for (keys.items) |key| {
        const info = root.classNamed(self, key) orelse continue;
        const sigs = info.member_methods.get(name) orelse continue;
        for (sigs.items) |sig| {
            if (!extensionArityFits(&sig, n_args)) continue;
            try out.append(a, .{ .sig = sig, .return_class = null });
        }
    }
    for (keys.items) |key| {
        const list = self.extensions.get(key) orelse continue;
        for (list.items) |*ext| {
            if (!std.mem.eql(u8, ext.name, name)) continue;
            if (!extensionArityFits(&ext.sig, n_args)) continue;
            try out.append(a, .{ .sig = ext.sig, .return_class = ext.return_class });
        }
    }
}

pub const ExtensionCandidate = struct { sig: root.FnSig, return_class: ?[]const u8 };

test {
    std.testing.refAllDecls(@This());
    // Force analysis of the entry points, catching cross-file signature drift.
    _ = &checkBlock;
    _ = &checkStmt;
    _ = &checkLocalDecl;
    _ = &checkAssign;
    _ = &computeExprTy;
    _ = &checkMemberAccess;
    _ = &lookupExtensionProperty;
    _ = &lookupExtension;
}
