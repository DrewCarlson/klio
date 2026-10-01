//! Machine code for klio's JIT: executable memory (`mem`) and an assembler
//! per architecture (`a64`, `x64`). What gets compiled, and how compiled
//! code meets the interpreter, is the evaluator's (`plans/jit.md`).

const std = @import("std");
const builtin = @import("builtin");

pub const mem = @import("mem.zig");
pub const a64 = @import("a64.zig");
pub const x64 = @import("x64.zig");

/// Whether this build can compile and run code: an architecture with an
/// assembler on a system with executable memory.
pub const supported = mem.supported;

/// Copies `bytes` into `heap` and makes them runnable; answers the address
/// they run at.
pub fn install(heap: *mem.Heap, bytes: []const u8) mem.Error!usize {
    const code = try heap.alloc(bytes.len);
    mem.beginWrite();
    @memcpy(code.w[0..bytes.len], bytes);
    mem.publish(code);
    return code.x;
}

test {
    std.testing.refAllDecls(@This());
    _ = mem;
    _ = a64;
    _ = x64;
    _ = @import("x64_test.zig");
}

const Fn2 = *const fn (u64, u64) callconv(.c) u64;

test "assembled code runs: a loop, a call out and a literal" {
    if (comptime !supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var heap: mem.Heap = .{};
    defer heap.deinit();
    const Helper = struct {
        fn triple(v: u64) callconv(.c) u64 {
            return v * 3;
        }
    };
    const bytes = switch (builtin.cpu.arch) {
        .aarch64 => blk: {
            // sum = 0; for (i = a; i != 0; i--) sum += b; return triple(sum) + 0x1122334455667788
            var a = a64.Asm.init(gpa);
            defer a.deinit();
            const top = try a.newLabel();
            const done = try a.newLabel();
            try a.stpPre(a64.fp, a64.lr, a64.sp, -16);
            try a.movImm(.x, .x2, 0);
            a.bind(top);
            try a.cbz(.x, .x0, done);
            try a.add(.x, .x2, .x2, .x1);
            try a.subImm(.x, .x0, .x0, 1);
            try a.b(top);
            a.bind(done);
            try a.mov(.x, .x0, .x2);
            try a.callAbs(@intFromPtr(&Helper.triple), .x16);
            try a.ldrLit(.x1, 0x1122334455667788);
            try a.add(.x, .x0, .x0, .x1);
            try a.ldpPost(a64.fp, a64.lr, a64.sp, 16);
            try a.ret();
            break :blk try a.finish();
        },
        .x86_64 => blk: {
            var a = x64.Asm.init(gpa);
            defer a.deinit();
            const top = try a.newLabel();
            const done = try a.newLabel();
            try a.push(.rbx);
            try a.movImm(.rbx, 0);
            a.bind(top);
            try a.@"test"(.q, .rdi, .rdi);
            try a.jcc(.e, done);
            try a.add(.q, .rbx, .rsi);
            try a.subImm(.q, .rdi, 1);
            try a.jmp(top);
            a.bind(done);
            try a.mov(.q, .rdi, .rbx);
            try a.callAbs(@intFromPtr(&Helper.triple));
            try a.loadLit(.rcx, 0x1122334455667788);
            try a.add(.q, .rax, .rcx);
            try a.pop(.rbx);
            try a.ret();
            break :blk try a.finish();
        },
        else => unreachable,
    };
    defer gpa.free(bytes);
    const at = try install(&heap, bytes);
    const f: Fn2 = @ptrFromInt(at);
    try std.testing.expectEqual(@as(u64, 7 * 5 * 3 + 0x1122334455667788), f(7, 5));
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), f(0, 9));
}
