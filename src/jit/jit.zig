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
    /// Label slots; `null` until bound to a code offset.
    labels: std.ArrayListUnmanaged(?usize) = .empty,
    /// Pending forward-jump rel32 patches, applied at `bind`.
    fixups: std.ArrayListUnmanaged(Fixup) = .empty,
    a: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) Emitter {
        return .{ .a = a };
    }
    pub fn deinit(self: *Emitter) void {
        self.buf.deinit(self.a);
        self.labels.deinit(self.a);
        self.fixups.deinit(self.a);
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

    /// `cqo` — sign-extend rax into rdx:rax (for a signed 64-bit divide).
    pub fn cqo(self: *Emitter) JitError!void {
        try self.byte(0x48);
        try self.byte(0x99);
    }

    /// `idiv <src64>` — signed divide rdx:rax by `src`; quotient in rax,
    /// remainder in rdx. Caller must `cqo` first and guard divide-by-zero and
    /// the INT_MIN/-1 overflow (both raise #DE on x86).
    pub fn idivReg(self: *Emitter, src: Reg) JitError!void {
        try self.rexW(src);
        try self.byte(0xF7);
        try self.byte(0xF8 | low3(src)); // /7, mod=11
    }

    /// `cmp <a64>, <b64>` (sets flags for a - b).
    pub fn cmpReg(self: *Emitter, a: Reg, b: Reg) JitError!void {
        try self.rexWrr(b, a);
        try self.byte(0x39); // CMP r/m64, r64
        try self.modrmRR(b, a);
    }

    /// `neg <dst64>` (two's-complement negate).
    pub fn negReg(self: *Emitter, dst: Reg) JitError!void {
        try self.rexW(dst);
        try self.byte(0xF7);
        try self.byte(0xD8 | low3(dst)); // /3, mod=11
    }

    /// `add <dst64>, imm32` (sign-extended).
    pub fn addImm32(self: *Emitter, dst: Reg, v: i32) JitError!void {
        try self.rexWrr(.rax, dst); // reg field unused (=/0), only REX.B for dst
        try self.byte(0x81);
        try self.byte(0xC0 | low3(dst)); // /0
        try self.imm32(@bitCast(v));
    }

    /// `cmp <a64>, imm32` (sign-extended).
    pub fn cmpImm32(self: *Emitter, a: Reg, v: i32) JitError!void {
        try self.rexWrr(.rax, a);
        try self.byte(0x81);
        try self.byte(0xF8 | low3(a)); // /7
        try self.imm32(@bitCast(v));
    }

    /// `mov <dst64>, [<base64> + disp32]`.
    pub fn loadMem(self: *Emitter, dst: Reg, base: Reg, disp: i32) JitError!void {
        try self.rexWrr(dst, base);
        try self.byte(0x8B); // MOV r64, r/m64
        try self.memOperand(dst, base, disp);
    }

    /// `mov [<base64> + disp32], <src64>`.
    pub fn storeMem(self: *Emitter, base: Reg, disp: i32, src: Reg) JitError!void {
        try self.rexWrr(src, base);
        try self.byte(0x89); // MOV r/m64, r64
        try self.memOperand(src, base, disp);
    }

    /// ModRM+SIB+disp32 for `[base + disp32]` with ModRM.reg = `reg`. `rsp`/`r12`
    /// bases require a SIB byte; mod=10 always emits a 32-bit displacement.
    fn memOperand(self: *Emitter, reg: Reg, base: Reg, disp: i32) JitError!void {
        const rm = low3(base);
        try self.byte(0x80 | (low3(reg) << 3) | rm); // mod=10
        if (rm == 0x4) try self.byte(0x24); // SIB: base=rsp/r12, index=none, scale=1
        try self.imm32(@bitCast(disp));
    }

    /// `push <reg64>`.
    pub fn push(self: *Emitter, r: Reg) JitError!void {
        if (@intFromEnum(r) >= 8) try self.byte(0x41);
        try self.byte(0x50 | low3(r));
    }
    /// `pop <reg64>`.
    pub fn pop(self: *Emitter, r: Reg) JitError!void {
        if (@intFromEnum(r) >= 8) try self.byte(0x41);
        try self.byte(0x58 | low3(r));
    }

    /// `test <a64>, <b64>` (sets flags for a & b).
    pub fn testReg(self: *Emitter, a: Reg, b: Reg) JitError!void {
        try self.rexWrr(b, a);
        try self.byte(0x85); // TEST r/m64, r64
        try self.modrmRR(b, a);
    }

    /// `movsxd <dst64>, <src32>` — sign-extend the low 32 bits of `src` into
    /// `dst` (normalizes a 32-bit Kotlin `Int` result held in a 64-bit slot).
    pub fn movsxd(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.rexWrr(dst, src);
        try self.byte(0x63); // MOVSXD r64, r/m32
        try self.modrmRR(dst, src);
    }

    /// SSE register, by encoding number (parallels `Reg`). The loop compiler
    /// uses xmm0–xmm2 as per-instruction scratch for `f64` arithmetic; an IR
    /// `f64` register keeps its bit pattern in its i64 slot and is moved in/out
    /// with `movsd` (so no integer<->xmm round-trip on the hot path).
    pub const Xmm = enum(u4) {
        xmm0 = 0,
        xmm1 = 1,
        xmm2 = 2,
        xmm3 = 3,
        xmm4 = 4,
        xmm5 = 5,
        xmm6 = 6,
        xmm7 = 7,
        xmm8 = 8,
        xmm9 = 9,
        xmm10 = 10,
        xmm11 = 11,
        xmm12 = 12,
        xmm13 = 13,
        xmm14 = 14,
        xmm15 = 15,
    };
    fn xlow3(x: Xmm) u8 {
        return @as(u8, @intFromEnum(x)) & 0x7;
    }
    /// Optional REX for an SSE op with xmm `reg` field and `rm` (xmm or gpr):
    /// REX.R for an extended xmm reg, REX.B for an extended rm. Emitted only when
    /// an extended register is used (low regs need no REX, keeping encodings tight).
    fn sseRex(self: *Emitter, reg_ext: bool, rm_ext: bool) JitError!void {
        if (reg_ext or rm_ext) {
            const r: u8 = if (reg_ext) 0x04 else 0;
            const b: u8 = if (rm_ext) 0x01 else 0;
            try self.byte(0x40 | r | b);
        }
    }

    /// `movsd <xdst>, [<base64> + disp32]` — load an f64 from a frame slot.
    pub fn movsdLoad(self: *Emitter, dst: Xmm, base: Reg, disp: i32) JitError!void {
        try self.byte(0xF2);
        try self.sseRex(@intFromEnum(dst) >= 8, @intFromEnum(base) >= 8);
        try self.byte(0x0F);
        try self.byte(0x10);
        try self.memOperandX(dst, base, disp);
    }
    /// `movsd [<base64> + disp32], <xsrc>` — store an f64 to a frame slot.
    pub fn movsdStore(self: *Emitter, base: Reg, disp: i32, src: Xmm) JitError!void {
        try self.byte(0xF2);
        try self.sseRex(@intFromEnum(src) >= 8, @intFromEnum(base) >= 8);
        try self.byte(0x0F);
        try self.byte(0x11);
        try self.memOperandX(src, base, disp);
    }
    /// ModRM+SIB+disp32 for `[base + disp32]` with ModRM.reg = an xmm register.
    fn memOperandX(self: *Emitter, reg: Xmm, base: Reg, disp: i32) JitError!void {
        const rm = low3(base);
        try self.byte(0x80 | (xlow3(reg) << 3) | rm); // mod=10
        if (rm == 0x4) try self.byte(0x24); // SIB for rsp/r12 base
        try self.imm32(@bitCast(disp));
    }

    fn sseArith(self: *Emitter, op: u8, dst: Xmm, src: Xmm) JitError!void {
        try self.byte(0xF2);
        try self.sseRex(@intFromEnum(dst) >= 8, @intFromEnum(src) >= 8);
        try self.byte(0x0F);
        try self.byte(op);
        try self.byte(0xC0 | (xlow3(dst) << 3) | xlow3(src)); // mod=11
    }
    /// `addsd <xdst>, <xsrc>` (dst += src, IEEE double).
    pub fn addsd(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.sseArith(0x58, dst, src);
    }
    pub fn subsd(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.sseArith(0x5C, dst, src);
    }
    pub fn mulsd(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.sseArith(0x59, dst, src);
    }
    pub fn divsd(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.sseArith(0x5E, dst, src);
    }
    /// `ucomisd <a>, <b>` — unordered compare, sets ZF/PF/CF (PF=1 on NaN).
    pub fn ucomisd(self: *Emitter, a: Xmm, b: Xmm) JitError!void {
        try self.byte(0x66);
        try self.sseRex(@intFromEnum(a) >= 8, @intFromEnum(b) >= 8);
        try self.byte(0x0F);
        try self.byte(0x2E);
        try self.byte(0xC0 | (xlow3(a) << 3) | xlow3(b));
    }
    /// `cvtsi2sd <xdst>, <src64>` — signed i64 -> f64.
    pub fn cvtsi2sd(self: *Emitter, dst: Xmm, src: Reg) JitError!void {
        try self.byte(0xF2);
        const r: u8 = if (@intFromEnum(dst) >= 8) 0x04 else 0;
        const b: u8 = if (@intFromEnum(src) >= 8) 0x01 else 0;
        try self.byte(0x48 | r | b); // REX.W
        try self.byte(0x0F);
        try self.byte(0x2A);
        try self.byte(0xC0 | (xlow3(dst) << 3) | low3(src));
    }
    /// `cvttsd2si <dst64>, <xsrc>` — f64 -> signed i64 (truncating).
    pub fn cvttsd2si(self: *Emitter, dst: Reg, src: Xmm) JitError!void {
        try self.byte(0xF2);
        const r: u8 = if (@intFromEnum(dst) >= 8) 0x04 else 0;
        const b: u8 = if (@intFromEnum(src) >= 8) 0x01 else 0;
        try self.byte(0x48 | r | b); // REX.W
        try self.byte(0x0F);
        try self.byte(0x2C);
        try self.byte(0xC0 | (low3(dst) << 3) | xlow3(src));
    }

    pub const SetCc = enum(u8) {
        e = 0x94,
        ne = 0x95,
        l = 0x9C,
        ge = 0x9D,
        le = 0x9E,
        g = 0x9F,
        b = 0x92, // unsigned below (CF=1)
        a = 0x97, // unsigned above (CF=0 and ZF=0)
        ae = 0x93, // unsigned above-or-equal (CF=0)
        p = 0x9A, // parity (PF=1 — ucomisd unordered/NaN)
        np = 0x9B, // not parity (PF=0 — ucomisd ordered)
    };

    /// `and <dst64>, <src64>` (dst &= src).
    pub fn andReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.rexWrr(src, dst);
        try self.byte(0x21); // AND r/m64, r64
        try self.modrmRR(src, dst);
    }
    /// `or <dst64>, <src64>` (dst |= src).
    pub fn orReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.rexWrr(src, dst);
        try self.byte(0x09); // OR r/m64, r64
        try self.modrmRR(src, dst);
    }
    /// `setcc <reg8>` then zero-extend to 64 bits — materialize a 0/1 boolean
    /// from the flags into `reg`. Only the low byte is set, so it is zeroed
    /// first via `xor reg,reg` semantics handled by the caller; here we set the
    /// byte then `movzx` it.
    pub fn setccReg(self: *Emitter, cc: SetCc, reg: Reg) JitError!void {
        // setcc r/m8
        if (@intFromEnum(reg) >= 8) try self.byte(0x41) else if (low3(reg) >= 4) try self.byte(0x40); // REX for spl/bpl/sil/dil byte access
        try self.byte(0x0F);
        try self.byte(@intFromEnum(cc));
        try self.byte(0xC0 | low3(reg)); // /0, mod=11
        // movzx reg64, reg8
        try self.rexWrr(reg, reg);
        try self.byte(0x0F);
        try self.byte(0xB6); // MOVZX r64, r/m8
        try self.modrmRR(reg, reg);
    }

    /// Element access width + signedness for `[base + index*scale]`.
    pub const ElemW = enum { b8s, b8u, b16s, b16u, b32s, b32u, b64 };

    /// REX byte for a SIB-addressed op. `w` selects 64-bit operand size.
    fn rexSib(self: *Emitter, reg: Reg, base: Reg, index: Reg, w: bool) JitError!void {
        var b: u8 = 0x40;
        if (w) b |= 0x08;
        if (@intFromEnum(reg) >= 8) b |= 0x04;
        if (@intFromEnum(index) >= 8) b |= 0x02;
        if (@intFromEnum(base) >= 8) b |= 0x01;
        try self.byte(b);
    }
    fn sibScale(scale: u8) u8 {
        return switch (scale) {
            2 => 1,
            4 => 2,
            8 => 3,
            else => 0, // scale 1
        };
    }
    /// ModRM (mod=01, rm=100=SIB) + SIB + disp8=0 for `[base + index*scale]`.
    fn sibOperand(self: *Emitter, reg: Reg, base: Reg, index: Reg, scale: u8) JitError!void {
        try self.byte(0x44 | (low3(reg) << 3));
        try self.byte((sibScale(scale) << 6) | (low3(index) << 3) | low3(base));
        try self.byte(0x00);
    }

    /// `mov <dst64>, [<base> + <index>*scale]` with the given element width,
    /// sign- or zero-extending into the 64-bit destination.
    pub fn loadSib(self: *Emitter, dst: Reg, base: Reg, index: Reg, scale: u8, w: ElemW) JitError!void {
        switch (w) {
            .b8s => {
                try self.rexSib(dst, base, index, true);
                try self.byte(0x0F);
                try self.byte(0xBE);
            },
            .b8u => {
                try self.rexSib(dst, base, index, true);
                try self.byte(0x0F);
                try self.byte(0xB6);
            },
            .b16s => {
                try self.rexSib(dst, base, index, true);
                try self.byte(0x0F);
                try self.byte(0xBF);
            },
            .b16u => {
                try self.rexSib(dst, base, index, true);
                try self.byte(0x0F);
                try self.byte(0xB7);
            },
            .b32s => {
                try self.rexSib(dst, base, index, true);
                try self.byte(0x63); // MOVSXD r64, r/m32
            },
            .b32u => {
                try self.rexSib(dst, base, index, false);
                try self.byte(0x8B); // MOV r32 (zero-extends to r64)
            },
            .b64 => {
                try self.rexSib(dst, base, index, true);
                try self.byte(0x8B);
            },
        }
        try self.sibOperand(dst, base, index, scale);
    }

    /// `mov [<base> + <index>*scale], <src>` storing the low `w` bytes of `src`.
    pub fn storeSib(self: *Emitter, base: Reg, index: Reg, scale: u8, src: Reg, w: ElemW) JitError!void {
        switch (w) {
            .b8s, .b8u => {
                try self.rexSib(src, base, index, false);
                try self.byte(0x88); // MOV r/m8, r8
            },
            .b16s, .b16u => {
                try self.byte(0x66); // operand-size prefix
                try self.rexSib(src, base, index, false);
                try self.byte(0x89);
            },
            .b32s, .b32u => {
                try self.rexSib(src, base, index, false);
                try self.byte(0x89);
            },
            .b64 => {
                try self.rexSib(src, base, index, true);
                try self.byte(0x89);
            },
        }
        try self.sibOperand(src, base, index, scale);
    }

    /// `cmp <a64>, 0` then deopt-jump if signed-less (a < 0).
    /// `ret`.
    pub fn ret(self: *Emitter) JitError!void {
        try self.byte(0xC3);
    }

    // --- labels & jumps ------------------------------------------------------

    pub const Cond = enum(u8) {
        l = 0x8C, // signed <
        ge = 0x8D, // signed >=
        e = 0x84,
        ne = 0x85,
        le = 0x8E,
        g = 0x8F,
    };
    pub const Label = usize;

    /// A jump whose rel32 is patched when its target label is bound.
    const Fixup = struct { at: usize, end: usize, target: Label };

    pub fn newLabel(self: *Emitter) JitError!Label {
        self.labels.append(self.a, null) catch return JitError.OutOfMemory;
        return self.labels.items.len - 1;
    }

    /// Bind `l` to the current position and patch every pending jump to it.
    pub fn bind(self: *Emitter, l: Label) JitError!void {
        const pos = self.buf.items.len;
        self.labels.items[l] = pos;
        var i: usize = 0;
        while (i < self.fixups.items.len) {
            const f = self.fixups.items[i];
            if (f.target == l) {
                const rel: i32 = @intCast(@as(i64, @intCast(pos)) - @as(i64, @intCast(f.end)));
                std.mem.writeInt(i32, self.buf.items[f.at..][0..4], rel, .little);
                _ = self.fixups.swapRemove(i);
            } else i += 1;
        }
    }

    pub fn jmp(self: *Emitter, l: Label) JitError!void {
        try self.byte(0xE9);
        try self.jumpRel(l, self.buf.items.len + 4);
    }
    pub fn jcc(self: *Emitter, cc: Cond, l: Label) JitError!void {
        try self.byte(0x0F);
        try self.byte(@intFromEnum(cc));
        try self.jumpRel(l, self.buf.items.len + 4);
    }
    /// Emit the rel32 field: resolved now if the label is already bound
    /// (backward jump), else a placeholder recorded for patching at `bind`.
    fn jumpRel(self: *Emitter, l: Label, end: usize) JitError!void {
        if (self.labels.items[l]) |tgt| {
            const rel: i32 = @intCast(@as(i64, @intCast(tgt)) - @as(i64, @intCast(end)));
            try self.imm32(@bitCast(rel));
        } else {
            self.fixups.append(self.a, .{ .at = self.buf.items.len, .end = end, .target = l }) catch return JitError.OutOfMemory;
            try self.imm32(0);
        }
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

test "jit compiles a native counted loop (labels + jumps)" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    // f(n=rdi) = sum(0 .. n-1)
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.movImm64(.rax, 0); // sum
    try em.movImm64(.rcx, 0); // i
    const top = try em.newLabel();
    const end = try em.newLabel();
    try em.bind(top);
    try em.cmpReg(.rcx, .rdi); // i - n
    try em.jcc(.ge, end); // i >= n -> exit (forward jump, patched)
    try em.addReg(.rax, .rcx); // sum += i
    try em.addImm32(.rcx, 1); // i++
    try em.jmp(top); // backward jump
    try em.bind(end);
    try em.ret();
    var buf = try finalize(em.code());
    defer buf.deinit();
    const f = buf.entry(*const fn (i64) callconv(.c) i64);
    try std.testing.expectEqual(@as(i64, 4950), f(100));
    try std.testing.expectEqual(@as(i64, 0), f(0));
    try std.testing.expectEqual(@as(i64, 499999500000), f(1000000));
}

test "jit memory load/store through a base register" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    // f(ptr=rdi): slot=[ptr+8]; slot += 5; return slot.
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.loadMem(.rax, .rdi, 8);
    try em.addImm32(.rax, 5);
    try em.storeMem(.rdi, 8, .rax);
    try em.ret();
    var buf = try finalize(em.code());
    defer buf.deinit();
    const f = buf.entry(*const fn (*[2]i64) callconv(.c) i64);
    var arr = [_]i64{ 111, 37 };
    try std.testing.expectEqual(@as(i64, 42), f(&arr));
    try std.testing.expectEqual(@as(i64, 42), arr[1]); // stored back
    try std.testing.expectEqual(@as(i64, 111), arr[0]); // untouched
}

test "push/pop/test/movsxd encode the documented bytes" {
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.push(.rbx); // 53
    try em.pop(.rbx); // 5B
    try em.push(.r12); // 41 54
    try em.testReg(.rax, .rax); // 48 85 C0
    try em.movsxd(.rax, .rax); // 48 63 C0
    try std.testing.expectEqualSlices(u8, &.{
        0x53,
        0x5B,
        0x41, 0x54,
        0x48, 0x85, 0xC0,
        0x48, 0x63, 0xC0,
    }, em.code());
}

test "setcc materializes a boolean from a comparison" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    // f(a=rdi, b=rsi) = (a < b) ? 1 : 0
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.cmpReg(.rdi, .rsi); // a - b
    try em.setccReg(.l, .rax); // rax = (a < b)
    try em.ret();
    var buf = try finalize(em.code());
    defer buf.deinit();
    const f = buf.entry(*const fn (i64, i64) callconv(.c) i64);
    try std.testing.expectEqual(@as(i64, 1), f(3, 4));
    try std.testing.expectEqual(@as(i64, 0), f(4, 3));
    try std.testing.expectEqual(@as(i64, 0), f(5, 5));
}

test "movsxd normalizes a 32-bit overflowed result" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    // f(a=rdi) = sign_extend_i32(a + a) — emulates Kotlin Int wraparound.
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.movReg(.rax, .rdi);
    try em.addReg(.rax, .rdi);
    try em.movsxd(.rax, .rax);
    try em.ret();
    var buf = try finalize(em.code());
    defer buf.deinit();
    const f = buf.entry(*const fn (i64) callconv(.c) i64);
    // 2_000_000_000 + 2_000_000_000 = 4_000_000_000, wraps as i32 to -294967296.
    try std.testing.expectEqual(@as(i64, -294967296), f(2_000_000_000));
}

test "SIB load/store indexes a byte buffer" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    // f(buf=rdi, i=rsi): buf[i] = 1; return buf[i] (zero-extended byte).
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.movImm64(.rax, 1);
    try em.storeSib(.rdi, .rsi, 1, .rax, .b8u);
    try em.loadSib(.rax, .rdi, .rsi, 1, .b8u);
    try em.ret();
    var buf = try finalize(em.code());
    defer buf.deinit();
    const f = buf.entry(*const fn ([*]u8, i64) callconv(.c) i64);
    var arr = [_]u8{ 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(i64, 1), f(&arr, 3));
    try std.testing.expectEqual(@as(u8, 1), arr[3]);
    try std.testing.expectEqual(@as(u8, 0), arr[2]);
}

test "SIB load with scale and sign extension" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    // f(buf=rdi, i=rsi): return (i32)buf[i] sign-extended, scale 4.
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.loadSib(.rax, .rdi, .rsi, 4, .b32s);
    try em.ret();
    var buf = try finalize(em.code());
    defer buf.deinit();
    const f = buf.entry(*const fn ([*]i32, i64) callconv(.c) i64);
    var arr = [_]i32{ 10, -7, 999 };
    try std.testing.expectEqual(@as(i64, -7), f(&arr, 1));
    try std.testing.expectEqual(@as(i64, 999), f(&arr, 2));
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

test "cqo + idiv encode the documented bytes" {
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.cqo(); // 48 99
    try em.idivReg(.rcx); // 48 F7 F9 (idiv rcx)
    try em.idivReg(.rsi); // 48 F7 FE (idiv rsi)
    try std.testing.expectEqualSlices(u8, &.{
        0x48, 0x99,
        0x48, 0xF7, 0xF9,
        0x48, 0xF7, 0xFE,
    }, em.code());
}

test "emitted signed divide and remainder match native" {
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    // fn(rdi=a, rsi=b) -> a / b
    try em.movReg(.rax, .rdi);
    try em.cqo();
    try em.idivReg(.rsi); // quotient in rax
    try em.ret();
    var exec = try finalize(em.code());
    defer exec.deinit();
    const f = exec.entry(*const fn (i64, i64) callconv(.c) i64);
    try std.testing.expectEqual(@as(i64, 7), f(47, 6));
    try std.testing.expectEqual(@as(i64, -7), f(-47, 6));
    try std.testing.expectEqual(@as(i64, 0), f(5, 6));

    var em2 = Emitter.init(std.testing.allocator);
    defer em2.deinit();
    // fn(rdi=a, rsi=b) -> a % b  (remainder in rdx)
    try em2.movReg(.rax, .rdi);
    try em2.cqo();
    try em2.idivReg(.rsi);
    try em2.movReg(.rax, .rdx);
    try em2.ret();
    var exec2 = try finalize(em2.code());
    defer exec2.deinit();
    const g = exec2.entry(*const fn (i64, i64) callconv(.c) i64);
    try std.testing.expectEqual(@as(i64, 5), g(47, 6));
    try std.testing.expectEqual(@as(i64, -5), g(-47, 6));
}

test "SSE double op encodings match documented bytes" {
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    try em.movsdLoad(.xmm0, .rbx, 8); // F2 0F 10 43 08
    try em.movsdStore(.rbx, 16, .xmm1); // F2 0F 11 4B 10
    try em.addsd(.xmm0, .xmm1); // F2 0F 58 C1
    try em.subsd(.xmm0, .xmm1); // F2 0F 5C C1
    try em.mulsd(.xmm0, .xmm1); // F2 0F 59 C1
    try em.divsd(.xmm0, .xmm1); // F2 0F 5E C1
    try em.ucomisd(.xmm0, .xmm1); // 66 0F 2E C1
    try em.cvtsi2sd(.xmm0, .rax); // F2 48 0F 2A C0
    try em.cvttsd2si(.rax, .xmm0); // F2 48 0F 2C C0
    try std.testing.expectEqualSlices(u8, &.{
        0xF2, 0x0F, 0x10, 0x83, 0x08, 0x00, 0x00, 0x00,
        0xF2, 0x0F, 0x11, 0x8B, 0x10, 0x00, 0x00, 0x00,
        0xF2, 0x0F, 0x58, 0xC1,
        0xF2, 0x0F, 0x5C, 0xC1,
        0xF2, 0x0F, 0x59, 0xC1,
        0xF2, 0x0F, 0x5E, 0xC1,
        0x66, 0x0F, 0x2E, 0xC1,
        0xF2, 0x48, 0x0F, 0x2A, 0xC0,
        0xF2, 0x48, 0x0F, 0x2C, 0xC0,
    }, em.code());
}

test "emitted double arithmetic over a slot file matches native" {
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    // fn(rdi = *[2]f64) -> f64 : slots[0]*slots[1] + slots[0]
    try em.push(.rbx);
    try em.movReg(.rbx, .rdi);
    try em.movsdLoad(.xmm0, .rbx, 0); // a
    try em.movsdLoad(.xmm1, .rbx, 8); // b
    try em.mulsd(.xmm0, .xmm1); // a*b
    try em.movsdLoad(.xmm1, .rbx, 0); // a
    try em.addsd(.xmm0, .xmm1); // a*b + a
    // return in xmm0 already (System V f64 return). Move result to slot 0 then load is unnecessary.
    try em.pop(.rbx);
    try em.ret();
    var exec = try finalize(em.code());
    defer exec.deinit();
    const f = exec.entry(*const fn ([*]f64) callconv(.c) f64);
    var slots = [_]f64{ 3.0, 4.0 };
    try std.testing.expectEqual(@as(f64, 15.0), f(&slots)); // 3*4 + 3
    slots = .{ 2.5, -2.0 };
    try std.testing.expectEqual(@as(f64, -2.5), f(&slots)); // 2.5*-2 + 2.5
}

test "cvtsi2sd / cvttsd2si round-trip int<->double" {
    var em = Emitter.init(std.testing.allocator);
    defer em.deinit();
    // fn(rdi=i64) -> i64 : trunc(double(rdi) * 1.5 ... ) ; use cvt both ways
    try em.cvtsi2sd(.xmm0, .rdi); // (double)rdi
    try em.cvttsd2si(.rax, .xmm0); // back to int
    try em.ret();
    var exec = try finalize(em.code());
    defer exec.deinit();
    const f = exec.entry(*const fn (i64) callconv(.c) i64);
    try std.testing.expectEqual(@as(i64, 42), f(42));
    try std.testing.expectEqual(@as(i64, -7), f(-7));
}
