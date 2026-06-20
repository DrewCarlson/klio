//! Stage-3 JIT: compile a hot natural loop to native x86-64 machine code.
//!
//! Additive tier over the IR interpreter (see plans/JIT-DESIGN.md). The loop's
//! IR registers live as i64 slots in a scratch register file; the emitted code
//! reads/writes those slots (rax/rcx scratch — no register allocator) and runs
//! the loop natively, eliminating Value boxing, member dispatch, and the
//! per-instruction interpreter overhead. At a loop edge that leaves the compiled
//! region (or a failed guard) the native code returns the BlockId+inst index to
//! resume, and the interpreter continues there with the registers reboxed.
//!
//! Gated behind `KLIO_JIT` and entered only when the live-in registers' runtime
//! types match the statically-inferred ones; otherwise the interpreter runs the
//! loop unchanged. So the build stays correct with the JIT off (default) or on.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");
const jit = @import("jit");

const Value = runtime.Value;
const Module = ir.Module;
const Func = ir.Func;
const Inst = ir.Inst;
const Reg = ir.Reg;
const BlockId = ir.BlockId;
const Allocator = std.mem.Allocator;
const E = jit.Reg;

// Native register assignment. `REGS` (callee-saved) holds the regs64 base
// pointer for the whole loop; `T0`/`T1` are per-instruction scratch.
const REGS: E = .rbx;
const T0: E = .rax;
const T1: E = .rcx;

/// Static type of an IR register, for normalization and reboxing.
pub const RegType = enum(u8) { i32, i64, boolean, unit, null_, unknown };

/// The native loop returns `(block_id << 1) | resume_in_interpreter`. For now
/// every return resumes the interpreter at the start of the target block
/// (inst 0); the low bit is reserved for future mid-block deopt.
fn encodeResume(blk: BlockId) u64 {
    return @as(u64, blk.int());
}

pub const CompiledLoop = struct {
    exec: jit.ExecBuf,
    n_regs: u32,
    reg_types: []RegType,
    read_set: []bool, // reg is read somewhere in the loop (must unbox at entry)
    def_set: []bool, // reg is written somewhere in the loop (rebox at exit)
    allocator: Allocator,

    pub fn deinit(self: *CompiledLoop) void {
        self.exec.deinit();
        self.allocator.free(self.reg_types);
        self.allocator.free(self.read_set);
        self.allocator.free(self.def_set);
    }
};

// --- supported-shape predicates ---------------------------------------------

fn constType(c: ir.Const) RegType {
    return switch (c) {
        .Int, .Char, .Short, .Byte => .i32,
        .Long => .i64,
        .Bool => .boolean,
        .Unit => .unit,
        .Null => .null_,
        else => .unknown,
    };
}

fn constI64(c: ir.Const) i64 {
    return switch (c) {
        .Int => |x| x,
        .Char => |x| x,
        .Short => |x| x,
        .Byte => |x| x,
        .Long => |x| x,
        .Bool => |b| if (b) 1 else 0,
        else => 0, // Unit / Null carried as 0; never used arithmetically.
    };
}

fn isNumeric(t: RegType) bool {
    return t == .i32 or t == .i64;
}

fn isArithBinOp(op: ir.BinOp) bool {
    return switch (op) {
        .Add, .Sub, .Mul => true,
        else => false,
    };
}
fn isCmpBinOp(op: ir.BinOp) bool {
    return switch (op) {
        .Eq, .NotEq, .Less, .LessEq, .Greater, .GreaterEq => true,
        else => false,
    };
}

// --- whole-function static type inference -----------------------------------

fn inferTypes(a: Allocator, module: *const Module, func: *const Func, n_regs: u32) Allocator.Error![]RegType {
    const types = try a.alloc(RegType, n_regs);
    @memset(types, .unknown);
    // Fixpoint: a BinOp result type depends on its operands, which may be
    // defined later in the block order (loop back-edges).
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < 16) : (iters += 1) {
        changed = false;
        for (func.blocks) |*blk| {
            for (blk.insts) |*inst| {
                const before = setDefType(types, module, inst);
                if (before) changed = true;
            }
        }
    }
    return types;
}

/// Update `types` for the register `inst` defines; return true if it changed.
fn setDefType(types: []RegType, module: *const Module, inst: *const Inst) bool {
    const dst_t: ?struct { r: Reg, t: RegType } = switch (inst.*) {
        .Const => |c| .{ .r = c.dst, .t = constType(module.consts.items[c.value.int()]) },
        .Move => |m| .{ .r = m.dst, .t = typeOf(types, m.src) },
        .BinOp => |b| blk: {
            if (isCmpBinOp(b.op)) break :blk .{ .r = b.dst, .t = .boolean };
            if (isArithBinOp(b.op)) {
                const lt = typeOf(types, b.lhs);
                const rt = typeOf(types, b.rhs);
                // Prefer a known operand type; both should agree in valid Kotlin.
                const t: RegType = if (lt != .unknown) lt else rt;
                break :blk .{ .r = b.dst, .t = t };
            }
            break :blk null;
        },
        else => null,
    };
    if (dst_t) |d| {
        if (d.r.int() < types.len and types[d.r.int()] != d.t and d.t != .unknown) {
            types[d.r.int()] = d.t;
            return true;
        }
    }
    return false;
}

fn typeOf(types: []const RegType, r: Reg) RegType {
    if (r.int() < types.len) return types[r.int()];
    return .unknown;
}

// --- loop detection ---------------------------------------------------------

fn succEach(term: ir.Terminator, out: *std.ArrayListUnmanaged(BlockId), a: Allocator) Allocator.Error!void {
    switch (term) {
        .Goto => |b| try out.append(a, b),
        .Branch => |br| {
            try out.append(a, br.t);
            try out.append(a, br.f);
        },
        else => {}, // unsupported terminator => no in-loop successors
    }
}

/// Collect the natural loop with `header`, or null if `header` is not a loop
/// header or the loop is not a compilable shape. The returned slice is the set
/// of blocks belonging to the loop (caller frees).
fn collectLoop(a: Allocator, func: *const Func, header: BlockId) Allocator.Error!?[]BlockId {
    const nb = func.blocks.len;
    if (nb == 0 or header.int() >= nb) return null;

    // Forward reachability from the header (only through Goto/Branch edges).
    const reach = try a.alloc(bool, nb);
    defer a.free(reach);
    @memset(reach, false);
    var stack: std.ArrayListUnmanaged(BlockId) = .empty;
    defer stack.deinit(a);
    var succ: std.ArrayListUnmanaged(BlockId) = .empty;
    defer succ.deinit(a);
    reach[header.int()] = true;
    try stack.append(a, header);
    while (stack.pop()) |b| {
        succ.clearRetainingCapacity();
        try succEach(func.blocks[b.int()].terminator, &succ, a);
        for (succ.items) |s| {
            if (s.int() < nb and !reach[s.int()]) {
                reach[s.int()] = true;
                try stack.append(a, s);
            }
        }
    }

    // Back-edge sources: reachable blocks whose terminator targets the header.
    const be = try a.alloc(bool, nb);
    defer a.free(be);
    @memset(be, false);
    var any_be = false;
    for (func.blocks, 0..) |*blk, i| {
        if (!reach[i]) continue;
        succ.clearRetainingCapacity();
        try succEach(blk.terminator, &succ, a);
        for (succ.items) |s| {
            if (s.int() == header.int()) {
                be[i] = true;
                any_be = true;
            }
        }
    }
    if (!any_be) return null;

    // Loop body = header plus every reachable block that can reach a back-edge
    // source. Reverse BFS over predecessor edges restricted to `reach`.
    const preds = try buildPreds(a, func, nb, reach);
    defer {
        for (preds) |*p| p.deinit(a);
        a.free(preds);
    }
    const inloop = try a.alloc(bool, nb);
    defer a.free(inloop);
    @memset(inloop, false);
    inloop[header.int()] = true;
    stack.clearRetainingCapacity();
    for (0..nb) |i| {
        if (be[i]) {
            if (!inloop[i]) {
                inloop[i] = true;
                try stack.append(a, BlockId.from(@intCast(i)));
            }
        }
    }
    while (stack.pop()) |b| {
        for (preds[b.int()].items) |p| {
            if (!inloop[p.int()]) {
                inloop[p.int()] = true;
                try stack.append(a, p);
            }
        }
    }

    var body: std.ArrayListUnmanaged(BlockId) = .empty;
    errdefer body.deinit(a);
    for (0..nb) |i| {
        if (inloop[i]) try body.append(a, BlockId.from(@intCast(i)));
    }
    if (body.items.len == 0 or body.items.len > 256) {
        body.deinit(a);
        return null;
    }
    return try body.toOwnedSlice(a);
}

fn buildPreds(a: Allocator, func: *const Func, nb: usize, reach: []const bool) Allocator.Error![]std.ArrayListUnmanaged(BlockId) {
    const preds = try a.alloc(std.ArrayListUnmanaged(BlockId), nb);
    for (preds) |*p| p.* = .empty;
    var succ: std.ArrayListUnmanaged(BlockId) = .empty;
    defer succ.deinit(a);
    for (func.blocks, 0..) |*blk, i| {
        if (!reach[i]) continue;
        succ.clearRetainingCapacity();
        try succEach(blk.terminator, &succ, a);
        for (succ.items) |s| {
            if (s.int() < nb) try preds[s.int()].append(a, BlockId.from(@intCast(i)));
        }
    }
    return preds;
}

// --- liveness (which registers the loop reads as live-in / writes) ----------

fn instReadsDef(inst: *const Inst, reads: *[3]Reg, n_reads: *usize, def: *?Reg) void {
    n_reads.* = 0;
    def.* = null;
    switch (inst.*) {
        .Const => |c| def.* = c.dst,
        .Move => |m| {
            reads[0] = m.src;
            n_reads.* = 1;
            def.* = m.dst;
        },
        .BinOp => |b| {
            reads[0] = b.lhs;
            reads[1] = b.rhs;
            n_reads.* = 2;
            def.* = b.dst;
        },
        else => {},
    }
}

const LoopSets = struct { read: []bool, def: []bool };

/// `read` = registers live-in at the loop header (read before any def along some
/// path through the loop); `def` = registers written anywhere in the loop.
fn computeSets(a: Allocator, func: *const Func, body: []const BlockId, header: BlockId, n_regs: u32) Allocator.Error!LoopSets {
    const nb = func.blocks.len;
    const in_body = try a.alloc(bool, nb);
    defer a.free(in_body);
    @memset(in_body, false);
    for (body) |b| in_body[b.int()] = true;

    // Per-block use/def, plus the global def set.
    const use = try a.alloc([]bool, nb);
    const def_b = try a.alloc([]bool, nb);
    defer {
        for (body) |b| {
            a.free(use[b.int()]);
            a.free(def_b[b.int()]);
        }
        a.free(use);
        a.free(def_b);
    }
    const def_all = try a.alloc(bool, n_regs);
    @memset(def_all, false);

    for (body) |bid| {
        const u = try a.alloc(bool, n_regs);
        const d = try a.alloc(bool, n_regs);
        @memset(u, false);
        @memset(d, false);
        const blk = &func.blocks[bid.int()];
        var reads: [3]Reg = undefined;
        var nr: usize = 0;
        var df: ?Reg = null;
        for (blk.insts) |*inst| {
            instReadsDef(inst, &reads, &nr, &df);
            for (reads[0..nr]) |rr| {
                if (rr.int() < n_regs and !d[rr.int()]) u[rr.int()] = true;
            }
            if (df) |dd| if (dd.int() < n_regs) {
                d[dd.int()] = true;
                def_all[dd.int()] = true;
            };
        }
        // Terminator reads (Branch cond).
        switch (blk.terminator) {
            .Branch => |br| if (br.cond.int() < n_regs and !d[br.cond.int()]) {
                u[br.cond.int()] = true;
            },
            else => {},
        }
        use[bid.int()] = u;
        def_b[bid.int()] = d;
    }

    // Backward liveness fixpoint over loop blocks.
    const live_in = try a.alloc([]bool, nb);
    defer {
        for (body) |b| a.free(live_in[b.int()]);
        a.free(live_in);
    }
    for (body) |b| {
        live_in[b.int()] = try a.alloc(bool, n_regs);
        @memset(live_in[b.int()], false);
    }
    var succ: std.ArrayListUnmanaged(BlockId) = .empty;
    defer succ.deinit(a);
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < 64) : (iters += 1) {
        changed = false;
        for (body) |bid| {
            const blk = &func.blocks[bid.int()];
            // live_out = union of live_in[succ] for in-loop successors.
            const li = live_in[bid.int()];
            const u = use[bid.int()];
            const d = def_b[bid.int()];
            succ.clearRetainingCapacity();
            succEach(blk.terminator, &succ, a) catch {};
            var r: usize = 0;
            while (r < n_regs) : (r += 1) {
                var live_out = false;
                for (succ.items) |s| {
                    if (s.int() < nb and in_body[s.int()] and live_in[s.int()][r]) {
                        live_out = true;
                        break;
                    }
                }
                const new_li = u[r] or (live_out and !d[r]);
                if (new_li and !li[r]) {
                    li[r] = true;
                    changed = true;
                }
            }
        }
    }

    const read = try a.alloc(bool, n_regs);
    @memcpy(read, live_in[header.int()]);
    return .{ .read = read, .def = def_all };
}

// --- compilation ------------------------------------------------------------

const Compiler = struct {
    a: Allocator,
    module: *const Module,
    func: *const Func,
    body: []const BlockId,
    types: []const RegType,
    n_regs: u32,
    em: jit.Emitter,
    /// Per-block native label (only for in-loop blocks).
    block_label: []?jit.Emitter.Label,
    /// Exit stubs: target block -> label that returns its encoded resume.
    exit_targets: std.ArrayListUnmanaged(BlockId),
    exit_labels: std.ArrayListUnmanaged(jit.Emitter.Label),
    epilogue: jit.Emitter.Label,

    fn inBody(self: *Compiler, b: BlockId) bool {
        for (self.body) |x| if (x.int() == b.int()) return true;
        return false;
    }

    fn slotDisp(self: *Compiler, r: Reg) ?i32 {
        const off: u64 = @as(u64, r.int()) * 8;
        if (off > std.math.maxInt(i32)) return null;
        if (r.int() >= self.n_regs) return null;
        return @intCast(off);
    }

    fn markRead(self: *Compiler, r: Reg) void {
        _ = self;
        _ = r;
    }
    fn markDef(self: *Compiler, r: Reg) void {
        _ = self;
        _ = r;
    }

    fn loadSlot(self: *Compiler, native: E, r: Reg) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.loadMem(native, REGS, d);
    }
    fn storeSlot(self: *Compiler, r: Reg, native: E) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.storeMem(REGS, d, native);
    }

    fn exitLabel(self: *Compiler, blk: BlockId) !jit.Emitter.Label {
        for (self.exit_targets.items, 0..) |t, i| {
            if (t.int() == blk.int()) return self.exit_labels.items[i];
        }
        const l = try self.em.newLabel();
        self.exit_targets.append(self.a, blk) catch return jit.JitError.OutOfMemory;
        self.exit_labels.append(self.a, l) catch return jit.JitError.OutOfMemory;
        return l;
    }

    /// A jump to `target`: the in-loop block label or an exit stub.
    fn edgeLabel(self: *Compiler, target: BlockId) !jit.Emitter.Label {
        if (self.inBody(target)) {
            return self.block_label[target.int()].?;
        }
        return self.exitLabel(target);
    }

    fn emitInst(self: *Compiler, inst: *const Inst) !void {
        switch (inst.*) {
            .Const => |c| {
                const t = constType(self.module.consts.items[c.value.int()]);
                if (t == .unknown) return jit.JitError.Unsupported;
                const v = constI64(self.module.consts.items[c.value.int()]);
                try self.em.movImm64(T0, @bitCast(v));
                try self.storeSlot(c.dst, T0);
                self.markDef(c.dst);
            },
            .Move => |m| {
                self.markRead(m.src);
                try self.loadSlot(T0, m.src);
                try self.storeSlot(m.dst, T0);
                self.markDef(m.dst);
            },
            .BinOp => |b| {
                if (!isArithBinOp(b.op) and !isCmpBinOp(b.op)) return jit.JitError.Unsupported;
                if (!isNumeric(typeOf(self.types, b.lhs)) or !isNumeric(typeOf(self.types, b.rhs)))
                    return jit.JitError.Unsupported;
                self.markRead(b.lhs);
                self.markRead(b.rhs);
                try self.loadSlot(T0, b.lhs);
                try self.loadSlot(T1, b.rhs);
                if (isCmpBinOp(b.op)) {
                    try self.em.cmpReg(T0, T1);
                    const cc: jit.Emitter.SetCc = switch (b.op) {
                        .Eq => .e,
                        .NotEq => .ne,
                        .Less => .l,
                        .LessEq => .le,
                        .Greater => .g,
                        .GreaterEq => .ge,
                        else => unreachable,
                    };
                    try self.em.setccReg(cc, T0);
                } else {
                    switch (b.op) {
                        .Add => try self.em.addReg(T0, T1),
                        .Sub => try self.em.subReg(T0, T1),
                        .Mul => try self.em.imulReg(T0, T1),
                        else => unreachable,
                    }
                    if (typeOf(self.types, b.dst) == .i32) try self.em.movsxd(T0, T0);
                }
                try self.storeSlot(b.dst, T0);
                self.markDef(b.dst);
            },
            .Trace => {}, // span marker — no code
            else => return jit.JitError.Unsupported,
        }
    }

    fn emitBlock(self: *Compiler, blk: *const ir.Block) !void {
        for (blk.insts) |*inst| try self.emitInst(inst);
        switch (blk.terminator) {
            .Goto => |target| {
                try self.em.jmp(try self.edgeLabel(target));
            },
            .Branch => |br| {
                self.markRead(br.cond);
                try self.loadSlot(T0, br.cond);
                try self.em.testReg(T0, T0);
                // nonzero (true) -> t ; else fall through to f.
                try self.em.jcc(.ne, try self.edgeLabel(br.t));
                try self.em.jmp(try self.edgeLabel(br.f));
            },
            else => return jit.JitError.Unsupported,
        }
    }

    fn run(self: *Compiler) !void {
        // Prologue: save rbx, load regs base.
        try self.em.push(REGS);
        try self.em.movReg(REGS, .rdi);
        // Emit each loop block in body order; the header is first.
        for (self.body) |bid| {
            try self.em.bind(self.block_label[bid.int()].?);
            try self.emitBlock(&self.func.blocks[bid.int()]);
        }
        // Exit stubs: load encoded resume target, jump to epilogue.
        for (self.exit_targets.items, 0..) |t, i| {
            try self.em.bind(self.exit_labels.items[i]);
            try self.em.movImm64(.rax, encodeResume(t));
            try self.em.jmp(self.epilogue);
        }
        try self.em.bind(self.epilogue);
        try self.em.pop(REGS);
        try self.em.ret();
    }
};

/// Try to compile the natural loop whose header is `header`. Returns a compiled
/// loop on success, or null if the loop is not a supported shape.
pub fn tryCompile(a: Allocator, module: *const Module, func: *const Func, header: BlockId) Allocator.Error!?CompiledLoop {
    const body = (try collectLoop(a, func, header)) orelse {
        if (debugEnabled()) std.debug.print("[jit]   bail: collectLoop null (header {d})\n", .{header.int()});
        return null;
    };
    defer a.free(body);

    if (debugEnabled()) {
        for (body) |bid| {
            const blk = &func.blocks[bid.int()];
            std.debug.print("[jit]   body block {d}: ", .{bid.int()});
            for (blk.insts) |*inst| std.debug.print("{s} ", .{@tagName(inst.*)});
            std.debug.print("| term {s}\n", .{@tagName(blk.terminator)});
        }
    }
    // Validate: every loop block must use only supported insts + Goto/Branch.
    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        switch (blk.terminator) {
            .Goto, .Branch => {},
            else => {
                if (debugEnabled()) std.debug.print("[jit]   bail: block {d} terminator {s}\n", .{ bid.int(), @tagName(blk.terminator) });
                return null;
            },
        }
        for (blk.insts) |*inst| {
            switch (inst.*) {
                .Const, .Move, .BinOp, .Trace => {},
                else => {
                    if (debugEnabled()) std.debug.print("[jit]   bail: block {d} inst {s}\n", .{ bid.int(), @tagName(inst.*) });
                    return null;
                },
            }
        }
    }

    const n_regs: u32 = func.n_locals;
    const types = try inferTypes(a, module, func, n_regs);
    const sets = try computeSets(a, func, body, header, n_regs);
    // From here, `types`, `sets.read`, `sets.def` are owned; free on any bail.
    var ok = false;
    defer if (!ok) {
        a.free(types);
        a.free(sets.read);
        a.free(sets.def);
    };

    // Require every read/def reg to have a known scalar type (for unbox/rebox).
    for (0..n_regs) |r| {
        if ((sets.read[r] or sets.def[r]) and types[r] == .unknown) {
            if (debugEnabled()) {
                std.debug.print("[jit]   bail: reg {d} unknown type (read={} def={})\n", .{ r, sets.read[r], sets.def[r] });
                for (body) |bid| {
                    const blk = &func.blocks[bid.int()];
                    for (blk.insts) |*inst| {
                        var rd: [3]Reg = undefined;
                        var nr: usize = 0;
                        var df: ?Reg = null;
                        instReadsDef(inst, &rd, &nr, &df);
                        const dt: RegType = if (df) |d| (if (d.int() < n_regs) types[d.int()] else .unknown) else .unknown;
                        std.debug.print("[jit]     b{d} {s} dst={?d} t={s}\n", .{ bid.int(), @tagName(inst.*), if (df) |d| d.int() else null, @tagName(dt) });
                    }
                }
            }
            return null;
        }
    }

    var c = Compiler{
        .a = a,
        .module = module,
        .func = func,
        .body = body,
        .types = types,
        .n_regs = n_regs,
        .em = jit.Emitter.init(a),
        .block_label = try a.alloc(?jit.Emitter.Label, func.blocks.len),
        .exit_targets = .empty,
        .exit_labels = .empty,
        .epilogue = undefined,
    };
    defer c.em.deinit();
    defer a.free(c.block_label);
    defer c.exit_targets.deinit(a);
    defer c.exit_labels.deinit(a);
    @memset(c.block_label, null);

    for (body) |bid| c.block_label[bid.int()] = c.em.newLabel() catch return null;
    c.epilogue = c.em.newLabel() catch return null;

    c.run() catch |e| {
        if (debugEnabled()) std.debug.print("[jit]   bail: codegen {s}\n", .{@errorName(e)});
        return null;
    };

    const exec = jit.finalize(c.em.code()) catch |e| {
        if (debugEnabled()) std.debug.print("[jit]   bail: finalize {s}\n", .{@errorName(e)});
        return null;
    };
    ok = true;
    return CompiledLoop{
        .exec = exec,
        .n_regs = n_regs,
        .reg_types = types,
        .read_set = sets.read,
        .def_set = sets.def,
        .allocator = a,
    };
}

// --- per-function JIT state + the interpreter hook --------------------------

/// Compile a loop header after it has been entered this many times.
const HOT_THRESHOLD: u32 = 64;

pub const FuncJit = struct {
    counts: []u32,
    /// Per loop-header block: present once compilation was attempted; the value
    /// is the compiled loop, or null when the header is not a compilable shape.
    loops: std.AutoHashMapUnmanaged(u32, ?CompiledLoop) = .empty,
    a: Allocator,

    pub fn deinit(self: *FuncJit) void {
        self.a.free(self.counts);
        var it = self.loops.valueIterator();
        while (it.next()) |v| if (v.*) |*cl| cl.deinit();
        self.loops.deinit(self.a);
    }
};

var jit_enabled_cache: ?bool = null;
var jit_debug_cache: ?bool = null;

fn debugEnabled() bool {
    if (jit_debug_cache) |d| return d;
    const v = runtime.getenvSlice("KLIO_JIT_DEBUG");
    const on = v != null and v.?.len > 0 and !std.mem.eql(u8, v.?, "0");
    jit_debug_cache = on;
    return on;
}

/// Whether the loop JIT is on (`KLIO_JIT` set to a non-empty, non-"0" value).
pub fn enabled() bool {
    if (jit_enabled_cache) |e| return e;
    const v = runtime.getenvSlice("KLIO_JIT");
    const on = v != null and v.?.len > 0 and !std.mem.eql(u8, v.?, "0");
    jit_enabled_cache = on;
    return on;
}

threadlocal var states: std.AutoHashMapUnmanaged(usize, *FuncJit) = .empty;
threadlocal var scratch: std.ArrayListUnmanaged(i64) = .empty;

/// Per-thread JIT state for `func`, created on first use. Uses the C allocator
/// (lives for the thread; the compiled code + counters are process-lifetime).
fn forFunc(func: *const Func) ?*FuncJit {
    const a = std.heap.page_allocator;
    const key = @intFromPtr(func);
    if (states.get(key)) |s| return s;
    if (func.blocks.len == 0) return null;
    const s = a.create(FuncJit) catch return null;
    s.* = .{ .counts = a.alloc(u32, func.blocks.len) catch {
        a.destroy(s);
        return null;
    }, .a = a };
    @memset(s.counts, 0);
    states.put(a, key, s) catch {
        a.free(s.counts);
        a.destroy(s);
        return null;
    };
    return s;
}

/// Interpreter hook: at the start of block `cur`, count the entry and — once
/// hot — compile and run the natural loop with that header. Returns the block
/// to resume at (registers reboxed) when a compiled loop ran, else null (the
/// interpreter executes the block normally). Only call with `KLIO_JIT` on.
pub fn maybeRunHot(module: *const Module, func: *const Func, regs: *std.ArrayList(Value), allocator: Allocator, cur: BlockId) ?BlockId {
    const fj = forFunc(func) orelse return null;
    const bi = cur.int();
    if (bi >= fj.counts.len) return null;

    if (!fj.loops.contains(bi)) {
        fj.counts[bi] += 1;
        if (fj.counts[bi] < HOT_THRESHOLD) return null;
        const compiled = tryCompile(std.heap.page_allocator, module, func, cur) catch null;
        if (debugEnabled()) {
            if (compiled != null) {
                std.debug.print("[jit] compiled loop {s} block {d}\n", .{ func.name, bi });
            } else {
                std.debug.print("[jit] NOT compilable: loop {s} block {d}\n", .{ func.name, bi });
            }
        }
        fj.loops.put(fj.a, bi, compiled) catch return null;
    }

    const entry = fj.loops.get(bi).?;
    if (entry == null) return null;
    const cl = &entry.?;

    // Ensure the frame has slots for every register the loop touches.
    if (regs.items.len < cl.n_regs) {
        regs.appendNTimes(allocator, .Unit, cl.n_regs - regs.items.len) catch return null;
    }
    scratch.ensureTotalCapacity(std.heap.page_allocator, cl.n_regs) catch return null;
    scratch.items.len = cl.n_regs;
    return switch (runLoop(cl, regs.items, scratch.items[0..cl.n_regs])) {
        .resume_at => |b| b,
        .bail => null,
    };
}

/// Outcome of attempting to run a compiled loop against a live register file.
pub const RunResult = union(enum) {
    /// Resume the interpreter at this block (registers already written back).
    resume_at: BlockId,
    /// Live-in types did not match; the loop was not entered. Interpret normally.
    bail,
};

/// Unbox the loop's read registers from `regs` (frame registers) into a scalar
/// file, run the native code, and rebox the written registers. `regs` is the
/// frame's register slice; `scratch` is a caller-provided i64 buffer of length
/// >= `n_regs`.
pub fn runLoop(self: *const CompiledLoop, regs: []Value, slots: []i64) RunResult {
    var r: usize = 0;
    while (r < self.n_regs) : (r += 1) {
        slots[r] = 0;
        if (!self.read_set[r]) continue;
        if (r >= regs.len) return .bail;
        const v = regs[r];
        switch (self.reg_types[r]) {
            .i32 => switch (v) {
                .Int => |x| slots[r] = x,
                .Char => |x| slots[r] = x,
                .Short => |x| slots[r] = x,
                .Byte => |x| slots[r] = x,
                else => return .bail,
            },
            .i64 => switch (v) {
                .Long => |x| slots[r] = x,
                else => return .bail,
            },
            .boolean => switch (v) {
                .Bool => |b| slots[r] = if (b) 1 else 0,
                else => return .bail,
            },
            .unit => if (v != .Unit) return .bail,
            .null_ => if (v != .Null) return .bail,
            .unknown => return .bail,
        }
    }

    const fnptr = self.exec.entry(*const fn ([*]i64) callconv(.c) u64);
    const code = fnptr(slots.ptr);
    const target = BlockId.from(@intCast(code));

    // Rebox written registers back into the frame.
    r = 0;
    while (r < self.n_regs) : (r += 1) {
        if (!self.def_set[r]) continue;
        if (r >= regs.len) continue;
        regs[r] = switch (self.reg_types[r]) {
            .i32 => .{ .Int = @truncate(slots[r]) },
            .i64 => .{ .Long = slots[r] },
            .boolean => .{ .Bool = slots[r] != 0 },
            .unit => .Unit,
            .null_ => .Null,
            .unknown => regs[r],
        };
    }
    return .{ .resume_at = target };
}
