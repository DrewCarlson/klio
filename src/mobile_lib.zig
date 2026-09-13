//! Static-library entry point for embedding the interpreter in a mobile app
//! host (iOS `.app`, Android APK): the host links this archive and calls the
//! exported C `klio_run`. iOS forbids spawning a `klio` executable, so the CLI
//! runs in-process through `cli.runArgv`. Built by
//! `zig build mobile-lib -Dtarget=<mobile triple>`, for mobile targets only.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const runtime = @import("runtime");
const compose_ui = @import("compose_ui");

/// A mobile app cannot symbolize its own image (see `runtime.trace`), so panics
/// route to a minimal handler and the `SelfInfo` symbolizer stays unlinked.
pub const panic = std.debug.FullPanic(runtime.trace.panicFn);

/// Opts into the statically-linked Skia shim; `compose_ui` reads it off the
/// root. The host links libklio_skia.a, so the shim resolves from those symbols
/// instead of dlopen. The plain interpreter exe omits it and stays headless.
pub const klio_skia_static = true;

/// Interpret a program in-process and return the exit code. `argv` holds the
/// CLI arguments after the program name (`{"run", "<path>"}`); a synthetic
/// `"klio"` name is prepended. Call once per host process.
export fn klio_run(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    // The simulator is a host process where the JIT works; a device forbids
    // W^X for un-entitled apps, so it falls back to the pure interpreter.
    runtime.perf.setProfile(if (builtin.abi == .simulator) .fast else .safe);

    // The ArenaAllocator struct, not just its backing memory, must outlive a
    // hosted UI run: every VM object holds `{ptr = &arena, vtable}` and the
    // frame source re-enters the VM after this returns. A stack `var arena`
    // would leave that `ptr` dangling, so the struct lives on the heap.
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
    // that the platform frame source (iOS CADisplayLink) drives after this
    // returns, and everything it touches lives on this arena, so the arena
    // leaks here and the OS reclaims it at process exit. A non-UI run frees it.
    if (compose_ui.hostedActive()) return rc;
    releaseArena(arena);
    return rc;
}
