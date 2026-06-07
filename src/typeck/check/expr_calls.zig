//! Call-expression checking and overload resolution. Free functions over
//! `*Checker`.

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

/// Single call-dispatch decision tree. `arg_names`/`type_args` are parallel
/// to the parsed `Call` payload. Returns the callee's result type.
pub fn checkCall(
    self: *Checker,
    callee: *const Expr,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const TypeRef,
    call_span: Span,
) Allocator.Error!Type {
    // Direct named-callable case: `foo(args)` where `foo` is a known
    // user fn or class. Otherwise fall back to tolerant typing.
    if (callee.* == .Path and callee.Path.segments.len == 1) {
        const callee_span = callee.Path.span;
        const name = callee.Path.segments[0].name;
        try visibility.enforceDslScopeForMember(self, name, callee_span);
        if (!self.fns.contains(name) and !self.classes.contains(name)) {
            if (try checkToplevelContractCall(self, name, args, call_span)) |ty| {
                return ty;
            }
            // Tolerant bare extension-call fallback. Inside a
            // receiver-typed lambda the implicit receiver makes an
            // extension function callable without a qualifier
            // (`launch { … }` / `async { … }` are `CoroutineScope`
            // extensions). The resolver/typeck have no receiver-type
            // context at a bare call site. Only treat it as an extension
            // call when the trailing arg is a lambda — the receiver-lambda
            // builder shape we care about.
            const looks_like_builder = args.len > 0 and switch (args[args.len - 1]) {
                .Lambda, .AnonFun => true,
                else => false,
            };
            if (looks_like_builder) {
                var ext_sig: ?FnSig = null;
                var it = self.extensions.valueIterator();
                outer: while (it.next()) |list| {
                    for (list.items) |e| {
                        if (std.mem.eql(u8, e.name, name)) {
                            ext_sig = e.sig;
                            break :outer;
                        }
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
            const result = try checkOverloadedCall(self, sigs_list.items, args, arg_names, type_args, callee.span());
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
        if (self.classes.get(name)) |cls| {
            try visibility.checkClassUseVisibility(self, name, &cls, callee_span);
            if (cls.has_secondary_ctors) {
                // Multiple constructor arities exist; the interp picks the
                // matching one at runtime. Skip arity checking and just type
                // each arg loosely.
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
    // Stdlib chain methods on a `List<T>` seeded by `listOf` /
    // `mutableListOf` flow the element type through `map` / `filter` /
    // `fold` / `forEach` so the lambdas they take get a concrete expected
    // parameter type.
    if (callee.* == .Member) {
        const m = callee.Member;
        const mname = m.name.name;
        if (isScopeFn(mname)) {
            if (try checkMemberContractCall(self, m.receiver, mname, args)) |ty| {
                return ty;
            }
        }
        {
            var recv_ty = try expr_mod.checkExpr(self, m.receiver, null);
            recv_ty.deinit(self.allocator);
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
        // Extension-function dispatch on a user class receiver. The receiver
        // was just typed above; walk the recv class chain looking for an
        // extension matching `name` and first-fit on arg types. For a
        // nullable receiver `s: T?`, expr_class is typically not set —
        // derive the head-class name from the receiver type so extension
        // lookup against `T?.foo` extensions still works.
        var class_from_ty: ?[]const u8 = null;
        if (self.expr_class.get(m.receiver.span())) |cn| {
            class_from_ty = cn;
        } else {
            var recv_ty = try expr_mod.checkExpr(self, m.receiver, null);
            defer recv_ty.deinit(self.allocator);
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
            // Visibility check on member method calls. Runs before extension
            // fallback so a private member on the receiver's class is flagged
            // at the use site.
            if (try visibility.lookupMemberVisibility(self, cn, mname) != null) {
                try visibility.checkMemberVisibility(self, cn, mname, cn, m.name.span);
            }
            if (try expr_mod.lookupExtension(self, cn, mname, args)) |ext| {
                const sig = ext.sig;
                if (sig.params.len == 0) {
                    for (args) |*a| {
                        var t = try expr_mod.checkExpr(self, a, null);
                        t.deinit(self.allocator);
                    }
                } else {
                    var t = try checkOverloadedCall(self,
                        &[_]FnSig{sig},
                        args,
                        arg_names,
                        type_args,
                        call_span,
                    );
                    t.deinit(self.allocator);
                }
                if (ext.return_class) |rcn| {
                    try self.expr_class.put(call_span, rcn);
                }
                return try sig.return_ty.clone(self.allocator);
            }
        }
    }
    // Lambda value call: if callee has Function type, check params.
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

fn isScopeFn(name: []const u8) bool {
    return std.mem.eql(u8, name, "let") or std.mem.eql(u8, name, "run") or
        std.mem.eql(u8, name, "apply") or std.mem.eql(u8, name, "also");
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

/// Emit T0115 when a suspending callee is invoked from a non-suspending
/// context. The suspending context is set on entry to every `suspend fun`
/// body and inherited by enclosing lambdas; the non-suspending base case is
/// the top of any non-suspending function or file-top-level code.
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

/// True when `stmts` contains a non-local `return` — one that targets the
/// enclosing function rather than a nested lambda / anonymous-function
/// literal. Crossinline lambdas must not contain such a return because the
/// spliced body lives in the inline call's frame.
pub fn lambdaBodyHasNonlocalReturn(stmts: []const Stmt) bool {
    return helpers.scanLambdaStmtsForReturn(stmts);
}

/// Scan each positional lambda argument against the candidates'
/// `is_crossinline_param` flags. Emit T0056 when a lambda argument whose
/// corresponding parameter is `crossinline` in any candidate carries a
/// non-local `return`. Named-arg positions are resolved against each
/// candidate's `param_names`.
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

/// Picks an overload from `sigs` by first-fit on argument types and drives
/// arity + assignability diagnostics against the chosen signature. Falls
/// back to the first arity-matching signature when no candidate's parameter
/// types are a clean fit, and to the first declared signature when even
/// arity has no match.
pub fn checkOverloadedCall(
    self: *Checker,
    sigs: []const FnSig,
    args: []const Expr,
    arg_names: []const ?[]const u8,
    type_args: []const TypeRef,
    call_span: Span,
) Allocator.Error!Type {
    // Crossinline-lambda non-local-return diagnostic (T0056). If any
    // overload candidate marks the current arg position `crossinline` and
    // the argument is a lambda literal whose body contains a non-local
    // `return` (one not nested inside another lambda), the lambda violates
    // `crossinline`'s contract.
    try checkCrossinlineArgReturns(self, sigs, args, arg_names);
    // Filter the candidate set before any MSC procedure runs. Named-arg
    // names must each map to some parameter of every surviving candidate;
    // explicit `<...>` must match exactly the candidate's declaration-site
    // type-parameter count.
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
        // Emit T0089 / T0092 against the first named arg / call span, then
        // fall back to the unfiltered set so downstream diagnostics (arity,
        // assignability) still surface usefully.
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
        if (has_type_args or sig.type_param_count == 0) {
            return sig.return_ty.clone(self.allocator);
        }
        // Pre-type each argument with its declared parameter type as the
        // expected hint (type-params stay abstract and are treated
        // permissively). A lambda argument whose parameter is `suspend …`
        // is checked in a suspend context, so calls like
        // `runBlocking { delay() }` don't spuriously flag the suspend body.
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
    // Pre-type each argument once; selection consults these types, and
    // assignability checks against the chosen signature reuse them without
    // re-evaluating.
    var arg_tys: std.ArrayList(Type) = .empty;
    defer {
        for (arg_tys.items) |*t| t.deinit(self.allocator);
        arg_tys.deinit(self.allocator);
    }
    for (args) |*a| {
        try arg_tys.append(self.allocator, try expr_mod.checkExpr(self, a, null));
    }
    var chosen: ?*const FnSig = null;
    var arity_match: ?*const FnSig = null;
    var fitting: std.ArrayList(*const FnSig) = .empty;
    defer fitting.deinit(self.allocator);
    for (filtered.items) |s| {
        var min: usize = 0;
        for (s.has_default) |h| {
            if (!h) min += 1;
        }
        const max = s.params.len;
        if (args.len < min or args.len > max) {
            continue;
        }
        if (arity_match == null) {
            arity_match = s;
        }
        var fits = true;
        const n = @min(arg_tys.items.len, s.params.len);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (!arg_tys.items[k].isSubtypeOf(s.params[k])) {
                fits = false;
                break;
            }
        }
        if (fits) try fitting.append(self.allocator, s);
    }
    if (fitting.items.len != 0) {
        // Full MSC pairwise forwarding test, with the integer-widening rule
        // folded into the constraint comparison. Falls back to the
        // widen-only tiebreaker when MSC reports an ambiguity, so untyped
        // corpora remain parity-stable.
        const msc = try helpers.pickMsc(self.allocator, fitting.items, args.len, &self.classes);
        switch (msc) {
            .ok => |best| chosen = best,
            .ambiguous => |frontier| {
                defer self.allocator.free(frontier);
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
                var best: *const FnSig = frontier[0];
                var best_score = helpers.widenScore(frontier[0].params);
                for (frontier[1..]) |s| {
                    const sc = helpers.widenScore(s.params);
                    if (sc < best_score) {
                        best_score = sc;
                        best = s;
                    }
                }
                chosen = best;
            },
        }
    }
    if (chosen == null and arity_match == null) {
        // No candidate is applicable for the call. The single-message form
        // here keeps the diagnostic from multiplying out into one per
        // non-matching overload.
        var arities: std.ArrayList([]u8) = .empty;
        defer {
            for (arities.items) |a| self.allocator.free(a);
            arities.deinit(self.allocator);
        }
        for (filtered.items) |s| {
            var min: usize = 0;
            for (s.has_default) |h| {
                if (!h) min += 1;
            }
            const max = s.params.len;
            if (min == max) {
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
        return .Unresolved;
    }
    const sig = chosen orelse arity_match.?;
    if (has_type_args) {
        try decl_mod.checkTypeArgBounds(self, sig, type_args);
    }
    try enforceSuspendColoring(self, sig.is_suspend, "function", call_span);
    var min: usize = 0;
    for (sig.has_default) |h| {
        if (!h) min += 1;
    }
    const max = sig.params.len;
    if (args.len < min or args.len > max) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Wrong number of arguments: expected {d}..{d}, got {d}",
            .{ min, max, args.len },
        );
        var d = Diagnostic.err(msg, call_span);
        _ = d.withCode(codes.TYPE_ARGUMENT_COUNT);
        try self.diagnostics.emit(self.allocator, d);
    } else {
        const n = @min(@min(args.len, sig.params.len), arg_tys.items.len);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            try checkAssignable(self, &arg_tys.items[k], &sig.params[k], args[k].span());
        }
    }
    if (has_type_args) {
        return sig.return_ty.clone(self.allocator);
    }
    return inferCallReturnWithArgs(self, sig, arg_tys.items, args, call_span);
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

/// Inference run inside a multi-call session so nested generic calls in
/// `args` contribute to a single solver. The outermost call solves once and
/// substitutes; inner calls return their fresh-var-bearing return type for
/// the outer to continue constraining.
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
        };
    }
    var local_subst = std.StringHashMap(Type).init(self.allocator);
    defer {
        var it = local_subst.valueIterator();
        while (it.next()) |t| t.deinit(self.allocator);
        local_subst.deinit();
    }
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
        }
        // Map each argument to its parameter slot, honouring a trailing
        // lambda that binds to the last functional parameter past defaulted
        // middle params (so `async { … }` constrains the lambda against
        // `block`, not `context`).
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
    // The return type carries our fresh inference vars. Outer call
    // resolution (and the lambda re-typing pass below) sees them as
    // `TypeParam(...)` which downstream checks treat permissively. When we
    // are the root call, we solve below and replace them with the concrete
    // substitution.
    var returned = try helpers.substituteTypeParams(self.allocator, &sig.return_ty, &local_subst);
    errdefer returned.deinit(self.allocator);
    // Lambda re-typing: re-check lambda args with substituted expected types
    // when the outer call has begun to refine them.
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
    // Lambda re-typing pass — only meaningful at the root, since the
    // substitution carries the fully-solved types.
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
        // The root closes the session after substitution.
        self.inference_session.?.cs.deinit();
        self.inference_session = null;
    }
    return returned;
}

/// Index of the parameter a trailing-lambda argument binds to, when the
/// call omits defaulted middle parameters. Kotlin lets `obj.async { … }`
/// bind the lambda to the last functional parameter (`block`), skipping the
/// defaulted `context`. Returns the last param idx only for the final
/// argument when it is a lambda, the call passed fewer args than params, and
/// the last parameter is a functional type.
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

pub fn checkArityAndArgs(self: *Checker, sig: *const FnSig, args: []const Expr, call_span: Span) Allocator.Error!void {
    var vararg_idx: ?usize = null;
    for (sig.is_vararg, 0..) |v, i| {
        if (v) {
            vararg_idx = i;
            break;
        }
    }
    const trailing_lambda_idx = trailingLambdaParamIdx(sig, args);
    // Spread arguments must land on a vararg parameter regardless of arity.
    // Emit T0047 up front so the diagnostic still fires when a mis-spread
    // also produces an arity mismatch.
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
    var min_args: usize = 0;
    {
        const n = @min(sig.has_default.len, sig.is_vararg.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!sig.has_default[i] and !sig.is_vararg[i]) min_args += 1;
        }
    }
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
    // Per-arg typing. Spread args must land on a vararg parameter, otherwise
    // emit T0047.
    const trailing_pos: ?usize = if (trailing_lambda_idx != null) args.len - 1 else null;
    for (args, 0..) |*a, i| {
        const is_spread = a.* == .Spread;
        // Map positional index i to a parameter slot. Past the vararg index,
        // every additional positional arg lands on the vararg.
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
            // Recurse into the spread expression for diagnostics.
            const spread_expr = a.Spread.expr;
            var spread_ty = try expr_mod.checkExpr(self, spread_expr, null);
            defer spread_ty.deinit(self.allocator);
            // Spread expression's element type must be a subtype of the
            // vararg parameter's element type.
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

/// Every function reached through a definition-by-convention dispatch site
/// must carry the `operator` modifier. Look up the member (walking
/// supertypes) on the receiver's user-class name and emit T0087 when found
/// without the flag. No diagnostic when the class isn't known (built-in
/// types, type params, generics without bound info).
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
    while (stack.pop()) |name| {
        if ((try visited.getOrPut(name)).found_existing) {
            continue;
        }
        const info = self.classes.get(name) orelse continue;
        if (info.member_flags.get(op_name)) |flags| {
            if (!flags.is_operator) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "`{s}.{s}` is used as an operator-convention function but is missing the `operator` modifier",
                    .{ name, op_name },
                );
                var d = Diagnostic.warning(msg, sp);
                _ = d.withCode(codes.TYPE_OPERATOR_KEYWORD_MISSING);
                try self.diagnostics.emit(self.allocator, d);
            }
            return;
        }
        for (info.supertypes.items) |s| {
            try stack.append(self.allocator, s);
        }
    }
}

pub fn checkBinary(self: *Checker, op: BinOp, lhs: *const Expr, rhs: *const Expr, sp: Span) Allocator.Error!Type {
    var l = try expr_mod.checkExpr(self, lhs, null);
    defer l.deinit(self.allocator);
    // `&&` / `||` narrowing flow is handled by the CFG: the lowering emits
    // AssumeIs / AssumeNull / AssumeRefEq on the rhs block before the rhs
    // expression evaluates, so smart-cast queries at rhs spans see lhs's
    // truthy facts.
    var r = try expr_mod.checkExpr(self, rhs, null);
    defer r.deinit(self.allocator);
    // Dispatch-site `operator` modifier check. Binary arith / range /
    // comparison dispatches on the LHS class; `in` / `!in` dispatches on the
    // RHS class.
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
    // Comparing `x == null` / `x != null` where `x` has a statically known
    // non-nullable type always yields the same value; surface it as W0003 so
    // the user can drop the dead branch.
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
    // An equality between two definitely-distinct types unrelated by
    // subtyping is a compile-time error. Skip when either side is `null`
    // (the null arm routes separately) or when either side typed to
    // `Unresolved` (we have no information).
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
            // When the rhs diverges (return / throw / continue / break, all
            // typed as `Nothing`), control falls through only when the lhs
            // was non-null — the CFG handles that narrowing.
            break :blk try helpers.lub(self.allocator, &lhs_non_null, &r);
        },
        .Assign => .Unit,
    };
}

/// Type-check a stdlib top-level contract call like `run { ... }`,
/// `with(x) { ... }`, `check(c)`, `require(c)`. Returns `null` if the shape
/// does not match any known contract; the caller falls back to normal call
/// dispatch in that case.
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
        // `suspendCoroutine<T> { cont -> … }` returns T, not the lambda's
        // body type (Unit). We don't have a generic-arg-aware path here, so
        // leave the call's result type unresolved — assignment context drives
        // the binding type.
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
    // Builder-style inference. We accept the call shape (one trailing lambda,
    // optional initial capacity for the list / set / map variants) and infer
    // the element / key-value types from the body's `add` / `put` / `yield`
    // calls.
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
            // The `sequence { }` / `iterator { }` block has a `suspend
            // SequenceScope<T>.() -> Unit` type, so `yield` / `yieldAll`
            // (suspend funcs) inside it are in a suspending context.
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
    // `public inline fun repeat(times: Int, action: (Int) -> Unit)`. Being
    // inline, `action` inherits the caller's suspend context — `repeat(n) {
    // delay() }` is legal inside a coroutine builder. Routing through
    // `checkLambdaInPlace` preserves that inheritance.
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
        // The CFG's contract effect emits Assume nodes for `check` /
        // `require` after the call, picking up every refinement the lowering
        // tracked on the condition register.
        return .Unit;
    }
    return null;
}

/// Type-check a member-form scope-function call: `recv.let { ... }`,
/// `recv.run { ... }`, `recv.apply { ... }`, `recv.also { ... }`. Returns
/// `null` if `name` is not a recognized scope function.
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

/// Walk a builder lambda body collecting argument types from every
/// implicit-this call of `target_name` (e.g. `add(x)` in `buildList`).
/// Returns the LUB of those argument types at `arg_idx`.
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

/// A receiver binding for a scope-function lambda: a value type plus the
/// optional user-class name behind it.
pub const ReceiverBinding = struct {
    ty: Type,
    class_name: ?[]const u8,
};

/// Type-check a lambda body without saving/restoring `assigned`. Per the
/// calls-in-place exactly-once contract, assignments performed inside the
/// body must propagate to the enclosing CFG. `it_binding` and `this_binding`
/// supply implicit `it` / `this` from scope-function receivers.
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
    // Pull param types from expected function type, if it's one.
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
    // A lambda assigned to a `suspend (…) -> R` slot becomes a suspending
    // lambda. A lambda passed to an `inline` function is inlined into the
    // caller, so it also inherits the enclosing suspending bit.
    const enclosing_suspend = lastBool(self.suspend_context_stack);
    try self.suspend_context_stack.append(self.allocator, is_suspend or enclosing_suspend);
    // Pick zero vs one phantom `it` based on the expected callable shape. The
    // parser preemptively pushes a synthetic `it` for any zero-`->` lambda
    // body, so when the expected callable is zero-arity we strip that
    // synthetic param.
    const expected_arity: ?usize = if (expected) |exp| switch (exp.nonNull().*) {
        .Function => |f| f.params.len,
        else => null,
    } else null;
    const synthetic_it = params.len == 1 and std.mem.eql(u8, params[0].name, "it") and
        (expected_arity != null and expected_arity.? == 0);
    const effective_empty = params.len == 0 or synthetic_it;
    const bind_it = effective_empty and !(expected_arity != null and expected_arity.? == 0);
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
        if (expected_arity != null and expected_arity.? == 0) {
            // empty params
        } else {
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

// ---- assignability + diagnostics ------------------------------------

pub fn checkAssignable(self: *Checker, src: *const Type, dst: *const Type, sp: Span) Allocator.Error!void {
    if (src.* == .Unresolved or dst.* == .Unresolved) {
        return;
    }
    if (src.isSubtypeOf(dst.*)) {
        return;
    }
    // GADT-style refinement: when the dst carries a type parameter that the
    // CFG knows has been refined to a concrete type at this branch (via an
    // `is`-narrowing on a declared `Super<T>` receiver), substitute and retry.
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
