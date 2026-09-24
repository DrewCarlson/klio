//! Loop region analysis: successor and dominator walks, natural loop body collection,
//! and the read/def sets deciding which registers are live in and out of the region.

const std = @import("std");
const ir = @import("../ir.zig");

const common = @import("common.zig");
const shapes = @import("shapes.zig");
const type_infer = @import("types.zig");
const code_cache = @import("cache.zig");

const Module = ir.Module;
const Func = ir.Func;
const Inst = ir.Inst;
const Reg = ir.Reg;
const BlockId = ir.BlockId;
const Allocator = std.mem.Allocator;

const fjEscapeEnabled = code_cache.fjEscapeEnabled;
const RegType = common.RegType;
const arrayOpOf = shapes.arrayOpOf;
const bitwiseOpOf = shapes.bitwiseOpOf;
const numericConvOf = shapes.numericConvOf;
const trampolinableCallOf = shapes.trampolinableCallOf;
const trampolinableCallValueOf = shapes.trampolinableCallValueOf;
const trampolinableFieldOf = shapes.trampolinableFieldOf;
const trampolinableFieldSetOf = shapes.trampolinableFieldSetOf;
const trampolinableGlobalOf = shapes.trampolinableGlobalOf;
const trampolinableMemberOf = shapes.trampolinableMemberOf;
const trampolinableVirtualOf = shapes.trampolinableVirtualOf;
const isScalarRt = type_infer.isScalarRt;

pub fn succEach(term: ir.Terminator, out: *std.ArrayList(BlockId), a: Allocator) Allocator.Error!void {
    switch (term) {
        .Goto => |b| try out.append(a, b),
        .Branch => |br| {
            try out.append(a, br.t);
            try out.append(a, br.f);
        },
        else => {},
    }
}

/// Every CFG successor of a terminator, of all kinds, for dominance analysis.
fn fullSucc(term: ir.Terminator, out: *std.ArrayList(BlockId), a: Allocator) Allocator.Error!void {
    switch (term) {
        .Goto => |b| try out.append(a, b),
        .Branch => |br| {
            try out.append(a, br.t);
            try out.append(a, br.f);
        },
        .Switch => |sw| {
            for (sw.arms) |arm| try out.append(a, arm.target);
            try out.append(a, sw.default);
        },
        else => {},
    }
}

/// `dom[i]`: every path from the function entry to `i` goes through `header`, computed
/// as the complement of reachable-without-entering-header. Caller frees.
fn dominatedSet(a: Allocator, func: *const Func, nb: usize, header: BlockId) Allocator.Error![]bool {
    const reach_no_h = try a.alloc(bool, nb);
    defer a.free(reach_no_h);
    @memset(reach_no_h, false);
    var stack: std.ArrayList(BlockId) = .empty;
    defer stack.deinit(a);
    var succ: std.ArrayList(BlockId) = .empty;
    defer succ.deinit(a);
    const entry = func.entry;
    if (entry.int() < nb and entry.int() != header.int()) {
        reach_no_h[entry.int()] = true;
        try stack.append(a, entry);
    }
    while (stack.pop()) |b| {
        succ.clearRetainingCapacity();
        try fullSucc(func.blocks[b.int()].terminator, &succ, a);
        for (succ.items) |s| {
            if (s.int() < nb and s.int() != header.int() and !reach_no_h[s.int()]) {
                reach_no_h[s.int()] = true;
                try stack.append(a, s);
            }
        }
    }
    const dom = try a.alloc(bool, nb);
    for (0..nb) |i| dom[i] = !reach_no_h[i]; // unreachable while avoiding header => dominated
    dom[header.int()] = true;
    return dom;
}

pub fn collectLoop(a: Allocator, func: *const Func, header: BlockId) Allocator.Error!?[]BlockId {
    const nb = func.blocks.len;
    if (nb == 0 or header.int() >= nb) return null;

    const dom = try dominatedSet(a, func, nb, header);
    defer a.free(dom);

    const reach = try a.alloc(bool, nb);
    defer a.free(reach);
    @memset(reach, false);
    var stack: std.ArrayList(BlockId) = .empty;
    defer stack.deinit(a);
    var succ: std.ArrayList(BlockId) = .empty;
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

    const be = try a.alloc(bool, nb);
    defer a.free(be);
    @memset(be, false);
    var any_be = false;
    for (func.blocks, 0..) |*blk, i| {
        if (!reach[i] or !dom[i]) continue; // a real back-edge source is dominated by the header
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
        if (be[i] and !inloop[i]) {
            inloop[i] = true;
            try stack.append(a, BlockId.from(@intCast(i)));
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

    // A natural loop is entered only through its header: if a non-header loop block has a
    // predecessor outside the loop, `header` is not the real entry, so the region is rejected.
    for (0..nb) |i| {
        if (!inloop[i] or i == header.int()) continue;
        for (preds[i].items) |p| {
            if (!inloop[p.int()]) return null;
        }
    }

    var body: std.ArrayList(BlockId) = .empty;
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

fn buildPreds(a: Allocator, func: *const Func, nb: usize, reach: []const bool) Allocator.Error![]std.ArrayList(BlockId) {
    const preds = try a.alloc(std.ArrayList(BlockId), nb);
    for (preds) |*p| p.* = .empty;
    var succ: std.ArrayList(BlockId) = .empty;
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

pub fn typeAt(types: []const RegType, r: Reg) RegType {
    return if (r.int() < types.len) types[r.int()] else .unknown;
}

/// An object-vs-null comparison, emitted as a null-test callback on the boxed register
/// rather than a native scalar compare.
pub fn isNullCheckBinOp(types: []const RegType, b: anytype) bool {
    if (b.op != .Eq and b.op != .NotEq and b.op != .IdentEq and b.op != .IdentNeq) return false;
    const lt = typeAt(types, b.lhs);
    const rt = typeAt(types, b.rhs);
    return (lt == .object and rt == .null_) or (lt == .null_ and rt == .object) or (lt == .object and rt == .object);
}

/// Instructions safe to run as an interpreter ESCAPE from a compiled body: those whose
/// arm neither parks the coroutine machinery nor manipulates the try/finally stack.
/// Escaped bodies already exclude try-regions, and `.flat_call` outcomes discard and deopt.
pub fn execEscapable(inst: *const Inst) bool {
    if (!fjEscapeEnabled()) return false;
    return switch (inst.*) {
        .SuspendResumePoint => false,
        else => true,
    };
}

pub fn instReadsDef(module: *const Module, inst: *const Inst, reads: *[8]Reg, n_reads: *usize, def: *?Reg, types: []const RegType) void {
    n_reads.* = 0;
    def.* = null;
    if (arrayOpOf(module, inst)) |op| {
        reads[0] = op.index;
        if (op.is_set) {
            reads[1] = op.value;
            n_reads.* = 2;
            return;
        }
        n_reads.* = 1;
        // Only a packed-array element is a scalar def: an object or map subscript writes a
        // boxed or nullable register.
        if (typeAt(types, op.dst) == .object) return;
        def.* = op.dst;
        return;
    }
    if (numericConvOf(module, inst)) |nc| {
        reads[0] = nc.src;
        n_reads.* = 1;
        def.* = nc.dst;
        return;
    }
    if (bitwiseOpOf(module, inst)) |bo| {
        reads[0] = bo.lhs;
        reads[1] = bo.rhs;
        n_reads.* = 2;
        def.* = bo.dst;
        return;
    }
    // A trampolined call reads its consecutive arg registers; its dst is a def only when
    // the callee returns a scalar, so an unused or Unit result forces no type requirement.
    if (trampolinableCallOf(inst)) |tc| {
        var k: u8 = 0;
        while (k < tc.n_args and k < 6) : (k += 1) reads[k] = Reg.from(tc.args_reg + k);
        n_reads.* = tc.n_args;
        if (isScalarRt(typeAt(types, tc.dst))) def.* = tc.dst;
        return;
    }
    if (trampolinableMemberOf(module, inst)) |mc| {
        const recv_scalar: usize = if (isScalarRt(typeAt(types, mc.recv))) 1 else 0;
        if (recv_scalar != 0) reads[0] = mc.recv;
        var k: u8 = 0;
        while (k < mc.n_args and k < 6) : (k += 1) {
            reads[recv_scalar + k] = Reg.from(mc.args_reg + k);
        }
        n_reads.* = recv_scalar + @as(usize, mc.n_args);
        if (isScalarRt(typeAt(types, mc.dst))) def.* = mc.dst;
        return;
    }
    if (trampolinableVirtualOf(inst)) |vc| {
        var k: u8 = 0;
        while (k < vc.n_args and k < 6) : (k += 1) reads[k] = Reg.from(vc.args_reg + k);
        n_reads.* = vc.n_args;
        if (isScalarRt(typeAt(types, vc.dst))) def.* = vc.dst;
        return;
    }
    if (trampolinableFieldOf(module, inst)) |fld| {
        n_reads.* = 0;
        if (isScalarRt(typeAt(types, fld.dst))) def.* = fld.dst;
        return;
    }
    if (trampolinableFieldSetOf(module, inst)) |fs| {
        reads[0] = fs.value;
        n_reads.* = 1;
        return;
    }
    if (trampolinableCallValueOf(inst)) |cvc| {
        var k: u8 = 0;
        while (k < cvc.n_args and k < 6) : (k += 1) reads[k] = Reg.from(cvc.args_reg + k);
        n_reads.* = cvc.n_args;
        return;
    }
    if (trampolinableGlobalOf(module, inst) != null) return;
    switch (inst.*) {
        .Const => |c| def.* = c.dst,
        .Move => |m| {
            if (typeAt(types, m.dst) == .object or typeAt(types, m.src) == .object) return;
            reads[0] = m.src;
            n_reads.* = 1;
            def.* = m.dst;
        },
        .BinOp => |b| {
            if (isNullCheckBinOp(types, b)) {
                def.* = b.dst;
                return;
            }
            reads[0] = b.lhs;
            reads[1] = b.rhs;
            n_reads.* = 2;
            def.* = b.dst;
        },
        .Not => |n| {
            reads[0] = n.src;
            n_reads.* = 1;
            def.* = n.dst;
        },
        .UnOp => |u| {
            reads[0] = u.operand;
            n_reads.* = 1;
            def.* = u.dst;
        },
        // The cell register is unboxed at entry and reboxed at exit by the cell machinery,
        // not by the scalar read/def sets.
        .CellGet => |cg| def.* = cg.dst,
        .CellSet => |cs| {
            reads[0] = cs.value;
            n_reads.* = 1;
        },
        else => {},
    }
}

pub const LoopSets = struct { read: []bool, def: []bool };

pub fn computeSets(a: Allocator, module: *const Module, func: *const Func, body: []const BlockId, header: BlockId, n_regs: u32, types: []const RegType) Allocator.Error!LoopSets {
    const nb = func.blocks.len;
    const in_body = try a.alloc(bool, nb);
    defer a.free(in_body);
    @memset(in_body, false);
    for (body) |b| in_body[b.int()] = true;

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
        var reads: [8]Reg = undefined;
        var nr: usize = 0;
        var df: ?Reg = null;
        for (blk.insts) |*inst| {
            instReadsDef(module, inst, &reads, &nr, &df, types);
            for (reads[0..nr]) |rr| {
                if (rr.int() < n_regs and !d[rr.int()]) u[rr.int()] = true;
            }
            if (df) |dd| if (dd.int() < n_regs) {
                d[dd.int()] = true;
                def_all[dd.int()] = true;
            };
        }
        switch (blk.terminator) {
            .Branch => |br| if (br.cond.int() < n_regs and !d[br.cond.int()]) {
                u[br.cond.int()] = true;
            },
            else => {},
        }
        use[bid.int()] = u;
        def_b[bid.int()] = d;
    }

    const live_in = try a.alloc([]bool, nb);
    defer {
        for (body) |b| a.free(live_in[b.int()]);
        a.free(live_in);
    }
    for (body) |b| {
        live_in[b.int()] = try a.alloc(bool, n_regs);
        @memset(live_in[b.int()], false);
    }
    var succ: std.ArrayList(BlockId) = .empty;
    defer succ.deinit(a);
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < 64) : (iters += 1) {
        changed = false;
        for (body) |bid| {
            const blk = &func.blocks[bid.int()];
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
