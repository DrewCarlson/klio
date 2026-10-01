//! The baseline compiler's macro assembler: the operations its op templates
//! are written in, over role registers, for AArch64 and x86-64. Compiled code
//! enters with the handler arguments in place (the context, the frame, its
//! registers, the code; the pc and block are set again before any handler is
//! called, so their registers are scratch in between).

const std = @import("std");
const builtin = @import("builtin");
const jit = @import("jit");

pub const Error = error{ OutOfMemory, OutOfRange, NotEncodable, Unsupported, PinKind };

/// A scratch register.
pub const T = enum { t0, t1, t2, t3 };
/// A floating-point scratch register.
pub const FR = enum { f0, f1 };

/// Code set out of the way (`cold`): the label after it where the code was
/// cold already, else none.
pub const Cold = struct { after: ?u32 };
pub const Wd = enum { w32, w64 };

/// Whether the target has AArch64's single-instruction atomics (LSE), as every
/// Apple core does; a baseline ARMv8.0 target keeps exclusive pairs.
const has_lse = builtin.cpu.arch == .aarch64 and std.Target.aarch64.featureSetHas(builtin.cpu.features, .lse);

/// The longest run `copyFrom` copies: the reach of a pair store's offset.
pub const copy_max: usize = 512;

/// Conditions after a signed integer compare.
pub const Cond = enum { eq, ne, lt, le, gt, ge };

/// A register of the frame kept in a machine register while a loop runs
/// (`jit/types`): its payload lives in machine register `reg` of the backend's
/// `pin_regs`, and its tag word in the frame holds `kind` throughout.
/// A frame register a loop keeps in machine register `reg`, of kind `kind` throughout;
/// `temp` for one its loop writes before reading, unwritten on the way in.
pub const Pin = struct { vreg: u32, reg: u8, kind: u8, temp: bool = false };

/// A pinned register's tag or value would change its kind: the compile gives
/// up its pins and starts again without them.
pub const PinError = error{PinKind};

/// The registers the register operands of the ops name: the frame's, or a
/// callee's compiled into its caller, `off` registers into the thread's
/// inline registers, whose address the inline base register holds.
pub const Win = struct {
    inline_area: bool = false,
    off: u32 = 0,
};

pub const A64 = struct {
    const A = jit.a64;
    a: A.Asm,
    /// The window register operands address (`Win`).
    win_base: A.Reg = regs,
    win_off: u32 = 0,
    /// The frame's registers kept in machine registers here (`Pin`).
    pins: []const Pin = &.{},

    /// The machine registers pins live in: free between exits, since a handler call
    /// sets the pc and block registers again and the others hold nothing across an op.
    pub const pin_regs = [_]A.Reg{ .x7, .x8, .x13, .x4, .x5 };
    pub const n_pin_regs = pin_regs.len;

    /// The pin of register `r` of the frame's window, if it has one.
    fn pinned(m: *const A64, r: u32) ?Pin {
        if (m.win_base != regs or m.pins.len == 0) return null;
        const v = m.win_off + r;
        for (m.pins) |p| if (p.vreg == v) return p;
        return null;
    }

    /// Whether register `r` is a pinned temporary, whose frame tag was set on the way into
    /// its loop.
    pub fn isTempPin(m: *const A64, r: u32) bool {
        const p = m.pinned(r) orelse return false;
        return p.temp;
    }

    /// Every pin's payload to its register in the frame, whose tag holds the pin's kind.
    pub fn writeBackPins(m: *A64) Error!void {
        for (m.pins) |p| {
            const b, const o = try m.reach(regs, p.vreg * 16);
            try m.a.str(.x, pin_regs[p.reg], b, o);
        }
    }
    /// Every pin's payload from its register in the frame.
    pub fn loadPins(m: *A64) Error!void {
        for (m.pins) |p| {
            const b, const o = try m.reach(regs, p.vreg * 16);
            try m.a.ldr(.x, pin_regs[p.reg], b, o);
        }
    }

    const ctx: A.Reg = .x0;
    const frame: A.Reg = .x1;
    const regs: A.Reg = .x2;
    const pc_r: A.Reg = .x4;
    const blk_r: A.Reg = .x5;
    /// Address scratch for offsets the load and store forms cannot reach.
    const addr: A.Reg = .x15;
    /// The thread's inline registers while a callee compiled into its
    /// caller runs.
    const inl: A.Reg = .x6;

    pub const Label = A.Label;

    pub fn init(gpa: std.mem.Allocator) A64 {
        return .{ .a = A.Asm.init(gpa) };
    }
    pub fn deinit(m: *A64) void {
        m.a.deinit();
    }
    pub fn offset(m: *const A64) u32 {
        return m.a.pos() * 4;
    }
    pub fn finish(m: *A64) Error![]u8 {
        return m.a.finish();
    }
    pub fn label(m: *A64) Error!Label {
        return m.a.newLabel();
    }
    pub fn bind(m: *A64, l: Label) void {
        m.a.bind(l);
    }
    pub fn jump(m: *A64, l: Label) Error!void {
        return m.a.b(l);
    }

    fn t(r: T) A.Reg {
        return switch (r) {
            .t0 => .x9,
            .t1 => .x10,
            .t2 => .x11,
            .t3 => .x12,
        };
    }
    fn f(r: FR) A.V {
        return switch (r) {
            .f0 => .v16,
            .f1 => .v17,
        };
    }
    fn wd(w: Wd) A.W {
        return if (w == .w64) .x else .w;
    }
    fn cond(c: Cond) A.Cond {
        return switch (c) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
        };
    }

    /// `base + off` as a base register and an offset every access form
    /// reaches (up to 4095, the byte forms' limit).
    fn reach(m: *A64, base: A.Reg, off: u32) Error!struct { A.Reg, i32 } {
        if (off <= 4095) return .{ base, @intCast(off) };
        try m.a.movImm(.x, addr, off);
        try m.a.add(.x, addr, base, addr);
        return .{ addr, 0 };
    }

    /// `d` = the tag of register `r` (the byte after the payload, its low six bits).
    /// A register's words are read whole, as they are written (`storePayload`): this
    /// core serves a load from a store in its buffer only when the two are one size.
    pub fn loadTag(m: *A64, d: T, r: u32, tag_off: u32) Error!void {
        if (m.pinned(r)) |p| return m.a.movImm(.w, t(d), p.kind);
        const b, const o = try m.reach(m.win_base, m.slot(r) + tag_off);
        try m.a.ldr(.x, t(d), b, o);
        try m.a.andImm(.w, t(d), t(d), 0x3f);
    }
    /// To `fail` unless register `r` holds tag `tag`.
    pub fn guardTag(m: *A64, r: u32, tag_off: u32, tag: u8, fail: Label) Error!void {
        if (m.pinned(r)) |p| {
            if (p.kind != tag) try m.a.b(fail);
            return;
        }
        try m.loadTag(.t3, r, tag_off);
        try m.a.cmpImm(.w, t(.t3), tag);
        try m.a.bCond(.ne, fail);
    }
    /// Traps unless `d`, a tag, is `tag`: a pinned register takes only values of its
    /// kind, as the kinds say; a break here is a wrong kind.
    fn guardKnownTag(m: *A64, d: T, tag: u8) Error!void {
        const ok = try m.a.newLabel();
        try m.a.cmpImm(.w, t(d), tag);
        try m.a.bCond(.eq, ok);
        try m.a.brk(1);
        m.a.bind(ok);
    }
    pub fn cmpTagImm(m: *A64, d: T, tag: u8) Error!void {
        try m.a.cmpImm(.w, t(d), tag);
    }
    /// `d` = register `r`'s payload; of a 32-bit one, the low half (the rest is padding
    /// the interpreter may leave as it was).
    pub fn loadPayload(m: *A64, w: Wd, d: T, r: u32) Error!void {
        _ = w;
        if (m.pinned(r)) |p| return m.a.mov(.x, t(d), pin_regs[p.reg]);
        const b, const o = try m.reach(m.win_base, m.slot(r));
        try m.a.ldr(.x, t(d), b, o);
    }
    /// `d` = register `r`'s payload byte (a Bool's), the rest of the word cleared.
    pub fn loadPayloadByte(m: *A64, d: T, r: u32) Error!void {
        if (m.pinned(r)) |p| return m.a.andImm(.w, t(d), pin_regs[p.reg], 0xff);
        const b, const o = try m.reach(m.win_base, m.slot(r));
        try m.a.ldr(.x, t(d), b, o);
        try m.a.andImm(.w, t(d), t(d), 0xff);
    }
    /// A register's word is written whole: a narrower store under a later load of
    /// the word would keep the load from taking its bytes from the store buffer.
    /// A 32-bit payload's upper bytes, a Bool's and the bytes after the tag are
    /// padding, and a 32-bit result's upper half is zero here.
    pub fn storePayload(m: *A64, w: Wd, r: u32, s: T) Error!void {
        _ = w;
        if (m.pinned(r)) |p| return m.a.mov(.x, pin_regs[p.reg], t(s));
        const b, const o = try m.reach(m.win_base, m.slot(r));
        try m.a.str(.x, t(s), b, o);
    }
    pub fn storePayloadByte(m: *A64, r: u32, s: T) Error!void {
        if (m.pinned(r)) |p| return m.a.mov(.x, pin_regs[p.reg], t(s));
        const b, const o = try m.reach(m.win_base, m.slot(r));
        try m.a.str(.x, t(s), b, o);
    }
    /// Register `r`'s tag word = `tag`, through scratch `s`.
    pub fn storeTag(m: *A64, r: u32, tag_off: u32, tag: u8, s: T) Error!void {
        if (m.pinned(r)) |p| {
            if (p.kind != tag) return Error.PinKind;
            return;
        }
        try m.a.movImm(.w, t(s), tag);
        const b, const o = try m.reach(m.win_base, m.slot(r) + tag_off);
        try m.a.str(.x, t(s), b, o);
    }
    /// Register `r` = the 16 bytes `v`.
    pub fn storeValue(m: *A64, r: u32, v: [16]u8) Error!void {
        if (m.pinned(r)) |p| {
            if (v[8] & 0x3f != p.kind) return Error.PinKind;
            return m.a.movImm(.x, pin_regs[p.reg], std.mem.readInt(u64, v[0..8], .little));
        }
        try m.storeBytes(m.win_base, m.slot(r), &v);
    }
    /// `bytes` stored at `base + off`, eight at a time.
    fn storeBytes(m: *A64, base: A.Reg, off: u32, bytes: []const u8) Error!void {
        var i: usize = 0;
        while (i < bytes.len) : (i += 8) {
            const n = @min(8, bytes.len - i);
            var word: u64 = 0;
            for (0..n) |k| word |= @as(u64, bytes[i + k]) << @intCast(k * 8);
            try m.a.movImm(.x, t(.t0), word);
            const b, const o = try m.reach(base, off + @as(u32, @intCast(i)));
            if (n == 8) try m.a.str(.x, t(.t0), b, o) else if (n == 4) try m.a.str(.w, t(.t0), b, o) else return Error.Unsupported;
        }
    }
    pub fn storeFrameBytes(m: *A64, off: u32, bytes: []const u8) Error!void {
        return m.storeBytes(frame, off, bytes);
    }
    /// Register `d` = register `s`, all 16 bytes.
    pub fn copyValue(m: *A64, d: u32, s: u32) Error!void {
        const dp = m.pinned(d);
        const sp = m.pinned(s);
        if (dp != null or sp != null) {
            // A pinned destination takes a value of its kind, as the kinds say.
            if (dp) |x| if (sp) |y| {
                if (x.kind != y.kind) return Error.PinKind;
                return m.a.mov(.x, pin_regs[x.reg], pin_regs[y.reg]);
            };
            try m.loadPayload(.w64, .t0, s);
            try m.loadTag(.t1, s, 8);
            if (dp) |x| {
                if (sp == null) try m.guardKnownTag(.t1, x.kind);
                return m.a.mov(.x, pin_regs[x.reg], t(.t0));
            }
            const db, const do = try m.reach(m.win_base, m.slot(d));
            try m.a.str(.x, t(.t0), db, do);
            try m.a.str(.x, t(.t1), db, do + 8);
            return;
        }
        const sb, const so = try m.reach(m.win_base, m.slot(s));
        try m.a.ldr(.x, t(.t0), sb, so);
        try m.a.ldr(.x, t(.t1), sb, so + 8);
        const db, const do = try m.reach(m.win_base, m.slot(d));
        try m.a.str(.x, t(.t0), db, do);
        try m.a.str(.x, t(.t1), db, do + 8);
    }

    pub fn movImm(m: *A64, d: T, v: u64) Error!void {
        try m.a.movImm(.x, t(d), v);
    }
    pub fn add(m: *A64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.a.add(wd(w), t(d), t(x), t(y));
    }
    pub fn sub(m: *A64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.a.sub(wd(w), t(d), t(x), t(y));
    }
    pub fn mul(m: *A64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.a.mul(wd(w), t(d), t(x), t(y));
    }
    pub fn andR(m: *A64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.a.@"and"(wd(w), t(d), t(x), t(y));
    }
    pub fn orR(m: *A64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.a.orr(wd(w), t(d), t(x), t(y));
    }
    pub fn xorR(m: *A64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.a.eor(wd(w), t(d), t(x), t(y));
    }
    /// Shifts by `y`'s low 5 (32-bit) or 6 (64-bit) bits, as Kotlin's do.
    pub fn shl(m: *A64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.a.lslv(wd(w), t(d), t(x), t(y));
    }
    pub fn sar(m: *A64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.a.asrv(wd(w), t(d), t(x), t(y));
    }
    pub fn shr(m: *A64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.a.lsrv(wd(w), t(d), t(x), t(y));
    }
    pub fn neg(m: *A64, w: Wd, d: T, x: T) Error!void {
        try m.a.neg(wd(w), t(d), t(x));
    }
    /// `d` = the bits of `x` inverted.
    pub fn notR(m: *A64, w: Wd, d: T, x: T) Error!void {
        try m.a.mvn(wd(w), t(d), t(x));
    }
    /// `d` = `x / y` truncated, or with `rem` its remainder, `y` neither 0 nor -1 (the
    /// quotient's overflow): `x` is t0, `y` t1 and `d` t2 on every backend.
    pub fn divRem(m: *A64, w: Wd, rem: bool, d: T, x: T, y: T) Error!void {
        if (!rem) return m.a.sdiv(wd(w), t(d), t(x), t(y));
        try m.a.sdiv(wd(w), addr, t(x), t(y));
        try m.a.msub(wd(w), t(d), addr, t(y), t(x));
    }
    pub fn addImm(m: *A64, w: Wd, d: T, x: T, v: u32) Error!void {
        try m.a.addImm(wd(w), t(d), t(x), v);
    }
    pub fn subImm(m: *A64, w: Wd, d: T, x: T, v: u32) Error!void {
        try m.a.subImm(wd(w), t(d), t(x), v);
    }
    pub fn xorImm1(m: *A64, d: T, x: T) Error!void {
        try m.a.eorImm(.w, t(d), t(x), 1);
    }
    /// 32-bit to 64-bit, sign-extending.
    pub fn signExtend32(m: *A64, d: T, x: T) Error!void {
        try m.a.sxtw(t(d), t(x));
    }
    /// The low 32 bits of `x`, zero-extended.
    pub fn zeroExtend32(m: *A64, d: T, x: T) Error!void {
        try m.a.mov(.w, t(d), t(x));
    }
    pub fn cmp(m: *A64, w: Wd, x: T, y: T) Error!void {
        try m.a.cmp(wd(w), t(x), t(y));
    }
    /// `d` = 1 when `c` holds after the last compare, else 0.
    pub fn setCond(m: *A64, d: T, c: Cond) Error!void {
        try m.a.cset(.w, t(d), cond(c));
    }
    pub fn bCond(m: *A64, c: Cond, l: Label) Error!void {
        try m.a.bCond(cond(c), l);
    }
    /// To `l` when `x` (its low 32 bits) is zero.
    pub fn bZero(m: *A64, x: T, l: Label) Error!void {
        try m.a.cbz(.w, t(x), l);
    }
    pub fn bNonZero(m: *A64, x: T, l: Label) Error!void {
        try m.a.cbnz(.w, t(x), l);
    }
    /// To `l` when bit `bit` of `x` is set. A test and a conditional branch
    /// rather than `tbnz`, whose 32 KB reach a large function's slow paths
    /// exceed.
    pub fn bBit(m: *A64, x: T, bit: u6, l: Label) Error!void {
        try m.a.tstImm(.x, t(x), @as(u64, 1) << bit);
        try m.a.bCond(.ne, l);
    }
    /// To `l` when bit `bit` of `x` is clear.
    pub fn bBitClear(m: *A64, x: T, bit: u6, l: Label) Error!void {
        try m.a.tstImm(.x, t(x), @as(u64, 1) << bit);
        try m.a.bCond(.eq, l);
    }

    /// `d` = the word at the context's field `off`.
    pub fn loadCtx(m: *A64, d: T, off: u32) Error!void {
        const b, const o = try m.reach(ctx, off);
        try m.a.ldr(.x, t(d), b, o);
    }
    pub fn loadFrame(m: *A64, d: T, off: u32) Error!void {
        const b, const o = try m.reach(frame, off);
        try m.a.ldr(.x, t(d), b, o);
    }
    /// `d` = the word at `[x + off]`.
    pub fn loadAt(m: *A64, w: Wd, d: T, x: T, off: u32) Error!void {
        const b, const o = try m.reach(t(x), off);
        try m.a.ldr(if (w == .w64) .x else .w, t(d), b, o);
    }
    pub fn storeAt(m: *A64, w: Wd, x: T, off: u32, s: T) Error!void {
        const b, const o = try m.reach(t(x), off);
        try m.a.str(if (w == .w64) .x else .w, t(s), b, o);
    }
    /// Whether this build's CPU has the lighter acquire load (`ldapr`), which is
    /// what an acquire load compiles to in the interpreter too.
    const rcpc = std.Target.aarch64.featureSetHas(builtin.cpu.features, .rcpc);

    /// `d` = the word at `[x + off]` with acquire ordering.
    pub fn loadAcquire(m: *A64, w: Wd, d: T, x: T, off: u32) Error!void {
        var base = t(x);
        if (off != 0) {
            try m.a.movImm(.x, addr, off);
            try m.a.add(.x, addr, t(x), addr);
            base = addr;
        }
        if (rcpc) try m.a.ldapr(wd(w), t(d), base) else try m.a.ldar(wd(w), t(d), base);
    }
    /// `d` = the 32-bit word at absolute `address`.
    pub fn loadAbs32(m: *A64, d: T, address: usize) Error!void {
        try m.a.ldrLit(t(d), address);
        try m.a.ldr(.w, t(d), t(d), 0);
    }
    /// Register `r`'s payload word `word` (0 or 1) = the word at `[x + off]`.
    pub fn copyWordToReg(m: *A64, r: u32, word: u32, x: T, off: u32, s: T) Error!void {
        if (m.pinned(r) != null) return Error.PinKind;
        try m.loadAt(.w64, s, x, off);
        const b, const o = try m.reach(m.win_base, m.slot(r) + word * 8);
        try m.a.str(.x, t(s), b, o);
    }
    /// Register `r` = the 16 bytes at `[x + off]`.
    pub fn copyValueFrom(m: *A64, r: u32, x: T, off: u32) Error!void {
        try m.copyWordToReg(r, 0, x, off, .t1);
        try m.copyWordToReg(r, 1, x, off + 8, .t1);
    }

    pub const FOp = enum { add, sub, mul, div };

    /// `f` = register `r`'s payload as a double (or a single when `!dbl`).
    /// A single is read and written in its register's whole word, as the other
    /// payloads are: a single's register holds it zero-extended.
    pub fn loadF(m: *A64, dbl: bool, fr: FR, r: u32) Error!void {
        _ = dbl;
        // A pinned register holds an integer kind: this read sits behind a check of its
        // tag against a float's, which always fails, and only needs to assemble.
        if (m.pinned(r)) |p| return m.a.fmovToV(.x, fv(fr), pin_regs[p.reg]);
        const b, const o = try m.reach(m.win_base, m.slot(r));
        try m.a.ldrF(.d, fv(fr), b, o);
    }
    pub fn storeF(m: *A64, dbl: bool, r: u32, fr: FR) Error!void {
        _ = dbl;
        if (m.pinned(r) != null) return Error.PinKind;
        const b, const o = try m.reach(m.win_base, m.slot(r));
        try m.a.strF(.d, fv(fr), b, o);
    }
    /// `fr` = the float whose bits are `bits` (the low 32 for a single).
    pub fn movF(m: *A64, dbl: bool, fr: FR, bits: u64) Error!void {
        try m.a.movImm(.x, t(.t1), bits);
        try m.a.fmovToV(if (dbl) .x else .w, fv(fr), t(.t1));
    }
    pub fn fop(m: *A64, op: FOp, dbl: bool, d: FR, x: FR, y: FR) Error!void {
        const w: A.F = if (dbl) .d else .s;
        switch (op) {
            .add => try m.a.fadd(w, fv(d), fv(x), fv(y)),
            .sub => try m.a.fsub(w, fv(d), fv(x), fv(y)),
            .mul => try m.a.fmul(w, fv(d), fv(x), fv(y)),
            .div => try m.a.fdiv(w, fv(d), fv(x), fv(y)),
        }
    }
    /// `d` = 1 when `x c y` holds as IEEE compares hold: every compare but
    /// `ne` is false for an unordered pair.
    pub fn fcmpSet(m: *A64, dbl: bool, d: T, x: FR, y: FR, c: Cond) Error!void {
        try m.a.fcmp(if (dbl) .d else .s, fv(x), fv(y));
        const ac: A.Cond = switch (c) {
            .lt => .mi,
            .le => .ls,
            .gt => .gt,
            .ge => .ge,
            .eq => .eq,
            .ne => .ne,
        };
        try m.a.cset(.w, t(d), ac);
    }
    fn fv(r: FR) A.V {
        return f(r);
    }

    /// To `l` when the low 16 bits of `x` are zero.
    pub fn bLow16Zero(m: *A64, x: T, l: Label) Error!void {
        try m.a.tstImm(.x, t(x), 0xFFFF);
        try m.a.bCond(.eq, l);
    }
    /// Register `r`'s word `word` (0 the payload, 1 the tag's) = `s`.
    pub fn storeRegWord(m: *A64, r: u32, word: u32, s: T) Error!void {
        if (m.pinned(r)) |p| {
            // The tag word stays the pin's kind, which the kinds say the value has.
            if (word == 0) try m.a.mov(.x, pin_regs[p.reg], t(s));
            return;
        }
        const b, const o = try m.reach(m.win_base, m.slot(r) + word * 8);
        try m.a.str(.x, t(s), b, o);
    }

    /// `d` = the byte at `[x + off]`.
    pub fn loadByteAt(m: *A64, d: T, x: T, off: u32) Error!void {
        const b, const o = try m.reach(t(x), off);
        try m.a.ldr(.b, t(d), b, o);
    }
    /// `d` = the byte at `[x]`, with acquire ordering.
    pub fn loadAcquireByte(m: *A64, d: T, x: T) Error!void {
        try m.a.ldarb(t(d), t(x));
    }
    pub fn lsrImm(m: *A64, w: Wd, d: T, x: T, n: u6) Error!void {
        try m.a.lsrImm(wd(w), t(d), t(x), n);
    }
    /// To `l` when all 64 bits of `x` are zero.
    pub fn bZero64(m: *A64, x: T, l: Label) Error!void {
        try m.a.cbz(.x, t(x), l);
    }
    /// `d` = `x & imm`, `imm` a mask of one run of ones (or its inverse).
    pub fn andImm(m: *A64, w: Wd, d: T, x: T, imm: i32) Error!void {
        const v: u64 = @bitCast(@as(i64, imm));
        try m.a.andImm(wd(w), t(d), t(x), if (w == .w64) v else v & 0xffff_ffff);
    }
    pub fn shlImm(m: *A64, w: Wd, d: T, x: T, n: u6) Error!void {
        try m.a.lslImm(wd(w), t(d), t(x), n);
    }
    /// To `l` when `x`, 64 bits, is negative.
    pub fn bNegative(m: *A64, x: T, l: Label) Error!void {
        try m.a.cmpImm(.x, t(x), 0);
        try m.a.bCond(.lt, l);
    }
    /// The 32-bit word at `[x + off]` = `new` if it holds `expect`, with
    /// acquire ordering; to `fail`, storing nothing, if it does not.
    pub fn cas32(m: *A64, x: T, off: u32, expect: T, new: T, fail: Label) Error!void {
        try m.a.movImm(.x, addr, off);
        try m.a.add(.x, addr, t(x), addr);
        const retry = try m.a.newLabel();
        m.a.bind(retry);
        try m.a.ldaxr(.w, .x14, addr);
        try m.a.cmp(.w, .x14, t(expect));
        try m.a.bCond(.ne, fail);
        try m.a.stlxr(.w, .x17, t(new), addr);
        try m.a.cbnz(.w, .x17, retry);
    }
    /// The 32-bit word at `[x + off]` &= `mask` atomically, with release ordering.
    pub fn atomicAnd32(m: *A64, x: T, off: u32, mask: u32) Error!void {
        try m.a.movImm(.x, addr, off);
        try m.a.add(.x, addr, t(x), addr);
        const retry = try m.a.newLabel();
        m.a.bind(retry);
        try m.a.ldaxr(.w, .x14, addr);
        try m.a.andImm(.w, .x14, .x14, mask);
        try m.a.stlxr(.w, .x17, .x14, addr);
        try m.a.cbnz(.w, .x17, retry);
    }
    /// The 32-bit word at `[x + off]` += `delta` atomically, acquire and release; `old` =
    /// the word before.
    pub fn atomicAdd32(m: *A64, x: T, off: u32, delta: i32, old: T) Error!void {
        return m.atomicAdd(.w32, x, off, delta, old);
    }
    /// The word of width `w` at `[x + off]` += `delta` atomically, acquire and release;
    /// `old` = the word before.
    pub fn atomicAdd(m: *A64, w: Wd, x: T, off: u32, delta: i32, old: T) Error!void {
        try m.a.movImm(.x, addr, off);
        try m.a.add(.x, addr, t(x), addr);
        if (comptime has_lse) {
            try m.a.movImm(.x, .x14, @bitCast(@as(i64, delta)));
            return m.a.ldaddal(wd(w), .x14, t(old), addr);
        }
        return m.exclusiveAdd(w, delta, old);
    }
    /// `atomicAdd` with no ordering, for a counter nothing reads through: a
    /// store before it need not have landed first.
    pub fn atomicAddRelaxed(m: *A64, w: Wd, x: T, off: u32, delta: i32, old: T) Error!void {
        try m.a.movImm(.x, addr, off);
        try m.a.add(.x, addr, t(x), addr);
        if (comptime has_lse) {
            try m.a.movImm(.x, .x14, @bitCast(@as(i64, delta)));
            return m.a.ldadd(wd(w), .x14, t(old), addr);
        }
        return m.exclusiveAdd(w, delta, old);
    }
    /// `out` = the 32-bit word at `[x + off]`, zero-extended, an identity taken on the
    /// first ask: where it is 0, the low word of one past the counter at `counter` (bumped
    /// with no ordering, 1 in place of 0) is swapped in, or the one another thread swapped
    /// in first is read. `x` is kept.
    pub fn takeIdentity(m: *A64, x: T, off: u32, out: T, counter: usize) Error!void {
        const done = try m.a.newLabel();
        try m.loadAt(.w32, out, x, off);
        try m.a.cbnz(.w, t(out), done);
        try m.a.movImm(.x, addr, counter);
        if (comptime has_lse) {
            try m.a.movImm(.x, .x14, 1);
            try m.a.ldadd(.x, .x14, t(out), addr);
        } else try m.exclusiveAdd(.w64, 1, out);
        try m.a.addImm(.w, t(out), t(out), 1);
        try m.a.cmpImm(.w, t(out), 0);
        try m.a.csinc(.w, t(out), t(out), .zr, .ne);
        try m.a.movImm(.x, addr, off);
        try m.a.add(.x, addr, t(x), addr);
        if (comptime has_lse) {
            try m.a.movImm(.x, .x14, 0);
            try m.a.cas(.w, .x14, t(out), addr);
            try m.a.cbz(.w, .x14, done);
            try m.a.mov(.w, t(out), .x14);
        } else {
            const retry = try m.a.newLabel();
            const lost = try m.a.newLabel();
            m.a.bind(retry);
            try m.a.ldaxr(.w, .x14, addr);
            try m.a.cbnz(.w, .x14, lost);
            try m.a.stlxr(.w, .x17, t(out), addr);
            try m.a.cbnz(.w, .x17, retry);
            try m.a.b(done);
            m.a.bind(lost);
            try m.a.mov(.w, t(out), .x14);
        }
        m.a.bind(done);
    }
    fn exclusiveAdd(m: *A64, w: Wd, delta: i32, old: T) Error!void {
        const retry = try m.a.newLabel();
        m.a.bind(retry);
        try m.a.ldaxr(wd(w), t(old), addr);
        if (delta >= 0) try m.a.addImm(wd(w), .x14, t(old), @intCast(delta)) else try m.a.subImm(wd(w), .x14, t(old), @intCast(-delta));
        try m.a.stlxr(wd(w), .x17, .x14, addr);
        try m.a.cbnz(.w, .x17, retry);
    }
    /// `bytes` copied to `[x]` from where they lie, through t0, t1 and t2 a pair
    /// of words at a time; `x` is t3 and `bytes` a multiple of 16 no longer
    /// than `copy_max`. The bytes must stay where they are for the code's life.
    pub fn copyFrom(m: *A64, x: T, bytes: []const u8) Error!void {
        std.debug.assert(x == .t3 and bytes.len % 16 == 0 and bytes.len <= copy_max);
        try m.a.movImm(.x, t(.t0), @intFromPtr(bytes.ptr));
        var off: i32 = 0;
        while (off < bytes.len) : (off += 16) {
            try m.a.ldp(t(.t1), t(.t2), t(.t0), off);
            try m.a.stp(t(.t1), t(.t2), t(x), off);
        }
    }
    /// `d1`, `d2` = the two words at `[x + off]`, in one access where `x + off`
    /// is 16-byte aligned on a processor with LSE2.
    pub fn loadPair(m: *A64, d1: T, d2: T, x: T, off: u32) Error!void {
        const b, const o = try m.reachPair(t(x), off);
        try m.a.ldp(t(d1), t(d2), b, o);
    }
    /// The two words at `[x + off]` = `s1`, `s2`, in one access as `loadPair`
    /// reads them.
    pub fn storePair(m: *A64, x: T, off: u32, s1: T, s2: T) Error!void {
        const b, const o = try m.reachPair(t(x), off);
        try m.a.stp(t(s1), t(s2), b, o);
    }
    fn reachPair(m: *A64, base: A.Reg, off: u32) Error!struct { A.Reg, i32 } {
        if (off <= 504) return .{ base, @intCast(off) };
        try m.a.movImm(.x, addr, off);
        try m.a.add(.x, addr, base, addr);
        return .{ addr, 0 };
    }
    /// Every store before it is seen before every store after it.
    pub fn fenceStores(m: *A64) Error!void {
        try m.a.dmb(.ishst);
    }
    /// Every load before it is performed before every load after it.
    pub fn fenceLoads(m: *A64) Error!void {
        try m.a.dmb(.ishld);
    }
    /// Compares the word of width `w` at `[x + off]` with `y`.
    pub fn cmpAt(m: *A64, w: Wd, x: T, off: u32, y: T) Error!void {
        const b, const o = try m.reach(t(x), off);
        try m.a.ldr(if (w == .w64) .x else .w, .x14, b, o);
        try m.a.cmp(wd(w), .x14, t(y));
    }
    /// `[x + off]` = `s`, with release ordering.
    pub fn storeRelease(m: *A64, w: Wd, x: T, off: u32, s: T) Error!void {
        var base = t(x);
        if (off != 0) {
            try m.a.movImm(.x, addr, off);
            try m.a.add(.x, addr, t(x), addr);
            base = addr;
        }
        try m.a.stlr(wd(w), t(s), base);
    }
    /// The window register operands address from here on.
    /// Later code goes to the cold section, placed after all of the function's hot code,
    /// or back to the hot one.
    /// Byte offset of bound label `l` in the finished code.
    pub fn labelOffset(m: *const A64, l: Label) ?u32 {
        return m.a.labelOffset(l);
    }
    /// Later code goes out of the way of the code before it: to the cold section, placed
    /// after all of the function's hot code, or, where the code is cold already, behind a
    /// jump over it. `endCold` ends it.
    pub fn cold(m: *A64) Error!Cold {
        if (!m.a.cold) {
            m.a.section(true);
            return .{ .after = null };
        }
        const after = try m.label();
        try m.jump(after);
        return .{ .after = after };
    }
    pub fn endCold(m: *A64, c: Cold) void {
        if (c.after) |l| m.bind(l) else m.a.section(false);
    }

    pub fn setWin(m: *A64, w: Win) void {
        m.win_base = if (w.inline_area) inl else regs;
        m.win_off = w.off;
    }
    pub fn getWin(m: *const A64) Win {
        return .{ .inline_area = m.win_base == inl, .off = m.win_off };
    }
    fn slot(m: *const A64, r: u32) u32 {
        return (m.win_off + r) * 16;
    }
    /// The inline base register = the context's thread state + `area_off`.
    pub fn loadInlineBase(m: *A64, ev_off: u32, area_off: u32) Error!void {
        const b, const o = try m.reach(ctx, ev_off);
        try m.a.ldr(.x, inl, b, o);
        try m.a.movImm(.x, addr, area_off);
        try m.a.add(.x, inl, inl, addr);
    }
    /// The context's word at `off` = `s`.
    pub fn storeCtx(m: *A64, off: u32, s: T) Error!void {
        const b, const o = try m.reach(ctx, off);
        try m.a.str(.x, t(s), b, o);
    }
    /// `bytes` stored at `[x + off]`, through t0; `x` is not t0.
    pub fn storeBytesAt(m: *A64, x: T, off: u32, bytes: []const u8) Error!void {
        std.debug.assert(x != .t0);
        return m.storeBytes(t(x), off, bytes);
    }
    /// `d` = word `word` (0 the payload, 1 the tag's) of register `r`.
    pub fn loadRegWord(m: *A64, d: T, r: u32, word: u32) Error!void {
        if (m.pinned(r)) |p| {
            if (word == 0) return m.a.mov(.x, t(d), pin_regs[p.reg]);
            return m.a.movImm(.x, t(d), p.kind);
        }
        const b, const o = try m.reach(m.win_base, m.slot(r) + word * 8);
        try m.a.ldr(.x, t(d), b, o);
    }

    /// Calls `f(ctx, arg, &register args, &register dst)`, a function of the handlers'
    /// convention, keeping the registers the ops run on; `t0` = the bool it returns.
    pub fn callHost(m: *A64, f_addr: usize, arg: usize, args: u32, dst: u32) Error!void {
        // The host code reads its arguments and writes its result in the frame, and
        // leaves no caller-saved register as it was.
        try m.writeBackPins();
        try m.a.stpPre(ctx, frame, A.sp, -48);
        try m.a.stp(regs, .x3, A.sp, 16);
        try m.a.stp(inl, A.lr, A.sp, 32);
        try m.windowAddr(.x3, dst);
        try m.windowAddr(.x2, args);
        try m.a.movImm(.x, .x1, arg);
        try m.a.callAbs(f_addr, .x16);
        try m.a.andImm(.w, t(.t0), .x0, 0xff);
        try m.a.ldp(inl, A.lr, A.sp, 32);
        try m.a.ldp(regs, .x3, A.sp, 16);
        try m.a.ldpPost(ctx, frame, A.sp, 48);
        try m.loadPins();
    }
    /// `d` = the address of register `r` of the window.
    fn windowAddr(m: *A64, d: A.Reg, r: u32) Error!void {
        const off = m.slot(r);
        if (off <= 4095) return m.a.addImm(.x, d, m.win_base, off);
        try m.a.movImm(.x, addr, off);
        try m.a.add(.x, d, m.win_base, addr);
    }
    /// The frame's word at `off` = `s`.
    pub fn storeFrame(m: *A64, off: u32, s: T) Error!void {
        const b, const o = try m.reach(frame, off);
        try m.a.str(.x, t(s), b, o);
    }
    /// `d` = the address of the window plus the byte offset in `x`.
    pub fn windowPlus(m: *A64, d: T, x: T) Error!void {
        try m.a.add(.x, t(d), m.win_base, t(x));
    }
    /// To the address in `x`.
    pub fn jumpTo(m: *A64, x: T) Error!void {
        try m.a.br(t(x));
    }
    /// The frame and its registers become `fr` and `w`, the code, the pc and the block `code`,
    /// `pc` and `blk`: another function's code, which the code then goes on in.
    pub fn enterHere(m: *A64, fr: T, w: T, code: usize, pc: usize, blk: u32) Error!void {
        try m.a.mov(.x, frame, t(fr));
        try m.a.mov(.x, regs, t(w));
        try m.a.movImm(.x, .x3, code);
        try m.a.movImm(.x, pc_r, pc);
        try m.a.movImm(.w, blk_r, blk);
    }
    /// Tail-calls the handler at `h` with the context's word at `off` for its pc.
    pub fn tailHandlerCtx(m: *A64, h: usize, off: u32) Error!void {
        const b, const o = try m.reach(ctx, off);
        try m.a.ldr(.x, pc_r, b, o);
        try m.a.jumpAbs(h, .x16);
    }
    /// Tail-calls the handler at `h` for the op at `pc` in block `blk`.
    pub fn tailHandler(m: *A64, h: usize, pc: usize, blk: u32) Error!void {
        try m.a.movImm(.x, pc_r, pc);
        try m.a.movImm(.w, blk_r, blk);
        try m.a.jumpAbs(h, .x16);
    }
};

pub const X64 = struct {
    const X = jit.x64;
    a: X.Asm,
    /// The window register operands address (`Win`).
    win_base: X.Reg = regs,
    win_off: u32 = 0,
    /// No register is pinned on x86-64: every register the handlers' convention leaves
    /// free holds an operand or a scratch value.
    pins: []const Pin = &.{},
    pub const n_pin_regs = 0;

    pub fn writeBackPins(_: *X64) Error!void {}
    pub fn loadPins(_: *X64) Error!void {}
    pub fn isTempPin(_: *const X64, _: u32) bool {
        return false;
    }

    const ctx: X.Reg = .rdi;
    const frame: X.Reg = .rsi;
    const regs: X.Reg = .rdx;
    const pc_r: X.Reg = .r8;
    const blk_r: X.Reg = .r9;
    /// The thread's inline registers while a callee compiled into its
    /// caller runs: the block register, set again before any handler runs.
    const inl: X.Reg = .r9;

    pub const Label = X.Label;

    pub fn init(gpa: std.mem.Allocator) X64 {
        return .{ .a = X.Asm.init(gpa) };
    }
    pub fn deinit(m: *X64) void {
        m.a.deinit();
    }
    pub fn offset(m: *const X64) u32 {
        return m.a.pos();
    }
    pub fn finish(m: *X64) Error![]u8 {
        return m.a.finish();
    }
    pub fn label(m: *X64) Error!Label {
        return m.a.newLabel();
    }
    pub fn bind(m: *X64, l: Label) void {
        m.a.bind(l);
    }
    pub fn jump(m: *X64, l: Label) Error!void {
        return m.a.jmp(l);
    }

    fn t(r: T) X.Reg {
        return switch (r) {
            .t0 => .rax,
            .t1 => .r10,
            .t2 => .r11,
            .t3 => .r8,
        };
    }
    fn f(r: FR) X.X {
        return switch (r) {
            .f0 => .xmm0,
            .f1 => .xmm1,
        };
    }
    fn wd(w: Wd) X.W {
        return if (w == .w64) .q else .d;
    }
    fn cond(c: Cond) X.Cond {
        return switch (c) {
            .eq => .e,
            .ne => .ne,
            .lt => .l,
            .le => .le,
            .gt => .g,
            .ge => .ge,
        };
    }
    fn at(base: X.Reg, off: u32) X.Mem {
        return X.Mem.at(base, @intCast(off));
    }

    pub fn loadTag(m: *X64, d: T, r: u32, tag_off: u32) Error!void {
        try m.a.loadU8(t(d), at(m.win_base, m.slot(r) + tag_off));
        try m.a.andImm(.d, t(d), 0x3f);
    }
    pub fn guardTag(m: *X64, r: u32, tag_off: u32, tag: u8, fail: Label) Error!void {
        try m.loadTag(.t3, r, tag_off);
        try m.a.cmpImm(.d, t(.t3), tag);
        try m.a.jcc(.ne, fail);
    }
    pub fn cmpTagImm(m: *X64, d: T, tag: u8) Error!void {
        try m.a.cmpImm(.d, t(d), tag);
    }
    pub fn loadPayload(m: *X64, w: Wd, d: T, r: u32) Error!void {
        try m.a.load(wd(w), t(d), at(m.win_base, m.slot(r)));
    }
    pub fn loadPayloadByte(m: *X64, d: T, r: u32) Error!void {
        try m.a.loadU8(t(d), at(m.win_base, m.slot(r)));
    }
    /// A register's word is written whole, as on AArch64 (`A64.storePayload`).
    pub fn storePayload(m: *X64, w: Wd, r: u32, s: T) Error!void {
        _ = w;
        try m.a.store(.q, at(m.win_base, m.slot(r)), t(s));
    }
    pub fn storePayloadByte(m: *X64, r: u32, s: T) Error!void {
        try m.a.store(.q, at(m.win_base, m.slot(r)), t(s));
    }
    pub fn storeTag(m: *X64, r: u32, tag_off: u32, tag: u8, s: T) Error!void {
        _ = s;
        try m.a.storeImm(.q, at(m.win_base, m.slot(r) + tag_off), tag);
    }
    pub fn storeValue(m: *X64, r: u32, v: [16]u8) Error!void {
        try m.storeBytes(m.win_base, m.slot(r), &v);
    }
    fn storeBytes(m: *X64, base: X.Reg, off: u32, bytes: []const u8) Error!void {
        var i: usize = 0;
        while (i < bytes.len) : (i += 8) {
            const n = @min(8, bytes.len - i);
            var word: u64 = 0;
            for (0..n) |k| word |= @as(u64, bytes[i + k]) << @intCast(k * 8);
            try m.a.movImm(t(.t0), word);
            if (n == 8) try m.a.store(.q, at(base, off + @as(u32, @intCast(i))), t(.t0)) else if (n == 4) try m.a.store(.d, at(base, off + @as(u32, @intCast(i))), t(.t0)) else return Error.Unsupported;
        }
    }
    pub fn storeFrameBytes(m: *X64, off: u32, bytes: []const u8) Error!void {
        return m.storeBytes(frame, off, bytes);
    }
    pub fn copyValue(m: *X64, d: u32, s: u32) Error!void {
        try m.a.load(.q, t(.t0), at(m.win_base, m.slot(s)));
        try m.a.load(.q, t(.t1), at(m.win_base, m.slot(s) + 8));
        try m.a.store(.q, at(m.win_base, m.slot(d)), t(.t0));
        try m.a.store(.q, at(m.win_base, m.slot(d) + 8), t(.t1));
    }

    pub fn movImm(m: *X64, d: T, v: u64) Error!void {
        try m.a.movImm(t(d), v);
    }
    /// Three-operand forms on a two-operand machine: `d = x op y`.
    fn three(m: *X64, comptime op: []const u8, w: Wd, d: T, x: T, y: T) Error!void {
        if (d == y and d != x) {
            // Commutative only: the templates never ask for `d == y` with sub or shifts.
            try @field(X.Asm, op)(&m.a, wd(w), t(d), t(x));
            return;
        }
        if (d != x) try m.a.mov(wd(w), t(d), t(x));
        try @field(X.Asm, op)(&m.a, wd(w), t(d), t(y));
    }
    pub fn add(m: *X64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.three("add", w, d, x, y);
    }
    pub fn sub(m: *X64, w: Wd, d: T, x: T, y: T) Error!void {
        std.debug.assert(d != y or d == x);
        try m.three("sub", w, d, x, y);
    }
    pub fn mul(m: *X64, w: Wd, d: T, x: T, y: T) Error!void {
        if (d == y and d != x) return m.a.imul(wd(w), t(d), t(x));
        if (d != x) try m.a.mov(wd(w), t(d), t(x));
        try m.a.imul(wd(w), t(d), t(y));
    }
    pub fn andR(m: *X64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.three("and", w, d, x, y);
    }
    pub fn orR(m: *X64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.three("or", w, d, x, y);
    }
    pub fn xorR(m: *X64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.three("xor", w, d, x, y);
    }
    /// The count goes through `cl`: rcx is the code register, restored after.
    fn shift(m: *X64, comptime op: enum { shl, sar, shr }, w: Wd, d: T, x: T, y: T) Error!void {
        std.debug.assert(d != y);
        if (d != x) try m.a.mov(wd(w), t(d), t(x));
        try m.a.push(.rcx);
        try m.a.mov(.q, .rcx, t(y));
        switch (op) {
            .shl => try m.a.shlCl(wd(w), t(d)),
            .sar => try m.a.sarCl(wd(w), t(d)),
            .shr => try m.a.shrCl(wd(w), t(d)),
        }
        try m.a.pop(.rcx);
    }
    pub fn shl(m: *X64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.shift(.shl, w, d, x, y);
    }
    pub fn sar(m: *X64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.shift(.sar, w, d, x, y);
    }
    pub fn shr(m: *X64, w: Wd, d: T, x: T, y: T) Error!void {
        try m.shift(.shr, w, d, x, y);
    }
    pub fn neg(m: *X64, w: Wd, d: T, x: T) Error!void {
        if (d != x) try m.a.mov(wd(w), t(d), t(x));
        try m.a.neg(wd(w), t(d));
    }
    pub fn notR(m: *X64, w: Wd, d: T, x: T) Error!void {
        if (d != x) try m.a.mov(wd(w), t(d), t(x));
        try m.a.not(wd(w), t(d));
    }
    /// `idiv` divides rdx:rax, and rdx is the register base: kept across it.
    pub fn divRem(m: *X64, w: Wd, rem: bool, d: T, x: T, y: T) Error!void {
        std.debug.assert(x == .t0 and y == .t1 and d == .t2);
        try m.a.push(.rdx);
        try m.a.signExtendAcc(wd(w));
        try m.a.idiv(wd(w), t(y));
        try m.a.mov(wd(w), t(d), if (rem) .rdx else .rax);
        try m.a.pop(.rdx);
    }
    pub fn addImm(m: *X64, w: Wd, d: T, x: T, v: u32) Error!void {
        if (d != x) try m.a.mov(wd(w), t(d), t(x));
        try m.a.addImm(wd(w), t(d), @intCast(v));
    }
    pub fn subImm(m: *X64, w: Wd, d: T, x: T, v: u32) Error!void {
        if (d != x) try m.a.mov(wd(w), t(d), t(x));
        try m.a.subImm(wd(w), t(d), @intCast(v));
    }
    pub fn xorImm1(m: *X64, d: T, x: T) Error!void {
        if (d != x) try m.a.mov(.d, t(d), t(x));
        try m.a.xorImm(.d, t(d), 1);
    }
    pub fn signExtend32(m: *X64, d: T, x: T) Error!void {
        try m.a.movsxd(t(d), t(x));
    }
    pub fn zeroExtend32(m: *X64, d: T, x: T) Error!void {
        try m.a.mov(.d, t(d), t(x));
    }
    pub fn cmp(m: *X64, w: Wd, x: T, y: T) Error!void {
        try m.a.cmp(wd(w), t(x), t(y));
    }
    pub fn setCond(m: *X64, d: T, c: Cond) Error!void {
        try m.a.setcc(cond(c), t(d));
        try m.a.movzx(.b, t(d), t(d));
    }
    pub fn bCond(m: *X64, c: Cond, l: Label) Error!void {
        try m.a.jcc(cond(c), l);
    }
    pub fn bZero(m: *X64, x: T, l: Label) Error!void {
        try m.a.@"test"(.d, t(x), t(x));
        try m.a.jcc(.e, l);
    }
    pub fn bNonZero(m: *X64, x: T, l: Label) Error!void {
        try m.a.@"test"(.d, t(x), t(x));
        try m.a.jcc(.ne, l);
    }
    pub fn bBit(m: *X64, x: T, bit: u6, l: Label) Error!void {
        std.debug.assert(bit < 31);
        try m.a.testImm(.d, t(x), @as(i32, 1) << @intCast(bit));
        try m.a.jcc(.ne, l);
    }
    /// A branch to `l` when bit `bit` (below 32) of `x` is clear.
    pub fn bBitClear(m: *X64, x: T, bit: u6, l: Label) Error!void {
        std.debug.assert(bit < 32);
        try m.a.testImm(.d, t(x), @bitCast(@as(u32, 1) << @intCast(bit)));
        try m.a.jcc(.e, l);
    }
    /// `d1`, `d2` = the two words at `[x + off]`, in one access: an aligned SSE load of
    /// 16 bytes, which a processor with AVX performs whole.
    pub fn loadPair(m: *X64, d1: T, d2: T, x: T, off: u32) Error!void {
        try m.a.movdqaLoad(.xmm15, at(t(x), off));
        try m.a.movFromX(.q, t(d1), .xmm15);
        try m.a.punpckhqdq(.xmm15, .xmm15);
        try m.a.movFromX(.q, t(d2), .xmm15);
    }
    /// The two words at `[x + off]` = `s1`, `s2`, in one access as `loadPair` reads them.
    pub fn storePair(m: *X64, x: T, off: u32, s1: T, s2: T) Error!void {
        try m.a.movToX(.q, .xmm14, t(s1));
        try m.a.movToX(.q, .xmm15, t(s2));
        try m.a.punpcklqdq(.xmm14, .xmm15);
        try m.a.movdqaStore(at(t(x), off), .xmm14);
    }

    pub fn loadCtx(m: *X64, d: T, off: u32) Error!void {
        try m.a.load(.q, t(d), at(ctx, off));
    }
    pub fn loadFrame(m: *X64, d: T, off: u32) Error!void {
        try m.a.load(.q, t(d), at(frame, off));
    }
    pub fn loadAt(m: *X64, w: Wd, d: T, x: T, off: u32) Error!void {
        try m.a.load(wd(w), t(d), at(t(x), off));
    }
    pub fn storeAt(m: *X64, w: Wd, x: T, off: u32, s: T) Error!void {
        try m.a.store(wd(w), at(t(x), off), t(s));
    }
    /// A load is an acquire on x86-64.
    pub fn loadAcquire(m: *X64, w: Wd, d: T, x: T, off: u32) Error!void {
        try m.a.load(wd(w), t(d), at(t(x), off));
    }
    pub fn loadAbs32(m: *X64, d: T, address: usize) Error!void {
        try m.a.loadLit(t(d), address);
        try m.a.load(.d, t(d), at(t(d), 0));
    }
    pub fn copyWordToReg(m: *X64, r: u32, word: u32, x: T, off: u32, s: T) Error!void {
        try m.a.load(.q, t(s), at(t(x), off));
        try m.a.store(.q, at(m.win_base, m.slot(r) + word * 8), t(s));
    }
    pub fn copyValueFrom(m: *X64, r: u32, x: T, off: u32) Error!void {
        try m.copyWordToReg(r, 0, x, off, .t1);
        try m.copyWordToReg(r, 1, x, off + 8, .t1);
    }

    pub const FOp = enum { add, sub, mul, div };

    pub fn loadF(m: *X64, dbl: bool, fr: FR, r: u32) Error!void {
        try m.a.movsdLoad(dbl, f(fr), at(m.win_base, m.slot(r)));
    }
    pub fn storeF(m: *X64, dbl: bool, r: u32, fr: FR) Error!void {
        try m.a.movsdStore(dbl, at(m.win_base, m.slot(r)), f(fr));
    }
    pub fn movF(m: *X64, dbl: bool, fr: FR, bits: u64) Error!void {
        try m.a.movImm(t(.t1), bits);
        try m.a.movToX(if (dbl) .q else .d, f(fr), t(.t1));
    }
    pub fn fop(m: *X64, op: FOp, dbl: bool, d: FR, x: FR, y: FR) Error!void {
        std.debug.assert(d != y or d == x);
        if (d != x) try m.a.movapd(f(d), f(x));
        switch (op) {
            .add => try m.a.addsd(dbl, f(d), f(y)),
            .sub => try m.a.subsd(dbl, f(d), f(y)),
            .mul => try m.a.mulsd(dbl, f(d), f(y)),
            .div => try m.a.divsd(dbl, f(d), f(y)),
        }
    }
    /// `ucomisd` sets ZF, PF and CF all for an unordered pair, so less-than is
    /// read as the other operand being above, and equality needs PF clear.
    pub fn fcmpSet(m: *X64, dbl: bool, d: T, x: FR, y: FR, c: Cond) Error!void {
        switch (c) {
            .lt, .le => try m.a.ucomisd(dbl, f(y), f(x)),
            else => try m.a.ucomisd(dbl, f(x), f(y)),
        }
        switch (c) {
            .lt, .gt => try m.a.setcc(.a, t(d)),
            .le, .ge => try m.a.setcc(.ae, t(d)),
            .eq => {
                try m.a.setcc(.e, t(d));
                try m.a.setcc(.np, t(.t3));
                try m.a.@"and"(.b, t(d), t(.t3));
            },
            .ne => {
                try m.a.setcc(.ne, t(d));
                try m.a.setcc(.p, t(.t3));
                try m.a.@"or"(.b, t(d), t(.t3));
            },
        }
        try m.a.movzx(.b, t(d), t(d));
    }

    pub fn bLow16Zero(m: *X64, x: T, l: Label) Error!void {
        try m.a.testImm(.d, t(x), 0xFFFF);
        try m.a.jcc(.e, l);
    }
    pub fn storeRegWord(m: *X64, r: u32, word: u32, s: T) Error!void {
        try m.a.store(.q, at(m.win_base, m.slot(r) + word * 8), t(s));
    }

    pub fn loadByteAt(m: *X64, d: T, x: T, off: u32) Error!void {
        try m.a.loadU8(t(d), at(t(x), off));
    }
    pub fn loadAcquireByte(m: *X64, d: T, x: T) Error!void {
        try m.a.loadU8(t(d), at(t(x), 0));
    }
    pub fn lsrImm(m: *X64, w: Wd, d: T, x: T, n: u6) Error!void {
        if (d != x) try m.a.mov(wd(w), t(d), t(x));
        try m.a.shrImm(wd(w), t(d), n);
    }
    pub fn bZero64(m: *X64, x: T, l: Label) Error!void {
        try m.a.@"test"(.q, t(x), t(x));
        try m.a.jcc(.e, l);
    }
    pub fn andImm(m: *X64, w: Wd, d: T, x: T, imm: i32) Error!void {
        if (d != x) try m.a.mov(wd(w), t(d), t(x));
        try m.a.andImm(wd(w), t(d), imm);
    }
    pub fn shlImm(m: *X64, w: Wd, d: T, x: T, n: u6) Error!void {
        if (d != x) try m.a.mov(wd(w), t(d), t(x));
        try m.a.shlImm(wd(w), t(d), n);
    }
    pub fn bNegative(m: *X64, x: T, l: Label) Error!void {
        try m.a.@"test"(.q, t(x), t(x));
        try m.a.jcc(.l, l);
    }
    /// `lock cmpxchg` compares with rax: `expect` is t0.
    pub fn cas32(m: *X64, x: T, off: u32, expect: T, new: T, fail: Label) Error!void {
        std.debug.assert(expect == .t0 and x != .t0 and new != .t0);
        try m.a.lockCmpxchg(.d, at(t(x), off), t(new));
        try m.a.jcc(.ne, fail);
    }
    pub fn atomicAnd32(m: *X64, x: T, off: u32, mask: u32) Error!void {
        try m.a.lockAndImm(.d, at(t(x), off), @bitCast(mask));
    }
    /// `lock xadd` is a full barrier.
    pub fn atomicAdd32(m: *X64, x: T, off: u32, delta: i32, old: T) Error!void {
        return m.atomicAdd(.w32, x, off, delta, old);
    }
    pub fn atomicAdd(m: *X64, w: Wd, x: T, off: u32, delta: i32, old: T) Error!void {
        std.debug.assert(x != old);
        try m.a.movImm(t(old), @bitCast(@as(i64, delta)));
        try m.a.lockXadd(wd(w), at(t(x), off), t(old));
    }
    /// A locked add orders as a full barrier on x86-64 whatever it asks.
    pub fn atomicAddRelaxed(m: *X64, w: Wd, x: T, off: u32, delta: i32, old: T) Error!void {
        return m.atomicAdd(w, x, off, delta, old);
    }
    /// `takeIdentity` as A64's: `lock cmpxchg` compares with rax, so t0 is scratch, and t3
    /// holds the counter's address.
    pub fn takeIdentity(m: *X64, x: T, off: u32, out: T, counter: usize) Error!void {
        std.debug.assert(x != .t0 and x != .t3 and out != .t0 and out != .t3);
        const done = try m.a.newLabel();
        const nonzero = try m.a.newLabel();
        try m.loadAt(.w32, out, x, off);
        try m.a.@"test"(.d, t(out), t(out));
        try m.a.jcc(.ne, done);
        try m.a.movImm(t(.t3), counter);
        try m.a.movImm(t(out), 1);
        try m.a.lockXadd(.q, at(t(.t3), 0), t(out));
        try m.a.addImm(.d, t(out), 1);
        try m.a.jcc(.ne, nonzero);
        try m.a.movImm(t(out), 1);
        m.a.bind(nonzero);
        try m.a.xor(.d, t(.t0), t(.t0));
        try m.a.lockCmpxchg(.d, at(t(x), off), t(out));
        try m.a.jcc(.e, done);
        try m.a.mov(.d, t(out), t(.t0));
        m.a.bind(done);
    }
    /// `bytes` stored at `[x]`, as immediates through t0: a word's immediate and
    /// store cost what a load and a store do.
    pub fn copyFrom(m: *X64, x: T, bytes: []const u8) Error!void {
        std.debug.assert(x == .t3 and bytes.len % 16 == 0 and bytes.len <= copy_max);
        return m.storeBytes(t(x), 0, bytes);
    }
    /// Stores are seen in order on x86-64.
    pub fn fenceStores(_: *X64) Error!void {}
    /// Loads are performed in order on x86-64.
    pub fn fenceLoads(_: *X64) Error!void {}
    /// Compares the word of width `w` at `[x + off]` with `y`.
    pub fn cmpAt(m: *X64, w: Wd, x: T, off: u32, y: T) Error!void {
        try m.a.cmpLoad(wd(w), t(y), at(t(x), off));
    }
    /// A store is a release on x86-64.
    pub fn storeRelease(m: *X64, w: Wd, x: T, off: u32, s: T) Error!void {
        try m.a.store(wd(w), at(t(x), off), t(s));
    }
    /// Later code goes to the cold section, placed after all of the function's hot code,
    /// or back to the hot one.
    /// Byte offset of bound label `l` in the finished code.
    pub fn labelOffset(m: *const X64, l: Label) ?u32 {
        return m.a.labelOffset(l);
    }
    /// Later code goes out of the way of the code before it: to the cold section, placed
    /// after all of the function's hot code, or, where the code is cold already, behind a
    /// jump over it. `endCold` ends it.
    pub fn cold(m: *X64) Error!Cold {
        if (!m.a.cold) {
            m.a.section(true);
            return .{ .after = null };
        }
        const after = try m.label();
        try m.jump(after);
        return .{ .after = after };
    }
    pub fn endCold(m: *X64, c: Cold) void {
        if (c.after) |l| m.bind(l) else m.a.section(false);
    }

    pub fn setWin(m: *X64, w: Win) void {
        m.win_base = if (w.inline_area) inl else regs;
        m.win_off = w.off;
    }
    pub fn getWin(m: *const X64) Win {
        return .{ .inline_area = m.win_base == inl, .off = m.win_off };
    }
    fn slot(m: *const X64, r: u32) u32 {
        return (m.win_off + r) * 16;
    }
    pub fn loadInlineBase(m: *X64, ev_off: u32, area_off: u32) Error!void {
        try m.a.load(.q, inl, at(ctx, ev_off));
        try m.a.addImm(.q, inl, @intCast(area_off));
    }
    pub fn storeCtx(m: *X64, off: u32, s: T) Error!void {
        try m.a.store(.q, at(ctx, off), t(s));
    }
    pub fn storeBytesAt(m: *X64, x: T, off: u32, bytes: []const u8) Error!void {
        std.debug.assert(x != .t0);
        return m.storeBytes(t(x), off, bytes);
    }
    pub fn loadRegWord(m: *X64, d: T, r: u32, word: u32) Error!void {
        try m.a.load(.q, t(d), at(m.win_base, m.slot(r) + word * 8));
    }

    /// Calls `f(ctx, arg, &register args, &register dst)`, a function of the handlers'
    /// convention, keeping the registers the ops run on; `t0` = the bool it returns.
    /// Five pushes from an entry's alignment leave the stack aligned for the call.
    pub fn callHost(m: *X64, f_addr: usize, arg: usize, args: u32, dst: u32) Error!void {
        for ([_]X.Reg{ ctx, frame, regs, .rcx, inl }) |r| try m.a.push(r);
        try m.a.lea(.rcx, at(m.win_base, m.slot(dst)));
        try m.a.lea(.rdx, at(m.win_base, m.slot(args)));
        try m.a.movImm(.rsi, arg);
        try m.a.callAbs(f_addr);
        try m.a.andImm(.d, .rax, 0xff);
        for ([_]X.Reg{ inl, .rcx, regs, frame, ctx }) |r| try m.a.pop(r);
    }
    pub fn storeFrame(m: *X64, off: u32, s: T) Error!void {
        try m.a.store(.q, at(frame, off), t(s));
    }
    pub fn windowPlus(m: *X64, d: T, x: T) Error!void {
        if (d != x) try m.a.mov(.q, t(d), t(x));
        try m.a.add(.q, t(d), m.win_base);
    }
    pub fn jumpTo(m: *X64, x: T) Error!void {
        try m.a.jmpReg(t(x));
    }
    /// `A64.enterHere`. `t3` is the pc register: neither operand is it.
    pub fn enterHere(m: *X64, fr: T, w: T, code: usize, pc: usize, blk: u32) Error!void {
        std.debug.assert(fr != .t3 and w != .t3);
        try m.a.mov(.q, frame, t(fr));
        try m.a.mov(.q, regs, t(w));
        try m.a.movImm(.rcx, code);
        try m.a.movImm(pc_r, pc);
        try m.a.movImm(blk_r, blk);
    }
    pub fn tailHandlerCtx(m: *X64, h: usize, off: u32) Error!void {
        try m.a.load(.q, pc_r, at(ctx, off));
        try m.a.jumpAbs(h);
    }
    pub fn tailHandler(m: *X64, h: usize, pc: usize, blk: u32) Error!void {
        try m.a.movImm(pc_r, pc);
        try m.a.movImm(blk_r, blk);
        try m.a.jumpAbs(h);
    }
};

/// This build's macro assembler.
pub const Masm = switch (builtin.cpu.arch) {
    .aarch64 => A64,
    .x86_64 => X64,
    else => A64,
};
