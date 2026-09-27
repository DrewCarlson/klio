//! The program being lowered and the builder of one body: its blocks,
//! registers, locals, receivers, loops, finally blocks and inline regions.
//! Each body lowers on its own builder, in any order.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const bridge = @import("../../core/bridge.zig");
const records = @import("records.zig");
const compose = @import("compose.zig");
const env_mod = @import("env.zig");
const operator = @import("operator.zig");
const inline_mod = @import("inline.zig");
const locals_mod = @import("locals.zig");
const types_mod = @import("types.zig");

const Allocator = std.mem.Allocator;
const Sym = sema.Sym;
const BlockId = ir.BlockId;
const FuncId = ir.FuncId;
const Inst = ir.Inst;
const Reg = ir.Reg;
const Terminator = ir.Terminator;

pub const Error = records.Error;

pub const Program = struct {
    a: Allocator,
    s: *sema.Sema,
    br: *bridge.Bridge,
    m: *ir.Module,
    prims: *const operator.PrimTable,
    /// Every body's failures, in the order they happened.
    errors: std.ArrayList(LowerError) = .empty,
    /// By FuncId: its body is written.
    lowered: std.DynamicBitSetUnmanaged = .{},
    /// By FuncId: its body was tried, lowered or not. An instantiation
    /// lowers its callee first when it has not been tried.
    attempted: std.DynamicBitSetUnmanaged = .{},
    /// By FuncId: a lambda literal some body made a closure of. A literal
    /// only ever lowered in place at inline calls has no body of its own.
    closures: std.DynamicBitSetUnmanaged = .{},

    pub fn isLowered(p: *const Program, f: FuncId) bool {
        return f.int() < p.lowered.bit_length and p.lowered.isSet(f.int());
    }

    /// Whether `f` runs a native instead of a body.
    pub fn isNative(p: *const Program, f: FuncId) bool {
        const r = p.m.resolved orelse return false;
        return f.int() < r.func_native.len and r.func_native[f.int()] != .none;
    }

    /// Marks `f` tried; false when it already was.
    pub fn markAttempted(p: *Program, f: FuncId) Allocator.Error!bool {
        if (f.int() >= p.attempted.bit_length) try p.attempted.resize(p.a, @max(f.int() + 1, p.m.funcs.items.len), false);
        if (p.attempted.isSet(f.int())) return false;
        p.attempted.set(f.int());
        return true;
    }
};

pub const LowerError = struct { func: FuncId, span: span.Span, msg: []const u8 };

pub const BodyKind = enum { function, ctor, getter, setter, defaults, lambda, local_fun, init_unit, sam_ctor, sam_method, sam_equals, sam_hash_code, delegated, adapter, restart };

/// Where a local lives: a register, or a cell a nested body shares.
pub const Home = union(enum) { reg: Reg, cell: Reg };

/// A block while its body is written.
pub const BlockBuf = struct {
    insts: std.ArrayList(Inst) = .empty,
    /// Null until the block is terminated.
    terminator: ?Terminator = null,
    handlers: ir.BlockHandlers = .{},
};

/// An enclosing loop: where `break` and `continue` go.
pub const Loop = struct {
    /// Null for an unlabeled loop.
    label: ?[]const u8,
    break_to: BlockId,
    continue_to: BlockId,
    /// `finallys.items.len` at the loop's entry: a jump out replays the ones above.
    finally_depth: usize,
    /// `Builder.compose_open` at the loop's entry: a jump out closes the
    /// replace groups above it.
    compose_open: u32 = 0,
};

/// An enclosing `try`: a jump out of it pops its handler frame and replays
/// its `finally`.
pub const Finally = struct {
    /// Null for a `try` with catches only.
    block: ?*const ast.Block,
    /// The block whose handler frame is armed where the jump is: the try
    /// body's entry, or a catch handler the finally protects.
    try_entry: BlockId,
    /// A `try` of an inline function's body copied into this one: its
    /// finally is replayed from the copied IR, not from syntax.
    replay: ?*const inline_mod.FinallyReplay = null,
};

/// The record a lookup found missing, for the error the failed body reports.
pub const Miss = struct { node: ast.NodeId, what: []const u8 };

pub const zero_span: span.Span = .{ .file = span.FileId.from(0), .start = 0, .end = 0 };

pub const Builder = struct {
    p: *Program,
    recs: *const sema.output.FileRecords,
    file: u32,
    /// The function, constructor, property or lambda symbol whose body this is.
    owner: Sym,
    func: FuncId,
    kind: BodyKind,
    blocks: std.ArrayList(BlockBuf) = .empty,
    cur: BlockId = BlockId.from(0),
    next_reg: u32 = 0,
    locals: std.AutoHashMapUnmanaged(Sym, Home) = .empty,
    /// The registers that are homes of `var` locals, which a `val` bound to
    /// their value copies (`env.bindLocal`).
    var_homes: std.AutoHashMapUnmanaged(Reg, void) = .empty,
    /// What the statement or condition being lowered writes while the
    /// values it reads are in flight (`locals.Hazard`).
    hazard: ?*locals_mod.Hazard = null,
    /// The index in the entry block of the instruction `emitEntry` last
    /// appended, which is a register the body keeps.
    entry_last: usize = std.math.maxInt(usize),
    env: env_mod.Env = .{},
    /// This body's captures (`br.captures_of[func]`), read-only.
    captures: []const bridge.CaptureKey = &.{},
    loops: std.ArrayList(Loop) = .empty,
    finallys: std.ArrayList(Finally) = .empty,
    /// Inline instantiations and lambdas lowered in place, innermost last (D).
    regions: std.ArrayList(inline_mod.Region) = .empty,
    /// The innermost expression being lowered: a failure names it.
    cur_span: span.Span = zero_span,
    /// The kind of expression `cur_span` is.
    cur_kind: []const u8 = "body",
    /// Where a failure is reported before any expression names one: the
    /// declaration the body belongs to, or the reference an adapter serves.
    site: span.Span = zero_span,
    /// The last record a lookup found missing.
    miss: ?Miss = null,
    /// `Unit` in the entry block, once something asked for it.
    unit_reg: ?Reg = null,
    /// `null` in the entry block, once something asked for it.
    null_reg: ?Reg = null,
    /// A `tailrec` function's (`tailrec.zig`): the expressions in tail
    /// position, the block a tail call jumps to, and by parameter index
    /// the register the parameter is loaded into.
    tails: std.AutoHashMapUnmanaged(*const ast.Expr, void) = .empty,
    tail_head: ?BlockId = null,
    tail_params: []const ?Reg = &.{},
    /// A composable body's exit, where its own returns go once its groups
    /// close (`compose.zig`).
    compose_exit: ?compose.Exit = null,
    /// Replace groups the composable body has open where lowering is.
    compose_open: u32 = 0,
    /// An `@ExplicitGroupsComposable` body, which gets no groups added.
    compose_explicit: bool = false,
    /// The composable scope's change bits its calls forward, one register
    /// per `$changed` int: a skippable body's `$dirty`, else its
    /// `$changed`; and what each slot tracks.
    compose_dirty: []const Reg = &.{},
    compose_tracked: []const compose.Tracked = &.{},
    /// Whether a lambda literal here is remembered (`compose.memoizes`): in
    /// a composable body or an inline lambda in one, outside any `try`.
    compose_remember: bool = false,
    /// Whether `compose_dirty` is a skip gate's settled `$dirty`.
    compose_dirty_var: bool = false,
    /// The literal being lowered as an inline argument's value or inside a
    /// conversion remembered as a whole, which is not remembered itself.
    unmemoized: ?*const ast.Expr = null,
    /// In-place literals whose parameter may not compose.
    compose_disallowed: std.AutoHashMapUnmanaged(*const ast.Expr, void) = .empty,
    /// The literals an inline call now takes in place each compose in a
    /// group of their own (`compose.InlineGroups`).
    compose_lambda_groups: bool = false,
    /// The block scope a loop's group answers to (`compose.LoopGroups`).
    compose_block: compose.BlockScope = .{},
    /// The composer's `currentMarker` where the composable body started,
    /// read when a literal inside returns to it.
    compose_marker: ?Reg = null,

    /// A builder for `func`'s body over `file`'s records, with its entry block.
    pub fn init(p: *Program, file: u32, owner: Sym, func: FuncId, kind: BodyKind) Error!Builder {
        const br = p.br;
        var b: Builder = .{
            .p = p,
            .recs = recordsOf(br, file),
            .file = file,
            .owner = owner,
            .func = func,
            .kind = kind,
            .captures = if (func.int() < br.captures_of.len) br.captures_of[func.int()] else &.{},
        };
        b.cur = try b.newBlock();
        return b;
    }

    /// Reads records from `file` from here on: an init unit moving between
    /// the declarations it initializes.
    pub fn setFile(b: *Builder, file: u32) void {
        b.file = file;
        b.recs = recordsOf(b.p.br, file);
    }

    pub fn newReg(b: *Builder) Reg {
        const r = Reg.from(b.next_reg);
        b.next_reg += 1;
        return r;
    }

    pub fn newBlock(b: *Builder) Error!BlockId {
        const id = BlockId.from(@intCast(b.blocks.items.len));
        try b.blocks.append(b.p.a, .{});
        return id;
    }

    pub fn switchTo(b: *Builder, id: BlockId) void {
        b.cur = id;
    }

    /// Appends to the current block. Code after a terminator is dead: it
    /// goes into a fresh block nothing jumps to.
    pub fn emit(b: *Builder, inst: Inst) Error!void {
        if (b.terminated()) b.cur = try b.newBlock();
        var out = inst;
        // A call into another file's facade initializes that file first.
        if (out == .CallStatic and out.CallStatic.init == ir.NO_UNIT) {
            if (b.p.br.m.resolved) |r| out.CallStatic.init = ir.resolved.facadeEntry(r, b.func, out.CallStatic.func);
        }
        try b.blocks.items[b.cur.int()].insts.append(b.p.a, out);
    }

    /// Appends to the entry block, which dominates every use: a load with
    /// no effect the body reads anywhere (a parameter, a capture, `this`).
    pub fn emitEntry(b: *Builder, inst: Inst) Error!void {
        const entry = &b.blocks.items[0].insts;
        try entry.append(b.p.a, inst);
        b.entry_last = entry.items.len - 1;
    }

    pub fn emitConst(b: *Builder, c: ir.Const) Error!Reg {
        const dst = b.newReg();
        const id = try b.p.m.internConst(b.p.a, c);
        try b.emit(.{ .Const = .{ .dst = dst, .value = id } });
        return dst;
    }

    /// `Unit`, loaded once in the entry block.
    pub fn unit(b: *Builder) Error!Reg {
        if (b.unit_reg) |r| return r;
        const r = try b.entryConst(.Unit);
        b.unit_reg = r;
        return r;
    }

    /// `null`, loaded once in the entry block.
    pub fn nullValue(b: *Builder) Error!Reg {
        if (b.null_reg) |r| return r;
        const r = try b.entryConst(.Null);
        b.null_reg = r;
        return r;
    }

    fn entryConst(b: *Builder, c: ir.Const) Error!Reg {
        const dst = b.newReg();
        const id = try b.p.m.internConst(b.p.a, c);
        try b.emitEntry(.{ .Const = .{ .dst = dst, .value = id } });
        return dst;
    }

    /// Ends the current block. A block already ended keeps its terminator:
    /// whatever follows a `return` or `throw` never runs.
    pub fn terminate(b: *Builder, t: Terminator) void {
        const blk = &b.blocks.items[b.cur.int()];
        if (blk.terminator == null) blk.terminator = t;
    }

    pub fn terminated(b: *const Builder) bool {
        return b.blocks.items[b.cur.int()].terminator != null;
    }

    /// Moves `regs` into a fresh contiguous run and returns its first register.
    pub fn run(b: *Builder, regs: []const Reg) Error!Reg {
        const first = Reg.from(b.next_reg);
        for (regs) |r| try b.emit(.{ .Move = .{ .dst = b.newReg(), .src = r } });
        return first;
    }

    /// Tests `v` against `null`: the current block branches to `is_null` or
    /// `not_null`, both fresh and neither current.
    pub fn branchOnNull(b: *Builder, v: Reg) Error!NullSplit {
        const nul = try b.nullValue();
        const t = b.newReg();
        try b.emit(.{ .BinOp = .{ .dst = t, .op = .IdentEq, .lhs = v, .rhs = nul } });
        const split: NullSplit = .{ .is_null = try b.newBlock(), .not_null = try b.newBlock() };
        b.terminate(.{ .Branch = .{ .cond = t, .t = split.is_null, .f = split.not_null } });
        return split;
    }

    /// Records a lowering error for this body at `sp`, or at `site` when
    /// `sp` is the empty span of a body no expression has named yet; the
    /// body fails.
    pub fn fail(b: *Builder, sp: span.Span, comptime fmt: []const u8, args: anytype) Error {
        const msg = std.fmt.allocPrint(b.p.a, fmt, args) catch return error.OutOfMemory;
        const at = if (std.meta.eql(sp, zero_span)) b.site else sp;
        b.p.errors.append(b.p.a, .{ .func = b.func, .span = at, .msg = msg }) catch return error.OutOfMemory;
        return error.Unsupported;
    }

    /// Writes blocks, entry and n_locals into `p.m.funcs[func]`. A block
    /// nothing terminated is dead code and ends in `Unreachable`.
    pub fn finish(b: *Builder) Error!void {
        const a = b.p.a;
        try b.pruneDeadTypeValues();
        try b.coalesceCopies();
        try b.aliasRuns();
        const f = &b.p.m.funcs.items[b.func.int()];
        const blocks = try a.alloc(ir.Block, b.blocks.items.len);
        for (b.blocks.items, blocks, 0..) |*buf, *out, i| {
            out.* = .{
                .id = BlockId.from(@intCast(i)),
                .insts = try buf.insts.toOwnedSlice(a),
                .terminator = buf.terminator orelse .Unreachable,
            };
            if (buf.handlers.any()) {
                const h = try out.handlersMut(a);
                h.* = buf.handlers;
            }
        }
        f.blocks = blocks;
        f.entry = BlockId.from(0);
        f.n_locals = b.next_reg;
        const lw = &b.p.lowered;
        if (b.func.int() >= lw.bit_length) try lw.resize(a, @max(b.func.int() + 1, b.p.m.funcs.items.len), false);
        lw.set(b.func.int());
    }

    /// Drops what builds a run-time type value nothing reads: a reified
    /// argument an inline body only tests statically leaves the value its
    /// call built behind. Class literals, arrays and the base's type builders
    /// only allocate, and constants and copies only set registers.
    fn pruneDeadTypeValues(b: *Builder) Error!void {
        const builders = types_mod.typeBuilders(b);
        if (builders[0] == null) return;
        const reads = try b.p.a.alloc(u32, b.next_reg);
        const Count = struct {
            reads: []u32,
            fn cb(c: @This(), r: Reg, is_def: bool) void {
                if (!is_def and r.int() < c.reads.len) c.reads[r.int()] += 1;
            }
        };
        while (true) {
            @memset(reads, 0);
            for (b.blocks.items) |*blk| {
                for (blk.insts.items) |*inst| ir.visitInstRegs(inst, Count{ .reads = reads }, Count.cb);
                if (blk.terminator) |*t| ir.visitTerminatorRegs(t, Count{ .reads = reads }, Count.cb);
            }
            var removed = false;
            for (b.blocks.items) |*blk| {
                var i: usize = 0;
                while (i < blk.insts.items.len) {
                    if (deadTypePart(&blk.insts.items[i], builders, reads)) {
                        _ = blk.insts.orderedRemove(i);
                        removed = true;
                    } else i += 1;
                }
            }
            if (!removed) return;
        }
    }

    /// Drops a copy of a register only it reads into a register only it
    /// writes, when the instruction that wrote the source is earlier in the
    /// copy's block and nothing between them touches the destination: that
    /// instruction writes the destination itself. An argument run and a
    /// `val` copy a fresh temporary this way.
    fn coalesceCopies(b: *Builder) Error!void {
        try coalesceBlockCopies(b.p.a, b.blocks.items, b.next_reg);
    }

    /// Gives a call the registers its argument run copies as its run, when
    /// they are consecutive and nothing writes them between the copies and
    /// the call: `f(x)` and `x.g()` then pass `x`'s own register. The callee
    /// reads its parameters from the caller's registers, which the caller
    /// does not write while the call runs.
    fn aliasRuns(b: *Builder) Error!void {
        try aliasBlockRuns(b.p.a, b.blocks.items, b.next_reg);
    }

    pub const call = records.call;
    pub const callOf = records.callOf;
    pub const name = records.name;
    pub const names = records.names;
    pub const recv = records.recv;
    pub const typeTest = records.typeTest;
    pub const typeTests = records.typeTests;
    pub const ref = records.ref;
    pub const lambda = records.lambda;
    pub const returnTarget = records.returnTarget;
    pub const decl = records.decl;
    pub const exprType = records.exprType;
    pub const forGroup = records.forGroup;
    pub const compound = records.compound;
    pub const destructureEntry = records.destructureEntry;
    pub const whenPattern = records.whenPattern;
    pub const nameAt = records.nameAt;
    pub const nameMissed = records.nameMissed;
    pub const delegate = records.delegate;
    pub const supers = records.supers;
};

/// Whether `inst` builds part of a run-time type value that nothing reads
/// (with the constants and copies that fed it).
fn deadTypePart(inst: *const ir.Inst, builders: [3]?ir.FuncId, reads: []const u32) bool {
    const dst: Reg = switch (inst.*) {
        .ClassLiteral => |x| x.dst,
        .NewArray => |x| x.dst,
        .Const => |x| x.dst,
        .Move => |x| x.dst,
        .CallStatic => |x| blk: {
            for (builders) |f| if (f != null and x.func == f.?) break :blk x.dst;
            return false;
        },
        else => return false,
    };
    return dst.int() < reads.len and reads[dst.int()] == 0;
}

/// The index in `insts` of the instruction writing `y`, when no
/// instruction after it touches `x`.
fn copySource(insts: []const ir.Inst, x: Reg, y: Reg) ?usize {
    const Touch = struct {
        x: Reg,
        y: Reg,
        hit_x: *bool,
        def_y: *bool,
        fn cb(c: @This(), r: Reg, is_def: bool) void {
            if (r == c.x) c.hit_x.* = true;
            if (is_def and r == c.y) c.def_y.* = true;
        }
    };
    var i = insts.len;
    while (i > 0) {
        i -= 1;
        var hit_x = false;
        var def_y = false;
        ir.visitInstRegs(&insts[i], Touch{ .x = x, .y = y, .hit_x = &hit_x, .def_y = &def_y }, Touch.cb);
        if (def_y) return i;
        if (hit_x) return null;
    }
    return null;
}

/// Whether `inst`, which writes the copied register, may write `x` instead.
/// It must not already read `x` unless it reads its operands before it
/// writes; a constructor writes its instance before it runs, which a
/// handler of the block could see if the constructor throws. A parameter,
/// a capture or a cell goes only into a register nothing else writes: the
/// inliner takes such a register for the value itself.
fn takesDst(inst: *const ir.Inst, x: Reg, has_handlers: bool, x_single: bool) bool {
    const Reads = struct {
        x: Reg,
        found: *bool,
        fn cb(c: @This(), r: Reg, is_def: bool) void {
            if (!is_def and r == c.x) c.found.* = true;
        }
    };
    var reads_x = false;
    ir.visitInstRegs(inst, Reads{ .x = x, .found = &reads_x }, Reads.cb);
    return switch (inst.*) {
        .RNewInstance => !reads_x and !has_handlers,
        .LoadParam, .LoadCapture => x_single,
        .MakeCell => x_single and !reads_x,
        .Const, .LoadStatic, .LoadObject, .ClassLiteral => true,
        .Move, .BinOp, .UnOp, .Not, .NotNullAssert, .CellGet, .GetFieldSlot, .ArrayGet, .ClassOf, .RInstanceOf, .RCast, .CallStatic, .RCallVirtual, .CallInterface, .CallNative, .RCallValue => true,
        else => !reads_x,
    };
}

fn coalesceBlockCopies(a: Allocator, blocks: []BlockBuf, n: u32) Error!void {
    if (n == 0) return;
    const reads = try a.alloc(u32, n);
    defer a.free(reads);
    const defs = try a.alloc(u32, n);
    defer a.free(defs);
    @memset(reads, 0);
    @memset(defs, 0);
    const Count = struct {
        reads: []u32,
        defs: []u32,
        fn cb(c: @This(), r: Reg, is_def: bool) void {
            if (r.int() >= c.reads.len) return;
            if (is_def) c.defs[r.int()] += 1 else c.reads[r.int()] += 1;
        }
    };
    const counts: Count = .{ .reads = reads, .defs = defs };
    for (blocks) |*blk| {
        for (blk.insts.items) |*inst| ir.visitInstRegs(inst, counts, Count.cb);
        if (blk.terminator) |*t| ir.visitTerminatorRegs(t, counts, Count.cb);
        // A caught exception is written into its register by the unwinder.
        for (blk.handlers.catches) |c| Count.cb(counts, c.exception_reg, true);
    }
    for (blocks) |*blk| {
        const has_handlers = blk.handlers.any();
        var j: usize = 0;
        while (j < blk.insts.items.len) : (j += 1) {
            const mv = switch (blk.insts.items[j]) {
                .Move => |m| m,
                else => continue,
            };
            const y = mv.src;
            const x = mv.dst;
            if (x == y or y.int() >= n or x.int() >= n) continue;
            if (defs[y.int()] != 1 or reads[y.int()] != 1) continue;
            const i = copySource(blk.insts.items[0..j], x, y) orelse continue;
            const src = &blk.insts.items[i];
            if (!takesDst(src, x, has_handlers, defs[x.int()] == 1)) continue;
            setDst(src, x);
            _ = blk.insts.orderedRemove(j);
            defs[y.int()] = 0;
            reads[y.int()] = 0;
            j -= 1;
        }
    }
}

fn aliasBlockRuns(a: Allocator, blocks: []BlockBuf, n: u32) Error!void {
    if (n == 0) return;
    const reads = try a.alloc(u32, n);
    defer a.free(reads);
    const defs = try a.alloc(u32, n);
    defer a.free(defs);
    @memset(reads, 0);
    @memset(defs, 0);
    const Count = struct {
        reads: []u32,
        defs: []u32,
        fn cb(c: @This(), r: Reg, is_def: bool) void {
            if (r.int() >= c.reads.len) return;
            if (is_def) c.defs[r.int()] += 1 else c.reads[r.int()] += 1;
        }
    };
    const counts: Count = .{ .reads = reads, .defs = defs };
    for (blocks) |*blk| {
        for (blk.insts.items) |*inst| ir.visitInstRegs(inst, counts, Count.cb);
        if (blk.terminator) |*t| ir.visitTerminatorRegs(t, counts, Count.cb);
        for (blk.handlers.catches) |c| Count.cb(counts, c.exception_reg, true);
    }
    var copies: std.ArrayList(usize) = .empty;
    defer copies.deinit(a);
    for (blocks) |*blk| {
        var c: usize = 0;
        while (c < blk.insts.items.len) : (c += 1) {
            const arg_run = argRunOf(&blk.insts.items[c]) orelse continue;
            if (arg_run.n == 0 or arg_run.first.int() + arg_run.n > n) continue;
            copies.clearRetainingCapacity();
            const src0 = (try runSources(blk.insts.items[0..c], arg_run, defs, reads, &copies, a)) orelse continue;
            if (blk.insts.items[c] == .RNewInstance) {
                const d = blk.insts.items[c].RNewInstance.dst.int();
                if (d >= src0.int() and d < src0.int() + arg_run.n) continue;
            }
            setArgs(&blk.insts.items[c], src0);
            for (0..arg_run.n) |k| {
                const r = arg_run.first.int() + @as(u32, @intCast(k));
                defs[r] = 0;
                reads[r] = 0;
            }
            // Highest index first, so the others stay where they are.
            std.mem.sort(usize, copies.items, {}, std.sort.desc(usize));
            for (copies.items) |m| _ = blk.insts.orderedRemove(m);
            c -= copies.items.len;
        }
    }
}

const ArgRun = struct { first: Reg, n: u32 };

/// The argument run `inst` reads, if it reads one.
fn argRunOf(inst: *const ir.Inst) ?ArgRun {
    switch (inst.*) {
        inline else => |*p| {
            const P = @TypeOf(p.*);
            if (comptime @hasField(P, "args") and @hasField(P, "n_args")) {
                if (comptime @FieldType(P, "args") == Reg) return .{ .first = p.args, .n = p.n_args };
            }
            return null;
        },
    }
}

fn setArgs(inst: *ir.Inst, r: Reg) void {
    switch (inst.*) {
        inline else => |*p| {
            const P = @TypeOf(p.*);
            if (comptime @hasField(P, "args") and @hasField(P, "n_args") and @FieldType(P, "args") == Reg) p.args = r else unreachable;
        },
    }
}

/// When each register of `run` is written once, by a copy in `insts`, and
/// read only by the run, and the copies' sources are consecutive and not
/// written again before the call: the first source, with the copies'
/// indices in `copies`.
fn runSources(insts: []const ir.Inst, run: ArgRun, defs: []const u32, reads: []const u32, copies: *std.ArrayList(usize), a: Allocator) Error!?Reg {
    var src0: ?Reg = null;
    for (0..run.n) |k| {
        const r = Reg.from(run.first.int() + @as(u32, @intCast(k)));
        if (defs[r.int()] != 1 or reads[r.int()] != 1) return null;
        const m = findDef(insts, r) orelse return null;
        const src = switch (insts[m]) {
            .Move => |mv| mv.src,
            else => return null,
        };
        if (k == 0) {
            src0 = src;
        } else if (src.int() != src0.?.int() + @as(u32, @intCast(k))) return null;
        if (writtenAfter(insts[m + 1 ..], src)) return null;
        try copies.append(a, m);
    }
    return src0;
}

fn findDef(insts: []const ir.Inst, r: Reg) ?usize {
    const Def = struct {
        r: Reg,
        found: *bool,
        fn cb(c: @This(), reg: Reg, is_def: bool) void {
            if (is_def and reg == c.r) c.found.* = true;
        }
    };
    var i = insts.len;
    while (i > 0) {
        i -= 1;
        var found = false;
        ir.visitInstRegs(&insts[i], Def{ .r = r, .found = &found }, Def.cb);
        if (found) return i;
    }
    return null;
}

fn writtenAfter(insts: []const ir.Inst, r: Reg) bool {
    const Def = struct {
        r: Reg,
        found: *bool,
        fn cb(c: @This(), reg: Reg, is_def: bool) void {
            if (is_def and reg == c.r) c.found.* = true;
        }
    };
    var found = false;
    for (insts) |*inst| ir.visitInstRegs(inst, Def{ .r = r, .found = &found }, Def.cb);
    return found;
}

/// Sets the register `inst` writes.
fn setDst(inst: *ir.Inst, r: Reg) void {
    switch (inst.*) {
        inline else => |*p| {
            if (comptime @hasField(@TypeOf(p.*), "dst")) p.dst = r else unreachable;
        },
    }
}

/// Where `Builder.branchOnNull` goes.
pub const NullSplit = struct { is_null: BlockId, not_null: BlockId };

fn recordsOf(br: *const bridge.Bridge, file: u32) *const sema.output.FileRecords {
    return if (file < br.records.len) &br.records[file] else &no_records;
}

/// The records of a file sema has none for.
const no_records: sema.output.FileRecords = .{};

fn testBlock(a: Allocator, insts: []const Inst, term: Terminator) Error!BlockBuf {
    var blk: BlockBuf = .{ .terminator = term };
    try blk.insts.appendSlice(a, insts);
    return blk;
}

test "a copy of a temporary goes into the instruction that wrote it" {
    const a = std.testing.allocator;
    const r = Reg.from;
    var blocks = [_]BlockBuf{try testBlock(a, &.{
        .{ .Const = .{ .dst = r(1), .value = ir.ConstId.from(0) } },
        .{ .BinOp = .{ .dst = r(2), .op = .Add, .lhs = r(1), .rhs = r(0) } },
        .{ .Move = .{ .dst = r(3), .src = r(2) } },
    }, .{ .Return = r(3) })};
    defer blocks[0].insts.deinit(a);
    try coalesceBlockCopies(a, &blocks, 4);
    try std.testing.expectEqual(@as(usize, 2), blocks[0].insts.items.len);
    try std.testing.expectEqual(r(3), blocks[0].insts.items[1].BinOp.dst);
}

test "a copy stays when its destination is touched in between, or a parameter would gain a second writer" {
    const a = std.testing.allocator;
    const r = Reg.from;
    var touched = [_]BlockBuf{try testBlock(a, &.{
        .{ .BinOp = .{ .dst = r(2), .op = .Add, .lhs = r(0), .rhs = r(0) } },
        .{ .BinOp = .{ .dst = r(3), .op = .Add, .lhs = r(3), .rhs = r(0) } },
        .{ .Move = .{ .dst = r(3), .src = r(2) } },
    }, .{ .Return = r(3) })};
    defer touched[0].insts.deinit(a);
    try coalesceBlockCopies(a, &touched, 4);
    try std.testing.expectEqual(@as(usize, 3), touched[0].insts.items.len);

    var param = [_]BlockBuf{try testBlock(a, &.{
        .{ .LoadParam = .{ .dst = r(1), .idx = 0 } },
        .{ .Move = .{ .dst = r(2), .src = r(1) } },
        .{ .Const = .{ .dst = r(2), .value = ir.ConstId.from(0) } },
    }, .{ .Return = r(2) })};
    defer param[0].insts.deinit(a);
    try coalesceBlockCopies(a, &param, 3);
    try std.testing.expectEqual(@as(usize, 3), param[0].insts.items.len);
    // Into a register nothing else writes, the parameter's load takes it.
    _ = param[0].insts.orderedRemove(2);
    try coalesceBlockCopies(a, &param, 3);
    try std.testing.expectEqual(@as(usize, 1), param[0].insts.items.len);
    try std.testing.expectEqual(r(2), param[0].insts.items[0].LoadParam.dst);
}

test "a constructor keeps its own register in a block a handler watches" {
    const a = std.testing.allocator;
    const r = Reg.from;
    const new: Inst = .{ .RNewInstance = .{ .dst = r(1), .class = ir.ClassId.from(0), .ctor = FuncId.from(0), .args = r(0), .n_args = 0 } };
    var blocks = [_]BlockBuf{try testBlock(a, &.{ new, .{ .Move = .{ .dst = r(2), .src = r(1) } } }, .{ .Return = r(2) })};
    defer blocks[0].insts.deinit(a);
    const catches = [_]ir.CatchHandler{.{ .class = ir.ClassId.from(0), .handler = BlockId.from(0), .exception_reg = r(3) }};
    blocks[0].handlers.catches = @constCast(&catches);
    try coalesceBlockCopies(a, &blocks, 4);
    try std.testing.expectEqual(@as(usize, 2), blocks[0].insts.items.len);
    blocks[0].handlers.catches = &.{};
    try coalesceBlockCopies(a, &blocks, 4);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].insts.items.len);
    try std.testing.expectEqual(r(2), blocks[0].insts.items[0].RNewInstance.dst);
}

test "a call passes consecutive registers it copied as its argument run" {
    const a = std.testing.allocator;
    const r = Reg.from;
    const call: Inst = .{ .CallStatic = .{ .dst = r(7), .func = FuncId.from(0), .args = r(5), .n_args = 2 } };
    var blocks = [_]BlockBuf{try testBlock(a, &.{
        .{ .Move = .{ .dst = r(5), .src = r(0) } },
        .{ .Move = .{ .dst = r(6), .src = r(1) } },
        call,
    }, .{ .Return = r(7) })};
    defer blocks[0].insts.deinit(a);
    try aliasBlockRuns(a, &blocks, 8);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].insts.items.len);
    try std.testing.expectEqual(r(0), blocks[0].insts.items[0].CallStatic.args);

    // Out of order, or a source written before the call, keeps the copies.
    var swapped = [_]BlockBuf{try testBlock(a, &.{
        .{ .Move = .{ .dst = r(5), .src = r(1) } },
        .{ .Move = .{ .dst = r(6), .src = r(0) } },
        call,
    }, .{ .Return = r(7) })};
    defer swapped[0].insts.deinit(a);
    try aliasBlockRuns(a, &swapped, 8);
    try std.testing.expectEqual(@as(usize, 3), swapped[0].insts.items.len);
    var written = [_]BlockBuf{try testBlock(a, &.{
        .{ .Move = .{ .dst = r(5), .src = r(0) } },
        .{ .Move = .{ .dst = r(6), .src = r(1) } },
        .{ .Const = .{ .dst = r(1), .value = ir.ConstId.from(0) } },
        call,
    }, .{ .Return = r(7) })};
    defer written[0].insts.deinit(a);
    try aliasBlockRuns(a, &written, 8);
    try std.testing.expectEqual(@as(usize, 4), written[0].insts.items.len);
    // A constructor writes its instance before it reads its arguments.
    var ctor = [_]BlockBuf{try testBlock(a, &.{
        .{ .Move = .{ .dst = r(5), .src = r(0) } },
        .{ .RNewInstance = .{ .dst = r(0), .class = ir.ClassId.from(0), .ctor = FuncId.from(0), .args = r(5), .n_args = 1 } },
    }, .{ .Return = r(0) })};
    defer ctor[0].insts.deinit(a);
    try aliasBlockRuns(a, &ctor, 8);
    try std.testing.expectEqual(@as(usize, 2), ctor[0].insts.items.len);
}
