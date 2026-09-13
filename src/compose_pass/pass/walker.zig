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

/// Recursive in-place body transformer. Within a `@Composable` function body it
/// replaces every `currentComposer` read with the threaded `$composer` parameter
/// and appends `($composer, childChanged)` to every `@Composable` call,
/// descending through control flow, nested calls, string interpolations, and
/// lambda bodies.
pub const Walker = struct {
    a: std.mem.Allocator,
    b: B,
    oracle: ComposableOracle,
    oracle_ctx: *anyopaque,
    sinks: ?*const std.StringHashMap(void) = null,
    /// Local vals declared `MutableState<@Composable fn>` or `State<...>`, keyed
    /// by name to the composable fn type's arity. A later `x.value = { … }`
    /// assignment's lambda is a composable value by that declared type and wraps
    /// in composableLambdaInstance like a typed val initializer.
    composable_state_vals: ?*std.StringHashMap(u8) = null,
    /// Names of the enclosing function's `@Composable`-lambda-typed value
    /// parameters. A bare call to one invokes a lowered composable lambda whose
    /// trailing params are `$composer`/`$changed`, so it threads like an
    /// oracle-named composable call.
    lambda_params: ?*std.StringHashMap(void) = null,
    /// Wrap a returned composable lambda in composableLambdaInstance. Enabled
    /// only for the movable-content factories.
    wrap_ret_lambda: bool = false,
    /// Simple names of LOCAL `@Composable` declarations seen so far in this walk,
    /// scoped to the enclosing function's transform. A local name must never join
    /// the global oracle, or unrelated same-named functions everywhere thread.
    locals: ?*std.StringHashMap(void) = null,
    /// Scoped names of vals holding composable lambdas, factory-initialized or
    /// declared with a `@Composable` fn type. Their bare calls are VALUE
    /// invocations, so the pair passes positionally: a wrapped
    /// ComposableLambdaImpl declares `invoke(c, changed)` and named
    /// `$composer=`/`$changed=` args cannot bind it. Function calls keep the
    /// named pair for the defaulted-marker machinery.
    composable_vals: ?*std.StringHashMap(void) = null,
    /// Vals initialized from `movableContentOf` or `movableContentWithReceiverOf`.
    /// Their bare invokes compose but keep the runtime-completed call protocol, so
    /// the name feeds ONLY the branch scan: an `if (…) content()` still needs
    /// branch groups and the synthesized empty else, or a branch flip deletes the
    /// sibling group that moves into its slot.
    movable_vals: ?*std.StringHashMap(void) = null,
    /// Ambient mode: the scope is a `@Composable` property getter, which has no
    /// `$composer` param, so composer references resolve through the
    /// `__compose_currentComposer` host intrinsic.
    ambient: bool = false,
    /// The enclosing function is `@ExplicitGroupsComposable`: it manages its own
    /// groups with explicit `startX`/`endX` composer calls, so the automatic
    /// per-branch replace-groups must NOT be inserted. Inserting them corrupts the
    /// group structure: in `ReusableContentHost`'s `if (active) content() else
    /// deactivateToEndGroup()`, a branch bracket makes the deactivate path start a
    /// key-mismatched replace-group that deletes the reused content's nodes. Reset
    /// to false inside a nested composable lambda, its own non-explicit scope.
    explicit_groups: bool = false,
    /// Whether the current scope is composable: a composable function body or a
    /// composable lambda body. Only there are `@Composable` calls threaded and
    /// `currentComposer` substituted. A non-composable body is still walked, to
    /// transform composable-lambda-sink arguments, but its own calls are left
    /// alone.
    thread: bool = true,
    /// The enclosing function declares a `@Composable`-function-typed return
    /// type, so a lambda in return position (`return { … }`, or the whole
    /// expression body) is composable, as in `movableContentOf`'s wrapper.
    ret_composable: bool = false,
    /// Declared param count of that return function type; the header-less
    /// returned lambda keeps an `it` slot when it is 1.
    ret_fn_params: u8 = 0,
    /// Stack of enclosing composable-lambda scopes a `return@label` can target. A
    /// non-local return, one naming a scope other than the innermost, closes every
    /// group opened since that scope started, the way the compiler emits
    /// `$composer.endToMarker($marker)`. Lazily created.
    nlr_scopes: ?*std.ArrayList(NlrScope) = null,
    /// Monotonic source of fresh marker-local names for this walk.
    nlr_counter: usize = 0,
    /// Enclosing restartable fn's value-param name to skip-calculus triple index,
    /// present only when the transform emitted per-param probes. Lets a memoized
    /// lambda whose captures are all params derive its validity from `$dirty` with
    /// zero stored key slots, kotlinc's shape.
    param_triples: ?*const std.StringHashMap(u5) = null,
    /// `$dirty` carries live per-param facts in the CURRENT scope: true in the
    /// restartable body and through inline-callee lambda splices, false inside a
    /// nested composable lambda, whose recompositions run without the enclosing
    /// frame's `$dirty`.
    dirty_in_scope: bool = false,
    /// Local declarations seen so far that shadow a tripled param name. A bare
    /// reference to such a name is the local, whose change state the param's
    /// `$dirty` triple does not describe. Lazily created.
    shadowed_triples: ?*std.StringHashMap(void) = null,

    /// A `return@label` target: the enclosing composable lambda labelled `label`,
    /// the local `marker_var` holding its start marker, and whether a non-local
    /// return referenced it, so the marker capture is emitted only when needed.
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

    /// If `label` names a non-innermost enclosing composable-lambda scope, mark
    /// that scope as needing its start marker and return the marker-local name to
    /// close groups back to. Null for a local return, which closes its own groups
    /// as it unwinds.
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

    /// The composer reference for the current scope: the threaded `$composer`
    /// param, or the ambient intrinsic call in a getter.
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
            // A statement-position `if`/`when` discards its value, so an
            // expression-shaped branch (`if (c) parent { … } else parent { … }`,
            // no braces) can be boxed into a Block and take the per-branch
            // replaceable group like a braced branch. An expression-position
            // conditional keeps the Block-only rule so its value is not
            // displaced.
            .Expr => |*e| {
                try w.walkExpr(e);
                // An `@ExplicitGroupsComposable` body manages its own groups, so
                // its statement conditionals take no per-branch replace-groups.
                if (w.thread and !w.explicit_groups) w.wrapStatementConditional(e);
            },
            .Assign => |*asg| {
                try w.walkExpr(&asg.target);
                // `content.value = { … }` where `content` is a recorded
                // `MutableState<@Composable fn>` val: the stored lambda is
                // composable by the state's declared type, so it threads and wraps
                // in composableLambdaInstance like a typed val initializer. The
                // reference then sees a stable ComposableLambdaImpl whose invoke
                // records changed(this), so a swapped content invalidates.
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
                // A local shadowing a tripled param name retires that name from
                // `$dirty`-derived certainty for the rest of the walk.
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
                // `val content: @Composable () -> Unit = { … }`, where the
                // declared type makes the initializer lambda composable, or
                // `val content = @Composable { … }`, where the literal carries the
                // annotation itself.
                if (p.init) |*ini| {
                    if (p.ty != null and isComposableFnType(&p.ty.?)) {
                        try w.walkComposableValueExpr(
                            ini,
                            @intCast(@min(p.ty.?.function.?.params.len, 255)),
                        );
                        // In a plain scope the val's lambda is a composable value
                        // with no composer ambient at creation, so kotlinc wraps it
                        // in composableLambdaInstance(key, true, block) and every
                        // invocation gets its own restart group. The per-lambda key
                        // keeps currentCompositeKeyHashCode distinct between two
                        // content lambdas run under the same movable-content root.
                        if (root.emit_lambda_memo and !w.thread and ini.* == .Lambda) {
                            w.wrapInComposableLambdaInstance(ini);
                        }
                    } else if (p.ty != null and stateOfComposableArity(&p.ty.?) != null) {
                        // In `val content: MutableState<@Composable () -> Unit> =
                        // mutableStateOf({ … })` the state's type argument makes
                        // every stored lambda composable. Record the val for the
                        // assignment walk and wrap the initial store's lambda.
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
                        // No declared type: the literal's own header is the arity,
                        // and a headerless literal is `() -> Unit`, since its
                        // parser-injected `it` never binds without an expected
                        // type.
                        const arity: u8 = if (ini.Lambda.implicit_it) 0 else @intCast(@min(ini.Lambda.params.len, 255));
                        try w.transformComposableLambda(&ini.Lambda, arity, null);
                    } else {
                        try w.walkExpr(ini);
                    }
                }
                if (p.delegate) |del| try w.walkExpr(del);
                // A val holding a composable lambda, declared with a
                // `@Composable` fn type or initialized from a factory returning
                // one (`val content = movableContentOf { … }`), joins the scoped
                // locals set so a bare `content()` threads.
                const holds_composable = blk: {
                    if (p.ty != null and isComposableFnType(&p.ty.?)) break :blk true;
                    if (p.init) |*ini2| {
                        if (ini2.* == .Lambda and isComposable(ini2.Lambda.annotations)) break :blk true;
                    }
                    // In `val current by rememberUpdatedState(content)` the
                    // delegated val reads back a value the walker already knows is
                    // composable, so `current()` threads like `content()`.
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
                    // An unclassified val's bare calls go unthreaded; the runtime
                    // closure completion supplies the pair from the ambient
                    // composer when the invoked value's protocol wants it.
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
                    // The name joins both sets: `locals` feeds nested transforms
                    // and branch scans, while `composable_vals` only decides the
                    // positional pair under the memo emission.
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
                // A local `@Composable` declaration transforms like a top-level
                // one, its name already in the oracle via the body-deep
                // collection, and the transform walks its body itself.
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
                // A local fn returning a `@Composable` fn type: its
                // return-position lambdas compose like a top-level one's, with the
                // walker flag scoped to this declaration.
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

    /// Walk an expression under an expected `@Composable` function type. Kotlin
    /// propagates that expected type through value-producing control flow, so
    /// every lambda leaf gains the hidden composer ABI even when the property
    /// initializer is an `if`, `when`, `try`, or block rather than a lambda.
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

    /// Replace a just-transformed composable lambda ARGUMENT with
    /// `rememberComposableLambda(<span key>, true, <lambda>, $composer, 0)`, the
    /// remembered instance the engine slots, so `composer.changed(content)` is
    /// false when the content is unchanged and the child group skips. Threaded
    /// scope only, since `$composer` must be in scope; entry-point sinks in plain
    /// scope stay raw, as `invokeComposable` wraps the root itself.
    fn wrapInComposableLambda(w: *Walker, arg: *Expr) void {
        w.wrapInComposableLambdaLabeled(arg, null);
    }

    /// Bracket a ComposableLambdaImpl-invoked lambda body with the
    /// restartable-but-not-skippable execute gate compiled into composable
    /// lambdas: `if ($composer.shouldExecute(true, $changed and 1)) { <body> }
    /// else { $composer.skipToGroupEnd() }`. The impl's invoke supplies the
    /// restart group. Without this gate the body has no pause point, so a
    /// PausableComposition resumes a content lambda's children in its parent's
    /// round instead of pausing at the lambda. The literal `true` adds only the
    /// pause consult, leaving the execute decision unchanged.
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
        // `rememberComposableLambda(key, true, block, $composer, 0)` remembers
        // the `ComposableLambdaImpl` in a slot of the current group rather than
        // opening a child group, whose stray group breaks
        // `deactivateToEndGroup`.
        const args = w.a.alloc(Expr, 5) catch @panic("oom");
        args[0] = w.b.intLit(key);
        args[1] = .{ .BoolLit = .{ .value = true, .span = w.b.gen_span } };
        // Wrapping re-parents the lambda under the memo call, which strips its
        // callee-derived implicit label; a `return@PWrap` inside would then unwind
        // past ComposableLambdaImpl.invoke and leave the restart group open. The
        // label is re-attached explicitly as `lbl@ { … }`.
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

    /// A composable lambda returned by a non-composable factory has no
    /// `$composer` in scope, so kotlinc wraps it in
    /// `composableLambdaInstance(key, true, block)`, a ComposableLambdaImpl whose
    /// invoke supplies the restart group each call site needs. Without it,
    /// `movableContentOf`'s `content(n)` composes the movable group with no
    /// restart bracket and multi-insert positioning breaks.
    pub fn wrapInComposableLambdaInstance(w: *Walker, arg: *Expr) void {
        const key = positionalKey(exprSpanOf(arg));
        if (arg.* == .Lambda) w.wrapLambdaBodyInPausePoint(&arg.Lambda);
        const args = w.a.alloc(Expr, 3) catch @panic("oom");
        args[0] = w.b.intLit(key);
        args[1] = .{ .BoolLit = .{ .value = true, .span = w.b.gen_span } };
        args[2] = arg.*;
        arg.* = w.b.call(w.b.pathExprSegs(&composable_lambda_instance_path), args);
    }

    /// Whether a branch contains a call the pass considers composable: an oracle
    /// name, scoped local, composable lambda param, or sink. This gates the
    /// per-branch replace groups, since only conditional COMPOSITION is
    /// bracketed; bracketing plain control flow inside threaded engine functions
    /// corrupts their group structure.
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
                // A bare read of a `@Composable`-getter property
                // (`currentRecomposeScope`, `currentCompositeKeyHashCode`)
                // composes, so the containing lambda is composable content even
                // when it makes no composable call.
                if (p.segments.len >= 1 and root.active_composable_getter_props != null and
                    root.active_composable_getter_props.?.contains(p.segments[p.segments.len - 1].name))
                    return true;
                return false;
            },
            .Member => |m| {
                // `receiver.currentCompositeKeyHashCode`: a composable-getter read
                // through an explicit receiver.
                if (root.active_composable_getter_props != null and
                    root.active_composable_getter_props.?.contains(m.name.name)) return true;
                return w.branchHasComposable(m.receiver);
            },
            // Composable calls under control flow still make the branch composable
            // content: a `Linear { for (id in items) Text("$id") }` lambda is
            // memoized like its straight-line sibling, or every re-run passes a
            // fresh closure and the callee's `changed(content)` probe records a
            // change the reference runtime never sees.
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

    /// Statement-position conditional: box each expression-shaped branch holding
    /// composable content into a Block, then bracket it with the per-branch
    /// replaceable group; braced branches were already wrapped by the expression
    /// walk. Recurses down `else if` chains, since every arm of a statement
    /// conditional is statement-position too.
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
                        // A conditional whose false path emits no group leaves a
                        // positional hole: on the false frame the stale then-group
                        // sits where the next sibling's replace or restart group
                        // starts, and the replace-on-mismatch path deletes it and
                        // re-inserts everything after. The false path therefore
                        // emits an empty replaceable group.
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
                        // Same positional hole as an else-less `if`: a when
                        // statement matching no branch still emits a group.
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

    /// Whether a loop body is exactly one bare `key(...)` call, directly or as a
    /// single-statement block.
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

    /// Bracket a loop whose body composes: the body gets a per-iteration
    /// replaceable group, one sibling group per iteration under the same span key
    /// that the runtime reconciles positionally, and the loop itself an outer
    /// group. A change in iteration count then inserts or removes body groups
    /// instead of shifting every slot after the loop. Bodies that jump out with
    /// `break`, `continue`, or `return` stay unbracketed, since the jump would
    /// skip the end call.
    fn wrapLoopContent(w: *Walker, loop: *Expr, body: *Expr) void {
        if (!(w.thread and !w.explicit_groups)) return;
        if (!w.branchHasComposable(body)) return;
        if (loopBodyEscapes(body)) return;
        // A body that IS a `key(...)` call brings its own movable group, which
        // must sit as a direct sibling of the other iterations' groups so a
        // reorder MOVES it. A per-iteration replace wrapper would pair old and new
        // iterations positionally, leaving each pending with a single foreign key
        // and recreating every node. The movable group already gives each
        // iteration its own bracket, covering the remember-shift case too.
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

    /// Whether a loop body contains a `break`, `continue`, or `return` that leaves
    /// the body, at any depth. Nested loops keep their own break/continue, but
    /// scanning conservatively at all depths only costs a missed bracket, never an
    /// unbalanced group.
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

    /// Wrap a plain lambda argument of a composable call in
    /// `remember(<capture keys...>, { <lambda> })`, the strong-skipping lambda
    /// memoization. Capture keys are the bare names the body reads that are not
    /// declared inside it, call callees excluded. An over-approximate key, such as
    /// a stable global, only ever compares equal and cannot break identity, while
    /// a missed key would, so the wrap bails when the body writes any bare name: a
    /// captured `var` the runtime boxes, whose cell key is meaningless.
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
        // kotlinc's zero-key-slot shape: when every capture is an enclosing
        // restartable fn's value param whose change state `$dirty` already
        // carries, the memo is `$composer.cache(<any capture changed>, calc)`, one
        // stored slot and no keys. Falls through to the key-slot `remember` wrap
        // when any capture is a local, whose probe would consume a slot anyway, or
        // `$dirty` is out of scope.
        const memo_trace = root.memo_trace_enabled;
        if (memo_trace) {
            std.debug.print("[memo] callee={s} dirty_in_scope={} triples={} keys:", .{ callee_name, w.dirty_in_scope, w.param_triples != null });
            for (keys.items) |k| std.debug.print(" {s}", .{k.Path.segments[0].name});
            std.debug.print("\n", .{});
        }
        // A fully closed lambda, `{}` with no captures and no bare names at all,
        // lifts to a top-level singleton val, kotlinc's static-instance shape:
        // permanent identity, a static argument, and no slot consumed anywhere.
        // Only the empty body qualifies; a body with calls still resolves bare
        // names through the creation-time receiver chain and stays site-created.
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
        // A zero-capture lambda's memo never invalidates: `cache(false, calc)`
        // needs no `$dirty` and holds one permanent slot in any scope, kotlinc's
        // lifted-singleton shape without the lift.
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
        // Threaded with the composer pair, like the rememberComposableLambda
        // wrap, so the emitted call names the one `remember` overload whose arity
        // matches (keys, calculation, pair) and qualified-call lowering binds it
        // precisely instead of the first-registered overload.
        rem_args[keys.items.len + 1] = w.composerRef();
        rem_args[keys.items.len + 2] = w.b.intLit(0);
        // Fully qualified: the synthesized call lands in user-file import scope,
        // which need not import `remember` itself.
        arg.* = w.b.call(w.b.pathExprSegs(&.{ "androidx", "compose", "runtime", "remember" }), rem_args);
    }

    /// `{ $composer.startReplaceGroup(<span key>); $composer.endReplaceGroup() }`,
    /// the group a conditional's untaken path still occupies.
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

    /// `wrapBranchInReplaceGroup`, boxing a non-Block branch into a
    /// single-statement Block first. Idempotent for already-wrapped blocks, whose
    /// first statement is the startReplaceGroup call.
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
    /// `dyn_n` is the count of dynamic key arguments, the original args before the
    /// content lambda. Multiple keys join pairwise through `$composer.joinKey`.
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

    /// Bracket a Block-shaped branch with
    /// `$composer.startReplaceGroup(<span key>)` and `endReplaceGroup()`.
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
        // `currentComposer`, bare or as a trailing member segment, IS the threaded
        // composer inside a composable body.
        if (w.thread and isCurrentComposer(e)) {
            e.* = w.composerRef();
            return;
        }
        switch (e.*) {
            .Call => |*c| {
                try w.walkExpr(c.callee);
                const name = calleeSimpleName(c.callee);
                // `key(k…) { content }` before its args gain the composer pair:
                // the dynamic key count is every argument before the trailing
                // content lambda.
                const key_dyn_n: usize = if (c.args.len >= 2) c.args.len - 1 else 0;
                const is_key_call = w.thread and name != null and
                    std.mem.eql(u8, name.?, "key") and key_dyn_n >= 1 and
                    c.args[c.args.len - 1] == .Lambda and w.oracle(w.oracle_ctx, "key");
                // A trailing lambda bound to a `@Composable`-typed parameter
                // becomes a `{ …, $composer, $changed -> … }` lambda, since
                // composable lambdas lower to `FunctionN<…, Composer, Int, …>` and
                // the engine invokes them with the composer. It is transformed in
                // place of the generic lambda-body recursion, so its body threads
                // once against its own `$composer`, not the enclosing one, and no
                // argument threads twice.
                //
                // A sink whose name is ITSELF a composable function is only
                // callable from composable context; the same bare name in a
                // non-composable scope is a different declaration (the validator
                // extension `MockViewValidator.Linear(block)`), which must not be
                // handed a phantom composer. A non-composable sink, such as the
                // `compose { }` and `movableContentOf { }` entry points,
                // transforms its lambda from any scope.
                const sink_applies = name != null and w.sinks != null and w.sinks.?.contains(name.?) and
                    (w.thread or !w.oracle(w.oracle_ctx, name.?));
                // A call through a composable-lambda VALUE, a movableContentOf val
                // or a composable lambda param, is a composable call too: its
                // trailing lambda binds a `@Composable`-typed parameter, as in
                // `parent { Wrap { child() } }` where `parent` came from
                // `movableContentOf<@Composable () -> Unit>`, so it transforms like
                // a named sink's. Threaded scope only, since the same bare name
                // outside composition is a different declaration.
                const val_sink = name != null and w.thread and
                    ((w.composable_vals != null and w.composable_vals.?.contains(name.?)) or
                        (w.locals != null and w.locals.?.contains(name.?)) or
                        (w.lambda_params != null and w.lambda_params.?.contains(name.?)));
                // The trailing lambda may carry an explicit label
                // (`InlineLinear outer@{ … }`), which the parser wraps in a
                // `Labeled` node. Unwrapping it reaches the lambda so the labeled
                // form threads identically to the bare one.
                const sink_last = c.args.len != 0 and
                    trailingLambda(&c.args[c.args.len - 1]) != null and (sink_applies or val_sink);
                for (c.args, 0..) |*arg, i| {
                    if (sink_last and i == c.args.len - 1) {
                        const sink_lam = trailingLambda(arg).?;
                        // The `return@label` target for this sink lambda: its
                        // explicit `lbl@` label, or the callee name for the
                        // implicit `return@Callee` form.
                        const sink_label: ?[]const u8 = switch (arg.*) {
                            .Labeled => |lb| lb.label.name,
                            else => name,
                        };
                        // The pass shapes a headerless sink lambda with the bare
                        // composer pair and leaves the slot count to the lowering,
                        // which repairs it against the resolved parameter's
                        // declared arity: transformResolvedComposableLambda inserts
                        // the implicit `it` when the selected parameter takes one,
                        // and the runtime's flattened-receiver dispatch supplies a
                        // receiver slot the declared arity omits.
                        const exp: ?u8 = null;
                        const is_mco = std.mem.eql(u8, name.?, "movableContentOf");
                        const is_mcwro = std.mem.eql(u8, name.?, "movableContentWithReceiverOf");
                        // A movable-content type arg that is itself a
                        // `@Composable` function type makes the lambda param at
                        // that position a composable value, so a bare `child()` in
                        // the body threads the composer
                        // (`movableContentOf<@Composable () -> Unit> { child ->
                        // Wrap { child() } }`). Those param names join the walker's
                        // lambda-param set for the body walk and are removed after
                        // unless already present.
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
                        // Wrap only content that actually composes: the name-keyed
                        // sink also catches sibling overloads' plain trailing
                        // lambdas, such as ComposeNode's update, whose wrapped
                        // invoke shape would not exist. An inline composable's
                        // lambda stays raw, since kotlinc splices it into the
                        // caller's group; wrapping would also re-parent it under
                        // `composableLambda(..)` so its implicit label no longer
                        // matches and a `return@InlineWrapper` unwinds past
                        // ComposableLambdaImpl.invoke, leaving the root restart
                        // group open.
                        //
                        // A movable-content factory call outside composition
                        // (`val c = movableContentOf { … }`) still stores its
                        // content as a composableLambdaInstance singleton, the
                        // wrapper that supplies the restart group the movable
                        // machinery re-invokes on nested recompose; a raw threaded
                        // closure has none and the group walk diverges.
                        if (!w.thread and root.emit_lambda_memo and (is_mco or is_mcwro)) {
                            w.wrapInComposableLambdaInstance(arg);
                        }
                        // Wrap by TYPE, not content: the sink's parameter is
                        // declared `@Composable`, so kotlinc memoizes the lambda
                        // regardless of what its body does. Unwrapped, it passes a
                        // fresh instance every parent recompose and re-invalidates
                        // the subcomposition through rememberUpdatedState.
                        if (w.thread and root.emit_lambda_memo and
                            !calleeInlinesLambda(name.?))
                        {
                            w.wrapInComposableLambdaLabeled(arg, name.?);
                            // The wrapped argument is no longer a lambda, so it
                            // binds by the sink's last-parameter name and a
                            // defaulted middle parameter cannot absorb it
                            // positionally.
                        }
                    } else if (arg.* == .Lambda and w.thread and name != null and
                        calleeInlinesLambda(name.?))
                    {
                        // An inline callee's lambda body composes inline in the
                        // enclosing composable, so threading continues; the generic
                        // lambda walk below resets it for plain value-position
                        // lambdas.
                        if (!lambdaHasComposerParams(&arg.Lambda)) {
                            // An inline lambda's params shadow same-named tripled
                            // fn params. Shadowing is retired for the rest of the
                            // walk, which is conservative but never unsound.
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
                        // A plain callback lambda at a non-inline callee
                        // (`DisposableEffect { … }`, `LaunchedEffect { … }`) is not
                        // a composable scope: kotlinc admits composable calls only
                        // through inline splices or composable parameters.
                        // Threading it emits memo wraps and composer brackets that
                        // execute after composition through the captured outer
                        // composer, leaving unapplied change ops behind.
                        const saved = w.thread;
                        w.thread = false;
                        try w.walkExpr(arg);
                        w.thread = saved;
                        // Strong-skipping lambda memoization: kotlinc wraps a
                        // plain lambda argument of a composable call in
                        // `remember(captures...) { lambda }` so an unchanged
                        // re-execution passes the SAME instance. Skipped when the
                        // body returns to the callee's implicit label, which
                        // rewrapping would re-parent.
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
                        // An explicit-receiver invoke of a `@Composable`-typed
                        // property (`content.content(parameter)`) is served by the
                        // runtime closure completion: a typeless composable value
                        // call gains the pair from the ambient composer when the
                        // closure's protocol wants it.
                        const is_composable_prop = false;
                        // VALUE invocations take the pair positionally, but only
                        // under the memoization emission, since a wrapped
                        // ComposableLambdaImpl cannot bind the named pair. That is
                        // exactly where the value can be memo-wrapped: sink-arg
                        // lambdas reaching lambda params and composable props. A
                        // composable val, such as movableContentOf's returned
                        // wrapper, holds an unwrapped closure with literal
                        // `$composer`/`$changed` params and keeps the named pair.
                        const positional = root.emit_lambda_memo and (is_lambda_param or is_composable_prop or is_composable_val or is_local_composable);
                        // Bare, member-form, and qualified-path calls all keep
                        // their source argument shape. IR resolution selects the
                        // exact declaration first, and only then does lowering
                        // complete a proven Compose ABI; a runtime-dispatched
                        // member or member-syntax extension completes at the
                        // member-miss tail. Both work against the RESOLVED
                        // declaration, never a simple name, so `oracle_hit` is
                        // constant-false and only the value-invocation forms above
                        // transform at the call site.
                        const oracle_hit = false;
                        if (positional or is_composable_val or is_local_composable or oracle_hit) try w.threadCall(c, positional);
                    }
                }
                // `key(k…) { content }` is a compiler intrinsic: kotlinc brackets
                // it with a movable group whose data key joins the dynamic key
                // arguments, so a changed key replaces or moves the content's group
                // identity. The upstream function body is just `block()`, so
                // without the bracket the dynamic keys are ignored entirely.
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
                // Conditional content in a composable body gets a replaceable
                // group per branch under distinct span keys, the plugin ABI's
                // slot-alignment bracket. Without it a forced recomposition of an
                // unchanged body misaligns at the branch and reports spurious
                // changes, and a branch flip cannot replace its content atomically.
                // Statement-shaped (Block) branches only: an expression-if's value
                // must not be displaced by the bracket call.
                if (w.thread and !w.explicit_groups and (w.branchHasComposable(f.then_branch) or
                    (if (f.else_branch) |eb2| w.branchHasComposable(eb2) else false)))
                {
                    // A composable `if` with no `else` still needs a group in the
                    // not-taken branch: without it the conditional's group is absent
                    // when the condition is false and present when true, so a flip
                    // shifts every following sibling and `startReplaceGroup` deletes
                    // the sibling that moved into its slot. kotlinc emits the same
                    // synthesized empty else.
                    if (f.else_branch == null) {
                        // Key the empty else off the `if`'s own span so each
                        // conditional's else group is stable and distinct from its
                        // then group, which keys off the then-branch span.
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
                // A non-local `return@label` unwinds past composable calls whose
                // groups were opened after the target scope started, so they close
                // first with `$composer.endToMarker($marker)`, mirroring the
                // compiler's epilogue. The return value composes inside the
                // still-open groups (`return@compose Text("true")`), so it
                // evaluates into a temp BEFORE the marker close:
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
                // `when` branches take the same per-branch replaceable group as
                // `if` branches: conditional composable content needs a
                // slot-alignment bracket per branch, or a branch flip cannot
                // replace its content atomically. Statement-shaped (Block) branches
                // only.
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
                // `transformComposableLambda` walks the body against the lambda's
                // own composer immediately. A surrounding expression walk may
                // encounter that shared node again, which must not thread or
                // bracket its body a second time.
                //
                // A plain lambda in value position, a returned `() -> Unit` or a
                // stored callback, is not composable content even inside a
                // composable body: kotlinc composes only through composable sinks
                // and inline splices. Threading one would emit
                // `rememberComposableLambda($composer, ...)` capturing the
                // enclosing composer, which, run later outside composition, records
                // into that composer's drained change list. Inline-callee lambda
                // args keep threading via their explicit arm in the call walk.
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

    /// Rewrite a `@Composable` lambda to `{ …orig, $composer, $changed -> … }` and
    /// thread its body. A `@Composable (P…) -> R` lowers to a
    /// `FunctionN<P…, Composer, Int, R>`, which `invokeComposable` and the composer
    /// invoke with the composer and a changed flag.
    pub fn transformComposableLambda(w: *Walker, lam: anytype, expected_params: ?u8, label: ?[]const u8) std.mem.Allocator.Error!void {
        if (dbg_lambda) std.debug.print("[compose-pass] transform composable lambda ({d} params)\n", .{lam.params.len});
        // Idempotence: a lambda already carrying a trailing `$composer` param, a
        // shared node reached twice, is left alone.
        if (lambdaHasComposerParams(lam)) return;
        // A lambda with only the synthetic `it`, a header-less `{ … }` bound to a
        // `() -> R` sink, has no real parameters: the composer/changed pair
        // replaces `it` rather than following it. A header-declared lambda keeps
        // its explicit parameters and gains the pair after them, as does the
        // implicit `it` when the sink's declared composable type takes one
        // parameter, since `MovableContent({ content() })` invokes its content with
        // the movable parameter first.
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
        // The pair is declared, not inferred: the body's `$composer.…` group calls
        // and `$changed and …` masks bind statically only when the lambda records
        // the types the function form declares at its params.
        new_tys[n] = w.b.typeRef("Composer");
        new_tys[n + 1] = w.b.typeRef("Int");
        lam.params = new_params;
        lam.param_tys = new_tys;
        lam.implicit_it = false;
        // The lambda body IS composable, so it threads and substitutes
        // currentComposer even when the enclosing scope did not. A composable
        // lambda is its own scope, not the enclosing `@ExplicitGroupsComposable`
        // function's, so its branches take the automatic replace-groups again.
        const saved = w.thread;
        const saved_eg = w.explicit_groups;
        const saved_dirty = w.dirty_in_scope;
        w.thread = true;
        w.explicit_groups = false;
        // A composable lambda recomposes without the enclosing frame, so its body
        // must not read the outer `$dirty` for memo validity.
        w.dirty_in_scope = false;
        // Register this lambda as a `return@label` target so a nested non-local
        // return can close the groups it opened. The marker capture is prepended
        // only if such a return is found while walking the body.
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
        // A labeled early return (`return@run`) crossing a wrapped branch bracket
        // closes the replace-groups it exits. The content lambda's restart group
        // belongs to ComposableLambdaImpl, so only replace-groups close here.
        {
            // The lambda's own implicit label (`return@compose` inside the
            // `compose { }` content) is a local return for the injector: it closes
            // the replace-groups opened inside this body, like a bare `return` in a
            // fn body.
            var inj = EpilogueInjector{ .a = w.a, .b = w.b, .fn_name = label orelse "", .value_params = &.{}, .has_restart = false };
            try inj.stmts(lam.body.stmts);
        }
    }

    /// Prepend `val <marker_var> = <composer>.currentMarker` to a lambda body so
    /// a nested non-local return can pass the captured marker to `endToMarker`.
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

    /// The `$changed` value a threaded call passes: per-arg certainty bits for the
    /// positional argument prefix. Named args stop the mapping, since the pass has
    /// no callee signature to reorder against and a bit at the wrong triple would
    /// silence the wrong probe. A literal argument is static (`0b110 << 3i`); a
    /// bare forward of one of the enclosing restartable fn's exclusively-tripled
    /// params recombines its live `$dirty` triple into the callee's position, as
    /// kotlinc propagates. Everything else claims nothing and the callee probes.
    fn childChangedBits(w: *Walker, callee_name: ?[]const u8, args: []const Expr, arg_names: []const ?[]const u8, had_trailing: bool) Expr {
        var const_bits: i64 = 0;
        var dyn: ?Expr = null;
        // A named argument maps to its callee param position through the
        // compilation's composable-signature table; without a unique signature the
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

    /// Append `($composer = <composer>, $changed = <childChanged>)` to a resolved
    /// `@Composable` call. The pair passes by NAME: the callee may declare
    /// defaulted params between the caller's positional args and the synthetic
    /// pair, and a positional append would bind the composer into the first omitted
    /// param. Named, the binder slots the pair exactly and the omitted params take
    /// their defaults.
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
        // A trailing lambda binds the callee's last function-typed parameter, even
        // across a defaulted middle parameter: `ExplicitStartReplaceGroup(key,
        // insertGroup = true) { content }` binds the lambda to `content`, not
        // `insertGroup`. Clearing `has_trailing_lambda` below and appending the
        // composer pair strips that signal, so the now-plain positional lambda
        // would slide into the first open slot. Re-emitting it by the callee's last
        // parameter name rejoins it to `content` across the gap.
        //
        // Only when the call actually reaches the composable-content sink overload,
        // though. A bare-name key conflates overloads: `ComposeNode(::Factory)
        // { update }` binds the non-sink `(factory, update)` overload whose
        // trailing lambda already sits at its correct positional slot, while the
        // map records the sibling `(factory, update, content)` overload's `content`
        // param, and renaming to `content=` there misbinds the call. The content
        // reach is the fewest value arguments any sink overload needs for the
        // trailing lambda to bind `content`: the non-defaulted params before it,
        // plus the lambda. A call with fewer args binds a smaller, non-content
        // overload and keeps its trailing lambda positional.
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
