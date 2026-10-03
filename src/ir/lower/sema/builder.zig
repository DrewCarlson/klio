//! The program being lowered and the builder of one body: its blocks,
//! registers, locals, receivers, loops, finally blocks and inline regions.
//! Each body lowers on its own builder, in any order.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const runtime = @import("runtime");
const bridge = @import("../../core/bridge.zig");
const records = @import("records.zig");
const compose = @import("compose.zig");
const env_mod = @import("env.zig");
const operator = @import("operator.zig");
const inline_mod = @import("inline.zig");
const locals_mod = @import("locals.zig");
const name_mod = @import("name.zig");
const coerce_mod = @import("coerce.zig");
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
    /// By class: whether its values are held as their numbers (`coerce`).
    scalar_classes: std.AutoHashMapUnmanaged(Sym, ?coerce_mod.Scalar) = .empty,
    /// By member: the roots of its override family (`coerce`).
    family_roots: std.AutoHashMapUnmanaged(Sym, []const Sym) = .empty,
    /// By file: its top-level properties that have a static, in symbol
    /// order (`staticsOf`).
    file_statics: ?[]const []const Sym = null,
    /// By what an adapter adapts: the reference it serves (`adapterRef`).
    adapter_refs: ?std.AutoHashMapUnmanaged(bridge.Adapter, AdapterRef) = null,
    /// Scratch for the bodies being lowered, one level per builder open: a
    /// lambda's or an inline callee's body lowers inside its caller's
    /// (`pushScratch`). `depth` of them are in use.
    levels: std.ArrayList(*sema.Scratch) = .empty,
    depth: u32 = 0,

    /// The reference record adapter `ad` serves: the first of the records
    /// that adapt what it does, in the order they are kept. All of them are
    /// indexed the first time one is asked for, in one walk of the records.
    pub fn adapterRef(p: *Program, ad: bridge.Adapter) Allocator.Error!?AdapterRef {
        const by_adapter = if (p.adapter_refs) |*m| m else blk: {
            var m: std.AutoHashMapUnmanaged(bridge.Adapter, AdapterRef) = .empty;
            for (p.br.records) |fr| for (fr.refs) |r| switch (r.detail) {
                .ref => |x| {
                    const gop = try m.getOrPut(p.a, .{ .target = x.target, .ty = x.ty, .bound = std.meta.activeTag(x.bound) });
                    if (!gop.found_existing) gop.value_ptr.* = .{ .rec = x, .anchor = r.anchor };
                },
                else => {},
            };
            p.adapter_refs = m;
            break :blk &p.adapter_refs.?;
        };
        return by_adapter.get(ad);
    }

    /// The top-level properties of `file` that have a static, in symbol
    /// order: what its initialization unit stores. Bucketed for every file
    /// the first time a unit asks, in one walk of the symbols.
    pub fn staticsOf(p: *Program, file: u32) Allocator.Error![]const Sym {
        const by_file = p.file_statics orelse blk: {
            const s = p.s;
            const counts = try p.a.alloc(u32, s.files.items.len);
            @memset(counts, 0);
            const Each = struct {
                fn static(pr: *const Program, i: u32) ?u32 {
                    if (pr.br.static_of[i].int() == bridge.NONE) return null;
                    const sym = Sym.from(i);
                    if (pr.s.syms.kind(sym) != .property) return null;
                    const f = pr.s.syms.get(sym).file;
                    return if (f < pr.s.files.items.len) f else null;
                }
            };
            var i: u32 = 1;
            while (i < p.br.static_of.len) : (i += 1) if (Each.static(p, i)) |f| {
                counts[f] += 1;
            };
            const lists = try p.a.alloc([]Sym, counts.len);
            for (lists, counts) |*l, c| l.* = try p.a.alloc(Sym, c);
            @memset(counts, 0);
            i = 1;
            while (i < p.br.static_of.len) : (i += 1) if (Each.static(p, i)) |f| {
                lists[f][counts[f]] = Sym.from(i);
                counts[f] += 1;
            };
            p.file_statics = lists;
            break :blk lists;
        };
        return if (file < by_file.len) by_file[file] else &.{};
    }

    /// Opens a scratch level for a body about to be lowered: what its
    /// builder works in, emptied by `popScratch` once `Builder.finish` has
    /// copied the body out.
    pub fn pushScratch(p: *Program) Allocator.Error!Allocator {
        if (p.levels.items.len == p.depth) {
            const level = try std.heap.page_allocator.create(sema.Scratch);
            level.* = .{};
            p.levels.append(std.heap.page_allocator, level) catch |e| {
                std.heap.page_allocator.destroy(level);
                return e;
            };
        }
        p.depth += 1;
        return p.levels.items[p.depth - 1].allocator();
    }

    pub fn popScratch(p: *Program) void {
        p.depth -= 1;
        p.levels.items[p.depth].reset(4 * 1024 * 1024);
    }

    /// Frees the scratch levels, once every body is lowered.
    pub fn freeScratch(p: *Program) void {
        for (p.levels.items) |level| {
            level.deinit();
            std.heap.page_allocator.destroy(level);
        }
        p.levels.deinit(std.heap.page_allocator);
        p.levels = .empty;
        p.depth = 0;
    }

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

/// The reference an adapter serves, and where it is written.
pub const AdapterRef = struct { rec: *const sema.records.RefRec, anchor: span.Span };

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
    /// What the body's lowering works in: its blocks and their
    /// instructions, its tables of locals, its passes' counts. `finish`
    /// copies the body out to `p.a`.
    sa: Allocator,
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
    /// Registers an `UnboxValue` wrote, by the scalar class they hold the
    /// number of: unboxing one again is the register itself.
    unboxed: std.AutoHashMapUnmanaged(Reg, ir.ClassId) = .empty,
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
    pub fn init(p: *Program, sa: Allocator, file: u32, owner: Sym, func: FuncId, kind: BodyKind) Error!Builder {
        const br = p.br;
        var b: Builder = .{
            .p = p,
            .sa = sa,
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
        try b.blocks.append(b.sa, .{});
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
        try b.blocks.items[b.cur.int()].insts.append(b.sa, out);
    }

    /// Appends to the entry block, which dominates every use: a load with
    /// no effect the body reads anywhere (a parameter, a capture, `this`).
    pub fn emitEntry(b: *Builder, inst: Inst) Error!void {
        const entry = &b.blocks.items[0].insts;
        try entry.append(b.sa, inst);
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
        const sa = b.sa;
        // A pass runs only on a body holding the instructions it acts on.
        var kinds = instKinds(b.blocks.items);
        try b.pruneDeadTypeValues();
        if (kinds.contains(.UnOp)) try b.foldConversions();
        if (kinds.contains(.Not)) try b.foldNegatedTests();
        if (kinds.contains(.MakeCell)) {
            try b.decellLocals();
            kinds.insert(.Move);
        }
        threadJumps(b.blocks.items);
        try mergeBlocks(sa, b.blocks.items);
        if (kinds.contains(.Move) and b.next_reg != 0) {
            // Each of the three keeps the counts as it drops copies: one
            // count serves them all.
            const counts = try RegCounts.of(sa, b.blocks.items, b.next_reg);
            try forwardCountedCopies(sa, b.blocks.items, b.next_reg, counts);
            try b.coalesceCopies(counts);
            try b.aliasRuns(counts);
        }
        const work = try sa.alloc(ir.Block, b.blocks.items.len);
        for (b.blocks.items, work, 0..) |*buf, *out, i| {
            out.* = .{
                .id = BlockId.from(@intCast(i)),
                .insts = buf.insts.items,
                .terminator = buf.terminator orelse .Unreachable,
                .handlers = if (buf.handlers.any()) &buf.handlers else null,
            };
        }
        // A body calls copy in keeps its registers: a copy reads which parameter a register
        // holds from the register (`inline.instantiate`).
        const n_locals = if (b.copiedIn()) b.next_reg else try ir.regs.compact(sa, work, b.next_reg);
        const f = &b.p.m.funcs.items[b.func.int()];
        f.blocks = try copyOut(b.p.a, work);
        f.entry = BlockId.from(0);
        f.n_locals = n_locals;
        const lw = &b.p.lowered;
        if (b.func.int() >= lw.bit_length) try lw.resize(b.p.a, @max(b.func.int() + 1, b.p.m.funcs.items.len), false);
        lw.set(b.func.int());
    }

    /// Whether calls copy this body in rather than call it: an inline function, an inline
    /// property's accessor, or the defaults of an inline function.
    fn copiedIn(b: *const Builder) bool {
        const br = b.p.br;
        const s = b.p.s;
        if (b.func.int() >= br.origin.len) return false;
        return switch (br.origin[b.func.int()]) {
            // A local function's origin is `.lambda`; only a declared one is inline.
            .decl, .defaults, .lambda => |sym| s.syms.flags(sym).inline_,
            .getter => |sym| name_mod.inlineAccessor(s, sym, false),
            .setter => |sym| name_mod.inlineAccessor(s, sym, true),
            else => false,
        };
    }

    /// Drops what builds a run-time type value nothing reads: a reified
    /// argument an inline body only tests statically leaves the value its
    /// call built behind. Class literals, arrays and the base's type builders
    /// only allocate, and constants and copies only set registers.
    fn pruneDeadTypeValues(b: *Builder) Error!void {
        const builders = types_mod.typeBuilders(b);
        if (builders[0] == null) return;
        const reads = try b.sa.alloc(u32, b.next_reg);
        const Count = struct {
            reads: []u32,
            fn cb(c: @This(), r: Reg, is_def: bool) void {
                if (!is_def and r.int() < c.reads.len) c.reads[r.int()] += 1;
            }
            fn uncount(c: @This(), r: Reg, is_def: bool) void {
                if (!is_def and r.int() < c.reads.len) c.reads[r.int()] -= 1;
            }
        };
        @memset(reads, 0);
        for (b.blocks.items) |*blk| {
            for (blk.insts.items) |*inst| ir.visitInstRegs(inst, Count{ .reads = reads }, Count.cb);
            if (blk.terminator) |*t| ir.visitTerminatorRegs(t, Count{ .reads = reads }, Count.cb);
        }
        // A dropped instruction's reads stop counting, which may leave what
        // it read unread: until a sweep drops nothing. Nothing dropped comes
        // back, so the order they go in leaves the same body. A sweep walks
        // each block backward, from a value's reads to its write, so a chain
        // of copies nothing reads goes in one sweep.
        var longest: usize = 0;
        for (b.blocks.items) |*blk| longest = @max(longest, blk.insts.items.len);
        const dropped = try b.sa.alloc(bool, longest);
        while (true) {
            var removed = false;
            var bi = b.blocks.items.len;
            while (bi > 0) {
                bi -= 1;
                const blk = &b.blocks.items[bi];
                const insts = blk.insts.items;
                @memset(dropped[0..insts.len], false);
                var any = false;
                var i = insts.len;
                while (i > 0) {
                    i -= 1;
                    if (!deadTypePart(&insts[i], builders, reads)) continue;
                    ir.visitInstRegs(&insts[i], Count{ .reads = reads }, Count.uncount);
                    dropped[i] = true;
                    any = true;
                }
                if (any) {
                    dropMarked(blk, dropped);
                    removed = true;
                }
            }
            if (!removed) return;
        }
    }

    /// Folds a conversion of a constant into the converted constant, and
    /// drops the constant when only such conversions read it: `l * 31`
    /// multiplies by the `Long` 31 rather than converting 31 each time.
    fn foldConversions(b: *Builder) Error!void {
        const a = b.sa;
        const n = b.next_reg;
        const defs = try a.alloc(u32, n);
        defer a.free(defs);
        const reads = try a.alloc(u32, n);
        defer a.free(reads);
        @memset(defs, 0);
        @memset(reads, 0);
        const Count = struct {
            defs: []u32,
            reads: []u32,
            fn cb(c: @This(), r: Reg, is_def: bool) void {
                if (r.int() >= c.reads.len) return;
                if (is_def) c.defs[r.int()] += 1 else c.reads[r.int()] += 1;
            }
        };
        const counter: Count = .{ .defs = defs, .reads = reads };
        var any = false;
        for (b.blocks.items) |*blk| {
            for (blk.insts.items) |*inst| {
                ir.visitInstRegs(inst, counter, Count.cb);
                if (inst.* == .UnOp and inst.UnOp.op.conversion() != null) any = true;
            }
            if (blk.terminator) |*t| ir.visitTerminatorRegs(t, counter, Count.cb);
        }
        if (!any) return;
        // The constant a register holds, where one `Const` is its only write.
        const consts = try a.alloc(?ir.ConstId, n);
        defer a.free(consts);
        @memset(consts, null);
        for (b.blocks.items) |*blk| for (blk.insts.items) |inst| {
            if (inst == .Const and defs[inst.Const.dst.int()] == 1) consts[inst.Const.dst.int()] = inst.Const.value;
        };
        const folded = try a.alloc(bool, n);
        defer a.free(folded);
        @memset(folded, false);
        for (b.blocks.items) |*blk| for (blk.insts.items) |*inst| {
            if (inst.* != .UnOp) continue;
            const x = inst.UnOp;
            const to = x.op.conversion() orelse continue;
            const cid = consts[x.operand.int()] orelse continue;
            const v = numericValue(b.p.m.consts.items[cid.int()]) orelse continue;
            const out = runtime.numconv.convert(to, v) orelse continue;
            inst.* = .{ .Const = .{ .dst = x.dst, .value = try b.p.m.internConst(b.p.a, numericConst(out)) } };
            reads[x.operand.int()] -= 1;
            folded[x.operand.int()] = true;
        };
        for (b.blocks.items) |*blk| {
            var kept: usize = 0;
            for (blk.insts.items) |inst| {
                if (inst == .Const and folded[inst.Const.dst.int()] and reads[inst.Const.dst.int()] == 0) continue;
                blk.insts.items[kept] = inst;
                kept += 1;
            }
            blk.insts.shrinkRetainingCapacity(kept);
        }
    }

    /// A `!` of an equality or identity test that nothing else reads becomes the
    /// negated test, writing the `!`'s register, and the `!` goes: `a != null`
    /// lowers to `!(a === null)`, and as one test it can join its block's
    /// branch. Only the tests whose negation is exact (`==`, `!=`, their boxed
    /// forms, `===`, `!==`); an ordering's is not, where NaN answers false both
    /// ways. The test and the `!` are in one block with nothing between them
    /// touching the `!`'s register, which the test now writes earlier.
    fn foldNegatedTests(b: *Builder) Error!void {
        const a = b.sa;
        const n = b.next_reg;
        const defs = try a.alloc(u32, n);
        defer a.free(defs);
        const reads = try a.alloc(u32, n);
        defer a.free(reads);
        @memset(defs, 0);
        @memset(reads, 0);
        const Count = struct {
            defs: []u32,
            reads: []u32,
            fn cb(c: @This(), r: Reg, is_def: bool) void {
                if (r.int() >= c.reads.len) return;
                if (is_def) c.defs[r.int()] += 1 else c.reads[r.int()] += 1;
            }
        };
        const counter: Count = .{ .defs = defs, .reads = reads };
        var any = false;
        for (b.blocks.items) |*blk| {
            for (blk.insts.items) |*inst| {
                ir.visitInstRegs(inst, counter, Count.cb);
                if (inst.* == .Not) any = true;
            }
            if (blk.terminator) |*t| ir.visitTerminatorRegs(t, counter, Count.cb);
            for (blk.handlers.catches) |c| Count.cb(counter, c.exception_reg, true);
        }
        if (!any) return;
        const Touches = struct {
            reg: u32,
            hit: *bool,
            fn cb(t: @This(), r: Reg, is_def: bool) void {
                _ = is_def;
                if (r.int() == t.reg) t.hit.* = true;
            }
        };
        for (b.blocks.items) |*blk| {
            var i: usize = 0;
            while (i < blk.insts.items.len) : (i += 1) {
                const not = switch (blk.insts.items[i]) {
                    .Not => |x| x,
                    else => continue,
                };
                const src = not.src.int();
                if (src >= n or defs[src] != 1 or reads[src] != 1) continue;
                var j = i;
                const test_at: ?usize = while (j > 0) {
                    j -= 1;
                    switch (blk.insts.items[j]) {
                        .BinOp => |bo| if (bo.dst.int() == src) break j,
                        else => {},
                    }
                } else null;
                const t = test_at orelse continue;
                const negated: ir.BinOp = switch (blk.insts.items[t].BinOp.op) {
                    .Eq => .NotEq,
                    .NotEq => .Eq,
                    .BoxedEq => .BoxedNotEq,
                    .BoxedNotEq => .BoxedEq,
                    .IdentEq => .IdentNeq,
                    .IdentNeq => .IdentEq,
                    else => continue,
                };
                var hit = false;
                for (blk.insts.items[t + 1 .. i]) |*between| ir.visitInstRegs(between, Touches{ .reg = not.dst.int(), .hit = &hit }, Touches.cb);
                if (hit) continue;
                blk.insts.items[t].BinOp.dst = not.dst;
                blk.insts.items[t].BinOp.op = negated;
                _ = blk.insts.orderedRemove(i);
                i -= 1;
            }
        }
    }

    /// Keeps in a register a `var` whose cell never leaves this function.
    /// A local a lambda captures is made a cell before lowering knows the
    /// lambda is spliced into its caller by an inline call; a cell nothing
    /// passes on, stores or captures is only this frame's own storage.
    fn decellLocals(b: *Builder) Error!void {
        try decellBlocks(b.sa, b.blocks.items, b.next_reg);
    }

    /// Drops a copy of a register only it reads into a register only it
    /// writes, when the instruction that wrote the source is earlier in the
    /// copy's block and nothing between them touches the destination: that
    /// instruction writes the destination itself. An argument run and a
    /// `val` copy a fresh temporary this way.
    fn coalesceCopies(b: *Builder, counts: RegCounts) Error!void {
        try coalesceCountedCopies(b.sa, b.blocks.items, b.next_reg, counts);
    }

    /// Gives a call the registers its argument run copies as its run, when
    /// they are consecutive and nothing writes them between the copies and
    /// the call: `f(x)` and `x.g()` then pass `x`'s own register. The callee
    /// reads its parameters from the caller's registers, which the caller
    /// does not write while the call runs.
    fn aliasRuns(b: *Builder, counts: RegCounts) Error!void {
        try aliasCountedRuns(b.sa, b.blocks.items, b.next_reg, counts);
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
fn copySource(insts: []const ir.Inst, dropped: []const bool, x: Reg, y: Reg) ?usize {
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
        if (dropped[i]) continue;
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

/// Sends an edge to an empty block that only jumps on straight to where it
/// jumps: the `else` a lone `if` leaves, a join passed through. A block
/// with handlers, whose edges the try machinery keys on, is neither passed
/// through nor retargeted from.
const InstKinds = std.EnumSet(std.meta.Tag(Inst));

/// Which kinds of instruction the blocks hold.
fn instKinds(blocks: []const BlockBuf) InstKinds {
    var out: InstKinds = .initEmpty();
    for (blocks) |*blk| for (blk.insts.items) |inst| out.insert(inst);
    return out;
}

/// A finished body's blocks, as `work` holds them in scratch, in `a`: each
/// block's instructions and handlers, and the registers a closure captures.
/// The instructions of every block share one array, the captures another.
fn copyOut(a: Allocator, work: []const ir.Block) Allocator.Error![]ir.Block {
    var n_insts: usize = 0;
    var n_caps: usize = 0;
    for (work) |w| {
        n_insts += w.insts.len;
        for (w.insts) |inst| switch (inst) {
            .MakeClosure => |mc| n_caps += mc.captures.len,
            else => {},
        };
    }
    const blocks = try a.alloc(ir.Block, work.len);
    const insts = try a.alloc(Inst, n_insts);
    const caps = try a.alloc(Reg, n_caps);
    var at: usize = 0;
    var cap_at: usize = 0;
    for (work, blocks) |w, *out| {
        const mine = insts[at..][0..w.insts.len];
        at += w.insts.len;
        @memcpy(mine, w.insts);
        out.* = .{ .id = w.id, .insts = mine, .terminator = w.terminator };
        for (mine) |*inst| switch (inst.*) {
            .MakeClosure => |*mc| {
                const c = caps[cap_at..][0..mc.captures.len];
                cap_at += c.len;
                @memcpy(c, mc.captures);
                mc.captures = c;
            },
            else => {},
        };
        if (w.handlers) |wh| {
            const h = try out.handlersMut(a);
            h.* = wh.*;
            h.catches = try a.dupe(ir.CatchHandler, wh.catches);
            h.pop_on_exit = try a.dupe(BlockId, wh.pop_on_exit);
        }
    }
    return blocks;
}

fn threadJumps(blocks: []BlockBuf) void {
    const Hop = struct {
        fn through(bs: []BlockBuf, target: BlockId) BlockId {
            var cur = target;
            var hops: usize = 0;
            while (hops < 8) : (hops += 1) {
                if (cur.int() >= bs.len) return cur;
                const t = &bs[cur.int()];
                if (t.insts.items.len != 0 or t.handlers.any()) return cur;
                const next = switch (t.terminator orelse return cur) {
                    .Goto => |x| x,
                    else => return cur,
                };
                if (next.int() == cur.int()) return cur;
                cur = next;
            }
            return cur;
        }
    };
    // A block a handler names keeps every edge to it: the handler may be
    // what reaches it.
    for (blocks) |*blk| {
        if (blk.handlers.any()) continue;
        const t = &(blk.terminator orelse continue);
        switch (t.*) {
            .Goto => |*x| x.* = Hop.through(blocks, x.*),
            .Branch => |*br| {
                br.t = Hop.through(blocks, br.t);
                br.f = Hop.through(blocks, br.f);
            },
            else => {},
        }
    }
}

/// Joins a block to the one block that jumps to it: a `Goto` to a block
/// no other edge or handler names runs straight on. The joined block is
/// left empty and unreachable, so no block id moves. Blocks with handlers
/// keep their edges, which the try machinery keys on.
fn mergeBlocks(a: Allocator, blocks: []BlockBuf) Error!void {
    if (blocks.len < 2) return;
    const preds = try a.alloc(u32, blocks.len);
    defer a.free(preds);
    const pinned = try a.alloc(bool, blocks.len);
    defer a.free(pinned);
    @memset(preds, 0);
    @memset(pinned, false);
    pinned[0] = true;
    const Pin = struct {
        fn at(p: []bool, id: ?BlockId) void {
            if (id) |x| if (x.int() < p.len) {
                p[x.int()] = true;
            };
        }
    };
    for (blocks) |*blk| {
        if (blk.terminator) |t| switch (t) {
            .Goto => |x| preds[x.int()] += 1,
            .Branch => |br| {
                preds[br.t.int()] += 1;
                preds[br.f.int()] += 1;
            },
            else => {},
        };
        const h = &blk.handlers;
        for (h.catches) |c| Pin.at(pinned, c.handler);
        Pin.at(pinned, h.finally);
        Pin.at(pinned, h.finally_done);
        Pin.at(pinned, h.finally_done_for);
        Pin.at(pinned, h.catch_done_for);
        for (h.pop_on_exit) |x| Pin.at(pinned, x);
    }
    for (blocks, 0..) |*p, pi| {
        while (true) {
            const t = p.terminator orelse break;
            const next = switch (t) {
                .Goto => |x| x.int(),
                else => break,
            };
            if (next == pi or next >= blocks.len or preds[next] != 1 or pinned[next]) break;
            const q = &blocks[next];
            if (p.handlers.any() or q.handlers.any()) break;
            try p.insts.appendSlice(a, q.insts.items);
            p.terminator = q.terminator;
            q.insts.clearRetainingCapacity();
            q.terminator = .Unreachable;
            preds[next] = 0;
        }
    }
}

/// How many times each register of a body is read and written; a catch's
/// exception register counts as written, by the unwinder.
const RegCounts = struct {
    reads: []u32,
    defs: []u32,

    fn of(a: Allocator, blocks: []BlockBuf, n: u32) Error!RegCounts {
        const reads = try a.alloc(u32, n);
        errdefer a.free(reads);
        const defs = try a.alloc(u32, n);
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
        return .{ .reads = reads, .defs = defs };
    }

    fn free(self: RegCounts, a: Allocator) void {
        a.free(self.defs);
        a.free(self.reads);
    }
};

/// Forwards a copy into the one instruction that reads it: `x = y` then a
/// read of `x` later in the block reads `y`, when `x` is written only by
/// the copy, read only there, and `y` is not written in between.
fn forwardCopies(a: Allocator, blocks: []BlockBuf, n: u32) Error!void {
    if (n == 0) return;
    const counts = try RegCounts.of(a, blocks, n);
    defer counts.free(a);
    try forwardCountedCopies(a, blocks, n, counts);
}

/// `forwardCopies` with the body's `counts`, which it keeps as it drops
/// copies.
fn forwardCountedCopies(a: Allocator, blocks: []BlockBuf, n: u32, counts: RegCounts) Error!void {
    const reads = counts.reads;
    const defs = counts.defs;
    var longest: usize = 0;
    for (blocks) |*blk| longest = @max(longest, blk.insts.items.len);
    // Copies forwarded, dropped once the block is walked: the walk reads
    // only what follows a copy, which none dropped is.
    const dropped = try a.alloc(bool, longest);
    defer a.free(dropped);
    for (blocks) |*blk| {
        @memset(dropped[0..blk.insts.items.len], false);
        var any_dropped = false;
        var j: usize = 0;
        while (j < blk.insts.items.len) {
            const mv = switch (blk.insts.items[j]) {
                .Move => |m| m,
                else => {
                    j += 1;
                    continue;
                },
            };
            const x = mv.dst;
            const y = mv.src;
            j += 1;
            if (x == y or x.int() >= n or defs[x.int()] != 1 or reads[x.int()] != 1) continue;
            var k = j;
            const done = while (k < blk.insts.items.len) : (k += 1) {
                const inst = &blk.insts.items[k];
                if (touches(inst, x, false)) {
                    // Operands read before the result is written, where it
                    // writes `y` itself.
                    if (touches(inst, y, true) and !readsFirst(inst)) break false;
                    if (!replaceReads(inst, x, y)) break false;
                    break true;
                }
                if (touches(inst, y, true)) break false;
            } else blk: {
                const t = if (blk.terminator) |*tt| tt else break :blk false;
                break :blk replaceTerminatorRead(t, x, y);
            };
            if (!done) continue;
            dropped[j - 1] = true;
            any_dropped = true;
            defs[x.int()] = 0;
            reads[x.int()] = 0;
        }
        if (any_dropped) dropMarked(blk, dropped);
    }
}

/// Whether `inst` reads `r`, or with `writes` writes it.
fn touches(inst: *const ir.Inst, r: Reg, writes: bool) bool {
    const T = struct {
        r: Reg,
        writes: bool,
        found: *bool,
        fn cb(c: @This(), reg: Reg, is_def: bool) void {
            if (reg == c.r and is_def == c.writes) c.found.* = true;
        }
    };
    var found = false;
    ir.visitInstRegs(inst, T{ .r = r, .writes = writes, .found = &found }, T.cb);
    return found;
}

/// Whether `inst` reads every operand before it writes its result.
fn readsFirst(inst: *const ir.Inst) bool {
    return switch (inst.*) {
        .Move, .BinOp, .UnOp, .Not, .NotNullAssert, .GetFieldSlot, .ArrayGet, .ClassOf, .RInstanceOf, .RCast => true,
        else => false,
    };
}

/// Makes `inst` read `to` where it reads `from`; false, changing nothing,
/// when `from` is in an argument run or a list, which a single register
/// cannot stand in.
fn replaceReads(inst: *ir.Inst, from: Reg, to: Reg) bool {
    switch (inst.*) {
        inline else => |*p| {
            const P = @TypeOf(p.*);
            // A run or a list naming `from` keeps it.
            inline for (std.meta.fields(P)) |f| {
                if (f.type == Reg and comptime std.mem.eql(u8, f.name, "args") and @hasField(P, "n_args")) {
                    if (from.int() >= @field(p, f.name).int() and from.int() < @field(p, f.name).int() + p.n_args) return false;
                } else if (f.type == []const Reg or f.type == []Reg) {
                    for (@field(p, f.name)) |r| if (r == from) return false;
                }
            }
            inline for (std.meta.fields(P)) |f| {
                const is_run = comptime std.mem.eql(u8, f.name, "args") and @hasField(P, "n_args");
                if (comptime std.mem.eql(u8, f.name, "dst") or is_run) continue;
                if (f.type == Reg) {
                    if (@field(p, f.name) == from) @field(p, f.name) = to;
                } else if (f.type == ?Reg) {
                    if (@field(p, f.name)) |r| if (r == from) {
                        @field(p, f.name) = to;
                    };
                }
            }
            return true;
        },
    }
}

fn replaceTerminatorRead(t: *Terminator, from: Reg, to: Reg) bool {
    switch (t.*) {
        .Branch => |*br| if (br.cond == from) {
            br.cond = to;
            return true;
        },
        .Return => |*r| if (r.*) |v| if (v == from) {
            r.* = to;
            return true;
        },
        .Throw => |*v| if (v.* == from) {
            v.* = to;
            return true;
        },
        else => {},
    }
    return false;
}

/// A numeric or `Char` constant as the value it loads; null for the others.
fn numericValue(c: ir.Const) ?runtime.Value {
    return switch (c) {
        .Int => |x| .{ .Int = x },
        .Long => |x| .{ .Long = x },
        .Short => |x| .{ .Short = x },
        .Byte => |x| .{ .Byte = x },
        .Char => |x| .{ .Char = x },
        .Double => |x| .{ .Double = x },
        .Float => |x| .{ .Float = x },
        else => null,
    };
}

/// The constant a conversion's result loads.
fn numericConst(v: runtime.Value) ir.Const {
    return switch (v) {
        .Int => |x| .{ .Int = x },
        .Long => |x| .{ .Long = x },
        .Short => |x| .{ .Short = x },
        .Byte => |x| .{ .Byte = x },
        .Char => |x| .{ .Char = x },
        .Double => |x| .{ .Double = x },
        .Float => |x| .{ .Float = x },
        else => unreachable,
    };
}

fn decellBlocks(a: Allocator, blocks: []BlockBuf, n: u32) Error!void {
    if (n == 0) return;
    // Per register: cells made into it, other writes, reads as the cell of a
    // `CellGet` or `CellSet`, and any other read.
    const makes = try a.alloc(u32, n);
    defer a.free(makes);
    const writes = try a.alloc(u32, n);
    defer a.free(writes);
    const other_reads = try a.alloc(u32, n);
    defer a.free(other_reads);
    @memset(makes, 0);
    @memset(writes, 0);
    @memset(other_reads, 0);
    const Count = struct {
        writes: []u32,
        other_reads: []u32,
        fn cb(c: @This(), r: Reg, is_def: bool) void {
            if (r.int() >= c.writes.len) return;
            if (is_def) c.writes[r.int()] += 1 else c.other_reads[r.int()] += 1;
        }
    };
    const count: Count = .{ .writes = writes, .other_reads = other_reads };
    var any = false;
    for (blocks) |*blk| {
        for (blk.insts.items) |*inst| switch (inst.*) {
            .MakeCell => |m| {
                if (m.dst.int() < n) makes[m.dst.int()] += 1;
                Count.cb(count, m.src, false);
                any = true;
            },
            .CellGet => |g| Count.cb(count, g.dst, true),
            .CellSet => |c| Count.cb(count, c.value, false),
            else => ir.visitInstRegs(inst, count, Count.cb),
        };
        if (blk.terminator) |*t| ir.visitTerminatorRegs(t, count, Count.cb);
        for (blk.handlers.catches) |c| Count.cb(count, c.exception_reg, true);
    }
    if (!any) return;
    const kept = struct {
        fn f(mk: []const u32, wr: []const u32, rd: []const u32, r: Reg) bool {
            const i = r.int();
            return i < mk.len and mk[i] == 1 and wr[i] == 0 and rd[i] == 0;
        }
    }.f;
    for (blocks) |*blk| {
        for (blk.insts.items) |*inst| switch (inst.*) {
            .MakeCell => |m| if (kept(makes, writes, other_reads, m.dst)) {
                inst.* = .{ .Move = .{ .dst = m.dst, .src = m.src } };
            },
            .CellGet => |g| if (kept(makes, writes, other_reads, g.cell)) {
                inst.* = .{ .Move = .{ .dst = g.dst, .src = g.cell } };
            },
            .CellSet => |c| if (kept(makes, writes, other_reads, c.cell)) {
                inst.* = .{ .Move = .{ .dst = c.cell, .src = c.value } };
            },
            else => {},
        };
    }
}

fn coalesceBlockCopies(a: Allocator, blocks: []BlockBuf, n: u32) Error!void {
    if (n == 0) return;
    const counts = try RegCounts.of(a, blocks, n);
    defer counts.free(a);
    try coalesceCountedCopies(a, blocks, n, counts);
}

/// `coalesceBlockCopies` with the body's `counts`, which it keeps as it
/// drops copies.
fn coalesceCountedCopies(a: Allocator, blocks: []BlockBuf, n: u32, counts: RegCounts) Error!void {
    const reads = counts.reads;
    const defs = counts.defs;
    var longest: usize = 0;
    for (blocks) |*blk| longest = @max(longest, blk.insts.items.len);
    // Copies coalesced, dropped once the block is walked; the walk back to
    // a copy's source passes over them.
    const dropped = try a.alloc(bool, longest);
    defer a.free(dropped);
    for (blocks) |*blk| {
        const has_handlers = blk.handlers.any();
        @memset(dropped[0..blk.insts.items.len], false);
        var any_dropped = false;
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
            const i = copySource(blk.insts.items[0..j], dropped[0..j], x, y) orelse continue;
            const src = &blk.insts.items[i];
            if (!takesDst(src, x, has_handlers, defs[x.int()] == 1)) continue;
            setDst(src, x);
            dropped[j] = true;
            any_dropped = true;
            defs[y.int()] = 0;
            reads[y.int()] = 0;
        }
        if (any_dropped) dropMarked(blk, dropped);
    }
}

/// Drops the instructions of `blk` that `dropped` marks, keeping the rest in order.
fn dropMarked(blk: *BlockBuf, dropped: []const bool) void {
    var kept: usize = 0;
    for (blk.insts.items, 0..) |inst, i| {
        if (dropped[i]) continue;
        blk.insts.items[kept] = inst;
        kept += 1;
    }
    blk.insts.shrinkRetainingCapacity(kept);
}

fn aliasBlockRuns(a: Allocator, blocks: []BlockBuf, n: u32) Error!void {
    if (n == 0) return;
    const counts = try RegCounts.of(a, blocks, n);
    defer counts.free(a);
    try aliasCountedRuns(a, blocks, n, counts);
}

/// `aliasBlockRuns` with the body's `counts`, which it keeps as it drops
/// copies.
fn aliasCountedRuns(a: Allocator, blocks: []BlockBuf, n: u32, counts: RegCounts) Error!void {
    const reads = counts.reads;
    const defs = counts.defs;
    var longest: usize = 0;
    for (blocks) |*blk| longest = @max(longest, blk.insts.items.len);
    // By register, the last instruction of the block being walked that
    // writes it, up to the one the walk is at: `at` holds the index, and
    // `in` the block's number plus one, so no clearing between blocks.
    const at = try a.alloc(u32, n);
    defer a.free(at);
    const in = try a.alloc(u32, n);
    defer a.free(in);
    @memset(in, 0);
    // Copies dropped from the block being walked, compacted out once it is done.
    const dropped = try a.alloc(bool, longest);
    defer a.free(dropped);
    const Defs = struct {
        at: []u32,
        in: []u32,
        blk: u32,
        i: u32,
        fn cb(d: @This(), r: Reg, is_def: bool) void {
            if (!is_def or r.int() >= d.at.len) return;
            d.at[r.int()] = d.i;
            d.in[r.int()] = d.blk;
        }
    };
    for (blocks, 1..) |*blk, bn| {
        const insts = blk.insts.items;
        const here: u32 = @intCast(bn);
        @memset(dropped[0..insts.len], false);
        var any_dropped = false;
        for (insts, 0..) |*inst, c| {
            defer ir.visitInstRegs(inst, Defs{ .at = at, .in = in, .blk = here, .i = @intCast(c) }, Defs.cb);
            const arg_run = argRunOf(inst) orelse continue;
            if (arg_run.n == 0 or arg_run.first.int() + arg_run.n > n) continue;
            const src0 = runSources(insts, arg_run, defs, reads, at, in, here) orelse continue;
            if (inst.* == .RNewInstance) {
                const d = inst.RNewInstance.dst.int();
                if (d >= src0.int() and d < src0.int() + arg_run.n) continue;
            }
            setArgs(inst, src0);
            for (0..arg_run.n) |k| {
                const r = arg_run.first.int() + @as(u32, @intCast(k));
                dropped[at[r]] = true;
                defs[r] = 0;
                reads[r] = 0;
            }
            any_dropped = true;
        }
        if (any_dropped) dropMarked(blk, dropped);
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

/// When each register of `run` is written once, by a copy earlier in the
/// block, and read only by the run, and the copies' sources are consecutive
/// and not written again before the call: the first source. `at` and `in`
/// say where in the block each register was last written before the call.
fn runSources(insts: []const ir.Inst, run: ArgRun, defs: []const u32, reads: []const u32, at: []const u32, in: []const u32, here: u32) ?Reg {
    var src0: ?Reg = null;
    for (0..run.n) |k| {
        const r = Reg.from(run.first.int() + @as(u32, @intCast(k)));
        if (defs[r.int()] != 1 or reads[r.int()] != 1) return null;
        if (in[r.int()] != here) return null;
        const m = at[r.int()];
        const src = switch (insts[m]) {
            .Move => |mv| mv.src,
            else => return null,
        };
        if (k == 0) {
            src0 = src;
        } else if (src.int() != src0.?.int() + @as(u32, @intCast(k))) return null;
        // Written again between the copy and the call.
        if (src.int() < in.len and in[src.int()] == here and at[src.int()] > m) return null;
    }
    return src0;
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

test "the copy passes with one count between them leave what each counting for itself leaves" {
    const a = std.testing.allocator;
    const r = Reg.from;
    const body = [_]Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .Const = .{ .dst = r(1), .value = ir.ConstId.from(0) } },
        .{ .BinOp = .{ .dst = r(2), .op = .Add, .lhs = r(1), .rhs = r(0) } },
        .{ .Move = .{ .dst = r(3), .src = r(2) } },
        .{ .Move = .{ .dst = r(4), .src = r(3) } },
        .{ .Move = .{ .dst = r(5), .src = r(4) } },
        .{ .Move = .{ .dst = r(6), .src = r(0) } },
        .{ .CallStatic = .{ .dst = r(7), .func = FuncId.from(0), .args = r(5), .n_args = 2 } },
        .{ .Move = .{ .dst = r(8), .src = r(7) } },
        .{ .BinOp = .{ .dst = r(9), .op = .Add, .lhs = r(8), .rhs = r(8) } },
    };
    var each = [_]BlockBuf{try testBlock(a, &body, .{ .Return = r(9) })};
    defer each[0].insts.deinit(a);
    try forwardCopies(a, &each, 10);
    try coalesceBlockCopies(a, &each, 10);
    try aliasBlockRuns(a, &each, 10);
    var shared = [_]BlockBuf{try testBlock(a, &body, .{ .Return = r(9) })};
    defer shared[0].insts.deinit(a);
    const counts = try RegCounts.of(a, &shared, 10);
    defer counts.free(a);
    try forwardCountedCopies(a, &shared, 10, counts);
    try coalesceCountedCopies(a, &shared, 10, counts);
    try aliasCountedRuns(a, &shared, 10, counts);
    // Something was dropped, and the same.
    try std.testing.expect(each[0].insts.items.len < body.len);
    try std.testing.expectEqual(each[0].insts.items.len, shared[0].insts.items.len);
    for (each[0].insts.items, shared[0].insts.items) |x, y| try std.testing.expect(std.meta.eql(x, y));
    // And the counts kept are the body's as it now stands.
    const fresh = try RegCounts.of(a, &shared, 10);
    defer fresh.free(a);
    try std.testing.expectEqualSlices(u32, fresh.reads, counts.reads);
    try std.testing.expectEqualSlices(u32, fresh.defs, counts.defs);
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

test "a cell that never leaves its function is a register" {
    const a = std.testing.allocator;
    const r = Reg.from;
    var blocks = [_]BlockBuf{try testBlock(a, &.{
        .{ .Const = .{ .dst = r(0), .value = ir.ConstId.from(0) } },
        .{ .MakeCell = .{ .dst = r(1), .src = r(0) } },
        .{ .CellGet = .{ .dst = r(2), .cell = r(1) } },
        .{ .BinOp = .{ .dst = r(3), .op = .Add, .lhs = r(2), .rhs = r(2) } },
        .{ .CellSet = .{ .cell = r(1), .value = r(3) } },
        .{ .CellGet = .{ .dst = r(4), .cell = r(1) } },
    }, .{ .Return = r(4) })};
    defer blocks[0].insts.deinit(a);
    try decellBlocks(a, &blocks, 5);
    const insts = blocks[0].insts.items;
    try std.testing.expectEqual(Inst{ .Move = .{ .dst = r(1), .src = r(0) } }, insts[1]);
    try std.testing.expectEqual(Inst{ .Move = .{ .dst = r(2), .src = r(1) } }, insts[2]);
    try std.testing.expectEqual(Inst{ .Move = .{ .dst = r(1), .src = r(3) } }, insts[4]);
    try std.testing.expectEqual(Inst{ .Move = .{ .dst = r(4), .src = r(1) } }, insts[5]);
}

test "a cell a closure captures, a call takes or a return gives stays a cell" {
    const a = std.testing.allocator;
    const r = Reg.from;
    const caps = [_]Reg{r(1)};
    const escapes = [_]Inst{
        .{ .MakeClosure = .{ .dst = r(2), .func = FuncId.from(0), .captures = &caps } },
        .{ .CallStatic = .{ .dst = r(2), .func = FuncId.from(0), .args = r(1), .n_args = 1 } },
        .{ .Move = .{ .dst = r(2), .src = r(1) } },
    };
    for (escapes) |esc| {
        var blocks = [_]BlockBuf{try testBlock(a, &.{
            .{ .MakeCell = .{ .dst = r(1), .src = r(0) } },
            esc,
            .{ .CellGet = .{ .dst = r(3), .cell = r(1) } },
        }, .{ .Return = r(3) })};
        defer blocks[0].insts.deinit(a);
        try decellBlocks(a, &blocks, 4);
        try std.testing.expect(blocks[0].insts.items[0] == .MakeCell);
        try std.testing.expect(blocks[0].insts.items[2] == .CellGet);
    }
    var returned = [_]BlockBuf{try testBlock(a, &.{
        .{ .MakeCell = .{ .dst = r(1), .src = r(0) } },
    }, .{ .Return = r(1) })};
    defer returned[0].insts.deinit(a);
    try decellBlocks(a, &returned, 2);
    try std.testing.expect(returned[0].insts.items[0] == .MakeCell);
}

test "a block only one jump reaches joins the block that jumps" {
    const a = std.testing.allocator;
    const r = Reg.from;
    var blocks = [_]BlockBuf{
        try testBlock(a, &.{.{ .Const = .{ .dst = r(0), .value = ir.ConstId.from(0) } }}, .{ .Goto = BlockId.from(1) }),
        try testBlock(a, &.{.{ .Move = .{ .dst = r(1), .src = r(0) } }}, .{ .Goto = BlockId.from(2) }),
        try testBlock(a, &.{.{ .Move = .{ .dst = r(2), .src = r(1) } }}, .{ .Branch = .{ .cond = r(2), .t = BlockId.from(2), .f = BlockId.from(3) } }),
        try testBlock(a, &.{}, .{ .Return = r(2) }),
    };
    defer for (&blocks) |*blk| blk.insts.deinit(a);
    try mergeBlocks(a, &blocks);
    // Block 1 joins block 0; block 2 is also its own loop's target, and 3 a branch's.
    try std.testing.expectEqual(@as(usize, 2), blocks[0].insts.items.len);
    try std.testing.expectEqual(Terminator{ .Goto = BlockId.from(2) }, blocks[0].terminator.?);
    try std.testing.expectEqual(Terminator.Unreachable, blocks[1].terminator.?);
    try std.testing.expectEqual(@as(usize, 1), blocks[2].insts.items.len);
}

test "a copy read once in its block is forwarded to its reader" {
    const a = std.testing.allocator;
    const r = Reg.from;
    var blocks = [_]BlockBuf{try testBlock(a, &.{
        .{ .Move = .{ .dst = r(2), .src = r(1) } },
        .{ .BinOp = .{ .dst = r(1), .op = .Add, .lhs = r(2), .rhs = r(0) } },
        .{ .Move = .{ .dst = r(3), .src = r(1) } },
    }, .{ .Branch = .{ .cond = r(3), .t = BlockId.from(0), .f = BlockId.from(0) } })};
    defer blocks[0].insts.deinit(a);
    try forwardCopies(a, &blocks, 4);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].insts.items.len);
    try std.testing.expectEqual(r(1), blocks[0].insts.items[0].BinOp.lhs);
    try std.testing.expectEqual(r(1), blocks[0].terminator.?.Branch.cond);

    // Not into an argument run, nor past a write of the source.
    var run = [_]BlockBuf{try testBlock(a, &.{
        .{ .Move = .{ .dst = r(2), .src = r(1) } },
        .{ .CallStatic = .{ .dst = r(3), .func = FuncId.from(0), .args = r(2), .n_args = 1 } },
    }, .{ .Return = r(3) })};
    defer run[0].insts.deinit(a);
    try forwardCopies(a, &run, 4);
    try std.testing.expectEqual(@as(usize, 2), run[0].insts.items.len);
    var written = [_]BlockBuf{try testBlock(a, &.{
        .{ .Move = .{ .dst = r(2), .src = r(1) } },
        .{ .Const = .{ .dst = r(1), .value = ir.ConstId.from(0) } },
        .{ .BinOp = .{ .dst = r(3), .op = .Add, .lhs = r(2), .rhs = r(1) } },
    }, .{ .Return = r(3) })};
    defer written[0].insts.deinit(a);
    try forwardCopies(a, &written, 4);
    try std.testing.expectEqual(@as(usize, 3), written[0].insts.items.len);
}

test "an edge to an empty block that only jumps goes where it jumps" {
    const a = std.testing.allocator;
    const r = Reg.from;
    var blocks = [_]BlockBuf{
        try testBlock(a, &.{}, .{ .Branch = .{ .cond = r(0), .t = BlockId.from(1), .f = BlockId.from(2) } }),
        try testBlock(a, &.{.{ .Move = .{ .dst = r(1), .src = r(0) } }}, .{ .Goto = BlockId.from(3) }),
        try testBlock(a, &.{}, .{ .Goto = BlockId.from(3) }),
        try testBlock(a, &.{}, .{ .Return = r(1) }),
    };
    defer for (&blocks) |*blk| blk.insts.deinit(a);
    threadJumps(&blocks);
    try std.testing.expectEqual(BlockId.from(3), blocks[0].terminator.?.Branch.f);
    try std.testing.expectEqual(BlockId.from(1), blocks[0].terminator.?.Branch.t);
    // A block with handlers is not passed through.
    const catches = [_]ir.CatchHandler{.{ .class = ir.ClassId.from(0), .handler = BlockId.from(3), .exception_reg = r(2) }};
    blocks[2].handlers.catches = @constCast(&catches);
    blocks[0].terminator = .{ .Branch = .{ .cond = r(0), .t = BlockId.from(1), .f = BlockId.from(2) } };
    threadJumps(&blocks);
    try std.testing.expectEqual(BlockId.from(2), blocks[0].terminator.?.Branch.f);
    blocks[2].handlers.catches = &.{};
}


test "two calls in one block each pass the registers they copied, and the copies go" {
    const a = std.testing.allocator;
    const r = Reg.from;
    var blocks = [_]BlockBuf{try testBlock(a, &.{
        .{ .Move = .{ .dst = r(5), .src = r(0) } },
        .{ .Move = .{ .dst = r(6), .src = r(1) } },
        .{ .CallStatic = .{ .dst = r(7), .func = FuncId.from(0), .args = r(5), .n_args = 2 } },
        .{ .Move = .{ .dst = r(8), .src = r(2) } },
        .{ .Move = .{ .dst = r(9), .src = r(3) } },
        .{ .CallStatic = .{ .dst = r(10), .func = FuncId.from(0), .args = r(8), .n_args = 2 } },
        .{ .BinOp = .{ .dst = r(11), .op = .Add, .lhs = r(7), .rhs = r(10) } },
    }, .{ .Return = r(11) })};
    defer blocks[0].insts.deinit(a);
    try aliasBlockRuns(a, &blocks, 12);
    const insts = blocks[0].insts.items;
    try std.testing.expectEqual(@as(usize, 3), insts.len);
    try std.testing.expectEqual(r(0), insts[0].CallStatic.args);
    try std.testing.expectEqual(r(2), insts[1].CallStatic.args);
    try std.testing.expectEqual(r(11), insts[2].BinOp.dst);
}

test "a copy coalesces past one dropped before it" {
    const a = std.testing.allocator;
    const r = Reg.from;
    // The second copy's walk back to its source passes where the first one
    // was, which wrote the register the second one writes: gone, it is no
    // touch of it.
    var blocks = [_]BlockBuf{try testBlock(a, &.{
        .{ .BinOp = .{ .dst = r(2), .op = .Add, .lhs = r(0), .rhs = r(0) } },
        .{ .Const = .{ .dst = r(1), .value = ir.ConstId.from(0) } },
        .{ .Move = .{ .dst = r(3), .src = r(2) } },
        .{ .Move = .{ .dst = r(3), .src = r(1) } },
    }, .{ .Return = r(3) })};
    defer blocks[0].insts.deinit(a);
    try coalesceBlockCopies(a, &blocks, 4);
    const insts = blocks[0].insts.items;
    try std.testing.expectEqual(@as(usize, 2), insts.len);
    try std.testing.expectEqual(r(3), insts[0].BinOp.dst);
    try std.testing.expectEqual(r(3), insts[1].Const.dst);
}

test "a finished body is copied out of its builder's scratch whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = Reg.from;
    var caps = [_]Reg{ r(1), r(2) };
    var insts = [_]Inst{
        .{ .MakeClosure = .{ .dst = r(0), .func = FuncId.from(3), .captures = &caps } },
    };
    var catches = [_]ir.CatchHandler{.{ .class = ir.ClassId.from(0), .handler = BlockId.from(1), .exception_reg = r(4) }};
    var handlers: ir.BlockHandlers = .{ .catches = &catches };
    const work = [_]ir.Block{
        .{ .id = BlockId.from(0), .insts = &insts, .terminator = .{ .Return = r(0) }, .handlers = &handlers },
        .{ .id = BlockId.from(1), .insts = &.{}, .terminator = .Unreachable },
    };
    const out = try copyOut(a, &work);
    // What scratch held is gone over; the copy keeps the body.
    caps[0] = r(9);
    insts[0].MakeClosure.dst = r(9);
    catches[0].exception_reg = r(9);
    try std.testing.expectEqual(r(0), out[0].insts[0].MakeClosure.dst);
    try std.testing.expectEqualSlices(Reg, &.{ r(1), r(2) }, out[0].insts[0].MakeClosure.captures);
    try std.testing.expectEqual(r(4), out[0].h().catches[0].exception_reg);
    try std.testing.expect(out[1].handlers == null);
    try std.testing.expectEqual(@as(usize, 0), out[1].insts.len);
}
