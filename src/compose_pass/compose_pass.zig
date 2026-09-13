//! Compose compiler-plugin-equivalent lowering pass.
//!
//! An AST-to-AST transform that rewrites `@Composable` functions the way
//! androidx's Compose compiler plugin does, so upstream's real `Composer` /
//! `SlotTable` / `Recomposer` run unchanged. It depends only on `ast` + `span`
//! and registers as a pass, keeping the core lowerer oblivious.
//!
//! `@Composable fun App(x: Int) { Body }` becomes:
//!
//!     fun App(x: Int, $composer: Composer, $changed: Int) {
//!         $composer.startRestartGroup(<key>)
//!         Body                                     // @Composable calls threaded
//!         $composer.endRestartGroup()?.updateScope { c, f -> App(x, c, $changed or 1) }
//!     }
//!
//! Every `@Composable` call in the body gains the threaded `$composer` and a
//! child `$changed`. Positional group keys derive from the call's source span,
//! stable per call site, playing the role of the plugin's compile-time key
//! constant.

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

/// Composable-lambda memoization emission. Always on: kotlinc wraps composable
/// lambda arguments in remembered `composableLambda` instances. Without it an
/// unchanged content lambda is a fresh closure every recomposition,
/// `composer.changed(content)` is always true, and a forced recomposition of
/// unchanged content reports spurious changes.
pub var emit_lambda_memo: bool = true;

/// Group-emission debug (set by the build driver from KLIO_COMPOSE_DBG).
pub var dbg_groups: bool = false;

/// Synthetic name of the injected composer parameter.
pub const composer_param = "$composer";
/// Synthetic name of the injected changed-flags parameter.
pub const changed_param = "$changed";
/// The skip-calculus accumulator local (`var $dirty = $changed and 1`).
pub const dirty_local = "$dirty";
/// Whether restartable composables emit the skip calculus (probes plus skip
/// branch). Always on. The pass reads no environment itself (ast+span only), so
/// a caller can A/B the emission without a rebuild.
pub var emit_skip_calculus: bool = true;

/// Files whose bare `@Composable` names an annotation class the program
/// declares itself: a package other than `androidx.compose.runtime` declaring
/// `annotation class Composable`, with no import of another `Composable`. There
/// the annotation is the program's own and its declarations are left alone.
pub var user_composable_files: ?*const std.AutoHashMap(span_mod.FileId, void) = null;

/// Whether a declaration's annotations include `@Composable`. Matches the bare
/// name and any dotted path ending in `Composable`, except a bare `Composable`
/// in a file where the name is the program's own annotation class.
pub fn isComposable(annotations: []const ast.Annotation) bool {
    for (annotations) |a| {
        if (a.path.len == 0) continue;
        if (!std.mem.eql(u8, a.path[a.path.len - 1].name, "Composable")) continue;
        if (a.path.len == 1) {
            if (user_composable_files) |files| {
                if (files.contains(a.span.file)) continue;
            }
        }
        return true;
    }
    return false;
}

/// Stable positional group key for a call site, derived from its span:
/// identical across recompositions, distinct per source location. The Compose
/// plugin emits a compile-time constant in this role.
pub fn positionalKey(sp: Span) i64 {
    var h: u64 = 0xcbf29ce484222325;
    inline for (.{ @as(u64, sp.file.int()), @as(u64, sp.start), @as(u64, sp.end) }) |v| {
        h ^= v;
        h *%= 0x100000001b3;
    }
    // Fold to a signed 32-bit key (the ABI key type is `Int`).
    return @as(i64, @as(i32, @truncate(@as(i64, @bitCast(h)))));
}

pub var active_composable_params: ?*const std.StringHashMap(ComposableParams) = null;

/// Fully-closed memoized lambdas lifted to top-level singleton vals during
/// the transform; the driver appends them to the compilation's decls after
/// `transformDecls` returns. Null disables lifting.
pub var pending_memo_lifts: ?*std.ArrayList(ast.Decl) = null;
pub var pending_lift_alloc: ?std.mem.Allocator = null;

/// KLIO_MEMO_TRACE: log memoization-path decisions and call-site bits.
pub var memo_trace_enabled: bool = false;

pub var compose_audit: ComposeAudit = .{};

pub var active_composable_names: ?*const std.StringHashMap(void) = null;
pub var active_composable_sinks: ?*const std.StringHashMap(void) = null;

/// Names of INLINE functions in the compile universe. A composable call is
/// legal inside a lambda argument only when the callee inlines it or the
/// parameter is composable; a plain callback lambda (`DisposableEffect { … }`)
/// is not a composable scope, and threading it emits composer traffic that runs
/// post-composition through the captured outer composer.
pub var active_inline_fns: ?*const std.StringHashMap(void) = null;

/// Names of PROPERTIES whose read invokes a `@Composable` getter, with the
/// annotation on the property or on its `get()` accessor (`currentComposer`,
/// `currentRecomposeScope`, `currentCompositeKeyHashCode`). Reading one
/// composes, so `branchHasComposable` treats a lambda that only reads such a
/// property as composable content and memoizes it.
pub var active_composable_getter_props: ?*const std.StringHashMap(void) = null;

/// Class name to stability registry for the current transform run, built by
/// `collectClassStability` over the module's declarations plus the baked base's.
/// Null (no registry) treats every type as stable.
pub var active_stability: ?*const std.StringHashMap(Stability) = null;

const collect = @import("pass/collect.zig");
pub const ComposableOracle = collect.ComposableOracle;
pub const NameSetOracle = collect.NameSetOracle;
pub const collectComposableNames = collect.collectComposableNames;
pub const ComposableParams = collect.ComposableParams;
pub const collectComposableParamNames = collect.collectComposableParamNames;
pub const composableFunctionRecvSlots = collect.composableFunctionRecvSlots;
pub const composableFunctionArity = collect.composableFunctionArity;
pub const ComposeAudit = collect.ComposeAudit;
pub const composeAuditOn = collect.composeAuditOn;
pub const collectSinkContentReachInto = collect.collectSinkContentReachInto;
pub const collectInlineFnNames = collect.collectInlineFnNames;
pub const collectInlineFnNamesInto = collect.collectInlineFnNamesInto;
pub const collectComposableGetterProps = collect.collectComposableGetterProps;
pub const collectComposableGetterPropsInto = collect.collectComposableGetterPropsInto;
pub const collectComposableLambdaSinks = collect.collectComposableLambdaSinks;

const stability = @import("pass/stability.zig");
pub const Stability = stability.Stability;
pub const collectClassStability = stability.collectClassStability;

const transform = @import("pass/transform.zig");
pub const transformDecls = transform.transformDecls;
pub const transformComposableFunction = transform.transformComposableFunction;
pub const transformThreadedComposable = transform.transformThreadedComposable;

const lambda = @import("pass/lambda.zig");
pub const transformResolvedComposableLambda = lambda.transformResolvedComposableLambda;

const epilogue = @import("pass/epilogue.zig");
pub const memoWrappedLambda = epilogue.memoWrappedLambda;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("pass/annotations.zig"));
    std.testing.refAllDecls(@import("pass/builder.zig"));
    std.testing.refAllDecls(@import("pass/collect.zig"));
    std.testing.refAllDecls(@import("pass/epilogue.zig"));
    std.testing.refAllDecls(@import("pass/lambda.zig"));
    std.testing.refAllDecls(@import("pass/stability.zig"));
    std.testing.refAllDecls(@import("pass/tests.zig"));
    std.testing.refAllDecls(@import("pass/transform.zig"));
    std.testing.refAllDecls(@import("pass/walker.zig"));
}
