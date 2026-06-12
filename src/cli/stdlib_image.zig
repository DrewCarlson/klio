//! Stdlib image cache for the CLI: bake the lowered dependency base
//! (embedded stdlib sources plus any selected packs) to
//! `~/.klio/cache/stdlib-<key>.klio-image` once, then load + extend it per
//! run instead of re-parsing and re-lowering ~4500 declarations.
//!
//! Keying — the image is addressed by a Blake3 over every input the bake
//! consumed:
//!   - the image format version and the `klio` executable's own identity
//!     (size + mtime of /proc/self/exe — any rebuild of the interpreter
//!     invalidates every image),
//!   - the content of every stdlib source the pack builder reads (the
//!     curated upstream files + the klio actuals, or the `KLIO_STDLIB_PACK`
//!     override pack bytes),
//!   - the stdlib load gate (implicit-only vs full curated set),
//!   - each selected pack's stored content hash + resolved feature set.
//! A stale or missing image is rebaked transparently; a key mismatch can
//! never serve stale lowered code.
//!
//! The fast path mirrors `loadInstalledPacks` exactly: cache packs still
//! load per run (their parse is cheap and produces the bindings, feature
//! hints, and known-package registrations); only the embedded stdlib
//! sources — and ALL dependency lowering — come from the image. Programs
//! that fail the `canExtendBase` gate (redeclaring a base name, declaring
//! expect/actual, sharing a base package) fall back to the legacy
//! whole-program build, byte-identically.
//!
//! Set `KLIO_STDLIB_IMAGE=0` to disable the cache; `KLIO_PACK_DIAG` also
//! disables it (the diagnostic prints come from the legacy loader).
//! `KLIO_TRACE_STDLIB_IMAGE=1` prints one hit/bake/fallback line per run.

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
const image = interp_ir.image;
const StdlibBase = interp_ir.build.StdlibBase;
const BuiltModule = interp_ir.build.BuiltModule;

const runtime = @import("runtime");
const stdlib = @import("stdlib");
const HostBindings = stdlib.HostBindings;

const io = @import("io.zig");
const pack_cache = @import("pack_cache.zig");
const RequestedFeatures = pack_cache.RequestedFeatures;

/// Keep this many images; older ones (by mtime) are pruned after a bake.
const KEEP_IMAGES = 6;

/// A program assembled against the image (or freshly baked) base: the
/// extended module, the map its spans resolve through, and the bindings
/// to install. Everything lives on the caller's process-lifetime arena.
pub const Prepared = struct {
    built: BuiltModule,
    map: *const SourceMap,
    bindings: HostBindings,
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
    io.printStderr(gpa, "[stdlib-image] " ++ fmt ++ "\n", args);
}

fn disabled(gpa: Allocator) bool {
    if (builtin.os.tag != .linux) return true;
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

// ---------------------------------------------------------------------
// Key ingredients
// ---------------------------------------------------------------------

/// `~/.klio/cache`, created if absent. Caller frees.
fn cacheDir(gpa: Allocator) ?[]u8 {
    const home = getEnvVar(gpa, "HOME") orelse return null;
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

/// Size + mtime of the running executable: any rebuild of the interpreter
/// invalidates every baked image.
fn exeStamp(gpa: Allocator) ?[2]u64 {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const st = std.Io.Dir.cwd().statFile(threaded.io(), "/proc/self/exe", .{}) catch return null;
    const mtime_ns: u64 = @truncate(@as(u128, @bitCast(@as(i128, st.mtime.nanoseconds))));
    return .{ st.size, mtime_ns };
}

/// Content hash of every stdlib source the bake consumes: the
/// `KLIO_STDLIB_PACK` override pack when set, else the curated upstream
/// files + klio actuals the embedded pack builder reads. Null when any
/// input is unreadable (then there is nothing to bake either).
fn stdlibContentHash(gpa: Allocator) ?[32]u8 {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    const cwd = std.Io.Dir.cwd();

    var hasher = std.crypto.hash.Blake3.init(.{});

    if (getEnvVar(gpa, "KLIO_STDLIB_PACK")) |override_path| {
        defer gpa.free(override_path);
        const bytes = cwd.readFileAlloc(fio, override_path, gpa, .unlimited) catch return null;
        defer gpa.free(bytes);
        hasher.update("override:");
        hasher.update(override_path);
        hasher.update(bytes);
    } else {
        const pb = stdlib.pack_builder;
        var upstream = cwd.openDir(fio, pb.UPSTREAM_STDLIB_ROOT, .{}) catch return null;
        defer upstream.close(fio);
        for (pb.CURATED_UPSTREAM_SOURCES) |rel| {
            const bytes = upstream.readFileAlloc(fio, rel, gpa, .unlimited) catch return null;
            defer gpa.free(bytes);
            hasher.update(rel);
            hasher.update(":");
            var len_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_buf, bytes.len, .little);
            hasher.update(&len_buf);
            hasher.update(bytes);
        }
        var klio_dir = cwd.openDir(fio, pb.KLIO_STDLIB_DIR, .{}) catch return null;
        defer klio_dir.close(fio);
        for (pb.KLIO_STDLIB_ACTUAL_FILES) |rel| {
            const bytes = klio_dir.readFileAlloc(fio, rel, gpa, .unlimited) catch return null;
            defer gpa.free(bytes);
            hasher.update(rel);
            hasher.update(":");
            var len_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_buf, bytes.len, .little);
            hasher.update(&len_buf);
            hasher.update(bytes);
        }
    }

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// The image cache key for one dependency configuration.
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
    // Order-independent fold over the selected packs: each pack's own
    // digest, XORed together (selection order is loader-internal).
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

// ---------------------------------------------------------------------
// Meta sidecar: the stdlib package universe, needed to compute the load
// gate on runs that skip the embedded source parse entirely.
// ---------------------------------------------------------------------

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

/// Write via a unique temp file + rename, so two racing processes can
/// never expose a partial file; the loser's rename simply wins last.
fn writeAtomic(gpa: Allocator, cache: []const u8, dest: []const u8, bytes: []const u8) void {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    const unique = runtime.clockMonotonicNanos() ^ (@as(u64, @intCast(std.os.linux.getpid())) << 32);
    const tmp = std.fmt.allocPrint(gpa, "{s}/.tmp-{x}", .{ cache, unique }) catch return;
    defer gpa.free(tmp);
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(fio, .{ .sub_path = tmp, .data = bytes }) catch return;
    cwd.rename(tmp, cwd, dest, fio) catch {
        cwd.deleteFile(fio, tmp) catch {};
    };
}

/// Delete all but the newest `KEEP_IMAGES` images (by mtime).
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

// ---------------------------------------------------------------------
// User-file parsing (scratch + final maps)
// ---------------------------------------------------------------------

const ParsedUser = struct {
    texts: [][]const u8,
    asts: []KotlinFile,
};

/// Parse the user files onto `map`. Null on any read/lex/parse failure —
/// the caller then takes the legacy path, which renders the diagnostics.
fn parseUserFiles(gpa: Allocator, map: *SourceMap, paths: []const []const u8, texts: ?[][]const u8) ?ParsedUser {
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
        const p = parser.Parser.new(gpa, fid, src, lexed.tokens);
        const file_ast = p.parseFile();
        if (p.diagnostics.hasErrors()) return null;
        out_asts[i] = file_ast;
    }
    return .{ .texts = out_texts, .asts = out_asts };
}

// ---------------------------------------------------------------------
// Fast path
// ---------------------------------------------------------------------

/// Try to assemble the program against a cached (or freshly baked) stdlib
/// image. Null means "take the legacy whole-program path" — because the
/// cache is disabled or unavailable, the user program fails to parse, the
/// program needs the fallback build, or the base is not bakeable.
pub fn tryPrepare(
    gpa: Allocator,
    paths: []const []const u8,
    features: *const RequestedFeatures,
) ?Prepared {
    if (disabled(gpa)) return null;
    const t0 = runtime.clockMonotonicNanos();
    const cache = cacheDir(gpa) orelse return null;
    const exe = exeStamp(gpa) orelse return null;
    const stdlib_hash = stdlibContentHash(gpa) orelse return null;
    const t_hash = runtime.clockMonotonicNanos();

    // Scratch parse: the reuse gate and the key need the program's decls
    // and imports before any base is chosen.
    var scratch_map = SourceMap.init(gpa);
    const user = parseUserFiles(gpa, &scratch_map, paths, null) orelse return null;

    // Cache packs load per run (bindings, hints, known packages, and the
    // selection identity); only the embedded stdlib comes from the image.
    // A program with no imports can never match a pack's library id, so
    // the cache walk (reading + verifying every pack file) is skipped and
    // the selection is the empty one the loader would compute.
    var selection = pack_cache.Selection{};
    var any_imports = false;
    for (user.asts) |f| {
        if (f.imports.len != 0) any_imports = true;
    }
    var packs_map = SourceMap.init(gpa);
    const pack_bindings = if (any_imports)
        pack_cache.loadInstalledPacksOpts(gpa, user.asts, &packs_map, features, .{
            .include_stdlib = false,
            .selection = &selection,
        }).bindings
    else
        pack_cache.mergedHostBindings(gpa);
    const t_packs = runtime.clockMonotonicNanos();

    // Load gate from the meta sidecar; missing meta means cold path.
    const meta_file = metaPath(gpa, cache, stdlib_hash) orelse return null;
    var gate_full: ?bool = null;
    if (readMeta(gpa, meta_file)) |meta| {
        var prefix_set = std.StringHashMap(void).init(gpa);
        defer prefix_set.deinit();
        for (selection.final_prefixes.items) |p| prefix_set.put(p, {}) catch return null;
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
        if (loadImageFile(gpa, image_path)) |loaded| {
            const t_load = runtime.clockMonotonicNanos();
            const out = finishFromLoaded(gpa, loaded, user, paths, pack_bindings);
            trace(gpa, "hit {s} (key {d}ms, packs {d}ms, load {d}ms, extend {d}ms)", .{
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
        return bakeAndPrepare(gpa, cache, meta_file, false, user, paths, features);
    }

    // No meta yet: cold path. The full load computes the gate; the key is
    // derived afterwards.
    return bakeAndPrepare(gpa, cache, meta_file, true, user, paths, features);
}

fn tombstoneExists(gpa: Allocator, cache: []const u8, hex: [32]u8) bool {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const path = std.fmt.allocPrint(gpa, "{s}/stdlib-{s}.unbakeable", .{ cache, hex }) catch return false;
    defer gpa.free(path);
    _ = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return false;
    return true;
}

fn writeTombstone(gpa: Allocator, cache: []const u8, hex: [32]u8) void {
    const path = std.fmt.allocPrint(gpa, "{s}/stdlib-{s}.unbakeable", .{ cache, hex }) catch return;
    defer gpa.free(path);
    writeAtomic(gpa, cache, path, "unbakeable");
}

/// Read + decode an image file. Null on any mismatch (the caller rebakes).
fn loadImageFile(gpa: Allocator, path: []const u8) ?image.Loaded {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    // The decoded base borrows from these bytes; they live on the
    // process-lifetime arena, never freed.
    const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .unlimited) catch return null;
    const loaded = image.load(gpa, bytes) catch null;
    if (loaded == null) trace(gpa, "image rejected: {s}", .{image.lastLoadFailure()});
    return loaded;
}

/// Shared tail of the hit and bake paths: replay the image's registry
/// side effects, gate-check the user program, extend, and package the
/// result.
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

    // Re-parse the user files onto a map extending the base's, so user
    // FileIds continue after the base's and base spans stay resolvable.
    const map = gpa.create(SourceMap) catch return null;
    map.* = SourceMap.init(gpa);
    map.files.appendSlice(map.arena.allocator(), loaded.map.files.items) catch return null;
    const user2 = parseUserFiles(gpa, map, paths, user.texts) orelse return null;

    const built = interp_ir.build.buildModuleFilesExtend(gpa, loaded.base, user2.asts) catch return null;

    var bindings = bindings_in;
    for (loaded.binding_fqns) |fqn| {
        if (bindings.resolve(fqn)) |f| bindings.register(fqn, f) catch {};
    }

    return .{ .built = built, .map = map, .bindings = bindings };
}

/// Cold path: run the full legacy dependency load on a fresh map, lower
/// it into a `StdlibBase`, bake + publish the image (and the meta sidecar),
/// then extend for this run.
fn bakeAndPrepare(
    gpa: Allocator,
    cache: []const u8,
    meta_file: []const u8,
    write_meta_file: bool,
    user: ParsedUser,
    paths: []const []const u8,
    features: *const RequestedFeatures,
) ?Prepared {
    const exe = exeStamp(gpa) orelse return null;
    const stdlib_hash = stdlibContentHash(gpa) orelse return null;

    const dep_map = gpa.create(SourceMap) catch return null;
    dep_map.* = SourceMap.init(gpa);
    var report = pack_cache.EmbeddedReport{};
    var selection = pack_cache.Selection{};
    const deps = pack_cache.loadInstalledPacksOpts(gpa, user.asts, dep_map, features, .{
        .embedded_report = &report,
        .selection = &selection,
    });

    const key = imageKey(stdlib_hash, exe, report.gate_full, selection.packs.items);
    const hex = keyHex(key);
    const image_path = std.fmt.allocPrint(gpa, "{s}/stdlib-{s}.klio-image", .{ cache, hex }) catch return null;

    if (write_meta_file) {
        writeMeta(gpa, cache, meta_file, .{
            .pkgs = report.pkgs.items,
            .any_non_implicit = report.any_non_implicit,
        });
        // The gate was unknown when this path was chosen; an image for the
        // now-known key may already exist (e.g. the meta file was pruned).
        if (loadImageFile(gpa, image_path)) |loaded| {
            trace(gpa, "hit {s}", .{hex});
            return finishFromLoaded(gpa, loaded, user, paths, deps.bindings);
        }
        if (tombstoneExists(gpa, cache, hex)) return null;
    }

    const base = (interp_ir.build.buildStdlibBase(gpa, deps.asts) catch return null) orelse {
        writeTombstone(gpa, cache, hex);
        trace(gpa, "unbakeable {s} (base not snapshot-safe)", .{hex});
        return null;
    };
    base.user_file_start = @intCast(dep_map.files.items.len);

    const bytes = (image.bake(gpa, base, dep_map, .{
        .known_packages = report.known_packages.items,
        .binding_fqns = report.binding_fqns.items,
    }) catch return null) orelse {
        writeTombstone(gpa, cache, hex);
        trace(gpa, "unbakeable {s} (outside serializable surface)", .{hex});
        return null;
    };
    writeAtomic(gpa, cache, image_path, bytes);
    pruneImages(gpa, cache);
    trace(gpa, "baked {s} ({d} bytes)", .{ hex, bytes.len });

    // Extend straight from the in-memory base — no need to reload what we
    // just wrote.
    if (!interp_ir.build.canExtendBase(base, user.asts)) {
        trace(gpa, "fallback (base name collision)", .{});
        return null;
    }
    const map = gpa.create(SourceMap) catch return null;
    map.* = SourceMap.init(gpa);
    map.files.appendSlice(map.arena.allocator(), dep_map.files.items) catch return null;
    const user2 = parseUserFiles(gpa, map, paths, user.texts) orelse return null;
    const built = interp_ir.build.buildModuleFilesExtend(gpa, base, user2.asts) catch return null;
    return .{ .built = built, .map = map, .bindings = deps.bindings };
}

// ---------------------------------------------------------------------
// `klio bake`
// ---------------------------------------------------------------------

/// `klio bake [files...]`: ensure the stdlib image(s) the given programs
/// need exist, baking on miss. With no files, both stdlib gate variants
/// are baked (a program with no stdlib imports and one importing the
/// full curated set).
pub fn runBake(gpa: Allocator, paths: []const []const u8, features: *const RequestedFeatures) u8 {
    if (disabled(gpa)) {
        io.writeStderr("error: the stdlib image cache is disabled (KLIO_STDLIB_IMAGE=0 or KLIO_PACK_DIAG set)\n");
        return 2;
    }
    if (paths.len != 0) {
        return bakeForPrograms(gpa, paths, features);
    }
    // Synthesize the two gate variants under the user's own cache dir.
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
