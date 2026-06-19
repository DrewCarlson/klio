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

    /// REX.W for a two-operand op: `reg` is the ModRM.reg field (REX.R),
    /// `rm` the ModRM.r/m field (REX.B).
    fn rexWrr(self: *Emitter, reg: Reg, rm: Reg) JitError!void {
        const rex_r: u8 = if (@intFromEnum(reg) >= 8) 0x04 else 0;
        const rex_b: u8 = if (@intFromEnum(rm) >= 8) 0x01 else 0;
        try self.byte(0x48 | rex_r | rex_b);
    }
    /// ModRM byte for register-direct (mod=11): `reg`/`rm` fields.
    fn modrmRR(self: *Emitter, reg: Reg, rm: Reg) JitError!void {
        try self.byte(0xC0 | (low3(reg) << 3) | low3(rm));
    }

    /// `add <dst64>, <src64>` (dst += src).
    pub fn addReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.rexWrr(src, dst);
        try self.byte(0x01); // ADD r/m64, r64
        try self.modrmRR(src, dst);
    }

    /// `sub <dst64>, <src64>` (dst -= src).
    pub fn subReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.rexWrr(src, dst);
        try self.byte(0x29); // SUB r/m64, r64
        try self.modrmRR(src, dst);
    }

    /// `mov <dst64>, <src64>`.
    pub fn movReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.rexWrr(src, dst);
        try self.byte(0x89); // MOV r/m64, r64
        try self.modrmRR(src, dst);
    }

    /// `imul <dst64>, <src64>` (dst *= src).
    pub fn imulReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.rexWrr(dst, src);
        try self.byte(0x0F);
        try self.byte(0xAF); // IMUL r64, r/m64
        try self.modrmRR(dst, src);
    }

    /// `cmp <a64>, <b64>` (sets flags for a - b).
    pub fn cmpReg(self: *Emitter, a: Reg, b: Reg) JitError!void {
        try self.rexWrr(b, a);
        try self.byte(0x39); // CMP r/m64, r64
        try self.modrmRR(b, a);
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

test "register ALU ops compute the same as native" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    // f(a=rdi, b=rsi): rax = ((a - b) * b) ... then return; verifies sub/mov/imul.
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.movReg(.rax, .rdi); // rax = a
    try em.subReg(.rax, .rsi); // rax = a - b
    try em.imulReg(.rax, .rsi); // rax = (a - b) * b
    try em.ret();
    var buf = try finalize(em.code());
    defer buf.deinit();
    const f = buf.entry(*const fn (i64, i64) callconv(.c) i64);
    try std.testing.expectEqual(@as(i64, (10 - 3) * 3), f(10, 3));
    try std.testing.expectEqual(@as(i64, (100 - 7) * 7), f(100, 7));
}

test "ALU encodings match documented bytes" {
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.movReg(.rax, .rdi); // 48 89 F8 (mov rax, rdi)
    try em.subReg(.rax, .rsi); // 48 29 F0 (sub rax, rsi)
    try em.imulReg(.rax, .rsi); // 48 0F AF C6 (imul rax, rsi)
    try em.cmpReg(.rax, .rcx); // 48 39 C8 (cmp rax, rcx)
    try std.testing.expectEqualSlices(u8, &.{
        0x48, 0x89, 0xF8,
        0x48, 0x29, 0xF0,
        0x48, 0x0F, 0xAF, 0xC6,
        0x48, 0x39, 0xC8,
    }, em.code());
}
