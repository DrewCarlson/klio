//! Ahead-of-time C generation from sema's lowering: the program itself, not
//! a launcher for it. Every function the program reaches from `main` is a C
//! function over the runtime's values; classes, statics, natives and host
//! value kinds are addressed by the ids the bridge allocated. Nothing reads a
//! module at run time and no image is loaded.
//!
//! `reach` walks the program, `sig` and `typing` give every register a
//! machine type, `cfunc` writes one body and `cprog` the whole file.

const std = @import("std");
const ir = @import("ir");

const program = @import("cgen/program.zig");
const cprog = @import("cgen/cprog.zig");

/// Emits the program reached from `main` as C to `w`. Null when it did;
/// otherwise why the program is outside what the backend compiles, owned
/// by `gpa`, and nothing is written.
pub fn emitProgram(gpa: std.mem.Allocator, br: *ir.bridge.Bridge, main: ir.FuncId, w: *std.Io.Writer, src_path: []const u8) !?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var p = try program.build(gpa, a, br, main);
    if (p.refusal) |r| return try gpa.dupe(u8, r);
    var aw: std.Io.Writer.Allocating = .init(a);
    try cprog.write(&p, &aw.writer, src_path);
    if (p.refusal) |r| return try gpa.dupe(u8, r);
    try w.writeAll(aw.written());
    return null;
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("cgen/ctype.zig"));
    std.testing.refAllDecls(@import("cgen/typing.zig"));
    std.testing.refAllDecls(@import("cgen/sig.zig"));
    std.testing.refAllDecls(@import("cgen/reach.zig"));
    std.testing.refAllDecls(@import("cgen/program.zig"));
    std.testing.refAllDecls(@import("cgen/cfunc.zig"));
    std.testing.refAllDecls(@import("cgen/cprog.zig"));
    std.testing.refAllDecls(@import("cgen/rt_abi.zig"));
}
