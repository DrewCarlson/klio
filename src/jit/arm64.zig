//! AArch64 (AAPCS64) machine-code emitter. Mirrors the x86-64 `Emitter` API
//! method-for-method so the loop/function compiler in `ir/jit_loop.zig` is
//! arch-neutral: it programs a fixed-role register machine and this backend
//! lowers each macro-op to ARM64.
//!
//! Role mapping (x86 name -> AArch64 register):
//!   rax (T0, scratch / return / call-target) -> x9
//!   rcx (T1, scratch / shift-count)          -> x10
//!   rdx (T2, scratch / div-remainder)        -> x11
//!   rbx (REGS, slots base pointer)           -> x19  (callee-saved)
//!   rdi (arg0)                               -> x0
//!   rsi (arg1)                               -> x1
//!   xmm0 / xmm1                              -> v0 / v1
//! Internal scratch (never a role): x12 (div quotient), x16/x17 (addr/imm).
//!
//! The C entry contract is preserved: the native unit takes the slots pointer
//! in arg0 and returns its result code in the rax-role. The aarch64 `ret`
//! reconciles that to x0 (the AAPCS return register), and `push`/`pop` pair the
//! REGS save with the link register so a trampoline `blr` is transparent.

const std = @import("std");
const root = @import("jit.zig");

const JitError = root.JitError;
const Reg = root.Reg;
const Xmm = root.Xmm;
const Cond = root.Cond;
const SetCc = root.SetCc;
const ElemW = root.ElemW;

/// AArch64 register number for an x86-role register.
fn gp(r: Reg) u32 {
    return switch (r) {
        .rax => 9,
        .rcx => 10,
        .rdx => 11,
        .rbx => 19,
        .rsi => 1,
        .rdi => 0,
        // Not used as physical registers by the compiler; mapped to spare
        // callee/caller regs so an accidental use is still a valid encoding.
        .rsp => 28,
        .rbp => 29,
        .r8 => 2,
        .r9 => 3,
        .r10 => 4,
        .r11 => 5,
        .r12 => 6,
        .r13 => 7,
        .r14 => 20,
        .r15 => 21,
    };
}
fn fp(x: Xmm) u32 {
    return @intFromEnum(x);
}

const XZR: u32 = 31;
const SP: u32 = 31;
const LR: u32 = 30;
const TMP_DIV: u32 = 12;
const TMP_ADDR: u32 = 16;

/// AArch64 4-bit condition code for an integer/float compare result. The
/// abstract mnemonics partition cleanly: signed forms follow `cmp`, the
/// `a`/`ae`/`be` forms only ever follow `fcmp`, and `e`/`ne` work for both.
fn condCode(c: Cond) u32 {
    return switch (c) {
        .e => 0b0000, // EQ
        .ne => 0b0001, // NE
        .b => 0b0011, // LO  (unsigned <)
        .ae => 0b1010, // GE  (float a>=b)
        .a => 0b1100, // GT  (float a>b)
        .be => 0b1101, // LE  (float !(a>b))
        .l => 0b1011, // LT
        .ge => 0b1010, // GE
        .le => 0b1101, // LE
        .g => 0b1100, // GT
        .p => 0b0110, // VS  (fcmp unordered)
        .np => 0b0111, // VC  (fcmp ordered)
    };
}
fn setCode(c: SetCc) u32 {
    return switch (c) {
        .e => 0b0000,
        .ne => 0b0001,
        .b => 0b0011,
        .a => 0b1100,
        .ae => 0b1010,
        .l => 0b1011,
        .ge => 0b1010,
        .le => 0b1101,
        .g => 0b1100,
        .p => 0b0110,
        .np => 0b0111,
    };
}

pub const Emitter = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    labels: std.ArrayListUnmanaged(?usize) = .empty,
    fixups: std.ArrayListUnmanaged(Fixup) = .empty,
    a: std.mem.Allocator,

    pub const Label = usize;

    /// A branch whose 19- or 26-bit offset is patched when its target binds.
    const Fixup = struct { at: usize, wide: bool, target: Label };

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

    fn inst(self: *Emitter, w: u32) JitError!void {
        var le: [4]u8 = undefined;
        std.mem.writeInt(u32, &le, w, .little);
        self.buf.appendSlice(self.a, &le) catch return JitError.OutOfMemory;
    }

    // --- constant materialization ------------------------------------------

    /// `movz`/`movk` sequence loading a full 64-bit immediate into `rd`.
    fn movImmRaw(self: *Emitter, rd: u32, v: u64) JitError!void {
        try self.inst(0xD2800000 | (@as(u32, @intCast(v & 0xFFFF)) << 5) | rd); // movz rd, #lo16
        var hw: u6 = 1;
        while (hw < 4) : (hw += 1) {
            const part: u64 = (v >> (@as(u6, hw) * 16)) & 0xFFFF;
            if (part == 0) continue;
            try self.inst(0xF2800000 | (@as(u32, hw) << 21) | (@as(u32, @intCast(part)) << 5) | rd);
        }
    }

    pub fn movImm64(self: *Emitter, dst: Reg, v: u64) JitError!void {
        try self.movImmRaw(gp(dst), v);
    }

    // --- register ALU ------------------------------------------------------

    pub fn movReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        // orr dst, xzr, src
        try self.inst(0xAA0003E0 | (gp(src) << 16) | gp(dst));
    }
    pub fn addReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.inst(0x8B000000 | (gp(src) << 16) | (gp(dst) << 5) | gp(dst));
    }
    pub fn subReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.inst(0xCB000000 | (gp(src) << 16) | (gp(dst) << 5) | gp(dst));
    }
    pub fn imulReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        // madd dst, dst, src, xzr
        try self.inst(0x9B000000 | (gp(src) << 16) | (XZR << 10) | (gp(dst) << 5) | gp(dst));
    }
    pub fn negReg(self: *Emitter, dst: Reg) JitError!void {
        // sub dst, xzr, dst
        try self.inst(0xCB000000 | (gp(dst) << 16) | (XZR << 5) | gp(dst));
    }
    pub fn andReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.inst(0x8A000000 | (gp(src) << 16) | (gp(dst) << 5) | gp(dst));
    }
    pub fn orReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.inst(0xAA000000 | (gp(src) << 16) | (gp(dst) << 5) | gp(dst));
    }
    pub fn xorReg(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        try self.inst(0xCA000000 | (gp(src) << 16) | (gp(dst) << 5) | gp(dst));
    }
    pub fn cmpReg(self: *Emitter, a: Reg, b: Reg) JitError!void {
        // subs xzr, a, b
        try self.inst(0xEB000000 | (gp(b) << 16) | (gp(a) << 5) | XZR);
    }
    pub fn testReg(self: *Emitter, a: Reg, b: Reg) JitError!void {
        // ands xzr, a, b
        try self.inst(0xEA000000 | (gp(b) << 16) | (gp(a) << 5) | XZR);
    }
    pub fn movsxd(self: *Emitter, dst: Reg, src: Reg) JitError!void {
        // sxtw dst, src  (sbfm dst, src, #0, #31)
        try self.inst(0x93407C00 | (gp(src) << 5) | gp(dst));
    }

    fn fits12(v: i32) bool {
        return v >= 0 and v < 4096;
    }

    pub fn addImm32(self: *Emitter, dst: Reg, v: i32) JitError!void {
        const d = gp(dst);
        if (fits12(v)) {
            try self.inst(0x91000000 | (@as(u32, @intCast(v)) << 10) | (d << 5) | d);
        } else if (v < 0 and -v < 4096) {
            try self.inst(0xD1000000 | (@as(u32, @intCast(-v)) << 10) | (d << 5) | d);
        } else {
            try self.movImmRaw(TMP_ADDR, @bitCast(@as(i64, v)));
            try self.inst(0x8B000000 | (TMP_ADDR << 16) | (d << 5) | d);
        }
    }
    pub fn cmpImm32(self: *Emitter, a: Reg, v: i32) JitError!void {
        const ra = gp(a);
        if (fits12(v)) {
            try self.inst(0xF1000000 | (@as(u32, @intCast(v)) << 10) | (ra << 5) | XZR); // subs xzr,a,#v
        } else if (v < 0 and -v < 4096) {
            try self.inst(0xB1000000 | (@as(u32, @intCast(-v)) << 10) | (ra << 5) | XZR); // cmn a,#-v
        } else {
            try self.movImmRaw(TMP_ADDR, @bitCast(@as(i64, v)));
            try self.inst(0xEB000000 | (TMP_ADDR << 16) | (ra << 5) | XZR); // subs xzr,a,tmp
        }
    }

    // --- signed divide / remainder -----------------------------------------

    /// x86 sign-extends rax into rdx:rax; AArch64 `sdiv` needs no setup.
    pub fn cqo(self: *Emitter) JitError!void {
        _ = self;
    }
    /// Quotient of T0(rax/x9) by `src`, leaving quotient in T0 and remainder in
    /// T2(rdx/x11) — the exact post-idiv register contract the compiler reads.
    pub fn idivReg(self: *Emitter, src: Reg) JitError!void {
        const dividend: u32 = gp(.rax);
        const divisor: u32 = gp(src);
        const rem: u32 = gp(.rdx);
        // sdiv x12, dividend, divisor
        try self.inst(0x9AC00C00 | (divisor << 16) | (dividend << 5) | TMP_DIV);
        // msub rem, x12, divisor, dividend   (rem = dividend - x12*divisor)
        try self.inst(0x9B008000 | (divisor << 16) | (dividend << 10) | (TMP_DIV << 5) | rem);
        // mov dividend(=T0), x12   (quotient)
        try self.inst(0xAA0003E0 | (TMP_DIV << 16) | dividend);
    }

    // --- shifts (count in rcx/x10) -----------------------------------------

    fn shiftBy(self: *Emitter, dst: Reg, op2: u32, w64: bool) JitError!void {
        const base: u32 = if (w64) 0x9AC00000 else 0x1AC00000;
        const d = gp(dst);
        try self.inst(base | op2 | (gp(.rcx) << 16) | (d << 5) | d);
    }
    pub fn shlCl(self: *Emitter, dst: Reg, w64: bool) JitError!void {
        try self.shiftBy(dst, 0x2000, w64); // lslv
    }
    pub fn sarCl(self: *Emitter, dst: Reg, w64: bool) JitError!void {
        try self.shiftBy(dst, 0x2800, w64); // asrv
    }
    pub fn shrCl(self: *Emitter, dst: Reg, w64: bool) JitError!void {
        try self.shiftBy(dst, 0x2400, w64); // lsrv
    }

    // --- memory (base + disp) ----------------------------------------------

    /// Effective-address load/store with a 12-bit scaled unsigned offset when
    /// the displacement fits, else a materialized register offset.
    fn memScaled(self: *Emitter, op_uoff: u32, op_roff: u32, t: u32, base: Reg, disp: i32, scale_log2: u5) JitError!void {
        const n = gp(base);
        const scale: i32 = @as(i32, 1) << scale_log2;
        if (disp >= 0 and @rem(disp, scale) == 0 and (@as(u32, @intCast(disp)) >> scale_log2) < 4096) {
            const imm12: u32 = @as(u32, @intCast(disp)) >> scale_log2;
            try self.inst(op_uoff | (imm12 << 10) | (n << 5) | t);
        } else {
            try self.movImmRaw(TMP_ADDR, @bitCast(@as(i64, disp)));
            try self.inst(op_roff | (TMP_ADDR << 16) | (n << 5) | t);
        }
    }

    pub fn loadMem(self: *Emitter, dst: Reg, base: Reg, disp: i32) JitError!void {
        try self.memScaled(0xF9400000, 0xF8606800, gp(dst), base, disp, 3); // ldr x
    }
    pub fn storeMem(self: *Emitter, base: Reg, disp: i32, src: Reg) JitError!void {
        try self.memScaled(0xF9000000, 0xF8206800, gp(src), base, disp, 3); // str x
    }
    pub fn loadMemB(self: *Emitter, dst: Reg, base: Reg, disp: i32) JitError!void {
        try self.memScaled(0x39400000, 0x38606800, gp(dst), base, disp, 0); // ldrb w (zero-ext)
    }
    pub fn storeMemBImm(self: *Emitter, base: Reg, disp: i32, v: u8) JitError!void {
        try self.movImmRaw(TMP_DIV, v); // strb source byte
        try self.memScaled(0x39000000, 0x38206800, TMP_DIV, base, disp, 0); // strb w
    }

    // --- stack (REGS + LR pairing) -----------------------------------------

    /// Saves `r` together with the link register so a trampoline `blr` in the
    /// body is transparent: `pop` restores LR before `ret`.
    pub fn push(self: *Emitter, r: Reg) JitError!void {
        // stp r, lr, [sp, #-16]!   (pre-index, imm7 = -2)
        try self.inst(0xA9800000 | (0x7E << 15) | (LR << 10) | (SP << 5) | gp(r));
    }
    pub fn pop(self: *Emitter, r: Reg) JitError!void {
        // ldp r, lr, [sp], #16     (post-index, imm7 = 2)
        try self.inst(0xA8C00000 | (0x02 << 15) | (LR << 10) | (SP << 5) | gp(r));
    }

    // --- return / indirect call --------------------------------------------

    pub fn ret(self: *Emitter) JitError!void {
        // mov x0, <rax-role>  (reconcile to the AAPCS return register)
        try self.inst(0xAA0003E0 | (gp(.rax) << 16) | 0);
        try self.inst(0xD65F03C0); // ret
    }
    /// `blr target`, then move the AAPCS return value (x0) into the rax-role so
    /// the compiler's post-call `testReg(.rax, .rax)` sees the trampoline result.
    pub fn callReg(self: *Emitter, target: Reg) JitError!void {
        try self.inst(0xD63F0000 | (gp(target) << 5));
        try self.inst(0xAA0003E0 | (0 << 16) | gp(.rax)); // mov rax, x0
    }

    // --- setcc -------------------------------------------------------------

    pub fn setccReg(self: *Emitter, cc: SetCc, reg: Reg) JitError!void {
        // cset reg, cc  ==  csinc reg, xzr, xzr, invert(cc)
        const inv = setCode(cc) ^ 1;
        try self.inst(0x9A9F07E0 | (inv << 12) | gp(reg));
    }

    // --- SIMD / float ------------------------------------------------------

    fn fpMem(self: *Emitter, op_uoff: u32, op_roff: u32, t: u32, base: Reg, disp: i32, scale_log2: u5) JitError!void {
        try self.memScaled(op_uoff, op_roff, t, base, disp, scale_log2);
    }
    pub fn movsdLoad(self: *Emitter, dst: Xmm, base: Reg, disp: i32) JitError!void {
        try self.fpMem(0xFD400000, 0xFC606800, fp(dst), base, disp, 3); // ldr d
    }
    pub fn movsdStore(self: *Emitter, base: Reg, disp: i32, src: Xmm) JitError!void {
        try self.fpMem(0xFD000000, 0xFC206800, fp(src), base, disp, 3); // str d
    }
    pub fn movssLoad(self: *Emitter, dst: Xmm, base: Reg, disp: i32) JitError!void {
        try self.fpMem(0xBD400000, 0xBC606800, fp(dst), base, disp, 2); // ldr s
    }
    pub fn movssStore(self: *Emitter, base: Reg, disp: i32, src: Xmm) JitError!void {
        try self.fpMem(0xBD000000, 0xBC206800, fp(src), base, disp, 2); // str s
    }

    fn fpRRR(self: *Emitter, op: u32, dst: Xmm, src: Xmm) JitError!void {
        try self.inst(op | (fp(src) << 16) | (fp(dst) << 5) | fp(dst));
    }
    pub fn addsd(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.fpRRR(0x1E602800, dst, src);
    }
    pub fn subsd(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.fpRRR(0x1E603800, dst, src);
    }
    pub fn mulsd(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.fpRRR(0x1E600800, dst, src);
    }
    pub fn divsd(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.fpRRR(0x1E601800, dst, src);
    }
    pub fn addss(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.fpRRR(0x1E202800, dst, src);
    }
    pub fn subss(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.fpRRR(0x1E203800, dst, src);
    }
    pub fn mulss(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.fpRRR(0x1E200800, dst, src);
    }
    pub fn divss(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.fpRRR(0x1E201800, dst, src);
    }
    /// `fcmp dst, src` — sets NZCV (V=1 on unordered) for the cond mapping.
    pub fn ucomisd(self: *Emitter, a: Xmm, b: Xmm) JitError!void {
        try self.inst(0x1E602000 | (fp(b) << 16) | (fp(a) << 5));
    }
    pub fn ucomiss(self: *Emitter, a: Xmm, b: Xmm) JitError!void {
        try self.inst(0x1E202000 | (fp(b) << 16) | (fp(a) << 5));
    }
    /// `eor Vd.8B, Vn.8B, Vm.8B` — zeroes the register when dst==src.
    pub fn xorps(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        try self.inst(0x2E201C00 | (fp(src) << 16) | (fp(dst) << 5) | fp(dst));
    }
    pub fn cvtss2sd(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        // fcvt d, s
        try self.inst(0x1E22C000 | (fp(src) << 5) | fp(dst));
    }
    pub fn cvtsd2ss(self: *Emitter, dst: Xmm, src: Xmm) JitError!void {
        // fcvt s, d
        try self.inst(0x1E624000 | (fp(src) << 5) | fp(dst));
    }
    pub fn cvtsi2sd(self: *Emitter, dst: Xmm, src: Reg) JitError!void {
        // scvtf d, x
        try self.inst(0x9E620000 | (gp(src) << 5) | fp(dst));
    }
    pub fn cvtsi2ss(self: *Emitter, dst: Xmm, src: Reg) JitError!void {
        // scvtf s, x
        try self.inst(0x9E220000 | (gp(src) << 5) | fp(dst));
    }
    pub fn cvttsd2si(self: *Emitter, dst: Reg, src: Xmm) JitError!void {
        // fcvtzs x, d  (truncate toward zero; NaN->0, overflow saturates)
        try self.inst(0x9E780000 | (fp(src) << 5) | gp(dst));
    }
    pub fn cvttss2si(self: *Emitter, dst: Reg, src: Xmm) JitError!void {
        // fcvtzs x, s
        try self.inst(0x9E380000 | (fp(src) << 5) | gp(dst));
    }

    // --- array element access [base + index*scale] -------------------------

    fn elemLog2(w: ElemW) u5 {
        return switch (w) {
            .b8s, .b8u => 0,
            .b16s, .b16u => 1,
            .b32s, .b32u => 2,
            .b64 => 3,
        };
    }
    /// `[base + index, lsl #log2(scale)]` register-offset addressing. `scale`
    /// from the compiler always equals the element size, matching AArch64's
    /// scaled-register-offset requirement (shift amount = access-size log2).
    pub fn loadSib(self: *Emitter, dst: Reg, base: Reg, index: Reg, scale: u8, w: ElemW) JitError!void {
        _ = scale;
        const sh: u32 = elemLog2(w);
        const opc: u32 = switch (w) {
            .b8u => 0x38606800, // ldrb w
            .b8s => 0x38E06800, // ldrsb x
            .b16u => 0x78606800, // ldrh w
            .b16s => 0x78E06800, // ldrsh x
            .b32u => 0xB8606800, // ldr w (zero-ext)
            .b32s => 0xB8A06800, // ldrsw x
            .b64 => 0xF8606800, // ldr x
        };
        // S bit (bit 12) scales the index by the access size.
        const s: u32 = if (sh != 0) (1 << 12) else 0;
        try self.inst(opc | s | (gp(index) << 16) | (gp(base) << 5) | gp(dst));
    }
    pub fn storeSib(self: *Emitter, base: Reg, index: Reg, scale: u8, src: Reg, w: ElemW) JitError!void {
        _ = scale;
        const sh: u32 = elemLog2(w);
        const opc: u32 = switch (w) {
            .b8s, .b8u => 0x38206800, // strb w
            .b16s, .b16u => 0x78206800, // strh w
            .b32s, .b32u => 0xB8206800, // str w
            .b64 => 0xF8206800, // str x
        };
        const s: u32 = if (sh != 0) (1 << 12) else 0;
        try self.inst(opc | s | (gp(index) << 16) | (gp(base) << 5) | gp(src));
    }

    // --- labels & branches -------------------------------------------------

    pub fn newLabel(self: *Emitter) JitError!Label {
        self.labels.append(self.a, null) catch return JitError.OutOfMemory;
        return self.labels.items.len - 1;
    }

    pub fn bind(self: *Emitter, l: Label) JitError!void {
        const pos = self.buf.items.len;
        self.labels.items[l] = pos;
        var i: usize = 0;
        while (i < self.fixups.items.len) {
            const f = self.fixups.items[i];
            if (f.target == l) {
                self.patch(f, pos);
                _ = self.fixups.swapRemove(i);
            } else i += 1;
        }
    }

    fn patch(self: *Emitter, f: Fixup, target: usize) void {
        const rel: i64 = @as(i64, @intCast(target)) - @as(i64, @intCast(f.at));
        const words: i64 = @divExact(rel, 4);
        var cur = std.mem.readInt(u32, self.buf.items[f.at..][0..4], .little);
        if (f.wide) {
            const imm26: u32 = @as(u32, @bitCast(@as(i32, @intCast(words)))) & 0x03FF_FFFF;
            cur = (cur & 0xFC00_0000) | imm26;
        } else {
            const imm19: u32 = @as(u32, @bitCast(@as(i32, @intCast(words)))) & 0x7_FFFF;
            cur = (cur & 0xFF00_001F) | (imm19 << 5);
        }
        std.mem.writeInt(u32, self.buf.items[f.at..][0..4], cur, .little);
    }

    fn branchRel(self: *Emitter, wide: bool, l: Label, word: u32) JitError!void {
        const at = self.buf.items.len;
        if (self.labels.items[l]) |tgt| {
            try self.inst(word);
            self.patch(.{ .at = at, .wide = wide, .target = l }, tgt);
        } else {
            self.fixups.append(self.a, .{ .at = at, .wide = wide, .target = l }) catch return JitError.OutOfMemory;
            try self.inst(word);
        }
    }
    pub fn jmp(self: *Emitter, l: Label) JitError!void {
        try self.branchRel(true, l, 0x14000000); // b
    }
    pub fn jcc(self: *Emitter, cc: Cond, l: Label) JitError!void {
        try self.branchRel(false, l, 0x54000000 | condCode(cc)); // b.cond
    }
};

// --- tests (execute natively; the host must be aarch64) ----------------------

const builtin = @import("builtin");
const testing = std.testing;
const arch_ok = builtin.cpu.arch == .aarch64;

fn run0(em: *Emitter, comptime Fn: type) !Fn {
    const buf = try root.finalize(em.code());
    return buf.entry(Fn);
}

test "arm64: constant return" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    try em.movImm64(.rax, 42);
    try em.ret();
    const f = try run0(&em, *const fn () callconv(.c) i64);
    try testing.expectEqual(@as(i64, 42), f());
}

test "arm64: add/sub/mul/neg of args (rdi,rsi)" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    // rax = ((a - b) * b); a=rdi, b=rsi
    try em.movReg(.rax, .rdi);
    try em.subReg(.rax, .rsi);
    try em.imulReg(.rax, .rsi);
    try em.ret();
    const f = try run0(&em, *const fn (i64, i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, (10 - 3) * 3), f(10, 3));
    try testing.expectEqual(@as(i64, (100 - 7) * 7), f(100, 7));

    var em2 = Emitter.init(testing.allocator);
    defer em2.deinit();
    try em2.movReg(.rax, .rdi);
    try em2.negReg(.rax);
    try em2.ret();
    const g = try run0(&em2, *const fn (i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, -5), g(5));
    try testing.expectEqual(@as(i64, 7), g(-7));
}

test "arm64: bitwise and/or/xor + movImm64 wide" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    try em.movImm64(.rax, 0xDEAD_BEEF_CAFE_F00D);
    try em.movImm64(.rcx, 0x0F0F_0F0F_0F0F_0F0F);
    try em.andReg(.rax, .rcx);
    try em.ret();
    const f = try run0(&em, *const fn () callconv(.c) u64);
    try testing.expectEqual(@as(u64, 0x0E0D_0E0F_0A0E_000D), f());
}

test "arm64: counted loop (labels + jcc + jmp)" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    // f(n=rdi) = sum(0..n-1)
    try em.movImm64(.rax, 0);
    try em.movImm64(.rcx, 0);
    const top = try em.newLabel();
    const end = try em.newLabel();
    try em.bind(top);
    try em.cmpReg(.rcx, .rdi);
    try em.jcc(.ge, end);
    try em.addReg(.rax, .rcx);
    try em.addImm32(.rcx, 1);
    try em.jmp(top);
    try em.bind(end);
    try em.ret();
    const f = try run0(&em, *const fn (i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 4950), f(100));
    try testing.expectEqual(@as(i64, 0), f(0));
    try testing.expectEqual(@as(i64, 499999500000), f(1000000));
}

test "arm64: memory load/store through base" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    try em.loadMem(.rax, .rdi, 8);
    try em.addImm32(.rax, 5);
    try em.storeMem(.rdi, 8, .rax);
    try em.ret();
    const f = try run0(&em, *const fn (*[2]i64) callconv(.c) i64);
    var arr = [_]i64{ 111, 37 };
    try testing.expectEqual(@as(i64, 42), f(&arr));
    try testing.expectEqual(@as(i64, 42), arr[1]);
    try testing.expectEqual(@as(i64, 111), arr[0]);
}

test "arm64: setcc from comparison" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    try em.cmpReg(.rdi, .rsi);
    try em.setccReg(.l, .rax); // (a < b) signed
    try em.ret();
    const f = try run0(&em, *const fn (i64, i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 1), f(3, 4));
    try testing.expectEqual(@as(i64, 0), f(4, 3));
    try testing.expectEqual(@as(i64, 0), f(5, 5));
    try testing.expectEqual(@as(i64, 1), f(-9, -1));
}

test "arm64: movsxd normalizes 32-bit overflow" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    try em.movReg(.rax, .rdi);
    try em.addReg(.rax, .rdi);
    try em.movsxd(.rax, .rax);
    try em.ret();
    const f = try run0(&em, *const fn (i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, -294967296), f(2_000_000_000));
}

test "arm64: shifts by cl (rcx), 32- and 64-bit" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    // (a << b) 64-bit ; a=rdi, b=rcx<-rsi
    try em.movReg(.rax, .rdi);
    try em.movReg(.rcx, .rsi);
    try em.shlCl(.rax, true);
    try em.ret();
    const f = try run0(&em, *const fn (i64, i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 1 << 10), f(1, 10));
    try testing.expectEqual(@as(i64, 40), f(5, 3));

    var em2 = Emitter.init(testing.allocator);
    defer em2.deinit();
    // (a >> b) 32-bit arithmetic
    try em2.movReg(.rax, .rdi);
    try em2.movReg(.rcx, .rsi);
    try em2.sarCl(.rax, false);
    try em2.ret();
    const g = try run0(&em2, *const fn (i64, i64) callconv(.c) u64);
    // 32-bit asr yields the 32-bit result zero-extended into the 64-bit reg,
    // matching x86's 32-bit-op upper-clear; the caller sign-extends if needed.
    try testing.expectEqual(@as(u64, 0xFFFF_FFFC), g(-16, 2));
    try testing.expectEqual(@as(u64, 5), g(20, 2));
}

test "arm64: signed divide and remainder (idiv contract)" {
    if (!arch_ok) return error.SkipZigTest;
    // quotient: dividend T0(rax)<-rdi, divisor T1(rcx)<-rsi
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    try em.movReg(.rax, .rdi);
    try em.movReg(.rcx, .rsi);
    try em.cqo();
    try em.idivReg(.rcx);
    try em.ret();
    const q = try run0(&em, *const fn (i64, i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 7), q(47, 6));
    try testing.expectEqual(@as(i64, -7), q(-47, 6));
    try testing.expectEqual(@as(i64, 0), q(5, 6));

    // remainder is left in T2(rdx); read it back
    var em2 = Emitter.init(testing.allocator);
    defer em2.deinit();
    try em2.movReg(.rax, .rdi);
    try em2.movReg(.rcx, .rsi);
    try em2.cqo();
    try em2.idivReg(.rcx);
    try em2.movReg(.rax, .rdx);
    try em2.ret();
    const r = try run0(&em2, *const fn (i64, i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 5), r(47, 6));
    try testing.expectEqual(@as(i64, -5), r(-47, 6));
}

test "arm64: SIB byte + scaled-word array access" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    // buf[i]=1 (byte), return buf[i]; buf=rdi, i=rsi
    try em.movImm64(.rax, 1);
    try em.storeSib(.rdi, .rsi, 1, .rax, .b8u);
    try em.loadSib(.rax, .rdi, .rsi, 1, .b8u);
    try em.ret();
    const f = try run0(&em, *const fn ([*]u8, i64) callconv(.c) i64);
    var arr = [_]u8{ 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(i64, 1), f(&arr, 3));
    try testing.expectEqual(@as(u8, 1), arr[3]);
    try testing.expectEqual(@as(u8, 0), arr[2]);

    var em2 = Emitter.init(testing.allocator);
    defer em2.deinit();
    try em2.loadSib(.rax, .rdi, .rsi, 4, .b32s); // sign-extend i32, scale 4
    try em2.ret();
    const g = try run0(&em2, *const fn ([*]i32, i64) callconv(.c) i64);
    var arr2 = [_]i32{ 10, -7, 999 };
    try testing.expectEqual(@as(i64, -7), g(&arr2, 1));
    try testing.expectEqual(@as(i64, 999), g(&arr2, 2));
}

test "arm64: double arithmetic over a slot file" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    // fn(rdi=*[2]f64) -> f64 : s0*s1 + s0
    try em.push(.rbx);
    try em.movReg(.rbx, .rdi);
    try em.movsdLoad(.xmm0, .rbx, 0);
    try em.movsdLoad(.xmm1, .rbx, 8);
    try em.mulsd(.xmm0, .xmm1);
    try em.movsdLoad(.xmm1, .rbx, 0);
    try em.addsd(.xmm0, .xmm1);
    try em.pop(.rbx);
    try em.ret();
    const f = try run0(&em, *const fn ([*]f64) callconv(.c) f64);
    var slots = [_]f64{ 3.0, 4.0 };
    try testing.expectEqual(@as(f64, 15.0), f(&slots));
    slots = .{ 2.5, -2.0 };
    try testing.expectEqual(@as(f64, -2.5), f(&slots));
}

test "arm64: f32 arithmetic over a slot file" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    try em.push(.rbx);
    try em.movReg(.rbx, .rdi);
    try em.movssLoad(.xmm0, .rbx, 0);
    try em.movssLoad(.xmm1, .rbx, 8);
    try em.mulss(.xmm0, .xmm1);
    try em.movssLoad(.xmm1, .rbx, 0);
    try em.addss(.xmm0, .xmm1);
    try em.pop(.rbx);
    try em.ret();
    const f = try run0(&em, *const fn ([*]i64) callconv(.c) f32);
    var slots = [_]i64{ @as(u32, @bitCast(@as(f32, 3.0))), @as(u32, @bitCast(@as(f32, 4.0))) };
    try testing.expectEqual(@as(f32, 15.0), f(&slots));
}

test "arm64: int<->double conversions" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    try em.cvtsi2sd(.xmm0, .rdi);
    try em.cvttsd2si(.rax, .xmm0);
    try em.ret();
    const f = try run0(&em, *const fn (i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 42), f(42));
    try testing.expectEqual(@as(i64, -7), f(-7));
}

test "arm64: float compare with NaN semantics (Less/Eq/NotEq)" {
    if (!arch_ok) return error.SkipZigTest;
    // Mirror the loop compiler's float-Less lowering: ucomi(rhs,lhs); seta.
    const less = struct {
        fn build(em: *Emitter) !void {
            try em.push(.rbx);
            try em.movReg(.rbx, .rdi);
            try em.movsdLoad(.xmm0, .rbx, 0); // a
            try em.movsdLoad(.xmm1, .rbx, 8); // b
            // a<b: ucomi(b,a); seta
            try em.ucomisd(.xmm1, .xmm0);
            try em.setccReg(.a, .rax);
            try em.pop(.rbx);
            try em.ret();
        }
    };
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    try less.build(&em);
    const lt = try run0(&em, *const fn ([*]f64) callconv(.c) i64);
    var s = [_]f64{ 1.0, 2.0 };
    try testing.expectEqual(@as(i64, 1), lt(&s));
    s = .{ 2.0, 1.0 };
    try testing.expectEqual(@as(i64, 0), lt(&s));
    s = .{ 1.0, 1.0 };
    try testing.expectEqual(@as(i64, 0), lt(&s));
    const nan = std.math.nan(f64);
    s = .{ nan, 1.0 };
    try testing.expectEqual(@as(i64, 0), lt(&s)); // NaN<x is false
    s = .{ 1.0, nan };
    try testing.expectEqual(@as(i64, 0), lt(&s));

    // Eq: ucomi(a,b); sete & setnp
    var eqm = Emitter.init(testing.allocator);
    defer eqm.deinit();
    try eqm.push(.rbx);
    try eqm.movReg(.rbx, .rdi);
    try eqm.movsdLoad(.xmm0, .rbx, 0);
    try eqm.movsdLoad(.xmm1, .rbx, 8);
    try eqm.ucomisd(.xmm0, .xmm1);
    try eqm.setccReg(.e, .rax);
    try eqm.setccReg(.np, .rcx);
    try eqm.andReg(.rax, .rcx);
    try eqm.pop(.rbx);
    try eqm.ret();
    const eq = try run0(&eqm, *const fn ([*]f64) callconv(.c) i64);
    s = .{ 1.0, 1.0 };
    try testing.expectEqual(@as(i64, 1), eq(&s));
    s = .{ 1.0, 2.0 };
    try testing.expectEqual(@as(i64, 0), eq(&s));
    s = .{ nan, nan };
    try testing.expectEqual(@as(i64, 0), eq(&s)); // NaN==NaN is false

    // NotEq: ucomi(a,b); setne | setp
    var nem = Emitter.init(testing.allocator);
    defer nem.deinit();
    try nem.push(.rbx);
    try nem.movReg(.rbx, .rdi);
    try nem.movsdLoad(.xmm0, .rbx, 0);
    try nem.movsdLoad(.xmm1, .rbx, 8);
    try nem.ucomisd(.xmm0, .xmm1);
    try nem.setccReg(.ne, .rax);
    try nem.setccReg(.p, .rcx);
    try nem.orReg(.rax, .rcx);
    try nem.pop(.rbx);
    try nem.ret();
    const ne = try run0(&nem, *const fn ([*]f64) callconv(.c) i64);
    s = .{ 1.0, 2.0 };
    try testing.expectEqual(@as(i64, 1), ne(&s));
    s = .{ 1.0, 1.0 };
    try testing.expectEqual(@as(i64, 0), ne(&s));
    s = .{ nan, 1.0 };
    try testing.expectEqual(@as(i64, 1), ne(&s)); // NaN!=x is true
}

fn tramp99(user: *anyopaque, site: u64) callconv(.c) u64 {
    _ = user;
    _ = site;
    return 99;
}

test "arm64: indirect call (blr) with LR pairing + return reconcile" {
    if (!arch_ok) return error.SkipZigTest;
    var em = Emitter.init(testing.allocator);
    defer em.deinit();
    try em.push(.rbx); // saves x19 + lr
    try em.movReg(.rbx, .rdi);
    try em.movImm64(.rdi, 0); // arg0
    try em.movImm64(.rsi, 7); // arg1 (site)
    try em.movImm64(.rax, @intFromPtr(&tramp99));
    try em.callReg(.rax); // rax := callee return (99)
    try em.pop(.rbx); // restores lr
    try em.ret(); // returns rax via x0
    const f = try run0(&em, *const fn (usize) callconv(.c) u64);
    try testing.expectEqual(@as(u64, 99), f(0));
}
