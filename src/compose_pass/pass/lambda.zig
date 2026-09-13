//! Post-resolution composable lambda argument transform and the capture
//! analysis behind memoized lambda lifting.

const std = @import("std");
const ast = @import("ast");
const span_mod = @import("span");
const root = @import("../compose_pass.zig");

const Span = span_mod.Span;
const Expr = ast.Expr;
const Stmt = ast.Stmt;

const collect = @import("collect.zig");
const NameSetOracle = collect.NameSetOracle;
const lambdaHasComposerParams = collect.lambdaHasComposerParams;
const composeAuditOn = collect.composeAuditOn;

const epilogue = @import("epilogue.zig");
const trailingLambda = epilogue.trailingLambda;
const memoWrappedLambda = epilogue.memoWrappedLambda;

const walker = @import("walker.zig");
const Walker = walker.Walker;

/// Transform a lambda argument after IR call resolution has selected its exact
/// declaration and parameter. The overload-precise path for composable
/// parameters that are not the source trailing lambda (`Scaffold(topBar = {…})`).
pub fn transformResolvedComposableLambda(
    a: std.mem.Allocator,
    arg: *Expr,
    expected_params: u8,
    implicit_label: ?[]const u8,
    callee_inline: bool,
) std.mem.Allocator.Error!bool {
    const lam = trailingLambda(arg) orelse memoWrappedLambda(arg) orelse return false;
    if (lambdaHasComposerParams(lam)) {
        // The pass already shaped this lambda; repair it against the declared
        // arity of the parameter resolution just selected. The pass shapes
        // headerless lambdas with the bare pair only, and the resolved
        // declaration is the authority on the synthetic slot count. A one-short
        // lambda gains the implicit `it`; one over is the flattened receiver
        // slot the declared arity omits and is left alone. Anything else is
        // audited.
        const user_n = lam.params.len - 2;
        if (user_n + 1 == expected_params) {
            const np = a.alloc(ast.Ident, lam.params.len + 1) catch return false;
            np[0] = .{ .name = "it", .span = lam.params[0].span };
            @memcpy(np[1..], lam.params);
            const nt = a.alloc(?ast.TypeRef, lam.param_tys.len + 1) catch return false;
            nt[0] = null;
            @memcpy(nt[1..], lam.param_tys);
            lam.params = np;
            lam.param_tys = nt;
            return true;
        }
        if (user_n < expected_params or user_n > @as(usize, expected_params) + 1) {
            root.compose_audit.lambda_arity_mismatch += 1;
            if (composeAuditOn()) {
                std.debug.print(
                    "[KLIO_RESOLVE_AUDIT] compose lambda-arity pass={d} declared={d}\n",
                    .{ user_n, expected_params },
                );
            }
        }
        return false;
    }
    const names = root.active_composable_names orelse return false;
    const label: ?[]const u8 = switch (arg.*) {
        .Labeled => |labeled| labeled.label.name,
        else => implicit_label,
    };
    var oracle = NameSetOracle{ .names = names };
    var w = Walker{
        .a = a,
        .b = .{ .a = a, .gen_span = exprSpanOf(arg) },
        .oracle = NameSetOracle.isComposableCall,
        .oracle_ctx = &oracle,
        .sinks = root.active_composable_sinks,
        .thread = true,
    };
    try w.transformComposableLambda(lam, expected_params, label);
    // Wrap by TYPE, not content: the callee's parameter is declared
    // `@Composable`, so kotlinc memoizes the lambda regardless of what its body
    // does. Wrapping by content instead passes a fresh instance on every parent
    // recompose, `rememberUpdatedState(content)` records a real state change,
    // and the subcomposition recomposes an extra frame.
    if (root.emit_lambda_memo and !callee_inline) {
        w.wrapInComposableLambdaLabeled(arg, label);
    }
    return true;
}

/// Composable callees whose lambda argument is itself a memoization or effect
/// calculation: wrapping it in `remember` would nest memoization or displace the
/// effect protocol's own keying.
pub fn plainMemoExcluded(name: []const u8) bool {
    const excluded = [_][]const u8{
        "remember",           "derivedStateOf",        "rememberSaveable",
        "rememberUpdatedState", "produceState",        "LaunchedEffect",
        "DisposableEffect",   "SideEffect",            "snapshotFlow",
        "rememberCoroutineScope", "movableContentOf",  "movableContentWithReceiverOf",
        "rememberComposableLambda", "composableLambda", "composableLambdaInstance",
        "key",
    };
    for (excluded) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Capture-fact walk for plain-lambda memoization. `refs` collects bare name
/// reads, call callees excluded; `declared` the names bound inside; `bad` flags
/// shapes memoization must skip: a write to a captured bare name, where a boxed
/// `var` cell key is meaningless, or a labeled return to the callee's implicit
/// label, which rewrapping would re-parent.
pub fn collectLambdaCaptureFacts(stmts: []const Stmt, refs: *std.StringHashMap(void), declared: *std.StringHashMap(void), bad: *bool, callee_name: []const u8) void {
    for (stmts) |*st| collectCaptureFactsStmt(st, refs, declared, bad, callee_name);
}

fn collectCaptureFactsStmt(st: *const Stmt, refs: *std.StringHashMap(void), declared: *std.StringHashMap(void), bad: *bool, callee: []const u8) void {
    switch (st.*) {
        .Expr => |*e| collectCaptureFactsExpr(e, refs, declared, bad, callee),
        .Assign => |*a| {
            if (a.target == .Path and a.target.Path.segments.len == 1) {
                if (!declared.contains(a.target.Path.segments[0].name)) {
                    bad.* = true;
                    return;
                }
            } else {
                collectCaptureFactsExpr(&a.target, refs, declared, bad, callee);
            }
            collectCaptureFactsExpr(&a.value, refs, declared, bad, callee);
        },
        .Decl => |*d| switch (d.*) {
            .Property => |pp| {
                if (pp.init) |*ini| collectCaptureFactsExpr(ini, refs, declared, bad, callee);
                declared.put(pp.name.name, {}) catch {};
            },
            .Function => |*f| {
                declared.put(f.name.name, {}) catch {};
                if (f.body) |fb| switch (fb) {
                    .Block => |blk| collectLambdaCaptureFacts(blk.stmts, refs, declared, bad, callee),
                    .Expr => |*e| collectCaptureFactsExpr(e, refs, declared, bad, callee),
                };
            },
            else => bad.* = true,
        },
        .DestructuringDecl => |*dd| {
            collectCaptureFactsExpr(&dd.init, refs, declared, bad, callee);
            for (dd.names) |nm| declared.put(nm.name, {}) catch {};
        },
    }
}

fn collectCaptureFactsExpr(e: *const Expr, refs: *std.StringHashMap(void), declared: *std.StringHashMap(void), bad: *bool, callee: []const u8) void {
    if (bad.*) return;
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1) refs.put(p.segments[0].name, {}) catch {};
        },
        .Call => |c| {
            // A simple-name callee is a function reference, not a value key.
            if (!(c.callee.* == .Path and c.callee.Path.segments.len == 1)) {
                collectCaptureFactsExpr(c.callee, refs, declared, bad, callee);
            }
            for (c.args) |*a| collectCaptureFactsExpr(a, refs, declared, bad, callee);
        },
        .Member => |m| collectCaptureFactsExpr(m.receiver, refs, declared, bad, callee),
        .Index => |ix| {
            collectCaptureFactsExpr(ix.receiver, refs, declared, bad, callee);
            for (ix.args) |*a| collectCaptureFactsExpr(a, refs, declared, bad, callee);
        },
        .Binary => |bn| {
            collectCaptureFactsExpr(bn.lhs, refs, declared, bad, callee);
            collectCaptureFactsExpr(bn.rhs, refs, declared, bad, callee);
        },
        .Unary => |u| collectCaptureFactsExpr(u.expr, refs, declared, bad, callee),
        .Postfix => |px| {
            // `x++` writes its operand.
            if (px.expr.* == .Path and px.expr.Path.segments.len == 1 and
                !declared.contains(px.expr.Path.segments[0].name))
            {
                bad.* = true;
                return;
            }
            collectCaptureFactsExpr(px.expr, refs, declared, bad, callee);
        },
        .If => |f| {
            collectCaptureFactsExpr(f.cond, refs, declared, bad, callee);
            collectCaptureFactsExpr(f.then_branch, refs, declared, bad, callee);
            if (f.else_branch) |eb| collectCaptureFactsExpr(eb, refs, declared, bad, callee);
        },
        .When => |wh| {
            if (wh.subject) |sub| collectCaptureFactsExpr(sub, refs, declared, bad, callee);
            for (wh.branches) |*br| collectCaptureFactsExpr(&br.body, refs, declared, bad, callee);
        },
        .Block => |blk| collectLambdaCaptureFacts(blk.stmts, refs, declared, bad, callee),
        .For => |fr| {
            collectCaptureFactsExpr(fr.iter, refs, declared, bad, callee);
            collectCaptureFactsExpr(fr.body, refs, declared, bad, callee);
        },
        .While => |wl| {
            collectCaptureFactsExpr(wl.cond, refs, declared, bad, callee);
            collectCaptureFactsExpr(wl.body, refs, declared, bad, callee);
        },
        .DoWhile => |dw| {
            if (dw.body) |bd| collectCaptureFactsExpr(bd, refs, declared, bad, callee);
            collectCaptureFactsExpr(dw.cond, refs, declared, bad, callee);
        },
        .Lambda => |lam| {
            for (lam.params) |pn| declared.put(pn.name, {}) catch {};
            collectLambdaCaptureFacts(lam.body.stmts, refs, declared, bad, callee);
        },
        .StringTemplate => |st2| for (st2.parts) |*part| switch (part.*) {
            .Interp => |ie| collectCaptureFactsExpr(ie, refs, declared, bad, callee),
            .ShortInterp => |idn| refs.put(idn.name, {}) catch {},
            else => {},
        },
        .Return => |r| {
            if (r.label) |lb| {
                if (std.mem.eql(u8, lb.name, callee)) {
                    bad.* = true;
                    return;
                }
            }
            if (r.value) |v| collectCaptureFactsExpr(v, refs, declared, bad, callee);
        },
        .IsCheck => |ic| collectCaptureFactsExpr(ic.expr, refs, declared, bad, callee),
        .As => |asx| collectCaptureFactsExpr(asx.expr, refs, declared, bad, callee),
        .Labeled => |l| collectCaptureFactsExpr(l.expr, refs, declared, bad, callee),
        .IntLit, .FloatLit, .BoolLit, .CharLit, .NullLit, .This => {},
        else => bad.* = true,
    }
}

/// The span of an expression, for the memoization key. Falls back to a zero span
/// when the node form carries none the pass knows about.
pub fn exprSpanOf(e: *const Expr) Span {
    return switch (e.*) {
        .Lambda => |l| l.span,
        .Call => |c| exprSpanOf(c.callee),
        .Path => |pp| if (pp.segments.len != 0) pp.segments[0].span else Span.init(span_mod.FileId.from(0), 0, 0),
        else => Span.init(span_mod.FileId.from(0), 0, 0),
    };
}

/// Whether `e` denotes `currentComposer`, as a bare path or a trailing member
/// segment of that name.
pub fn isCurrentComposer(e: *const Expr) bool {
    return switch (e.*) {
        .Path => |p| p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, "currentComposer"),
        else => false,
    };
}
