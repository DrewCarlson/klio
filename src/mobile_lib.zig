//! Static-library entry point for embedding the interpreter into a mobile app
//! host (iOS `.app`, Android APK). The app's native launch code links this
//! archive and calls the exported C `klio_run` to interpret a program; there is
//! no spawned `klio` executable on device (iOS forbids it), so the CLI runs
//! in-process through `cli.runArgv`.
//!
//! Built via `zig build mobile-lib -Dtarget=<mobile triple>`; only meaningful
//! for the mobile targets (`is_mobile_target`).
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const runtime = @import("runtime");
const compose_ui = @import("compose_ui");

/// This archive is only ever linked into a mobile app, which cannot symbolize
/// its own image (see `runtime.trace`) — route panics to a minimal handler so
/// the `SelfInfo` symbolizer is never pulled in.
pub const panic = std.debug.FullPanic(runtime.trace.panicFn);

/// Opt into the statically-linked Skia shim (compose_ui reads this off the root).
/// The app host links libklio_skia.a, so on iOS the interpreter resolves the shim
/// from those symbols instead of dlopen. The plain interpreter exe omits this and
/// stays headless.
pub const klio_skia_static = true;

/// Interpret a program in-process. `argc`/`argv` are the CLI arguments *after*
/// the program name (e.g. the host passes `{"run", "<path>"}`); a synthetic
/// `"klio"` program name is prepended. Returns the process exit code. Safe to
/// call once per host process.
export fn klio_run(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    // The simulator is a host process where the JIT works; a real device
    // forbids W^X for un-entitled apps, so fall back to the pure interpreter.
    runtime.perf.setProfile(if (builtin.abi == .simulator) .fast else .safe);

    // The ArenaAllocator STRUCT (not just its backing memory) must outlive a
    // hosted UI run: the allocator handle every VM object holds is
    // `{ptr = &arena, vtable}`, and the platform frame source re-enters the VM
    // after this returns. A stack `var arena` would leave that `ptr` dangling
    // the instant `klio_run` returns, so heap-allocate it for a stable address.
    const arena = std.heap.page_allocator.create(std.heap.ArenaAllocator) catch return 71;
    arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const gpa = arena.allocator();

    const releaseArena = struct {
        fn call(a: *std.heap.ArenaAllocator) void {
            a.deinit();
            std.heap.page_allocator.destroy(a);
        }
    }.call;

    var args: std.ArrayList([]const u8) = .empty;
    args.append(gpa, "klio") catch {
        releaseArena(arena);
        return 71;
    };
    var i: usize = 0;
    const n: usize = @intCast(argc);
    while (i < n) : (i += 1) args.append(gpa, std.mem.span(argv[i])) catch {
        releaseArena(arena);
        return 71;
    };

    const rc = cli.runArgv(gpa, args.items) catch |e| {
        std.debug.print("klio_run: {s}\n", .{@errorName(e)});
        releaseArena(arena);
        return 70;
    };

    // A hosted UI run stays resident: `application` registered a frame callback
    // and returned, and the platform frame source (iOS CADisplayLink) re-enters
    // the VM after this call returns. Everything the callback touches lives on
    // this arena (and its allocator handle points at the arena struct), so both
    // must outlive `klio_run` — leak them (the OS reclaims at process exit). A
    // non-UI run frees the arena now as usual.
    if (compose_ui.hostedActive()) return rc;
    releaseArena(arena);
    return rc;
}
