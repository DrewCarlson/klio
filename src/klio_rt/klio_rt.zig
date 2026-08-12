//! The C ABI surface of the klio runtime — stage 1 of the C transpiler
//! (`plans/c-transpiler-plan.md`): program bootstrap, so a C host (and later
//! the transpiled C itself) can drive klio end to end against a static
//! library. The frame-ABI and leaf-helper exports arrive with the emitter.

const std = @import("std");
const cli = @import("cli");
const runtime = @import("runtime");

/// Run the Kotlin program at `path` exactly as `klio run <path>` would,
/// on the default process-lifetime arena profile. Returns the process
/// exit code (0 success, 1 diagnostics/runtime error).
export fn klio_rt_run_file(path: [*:0]const u8) c_int {
    runtime.perf.setProfile(runtime.perf.resolveBinaryProfile(&.{}));
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = runtime.allocTrackWrap(arena.allocator());
    var features = cli.commands.RequestedFeatures.init(gpa);
    defer features.deinit();
    const code = cli.commands.runFileIrVm(gpa, std.mem.span(path), &features);
    return @intCast(code);
}

/// Library version tag for the header/link handshake.
export fn klio_rt_abi_version() c_int {
    return 1;
}
