//! Bundle boot: detect a payload appended to the running executable and run the
//! embedded program instead of the normal CLI. A plain `klio` binary probes
//! negative and the CLI proceeds untouched. In bundle mode argv[1..] goes to
//! `fun main(args: Array<String>)` verbatim, klio subcommands are unreachable,
//! and the `~/.klio` cache and pack directories are never consulted.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const span = @import("span");
const SourceMap = span.SourceMap;

const pack = @import("pack");
const bf = pack.bundle_format;

const interp_ir = @import("interp_ir");
const image = interp_ir.image;
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const HostBindings = stdlib.HostBindings;
const ir_mod = @import("ir");

const compose_ui = @import("compose_ui");

const io = @import("io.zig");
const commands = @import("commands.zig");
const pack_cache = @import("pack_cache.zig");
const stdlib_image = @import("stdlib_image.zig");
const bundle = @import("bundle.zig");
const shim_extract = @import("shim_extract.zig");
const macho_sign = @import("macho_sign.zig");

const ProbeState = union(enum) {
    unknown,
    not_a_bundle,
    bundle: bf.Trailer,
};
var probe_state: ProbeState = .unknown;
var probe_file_len: u64 = 0;

/// Whether the running executable carries a bundle payload. Probed before argv
/// is interpreted, so an `--opt`-shaped entry still belongs to the program.
pub fn bundleModeActive() bool {
    return probeSelf() != null;
}

fn probeSelf() ?bf.Trailer {
    switch (probe_state) {
        .not_a_bundle => return null,
        .bundle => |t| return t,
        .unknown => {},
    }
    probe_state = .not_a_bundle;
    const t = probeSelfInner() orelse return null;
    probe_state = .{ .bundle = t };
    return t;
}

/// Read the trailer candidate from the platform-specific tail position. ELF and
/// PE append the overlay plainly, so the trailer sits at `EOF - 72`. A signed
/// Mach-O re-signs over the overlay and keeps the signature last, putting the
/// trailer at `LC_CODE_SIGNATURE.dataoff - 72`; an unsigned stub falls back to
/// the EOF probe.
fn probeSelfInner() ?bf.Trailer {
    const path = selfExePathZ() orelse return null;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end <= bf.TRAILER_LEN) return null;
    const file_len: u64 = @intCast(end);

    if (builtin.os.tag == .macos) {
        if (machoTrailerPos(fd)) |pos| {
            if (readTrailerAt(fd, pos, file_len)) |t| {
                probe_file_len = file_len;
                return t;
            }
        }
    }

    const t = readTrailerAt(fd, file_len - bf.TRAILER_LEN, file_len) orelse return null;
    probe_file_len = file_len;
    return t;
}

fn readTrailerAt(fd: c_int, pos: u64, file_len: u64) ?bf.Trailer {
    if (pos + bf.TRAILER_LEN > file_len) return null;
    var tail: [bf.TRAILER_LEN]u8 = undefined;
    const n = std.c.pread(fd, &tail, tail.len, @intCast(pos));
    if (n != tail.len) return null;
    const t = bf.Trailer.decode(&tail) orelse return null;
    if (!t.consistent(file_len)) return null;
    return t;
}

var macho_head_buf: [256 * 1024]u8 = undefined;
fn machoTrailerPos(fd: c_int) ?u64 {
    var hdr: [32]u8 = undefined;
    if (std.c.pread(fd, &hdr, hdr.len, 0) != hdr.len) return null;
    if (std.mem.readInt(u32, hdr[0..4], .little) != 0xfeedfacf) return null;
    const sizeofcmds = std.mem.readInt(u32, hdr[20..24], .little);
    const need: usize = 32 + @as(usize, sizeofcmds);
    if (need > macho_head_buf.len) return null;
    if (std.c.pread(fd, &macho_head_buf, need, 0) != @as(isize, @intCast(need))) return null;
    return macho_sign.trailerOffset(macho_head_buf[0..need]);
}

var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;

/// Resolve the own-executable path into a static buffer, never trusting argv[0].
fn selfExePathZ() ?[*:0]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            const n = std.os.linux.readlink("/proc/self/exe", &self_path_buf, self_path_buf.len - 1);
            if (@as(isize, @bitCast(n)) <= 0) return null;
            self_path_buf[n] = 0;
            return @ptrCast(&self_path_buf);
        },
        .macos => {
            var len: u32 = self_path_buf.len;
            if (std.c._NSGetExecutablePath(&self_path_buf, &len) != 0) return null;
            return @ptrCast(&self_path_buf);
        },
        else => return null,
    }
}

/// mmap the whole bundle file read-only. The mapping lives for the process: the
/// loaded base and every borrowed string point into it.
fn mmapSelf(len: u64) ?[]const u8 {
    const path = selfExePathZ() orelse return null;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const mapped = std.posix.mmap(
        null,
        @intCast(len),
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return null;
    return mapped[0..@intCast(len)];
}

pub fn run(gpa: Allocator, argv: []const []const u8) u8 {
    const trailer = probeSelf() orelse {
        io.writeStderr("error: bundle probe failed after activation\n");
        return 1;
    };

    const bytes = mmapSelf(probe_file_len) orelse {
        io.writeStderr("error: cannot map the bundle payload\n");
        return 1;
    };

    if (!bf.verifyPayload(bytes, &trailer)) {
        io.writeStderr("error: bundle payload hash mismatch (file truncated or modified); rebundle\n");
        return 1;
    }

    const table = bf.decodeTable(gpa, bytes, &trailer) orelse {
        io.writeStderr("error: bundle section table is malformed; rebundle\n");
        return 1;
    };

    const manifest_section = bf.findSection(&table, bf.section_names.MANIFEST) orelse {
        io.writeStderr("error: bundle carries no manifest; rebundle\n");
        return 1;
    };
    const manifest_bytes = (bf.sectionBytes(gpa, bytes, manifest_section) catch return 1) orelse return 1;
    var perr: pack.PackError = undefined;
    const manifest = (pack.read.decode(bf.BundleManifest, gpa, manifest_bytes.slice(), &perr) catch return 1) orelse {
        io.writeStderr("error: bundle manifest is malformed; rebundle\n");
        return 1;
    };

    if (!std.mem.eql(u8, manifest.klio_version, bundle.VERSION)) {
        io.printStderr(gpa, "error: this bundle was produced by klio {s} but the runtime is {s}; rebundle with a matching klio\n", .{
            manifest.klio_version, bundle.VERSION,
        });
        return 1;
    }
    if (manifest.image_format_version != image.FORMAT_VERSION) {
        io.printStderr(gpa, "error: this bundle was produced by klio {s} but the runtime is {s}; rebundle with a matching klio\n", .{
            manifest.klio_version, bundle.VERSION,
        });
        return 1;
    }

    if (runtime.envOnce("KLIO_BUNDLE_INSPECT")) |v| {
        if (v.len != 0 and !std.mem.eql(u8, v, "0")) {
            printInspect(gpa, &manifest, &table);
            return 0;
        }
    }

    return bootProgram(gpa, bytes, &table, &manifest, argv);
}

fn bootProgram(
    gpa: Allocator,
    bytes: []const u8,
    table: *const bf.SectionTable,
    manifest: *const bf.BundleManifest,
    argv: []const []const u8,
) u8 {
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();
    interp_ir.resetReceiverThreadLocals();
    interp_ir.resetRunGlobalCaches();

    installResources(gpa, bytes, table, manifest);

    if (manifest.flavor == .ui) {
        if (bf.findSection(table, bf.section_names.SKIA_SHIM)) |shim_section| {
            const shim = (bf.sectionBytes(gpa, bytes, shim_section) catch null) orelse {
                io.writeStderr("warning: embedded rendering backend is corrupt; running headless\n");
                return bootRest(gpa, bytes, table, manifest, argv);
            };
            if (shim_extract.ensureExtracted(gpa, shim.slice())) |path| {
                compose_ui.setSkiaLibPath(path);
            } else {
                io.writeStderr("warning: cannot extract the rendering backend (cache and temp dirs unwritable); running headless\n");
            }
        }
    }
    if (bf.findSection(table, bf.section_names.ICON)) |icon_section| {
        compose_ui.setWindowIconPng(bf.sectionStored(bytes, icon_section));
    }
    if (manifest.name.len != 0) {
        if (std.fmt.allocPrintSentinel(gpa, "{s}", .{manifest.name}, 0) catch null) |title| {
            compose_ui.setDefaultWindowTitle(title);
        }
    }

    return bootRest(gpa, bytes, table, manifest, argv);
}

fn bootRest(
    gpa: Allocator,
    bytes: []const u8,
    table: *const bf.SectionTable,
    manifest: *const bf.BundleManifest,
    argv: []const []const u8,
) u8 {
    for (manifest.known_packages) |pkg| stdlib.registerKnownPackage(pkg);

    if (manifest.entry.len != 0) {
        if (bf.findSection(table, bf.section_names.PROGRAM_IMAGE)) |pi_section| {
            const pi_bytes = bf.sectionStored(bytes, pi_section);
            const loaded = (image.load(gpa, pi_bytes) catch null) orelse {
                io.printStderr(gpa, "error: bundle program image rejected ({s}); rebundle\n", .{image.lastLoadFailure()});
                return 1;
            };
            for (loaded.known_packages) |pkg| stdlib.registerKnownPackage(pkg);
            const bindings = replayBindings(gpa, loaded.binding_fqns, manifest) orelse return 1;
            return commands.runBuiltModuleArgs(gpa, loaded.base.built, bindings, loaded.map, "error: no main function found", argv[1..]);
        }
        io.writeStderr("error: bundle names an entry but carries no program image; rebundle\n");
        return 1;
    }

    const image_section = bf.findSection(table, bf.section_names.BASE_IMAGE) orelse {
        io.writeStderr("error: bundle carries no base image; rebundle\n");
        return 1;
    };
    const image_bytes = bf.sectionStored(bytes, image_section);
    const loaded = (image.load(gpa, image_bytes) catch null) orelse {
        io.printStderr(gpa, "error: bundle base image rejected ({s}); rebundle\n", .{image.lastLoadFailure()});
        return 1;
    };
    for (loaded.known_packages) |pkg| stdlib.registerKnownPackage(pkg);

    const src_section = bf.findSection(table, bf.section_names.PROGRAM_SRC) orelse {
        io.writeStderr("error: bundle carries no program sources; rebundle\n");
        return 1;
    };
    const src_bytes = (bf.sectionBytes(gpa, bytes, src_section) catch return 1) orelse return 1;
    var perr: pack.PackError = undefined;
    const sources = (pack.read.decode(bf.ProgramSources, gpa, src_bytes.slice(), &perr) catch return 1) orelse {
        io.writeStderr("error: bundle program sources are malformed; rebundle\n");
        return 1;
    };

    const paths = gpa.alloc([]const u8, sources.files.len) catch return 1;
    const texts = gpa.alloc([]const u8, sources.files.len) catch return 1;
    for (sources.files, 0..) |f, i| {
        paths[i] = f.path;
        texts[i] = f.bytes;
    }

    const map = gpa.create(SourceMap) catch return 1;
    map.* = SourceMap.init(gpa);
    map.files.appendSlice(map.arena.allocator(), loaded.map.files.items) catch return 1;
    const user = stdlib_image.parseUserFiles(gpa, map, paths, texts) orelse {
        io.writeStderr("error: embedded program sources fail to parse; rebundle\n");
        return 1;
    };

    if (!interp_ir.build.canExtendBase(loaded.base, user.asts)) {
        io.writeStderr("error: embedded program cannot extend the bundle base; rebundle\n");
        return 1;
    }
    if (commands.computeEagerCalls(gpa, user.asts, &.{})) |ec| ir_mod.pending_eager_calls = ec;
    span.active_map = map;
    const built = interp_ir.build.buildModuleFilesExtend(gpa, loaded.base, user.asts) catch return 1;

    const bindings = replayBindings(gpa, loaded.binding_fqns, manifest) orelse return 1;
    return commands.runBuiltModuleArgs(gpa, built, bindings, map, "error: no main function found", argv[1..]);
}

fn replayBindings(
    gpa: Allocator,
    binding_fqns: []const []const u8,
    manifest: *const bf.BundleManifest,
) ?HostBindings {
    var bindings = pack_cache.mergedHostBindings(gpa);
    for (binding_fqns) |fqn| {
        if (bindings.resolve(fqn)) |f| bindings.register(fqn, f) catch {};
    }
    for (manifest.pack_bindings) |pb| {
        const f = bindings.resolve(pb.host_symbol) orelse {
            io.printStderr(gpa, "error: bundle host binding `{s}` does not resolve in this runtime; rebundle with a matching klio\n", .{pb.host_symbol});
            return null;
        };
        bindings.register(gpa.dupe(u8, pb.fqn) catch return null, f) catch {};
    }
    return bindings;
}

/// The mmap-backed resource table served to `klio.bundle.Resources`.
fn installResources(
    gpa: Allocator,
    bytes: []const u8,
    table: *const bf.SectionTable,
    manifest: *const bf.BundleManifest,
) void {
    const entries = gpa.alloc(stdlib.bundle_resources.Entry, manifest.resources.len) catch return;
    if (manifest.resources.len != 0) {
        const section = bf.findSection(table, bf.section_names.RESOURCES) orelse return;
        const stored = bf.sectionStored(bytes, section);
        for (manifest.resources, 0..) |r, i| {
            const start: usize = @intCast(r.offset);
            const end: usize = start + @as(usize, @intCast(r.stored_len));
            if (end > stored.len) return;
            entries[i] = .{
                .mount = r.mount,
                .stored = stored[start..end],
                .uncompressed_len = @intCast(r.uncompressed_len),
                .compressed = r.compression == .zstd,
            };
        }
    }
    stdlib.bundle_resources.installEntries(entries);
}

fn printInspect(gpa: Allocator, manifest: *const bf.BundleManifest, table: *const bf.SectionTable) void {
    io.printStdout(gpa, "bundle: {s}\n", .{manifest.name});
    io.printStdout(gpa, "klio: {s} (image format {d})\n", .{ manifest.klio_version, manifest.image_format_version });
    io.printStdout(gpa, "flavor: {s}\n", .{@tagName(manifest.flavor)});
    io.printStdout(gpa, "entry: {s}{s}\n", .{
        if (manifest.entry.len != 0) manifest.entry else "program-src",
        if (manifest.program_src_fallback) @as([]const u8, " (program-image refused)") else "",
    });
    io.printStdout(gpa, "packs:\n", .{});
    for (manifest.packs) |p| {
        io.printStdout(gpa, "  {s} {s}", .{ p.id, p.version });
        for (p.features) |f| io.printStdout(gpa, " +{s}", .{f});
        io.printStdout(gpa, "\n", .{});
    }
    io.printStdout(gpa, "sections:\n", .{});
    for (table.entries) |s| {
        io.printStdout(gpa, "  {s} {d} bytes ({d} uncompressed)\n", .{ s.name, s.stored_len, s.uncompressed_len });
    }
    if (manifest.resources.len != 0) {
        io.printStdout(gpa, "resources:\n", .{});
        for (manifest.resources) |r| {
            io.printStdout(gpa, "  {s} {d} bytes\n", .{ r.mount, r.uncompressed_len });
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
