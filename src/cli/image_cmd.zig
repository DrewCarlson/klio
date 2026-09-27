//! The commands over base images: `klio bake` fills the cache a run reads,
//! `bake-image --stdlib-cache` bakes the image the build installs beside the
//! binary, `bake-image` writes a self-contained sema image (`sema_image`),
//! and `run-image` runs a program over one. `runOnImage` is the entry a
//! bundle boots through.

const std = @import("std");
const span = @import("span");
const lower_driver = @import("lower_driver");

const io = @import("io.zig");
const sema_cmd = @import("sema_cmd.zig");
const sema_run = @import("sema_run.zig");
const sema_base_cache = @import("sema_base_cache.zig");
const sema_image = @import("sema_image.zig");
const pack_cache = @import("pack_cache.zig");
const stdlib = @import("stdlib");

const Allocator = std.mem.Allocator;
const pipeline = lower_driver.pipeline;

/// `klio bake [files...]`: the base image each program's base needs is in
/// the cache after it; with no files, the base of a program without packs.
pub fn bake(gpa: Allocator, paths: []const []const u8, feature_specs: []const []const u8) u8 {
    if (sema_base_cache.disabled()) {
        io.writeStderr("error: the base image cache is disabled (KLIO_SEMA_IMAGE=0)\n");
        return 2;
    }
    const mem = sema_run.RunMemory.init() catch return 2;
    defer mem.deinit();
    var report: sema_cmd.LoadReport = .{};
    const loaded = sema_cmd.loadSources(mem.arena(), mem.map, paths, .{ .feature_specs = feature_specs, .report_pack_failures = true, .report = &report, .image = true });
    io.writeStderr(report.syntax.items);
    const src = loaded catch |e| return sema_run.loadFailed(gpa, e, &report);
    _ = sema_run.baseImage(gpa, mem.arena(), mem.map, src, sema_cmd.hostBinding(gpa)) catch |e| {
        io.printStderr(gpa, "error: could not bake a base image for this configuration: {s}\n", .{@errorName(e)});
        return 1;
    };
    io.writeStdout("stdlib image ready\n");
    return 0;
}

/// `klio bake-image --stdlib-cache <dir>`: the base image of a program
/// without packs, into `dir` under the name a run of this binary looks
/// for it by. The build installs `dir` as `share/klio/cache`, where a run
/// whose own cache misses finds it. `--for <exe>` names the image for
/// another klio built from the same sources: a cross build bakes its
/// target's image with a host binary, as it cannot run the target's.
pub fn bakeStdlibCache(gpa: Allocator, dir: []const u8, for_exe: ?[]const u8) u8 {
    sema_base_cache.stamp_exe = for_exe;
    defer sema_base_cache.stamp_exe = null;
    const mem = sema_run.RunMemory.init() catch return 2;
    defer mem.deinit();
    const a = mem.arena();
    var report: sema_cmd.LoadReport = .{};
    const src = sema_cmd.loadSources(a, mem.map, &.{}, .{ .with_packs = false, .report = &report }) catch |e| return sema_run.loadFailed(gpa, e, &report);
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().createDirPath(threaded.io(), dir) catch {
        io.printStderr(gpa, "error: cannot create {s}\n", .{dir});
        return 1;
    };
    const path = sema_base_cache.pathIn(a, dir, src.key orelse return 2) orelse {
        io.printStderr(gpa, "error: cannot name the base image in {s}\n", .{dir});
        return 1;
    };
    const baked = pipeline.bakeBase(a, gpa, src.base, sema_cmd.hostBinding(gpa), mem.map, src.record) catch |e| {
        io.printStderr(gpa, "error: the base image did not bake into {s}: {s}\n", .{ dir, @errorName(e) });
        return 1;
    };
    defer gpa.free(baked);
    sema_base_cache.writeOrFail(a, path, baked) catch |e| {
        io.printStderr(gpa, "error: cannot write {s}: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    return 0;
}

/// `klio bake-image <program.kt...> -o <out>`: the self-contained sema image
/// of the programs' base (the stdlib and the packs they import, with the
/// requested features). The programs themselves are not in it.
pub fn bakeImage(gpa: Allocator, paths: []const []const u8, feature_specs: []const []const u8, out_path: []const u8) u8 {
    const mem = sema_run.RunMemory.init() catch return 2;
    defer mem.deinit();
    const baked = bakeFor(gpa, mem, paths, null, feature_specs, null) catch |e| switch (e) {
        error.Reported => return 1,
        else => {
            io.printStderr(gpa, "error: the base image did not bake: {s}\n", .{@errorName(e)});
            return 1;
        },
    };
    const bytes = baked.bytes;
    defer gpa.free(bytes);
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = out_path, .data = bytes }) catch {
        io.printStderr(gpa, "error: cannot write {s}\n", .{out_path});
        return 1;
    };
    io.printStdout(gpa, "wrote {s} ({d} bytes)\n", .{ out_path, bytes.len });
    return 0;
}

/// A sema image baked for programs, and what loading them gave.
pub const Baked = struct {
    /// The encoded sema image, owned by `gpa`.
    bytes: []u8,
    /// The base and the programs, loaded as `klio run` loads them.
    src: pipeline.Sources,
    /// The base image the sema image holds.
    base: []const u8,
};

/// The sema image of the base `paths` run on (their text read from the
/// files, or given by `texts`). Loading problems are printed
/// (`error.Reported`). `selection` receives the packs the imports chose.
pub fn bakeFor(gpa: Allocator, mem: sema_run.RunMemory, paths: []const []const u8, texts: ?[]const []const u8, feature_specs: []const []const u8, selection: ?*pack_cache.Selection) !Baked {
    const a = mem.arena();
    var report: sema_cmd.LoadReport = .{};
    var recorded: std.ArrayList(sema_cmd.BaseFile) = .empty;
    var own_selection: pack_cache.Selection = .{};
    const sel = selection orelse &own_selection;
    const loaded = sema_cmd.loadSources(a, mem.map, paths, .{
        .feature_specs = feature_specs,
        .report_pack_failures = true,
        .report = &report,
        .record_base = &recorded,
        .selection = sel,
        .program_texts = texts,
    });
    io.writeStderr(report.syntax.items);
    const src = loaded catch |e| {
        _ = sema_run.loadFailed(gpa, e, &report);
        return error.Reported;
    };
    var packs: std.ArrayList([]const u8) = .empty;
    for (sel.packs.items) |sp| try packs.append(a, packId(a, sp.path));
    std.mem.sort([]const u8, packs.items, {}, lessThan);
    const features = try a.dupe([]const u8, feature_specs);
    std.mem.sort([]const u8, features, {}, lessThan);
    // The base's files go in only for a program the serialization pass
    // rewrites, which reads the packs' declarations: any other loads its
    // base from the image alone.
    const serialized = try sema_cmd.serializedPrograms(a, mem.map, src.program, src.record);
    const files = if (serialized) try sema_image.filesOf(a, recorded.items) else &.{};
    const known = try stdlib.knownPackagesSnapshot(a);
    // The image is only of use if a load from it gives the base the image
    // inside was baked against: checked here, against the one the cache
    // gave and, when that does not hold, one baked afresh.
    const binding = sema_cmd.hostBinding(gpa);
    var base = try sema_run.baseImage(gpa, a, mem.map, src, binding);
    var fresh = false;
    while (true) {
        const img: sema_image.Image = .{ .base = base, .files = files, .features = features, .packs = packs.items, .known_packages = known };
        const bytes = try sema_image.encode(gpa, &img);
        if (reloads(gpa, bytes, paths, texts)) return .{ .bytes = bytes, .src = src, .base = base };
        gpa.free(bytes);
        if (fresh) {
            io.writeStderr("error: the base does not load back from its image the way it was loaded to bake it\n");
            return error.Reported;
        }
        base = try sema_run.bakeBaseFresh(gpa, a, mem.map, src, binding);
        fresh = true;
    }
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Whether the programs build over the sema image `bytes` as they will
/// when it runs them: its base registered from its own files and checked
/// against the base image inside. Prints nothing.
fn reloads(gpa: Allocator, bytes: []const u8, paths: []const []const u8, texts: ?[]const []const u8) bool {
    const mem = sema_run.RunMemory.init() catch return false;
    defer mem.deinit();
    const a = mem.arena();
    const img = sema_image.decode(a, bytes) catch return false;
    const base = sema_image.baseOf(a, &img) catch return false;
    const src = sema_cmd.loadSources(a, mem.map, paths, .{ .base = base, .base_image = img.base, .program_texts = texts }) catch return false;
    _ = pipeline.buildOnImage(a, src.program, sema_cmd.hostBinding(gpa), img.base, null) catch return false;
    return true;
}

/// A selected pack's library id, read from its manifest; the file's name
/// when the manifest does not read.
fn packId(a: Allocator, path: []const u8) []const u8 {
    switch (pack_cache.readPackManifest(a, path)) {
        .ok => |m| return m.library_id,
        .err => {},
    }
    const base = std.fs.path.basename(path);
    return if (std.mem.endsWith(u8, base, ".klio-pack")) base[0 .. base.len - ".klio-pack".len] else base;
}

/// `klio run-image <image> <program.kt...> [args...]`.
pub fn runImage(gpa: Allocator, image_path: []const u8, paths: []const []const u8, args: []const []const u8) u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    // The run reads the base's names and bodies out of the image, so it
    // lives as long as the process.
    const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), image_path, std.heap.page_allocator, .unlimited) catch {
        io.printStderr(gpa, "error: cannot read base image {s}\n", .{image_path});
        return 1;
    };
    return runOnImage(gpa, bytes, paths, null, args, "rebake it with this klio");
}

/// Runs the programs `paths` (their text read from the files, or given by
/// `texts`) over the sema image `bytes` with `main(args)`. Nothing is read
/// from the data home or the checkout. `remedy` says what to do about an
/// image this klio cannot run over.
pub fn runOnImage(gpa: Allocator, bytes: []const u8, paths: []const []const u8, texts: ?[]const []const u8, args: []const []const u8, remedy: []const u8) u8 {
    pipeline.hooks.start();
    const mem = sema_run.RunMemory.init() catch return 2;
    defer mem.deinit();
    const a = mem.arena();
    const img = sema_image.decode(a, bytes) catch |e| {
        io.printStderr(gpa, "error: base image rejected ({s}); {s}\n", .{ switch (e) {
            error.Stale => "written by another klio",
            error.Malformed => "not a sema image",
            error.OutOfMemory => "out of memory",
        }, remedy });
        return 1;
    };
    for (img.known_packages) |pkg| stdlib.registerKnownPackage(pkg);
    const base = sema_image.baseOf(a, &img) catch return 2;
    const p = switch (sema_run.prepare(gpa, mem, paths, .{ .base = base, .base_image = img.base, .program_texts = texts }, .{ .bytes = img.base, .remedy = remedy })) {
        .ok => |ok| ok,
        .exit => |code| return code,
    };
    return sema_run.runBuilt(gpa, a, mem.map, p.src.program, &p.built, args);
}
