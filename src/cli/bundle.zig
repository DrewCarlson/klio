//! `klio bundle` — turn a Kotlin program plus everything it needs (baked
//! dependency image, embedded resources, and for Compose programs the
//! Skia rendering backend) into one self-contained executable.
//!
//! Bundling is file surgery: copy the running `klio` binary (the stub),
//! append an aligned payload area (`pack.bundle_format`), and write the
//! trailer. No compiler or linker runs. The full assemble-and-lower
//! pipeline executes at bundle time so every resolution diagnostic
//! surfaces here, not on the user's machine.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const ast = @import("ast");
const KotlinFile = ast.KotlinFile;
const span = @import("span");
const SourceMap = span.SourceMap;
const diagnostics = @import("diagnostics");

const pack = @import("pack");
const bf = pack.bundle_format;

const interp_ir = @import("interp_ir");
const image = interp_ir.image;
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const HostBindings = stdlib.HostBindings;
const ir_mod = @import("ir");

const io = @import("io.zig");
const commands = @import("commands.zig");
const pack_cache = @import("pack_cache.zig");
const RequestedFeatures = pack_cache.RequestedFeatures;
const stdlib_image = @import("stdlib_image.zig");
const project = @import("project.zig");

/// Parsed `klio bundle` command line.
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
    feature_specs: std.ArrayList([]const u8) = .empty,
};

pub const Include = struct {
    path: []const u8,
    /// Mount path inside the bundle's resource table.
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
    \\  --dry-run                  Print the resolved pack set, flavor, sections,
    \\                             and projected size without writing
    \\
;

pub fn runBundle(gpa: Allocator, args: []const []const u8) u8 {
    var opts = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (flagValue(gpa, args, &i, "-o", "--output")) |v| {
            opts.output = v orelse return usageErr(gpa, "--output requires a path");
        } else if (flagValue(gpa, args, &i, null, "--target")) |v| {
            opts.target = v orelse return usageErr(gpa, "--target requires a target name");
        } else if (std.mem.eql(u8, a, "--ui")) {
            opts.ui = true;
        } else if (std.mem.eql(u8, a, "--headless")) {
            opts.ui = false;
        } else if (flagValue(gpa, args, &i, null, "--include")) |v| {
            const val = v orelse return usageErr(gpa, "--include requires a path[:mount]");
            const inc = parseInclude(val);
            opts.includes.append(gpa, inc) catch return 2;
        } else if (flagValue(gpa, args, &i, null, "--name")) |v| {
            opts.name = v orelse return usageErr(gpa, "--name requires a value");
        } else if (flagValue(gpa, args, &i, null, "--icon")) |v| {
            opts.icon = v orelse return usageErr(gpa, "--icon requires a png path");
        } else if (flagValue(gpa, args, &i, null, "--stub")) |v| {
            opts.stub = v orelse return usageErr(gpa, "--stub requires a path");
        } else if (flagValue(gpa, args, &i, null, "--desktop-dir")) |v| {
            opts.desktop_dir = v orelse return usageErr(gpa, "--desktop-dir requires a directory");
        } else if (flagValue(gpa, args, &i, null, "--feature")) |v| {
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
    gpa: Allocator,
    args: []const []const u8,
    i: *usize,
    short: ?[]const u8,
    long: []const u8,
) ??[]const u8 {
    _ = gpa;
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
    if (std.mem.lastIndexOfScalar(u8, val, ':')) |colon| {
        return .{ .path = val[0..colon], .mount = val[colon + 1 ..] };
    }
    return .{ .path = val, .mount = "" };
}

fn usageErr(gpa: Allocator, msg: []const u8) u8 {
    io.printStderr(gpa, "error: {s}\n\n{s}", .{ msg, USAGE });
    return 2;
}

// ---------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------

const target_names = [_][]const u8{
    "linux-x64", "linux-arm64", "macos-x64", "macos-arm64", "windows-x64", "windows-arm64",
};

pub fn hostTarget() []const u8 {
    const os: []const u8 = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => "unknown",
    };
    const arch: []const u8 = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => "unknown",
    };
    return switch (builtin.os.tag) {
        .linux => if (builtin.cpu.arch == .x86_64) "linux-x64" else "linux-arm64",
        .macos => if (builtin.cpu.arch == .x86_64) "macos-x64" else "macos-arm64",
        .windows => if (builtin.cpu.arch == .x86_64) "windows-x64" else "windows-arm64",
        else => {
            _ = os;
            _ = arch;
            return "unknown";
        },
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

    // Project mode: a directory with klio.toml supplies [application].
    var proj: ?project.Application = null;
    var main_path: []const u8 = opts.input;
    if (isDirectory(fio, opts.input)) {
        proj = project.loadApplication(gpa, opts.input) orelse {
            io.printStderr(gpa, "error: `{s}` is a directory but has no klio.toml with an [application] table (or a single main .kt)\n", .{opts.input});
            return 2;
        };
        main_path = proj.?.main;
        if (opts.name == null and proj.?.name.len != 0) opts.name = proj.?.name;
        if (opts.icon == null and proj.?.icon.len != 0) opts.icon = proj.?.icon;
        for (proj.?.includes) |inc| {
            opts.includes.append(gpa, parseInclude(inc)) catch return 2;
        }
    }
    if (!std.mem.endsWith(u8, main_path, ".kt")) {
        io.printStderr(gpa, "error: expected a `.kt` source file, got `{s}`\n", .{main_path});
        return 2;
    }

    const out_path = opts.output orelse defaultOutput(gpa, main_path, target) catch return 2;
    const app_name = opts.name orelse std.fs.path.basename(out_path);

    var requested = RequestedFeatures.init(gpa);
    for (opts.feature_specs.items) |spec| {
        const slash = std.mem.indexOfScalar(u8, spec, '/') orelse {
            io.printStderr(gpa, "error: --feature `{s}` must be `<pack>/<feature>`\n", .{spec});
            return 2;
        };
        const gop = requested.getOrPut(spec[0..slash]) catch return 2;
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(gpa);
        gop.value_ptr.put(spec[slash + 1 ..], {}) catch return 2;
    }

    // 1. Parse the program.
    var scratch_map = SourceMap.init(gpa);
    const paths = [_][]const u8{main_path};
    const user = stdlib_image.parseUserFiles(gpa, &scratch_map, &paths, null) orelse {
        // Re-run through the check pipeline so the diagnostics render.
        return commands.runCheck(gpa, &paths, .Plain, &requested);
    };

    // 2. Dependency load + base image (cache reuse or fresh bake).
    var report = pack_cache.EmbeddedReport{};
    var selection = pack_cache.Selection{};
    const bb = stdlib_image.bundleBaseImage(gpa, user.asts, &requested, &report, &selection) orelse {
        io.writeStderr("error: the dependency base for this program cannot bake to an image; bundling requires a bakeable base\n");
        return 1;
    };

    // 3. Verify the program lowers cleanly against the base (all
    //    resolution diagnostics surface at bundle time).
    {
        if (!interp_ir.build.canExtendBase(bb.base, user.asts)) {
            io.writeStderr("error: the program redeclares a name from its dependency base and cannot bundle; rename the declaration\n");
            return 1;
        }
        const map = gpa.create(SourceMap) catch return 1;
        map.* = SourceMap.init(gpa);
        map.files.appendSlice(map.arena.allocator(), bb.map.files.items) catch return 1;
        const user2 = stdlib_image.parseUserFiles(gpa, map, &paths, user.texts) orelse return 1;
        var built = interp_ir.build.buildModuleFilesExtend(gpa, bb.base, user2.asts) catch return 1;
        const mg = built.module.borrow();
        defer mg.deinit();
        const rdiags = mg.get().resolve_diags.items;
        if (rdiags.len != 0) {
            for (rdiags) |d| {
                const msg = d.render(gpa, map) catch return 1;
                io.printStderr(gpa, "{s}\n", .{msg});
            }
            return 1;
        }
        if (built.main == null) {
            io.writeStderr("error: no main function found\n");
            return 1;
        }
    }

    // 4. Flavor: forced, or auto-detected off the selected pack set.
    const is_ui = opts.ui orelse detectUiFlavor(&selection);

    // 5. Sections.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program_src = encodeProgramSources(arena, &paths, user.texts) catch return 1;

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
        .report = &report,
        .selection = &selection,
        .bindings = &bb.bindings,
        .resources = resource_entries.items,
    }) catch return 1;
    var perr: pack.PackError = undefined;
    const manifest_bytes = (pack.write.encode(bf.BundleManifest, arena, &manifest, &perr) catch return 1) orelse return 1;

    // 6. Stub.
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

    // 7. Assemble.
    var w = bf.Writer.init(gpa);
    defer w.deinit();
    w.addSection(bf.section_names.MANIFEST, manifest_bytes.items, .none, false) catch return 1;
    w.addSection(bf.section_names.BASE_IMAGE, bb.bytes, .none, true) catch return 1;
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
    const tail = (w.finish(stub_bytes.len, &perr) catch return 1) orelse {
        io.printStderr(gpa, "error: bundle assembly failed: {f}\n", .{perr});
        return 1;
    };
    defer gpa.free(tail);

    if (opts.dry_run) {
        printDryRun(gpa, &manifest, &w, stub_bytes.len, tail.len, out_path);
        return 0;
    }

    {
        var whole: std.ArrayList(u8) = .empty;
        defer whole.deinit(gpa);
        whole.ensureTotalCapacityPrecise(gpa, stub_bytes.len + tail.len) catch return 1;
        whole.appendSliceAssumeCapacity(stub_bytes);
        whole.appendSliceAssumeCapacity(tail);
        cwd.writeFile(fio, .{ .sub_path = out_path, .data = whole.items }) catch {
            io.printStderr(gpa, "error: cannot write `{s}`\n", .{out_path});
            return 1;
        };
    }
    markExecutable(out_path);

    if (opts.desktop_dir) |dir| {
        emitDesktopFiles(gpa, fio, dir, app_name, out_path, icon_bytes);
    }

    const total = stub_bytes.len + tail.len;
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

/// UI flavor when the pack fixpoint selected any androidx.compose.ui*
/// pack (or klio.compose.ui).
fn detectUiFlavor(selection: *const pack_cache.Selection) bool {
    for (selection.packs.items) |p| {
        const base = std.fs.path.basename(p.path);
        if (std.mem.startsWith(u8, base, "androidx.compose.ui") or
            std.mem.startsWith(u8, base, "klio.compose.ui"))
        {
            return true;
        }
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

/// Append one `--include` (file or directory) to the resources blob.
/// The default mount is the path relative to the main source's directory
/// (falling back to the basename when it is not under it).
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

/// Locate the Skia shim blob to embed for `target`. Same-target: the
/// `KLIO_SKIA_LIB` override, then the shim installed next to the running
/// executable (`../lib/`). Cross-target: `KLIO_STUB_DIR` / the stub cache
/// (resolved by stub_fetch alongside the stub).
fn findShimBytes(arena: Allocator, fio: std.Io, target: []const u8) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    if (std.mem.eql(u8, target, hostTarget())) {
        if (runtime.getenvSlice("KLIO_SKIA_LIB")) |p| {
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

const ManifestInputs = struct {
    flavor: bf.Flavor,
    name: []const u8,
    report: *const pack_cache.EmbeddedReport,
    selection: *const pack_cache.Selection,
    bindings: *const HostBindings,
    resources: []const bf.ResourceEntry,
};

fn buildManifest(arena: Allocator, in: ManifestInputs) !bf.BundleManifest {
    // Pack infos, sorted by id for determinism (fixpoint order follows
    // directory enumeration).
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

    const fqns = try arena.alloc([]const u8, in.report.binding_fqns.items.len);
    for (in.report.binding_fqns.items, 0..) |f, i| fqns[i] = f;

    const pairs = try harvestPackBindings(arena, in.bindings);

    return .{
        .klio_version = VERSION,
        .image_format_version = image.FORMAT_VERSION,
        .flavor = in.flavor,
        .name = in.name,
        .entry = "",
        .program_src_fallback = false,
        .packs = packs.items,
        .known_packages = known,
        .binding_fqns = fqns,
        .pack_bindings = pairs,
        .resources = in.resources,
    };
}

/// The host bindings the pack load added beyond the in-binary defaults,
/// as replayable `(fqn, host_symbol)` pairs: for each entry whose FQN
/// does not already resolve to the same host function, find the default
/// registry name carrying that function pointer. Boot re-resolves the
/// symbol and registers it under the FQN.
fn harvestPackBindings(arena: Allocator, bindings: *const HostBindings) ![]bf.BindingPair {
    var merged = pack_cache.mergedHostBindings(arena);
    defer merged.deinit();
    var rev = std.AutoHashMap(usize, []const u8).init(arena);
    defer rev.deinit();
    {
        var it = merged.table.iterator();
        while (it.next()) |e| {
            try rev.put(@intFromPtr(e.value_ptr.*), e.key_ptr.*);
        }
    }
    var out: std.ArrayList(bf.BindingPair) = .empty;
    var it = bindings.table.iterator();
    while (it.next()) |e| {
        if (merged.resolve(e.key_ptr.*)) |f| {
            if (f == e.value_ptr.*) continue;
        }
        const sym = rev.get(@intFromPtr(e.value_ptr.*)) orelse continue;
        try out.append(arena, .{
            .fqn = try arena.dupe(u8, e.key_ptr.*),
            .host_symbol = try arena.dupe(u8, sym),
        });
    }
    std.mem.sort(bf.BindingPair, out.items, {}, struct {
        fn lt(_: void, x: bf.BindingPair, y: bf.BindingPair) bool {
            return std.mem.lessThan(u8, x.fqn, y.fqn);
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

/// The running executable's path. Per-OS: /proc/self/exe on linux,
/// `_NSGetExecutablePath` on macOS. Windows (`GetModuleFileNameW`) lands
/// with the PE milestone.
pub fn selfExePath(arena: Allocator) ?[]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = std.os.linux.readlink("/proc/self/exe", &buf, buf.len);
            if (@as(isize, @bitCast(n)) <= 0) return null;
            return arena.dupe(u8, buf[0..n]) catch null;
        },
        .macos => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            var len: u32 = buf.len;
            if (std.c._NSGetExecutablePath(&buf, &len) != 0) return null;
            const path = std.mem.sliceTo(&buf, 0);
            return arena.dupe(u8, path) catch null;
        },
        else => return null,
    }
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

/// Emit `<name>.desktop` (+ the icon PNG when present) into `dir` for
/// GUI-first Linux distribution.
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

test "defaultOutput strips .kt and appends .exe on windows" {
    const gpa = std.testing.allocator;
    const plain = try defaultOutput(gpa, "dir/tool.kt", "linux-x64");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("tool", plain);
    const exe = try defaultOutput(gpa, "tool.kt", "windows-x64");
    defer gpa.free(exe);
    try std.testing.expectEqualStrings("tool.exe", exe);
}
