//! Kotlin/Native's `kotlin.native.ref` and `kotlin.native.runtime.GC` over
//! the runtime's weak cells, cleaner registry and collector.

const std = @import("std");
const runtime = @import("runtime");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const Allocator = std.mem.Allocator;

fn arity(comptime what: []const u8) EvalResult {
    return .{ .err = .{ .Arity = what } };
}

/// `__klio_weakNew(referred)`: a weak cell for the referent.
pub fn weak_new(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len != 1) return arity("__klio_weakNew expects one argument");
    return .{ .ok = try runtime.weak.newWeak(ctx.allocator, ctx.args[0]) };
}

/// `__klio_weakGet(cell)`: the referent, or null once it was collected.
pub fn weak_get(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len != 1) return arity("__klio_weakGet expects one argument");
    return .{ .ok = runtime.weak.get(ctx.args[0]) };
}

/// `__klio_cleanerRegister(owner, job)`: true when the caller must start this
/// run's cleaner thread.
pub fn cleaner_register(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len != 2) return arity("__klio_cleanerRegister expects two arguments");
    return .{ .ok = .{ .Bool = try runtime.weak.registerCleaner(ctx.args[0], ctx.args[1]) } };
}

/// `__klio_cleanerTake()`: the next cleanup job, waiting for one, or null
/// once the run is ending.
pub fn cleaner_take(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = runtime.weak.takeCleanup() orelse .Null };
}

fn asU(v: Value) ?usize {
    return switch (v) {
        .Long => |x| @bitCast(x),
        else => null,
    };
}

/// `registerNativeFinalizer(owner, finalizer, pointer)`: the registration's
/// handle.
pub fn native_finalizer_register(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len != 3) return arity("registerNativeFinalizer expects three arguments");
    const f = asU(ctx.args[1]) orelse return .{ .err = .{ .Type = "registerNativeFinalizer: the finalizer is a Long" } };
    const p = asU(ctx.args[2]) orelse return .{ .err = .{ .Type = "registerNativeFinalizer: the pointer is a Long" } };
    if (f == 0) return .{ .err = .{ .Type = "registerNativeFinalizer: the finalizer is null" } };
    const handle = try runtime.weak.registerNative(ctx.args[0], f, p);
    return .{ .ok = .{ .Long = @bitCast(@as(u64, handle)) } };
}

/// `runNativeFinalizer(handle)`: true when this call ran it.
pub fn native_finalizer_run(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len != 1) return arity("runNativeFinalizer expects one argument");
    const h = asU(ctx.args[0]) orelse return .{ .err = .{ .Type = "runNativeFinalizer: the handle is a Long" } };
    return .{ .ok = .{ .Bool = runtime.weak.runNative(h) } };
}

/// `Platform.osFamily`'s ordinal: OsFamily's order.
pub fn os_family(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    const b = @import("builtin");
    const n: i32 = switch (b.os.tag) {
        .macos => 1,
        .ios => 2,
        .linux => if (b.abi == .android or b.abi == .androideabi) 5 else 3,
        .windows => 4,
        .wasi, .emscripten => 6,
        .tvos => 7,
        .watchos => 8,
        else => 0,
    };
    return .{ .ok = .{ .Int = n } };
}

/// `Platform.cpuArchitecture`'s ordinal: CpuArchitecture's order.
pub fn cpu_architecture(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    const n: i32 = switch (@import("builtin").cpu.arch) {
        .arm, .thumb => 1,
        .aarch64 => 2,
        .x86 => 3,
        .x86_64 => 4,
        .mips => 5,
        .mipsel => 6,
        .wasm32 => 7,
        else => 0,
    };
    return .{ .ok = .{ .Int = n } };
}

/// `Platform.getAvailableProcessors()`: the processors this process may use.
pub fn available_processors(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    const n = std.Thread.getCpuCount() catch 1;
    return .{ .ok = .{ .Int = @intCast(@min(n, std.math.maxInt(i32))) } };
}

/// `GC.collect()`: a full collection, finished before it returns.
pub fn gc_collect(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    if (runtime.gc.gc_enabled) runtime.gc.collect();
    return .{ .ok = .Unit };
}

test {
    std.testing.refAllDecls(@This());
}
