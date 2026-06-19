//! Tiered native-compiler foundation for KLIO. See `plans/JIT-DESIGN.md`.
//!
//! This is the foundation tier only: W^X executable memory plus a minimal
//! x86-64 (System V) machine-code emitter. The interpreter remains the sole
//! execution engine; the JIT grows as an additive tier with interpreter
//! fallback, so the build stays green at every stage. Nothing here is wired into
//! execution yet — it is the substrate the hot-path compiler is built on.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const JitError = error{ Unsupported, OutOfMemory, MapFailed, ProtectFailed };

/// A finalized block of executable machine code. Holds its own W^X page(s);
/// `deinit` unmaps them. `call` reinterprets the entry as a function pointer.
pub const ExecBuf = struct {
    mem: []align(std.heap.page_size_min) u8,
    len: usize,

    pub fn deinit(self: *ExecBuf) void {
        std.posix.munmap(self.mem);
        self.* = undefined;
    }

    /// Reinterpret the code's entry as a function of type `Fn` (a
    /// `*const fn (...) callconv(.c) T`). The caller is responsible for matching
    /// the actual emitted signature.
    pub fn entry(self: *const ExecBuf, comptime Fn: type) Fn {
        return @ptrCast(@alignCast(self.mem.ptr));
    }
};

/// Copy `code` into fresh page-aligned memory and flip it to read+execute
/// (W^X: written while writable, then sealed before execution — never
/// simultaneously writable and executable).
pub fn finalize(code: []const u8) JitError!ExecBuf {
    if (comptime builtin.cpu.arch != .x86_64) return JitError.Unsupported;
    const page = std.heap.pageSize();
    const sz = std.mem.alignForward(usize, @max(code.len, 1), page);
    const mem = std.posix.mmap(
        null,
        sz,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return JitError.MapFailed;
    @memcpy(mem[0..code.len], code);
    const rc = linux.mprotect(mem.ptr, sz, .{ .READ = true, .EXEC = true });
    if (rc != 0) {
        std.posix.munmap(mem);
        return JitError.ProtectFailed;
    }
    return .{ .mem = mem, .len = code.len };
}

/// x86-64 callee-saved / argument registers under System V, by encoding number.
pub const Reg = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,
};

/// Minimal x86-64 instruction emitter. Grows opcode by opcode as the hot-path
/// compiler needs them (see JIT-DESIGN stage 2). Every encoder is table-tested.
pub const Emitter = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    a: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) Emitter {
        return .{ .a = a };
    }
    pub fn deinit(self: *Emitter) void {
        self.buf.deinit(self.a);
    }
    pub fn code(self: *const Emitter) []const u8 {
        return self.buf.items;
    }

    fn byte(self: *Emitter, b: u8) JitError!void {
        self.buf.append(self.a, b) catch return JitError.OutOfMemory;
    }
    fn imm32(self: *Emitter, v: u32) JitError!void {
        var le: [4]u8 = undefined;
        std.mem.writeInt(u32, &le, v, .little);
        self.buf.appendSlice(self.a, &le) catch return JitError.OutOfMemory;
    }
    fn imm64(self: *Emitter, v: u64) JitError!void {
        var le: [8]u8 = undefined;
        std.mem.writeInt(u64, &le, v, .little);
        self.buf.appendSlice(self.a, &le) catch return JitError.OutOfMemory;
    }
    /// Low 3 bits of a register's encoding, widened to `u8` for ModRM/opcode use.
    fn low3(r: Reg) u8 {
        return @as(u8, @intFromEnum(r)) & 0x7;
    }

    /// REX.W prefix with the B bit for an extended (r8–r15) destination.
    fn rexW(self: *Emitter, dst: Reg) JitError!void {
        const b: u8 = if (@intFromEnum(dst) >= 8) 1 else 0;
        try self.byte(0x48 | b);
    }

    /// `mov <reg64>, imm64` (movabs). Loads a full 64-bit immediate.
    pub fn movImm64(self: *Emitter, dst: Reg, v: u64) JitError!void {
        try self.rexW(dst);
        try self.byte(0xB8 | low3(dst));
        try self.imm64(v);
    }

    /// `add <dst64>, <src64>`.
    pub fn addReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        const rex_r: u8 = if (@intFromEnum(src) >= 8) 0x04 else 0;
        const rex_b: u8 = if (@intFromEnum(dst) >= 8) 0x01 else 0;
        try self.byte(0x48 | rex_r | rex_b);
        try self.byte(0x01);
        try self.byte(0xC0 | (low3(src) << 3) | low3(dst));
    }

    /// `ret`.
    pub fn ret(self: *Emitter) JitError!void {
        try self.byte(0xC3);
    }
};

// --- tests -------------------------------------------------------------------

test "executable memory runs an emitted constant-returning function" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.movImm64(.rax, 42);
    try em.ret();
    var buf = try finalize(em.code());
    defer buf.deinit();
    const f = buf.entry(*const fn () callconv(.c) i64);
    try std.testing.expectEqual(@as(i64, 42), f());
}

test "emitted add of two arguments matches native" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    // System V: arg0 = rdi, arg1 = rsi, return = rax.
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.movImm64(.rax, 0);
    try em.addReg(.rax, .rdi);
    try em.addReg(.rax, .rsi);
    try em.ret();
    var buf = try finalize(em.code());
    defer buf.deinit();
    const f = buf.entry(*const fn (i64, i64) callconv(.c) i64);
    try std.testing.expectEqual(@as(i64, 7), f(3, 4));
    try std.testing.expectEqual(@as(i64, -1), f(10, -11));
}

test "movImm64 encodes the documented bytes" {
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.movImm64(.rax, 42);
    // 48 B8 2A 00 00 00 00 00 00 00
    try std.testing.expectEqualSlices(u8, &.{ 0x48, 0xB8, 0x2A, 0, 0, 0, 0, 0, 0, 0 }, em.code());
}
