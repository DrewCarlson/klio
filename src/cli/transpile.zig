//! `klio transpile`: the program built through sema, the bridge and lowering
//! from sema, then emitted as C. `--native` compiles it (`cgen`); the
//! launcher form boots the interpreter over the program's sema image.

const std = @import("std");
const span = @import("span");
const ir = @import("ir");
const lower_driver = @import("lower_driver");

const io = @import("io.zig");
const sema_cmd = @import("sema_cmd.zig");
const sema_run = @import("sema_run.zig");
const image_cmd = @import("image_cmd.zig");
const cgen = @import("cgen.zig");
const reach_mod = @import("cgen/reach.zig");
const sema = @import("sema");

const Allocator = std.mem.Allocator;
const pipeline = lower_driver.pipeline;

/// A program built for emission: the resolved module and its bridge, with
/// the program's `main`.
pub const Built = struct {
    built: pipeline.Built,
    main: ir.FuncId,
};

/// Builds `paths` as `klio run` does. Null after reporting why the program
/// does not build: an unresolved reference or a body that did not lower in
/// the program's own files, or no `main`.
pub fn buildProgram(gpa: Allocator, arena: Allocator, map: *span.SourceMap, paths: []const []const u8, feature_specs: []const []const u8) ?Built {
    var report: sema_cmd.LoadReport = .{};
    const loaded = sema_cmd.loadSources(arena, map, paths, .{ .feature_specs = feature_specs, .report_pack_failures = true, .report = &report });
    io.writeStderr(report.syntax.items);
    const src = loaded catch |e| {
        switch (e) {
            // The report above names what does not lex or parse.
            error.ProgramSyntax => {},
            error.ProgramUnreadable => io.printStderr(gpa, "error: cannot read {s}: {s}\n", .{ report.unreadable.?.path, @errorName(report.unreadable.?.err) }),
            else => io.printStderr(gpa, "error: cannot load the program: {s}\n", .{@errorName(e)}),
        }
        return null;
    };
    const built = sema_run.buildRun(gpa, arena, map, src, sema_cmd.hostBinding(gpa)) catch |e| {
        io.printStderr(gpa, "error: the sema pipeline failed: {s}\n", .{@errorName(e)});
        return null;
    };
    const s = built.s;
    var errors: usize = 0;
    for (s.census.sites.items) |site| {
        const fc = s.fileOf(site.file) orelse continue;
        if (fc.origin != .program) continue;
        errors += 1;
        io.printStderr(gpa, "error: {s}: unresolved ({s}) {s}\n", .{ pipeline.where(arena, map, site.sp) catch "?", @tagName(site.reason), site.detail });
    }
    for (built.prog.errors.items) |le| {
        const file = if (le.span.file.int() < map.files.items.len) map.get(le.span.file).path else "";
        const in_program = for (src.program) |p| {
            if (std.mem.eql(u8, p.path, file)) break true;
        } else false;
        if (!in_program) continue;
        errors += 1;
        const f = built.br.m.funcs.items[le.func.int()];
        io.printStderr(gpa, "error: {s}: in {s}: {s}\n", .{ pipeline.where(arena, map, le.span) catch "?", f.fqn, le.msg });
    }
    if (errors != 0) return null;
    const main_sym = (pipeline.mainOf(s) catch {
        io.printStderr(gpa, "error: out of memory\n", .{});
        return null;
    }) orelse {
        io.printStderr(gpa, "error: no `main` function in {s}\n", .{pipeline.mainFileName(s)});
        return null;
    };
    const main = built.br.funcOfOpt(main_sym) orelse {
        io.printStderr(gpa, "error: `main` has no id\n", .{});
        return null;
    };
    return .{ .built = built, .main = main };
}

/// `klio transpile --native <file> [-o out.c]`: the program as standalone C.
/// Exit 1 when the program is outside what the backend compiles.
pub fn runNative(gpa: Allocator, paths: []const []const u8, out_path: ?[]const u8, feature_specs: []const []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var map = span.SourceMap.init(arena);
    span.active_map = &map;
    defer span.active_map = null;

    const path = paths[0];
    const c_out = out_path orelse blk: {
        const base = std.fs.path.basename(path);
        const stem = if (std.mem.endsWith(u8, base, ".kt")) base[0 .. base.len - 3] else base;
        break :blk std.fmt.allocPrint(arena, "{s}.c", .{stem}) catch return 1;
    };
    const b = buildProgram(gpa, arena, &map, paths, feature_specs) orelse return 1;
    if (std.c.getenv("KLIO_CGEN_REACH") != null) dumpReach(gpa, b) catch {};
    if (std.c.getenv("KLIO_CGEN_DUMP")) |want| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        ir.disasm.dumpModule(&aw.writer, b.built.br.m, .{ .func_filter = std.mem.span(want) }) catch {};
        io.printStderr(gpa, "{s}", .{aw.written()});
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const refusal = cgen.emitProgram(gpa, b.built.br, b.main, &aw.writer, path) catch |e| {
        io.printStderr(gpa, "error: native emission failed: {s}\n", .{@errorName(e)});
        return 2;
    };
    if (refusal) |why| {
        defer gpa.free(why);
        io.printStderr(gpa, "error: refuse {s}; `klio transpile` without --native emits the launcher form\n", .{why});
        return 1;
    }
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = c_out, .data = aw.written() }) catch {
        io.printStderr(gpa, "error: cannot write `{s}`\n", .{c_out});
        return 1;
    };
    io.printStderr(gpa, "wrote {s} ({d} bytes, standalone)\n", .{ c_out, aw.written().len });
    return 0;
}

/// `klio transpile <file> [-o out.c]`: a launcher, the C `main` that boots
/// the runtime over the program, linked against `libklio_rt`. The program's
/// base is baked into a sema image written beside the C (`out.klio-image`),
/// which a compiler with `#embed` builds into the binary; the program's
/// sources are in the C. The program builds over that image here, so one
/// that does not build fails now rather than when the binary runs. Build:
/// `zig cc out.c -I<include> -L<lib> -lklio_rt -lzstd`.
pub fn runLauncher(gpa: Allocator, paths: []const []const u8, out_path: ?[]const u8, feature_specs: []const []const u8) u8 {
    const path = paths[0];
    const mem = sema_run.RunMemory.init() catch return 2;
    defer mem.deinit();
    const arena = mem.arena();
    const c_out = out_path orelse blk: {
        const base = std.fs.path.basename(path);
        const stem = if (std.mem.endsWith(u8, base, ".kt")) base[0 .. base.len - 3] else base;
        break :blk std.fmt.allocPrint(arena, "{s}.c", .{stem}) catch return 1;
    };
    const image_out = std.fmt.allocPrint(arena, "{s}.klio-image", .{if (std.mem.endsWith(u8, c_out, ".c")) c_out[0 .. c_out.len - 2] else c_out}) catch return 1;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const fio = threaded.io();
    const texts = arena.alloc([]const u8, paths.len) catch return 2;
    for (paths, texts) |p, *t| {
        t.* = std.Io.Dir.cwd().readFileAlloc(fio, p, arena, .unlimited) catch {
            io.printStderr(gpa, "error: cannot read {s}: ReadFailed\n", .{p});
            return 1;
        };
    }
    const baked = image_cmd.bakeFor(gpa, mem, paths, texts, feature_specs, null) catch |e| switch (e) {
        error.Reported => return 1,
        else => {
            io.printStderr(gpa, "error: the base image for this program did not bake: {s}\n", .{@errorName(e)});
            return 1;
        },
    };
    defer gpa.free(baked.bytes);
    const built = pipeline.buildOnBase(arena, baked.src, sema_cmd.hostBinding(gpa), baked.base) catch |e| {
        io.printStderr(gpa, "error: the program does not build over its base image: {s}\n", .{@errorName(e)});
        return 1;
    };
    if (sema_run.reportProgramErrors(gpa, arena, mem.map, baked.src.program, &built) != 0) return 1;
    const found = pipeline.mainOf(built.s) catch {
        io.writeStderr("error: out of memory\n");
        return 1;
    };
    if (found == null) {
        io.writeStderr("error: no main function found\n");
        return 1;
    }

    // The binary runs from anywhere, so it names its files absolutely.
    var abs: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        const full = std.Io.Dir.cwd().realPathFileAlloc(fio, p, arena) catch {
            io.printStderr(gpa, "error: cannot resolve `{s}`\n", .{p});
            return 1;
        };
        abs.append(arena, full) catch return 1;
    }
    std.Io.Dir.cwd().writeFile(fio, .{ .sub_path = image_out, .data = baked.bytes }) catch {
        io.printStderr(gpa, "error: cannot write `{s}`\n", .{image_out});
        return 1;
    };
    const image_abs = std.Io.Dir.cwd().realPathFileAlloc(fio, image_out, arena) catch {
        io.printStderr(gpa, "error: cannot resolve `{s}`\n", .{image_out});
        return 1;
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeLauncher(&aw.writer, path, .{
        .image_name = std.fs.path.basename(image_out),
        .image_path = image_abs,
        .paths = abs.items,
        .texts = texts,
    }) catch return 1;
    std.Io.Dir.cwd().writeFile(fio, .{ .sub_path = c_out, .data = aw.written() }) catch {
        io.printStderr(gpa, "error: cannot write `{s}`\n", .{c_out});
        return 1;
    };
    io.printStderr(gpa, "wrote {s} ({d} bytes, launcher) and {s} ({d} bytes)\n", .{ c_out, aw.written().len, image_out, baked.bytes.len });
    return 0;
}

/// What a launcher hands the runtime.
const Launch = struct {
    /// The sema image's file name beside the C, for `#embed`.
    image_name: []const u8,
    /// Where the image was written, read when the compiler has no `#embed`.
    image_path: []const u8,
    /// The programs' files, absolute, and their text.
    paths: []const []const u8,
    texts: []const []const u8,
};

/// The launcher's C: the sema image, the program's files and their text,
/// and a `main` that hands them and its arguments to the runtime.
fn writeLauncher(w: *std.Io.Writer, src_path: []const u8, l: Launch) !void {
    const ctype = @import("cgen/ctype.zig");
    try w.print(
        \\/* Generated by `klio transpile {s}`. Do not edit.
        \\ * A launcher: it boots the klio runtime over the program, built over the
        \\ * sema image beside this file, which a compiler with `#embed` builds in;
        \\ * elsewhere the binary reads it from where it was written.
        \\ * Build: zig cc <this file> -I<include> -L<lib> -lklio_rt -lzstd */
        \\#include <klio_rt.h>
        \\
        \\#ifdef __clang__
        \\#pragma clang diagnostic ignored "-Wc23-extensions"
        \\#endif
        \\#if defined(__has_embed)
        \\#if __has_embed(
    , .{src_path});
    try ctype.writeCString(w, l.image_name);
    try w.writeAll(")\nstatic const unsigned char KLIO_IMAGE[] = {\n#embed ");
    try ctype.writeCString(w, l.image_name);
    try w.writeAll(
        \\
        \\};
        \\#define KLIO_IMAGE_BYTES KLIO_IMAGE, sizeof KLIO_IMAGE
        \\#endif
        \\#endif
        \\#ifndef KLIO_IMAGE_BYTES
        \\#define KLIO_IMAGE_BYTES 0, 0
        \\#endif
        \\
        \\static const char KLIO_IMAGE_PATH[] =
    );
    try w.writeByte(' ');
    try ctype.writeCString(w, l.image_path);
    try w.writeAll(";\nstatic const char *const KLIO_PATHS[] = {");
    for (l.paths, 0..) |s, i| {
        if (i != 0) try w.writeAll(", ");
        try ctype.writeCString(w, s);
    }
    try w.writeAll("};\n");
    for (l.texts, 0..) |t, i| {
        try w.print("static const char KLIO_TEXT_{d}[] =\n", .{i});
        try writeText(w, t);
        try w.writeAll(";\n");
    }
    try w.writeAll("static const char *const KLIO_TEXTS[] = {");
    for (l.texts, 0..) |_, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("KLIO_TEXT_{d}", .{i});
    }
    try w.print(
        \\}};
        \\
        \\int main(int argc, char **argv) {{
        \\  return klio_rt_run_image(KLIO_IMAGE_BYTES, KLIO_IMAGE_PATH, KLIO_PATHS, KLIO_TEXTS, {d},
        \\                           (const char *const *)argv + 1, (uint32_t)(argc - 1));
        \\}}
        \\
    , .{l.paths.len});
}

/// A source text as C string literals, one per line.
fn writeText(w: *std.Io.Writer, text: []const u8) !void {
    const ctype = @import("cgen/ctype.zig");
    if (text.len == 0) return w.writeAll("  \"\"");
    var rest = text;
    var first = true;
    while (rest.len != 0) {
        const nl = std.mem.findScalar(u8, rest, '\n');
        const line = if (nl) |k| rest[0..k] else rest;
        if (!first) try w.writeByte('\n');
        first = false;
        try w.writeAll("  \"");
        try ctype.writeCChars(w, line);
        if (nl != null) try w.writeAll("\\n");
        try w.writeByte('"');
        rest = rest[@min(rest.len, line.len + 1)..];
    }
}

test "a launcher embeds its image and hands the runtime its files, their text and its arguments" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeLauncher(&aw.writer, "a.kt", .{
        .image_name = "a.klio-image",
        .image_path = "/p/a.klio-image",
        .paths = &.{"/p/a.kt"},
        .texts = &.{"fun main() {\n    println(\"hi\")\n}\n"},
    });
    const c = aw.written();
    try std.testing.expect(std.mem.find(u8, c, "#if __has_embed(\"a.klio-image\")") != null);
    try std.testing.expect(std.mem.find(u8, c, "#embed \"a.klio-image\"") != null);
    try std.testing.expect(std.mem.find(u8, c, "KLIO_IMAGE_PATH[] = \"/p/a.klio-image\";") != null);
    try std.testing.expect(std.mem.find(u8, c, "KLIO_PATHS[] = {\"/p/a.kt\"}") != null);
    try std.testing.expect(std.mem.find(u8, c, "  \"fun main() {\\n\"\n  \"    println(\\\"hi\\\")\\n\"\n  \"}\\n\";") != null);
    try std.testing.expect(std.mem.find(u8, c, "klio_rt_run_image(KLIO_IMAGE_BYTES, KLIO_IMAGE_PATH, KLIO_PATHS, KLIO_TEXTS, 1,") != null);
}

/// Whether `f` is declared in one of the program's own files.
fn isProgramFunc(br: *const ir.bridge.Bridge, f: ir.FuncId) bool {
    const s = br.s;
    if (f.int() >= br.origin.len) return false;
    // A base loaded from its image keeps origins this analysis never made.
    if (br.layer_ends.len != 0 and f.int() < br.layer_ends[0].funcs) return false;
    const sym: sema.Sym = switch (br.origin[f.int()]) {
        .decl, .getter, .setter, .defaults, .lambda, .sam_ctor, .sam_method, .sam_equals, .sam_hash_code, .abstract, .restart => |x| x,
        .init_unit => |u| switch (br.units[u]) {
            .file => |file| return if (s.fileOf(file)) |fc| fc.origin == .program else false,
            .enum_class => |e| e,
        },
        .adapter => |i| br.adapters[i].target,
    };
    const file = s.syms.get(sym).file;
    const fc = s.fileOf(file) orelse return false;
    return fc.origin == .program;
}

fn bump(gpa: Allocator, tags: *std.StringArrayHashMapUnmanaged(u32), tag: []const u8) !void {
    const gop = try tags.getOrPut(gpa, tag);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
}

/// `KLIO_CGEN_REACH`: what the program reaches, for widening the backend.
fn dumpReach(gpa: Allocator, b: Built) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var rc = reach_mod.init(arena_state.allocator(), b.built.br) orelse return;
    try rc.walk(b.main);
    const m = b.built.br.m;
    const r = rc.r;
    var tags = std.StringArrayHashMapUnmanaged(u32).empty;
    defer tags.deinit(gpa);
    var n_user: usize = 0;
    for (rc.funcs.items) |id| {
        const f = m.funcById(id).?;
        const user = isProgramFunc(b.built.br, id);
        if (user) n_user += 1;
        var n: usize = 0;
        for (f.blocks) |*blk| {
            n += blk.insts.len;
            for (blk.insts) |*inst| try bump(gpa, &tags, @tagName(std.meta.activeTag(inst.*)));
            try bump(gpa, &tags, @tagName(std.meta.activeTag(blk.terminator)));
            if (blk.h().any()) try bump(gpa, &tags, "<handlers>");
        }
        std.debug.print("[reach] func {s} #{d} {s} insts={d}{s}\n", .{ if (user) "user" else "base", id.int(), f.fqn, n, if (f.is_suspend) " suspend" else "" });
    }
    for (rc.natives.items) |nid| {
        const n = r.natives[nid.int()];
        std.debug.print("[reach] native #{d} {s} table={s} key={s} op={s} host_fn={} static={} recv={} reified={d} vararg={?d}\n", .{ nid.int(), n.name, @tagName(n.table), n.key, @tagName(n.op), n.host_fn != null, n.static_, n.receiver, n.reified, n.vararg_back });
    }
    for (rc.constructed.items) |c| std.debug.print("[reach] class #{d} {s}\n", .{ c.int(), m.classes.items[c.int()].fqn });
    for (rc.objects.items) |c| std.debug.print("[reach] object #{d} {s}\n", .{ c.int(), m.classes.items[c.int()].fqn });
    for (rc.slots.items) |sl| std.debug.print("[reach] slot #{d} {s}\n", .{ sl.int(), if (m.funcById(ir.FuncId.from(sl.int()))) |f| f.fqn else "?" });
    for (rc.statics.items) |st| std.debug.print("[reach] static #{d} {s}\n", .{ st.int(), r.statics[st.int()].name });
    for (rc.closure_sites.items) |cl| std.debug.print("[reach] closure #{d} {s}\n", .{ cl.body.int(), if (m.funcById(cl.body)) |f| f.fqn else "?" });
    for (rc.missing.items) |mi| std.debug.print("[reach] missing #{d} {s}\n", .{ mi.int(), if (m.funcById(mi)) |f| f.fqn else "?" });
    var it = tags.iterator();
    while (it.next()) |e| std.debug.print("[reach] tag {s} {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    std.debug.print("[reach] total funcs={d} user={d} natives={d} classes={d}\n", .{ rc.funcs.items.len, n_user, rc.natives.items.len, rc.constructed.items.len });
}
