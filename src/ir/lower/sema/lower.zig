//! The program driver: lowers every `FuncId` the bridge allocated, except
//! the abstract ones, each on its own builder, an inline function before
//! its first instantiation.

const std = @import("std");
const sema = @import("sema");

const bridge = @import("../../core/bridge.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const body = @import("body.zig");
const operator = @import("operator.zig");
const ir = @import("../../ir.zig");

const Allocator = std.mem.Allocator;
const Error = records.Error;
const Program = builder.Program;
const FuncId = ir.FuncId;
const Sym = sema.Sym;

/// Lowers every body the bridge allocated an id for, in id order, inline
/// functions first so an instantiation finds its callee lowered. A body
/// that fails records its error in the program and the rest still lower;
/// only running out of memory stops it. Bodies in files the bridge does
/// not lower (`Bridge.lowersFile`) are left as shells.
pub fn lowerProgram(a: Allocator, s: *sema.Sema, br: *bridge.Bridge) Error!Program {
    return lowerFrom(a, s, br, .{});
}

/// `lowerProgram` over a bridge `bridge.buildOver` extended: the loaded
/// base's bodies, `FuncId`s below `base_lowered.bit_length`, were lowered
/// when it was baked, those set in `base_lowered` successfully. They are
/// not lowered again and their origins are not read.
pub fn lowerProgramOver(a: Allocator, s: *sema.Sema, br: *bridge.Bridge, base_lowered: std.DynamicBitSetUnmanaged) Error!Program {
    return lowerFrom(a, s, br, base_lowered);
}

fn lowerFrom(a: Allocator, s: *sema.Sema, br: *bridge.Bridge, base_lowered: std.DynamicBitSetUnmanaged) Error!Program {
    const prims = try a.create(operator.PrimTable);
    prims.* = try operator.PrimTable.init(a, s);
    var p: Program = .{ .a = a, .s = s, .br = br, .m = br.m, .prims = prims };
    errdefer p.freeScratch();
    const n = br.origin.len;
    const first: u32 = @intCast(@min(base_lowered.bit_length, n));
    p.lowered = try std.DynamicBitSetUnmanaged.initEmpty(a, n);
    p.attempted = try std.DynamicBitSetUnmanaged.initEmpty(a, n);
    var i: u32 = 0;
    while (i < first) : (i += 1) {
        p.attempted.set(i);
        if (base_lowered.isSet(i)) p.lowered.set(i);
    }
    var tried = try std.DynamicBitSetUnmanaged.initEmpty(a, n);
    for ([_]bool{ true, false }) |inline_pass| {
        i = first;
        while (i < n) : (i += 1) {
            if (tried.isSet(i)) continue;
            const f = FuncId.from(i);
            if (isInline(s, br.origin[i]) != inline_pass) continue;
            if (!lowersBody(s, br, br.origin[i])) continue;
            tried.set(i);
            try body.lowerBody(&p, f);
        }
    }
    p.freeScratch();
    if (std.c.getenv("KLIO_LOWER_FINGERPRINT") != null) printFingerprints(&p, first);
    return p;
}

/// `KLIO_LOWER_FINGERPRINT`: a line for each body lowered from `first` on,
/// with its block, instruction and register counts and a hash of its
/// blocks by value, to compare two builds' lowering body by body.
fn printFingerprints(p: *const Program, first: u32) void {
    var i: u32 = first;
    while (i < p.m.funcs.items.len) : (i += 1) {
        if (!p.isLowered(FuncId.from(i))) continue;
        const f = &p.m.funcs.items[i];
        var h = std.hash.Wyhash.init(0);
        var insts: usize = 0;
        for (f.blocks) |*blk| {
            insts += blk.insts.len;
            std.hash.autoHashStrat(&h, blk.insts, .DeepRecursive);
            std.hash.autoHash(&h, blk.terminator);
            std.hash.autoHashStrat(&h, blk.h().*, .DeepRecursive);
        }
        std.debug.print("[fn] {d} blocks={d} insts={d} locals={d} hash={x}\n", .{ i, f.blocks.len, insts, f.n_locals, h.final() });
    }
}

/// Whether a function's body is an inline function's, which callers
/// instantiate.
fn isInline(s: *sema.Sema, origin: bridge.FuncOrigin) bool {
    return switch (origin) {
        .decl => |d| s.syms.kind(d) == .function and s.syms.flags(d).inline_,
        else => false,
    };
}

/// Whether the file an origin's declaration is in gets bodies.
fn lowersBody(s: *sema.Sema, br: *const bridge.Bridge, origin: bridge.FuncOrigin) bool {
    const sym: Sym = switch (origin) {
        .decl, .getter, .setter, .defaults, .lambda, .sam_ctor, .sam_method, .sam_equals, .sam_hash_code, .abstract, .restart => |x| x,
        .init_unit => |u| switch (br.units[u]) {
            .file, .eager_file => |f| return br.lowersFile(f),
            .enum_class => |e| e,
        },
        .adapter => return true,
    };
    const file = s.syms.get(sym).file;
    if (file == sema.symbols.NO_FILE) return true;
    return br.lowersFile(file);
}
