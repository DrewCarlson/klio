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
