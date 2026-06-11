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

/// One integration-test file under src/itests/, run as its own test binary so
/// a crash or OOM in one file isolates instead of taking down the whole suite.
///
/// `parity_data`/`dirs` declare the repo data the binary reads at runtime by
/// cwd-relative path. Run steps cache on a manifest of declared inputs only,
/// so every consumed file must be declared or a stale pass could be reused.
const Itest = struct {
    name: []const u8,
    /// Runs Kotlin through the parity pipeline, which builds the stdlib pack
    /// from `kotlin/` + `kotlin-klio/kotlin-*` and (in pack load modes) reads
    /// the in-repo kotlinx pack sources.
    parity_data: bool = true,
    /// Extra build-root-relative data directories this test reads.
    dirs: []const []const u8 = &.{},
    /// Honors the fuzzer / kotlinc-oracle environment at runtime.
    fuzz_env: bool = false,
    /// Spawns the installed `zig-out/bin/klio` binary as a child process.
    needs_exe: bool = false,
};

const itests_files = [_]Itest{
    .{ .name = "cfa_builder", .parity_data = false },
    .{ .name = "cfa_smartcast", .parity_data = false },
    .{ .name = "parity_advanced_idioms" },
    .{ .name = "parity_array_bulk_ops" },
    .{ .name = "parity_atomicfu_arrays" },
    .{ .name = "parity_closures_advanced" },
    .{ .name = "parity_closures_deep" },
    .{ .name = "parity_collections_intensive" },
    .{ .name = "parity_conformance", .dirs = &.{"tests/fixtures/conformance"} },
    .{ .name = "parity_coroutine_smoke", .dirs = &.{"tests/fixtures/coroutine_smoke"} },
    .{ .name = "parity_corpus_pinned", .dirs = &.{"tests/fixtures/parity_corpus"} },
    .{ .name = "parity_coroutines_realistic" },
    .{ .name = "parity_data_class_features" },
    .{ .name = "parity_dsl_operators" },
    .{ .name = "parity_exceptions_and_flow" },
    .{ .name = "parity_extension_resolution" },
    .{ .name = "parity_functional_patterns" },
    .{ .name = "parity_generics_advanced" },
    .{ .name = "parity_inheritance_dispatch" },
    .{ .name = "parity_inner_classes" },
    .{ .name = "parity_interfaces_visibility" },
    .{ .name = "parity_iterables_special" },
    .{ .name = "parity_kotlinx_io_read" },
    .{ .name = "parity_lambdas_and_dispatch" },
    .{ .name = "parity_maps_intensive" },
    .{ .name = "parity_named_args_defaults" },
    .{ .name = "parity_nullability_deep" },
    .{ .name = "parity_object_init" },
    .{ .name = "parity_operator_edge_cases" },
    .{ .name = "parity_properties_accessors" },
    .{ .name = "parity_ranges_arrays" },
    .{ .name = "parity_sealed_when_patterns" },
    .{ .name = "parity_string_processing" },
    .{ .name = "parity_strings_numbers" },
    .{ .name = "parity_suspend_shapes" },
    .{ .name = "parity_threaded_litmus", .dirs = &.{"tests/fixtures/threaded_litmus"} },
    .{ .name = "parity_type_system_shapes" },
    .{ .name = "parity_visibility_modifiers" },
    .{ .name = "resolve_ambiguity" },
    .{ .name = "parser_corpus", .parity_data = false },
    .{ .name = "runtime_objref_threads", .parity_data = false },
    .{ .name = "typeck_negative", .parity_data = false, .dirs = &.{"tests/fixtures/typeck_negative"} },
    .{ .name = "check_examples", .dirs = &.{"examples"} },
    .{ .name = "differential", .dirs = &.{ "examples", "tests/fixtures/coroutine_smoke" } },
    .{ .name = "fuzz_closures_suspend", .fuzz_env = true },
    // End-to-end ktor gate: child `klio` + in-test HTTP server + installed packs.
    .{ .name = "ktor_client_get", .parity_data = false, .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-kotlinx-serialization",
        "kotlin-klio/klio-ktor-client",
    } },
};

/// Read by every parity-pipeline run: the stdlib pack is built at runtime from
/// the curated upstream sources plus the klio-authored actuals.
const stdlib_data_dirs = [_][]const u8{
    "kotlin/libraries/stdlib",
    "kotlin-klio/kotlin-collections",
    "kotlin-klio/kotlin-coroutines",
    "kotlin-klio/kotlin-internal",
    "kotlin-klio/kotlin-io",
    "kotlin-klio/kotlin-time",
    "kotlin-klio/kotlin-util",
};

/// Read by the SourcePacks/CompiledPacks load modes (each pack's klio.toml is
/// opened on every load; sources when the program's imports pull the pack in).
const kotlinx_pack_dirs = [_][]const u8{
    "kotlin-klio/klio-kotlinx-coroutines",
    "kotlin-klio/klio-kotlinx-atomicfu",
    "kotlin-klio/klio-kotlinx-io",
};

/// Environment variables the interpreter and runtime read per-process (via
/// /proc/self/environ) that can change what a test executes or asserts. Folded
/// into every test run's cache key when set, so e.g. a pass recorded without
/// KLIO_RACE_JITTER never satisfies a jitter run. Deliberately excluded as
/// scheduling/placement-only knobs: KLIO_PARITY_JOBS, KLIO_PARITY_JAVA_XMX_MB,
/// KLIO_PARITY_JAVA_TIMEOUT_SECS, CARGO_TARGET_DIR.
const interp_env_keys = [_][]const u8{
    "KLIO_RACE_JITTER",
    "KLIO_MAX_EVAL_DEPTH",
    "KLIO_THROW_TRACE",
    "KLIO_TRACE_RESOLVE",
    "KLIO_TRACE_CHAIN",
    "KLIO_TRACE_INVARIANTS",
    "KLIO_TRACE_PATH",
    "KLIO_TRACE_HTTP",
    "KLIO_LINK_AUDIT",
    "KLIO_RESOLVE_AUDIT",
    "KLIO_RESOLVE_STRICT",
    "KLIO_STDLIB_PACK",
    "KLIO_PACK_DIAG",
};

/// Fuzzer sweep size/seed plus the kotlinc-oracle discovery overrides. Note
/// kotlinc found via plain PATH/JAVA_HOME lookup is not part of the key; use
/// the KLIO_KOTLINC_* overrides (or -Dseed) to force an oracle re-run.
const fuzz_env_keys = [_][]const u8{
    "KLIO_FUZZ_SEED",
    "KLIO_FUZZ_SEEDS",
    "KLIO_SKIP_KOTLINC_PARITY",
    "KLIO_KOTLINC_JVM_HOME",
    "KLIO_KOTLINC_NATIVE",
    "KLIO_NO_AUTO_INSTALL_KOTLINC",
    "KONAN_DATA_DIR",
};

pub fn build(b: *std.Build) void {
    // The zig CLI hands the build runner a fresh random --seed on every
    // invocation, and addRunArtifact bakes that seed into each test binary's
    // argv, which is hashed into the run step's cache manifest -- so no test
    // run step could ever report "cached". Pin it; this overrides the CLI
    // --seed flag, so use -Dseed=N to vary the test-runner seed on purpose
    // (any new value also forces every test run step to re-execute).
    b.graph.random_seed = b.option(u32, "seed", "Test-runner seed (pinned by default so test runs cache; set to force re-runs)") orelse 0x6b6c696f;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Memoized configure-phase directory walks for declareDataDirs.
    var data_memo = std.StringHashMap([]const []const u8).init(b.allocator);

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
            for (itests_files) |spec| {
                const tmod = b.createModule(.{
                    .root_source_file = b.path(b.fmt("src/itests/{s}.zig", .{spec.name})),
                    .target = target,
                    .optimize = optimize,
                    .imports = imports,
                });
                const tbin = b.addTest(.{ .root_module = tmod });
                const run_t = b.addRunArtifact(tbin);
                run_t.setCwd(b.path("."));
                keyOnEnv(b, run_t, &interp_env_keys);
                if (spec.fuzz_env) keyOnEnv(b, run_t, &fuzz_env_keys);
                // Child-spawning tests need the `klio` binary installed first.
                if (spec.needs_exe) run_t.step.dependOn(b.getInstallStep());
                if (spec.parity_data) {
                    declareDataDirs(b, run_t, &data_memo, &stdlib_data_dirs);
                    declareDataDirs(b, run_t, &data_memo, &kotlinx_pack_dirs);
                }
                declareDataDirs(b, run_t, &data_memo, spec.dirs);
                test_step.dependOn(&run_t.step);
                // Targeted iteration: run just this itest (and build only its
                // dependency closure), e.g. `zig build itest-parity_object_init`.
                const one = b.step(
                    b.fmt("itest-{s}", .{spec.name}),
                    b.fmt("Run the {s} integration test", .{spec.name}),
                );
                one.dependOn(&run_t.step);
                // Also install the raw test binary so it can be looped from a
                // shell without the build graph re-running each iteration.
                const inst = b.addInstallArtifact(tbin, .{
                    .dest_sub_path = b.fmt("itest-{s}", .{spec.name}),
                });
                itest_bin_step.dependOn(&inst.step);
            }
            continue;
        }
        const t = b.addTest(.{ .root_module = mods.get(m.name).? });
        const run_t = b.addRunArtifact(t);
        keyOnEnv(b, run_t, &interp_env_keys);
        // Module tests that read repo data by relative path at runtime: pin
        // the cwd they assume and declare what they read as cache inputs.
        if (std.mem.eql(u8, m.name, "e2e")) {
            run_t.setCwd(b.path("."));
            declareDataDirs(b, run_t, &data_memo, &stdlib_data_dirs);
            declareDataDirs(b, run_t, &data_memo, &kotlinx_pack_dirs);
            declareDataDirs(b, run_t, &data_memo, &.{ "examples", "tests/corpus/expected" });
        } else if (std.mem.eql(u8, m.name, "stdlib_pack")) {
            run_t.setCwd(b.path("."));
            declareDataDirs(b, run_t, &data_memo, &stdlib_data_dirs);
        } else if (std.mem.eql(u8, m.name, "bench")) {
            run_t.setCwd(b.path("."));
            declareDataDirs(b, run_t, &data_memo, &.{"tests/fixtures/bench_corpus"});
        }
        test_step.dependOn(&run_t.step);
    }
}

/// Fold the listed environment variables (those that are set) into the run
/// step's child environment, and thereby into its cache manifest: Run.make
/// hashes every environ_map entry, so a pass recorded under one value of a
/// variable never satisfies a run under another. When none are set the step's
/// environment map stays null and nothing env-related is hashed.
fn keyOnEnv(b: *std.Build, run: *std.Build.Step.Run, names: []const []const u8) void {
    for (names) |name| {
        if (b.graph.environ_map.get(name)) |value| run.setEnvironmentVariable(name, value);
    }
}

/// Declare every regular file under the build-root-relative directories as a
/// file input of the run step, so the step's cache manifest covers the data
/// the test binary reads at runtime (Zig hashes declared inputs only; a run
/// step has no directory-input API). Adding/removing a file changes the
/// declared path set and editing one changes its content hash, so each case
/// re-runs exactly the steps that declare that directory. A missing directory
/// declares nothing: the test then fails at runtime and failed steps are
/// never cached.
fn declareDataDirs(
    b: *std.Build,
    run: *std.Build.Step.Run,
    memo: *std.StringHashMap([]const []const u8),
    dirs: []const []const u8,
) void {
    for (dirs) |dir| {
        for (listDataFiles(b, memo, dir)) |rel| run.addFileInput(b.path(rel));
    }
}

/// Configure-phase walk of one build-root-relative directory, memoized so the
/// many run steps that declare the same tree share a single walk. The list is
/// sorted so the manifest hash is independent of readdir order.
fn listDataFiles(
    b: *std.Build,
    memo: *std.StringHashMap([]const []const u8),
    dir: []const u8,
) []const []const u8 {
    if (memo.get(dir)) |files| return files;
    const io = b.graph.io;
    var files: std.ArrayList([]const u8) = .empty;
    collect: {
        var d = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch break :collect;
        defer d.close(io);
        var walker = d.walk(b.allocator) catch @panic("oom");
        defer walker.deinit();
        while (walker.next(io) catch |e|
            std.debug.panic("walking {s}: {s}", .{ dir, @errorName(e) })) |entry|
        {
            if (entry.kind != .file) continue;
            files.append(b.allocator, b.fmt("{s}/{s}", .{ dir, entry.path })) catch @panic("oom");
        }
    }
    std.mem.sort([]const u8, files.items, {}, stringLessThan);
    const owned = files.toOwnedSlice(b.allocator) catch @panic("oom");
    memo.put(b.dupe(dir), owned) catch @panic("oom");
    return owned;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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
