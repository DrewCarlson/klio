//! Ambient-composer support for plugin-lowered `@Composable` execution. The lowering
//! threads a synthetic `$composer, $changed` pair through every composable signature;
//! this keeps the per-thread ambient composer stack for what that pair cannot reach: a
//! `@Composable` property getter has no composer parameter, so its composer references
//! compile to `__compose_currentComposer`, which reads this stack.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const HostBindings = stdlib.HostBindings;
const Error = Allocator.Error;

/// Stack of active `KlioComposer` values, head first; page-allocator backed and GC-rooted.
threadlocal var composer_stack: std.ArrayList(Value) = .empty;

fn stackAllocator() Allocator {
    return runtime.slab.tracedPage();
}

threadlocal var compose_troot: runtime.gc.ThreadRoot = undefined;
threadlocal var compose_troot_inited: bool = false;

fn gcMarkComposeLocal(ctx: *anyopaque, m: *runtime.gc.Marker) void {
    const sp: *const std.ArrayList(Value) = @ptrCast(@alignCast(ctx));
    for (sp.items) |v| v.gcMark(m);
}

fn ensureComposeRoot() void {
    if (!runtime.gc.gc_enabled) return;
    if (!compose_troot_inited) {
        compose_troot_inited = true;
        compose_troot = .{ .ctx = @ptrCast(&composer_stack), .mark = gcMarkComposeLocal };
        runtime.gc.registerThreadRoot(&compose_troot);
    }
}

pub fn gcUninstallComposeRoot() void {
    if (!compose_troot_inited) return;
    runtime.gc.unregisterThreadRoot(&compose_troot);
    compose_troot_inited = false;
}

pub fn pushComposer(v: Value) void {
    ensureComposeRoot();
    composer_stack.append(stackAllocator(), v) catch {};
}

pub fn popComposer() void {
    if (composer_stack.items.len != 0) _ = composer_stack.pop();
}

pub fn currentComposer() ?Value {
    if (composer_stack.items.len == 0) return null;
    return composer_stack.items[composer_stack.items.len - 1];
}

/// The threaded `$composer`, or null when the call is not a threaded composable. The
/// plugin ABI ends the parameter list with `$composer, $changed` and right-aligns `args`
/// with `params`: 1:1 for a free call, one shorter when `params` carry a leading `this`.
pub fn threadedComposerArgFor(fqn: []const u8, params: []const ir.Param, args: []const Value) ?Value {
    const got = threadedComposerArg(params, args);
    if (got != null and runtime.envOnce("KLIO_COMPOSER_BIND_TRACE") != null) {
        std.debug.print("[composer-bind-fn] {s}\n", .{fqn});
    }
    return got;
}

pub fn threadedComposerArg(params: []const ir.Param, args: []const Value) ?Value {
    if (params.len < 2 or args.len < 2) return null;
    if (args.len != params.len and args.len != params.len - 1) return null;
    if (!std.mem.eql(u8, params[params.len - 2].name, "$composer")) return null;
    if (!std.mem.eql(u8, params[params.len - 1].name, "$changed")) return null;
    const composer = args[args.len - 2];
    if (composer != .Instance) return null;
    if (runtime.envOnce("KLIO_COMPOSER_BIND_TRACE") != null) {
        const ig = composer.Instance.borrow();
        const cg = ig.get().class.borrow();
        const cls_name = cg.get().name;
        std.debug.print("[composer-bind] class={s} args={d} params={d} last={s}\n", .{ cls_name, args.len, params.len, @tagName(std.meta.activeTag(args[args.len - 1])) });
        // A non-Composer instance in the pair slot is a misbind; dump the frame chain.
        const is_composer = std.mem.indexOf(u8, cls_name, "Composer") != null;
        cg.deinit();
        ig.deinit();
        if (!is_composer) ir.eval.dumpFrameChainForDiagAlways();
    }
    return composer;
}

/// Clear the composer stack at a run boundary; `Composition` itself pops in a `finally`.
pub fn resetAtRunBoundary() void {
    composer_stack.clearRetainingCapacity();
}

fn intrPushComposer(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len >= 1) pushComposer(ctx.args[0]);
    return .{ .ok = .{ .Unit = {} } };
}

fn intrPopComposer(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    popComposer();
    return .{ .ok = .{ .Unit = {} } };
}

fn intrCurrentComposer(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    return .{ .ok = currentComposer() orelse .{ .Null = {} } };
}

pub fn hostBindings(allocator: Allocator) Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("androidx.compose.runtime.__compose_pushComposer", intrPushComposer);
    try b.register("androidx.compose.runtime.__compose_popComposer", intrPopComposer);
    try b.register("androidx.compose.runtime.__compose_currentComposer", intrCurrentComposer);
    return b;
}

const testing = std.testing;

test "composer stack push/current/pop" {
    resetAtRunBoundary();
    try testing.expect(currentComposer() == null);
    pushComposer(Value.newInt(7));
    try testing.expect(currentComposer().?.Int == 7);
    pushComposer(Value.newInt(9));
    try testing.expect(currentComposer().?.Int == 9);
    popComposer();
    try testing.expect(currentComposer().?.Int == 7);
    popComposer();
    try testing.expect(currentComposer() == null);
    popComposer(); // underflow is a no-op
}

test "hostBindings registers the composer-stack intrinsics" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("androidx.compose.runtime.__compose_pushComposer") != null);
    try testing.expect(b.resolve("androidx.compose.runtime.__compose_popComposer") != null);
    try testing.expect(b.resolve("androidx.compose.runtime.__compose_currentComposer") != null);
}

test "threadedComposerArg finds the composer for free, value, and member call shapes" {
    const composer = Value{ .Instance = undefined };
    const dummy_ty = ir.TypeRef{ .name = "Any", .nullable = false, .args = &.{} };
    const mk = struct {
        fn p(name: []const u8, ty: ir.TypeRef) ir.Param {
            return .{ .name = name, .ty = ty, .default = null };
        }
    }.p;
    const p_this = mk("this", dummy_ty);
    const p_composer = mk("$composer", dummy_ty);
    const p_changed = mk("$changed", dummy_ty);
    const p_x = mk("x", dummy_ty);

    // Free/value call: args map 1:1 with params, composer is second-to-last.
    {
        const params = [_]ir.Param{ p_x, p_composer, p_changed };
        const args = [_]Value{ Value.newInt(7), composer, Value.newInt(1) };
        const got = threadedComposerArg(&params, &args);
        try testing.expect(got != null and got.? == .Instance);
    }
    // Member call: params carry the leading `this`, args are receiver-excluded.
    {
        const params = [_]ir.Param{ p_this, p_composer, p_changed };
        const args = [_]Value{ composer, Value.newInt(1) };
        const got = threadedComposerArg(&params, &args);
        try testing.expect(got != null and got.? == .Instance);
    }
    // Not a threaded composable: no synthetic tail.
    {
        const params = [_]ir.Param{ p_x, p_x };
        const args = [_]Value{ Value.newInt(1), Value.newInt(2) };
        try testing.expect(threadedComposerArg(&params, &args) == null);
    }
    // A non-Instance composer arg (defaulted/absent) is not pushed.
    {
        const params = [_]ir.Param{ p_composer, p_changed };
        const args = [_]Value{ .{ .Null = {} }, Value.newInt(1) };
        try testing.expect(threadedComposerArg(&params, &args) == null);
    }
    // Wrong arity (neither 1:1 nor receiver-excluded) is rejected.
    {
        const params = [_]ir.Param{ p_this, p_x, p_composer, p_changed };
        const args = [_]Value{ composer, Value.newInt(1) };
        try testing.expect(threadedComposerArg(&params, &args) == null);
    }
}

