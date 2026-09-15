//! `klio ide` — the project model an editor builds its workspace from.
//!
//! `model` materialises every pack source the project resolves against into the
//! klio data home, then prints the module graph as JSON. The CLI owns every
//! answer about how a project composes (which packs load, which source sets
//! refine which, which roots a module spans); an editor integration renders
//! that answer and never re-derives it.
//!
//! Materialisation is an IDE-only step. `klio run` and `klio pack install` do
//! not touch `<home>/.klio/ide`, so a user who never opens an editor pays
//! nothing for it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const pack = @import("pack");
const schema = pack.schema;
const section_names = pack.section_names;
const PackReader = pack.PackReader;
const PackError = pack.PackError;

const runtime = @import("runtime");
const stdlib = @import("stdlib");
const stdlib_pack = @import("stdlib_pack");

const io = @import("io.zig");
const pack_build = @import("pack_build.zig");

/// Bumped when the emitted JSON changes shape. A consumer that does not know
/// the version refuses the document rather than mis-modelling the project.
pub const SCHEMA_VERSION: u32 = 1;

const KOTLIN_RELEASE = stdlib.pack_builder.stdlib_sources.KOTLIN_RELEASE;

const USAGE =
    \\usage: klio ide <subcommand>
    \\
    \\  model [--project <dir>] [--out <file>] [--refresh]
    \\        Materialise the project's pack sources and print its module graph.
    \\  packs Print every installed pack with its version, features and
    \\        dependencies, which is what a manifest editor completes from.
    \\  gc    Drop materialised sources no pack in the cache still names.
    \\
;

pub fn run(gpa: Allocator, args: []const []const u8) u8 {
    if (args.len == 0) {
        io.printStderr(gpa, "{s}", .{USAGE});
        return 2;
    }
    if (std.mem.eql(u8, args[0], "model")) return runModel(gpa, args[1..]);
    if (std.mem.eql(u8, args[0], "packs")) return runPacks(gpa, args[1..]);
    if (std.mem.eql(u8, args[0], "gc")) return runGc(gpa, args[1..]);
    io.printStderr(gpa, "error: unknown `klio ide` subcommand `{s}`\n\n{s}", .{ args[0], USAGE });
    return 2;
}

// ---------------------------------------------------------------- model ----

/// One packed source root, and the module an editor builds over it.
const SourceSet = struct {
    /// `rel_path` prefix inside the materialised tree.
    root: []const u8,
    feature: []const u8 = "",
    has_expect: bool = false,
    has_actual: bool = false,
    /// Absolute content root.
    path: []const u8,
    module_id: []const u8,
};

/// A library resolved into the model: the materialised sets plus the library
/// ids it loads behind.
const Library = struct {
    id: []const u8,
    version: []const u8,
    sets: []SourceSet,
    deps: []const []const u8,
};

const ModelError = error{ OutOfMemory, Failed };

fn runModel(gpa: Allocator, args: []const []const u8) u8 {
    var project_dir: []const u8 = ".";
    var out_path: ?[]const u8 = null;
    var refresh = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--project") or std.mem.eql(u8, a, "-p")) {
            i += 1;
            if (i >= args.len) return usageErr(gpa, "--project requires a directory");
            project_dir = args[i];
        } else if (optionValue(a, "--project=")) |v| {
            project_dir = v;
        } else if (std.mem.eql(u8, a, "--out") or std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= args.len) return usageErr(gpa, "--out requires a path");
            out_path = args[i];
        } else if (optionValue(a, "--out=")) |v| {
            out_path = v;
        } else if (std.mem.eql(u8, a, "--refresh")) {
            refresh = true;
        } else {
            return usageErr(gpa, "unknown option");
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const json = buildModel(a, project_dir, refresh) catch |e| switch (e) {
        error.OutOfMemory => {
            io.writeStderr("error: out of memory\n");
            return 1;
        },
        error.Failed => return 1,
    };

    if (out_path) |p| {
        var threaded = std.Io.Threaded.init(a, .{});
        defer threaded.deinit();
        std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = p, .data = json }) catch {
            io.printStderr(gpa, "error: cannot write {s}\n", .{p});
            return 1;
        };
    } else {
        io.writeStdout(json);
    }
    return 0;
}

fn buildModel(a: Allocator, project_dir: []const u8, refresh: bool) ModelError![]const u8 {
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const fio = threaded.io();

    const ide_root = try ideRoot(a);
    const project_abs = absPath(a, project_dir) catch project_dir;

    var problems: std.ArrayList([]const u8) = .empty;

    // The stdlib is the one library every module resolves against, and the one
    // the interpreter resolves for itself rather than from the pack cache.
    const std_lib = try materializeStdlib(a, fio, ide_root, refresh, &problems);

    // The project's own manifest, when it has one.
    var manifest: ?pack_build.LibraryToml = null;
    const toml_path = try std.fs.path.join(a, &.{ project_abs, "klio.toml" });
    if (readFileOpt(a, fio, toml_path)) |text| {
        switch (pack_build.parseLibraryToml(a, text)) {
            .ok => |cfg| manifest = cfg,
            .err => |e| try problems.append(a, try std.fmt.allocPrint(a, "klio.toml: {s}", .{e})),
        }
    }

    var libs: std.ArrayList(Library) = .empty;
    if (manifest) |cfg| {
        var wanted: std.ArrayList([]const u8) = .empty;
        for (cfg.deps) |d| try wanted.append(a, d.id);
        try resolveLibraries(a, fio, ide_root, refresh, wanted.items, &libs, &problems);
    }

    return renderModel(a, .{
        .project_dir = project_abs,
        .project_name = std.fs.path.basename(project_abs),
        .manifest = manifest,
        .stdlib = std_lib,
        .libs = libs.items,
        .problems = problems.items,
    });
}

/// Materialise the stdlib pack the interpreter itself would load, so an editor
/// resolves against the same sources a run would.
fn materializeStdlib(
    a: Allocator,
    fio: std.Io,
    ide_root: []const u8,
    refresh: bool,
    problems: *std.ArrayList([]const u8),
) ModelError!Library {
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    runtime.procEnvPutAllInto(a, &env);

    var perr: PackError = undefined;
    const bytes = (stdlib_pack.stdlibPackBytes(a, &env, &perr) catch return error.OutOfMemory) orelse {
        try problems.append(a, try a.dupe(u8, "the stdlib pack could not be resolved"));
        return .{ .id = "stdlib", .version = "0", .sets = &.{}, .deps = &.{} };
    };
    return materializePack(a, fio, ide_root, "stdlib", bytes, refresh, problems);
}

/// Walk the wanted library ids and their transitive dependencies, materialising
/// each installed pack. Missing packs become problems, never a hard failure: a
/// half-resolved model still gives an editor most of a project.
fn resolveLibraries(
    a: Allocator,
    fio: std.Io,
    ide_root: []const u8,
    refresh: bool,
    wanted: []const []const u8,
    out: *std.ArrayList(Library),
    problems: *std.ArrayList([]const u8),
) ModelError!void {
    const cache = try cacheDir(a);
    const installed = try indexInstalledPacks(a, fio, cache);

    var seen = std.StringHashMap(void).init(a);
    var queue: std.ArrayList([]const u8) = .empty;
    for (wanted) |w| try queue.append(a, w);

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const id = queue.items[qi];
        if (std.mem.eql(u8, id, "stdlib")) continue;
        const gop = try seen.getOrPut(id);
        if (gop.found_existing) continue;

        const path = installed.get(id) orelse {
            try problems.append(a, try std.fmt.allocPrint(
                a,
                "pack `{s}` is not installed; run `klio pack install`",
                .{id},
            ));
            continue;
        };
        const bytes = readFileOpt(a, fio, path) orelse {
            try problems.append(a, try std.fmt.allocPrint(a, "pack `{s}` is unreadable", .{id}));
            continue;
        };
        const lib = try materializePack(a, fio, ide_root, id, bytes, refresh, problems);
        for (lib.deps) |d| try queue.append(a, d);
        try out.append(a, lib);
    }
}

/// Write a pack's sources under `<ide>/libs/<id>/<hash>/src`, keeping every
/// `rel_path` intact so a source set's root is a real directory an editor can
/// mount. A `.complete` marker makes the write once per pack content.
fn materializePack(
    a: Allocator,
    fio: std.Io,
    ide_root: []const u8,
    fallback_id: []const u8,
    bytes: []u8,
    refresh: bool,
    problems: *std.ArrayList([]const u8),
) ModelError!Library {
    var perr: PackError = undefined;
    var reader = (PackReader.fromBytes(a, bytes, &perr) catch return error.OutOfMemory) orelse {
        try problems.append(a, try std.fmt.allocPrint(a, "pack `{s}` failed to open", .{fallback_id}));
        return .{ .id = fallback_id, .version = "0", .sets = &.{}, .deps = &.{} };
    };
    defer reader.deinit();

    const hash = reader.packHash();
    const hex = try std.fmt.allocPrint(a, "{x}", .{&hash});
    const short = hex[0..16];

    var id = fallback_id;
    var version: []const u8 = "0";
    var deps: []const []const u8 = &.{};
    if (readSection(&reader, section_names.MANIFEST)) |payload| {
        if (schema.decode(schema.PackManifest, a, payload, &perr) catch null) |m| {
            id = m.library_id;
            version = m.library_version;
            const d = try a.alloc([]const u8, m.dependencies.len);
            for (m.dependencies, d) |src, *dst| dst.* = src.library_id;
            deps = d;
        }
    }

    const dir = try std.fs.path.join(a, &.{ ide_root, "libs", id, short });
    // The sources sit in a directory named for the pack, not a generic `src`.
    // An editor shows a content root by its directory name, so this is what
    // makes a pack read as `kotlinx.serialization` rather than `src`.
    const src_dir = try std.fs.path.join(a, &.{ dir, id });
    const marker = try std.fs.path.join(a, &.{ dir, ".complete" });
    const sets_file = try std.fs.path.join(a, &.{ dir, "sourcesets" });

    // A tree written under the old layout still carries its marker, so the
    // marker alone would leave the model pointing at a directory that is gone.
    const laid_out = blk: {
        var d = std.Io.Dir.cwd().openDir(fio, src_dir, .{}) catch break :blk false;
        d.close(fio);
        break :blk true;
    };
    const complete = !refresh and laid_out and readFileOpt(a, fio, marker) != null;
    if (!complete) {
        // Anything a previous layout left behind in the same content directory.
        if (!std.mem.eql(u8, id, "src")) {
            const stale = try std.fs.path.join(a, &.{ dir, "src" });
            std.Io.Dir.cwd().deleteTree(fio, stale) catch {};
        }
        if (readSection(&reader, section_names.SOURCES)) |payload| {
            const bundle = (schema.decode(schema.SourceBundle, a, payload, &perr) catch null) orelse {
                try problems.append(a, try std.fmt.allocPrint(a, "pack `{s}`: sources failed to decode", .{id}));
                return .{ .id = id, .version = version, .sets = &.{}, .deps = deps };
            };
            for (bundle.files) |f| {
                const dest = try std.fs.path.join(a, &.{ src_dir, f.rel_path });
                if (std.fs.path.dirname(dest)) |parent| {
                    std.Io.Dir.cwd().createDirPath(fio, parent) catch {};
                }
                std.Io.Dir.cwd().writeFile(fio, .{ .sub_path = dest, .data = f.bytes }) catch {
                    try problems.append(a, try std.fmt.allocPrint(a, "cannot write {s}", .{dest}));
                };
            }
        } else {
            try problems.append(a, try std.fmt.allocPrint(a, "pack `{s}` carries no sources", .{id}));
        }
    }

    // The source sets: from the pack when it records them, else the persisted
    // copy, else one unnamed set spanning everything the pack shipped.
    var sets: []schema.SourceSetEntry = &.{};
    if (readSection(&reader, section_names.SOURCESETS)) |payload| {
        if (schema.decode(schema.SourceSetIndex, a, payload, &perr) catch null) |idx| sets = idx.sets;
    }
    if (sets.len == 0) {
        if (readFileOpt(a, fio, sets_file)) |text| sets = try parseSetsFile(a, text);
    }
    if (sets.len == 0) {
        const one = try a.alloc(schema.SourceSetEntry, 1);
        one[0] = .{ .root = "", .feature = "", .has_expect = false, .has_actual = false };
        sets = one;
    }

    if (!complete) {
        std.Io.Dir.cwd().createDirPath(fio, dir) catch {};
        std.Io.Dir.cwd().writeFile(fio, .{ .sub_path = sets_file, .data = try renderSetsFile(a, sets) }) catch {};
        std.Io.Dir.cwd().writeFile(fio, .{ .sub_path = marker, .data = hex }) catch {};
    }

    const out = try a.alloc(SourceSet, sets.len);
    for (sets, out) |s, *dst| {
        dst.* = .{
            .root = s.root,
            .feature = s.feature,
            .has_expect = s.has_expect,
            .has_actual = s.has_actual,
            .path = if (s.root.len == 0) src_dir else try std.fs.path.join(a, &.{ src_dir, s.root }),
            .module_id = try moduleId(a, id, s.root),
        };
    }
    return .{ .id = id, .version = version, .sets = out, .deps = deps };
}

fn moduleId(a: Allocator, lib: []const u8, root: []const u8) Allocator.Error![]const u8 {
    if (root.len == 0) return a.dupe(u8, lib);
    return std.fmt.allocPrint(a, "{s}:{s}", .{ lib, root });
}

// ------------------------------------------------------------- rendering ----

const RenderInput = struct {
    project_dir: []const u8,
    project_name: []const u8,
    manifest: ?pack_build.LibraryToml,
    stdlib: Library,
    libs: []const Library,
    problems: []const []const u8,
};

/// Arguments a user's own module carries. `-Xmulti-platform` is what lets
/// `expect`/`actual` appear outside a multiplatform build.
const BASE_ARGS = [_][]const u8{ "-Xmulti-platform", "-Xexpect-actual-classes" };

/// Every library klio ships resolves under these. `-Xallow-kotlin-package` is
/// not stdlib-only: `kotlin.test` declares `package kotlin.test`, and any pack
/// may supply a `kotlin.*` package klio treats as part of its standard surface.
/// User modules keep `BASE_ARGS`, so a program still cannot declare into
/// `kotlin`.
const LIBRARY_ARGS = [_][]const u8{
    "-Xmulti-platform",
    "-Xexpect-actual-classes",
    "-Xallow-kotlin-package",
    "-opt-in=kotlin.ExperimentalMultiplatform",
    "-opt-in=kotlin.contracts.ExperimentalContracts",
    "-opt-in=kotlin.experimental.ExperimentalTypeInference",
};

fn renderModel(a: Allocator, in: RenderInput) ModelError![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    const w = &s;

    try w.appendSlice(a, "{\n");
    try appendFmt(a, w, "  \"schema\": {d},\n", .{SCHEMA_VERSION});
    try appendFmt(a, w, "  \"kotlin\": \"{d}.{d}.{d}\",\n", .{
        KOTLIN_RELEASE.major, KOTLIN_RELEASE.minor, KOTLIN_RELEASE.patch,
    });
    try appendFmt(a, w, "  \"languageVersion\": \"{d}.{d}\",\n", .{
        KOTLIN_RELEASE.major, KOTLIN_RELEASE.minor,
    });
    try w.appendSlice(a, "  \"project\": {");
    try w.appendSlice(a, "\"root\": ");
    try appendJsonString(a, w, in.project_dir);
    try w.appendSlice(a, ", \"name\": ");
    try appendJsonString(a, w, in.project_name);
    try appendFmt(a, w, ", \"hasManifest\": {s}", .{if (in.manifest != null) "true" else "false"});
    try w.appendSlice(a, "},\n");

    // Every library module a project module may depend on, stdlib first.
    var lib_dep_ids: std.ArrayList([]const u8) = .empty;
    for (libraryModuleIds(a, in.stdlib) catch &.{}) |id| try lib_dep_ids.append(a, id);
    for (in.libs) |lib| {
        for (libraryModuleIds(a, lib) catch &.{}) |id| try lib_dep_ids.append(a, id);
    }

    try w.appendSlice(a, "  \"modules\": [\n");
    var first = true;

    // stdlib: the `expect` roots resolve ahead of the roots that actualise them.
    try renderLibrary(a, w, &first, in.stdlib, &.{}, in.stdlib, &LIBRARY_ARGS);
    for (in.libs) |lib| {
        try renderLibrary(a, w, &first, lib, in.libs, in.stdlib, &LIBRARY_ARGS);
    }

    // The project's own modules.
    const main_roots = try projectSourceRoots(a, in);
    const main_id = try std.fmt.allocPrint(a, "{s}:main", .{in.project_name});
    try renderModule(a, w, &first, .{
        .id = main_id,
        .kind = "source",
        .platform = "klio",
        .roots = main_roots,
        .depends_on = &.{},
        .deps = lib_dep_ids.items,
        .args = &BASE_ARGS,
        .is_test = false,
        .read_only = false,
        .highlight = "full",
        .feature = "",
    });

    if (in.manifest) |cfg| {
        for (cfg.tests, 0..) |t, idx| {
            const root = try std.fs.path.join(a, &.{ in.project_dir, t.root });
            const roots = try a.alloc([]const u8, 1);
            roots[0] = root;
            var deps: std.ArrayList([]const u8) = .empty;
            try deps.append(a, main_id);
            for (lib_dep_ids.items) |d| try deps.append(a, d);
            try renderModule(a, w, &first, .{
                .id = try std.fmt.allocPrint(a, "{s}:test{d}", .{ in.project_name, idx }),
                .kind = "source",
                .platform = "klio",
                .roots = roots,
                .depends_on = &.{},
                .deps = deps.items,
                .args = &BASE_ARGS,
                .is_test = true,
                .read_only = false,
                .highlight = "full",
                .feature = t.feature,
            });
        }
    }

    try w.appendSlice(a, "\n  ],\n");

    try w.appendSlice(a, "  \"problems\": [");
    for (in.problems, 0..) |p, idx| {
        if (idx != 0) try w.appendSlice(a, ", ");
        try appendJsonString(a, w, p);
    }
    try w.appendSlice(a, "]\n}\n");
    return s.items;
}

/// A library's modules: one per source set, with the `actual` sets refining
/// every `expect` set of the same library.
/// A library's modules. klio builds a pack's sources as one unit, so its source
/// sets see each other, and the model says so by collapsing them into at most
/// two modules: the roots that declare `expect`, and everything that actualises
/// them. One module per set instead would leave a pack's own sets blind to each
/// other, which is how `kotlinx.serialization`'s json roots lost sight of its
/// core roots.
fn renderLibrary(
    a: Allocator,
    w: *std.ArrayList(u8),
    first: *bool,
    lib: Library,
    all: []const Library,
    std_lib: Library,
    args: []const []const u8,
) ModelError!void {
    var expect_roots: std.ArrayList([]const u8) = .empty;
    var main_roots: std.ArrayList([]const u8) = .empty;
    var feature: []const u8 = "";
    for (lib.sets) |set| {
        if (set.has_expect) {
            try expect_roots.append(a, set.path);
        } else {
            try main_roots.append(a, set.path);
            if (feature.len == 0) feature = set.feature;
        }
    }

    var deps: std.ArrayList([]const u8) = .empty;
    // Everything but the stdlib itself resolves against the stdlib.
    if (!std.mem.eql(u8, lib.id, std_lib.id)) {
        for (libraryModuleIds(a, std_lib) catch &.{}) |id| try deps.append(a, id);
    }
    for (lib.deps) |dep_id| {
        for (all) |other| {
            if (!std.mem.eql(u8, other.id, dep_id)) continue;
            for (libraryModuleIds(a, other) catch &.{}) |id| try deps.append(a, id);
        }
    }

    const common_id = try std.fmt.allocPrint(a, "{s}:common", .{lib.id});
    if (expect_roots.items.len != 0) {
        try renderModule(a, w, first, .{
            .id = common_id,
            .kind = "library",
            .platform = "common",
            .roots = expect_roots.items,
            .depends_on = &.{},
            .deps = deps.items,
            .args = args,
            .is_test = false,
            .read_only = true,
            .highlight = "off",
            .feature = "",
        });
    }

    if (main_roots.items.len != 0) {
        const refines: []const []const u8 = if (expect_roots.items.len == 0) &.{} else blk: {
            const one = try a.alloc([]const u8, 1);
            one[0] = common_id;
            break :blk one;
        };
        try renderModule(a, w, first, .{
            .id = lib.id,
            .kind = "library",
            .platform = "klio",
            .roots = main_roots.items,
            .depends_on = refines,
            .deps = deps.items,
            .args = args,
            .is_test = false,
            .read_only = true,
            .highlight = "off",
            .feature = feature,
        });
    }
}

const ModuleOut = struct {
    id: []const u8,
    kind: []const u8,
    platform: []const u8,
    roots: []const []const u8,
    depends_on: []const []const u8,
    deps: []const []const u8,
    args: []const []const u8,
    is_test: bool,
    read_only: bool,
    highlight: []const u8,
    feature: []const u8,
};

/// The module ids `renderLibrary` emits for a library, in dependency order.
fn libraryModuleIds(a: Allocator, lib: Library) ModelError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var has_expect = false;
    var has_main = false;
    for (lib.sets) |set| {
        if (set.has_expect) has_expect = true else has_main = true;
    }
    if (has_expect) try out.append(a, try std.fmt.allocPrint(a, "{s}:common", .{lib.id}));
    if (has_main) try out.append(a, lib.id);
    return out.items;
}

fn renderModule(
    a: Allocator,
    w: *std.ArrayList(u8),
    first: *bool,
    m: ModuleOut,
) ModelError!void {
    if (!first.*) try w.appendSlice(a, ",\n");
    first.* = false;
    try w.appendSlice(a, "    {");
    try w.appendSlice(a, "\"id\": ");
    try appendJsonString(a, w, m.id);
    try appendFmt(a, w, ", \"kind\": \"{s}\", \"platform\": \"{s}\"", .{ m.kind, m.platform });
    try w.appendSlice(a, ", \"contentRoots\": ");
    try appendJsonArray(a, w, m.roots);
    try w.appendSlice(a, ", \"dependsOn\": ");
    try appendJsonArray(a, w, m.depends_on);
    try w.appendSlice(a, ", \"dependencies\": ");
    try appendJsonArray(a, w, m.deps);
    try w.appendSlice(a, ", \"compilerArguments\": ");
    try appendJsonArray(a, w, m.args);
    try appendFmt(a, w, ", \"isTest\": {s}", .{if (m.is_test) "true" else "false"});
    try appendFmt(a, w, ", \"readOnly\": {s}", .{if (m.read_only) "true" else "false"});
    try appendFmt(a, w, ", \"highlighting\": \"{s}\"", .{m.highlight});
    if (m.feature.len != 0) {
        try w.appendSlice(a, ", \"feature\": ");
        try appendJsonString(a, w, m.feature);
    }
    try w.appendSlice(a, "}");
}

/// The project's own source roots: its manifest's, else the project directory,
/// which is what a loose folder of `.kt` files resolves as.
fn projectSourceRoots(a: Allocator, in: RenderInput) ModelError![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    if (in.manifest) |cfg| {
        for (cfg.library.source_roots) |r| {
            try roots.append(a, try std.fs.path.join(a, &.{ in.project_dir, r }));
        }
        for (cfg.source) |s| {
            try roots.append(a, try std.fs.path.join(a, &.{ in.project_dir, s.root }));
        }
        if (roots.items.len == 0) {
            try roots.append(a, try std.fs.path.join(a, &.{ in.project_dir, "src" }));
        }
    } else {
        try roots.append(a, in.project_dir);
    }
    return roots.items;
}

// ---------------------------------------------------------------- packs ----

/// Every installed pack, as the catalogue a manifest editor offers: the id to
/// depend on, the version it would resolve, and the features and dependencies
/// that id carries. Manifests only ever name what is installed, so the cache is
/// the whole answer.
fn runPacks(gpa: Allocator, args: []const []const u8) u8 {
    _ = args;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const fio = threaded.io();

    const cache = cacheDir(a) catch {
        io.writeStderr("error: HOME (or KLIO_HOME) is unset\n");
        return 1;
    };
    const installed = indexInstalledPacks(a, fio, cache) catch return 1;

    var ids: std.ArrayList([]const u8) = .empty;
    var it = installed.keyIterator();
    while (it.next()) |k| ids.append(a, k.*) catch return 1;
    std.mem.sort([]const u8, ids.items, {}, lessStr);

    var s: std.ArrayList(u8) = .empty;
    const w = &s;
    appendFmt(a, w, "{{\n  \"schema\": {d},\n  \"packs\": [\n", .{SCHEMA_VERSION}) catch return 1;

    var first = true;
    for (ids.items) |id| {
        const path = installed.get(id) orelse continue;
        // The manifest alone, so a catalogue over every installed pack reads
        // kilobytes rather than every byte each pack carries.
        var perr: PackError = undefined;
        const payload = (pack.readSectionFromPath(a, path, section_names.MANIFEST, &perr) catch continue) orelse continue;
        const manifest = (schema.decode(schema.PackManifest, a, payload.slice(), &perr) catch continue) orelse continue;

        if (!first) w.appendSlice(a, ",\n") catch return 1;
        first = false;
        w.appendSlice(a, "    {\"id\": ") catch return 1;
        appendJsonString(a, w, manifest.library_id) catch return 1;
        w.appendSlice(a, ", \"version\": ") catch return 1;
        appendJsonString(a, w, manifest.library_version) catch return 1;
        w.appendSlice(a, ", \"defaultFeatures\": ") catch return 1;
        appendJsonArray(a, w, manifest.default_features) catch return 1;
        w.appendSlice(a, ", \"features\": [") catch return 1;
        for (manifest.features, 0..) |f, i| {
            if (i != 0) w.appendSlice(a, ", ") catch return 1;
            w.appendSlice(a, "{\"name\": ") catch return 1;
            appendJsonString(a, w, f.name) catch return 1;
            w.appendSlice(a, ", \"requires\": ") catch return 1;
            appendJsonArray(a, w, f.requires) catch return 1;
            w.appendSlice(a, "}") catch return 1;
        }
        w.appendSlice(a, "], \"dependencies\": [") catch return 1;
        for (manifest.dependencies, 0..) |d, i| {
            if (i != 0) w.appendSlice(a, ", ") catch return 1;
            appendJsonString(a, w, d.library_id) catch return 1;
        }
        w.appendSlice(a, "]}") catch return 1;
    }
    w.appendSlice(a, "\n  ]\n}\n") catch return 1;
    io.writeStdout(s.items);
    return 0;
}

// ------------------------------------------------------------------- gc ----

fn runGc(gpa: Allocator, args: []const []const u8) u8 {
    _ = args;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const fio = threaded.io();

    const ide_root = ideRoot(a) catch {
        io.writeStderr("error: HOME (or KLIO_HOME) is unset\n");
        return 1;
    };
    const libs_dir = std.fs.path.join(a, &.{ ide_root, "libs" }) catch return 1;

    var removed: usize = 0;
    var dir = std.Io.Dir.cwd().openDir(fio, libs_dir, .{ .iterate = true }) catch {
        io.writeStdout("nothing materialised\n");
        return 0;
    };
    defer dir.close(fio);

    // Within one library, keep only the newest content hash: an older one is a
    // pack version nothing resolves against any more.
    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const lib_dir = std.fs.path.join(a, &.{ libs_dir, entry.name }) catch continue;
        var versions: std.ArrayList([]const u8) = .empty;
        var vdir = std.Io.Dir.cwd().openDir(fio, lib_dir, .{ .iterate = true }) catch continue;
        var vit = vdir.iterate();
        while (vit.next(fio) catch null) |v| {
            if (v.kind != .directory) continue;
            versions.append(a, a.dupe(u8, v.name) catch continue) catch continue;
        }
        vdir.close(fio);
        if (versions.items.len <= 1) continue;
        std.mem.sort([]const u8, versions.items, {}, lessStr);
        for (versions.items[0 .. versions.items.len - 1]) |old| {
            const victim = std.fs.path.join(a, &.{ lib_dir, old }) catch continue;
            std.Io.Dir.cwd().deleteTree(fio, victim) catch continue;
            removed += 1;
        }
    }
    io.printStdout(gpa, "removed {d} stale materialisation(s)\n", .{removed});
    return 0;
}

// -------------------------------------------------------------- plumbing ----

fn ideRoot(a: Allocator) ModelError![]const u8 {
    const home = (runtime.procEnvKlioHome(a) catch null) orelse return error.Failed;
    return std.fs.path.join(a, &.{ home, ".klio", "ide" });
}

fn cacheDir(a: Allocator) ModelError![]const u8 {
    const home = (runtime.procEnvKlioHome(a) catch null) orelse return error.Failed;
    return std.fs.path.join(a, &.{ home, ".klio", "packs" });
}

/// Installed packs are named `<library_id>-<version>.klio-pack`, so the id maps
/// to a path without opening a single file.
fn indexInstalledPacks(
    a: Allocator,
    fio: std.Io,
    cache: []const u8,
) ModelError!std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(a);
    var dir = std.Io.Dir.cwd().openDir(fio, cache, .{ .iterate = true }) catch return map;
    defer dir.close(fio);
    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".klio-pack")) continue;
        const id = libIdFromBasename(entry.name) orelse continue;
        const path = try std.fs.path.join(a, &.{ cache, entry.name });
        try map.put(try a.dupe(u8, id), path);
    }
    return map;
}

/// The library id in `<id>-<version>.klio-pack`: the version starts at the
/// first dash followed by a digit.
fn libIdFromBasename(basename: []const u8) ?[]const u8 {
    const stem = if (std.mem.endsWith(u8, basename, ".klio-pack"))
        basename[0 .. basename.len - ".klio-pack".len]
    else
        basename;
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, stem, i, '-')) |dash| {
        if (dash + 1 < stem.len and std.ascii.isDigit(stem[dash + 1])) {
            return if (dash == 0) null else stem[0..dash];
        }
        i = dash + 1;
    }
    return null;
}

fn readSection(reader: *PackReader, name: []const u8) ?[]const u8 {
    var perr: PackError = undefined;
    const payload = (reader.readSection(name, &perr) catch return null) orelse return null;
    return payload.slice();
}

fn readFileOpt(a: Allocator, fio: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fio, path, a, .unlimited) catch null;
}

fn absPath(a: Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return a.dupe(u8, path);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&buf, buf.len) == null) return a.dupe(u8, path);
    const len = std.mem.findScalar(u8, &buf, 0) orelse buf.len;
    return std.fs.path.resolve(a, &.{ buf[0..len], path });
}

fn renderSetsFile(a: Allocator, sets: []const schema.SourceSetEntry) Allocator.Error![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    for (sets) |set| {
        try appendFmt(a, &s, "{s}\t{s}\t{d}\t{d}\n", .{
            set.root,
            set.feature,
            @intFromBool(set.has_expect),
            @intFromBool(set.has_actual),
        });
    }
    return s.items;
}

fn parseSetsFile(a: Allocator, text: []const u8) Allocator.Error![]schema.SourceSetEntry {
    var out: std.ArrayList(schema.SourceSetEntry) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const root = f.next() orelse continue;
        const feature = f.next() orelse "";
        const e = f.next() orelse "0";
        const act = f.next() orelse "0";
        try out.append(a, .{
            .root = try a.dupe(u8, root),
            .feature = try a.dupe(u8, feature),
            .has_expect = e.len > 0 and e[0] == '1',
            .has_actual = act.len > 0 and act[0] == '1',
        });
    }
    return out.items;
}

fn appendFmt(
    a: Allocator,
    buf: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const text = try std.fmt.allocPrint(a, fmt, args);
    try buf.appendSlice(a, text);
}

fn appendJsonArray(a: Allocator, buf: *std.ArrayList(u8), items: []const []const u8) Allocator.Error!void {
    try buf.append(a, '[');
    for (items, 0..) |item, i| {
        if (i != 0) try buf.appendSlice(a, ", ");
        try appendJsonString(a, buf, item);
    }
    try buf.append(a, ']');
}

fn appendJsonString(a: Allocator, buf: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    try appendFmt(a, buf, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(a, c);
                }
            },
        }
    }
    try buf.append(a, '"');
}

fn optionValue(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    return arg[prefix.len..];
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn usageErr(gpa: Allocator, msg: []const u8) u8 {
    io.printStderr(gpa, "error: {s}\n\n{s}", .{ msg, USAGE });
    return 2;
}

test "library id parses out of an installed pack basename" {
    try std.testing.expectEqualStrings("kotlinx.coroutines", libIdFromBasename("kotlinx.coroutines-1.11.0.klio-pack").?);
    try std.testing.expectEqualStrings("io.ktor", libIdFromBasename("io.ktor-3.5.1.klio-pack").?);
    try std.testing.expect(libIdFromBasename("noversion.klio-pack") == null);
}

test "source sets round-trip through the persisted sidecar" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    const sets = [_]schema.SourceSetEntry{
        .{ .root = "upstream/common", .feature = "", .has_expect = true, .has_actual = false },
        .{ .root = "klioMain", .feature = "extra", .has_expect = false, .has_actual = true },
    };
    const text = try renderSetsFile(al, &sets);
    const back = try parseSetsFile(al, text);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("upstream/common", back[0].root);
    try std.testing.expect(back[0].has_expect);
    try std.testing.expectEqualStrings("extra", back[1].feature);
    try std.testing.expect(back[1].has_actual);
}

test "a module id names the library and its root" {
    const a = std.testing.allocator;
    const both = try moduleId(a, "kotlinx.io", "upstream/core/common/src");
    defer a.free(both);
    try std.testing.expectEqualStrings("kotlinx.io:upstream/core/common/src", both);
    const bare = try moduleId(a, "kotlinx.io", "");
    defer a.free(bare);
    try std.testing.expectEqualStrings("kotlinx.io", bare);
}
