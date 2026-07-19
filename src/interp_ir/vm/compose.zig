//! Implicit-composer support for `@Composable` execution — klio's replacement
//! for the Compose compiler plugin's `$composer` threading.
//!
//! The plugin normally rewrites every `@Composable` function to take a synthetic
//! `Composer` parameter and to bracket its body with positional group-key calls.
//! klio has no plugin: instead this module keeps a per-thread stack of the
//! active composer value (the klioMain `KlioComposer`), pushed by the klioMain
//! `Composition` around the content lambda, and the call dispatcher brackets
//! every `@Composable` call with `startGroup(key)` / `endGroup()` on the current
//! composer (see `host_call_func.zig`). The positional key is derived from the
//! call-site source span, so the same source position maps to the same slot
//! group across recompositions. `currentComposer` (klioMain) resolves to the
//! stack head via the `__compose_currentComposer` intrinsic.
//!
//! Modeled on the coroutine `active_scope_stack` (`coroutines.zig`): a
//! page-allocator-backed threadlocal that is a GC thread-root for its lifetime.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const host_call_member = @import("host_call_member.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const HostBindings = stdlib.HostBindings;
const Error = Allocator.Error;

/// Stack of the active composer values (klioMain `KlioComposer`). The head is
/// the composer the current `@Composable` body runs against. Page-allocator
/// backed for the same reason the coroutine scope stack is: it persists across
/// GC safepoints taken inside composition.
threadlocal var composer_stack: std.ArrayList(Value) = .empty;

fn stackAllocator() Allocator {
    return runtime.slab.tracedPage();
}

// ----- GC rooting -----

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

/// Unlink this thread's compose root node at its exit seam.
pub fn gcUninstallComposeRoot() void {
    if (!compose_troot_inited) return;
    runtime.gc.unregisterThreadRoot(&compose_troot);
    compose_troot_inited = false;
}

// ----- composer stack -----

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

/// The threaded `$composer` argument to publish as the ambient composer for a
/// pass-lowered `@Composable` call, or null when the call is not a threaded
/// composable (so the caller pushes nothing).
///
/// The plugin ABI ends a composable's parameter list with the synthetic
/// `$composer, $changed` pair. `args` are the call arguments right-aligned with
/// `params`: for a free function or value call they map 1:1 (`args.len ==
/// params.len`); for a member method `params` carries an extra leading `this`
/// receiver param while `args` is receiver-excluded (`args.len == params.len -
/// 1`). In both shapes the `$composer` value is the second-to-last argument. It
/// must be an `Instance` (the real Composer) — a defaulted/absent composer is
/// not a stack entry.
pub fn threadedComposerArg(params: []const ir.Param, args: []const Value) ?Value {
    if (params.len < 2 or args.len < 2) return null;
    if (args.len != params.len and args.len != params.len - 1) return null;
    if (!std.mem.eql(u8, params[params.len - 2].name, "$composer")) return null;
    if (!std.mem.eql(u8, params[params.len - 1].name, "$changed")) return null;
    const composer = args[args.len - 2];
    if (composer != .Instance) return null;
    return composer;
}

/// Clear the composer stack at a run boundary (a leaked composer across runs is
/// a bug, but the synchronous `Composition` always pops in a `finally`).
pub fn resetAtRunBoundary() void {
    composer_stack.clearRetainingCapacity();
}

// ----- @Composable detection + positional key -----

pub fn isComposable(f: *const ir.Func) bool {
    for (f.annotation_names) |n| {
        if (std.mem.eql(u8, n, "Composable")) return true;
        if (std.mem.endsWith(u8, n, ".Composable")) return true;
    }
    return false;
}

/// A stable positional group key for the call currently being dispatched,
/// derived from the caller frame's in-progress statement span. Deterministic
/// and unique per source location, so the same call site yields the same key
/// across recompositions (the basis of `remember` slot identity).
pub fn callSiteKey() u64 {
    const sp = ir.eval.currentCallSiteSpan() orelse return 0x9e3779b97f4a7c15;
    var h = std.hash.Wyhash.init(0xc0117a5e);
    h.update(std.mem.asBytes(&sp.file));
    h.update(std.mem.asBytes(&sp.start));
    h.update(std.mem.asBytes(&sp.end));
    return h.final();
}

/// Hash one argument for the `@Composable` arg-changed check. Primitives and
/// content types hash by value/content; reference types (instances, closures,
/// `MutableState`, …) hash by identity — their value changing is observed via
/// the snapshot read subscription, not the arg-changed path, matching Compose's
/// stability model (a stable parameter is "unchanged" while its object is the
/// same instance).
fn argValueHash(v: *const Value) u64 {
    return switch (v.*) {
        .Null, .Unit => 0,
        // Kotlin's `Set`/`Map` hashCode is the *sum* of element/entry hashes, so
        // `setOf()` and `setOf(0)` both hash to 0 — using that as the @Composable
        // "changed" signal wrongly skips recomposition when a set toggles an
        // element whose hash the sum absorbs (element 0, or any element added to
        // an empty set). Fold size + each element structurally instead so a
        // content change is reflected.
        .Set => |s| blk: {
            const g = s.items.borrow();
            defer g.deinit();
            var h: u64 = 0xcbf29ce484222325 ^ 0x5e7;
            h = (h ^ @as(u64, g.get().items.len)) *% 1099511628211;
            for (g.get().items) |*e| h = (h ^ argValueHash(e)) *% 1099511628211;
            break :blk h;
        },
        .Map => |m| blk: {
            const g = m.entries.borrow();
            defer g.deinit();
            var h: u64 = 0xcbf29ce484222325 ^ 0x3a9;
            h = (h ^ @as(u64, g.get().pairs.items.len)) *% 1099511628211;
            for (g.get().pairs.items) |*p| {
                h = (h ^ argValueHash(&p.key)) *% 1099511628211;
                h = (h ^ argValueHash(&p.value)) *% 1099511628211;
            }
            break :blk h;
        },
        .Bool, .Char, .Byte, .Short, .Int, .Long, .UByte, .UShort, .UInt, .ULong, .Float, .Double, .String, .Pair, .Triple, .List, .Array, .Range, .MapEntry => @as(u64, @bitCast(@as(i64, host_call_member.kotlinHashCode(v)))),
        else => if (v.lockIdentity()) |id| @as(u64, id) else @as(u64, @bitCast(@as(i64, host_call_member.kotlinHashCode(v)))),
    };
}

/// FNV-1a combine of the call's argument hashes — the @Composable "changed"
/// signal. A group whose args hash differs from last pass re-composes even if it
/// was not directly invalidated (klio's stand-in for the plugin's `$changed`).
pub fn argsHash(args: []const Value) i64 {
    var h: u64 = 1469598103934665603;
    for (args) |*a| {
        h = (h ^ argValueHash(a)) *% 1099511628211;
    }
    return @bitCast(h);
}

// ----- host intrinsics (klioMain composer stack management) -----

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

/// Compose intrinsics that touch the interpreter's composer stack (registered
/// from interp_ir, merged alongside the `src/compose_runtime` pure intrinsics).
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

test "argsHash is stable, order-sensitive, and value-sensitive" {
    const a = [_]Value{ Value.newInt(1), Value.newInt(2) };
    const same = [_]Value{ Value.newInt(1), Value.newInt(2) };
    const reordered = [_]Value{ Value.newInt(2), Value.newInt(1) };
    const changed = [_]Value{ Value.newInt(1), Value.newInt(3) };
    try testing.expectEqual(argsHash(&a), argsHash(&same));
    try testing.expect(argsHash(&a) != argsHash(&reordered));
    try testing.expect(argsHash(&a) != argsHash(&changed));
    // No-arg call: a fixed seed, equal to itself.
    try testing.expectEqual(argsHash(&.{}), argsHash(&.{}));
}
