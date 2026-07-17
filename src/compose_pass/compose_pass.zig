//! Compose compiler-plugin-equivalent lowering pass (Phase 1).
//!
//! A pluggable AST-to-AST transform that rewrites `@Composable` functions the
//! way androidx's Compose compiler plugin does, so that upstream's real
//! `Composer` / `SlotTable` / `Recomposer` can run unchanged. This module is
//! deliberately self-contained (depends only on `ast` + `span`) so the core
//! lowerer stays oblivious — the transform is registered as a pass, not baked
//! into `src/ir/lower`.
//!
//! Phase 1 emits the restartable-group skeleton without `$changed`-based
//! skipping (that is Phase 2). A `@Composable fun App(x: Int) { Body }`:
//!
//!     fun App(x: Int, $composer: Composer, $changed: Int) {
//!         $composer.startRestartGroup(<key>)
//!         Body                                     // @Composable calls threaded
//!         $composer.endRestartGroup()?.updateScope { c, f -> App(x, c, $changed or 1) }
//!     }
//!
//! Each `@Composable` call in the body gains two trailing arguments — the
//! threaded `$composer` and a child `$changed` (0 in Phase 1). Positional group
//! keys are derived from the call's source span (stable per call site), the same
//! role the plugin's compile-time key constant plays.
//!
//! See plans/compose-plugin-lowering.md.

const std = @import("std");
const ast = @import("ast");
const span_mod = @import("span");

const Span = span_mod.Span;
const Ident = ast.Ident;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Param = ast.Param;
const TypeRef = ast.TypeRef;
const Function = ast.Function;
const Block = ast.Block;
const FunctionBody = ast.FunctionBody;
const Decl = ast.Decl;

const dbg_lambda = false;

/// Composable-lambda memoization emission (KLIO_COMPOSE_MEMO=0 disables,
/// an A/B bisection switch like KLIO_COMPOSE_SKIP). ON by default: kotlinc
/// always wraps composable lambda arguments in remembered
/// `composableLambda` instances — without it an unchanged content lambda
/// is a fresh closure every recomposition, `composer.changed(content)` is
/// always true, and a forced recomposition of unchanged content reports
/// spurious changes (the expectNoChanges family).
pub var emit_lambda_memo: bool = true;

/// Group-emission debug (set by the build driver from KLIO_COMPOSE_DBG).
pub var dbg_groups: bool = false;

/// Synthetic name of the injected composer parameter.
pub const composer_param = "$composer";
/// Synthetic name of the injected changed-flags parameter.
pub const changed_param = "$changed";
/// The skip-calculus accumulator local (`var $dirty = $changed and 1`).
pub const dirty_local = "$dirty";
/// Whether restartable composables emit the skip calculus (probes + skip
/// branch). The integration point sets this from `KLIO_COMPOSE_SKIP=0` so a
/// pace or correctness question can A/B the emission without a rebuild; the
/// pass itself stays free of environment access (ast+span only).
pub var emit_skip_calculus: bool = true;
/// FQN of the absent-argument marker singleton accessor (declared in the
/// compose runtime engine pack). A defaulted `@Composable` parameter's default
/// expression must evaluate INSIDE the function body — with `$composer` in
/// scope — exactly as the upstream plugin's `$default`-mask rewrite does
/// (`fun Test(n: Int = LocalNumber.current)` reads a CompositionLocal). The
/// pass replaces the declared default with `klioComposableDefaultMarker()`
/// (cheap, needs no composition) and prologues the body with
/// `val n = if (n$arg === klioComposableDefaultMarker()) <default> else n$arg`.
const default_marker_path = [_][]const u8{ "androidx", "compose", "runtime", "klioComposableDefaultMarker" };
/// FQN of the ambient-composer host intrinsic (klioMain HostIntrinsics.kt,
/// served by src/interp_ir/vm/compose.zig). A `@Composable` property GETTER
/// has no `$composer` parameter to thread — upstream compiles `currentComposer`
/// there as an intrinsic — so an ambient-mode walk substitutes reads (and the
/// composer argument of threaded calls) with this call; the interpreter keeps
/// the stack populated around every transformed-composable invocation.
const ambient_composer_path = [_][]const u8{ "androidx", "compose", "runtime", "__compose_currentComposer" };

/// `androidx.compose.runtime.internal.composableLambda(composer, key, tracked,
/// block)` — the remembered composable-lambda wrapper kotlinc emits around
/// every composable lambda argument, so an unchanged content lambda compares
/// EQUAL across recompositions and its group skips.
const composable_lambda_path = [_][]const u8{ "androidx", "compose", "runtime", "internal", "composableLambda" };

/// Whether a declaration's annotations include `@Composable`. Matches both the
/// bare `Composable` and any dotted path ending in `Composable`.
pub fn isComposable(annotations: []const ast.Annotation) bool {
    for (annotations) |a| {
        if (a.path.len == 0) continue;
        if (std.mem.eql(u8, a.path[a.path.len - 1].name, "Composable")) return true;
    }
    return false;
}

/// A `@Composable` function that owns its OWN restart scope: the plugin brackets
/// it with `startRestartGroup`/`endRestartGroup()?.updateScope`. Excluded:
///   - `inline` composables — the compiler inlines them into the caller's group,
///     so they emit no separate scope;
///   - `@NonRestartableComposable` / `@ReadOnlyComposable` / `@ExplicitGroupsComposable`
///     — the compiler emits no restart group; they recompose as part of their caller.
/// Bracketing these (as the plugin did for every `@Composable`) creates spurious
/// nested restart scopes: `setContent { Text(…) }` gained 3 nested scopes instead
/// of 1, the state read attributed to the wrong (innermost) scope, and the outer
/// scopes were left with null restart blocks — so recomposition threw
/// "Invalid restart scope" / recorded no change. These still get the threaded
/// `$composer`/`$changed` parameters, just no restart bracket.
fn isRestartableComposable(f: *const Function) bool {
    if (!isComposable(f.annotations)) return false;
    if (f.is_inline) return false;
    // A restart scope returns Unit. A declared non-Unit return type — or an
    // expression body with no declared type, whose value IS the body — is a
    // value-returning composable (`collectAsState`, `rememberUpdatedState`):
    // threaded, never restart-wrapped, or the wrap collapses its value to
    // Unit.
    if (f.return_type) |rt| {
        if (!std.mem.eql(u8, rt.name.name, "Unit")) return false;
    } else if (f.body != null and f.body.? == .Expr) {
        return false;
    }
    for (f.annotations) |ann| {
        if (ann.path.len == 0) continue;
        const nm = ann.path[ann.path.len - 1].name;
        if (std.mem.eql(u8, nm, "NonRestartableComposable")) return false;
        if (std.mem.eql(u8, nm, "ReadOnlyComposable")) return false;
        if (std.mem.eql(u8, nm, "ExplicitGroupsComposable")) return false;
    }
    return true;
}

/// A stable positional group key for a call site, derived from its span. The
/// Compose plugin emits a compile-time constant here; a span hash plays the
/// same role — identical across recompositions, distinct per source location.
pub fn positionalKey(sp: Span) i64 {
    var h: u64 = 0xcbf29ce484222325;
    inline for (.{ @as(u64, sp.file.int()), @as(u64, sp.start), @as(u64, sp.end) }) |v| {
        h ^= v;
        h *%= 0x100000001b3;
    }
    // Fold to a signed 32-bit key (the ABI key type is `Int`).
    return @as(i64, @as(i32, @truncate(@as(i64, @bitCast(h)))));
}

// --------------------------------------------------------------------------
// Small AST builders (arena-allocated). Generated nodes carry `gen_span`.
// --------------------------------------------------------------------------

const B = struct {
    a: std.mem.Allocator,
    gen_span: Span,

    fn ident(self: B, name: []const u8) Ident {
        return .{ .name = name, .span = self.gen_span };
    }

    fn box(self: B, e: Expr) *Expr {
        const p = self.a.create(Expr) catch @panic("oom");
        p.* = e;
        return p;
    }

    /// `name` as a single-segment path expression.
    fn pathExpr(self: B, name: []const u8) Expr {
        const segs = self.a.alloc(Ident, 1) catch @panic("oom");
        segs[0] = self.ident(name);
        return .{ .Path = .{ .segments = segs, .span = self.gen_span } };
    }

    /// `a.b.c` as a multi-segment path expression.
    fn pathExprSegs(self: B, names: []const []const u8) Expr {
        const segs = self.a.alloc(Ident, names.len) catch @panic("oom");
        for (names, segs) |nm, *s| s.* = self.ident(nm);
        return .{ .Path = .{ .segments = segs, .span = self.gen_span } };
    }

    fn intLit(self: B, v: i64) Expr {
        return .{ .IntLit = .{ .value = v, .kind = .Int, .span = self.gen_span } };
    }

    /// `receiver.name`.
    fn member(self: B, receiver: Expr, name: []const u8) Expr {
        return .{ .Member = .{
            .receiver = self.box(receiver),
            .name = self.ident(name),
            .safe = false,
            .span = self.gen_span,
        } };
    }

    /// `receiver.name(args)` (positional args, no trailing lambda).
    fn callMember(self: B, receiver: Expr, name: []const u8, args: []Expr) Expr {
        return self.call(self.member(receiver, name), args);
    }

    /// `callee(args)` with all-positional args.
    fn call(self: B, callee: Expr, args: []Expr) Expr {
        const names = self.a.alloc(?[]const u8, args.len) catch @panic("oom");
        for (names) |*n| n.* = null;
        return .{ .Call = .{
            .callee = self.box(callee),
            .args = args,
            .arg_names = names,
            .type_args = &.{},
            .is_infix = false,
            .has_trailing_lambda = false,
            .span = self.gen_span,
        } };
    }

    fn slice1(self: B, e: Expr) []Expr {
        const s = self.a.alloc(Expr, 1) catch @panic("oom");
        s[0] = e;
        return s;
    }

    /// A named user type reference (`Composer`, `Int`) with no generics.
    fn typeRef(self: B, name: []const u8) TypeRef {
        return .{
            .name = self.ident(name),
            .nullable = false,
            .span = self.gen_span,
            .type_args = &.{},
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        };
    }

    fn param(self: B, name: []const u8, ty: TypeRef) Param {
        return .{
            .name = self.ident(name),
            .ty = ty,
            .default = null,
            .is_vararg = false,
            .is_crossinline = false,
            .is_noinline = false,
            .annotations = &.{},
            .span = self.gen_span,
        };
    }
};

/// Callback deciding whether a call whose callee is the given simple name binds
/// a `@Composable` function (and so must be threaded the composer). Real
/// integration supplies this from resolution; unit tests supply a fixed set.
pub const ComposableOracle = *const fn (ctx: *anyopaque, callee_name: []const u8) bool;

/// A name-set oracle: a call is composable when its callee's simple name is a
/// declared `@Composable` function. This is the integration oracle (the plugin
/// resolves precisely by symbol; a simple-name set covers the compose API, whose
/// composable functions are consistently named — `Text`, `Column`, `Linear`).
pub const NameSetOracle = struct {
    names: *const std.StringHashMap(void),

    fn isComposableCall(ctx: *anyopaque, callee_name: []const u8) bool {
        const self: *const NameSetOracle = @ptrCast(@alignCast(ctx));
        return self.names.contains(callee_name);
    }
};

/// Collect the simple names of every `@Composable` function declared across a
/// decl slice (top level + class/object members). The result feeds the
/// integration oracle. Caller owns the returned map.
pub fn collectComposableNames(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    try collectInto(&set, decls);
    return set;
}

fn collectInto(set: *std.StringHashMap(void), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            if (isComposable(f.annotations)) try set.put(f.name.name, {});
        },
        .Class => |*c| try collectInto(set, c.members),
        .Object => |*o| try collectInto(set, o.members),
        else => {},
    };
}

/// Whether a parameter's type is a `@Composable`-annotated function type — a
/// sink a lambda argument is transformed for.
fn isComposableLambdaParam(p: *const Param) bool {
    return p.ty.function != null and isComposable(p.ty.annotations);
}

/// A declared type that is a `@Composable`-annotated function type
/// (`@Composable () -> Unit`) — a lambda bound to it composes.
fn isComposableFnType(t: *const ast.TypeRef) bool {
    return t.function != null and isComposable(t.annotations);
}

/// Names of functions returning a `@Composable` function type, installed by
/// the build driver around `transformDecls` (module decls + baked base). A
/// val initialized from one holds a composable lambda; the walker records
/// the val's name in its scoped `locals` set so bare calls thread.
pub var active_factories: ?*const std.StringHashMap(void) = null;

/// Declared parameter count of a sink's `@Composable` lambda parameter,
/// recorded only when NON-ZERO (module decls + baked base, installed around
/// `transformDecls`). A header-less `{ … }` bound to a `@Composable (P) ->
/// Unit` sink keeps its implicit `it` slot ahead of `$composer`/`$changed` —
/// `MovableContent({ content() })` invokes its content with the movable
/// parameter first.
pub var active_sink_arity: ?*const std.StringHashMap(u8) = null;

/// Per-sink bitmask of the TOTAL param counts of overloads whose LAST param
/// is the composable lambda (bit n set = an n-param overload exists). A
/// name-keyed sink cannot distinguish `ComposeNode(factory, update)` from
/// `ComposeNode(factory, update, content)`; without this the 2-arg call's
/// trailing UPDATE lambda was transformed (and under the memo emission,
/// wrapped) as composable.
pub var active_sink_argcounts: ?*const std.StringHashMap(u64) = null;

/// Collect `sink name -> arg-count bitmask` (see active_sink_argcounts).
pub fn collectComposableSinkArgCounts(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(u64) {
    var set = std.StringHashMap(u64).init(a);
    try collectSinkArgCountsInto(&set, decls);
    return set;
}

fn noteSinkArgCount(set: *std.StringHashMap(u64), name: []const u8, n_params: usize) std.mem.Allocator.Error!void {
    if (n_params >= 64) return;
    const gop = try set.getOrPut(name);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* |= @as(u64, 1) << @intCast(n_params);
}

fn collectSinkArgCountsInto(set: *std.StringHashMap(u64), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            if (f.params.len != 0 and isComposableLambdaParam(&f.params[f.params.len - 1])) {
                // Defaulted middle params permit shorter calls: every count
                // from the required minimum up to the full list matches.
                var required: usize = 0;
                for (f.params) |*p| {
                    if (p.default == null) required += 1;
                }
                var n = required;
                if (n == 0) n = 1;
                while (n <= f.params.len) : (n += 1) try noteSinkArgCount(set, f.name.name, n);
            }
        },
        .Class => |*c| {
            if (c.primary_params.len != 0) {
                const lp = &c.primary_params[c.primary_params.len - 1];
                if (lp.ty.function != null and isComposable(lp.ty.annotations)) {
                    try noteSinkArgCount(set, c.name.name, c.primary_params.len);
                }
            }
            try collectSinkArgCountsInto(set, c.members);
        },
        .Object => |*o| try collectSinkArgCountsInto(set, o.members),
        else => {},
    };
}

/// Names of class PROPERTIES declared with a `@Composable` function type
/// (`MovableContent.content`). An explicit-receiver invoke of one
/// (`content.content(parameter)` in the composer's movable-content path) is
/// a composable call and threads the pair. Consulted only for `.Member`
/// callees, so a same-named bare call cannot be captured.
pub var active_composable_props: ?*const std.StringHashMap(void) = null;

/// Collect `@Composable`-fn-typed property names (constructor vals and body
/// properties) across the decls. Caller owns the map.
pub fn collectComposableProps(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    try collectComposablePropsInto(&set, decls);
    return set;
}

fn collectComposablePropsInto(set: *std.StringHashMap(void), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Property => |p| {
            if (p.ty != null and isComposableFnType(&p.ty.?)) try set.put(p.name.name, {});
        },
        .Class => |*c| {
            for (c.primary_params) |*p| {
                if (p.property != null and p.ty.function != null and isComposable(p.ty.annotations)) {
                    try set.put(p.name.name, {});
                }
            }
            try collectComposablePropsInto(set, c.members);
        },
        .Object => |*o| try collectComposablePropsInto(set, o.members),
        else => {},
    };
}

/// Collect `sink name -> composable-lambda param count` for sinks whose
/// composable parameter declares at least one value parameter. Caller owns.
pub fn collectComposableSinkArity(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(u8) {
    var set = std.StringHashMap(u8).init(a);
    try collectSinkArityInto(&set, decls);
    return set;
}

fn compParamArity(t: *const ast.TypeRef) ?u8 {
    if (t.function == null or !isComposable(t.annotations)) return null;
    const n = t.function.?.params.len;
    if (n == 0) return null;
    return @intCast(@min(n, 255));
}

fn collectSinkArityInto(set: *std.StringHashMap(u8), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            for (f.params) |*p| if (compParamArity(&p.ty)) |n| {
                try set.put(f.name.name, n);
                break;
            };
        },
        .Class => |*c| {
            for (c.primary_params) |*p| if (compParamArity(&p.ty)) |n| {
                try set.put(c.name.name, n);
                break;
            };
            try collectSinkArityInto(set, c.members);
        },
        .Object => |*o| try collectSinkArityInto(set, o.members),
        else => {},
    };
}

/// Collect the simple names of functions RETURNING a `@Composable` function
/// type (`movableContentOf`): a val initialized from one holds a composable
/// lambda, so a bare call through the val is threaded. Caller owns the map.
pub fn collectComposableValFactories(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    try collectFactoriesInto(&set, decls);
    return set;
}

fn collectFactoriesInto(set: *std.StringHashMap(void), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            if (f.return_type != null and isComposableFnType(&f.return_type.?)) {
                try set.put(f.name.name, {});
            }
        },
        .Class => |*c| try collectFactoriesInto(set, c.members),
        .Object => |*o| try collectFactoriesInto(set, o.members),
        else => {},
    };
}

/// Collect the simple names of functions (and constructors) that declare a
/// `@Composable`-typed lambda parameter, so a lambda bound to one is itself
/// transformed. Caller owns the returned map.
pub fn collectComposableLambdaSinks(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    try collectSinksInto(&set, decls);
    return set;
}

fn collectSinksInto(set: *std.StringHashMap(void), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            for (f.params) |*p| if (isComposableLambdaParam(p)) {
                try set.put(f.name.name, {});
                break;
            };
        },
        .Class => |*c| {
            // A class whose PRIMARY constructor takes a `@Composable`-typed
            // lambda is a sink under its own name: `MovableContent({ … })`
            // transforms its content lambda exactly like a function call
            // would.
            for (c.primary_params) |*p| {
                if (p.ty.function != null and isComposable(p.ty.annotations)) {
                    try set.put(c.name.name, {});
                    break;
                }
            }
            try collectSinksInto(set, c.members);
        },
        .Object => |*o| try collectSinksInto(set, o.members),
        else => {},
    };
}

/// Transform every `@Composable` top-level function in `decls` in place,
/// threading the composer per the plugin ABI. `composable_names` is the oracle
/// set (built with `collectComposableNames`, optionally extended with names from
/// a baked base). Class/object members and composable lambdas are handled by a
/// later phase.
pub fn transformDecls(
    a: std.mem.Allocator,
    decls: []ast.Decl,
    composable_names: *const std.StringHashMap(void),
    lambda_sinks: *const std.StringHashMap(void),
) std.mem.Allocator.Error!void {
    var oracle = NameSetOracle{ .names = composable_names };
    for (decls) |*d| try transformDecl(a, d, &oracle, lambda_sinks, false);
}

fn transformDecl(
    a: std.mem.Allocator,
    d: *ast.Decl,
    oracle: *NameSetOracle,
    sinks: *const std.StringHashMap(void),
    in_class: bool,
) std.mem.Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| {
            if (f.body == null) return;
            if (isComposable(f.annotations)) {
                if (isRestartableComposable(f)) {
                    f.* = try transformComposableFunction(a, f, NameSetOracle.isComposableCall, oracle, sinks, in_class, null);
                } else {
                    f.* = try transformThreadedComposable(a, f, NameSetOracle.isComposableCall, oracle, sinks, null);
                }
            } else {
                // Not composable: still walk the body so a `compose { … }` /
                // `setContent { … }` composable-lambda argument is transformed.
                const ret_composable = f.return_type != null and isComposableFnType(&f.return_type.?);
                const ret_fn_params: u8 = if (ret_composable) @intCast(@min(f.return_type.?.function.?.params.len, 255)) else 0;
                // A NON-composable fn can still take `@Composable`-typed
                // lambda params (`movableContentOf(content)`): a bare
                // `content()` inside one of its composable lambdas (the
                // ctor-sink wrapper `MovableContent({ content() })`) is a
                // composable call and must thread.
                const lp = a.create(std.StringHashMap(void)) catch @panic("oom");
                lp.* = try composableLambdaParamNames(a, f);
                var w = Walker{ .a = a, .b = .{ .a = a, .gen_span = f.span }, .oracle = NameSetOracle.isComposableCall, .oracle_ctx = oracle, .sinks = sinks, .thread = false, .ret_composable = ret_composable, .ret_fn_params = ret_fn_params, .lambda_params = lp };
                if (f.body) |*fb| switch (fb.*) {
                    .Block => |*blk| try w.walkBlock(blk),
                    .Expr => |*e| if (ret_composable and e.* == .Lambda) {
                        try w.transformComposableLambda(&e.Lambda, ret_fn_params);
                    } else {
                        try w.walkExpr(e);
                    },
                };
            }
        },
        .Class => |*c| for (c.members) |*m| try transformDecl(a, m, oracle, sinks, true),
        .Object => |*o| for (o.members) |*m| try transformDecl(a, m, oracle, sinks, true),
        .Property => |p| {
            const pb = B{ .a = a, .gen_span = p.span };
            var w = Walker{ .a = a, .b = pb, .oracle = NameSetOracle.isComposableCall, .oracle_ctx = oracle, .sinks = sinks, .thread = false };
            if (p.init) |*ini| try w.walkExpr(ini);
            if (p.delegate) |del| try w.walkExpr(del);
            // A `@Composable` property GETTER composes with no `$composer`
            // param of its own: walk its body in ambient mode, where composer
            // references go through the `__compose_currentComposer` intrinsic
            // (the interpreter keeps that stack current around every
            // transformed-composable call). The upstream `currentComposer`
            // property ITSELF is the intrinsic stub ("Implemented as an
            // intrinsic", a throwing body): replace its getter body with the
            // intrinsic read.
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

/// `androidx.compose.runtime.klioComposableDefaultMarker()` — the absent-arg
/// sentinel call (see `default_marker_path`).
fn markerCall(b: B) Expr {
    return b.call(b.pathExprSegs(&default_marker_path), b.a.alloc(Expr, 0) catch @panic("oom"));
}

/// `$dirty = $dirty or (if (<probe>) 2 else 0)` — one skip-calculus probe.
fn dirtyOrProbe(b: B, probe: Expr) Stmt {
    const pick = Expr{ .If = .{
        .cond = b.box(probe),
        .then_branch = b.box(b.intLit(2)),
        .else_branch = b.box(b.intLit(0)),
        .span = b.gen_span,
    } };
    return .{ .Assign = .{
        .target = b.pathExpr(dirty_local),
        .op = .Assign,
        .value = b.callMember(b.pathExpr(dirty_local), "or", b.slice1(pick)),
        .span = b.gen_span,
    } };
}

/// The transformed signature plus the body prologue that re-evaluates
/// composable defaults in composition context. Every original param keeps its
/// slot; a DEFAULTED param `p: T = D` is renamed to `p$arg` with the marker as
/// its default, and the prologue declares `val p = if (p$arg === marker()) D
/// else p$arg` — so `D` runs inside the body, where the threaded `$composer`
/// is in scope (the body walk threads any composable call inside `D`). The
/// restart re-call passes `p$arg`, so a recomposition of the scope re-evaluates
/// the default exactly as upstream's `$default`-mask re-call does.
/// `$composer`/`$changed` are appended last, as before.
const ParamsAndPrologue = struct { params: []Param, prologue: []Stmt };

/// The enclosing function's `@Composable`-lambda-typed param names, for the
/// walker's bare-invoke threading (`content()`). Arena-allocated.
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
            .ty = null,
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

/// The composable-function transform. Returns a NEW `Function` (the input is not
/// mutated); all fresh nodes are arena-allocated. `oracle`/`oracle_ctx` classify
/// callees; `sinks` names functions with a `@Composable`-typed lambda parameter,
/// so a lambda bound to one is itself transformed (null = no lambda transform).
pub fn transformComposableFunction(
    a: std.mem.Allocator,
    f: *const Function,
    oracle: ComposableOracle,
    oracle_ctx: *anyopaque,
    sinks: ?*const std.StringHashMap(void),
    in_class: bool,
    locals: ?*std.StringHashMap(void),
) std.mem.Allocator.Error!Function {
    const b = B{ .a = a, .gen_span = f.span };

    // 1. Signature: append `$composer: Composer` and `$changed: Int`; move
    //    composable defaults into the body prologue.
    const pp = try buildParamsAndPrologue(a, b, f);
    const params = pp.params;

    // 2. Body: thread the composer through @Composable calls, then bracket.
    const orig_stmts: []const Stmt = switch (f.body orelse return signatureOnly(f, params)) {
        .Block => |blk| blk.stmts,
        .Expr => |e| blk: {
            // Single-expression body becomes a one-statement block.
            const s = try a.alloc(Stmt, 1);
            s[0] = .{ .Expr = e };
            break :blk s;
        },
    };

    var out: std.ArrayList(Stmt) = .empty;
    // `$composer.startRestartGroup(<key>)`
    try out.append(a, .{ .Expr = b.callMember(
        b.pathExpr(composer_param),
        "startRestartGroup",
        b.slice1(b.intLit(positionalKey(f.span))),
    ) });
    // Threaded body: walk in place, replacing `currentComposer` with the
    // threaded `$composer` and threading each @Composable call. The defaults
    // prologue walks too, so a composable call inside a default expression is
    // threaded against this body's `$composer`.
    const lp = try a.create(std.StringHashMap(void));
    lp.* = try composableLambdaParamNames(a, f);
    const w_ret_composable = f.return_type != null and isComposableFnType(&f.return_type.?);
    var w = Walker{ .a = a, .b = b, .oracle = oracle, .oracle_ctx = oracle_ctx, .sinks = sinks, .lambda_params = lp, .locals = locals, .ret_composable = w_ret_composable, .ret_fn_params = if (w_ret_composable) @intCast(@min(f.return_type.?.function.?.params.len, 255)) else 0 };
    for (pp.prologue) |*s| {
        try w.walkStmt(s);
        try out.append(a, s.*);
    }
    // Skip calculus: probe every value parameter through
    // `$composer.changed(p)` — the probe also stores the value in the slot
    // table, so it runs on every invocation regardless of the skip decision.
    // The body executes when a probe reported a change, the scope was forced
    // (`$changed` bit 0, set by the restart re-invoke), or the composer is
    // not in a skippable state; otherwise the group skips wholesale. A
    // vararg parameter is not probed element-wise and conservatively always
    // recomposes; a receiver (member or extension) probes `this`. Probes run
    // AFTER the defaults prologue so a defaulted parameter probes its
    // resolved value.
    if (emit_skip_calculus) {
        const dirty_prop = try a.create(ast.Property);
        dirty_prop.* = .{
            .mutable = true,
            .name = b.ident(dirty_local),
            .receiver_type = null,
            .ty = null,
            .init = b.callMember(b.pathExpr(changed_param), "and", b.slice1(b.intLit(1))),
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
        if (f.receiver_type != null or in_class) {
            try out.append(a, dirtyOrProbe(b, b.callMember(
                b.pathExpr(composer_param),
                "changed",
                b.slice1(.{ .This = .{ .qualifier = null, .span = b.gen_span } }),
            )));
        }
        for (f.params) |p| {
            if (p.is_vararg) {
                try out.append(a, .{ .Assign = .{
                    .target = b.pathExpr(dirty_local),
                    .op = .Assign,
                    .value = b.callMember(b.pathExpr(dirty_local), "or", b.slice1(b.intLit(2))),
                    .span = b.gen_span,
                } });
                continue;
            }
            try out.append(a, dirtyOrProbe(b, b.callMember(
                b.pathExpr(composer_param),
                "changed",
                b.slice1(b.pathExpr(p.name.name)),
            )));
        }
    }
    // `if ($dirty != 0 || !$composer.skipping) { <body> } else
    // { $composer.skipToGroupEnd() }`
    var body_list: std.ArrayList(Stmt) = .empty;
    for (orig_stmts) |*s| {
        try w.walkStmt(@constCast(s));
        try body_list.append(a, s.*);
    }
    if (!emit_skip_calculus) {
        for (body_list.items) |s| try out.append(a, s);
        try out.append(a, .{ .Expr = try endRestartGroupExpr(a, b, f.name.name, params[0..f.params.len]) });
        const plain_body = Block{ .stmts = try out.toOwnedSlice(a), .span = f.span };
        return withBody(f, params, .{ .Block = plain_body });
    }
    const skip_stmts = try a.alloc(Stmt, 1);
    skip_stmts[0] = .{ .Expr = b.callMember(b.pathExpr(composer_param), "skipToGroupEnd", try a.alloc(Expr, 0)) };
    const run_cond = Expr{ .Binary = .{
        .op = .Or,
        .lhs = b.box(.{ .Binary = .{
            .op = .Neq,
            .lhs = b.box(b.pathExpr(dirty_local)),
            .rhs = b.box(b.intLit(0)),
            .span = b.gen_span,
        } }),
        .rhs = b.box(.{ .Unary = .{
            .op = .Not,
            .expr = b.box(b.member(b.pathExpr(composer_param), "skipping")),
            .span = b.gen_span,
        } }),
        .span = b.gen_span,
    } };
    try out.append(a, .{ .Expr = .{ .If = .{
        .cond = b.box(run_cond),
        .then_branch = b.box(.{ .Block = .{ .stmts = try body_list.toOwnedSlice(a), .span = f.span } }),
        .else_branch = b.box(.{ .Block = .{ .stmts = skip_stmts, .span = b.gen_span } }),
        .span = b.gen_span,
    } } });
    // `$composer.endRestartGroup()?.updateScope { c, f -> App(args, c, $changed or 1) }`
    try out.append(a, .{ .Expr = try endRestartGroupExpr(a, b, f.name.name, params[0..f.params.len]) });

    const new_body = Block{ .stmts = try out.toOwnedSlice(a), .span = f.span };
    return withBody(f, params, .{ .Block = new_body });
}

/// Transform a non-restartable / inline @Composable (`isRestartableComposable`
/// false): append `$composer`/`$changed` and thread the body, WITHOUT a
/// start/endRestartGroup bracket. The body's original form (block or single
/// expression) is preserved so a value-returning composable keeps its result.
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
    var w = Walker{ .a = a, .b = b, .oracle = oracle, .oracle_ctx = oracle_ctx, .sinks = sinks, .lambda_params = lp, .locals = locals, .ret_composable = w_ret_composable, .ret_fn_params = if (w_ret_composable) @intCast(@min(f.return_type.?.function.?.params.len, 255)) else 0 };
    const body = f.body orelse return signatureOnly(f, params);
    switch (body) {
        .Block => |blk| {
            const stmts = try a.alloc(Stmt, pp.prologue.len + blk.stmts.len);
            @memcpy(stmts[0..pp.prologue.len], pp.prologue);
            @memcpy(stmts[pp.prologue.len..], blk.stmts);
            for (stmts) |*s| try w.walkStmt(s);
            return withBody(f, params, .{ .Block = .{ .stmts = stmts, .span = blk.span } });
        },
        .Expr => |e| {
            var ne = e;
            try w.walkExpr(&ne);
            if (pp.prologue.len == 0) return withBody(f, params, .{ .Expr = ne });
            // A value-returning single-expression body gains the prologue as a
            // block; the expression becomes an explicit `return`.
            const stmts = try a.alloc(Stmt, pp.prologue.len + 1);
            @memcpy(stmts[0..pp.prologue.len], pp.prologue);
            for (stmts[0..pp.prologue.len]) |*s| try w.walkStmt(s);
            stmts[pp.prologue.len] = .{ .Expr = .{ .Return = .{
                .value = b.box(ne),
                .label = null,
                .span = b.gen_span,
            } } };
            return withBody(f, params, .{ .Block = .{ .stmts = stmts, .span = f.span } });
        },
    }
}

/// Recursive in-place body transformer. Within a `@Composable` function body it
/// (1) replaces every `currentComposer` read with the threaded `$composer`
/// parameter — the role the plugin's `$composer` substitution plays — and (2)
/// appends `($composer, childChanged)` to every `@Composable` call. It descends
/// through control flow, nested calls, string interpolations, and lambda bodies.
const Walker = struct {
    a: std.mem.Allocator,
    b: B,
    oracle: ComposableOracle,
    oracle_ctx: *anyopaque,
    sinks: ?*const std.StringHashMap(void) = null,
    /// Names of the enclosing function's `@Composable`-lambda-typed value
    /// parameters. A bare call to one (`content()` inside
    /// `CompositionLocalProvider`) invokes a plugin-lowered composable lambda,
    /// so it is threaded exactly like an oracle-named composable call — the
    /// closure's trailing params are `$composer`/`$changed`.
    lambda_params: ?*const std.StringHashMap(void) = null,
    /// Simple names of LOCAL `@Composable` declarations seen so far in this
    /// walk. Scoped to the enclosing function's transform — a local name
    /// (`Composition`, `View`, `Test` in the upstream tests) must never join
    /// the GLOBAL oracle, or unrelated same-named functions everywhere get
    /// threaded (`Composition(applier, parent)` is the non-composable
    /// factory).
    locals: ?*std.StringHashMap(void) = null,
    /// Scoped names of VALS holding composable lambdas (factory-initialized
    /// or declared with a @Composable fn type). Their bare calls are VALUE
    /// invocations: the pair passes POSITIONALLY (a wrapped
    /// ComposableLambdaImpl declares `invoke(c, changed)` — named
    /// `$composer=`/`$changed=` args cannot bind it). Function calls keep
    /// the named pair for the defaulted-marker machinery.
    composable_vals: ?*std.StringHashMap(void) = null,
    /// Ambient mode: the scope is a `@Composable` property GETTER, which has
    /// no `$composer` param. Composer references resolve through the
    /// `__compose_currentComposer` host intrinsic instead.
    ambient: bool = false,
    /// Whether the current scope is composable — a composable function body or a
    /// composable lambda body. Only there are @Composable calls threaded and
    /// `currentComposer` substituted. A non-composable body is still walked (to
    /// transform composable-lambda-sink arguments a `compose { … }` passes down),
    /// but its own calls are left alone.
    thread: bool = true,
    /// The enclosing function declares a `@Composable`-function-typed RETURN
    /// type: a lambda in return position (`return { … }`, or the whole
    /// expression body) is composable — `movableContentOf`'s returned
    /// wrapper is the shape.
    ret_composable: bool = false,
    /// Declared param count of that return function type (the header-less
    /// returned lambda keeps an `it` slot when it is 1).
    ret_fn_params: u8 = 0,

    /// The composer reference for the current scope: the threaded `$composer`
    /// param, or the ambient intrinsic call in a getter.
    fn composerRef(w: *Walker) Expr {
        if (w.ambient)
            return w.b.call(w.b.pathExprSegs(&ambient_composer_path), w.a.alloc(Expr, 0) catch @panic("oom"));
        return w.b.pathExpr(composer_param);
    }

    fn walkBlock(w: *Walker, blk: *Block) std.mem.Allocator.Error!void {
        for (blk.stmts) |*s| try w.walkStmt(s);
    }

    fn walkStmt(w: *Walker, s: *Stmt) std.mem.Allocator.Error!void {
        switch (s.*) {
            .Expr => |*e| try w.walkExpr(e),
            .Assign => |*asg| {
                try w.walkExpr(&asg.target);
                try w.walkExpr(&asg.value);
            },
            .DestructuringDecl => |*d| try w.walkExpr(&d.init),
            .Decl => |*d| try w.walkDecl(d),
        }
    }

    fn walkDecl(w: *Walker, d: *Decl) std.mem.Allocator.Error!void {
        switch (d.*) {
            .Property => |p| {
                // `val content: @Composable () -> Unit = { … }` — the
                // declared type makes the initializer lambda composable.
                if (p.init) |*ini| {
                    if (ini.* == .Lambda and p.ty != null and isComposableFnType(&p.ty.?)) {
                        try w.transformComposableLambda(&ini.Lambda, @intCast(@min(p.ty.?.function.?.params.len, 255)));
                    } else {
                        try w.walkExpr(ini);
                    }
                }
                if (p.delegate) |del| try w.walkExpr(del);
                // A val HOLDING a composable lambda — declared with a
                // `@Composable` fn type, or initialized from a factory
                // returning one (`val content = movableContentOf { … }`) —
                // joins the scoped locals set: a bare `content()` threads.
                const holds_composable = blk: {
                    if (p.ty != null and isComposableFnType(&p.ty.?)) break :blk true;
                    const ini = p.init orelse break :blk false;
                    if (ini != .Call or ini.Call.callee.* != .Path) break :blk false;
                    const segs = ini.Call.callee.Path.segments;
                    if (segs.len == 0) break :blk false;
                    const af = active_factories orelse break :blk false;
                    break :blk af.contains(segs[segs.len - 1].name);
                };
                if (holds_composable) {
                    // The name joins BOTH sets: `locals` feeds every
                    // established consumer (nested transforms, branch
                    // scans); `composable_vals` only decides the
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
                // A LOCAL `@Composable` declaration transforms exactly like
                // a top-level one (its name is already in the oracle via the
                // body-deep collection); the transform walks its body itself.
                if (f.body != null and isComposable(f.annotations)) {
                    if (w.locals == null) {
                        const set = w.a.create(std.StringHashMap(void)) catch @panic("oom");
                        set.* = std.StringHashMap(void).init(w.a);
                        w.locals = set;
                    }
                    try w.locals.?.put(f.name.name, {});
                    if (isRestartableComposable(f)) {
                        f.* = try transformComposableFunction(w.a, f, w.oracle, w.oracle_ctx, w.sinks, false, w.locals);
                    } else {
                        f.* = try transformThreadedComposable(w.a, f, w.oracle, w.oracle_ctx, w.sinks, w.locals);
                    }
                    return;
                }
                // A local fn returning a `@Composable` fn-type: its
                // return-position lambdas compose, exactly like a top-level
                // one's (the walker flag is scoped to this declaration).
                const saved_ret = w.ret_composable;
                const saved_rfp = w.ret_fn_params;
                w.ret_composable = f.return_type != null and isComposableFnType(&f.return_type.?);
                w.ret_fn_params = if (w.ret_composable) @intCast(@min(f.return_type.?.function.?.params.len, 255)) else 0;
                defer {
                    w.ret_composable = saved_ret;
                    w.ret_fn_params = saved_rfp;
                }
                if (f.body) |*fb| switch (fb.*) {
                    .Block => |*blk| try w.walkBlock(blk),
                    .Expr => |*e| if (w.ret_composable and e.* == .Lambda) {
                        try w.transformComposableLambda(&e.Lambda, w.ret_fn_params);
                    } else {
                        try w.walkExpr(e);
                    },
                };
            },
            else => {},
        }
    }

    /// Replace a just-transformed composable lambda ARGUMENT with
    /// `composableLambda($composer, <span key>, true, <lambda>)` — the
    /// remembered instance the engine slots, so `composer.changed(content)`
    /// is false when the content is unchanged and the child group SKIPS.
    /// Threaded scope only ($composer must be in scope); entry-point sinks
    /// in plain scope stay raw (invokeComposable wraps the root itself).
    fn wrapInComposableLambda(w: *Walker, arg: *Expr) void {
        const key = positionalKey(exprSpanOf(arg));
        const args = w.a.alloc(Expr, 4) catch @panic("oom");
        args[0] = w.composerRef();
        args[1] = w.b.intLit(key);
        args[2] = .{ .BoolLit = .{ .value = true, .span = w.b.gen_span } };
        args[3] = arg.*;
        arg.* = w.b.call(w.b.pathExprSegs(&composable_lambda_path), args);
    }

    /// Whether a branch contains a call the pass considers composable
    /// (oracle name, scoped local, composable lambda param, or sink) —
    /// the gate for the per-branch replace groups: kotlinc brackets only
    /// conditional COMPOSITION, and bracketing plain control flow inside
    /// threaded engine functions corrupts their group structure.
    fn branchHasComposable(w: *Walker, e: *const Expr) bool {
        switch (e.*) {
            .Call => |c| {
                if (calleeSimpleName(c.callee)) |nm| {
                    const is_lp = w.lambda_params != null and w.lambda_params.?.contains(nm);
                    const is_local = w.locals != null and w.locals.?.contains(nm);
                    const is_val = w.composable_vals != null and w.composable_vals.?.contains(nm);
                    const is_sink = w.sinks != null and w.sinks.?.contains(nm);
                    if (is_lp or is_local or is_val or is_sink or w.oracle(w.oracle_ctx, nm)) return true;
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
                    else => {},
                };
                return false;
            },
            else => return false,
        }
    }

    /// Bracket a Block-shaped branch with
    /// `$composer.startReplaceGroup(<span key>)` / `endReplaceGroup()`.
    fn wrapBranchInReplaceGroup(w: *Walker, branch: *Expr) void {
        if (branch.* != .Block) return;
        const blk = &branch.Block;
        const key = positionalKey(blk.span);
        if (dbg_groups) std.debug.print("[compose-pass] replace-group key={d} stmts={d}\n", .{ key, blk.stmts.len });
        const stmts = w.a.alloc(ast.Stmt, blk.stmts.len + 2) catch @panic("oom");
        const start_args = w.a.alloc(Expr, 1) catch @panic("oom");
        start_args[0] = w.b.intLit(key);
        stmts[0] = .{ .Expr = w.b.callMember(w.composerRef(), "startReplaceGroup", start_args) };
        @memcpy(stmts[1 .. blk.stmts.len + 1], blk.stmts);
        stmts[blk.stmts.len + 1] = .{ .Expr = w.b.callMember(w.composerRef(), "endReplaceGroup", w.a.alloc(Expr, 0) catch @panic("oom")) };
        blk.stmts = stmts;
    }

    fn walkExpr(w: *Walker, e: *Expr) std.mem.Allocator.Error!void {
        // `currentComposer` (bare or trailing member segment) IS the threaded
        // composer inside a composable body.
        if (w.thread and isCurrentComposer(e)) {
            e.* = w.composerRef();
            return;
        }
        switch (e.*) {
            .Call => |*c| {
                try w.walkExpr(c.callee);
                const name = calleeSimpleName(c.callee);
                // A trailing lambda bound to a `@Composable`-typed parameter
                // becomes a `{ …, $composer, $changed -> … }` lambda (the plugin
                // lowers composable lambdas to FunctionN<…, Composer, Int, …>);
                // the engine invokes it with the composer. It is transformed in
                // place of the generic lambda-body recursion, so its body is
                // threaded once against its own `$composer` — not the enclosing
                // one — and no argument is threaded twice.
                // A sink whose name is ITSELF a composable function (`Linear`,
                // `Text` mocks) is only callable from composable context; the
                // same bare name in a NON-composable scope is a different
                // declaration (the validator extension `MockViewValidator.
                // Linear(block)`), and transforming its lambda handed the
                // validator's calls a phantom composer. A non-composable sink
                // (`compose { }`, `movableContentOf { }` — the entry points)
                // transforms its lambda from any scope.
                const sink_applies = name != null and w.sinks != null and w.sinks.?.contains(name.?) and
                    (w.thread or !w.oracle(w.oracle_ctx, name.?));
                const sink_last = c.args.len != 0 and
                    c.args[c.args.len - 1] == .Lambda and sink_applies;
                for (c.args, 0..) |*arg, i| {
                    if (sink_last and i == c.args.len - 1) {
                        const exp: ?u8 = if (active_sink_arity) |sa| sa.get(name.?) else null;
                        try w.transformComposableLambda(&arg.Lambda, exp);
                        // Wrap only content that actually COMPOSES: the
                        // name-keyed sink also catches sibling overloads'
                        // plain trailing lambdas (ComposeNode's update),
                        // whose wrapped invoke shape would not exist.
                        if (w.thread and emit_lambda_memo and w.branchHasComposable(arg)) w.wrapInComposableLambda(arg);
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
                        // property (`content.content(parameter)`).
                        const is_composable_prop = c.callee.* == .Member and
                            active_composable_props != null and active_composable_props.?.contains(nm);
                        // VALUE invocations take the pair positionally —
                        // only under the memoization emission (a wrapped
                        // ComposableLambdaImpl cannot bind the named pair);
                        // unwrapped closures keep the named pair, the
                        // established shape.
                        // Positional pair ONLY where the value can be a
                        // memo-wrapped ComposableLambdaImpl: sink-arg
                        // lambdas reach lambda params and composable
                        // props. A composable VAL (movableContentOf's
                        // returned wrapper) holds an unwrapped closure
                        // with literal `$composer`/`$changed` params — it
                        // keeps the named pair.
                        const positional = emit_lambda_memo and (is_lambda_param or is_composable_prop);
                        if (positional or is_composable_val or is_local_composable or w.oracle(w.oracle_ctx, nm)) try w.threadCall(c, positional);
                    }
                }
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
                // Conditional content in a composable body gets a
                // REPLACEABLE GROUP per branch (distinct span keys), the
                // plugin ABI's slot-alignment bracket: without it a forced
                // recomposition of an UNCHANGED body misaligns at the
                // branch and reports spurious changes, and a branch flip
                // cannot replace its content atomically. Statement-shaped
                // (Block) branches only: an expression-if's value must not
                // be displaced by the bracket call. A `return` inside the
                // branch skips the end call (kotlinc brackets returns too;
                // acceptable gap, noted).
                if (w.thread and (w.branchHasComposable(f.then_branch) or
                    (if (f.else_branch) |eb2| w.branchHasComposable(eb2) else false)))
                {
                    w.wrapBranchInReplaceGroup(f.then_branch);
                    if (f.else_branch) |eb| w.wrapBranchInReplaceGroup(eb);
                }
            },
            .While => |*wl| {
                try w.walkExpr(wl.cond);
                try w.walkExpr(wl.body);
            },
            .DoWhile => |*dw| {
                if (dw.body) |bd| try w.walkExpr(bd);
                try w.walkExpr(dw.cond);
            },
            .For => |*fr| {
                try w.walkExpr(fr.iter);
                try w.walkExpr(fr.body);
            },
            .Return => |*r| if (r.value) |v| {
                if (w.ret_composable and v.* == .Lambda) {
                    try w.transformComposableLambda(&v.Lambda, w.ret_fn_params);
                } else {
                    try w.walkExpr(v);
                }
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
                for (wh.branches) |*br| {
                    for (br.patterns) |*pat| switch (pat.kind) {
                        .Value => |*ve| try w.walkExpr(ve),
                        .InRange => |*ve| try w.walkExpr(ve),
                        else => {},
                    };
                    try w.walkExpr(&br.body);
                }
            },
            .IsCheck => |*ic| try w.walkExpr(ic.expr),
            .As => |*as| try w.walkExpr(as.expr),
            .StringTemplate => |*st| for (st.parts) |*part| switch (part.*) {
                .Interp => |ie| try w.walkExpr(ie),
                else => {},
            },
            .Lambda => |*lam| try w.walkBlock(&lam.body),
            .AnonFun => |*af| if (af.body) |ab| switch (ab.*) {
                .Block => |*blk| try w.walkBlock(blk),
                .Expr => |*ex| try w.walkExpr(ex),
            },
            else => {},
        }
    }

    /// Rewrite a `@Composable` lambda to `{ …orig, $composer, $changed -> … }`
    /// and thread its body. The plugin lowers a `@Composable (P…) -> R` to a
    /// `FunctionN<P…, Composer, Int, R>`; the engine's `invokeComposable` /
    /// composer invoke it with the composer and a changed flag.
    fn transformComposableLambda(w: *Walker, lam: anytype, expected_params: ?u8) std.mem.Allocator.Error!void {
        if (dbg_lambda) std.debug.print("[compose-pass] transform composable lambda ({d} params)\n", .{lam.params.len});
        // Idempotence: a lambda already carrying a trailing `$composer` param
        // (a shared node reached twice) is left alone.
        if (lam.params.len >= 2 and std.mem.eql(u8, lam.params[lam.params.len - 1].name, changed_param))
            return;
        // A lambda with only the synthetic `it` (a header-less `{ … }` bound to a
        // `() -> R` sink) has no real parameters: the composer/changed pair
        // replaces `it`, not follows it. A header-declared lambda keeps its
        // explicit parameters and gains the pair after them — as does the
        // implicit `it` when the sink's declared composable type takes one
        // parameter (`MovableContent({ content() })` invokes its content
        // with the movable parameter first).
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
        lam.params = new_params;
        lam.param_tys = new_tys;
        lam.implicit_it = false;
        // The lambda body IS composable: thread it (and substitute
        // currentComposer) even when the enclosing scope was not.
        const saved = w.thread;
        w.thread = true;
        try w.walkBlock(&lam.body);
        w.thread = saved;
    }

    /// Append `($composer = <composer>, $changed = <childChanged>)` to a
    /// resolved @Composable call. The pair is passed by NAME: the callee may
    /// declare defaulted params between the caller's positional args and the
    /// synthetic pair (`Test(number: Int = …, $composer, $changed)` called
    /// `Test($composer, 0)`), and a positional append would bind the composer
    /// into the first omitted param. Named, the binder slots the pair exactly
    /// and the omitted params take their defaults.
    fn threadCall(w: *Walker, c: anytype, positional: bool) std.mem.Allocator.Error!void {
        var new_args = try w.a.alloc(Expr, c.args.len + 2);
        @memcpy(new_args[0..c.args.len], c.args);
        new_args[c.args.len] = w.composerRef();
        new_args[c.args.len + 1] = w.b.intLit(0);
        const new_names = try w.a.alloc(?[]const u8, new_args.len);
        for (new_names, 0..) |*n, i| n.* = if (i < c.arg_names.len) c.arg_names[i] else null;
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

/// The span of an expression, for the memoization key. Falls back to a
/// zero span when the node form carries none the pass knows about.
fn exprSpanOf(e: *const Expr) Span {
    return switch (e.*) {
        .Lambda => |l| l.span,
        .Call => |c| exprSpanOf(c.callee),
        .Path => |pp| if (pp.segments.len != 0) pp.segments[0].span else Span.init(span_mod.FileId.from(0), 0, 0),
        else => Span.init(span_mod.FileId.from(0), 0, 0),
    };
}

/// Whether `e` denotes `currentComposer` — a bare path or a trailing member
/// segment of that name.
fn isCurrentComposer(e: *const Expr) bool {
    return switch (e.*) {
        .Path => |p| p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, "currentComposer"),
        else => false,
    };
}

/// `$composer.endRestartGroup()?.updateScope { c, f -> Self(origArgs, c, $changed or 1) }`
/// — Phase 1 emits the recompose lambda that re-invokes the function with the
/// same value arguments, the recompose composer, and `$changed or 1`.
/// `value_params` are the TRANSFORMED value params (a defaulted param is its
/// renamed `p$arg`, so a restart passes the marker through and the default
/// re-evaluates in the new composition).
fn endRestartGroupExpr(a: std.mem.Allocator, b: B, fn_name: []const u8, value_params: []const Param) std.mem.Allocator.Error!Expr {
    // `$composer.endRestartGroup()`
    const end_call = b.callMember(b.pathExpr(composer_param), "endRestartGroup", &.{});
    // `?.updateScope(<lambda>)` — safe member call.
    const lambda = try recomposeLambda(a, b, fn_name, value_params);
    return .{ .Call = .{
        .callee = b.box(.{ .Member = .{
            .receiver = b.box(end_call),
            .name = b.ident("updateScope"),
            .safe = true,
            .span = b.gen_span,
        } }),
        .args = b.slice1(lambda),
        .arg_names = try oneNull(a),
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = b.gen_span,
    } };
}

/// `{ c, _f -> Self(origValueArgs, c, $changed or 1) }`
fn recomposeLambda(a: std.mem.Allocator, b: B, fn_name: []const u8, value_params: []const Param) std.mem.Allocator.Error!Expr {
    // Re-invoke the function: original value params by name + (recompose
    // composer, $changed or 1).
    var call_args = try a.alloc(Expr, value_params.len + 2);
    for (value_params, 0..) |p, i| call_args[i] = b.pathExpr(p.name.name);
    call_args[value_params.len] = b.pathExpr("$rc"); // recompose composer lambda param
    // `$changed.or(1)` — Kotlin's bitwise `or` is an INFIX FUNCTION, not an
    // operator: the AST `BinOp.Or` is logical `||`, whose short-circuit branch
    // on an Int operand kills the restart invocation. Emit the member call the
    // parser would produce for `$changed or 1`.
    call_args[value_params.len + 1] = b.callMember(
        b.pathExpr(changed_param),
        "or",
        b.slice1(b.intLit(1)),
    );
    const reinvoke = b.call(b.pathExpr(fn_name), call_args);

    const lam_params = try a.alloc(Ident, 2);
    lam_params[0] = b.ident("$rc");
    lam_params[1] = b.ident("$rf");
    const lam_ptys = try a.alloc(?TypeRef, 2);
    lam_ptys[0] = null;
    lam_ptys[1] = null;
    const body_stmts = try a.alloc(Stmt, 1);
    body_stmts[0] = .{ .Expr = reinvoke };
    return .{ .Lambda = .{
        .params = lam_params,
        .param_tys = lam_ptys,
        .body = .{ .stmts = body_stmts, .span = b.gen_span },
        .implicit_it = false,
        .span = b.gen_span,
    } };
}

fn oneNull(a: std.mem.Allocator) std.mem.Allocator.Error![]?[]const u8 {
    const s = try a.alloc(?[]const u8, 1);
    s[0] = null;
    return s;
}

/// The simple (last-segment) name a call's callee denotes, or null when the
/// callee is not a plain name / member (Phase 1 only threads those shapes).
fn calleeSimpleName(callee: *const Expr) ?[]const u8 {
    return switch (callee.*) {
        .Path => |p| if (p.segments.len >= 1) p.segments[p.segments.len - 1].name else null,
        .Member => |m| m.name.name,
        else => null,
    };
}

fn signatureOnly(f: *const Function, params: []Param) Function {
    return withBody(f, params, f.body orelse .{ .Block = .{ .stmts = &.{}, .span = f.span } });
}

/// A copy of `f` with new params + body; all other fields preserved. Clears
/// the `@Composable` annotation is left to a later pass — Phase 1 keeps it so
/// downstream still recognises the function during migration.
fn withBody(f: *const Function, params: []Param, body: FunctionBody) Function {
    var out = f.*;
    out.params = params;
    out.body = body;
    return out;
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

const testing = std.testing;

fn allComposable(_: *anyopaque, _: []const u8) bool {
    return true;
}

test "a composable-lambda-sink argument is transformed to (…, composer, changed)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    // Body: Column { Text("hi") }  — Column is a lambda sink, Text is composable.
    var text_segs = [_]Ident{dummyIdent("Text")};
    var text_callee = Expr{ .Path = .{ .segments = &text_segs, .span = gsp } };
    var str_parts = [_]ast.StringPart{.{ .Text = "hi" }};
    var text_args = [_]Expr{.{ .StringTemplate = .{ .parts = &str_parts, .span = gsp } }};
    var text_names = [_]?[]const u8{null};
    var lam_body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &text_callee,
        .args = &text_args,
        .arg_names = &text_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = gsp,
    } } }};
    var lam_params: [0]Ident = .{};
    var lam_ptys: [0]?TypeRef = .{};
    var col_args = [_]Expr{.{ .Lambda = .{
        .params = &lam_params,
        .param_tys = &lam_ptys,
        .body = .{ .stmts = &lam_body_stmts, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } }};
    var col_segs = [_]Ident{dummyIdent("Column")};
    var col_callee = Expr{ .Path = .{ .segments = &col_segs, .span = gsp } };
    var col_names = [_]?[]const u8{null};
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &col_callee,
        .args = &col_args,
        .arg_names = &col_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const host = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);

    var sinks = std.StringHashMap(void).init(a);
    try sinks.put("Column", {});
    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &host, allComposable, &ctx, &sinks, false, null);
    // The Column call sits inside the skip-if's then-block.
    const col = wrappedBodyStmts(&out)[0].Expr.Call;
    // Column is composable too (allComposable) → gains its own (composer, changed).
    // The sink lambda is memoized — wrapped in
    // `composableLambda($composer, key, true, <lambda>)` with the lambda last.
    const memo = col.args[0].Call;
    const memo_path = memo.callee.Path;
    try testing.expectEqualStrings("composableLambda", memo_path.segments[memo_path.segments.len - 1].name);
    try testing.expectEqual(@as(usize, 4), memo.args.len);
    const lam = memo.args[3].Lambda;
    // The sink lambda had only the synthetic `it`; it is replaced by
    // ($composer, $changed), not appended after.
    try testing.expectEqual(@as(usize, 2), lam.params.len);
    try testing.expectEqualStrings(composer_param, lam.params[0].name);
    try testing.expectEqualStrings(changed_param, lam.params[1].name);
    try testing.expect(!lam.implicit_it);
    // Its body's Text call was threaded ($composer, 0).
    const inner = lam.body.stmts[0].Expr.Call;
    try testing.expectEqual(@as(usize, 3), inner.args.len);
    try testing.expectEqualStrings(composer_param, inner.args[1].Path.segments[0].name);
}

fn noneComposable(_: *anyopaque, _: []const u8) bool {
    return false;
}

/// The restart-wrapped body statements: the then-block of the skip `if`
/// (second-to-last statement of the transformed body).
fn wrappedBodyStmts(out: *const Function) []const Stmt {
    const stmts = out.body.?.Block.stmts;
    return stmts[stmts.len - 2].Expr.If.then_branch.Block.stmts;
}

fn dummyIdent(name: []const u8) Ident {
    return .{ .name = name, .span = Span.init(span_mod.FileId.from(0), 0, 0) };
}

fn emptyFn(name: []const u8, params: []Param, body: ?FunctionBody, comp: bool) Function {
    return .{
        .name = dummyIdent(name),
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = params,
        .return_type = null,
        .body = body,
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = if (comp) &composableAnno else &.{},
        .span = Span.init(span_mod.FileId.from(0), 100, 200),
    };
}

var composableAnno = [_]ast.Annotation{.{
    .use_site = null,
    .path = &composablePath,
    .type_args = &.{},
    .args = &.{},
    .arg_names = &.{},
    .span = Span.init(span_mod.FileId.from(0), 0, 0),
}};
var composablePath = [_]Ident{dummyIdent("Composable")};

test "isComposable detects the annotation" {
    var noargs: [0]Param = .{};
    const cf = emptyFn("App", &noargs, null, true);
    const pf = emptyFn("plain", &noargs, null, false);
    try testing.expect(isComposable(cf.annotations));
    try testing.expect(!isComposable(pf.annotations));
}

test "walker replaces currentComposer with the threaded composer inside a nested call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    // @Composable fun Host() { Emit(currentComposer) }
    var cc_segs = [_]Ident{dummyIdent("currentComposer")};
    var emit_segs = [_]Ident{dummyIdent("Emit")};
    var emit_callee = Expr{ .Path = .{ .segments = &emit_segs, .span = gsp } };
    var emit_args = [_]Expr{.{ .Path = .{ .segments = &cc_segs, .span = gsp } }};
    var emit_names = [_]?[]const u8{null};
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &emit_callee,
        .args = &emit_args,
        .arg_names = &emit_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const host = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);

    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &host, allComposable, &ctx, null, false, null);
    // The Emit call sits inside the skip-if's then-block.
    const emit = wrappedBodyStmts(&out)[0].Expr.Call;
    // Emit gained ($composer, 0); its first arg — originally currentComposer —
    // is now the threaded $composer.
    try testing.expectEqual(@as(usize, 3), emit.args.len);
    try testing.expectEqualStrings(composer_param, emit.args[0].Path.segments[0].name);
    try testing.expectEqualStrings(composer_param, emit.args[1].Path.segments[0].name);
    try testing.expectEqual(@as(i64, 0), emit.args[2].IntLit.value);
}

test "positionalKey is stable per span and fits Int" {
    const s1 = Span.init(span_mod.FileId.from(3), 10, 20);
    const s2 = Span.init(span_mod.FileId.from(3), 10, 21);
    try testing.expectEqual(positionalKey(s1), positionalKey(s1));
    try testing.expect(positionalKey(s1) != positionalKey(s2));
    try testing.expect(positionalKey(s1) >= std.math.minInt(i32) and positionalKey(s1) <= std.math.maxInt(i32));
}

test "transform injects composer/changed params and brackets the body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // @Composable fun App(x: Int) { Text("hi") }
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    var app_params = [_]Param{.{
        .name = dummyIdent("x"),
        .ty = .{ .name = dummyIdent("Int"), .nullable = false, .span = gsp, .type_args = &.{}, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null },
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = gsp,
    }};
    // body: Text("hi")
    var text_segs = [_]Ident{dummyIdent("Text")};
    var text_callee = Expr{ .Path = .{ .segments = &text_segs, .span = gsp } };
    var str_parts = [_]ast.StringPart{.{ .Text = "hi" }};
    var text_args = [_]Expr{.{ .StringTemplate = .{ .parts = &str_parts, .span = gsp } }};
    var text_argnames = [_]?[]const u8{null};
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &text_callee,
        .args = &text_args,
        .arg_names = &text_argnames,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = Span.init(span_mod.FileId.from(0), 300, 310),
    } } }};
    const app = emptyFn("App", &app_params, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);

    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &app, allComposable, &ctx, null, false, null);

    // Signature gained the two synthetic params.
    try testing.expectEqual(@as(usize, 3), out.params.len);
    try testing.expectEqualStrings("x", out.params[0].name.name);
    try testing.expectEqualStrings(composer_param, out.params[1].name.name);
    try testing.expectEqualStrings("Composer", out.params[1].ty.name.name);
    try testing.expectEqualStrings(changed_param, out.params[2].name.name);

    const stmts = out.body.?.Block.stmts;
    // startRestartGroup + $dirty decl + probe(x) + skip-if + endRestartGroup.
    try testing.expectEqual(@as(usize, 5), stmts.len);
    // First stmt: $composer.startRestartGroup(<key>)
    try testing.expectEqualStrings("startRestartGroup", stmts[0].Expr.Call.callee.Member.name.name);
    try testing.expectEqualStrings(composer_param, stmts[0].Expr.Call.callee.Member.receiver.Path.segments[0].name);
    // Skip calculus: `var $dirty = $changed and 1`, then one probe per param.
    try testing.expectEqualStrings(dirty_local, stmts[1].Decl.Property.name.name);
    try testing.expect(stmts[1].Decl.Property.mutable);
    const probe = stmts[2].Assign.value.Call;
    try testing.expectEqualStrings("or", probe.callee.Member.name.name);
    try testing.expectEqualStrings("changed", probe.args[0].If.cond.Call.callee.Member.name.name);
    try testing.expectEqualStrings("x", probe.args[0].If.cond.Call.args[0].Path.segments[0].name);
    // The skip if: body in the then-block, skipToGroupEnd in the else.
    const skip_if = stmts[3].Expr.If;
    try testing.expectEqualStrings(
        "skipToGroupEnd",
        skip_if.else_branch.?.Block.stmts[0].Expr.Call.callee.Member.name.name,
    );
    // The Text call gained 2 trailing args (composer + changed).
    const text_call = wrappedBodyStmts(&out)[0].Expr.Call;
    try testing.expectEqual(@as(usize, 3), text_call.args.len);
    try testing.expectEqualStrings(composer_param, text_call.args[1].Path.segments[0].name);
    try testing.expectEqual(@as(i64, 0), text_call.args[2].IntLit.value);
    // Last stmt: endRestartGroup()?.updateScope { ... }
    const upd = stmts[4].Expr.Call;
    try testing.expect(upd.callee.Member.safe);
    try testing.expectEqualStrings("updateScope", upd.callee.Member.name.name);
    try testing.expectEqualStrings("endRestartGroup", upd.callee.Member.receiver.Call.callee.Member.name.name);
}

test "defaulted composable param becomes marker-guarded prologue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // @Composable fun App(x: Int = 5) { }
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    var five = Expr{ .IntLit = .{ .value = 5, .kind = .Int, .span = gsp } };
    var app_params = [_]Param{.{
        .name = dummyIdent("x"),
        .ty = .{ .name = dummyIdent("Int"), .nullable = false, .span = gsp, .type_args = &.{}, .function = null, .definitely_non_null = false, .annotations = &.{}, .qualified_path = null },
        .default = &five,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = gsp,
    }};
    var body_stmts = [_]Stmt{};
    const app = emptyFn("App", &app_params, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);

    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &app, allComposable, &ctx, null, false, null);

    // The param is renamed and its default is the marker call.
    try testing.expectEqualStrings("x$arg", out.params[0].name.name);
    const marker = out.params[0].default.?.Call;
    const seg = marker.callee.Path.segments;
    try testing.expectEqualStrings("klioComposableDefaultMarker", seg[seg.len - 1].name);

    // Body: startRestartGroup, `val x = if (x$arg === marker()) 5 else x$arg`,
    // $dirty decl, probe(x), skip-if, endRestartGroup?.updateScope.
    const stmts = out.body.?.Block.stmts;
    try testing.expectEqual(@as(usize, 6), stmts.len);
    const prop = stmts[1].Decl.Property;
    try testing.expectEqualStrings("x", prop.name.name);
    const pick = prop.init.?.If;
    try testing.expect(pick.cond.Binary.op == .IdentEq);
    try testing.expectEqualStrings("x$arg", pick.cond.Binary.lhs.Path.segments[0].name);
    try testing.expectEqual(@as(i64, 5), pick.then_branch.IntLit.value);
    try testing.expectEqualStrings("x$arg", pick.else_branch.?.Path.segments[0].name);

    // The probe reads the RESOLVED value `x`, not the renamed argument.
    try testing.expectEqualStrings("x", stmts[3].Assign.value.Call.args[0].If.cond.Call.args[0].Path.segments[0].name);
    // The restart re-call passes the RENAMED param (marker flows through).
    const upd = stmts[5].Expr.Call;
    const lam = upd.args[0].Lambda;
    const reinvoke = lam.body.stmts[0].Expr.Call;
    try testing.expectEqualStrings("x$arg", reinvoke.args[0].Path.segments[0].name);
}

test "threadCall appends the composer pair as named args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    var text_segs = [_]Ident{dummyIdent("Text")};
    var text_callee = Expr{ .Path = .{ .segments = &text_segs, .span = gsp } };
    var text_argnames = [_]?[]const u8{};
    var call = Expr{ .Call = .{
        .callee = &text_callee,
        .args = &.{},
        .arg_names = &text_argnames,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = gsp,
    } };
    var ctx: u8 = 0;
    var w = Walker{ .a = a, .b = .{ .a = a, .gen_span = gsp }, .oracle = allComposable, .oracle_ctx = &ctx };
    try w.walkExpr(&call);
    const c = call.Call;
    try testing.expectEqual(@as(usize, 2), c.args.len);
    try testing.expectEqualStrings(composer_param, c.arg_names[0].?);
    try testing.expectEqualStrings(changed_param, c.arg_names[1].?);
}

test "non-composable callees are not threaded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    var segs = [_]Ident{dummyIdent("println")};
    var callee = Expr{ .Path = .{ .segments = &segs, .span = gsp } };
    var no_args = [_]Expr{};
    var no_names = [_]?[]const u8{};
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &callee,
        .args = &no_args,
        .arg_names = &no_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const fnp = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);
    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &fnp, noneComposable, &ctx, null, false, null);
    // println keeps 0 args (not threaded).
    try testing.expectEqual(@as(usize, 0), wrappedBodyStmts(&out)[0].Expr.Call.args.len);
}
