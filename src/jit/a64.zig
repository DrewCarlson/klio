//! An AArch64 assembler: each method appends one instruction (or a short
//! fixed sequence) to a word buffer. Branches to labels and loads of 64-bit
//! literals are resolved by `finish`, which places the literal pool after the
//! code, so the result is position independent.

const std = @import("std");

pub const Error = error{ OutOfMemory, OutOfRange, NotEncodable };

/// A general register. Encoding 31 is the zero register in most operand
/// positions and the stack pointer in an address or an immediate add's.
pub const Reg = enum(u5) {
    x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15,
    x16, x17, x18, x19, x20, x21, x22, x23, x24, x25, x26, x27, x28, x29, x30, zr,

    fn n(r: Reg) u32 {
        return @intFromEnum(r);
    }
};

/// Register 31 in an address or an immediate add: the stack pointer.
pub const sp: Reg = .zr;
pub const fp: Reg = .x29;
pub const lr: Reg = .x30;

/// A floating-point register.
pub const V = enum(u5) {
    v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15,
    v16, v17, v18, v19, v20, v21, v22, v23, v24, v25, v26, v27, v28, v29, v30, v31,

    fn n(r: V) u32 {
        return @intFromEnum(r);
    }
};

/// Operand width: `w` 32 bits, `x` 64.
pub const W = enum(u1) {
    w,
    x,

    fn sf(w: W) u32 {
        return @as(u32, @intFromEnum(w)) << 31;
    }
    fn bits(w: W) u32 {
        return if (w == .x) 64 else 32;
    }
};

/// Floating-point width: `s` single, `d` double.
pub const F = enum { s, d };

pub const Cond = enum(u4) {
    eq, ne, hs, lo, mi, pl, vs, vc, hi, ls, ge, lt, gt, le, al, nv,

    pub fn invert(c: Cond) Cond {
        return @enumFromInt(@intFromEnum(c) ^ 1);
    }
};

pub const Shift = enum(u2) { lsl, lsr, asr, ror };

/// A memory access's size, and for a load whether it sign-extends and to
/// which width.
pub const Size = enum { b, h, w, x, sb_w, sh_w, sb_x, sh_x, sw_x };

pub const Label = u32;

pub const Barrier = enum(u4) { ishld = 0b1001, ishst = 0b1010, ish = 0b1011, sy = 0b1111 };

const Fixup = struct { at: u32, label: Label, kind: enum { b26, b19, b14, adr } };
const Lit = struct { at: u32, value: u64 };

pub const Asm = struct {
    gpa: std.mem.Allocator,
    /// The current section's words; `other` holds the other section's.
    words: std.ArrayList(u32) = .empty,
    other: std.ArrayList(u32) = .empty,
    /// Whether the current section is the cold one, which `finish` places
    /// after the hot one, so code rarely run stays out of the way of code
    /// that is.
    cold: bool = false,
    labels: std.ArrayList(?u32) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    lits: std.ArrayList(Lit) = .empty,

    /// Marks a position in the cold section until `finish` places it.
    const cold_bit: u32 = 1 << 31;

    pub fn init(gpa: std.mem.Allocator) Asm {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Asm) void {
        self.words.deinit(self.gpa);
        self.other.deinit(self.gpa);
        self.labels.deinit(self.gpa);
        self.fixups.deinit(self.gpa);
        self.lits.deinit(self.gpa);
    }

    /// Words emitted so far in the current section.
    pub fn pos(self: *const Asm) u32 {
        return @intCast(self.words.items.len);
    }

    /// The current position, marked with its section.
    fn here(self: *const Asm) u32 {
        return self.pos() | if (self.cold) cold_bit else 0;
    }

    /// Later words go to the cold section, or back to the hot one.
    pub fn section(self: *Asm, cold: bool) void {
        if (cold == self.cold) return;
        std.mem.swap(std.ArrayList(u32), &self.words, &self.other);
        self.cold = cold;
    }

    pub fn emit(self: *Asm, w: u32) Error!void {
        try self.words.append(self.gpa, w);
    }

    pub fn newLabel(self: *Asm) Error!Label {
        try self.labels.append(self.gpa, null);
        return @intCast(self.labels.items.len - 1);
    }

    pub fn bind(self: *Asm, l: Label) void {
        self.labels.items[l] = self.here();
    }

    pub fn isBound(self: *const Asm, l: Label) bool {
        return self.labels.items[l] != null;
    }

    /// Byte offset of a bound label from the start of the code.
    pub fn labelOffset(self: *const Asm, l: Label) ?u32 {
        const p = self.labels.items[l] orelse return null;
        if (p & cold_bit != 0) return null;
        return p * 4;
    }

    /// The code and its literal pool, labels and literals resolved. The
    /// caller owns the bytes.
    pub fn finish(self: *Asm) Error![]u8 {
        // The cold section after the hot one.
        self.section(false);
        const hot_len = self.pos();
        try self.words.appendSlice(self.gpa, self.other.items);
        self.other.clearRetainingCapacity();
        for (self.labels.items) |*l| if (l.*) |p| {
            l.* = place(p, hot_len);
        };
        for (self.fixups.items) |*f| f.at = place(f.at, hot_len);
        for (self.lits.items) |*l| l.at = place(l.at, hot_len);
        for (self.fixups.items) |f| {
            const target = self.labels.items[f.label] orelse return Error.OutOfRange;
            const off: i64 = @as(i64, target) - @as(i64, f.at);
            const w = &self.words.items[f.at];
            switch (f.kind) {
                .b26 => w.* |= try field(off, 26, 0),
                .b19 => w.* |= try field(off, 19, 5),
                .b14 => w.* |= try field(off, 14, 5),
                .adr => {
                    const byte_off = off * 4;
                    if (byte_off < -(1 << 20) or byte_off >= (1 << 20)) return Error.OutOfRange;
                    const u: u32 = @bitCast(@as(i32, @intCast(byte_off)));
                    w.* |= ((u & 3) << 29) | (((u >> 2) & 0x7FFFF) << 5);
                },
            }
        }
        // The pool: 8-byte aligned, one slot per distinct value.
        if (self.lits.items.len != 0) {
            if (self.pos() % 2 != 0) try self.emit(nop_word);
            var seen: std.AutoHashMapUnmanaged(u64, u32) = .empty;
            defer seen.deinit(self.gpa);
            for (self.lits.items) |l| {
                const slot = (try seen.getOrPut(self.gpa, l.value));
                if (!slot.found_existing) {
                    slot.value_ptr.* = self.pos();
                    try self.emit(@truncate(l.value));
                    try self.emit(@truncate(l.value >> 32));
                }
                const off: i64 = @as(i64, slot.value_ptr.*) - @as(i64, l.at);
                self.words.items[l.at] |= try field(off, 19, 5);
            }
        }
        const out = try self.gpa.alloc(u8, self.words.items.len * 4);
        for (self.words.items, 0..) |w, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], w, .little);
        return out;
    }

    /// Where position `p` of either section ends up, the hot section `hot_len` words long.
    fn place(p: u32, hot_len: u32) u32 {
        return if (p & cold_bit != 0) (p & ~cold_bit) + hot_len else p;
    }

    fn ref(self: *Asm, l: Label, kind: @FieldType(Fixup, "kind"), w: u32) Error!void {
        try self.fixups.append(self.gpa, .{ .at = self.here(), .label = l, .kind = kind });
        try self.emit(w);
    }

    // ---------------------------------------------------------- arithmetic --

    fn addSubImm(self: *Asm, base: u32, w: W, rd: Reg, rn: Reg, imm: u32) Error!void {
        if (imm < 4096) return self.emit(w.sf() | base | (imm << 10) | (rn.n() << 5) | rd.n());
        if (imm & 0xFFF == 0 and imm >> 12 < 4096) return self.emit(w.sf() | base | (1 << 22) | ((imm >> 12) << 10) | (rn.n() << 5) | rd.n());
        return Error.NotEncodable;
    }

    /// `rd = rn + imm`, imm a 12-bit value or one shifted left 12; either
    /// register may be `sp`.
    pub fn addImm(self: *Asm, w: W, rd: Reg, rn: Reg, imm: u32) Error!void {
        return self.addSubImm(0x11000000, w, rd, rn, imm);
    }
    pub fn subImm(self: *Asm, w: W, rd: Reg, rn: Reg, imm: u32) Error!void {
        return self.addSubImm(0x51000000, w, rd, rn, imm);
    }
    pub fn addsImm(self: *Asm, w: W, rd: Reg, rn: Reg, imm: u32) Error!void {
        return self.addSubImm(0x31000000, w, rd, rn, imm);
    }
    pub fn subsImm(self: *Asm, w: W, rd: Reg, rn: Reg, imm: u32) Error!void {
        return self.addSubImm(0x71000000, w, rd, rn, imm);
    }
    pub fn cmpImm(self: *Asm, w: W, rn: Reg, imm: u32) Error!void {
        return self.subsImm(w, .zr, rn, imm);
    }
    pub fn cmnImm(self: *Asm, w: W, rn: Reg, imm: u32) Error!void {
        return self.addsImm(w, .zr, rn, imm);
    }

    fn shiftedReg(self: *Asm, base: u32, w: W, rd: Reg, rn: Reg, rm: Reg, sh: Shift, amount: u6) Error!void {
        if (amount >= w.bits()) return Error.NotEncodable;
        return self.emit(w.sf() | base | (@as(u32, @intFromEnum(sh)) << 22) | (rm.n() << 16) | (@as(u32, amount) << 10) | (rn.n() << 5) | rd.n());
    }

    pub fn add(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.shiftedReg(0x0B000000, w, rd, rn, rm, .lsl, 0);
    }
    pub fn addShifted(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg, sh: Shift, amount: u6) Error!void {
        return self.shiftedReg(0x0B000000, w, rd, rn, rm, sh, amount);
    }
    pub fn sub(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.shiftedReg(0x4B000000, w, rd, rn, rm, .lsl, 0);
    }
    pub fn adds(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.shiftedReg(0x2B000000, w, rd, rn, rm, .lsl, 0);
    }
    pub fn subs(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.shiftedReg(0x6B000000, w, rd, rn, rm, .lsl, 0);
    }
    pub fn cmp(self: *Asm, w: W, rn: Reg, rm: Reg) Error!void {
        return self.subs(w, .zr, rn, rm);
    }
    pub fn neg(self: *Asm, w: W, rd: Reg, rm: Reg) Error!void {
        return self.sub(w, rd, .zr, rm);
    }
    pub fn negs(self: *Asm, w: W, rd: Reg, rm: Reg) Error!void {
        return self.subs(w, rd, .zr, rm);
    }

    pub fn @"and"(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.shiftedReg(0x0A000000, w, rd, rn, rm, .lsl, 0);
    }
    pub fn orr(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.shiftedReg(0x2A000000, w, rd, rn, rm, .lsl, 0);
    }
    pub fn orrShifted(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg, sh: Shift, amount: u6) Error!void {
        return self.shiftedReg(0x2A000000, w, rd, rn, rm, sh, amount);
    }
    pub fn eor(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.shiftedReg(0x4A000000, w, rd, rn, rm, .lsl, 0);
    }
    pub fn ands(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.shiftedReg(0x6A000000, w, rd, rn, rm, .lsl, 0);
    }
    pub fn bic(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.shiftedReg(0x0A200000, w, rd, rn, rm, .lsl, 0);
    }
    pub fn orn(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.shiftedReg(0x2A200000, w, rd, rn, rm, .lsl, 0);
    }
    pub fn tst(self: *Asm, w: W, rn: Reg, rm: Reg) Error!void {
        return self.ands(w, .zr, rn, rm);
    }
    /// `rd = rm` (not for `sp`: use `addImm(rd, sp, 0)`).
    pub fn mov(self: *Asm, w: W, rd: Reg, rm: Reg) Error!void {
        return self.orr(w, rd, .zr, rm);
    }
    pub fn mvn(self: *Asm, w: W, rd: Reg, rm: Reg) Error!void {
        return self.orn(w, rd, .zr, rm);
    }

    fn logicalImm(self: *Asm, base: u32, w: W, rd: Reg, rn: Reg, value: u64) Error!void {
        const e = encodeBitmask(value, w.bits()) orelse return Error.NotEncodable;
        return self.emit(w.sf() | base | (@as(u32, e.n) << 22) | (@as(u32, e.immr) << 16) | (@as(u32, e.imms) << 10) | (rn.n() << 5) | rd.n());
    }
    pub fn andImm(self: *Asm, w: W, rd: Reg, rn: Reg, value: u64) Error!void {
        return self.logicalImm(0x12000000, w, rd, rn, value);
    }
    pub fn orrImm(self: *Asm, w: W, rd: Reg, rn: Reg, value: u64) Error!void {
        return self.logicalImm(0x32000000, w, rd, rn, value);
    }
    pub fn eorImm(self: *Asm, w: W, rd: Reg, rn: Reg, value: u64) Error!void {
        return self.logicalImm(0x52000000, w, rd, rn, value);
    }
    pub fn andsImm(self: *Asm, w: W, rd: Reg, rn: Reg, value: u64) Error!void {
        return self.logicalImm(0x72000000, w, rd, rn, value);
    }
    pub fn tstImm(self: *Asm, w: W, rn: Reg, value: u64) Error!void {
        return self.andsImm(w, .zr, rn, value);
    }

    pub fn movz(self: *Asm, w: W, rd: Reg, imm: u16, hw: u2) Error!void {
        return self.emit(w.sf() | 0x52800000 | (@as(u32, hw) << 21) | (@as(u32, imm) << 5) | rd.n());
    }
    pub fn movk(self: *Asm, w: W, rd: Reg, imm: u16, hw: u2) Error!void {
        return self.emit(w.sf() | 0x72800000 | (@as(u32, hw) << 21) | (@as(u32, imm) << 5) | rd.n());
    }
    pub fn movn(self: *Asm, w: W, rd: Reg, imm: u16, hw: u2) Error!void {
        return self.emit(w.sf() | 0x12800000 | (@as(u32, hw) << 21) | (@as(u32, imm) << 5) | rd.n());
    }

    /// `rd = value`, in the fewest instructions: one `movz` or `movn` and
    /// `movk`s for the other halfwords, or one `orr` of a bitmask immediate.
    pub fn movImm(self: *Asm, w: W, rd: Reg, value: u64) Error!void {
        const v = if (w == .w) value & 0xFFFF_FFFF else value;
        const halves: usize = if (w == .w) 2 else 4;
        var zeros: usize = 0;
        var ones: usize = 0;
        for (0..halves) |i| {
            const h: u16 = @truncate(v >> @intCast(i * 16));
            if (h == 0) zeros += 1;
            if (h == 0xFFFF) ones += 1;
        }
        if (zeros < halves - 1 and ones < halves - 1) {
            if (encodeBitmask(v, w.bits()) != null) return self.orrImm(w, rd, .zr, v);
        }
        const inverted = ones > zeros;
        var first = true;
        for (0..halves) |i| {
            const h: u16 = @truncate(v >> @intCast(i * 16));
            const skip: u16 = if (inverted) 0xFFFF else 0;
            if (h == skip) continue;
            if (first) {
                if (inverted) try self.movn(w, rd, ~h, @intCast(i)) else try self.movz(w, rd, h, @intCast(i));
                first = false;
            } else try self.movk(w, rd, h, @intCast(i));
        }
        if (first) {
            if (inverted) try self.movn(w, rd, 0, 0) else try self.movz(w, rd, 0, 0);
        }
    }

    fn bitfield(self: *Asm, base: u32, w: W, rd: Reg, rn: Reg, immr: u6, imms: u6) Error!void {
        const nbit: u32 = if (w == .x) 1 << 22 else 0;
        return self.emit(w.sf() | base | nbit | (@as(u32, immr) << 16) | (@as(u32, imms) << 10) | (rn.n() << 5) | rd.n());
    }
    pub fn ubfm(self: *Asm, w: W, rd: Reg, rn: Reg, immr: u6, imms: u6) Error!void {
        return self.bitfield(0x53000000, w, rd, rn, immr, imms);
    }
    pub fn sbfm(self: *Asm, w: W, rd: Reg, rn: Reg, immr: u6, imms: u6) Error!void {
        return self.bitfield(0x13000000, w, rd, rn, immr, imms);
    }
    pub fn lslImm(self: *Asm, w: W, rd: Reg, rn: Reg, s: u6) Error!void {
        const bits: u32 = w.bits();
        if (s >= bits) return Error.NotEncodable;
        return self.ubfm(w, rd, rn, @intCast((bits - s) % bits), @intCast(bits - 1 - s));
    }
    pub fn lsrImm(self: *Asm, w: W, rd: Reg, rn: Reg, s: u6) Error!void {
        if (s >= w.bits()) return Error.NotEncodable;
        return self.ubfm(w, rd, rn, s, @intCast(w.bits() - 1));
    }
    pub fn asrImm(self: *Asm, w: W, rd: Reg, rn: Reg, s: u6) Error!void {
        if (s >= w.bits()) return Error.NotEncodable;
        return self.sbfm(w, rd, rn, s, @intCast(w.bits() - 1));
    }
    pub fn sxtb(self: *Asm, w: W, rd: Reg, rn: Reg) Error!void {
        return self.sbfm(w, rd, rn, 0, 7);
    }
    pub fn sxth(self: *Asm, w: W, rd: Reg, rn: Reg) Error!void {
        return self.sbfm(w, rd, rn, 0, 15);
    }
    pub fn sxtw(self: *Asm, rd: Reg, rn: Reg) Error!void {
        return self.sbfm(.x, rd, rn, 0, 31);
    }
    pub fn uxtb(self: *Asm, rd: Reg, rn: Reg) Error!void {
        return self.ubfm(.w, rd, rn, 0, 7);
    }
    pub fn uxth(self: *Asm, rd: Reg, rn: Reg) Error!void {
        return self.ubfm(.w, rd, rn, 0, 15);
    }

    fn dp2(self: *Asm, op: u32, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.emit(w.sf() | 0x1AC00000 | (rm.n() << 16) | (op << 10) | (rn.n() << 5) | rd.n());
    }
    pub fn lslv(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.dp2(0b001000, w, rd, rn, rm);
    }
    pub fn lsrv(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.dp2(0b001001, w, rd, rn, rm);
    }
    pub fn asrv(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.dp2(0b001010, w, rd, rn, rm);
    }
    pub fn sdiv(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.dp2(0b000011, w, rd, rn, rm);
    }
    pub fn udiv(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.dp2(0b000010, w, rd, rn, rm);
    }

    pub fn madd(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg, ra: Reg) Error!void {
        return self.emit(w.sf() | 0x1B000000 | (rm.n() << 16) | (ra.n() << 10) | (rn.n() << 5) | rd.n());
    }
    pub fn msub(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg, ra: Reg) Error!void {
        return self.emit(w.sf() | 0x1B008000 | (rm.n() << 16) | (ra.n() << 10) | (rn.n() << 5) | rd.n());
    }
    pub fn mul(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.madd(w, rd, rn, rm, .zr);
    }
    /// `rd = rn * rm` over the 32-bit operands, sign-extended to 64 bits.
    pub fn smull(self: *Asm, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.emit(0x9B207C00 | (rm.n() << 16) | (rn.n() << 5) | rd.n());
    }
    pub fn smulh(self: *Asm, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.emit(0x9B407C00 | (rm.n() << 16) | (rn.n() << 5) | rd.n());
    }
    pub fn umulh(self: *Asm, rd: Reg, rn: Reg, rm: Reg) Error!void {
        return self.emit(0x9BC07C00 | (rm.n() << 16) | (rn.n() << 5) | rd.n());
    }

    fn condSel(self: *Asm, base: u32, w: W, rd: Reg, rn: Reg, rm: Reg, c: Cond) Error!void {
        return self.emit(w.sf() | base | (rm.n() << 16) | (@as(u32, @intFromEnum(c)) << 12) | (rn.n() << 5) | rd.n());
    }
    pub fn csel(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg, c: Cond) Error!void {
        return self.condSel(0x1A800000, w, rd, rn, rm, c);
    }
    pub fn csinc(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg, c: Cond) Error!void {
        return self.condSel(0x1A800400, w, rd, rn, rm, c);
    }
    pub fn csinv(self: *Asm, w: W, rd: Reg, rn: Reg, rm: Reg, c: Cond) Error!void {
        return self.condSel(0x5A800000, w, rd, rn, rm, c);
    }
    /// `rd = c ? 1 : 0`.
    pub fn cset(self: *Asm, w: W, rd: Reg, c: Cond) Error!void {
        return self.csinc(w, rd, .zr, .zr, c.invert());
    }

    // -------------------------------------------------------------- memory --

    fn sizeInfo(s: Size) struct { base_imm: u32, base_unscaled: u32, base_reg: u32, scale: u2 } {
        return switch (s) {
            .b => .{ .base_imm = 0x39400000, .base_unscaled = 0x38400000, .base_reg = 0x38606800, .scale = 0 },
            .h => .{ .base_imm = 0x79400000, .base_unscaled = 0x78400000, .base_reg = 0x78606800, .scale = 1 },
            .w => .{ .base_imm = 0xB9400000, .base_unscaled = 0xB8400000, .base_reg = 0xB8606800, .scale = 2 },
            .x => .{ .base_imm = 0xF9400000, .base_unscaled = 0xF8400000, .base_reg = 0xF8606800, .scale = 3 },
            .sb_w => .{ .base_imm = 0x39C00000, .base_unscaled = 0x38C00000, .base_reg = 0x38E06800, .scale = 0 },
            .sh_w => .{ .base_imm = 0x79C00000, .base_unscaled = 0x78C00000, .base_reg = 0x78E06800, .scale = 1 },
            .sb_x => .{ .base_imm = 0x39800000, .base_unscaled = 0x38800000, .base_reg = 0x38A06800, .scale = 0 },
            .sh_x => .{ .base_imm = 0x79800000, .base_unscaled = 0x78800000, .base_reg = 0x78A06800, .scale = 1 },
            .sw_x => .{ .base_imm = 0xB9800000, .base_unscaled = 0xB8800000, .base_reg = 0xB8A06800, .scale = 2 },
        };
    }

    fn memImm(self: *Asm, base_imm: u32, base_unscaled: u32, scale: u2, rt: u32, rn: Reg, off: i32) Error!void {
        const unit: i32 = @as(i32, 1) << scale;
        if (off >= 0 and @rem(off, unit) == 0 and @divExact(off, unit) < 4096) {
            const imm: u32 = @intCast(@divExact(off, unit));
            return self.emit(base_imm | (imm << 10) | (rn.n() << 5) | rt);
        }
        if (off >= -256 and off < 256) {
            const imm: u32 = @as(u32, @bitCast(off)) & 0x1FF;
            return self.emit(base_unscaled | (imm << 12) | (rn.n() << 5) | rt);
        }
        return Error.NotEncodable;
    }

    /// Load `s` from `[rn + off]`: a scaled unsigned offset, or an unscaled
    /// signed one within 256 bytes.
    pub fn ldr(self: *Asm, s: Size, rt: Reg, rn: Reg, off: i32) Error!void {
        const i = sizeInfo(s);
        return self.memImm(i.base_imm, i.base_unscaled, i.scale, rt.n(), rn, off);
    }
    /// Store the low `s` of `rt` to `[rn + off]` (`s` one of b, h, w, x).
    pub fn str(self: *Asm, s: Size, rt: Reg, rn: Reg, off: i32) Error!void {
        const i = sizeInfo(s);
        return self.memImm(i.base_imm & ~@as(u32, 0x00400000), i.base_unscaled & ~@as(u32, 0x00400000), i.scale, rt.n(), rn, off);
    }
    /// Load `s` from `[rn + rm << scale]`, scaled by the access size when
    /// `scaled`.
    pub fn ldrReg(self: *Asm, s: Size, rt: Reg, rn: Reg, rm: Reg, scaled: bool) Error!void {
        const i = sizeInfo(s);
        const sbit: u32 = if (scaled and i.scale != 0) 1 << 12 else 0;
        return self.emit(i.base_reg | sbit | (rm.n() << 16) | (rn.n() << 5) | rt.n());
    }
    pub fn strReg(self: *Asm, s: Size, rt: Reg, rn: Reg, rm: Reg, scaled: bool) Error!void {
        const i = sizeInfo(s);
        const sbit: u32 = if (scaled and i.scale != 0) 1 << 12 else 0;
        return self.emit((i.base_reg & ~@as(u32, 0x00400000)) | sbit | (rm.n() << 16) | (rn.n() << 5) | rt.n());
    }

    fn pair(self: *Asm, base: u32, rt: Reg, rt2: Reg, rn: Reg, off: i32) Error!void {
        if (@rem(off, 8) != 0 or off < -512 or off > 504) return Error.NotEncodable;
        const imm: u32 = @as(u32, @bitCast(@divExact(off, 8))) & 0x7F;
        return self.emit(base | (imm << 15) | (rt2.n() << 10) | (rn.n() << 5) | rt.n());
    }
    pub fn ldp(self: *Asm, rt: Reg, rt2: Reg, rn: Reg, off: i32) Error!void {
        return self.pair(0xA9400000, rt, rt2, rn, off);
    }
    pub fn stp(self: *Asm, rt: Reg, rt2: Reg, rn: Reg, off: i32) Error!void {
        return self.pair(0xA9000000, rt, rt2, rn, off);
    }
    /// `stp` that first moves `rn` by `off` (a push with `sp`).
    pub fn stpPre(self: *Asm, rt: Reg, rt2: Reg, rn: Reg, off: i32) Error!void {
        return self.pair(0xA9800000, rt, rt2, rn, off);
    }
    /// `ldp` that then moves `rn` by `off` (a pop with `sp`).
    pub fn ldpPost(self: *Asm, rt: Reg, rt2: Reg, rn: Reg, off: i32) Error!void {
        return self.pair(0xA8C00000, rt, rt2, rn, off);
    }

    pub fn ldar(self: *Asm, w: W, rt: Reg, rn: Reg) Error!void {
        return self.emit((if (w == .x) @as(u32, 0xC8DFFC00) else 0x88DFFC00) | (rn.n() << 5) | rt.n());
    }
    /// Load-acquire with release-consistent (processor) ordering (FEAT_LRCPC):
    /// ordered after earlier loads as `ldar` is, but not after earlier
    /// release stores, so a pending store does not hold it back.
    pub fn ldapr(self: *Asm, w: W, rt: Reg, rn: Reg) Error!void {
        return self.emit((if (w == .x) @as(u32, 0xF8BFC000) else 0xB8BFC000) | (rn.n() << 5) | rt.n());
    }
    pub fn ldarb(self: *Asm, rt: Reg, rn: Reg) Error!void {
        return self.emit(0x08DFFC00 | (rn.n() << 5) | rt.n());
    }
    pub fn stlr(self: *Asm, w: W, rt: Reg, rn: Reg) Error!void {
        return self.emit((if (w == .x) @as(u32, 0xC89FFC00) else 0x889FFC00) | (rn.n() << 5) | rt.n());
    }
    pub fn stlrb(self: *Asm, rt: Reg, rn: Reg) Error!void {
        return self.emit(0x089FFC00 | (rn.n() << 5) | rt.n());
    }
    pub fn ldaxr(self: *Asm, w: W, rt: Reg, rn: Reg) Error!void {
        return self.emit((if (w == .x) @as(u32, 0xC85FFC00) else 0x885FFC00) | (rn.n() << 5) | rt.n());
    }
    /// `rs = 0` when the exclusive store took.
    pub fn stlxr(self: *Asm, w: W, rs: Reg, rt: Reg, rn: Reg) Error!void {
        return self.emit((if (w == .x) @as(u32, 0xC800FC00) else 0x8800FC00) | (rs.n() << 16) | (rn.n() << 5) | rt.n());
    }
    /// Compare-and-swap with no ordering (LSE): if `[rn] == rs`, `[rn] = rt`; `rs`
    /// receives the old value either way.
    pub fn cas(self: *Asm, w: W, rs: Reg, rt: Reg, rn: Reg) Error!void {
        return self.emit((if (w == .x) @as(u32, 0xC8A07C00) else 0x88A07C00) | (rs.n() << 16) | (rn.n() << 5) | rt.n());
    }
    /// Compare-and-swap with acquire and release (LSE): if `[rn] == rs`,
    /// `[rn] = rt`; `rs` receives the old value either way.
    pub fn casal(self: *Asm, w: W, rs: Reg, rt: Reg, rn: Reg) Error!void {
        return self.emit((if (w == .x) @as(u32, 0xC8E0FC00) else 0x88E0FC00) | (rs.n() << 16) | (rn.n() << 5) | rt.n());
    }
    /// `[rn] += rs` atomically with acquire and release (LSE); `rt` receives
    /// the old value.
    pub fn ldaddal(self: *Asm, w: W, rs: Reg, rt: Reg, rn: Reg) Error!void {
        return self.emit((if (w == .x) @as(u32, 0xF8E00000) else 0xB8E00000) | (rs.n() << 16) | (rn.n() << 5) | rt.n());
    }
    /// `ldaddal` with no ordering: atomic, and nothing else waits for it.
    pub fn ldadd(self: *Asm, w: W, rs: Reg, rt: Reg, rn: Reg) Error!void {
        return self.emit((if (w == .x) @as(u32, 0xF8200000) else 0xB8200000) | (rs.n() << 16) | (rn.n() << 5) | rt.n());
    }
    pub fn dmb(self: *Asm, kind: Barrier) Error!void {
        return self.emit(0xD50330BF | (@as(u32, @intFromEnum(kind)) << 8));
    }

    /// `rt` loaded from the literal pool slot holding `value`.
    pub fn ldrLit(self: *Asm, rt: Reg, value: u64) Error!void {
        try self.lits.append(self.gpa, .{ .at = self.here(), .value = value });
        return self.emit(0x58000000 | rt.n());
    }
    /// `vt` (a double) loaded from the literal pool slot holding `bits`.
    pub fn ldrLitD(self: *Asm, vt: V, bits: u64) Error!void {
        try self.lits.append(self.gpa, .{ .at = self.here(), .value = bits });
        return self.emit(0x5C000000 | vt.n());
    }
    /// `rd` = the address of label `l`.
    pub fn adr(self: *Asm, rd: Reg, l: Label) Error!void {
        return self.ref(l, .adr, 0x10000000 | rd.n());
    }

    // ------------------------------------------------------------ branches --

    pub fn b(self: *Asm, l: Label) Error!void {
        return self.ref(l, .b26, 0x14000000);
    }
    pub fn bl(self: *Asm, l: Label) Error!void {
        return self.ref(l, .b26, 0x94000000);
    }
    pub fn bCond(self: *Asm, c: Cond, l: Label) Error!void {
        return self.ref(l, .b19, 0x54000000 | @as(u32, @intFromEnum(c)));
    }
    pub fn cbz(self: *Asm, w: W, rt: Reg, l: Label) Error!void {
        return self.ref(l, .b19, w.sf() | 0x34000000 | rt.n());
    }
    pub fn cbnz(self: *Asm, w: W, rt: Reg, l: Label) Error!void {
        return self.ref(l, .b19, w.sf() | 0x35000000 | rt.n());
    }
    pub fn tbz(self: *Asm, rt: Reg, bit: u6, l: Label) Error!void {
        return self.ref(l, .b14, (@as(u32, bit >> 5) << 31) | 0x36000000 | (@as(u32, bit & 31) << 19) | rt.n());
    }
    pub fn tbnz(self: *Asm, rt: Reg, bit: u6, l: Label) Error!void {
        return self.ref(l, .b14, (@as(u32, bit >> 5) << 31) | 0x37000000 | (@as(u32, bit & 31) << 19) | rt.n());
    }
    pub fn br(self: *Asm, rn: Reg) Error!void {
        return self.emit(0xD61F0000 | (rn.n() << 5));
    }
    pub fn blr(self: *Asm, rn: Reg) Error!void {
        return self.emit(0xD63F0000 | (rn.n() << 5));
    }
    pub fn ret(self: *Asm) Error!void {
        return self.emit(0xD65F03C0);
    }
    /// A jump to absolute `addr` through `scratch`.
    pub fn jumpAbs(self: *Asm, addr: usize, scratch: Reg) Error!void {
        try self.ldrLit(scratch, addr);
        return self.br(scratch);
    }
    /// A call of absolute `addr` through `scratch`.
    pub fn callAbs(self: *Asm, addr: usize, scratch: Reg) Error!void {
        try self.ldrLit(scratch, addr);
        return self.blr(scratch);
    }
    pub fn nop(self: *Asm) Error!void {
        return self.emit(nop_word);
    }
    pub fn brk(self: *Asm, imm: u16) Error!void {
        return self.emit(0xD4200000 | (@as(u32, imm) << 5));
    }

    // ------------------------------------------------------ floating point --

    fn ftype(f: F) u32 {
        return if (f == .d) 1 << 22 else 0;
    }
    fn fp3(self: *Asm, op: u32, f: F, rd: V, rn: V, rm: V) Error!void {
        return self.emit(0x1E200800 | ftype(f) | (rm.n() << 16) | (op << 12) | (rn.n() << 5) | rd.n());
    }
    pub fn fmul(self: *Asm, f: F, rd: V, rn: V, rm: V) Error!void {
        return self.fp3(0b0000, f, rd, rn, rm);
    }
    pub fn fdiv(self: *Asm, f: F, rd: V, rn: V, rm: V) Error!void {
        return self.fp3(0b0001, f, rd, rn, rm);
    }
    pub fn fadd(self: *Asm, f: F, rd: V, rn: V, rm: V) Error!void {
        return self.fp3(0b0010, f, rd, rn, rm);
    }
    pub fn fsub(self: *Asm, f: F, rd: V, rn: V, rm: V) Error!void {
        return self.fp3(0b0011, f, rd, rn, rm);
    }
    fn fp1(self: *Asm, op: u32, f: F, rd: V, rn: V) Error!void {
        return self.emit(0x1E204000 | ftype(f) | (op << 15) | (rn.n() << 5) | rd.n());
    }
    pub fn fmovV(self: *Asm, f: F, rd: V, rn: V) Error!void {
        return self.fp1(0b000000, f, rd, rn);
    }
    pub fn fabs(self: *Asm, f: F, rd: V, rn: V) Error!void {
        return self.fp1(0b000001, f, rd, rn);
    }
    pub fn fneg(self: *Asm, f: F, rd: V, rn: V) Error!void {
        return self.fp1(0b000010, f, rd, rn);
    }
    pub fn fsqrt(self: *Asm, f: F, rd: V, rn: V) Error!void {
        return self.fp1(0b000011, f, rd, rn);
    }
    /// Double from single.
    pub fn fcvtDS(self: *Asm, rd: V, rn: V) Error!void {
        return self.fp1(0b000101, .s, rd, rn);
    }
    /// Single from double.
    pub fn fcvtSD(self: *Asm, rd: V, rn: V) Error!void {
        return self.fp1(0b000100, .d, rd, rn);
    }
    pub fn fcmp(self: *Asm, f: F, rn: V, rm: V) Error!void {
        return self.emit(0x1E202000 | ftype(f) | (rm.n() << 16) | (rn.n() << 5));
    }
    pub fn fcmpZero(self: *Asm, f: F, rn: V) Error!void {
        return self.emit(0x1E202008 | ftype(f) | (rn.n() << 5));
    }

    fn fpInt(self: *Asm, base: u32, w: W, f: F, rd: u32, rn: u32) Error!void {
        return self.emit(w.sf() | base | ftype(f) | (rn << 5) | rd);
    }
    /// The bits of general `rn` moved to `rd` (`w` with `s`, `x` with `d`).
    pub fn fmovToV(self: *Asm, w: W, rd: V, rn: Reg) Error!void {
        return self.fpInt(0x1E270000, w, if (w == .x) .d else .s, rd.n(), rn.n());
    }
    pub fn fmovFromV(self: *Asm, w: W, rd: Reg, rn: V) Error!void {
        return self.fpInt(0x1E260000, w, if (w == .x) .d else .s, rd.n(), rn.n());
    }
    /// Signed integer `rn` converted to float `rd`.
    pub fn scvtf(self: *Asm, f: F, rd: V, w: W, rn: Reg) Error!void {
        return self.fpInt(0x1E220000, w, f, rd.n(), rn.n());
    }
    pub fn ucvtf(self: *Asm, f: F, rd: V, w: W, rn: Reg) Error!void {
        return self.fpInt(0x1E230000, w, f, rd.n(), rn.n());
    }
    /// Float `rn` to signed integer `rd`, rounding toward zero, saturating,
    /// NaN to 0: Kotlin's `toInt()` and `toLong()`.
    pub fn fcvtzs(self: *Asm, w: W, rd: Reg, f: F, rn: V) Error!void {
        return self.fpInt(0x1E380000, w, f, rd.n(), rn.n());
    }
    pub fn fcvtzu(self: *Asm, w: W, rd: Reg, f: F, rn: V) Error!void {
        return self.fpInt(0x1E390000, w, f, rd.n(), rn.n());
    }

    pub fn ldrF(self: *Asm, f: F, vt: V, rn: Reg, off: i32) Error!void {
        return if (f == .d)
            self.memImm(0xFD400000, 0xFC400000, 3, vt.n(), rn, off)
        else
            self.memImm(0xBD400000, 0xBC400000, 2, vt.n(), rn, off);
    }
    pub fn strF(self: *Asm, f: F, vt: V, rn: Reg, off: i32) Error!void {
        return if (f == .d)
            self.memImm(0xFD000000, 0xFC000000, 3, vt.n(), rn, off)
        else
            self.memImm(0xBD000000, 0xBC000000, 2, vt.n(), rn, off);
    }
};

const nop_word: u32 = 0xD503201F;

fn field(off: i64, comptime bits: u6, comptime shift: u5) Error!u32 {
    const lim: i64 = @as(i64, 1) << (bits - 1);
    if (off < -lim or off >= lim) return Error.OutOfRange;
    const mask: u32 = (@as(u32, 1) << bits) - 1;
    return (@as(u32, @bitCast(@as(i32, @intCast(off)))) & mask) << shift;
}

pub const Bitmask = struct { n: u1, immr: u6, imms: u6 };

/// The (N, immr, imms) fields of a logical instruction's immediate, when
/// `value` is a rotated run of ones repeated across `width` bits.
pub fn encodeBitmask(value: u64, width: u32) ?Bitmask {
    const v: u64 = if (width == 32) (value & 0xFFFF_FFFF) | ((value & 0xFFFF_FFFF) << 32) else value;
    if (v == 0 or v == ~@as(u64, 0)) return null;
    // The smallest element size the value repeats at.
    var size: u32 = 64;
    while (size > 2) {
        const half = size / 2;
        const mask: u64 = (@as(u64, 1) << @intCast(half)) - 1;
        if ((v & mask) != ((v >> @intCast(half)) & mask)) break;
        size = half;
    }
    const emask: u64 = if (size == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(size)) - 1;
    const elem = v & emask;
    // Rotate the element right until its run of ones starts at bit 0.
    var rot: u32 = 0;
    var e = elem;
    const ones = @popCount(elem);
    if (ones == 0 or ones == size) return null;
    while (rot < size) : (rot += 1) {
        const run: u64 = (@as(u64, 1) << @intCast(ones)) - 1;
        if (e == run) break;
        e = ((e >> 1) | ((e & 1) << @intCast(size - 1))) & emask;
    } else return null;
    // `rot` right rotations made it a run from bit 0; the instruction rotates
    // right by immr, so immr is the left rotation.
    const immr: u32 = (size - rot) % size;
    const imms: u32 = ((~(size - 1) << 1) & 0x3F) | (ones - 1);
    return .{ .n = if (size == 64) 1 else 0, .immr = @intCast(immr), .imms = @intCast(imms & 0x3F) };
}

test "every instruction encodes as the system assembler encodes it" {
    var a = Asm.init(std.testing.allocator);
    defer a.deinit();
    try a.addImm(.x, .x0, .x1, 12);
    try a.addImm(.w, .x3, .x4, 4095);
    try a.addImm(.x, .x5, sp, 16);
    try a.addImm(.x, .x6, .x7, 4096);
    try a.subImm(.x, .x8, .x9, 1);
    try a.addsImm(.x, .x10, .x11, 7);
    try a.subsImm(.w, .x12, .x13, 2);
    try a.cmpImm(.x, .x14, 100);
    try a.cmnImm(.w, .x15, 3);
    try a.add(.x, .x0, .x1, .x2);
    try a.addShifted(.x, .x3, .x4, .x5, .lsl, 4);
    try a.sub(.w, .x6, .x7, .x8);
    try a.adds(.x, .x9, .x10, .x11);
    try a.subs(.x, .x12, .x13, .x14);
    try a.cmp(.w, .x1, .x2);
    try a.neg(.x, .x3, .x4);
    try a.@"and"(.x, .x5, .x6, .x7);
    try a.orr(.w, .x8, .x9, .x10);
    try a.eor(.x, .x11, .x12, .x13);
    try a.ands(.x, .x14, .x15, .x16);
    try a.bic(.x, .x1, .x2, .x3);
    try a.orn(.x, .x4, .x5, .x6);
    try a.tst(.w, .x7, .x8);
    try a.mov(.x, .x9, .x10);
    try a.mvn(.w, .x11, .x12);
    try a.andImm(.x, .x0, .x1, 0xff);
    try a.orrImm(.w, .x2, .x3, 0x3f);
    try a.eorImm(.x, .x4, .x5, 0xffff0000ffff0000);
    try a.andImm(.w, .x6, .x7, 0x80000000);
    try a.tstImm(.x, .x8, 1);
    try a.andsImm(.x, .x9, .x10, 0xf0);
    try a.movz(.x, .x0, 0x1234, 0);
    try a.movz(.x, .x1, 0xbeef, 1);
    try a.movk(.x, .x2, 0xdead, 3);
    try a.movn(.w, .x3, 0, 0);
    try a.lslImm(.x, .x4, .x5, 3);
    try a.lsrImm(.w, .x6, .x7, 5);
    try a.asrImm(.x, .x8, .x9, 63);
    try a.sxtb(.x, .x10, .x11);
    try a.sxth(.w, .x12, .x13);
    try a.sxtw(.x14, .x15);
    try a.uxtb(.x16, .x17);
    try a.uxth(.x0, .x1);
    try a.lslv(.x, .x2, .x3, .x4);
    try a.lsrv(.w, .x5, .x6, .x7);
    try a.asrv(.x, .x8, .x9, .x10);
    try a.sdiv(.x, .x11, .x12, .x13);
    try a.udiv(.w, .x14, .x15, .x16);
    try a.madd(.x, .x0, .x1, .x2, .x3);
    try a.msub(.w, .x4, .x5, .x6, .x7);
    try a.mul(.x, .x8, .x9, .x10);
    try a.smull(.x11, .x12, .x13);
    try a.smulh(.x14, .x15, .x16);
    try a.umulh(.x0, .x1, .x2);
    try a.csel(.x, .x3, .x4, .x5, .eq);
    try a.csinc(.w, .x6, .x7, .x8, .lt);
    try a.csinv(.x, .x9, .x10, .x11, .hi);
    try a.cset(.w, .x12, .ne);
    try a.ldr(.x, .x0, .x1, 8);
    try a.ldr(.w, .x2, .x3, 4092);
    try a.ldr(.b, .x4, .x5, 7);
    try a.ldr(.h, .x6, .x7, 2);
    try a.ldr(.sb_w, .x8, .x9, 1);
    try a.ldr(.sh_x, .x10, .x11, 6);
    try a.ldr(.sw_x, .x12, .x13, 12);
    try a.ldr(.x, .x14, .x15, -8);
    try a.ldr(.w, .x16, .x17, 3);
    try a.str(.x, .x0, .x1, 16);
    try a.str(.w, .x2, .x3, 0);
    try a.str(.b, .x4, .x5, 255);
    try a.str(.h, .x6, .x7, 10);
    try a.str(.x, .x8, .x9, -16);
    try a.ldrReg(.x, .x0, .x1, .x2, true);
    try a.ldrReg(.x, .x3, .x4, .x5, false);
    try a.ldrReg(.b, .x6, .x7, .x8, false);
    try a.ldrReg(.w, .x9, .x10, .x11, true);
    try a.strReg(.x, .x12, .x13, .x14, true);
    try a.ldrReg(.sw_x, .x15, .x16, .x17, false);
    try a.ldp(.x0, .x1, .x2, 16);
    try a.stpPre(.x3, .x4, sp, -32);
    try a.ldpPost(fp, lr, sp, 16);
    try a.stp(.x5, .x6, .x7, 0);
    try a.ldar(.x, .x0, .x1);
    try a.ldar(.w, .x2, .x3);
    try a.ldarb(.x4, .x5);
    try a.stlr(.x, .x6, .x7);
    try a.stlrb(.x8, .x9);
    try a.ldaxr(.x, .x10, .x11);
    try a.stlxr(.x, .x12, .x13, .x14);
    try a.casal(.w, .x15, .x16, .x17);
    try a.casal(.x, .x0, .x1, .x2);
    try a.dmb(.ish);
    try a.dmb(.ishld);
    try a.br(.x16);
    try a.blr(.x17);
    try a.ret();
    try a.nop();
    try a.brk(0x3e8);
    try a.fadd(.d, .v0, .v1, .v2);
    try a.fsub(.s, .v3, .v4, .v5);
    try a.fmul(.d, .v6, .v7, .v8);
    try a.fdiv(.s, .v9, .v10, .v11);
    try a.fmovV(.d, .v12, .v13);
    try a.fabs(.s, .v14, .v15);
    try a.fneg(.d, .v16, .v17);
    try a.fsqrt(.d, .v18, .v19);
    try a.fcvtDS(.v20, .v21);
    try a.fcvtSD(.v22, .v23);
    try a.fcmp(.d, .v24, .v25);
    try a.fcmpZero(.s, .v26);
    try a.fmovToV(.x, .v0, .x1);
    try a.fmovToV(.w, .v2, .x3);
    try a.fmovFromV(.x, .x4, .v5);
    try a.fmovFromV(.w, .x6, .v7);
    try a.scvtf(.d, .v8, .x, .x9);
    try a.scvtf(.s, .v10, .w, .x11);
    try a.scvtf(.d, .v12, .w, .x13);
    try a.ucvtf(.d, .v14, .x, .x15);
    try a.fcvtzs(.x, .x16, .d, .v17);
    try a.fcvtzs(.w, .x0, .s, .v1);
    try a.fcvtzu(.x, .x2, .d, .v3);
    try a.ldrF(.d, .v0, .x1, 8);
    try a.strF(.d, .v2, .x3, 16);
    try a.ldrF(.s, .v4, .x5, 4);
    try a.strF(.s, .v6, .x7, 0);
    try a.ldrF(.d, .v8, .x9, -8);
    const want = [_]u32{
        0x91003020, 0x113ffc83, 0x910043e5, 0x914004e6, 0xd1000528, 0xb1001d6a, 0x710009ac, 0xf10191df, 0x31000dff, 0x8b020020,
        0x8b051083, 0x4b0800e6, 0xab0b0149, 0xeb0e01ac, 0x6b02003f, 0xcb0403e3, 0x8a0700c5, 0x2a0a0128, 0xca0d018b, 0xea1001ee,
        0x8a230041, 0xaa2600a4, 0x6a0800ff, 0xaa0a03e9, 0x2a2c03eb, 0x92401c20, 0x32001462, 0xd2103ca4, 0x120100e6, 0xf240011f,
        0xf27c0d49, 0xd2824680, 0xd2b7dde1, 0xf2fbd5a2, 0x12800003, 0xd37df0a4, 0x53057ce6, 0x937ffd28, 0x93401d6a, 0x13003dac,
        0x93407dee, 0x53001e30, 0x53003c20, 0x9ac42062, 0x1ac724c5, 0x9aca2928, 0x9acd0d8b, 0x1ad009ee, 0x9b020c20, 0x1b069ca4,
        0x9b0a7d28, 0x9b2d7d8b, 0x9b507dee, 0x9bc27c20, 0x9a850083, 0x1a88b4e6, 0xda8b8149, 0x1a9f07ec, 0xf9400420, 0xb94ffc62,
        0x39401ca4, 0x794004e6, 0x39c00528, 0x79800d6a, 0xb9800dac, 0xf85f81ee, 0xb8403230, 0xf9000820, 0xb9000062, 0x3903fca4,
        0x790014e6, 0xf81f0128, 0xf8627820, 0xf8656883, 0x386868e6, 0xb86b7949, 0xf82e79ac, 0xb8b16a0f, 0xa9410440, 0xa9be13e3,
        0xa8c17bfd, 0xa90018e5, 0xc8dffc20, 0x88dffc62, 0x08dffca4, 0xc89ffce6, 0x089ffd28, 0xc85ffd6a, 0xc80cfdcd, 0x88effe30,
        0xc8e0fc41, 0xd5033bbf, 0xd50339bf, 0xd61f0200, 0xd63f0220, 0xd65f03c0, 0xd503201f, 0xd4207d00, 0x1e622820, 0x1e253883,
        0x1e6808e6, 0x1e2b1949, 0x1e6041ac, 0x1e20c1ee, 0x1e614230, 0x1e61c272, 0x1e22c2b4, 0x1e6242f6, 0x1e792300, 0x1e202348,
        0x9e670020, 0x1e270062, 0x9e6600a4, 0x1e2600e6, 0x9e620128, 0x1e22016a, 0x1e6201ac, 0x9e6301ee, 0x9e780230, 0x1e380020,
        0x9e790062, 0xfd400420, 0xfd000862, 0xbd4004a4, 0xbd0000e6, 0xfc5f8128,
    };
    try std.testing.expectEqual(want.len, a.words.items.len);
    for (want, a.words.items, 0..) |w, got, i| {
        if (w != got) {
            std.debug.print("instruction {d}: want 0x{x:0>8}, got 0x{x:0>8}\n", .{ i, w, got });
            return error.TestExpectedEqual;
        }
    }
}

test "labels and literals resolve after the code, forward and back" {
    var a = Asm.init(std.testing.allocator);
    defer a.deinit();
    const top = try a.newLabel();
    const out = try a.newLabel();
    a.bind(top);
    try a.cbz(.x, .x0, out);
    try a.ldrLit(.x1, 0x1122334455667788);
    try a.bCond(.ne, top);
    try a.tbnz(.x2, 40, out);
    try a.ldrLit(.x3, 0x1122334455667788);
    a.bind(out);
    try a.b(top);
    const bytes = try a.finish();
    defer std.testing.allocator.free(bytes);
    // The pool follows the code at word 6, already 8-byte aligned.
    const want = [_]u32{ 0xb40000a0, 0x580000a1, 0x54ffffc1, 0xb7400042, 0x58000043, 0x17fffffb, 0x55667788, 0x11223344 };
    try std.testing.expectEqual(want.len * 4, bytes.len);
    for (want, 0..) |w, i| try std.testing.expectEqual(w, std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
}

test "the cold section follows the hot one, and branches and literals between them resolve" {
    var a = Asm.init(std.testing.allocator);
    defer a.deinit();
    const cold = try a.newLabel();
    const back = try a.newLabel();
    try a.cbz(.x, .x0, cold);
    try a.movImm(.x, .x1, 1);
    a.bind(back);
    try a.ret();
    a.section(true);
    a.bind(cold);
    try a.ldrLit(.x1, 0x55);
    try a.b(back);
    a.section(false);
    try a.nop();
    const bytes = try a.finish();
    defer std.testing.allocator.free(bytes);
    // Hot words 0-3, cold words 4-5, the pool at 6.
    const want = [_]u32{ 0xb4000080, 0xd2800021, 0xd65f03c0, 0xd503201f, 0x58000041, 0x17fffffd, 0x55, 0 };
    try std.testing.expectEqual(want.len * 4, bytes.len);
    for (want, 0..) |w, i| try std.testing.expectEqual(w, std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(?u32, 8), a.labelOffset(back));
}

test "a 64-bit immediate takes its shortest sequence" {
    var a = Asm.init(std.testing.allocator);
    defer a.deinit();
    try a.movImm(.x, .x0, 0);
    try a.movImm(.x, .x1, 0xFFFF_FFFF_FFFF_FFFF);
    try a.movImm(.x, .x2, 0x0000_0000_1234_0000);
    try a.movImm(.x, .x3, 0xFFFF_FFFF_FFFF_1234);
    try a.movImm(.x, .x4, 0x00FF_00FF_00FF_00FF);
    try a.movImm(.x, .x5, 0x1234_5678_9ABC_DEF0);
    try a.movImm(.w, .x6, 0xFFFF_0001);
    const want = [_]u32{
        0xd2800000, 0x92800001, 0xd2a24682, 0x929db963, 0xb2009fe4,
        0xd29bde05, 0xf2b35785, 0xf2cacf05, 0xf2e24685, 0x129fffc6,
    };
    try std.testing.expectEqualSlices(u32, &want, a.words.items);
}

test "ldapr encodes as the system assembler encodes it" {
    var a = Asm.init(std.testing.allocator);
    defer a.deinit();
    try a.ldapr(.x, .x0, .x1);
    try a.ldapr(.w, .x2, .x3);
    try std.testing.expectEqualSlices(u32, &.{ 0xf8bfc020, 0xb8bfc062 }, a.words.items);
}

test "cas encodes as the system assembler encodes it" {
    var a = Asm.init(std.testing.allocator);
    defer a.deinit();
    try a.cas(.x, .x1, .x2, .x3);
    try a.cas(.w, .x1, .x2, .x3);
    try std.testing.expectEqualSlices(u32, &.{ 0xc8a17c62, 0x88a17c62 }, a.words.items);
}

test "ldaddal and ldadd encode as the system assembler encodes them" {
    var a = Asm.init(std.testing.allocator);
    defer a.deinit();
    try a.ldaddal(.x, .x1, .x2, .x3);
    try a.ldaddal(.w, .x1, .x2, .x3);
    try a.ldadd(.x, .x1, .x2, .x3);
    try a.ldadd(.w, .x1, .x2, .x3);
    try std.testing.expectEqualSlices(u32, &.{ 0xf8e10062, 0xb8e10062, 0xf8210062, 0xb8210062 }, a.words.items);
}
