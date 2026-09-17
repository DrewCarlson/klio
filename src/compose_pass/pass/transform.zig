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
const defaults_local = root.defaults_local;
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
                const ret_composable = f.return_type != null and isComposableFnType(f.return_type.?);
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
                        try w.transformComposableLambda(e.Lambda, ret_fn_params, null);
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
            if (p.init) |ini| try w.walkExpr(ini);
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

/// The absent-argument bit parameter `i` owns. `$dirty`/`$changed` spend three bits per
/// probed slot starting at bit 1, of which only the lower two carry the skip calculus;
/// the third is free and travels through `updateChangedFlags` untouched, so a restart
/// can tell the body which slots the original caller never supplied. Ten slots fit.
pub fn defaultBit(i: usize) i64 {
    return @as(i64, 8) << (3 * @as(u6, @intCast(i)));
}

/// The widest parameter index the absent-argument mask reaches.
pub const max_default_slot: usize = 9;

/// Whether re-evaluating this default on a later composition yields the same value a
/// restart would have carried in. A literal, a `null` or a plain name does; anything
/// that calls, allocates or reads through a receiver may not, and only those need the
/// defaults group — which costs a slot-table group on every composition that runs it.
fn defaultRecomputesEqual(e: *const Expr) bool {
    return switch (e.*) {
        .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit, .Path => true,
        .StringTemplate => |t| blk: {
            for (t.parts) |part| {
                if (part != .Text) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// `$defaults and <bit> != 0`: whether the caller left parameter `i` to its default.
fn defaultTaken(b: B, bit: i64) Expr {
    return .{ .Binary = .{
        .op = .Neq,
        .lhs = b.box(b.callMember(b.pathExpr(defaults_local), "and", b.slice1(b.intLit(bit)))),
        .rhs = b.box(b.intLit(0)),
        .span = b.gen_span,
    } };
}

/// A defaulted slot never reaches `composer.changed`: the caller stored nothing for an
/// argument it did not pass, so the triple reads certain-same and the probe is the
/// branch taken only when a value did arrive. `taken` is the test for "took its default":
/// the mask when the function carries one, the marker the argument still holds otherwise.
fn defaultedProbe(b: B, taken: Expr, guarded: Stmt, triple: u5) Stmt {
    const then_stmts = b.a.alloc(Stmt, 1) catch @panic("oom");
    then_stmts[0] = dirtyOrConst(b, dirtySame(triple));
    const else_stmts = b.a.alloc(Stmt, 1) catch @panic("oom");
    else_stmts[0] = guarded;
    return .{ .Expr = .{ .If = .{
        .cond = b.box(taken),
        .then_branch = b.box(.{ .Block = .{ .stmts = then_stmts, .span = b.gen_span } }),
        .else_branch = b.box(.{ .Block = .{ .stmts = else_stmts, .span = b.gen_span } }),
        .span = b.gen_span,
    } } };
}

/// `p$arg === marker()`: the test a function past the mask's reach uses instead. Its
/// restart hands `p$arg` straight back, so both compositions read the same branch.
fn markerTaken(b: B, arg_name: []const u8) Expr {
    return .{ .Binary = .{
        .op = .IdentEq,
        .lhs = b.box(b.pathExpr(arg_name)),
        .rhs = b.box(markerCall(b)),
        .span = b.gen_span,
    } };
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
    return .{ .Assign = ast.box(b.a, ast.AssignStmt{
        .target = b.pathExpr(dirty_local),
        .op = .Assign,
        .value = b.callMember(b.pathExpr(dirty_local), "or", b.slice1(b.intLit(v))),
        .span = b.gen_span,
    }) catch @panic("oom") };
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
    return .{ .Assign = ast.box(b.a, ast.AssignStmt{
        .target = b.pathExpr(dirty_local),
        .op = .Assign,
        .value = b.callMember(b.pathExpr(dirty_local), "or", b.slice1(pick)),
        .span = b.gen_span,
    }) catch @panic("oom") };
}

/// Every original param keeps its slot; a defaulted `p: T = D` is renamed `p$arg` with
/// the marker as its default. A restartable function binds `var p = p$arg` and resolves
/// the default inside a `startDefaults` group a restart jumps over; everything else
/// resolves it once, inline. The threaded pair is unchanged: the absent-argument mask
/// rides in the free bit of each slot's `$changed` triple.
const ParamsAndPrologue = struct {
    params: []Param,
    prologue: []Stmt,
    /// `startDefaults() … endDefaults()`, the head of a restartable body's execute
    /// branch. Empty when no parameter has a default.
    defaults: []Stmt = &.{},
};

fn composableLambdaParamNames(a: std.mem.Allocator, f: *const Function) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    for (f.params) |*p| {
        if (isComposableLambdaParam(p)) try set.put(p.name.name, {});
    }
    return set;
}

fn localProp(
    a: std.mem.Allocator,
    b: B,
    mutable: bool,
    name: ast.Ident,
    ty: ?ast.TypeRef,
    init: Expr,
) std.mem.Allocator.Error!Stmt {
    const prop = try a.create(ast.Property);
    prop.* = .{
        .mutable = mutable,
        .name = name,
        .receiver_type = null,
        .ty = if (ty) |t| try ast.box(a, t) else null,
        .init = try ast.box(a, init),
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
    return .{ .Decl = try ast.box(a, ast.Decl{ .Property = prop }) };
}

fn assignStmt(a: std.mem.Allocator, b: B, target: Expr, value: Expr) std.mem.Allocator.Error!Stmt {
    return .{ .Assign = try ast.box(a, ast.AssignStmt{
        .target = target,
        .op = .Assign,
        .value = value,
        .span = b.gen_span,
    }) };
}

fn buildParamsAndPrologue(
    a: std.mem.Allocator,
    b: B,
    f: *const Function,
    restartable: bool,
    skippable: bool,
) std.mem.Allocator.Error!ParamsAndPrologue {
    var n_defaulted: usize = 0;
    var widest_default: usize = 0;
    var any_recomputes_different = false;
    if (f.body != null) {
        for (f.params, 0..) |p, i| {
            const d = p.default orelse continue;
            n_defaulted += 1;
            widest_default = i;
            if (!defaultRecomputesEqual(d)) any_recomputes_different = true;
        }
    }
    // A restart re-enters with the values the scope captured, and a default is computed
    // once for the life of the group: that needs both a group the restart jumps over and
    // a mask saying which slots the original caller never supplied. Where every default
    // recomputes to the same value, or past the mask's reach, the one-shot prologue
    // stands: it re-evaluates, but never misreads a slot.
    const group = restartable and any_recomputes_different and widest_default <= max_default_slot;
    var params = try a.alloc(Param, f.params.len + 2);
    var prologue: std.ArrayList(Stmt) = .empty;
    var resolves: std.ArrayList(Stmt) = .empty;
    // `$changed and <all flags>`: a restart hands the mask back in the bits it owns.
    var mask: ?Expr = null;
    var all_flags: i64 = 0;
    var keep_mask: i64 = 0x7fffffff;
    for (f.params, 0..) |p, i| {
        params[i] = p;
        if (p.default == null or f.body == null) continue;
        const argname = try std.fmt.allocPrint(a, "{s}$arg", .{p.name.name});
        params[i].name = b.ident(argname);
        params[i].default = b.box(markerCall(b));
        const absent = Expr{ .Binary = .{
            .op = .IdentEq,
            .lhs = b.box(b.pathExpr(argname)),
            .rhs = b.box(markerCall(b)),
            .span = b.gen_span,
        } };
        if (!group) {
            try prologue.append(a, try localProp(a, b, false, p.name, p.ty, .{ .If = .{
                .cond = b.box(absent),
                .then_branch = p.default.?,
                .else_branch = b.box(b.pathExpr(argname)),
                .span = b.gen_span,
            } }));
            continue;
        }
        const bit = defaultBit(i);
        all_flags |= bit;
        // `var p: T = p$arg` holds the marker until the defaults group resolves it, the
        // value a caller passed, or — on a restart — the value the scope captured.
        try prologue.append(a, try localProp(a, b, true, p.name, p.ty, b.pathExpr(argname)));
        const term = Expr{ .If = .{
            .cond = b.box(absent),
            .then_branch = b.box(b.intLit(bit)),
            .else_branch = b.box(b.intLit(0)),
            .span = b.gen_span,
        } };
        mask = if (mask) |m| b.callMember(m, "or", b.slice1(term)) else term;
        // An if EXPRESSION, not a statement: a statement would invite the walker's
        // branch bracket inside the defaults group the skip path jumps over.
        try resolves.append(a, try assignStmt(a, b, b.pathExpr(p.name.name), .{ .If = .{
            .cond = b.box(defaultTaken(b, bit)),
            .then_branch = p.default.?,
            .else_branch = b.box(b.pathExpr(p.name.name)),
            .span = b.gen_span,
        } }));
        keep_mask &= ~(@as(i64, 6) << (3 * @as(u6, tripleIdx(i))));
    }
    params[f.params.len] = b.param(composer_param, b.typeRef("Composer"));
    params[f.params.len + 1] = b.param(changed_param, b.typeRef("Int"));
    if (!group) return .{ .params = params, .prologue = try prologue.toOwnedSlice(a) };

    const carried = b.callMember(b.pathExpr(changed_param), "and", b.slice1(b.intLit(all_flags)));
    try prologue.append(a, try localProp(a, b, false, b.ident(defaults_local), null, b.callMember(
        carried,
        "or",
        b.slice1(mask.?),
    )));

    // `$changed and 1 == 0 || $composer.defaultsInvalid`: bit 0 is set only by a restart,
    // so an ordinary call evaluates the defaults and a restart reuses what the scope
    // captured, unless a state read inside a default changed.
    const cond = Expr{ .Binary = .{
        .op = .Or,
        .lhs = b.box(.{ .Binary = .{
            .op = .Eq,
            .lhs = b.box(b.callMember(b.pathExpr(changed_param), "and", b.slice1(b.intLit(1)))),
            .rhs = b.box(b.intLit(0)),
            .span = b.gen_span,
        } }),
        .rhs = b.box(b.member(b.pathExpr(composer_param), "defaultsInvalid")),
        .span = b.gen_span,
    } };
    var skip: std.ArrayList(Stmt) = .empty;
    try skip.append(a, .{ .Expr = b.callMember(b.pathExpr(composer_param), "skipToGroupEnd", try a.alloc(Expr, 0)) });
    if (skippable) {
        // Values carried in from the scope, never re-established here: their triples read
        // unknown so a child cannot skip on a certainty this call did not make.
        try skip.append(a, try assignStmt(a, b, b.pathExpr(dirty_local), b.callMember(
            b.pathExpr(dirty_local),
            "and",
            b.slice1(b.intLit(keep_mask)),
        )));
    }
    const defaults = try a.alloc(Stmt, 3);
    defaults[0] = .{ .Expr = b.callMember(b.pathExpr(composer_param), "startDefaults", try a.alloc(Expr, 0)) };
    defaults[1] = .{ .Expr = .{ .If = .{
        .cond = b.box(cond),
        .then_branch = b.box(.{ .Block = .{ .stmts = try resolves.toOwnedSlice(a), .span = b.gen_span } }),
        .else_branch = b.box(.{ .Block = .{ .stmts = try skip.toOwnedSlice(a), .span = b.gen_span } }),
        .span = b.gen_span,
    } } };
    defaults[2] = .{ .Expr = b.callMember(b.pathExpr(composer_param), "endDefaults", try a.alloc(Expr, 0)) };
    return .{ .params = params, .prologue = try prologue.toOwnedSlice(a), .defaults = defaults };
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

    const pp = try buildParamsAndPrologue(a, b, f, true, skippable);
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
    const w_ret_composable = f.return_type != null and isComposableFnType(f.return_type.?);
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
    // The defaults group brackets itself, so the walker adds no branch groups of its own:
    // the skip path jumps straight to `endDefaults` and must find nothing else opened.
    if (pp.defaults.len != 0) {
        const saved_groups = w.explicit_groups;
        w.explicit_groups = true;
        for (pp.defaults) |*s| try w.walkStmt(s);
        w.explicit_groups = saved_groups;
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
            .init = b.box(b.pathExpr(changed_param)),
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
        try out.append(a, .{ .Decl = try ast.box(a, ast.Decl{ .Property = dirty_prop }) });
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
                const taken = if (pp.defaults.len != 0)
                    defaultTaken(b, defaultBit(pi))
                else
                    markerTaken(b, try std.fmt.allocPrint(a, "{s}$arg", .{p.name.name}));
                try out.append(a, defaultedProbe(b, taken, guardProbe(b, probe, triple), triple));
            } else {
                try out.append(a, guardProbe(b, probe, triple));
            }
        }
        // The receiver's triple sits after the value params, kotlinc's slot order.
        if (f.receiver_type != null or in_class) {
            const recv_triple = tripleIdx(f.params.len);
            const recv_probe: []const u8 = if (f.receiver_type) |rt|
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
    for (pp.defaults) |s| try body_list.append(a, s);
    for (orig_stmts) |*s| {
        try w.walkStmt(@constCast(s));
        try body_list.append(a, s.*);
    }
    {
        var inj = EpilogueInjector{ .a = a, .b = b, .fn_name = f.name.name, .value_params = params[0..f.params.len], .has_defaults = pp.defaults.len != 0 };
        try inj.stmts(body_list.items);
    }
    if (!root.emit_skip_calculus) {
        for (body_list.items) |s| try out.append(a, s);
        try out.append(a, .{ .Expr = try endRestartGroupExpr(a, b, f.name.name, params[0..f.params.len], pp.defaults.len != 0) });
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
    try out.append(a, .{ .Expr = try endRestartGroupExpr(a, b, f.name.name, params[0..f.params.len], pp.defaults.len != 0) });

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
    const pp = try buildParamsAndPrologue(a, b, f, false, false);
    const params = pp.params;
    const lp = try a.create(std.StringHashMap(void));
    lp.* = try composableLambdaParamNames(a, f);
    const w_ret_composable = f.return_type != null and isComposableFnType(f.return_type.?);
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
                .init = b.box(ne),
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
            stmts[1 + pp.prologue.len] = .{ .Decl = try ast.box(a, ast.Decl{ .Property = result_prop }) };
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
