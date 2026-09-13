//! `@Composable` annotation predicates and the fully-qualified names of the
//! runtime entry points the pass emits calls to.

const std = @import("std");
const ast = @import("ast");
const root = @import("../compose_pass.zig");

const Function = ast.Function;

const isComposable = root.isComposable;

pub const dbg_lambda = false;

/// FQN of the absent-argument marker singleton accessor, declared in the compose
/// runtime engine pack. A defaulted `@Composable` parameter's default must
/// evaluate inside the function body with `$composer` in scope (`fun Test(n: Int
/// = LocalNumber.current)` reads a CompositionLocal), so the pass replaces the
/// declared default with `klioComposableDefaultMarker()` and prologues the body
/// with `val n = if (n$arg === klioComposableDefaultMarker()) <default> else n$arg`.
pub const default_marker_path = [_][]const u8{ "androidx", "compose", "runtime", "klioComposableDefaultMarker" };
/// FQN of the ambient-composer host intrinsic (klioMain HostIntrinsics.kt,
/// served by src/interp_ir/vm/compose.zig). A `@Composable` property getter has
/// no `$composer` parameter to thread, so an ambient-mode walk substitutes reads,
/// and the composer argument of threaded calls, with this call. The interpreter
/// keeps the stack populated around every transformed-composable invocation.
pub const ambient_composer_path = [_][]const u8{ "androidx", "compose", "runtime", "__compose_currentComposer" };

/// `androidx.compose.runtime.internal.composableLambda(composer, key, tracked,
/// block)`: the remembered wrapper kotlinc emits around every composable lambda
/// argument, so an unchanged content lambda compares EQUAL and its group skips.
const composable_lambda_path = [_][]const u8{ "androidx", "compose", "runtime", "internal", "composableLambda" };
pub const composable_lambda_instance_path = [_][]const u8{ "androidx", "compose", "runtime", "internal", "composableLambdaInstance" };
/// `androidx.compose.runtime.internal.rememberComposableLambda(key, tracked,
/// block)`. Unlike `composableLambda`, which opens a movable child group, this
/// stores the `ComposableLambdaImpl` in a `remember` slot of the current group,
/// adding no child group. A group here would sit as an extra first child of an
/// enclosing reusable group and hide the real content from
/// `deactivateToEndGroup`, which deactivates the group's first child subtree.
pub const remember_composable_lambda_path = [_][]const u8{ "androidx", "compose", "runtime", "internal", "rememberComposableLambda" };

/// A `@Composable` function that owns its own restart scope, bracketed with
/// `startRestartGroup`/`endRestartGroup()?.updateScope`. Excluded: `inline`
/// composables, which the compiler splices into the caller's group, and
/// `@NonRestartableComposable` / `@ReadOnlyComposable` /
/// `@ExplicitGroupsComposable`, which recompose as part of their caller.
/// Excluded functions still get the threaded `$composer`/`$changed` parameters;
/// bracketing them nests spurious restart scopes with null restart blocks.
pub fn isRestartableComposable(f: *const Function) bool {
    if (!isComposable(f.annotations)) return false;
    if (f.is_inline) return false;
    // A restart scope returns Unit. A declared non-Unit return type, or an
    // expression body with no declared type whose value IS the body, marks a
    // value-returning composable (`collectAsState`, `rememberUpdatedState`):
    // threaded but never restart-wrapped, since the wrap collapses its value.
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

/// A `@Composable` function annotated `@ExplicitGroupsComposable`: it emits its
/// own groups, so the pass threads the composer but inserts no automatic groups,
/// neither a restart bracket nor per-branch replace-groups.
pub fn isExplicitGroups(f: *const Function) bool {
    for (f.annotations) |ann| {
        if (ann.path.len == 0) continue;
        if (std.mem.eql(u8, ann.path[ann.path.len - 1].name, "ExplicitGroupsComposable")) return true;
    }
    return false;
}
