//! `klio dump-ir` and `klio transpile-dump`: the program built as `klio run`
//! builds it, its lowered module printed, nothing run.

const std = @import("std");
const span = @import("span");
const ir = @import("ir");

const io = @import("io.zig");
const sema_run = @import("sema_run.zig");

const Allocator = std.mem.Allocator;

/// `klio dump-ir`: every function the program lowered, or those `opts`
/// names, with the direct / virtual / dynamic tally of its calls. What did
/// not resolve or lower in the program is reported, and exits 1 after the
/// dump.
pub fn dumpIr(gpa: Allocator, paths: []const []const u8, feature_specs: []const []const u8, opts: ir.disasm.Options) u8 {
    const mem = sema_run.RunMemory.init() catch return 2;
    defer mem.deinit();
    const p = switch (sema_run.prepare(gpa, mem, paths, .{ .feature_specs = feature_specs, .report_pack_failures = true }, null)) {
        .ok => |ok| ok,
        .exit => |code| return code,
    };
    const errors = sema_run.reportProgramErrors(gpa, mem.arena(), mem.map, p.src.program, &p.built);
    const m = p.built.br.m;
    var o = opts;
    if (o.func_filter != null or o.all) {
        // A base body stays in the base image until something reads it.
        for (m.funcs.items) |*f| {
            if (o.all or named(f, o.func_filter.?)) _ = m.ensureFuncBody(f);
        }
    } else {
        o.program_from = programStart(p.built.br);
    }
    span.dumpFileIds(mem.map);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    ir.disasm.dumpModule(&aw.writer, m, o) catch return 2;
    io.writeStdout(aw.written());
    return if (errors != 0) 1 else 0;
}

/// `klio transpile-dump`: the decoded bytecode stream of each block of each
/// function the program lowered.
pub fn transpileDump(gpa: Allocator, paths: []const []const u8, feature_specs: []const []const u8) u8 {
    const mem = sema_run.RunMemory.init() catch return 2;
    defer mem.deinit();
    const p = switch (sema_run.prepare(gpa, mem, paths, .{ .feature_specs = feature_specs, .report_pack_failures = true }, null)) {
        .ok => |ok| ok,
        .exit => |code| return code,
    };
    const errors = sema_run.reportProgramErrors(gpa, mem.arena(), mem.map, p.src.program, &p.built);
    const m = p.built.br.m;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    const from = @min(programStart(p.built.br), m.funcs.items.len);
    for (m.funcs.items[from..]) |*f| {
        const fs = ir.bc.funcStreams(f, m.consts.items) orelse continue;
        w.print("fn {s} (fid {d}, {d} blocks)\n", .{ f.name, f.id.int(), f.blocks.len }) catch return 2;
        for (0..fs.blocks.len) |bi| {
            w.print(" block b{d}:\n", .{bi}) catch return 2;
            ir.bc.dumpBlock(w, fs, bi) catch return 2;
        }
    }
    io.writeStdout(aw.written());
    return if (errors != 0) 1 else 0;
}

/// The first of the program's functions: the bridge numbers the base's
/// first, through its layer's end.
fn programStart(br: *const ir.bridge.Bridge) u32 {
    if (br.layer_ends.len < 2) return 0;
    return br.layer_ends[0].funcs;
}

fn named(f: *const ir.Func, filter: []const u8) bool {
    return std.mem.find(u8, f.name, filter) != null or std.mem.find(u8, f.fqn, filter) != null;
}
