//! Dense `u32` op code, one array per function holding every block's ops one
//! block after another: the interpreter's one representation. Ops cover the
//! hot instructions; an `escape` op runs any other through its arm in
//! `execInst`.
//!
//! Every block's ops end in its terminator op (`jump`, `br`, `cmp_br`, `ret`
//! or `term_exit`), so flow stays inside the loop. A block reference in an op
//! is two words, the block and the pc its ops are entered at, so an edge moves
//! the pc and nothing else. What a try region does at a block's entry and at
//! its Goto (a try frame pushed or popped) is a `block_entry` op and a
//! `goto_try` op; a finally's pending flow (a return, a throw or a non-local
//! return passing through it) runs in the frame loop.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");

pub const Op = enum(u32) {
    /// dst, const_id: a constant the module's table does not hold, made by the loop.
    const_load,
    /// dst, slot: a scalar constant, one of the function's `values`.
    const_val,
    /// dst, payload: a small Int constant embedded in the stream.
    const_int,
    /// dst, src: copy with retain.
    move,
    /// dst, idx.
    load_param,
    /// dst, cell.
    cell_get,
    /// inst_idx, kind, dst, lhs, rhs. The generic fallback reaches the
    /// original inst through inst_idx.
    bin,
    /// `bin`'s words for an Add: two Ints or two Longs add in place; any
    /// other pair runs as `bin`.
    add,
    /// `bin`'s words for a Sub, as `add`.
    sub,
    /// `bin`'s words for a compare, whose kind word carries the order mask
    /// above its low byte: two Ints or two Longs answer from the mask; any
    /// other pair runs as `bin`.
    cmp,
    /// `bin` for one operator each (`binOp`), so the dispatch that reaches
    /// one chooses the operation.
    bin_mul,
    bin_div,
    bin_mod,
    bin_and,
    bin_or,
    bin_xor,
    bin_shl,
    bin_shr,
    bin_ushr,
    bin_ident_eq,
    bin_ident_neq,
    /// inst_idx: every other instruction, via `execInst`.
    escape,
    /// target (block, pc), edge span: the block's Goto.
    jump,
    /// cond_reg, t (block, pc), f (block, pc), edge span: the block's Branch on a Bool
    /// register. A non-Bool condition exits to the frame loop's terminator path.
    br,
    /// has_val, reg: the block's Return.
    ret,
    /// `ret`'s words, in a function with a try region: a return inside one,
    /// or with a finally's flow pending, runs the frame loop's routing.
    ret_try,
    /// Run the block's real terminator in the frame loop, through its `end` op.
    term_exit,
    /// inst_idx, kind, dst, operand: a unary operator, with the scalar tags
    /// served inline and every other shape falling to the instruction's arm.
    un,
    /// `un` for an increment, a decrement or a negation (`unOp`).
    un_inc,
    un_dec,
    un_neg,
    /// `un`'s words for a conversion to one type each (`UnOp.conversion`),
    /// computed inline.
    conv_byte,
    conv_short,
    conv_int,
    conv_long,
    conv_float,
    conv_double,
    conv_char,
    /// `un`'s words for one numeric function each (`UnOp.function`),
    /// computed inline.
    fn_inv,
    fn_to_raw_bits,
    fn_to_bits,
    fn_float_from_bits,
    fn_double_from_bits,
    fn_count_trailing_zero_bits,
    fn_uint_to_float,
    fn_uint_to_double,
    fn_ulong_to_float,
    fn_ulong_to_double,
    fn_sin,
    fn_cos,
    fn_sqrt,
    fn_to_ulong,
    fn_to_uint,
    fn_to_ushort,
    fn_to_ubyte,
    fn_unsigned_bits,
    /// inst_idx, kind, dst, lhs, rhs, t (block, pc), f (block, pc), edge span:
    /// the block's last instruction is a BinOp whose dst is the Branch condition.
    /// The compare still writes dst, so register state matches the unfused
    /// form; non-scalar operands fall back to the generic arm and branch on dst.
    /// A compare's kind word carries its order mask, as `cmp`'s does.
    cmp_br,
    /// inst_idx, func, args, n_args, dst, site, init: a static call. The loop
    /// runs an interpreted callee without leaving the stream; any other
    /// callee runs through the instruction's arm. `site` indexes the
    /// function's `callees`, where a run leaves the callee's streams for the
    /// next once `init`, the unit the call must see run (`NONE` for none),
    /// has run.
    call,
    /// last span: the end of a block's ops, after its terminator op if it
    /// has one, with the span words of the block's last `Trace`. Each op
    /// dispatches the next, and this one leaves.
    end,
    /// inst_idx, dst, obj, slot: an instance's field read in place; any other
    /// receiver runs through the instruction's arm.
    get_field,
    /// inst_idx, obj, slot, value: an instance's field write in place.
    set_field,
    /// inst_idx, slot, args, n_args, dst, site: a virtual or interface call.
    /// A receiver whose class implements the slot with an interpreted
    /// body runs it in the stream, as `call` does; `site` indexes the
    /// function's `vcallees`, where the first two classes its calls
    /// resolve keep their implementations, bodies or host functions.
    vcall,
    /// inst_idx, class, ctor, args, n_args, dst, site: a constructor call.
    /// A class whose constructor is an interpreted body gets its instance
    /// made here and the constructor run in the stream; `site` is a `callees`
    /// entry, as a `call`'s is.
    new,
    /// inst_idx, callee, args, n_args, dst: a function value's invoke. A
    /// lambda made from sema runs its body in the stream over a copy of its
    /// captures.
    callv,
    /// inst_idx, dst, src: `!` on a Boolean; anything else takes the arm.
    not,
    /// inst_idx, dst, src: `x!!` or a `lateinit` property's read, a copy of anything but
    /// `null`, which takes the instruction's arm (the exception it throws).
    not_null,
    /// inst_idx, native, args, n_args, dst, direct: a host call over the
    /// argument run, read in place. Not `direct` (a `super` call), an
    /// instance receiver's own override of the member answers instead.
    native,
    /// inst_idx, dst, array, index: an array's (or a string's) element read
    /// in place; a null, a bad index or anything else takes the arm.
    array_get,
    /// inst_idx, array, index, value: an array's element write in place.
    array_set,
    /// inst_idx, dst, class: an object's singleton once built; the arm builds it.
    load_object,
    /// dst, idx: a capture of the running closure, as `load_param` reads a parameter.
    load_capture,
    /// n, then n (dst, idx) pairs: every parameter the entry block loads, in
    /// one op at its start. A call the stream loop makes writes them itself
    /// and enters after this op.
    load_params,
    /// The `bin_k` ops, one per operator (`binKOp`): kind, x, kreg, lo, hi,
    /// then a `bin`, `add`, `sub` or `cmp`, that op with one operand a
    /// constant it carries (`Fold`). The kind word holds the operator the
    /// prefix computes with `x` on its left in its low byte, the constant's
    /// `KType` in the next, and the operator's order mask above; `lo` and
    /// `hi` are the constant's bits. A register of the constant's type
    /// computes here and writes the op's dst; any other writes the constant
    /// to `kreg` and runs the op. An op per operator, so the dispatch that
    /// reaches one chooses the operation.
    bin_k_add,
    bin_k_sub,
    bin_k_mul,
    bin_k_div,
    bin_k_mod,
    bin_k_less,
    bin_k_less_eq,
    bin_k_greater,
    bin_k_greater_eq,
    bin_k_eq,
    bin_k_not_eq,
    bin_k_boxed_eq,
    bin_k_boxed_not_eq,
    bin_k_and,
    bin_k_or,
    bin_k_xor,
    bin_k_shl,
    bin_k_shr,
    bin_k_ushr,
    bin_k_ident_eq,
    bin_k_ident_neq,
    /// The `cmp_br_k` ops, one per compare (`cmpBrKOp`): `bin_k`'s words,
    /// then a `cmp_br`, the fused compare with a constant operand,
    /// branching here when the prefix computes it.
    cmp_br_k_less,
    cmp_br_k_less_eq,
    cmp_br_k_greater,
    cmp_br_k_greater_eq,
    cmp_br_k_eq,
    cmp_br_k_not_eq,
    cmp_br_k_boxed_eq,
    cmp_br_k_boxed_not_eq,
    cmp_br_k_ident_eq,
    cmp_br_k_ident_neq,
    /// The first op of a block whose entry pushes, pops or disarms a try
    /// frame, which it does before the block's next op.
    block_entry,
    /// target (block, pc), edge span: a Goto whose leaving pops try frames,
    /// done here; with a finally's flow pending, the frame loop routes it.
    goto_try,
    /// dst, src: a capture cell made over a register.
    make_cell,
    /// inst_idx, cell, value: a store through a capture cell; a register
    /// holding no cell runs the arm, which writes the register.
    cell_set,
    /// inst_idx, static, value: a static store once its init unit has run;
    /// the arm runs the unit first.
    store_static,
    /// inst_idx: a closure over its captures, made by the instruction's arm.
    make_closure,
    /// inst_idx: an array over its argument run, made by the instruction's arm.
    new_array,
    /// inst_idx, dst, src, class, slot: `BoxValue` on an instance or a null, which is itself;
    /// the arm makes the instance over a number.
    box_value,
    /// inst_idx, dst, src, class, slot: `UnboxValue` in place.
    unbox_value,
    /// inst_idx, dst, static: a static read in place once its init unit has
    /// run; the arm runs the unit first.
    load_static,
    /// inst_idx, dst, src, class, nullable: `is` on a value the tables
    /// classify; a function value runs the arm.
    is,
    /// inst_idx, dst, src, class, flags (1 nullable, 2 safe): `as` and `as?`
    /// on a value the tables classify that passes, and `as?` on one that
    /// fails; a failing `as` and a function value run the arm.
    cast,
    /// dst, const_id, slot: a String constant. The site makes its string
    /// once, in the permanent generation, and keeps it in the function's
    /// `strings`; a Kotlin string is immutable, and the JVM interns its
    /// literals.
    const_str,
    /// inst_idx, dst, src: `IterOpen`, a `for` loop's stamp (`runtime.forloop`).
    iter_open,
    /// inst_idx, dst, src, idx, stamp: `IterHas` on an Int position and a Long stamp.
    iter_has,
    /// inst_idx, dst, src, idx, stamp: `IterGet` on an Int position and a Long stamp; a
    /// change since the loop began runs the arm, which throws.
    iter_get,
    /// An op of a compiled function: the op this pc held runs as compiled code
    /// (`JitCode`), its operands still following as they were.
    jit,
};

/// How many words the op at `pc` takes, `op` being the op that starts there.
pub fn opLen(op: Op, code: []const u32, pc: usize) usize {
    return switch (op) {
        .block_entry, .term_exit => 1,
        .escape, .make_closure, .new_array => 2,
        .const_load, .const_val, .const_int, .move, .load_param, .cell_get, .ret, .ret_try, .make_cell, .load_capture => 3,
        .end, .not, .not_null, .const_str, .cell_set, .store_static, .load_static, .load_object, .iter_open => 4,
        .un, .un_inc, .un_dec, .un_neg, .conv_byte, .conv_short, .conv_int, .conv_long, .conv_float, .conv_double, .conv_char, .fn_inv, .fn_to_raw_bits, .fn_to_bits, .fn_float_from_bits, .fn_double_from_bits, .fn_count_trailing_zero_bits, .fn_uint_to_float, .fn_uint_to_double, .fn_ulong_to_float, .fn_ulong_to_double, .fn_sin, .fn_cos, .fn_sqrt, .fn_to_ulong, .fn_to_uint, .fn_to_ushort, .fn_to_ubyte, .fn_unsigned_bits, .get_field, .set_field, .array_get, .array_set => 5,
        .bin, .add, .sub, .cmp, .bin_mul, .bin_div, .bin_mod, .bin_and, .bin_or, .bin_xor, .bin_shl, .bin_shr, .bin_ushr, .bin_ident_eq, .bin_ident_neq, .jump, .goto_try, .is, .cast, .box_value, .unbox_value, .iter_has, .iter_get => 6,
        .bin_k_add, .bin_k_sub, .bin_k_mul, .bin_k_div, .bin_k_mod, .bin_k_less, .bin_k_less_eq, .bin_k_greater, .bin_k_greater_eq, .bin_k_eq, .bin_k_not_eq, .bin_k_boxed_eq, .bin_k_boxed_not_eq, .bin_k_and, .bin_k_or, .bin_k_xor, .bin_k_shl, .bin_k_shr, .bin_k_ushr, .bin_k_ident_eq, .bin_k_ident_neq => 6,
        .cmp_br_k_less, .cmp_br_k_less_eq, .cmp_br_k_greater, .cmp_br_k_greater_eq, .cmp_br_k_eq, .cmp_br_k_not_eq, .cmp_br_k_boxed_eq, .cmp_br_k_boxed_not_eq, .cmp_br_k_ident_eq, .cmp_br_k_ident_neq => 6,
        .vcall, .native, .callv => 7,
        .call, .new => 8,
        .br => 9,
        .cmp_br => 13,
        .load_params => 2 + 2 * @as(usize, code[pc + 1]),
        .jit => unreachable,
    };
}

/// A compiled function's code: the address of the code of the op at each
/// pc, and the op each pc held before its opcode word became `jit`.
pub const JitCode = struct {
    /// Per code word: the address of the code of the op that starts there,
    /// `no_entry` where none does.
    entries: []const usize,
    /// Per code word: the op that starts there (`jit` where none does).
    ops: []const Op,
    /// Where the callees compiled into the code leave it (`InlineExit`), kept
    /// as long as the code.
    exits: ?*std.heap.ArenaAllocator = null,
    /// The code this code replaced, which a frame may still be running.
    prev: ?*const JitCode = null,

    pub const no_entry: usize = 0;

    pub inline fn entry(self: *const JitCode, pc: usize) usize {
        return self.entries[pc];
    }
};

/// Where code a callee was compiled into leaves it for the interpreter: each
/// callee it runs in gets its frame, outermost first, and op `op` at `pc` in
/// block `blk` of the innermost one runs there.
pub const InlineExit = struct {
    levels: []const InlineLevel,
    op: Op,
    pc: u32,
    blk: u32,
    /// For an `is` or `cast`, the class test's cache the code reads, which
    /// the exit fills for the value it left with.
    cache: ?*u64 = null,
    /// Times the code has left here (`baseline.exit_threshold`).
    runs: std.atomic.Value(u32) = .init(0),
};

/// A call compiled code makes of the callee its site keeps (`baseline.Gen.directCall`): what
/// the callee's direct entry (`FuncStreams.direct_entry`) and the shared code that makes the
/// call otherwise (`stream.directCall`) read of it. Compiled code reads it at fixed offsets.
/// It carries the callee's shape and the caller's way back as the site compiled them, so a
/// call reads this record and the thread's own state and nothing of either function's
/// streams, which a program with many callees finds out of cache.
pub const DirectSite = extern struct {
    // What a call reads, in the record's first two cache lines (`baseline` allocates it on a
    // line's start); the rest only a call the handler takes reads.
    sc: *const FuncStreams,
    /// The callee's function and code, as `sc` holds them.
    func: *const ir.Func,
    code: [*]const u32,
    /// The callee's compiled code at `npc`, when it was compiled as the site compiled.
    entry: usize,
    /// Where the caller's compiled code goes on after the call (`Activation.ret_code`), set as
    /// the caller's code is installed.
    back: usize,
    /// The caller's streams and code, which the callee returns into.
    caller: *const FuncStreams,
    caller_code: [*]const u32,
    /// The call's block and its instruction there, where the caller stands: one word.
    blk: u32,
    idx: u32,
    /// The argument run: its first register's offset in the caller's window, in bytes, and its
    /// length.
    lo16: u32,
    nargs: u32,
    /// The callee's window, where it goes on once its parameters are loaded, and its entry
    /// block.
    n_locals: u32,
    npc: u32,
    eb: u32,
    /// The callee's parameter pairs in `pairs`: its register, then the argument it loads.
    npairs: u32,
    ret_idx: u32,
    ret_pc: u32,
    dst: ir.Reg,
    /// For a virtual call, the class its receiver's instance is; `no_class` for a static call.
    class: u32,
    /// Whether the shape above opens the callee's frame: the callee was compiled, its
    /// parameters fit `pairs`, and opening its frame fills no register and clears no try
    /// stack or span.
    shaped: bool,
    /// Whether a call it leaves to the handler counts toward compiling the caller again
    /// (`FuncStreams.stale`).
    stale: bool,
    pairs: [2 * max_pairs]u32,
    pc: u32,
    op: Op,

    pub const no_class = std.math.maxInt(u32);
    pub const max_pairs = 6;

    /// Fills in the callee's shape once it is compiled (`entries` its entry table), where
    /// opening its frame takes nothing past it; the flag goes last, so a reader that sees it
    /// sees the rest. Any thread may: they write the same words.
    pub fn takeShape(self: *DirectSite, entries: [*]const usize) void {
        const sc = self.sc;
        const open = sc.open;
        if (open.fill_all or open.keeps_try or open.clear_span or sc.fill.len != 0 or sc.param_map.len > self.pairs.len) return;
        const e = entries[self.npc];
        if (e == JitCode.no_entry) return;
        for (sc.param_map, 0..) |w, i| self.pairs[i] = w;
        self.npairs = @intCast(sc.param_map.len / 2);
        self.entry = e;
        @atomicStore(bool, &self.shaped, true, .release);
    }

    pub inline fn isShaped(self: *const DirectSite) bool {
        return @atomicLoad(bool, &self.shaped, .acquire);
    }
};

/// A callee compiled into its caller's code, as one of its exits finds it.
pub const InlineLevel = struct {
    sc: *const FuncStreams,
    /// The call's pc and block in the caller's streams.
    call_pc: u32,
    call_blk: u32,
    /// The callee's first register in the thread's inline registers.
    area: u32,
    /// The callee's registers written by the time the exit is reached; the
    /// others are `Unit`.
    written: []const u16,
    /// The span the callee's blocks left: known to the compiler, or in the
    /// thread's slot for this level.
    span: InlineSpan,
};

pub const InlineSpan = union(enum) {
    known: ?ir.Span,
    slot,
};

/// Span words: a span as three words (file, start, end). `Trace` runs no op: a
/// frame records where it stands at every instruction that can observe a span (an
/// escape, a call, a throw), and its span is the last `Trace` before there in its
/// block, else its block's entry span (`FuncStreams.entry_spans`). An edge op's words
/// are the span it leaves in the frame for a target that finds its entry span there
/// (`spanmap.edgeSpan`): file `NO_SPAN` for none to leave, `NULL_SPAN` for leaving
/// none. The `end` op's words are its block's last `Trace`, or `NO_SPAN`.
pub const NO_SPAN: u32 = std.math.maxInt(u32);
pub const NULL_SPAN: u32 = std.math.maxInt(u32) - 1;

/// The span words `sp` names.
fn spanWords(sp: ?ir.Span) [3]u32 {
    const x = sp orelse return .{ NULL_SPAN, 0, 0 };
    return .{ x.file.int(), x.start, x.end };
}

/// The span a block's last `Trace` names, as the `end` op's words.
fn lastTraceWords(blk: *const ir.Block) [3]u32 {
    const sp = ir.spanmap.lastTrace(blk) orelse return .{ NO_SPAN, 0, 0 };
    return spanWords(sp);
}

/// The span the words at `code[at]` leave: null for `NULL_SPAN`. Not for `NO_SPAN`.
pub fn wordsSpan(code: []const u32, at: usize) ?ir.Span {
    if (code[at] == NULL_SPAN) return null;
    return .{ .file = @enumFromInt(code[at]), .start = code[at + 1], .end = code[at + 2] };
}

/// A block's place in its function's code.
pub const BlockCode = struct {
    /// The pc an edge to the block enters at: its `block_entry` op when it
    /// has one, else `start`.
    enter: u32,
    /// The pc of the block's first op after `block_entry`.
    start: u32,
    /// The pc of the block's `end` op.
    end: u32,
    /// `idx_pc[i]` = the pc where instruction `i`'s encoding begins, so the
    /// resume machinery's (block, idx) coordinates enter mid-block.
    idx_pc: []const u32,
};

/// A function's code and where each block sits in it, indexed by BlockId.
/// Process-lifetime cache data: built once, never freed; a lazily-decoded
/// body gets a fresh table.
pub const FuncStreams = struct {
    func: *const ir.Func,
    /// Every block's ops, each block closed by its `end` op.
    code: []const u32,
    blocks: []const BlockCode,
    /// The pc a call enters the function at.
    entry_pc: u32,
    /// The entry block's parameter loads as (dst, idx) pairs, and the pc
    /// after its `load_params` op: a call that writes them enters there.
    /// Empty when the entry block has none, or a `block_entry` op first.
    param_map: []const u32 = &.{},
    body_pc: u32 = 0,
    /// Per `call` site, the callee's streams once a call has resolved them.
    callees: []std.atomic.Value(?*const FuncStreams),
    /// Per `vcall` site, the implementations the first two receiver classes it resolved run, once
    /// a call has resolved one the loop runs in place.
    vcallees: []std.atomic.Value(?*const VEntry) = &.{},
    /// Per `callv` site, the lambda its calls have run, once one has (`LambdaSite`).
    lambdas: []std.atomic.Value(?*const LambdaSite) = &.{},
    /// Per `const_str` site, the cell of its string once a load has made it (0 before).
    strings: []std.atomic.Value(usize),
    /// The scalar constants the function's `const_val` ops load, made when its code is built.
    values: []const runtime.Value,
    /// The registers a frame of the function writes `Unit` to as it opens
    /// (`framemap.fillSet`), so that every register live anywhere holds a value there; empty
    /// for almost every function. `Open.fill_all` for one no frame map covers, whose frames
    /// fill every register.
    fill: []const u32 = &.{},
    /// What opening a frame of the function does beyond its window, in the one byte a call
    /// reads for it.
    open: Open = .{},
    /// What a call runs in place of a frame when the body is only field traffic (`leafOf`).
    leaf: Leaf = .none,
    /// The function's compiled code once the JIT has compiled it; every op's
    /// opcode word is then `jit`.
    jit: std.atomic.Value(?*const JitCode) = .init(null),
    /// `jit`'s entries, published with it, read by the `jit` op without the
    /// hop through `JitCode`.
    jit_entries: std.atomic.Value(?[*]const usize) = .init(null),
    /// Where a compiled caller goes in the function's current code to call it (`DirectSite`):
    /// code that opens the function's frame, as a call's handler would, and goes on at its
    /// entry. 0 when its code has none.
    direct_entry: std.atomic.Value(usize) = .init(0),
    /// Entries and loop edges counted toward compiling the function; racing
    /// counts may lose one, which only moves when it compiles.
    hot: std.atomic.Value(u32) = .init(0),
    /// Runs of call sites its compiled code leaves to the call for want of a
    /// callee the site's cache held when it compiled; at the JIT's threshold
    /// the function compiles again with what the caches hold then.
    stale: std.atomic.Value(u32) = .init(0),
    /// Times the function has compiled again for its call sites' caches.
    recompiles: u8 = 0,
    /// Times the function has compiled again for callees it ran in place that left its code
    /// too often (`exits_hot`).
    exit_recompiles: u8 = 0,
    /// Set once an op of the function compiled into a caller has left the caller's code at
    /// `baseline.exit_threshold` runs: compiled callers call the function from then on rather
    /// than run it in place.
    exits_hot: std.atomic.Value(bool) = .init(false),
    /// A constructor a `new` runs as its leaf: its class's instance as the
    /// op makes it in region memory, built at the first `new` that can use it.
    new_template: std.atomic.Value(?*const runtime.InstanceData.Template) = .init(null),
    /// How the code runs the instructions it does not run as they stand (hoisted parameter
    /// loads, constants an op carries), for the frame map.
    effects: []const ir.framemap.Effect = &.{},
    /// Per block, the span a frame standing in it before its first `Trace` is in
    /// (`spanmap.entrySpans`).
    entry_spans: []const ir.spanmap.EntrySpan = &.{},
    /// Per block, the try frames in effect from its entry on (`trymap.tryContexts`), none
    /// in a function with no try region: the function keeps no try stack as it runs, and a
    /// route through its handlers finds the frames from its block. Null for a function two
    /// paths into a block of which leave different frames, which keeps its try stack.
    try_ctx: ?ir.trymap.TryContexts = null,
    /// Whether a block opens a try region.
    has_try: bool = false,

    /// What a frame of the function is known by from its position (`framemap.FrameMap`),
    /// built the first time anything asks: its address, `no_frame_map` for a function it
    /// cannot map, 0 before.
    frame_map: std.atomic.Value(usize) = .init(0),

    pub const Open = packed struct(u8) {
        /// No frame map covers the function: its frames fill every register (`fill`).
        fill_all: bool = false,
        /// The function keeps its try stack (`try_ctx` null): it starts empty.
        keeps_try: bool = false,
        /// The entry block finds its span in the frame (`spanmap.EntrySpan.dyn`): it
        /// starts none.
        clear_span: bool = false,
        _: u5 = 0,
    };

    /// The function's frame map, built now if nothing has asked before; null for a function
    /// whose registers or blocks it cannot map. Safe from any thread, a collector's included:
    /// it reads the function's blocks, which do not change once published.
    pub fn frameMap(self: *const FuncStreams) ?*const ir.framemap.FrameMap {
        const m = self.frame_map.load(.acquire);
        if (m == no_frame_map) return null;
        if (m != 0) return @ptrFromInt(m);
        return self.frameMapSlow();
    }

    noinline fn frameMapSlow(self: *const FuncStreams) ?*const ir.framemap.FrameMap {
        const a = std.heap.smp_allocator;
        const func = self.func;
        const built: usize = blk: {
            const fm = (ir.framemap.FrameMap.init(a, func.blocks, func.entry.int(), func.n_locals, self.effects) catch break :blk no_frame_map) orelse break :blk no_frame_map;
            const p = a.create(ir.framemap.FrameMap) catch {
                var x = fm;
                x.deinit(a);
                break :blk no_frame_map;
            };
            p.* = fm;
            break :blk @intFromPtr(p);
        };
        const slot = &@constCast(self).frame_map;
        if (slot.cmpxchgStrong(0, built, .acq_rel, .acquire)) |won| {
            if (built != no_frame_map) {
                const p: *ir.framemap.FrameMap = @ptrFromInt(built);
                p.deinit(a);
                a.destroy(p);
            }
            return if (won == no_frame_map) null else @ptrFromInt(won);
        }
        return if (built == no_frame_map) null else @ptrFromInt(built);
    }

    /// The op that starts at `pc`, through `jit` to the op it stands for.
    pub fn opAt(self: *const FuncStreams, pc: usize) Op {
        const op: Op = @enumFromInt(@atomicLoad(u32, &self.code[pc], .acquire));
        if (op != .jit) return op;
        return self.jit.load(.acquire).?.ops[pc];
    }
};

/// A body that only moves fields of its first parameter, which a call runs
/// without a frame of its own.
pub const Leaf = union(enum) {
    none,
    /// Returns field `slot` of parameter 0: a default getter.
    get_field: u32,
    /// Stores each parameter in its field of parameter 0, in order, and
    /// returns parameter 0: a constructor that only takes its properties.
    set_fields: SetFields,
};

pub const FieldStore = struct { slot: u32, param: u16 };

/// A constructor's field stores, and the object (a companion) whose
/// singleton it loads to initialize, `NO_OBJECT` for none. Once that object
/// is built the load does nothing, and a call runs the stores alone.
pub const SetFields = struct {
    stores: []const FieldStore,
    object: u32 = NO_OBJECT,
    /// The superclass constructor the body calls before its stores, over
    /// its own parameters. A call runs that constructor's leaf first.
    super: ?Super = null,
};

/// A constructor's call of its superclass's: the call's site (its callee is
/// at `FuncStreams.callees[site]` once a call has resolved it), and for
/// each of the callee's parameters, the caller's parameter passed there.
pub const Super = struct { site: u32, args: []const u16 };

fn freeLeaf(a: std.mem.Allocator, leaf: Leaf) void {
    if (leaf != .set_fields) return;
    a.free(leaf.set_fields.stores);
    if (leaf.set_fields.super) |sup| a.free(sup.args);
}

pub const NO_OBJECT: u32 = std.math.maxInt(u32);

/// `FuncStreams.frame_map` for a function no map covers.
const no_frame_map: usize = 1;

/// The `Leaf` of `func`: one block, no handlers, reading parameters and
/// either returning a field of parameter 0 or storing parameters in its
/// fields and returning it, the stores after at most one load of an object
/// whose value nothing reads and one call that passes the parameters on,
/// parameter 0 first, and whose result nothing reads.
fn leafOf(a: std.mem.Allocator, func: *const ir.Func, call_sites: u32) Leaf {
    if (func.entry.int() != 0) return .none;
    const leaf = leafOfBlocks(a, func.blocks);
    // The super call is the body's one call, site 0, unless the encoder
    // left it to the instruction's arm.
    if (leaf == .set_fields and leaf.set_fields.super != null and call_sites != 1) {
        freeLeaf(a, leaf);
        return .none;
    }
    return leaf;
}

fn leafOfBlocks(a: std.mem.Allocator, blocks: []const ir.Block) Leaf {
    if (blocks.len != 1) return .none;
    const b = &blocks[0];
    if (b.handlers != null) return .none;
    const ret: ?ir.Reg = switch (b.terminator) {
        .Return => |r| r,
        else => return .none,
    };
    // A register another instruction writes after a parameter load no
    // longer holds the parameter: an entry of index `overwritten` says so.
    const overwritten = std.math.maxInt(u16);
    const Param = struct { reg: ir.Reg, idx: u16 };
    var params: [16]Param = undefined;
    var n_params: usize = 0;
    var stores: [16]FieldStore = undefined;
    var n_stores: usize = 0;
    var object: u32 = NO_OBJECT;
    var super_args: [16]u16 = undefined;
    var n_super: ?usize = null;
    const paramOf = struct {
        fn f(ps: []const Param, r: ir.Reg) ?u16 {
            var i = ps.len;
            while (i > 0) {
                i -= 1;
                if (ps[i].reg == r) return if (ps[i].idx == overwritten) null else ps[i].idx;
            }
            return null;
        }
    }.f;
    for (b.insts, 0..) |inst, i| switch (inst) {
        .LoadParam => |lp| {
            if (n_params == params.len or lp.idx == overwritten) return .none;
            params[n_params] = .{ .reg = lp.dst, .idx = lp.idx };
            n_params += 1;
        },
        .LoadObject => |lo| {
            if (object != NO_OBJECT or n_params == params.len) return .none;
            object = lo.class.int();
            params[n_params] = .{ .reg = lo.dst, .idx = overwritten };
            n_params += 1;
        },
        .Move => |mv| {
            if (n_params == params.len) return .none;
            params[n_params] = .{ .reg = mv.dst, .idx = paramOf(params[0..n_params], mv.src) orelse overwritten };
            n_params += 1;
        },
        .CallStatic => |cs| {
            if (n_super != null or n_stores != 0 or cs.init != ir.NO_UNIT) return .none;
            if (cs.n_args == 0 or cs.n_args > super_args.len or n_params == params.len) return .none;
            for (0..cs.n_args) |j| super_args[j] = paramOf(params[0..n_params], ir.Reg.from(cs.args.int() + @as(u32, @intCast(j)))) orelse return .none;
            if (super_args[0] != 0) return .none;
            n_super = cs.n_args;
            params[n_params] = .{ .reg = cs.dst, .idx = overwritten };
            n_params += 1;
        },
        .GetFieldSlot => |g| {
            if (i + 1 != b.insts.len or n_stores != 0 or object != NO_OBJECT or n_super != null) return .none;
            if ((paramOf(params[0..n_params], g.obj) orelse return .none) != 0) return .none;
            if (ret == null or ret.? != g.dst) return .none;
            return .{ .get_field = g.slot };
        },
        .SetFieldSlot => |st| {
            if ((paramOf(params[0..n_params], st.obj) orelse return .none) != 0) return .none;
            const from = paramOf(params[0..n_params], st.value) orelse return .none;
            if (from == 0 or n_stores == stores.len) return .none;
            stores[n_stores] = .{ .slot = st.slot, .param = from };
            n_stores += 1;
        },
        else => return .none,
    };
    const r = ret orelse return .none;
    if ((paramOf(params[0..n_params], r) orelse return .none) != 0) return .none;
    const own = a.dupe(FieldStore, stores[0..n_stores]) catch return .none;
    const sup: ?Super = if (n_super) |n| .{ .site = 0, .args = a.dupe(u16, super_args[0..n]) catch {
        a.free(own);
        return .none;
    } } else null;
    return .{ .set_fields = .{ .stores = own, .object = object, .super = sup } };
}

var cache_mutex: runtime.SpinMutex = .{};
/// Keyed per function: a table names the `Func` it was built for, and a call
/// runs that `Func`'s blocks. The address alone is not an identity: a function
/// freed and another built at the same address would serve the first one's
/// streams, so the key carries its blocks and a shape signature of them, and a
/// run clears the cache (`resetCacheForTest`).
const CacheKey = struct { func: usize, blocks: usize, sig: u64 };

fn blocksSignature(blocks: []const ir.Block) u64 {
    var h = std.hash.Wyhash.init(blocks.len);
    for (blocks) |*b| {
        h.update(std.mem.asBytes(&@as(u32, @intCast(b.insts.len))));
        h.update(std.mem.asBytes(&@as(u8, @intFromEnum(b.terminator))));
        if (b.insts.len != 0) {
            h.update(std.mem.asBytes(&@as(u8, @intFromEnum(b.insts[0]))));
            h.update(std.mem.asBytes(&@as(u8, @intFromEnum(b.insts[b.insts.len - 1]))));
        }
    }
    return h.final();
}
var cache: ?std.AutoHashMap(CacheKey, *const FuncStreams) = null;

/// Generation for the per-Func `bc_memo` fast path: `resetCacheForTest` frees
/// every cached FuncStreams, so a Func surviving the reset must not serve its
/// memoized pointer into freed memory.
var stream_gen = std.atomic.Value(u32).init(1);

/// Drop every cached stream table, freeing the streams. Keys are blocks
/// pointers, stable only for one program's life: an in-process driver reuses
/// those addresses and a stale hit would run the wrong stream.
pub fn resetCacheForTest() void {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    _ = stream_gen.fetchAdd(1, .monotonic);
    const c = if (cache) |*cc| cc else return;
    const a = std.heap.smp_allocator;
    var it = c.valueIterator();
    while (it.next()) |fs_p| {
        const fs = fs_p.*;
        for (fs.blocks) |b| a.free(b.idx_pc);
        a.free(fs.blocks);
        a.free(fs.code);
        a.free(fs.values);
        a.free(fs.callees);
        a.free(fs.strings);
        freeLeaf(a, fs.leaf);
        var next_jc = fs.jit.load(.acquire);
        while (next_jc) |jc| {
            next_jc = jc.prev;
            a.free(jc.entries);
            a.free(jc.ops);
            if (jc.exits) |ar| {
                ar.deinit();
                a.destroy(ar);
            }
            a.destroy(jc);
        }
        if (fs.param_map.len != 0) a.free(fs.param_map);
        const fm = fs.frame_map.load(.acquire);
        if (fm > no_frame_map) {
            const p: *ir.framemap.FrameMap = @ptrFromInt(fm);
            p.deinit(a);
            a.destroy(p);
        }
        a.free(fs.effects);
        a.free(fs.entry_spans);
        if (fs.try_ctx) |t| {
            var tc = t;
            tc.deinit(a);
        }
        a.free(fs.fill);
        a.destroy(fs);
    }
    c.clearRetainingCapacity();
}

/// The streams of `func`'s blocks; `consts` is the owning module's table, for
/// embedded payloads. The memo on the `Func` answers inline; the shared cache
/// behind it takes a global mutex and a hash probe.
pub inline fn funcStreams(func: *const ir.Func, consts: []const ir.Const) ?*const FuncStreams {
    const m = func.bc_memo.load(.acquire);
    if (m != 0 and func.bc_memo_gen == stream_gen.load(.monotonic)) {
        return if (m == 1) null else @ptrFromInt(m);
    }
    return funcStreamsSlow(func, consts);
}

fn funcStreamsSlow(func: *const ir.Func, consts: []const ir.Const) ?*const FuncStreams {
    // A body another thread is still publishing has none yet (`Module.ensureFuncBody`).
    if (@atomicLoad(u32, &func.deferred_offset, .acquire) != 0) return null;
    if (func.blocks.len == 0) return null;
    const gen = stream_gen.load(.monotonic);
    const key: CacheKey = .{ .func = @intFromPtr(func), .blocks = @intFromPtr(func.blocks.ptr), .sig = blocksSignature(func.blocks) };
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (cache == null) {
        cache = std.AutoHashMap(CacheKey, *const FuncStreams).init(std.heap.smp_allocator);
    }
    if (cache.?.get(key)) |fs| {
        @constCast(func).bc_memo_gen = gen;
        @constCast(func).bc_memo.store(@intFromPtr(fs), .release);
        return fs;
    }
    const a = std.heap.smp_allocator;
    var sites: Sites = .{};
    const laid = buildBlocks(func.blocks, func.entry.int(), consts, func.n_locals, &sites) orelse return null;
    const callees = a.alloc(std.atomic.Value(?*const FuncStreams), sites.calls) catch return null;
    for (callees) |*c| c.* = .init(null);
    const strings = a.alloc(std.atomic.Value(usize), sites.strings) catch return null;
    for (strings) |*c| c.* = .init(0);
    const vcallees = a.alloc(std.atomic.Value(?*const VEntry), sites.vcalls) catch return null;
    for (vcallees) |*c| c.* = .init(null);
    const lambdas = a.alloc(std.atomic.Value(?*const LambdaSite), sites.callvs) catch return null;
    for (lambdas) |*c| c.* = .init(null);
    const fill = ir.framemap.fillSet(a, func.blocks, func.entry.int(), func.n_locals, laid.effects) catch null;
    const fs = a.create(FuncStreams) catch return null;
    fs.* = .{
        .func = func,
        .code = laid.code,
        .blocks = laid.blocks,
        .entry_pc = laid.blocks[func.entry.int()].enter,
        .param_map = laid.param_map,
        .body_pc = laid.body_pc,
        .effects = laid.effects,
        .entry_spans = laid.entry_spans,
        .try_ctx = laid.try_ctx,
        .has_try = laid.has_try,
        .callees = callees,
        .strings = strings,
        .vcallees = vcallees,
        .lambdas = lambdas,
        .values = laid.values,
        .fill = fill orelse &.{},
        .open = .{ .fill_all = fill == null, .keeps_try = laid.try_ctx == null, .clear_span = laid.entry_spans[func.entry.int()] == .dyn },
        .leaf = leafOf(a, func, sites.calls),
    };
    cache.?.put(key, fs) catch return fs;
    @constCast(func).bc_memo_gen = gen;
    @constCast(func).bc_memo.store(@intFromPtr(fs), .release);
    return fs;
}

/// What the try machinery does around a block, which the frame loop runs: at its entry (a try
/// frame pushed, a catch-only try's frame popped at its join, a finally's frame disarmed as the
/// finally begins) and at its Goto (a finally's frame popped, a pending flow a finally's end
/// completes or replays, an inline return's frames popped). A Branch does none of it, and a
/// Return checks for it where it runs. A function whose try frames are known where each block
/// stands (`trymap.tryContexts`) keeps no try stack: its blocks push and pop nothing, a Goto
/// checks only for a pending flow where a finally's end keys one, and a return with a finally
/// to run goes to the frame loop, which finds the frames from its block.
const BlockFx = struct {
    entry: bool = false,
    goto: bool = false,
    try_ret: bool = false,
    /// A return that runs a finally first, in a function with known try frames.
    ret_exit: bool = false,
    /// The span words of the block's edge ops: the span they leave for their targets.
    span: [3]u32 = .{ NO_SPAN, 0, 0 },
};

/// Whether any block opens a try region, so a return may have finallys to run.
fn hasTry(blocks: []const ir.Block) bool {
    for (blocks) |*b| {
        if (b.h().catches.len != 0 or b.h().finally != null) return true;
    }
    return false;
}

fn blockEffects(blocks: []const ir.Block, tc: ?*const ir.trymap.TryContexts) ?[]BlockFx {
    const fx = std.heap.smp_allocator.alloc(BlockFx, blocks.len) catch return null;
    @memset(fx, .{});
    const try_ret = hasTry(blocks);
    for (blocks, fx, 0..) |*b, *f, bi| {
        const h = b.h();
        f.try_ret = try_ret;
        if (tc) |t| {
            for (t.of(@intCast(bi))) |body| if (blocks[body].h().finally != null) {
                f.ret_exit = true;
                break;
            };
            continue;
        }
        if (h.catches.len != 0 or h.finally != null or h.catch_done_for != null) f.entry = true;
        if (h.finally_done_for != null or h.pop_on_exit.len != 0) f.goto = true;
    }
    // A finally's entry disarms its frame, and a finally or its done sentinel keys a pending flow.
    for (blocks) |*b| {
        const h = b.h();
        if (h.finally) |fin| if (fin.int() < fx.len) {
            if (tc == null) fx[fin.int()].entry = true;
            fx[fin.int()].goto = true;
        };
        if (h.finally_done) |d| if (d.int() < fx.len) {
            fx[d.int()].goto = true;
        };
    }
    return fx;
}

/// Build-time bound on every register operand a dedicated op emits. With the
/// frame loop's `regs.len >= n_locals` entry check this proves stream register
/// accesses in bounds, so the hot helpers index unchecked. Out of range
/// demotes the instruction to an escape.
fn regOk(n_locals: u32, r: u32) bool {
    return r < n_locals;
}

/// The outcomes of comparing two Ints or two Longs that a compare holds for, one bit each: bit 0
/// less, bit 1 equal, bit 2 greater. Zero for any other operator.
pub fn orderMask(op: ir.BinOp) u32 {
    return switch (op) {
        .Less => 0b001,
        .LessEq => 0b011,
        .Eq, .BoxedEq => 0b010,
        .NotEq, .BoxedNotEq => 0b101,
        .Greater => 0b100,
        .GreaterEq => 0b110,
        else => 0,
    };
}

/// A binary op's kind word: the operator in the low byte, its order mask above.
pub fn kindWord(op: ir.BinOp) u32 {
    return @intFromEnum(op) | orderMask(op) << 8;
}

/// A constant other than a String, as the value a load makes of it.
fn scalarValue(c: ir.Const) runtime.Value {
    return switch (c) {
        .Unit => .Unit,
        .Int => |v| .{ .Int = v },
        .Long => |v| .{ .Long = v },
        .UInt => |v| .{ .UInt = v },
        .ULong => |v| .{ .ULong = v },
        .UShort => |v| .{ .UShort = v },
        .UByte => |v| .{ .UByte = v },
        .Short => |v| .{ .Short = v },
        .Byte => |v| .{ .Byte = v },
        .Double => |v| .{ .Double = v },
        .Float => |v| .{ .Float = v },
        .Bool => |v| .{ .Bool = v },
        .Char => |v| .{ .Char = v },
        .Null => .Null,
        .String => unreachable,
    };
}

/// The per-function site counters a stream build numbers its call and string sites with.
const Sites = struct { calls: u32 = 0, strings: u32 = 0, vcalls: u32 = 0, callvs: u32 = 0 };

/// A `callv` site's lambda: the function literal's record the closures it
/// called point to, and what that record runs, the lambda's streams in the
/// module its body belongs to. Immutable once published.
pub const LambdaSite = struct {
    record: *const anyopaque,
    sc: *const FuncStreams,
    module: *const ir.Module,
    /// The sub-module the body was lowered into, null for the main module.
    owning: ?*const ir.Module,
};

/// A `vcall` site's receiver classes, up to two, and for each the implementation it runs: the
/// streams of an interpreted body, or, where that is null, the host function the tables bind.
/// Immutable once published: a site that meets a second class publishes a new entry.
pub const VEntry = struct {
    classes: [2]u32,
    streams: [2]?*const FuncStreams,
    natives: [2]ir.NativeId,
    n: u32,
};

/// A block reference's pc word, filled in once every block's start is known.
const Fixup = struct { pos: u32, block: u32 };

/// One function's code under construction.
const Emit = struct {
    code: std.ArrayList(u32) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    values: std.ArrayList(runtime.Value) = .empty,

    /// A block reference: the block, then the pc its ops start at.
    fn blockRef(e: *Emit, b: ir.BlockId) bool {
        const a = std.heap.smp_allocator;
        e.code.append(a, b.int()) catch return false;
        e.fixups.append(a, .{ .pos = @intCast(e.code.items.len), .block = b.int() }) catch return false;
        e.code.append(a, 0) catch return false;
        return true;
    }
};

const Laid = struct {
    code: []const u32,
    blocks: []const BlockCode,
    values: []const runtime.Value,
    param_map: []const u32 = &.{},
    body_pc: u32 = 0,
    effects: []const ir.framemap.Effect = &.{},
    entry_spans: []const ir.spanmap.EntrySpan = &.{},
    try_ctx: ?ir.trymap.TryContexts = null,
    has_try: bool = false,
};

/// The entry block's parameter loads that `load_params` takes: each may run first, since
/// it writes a register nothing else writes, or one nothing before it in the entry block
/// touches, in an entry block nothing jumps back to.
const Hoist = struct {
    pairs: []u32,
    skip: []bool,
};

fn entryHoist(a: std.mem.Allocator, blocks: []const ir.Block, entry: u32, n_locals: u32) ?Hoist {
    if (entry >= blocks.len) return .{ .pairs = &.{}, .skip = &.{} };
    const defs = a.alloc(u32, n_locals) catch return null;
    defer a.free(defs);
    @memset(defs, 0);
    const Count = struct {
        defs: []u32,
        fn cb(c: @This(), r: ir.Reg, is_def: bool) void {
            if (is_def and r.int() < c.defs.len) c.defs[r.int()] += 1;
        }
    };
    for (blocks) |*blk| {
        for (blk.insts) |*inst| ir.visitInstRegs(inst, Count{ .defs = defs }, Count.cb);
        for (blk.h().catches) |c| Count.cb(.{ .defs = defs }, c.exception_reg, true);
    }
    const insts = blocks[entry].insts;
    const skip = a.alloc(bool, insts.len) catch return null;
    @memset(skip, false);
    const reentered = for (blocks) |*blk| {
        if (targets(blk, entry)) break true;
    } else false;
    var pairs: std.ArrayList(u32) = .empty;
    for (insts, 0..) |*inst, i| switch (inst.*) {
        .LoadParam => |lp| if (regOk(n_locals, lp.dst.int()) and
            (defs[lp.dst.int()] == 1 or (!reentered and !touchedIn(insts[0..i], lp.dst))))
        {
            pairs.appendSlice(a, &.{ lp.dst.int(), lp.idx }) catch return null;
            skip[i] = true;
        },
        else => {},
    };
    return .{ .pairs = pairs.toOwnedSlice(a) catch return null, .skip = skip };
}

/// Whether `blk` jumps to block `b` or names it as a handler.
fn targets(blk: *const ir.Block, b: u32) bool {
    switch (blk.terminator) {
        .Goto => |t| if (t.int() == b) return true,
        .Branch => |br| if (br.t.int() == b or br.f.int() == b) return true,
        else => {},
    }
    for (blk.h().catches) |c| if (c.handler.int() == b) return true;
    if (blk.h().finally) |f| if (f.int() == b) return true;
    return false;
}

/// Whether one of `insts` reads or writes `r`.
fn touchedIn(insts: []const ir.Inst, r: ir.Reg) bool {
    for (insts) |*inst| if (touch(inst, r) != .none) return true;
    return false;
}

const Touch = enum { read, write, none };

/// How `inst` meets `r`: reading it (whether or not it writes it too), writing it, or not.
fn touch(inst: *const ir.Inst, r: ir.Reg) Touch {
    const Seen = struct {
        r: ir.Reg,
        read: *bool,
        write: *bool,
        fn cb(c: @This(), x: ir.Reg, is_def: bool) void {
            if (x != c.r) return;
            if (is_def) c.write.* = true else c.read.* = true;
        }
    };
    var read = false;
    var write = false;
    ir.visitInstRegs(inst, Seen{ .r = r, .read = &read, .write = &write }, Seen.cb);
    return if (read) .read else if (write) .write else .none;
}

/// Whether a `bin` can compute `op` in place for some operands: every operator but those only
/// the instruction's arm computes (string concatenation, ranges, `?:`, `pow`).
fn scalarOperator(op: ir.BinOp) bool {
    return switch (op) {
        .StringConcat, .RangeTo, .RangeUntil, .DownTo, .Elvis, .Pow => false,
        else => true,
    };
}

/// The type of a constant a `bin_k` or `cmp_br_k` carries.
pub const KType = enum(u8) { int, long, float, double, ulong, uint, null };

/// A BinOp's constant operand, which its op carries in its own words: the
/// Const's register is written by that Const alone and read by the BinOp
/// alone, so the Const runs no op, and the BinOp writes the register itself
/// before it takes its general path.
pub const Fold = struct {
    /// The constant's register.
    reg: u32,
    /// The constant, as the op computes with it: an Int or a Long.
    value: ir.Const,
    /// The operator the op computes, the register on its left: the BinOp's
    /// own for a constant on the right, its mirror for one on the left.
    op: ir.BinOp,
};

/// The folds of a function's instructions, indexed with its blocks' instructions laid end to
/// end (`base[block] + index`).
const Folds = struct {
    base: []u32,
    /// A Const whose BinOp carries it.
    skip: []bool,
    /// A BinOp's constant operand.
    fold: []?Fold,

    fn deinit(f: Folds, a: std.mem.Allocator) void {
        a.free(f.base);
        a.free(f.skip);
        a.free(f.fold);
    }
};

/// Whether `bin_k` computes the operator with a constant of this kind: an
/// Int or a Long in arithmetic, bitwise operations, shifts and compares; a
/// Float or a Double, other than NaN, in arithmetic and compares; an
/// unsigned number in equality; `null` in equality and identity.
pub fn foldable(op: ir.BinOp, c: ir.Const) bool {
    return switch (c) {
        .Int, .Long => switch (op) {
            .Add, .Sub, .Mul, .Div, .Mod, .Less, .LessEq, .Greater, .GreaterEq, .Eq, .NotEq, .BoxedEq, .BoxedNotEq, .And, .Or, .Xor, .Shl, .Shr, .UShr => true,
            else => false,
        },
        .Float => |f| !std.math.isNan(f) and floatFoldable(op),
        .Double => |d| !std.math.isNan(d) and floatFoldable(op),
        .ULong, .UInt => switch (op) {
            .Eq, .NotEq, .BoxedEq, .BoxedNotEq => true,
            else => false,
        },
        // `x == null` is `x === null`.
        .Null => switch (op) {
            .Eq, .NotEq, .BoxedEq, .BoxedNotEq, .IdentEq, .IdentNeq => true,
            else => false,
        },
        else => false,
    };
}

fn floatFoldable(op: ir.BinOp) bool {
    return switch (op) {
        .Add, .Sub, .Mul, .Div, .Mod, .Less, .LessEq, .Greater, .GreaterEq, .Eq, .NotEq => true,
        else => false,
    };
}

fn kType(c: ir.Const) KType {
    return switch (c) {
        .Int => .int,
        .Long => .long,
        .Float => .float,
        .Double => .double,
        .ULong => .ulong,
        .UInt => .uint,
        .Null => .null,
        else => unreachable,
    };
}

/// A folded constant's bits, as its op's `lo` and `hi` words hold them.
pub fn kBits(c: ir.Const) u64 {
    return switch (c) {
        .Int => |v| @as(u32, @bitCast(v)),
        .Long => |v| @bitCast(v),
        .Float => |v| @as(u32, @bitCast(v)),
        .Double => |v| @bitCast(v),
        .ULong => |v| v,
        .UInt => |v| v,
        .Null => 0,
        else => unreachable,
    };
}

/// The op a BinOp takes: an Add and a Sub their own, a compare `cmp`, an operator a `bin_*` op
/// computes that op, any other `bin`.
pub fn binOp(op: ir.BinOp) Op {
    return switch (op) {
        .Add => .add,
        .Sub => .sub,
        .Mul => .bin_mul,
        .Div => .bin_div,
        .Mod => .bin_mod,
        .And => .bin_and,
        .Or => .bin_or,
        .Xor => .bin_xor,
        .Shl => .bin_shl,
        .Shr => .bin_shr,
        .UShr => .bin_ushr,
        .IdentEq => .bin_ident_eq,
        .IdentNeq => .bin_ident_neq,
        else => if (orderMask(op) != 0) .cmp else .bin,
    };
}

/// The operator a `bin_*` op computes; null for the other ops.
pub fn binOperator(o: Op) ?ir.BinOp {
    return switch (o) {
        .bin_mul => .Mul,
        .bin_div => .Div,
        .bin_mod => .Mod,
        .bin_and => .And,
        .bin_or => .Or,
        .bin_xor => .Xor,
        .bin_shl => .Shl,
        .bin_shr => .Shr,
        .bin_ushr => .UShr,
        .bin_ident_eq => .IdentEq,
        .bin_ident_neq => .IdentNeq,
        else => null,
    };
}

/// The op a UnOp takes: a conversion and a numeric function their own, an increment, a
/// decrement and a negation theirs, any other `un`.
pub fn unOp(op: ir.UnOp) Op {
    if (op.conversion()) |t| return switch (t) {
        .byte => .conv_byte,
        .short => .conv_short,
        .int => .conv_int,
        .long => .conv_long,
        .float => .conv_float,
        .double => .conv_double,
        .char => .conv_char,
    };
    if (op.function()) |f| return switch (f) {
        .inv => .fn_inv,
        .to_raw_bits => .fn_to_raw_bits,
        .to_bits => .fn_to_bits,
        .float_from_bits => .fn_float_from_bits,
        .double_from_bits => .fn_double_from_bits,
        .count_trailing_zero_bits => .fn_count_trailing_zero_bits,
        .uint_to_float => .fn_uint_to_float,
        .uint_to_double => .fn_uint_to_double,
        .ulong_to_float => .fn_ulong_to_float,
        .ulong_to_double => .fn_ulong_to_double,
        .sin => .fn_sin,
        .cos => .fn_cos,
        .sqrt => .fn_sqrt,
        .to_ulong => .fn_to_ulong,
        .to_uint => .fn_to_uint,
        .to_ushort => .fn_to_ushort,
        .to_ubyte => .fn_to_ubyte,
        .unsigned_bits => .fn_unsigned_bits,
    };
    return switch (op) {
        .Inc => .un_inc,
        .Dec => .un_dec,
        .Neg => .un_neg,
        else => .un,
    };
}

/// The operator an `un_*` op computes; null for the other ops.
pub fn unOperator(o: Op) ?ir.UnOp {
    return switch (o) {
        .un_inc => .Inc,
        .un_dec => .Dec,
        .un_neg => .Neg,
        else => null,
    };
}

/// The type a `conv_*` op converts to; null for the other ops.
pub fn convTarget(o: Op) ?runtime.numconv.Target {
    return switch (o) {
        .conv_byte => .byte,
        .conv_short => .short,
        .conv_int => .int,
        .conv_long => .long,
        .conv_float => .float,
        .conv_double => .double,
        .conv_char => .char,
        else => null,
    };
}

/// The function an `fn_*` op computes; null for the other ops.
pub fn fnOf(o: Op) ?runtime.numfn.Fn {
    return switch (o) {
        .fn_inv => .inv,
        .fn_to_raw_bits => .to_raw_bits,
        .fn_to_bits => .to_bits,
        .fn_float_from_bits => .float_from_bits,
        .fn_double_from_bits => .double_from_bits,
        .fn_count_trailing_zero_bits => .count_trailing_zero_bits,
        .fn_uint_to_float => .uint_to_float,
        .fn_uint_to_double => .uint_to_double,
        .fn_ulong_to_float => .ulong_to_float,
        .fn_ulong_to_double => .ulong_to_double,
        .fn_sin => .sin,
        .fn_cos => .cos,
        .fn_sqrt => .sqrt,
        .fn_to_ulong => .to_ulong,
        .fn_to_uint => .to_uint,
        .fn_to_ushort => .to_ushort,
        .fn_to_ubyte => .to_ubyte,
        .fn_unsigned_bits => .unsigned_bits,
        else => null,
    };
}

/// The `bin_k` op computing `op`, one `foldable` takes.
pub fn binKOp(op: ir.BinOp) Op {
    return switch (op) {
        .Add => .bin_k_add,
        .Sub => .bin_k_sub,
        .Mul => .bin_k_mul,
        .Div => .bin_k_div,
        .Mod => .bin_k_mod,
        .Less => .bin_k_less,
        .LessEq => .bin_k_less_eq,
        .Greater => .bin_k_greater,
        .GreaterEq => .bin_k_greater_eq,
        .Eq => .bin_k_eq,
        .NotEq => .bin_k_not_eq,
        .BoxedEq => .bin_k_boxed_eq,
        .BoxedNotEq => .bin_k_boxed_not_eq,
        .And => .bin_k_and,
        .Or => .bin_k_or,
        .Xor => .bin_k_xor,
        .Shl => .bin_k_shl,
        .Shr => .bin_k_shr,
        .UShr => .bin_k_ushr,
        .IdentEq => .bin_k_ident_eq,
        .IdentNeq => .bin_k_ident_neq,
        else => unreachable,
    };
}

/// The `cmp_br_k` op for compare `op`; null for any other operator.
pub fn cmpBrKOp(op: ir.BinOp) ?Op {
    return switch (op) {
        .Less => .cmp_br_k_less,
        .LessEq => .cmp_br_k_less_eq,
        .Greater => .cmp_br_k_greater,
        .GreaterEq => .cmp_br_k_greater_eq,
        .Eq => .cmp_br_k_eq,
        .NotEq => .cmp_br_k_not_eq,
        .BoxedEq => .cmp_br_k_boxed_eq,
        .BoxedNotEq => .cmp_br_k_boxed_not_eq,
        .IdentEq => .cmp_br_k_ident_eq,
        .IdentNeq => .cmp_br_k_ident_neq,
        else => null,
    };
}

/// The operator a `bin_k` or `cmp_br_k` op computes; null for the other ops.
pub fn kOperator(o: Op) ?ir.BinOp {
    return switch (o) {
        .bin_k_add => .Add,
        .bin_k_sub => .Sub,
        .bin_k_mul => .Mul,
        .bin_k_div => .Div,
        .bin_k_mod => .Mod,
        .bin_k_less => .Less,
        .bin_k_less_eq => .LessEq,
        .bin_k_greater => .Greater,
        .bin_k_greater_eq => .GreaterEq,
        .bin_k_eq => .Eq,
        .bin_k_not_eq => .NotEq,
        .bin_k_boxed_eq => .BoxedEq,
        .bin_k_boxed_not_eq => .BoxedNotEq,
        .bin_k_and => .And,
        .bin_k_or => .Or,
        .bin_k_xor => .Xor,
        .bin_k_shl => .Shl,
        .bin_k_shr => .Shr,
        .bin_k_ushr => .UShr,
        .bin_k_ident_eq => .IdentEq,
        .bin_k_ident_neq => .IdentNeq,
        .cmp_br_k_less => .Less,
        .cmp_br_k_less_eq => .LessEq,
        .cmp_br_k_greater => .Greater,
        .cmp_br_k_greater_eq => .GreaterEq,
        .cmp_br_k_eq => .Eq,
        .cmp_br_k_not_eq => .NotEq,
        .cmp_br_k_boxed_eq => .BoxedEq,
        .cmp_br_k_boxed_not_eq => .BoxedNotEq,
        .cmp_br_k_ident_eq => .IdentEq,
        .cmp_br_k_ident_neq => .IdentNeq,
        else => null,
    };
}

/// A `bin_k`'s kind word.
pub fn kWord(f: Fold) u32 {
    return @intFromEnum(f.op) | @as(u32, @intFromEnum(kType(f.value))) << 8 | orderMask(f.op) << 16;
}

/// `k op x` as `x op' k`, or null when the operator has no mirror.
pub fn mirrored(op: ir.BinOp) ?ir.BinOp {
    return switch (op) {
        .Add, .Mul, .Eq, .NotEq, .BoxedEq, .BoxedNotEq, .IdentEq, .IdentNeq, .And, .Or, .Xor => op,
        .Less => .Greater,
        .LessEq => .GreaterEq,
        .Greater => .Less,
        .GreaterEq => .LessEq,
        else => null,
    };
}

fn constFolds(a: std.mem.Allocator, blocks: []const ir.Block, consts: []const ir.Const, n_locals: u32) ?Folds {
    const base = a.alloc(u32, blocks.len) catch return null;
    var n: u32 = 0;
    for (blocks, base) |*blk, *b| {
        b.* = n;
        n += @intCast(blk.insts.len);
    }
    const skip = a.alloc(bool, n) catch return null;
    @memset(skip, false);
    const fold = a.alloc(?Fold, n) catch return null;
    @memset(fold, null);
    const out: Folds = .{ .base = base, .skip = skip, .fold = fold };
    const Uses = struct { defs: u32 = 0, reads: u32 = 0 };
    const uses = a.alloc(Uses, n_locals) catch return null;
    defer a.free(uses);
    @memset(uses, .{});
    const Count = struct {
        uses: []Uses,
        fn cb(c: @This(), r: ir.Reg, is_def: bool) void {
            if (r.int() >= c.uses.len) return;
            if (is_def) c.uses[r.int()].defs += 1 else c.uses[r.int()].reads += 1;
        }
    };
    const count: Count = .{ .uses = uses };
    for (blocks) |*blk| {
        for (blk.insts) |*inst| ir.visitInstRegs(inst, count, Count.cb);
        ir.visitTerminatorRegs(&blk.terminator, count, Count.cb);
        for (blk.h().catches) |c| Count.cb(count, c.exception_reg, true);
    }
    // The Const defining each register that one Const writes and one instruction reads.
    const defs = a.alloc(ConstDef, n_locals) catch return null;
    defer a.free(defs);
    @memset(defs, .{});
    for (blocks, base) |*blk, b| for (blk.insts, 0..) |inst, i| switch (inst) {
        .Const => |c| if (regOk(n_locals, c.dst.int()) and c.value.int() < consts.len) {
            const u = uses[c.dst.int()];
            if (u.defs == 1 and u.reads == 1)
                defs[c.dst.int()] = .{ .at = b + @as(u32, @intCast(i)), .cid = c.value.int() };
        },
        else => {},
    };
    var near: NearConst = .{ .a = a, .blocks = blocks, .consts = consts, .n_locals = n_locals };
    defer near.deinit();
    for (blocks, base, 0..) |*blk, b, bi| for (blk.insts, 0..) |inst, i| switch (inst) {
        .BinOp => |bo| {
            if (!regOk(n_locals, bo.dst.int()) or !regOk(n_locals, bo.lhs.int()) or !regOk(n_locals, bo.rhs.int())) continue;
            const Side = struct { reg: u32, op: ir.BinOp, def: ConstDef };
            const side: ?Side = pick: {
                const r = if (defs[bo.rhs.int()].at != NO_CONST) defs[bo.rhs.int()] else near.def(bi, b, i, bo, bo.rhs);
                if (r.at != NO_CONST and foldable(bo.op, consts[r.cid])) break :pick .{ .reg = bo.rhs.int(), .op = bo.op, .def = r };
                const m = mirrored(bo.op) orelse break :pick null;
                const l = if (defs[bo.lhs.int()].at != NO_CONST) defs[bo.lhs.int()] else near.def(bi, b, i, bo, bo.lhs);
                if (l.at != NO_CONST and foldable(bo.op, consts[l.cid])) break :pick .{ .reg = bo.lhs.int(), .op = m, .def = l };
                break :pick null;
            };
            const sd = side orelse continue;
            // A BinOp the block's Branch reads fuses with it, and only a compare has a `cmp_br_k`.
            if (i + 1 == blk.insts.len and blk.terminator == .Branch and blk.terminator.Branch.cond.int() == bo.dst.int() and
                cmpBrKOp(sd.op) == null) continue;
            skip[sd.def.at] = true;
            fold[b + i] = .{ .reg = sd.reg, .value = consts[sd.def.cid], .op = sd.op };
        },
        else => {},
    };
    return out;
}

const NO_CONST = std.math.maxInt(u32);

/// A Const a BinOp carries: where it is, with the blocks' instructions laid end to end, and
/// its constant; `at` is `NO_CONST` for none.
const ConstDef = struct { at: u32 = NO_CONST, cid: u32 = 0 };

/// The Const a BinOp reads a register from when the register has other writers or readers:
/// one in the BinOp's block with nothing between them touching the register, which the BinOp
/// reads once and nothing reads after it, nor a catch or a finally a throw between the two
/// could reach. The liveness this asks for is found on the first such question.
const NearConst = struct {
    a: std.mem.Allocator,
    blocks: []const ir.Block,
    consts: []const ir.Const,
    n_locals: u32,
    live: ?ir.regs.Live = null,
    tried: bool = false,

    fn deinit(self: *NearConst) void {
        if (self.live) |*l| l.deinit(self.a);
    }

    fn def(self: *NearConst, bi: usize, b: u32, i: usize, bo: anytype, reg: ir.Reg) ConstDef {
        if (bo.lhs == bo.rhs) return .{};
        const blk = &self.blocks[bi];
        const insts = blk.insts;
        var k = i;
        const at: usize = while (k > 0) {
            k -= 1;
            if (touch(&insts[k], reg) != .none) break k;
        } else return .{};
        const c = switch (insts[at]) {
            .Const => |c| c,
            else => return .{},
        };
        if (c.value.int() >= self.consts.len) return .{};
        const lv = self.liveness() orelse return .{};
        if (lv.isHandled(reg.int())) return .{};
        if (bo.dst != reg) {
            const after = for (insts[i + 1 ..]) |*x| {
                const t = touch(x, reg);
                if (t != .none) break t;
            } else Touch.none;
            switch (after) {
                .read => return .{},
                .write => {},
                .none => {
                    if (termReads(&blk.terminator, reg) or lv.isLiveOut(bi, reg.int())) return .{};
                },
            }
        }
        return .{ .at = b + @as(u32, @intCast(at)), .cid = c.value.int() };
    }

    fn liveness(self: *NearConst) ?*const ir.regs.Live {
        if (!self.tried) {
            self.tried = true;
            self.live = ir.regs.Live.init(self.a, self.blocks, self.n_locals) catch null;
        }
        return if (self.live) |*l| l else null;
    }
};

fn termReads(t: *const ir.Terminator, r: ir.Reg) bool {
    const Seen = struct {
        r: ir.Reg,
        hit: *bool,
        fn cb(c: @This(), x: ir.Reg, _: bool) void {
            if (x == c.r) c.hit.* = true;
        }
    };
    var hit = false;
    ir.visitTerminatorRegs(t, Seen{ .r = r, .hit = &hit }, Seen.cb);
    return hit;
}

/// `blocks` laid out in one code array with every block reference's pc filled in. Null when an
/// allocation fails or an edge names no block.
fn buildBlocks(blocks: []const ir.Block, entry: u32, consts: []const ir.Const, n_locals: u32, sites: *Sites) ?Laid {
    const a = std.heap.smp_allocator;
    var e: Emit = .{};
    defer e.fixups.deinit(a);
    // A function with no try region stands in none anywhere.
    const has_try = hasTry(blocks);
    const try_ctx: ?ir.trymap.TryContexts = if (has_try) (ir.trymap.tryContexts(a, blocks, entry) catch return null) else ir.trymap.TryContexts.none;
    const fx = blockEffects(blocks, if (try_ctx) |*t| t else null) orelse return null;
    defer a.free(fx);
    const entry_spans = ir.spanmap.entrySpans(a, blocks, entry) catch return null;
    for (blocks, fx, 0..) |*b, *f, bi| {
        var succ: [2]u32 = undefined;
        const ts: []const u32 = switch (b.terminator) {
            .Goto => |g| blk: {
                succ[0] = g.int();
                break :blk succ[0..1];
            },
            .Branch => |br| blk: {
                succ = .{ br.t.int(), br.f.int() };
                break :blk &succ;
            },
            else => &.{},
        };
        if (ir.spanmap.edgeSpan(entry_spans, b, @intCast(bi), ts)) |es| f.span = switch (es) {
            .span => |sp| spanWords(sp),
            .none => spanWords(null),
        };
    }
    const hoist = entryHoist(a, blocks, entry, n_locals) orelse return null;
    defer a.free(hoist.skip);
    const folds = constFolds(a, blocks, consts, n_locals) orelse return null;
    defer folds.deinit(a);
    const out = a.alloc(BlockCode, blocks.len) catch return null;
    var body_pc: u32 = 0;
    for (blocks, out, fx, 0..) |*blk, *slot, f, bi| {
        const h: ?*const Hoist = if (bi == entry and hoist.pairs.len != 0) &hoist else null;
        slot.* = build(blk, f, consts, n_locals, sites, &e, h, &body_pc, .{ .folds = &folds, .base = folds.base[bi] }) orelse return null;
    }
    for (e.fixups.items) |f| {
        if (f.block >= out.len) return null;
        e.code.items[f.pos] = out[f.block].enter;
    }
    // A `block_entry` op at the entry comes first: a call enters there, and
    // the entry block's ops load the parameters.
    const direct = hoist.pairs.len != 0 and entry < fx.len and !fx[entry].entry;
    if (!direct and hoist.pairs.len != 0) a.free(hoist.pairs);
    // How the code runs the instructions it does not run as they stand, for the frame map.
    var effects: std.ArrayList(ir.framemap.Effect) = .empty;
    if (hoist.pairs.len != 0) for (hoist.skip, 0..) |h, i| {
        if (h) effects.append(a, .{ .at = folds.base[entry] + @as(u32, @intCast(i)), .kind = .hoisted }) catch return null;
    };
    for (folds.skip, folds.fold, 0..) |sk, fo, g| {
        if (sk) effects.append(a, .{ .at = @intCast(g), .kind = .skipped }) catch return null;
        if (fo) |f| effects.append(a, .{ .at = @intCast(g), .kind = .unread, .reg = f.reg }) catch return null;
    }
    return .{
        .code = e.code.toOwnedSlice(a) catch return null,
        .blocks = out,
        .values = e.values.toOwnedSlice(a) catch return null,
        .param_map = if (direct) hoist.pairs else &.{},
        .body_pc = body_pc,
        .effects = effects.toOwnedSlice(a) catch return null,
        .entry_spans = entry_spans,
        .try_ctx = try_ctx,
        .has_try = has_try,
    };
}

/// A block's place in its function's `Folds`.
const BlockFolds = struct {
    folds: ?*const Folds = null,
    base: u32 = 0,

    fn skip(bf: BlockFolds, i: usize) bool {
        const f = bf.folds orelse return false;
        return f.skip[bf.base + i];
    }

    fn fold(bf: BlockFolds, i: usize) ?Fold {
        const f = bf.folds orelse return null;
        return f.fold[bf.base + i];
    }
};

fn build(blk: *const ir.Block, fx: BlockFx, consts: []const ir.Const, n_locals: u32, sites: *Sites, e: *Emit, hoist: ?*const Hoist, body_pc: *u32, bf: BlockFolds) ?BlockCode {
    const insts = blk.insts;
    var fuse_cmp_idx: ?usize = null;
    if (insts.len != 0) {
        switch (blk.terminator) {
            .Branch => |br| switch (insts[insts.len - 1]) {
                .BinOp => |bo| {
                    if (bo.dst.int() == br.cond.int()) fuse_cmp_idx = insts.len - 1;
                },
                else => {},
            },
            else => {},
        }
    }
    const a = std.heap.smp_allocator;
    const code = &e.code;
    const enter: u32 = @intCast(code.items.len);
    if (fx.entry) code.append(a, @intFromEnum(Op.block_entry)) catch return null;
    const start: u32 = @intCast(code.items.len);
    if (hoist) |h| {
        code.append(a, @intFromEnum(Op.load_params)) catch return null;
        code.append(a, @intCast(h.pairs.len / 2)) catch return null;
        code.appendSlice(a, h.pairs) catch return null;
        body_pc.* = @intCast(code.items.len);
    }
    var idx_pc = a.alloc(u32, insts.len) catch return null;
    for (insts, 0..) |*inst, i| {
        idx_pc[i] = @intCast(code.items.len);
        if (hoist) |h| if (h.skip[i]) continue;
        if (bf.skip(i)) continue;
        if (bf.fold(i)) |k| {
            const bo = insts[i].BinOp;
            const bits = kBits(k.value);
            code.appendSlice(a, &.{
                @intFromEnum(if (fuse_cmp_idx == i) cmpBrKOp(k.op).? else binKOp(k.op)),
                kWord(k),
                if (bo.rhs.int() == k.reg) bo.lhs.int() else bo.rhs.int(),
                k.reg,
                @truncate(bits),
                @truncate(bits >> 32),
            }) catch return null;
        }
        if (fuse_cmp_idx == i and regOk(n_locals, insts[i].BinOp.dst.int()) and
            regOk(n_locals, insts[i].BinOp.lhs.int()) and regOk(n_locals, insts[i].BinOp.rhs.int()))
        {
            const bo = insts[i].BinOp;
            const br = blk.terminator.Branch;
            const cx = fx.span;
            code.appendSlice(a, &.{
                @intFromEnum(Op.cmp_br),
                @intCast(i),
                kindWord(bo.op),
                bo.dst.int(),
                bo.lhs.int(),
                bo.rhs.int(),
            }) catch return null;
            if (!e.blockRef(br.t) or !e.blockRef(br.f)) return null;
            code.appendSlice(a, &cx) catch return null;
            continue;
        }
        switch (inst.*) {
            .Const => |c| {
                if (!regOk(n_locals, c.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                const cid = c.value.int();
                if (cid < consts.len and consts[cid] == .Int) {
                    code.appendSlice(a, &.{
                        @intFromEnum(Op.const_int),
                        c.dst.int(),
                        @bitCast(consts[cid].Int),
                    }) catch return null;
                    continue;
                }
                if (cid < consts.len and consts[cid] == .String) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.const_str), c.dst.int(), cid, sites.strings }) catch return null;
                    sites.strings += 1;
                    continue;
                }
                if (cid < consts.len) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.const_val), c.dst.int(), @intCast(e.values.items.len) }) catch return null;
                    e.values.append(a, scalarValue(consts[cid])) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.const_load), c.dst.int(), c.value.int() }) catch return null;
            },
            .Move => |mv| {
                if (!regOk(n_locals, mv.dst.int()) or !regOk(n_locals, mv.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.move), mv.dst.int(), mv.src.int() }) catch return null;
            },
            .LoadParam => |lp| {
                if (!regOk(n_locals, lp.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.load_param), lp.dst.int(), @intCast(lp.idx) }) catch return null;
            },
            .CellGet => |cg| {
                if (!regOk(n_locals, cg.dst.int()) or !regOk(n_locals, cg.cell.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.cell_get), cg.dst.int(), cg.cell.int() }) catch return null;
            },
            .Trace => {},
            .UnOp => |u| {
                if (!regOk(n_locals, u.dst.int()) or !regOk(n_locals, u.operand.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{
                    @intFromEnum(unOp(u.op)),
                    @intCast(i),
                    @intFromEnum(u.op),
                    u.dst.int(),
                    u.operand.int(),
                }) catch return null;
            },
            .GetFieldSlot => |g| {
                if (!regOk(n_locals, g.dst.int()) or !regOk(n_locals, g.obj.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.get_field), @intCast(i), g.dst.int(), g.obj.int(), g.slot }) catch return null;
            },
            .SetFieldSlot => |sf| {
                if (!regOk(n_locals, sf.obj.int()) or !regOk(n_locals, sf.value.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.set_field), @intCast(i), sf.obj.int(), sf.slot, sf.value.int() }) catch return null;
            },
            .RCallVirtual, .CallInterface => {
                const slot, const args, const n_args, const dst = switch (inst.*) {
                    .RCallVirtual => |v| .{ v.slot, v.args, v.n_args, v.dst },
                    .CallInterface => |v| .{ v.slot, v.args, v.n_args, v.dst },
                    else => unreachable,
                };
                const run_ok = n_args != 0 and regOk(n_locals, args.int() + n_args - 1);
                if (!run_ok or !regOk(n_locals, dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.vcall), @intCast(i), slot.int(), args.int(), n_args, dst.int(), sites.vcalls }) catch return null;
                sites.vcalls += 1;
            },
            .RNewInstance => |ni| {
                const run_ok = ni.n_args == 0 or regOk(n_locals, ni.args.int() + ni.n_args - 1);
                if (!run_ok or !regOk(n_locals, ni.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.new), @intCast(i), ni.class.int(), ni.ctor.int(), ni.args.int(), ni.n_args, ni.dst.int(), sites.calls }) catch return null;
                sites.calls += 1;
            },
            .RCallValue => |cv| {
                const run_ok = cv.n_args == 0 or regOk(n_locals, cv.args.int() + cv.n_args - 1);
                if (!run_ok or !regOk(n_locals, cv.dst.int()) or !regOk(n_locals, cv.callee.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.callv), @intCast(i), cv.callee.int(), cv.args.int(), cv.n_args, cv.dst.int(), sites.callvs }) catch return null;
                sites.callvs += 1;
            },
            .CallNative => |cn| {
                const run_ok = cn.n_args == 0 or regOk(n_locals, cn.args.int() + cn.n_args - 1);
                if (!run_ok or !regOk(n_locals, cn.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.native), @intCast(i), cn.native.int(), cn.args.int(), cn.n_args, cn.dst.int(), @intFromBool(cn.direct) }) catch return null;
            },
            .LoadCapture => |lc| {
                if (!regOk(n_locals, lc.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.load_capture), lc.dst.int(), @intCast(lc.idx) }) catch return null;
            },
            .LoadStatic => |ls| {
                if (!regOk(n_locals, ls.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.load_static), @intCast(i), ls.dst.int(), ls.static.int() }) catch return null;
            },
            .RInstanceOf => |t| {
                if (!regOk(n_locals, t.dst.int()) or !regOk(n_locals, t.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.is), @intCast(i), t.dst.int(), t.src.int(), t.class.int(), @intFromBool(t.nullable) }) catch return null;
            },
            .RCast => |t| {
                if (!regOk(n_locals, t.dst.int()) or !regOk(n_locals, t.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                const flags = @as(u32, @intFromBool(t.nullable)) | @as(u32, @intFromBool(t.safe)) << 1;
                code.appendSlice(a, &.{ @intFromEnum(Op.cast), @intCast(i), t.dst.int(), t.src.int(), t.class.int(), flags }) catch return null;
            },
            .MakeCell => |mc| {
                if (!regOk(n_locals, mc.dst.int()) or !regOk(n_locals, mc.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.make_cell), mc.dst.int(), mc.src.int() }) catch return null;
            },
            .CellSet => |cs| {
                if (!regOk(n_locals, cs.cell.int()) or !regOk(n_locals, cs.value.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.cell_set), @intCast(i), cs.cell.int(), cs.value.int() }) catch return null;
            },
            .StoreStatic => |ss| {
                if (!regOk(n_locals, ss.value.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.store_static), @intCast(i), ss.static.int(), ss.value.int() }) catch return null;
            },
            .MakeClosure => code.appendSlice(a, &.{ @intFromEnum(Op.make_closure), @intCast(i) }) catch return null,
            inline .BoxValue, .UnboxValue => |bv, tag| {
                if (!regOk(n_locals, bv.dst.int()) or !regOk(n_locals, bv.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                const op: Op = if (tag == .BoxValue) .box_value else .unbox_value;
                code.appendSlice(a, &.{ @intFromEnum(op), @intCast(i), bv.dst.int(), bv.src.int(), bv.class.int(), bv.slot }) catch return null;
            },
            .NewArray => code.appendSlice(a, &.{ @intFromEnum(Op.new_array), @intCast(i) }) catch return null,
            .ArrayGet => |ag| {
                if (!regOk(n_locals, ag.dst.int()) or !regOk(n_locals, ag.array.int()) or !regOk(n_locals, ag.index.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.array_get), @intCast(i), ag.dst.int(), ag.array.int(), ag.index.int() }) catch return null;
            },
            .ArraySet => |as| {
                if (!regOk(n_locals, as.array.int()) or !regOk(n_locals, as.index.int()) or !regOk(n_locals, as.value.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.array_set), @intCast(i), as.array.int(), as.index.int(), as.value.int() }) catch return null;
            },
            .LoadObject => |lo| {
                if (!regOk(n_locals, lo.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.load_object), @intCast(i), lo.dst.int(), lo.class.int() }) catch return null;
            },
            .Not => |n| {
                if (!regOk(n_locals, n.dst.int()) or !regOk(n_locals, n.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.not), @intCast(i), n.dst.int(), n.src.int() }) catch return null;
            },
            .IterOpen => |x| {
                if (!regOk(n_locals, x.dst.int()) or !regOk(n_locals, x.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.iter_open), @intCast(i), x.dst.int(), x.src.int() }) catch return null;
            },
            inline .IterHas, .IterGet => |x, tag| {
                if (!regOk(n_locals, x.dst.int()) or !regOk(n_locals, x.src.int()) or !regOk(n_locals, x.idx.int()) or !regOk(n_locals, x.stamp.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                const op: Op = if (tag == .IterHas) .iter_has else .iter_get;
                code.appendSlice(a, &.{ @intFromEnum(op), @intCast(i), x.dst.int(), x.src.int(), x.idx.int(), x.stamp.int() }) catch return null;
            },
            inline .NotNullAssert, .LateinitCheck => |n| {
                if (!regOk(n_locals, n.dst.int()) or !regOk(n_locals, n.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.not_null), @intCast(i), n.dst.int(), n.src.int() }) catch return null;
            },
            .CallStatic => |cs| {
                const run_ok = cs.n_args == 0 or regOk(n_locals, cs.args.int() + cs.n_args - 1);
                if (!run_ok or !regOk(n_locals, cs.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{
                    @intFromEnum(Op.call),
                    @intCast(i),
                    cs.func.int(),
                    cs.args.int(),
                    cs.n_args,
                    cs.dst.int(),
                    sites.calls,
                    cs.init,
                }) catch return null;
                sites.calls += 1;
            },
            .BinOp => |bo| {
                // An operator no op computes in place goes straight to its arm.
                if (!regOk(n_locals, bo.dst.int()) or !regOk(n_locals, bo.lhs.int()) or
                    !regOk(n_locals, bo.rhs.int()) or !scalarOperator(bo.op))
                {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                const op = binOp(bo.op);
                code.appendSlice(a, &.{
                    @intFromEnum(op),
                    @intCast(i),
                    kindWord(bo.op),
                    bo.dst.int(),
                    bo.lhs.int(),
                    bo.rhs.int(),
                }) catch return null;
            },
            else => {
                code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
            },
        }
    }
    const xs = fx.span;
    {
        switch (blk.terminator) {
            .Goto => |g| {
                code.append(a, @intFromEnum(if (fx.goto) Op.goto_try else Op.jump)) catch return null;
                if (!e.blockRef(g)) return null;
                code.appendSlice(a, &xs) catch return null;
            },
            .Branch => |br| {
                // A cmp_br already carries the branch.
                if (fuse_cmp_idx == null) {
                    if (regOk(n_locals, br.cond.int())) {
                        code.appendSlice(a, &.{ @intFromEnum(Op.br), br.cond.int() }) catch return null;
                        if (!e.blockRef(br.t) or !e.blockRef(br.f)) return null;
                        code.appendSlice(a, &xs) catch return null;
                    } else {
                        code.append(a, @intFromEnum(Op.term_exit)) catch return null;
                    }
                }
            },
            .Return => |maybe_r| {
                if (fx.ret_exit or (maybe_r != null and !regOk(n_locals, maybe_r.?.int()))) {
                    code.append(a, @intFromEnum(Op.term_exit)) catch return null;
                } else {
                    code.appendSlice(a, &.{
                        @intFromEnum(if (fx.try_ret) Op.ret_try else Op.ret),
                        @intFromBool(maybe_r != null),
                        if (maybe_r) |r| r.int() else 0,
                    }) catch return null;
                }
            },
            else => {
                code.append(a, @intFromEnum(Op.term_exit)) catch return null;
            },
        }
    }
    const end: u32 = @intCast(code.items.len);
    code.append(a, @intFromEnum(Op.end)) catch return null;
    code.appendSlice(a, &lastTraceWords(blk)) catch return null;
    return .{ .enter = enter, .start = start, .end = end, .idx_pc = idx_pc };
}

test {
    std.testing.refAllDecls(@This());
}

/// The site counters the encoding tests hand `build`.
var test_sites: Sites = .{};

/// The pc a lone block's references name: `TEST_PC` plus the block.
const TEST_PC: u32 = 1000;

/// One block built alone at pc 0, as the encoding tests read it.
fn buildOne(blk: *const ir.Block, consts: []const ir.Const, n_locals: u32, sites: *Sites) ?struct { code: []const u32, idx_pc: []const u32, values: []const runtime.Value } {
    var e: Emit = .{};
    var body_pc: u32 = 0;
    const b = build(blk, .{}, consts, n_locals, sites, &e, null, &body_pc, .{}) orelse return null;
    for (e.fixups.items) |f| e.code.items[f.pos] = TEST_PC + f.block;
    return .{ .code = e.code.items, .idx_pc = b.idx_pc, .values = e.values.items };
}

test "stream encoding: dedicated ops, operand words, idx_pc, escape" {
    var insts = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(1), .value = ir.ConstId.from(7) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(2), .op = .Add, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0), .compound = false } },
        .{ .Move = .{ .dst = ir.Reg.from(3), .src = ir.Reg.from(2) } },
        .{ .ClassOf = .{ .dst = ir.Reg.from(4), .src = ir.Reg.from(3) } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(2) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    const want = [_]u32{
        @intFromEnum(Op.const_load), 1, 7,
        @intFromEnum(Op.add),        1, @intFromEnum(ir.BinOp.Add), 2, 1, 0,
        @intFromEnum(Op.move),       3, 2,
        @intFromEnum(Op.escape),     3,
        @intFromEnum(Op.jump),       2, 1002, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),        NO_SPAN, 0, 0,
    };
    try std.testing.expectEqualSlices(u32, &want, st.code);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 9, 12 }, st.idx_pc);

    const consts = [_]ir.Const{ .{ .Int = -42 }, .{ .String = "s" }, .{ .Long = 9 } };
    // Constant 7 is past this table: the op loads it by id.
    const st2 = buildOne(&blk, &consts, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromEnum(Op.const_load), st2.code[0]);
    var sconst = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(1), .value = ir.ConstId.from(1) } },
        .{ .Const = .{ .dst = ir.Reg.from(2), .value = ir.ConstId.from(2) } },
        .{ .Const = .{ .dst = ir.Reg.from(3), .value = ir.ConstId.from(1) } },
    };
    var sblk = blk;
    sblk.insts = &sconst;
    var ssites: Sites = .{};
    const st4 = buildOne(&sblk, &consts, 8, &ssites) orelse return error.TestUnexpectedResult;
    // Each string load site keeps a string of its own.
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.const_str),  1, 1, 0,
        @intFromEnum(Op.const_val),  2, 0,
        @intFromEnum(Op.const_str),  3, 1, 1,
        @intFromEnum(Op.jump),       2, 1002, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),        NO_SPAN, 0, 0,
    }, st4.code);
    try std.testing.expectEqual(@as(u32, 2), ssites.strings);
    // A scalar constant is a value the code carries.
    try std.testing.expectEqualSlices(runtime.Value, &.{.{ .Long = 9 }}, st4.values);
    var iblk = blk;
    var iconst = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(1), .value = ir.ConstId.from(0) } },
    };
    iblk.insts = &iconst;
    const st3 = buildOne(&iblk, &consts, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.const_int), 1, @as(u32, @bitCast(@as(i32, -42))),
        @intFromEnum(Op.jump),      2, 1002, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),       NO_SPAN, 0, 0,
    }, st3.code);
}

test "stream encoding: fused terminators" {
    var mv = [_]ir.Inst{
        .{ .Move = .{ .dst = ir.Reg.from(1), .src = ir.Reg.from(0) } },
    };
    const goto_blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &mv,
        .terminator = .{ .Goto = ir.BlockId.from(3) },
    };
    const gs = buildOne(&goto_blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.move), 1, 0,
        @intFromEnum(Op.jump), 3, 1003, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),  NO_SPAN, 0, 0,
    }, gs.code);

    var none = [_]ir.Inst{};
    const ret_blk: ir.Block = .{
        .id = ir.BlockId.from(1),
        .insts = &none,
        .terminator = .{ .Return = ir.Reg.from(5) },
    };
    const rs = buildOne(&ret_blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{ @intFromEnum(Op.ret), 1, 5, @intFromEnum(Op.end), NO_SPAN, 0, 0 }, rs.code);

    const br_blk: ir.Block = .{
        .id = ir.BlockId.from(2),
        .insts = &none,
        .terminator = .{ .Branch = .{ .cond = ir.Reg.from(2), .t = ir.BlockId.from(1), .f = ir.BlockId.from(4) } },
    };
    const bs = buildOne(&br_blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{ @intFromEnum(Op.br), 2, 1, 1001, 4, 1004, NO_SPAN, 0, 0, @intFromEnum(Op.end), NO_SPAN, 0, 0 }, bs.code);
}

test "stream encoding: adds, subtracts and compares are ops of their own, a compare with its order mask, an arm-only operator an escape" {
    var insts = [_]ir.Inst{
        .{ .BinOp = .{ .dst = ir.Reg.from(2), .op = .Sub, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(3), .op = .LessEq, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(4), .op = .Mul, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(5), .op = .IdentEq, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(7), .op = .StringConcat, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(6), .op = .NotEq, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0) } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(1),
        .insts = &insts,
        .terminator = .{ .Branch = .{ .cond = ir.Reg.from(6), .t = ir.BlockId.from(1), .f = ir.BlockId.from(2) } },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    const le = kindWord(.LessEq);
    const ne = kindWord(.NotEq);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ir.BinOp.LessEq)) | 0b011 << 8, le);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ir.BinOp.NotEq)) | 0b101 << 8, ne);
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.sub),    0, @intFromEnum(ir.BinOp.Sub),     2, 1, 0,
        @intFromEnum(Op.cmp),    1, le,                             3, 1, 0,
        @intFromEnum(Op.bin_mul), 2, @intFromEnum(ir.BinOp.Mul),    4, 1, 0,
        @intFromEnum(Op.bin_ident_eq), 3, @intFromEnum(ir.BinOp.IdentEq), 5, 1, 0,
        @intFromEnum(Op.escape), 4,
        @intFromEnum(Op.cmp_br), 5, ne,                             6, 1, 0, 1, 1001, 2, 1002, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),    NO_SPAN, 0, 0,
    }, st.code);
}

test "stream encoding: a static call is a call op carrying its init unit" {
    var calls = [_]ir.Inst{
        .{ .CallStatic = .{ .dst = ir.Reg.from(3), .func = ir.FuncId.from(9), .args = ir.Reg.from(1), .n_args = 2 } },
        .{ .CallStatic = .{ .dst = ir.Reg.from(4), .func = ir.FuncId.from(9), .args = ir.Reg.from(1), .n_args = 2, .init = 5 } },
        .{ .CallStatic = .{ .dst = ir.Reg.from(4), .func = ir.FuncId.from(9), .args = ir.Reg.from(7), .n_args = 2 } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &calls,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.call),   0, 9, 1, 2, 3, 0, ir.NO_UNIT,
        @intFromEnum(Op.call),   1, 9, 1, 2, 4, 1, 5,
        @intFromEnum(Op.escape), 2,
        @intFromEnum(Op.jump),   1, 1001, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),    NO_SPAN, 0, 0,
    }, st.code);
}

test "stream encoding: field slots and virtual calls are ops of their own" {
    var insts = [_]ir.Inst{
        .{ .GetFieldSlot = .{ .dst = ir.Reg.from(2), .obj = ir.Reg.from(1), .slot = 3 } },
        .{ .SetFieldSlot = .{ .obj = ir.Reg.from(1), .slot = 4, .value = ir.Reg.from(2) } },
        .{ .RCallVirtual = .{ .dst = ir.Reg.from(5), .slot = ir.MethodSlotId.from(7), .args = ir.Reg.from(1), .n_args = 2 } },
        .{ .CallInterface = .{ .dst = ir.Reg.from(6), .iface = ir.ClassId.from(0), .slot = ir.MethodSlotId.from(8), .args = ir.Reg.from(1), .n_args = 1 } },
        .{ .GetFieldSlot = .{ .dst = ir.Reg.from(9), .obj = ir.Reg.from(1), .slot = 3 } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.get_field), 0, 2, 1, 3,
        @intFromEnum(Op.set_field), 1, 1, 4, 2,
        @intFromEnum(Op.vcall),     2, 7, 1, 2, 5, 0,
        @intFromEnum(Op.vcall),     3, 8, 1, 1, 6, 1,
        @intFromEnum(Op.escape),    4,
        @intFromEnum(Op.jump),      1, 1001, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),       NO_SPAN, 0, 0,
    }, st.code);
}

test "stream encoding: a trace runs no op, the end op carries its block's last span, and an edge the span its target finds" {
    const sp = @import("span");
    const s1: ir.Span = .{ .file = sp.FileId.from(4), .start = 10, .end = 20 };
    const s2: ir.Span = .{ .file = sp.FileId.from(4), .start = 30, .end = 40 };
    var insts = [_]ir.Inst{
        .{ .Trace = .{ .span = s1 } },
        .{ .Move = .{ .dst = ir.Reg.from(1), .src = ir.Reg.from(0) } },
        .{ .Trace = .{ .span = s2 } },
        .{ .Move = .{ .dst = ir.Reg.from(2), .src = ir.Reg.from(1) } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    // Alone, the block's jump has no target that finds its span in the frame.
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.move), 1, 0,
        @intFromEnum(Op.move), 2, 1,
        @intFromEnum(Op.jump), 1, 1001, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),  4, 30, 40,
    }, st.code);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 3, 3 }, st.idx_pc);
    // b0 (s1) branches to b1 (s2) and b2, which b1 goes on to: b2 finds s1 or s2, so the
    // edges into it leave theirs, b0's on both its edges. b2's `end` has no span.
    var b0 = [_]ir.Inst{.{ .Trace = .{ .span = s1 } }};
    var b1 = [_]ir.Inst{.{ .Trace = .{ .span = s2 } }};
    const blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &b0, .terminator = .{ .Branch = .{ .cond = ir.Reg.from(0), .t = ir.BlockId.from(1), .f = ir.BlockId.from(2) } } },
        .{ .id = ir.BlockId.from(1), .insts = &b1, .terminator = .{ .Goto = ir.BlockId.from(2) } },
        .{ .id = ir.BlockId.from(2), .insts = &.{}, .terminator = .{ .Return = null } },
    };
    var sites: Sites = .{};
    const laid = buildBlocks(&blocks, 0, &.{}, 4, &sites) orelse return error.TestUnexpectedResult;
    const a = std.heap.smp_allocator;
    defer {
        for (laid.blocks) |b| a.free(b.idx_pc);
        a.free(laid.blocks);
        a.free(laid.code);
        a.free(laid.values);
        a.free(laid.effects);
        a.free(laid.entry_spans);
    }
    try std.testing.expectEqual(ir.spanmap.EntrySpan.dyn, laid.entry_spans[2]);
    const c = laid.code;
    const br = laid.blocks[0].start;
    try std.testing.expectEqual(@intFromEnum(Op.br), c[br]);
    try std.testing.expectEqualSlices(u32, &.{ 4, 10, 20 }, c[br + 6 .. br + 9]);
    const jmp = laid.blocks[1].start;
    try std.testing.expectEqual(@intFromEnum(Op.jump), c[jmp]);
    try std.testing.expectEqualSlices(u32, &.{ 4, 30, 40 }, c[jmp + 3 .. jmp + 6]);
    try std.testing.expectEqualSlices(u32, &.{ NO_SPAN, 0, 0 }, c[laid.blocks[2].end + 1 .. laid.blocks[2].end + 4]);
}

test "stream encoding: constructors, function values, host calls, Not and not-null assertions are ops of their own" {
    var insts = [_]ir.Inst{
        .{ .RNewInstance = .{ .dst = ir.Reg.from(4), .class = ir.ClassId.from(3), .ctor = ir.FuncId.from(11), .args = ir.Reg.from(1), .n_args = 2 } },
        .{ .RCallValue = .{ .dst = ir.Reg.from(5), .callee = ir.Reg.from(0), .args = ir.Reg.from(1), .n_args = 1 } },
        .{ .Not = .{ .dst = ir.Reg.from(6), .src = ir.Reg.from(2) } },
        .{ .CallNative = .{ .dst = ir.Reg.from(7), .native = ir.NativeId.from(40), .args = ir.Reg.from(1), .n_args = 2, .direct = true } },
        .{ .NotNullAssert = .{ .dst = ir.Reg.from(3), .src = ir.Reg.from(7) } },
        .{ .LateinitCheck = .{ .dst = ir.Reg.from(2), .src = ir.Reg.from(3), .name = ir.ConstId.from(0) } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    var sites: Sites = .{};
    const st = buildOne(&blk, &.{}, 8, &sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.new),    0, 3, 11, 1, 2, 4, 0,
        @intFromEnum(Op.callv),  1, 0, 1, 1, 5, 0,
        @intFromEnum(Op.not),    2, 6, 2,
        @intFromEnum(Op.native), 3, 40, 1, 2, 7, 1,
        @intFromEnum(Op.not_null), 4, 3, 7,
        @intFromEnum(Op.not_null), 5, 2, 3,
        @intFromEnum(Op.jump),   1, 1001, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),    NO_SPAN, 0, 0,
    }, st.code);
    try std.testing.expectEqual(@as(u32, 1), sites.calls);
}

test "stream encoding: a function's blocks share one code array, and an edge names its target's pc" {
    var mv = [_]ir.Inst{
        .{ .Move = .{ .dst = ir.Reg.from(1), .src = ir.Reg.from(0) } },
    };
    var none = [_]ir.Inst{};
    const blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &mv, .terminator = .{ .Goto = ir.BlockId.from(2) } },
        .{ .id = ir.BlockId.from(1), .insts = &none, .terminator = .{ .Return = ir.Reg.from(1) } },
        .{ .id = ir.BlockId.from(2), .insts = &none, .terminator = .{ .Branch = .{ .cond = ir.Reg.from(1), .t = ir.BlockId.from(1), .f = ir.BlockId.from(0) } } },
    };
    var sites: Sites = .{};
    const laid = buildBlocks(&blocks, 0, &.{}, 8, &sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.move), 1, 0,
        @intFromEnum(Op.jump), 2, 20, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),  NO_SPAN, 0, 0,
        @intFromEnum(Op.ret),  1, 1,
        @intFromEnum(Op.end),  NO_SPAN, 0, 0,
        @intFromEnum(Op.br),   1, 1, 13, 0, 0, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),  NO_SPAN, 0, 0,
    }, laid.code);
    try std.testing.expectEqual(@as(u32, 0), laid.blocks[0].start);
    try std.testing.expectEqual(@as(u32, 0), laid.blocks[0].enter);
    try std.testing.expectEqual(@as(u32, 9), laid.blocks[0].end);
    try std.testing.expectEqual(@as(u32, 13), laid.blocks[1].start);
    try std.testing.expectEqual(@as(u32, 16), laid.blocks[1].end);
    try std.testing.expectEqual(@as(u32, 20), laid.blocks[2].start);
    try std.testing.expectEqual(@as(u32, 29), laid.blocks[2].end);
    try std.testing.expectEqualSlices(u32, &.{0}, laid.blocks[0].idx_pc);

    // An edge to a block the function does not have builds nothing.
    const bad = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &none, .terminator = .{ .Goto = ir.BlockId.from(5) } },
    };
    try std.testing.expect(buildBlocks(&bad, 0, &.{}, 8, &sites) == null);
}

test "a body still being published has no streams until its flag clears" {
    var none = [_]ir.Inst{};
    var blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &none, .terminator = .{ .Return = ir.Reg.from(0) } },
    };
    var f: ir.Func = .{
        .id = ir.FuncId.from(0),
        .name = "published",
        .fqn = "published",
        .params = &.{},
        .return_ty = .{ .name = "", .nullable = true, .args = &.{} },
        .n_locals = 1,
        .blocks = &blocks,
        .deferred_offset = 1,
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
    };
    // `ensureFuncBody` writes the blocks before it clears the flag; a reader must not take
    // them before the flag says they are all there.
    try std.testing.expect(funcStreams(&f, &.{}) == null);
    @atomicStore(u32, &f.deferred_offset, 0, .release);
    const fs = funcStreams(&f, &.{}) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), fs.blocks.len);
}

test "stream encoding: captures, statics and class tests are ops of their own" {
    var insts = [_]ir.Inst{
        .{ .LoadCapture = .{ .dst = ir.Reg.from(1), .idx = 2 } },
        .{ .LoadStatic = .{ .dst = ir.Reg.from(2), .static = ir.StaticId.from(6) } },
        .{ .RInstanceOf = .{ .dst = ir.Reg.from(3), .src = ir.Reg.from(1), .class = ir.ClassId.from(4), .nullable = true } },
        .{ .RCast = .{ .dst = ir.Reg.from(4), .src = ir.Reg.from(1), .class = ir.ClassId.from(4), .nullable = false, .safe = true } },
        .{ .RCast = .{ .dst = ir.Reg.from(9), .src = ir.Reg.from(1), .class = ir.ClassId.from(4), .nullable = false, .safe = false } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.load_capture), 1, 2,
        @intFromEnum(Op.load_static),  1, 2, 6,
        @intFromEnum(Op.is),           2, 3, 1, 4, 1,
        @intFromEnum(Op.cast),         3, 4, 1, 4, 2,
        @intFromEnum(Op.escape),       4,
        @intFromEnum(Op.jump),         1, 1001, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),          NO_SPAN, 0, 0,
    }, st.code);
}

test "stream encoding: a function whose try frames are known pushes and pops none, and a finally's Gotos check for a pending flow" {
    var none = [_]ir.Inst{};
    var mv = [_]ir.Inst{
        .{ .Move = .{ .dst = ir.Reg.from(1), .src = ir.Reg.from(0) } },
    };
    var body_h: ir.BlockHandlers = .{ .finally = ir.BlockId.from(2), .finally_done = ir.BlockId.from(3) };
    var done_h: ir.BlockHandlers = .{ .finally_done_for = ir.BlockId.from(1) };
    const blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &none, .terminator = .{ .Goto = ir.BlockId.from(1) } },
        .{ .id = ir.BlockId.from(1), .insts = &mv, .terminator = .{ .Goto = ir.BlockId.from(2) }, .handlers = &body_h },
        .{ .id = ir.BlockId.from(2), .insts = &none, .terminator = .{ .Goto = ir.BlockId.from(3) } },
        .{ .id = ir.BlockId.from(3), .insts = &none, .terminator = .{ .Return = null }, .handlers = &done_h },
    };
    var sites: Sites = .{};
    const laid = buildBlocks(&blocks, 0, &.{}, 8, &sites) orelse return error.TestUnexpectedResult;
    try std.testing.expect(laid.try_ctx != null);
    try std.testing.expectEqualSlices(u32, &.{
        // b0: a plain Goto into the try body.
        @intFromEnum(Op.jump),        1, 10, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
        // b1: the try body pushes nothing; its Goto into the finally is plain, and leaves
        // the finally, which finds its span in the frame, none.
        @intFromEnum(Op.move),        1, 0,
        @intFromEnum(Op.jump),        2, 23, NULL_SPAN, 0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
        // b2: the finally's Goto checks for a flow it keys.
        @intFromEnum(Op.goto_try),    3, 33, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
        // b3: the done sentinel returns through any finally a flow left.
        @intFromEnum(Op.ret_try),     0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
    }, laid.code);
    // A return inside the region has the finally to run, which the frame loop finds.
    var ret_h: ir.BlockHandlers = .{ .finally = ir.BlockId.from(2), .finally_done = ir.BlockId.from(3) };
    const inside = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &none, .terminator = .{ .Goto = ir.BlockId.from(1) } },
        .{ .id = ir.BlockId.from(1), .insts = &mv, .terminator = .{ .Return = ir.Reg.from(1) }, .handlers = &ret_h },
        .{ .id = ir.BlockId.from(2), .insts = &none, .terminator = .{ .Goto = ir.BlockId.from(3) } },
        .{ .id = ir.BlockId.from(3), .insts = &none, .terminator = .{ .Return = null }, .handlers = &done_h },
    };
    const in_laid = buildBlocks(&inside, 0, &.{}, 8, &sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromEnum(Op.term_exit), in_laid.code[in_laid.blocks[1].start + 3]);
}

test "stream encoding: a function whose paths leave a block different try frames keeps its try stack: its try blocks start with block_entry" {
    var none = [_]ir.Inst{};
    var catches = [_]ir.CatchHandler{.{ .class = ir.ClassId.from(0), .handler = ir.BlockId.from(3), .exception_reg = ir.Reg.from(1) }};
    var body_h: ir.BlockHandlers = .{ .catches = &catches };
    // b1's region goes on to b2 without leaving it, and b0 goes around it to b2.
    const blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &none, .terminator = .{ .Branch = .{ .cond = ir.Reg.from(0), .t = ir.BlockId.from(1), .f = ir.BlockId.from(2) } } },
        .{ .id = ir.BlockId.from(1), .insts = &none, .terminator = .{ .Goto = ir.BlockId.from(2) }, .handlers = &body_h },
        .{ .id = ir.BlockId.from(2), .insts = &none, .terminator = .{ .Return = null } },
        .{ .id = ir.BlockId.from(3), .insts = &none, .terminator = .{ .Return = null } },
    };
    var sites: Sites = .{};
    const laid = buildBlocks(&blocks, 0, &.{}, 8, &sites) orelse return error.TestUnexpectedResult;
    try std.testing.expect(laid.try_ctx == null);
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.br),          0, 1, 13, 2, 24, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
        // b1: pushes its try frame at entry.
        @intFromEnum(Op.block_entry),
        @intFromEnum(Op.jump),        2, 24, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
        @intFromEnum(Op.ret_try),     0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
        @intFromEnum(Op.ret_try),     0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
    }, laid.code);
    try std.testing.expectEqual(@as(u32, 13), laid.blocks[1].enter);
    try std.testing.expectEqual(@as(u32, 14), laid.blocks[1].start);
}

test "stream encoding: cells, static stores, closures and arrays are ops of their own" {
    var caps = [_]ir.Reg{ir.Reg.from(1)};
    var insts = [_]ir.Inst{
        .{ .MakeCell = .{ .dst = ir.Reg.from(2), .src = ir.Reg.from(1) } },
        .{ .CellSet = .{ .cell = ir.Reg.from(2), .value = ir.Reg.from(3) } },
        .{ .StoreStatic = .{ .static = ir.StaticId.from(5), .value = ir.Reg.from(3) } },
        .{ .MakeClosure = .{ .dst = ir.Reg.from(4), .func = ir.FuncId.from(7), .captures = &caps } },
        .{ .NewArray = .{ .dst = ir.Reg.from(5), .class = ir.ClassId.from(2), .args = ir.Reg.from(1), .n_args = 2 } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.make_cell),    2, 1,
        @intFromEnum(Op.cell_set),     1, 2, 3,
        @intFromEnum(Op.store_static), 2, 5, 3,
        @intFromEnum(Op.make_closure), 3,
        @intFromEnum(Op.new_array),    4,
        @intFromEnum(Op.jump),         1, 1001, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),          NO_SPAN, 0, 0,
    }, st.code);
}

test "stream encoding: a block of escapes has a stream of its own" {
    var mc = [_]ir.Inst{
        .{ .ClassOf = .{ .dst = ir.Reg.from(1), .src = ir.Reg.from(0) } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &mc,
        .terminator = .{ .Goto = ir.BlockId.from(0) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.escape), 0,
        @intFromEnum(Op.jump),   0, 1000, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),    NO_SPAN, 0, 0,
    }, st.code);
}

/// Human-readable decode of block `b`'s ops.
pub fn dumpBlock(w: anytype, fs: *const FuncStreams, b: usize) !void {
    var pc: usize = fs.blocks[b].enter;
    const code = fs.code;
    while (pc <= fs.blocks[b].end) {
        const op = fs.opAt(pc);
        switch (op) {
            .jit => unreachable,
            .const_load => {
                try w.print("  {d:>4}: const_load r{d} <- const#{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .const_val => {
                try w.print("  {d:>4}: const_val  r{d} <- value{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .un, .un_inc, .un_dec, .un_neg, .conv_byte, .conv_short, .conv_int, .conv_long, .conv_float, .conv_double, .conv_char, .fn_inv, .fn_to_raw_bits, .fn_to_bits, .fn_float_from_bits, .fn_double_from_bits, .fn_count_trailing_zero_bits, .fn_uint_to_float, .fn_uint_to_double, .fn_ulong_to_float, .fn_ulong_to_double, .fn_sin, .fn_cos, .fn_sqrt, .fn_to_ulong, .fn_to_uint, .fn_to_ushort, .fn_to_ubyte, .fn_unsigned_bits => |o| {
                try w.print("  {d:>4}: {s:<10} r{d} <- op{d} r{d}\n", .{ pc, @tagName(o), code[pc + 3], code[pc + 2], code[pc + 4] });
                pc += 5;
            },
            .const_int => {
                try w.print("  {d:>4}: const_int  r{d} <- {d}\n", .{ pc, code[pc + 1], @as(i32, @bitCast(code[pc + 2])) });
                pc += 3;
            },
            .move => {
                try w.print("  {d:>4}: move       r{d} <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .load_param => {
                try w.print("  {d:>4}: load_param r{d} <- p{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .load_params => {
                const n = code[pc + 1];
                try w.print("  {d:>4}: load_params", .{pc});
                for (0..n) |k| try w.print(" r{d} <- p{d}", .{ code[pc + 2 + 2 * k], code[pc + 3 + 2 * k] });
                try w.print("\n", .{});
                pc += 2 + 2 * n;
            },
            .cell_get => {
                try w.print("  {d:>4}: cell_get   r{d} <- cell r{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .bin, .add, .sub, .cmp, .bin_mul, .bin_div, .bin_mod, .bin_and, .bin_or, .bin_xor, .bin_shl, .bin_shr, .bin_ushr, .bin_ident_eq, .bin_ident_neq => |o| {
                try w.print("  {d:>4}: {s:<10} i{d} kind={d} r{d} <- r{d} op r{d}\n", .{ pc, @tagName(o), code[pc + 1], code[pc + 2] & 0xff, code[pc + 3], code[pc + 4], code[pc + 5] });
                pc += 6;
            },
            .escape => {
                try w.print("  {d:>4}: escape     i{d}\n", .{ pc, code[pc + 1] });
                pc += 2;
            },
            .jump, .goto_try => |o| {
                try w.print("  {d:>4}: {s:<10} b{d} @{d}\n", .{ pc, @tagName(o), code[pc + 1], code[pc + 2] });
                pc += 6;
            },
            .br => {
                try w.print("  {d:>4}: br         r{d} ? b{d} @{d} : b{d} @{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5] });
                pc += 9;
            },
            .ret, .ret_try => |o| {
                try w.print("  {d:>4}: {s:<10} has_val={d} r{d}\n", .{ pc, @tagName(o), code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .term_exit => {
                try w.print("  {d:>4}: term_exit\n", .{pc});
                pc += 4;
            },
            .cmp_br => {
                try w.print("  {d:>4}: cmp_br     i{d} kind={d} r{d} <- r{d} op r{d} ? b{d} @{d} : b{d} @{d}\n", .{ pc, code[pc + 1], code[pc + 2] & 0xff, code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6], code[pc + 7], code[pc + 8], code[pc + 9] });
                pc += 13;
            },
            .call => {
                try w.print("  {d:>4}: call       i{d} f{d} r{d}..+{d} -> r{d} site{d} init{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6], code[pc + 7] });
                pc += 8;
            },
            .end => {
                try w.print("  {d:>4}: end\n", .{pc});
                pc += 4;
            },
            .block_entry => {
                try w.print("  {d:>4}: block_entry\n", .{pc});
                pc += 1;
            },
            .bin_k_add,
            .bin_k_sub,
            .bin_k_mul,
            .bin_k_div,
            .bin_k_mod,
            .bin_k_less,
            .bin_k_less_eq,
            .bin_k_greater,
            .bin_k_greater_eq,
            .bin_k_eq,
            .bin_k_not_eq,
            .bin_k_boxed_eq,
            .bin_k_boxed_not_eq,
            .bin_k_and,
            .bin_k_or,
            .bin_k_xor,
            .bin_k_shl,
            .bin_k_shr,
            .bin_k_ushr,
            .bin_k_ident_eq,
            .bin_k_ident_neq,
            .cmp_br_k_less,
            .cmp_br_k_less_eq,
            .cmp_br_k_greater,
            .cmp_br_k_greater_eq,
            .cmp_br_k_eq,
            .cmp_br_k_not_eq,
            .cmp_br_k_boxed_eq,
            .cmp_br_k_boxed_not_eq,
            .cmp_br_k_ident_eq,
            .cmp_br_k_ident_neq => |o| {
                try w.print("  {d:>4}: {s:<10} kind={d} r{d} k={s}:{x} (r{d})\n", .{ pc, @tagName(o), code[pc + 1] & 0xff, code[pc + 2], @tagName(@as(KType, @enumFromInt((code[pc + 1] >> 8) & 0xff))), @as(u64, code[pc + 5]) << 32 | code[pc + 4], code[pc + 3] });
                pc += 6;
            },
            .get_field => {
                try w.print("  {d:>4}: get_field  i{d} r{d} <- r{d}.#{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4] });
                pc += 5;
            },
            .set_field => {
                try w.print("  {d:>4}: set_field  i{d} r{d}.#{d} <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4] });
                pc += 5;
            },
            .vcall => {
                try w.print("  {d:>4}: vcall      i{d} slot{d} r{d}..+{d} -> r{d} site{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6] });
                pc += 7;
            },
            .new => {
                try w.print("  {d:>4}: new        i{d} class{d} ctor f{d} r{d}..+{d} -> r{d} site{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6], code[pc + 7] });
                pc += 8;
            },
            .callv => {
                try w.print("  {d:>4}: callv      i{d} r{d}(r{d}..+{d}) -> r{d} site{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6] });
                pc += 7;
            },
            .not => {
                try w.print("  {d:>4}: not        i{d} r{d} <- !r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .not_null => {
                try w.print("  {d:>4}: not_null   i{d} r{d} <- r{d}!!\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .const_str => {
                try w.print("  {d:>4}: const_str  r{d} <- const#{d} string{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .make_cell => {
                try w.print("  {d:>4}: make_cell  r{d} <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .cell_set => {
                try w.print("  {d:>4}: cell_set   i{d} *r{d} <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .store_static => {
                try w.print("  {d:>4}: store_static i{d} static{d} <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .make_closure, .new_array => |o| {
                try w.print("  {d:>4}: {s:<10} i{d}\n", .{ pc, @tagName(o), code[pc + 1] });
                pc += 2;
            },
            .load_capture => {
                try w.print("  {d:>4}: load_capture r{d} <- c{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .load_static => {
                try w.print("  {d:>4}: load_static i{d} r{d} <- static{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .is, .cast => |o| {
                try w.print("  {d:>4}: {s:<10} i{d} r{d} <- r{d} class{d} flags={d}\n", .{ pc, @tagName(o), code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5] });
                pc += 6;
            },
            .box_value, .unbox_value => |o| {
                try w.print("  {d:>4}: {s:<10} i{d} r{d} <- r{d} class{d} slot{d}\n", .{ pc, @tagName(o), code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5] });
                pc += 6;
            },
            .native => {
                try w.print("  {d:>4}: native     i{d} n{d} r{d}..+{d} -> r{d} direct={d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6] });
                pc += 7;
            },
            .array_get => {
                try w.print("  {d:>4}: array_get  i{d} r{d} <- r{d}[r{d}]\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4] });
                pc += 5;
            },
            .array_set => {
                try w.print("  {d:>4}: array_set  i{d} r{d}[r{d}] <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4] });
                pc += 5;
            },
            .load_object => {
                try w.print("  {d:>4}: load_object i{d} r{d} <- class{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .iter_open => {
                try w.print("  {d:>4}: iter_open  i{d} r{d} <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .iter_has, .iter_get => |o| {
                try w.print("  {d:>4}: {s:<10} i{d} r{d} <- r{d}[r{d}] stamp r{d}\n", .{ pc, @tagName(o), code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5] });
                pc += 6;
            },
        }
    }
}

test "a body that only reads a field of its receiver, or only stores its parameters, is a leaf" {
    const a = std.testing.allocator;
    const r = ir.Reg.from;
    var getter = [_]ir.Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .GetFieldSlot = .{ .dst = r(1), .obj = r(0), .slot = 3 } },
    };
    var blk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &getter, .terminator = .{ .Return = r(1) } };
    try std.testing.expectEqual(Leaf{ .get_field = 3 }, leafOfBlocks(a, (&blk)[0..1]));
    // A field of another parameter, or a result other than the field read, is not.
    getter[0].LoadParam.idx = 1;
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&blk)[0..1]));
    getter[0].LoadParam.idx = 0;
    blk.terminator = .{ .Return = r(0) };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&blk)[0..1]));

    var ctor = [_]ir.Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .LoadParam = .{ .dst = r(1), .idx = 1 } },
        .{ .LoadParam = .{ .dst = r(2), .idx = 2 } },
        .{ .SetFieldSlot = .{ .obj = r(0), .slot = 1, .value = r(2) } },
        .{ .SetFieldSlot = .{ .obj = r(0), .slot = 0, .value = r(1) } },
    };
    var cblk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &ctor, .terminator = .{ .Return = r(0) } };
    const leaf = leafOfBlocks(a, (&cblk)[0..1]);
    defer if (leaf == .set_fields) a.free(leaf.set_fields.stores);
    try std.testing.expectEqualSlices(FieldStore, &.{ .{ .slot = 1, .param = 2 }, .{ .slot = 0, .param = 1 } }, leaf.set_fields.stores);
    try std.testing.expectEqual(NO_OBJECT, leaf.set_fields.object);
    // Storing the receiver itself, into another object, or returning nothing is not.
    ctor[4].SetFieldSlot.value = r(0);
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&cblk)[0..1]));
    ctor[4].SetFieldSlot.value = r(1);
    ctor[3].SetFieldSlot.obj = r(1);
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&cblk)[0..1]));
    ctor[3].SetFieldSlot.obj = r(0);
    cblk.terminator = .{ .Return = null };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&cblk)[0..1]));
    // Any other instruction, or a second block, makes a frame necessary.
    var other = [_]ir.Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .Const = .{ .dst = r(1), .value = ir.ConstId.from(0) } },
    };
    const oblk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &other, .terminator = .{ .Return = r(1) } };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&oblk)[0..1]));
    const two = [_]ir.Block{ blk, blk };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, &two));
}

test "a constructor that stores nothing, or first passes its parameters to its superclass's, is a leaf" {
    const a = std.testing.allocator;
    const r = ir.Reg.from;
    var empty = [_]ir.Inst{.{ .LoadParam = .{ .dst = r(0), .idx = 0 } }};
    const eblk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &empty, .terminator = .{ .Return = r(0) } };
    const e = leafOfBlocks(a, (&eblk)[0..1]);
    defer freeLeaf(a, e);
    try std.testing.expectEqual(@as(usize, 0), e.set_fields.stores.len);
    try std.testing.expect(e.set_fields.super == null);

    // `class Sub(x: Int, val y: Int) : Base(x)`, its companion's load first.
    var sub = [_]ir.Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .LoadObject = .{ .dst = r(1), .class = ir.ClassId.from(4) } },
        .{ .LoadParam = .{ .dst = r(2), .idx = 1 } },
        .{ .LoadParam = .{ .dst = r(4), .idx = 0 } },
        .{ .Move = .{ .dst = r(5), .src = r(2) } },
        .{ .CallStatic = .{ .dst = r(6), .func = ir.FuncId.from(9), .args = r(4), .n_args = 2 } },
        .{ .LoadParam = .{ .dst = r(7), .idx = 2 } },
        .{ .SetFieldSlot = .{ .obj = r(0), .slot = 1, .value = r(7) } },
    };
    var sblk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &sub, .terminator = .{ .Return = r(0) } };
    const l = leafOfBlocks(a, (&sblk)[0..1]);
    defer freeLeaf(a, l);
    try std.testing.expectEqual(@as(u32, 4), l.set_fields.object);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1 }, l.set_fields.super.?.args);
    try std.testing.expectEqualSlices(FieldStore, &.{.{ .slot = 1, .param = 2 }}, l.set_fields.stores);
    // The call's result read, a receiver other than parameter 0, an argument no parameter
    // holds, a store before the call, or a class to initialize at the call needs a frame.
    sub[7].SetFieldSlot.value = r(6);
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&sblk)[0..1]));
    sub[7].SetFieldSlot.value = r(7);
    sub[3].LoadParam.idx = 2;
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&sblk)[0..1]));
    sub[3].LoadParam.idx = 0;
    sub[4].Move.src = r(1);
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&sblk)[0..1]));
    sub[4].Move.src = r(2);
    var early = [_]ir.Inst{ sub[0], sub[6], sub[7], sub[2], sub[3], sub[4], sub[5] };
    const early_blk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &early, .terminator = .{ .Return = r(0) } };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&early_blk)[0..1]));
    sub[5].CallStatic.init = 3;
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&sblk)[0..1]));
    sub[5].CallStatic.init = ir.NO_UNIT;
    // A body whose call the encoder left to the instruction's arm has no site to find it at.
    var func: ir.Func = undefined;
    func.entry = ir.BlockId.from(0);
    func.blocks = (&sblk)[0..1];
    try std.testing.expectEqual(Leaf.none, leafOf(a, &func, 0));
    const ok = leafOf(a, &func, 1);
    defer freeLeaf(a, ok);
    try std.testing.expectEqual(@as(u32, 0), ok.set_fields.super.?.site);
}

test "a constructor that loads its companion before storing its parameters is a leaf that names it" {
    const a = std.testing.allocator;
    const r = ir.Reg.from;
    var ctor = [_]ir.Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .LoadObject = .{ .dst = r(1), .class = ir.ClassId.from(7) } },
        .{ .LoadParam = .{ .dst = r(2), .idx = 1 } },
        .{ .SetFieldSlot = .{ .obj = r(0), .slot = 0, .value = r(2) } },
    };
    var blk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &ctor, .terminator = .{ .Return = r(0) } };
    const leaf = leafOfBlocks(a, (&blk)[0..1]);
    defer if (leaf == .set_fields) a.free(leaf.set_fields.stores);
    try std.testing.expectEqual(@as(u32, 7), leaf.set_fields.object);
    try std.testing.expectEqualSlices(FieldStore, &.{.{ .slot = 0, .param = 1 }}, leaf.set_fields.stores);
    // The object's value stored needs a frame.
    ctor[3].SetFieldSlot.value = r(1);
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&blk)[0..1]));
    ctor[3].SetFieldSlot.value = r(2);
    // So does a load over the receiver, or over a parameter the stores read.
    ctor[1].LoadObject.dst = r(0);
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&blk)[0..1]));
    ctor[1].LoadObject.dst = r(1);
    var over = [_]ir.Inst{ ctor[0], ctor[2], ctor[1], ctor[3] };
    over[2].LoadObject.dst = r(2);
    const oblk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &over, .terminator = .{ .Return = r(0) } };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&oblk)[0..1]));
    // And a second object.
    var twice = [_]ir.Inst{ ctor[0], ctor[1], ctor[1], ctor[2], ctor[3] };
    const tblk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &twice, .terminator = .{ .Return = r(0) } };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&tblk)[0..1]));
    // A getter never loads one.
    var getter = [_]ir.Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .LoadObject = .{ .dst = r(1), .class = ir.ClassId.from(7) } },
        .{ .GetFieldSlot = .{ .dst = r(2), .obj = r(0), .slot = 0 } },
    };
    const gblk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &getter, .terminator = .{ .Return = r(2) } };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&gblk)[0..1]));
}

test "stream encoding: the entry block's parameters load in one op a call steps over" {
    var entry = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(2), .value = ir.ConstId.from(0) } },
        .{ .LoadParam = .{ .dst = ir.Reg.from(0), .idx = 0 } },
        .{ .LoadParam = .{ .dst = ir.Reg.from(1), .idx = 1 } },
    };
    var tail = [_]ir.Inst{
        .{ .LoadParam = .{ .dst = ir.Reg.from(3), .idx = 0 } },
    };
    const blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &entry, .terminator = .{ .Goto = ir.BlockId.from(1) } },
        .{ .id = ir.BlockId.from(1), .insts = &tail, .terminator = .{ .Return = ir.Reg.from(0) } },
    };
    var sites: Sites = .{};
    const consts = [_]ir.Const{.{ .Int = 7 }};
    const laid = buildBlocks(&blocks, 0, &consts, 8, &sites) orelse return error.TestUnexpectedResult;
    const a = std.heap.smp_allocator;
    defer {
        for (laid.blocks) |b| a.free(b.idx_pc);
        a.free(laid.blocks);
        a.free(laid.code);
        a.free(laid.values);
        a.free(laid.param_map);
        a.free(laid.effects);
    }
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1 }, laid.param_map);
    const e0 = laid.blocks[0].enter;
    try std.testing.expectEqualSlices(u32, &.{ @intFromEnum(Op.load_params), 2, 0, 0, 1, 1, @intFromEnum(Op.const_int), 2, 7 }, laid.code[e0 .. e0 + 9]);
    try std.testing.expectEqual(e0 + 6, laid.body_pc);
    // A later block's load keeps its own op.
    try std.testing.expectEqual(@intFromEnum(Op.load_param), laid.code[laid.blocks[1].start]);
    // The frame map reads the two loads as run before the entry block's first instruction.
    try std.testing.expectEqualSlices(ir.framemap.Effect, &.{ .{ .at = 1, .kind = .hoisted }, .{ .at = 2, .kind = .hoisted } }, laid.effects);
}


test "stream encoding: a constant only one operation reads rides in that operation's op" {
    var entry = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(1), .value = ir.ConstId.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(2), .op = .And, .lhs = ir.Reg.from(0), .rhs = ir.Reg.from(1), .compound = false } },
        .{ .Const = .{ .dst = ir.Reg.from(3), .value = ir.ConstId.from(1) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(4), .op = .Less, .lhs = ir.Reg.from(3), .rhs = ir.Reg.from(2), .compound = false } },
    };
    var tail = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(5), .value = ir.ConstId.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(6), .op = .Add, .lhs = ir.Reg.from(5), .rhs = ir.Reg.from(5), .compound = false } },
        .{ .Const = .{ .dst = ir.Reg.from(7), .value = ir.ConstId.from(2) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(8), .op = .Sub, .lhs = ir.Reg.from(7), .rhs = ir.Reg.from(0), .compound = false } },
        .{ .Const = .{ .dst = ir.Reg.from(9), .value = ir.ConstId.from(3) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(10), .op = .Mul, .lhs = ir.Reg.from(0), .rhs = ir.Reg.from(9), .compound = false } },
    };
    const blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &entry, .terminator = .{ .Branch = .{ .cond = ir.Reg.from(4), .t = ir.BlockId.from(1), .f = ir.BlockId.from(1) } } },
        .{ .id = ir.BlockId.from(1), .insts = &tail, .terminator = .{ .Return = ir.Reg.from(6) } },
    };
    var sites: Sites = .{};
    const consts = [_]ir.Const{ .{ .Int = 0xff }, .{ .Int = 5 }, .{ .Long = -2 }, .{ .Float = std.math.nan(f32) } };
    const laid = buildBlocks(&blocks, 0, &consts, 12, &sites) orelse return error.TestUnexpectedResult;
    const and_kw = @intFromEnum(ir.BinOp.And);
    // `5 < r2` is computed as `r2 > 5`; the op behind the prefix is the BinOp as written.
    const gt_kw = @intFromEnum(ir.BinOp.Greater) | orderMask(.Greater) << 16;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.bin_k_and),    and_kw,             0, 1, 0xff, 0,
        @intFromEnum(Op.bin_and),  1,                  kindWord(.And), 2, 0, 1,
        @intFromEnum(Op.cmp_br_k_greater), gt_kw,              2, 3, 5,    0,
        @intFromEnum(Op.cmp_br),   3,                  kindWord(.Less), 4, 3, 2,
    }, laid.code[0..24]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 12, 12 }, laid.blocks[0].idx_pc);
    // The frame map reads each folded constant as doing nothing, and its op as reading no
    // register for it.
    try std.testing.expectEqualSlices(ir.framemap.Effect, &.{
        .{ .at = 0, .kind = .skipped },
        .{ .at = 1, .kind = .unread, .reg = 1 },
        .{ .at = 2, .kind = .skipped },
        .{ .at = 3, .kind = .unread, .reg = 3 },
    }, laid.effects);
    // A constant read twice, one on the left of an operator with no mirror, and a NaN keep their loads.
    const t = laid.blocks[1].start;
    try std.testing.expectEqualSlices(u32, &.{ @intFromEnum(Op.const_int), 5, 0xff }, laid.code[t .. t + 3]);
    try std.testing.expectEqual(@intFromEnum(Op.const_val), laid.code[t + 9]);
    try std.testing.expectEqual(@intFromEnum(Op.const_val), laid.code[t + 18]);
}

test "a constant rides in the operation that reads it when its register is written again, and dead after" {
    const r = ir.Reg.from;
    const k = ir.ConstId.from;
    // r1 carries two constants, each read by the next operation only; r5 is read again after
    // its operation, r6 in the next block, and r7 by the catch.
    var entry = [_]ir.Inst{
        .{ .Const = .{ .dst = r(1), .value = k(0) } },
        .{ .BinOp = .{ .dst = r(2), .op = .And, .lhs = r(0), .rhs = r(1) } },
        .{ .Const = .{ .dst = r(1), .value = k(1) } },
        .{ .BinOp = .{ .dst = r(3), .op = .Add, .lhs = r(2), .rhs = r(1) } },
        .{ .Const = .{ .dst = r(5), .value = k(1) } },
        .{ .BinOp = .{ .dst = r(4), .op = .Add, .lhs = r(3), .rhs = r(5) } },
        .{ .BinOp = .{ .dst = r(4), .op = .Add, .lhs = r(4), .rhs = r(5) } },
        .{ .Const = .{ .dst = r(6), .value = k(1) } },
        .{ .BinOp = .{ .dst = r(4), .op = .Add, .lhs = r(4), .rhs = r(6) } },
        .{ .Const = .{ .dst = r(7), .value = k(1) } },
        .{ .BinOp = .{ .dst = r(4), .op = .Add, .lhs = r(4), .rhs = r(7) } },
    };
    var next = [_]ir.Inst{.{ .BinOp = .{ .dst = r(8), .op = .Add, .lhs = r(4), .rhs = r(6) } }};
    var handler = [_]ir.Inst{.{ .Move = .{ .dst = r(8), .src = r(7) } }};
    var catches = [_]ir.CatchHandler{.{ .class = ir.ClassId.from(0), .handler = ir.BlockId.from(2), .exception_reg = r(9) }};
    var hs: ir.BlockHandlers = .{ .catches = &catches };
    const blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &entry, .terminator = .{ .Goto = ir.BlockId.from(1) }, .handlers = &hs },
        .{ .id = ir.BlockId.from(1), .insts = &next, .terminator = .{ .Return = r(8) } },
        .{ .id = ir.BlockId.from(2), .insts = &handler, .terminator = .{ .Return = r(8) } },
    };
    const consts = [_]ir.Const{ .{ .Int = 0xff }, .{ .Int = 5 } };
    const a = std.testing.allocator;
    const folds = constFolds(a, &blocks, &consts, 10) orelse return error.TestUnexpectedResult;
    defer folds.deinit(a);
    const folded = [_]bool{ false, true, false, true, false, false, false, false, false, false, false };
    for (folded, 0..) |f, i| try std.testing.expectEqual(f, folds.fold[i] != null);
    for (folded, 0..) |f, i| if (f) try std.testing.expect(folds.skip[i - 1]);
    try std.testing.expect(!folds.skip[4] and !folds.skip[7] and !folds.skip[9]);
}

test "a parameter's load runs first when nothing before it touches its register, which is written again after" {
    const r = ir.Reg.from;
    var entry = [_]ir.Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .BinOp = .{ .dst = r(1), .op = .Add, .lhs = r(0), .rhs = r(0) } },
        .{ .LoadParam = .{ .dst = r(0), .idx = 1 } },
        .{ .BinOp = .{ .dst = r(1), .op = .Add, .lhs = r(1), .rhs = r(0) } },
        .{ .Move = .{ .dst = r(0), .src = r(1) } },
    };
    var blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &entry, .terminator = .{ .Return = r(0) } },
    };
    const a = std.testing.allocator;
    {
        const h = entryHoist(a, &blocks, 0, 2) orelse return error.TestUnexpectedResult;
        defer a.free(h.pairs);
        defer a.free(h.skip);
        // The second load's register was the first's: it stays in place.
        try std.testing.expectEqualSlices(u32, &.{ 0, 0 }, h.pairs);
        try std.testing.expectEqualSlices(bool, &.{ true, false, false, false, false }, h.skip);
    }
    // An entry block a jump comes back to runs its loads each time.
    blocks[0].terminator = .{ .Branch = .{ .cond = r(1), .t = ir.BlockId.from(0), .f = ir.BlockId.from(0) } };
    const h = entryHoist(a, &blocks, 0, 2) orelse return error.TestUnexpectedResult;
    defer a.free(h.pairs);
    defer a.free(h.skip);
    try std.testing.expectEqual(@as(usize, 0), h.pairs.len);
}

test "stream encoding: a test against a null constant rides in its op, fused with its branch" {
    var insts = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(1), .value = ir.ConstId.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(2), .op = .IdentNeq, .lhs = ir.Reg.from(0), .rhs = ir.Reg.from(1), .compound = false } },
    };
    const blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &insts, .terminator = .{ .Branch = .{ .cond = ir.Reg.from(2), .t = ir.BlockId.from(0), .f = ir.BlockId.from(0) } } },
    };
    var sites: Sites = .{};
    const consts = [_]ir.Const{.Null};
    const laid = buildBlocks(&blocks, 0, &consts, 4, &sites) orelse return error.TestUnexpectedResult;
    const kw = @intFromEnum(ir.BinOp.IdentNeq) | @as(u32, @intFromEnum(KType.null)) << 8;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.cmp_br_k_ident_neq), kw, 0, 1, 0, 0,
        @intFromEnum(Op.cmp_br), 1, kindWord(.IdentNeq), 2, 0, 1,
    }, laid.code[0..12]);
}
