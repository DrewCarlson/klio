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

const pack = @import("pack");
const bf = pack.bundle_format;

const interp_ir = @import("interp_ir");
const image = interp_ir.image;
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const HostBindings = stdlib.HostBindings;

const io = @import("io.zig");
const commands = @import("commands.zig");
const pack_cache = @import("pack_cache.zig");
const RequestedFeatures = pack_cache.RequestedFeatures;
const stdlib_image = @import("stdlib_image.zig");
const project = @import("project.zig");
const macho_sign = @import("macho_sign.zig");
const ir = @import("ir");

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
    app_dir: ?[]const u8 = null,
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
    \\  --app-dir <dir>            Also emit <name>.app around the bundle (macos)
    \\  --dry-run                  Print the resolved pack set, flavor, sections,
    \\                             and projected size without writing
    \\
;

/// `klio bake-image <program> -o <out>`: bake the dependency base (the embedded
/// stdlib plus the packs the program pulls in) to a standalone `.klio-image`
/// file. A mobile app host ships this as a resource and loads it with
/// `run-image`, so the heavy stdlib + pack lowering happens once at build time
/// instead of on device. The program's own code is NOT baked in — it is run
/// against the base by `run-image`, which is what makes a fast reload cycle
/// possible (the base is stable; only the small program is re-pushed).
pub fn bakeImage(gpa: Allocator, paths: []const []const u8, requested: *RequestedFeatures, out_path: []const u8) u8 {
    var scratch_map = SourceMap.init(gpa);
    const user = stdlib_image.parseUserFiles(gpa, &scratch_map, paths, null) orelse {
        return commands.runCheck(gpa, paths, .Plain, requested);
    };
    var report = pack_cache.EmbeddedReport{};
    var selection = pack_cache.Selection{};
    const deps = stdlib_image.bundleDepLoad(gpa, user.asts, requested, &report, &selection) orelse return 1;
    const bb = stdlib_image.bundleBaseImage(gpa, &deps, &report, &selection) orelse {
        io.writeStderr("error: the dependency base for this program cannot bake to an image\n");
        return 1;
    };
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = out_path, .data = bb.bytes }) catch {
        io.printStderr(gpa, "error: cannot write {s}\n", .{out_path});
        return 1;
    };
    io.printStdout(gpa, "wrote {s} ({d} bytes)\n", .{ out_path, bb.bytes.len });
    return 0;
}

/// `klio run-image <base.klio-image> <program.kt> [args...]`: load a pre-baked
/// dependency base from a file and run the program against it. The heavy
/// stdlib + pack lowering is already in the base, so only the small program is
/// parsed and lowered — the fast path a mobile host uses, and the hot-reload
/// primitive (keep the base resident, re-extend a new program source). Mirrors
/// the bundle base-image + program-src boot (see bundle_boot.bootRest).
/// A program assembled against an explicit base-image artifact: the exact
/// module `run-image` executes, exposed so the transpiler can emit against
/// the same fid/const space the runtime will rebuild from the same file.
pub const ImageAssembly = struct {
    built: interp_ir.build.BuiltModule,
    map: *SourceMap,
    binding_fqns: []const []const u8,
};

pub fn assembleImageBuild(gpa: Allocator, base_path: []const u8, paths: []const []const u8) ?ImageAssembly {
    // The image buffer must outlive the base (decoded slices borrow it), so it
    // is read into the process-lifetime allocator and never freed.
    const bytes = blk: {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        break :blk std.Io.Dir.cwd().readFileAlloc(threaded.io(), base_path, gpa, .unlimited) catch {
            io.printStderr(gpa, "error: cannot read base image {s}\n", .{base_path});
            return null;
        };
    };
    const loaded = (image.load(gpa, bytes) catch null) orelse {
        io.printStderr(gpa, "error: base image rejected ({s})\n", .{image.lastLoadFailure()});
        return null;
    };
    for (loaded.known_packages) |pkg| stdlib.registerKnownPackage(pkg);

    const map = gpa.create(SourceMap) catch return null;
    map.* = SourceMap.init(gpa);
    map.files.appendSlice(map.arena.allocator(), loaded.map.files.items) catch return null;
    const user = stdlib_image.parseUserFiles(gpa, map, paths, null) orelse {
        io.writeStderr("error: program fails to parse\n");
        return null;
    };
    if (!interp_ir.build.canExtendBase(loaded.base, user.asts)) {
        io.writeStderr("error: program cannot extend the base image (it redeclares a base name)\n");
        return null;
    }
    if (commands.computeEagerCalls(gpa, user.asts, &.{})) |ec| ir.pending_eager_calls = ec;
    span.active_map = map;
    const built = interp_ir.build.buildModuleFilesExtend(gpa, loaded.base, user.asts) catch return null;
    return .{ .built = built, .map = map, .binding_fqns = loaded.binding_fqns };
}

pub fn runImage(gpa: Allocator, base_path: []const u8, paths: []const []const u8, program_args: []const []const u8) u8 {
    const asm_r = assembleImageBuild(gpa, base_path, paths) orelse return 1;
    var bindings = pack_cache.mergedHostBindings(gpa);
    for (asm_r.binding_fqns) |fqn| {
        if (bindings.resolve(fqn)) |f| bindings.register(fqn, f) catch {};
    }
    return commands.runBuiltModuleArgs(gpa, asm_r.built, bindings, asm_r.map, "error: no main function found", program_args);
}

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

    // Project mode: a directory with klio.toml supplies [application] and
    // the full project source set.
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
    const user = stdlib_image.parseUserFiles(gpa, &scratch_map, paths, null) orelse {
        // Re-run through the check pipeline so the diagnostics render.
        return commands.runCheck(gpa, paths, .Plain, &requested);
    };

    // 2. Dependency load: embedded stdlib + installed packs. Lowering
    //    mutates the parsed ASTs and baking strips dead AST bodies, so
    //    each bake attempt below gets its own load.
    var report = pack_cache.EmbeddedReport{};
    var selection = pack_cache.Selection{};
    const deps = stdlib_image.bundleDepLoad(gpa, user.asts, &requested, &report, &selection) orelse return 1;

    // 3. Whole-program image first (mmap -> load -> run at boot, zero
    //    parsing or lowering). The bake refuses outside the serializable
    //    surface; the bundle then falls back to the always-works
    //    base-image + program-src boot (startup is the only difference),
    //    recorded in the manifest. A successful program bake is also the
    //    program verification: it lowers cleanly with a main.
    var program_image: ?[]const u8 = null;
    var program_src_fallback = false;
    if (programImageEnabled()) {
        program_image = bakeProgramImage(gpa, &deps, paths, user.texts, &report);
        program_src_fallback = program_image == null;
    }

    // 4. The base-image + program-src path (the program-image refusal
    //    fallback, and the diagnostic renderer): fresh dep load, base
    //    bake (or cache reuse), then an extend that surfaces every
    //    resolution diagnostic at bundle time.
    var base_image: ?[]const u8 = null;
    if (program_image == null) {
        const deps2 = stdlib_image.bundleDepLoad(gpa, user.asts, &requested, null, null) orelse return 1;
        const bb = stdlib_image.bundleBaseImage(gpa, &deps2, &report, &selection) orelse {
            io.writeStderr("error: the dependency base for this program cannot bake to an image; bundling requires a bakeable base\n");
            return 1;
        };
        base_image = bb.bytes;
        if (!interp_ir.build.canExtendBase(bb.base, user.asts)) {
            io.writeStderr("error: the program redeclares a name from its dependency base and cannot bundle; rename the declaration\n");
            return 1;
        }
        const map = gpa.create(SourceMap) catch return 1;
        map.* = SourceMap.init(gpa);
        map.files.appendSlice(map.arena.allocator(), bb.map.files.items) catch return 1;
        const user2 = stdlib_image.parseUserFiles(gpa, map, paths, user.texts) orelse return 1;
        span.active_map = map;
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

    // 5. Flavor: forced, or auto-detected off the selected pack set.
    const is_ui = opts.ui orelse detectUiFlavor(&selection);

    // 6. Sections.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program_src = encodeProgramSources(arena, paths, user.texts) catch return 1;

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
        // A windowed Compose UI program (one that calls runApp) needs a real
        // window backend; a shim built without one (the stub) still renders
        // offscreen but its `winOpen` returns null, so the app would open no
        // window and exit silently. Fail fast. Offscreen-only bundles
        // (uiRenderer -> PNG) don't open a window, so they're exempt.
        if (programOpensWindow(user.texts)) {
            switch (skiaWindowSupport(shim_bytes.?)) {
                .ok => {},
                .stub => {
                    io.printStderr(gpa, "error: this Compose UI program opens a window (runApp), but the Skia backend for {s} has no windowing support (it renders offscreen only, so the app would open no window and exit silently).\n  {s}\n", .{ target, rebuildHint(target) });
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
        .entry = if (program_image != null) "main" else "",
        .program_src_fallback = program_src_fallback,
        .report = &report,
        .selection = &selection,
        .bindings = &deps.bindings,
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
    if (base_image) |bi| {
        w.addSection(bf.section_names.BASE_IMAGE, bi, .none, true) catch return 1;
    }
    w.addSection(bf.section_names.PROGRAM_SRC, program_src, .none, false) catch return 1;
    if (program_image) |pi| {
        w.addSection(bf.section_names.PROGRAM_IMAGE, pi, .none, true) catch return 1;
    }
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

    // macOS targets: the payload cannot simply trail the linker's code
    // signature (the arm64 kernel refuses trailing data past it and the
    // binary cannot be re-signed). Strip the stub's own signature, put the
    // overlay in its place, and re-sign ad hoc; the trailer then sits at
    // LC_CODE_SIGNATURE.dataoff - 72. Cross-assembling a macOS bundle from
    // another host works — it is pure byte surgery. An unsigned x86_64 stub
    // keeps the plain overlay append (macho stays null).
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

/// Whether the program opens a window: it references `runApp`, the single
/// windowing entrypoint in `klio.compose.ui` (offscreen `uiRenderer` bundles
/// don't). A source scan is enough — runApp is the only window entry.
fn programOpensWindow(texts: [][]const u8) bool {
    for (texts) |t| {
        if (std.mem.indexOf(u8, t, "runApp") != null) return true;
    }
    return false;
}

const ShimWindowSupport = enum { ok, stub, unknown };

/// Read the shim's baked windowing-backend marker (`skia_shim.cpp`
/// `klio_win_backend_tag`) by a byte scan — works for the host shim and a
/// cross-target one alike. `stub` means the backend cannot open a window;
/// `unknown` means the marker is absent (a shim predating the marker).
fn skiaWindowSupport(shim: []const u8) ShimWindowSupport {
    const marker = "klio-win-backend:";
    const idx = std.mem.indexOf(u8, shim, marker) orelse return .unknown;
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

/// The actionable "rebuild the backend" hint for the target's OS.
fn rebuildHint(target: []const u8) []const u8 {
    if (std.mem.startsWith(u8, target, "macos")) {
        return "rebuild the backend with `zig build skia-lib -Dskia -Dcocoa -Dgpu`, or use a UI-enabled klio build.";
    }
    if (std.mem.startsWith(u8, target, "windows")) {
        return "rebuild the backend with a Win32 windowing build of the Skia shim, or use a UI-enabled klio build.";
    }
    return "rebuild the backend with `zig build skia-lib -Dskia` after installing libsdl2-dev (or `scripts/fetch-sdl.sh` + `-Dsdl-static`), or use a UI-enabled klio build.";
}

/// Whether the whole-program image bake is attempted (default yes;
/// KLIO_BUNDLE_PROGRAM_IMAGE=0 forces the program-src boot, mainly so
/// tests can gate both paths).
fn programImageEnabled() bool {
    const v = runtime.envOnce("KLIO_BUNDLE_PROGRAM_IMAGE") orelse return true;
    return v.len == 0 or !std.mem.eql(u8, v, "0");
}

/// Lower deps + program as one module and bake it (semantically equal to
/// the extend path — the run pipeline treats them as byte-identical).
/// Null on any refusal; the caller records the program-src fallback.
fn bakeProgramImage(
    gpa: Allocator,
    deps: *const stdlib_image.BundleDeps,
    paths: []const []const u8,
    texts: [][]const u8,
    report: *const pack_cache.EmbeddedReport,
) ?[]const u8 {
    // Parse the user files onto the dependency map (their FileIds continue
    // after the deps'), then lower everything as one module.
    const dep_file_count = deps.map.files.items.len;
    const user = stdlib_image.parseUserFiles(gpa, deps.map, paths, texts) orelse return null;
    var all: std.ArrayList(KotlinFile) = .empty;
    defer all.deinit(gpa);
    all.appendSlice(gpa, deps.asts) catch return null;
    all.appendSlice(gpa, user.asts) catch return null;
    span.active_map = deps.map;
    const pb = (interp_ir.build.buildProgramBase(gpa, all.items) catch return null) orelse return null;
    pb.user_file_start = @intCast(dep_file_count);
    return (image.bake(gpa, pb, deps.map, .{
        .known_packages = report.known_packages.items,
        .binding_fqns = report.binding_fqns.items,
    }) catch return null) orelse null;
}

const ManifestInputs = struct {
    flavor: bf.Flavor,
    name: []const u8,
    entry: []const u8,
    program_src_fallback: bool,
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
        .entry = in.entry,
        .program_src_fallback = in.program_src_fallback,
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
/// with PE support.
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

/// Emit `<dir>/<name>.app/Contents/` (`Info.plist`, `MacOS/<name>` copied
/// from the signed bundle, `Resources/icon.icns` from `--icon`) so a macOS
/// bundle double-clicks and shows a name/icon in the Dock. The inner binary
/// is the ad-hoc-signed bundle; a user with a signing identity can re-sign
/// the .app (`codesign --deep -f -s ...`) — the payload survives it.
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

    // The inner binary is the finished bundle itself.
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

/// Wrap a square PNG in a single-entry `.icns`, choosing the icon type from
/// the PNG's pixel width (falling back to the 256×256 slot). macOS reads
/// PNG-encoded icon data directly.
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

test "skiaWindowSupport reads the backend marker" {
    try std.testing.expectEqual(ShimWindowSupport.ok, skiaWindowSupport("....klio-win-backend:cocoa\x00..."));
    try std.testing.expectEqual(ShimWindowSupport.ok, skiaWindowSupport("klio-win-backend:sdl"));
    try std.testing.expectEqual(ShimWindowSupport.ok, skiaWindowSupport("x klio-win-backend:win32 y"));
    try std.testing.expectEqual(ShimWindowSupport.stub, skiaWindowSupport("junk klio-win-backend:stub junk"));
    try std.testing.expectEqual(ShimWindowSupport.unknown, skiaWindowSupport("a plain dylib with no marker"));
}

test "programOpensWindow detects runApp, not offscreen uiRenderer" {
    var windowed = [_][]const u8{"fun main() { runApp(80, 52, 8, \"t\", -1) { } }"};
    try std.testing.expect(programOpensWindow(&windowed));
    var offscreen = [_][]const u8{"fun main() { val ui = uiRenderer(16, 10) { }; ui.savePng(\"x\", 8) }"};
    try std.testing.expect(!programOpensWindow(&offscreen));
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
