//! Pack cache + installed-pack loading.
//!
//! Walks the local pack
//! cache, parses each pack the user imports so resolution + type
//! inference see its real signatures, consumes the embedded stdlib's
//! curated sources, and merges every pack's host bindings into a single
//! table the loader installs.

const std = @import("std");
const Allocator = std.mem.Allocator;

const span = @import("span");
const SourceMap = span.SourceMap;

const ast = @import("ast");
const KotlinFile = ast.KotlinFile;

const lexer = @import("lexer");
const parser = @import("parser");

const pack = @import("pack");
const schema = pack.schema;
const section_names = pack.section_names;
const PackReader = pack.PackReader;
const PackError = pack.PackError;

const runtime = @import("runtime");

const stdlib = @import("stdlib");
const HostBindings = stdlib.HostBindings;

const stdlib_pack = @import("stdlib_pack");

const kotlinx_atomicfu = @import("kotlinx_atomicfu");
const kotlinx_io = @import("kotlinx_io");
const kotlinx_datetime = @import("kotlinx_datetime");
const kotlinx_coroutines = @import("kotlinx_coroutines");
const kotlinx_serialization = @import("kotlinx_serialization");
const ktor_client = @import("ktor_client");

const io = @import("io.zig");

/// Per-`library_id` set of feature names a consumer requested (cargo
/// style). Seeds the loader's feature resolution; default features are
/// added on top unless a request opts out.
///
/// Maps `library_id` -> set of requested feature names.
pub const RequestedFeatures = std.StringHashMap(std.StringHashMap(void));

/// Result of loading installed packs: the parsed pack ASTs and the
/// merged host-binding table their `host_symbol` keys resolve against.
pub const LoadedPacks = struct {
    asts: []const KotlinFile,
    bindings: HostBindings,
};

/// What the embedded-stdlib source load saw and did, recorded for the
/// stdlib-image fast path: the package universe behind the load gate, the
/// packages it registered, and the host-binding FQNs it installed. All
/// strings are dupes owned by the loader's allocator.
pub const EmbeddedReport = struct {
    /// Package of every parsed curated source (deduplicated).
    pkgs: std.ArrayList([]const u8) = .empty,
    any_non_implicit: bool = false,
    /// The gate the load used (true = the full curated set loaded).
    gate_full: bool = false,
    /// Packages registered via `stdlib.registerKnownPackage`.
    known_packages: std.ArrayList([]const u8) = .empty,
    /// Host-binding FQNs registered into the installed overlay.
    binding_fqns: std.ArrayList([]const u8) = .empty,
};

/// One pack the loader selected, identified for cache keying: its cache
/// path, the pack's stored content hash, and the resolved active feature
/// names (sorted). Strings are dupes owned by the loader's allocator.
pub const SelectedPack = struct {
    path: []const u8,
    hash: [pack.format.HASH_LEN]u8,
    features: []const []const u8,
};

/// Out-param describing one load for the stdlib-image fast path.
pub const Selection = struct {
    packs: std.ArrayList(SelectedPack) = .empty,
    /// The import-prefix universe at fixpoint end (user imports plus
    /// imports discovered in loaded pack sources); the embedded-stdlib
    /// load gate is a function of this set.
    final_prefixes: std.ArrayList([]const u8) = .empty,
};

/// Knobs for `loadInstalledPacksOpts`.
pub const LoadOptions = struct {
    /// When false, the embedded stdlib sources are skipped entirely (the
    /// caller supplies their lowered form from a baked image) and only
    /// cache packs load.
    include_stdlib: bool = true,
    embedded_report: ?*EmbeddedReport = null,
    selection: ?*Selection = null,
};

/// `Result<PathBuf, String>` carried as data: `ok` is an owned path and
/// `err` an owned message, both freed by the caller with the allocator
/// passed to the producing function.
pub const PathResult = union(enum) {
    ok: []u8,
    err: []u8,
};

/// `Result<(), String>`.
pub const VoidResult = union(enum) {
    ok: void,
    err: []u8,
};

/// `Result<PackManifest, String>`: `ok` carries an owned manifest the
/// caller deinits.
pub const ManifestResult = union(enum) {
    ok: schema.PackManifest,
    err: []u8,
};

// ---------------------------------------------------------------------
// environment access
// ---------------------------------------------------------------------

/// Read one environment variable from the parent process. Returns an
/// owned copy of the value or `null`. Mirrors Rust's `std::env::var_os`
/// for the few variables this module consults (`HOME`, `KLIO_PACK_DIAG`).
fn getEnvVar(allocator: Allocator, name: []const u8) ?[]u8 {
    return runtime.procEnvGetVar(allocator, name) catch null;
}

/// True when `name` is present in the environment (any value), mirroring
/// `std::env::var_os(name).is_some()`.
fn envVarPresent(allocator: Allocator, name: []const u8) bool {
    if (getEnvVar(allocator, name)) |v| {
        allocator.free(v);
        return true;
    }
    return false;
}

/// Build an `Environ.Map` from the parent process environment so the
/// stdlib-pack loader can consult `KLIO_STDLIB_PACK`. Caller deinits.
fn procEnvMap(allocator: Allocator) std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    runtime.procEnvPutAllInto(allocator, &map);
    return map;
}

/// A throwaway threaded `Io` for filesystem work inside a single call.
fn threadedIo(allocator: Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(allocator, .{});
}

// ---------------------------------------------------------------------
// import-prefix helpers
// ---------------------------------------------------------------------

/// Join an identifier path (`a`, `b`, `c`) into a dotted string
/// (`a.b.c`). Caller owns the result.
fn joinIdentPath(allocator: Allocator, path: []const ast.Ident) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (path, 0..) |id, i| {
        if (i != 0) try buf.append(allocator, '.');
        try buf.appendSlice(allocator, id.name);
    }
    return buf.toOwnedSlice(allocator);
}

/// The set of dotted import prefixes a user's AST files declare. Each
/// key is owned by the returned map's allocator; the caller deinits with
/// `freeStringSet`.
fn collectUserImportPrefixes(
    allocator: Allocator,
    user_asts: []const KotlinFile,
) Allocator.Error!std.StringHashMap(void) {
    var out = std.StringHashMap(void).init(allocator);
    errdefer freeStringSet(&out);
    for (user_asts) |f| {
        for (f.imports) |imp| {
            const joined = try joinIdentPath(allocator, imp.path);
            const gop = try out.getOrPut(joined);
            if (gop.found_existing) {
                allocator.free(joined);
            } else {
                gop.value_ptr.* = {};
            }
        }
    }
    return out;
}

/// Free a `StringHashMap(void)` whose keys are owned by its allocator.
fn freeStringSet(set: *std.StringHashMap(void)) void {
    var it = set.keyIterator();
    while (it.next()) |k| set.allocator.free(k.*);
    set.deinit();
}

/// The package path declared by an AST file's `package` header (empty
/// when absent). Caller owns the result.
fn packagePathOf(allocator: Allocator, file: KotlinFile) Allocator.Error![]u8 {
    if (file.package) |p| {
        return joinIdentPath(allocator, p.path);
    }
    return allocator.dupe(u8, "");
}

// ---------------------------------------------------------------------
// embedded stdlib sources
// ---------------------------------------------------------------------

/// Consume the **embedded** stdlib pack's `SOURCES` section (the curated
/// upstream commonMain + klio actuals — today `kotlin.time`).
///
/// The embedded stdlib pack's `SYMBOLS` / `BINDINGS` are already
/// statically linked into the interpreter (the cache loop deliberately
/// skips any on-disk `stdlib*` pack so they are not double-loaded);
/// those sections are intentionally NOT touched here. This step only
/// parses the Kotlin `SOURCES` and pushes the resulting ASTs into the
/// module + registers their packages, so a program importing a package
/// these sources provide resolves against real upstream Kotlin.
///
/// Gated on the user's imports: the curated set is loaded only when a
/// user import matches one of the packages those sources declare (prefix
/// match). Programs that never import such a package pay nothing.
fn loadEmbeddedStdlibSources(
    allocator: Allocator,
    user_import_prefixes: *const std.StringHashMap(void),
    source_map: *SourceMap,
    out_asts: *std.ArrayList(KotlinFile),
    out_bindings: *HostBindings,
    report: ?*EmbeddedReport,
) Allocator.Error!void {
    var env = procEnvMap(allocator);
    defer env.deinit();
    var err: PackError = undefined;
    const bytes = (stdlib_pack.stdlibPackBytes(allocator, &env, &err) catch return) orelse return;
    var reader = (PackReader.fromBytes(allocator, bytes, &err) catch return) orelse return;
    defer reader.deinit();
    const payload = (reader.readSection(section_names.SOURCES, &err) catch return) orelse return;
    defer payload.deinit(allocator);
    var bundle = (schema.decode(schema.SourceBundle, allocator, payload.slice(), &err) catch return) orelse return;
    defer bundle.deinit(allocator);
    if (bundle.files.len == 0) return;

    const diag = envVarPresent(allocator, "KLIO_PACK_DIAG");

    // Parse each source once, recording its package header. The curated
    // set is an interdependent unit, so it is all-or-nothing: load every
    // file iff some user import matches any package the set declares.
    const Parsed = struct { pkg: []u8, file: KotlinFile };
    var parsed: std.ArrayList(Parsed) = .empty;
    defer {
        for (parsed.items) |p| allocator.free(p.pkg);
        parsed.deinit(allocator);
    }

    for (bundle.files) |sf| {
        // Consumption deferral: sources that PARSE but whose interpreted
        // declarations would shadow — and currently conflict with —
        // klio's host intrinsics. The intrinsics serve these APIs until
        // the source bodies interoperate.
        if (stdlib.isConsumptionDeferredSource(sf.rel_path)) continue;
        if (diag and (std.mem.indexOf(u8, sf.rel_path, "Maps.kt") != null or
            std.mem.indexOf(u8, sf.rel_path, "Sets.kt") != null))
        {
            io.printStderr(allocator, "[embed source] {s}\n", .{sf.rel_path});
        }
        const fid = source_map.add(sf.rel_path, sf.bytes) catch continue;
        const src = source_map.get(fid).source;
        var lx = lexer.Lexer.init(allocator, fid, src) catch continue;
        var lexed = lx.tokenize() catch continue;
        const lex_errors = lexed.diagnostics.hasErrors();
        if (lex_errors) {
            if (diag) {
                io.printStderr(allocator, "[embed lex err] {s}: {d} diags\n", .{
                    sf.rel_path, lexed.diagnostics.diags().len,
                });
            }
            lexed.deinit(allocator);
            continue;
        }
        const p = parser.Parser.new(allocator, fid, src, lexed.tokens);
        const file_ast = p.parseFile();
        if (p.diagnostics.hasErrors()) {
            if (diag) {
                for (p.diagnostics.diags()) |d| {
                    io.printStderr(allocator, "[embed parse err] {s}: {s}\n", .{ sf.rel_path, d.message });
                }
            }
            lexed.deinit(allocator);
            continue;
        }
        lexed.deinit(allocator);
        const pkg = packagePathOf(allocator, file_ast) catch continue;
        parsed.append(allocator, .{ .pkg = pkg, .file = file_ast }) catch {
            allocator.free(pkg);
            continue;
        };
    }

    // Always load files in implicitly-imported packages
    // (kotlin.collections, kotlin.ranges, ...) — they are visible in
    // every source file without an explicit import, so their
    // builders/extensions must be available to user code
    // unconditionally. Other curated sources stay all-or-nothing and
    // gated on a matching user import.
    var any_non_implicit = false;
    for (parsed.items) |p| {
        if (p.pkg.len != 0 and !stdlib.isImplicitlyImportedPackage(p.pkg)) {
            any_non_implicit = true;
            break;
        }
    }
    var imported_match = false;
    for (parsed.items) |p| {
        if (p.pkg.len == 0) continue;
        if (importPrefixMatches(allocator, user_import_prefixes, p.pkg)) {
            imported_match = true;
            break;
        }
    }
    const load_gated = imported_match or !any_non_implicit;

    if (report) |rep| {
        rep.any_non_implicit = any_non_implicit;
        rep.gate_full = load_gated;
        var seen_pkgs = std.StringHashMap(void).init(allocator);
        defer seen_pkgs.deinit();
        for (parsed.items) |p| {
            if (p.pkg.len == 0) continue;
            const gop = try seen_pkgs.getOrPut(p.pkg);
            if (!gop.found_existing) try rep.pkgs.append(allocator, try allocator.dupe(u8, p.pkg));
        }
    }

    for (parsed.items) |p| {
        const is_implicit = p.pkg.len != 0 and stdlib.isImplicitlyImportedPackage(p.pkg);
        if (!is_implicit and !load_gated) continue;
        if (p.pkg.len != 0) {
            stdlib.registerKnownPackage(p.pkg);
            if (report) |rep| try rep.known_packages.append(allocator, try allocator.dupe(u8, p.pkg));
        }
        try out_asts.append(allocator, p.file);
    }

    // The curated sources' klio `actual`s call a couple of `internal`
    // platform helpers whose Kotlin bodies are inert stubs. Register
    // their host bindings into the installed overlay so they shadow the
    // stub bodies at dispatch. These come from the statically-linked
    // stdlib defaults; we do NOT re-load the embedded pack's
    // SYMBOLS/BINDINGS sections.
    var merged = mergedHostBindings(allocator);
    defer merged.deinit();
    const platform_fqns = [_][]const u8{
        "kotlin.time.__klio_time_systemMillis",
        "kotlin.time.__klio_time_monotonicNanos",
        "kotlin.coroutines.__klio_co_newSlot",
        "kotlin.coroutines.__klio_co_park",
        "kotlin.coroutines.__klio_co_resume",
        "kotlin.coroutines.__klio_co_runRoot",
    };
    for (platform_fqns) |fqn| {
        if (merged.resolve(fqn)) |f| {
            try out_bindings.register(fqn, f);
            if (report) |rep| try rep.binding_fqns.append(allocator, try allocator.dupe(u8, fqn));
        }
    }
}

/// True when any prefix in `prefixes` matches `pkg` by the same
/// bidirectional dotted-prefix rule the Rust loader uses: `imp == pkg`,
/// `imp` starts with `pkg.`, or `pkg` starts with `imp.`.
pub fn importPrefixMatches(
    allocator: Allocator,
    prefixes: *const std.StringHashMap(void),
    pkg: []const u8,
) bool {
    var it = prefixes.keyIterator();
    while (it.next()) |imp_ptr| {
        const imp = imp_ptr.*;
        if (std.mem.eql(u8, imp, pkg)) return true;
        if (dottedPrefix(allocator, pkg, imp)) return true;
        if (dottedPrefix(allocator, imp, pkg)) return true;
    }
    return false;
}

/// True when `s` starts with `prefix` followed by a `.` (i.e.
/// `s.starts_with(format!("{prefix}."))`).
fn dottedPrefix(allocator: Allocator, s: []const u8, prefix: []const u8) bool {
    _ = allocator;
    if (s.len <= prefix.len) return false;
    if (!std.mem.startsWith(u8, s, prefix)) return false;
    return s[prefix.len] == '.';
}

// ---------------------------------------------------------------------
// pack candidates + loading
// ---------------------------------------------------------------------

const PackCandidate = struct {
    pack: PackReader,
    manifest: schema.PackManifest,
    /// Cache path of the pack file, for selection identity.
    path: []u8,

    fn deinit(self: *PackCandidate, allocator: Allocator) void {
        self.manifest.deinit(allocator);
        self.pack.deinit();
        allocator.free(self.path);
    }
};

/// Read every `.klio-pack` file in the cache directory (skipping the
/// embedded stdlib) and decode its manifest, yielding the set of
/// candidate packs the fixpoint loader picks from. The returned list and
/// every candidate are owned by the caller.
fn collectPackCandidates(allocator: Allocator, cache: []const u8) Allocator.Error![]PackCandidate {
    var candidates: std.ArrayList(PackCandidate) = .empty;
    errdefer {
        for (candidates.items) |*c| c.deinit(allocator);
        candidates.deinit(allocator);
    }
    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(fio, cache, .{ .iterate = true }) catch
        return candidates.toOwnedSlice(allocator);
    defer dir.close(fio);
    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".klio-pack")) continue;
        if (std.mem.startsWith(u8, entry.name, "stdlib")) continue;
        const path = try std.fs.path.join(allocator, &.{ cache, entry.name });
        var keep_path = false;
        defer if (!keep_path) allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(fio, path, allocator, .unlimited) catch continue;
        var err: PackError = undefined;
        var reader = (PackReader.fromBytes(allocator, bytes, &err) catch continue) orelse continue;
        const payload = (reader.readSection(section_names.MANIFEST, &err) catch {
            reader.deinit();
            continue;
        }) orelse {
            reader.deinit();
            continue;
        };
        const manifest = (schema.decode(schema.PackManifest, allocator, payload.slice(), &err) catch {
            payload.deinit(allocator);
            reader.deinit();
            continue;
        }) orelse {
            payload.deinit(allocator);
            reader.deinit();
            continue;
        };
        payload.deinit(allocator);
        keep_path = true;
        try candidates.append(allocator, .{ .pack = reader, .manifest = manifest, .path = path });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Does `rel_path` fall under any of `sources` (each a path prefix
/// relative to the pack root, e.g. `shim/io/ktor/server`)?
fn sourceInFeature(rel_path: []const u8, sources: [][]const u8) bool {
    for (sources) |pat_raw| {
        const pat = std.mem.trimEnd(u8, pat_raw, "/");
        if (std.mem.eql(u8, rel_path, pat)) return true;
        if (rel_path.len > pat.len and std.mem.startsWith(u8, rel_path, pat) and rel_path[pat.len] == '/') {
            return true;
        }
    }
    return false;
}

/// Compute a pack's active feature set: its default features (unless the
/// request opted out) plus any explicitly requested features, expanded
/// transitively over each feature's `requires`. Caller deinits the set.
fn resolveActiveFeatures(
    allocator: Allocator,
    manifest: *const schema.PackManifest,
    requested: ?*const std.StringHashMap(void),
) Allocator.Error!std.StringHashMap(void) {
    var active = std.StringHashMap(void).init(allocator);
    errdefer active.deinit();
    for (manifest.default_features) |f| {
        try active.put(f, {});
    }
    if (requested) |req| {
        var it = req.keyIterator();
        while (it.next()) |k| try active.put(k.*, {});
    }
    // Transitively pull in `requires` until the set stops growing.
    while (true) {
        var added = false;
        for (manifest.features) |f| {
            if (active.contains(f.name)) {
                for (f.requires) |r| {
                    const gop = try active.getOrPut(r);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = {};
                        added = true;
                    }
                }
            }
        }
        if (!added) break;
    }
    return active;
}

/// True when `rel_path` should load given the pack's features and the
/// active set: a file gated by some feature loads only if an active
/// feature gates it; an ungated (core) file always loads.
fn sourceIsActive(
    rel_path: []const u8,
    manifest: *const schema.PackManifest,
    active: *const std.StringHashMap(void),
) bool {
    var gated = false;
    for (manifest.features) |f| {
        if (sourceInFeature(rel_path, f.sources)) {
            gated = true;
            if (active.contains(f.name)) return true;
        }
    }
    return !gated;
}

/// For an inactive gated file, return `(feature_name, source_prefix)` of
/// the first feature gating it. Used to hint the user which feature to
/// enable. `null` when the file is core or already active. The returned
/// slices borrow from `manifest`.
const Gate = struct { feature: []const u8, prefix: []const u8 };

fn inactiveGate(
    rel_path: []const u8,
    manifest: *const schema.PackManifest,
    active: *const std.StringHashMap(void),
) ?Gate {
    if (sourceIsActive(rel_path, manifest, active)) return null;
    for (manifest.features) |f| {
        for (f.sources) |pat_raw| {
            const p = std.mem.trimEnd(u8, pat_raw, "/");
            if (std.mem.eql(u8, rel_path, p) or
                (rel_path.len > p.len and std.mem.startsWith(u8, rel_path, p) and rel_path[p.len] == '/'))
            {
                return .{ .feature = f.name, .prefix = p };
            }
        }
    }
    return null;
}

/// The Kotlin package declared in a source file, for the feature hint.
/// Scans for the first `package a.b.c` statement; `null` if absent. The
/// result borrows from `bytes`.
fn packageOfSource(bytes: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "package ")) {
            var rest = std.mem.trim(u8, t["package ".len..], " \t\r");
            rest = std.mem.trimEnd(u8, rest, ";");
            rest = std.mem.trim(u8, rest, " \t\r");
            return rest;
        }
    }
    return null;
}

/// Does a user import specifically *target* a (possibly gated) package —
/// i.e. it is that package (`import pkg.*`) or a member of it
/// (`import pkg.Symbol`)? A parent star-import does NOT target it.
fn importMatchesPackage(allocator: Allocator, import: []const u8, pkg: []const u8) bool {
    if (pkg.len == 0) return false;
    if (std.mem.eql(u8, import, pkg)) return true;
    return dottedPrefix(allocator, import, pkg);
}

const FeatureHint = struct {
    lib: []u8,
    feat: []u8,
    pkg: []u8,

    fn deinit(self: FeatureHint, allocator: Allocator) void {
        allocator.free(self.lib);
        allocator.free(self.feat);
        allocator.free(self.pkg);
    }
};

/// Load one resolved pack candidate: register its packages, parse its
/// sources (or fall back to the frozen AST bundle), and wire up its
/// bindings. Imports discovered in the pack's files are appended to
/// `new_imports` so the fixpoint loop can pull in transitive packs.
fn loadPackCandidate(
    allocator: Allocator,
    c: *const PackCandidate,
    lib_id: []const u8,
    merged: *const HostBindings,
    active_features: *const std.StringHashMap(void),
    user_imports: *const std.StringHashMap(void),
    feature_hints: *std.ArrayList(FeatureHint),
    source_map: *SourceMap,
    out_asts: *std.ArrayList(KotlinFile),
    out_bindings: *HostBindings,
    new_imports: *std.ArrayList([]u8),
) Allocator.Error!void {
    const manifest = &c.manifest;
    const reader = &c.pack;
    // Teach the resolver every package this pack ships + declares
    // implicit, so user `import kotlinx.*` lines resolve. Pack manifests
    // carry implicit packages; each AST file's `package` header covers
    // the rest.
    stdlib.registerKnownPackage(manifest.library_id);
    for (manifest.implicit_packages) |p| {
        stdlib.registerKnownPackage(p);
    }
    // Re-parse the pack's Kotlin sources through the shared SourceMap
    // rather than decoding the frozen `ast` section: it assigns each pack
    // file a fresh FileId (spans never collide), and is immune to
    // AST-schema drift. Falls back to the frozen `ast` bundle only when
    // the `sources` section is absent.
    var loaded_from_sources = false;
    var err: PackError = undefined;
    if (reader.readSection(section_names.SOURCES, &err) catch null) |payload| {
        defer payload.deinit(allocator);
        if (schema.decode(schema.SourceBundle, allocator, payload.slice(), &err) catch null) |bundle_val| {
            var bundle = bundle_val;
            defer bundle.deinit(allocator);
            for (bundle.files) |sf| {
                if (stdlib.isConsumptionDeferredSource(sf.rel_path)) continue;
                // Feature gating: a source under an inactive feature's
                // roots is skipped, so the pack's core loads by default
                // and a consumer opts into the rest. If a user import
                // targets that gated package, record a hint.
                if (!sourceIsActive(sf.rel_path, manifest, active_features)) {
                    if (inactiveGate(sf.rel_path, manifest, active_features)) |gate| {
                        if (packageOfSource(sf.bytes)) |pkg| {
                            var imp_it = user_imports.keyIterator();
                            var matched = false;
                            while (imp_it.next()) |imp| {
                                if (importMatchesPackage(allocator, imp.*, pkg)) {
                                    matched = true;
                                    break;
                                }
                            }
                            if (matched) {
                                feature_hints.append(allocator, .{
                                    .lib = try allocator.dupe(u8, lib_id),
                                    .feat = try allocator.dupe(u8, gate.feature),
                                    .pkg = try allocator.dupe(u8, pkg),
                                }) catch {};
                            }
                        }
                    }
                    continue;
                }
                const fid = source_map.add(sf.rel_path, sf.bytes) catch continue;
                const src = source_map.get(fid).source;
                var lx = lexer.Lexer.init(allocator, fid, src) catch continue;
                var lexed = lx.tokenize() catch continue;
                if (lexed.diagnostics.hasErrors()) {
                    lexed.deinit(allocator);
                    continue;
                }
                const p = parser.Parser.new(allocator, fid, src, lexed.tokens);
                const file_ast = p.parseFile();
                if (p.diagnostics.hasErrors()) {
                    lexed.deinit(allocator);
                    continue;
                }
                lexed.deinit(allocator);
                if (file_ast.package) |pkg| {
                    const path = joinIdentPath(allocator, pkg.path) catch continue;
                    defer allocator.free(path);
                    if (path.len != 0) stdlib.registerKnownPackage(path);
                }
                for (file_ast.imports) |imp| {
                    const joined = joinIdentPath(allocator, imp.path) catch continue;
                    new_imports.append(allocator, joined) catch allocator.free(joined);
                }
                try out_asts.append(allocator, file_ast);
                loaded_from_sources = true;
            }
        }
    }
    if (!loaded_from_sources) {
        if (reader.readSection(section_names.AST, &err) catch null) |payload| {
            defer payload.deinit(allocator);
            if (schema.decode(schema.AstBundle, allocator, payload.slice(), &err) catch null) |ast_bundle_val| {
                const ast_bundle = ast_bundle_val;
                // The carried KotlinFiles are pushed into out_asts and
                // outlive the bundle; free only the bundle's spine + the
                // per-file rel_path strings, not the KotlinFiles.
                defer {
                    for (ast_bundle.files) |*f| allocator.free(f.rel_path);
                    allocator.free(ast_bundle.files);
                }
                for (ast_bundle.files) |f| {
                    if (f.kotlin_file.package) |pkg| {
                        const path = joinIdentPath(allocator, pkg.path) catch continue;
                        defer allocator.free(path);
                        if (path.len != 0) stdlib.registerKnownPackage(path);
                    }
                    for (f.kotlin_file.imports) |imp| {
                        const joined = joinIdentPath(allocator, imp.path) catch continue;
                        new_imports.append(allocator, joined) catch allocator.free(joined);
                    }
                    try out_asts.append(allocator, f.kotlin_file);
                }
            }
        }
    }
    if (reader.readSection(section_names.BINDINGS, &err) catch null) |payload| {
        defer payload.deinit(allocator);
        if (schema.decode(schema.BindingManifest, allocator, payload.slice(), &err) catch null) |bm_val| {
            var bm = bm_val;
            defer bm.deinit(allocator);
            for (bm.bindings) |b| {
                if (merged.resolve(b.host_symbol)) |f| {
                    // HostBindings keys must outlive the bindings table
                    // (the bm is freed here). Pack-load is a one-shot at
                    // startup, so a leaked dup of the FQN is bounded.
                    const leaked = allocator.dupe(u8, b.fqn) catch continue;
                    try out_bindings.register(leaked, f);
                }
            }
        }
    }
    // Also bring in any merged binding whose FQN sits under the loaded
    // pack's library_id but isn't explicitly listed in the pack
    // manifest. Newer host entries take effect without a pack rebuild.
    const lib_prefix = std.fmt.allocPrint(allocator, "{s}.", .{lib_id}) catch return;
    defer allocator.free(lib_prefix);
    var entry_it = merged.table.iterator();
    while (entry_it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, lib_prefix)) {
            try out_bindings.register(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

// ---------------------------------------------------------------------
// installed-pack loader
// ---------------------------------------------------------------------

/// Walk the local pack cache, parse each pack's sources, and build a
/// `HostBindings` populated with the Rust-side bindings each pack
/// declares. The caller prepends the returned ASTs to the user's AST
/// list before lowering so pack declarations participate in IR build.
/// Only packs whose imports actually appear in the user's source (or are
/// pulled in transitively) are loaded.
///
/// `requested_features` maps a `library_id` to the feature names the
/// consumer asked for (cargo style); a pack's feature-gated source roots
/// load only when their feature is active.
pub fn loadInstalledPacks(
    gpa: Allocator,
    user_asts: []const KotlinFile,
    source_map: *SourceMap,
    requested_features: *const RequestedFeatures,
) LoadedPacks {
    return loadInstalledPacksOpts(gpa, user_asts, source_map, requested_features, .{});
}

/// `loadInstalledPacks` with the stdlib-image knobs: optionally skip the
/// embedded stdlib sources and/or record what the load consumed.
pub fn loadInstalledPacksOpts(
    gpa: Allocator,
    user_asts: []const KotlinFile,
    source_map: *SourceMap,
    requested_features: *const RequestedFeatures,
    opts: LoadOptions,
) LoadedPacks {
    return loadInstalledPacksImpl(gpa, user_asts, source_map, requested_features, opts) catch .{
        .asts = &.{},
        .bindings = mergedHostBindings(gpa),
    };
}

fn loadInstalledPacksImpl(
    gpa: Allocator,
    user_asts: []const KotlinFile,
    source_map: *SourceMap,
    requested_features: *const RequestedFeatures,
    opts: LoadOptions,
) Allocator.Error!LoadedPacks {
    var out_asts: std.ArrayList(KotlinFile) = .empty;
    errdefer out_asts.deinit(gpa);
    var out_bindings = mergedHostBindingsInit(gpa);
    errdefer out_bindings.deinit();

    var user_import_prefixes = try collectUserImportPrefixes(gpa, user_asts);
    defer freeStringSet(&user_import_prefixes);

    // The embedded stdlib's curated kotlin.time SOURCES are consumed
    // after the pack-cache walk, so a loaded pack that itself imports
    // kotlin.time also triggers the load — gating on the user program's
    // imports alone would miss it.
    const cache_res = klioCacheDir(gpa);
    const cache = switch (cache_res) {
        .ok => |c| c,
        .err => |e| {
            gpa.free(e);
            if (opts.include_stdlib) {
                try loadEmbeddedStdlibSources(gpa, &user_import_prefixes, source_map, &out_asts, &out_bindings, opts.embedded_report);
            }
            return .{ .asts = try out_asts.toOwnedSlice(gpa), .bindings = out_bindings };
        },
    };
    defer gpa.free(cache);

    var merged = mergedHostBindings(gpa);
    defer merged.deinit();

    // Collect every candidate pack on disk once. Loading is then a
    // fixed-point loop: each pass loads packs whose `library_id` matches
    // a currently-known import prefix, and the pass's freshly-loaded
    // ASTs contribute their own imports to the prefix set for the next
    // pass. This lets a pack that transitively depends on another pull
    // its dependency in even when the user imports only the outer
    // library.
    const candidates = try collectPackCandidates(gpa, cache);
    defer {
        for (candidates) |*c| c.deinit(gpa);
        gpa.free(candidates);
    }

    // known_prefixes owns its keys (dups of the user-import prefixes plus
    // dynamically discovered imports).
    var known_prefixes = std.StringHashMap(void).init(gpa);
    defer freeStringSet(&known_prefixes);
    {
        var it = user_import_prefixes.keyIterator();
        while (it.next()) |k| {
            const dup = try gpa.dupe(u8, k.*);
            const gop = try known_prefixes.getOrPut(dup);
            if (gop.found_existing) gpa.free(dup) else gop.value_ptr.* = {};
        }
    }

    var loaded_lib_ids = std.StringHashMap(void).init(gpa);
    defer freeStringSet(&loaded_lib_ids);

    // Feature requests accumulate across passes: the CLI seed plus what
    // each loaded pack asks of its own dependencies.
    var feature_reqs = try cloneRequestedFeatures(gpa, requested_features);
    defer deinitRequestedFeatures(&feature_reqs);

    var feature_hints: std.ArrayList(FeatureHint) = .empty;
    defer {
        for (feature_hints.items) |h| h.deinit(gpa);
        feature_hints.deinit(gpa);
    }

    while (true) {
        var progressed = false;
        var new_imports: std.ArrayList([]u8) = .empty;
        defer {
            for (new_imports.items) |s| gpa.free(s);
            new_imports.deinit(gpa);
        }
        var new_prefixes: std.ArrayList([]u8) = .empty;
        defer {
            for (new_prefixes.items) |s| gpa.free(s);
            new_prefixes.deinit(gpa);
        }

        for (candidates) |*c| {
            const lib_id = c.manifest.library_id;
            if (loaded_lib_ids.contains(lib_id)) continue;
            const wanted = importPrefixMatches(gpa, &known_prefixes, lib_id);
            if (!wanted) continue;
            const lib_dup = try gpa.dupe(u8, lib_id);
            const gop = try loaded_lib_ids.getOrPut(lib_dup);
            if (gop.found_existing) gpa.free(lib_dup) else gop.value_ptr.* = {};
            progressed = true;

            var active = try resolveActiveFeatures(gpa, &c.manifest, feature_reqs.getPtr(lib_id));
            defer active.deinit();

            if (opts.selection) |sel| {
                var feats = try gpa.alloc([]const u8, active.count());
                var fit = active.keyIterator();
                var fi: usize = 0;
                while (fit.next()) |f| : (fi += 1) feats[fi] = try gpa.dupe(u8, f.*);
                std.mem.sort([]const u8, feats, {}, struct {
                    fn lessThan(_: void, x: []const u8, y: []const u8) bool {
                        return std.mem.lessThan(u8, x, y);
                    }
                }.lessThan);
                try sel.packs.append(gpa, .{
                    .path = try gpa.dupe(u8, c.path),
                    .hash = c.pack.packHash(),
                    .features = feats,
                });
            }

            // An active feature can pull in dependency packs and ask
            // features of them. A dep entry is `lib` or `lib/feat[,feat2]`
            // — the suffix requests features on that dependency.
            for (c.manifest.features) |f| {
                if (active.contains(f.name)) {
                    for (f.deps) |dep| {
                        if (std.mem.indexOfScalar(u8, dep, '/')) |slash| {
                            const lib = dep[0..slash];
                            const feats = dep[slash + 1 ..];
                            try new_prefixes.append(gpa, try gpa.dupe(u8, lib));
                            try addFeatureReqs(gpa, &feature_reqs, lib, feats);
                        } else {
                            try new_prefixes.append(gpa, try gpa.dupe(u8, dep));
                        }
                    }
                }
            }
            for (c.manifest.dependencies) |dep| {
                if (dep.features.len != 0) {
                    try addFeatureSlice(gpa, &feature_reqs, dep.library_id, dep.features);
                }
            }

            try loadPackCandidate(
                gpa,
                c,
                lib_id,
                &merged,
                &active,
                &user_import_prefixes,
                &feature_hints,
                source_map,
                &out_asts,
                &out_bindings,
                &new_imports,
            );
        }
        if (!progressed) break;
        for (new_imports.items) |imp| {
            if (imp.len == 0) continue;
            const dup = try gpa.dupe(u8, imp);
            const ip = try known_prefixes.getOrPut(dup);
            if (ip.found_existing) gpa.free(dup) else ip.value_ptr.* = {};
        }
        for (new_prefixes.items) |p| {
            const dup = try gpa.dupe(u8, p);
            const pp = try known_prefixes.getOrPut(dup);
            if (pp.found_existing) gpa.free(dup) else pp.value_ptr.* = {};
        }
    }

    if (opts.selection) |sel| {
        var it = known_prefixes.keyIterator();
        while (it.next()) |k| try sel.final_prefixes.append(gpa, try gpa.dupe(u8, k.*));
    }

    if (opts.include_stdlib) {
        try loadEmbeddedStdlibSources(gpa, &known_prefixes, source_map, &out_asts, &out_bindings, opts.embedded_report);
    }

    // Tell the user how to enable any feature their imports need but that
    // wasn't requested. Drop hints for packages something else already
    // provided: only a genuinely unprovided import should prompt.
    var loaded_pkgs = std.StringHashMap(void).init(gpa);
    defer freeStringSet(&loaded_pkgs);
    for (out_asts.items) |f| {
        if (f.package) |p| {
            const joined = try joinIdentPath(gpa, p.path);
            const gop = try loaded_pkgs.getOrPut(joined);
            if (gop.found_existing) gpa.free(joined) else gop.value_ptr.* = {};
        }
    }

    var shown: std.ArrayList([2][]const u8) = .empty;
    defer shown.deinit(gpa);
    for (feature_hints.items) |h| {
        if (loaded_pkgs.contains(h.pkg)) continue;
        var dup_exists = false;
        for (shown.items) |s| {
            if (std.mem.eql(u8, s[0], h.lib) and std.mem.eql(u8, s[1], h.feat)) {
                dup_exists = true;
                break;
            }
        }
        if (!dup_exists) try shown.append(gpa, .{ h.lib, h.feat });
    }
    std.mem.sort([2][]const u8, shown.items, {}, struct {
        fn lessThan(_: void, a: [2][]const u8, b: [2][]const u8) bool {
            const c0 = std.mem.order(u8, a[0], b[0]);
            if (c0 != .eq) return c0 == .lt;
            return std.mem.order(u8, a[1], b[1]) == .lt;
        }
    }.lessThan);
    for (shown.items) |s| {
        io.printStderr(
            gpa,
            "note: an import requires feature `{s}` of pack `{s}`; enable it with `--feature {s}/{s}`\n",
            .{ s[1], s[0], s[0], s[1] },
        );
    }

    return .{ .asts = try out_asts.toOwnedSlice(gpa), .bindings = out_bindings };
}

/// Deep-copy a `RequestedFeatures` map (keys + nested sets owned by
/// `allocator`). Caller frees with `deinitRequestedFeatures`.
fn cloneRequestedFeatures(allocator: Allocator, src: *const RequestedFeatures) Allocator.Error!RequestedFeatures {
    var out = RequestedFeatures.init(allocator);
    errdefer deinitRequestedFeatures(&out);
    var it = src.iterator();
    while (it.next()) |entry| {
        const lib = try allocator.dupe(u8, entry.key_ptr.*);
        var set = std.StringHashMap(void).init(allocator);
        var fit = entry.value_ptr.keyIterator();
        while (fit.next()) |f| {
            try set.put(try allocator.dupe(u8, f.*), {});
        }
        try out.put(lib, set);
    }
    return out;
}

fn deinitRequestedFeatures(rf: *RequestedFeatures) void {
    const a = rf.allocator;
    var it = rf.iterator();
    while (it.next()) |entry| {
        a.free(entry.key_ptr.*);
        var fit = entry.value_ptr.keyIterator();
        while (fit.next()) |f| a.free(f.*);
        entry.value_ptr.deinit();
    }
    rf.deinit();
}

/// Insert each comma-separated feature in `feats` into the requested set
/// for `lib`, owning fresh copies of the strings.
fn addFeatureReqs(
    allocator: Allocator,
    reqs: *RequestedFeatures,
    lib: []const u8,
    feats: []const u8,
) Allocator.Error!void {
    const set = try featureSetFor(allocator, reqs, lib);
    var it = std.mem.splitScalar(u8, feats, ',');
    while (it.next()) |feat_raw| {
        const feat = std.mem.trim(u8, feat_raw, " \t");
        if (feat.len == 0) continue;
        if (!set.contains(feat)) try set.put(try allocator.dupe(u8, feat), {});
    }
}

/// Insert each feature in `feats` into the requested set for `lib`.
fn addFeatureSlice(
    allocator: Allocator,
    reqs: *RequestedFeatures,
    lib: []const u8,
    feats: [][]const u8,
) Allocator.Error!void {
    const set = try featureSetFor(allocator, reqs, lib);
    for (feats) |feat| {
        if (!set.contains(feat)) try set.put(try allocator.dupe(u8, feat), {});
    }
}

/// Get (or create) the requested-feature set for `lib`, owning the key.
fn featureSetFor(
    allocator: Allocator,
    reqs: *RequestedFeatures,
    lib: []const u8,
) Allocator.Error!*std.StringHashMap(void) {
    if (reqs.getPtr(lib)) |p| return p;
    const key = try allocator.dupe(u8, lib);
    try reqs.put(key, std.StringHashMap(void).init(allocator));
    return reqs.getPtr(lib).?;
}

// ---------------------------------------------------------------------
// host-binding merge
// ---------------------------------------------------------------------

fn mergedHostBindingsInit(gpa: Allocator) HostBindings {
    return mergedHostBindings(gpa);
}

/// Build a single `HostBindings` table that the loader passes to every
/// pack: starts with `klio-stdlib`'s defaults and unions in the bindings
/// each `klio-kotlinx-*` crate ships, plus ktor-client.
pub fn mergedHostBindings(gpa: Allocator) HostBindings {
    var out = HostBindings.withStdlibDefaults(gpa) catch HostBindings.init(gpa);
    mergeInto(&out, kotlinx_atomicfu.hostBindings(gpa) catch null);
    mergeInto(&out, kotlinx_io.hostBindings(gpa) catch null);
    mergeInto(&out, kotlinx_datetime.hostBindings(gpa) catch null);
    mergeInto(&out, kotlinx_coroutines.hostBindings(gpa) catch null);
    mergeInto(&out, kotlinx_serialization.hostBindings(gpa) catch null);
    // ktor-client is opt-in (pack must be installed to take effect) but
    // its host functions are always available in the registry so the
    // pack's bindings resolve when installed.
    mergeInto(&out, ktor_client.hostBindings(gpa) catch null);
    return out;
}

fn mergeInto(dst: *HostBindings, src_opt: ?HostBindings) void {
    var src = src_opt orelse return;
    defer src.deinit();
    var it = src.table.iterator();
    while (it.next()) |entry| {
        dst.register(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }
}

// ---------------------------------------------------------------------
// cache directory + manifest IO
// ---------------------------------------------------------------------

fn klioCacheDir(allocator: Allocator) PathResult {
    const home = getEnvVar(allocator, "HOME") orelse
        return .{ .err = allocator.dupe(u8, "HOME env var unset") catch "" };
    defer allocator.free(home);
    const path = std.fs.path.join(allocator, &.{ home, ".klio", "packs" }) catch
        return .{ .err = allocator.dupe(u8, "out of memory") catch "" };
    return .{ .ok = path };
}

/// Read the manifest section of the pack at `path`. `ok` carries an owned
/// `PackManifest` the caller deinits; `err` an owned message.
pub fn readPackManifest(allocator: Allocator, path: []const u8) ManifestResult {
    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(fio, path, allocator, .unlimited) catch |e|
        return .{ .err = std.fmt.allocPrint(allocator, "read {s}: {s}", .{ path, @errorName(e) }) catch "" };
    var err: PackError = undefined;
    var reader = (PackReader.fromBytes(allocator, bytes, &err) catch return memErr(allocator)) orelse
        return .{ .err = packErrMsg(allocator, err) };
    defer reader.deinit();
    const payload = (reader.readSection(section_names.MANIFEST, &err) catch return memErr(allocator)) orelse
        return .{ .err = std.fmt.allocPrint(allocator, "{s}: missing manifest section", .{path}) catch "" };
    defer payload.deinit(allocator);
    const manifest = (schema.decode(schema.PackManifest, allocator, payload.slice(), &err) catch return memErr(allocator)) orelse
        return .{ .err = packErrMsg(allocator, err) };
    return .{ .ok = manifest };
}

fn memErr(allocator: Allocator) ManifestResult {
    return .{ .err = allocator.dupe(u8, "out of memory") catch "" };
}

fn packErrMsg(allocator: Allocator, err: PackError) []u8 {
    return std.fmt.allocPrint(allocator, "{any}", .{err}) catch "";
}

/// Copy a `.klio-pack` into the local cache, named
/// `<library_id>-<version>.klio-pack`. `ok` is the owned destination
/// path. Rebuilds the sidecar index best-effort.
pub fn installPackIntoCache(allocator: Allocator, src: []const u8) PathResult {
    const manifest_res = readPackManifest(allocator, src);
    switch (manifest_res) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    var manifest = manifest_res.ok;
    defer manifest.deinit(allocator);

    const cache_res = klioCacheDir(allocator);
    const cache = switch (cache_res) {
        .ok => |c| c,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(cache);

    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();
    std.Io.Dir.cwd().createDirPath(fio, cache) catch |e|
        return .{ .err = std.fmt.allocPrint(allocator, "{s}", .{@errorName(e)}) catch "" };

    const name = std.fmt.allocPrint(allocator, "{s}-{s}.klio-pack", .{
        manifest.library_id, manifest.library_version,
    }) catch return .{ .err = allocator.dupe(u8, "out of memory") catch "" };
    defer allocator.free(name);
    const dest = std.fs.path.join(allocator, &.{ cache, name }) catch
        return .{ .err = allocator.dupe(u8, "out of memory") catch "" };

    // Copy bytes: read source, write destination.
    const bytes = std.Io.Dir.cwd().readFileAlloc(fio, src, allocator, .unlimited) catch |e| {
        allocator.free(dest);
        return .{ .err = std.fmt.allocPrint(allocator, "copy: {s}", .{@errorName(e)}) catch "" };
    };
    defer allocator.free(bytes);
    std.Io.Dir.cwd().writeFile(fio, .{ .sub_path = dest, .data = bytes }) catch |e| {
        allocator.free(dest);
        return .{ .err = std.fmt.allocPrint(allocator, "copy: {s}", .{@errorName(e)}) catch "" };
    };

    rebuildCacheIndex(allocator, cache);
    return .{ .ok = dest };
}

// ---------------------------------------------------------------------
// cache index sidecar
// ---------------------------------------------------------------------

/// One entry in the sidecar `index.json`. Field names match the Rust
/// struct so the serialized form is identical.
const CacheIndexEntry = struct {
    library_id: []const u8,
    version: []const u8,
    abi_version: u32,
    path: []const u8,
    dependencies: []const []const u8,
};

const CACHE_INDEX_NAME: []const u8 = "index.json";

/// Walk every pack file in the cache, read each manifest, and write a
/// sidecar `index.json` so subsequent startups can skip the per-pack
/// header read. Best-effort: failures here are swallowed.
fn rebuildCacheIndex(allocator: Allocator, cache: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(fio, cache, .{ .iterate = true }) catch return;
    defer dir.close(fio);

    var out: std.ArrayList(CacheIndexEntry) = .empty;
    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".klio-pack")) continue;
        const p = std.fs.path.join(arena, &.{ cache, entry.name }) catch continue;
        const mr = readPackManifest(allocator, p);
        switch (mr) {
            .err => |e| {
                allocator.free(e);
                continue;
            },
            .ok => {},
        }
        var m = mr.ok;
        defer m.deinit(allocator);
        var deps: std.ArrayList([]const u8) = .empty;
        for (m.dependencies) |d| {
            deps.append(arena, arena.dupe(u8, d.library_id) catch continue) catch continue;
        }
        out.append(arena, .{
            .library_id = arena.dupe(u8, m.library_id) catch continue,
            .version = arena.dupe(u8, m.library_version) catch continue,
            .abi_version = m.abi_version,
            .path = arena.dupe(u8, p) catch continue,
            .dependencies = deps.toOwnedSlice(arena) catch continue,
        }) catch continue;
    }
    std.mem.sort(CacheIndexEntry, out.items, {}, struct {
        fn lessThan(_: void, a: CacheIndexEntry, b: CacheIndexEntry) bool {
            return std.mem.order(u8, a.library_id, b.library_id) == .lt;
        }
    }.lessThan);
    const bytes = std.json.Stringify.valueAlloc(arena, out.items, .{ .whitespace = .indent_2 }) catch return;
    const idx_path = std.fs.path.join(arena, &.{ cache, CACHE_INDEX_NAME }) catch return;
    std.Io.Dir.cwd().writeFile(fio, .{ .sub_path = idx_path, .data = bytes }) catch return;
}

// ---------------------------------------------------------------------
// list / remove
// ---------------------------------------------------------------------

/// List every pack in the local cache, one line per pack.
pub fn listCachePacks(allocator: Allocator) VoidResult {
    const cache_res = klioCacheDir(allocator);
    const cache = switch (cache_res) {
        .ok => |c| c,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(cache);

    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(fio, cache, .{ .iterate = true }) catch {
        io.printStderr(allocator, "(no packs installed at {s})\n", .{cache});
        return .{ .ok = {} };
    };
    defer dir.close(fio);

    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".klio-pack")) continue;
        const p = std.fs.path.join(allocator, &.{ cache, entry.name }) catch continue;
        paths.append(allocator, p) catch allocator.free(p);
    }
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (paths.items) |path| {
        const mr = readPackManifest(allocator, path);
        switch (mr) {
            .ok => {
                var m = mr.ok;
                defer m.deinit(allocator);
                var deps_buf: std.ArrayList(u8) = .empty;
                defer deps_buf.deinit(allocator);
                if (m.dependencies.len == 0) {
                    deps_buf.appendSlice(allocator, "\u{2014}") catch {};
                } else {
                    for (m.dependencies, 0..) |d, i| {
                        if (i != 0) deps_buf.appendSlice(allocator, ", ") catch {};
                        deps_buf.appendSlice(allocator, d.library_id) catch {};
                        const fm = formatMin(allocator, d.min_version);
                        defer allocator.free(fm);
                        deps_buf.appendSlice(allocator, fm) catch {};
                    }
                }
                io.printStdout(allocator, "{s: <32}  {s: <10}  abi {d}  deps {s}\n", .{
                    m.library_id, m.library_version, m.abi_version, deps_buf.items,
                });
            },
            .err => |e| {
                defer allocator.free(e);
                io.printStdout(allocator, "{s}: ! {s}\n", .{ path, e });
            },
        }
    }
    return .{ .ok = {} };
}

/// Render a dependency min-version suffix: ` (>=x)` or empty. Owned.
fn formatMin(allocator: Allocator, min: []const u8) []u8 {
    if (min.len == 0) return allocator.dupe(u8, "") catch "";
    return std.fmt.allocPrint(allocator, " (>={s})", .{min}) catch "";
}

/// Remove the cached pack matching `library_id` (and optionally
/// `version`). `ok` is the owned path that was removed.
pub fn removeCachePack(allocator: Allocator, library_id: []const u8, version: ?[]const u8) PathResult {
    const cache_res = klioCacheDir(allocator);
    const cache = switch (cache_res) {
        .ok => |c| c,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(cache);

    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(fio, cache, .{ .iterate = true }) catch |e|
        return .{ .err = std.fmt.allocPrint(allocator, "{s}", .{@errorName(e)}) catch "" };
    defer dir.close(fio);

    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".klio-pack")) continue;
        const p = std.fs.path.join(allocator, &.{ cache, entry.name }) catch continue;
        var keep_p = false;
        defer if (!keep_p) allocator.free(p);
        const mr = readPackManifest(allocator, p);
        switch (mr) {
            .err => |e| {
                allocator.free(e);
                continue;
            },
            .ok => {},
        }
        var manifest = mr.ok;
        defer manifest.deinit(allocator);
        if (!std.mem.eql(u8, manifest.library_id, library_id)) continue;
        if (version) |v| {
            if (!std.mem.eql(u8, manifest.library_version, v)) continue;
        }
        std.Io.Dir.cwd().deleteFile(fio, p) catch |e|
            return .{ .err = std.fmt.allocPrint(allocator, "{s}", .{@errorName(e)}) catch "" };
        rebuildCacheIndex(allocator, cache);
        keep_p = true;
        return .{ .ok = p };
    }
    return .{ .err = std.fmt.allocPrint(allocator, "no pack matching {s} found in cache", .{library_id}) catch "" };
}

// ---------------------------------------------------------------------
// inspect / verify
// ---------------------------------------------------------------------

/// Inspect a pack: print its format version, hash prefix, sections, and
/// decoded manifest / symbol / binding counts.
pub fn inspectPack(allocator: Allocator, path: []const u8) VoidResult {
    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(fio, path, allocator, .unlimited) catch |e|
        return .{ .err = std.fmt.allocPrint(allocator, "read {s}: {s}", .{ path, @errorName(e) }) catch "" };
    var err: PackError = undefined;
    var reader = (PackReader.fromBytes(allocator, bytes, &err) catch return voidMemErr(allocator)) orelse
        return .{ .err = packErrMsg(allocator, err) };
    defer reader.deinit();

    io.printStdout(allocator, "file:    {s}\n", .{path});
    io.printStdout(allocator, "format:  v{d}\n", .{reader.formatVersion()});
    const hash = reader.packHash();
    var hash_buf: std.ArrayList(u8) = .empty;
    defer hash_buf.deinit(allocator);
    hash_buf.appendSlice(allocator, "hash:    ") catch {};
    for (hash[0..16]) |b| {
        hash_buf.appendSlice(allocator, std.fmt.bytesToHex(&[_]u8{b}, .lower)[0..]) catch {};
    }
    hash_buf.appendSlice(allocator, "\u{2026}\n") catch {};
    io.writeStdout(hash_buf.items);

    io.writeStdout("sections:\n");
    for (reader.sections()) |e| {
        io.printStdout(allocator, "  - {s: <10} stored={d: >8} bytes  uncompressed={d: >8} bytes  {s}\n", .{
            e.name, e.stored_len, e.uncompressed_len, @tagName(e.compression),
        });
    }

    if (reader.readSection(section_names.MANIFEST, &err) catch return voidMemErr(allocator)) |payload| {
        defer payload.deinit(allocator);
        var m = (schema.decode(schema.PackManifest, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
            return .{ .err = packErrMsg(allocator, err) };
        defer m.deinit(allocator);
        const impl = strSliceDebug(allocator, m.implicit_packages);
        defer allocator.free(impl);
        io.printStdout(allocator, "manifest: library={s} version={s} abi={d} implicit={s}\n", .{
            m.library_id, m.library_version, m.abi_version, impl,
        });
        if (m.features.len != 0) {
            const df = strSliceDebug(allocator, m.default_features);
            defer allocator.free(df);
            io.printStdout(allocator, "default-features: {s}\n", .{df});
            for (m.features) |f| {
                const srcs = strSliceDebug(allocator, f.sources);
                defer allocator.free(srcs);
                var tail: std.ArrayList(u8) = .empty;
                defer tail.deinit(allocator);
                if (f.requires.len != 0) {
                    const rq = strSliceDebug(allocator, f.requires);
                    defer allocator.free(rq);
                    const seg = std.fmt.allocPrint(allocator, " requires={s}", .{rq}) catch "";
                    defer allocator.free(seg);
                    tail.appendSlice(allocator, seg) catch {};
                }
                if (f.deps.len != 0) {
                    const dp = strSliceDebug(allocator, f.deps);
                    defer allocator.free(dp);
                    const seg = std.fmt.allocPrint(allocator, " deps={s}", .{dp}) catch "";
                    defer allocator.free(seg);
                    tail.appendSlice(allocator, seg) catch {};
                }
                io.printStdout(allocator, "  feature {s}: sources={s}{s}\n", .{ f.name, srcs, tail.items });
            }
        }
    }
    if (reader.readSection(section_names.SYMBOLS, &err) catch return voidMemErr(allocator)) |payload| {
        defer payload.deinit(allocator);
        var s = (schema.decode(schema.SymbolIndex, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
            return .{ .err = packErrMsg(allocator, err) };
        defer s.deinit(allocator);
        io.printStdout(allocator, "symbols:  {d} entries\n", .{s.entries.len});
    }
    if (reader.readSection(section_names.BINDINGS, &err) catch return voidMemErr(allocator)) |payload| {
        defer payload.deinit(allocator);
        var b = (schema.decode(schema.BindingManifest, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
            return .{ .err = packErrMsg(allocator, err) };
        defer b.deinit(allocator);
        io.printStdout(allocator, "bindings: {d} entries\n", .{b.bindings.len});
    }
    return .{ .ok = {} };
}

fn voidMemErr(allocator: Allocator) VoidResult {
    return .{ .err = allocator.dupe(u8, "out of memory") catch "" };
}

/// Render a `[][]const u8` the way Rust's `{:?}` does for a slice of
/// strings: `["a", "b"]`. Owned by the caller.
fn strSliceDebug(allocator: Allocator, slice: [][]const u8) []u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.append(allocator, '[') catch return allocator.dupe(u8, "[]") catch "";
    for (slice, 0..) |s, i| {
        if (i != 0) buf.appendSlice(allocator, ", ") catch {};
        buf.append(allocator, '"') catch {};
        buf.appendSlice(allocator, s) catch {};
        buf.append(allocator, '"') catch {};
    }
    buf.append(allocator, ']') catch {};
    return buf.toOwnedSlice(allocator) catch "";
}

/// Verify a pack by reading every required section back through the
/// loader and decoding it. `smoke` is accepted for compatibility.
pub fn verifyPack(allocator: Allocator, path: []const u8, smoke: ?[]const u8) VoidResult {
    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(fio, path, allocator, .unlimited) catch |e|
        return .{ .err = std.fmt.allocPrint(allocator, "read {s}: {s}", .{ path, @errorName(e) }) catch "" };
    var err: PackError = undefined;
    var reader = (PackReader.fromBytes(allocator, bytes, &err) catch return voidMemErr(allocator)) orelse
        return .{ .err = packErrMsg(allocator, err) };
    defer reader.deinit();

    const required = [_][]const u8{
        section_names.MANIFEST,
        section_names.SYMBOLS,
        section_names.BINDINGS,
    };
    for (required) |name| {
        const payload = (reader.readSection(name, &err) catch return voidMemErr(allocator)) orelse
            return .{ .err = std.fmt.allocPrint(allocator, "missing required section `{s}`", .{name}) catch "" };
        defer payload.deinit(allocator);
        if (std.mem.eql(u8, name, section_names.MANIFEST)) {
            var m = (schema.decode(schema.PackManifest, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
                return .{ .err = packErrMsg(allocator, err) };
            m.deinit(allocator);
        } else if (std.mem.eql(u8, name, section_names.SYMBOLS)) {
            var s = (schema.decode(schema.SymbolIndex, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
                return .{ .err = packErrMsg(allocator, err) };
            s.deinit(allocator);
        } else if (std.mem.eql(u8, name, section_names.BINDINGS)) {
            var b = (schema.decode(schema.BindingManifest, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
                return .{ .err = packErrMsg(allocator, err) };
            b.deinit(allocator);
        }
    }
    if (smoke != null) {
        io.writeStderr("note: pack smoke-run was removed during the IR cutover.\n");
    }
    return .{ .ok = {} };
}

// ---------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------

test "merged host bindings cover stdlib defaults" {
    var b = mergedHostBindings(std.testing.allocator);
    defer b.deinit();
    try std.testing.expect(!b.isEmpty());
}

test "sourceInFeature matches prefix and exact" {
    var pats = [_][]const u8{ "shim/io/ktor/server", "shim/io/ktor/client/" };
    try std.testing.expect(sourceInFeature("shim/io/ktor/server", &pats));
    try std.testing.expect(sourceInFeature("shim/io/ktor/server/Routing.kt", &pats));
    try std.testing.expect(sourceInFeature("shim/io/ktor/client/Http.kt", &pats));
    try std.testing.expect(!sourceInFeature("shim/io/ktor/serverless", &pats));
    try std.testing.expect(!sourceInFeature("shim/io/ktor/core", &pats));
}

test "resolveActiveFeatures expands defaults and requires" {
    const a = std.testing.allocator;
    var default = [_][]const u8{"core"};
    var req_a = [_][]const u8{"json"};
    var feat_a = schema.FeatureDef{ .name = "json", .sources = &.{}, .deps = &.{}, .requires = &req_a };
    var feats = [_]schema.FeatureDef{feat_a};
    const manifest = schema.PackManifest{
        .library_id = "lib",
        .library_version = "1.0",
        .abi_version = 1,
        .implicit_packages = &.{},
        .dependencies = &.{},
        .default_features = &default,
        .features = &feats,
    };
    var requested = std.StringHashMap(void).init(a);
    defer requested.deinit();
    try requested.put("core", {});
    var active = try resolveActiveFeatures(a, &manifest, &requested);
    defer active.deinit();
    try std.testing.expect(active.contains("core"));
    // "json" is not requested or default, so it is not active.
    try std.testing.expect(!active.contains("json"));
    // Activating "json" pulls in nothing extra here, but "a"-required
    // expansion is covered by a self-requiring feature.
    _ = &feat_a;
}

test "resolveActiveFeatures pulls in transitive requires" {
    const a = std.testing.allocator;
    var default = [_][]const u8{"outer"};
    var req_outer = [_][]const u8{"inner"};
    const f_outer = schema.FeatureDef{ .name = "outer", .sources = &.{}, .deps = &.{}, .requires = &req_outer };
    const f_inner = schema.FeatureDef{ .name = "inner", .sources = &.{}, .deps = &.{}, .requires = &.{} };
    var feats = [_]schema.FeatureDef{ f_outer, f_inner };
    const manifest = schema.PackManifest{
        .library_id = "lib",
        .library_version = "1.0",
        .abi_version = 1,
        .implicit_packages = &.{},
        .dependencies = &.{},
        .default_features = &default,
        .features = &feats,
    };
    var active = try resolveActiveFeatures(a, &manifest, null);
    defer active.deinit();
    try std.testing.expect(active.contains("outer"));
    try std.testing.expect(active.contains("inner"));
}

test "sourceIsActive and inactiveGate" {
    var srcs = [_][]const u8{"shim/server"};
    const f = schema.FeatureDef{ .name = "server", .sources = &srcs, .deps = &.{}, .requires = &.{} };
    var feats = [_]schema.FeatureDef{f};
    const manifest = schema.PackManifest{
        .library_id = "lib",
        .library_version = "1.0",
        .abi_version = 1,
        .implicit_packages = &.{},
        .dependencies = &.{},
        .default_features = &.{},
        .features = &feats,
    };
    const a = std.testing.allocator;
    var active = std.StringHashMap(void).init(a);
    defer active.deinit();
    // Core (ungated) file is always active.
    try std.testing.expect(sourceIsActive("shim/core/Core.kt", &manifest, &active));
    // Gated file with no active feature is inactive.
    try std.testing.expect(!sourceIsActive("shim/server/Routing.kt", &manifest, &active));
    const gate = inactiveGate("shim/server/Routing.kt", &manifest, &active);
    try std.testing.expect(gate != null);
    try std.testing.expectEqualStrings("server", gate.?.feature);
    try std.testing.expectEqualStrings("shim/server", gate.?.prefix);
    // Once active, the gated file becomes active and has no gate.
    try active.put("server", {});
    try std.testing.expect(sourceIsActive("shim/server/Routing.kt", &manifest, &active));
    try std.testing.expect(inactiveGate("shim/server/Routing.kt", &manifest, &active) == null);
}

test "packageOfSource finds the package line" {
    const src =
        \\// a comment
        \\
        \\   package io.ktor.server ;
        \\
        \\fun main() {}
    ;
    const pkg = packageOfSource(src);
    try std.testing.expect(pkg != null);
    try std.testing.expectEqualStrings("io.ktor.server", pkg.?);
    try std.testing.expect(packageOfSource("fun main() {}") == null);
}

test "importMatchesPackage targets package and members only" {
    const a = std.testing.allocator;
    try std.testing.expect(importMatchesPackage(a, "io.ktor.server", "io.ktor.server"));
    try std.testing.expect(importMatchesPackage(a, "io.ktor.server.Routing", "io.ktor.server"));
    // A parent star import does not target a child package.
    try std.testing.expect(!importMatchesPackage(a, "io.ktor", "io.ktor.server"));
    try std.testing.expect(!importMatchesPackage(a, "io.ktor.server", ""));
}

test "formatMin renders a min-version suffix" {
    const a = std.testing.allocator;
    const empty = formatMin(a, "");
    defer a.free(empty);
    try std.testing.expectEqualStrings("", empty);
    const some = formatMin(a, "1.2.0");
    defer a.free(some);
    try std.testing.expectEqualStrings(" (>=1.2.0)", some);
}

test "strSliceDebug mirrors Rust slice debug" {
    const a = std.testing.allocator;
    var items = [_][]const u8{ "kotlin", "kotlin.collections" };
    const out = strSliceDebug(a, &items);
    defer a.free(out);
    try std.testing.expectEqualStrings("[\"kotlin\", \"kotlin.collections\"]", out);
    var empty: [0][]const u8 = .{};
    const out2 = strSliceDebug(a, &empty);
    defer a.free(out2);
    try std.testing.expectEqualStrings("[]", out2);
}

test "dottedPrefix only matches on a dot boundary" {
    const a = std.testing.allocator;
    try std.testing.expect(dottedPrefix(a, "io.ktor.server", "io.ktor"));
    try std.testing.expect(!dottedPrefix(a, "io.ktorx", "io.ktor"));
    try std.testing.expect(!dottedPrefix(a, "io.ktor", "io.ktor"));
}

test "cloneRequestedFeatures deep copies the map" {
    const a = std.testing.allocator;
    var src = RequestedFeatures.init(a);
    {
        var set = std.StringHashMap(void).init(a);
        try set.put("server", {});
        try src.put("io.ktor", set);
    }
    defer {
        var it = src.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        src.deinit();
    }
    var cloned = try cloneRequestedFeatures(a, &src);
    defer deinitRequestedFeatures(&cloned);
    const feats = cloned.get("io.ktor").?;
    try std.testing.expect(feats.contains("server"));
}

test "addFeatureReqs splits comma-separated features" {
    const a = std.testing.allocator;
    var reqs = RequestedFeatures.init(a);
    defer deinitRequestedFeatures(&reqs);
    try addFeatureReqs(a, &reqs, "kotlinx.serialization", "json, cbor ,");
    const set = reqs.get("kotlinx.serialization").?;
    try std.testing.expect(set.contains("json"));
    try std.testing.expect(set.contains("cbor"));
    try std.testing.expectEqual(@as(usize, 2), set.count());
}
