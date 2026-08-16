//! End-to-end gate for the baked stdlib image: the `klio run` fast path
//! (bake on miss, hit on rerun) must be byte-identical to the legacy
//! whole-program build — stdout, stderr, and exit code — including the
//! base-name-collision fallback, the no-main error path, a pack-using
//! program, a corrupted image, and a stale stdlib source.
//!
//! Each scenario runs the real `klio` binary (KLIO_ITEST_BIN) against a
//! scratch HOME so the image cache under test never touches the real
//! `~/.klio`. The in-process test bakes + reloads a lowered base directly
//! and deep-compares the tables that drive dispatch.

const std = @import("std");
const interp_ir = @import("interp_ir");
const stdlib = @import("stdlib");
const span = @import("span");
const lexer = @import("lexer");
const parser = @import("parser");
const ast = @import("ast");
const runtime = @import("runtime");

const SourceMap = span.SourceMap;

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const TMP_ROOT = "/tmp/klio_itest_stdlib_image";

// -------------------------------------------------------------------------
// Child-process plumbing.
// -------------------------------------------------------------------------

fn klioBin(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    const rel = env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
    // Scenarios spawn with a non-repo cwd, so the binary path must be
    // absolute.
    return std.Io.Dir.cwd().realPathFileAlloc(io, rel, a) catch rel;
}

fn baseEnv(a: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(a);
    errdefer map.deinit();
    runtime.procEnvPutAllInto(a, &map);
    try map.put("HOME", home);
    // The comparisons assert byte-identical stderr; keep tracing off.
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_TRACE_STDLIB_IMAGE"));
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_STDLIB_IMAGE"));
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_PACK_DIAG"));
    return map;
}

const RunResult = struct { code: u32, stdout: []u8, stderr: []u8 };

fn runKlio(
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    cwd: ?[]const u8,
    argv: []const []const u8,
) !RunResult {
    const r = std.process.run(a, io, .{
        .argv = argv,
        .environ_map = env,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
    }) catch |e| {
        std.debug.print("stdlib_image: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    const code: u32 = switch (r.term) {
        .exited => |c| c,
        else => 0xffff,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

fn writeProgram(a: std.mem.Allocator, io: std.Io, name: []const u8, src: []const u8) ![]const u8 {
    std.Io.Dir.cwd().createDirPath(io, TMP_ROOT) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ TMP_ROOT, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
    return path;
}

/// Run `argv` twice against a fresh image cache (cold bake, then hit) and
/// once with the cache disabled; assert all three runs are byte-identical
/// on stdout + stderr + exit code.
fn assertImageMatchesLegacy(
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    cwd: ?[]const u8,
    argv: []const []const u8,
) !void {
    try env.put("KLIO_STDLIB_IMAGE", "0");
    const legacy = try runKlio(a, io, env, cwd, argv);
    _ = env.array_hash_map.swapRemove(@as([]const u8, "KLIO_STDLIB_IMAGE"));
    const cold = try runKlio(a, io, env, cwd, argv);
    const warm = try runKlio(a, io, env, cwd, argv);

    for ([_]RunResult{ cold, warm }) |got| {
        if (got.code != legacy.code or
            !std.mem.eql(u8, got.stdout, legacy.stdout) or
            !std.mem.eql(u8, got.stderr, legacy.stderr))
        {
            std.debug.print(
                "stdlib_image mismatch for {s}\nlegacy code={d} stdout:\n{s}\nstderr:\n{s}\nimage code={d} stdout:\n{s}\nstderr:\n{s}\n",
                .{ argv[argv.len - 1], legacy.code, legacy.stdout, legacy.stderr, got.code, got.stdout, got.stderr },
            );
            return error.TestUnexpectedResult;
        }
    }
}

fn freshHome(a: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const home = try std.fmt.allocPrint(a, "{s}/home_{s}", .{ TMP_ROOT, name });
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    return home;
}

fn countImages(a: std.mem.Allocator, io: std.Io, home: []const u8) usize {
    const cache = std.fmt.allocPrint(a, "{s}/.klio/cache", .{home}) catch return 0;
    var dir = std.Io.Dir.cwd().openDir(io, cache, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".klio-image")) n += 1;
    }
    return n;
}

fn firstImagePath(a: std.mem.Allocator, io: std.Io, home: []const u8) ?[]const u8 {
    const cache = std.fmt.allocPrint(a, "{s}/.klio/cache", .{home}) catch return null;
    var dir = std.Io.Dir.cwd().openDir(io, cache, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".klio-image")) {
            return std.fmt.allocPrint(a, "{s}/{s}", .{ cache, entry.name }) catch null;
        }
    }
    return null;
}

// -------------------------------------------------------------------------
// Programs.
// -------------------------------------------------------------------------

const P_BASIC =
    \\enum class Paint(val code: Int) {
    \\    RED(10),
    \\    GREEN(20) { override fun label(): String = "green!" };
    \\    open fun label(): String = "plain " + code
    \\}
    \\object Registry { var total = 0 }
    \\fun main() {
    \\    val items = listOf(3, 1, 2).sorted().map { it * 10 }
    \\    println(items.joinToString("|"))
    \\    println(Paint.RED.label() + " " + Paint.GREEN.label() + " " + Paint.GREEN.ordinal)
    \\    Registry.total += 41
    \\    println("total=${Registry.total + 1}")
    \\    println(buildString { append("a"); append(1..3) })
    \\}
    \\
;

/// Redeclares a stdlib top-level name: must take the whole-program
/// fallback and still behave exactly like the legacy path.
const P_FALLBACK =
    \\fun listOf(x: Int): Int = x + 1
    \\fun main() {
    \\    println(listOf(41))
    \\    println(kotlin.collections.listOf(1, 2).size)
    \\}
    \\
;

const P_NO_MAIN =
    \\fun helper(): Int = 7
    \\
;

const P_KX =
    \\import kotlinx.coroutines.*
    \\fun main() = runBlocking {
    \\    val jobs = (1..3).map { n -> async { n * n } }
    \\    println(jobs.map { it.await() }.joinToString(","))
    \\}
    \\
;

/// A package member used by fully-qualified name with no `import`. The load
/// gate must harvest the qualified prefix identically on the image and
/// legacy paths so the gated sources load (and fold into the same image key)
/// regardless of cache state.
const P_QUALIFIED_IMPLICIT =
    \\fun main() {
    \\    println(kotlin.math.max(3, 7))
    \\    println(kotlin.math.sqrt(16.0))
    \\}
    \\
;

/// The same shape against a non-implicit gated package (`kotlin.coroutines`):
/// the qualified reference alone must open the curated sources, byte-identical
/// across cache modes.
const P_QUALIFIED_GATED =
    \\fun main() {
    \\    val ctx = kotlin.coroutines.EmptyCoroutineContext
    \\    println(ctx != null)
    \\}
    \\
;

// -------------------------------------------------------------------------
// CLI scenarios.
// -------------------------------------------------------------------------

test "image path is byte-identical to legacy: basic, fallback, no-main" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = try freshHome(a, io, "basic");
    var env = try baseEnv(a, home);
    defer env.deinit();
    const bin = try klioBin(a, io, &env);

    const basic = try writeProgram(a, io, "basic.kt", P_BASIC);
    try assertImageMatchesLegacy(a, io, &env, null, &.{ bin, "run", basic });
    try std.testing.expect(countImages(a, io, home) >= 1);

    const fallback = try writeProgram(a, io, "fallback.kt", P_FALLBACK);
    try assertImageMatchesLegacy(a, io, &env, null, &.{ bin, "run", fallback });

    const no_main = try writeProgram(a, io, "no_main.kt", P_NO_MAIN);
    try assertImageMatchesLegacy(a, io, &env, null, &.{ bin, "run", no_main });
}

test "fully-qualified unimported reference: image path matches legacy" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = try freshHome(a, io, "qualified");
    var env = try baseEnv(a, home);
    defer env.deinit();
    const bin = try klioBin(a, io, &env);

    const implicit = try writeProgram(a, io, "qualified_implicit.kt", P_QUALIFIED_IMPLICIT);
    try assertImageMatchesLegacy(a, io, &env, null, &.{ bin, "run", implicit });

    const gated = try writeProgram(a, io, "qualified_gated.kt", P_QUALIFIED_GATED);
    try assertImageMatchesLegacy(a, io, &env, null, &.{ bin, "run", gated });
}

test "corrupted image is rejected and rebaked transparently" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = try freshHome(a, io, "corrupt");
    var env = try baseEnv(a, home);
    defer env.deinit();
    const bin = try klioBin(a, io, &env);

    const basic = try writeProgram(a, io, "corrupt_probe.kt", P_BASIC);
    const first = try runKlio(a, io, &env, null, &.{ bin, "run", basic });
    try std.testing.expectEqual(@as(u32, 0), first.code);

    const img = firstImagePath(a, io, home) orelse return error.TestUnexpectedResult;
    // Truncate the image; the next run must reject it and rebake.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, img, a, .unlimited);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = img, .data = bytes[0 .. bytes.len / 2] });

    const again = try runKlio(a, io, &env, null, &.{ bin, "run", basic });
    try std.testing.expectEqual(@as(u32, 0), again.code);
    try std.testing.expectEqualStrings(first.stdout, again.stdout);
    // Rebaked: the file is whole again.
    const rebaked = try std.Io.Dir.cwd().readFileAlloc(io, img, a, .unlimited);
    try std.testing.expectEqual(bytes.len, rebaked.len);
}

test "editing a stdlib source rebakes under a new key" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    // Sandbox with a private copy of every stdlib source the bake reads,
    // so editing one never touches the repo.
    const sandbox = try std.fmt.allocPrint(a, "{s}/stale_sandbox", .{TMP_ROOT});
    cwd.deleteTree(io, sandbox) catch {};
    const pb = stdlib.pack_builder;
    for (pb.CURATED_UPSTREAM_SOURCES) |rel| {
        const src_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ pb.UPSTREAM_STDLIB_ROOT, rel });
        const dst_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ sandbox, pb.UPSTREAM_STDLIB_ROOT, rel });
        try cwd.createDirPath(io, std.fs.path.dirname(dst_path).?);
        const data = try cwd.readFileAlloc(io, src_path, a, .unlimited);
        try cwd.writeFile(io, .{ .sub_path = dst_path, .data = data });
    }
    for (pb.KLIO_STDLIB_ACTUAL_FILES) |rel| {
        const src_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ pb.KLIO_STDLIB_DIR, rel });
        const dst_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ sandbox, pb.KLIO_STDLIB_DIR, rel });
        try cwd.createDirPath(io, std.fs.path.dirname(dst_path).?);
        const data = try cwd.readFileAlloc(io, src_path, a, .unlimited);
        try cwd.writeFile(io, .{ .sub_path = dst_path, .data = data });
    }

    const home = try freshHome(a, io, "stale");
    var env = try baseEnv(a, home);
    defer env.deinit();
    const bin = try klioBin(a, io, &env);
    const prog = try writeProgram(a, io, "stale_probe.kt", P_BASIC);

    const first = try runKlio(a, io, &env, sandbox, &.{ bin, "run", prog });
    try std.testing.expectEqual(@as(u32, 0), first.code);
    try std.testing.expectEqual(@as(usize, 1), countImages(a, io, home));

    // Edit one stdlib source (content change, semantics preserved).
    const edited = try std.fmt.allocPrint(a, "{s}/{s}/src/kotlin/util/Standard.kt", .{ sandbox, pb.UPSTREAM_STDLIB_ROOT });
    const old = try cwd.readFileAlloc(io, edited, a, .unlimited);
    const patched = try std.fmt.allocPrint(a, "{s}\n// stale-test edit\n", .{old});
    try cwd.writeFile(io, .{ .sub_path = edited, .data = patched });

    const second = try runKlio(a, io, &env, sandbox, &.{ bin, "run", prog });
    try std.testing.expectEqual(@as(u32, 0), second.code);
    try std.testing.expectEqualStrings(first.stdout, second.stdout);
    // A second image under the new content key.
    try std.testing.expectEqual(@as(usize, 2), countImages(a, io, home));

    const third = try runKlio(a, io, &env, sandbox, &.{ bin, "run", prog });
    try std.testing.expectEqual(@as(u32, 0), third.code);
    try std.testing.expectEqualStrings(first.stdout, third.stdout);
    try std.testing.expectEqual(@as(usize, 2), countImages(a, io, home));
}

test "outside a checkout the embedded pack serves the stdlib" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    // Empty cwd: no kotlin/ checkout, no kotlin-klio/. The binary's
    // embedded pack must serve the curated sources (inline `run`/`let`
    // come from them), and the image cache must key off the embedded
    // bytes (bake once, hit on rerun).
    const sandbox = try std.fmt.allocPrint(a, "{s}/outside_sandbox", .{TMP_ROOT});
    cwd.deleteTree(io, sandbox) catch {};
    try cwd.createDirPath(io, sandbox);

    const home = try freshHome(a, io, "outside");
    var env = try baseEnv(a, home);
    defer env.deinit();
    _ = env.array_hash_map.swapRemove(@as([]const u8, "KLIO_STDLIB_PACK"));
    const bin = try klioBin(a, io, &env);
    const prog = try writeProgram(a, io, "outside_probe.kt",
        \\fun main() {
        \\    val doubled = listOf(1, 2, 3).map { it * 2 }
        \\    val msg = doubled.joinToString(",").let { "doubled: $it" }
        \\    run { println(msg) }
        \\}
        \\
    );

    const first = try runKlio(a, io, &env, sandbox, &.{ bin, "run", prog });
    try std.testing.expectEqualStrings("", first.stderr);
    try std.testing.expectEqual(@as(u32, 0), first.code);
    try std.testing.expectEqualStrings("doubled: 2,4,6\n", first.stdout);
    try std.testing.expectEqual(@as(usize, 1), countImages(a, io, home));

    const second = try runKlio(a, io, &env, sandbox, &.{ bin, "run", prog });
    try std.testing.expectEqual(@as(u32, 0), second.code);
    try std.testing.expectEqualStrings(first.stdout, second.stdout);
    try std.testing.expectEqual(@as(usize, 1), countImages(a, io, home));
}

test "pack-using program: image path matches legacy with installed packs" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = try freshHome(a, io, "packs");
    var env = try baseEnv(a, home);
    defer env.deinit();
    const bin = try klioBin(a, io, &env);

    // Build + install the kotlinx packs into the scratch HOME.
    const pack_dirs = [_][]const u8{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-io",
    };
    const pack_files = [_][]const u8{
        "target/packs/kotlinx.atomicfu.klio-pack",
        "target/packs/kotlinx.coroutines.klio-pack",
        "target/packs/kotlinx.io.klio-pack",
    };
    for (pack_dirs) |d| {
        const r = try runKlio(a, io, &env, null, &.{ bin, "pack", "build", d });
        if (r.code != 0) {
            std.debug.print("stdlib_image: pack build {s} failed:\n{s}\n", .{ d, r.stderr });
            return error.TestUnexpectedResult;
        }
    }
    for (pack_files) |f| {
        const r = try runKlio(a, io, &env, null, &.{ bin, "pack", "install", f });
        if (r.code != 0) {
            std.debug.print("stdlib_image: pack install {s} failed:\n{s}\n", .{ f, r.stderr });
            return error.TestUnexpectedResult;
        }
    }

    const kx = try writeProgram(a, io, "kx.kt", P_KX);
    try assertImageMatchesLegacy(a, io, &env, null, &.{ bin, "run", kx });
}

// -------------------------------------------------------------------------
// In-process round trip: bake a lowered base and deep-compare the loaded
// copy's tables against the original.
// -------------------------------------------------------------------------

fn parseOne(a: std.mem.Allocator, map: *SourceMap, name: []const u8, src: []const u8) !ast.KotlinFile {
    const fid = try map.add(name, src);
    const srcf = map.get(fid).source;
    var lx = try lexer.Lexer.init(a, fid, srcf);
    const lexed = try lx.tokenize();
    try std.testing.expect(!lexed.diagnostics.hasErrors());
    const p = parser.Parser.new(a, fid, srcf, lexed.tokens);
    const file_ast = p.parseFile();
    try std.testing.expect(!p.diagnostics.hasErrors());
    return file_ast;
}

const DEP_SRC =
    \\package dep.lib
    \\
    \\enum class Mode(val tag: Int) {
    \\    FAST(1),
    \\    SLOW(2) { override fun describe(): String = "slow" };
    \\    open fun describe(): String = "mode " + tag
    \\}
    \\open class Box(val size: Int) {
    \\    open fun grow(by: Int = 1): Box = Box(size + by)
    \\}
    \\class BigBox(size: Int) : Box(size) {
    \\    override fun grow(by: Int): Box = BigBox(size + by * 2)
    \\}
    \\object Counter { var hits = 0 }
    \\inline fun twice(block: () -> Int): Int = block() + block()
    \\fun depHelper(x: Int): Int = twice { x } + Mode.FAST.tag
    \\val depConst = 40 + 2
    \\
;

test "bake/load round-trips the lowered base tables" {
    const a = file_arena.allocator();

    var map = SourceMap.init(a);
    const dep = try parseOne(a, &map, "dep.kt", DEP_SRC);
    var files = [_]ast.KotlinFile{dep};
    const base = (try interp_ir.build.buildStdlibBase(a, &files)) orelse
        return error.TestUnexpectedResult;
    base.user_file_start = @intCast(map.files.items.len);

    const known = [_][]const u8{"dep.lib"};
    const fqns = [_][]const u8{"dep.lib.depHelper"};
    const bytes = (try interp_ir.image.bake(a, base, &map, .{
        .known_packages = &known,
        .binding_fqns = &fqns,
    })) orelse return error.TestUnexpectedResult;

    const loaded = (try interp_ir.image.load(a, bytes)) orelse {
        std.debug.print("image load failed: {s}\n", .{interp_ir.image.lastLoadFailure()});
        return error.TestUnexpectedResult;
    };
    const got = loaded.base;

    // Module spine.
    {
        const mg0 = base.built.module.borrow();
        defer mg0.deinit();
        const mg1 = got.built.module.borrow();
        defer mg1.deinit();
        const m0 = mg0.get();
        const m1 = mg1.get();
        // The loaded module's funcs are lazy (per-func header sections); decode
        // each through funcById and compare to the eager fresh-built func.
        try std.testing.expectEqual(m0.funcCount(), m1.funcCount());
        for (m0.funcs.items) |*f0| {
            const f1 = m1.funcById(f0.id).?;
            try std.testing.expectEqualStrings(f0.name, f1.name);
            try std.testing.expectEqualStrings(f0.fqn, f1.fqn);
            try std.testing.expectEqual(f0.id, f1.id);
            // Materialise lazily-deferred bodies ON BOTH SIDES so the
            // round-trip is checked through the lazy-IR decode, not against
            // an empty deferred marker (the fresh build defers bodies too).
            _ = m0.ensureFuncBody(@constCast(f0));
            _ = m1.ensureFuncBody(@constCast(f1));
            if (f0.blocks.len != f1.blocks.len)
                std.debug.print("round-trip block mismatch: {s}#{d} fresh={d} decoded={d}\n", .{ f0.fqn, f0.id.int(), f0.blocks.len, f1.blocks.len });
            try std.testing.expectEqual(f0.blocks.len, f1.blocks.len);
            if (f0.params.len != f1.params.len)
                std.debug.print("round-trip param mismatch: {s}#{d} fresh={d} decoded={d}\n", .{ f0.fqn, f0.id.int(), f0.params.len, f1.params.len });
            try std.testing.expectEqual(f0.params.len, f1.params.len);
            for (f0.blocks, f1.blocks) |b0, b1| {
                if (b0.insts.len != b1.insts.len)
                    std.debug.print("round-trip inst mismatch: {s}#{d} fresh={d} decoded={d} blocks={d}\n", .{ f0.fqn, f0.id.int(), b0.insts.len, b1.insts.len, f0.blocks.len });
                try std.testing.expectEqual(b0.insts.len, b1.insts.len);
                try std.testing.expectEqual(
                    @as(std.meta.Tag(@TypeOf(b0.terminator)), b0.terminator),
                    @as(std.meta.Tag(@TypeOf(b1.terminator)), b1.terminator),
                );
            }
        }
        const eqn = struct {
            fn check(label: []const u8, av: usize, bv: usize) !void {
                if (av != bv) std.debug.print("round-trip table mismatch: {s} fresh={d} decoded={d}\n", .{ label, av, bv });
                try std.testing.expectEqual(av, bv);
            }
        }.check;
        try eqn("consts", m0.consts.items.len, m1.consts.items.len);
        for (m0.consts.items, m1.consts.items) |c0, c1| {
            try std.testing.expect(c0.eql(c1));
        }
        try eqn("classes", m0.classes.items.len, m1.classes.items.len);
        try eqn("top_level", m0.top_level.items.len, m1.top_level.items.len);
        try eqn("func_index", m0.func_index.items.len, m1.func_index.items.len);
        try eqn("func_name_index", m0.func_name_index.count(), m1.func_name_index.count());
        try eqn("class_member_names", m0.registry.class_member_names.count(), m1.registry.class_member_names.count());
        try eqn("hierarchy_methods", m0.registry.hierarchy_methods.count(), m1.registry.hierarchy_methods.count());
        try eqn("class_const_inits", m0.registry.class_const_inits.count(), m1.registry.class_const_inits.count());
        try eqn("decl_user_arity", m0.decl_user_arity.count(), m1.decl_user_arity.count());
    }

    // Runtime class table: same keys, linked parents, enum entries.
    try std.testing.expectEqual(base.built.classes.count(), got.built.classes.count());
    {
        var it = base.built.classes.iterator();
        while (it.next()) |entry| {
            const other = got.built.classes.get(entry.key_ptr.*) orelse return error.TestUnexpectedResult;
            const g0 = entry.value_ptr.borrow();
            defer g0.deinit();
            const g1 = other.borrow();
            defer g1.deinit();
            try std.testing.expectEqualStrings(g0.get().fqn, g1.get().fqn);
            try std.testing.expectEqual(g0.get().methods.len, g1.get().methods.len);
            try std.testing.expectEqual(g0.get().enum_entries.len, g1.get().enum_entries.len);
            try std.testing.expectEqual(g0.get().parent != null, g1.get().parent != null);
            for (g0.get().enum_entries, g1.get().enum_entries) |e0, e1| {
                try std.testing.expectEqualStrings(e0.name, e1.name);
            }
        }
    }

    // Base gate sets + extras.
    try std.testing.expectEqual(base.decl_names.count(), got.decl_names.count());
    try std.testing.expect(got.decl_names.contains("depHelper"));
    try std.testing.expect(got.decl_names.contains("Mode"));
    try std.testing.expectEqual(base.packages.count(), got.packages.count());
    try std.testing.expect(got.packages.contains("dep.lib"));
    try std.testing.expectEqual(base.type_names.count(), got.type_names.count());
    try std.testing.expectEqual(base.inline_ids.len, got.inline_ids.len);
    for (base.inline_ids, got.inline_ids) |x0, x1| {
        try std.testing.expectEqual(x0.id, x1.id);
        try std.testing.expectEqualStrings(x0.f.get().name.name, x1.f.get().name.name);
    }
    try std.testing.expectEqual(base.enum_id_next, got.enum_id_next);
    try std.testing.expectEqual(base.user_file_start, got.user_file_start);
    // The loaded image drops the eager forest: decls decode lazily from the
    // per-decl sections on first `ForestField.get()`, so `lifted_decls` is empty.
    try std.testing.expectEqual(@as(usize, 0), got.lifted_decls.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.known_packages.len);
    try std.testing.expectEqualStrings("dep.lib", loaded.known_packages[0]);
    try std.testing.expectEqual(@as(usize, 1), loaded.binding_fqns.len);

    // The loaded map mirrors the baked one.
    try std.testing.expectEqual(map.files.items.len, loaded.map.files.items.len);
    try std.testing.expectEqualStrings(map.files.items[0].path, loaded.map.files.items[0].path);

    // Both bases accept and extend the same user program identically.
    // The base here is DEP-ONLY (no stdlib), so the user program must stay
    // within that surface: a bare `println` against a base with no candidate
    // is now a recorded pre-run resolve diagnostic (correctly — see the
    // provably-unresolved bare-call rejection), and this test asserts a
    // diag-free lowering. The values still flow through every dep shape the
    // table comparison exercises.
    const USER_SRC =
        \\import dep.lib.*
        \\fun main(): Int {
        \\    val a = depHelper(20) + depConst
        \\    val b = BigBox(3).grow(2).size
        \\    val c = Mode.SLOW.describe()
        \\    return a + b + c.length
        \\}
        \\
    ;
    {
        var user_map0 = SourceMap.init(a);
        try user_map0.files.appendSlice(user_map0.arena.allocator(), map.files.items);
        const uf0 = try parseOne(a, &user_map0, "user.kt", USER_SRC);
        var user_map1 = SourceMap.init(a);
        try user_map1.files.appendSlice(user_map1.arena.allocator(), loaded.map.files.items);
        const uf1 = try parseOne(a, &user_map1, "user.kt", USER_SRC);

        var files0 = [_]ast.KotlinFile{uf0};
        var files1 = [_]ast.KotlinFile{uf1};
        try std.testing.expect(interp_ir.build.canExtendBase(base, &files0));
        try std.testing.expect(interp_ir.build.canExtendBase(got, &files1));
        var built0 = try interp_ir.build.buildModuleFilesExtend(a, base, &files0);
        var built1 = try interp_ir.build.buildModuleFilesExtend(a, got, &files1);
        defer built0.deinit();
        defer built1.deinit();
        try std.testing.expect(built0.main != null);
        try std.testing.expect(built1.main != null);
        const bg0 = built0.module.borrow();
        defer bg0.deinit();
        const bg1 = built1.module.borrow();
        defer bg1.deinit();
        try std.testing.expectEqual(bg0.get().funcCount(), bg1.get().funcCount());
        for (bg0.get().resolve_diags.items) |d|
            std.debug.print("round-trip resolve diag: {s} kind={s} file={d} at={d}\n", .{ d.name, @tagName(d.kind), d.span.file.int(), d.span.start });
        try std.testing.expectEqual(@as(usize, 0), bg0.get().resolve_diags.items.len);
        try std.testing.expectEqual(@as(usize, 0), bg1.get().resolve_diags.items.len);
    }
}
