//! Stdlib image cache for the CLI: bake the lowered dependency base
//! (embedded stdlib sources plus any selected packs) to
//! `~/.klio/cache/stdlib-<key>.klio-image` once, then load + extend it per
//! run instead of re-parsing and re-lowering ~4500 declarations.
//!
//! Keying — the image is addressed by a Blake3 over every input the bake
//! consumed:
//!   - the image format version and the `klio` executable's own identity
//!     (size + mtime of the running executable — any rebuild of the
//!     interpreter invalidates every image),
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
const RequestedFeatures = pack_cache.RequestedFeatures;

/// Keep this many images; older ones (by mtime) are pruned after a bake.
/// The examples corpus alone spans ~10 distinct pack-set fingerprints
/// (runtime, +ui, +material3, +foundation, +text, mosaic, ktor, ...); a
/// cap below that count made every parallel corpus run evict the images
/// its sibling processes were about to load, re-baking 30s+ images
/// forever. Images run ~10-26MB, so this keeps the cache under ~500MB.
const KEEP_IMAGES = 24;

/// A program assembled against the image (or freshly baked) base: the
/// extended module, the map its spans resolve through, and the bindings
/// to install. Everything lives on the caller's process-lifetime arena.
pub const Prepared = struct {
    built: BuiltModule,
    map: *const SourceMap,
    bindings: HostBindings,
    /// The user files parsed onto `map` (their FileIds are the trailing
    /// entries, after the base's). `klio test` discovers tests in these.
    user_asts: []const KotlinFile,
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

/// `$KLIO_HOME/.klio/cache` (or `~/.klio/cache`), created if absent. Caller frees.
fn cacheDir(gpa: Allocator) ?[]u8 {
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

/// Size + mtime of the running executable: any rebuild of the interpreter
/// invalidates every baked image.
fn exeStamp(gpa: Allocator) ?[2]u64 {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const st = blk: {
        if (builtin.os.tag == .linux)
            break :blk cwd.statFile(fio, "/proc/self/exe", .{}) catch return null;
        if (builtin.os.tag.isDarwin()) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            var n: u32 = buf.len;
            if (std.c._NSGetExecutablePath(&buf, &n) != 0) return null;
            const path = std.mem.sliceTo(&buf, 0);
            break :blk cwd.statFile(fio, path, .{}) catch return null;
        }
        return null;
    };
    const mtime_ns: u64 = @truncate(@as(u128, @bitCast(@as(i128, st.mtime.nanoseconds))));
    return .{ st.size, mtime_ns };
}

/// Content hash of every stdlib source the bake consumes, mirroring
/// `stdlibPackBytes`'s resolution order: the `KLIO_STDLIB_PACK` override
/// pack when set, else the curated upstream files + klio actuals the cwd
/// checkout provides, else the pack bytes embedded in the binary. Null
/// only when no source resolves (then there is nothing to bake either).
fn stdlibContentHash(gpa: Allocator) ?[32]u8 {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    const cwd = std.Io.Dir.cwd();

    var hasher = std.crypto.hash.Blake3.init(.{});

    // The @Composable lowering plugin rewrites base/pack composables at bake
    // time. It is the only compose path now, so the salt is constant; kept so a
    // pre-cutover image (baked without the transform) is never reused.
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
        // An unreadable override falls through to the checkout, exactly
        // like `stdlibPackBytes`.
    }
    if (!override_hashed and !hashCheckoutSources(gpa, fio, &hasher)) {
        return embeddedContentHash();
    }

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// Fold the cwd checkout's stdlib sources into `hasher`. False when any
/// file is unreadable (the pack build would fail the same way, so the run
/// falls through to the embedded pack and its hash).
fn hashCheckoutSources(gpa: Allocator, fio: std.Io, hasher: *std.crypto.hash.Blake3) bool {
    const cwd = std.Io.Dir.cwd();
    const pb = stdlib.pack_builder;
    var upstream = cwd.openDir(fio, pb.UPSTREAM_STDLIB_ROOT, .{}) catch return false;
    defer upstream.close(fio);
    for (pb.CURATED_UPSTREAM_SOURCES) |rel| {
        const bytes = upstream.readFileAlloc(fio, rel, gpa, .unlimited) catch return false;
        defer gpa.free(bytes);
        hasher.update(rel);
        hasher.update(":");
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, bytes.len, .little);
        hasher.update(&len_buf);
        hasher.update(bytes);
    }
    var klio_dir = cwd.openDir(fio, pb.KLIO_STDLIB_DIR, .{}) catch return false;
    defer klio_dir.close(fio);
    for (pb.KLIO_STDLIB_ACTUAL_FILES) |rel| {
        const bytes = klio_dir.readFileAlloc(fio, rel, gpa, .unlimited) catch return false;
        defer gpa.free(bytes);
        hasher.update(rel);
        hasher.update(":");
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, bytes.len, .little);
        hasher.update(&len_buf);
        hasher.update(bytes);
    }
    return true;
}

/// Hash of the pack bytes embedded in the binary, or null in builds
/// carrying none (zigcheck stub builds).
fn embeddedContentHash() ?[32]u8 {
    const bytes = stdlib_pack.EMBEDDED_PACK_BYTES orelse return null;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("embedded:");
    hasher.update(bytes);
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

pub const ParsedUser = struct {
    texts: [][]const u8,
    asts: []KotlinFile,
};

/// Parse the user files onto `map`. Null on any read/lex/parse failure —
/// the caller then takes the legacy path, which renders the diagnostics.
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

/// Publish the image's own declarations for the checker (see
/// `types.ExternDecls`): every class simple name, and the return class of
/// every top-level function whose simple name resolves unambiguously.
/// Check the base's OWN sources and stage the resolutions on it. Runs only
/// where those sources exist — while an image is being built — so a cached
/// run pays nothing and still gets the answers.
/// Compute the base sources' eager call resolutions and stage them on the
/// pending channel so `buildStdlibBase`'s body lowering consumes them —
/// the SAME ordering as the whole-program build, where `computeEagerCalls`
/// runs before the build. Base bodies lower during the base build; a check
/// that runs only afterwards can no longer influence them, and a composable
/// call the shape resolver cannot prove (`default_param_shape`) then falls
/// to the bare value read and loses its `($composer, $changed)` pair — the
/// baked image carries the unthreaded call and the run dies with
/// `startRestartGroup` on `kotlin.Nothing`.
fn stageBaseEagerCalls(gpa: Allocator, asts: []const KotlinFile) void {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_STDLIB_CHECK") orelse "1", "0")) return;
    // The base's own sources ARE the whole universe for calls inside
    // them, so a source extension pick is trustworthy here in a way it
    // never is for a user program that also loads packs.
    typeck_mod.check.expr_calls.complete_universe = true;
    defer typeck_mod.check.expr_calls.complete_universe = false;
    if (@import("commands.zig").computeEagerCalls(gpa, asts, &.{})) |ec| {
        if (ir_mod.pending_eager_calls) |*old| old.deinit();
        ir_mod.pending_eager_calls = ec;
    }
}

fn checkBaseSources(gpa: Allocator, base: *interp_ir.build.StdlibBase, asts: []const KotlinFile) void {
    _ = asts;
    if (std.mem.eql(u8, runtime.envOnce("KLIO_STDLIB_CHECK") orelse "1", "0")) return;
    // The resolutions staged by `stageBaseEagerCalls` were consumed into the
    // built module (call span -> declaration span). Key each to the FuncId
    // lowering assigned so the answers ride the image and a cached run pays
    // nothing.
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
        base.eager_calls = out.toOwnedSlice(gpa) catch &.{};
        if (runtime.envOnce("KLIO_EAGER_AUDIT") != null) {
            std.debug.print("[stdlib-check] {d} base call resolutions, {d} keyed to a FuncId\n", .{ total, base.eager_calls.len });
        }
    }
    // The checker's per-run channels are the USER program's to fill;
    // clear anything the base pass staged so they do not leak into it.
    if (ir_mod.pending_eager_calls) |*m| {
        m.deinit();
        ir_mod.pending_eager_calls = null;
    }
    if (ir_mod.pending_eager_call_fids) |*m| {
        m.deinit();
        ir_mod.pending_eager_call_fids = null;
    }
}

/// Republish the base's own eager call resolutions, baked when its sources
/// were last available. Merged UNDER the user program's, which is computed
/// after this and must win on any span they share (they cannot: base and
/// user file ids are disjoint, but the ordering states the intent).
fn publishBaseEagerCalls(gpa: std.mem.Allocator, sb: *const interp_ir.build.StdlibBase) void {
    if (sb.eager_calls.len == 0) return;
    var m = ir_mod.pending_eager_call_fids orelse std.AutoHashMap(span.Span, u32).init(gpa);
    for (sb.eager_calls) |ec| m.put(ec.call, ec.fid) catch {};
    ir_mod.pending_eager_call_fids = m;
    if (runtime.envOnce("KLIO_EAGER_AUDIT") != null) {
        std.debug.print("[stdlib-check] republished {d} base call resolutions\n", .{sb.eager_calls.len});
    }
}

/// The bare class head of a lowered type name: no nullability marker, no
/// type arguments, no package qualification.
fn headOf(name: []const u8) []const u8 {
    var h = std.mem.trimEnd(u8, name, "?");
    if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
    if (std.mem.lastIndexOfScalar(u8, h, '.')) |d| h = h[d + 1 ..];
    return h;
}

fn publishExternDecls(gpa: std.mem.Allocator, sb: *const interp_ir.build.StdlibBase) void {
    const mg = sb.built.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    // Simple names, because that is the only spelling the checker's class
    // table uses. Where two classes share one — compose declares a
    // `SlotTable` in both its gapbuffer and linkbuffer implementations — the
    // name identifies nothing, and offering one's extensions for the other
    // binds calls to a declaration the receiver never had. Such a name is
    // dropped from every published map.
    var classes = std.StringHashMap(void).init(gpa);
    var ambiguous_names = std.StringHashMap(void).init(gpa);
    defer ambiguous_names.deinit();
    for (m.classes.items) |*c| {
        const gop = classes.getOrPut(c.name) catch continue;
        if (gop.found_existing) ambiguous_names.put(c.name, {}) catch {};
    }
    {
        var ait = ambiguous_names.keyIterator();
        while (ait.next()) |k| _ = classes.remove(k.*);
    }
    // Return heads ride the image's baked index: on a cached load the funcs
    // are lazy, so walking them here answered nothing at all. On the run
    // that BUILDS the base there is no baked index yet and the funcs are
    // right there, so derive it — the two paths must publish the same thing
    // or the checker's answers depend on whether the cache was warm.
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
    // Extensions, keyed by the receiver's class head.
    //
    // Built from the NAME INDEX and the declaration signatures, never from
    // decoded function bodies: on a cached image the funcs are lazy and
    // `m.funcs.items` is empty, so a walk over them published nothing at all
    // — which is why the checker had zero candidates for every member call
    // on exactly the runs that matter. Both of these are eager in the image,
    // because lowering resolves names against them.
    // The baked index on a load, derived from the decoded funcs on the run
    // that builds the base, so a warm cache and a cold one publish the same.
    var ext_rets = std.StringHashMap([]const u8).init(gpa);
    defer ext_rets.deinit();
    if (sb.ext_returns.len != 0) {
        for (sb.ext_returns) |er| ext_rets.put(er.key, er.head) catch {};
    } else {
        var eamb = std.StringHashMap(void).init(gpa);
        defer eamb.deinit();
        for (m.funcs.items) |*f| {
            if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
            if (f.name.len == 0) continue;
            const rh = headOf(f.params[0].ty.name);
            const h = headOf(f.return_ty.name);
            if (rh.len == 0 or h.len == 0 or !classes.contains(h)) continue;
            const key = std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ rh, f.name }) catch continue;
            if (eamb.contains(key)) continue;
            const gop = ext_rets.getOrPut(key) catch continue;
            if (gop.found_existing) {
                if (!std.mem.eql(u8, gop.value_ptr.*, h)) {
                    _ = ext_rets.remove(key);
                    eamb.put(key, {}) catch {};
                }
            } else gop.value_ptr.* = h;
        }
    }
    var exts = std.StringHashMap(std.ArrayList(types_mod.ExternExt)).init(gpa);
    var nit = m.func_name_index.iterator();
    while (nit.next()) |entry| {
        const fname = entry.key_ptr.*;
        if (fname.len == 0) continue;
        for (entry.value_ptr.items) |fid| {
            const sig = m.decl_sigs.get(fid.int()) orelse continue;
            const recv = sig.receiver_ty orelse continue;
            const recv_head = headOf(recv.name);
            if (recv_head.len == 0 or ambiguous_names.contains(recv_head)) continue;
            const n = sig.sig.len;
            const heads = gpa.alloc([]const u8, n) catch continue;
            const nulls = gpa.alloc(bool, n) catch {
                gpa.free(heads);
                continue;
            };
            for (sig.sig, heads, nulls) |*p, *h, *nl| {
                h.* = headOf(p.name);
                nl.* = p.nullable;
            }
            const gop = exts.getOrPut(recv_head) catch {
                gpa.free(heads);
                gpa.free(nulls);
                continue;
            };
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.append(gpa, .{
                .name = fname,
                .fid = fid.int(),
                .param_heads = heads,
                .param_nullable = nulls,
                // From the baked index; the declaration signature has no
                // return type of its own. This head is RANKING evidence
                // only — see the split at its consumer.
                .return_head = blk_r: {
                    const key = std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ recv_head, fname }) catch break :blk_r "";
                    defer gpa.free(key);
                    const h = ext_rets.get(key) orelse break :blk_r "";
                    if (ambiguous_names.contains(h)) break :blk_r "";
                    break :blk_r h;
                },
                .return_nullable = false,
                .is_infix = false,
            }) catch {};
        }
    }
    if (runtime.envOnce("KLIO_EAGER_AUDIT") != null) {
        var n_ext: usize = 0;
        var eit = exts.valueIterator();
        while (eit.next()) |l| n_ext += l.items.len;
        std.debug.print("[EAGER-EXTERN] published classes={d} fn_returns={d} ext_recvs={d} exts={d} (module funcs={d})\n", .{ classes.count(), rets.count(), exts.count(), n_ext, m.funcs.items.len });
    }
    var supers = std.StringHashMap([][]const u8).init(gpa);
    for (m.classes.items) |*c| {
        if (c.supertypes.len == 0 or ambiguous_names.contains(c.name)) continue;
        const names = gpa.alloc([]const u8, c.supertypes.len) catch continue;
        var n: usize = 0;
        for (c.supertypes) |sid| {
            if (sid.int() >= m.classes.items.len) continue;
            names[n] = m.classes.items[sid.int()].name;
            n += 1;
        }
        if (n == 0) {
            gpa.free(names);
            continue;
        }
        supers.put(c.name, names[0..n]) catch gpa.free(names);
    }
    types_mod.pending_extern_decls = .{
        .classes = classes,
        .fn_return_class = rets,
        .extensions = exts,
        .supertypes = supers,
        .has_extensions = true,
    };
}

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
    // A program with neither imports nor a package-rooted qualified
    // reference can never match a pack's library id, so the cache walk
    // (reading + verifying every pack file) is skipped and the selection
    // is the empty one the loader would compute.
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
    // Packs are parsed only to read their bindings + selection identity; the
    // image already holds their lowered form. Parse the (large, e.g. ktor)
    // pack ASTs and source into a scratch arena and drop it before the program
    // runs — keeping only the bindings table and the selection, copied into
    // process-lifetime storage. This avoids retaining tens of MB of pack AST
    // for a server's whole life.
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

    // Load gate from the meta sidecar; missing meta means cold path.
    const meta_file = metaPath(gpa, cache, stdlib_hash) orelse return null;
    var gate_full: ?bool = null;
    if (readMeta(gpa, meta_file)) |meta| {
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
        if (loadImageFile(gpa, image_path)) |loaded| {
            const t_load = runtime.clockMonotonicNanos();
            const out = finishFromLoaded(gpa, loaded, user, paths, pack_bindings);
            // A null `out` means the loaded image could not serve this
            // program (extend gate refused) and the caller re-lowers the
            // whole dependency surface from source — name the outcome so
            // the trace never reads as a served hit.
            trace(gpa, "{s} {s} (key {d}ms, packs {d}ms, load {d}ms, extend {d}ms)", .{
                if (out != null) @as([]const u8, "hit") else "hit-but-fallback",
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
    // The decoded base borrows from these bytes for the process's life. Prefer a
    // read-only mmap: the decode only touches the pages it eagerly decodes, so
    // the deferred body/IR sections and the (slice-only) stdlib source text stay
    // file-backed and never count against RSS until something reads them. Fall
    // back to a heap read where mmap is unavailable.
    const bytes = mmapImage(path) orelse blk: {
        var threaded = threadedIo(gpa);
        defer threaded.deinit();
        break :blk std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .unlimited) catch return null;
    };
    const loaded = image.load(gpa, bytes) catch null;
    if (loaded == null) trace(gpa, "image rejected: {s}", .{image.lastLoadFailure()});
    return loaded;
}

/// Read-only `MAP_PRIVATE` mmap of the image, never unmapped (process-lifetime,
/// like the base that borrows it). Returns null on any error so the caller
/// falls back to a heap read.
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

    publishExternDecls(gpa, loaded.base);
    publishBaseEagerCalls(gpa, loaded.base);
    if (@import("commands.zig").computeEagerCalls(gpa, user2.asts, &.{})) |ec| ir_mod.pending_eager_calls = ec;
    span.active_map = map;
    const built = interp_ir.build.buildModuleFilesExtend(gpa, loaded.base, user2.asts) catch return null;

    var bindings = bindings_in;
    for (loaded.binding_fqns) |fqn| {
        if (bindings.resolve(fqn)) |f| bindings.register(fqn, f) catch {};
    }

    return .{ .built = built, .map = map, .bindings = bindings, .user_asts = user2.asts };
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

    const tb0 = runtime.clockMonotonicNanos();
    const dep_map = gpa.create(SourceMap) catch return null;
    dep_map.* = SourceMap.init(gpa);
    var report = pack_cache.EmbeddedReport{};
    var selection = pack_cache.Selection{};
    const deps = pack_cache.loadInstalledPacksOpts(gpa, user.asts, dep_map, features, .{
        .embedded_report = &report,
        .selection = &selection,
    });
    const tb_parse = runtime.clockMonotonicNanos();

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

    const tb_pre = runtime.clockMonotonicNanos();
    stageBaseEagerCalls(gpa, deps.asts);
    const base = (interp_ir.build.buildStdlibBase(gpa, deps.asts) catch return null) orelse {
        writeTombstone(gpa, cache, hex);
        trace(gpa, "unbakeable {s} (base not snapshot-safe)", .{hex});
        return null;
    };
    base.user_file_start = @intCast(dep_map.files.items.len);

    // The BASE's own sources are checked here, where they exist. This is the
    // only place they do: a cached run loads IR and never parses them, so a
    // call site inside a stdlib body could never receive an eager pick — and
    // the dispatch census is mostly such sites. The results ride the image.
    checkBaseSources(gpa, base, deps.asts);

    const tb_lower = runtime.clockMonotonicNanos();
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
    trace(gpa, "baked {s} ({d} bytes; parse {d}ms, lower {d}ms, serialize {d}ms)", .{
        hex,
        bytes.len,
        (tb_parse - tb0) / 1_000_000,
        (tb_lower - tb_pre) / 1_000_000,
        (runtime.clockMonotonicNanos() - tb_lower) / 1_000_000,
    });

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
    publishExternDecls(gpa, base);
    publishBaseEagerCalls(gpa, base);
    if (@import("commands.zig").computeEagerCalls(gpa, user2.asts, &.{})) |ec| ir_mod.pending_eager_calls = ec;
    span.active_map = map;
    const built = interp_ir.build.buildModuleFilesExtend(gpa, base, user2.asts) catch return null;
    return .{ .built = built, .map = map, .bindings = deps.bindings, .user_asts = user2.asts };
}

// ---------------------------------------------------------------------
// `klio bundle` support
// ---------------------------------------------------------------------

/// One dependency load for `klio bundle`: the parsed dependency ASTs
/// (embedded stdlib + installed packs), the map they parsed onto, and
/// the run bindings. Lowering MUTATES the ASTs (lifting, plugin
/// rewrites) and baking strips dead AST bodies, so each lower needs its
/// own load — the bundler calls this once per bake attempt.
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

/// The dependency base assembled for a bundle: the image bytes to embed
/// and the in-memory base + map for bundle-time program verification.
pub const BundleBase = struct {
    bytes: []const u8,
    base: *interp_ir.build.StdlibBase,
    map: *const SourceMap,
};

/// Assemble the dependency base image for `klio bundle` from an already
/// completed dependency load: reuse a cache-keyed image when one matches
/// or bake fresh (publishing the bake into the cache like a normal run).
/// `report`/`selection` are the load's out-params (they key the cache).
/// Null when the base cannot bake — the caller surfaces the error.
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

    // Same bake-time staging + check as `bakeAndPrepare`: this is the OTHER
    // path that builds a base from source (`bake-image`, and any bundle),
    // and the resolutions have to ride whichever image the run ends up with.
    stageBaseEagerCalls(gpa, deps.asts);
    const base = (interp_ir.build.buildStdlibBase(gpa, deps.asts) catch return null) orelse return null;
    base.user_file_start = @intCast(deps.map.files.items.len);
    checkBaseSources(gpa, base, deps.asts);
    const bytes = (image.bake(gpa, base, deps.map, .{
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
