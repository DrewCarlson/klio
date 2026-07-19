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
const composable_lambda_instance_path = [_][]const u8{ "androidx", "compose", "runtime", "internal", "composableLambdaInstance" };

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

/// Sink name -> the NAME of its last parameter when that parameter is the
/// composable lambda. The memo wrap turns the trailing lambda into a plain
/// call expression, which no longer binds as a trailing lambda: with
/// defaulted middle parameters it would slide into the FIRST open slot
/// positionally. Emitting the wrapped argument by name keeps the binding.
pub var active_sink_last_param: ?*const std.StringHashMap([]const u8) = null;

pub fn collectComposableSinkLastParam(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap([]const u8) {
    var set = std.StringHashMap([]const u8).init(a);
    try collectSinkLastParamInto(&set, decls);
    return set;
}

pub fn collectSinkLastParamInto(set: *std.StringHashMap([]const u8), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            if (f.params.len != 0) {
                const lp = &f.params[f.params.len - 1];
                if (lp.ty.function != null and isComposable(lp.ty.annotations)) {
                    try set.put(f.name.name, lp.name.name);
                }
            }
        },
        .Class => |*c| {
            if (c.primary_params.len != 0) {
                const lp = &c.primary_params[c.primary_params.len - 1];
                if (lp.ty.function != null and isComposable(lp.ty.annotations)) {
                    try set.put(c.name.name, lp.name.name);
                }
            }
            try collectSinkLastParamInto(set, c.members);
        },
        .Object => |*o| try collectSinkLastParamInto(set, o.members),
        else => {},
    };
}

/// Names of INLINE functions in the compile universe. A composable call is
/// legal inside a lambda argument only when the callee inlines it (the body
/// splices into the composable caller) or the parameter is composable (the
/// sink path): a plain callback lambda (`DisposableEffect { … }`) is not a
/// composable scope, and threading it emits composer traffic that runs
/// POST-composition through the captured outer composer.
pub var active_inline_fns: ?*const std.StringHashMap(void) = null;

/// Collect the names of `inline fun` declarations (top-level and members).
pub fn collectInlineFnNames(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    try collectInlineFnNamesInto(&set, decls);
    return set;
}

pub fn collectInlineFnNamesInto(set: *std.StringHashMap(void), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            if (f.is_inline) try set.put(f.name.name, {});
        },
        .Class => |*c| try collectInlineFnNamesInto(set, c.members),
        .Object => |*o| try collectInlineFnNamesInto(set, o.members),
        else => {},
    };
}

/// Common Kotlin stdlib inline higher-order functions. The stdlib lowers
/// from a baked image, so its `inline` modifiers are not in the collected
/// AST universe; these names splice their lambdas and keep the composable
/// scope.
const stdlib_inline_hofs = [_][]const u8{
    "let",           "run",        "with",       "apply",     "also",
    "takeIf",        "takeUnless", "repeat",     "use",       "synchronized",
    "forEach",       "forEachIndexed", "onEach", "map",       "mapIndexed",
    "mapNotNull",    "filter",     "filterNot",  "flatMap",   "fold",
    "sumOf",         "count",      "any",        "all",       "none",
    "first",         "firstOrNull", "last",      "lastOrNull", "find",
    "indexOfFirst",  "indexOfLast", "groupBy",   "associateBy", "associateWith",
    "getOrElse",     "getOrPut",   "buildString", "buildList", "buildSet",
    "buildMap",      "maxOf",      "minOf",      "runCatching", "withLock",
    "measureTime",   "fastForEach", "fastForEachIndexed", "fastMap", "fastAny",
    "fastFilter",    "fastGroupBy", "fastFirstOrNull", "trace", "sortedBy",
    "joinToString",  "removeIf",   "partition",  "single",    "singleOrNull",
};

/// Whether a lambda argument of a call to `name` keeps the composable
/// scope: the callee inlines the lambda (collected decls or the stdlib
/// list). Sink last-params are handled before this on the sink path.
fn calleeInlinesLambda(name: []const u8) bool {
    if (active_inline_fns) |ifns| {
        if (ifns.contains(name)) return true;
    }
    for (stdlib_inline_hofs) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
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

// --------------------------------------------------------------------------
// Stability inference
// --------------------------------------------------------------------------

/// The Compose plugin's per-class stability classification. A composable whose
/// value parameters (and receiver) are all STABLE gets the skip calculus; one
/// with ANY unstable parameter is "restartable but not skippable" — it keeps
/// its restart scope but emits no `changed()` probes and never skips, so an
/// invalidation of an enclosing scope re-runs it even when the parameter
/// INSTANCE is unchanged (a mutated model object still recomposes through it).
/// `stable_annotated` (`@Stable`/`@Immutable`) is unconditionally stable;
/// inferred `stable` still requires stable type arguments at the use site.
pub const Stability = enum { unstable, stable, stable_annotated };

/// Class-name → stability registry for the current transform run, built by
/// `collectClassStability` over the module's declarations (plus the baked
/// base's). Null (unit tests, no registry) treats every type as stable.
pub var active_stability: ?*const std.StringHashMap(Stability) = null;

/// Delegate factories whose backing field is a stable snapshot-state object:
/// `var x by mutableStateOf(…)` keeps the declaring class stable (the field
/// is a `MutableState`, itself `@Stable`).
const stable_delegate_factories = [_][]const u8{
    "mutableStateOf",
    "mutableIntStateOf",
    "mutableLongStateOf",
    "mutableFloatStateOf",
    "mutableDoubleStateOf",
};

const stable_builtin_types = [_][]const u8{
    "Int",    "Long",   "Short", "Byte",    "Char",  "Boolean",
    "Float",  "Double", "String", "Unit",   "Nothing",
    "UInt",   "ULong",  "UShort", "UByte",
};

fn isStableBuiltinType(name: []const u8) bool {
    for (stable_builtin_types) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn hasStableAnnotation(annotations: []const ast.Annotation) bool {
    for (annotations) |ann| {
        if (ann.path.len == 0) continue;
        const nm = ann.path[ann.path.len - 1].name;
        if (std.mem.eql(u8, nm, "Stable")) return true;
        if (std.mem.eql(u8, nm, "Immutable")) return true;
        if (std.mem.eql(u8, nm, "StableMarker")) return true;
    }
    return false;
}

fn isTypeParamName(name: []const u8, tps: []const ast.TypeParam) bool {
    for (tps) |*tp| if (std.mem.eql(u8, tp.name.name, name)) return true;
    return false;
}

/// Build the class-stability registry over every class/object/typealias in
/// `module_decls` + `base_decls` (nested declarations included). Caller owns
/// the returned map. Same-simple-name collisions keep the weaker verdict.
pub fn collectClassStability(
    a: std.mem.Allocator,
    module_decls: []const Decl,
    base_decls: []const Decl,
) std.mem.Allocator.Error!std.StringHashMap(Stability) {
    var cls = StabilityClassifier{
        .classes = std.StringHashMap(*const ast.Class).init(a),
        .objects = std.StringHashMap(*const ast.ObjectDecl).init(a),
        .aliases = std.StringHashMap(*const ast.TypeAlias).init(a),
        .memo = std.StringHashMap(Stability).init(a),
        .in_progress = std.StringHashMap(void).init(a),
    };
    defer cls.classes.deinit();
    defer cls.objects.deinit();
    defer cls.aliases.deinit();
    defer cls.in_progress.deinit();
    try cls.index(module_decls);
    try cls.index(base_decls);
    var it = cls.classes.keyIterator();
    while (it.next()) |k| _ = try cls.classifyName(k.*);
    var oit = cls.objects.keyIterator();
    while (oit.next()) |k| _ = try cls.classifyName(k.*);
    var ait = cls.aliases.keyIterator();
    while (ait.next()) |k| _ = try cls.classifyName(k.*);
    return cls.memo;
}

const StabilityClassifier = struct {
    classes: std.StringHashMap(*const ast.Class),
    objects: std.StringHashMap(*const ast.ObjectDecl),
    aliases: std.StringHashMap(*const ast.TypeAlias),
    memo: std.StringHashMap(Stability),
    in_progress: std.StringHashMap(void),

    fn index(self: *StabilityClassifier, decls: []const Decl) std.mem.Allocator.Error!void {
        for (decls) |*d| switch (d.*) {
            .Class => |*c| {
                const gop = try self.classes.getOrPut(c.name.name);
                if (!gop.found_existing) gop.value_ptr.* = c;
                try self.index(c.members);
            },
            .Object => |*o| {
                const gop = try self.objects.getOrPut(o.name.name);
                if (!gop.found_existing) gop.value_ptr.* = o;
                try self.index(o.members);
            },
            .TypeAlias => |*t| {
                const gop = try self.aliases.getOrPut(t.name.name);
                if (!gop.found_existing) gop.value_ptr.* = t;
            },
            else => {},
        };
    }

    fn classifyName(self: *StabilityClassifier, name: []const u8) std.mem.Allocator.Error!Stability {
        if (self.memo.get(name)) |s| return s;
        if (self.in_progress.contains(name)) return .stable; // recursive back-edge
        try self.in_progress.put(name, {});
        defer _ = self.in_progress.remove(name);
        const result: Stability = blk: {
            if (self.classes.get(name)) |c| break :blk try self.classifyClass(c);
            if (self.objects.get(name)) |o| break :blk try self.classifyObject(o);
            if (self.aliases.get(name)) |t| {
                break :blk if (try self.typeStable(&t.target, t.type_params)) .stable else .unstable;
            }
            break :blk .unstable;
        };
        try self.memo.put(name, result);
        return result;
    }

    fn typeStable(self: *StabilityClassifier, t: *const TypeRef, tps: []const ast.TypeParam) std.mem.Allocator.Error!bool {
        if (t.function != null) return true; // function types are stable
        const n = t.name.name;
        if (isTypeParamName(n, tps)) return false;
        if (isStableBuiltinType(n)) return true;
        switch (try self.classifyName(n)) {
            .stable_annotated => return true,
            .unstable => return false,
            .stable => {
                for (t.type_args) |*ta| {
                    if (ta.is_star) return false;
                    if (!try self.typeStable(&ta.ty, tps)) return false;
                }
                return true;
            },
        }
    }

    fn classifyClass(self: *StabilityClassifier, c: *const ast.Class) std.mem.Allocator.Error!Stability {
        if (hasStableAnnotation(c.annotations)) return .stable_annotated;
        if (c.is_enum) return .stable;
        if (c.is_interface or c.is_fun_interface or c.is_annotation) return .unstable;
        if (c.is_open or c.is_abstract or c.is_sealed) return .unstable;
        // A class supertype (ctor-call form) folds its own stability in;
        // interface supertypes carry no state and are ignored.
        for (c.supertypes, c.supertype_args) |*st, sa| {
            if (sa == null) continue;
            switch (try self.classifyName(st.name.name)) {
                .unstable => return .unstable,
                else => {},
            }
        }
        for (c.primary_params) |*p| {
            const is_prop = p.property orelse continue;
            if (is_prop) return .unstable; // `var` constructor property
            if (!try self.typeStable(&p.ty, c.type_params)) return .unstable;
        }
        if (!try self.membersStable(c.members, c.type_params)) return .unstable;
        return .stable;
    }

    fn classifyObject(self: *StabilityClassifier, o: *const ast.ObjectDecl) std.mem.Allocator.Error!Stability {
        if (!try self.membersStable(o.members, &.{})) return .unstable;
        return .stable;
    }

    fn membersStable(self: *StabilityClassifier, members: []const Decl, tps: []const ast.TypeParam) std.mem.Allocator.Error!bool {
        for (members) |*m| {
            if (m.* != .Property) continue;
            const p = m.Property;
            if (p.receiver_type != null) continue; // extension member: no backing field
            if (p.delegate) |del| {
                if (delegateFactoryStable(del)) continue;
                return false;
            }
            // Computed property (getter, no backing field) carries no state.
            if (p.getter != null and p.init == null and p.explicit_field == null) continue;
            if (p.mutable) return false;
            if (p.ty) |*ty| {
                if (!try self.typeStable(ty, tps)) return false;
            } else if (p.init) |*ini| {
                if (!literalStable(ini)) return false;
            }
        }
        return true;
    }
};

fn delegateFactoryStable(e: *const Expr) bool {
    if (e.* != .Call) return false;
    const nm = calleeSimpleName(e.Call.callee) orelse return false;
    for (stable_delegate_factories) |f| if (std.mem.eql(u8, f, nm)) return true;
    return false;
}

fn literalStable(e: *const Expr) bool {
    return switch (e.*) {
        .IntLit, .FloatLit, .BoolLit, .CharLit => true,
        .StringTemplate => |st| blk: {
            for (st.parts) |part| if (part == .Interp) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

/// Registry-only stability check for a parameter type at transform time
/// (`active_stability` is the finished map; no recursion into declarations).
fn typeStableFromMap(map: *const std.StringHashMap(Stability), t: *const TypeRef, tps: []const ast.TypeParam) bool {
    if (t.function != null) return true;
    const n = t.name.name;
    if (isTypeParamName(n, tps)) return false;
    if (isStableBuiltinType(n)) return true;
    switch (map.get(n) orelse .unstable) {
        .stable_annotated => return true,
        .unstable => return false,
        .stable => {
            for (t.type_args) |*ta| {
                if (ta.is_star) return false;
                if (!typeStableFromMap(map, &ta.ty, tps)) return false;
            }
            return true;
        },
    }
}

/// Whether the plugin gives `f` the skip calculus: every value parameter, the
/// extension receiver, and the enclosing class (for a member) must be stable.
/// No registry (`active_stability == null`) keeps the legacy all-stable
/// behavior for direct unit-test callers.
fn fnIsSkippable(f: *const Function, in_class: bool, enclosing_class: ?[]const u8) bool {
    const map = active_stability orelse return true;
    if (f.receiver_type) |*rt| {
        if (!typeStableFromMap(map, rt, f.type_params)) return false;
    }
    if (in_class) {
        const ec = enclosing_class orelse return false;
        switch (map.get(ec) orelse Stability.unstable) {
            .unstable => return false,
            else => {},
        }
    }
    for (f.params) |*p| {
        if (p.is_vararg) continue; // keeps its own always-recompose arm
        if (isComposableLambdaParam(p)) continue;
        if (!typeStableFromMap(map, &p.ty, f.type_params)) return false;
    }
    return true;
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
            if (f.body == null) return;
            if (isComposable(f.annotations)) {
                if (isRestartableComposable(f)) {
                    f.* = try transformComposableFunction(a, f, NameSetOracle.isComposableCall, oracle, sinks, in_class, null, enclosing_class);
                } else {
                    f.* = try transformThreadedComposable(a, f, NameSetOracle.isComposableCall, oracle, sinks, null);
                }
            } else {
                // Not composable: still walk the body so a `compose { … }` /
                // `setContent { … }` composable-lambda argument is transformed.
                const ret_composable = f.return_type != null and isComposableFnType(&f.return_type.?);
                const ret_fn_params: u8 = if (ret_composable) @intCast(@min(f.return_type.?.function.?.params.len, 255)) else 0;
                const wrap_ret = ret_composable and std.mem.startsWith(u8, f.name.name, "movableContent");
                // A NON-composable fn can still take `@Composable`-typed
                // lambda params (`movableContentOf(content)`): a bare
                // `content()` inside one of its composable lambdas (the
                // ctor-sink wrapper `MovableContent({ content() })`) is a
                // composable call and must thread.
                const lp = a.create(std.StringHashMap(void)) catch @panic("oom");
                lp.* = try composableLambdaParamNames(a, f);
                var w = Walker{ .a = a, .b = .{ .a = a, .gen_span = f.span }, .oracle = NameSetOracle.isComposableCall, .oracle_ctx = oracle, .sinks = sinks, .thread = false, .ret_composable = ret_composable, .ret_fn_params = ret_fn_params, .lambda_params = lp, .wrap_ret_lambda = wrap_ret };
                if (f.body) |*fb| switch (fb.*) {
                    .Block => |*blk| try w.walkBlock(blk),
                    .Expr => |*e| if (ret_composable and e.* == .Lambda) {
                        try w.transformComposableLambda(&e.Lambda, ret_fn_params, null);
                        if (emit_lambda_memo and w.wrap_ret_lambda) w.wrapInComposableLambdaInstance(e);
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

/// Guard a marker-defaulted param's skip-calculus probe with
/// `if (p$arg !== marker()) { <probe> }`. A parameter that fell back to its
/// default value is NOT probed: kotlinc's `$default`-mask path sets the dirty
/// bits directly and never emits a `composer.changed()` for it, so probing it
/// here would store an extra slot the compiler never stores (the slot-size
/// validation tests count exactly these). The default's own composition-local
/// / snapshot-state reads still invalidate the scope when they change, so
/// skipping the probe does not lose recomposition. A defaulted param that the
/// caller DID pass (`p$arg !== marker()`) is probed normally, matching the
/// compiler's uncertain-bits path.
fn dirtyProbeIfPassed(b: B, arg_name: []const u8, probe: Stmt) Stmt {
    const not_default = Expr{ .Binary = .{
        .op = .IdentNeq,
        .lhs = b.box(b.pathExpr(arg_name)),
        .rhs = b.box(markerCall(b)),
        .span = b.gen_span,
    } };
    const then_stmts = b.a.alloc(Stmt, 1) catch @panic("oom");
    then_stmts[0] = probe;
    return .{ .Expr = .{ .If = .{
        .cond = b.box(not_default),
        .then_branch = b.box(.{ .Block = .{ .stmts = then_stmts, .span = b.gen_span } }),
        .else_branch = null,
        .span = b.gen_span,
    } } };
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
    enclosing_class: ?[]const u8,
) std.mem.Allocator.Error!Function {
    const b = B{ .a = a, .gen_span = f.span };
    // kotlinc parity: any unstable value parameter (or receiver) makes the
    // function restartable but NOT skippable — no probes, no skip branch.
    const skippable = emit_skip_calculus and fnIsSkippable(f, in_class, enclosing_class);

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
    if (skippable) {
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
            const probe = dirtyOrProbe(b, b.callMember(
                b.pathExpr(composer_param),
                "changed",
                b.slice1(b.pathExpr(p.name.name)),
            ));
            if (p.default != null and f.body != null) {
                const arg_name = try std.fmt.allocPrint(a, "{s}$arg", .{p.name.name});
                try out.append(a, dirtyProbeIfPassed(b, arg_name, probe));
            } else {
                try out.append(a, probe);
            }
        }
    }
    // `if ($composer.shouldExecute($dirty != 0 || !$composer.skipping,
    // $dirty and 1)) { <body> } else { $composer.skipToGroupEnd() }` —
    // the shouldExecute wrapper is what gives PausableComposition its
    // pause points (the composer pauses inserting/reusing content there
    // when the shouldPause callback says so); for ordinary composition it
    // returns its first argument unchanged.
    var body_list: std.ArrayList(Stmt) = .empty;
    for (orig_stmts) |*s| {
        try w.walkStmt(@constCast(s));
        try body_list.append(a, s.*);
    }
    // An early/conditional `return` must close the open groups on its way
    // out, exactly as the tail epilogue does on the normal path.
    {
        var inj = EpilogueInjector{ .a = a, .b = b, .fn_name = f.name.name, .value_params = params[0..f.params.len] };
        try inj.stmts(body_list.items);
    }
    if (!emit_skip_calculus) {
        for (body_list.items) |s| try out.append(a, s);
        try out.append(a, .{ .Expr = try endRestartGroupExpr(a, b, f.name.name, params[0..f.params.len]) });
        const plain_body = Block{ .stmts = try out.toOwnedSlice(a), .span = f.span };
        return withBody(f, params, .{ .Block = plain_body });
    }
    const skip_stmts = try a.alloc(Stmt, 1);
    skip_stmts[0] = .{ .Expr = b.callMember(b.pathExpr(composer_param), "skipToGroupEnd", try a.alloc(Expr, 0)) };
    // Skippable: `$dirty != 0 || !$composer.skipping`. Non-skippable keeps the
    // shouldExecute pause point but always executes (`true`), exactly as the
    // plugin emits for a restartable-but-not-skippable composable.
    const params_changed: Expr = if (skippable) .{ .Binary = .{
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
    lambda_params: ?*std.StringHashMap(void) = null,
    /// Wrap a returned composable lambda in composableLambdaInstance —
    /// enabled only for the movable-content factories today (kotlinc wraps
    /// every such return; klio gates the rollout while the general wrap's
    /// interactions are driven out).
    wrap_ret_lambda: bool = false,
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
    /// Stack of enclosing composable-lambda scopes that a `return@label` can
    /// target. A non-local return (one that names a scope other than the
    /// innermost) must close every group opened since that scope started, the
    /// way the compiler emits `$composer.endToMarker($marker)`. Lazily created.
    nlr_scopes: ?*std.ArrayList(NlrScope) = null,
    /// Monotonic source of fresh marker-local names for this walk.
    nlr_counter: usize = 0,

    /// A `return@label` target: the enclosing composable lambda labelled
    /// `label`, the local `marker_var` holding its start marker, and whether a
    /// non-local return actually referenced it (so the marker capture is only
    /// emitted when needed).
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
    /// that scope as needing its start marker and return the marker-local name
    /// to close groups back to; otherwise null (a local return closes its own
    /// groups as it unwinds normally).
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

    fn walkBlock(w: *Walker, blk: *Block) std.mem.Allocator.Error!void {
        for (blk.stmts) |*s| try w.walkStmt(s);
    }

    fn walkStmt(w: *Walker, s: *Stmt) std.mem.Allocator.Error!void {
        switch (s.*) {
            // A statement-position `if`/`when` discards its value, so an
            // EXPRESSION-shaped branch (`if (c) parent { … } else parent
            // { … }` — no braces) can be boxed into a Block and take the
            // per-branch replaceable group like a braced branch. An
            // expression-position conditional keeps the Block-only rule —
            // its value must not be displaced.
            .Expr => |*e| {
                try w.walkExpr(e);
                if (w.thread) w.wrapStatementConditional(e);
            },
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
                // declared type makes the initializer lambda composable —
                // or `val content = @Composable { … }`, where the literal
                // carries the annotation itself.
                if (p.init) |*ini| {
                    if (ini.* == .Lambda and p.ty != null and isComposableFnType(&p.ty.?)) {
                        try w.transformComposableLambda(&ini.Lambda, @intCast(@min(p.ty.?.function.?.params.len, 255)), null);
                    } else if (ini.* == .Lambda and isComposable(ini.Lambda.annotations)) {
                        // No declared type: the literal's own header is the
                        // arity, and a headerless literal is `() -> Unit`
                        // (its parser-injected `it` never binds without an
                        // expected type).
                        const arity: u8 = if (ini.Lambda.implicit_it) 0 else @intCast(@min(ini.Lambda.params.len, 255));
                        try w.transformComposableLambda(&ini.Lambda, arity, null);
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
                    if (p.init) |*ini2| {
                        if (ini2.* == .Lambda and isComposable(ini2.Lambda.annotations)) break :blk true;
                    }
                    // `val current by rememberUpdatedState(content)` — a
                    // DELEGATED val whose delegate call carries a value the
                    // walker already knows is composable reads back that
                    // value: `current()` must thread like `content()`.
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
                        f.* = try transformComposableFunction(w.a, f, w.oracle, w.oracle_ctx, w.sinks, false, w.locals, null);
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
                        if (emit_lambda_memo and w.wrap_ret_lambda) w.wrapInComposableLambdaInstance(e);
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

    /// A composable lambda RETURNED by a (non-composable) factory has no
    /// `$composer` in scope: kotlinc wraps it in
    /// `composableLambdaInstance(key, true, block)` — a ComposableLambdaImpl
    /// whose invoke supplies the RESTART GROUP each call site needs
    /// (`movableContentOf`'s wrapper: without it, `content(n)` composes the
    /// movable group with no restart bracket and multi-insert positioning
    /// breaks).
    fn wrapInComposableLambdaInstance(w: *Walker, arg: *Expr) void {
        const key = positionalKey(exprSpanOf(arg));
        const args = w.a.alloc(Expr, 3) catch @panic("oom");
        args[0] = w.b.intLit(key);
        args[1] = .{ .BoolLit = .{ .value = true, .span = w.b.gen_span } };
        args[2] = arg.*;
        arg.* = w.b.call(w.b.pathExprSegs(&composable_lambda_instance_path), args);
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
    /// Statement-position conditional: box each EXPRESSION-shaped branch
    /// holding composable content into a Block, then bracket it with the
    /// per-branch replaceable group (braced branches were already wrapped
    /// by the expression walk). Recurses down `else if` chains — every
    /// arm of a statement conditional is statement-position too.
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
                    }
                }
            },
            .When => |*wh| {
                var any = false;
                for (wh.branches) |*br| {
                    if (w.branchHasComposable(&br.body)) any = true;
                }
                if (any) {
                    for (wh.branches) |*br| w.wrapBranchBoxed(&br.body);
                }
            },
            else => {},
        }
    }

    /// `wrapBranchInReplaceGroup`, boxing a non-Block branch into a
    /// single-statement Block first. Idempotent for already-wrapped
    /// blocks (their first stmt is the startReplaceGroup call).
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

    /// Rewrite a (threaded) `key(k…, block, …)` call into
    ///     { $composer.startMovableGroup(<site key>, <joined keys>)
    ///       val $key$v = key(…)
    ///       $composer.endMovableGroup()
    ///       $key$v }
    /// `dyn_n` is the count of dynamic key arguments (the original args
    /// before the content lambda). Multiple keys join pairwise through
    /// `$composer.joinKey`, exactly as the plugin emits.
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
                // `key(k…) { content }` before its args gain the composer
                // pair: the dynamic key count is every argument before the
                // trailing content lambda.
                const key_dyn_n: usize = if (c.args.len >= 2) c.args.len - 1 else 0;
                const is_key_call = w.thread and name != null and
                    std.mem.eql(u8, name.?, "key") and key_dyn_n >= 1 and
                    c.args[c.args.len - 1] == .Lambda and w.oracle(w.oracle_ctx, "key");
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
                // A call THROUGH a composable-lambda VALUE (a movableContentOf
                // val, a composable lambda param) is a composable call too:
                // its trailing lambda binds a `@Composable`-typed parameter
                // (`parent { Wrap { child() } }` where `parent` came from
                // `movableContentOf<@Composable () -> Unit>`), so it must be
                // transformed like a named sink's. Threaded scope only — the
                // same bare name outside composition (a validator block) is a
                // different declaration.
                const val_sink = name != null and w.thread and
                    ((w.composable_vals != null and w.composable_vals.?.contains(name.?)) or
                        (w.locals != null and w.locals.?.contains(name.?)) or
                        (w.lambda_params != null and w.lambda_params.?.contains(name.?)));
                // The trailing lambda may carry an explicit label
                // (`InlineLinear outer@{ … }`), which the parser wraps in a
                // `Labeled` node. Unwrap it to reach the lambda so the labeled
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
                        var exp: ?u8 = if (active_sink_arity) |sa| sa.get(name.?) else null;
                        // `movableContentOf` / `movableContentWithReceiverOf`
                        // are OVERLOADED on the lambda's parameter count
                        // (`() -> Unit` vs `(P) -> Unit` … `R.(P1..P3)`); the
                        // name-keyed sink-arity map conflates them, and a
                        // spurious synthetic `it` shifts the invoke protocol
                        // (the 3-param block is invoked 2-arg and `$composer`
                        // receives the Int dirty flag). Explicit call-site
                        // type args name the overload exactly (the receiver
                        // form spends its first type arg on R, not a lambda
                        // param); otherwise a headerless lambda IS the
                        // 0-param overload — kotlinc cannot infer `P` from a
                        // headerless literal, so a bare `it` inside belongs
                        // to an ENCLOSING implicit-`it` lambda
                        // (`Array(4) { movableContentOf { level[it * 2]() } }`),
                        // never to this one.
                        const is_mco = std.mem.eql(u8, name.?, "movableContentOf");
                        const is_mcwro = std.mem.eql(u8, name.?, "movableContentWithReceiverOf");
                        if ((is_mco or is_mcwro) and sink_lam.implicit_it) {
                            if (c.type_args.len != 0) {
                                const ta: u8 = @intCast(@min(c.type_args.len, 255));
                                exp = if (is_mcwro) ta - 1 else ta;
                            } else {
                                exp = 0;
                            }
                        }
                        // A movable-content type arg that is ITSELF a
                        // `@Composable` function type makes the lambda param
                        // at that position a composable value: a bare
                        // `child()` in the body must thread the composer
                        // (`movableContentOf<@Composable () -> Unit> {
                        // child -> Wrap { child() } }`). Record those param
                        // names in the walker's lambda-param set for the
                        // body walk, scoped — remove after unless already
                        // present.
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
                        // Wrap only content that actually COMPOSES: the
                        // name-keyed sink also catches sibling overloads'
                        // plain trailing lambdas (ComposeNode's update),
                        // whose wrapped invoke shape would not exist. An
                        // INLINE composable's lambda stays raw — kotlinc
                        // splices it into the caller's group and never wraps
                        // it; wrapping also re-parents the lambda under
                        // `composableLambda(..)`, so its implicit label no
                        // longer matches and a `return@InlineWrapper` inside
                        // unwound non-locally past ComposableLambdaImpl.invoke,
                        // leaving the root restart group open (the
                        // conditional-return "Start/end imbalance" family).
                        // A movable-content FACTORY call outside composition
                        // (`val c = movableContentOf { … }` in a test fn)
                        // still stores its content as a
                        // composableLambdaInstance singleton — that wrapper
                        // supplies the restart group the movable machinery
                        // re-invokes on nested recompose; a raw threaded
                        // closure has none and the group walk diverges
                        // ("Started group at N must be a subgroup ...").
                        if (!w.thread and emit_lambda_memo and (is_mco or is_mcwro)) {
                            w.wrapInComposableLambdaInstance(arg);
                        }
                        if (w.thread and emit_lambda_memo and w.branchHasComposable(arg) and
                            !calleeInlinesLambda(name.?))
                        {
                            w.wrapInComposableLambda(arg);
                            // The wrapped argument is no longer a lambda:
                            // bind it by the sink's last-parameter name so a
                            // defaulted middle parameter cannot absorb it
                            // positionally.
                            if (active_sink_last_param) |lp| {
                                if (lp.get(name.?)) |pname| {
                                    const names = w.a.alloc(?[]const u8, c.args.len) catch @panic("oom");
                                    for (0..c.args.len) |k| {
                                        names[k] = if (k < c.arg_names.len) c.arg_names[k] else null;
                                    }
                                    names[c.args.len - 1] = pname;
                                    c.arg_names = names;
                                }
                            }
                        }
                    } else if (arg.* == .Lambda and w.thread and name != null and
                        !calleeInlinesLambda(name.?))
                    {
                        // A plain callback lambda at a non-inline callee
                        // (`DisposableEffect { … }`, `LaunchedEffect { … }`)
                        // is not a composable scope: kotlinc only admits
                        // composable calls through inline splices or
                        // composable parameters. Threading it emits memo
                        // wraps and composer brackets that execute AFTER
                        // composition through the captured outer composer,
                        // leaving unapplied change ops behind.
                        const saved = w.thread;
                        w.thread = false;
                        try w.walkExpr(arg);
                        w.thread = saved;
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
                        const positional = emit_lambda_memo and (is_lambda_param or is_composable_prop or is_composable_val or is_local_composable);
                        if (positional or is_composable_val or is_local_composable or w.oracle(w.oracle_ctx, nm)) try w.threadCall(c, positional);
                    }
                }
                // `key(k…) { content }` is a COMPILER intrinsic: kotlinc
                // brackets it with a MOVABLE group whose data key joins the
                // dynamic key arguments, so a changed key replaces (or moves)
                // the content's group identity. The upstream function body is
                // just `block()` — without the bracket the dynamic keys are
                // ignored entirely (a `key(k)` flip recomposed in place and
                // reported "no changes").
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
            .Return => |*r| {
                if (r.value) |v| {
                    if (w.ret_composable and v.* == .Lambda) {
                        try w.transformComposableLambda(&v.Lambda, w.ret_fn_params, null);
                        if (emit_lambda_memo and w.wrap_ret_lambda) w.wrapInComposableLambdaInstance(v);
                    } else {
                        try w.walkExpr(v);
                    }
                }
                // A non-local `return@label` unwinds past composable calls whose
                // groups were opened after the target scope started; close them
                // first with `$composer.endToMarker($marker)`, mirroring the
                // compiler's epilogue. Emitted as `{ endToMarker(m); <return> }`.
                if (w.thread) if (w.nlrReturnMarker(r.label)) |marker_var| {
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
                // `when` branches take the same per-branch REPLACEABLE
                // GROUP as `if` branches (see the `.If` arm): conditional
                // composable content needs a slot-alignment bracket per
                // branch, or a branch flip cannot replace its content
                // atomically. Statement-shaped (Block) branches only.
                if (w.thread and any_composable) {
                    for (wh.branches) |*br| w.wrapBranchInReplaceGroup(&br.body);
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
    fn transformComposableLambda(w: *Walker, lam: anytype, expected_params: ?u8, label: ?[]const u8) std.mem.Allocator.Error!void {
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
        // A labeled early return (`return@run`) crossing a wrapped branch
        // bracket must close the replace-groups it exits; the content
        // lambda's restart group belongs to ComposableLambdaImpl, so only
        // replace-groups close here.
        {
            var inj = EpilogueInjector{ .a = w.a, .b = w.b, .fn_name = "", .value_params = &.{}, .has_restart = false };
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

    /// Append `($composer = <composer>, $changed = <childChanged>)` to a
    /// resolved @Composable call. The pair is passed by NAME: the callee may
    /// declare defaulted params between the caller's positional args and the
    /// synthetic pair (`Test(number: Int = …, $composer, $changed)` called
    /// `Test($composer, 0)`), and a positional append would bind the composer
    /// into the first omitted param. Named, the binder slots the pair exactly
    /// and the omitted params take their defaults.
    fn threadCall(w: *Walker, c: anytype, positional: bool) std.mem.Allocator.Error!void {
        const had_trailing = c.has_trailing_lambda;
        var new_args = try w.a.alloc(Expr, c.args.len + 2);
        @memcpy(new_args[0..c.args.len], c.args);
        new_args[c.args.len] = w.composerRef();
        new_args[c.args.len + 1] = w.b.intLit(0);
        const new_names = try w.a.alloc(?[]const u8, new_args.len);
        for (new_names, 0..) |*n, i| n.* = if (i < c.arg_names.len) c.arg_names[i] else null;
        // A trailing lambda bound the callee's last function-typed parameter,
        // even across a defaulted middle parameter (`ExplicitStartReplaceGroup(
        // key, insertGroup = true) { content }` binds the lambda to `content`,
        // not `insertGroup`). Clearing `has_trailing_lambda` below and appending
        // the composer pair strips that signal: the now-plain positional lambda
        // would slide into the first open slot (`insertGroup`) and its `if
        // (insertGroup)` sees a closure. Re-emit it by the callee's last
        // parameter name so the binder rejoins it to `content` across the gap.
        if (had_trailing and c.args.len != 0 and new_names[c.args.len - 1] == null) {
            if (calleeSimpleName(c.callee)) |nm| {
                if (active_sink_last_param) |lp| {
                    if (lp.get(nm)) |pname| new_names[c.args.len - 1] = pname;
                }
            }
        }
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
/// Inject the restart epilogue before every `return` that exits the
/// restartable composable, so an early/conditional return closes its open
/// groups exactly as kotlinc's generated code does — otherwise the group is
/// left open and the next composition throws "Start/end imbalance". Each
/// injected block closes the enclosing wrapped replace-groups first (one
/// `$composer.endReplaceGroup()` per open bracket), then runs
/// `$composer.endRestartGroup()?.updateScope(..)`. Descends through control
/// flow and into lambda arguments of INLINE callees (a bare `return` there
/// is a non-local exit of the composable); a non-inline lambda, anonymous
/// fn, local fn, or local class keeps its own returns.
const EpilogueInjector = struct {
    a: std.mem.Allocator,
    b: B,
    fn_name: []const u8,
    value_params: []const Param,
    /// Whether the body being injected owns a restart bracket (a
    /// transformComposableFunction body). A content lambda's restart group
    /// belongs to ComposableLambdaImpl, so only replace-groups close there.
    has_restart: bool = true,
    /// Open wrapped replace-groups at the current descent position.
    replace_depth: usize = 0,
    /// Inline-lambda boundaries the descent entered: the callee's simple
    /// name (the implicit label of its lambda) and the replace-depth at
    /// entry, so `return@run` closes exactly the brackets opened inside.
    labels: [16]LabelEntry = undefined,
    n_labels: usize = 0,

    const LabelEntry = struct { name: []const u8, depth: usize };

    fn stmts(self: *EpilogueInjector, list: []Stmt) std.mem.Allocator.Error!void {
        for (list) |*s| try self.stmt(s);
    }

    fn stmt(self: *EpilogueInjector, s: *Stmt) std.mem.Allocator.Error!void {
        switch (s.*) {
            .Expr => |*e| try self.expr(e),
            .Assign => |*asg| {
                try self.expr(&asg.target);
                try self.expr(&asg.value);
            },
            .DestructuringDecl => |*dd| try self.expr(&dd.init),
            .Decl => |*d| switch (d.*) {
                .Property => |p| {
                    if (p.init) |*ini| try self.expr(ini);
                    if (p.delegate) |del| try self.expr(del);
                },
                // A local fn / class owns its returns.
                else => {},
            },
        }
    }

    fn block(self: *EpilogueInjector, blk: *ast.Block) std.mem.Allocator.Error!void {
        // A branch block the walker wrapped opens a replace-group whose end
        // call sits at the block's tail; a return inside must close it too.
        const wrapped = blk.stmts.len != 0 and isComposerCallStmt(&blk.stmts[0], "startReplaceGroup");
        if (wrapped) self.replace_depth += 1;
        defer if (wrapped) {
            self.replace_depth -= 1;
        };
        try self.stmts(blk.stmts);
    }

    fn expr(self: *EpilogueInjector, e: *Expr) std.mem.Allocator.Error!void {
        switch (e.*) {
            .Return => |*r| {
                if (r.value) |v| try self.expr(v);
                const ret_span = r.span;
                // How many open replace-groups this return crosses, and
                // whether it exits the composable itself (then the restart
                // epilogue runs too).
                var n_end: usize = 0;
                var exits_composable = false;
                if (r.label == null or std.mem.eql(u8, r.label.?.name, self.fn_name)) {
                    n_end = self.replace_depth;
                    exits_composable = self.has_restart;
                    if (!self.has_restart and n_end == 0) return;
                } else {
                    // `return@run`: exit crosses the brackets opened since
                    // the labeled inline lambda's entry.
                    var found = false;
                    var i: usize = self.n_labels;
                    while (i > 0) {
                        i -= 1;
                        if (std.mem.eql(u8, self.labels[i].name, r.label.?.name)) {
                            n_end = self.replace_depth - self.labels[i].depth;
                            found = true;
                            break;
                        }
                    }
                    if (!found or n_end == 0) return;
                }
                const inner = e.*;
                const extra: usize = if (exits_composable) 2 else 1;
                const list = try self.a.alloc(Stmt, n_end + extra);
                for (0..n_end) |k| {
                    list[k] = .{ .Expr = self.b.callMember(
                        self.b.pathExpr(composer_param),
                        "endReplaceGroup",
                        try self.a.alloc(Expr, 0),
                    ) };
                }
                if (exits_composable) {
                    list[n_end] = .{ .Expr = try endRestartGroupExpr(self.a, self.b, self.fn_name, self.value_params) };
                }
                list[n_end + extra - 1] = .{ .Expr = inner };
                e.* = .{ .Block = .{ .stmts = list, .span = ret_span } };
            },
            .Call => |*c| {
                try self.expr(c.callee);
                const callee_name: ?[]const u8 = if (c.callee.* == .Path and c.callee.Path.segments.len >= 1)
                    c.callee.Path.segments[c.callee.Path.segments.len - 1].name
                else if (c.callee.* == .Member)
                    c.callee.Member.name.name
                else
                    null;
                const inlines = callee_name != null and calleeInlinesLambda(callee_name.?);
                for (c.args) |*arg| {
                    switch (arg.*) {
                        .Lambda => |*lam| if (inlines) {
                            const pushed = self.n_labels < self.labels.len;
                            if (pushed) {
                                self.labels[self.n_labels] = .{ .name = callee_name.?, .depth = self.replace_depth };
                                self.n_labels += 1;
                            }
                            defer if (pushed) {
                                self.n_labels -= 1;
                            };
                            try self.block(&lam.body);
                        },
                        else => try self.expr(arg),
                    }
                }
            },
            .If => |*f| {
                try self.expr(f.cond);
                try self.expr(f.then_branch);
                if (f.else_branch) |eb| try self.expr(eb);
            },
            .When => |*wh| {
                if (wh.subject) |sub| try self.expr(sub);
                for (wh.branches) |*br| try self.expr(&br.body);
            },
            .Block => |*blk| try self.block(blk),
            .Try => |*t| {
                try self.block(&t.body);
                for (t.catches) |*ca| try self.block(&ca.body);
                if (t.finally) |*fin| try self.block(fin);
            },
            .While => |*wl| {
                try self.expr(wl.cond);
                try self.expr(wl.body);
            },
            .DoWhile => |*dw| {
                if (dw.body) |bd| try self.expr(bd);
                try self.expr(dw.cond);
            },
            .For => |*fr| {
                try self.expr(fr.iter);
                try self.expr(fr.body);
            },
            .Binary => |*bn| {
                try self.expr(bn.lhs);
                try self.expr(bn.rhs);
            },
            .Unary => |*u| try self.expr(u.expr),
            .Postfix => |*p| try self.expr(p.expr),
            .Member => |*m| try self.expr(m.receiver),
            .Index => |*ix| {
                try self.expr(ix.receiver);
                for (ix.args) |*arg| try self.expr(arg);
            },
            .Labeled => |*l| try self.expr(l.expr),
            .Throw => |*t| try self.expr(t.value),
            .IsCheck => |*ic| try self.expr(ic.expr),
            .As => |*as| try self.expr(as.expr),
            .StringTemplate => |*st| for (st.parts) |*part| switch (part.*) {
                .Interp => |ie| try self.expr(ie),
                else => {},
            },
            else => {},
        }
    }
};

/// Whether a headerless lambda body reads the implicit `it` anywhere.
fn blockUsesIt(blk: *const ast.Block) bool {
    for (blk.stmts) |*st| {
        if (stmtUsesIt(st)) return true;
    }
    return false;
}

fn stmtUsesIt(s: *const Stmt) bool {
    switch (s.*) {
        .Expr => |*e| return exprUsesIt(e),
        .Assign => |*asg| return exprUsesIt(&asg.target) or exprUsesIt(&asg.value),
        .DestructuringDecl => |*dd| return exprUsesIt(&dd.init),
        .Decl => |*d| switch (d.*) {
            .Property => |pr| {
                if (pr.init) |*ini| return exprUsesIt(ini);
                return false;
            },
            else => return false,
        },
    }
}

fn exprUsesIt(e: *const Expr) bool {
    switch (e.*) {
        .Path => |p| return p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, "it"),
        .Call => |*c| {
            if (exprUsesIt(c.callee)) return true;
            for (c.args) |*a| {
                switch (a.*) {
                    // A nested headerless lambda rebinds `it`.
                    .Lambda => {},
                    else => if (exprUsesIt(a)) return true,
                }
            }
            return false;
        },
        .If => |*f| {
            if (exprUsesIt(f.cond) or exprUsesIt(f.then_branch)) return true;
            if (f.else_branch) |eb| return exprUsesIt(eb);
            return false;
        },
        .When => |*wh| {
            if (wh.subject) |sub| if (exprUsesIt(sub)) return true;
            for (wh.branches) |*br| if (exprUsesIt(&br.body)) return true;
            return false;
        },
        .Block => |*blk| return blockUsesIt(blk),
        .Binary => |*bn| return exprUsesIt(bn.lhs) or exprUsesIt(bn.rhs),
        .Unary => |*u| return exprUsesIt(u.expr),
        .Postfix => |*p| return exprUsesIt(p.expr),
        .Member => |*m| return exprUsesIt(m.receiver),
        .Index => |*ix| {
            if (exprUsesIt(ix.receiver)) return true;
            for (ix.args) |*a| if (exprUsesIt(a)) return true;
            return false;
        },
        .StringTemplate => |*st| {
            for (st.parts) |*part| switch (part.*) {
                .Interp => |ie| if (exprUsesIt(ie)) return true,
                else => {},
            };
            return false;
        },
        .Labeled => |*l| return exprUsesIt(l.expr),
        .Throw => |*t| return exprUsesIt(t.value),
        .Return => |*r| {
            if (r.value) |v| return exprUsesIt(v);
            return false;
        },
        else => return false,
    }
}

/// Whether `s` is a bare `$composer.<name>()` call statement.
fn isComposerCallStmt(s: *const Stmt, name: []const u8) bool {
    if (s.* != .Expr) return false;
    const e = &s.Expr;
    if (e.* != .Call) return false;
    const callee = e.Call.callee;
    if (callee.* != .Member) return false;
    if (!std.mem.eql(u8, callee.Member.name.name, name)) return false;
    const recv = callee.Member.receiver;
    return recv.* == .Path and recv.Path.segments.len == 1 and
        std.mem.eql(u8, recv.Path.segments[0].name, composer_param);
}

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

/// A lambda literal argument, or a lambda wrapped in a `Labeled` node from an
/// explicit `lbl@{ … }` trailing lambda. Returns the lambda payload pointer so
/// the labeled form threads exactly like the bare one; null for a non-lambda arg.
fn trailingLambda(e: *Expr) ?*@FieldType(Expr, "Lambda") {
    return switch (e.*) {
        .Lambda => &e.Lambda,
        .Labeled => |*l| if (l.expr.* == .Lambda) &l.expr.Lambda else null,
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
    const out = try transformComposableFunction(a, &host, allComposable, &ctx, &sinks, false, null, null);
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
    const out = try transformComposableFunction(a, &host, allComposable, &ctx, null, false, null, null);
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
    const out = try transformComposableFunction(a, &app, allComposable, &ctx, null, false, null, null);

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
    const out = try transformComposableFunction(a, &app, allComposable, &ctx, null, false, null, null);

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

    // A DEFAULTED param's probe is guarded by `if (x$arg !== marker())` so a
    // param that fell back to its default stores no `changed` slot.
    const guard = stmts[3].Expr.If;
    try testing.expect(guard.cond.Binary.op == .IdentNeq);
    try testing.expectEqualStrings("x$arg", guard.cond.Binary.lhs.Path.segments[0].name);
    const probe = guard.then_branch.Block.stmts[0];
    // The probe reads the RESOLVED value `x`, not the renamed argument.
    try testing.expectEqualStrings("x", probe.Assign.value.Call.args[0].If.cond.Call.args[0].Path.segments[0].name);
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

test "threadCall re-names a trailing lambda across a defaulted gap" {
    // `ExplicitStartReplaceGroup(key) { content }` — one positional arg then a
    // trailing lambda binding the last param `content`, with a defaulted
    // `insertGroup` in between. Threading appends the composer pair and clears
    // `has_trailing_lambda`; the lambda must be re-emitted by name so it rejoins
    // `content` rather than sliding into `insertGroup`.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    var last_param = std.StringHashMap([]const u8).init(a);
    try last_param.put("ExplicitStartReplaceGroup", "content");
    active_sink_last_param = &last_param;
    defer active_sink_last_param = null;

    var callee_segs = [_]Ident{dummyIdent("ExplicitStartReplaceGroup")};
    var callee = Expr{ .Path = .{ .segments = &callee_segs, .span = gsp } };
    var lam_params: [0]Ident = .{};
    var lam_ptys: [0]?TypeRef = .{};
    var args = [_]Expr{
        .{ .IntLit = .{ .value = 42, .kind = .Int, .span = gsp } },
        .{ .Lambda = .{
            .params = &lam_params,
            .param_tys = &lam_ptys,
            .body = .{ .stmts = &.{}, .span = gsp },
            .implicit_it = false,
            .span = gsp,
        } },
    };
    var arg_names = [_]?[]const u8{ null, null };
    var call = Expr{ .Call = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &arg_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } };
    var ctx: u8 = 0;
    var w = Walker{ .a = a, .b = .{ .a = a, .gen_span = gsp }, .oracle = allComposable, .oracle_ctx = &ctx };
    try w.threadCall(&call.Call, false);
    const c = call.Call;
    try testing.expectEqual(@as(usize, 4), c.args.len);
    try testing.expect(c.arg_names[0] == null); // key stays positional
    try testing.expectEqualStrings("content", c.arg_names[1].?); // lambda re-named
    try testing.expectEqualStrings(composer_param, c.arg_names[2].?);
    try testing.expectEqualStrings(changed_param, c.arg_names[3].?);
    try testing.expect(!c.has_trailing_lambda);
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
    const out = try transformComposableFunction(a, &fnp, noneComposable, &ctx, null, false, null, null);
    // println keeps 0 args (not threaded).
    try testing.expectEqual(@as(usize, 0), wrappedBodyStmts(&out)[0].Expr.Call.args.len);
}

test "movableContentWithReceiverOf type args pick the headerless lambda's overload arity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);
    // mcwro<Int>() { … } — headerless it-free lambda; one type arg = receiver
    // only, so the block gains exactly ($composer, $changed), no `it`.
    var lam_params: [0]Ident = .{};
    var lam_ptys: [0]?TypeRef = .{};
    var call_args = [_]Expr{.{ .Lambda = .{
        .params = &lam_params,
        .param_tys = &lam_ptys,
        .body = .{ .stmts = &.{}, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } }};
    var segs = [_]Ident{dummyIdent("movableContentWithReceiverOf")};
    var callee = Expr{ .Path = .{ .segments = &segs, .span = gsp } };
    var names = [_]?[]const u8{null};
    var tas = [_]TypeRef{.{
        .name = dummyIdent("Int"),
        .nullable = false,
        .span = gsp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    }};
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &callee,
        .args = &call_args,
        .arg_names = &names,
        .type_args = &tas,
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const host = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);
    var sinks = std.StringHashMap(void).init(a);
    try sinks.put("movableContentWithReceiverOf", {});
    // Conflated name-keyed arity says 3 (the R.(P1..P3) overload) — the
    // call-site type args must override it down to 0.
    var arity = std.StringHashMap(u8).init(a);
    try arity.put("movableContentWithReceiverOf", 3);
    active_sink_arity = &arity;
    defer active_sink_arity = null;
    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &host, noneComposable, &ctx, &sinks, false, null, null);
    const call = wrappedBodyStmts(&out)[0].Expr.Call;
    const lam = call.args[call.args.len - 1].Lambda;
    try testing.expectEqual(@as(usize, 2), lam.params.len);
    try testing.expectEqualStrings(composer_param, lam.params[0].name);
    try testing.expectEqualStrings(changed_param, lam.params[1].name);
}

fn testTypeRef(name: []const u8) TypeRef {
    return .{
        .name = dummyIdent(name),
        .nullable = false,
        .span = Span.init(span_mod.FileId.from(0), 0, 0),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

fn testClassParam(name: []const u8, ty_name: []const u8, mutable_prop: ?bool) ast.ClassParam {
    return .{
        .property = mutable_prop,
        .name = dummyIdent(name),
        .ty = testTypeRef(ty_name),
        .default = null,
        .visibility = .Public,
        .is_vararg = false,
        .annotations = &.{},
        .span = Span.init(span_mod.FileId.from(0), 0, 0),
    };
}

fn testClass(name: []const u8, primary_params: []ast.ClassParam) ast.Class {
    return .{
        .name = dummyIdent(name),
        .type_params = &.{},
        .where_bounds = &.{},
        .primary_params = primary_params,
        .init_blocks = &.{},
        .init_block_positions = &.{},
        .supertypes = &.{},
        .supertype_args = &.{},
        .supertype_delegates = &.{},
        .is_data = false,
        .is_companion = false,
        .is_enum = false,
        .is_sealed = false,
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .secondary_ctors = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .is_value = false,
        .is_annotation = false,
        .is_expect = false,
        .is_actual = false,
        .enum_entries = &.{},
        .members = &.{},
        .visibility = .Public,
        .primary_ctor_visibility = null,
        .annotations = &.{},
        .span = Span.init(span_mod.FileId.from(0), 0, 0),
    };
}

test "stability: a var-bearing class is unstable, a val-only class is stable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // class Model(var contacts: String); class Point(val x: Int, val y: Int)
    var model_params = [_]ast.ClassParam{testClassParam("contacts", "String", true)};
    var point_params = [_]ast.ClassParam{
        testClassParam("x", "Int", false),
        testClassParam("y", "Int", false),
    };
    var decls = [_]Decl{
        .{ .Class = testClass("Model", &model_params) },
        .{ .Class = testClass("Point", &point_params) },
    };
    var map = try collectClassStability(a, &decls, &.{});
    defer map.deinit();
    try testing.expectEqual(Stability.unstable, map.get("Model").?);
    try testing.expectEqual(Stability.stable, map.get("Point").?);
}

test "stability: an unstable param drops the skip calculus, a stable one keeps it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    var model_params = [_]ast.ClassParam{testClassParam("contacts", "String", true)};
    var decls = [_]Decl{.{ .Class = testClass("Model", &model_params) }};
    var map = try collectClassStability(a, &decls, &.{});
    defer map.deinit();
    active_stability = &map;
    defer active_stability = null;

    var body_stmts = [_]Stmt{};
    var ctx: u8 = 0;

    // @Composable fun Show(m: Model) — restartable but NOT skippable:
    // no $dirty, no changed() probe, shouldExecute(true, $changed and 1).
    var unstable_params = [_]Param{.{
        .name = dummyIdent("m"),
        .ty = testTypeRef("Model"),
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = gsp,
    }};
    const show = emptyFn("Show", &unstable_params, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);
    const out = try transformComposableFunction(a, &show, allComposable, &ctx, null, false, null, null);
    const stmts = out.body.?.Block.stmts;
    // startRestartGroup + shouldExecute-if + endRestartGroup (no $dirty decl,
    // no probes).
    try testing.expectEqual(@as(usize, 3), stmts.len);
    const cond = stmts[1].Expr.If.cond.Call;
    try testing.expectEqualStrings("shouldExecute", cond.callee.Member.name.name);
    try testing.expect(cond.args[0].BoolLit.value);
    // The pause argument reads $changed (there is no $dirty).
    try testing.expectEqualStrings(changed_param, cond.args[1].Call.callee.Member.receiver.Path.segments[0].name);
    // The restart re-call is still emitted.
    try testing.expectEqualStrings("updateScope", stmts[2].Expr.Call.callee.Member.name.name);

    // @Composable fun ShowInt(x: Int) keeps the probe + $dirty calculus.
    var stable_params = [_]Param{.{
        .name = dummyIdent("x"),
        .ty = testTypeRef("Int"),
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = gsp,
    }};
    var body_stmts2 = [_]Stmt{};
    const show_int = emptyFn("ShowInt", &stable_params, .{ .Block = .{ .stmts = &body_stmts2, .span = gsp } }, true);
    const out2 = try transformComposableFunction(a, &show_int, allComposable, &ctx, null, false, null, null);
    const stmts2 = out2.body.?.Block.stmts;
    // startRestartGroup + $dirty + probe + skip-if + endRestartGroup.
    try testing.expectEqual(@as(usize, 5), stmts2.len);
    try testing.expectEqualStrings(dirty_local, stmts2[1].Decl.Property.name.name);
}

test "key(k) { } gains a movable-group bracket with the dynamic key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 40, 60);

    // @Composable fun Host() { key(k) { Text("hi") } }
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
    var k_segs = [_]Ident{dummyIdent("k")};
    var key_args = [_]Expr{
        .{ .Path = .{ .segments = &k_segs, .span = gsp } },
        .{ .Lambda = .{
            .params = &lam_params,
            .param_tys = &lam_ptys,
            .body = .{ .stmts = &lam_body_stmts, .span = gsp },
            .implicit_it = true,
            .span = gsp,
        } },
    };
    var key_segs = [_]Ident{dummyIdent("key")};
    var key_callee = Expr{ .Path = .{ .segments = &key_segs, .span = gsp } };
    var key_names = [_]?[]const u8{ null, null };
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = &key_callee,
        .args = &key_args,
        .arg_names = &key_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const host = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);
    var sinks = std.StringHashMap(void).init(a);
    try sinks.put("key", {});
    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &host, allComposable, &ctx, &sinks, false, null, null);
    // The key call became { startMovableGroup(site, k); val $key$v = key(...);
    // endMovableGroup(); $key$v }.
    const blk = wrappedBodyStmts(&out)[0].Expr.Block;
    try testing.expectEqual(@as(usize, 4), blk.stmts.len);
    const start = blk.stmts[0].Expr.Call;
    try testing.expectEqualStrings("startMovableGroup", start.callee.Member.name.name);
    try testing.expectEqual(@as(usize, 2), start.args.len);
    try testing.expectEqualStrings("k", start.args[1].Path.segments[0].name);
    const kcall = blk.stmts[1].Decl.Property.init.?.Call;
    try testing.expectEqualStrings("key", kcall.callee.Path.segments[0].name);
    // Threaded: keys + lambda + $composer + $changed.
    try testing.expectEqual(@as(usize, 4), kcall.args.len);
    try testing.expectEqualStrings("endMovableGroup", blk.stmts[2].Expr.Call.callee.Member.name.name);
    try testing.expectEqualStrings("$key$v", blk.stmts[3].Expr.Path.segments[0].name);
}

test "a non-local return through a sink lambda closes groups via endToMarker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gsp = Span.init(span_mod.FileId.from(0), 0, 0);

    // Body: InlineLinear outer@{ InlineLinear { return@outer } }
    // A `return@outer` from the inner sink lambda is non-local, so it must
    // close the inner group before unwinding.
    const ret = try a.create(Expr);
    ret.* = .{ .Return = .{ .value = null, .label = dummyIdent("outer"), .span = gsp } };
    const inner_body = try a.alloc(Stmt, 1);
    inner_body[0] = .{ .Expr = ret.* };
    var noparams_l: [0]Ident = .{};
    var noptys_l: [0]?TypeRef = .{};
    const inner_lam = try a.create(Expr);
    inner_lam.* = .{ .Lambda = .{
        .params = &noparams_l,
        .param_tys = &noptys_l,
        .body = .{ .stmts = inner_body, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } };
    const il_segs = try a.alloc(Ident, 1);
    il_segs[0] = dummyIdent("InlineLinear");
    const inner_callee = try a.create(Expr);
    inner_callee.* = .{ .Path = .{ .segments = il_segs, .span = gsp } };
    const inner_args = try a.alloc(Expr, 1);
    inner_args[0] = inner_lam.*;
    const inner_names = try a.alloc(?[]const u8, 1);
    inner_names[0] = null;
    const inner_call = try a.create(Expr);
    inner_call.* = .{ .Call = .{
        .callee = inner_callee,
        .args = inner_args,
        .arg_names = inner_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } };

    const outer_body = try a.alloc(Stmt, 1);
    outer_body[0] = .{ .Expr = inner_call.* };
    const outer_lam = try a.create(Expr);
    outer_lam.* = .{ .Lambda = .{
        .params = &noparams_l,
        .param_tys = &noptys_l,
        .body = .{ .stmts = outer_body, .span = gsp },
        .implicit_it = true,
        .span = gsp,
    } };
    const outer_labeled = try a.create(Expr);
    outer_labeled.* = .{ .Labeled = .{ .label = dummyIdent("outer"), .expr = outer_lam, .span = gsp } };
    const ol_segs = try a.alloc(Ident, 1);
    ol_segs[0] = dummyIdent("InlineLinear");
    const outer_callee = try a.create(Expr);
    outer_callee.* = .{ .Path = .{ .segments = ol_segs, .span = gsp } };
    const outer_args = try a.alloc(Expr, 1);
    outer_args[0] = outer_labeled.*;
    const outer_names = try a.alloc(?[]const u8, 1);
    outer_names[0] = null;
    var body_stmts = [_]Stmt{.{ .Expr = .{ .Call = .{
        .callee = outer_callee,
        .args = outer_args,
        .arg_names = outer_names,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = true,
        .span = gsp,
    } } }};
    var noparams: [0]Param = .{};
    const host = emptyFn("Host", &noparams, .{ .Block = .{ .stmts = &body_stmts, .span = gsp } }, true);

    var sinks = std.StringHashMap(void).init(a);
    try sinks.put("InlineLinear", {});
    // `InlineLinear` is an inline function: its lambda is spliced, never
    // wrapped in composableLambda — mirror that so the sink lambda stays raw.
    var inline_fns = std.StringHashMap(void).init(a);
    try inline_fns.put("InlineLinear", {});
    active_inline_fns = &inline_fns;
    defer active_inline_fns = null;
    var ctx: u8 = 0;
    const out = try transformComposableFunction(a, &host, allComposable, &ctx, &sinks, false, null, null);

    const ocall = wrappedBodyStmts(&out)[0].Expr.Call;
    // The labeled trailing lambda is unwrapped and threaded.
    const olam = ocall.args[0].Labeled.expr.Lambda;
    try testing.expectEqual(@as(usize, 2), olam.params.len);
    try testing.expectEqualStrings(composer_param, olam.params[0].name);
    // The outer lambda body gains a leading `val <marker> = $composer.currentMarker`.
    try testing.expect(olam.body.stmts[0] == .Decl);
    const marker_prop = olam.body.stmts[0].Decl.Property;
    try testing.expect(!marker_prop.mutable);
    try testing.expect(marker_prop.init.? == .Member);
    try testing.expectEqualStrings("currentMarker", marker_prop.init.?.Member.name.name);
    const marker_name = marker_prop.name.name;
    // The inner sink lambda's `return@outer` became `{ endToMarker(m); return }`.
    const inner_lam_out = olam.body.stmts[1].Expr.Call.args[0].Lambda;
    const wrapped = inner_lam_out.body.stmts[0].Expr;
    try testing.expect(wrapped == .Block);
    const cleanup = wrapped.Block.stmts[0].Expr.Call;
    try testing.expectEqualStrings("endToMarker", cleanup.callee.Member.name.name);
    try testing.expectEqualStrings(marker_name, cleanup.args[0].Path.segments[0].name);
    try testing.expect(wrapped.Block.stmts[1].Expr == .Return);
}
