//! Project resolution from a directory's `klio.toml`. A `[[test]]` set composes for
//! `klio test` when its `feature` is unset (core) or active, a default feature or one
//! named by `--feature`; `[[source]]`/`source_roots` are the main sources for `klio run`.

const std = @import("std");
const pack_build = @import("pack_build.zig");
const lexer = @import("lexer");
const parser = @import("parser");
const span = @import("span");

const Allocator = std.mem.Allocator;

pub const FeatureSel = union(enum) {
    all,
    selected: []const []const u8,
};

pub const TestPlan = struct {
    /// Its pack is built and installed so the library API resolves inside the tests.
    project_dir: []const u8,
    pack_id: []const u8,
    /// One program each, run in order. A manifest naming no group yields one.
    groups: []const TestGroup,
};

/// One test program: the roots that compose into it, and the features they need.
pub const TestGroup = struct {
    name: []const u8,
    /// Core plus active-feature test roots, project-dir-joined.
    roots: []const []const u8,
    /// The caller adds these to the requested-feature set before the pack loads.
    active_features: []const []const u8,
};

fn featureSelected(feature: []const u8, sel: FeatureSel, manifest: *const pack_build.LibraryToml) bool {
    if (feature.len == 0) return true; // core is always active
    switch (sel) {
        .all => {
            for (manifest.features.defs) |d| {
                if (std.mem.eql(u8, d.name, feature)) return true;
            }
            return false;
        },
        .selected => |names| {
            for (names) |n| {
                if (std.mem.eql(u8, n, feature)) return true;
            }
            return false;
        },
    }
}

/// The `[application]` surface for `klio bundle`, every path project-dir-joined.
pub const Application = struct {
    main: []const u8,
    /// Sorted, and includes `main`.
    sources: []const []const u8,
    name: []const u8,
    icon: []const u8,
    /// Each entry is `path[:mount]`.
    includes: []const []const u8,
};

/// Resolves the project at `dir`, discovering `main` when the manifest omits it:
/// exactly one source under the roots may declare one. Null without a readable manifest.
pub fn loadApplication(a: Allocator, dir: []const u8) ?Application {
    const toml_path = std.fs.path.join(a, &.{ dir, "klio.toml" }) catch return null;
    const text = pack_build.readFileOwned(a, toml_path) orelse return null;
    const manifest = switch (pack_build.parseLibraryToml(a, text)) {
        .ok => |m| m,
        .err => return null,
    };
    const app = manifest.application;

    var roots: std.ArrayList([]const u8) = .empty;
    for (manifest.source) |s| {
        if (s.root.len != 0) roots.append(a, std.fs.path.join(a, &.{ dir, s.root }) catch continue) catch {};
    }
    for (manifest.library.source_roots) |r| {
        roots.append(a, std.fs.path.join(a, &.{ dir, r }) catch continue) catch {};
    }
    if (roots.items.len == 0) roots.append(a, a.dupe(u8, dir) catch return null) catch return null;

    var sources: std.ArrayList([]const u8) = .empty;
    for (roots.items) |root| collectKt(a, root, &sources);
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var main_path: ?[]const u8 = null;
    if (app.main.len != 0) {
        main_path = std.fs.path.join(a, &.{ dir, app.main }) catch return null;
        var listed = false;
        for (sources.items) |s| {
            if (std.mem.eql(u8, s, main_path.?)) listed = true;
        }
        if (!listed) sources.append(a, main_path.?) catch return null;
    } else {
        for (sources.items) |s| {
            if (!declaresMain(a, s)) continue;
            if (main_path != null) return null;
            main_path = s;
        }
    }
    const main = main_path orelse return null;

    var includes: std.ArrayList([]const u8) = .empty;
    for (app.include) |inc| {
        if (std.mem.findScalarLast(u8, inc, ':')) |colon| {
            const joined = std.fs.path.join(a, &.{ dir, inc[0..colon] }) catch continue;
            includes.append(a, std.fmt.allocPrint(a, "{s}:{s}", .{ joined, inc[colon + 1 ..] }) catch continue) catch {};
        } else {
            includes.append(a, std.fs.path.join(a, &.{ dir, inc }) catch continue) catch {};
        }
    }

    return .{
        .main = main,
        .sources = sources.toOwnedSlice(a) catch return null,
        .name = app.name,
        .icon = if (app.icon.len != 0) std.fs.path.join(a, &.{ dir, app.icon }) catch "" else "",
        .includes = includes.toOwnedSlice(a) catch return null,
    };
}

fn collectKt(a: Allocator, path: []const u8, out: *std.ArrayList([]const u8)) void {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const fio = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(fio, path, .{ .iterate = true }) catch {
        if (std.mem.endsWith(u8, path, ".kt")) out.append(a, a.dupe(u8, path) catch return) catch {};
        return;
    };
    defer dir.close(fio);
    var walker = dir.walk(a) catch return;
    defer walker.deinit();
    while (walker.next(fio) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".kt")) continue;
        const joined = std.fs.path.join(a, &.{ path, entry.path }) catch continue;
        out.append(a, joined) catch {};
    }
}

fn declaresMain(a: Allocator, path: []const u8) bool {
    const text = pack_build.readFileOwned(a, path) orelse return false;
    var map = span.SourceMap.init(a);
    const fid = map.add(path, text) catch return false;
    const src = map.get(fid).source;
    var lx = lexer.Lexer.init(a, fid, src) catch return false;
    const lexed = lx.tokenize() catch return false;
    if (lexed.diagnostics.hasErrors()) return false;
    const p = parser.Parser.new(a, fid, src, lexed.tokens, lexed.strings);
    const file_ast = p.parseFile();
    if (p.diagnostics.hasErrors()) return false;
    for (file_ast.decls) |d| {
        if (d == .Function and std.mem.eql(u8, d.Function.name.name, "main")) return true;
    }
    return false;
}

/// Composes the active `[[test]]` roots of the project at `dir` under `sel`. Null when
/// `dir` has no readable manifest or no tests, which the caller reads as a bare source dir.
pub fn planTest(a: Allocator, dir: []const u8, sel: FeatureSel) ?TestPlan {
    const toml_path = std.fs.path.join(a, &.{ dir, "klio.toml" }) catch return null;
    const text = pack_build.readFileOwned(a, toml_path) orelse return null;
    const manifest = switch (pack_build.parseLibraryToml(a, text)) {
        .ok => |m| m,
        .err => return null,
    };
    if (manifest.tests.len == 0) return null;

    // The groups the selected roots name, in first-seen order. None means a
    // single unnamed program holding every selected root.
    var names: std.ArrayList([]const u8) = .empty;
    for (manifest.tests) |t| {
        if (t.root.len == 0 or t.group.len == 0) continue;
        if (!featureSelected(t.feature, sel, &manifest)) continue;
        var seen = false;
        for (names.items) |x| if (std.mem.eql(u8, x, t.group)) {
            seen = true;
            break;
        };
        if (!seen) names.append(a, t.group) catch continue;
    }
    if (names.items.len == 0) names.append(a, "") catch return null;

    var groups: std.ArrayList(TestGroup) = .empty;
    for (names.items) |name| {
        var roots: std.ArrayList([]const u8) = .empty;
        var active: std.ArrayList([]const u8) = .empty;
        for (manifest.tests) |t| {
            if (t.root.len == 0) continue;
            // An ungrouped root joins every group; a grouped one only its own.
            if (t.group.len != 0 and !std.mem.eql(u8, t.group, name)) continue;
            if (!featureSelected(t.feature, sel, &manifest)) continue;
            const joined = std.fs.path.join(a, &.{ dir, t.root }) catch continue;
            roots.append(a, joined) catch continue;
            if (t.feature.len != 0) {
                const dup = a.dupe(u8, t.feature) catch continue;
                var seen = false;
                for (active.items) |x| if (std.mem.eql(u8, x, dup)) {
                    seen = true;
                    break;
                };
                if (!seen) active.append(a, dup) catch {};
            }
        }
        if (roots.items.len == 0) continue;
        groups.append(a, .{
            .name = name,
            .roots = roots.toOwnedSlice(a) catch continue,
            .active_features = active.toOwnedSlice(a) catch continue,
        }) catch continue;
    }
    if (groups.items.len == 0) return null;

    return TestPlan{
        .project_dir = a.dupe(u8, dir) catch return null,
        .pack_id = a.dupe(u8, manifest.library.id) catch return null,
        .groups = groups.toOwnedSlice(a) catch return null,
    };
}

/// The library whose own source `paths` belong to, or null. Walking up from a
/// source file to its `klio.toml` answers one question: are these files the
/// library itself? They are when the file sits under a declared source root, and
/// then the installed pack built from those same files must not load alongside
/// them. A file under a `[[test]]` root is a consumer, not the library, so it
/// resolves against the installed pack as usual.
pub fn owningLibraryId(a: Allocator, paths: []const []const u8) ?[]const u8 {
    const owner = owningManifest(a, paths) orelse return null;
    if (owner.cfg.library.id.len == 0) return null;
    for (paths) |p| {
        if (!underSourceRoot(a, owner.dir, &owner.cfg, p)) return null;
    }
    return owner.cfg.library.id;
}

const OwningManifest = struct { dir: []const u8, cfg: pack_build.LibraryToml };

/// The manifest governing `paths`, and the directory holding it. Absolute
/// first: a relative path runs out of components before the walk reaches the
/// working directory, and the manifest there goes unseen.
fn owningManifest(a: Allocator, paths: []const []const u8) ?OwningManifest {
    const first = if (paths.len != 0) paths[0] else return null;
    var dir = std.fs.path.dirname(absOrSelf(a, first)) orelse return null;

    while (true) {
        const toml_path = std.fs.path.join(a, &.{ dir, "klio.toml" }) catch return null;
        if (readFileAlloc(a, toml_path)) |text| {
            return switch (pack_build.parseLibraryToml(a, text)) {
                .ok => |c| .{ .dir = dir, .cfg = c },
                .err => null,
            };
        }
        dir = std.fs.path.dirname(dir) orelse return null;
        if (dir.len == 0) return null;
    }
}

fn underSourceRoot(a: Allocator, project_dir: []const u8, cfg: *const pack_build.LibraryToml, path: []const u8) bool {
    const abs = absOrSelf(a, path);
    for (cfg.library.source_roots) |root| {
        if (pathStartsWith(abs, absOrSelf(a, std.fs.path.join(a, &.{ project_dir, root }) catch return false))) return true;
    }
    for (cfg.source) |s| {
        if (pathStartsWith(abs, absOrSelf(a, std.fs.path.join(a, &.{ project_dir, s.root }) catch return false))) return true;
    }
    if (cfg.library.source_roots.len == 0 and cfg.source.len == 0) {
        return pathStartsWith(abs, absOrSelf(a, std.fs.path.join(a, &.{ project_dir, "src" }) catch return false));
    }
    return false;
}

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

fn absOrSelf(a: Allocator, path: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&buf, buf.len) == null) return path;
    const len = std.mem.findScalar(u8, &buf, 0) orelse buf.len;
    return std.fs.path.resolve(a, &.{ buf[0..len], path }) catch path;
}

fn readFileAlloc(a: Allocator, path: []const u8) ?[]u8 {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, a, .unlimited) catch null;
}

/// `owningLibraryId` as a load exclusion list, empty when the sources are not a
/// library's own.
pub fn ownLibraryExclusion(a: Allocator, paths: []const []const u8) []const []const u8 {
    const id = owningLibraryId(a, paths) orelse return &.{};
    const one = a.alloc([]const u8, 1) catch return &.{};
    one[0] = id;
    return one;
}

/// The `<pack>/<feature>` specs the manifest owning `paths` declares on its
/// dependencies. A manifest that asks for a dependency's feature is asking for
/// it whenever the project runs, not only when a `--feature` flag repeats it.
pub fn declaredFeatureSpecs(a: Allocator, paths: []const []const u8) []const []const u8 {
    const owner = owningManifest(a, paths) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (owner.cfg.deps) |dep| {
        for (dep.features) |feature| {
            const spec = std.fmt.allocPrint(a, "{s}/{s}", .{ dep.id, feature }) catch continue;
            out.append(a, spec) catch continue;
        }
    }
    return out.items;
}

/// The `[application] include` entries of the manifest owning `paths`, each
/// `path[:mount]` with its path joined to the project directory: the
/// resources `klio run` serves the program, as its bundle would carry them.
pub fn declaredIncludes(a: Allocator, paths: []const []const u8) []const []const u8 {
    const owner = owningManifest(a, paths) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (owner.cfg.application.include) |inc| {
        const joined = if (std.mem.findScalarLast(u8, inc, ':')) |colon|
            std.fmt.allocPrint(a, "{s}:{s}", .{ std.fs.path.join(a, &.{ owner.dir, inc[0..colon] }) catch continue, inc[colon + 1 ..] }) catch continue
        else
            std.fs.path.join(a, &.{ owner.dir, inc }) catch continue;
        out.append(a, joined) catch continue;
    }
    return out.items;
}

/// Libraries the running command needs whatever the project declares. `klio
/// test` runs `kotlin.test`: its `@Test` and assertions are the runner's own
/// dependency, so a library's test sources resolve them without the manifest
/// listing a dependency the library itself does not have.
pub var implicit_dependencies: []const []const u8 = &.{};

/// The dependency ids the manifest owning `paths` declares, or null when the
/// sources belong to no project. Null and empty differ: no manifest means the
/// old import-driven loading, while a manifest with no dependencies means a
/// project that uses nothing but the stdlib.
pub fn declaredDependencyIds(a: Allocator, paths: []const []const u8) ?[]const []const u8 {
    const owner = owningManifest(a, paths) orelse return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (owner.cfg.deps) |dep| out.append(a, dep.id) catch continue;
    // A project resolves against itself as well: its own sources are on the
    // command line, and its own pack may be installed.
    if (owner.cfg.library.id.len != 0) out.append(a, owner.cfg.library.id) catch {};
    for (implicit_dependencies) |id| out.append(a, id) catch {};
    return out.items;
}
