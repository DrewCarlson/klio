//! Call checking and overload resolution. Free functions over `*Checker`.

const std = @import("std");

const span = @import("span");
const ast = @import("ast");
const diagnostics = @import("diagnostics");
const types = @import("types");

const root = @import("../check.zig");
const helpers = root.helpers;
const expr_mod = @import("expr.zig");
const decl_mod = @import("decl.zig");
const visibility = @import("visibility.zig");
const narrowing = @import("narrowing.zig");

const Allocator = std.mem.Allocator;
const Span = span.Span;
const Checker = root.Checker;
const Binding = root.Binding;
const FnSig = root.FnSig;
const InferenceSession = root.InferenceSession;
const codes = root.codes;

const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Block = ast.Block;
const Ident = ast.Ident;
const BinOp = ast.BinOp;
const TypeRef = ast.TypeRef;

const Diagnostic = diagnostics.Diagnostic;

const Type = types.Type;
const GenericArg = types.GenericArg;
const Variance = types.Variance;

/// Also records the result's class for the call span, so an unannotated
/// `val m = makeThing()` carries a class into member resolution.
pub fn checkCall(
    self: *Checker,
    callee: *const Expr,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const TypeRef,
    call_span: Span,
) Allocator.Error!Type {
    const ty = try checkCallInner(self, callee, args, arg_names, type_args, call_span);
    if (!self.expr_class.contains(call_span)) {
        if (returnClassName(self, &ty)) |cn| {
            self.expr_class.put(call_span, cn) catch {};
        } else if (callee.* == .Path and callee.Path.segments.len == 1) {
            // Class identity rides the signature; one declaration settles it.
            const nm0 = callee.Path.segments[0].name;
            if (self.fns.get(nm0)) |sigs| {
                if (sigs.items.len == 1) {
                    if (sigs.items[0].return_class) |cn| {
                        if (self.classes.contains(cn)) self.expr_class.put(call_span, cn) catch {};
                    }
                }
            } else if (self.extern_fn_return_class) |ext| {
                if (ext.get(nm0)) |cn| {
                    if (self.classes.contains(cn)) self.expr_class.put(call_span, cn) catch {};
                }
            }
        }
    }
    return ty;
}

/// Null unless the result's generic head names a class the module declares.
fn returnClassName(self: *Checker, t: *const Type) ?[]const u8 {
    return switch (t.*) {
        .Generic => |g| if (self.classes.contains(g.name)) g.name else null,
        .Nullable => |inner| returnClassName(self, inner),
        else => null,
    };
}

fn checkCallInner(
    self: *Checker,
    callee: *const Expr,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const TypeRef,
    call_span: Span,
) Allocator.Error!Type {
    call_shape_counts[0] += 1;
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const callee_span = callee.Path.span;
        const name = callee.Path.segments[0].name;
        try visibility.enforceDslScopeForMember(self, name, callee_span);
        if (!self.fns.contains(name) and !self.classes.contains(name)) {
            if (try checkToplevelContractCall(self, name, args, call_span)) |ty| {
                return ty;
            }
            // An implicit receiver makes an extension callable unqualified
            // (`launch { … }`), but a bare call site has no receiver context.
            const looks_like_builder = args.len > 0 and switch (args[args.len - 1]) {
                .Lambda, .AnonFun => true,
                else => false,
            };
            if (looks_like_builder) {
                var ext_sig: ?FnSig = null;
                var it = self.extensions.valueIterator();
                outer: while (it.next()) |list| {
                    for (list.items) |e| {
                        if (!std.mem.eql(u8, e.name, name)) continue;
                        // Otherwise the bare name targets a member of the
                        // builder's receiver, resolved at runtime.
                        const min = sigMinArity(&e.sig);
                        const fits_arity = if (sigVarargIdx(&e.sig) != null)
                            args.len >= min
                        else
                            args.len >= min and args.len <= e.sig.params.len;
                        if (!fits_arity) continue;
                        const lam_slot = if (e.sig.params.len == 0)
                            continue
                        else
                            @min(args.len - 1, e.sig.params.len - 1);
                        if (e.sig.params[lam_slot].nonNull().* != .Function) continue;
                        ext_sig = e.sig;
                        break :outer;
                    }
                }
                if (ext_sig) |sig| {
                    return checkOverloadedCall(self,
                        &[_]FnSig{sig},
                        args,
                        arg_names,
                        type_args,
                        callee.span(),
                    );
                }
            }
        }
        if (self.fns.get(name)) |sigs_list| {
            // A bare call here may target a member of the lambda's eventual
            // receiver, so with no arity match defer to runtime dispatch.
            if (self.lambda_depth > 0) {
                var any_arity_fits = false;
                for (sigs_list.items) |*s| {
                    const min = sigMinArity(s);
                    const fits_arity = if (sigVarargIdx(s) != null)
                        args.len >= min
                    else
                        args.len >= min and args.len <= s.params.len;
                    if (fits_arity) {
                        any_arity_fits = true;
                        break;
                    }
                }
                if (!any_arity_fits) {
                    for (args) |*arg| {
                        var t = try expr_mod.checkExpr(self, arg, null);
                        t.deinit(self.allocator);
                    }
                    return .Unresolved;
                }
            }
            if (self.fn_visibility.get(name)) |entries| {
                for (entries.items) |vf| {
                    try visibility.checkTopLevelVisibility(self, name, vf.visibility, vf.file, callee_span);
                }
            }
            if (self.fn_visibility.get(name)) |entries| {
                const anns_list: ?std.ArrayList([]ast.Annotation) = self.fn_annotations.get(name);
                for (entries.items, 0..) |vf, i| {
                    const anns: []ast.Annotation = if (anns_list) |al|
                        (if (i < al.items.len) al.items[i] else &.{})
                    else
                        &.{};
                    try visibility.checkPublishedApiUse(self, name, vf.visibility, anns, callee_span);
                }
            }
            var is_builder = false;
            if (self.fn_annotations.get(name)) |list| {
                for (list.items) |anns| {
                    if (helpers.annotationsInclude(anns, "BuilderInference")) {
                        is_builder = true;
                        break;
                    }
                }
            }
            const prev_bi = self.builder_inference_active;
            if (is_builder) {
                self.builder_inference_active = true;
            }
            // A same-named extension that fits means the flat top-level map
            // is an incomplete candidate set, so its pick cannot record.
            const extension_may_shadow = self.lambda_depth > 0 and
                anyExtensionFitsArity(self, name, args.len);
            const result = if (extension_may_shadow)
                try checkOverloadedCall(self, sigs_list.items, args, arg_names, type_args, callee.span())
            else
                try checkOverloadedCallRecorded(self, sigs_list.items, args, arg_names, type_args, callee.span(), name);
            self.builder_inference_active = prev_bi;
            return result;
        }
        if (std.mem.eql(u8, name, "listOf") or std.mem.eql(u8, name, "mutableListOf")) {
            var acc: ?Type = null;
            for (args) |*a| {
                var t = try expr_mod.checkExpr(self, a, null);
                if (acc) |prev| {
                    var p = prev;
                    acc = try helpers.lub(self.allocator, &p, &t);
                    p.deinit(self.allocator);
                    t.deinit(self.allocator);
                } else {
                    acc = t;
                }
            }
            const elem = acc orelse Type.Unresolved;
            try putListElem(self, call_span, elem);
            return .Unresolved;
        }
        if (root.classNamed(self, name)) |cls| {
            try visibility.checkClassUseVisibility(self, name, &cls, callee_span);
            if (cls.has_secondary_ctors) {
                // Several arities exist and the runtime picks between them.
                for (args) |*a| {
                    var t = try expr_mod.checkExpr(self, a, null);
                    t.deinit(self.allocator);
                }
                return .Unresolved;
            }
            if (cls.ctor) |sig| {
                try checkArityAndArgs(self, &sig, args, callee.span());
            } else {
                for (args) |*a| {
                    var t = try expr_mod.checkExpr(self, a, null);
                    t.deinit(self.allocator);
                }
            }
            return .Unresolved;
        }
    }
    // Flow a seeded `List<T>` element type through the chain so each lambda
    // gets a concrete expected parameter type.
    if (callee.* == .Member) {
        call_shape_counts[1] += 1;
        const m = callee.Member;
        const mname = m.name.name;
        if (isScopeFn(mname)) {
            if (try checkMemberContractCall(self, m.receiver, mname, args)) |ty| {
                return ty;
            }
        }
        // Type the receiver once and reuse it: re-typing at each member
        // level makes a long `sb.append(..).append(..)` chain cost 2^depth.
        var recv_ty = try expr_mod.checkExpr(self, m.receiver, null);
        defer recv_ty.deinit(self.allocator);
        // Outside its declaring scope the read has the property's public
        // type, so the member resolves against that, not the field type.
        if (self.ebf_outside.get(m.receiver.span())) |info| {
            try enforceEbfPublicMember(self, &info, mname, args.len, m.name.span);
        }
        if (self.list_elem.get(m.receiver.span())) |elem| {
            if (std.mem.eql(u8, mname, "map")) {
                if (args.len > 0) {
                    const expect = Type{ .Function = .{
                        .params = try self.allocator.dupe(Type, &[_]Type{try elem.clone(self.allocator)}),
                        .return_type = try newType(self.allocator, .Unresolved),
                        .is_suspend = false,
                    } };
                    var expect_mut = expect;
                    defer expect_mut.deinit(self.allocator);
                    var ty = try expr_mod.checkExpr(self, &args[0], &expect);
                    var new_elem: Type = switch (ty) {
                        .Function => |f| try f.return_type.clone(self.allocator),
                        else => .Unresolved,
                    };
                    ty.deinit(self.allocator);
                    try putListElem(self, call_span, new_elem);
                    new_elem = .Unresolved;
                    return .Unresolved;
                }
            } else if (std.mem.eql(u8, mname, "filter")) {
                if (args.len > 0) {
                    var expect = Type{ .Function = .{
                        .params = try self.allocator.dupe(Type, &[_]Type{try elem.clone(self.allocator)}),
                        .return_type = try newType(self.allocator, .Boolean),
                        .is_suspend = false,
                    } };
                    defer expect.deinit(self.allocator);
                    var t = try expr_mod.checkExpr(self, &args[0], &expect);
                    t.deinit(self.allocator);
                    try putListElem(self, call_span, try elem.clone(self.allocator));
                    return .Unresolved;
                }
            } else if (std.mem.eql(u8, mname, "forEach")) {
                if (args.len > 0) {
                    var expect = Type{ .Function = .{
                        .params = try self.allocator.dupe(Type, &[_]Type{try elem.clone(self.allocator)}),
                        .return_type = try newType(self.allocator, .Unit),
                        .is_suspend = false,
                    } };
                    defer expect.deinit(self.allocator);
                    var t = try expr_mod.checkExpr(self, &args[0], &expect);
                    t.deinit(self.allocator);
                    return .Unit;
                }
            } else if (std.mem.eql(u8, mname, "fold") and args.len >= 2) {
                const init_ty = try expr_mod.checkExpr(self, &args[0], null);
                var expect = Type{ .Function = .{
                    .params = try self.allocator.dupe(Type, &[_]Type{ try init_ty.clone(self.allocator), try elem.clone(self.allocator) }),
                    .return_type = try newType(self.allocator, try init_ty.clone(self.allocator)),
                    .is_suspend = false,
                } };
                defer expect.deinit(self.allocator);
                var t = try expr_mod.checkExpr(self, &args[1], &expect);
                t.deinit(self.allocator);
                return init_ty;
            }
        }
        // A nullable receiver usually has no `expr_class`, so the head class
        // comes from the receiver type, keeping `T?.foo` extensions reachable.
        var class_from_ty: ?[]const u8 = null;
        if (self.expr_class.get(m.receiver.span())) |cn| {
            class_from_ty = cn;
        } else if (self.rank_class.get(m.receiver.span())) |cn| {
            // Ranking-only: enough to choose candidates, never a type.
            class_from_ty = cn;
        } else {
            // Reuse the receiver typed above; re-typing costs 2^depth.
            class_from_ty = switch (recv_ty.nonNull().*) {
                .Generic => |g| g.name,
                .String => "String",
                .Int => "Int",
                .Long => "Long",
                .Boolean => "Boolean",
                .Char => "Char",
                .Double => "Double",
                .Float => "Float",
                else => null,
            };
        }
        if (class_from_ty) |cn| {
            // Before the extension fallback, so a private member is flagged.
            if (try visibility.lookupMemberVisibility(self, cn, mname) != null) {
                try visibility.checkMemberVisibility(self, cn, mname, cn, m.name.span);
            }
            var cands: std.ArrayList(expr_mod.ExtensionCandidate) = .empty;
            defer cands.deinit(self.allocator);
            try expr_mod.lookupExtensionCandidates(self, cn, mname, args.len, &cands);
            call_shape_counts[2] += 1;
            if (std.c.getenv("KLIO_EAGER_AUDIT") != null) {
                std.debug.print("[EAGER-MEMBER] recv_class={s} name={s} cands={d} ext_key={}\n", .{ cn, mname, cands.items.len, self.extensions.contains(cn) });
            }
            if (cands.items.len != 0) {
                call_shape_counts[3] += 1;
                // Full selection, so `sb.append("x")` picks `append(String)`
                // over an arity-matching sibling.
                var sigs_buf: std.ArrayList(FnSig) = .empty;
                defer sigs_buf.deinit(self.allocator);
                for (cands.items) |c| try sigs_buf.append(self.allocator, c.sig);
                // Complete here: the image publishes every extension on the
                // class and its supertypes, so the pick may record.
                const ret = try checkOverloadedCallRecordedAt(
                    self,
                    sigs_buf.items,
                    args,
                    arg_names,
                    type_args,
                    call_span,
                    mname,
                    m.name.span,
                );
                if (cands.items[0].return_class) |rcn| {
                    // A head good enough to choose the next receiver is not
                    // necessarily one lowering can bind against.
                    if (cands.items[0].sig.extern_fid != null) {
                        try self.rank_class.put(call_span, rcn);
                    } else {
                        try self.expr_class.put(call_span, rcn);
                    }
                }
                return ret;
            }
        }
    }
    const callee_ty = try expr_mod.checkExpr(self, callee, null);
    if (callee_ty == .Function) {
        const f = callee_ty.Function;
        if (f.params.len == args.len) {
            for (args, f.params) |*a, *p| {
                var at = try expr_mod.checkExpr(self, a, p);
                try checkAssignable(self, &at, p, a.span());
                at.deinit(self.allocator);
            }
        } else {
            for (args) |*a| {
                var t = try expr_mod.checkExpr(self, a, null);
                t.deinit(self.allocator);
            }
        }
        try enforceSuspendColoring(self, f.is_suspend, "lambda", call_span);
        const ret = try f.return_type.clone(self.allocator);
        var ct = callee_ty;
        ct.deinit(self.allocator);
        return ret;
    }
    var ct = callee_ty;
    ct.deinit(self.allocator);
    for (args) |*a| {
        var t = try expr_mod.checkExpr(self, a, null);
        t.deinit(self.allocator);
    }
    return .Unresolved;
}

fn anyExtensionFitsArity(self: *const Checker, name: []const u8, n_args: usize) bool {
    var lists = self.extensions.valueIterator();
    while (lists.next()) |list| {
        for (list.items) |*ext| {
            if (!std.mem.eql(u8, ext.name, name)) continue;
            const min = sigMinArity(&ext.sig);
            const fits = if (sigVarargIdx(&ext.sig) != null)
                n_args >= min
            else
                n_args >= min and n_args <= ext.sig.params.len;
            if (fits) {
                return true;
            }
        }
    }
    return false;
}

fn isScopeFn(name: []const u8) bool {
    return std.mem.eql(u8, name, "let") or std.mem.eql(u8, name, "run") or
        std.mem.eql(u8, name, "apply") or std.mem.eql(u8, name, "also");
}

/// The narrower field type is not visible outside the declaring scope, so a
/// member only it supplies is an unresolved reference.
fn enforceEbfPublicMember(
    self: *Checker,
    info: *const root.EbfOutside,
    name: []const u8,
    arg_count: usize,
    sp: Span,
) Allocator.Error!void {
    const head = info.head orelse return;
    // Universal callables on every type (Any members, scope functions).
    const universal = [_][]const u8{
        "toString", "hashCode", "equals", "let",    "run",
        "apply",    "also",     "takeIf", "takeUnless", "to",
    };
    for (universal) |u| {
        if (std.mem.eql(u8, name, u)) return;
    }
    if (readOnlyCollectionLacks(head, name)) {
        return emitEbfUnresolved(self, name, info.display, sp);
    }
    if (self.classes.contains(head)) {
        if (try visibility.lookupMemberThroughChain(self, self.allocator, head, name)) |found| {
            var t = found[0];
            t.deinit(self.allocator);
            return;
        }
        var cands: std.ArrayList(expr_mod.ExtensionCandidate) = .empty;
        defer cands.deinit(self.allocator);
        try expr_mod.lookupExtensionCandidates(self, head, name, arg_count, &cands);
        if (cands.items.len != 0) return;
        return emitEbfUnresolved(self, name, info.display, sp);
    }
}

fn emitEbfUnresolved(self: *Checker, name: []const u8, display: []const u8, sp: Span) Allocator.Error!void {
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "unresolved reference `{s}` on `{s}`",
        .{ name, display },
    );
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(codes.TYPE_UNRESOLVED_REFERENCE);
    _ = d.withFactory(&diagnostics.generated.UNRESOLVED_REFERENCE);
    try self.diagnostics.emit(self.allocator, d);
}

/// The mutation API that exists only on the `Mutable*` subtypes.
fn readOnlyCollectionLacks(head: []const u8, name: []const u8) bool {
    const read_only = [_][]const u8{ "List", "Collection", "Iterable", "Set", "Map" };
    var is_read_only = false;
    for (read_only) |r| {
        if (std.mem.eql(u8, head, r)) {
            is_read_only = true;
            break;
        }
    }
    if (!is_read_only) return false;
    const mutators = [_][]const u8{
        "add",        "addAll",      "addFirst", "addLast",     "remove",
        "removeAt",   "removeAll",   "removeFirst", "removeLast", "retainAll",
        "clear",      "set",         "put",      "putAll",      "putIfAbsent",
        "replaceAll", "removeIf",    "sort",     "getOrPut",    "merge",
        "replace",    "fill",        "shuffle",
    };
    for (mutators) |m| {
        if (std.mem.eql(u8, name, m)) return true;
    }
    return false;
}

fn putListElem(self: *Checker, sp: Span, ty: Type) Allocator.Error!void {
    const gop = try self.list_elem.getOrPut(sp);
    if (gop.found_existing) gop.value_ptr.deinit(self.allocator);
    gop.value_ptr.* = ty;
}

fn newType(allocator: Allocator, t: Type) Allocator.Error!*Type {
    const p = try allocator.create(Type);
    p.* = t;
    return p;
}

/// The suspending context is set on entry to every `suspend fun` body and
/// inherited by enclosing lambdas; top-level code is non-suspending.
pub fn enforceSuspendColoring(
    self: *Checker,
    callee_is_suspend: bool,
    callee_label: []const u8,
    sp: Span,
) Allocator.Error!void {
    if (!callee_is_suspend) {
        return;
    }
    const in_suspend = lastBool(self.suspend_context_stack);
    if (in_suspend) {
        return;
    }
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "suspending {s} called from a non-suspending context",
        .{callee_label},
    );
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(codes.TYPE_SUSPEND_CALL_FROM_NON_SUSPEND);
    try self.diagnostics.emit(self.allocator, d);
}

fn lastBool(stack: std.ArrayList(bool)) bool {
    if (stack.items.len == 0) return false;
    return stack.items[stack.items.len - 1];
}

/// Non-local meaning it targets the enclosing function, not a nested lambda.
/// A crossinline lambda may not contain one: its body is spliced into the
/// inline call's frame.
pub fn lambdaBodyHasNonlocalReturn(stmts: []const Stmt) bool {
    return helpers.scanLambdaStmtsForReturn(stmts);
}

/// Named-argument positions resolve against each candidate's `param_names`.
pub fn checkCrossinlineArgReturns(
    self: *Checker,
    sigs: []const FnSig,
    args: []const Expr,
    arg_names: []const ?[]const u8,
) Allocator.Error!void {
    if (sigs.len == 0) {
        return;
    }
    {
        var any = false;
        for (sigs) |*s| {
            for (s.is_crossinline_param) |x| {
                if (x) {
                    any = true;
                    break;
                }
            }
            if (any) break;
        }
        if (!any) return;
    }
    var next_pos: usize = 0;
    for (args, 0..) |*arg, i| {
        var param_idx: ?usize = null;
        if (i < arg_names.len and arg_names[i] != null) {
            const aname = arg_names[i].?;
            for (sigs) |*s| {
                for (s.param_names, 0..) |p, pi| {
                    if (std.mem.eql(u8, p, aname)) {
                        param_idx = pi;
                        break;
                    }
                }
                if (param_idx != null) break;
            }
        } else {
            param_idx = next_pos;
            next_pos += 1;
        }
        const idx = param_idx orelse continue;
        var is_crossinline_here = false;
        for (sigs) |*s| {
            if (idx < s.is_crossinline_param.len and s.is_crossinline_param[idx]) {
                is_crossinline_here = true;
                break;
            }
        }
        if (!is_crossinline_here) {
            continue;
        }
        if (arg.* == .Lambda and lambdaBodyHasNonlocalReturn(arg.Lambda.body.stmts)) {
            var d = Diagnostic.err(
                "non-local `return` is not allowed inside a lambda passed to a `crossinline` parameter",
                arg.Lambda.span,
            );
            _ = d.withCode(codes.TYPE_CROSSINLINE_PARAM_LEAK);
            try self.diagnostics.emit(self.allocator, d);
        }
    }
}

/// The full Kotlin shadow surface. Bounded; cycles cut by the visit list.
fn classChainHasMember(self: *Checker, class_name: []const u8, name: []const u8) bool {
    var frontier: [24][]const u8 = undefined;
    var seen: [24][]const u8 = undefined;
    var fl: usize = 0;
    var sl: usize = 0;
    frontier[fl] = class_name;
    fl += 1;
    while (fl > 0) {
        fl -= 1;
        const cn = frontier[fl];
        var dup = false;
        for (seen[0..sl]) |v| {
            if (std.mem.eql(u8, v, cn)) dup = true;
        }
        if (dup) continue;
        if (sl >= seen.len) break;
        seen[sl] = cn;
        sl += 1;
        const info = root.classNamed(self, cn) orelse continue;
        if (info.member_sigs.contains(name)) return true;
        for (info.supertypes.items) |sup| {
            if (fl >= frontier.len) break;
            frontier[fl] = sup;
            fl += 1;
        }
    }
    return false;
}

fn typeMentionsTypeParam(t: *const Type) bool {
    return switch (t.*) {
        .TypeParam => true,
        .Nullable => |inner| typeMentionsTypeParam(inner),
        .Generic => |g| blk: {
            for (g.args) |*a| {
                if (!a.is_star and typeMentionsTypeParam(&a.ty)) break :blk true;
            }
            break :blk false;
        },
        .Function => |f| blk: {
            for (f.params) |*p| if (typeMentionsTypeParam(p)) break :blk true;
            break :blk typeMentionsTypeParam(f.return_type);
        },
        else => false,
    };
}

fn sigMentionsTypeParam(sig: *const FnSig) bool {
    for (sig.params) |*p| if (typeMentionsTypeParam(p)) return true;
    return typeMentionsTypeParam(&sig.return_ty);
}

/// `KLIO_EAGER_GATES=1`: which gate drops each candidate resolution.
pub var eager_gate_counts: [7]u64 = @splat(0);
/// `KLIO_EAGER_AUDIT`: [0] calls seen, [1] member callees, [2] those whose
/// receiver class was named, [3] those that found extension candidates.
pub var call_shape_counts: [5]u64 = @splat(0);
fn eagerGate(i: usize) void {
    eager_gate_counts[i] += 1;
}

fn recordResolvedCall(self: *Checker, call_span: Span, sig: *const FnSig, record_name: []const u8) void {
    eagerGate(0);
    // Picking within a vararg family needs the engine's packing logic.
    for (sig.is_vararg) |v| if (v) {
        eagerGate(1);
        return;
    };
    // A guess: `listOf(a, b).minOrNull()` for `a: T` leaves the total-order
    // and IEEE overloads both live, and only the runtime values decide.
    if (sigMentionsTypeParam(sig)) {
        eagerGate(2);
        return;
    }
    // A bare call inside an extension body has that receiver in scope, so a
    // same-named extension on it out-ranks this registry's answer.
    if (self.extension_fn_names.contains(record_name)) {
        eagerGate(3);
        return;
    }
    // Kotlin scoping resolves a bare call to an enclosing class's member,
    // declared or inherited, over any top-level declaration.
    {
        var ci: usize = self.class_stack.items.len;
        while (ci > 0) {
            ci -= 1;
            if (classChainHasMember(self, self.class_stack.items[ci], record_name)) {
                eagerGate(4);
                return;
            }
        }
    }
    // The registry is file-blind, and these are visible in one file only.
    if (sig.decl_span) |ds| {
        if (ds.file.int() != call_span.file.int()) {
            if (self.fn_visibility.get(record_name)) |entries| {
                for (entries.items) |vf| {
                    if (vf.file.int() != ds.file.int()) continue;
                    if (vf.visibility == .Private) {
                        eagerGate(5);
                        return;
                    }
                }
            }
        }
    }
    // The registry is package-blind, so record only a declaration in the
    // caller's own package or a default-imported `kotlin*` one.
    if (sig.decl_span) |ds| {
        const decl_pkg = self.file_packages.get(ds.file.int()) orelse "";
        const call_pkg = self.file_packages.get(call_span.file.int()) orelse "";
        const same = std.mem.eql(u8, decl_pkg, call_pkg);
        const default_imported = std.mem.eql(u8, decl_pkg, "kotlin") or
            std.mem.startsWith(u8, decl_pkg, "kotlin.");
        if (!same and !default_imported) {
            eagerGate(5);
            return;
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    buf.print(self.allocator, "arity={d}", .{sig.params.len}) catch return;
    for (sig.params, 0..) |*pt, i| {
        buf.print(self.allocator, ";p{d}={f}", .{ i, pt.* }) catch return;
    }
    buf.print(self.allocator, ";ret={f}", .{sig.return_ty}) catch return;
    const rendered = self.allocator.dupe(u8, buf.items) catch return;
    eagerGate(6);
    self.resolved_calls.put(record_span_override orelse call_span, .{ .decl_span = sig.decl_span, .render = rendered, .extern_fid = sig.extern_fid }) catch {
        self.allocator.free(rendered);
    };
}

pub fn checkOverloadedCall(
    self: *Checker,
    sigs: []const FnSig,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const TypeRef,
    call_span: Span,
) Allocator.Error!Type {
    return checkOverloadedCallRec(self, sigs, args, arg_names, type_args, call_span, false);
}

/// As `checkOverloadedCall`, for a call form whose candidate set is complete,
/// so the pick may record. A qualified call sees a partial set and must not.
pub fn checkOverloadedCallRecorded(
    self: *Checker,
    sigs: []const FnSig,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const TypeRef,
    call_span: Span,
    record_name: []const u8,
) Allocator.Error!Type {
    return checkOverloadedCallRecImpl(self, sigs, args, arg_names, type_args, call_span, true, record_name);
}

/// A member call keys its record on the member-name span, the identity
/// lowering holds when it decides that call's target.
pub fn checkOverloadedCallRecordedAt(
    self: *Checker,
    sigs: []const FnSig,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const TypeRef,
    call_span: Span,
    record_name: []const u8,
    record_span: Span,
) Allocator.Error!Type {
    const prev = record_span_override;
    record_span_override = record_span;
    defer record_span_override = prev;
    return checkOverloadedCallRecImpl(self, sigs, args, arg_names, type_args, call_span, true, record_name);
}

var record_span_override: ?Span = null;

/// True over a complete universe: the base's own sources at image bake time.
/// Outside it a source-extension pick is refused, since a program that loads
/// packs sees only part of the surface.
pub var complete_universe: bool = false;

fn checkOverloadedCallRec(
    self: *Checker,
    sigs: []const FnSig,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const TypeRef,
    call_span: Span,
    record: bool,
) Allocator.Error!Type {
    return checkOverloadedCallRecImpl(self, sigs, args, arg_names, type_args, call_span, record, "");
}

fn checkOverloadedCallRecImpl(
    self: *Checker,
    sigs: []const FnSig,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const TypeRef,
    call_span: Span,
    record: bool,
    record_name: []const u8,
) Allocator.Error!Type {
    try checkCrossinlineArgReturns(self, sigs, args, arg_names);
    // Every named argument must map to a parameter of each survivor, and
    // explicit `<...>` must match its type-parameter count exactly.
    const has_type_args = type_args.len != 0;
    var filtered: std.ArrayList(*const FnSig) = .empty;
    defer filtered.deinit(self.allocator);
    for (sigs) |*s| {
        if (has_type_args and s.type_param_count != type_args.len) {
            continue;
        }
        var all_named = true;
        for (arg_names) |n| {
            if (n) |nm| {
                var found = false;
                for (s.param_names) |p| {
                    if (std.mem.eql(u8, p, nm)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    all_named = false;
                    break;
                }
            }
        }
        if (all_named) try filtered.append(self.allocator, s);
    }
    if (filtered.items.len == 0 and sigs.len != 0) {
        // Fall back to the unfiltered set so later checks still surface.
        if (has_type_args) {
            var any_count = false;
            for (sigs) |*s| {
                if (s.type_param_count == type_args.len) {
                    any_count = true;
                    break;
                }
            }
            if (!any_count) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "No candidate function accepts {d} type argument(s)",
                    .{type_args.len},
                );
                var d = Diagnostic.err(msg, call_span);
                _ = d.withCode(codes.TYPE_TYPE_ARGUMENT_COUNT_MISMATCH);
                try self.diagnostics.emit(self.allocator, d);
            }
        }
        for (arg_names, 0..) |n, i| {
            if (n) |nm| {
                var found = false;
                for (sigs) |*s| {
                    for (s.param_names) |p| {
                        if (std.mem.eql(u8, p, nm)) {
                            found = true;
                            break;
                        }
                    }
                    if (found) break;
                }
                if (!found) {
                    const sp = if (i < args.len) args[i].span() else call_span;
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "No parameter named `{s}` on any candidate",
                        .{nm},
                    );
                    var d = Diagnostic.err(msg, sp);
                    _ = d.withCode(codes.TYPE_NAMED_PARAMETER_NOT_FOUND);
                    try self.diagnostics.emit(self.allocator, d);
                }
            }
        }
        for (sigs) |*s| try filtered.append(self.allocator, s);
    }
    if (filtered.items.len == 1) {
        const sig = filtered.items[0];
        if (has_type_args) {
            try decl_mod.checkTypeArgBounds(self, sig, type_args);
        }
        try checkArityAndArgs(self, sig, args, call_span);
        try enforceSuspendColoring(self, sig.is_suspend, "function", call_span);
        // Filtering a set down to one is not a typed decision.
        if (record and sigs.len == 1 and !sig.is_extension) recordResolvedCall(self, call_span, sig, record_name);
        if (has_type_args or sig.type_param_count == 0) {
            return sig.return_ty.clone(self.allocator);
        }
        // A `suspend` parameter gives the lambda a suspend context.
        const trailing_idx = trailingLambdaParamIdx(sig, args);
        var arg_tys: std.ArrayList(Type) = .empty;
        defer {
            for (arg_tys.items) |*t| t.deinit(self.allocator);
            arg_tys.deinit(self.allocator);
        }
        for (args, 0..) |*a, i| {
            const pidx = if (i + 1 == args.len) (trailing_idx orelse i) else i;
            const hint: ?*const Type = if (pidx < sig.params.len) &sig.params[pidx] else null;
            try arg_tys.append(self.allocator, try expr_mod.checkExpr(self, a, hint));
        }
        return inferCallReturnWithArgs(self, sig, arg_tys.items, args, call_span);
    }
    // Lambda arguments are deferred: unhinted they would invent a synthetic
    // `it` and poison selection. `Unresolved` fits every candidate meanwhile.
    var arg_tys: std.ArrayList(Type) = .empty;
    defer {
        for (arg_tys.items) |*t| t.deinit(self.allocator);
        arg_tys.deinit(self.allocator);
    }
    for (args) |*a| {
        switch (a.*) {
            .Lambda, .AnonFun => try arg_tys.append(self.allocator, .Unresolved),
            else => try arg_tys.append(self.allocator, try expr_mod.checkExpr(self, a, null)),
        }
    }
    var chosen: ?*const FnSig = null;
    var uncertain_pick = false;
    var arity_match: ?*const FnSig = null;
    var fitting: std.ArrayList(*const FnSig) = .empty;
    defer fitting.deinit(self.allocator);
    for (filtered.items) |s| {
        const va_idx = sigVarargIdx(s);
        const min = sigMinArity(s);
        const max = s.params.len;
        const arity_ok = if (va_idx != null)
            args.len >= min
        else
            args.len >= min and args.len <= max;
        if (!arity_ok) {
            continue;
        }
        if (arity_match == null) {
            arity_match = s;
        }
        var fits = true;
        var k: usize = 0;
        while (k < arg_tys.items.len) : (k += 1) {
            // Past a vararg, every further argument lands on its slot.
            const slot = if (va_idx != null and k >= va_idx.?) va_idx.? else k;
            if (slot >= s.params.len) break;
            if (k < args.len and args[k] == .Spread) {
                // Selection only requires a vararg slot; the element type is
                // checked against the chosen signature later.
                if (va_idx == null or slot != va_idx.?) {
                    fits = false;
                    break;
                }
                continue;
            }
            if (k < args.len and (args[k] == .Lambda or args[k] == .AnonFun)) {
                // `Unresolved` fits anything, but the literal cannot.
                const pslot = s.params[slot].nonNull().*;
                if (pslot != .Function and pslot != .Unresolved and pslot != .TypeParam) {
                    fits = false;
                    break;
                }
                continue;
            }
            if (!arg_tys.items[k].isSubtypeOf(s.params[slot])) {
                fits = false;
                break;
            }
        }
        if (fits) try fitting.append(self.allocator, s);
    }
    // When candidates differ only in the lambda's return type (`sumOf`), that
    // return is the signal, and selection cannot see the deferred body.
    if (chosen == null and fitting.items.len > 1) {
        if (try lambdaReturnTiebreak(self, fitting.items, args)) |s| {
            chosen = s;
        }
    }
    if (chosen == null and fitting.items.len != 0) {
        // Integer widening is folded into the specificity comparison.
        const msc = try helpers.pickMsc(self.allocator, fitting.items, args.len, &self.classes);
        switch (msc) {
            .ok => |best| chosen = best,
            .ambiguous => |frontier| {
                defer self.allocator.free(frontier);
                const res = try resolveAmbiguousFrontier(self, frontier, args, arg_tys.items, call_span);
                chosen = res.sig;
                uncertain_pick = !res.certain;
            },
        }
    }
    if (chosen == null and arity_match == null) {
        // No candidate is applicable. One message, not one per overload.
        var arities: std.ArrayList([]u8) = .empty;
        defer {
            for (arities.items) |a| self.allocator.free(a);
            arities.deinit(self.allocator);
        }
        for (filtered.items) |s| {
            const min = sigMinArity(s);
            const max = s.params.len;
            if (sigVarargIdx(s) != null) {
                try arities.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}+", .{min}));
            } else if (min == max) {
                try arities.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{min}));
            } else {
                try arities.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}..{d}", .{ min, max }));
            }
        }
        const joined = try joinStrings(self.allocator, arities.items, " or ");
        defer self.allocator.free(joined);
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "No candidate accepts {d} argument(s); expected {s}",
            .{ args.len, joined },
        );
        var d = Diagnostic.err(msg, call_span);
        _ = d.withCode(codes.TYPE_NONE_APPLICABLE);
        try self.diagnostics.emit(self.allocator, d);
        // No hint, but walk the deferred bodies for their own diagnostics.
        for (args) |*a| {
            if (a.* != .Lambda and a.* != .AnonFun) continue;
            var t = try expr_mod.checkExpr(self, a, null);
            t.deinit(self.allocator);
        }
        return .Unresolved;
    }
    const sig = chosen orelse arity_match.?;
    // The arity-match fallback is a guess, and an `Unresolved` argument fits
    // every candidate, so neither is evidence.
    const args_decisive = blk: {
        for (arg_tys.items) |*t| {
            var core: *const Type = t;
            while (core.* == .Nullable) core = core.Nullable;
            switch (core.*) {
                .Unresolved, .TypeParam => break :blk false,
                else => {},
            }
        }
        break :blk true;
    };
    // A parameter the checker could not type fits every argument, so a pick
    // reached through it is arity luck, not a typed decision.
    const sig_params_decisive = blk: {
        const va2 = sigVarargIdx(sig);
        var k2: usize = 0;
        while (k2 < args.len) : (k2 += 1) {
            const slot2 = if (va2 != null and k2 >= va2.?) va2.? else k2;
            if (slot2 >= sig.params.len) break;
            if (sig.params[slot2].nonNull().* == .Unresolved) break :blk false;
        }
        break :blk true;
    };
    // Only image extensions are seen in full; a program that loads packs has
    // source extensions the checker never saw.
    if (record and chosen != null and args_decisive and sig_params_decisive and
        (!sig.is_extension or sig.extern_fid != null or complete_universe))
    {
        if (std.c.getenv("KLIO_EAGER_HITS") != null) {
            std.debug.print("[REC-MSC] '{s}' args:", .{record_name});
            for (arg_tys.items) |*t| switch (t.*) {
                .Generic => |g| std.debug.print(" G:{s}", .{g.name}),
                .Nullable => |inner| switch (inner.*) {
                    .Generic => |g| std.debug.print(" N.G:{s}", .{g.name}),
                    else => std.debug.print(" N.{s}", .{@tagName(inner.*)}),
                },
                else => std.debug.print(" {s}", .{@tagName(t.*)}),
            };
            std.debug.print("\n", .{});
        }
        recordResolvedCall(self, call_span, sig, record_name);
    }
    if (has_type_args) {
        try decl_mod.checkTypeArgBounds(self, sig, type_args);
    }
    // Each deferred body is checked exactly once, with its declared shape.
    {
        const t_idx = trailingLambdaParamIdx(sig, args);
        for (args, 0..) |*a, i| {
            if (a.* != .Lambda and a.* != .AnonFun) continue;
            const pidx = if (i + 1 == args.len) (t_idx orelse i) else i;
            const hint: ?*const Type = if (pidx < sig.params.len) &sig.params[pidx] else null;
            const t = try expr_mod.checkExpr(self, a, hint);
            if (i < arg_tys.items.len) {
                arg_tys.items[i].deinit(self.allocator);
                arg_tys.items[i] = t;
            } else {
                var owned = t;
                owned.deinit(self.allocator);
            }
        }
    }
    try enforceSuspendColoring(self, sig.is_suspend, "function", call_span);
    const sig_va_idx = sigVarargIdx(sig);
    const min = sigMinArity(sig);
    const max = sig.params.len;
    const sig_arity_ok = if (sig_va_idx != null)
        args.len >= min
    else
        args.len >= min and args.len <= max;
    if (!sig_arity_ok) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Wrong number of arguments: expected {d}..{d}, got {d}",
            .{ min, max, args.len },
        );
        var d = Diagnostic.err(msg, call_span);
        _ = d.withCode(codes.TYPE_ARGUMENT_COUNT);
        try self.diagnostics.emit(self.allocator, d);
    } else {
        const n = @min(args.len, arg_tys.items.len);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (args[k] == .Spread) continue;
            const slot = if (sig_va_idx != null and k >= sig_va_idx.?) sig_va_idx.? else k;
            if (slot >= sig.params.len) break;
            try checkAssignable(self, &arg_tys.items[k], &sig.params[slot], args[k].span());
        }
    }
    if (has_type_args) {
        if (uncertain_pick) return .Unresolved;
        return sig.return_ty.clone(self.allocator);
    }
    var ret = try inferCallReturnWithArgs(self, sig, arg_tys.items, args, call_span);
    if (uncertain_pick) {
        ret.deinit(self.allocator);
        return .Unresolved;
    }
    return ret;
}

fn sigParamsResolved(sig: *const FnSig) bool {
    for (sig.params) |*p| {
        if (p.nonNull().* == .Unresolved) return false;
    }
    return true;
}

fn argClassName(self: *Checker, args: []const Expr, arg_tys: []const Type, i: usize) ?[]const u8 {
    if (i < args.len) {
        if (self.expr_class.get(args[i].span())) |cn| return cn;
    }
    if (i >= arg_tys.len) return null;
    return switch (arg_tys[i].nonNull().*) {
        .String => "String",
        .Int => "Int",
        .Long => "Long",
        .Boolean => "Boolean",
        .Char => "Char",
        .Double => "Double",
        .Float => "Float",
        .Byte => "Byte",
        .Short => "Short",
        .Generic => |g| g.name,
        else => null,
    };
}

fn classIsSubtypeOf(self: *Checker, sub: []const u8, sup: []const u8) bool {
    if (std.mem.eql(u8, sub, sup)) return true;
    const info = root.classNamed(self, sub) orelse return false;
    var steps: usize = 0;
    for (info.supertypes.items) |s| {
        if (steps > 64) break;
        steps += 1;
        if (classIsSubtypeOf(self, s, sup)) return true;
    }
    return false;
}

/// Selection signal means a resolved type, or a `param_class_names` entry for
/// a user-class parameter typed `Unresolved`.
fn sigParamsKnown(sig: *const FnSig) bool {
    for (sig.params, 0..) |*p, i| {
        if (p.nonNull().* != .Unresolved) continue;
        const cn = if (i < sig.param_class_names.len) sig.param_class_names[i] else null;
        if (cn == null) return false;
    }
    return true;
}

fn paramClassName(sig: *const FnSig, i: usize) ?[]const u8 {
    if (i >= sig.param_class_names.len) return null;
    return sig.param_class_names[i];
}

fn paramListsEqual(a: *const FnSig, b: *const FnSig) bool {
    if (a.params.len != b.params.len) return false;
    for (a.params, b.params, 0..) |pa, pb, i| {
        if (!pa.eql(pb)) return false;
        const ca = paramClassName(a, i);
        const cb = paramClassName(b, i);
        if ((ca == null) != (cb == null)) return false;
        if (ca != null and !std.mem.eql(u8, ca.?, cb.?)) return false;
    }
    return true;
}

/// Type the lambda once with the return left open, then pick the candidate
/// whose function-typed parameter returns what the body returned.
fn lambdaReturnTiebreak(
    self: *Checker,
    pool: []const *const FnSig,
    args: []const Expr,
) Allocator.Error!?*const FnSig {
    if (args.len == 0) return null;
    if (args[args.len - 1] != .Lambda and args[args.len - 1] != .AnonFun) return null;
    const li = args.len - 1;
    const slot = trailingLambdaParamIdx(pool[0], args) orelse li;
    if (slot >= pool[0].params.len) return null;
    if (pool[0].params[slot].nonNull().* != .Function) return null;
    // Unless they differ only there, the body's return says nothing.
    for (pool[1..]) |s| {
        if (s.params.len != pool[0].params.len) return null;
        for (s.params, pool[0].params, 0..) |pa, pb, i| {
            if (i == slot) continue;
            if (!pa.eql(pb)) return null;
        }
    }
    // Open the expected return so the body's own type comes through.
    const first_fn = pool[0].params[slot].nonNull().Function;
    var open_params = try self.allocator.alloc(Type, first_fn.params.len);
    defer self.allocator.free(open_params);
    for (first_fn.params, 0..) |*pt, i| open_params[i] = pt.*;
    var open_ret: Type = .Unresolved;
    const expected = Type{ .Function = .{
        .params = open_params,
        .return_type = &open_ret,
        .is_suspend = first_fn.is_suspend,
    } };
    var lam_ty = try expr_mod.checkExpr(self, &args[li], &expected);
    defer lam_ty.deinit(self.allocator);
    if (lam_ty != .Function) return null;
    const actual_ret = lam_ty.Function.return_type;
    if (actual_ret.* == .Unresolved) return null;
    for (pool) |s| {
        if (slot >= s.params.len) continue;
        const p = s.params[slot].nonNull().*;
        if (p != .Function) continue;
        if (p.Function.return_type.eql(actual_ret.*)) return s;
    }
    return null;
}

const AmbResolution = struct {
    sig: *const FnSig,
    /// False when guesswork broke the tie: the pick still drives argument
    /// checks, but its return type carries no signal.
    certain: bool,
};

/// A frontier routinely holds unresolved or duplicated signatures, where
/// reporting an ambiguity says nothing, so the tiers below run first.
fn resolveAmbiguousFrontier(
    self: *Checker,
    frontier: []const *const FnSig,
    args: []const Expr,
    arg_tys: []const Type,
    call_span: Span,
) Allocator.Error!AmbResolution {
    // Tier 1: candidates whose parameter types fully resolved.
    var resolved: std.ArrayList(*const FnSig) = .empty;
    defer resolved.deinit(self.allocator);
    for (frontier) |s| {
        if (sigParamsResolved(s)) try resolved.append(self.allocator, s);
    }
    if (resolved.items.len == 1) return .{ .sig = resolved.items[0], .certain = true };
    // Tier 2: resolved types or class-name-annotated `Unresolved` slots.
    var known: std.ArrayList(*const FnSig) = .empty;
    defer known.deinit(self.allocator);
    for (frontier) |s| {
        if (sigParamsKnown(s)) try known.append(self.allocator, s);
    }
    if (known.items.len == 1) return .{ .sig = known.items[0], .certain = true };
    const pool: []const *const FnSig = if (known.items.len != 0) known.items else frontier;
    // Tier 3: `decode(CharSequence)` beats `decode(ByteArray)` for a `String`.
    {
        var compatible: std.ArrayList(*const FnSig) = .empty;
        defer compatible.deinit(self.allocator);
        for (pool) |s| {
            var ok = true;
            for (s.params, 0..) |*p, i| {
                if (i >= arg_tys.len) break;
                if (p.nonNull().* != .Unresolved) continue;
                const pc = paramClassName(s, i) orelse continue;
                const ac = argClassName(self, args, arg_tys, i) orelse continue;
                if (!classIsSubtypeOf(self, ac, pc)) {
                    ok = false;
                    break;
                }
            }
            if (ok) try compatible.append(self.allocator, s);
        }
        if (compatible.items.len == 1) return .{ .sig = compatible.items[0], .certain = true };
    }
    var all_same = true;
    for (pool[1..]) |s| {
        if (!paramListsEqual(pool[0], s)) {
            all_same = false;
            break;
        }
    }
    if (all_same) return .{ .sig = pool[0], .certain = true };
    // Also run before selection; here for frontiers reached another way.
    if (try lambdaReturnTiebreak(self, pool, args)) |s| {
        return .{ .sig = s, .certain = true };
    }
    var args_known = true;
    for (arg_tys, 0..) |*t, i| {
        const nn = t.nonNull().*;
        if (nn == .Unresolved or nn == .TypeParam) {
            // A constructor call types as `Unresolved` but has `expr_class`.
            if (i < args.len and self.expr_class.get(args[i].span()) != null) continue;
            args_known = false;
            break;
        }
    }
    var diagnosed = false;
    if (args_known and known.items.len == frontier.len) {
        diagnosed = true;
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |nm| self.allocator.free(nm);
            names.deinit(self.allocator);
        }
        for (frontier) |s| {
            const params_str = try helpers.describeParams(self.allocator, s.params);
            defer self.allocator.free(params_str);
            try names.append(self.allocator, try std.fmt.allocPrint(self.allocator, "({s})", .{params_str}));
        }
        const joined = try joinStrings(self.allocator, names.items, ", ");
        defer self.allocator.free(joined);
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Overload resolution ambiguity between candidates: {s}",
            .{joined},
        );
        var d = Diagnostic.err(msg, call_span);
        _ = d.withCode(codes.TYPE_OVERLOAD_RESOLUTION_AMBIGUITY);
        try self.diagnostics.emit(self.allocator, d);
    }
    var best: *const FnSig = pool[0];
    var best_score = helpers.widenScore(pool[0].params);
    for (pool[1..]) |s| {
        const sc = helpers.widenScore(s.params);
        if (sc < best_score) {
            best_score = sc;
            best = s;
        }
    }
    return .{ .sig = best, .certain = diagnosed };
}

fn joinStrings(allocator: Allocator, parts: []const []const u8, sep: []const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    for (parts, 0..) |p, i| {
        if (i > 0) aw.writer.writeAll(sep) catch return error.OutOfMemory;
        aw.writer.writeAll(p) catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}

/// One session per source-level expression: the outermost call solves and
/// substitutes, inner ones hand back a type still carrying fresh vars.
pub fn inferCallReturnWithArgs(
    self: *Checker,
    sig: *const FnSig,
    arg_tys: []const Type,
    args: []const Expr,
    call_span: Span,
) Allocator.Error!Type {
    const constraints = types.constraints;
    if (sig.type_param_count == 0 or sig.type_param_names.len == 0) {
        return sig.return_ty.clone(self.allocator);
    }
    const is_root = self.inference_session == null;
    if (is_root) {
        self.inference_session = .{
            .cs = constraints.ConstraintSystem.init(self.allocator),
            .depth = 0,
            .all_vars = .empty,
        };
    }
    // The value name slices belong to the constraint system's arena, which
    // outlives this map, so teardown frees the spine only.
    var local_subst = std.StringHashMap(Type).init(self.allocator);
    defer local_subst.deinit();
    var vars: std.ArrayList(constraints.InferenceVar) = .empty;
    defer vars.deinit(self.allocator);
    {
        const session = &self.inference_session.?;
        session.depth += 1;
        for (sig.type_param_names) |name| {
            const unique = try std.fmt.allocPrint(self.allocator, "{s}@{d}-{d}", .{ name, call_span.start, call_span.end });
            defer self.allocator.free(unique);
            const fresh = try session.cs.fresh(unique);
            session.cs.setPreference(fresh[0], .PullUp);
            try local_subst.put(name, fresh[1]);
            try vars.append(self.allocator, fresh[0]);
            // Arena-owned by the constraint system, so the list may borrow.
            if (fresh[1] == .TypeParam) {
                try session.all_vars.append(self.allocator, .{ .unique = fresh[1].TypeParam, .v = fresh[0] });
            }
        }
        // A trailing lambda binds past defaulted middle parameters, so
        // `async { … }` constrains against `block`, not `context`.
        const trailing_idx = trailingLambdaParamIdx(sig, args);
        for (arg_tys, 0..) |at, i| {
            if (at == .Unresolved) {
                continue;
            }
            const pidx = if (i + 1 == arg_tys.len) (trailing_idx orelse i) else i;
            if (pidx >= sig.params.len) {
                continue;
            }
            const p = &sig.params[pidx];
            var p_with_vars = try helpers.substituteTypeParams(self.allocator, p, &local_subst);
            defer p_with_vars.deinit(self.allocator);
            try session.cs.addConstraintWith(
                at,
                p_with_vars,
                .Subtype,
                .{ .CallSite = .{ .span = call_span, .arg_idx = i } },
            );
        }
    }
    // The fresh vars ride out as `TypeParam`, which downstream checks treat
    // permissively, until the root call solves and substitutes.
    var returned = try helpers.substituteTypeParams(self.allocator, &sig.return_ty, &local_subst);
    errdefer returned.deinit(self.allocator);
    var final_subst = std.StringHashMap(Type).init(self.allocator);
    defer {
        var it = final_subst.valueIterator();
        while (it.next()) |t| t.deinit(self.allocator);
        final_subst.deinit();
    }
    {
        var it = local_subst.iterator();
        while (it.next()) |entry| {
            try final_subst.put(entry.key_ptr.*, try entry.value_ptr.clone(self.allocator));
        }
    }
    if (is_root) {
        const session = &self.inference_session.?;
        if (try session.cs.solveToFixpoint()) |_| {
            if (!self.builder_inference_active) {
                var msg: []const u8 = "type inference failed for this call";
                if (session.cs.lastError()) |le| {
                    if (le.provenance == .CallSite) {
                        msg = try std.fmt.allocPrint(
                            self.allocator,
                            "type inference failed for this call; argument {d} does not satisfy the inferred parameter type",
                            .{le.provenance.CallSite.arg_idx + 1},
                        );
                    }
                }
                var d = Diagnostic.err(msg, call_span);
                _ = d.withCode(codes.TYPE_INFERENCE_FAILED);
                try self.diagnostics.emit(self.allocator, d);
            }
            session.depth -= 1;
            if (session.depth == 0) {
                self.inference_session.?.cs.deinit();
                self.inference_session = null;
            }
            returned.deinit(self.allocator);
            return sig.return_ty.clone(self.allocator);
        }
        var staged = try session.cs.solveStaged();
        defer staged.deinit();
        var legacy = try session.cs.solve();
        defer legacy.deinit();
        for (sig.type_param_names, 0..) |name, i| {
            if (i < vars.items.len) {
                const v = vars.items[i];
                const pick = staged.get(v) orelse legacy.get(v);
                if (pick) |t| {
                    if (t != .Nothing) {
                        if (final_subst.getPtr(name)) |existing| existing.deinit(self.allocator);
                        try final_subst.put(name, try t.clone(self.allocator));
                    }
                }
            }
        }
    }
    // Only meaningful at the root, where the substitution is fully solved.
    if (is_root) {
        const trailing_idx = trailingLambdaParamIdx(sig, args);
        for (args, 0..) |*arg, i| {
            if (arg.* != .Lambda) {
                continue;
            }
            const pidx = if (i + 1 == args.len) (trailing_idx orelse i) else i;
            if (pidx >= sig.params.len) {
                continue;
            }
            const param_ty = &sig.params[pidx];
            var expected = try helpers.substituteTypeParams(self.allocator, param_ty, &final_subst);
            defer expected.deinit(self.allocator);
            if (!helpers.expectedChanged(param_ty, &expected)) {
                continue;
            }
            var refined = try expr_mod.checkExpr(self, arg, &expected);
            defer refined.deinit(self.allocator);
            if (expected == .Function and refined == .Function) {
                const r_expected = expected.Function.return_type;
                const r_refined = refined.Function.return_type;
                if (r_expected.* == .TypeParam) {
                    const nm = r_expected.TypeParam;
                    if (r_refined.* != .Unresolved and r_refined.* != .Nothing) {
                        if (final_subst.getPtr(nm)) |existing| existing.deinit(self.allocator);
                        try final_subst.put(nm, try r_refined.clone(self.allocator));
                    }
                }
            }
        }
        returned.deinit(self.allocator);
        returned = try helpers.substituteTypeParams(self.allocator, &sig.return_ty, &final_subst);
    }
    const session = &self.inference_session.?;
    session.depth -= 1;
    if (is_root) {
        // A nested call recorded its result with vars still in flight.
        refreshRecordedTypes(self, session) catch {};
        self.inference_session.?.all_vars.deinit(self.allocator);
        self.inference_session.?.cs.deinit();
        self.inference_session = null;
    }
    return returned;
}

/// An unpinned variable is left alone, so a partially-solved call degrades to
/// "unknown", never to wrong.
fn refreshRecordedTypes(self: *Checker, session: *root.InferenceSession) Allocator.Error!void {
    if (session.all_vars.items.len == 0) return;
    var staged = try session.cs.solveStaged();
    defer staged.deinit();
    var legacy = try session.cs.solve();
    defer legacy.deinit();
    var subst = std.StringHashMap(Type).init(self.allocator);
    defer {
        var vit = subst.valueIterator();
        while (vit.next()) |t| t.deinit(self.allocator);
        subst.deinit();
    }
    for (session.all_vars.items) |sv| {
        const pick = staged.get(sv.v) orelse legacy.get(sv.v) orelse continue;
        if (pick == .Nothing or pick == .Unresolved) continue;
        if (subst.contains(sv.unique)) continue;
        try subst.put(sv.unique, try pick.clone(self.allocator));
    }
    if (subst.count() == 0) return;
    var it = self.types.iterator();
    while (it.next()) |e| {
        if (!typeMentionsTypeParam(e.value_ptr)) continue;
        var replaced = helpers.substituteTypeParams(self.allocator, e.value_ptr, &subst) catch continue;
        if (replaced.eql(e.value_ptr.*)) {
            replaced.deinit(self.allocator);
            continue;
        }
        e.value_ptr.deinit(self.allocator);
        e.value_ptr.* = replaced;
    }
}

/// Kotlin binds it past defaulted middle parameters, so `obj.async { … }`
/// binds `block`, not `context`.
pub fn trailingLambdaParamIdx(sig: *const FnSig, args: []const Expr) ?usize {
    if (args.len == 0 or sig.params.len <= args.len) {
        return null;
    }
    const last = args.len - 1;
    switch (args[last]) {
        .Lambda, .AnonFun => {},
        else => return null,
    }
    const lp = sig.params.len - 1;
    if (sig.params[lp] == .Function) {
        return lp;
    }
    return null;
}

fn sigVarargIdx(sig: *const FnSig) ?usize {
    for (sig.is_vararg, 0..) |v, i| {
        if (v) return i;
    }
    return null;
}

/// Parameters neither defaulted nor `vararg`; a vararg accepts zero.
fn sigMinArity(sig: *const FnSig) usize {
    var min: usize = 0;
    const n = @min(sig.has_default.len, sig.is_vararg.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!sig.has_default[i] and !sig.is_vararg[i]) min += 1;
    }
    return min;
}

pub fn checkArityAndArgs(self: *Checker, sig: *const FnSig, args: []const Expr, call_span: Span) Allocator.Error!void {
    const vararg_idx = sigVarargIdx(sig);
    const trailing_lambda_idx = trailingLambdaParamIdx(sig, args);
    // Up front, so it still fires when the call also mismatches arity.
    if (vararg_idx == null) {
        for (args) |*a| {
            if (a.* == .Spread) {
                var d = Diagnostic.err(
                    "`*` spread argument requires a `vararg` parameter",
                    a.Spread.span,
                );
                _ = d.withCode(codes.TYPE_SPREAD_REQUIRES_VARARG);
                try self.diagnostics.emit(self.allocator, d);
            }
        }
    }
    const min_args = sigMinArity(sig);
    const max_args = sig.params.len;
    const arity_ok = if (vararg_idx != null)
        args.len >= min_args
    else
        args.len >= min_args and args.len <= max_args;
    if (!arity_ok) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Wrong number of arguments: expected {d}..{d}, got {d}",
            .{ min_args, max_args, args.len },
        );
        var d = Diagnostic.err(msg, call_span);
        _ = d.withCode(codes.TYPE_ARGUMENT_COUNT);
        try self.diagnostics.emit(self.allocator, d);
        for (args) |*a| {
            var t = try expr_mod.checkExpr(self, a, null);
            t.deinit(self.allocator);
        }
        return;
    }
    const trailing_pos: ?usize = if (trailing_lambda_idx != null) args.len - 1 else null;
    for (args, 0..) |*a, i| {
        const is_spread = a.* == .Spread;
        // Past the vararg index, every further argument lands on its slot.
        const target_param = if (trailing_pos != null and i == trailing_pos.?)
            trailing_lambda_idx.?
        else if (vararg_idx != null and i >= vararg_idx.?)
            vararg_idx.?
        else
            i;
        if (is_spread) {
            const is_va = if (target_param < sig.is_vararg.len) sig.is_vararg[target_param] else false;
            if (!is_va) {
                var d = Diagnostic.err(
                    "`*` spread argument requires a `vararg` parameter",
                    a.span(),
                );
                _ = d.withCode(codes.TYPE_SPREAD_REQUIRES_VARARG);
                try self.diagnostics.emit(self.allocator, d);
            }
            const spread_expr = a.Spread.expr;
            var spread_ty = try expr_mod.checkExpr(self, spread_expr, null);
            defer spread_ty.deinit(self.allocator);
            // Element type against the vararg's element type.
            if (is_va and target_param < sig.params.len) {
                const param_elem = &sig.params[target_param];
                var spread_elem: ?Type = try helpers.arrayElementType(self.allocator, &spread_ty);
                if (spread_elem == null) {
                    if (self.expr_class.get(spread_expr.span())) |cn| {
                        spread_elem = helpers.primitiveArrayElemByName(cn);
                    }
                }
                if (spread_elem) |*se| {
                    defer se.deinit(self.allocator);
                    if (!se.isSubtypeOf(param_elem.*)) {
                        const se_str = try se.toString(self.allocator);
                        defer self.allocator.free(se_str);
                        const pe_str = try param_elem.toString(self.allocator);
                        defer self.allocator.free(pe_str);
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "spread argument element type `{s}` is not a subtype of vararg parameter element type `{s}`",
                            .{ se_str, pe_str },
                        );
                        var d = Diagnostic.err(msg, spread_expr.span());
                        _ = d.withCode(codes.TYPE_SPREAD_TYPE_MISMATCH);
                        try self.diagnostics.emit(self.allocator, d);
                    }
                }
            }
            continue;
        }
        if (target_param >= sig.params.len) {
            continue;
        }
        const p = &sig.params[target_param];
        var at = try expr_mod.checkExpr(self, a, p);
        defer at.deinit(self.allocator);
        if (vararg_idx == null or vararg_idx.? != target_param) {
            try checkAssignable(self, &at, p, a.span());
        }
    }
}

/// Kotlin requires `operator` on every function reached by convention
/// dispatch. Silent when the receiver class is unknown.
pub fn checkUserOperatorKeyword(
    self: *Checker,
    receiver_class: ?[]const u8,
    op_name: []const u8,
    sp: Span,
) Allocator.Error!void {
    const class_name = receiver_class orelse return;
    var visited = std.StringHashMap(void).init(self.allocator);
    defer visited.deinit();
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, class_name);
    // `operator` is inherited, so an override may omit it.
    var found_name: ?[]const u8 = null;
    while (stack.pop()) |name| {
        if ((try visited.getOrPut(name)).found_existing) {
            continue;
        }
        const info = root.classNamed(self, name) orelse continue;
        if (info.member_flags.get(op_name)) |flags| {
            if (flags.is_operator) {
                return;
            }
            if (found_name == null) found_name = name;
        }
        for (info.supertypes.items) |s| {
            try stack.append(self.allocator, s);
        }
    }
    if (found_name) |name| {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "`{s}.{s}` is used as an operator-convention function but is missing the `operator` modifier",
            .{ name, op_name },
        );
        var d = Diagnostic.warning(msg, sp);
        _ = d.withCode(codes.TYPE_OPERATOR_KEYWORD_MISSING);
        try self.diagnostics.emit(self.allocator, d);
    }
}

pub fn checkBinary(self: *Checker, op: BinOp, lhs: *const Expr, rhs: *const Expr, sp: Span) Allocator.Error!Type {
    var l = try expr_mod.checkExpr(self, lhs, null);
    defer l.deinit(self.allocator);
    // `&&`/`||` narrowing comes from the CFG: an Assume lands on the rhs block
    // before the rhs evaluates, so queries there see the lhs's truthy facts.
    var r = try expr_mod.checkExpr(self, rhs, null);
    defer r.deinit(self.allocator);
    // Arithmetic and comparison dispatch on the lhs; `in`/`!in` on the rhs.
    const op_name: ?[]const u8 = switch (op) {
        .Add => "plus",
        .Sub => "minus",
        .Mul => "times",
        .Div => "div",
        .Rem => "rem",
        .Range => "rangeTo",
        .RangeUntil => "rangeUntil",
        .Lt, .Le, .Gt, .Ge => "compareTo",
        else => null,
    };
    if (op_name) |opn| {
        const cls = self.expr_class.get(lhs.span());
        try checkUserOperatorKeyword(self, cls, opn, sp);
    }
    if (op == .In or op == .NotIn) {
        const cls = self.expr_class.get(rhs.span());
        try checkUserOperatorKeyword(self, cls, "contains", sp);
    }
    // Always the same value on a statically non-nullable `x`.
    if (op == .Eq or op == .Neq or op == .IdentEq or op == .IdentNeq) {
        const null_other: ?*const Type = if (lhs.* == .NullLit)
            &r
        else if (rhs.* == .NullLit)
            &l
        else
            null;
        if (null_other) |other| {
            const is_dead = switch (other.*) {
                .Nullable, .Unresolved, .Nothing => false,
                else => true,
            };
            if (is_dead) {
                const result = op == .Neq or op == .IdentNeq;
                const msg = try std.fmt.allocPrint(self.allocator, "Condition is always '{}'", .{result});
                var d = Diagnostic.warning(msg, sp);
                _ = d.withCode(codes.WARN_SENSELESS_COMPARISON);
                _ = d.withFactory(&diagnostics.generated.SENSELESS_COMPARISON);
                try self.diagnostics.emit(self.allocator, d);
            }
        }
    }
    // Unrelated operand types are an error; `null` routes above and
    // `Unresolved` carries no information.
    if ((op == .Eq or op == .Neq or op == .IdentEq or op == .IdentNeq) and
        lhs.* != .NullLit and rhs.* != .NullLit and
        !helpers.equalityTypesCompatible(&l, &r))
    {
        const is_ref = op == .IdentEq or op == .IdentNeq;
        const code = if (is_ref) codes.TYPE_REFERENCE_EQUALITY_DISTINCT_TYPES else codes.TYPE_VALUE_EQUALITY_DISTINCT_TYPES;
        const label = if (is_ref) "reference equality" else "equality";
        const l_str = try helpers.typeLabel(self.allocator, &l);
        defer self.allocator.free(l_str);
        const r_str = try helpers.typeLabel(self.allocator, &r);
        defer self.allocator.free(r_str);
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{s} between `{s}` and `{s}` is impossible — types are unrelated",
            .{ label, l_str, r_str },
        );
        var d = Diagnostic.err(msg, sp);
        _ = d.withCode(code);
        try self.diagnostics.emit(self.allocator, d);
    }
    return switch (op) {
        .Add => blk: {
            if (l.nonNull().* == .String or r.nonNull().* == .String) {
                break :blk .String;
            } else if (helpers.isNumeric(&l) or helpers.isNumeric(&r)) {
                break :blk helpers.numericLub(&l, &r);
            } else {
                break :blk .Unresolved;
            }
        },
        .Sub, .Mul, .Div, .Rem => blk: {
            if (helpers.isNumeric(&l) or helpers.isNumeric(&r)) {
                break :blk helpers.numericLub(&l, &r);
            } else {
                break :blk .Unresolved;
            }
        },
        .Eq, .Neq, .IdentEq, .IdentNeq, .Lt, .Le, .Gt, .Ge, .In, .NotIn, .And, .Or => .Boolean,
        .Range, .RangeUntil => blk: {
            const inner = helpers.numericLub(&l, &r);
            break :blk Type{ .Range = try newType(self.allocator, inner) };
        },
        .Elvis => blk: {
            if (l != .Nullable and l != .Unresolved and l != .Nothing) {
                var d = Diagnostic.warning(
                    "Elvis operator (?:) always returns the left operand of non-nullable type",
                    sp,
                );
                _ = d.withCode(codes.WARN_USELESS_ELVIS);
                _ = d.withFactory(&diagnostics.generated.USELESS_ELVIS);
                try self.diagnostics.emit(self.allocator, d);
            }
            var lhs_non_null = switch (l) {
                .Nullable => |inner| try inner.clone(self.allocator),
                else => try l.clone(self.allocator),
            };
            defer lhs_non_null.deinit(self.allocator);
            // A diverging rhs leaves fall-through only for a non-null lhs.
            break :blk try helpers.lub(self.allocator, &lhs_non_null, &r);
        },
        .Assign => .Unit,
    };
}

/// Stdlib contract calls: `run`, `with`, `check`, `require`, the builders.
/// Null when the shape matches none, and the caller falls back to dispatch.
pub fn checkToplevelContractCall(
    self: *Checker,
    name: []const u8,
    args: []const Expr,
    call_span: Span,
) Allocator.Error!?Type {
    _ = call_span;
    if (std.mem.eql(u8, name, "run") and args.len == 1) {
        if (args[0] == .Lambda) {
            const lam = args[0].Lambda;
            var ty = try checkLambdaInPlace(self, lam.params, &lam.body, null, null);
            defer ty.deinit(self.allocator);
            return switch (ty) {
                .Function => |f| try f.return_type.clone(self.allocator),
                else => .Unresolved,
            };
        }
        return null;
    }
    if ((std.mem.eql(u8, name, "suspendCoroutine") or
        std.mem.eql(u8, name, "suspendCoroutineUninterceptedOrReturn") or
        std.mem.eql(u8, name, "suspendCancellableCoroutine")) and args.len == 1)
    {
        // This returns T, not the lambda body's `Unit`. With no generic
        // argument in hand, assignment context drives the binding type.
        if (args[0] == .Lambda) {
            const lam = args[0].Lambda;
            try self.suspend_context_stack.append(self.allocator, true);
            var t = try checkLambdaInPlace(self, lam.params, &lam.body, null, null);
            t.deinit(self.allocator);
            _ = self.suspend_context_stack.pop();
        }
        return .Unresolved;
    }
    if (std.mem.eql(u8, name, "with") and args.len == 2) {
        var recv = try expr_mod.checkExpr(self, &args[0], null);
        const recv_cls = self.expr_class.get(args[0].span());
        if (args[1] == .Lambda) {
            const lam = args[1].Lambda;
            var ty = try checkLambdaInPlace(self,
                lam.params,
                &lam.body,
                null,
                .{ .ty = recv, .class_name = recv_cls },
            );
            defer ty.deinit(self.allocator);
            return switch (ty) {
                .Function => |f| try f.return_type.clone(self.allocator),
                else => .Unresolved,
            };
        }
        recv.deinit(self.allocator);
        return null;
    }
    // Element and key/value types come from the body's `add`/`put`/`yield`.
    if ((std.mem.eql(u8, name, "buildList") or std.mem.eql(u8, name, "buildSet")) and
        (args.len >= 1 and args.len <= 2))
    {
        const lambda = &args[args.len - 1];
        var elem: Type = .Nothing;
        if (lambda.* == .Lambda) {
            const lam = lambda.Lambda;
            var t = try checkLambdaInPlace(self, lam.params, &lam.body, null, .{ .ty = .Unresolved, .class_name = null });
            t.deinit(self.allocator);
            elem = try collectBuilderCallArgType(self, &lam.body, "add", 0);
        }
        if (elem == .Nothing or elem == .Unresolved) {
            elem.deinit(self.allocator);
            return .Unresolved;
        }
        const head = if (std.mem.eql(u8, name, "buildList")) "List" else "Set";
        return Type{ .Generic = .{
            .name = try self.allocator.dupe(u8, head),
            .args = try self.allocator.dupe(GenericArg, &[_]GenericArg{.{
                .variance = .Invariant,
                .is_star = false,
                .ty = elem,
            }}),
        } };
    }
    if (std.mem.eql(u8, name, "buildMap") and (args.len >= 1 and args.len <= 2)) {
        const lambda = &args[args.len - 1];
        var k_ty: Type = .Nothing;
        var v_ty: Type = .Nothing;
        if (lambda.* == .Lambda) {
            const lam = lambda.Lambda;
            var t = try checkLambdaInPlace(self, lam.params, &lam.body, null, .{ .ty = .Unresolved, .class_name = null });
            t.deinit(self.allocator);
            k_ty = try collectBuilderCallArgType(self, &lam.body, "put", 0);
            v_ty = try collectBuilderCallArgType(self, &lam.body, "put", 1);
        }
        if (k_ty == .Nothing or k_ty == .Unresolved or v_ty == .Nothing or v_ty == .Unresolved) {
            k_ty.deinit(self.allocator);
            v_ty.deinit(self.allocator);
            return .Unresolved;
        }
        return Type{ .Generic = .{
            .name = try self.allocator.dupe(u8, "Map"),
            .args = try self.allocator.dupe(GenericArg, &[_]GenericArg{
                .{ .variance = .Invariant, .is_star = false, .ty = k_ty },
                .{ .variance = .Invariant, .is_star = false, .ty = v_ty },
            }),
        } };
    }
    if ((std.mem.eql(u8, name, "sequence") or std.mem.eql(u8, name, "iterator")) and args.len == 1) {
        var elem: Type = .Nothing;
        if (args[0] == .Lambda) {
            const lam = args[0].Lambda;
            // The block is `suspend SequenceScope<T>.() -> Unit`, so `yield`
            // inside it is in a suspending context.
            try self.suspend_context_stack.append(self.allocator, true);
            var t = try checkLambdaInPlace(self, lam.params, &lam.body, null, .{ .ty = .Unresolved, .class_name = null });
            t.deinit(self.allocator);
            _ = self.suspend_context_stack.pop();
            elem = try collectBuilderCallArgType(self, &lam.body, "yield", 0);
        }
        if (elem == .Nothing or elem == .Unresolved) {
            elem.deinit(self.allocator);
            return .Unresolved;
        }
        const head = if (std.mem.eql(u8, name, "sequence")) "Sequence" else "Iterator";
        return Type{ .Generic = .{
            .name = try self.allocator.dupe(u8, head),
            .args = try self.allocator.dupe(GenericArg, &[_]GenericArg{.{
                .variance = .Invariant,
                .is_star = false,
                .ty = elem,
            }}),
        } };
    }
    if (std.mem.eql(u8, name, "buildString") and args.len == 1) {
        if (args[0] == .Lambda) {
            const lam = args[0].Lambda;
            var t = try checkLambdaInPlace(self, lam.params, &lam.body, null, .{ .ty = .Unresolved, .class_name = "StringBuilder" });
            t.deinit(self.allocator);
        }
        return .String;
    }
    // `repeat` is inline, so `action` inherits the caller's suspend context
    // and `repeat(n) { delay() }` is legal inside a coroutine builder.
    if (std.mem.eql(u8, name, "repeat") and args.len == 2) {
        const int_ty: Type = .Int;
        var t0 = try expr_mod.checkExpr(self, &args[0], &int_ty);
        t0.deinit(self.allocator);
        if (args[1] == .Lambda) {
            const lam = args[1].Lambda;
            var t = try checkLambdaInPlace(self, lam.params, &lam.body, .{ .ty = .Int, .class_name = null }, null);
            t.deinit(self.allocator);
        } else {
            var t = try expr_mod.checkExpr(self, &args[1], null);
            t.deinit(self.allocator);
        }
        return .Unit;
    }
    if ((std.mem.eql(u8, name, "check") or std.mem.eql(u8, name, "require")) and
        (args.len >= 1 and args.len <= 2))
    {
        const bool_ty: Type = .Boolean;
        var cond_ty = try expr_mod.checkExpr(self, &args[0], &bool_ty);
        cond_ty.deinit(self.allocator);
        for (args[1..]) |*a| {
            var t = try expr_mod.checkExpr(self, a, null);
            t.deinit(self.allocator);
        }
        // The CFG's contract effect emits the Assume nodes after the call.
        return .Unit;
    }
    return null;
}

/// `recv.let`, `recv.run`, `recv.apply`, `recv.also`; null for anything else.
pub fn checkMemberContractCall(
    self: *Checker,
    recv: *const Expr,
    name: []const u8,
    args: []const Expr,
) Allocator.Error!?Type {
    if (args.len != 1) {
        return null;
    }
    if (args[0] != .Lambda) {
        return null;
    }
    const lam = args[0].Lambda;
    const recv_ty = try expr_mod.checkExpr(self, recv, null);
    const recv_cls = self.expr_class.get(recv.span());
    if (std.mem.eql(u8, name, "let")) {
        var ty = try checkLambdaInPlace(self,
            lam.params,
            &lam.body,
            .{ .ty = recv_ty, .class_name = recv_cls },
            null,
        );
        defer ty.deinit(self.allocator);
        return switch (ty) {
            .Function => |f| try f.return_type.clone(self.allocator),
            else => .Unresolved,
        };
    } else if (std.mem.eql(u8, name, "run")) {
        var ty = try checkLambdaInPlace(self,
            lam.params,
            &lam.body,
            null,
            .{ .ty = recv_ty, .class_name = recv_cls },
        );
        defer ty.deinit(self.allocator);
        return switch (ty) {
            .Function => |f| try f.return_type.clone(self.allocator),
            else => .Unresolved,
        };
    } else if (std.mem.eql(u8, name, "apply")) {
        var t = try checkLambdaInPlace(self,
            lam.params,
            &lam.body,
            null,
            .{ .ty = try recv_ty.clone(self.allocator), .class_name = recv_cls },
        );
        t.deinit(self.allocator);
        return recv_ty;
    } else if (std.mem.eql(u8, name, "also")) {
        var t = try checkLambdaInPlace(self,
            lam.params,
            &lam.body,
            .{ .ty = try recv_ty.clone(self.allocator), .class_name = recv_cls },
            null,
        );
        t.deinit(self.allocator);
        return recv_ty;
    }
    var rt = recv_ty;
    rt.deinit(self.allocator);
    return null;
}

/// LUB of the `arg_idx` argument over every implicit-this call of
/// `target_name`, such as `add(x)` inside `buildList`.
pub fn collectBuilderCallArgType(
    self: *Checker,
    body: *const Block,
    target_name: []const u8,
    arg_idx: usize,
) Allocator.Error!Type {
    var acc: ?Type = null;
    try walkBuilderBlock(self, body, target_name, arg_idx, &acc);
    return acc orelse Type.Nothing;
}

pub fn walkBuilderBlock(
    self: *Checker,
    body: *const Block,
    target_name: []const u8,
    arg_idx: usize,
    acc: *?Type,
) Allocator.Error!void {
    for (body.stmts) |*s| {
        switch (s.*) {
            .Expr => |*e| try walkBuilderExpr(self, e, target_name, arg_idx, acc),
            .Assign => |a| try walkBuilderExpr(self, &a.value, target_name, arg_idx, acc),
            .DestructuringDecl => |d| try walkBuilderExpr(self, &d.init, target_name, arg_idx, acc),
            .Decl => {},
        }
    }
}

pub fn walkBuilderExpr(
    self: *Checker,
    expr: *const Expr,
    target_name: []const u8,
    arg_idx: usize,
    acc: *?Type,
) Allocator.Error!void {
    if (expr.* == .Call) {
        const c = expr.Call;
        const cname: ?[]const u8 = switch (c.callee.*) {
            .Path => |p| if (p.segments.len == 1) p.segments[0].name else null,
            else => null,
        };
        if (cname != null and std.mem.eql(u8, cname.?, target_name) and arg_idx < c.args.len) {
            const t = try expr_mod.checkExpr(self, &c.args[arg_idx], null);
            if (acc.*) |*prev| {
                const merged = try helpers.lub(self.allocator, prev, &t);
                prev.deinit(self.allocator);
                var tt = t;
                tt.deinit(self.allocator);
                acc.* = merged;
            } else {
                acc.* = t;
            }
        }
        for (c.args) |*a| {
            try walkBuilderExpr(self, a, target_name, arg_idx, acc);
        }
    }
}

/// A scope-function receiver: a value type plus the user-class name behind it.
pub const ReceiverBinding = struct {
    ty: Type,
    class_name: ?[]const u8,
};

/// Under the calls-in-place exactly-once contract an assignment inside the
/// body must reach the enclosing CFG, so `assigned` is not saved or restored.
pub fn checkLambdaInPlace(
    self: *Checker,
    params: []const Ident,
    body: *const Block,
    it_binding: ?ReceiverBinding,
    this_binding: ?ReceiverBinding,
) Allocator.Error!Type {
    try narrowing.pushFrame(self);
    if (params.len == 0) {
        const ib = it_binding orelse ReceiverBinding{ .ty = .Unresolved, .class_name = null };
        try narrowing.currentFrame(self).bindings.put("it", .{
            .ty = ib.ty,
            .mutable = false,
            .decl_span = null,
            .class_name = ib.class_name,
            .decl_type_name = null,
        });
    } else {
        for (params) |p| {
            try narrowing.currentFrame(self).bindings.put(p.name, .{
                .ty = .Unresolved,
                .mutable = false,
                .decl_span = p.span,
                .class_name = null,
                .decl_type_name = null,
            });
        }
    }
    if (this_binding) |tb| {
        try narrowing.currentFrame(self).bindings.put("this", .{
            .ty = tb.ty,
            .mutable = false,
            .decl_span = null,
            .class_name = tb.class_name,
            .decl_type_name = null,
        });
        if (tb.class_name) |cn| {
            var markers = std.StringHashMap(void).init(self.allocator);
            if (self.dsl_class_markers.get(cn)) |m| {
                var it = m.keyIterator();
                while (it.next()) |k| try markers.put(k.*, {});
            }
            try self.dsl_receiver_stack.append(self.allocator, .{ .name = cn, .markers = markers });
            try self.class_stack.append(self.allocator, cn);
            if (std.c.getenv("KLIO_RH_TRACE") != null)
                std.debug.print("[rh-put] site=inplace f={d} s={d}..{d} head={s}\n", .{ body.span.file.int(), body.span.start, body.span.end, cn });
            self.lambda_recv_heads.put(body.span, cn) catch {};
            const actual_ret = try expr_mod.checkBlock(self, body, null);
            _ = self.class_stack.pop();
            var popped = self.dsl_receiver_stack.pop().?;
            popped.markers.deinit();
            narrowing.popFrame(self);
            return Type{ .Function = .{
                .params = try self.allocator.alloc(Type, 0),
                .return_type = try newType(self.allocator, actual_ret),
                .is_suspend = false,
            } };
        }
    }
    const actual_ret = try expr_mod.checkBlock(self, body, null);
    narrowing.popFrame(self);
    return Type{ .Function = .{
        .params = try self.allocator.alloc(Type, 0),
        .return_type = try newType(self.allocator, actual_ret),
        .is_suspend = false,
    } };
}

pub fn checkLambda(
    self: *Checker,
    params: []const Ident,
    body: *const Block,
    expected: ?*const Type,
) Allocator.Error!Type {
    return checkLambdaShaped(self, params, body, expected, false);
}

fn resolvedParamIsReferenced(self: *const Checker, param_span: Span) bool {
    return self.resolution.referenced_decls.contains(param_span);
}

pub fn checkLambdaShaped(
    self: *Checker,
    params: []const Ident,
    body: *const Block,
    expected: ?*const Type,
    implicit_it: bool,
) Allocator.Error!Type {
    var param_tys: std.ArrayList(Type) = .empty;
    defer {
        for (param_tys.items) |*t| t.deinit(self.allocator);
        param_tys.deinit(self.allocator);
    }
    var ret_expected: Type = .Unresolved;
    var is_suspend = false;
    if (expected) |exp| {
        const nn = exp.nonNull();
        if (nn.* == .Function) {
            const f = nn.Function;
            for (f.params) |*p| try param_tys.append(self.allocator, try p.clone(self.allocator));
            ret_expected = try f.return_type.clone(self.allocator);
            is_suspend = f.is_suspend;
            // The head that answers member-versus-global inside the body.
            if (f.receiver_head) |h| {
                if (std.c.getenv("KLIO_RH_TRACE") != null)
                    std.debug.print("[rh-put] site=shaped f={d} s={d}..{d} head={s}\n", .{ body.span.file.int(), body.span.start, body.span.end, h });
                self.lambda_recv_heads.put(body.span, h) catch {};
            }
            // Lowering falls back to this for a cross-pack member call, whose
            // callee is not in its name index.
            self.lambda_param_shapes.put(body.span, .{
                .has_receiver = f.receiver_head != null,
                .arity = @intCast(f.params.len),
            }) catch {};
            // Same, for function-typed params the AST leaves unannotated.
            for (params, 0..) |p2, i| {
                if (i >= f.params.len) break;
                const pt = &f.params[i];
                const core: *const Type = if (pt.* == .Nullable) pt.Nullable else pt;
                if (core.* == .Function) {
                    self.lambda_param_shapes.put(p2.span, .{
                        .has_receiver = core.Function.receiver_head != null,
                        .arity = @intCast(core.Function.params.len),
                    }) catch {};
                }
            }
        } else {
            const count = @max(params.len, 1);
            var i: usize = 0;
            while (i < count) : (i += 1) try param_tys.append(self.allocator, .Unresolved);
        }
    } else {
        const count = @max(params.len, 1);
        var i: usize = 0;
        while (i < count) : (i += 1) try param_tys.append(self.allocator, .Unresolved);
    }
    defer ret_expected.deinit(self.allocator);
    try narrowing.pushFrame(self);
    // A lambda in a `suspend` slot is suspending, and one passed to an
    // `inline` function inherits the enclosing bit. An unknown shape might be
    // either, so it is checked permissively.
    const enclosing_suspend = lastBool(self.suspend_context_stack);
    const unknown_shape = expected == null or expected.?.nonNull().* != .Function;
    try self.suspend_context_stack.append(self.allocator, is_suspend or enclosing_suspend or unknown_shape);
    self.lambda_depth += 1;
    defer self.lambda_depth -= 1;
    // The parser pushes a synthetic `it` for every zero-`->` lambda, so real
    // arity comes from the expected type; with none, it is `() -> R`.
    const expected_arity: ?usize = if (expected) |exp| switch (exp.nonNull().*) {
        .Function => |f| f.params.len,
        else => null,
    } else null;
    const synthetic_it = params.len == 1 and implicit_it and
        !(expected_arity != null and expected_arity.? >= 1);
    const effective_empty = params.len == 0 or synthetic_it;
    const expected_binds_it = effective_empty and expected_arity != null and expected_arity.? >= 1;
    // A generic parameter (`listOf({ it })`) has no shape until its argument
    // supplies one, so infer arity one only if the parameter is read.
    const inferred_it = effective_empty and expected_arity == null and
        narrowing.lookup(self, "it") == null and params.len == 1 and
        resolvedParamIsReferenced(self, params[0].span);
    const bind_it = expected_binds_it or inferred_it;
    if (bind_it) {
        const it_ty = if (param_tys.items.len > 0) try param_tys.items[0].clone(self.allocator) else Type.Unresolved;
        try narrowing.currentFrame(self).bindings.put("it", .{
            .ty = it_ty,
            .mutable = false,
            .decl_span = null,
            .class_name = null,
            .decl_type_name = null,
        });
    } else if (!effective_empty) {
        for (params, 0..) |p, i| {
            const pt = if (i < param_tys.items.len) try param_tys.items[i].clone(self.allocator) else Type.Unresolved;
            try narrowing.currentFrame(self).bindings.put(p.name, .{
                .ty = pt,
                .mutable = false,
                .decl_span = p.span,
                .class_name = null,
                .decl_type_name = null,
            });
        }
    }
    const actual_ret = try expr_mod.checkBlock(self, body, &ret_expected);
    _ = self.suspend_context_stack.pop();
    narrowing.popFrame(self);
    const return_type = if (ret_expected == .Unresolved)
        actual_ret
    else blk: {
        var ar = actual_ret;
        ar.deinit(self.allocator);
        break :blk try ret_expected.clone(self.allocator);
    };
    var params_out: std.ArrayList(Type) = .empty;
    errdefer {
        for (params_out.items) |*t| t.deinit(self.allocator);
        params_out.deinit(self.allocator);
    }
    if (effective_empty) {
        if (expected_binds_it or inferred_it) {
            const first = if (param_tys.items.len > 0) try param_tys.items[0].clone(self.allocator) else Type.Unresolved;
            try params_out.append(self.allocator, first);
        }
    } else {
        for (params, 0..) |_, i| {
            const pt = if (i < param_tys.items.len) try param_tys.items[i].clone(self.allocator) else Type.Unresolved;
            try params_out.append(self.allocator, pt);
        }
    }
    return Type{ .Function = .{
        .params = try params_out.toOwnedSlice(self.allocator),
        .return_type = try newType(self.allocator, return_type),
        .is_suspend = is_suspend,
    } };
}

pub fn checkAssignable(self: *Checker, src: *const Type, dst: *const Type, sp: Span) Allocator.Error!void {
    if (src.* == .Unresolved or dst.* == .Unresolved) {
        return;
    }
    if (src.isSubtypeOf(dst.*)) {
        return;
    }
    // GADT refinement: substitute any type parameter the CFG narrowed at this
    // branch and retry.
    var gadt = try narrowing.cfgGadtSubstAt(self, sp);
    defer {
        var it = gadt.valueIterator();
        while (it.next()) |t| t.deinit(self.allocator);
        gadt.deinit();
    }
    if (gadt.count() != 0) {
        var dst_refined = try helpers.substituteTypeParams(self.allocator, dst, &gadt);
        defer dst_refined.deinit(self.allocator);
        if (src.isSubtypeOf(dst_refined)) {
            return;
        }
    }
    const src_str = try src.toString(self.allocator);
    defer self.allocator.free(src_str);
    const dst_str = try dst.toString(self.allocator);
    defer self.allocator.free(dst_str);
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "Type mismatch: inferred type is `{s}` but `{s}` was expected",
        .{ src_str, dst_str },
    );
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(codes.TYPE_MISMATCH);
    try self.diagnostics.emit(self.allocator, d);
}

test {
    std.testing.refAllDecls(@This());
}
