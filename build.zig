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
    "parity_nullability_deep", "parity_object_init", "parity_operator_edge_cases", "parity_properties_accessors",
    "parity_ranges_arrays", "parity_sealed_when_patterns", "parity_string_processing",
    "parity_strings_numbers", "parity_suspend_shapes", "parity_threaded_litmus",
    "parity_type_system_shapes", "parity_visibility_modifiers", "parser_corpus",
    "runtime_objref_threads", "typeck_negative", "differential",
    "fuzz_closures_suspend",
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

    // The pack format compresses sections with zstd. Zig std ships only a
    // zstd decoder, so the encoder is linked from the vendored zstd C
    // sources, compiled here into a static library. The symbols are
    // declared extern in src/pack/zstd.zig (no header needed). Link inputs
    // attached to the pack module flow into every artifact that imports it.
    const zstd = buildZstd(b, target, optimize);
    const pack_mod = mods.get("pack").?;
    pack_mod.link_libc = true;
    pack_mod.linkLibrary(zstd);

    // Install the compiled static library to zig-out/lib/libzstd.a so
    // per-module verification (scripts/zigcheck.py) can link the extern
    // ZSTD_* symbols without re-running the whole build graph.
    b.installArtifact(zstd);
    const zstd_lib_step = b.step("zstd-lib", "Build and install the vendored zstd static library");
    zstd_lib_step.dependOn(&b.addInstallArtifact(zstd, .{}).step);

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
    const itest_bin_step = b.step("itest-bin", "Build+install standalone itest binaries for stress looping");
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
                const tbin = b.addTest(.{ .root_module = tmod });
                const run_t = b.addRunArtifact(tbin);
                run_t.setCwd(b.path("."));
                test_step.dependOn(&run_t.step);
                // Also install the raw test binary so it can be looped from a
                // shell without the build graph re-running each iteration.
                const inst = b.addInstallArtifact(tbin, .{
                    .dest_sub_path = b.fmt("itest-{s}", .{name}),
                });
                itest_bin_step.dependOn(&inst.step);
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

/// zstd C sources, relative to the dependency's `lib/` directory. The x86-64
/// BMI2 assembly fast path (`huf_decompress_amd64.S`) is omitted and disabled
/// via `-DZSTD_DISABLE_ASM` so the same C-only build works on every target.
const zstd_sources = [_][]const u8{
    // common
    "common/debug.c",
    "common/entropy_common.c",
    "common/error_private.c",
    "common/fse_decompress.c",
    "common/pool.c",
    "common/threading.c",
    "common/xxhash.c",
    "common/zstd_common.c",
    // compress
    "compress/fse_compress.c",
    "compress/hist.c",
    "compress/huf_compress.c",
    "compress/zstd_compress.c",
    "compress/zstd_compress_literals.c",
    "compress/zstd_compress_sequences.c",
    "compress/zstd_compress_superblock.c",
    "compress/zstd_double_fast.c",
    "compress/zstd_fast.c",
    "compress/zstd_lazy.c",
    "compress/zstd_ldm.c",
    "compress/zstdmt_compress.c",
    "compress/zstd_opt.c",
    // decompress
    "decompress/huf_decompress.c",
    "decompress/zstd_ddict.c",
    "decompress/zstd_decompress_block.c",
    "decompress/zstd_decompress.c",
    // dictBuilder (ZSTD_*_usingDict live in the core, but link the builder so
    // the dictionary trainer APIs are available if pack ever needs them).
    "dictBuilder/cover.c",
    "dictBuilder/divsufsort.c",
    "dictBuilder/fastcover.c",
    "dictBuilder/zdict.c",
};

/// Build the vendored zstd C library as a static library statically linked
/// into the binary and test artifacts. No system zstd is referenced.
fn buildZstd(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const dep = b.dependency("zstd", .{});

    const lib = b.addLibrary(.{
        .name = "zstd",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addIncludePath(dep.path("lib"));
    lib.root_module.addIncludePath(dep.path("lib/common"));
    lib.root_module.addCSourceFiles(.{
        .root = dep.path("lib"),
        .files = &zstd_sources,
        .flags = &.{
            "-DZSTD_DISABLE_ASM",
            "-DXXH_NAMESPACE=ZSTD_",
            "-fvisibility=hidden",
            "-std=c11",
        },
    });
    lib.installHeader(dep.path("lib/zstd.h"), "zstd.h");

    return lib;
}
