//! Pack subcommand: build a `.klio-pack` artifact, migrate one, and talk
//! to a local-filesystem registry.
//!
//! The `run_pack` dispatch over every `PackCmd` subcommand wires one
//! command apiece; the cache helpers it dispatches to (`inspect_pack`,
//! `install_pack_into_cache`, …) live in `pack_cache.zig`.
//!
//! This build has no zstd codec, so every section that the Rust builder
//! stored as `Compression.Zstd` is stored uncompressed here (same caveat
//! as the embedded stdlib pack builder). `migrate` re-emits plain
//! sections and `train-dict` reports the missing encoder as data.

const std = @import("std");

const span = @import("span");
const SourceMap = span.SourceMap;
const FileId = span.FileId;
const Span = span.Span;

const ast = @import("ast");
const KotlinFile = ast.KotlinFile;

const types = @import("types");
const Type = types.Type;

const lexer = @import("lexer");
const Lexer = lexer.Lexer;

const parser = @import("parser");
const Parser = parser.Parser;

const resolver = @import("resolver");
const typeck = @import("typeck");

const runtime = @import("runtime");

const stdlib = @import("stdlib");
const HostBindings = stdlib.HostBindings;

const pack = @import("pack");
const PackReader = pack.PackReader;
const PackWriter = pack.PackWriter;
const Compression = pack.Compression;
const section_names = pack.section_names;
const schema = pack.schema;
const PackError = pack.PackError;

const io = @import("io.zig");

const pack_cache = @import("pack_cache.zig");
const mergedHostBindings = pack_cache.mergedHostBindings;
const readPackManifest = pack_cache.readPackManifest;
const installPackIntoCache = pack_cache.installPackIntoCache;
const listCachePacks = pack_cache.listCachePacks;
const removeCachePack = pack_cache.removeCachePack;
const inspectPack = pack_cache.inspectPack;
const verifyPack = pack_cache.verifyPack;
const PathResult = pack_cache.PathResult;
const VoidResult = pack_cache.VoidResult;
const ManifestResult = pack_cache.ManifestResult;

/// `klio pack <cmd>` subcommands. Mirrors `main::PackCmd`.
pub const PackCmd = union(enum) {
    /// Build a `.klio-pack` from a library directory.
    Build: struct { dir: []const u8, out: ?[]const u8 = null },
    /// Build a pack from the in-process Kotlin standard library.
    Stdlib: struct {
        out: []const u8 = "target/packs/stdlib.klio-pack",
        bindings_only: bool = true,
        compress_symbols: bool = true,
    },
    /// Copy a `.klio-pack` into the local cache.
    Install: struct { pack: []const u8 },
    /// List every pack in the local cache.
    List,
    /// Remove a cached pack.
    Remove: struct { library_id: []const u8, version: ?[]const u8 = null },
    /// Inspect a pack: manifest, sections, counts.
    Inspect: struct { pack: []const u8 },
    /// Verify a pack by reading every section back through the loader.
    Verify: struct { pack: []const u8, smoke: ?[]const u8 = null },
    /// Scaffold a new library project.
    New: struct { dir: []const u8, id: ?[]const u8 = null },
    /// Migrate a pack to the current on-disk format version.
    Migrate: struct { input: []const u8, out: ?[]const u8 = null },
    /// Train a zstd dictionary from packs.
    TrainDict: struct {
        inputs: []const []const u8,
        out: []const u8 = "target/packs/klio.zstd-dict",
        max_size: usize = 64 * 1024,
    },
    /// Publish a pack into a local-filesystem registry.
    Publish: struct { pack: []const u8, registry: ?[]const u8 = null },
    /// Search a registry's index for libraries matching `query`.
    Search: struct { query: []const u8, registry: ?[]const u8 = null },
    /// Fetch a pack from a registry into the local cache.
    Fetch: struct {
        library_id: []const u8,
        version: ?[]const u8 = null,
        registry: ?[]const u8 = null,
    },
};

/// A failure carried as data. Owned by `gpa`; rendered by the dispatch
/// arm and then freed. Mirrors the Rust `String` error returned by every
/// pack helper.
const Failure = []u8;

fn fail(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Failure {
    return std.fmt.allocPrint(gpa, fmt, args) catch @constCast("out of memory");
}

/// single dispatch over every PackCmd subcommand; each arm wires one command
pub fn runPack(gpa: std.mem.Allocator, cmd: PackCmd) u8 {
    switch (cmd) {
        .Build => |b| switch (buildLibraryPack(gpa, b.dir, b.out)) {
            .ok => |path| {
                defer gpa.free(path);
                io.printStderr(gpa, "wrote {s}\n", .{path});
                return 0;
            },
            .err => |e| {
                defer gpa.free(e);
                io.printStderr(gpa, "error: {s}\n", .{e});
                return 2;
            },
        },
        .Stdlib => |s| {
            if (!s.bindings_only) {
                io.printStderr(gpa, "--bindings-only is the only supported mode in the MVP\n", .{});
                return 2;
            }
            switch (buildStdlibPack(gpa, s.compress_symbols)) {
                .ok => |bytes| {
                    defer gpa.free(bytes);
                    switch (writePack(gpa, s.out, bytes)) {
                        .ok => {
                            io.printStderr(gpa, "wrote {s} ({d} bytes)\n", .{ s.out, bytes.len });
                            return 0;
                        },
                        .err => |e| {
                            defer gpa.free(e);
                            io.printStderr(gpa, "error: {s}\n", .{e});
                            return 2;
                        },
                    }
                },
                .err => |e| {
                    defer gpa.free(e);
                    io.printStderr(gpa, "pack build failed: {s}\n", .{e});
                    return 2;
                },
            }
        },
        .Install => |i| switch (installPackIntoCache(gpa, i.pack)) {
            .ok => |dest| {
                defer gpa.free(dest);
                io.printStderr(gpa, "installed {s}\n", .{dest});
                return 0;
            },
            .err => |e| {
                defer gpa.free(e);
                io.printStderr(gpa, "error: {s}\n", .{e});
                return 2;
            },
        },
        .List => switch (listCachePacks(gpa)) {
            .ok => return 0,
            .err => |e| {
                defer gpa.free(e);
                io.printStderr(gpa, "error: {s}\n", .{e});
                return 2;
            },
        },
        .Remove => |r| switch (removeCachePack(gpa, r.library_id, r.version)) {
            .ok => |p| {
                defer gpa.free(p);
                io.printStderr(gpa, "removed {s}\n", .{p});
                return 0;
            },
            .err => |e| {
                defer gpa.free(e);
                io.printStderr(gpa, "error: {s}\n", .{e});
                return 2;
            },
        },
        .Inspect => |i| switch (inspectPack(gpa, i.pack)) {
            .ok => return 0,
            .err => |e| {
                defer gpa.free(e);
                io.printStderr(gpa, "error: {s}\n", .{e});
                return 2;
            },
        },
        .Verify => |v| switch (verifyPack(gpa, v.pack, v.smoke)) {
            .ok => return 0,
            .err => |e| {
                defer gpa.free(e);
                io.printStderr(gpa, "verify failed: {s}\n", .{e});
                return 1;
            },
        },
        .Migrate => |m| {
            const target = m.out orelse m.input;
            switch (migratePack(gpa, m.input, target)) {
                .ok => {
                    io.printStderr(gpa, "migrated {s} -> {s}\n", .{ m.input, target });
                    return 0;
                },
                .err => |e| {
                    defer gpa.free(e);
                    io.printStderr(gpa, "error: {s}\n", .{e});
                    return 2;
                },
            }
        },
        .Publish => |p| switch (publishToRegistry(gpa, p.pack, p.registry)) {
            .ok => |dest| {
                defer gpa.free(dest);
                io.printStderr(gpa, "published {s}\n", .{dest});
                return 0;
            },
            .err => |e| {
                defer gpa.free(e);
                io.printStderr(gpa, "error: {s}\n", .{e});
                return 2;
            },
        },
        .Search => |s| switch (searchRegistry(gpa, s.query, s.registry)) {
            .ok => return 0,
            .err => |e| {
                defer gpa.free(e);
                io.printStderr(gpa, "error: {s}\n", .{e});
                return 2;
            },
        },
        .Fetch => |f| switch (fetchFromRegistry(gpa, f.library_id, f.version, f.registry)) {
            .ok => |dest| {
                defer gpa.free(dest);
                io.printStderr(gpa, "fetched {s}\n", .{dest});
                return 0;
            },
            .err => |e| {
                defer gpa.free(e);
                io.printStderr(gpa, "error: {s}\n", .{e});
                return 2;
            },
        },
        .TrainDict => |t| switch (trainZstdDict(gpa, t.inputs, t.out, t.max_size)) {
            .ok => {
                io.printStderr(gpa, "trained dict {s}\n", .{t.out});
                return 0;
            },
            .err => |e| {
                defer gpa.free(e);
                io.printStderr(gpa, "error: {s}\n", .{e});
                return 2;
            },
        },
        .New => |n| switch (scaffoldLibrary(gpa, n.dir, n.id)) {
            .ok => {
                io.printStderr(gpa, "scaffolded {s}\n", .{n.dir});
                return 0;
            },
            .err => |e| {
                defer gpa.free(e);
                io.printStderr(gpa, "error: {s}\n", .{e});
                return 2;
            },
        },
    }
}

/// `Result<T, String>` for the helpers whose success carries a value (a
/// path, bytes). Mirrors the Rust signatures; reuses the same `.ok`/`.err`
/// shape as `pack_cache.PathResult`.
fn Outcome(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: Failure,
    };
}

// ---------------------------------------------------------------------
// filesystem helpers
// ---------------------------------------------------------------------

fn threadedIo(allocator: std.mem.Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(allocator, .{});
}

/// Read a whole file relative to cwd into an owned buffer.
fn readFileOwned(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const tio = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(tio, path, gpa, .unlimited) catch null;
}

/// `std.fs::create_dir_all(parent)` for the parent of `path`, then write.
fn writeFileWithParents(gpa: std.mem.Allocator, path: []const u8, data: []const u8) VoidResult {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const tio = threaded.io();
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(tio, parent) catch |e|
            return .{ .err = fail(gpa, "{s}", .{@errorName(e)}) };
    }
    std.Io.Dir.cwd().writeFile(tio, .{ .sub_path = path, .data = data }) catch |e|
        return .{ .err = fail(gpa, "{s}", .{@errorName(e)}) };
    return .{ .ok = {} };
}

fn copyFileTo(gpa: std.mem.Allocator, src: []const u8, dest: []const u8) VoidResult {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const tio = threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.copyFile(src, cwd, dest, tio, .{}) catch |e|
        return .{ .err = fail(gpa, "copy: {s}", .{@errorName(e)}) };
    return .{ .ok = {} };
}

fn pathExists(gpa: std.mem.Allocator, path: []const u8) bool {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const tio = threaded.io();
    _ = std.Io.Dir.cwd().statFile(tio, path, .{}) catch return false;
    return true;
}

fn getEnv(gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    return runtime.procEnvGetVar(gpa, name) catch null;
}

fn packErrText(gpa: std.mem.Allocator, err: PackError) Failure {
    return std.fmt.allocPrint(gpa, "{f}", .{err}) catch @constCast("pack error");
}

/// Open a pack from `path`, returning a reader or a `String` failure.
fn openReader(gpa: std.mem.Allocator, path: []const u8) Outcome(PackReader) {
    const bytes = readFileOwned(gpa, path) orelse
        return .{ .err = fail(gpa, "read {s}: file unreadable", .{path}) };
    var err: PackError = undefined;
    const reader = (PackReader.fromBytes(gpa, bytes, &err) catch
        return .{ .err = fail(gpa, "out of memory", .{}) }) orelse
        return .{ .err = packErrText(gpa, err) };
    return .{ .ok = reader };
}

// ---------------------------------------------------------------------
// migrate
// ---------------------------------------------------------------------

/// Re-encode a pack against the currently-supported `FORMAT_VERSION`.
///
/// Today the writer only knows how to emit one version, so a successful
/// migrate is a no-op round-trip that validates the input pack and
/// rewrites it deterministically. Dictionary-compressed sections are
/// re-emitted as plain sections; this build has no zstd codec, so any
/// already-compressed section is unreadable and the migrate surfaces the
/// reader's error.
fn migratePack(gpa: std.mem.Allocator, input: []const u8, output: []const u8) VoidResult {
    const reader_res = openReader(gpa, input);
    switch (reader_res) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    var reader = reader_res.ok;
    defer reader.deinit();

    var writer = PackWriter.init(gpa);
    defer writer.deinit();

    // Payloads decoded by the reader must outlive `finish`, so keep them.
    var payloads: std.ArrayList([]u8) = .empty;
    defer {
        for (payloads.items) |p| gpa.free(p);
        payloads.deinit(gpa);
    }

    for (reader.sections()) |entry| {
        var err: PackError = undefined;
        const section = (reader.readSection(entry.name, &err) catch
            return .{ .err = fail(gpa, "out of memory", .{}) }) orelse
            return .{ .err = packErrText(gpa, err) };
        const owned = gpa.dupe(u8, section.slice()) catch {
            section.deinit(gpa);
            return .{ .err = fail(gpa, "out of memory", .{}) };
        };
        section.deinit(gpa);
        payloads.append(gpa, owned) catch return .{ .err = fail(gpa, "out of memory", .{}) };
        // None and Zstd/ZstdDict alike re-emit as plain: this build has no
        // zstd encoder, so re-training a dictionary is the user's call.
        _ = writer.addSection(entry.name, owned, .None) catch
            return .{ .err = fail(gpa, "out of memory", .{}) };
    }

    var err: PackError = undefined;
    var bytes = (writer.finish(&err) catch return .{ .err = fail(gpa, "out of memory", .{}) }) orelse
        return .{ .err = packErrText(gpa, err) };
    defer bytes.deinit(gpa);
    return writeFileWithParents(gpa, output, bytes.items);
}

// ---------------------------------------------------------------------
// Local-filesystem registry
// ---------------------------------------------------------------------

fn registryDir(gpa: std.mem.Allocator, override_path: ?[]const u8) Outcome([]u8) {
    if (override_path) |p| {
        return .{ .ok = gpa.dupe(u8, p) catch return .{ .err = fail(gpa, "out of memory", .{}) } };
    }
    const home = getEnv(gpa, "HOME") orelse return .{ .err = fail(gpa, "HOME env var unset", .{}) };
    defer gpa.free(home);
    const path = std.fs.path.join(gpa, &.{ home, ".klio", "registry" }) catch
        return .{ .err = fail(gpa, "out of memory", .{}) };
    return .{ .ok = path };
}

const RegistryEntry = struct {
    library_id: []const u8,
    version: []const u8,
    abi_version: u32,
    relative_path: []const u8,
};

fn registryIndexPath(gpa: std.mem.Allocator, root: []const u8) ?[]u8 {
    return std.fs.path.join(gpa, &.{ root, "index.json" }) catch null;
}

/// Read the registry's `index.json`. An absent or unreadable file yields
/// an empty list; a malformed file is a failure. The returned slice +
/// every string are owned by `gpa`.
fn readRegistryIndex(gpa: std.mem.Allocator, root: []const u8) Outcome([]RegistryEntry) {
    const path = registryIndexPath(gpa, root) orelse return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(path);
    const bytes = readFileOwned(gpa, path) orelse return .{ .ok = &.{} };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice([]RegistryEntry, gpa, bytes, .{ .allocate = .alloc_always }) catch |e|
        return .{ .err = fail(gpa, "{s}", .{@errorName(e)}) };
    defer parsed.deinit();
    // Deep-copy out of the parser's arena into `gpa`.
    const out = gpa.alloc(RegistryEntry, parsed.value.len) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    for (parsed.value, out) |src, *dst| {
        dst.* = .{
            .library_id = gpa.dupe(u8, src.library_id) catch "",
            .version = gpa.dupe(u8, src.version) catch "",
            .abi_version = src.abi_version,
            .relative_path = gpa.dupe(u8, src.relative_path) catch "",
        };
    }
    return .{ .ok = out };
}

fn freeRegistryIndex(gpa: std.mem.Allocator, entries: []RegistryEntry) void {
    for (entries) |e| {
        gpa.free(e.library_id);
        gpa.free(e.version);
        gpa.free(e.relative_path);
    }
    gpa.free(entries);
}

fn writeRegistryIndex(gpa: std.mem.Allocator, root: []const u8, entries: []const RegistryEntry) VoidResult {
    const bytes = std.json.Stringify.valueAlloc(gpa, entries, .{ .whitespace = .indent_2 }) catch
        return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(bytes);
    const path = registryIndexPath(gpa, root) orelse return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(path);
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const tio = threaded.io();
    std.Io.Dir.cwd().writeFile(tio, .{ .sub_path = path, .data = bytes }) catch |e|
        return .{ .err = fail(gpa, "{s}", .{@errorName(e)}) };
    return .{ .ok = {} };
}

fn lessRegistryEntry(_: void, a: RegistryEntry, b: RegistryEntry) bool {
    const by_id = std.mem.order(u8, a.library_id, b.library_id);
    if (by_id != .eq) return by_id == .lt;
    return std.mem.order(u8, a.version, b.version) == .lt;
}

fn publishToRegistry(
    gpa: std.mem.Allocator,
    pack_path: []const u8,
    registry_override: ?[]const u8,
) PathResult {
    const manifest_res = readPackManifest(gpa, pack_path);
    switch (manifest_res) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    var manifest = manifest_res.ok;
    defer manifest.deinit(gpa);

    const root_res = registryDir(gpa, registry_override);
    switch (root_res) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    const root = root_res.ok;
    defer gpa.free(root);

    const lib_dir = std.fs.path.join(gpa, &.{ root, manifest.library_id, manifest.library_version }) catch
        return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(lib_dir);
    {
        var threaded = threadedIo(gpa);
        defer threaded.deinit();
        const tio = threaded.io();
        std.Io.Dir.cwd().createDirPath(tio, lib_dir) catch |e|
            return .{ .err = fail(gpa, "{s}", .{@errorName(e)}) };
    }
    const file_name = std.fmt.allocPrint(gpa, "{s}-{s}.klio-pack", .{ manifest.library_id, manifest.library_version }) catch
        return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(file_name);
    const dest = std.fs.path.join(gpa, &.{ lib_dir, file_name }) catch
        return .{ .err = fail(gpa, "out of memory", .{}) };
    switch (copyFileTo(gpa, pack_path, dest)) {
        .err => |e| {
            gpa.free(dest);
            return .{ .err = e };
        },
        .ok => {},
    }

    // `dest.strip_prefix(root)` -> the path under the registry root.
    const relative = blk: {
        const prefix = std.fmt.allocPrint(gpa, "{s}{c}", .{ root, std.fs.path.sep }) catch {
            gpa.free(dest);
            return .{ .err = fail(gpa, "out of memory", .{}) };
        };
        defer gpa.free(prefix);
        if (std.mem.startsWith(u8, dest, prefix)) {
            break :blk gpa.dupe(u8, dest[prefix.len..]) catch dest;
        }
        break :blk gpa.dupe(u8, dest) catch dest;
    };
    defer gpa.free(relative);

    const index_res = readRegistryIndex(gpa, root);
    switch (index_res) {
        .err => |e| {
            gpa.free(dest);
            return .{ .err = e };
        },
        .ok => {},
    }
    const old = index_res.ok;
    defer freeRegistryIndex(gpa, old);

    var index: std.ArrayList(RegistryEntry) = .empty;
    defer index.deinit(gpa);
    // Drop any prior entry for this exact id+version, then push the new one.
    for (old) |e| {
        if (std.mem.eql(u8, e.library_id, manifest.library_id) and
            std.mem.eql(u8, e.version, manifest.library_version)) continue;
        index.append(gpa, e) catch {
            gpa.free(dest);
            return .{ .err = fail(gpa, "out of memory", .{}) };
        };
    }
    index.append(gpa, .{
        .library_id = manifest.library_id,
        .version = manifest.library_version,
        .abi_version = manifest.abi_version,
        .relative_path = relative,
    }) catch {
        gpa.free(dest);
        return .{ .err = fail(gpa, "out of memory", .{}) };
    };
    std.mem.sort(RegistryEntry, index.items, {}, lessRegistryEntry);
    switch (writeRegistryIndex(gpa, root, index.items)) {
        .err => |e| {
            gpa.free(dest);
            return .{ .err = e };
        },
        .ok => {},
    }
    return .{ .ok = dest };
}

fn searchRegistry(gpa: std.mem.Allocator, query: []const u8, registry_override: ?[]const u8) VoidResult {
    const root_res = registryDir(gpa, registry_override);
    switch (root_res) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    const root = root_res.ok;
    defer gpa.free(root);

    const entries_res = readRegistryIndex(gpa, root);
    switch (entries_res) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    const entries = entries_res.ok;
    defer freeRegistryIndex(gpa, entries);

    const lq = std.ascii.allocLowerString(gpa, query) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(lq);

    var any = false;
    for (entries) |e| {
        const lid = std.ascii.allocLowerString(gpa, e.library_id) catch continue;
        defer gpa.free(lid);
        if (std.mem.indexOf(u8, lid, lq) == null) continue;
        any = true;
        io.printStdout(gpa, "{s: <32}  {s: <12}  abi {d}  {s}\n", .{ e.library_id, e.version, e.abi_version, e.relative_path });
    }
    if (!any) {
        io.printStderr(gpa, "no packs matching `{s}` in {s}\n", .{ query, root });
    }
    return .{ .ok = {} };
}

fn fetchFromRegistry(
    gpa: std.mem.Allocator,
    library_id: []const u8,
    version: ?[]const u8,
    registry_override: ?[]const u8,
) PathResult {
    const root_res = registryDir(gpa, registry_override);
    switch (root_res) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    const root = root_res.ok;
    defer gpa.free(root);

    const entries_res = readRegistryIndex(gpa, root);
    switch (entries_res) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    const entries = entries_res.ok;
    defer freeRegistryIndex(gpa, entries);

    // Highest version matching id (+ optional exact version).
    var best: ?*const RegistryEntry = null;
    for (entries) |*e| {
        if (!std.mem.eql(u8, e.library_id, library_id)) continue;
        if (version) |v| {
            if (!std.mem.eql(u8, e.version, v)) continue;
        }
        if (best) |b| {
            if (std.mem.order(u8, e.version, b.version) == .gt) best = e;
        } else {
            best = e;
        }
    }
    const candidate = best orelse return .{ .err = fail(gpa, "no registry entry for `{s}`", .{library_id}) };

    const src = std.fs.path.join(gpa, &.{ root, candidate.relative_path }) catch
        return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(src);
    if (!pathExists(gpa, src)) {
        return .{ .err = fail(gpa, "registry entry points at missing file {s}", .{src}) };
    }
    return installPackIntoCache(gpa, src);
}

// ---------------------------------------------------------------------
// train dict
// ---------------------------------------------------------------------

/// Train a zstd dictionary from the AST + sources sections of the
/// supplied packs. This build ships no zstd encoder, so the training
/// path reports the missing codec as data once the inputs are validated.
fn trainZstdDict(
    gpa: std.mem.Allocator,
    inputs: []const []const u8,
    out: []const u8,
    max_size: usize,
) VoidResult {
    _ = out;
    _ = max_size;
    if (inputs.len == 0) {
        return .{ .err = fail(gpa, "at least one input pack required", .{}) };
    }
    var any = false;
    for (inputs) |path| {
        const reader_res = openReader(gpa, path);
        switch (reader_res) {
            .err => |e| return .{ .err = e },
            .ok => {},
        }
        var reader = reader_res.ok;
        defer reader.deinit();
        for ([_][]const u8{ section_names.SOURCES, section_names.AST, section_names.SYMBOLS }) |name| {
            var err: PackError = undefined;
            const section = reader.readSection(name, &err) catch
                return .{ .err = fail(gpa, "out of memory", .{}) };
            if (section) |s| {
                any = true;
                s.deinit(gpa);
            }
        }
    }
    if (!any) {
        return .{ .err = fail(gpa, "no AST/sources/symbols sections found in inputs", .{}) };
    }
    return .{ .err = fail(gpa, "zstd dict training failed: no zstd encoder in this build", .{}) };
}

// ---------------------------------------------------------------------
// scaffold
// ---------------------------------------------------------------------

fn scaffoldLibrary(gpa: std.mem.Allocator, dir: []const u8, id_override: ?[]const u8) VoidResult {
    if (pathExists(gpa, dir)) {
        return .{ .err = fail(gpa, "{s} already exists", .{dir}) };
    }
    const id = id_override orelse std.fs.path.basename(dir);
    if (id.len == 0) {
        return .{ .err = fail(gpa, "could not derive library id from path", .{}) };
    }
    const src_dir = std.fs.path.join(gpa, &.{ dir, "src", "main", "kotlin" }) catch
        return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(src_dir);
    {
        var threaded = threadedIo(gpa);
        defer threaded.deinit();
        const tio = threaded.io();
        std.Io.Dir.cwd().createDirPath(tio, src_dir) catch |e|
            return .{ .err = fail(gpa, "{s}", .{@errorName(e)}) };
    }

    const klio_toml = std.fmt.allocPrint(gpa,
        "[library]\nid = \"{s}\"\nversion = \"0.1.0\"\nabi = 1\nimplicit_packages = []\nsource_roots = [\"src/main/kotlin\"]\n\n[[deps]]\nid = \"stdlib\"\n\n" ++
            "# Map FQN to host_symbol for any native binding the host registers.\n# Omit the table when the library is pure Kotlin.\n# [bindings]\n# \"{s}.example.hello\" = \"{s}.example.hello\"\n",
        .{ id, id, id },
    ) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(klio_toml);
    const toml_path = std.fs.path.join(gpa, &.{ dir, "klio.toml" }) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(toml_path);
    switch (writeFileWithParents(gpa, toml_path, klio_toml)) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }

    const pkg = sanitizePackage(gpa, id) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(pkg);
    const sample = std.fmt.allocPrint(gpa, "package {s}\n\nfun greet(name: String): String = \"hello, $name\"\n", .{pkg}) catch
        return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(sample);
    const sample_path = std.fs.path.join(gpa, &.{ src_dir, "Sample.kt" }) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(sample_path);
    switch (writeFileWithParents(gpa, sample_path, sample)) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }

    const readme = std.fmt.allocPrint(gpa,
        "# {s}\n\nA klio pack scaffold.\n\nBuild:\n\n    klio pack build .\n\nInstall:\n\n    klio pack install target/packs/{s}.klio-pack\n\nUse from a program:\n\n    import {s}.greet\n    fun main() {{ println(greet(\"world\")) }}\n",
        .{ id, id, pkg },
    ) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(readme);
    const readme_path = std.fs.path.join(gpa, &.{ dir, "README.md" }) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    defer gpa.free(readme_path);
    switch (writeFileWithParents(gpa, readme_path, readme)) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    return .{ .ok = {} };
}

fn sanitizePackage(gpa: std.mem.Allocator, id: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, id.len);
    for (id, out) |c, *o| {
        o.* = if (std.ascii.isAlphanumeric(c) or c == '.') c else '_';
    }
    return out;
}

// ---------------------------------------------------------------------
// stdlib pack
// ---------------------------------------------------------------------

fn buildStdlibPack(gpa: std.mem.Allocator, compress_symbols: bool) Outcome([]u8) {
    var err: PackError = undefined;
    var bytes = (stdlib.build_stdlib_pack(gpa, compress_symbols, &err) catch
        return .{ .err = fail(gpa, "out of memory", .{}) }) orelse
        return .{ .err = packErrText(gpa, err) };
    defer bytes.deinit(gpa);
    return .{ .ok = gpa.dupe(u8, bytes.items) catch return .{ .err = fail(gpa, "out of memory", .{}) } };
}

// ---------------------------------------------------------------------
// source-root walk + filtering
// ---------------------------------------------------------------------

/// One source root with optional include/exclude filtering, used by the
/// `[[source]]` manifest table. See `patMatch` for the supported pattern
/// forms.
pub const SourceRoot = struct {
    root: []const u8,
    include: [][]const u8 = &.{},
    exclude: [][]const u8 = &.{},
};

/// Match `rel` (a slash-normalized path relative to a source root)
/// against a single pattern.
pub fn patMatch(rel: []const u8, pat: []const u8) bool {
    if (pat.len > 0 and pat[pat.len - 1] == '/') {
        // Directory prefix: the directory itself or anything under it.
        const prefix = pat[0 .. pat.len - 1];
        return std.mem.eql(u8, rel, prefix) or std.mem.startsWith(u8, rel, pat);
    }
    if (pat.len > 0 and pat[0] == '*') {
        // Suffix glob.
        return std.mem.endsWith(u8, rel, pat[1..]);
    }
    if (pat.len > 0 and pat[pat.len - 1] == '*') {
        // Prefix glob.
        return std.mem.startsWith(u8, rel, pat[0 .. pat.len - 1]);
    }
    // Exact match.
    return std.mem.eql(u8, rel, pat);
}

/// Walk every root in `roots` for `.kt` files, applying each root's
/// include/exclude rules, and return the collected source files sorted by
/// crate-dir-relative path. `dir` is the directory holding `klio.toml`.
/// All returned strings are allocated from `a`.
pub fn collectPackSources(
    a: std.mem.Allocator,
    dir: []const u8,
    roots: []const SourceRoot,
) Outcome([]schema.SourceFile) {
    var files: std.ArrayList(schema.SourceFile) = .empty;
    var seen = std.StringHashMap(void).init(a);

    var threaded = threadedIo(a);
    defer threaded.deinit();
    const tio = threaded.io();

    for (roots) |sr| {
        const root_path = std.fs.path.join(a, &.{ dir, sr.root }) catch return .{ .err = fail(a, "out of memory", .{}) };
        var root_dir = std.Io.Dir.cwd().openDir(tio, root_path, .{ .iterate = true }) catch continue;
        defer root_dir.close(tio);

        // Collect this root's entries, then sort by file path so the order
        // matches walkdir's `sort_by_file_name` before the final rel sort.
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(a);
        var walker = root_dir.walk(a) catch return .{ .err = fail(a, "walk {s}: out of memory", .{root_path}) };
        defer walker.deinit();
        while (walker.next(tio) catch
            return .{ .err = fail(a, "walk {s}: read error", .{root_path}) }) |entry|
        {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".kt")) continue;
            paths.append(a, a.dupe(u8, entry.path) catch return .{ .err = fail(a, "out of memory", .{}) }) catch
                return .{ .err = fail(a, "out of memory", .{}) };
        }
        std.mem.sort([]const u8, paths.items, {}, lessStr);

        for (paths.items) |rel_to_root_raw| {
            // Normalize backslashes (Windows) -> slashes for matching.
            const rel_to_root = normalizeSlashes(a, rel_to_root_raw) catch return .{ .err = fail(a, "out of memory", .{}) };
            const included = sr.include.len == 0 or anyMatch(rel_to_root, sr.include);
            if (!included) continue;
            if (anyMatch(rel_to_root, sr.exclude)) continue;

            // Crate-dir-relative path (`<root>/<rel_to_root>`).
            const rel = std.fs.path.join(a, &.{ sr.root, rel_to_root }) catch return .{ .err = fail(a, "out of memory", .{}) };
            const gop = seen.getOrPut(rel) catch return .{ .err = fail(a, "out of memory", .{}) };
            if (gop.found_existing) continue;

            const abs = std.fs.path.join(a, &.{ root_path, rel_to_root }) catch return .{ .err = fail(a, "out of memory", .{}) };
            const bytes = std.Io.Dir.cwd().readFileAlloc(tio, abs, a, .unlimited) catch
                return .{ .err = fail(a, "read {s}: unreadable", .{abs}) };
            files.append(a, .{ .rel_path = rel, .bytes = bytes }) catch return .{ .err = fail(a, "out of memory", .{}) };
        }
    }
    const slice = files.toOwnedSlice(a) catch return .{ .err = fail(a, "out of memory", .{}) };
    std.mem.sort(schema.SourceFile, slice, {}, lessSourceFile);
    return .{ .ok = slice };
}

fn anyMatch(rel: []const u8, pats: []const []const u8) bool {
    for (pats) |p| {
        if (patMatch(rel, p)) return true;
    }
    return false;
}

fn normalizeSlashes(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessSourceFile(_: void, a: schema.SourceFile, b: schema.SourceFile) bool {
    return std.mem.order(u8, a.rel_path, b.rel_path) == .lt;
}

// ---------------------------------------------------------------------
// klio.toml model + parser
// ---------------------------------------------------------------------

const BindingValue = union(enum) {
    Symbol: []const u8,
    Detailed: struct {
        host_symbol: []const u8,
        kind: ?[]const u8 = null,
        overrides_interpreter: bool = true,
        platform_actual: bool = false,
    },
};

const BindingPair = struct { fqn: []const u8, value: BindingValue };

const LibraryHeader = struct {
    id: []const u8 = "",
    version: []const u8 = "",
    abi: u32 = 1,
    implicit_packages: [][]const u8 = &.{},
    source_roots: [][]const u8 = &.{},
    auto_bindings: bool = false,
    binding_auto_prefixes: [][]const u8 = &.{},
};

const DepEntry = struct {
    id: []const u8 = "",
    min_version: []const u8 = "",
    features: [][]const u8 = &.{},
    default_features: bool = true,
};

const FeatureTomlDef = struct {
    name: []const u8,
    sources: [][]const u8 = &.{},
    deps: [][]const u8 = &.{},
    requires: [][]const u8 = &.{},
};

const FeaturesToml = struct {
    default: [][]const u8 = &.{},
    defs: []FeatureTomlDef = &.{},
};

const LibraryToml = struct {
    library: LibraryHeader = .{},
    deps: []DepEntry = &.{},
    bindings: []BindingPair = &.{},
    source: []SourceRoot = &.{},
    features: FeaturesToml = .{},
};

/// Minimal TOML reader for the `klio.toml` shape the builder consumes:
/// `[library]`, `[[deps]]`, `[bindings]`, `[[source]]`, `[features]`, and
/// `[features.<name>]` tables. Values are bare scalars, double-quoted
/// strings, or single-line arrays of double-quoted strings. Comments
/// (`#`) and blank lines are skipped. Parses into `a`. Returns the error
/// text on a malformed document.
fn parseLibraryToml(a: std.mem.Allocator, text: []const u8) Outcome(LibraryToml) {
    var cfg = LibraryToml{};
    var deps: std.ArrayList(DepEntry) = .empty;
    var bindings: std.ArrayList(BindingPair) = .empty;
    var sources: std.ArrayList(SourceRoot) = .empty;
    var feature_defs: std.ArrayList(FeatureTomlDef) = .empty;

    // Section context: which table the following key/value lines fill.
    const Section = enum { none, library, dep, bindings, source, features, feature_def };
    var section: Section = .none;

    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw_line| {
        const line = stripComment(std.mem.trim(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (std.mem.startsWith(u8, line, "[[")) {
                const name = std.mem.trim(u8, line[2 .. line.len - 2], " \t");
                if (std.mem.eql(u8, name, "deps")) {
                    section = .dep;
                    deps.append(a, .{}) catch return .{ .err = fail(a, "out of memory", .{}) };
                } else if (std.mem.eql(u8, name, "source")) {
                    section = .source;
                    sources.append(a, .{ .root = "" }) catch return .{ .err = fail(a, "out of memory", .{}) };
                } else {
                    section = .none;
                }
            } else {
                const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
                if (std.mem.eql(u8, name, "library")) {
                    section = .library;
                } else if (std.mem.eql(u8, name, "bindings")) {
                    section = .bindings;
                } else if (std.mem.eql(u8, name, "features")) {
                    section = .features;
                } else if (std.mem.startsWith(u8, name, "features.")) {
                    section = .feature_def;
                    feature_defs.append(a, .{ .name = a.dupe(u8, name["features.".len..]) catch "" }) catch
                        return .{ .err = fail(a, "out of memory", .{}) };
                } else {
                    section = .none;
                }
            }
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse
            return .{ .err = fail(a, "malformed line in klio.toml: `{s}`", .{line}) };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        switch (section) {
            .none => {},
            .library => assignLibrary(a, &cfg.library, key, val),
            .dep => assignDep(a, &deps.items[deps.items.len - 1], key, val),
            .bindings => {
                const pair = parseBindingPair(a, key, val) catch return .{ .err = fail(a, "out of memory", .{}) };
                bindings.append(a, pair) catch return .{ .err = fail(a, "out of memory", .{}) };
            },
            .source => assignSource(a, &sources.items[sources.items.len - 1], key, val),
            .features => {
                if (std.mem.eql(u8, key, "default")) {
                    cfg.features.default = parseStrArray(a, val) catch return .{ .err = fail(a, "out of memory", .{}) };
                }
            },
            .feature_def => assignFeatureDef(a, &feature_defs.items[feature_defs.items.len - 1], key, val),
        }
    }

    cfg.deps = deps.toOwnedSlice(a) catch return .{ .err = fail(a, "out of memory", .{}) };
    // Bindings sort by FQN so the `[bindings]` table is order-independent,
    // mirroring serde's BTreeMap.
    std.mem.sort(BindingPair, bindings.items, {}, lessBindingPair);
    cfg.bindings = bindings.toOwnedSlice(a) catch return .{ .err = fail(a, "out of memory", .{}) };
    cfg.source = sources.toOwnedSlice(a) catch return .{ .err = fail(a, "out of memory", .{}) };
    std.mem.sort(FeatureTomlDef, feature_defs.items, {}, lessFeatureDef);
    cfg.features.defs = feature_defs.toOwnedSlice(a) catch return .{ .err = fail(a, "out of memory", .{}) };
    return .{ .ok = cfg };
}

fn lessBindingPair(_: void, a: BindingPair, b: BindingPair) bool {
    return std.mem.order(u8, a.fqn, b.fqn) == .lt;
}

fn lessFeatureDef(_: void, a: FeatureTomlDef, b: FeatureTomlDef) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn stripComment(line: []const u8) []const u8 {
    // A `#` outside a quoted string starts a comment.
    var in_str = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_str = !in_str;
        if (c == '#' and !in_str) return std.mem.trim(u8, line[0..i], " \t");
    }
    return line;
}

/// Unquote a double-quoted scalar; bare scalars pass through. Duplicated
/// into `a` so the result outlives the source text.
fn tomlString(a: std.mem.Allocator, val: []const u8) []const u8 {
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
        return a.dupe(u8, val[1 .. val.len - 1]) catch "";
    }
    return a.dupe(u8, val) catch "";
}

fn tomlBool(val: []const u8) bool {
    return std.mem.eql(u8, val, "true");
}

fn tomlU32(val: []const u8) u32 {
    return std.fmt.parseInt(u32, val, 10) catch 0;
}

/// Parse a single-line array of double-quoted strings into `a`.
fn parseStrArray(a: std.mem.Allocator, val: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const trimmed = std.mem.trim(u8, val, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[') return out.toOwnedSlice(a);
    const inner = trimmed[1 .. trimmed.len - 1];
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw| {
        const e = std.mem.trim(u8, raw, " \t");
        if (e.len == 0) continue;
        try out.append(a, tomlString(a, e));
    }
    return out.toOwnedSlice(a);
}

fn assignLibrary(a: std.mem.Allocator, h: *LibraryHeader, key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "id")) {
        h.id = tomlString(a, val);
    } else if (std.mem.eql(u8, key, "version")) {
        h.version = tomlString(a, val);
    } else if (std.mem.eql(u8, key, "abi")) {
        h.abi = tomlU32(val);
    } else if (std.mem.eql(u8, key, "implicit_packages")) {
        h.implicit_packages = parseStrArray(a, val) catch &.{};
    } else if (std.mem.eql(u8, key, "source_roots")) {
        h.source_roots = parseStrArray(a, val) catch &.{};
    } else if (std.mem.eql(u8, key, "auto_bindings")) {
        h.auto_bindings = tomlBool(val);
    } else if (std.mem.eql(u8, key, "binding_auto_prefixes")) {
        h.binding_auto_prefixes = parseStrArray(a, val) catch &.{};
    }
}

fn assignDep(a: std.mem.Allocator, d: *DepEntry, key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "id")) {
        d.id = tomlString(a, val);
    } else if (std.mem.eql(u8, key, "min_version")) {
        d.min_version = tomlString(a, val);
    } else if (std.mem.eql(u8, key, "features")) {
        d.features = parseStrArray(a, val) catch &.{};
    } else if (std.mem.eql(u8, key, "default_features")) {
        d.default_features = tomlBool(val);
    }
}

fn assignSource(a: std.mem.Allocator, s: *SourceRoot, key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "root")) {
        s.root = tomlString(a, val);
    } else if (std.mem.eql(u8, key, "include")) {
        s.include = parseStrArray(a, val) catch &.{};
    } else if (std.mem.eql(u8, key, "exclude")) {
        s.exclude = parseStrArray(a, val) catch &.{};
    }
}

fn assignFeatureDef(a: std.mem.Allocator, f: *FeatureTomlDef, key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "sources")) {
        f.sources = parseStrArray(a, val) catch &.{};
    } else if (std.mem.eql(u8, key, "deps")) {
        f.deps = parseStrArray(a, val) catch &.{};
    } else if (std.mem.eql(u8, key, "requires")) {
        f.requires = parseStrArray(a, val) catch &.{};
    }
}

/// One `[bindings]` entry: `"fqn" = "host_symbol"` (the Symbol form) or
/// `"fqn" = { host_symbol = "...", kind = "...", overrides_interpreter =
/// .., platform_actual = .. }` (the Detailed form).
fn parseBindingPair(a: std.mem.Allocator, key: []const u8, val: []const u8) !BindingPair {
    const fqn = tomlString(a, key);
    const trimmed = std.mem.trim(u8, val, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '{') {
        var detailed: @FieldType(BindingValue, "Detailed") = .{ .host_symbol = "" };
        const inner = trimmed[1 .. trimmed.len - 1];
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |raw| {
            const field = std.mem.trim(u8, raw, " \t");
            if (field.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            const fk = std.mem.trim(u8, field[0..eq], " \t");
            const fv = std.mem.trim(u8, field[eq + 1 ..], " \t");
            if (std.mem.eql(u8, fk, "host_symbol")) {
                detailed.host_symbol = tomlString(a, fv);
            } else if (std.mem.eql(u8, fk, "kind")) {
                detailed.kind = tomlString(a, fv);
            } else if (std.mem.eql(u8, fk, "overrides_interpreter")) {
                detailed.overrides_interpreter = tomlBool(fv);
            } else if (std.mem.eql(u8, fk, "platform_actual")) {
                detailed.platform_actual = tomlBool(fv);
            }
        }
        return .{ .fqn = fqn, .value = .{ .Detailed = detailed } };
    }
    return .{ .fqn = fqn, .value = .{ .Symbol = tomlString(a, val) } };
}

// ---------------------------------------------------------------------
// frozen front-end bundles
// ---------------------------------------------------------------------

/// Parse every source file at pack-build time. Files that fail to lex or
/// parse are dropped from the returned bundle; the loader falls back to
/// the `sources` section to re-parse them later. Spans inside the bundle
/// carry `SourceMap` `FileId`s allocated during the build. Allocated from
/// `a`.
fn buildAstBundle(a: std.mem.Allocator, files: []const schema.SourceFile) schema.AstBundle {
    var out_files: std.ArrayList(schema.AstFile) = .empty;
    var map = SourceMap.init(a);
    for (files) |f| {
        const id = map.add(f.rel_path, f.bytes) catch continue;
        const src = map.get(id).source;
        var lx = Lexer.init(a, id, src) catch continue;
        var lexed = lx.tokenize() catch continue;
        if (lexed.diagnostics.hasErrors()) continue;
        const p = Parser.new(a, id, src, lexed.tokens);
        const file_ast = p.parseFile();
        if (p.diagnostics.hasErrors()) continue;
        out_files.append(a, .{
            .rel_path = a.dupe(u8, f.rel_path) catch continue,
            .kotlin_file = file_ast,
        }) catch continue;
    }
    return .{ .files = out_files.toOwnedSlice(a) catch &.{} };
}

/// Run typecheck over the parsed AST bundle and produce the
/// per-expression type map. Best-effort: any file whose typecheck reports
/// errors causes the whole bundle to be skipped, mirroring the Rust
/// builder. Allocated from `a`.
fn buildTypeckBundle(a: std.mem.Allocator, asts: []const KotlinFile) schema.TypeckBundle {
    if (asts.len == 0) return .{};
    var r = resolver.resolveModule(a, asts) catch return .{};
    var tc = typeck.typecheckModule(a, asts, &r) catch return .{};
    if (tc.diagnostics.hasErrors()) return .{};

    var entries: std.ArrayList(schema.TypeckEntry) = .empty;
    var it = tc.types.iterator();
    while (it.next()) |kv| {
        entries.append(a, .{
            .span = kv.key_ptr.*,
            .ty = kv.value_ptr.clone(a) catch continue,
        }) catch continue;
    }
    std.mem.sort(schema.TypeckEntry, entries.items, {}, lessTypeckEntry);
    return .{ .entries = entries.toOwnedSlice(a) catch &.{} };
}

fn lessTypeckEntry(_: void, a: schema.TypeckEntry, b: schema.TypeckEntry) bool {
    if (a.span.file.int() != b.span.file.int()) return a.span.file.int() < b.span.file.int();
    if (a.span.start != b.span.start) return a.span.start < b.span.start;
    return a.span.end < b.span.end;
}

// ---------------------------------------------------------------------
// bindings
// ---------------------------------------------------------------------

/// Build the sorted binding list for a pack: the explicit `[bindings]`
/// entries from `klio.toml` plus, when `auto_bindings` is set, every
/// `merged_host_bindings` entry whose FQN matches a configured prefix.
/// Allocated from `a`.
fn collectPackBindings(
    a: std.mem.Allocator,
    binding_cfg: []const BindingPair,
    library: *const LibraryHeader,
) []schema.Binding {
    var bindings: std.ArrayList(schema.Binding) = .empty;
    for (binding_cfg) |pair| {
        const host_symbol: []const u8, const overrides_interpreter: bool, const platform_actual: bool = switch (pair.value) {
            .Symbol => |s| .{ s, true, false },
            .Detailed => |d| .{ d.host_symbol, d.overrides_interpreter, d.platform_actual },
        };
        bindings.append(a, .{
            .fqn = pair.fqn,
            .kind = .Function,
            .host_symbol = host_symbol,
            .overrides_interpreter = overrides_interpreter,
            .purity = .Effectful,
            .min_arity = 0,
            .max_arity = std.math.maxInt(u8),
            .platform_actual = platform_actual,
        }) catch return bindings.items;
    }

    // Auto-emit: pull every entry from `merged_host_bindings` whose FQN
    // matches a configured prefix.
    if (library.auto_bindings) {
        var prefixes: std.ArrayList([]const u8) = .empty;
        if (library.binding_auto_prefixes.len == 0) {
            prefixes.append(a, std.fmt.allocPrint(a, "{s}.", .{library.id}) catch "") catch {};
        } else {
            for (library.binding_auto_prefixes) |p| {
                const pre = if (p.len > 0 and p[p.len - 1] == '.')
                    a.dupe(u8, p) catch ""
                else
                    std.fmt.allocPrint(a, "{s}.", .{p}) catch "";
                prefixes.append(a, pre) catch {};
            }
        }
        var host = mergedHostBindings(a);
        defer host.deinit();
        var known = std.StringHashMap(void).init(a);
        for (bindings.items) |b| known.put(b.fqn, {}) catch {};

        var hit = host.table.iterator();
        while (hit.next()) |entry| {
            const host_symbol = entry.key_ptr.*;
            var matched = false;
            for (prefixes.items) |pre| {
                if (std.mem.startsWith(u8, host_symbol, pre)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
            if (known.contains(host_symbol)) continue;
            const fqn = a.dupe(u8, host_symbol) catch continue;
            bindings.append(a, .{
                .fqn = fqn,
                .kind = .Function,
                .host_symbol = fqn,
                .overrides_interpreter = true,
                .purity = .Effectful,
                .min_arity = 0,
                .max_arity = std.math.maxInt(u8),
                .platform_actual = false,
            }) catch break;
        }
    }
    std.mem.sort(schema.Binding, bindings.items, {}, lessBinding);
    return bindings.toOwnedSlice(a) catch bindings.items;
}

fn lessBinding(_: void, a: schema.Binding, b: schema.Binding) bool {
    return std.mem.order(u8, a.fqn, b.fqn) == .lt;
}

// ---------------------------------------------------------------------
// build library pack
// ---------------------------------------------------------------------

fn buildLibraryPack(gpa: std.mem.Allocator, dir: []const u8, out: ?[]const u8) PathResult {
    // Everything the build allocates lives in this arena and is freed at
    // scope exit, matching the Rust function's drop-at-return ownership.
    // The single survivor is the returned `out_path`, allocated from gpa.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const toml_path = std.fs.path.join(a, &.{ dir, "klio.toml" }) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    const toml_str = readFileOwned(a, toml_path) orelse
        return .{ .err = fail(gpa, "read {s}: file unreadable", .{toml_path}) };

    const cfg_res = parseLibraryToml(a, toml_str);
    switch (cfg_res) {
        .err => |e| return .{ .err = gpa.dupe(u8, e) catch @constCast("out of memory") },
        .ok => {},
    }
    const cfg = cfg_res.ok;

    // Source files. The plain `source_roots` strings become unfiltered
    // roots; the `[[source]]` tables follow with their include/exclude
    // rules.
    var effective: std.ArrayList(SourceRoot) = .empty;
    if (cfg.library.source_roots.len == 0 and cfg.source.len == 0) {
        effective.append(a, .{ .root = "src" }) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    } else {
        for (cfg.library.source_roots) |root| {
            effective.append(a, .{ .root = root }) catch return .{ .err = fail(gpa, "out of memory", .{}) };
        }
    }
    for (cfg.source) |s| {
        effective.append(a, s) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    }

    const files_res = collectPackSources(a, dir, effective.items);
    switch (files_res) {
        .err => |e| return .{ .err = gpa.dupe(u8, e) catch @constCast("out of memory") },
        .ok => {},
    }
    const files = files_res.ok;

    // Manifest.
    const feature_defs = a.alloc(schema.FeatureDef, cfg.features.defs.len) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    for (cfg.features.defs, feature_defs) |src, *dst| {
        dst.* = .{ .name = src.name, .sources = src.sources, .deps = src.deps, .requires = src.requires };
    }
    const dependencies = a.alloc(schema.PackDependency, cfg.deps.len) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    for (cfg.deps, dependencies) |d, *dst| {
        dst.* = .{
            .library_id = d.id,
            .min_version = d.min_version,
            .features = d.features,
            .default_features = d.default_features,
        };
    }
    const manifest = schema.PackManifest{
        .library_id = cfg.library.id,
        .library_version = cfg.library.version,
        .abi_version = cfg.library.abi,
        .implicit_packages = cfg.library.implicit_packages,
        .dependencies = dependencies,
        .default_features = cfg.features.default,
        .features = feature_defs,
    };
    var perr: PackError = undefined;
    const manifest_bytes = (schema.encode(schema.PackManifest, a, &manifest, &perr) catch
        return .{ .err = fail(gpa, "out of memory", .{}) }) orelse return .{ .err = packErrText(gpa, perr) };

    // Bindings.
    const bindings = collectPackBindings(a, cfg.bindings, &cfg.library);
    const binding_manifest = schema.BindingManifest{ .bindings = bindings };
    const bindings_bytes = (schema.encode(schema.BindingManifest, a, &binding_manifest, &perr) catch
        return .{ .err = fail(gpa, "out of memory", .{}) }) orelse return .{ .err = packErrText(gpa, perr) };

    // Sources.
    const source_bundle = schema.SourceBundle{ .files = files };
    const sources_bytes = (schema.encode(schema.SourceBundle, a, &source_bundle, &perr) catch
        return .{ .err = fail(gpa, "out of memory", .{}) }) orelse return .{ .err = packErrText(gpa, perr) };

    // Frozen AST.
    const ast_bundle = buildAstBundle(a, files);
    const ast_bytes = (schema.encode(schema.AstBundle, a, &ast_bundle, &perr) catch
        return .{ .err = fail(gpa, "out of memory", .{}) }) orelse return .{ .err = packErrText(gpa, perr) };

    // Frozen typeck. Collect the parsed `KotlinFile`s directly; the Rust
    // builder cloned them, but in the arena the bundle's files outlive
    // this call, so a borrow is faithful and cheaper.
    const asts = a.alloc(KotlinFile, ast_bundle.files.len) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    for (ast_bundle.files, asts) |f, *dst| dst.* = f.kotlin_file;
    const typeck_bundle = buildTypeckBundle(a, asts);
    const typeck_bytes = (schema.encode(schema.TypeckBundle, a, &typeck_bundle, &perr) catch
        return .{ .err = fail(gpa, "out of memory", .{}) }) orelse return .{ .err = packErrText(gpa, perr) };

    // Assemble. The Rust builder zstd-compressed SOURCES/AST/TYPECK; this
    // build has no zstd codec, so every section is stored uncompressed.
    var writer = PackWriter.init(a);
    defer writer.deinit();
    _ = writer.addRaw(section_names.MANIFEST, manifest_bytes.items) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    _ = writer.addRaw(section_names.BINDINGS, bindings_bytes.items) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    _ = writer.addSection(section_names.SOURCES, sources_bytes.items, .None) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    _ = writer.addSection(section_names.AST, ast_bytes.items, .None) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    _ = writer.addSection(section_names.TYPECK, typeck_bytes.items, .None) catch return .{ .err = fail(gpa, "out of memory", .{}) };
    var pack_bytes = (writer.finish(&perr) catch
        return .{ .err = fail(gpa, "out of memory", .{}) }) orelse return .{ .err = packErrText(gpa, perr) };
    defer pack_bytes.deinit(a);

    const out_path: []u8 = if (out) |o|
        gpa.dupe(u8, o) catch return .{ .err = fail(gpa, "out of memory", .{}) }
    else
        std.fmt.allocPrint(gpa, "target/packs/{s}.klio-pack", .{cfg.library.id}) catch
            return .{ .err = fail(gpa, "out of memory", .{}) };
    switch (writeFileWithParents(gpa, out_path, pack_bytes.items)) {
        .err => |e| {
            gpa.free(out_path);
            return .{ .err = e };
        },
        .ok => {},
    }
    return .{ .ok = out_path };
}

fn writePack(gpa: std.mem.Allocator, out: []const u8, bytes: []const u8) VoidResult {
    return writeFileWithParents(gpa, out, bytes);
}

// ---------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------

test "pack cmd tag names" {
    const c: PackCmd = .List;
    try std.testing.expectEqualStrings("List", @tagName(c));
}

test "pat_match: exact, directory prefix, suffix glob, prefix glob" {
    // Exact.
    try std.testing.expect(patMatch("Buffer.kt", "Buffer.kt"));
    try std.testing.expect(!patMatch("Buffer.kt", "Other.kt"));
    // Directory prefix.
    try std.testing.expect(patMatch("files", "files/"));
    try std.testing.expect(patMatch("files/Foo.kt", "files/"));
    try std.testing.expect(!patMatch("filesystem/Foo.kt", "files/"));
    // Suffix glob.
    try std.testing.expect(patMatch("a/b/Foo.kt", "*.kt"));
    try std.testing.expect(patMatch("a/b/PlatformWindows.kt", "*Windows.kt"));
    try std.testing.expect(!patMatch("a/b/Foo.java", "*.kt"));
    // Prefix glob.
    try std.testing.expect(patMatch("internal/Utf8.kt", "internal/*"));
    try std.testing.expect(!patMatch("public/Utf8.kt", "internal/*"));
}

test "sanitizePackage replaces non-alnum, keeps dots" {
    const gpa = std.testing.allocator;
    const out = try sanitizePackage(gpa, "io.ktor-client.2");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("io.ktor_client.2", out);
}

test "parseLibraryToml reads header, deps, bindings, source, features" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\[library]
        \\id = "myorg.crypto"
        \\version = "1.2.3"
        \\abi = 2
        \\implicit_packages = ["myorg.crypto"]
        \\source_roots = ["src/main/kotlin"]
        \\auto_bindings = true
        \\
        \\[[deps]]
        \\id = "stdlib"
        \\
        \\[[deps]]
        \\id = "kotlinx.io"
        \\min_version = "0.3.0"
        \\features = ["files"]
        \\
        \\[bindings]
        \\"myorg.crypto.hash" = "myorg.crypto.hash"
        \\"myorg.crypto.hmac" = { host_symbol = "myorg.crypto.hmac", platform_actual = true }
        \\
        \\[[source]]
        \\root = "extra"
        \\include = ["*.kt"]
        \\exclude = ["Bench.kt"]
        \\
        \\[features]
        \\default = ["core"]
        \\
        \\[features.json]
        \\sources = ["shim/json"]
        \\requires = ["core"]
        \\
    ;
    const res = parseLibraryToml(a, text);
    const cfg = switch (res) {
        .ok => |c| c,
        .err => return error.TestParseFailed,
    };
    try std.testing.expectEqualStrings("myorg.crypto", cfg.library.id);
    try std.testing.expectEqualStrings("1.2.3", cfg.library.version);
    try std.testing.expectEqual(@as(u32, 2), cfg.library.abi);
    try std.testing.expect(cfg.library.auto_bindings);
    try std.testing.expectEqual(@as(usize, 1), cfg.library.implicit_packages.len);
    try std.testing.expectEqual(@as(usize, 2), cfg.deps.len);
    try std.testing.expectEqualStrings("stdlib", cfg.deps[0].id);
    try std.testing.expectEqualStrings("kotlinx.io", cfg.deps[1].id);
    try std.testing.expectEqualStrings("0.3.0", cfg.deps[1].min_version);
    try std.testing.expectEqual(@as(usize, 1), cfg.deps[1].features.len);
    // Bindings sorted by FQN.
    try std.testing.expectEqual(@as(usize, 2), cfg.bindings.len);
    try std.testing.expectEqualStrings("myorg.crypto.hash", cfg.bindings[0].fqn);
    try std.testing.expectEqualStrings("myorg.crypto.hmac", cfg.bindings[1].fqn);
    try std.testing.expect(cfg.bindings[1].value == .Detailed);
    try std.testing.expect(cfg.bindings[1].value.Detailed.platform_actual);
    try std.testing.expectEqual(@as(usize, 1), cfg.source.len);
    try std.testing.expectEqualStrings("extra", cfg.source[0].root);
    try std.testing.expectEqual(@as(usize, 1), cfg.features.default.len);
    try std.testing.expectEqualStrings("core", cfg.features.default[0]);
    try std.testing.expectEqual(@as(usize, 1), cfg.features.defs.len);
    try std.testing.expectEqualStrings("json", cfg.features.defs[0].name);
}

test "collectPackBindings: explicit entries sorted, then auto when enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pairs = [_]BindingPair{
        .{ .fqn = "z.last", .value = .{ .Symbol = "z.last" } },
        .{ .fqn = "a.first", .value = .{ .Detailed = .{ .host_symbol = "host.a", .overrides_interpreter = false, .platform_actual = true } } },
    };
    const header = LibraryHeader{ .id = "myorg", .auto_bindings = false };
    const out = collectPackBindings(a, &pairs, &header);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("a.first", out[0].fqn);
    try std.testing.expectEqualStrings("host.a", out[0].host_symbol);
    try std.testing.expect(!out[0].overrides_interpreter);
    try std.testing.expect(out[0].platform_actual);
    try std.testing.expectEqualStrings("z.last", out[1].fqn);
    try std.testing.expect(out[1].overrides_interpreter);
}

test "buildAstBundle drops files that fail to parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]schema.SourceFile{
        .{ .rel_path = "ok/Good.kt", .bytes = "package ok\nfun f(): Int = 1\n" },
        .{ .rel_path = "bad/Broken.kt", .bytes = "fun (((\n" },
    };
    const bundle = buildAstBundle(a, &files);
    try std.testing.expectEqual(@as(usize, 1), bundle.files.len);
    try std.testing.expectEqualStrings("ok/Good.kt", bundle.files[0].rel_path);
}

test "registry index round-trips through json" {
    const gpa = std.testing.allocator;
    const entries = [_]RegistryEntry{
        .{ .library_id = "a", .version = "1.0.0", .abi_version = 1, .relative_path = "a/1.0.0/a-1.0.0.klio-pack" },
    };
    const bytes = try std.json.Stringify.valueAlloc(gpa, &entries, .{ .whitespace = .indent_2 });
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice([]RegistryEntry, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualStrings("a", parsed.value[0].library_id);
    try std.testing.expectEqual(@as(u32, 1), parsed.value[0].abi_version);
}
