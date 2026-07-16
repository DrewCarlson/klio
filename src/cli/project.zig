//! Project resolution for `klio test` / `klio run`: read a directory's
//! `klio.toml` and compose its active source sets. The bridge from a project
//! manifest to the existing file-list run/test pipeline.
//!
//! A `[[test]]` set is composed for `klio test` when its `feature` is unset
//! (core) or active (a default feature, or one requested via
//! `--feature <pack>/<feat>`). The manifest's own `[[source]]`/`source_roots`
//! are the project's main sources for `klio run`.

const std = @import("std");
const pack_build = @import("pack_build.zig");
const lexer = @import("lexer");
const parser = @import("parser");
const span = @import("span");

const Allocator = std.mem.Allocator;

/// Which features' tests to compose for a `klio test` run.
pub const FeatureSel = union(enum) {
    /// Core + every feature module (the default, and `--all`).
    all,
    /// Core + exactly these features (`--feature X` one or more times).
    selected: []const []const u8,
};

pub const TestPlan = struct {
    /// Project directory (holds `klio.toml`). Its pack is built+installed so
    /// the library API resolves inside the tests.
    project_dir: []const u8,
    /// The manifest's library id (names the built pack: `target/packs/<id>.klio-pack`).
    pack_id: []const u8,
    /// Composed test source roots (project-dir-joined; core + active features).
    roots: []const []const u8,
    /// Features whose sources must be activated so their tests compile — the
    /// caller adds these to the requested-feature set before the pack loads.
    active_features: []const []const u8,
};

fn featureSelected(feature: []const u8, sel: FeatureSel, manifest: *const pack_build.LibraryToml) bool {
    if (feature.len == 0) return true; // core is always active
    switch (sel) {
        .all => {
            // Active iff it is a declared feature of this project.
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

/// The resolved `[application]` surface of a project for `klio bundle`.
/// All paths are project-dir-joined.
pub const Application = struct {
    /// The file carrying `main` (manifest `main`, or discovered).
    main: []const u8,
    /// Every project source file (sorted; includes `main`).
    sources: []const []const u8,
    name: []const u8,
    icon: []const u8,
    /// Raw `include = [...]` values (path[:mount]), dir-joined paths.
    includes: []const []const u8,
};

/// Resolve the project at `dir` for `klio bundle <dir>`: read its
/// `klio.toml`, join the `[application]` table's paths, and discover the
/// `main` source when the manifest omits it (exactly one source under the
/// project's roots may declare a top-level `main`). Null when there is no
/// readable manifest or no main can be determined.
pub fn loadApplication(a: Allocator, dir: []const u8) ?Application {
    const toml_path = std.fs.path.join(a, &.{ dir, "klio.toml" }) catch return null;
    const text = pack_build.readFileOwned(a, toml_path) orelse return null;
    const manifest = switch (pack_build.parseLibraryToml(a, text)) {
        .ok => |m| m,
        .err => return null,
    };
    const app = manifest.application;

    // Source roots: `[[source]]` roots, else the manifest's `source_roots`,
    // else the project directory itself.
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
            if (main_path != null) return null; // ambiguous: manifest must name it
            main_path = s;
        }
    }
    const main = main_path orelse return null;

    var includes: std.ArrayList([]const u8) = .empty;
    for (app.include) |inc| {
        // Join only the path half of `path[:mount]`.
        if (std.mem.lastIndexOfScalar(u8, inc, ':')) |colon| {
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

/// Whether the file parses and declares a top-level `fun main`.
fn declaresMain(a: Allocator, path: []const u8) bool {
    const text = pack_build.readFileOwned(a, path) orelse return false;
    var map = span.SourceMap.init(a);
    const fid = map.add(path, text) catch return false;
    const src = map.get(fid).source;
    var lx = lexer.Lexer.init(a, fid, src) catch return false;
    const lexed = lx.tokenize() catch return false;
    if (lexed.diagnostics.hasErrors()) return false;
    const p = parser.Parser.new(a, fid, src, lexed.tokens);
    const file_ast = p.parseFile();
    if (p.diagnostics.hasErrors()) return false;
    for (file_ast.decls) |d| {
        if (d == .Function and std.mem.eql(u8, d.Function.name.name, "main")) return true;
    }
    return false;
}

/// Compose the active `[[test]]` roots of the project at `dir` under the given
/// feature selection. Returns null when `dir` has no readable manifest or
/// declares no tests (the caller then falls back to treating `dir` as a bare
/// source directory). Allocations are in `a`.
pub fn planTest(a: Allocator, dir: []const u8, sel: FeatureSel) ?TestPlan {
    const toml_path = std.fs.path.join(a, &.{ dir, "klio.toml" }) catch return null;
    const text = pack_build.readFileOwned(a, toml_path) orelse return null;
    const manifest = switch (pack_build.parseLibraryToml(a, text)) {
        .ok => |m| m,
        .err => return null,
    };
    if (manifest.tests.len == 0) return null;

    var roots: std.ArrayList([]const u8) = .empty;
    var active: std.ArrayList([]const u8) = .empty;
    for (manifest.tests) |t| {
        if (t.root.len == 0) continue;
        if (!featureSelected(t.feature, sel, &manifest)) continue;
        const joined = std.fs.path.join(a, &.{ dir, t.root }) catch continue;
        roots.append(a, joined) catch continue;
        if (t.feature.len != 0) {
            const dup = a.dupe(u8, t.feature) catch continue;
            // De-dup: a feature with several test roots activates once.
            var seen = false;
            for (active.items) |x| if (std.mem.eql(u8, x, dup)) {
                seen = true;
                break;
            };
            if (!seen) active.append(a, dup) catch {};
        }
    }
    if (roots.items.len == 0) return null;

    return TestPlan{
        .project_dir = a.dupe(u8, dir) catch return null,
        .pack_id = a.dupe(u8, manifest.library.id) catch return null,
        .roots = roots.toOwnedSlice(a) catch return null,
        .active_features = active.toOwnedSlice(a) catch return null,
    };
}
