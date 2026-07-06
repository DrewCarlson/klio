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
const pack_cache = @import("pack_cache.zig");

const Allocator = std.mem.Allocator;
const RequestedFeatures = pack_cache.RequestedFeatures;

pub const TestPlan = struct {
    /// Project directory (holds `klio.toml`). Its pack is built+installed so
    /// the library API resolves inside the tests.
    project_dir: []const u8,
    /// The manifest's library id (names the built pack: `target/packs/<id>.klio-pack`).
    pack_id: []const u8,
    /// Composed test source roots (project-dir-joined; core + active features).
    roots: []const []const u8,
};

fn featureActive(
    feature: []const u8,
    pack_id: []const u8,
    manifest: *const pack_build.LibraryToml,
    features: *const RequestedFeatures,
) bool {
    if (feature.len == 0) return true;
    for (manifest.features.default) |d| {
        if (std.mem.eql(u8, d, feature)) return true;
    }
    if (features.get(pack_id)) |set| {
        if (set.contains(feature)) return true;
    }
    return false;
}

/// Compose the active `[[test]]` roots of the project at `dir`. Returns null
/// when `dir` has no readable manifest or declares no tests (the caller then
/// falls back to treating `dir` as a bare source directory). Allocations are
/// in `a`.
pub fn planTest(a: Allocator, dir: []const u8, features: *const RequestedFeatures) ?TestPlan {
    const toml_path = std.fs.path.join(a, &.{ dir, "klio.toml" }) catch return null;
    const text = pack_build.readFileOwned(a, toml_path) orelse return null;
    const manifest = switch (pack_build.parseLibraryToml(a, text)) {
        .ok => |m| m,
        .err => return null,
    };
    if (manifest.tests.len == 0) return null;

    var roots: std.ArrayList([]const u8) = .empty;
    for (manifest.tests) |t| {
        if (t.root.len == 0) continue;
        if (!featureActive(t.feature, manifest.library.id, &manifest, features)) continue;
        const joined = std.fs.path.join(a, &.{ dir, t.root }) catch continue;
        roots.append(a, joined) catch continue;
    }
    if (roots.items.len == 0) return null;

    return TestPlan{
        .project_dir = a.dupe(u8, dir) catch return null,
        .pack_id = a.dupe(u8, manifest.library.id) catch return null,
        .roots = roots.toOwnedSlice(a) catch return null,
    };
}
