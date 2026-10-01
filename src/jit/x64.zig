//! An x86-64 assembler: each method appends one instruction to a byte
//! buffer. Branches to labels are rel32 and resolved by `finish`, which also
//! places the literal pool (8-byte slots read RIP-relative) after the code,
//! so the result is position independent.

const std = @import("std");

pub const Error = error{ OutOfMemory, OutOfRange, NotEncodable };

pub const Reg = enum(u4) {
    rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi, r8, r9, r10, r11, r12, r13, r14, r15,

    fn low(r: Reg) u8 {
        return @as(u8, @intFromEnum(r)) & 7;
    }
    fn high(r: Reg) u8 {
        return @as(u8, @intFromEnum(r)) >> 3;
    }
};

pub const X = enum(u4) {
    xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7, xmm8, xmm9, xmm10, xmm11, xmm12, xmm13, xmm14, xmm15,

    fn low(r: X) u8 {
        return @as(u8, @intFromEnum(r)) & 7;
    }
    fn high(r: X) u8 {
        return @as(u8, @intFromEnum(r)) >> 3;
    }
};

/// Operand size of an integer instruction.
pub const W = enum { b, d, q };

pub const Cond = enum(u4) {
    o, no, b, ae, e, ne, be, a, s, ns, p, np, l, ge, le, g,

    pub fn invert(c: Cond) Cond {
        return @enumFromInt(@intFromEnum(c) ^ 1);
    }
};

/// A memory operand: `[base + index * scale + disp]`, or `[rip + disp]` to a
/// literal slot.
pub const Mem = struct {
    base: Reg,
    index: ?Reg = null,
    scale: u2 = 0,
    disp: i32 = 0,

    pub fn at(base: Reg, disp: i32) Mem {
        return .{ .base = base, .disp = disp };
    }
    pub fn indexed(base: Reg, index: Reg, scale: u2, disp: i32) Mem {
        return .{ .base = base, .index = index, .scale = scale, .disp = disp };
    }
};

pub const Label = u32;

const Fixup = struct { at: u32, label: Label };
const Lit = struct { at: u32, value: u64 };

/// The ALU operations of the `81 /n` and `01`-style encodings.
const Alu = enum(u3) { add = 0, @"or" = 1, adc = 2, sbb = 3, @"and" = 4, sub = 5, xor = 6, cmp = 7 };

pub const Asm = struct {
    gpa: std.mem.Allocator,
    /// The current section's bytes; `other` holds the other section's.
    bytes: std.ArrayList(u8) = .empty,
    other: std.ArrayList(u8) = .empty,
    /// Whether the current section is the cold one, which `finish` places
    /// after the hot one.
    cold: bool = false,
    labels: std.ArrayList(?u32) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    lits: std.ArrayList(Lit) = .empty,

    const cold_bit: u32 = 1 << 31;

    pub fn init(gpa: std.mem.Allocator) Asm {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Asm) void {
        self.bytes.deinit(self.gpa);
        self.other.deinit(self.gpa);
        self.labels.deinit(self.gpa);
        self.fixups.deinit(self.gpa);
        self.lits.deinit(self.gpa);
    }

    pub fn pos(self: *const Asm) u32 {
        return @intCast(self.bytes.items.len);
    }

    fn here(self: *const Asm) u32 {
        return self.pos() | if (self.cold) cold_bit else 0;
    }

    /// Later bytes go to the cold section, or back to the hot one.
    pub fn section(self: *Asm, cold: bool) void {
        if (cold == self.cold) return;
        std.mem.swap(std.ArrayList(u8), &self.bytes, &self.other);
        self.cold = cold;
    }

    fn place(p: u32, hot_len: u32) u32 {
        return if (p & cold_bit != 0) (p & ~cold_bit) + hot_len else p;
    }

    fn byte(self: *Asm, b: u8) Error!void {
        try self.bytes.append(self.gpa, b);
    }
    fn int32(self: *Asm, v: i32) Error!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &buf, v, .little);
        try self.bytes.appendSlice(self.gpa, &buf);
    }
    fn int64(self: *Asm, v: u64) Error!void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        try self.bytes.appendSlice(self.gpa, &buf);
    }

    pub fn newLabel(self: *Asm) Error!Label {
        try self.labels.append(self.gpa, null);
        return @intCast(self.labels.items.len - 1);
    }

    pub fn bind(self: *Asm, l: Label) void {
        self.labels.items[l] = self.here();
    }

    pub fn labelOffset(self: *const Asm, l: Label) ?u32 {
        const p = self.labels.items[l] orelse return null;
        if (p & cold_bit != 0) return null;
        return p;
    }

    /// The code and its literal pool, labels and literals resolved. The
    /// caller owns the bytes.
    pub fn finish(self: *Asm) Error![]u8 {
        self.section(false);
        const hot_len = self.pos();
        try self.bytes.appendSlice(self.gpa, self.other.items);
        self.other.clearRetainingCapacity();
        for (self.labels.items) |*l| if (l.*) |p| {
            l.* = place(p, hot_len);
        };
        for (self.fixups.items) |*f| f.at = place(f.at, hot_len);
        for (self.lits.items) |*l| l.at = place(l.at, hot_len);
        for (self.fixups.items) |f| {
            const target = self.labels.items[f.label] orelse return Error.OutOfRange;
            const rel: i64 = @as(i64, target) - @as(i64, f.at + 4);
            std.mem.writeInt(i32, self.bytes.items[f.at..][0..4], @intCast(rel), .little);
        }
        if (self.lits.items.len != 0) {
            while (self.pos() % 8 != 0) try self.byte(0xCC);
            var seen: std.AutoHashMapUnmanaged(u64, u32) = .empty;
            defer seen.deinit(self.gpa);
            for (self.lits.items) |l| {
                const slot = try seen.getOrPut(self.gpa, l.value);
                if (!slot.found_existing) {
                    slot.value_ptr.* = self.pos();
                    try self.int64(l.value);
                }
                const rel: i64 = @as(i64, slot.value_ptr.*) - @as(i64, l.at + 4);
                std.mem.writeInt(i32, self.bytes.items[l.at..][0..4], @intCast(rel), .little);
            }
        }
        return self.gpa.dupe(u8, self.bytes.items);
    }

    // ------------------------------------------------------------ encoding --

    /// REX for a ModRM instruction with `reg` in the reg field and `m` the
    /// memory operand; `force` for byte registers 4-7 (spl..dil) and `w` for
    /// 64-bit operands.
    fn rexMem(self: *Asm, w: bool, reg: u8, m: Mem, force: bool) Error!void {
        const x: u8 = if (m.index) |i| i.high() else 0;
        const rex: u8 = 0x40 | (@as(u8, @intFromBool(w)) << 3) | ((reg >> 3) << 2) | (x << 1) | m.base.high();
        if (rex != 0x40 or force) try self.byte(rex);
    }
    fn rexRR(self: *Asm, w: bool, reg: u8, rm: u8, force: bool) Error!void {
        const rex: u8 = 0x40 | (@as(u8, @intFromBool(w)) << 3) | ((reg >> 3) << 2) | (rm >> 3);
        if (rex != 0x40 or force) try self.byte(rex);
    }

    /// ModRM, SIB and displacement for `m` with `reg` in the reg field.
    fn modrmMem(self: *Asm, reg: u8, m: Mem) Error!void {
        const r = (reg & 7) << 3;
        const base_low = m.base.low();
        const need_sib = m.index != null or base_low == 4;
        const mod: u8 = if (m.disp == 0 and base_low != 5) 0 else if (m.disp >= -128 and m.disp < 128) 1 else 2;
        if (need_sib) {
            try self.byte((mod << 6) | r | 4);
            const idx: u8 = if (m.index) |i| i.low() else 4;
            if (m.index) |i| if (i == .rsp) return Error.NotEncodable;
            try self.byte((@as(u8, m.scale) << 6) | (idx << 3) | base_low);
        } else {
            try self.byte((mod << 6) | r | base_low);
        }
        switch (mod) {
            1 => try self.byte(@bitCast(@as(i8, @intCast(m.disp)))),
            2 => try self.int32(m.disp),
            else => {},
        }
    }
    fn modrmRR(self: *Asm, reg: u8, rm: u8) Error!void {
        try self.byte(0xC0 | ((reg & 7) << 3) | (rm & 7));
    }

    fn opRR(self: *Asm, w: W, op: u8, reg: Reg, rm: Reg) Error!void {
        if (w == .b) {
            const force = @intFromEnum(reg) >= 4 or @intFromEnum(rm) >= 4;
            try self.rexRR(false, @intFromEnum(reg), @intFromEnum(rm), force);
            try self.byte(op - 1);
        } else {
            try self.rexRR(w == .q, @intFromEnum(reg), @intFromEnum(rm), false);
            try self.byte(op);
        }
        try self.modrmRR(@intFromEnum(reg), @intFromEnum(rm));
    }
    fn opRM(self: *Asm, w: W, op: u8, reg: Reg, m: Mem) Error!void {
        if (w == .b) {
            try self.rexMem(false, @intFromEnum(reg), m, @intFromEnum(reg) >= 4);
            try self.byte(op - 1);
        } else {
            try self.rexMem(w == .q, @intFromEnum(reg), m, false);
            try self.byte(op);
        }
        try self.modrmMem(@intFromEnum(reg), m);
    }

    // ---------------------------------------------------------------- moves --

    /// `dst = src`.
    pub fn mov(self: *Asm, w: W, dst: Reg, src: Reg) Error!void {
        return self.opRR(w, 0x89, src, dst);
    }
    /// `dst = [m]`.
    pub fn load(self: *Asm, w: W, dst: Reg, m: Mem) Error!void {
        return self.opRM(w, 0x8B, dst, m);
    }
    /// `[m] = src`.
    pub fn store(self: *Asm, w: W, m: Mem, src: Reg) Error!void {
        return self.opRM(w, 0x89, src, m);
    }
    /// `[m] = imm` (a byte, or a 32-bit value sign-extended for `q`).
    pub fn storeImm(self: *Asm, w: W, m: Mem, imm: i32) Error!void {
        switch (w) {
            .b => {
                try self.rexMem(false, 0, m, false);
                try self.byte(0xC6);
                try self.modrmMem(0, m);
                try self.byte(@bitCast(@as(i8, @truncate(imm))));
            },
            .d, .q => {
                try self.rexMem(w == .q, 0, m, false);
                try self.byte(0xC7);
                try self.modrmMem(0, m);
                try self.int32(imm);
            },
        }
    }
    /// `dst = zero-extended byte [m]`.
    pub fn loadU8(self: *Asm, dst: Reg, m: Mem) Error!void {
        try self.rexMem(false, @intFromEnum(dst), m, false);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, 0xB6 });
        try self.modrmMem(@intFromEnum(dst), m);
    }
    pub fn loadU16(self: *Asm, dst: Reg, m: Mem) Error!void {
        try self.rexMem(false, @intFromEnum(dst), m, false);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, 0xB7 });
        try self.modrmMem(@intFromEnum(dst), m);
    }
    /// `dst = sign-extended byte [m]`, 64 bits.
    pub fn loadI8(self: *Asm, dst: Reg, m: Mem) Error!void {
        try self.rexMem(true, @intFromEnum(dst), m, false);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, 0xBE });
        try self.modrmMem(@intFromEnum(dst), m);
    }
    pub fn loadI16(self: *Asm, dst: Reg, m: Mem) Error!void {
        try self.rexMem(true, @intFromEnum(dst), m, false);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, 0xBF });
        try self.modrmMem(@intFromEnum(dst), m);
    }
    /// `dst = sign-extended dword [m]`.
    pub fn loadI32(self: *Asm, dst: Reg, m: Mem) Error!void {
        try self.rexMem(true, @intFromEnum(dst), m, false);
        try self.byte(0x63);
        try self.modrmMem(@intFromEnum(dst), m);
    }
    /// `dst = sign-extended low dword of src`.
    pub fn movsxd(self: *Asm, dst: Reg, src: Reg) Error!void {
        try self.rexRR(true, @intFromEnum(dst), @intFromEnum(src), false);
        try self.byte(0x63);
        try self.modrmRR(@intFromEnum(dst), @intFromEnum(src));
    }
    /// `dst = sign-extended low byte (or word) of src`, 64 bits.
    pub fn movsx(self: *Asm, from: W, dst: Reg, src: Reg) Error!void {
        const force = @intFromEnum(src) >= 4;
        try self.rexRR(true, @intFromEnum(dst), @intFromEnum(src), force);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, if (from == .b) 0xBE else 0xBF });
        try self.modrmRR(@intFromEnum(dst), @intFromEnum(src));
    }
    /// `dst = zero-extended low byte (or word) of src`, 32 bits (clearing the rest).
    pub fn movzx(self: *Asm, from: W, dst: Reg, src: Reg) Error!void {
        const force = from == .b and @intFromEnum(src) >= 4;
        try self.rexRR(false, @intFromEnum(dst), @intFromEnum(src), force);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, if (from == .b) 0xB6 else 0xB7 });
        try self.modrmRR(@intFromEnum(dst), @intFromEnum(src));
    }
    /// `dst = value`, in the shortest form.
    pub fn movImm(self: *Asm, dst: Reg, value: u64) Error!void {
        if (value <= 0xFFFF_FFFF) {
            try self.rexRR(false, 0, @intFromEnum(dst), false);
            try self.byte(0xB8 + dst.low());
            return self.int32(@bitCast(@as(u32, @intCast(value))));
        }
        const s: i64 = @bitCast(value);
        if (s >= std.math.minInt(i32) and s < 0) {
            try self.rexRR(true, 0, @intFromEnum(dst), false);
            try self.byte(0xC7);
            try self.modrmRR(0, @intFromEnum(dst));
            return self.int32(@intCast(s));
        }
        try self.rexRR(true, 0, @intFromEnum(dst), false);
        try self.byte(0xB8 + dst.low());
        return self.int64(value);
    }
    pub fn lea(self: *Asm, dst: Reg, m: Mem) Error!void {
        return self.opRM(.q, 0x8D, dst, m);
    }

    // ------------------------------------------------------------------ alu --

    fn aluRR(self: *Asm, op: Alu, w: W, dst: Reg, src: Reg) Error!void {
        return self.opRR(w, (@as(u8, @intFromEnum(op)) << 3) | 1, src, dst);
    }
    fn aluImm(self: *Asm, op: Alu, w: W, dst: Reg, imm: i32) Error!void {
        const digit: u8 = @intFromEnum(op);
        if (w == .b) {
            try self.rexRR(false, 0, @intFromEnum(dst), @intFromEnum(dst) >= 4);
            try self.byte(0x80);
            try self.modrmRR(digit, @intFromEnum(dst));
            return self.byte(@bitCast(@as(i8, @truncate(imm))));
        }
        try self.rexRR(w == .q, 0, @intFromEnum(dst), false);
        if (imm >= -128 and imm < 128) {
            try self.byte(0x83);
            try self.modrmRR(digit, @intFromEnum(dst));
            return self.byte(@bitCast(@as(i8, @intCast(imm))));
        }
        // The accumulator's own form is a byte shorter.
        if (dst == .rax) {
            try self.byte((digit << 3) | 5);
            return self.int32(imm);
        }
        try self.byte(0x81);
        try self.modrmRR(digit, @intFromEnum(dst));
        return self.int32(imm);
    }
    fn aluMemImm(self: *Asm, op: Alu, w: W, m: Mem, imm: i32) Error!void {
        const digit: u8 = @intFromEnum(op);
        if (w == .b) {
            try self.rexMem(false, 0, m, false);
            try self.byte(0x80);
            try self.modrmMem(digit, m);
            return self.byte(@bitCast(@as(i8, @truncate(imm))));
        }
        try self.rexMem(w == .q, 0, m, false);
        if (imm >= -128 and imm < 128) {
            try self.byte(0x83);
            try self.modrmMem(digit, m);
            return self.byte(@bitCast(@as(i8, @intCast(imm))));
        }
        try self.byte(0x81);
        try self.modrmMem(digit, m);
        return self.int32(imm);
    }
    /// `dst op= [m]`.
    fn aluLoad(self: *Asm, op: Alu, w: W, dst: Reg, m: Mem) Error!void {
        return self.opRM(w, (@as(u8, @intFromEnum(op)) << 3) | 3, dst, m);
    }

    pub fn add(self: *Asm, w: W, dst: Reg, src: Reg) Error!void {
        return self.aluRR(.add, w, dst, src);
    }
    pub fn sub(self: *Asm, w: W, dst: Reg, src: Reg) Error!void {
        return self.aluRR(.sub, w, dst, src);
    }
    pub fn @"and"(self: *Asm, w: W, dst: Reg, src: Reg) Error!void {
        return self.aluRR(.@"and", w, dst, src);
    }
    pub fn @"or"(self: *Asm, w: W, dst: Reg, src: Reg) Error!void {
        return self.aluRR(.@"or", w, dst, src);
    }
    pub fn xor(self: *Asm, w: W, dst: Reg, src: Reg) Error!void {
        return self.aluRR(.xor, w, dst, src);
    }
    pub fn cmp(self: *Asm, w: W, a: Reg, b: Reg) Error!void {
        return self.aluRR(.cmp, w, a, b);
    }
    pub fn addImm(self: *Asm, w: W, dst: Reg, imm: i32) Error!void {
        return self.aluImm(.add, w, dst, imm);
    }
    pub fn subImm(self: *Asm, w: W, dst: Reg, imm: i32) Error!void {
        return self.aluImm(.sub, w, dst, imm);
    }
    pub fn andImm(self: *Asm, w: W, dst: Reg, imm: i32) Error!void {
        return self.aluImm(.@"and", w, dst, imm);
    }
    pub fn orImm(self: *Asm, w: W, dst: Reg, imm: i32) Error!void {
        return self.aluImm(.@"or", w, dst, imm);
    }
    pub fn xorImm(self: *Asm, w: W, dst: Reg, imm: i32) Error!void {
        return self.aluImm(.xor, w, dst, imm);
    }
    pub fn cmpImm(self: *Asm, w: W, a: Reg, imm: i32) Error!void {
        return self.aluImm(.cmp, w, a, imm);
    }
    pub fn cmpMemImm(self: *Asm, w: W, m: Mem, imm: i32) Error!void {
        return self.aluMemImm(.cmp, w, m, imm);
    }
    pub fn addMemImm(self: *Asm, w: W, m: Mem, imm: i32) Error!void {
        return self.aluMemImm(.add, w, m, imm);
    }
    pub fn cmpLoad(self: *Asm, w: W, a: Reg, m: Mem) Error!void {
        return self.aluLoad(.cmp, w, a, m);
    }
    pub fn addLoad(self: *Asm, w: W, dst: Reg, m: Mem) Error!void {
        return self.aluLoad(.add, w, dst, m);
    }
    pub fn subLoad(self: *Asm, w: W, dst: Reg, m: Mem) Error!void {
        return self.aluLoad(.sub, w, dst, m);
    }
    /// `a & b`, setting the flags only.
    pub fn @"test"(self: *Asm, w: W, a: Reg, b: Reg) Error!void {
        return self.opRR(w, 0x85, b, a);
    }
    pub fn testImm(self: *Asm, w: W, a: Reg, imm: i32) Error!void {
        if (a == .rax) {
            if (w == .b) {
                try self.byte(0xA8);
                return self.byte(@bitCast(@as(i8, @truncate(imm))));
            }
            if (w == .q) try self.byte(0x48);
            try self.byte(0xA9);
            return self.int32(imm);
        }
        if (w == .b) {
            try self.rexRR(false, 0, @intFromEnum(a), @intFromEnum(a) >= 4);
            try self.byte(0xF6);
            try self.modrmRR(0, @intFromEnum(a));
            return self.byte(@bitCast(@as(i8, @truncate(imm))));
        }
        try self.rexRR(w == .q, 0, @intFromEnum(a), false);
        try self.byte(0xF7);
        try self.modrmRR(0, @intFromEnum(a));
        return self.int32(imm);
    }
    pub fn testMemImm8(self: *Asm, m: Mem, imm: u8) Error!void {
        try self.rexMem(false, 0, m, false);
        try self.byte(0xF6);
        try self.modrmMem(0, m);
        return self.byte(imm);
    }
    /// `dst = dst * src` (low half).
    pub fn imul(self: *Asm, w: W, dst: Reg, src: Reg) Error!void {
        try self.rexRR(w == .q, @intFromEnum(dst), @intFromEnum(src), false);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, 0xAF });
        return self.modrmRR(@intFromEnum(dst), @intFromEnum(src));
    }
    pub fn imulImm(self: *Asm, w: W, dst: Reg, src: Reg, imm: i32) Error!void {
        try self.rexRR(w == .q, @intFromEnum(dst), @intFromEnum(src), false);
        if (imm >= -128 and imm < 128) {
            try self.byte(0x6B);
            try self.modrmRR(@intFromEnum(dst), @intFromEnum(src));
            return self.byte(@bitCast(@as(i8, @intCast(imm))));
        }
        try self.byte(0x69);
        try self.modrmRR(@intFromEnum(dst), @intFromEnum(src));
        return self.int32(imm);
    }

    fn unary(self: *Asm, w: W, digit: u8, r: Reg) Error!void {
        try self.rexRR(w == .q, 0, @intFromEnum(r), false);
        try self.byte(0xF7);
        return self.modrmRR(digit, @intFromEnum(r));
    }
    pub fn not(self: *Asm, w: W, r: Reg) Error!void {
        return self.unary(w, 2, r);
    }
    pub fn neg(self: *Asm, w: W, r: Reg) Error!void {
        return self.unary(w, 3, r);
    }
    /// `rdx:rax / r` signed: quotient in rax, remainder in rdx.
    pub fn idiv(self: *Asm, w: W, r: Reg) Error!void {
        return self.unary(w, 7, r);
    }
    /// Sign-extends rax into rdx (`cqo`), or eax into edx (`cdq`).
    pub fn signExtendAcc(self: *Asm, w: W) Error!void {
        if (w == .q) try self.byte(0x48);
        return self.byte(0x99);
    }

    fn shiftCl(self: *Asm, w: W, digit: u8, r: Reg) Error!void {
        try self.rexRR(w == .q, 0, @intFromEnum(r), false);
        try self.byte(0xD3);
        return self.modrmRR(digit, @intFromEnum(r));
    }
    fn shiftImm(self: *Asm, w: W, digit: u8, r: Reg, n: u8) Error!void {
        try self.rexRR(w == .q, 0, @intFromEnum(r), false);
        try self.byte(0xC1);
        try self.modrmRR(digit, @intFromEnum(r));
        return self.byte(n);
    }
    /// Shifts by `cl`.
    pub fn shlCl(self: *Asm, w: W, r: Reg) Error!void {
        return self.shiftCl(w, 4, r);
    }
    pub fn shrCl(self: *Asm, w: W, r: Reg) Error!void {
        return self.shiftCl(w, 5, r);
    }
    pub fn sarCl(self: *Asm, w: W, r: Reg) Error!void {
        return self.shiftCl(w, 7, r);
    }
    pub fn shlImm(self: *Asm, w: W, r: Reg, n: u8) Error!void {
        return self.shiftImm(w, 4, r, n);
    }
    pub fn shrImm(self: *Asm, w: W, r: Reg, n: u8) Error!void {
        return self.shiftImm(w, 5, r, n);
    }
    pub fn sarImm(self: *Asm, w: W, r: Reg, n: u8) Error!void {
        return self.shiftImm(w, 7, r, n);
    }

    /// `r8 = cond ? 1 : 0` (the low byte only).
    pub fn setcc(self: *Asm, c: Cond, r: Reg) Error!void {
        try self.rexRR(false, 0, @intFromEnum(r), @intFromEnum(r) >= 4);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, 0x90 + @as(u8, @intFromEnum(c)) });
        return self.modrmRR(0, @intFromEnum(r));
    }
    pub fn cmov(self: *Asm, c: Cond, w: W, dst: Reg, src: Reg) Error!void {
        try self.rexRR(w == .q, @intFromEnum(dst), @intFromEnum(src), false);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, 0x40 + @as(u8, @intFromEnum(c)) });
        return self.modrmRR(@intFromEnum(dst), @intFromEnum(src));
    }

    /// `if ([m] == eax) [m] = src`, with `eax` (or `rax`) the old value; locked.
    pub fn lockCmpxchg(self: *Asm, w: W, m: Mem, src: Reg) Error!void {
        try self.byte(0xF0);
        try self.rexMem(w == .q, @intFromEnum(src), m, false);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, 0xB1 });
        return self.modrmMem(@intFromEnum(src), m);
    }
    /// `[m] += src` atomically, `src` = the old value.
    pub fn lockXadd(self: *Asm, w: W, m: Mem, src: Reg) Error!void {
        try self.byte(0xF0);
        try self.rexMem(w == .q, @intFromEnum(src), m, false);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, 0xC1 });
        return self.modrmMem(@intFromEnum(src), m);
    }
    /// `[m] &= imm` atomically.
    pub fn lockAndImm(self: *Asm, w: W, m: Mem, imm: i32) Error!void {
        try self.byte(0xF0);
        try self.rexMem(w == .q, 0, m, false);
        try self.byte(0x81);
        try self.modrmMem(4, m);
        return self.int32(imm);
    }
    pub fn mfence(self: *Asm) Error!void {
        return self.bytes.appendSlice(self.gpa, &.{ 0x0F, 0xAE, 0xF0 });
    }

    // ------------------------------------------------------------ branches --

    pub fn jmp(self: *Asm, l: Label) Error!void {
        try self.byte(0xE9);
        try self.fixups.append(self.gpa, .{ .at = self.here(), .label = l });
        return self.int32(0);
    }
    pub fn jcc(self: *Asm, c: Cond, l: Label) Error!void {
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, 0x80 + @as(u8, @intFromEnum(c)) });
        try self.fixups.append(self.gpa, .{ .at = self.here(), .label = l });
        return self.int32(0);
    }
    pub fn callLabel(self: *Asm, l: Label) Error!void {
        try self.byte(0xE8);
        try self.fixups.append(self.gpa, .{ .at = self.here(), .label = l });
        return self.int32(0);
    }
    pub fn jmpReg(self: *Asm, r: Reg) Error!void {
        try self.rexRR(false, 0, @intFromEnum(r), false);
        try self.byte(0xFF);
        return self.modrmRR(4, @intFromEnum(r));
    }
    pub fn callReg(self: *Asm, r: Reg) Error!void {
        try self.rexRR(false, 0, @intFromEnum(r), false);
        try self.byte(0xFF);
        return self.modrmRR(2, @intFromEnum(r));
    }
    /// A jump to absolute `addr`, through a literal slot.
    pub fn jumpAbs(self: *Asm, addr: usize) Error!void {
        try self.bytes.appendSlice(self.gpa, &.{ 0xFF, 0x25 });
        try self.lits.append(self.gpa, .{ .at = self.here(), .value = addr });
        return self.int32(0);
    }
    /// A call of absolute `addr`, through a literal slot.
    pub fn callAbs(self: *Asm, addr: usize) Error!void {
        try self.bytes.appendSlice(self.gpa, &.{ 0xFF, 0x15 });
        try self.lits.append(self.gpa, .{ .at = self.here(), .value = addr });
        return self.int32(0);
    }
    /// `dst = the literal slot holding value`.
    pub fn loadLit(self: *Asm, dst: Reg, value: u64) Error!void {
        try self.rexRR(true, @intFromEnum(dst), 0, false);
        try self.byte(0x8B);
        try self.byte(((dst.low()) << 3) | 5);
        try self.lits.append(self.gpa, .{ .at = self.here(), .value = value });
        return self.int32(0);
    }
    pub fn ret(self: *Asm) Error!void {
        return self.byte(0xC3);
    }
    pub fn push(self: *Asm, r: Reg) Error!void {
        if (r.high() != 0) try self.byte(0x41);
        return self.byte(0x50 + r.low());
    }
    pub fn pop(self: *Asm, r: Reg) Error!void {
        if (r.high() != 0) try self.byte(0x41);
        return self.byte(0x58 + r.low());
    }
    pub fn int3(self: *Asm) Error!void {
        return self.byte(0xCC);
    }
    pub fn nop(self: *Asm) Error!void {
        return self.byte(0x90);
    }

    // ------------------------------------------------------------------ sse --

    fn sseRR(self: *Asm, prefix: ?u8, w: bool, op: u8, reg: u8, rm: u8) Error!void {
        if (prefix) |p| try self.byte(p);
        try self.rexRR(w, reg, rm, false);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, op });
        return self.modrmRR(reg, rm);
    }
    fn sseRM(self: *Asm, prefix: ?u8, w: bool, op: u8, reg: u8, m: Mem) Error!void {
        if (prefix) |p| try self.byte(p);
        try self.rexMem(w, reg, m, false);
        try self.bytes.appendSlice(self.gpa, &.{ 0x0F, op });
        return self.modrmMem(reg, m);
    }
    fn fpPrefix(double: bool) u8 {
        return if (double) 0xF2 else 0xF3;
    }

    /// `dst = [m]` (a double, or a single when `!double`).
    pub fn movsdLoad(self: *Asm, double: bool, dst: X, m: Mem) Error!void {
        return self.sseRM(fpPrefix(double), false, 0x10, @intFromEnum(dst), m);
    }
    pub fn movsdStore(self: *Asm, double: bool, m: Mem, src: X) Error!void {
        return self.sseRM(fpPrefix(double), false, 0x11, @intFromEnum(src), m);
    }
    pub fn movapd(self: *Asm, dst: X, src: X) Error!void {
        return self.sseRR(0x66, false, 0x28, @intFromEnum(dst), @intFromEnum(src));
    }
    /// `dst = [m]`, all 16 bytes, `m` 16-byte aligned: one access on a processor with AVX.
    pub fn movdqaLoad(self: *Asm, dst: X, m: Mem) Error!void {
        return self.sseRM(0x66, false, 0x6F, @intFromEnum(dst), m);
    }
    /// `[m] = src`, all 16 bytes, `m` 16-byte aligned: one access on a processor with AVX.
    pub fn movdqaStore(self: *Asm, m: Mem, src: X) Error!void {
        return self.sseRM(0x66, false, 0x7F, @intFromEnum(src), m);
    }
    /// `dst = [m]`, all 16 bytes, `m` of any alignment.
    pub fn movdquLoad(self: *Asm, dst: X, m: Mem) Error!void {
        return self.sseRM(0xF3, false, 0x6F, @intFromEnum(dst), m);
    }
    /// `[m] = src`, all 16 bytes, `m` of any alignment.
    pub fn movdquStore(self: *Asm, m: Mem, src: X) Error!void {
        return self.sseRM(0xF3, false, 0x7F, @intFromEnum(src), m);
    }
    /// `dst`'s high quadword = `src`'s low one; its low one stays.
    pub fn punpcklqdq(self: *Asm, dst: X, src: X) Error!void {
        return self.sseRR(0x66, false, 0x6C, @intFromEnum(dst), @intFromEnum(src));
    }
    /// `dst`'s low quadword = its high one (with `src` the same register).
    pub fn punpckhqdq(self: *Asm, dst: X, src: X) Error!void {
        return self.sseRR(0x66, false, 0x6D, @intFromEnum(dst), @intFromEnum(src));
    }
    /// The bits of general `src` moved to `dst` (`q` 64, `d` 32).
    pub fn movToX(self: *Asm, w: W, dst: X, src: Reg) Error!void {
        return self.sseRR(0x66, w == .q, 0x6E, @intFromEnum(dst), @intFromEnum(src));
    }
    pub fn movFromX(self: *Asm, w: W, dst: Reg, src: X) Error!void {
        return self.sseRR(0x66, w == .q, 0x7E, @intFromEnum(src), @intFromEnum(dst));
    }
    pub fn addsd(self: *Asm, double: bool, dst: X, src: X) Error!void {
        return self.sseRR(fpPrefix(double), false, 0x58, @intFromEnum(dst), @intFromEnum(src));
    }
    pub fn mulsd(self: *Asm, double: bool, dst: X, src: X) Error!void {
        return self.sseRR(fpPrefix(double), false, 0x59, @intFromEnum(dst), @intFromEnum(src));
    }
    pub fn subsd(self: *Asm, double: bool, dst: X, src: X) Error!void {
        return self.sseRR(fpPrefix(double), false, 0x5C, @intFromEnum(dst), @intFromEnum(src));
    }
    pub fn divsd(self: *Asm, double: bool, dst: X, src: X) Error!void {
        return self.sseRR(fpPrefix(double), false, 0x5E, @intFromEnum(dst), @intFromEnum(src));
    }
    pub fn sqrtsd(self: *Asm, double: bool, dst: X, src: X) Error!void {
        return self.sseRR(fpPrefix(double), false, 0x51, @intFromEnum(dst), @intFromEnum(src));
    }
    /// Compares, setting ZF, PF and CF (unordered sets all three).
    pub fn ucomisd(self: *Asm, double: bool, a: X, b: X) Error!void {
        return self.sseRR(if (double) 0x66 else null, false, 0x2E, @intFromEnum(a), @intFromEnum(b));
    }
    pub fn xorpd(self: *Asm, dst: X, src: X) Error!void {
        return self.sseRR(0x66, false, 0x57, @intFromEnum(dst), @intFromEnum(src));
    }
    /// Signed integer `src` (`q` 64, `d` 32 bits) to float `dst`.
    pub fn cvtsi2sd(self: *Asm, double: bool, dst: X, w: W, src: Reg) Error!void {
        return self.sseRR(fpPrefix(double), w == .q, 0x2A, @intFromEnum(dst), @intFromEnum(src));
    }
    /// Float to signed integer, truncating; an out-of-range value or NaN
    /// gives the minimum integer, which Kotlin's conversion does not.
    pub fn cvttsd2si(self: *Asm, double: bool, w: W, dst: Reg, src: X) Error!void {
        return self.sseRR(fpPrefix(double), w == .q, 0x2C, @intFromEnum(dst), @intFromEnum(src));
    }
    /// Double from single (`to_double`), or single from double.
    pub fn cvtFloat(self: *Asm, to_double: bool, dst: X, src: X) Error!void {
        return self.sseRR(if (to_double) 0xF3 else 0xF2, false, 0x5A, @intFromEnum(dst), @intFromEnum(src));
    }
};
