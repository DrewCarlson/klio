//! Stdlib image cache for the CLI: bake the lowered dependency base (embedded
//! stdlib sources plus selected packs) to `~/.klio/cache/stdlib-<key>.klio-image`
//! once, then load and extend it per run.
//!
//! The key is a Blake3 over the image format version, the running executable's
//! size and mtime, the path, size and mtime of every stdlib source the pack
//! builder reads (or the `KLIO_STDLIB_PACK` override pack bytes), the stdlib load gate
//! (implicit-only vs full curated set), and each selected pack's stored content
//! hash and resolved feature set. A mismatch rebakes rather than serving stale
//! lowered code. Packs still load per run for their bindings and known-package
//! registrations; only the stdlib sources and dependency lowering ride the image.
//! `KLIO_STDLIB_IMAGE=0` or `KLIO_PACK_DIAG` disables the cache.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const span = @import("span");
const SourceMap = span.SourceMap;

const ast = @import("ast");
const KotlinFile = ast.KotlinFile;

const lexer = @import("lexer");
const parser = @import("parser");

const pack = @import("pack");
const interp_ir = @import("interp_ir");
const typeck_mod = @import("typeck");
const types_mod = @import("types");
const ir_mod = @import("ir");
const image = interp_ir.image;
const StdlibBase = interp_ir.build.StdlibBase;
const BuiltModule = interp_ir.build.BuiltModule;

const runtime = @import("runtime");
const stdlib = @import("stdlib");
const HostBindings = stdlib.HostBindings;

const stdlib_pack = @import("stdlib_pack");

const io = @import("io.zig");
const pack_cache = @import("pack_cache.zig");
const project = @import("project.zig");
const RequestedFeatures = pack_cache.RequestedFeatures;

/// Keep this many images; older ones (by mtime) are pruned after a bake. Below
/// ~10 the examples corpus makes parallel runs evict images siblings need.
const KEEP_IMAGES = 24;

/// A program assembled against the image base, on the caller's process arena.
pub const Prepared = struct {
    built: BuiltModule,
    map: *const SourceMap,
    bindings: HostBindings,
    /// The user files parsed onto `map`; their FileIds trail the base's.
    user_asts: []const KotlinFile,
    /// Lazy bodies: the program already ran inside the build, with this code.
    ran: ?u8 = null,
};

fn getEnvVar(allocator: Allocator, name: []const u8) ?[]u8 {
    return runtime.procEnvGetVar(allocator, name) catch null;
}

fn traceEnabled(gpa: Allocator) bool {
    const v = getEnvVar(gpa, "KLIO_TRACE_STDLIB_IMAGE") orelse return false;
    defer gpa.free(v);
    return v.len != 0 and !std.mem.eql(u8, v, "0");
}

fn trace(gpa: Allocator, comptime fmt: []const u8, args: anytype) void {
    if (!traceEnabled(gpa)) return;
    io.printStderr(gpa, "[stdlib-image] " ++ fmt ++ " (rss {d}mb)\n", args ++ .{rssMb()});
}

/// Resident set in MB, for the traces; 0 where the platform does not say.
pub fn rssMb() u64 {
    return (runtime.currentRssKb() orelse 0) / 1024;
}

fn disabled(gpa: Allocator) bool {
    if (getEnvVar(gpa, "KLIO_PACK_DIAG")) |v| {
        gpa.free(v);
        return true;
    }
    if (getEnvVar(gpa, "KLIO_STDLIB_IMAGE")) |v| {
        defer gpa.free(v);
        return std.mem.eql(u8, v, "0");
    }
    return false;
}

fn threadedIo(allocator: Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(allocator, .{});
}

/// `bakeStdlibCache` points the cache at a directory of its own for one bake.
var cache_dir_override: ?[]const u8 = null;

/// `$KLIO_HOME/.klio/cache` (or `~/.klio/cache`), created if absent. Caller frees.
fn cacheDir(gpa: Allocator) ?[]u8 {
    if (cache_dir_override) |dir| {
        var threaded = threadedIo(gpa);
        defer threaded.deinit();
        std.Io.Dir.cwd().createDirPath(threaded.io(), dir) catch return null;
        return gpa.dupe(u8, dir) catch null;
    }
    const home = (runtime.procEnvKlioHome(gpa) catch null) orelse return null;
    defer gpa.free(home);
    const dir = std.fs.path.join(gpa, &.{ home, ".klio", "cache" }) catch return null;
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    std.Io.Dir.cwd().createDirPath(threaded.io(), dir) catch {
        gpa.free(dir);
        return null;
    };
    return dir;
}

/// Size + mtime of the running executable: any rebuild invalidates every image.
/// The running executable's path, into `buf`.
fn exePath(buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (builtin.os.tag == .linux) return "/proc/self/exe";
    if (builtin.os.tag.isDarwin()) {
        var n: u32 = buf.len;
        if (std.c._NSGetExecutablePath(buf, &n) != 0) return null;
        return std.mem.sliceTo(buf, 0);
    }
    return null;
}

/// The image the build installed beside the binary for this key, if any:
/// `<bin dir>/../share/klio/cache/stdlib-<key>.klio-image`. Caller frees.
fn shippedImagePath(gpa: Allocator, hex: [32]u8) ?[]u8 {
    const name = std.fmt.allocPrint(gpa, "stdlib-{s}.klio-image", .{hex}) catch return null;
    defer gpa.free(name);
    return shippedCachePath(gpa, name);
}

/// The build's copy of a cache file `name`, beside the binary. Caller frees.
/// `KLIO_STDLIB_IMAGE_SHIPPED=0` ignores that copy, for a measurement or a
/// test that wants the run's own cache to decide.
fn shippedCachePath(gpa: Allocator, name: []const u8) ?[]u8 {
    if (runtime.envOnce("KLIO_STDLIB_IMAGE_SHIPPED")) |v| {
        if (std.mem.eql(u8, v, "0")) return null;
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exePath(&buf) orelse return null;
    // The Linux path is a link; the shipped cache sits beside the real file.
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = if (builtin.os.tag == .linux)
        (std.posix.readlink(exe, &real_buf) catch return null)
    else
        exe;
    const bin_dir = std.fs.path.dirname(real) orelse return null;
    return std.fs.path.join(gpa, &.{ bin_dir, "..", "share", "klio", "cache", name }) catch null;
}

/// The run's meta file, else the build's copy of it beside the binary, so a
/// fresh data home takes the shipped image without parsing the stdlib to
/// learn the key.
fn readMetaFromCaches(gpa: Allocator, meta_file: []const u8) ?MetaFile {
    if (readMeta(gpa, meta_file)) |m| return m;
    const shipped = shippedCachePath(gpa, std.fs.path.basename(meta_file)) orelse return null;
    defer gpa.free(shipped);
    return readMeta(gpa, shipped);
}

/// The image for `hex` from the run's cache, else the one shipped beside the
/// binary; `shipped` says which served.
const FoundImage = struct { loaded: image.Loaded, shipped: bool };

fn loadImageFromCaches(gpa: Allocator, image_path: []const u8, hex: [32]u8) ?FoundImage {
    if (loadImageFile(gpa, image_path)) |loaded| return .{ .loaded = loaded, .shipped = false };
    const shipped = shippedImagePath(gpa, hex) orelse return null;
    defer gpa.free(shipped);
    if (loadImageFile(gpa, shipped)) |loaded| return .{ .loaded = loaded, .shipped = true };
    return null;
}

fn exeStamp(gpa: Allocator) ?[2]u64 {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = exePath(&buf) orelse return null;
    const st = cwd.statFile(fio, path, .{}) catch return null;
    const mtime_ns: u64 = @truncate(@as(u128, @bitCast(@as(i128, st.mtime.nanoseconds))));
    return .{ st.size, mtime_ns };
}

/// Content hash of every stdlib source the bake consumes, in `stdlibPackBytes`'s
/// resolution order: the `KLIO_STDLIB_PACK` override pack, else the curated
/// upstream files + klio actuals from the cwd checkout, else the embedded pack.
fn stdlibContentHash(gpa: Allocator) ?[32]u8 {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    const cwd = std.Io.Dir.cwd();

    var hasher = std.crypto.hash.Blake3.init(.{});

    // Salt for the @Composable lowering plugin: an image baked without its
    // bake-time rewrite of base/pack composables must never be reused.
    hasher.update("compose_plugin:1;");

    var override_hashed = false;
    if (getEnvVar(gpa, "KLIO_STDLIB_PACK")) |override_path| {
        defer gpa.free(override_path);
        if (cwd.readFileAlloc(fio, override_path, gpa, .unlimited) catch null) |bytes| {
            defer gpa.free(bytes);
            hasher.update("override:");
            hasher.update(override_path);
            hasher.update(bytes);
            override_hashed = true;
        }
    }
    if (!override_hashed and !hashCheckoutSources(gpa, fio, &hasher)) {
        return embeddedContentHash();
    }

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// Fold the cwd checkout's stdlib sources into `hasher` by path, size and
/// modification time; false when one is missing, and the run falls through
/// to the embedded pack. Reading and hashing the sources themselves cost more
/// than loading the image they key.
fn hashCheckoutSources(gpa: Allocator, fio: std.Io, hasher: *std.crypto.hash.Blake3) bool {
    _ = gpa;
    const cwd = std.Io.Dir.cwd();
    const pb = stdlib.pack_builder;
    var upstream = cwd.openDir(fio, pb.UPSTREAM_STDLIB_ROOT, .{}) catch return false;
    defer upstream.close(fio);
    for (pb.CURATED_UPSTREAM_SOURCES) |rel| {
        if (!hashSourceStamp(fio, upstream, rel, hasher)) return false;
    }
    var klio_dir = cwd.openDir(fio, pb.KLIO_STDLIB_DIR, .{}) catch return false;
    defer klio_dir.close(fio);
    for (pb.KLIO_STDLIB_ACTUAL_FILES) |rel| {
        if (!hashSourceStamp(fio, klio_dir, rel, hasher)) return false;
    }
    return true;
}

fn hashSourceStamp(fio: std.Io, dir: std.Io.Dir, rel: []const u8, hasher: *std.crypto.hash.Blake3) bool {
    const st = dir.statFile(fio, rel, .{}) catch return false;
    hasher.update(rel);
    hasher.update(":");
    var word: [8]u8 = undefined;
    std.mem.writeInt(u64, &word, st.size, .little);
    hasher.update(&word);
    const mtime_ns: u64 = @truncate(@as(u128, @bitCast(@as(i128, st.mtime.nanoseconds))));
    std.mem.writeInt(u64, &word, mtime_ns, .little);
    hasher.update(&word);
    return true;
}

/// Identity of the pack bytes embedded in the binary, null in builds carrying
/// none.
///
/// The bytes are part of the executable, and the key already carries the
/// executable's stamp, so hashing ten megabytes on every run only restates what
/// the stamp says. The length keeps this distinct from a checkout hash over the
/// same sources.
fn embeddedContentHash() ?[32]u8 {
    const bytes = stdlib_pack.EMBEDDED_PACK_BYTES orelse return null;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("embedded:");
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, bytes.len, .little);
    hasher.update(&len_buf);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn imageKey(
    stdlib_hash: [32]u8,
    exe: [2]u64,
    gate_full: bool,
    packs: []const pack_cache.SelectedPack,
) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("klio-stdlib-image");
    var word: [8]u8 = undefined;
    std.mem.writeInt(u64, &word, image.FORMAT_VERSION, .little);
    hasher.update(&word);
    std.mem.writeInt(u64, &word, exe[0], .little);
    hasher.update(&word);
    std.mem.writeInt(u64, &word, exe[1], .little);
    hasher.update(&word);
    hasher.update(&stdlib_hash);
    hasher.update(if (gate_full) "gate:full" else "gate:implicit");
    // Order-independent XOR fold: selection order is loader-internal.
    var fold: [32]u8 = @splat(0);
    for (packs) |p| {
        var ph = std.crypto.hash.Blake3.init(.{});
        ph.update(&p.hash);
        for (p.features) |f| {
            ph.update("/");
            ph.update(f);
        }
        var digest: [32]u8 = undefined;
        ph.final(&digest);
        for (&fold, digest) |*dst, b| dst.* ^= b;
    }
    std.mem.writeInt(u64, &word, packs.len, .little);
    hasher.update(&word);
    hasher.update(&fold);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn keyHex(key: [32]u8) [32]u8 {
    return std.fmt.bytesToHex(key[0..16].*, .lower);
}

// Meta sidecar: the stdlib package universe, for the load gate without a parse.
const MetaFile = struct {
    pkgs: []const []const u8,
    any_non_implicit: bool,
};

fn metaPath(gpa: Allocator, cache: []const u8, stdlib_hash: [32]u8) ?[]u8 {
    const hex = std.fmt.bytesToHex(stdlib_hash[0..16].*, .lower);
    return std.fmt.allocPrint(gpa, "{s}/stdlib-meta-{s}.bin", .{ cache, hex }) catch null;
}

fn readMeta(gpa: Allocator, path: []const u8) ?MetaFile {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .unlimited) catch return null;
    var perr: pack.PackError = undefined;
    const meta = (pack.read.decode(MetaFile, gpa, bytes, &perr) catch null) orelse {
        gpa.free(bytes);
        return null;
    };
    gpa.free(bytes);
    return meta;
}

fn writeMeta(gpa: Allocator, cache: []const u8, path: []const u8, meta: MetaFile) void {
    var perr: pack.PackError = undefined;
    var bytes = (pack.write.encode(MetaFile, gpa, &meta, &perr) catch return) orelse return;
    defer bytes.deinit(gpa);
    writeAtomic(gpa, cache, path, bytes.items);
}

/// Temp file + rename, so a racing reader never sees a partial file.
fn writeAtomic(gpa: Allocator, cache: []const u8, dest: []const u8, bytes: []const u8) void {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    const pid: u64 = switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
    const unique = runtime.clockMonotonicNanos() ^ (pid << 32);
    const tmp = std.fmt.allocPrint(gpa, "{s}/.tmp-{x}", .{ cache, unique }) catch return;
    defer gpa.free(tmp);
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(fio, .{ .sub_path = tmp, .data = bytes }) catch return;
    cwd.rename(tmp, cwd, dest, fio) catch {
        cwd.deleteFile(fio, tmp) catch {};
    };
}

/// The base's declarations published for the user check, on its own thread
/// beside the strip.
/// The image write, off the path the program is waiting on. `finishBackgroundBake`
/// joins it before the process exits, so a normal exit never leaves a
/// half-written temp file behind.
const ImageWriter = struct {
    gpa: Allocator,
    cache: []u8,
    image_path: []u8,
    bytes: []const u8,
    thread: ?std.Thread = null,

    fn run(self: *ImageWriter) void {
        defer runtime.slab.flushMagazines();
        writeAtomic(self.gpa, self.cache, self.image_path, self.bytes);
        clearBakeMarker(self.gpa, self.image_path);
        pruneImages(self.gpa, self.cache);
    }
};

var image_writer: ?*ImageWriter = null;

/// Publishes `bytes` as the image at `image_path` on a thread. The loaded
/// base borrows `bytes` for the process's life, so they are never freed.
fn publishImage(gpa: Allocator, cache: []const u8, image_path: []const u8, bytes: []const u8) void {
    finishBackgroundBake();
    const w = gpa.create(ImageWriter) catch return;
    w.* = .{
        .gpa = gpa,
        .cache = gpa.dupe(u8, cache) catch return,
        .image_path = gpa.dupe(u8, image_path) catch return,
        .bytes = bytes,
    };
    w.thread = std.Thread.spawn(.{}, ImageWriter.run, .{w}) catch null;
    if (w.thread == null) w.run();
    image_writer = w;
}

/// Waits for the image write: a command that exists to produce the image
/// returns with it written, and a run does not exit from under it.
pub fn finishBackgroundBake() void {
    const w = image_writer orelse return;
    image_writer = null;
    if (w.thread) |t| t.join();
    w.gpa.free(w.cache);
    w.gpa.free(w.image_path);
    w.gpa.destroy(w);
}

fn pruneImages(gpa: Allocator, cache: []const u8) void {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(fio, cache, .{ .iterate = true }) catch return;
    defer dir.close(fio);
    const Entry = struct { name: []u8, mtime: i96 };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| gpa.free(e.name);
        entries.deinit(gpa);
    }
    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".klio-image")) continue;
        const st = dir.statFile(fio, entry.name, .{}) catch continue;
        const name = gpa.dupe(u8, entry.name) catch continue;
        entries.append(gpa, .{ .name = name, .mtime = st.mtime.nanoseconds }) catch {
            gpa.free(name);
            continue;
        };
    }
    if (entries.items.len <= KEEP_IMAGES) return;
    std.mem.sort(Entry, entries.items, {}, struct {
        fn newerFirst(_: void, x: Entry, y: Entry) bool {
            return x.mtime > y.mtime;
        }
    }.newerFirst);
    for (entries.items[KEEP_IMAGES..]) |e| {
        dir.deleteFile(fio, e.name) catch {};
    }
}

pub const ParsedUser = struct {
    texts: [][]const u8,
    asts: []KotlinFile,
};

/// Parse the user files onto `map`. Null on any read/lex/parse failure; the
/// caller then takes the whole-program path, which renders the diagnostics.
pub fn parseUserFiles(gpa: Allocator, map: *SourceMap, paths: []const []const u8, texts: ?[][]const u8) ?ParsedUser {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    const out_texts = gpa.alloc([]const u8, paths.len) catch return null;
    const out_asts = gpa.alloc(KotlinFile, paths.len) catch return null;
    for (paths, 0..) |path, i| {
        const text = if (texts) |t| t[i] else std.Io.Dir.cwd().readFileAlloc(fio, path, gpa, .unlimited) catch return null;
        out_texts[i] = text;
        const fid = map.add(path, text) catch return null;
        const src = map.get(fid).source;
        var lx = lexer.Lexer.init(gpa, fid, src) catch return null;
        const lexed = lx.tokenize() catch return null;
        if (lexed.diagnostics.hasErrors()) return null;
        const p = parser.Parser.new(gpa, fid, src, lexed.tokens, lexed.strings);
        const file_ast = p.parseFile();
        if (p.diagnostics.hasErrors()) return null;
        out_asts[i] = file_ast;
    }
    return .{ .texts = out_texts, .asts = out_asts };
}

/// Stage the base's eager call resolutions before `buildStdlibBase` lowers the
/// bodies; an unproven composable call bakes without its `($composer, $changed)`.
/// The stage as the build runs it, beside its own table passes.
const StageCtx = struct { gpa: Allocator };

/// What the lazy run needs from the cold driver, and what it leaves.
const LazyRun = struct {
    gpa: Allocator,
    known_packages: []const []const u8,
    binding_fqns: []const []const u8,
    dep_map: *const SourceMap,
    user: ParsedUser,
    paths: []const []const u8,
    bindings: HostBindings,
    prepared: ?Prepared = null,
};

/// Runs the program against a base whose bodies are still deferred; each
/// lowers on its first call through the module's hook.
fn lazyRunProgram(ctx: *anyopaque, base: *interp_ir.build.StdlibBase) u8 {
    const r: *LazyRun = @ptrCast(@alignCast(ctx));
    const prepared = finishFromBase(r.gpa, base, r) orelse return 1;
    r.prepared = prepared;
    interp_ir.build.lazy.enterRun();
    trace(r.gpa, "  lazy bodies: the program runs inside the build", .{});
    const msg = if (r.paths.len == 1) "error: no main function found" else "runtime error: no main function in module";
    return @import("commands.zig").runBuiltModuleArgs(r.gpa, prepared.built, prepared.bindings, prepared.map, msg, &.{});
}

/// `finishFromLoaded` over a base built in this process rather than loaded
/// from an image: the user program extends it and runs it.
fn finishFromBase(gpa: Allocator, base: *interp_ir.build.StdlibBase, r: *const LazyRun) ?Prepared {
    for (r.known_packages) |pkg| stdlib.registerKnownPackage(pkg);
    if (!interp_ir.build.canExtendBase(base, r.user.asts)) {
        trace(gpa, "fallback (base name collision)", .{});
        return null;
    }
    const map = gpa.create(SourceMap) catch return null;
    map.* = SourceMap.init(gpa);
    map.files.appendSlice(map.arena.allocator(), r.dep_map.files.items) catch return null;
    const user2 = parseUserFiles(gpa, map, r.paths, r.user.texts) orelse return null;
    publishExternDecls(gpa, base);
    ir_mod.discardPendingPicks();
    publishBaseEagerCalls(gpa, base);
    if (@import("commands.zig").eagerCallsOn()) {
        if (@import("commands.zig").computeEagerCalls(gpa, user2.asts, &.{})) |ec| ir_mod.pending_eager_calls = ec;
    }
    span.active_map = map;
    span.dumpFileIds(map);
    // The base is baked after the run, so the run module clones its tables
    // rather than taking them, and clones all of them: bodies lower into it
    // as the program runs.
    interp_ir.build.clone.complete_run_clone = true;
    defer interp_ir.build.clone.complete_run_clone = false;
    const built = interp_ir.build.buildModuleFilesExtend(gpa, base, user2.asts) catch return null;
    {
        // A body lowering on first call appends to the module frames are
        // running in: new functions box rather than move the table, and the
        // constants take their room now rather than move later.
        const mg = built.module.borrow();
        defer mg.deinit();
        const m: *ir_mod.Module = @constCast(mg.get());
        m.funcs_live = true;
        m.consts.ensureUnusedCapacity(m.func_name_index.allocator, 1 << 16) catch {};
        m.late_funcs.ensureUnusedCapacity(m.func_name_index.allocator, 1 << 14) catch {};
    }
    var bindings = r.bindings;
    for (r.binding_fqns) |fqn| {
        if (bindings.resolve(fqn)) |f| bindings.register(fqn, f) catch {};
    }
    return .{ .built = built, .map = map, .bindings = bindings, .user_asts = user2.asts };
}

fn stageJobRun(ctx: *anyopaque, files: []const KotlinFile) void {
    const c: *const StageCtx = @ptrCast(@alignCast(ctx));
    stageBaseEagerCalls(c.gpa, files);
}

fn stageBaseEagerCalls(gpa: Allocator, asts: []const KotlinFile) void {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_STDLIB_CHECK") orelse "1", "0")) return;
    // The base's own sources are the whole universe for calls inside them, so a
    // source extension pick is trustworthy here, unlike in a user program.
    typeck_mod.check.expr_calls.complete_universe = true;
    defer typeck_mod.check.expr_calls.complete_universe = false;
    // The picks are all this run reads; `KLIO_STAGE_DIAG` runs the checker's
    // diagnostic passes too, to compare against.
    const opts: @import("commands.zig").EagerCallOptions = .{ .diagnostics = runtime.envOnce("KLIO_STAGE_DIAG") != null };
    const t0 = runtime.clockMonotonicNanos();
    if (@import("commands.zig").computeEagerCallsOpts(gpa, asts, &.{}, opts)) |ec| {
        if (ir_mod.pending_eager_calls) |*old| old.deinit();
        ir_mod.pending_eager_calls = ec;
    }
    // The tables sit in this thread's storage; the build, on its own thread
    // with its module already made, adopts them from here after the join.
    ir_mod.staged_picks = ir_mod.takePendingPicks();
    trace(gpa, "  stage total: {d}ms", .{(runtime.clockMonotonicNanos() - t0) / 1_000_000});
}

/// Check the base's sources, keying the resolutions to FuncIds so they ride the
/// image. Runs only while an image is being built.
fn checkBaseSources(gpa: Allocator, base: *interp_ir.build.StdlibBase, asts: []const KotlinFile) void {
    _ = asts;
    if (std.mem.eql(u8, runtime.envOnce("KLIO_STDLIB_CHECK") orelse "1", "0")) return;
    // Resolutions arrive as call span -> declaration span; key each to its FuncId.
    {
        var out: std.ArrayList(interp_ir.build.StdlibBase.EagerCall) = .empty;
        var total: usize = 0;
        {
            const mg = base.built.module.borrow();
            defer mg.deinit();
            const m = mg.get();
            if (m.eager_calls) |*owned| {
                total = owned.count();
                var it = owned.iterator();
                while (it.next()) |e| {
                    const fid = m.funcByDeclSpan(e.value_ptr.*) orelse continue;
                    out.append(gpa, .{ .call = e.key_ptr.*, .fid = fid.int() }) catch continue;
                }
            }
        }
        // By call site, so the baked order does not depend on how the
        // checker's map was filled.
        std.mem.sort(interp_ir.build.StdlibBase.EagerCall, out.items, {}, struct {
            fn lessThan(_: void, x: interp_ir.build.StdlibBase.EagerCall, y: interp_ir.build.StdlibBase.EagerCall) bool {
                if (x.call.file.int() != y.call.file.int()) return x.call.file.int() < y.call.file.int();
                if (x.call.start != y.call.start) return x.call.start < y.call.start;
                return x.call.end < y.call.end;
            }
        }.lessThan);
        base.eager_calls = out.toOwnedSlice(gpa) catch &.{};
        if (runtime.envOnce("KLIO_EAGER_AUDIT") != null) {
            std.debug.print("[stdlib-check] {d} base call resolutions, {d} keyed to a FuncId\n", .{ total, base.eager_calls.len });
        }
    }
    // The checker's per-run channels belong to the user program; drop base staging.
    if (ir_mod.pending_eager_calls) |*m| {
        m.deinit();
        ir_mod.pending_eager_calls = null;
    }
    if (ir_mod.pending_eager_call_fids) |*m| {
        m.deinit();
        ir_mod.pending_eager_call_fids = null;
    }
}

/// Republish the base's baked eager call resolutions under the user program's.
fn publishBaseEagerCalls(gpa: std.mem.Allocator, sb: *const interp_ir.build.StdlibBase) void {
    if (sb.eager_calls.len == 0) return;
    if (std.mem.eql(u8, runtime.envOnce("KLIO_BASE_EAGER") orelse "1", "0")) return;
    var m = ir_mod.pending_eager_call_fids orelse std.AutoHashMap(span.Span, u32).init(gpa);
    for (sb.eager_calls) |ec| m.put(ec.call, ec.fid) catch {};
    ir_mod.pending_eager_call_fids = m;
    if (runtime.envOnce("KLIO_EAGER_AUDIT") != null) {
        std.debug.print("[stdlib-check] republished {d} base call resolutions\n", .{sb.eager_calls.len});
    }
}

fn headOf(name: []const u8) []const u8 {
    var h = std.mem.trimEnd(u8, name, "?");
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    if (std.mem.findScalarLast(u8, h, '.')) |d| h = h[d + 1 ..];
    return h;
}

/// The image's structural type, copied into the shape the checker reads.
fn externTypeOf(gpa: std.mem.Allocator, t: *const ir_mod.TypeRef) types_mod.ExternType {
    const args = gpa.alloc(types_mod.ExternType, t.args.len) catch return .{ .name = t.name, .nullable = t.nullable };
    for (t.args, args) |*src, *dst| dst.* = externTypeOf(gpa, src);
    return .{ .name = t.name, .nullable = t.nullable, .args = args };
}

/// One declaration's whole signature from its `DeclSig`; null for a private
/// one, which no program can name.
fn externFnOf(gpa: std.mem.Allocator, m: *const ir_mod.Module, name: []const u8, fid: u32, ds: *const ir_mod.Module.DeclSig) ?types_mod.ExternFn {
    if (ds.visibility == .Private) return null;
    const n = ds.sig.len;
    const params = gpa.alloc(types_mod.ExternType, n) catch return null;
    for (ds.sig, params) |*p, *dst| dst.* = externTypeOf(gpa, p);
    const names: []const []const u8 = if (ds.param_names.len == n) ds.param_names else blk: {
        const out = gpa.alloc([]const u8, n) catch return null;
        @memset(out, "");
        break :blk out;
    };
    const defaults: []const bool = if (ds.param_defaults.len == n) ds.param_defaults else blk: {
        const out = gpa.alloc(bool, n) catch return null;
        for (out, 0..) |*d, i| d.* = i >= ds.arity.required;
        break :blk out;
    };
    const tps: []const []const u8 = if (m.registry.func_type_params.get(ir_mod.FuncId.from(fid))) |list| list.items else &.{};
    return .{
        .name = name,
        .fid = fid,
        .type_params = tps,
        .receiver = if (ds.receiver_ty) |*rt| externTypeOf(gpa, rt) else null,
        .params = params,
        .param_names = names,
        .param_defaults = defaults,
        .has_vararg = ds.arity.has_vararg,
        .return_ty = if (ds.return_ty) |*rt| externTypeOf(gpa, rt) else null,
        .is_suspend = ds.is_suspend,
        .has_body = ds.has_body,
        .visibility = ds.visibility,
    };
}

/// Publish the image's own declarations for the checker (`types.ExternDecls`).
fn publishExternDecls(gpa: std.mem.Allocator, sb: *const interp_ir.build.StdlibBase) void {
    const mg = sb.built.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    // Simple names are the only spelling the checker's class table uses, so a name
    // two classes share identifies nothing and is dropped from every published map.
    var ambiguous_names = std.StringHashMap(void).init(gpa);
    defer ambiguous_names.deinit();
    {
        var seen = std.StringHashMap(void).init(gpa);
        defer seen.deinit();
        for (m.classes.items) |*c| {
            const gop = seen.getOrPut(c.name) catch continue;
            if (gop.found_existing) ambiguous_names.put(c.name, {}) catch {};
        }
    }
    // Member declarations by owner: the declaration records carry no name of
    // their own, and the member index is what the image loads eagerly.
    var members_by_owner = std.StringHashMap(std.ArrayList(types_mod.ExternFn)).init(gpa);
    defer members_by_owner.deinit();
    {
        var it = m.member_name_index.iterator();
        while (it.next()) |e| {
            const owner_fqn = e.key_ptr.a;
            const name = e.key_ptr.b;
            for (e.value_ptr.items) |fid| {
                const ds = m.decl_sigs.get(fid.int()) orelse continue;
                if (ds.receiver_ty != null) continue;
                const ef = externFnOf(gpa, m, name, fid.int(), &ds) orelse continue;
                const gop = members_by_owner.getOrPut(owner_fqn) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(gpa, ef) catch {};
            }
        }
    }
    var classes = std.StringHashMap(types_mod.ExternClass).init(gpa);
    for (m.classes.items) |*c| {
        if (ambiguous_names.contains(c.name)) continue;
        var props: std.ArrayList(types_mod.ExternProp) = .empty;
        for (c.primary_params) |*pp| {
            if (!pp.is_property) continue;
            props.append(gpa, .{ .name = pp.name, .ty = externTypeOf(gpa, &pp.ty) }) catch {};
        }
        for (c.declared_props) |*dp| {
            const ty: ?types_mod.ExternType = if (m.registry.class_prop_type_refs.get(.{ .a = c.name, .b = dp.name })) |*tr| externTypeOf(gpa, tr) else null;
            props.append(gpa, .{ .name = dp.name, .ty = ty, .is_abstract = dp.is_abstract }) catch {};
        }
        const ctor: ?types_mod.ExternFn = if (c.has_primary_ctor and !c.is_interface) blk: {
            const n = c.primary_params.len;
            const params = gpa.alloc(types_mod.ExternType, n) catch break :blk null;
            const names = gpa.alloc([]const u8, n) catch break :blk null;
            const defaults = gpa.alloc(bool, n) catch break :blk null;
            var has_vararg = false;
            for (c.primary_params, params, names, defaults) |*pp, *pt, *pn, *pd| {
                pt.* = externTypeOf(gpa, &pp.ty);
                pn.* = pp.name;
                pd.* = pp.default != null;
                if (pp.is_vararg) has_vararg = true;
            }
            break :blk .{
                .name = c.name,
                .fid = 0,
                .type_params = c.type_params,
                .params = params,
                .param_names = names,
                .param_defaults = defaults,
                .has_vararg = has_vararg,
            };
        } else null;
        var secondaries: std.ArrayList(types_mod.ExternFn) = .empty;
        for (c.secondary_ctor_arities) |*ca| {
            if (ca.low_priority) continue;
            const n = ca.param_heads.len;
            const params = gpa.alloc(types_mod.ExternType, n) catch continue;
            for (ca.param_heads, params) |h, *pt| pt.* = .{ .name = h };
            const names = gpa.alloc([]const u8, n) catch continue;
            if (ca.param_names.len == n) @memcpy(names, ca.param_names) else @memset(names, "");
            const defaults = gpa.alloc(bool, n) catch continue;
            if (ca.param_defaults.len == n) @memcpy(defaults, ca.param_defaults) else @memset(defaults, false);
            secondaries.append(gpa, .{
                .name = c.name,
                .fid = 0,
                .type_params = c.type_params,
                .params = params,
                .param_names = names,
                .param_defaults = defaults,
                .has_vararg = ca.vararg,
            }) catch {};
        }
        const supers = gpa.alloc(types_mod.ExternType, c.supertypes.len) catch continue;
        var n_supers: usize = 0;
        for (c.supertypes, 0..) |sid, i| {
            if (i < c.supertype_refs.len) {
                supers[n_supers] = externTypeOf(gpa, &c.supertype_refs[i]);
            } else {
                if (sid.int() >= m.classes.items.len) continue;
                supers[n_supers] = .{ .name = m.classes.items[sid.int()].name };
            }
            n_supers += 1;
        }
        var methods: []const types_mod.ExternFn = if (members_by_owner.get(c.fqn)) |list| list.items else &.{};
        // A companion's members answer `Foo.bar` on the class itself.
        if (c.companion) |cid| if (cid.int() < m.classes.items.len) {
            const comp = &m.classes.items[cid.int()];
            if (members_by_owner.get(comp.fqn)) |list| {
                const merged = gpa.alloc(types_mod.ExternFn, methods.len + list.items.len) catch break;
                @memcpy(merged[0..methods.len], methods);
                @memcpy(merged[methods.len..], list.items);
                methods = merged;
            }
            for (comp.primary_params) |*pp| {
                if (!pp.is_property) continue;
                props.append(gpa, .{ .name = pp.name, .ty = externTypeOf(gpa, &pp.ty) }) catch {};
            }
            for (comp.declared_props) |*dp| {
                const ty: ?types_mod.ExternType = if (m.registry.class_prop_type_refs.get(.{ .a = comp.name, .b = dp.name })) |*tr| externTypeOf(gpa, tr) else null;
                props.append(gpa, .{ .name = dp.name, .ty = ty, .is_abstract = dp.is_abstract }) catch {};
            }
        };
        classes.put(c.name, .{
            .name = c.name,
            .type_params = c.type_params,
            .supertypes = supers[0..n_supers],
            .methods = methods,
            .props = props.items,
            .ctor = ctor,
            .secondary_ctors = secondaries.items,
            .has_secondary_ctors = c.secondary_ctor_count != 0,
            .is_interface = c.is_interface,
            .is_abstract = c.is_abstract,
            .is_open = c.is_open,
            .is_enum = c.is_enum,
        }) catch {};
    }
    // Return heads ride the baked index, since a cached load's funcs are lazy; the
    // run that builds the base derives them from the funcs. Both publish the same.
    var rets = std.StringHashMap([]const u8).init(gpa);
    if (sb.fn_returns.len != 0) {
        for (sb.fn_returns) |fr| {
            if (ambiguous_names.contains(fr.head)) continue;
            rets.put(fr.name, fr.head) catch {};
        }
    } else {
        var ambiguous = std.StringHashMap(void).init(gpa);
        defer ambiguous.deinit();
        for (m.funcs.items) |*f| {
            if (f.kind != .plain) continue;
            if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
            const head = headOf(f.return_ty.name);
            if (head.len == 0 or !classes.contains(head)) continue;
            if (ambiguous.contains(f.name)) continue;
            const gop = rets.getOrPut(f.name) catch continue;
            if (gop.found_existing) {
                if (!std.mem.eql(u8, gop.value_ptr.*, head)) {
                    _ = rets.remove(f.name);
                    ambiguous.put(f.name, {}) catch {};
                }
            } else gop.value_ptr.* = head;
        }
    }
    // Extensions keyed by the receiver's class head, and receiver-less
    // top-level functions by name, from the name index and the declaration
    // signatures: on a cached image the funcs are lazy and `m.funcs.items` is
    // empty, while the index and signatures are eager.
    var exts = std.StringHashMap(std.ArrayList(types_mod.ExternFn)).init(gpa);
    var tops = std.StringHashMap(std.ArrayList(types_mod.ExternFn)).init(gpa);
    var nit = m.func_name_index.iterator();
    while (nit.next()) |entry| {
        const fname = entry.key_ptr.*;
        if (fname.len == 0) continue;
        for (entry.value_ptr.items) |fid| {
            const sig = m.decl_sigs.get(fid.int()) orelse continue;
            if (sig.receiver_ty) |recv| {
                var recv_head = headOf(recv.name);
                if (recv_head.len == 0 or ambiguous_names.contains(recv_head)) continue;
                const ef = externFnOf(gpa, m, fname, fid.int(), &sig) orelse continue;
                // `fun <T> T.also(...)` receives anything: it is an extension
                // on `Any`, the key every receiver's candidate walk reaches.
                for (ef.type_params) |tp| {
                    if (std.mem.eql(u8, tp, recv_head)) recv_head = "Any";
                }
                const gop = exts.getOrPut(recv_head) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(gpa, ef) catch {};
            } else if (sig.kind == .plain and sig.enclosing_class == null) {
                const ef = externFnOf(gpa, m, fname, fid.int(), &sig) orelse continue;
                const gop = tops.getOrPut(fname) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(gpa, ef) catch {};
            }
        }
    }
    if (runtime.envOnce("KLIO_EAGER_AUDIT") != null) {
        var n_ext: usize = 0;
        var eit = exts.valueIterator();
        while (eit.next()) |l| n_ext += l.items.len;
        var n_top: usize = 0;
        var tit = tops.valueIterator();
        while (tit.next()) |l| n_top += l.items.len;
        var n_members: usize = 0;
        var n_props: usize = 0;
        var cit = classes.valueIterator();
        while (cit.next()) |c| {
            n_members += c.methods.len;
            n_props += c.props.len;
        }
        std.debug.print("[EAGER-EXTERN] published classes={d} members={d} props={d} fn_returns={d} ext_recvs={d} exts={d} top_level={d} (module funcs={d})\n", .{ classes.count(), n_members, n_props, rets.count(), exts.count(), n_ext, n_top, m.funcs.items.len });
        var ait = ambiguous_names.keyIterator();
        var n_amb: usize = 0;
        while (ait.next()) |k| : (n_amb += 1) {
            if (n_amb < 40) std.debug.print("[EAGER-EXTERN] ambiguous {s}\n", .{k.*});
        }
        std.debug.print("[EAGER-EXTERN] ambiguous total={d}\n", .{n_amb});
    }
    var roots = std.StringHashMap(void).init(gpa);
    {
        var fi: u32 = 0;
        while (fi < m.funcCount()) : (fi += 1) {
            const f = m.funcById(ir_mod.FuncId.from(fi)) orelse continue;
            if (packageRootOf(f.package)) |r| roots.put(r, {}) catch {};
        }
        for (m.classes.items) |*c| {
            if (packageRootOf(c.package)) |r| roots.put(r, {}) catch {};
        }
    }
    types_mod.pending_extern_decls = .{
        .classes = classes,
        .fn_return_class = rets,
        .extensions = exts,
        .top_level = tops,
        .has_extensions = true,
        .package_roots = roots,
    };
}

/// The first segment of a dotted package, or null for the default package.
fn packageRootOf(pkg: []const u8) ?[]const u8 {
    if (pkg.len == 0) return null;
    const dot = std.mem.findScalar(u8, pkg, '.') orelse return pkg;
    return pkg[0..dot];
}

/// Assemble the program against a cached (or freshly baked) stdlib image. Null
/// means take the whole-program path.
pub fn tryPrepare(
    gpa: Allocator,
    paths: []const []const u8,
    features: *const RequestedFeatures,
) ?Prepared {
    if (disabled(gpa)) return null;
    const t0 = runtime.clockMonotonicNanos();
    // The library these sources are must stay out of the base. Its installed
    // pack declares the same `main` they do, and a base that declares one is
    // not snapshot-safe, which would disable the image for every later run.
    const own_library = project.ownLibraryExclusion(gpa, paths);
    const cache = cacheDir(gpa) orelse return null;
    const exe = exeStamp(gpa) orelse return null;
    const stdlib_hash = stdlibContentHash(gpa) orelse return null;
    const t_hash = runtime.clockMonotonicNanos();

    var scratch_map = SourceMap.init(gpa);
    const user = parseUserFiles(gpa, &scratch_map, paths, null) orelse return null;

    // Without imports or a package-rooted qualified reference nothing can match a
    // pack's library id, so the cache walk over every pack file is skipped.
    var qref_prefixes = pack_cache.collectQualifiedRefPrefixes(gpa, user.asts) catch
        std.StringHashMap(void).init(gpa);
    defer {
        var it = qref_prefixes.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        qref_prefixes.deinit();
    }
    var selection = pack_cache.Selection{};
    var any_refs = qref_prefixes.count() != 0;
    for (user.asts) |f| {
        if (f.imports.len != 0) any_refs = true;
    }
    // Packs are parsed only for their bindings and selection identity; the image
    // already holds their lowered form. Their ASTs land in a scratch arena dropped
    // before the program runs, leaving only bindings and selection alive.
    var pack_arena = std.heap.ArenaAllocator.init(gpa);
    defer pack_arena.deinit();
    const paa = pack_arena.allocator();
    var packs_map = SourceMap.init(paa);
    const pack_bindings = if (any_refs) blk: {
        var sel_tmp = pack_cache.Selection{};
        const tmp = pack_cache.loadInstalledPacksOpts(paa, user.asts, &packs_map, features, .{
            .include_stdlib = false,
            .selection = &sel_tmp,
            .report_failures = false,
            .asts_needed = false,
            .exclude_lib_ids = own_library,
            .declared_lib_ids = project.declaredDependencyIds(gpa, paths),
        }).bindings;
        for (sel_tmp.packs.items) |p| {
            const feats = gpa.alloc([]const u8, p.features.len) catch return null;
            for (p.features, 0..) |f, i| feats[i] = gpa.dupe(u8, f) catch return null;
            selection.packs.append(gpa, .{
                .path = gpa.dupe(u8, p.path) catch return null,
                .hash = p.hash,
                .features = feats,
            }) catch return null;
        }
        for (sel_tmp.final_prefixes.items) |pfx|
            selection.final_prefixes.append(gpa, gpa.dupe(u8, pfx) catch return null) catch return null;
        var out = HostBindings.init(gpa);
        var it = tmp.table.iterator();
        while (it.next()) |e| {
            const k = gpa.dupe(u8, e.key_ptr.*) catch continue;
            out.register(k, e.value_ptr.*) catch {};
        }
        break :blk out;
    } else pack_cache.mergedHostBindings(gpa);
    const t_packs = runtime.clockMonotonicNanos();

    const meta_file = metaPath(gpa, cache, stdlib_hash) orelse return null;
    var gate_full: ?bool = null;
    if (readMetaFromCaches(gpa, meta_file)) |meta| {
        var prefix_set = std.StringHashMap(void).init(gpa);
        defer prefix_set.deinit();
        for (selection.final_prefixes.items) |p| prefix_set.put(p, {}) catch return null;
        var qit = qref_prefixes.keyIterator();
        while (qit.next()) |k| prefix_set.put(k.*, {}) catch return null;
        var imported_match = false;
        for (meta.pkgs) |pkg| {
            if (pack_cache.importPrefixMatches(gpa, &prefix_set, pkg)) {
                imported_match = true;
                break;
            }
        }
        gate_full = imported_match or !meta.any_non_implicit;
    }

    if (gate_full) |gate| {
        const key = imageKey(stdlib_hash, exe, gate, selection.packs.items);
        const hex = keyHex(key);
        const image_path = std.fmt.allocPrint(gpa, "{s}/stdlib-{s}.klio-image", .{ cache, hex }) catch return null;
        if (loadImageFromCaches(gpa, image_path, hex)) |found| {
            const t_load = runtime.clockMonotonicNanos();
            const out = finishFromLoaded(gpa, found.loaded, user, paths, pack_bindings);
            // A null `out` means the extend gate refused; not a served hit.
            trace(gpa, "{s}{s} {s} (key {d}ms, packs {d}ms, load {d}ms, extend {d}ms)", .{
                if (out != null) @as([]const u8, "hit") else "hit-but-fallback",
                if (found.shipped) @as([]const u8, " (shipped)") else "",
                hex,
                (t_hash - t0) / 1_000_000,
                (t_packs - t_hash) / 1_000_000,
                (t_load - t_packs) / 1_000_000,
                (runtime.clockMonotonicNanos() - t_load) / 1_000_000,
            });
            return out;
        }
        if (tombstoneExists(gpa, cache, hex)) {
            trace(gpa, "unbakeable {s}", .{hex});
            return null;
        }
        tracePreBake(gpa, t0, t_hash, t_packs);
        return bakeAndPrepare(gpa, cache, meta_file, false, gate, user, paths, features, pack_bindings);
    }

    // No meta yet: the full load computes the gate and the key follows from it.
    tracePreBake(gpa, t0, t_hash, t_packs);
    return bakeAndPrepare(gpa, cache, meta_file, true, null, user, paths, features, pack_bindings);
}

fn tracePreBake(gpa: Allocator, t0: u64, t_hash: u64, t_packs: u64) void {
    runtime.prof.phaseMark("before bake");
    trace(gpa, "  before bake: key {d}ms, user+packs {d}ms, meta {d}ms", .{
        (t_hash - t0) / 1_000_000,
        (t_packs - t_hash) / 1_000_000,
        (runtime.clockMonotonicNanos() - t_packs) / 1_000_000,
    });
}

fn tombstoneExists(gpa: Allocator, cache: []const u8, hex: [32]u8) bool {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const path = std.fmt.allocPrint(gpa, "{s}/stdlib-{s}.unbakeable", .{ cache, hex }) catch return false;
    defer gpa.free(path);
    _ = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return false;
    return true;
}

fn bakeMarkerPath(gpa: Allocator, image_path: []const u8) ?[]u8 {
    return std.fmt.allocPrint(gpa, "{s}.baking", .{image_path}) catch null;
}

fn writeBakeMarker(gpa: Allocator, cache: []const u8, image_path: []const u8) void {
    const path = bakeMarkerPath(gpa, image_path) orelse return;
    defer gpa.free(path);
    writeAtomic(gpa, cache, path, "baking");
}

fn clearBakeMarker(gpa: Allocator, image_path: []const u8) void {
    const path = bakeMarkerPath(gpa, image_path) orelse return;
    defer gpa.free(path);
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    std.Io.Dir.cwd().deleteFile(threaded.io(), path) catch {};
}

/// True, and the marker cleared, when a background bake of this image was
/// started and never finished.
fn takeAbandonedBake(gpa: Allocator, image_path: []const u8) bool {
    const path = bakeMarkerPath(gpa, image_path) orelse return false;
    defer gpa.free(path);
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    _ = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return false;
    std.Io.Dir.cwd().deleteFile(threaded.io(), path) catch {};
    return true;
}

fn writeTombstone(gpa: Allocator, cache: []const u8, hex: [32]u8) void {
    const path = std.fmt.allocPrint(gpa, "{s}/stdlib-{s}.unbakeable", .{ cache, hex }) catch return;
    defer gpa.free(path);
    writeAtomic(gpa, cache, path, "unbakeable");
}

/// Read + decode an image file. Null on any mismatch (the caller rebakes).
fn loadImageFile(gpa: Allocator, path: []const u8) ?image.Loaded {
    // The decoded base borrows these bytes for the process's life, so the mmap is
    // never unmapped; it also keeps the deferred sections file-backed, off RSS.
    const bytes = mmapImage(path) orelse blk: {
        var threaded = threadedIo(gpa);
        defer threaded.deinit();
        break :blk std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .unlimited) catch return null;
    };
    const loaded = image.load(gpa, bytes) catch null;
    if (loaded == null) trace(gpa, "image rejected: {s}", .{image.lastLoadFailure()});
    return loaded;
}

fn mmapImage(path: []const u8) ?[]const u8 {
    if (path.len >= 4095) return null;
    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end <= 0) return null;
    _ = std.c.lseek(fd, 0, std.c.SEEK.SET);
    const len: usize = @intCast(end);
    const mapped = std.posix.mmap(
        null,
        len,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return null;
    return mapped[0..len];
}

fn finishFromLoaded(
    gpa: Allocator,
    loaded: image.Loaded,
    user: ParsedUser,
    paths: []const []const u8,
    bindings_in: HostBindings,
) ?Prepared {
    for (loaded.known_packages) |pkg| stdlib.registerKnownPackage(pkg);

    if (!interp_ir.build.canExtendBase(loaded.base, user.asts)) {
        trace(gpa, "fallback (base name collision)", .{});
        return null;
    }

    // Re-parse onto a map extending the base's, so base spans stay resolvable.
    const map = gpa.create(SourceMap) catch return null;
    map.* = SourceMap.init(gpa);
    map.files.appendSlice(map.arena.allocator(), loaded.map.files.items) catch return null;
    const user2 = parseUserFiles(gpa, map, paths, user.texts) orelse return null;

    const te0 = runtime.clockMonotonicNanos();
    publishExternDecls(gpa, loaded.base);
    runtime.prof.phaseMark("extend extern");
    const te_extern = runtime.clockMonotonicNanos();
    ir_mod.discardPendingPicks();
    publishBaseEagerCalls(gpa, loaded.base);
    runtime.prof.phaseMark("extend eager");
    const te_eager = runtime.clockMonotonicNanos();
    if (@import("commands.zig").eagerCallsOn()) {
        if (@import("commands.zig").computeEagerCalls(gpa, user2.asts, &.{})) |ec| ir_mod.pending_eager_calls = ec;
    }
    runtime.prof.phaseMark("extend user-check");
    const te_user_check = runtime.clockMonotonicNanos();
    span.active_map = map;
    span.dumpFileIds(map);
    // Loaded for this run alone: nothing reads the base after this.
    const built = interp_ir.build.buildModuleFilesExtendOwned(gpa, loaded.base, user2.asts) catch return null;
    runtime.prof.phaseMark("extend build");
    trace(gpa, "  extend: extern {d}ms, eager {d}ms, user-check {d}ms, build {d}ms", .{
        (te_extern - te0) / 1_000_000,
        (te_eager - te_extern) / 1_000_000,
        (te_user_check - te_eager) / 1_000_000,
        (runtime.clockMonotonicNanos() - te_user_check) / 1_000_000,
    });

    var bindings = bindings_in;
    for (loaded.binding_fqns) |fqn| {
        if (bindings.resolve(fqn)) |f| bindings.register(fqn, f) catch {};
    }

    return .{ .built = built, .map = map, .bindings = bindings, .user_asts = user2.asts };
}

/// The stdlib image a pack program builds on, materialised.
const StdlibLayer = struct {
    loaded: image.Loaded,
    any_non_implicit: bool,
    /// The image's file count: the stdlib's sources, first in its map.
    stdlib_files: usize,
};

/// The stdlib's own image for `gate`, from the cache or the build's copy,
/// brought wholly into memory so packs can lower on top of it. Null when
/// there is none, when the program pulls no pack in, or when the layered
/// build is switched off.
fn loadStdlibLayer(gpa: Allocator, cache: []const u8, stdlib_hash: [32]u8, exe: [2]u64, gate: bool, user: ParsedUser) ?StdlibLayer {
    // Opt-in: the layered build lowers only the packs on the stdlib image, but
    // a global call inside a pack member resolves dynamically over the layer
    // where the whole-program build resolves it statically, and a pack `actual`
    // does not yet supersede the stdlib's `expect` across the image boundary.
    // Both are the same gap a program-over-image run has today; closing it
    // makes the layer exact. `KLIO_STDLIB_IMAGE_LAYER=1` turns it on.
    if (!std.mem.eql(u8, runtime.envOnce("KLIO_STDLIB_IMAGE_LAYER") orelse "0", "1")) return null;
    var any_import = false;
    for (user.asts) |f| {
        if (f.imports.len != 0) any_import = true;
    }
    if (!any_import) return null;
    const meta_file = metaPath(gpa, cache, stdlib_hash) orelse return null;
    defer gpa.free(meta_file);
    const meta = readMetaFromCaches(gpa, meta_file) orelse {
        trace(gpa, "  stdlib layer: no meta", .{});
        return null;
    };
    const key = imageKey(stdlib_hash, exe, gate, &.{});
    const hex = keyHex(key);
    const image_path = std.fmt.allocPrint(gpa, "{s}/stdlib-{s}.klio-image", .{ cache, hex }) catch return null;
    defer gpa.free(image_path);
    const t0 = runtime.clockMonotonicNanos();
    const found = loadImageFromCaches(gpa, image_path, hex) orelse {
        trace(gpa, "  stdlib layer: no image {s} for gate:{s}", .{ hex, if (gate) @as([]const u8, "full") else "implicit" });
        return null;
    };
    const t_load = runtime.clockMonotonicNanos();
    const ok = image.materialize(gpa, found.loaded.base) catch return null;
    if (!ok) {
        trace(gpa, "stdlib layer {s} did not materialise; lowering from source", .{hex});
        return null;
    }
    trace(gpa, "  stdlib layer {s}{s}: load {d}ms, materialise {d}ms", .{
        hex,
        if (found.shipped) @as([]const u8, " (shipped)") else "",
        (t_load - t0) / 1_000_000,
        (runtime.clockMonotonicNanos() - t_load) / 1_000_000,
    });
    return .{ .loaded = found.loaded, .any_non_implicit = meta.any_non_implicit, .stdlib_files = found.loaded.map.files.items.len };
}

/// Cold path: load, lower, bake and publish the image and its meta sidecar,
/// then run from the image exactly as the next run will.
///
/// The parse, the stage, the lowered base and the bake's own turnover all
/// live on the build heap, which is dropped whole once the image bytes
/// exist: nothing the program runs on points into it. What the run needs is
/// decoded from those bytes on demand, so a cold run holds what a warm one
/// holds, plus the bytes.
fn bakeAndPrepare(
    gpa: Allocator,
    cache: []const u8,
    meta_file: []const u8,
    write_meta_file: bool,
    gate: ?bool,
    user: ParsedUser,
    paths: []const []const u8,
    features: *const RequestedFeatures,
    bindings: HostBindings,
) ?Prepared {
    const exe = exeStamp(gpa) orelse return null;
    const stdlib_hash = stdlibContentHash(gpa) orelse return null;

    const heap = runtime.slab.buildHeap();
    const ba = heap.allocator();
    var heap_released = false;
    defer if (!heap_released) dropBuildHeap(heap);

    const tb0 = runtime.clockMonotonicNanos();
    // A program that pulls packs in builds on the stdlib image when one is
    // at hand for its gate: the stdlib's own parse, stage and lowering are
    // then not repeated, and only the packs lower. `KLIO_STDLIB_IMAGE_LAYER=0`
    // lowers everything from source, the reference for the layered build.
    const layer = if (gate) |g| loadStdlibLayer(gpa, cache, stdlib_hash, exe, g, user) else null;
    // Over a layer the packs register after the image's files, and the stdlib
    // parses for the stage alone onto a scratch map whose ids are the image's,
    // so the stage checks the whole universe as a fresh build does and its
    // picks name declarations the lowering on top can find.
    const dep_map: *SourceMap = if (layer) |l| l.loaded.map else blk: {
        const m = ba.create(SourceMap) catch return null;
        m.* = SourceMap.init(ba);
        break :blk m;
    };
    var stage_map = SourceMap.init(ba);
    var report = pack_cache.EmbeddedReport{};
    var selection = pack_cache.Selection{};
    const deps = pack_cache.loadInstalledPacksOpts(ba, user.asts, dep_map, features, .{
        .stdlib_map = if (layer != null) &stage_map else null,
        .embedded_report = &report,
        .selection = &selection,
        .exclude_lib_ids = project.ownLibraryExclusion(ba, paths),
        .declared_lib_ids = project.declaredDependencyIds(ba, paths),
    });
    runtime.prof.phaseMark("parse");
    const tb_parse = runtime.clockMonotonicNanos();
    {
        const t = report.timing;
        const staged = t.sources + t.register + t.lex_parse_wall;
        trace(gpa, "  parse: sources {d}ms, register {d}ms, lex+parse {d}ms wall ({d} files on {d} threads, {d} pieces; lex {d}ms, parse {d}ms summed; longest {d}ms for {d} bytes), stdlib-other {d}ms, packs {d}ms", .{
            t.sources / 1_000_000,
            t.register / 1_000_000,
            t.lex_parse_wall / 1_000_000,
            t.files,
            t.threads,
            t.pieces,
            t.lex / 1_000_000,
            t.parse / 1_000_000,
            t.longest / 1_000_000,
            t.longest_bytes,
            (t.total -| staged) / 1_000_000,
            ((tb_parse - tb0) -| t.total) / 1_000_000,
        });
    }

    const key = imageKey(stdlib_hash, exe, report.gate_full, selection.packs.items);
    const hex = keyHex(key);
    const image_path = std.fmt.allocPrint(gpa, "{s}/stdlib-{s}.klio-image", .{ cache, hex }) catch return null;
    defer gpa.free(image_path);

    if (write_meta_file) {
        writeMeta(gpa, cache, meta_file, .{
            .pkgs = report.pkgs.items,
            .any_non_implicit = report.any_non_implicit,
        });
        // The gate was unknown here, so an image for the now-known key may exist.
        if (loadImageFromCaches(gpa, image_path, hex)) |found| {
            trace(gpa, "hit{s} {s}", .{ if (found.shipped) @as([]const u8, " (shipped)") else "", hex });
            return finishFromLoaded(gpa, found.loaded, user, paths, bindings);
        }
        if (tombstoneExists(gpa, cache, hex)) return null;
    }

    if (takeAbandonedBake(gpa, image_path)) trace(gpa, "the previous bake of {s} did not finish; baking again", .{hex});
    const tb_stage = runtime.clockMonotonicNanos();
    // The build runs the stage on a thread beside its table passes.
    var stage_ctx = StageCtx{ .gpa = ba };
    interp_ir.build.setStageJob(.{ .ctx = @ptrCast(&stage_ctx), .run = stageJobRun });
    // Lazy bodies: the build runs the program before its bodies lower.
    var lazy_run = LazyRun{
        .gpa = gpa,
        .known_packages = report.known_packages.items,
        .binding_fqns = report.binding_fqns.items,
        .dep_map = dep_map,
        .user = user,
        .paths = paths,
        .bindings = bindings,
    };
    const lazy_plan: ?*interp_ir.build.lazy.Plan = if (runtime.lazy_bodies)
        interp_ir.build.lazy.arm(ba, .{ .ctx = @ptrCast(&lazy_run), .run = lazyRunProgram }) catch null
    else
        null;
    // The loader lists the packs' ASTs first and the stdlib's last; over a
    // layer only the packs lower, and the stage's stdlib files must be the
    // image's, in the same order, for its picks to name what the lowering
    // finds.
    const base = (if (layer) |l| blk: {
        if (stage_map.files.items.len != l.stdlib_files or report.stdlib_asts > deps.asts.len) {
            trace(gpa, "stdlib layer: the image holds {d} stdlib files, this build {d}; lowering from source", .{ l.stdlib_files, stage_map.files.items.len });
            break :blk null;
        }
        break :blk interp_ir.build.buildStdlibBaseOnTop(ba, l.loaded.base, deps.asts[0 .. deps.asts.len - report.stdlib_asts]) catch return null;
    } else interp_ir.build.buildStdlibBaseUnstripped(ba, deps.asts) catch return null) orelse
    {
        writeTombstone(gpa, cache, hex);
        trace(gpa, "unbakeable {s} (base not snapshot-safe)", .{hex});
        return null;
    };
    base.user_file_start = @intCast(dep_map.files.items.len);
    // A build that never reached its fork point leaves the stage to run here.
    if (interp_ir.build.takeStageJob()) |job| job.run(job.ctx, deps.asts);

    // The only run where the base's sources exist; the results ride the image.
    checkBaseSources(ba, base, deps.asts);
    // Dead bodies are blanked so the bake skips them; the heap frees them.
    interp_ir.build.stripStdlibBaseKeep(base);
    const tb_build = runtime.clockMonotonicNanos();
    trace(gpa, "  lower: build {d}ms with the stage beside it", .{(tb_build - tb_stage) / 1_000_000});

    // The marker outlives a process that dies before the image lands, so the
    // next cold run says so rather than staying cold in silence.
    writeBakeMarker(gpa, cache, image_path);
    const bytes = (image.bake(gpa, ba, base, dep_map, .{
        .known_packages = report.known_packages.items,
        .binding_fqns = report.binding_fqns.items,
    }) catch return null) orelse {
        clearBakeMarker(gpa, image_path);
        writeTombstone(gpa, cache, hex);
        trace(gpa, "unbakeable {s} (outside serializable surface)", .{hex});
        return null;
    };
    runtime.prof.phaseMark("bake finish");
    const tb_bake = runtime.clockMonotonicNanos();
    publishImage(gpa, cache, image_path, bytes);
    trace(gpa, "baked {s} ({d} bytes, {d} inline forest nodes; parse {d}ms, lower {d}ms, bake {d}ms)", .{
        hex,
        bytes.len,
        interp_ir.image.inline_forest_nodes,
        (tb_parse - tb0) / 1_000_000,
        (tb_build - tb_stage) / 1_000_000,
        (tb_bake - tb_build) / 1_000_000,
    });

    // From here the run is a warm one over the bytes just baked. A rejected
    // image is a bug in the bake; the caller's from-source path still runs
    // the program.
    if (lazy_plan) |lp| {
        // The program ran inside the build; the image, baked from the base
        // the pools completed after it, is being written. The build stays
        // resident until exit, as the run module points into it.
        const ran = lazy_run.prepared orelse return null;
        trace(gpa, "  lazy bodies: exit {d}; the image was baked after the run", .{lp.exit_code orelse 1});
        return .{ .built = ran.built, .map = ran.map, .bindings = ran.bindings, .user_asts = ran.user_asts, .ran = lp.exit_code orelse 1 };
    }
    const loaded = (image.load(gpa, bytes) catch null) orelse {
        trace(gpa, "the baked image does not load: {s}", .{image.lastLoadFailure()});
        return null;
    };
    runtime.prof.phaseMark("load");
    const tb_load = runtime.clockMonotonicNanos();
    const heap_bytes = heap.mapped.load(.monotonic);
    dropBuildHeap(heap);
    heap_released = true;
    runtime.prof.phaseMark("drop build heap");
    const tb_drop = runtime.clockMonotonicNanos();
    trace(gpa, "  dropped the build heap: {d}mb in {d}us", .{ heap_bytes / (1024 * 1024), (tb_drop - tb_load) / 1000 });
    const out = finishFromLoaded(gpa, loaded, user, paths, bindings);
    trace(gpa, "  after bake: load {d}ms, drop {d}ms, extend {d}ms", .{
        (tb_load - tb_bake) / 1_000_000,
        (tb_drop - tb_load) / 1_000_000,
        (runtime.clockMonotonicNanos() - tb_drop) / 1_000_000,
    });
    return out;
}

/// Unmaps the build heap. The stage's picks point into it, and the run
/// publishes its own from the image.
fn dropBuildHeap(heap: *runtime.slab.Heap) void {
    if (ir_mod.pending_eager_calls) |*old| old.deinit();
    ir_mod.pending_eager_calls = null;
    runtime.slab.releaseAll(heap);
}

/// `klio bake-image --stdlib-cache <dir>`: bake the stdlib-only images, keyed
/// as this binary keys them, into `dir` as a cache the runtime reads when its
/// own misses. The build runs it on the freshly built binary and installs the
/// directory beside it, so a rebuilt klio's first run is not a cold one. Two
/// images, one per gate: the implicit one an import-free program looks up, and
/// the full one a program with a stdlib import looks up, which is also what a
/// program that pulls packs in builds its own base on.
///
/// Each image bakes in a child process (`--probe <name>` is the child's
/// spelling). A bake leaves state behind that a second bake in the same
/// process lowers differently: the second image diverged from a runtime bake
/// of its own key by six megabytes and dispatched a delegated read to the
/// wrong function, while the first matched byte for byte. The runtime bakes
/// one image per process, so only a fresh process reproduces its image.
pub fn bakeStdlibCache(
    gpa: Allocator,
    dir: []const u8,
    features: *const RequestedFeatures,
    self_exe: []const u8,
    only_probe: ?[]const u8,
) u8 {
    const probes = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "probe.kt", .source = "fun main() {}\n" },
        .{ .name = "probe_full.kt", .source = "import kotlin.math.abs\nfun main() { abs(1) }\n" },
    };
    if (only_probe) |want| {
        for (&probes) |pr| {
            if (std.mem.eql(u8, pr.name, want)) return bakeStdlibProbe(gpa, dir, features, pr.name, pr.source);
        }
        io.printStderr(gpa, "error: unknown stdlib-cache probe `{s}`\n", .{want});
        return 1;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const rio = threaded.io();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    runtime.procEnvPutAllInto(gpa, &env);

    for (&probes) |pr| {
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(a, &.{ self_exe, "bake-image", "--stdlib-cache", dir, "--probe", pr.name }) catch return 1;
        var lib_it = features.iterator();
        while (lib_it.next()) |entry| {
            var feat_it = entry.value_ptr.keyIterator();
            while (feat_it.next()) |feat| {
                argv.append(a, "--feature") catch return 1;
                argv.append(a, std.fmt.allocPrint(a, "{s}/{s}", .{ entry.key_ptr.*, feat.* }) catch return 1) catch return 1;
            }
        }
        const res = std.process.run(gpa, rio, .{ .argv = argv.items, .environ_map = &env }) catch |e| {
            io.printStderr(gpa, "error: the stdlib image bake for {s} could not start: {s}\n", .{ pr.name, @errorName(e) });
            return 1;
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        if (res.stderr.len != 0) io.writeStderr(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) {
                io.printStderr(gpa, "error: the stdlib image bake for {s} exited with {d}\n", .{ pr.name, code });
                return 1;
            },
            else => {
                io.printStderr(gpa, "error: the stdlib image bake for {s} died\n", .{pr.name});
                return 1;
            },
        }
    }
    return 0;
}

/// One probe's bake into `dir`, in this process: the child half of
/// `bakeStdlibCache`.
fn bakeStdlibProbe(gpa: Allocator, dir: []const u8, features: *const RequestedFeatures, name: []const u8, source: []const u8) u8 {
    cache_dir_override = dir;
    defer cache_dir_override = null;
    const cache = cacheDir(gpa) orelse {
        io.printStderr(gpa, "error: cannot create {s}\n", .{dir});
        return 1;
    };
    defer gpa.free(cache);
    const probe = std.fs.path.join(gpa, &.{ cache, name }) catch return 1;
    defer gpa.free(probe);
    writeAtomic(gpa, cache, probe, source);
    defer {
        var threaded = threadedIo(gpa);
        defer threaded.deinit();
        std.Io.Dir.cwd().deleteFile(threaded.io(), probe) catch {};
    }
    const prepared = tryPrepare(gpa, &.{probe}, features);
    finishBackgroundBake();
    if (prepared == null) {
        io.printStderr(gpa, "error: the stdlib image did not bake into {s}\n", .{dir});
        return 1;
    }
    return 0;
}

/// One dependency load for `klio bundle`. Lowering mutates the ASTs and baking
/// strips dead bodies, so each bake attempt needs its own load.
pub const BundleDeps = struct {
    asts: []const KotlinFile,
    map: *SourceMap,
    bindings: HostBindings,
};

pub fn bundleDepLoad(
    gpa: Allocator,
    user_asts: []const KotlinFile,
    features: *const RequestedFeatures,
    report: ?*pack_cache.EmbeddedReport,
    selection: ?*pack_cache.Selection,
) ?BundleDeps {
    const dep_map = gpa.create(SourceMap) catch return null;
    dep_map.* = SourceMap.init(gpa);
    const deps = pack_cache.loadInstalledPacksOpts(gpa, user_asts, dep_map, features, .{
        .embedded_report = report,
        .selection = selection,
    });
    return .{ .asts = deps.asts, .map = dep_map, .bindings = deps.bindings };
}

/// The image bytes to embed, plus the base and map for bundle-time verification.
pub const BundleBase = struct {
    bytes: []const u8,
    base: *interp_ir.build.StdlibBase,
    map: *const SourceMap,
};

/// Assemble the dependency base image for `klio bundle`, reusing a cache-keyed
/// image when one matches. `report`/`selection` key the cache.
pub fn bundleBaseImage(
    gpa: Allocator,
    deps: *const BundleDeps,
    report: *const pack_cache.EmbeddedReport,
    selection: *const pack_cache.Selection,
) ?BundleBase {
    const cache = if (disabled(gpa)) null else cacheDir(gpa);
    var image_path: ?[]u8 = null;
    if (cache) |c| blk: {
        const exe = exeStamp(gpa) orelse break :blk;
        const stdlib_hash = stdlibContentHash(gpa) orelse break :blk;
        const key = imageKey(stdlib_hash, exe, report.gate_full, selection.packs.items);
        const hex = keyHex(key);
        image_path = std.fmt.allocPrint(gpa, "{s}/stdlib-{s}.klio-image", .{ c, hex }) catch break :blk;
        var threaded = threadedIo(gpa);
        defer threaded.deinit();
        const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), image_path.?, gpa, .unlimited) catch break :blk;
        const loaded = (image.load(gpa, bytes) catch null) orelse break :blk;
        for (loaded.known_packages) |pkg| stdlib.registerKnownPackage(pkg);
        trace(gpa, "bundle reuses cached image {s}", .{hex});
        return .{ .bytes = bytes, .base = loaded.base, .map = loaded.map };
    }

    // Same bake-time staging and check as `bakeAndPrepare`, the other from-source path.
    var stage_ctx = StageCtx{ .gpa = gpa };
    interp_ir.build.setStageJob(.{ .ctx = @ptrCast(&stage_ctx), .run = stageJobRun });
    const base = (interp_ir.build.buildStdlibBase(gpa, deps.asts) catch return null) orelse return null;
    if (interp_ir.build.takeStageJob()) |job| job.run(job.ctx, deps.asts);
    base.user_file_start = @intCast(deps.map.files.items.len);
    checkBaseSources(gpa, base, deps.asts);
    const bytes = (image.bake(gpa, gpa, base, deps.map, .{
        .known_packages = report.known_packages.items,
        .binding_fqns = report.binding_fqns.items,
    }) catch return null) orelse return null;
    if (cache) |c| {
        if (image_path) |p| {
            writeAtomic(gpa, c, p, bytes);
            pruneImages(gpa, c);
        }
    }
    return .{ .bytes = bytes, .base = base, .map = deps.map };
}

/// `klio bake [files...]`: ensure the stdlib images the given programs need
/// exist. With no files, both stdlib gate variants are baked.
pub fn runBake(gpa: Allocator, paths: []const []const u8, features: *const RequestedFeatures) u8 {
    if (disabled(gpa)) {
        io.writeStderr("error: the stdlib image cache is disabled (KLIO_STDLIB_IMAGE=0 or KLIO_PACK_DIAG set)\n");
        return 2;
    }
    if (paths.len != 0) {
        return bakeForPrograms(gpa, paths, features);
    }
    const cache = cacheDir(gpa) orelse {
        io.writeStderr("error: cannot resolve ~/.klio/cache\n");
        return 1;
    };
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    const implicit_path = std.fmt.allocPrint(gpa, "{s}/.bake-implicit.kt", .{cache}) catch return 1;
    const full_path = std.fmt.allocPrint(gpa, "{s}/.bake-full.kt", .{cache}) catch return 1;
    std.Io.Dir.cwd().writeFile(fio, .{ .sub_path = implicit_path, .data = "fun main() {}\n" }) catch return 1;
    std.Io.Dir.cwd().writeFile(fio, .{
        .sub_path = full_path,
        .data = "import kotlin.time.Duration\nfun main() {}\n",
    }) catch return 1;
    defer {
        std.Io.Dir.cwd().deleteFile(fio, implicit_path) catch {};
        std.Io.Dir.cwd().deleteFile(fio, full_path) catch {};
    }
    var rc = bakeForPrograms(gpa, &.{implicit_path}, features);
    const rc2 = bakeForPrograms(gpa, &.{full_path}, features);
    if (rc == 0) rc = rc2;
    return rc;
}

fn bakeForPrograms(gpa: Allocator, paths: []const []const u8, features: *const RequestedFeatures) u8 {
    const prepared = tryPrepare(gpa, paths, features) orelse {
        io.writeStderr("error: could not bake a stdlib image for this configuration\n");
        return 1;
    };
    var built = prepared.built;
    built.deinit();
    io.writeStdout("stdlib image ready\n");
    return 0;
}

test {
    std.testing.refAllDecls(@This());
}
