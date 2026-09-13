//! The instruction-to-backend translator: walks the candidate region and
//! emits x86-64 for each supported instruction, recording guard, deopt, and
//! trampoline sites as it goes.

const std = @import("std");
const ir = @import("../ir.zig");
const jit = @import("jit");

const common = @import("common.zig");
const shapes = @import("shapes.zig");
const inline_analysis = @import("inline_analysis.zig");
const type_infer = @import("types.zig");

const Module = ir.Module;
const Func = ir.Func;
const Inst = ir.Inst;
const Reg = ir.Reg;
const BlockId = ir.BlockId;
const Allocator = std.mem.Allocator;
const E = jit.Reg;

const CELL_DATA_OFF = common.CELL_DATA_OFF;
const CallSite = common.CallSite;
const DirectSite = common.DirectSite;
const FIELD_STRIDE = common.FIELD_STRIDE;
const FIELD_VALUE_OFF = common.FIELD_VALUE_OFF;
const INST_CLASS_OFF = common.INST_CLASS_OFF;
const REGS = common.REGS;
const RegType = common.RegType;
const T0 = common.T0;
const T1 = common.T1;
const T2 = common.T2;
const VALUE_SIZE = common.VALUE_SIZE;
const X0 = common.X0;
const X1 = common.X1;
const encodeResume = common.encodeResume;
const instanceTagValue = common.instanceTagValue;
const returnCode = common.returnCode;
const BodyInstPos = inline_analysis.BodyInstPos;
const CALLEE_BLOCK_LIMIT = inline_analysis.CALLEE_BLOCK_LIMIT;
const INLINE_MAX_BLOCKS = inline_analysis.INLINE_MAX_BLOCKS;
const InlineSite = inline_analysis.InlineSite;
const calleeBlockOrder = inline_analysis.calleeBlockOrder;
const remapInst = inline_analysis.remapInst;
const slotBytes = inline_analysis.slotBytes;
const ArrayOp = shapes.ArrayOp;
const arrayOpOf = shapes.arrayOpOf;
const bitwiseOpOf = shapes.bitwiseOpOf;
const constFloatBits = shapes.constFloatBits;
const constI64 = shapes.constI64;
const constType = shapes.constType;
const isArithBinOp = shapes.isArithBinOp;
const isBitwiseBinOp = shapes.isBitwiseBinOp;
const isCmpBinOp = shapes.isCmpBinOp;
const isDivBinOp = shapes.isDivBinOp;
const isFloat = shapes.isFloat;
const isNumeric = shapes.isNumeric;
const numericConvOf = shapes.numericConvOf;
const trampolinableFieldOf = shapes.trampolinableFieldOf;
const trampolinableFieldSetOf = shapes.trampolinableFieldSetOf;
const ArrayInfo = type_infer.ArrayInfo;
const isScalarRt = type_infer.isScalarRt;
const tagForRt = type_infer.tagForRt;
const typeOf = type_infer.typeOf;

// --- compilation ------------------------------------------------------------

pub const Compiler = struct {
    a: Allocator,
    module: *const Module,
    func: *const Func,
    body: []const BlockId,
    types: []const RegType,
    array_info: []const ?ArrayInfo,
    cell_info: []const ?RegType,
    call_sites: []const CallSite,
    inline_sites: []const InlineSite,
    direct_sites: []const DirectSite = &.{},
    /// Frame register base slot, read by a guarded arm to reach its receiver.
    regs_ptr_slot: u32 = 0,
    /// Instructions a direct call consumed (the receiver Move), which must not
    /// be emitted.
    skip_insts: []const BodyInstPos = &.{},
    /// Per-register: is this a nullable-scalar register, and its null-flag slot.
    nullable: []const bool,
    null_flag_slot: []const u32,
    uc_slot: u32,
    tramp_slot: u32,
    n_regs: u32,
    /// Total register-slot count (caller registers plus inlined-callee registers);
    /// the upper bound for `slotDisp`.
    reg_slots: u32,
    val_payload_off: u32,
    val_tag_off: u32,
    /// Function-JIT mode (whole-function compile): enables `LoadParam` (reads a
    /// param slot) and the `Return` terminator (writes `result_slot`, exits).
    func_mode: bool = false,
    /// Method mode: `LoadParam 0` is the receiver — it lives in no slot (the
    /// entry seeds its field-buffer pointer instead), so the load is a no-op.
    method_mode: bool = false,
    param_slot_base: u32 = 0,
    n_params: u32 = 0,
    result_slot: u32 = 0,
    result_reg_slot: u32 = 0,
    /// Method mode: the slot holding the receiver's field-buffer pointer, which
    /// a direct call hands to the callee (the same receiver, so the same base).
    entry_fbase_slot: u32 = 0,
    em: jit.Emitter,
    block_label: []?jit.Label,
    exit_targets: std.ArrayList(BlockId),
    exit_labels: std.ArrayList(jit.Label),
    deopt_codes: std.ArrayList(u64),
    deopt_labels: std.ArrayList(jit.Label),
    epilogue: jit.Label,
    cur_block: BlockId = undefined,
    cur_inst: u32 = 0,
    /// While a spliced or direct call is emitted, where a deopt must resume:
    /// the receiver `Move` the compiler removed, so the interpreter re-runs
    /// from the point that fills the argument register native code never wrote.
    deopt_override: ?BodyInstPos = null,

    fn inBody(self: *Compiler, b: BlockId) bool {
        for (self.body) |x| if (x.int() == b.int()) return true;
        return false;
    }

    /// The compiled call-site index for the instruction at the current
    /// (block, inst), or null if that instruction is not a trampolined call.
    fn siteIndexAt(self: *Compiler) ?u32 {
        for (self.call_sites, 0..) |s, i| {
            if (s.block.int() == self.cur_block.int() and s.inst == self.cur_inst)
                return @intCast(i);
        }
        return null;
    }

    fn slotDisp(self: *Compiler, r: Reg) ?i32 {
        const off: u64 = @as(u64, r.int()) * 8;
        if (off > std.math.maxInt(i32) or r.int() >= self.reg_slots) return null;
        return @intCast(off);
    }

    /// The inline expansion at the current (block, inst), if any.
    fn inlineSiteAt(self: *Compiler) ?*const InlineSite {
        for (self.inline_sites) |*s| {
            if (s.block.int() == self.cur_block.int() and s.inst == self.cur_inst) return s;
        }
        return null;
    }

    /// The direct call at the current (block, inst), if any.
    fn directSiteAt(self: *Compiler) ?*const DirectSite {
        for (self.direct_sites) |*s| {
            if (s.block.int() == self.cur_block.int() and s.inst == self.cur_inst) return s;
        }
        return null;
    }

    fn isNullable(self: *Compiler, r: Reg) bool {
        return r.int() < self.nullable.len and self.nullable[r.int()];
    }
    fn loadFlag(self: *Compiler, native: E, r: Reg) !void {
        try self.em.loadMem(native, REGS, @intCast(@as(u64, self.null_flag_slot[r.int()]) * 8));
    }
    fn storeFlag(self: *Compiler, r: Reg, native: E) !void {
        try self.em.storeMem(REGS, @intCast(@as(u64, self.null_flag_slot[r.int()]) * 8), native);
    }

    /// Emit a register-writing instruction whose destination (or an operand) is a
    /// nullable-scalar register. Returns true when handled, false to fall through
    /// to the normal scalar path. Unsupported nullable shapes raise `Unsupported`.
    fn emitNullable(self: *Compiler, inst: *const Inst) !bool {
        switch (inst.*) {
            .Move => |m| {
                if (!self.isNullable(m.dst)) return false;
                if (typeOf(self.types, m.src) == .null_) {
                    // dst = null: value slot cleared, flag set.
                    try self.em.movImm64(T0, 0);
                    try self.storeSlot(m.dst, T0);
                    try self.em.movImm64(T0, 1);
                    try self.storeFlag(m.dst, T0);
                } else if (self.isNullable(m.src)) {
                    // dst = src: copy value + flag.
                    try self.loadSlot(T0, m.src);
                    try self.storeSlot(m.dst, T0);
                    try self.loadFlag(T0, m.src);
                    try self.storeFlag(m.dst, T0);
                } else {
                    // dst = scalar: value from src, flag cleared.
                    try self.loadSlot(T0, m.src);
                    try self.storeSlot(m.dst, T0);
                    try self.em.movImm64(T0, 0);
                    try self.storeFlag(m.dst, T0);
                }
                return true;
            },
            .BinOp => |b| {
                const ln = self.isNullable(b.lhs);
                const rn = self.isNullable(b.rhs);
                if (!ln and !rn) return false;
                // Only `nullable == null` / `nullable != null` is compiled (a test
                // of the flag); any other op on a nullable operand bails.
                if (b.op != .Eq and b.op != .NotEq) return jit.JitError.Unsupported;
                const nreg: Reg = if (ln and typeOf(self.types, b.rhs) == .null_)
                    b.lhs
                else if (rn and typeOf(self.types, b.lhs) == .null_)
                    b.rhs
                else
                    return jit.JitError.Unsupported;
                try self.loadFlag(T0, nreg); // T0 = 1 iff null
                if (b.op == .NotEq) {
                    try self.em.movImm64(T1, 1);
                    try self.em.xorReg(T0, T1); // != null -> 1 iff non-null
                }
                try self.storeSlot(b.dst, T0);
                return true;
            },
            else => return false,
        }
    }

    fn loadSlot(self: *Compiler, native: E, r: Reg) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.loadMem(native, REGS, d);
    }
    fn storeSlot(self: *Compiler, r: Reg, native: E) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.storeMem(REGS, d, native);
    }
    /// Load/store an f64 register's slot through an xmm (the slot holds the bits).
    fn loadF64Slot(self: *Compiler, x: jit.Xmm, r: Reg) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.movsdLoad(x, REGS, d);
    }
    fn storeF64Slot(self: *Compiler, r: Reg, x: jit.Xmm) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.movsdStore(REGS, d, x);
    }
    /// Load/store an f32 register's slot (f32 bits in the low 4 bytes).
    fn loadF32Slot(self: *Compiler, x: jit.Xmm, r: Reg) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.movssLoad(x, REGS, d);
    }
    fn storeF32Slot(self: *Compiler, r: Reg, x: jit.Xmm) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.movssStore(REGS, d, x);
    }

    fn loadFloat(self: *Compiler, x: jit.Xmm, r: Reg, is32: bool) !void {
        if (is32) try self.loadF32Slot(x, r) else try self.loadF64Slot(x, r);
    }

    /// `x.toInt()`/`toLong()` on a float, matching Kotlin's clamping: NaN→0,
    /// overflow→Int/Long.MIN/MAX, else truncate toward zero. `cvtt*2si` already
    /// truncates in range and yields the i64-min sentinel on NaN/overflow, so the
    /// common path is one convert + a sentinel check; only the rare sentinel case
    /// is fixed up. Result left in `T0`. `from_f32`/`to_i32` select precision.
    fn emitFloatToInt(self: *Compiler, src: Reg, dst: Reg, from_f32: bool, to_i32: bool) !void {
        try self.loadFloat(X0, src, from_f32);
        if (from_f32) try self.em.cvttss2si(T0, X0) else try self.em.cvttsd2si(T0, X0);
        const done64 = try self.em.newLabel();
        const not_nan = try self.em.newLabel();
        // Sentinel (i64 min) means NaN or out-of-i64-range.
        try self.em.movImm64(T1, 0x8000_0000_0000_0000);
        try self.em.cmpReg(T0, T1);
        try self.em.jcc(.ne, done64); // common: in range, T0 correct
        try self.ucomiFloat(X0, X0, from_f32); // PF set iff NaN
        try self.em.jcc(.np, not_nan);
        try self.em.movImm64(T0, 0); // NaN -> 0
        try self.em.jmp(done64);
        try self.em.bind(not_nan);
        // Overflow: positive -> i64 max, negative -> i64 min (T0 already = min).
        try self.em.xorps(X1, X1);
        try self.ucomiFloat(X0, X1, from_f32);
        try self.em.jcc(.be, done64); // x <= 0 -> i64 min (already in T0)
        try self.em.movImm64(T0, 0x7FFF_FFFF_FFFF_FFFF); // x > 0 -> i64 max
        try self.em.bind(done64);
        if (to_i32) {
            // Clamp the (already i64-clamped) value into the Int range.
            const lo = try self.em.newLabel();
            const done32 = try self.em.newLabel();
            try self.em.movImm64(T1, 0x7FFF_FFFF); // Int.MAX
            try self.em.cmpReg(T0, T1);
            try self.em.jcc(.le, lo);
            try self.em.movReg(T0, T1);
            try self.em.bind(lo);
            try self.em.movImm64(T1, 0xFFFF_FFFF_8000_0000); // Int.MIN (sign-extended)
            try self.em.cmpReg(T0, T1);
            try self.em.jcc(.ge, done32);
            try self.em.movReg(T0, T1);
            try self.em.bind(done32);
        }
        try self.storeSlot(dst, T0);
    }
    fn ucomiFloat(self: *Compiler, x: jit.Xmm, y: jit.Xmm, is32: bool) !void {
        if (is32) try self.em.ucomiss(x, y) else try self.em.ucomisd(x, y);
    }

    /// Emit an `f64`/`f32` BinOp (arithmetic or NaN-aware comparison). Operands
    /// and result move through their slots as raw bits; comparisons yield a 0/1
    /// boolean in `T0`. `is32` selects single- vs double-precision SSE.
    fn emitFloatBinOp(self: *Compiler, b: anytype, is32: bool) !void {
        if (b.op == .Mod) return jit.JitError.Unsupported; // no float remainder
        try self.loadFloat(X0, b.lhs, is32);
        try self.loadFloat(X1, b.rhs, is32);
        if (isCmpBinOp(b.op)) {
            // IEEE/Kotlin: any comparison with NaN is false except `!=`.
            switch (b.op) {
                // a<b ≡ b>a, a<=b ≡ b>=a: `seta`/`setae` give 0 on unordered.
                .Less => {
                    try self.ucomiFloat(X1, X0, is32);
                    try self.em.setccReg(.a, T0);
                },
                .LessEq => {
                    try self.ucomiFloat(X1, X0, is32);
                    try self.em.setccReg(.ae, T0);
                },
                .Greater => {
                    try self.ucomiFloat(X0, X1, is32);
                    try self.em.setccReg(.a, T0);
                },
                .GreaterEq => {
                    try self.ucomiFloat(X0, X1, is32);
                    try self.em.setccReg(.ae, T0);
                },
                .Eq => {
                    try self.ucomiFloat(X0, X1, is32);
                    try self.em.setccReg(.e, T0); // ZF=1
                    try self.em.setccReg(.np, T1); // ordered
                    try self.em.andReg(T0, T1);
                },
                .NotEq => {
                    try self.ucomiFloat(X0, X1, is32);
                    try self.em.setccReg(.ne, T0); // ZF=0
                    try self.em.setccReg(.p, T1); // unordered ⇒ !=
                    try self.em.orReg(T0, T1);
                },
                else => return jit.JitError.Unsupported,
            }
            try self.storeSlot(b.dst, T0);
            return;
        }
        if (is32) {
            switch (b.op) {
                .Add => try self.em.addss(X0, X1),
                .Sub => try self.em.subss(X0, X1),
                .Mul => try self.em.mulss(X0, X1),
                .Div => try self.em.divss(X0, X1),
                else => return jit.JitError.Unsupported,
            }
            try self.storeF32Slot(b.dst, X0);
        } else {
            switch (b.op) {
                .Add => try self.em.addsd(X0, X1),
                .Sub => try self.em.subsd(X0, X1),
                .Mul => try self.em.mulsd(X0, X1),
                .Div => try self.em.divsd(X0, X1),
                else => return jit.JitError.Unsupported,
            }
            try self.storeF64Slot(b.dst, X0);
        }
    }

    fn exitLabel(self: *Compiler, blk: BlockId) !jit.Label {
        for (self.exit_targets.items, 0..) |t, i| {
            if (t.int() == blk.int()) return self.exit_labels.items[i];
        }
        const l = try self.em.newLabel();
        self.exit_targets.append(self.a, blk) catch return jit.JitError.OutOfMemory;
        self.exit_labels.append(self.a, l) catch return jit.JitError.OutOfMemory;
        return l;
    }

    fn edgeLabel(self: *Compiler, target: BlockId) !jit.Label {
        if (self.inBody(target)) return self.block_label[target.int()].?;
        return self.exitLabel(target);
    }

    /// A deopt stub for resuming the interpreter at the current instruction.
    fn deoptLabel(self: *Compiler) !jit.Label {
        const code = if (self.deopt_override) |p|
            encodeResume(BlockId.from(p.b), p.i)
        else
            encodeResume(self.cur_block, self.cur_inst);
        for (self.deopt_codes.items, 0..) |c, i| {
            if (c == code) return self.deopt_labels.items[i];
        }
        const l = try self.em.newLabel();
        self.deopt_codes.append(self.a, code) catch return jit.JitError.OutOfMemory;
        self.deopt_labels.append(self.a, l) catch return jit.JitError.OutOfMemory;
        return l;
    }

    fn arrayOf(self: *Compiler, recv: Reg) !ArrayInfo {
        if (recv.int() < self.array_info.len) {
            if (self.array_info[recv.int()]) |ai| return ai;
        }
        return jit.JitError.Unsupported;
    }

    /// Load array `index` into rax, bounds-check against the array length, and
    /// leave the buffer pointer in rcx. On out-of-bounds, deopt at the current
    /// instruction (the interpreter re-runs it and throws).
    fn emitBoundsAndPtr(self: *Compiler, ai: ArrayInfo, index: Reg) !void {
        try self.loadSlot(T0, index); // rax = index
        try self.em.loadMem(T1, REGS, @intCast(@as(u64, ai.len_slot) * 8)); // rcx = len
        try self.em.cmpReg(T0, T1);
        try self.em.jcc(.ge, try self.deoptLabel()); // index >= len
        try self.em.cmpImm32(T0, 0);
        try self.em.jcc(.l, try self.deoptLabel()); // index < 0
        try self.em.loadMem(T1, REGS, @intCast(@as(u64, ai.ptr_slot) * 8)); // rcx = ptr
    }

    /// Read one boxed element (a `List` / reference `Array` of a uniform scalar
    /// kind) into the destination's scalar slot. The stride is a whole `Value`,
    /// which no SIB scale reaches, so the element address is computed; the
    /// element's tag is guarded exactly as a native field read guards a field's,
    /// and a mismatch deopts to re-run the subscript interpreted.
    fn emitBoxedGet(self: *Compiler, ai: ArrayInfo, op: ArrayOp) !void {
        try self.emitBoundsAndPtr(ai, op.index); // rax=index, rcx=ptr
        var stride: u32 = VALUE_SIZE;
        while (stride > 1) : (stride >>= 1) try self.em.addReg(T0, T0);
        try self.em.addReg(T1, T0); // rcx = &items[index]
        try self.em.loadMemB(T0, T1, @intCast(self.val_tag_off));
        try self.em.cmpImm32(T0, ai.tag);
        try self.em.jcc(.ne, try self.deoptLabel());
        const payload: i32 = @intCast(self.val_payload_off);
        switch (ai.rt) {
            .f64 => {
                try self.em.movsdLoad(X0, T1, payload);
                try self.storeF64Slot(op.dst, X0);
            },
            .f32 => {
                try self.em.movssLoad(X0, T1, payload);
                try self.storeF32Slot(op.dst, X0);
            },
            .boolean => {
                try self.em.loadMemB(T0, T1, payload);
                try self.storeSlot(op.dst, T0);
            },
            .i32 => {
                try self.em.loadMem(T0, T1, payload);
                try self.em.movsxd(T0, T0);
                try self.storeSlot(op.dst, T0);
            },
            .i64 => {
                try self.em.loadMem(T0, T1, payload);
                try self.storeSlot(op.dst, T0);
            },
            else => return jit.JitError.Unsupported,
        }
    }

    /// Signed divide/remainder of T0 (dividend) by T1 (divisor), result in T0.
    /// Divide-by-zero deopts to the current instruction (the interpreter throws
    /// the same `ArithmeticException`). Divisor == -1 is special-cased to avoid
    /// the x86 INT_MIN/-1 #DE while matching Kotlin's wrapping semantics.
    fn emitDivMod(self: *Compiler, is_mod: bool, is_i32: bool) !void {
        try self.em.cmpImm32(T1, 0);
        try self.em.jcc(.e, try self.deoptLabel());
        const neg1 = try self.em.newLabel();
        const done = try self.em.newLabel();
        try self.em.cmpImm32(T1, -1);
        try self.em.jcc(.e, neg1);
        try self.em.cqo(); // sign-extend rax into rdx:rax
        try self.em.idivReg(T1); // quotient->rax, remainder->rdx
        if (is_mod) try self.em.movReg(T0, T2);
        try self.em.jmp(done);
        try self.em.bind(neg1);
        if (is_mod) {
            try self.em.movImm64(T0, 0); // a % -1 == 0
        } else {
            try self.em.negReg(T0); // a / -1 == -a (wraps for MIN; fixed below)
        }
        try self.em.bind(done);
        if (is_i32) try self.em.movsxd(T0, T0);
    }

    /// Host call trampoline: rdi = *TrampCtx, rsi = site index, rax = the host
    /// callback. It performs the site's operation (call / member / field / object
    /// move / null test / subscript), writing scalar results to slots and object
    /// results to the frame registers, and returns 0 to continue native or a
    /// non-zero resume code (deopt / throw) which exits straight through the
    /// epilogue with rax intact.
    /// Emit an inlined call: copy each scalar arg into the callee's (remapped)
    /// parameter slot, emit the callee's single block remapped into the caller's
    /// extended register space, then copy the (remapped) return value to the dst.
    /// Prove the per-iteration receiver's class, jumping to `miss` otherwise.
    /// The receiver lives in a FRAME register (objects are not slot-backed), so
    /// this reads its `Value` through the frame base. `identity` is the address
    /// of the class cell's data, which is what `instanceClassIdentity` returns.
    fn emitReceiverGuard(self: *Compiler, recv_reg: u32, class: usize, miss: jit.Label) !void {
        try self.em.loadMem(T1, REGS, slotBytes(self.regs_ptr_slot));
        try self.em.addImm32(T1, @intCast(recv_reg * VALUE_SIZE));
        try self.em.loadMemB(T0, T1, @intCast(self.val_tag_off));
        try self.em.cmpImm32(T0, instanceTagValue());
        try self.em.jcc(.ne, miss);
        try self.em.loadMem(T1, T1, @intCast(self.val_payload_off));
        try self.em.loadMem(T0, T1, @intCast(INST_CLASS_OFF));
        try self.em.addImm32(T0, @intCast(CELL_DATA_OFF));
        try self.em.movImm64(T2, class);
        try self.em.cmpReg(T0, T2);
        try self.em.jcc(.ne, miss);
    }

    /// Every inline site at the current position. A single unguarded site is
    /// spliced outright; guarded arms form a chain ending in the trampoline.
    fn emitInlinedChain(self: *Compiler) !void {
        var first: ?*const InlineSite = null;
        var n_arms: usize = 0;
        for (self.inline_sites) |*s| {
            if (s.block.int() != self.cur_block.int() or s.inst != self.cur_inst) continue;
            if (first == null) first = s;
            n_arms += 1;
        }
        const head = first orelse return;
        if (!head.guarded) {
            try self.emitInlinedBody(head);
            return;
        }
        const done = try self.em.newLabel();
        for (self.inline_sites) |*s| {
            if (s.block.int() != self.cur_block.int() or s.inst != self.cur_inst) continue;
            const miss = try self.em.newLabel();
            try self.emitReceiverGuard(s.recv_reg, s.guard_class, miss);
            try self.emitInlinedBody(s);
            try self.em.jmp(done);
            try self.em.bind(miss);
        }
        // Every arm missed: the class is one this loop was not specialized for.
        try self.emitCallSite(head.fallback_site);
        try self.em.bind(done);
    }

    fn emitInlinedBody(self: *Compiler, site: *const InlineSite) !void {
        const saved = self.deopt_override;
        self.deopt_override = site.resume_at;
        defer self.deopt_override = saved;
        var order_buf: [INLINE_MAX_BLOCKS]u32 = undefined;
        const order = calleeBlockOrder(site.callee, &order_buf) orelse return jit.JitError.Unsupported;
        if (order.len == 1) {
            var field_n: u32 = 0;
            try self.emitInlinedBlock(site, &site.callee.blocks[order[0]], &field_n);
            if (site.has_result) {
                const ret = site.callee.blocks[order[0]].terminator.Return.?;
                try self.loadSlot(T0, Reg.from(site.base + ret.int()));
                try self.storeSlot(site.dst, T0);
            }
            return;
        }
        // A branching callee splices as blocks: each gets a label in the
        // caller's code, its edges jump between them, and every return lands on
        // one join after delivering the result.
        var label_of = [_]?jit.Label{null} ** CALLEE_BLOCK_LIMIT;
        for (order) |b| label_of[b] = try self.em.newLabel();
        const join = try self.em.newLabel();
        var field_n: u32 = 0;
        for (order) |b| {
            const blk = &site.callee.blocks[b];
            try self.em.bind(label_of[b].?);
            try self.emitInlinedBlock(site, blk, &field_n);
            switch (blk.terminator) {
                .Goto => |t| try self.em.jmp(label_of[t.int()] orelse return jit.JitError.Unsupported),
                .Branch => |br| {
                    try self.loadSlot(T0, Reg.from(site.base + br.cond.int()));
                    try self.em.testReg(T0, T0);
                    try self.em.jcc(.ne, label_of[br.t.int()] orelse return jit.JitError.Unsupported);
                    try self.em.jmp(label_of[br.f.int()] orelse return jit.JitError.Unsupported);
                },
                .Return => |r| {
                    if (site.has_result) {
                        try self.loadSlot(T0, Reg.from(site.base + (r orelse return jit.JitError.Unsupported).int()));
                        try self.storeSlot(site.dst, T0);
                    }
                    try self.em.jmp(join);
                },
                else => return jit.JitError.Unsupported,
            }
        }
        try self.em.bind(join);
    }

    /// One spliced callee block: bind its parameter loads to the call's argument
    /// slots, turn its `this`-field accesses into the caller's registered field
    /// sites (consumed in body order, which is why `field_n` threads across
    /// blocks), and emit the rest remapped into the caller's register space.
    fn emitInlinedBlock(self: *Compiler, site: *const InlineSite, blk: *const ir.Block, field_n: *u32) !void {
        for (blk.insts) |*ci| {
            if (ci.* == .LoadParam) {
                const lp = ci.LoadParam;
                if (site.is_member and lp.idx == 0) continue; // receiver: field sites read it
                const arg_i: u32 = if (site.is_member) lp.idx - 1 else lp.idx;
                try self.loadSlot(T0, Reg.from(site.args_reg + arg_i));
                try self.storeSlot(Reg.from(site.base + lp.dst.int()), T0);
                continue;
            }
            if (site.is_member) {
                if (trampolinableFieldOf(self.module, ci) != null or trampolinableFieldSetOf(self.module, ci) != null) {
                    try self.emitCallSite(site.field_site_base + field_n.*);
                    field_n.* += 1;
                    continue;
                }
            }
            const rinst = remapInst(ci.*, site.base);
            try self.emitInstBody(&rinst);
        }
    }

    /// A call straight into another compiled unit. The callee is a deopt-free
    /// method body over the SAME receiver, so the whole calling convention is
    /// three stores and a `call`: its scalar arguments, the receiver's field
    /// base (this unit's own — a self call shares the receiver), and the slots
    /// pointer the unit was compiled to read. Its only outcome is RETURN, so
    /// there is no resume code to interpret and no register to rebox; the
    /// result comes back out of the callee's own result slot.
    fn emitDirectCall(self: *Compiler, site: *const DirectSite) !void {
        const saved = self.deopt_override;
        self.deopt_override = site.resume_at;
        defer self.deopt_override = saved;
        const cal = site.callee;
        var i: u32 = 1;
        while (i < cal.n_params) : (i += 1) {
            try self.loadSlot(T0, Reg.from(site.args_reg + i));
            try self.em.storeMem(REGS, slotBytes(site.slot_base + cal.param_slot_base + i), T0);
        }
        try self.em.loadMem(T0, REGS, slotBytes(site.fbase_slot));
        try self.em.storeMem(REGS, slotBytes(site.slot_base + cal.entry_fbase_slot), T0);
        try self.em.movReg(.rdi, REGS);
        try self.em.addImm32(.rdi, slotBytes(site.slot_base));
        try self.em.movImm64(.rax, @intFromPtr(cal.exec.mem.ptr));
        try self.em.callReg(.rax);
        if (site.may_deopt) {
            // The callee hands back its own resume code. RETURN is the only one
            // this frame can continue from; anything else re-runs the call in
            // the interpreter, which is where the real throw is raised. The
            // callee wrote no field, so re-running repeats nothing.
            try self.em.movImm64(T1, returnCode());
            try self.em.cmpReg(T0, T1);
            try self.em.jcc(.ne, try self.deoptLabel());
        }
        if (site.has_result) {
            try self.em.loadMem(T0, REGS, slotBytes(site.slot_base + cal.result_slot));
            try self.storeSlot(site.dst, T0);
        }
    }

    /// Native scalar field read/write on a loop-invariant receiver: the field
    /// buffer pointer is cached in `site.fbase_slot` at loop entry, so this is a
    /// direct memory access with no host callback. A read guards the field value's
    /// `Value` tag and deopts (re-runs the instruction in the interpreter) on a
    /// mismatch — the field's scalar shape changed under the loop.
    fn emitNativeField(self: *Compiler, site: *const CallSite) !void {
        const byte_off: i32 = @intCast(site.field_idx * FIELD_STRIDE + FIELD_VALUE_OFF);
        const payload_off: i32 = byte_off + @as(i32, @intCast(self.val_payload_off));
        const tag_off: i32 = byte_off + @as(i32, @intCast(self.val_tag_off));
        // T1 = receiver field buffer pointer.
        try self.em.loadMem(T1, REGS, @intCast(@as(u64, site.fbase_slot) * 8));
        if (site.is_field) {
            const rt = typeOf(self.types, Reg.from(site.dst_reg));
            // Tag guard: the field value must still hold the expected scalar
            // kind. An NN-proven read (declared non-nullable scalar) skips it
            // — no deopt edge.
            if (!site.nn) {
                try self.em.loadMemB(T0, T1, tag_off);
                try self.em.cmpImm32(T0, site.tag);
                try self.em.jcc(.ne, try self.deoptLabel());
            }
            switch (rt) {
                .f64 => {
                    try self.em.movsdLoad(X0, T1, payload_off);
                    try self.storeF64Slot(Reg.from(site.dst_reg), X0);
                },
                .f32 => {
                    try self.em.movssLoad(X0, T1, payload_off);
                    try self.storeF32Slot(Reg.from(site.dst_reg), X0);
                },
                .boolean => {
                    try self.em.loadMemB(T0, T1, payload_off);
                    try self.storeSlot(Reg.from(site.dst_reg), T0);
                },
                .i32 => {
                    try self.em.loadMem(T0, T1, payload_off);
                    try self.em.movsxd(T0, T0);
                    try self.storeSlot(Reg.from(site.dst_reg), T0);
                },
                else => { // .i64
                    try self.em.loadMem(T0, T1, payload_off);
                    try self.storeSlot(Reg.from(site.dst_reg), T0);
                },
            }
            return;
        }
        // Field store: write the source scalar payload, then stamp the field's tag
        // to the source's scalar kind (correct even if the field was previously null).
        const rt = typeOf(self.types, Reg.from(site.src_reg));
        switch (rt) {
            .f64 => {
                try self.loadF64Slot(X0, Reg.from(site.src_reg));
                try self.em.movsdStore(T1, payload_off, X0);
            },
            .f32 => {
                try self.loadF32Slot(X0, Reg.from(site.src_reg));
                try self.em.movssStore(T1, payload_off, X0);
            },
            else => {
                try self.loadSlot(T0, Reg.from(site.src_reg));
                try self.em.storeMem(T1, payload_off, T0);
            },
        }
        try self.em.storeMemBImm(T1, tag_off, tagForRt(rt) orelse return jit.JitError.Unsupported);
    }

    fn emitCallSite(self: *Compiler, si: u32) !void {
        if (self.call_sites[si].native) {
            try self.emitNativeField(&self.call_sites[si]);
            return;
        }
        try self.em.loadMem(.rdi, REGS, @intCast(@as(u64, self.uc_slot) * 8));
        try self.em.movImm64(.rsi, @intCast(si));
        try self.em.loadMem(.rax, REGS, @intCast(@as(u64, self.tramp_slot) * 8));
        try self.em.callReg(.rax);
        try self.em.testReg(.rax, .rax);
        try self.em.jcc(.ne, self.epilogue);
    }

    fn emitInst(self: *Compiler, inst: *const Inst) !void {
        // An inlined call splices the callee's body in place: bind params, emit the
        // remapped callee instructions, copy the return value to the call's dst.
        // `cur_inst` stays the call's instruction, so any deopt inside the body
        // resumes there and the interpreter re-runs the (pure) call.
        if (self.inlineSiteAt()) |_| {
            try self.emitInlinedChain();
            return;
        }
        if (self.directSiteAt()) |site| {
            try self.emitDirectCall(site);
            return;
        }
        // The receiver Move a direct call consumed: its destination is an object
        // register nothing else reads, and copying its slot would move garbage.
        for (self.skip_insts) |p| {
            if (p.b == self.cur_block.int() and p.i == self.cur_inst) return;
        }
        // A trampolined site (call / member / field / object op / subscript) is a
        // host callback; checked first so an object-collection subscript is not
        // mistaken for a native packed-array access.
        if (self.siteIndexAt()) |si| {
            try self.emitCallSite(si);
            return;
        }
        // A move into, or null test of, a nullable-scalar register manages its
        // companion null flag natively.
        if (try self.emitNullable(inst)) return;
        try self.emitInstBody(inst);
    }

    /// The native codegen for a single instruction, without the site / inline /
    /// nullable dispatch — so a remapped inlined-callee instruction (which never
    /// contains a call or object op) can be emitted directly.
    fn emitInstBody(self: *Compiler, inst: *const Inst) !void {
        if (arrayOpOf(self.module, inst)) |op| {
            const ai = try self.arrayOf(op.recv);
            if (ai.boxed) {
                if (op.is_set) return jit.JitError.Unsupported;
                try self.emitBoxedGet(ai, op);
                return;
            }
            try self.emitBoundsAndPtr(ai, op.index); // rax=index, rcx=ptr
            if (op.is_set) {
                try self.loadSlot(T2, op.value);
                try self.em.storeSib(T1, T0, ai.esize, T2, ai.w);
            } else {
                try self.em.loadSib(T2, T1, T0, ai.esize, ai.w);
                try self.storeSlot(op.dst, T2);
            }
            return;
        }
        if (numericConvOf(self.module, inst)) |nc| {
            const from = typeOf(self.types, nc.src);
            switch (nc.to) {
                .f64 => {
                    if (from == .f64) { // identity
                        try self.loadSlot(T0, nc.src);
                        try self.storeSlot(nc.dst, T0);
                    } else if (from == .f32) { // f32 -> f64 (exact)
                        try self.loadF32Slot(X0, nc.src);
                        try self.em.cvtss2sd(X0, X0);
                        try self.storeF64Slot(nc.dst, X0);
                    } else if (isNumeric(from)) { // int -> double (always exact)
                        try self.loadSlot(T0, nc.src);
                        try self.em.cvtsi2sd(X0, T0);
                        try self.storeF64Slot(nc.dst, X0);
                    } else return jit.JitError.Unsupported;
                },
                .f32 => {
                    if (from == .f32) { // identity
                        try self.loadSlot(T0, nc.src);
                        try self.storeSlot(nc.dst, T0);
                    } else if (from == .f64) { // f64 -> f32 (round to nearest)
                        try self.loadF64Slot(X0, nc.src);
                        try self.em.cvtsd2ss(X0, X0);
                        try self.storeF32Slot(nc.dst, X0);
                    } else if (isNumeric(from)) { // int -> float
                        try self.loadSlot(T0, nc.src);
                        try self.em.cvtsi2ss(X0, T0);
                        try self.storeF32Slot(nc.dst, X0);
                    } else return jit.JitError.Unsupported;
                },
                .i64, .i32 => {
                    if (isFloat(from)) {
                        // float -> int with Kotlin clamping (NaN→0, overflow→MIN/MAX).
                        try self.emitFloatToInt(nc.src, nc.dst, from == .f32, nc.to == .i32);
                    } else if (isNumeric(from)) {
                        // int width change: copy the (sign-extended) bits — i32→i64
                        // is a no-op, i64→i32 truncates at rebox (Kotlin `Long.toInt`
                        // = low 32).
                        try self.loadSlot(T0, nc.src);
                        try self.storeSlot(nc.dst, T0);
                    } else return jit.JitError.Unsupported;
                },
                else => return jit.JitError.Unsupported,
            }
            return;
        }
        if (bitwiseOpOf(self.module, inst)) |bo| {
            const lt = typeOf(self.types, bo.lhs);
            const rt = typeOf(self.types, bo.rhs);
            // Integer operands only — a float (or a user-typed receiver whose
            // `and`/`shl` is a user operator) falls back to the interpreter.
            if (!isNumeric(lt) or isFloat(lt) or !isNumeric(rt) or isFloat(rt))
                return jit.JitError.Unsupported;
            const w64 = lt == .i64;
            try self.loadSlot(T0, bo.lhs);
            try self.loadSlot(T1, bo.rhs); // shift count lands in cl (T1 == rcx)
            switch (bo.kind) {
                .@"and" => try self.em.andReg(T0, T1),
                .@"or" => try self.em.orReg(T0, T1),
                .xor => try self.em.xorReg(T0, T1),
                .shl => try self.em.shlCl(T0, w64),
                .sar => try self.em.sarCl(T0, w64),
            }
            // Re-normalize a 32-bit result to a sign-extended slot (the 32-bit
            // shift already cleared the high half; and/or/xor used the 64-bit op).
            if (typeOf(self.types, bo.dst) == .i32) try self.em.movsxd(T0, T0);
            try self.storeSlot(bo.dst, T0);
            return;
        }
        switch (inst.*) {
            .Const => |c| {
                const cv = self.module.consts.items[c.value.int()];
                const t = constType(cv);
                if (t == .unknown) return jit.JitError.Unsupported;
                // float and integer consts both land as raw bits in the slot.
                const bits = if (isFloat(t)) constFloatBits(cv) else constI64(cv);
                try self.em.movImm64(T0, @bitCast(bits));
                try self.storeSlot(c.dst, T0);
            },
            .Move => |m| {
                try self.loadSlot(T0, m.src);
                try self.storeSlot(m.dst, T0);
            },
            .BinOp => |b| {
                const is_cmp = isCmpBinOp(b.op);
                const is_arith = isArithBinOp(b.op);
                const is_div = isDivBinOp(b.op);
                // A bitwise/shift BinOp: the same emit `bitwiseOpOf` uses for the
                // call-shaped spelling, which was unreachable from this form —
                // one `xor` written as an operator made the whole body
                // uncompilable even though the machinery was right there.
                if (isBitwiseBinOp(b.op)) {
                    const blt = typeOf(self.types, b.lhs);
                    const brt = typeOf(self.types, b.rhs);
                    if (!isNumeric(blt) or isFloat(blt) or !isNumeric(brt) or isFloat(brt))
                        return jit.JitError.Unsupported;
                    const bw64 = blt == .i64;
                    try self.loadSlot(T0, b.lhs);
                    try self.loadSlot(T1, b.rhs); // shift count lands in cl (T1 == rcx)
                    switch (b.op) {
                        .And => try self.em.andReg(T0, T1),
                        .Or => try self.em.orReg(T0, T1),
                        .Xor => try self.em.xorReg(T0, T1),
                        .Shl => try self.em.shlCl(T0, bw64),
                        .Shr => try self.em.sarCl(T0, bw64),
                        .UShr => {
                            // A 32-bit value sits SIGN-extended in its slot, so a
                            // logical shift has to clear the high half first or
                            // the shifted-in bits come from the sign. Masking
                            // through a scratch register is the one spelling both
                            // emitters share.
                            if (!bw64) {
                                try self.em.movImm64(T2, 0xFFFF_FFFF);
                                try self.em.andReg(T0, T2);
                            }
                            try self.em.shrCl(T0, bw64);
                        },
                        else => return jit.JitError.Unsupported,
                    }
                    if (typeOf(self.types, b.dst) == .i32) try self.em.movsxd(T0, T0);
                    try self.storeSlot(b.dst, T0);
                    return;
                }
                if (!is_cmp and !is_arith and !is_div) return jit.JitError.Unsupported;
                const lt = typeOf(self.types, b.lhs);
                const rt = typeOf(self.types, b.rhs);
                // float path: both operands must be the SAME float width (a mixed
                // int/float or f32/f64 op needs a conversion the fast paths don't
                // emit inline).
                if (isFloat(lt) or isFloat(rt)) {
                    if (lt != rt) return jit.JitError.Unsupported;
                    try self.emitFloatBinOp(b, lt == .f32);
                    return;
                }
                if (!isNumeric(lt) or !isNumeric(rt))
                    return jit.JitError.Unsupported;
                try self.loadSlot(T0, b.lhs);
                try self.loadSlot(T1, b.rhs);
                if (is_cmp) {
                    try self.em.cmpReg(T0, T1);
                    try self.em.setccReg(switch (b.op) {
                        .Eq => .e,
                        .NotEq => .ne,
                        .Less => .l,
                        .LessEq => .le,
                        .Greater => .g,
                        .GreaterEq => .ge,
                        else => unreachable,
                    }, T0);
                } else if (is_arith) {
                    switch (b.op) {
                        .Add => try self.em.addReg(T0, T1),
                        .Sub => try self.em.subReg(T0, T1),
                        .Mul => try self.em.imulReg(T0, T1),
                        else => unreachable,
                    }
                    if (typeOf(self.types, b.dst) == .i32) try self.em.movsxd(T0, T0);
                } else {
                    try self.emitDivMod(b.op == .Mod, typeOf(self.types, b.dst) == .i32);
                }
                try self.storeSlot(b.dst, T0);
            },
            .Not => |n| {
                // The source must live in a typed scalar slot: an object-typed
                // register (a boxed call result) keeps its value in the frame,
                // and its slot holds garbage.
                if (!isScalarRt(typeOf(self.types, n.src))) return jit.JitError.Unsupported;
                try self.loadSlot(T0, n.src);
                try self.em.cmpImm32(T0, 0); // src == 0 ? -> 1 (logical negation)
                try self.em.setccReg(.e, T0);
                try self.storeSlot(n.dst, T0);
            },
            .UnOp => |u| {
                if (!isNumeric(typeOf(self.types, u.operand))) return jit.JitError.Unsupported;
                try self.loadSlot(T0, u.operand);
                switch (u.op) {
                    .Neg => try self.em.negReg(T0),
                    .Inc => try self.em.addImm32(T0, 1),
                    .Dec => try self.em.addImm32(T0, -1),
                    .Plus => {},
                }
                if (typeOf(self.types, u.dst) == .i32) try self.em.movsxd(T0, T0);
                try self.storeSlot(u.dst, T0);
            },
            // The cell's live scalar is cached in the cell register's own slot:
            // CellGet copies it out, CellSet copies a value in. Entry/exit move
            // it through the box (see runLoop).
            .CellGet => |cg| {
                if (cg.cell.int() >= self.cell_info.len or self.cell_info[cg.cell.int()] == null)
                    return jit.JitError.Unsupported;
                try self.loadSlot(T0, cg.cell);
                try self.storeSlot(cg.dst, T0);
            },
            .CellSet => |cs| {
                if (cs.cell.int() >= self.cell_info.len) return jit.JitError.Unsupported;
                const crt = self.cell_info[cs.cell.int()] orelse return jit.JitError.Unsupported;
                if (typeOf(self.types, cs.value) != crt) return jit.JitError.Unsupported;
                try self.loadSlot(T0, cs.value);
                try self.storeSlot(cs.cell, T0);
            },
            // Function-JIT: copy a scalar param from its entry-filled slot.
            .LoadParam => |lp| {
                if (!self.func_mode or lp.idx >= self.n_params) return jit.JitError.Unsupported;
                // An object param lives in a FRAME register (seeded before
                // entry — the method receiver's field-buffer pointer
                // likewise); the slot load is a no-op.
                if (typeOf(self.types, lp.dst) == .object) return;
                try self.em.loadMem(T0, REGS, @intCast(@as(u64, self.param_slot_base + lp.idx) * 8));
                try self.storeSlot(lp.dst, T0);
            },
            .Trace => {},
            else => return jit.JitError.Unsupported,
        }
    }

    fn emitBlock(self: *Compiler, bid: BlockId, blk: *const ir.Block) !void {
        self.cur_block = bid;
        for (blk.insts, 0..) |*inst, i| {
            self.cur_inst = @intCast(i);
            try self.emitInst(inst);
        }
        switch (blk.terminator) {
            .Goto => |target| try self.em.jmp(try self.edgeLabel(target)),
            .Branch => |br| {
                try self.loadSlot(T0, br.cond);
                try self.em.testReg(T0, T0);
                try self.em.jcc(.ne, try self.edgeLabel(br.t));
                try self.em.jmp(try self.edgeLabel(br.f));
            },
            // Function-JIT: write the scalar return value (if any) to the result
            // slot, then exit with the RETURN sentinel. The bit pattern copies for
            // any scalar kind; `runFunc` reboxes it to the declared return type.
            .Return => |maybe_reg| {
                if (!self.func_mode) return jit.JitError.Unsupported;
                // Per-return delivery: a slot-typed value copies into
                // `result_slot` (and clears the frame marker); a
                // frame-resident one (object / escape-typed — its value lives
                // in the frame register, written there by the handlers)
                // records its REGISTER INDEX in `result_reg_slot` so
                // `runFunc` reads the frame.
                var frame_reg: i64 = -1;
                if (maybe_reg) |r| {
                    const rt = typeOf(self.types, r);
                    if (rt == .unknown or rt == .object) {
                        frame_reg = @intCast(r.int());
                    } else {
                        try self.loadSlot(T0, r);
                        try self.em.storeMem(REGS, @intCast(@as(u64, self.result_slot) * 8), T0);
                    }
                }
                try self.em.movImm64(T0, @bitCast(frame_reg));
                try self.em.storeMem(REGS, @intCast(@as(u64, self.result_reg_slot) * 8), T0);
                try self.em.movImm64(.rax, returnCode());
                try self.em.jmp(self.epilogue);
            },
            else => return jit.JitError.Unsupported,
        }
    }

    pub fn run(self: *Compiler) !void {
        try self.em.push(REGS);
        try self.em.movReg(REGS, .rdi);
        for (self.body) |bid| {
            try self.em.bind(self.block_label[bid.int()].?);
            try self.emitBlock(bid, &self.func.blocks[bid.int()]);
        }
        for (self.exit_targets.items, 0..) |t, i| {
            try self.em.bind(self.exit_labels.items[i]);
            try self.em.movImm64(.rax, encodeResume(t, 0));
            try self.em.jmp(self.epilogue);
        }
        for (self.deopt_codes.items, 0..) |code, i| {
            try self.em.bind(self.deopt_labels.items[i]);
            try self.em.movImm64(.rax, code);
            try self.em.jmp(self.epilogue);
        }
        try self.em.bind(self.epilogue);
        try self.em.pop(REGS);
        try self.em.ret();
    }
};
