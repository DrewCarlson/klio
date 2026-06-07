const std = @import("std");

/// One Zig module per former Rust crate. `deps` are the non-dev crate
/// dependencies (the acyclic graph). `tested` flips on once a module has been
/// ported with passing `test {}` blocks, which adds it to `zig build test`.
const Mod = struct {
    name: []const u8,
    deps: []const []const u8 = &.{},
    tested: bool = false,
};

const mod_list = [_]Mod{
    .{ .name = "span", .tested = true },
    .{ .name = "diagnostics", .deps = &.{"span"}, .tested = true },
    .{ .name = "ast", .deps = &.{"span"}, .tested = true },
    .{ .name = "runtime", .deps = &.{ "ast", "span" }, .tested = true },
    .{ .name = "types", .deps = &.{ "ast", "diagnostics", "span" }, .tested = true },
    .{ .name = "lexer", .deps = &.{ "diagnostics", "span" }, .tested = true },
    .{ .name = "pack", .deps = &.{ "ast", "span", "types" }, .tested = true },
    .{ .name = "parser", .deps = &.{ "ast", "diagnostics", "lexer", "span" }, .tested = true },
    .{ .name = "ir", .deps = &.{ "span", "ast", "types", "runtime", "diagnostics" }, .tested = true },
    .{ .name = "stdlib", .deps = &.{ "runtime", "pack" }, .tested = true },
    .{ .name = "cfa", .deps = &.{ "ast", "diagnostics", "lexer", "parser", "span", "types" }, .tested = true },
    .{ .name = "resolver", .deps = &.{ "span", "ast", "diagnostics", "types", "stdlib" }, .tested = true },
    .{ .name = "interp_ir", .deps = &.{ "ir", "runtime", "ast", "span", "stdlib", "diagnostics" }, .tested = true },
    .{ .name = "stdlib_pack", .deps = &.{ "pack", "stdlib" }, .tested = true },
    .{ .name = "stdlib_gen", .deps = &.{ "pack", "stdlib" }, .tested = true },
    .{ .name = "kotlinx_atomicfu", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "kotlinx_coroutines", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "kotlinx_datetime", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "kotlinx_io", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "kotlinx_serialization", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "ktor_client", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "typeck", .deps = &.{ "span", "ast", "diagnostics", "resolver", "types", "cfa" }, .tested = true },
    .{ .name = "diagnostics_gen", .deps = &.{}, .tested = true },
    .{ .name = "cli", .deps = &.{ "span", "diagnostics", "lexer", "parser", "resolver", "typeck", "interp_ir", "ast", "pack", "stdlib", "stdlib_pack", "kotlinx_atomicfu", "kotlinx_coroutines", "kotlinx_datetime", "kotlinx_io", "kotlinx_serialization", "ktor_client", "runtime", "types" }, .tested = true },
    .{ .name = "parity", .deps = &.{ "ast", "interp_ir", "kotlinx_atomicfu", "kotlinx_coroutines", "kotlinx_datetime", "kotlinx_io", "kotlinx_serialization", "lexer", "pack", "parser", "resolver", "runtime", "span", "stdlib", "stdlib_pack", "typeck" }, .tested = true },
    .{ .name = "bench", .deps = &.{ "ast", "interp_ir", "lexer", "parity", "parser", "resolver", "runtime", "span", "typeck" }, .tested = true },
    // End-to-end corpus test: runs every examples/*.kt in-process via the
    // parity pipeline and asserts against tests/corpus/expected/.
    .{ .name = "e2e", .deps = &.{"parity"}, .tested = true },
    // Integration suites ported from crates/*/tests.
    .{ .name = "itests", .deps = &.{ "parity", "typeck", "resolver", "parser", "lexer", "cfa", "runtime", "ast", "span", "diagnostics", "types", "pack", "ir", "interp_ir" }, .tested = true },
};

/// Integration-test files under src/itests/, each run as its own test binary so
/// a crash or OOM in one file isolates instead of taking down the whole suite.
const itests_files = [_][]const u8{
    "cfa_builder", "cfa_smartcast", "parity_advanced_idioms", "parity_array_bulk_ops",
    "parity_atomicfu_arrays", "parity_closures_advanced", "parity_closures_deep",
    "parity_collections_intensive", "parity_conformance", "parity_coroutine_smoke",
    "parity_coroutines_realistic", "parity_data_class_features", "parity_dsl_operators",
    "parity_exceptions_and_flow", "parity_extension_resolution", "parity_functional_patterns",
    "parity_generics_advanced", "parity_inheritance_dispatch", "parity_inner_classes",
    "parity_interfaces_visibility", "parity_iterables_special", "parity_kotlinx_io_read",
    "parity_lambdas_and_dispatch", "parity_maps_intensive", "parity_named_args_defaults",
    "parity_nullability_deep", "parity_operator_edge_cases", "parity_properties_accessors",
    "parity_ranges_arrays", "parity_sealed_when_patterns", "parity_string_processing",
    "parity_strings_numbers", "parity_suspend_shapes", "parity_threaded_litmus",
    "parity_type_system_shapes", "parity_visibility_modifiers", "parser_corpus",
    "runtime_objref_threads", "typeck_negative",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var mods = std.StringHashMap(*std.Build.Module).init(b.allocator);
    defer mods.deinit();

    for (mod_list) |m| {
        const mod = b.addModule(m.name, .{
            .root_source_file = b.path(b.fmt("src/{s}/{s}.zig", .{ m.name, m.name })),
            .target = target,
            .optimize = optimize,
        });
        mods.put(m.name, mod) catch @panic("oom");
    }
    for (mod_list) |m| {
        const mod = mods.get(m.name).?;
        for (m.deps) |d| mod.addImport(d, mods.get(d).?);
    }

    // The pack format compresses sections with the system zstd library.
    // Zig std ships only a zstd decoder, so the encoder is linked from
    // libzstd directly (no dev header needed — the symbols are declared
    // extern in src/pack/zstd.zig). The library is linked as an object
    // file because distros ship the versioned `libzstd.so.1` without a
    // `-dev` `libzstd.so` symlink; `-Dzstd-lib=` overrides the path. Link
    // inputs attached to the pack module flow into every artifact that
    // imports it.
    const zstd_lib = b.option(
        []const u8,
        "zstd-lib",
        "Path to the shared zstd library to link (default: /usr/lib/x86_64-linux-gnu/libzstd.so.1)",
    ) orelse "/usr/lib/x86_64-linux-gnu/libzstd.so.1";
    const pack_mod = mods.get("pack").?;
    pack_mod.link_libc = true;
    pack_mod.addObjectFile(.{ .cwd_relative = zstd_lib });

    const exe = b.addExecutable(.{
        .name = "klio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cli", .module = mods.get("cli").? },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the klio binary");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all ported module tests");
    for (mod_list) |m| {
        if (!m.tested) continue;
        if (std.mem.eql(u8, m.name, "itests")) {
            // One test binary per integration-test file (process isolation).
            const imports = b.allocator.alloc(std.Build.Module.Import, m.deps.len) catch @panic("oom");
            for (m.deps, 0..) |d, i| imports[i] = .{ .name = d, .module = mods.get(d).? };
            for (itests_files) |name| {
                const tmod = b.createModule(.{
                    .root_source_file = b.path(b.fmt("src/itests/{s}.zig", .{name})),
                    .target = target,
                    .optimize = optimize,
                    .imports = imports,
                });
                const run_t = b.addRunArtifact(b.addTest(.{ .root_module = tmod }));
                run_t.setCwd(b.path("."));
                test_step.dependOn(&run_t.step);
            }
            continue;
        }
        const t = b.addTest(.{ .root_module = mods.get(m.name).? });
        const run_t = b.addRunArtifact(t);
        // The e2e test reads examples/ and tests/corpus/expected/ by relative path.
        if (std.mem.eql(u8, m.name, "e2e")) run_t.setCwd(b.path("."));
        test_step.dependOn(&run_t.step);
    }
}
