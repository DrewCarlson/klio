//! `klio bundle`: turn a Kotlin program plus its baked dependency image,
//! embedded resources, and (for Compose) the Skia backend into one
//! self-contained executable. Bundling is file surgery: copy the running `klio`
//! binary (the stub), append an aligned payload area (`pack.bundle_format`), and
//! write the trailer. No compiler or linker runs, but the whole assemble-and-lower
//! pipeline does, so every resolution diagnostic surfaces at bundle time.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;


const pack = @import("pack");
const bf = pack.bundle_format;

const runtime = @import("runtime");
const stdlib = @import("stdlib");

const io = @import("io.zig");
const pack_cache = @import("pack_cache.zig");
const project = @import("project.zig");
const macho_sign = @import("macho_sign.zig");
const lower_driver = @import("lower_driver");
const sema_cmd = @import("sema_cmd.zig");
const sema_run = @import("sema_run.zig");
const sema_image = @import("sema_image.zig");
const image_cmd = @import("image_cmd.zig");
const pipeline = lower_driver.pipeline;

pub const Options = struct {
    input: []const u8 = "",
    output: ?[]const u8 = null,
    target: ?[]const u8 = null,
    /// null = auto-detect off the pack fixpoint.
    ui: ?bool = null,
    includes: std.ArrayList(Include) = .empty,
    name: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    stub: ?[]const u8 = null,
    dry_run: bool = false,
    desktop_dir: ?[]const u8 = null,
    app_dir: ?[]const u8 = null,
    feature_specs: std.ArrayList([]const u8) = .empty,
};

pub const Include = struct {
    path: []const u8,
    mount: []const u8,
};

const USAGE =
    \\usage: klio bundle <main.kt | project-dir> [options]
    \\
    \\  -o, --output <path>        Output executable (default: source basename)
    \\  --target <target>          linux-x64 (default: host), linux-arm64,
    \\                             macos-x64, macos-arm64, windows-x64, windows-arm64
    \\  --ui | --headless          Force the flavor (default: auto-detected)
    \\  --include <path[:mount]>   Embed a file or directory as resources (repeatable)
    \\  --name <string>            App display name (default: output basename)
    \\  --icon <png>               App icon source (single square PNG)
    \\  --feature <pack>/<feat>    Enable a pack feature (repeatable)
    \\  --stub <path>              Explicit stub binary (skips self-copy/fetch)
    \\  --desktop-dir <dir>        Also emit <name>.desktop + icon PNG (linux)
    \\  --app-dir <dir>            Also emit <name>.app around the bundle (macos)
    \\  --dry-run                  Print the resolved pack set, flavor, sections,
    \\                             and projected size without writing
    \\
;

pub fn runBundle(gpa: Allocator, args: []const []const u8) u8 {
    var opts = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (flagValue(args, &i, "-o", "--output")) |v| {
            opts.output = v orelse return usageErr(gpa, "--output requires a path");
        } else if (flagValue(args, &i, null, "--target")) |v| {
            opts.target = v orelse return usageErr(gpa, "--target requires a target name");
        } else if (std.mem.eql(u8, a, "--ui")) {
            opts.ui = true;
        } else if (std.mem.eql(u8, a, "--headless")) {
            opts.ui = false;
        } else if (flagValue(args, &i, null, "--include")) |v| {
            const val = v orelse return usageErr(gpa, "--include requires a path[:mount]");
            const inc = parseInclude(val);
            opts.includes.append(gpa, inc) catch return 2;
        } else if (flagValue(args, &i, null, "--name")) |v| {
            opts.name = v orelse return usageErr(gpa, "--name requires a value");
        } else if (flagValue(args, &i, null, "--icon")) |v| {
            opts.icon = v orelse return usageErr(gpa, "--icon requires a png path");
        } else if (flagValue(args, &i, null, "--stub")) |v| {
            opts.stub = v orelse return usageErr(gpa, "--stub requires a path");
        } else if (flagValue(args, &i, null, "--desktop-dir")) |v| {
            opts.desktop_dir = v orelse return usageErr(gpa, "--desktop-dir requires a directory");
        } else if (flagValue(args, &i, null, "--app-dir")) |v| {
            opts.app_dir = v orelse return usageErr(gpa, "--app-dir requires a directory");
        } else if (flagValue(args, &i, null, "--feature")) |v| {
            const val = v orelse return usageErr(gpa, "--feature requires a `<pack>/<feature>` value");
            opts.feature_specs.append(gpa, val) catch return 2;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            io.printStderr(gpa, "error: unknown option `{s}`\n\n{s}", .{ a, USAGE });
            return 2;
        } else {
            if (opts.input.len != 0) return usageErr(gpa, "expected exactly one input");
            opts.input = a;
        }
    }
    if (opts.input.len == 0) {
        io.writeStderr(USAGE);
        return 2;
    }
    return bundle(gpa, &opts);
}

/// `--flag value` / `--flag=value` / short alias. Returns null when `args[i]`
/// is not this flag; `?null` (inner null) when the value is missing.
fn flagValue(
    args: []const []const u8,
    i: *usize,
    short: ?[]const u8,
    long: []const u8,
) ??[]const u8 {
    const a = args[i.*];
    const matches = std.mem.eql(u8, a, long) or (short != null and std.mem.eql(u8, a, short.?));
    if (matches) {
        if (i.* + 1 >= args.len) return @as(?[]const u8, null);
        i.* += 1;
        return @as(?[]const u8, args[i.*]);
    }
    if (std.mem.startsWith(u8, a, long) and a.len > long.len and a[long.len] == '=') {
        return @as(?[]const u8, a[long.len + 1 ..]);
    }
    return null;
}

fn parseInclude(val: []const u8) Include {
    if (std.mem.findScalarLast(u8, val, ':')) |colon| {
        return .{ .path = val[0..colon], .mount = val[colon + 1 ..] };
    }
    return .{ .path = val, .mount = "" };
}

fn usageErr(gpa: Allocator, msg: []const u8) u8 {
    io.printStderr(gpa, "error: {s}\n\n{s}", .{ msg, USAGE });
    return 2;
}

const target_names = [_][]const u8{
    "linux-x64", "linux-arm64", "macos-x64", "macos-arm64", "windows-x64", "windows-arm64",
};

pub fn hostTarget() []const u8 {
    return switch (builtin.os.tag) {
        .linux => if (builtin.cpu.arch == .x86_64) "linux-x64" else "linux-arm64",
        .macos => if (builtin.cpu.arch == .x86_64) "macos-x64" else "macos-arm64",
        .windows => if (builtin.cpu.arch == .x86_64) "windows-x64" else "windows-arm64",
        else => "unknown",
    };
}

fn bundle(gpa: Allocator, opts: *Options) u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const fio = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const target = opts.target orelse hostTarget();
    var target_known = false;
    for (target_names) |t| {
        if (std.mem.eql(u8, t, target)) target_known = true;
    }
    if (!target_known) {
        io.printStderr(gpa, "error: unknown --target `{s}`\n", .{target});
        return 2;
    }
    const cross = !std.mem.eql(u8, target, hostTarget());

    var proj: ?project.Application = null;
    var main_path: []const u8 = opts.input;
    var paths: []const []const u8 = undefined;
    if (isDirectory(fio, opts.input)) {
        proj = project.loadApplication(gpa, opts.input) orelse {
            io.printStderr(gpa, "error: `{s}` is a directory but has no klio.toml with an [application] table (or a single main .kt)\n", .{opts.input});
            return 2;
        };
        main_path = proj.?.main;
        paths = proj.?.sources;
        if (opts.name == null and proj.?.name.len != 0) opts.name = proj.?.name;
        if (opts.icon == null and proj.?.icon.len != 0) opts.icon = proj.?.icon;
        for (proj.?.includes) |inc| {
            opts.includes.append(gpa, parseInclude(inc)) catch return 2;
        }
    } else {
        const single = gpa.alloc([]const u8, 1) catch return 2;
        single[0] = opts.input;
        paths = single;
    }
    if (!std.mem.endsWith(u8, main_path, ".kt")) {
        io.printStderr(gpa, "error: expected a `.kt` source file, got `{s}`\n", .{main_path});
        return 2;
    }

    const out_path = opts.output orelse defaultOutput(gpa, main_path, target) catch return 2;
    const app_name = opts.name orelse std.fs.path.basename(out_path);

    for (opts.feature_specs.items) |spec| {
        if (std.mem.findScalar(u8, spec, '/') == null) {
            io.printStderr(gpa, "error: --feature `{s}` must be `<pack>/<feature>`\n", .{spec});
            return 2;
        }
    }

    var prog_result = program(gpa, paths, opts.feature_specs.items);
    const prog = switch (prog_result) {
        .ok => |*p| p,
        .exit => |code| return code,
    };

    const is_ui = opts.ui orelse detectUiFlavor(&prog.selection);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program_src = encodeProgramSources(arena, paths, prog.texts) catch return 1;

    var resources_blob: std.ArrayList(u8) = .empty;
    var resource_entries: std.ArrayList(bf.ResourceEntry) = .empty;
    for (opts.includes.items) |inc| {
        if (!collectInclude(arena, fio, inc, main_path, &resources_blob, &resource_entries)) {
            io.printStderr(gpa, "error: cannot read --include `{s}`\n", .{inc.path});
            return 2;
        }
    }

    var shim_bytes: ?[]const u8 = null;
    if (is_ui) {
        shim_bytes = findShimBytes(arena, fio, target) orelse {
            io.printStderr(gpa, "error: this is a UI bundle but no Skia backend library was found for {s}; build it (zig build skia-lib) or set KLIO_SKIA_LIB\n", .{target});
            return 1;
        };
        if (programOpensWindow(prog.texts)) {
            switch (skiaWindowSupport(shim_bytes.?)) {
                .ok => {},
                .stub => {
                    io.printStderr(gpa, "error: this Compose UI program opens a window, but the Skia backend for {s} has no windowing support (it renders offscreen only, so the app would open no window and exit silently).\n  {s}\n", .{ target, rebuildHint(target) });
                    return 1;
                },
                .unknown => {
                    io.printStderr(gpa, "warning: cannot confirm the Skia backend for {s} supports a window (no capability marker); if the bundle opens no window, {s}\n", .{ target, rebuildHint(target) });
                },
            }
        }
    }

    var icon_bytes: ?[]const u8 = null;
    if (opts.icon) |icon_path| {
        icon_bytes = cwd.readFileAlloc(fio, icon_path, arena, .unlimited) catch {
            io.printStderr(gpa, "error: cannot read --icon `{s}`\n", .{icon_path});
            return 2;
        };
    }

    const manifest = buildManifest(arena, .{
        .flavor = if (is_ui) bf.Flavor.ui else bf.Flavor.headless,
        .name = app_name,
        .selection = &prog.selection,
        .resources = resource_entries.items,
    }) catch return 1;
    var perr: pack.PackError = undefined;
    const manifest_bytes = (pack.write.encode(bf.BundleManifest, arena, &manifest, &perr) catch return 1) orelse return 1;

    const stub_path = opts.stub orelse blk: {
        if (cross) {
            const fetched = @import("stub_fetch.zig").resolveStub(gpa, target, VERSION) orelse {
                io.printStderr(gpa, "error: no cached stub for {s} (klio {s}); connect once to fetch it, or pass --stub <path>\n", .{ target, VERSION });
                return 1;
            };
            break :blk fetched;
        }
        break :blk selfExePath(arena) orelse {
            io.writeStderr("error: cannot resolve the running executable path\n");
            return 1;
        };
    };

    var w = bf.Writer.init(gpa);
    defer w.deinit();
    w.addSection(bf.section_names.MANIFEST, manifest_bytes.items, .none, false) catch return 1;
    w.addSection(bf.section_names.SEMA_IMAGE, prog.sema_image, .none, true) catch return 1;
    w.addSection(bf.section_names.PROGRAM_SRC, program_src, .none, false) catch return 1;
    if (resource_entries.items.len != 0) {
        w.addSection(bf.section_names.RESOURCES, resources_blob.items, .none, false) catch return 1;
    }
    if (shim_bytes) |sb| {
        w.addSection(bf.section_names.SKIA_SHIM, sb, .zstd, false) catch return 1;
    }
    if (icon_bytes) |ib| {
        w.addSection(bf.section_names.ICON, ib, .none, false) catch return 1;
    }

    const stub_bytes = cwd.readFileAlloc(fio, stub_path, arena, .unlimited) catch {
        io.printStderr(gpa, "error: cannot read stub `{s}`\n", .{stub_path});
        return 1;
    };

    // macOS: the payload cannot trail the linker's code signature (the arm64
    // kernel refuses data past it). Strip the stub's signature, put the overlay in
    // its place, and re-sign ad hoc, which leaves the trailer at
    // `LC_CODE_SIGNATURE.dataoff - 72`. An unsigned x86_64 stub appends plainly.
    var macho: ?macho_sign.MachoInfo = null;
    var base_len: u64 = stub_bytes.len;
    if (std.mem.startsWith(u8, target, "macos")) {
        if (macho_sign.parse(stub_bytes)) |info| {
            macho = info;
            base_len = info.codesig_dataoff;
        } else if (std.mem.endsWith(u8, target, "arm64")) {
            io.writeStderr("error: the macos-arm64 stub is not a code-signed Mach-O and cannot be bundled\n");
            return 1;
        }
    }

    const tail = (w.finish(base_len, &perr) catch return 1) orelse {
        io.printStderr(gpa, "error: bundle assembly failed: {f}\n", .{perr});
        return 1;
    };
    defer gpa.free(tail);

    if (opts.dry_run) {
        printDryRun(gpa, &manifest, &w, @intCast(base_len), tail.len, out_path);
        return 0;
    }

    var total: usize = 0;
    {
        const core_len: usize = @intCast(base_len);
        var whole: std.ArrayList(u8) = .empty;
        defer whole.deinit(gpa);
        whole.ensureTotalCapacityPrecise(gpa, core_len + tail.len) catch return 1;
        whole.appendSliceAssumeCapacity(stub_bytes[0..core_len]);
        whole.appendSliceAssumeCapacity(tail);

        var signed: ?[]u8 = null;
        defer if (signed) |s| gpa.free(s);
        const final_bytes: []const u8 = if (macho) |info| blk: {
            const s = macho_sign.sign(gpa, whole.items, info, std.fs.path.basename(out_path)) catch return 1;
            signed = s;
            break :blk s;
        } else whole.items;
        total = final_bytes.len;

        cwd.writeFile(fio, .{ .sub_path = out_path, .data = final_bytes }) catch {
            io.printStderr(gpa, "error: cannot write `{s}`\n", .{out_path});
            return 1;
        };
    }
    markExecutable(out_path);

    if (opts.desktop_dir) |dir| {
        emitDesktopFiles(gpa, fio, dir, app_name, out_path, icon_bytes);
    }

    if (opts.app_dir) |dir| {
        if (std.mem.startsWith(u8, target, "macos")) {
            emitAppBundle(gpa, fio, dir, app_name, out_path, icon_bytes);
        } else {
            io.writeStderr("note: --app-dir applies to macOS targets; ignored\n");
        }
    }
    var packs_summary: std.ArrayList(u8) = .empty;
    defer packs_summary.deinit(gpa);
    packs_summary.appendSlice(gpa, "stdlib") catch {};
    for (manifest.packs) |p| {
        packs_summary.appendSlice(gpa, " + ") catch {};
        packs_summary.appendSlice(gpa, p.id) catch {};
    }
    if (is_ui) packs_summary.appendSlice(gpa, " + skia backend") catch {};
    io.printStdout(gpa, "bundled {s} ({d:.1} MB{s}): {s}\n", .{
        out_path,
        @as(f64, @floatFromInt(total)) / (1024.0 * 1024.0),
        if (is_ui) @as([]const u8, ", ui") else "",
        packs_summary.items,
    });
    return 0;
}

/// What a bundle carries of its program, and what the manifest says of it.
const Program = struct {
    texts: [][]const u8,
    selection: pack_cache.Selection = .{},
    /// The base's image and sources, over which the program's sources build
    /// at boot.
    sema_image: []const u8 = &.{},
};

const ProgramResult = union(enum) { ok: Program, exit: u8 };

/// The program's payload: a sema image of its base. Bundling is the check a
/// run makes: the program builds over that image and has a `main`, or the
/// bundle is refused with why.
fn program(gpa: Allocator, paths: []const []const u8, feature_specs: []const []const u8) ProgramResult {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const texts = gpa.alloc([]const u8, paths.len) catch return .{ .exit = 2 };
    for (paths, texts) |path, *t| {
        t.* = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .unlimited) catch {
            io.printStderr(gpa, "error: cannot read {s}: ReadFailed\n", .{path});
            return .{ .exit = 1 };
        };
    }
    // A bundle's resources are read through `klio.bundle`: the bundler's own
    // library, which a project using them need not declare.
    project.implicit_dependencies = &.{"klio.bundle"};
    // Lives as long as the process: the bundle is its last use.
    const mem = sema_run.RunMemory.init() catch return .{ .exit = 2 };
    var prog: Program = .{ .texts = texts };
    const baked = image_cmd.bakeFor(gpa, mem, paths, texts, feature_specs, &prog.selection) catch |e| switch (e) {
        error.Reported => return .{ .exit = 1 },
        else => {
            io.printStderr(gpa, "error: the base image for this program did not bake: {s}\n", .{@errorName(e)});
            return .{ .exit = 1 };
        },
    };
    const built = pipeline.buildOnBase(mem.arena(), baked.src, sema_cmd.hostBinding(gpa), baked.base) catch |e| {
        io.printStderr(gpa, "error: the program does not build over its base image: {s}\n", .{@errorName(e)});
        return .{ .exit = 1 };
    };
    if (sema_run.reportProgramErrors(gpa, mem.arena(), mem.map, baked.src.program, &built) != 0) return .{ .exit = 1 };
    const found = pipeline.mainOf(built.s) catch {
        io.writeStderr("error: out of memory\n");
        return .{ .exit = 1 };
    };
    if (found == null) {
        io.writeStderr("error: no main function found\n");
        return .{ .exit = 1 };
    }
    prog.sema_image = baked.bytes;
    return .{ .ok = prog };
}

pub const VERSION = @import("cli.zig").VERSION;

fn isDirectory(fio: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(fio, path, .{}) catch return false;
    return st.kind == .directory;
}

fn defaultOutput(gpa: Allocator, main_path: []const u8, target: []const u8) Allocator.Error![]const u8 {
    const base = std.fs.path.basename(main_path);
    const stem = base[0 .. base.len - ".kt".len];
    if (std.mem.startsWith(u8, target, "windows")) {
        return std.fmt.allocPrint(gpa, "{s}.exe", .{stem});
    }
    return gpa.dupe(u8, stem);
}

fn detectUiFlavor(selection: *const pack_cache.Selection) bool {
    for (selection.packs.items) |p| {
        const base = std.fs.path.basename(p.path);
        if (std.mem.startsWith(u8, base, "androidx.compose.ui")) return true;
    }
    return false;
}

fn encodeProgramSources(arena: Allocator, paths: []const []const u8, texts: [][]const u8) ![]const u8 {
    const files = try arena.alloc(bf.ProgramFile, paths.len);
    for (paths, texts, 0..) |p, t, i| {
        files[i] = .{ .path = p, .bytes = t };
    }
    const src = bf.ProgramSources{ .files = files };
    var perr: pack.PackError = undefined;
    var out = (try pack.write.encode(bf.ProgramSources, arena, &src, &perr)) orelse return error.EncodeFailed;
    return try out.toOwnedSlice(arena);
}

fn collectInclude(
    arena: Allocator,
    fio: std.Io,
    inc: Include,
    main_path: []const u8,
    blob: *std.ArrayList(u8),
    entries: *std.ArrayList(bf.ResourceEntry),
) bool {
    const cwd = std.Io.Dir.cwd();
    const mount_root = if (inc.mount.len != 0) inc.mount else defaultMount(inc.path, main_path);
    if (isDirectory(fio, inc.path)) {
        var dir = cwd.openDir(fio, inc.path, .{ .iterate = true }) catch return false;
        defer dir.close(fio);
        var walker = dir.walk(arena) catch return false;
        defer walker.deinit();
        var rels: std.ArrayList([]const u8) = .empty;
        while (walker.next(fio) catch return false) |entry| {
            if (entry.kind != .file) continue;
            rels.append(arena, arena.dupe(u8, entry.path) catch return false) catch return false;
        }
        // Sort for deterministic output (readdir order is not stable).
        std.mem.sort([]const u8, rels.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (rels.items) |rel| {
            const full = std.fs.path.join(arena, &.{ inc.path, rel }) catch return false;
            const mount = std.fmt.allocPrint(arena, "{s}/{s}", .{ mount_root, rel }) catch return false;
            if (!appendResource(arena, fio, full, mount, blob, entries)) return false;
        }
        return true;
    }
    return appendResource(arena, fio, inc.path, mount_root, blob, entries);
}

fn defaultMount(path: []const u8, main_path: []const u8) []const u8 {
    const dir = std.fs.path.dirname(main_path) orelse "";
    if (dir.len != 0 and std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/') {
        return path[dir.len + 1 ..];
    }
    return std.fs.path.basename(path);
}

fn appendResource(
    arena: Allocator,
    fio: std.Io,
    path: []const u8,
    mount: []const u8,
    blob: *std.ArrayList(u8),
    entries: *std.ArrayList(bf.ResourceEntry),
) bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(fio, path, arena, .unlimited) catch return false;
    const offset: u64 = blob.items.len;
    const compressed = pack.zstd.compress(arena, bytes, pack.DEFAULT_ZSTD_LEVEL) catch return false;
    // Store whichever is smaller; tiny/incompressible files stay raw.
    if (compressed.len < bytes.len) {
        blob.appendSlice(arena, compressed) catch return false;
        entries.append(arena, .{
            .mount = mount,
            .offset = offset,
            .stored_len = compressed.len,
            .uncompressed_len = bytes.len,
            .compression = .zstd,
        }) catch return false;
    } else {
        blob.appendSlice(arena, bytes) catch return false;
        entries.append(arena, .{
            .mount = mount,
            .offset = offset,
            .stored_len = bytes.len,
            .uncompressed_len = bytes.len,
            .compression = .none,
        }) catch return false;
    }
    return true;
}

/// Locate the Skia shim to embed for `target`. Same-target: `KLIO_SKIA_LIB`,
/// then `../lib/` beside the running executable. Cross-target: the stub cache.
fn findShimBytes(arena: Allocator, fio: std.Io, target: []const u8) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    if (std.mem.eql(u8, target, hostTarget())) {
        if (runtime.envOnce("KLIO_SKIA_LIB")) |p| {
            if (cwd.readFileAlloc(fio, p, arena, .unlimited) catch null) |b| return b;
        }
        if (selfExePath(arena)) |exe| {
            if (std.fs.path.dirname(exe)) |bin_dir| {
                const lib = std.fs.path.join(arena, &.{ bin_dir, "..", "lib", shimFileName(target) }) catch return null;
                if (cwd.readFileAlloc(fio, lib, arena, .unlimited) catch null) |b| return b;
            }
        }
        return null;
    }
    return @import("stub_fetch.zig").resolveShim(arena, target, VERSION);
}

pub fn shimFileName(target: []const u8) []const u8 {
    if (std.mem.startsWith(u8, target, "macos")) return "libklio_skia.dylib";
    if (std.mem.startsWith(u8, target, "windows")) return "klio_skia.dll";
    return "libklio_skia.so";
}

/// Whether the program calls one of Compose's window entry points
/// (`application`, `awaitApplication`, `singleWindowApplication`).
fn programOpensWindow(texts: []const []const u8) bool {
    const entries = [_][]const u8{ "application", "awaitApplication", "singleWindowApplication" };
    for (texts) |t| {
        for (entries) |name| {
            if (callsName(t, name)) return true;
        }
    }
    return false;
}

/// Whether `text` has `name` as a whole identifier followed by `(` or `{`.
fn callsName(text: []const u8, name: []const u8) bool {
    var from: usize = 0;
    while (std.mem.findPos(u8, text, from, name)) |at| {
        from = at + name.len;
        if (at > 0 and isIdentChar(text[at - 1])) continue;
        var i = from;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i < text.len and (text[i] == '(' or text[i] == '{')) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const ShimWindowSupport = enum { ok, stub, unknown };

/// The shim's baked windowing-backend marker, emitted by `skia_shim.cpp`.
fn skiaWindowSupport(shim: []const u8) ShimWindowSupport {
    const marker = "klio-win-backend:";
    const idx = std.mem.find(u8, shim, marker) orelse return .unknown;
    const start = idx + marker.len;
    var end = start;
    while (end < shim.len and isTagChar(shim[end])) : (end += 1) {}
    const kind = shim[start..end];
    if (std.mem.eql(u8, kind, "stub")) return .stub;
    return .ok;
}

fn isTagChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
}

fn rebuildHint(target: []const u8) []const u8 {
    if (std.mem.startsWith(u8, target, "macos")) {
        return "rebuild the backend with `zig build skia-lib -Dskia -Dcocoa -Dgpu`, or use a UI-enabled klio build.";
    }
    if (std.mem.startsWith(u8, target, "windows")) {
        return "rebuild the backend with a Win32 windowing build of the Skia shim, or use a UI-enabled klio build.";
    }
    return "rebuild the backend with `zig build skia-lib -Dskia` after installing libsdl2-dev (or `scripts/fetch-sdl.sh` + `-Dsdl-static`), or use a UI-enabled klio build.";
}

const ManifestInputs = struct {
    flavor: bf.Flavor,
    name: []const u8,
    selection: *const pack_cache.Selection,
    resources: []const bf.ResourceEntry,
};

fn buildManifest(arena: Allocator, in: ManifestInputs) !bf.BundleManifest {
    // Sorted by id: the fixpoint order follows directory enumeration.
    var packs: std.ArrayList(bf.PackInfo) = .empty;
    for (in.selection.packs.items) |sp| {
        var id: []const u8 = std.fs.path.basename(sp.path);
        if (std.mem.endsWith(u8, id, ".klio-pack")) id = id[0 .. id.len - ".klio-pack".len];
        var version: []const u8 = "";
        switch (pack_cache.readPackManifest(arena, sp.path)) {
            .ok => |m| {
                id = m.library_id;
                version = m.library_version;
            },
            .err => |e| arena.free(e),
        }
        const feats = try arena.alloc([]const u8, sp.features.len);
        for (sp.features, 0..) |f, i| feats[i] = f;
        try packs.append(arena, .{ .id = id, .version = version, .features = feats });
    }
    std.mem.sort(bf.PackInfo, packs.items, {}, struct {
        fn lt(_: void, x: bf.PackInfo, y: bf.PackInfo) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.lt);

    const known = try stdlib.knownPackagesSnapshot(arena);

    // Natives bind through the binary's own table at boot: there are no
    // pack bindings to replay, and the program builds from its sources.
    return .{
        .klio_version = VERSION,
        .image_format_version = sema_image.bundle_payload_version,
        .flavor = in.flavor,
        .name = in.name,
        .entry = "",
        .program_src_fallback = false,
        .packs = packs.items,
        .known_packages = known,
        .binding_fqns = &.{},
        .pack_bindings = &.{},
        .resources = in.resources,
    };
}

pub fn selfExePath(arena: Allocator) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = runtime.platform.selfExePath(&buf) orelse return null;
    return arena.dupe(u8, path) catch null;
}

fn markExecutable(path: []const u8) void {
    if (builtin.os.tag == .windows) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    _ = std.c.chmod(path_z, 0o755);
}

fn printDryRun(
    gpa: Allocator,
    manifest: *const bf.BundleManifest,
    w: *const bf.Writer,
    stub_len: usize,
    tail_len: usize,
    out_path: []const u8,
) void {
    io.printStdout(gpa, "bundle (dry run): {s}\n", .{out_path});
    io.printStdout(gpa, "flavor: {s}\n", .{@tagName(manifest.flavor)});
    io.printStdout(gpa, "entry: {s}{s}\n", .{
        if (manifest.entry.len != 0) manifest.entry else "program-src",
        if (manifest.program_src_fallback) @as([]const u8, " (program-image refused)") else "",
    });
    io.printStdout(gpa, "packs:\n", .{});
    for (manifest.packs) |p| {
        io.printStdout(gpa, "  {s} {s}\n", .{ p.id, p.version });
    }
    io.printStdout(gpa, "sections:\n", .{});
    for (w.sections.items) |s| {
        io.printStdout(gpa, "  {s} {d} bytes\n", .{ s.name, s.payload.len });
    }
    io.printStdout(gpa, "projected size: {d:.1} MB (stub {d:.1} MB + payload {d:.1} MB)\n", .{
        @as(f64, @floatFromInt(stub_len + tail_len)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(stub_len)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(tail_len)) / (1024.0 * 1024.0),
    });
}

fn emitDesktopFiles(
    gpa: Allocator,
    fio: std.Io,
    dir: []const u8,
    name: []const u8,
    out_path: []const u8,
    icon: ?[]const u8,
) void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(fio, dir) catch return;
    const desktop_path = std.fmt.allocPrint(gpa, "{s}/{s}.desktop", .{ dir, name }) catch return;
    defer gpa.free(desktop_path);
    const exec_abs = cwd.realPathFileAlloc(fio, out_path, gpa) catch null;
    defer if (exec_abs) |e| gpa.free(e);
    const icon_line = if (icon != null)
        std.fmt.allocPrint(gpa, "Icon={s}/{s}.png\n", .{ dir, name }) catch return
    else
        gpa.dupe(u8, "") catch return;
    defer gpa.free(icon_line);
    const contents = std.fmt.allocPrint(gpa,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\Exec={s}
        \\Terminal=false
        \\{s}
    , .{ name, exec_abs orelse out_path, icon_line }) catch return;
    defer gpa.free(contents);
    cwd.writeFile(fio, .{ .sub_path = desktop_path, .data = contents }) catch return;
    if (icon) |png| {
        const icon_path = std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ dir, name }) catch return;
        defer gpa.free(icon_path);
        cwd.writeFile(fio, .{ .sub_path = icon_path, .data = png }) catch {};
    }
}

/// Emit `<dir>/<name>.app/Contents/` around the finished bundle. The inner
/// binary's payload survives a re-sign of the .app with a real identity.
fn emitAppBundle(
    gpa: Allocator,
    fio: std.Io,
    dir: []const u8,
    name: []const u8,
    out_path: []const u8,
    icon: ?[]const u8,
) void {
    const cwd = std.Io.Dir.cwd();
    const contents = std.fmt.allocPrint(gpa, "{s}/{s}.app/Contents", .{ dir, name }) catch return;
    defer gpa.free(contents);
    const macos_dir = std.fmt.allocPrint(gpa, "{s}/MacOS", .{contents}) catch return;
    defer gpa.free(macos_dir);
    cwd.createDirPath(fio, macos_dir) catch return;

    const exe_bytes = cwd.readFileAlloc(fio, out_path, gpa, .unlimited) catch return;
    defer gpa.free(exe_bytes);
    const inner = std.fmt.allocPrint(gpa, "{s}/{s}", .{ macos_dir, name }) catch return;
    defer gpa.free(inner);
    cwd.writeFile(fio, .{ .sub_path = inner, .data = exe_bytes }) catch return;
    markExecutable(inner);

    var icon_key: []const u8 = "";
    if (icon) |png| {
        const res_dir = std.fmt.allocPrint(gpa, "{s}/Resources", .{contents}) catch return;
        defer gpa.free(res_dir);
        cwd.createDirPath(fio, res_dir) catch {};
        if (buildIcns(gpa, png)) |icns| {
            defer gpa.free(icns);
            const icns_path = std.fmt.allocPrint(gpa, "{s}/icon.icns", .{res_dir}) catch return;
            defer gpa.free(icns_path);
            cwd.writeFile(fio, .{ .sub_path = icns_path, .data = icns }) catch {};
            icon_key = "\n    <key>CFBundleIconFile</key><string>icon</string>";
        }
    }

    const plist = std.fmt.allocPrint(gpa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleExecutable</key><string>{s}</string>
        \\    <key>CFBundleIdentifier</key><string>klio.app.{s}</string>
        \\    <key>CFBundleName</key><string>{s}</string>
        \\    <key>CFBundlePackageType</key><string>APPL</string>
        \\    <key>CFBundleShortVersionString</key><string>1.0</string>
        \\    <key>CFBundleVersion</key><string>1</string>
        \\    <key>NSHighResolutionCapable</key><true/>{s}
        \\</dict>
        \\</plist>
        \\
    , .{ name, name, name, icon_key }) catch return;
    defer gpa.free(plist);
    const plist_path = std.fmt.allocPrint(gpa, "{s}/Info.plist", .{contents}) catch return;
    defer gpa.free(plist_path);
    cwd.writeFile(fio, .{ .sub_path = plist_path, .data = plist }) catch return;
}

/// Wrap a square PNG in a single-entry `.icns`, typed by its pixel width.
fn buildIcns(gpa: Allocator, png: []const u8) ?[]u8 {
    const kind = icnsTypeForWidth(pngWidth(png) orelse 256);
    const entry_len: u32 = 8 + @as(u32, @intCast(png.len));
    const total_len: u32 = 8 + entry_len;
    const out = gpa.alloc(u8, total_len) catch return null;
    @memcpy(out[0..4], "icns");
    std.mem.writeInt(u32, out[4..8], total_len, .big);
    @memcpy(out[8..12], kind);
    std.mem.writeInt(u32, out[12..16], entry_len, .big);
    @memcpy(out[16..], png);
    return out;
}

fn icnsTypeForWidth(w: u32) *const [4]u8 {
    return switch (w) {
        16 => "icp4",
        32 => "icp5",
        64 => "icp6",
        128 => "ic07",
        512 => "ic09",
        1024 => "ic10",
        else => "ic08", // 256 and anything non-standard
    };
}

fn pngWidth(png: []const u8) ?u32 {
    if (png.len < 24) return null;
    if (!std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return null;
    if (!std.mem.eql(u8, png[12..16], "IHDR")) return null;
    return std.mem.readInt(u32, png[16..20], .big);
}

test {
    std.testing.refAllDecls(@This());
}

test "parseInclude splits path:mount" {
    const both = parseInclude("assets/data.json:cfg/data.json");
    try std.testing.expectEqualStrings("assets/data.json", both.path);
    try std.testing.expectEqualStrings("cfg/data.json", both.mount);
    const bare = parseInclude("assets/data.json");
    try std.testing.expectEqualStrings("assets/data.json", bare.path);
    try std.testing.expectEqualStrings("", bare.mount);
}

test "defaultMount is main-relative, else basename" {
    try std.testing.expectEqualStrings("assets/a.txt", defaultMount("app/assets/a.txt", "app/main.kt"));
    try std.testing.expectEqualStrings("a.txt", defaultMount("elsewhere/a.txt", "app/main.kt"));
}

test "programOpensWindow finds Compose's window entry points" {
    const windowed = [_][]const u8{"fun main() = application {\n    Window(onCloseRequest = ::exitApplication) {}\n}\n"};
    try std.testing.expect(programOpensWindow(&windowed));
    const single = [_][]const u8{"fun main() = singleWindowApplication (title = \"x\") { }\n"};
    try std.testing.expect(programOpensWindow(&single));
    const awaiting = [_][]const u8{"suspend fun main() = awaitApplication{ }\n"};
    try std.testing.expect(programOpensWindow(&awaiting));
    const offscreen = [_][]const u8{ "// no application here\nval myapplication = 1\n", "fun main() { renderComposeToPng(1, 1, 1f, \"a.png\") {} }\n" };
    try std.testing.expect(!programOpensWindow(&offscreen));
}

test "skiaWindowSupport reads the backend marker" {
    try std.testing.expectEqual(ShimWindowSupport.ok, skiaWindowSupport("....klio-win-backend:cocoa\x00..."));
    try std.testing.expectEqual(ShimWindowSupport.ok, skiaWindowSupport("klio-win-backend:sdl"));
    try std.testing.expectEqual(ShimWindowSupport.ok, skiaWindowSupport("x klio-win-backend:win32 y"));
    try std.testing.expectEqual(ShimWindowSupport.stub, skiaWindowSupport("junk klio-win-backend:stub junk"));
    try std.testing.expectEqual(ShimWindowSupport.unknown, skiaWindowSupport("a plain dylib with no marker"));
}

test "defaultOutput strips .kt and appends .exe on windows" {
    const gpa = std.testing.allocator;
    const plain = try defaultOutput(gpa, "dir/tool.kt", "linux-x64");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("tool", plain);
    const exe = try defaultOutput(gpa, "tool.kt", "windows-x64");
    defer gpa.free(exe);
    try std.testing.expectEqualStrings("tool.exe", exe);
}
