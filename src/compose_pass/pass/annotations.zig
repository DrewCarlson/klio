//! `@Composable` predicates and the FQNs of the runtime entry points the pass emits.

const std = @import("std");
const ast = @import("ast");
const root = @import("../compose_pass.zig");

const Function = ast.Function;

const isComposable = root.isComposable;

pub const dbg_lambda = false;

/// Absent-argument marker singleton. A defaulted `@Composable` parameter's default must
/// evaluate inside the body with `$composer` in scope, so the declared default becomes
/// `klioComposableDefaultMarker()` and the body is prologued with
/// `val n = if (n$arg === klioComposableDefaultMarker()) <default> else n$arg`.
pub const default_marker_path = [_][]const u8{ "androidx", "compose", "runtime", "klioComposableDefaultMarker" };
/// Ambient-composer host intrinsic, served by `src/interp_ir/vm/compose.zig`. A
/// `@Composable` property getter has no `$composer` to thread, so an ambient-mode walk
/// substitutes this call for reads and for threaded arguments.
pub const ambient_composer_path = [_][]const u8{ "androidx", "compose", "runtime", "__compose_currentComposer" };

/// The remembered wrapper around a composable lambda argument, so unchanged content
/// compares EQUAL and its group skips.
const composable_lambda_path = [_][]const u8{ "androidx", "compose", "runtime", "internal", "composableLambda" };
pub const composable_lambda_instance_path = [_][]const u8{ "androidx", "compose", "runtime", "internal", "composableLambdaInstance" };
/// Stores the impl in a `remember` slot of the current group rather than opening a
/// movable child group, which would sit as an extra first child of an enclosing
/// reusable group and hide the real content from `deactivateToEndGroup`.
pub const remember_composable_lambda_path = [_][]const u8{ "androidx", "compose", "runtime", "internal", "rememberComposableLambda" };

/// A `@Composable` function owning its restart scope, bracketed with
/// `startRestartGroup`/`endRestartGroup()?.updateScope`. Excluded: `inline` composables
/// and `@NonRestartableComposable`/`@ReadOnlyComposable`/`@ExplicitGroupsComposable`,
/// which recompose as part of their caller but still get the threaded pair.
pub fn isRestartableComposable(f: *const Function) bool {
    if (!isComposable(f.annotations)) return false;
    if (f.is_inline) return false;
    // A restart scope returns Unit. A value-returning composable is threaded but never
    // wrapped, since the wrap collapses its value.
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

/// `@ExplicitGroupsComposable` emits its own groups, so the pass threads the composer
/// but inserts no automatic groups.
pub fn isExplicitGroups(f: *const Function) bool {
    for (f.annotations) |ann| {
        if (ann.path.len == 0) continue;
        if (std.mem.eql(u8, ann.path[ann.path.len - 1].name, "ExplicitGroupsComposable")) return true;
    }
    return false;
}
