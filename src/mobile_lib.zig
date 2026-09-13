//! Static library for embedding the interpreter in a mobile app host. iOS forbids
//! spawning a `klio` executable, so exported `klio_run` drives `cli.runArgv` in-process.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const runtime = @import("runtime");
const compose_ui = @import("compose_ui");

/// A mobile app cannot symbolize its own image, so the `SelfInfo` symbolizer stays unlinked.
pub const panic = std.debug.FullPanic(runtime.trace.panicFn);

/// Read off the root by `compose_ui`: the host links libklio_skia.a, so the Skia shim resolves without dlopen.
pub const klio_skia_static = true;

/// Interprets a program in-process and returns the exit code; `argv` excludes the program name.
export fn klio_run(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    // The simulator is a host process where the JIT works; a device forbids
    // W^X for un-entitled apps, so it falls back to the pure interpreter.
    runtime.perf.setProfile(if (builtin.abi == .simulator) .fast else .safe);

    // VM objects hold `{ptr = &arena, vtable}` and the frame source re-enters the VM
    // after this returns, so the ArenaAllocator struct itself must live on the heap.
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

    // A hosted UI run stays resident: the platform frame source drives the registered
    // frame callback off this arena after this returns, so the OS reclaims it at exit.
    if (compose_ui.hostedActive()) return rc;
    releaseArena(arena);
    return rc;
}
