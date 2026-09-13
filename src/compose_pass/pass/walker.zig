//! Recursive in-place body transform: composer substitution, threaded call
//! sites, group brackets, and composable-lambda memoization.

const std = @import("std");
const ast = @import("ast");
const span_mod = @import("span");
const root = @import("../compose_pass.zig");

const Span = span_mod.Span;
const Ident = ast.Ident;
const Block = ast.Block;
const Decl = ast.Decl;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const TypeRef = ast.TypeRef;

const composer_param = root.composer_param;
const changed_param = root.changed_param;
const dirty_local = root.dirty_local;
const isComposable = root.isComposable;
const positionalKey = root.positionalKey;

const annotations = @import("annotations.zig");
const dbg_lambda = annotations.dbg_lambda;
const ambient_composer_path = annotations.ambient_composer_path;
const composable_lambda_instance_path = annotations.composable_lambda_instance_path;
const remember_composable_lambda_path = annotations.remember_composable_lambda_path;
const isRestartableComposable = annotations.isRestartableComposable;

const builder = @import("builder.zig");
const B = builder.B;

const collect = @import("collect.zig");
const ComposableOracle = collect.ComposableOracle;
const stateOfComposableArity = collect.stateOfComposableArity;
const isComposableFnType = collect.isComposableFnType;
const lambdaHasComposerParams = collect.lambdaHasComposerParams;
const calleeInlinesLambda = collect.calleeInlinesLambda;
const callPropagatesExpectedValue = collect.callPropagatesExpectedValue;

const epilogue = @import("epilogue.zig");
const EpilogueInjector = epilogue.EpilogueInjector;
const calleeSimpleName = epilogue.calleeSimpleName;
const trailingLambda = epilogue.trailingLambda;
const isComposerCallStmt = epilogue.isComposerCallStmt;

const lambda = @import("lambda.zig");
const plainMemoExcluded = lambda.plainMemoExcluded;
const collectLambdaCaptureFacts = lambda.collectLambdaCaptureFacts;
const exprSpanOf = lambda.exprSpanOf;
const isCurrentComposer = lambda.isCurrentComposer;

const transform = @import("transform.zig");
const transformComposableFunction = transform.transformComposableFunction;
const transformThreadedComposable = transform.transformThreadedComposable;
const dirtyChanged = transform.dirtyChanged;
const dirtyMask = transform.dirtyMask;

/// Replaces every `currentComposer` read with the threaded `$composer` and appends
/// `($composer, childChanged)` to every `@Composable` call, at any depth.
pub const Walker = struct {
    a: std.mem.Allocator,
    b: B,
    oracle: ComposableOracle,
    oracle_ctx: *anyopaque,
    sinks: ?*const std.StringHashMap(void) = null,
    /// Vals typed `MutableState<@Composable fn>`, keyed to the fn type's arity.
    composable_state_vals: ?*std.StringHashMap(u8) = null,
    /// `@Composable`-lambda-typed params of the enclosing fn; a bare call to one threads.
    lambda_params: ?*std.StringHashMap(void) = null,
    /// Wrap a returned composable lambda in composableLambdaInstance: factories only.
    wrap_ret_lambda: bool = false,
    /// LOCAL `@Composable` declarations in this walk; they must never join the oracle.
    locals: ?*std.StringHashMap(void) = null,
    /// Scoped vals holding composable lambdas. Their bare calls are VALUE invocations, so
    /// the pair passes positionally: `invoke(c, changed)` cannot bind named args.
    composable_vals: ?*std.StringHashMap(void) = null,
    /// Vals from `movableContentOf`. Their invokes keep the runtime-completed protocol, so
    /// the name feeds ONLY the branch scan, which still needs its groups and empty else.
    movable_vals: ?*std.StringHashMap(void) = null,
    /// Ambient mode: a `@Composable` property getter has no `$composer` param, so composer
    /// references resolve through the `__compose_currentComposer` intrinsic.
    ambient: bool = false,
    /// `@ExplicitGroupsComposable`: the function manages its own groups, so automatic
    /// per-branch replace-groups must NOT be inserted. Reset inside a nested lambda.
    explicit_groups: bool = false,
    /// Whether the current scope is composable. Only there are calls threaded and
    /// `currentComposer` substituted; other bodies still walk for sink arguments.
    thread: bool = true,
    /// The enclosing function returns a `@Composable` function type, so a lambda in return
    /// position is composable.
    ret_composable: bool = false,
    /// Declared param count of that return type; a headerless lambda keeps `it` at 1.
    ret_fn_params: u8 = 0,
    /// Enclosing composable-lambda scopes a `return@label` can target: a non-local return
    /// closes every group opened since that scope started, as `endToMarker($marker)`.
    nlr_scopes: ?*std.ArrayList(NlrScope) = null,
    nlr_counter: usize = 0,
    /// Value-param name to skip-calculus triple, present only when probes were emitted: a
    /// memoized lambda capturing only params derives validity from `$dirty`, no key slots.
    param_triples: ?*const std.StringHashMap(u5) = null,
    /// Whether `$dirty` carries live per-param facts here: false in a nested lambda.
    dirty_in_scope: bool = false,
    /// Locals shadowing a tripled param name, which the triple does not describe.
    shadowed_triples: ?*std.StringHashMap(void) = null,

    /// A `return@label` target: the labelled lambda, the local holding its start marker,
    /// and whether a non-local return referenced it.
    const NlrScope = struct {
        label: []const u8,
        marker_var: []const u8,
        needs: bool,
    };

    fn nlrScopes(w: *Walker) *std.ArrayList(NlrScope) {
        if (w.nlr_scopes) |s| return s;
        const s = w.a.create(std.ArrayList(NlrScope)) catch @panic("oom");
        s.* = .empty;
        w.nlr_scopes = s;
        return s;
    }

    /// The marker-local to close groups back to for a non-innermost target; null for a
    /// local return, which closes its own groups as it unwinds.
    fn nlrReturnMarker(w: *Walker, label: ?Ident) ?[]const u8 {
        const lbl = label orelse return null;
        const scopes = w.nlr_scopes orelse return null;
        var i: usize = scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, scopes.items[i].label, lbl.name)) {
                if (i + 1 >= scopes.items.len) return null; // innermost: local
                scopes.items[i].needs = true;
                return scopes.items[i].marker_var;
            }
        }
        return null;
    }

    /// The threaded `$composer` param, or the ambient intrinsic call in a getter.
    fn composerRef(w: *Walker) Expr {
        if (w.ambient)
            return w.b.call(w.b.pathExprSegs(&ambient_composer_path), w.a.alloc(Expr, 0) catch @panic("oom"));
        return w.b.pathExpr(composer_param);
    }

    pub fn walkBlock(w: *Walker, blk: *Block) std.mem.Allocator.Error!void {
        for (blk.stmts) |*s| try w.walkStmt(s);
    }

    pub fn walkStmt(w: *Walker, s: *Stmt) std.mem.Allocator.Error!void {
        switch (s.*) {
            // A statement-position conditional discards its value, so an expression-shaped branch
            // can be boxed into a Block and bracketed; expression position keeps the Block rule.
            .Expr => |*e| {
                try w.walkExpr(e);
                if (w.thread and !w.explicit_groups) w.wrapStatementConditional(e);
            },
            .Assign => |*asg| {
                try w.walkExpr(&asg.target);
                // `content.value = { … }` on a `MutableState<@Composable fn>` val: composable by the
                // state's declared type, so it wraps and a swapped content invalidates.
                if (asg.value == .Lambda and w.composable_state_vals != null and
                    asg.target == .Member and
                    std.mem.eql(u8, asg.target.Member.name.name, "value") and
                    asg.target.Member.receiver.* == .Path and
                    asg.target.Member.receiver.Path.segments.len == 1)
                {
                    if (w.composable_state_vals.?.get(asg.target.Member.receiver.Path.segments[0].name)) |arity| {
                        try w.walkComposableValueExpr(&asg.value, arity);
                        if (root.emit_lambda_memo and asg.value == .Lambda) {
                            w.wrapInComposableLambdaInstance(&asg.value);
                        }
                        return;
                    }
                }
                try w.walkExpr(&asg.value);
            },
            .DestructuringDecl => |*d| try w.walkExpr(&d.init),
            .Decl => |*d| try w.walkDecl(d),
        }
    }

    fn walkDecl(w: *Walker, d: *Decl) std.mem.Allocator.Error!void {
        switch (d.*) {
            .Property => |p| {
                // A local shadowing a tripled param retires that name from `$dirty` certainty.
                if (w.param_triples) |triples| {
                    if (triples.contains(p.name.name)) {
                        if (w.shadowed_triples == null) {
                            const set = w.a.create(std.StringHashMap(void)) catch @panic("oom");
                            set.* = std.StringHashMap(void).init(w.a);
                            w.shadowed_triples = set;
                        }
                        w.shadowed_triples.?.put(p.name.name, {}) catch @panic("oom");
                    }
                }
                // The declared type makes the initializer composable, or the literal is annotated.
                if (p.init) |*ini| {
                    if (p.ty != null and isComposableFnType(&p.ty.?)) {
                        try w.walkComposableValueExpr(
                            ini,
                            @intCast(@min(p.ty.?.function.?.params.len, 255)),
                        );
                        // In a plain scope the lambda has no ambient composer at creation, so it wraps in
                        // composableLambdaInstance(key, true, block) and each invocation gets a restart group.
                        if (root.emit_lambda_memo and !w.thread and ini.* == .Lambda) {
                            w.wrapInComposableLambdaInstance(ini);
                        }
                    } else if (p.ty != null and stateOfComposableArity(&p.ty.?) != null) {
                        // The state's type argument makes every stored lambda composable.
                        const arity = stateOfComposableArity(&p.ty.?).?;
                        if (w.composable_state_vals == null) {
                            const m = w.a.create(std.StringHashMap(u8)) catch @panic("oom");
                            m.* = std.StringHashMap(u8).init(w.a);
                            w.composable_state_vals = m;
                        }
                        w.composable_state_vals.?.put(p.name.name, arity) catch @panic("oom");
                        if (ini.* == .Call) {
                            for (ini.Call.args) |*arg| {
                                if (arg.* == .Lambda) {
                                    try w.walkComposableValueExpr(arg, arity);
                                    if (root.emit_lambda_memo and arg.* == .Lambda) {
                                        w.wrapInComposableLambdaInstance(arg);
                                    }
                                }
                            }
                        }
                        try w.walkExpr(ini);
                    } else if (ini.* == .Lambda and isComposable(ini.Lambda.annotations)) {
                        // No declared type: the literal's header is the arity, and a headerless literal is
                        // `() -> Unit`, since its parser-injected `it` never binds without an expected type.
                        const arity: u8 = if (ini.Lambda.implicit_it) 0 else @intCast(@min(ini.Lambda.params.len, 255));
                        try w.transformComposableLambda(&ini.Lambda, arity, null);
                    } else {
                        try w.walkExpr(ini);
                    }
                }
                if (p.delegate) |del| try w.walkExpr(del);
                // Such a val joins the scoped locals set, so a bare `content()` threads.
                const holds_composable = blk: {
                    if (p.ty != null and isComposableFnType(&p.ty.?)) break :blk true;
                    if (p.init) |*ini2| {
                        if (ini2.* == .Lambda and isComposable(ini2.Lambda.annotations)) break :blk true;
                    }
                    // `val current by rememberUpdatedState(content)` reads back a composable value.
                    if (p.delegate) |del| {
                        if (del.* == .Call) {
                            for (del.Call.args) |*da| {
                                if (da.* != .Path) continue;
                                const dsegs = da.Path.segments;
                                if (dsegs.len != 1) continue;
                                const dn = dsegs[0].name;
                                const known = (w.lambda_params != null and w.lambda_params.?.contains(dn)) or
                                    (w.composable_vals != null and w.composable_vals.?.contains(dn)) or
                                    (w.locals != null and w.locals.?.contains(dn));
                                if (known) break :blk true;
                            }
                        }
                    }
                    // An unclassified val's calls go unthreaded; runtime closure completion supplies the
                    // pair from the ambient composer if the protocol wants it.
                    break :blk false;
                };
                if (!holds_composable) {
                    if (p.init) |*ini3| {
                        if (ini3.* == .Call) {
                            if (calleeSimpleName(ini3.Call.callee)) |cn| {
                                if (std.mem.eql(u8, cn, "movableContentOf") or
                                    std.mem.eql(u8, cn, "movableContentWithReceiverOf"))
                                {
                                    if (w.movable_vals == null) {
                                        const set = w.a.create(std.StringHashMap(void)) catch @panic("oom");
                                        set.* = std.StringHashMap(void).init(w.a);
                                        w.movable_vals = set;
                                    }
                                    try w.movable_vals.?.put(p.name.name, {});
                                }
                            }
                        }
                    }
                }
                if (holds_composable) {
                    // `locals` feeds nested transforms and branch scans; `composable_vals` only the pair.
                    if (w.locals == null) {
                        const lset = w.a.create(std.StringHashMap(void)) catch @panic("oom");
                        lset.* = std.StringHashMap(void).init(w.a);
                        w.locals = lset;
                    }
                    try w.locals.?.put(p.name.name, {});
                    if (w.composable_vals == null) {
                        const set = w.a.create(std.StringHashMap(void)) catch @panic("oom");
                        set.* = std.StringHashMap(void).init(w.a);
                        w.composable_vals = set;
                    }
                    try w.composable_vals.?.put(p.name.name, {});
                }
            },
            .Function => |*f| {
                // A local `@Composable` declaration transforms like a top-level one, its name already
                // in the oracle through the body-deep collection.
                if (f.body != null and isComposable(f.annotations)) {
                    if (w.locals == null) {
                        const set = w.a.create(std.StringHashMap(void)) catch @panic("oom");
                        set.* = std.StringHashMap(void).init(w.a);
                        w.locals = set;
                    }
                    try w.locals.?.put(f.name.name, {});
                    if (isRestartableComposable(f)) {
                        f.* = try transformComposableFunction(w.a, f, w.oracle, w.oracle_ctx, w.sinks, false, w.locals, null);
                    } else {
                        f.* = try transformThreadedComposable(w.a, f, w.oracle, w.oracle_ctx, w.sinks, w.locals);
                    }
                    return;
                }
                const saved_ret = w.ret_composable;
                const saved_rfp = w.ret_fn_params;
                w.ret_composable = f.return_type != null and isComposableFnType(&f.return_type.?);
                w.wrap_ret_lambda = w.ret_composable and std.mem.startsWith(u8, f.name.name, "movableContent");
                w.ret_fn_params = if (w.ret_composable) @intCast(@min(f.return_type.?.function.?.params.len, 255)) else 0;
                defer {
                    w.ret_composable = saved_ret;
                    w.ret_fn_params = saved_rfp;
                }
                if (f.body) |*fb| switch (fb.*) {
                    .Block => |*blk| try w.walkBlock(blk),
                    .Expr => |*e| if (w.ret_composable and e.* == .Lambda) {
                        try w.transformComposableLambda(&e.Lambda, w.ret_fn_params, null);
                        if (root.emit_lambda_memo and w.wrap_ret_lambda) w.wrapInComposableLambdaInstance(e);
                    } else {
                        try w.walkExpr(e);
                    },
                };
            },
            else => {},
        }
    }

    /// Kotlin propagates an expected `@Composable` function type through value-producing
    /// control flow, so every lambda leaf gains the composer ABI even under `if`/`when`.
    pub fn walkComposableValueExpr(
        w: *Walker,
        e: *Expr,
        expected_params: u8,
    ) std.mem.Allocator.Error!void {
        switch (e.*) {
            .Lambda => |*lam| try w.transformComposableLambda(lam, expected_params, null),
            .If => |*f| {
                try w.walkExpr(f.cond);
                try w.walkComposableValueExpr(f.then_branch, expected_params);
                if (f.else_branch) |else_branch|
                    try w.walkComposableValueExpr(else_branch, expected_params);
            },
            .When => |*wh| {
                if (wh.subject) |subject| try w.walkExpr(subject);
                for (wh.branches) |*branch| {
                    for (branch.patterns) |*pattern| switch (pattern.kind) {
                        .Value => |*value| try w.walkExpr(value),
                        .InRange => |*value| try w.walkExpr(value),
                        else => {},
                    };
                    try w.walkComposableValueExpr(&branch.body, expected_params);
                }
            },
            .Try => |*tr| {
                try w.walkComposableValueBlock(&tr.body, expected_params);
                for (tr.catches) |*catch_clause|
                    try w.walkComposableValueBlock(&catch_clause.body, expected_params);
                if (tr.finally) |*finally_block| try w.walkBlock(finally_block);
            },
            .Block => |*block| try w.walkComposableValueBlock(block, expected_params),
            .Labeled => |*labeled| {
                if (labeled.expr.* == .Lambda) {
                    try w.transformComposableLambda(
                        &labeled.expr.Lambda,
                        expected_params,
                        labeled.label.name,
                    );
                } else {
                    try w.walkComposableValueExpr(labeled.expr, expected_params);
                }
            },
            .As => |*cast| try w.walkComposableValueExpr(cast.expr, expected_params),
            .Binary => |*binary| {
                if (binary.op == .Elvis) {
                    try w.walkComposableValueExpr(binary.lhs, expected_params);
                    try w.walkComposableValueExpr(binary.rhs, expected_params);
                } else {
                    try w.walkExpr(e);
                }
            },
            .Call => |*call| {
                if (calleeSimpleName(call.callee)) |name| {
                    if (callPropagatesExpectedValue(name) and call.args.len != 0) {
                        if (trailingLambda(&call.args[call.args.len - 1])) |calculation| {
                            try w.walkComposableValueBlock(&calculation.body, expected_params);
                        }
                    }
                }
                try w.walkExpr(e);
            },
            else => try w.walkExpr(e),
        }
    }

    fn walkComposableValueBlock(
        w: *Walker,
        block: *Block,
        expected_params: u8,
    ) std.mem.Allocator.Error!void {
        if (block.stmts.len == 0) return;
        for (block.stmts[0 .. block.stmts.len - 1]) |*stmt| try w.walkStmt(stmt);
        const last = &block.stmts[block.stmts.len - 1];
        switch (last.*) {
            .Expr => |*expr| try w.walkComposableValueExpr(expr, expected_params),
            else => try w.walkStmt(last),
        }
    }

    /// Replace a transformed lambda ARGUMENT with `rememberComposableLambda(<span key>,
    /// true, <lambda>, $composer, 0)`. Threaded scope only, since `$composer` must be live.
    fn wrapInComposableLambda(w: *Walker, arg: *Expr) void {
        w.wrapInComposableLambdaLabeled(arg, null);
    }

    /// Bracket a ComposableLambdaImpl-invoked body with the execute gate compiled into
    /// composable lambdas: `if ($composer.shouldExecute(true, $changed and 1)) { <body> }
    /// else { $composer.skipToGroupEnd() }`, the pause point PausableComposition needs.
    fn wrapLambdaBodyInPausePoint(w: *Walker, lam: anytype) void {
        if (!lambdaHasComposerParams(lam)) return;
        if (lam.body.stmts.len == 1 and lam.body.stmts[0] == .Expr and
            lam.body.stmts[0].Expr == .If)
        {
            const cond = lam.body.stmts[0].Expr.If.cond;
            if (cond.* == .Call and cond.Call.callee.* == .Member and
                std.mem.eql(u8, cond.Call.callee.Member.name.name, "shouldExecute")) return;
        }
        const se_args = w.a.alloc(Expr, 2) catch @panic("oom");
        se_args[0] = .{ .BoolLit = .{ .value = true, .span = w.b.gen_span } };
        se_args[1] = w.b.callMember(w.b.pathExpr(changed_param), "and", w.b.slice1(w.b.intLit(1)));
        const run_cond = w.b.callMember(w.b.pathExpr(composer_param), "shouldExecute", se_args);
        const skip_stmts = w.a.alloc(ast.Stmt, 1) catch @panic("oom");
        skip_stmts[0] = .{ .Expr = w.b.callMember(w.b.pathExpr(composer_param), "skipToGroupEnd", w.a.alloc(Expr, 0) catch @panic("oom")) };
        const sp = lam.body.span;
        const new_stmts = w.a.alloc(ast.Stmt, 1) catch @panic("oom");
        new_stmts[0] = .{ .Expr = .{ .If = .{
            .cond = w.b.box(run_cond),
            .then_branch = w.b.box(.{ .Block = .{ .stmts = lam.body.stmts, .span = sp } }),
            .else_branch = w.b.box(.{ .Block = .{ .stmts = skip_stmts, .span = w.b.gen_span } }),
            .span = w.b.gen_span,
        } } };
        lam.body = .{ .stmts = new_stmts, .span = sp };
    }

    pub fn wrapInComposableLambdaLabeled(w: *Walker, arg: *Expr, label: ?[]const u8) void {
        const key = positionalKey(exprSpanOf(arg));
        if (arg.* == .Lambda) w.wrapLambdaBodyInPausePoint(&arg.Lambda);
        // The memo remembers the impl in a slot of the current group; a child group here would
        // break `deactivateToEndGroup`.
        const args = w.a.alloc(Expr, 5) catch @panic("oom");
        args[0] = w.b.intLit(key);
        args[1] = .{ .BoolLit = .{ .value = true, .span = w.b.gen_span } };
        // Wrapping re-parents the lambda and strips its callee-derived implicit label, so a
        // `return@PWrap` would unwind past ComposableLambdaImpl.invoke; re-attach `lbl@`.
        if (label) |lb| {
            if (arg.* == .Lambda) {
                const inner = w.a.create(Expr) catch @panic("oom");
                inner.* = arg.*;
                args[2] = .{ .Labeled = .{
                    .label = w.b.ident(lb),
                    .expr = inner,
                    .span = w.b.gen_span,
                } };
            } else {
                args[2] = arg.*;
            }
        } else {
            args[2] = arg.*;
        }
        args[3] = w.composerRef();
        args[4] = w.b.intLit(0);
        arg.* = w.b.call(w.b.pathExprSegs(&remember_composable_lambda_path), args);
    }

    /// A composable lambda returned by a non-composable factory has no `$composer` in scope,
    /// so it wraps in `composableLambdaInstance(key, true, block)`, whose invoke restarts.
    pub fn wrapInComposableLambdaInstance(w: *Walker, arg: *Expr) void {
        const key = positionalKey(exprSpanOf(arg));
        if (arg.* == .Lambda) w.wrapLambdaBodyInPausePoint(&arg.Lambda);
        const args = w.a.alloc(Expr, 3) catch @panic("oom");
        args[0] = w.b.intLit(key);
        args[1] = .{ .BoolLit = .{ .value = true, .span = w.b.gen_span } };
        args[2] = arg.*;
        arg.* = w.b.call(w.b.pathExprSegs(&composable_lambda_instance_path), args);
    }

    /// Gates the per-branch replace groups: only conditional COMPOSITION is bracketed.
    pub fn branchHasComposable(w: *Walker, e: *const Expr) bool {
        switch (e.*) {
            .Call => |c| {
                if (calleeSimpleName(c.callee)) |nm| {
                    const is_lp = w.lambda_params != null and w.lambda_params.?.contains(nm);
                    const is_local = w.locals != null and w.locals.?.contains(nm);
                    const is_val = w.composable_vals != null and w.composable_vals.?.contains(nm);
                    const is_sink = w.sinks != null and w.sinks.?.contains(nm);
                    const is_movable = w.movable_vals != null and w.movable_vals.?.contains(nm);
                    if (is_lp or is_local or is_val or is_sink or is_movable or w.oracle(w.oracle_ctx, nm)) return true;
                }
                if (w.branchHasComposable(c.callee)) return true;
                for (c.args) |*a| if (w.branchHasComposable(a)) return true;
                return false;
            },
            .Block => |blk| {
                for (blk.stmts) |*st| switch (st.*) {
                    .Expr => |*se| if (w.branchHasComposable(se)) return true,
                    .Assign => |a| {
                        if (w.branchHasComposable(&a.value)) return true;
                    },
                    .Decl => |d| switch (d) {
                        .Property => |pp| {
                            if (pp.init) |*ini| if (w.branchHasComposable(ini)) return true;
                        },
                        else => {},
                    },
                    else => {},
                };
                return false;
            },
            .If => |ff| {
                if (w.branchHasComposable(ff.then_branch)) return true;
                if (ff.else_branch) |eb| if (w.branchHasComposable(eb)) return true;
                return false;
            },
            .Lambda => |lam| {
                for (lam.body.stmts) |*st| switch (st.*) {
                    .Expr => |*se| if (w.branchHasComposable(se)) return true,
                    .Assign => |as| if (w.branchHasComposable(&as.value)) return true,
                    .Decl => |d| switch (d) {
                        .Property => |pp| {
                            if (pp.init) |*ini| if (w.branchHasComposable(ini)) return true;
                        },
                        else => {},
                    },
                    else => {},
                };
                return false;
            },
            .Path => |p| {
                // A bare read of a `@Composable`-getter property composes, so the lambda is content.
                if (p.segments.len >= 1 and root.active_composable_getter_props != null and
                    root.active_composable_getter_props.?.contains(p.segments[p.segments.len - 1].name))
                    return true;
                return false;
            },
            .Member => |m| {
                if (root.active_composable_getter_props != null and
                    root.active_composable_getter_props.?.contains(m.name.name)) return true;
                return w.branchHasComposable(m.receiver);
            },
            // Composable calls under control flow still make the branch composable content, or a
            // re-run passes a fresh closure and `changed(content)` records a false change.
            .For => |fr| {
                if (w.branchHasComposable(fr.iter)) return true;
                return w.branchHasComposable(fr.body);
            },
            .While => |wl| {
                if (w.branchHasComposable(wl.cond)) return true;
                return w.branchHasComposable(wl.body);
            },
            .DoWhile => |dw| {
                if (dw.body) |bd| if (w.branchHasComposable(bd)) return true;
                return w.branchHasComposable(dw.cond);
            },
            .When => |wh| {
                if (wh.subject) |sub| if (w.branchHasComposable(sub)) return true;
                for (wh.branches) |*br| if (w.branchHasComposable(&br.body)) return true;
                return false;
            },
            .Try => |t| {
                var tb = Expr{ .Block = t.body };
                if (w.branchHasComposable(&tb)) return true;
                for (t.catches) |*ca| {
                    var cb = Expr{ .Block = ca.body };
                    if (w.branchHasComposable(&cb)) return true;
                }
                if (t.finally) |fin| {
                    var fb = Expr{ .Block = fin };
                    if (w.branchHasComposable(&fb)) return true;
                }
                return false;
            },
            .Labeled => |l| return w.branchHasComposable(l.expr),
            else => return false,
        }
    }

    /// Boxes expression-shaped branches into Blocks first, then brackets them.
    fn wrapStatementConditional(w: *Walker, e: *Expr) void {
        switch (e.*) {
            .If => |*f| {
                if (w.branchHasComposable(f.then_branch) or
                    (if (f.else_branch) |eb| w.branchHasComposable(eb) else false))
                {
                    w.wrapBranchBoxed(f.then_branch);
                    if (f.else_branch) |eb| {
                        if (eb.* == .If) {
                            w.wrapStatementConditional(eb);
                        } else {
                            w.wrapBranchBoxed(eb);
                        }
                    } else {
                        // A conditional whose false path emits no group leaves a positional hole, and
                        // replace-on-mismatch deletes the sibling that moved in, so it emits an empty group.
                        f.else_branch = w.emptyReplaceGroupBlock(f.span);
                    }
                }
            },
            .When => |*wh| {
                var any = false;
                var has_else = false;
                for (wh.branches) |*br| {
                    if (w.branchHasComposable(&br.body)) any = true;
                    for (br.patterns) |p| {
                        if (p.kind == .Else) has_else = true;
                    }
                }
                if (any) {
                    for (wh.branches) |*br| w.wrapBranchBoxed(&br.body);
                    if (!has_else) {
                        // Same positional hole as an else-less `if`: a when matching nothing still emits one.
                        const nb = w.a.alloc(ast.WhenBranch, wh.branches.len + 1) catch @panic("oom");
                        @memcpy(nb[0..wh.branches.len], wh.branches);
                        const pats = w.a.alloc(ast.WhenPattern, 1) catch @panic("oom");
                        pats[0] = .{ .kind = .Else, .span = wh.span };
                        nb[wh.branches.len] = .{
                            .patterns = pats,
                            .body = w.emptyReplaceGroupBlock(wh.span).*,
                            .span = wh.span,
                        };
                        wh.branches = nb;
                    }
                }
            },
            else => {},
        }
    }

    fn bodyIsSoleKeyCall(e: *const Expr) bool {
        switch (e.*) {
            .Call => |c| return c.callee.* == .Path and
                c.callee.Path.segments.len == 1 and
                std.mem.eql(u8, c.callee.Path.segments[0].name, "key"),
            .Block => |blk| {
                // Rewritten form: { startMovableGroup(…); …; endMovableGroup(); … }.
                if (blk.stmts.len != 0 and isComposerCallStmt(&blk.stmts[0], "startMovableGroup")) return true;
                if (blk.stmts.len != 1) return false;
                if (blk.stmts[0] != .Expr) return false;
                return bodyIsSoleKeyCall(&blk.stmts[0].Expr);
            },
            else => return false,
        }
    }

    /// Bracket a loop whose body composes: a per-iteration replaceable group under the same
    /// span key plus an outer group. A body that jumps out stays unbracketed.
    fn wrapLoopContent(w: *Walker, loop: *Expr, body: *Expr) void {
        if (!(w.thread and !w.explicit_groups)) return;
        if (!w.branchHasComposable(body)) return;
        if (loopBodyEscapes(body)) return;
        // A body that IS a `key(...)` call brings its own movable group, which must sit as a
        // direct sibling of the other iterations' so a reorder MOVES it.
        if (!bodyIsSoleKeyCall(body)) w.wrapBranchBoxed(body);
        const sp = exprSpanOf(loop);
        const key = positionalKey(sp);
        const start_args = w.a.alloc(Expr, 1) catch @panic("oom");
        start_args[0] = w.b.intLit(key);
        const stmts = w.a.alloc(ast.Stmt, 3) catch @panic("oom");
        stmts[0] = .{ .Expr = w.b.callMember(w.composerRef(), "startReplaceGroup", start_args) };
        stmts[1] = .{ .Expr = loop.* };
        stmts[2] = .{ .Expr = w.b.callMember(w.composerRef(), "endReplaceGroup", w.a.alloc(Expr, 0) catch @panic("oom")) };
        loop.* = .{ .Block = .{ .stmts = stmts, .span = sp } };
    }

    /// Scans at all depths, which is conservative: a missed bracket, never an imbalance.
    fn loopBodyEscapes(e: *const Expr) bool {
        switch (e.*) {
            .Break, .Continue, .Return => return true,
            .Block => |blk| {
                for (blk.stmts) |*st| switch (st.*) {
                    .Expr => |*se| if (loopBodyEscapes(se)) return true,
                    .Assign => |a| if (loopBodyEscapes(&a.value)) return true,
                    .Decl => |d| switch (d) {
                        .Property => |pp| {
                            if (pp.init) |*ini| if (loopBodyEscapes(ini)) return true;
                        },
                        else => {},
                    },
                    else => {},
                };
                return false;
            },
            .If => |ff| {
                if (loopBodyEscapes(ff.cond)) return true;
                if (loopBodyEscapes(ff.then_branch)) return true;
                if (ff.else_branch) |eb| if (loopBodyEscapes(eb)) return true;
                return false;
            },
            .When => |wh| {
                if (wh.subject) |sub| if (loopBodyEscapes(sub)) return true;
                for (wh.branches) |*br| if (loopBodyEscapes(&br.body)) return true;
                return false;
            },
            .For => |fr| {
                if (loopBodyEscapes(fr.iter)) return true;
                return loopBodyEscapes(fr.body);
            },
            .While => |wl| {
                if (loopBodyEscapes(wl.cond)) return true;
                return loopBodyEscapes(wl.body);
            },
            .DoWhile => |dw| {
                if (dw.body) |bd| if (loopBodyEscapes(bd)) return true;
                return loopBodyEscapes(dw.cond);
            },
            .Try => |t| {
                var tb = Expr{ .Block = t.body };
                if (loopBodyEscapes(&tb)) return true;
                for (t.catches) |*ca| {
                    var cb = Expr{ .Block = ca.body };
                    if (loopBodyEscapes(&cb)) return true;
                }
                if (t.finally) |fin| {
                    var fb = Expr{ .Block = fin };
                    if (loopBodyEscapes(&fb)) return true;
                }
                return false;
            },
            .Labeled => |l| return loopBodyEscapes(l.expr),
            .Call => |c| {
                for (c.args) |*arg| {
                    if (arg.* == .Lambda) continue;
                    if (loopBodyEscapes(arg)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Wrap a plain lambda argument in `remember(<capture keys...>, { <lambda> })`. Keys are
    /// the bare names the body reads and does not declare: an over-approximate key only
    /// compares equal, so the wrap bails when the body writes one, whose cell key is dead.
    fn memoizePlainLambdaArg(w: *Walker, arg: *Expr, callee_name: []const u8) void {
        if (arg.* != .Lambda) return;
        const lam = &arg.Lambda;
        var refs = std.StringHashMap(void).init(w.a);
        defer refs.deinit();
        var declared = std.StringHashMap(void).init(w.a);
        defer declared.deinit();
        var bad = false;
        collectLambdaCaptureFacts(lam.body.stmts, &refs, &declared, &bad, callee_name);
        if (bad) return;
        var keys: std.ArrayList(Expr) = .empty;
        var it = refs.keyIterator();
        while (it.next()) |k| {
            const nm = k.*;
            if (declared.contains(nm)) continue;
            if (std.mem.eql(u8, nm, "it") or std.mem.eql(u8, nm, "this")) continue;
            for (lam.params) |*p| {
                if (std.mem.eql(u8, p.name, nm)) break;
            } else {
                keys.append(w.a, w.b.pathExpr(nm)) catch @panic("oom");
            }
        }
        const calc_stmts = w.a.alloc(Stmt, 1) catch @panic("oom");
        calc_stmts[0] = .{ .Expr = arg.* };
        const calc = Expr{ .Lambda = .{
            .params = &.{},
            .param_tys = &.{},
            .body = .{ .stmts = calc_stmts, .span = lam.span },
            .implicit_it = false,
            .span = lam.span,
        } };
        // kotlinc's zero-key-slot shape: when `$dirty` already carries every capture's change
        // state, the memo is `$composer.cache(<any capture changed>, calc)`.
        const memo_trace = root.memo_trace_enabled;
        if (memo_trace) {
            std.debug.print("[memo] callee={s} dirty_in_scope={} triples={} keys:", .{ callee_name, w.dirty_in_scope, w.param_triples != null });
            for (keys.items) |k| std.debug.print(" {s}", .{k.Path.segments[0].name});
            std.debug.print("\n", .{});
        }
        // A fully closed `{}` lifts to a top-level singleton val. Only an empty body qualifies,
        // since a body with calls resolves bare names through the creation-time receiver chain.
        if (keys.items.len == 0 and lam.body.stmts.len == 0 and root.pending_memo_lifts != null) {
            const key: u64 = @bitCast(@as(i64, positionalKey(lam.span)));
            const nm = std.fmt.allocPrint(w.a, "$klio$memo${x}", .{key}) catch @panic("oom");
            const prop = w.a.create(ast.Property) catch @panic("oom");
            prop.* = .{
                .mutable = false,
                .name = w.b.ident(nm),
                .receiver_type = null,
                .ty = null,
                .init = arg.*,
                .delegate = null,
                .getter = null,
                .setter = null,
                .is_abstract = false,
                .is_open = false,
                .is_override = false,
                .is_lateinit = false,
                .is_const = false,
                .is_inline = false,
                .is_expect = false,
                .is_actual = false,
                .setter_visibility = null,
                .visibility = .Private,
                .annotations = &.{},
                .span = w.b.gen_span,
            };
            root.pending_memo_lifts.?.append(root.pending_lift_alloc.?, .{ .Property = prop }) catch @panic("oom");
            arg.* = w.b.pathExpr(nm);
            if (memo_trace) std.debug.print("[memo] -> lifted singleton {s}\n", .{nm});
            return;
        }
        // A zero-capture memo never invalidates: `cache(false, calc)` needs no `$dirty`.
        if (keys.items.len == 0) {
            const cache_args = w.a.alloc(Expr, 2) catch @panic("oom");
            cache_args[0] = .{ .BoolLit = .{ .value = false, .span = w.b.gen_span } };
            cache_args[1] = calc;
            arg.* = w.b.callMember(w.composerRef(), "cache", cache_args);
            if (memo_trace) std.debug.print("[memo] -> cache (0 keys)\n", .{});
            return;
        }
        if (w.dirty_in_scope and w.param_triples != null) from_dirty: {
            const triples = w.param_triples.?;
            var invalid: ?Expr = null;
            for (keys.items) |k| {
                const nm = k.Path.segments[0].name;
                if (w.shadowed_triples != null and w.shadowed_triples.?.contains(nm)) {
                    if (memo_trace) std.debug.print("[memo] -> remember (shadowed key {s})\n", .{nm});
                    break :from_dirty;
                }
                const triple = triples.get(nm) orelse {
                    if (memo_trace) std.debug.print("[memo] -> remember (non-param key {s})\n", .{nm});
                    break :from_dirty;
                };
                const term = Expr{ .Binary = .{
                    .op = .Eq,
                    .lhs = w.b.box(w.b.callMember(w.b.pathExpr(dirty_local), "and", w.b.slice1(w.b.intLit(dirtyMask(triple))))),
                    .rhs = w.b.box(w.b.intLit(dirtyChanged(triple))),
                    .span = w.b.gen_span,
                } };
                invalid = if (invalid) |acc| Expr{ .Binary = .{
                    .op = .Or,
                    .lhs = w.b.box(acc),
                    .rhs = w.b.box(term),
                    .span = w.b.gen_span,
                } } else term;
            }
            const cache_args = w.a.alloc(Expr, 2) catch @panic("oom");
            cache_args[0] = invalid orelse .{ .BoolLit = .{ .value = false, .span = w.b.gen_span } };
            cache_args[1] = calc;
            arg.* = w.b.callMember(w.composerRef(), "cache", cache_args);
            if (memo_trace) std.debug.print("[memo] -> cache ({d} keys)\n", .{keys.items.len});
            return;
        }
        if (memo_trace) std.debug.print("[memo] -> remember (dirty_in_scope={})\n", .{w.dirty_in_scope});
        const rem_args = w.a.alloc(Expr, keys.items.len + 3) catch @panic("oom");
        @memcpy(rem_args[0..keys.items.len], keys.items);
        rem_args[keys.items.len] = calc;
        // Threaded with the pair so the call names the `remember` overload whose arity matches.
        rem_args[keys.items.len + 1] = w.composerRef();
        rem_args[keys.items.len + 2] = w.b.intLit(0);
        arg.* = w.b.call(w.b.pathExprSegs(&.{ "androidx", "compose", "runtime", "remember" }), rem_args);
    }

    /// `{ startReplaceGroup(<span key>); endReplaceGroup() }`, the group an untaken path
    /// still occupies.
    fn emptyReplaceGroupBlock(w: *Walker, sp: Span) *Expr {
        const start_args = w.a.alloc(Expr, 1) catch @panic("oom");
        start_args[0] = w.b.intLit(positionalKey(sp));
        const stmts = w.a.alloc(ast.Stmt, 2) catch @panic("oom");
        stmts[0] = .{ .Expr = w.b.callMember(w.composerRef(), "startReplaceGroup", start_args) };
        stmts[1] = .{ .Expr = w.b.callMember(w.composerRef(), "endReplaceGroup", w.a.alloc(Expr, 0) catch @panic("oom")) };
        const e = w.a.create(Expr) catch @panic("oom");
        e.* = .{ .Block = .{ .stmts = stmts, .span = sp } };
        return e;
    }

    fn wrapBranchBoxed(w: *Walker, branch: *Expr) void {
        if (branch.* == .Block) {
            if (branch.Block.stmts.len != 0 and
                isComposerCallStmt(&branch.Block.stmts[0], "startReplaceGroup")) return;
            w.wrapBranchInReplaceGroup(branch);
            return;
        }
        const sp = exprSpanOf(branch);
        const stmts = w.a.alloc(ast.Stmt, 1) catch @panic("oom");
        stmts[0] = .{ .Expr = branch.* };
        branch.* = .{ .Block = .{ .stmts = stmts, .span = sp } };
        w.wrapBranchInReplaceGroup(branch);
    }

    /// Rewrite a threaded `key(k…, block, …)` call into
    ///     { $composer.startMovableGroup(<site key>, <joined keys>)
    ///       val $key$v = key(…)
    ///       $composer.endMovableGroup()
    ///       $key$v }
    /// `dyn_n` counts the dynamic key arguments; multiple keys join through `joinKey`.
    fn wrapKeyCall(w: *Walker, e: *Expr, dyn_n: usize) void {
        const call_expr = e.*;
        const sp = exprSpanOf(&call_expr);
        var joined = call_expr.Call.args[0];
        for (call_expr.Call.args[1..dyn_n]) |k| {
            const jargs = w.a.alloc(Expr, 2) catch @panic("oom");
            jargs[0] = joined;
            jargs[1] = k;
            joined = w.b.callMember(w.composerRef(), "joinKey", jargs);
        }
        const start_args = w.a.alloc(Expr, 2) catch @panic("oom");
        start_args[0] = w.b.intLit(positionalKey(sp));
        start_args[1] = joined;
        const result_prop = w.a.create(ast.Property) catch @panic("oom");
        result_prop.* = .{
            .mutable = false,
            .name = w.b.ident("$key$v"),
            .receiver_type = null,
            .ty = null,
            .init = call_expr,
            .delegate = null,
            .getter = null,
            .setter = null,
            .is_abstract = false,
            .is_open = false,
            .is_override = false,
            .is_lateinit = false,
            .is_const = false,
            .is_inline = false,
            .is_expect = false,
            .is_actual = false,
            .setter_visibility = null,
            .visibility = .Public,
            .annotations = &.{},
            .span = w.b.gen_span,
        };
        const stmts = w.a.alloc(ast.Stmt, 4) catch @panic("oom");
        stmts[0] = .{ .Expr = w.b.callMember(w.composerRef(), "startMovableGroup", start_args) };
        stmts[1] = .{ .Decl = .{ .Property = result_prop } };
        stmts[2] = .{ .Expr = w.b.callMember(w.composerRef(), "endMovableGroup", w.a.alloc(Expr, 0) catch @panic("oom")) };
        stmts[3] = .{ .Expr = w.b.pathExpr("$key$v") };
        e.* = .{ .Block = .{ .stmts = stmts, .span = sp } };
    }

    /// Bracket a Block branch with `startReplaceGroup(<span key>)`/`endReplaceGroup()`.
    fn wrapBranchInReplaceGroup(w: *Walker, branch: *Expr) void {
        if (branch.* != .Block) return;
        const blk = &branch.Block;
        if (blk.stmts.len != 0 and
            isComposerCallStmt(&blk.stmts[0], "startReplaceGroup")) return;
        const key = positionalKey(blk.span);
        if (root.dbg_groups) std.debug.print("[compose-pass] replace-group key={d} stmts={d}\n", .{ key, blk.stmts.len });
        const start_args = w.a.alloc(Expr, 1) catch @panic("oom");
        start_args[0] = w.b.intLit(key);
        const preserve_tail = blk.stmts.len != 0 and blk.stmts[blk.stmts.len - 1] == .Expr and
            blk.stmts[blk.stmts.len - 1].Expr != .Return and
            blk.stmts[blk.stmts.len - 1].Expr != .Throw;
        const stmts = w.a.alloc(
            ast.Stmt,
            blk.stmts.len + if (preserve_tail) @as(usize, 3) else 2,
        ) catch @panic("oom");
        stmts[0] = .{ .Expr = w.b.callMember(w.composerRef(), "startReplaceGroup", start_args) };
        if (preserve_tail) {
            const tail_index = blk.stmts.len - 1;
            @memcpy(stmts[1 .. tail_index + 1], blk.stmts[0..tail_index]);
            const result_name = std.fmt.allocPrint(
                w.a,
                "$branch$v{x}",
                .{@as(u64, @bitCast(key))},
            ) catch @panic("oom");
            const result_prop = w.a.create(ast.Property) catch @panic("oom");
            result_prop.* = .{
                .mutable = false,
                .name = w.b.ident(result_name),
                .receiver_type = null,
                .ty = null,
                .init = blk.stmts[tail_index].Expr,
                .delegate = null,
                .getter = null,
                .setter = null,
                .is_abstract = false,
                .is_open = false,
                .is_override = false,
                .is_lateinit = false,
                .is_const = false,
                .is_inline = false,
                .is_expect = false,
                .is_actual = false,
                .setter_visibility = null,
                .visibility = .Public,
                .annotations = &.{},
                .span = w.b.gen_span,
            };
            stmts[tail_index + 1] = .{ .Decl = .{ .Property = result_prop } };
            stmts[tail_index + 2] = .{ .Expr = w.b.callMember(
                w.composerRef(),
                "endReplaceGroup",
                w.a.alloc(Expr, 0) catch @panic("oom"),
            ) };
            stmts[tail_index + 3] = .{ .Expr = w.b.pathExpr(result_name) };
        } else {
            @memcpy(stmts[1 .. blk.stmts.len + 1], blk.stmts);
            stmts[blk.stmts.len + 1] = .{ .Expr = w.b.callMember(
                w.composerRef(),
                "endReplaceGroup",
                w.a.alloc(Expr, 0) catch @panic("oom"),
            ) };
        }
        blk.stmts = stmts;
    }

    pub fn walkExpr(w: *Walker, e: *Expr) std.mem.Allocator.Error!void {
        // `currentComposer` IS the threaded composer inside a composable body.
        if (w.thread and isCurrentComposer(e)) {
            e.* = w.composerRef();
            return;
        }
        switch (e.*) {
            .Call => |*c| {
                try w.walkExpr(c.callee);
                const name = calleeSimpleName(c.callee);
                // Dynamic key count: every argument before the trailing content lambda.
                const key_dyn_n: usize = if (c.args.len >= 2) c.args.len - 1 else 0;
                const is_key_call = w.thread and name != null and
                    std.mem.eql(u8, name.?, "key") and key_dyn_n >= 1 and
                    c.args[c.args.len - 1] == .Lambda and w.oracle(w.oracle_ctx, "key");
                // A trailing lambda bound to a `@Composable`-typed parameter becomes
                // `{ …, $composer, $changed -> … }` here, so its body threads once against its own
                // `$composer`. A sink whose name is ITSELF composable applies in threaded scope only.
                const sink_applies = name != null and w.sinks != null and w.sinks.?.contains(name.?) and
                    (w.thread or !w.oracle(w.oracle_ctx, name.?));
                // A call through a composable-lambda VALUE is composable too. Threaded scope only.
                const val_sink = name != null and w.thread and
                    ((w.composable_vals != null and w.composable_vals.?.contains(name.?)) or
                        (w.locals != null and w.locals.?.contains(name.?)) or
                        (w.lambda_params != null and w.lambda_params.?.contains(name.?)));
                // An explicit label arrives as a `Labeled` node; unwrapping threads both forms alike.
                const sink_last = c.args.len != 0 and
                    trailingLambda(&c.args[c.args.len - 1]) != null and (sink_applies or val_sink);
                for (c.args, 0..) |*arg, i| {
                    if (sink_last and i == c.args.len - 1) {
                        const sink_lam = trailingLambda(arg).?;
                        const sink_label: ?[]const u8 = switch (arg.*) {
                            .Labeled => |lb| lb.label.name,
                            else => name,
                        };
                        // A headerless sink lambda is shaped with the bare composer pair, its slot count
                        // left to the lowering's repair against the resolved parameter's declared arity.
                        const exp: ?u8 = null;
                        const is_mco = std.mem.eql(u8, name.?, "movableContentOf");
                        const is_mcwro = std.mem.eql(u8, name.?, "movableContentWithReceiverOf");
                        // A movable-content type arg that is a `@Composable` function type makes that lambda
                        // param a composable value, so its name joins the lambda-param set for the body walk.
                        var added_names: [8]?[]const u8 = @splat(null);
                        var added_n: usize = 0;
                        if ((is_mco or is_mcwro) and w.lambda_params != null and !sink_lam.implicit_it) {
                            const ta_off: usize = if (is_mcwro) 1 else 0;
                            for (sink_lam.params, 0..) |*lp2, pi| {
                                const ti = pi + ta_off;
                                if (ti >= c.type_args.len) break;
                                const tref = &c.type_args[ti];
                                if (tref.function != null and isComposable(tref.annotations) and
                                    !w.lambda_params.?.contains(lp2.name) and added_n < added_names.len)
                                {
                                    w.lambda_params.?.put(lp2.name, {}) catch @panic("oom");
                                    added_names[added_n] = lp2.name;
                                    added_n += 1;
                                }
                            }
                        }
                        defer for (added_names[0..added_n]) |an| {
                            if (an) |nme| _ = w.lambda_params.?.remove(nme);
                        };
                        try w.transformComposableLambda(sink_lam, exp, sink_label);
                        // Wrap only content that actually composes: the name-keyed sink also catches sibling
                        // overloads' plain lambdas. An inline composable's stays raw, since wrapping re-parents
                        // it and a `return@InlineWrapper` would then unwind past invoke.
                        if (!w.thread and root.emit_lambda_memo and (is_mco or is_mcwro)) {
                            w.wrapInComposableLambdaInstance(arg);
                        }
                        // Wrap by TYPE, not content: the sink's parameter is declared `@Composable`, so
                        // kotlinc memoizes regardless of the body.
                        if (w.thread and root.emit_lambda_memo and
                            !calleeInlinesLambda(name.?))
                        {
                            w.wrapInComposableLambdaLabeled(arg, name.?);
                            // The wrapped argument is no longer a lambda, so it binds by the last parameter's name.
                        }
                    } else if (arg.* == .Lambda and w.thread and name != null and
                        calleeInlinesLambda(name.?))
                    {
                        // An inline callee's lambda body composes inline in the enclosing composable.
                        if (!lambdaHasComposerParams(&arg.Lambda)) {
                            // An inline lambda's params shadow same-named tripled fn params.
                            if (w.param_triples) |triples| {
                                for (arg.Lambda.params) |lp2| {
                                    if (!triples.contains(lp2.name)) continue;
                                    if (w.shadowed_triples == null) {
                                        const set = w.a.create(std.StringHashMap(void)) catch @panic("oom");
                                        set.* = std.StringHashMap(void).init(w.a);
                                        w.shadowed_triples = set;
                                    }
                                    w.shadowed_triples.?.put(lp2.name, {}) catch @panic("oom");
                                }
                            }
                            try w.walkBlock(&arg.Lambda.body);
                        }
                    } else if (arg.* == .Lambda and w.thread and name != null and
                        !calleeInlinesLambda(name.?))
                    {
                        // A plain callback lambda at a non-inline callee is not a composable scope, and
                        // threading it emits composer traffic that runs after composition.
                        const saved = w.thread;
                        w.thread = false;
                        try w.walkExpr(arg);
                        w.thread = saved;
                        // Strong-skipping memoization: `remember(captures...) { lambda }` passes the SAME
                        // instance. Skipped when the body returns to the callee's implicit label.
                        if (root.emit_lambda_memo and w.oracle(w.oracle_ctx, name.?) and
                            w.sinks != null and !w.sinks.?.contains(name.?) and
                            !plainMemoExcluded(name.?))
                        {
                            w.memoizePlainLambdaArg(arg, name.?);
                        }
                    } else {
                        try w.walkExpr(arg);
                    }
                }
                if (w.thread) {
                    if (name) |nm| {
                        const is_lambda_param = w.lambda_params != null and w.lambda_params.?.contains(nm);
                        const is_local_composable = w.locals != null and w.locals.?.contains(nm);
                        const is_composable_val = w.composable_vals != null and w.composable_vals.?.contains(nm);
                        // An explicit-receiver invoke of a `@Composable`-typed property is completed by the
                        // runtime from the ambient composer.
                        const is_composable_prop = false;
                        // VALUE invocations take the pair positionally, but only under the memo emission, since
                        // a wrapped ComposableLambdaImpl cannot bind the named pair.
                        const positional = root.emit_lambda_memo and (is_lambda_param or is_composable_prop or is_composable_val or is_local_composable);
                        // Other call forms keep their source argument shape: IR resolution selects the exact
                        // declaration first, and lowering completes the ABI against that, never a simple name.
                        const oracle_hit = false;
                        if (positional or is_composable_val or is_local_composable or oracle_hit) try w.threadCall(c, positional);
                    }
                }
                // `key(k…) { content }` is an intrinsic bracketed with a movable group whose data key
                // joins the dynamic keys; the upstream body is just `block()`.
                if (is_key_call) w.wrapKeyCall(e, key_dyn_n);
            },
            .Member => |*m| try w.walkExpr(m.receiver),
            .Index => |*ix| {
                try w.walkExpr(ix.receiver);
                for (ix.args) |*arg| try w.walkExpr(arg);
            },
            .Binary => |*bn| {
                try w.walkExpr(bn.lhs);
                try w.walkExpr(bn.rhs);
            },
            .Unary => |*u| try w.walkExpr(u.expr),
            .Postfix => |*p| try w.walkExpr(p.expr),
            .If => |*f| {
                try w.walkExpr(f.cond);
                try w.walkExpr(f.then_branch);
                if (f.else_branch) |eb| try w.walkExpr(eb);
                // Conditional content gets a replaceable group per branch under distinct span keys, or
                // a flip cannot replace its content atomically. Block-shaped branches only.
                if (w.thread and !w.explicit_groups and (w.branchHasComposable(f.then_branch) or
                    (if (f.else_branch) |eb2| w.branchHasComposable(eb2) else false)))
                {
                    // A composable `if` with no `else` still needs a group in the not-taken branch, or a
                    // flip shifts every following sibling and `startReplaceGroup` deletes the one moved in.
                    if (f.else_branch == null) {
                        // Keyed off the `if`'s own span, distinct from the then group's branch span.
                        const eb = w.a.create(Expr) catch @panic("oom");
                        const empty = w.a.alloc(ast.Stmt, 0) catch @panic("oom");
                        eb.* = .{ .Block = .{ .stmts = empty, .span = f.span } };
                        f.else_branch = eb;
                    }
                    w.wrapBranchInReplaceGroup(f.then_branch);
                    if (f.else_branch) |eb| w.wrapBranchInReplaceGroup(eb);
                }
            },
            .While => |*wl| {
                try w.walkExpr(wl.cond);
                try w.walkExpr(wl.body);
                w.wrapLoopContent(e, wl.body);
            },
            .DoWhile => |*dw| {
                if (dw.body) |bd| try w.walkExpr(bd);
                try w.walkExpr(dw.cond);
                if (dw.body) |bd| w.wrapLoopContent(e, bd);
            },
            .For => |*fr| {
                try w.walkExpr(fr.iter);
                try w.walkExpr(fr.body);
                w.wrapLoopContent(e, fr.body);
            },
            .Return => |*r| {
                if (r.value) |v| {
                    if (w.ret_composable and v.* == .Lambda) {
                        try w.transformComposableLambda(&v.Lambda, w.ret_fn_params, null);
                        if (root.emit_lambda_memo and w.wrap_ret_lambda) w.wrapInComposableLambdaInstance(v);
                    } else {
                        try w.walkExpr(v);
                    }
                }
                // A non-local `return@label` closes groups opened after the target scope started with
                // `endToMarker($marker)`. The value composes inside them, so it goes to a temp first:
                // `{ val $nlr$v = <value>; endToMarker(m); return $nlr$v }`.
                if (w.thread) if (w.nlrReturnMarker(r.label)) |marker_var| {
                    if (r.value) |rv| {
                        const tmp_name = try std.fmt.allocPrint(w.a, "$nlr$v{x}", .{@intFromPtr(e)});
                        const tmp_prop = try w.a.create(ast.Property);
                        tmp_prop.* = .{
                            .mutable = false,
                            .name = w.b.ident(tmp_name),
                            .receiver_type = null,
                            .ty = null,
                            .init = rv.*,
                            .delegate = null,
                            .getter = null,
                            .setter = null,
                            .is_abstract = false,
                            .is_open = false,
                            .is_override = false,
                            .is_lateinit = false,
                            .is_const = false,
                            .is_inline = false,
                            .is_expect = false,
                            .is_actual = false,
                            .setter_visibility = null,
                            .visibility = .Public,
                            .annotations = &.{},
                            .span = w.b.gen_span,
                        };
                        var ret_copy = e.Return;
                        const new_val = try w.a.create(Expr);
                        new_val.* = w.b.pathExpr(tmp_name);
                        ret_copy.value = new_val;
                        const stmts = try w.a.alloc(Stmt, 3);
                        stmts[0] = .{ .Decl = .{ .Property = tmp_prop } };
                        stmts[1] = .{ .Expr = w.b.callMember(
                            w.composerRef(),
                            "endToMarker",
                            w.b.slice1(w.b.pathExpr(marker_var)),
                        ) };
                        stmts[2] = .{ .Expr = .{ .Return = ret_copy } };
                        e.* = .{ .Block = .{ .stmts = stmts, .span = w.b.gen_span } };
                    } else {
                        const ret_copy = try w.a.create(Expr);
                        ret_copy.* = e.*;
                        const stmts = try w.a.alloc(Stmt, 2);
                        stmts[0] = .{ .Expr = w.b.callMember(
                            w.composerRef(),
                            "endToMarker",
                            w.b.slice1(w.b.pathExpr(marker_var)),
                        ) };
                        stmts[1] = .{ .Expr = ret_copy.* };
                        e.* = .{ .Block = .{ .stmts = stmts, .span = w.b.gen_span } };
                    }
                };
            },
            .Throw => |*t| try w.walkExpr(t.value),
            .Labeled => |*l| try w.walkExpr(l.expr),
            .Block => |*blk| try w.walkBlock(blk),
            .Try => |*t| {
                try w.walkBlock(&t.body);
                for (t.catches) |*ca| try w.walkBlock(&ca.body);
                if (t.finally) |*fin| try w.walkBlock(fin);
            },
            .When => |*wh| {
                if (wh.subject) |sub| try w.walkExpr(sub);
                var any_composable = false;
                for (wh.branches) |*br| {
                    for (br.patterns) |*pat| switch (pat.kind) {
                        .Value => |*ve| try w.walkExpr(ve),
                        .InRange => |*ve| try w.walkExpr(ve),
                        else => {},
                    };
                    try w.walkExpr(&br.body);
                    if (w.branchHasComposable(&br.body)) any_composable = true;
                }
                // `when` branches take the same per-branch replaceable group as `if` branches.
                if (w.thread and !w.explicit_groups and any_composable) {
                    for (wh.branches) |*br| w.wrapBranchInReplaceGroup(&br.body);
                }
            },
            .IsCheck => |*ic| try w.walkExpr(ic.expr),
            .As => |*as| try w.walkExpr(as.expr),
            .StringTemplate => |*st| for (st.parts) |*part| switch (part.*) {
                .Interp => |ie| try w.walkExpr(ie),
                else => {},
            },
            .Lambda => |*lam| {
                // The lambda body was already walked against its own composer, and a shared node must
                // not thread twice. A plain value-position lambda is not composable content.
                if (!lambdaHasComposerParams(lam)) {
                    const saved = w.thread;
                    w.thread = false;
                    try w.walkBlock(&lam.body);
                    w.thread = saved;
                }
            },
            .AnonFun => |*af| if (af.body) |ab| switch (ab.*) {
                .Block => |*blk| try w.walkBlock(blk),
                .Expr => |*ex| try w.walkExpr(ex),
            },
            else => {},
        }
    }

    /// Rewrite a `@Composable` lambda to `{ …orig, $composer, $changed -> … }`:
    /// `@Composable (P…) -> R` lowers to `FunctionN<P…, Composer, Int, R>`.
    pub fn transformComposableLambda(w: *Walker, lam: anytype, expected_params: ?u8, label: ?[]const u8) std.mem.Allocator.Error!void {
        if (dbg_lambda) std.debug.print("[compose-pass] transform composable lambda ({d} params)\n", .{lam.params.len});
        // Idempotence: a lambda already carrying the trailing pair is left alone.
        if (lambdaHasComposerParams(lam)) return;
        // A lambda with only the synthetic `it` has no real parameters, so the pair REPLACES
        // `it`; otherwise the pair follows the declared params.
        const keep_it = lam.implicit_it and (expected_params orelse 0) >= 1;
        const n: usize = if (lam.implicit_it) (if (keep_it) 1 else 0) else lam.params.len;
        const new_params = try w.a.alloc(Ident, n + 2);
        if (keep_it) {
            new_params[0] = w.b.ident("it");
        } else if (n != 0) @memcpy(new_params[0..n], lam.params[0..n]);
        new_params[n] = w.b.ident(composer_param);
        new_params[n + 1] = w.b.ident(changed_param);
        const new_tys = try w.a.alloc(?TypeRef, n + 2);
        for (new_tys, 0..) |*t, i| t.* = if (i < n and i < lam.param_tys.len) lam.param_tys[i] else null;
        // The pair is declared, not inferred: group calls and `$changed` masks bind statically
        // only when the lambda records the declared types.
        new_tys[n] = w.b.typeRef("Composer");
        new_tys[n + 1] = w.b.typeRef("Int");
        lam.params = new_params;
        lam.param_tys = new_tys;
        lam.implicit_it = false;
        // The lambda body IS composable and is its own scope, so it threads and brackets.
        const saved = w.thread;
        const saved_eg = w.explicit_groups;
        const saved_dirty = w.dirty_in_scope;
        w.thread = true;
        w.explicit_groups = false;
        // A composable lambda recomposes without the enclosing frame's `$dirty`.
        w.dirty_in_scope = false;
        // Register a `return@label` target; the marker capture is prepended only on demand.
        var marker_var: ?[]const u8 = null;
        if (label) |lb| {
            const scopes = w.nlrScopes();
            w.nlr_counter += 1;
            marker_var = std.fmt.allocPrint(w.a, "$klio_nlr_marker_{d}", .{w.nlr_counter}) catch @panic("oom");
            try scopes.append(w.a, .{ .label = lb, .marker_var = marker_var.?, .needs = false });
        }
        try w.walkBlock(&lam.body);
        if (label != null) {
            const scopes = w.nlr_scopes.?;
            const sc = scopes.pop().?;
            if (sc.needs) prependMarkerCapture(w, lam, marker_var.?);
        }
        w.thread = saved;
        w.explicit_groups = saved_eg;
        w.dirty_in_scope = saved_dirty;
        // A labeled early return closes the replace-groups it exits. The content lambda's
        // restart group belongs to ComposableLambdaImpl, so only replace-groups close here.
        {
            var inj = EpilogueInjector{ .a = w.a, .b = w.b, .fn_name = label orelse "", .value_params = &.{}, .has_restart = false };
            try inj.stmts(lam.body.stmts);
        }
    }

    /// Prepend `val <marker_var> = <composer>.currentMarker` so a nested non-local return
    /// can pass the captured marker to `endToMarker`.
    fn prependMarkerCapture(w: *Walker, lam: anytype, marker_var: []const u8) void {
        const prop = w.a.create(ast.Property) catch @panic("oom");
        prop.* = .{
            .mutable = false,
            .name = w.b.ident(marker_var),
            .receiver_type = null,
            .ty = null,
            .init = w.b.member(w.composerRef(), "currentMarker"),
            .delegate = null,
            .getter = null,
            .setter = null,
            .is_abstract = false,
            .is_open = false,
            .is_override = false,
            .is_lateinit = false,
            .is_const = false,
            .is_inline = false,
            .is_expect = false,
            .is_actual = false,
            .setter_visibility = null,
            .visibility = .Public,
            .annotations = &.{},
            .span = w.b.gen_span,
        };
        const old = lam.body.stmts;
        const stmts = w.a.alloc(Stmt, old.len + 1) catch @panic("oom");
        stmts[0] = .{ .Decl = .{ .Property = prop } };
        @memcpy(stmts[1..], old);
        lam.body.stmts = stmts;
    }

    /// The `$changed` a threaded call passes: per-arg certainty bits for the positional
    /// prefix, stopped by the first named arg. A literal is static (`0b110 << 3i`); a bare
    /// forward of an exclusively-tripled param recombines its `$dirty` triple.
    fn childChangedBits(w: *Walker, callee_name: ?[]const u8, args: []const Expr, arg_names: []const ?[]const u8, had_trailing: bool) Expr {
        var const_bits: i64 = 0;
        var dyn: ?Expr = null;
        // Named args map through the composable-signature table; without a unique signature the
        // mapping stops at the first named arg.
        const callee_params: ?[]const []const u8 = blk: {
            const nm = callee_name orelse break :blk null;
            const map = root.active_composable_params orelse break :blk null;
            const cp = map.get(nm) orelse break :blk null;
            if (cp.names.len == 0) break :blk null;
            break :blk cp.names;
        };
        const n = if (had_trailing and args.len > 0) args.len - 1 else args.len;
        for (args[0..n], 0..) |*arg, i| {
            var pos: usize = i;
            if (i < arg_names.len and arg_names[i] != null) {
                const params = callee_params orelse break;
                const an = arg_names[i].?;
                pos = for (params, 0..) |pn, k| {
                    if (std.mem.eql(u8, pn, an)) break k;
                } else break;
            }
            if (pos > 8) continue;
            const triple: u5 = @intCast(pos);
            switch (arg.*) {
                .IntLit, .BoolLit, .CharLit, .FloatLit, .NullLit => {
                    const_bits |= @as(i64, 6) << (3 * @as(u6, triple));
                },
                .Path => |p| {
                    if (!w.dirty_in_scope) continue;
                    const triples = w.param_triples orelse continue;
                    if (p.segments.len != 1) continue;
                    if (w.shadowed_triples != null and w.shadowed_triples.?.contains(p.segments[0].name)) continue;
                    const j = triples.get(p.segments[0].name) orelse continue;
                    const term: Expr = if (j == triple)
                        w.b.callMember(w.b.pathExpr(dirty_local), "and", w.b.slice1(w.b.intLit(@as(i64, 6) << (3 * @as(u6, triple)))))
                    else blk: {
                        const extracted = w.b.callMember(
                            w.b.callMember(w.b.pathExpr(dirty_local), "shr", w.b.slice1(w.b.intLit(3 * @as(i64, j)))),
                            "and",
                            w.b.slice1(w.b.intLit(6)),
                        );
                        break :blk w.b.callMember(extracted, "shl", w.b.slice1(w.b.intLit(3 * @as(i64, triple))));
                    };
                    dyn = if (dyn) |acc| w.b.callMember(acc, "or", w.b.slice1(term)) else term;
                },
                else => {},
            }
        }
        if (root.memo_trace_enabled) {
            std.debug.print("[bits] callee={s} const={d} dyn={} nargs={d} sig={}\n", .{ callee_name orelse "?", const_bits, dyn != null, args.len, callee_params != null });
        }
        if (dyn) |d| {
            if (const_bits == 0) return d;
            return w.b.callMember(d, "or", w.b.slice1(w.b.intLit(const_bits)));
        }
        return w.b.intLit(const_bits);
    }

    /// Append `($composer = <composer>, $changed = <childChanged>)` by NAME: a positional
    /// append would bind the composer into the first defaulted param the caller omitted.
    pub fn threadCall(w: *Walker, c: anytype, positional: bool) std.mem.Allocator.Error!void {
        if (c.arg_names.len >= 2) {
            const composer_name = c.arg_names[c.arg_names.len - 2];
            const changed_name = c.arg_names[c.arg_names.len - 1];
            if (composer_name != null and changed_name != null and
                std.mem.eql(u8, composer_name.?, composer_param) and
                std.mem.eql(u8, changed_name.?, changed_param))
            {
                return;
            }
        }
        const had_trailing = c.has_trailing_lambda;
        var new_args = try w.a.alloc(Expr, c.args.len + 2);
        @memcpy(new_args[0..c.args.len], c.args);
        new_args[c.args.len] = w.composerRef();
        new_args[c.args.len + 1] = w.childChangedBits(calleeSimpleName(c.callee), c.args, c.arg_names, had_trailing);
        const new_names = try w.a.alloc(?[]const u8, new_args.len);
        for (new_names, 0..) |*n, i| n.* = if (i < c.arg_names.len) c.arg_names[i] else null;
        // A trailing lambda binds the callee's last function-typed parameter even across a
        // defaulted middle one, but clearing `has_trailing_lambda` strips that signal, so it is
        // re-emitted by name. Only when the call reaches the content-sink overload: the content
        // reach, the fewest arguments any sink overload needs to bind `content`, gates that.
        if (!positional) {
            new_names[c.args.len] = composer_param;
            new_names[c.args.len + 1] = changed_param;
        } else {
            new_names[c.args.len] = null;
            new_names[c.args.len + 1] = null;
        }
        c.args = new_args;
        c.arg_names = new_names;
        c.has_trailing_lambda = false;
    }
};
