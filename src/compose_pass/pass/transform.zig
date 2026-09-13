//! Declaration-level transform: composer/changed threading, the defaulted-parameter
//! prologue, the `$dirty` skip calculus, and the restartable-group bracket.

const std = @import("std");
const ast = @import("ast");
const root = @import("../compose_pass.zig");

const Block = ast.Block;
const Expr = ast.Expr;
const Function = ast.Function;
const Param = ast.Param;
const Stmt = ast.Stmt;

const composer_param = root.composer_param;
const changed_param = root.changed_param;
const dirty_local = root.dirty_local;
const isComposable = root.isComposable;
const positionalKey = root.positionalKey;

const annotations = @import("annotations.zig");
const default_marker_path = annotations.default_marker_path;
const ambient_composer_path = annotations.ambient_composer_path;
const isRestartableComposable = annotations.isRestartableComposable;
const isExplicitGroups = annotations.isExplicitGroups;

const builder = @import("builder.zig");
const B = builder.B;

const collect = @import("collect.zig");
const ComposableOracle = collect.ComposableOracle;
const NameSetOracle = collect.NameSetOracle;
const isComposableLambdaParam = collect.isComposableLambdaParam;
const isComposableFnType = collect.isComposableFnType;

const epilogue = @import("epilogue.zig");
const EpilogueInjector = epilogue.EpilogueInjector;
const endRestartGroupExpr = epilogue.endRestartGroupExpr;
const signatureOnly = epilogue.signatureOnly;
const withBody = epilogue.withBody;

const stability = @import("stability.zig");
const fnIsSkippable = stability.fnIsSkippable;
const probeMethodFor = stability.probeMethodFor;

const walker = @import("walker.zig");
const Walker = walker.Walker;

/// Transform every `@Composable` top-level function in `decls` in place.
pub fn transformDecls(
    a: std.mem.Allocator,
    decls: []ast.Decl,
    composable_names: *const std.StringHashMap(void),
    lambda_sinks: *const std.StringHashMap(void),
) std.mem.Allocator.Error!void {
    var oracle = NameSetOracle{ .names = composable_names };
    for (decls) |*d| try transformDecl(a, d, &oracle, lambda_sinks, false, null);
}

fn transformDecl(
    a: std.mem.Allocator,
    d: *ast.Decl,
    oracle: *NameSetOracle,
    sinks: *const std.StringHashMap(void),
    in_class: bool,
    enclosing_class: ?[]const u8,
) std.mem.Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| {
            if (isComposable(f.annotations)) {
                if (root.dbg_groups) std.debug.print("[compose-pass] decl {s} restartable={}\n", .{ f.name.name, isRestartableComposable(f) });
                if (isRestartableComposable(f)) {
                    f.* = try transformComposableFunction(a, f, NameSetOracle.isComposableCall, oracle, sinks, in_class, null, enclosing_class);
                } else {
                    f.* = try transformThreadedComposable(a, f, NameSetOracle.isComposableCall, oracle, sinks, null);
                }
            } else {
                if (f.body == null) return;
                // Not composable: still walk the body so a `setContent { … }` lambda transforms.
                const ret_composable = f.return_type != null and isComposableFnType(&f.return_type.?);
                const ret_fn_params: u8 = if (ret_composable) @intCast(@min(f.return_type.?.function.?.params.len, 255)) else 0;
                const wrap_ret = ret_composable and std.mem.startsWith(u8, f.name.name, "movableContent");
                // A non-composable fn can still take `@Composable`-typed lambda params, so a bare
                // `content()` inside one of its composable lambdas is a composable call.
                const lp = a.create(std.StringHashMap(void)) catch @panic("oom");
                lp.* = try composableLambdaParamNames(a, f);
                var w = Walker{ .a = a, .b = .{ .a = a, .gen_span = f.span }, .oracle = NameSetOracle.isComposableCall, .oracle_ctx = oracle, .sinks = sinks, .thread = false, .ret_composable = ret_composable, .ret_fn_params = ret_fn_params, .lambda_params = lp, .wrap_ret_lambda = wrap_ret };
                if (f.body) |*fb| switch (fb.*) {
                    .Block => |*blk| try w.walkBlock(blk),
                    .Expr => |*e| if (ret_composable and e.* == .Lambda) {
                        try w.transformComposableLambda(&e.Lambda, ret_fn_params, null);
                        if (root.emit_lambda_memo and w.wrap_ret_lambda) w.wrapInComposableLambdaInstance(e);
                    } else {
                        try w.walkExpr(e);
                    },
                };
            }
        },
        .Class => |*c| for (c.members) |*m| try transformDecl(a, m, oracle, sinks, true, c.name.name),
        .Object => |*o| for (o.members) |*m| try transformDecl(a, m, oracle, sinks, true, o.name.name),
        .Property => |p| {
            const pb = B{ .a = a, .gen_span = p.span };
            var w = Walker{ .a = a, .b = pb, .oracle = NameSetOracle.isComposableCall, .oracle_ctx = oracle, .sinks = sinks, .thread = false };
            if (p.init) |*ini| try w.walkExpr(ini);
            if (p.delegate) |del| try w.walkExpr(del);
            // A `@Composable` property getter has no `$composer` param, so its body walks in
            // ambient mode through the `__compose_currentComposer` intrinsic.
            if (p.getter) |g| {
                if (isComposable(g.annotations) or isComposable(p.annotations)) {
                    if (std.mem.eql(u8, p.name.name, "currentComposer")) {
                        g.body = .{ .Expr = pb.call(pb.pathExprSegs(&ambient_composer_path), a.alloc(Expr, 0) catch @panic("oom")) };
                    } else {
                        var gw = Walker{ .a = a, .b = pb, .oracle = NameSetOracle.isComposableCall, .oracle_ctx = oracle, .sinks = sinks, .thread = true, .ambient = true };
                        switch (g.body) {
                            .Block => |*blk| try gw.walkBlock(blk),
                            .Expr => |*e| try gw.walkExpr(e),
                        }
                    }
                }
            }
        },
        else => {},
    }
}

fn markerCall(b: B) Expr {
    return b.call(b.pathExprSegs(&default_marker_path), b.a.alloc(Expr, 0) catch @panic("oom"));
}

/// Guard a marker-defaulted param's probe with `if (p$arg !== marker())`: kotlinc's
/// `$default`-mask path sets the dirty bits directly and stores no `changed` slot.
fn dirtyProbeIfPassed(b: B, arg_name: []const u8, probe: Stmt, triple: u5) Stmt {
    const not_default = Expr{ .Binary = .{
        .op = .IdentNeq,
        .lhs = b.box(b.pathExpr(arg_name)),
        .rhs = b.box(markerCall(b)),
        .span = b.gen_span,
    } };
    const then_stmts = b.a.alloc(Stmt, 1) catch @panic("oom");
    then_stmts[0] = probe;
    // Default taken: the slot is certain-same for this composition, so the triple's
    // same bit must set, or the `!= SAME` gate reads the empty triple as unknown.
    const else_stmts = b.a.alloc(Stmt, 1) catch @panic("oom");
    else_stmts[0] = dirtyOrConst(b, dirtySame(triple));
    return .{ .Expr = .{ .If = .{
        .cond = b.box(not_default),
        .then_branch = b.box(.{ .Block = .{ .stmts = then_stmts, .span = b.gen_span } }),
        .else_branch = b.box(.{ .Block = .{ .stmts = else_stmts, .span = b.gen_span } }),
        .span = b.gen_span,
    } } };
}

// Ten 3-bit triples fit above the forced bit in a Kotlin `Int`; slots beyond that
// share the last triple, which only widens invalidation.
fn tripleIdx(i: usize) u5 {
    return @intCast(@min(i, 9));
}

/// The changed and same values of skip-calculus triple `i`. The `$dirty` layout is
/// 3 bits per probed slot starting at bit 1; bit 0 is the restart-forced bit.
pub fn dirtyChanged(triple: u5) i64 {
    return @as(i64, 4) << (3 * @as(u6, triple));
}
fn dirtySame(triple: u5) i64 {
    return @as(i64, 2) << (3 * @as(u6, triple));
}
/// The whole-triple mask for probe `i` (0b111 at its position).
pub fn dirtyMask(triple: u5) i64 {
    return @as(i64, 14) << (3 * @as(u6, triple));
}

/// `if ($changed and (0b110 << 3i) == 0) { <probe> }`: the probe runs only when the
/// caller claimed nothing, which keeps slot-table usage position-stable.
fn guardProbe(b: B, probe: Stmt, triple: u5) Stmt {
    const guard = Expr{ .Binary = .{
        .op = .Eq,
        .lhs = b.box(b.callMember(b.pathExpr(changed_param), "and", b.slice1(b.intLit(@as(i64, 6) << (3 * @as(u6, triple)))))),
        .rhs = b.box(b.intLit(0)),
        .span = b.gen_span,
    } };
    const then_stmts = b.a.alloc(Stmt, 1) catch @panic("oom");
    then_stmts[0] = probe;
    return .{ .Expr = .{ .If = .{
        .cond = b.box(guard),
        .then_branch = b.box(.{ .Block = .{ .stmts = then_stmts, .span = b.gen_span } }),
        .else_branch = null,
        .span = b.gen_span,
    } } };
}

fn dirtyOrConst(b: B, v: i64) Stmt {
    return .{ .Assign = .{
        .target = b.pathExpr(dirty_local),
        .op = .Assign,
        .value = b.callMember(b.pathExpr(dirty_local), "or", b.slice1(b.intLit(v))),
        .span = b.gen_span,
    } };
}

/// `$dirty = $dirty or (if (<probe>) <changed_i> else <same_i>)`. The probe runs every
/// invocation, so the skip gate compares the triple region against all-same.
fn dirtyOrProbe(b: B, probe: Expr, triple: u5) Stmt {
    const pick = Expr{ .If = .{
        .cond = b.box(probe),
        .then_branch = b.box(b.intLit(dirtyChanged(triple))),
        .else_branch = b.box(b.intLit(dirtySame(triple))),
        .span = b.gen_span,
    } };
    return .{ .Assign = .{
        .target = b.pathExpr(dirty_local),
        .op = .Assign,
        .value = b.callMember(b.pathExpr(dirty_local), "or", b.slice1(pick)),
        .span = b.gen_span,
    } };
}

/// Every original param keeps its slot; a defaulted `p: T = D` is renamed `p$arg` with
/// the marker as its default and the prologue declares
/// `val p = if (p$arg === marker()) D else p$arg`. `$composer`/`$changed` come last.
const ParamsAndPrologue = struct { params: []Param, prologue: []Stmt };

fn composableLambdaParamNames(a: std.mem.Allocator, f: *const Function) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    for (f.params) |*p| {
        if (isComposableLambdaParam(p)) try set.put(p.name.name, {});
    }
    return set;
}

fn buildParamsAndPrologue(a: std.mem.Allocator, b: B, f: *const Function) std.mem.Allocator.Error!ParamsAndPrologue {
    var params = try a.alloc(Param, f.params.len + 2);
    var prologue: std.ArrayList(Stmt) = .empty;
    for (f.params, 0..) |p, i| {
        params[i] = p;
        if (p.default == null or f.body == null) continue;
        const argname = try std.fmt.allocPrint(a, "{s}$arg", .{p.name.name});
        params[i].name = b.ident(argname);
        params[i].default = b.box(markerCall(b));
        const cond = Expr{ .Binary = .{
            .op = .IdentEq,
            .lhs = b.box(b.pathExpr(argname)),
            .rhs = b.box(markerCall(b)),
            .span = b.gen_span,
        } };
        const pick = Expr{ .If = .{
            .cond = b.box(cond),
            .then_branch = p.default.?,
            .else_branch = b.box(b.pathExpr(argname)),
            .span = b.gen_span,
        } };
        const prop = try a.create(ast.Property);
        prop.* = .{
            .mutable = false,
            .name = p.name,
            .receiver_type = null,
            .ty = p.ty,
            .init = pick,
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
            .span = b.gen_span,
        };
        try prologue.append(a, .{ .Decl = .{ .Property = prop } });
    }
    params[f.params.len] = b.param(composer_param, b.typeRef("Composer"));
    params[f.params.len + 1] = b.param(changed_param, b.typeRef("Int"));
    return .{ .params = params, .prologue = try prologue.toOwnedSlice(a) };
}

/// Returns a NEW `Function`, leaving the input unmutated; fresh nodes are
/// arena-allocated. `sinks` names functions with a `@Composable`-typed lambda param.
pub fn transformComposableFunction(
    a: std.mem.Allocator,
    f: *const Function,
    oracle: ComposableOracle,
    oracle_ctx: *anyopaque,
    sinks: ?*const std.StringHashMap(void),
    in_class: bool,
    locals: ?*std.StringHashMap(void),
    enclosing_class: ?[]const u8,
) std.mem.Allocator.Error!Function {
    const b = B{ .a = a, .gen_span = f.span };
    // An unstable value parameter or receiver leaves the function restartable but NOT
    // skippable: no probes, no skip branch.
    const skippable = root.emit_skip_calculus and fnIsSkippable(f, in_class, enclosing_class);

    const pp = try buildParamsAndPrologue(a, b, f);
    const params = pp.params;

    const orig_stmts: []const Stmt = switch (f.body orelse return signatureOnly(f, params)) {
        .Block => |blk| blk.stmts,
        .Expr => |e| blk: {
            const s = try a.alloc(Stmt, 1);
            s[0] = .{ .Expr = e };
            break :blk s;
        },
    };

    var out: std.ArrayList(Stmt) = .empty;
    try out.append(a, .{ .Expr = b.callMember(
        b.pathExpr(composer_param),
        "startRestartGroup",
        b.slice1(b.intLit(positionalKey(f.span))),
    ) });
    // The defaults prologue walks too, so a composable call in a default is threaded.
    const lp = try a.create(std.StringHashMap(void));
    lp.* = try composableLambdaParamNames(a, f);
    const w_ret_composable = f.return_type != null and isComposableFnType(&f.return_type.?);
    var w = Walker{ .a = a, .b = b, .oracle = oracle, .oracle_ctx = oracle_ctx, .sinks = sinks, .lambda_params = lp, .locals = locals, .ret_composable = w_ret_composable, .ret_fn_params = if (w_ret_composable) @intCast(@min(f.return_type.?.function.?.params.len, 255)) else 0 };
    // Only non-defaulted, non-vararg params get a triple: a defaulted param's triple can
    // carry the default-taken same bit while the body sees a re-evaluated value.
    if (skippable) {
        const triples = try a.create(std.StringHashMap(u5));
        triples.* = std.StringHashMap(u5).init(a);
        for (f.params, 0..) |p, pi| {
            if (p.is_vararg or p.default != null) continue;
            // Index 9 is the shared overflow triple; only owned triples drive a memo condition.
            if (pi >= 9) continue;
            try triples.put(p.name.name, tripleIdx(pi));
        }
        w.param_triples = triples;
        w.dirty_in_scope = true;
    }
    for (pp.prologue) |*s| {
        try w.walkStmt(s);
        try out.append(a, s.*);
    }
    // Skip calculus: probe every value parameter through `$composer.changed(p)`, which also
    // stores the value. The body executes on a change, a forced scope, or a busy composer.
    if (skippable) {
        const dirty_prop = try a.create(ast.Property);
        dirty_prop.* = .{
            .mutable = true,
            .name = b.ident(dirty_local),
            .receiver_type = null,
            .ty = null,
            // Full copy, kotlinc's `$dirty = $changed`, so a guarded-off probe still has its
            // triple populated from the caller's certainty bits.
            .init = b.pathExpr(changed_param),
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
            .span = b.gen_span,
        };
        try out.append(a, .{ .Decl = .{ .Property = dirty_prop } });
        for (f.params, 0..) |p, pi| {
            const triple = tripleIdx(pi);
            if (p.is_vararg) {
                // A vararg packs a fresh array every call, so `changed(values.toList())` compares
                // structurally against the slot instead of by identity.
                try out.append(a, guardProbe(b, dirtyOrProbe(b, b.callMember(
                    b.pathExpr(composer_param),
                    "changed",
                    b.slice1(b.callMember(b.pathExpr(p.name.name), "toList", try a.alloc(Expr, 0))),
                ), triple), triple));
                continue;
            }
            const probe = dirtyOrProbe(b, b.callMember(
                b.pathExpr(composer_param),
                probeMethodFor(&p.ty, f.type_params),
                b.slice1(b.pathExpr(p.name.name)),
            ), triple);
            if (p.default != null and f.body != null) {
                const arg_name = try std.fmt.allocPrint(a, "{s}$arg", .{p.name.name});
                try out.append(a, guardProbe(b, dirtyProbeIfPassed(b, arg_name, probe, triple), triple));
            } else {
                try out.append(a, guardProbe(b, probe, triple));
            }
        }
        // The receiver's triple sits after the value params, kotlinc's slot order.
        if (f.receiver_type != null or in_class) {
            const recv_triple = tripleIdx(f.params.len);
            const recv_probe: []const u8 = if (f.receiver_type) |*rt|
                probeMethodFor(rt, f.type_params)
            else
                "changedInstance";
            try out.append(a, guardProbe(b, dirtyOrProbe(b, b.callMember(
                b.pathExpr(composer_param),
                recv_probe,
                b.slice1(.{ .This = .{ .qualifier = null, .span = b.gen_span } }),
            ), recv_triple), recv_triple));
        }
    }
    // `if ($composer.shouldExecute($dirty != 0 || !$composer.skipping, $dirty and 1))`:
    // the wrapper gives PausableComposition its pause points.
    var body_list: std.ArrayList(Stmt) = .empty;
    for (orig_stmts) |*s| {
        try w.walkStmt(@constCast(s));
        try body_list.append(a, s.*);
    }
    {
        var inj = EpilogueInjector{ .a = a, .b = b, .fn_name = f.name.name, .value_params = params[0..f.params.len] };
        try inj.stmts(body_list.items);
    }
    if (!root.emit_skip_calculus) {
        for (body_list.items) |s| try out.append(a, s);
        try out.append(a, .{ .Expr = try endRestartGroupExpr(a, b, f.name.name, params[0..f.params.len]) });
        const plain_body = Block{ .stmts = try out.toOwnedSlice(a), .span = f.span };
        return withBody(f, params, .{ .Block = plain_body });
    }
    const skip_stmts = try a.alloc(Stmt, 1);
    skip_stmts[0] = .{ .Expr = b.callMember(b.pathExpr(composer_param), "skipToGroupEnd", try a.alloc(Expr, 0)) };
    // Skippable gate: `($dirty and <forced+same bits>) != <all same> || !$composer.skipping`.
    // Non-skippable keeps the pause point but always executes (`true`).
    var gate_same: i64 = 0;
    if (skippable) {
        var seen_triples: u16 = 0;
        for (f.params, 0..) |_, pi| seen_triples |= @as(u16, 1) << @as(u4, @intCast(tripleIdx(pi)));
        if (f.receiver_type != null or in_class) seen_triples |= @as(u16, 1) << @as(u4, @intCast(tripleIdx(f.params.len)));
        var ti: u5 = 0;
        while (ti < 10) : (ti += 1) {
            if (seen_triples & (@as(u16, 1) << @as(u4, @intCast(ti))) != 0) gate_same += dirtySame(ti);
        }
    }
    const params_changed: Expr = if (skippable) .{ .Binary = .{
        .op = .Or,
        .lhs = b.box(.{ .Binary = .{
            .op = .Neq,
            .lhs = b.box(b.callMember(b.pathExpr(dirty_local), "and", b.slice1(b.intLit(gate_same + 1)))),
            .rhs = b.box(b.intLit(gate_same)),
            .span = b.gen_span,
        } }),
        .rhs = b.box(.{ .Unary = .{
            .op = .Not,
            .expr = b.box(b.member(b.pathExpr(composer_param), "skipping")),
            .span = b.gen_span,
        } }),
        .span = b.gen_span,
    } } else .{ .BoolLit = .{ .value = true, .span = b.gen_span } };
    const se_args = try a.alloc(Expr, 2);
    se_args[0] = params_changed;
    se_args[1] = b.callMember(b.pathExpr(if (skippable) dirty_local else changed_param), "and", b.slice1(b.intLit(1)));
    const run_cond = b.callMember(b.pathExpr(composer_param), "shouldExecute", se_args);
    try out.append(a, .{ .Expr = .{ .If = .{
        .cond = b.box(run_cond),
        .then_branch = b.box(.{ .Block = .{ .stmts = try body_list.toOwnedSlice(a), .span = f.span } }),
        .else_branch = b.box(.{ .Block = .{ .stmts = skip_stmts, .span = b.gen_span } }),
        .span = b.gen_span,
    } } });
    try out.append(a, .{ .Expr = try endRestartGroupExpr(a, b, f.name.name, params[0..f.params.len]) });

    const new_body = Block{ .stmts = try out.toOwnedSlice(a), .span = f.span };
    return withBody(f, params, .{ .Block = new_body });
}

/// Append `$composer`/`$changed` and thread the body with no restart bracket. The
/// body's original form is preserved so a value-returning composable keeps its result.
pub fn transformThreadedComposable(
    a: std.mem.Allocator,
    f: *const Function,
    oracle: ComposableOracle,
    oracle_ctx: *anyopaque,
    sinks: ?*const std.StringHashMap(void),
    locals: ?*std.StringHashMap(void),
) std.mem.Allocator.Error!Function {
    const b = B{ .a = a, .gen_span = f.span };
    const pp = try buildParamsAndPrologue(a, b, f);
    const params = pp.params;
    const lp = try a.create(std.StringHashMap(void));
    lp.* = try composableLambdaParamNames(a, f);
    const w_ret_composable = f.return_type != null and isComposableFnType(&f.return_type.?);
    var w = Walker{ .a = a, .b = b, .oracle = oracle, .oracle_ctx = oracle_ctx, .sinks = sinks, .lambda_params = lp, .locals = locals, .ret_composable = w_ret_composable, .ret_fn_params = if (w_ret_composable) @intCast(@min(f.return_type.?.function.?.params.len, 255)) else 0, .explicit_groups = isExplicitGroups(f) };
    const body = f.body orelse return signatureOnly(f, params);
    // A non-restartable composable still owns a replace group: repeated calls in a spliced
    // loop then reconcile as same-key siblings instead of splatting slots into the caller.
    const value_returning = (f.return_type != null and
        !std.mem.eql(u8, f.return_type.?.name.name, "Unit")) or
        (f.body != null and f.body.? == .Expr and f.return_type == null);
    // Engine slot primitives manage their own bracket: the memo wrap stores into the
    // CALLER's group by design, and `key`'s movable bracket is emitted at the call site.
    const grpwrap_excluded = std.mem.eql(u8, f.name.name, "rememberComposableLambda") or
        std.mem.eql(u8, f.name.name, "key");
    const wrap_group = value_returning and !f.is_inline and !isExplicitGroups(f) and
        !isReadOnlyComposable(f) and !grpwrap_excluded;
    if (wrap_group and root.dbg_groups) std.debug.print("[compose-pass] grpwrap {s}\n", .{f.name.name});
    const group_key = positionalKey(f.span);
    switch (body) {
        .Block => |blk| {
            const extra: usize = if (wrap_group) 2 else 0;
            const stmts = try a.alloc(Stmt, pp.prologue.len + blk.stmts.len + extra);
            const off: usize = if (wrap_group) 1 else 0;
            if (wrap_group) {
                stmts[0] = .{ .Expr = b.callMember(b.pathExpr(composer_param), "startReplaceGroup", b.slice1(b.intLit(group_key))) };
            }
            @memcpy(stmts[off .. off + pp.prologue.len], pp.prologue);
            @memcpy(stmts[off + pp.prologue.len .. off + pp.prologue.len + blk.stmts.len], blk.stmts);
            for (stmts[off .. off + pp.prologue.len + blk.stmts.len]) |*s| try w.walkStmt(s);
            if (wrap_group) {
                stmts[stmts.len - 1] = .{ .Expr = b.callMember(b.pathExpr(composer_param), "endReplaceGroup", try a.alloc(Expr, 0)) };
                var inj = EpilogueInjector{ .a = a, .b = b, .fn_name = f.name.name, .value_params = &.{}, .has_restart = false, .replace_depth = 1 };
                try inj.stmts(stmts[off .. off + pp.prologue.len + blk.stmts.len]);
            }
            return withBody(f, params, .{ .Block = .{ .stmts = stmts, .span = blk.span } });
        },
        .Expr => |e| {
            var ne = e;
            try w.walkExpr(&ne);
            if (!wrap_group) {
                if (pp.prologue.len == 0) return withBody(f, params, .{ .Expr = ne });
                const stmts = try a.alloc(Stmt, pp.prologue.len + 1);
                @memcpy(stmts[0..pp.prologue.len], pp.prologue);
                for (stmts[0..pp.prologue.len]) |*s| try w.walkStmt(s);
                stmts[pp.prologue.len] = .{ .Expr = .{ .Return = .{
                    .value = b.box(ne),
                    .label = null,
                    .span = b.gen_span,
                } } };
                return withBody(f, params, .{ .Block = .{ .stmts = stmts, .span = f.span } });
            }
            // `{ start; <prologue>; val $grp$v = <expr>; end; return $grp$v }`
            const result_name = try std.fmt.allocPrint(a, "$grp$v{x}", .{@as(u64, @bitCast(group_key))});
            const result_prop = try a.create(ast.Property);
            result_prop.* = .{
                .mutable = false,
                .name = b.ident(result_name),
                .receiver_type = null,
                .ty = null,
                .init = ne,
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
                .span = b.gen_span,
            };
            const stmts = try a.alloc(Stmt, pp.prologue.len + 4);
            stmts[0] = .{ .Expr = b.callMember(b.pathExpr(composer_param), "startReplaceGroup", b.slice1(b.intLit(group_key))) };
            @memcpy(stmts[1 .. 1 + pp.prologue.len], pp.prologue);
            for (stmts[1 .. 1 + pp.prologue.len]) |*s| try w.walkStmt(s);
            stmts[1 + pp.prologue.len] = .{ .Decl = .{ .Property = result_prop } };
            stmts[2 + pp.prologue.len] = .{ .Expr = b.callMember(b.pathExpr(composer_param), "endReplaceGroup", try a.alloc(Expr, 0)) };
            stmts[3 + pp.prologue.len] = .{ .Expr = .{ .Return = .{
                .value = b.box(b.pathExpr(result_name)),
                .label = null,
                .span = b.gen_span,
            } } };
            return withBody(f, params, .{ .Block = .{ .stmts = stmts, .span = f.span } });
        },
    }
}

fn isReadOnlyComposable(f: *const Function) bool {
    for (f.annotations) |ann| {
        if (ann.path.len == 0) continue;
        if (std.mem.eql(u8, ann.path[ann.path.len - 1].name, "ReadOnlyComposable")) return true;
    }
    return false;
}
