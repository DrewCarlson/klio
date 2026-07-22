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

/// This archive is only ever linked into a mobile app, which cannot symbolize
/// its own image (see `runtime.trace`) — route panics to a minimal handler so
/// the `SelfInfo` symbolizer is never pulled in.
pub const panic = std.debug.FullPanic(runtime.trace.panicFn);

/// Interpret a program in-process. `argc`/`argv` are the CLI arguments *after*
/// the program name (e.g. the host passes `{"run", "<path>"}`); a synthetic
/// `"klio"` program name is prepended. Returns the process exit code. Safe to
/// call once per host process.
export fn klio_run(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    // The simulator is a host process where the JIT works; a real device
    // forbids W^X for un-entitled apps, so fall back to the pure interpreter.
    runtime.perf.setProfile(if (builtin.abi == .simulator) .fast else .safe);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    args.append(gpa, "klio") catch return 71;
    var i: usize = 0;
    const n: usize = @intCast(argc);
    while (i < n) : (i += 1) args.append(gpa, std.mem.span(argv[i])) catch return 71;

    return cli.runArgv(gpa, args.items) catch |e| {
        std.debug.print("klio_run: {s}\n", .{@errorName(e)});
        return 70;
    };
}
