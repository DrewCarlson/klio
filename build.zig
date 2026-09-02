const std = @import("std");
const stdlib_sources = @import("src/stdlib/stdlib_sources.zig");

/// One Zig module per former Rust crate. `deps` are the non-dev crate
/// dependencies (the acyclic graph). `tested` flips on once a module has been
/// ported with passing `test {}` blocks, which adds it to `zig build test`.
const Mod = struct {
    name: []const u8,
    deps: []const []const u8 = &.{},
    tested: bool = false,
    /// Root source override for a module that does not live at the default
    /// `src/{name}/{name}.zig` (e.g. a shared file that sits inside another
    /// module's directory).
    src: ?[]const u8 = null,
};

/// Build-root-relative root source path for a module.
fn modSource(b: *std.Build, m: Mod) []const u8 {
    return m.src orelse b.fmt("src/{s}/{s}.zig", .{ m.name, m.name });
}

const mod_list = [_]Mod{
    .{ .name = "span", .tested = true },
    .{ .name = "diagnostics", .deps = &.{"span"}, .tested = true },
    .{ .name = "ast", .deps = &.{"span"}, .tested = true },
    .{ .name = "compose_pass", .deps = &.{ "ast", "span" }, .src = "src/compose_pass/compose_pass.zig", .tested = true },
    .{ .name = "runtime", .deps = &.{ "ast", "span" }, .tested = true },
    .{ .name = "types", .deps = &.{ "ast", "diagnostics", "span" }, .tested = true },
    .{ .name = "lexer", .deps = &.{ "diagnostics", "span" }, .tested = true },
    .{ .name = "pack", .deps = &.{ "ast", "span", "types" }, .tested = true },
    .{ .name = "parser", .deps = &.{ "ast", "diagnostics", "lexer", "span" }, .tested = true },
    // The kotlinx-serialization compiler-plugin replacement: synthesizes the
    // generated serializer declarations for every `@Serializable` class as
    // ordinary Kotlin (parsed from generated source) before lowering.
    .{ .name = "serialization_pass", .deps = &.{ "ast", "span", "lexer", "parser", "diagnostics" }, .src = "src/serialization_pass/serialization_pass.zig", .tested = true },
    .{ .name = "jit", .tested = true },
    .{ .name = "ir", .deps = &.{ "span", "ast", "types", "runtime", "diagnostics", "jit", "applicability", "compose_pass" }, .tested = true },
    // Shared overload-resolution applicability engine. Lives inside the ir
    // module's directory but is its own module (it depends on ir for TypeRef /
    // Param / FuncId) so the runtime scorers can import it. `ir` in turn
    // imports it for the lowering-time `resolveCall` scorer; Zig permits the
    // module cycle since neither side forms a comptime dependency loop.
    .{ .name = "applicability", .deps = &.{ "ir", "span" }, .src = "src/ir/applicability.zig", .tested = true },
    .{ .name = "stdlib", .deps = &.{ "runtime", "pack" }, .tested = true },
    .{ .name = "cfa", .deps = &.{ "ast", "diagnostics", "lexer", "parser", "span", "types" }, .tested = true },
    .{ .name = "resolver", .deps = &.{ "span", "ast", "diagnostics", "types", "stdlib" }, .tested = true },
    .{ .name = "interp_ir", .deps = &.{ "ir", "runtime", "ast", "span", "stdlib", "diagnostics", "applicability", "compose_pass", "serialization_pass" }, .tested = true },
    .{ .name = "stdlib_pack", .deps = &.{ "pack", "stdlib" }, .tested = true },
    .{ .name = "stdlib_gen", .deps = &.{ "pack", "stdlib" }, .tested = true },
    .{ .name = "kotlinx_atomicfu", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "kotlinx_coroutines", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "kotlinx_datetime", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "kotlinx_io", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "kotlinx_serialization", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "compose_runtime", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "compose_ui", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "ktor_client", .deps = &.{ "runtime", "stdlib" }, .tested = true },
    .{ .name = "typeck", .deps = &.{ "span", "ast", "diagnostics", "resolver", "types", "cfa" }, .tested = true },
    .{ .name = "diagnostics_gen", .deps = &.{}, .tested = true },
    .{ .name = "test_runner", .deps = &.{ "ast", "ir", "runtime", "interp_ir", "span" }, .tested = true },
    .{ .name = "cli", .deps = &.{ "span", "diagnostics", "lexer", "parser", "resolver", "typeck", "ir", "interp_ir", "ast", "pack", "stdlib", "stdlib_pack", "kotlinx_atomicfu", "kotlinx_coroutines", "kotlinx_datetime", "kotlinx_io", "kotlinx_serialization", "compose_runtime", "compose_ui", "ktor_client", "runtime", "types", "test_runner" }, .tested = true },
    .{ .name = "parity", .deps = &.{ "ast", "interp_ir", "kotlinx_atomicfu", "kotlinx_coroutines", "kotlinx_datetime", "kotlinx_io", "kotlinx_serialization", "compose_runtime", "compose_ui", "lexer", "pack", "parser", "resolver", "runtime", "span", "stdlib", "stdlib_pack", "typeck" }, .tested = true },
    .{ .name = "bench", .deps = &.{ "ast", "interp_ir", "lexer", "parity", "parser", "resolver", "runtime", "span", "typeck" }, .tested = true },
    // End-to-end corpus test: runs every examples/*.kt in-process via the
    // parity pipeline and asserts against tests/corpus/expected/.
    .{ .name = "e2e", .deps = &.{ "parity", "ir" }, .tested = true },
    // Integration suites ported from crates/*/tests.
    .{ .name = "itests", .deps = &.{ "parity", "typeck", "resolver", "parser", "lexer", "cfa", "runtime", "ast", "span", "diagnostics", "types", "pack", "ir", "interp_ir", "stdlib" }, .tested = true },
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
    /// Spawns a `klio` binary as a child process. The run step installs the
    /// harness-optimized `zig-out/bin/klio-harness` and points the test at it
    /// via `KLIO_ITEST_BIN`.
    needs_exe: bool = false,
    /// Point KLIO_ITEST_BIN at a ReleaseFast harness instead of the
    /// ReleaseSafe default — the throughput-gate policy (measured
    /// 1.18-1.20x on the compose suite). Correctness coverage keeps
    /// ReleaseSafe everywhere else (sweeps, units, the other itests).
    fast_exe: bool = false,
    /// Spends its runtime interpreting Kotlin programs (in-process through
    /// the parity pipeline, or via a spawned `klio` child), so the binary
    /// compiles with the harness optimize mode. Unit-style suites that lean
    /// on Debug `testing.allocator` leak/UAF fidelity set this false and
    /// stay on the default optimize mode.
    interprets: bool = true,
    /// Relative run cost for `-Ditest-shard` bin packing, scaled to the CI
    /// runner (4 vCPU Debug), where CPU-bound suites run ~2.5x slower than
    /// locally but child-timeout-bound suites (androidx) do not. Keep the
    /// heavy suites' weights roughly current so the shards stay balanced.
    weight: u16 = 1,
    /// Split this suite into N run steps, each with KLIO_COMMONTEST_SHARD=i/N
    /// so a single heavy suite can spread across CI shard jobs. `weight`
    /// applies to each slice.
    shards: u8 = 1,
};

const itests_files = [_]Itest{
    .{ .name = "cfa_builder", .parity_data = false, .interprets = false },
    .{ .name = "cfa_smartcast", .parity_data = false, .interprets = false },
    .{ .name = "parity_array_bulk_ops" },
    .{ .name = "parity_closures_deep" },
    .{ .name = "parity_collections_intensive" },
    // parity_conformance runs inside parity_threaded_litmus now (same
    // fixture-driver shape, one binary, both fixture dirs declared there and
    // its weight folded in); the deleted entry is not a dropped suite.
    .{ .name = "parity_corpus_pinned", .dirs = &.{ "tests/fixtures/parity_corpus", "examples/file_private_collision" }, .weight = 50 },
    .{ .name = "parity_coroutines_realistic", .dirs = &.{"tests/fixtures/coroutine_smoke"}, .weight = 16 },
    .{ .name = "parity_data_class_features" },
    .{ .name = "parity_dsl_operators" },
    .{ .name = "parity_exceptions_and_flow" },
    .{ .name = "parity_extension_resolution", .weight = 12 },
    .{ .name = "parity_generics_advanced" },
    .{ .name = "parity_inheritance_dispatch" },
    .{ .name = "parity_inner_classes" },
    .{ .name = "parity_lambdas_and_dispatch", .weight = 8 },
    .{ .name = "parity_named_args_defaults" },
    .{ .name = "parity_nullability_deep" },
    .{ .name = "parity_object_init", .weight = 12 },
    .{ .name = "parity_operator_edge_cases" },
    .{ .name = "parity_properties_accessors" },
    .{ .name = "parity_sealed_when_patterns" },
    .{ .name = "parity_strings_numbers" },
    .{ .name = "parity_stdlib_isolation", .weight = 25 },
    .{ .name = "parity_suspend_shapes" },
    // needs_exe: the eager-parity test spawns the harness (`run` + `dump-ir`)
    // — without it the child fell back to a stale `zig-out/bin/klio` and the
    // pins tested weeks-old lowering.
    .{ .name = "parity_threaded_litmus", .dirs = &.{ "tests/fixtures/threaded_litmus", "tests/fixtures/conformance" }, .weight = 35, .needs_exe = true },
    .{ .name = "parity_type_system_shapes" },
    .{ .name = "parity_visibility_modifiers" },
    .{ .name = "explicit_backing_fields" },
    .{ .name = "annotation_targets" },
    .{ .name = "context_parameters" },
    .{ .name = "resolve_ambiguity" },
    .{ .name = "parser_corpus", .parity_data = false, .interprets = false },
    .{ .name = "runtime_objref_threads", .parity_data = false, .interprets = false },
    .{ .name = "typeck_negative", .parity_data = false, .interprets = false, .dirs = &.{"tests/fixtures/typeck_negative"} },
    .{ .name = "check_examples", .dirs = &.{"examples"}, .weight = 10 },
    .{ .name = "differential", .dirs = &.{ "examples", "tests/fixtures/coroutine_smoke" }, .weight = 60 },
    .{ .name = "fuzz_closures_suspend", .fuzz_env = true, .weight = 20 },
    // End-to-end ktor gate: child `klio` + in-test HTTP server + installed packs.
    .{ .name = "ktor_client_get", .parity_data = false, .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-kotlinx-serialization",
        "kotlin-klio/klio-ktor",
    }, .weight = 25 },
    // Async ByteChannel gate: upstream channel write side (Slot suspension
    // protocol) through child `klio` + installed packs.
    .{ .name = "ktor_channel_async", .parity_data = false, .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-ktor",
    }, .weight = 40 },
    // End-to-end ktor server gate: a background child `klio` runs
    // `embeddedServer` (routing, params, headers, status, typed JSON) while
    // the test drives it as the HTTP client over real sockets.
    .{ .name = "ktor_server", .parity_data = false, .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-kotlinx-serialization",
        "kotlin-klio/klio-ktor",
    }, .weight = 40 },
    // Threaded stress gate for the pack concurrency primitives
    // (ConcurrentMap/Attributes computeIfAbsent once-only, the ktor locks
    // actuals, ByteChannel written from a Default worker) through child
    // `klio` + installed packs, with KLIO_RACE_JITTER widening the windows.
    .{ .name = "concurrency_stress", .parity_data = false, .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-ktor",
    }, .weight = 30 },
    // Reified inline Json extension shapes through the installed pack
    // (kotlinc-verified expected output; the in-process parity harness
    // does not fold in the serialization pack).
    .{ .name = "json_reified_inline", .parity_data = false, .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-serialization",
    }, .weight = 5 },
    // Baked stdlib image gate: bake -> hit -> fallback -> staleness ->
    // corruption through a child `klio` against a scratch HOME, plus the
    // in-process bake/load round trip.
    .{ .name = "stdlib_image", .needs_exe = true, .weight = 12 },
    // Single-executable bundle gate: `klio bundle` output runs against an
    // empty HOME byte-identically to `klio run` (argv, resources, exit
    // code, stdin, corruption refusal, inspect, determinism).
    .{ .name = "bundle_smoke", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-serialization",
        "kotlin-klio/klio-bundle",
    }, .weight = 15 },
    // Cross-target bundling gate: stub + shim resolve via KLIO_STUB_DIR
    // (no network), assembly is byte surgery, the fake-target bundle
    // boots; the offline hint and --stub override are asserted.
    .{ .name = "bundle_cross", .needs_exe = true, .weight = 10 },
    // UI bundle gate: the Skia shim embeds, extracts to the per-user
    // cache on first launch, and renders the headless pixel gate
    // byte-identically to a direct run (skips without the built shim).
    .{ .name = "bundle_ui", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-androidx-collection",
        "kotlin-klio/klio-compose-runtime-engine",
        "kotlin-klio/klio-compose-ui",
    }, .weight = 40 },
    // Bootstrapping proof: Kotlin's own stdlib commonTest sources run through
    // a child `klio test` against the installed kotlin.test pack.
    .{ .name = "stdlib_commontest", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlin-test",
        "kotlin/libraries/kotlin.test",
        "kotlin/libraries/stdlib/test",
        "tests/stdlib_commontest_actuals",
    }, .weight = 110, .shards = 2 },
    // androidx.collection's own commonTest sources run through a child
    // `klio test` against the installed androidx.collection pack.
    .{ .name = "androidx_collection_commontest", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-androidx-collection",
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlin-test",
    }, .weight = 40 },
    // The upstream Compose runtime's own test suite (CompositionTests,
    // RestartTests, MovableContentTests, the snapshot suites) run through a
    // child `klio test` against the ENGINE pack with the `@Composable` lowering
    // plugin — THE compose conformance gate.
    .{ .name = "compose_plugin_commontest", .needs_exe = true, .fast_exe = true, .dirs = &.{
        "kotlin-klio/klio-compose-runtime-engine",
        "kotlin-klio/klio-androidx-collection",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlin-test",
    }, .weight = 90 },
    // Each bundled library's own commonTest sources run through a child
    // `klio test` against its installed pack (see commontest_support.zig).
    .{ .name = "atomicfu_commontest", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlin-test",
    }, .weight = 30 },
    .{ .name = "io_commontest", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-kotlin-test",
    }, .weight = 30 },
    .{ .name = "datetime_commontest", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-datetime",
        "kotlin-klio/klio-kotlinx-serialization",
        "kotlin-klio/klio-kotlin-test",
    }, .weight = 30 },
    .{ .name = "serialization_commontest", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-serialization",
        "kotlin-klio/klio-kotlin-test",
    }, .weight = 40 },
    .{ .name = "serialization_json_commontest", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-serialization",
        "kotlin-klio/klio-kotlin-test",
    }, .weight = 60 },
    .{ .name = "coroutines_commontest", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlin-test",
    }, .weight = 90 },
    .{ .name = "ktor_commontest", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-ktor",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlin-test",
    }, .weight = 90 },
    .{ .name = "compose_ui_commontest", .needs_exe = true, .dirs = &.{
        "kotlin-klio/klio-compose-runtime",
        "kotlin-klio/klio-compose-runtime-engine",
        "kotlin-klio/klio-compose-ui-util",
        "kotlin-klio/klio-compose-ui-geometry",
        "kotlin-klio/klio-compose-ui-unit",
        "kotlin-klio/klio-compose-ui-graphics",
        "kotlin-klio/klio-compose-ui-text",
        "kotlin-klio/klio-compose-ui-core",
        "kotlin-klio/klio-androidx-collection",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlin-test",
        "tests/compose_ui_commontest_actuals",
    }, .weight = 60 },
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
    "kotlin-klio/kotlin-random",
    "kotlin-klio/kotlin-text",
    "kotlin/libraries/stdlib/native-wasm/src/generated",
    "kotlin/libraries/stdlib/native-wasm/src/kotlin/text",
    "kotlin/libraries/stdlib/wasm/src/kotlin/concurrent/atomics",
    "kotlin-klio/kotlin-uuid",
};

/// Read by the SourcePacks/CompiledPacks load modes (each pack's klio.toml is
/// opened on every load; sources when the program's imports pull the pack in).
const kotlinx_pack_dirs = [_][]const u8{
    "kotlin-klio/klio-kotlinx-coroutines",
    "kotlin-klio/klio-kotlinx-atomicfu",
    "kotlin-klio/klio-kotlinx-io",
    "kotlin-klio/klio-androidx-collection",
    "kotlin-klio/klio-compose-runtime-engine",
    "kotlin-klio/klio-mosaic",
    "kotlin-klio/klio-compose-ui",
    "kotlin-klio/klio-compose-ui-util",
    "kotlin-klio/klio-compose-ui-geometry",
    "kotlin-klio/klio-compose-ui-unit",
    "kotlin-klio/klio-compose-ui-graphics",
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
    "KLIO_STDLIB_IMAGE",
    "KLIO_TRACE_STDLIB_IMAGE",
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
    // Program-running harness binaries (parity itests, e2e, bench, the
    // fuzzer and the differential) spend their time interpreting Kotlin;
    // a Debug interpreter pays ~5x on every program's embedded-stdlib
    // assembly. They compile ReleaseSafe — bounds/overflow/unreachable
    // checks stay on — while the per-module unit tests keep the default
    // optimize mode so `testing.allocator` leak/UAF detection keeps full
    // Debug fidelity.
    const harness_optimize = b.option(
        std.builtin.OptimizeMode,
        "harness-optimize",
        "Optimize mode for the program-running test harnesses (default ReleaseSafe)",
    ) orelse .ReleaseSafe;

    // iOS/simulator SDK for the target artifacts (see resolveAppleSdk). Null for
    // every other target; wired onto the target module universe + target zstd +
    // the klio executables below, never onto the host-run build tools.
    const apple_sdk: ?[]const u8 = resolveAppleSdk(b, target);
    // Android NDK sysroot for the target artifacts (see resolveAndroidNdk). Null
    // for every other target; wired onto the same artifacts as apple_sdk.
    const android_ndk: ?AndroidNdk = resolveAndroidNdk(b, target);

    // The Compose-UI Skia backend: libklio_skia.so (the compose_ui module
    // dlopens it) is built by the system C++ toolchain because the prebuilt
    // Skia archives use the GNU libstdc++ ABI (zig cc/libc++ cannot link them);
    // see plans/UI-RENDERING-PACKS.md. Defaults ON when the vendored libs are
    // present (`scripts/fetch-skia.sh`); a checkout without them stays green.
    // On macOS the shim defaults to the Cocoa window + Metal backend (see
    // buildSkiaShim), so a plain `zig build` produces a UI-capable zig-out.
    const skia_libs_present = skiaLibsPresent(b, target);
    const want_skia = b.option(bool, "skia", "Build the Compose-UI Skia rendering backend (default: on when third_party/skia is present for the target)") orelse skia_libs_present;

    // Memoized configure-phase directory walks for declareDataDirs.
    var data_memo = std.StringHashMap([]const []const u8).init(b.allocator);

    var mods = std.StringHashMap(*std.Build.Module).init(b.allocator);
    defer mods.deinit();

    for (mod_list) |m| {
        const mod = b.addModule(m.name, .{
            .root_source_file = b.path(modSource(b, m)),
            .target = target,
            .optimize = optimize,
        });
        mods.put(m.name, mod) catch @panic("oom");
    }
    for (mod_list) |m| {
        const mod = mods.get(m.name).?;
        for (m.deps) |d| mod.addImport(d, mods.get(d).?);
    }
    if (apple_sdk) |sdk| {
        var it = mods.valueIterator();
        while (it.next()) |m| wireAppleSdk(b, m.*, sdk);
    }
    if (android_ndk) |ndk| {
        var it = mods.valueIterator();
        while (it.next()) |m| wireAndroidNdk(b, m.*, ndk);
    }

    // The pack format compresses sections with zstd. Zig std ships only a
    // zstd decoder, so the encoder is linked from the vendored zstd C
    // sources, compiled here into a static library. The symbols are
    // declared extern in src/pack/zstd.zig (no header needed). Link inputs
    // attached to the pack module flow into every artifact that imports it.
    const zstd = buildZstd(b, target, optimize);
    if (apple_sdk) |sdk| wireAppleSdk(b, zstd.root_module, sdk);
    if (android_ndk) |ndk| wireAndroidNdk(b, zstd.root_module, ndk);
    const pack_mod = mods.get("pack").?;
    pack_mod.link_libc = true;
    pack_mod.linkLibrary(zstd);

    // The compose_ui module dlopens the Skia backend (std.DynLib), which needs
    // libc; flow it into every artifact that imports compose_ui.
    mods.get("compose_ui").?.link_libc = true;

    // ir (eval/jit_loop) selects std.heap.c_allocator on the GC-off path, so its
    // test build needs libc too.
    mods.get("ir").?.link_libc = true;

    // The AArch64 JIT backend uses Darwin's per-thread MAP_JIT write toggle and
    // instruction-cache invalidate from libSystem. Link libc into every artifact
    // that pulls in the jit module so those externs resolve on Apple targets.
    if (target.result.os.tag.isDarwin()) mods.get("jit").?.link_libc = true;

    // Second per-(module, optimize) universe for the harness binaries.
    // Zig modules are keyed by (root source, optimize), so the harness
    // graph is a separate compilation of the same sources; it shares the
    // global cache and only rebuilds when sources change. When the two
    // modes coincide the Debug universe is reused as-is.
    var harness_mods = std.StringHashMap(*std.Build.Module).init(b.allocator);
    defer harness_mods.deinit();
    if (harness_optimize == optimize) {
        var it = mods.iterator();
        while (it.next()) |e| harness_mods.put(e.key_ptr.*, e.value_ptr.*) catch @panic("oom");
    } else {
        for (mod_list) |m| {
            const mod = b.createModule(.{
                .root_source_file = b.path(modSource(b, m)),
                .target = target,
                .optimize = harness_optimize,
            });
            harness_mods.put(m.name, mod) catch @panic("oom");
        }
        for (mod_list) |m| {
            const mod = harness_mods.get(m.name).?;
            for (m.deps) |d| mod.addImport(d, harness_mods.get(d).?);
        }
        const zstd_harness = buildZstd(b, target, harness_optimize);
        const pack_harness = harness_mods.get("pack").?;
        pack_harness.link_libc = true;
        pack_harness.linkLibrary(zstd_harness);
        harness_mods.get("compose_ui").?.link_libc = true;
        harness_mods.get("ir").?.link_libc = true;
        if (target.result.os.tag.isDarwin()) harness_mods.get("jit").?.link_libc = true;
        if (apple_sdk) |sdk| {
            var it = harness_mods.valueIterator();
            while (it.next()) |m| wireAppleSdk(b, m.*, sdk);
            wireAppleSdk(b, zstd_harness.root_module, sdk);
        }
    }

    // The stdlib pack is baked into the binary: embed_gen builds it from
    // the repo source checkout at build time and the bytes reach
    // `stdlib_pack` through the `stdlib_embedded` module, so the installed
    // binary runs from any directory (`stdlibPackBytes` still prefers the
    // env override and the cwd checkout when present). Every source the
    // builder reads is declared as a run-step input, so editing a stdlib
    // `.kt` regenerates the embed on the next build.
    //
    // embed_gen RUNS at build time, so it always compiles for the build
    // HOST — a `-Dtarget` cross build (the release stubs) reuses the
    // target universe only when it coincides with the host, and otherwise
    // gets its own host-target instances of embed_gen's module closure.
    const host_resolved = b.resolveTargetQuery(.{});
    const embed_gen_mods = blk: {
        const cross_build = target.result.os.tag != host_resolved.result.os.tag or
            target.result.cpu.arch != host_resolved.result.cpu.arch;
        if (!cross_build) break :blk mods;
        var host_mods = std.StringHashMap(*std.Build.Module).init(b.allocator);
        for (mod_list) |m| {
            const mod = b.createModule(.{
                .root_source_file = b.path(modSource(b, m)),
                .target = host_resolved,
                .optimize = optimize,
            });
            host_mods.put(m.name, mod) catch @panic("oom");
        }
        for (mod_list) |m| {
            const mod = host_mods.get(m.name).?;
            for (m.deps) |d| mod.addImport(d, host_mods.get(d).?);
        }
        const zstd_host = buildZstd(b, host_resolved, optimize);
        const pack_host = host_mods.get("pack").?;
        pack_host.link_libc = true;
        pack_host.linkLibrary(zstd_host);
        host_mods.get("compose_ui").?.link_libc = true;
        host_mods.get("ir").?.link_libc = true;
        break :blk host_mods;
    };
    const embed_gen = b.addExecutable(.{
        .name = "stdlib-embed-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stdlib_pack/embed_gen.zig"),
            .target = host_resolved,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pack", .module = embed_gen_mods.get("pack").? },
                .{ .name = "stdlib", .module = embed_gen_mods.get("stdlib").? },
            },
        }),
    });
    const embed_run = b.addRunArtifact(embed_gen);
    embed_run.setCwd(b.path("."));
    const embedded_pack = embed_run.addOutputFileArg("stdlib.klio-pack");
    for (stdlib_sources.CURATED_UPSTREAM_SOURCES) |rel|
        embed_run.addFileInput(b.path(b.fmt("{s}/{s}", .{ stdlib_sources.UPSTREAM_STDLIB_ROOT, rel })));
    for (stdlib_sources.KLIO_STDLIB_ACTUAL_FILES) |rel|
        embed_run.addFileInput(b.path(b.fmt("{s}/{s}", .{ stdlib_sources.KLIO_STDLIB_DIR, rel })));
    wireEmbeddedPack(b, &mods, target, optimize, embedded_pack);
    if (harness_optimize != optimize) {
        wireEmbeddedPack(b, &harness_mods, target, harness_optimize, embedded_pack);
    }

    // Bake the parity harness's EmbeddedOnly dependency bases once per
    // build. Every parity-pipeline test process then loads the lowered
    // stdlib base from the image instead of re-parsing and re-lowering
    // ~4500 declarations; the generator re-runs exactly when the stdlib
    // sources or the interpreter modules change.
    const base_gen = b.addExecutable(.{
        .name = "parity-base-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parity/base_gen.zig"),
            .target = target,
            .optimize = harness_optimize,
            .imports = &.{
                .{ .name = "parity", .module = harness_mods.get("parity").? },
            },
        }),
    });
    const base_gen_run = b.addRunArtifact(base_gen);
    base_gen_run.setCwd(b.path("."));
    const base_images = base_gen_run.addOutputDirectoryArg("parity-base");
    for (stdlib_sources.CURATED_UPSTREAM_SOURCES) |rel|
        base_gen_run.addFileInput(b.path(b.fmt("{s}/{s}", .{ stdlib_sources.UPSTREAM_STDLIB_ROOT, rel })));
    for (stdlib_sources.KLIO_STDLIB_ACTUAL_FILES) |rel|
        base_gen_run.addFileInput(b.path(b.fmt("{s}/{s}", .{ stdlib_sources.KLIO_STDLIB_DIR, rel })));
    const base_images_install = b.addInstallDirectory(.{
        .source_dir = base_images,
        .install_dir = .prefix,
        .install_subdir = "parity-base",
    });
    const base_images_path = b.getInstallPath(.prefix, "parity-base");

    // Install the compiled static library to zig-out/lib/libzstd.a so
    // per-module verification (scripts/zigcheck.py) can link the extern
    // ZSTD_* symbols without re-running the whole build graph.
    b.installArtifact(zstd);
    const zstd_lib_step = b.step("zstd-lib", "Build and install the vendored zstd static library");
    zstd_lib_step.dependOn(&b.addInstallArtifact(zstd, .{}).step);

    const exe = b.addExecutable(.{
        .name = b.fmt("klio{s}", .{targetBinSuffix(target)}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // libc for the GC backing (`c_allocator`) + the macOS
            // `malloc_zone_pressure_relief` page trim that keeps process RSS
            // tracking the live set under the tracing collector.
            .link_libc = true,
            .imports = &.{
                .{ .name = "cli", .module = mods.get("cli").? },
                .{ .name = "runtime", .module = mods.get("runtime").? },
            },
        }),
    });
    if (apple_sdk) |sdk| wireAppleSdk(b, exe.root_module, sdk);
    if (android_ndk) |ndk| wireAndroidNdk(b, exe.root_module, ndk);
    b.installArtifact(exe);

    // The C-ABI runtime library the C transpiler's output links against
    // (plans/c-transpiler-plan.md stage 1): `zig build klio-rt` installs
    // lib/libklio_rt.a + include/klio_rt.h. Ships inside every transpiled
    // binary, so it builds from the HARNESS module universe at
    // harness_optimize (ReleaseSafe by default) — the plain build's
    // Debug universe made a transpiled binary's interpreter half run 3x
    // slower than klio-harness, sinking the native floor the campaign
    // guarantees (native >= interpreted, apples-to-apples).
    const rt_lib = b.addLibrary(.{
        .name = "klio_rt",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/klio_rt/klio_rt.zig"),
            .target = target,
            .optimize = harness_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "cli", .module = harness_mods.get("cli").? },
                .{ .name = "runtime", .module = harness_mods.get("runtime").? },
                .{ .name = "ir", .module = harness_mods.get("ir").? },
            },
        }),
    });
    // Link-free census driver: runs any commontest suite from the shared
    // registry against the installed harness — one harness rebuild instead
    // of a per-suite itest link (plans/verification-latency-campaign.md).
    const census_exe = b.addExecutable(.{
        .name = "klio-census",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/itests/census_main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .imports = &.{
                .{ .name = "runtime", .module = mods.get("runtime").? },
            },
        }),
    });
    const census_step = b.step("klio-census", "Build + install the link-free census driver");
    census_step.dependOn(&b.addInstallArtifact(census_exe, .{}).step);

    const rt_step = b.step("klio-rt", "Build + install the C-ABI runtime static library");
    rt_step.dependOn(&b.addInstallArtifact(rt_lib, .{}).step);
    rt_step.dependOn(&b.addInstallHeaderFile(b.path("include/klio_rt.h"), "klio_rt.h").step);

    // Build + install the Compose-UI Skia backend as a shared library the
    // compose_ui module dlopens at runtime. Built with system g++ (libstdc++
    // ABI); the resulting .so is self-contained (static Skia + deps linked in).
    const skia_lib_step = b.step("skia-lib", "Build + install the Compose-UI Skia backend shared library");
    if (want_skia) {
        if (buildSkiaShim(b, target, apple_sdk)) |so| {
            const inst = b.addInstallFileWithDir(so, .lib, skiaLibName(target.result.os.tag));
            skia_lib_step.dependOn(&inst.step);
            b.getInstallStep().dependOn(&inst.step);
        } else {
            std.log.warn("-Dskia set but Skia libs for the target are missing; run scripts/fetch-skia.sh", .{});
        }
    }

    // Harness-optimized `klio` for the child-spawning itests: each spawned
    // program pays the embedded-stdlib assembly, so those tests point at
    // this binary (via KLIO_ITEST_BIN) instead of the Debug install.
    // A non-default optimize mode gets its own binary name
    // (`klio-harness-Debug`), so an edit-loop Debug build can never
    // silently replace the ReleaseSafe binary the sweep scripts target
    // (a resident `--watch` daemon did exactly that once).
    const harness_bin_name = if (harness_optimize == .ReleaseSafe)
        "klio-harness"
    else
        b.fmt("klio-harness-{s}", .{@tagName(harness_optimize)});
    const harness_exe = b.addExecutable(.{
        .name = harness_bin_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = harness_optimize,
            .imports = &.{
                .{ .name = "cli", .module = harness_mods.get("cli").? },
                .{ .name = "runtime", .module = harness_mods.get("runtime").? },
            },
        }),
    });
    if (apple_sdk) |sdk| wireAppleSdk(b, harness_exe.root_module, sdk);
    if (android_ndk) |ndk| wireAndroidNdk(b, harness_exe.root_module, ndk);
    const harness_exe_step = b.step("klio-harness", "Build+install the harness-optimized klio binary");
    harness_exe_step.dependOn(&b.addInstallArtifact(harness_exe, .{}).step);

    // The throughput-gate harness: ReleaseFast, its own name so it can never
    // shadow the ReleaseSafe binary the sweep scripts target. Only the gate
    // suites marked `fast_exe` spawn it.
    const fast_harness_exe = b.addExecutable(.{
        .name = "klio-harness-fast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "cli", .module = harness_mods.get("cli").? },
                .{ .name = "runtime", .module = harness_mods.get("runtime").? },
            },
        }),
    });
    if (apple_sdk) |sdk| wireAppleSdk(b, fast_harness_exe.root_module, sdk);
    if (android_ndk) |ndk| wireAndroidNdk(b, fast_harness_exe.root_module, ndk);
    const fast_harness_step = b.step("klio-harness-fast", "Build+install the ReleaseFast gate harness");
    fast_harness_step.dependOn(&b.addInstallArtifact(fast_harness_exe, .{}).step);

    // Static interpreter library for a mobile app host (iOS/Android). The app's
    // native launch code links this archive and calls the exported C `klio_run`
    // (src/mobile_lib.zig); there is no spawned klio executable on device. Only
    // meaningful for a mobile -Dtarget; built via the `mobile-lib` step. Shares
    // the target module universe, so it inherits the embedded stdlib pack, the
    // zstd link, and the Apple SDK wiring.
    const mobile_lib = b.addLibrary(.{
        .name = b.fmt("klio{s}", .{targetBinSuffix(target)}),
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mobile_lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "cli", .module = mods.get("cli").? },
                .{ .name = "runtime", .module = mods.get("runtime").? },
                .{ .name = "compose_ui", .module = mods.get("compose_ui").? },
            },
        }),
    });
    if (apple_sdk) |sdk| wireAppleSdk(b, mobile_lib.root_module, sdk);
    if (android_ndk) |ndk| wireAndroidNdk(b, mobile_lib.root_module, ndk);
    // The app host links this archive with the platform toolchain (clang/NDK),
    // not zig, so the Zig compiler-rt/ubsan builtins must travel inside the
    // archive (zig bundles them into an executable, but not a static lib).
    mobile_lib.bundle_compiler_rt = true;
    mobile_lib.bundle_ubsan_rt = true;
    const mobile_lib_step = b.step("mobile-lib", "Build the static interpreter library for a mobile app host");
    mobile_lib_step.dependOn(&b.addInstallArtifact(mobile_lib, .{}).step);
    // The interpreter references the vendored zstd, which zig keeps in a separate
    // archive (linked at final-link for the exe). The app host links with the
    // platform toolchain, so install libzstd.a alongside for it to link too.
    mobile_lib_step.dependOn(&b.addInstallArtifact(zstd, .{}).step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the klio binary");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run the fast module unit tests");
    const itest_step = b.step("itest", "Run the integration test suite (slow — interprets whole programs)");
    const itest_bin_step = b.step("itest-bin", "Build+install standalone itest binaries for stress looping");

    // -Ditest-shard=K/N partitions the integration suite (the itest binaries
    // plus the e2e and bench module tests) into N weight-balanced bins and
    // attaches only bin K to the `itest` step, so CI fans the suite across
    // parallel jobs. Without the option every suite runs. Assignment is
    // greedy over descending declared weights, so it is deterministic for a
    // given suite list.
    const shards = ItestShards.fromOption(b);
    // Serialize the run steps attached to `itest` within a shard. Each
    // commontest suite spawns a per-core worker pool of child `klio test`
    // processes; running several suites concurrently oversubscribes the CI
    // runner many-fold and starves compute-heavy suites below their ratchets
    // (io_commontest passes ~1120 alone but ~370 when it shares a shard). Chain
    // each included run step after the previous so exactly one suite runs at a
    // time with the full core count. Shards still run in parallel across CI
    // jobs, so wall-clock stays fanned out. (Targeted `itest-<name>` steps and
    // the fast `test` step are unaffected — only the shard-attached chain.)
    var prev_itest_run: ?*std.Build.Step = null;
    for (mod_list) |m| {
        if (!m.tested) continue;
        if (std.mem.eql(u8, m.name, "itests")) {
            // One test binary per integration-test file (process isolation).
            const imports = b.allocator.alloc(std.Build.Module.Import, m.deps.len) catch @panic("oom");
            for (m.deps, 0..) |d, i| imports[i] = .{ .name = d, .module = mods.get(d).? };
            const harness_imports = b.allocator.alloc(std.Build.Module.Import, m.deps.len) catch @panic("oom");
            for (m.deps, 0..) |d, i| harness_imports[i] = .{ .name = d, .module = harness_mods.get(d).? };
            for (itests_files) |spec| {
                const tmod = b.createModule(.{
                    .root_source_file = b.path(b.fmt("src/itests/{s}.zig", .{spec.name})),
                    .target = target,
                    .optimize = if (spec.interprets) harness_optimize else optimize,
                    .imports = if (spec.interprets) harness_imports else imports,
                });
                const tbin = b.addTest(.{ .root_module = tmod });
                // Targeted iteration: run just this itest (all slices), e.g.
                // `zig build itest-parity_object_init`.
                const one = b.step(
                    b.fmt("itest-{s}", .{spec.name}),
                    b.fmt("Run the {s} integration test", .{spec.name}),
                );
                for (0..spec.shards) |slice_i| {
                const run_t = b.addRunArtifact(tbin);
                run_t.setCwd(b.path("."));
                keyOnEnv(b, run_t, &interp_env_keys);
                if (spec.fuzz_env) keyOnEnv(b, run_t, &fuzz_env_keys);
                if (spec.shards > 1) {
                    run_t.setEnvironmentVariable(
                        "KLIO_COMMONTEST_SHARD",
                        b.fmt("{d}/{d}", .{ slice_i, spec.shards }),
                    );
                }
                // Child-spawning tests run programs through the
                // harness-optimized `klio` installed alongside the suite. They
                // must never be cached: the run-step manifest keys on the test
                // binary and declared file inputs, not on the separately-built
                // `klio-harness` they spawn, so an interpreter change rebuilds
                // the harness without invalidating the test and a stale pass is
                // served. These tests also bind sockets and mutate a scratch
                // HOME — genuine side effects — so always re-run them.
                if (spec.needs_exe) {
                    if (spec.fast_exe) {
                        const finst = b.addInstallArtifact(fast_harness_exe, .{});
                        run_t.step.dependOn(&finst.step);
                        run_t.setEnvironmentVariable("KLIO_ITEST_BIN", "zig-out/bin/klio-harness-fast");
                    } else {
                        const hinst = b.addInstallArtifact(harness_exe, .{});
                        run_t.step.dependOn(&hinst.step);
                        run_t.setEnvironmentVariable("KLIO_ITEST_BIN", b.fmt("zig-out/bin/{s}", .{harness_bin_name}));
                    }
                    run_t.has_side_effects = true;
                }
                if (spec.parity_data) {
                    declareDataDirs(b, run_t, &data_memo, &stdlib_data_dirs);
                    declareDataDirs(b, run_t, &data_memo, &kotlinx_pack_dirs);
                    // The parity harness caches one base snapshot per (load-mode,
                    // pack-mask) combination and never evicts, so the ceiling
                    // rises as the in-repo pack set grows. The concurrent
                    // snapshot stress tests additionally churn arena memory in
                    // proportion to interpreter THROUGHPUT — every host-serve
                    // round that speeds the map/list write cycle raises the
                    // per-test churn inside the same runTest window — so the
                    // watchdog headroom tracks that, not a leak.
                    run_t.setEnvironmentVariable("KLIO_RSS_CAP_KB", "10485760");
                    run_t.setEnvironmentVariable("KLIO_PARITY_BASE_IMAGES", base_images_path);
                    run_t.step.dependOn(&base_images_install.step);
                    run_t.addFileInput(base_images.path(b, "embedded-gate0.klio-image"));
                    run_t.addFileInput(base_images.path(b, "embedded-gate1.klio-image"));
                }
                declareDataDirs(b, run_t, &data_memo, spec.dirs);
                const slice_name = if (spec.shards > 1)
                    b.fmt("{s}#{d}", .{ spec.name, slice_i })
                else
                    spec.name;
                if (shards.includes(slice_name)) {
                    // Serialize only under an explicit shard (CI): chaining the
                    // run steps otherwise leaks into the targeted `itest-<name>`
                    // step (which depends on the same run step) so a single named
                    // run pulls the whole suite.
                    if (shards.active()) {
                        if (prev_itest_run) |p| run_t.step.dependOn(p);
                        prev_itest_run = &run_t.step;
                    }
                    itest_step.dependOn(&run_t.step);
                }
                one.dependOn(&run_t.step);
                }
                // Also install the raw test binary so it can be looped from a
                // shell without the build graph re-running each iteration.
                const inst = b.addInstallArtifact(tbin, .{
                    .dest_sub_path = b.fmt("itest-{s}", .{spec.name}),
                });
                itest_bin_step.dependOn(&inst.step);
            }
            continue;
        }
        // e2e and bench module tests run whole programs through the
        // interpreter; they ride the harness universe. Every other module
        // test stays on the default optimize mode for leak/UAF fidelity.
        const runs_programs = std.mem.eql(u8, m.name, "e2e") or std.mem.eql(u8, m.name, "bench");
        const test_mods = if (runs_programs) &harness_mods else &mods;
        const t = b.addTest(.{ .root_module = test_mods.get(m.name).? });
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
        // e2e and bench run programs through the in-process parity pipeline:
        // point them at the baked dependency bases like the parity itests.
        if (runs_programs) {
            // The parity harness caches one base snapshot per (load-mode,
            // pack-mask) combo without eviction, so give the corpus runners
            // headroom over the 6 GB default RSS watchdog cap.
            run_t.setEnvironmentVariable("KLIO_RSS_CAP_KB", "6815744");
            run_t.setEnvironmentVariable("KLIO_PARITY_BASE_IMAGES", base_images_path);
            run_t.step.dependOn(&base_images_install.step);
            run_t.addFileInput(base_images.path(b, "embedded-gate0.klio-image"));
            run_t.addFileInput(base_images.path(b, "embedded-gate1.klio-image"));
        }
        // Module tests that interpret whole programs (e2e, bench) are as slow
        // as the integration suite; keep them off the fast `test` step. A
        // named step (`zig build itest-e2e`) supports targeted iteration.
        if (runs_programs) {
            if (shards.includes(m.name)) {
                if (shards.active()) {
                    if (prev_itest_run) |p| run_t.step.dependOn(p);
                    prev_itest_run = &run_t.step;
                }
                itest_step.dependOn(&run_t.step);
            }
            const one = b.step(
                b.fmt("itest-{s}", .{m.name}),
                b.fmt("Run the {s} module test", .{m.name}),
            );
            one.dependOn(&run_t.step);
            // Installable form for process-parallel gating: the fast gate
            // fans shards of the corpus across CPUs as plain processes
            // (KLIO_E2E_SHARD=K/N + --test-filter), which one serial
            // in-build run step cannot.
            const bin_inst = b.addInstallArtifact(t, .{ .dest_sub_path = b.fmt("itest-{s}", .{m.name}) });
            const bin_one = b.step(
                b.fmt("itest-{s}-bin", .{m.name}),
                b.fmt("Install the {s} module test binary (+ data deps)", .{m.name}),
            );
            bin_one.dependOn(&bin_inst.step);
            bin_one.dependOn(&base_images_install.step);
        } else {
            test_step.dependOn(&run_t.step);
        }
    }

    const test_all_step = b.step("test-all", "Run the unit tests and the integration suite");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(itest_step);
}

/// Weight-balanced sharding of the integration suite for `-Ditest-shard=K/N`.
/// The suite list is the itest binaries plus the e2e and bench module tests;
/// e2e is by far the heaviest module test and gets its own static weight.
const ItestShards = struct {
    /// null = no sharding (every suite included).
    selected: ?std.StringHashMap(void),

    const e2e_weight: u16 = 150;
    const bench_weight: u16 = 12;

    fn fromOption(b: *std.Build) ItestShards {
        const raw = b.option([]const u8, "itest-shard", "Run only shard K of N of the integration suite (format K/N)") orelse
            return .{ .selected = null };
        const slash = std.mem.indexOfScalar(u8, raw, '/') orelse badShardOption(raw);
        const k = std.fmt.parseInt(usize, raw[0..slash], 10) catch badShardOption(raw);
        const n = std.fmt.parseInt(usize, raw[slash + 1 ..], 10) catch badShardOption(raw);
        if (n == 0 or k >= n) badShardOption(raw);

        const Suite = struct { name: []const u8, weight: u16 };
        var suites: std.ArrayList(Suite) = .empty;
        for (itests_files) |spec| {
            if (spec.shards > 1) {
                for (0..spec.shards) |si| {
                    suites.append(b.allocator, .{
                        .name = b.fmt("{s}#{d}", .{ spec.name, si }),
                        .weight = spec.weight,
                    }) catch @panic("oom");
                }
            } else {
                suites.append(b.allocator, .{ .name = spec.name, .weight = spec.weight }) catch @panic("oom");
            }
        }
        suites.append(b.allocator, .{ .name = "e2e", .weight = e2e_weight }) catch @panic("oom");
        suites.append(b.allocator, .{ .name = "bench", .weight = bench_weight }) catch @panic("oom");
        // Descending weight, name-tiebroken: deterministic greedy packing.
        std.mem.sort(Suite, suites.items, {}, struct {
            fn lt(_: void, x: Suite, y: Suite) bool {
                if (x.weight != y.weight) return x.weight > y.weight;
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);

        const bin_totals = b.allocator.alloc(u64, n) catch @panic("oom");
        @memset(bin_totals, 0);
        var selected = std.StringHashMap(void).init(b.allocator);
        for (suites.items) |s| {
            var lightest: usize = 0;
            for (bin_totals, 0..) |w, i| {
                if (w < bin_totals[lightest]) lightest = i;
            }
            bin_totals[lightest] += s.weight;
            if (lightest == k) selected.put(s.name, {}) catch @panic("oom");
        }
        return .{ .selected = selected };
    }

    fn includes(self: *const ItestShards, name: []const u8) bool {
        const sel = self.selected orelse return true;
        return sel.contains(name);
    }

    /// True when an explicit `-Ditest-shard=K/N` was given (the CI path). Only
    /// then do the shard's run steps serialize into a chain; the default `itest`
    /// and targeted `itest-<name>` steps must not inherit that chain.
    fn active(self: *const ItestShards) bool {
        return self.selected != null;
    }

    fn badShardOption(raw: []const u8) noreturn {
        std.debug.panic("-Ditest-shard expects K/N with K < N, got `{s}`", .{raw});
    }
};

/// Attach the build-time-generated stdlib pack to one module universe:
/// `stdlib_pack` imports `stdlib_embedded`, whose root embeds the generated
/// pack bytes via the `stdlib_pack_bytes` anonymous import. zigcheck.py
/// builds substitute `embedded_stub.zig` (no bytes) for the same module.
fn wireEmbeddedPack(
    b: *std.Build,
    mods: *std.StringHashMap(*std.Build.Module),
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    embedded_pack: std.Build.LazyPath,
) void {
    const embedded_mod = b.createModule(.{
        .root_source_file = b.path("src/stdlib_pack/embedded.zig"),
        .target = target,
        .optimize = optimize,
    });
    embedded_mod.addAnonymousImport("stdlib_pack_bytes", .{ .root_source_file = embedded_pack });
    mods.get("stdlib_pack").?.addImport("stdlib_embedded", embedded_mod);
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

/// Resolve the Apple SDK for an iOS target. Zig cannot auto-detect the iOS SDK
/// the way it does the native macOS one, so it must be supplied. A global
/// `--sysroot` is the wrong tool: it would also apply to the native host tools
/// (`stdlib-embed-gen` runs on the build host), linking them against the iOS
/// libc. Instead we resolve the SDK path here (xcrun, or `-Dapple-sdk`) and
/// attach its include/lib/framework paths onto the target artifacts only. Null
/// for non-iOS targets (native macOS auto-detects; other targets use zig's libc).
fn resolveAppleSdk(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    const override = b.option([]const u8, "apple-sdk", "Apple SDK path for iOS targets (default: xcrun lookup)");
    if (target.result.os.tag != .ios) return null;
    if (override) |p| return p;
    const sdk_name = if (target.result.abi == .simulator) "iphonesimulator" else "iphoneos";
    const out = b.run(&.{ "xcrun", "--sdk", sdk_name, "--show-sdk-path" });
    return b.dupe(std.mem.trim(u8, out, " \n\r\t"));
}

/// Per-target suffix for the installed `klio` binary, so a mobile cross build
/// installs as a distinct file (`klio-ios`, `klio-ios-sim`, `klio-android`) and
/// never overwrites the desktop `zig-out/bin/klio`. Desktop targets keep the
/// bare `klio` name.
fn targetBinSuffix(target: std.Build.ResolvedTarget) []const u8 {
    return switch (target.result.os.tag) {
        .ios => if (target.result.abi == .simulator) "-ios-sim" else "-ios",
        .linux => if (target.result.abi == .android or target.result.abi == .androideabi) "-android" else "",
        else => "",
    };
}

/// Attach an Apple SDK's header/library/framework search paths to a module, so a
/// libc-linking (and C-compiling) target artifact resolves `<string.h>` and
/// `libSystem` without a global `--sysroot`.
fn wireAppleSdk(b: *std.Build, mod: *std.Build.Module, sdk: []const u8) void {
    mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) });
    mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
    mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
}

/// The resolved Android NDK bits an artifact needs to compile C (bionic libc
/// headers) and link (the per-API libc/crt objects) for an android target.
const AndroidNdk = struct { sysroot: []const u8, triple: []const u8, api: u32 };

/// Resolve the Android NDK for an android target (null for every other target,
/// so it is only ever wired onto the target artifacts, never the host tools).
/// The NDK path comes from `-Dandroid-ndk`, then `$ANDROID_NDK_HOME`, then the
/// newest `~/Library/Android/sdk/ndk/<version>`. `-Dandroid-api` sets the
/// platform level (default 24).
fn resolveAndroidNdk(b: *std.Build, target: std.Build.ResolvedTarget) ?AndroidNdk {
    const t = target.result;
    const is_android = t.os.tag == .linux and (t.abi == .android or t.abi == .androideabi);
    if (!is_android) return null;
    const ndk = b.option([]const u8, "android-ndk", "Android NDK path (default: $ANDROID_NDK_HOME or the newest ~/Library/Android/sdk/ndk)") orelse
        defaultAndroidNdk(b) orelse @panic("android target needs -Dandroid-ndk=<path> or ANDROID_NDK_HOME");
    const api = b.option(u32, "android-api", "Android platform API level (default 24)") orelse 24;
    // The NDK toolchain prebuilt is a darwin-x86_64 host dir even on Apple silicon.
    const sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/darwin-x86_64/sysroot", .{ndk});
    const triple = switch (t.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        else => "aarch64-linux-android",
    };
    return .{ .sysroot = sysroot, .triple = triple, .api = api };
}

/// `$ANDROID_NDK_HOME`, else the newest `~/Library/Android/sdk/ndk/*` (found via a
/// configure-time shell glob, like `resolveAppleSdk` uses `xcrun`).
fn defaultAndroidNdk(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |v| return b.dupe(v);
    const home = b.graph.environ_map.get("HOME") orelse return null;
    const ndk_root = b.fmt("{s}/Library/Android/sdk/ndk", .{home});
    // Pipeline exit is `tail`'s (0) even when the glob matches nothing.
    const out = b.run(&.{ "sh", "-c", b.fmt("ls -d {s}/*/ 2>/dev/null | sort | tail -1", .{ndk_root}) });
    var trimmed = std.mem.trim(u8, out, " \n\r\t");
    if (std.mem.endsWith(u8, trimmed, "/")) trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len == 0) return null;
    return b.dupe(trimmed);
}

/// Attach the NDK sysroot's header + library search paths to a module so a
/// C-compiling / libc-linking android artifact resolves `<stdio.h>` and the
/// bionic libc without a global `--sysroot` (which would poison host tools).
fn wireAndroidNdk(b: *std.Build, mod: *std.Build.Module, ndk: AndroidNdk) void {
    mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{ndk.sysroot}) });
    mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ ndk.sysroot, ndk.triple }) });
    mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}/{d}", .{ ndk.sysroot, ndk.triple, ndk.api }) });
    // Android is PIC/PIE throughout; the static archive links into a PIE host, so
    // every object (including the vendored zstd C) must be position-independent.
    mod.pic = true;
}

/// Build the vendored zstd C library as a static library statically linked
/// into the binary and test artifacts. No system zstd is referenced.
fn buildZstd(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const dep = b.dependency("zstd", .{});

    // Suffix the installed archive by target (libzstd-android.a, libzstd-ios-sim.a,
    // libzstd.a for the host) so a cross build's archive never clobbers the host's
    // at zig-out/lib — an app host links the target archive with its own toolchain,
    // and a wrong-arch libzstd.a fails cryptically at link time.
    const lib = b.addLibrary(.{
        .name = b.fmt("zstd{s}", .{targetBinSuffix(target)}),
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

/// Skia prebuilt-lib layout for a target: the vendored base dir, the archive dir,
/// and the archive extension (`.a` on linux/macOS, `.lib` on windows). Null when
/// the OS/arch is not one of the six supported desktop targets.
fn skiaLibInfo(b: *std.Build, target: std.Build.ResolvedTarget) ?struct {
    base: []const u8,
    lib_dir: []const u8,
    ext: []const u8,
} {
    const os = target.result.os.tag;
    // iOS (arm64 only): skia-pack uses the camelCase `iosSim`/`ios` build token
    // in the out/ dir name, but a lowercase directory name locally. Simulator vs
    // device splits on the target abi (fetch-skia.sh iossim|ios).
    if (os == .ios) {
        if (target.result.cpu.arch != .aarch64) return null;
        const sim = target.result.abi == .simulator;
        const dir: []const u8 = if (sim) "iossim-arm64" else "ios-arm64";
        const tok: []const u8 = if (sim) "iosSim" else "ios";
        const base = b.fmt("third_party/skia/{s}", .{dir});
        return .{
            .base = base,
            .lib_dir = b.fmt("{s}/out/Release-{s}-arm64", .{ base, tok }),
            .ext = "a",
        };
    }
    const os_name: []const u8 = switch (os) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => return null,
    };
    const arch_name: []const u8 = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return null,
    };
    const base = b.fmt("third_party/skia/{s}-{s}", .{ os_name, arch_name });
    return .{
        .base = base,
        .lib_dir = b.fmt("{s}/out/Release-{s}-{s}", .{ base, os_name, arch_name }),
        .ext = if (os == .windows) "lib" else "a",
    };
}

/// Whether the target's prebuilt Skia libs are vendored (fetch-skia.sh).
fn skiaLibsPresent(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const info = skiaLibInfo(b, target) orelse return false;
    b.build_root.handle.access(b.graph.io, b.fmt("{s}/libskia.{s}", .{ info.lib_dir, info.ext }), .{}) catch return false;
    return true;
}

/// Locate the SDL2 headers + shared library for the Skia shim's windowing backend.
/// Checks the standard system locations, then a linuxbrew prefix. Returns the SDL2
/// include dir (so the shim's `#include <SDL.h>` resolves) + a full path to libSDL2
/// (linked directly, so no dev `.so` symlink is required), or null when SDL2 is
/// unavailable (then windowing is disabled and the pack renders headless). SDL2
/// picks X11 or Wayland at runtime, so this one backend covers the Linux matrix.
fn detectSdl(b: *std.Build) ?struct { inc: []const u8, lib: []const u8 } {
    const io = b.graph.io;
    const inc_candidates = [_][]const u8{
        "/usr/include/SDL2",
        "/usr/local/include/SDL2",
        "/home/linuxbrew/.linuxbrew/include/SDL2",
    };
    const lib_candidates = [_][]const u8{
        "/usr/lib/x86_64-linux-gnu/libSDL2-2.0.so.0",
        "/usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0",
        "/usr/local/lib/libSDL2-2.0.so.0",
        "/home/linuxbrew/.linuxbrew/lib/libSDL2-2.0.so.0",
        "/usr/lib/libSDL2-2.0.so.0",
    };
    var inc: ?[]const u8 = null;
    for (inc_candidates) |c| {
        if (b.build_root.handle.access(io, b.fmt("{s}/SDL.h", .{c}), .{})) |_| {
            inc = c;
            break;
        } else |_| {}
    }
    var lib: ?[]const u8 = null;
    for (lib_candidates) |c| {
        if (b.build_root.handle.access(io, c, .{})) |_| {
            lib = c;
            break;
        } else |_| {}
    }
    if (inc != null and lib != null) return .{ .inc = inc.?, .lib = lib.? };
    return null;
}

/// A versioned system shared object (e.g. `libEGL.so.1`) for the optional GPU
/// backend, by base name. No dev symlink (`libEGL.so`) is required — the `.so.1`
/// is enough to link against directly by path.
fn findVersionedLib(b: *std.Build, name: []const u8) ?[]const u8 {
    const io = b.graph.io;
    const dirs = [_][]const u8{
        "/usr/lib/x86_64-linux-gnu",
        "/lib/x86_64-linux-gnu",
        "/usr/lib/aarch64-linux-gnu",
        "/usr/lib",
    };
    const sonames = [_][]const u8{ "so.1", "so" };
    for (dirs) |d| {
        for (sonames) |sfx| {
            const p = b.fmt("{s}/{s}.{s}", .{ d, name, sfx });
            if (b.build_root.handle.access(io, p, .{})) |_| return p else |_| {}
        }
    }
    return null;
}

/// The dynamic-library file name of the Skia backend for a target OS (the name
/// the compose_ui module dlopens).
fn skiaLibName(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .macos => "libklio_skia.dylib",
        .windows => "klio_skia.dll",
        // iOS links the shim statically into the app (no dlopen), so it is a
        // static archive rather than a shared library.
        .ios => "libklio_skia.a",
        else => "libklio_skia.so",
    };
}

/// Build the iOS Compose-UI Skia shim as a STATIC archive (libklio_skia.a) of the
/// shim's own objects, compiled with the platform clang++ against the iOS SDK.
/// iOS bans dlopen of a runtime-written dylib, so the shim links into the app
/// statically; libskia + its sibling dep archives + the Apple frameworks are
/// added at the app link, not here. Offscreen/raster only for now (no window
/// backend) — the on-screen UIView + Metal surface comes later.
fn buildSkiaShimIos(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    sdk: []const u8,
    base: []const u8,
) ?std.Build.LazyPath {
    const sim = target.result.abi == .simulator;
    const min_flag: []const u8 = if (sim)
        "-mios-simulator-version-min=15.0"
    else
        "-miphoneos-version-min=15.0";
    const inc = b.fmt("-I{s}", .{base});

    // KLIO_UIKIT enables the iOS on-screen backend (attach to an app CAMetalLayer,
    // Ganesh-Metal). Offscreen raster + PNG still work alongside it; the app links
    // Metal/QuartzCore/UIKit. The shim is still compiled Objective-C++ for the
    // Metal/UIKit glue.
    const c1 = b.addSystemCommand(&.{ "clang++", "-std=c++17", "-O2", "-DNDEBUG", "-fPIC", "-arch", "arm64", "-DKLIO_UIKIT", "-DKLIO_METAL" });
    c1.addArgs(&.{ min_flag, "-isysroot", sdk, "-x", "objective-c++", inc, "-c" });
    c1.addFileArg(b.path("src/compose_ui/skia_shim.cpp"));
    c1.addArg("-o");
    const shim_o = c1.addOutputFileArg("skia_shim.o");

    const c2 = b.addSystemCommand(&.{ "clang++", "-std=c++17", "-O2", "-DNDEBUG", "-fPIC", "-arch", "arm64" });
    c2.addArgs(&.{ min_flag, "-isysroot", sdk, "-x", "objective-c++", inc, "-c" });
    c2.addFileArg(b.path("src/compose_ui/font_data.cpp"));
    c2.addArg("-o");
    const font_o = c2.addOutputFileArg("font_data.o");

    const ar = b.addSystemCommand(&.{ "libtool", "-static", "-o" });
    const out = ar.addOutputFileArg("libklio_skia.a");
    ar.addFileArg(shim_o);
    ar.addFileArg(font_o);
    return out;
}

/// Build the Compose-UI Skia backend shared library for `target` with the system
/// C++ toolchain, from `src/compose_ui/skia_shim.cpp` + the prebuilt Skia libs in
/// `third_party/skia/<os>-<arch>/` (fetch-skia.sh). The compiler and C++ runtime
/// must match the prebuilt libs' ABI, which differs per OS — linux GNU libstdc++,
/// macOS LLVM libc++, windows MSVC — so this is NOT `zig cc` (libc++ everywhere)
/// but the platform C++ driver. `-Dskia-cxx` (or `$CXX`) overrides the compiler,
/// which is how a cross toolchain (osxcross clang++, etc.) is supplied for a cross
/// build. The libs are -fPIC, so each links into a self-contained dynamic library
/// the module dlopens at runtime. Returns null when the target's libs are absent
/// or the OS/arch is unsupported.
///
/// Verified on linux-x64. macOS/windows use the standard per-platform link recipe
/// (clang++ + frameworks / clang-cl + system libs) but are unverified here.
fn buildSkiaShim(b: *std.Build, target: std.Build.ResolvedTarget, apple_sdk: ?[]const u8) ?std.Build.LazyPath {
    const io = b.graph.io;
    const os = target.result.os.tag;
    const info = skiaLibInfo(b, target) orelse return null;
    const base = info.base;
    const lib_dir = info.lib_dir;
    const ext = info.ext;
    b.build_root.handle.access(io, b.fmt("{s}/libskia.{s}", .{ lib_dir, ext }), .{}) catch return null;

    // iOS: the shim is a static archive of just its own objects (offscreen /
    // raster; no window backend yet). libskia + its sibling dep archives + the
    // Apple frameworks are linked into the app alongside it, not into the shim.
    if (os == .ios) return buildSkiaShimIos(b, target, apple_sdk orelse return null, base);

    // Compiler: -Dskia-cxx → per-OS default. The override lets a cross toolchain
    // (osxcross clang++, a mingw/clang-cl wrapper, …) build for a non-host target.
    const default_cxx: []const u8 = if (os == .linux) "g++" else "clang++";
    const cxx = b.option([]const u8, "skia-cxx", "C++ compiler for the Skia shim (default: g++ on linux, clang++ elsewhere)") orelse default_cxx;
    // macOS builds the Cocoa window + Metal surface by default, so a plain
    // `zig build` yields a UI-capable shim (no window backend => runApp opens
    // nothing). Pass -Dcocoa=false / -Dgpu=false for a headless offscreen-only
    // shim. Linux windowing is SDL (auto-linked when present); its GL surface
    // stays opt-in via -Dgpu. Metal falls back to raster at runtime if bring-up
    // fails, so defaulting it on is safe.
    const macos_backend_default = os == .macos;
    const want_gpu = b.option(bool, "gpu", "Build the GPU surface for the Skia shim (macOS Metal with -Dcocoa, or linux Ganesh+EGL; default: on for macOS, opt-in elsewhere; falls back to raster)") orelse macos_backend_default;
    const want_cocoa = b.option(bool, "cocoa", "Build the macOS Cocoa window backend (compiles the shim as Objective-C++; default: on for macOS)") orelse macos_backend_default;

    const run = b.addSystemCommand(&.{cxx});
    // -DNDEBUG matches the Release prebuilt: Skia headers define SK_DEBUG when
    // NDEBUG is absent, and debug-only fields (SkDEBUGCODE members in types the
    // skparagraph styles embed) change struct layouts across the ABI.
    // _GLIBCXX_USE_CXX11_ABI=0 matches how the JetBrains linux skia-pack is
    // compiled (its u16string symbols mangle pre-cxx11): std::basic_string
    // values cross the skparagraph API by reference, so the layouts must agree.
    run.addArgs(&.{ "-std=c++17", "-O2", "-DNDEBUG", "-fPIC", "-shared", b.fmt("-I{s}", .{base}) });
    if (os == .linux) run.addArg("-D_GLIBCXX_USE_CXX11_ABI=0");
    // The Cocoa backend needs the shim compiled as Objective-C++; -x applies to the
    // source that follows, so it must precede the source file.
    if (os == .macos and want_cocoa) {
        run.addArgs(&.{ "-DKLIO_COCOA", "-x", "objective-c++" });
        // Metal GPU surface for the Cocoa window (opt-in via -Dgpu). The ganesh
        // Metal backend is already in the linked archives; this enables the code
        // path. Falls back to raster if Metal bring-up fails at runtime.
        if (want_gpu) run.addArg("-DKLIO_METAL");
    }
    run.addFileArg(b.path("src/compose_ui/skia_shim.cpp"));
    // The bundled fallback font, baked into a byte array (scripts/gen-font-data.py).
    run.addFileArg(b.path("src/compose_ui/font_data.cpp"));
    // Reset the input language so the .a archives that follow are linked, not
    // compiled as Objective-C++ source (the -x above applies to everything after).
    if (os == .macos and want_cocoa) run.addArgs(&.{ "-x", "none" });
    run.addArg("-o");
    const so = run.addOutputFileArg(skiaLibName(os));

    // The prebuilt Skia archives have circular inter-archive references; on GNU
    // ld that needs a link group. ld64 (macOS) and lld resolve archives without.
    const group = os == .linux;
    if (group) run.addArg("-Wl,--start-group");
    var dir = b.build_root.handle.openDir(io, lib_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch return null;
    defer walker.deinit();
    const dot_ext = b.fmt(".{s}", .{ext});
    while (walker.next(io) catch return null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, dot_ext)) {
            run.addArg(b.fmt("{s}/{s}", .{ lib_dir, entry.path }));
        }
    }
    if (group) run.addArg("-Wl,--end-group");

    // SDL2 windowing backend (the shim's on-screen surface). Dev builds link
    // the system's dynamic SDL2 (detectSdl); release CI passes -Dsdl-static
    // to link the -fPIC static archive from scripts/fetch-sdl.sh so the
    // shipped shim carries no libSDL2 install dependency (SDL still dlopens
    // the host's X11/Wayland client libs at runtime). Without either, the
    // window functions are stubs and the pack falls back to headless
    // rendering.
    if (os == .linux) {
        const want_sdl_static = b.option(bool, "sdl-static", "Link SDL2 statically into the Skia shim from third_party/sdl (release artifacts; run scripts/fetch-sdl.sh first)") orelse false;
        const static_sdl: ?struct { inc: []const u8, lib: []const u8 } = blk: {
            if (!want_sdl_static) break :blk null;
            const arch_name: []const u8 = if (target.result.cpu.arch == .x86_64) "x64" else "arm64";
            const sdl_base = b.fmt("third_party/sdl/linux-{s}", .{arch_name});
            const lib = b.fmt("{s}/lib/libSDL2.a", .{sdl_base});
            b.build_root.handle.access(io, lib, .{}) catch {
                std.log.warn("-Dsdl-static set but {s} is missing; run scripts/fetch-sdl.sh", .{lib});
                break :blk null;
            };
            break :blk .{ .inc = b.fmt("{s}/include/SDL2", .{sdl_base}), .lib = lib };
        };
        if (static_sdl) |sdl| {
            run.addArgs(&.{ "-DKLIO_SDL", b.fmt("-I{s}", .{sdl.inc}), sdl.lib });
        } else if (detectSdl(b)) |sdl| {
            run.addArgs(&.{ "-DKLIO_SDL", b.fmt("-I{s}", .{sdl.inc}), sdl.lib });
        } else {
            std.log.warn("SDL2 not found; the Compose-UI window backend is disabled (headless render only). Install libsdl2-dev.", .{});
        }
        // Optional Ganesh+GL GPU surface. The ganesh archive is already in the link
        // group above; this enables the code path + links the GL/EGL runtime (the
        // ganesh objects also reference glX, so libGL is needed too). The on-screen
        // GPU window renders through SDL's GL context; the offscreen path uses EGL.
        // Skipped (raster fallback) if the GL/EGL libs are not found.
        if (want_gpu) {
            if (findVersionedLib(b, "libEGL")) |egl| {
                if (findVersionedLib(b, "libGL")) |gl| {
                    run.addArgs(&.{ "-DKLIO_GPU", egl, gl });
                }
            }
        }
    }

    // Per-OS C++ runtime + system frameworks/libs Skia needs.
    switch (os) {
        .linux => run.addArgs(&.{ "-lstdc++", "-lpthread", "-ldl", "-lm" }),
        .macos => run.addArgs(&.{
            "-lc++",
            "-framework", "AppKit",         "-framework", "CoreFoundation",
            "-framework", "CoreGraphics",   "-framework", "CoreText",
            "-framework", "CoreServices",   "-framework", "Foundation",
            "-framework", "Metal",          "-framework", "QuartzCore",
            "-framework", "IOKit",
        }),
        .windows => run.addArgs(&.{
            "-luser32", "-lgdi32", "-lopengl32", "-lole32", "-loleaut32",
        }),
        else => return null,
    }
    return so;
}
