//! Stage-3 JIT: compile a hot natural loop to native x86-64 machine code.
//!
//! Additive tier over the IR interpreter (see plans/JIT-DESIGN.md). The loop's
//! IR registers live as i64 slots in a scratch file; the emitted code uses
//! rax/rcx/rdx/rsi scratch per op (no register allocator) and runs the loop
//! natively, eliminating Value boxing, member dispatch, and per-instruction
//! interpreter overhead. Packed primitive arrays are indexed directly out of
//! their scalar buffer (the F5 representation), with a bounds-check that deopts
//! to the interpreter at the faulting instruction on out-of-range access.
//!
//! Gated behind `KLIO_JIT` and entered only when the live-in registers' runtime
//! types (and indexed-array kinds) match the compiled specialization; otherwise
//! the interpreter runs the loop unchanged. So the build stays correct with the
//! JIT off (default) or on.

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
const FuncId = ir.FuncId;
const Allocator = std.mem.Allocator;
const E = jit.Reg;

// --- instance field memory layout (for native field access) ------------------
// An instance's fields are a contiguous `[]Field` (name + Value); a scalar field
// is read/written directly out of the boxed receiver's field buffer. The Value's
// scalar payload sits at offset 0; its 1-byte tag at `value_tag_offset`. These are
// computed from the real types so the codegen tracks any layout change.
const FIELD_STRIDE: u32 = @sizeOf(runtime.InstanceData.Field);
const FIELD_VALUE_OFF: u32 = @offsetOf(runtime.InstanceData.Field, "value");

fn valuePayloadOffset() u32 {
    var v: Value = .{ .Long = 0 };
    return @intCast(@intFromPtr(&v.Long) - @intFromPtr(&v));
}
fn valueTagOffset() u32 {
    // A zeroed Value with a distinctive tag: the only byte equal to that tag value
    // (outside the cleared payload area) is the tag.
    var v: Value = undefined;
    @memset(std.mem.asBytes(&v), 0);
    v = .{ .Char = 0 };
    const tagv: u8 = @intFromEnum(@as(std.meta.Tag(Value), .Char));
    const bytes = std.mem.asBytes(&v);
    var off: usize = @sizeOf(u64);
    while (off < bytes.len) : (off += 1) {
        if (bytes[off] == tagv) return @intCast(off);
    }
    return 0;
}

// Native register assignment. `REGS` (callee-saved) holds the slot-file base
// pointer; `T0`-`T3` are per-instruction scratch.
const REGS: E = .rbx;
const T0: E = .rax; // index / lhs / result
const T1: E = .rcx; // rhs / len / ptr
const T2: E = .rdx; // array element scratch
// SSE scratch for `f64` arithmetic. A double IR register keeps its bit pattern
// in its i64 slot and is moved in/out with `movsd`.
const X0: jit.Xmm = .xmm0;
const X1: jit.Xmm = .xmm1;

/// Static type of an IR register, for normalization and reboxing. `object` marks
/// a register that holds a full `Value` reference (an instance, null, or other
/// boxed object): it lives in the frame's register array (a GC root), never in a
/// scalar slot, and is read/written only by host callbacks — so the native loop
/// can drive object field navigation and null tests without putting a reference
/// in an untracked slot.
pub const RegType = enum(u8) { i32, i64, f64, f32, boolean, unit, null_, object, unknown };

/// The native loop returns `(block_id << 32) | inst_index` — the interpreter
/// resume point. A normal loop exit resumes at the target block's first
/// instruction (inst 0); a guard-failure deopt resumes at the exact faulting
/// instruction so the interpreter re-runs it (and throws) without re-executing
/// earlier side effects.
fn encodeResume(blk: BlockId, inst: u32) u64 {
    return (@as(u64, blk.int()) << 32) | inst;
}
/// Public resume encoder for the host call trampoline (a deopt that re-executes
/// the call in the interpreter — used when the callee yields a non-throw error
/// or a non-scalar result the slot cannot hold).
pub fn encodeResumePub(blk: BlockId, inst: u32) u64 {
    return encodeResume(blk, inst);
}
/// Sentinel inst index marking "the trampolined call threw"; the host stashed
/// the exception in its loop ctx and the interpreter must re-raise it at the
/// call's block (via `resume_throw`) rather than re-execute the call.
pub const THROW_INST: u32 = 0xffff_ffff;
pub fn throwCode(blk: BlockId) u64 {
    return encodeResume(blk, THROW_INST);
}
/// Sentinel inst index marking "deopt and re-execute at the stashed instruction"
/// — used by a field read whose value is no longer the cached scalar (e.g. a
/// nullable field became null). Always non-zero, so the native call site's
/// "non-zero return = exit the loop" test never mistakes it for "continue".
pub const DEOPT_INST: u32 = 0xffff_fffe;
pub fn deoptCode(blk: BlockId) u64 {
    return encodeResume(blk, DEOPT_INST);
}
/// Sentinel inst index marking "the compiled function returned" (function-JIT
/// mode only): the scalar return value is in the compiled loop's `result_slot`.
/// Always non-zero, so it is never mistaken for "continue native".
pub const RETURN_INST: u32 = 0xffff_fffd;
pub fn returnCode() u64 {
    return encodeResume(BlockId.from(0), RETURN_INST);
}

/// Runtime context the JIT'd loop hands its trampoline: the live slot file, the
/// compiled loop (for per-site descriptors + reg types), and the host's opaque
/// loop ctx. Its address sits in a reserved slot the native call site loads.
pub const TrampCtx = extern struct {
    slots: [*]i64,
    compiled: *const CompiledLoop,
    user: *anyopaque,
    /// Runtime value-kind tag per `.i32` register (see `CompiledLoop.box_tags`).
    /// Seeded from `box_tags` + the live entry values; a trampolined call's
    /// result write refreshes its dst's tag, so an intrinsic member whose
    /// return kind is unknowable statically (`toChar` on `Int`) still reboxes
    /// with the kind it actually produced.
    tags: [*]u8,
};
/// `fn(trampctx, call_site_index) -> 0 to continue native, else a resume code`.
pub const TrampFn = *const fn (*anyopaque, u64) callconv(.c) u64;

/// One trampolined call site in a compiled loop. Arg/result types come from the
/// loop's `reg_types` (a slot index == its reg index).
pub const CallSite = struct {
    func: FuncId = @enumFromInt(0),
    args_reg: u32 = 0,
    n_args: u32 = 0,
    dst_reg: u32,
    has_result: bool = false,
    block: BlockId,
    inst: u32,
    /// Source span of the call (from the nearest preceding `.Trace`), so the
    /// trampoline can refresh the calling frame's position before dispatch — the
    /// native loop does not execute `.Trace`, so the frame's span is otherwise
    /// stale when a trampolined call throws.
    span: ?ir.Span = null,
    /// The register whose LIVE tag governs each argument's rebox. The native
    /// code copies argument SLOTS through `Move`s without touching the tag
    /// array, so a trampolined callee's refreshed result tag must be read
    /// through the move chain's SOURCE — `action(index++, item)` otherwise
    /// reboxed `item` (a Char produced by an unresolved `next()`) with the
    /// stale static Int tag and the closure received its code as an Int.
    arg_tag_regs: [3]u32 = .{ 0, 0, 0 },
    /// Live-tag source for the member receiver, through the same Move-chain
    /// walk as `arg_tag_regs`: a `Char` produced by an unresolved `next()`
    /// and MOVED into the receiver slot reboxes with the producer's runtime
    /// tag, not the receiver register's static one (native Moves copy slots,
    /// never tags — the `isBlank` loop's `c.isWhitespace()` receiver).
    recv_tag_reg: u32 = 0,
    /// Member-call fields. `is_member` selects `receiver.name(args)` dispatch;
    /// scalar receivers are rebuilt from slots and object receivers stay boxed.
    /// `recv_class` is the receiver's class identity at compile time, re-checked at
    /// loop entry so a later activation with a different receiver class deopts.
    is_member: bool = false,
    recv_reg: u32 = 0,
    name: []const u8 = "",
    resolved_member: ?FuncId = null,
    dispatch_recv_reg: ?u32 = null,
    recv_class: usize = 0,
    /// Field-read fields. `is_field` selects a direct stored-field read from the
    /// boxed receiver at `field_idx` (the field's stable position in the instance,
    /// valid for the guarded receiver class). When `dst_reg`'s type is `.object`
    /// the read writes the boxed value into the frame register; otherwise a scalar
    /// slot. `recv_varies` marks a non-loop-invariant boxed receiver, so the read
    /// re-checks the receiver's class each call instead of relying on the entry
    /// guard. No side effects.
    is_field: bool = false,
    /// A scalar field store `recv.field = slot[src_reg]` to the stored field at
    /// `field_idx` of the boxed receiver.
    is_field_set: bool = false,
    field_idx: u32 = 0,
    recv_varies: bool = false,
    /// Native field access: a loop-invariant scalar field read/write emitted as a
    /// direct memory access (no callback). `fbase_slot` holds the receiver's field
    /// buffer pointer (cached at loop entry); `tag` is the field value's expected
    /// `Value` tag (a read deopts on a mismatch — e.g. a nullable field gone null).
    native: bool = false,
    fbase_slot: u32 = 0,
    tag: u8 = 0,
    /// Object-vs-null test: read boxed register `recv_reg`, write `0`/`1` (negated
    /// when `neg`) to the scalar `dst_reg` slot. `is_obj_move` instead copies boxed
    /// register `src_reg` into `dst_reg` (both frame registers).
    is_null_check: bool = false,
    is_obj_move: bool = false,
    neg: bool = false,
    identity: bool = false,
    src_reg: u32 = 0,
    /// Object collection subscript: `regs[dst] = regs[recv_reg].get(slot[args_reg])`
    /// where the element is a boxed object. The index is a scalar slot register.
    is_obj_index: bool = false,
    /// Global read: resolve `name` through the host and write the boxed value
    /// directly into the frame register. This keeps singleton/property reads
    /// inside an otherwise native object-control loop without putting a GC
    /// reference in the scalar slot file.
    is_load_global: bool = false,
    /// Call a loop-invariant callable value held in `recv_reg` with the scalar
    /// args at `args_reg`; the result is discarded.
    is_call_value: bool = false,
    /// Map subscript on the loop-invariant map in `recv_reg`. `is_map_get` reads
    /// `map[slot[args_reg]]` and writes the nullable-scalar result into the value
    /// slot `dst_reg` + `map_flag_slot`; `is_map_set` stores `slot[src_reg]` at
    /// key `slot[args_reg]`.
    is_map_get: bool = false,
    is_map_set: bool = false,
    map_flag_slot: u32 = 0,
};

/// One packed array a compiled loop indexes: the register holding it, the
/// element kind specialized at compile time, and the scratch slots where the
/// entry unbox writes its buffer pointer and length.
pub const ArrayUnbox = struct {
    reg: Reg,
    kind: runtime.PrimitiveArrayKind,
    ptr_slot: u32,
    len_slot: u32,
};

/// One capture cell a compiled loop reads/writes: the register holding the
/// `Value.Cell`, and the scalar type its box holds. The cached inner scalar
/// lives in the cell register's own slot (`reg.int()`) for the native run; it
/// is unboxed from the box at entry and written back through the box at exit.
pub const CellUnbox = struct {
    reg: Reg,
    rt: RegType,
};

/// One nullable-scalar register: it holds a scalar of kind `rt` or null. The
/// scalar value lives in the register's own slot (`reg.int()`); a separate
/// `flag_slot` holds 1 when the register is null. Both are synced with the boxed
/// `Value` in `regs` at loop entry/exit; all in-loop reads/writes are native.
pub const NullableUnbox = struct {
    reg: Reg,
    rt: RegType,
    flag_slot: u32,
    live_in: bool,
    live_out: bool,
};

/// A loop-invariant Instance receiver whose field buffer pointer is cached in
/// `ptr_slot` at loop entry, so native field reads/writes index it directly.
pub const FieldBase = struct {
    recv_reg: u32,
    ptr_slot: u32,
};

pub const CompiledLoop = struct {
    exec: jit.ExecBuf,
    n_regs: u32,
    n_slots: u32, // register slots + 2 per indexed array (ptr,len)
    reg_types: []RegType,
    /// Value tag (`@intFromEnum(std.meta.Tag(Value))`) each `.i32` register
    /// boxes back to. `.i32` covers `Int`/`Char`/`Short`/`Byte` in machine
    /// terms, but a rebox must restore the ORIGINAL tag: `valueFromSlot(.i32)`
    /// always minted `.Int`, so a `Char` crossing a trampoline or loop exit
    /// re-emerged as an `Int` (a trampolined `append(c)` printed the char's
    /// CODE as digits). Defaults to the `Int` tag; refined from resolved
    /// callee return types and live samples.
    box_tags: []u8,
    read_set: []bool, // reg is read somewhere in the loop (must unbox at entry)
    def_set: []bool, // reg is written somewhere in the loop (rebox at exit)
    arrays: []ArrayUnbox,
    cells: []CellUnbox,
    nullables: []NullableUnbox,
    field_bases: []FieldBase,
    /// Trampolined call sites, indexed by the site index the native code passes
    /// the host callback. Empty when the loop makes no calls.
    call_sites: []CallSite,
    /// Reserved slot holding the `*TrampCtx` the native call sites load into rdi,
    /// and the slot holding the host `TrampFn` pointer. Only valid when
    /// `call_sites.len != 0`.
    uc_slot: u32,
    tramp_slot: u32,
    /// Function-JIT mode: this compiled unit is a whole function body (entry to
    /// `Return`), not a natural loop. `n_params` scalar params are loaded into the
    /// slots at `param_slot_base` before entry; a `Return` writes the scalar
    /// result of kind `result_rt` into `result_slot` and exits with `RETURN_INST`.
    func_mode: bool = false,
    n_params: u32 = 0,
    param_slot_base: u32 = 0,
    result_slot: u32 = 0,
    result_rt: RegType = .unit,
    /// Function-JIT: the scalar kind each param was specialized on. A later call
    /// whose arg is a different kind deopts to the interpreter.
    param_rt: []RegType = &.{},
    allocator: Allocator,

    pub fn deinit(self: *CompiledLoop) void {
        self.exec.deinit();
        self.allocator.free(self.reg_types);
        self.allocator.free(self.box_tags);
        self.allocator.free(self.read_set);
        self.allocator.free(self.def_set);
        self.allocator.free(self.arrays);
        self.allocator.free(self.cells);
        self.allocator.free(self.nullables);
        self.allocator.free(self.field_bases);
        self.allocator.free(self.call_sites);
        if (self.param_rt.len != 0) self.allocator.free(self.param_rt);
    }
};

// --- supported-shape predicates ---------------------------------------------

fn constType(c: ir.Const) RegType {
    return switch (c) {
        .Int, .Char, .Short, .Byte => .i32,
        .Long => .i64,
        .Double => .f64,
        .Float => .f32,
        .Bool => .boolean,
        .Unit => .unit,
        .Null => .null_,
        else => .unknown,
    };
}

/// The float bit pattern a `Double`/`Float` const carries (raw in its slot;
/// an f32 occupies the low 32 bits).
fn constFloatBits(c: ir.Const) i64 {
    return switch (c) {
        .Double => |x| @bitCast(x),
        .Float => |x| @as(u32, @bitCast(x)),
        else => 0,
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
fn isFloat(t: RegType) bool {
    return t == .f64 or t == .f32;
}

/// The scalar `RegType` a capture cell holds, or null for kinds the integer JIT
/// does not cache (the cell stays interpreter-only).
fn cellScalarType(v: Value) ?RegType {
    return switch (v) {
        .Int, .Char, .Short, .Byte => .i32,
        .Long => .i64,
        .Double => .f64,
        .Float => .f32,
        .Bool => .boolean,
        else => null,
    };
}

fn isArithBinOp(op: ir.BinOp) bool {
    return switch (op) {
        .Add, .Sub, .Mul => true,
        else => false,
    };
}
fn isDivBinOp(op: ir.BinOp) bool {
    return op == .Div or op == .Mod;
}
fn isCmpBinOp(op: ir.BinOp) bool {
    return switch (op) {
        .Eq, .NotEq, .Less, .LessEq, .Greater, .GreaterEq => true,
        else => false,
    };
}

// --- array subscripts -------------------------------------------------------

/// An array subscript recognized in the IR. Subscripts lower to `CallMember`
/// "get"/"set" (the interpreter fast-paths them), not to `Index`/`IndexSet`,
/// so the JIT matches that shape directly (and the dedicated instructions too).
const ArrayOp = struct { is_set: bool, recv: Reg, index: Reg, value: Reg, dst: Reg };

fn arrayOpOf(module: *const Module, inst: *const Inst) ?ArrayOp {
    switch (inst.*) {
        .Index => |ix| return .{ .is_set = false, .recv = ix.receiver, .index = ix.index, .value = ix.index, .dst = ix.dst },
        .IndexSet => |ix| return .{ .is_set = true, .recv = ix.receiver, .index = ix.index, .value = ix.value, .dst = ix.index },
        .CallMember => |cm| {
            if (cm.arg_names.len != 0) return null;
            if (cm.name.int() >= module.consts.items.len) return null;
            const name = module.consts.items[cm.name.int()];
            if (name != .String) return null;
            const a0 = cm.args.int();
            if (cm.n_args == 1 and std.mem.eql(u8, name.String, "get"))
                return .{ .is_set = false, .recv = cm.receiver, .index = Reg.from(a0), .value = Reg.from(a0), .dst = cm.dst };
            if (cm.n_args == 2 and std.mem.eql(u8, name.String, "set"))
                return .{ .is_set = true, .recv = cm.receiver, .index = Reg.from(a0), .value = Reg.from(a0 + 1), .dst = cm.dst };
            return null;
        },
        else => return null,
    }
}

/// A zero-arg numeric conversion (`x.toDouble()`/`toLong()`/`toInt()`), which
/// lowers to `CallMember`. The JIT compiles the always-exact directions
/// (int→double, int width changes); double→int is left to the interpreter
/// because `cvttsd2si` diverges from Kotlin on NaN/overflow (it clamps).
const NumConv = struct { dst: Reg, src: Reg, to: RegType };

fn numericConvOf(module: *const Module, inst: *const Inst) ?NumConv {
    switch (inst.*) {
        .CallMember => |cm| {
            if (cm.arg_names.len != 0 or cm.n_args != 0) return null;
            if (cm.name.int() >= module.consts.items.len) return null;
            const name = module.consts.items[cm.name.int()];
            if (name != .String) return null;
            const to: RegType = if (std.mem.eql(u8, name.String, "toDouble"))
                .f64
            else if (std.mem.eql(u8, name.String, "toFloat"))
                .f32
            else if (std.mem.eql(u8, name.String, "toLong"))
                .i64
            else if (std.mem.eql(u8, name.String, "toInt"))
                .i32
            else
                return null;
            return .{ .dst = cm.dst, .src = cm.receiver, .to = to };
        },
        else => return null,
    }
}

/// A bitwise infix operation (`a and b`, `a shl n`, …), which Kotlin lowers to a
/// `CallMember` (these are infix member functions on `Int`/`Long`). The JIT
/// emits a native bitwise/shift op. `ushr` (logical right shift) and `inv` are
/// left to the interpreter — `ushr` needs width-aware zero-extension this fast
/// path does not do.
const BitKind = enum { @"and", @"or", xor, shl, sar };
const BitOp = struct { dst: Reg, lhs: Reg, rhs: Reg, kind: BitKind };

fn bitwiseOpOf(module: *const Module, inst: *const Inst) ?BitOp {
    switch (inst.*) {
        .CallMember => |cm| {
            if (cm.arg_names.len != 0 or cm.n_args != 1) return null;
            if (cm.name.int() >= module.consts.items.len) return null;
            const name = module.consts.items[cm.name.int()];
            if (name != .String) return null;
            const kind: BitKind = if (std.mem.eql(u8, name.String, "and"))
                .@"and"
            else if (std.mem.eql(u8, name.String, "or"))
                .@"or"
            else if (std.mem.eql(u8, name.String, "xor"))
                .xor
            else if (std.mem.eql(u8, name.String, "shl"))
                .shl
            else if (std.mem.eql(u8, name.String, "shr"))
                .sar
            else
                return null;
            return .{ .dst = cm.dst, .lhs = cm.receiver, .rhs = Reg.from(cm.args.int()), .kind = kind };
        },
        else => return null,
    }
}

const INLINE_MAX_INSTS: usize = 24;

/// Whether a top-level callee can be inlined into the native loop: a single block
/// returning a value, made only of scalar instructions (no nested calls, object
/// ops, arrays, cells, or fields), with all-scalar required parameters and a
/// scalar return. Such a body is spliced into the caller's code with its registers
/// remapped, eliminating the call entirely.
fn inlinableCallee(module: *const Module, f: *const Func) bool {
    if (f.is_suspend or f.has_receiver_param) return false;
    if (f.blocks.len != 1) return false; // single block, not deferred
    const blk = &f.blocks[0];
    switch (blk.terminator) {
        .Return => |r| if (r == null) return false,
        else => return false,
    }
    for (f.params) |p| {
        if (p.is_vararg or p.default != null) return false;
        if (retRegType(p.ty) == .unknown) return false;
    }
    if (funcReturnRegType(module, f) == .unknown) return false;
    if (blk.insts.len > INLINE_MAX_INSTS) return false;
    for (blk.insts) |*inst| {
        if (numericConvOf(module, inst) != null) continue;
        if (bitwiseOpOf(module, inst) != null) continue;
        if (arrayOpOf(module, inst) != null) return false;
        switch (inst.*) {
            .Const, .Move, .BinOp, .Not, .UnOp, .Trace => {},
            // A parameter load binds to the matching caller argument at inline time.
            .LoadParam => |lp| if (lp.idx >= f.params.len) return false,
            else => return false,
        }
    }
    return true;
}

/// One inlined call: the callee's single block is emitted in place of the call,
/// with its registers shifted by `base` into the caller's extended register space.
/// `args_reg`/`dst` are caller registers; deopts inside the body resume at the
/// original call instruction (`block`,`inst`) so the interpreter re-runs the call.
const InlineSite = struct {
    block: BlockId,
    inst: u32,
    callee: *const Func,
    base: u32,
    args_reg: u32,
    n_args: u32,
    dst: Reg,
    /// Member inline: the call's receiver register (the callee's `this`), the
    /// callee register `LoadParam 0` writes (mapped to `recv_reg`, not `base`), and
    /// the contiguous range of field-access call sites the body's GetField/SetField
    /// on `this` were registered as (emitted in body order).
    is_member: bool = false,
    recv_reg: u32 = 0,
    this_reg: u32 = 0,
    field_site_base: u32 = 0,
    n_field_sites: u32 = 0,
    /// Has a value return (false for a `Unit` method invoked for its effect).
    has_result: bool = true,
};

/// The destination register an instruction writes, if any (covering every shape
/// that can appear in a compiled loop body, including object-producing ops that
/// `instReadsDef` deliberately omits). Used to confirm a register is loop-
/// invariant — defined outside the loop, never written inside.
/// The register whose LIVE tag governs `reg`'s rebox at the call at
/// `call_idx`: walk same-block `Move`s backward (arg slots are filled by
/// Moves immediately before their call), redirecting through each; any
/// other definition of the current register terminates the chain there.
fn argTagSourceReg(insts: []const Inst, call_idx: usize, reg: u32) u32 {
    var r = reg;
    var i = call_idx;
    while (i > 0) {
        i -= 1;
        const inst = &insts[i];
        if (inst.* == .Move) {
            const mv = inst.Move;
            if (mv.dst.int() == r) {
                r = mv.src.int();
                continue;
            }
        }
        if (instAnyDst(inst)) |d| {
            if (d.int() == r) break;
        }
    }
    return r;
}

fn instAnyDst(inst: *const Inst) ?Reg {
    return switch (inst.*) {
        .Const => |x| x.dst,
        .Move => |x| x.dst,
        .BinOp => |x| x.dst,
        .Not => |x| x.dst,
        .UnOp => |x| x.dst,
        .LoadParam => |x| x.dst,
        .LoadCapture => |x| x.dst,
        .LoadGlobal => |x| x.dst,
        .GetField => |x| x.dst,
        .Index => |x| x.dst,
        .CallMember => |x| x.dst,
        .Call => |x| x.dst,
        .CallValue => |x| x.dst,
        .CellGet => |x| x.dst,
        .MakeCell => |x| x.dst,
        .NewInstance => |x| x.dst,
        .NewList => |x| x.dst,
        else => null,
    };
}

fn regWrittenInBody(func: *const Func, body: []const BlockId, r: Reg) bool {
    for (body) |bid| {
        for (func.blocks[bid.int()].insts) |*inst| {
            if (instAnyDst(inst)) |d| if (d.int() == r.int()) return true;
        }
    }
    return false;
}

/// Whether a member method can be inlined: a single block, all instructions are
/// scalar ops, parameter loads, or `this`-field accesses (get/set of a scalar
/// field on the `LoadParam 0` register), with scalar required parameters and a
/// scalar-or-`Unit` return. `this_reg` receives the register `LoadParam 0` binds.
fn inlinableMemberCallee(module: *const Module, f: *const Func, this_reg_out: *u32) bool {
    if (f.is_suspend) return false;
    if (f.blocks.len != 1) return false;
    if (!f.has_receiver_param) return false; // params[0] is the synthesized `this`
    const blk = &f.blocks[0];
    switch (blk.terminator) {
        .Return => {},
        else => return false,
    }
    // Parameters after the receiver must be plain scalars.
    for (f.params, 0..) |p, i| {
        if (i == 0) continue; // the receiver
        if (p.is_vararg or p.default != null or retRegType(p.ty) == .unknown) return false;
    }
    if (blk.insts.len > INLINE_MAX_INSTS) return false;
    var this_reg: ?u32 = null;
    for (blk.insts) |*inst| {
        switch (inst.*) {
            .LoadParam => |lp| {
                if (lp.idx == 0) this_reg = lp.dst.int();
            },
            else => {},
        }
    }
    const tr = this_reg orelse return false; // must bind `this`
    this_reg_out.* = tr;
    for (blk.insts) |*inst| {
        if (numericConvOf(module, inst) != null) continue;
        if (bitwiseOpOf(module, inst) != null) continue;
        if (trampolinableFieldOf(module, inst)) |fld| {
            if (fld.recv.int() != tr) return false; // only `this`-field reads
            continue;
        }
        if (trampolinableFieldSetOf(module, inst)) |fs| {
            if (fs.recv.int() != tr) return false;
            continue;
        }
        if (arrayOpOf(module, inst) != null) return false;
        switch (inst.*) {
            .Const, .Move, .BinOp, .Not, .UnOp, .Trace => {},
            .LoadParam => |lp| if (lp.idx >= f.params.len) return false,
            else => return false,
        }
    }
    return true;
}

/// Copy an instruction with every register reference shifted by `base` — used to
/// emit an inlined callee body in the caller's extended register space. Only the
/// scalar instruction shapes an inlinable callee can contain are remapped.
fn remapInst(inst: Inst, base: u32) Inst {
    const b = base;
    var out = inst;
    switch (out) {
        .Const => |*c| c.dst = Reg.from(c.dst.int() + b),
        .Move => |*m| {
            m.dst = Reg.from(m.dst.int() + b);
            m.src = Reg.from(m.src.int() + b);
        },
        .BinOp => |*x| {
            x.dst = Reg.from(x.dst.int() + b);
            x.lhs = Reg.from(x.lhs.int() + b);
            x.rhs = Reg.from(x.rhs.int() + b);
        },
        .Not => |*n| {
            n.dst = Reg.from(n.dst.int() + b);
            n.src = Reg.from(n.src.int() + b);
        },
        .UnOp => |*u| {
            u.dst = Reg.from(u.dst.int() + b);
            u.operand = Reg.from(u.operand.int() + b);
        },
        .CallMember => |*cm| {
            // Bitwise / numeric-conversion infix ops (the only CallMembers an
            // inlinable callee may contain): remap receiver, args base, dst.
            cm.dst = Reg.from(cm.dst.int() + b);
            cm.receiver = Reg.from(cm.receiver.int() + b);
            cm.args = Reg.from(cm.args.int() + b);
        },
        .Trace => {},
        else => {},
    }
    return out;
}

/// A top-level `Call` the loop JIT can trampoline: a native call site invokes the
/// host, which reboxes the scalar args, runs the callee interpreted, and reboxes a
/// scalar result. v1 handles only the bare positional form (no named args, no
/// reified type args) with at most three args.
const TrampCall = struct { func: FuncId, args_reg: u32, n_args: u32, dst: Reg };

fn trampolinableCallOf(inst: *const Inst) ?TrampCall {
    switch (inst.*) {
        .Call => |c| {
            if (c.arg_names.len != 0 or c.type_args.len != 0) return null;
            if (c.n_args > 3) return null;
            return .{ .func = c.func, .args_reg = c.args.int(), .n_args = c.n_args, .dst = c.dst };
        },
        else => return null,
    }
}

/// A `CallValue` the loop JIT can trampoline: invocation of a loop-invariant
/// callable value (a closure/function/bound reference) held in a register. v1
/// handles the bare positional form with at most three scalar args and a result
/// that is discarded (a side-effecting call).
const TrampCallValue = struct { callee: Reg, args_reg: u32, n_args: u32, dst: Reg };

fn trampolinableCallValueOf(inst: *const Inst) ?TrampCallValue {
    switch (inst.*) {
        .CallValue => |cv| {
            if (cv.arg_names.len != 0 or cv.type_args.len != 0) return null;
            if (cv.n_args > 3) return null;
            return .{ .callee = cv.callee, .args_reg = cv.args.int(), .n_args = cv.n_args, .dst = cv.dst };
        },
        else => return null,
    }
}

const TrampGlobal = struct { dst: Reg, name: []const u8 };

fn trampolinableGlobalOf(module: *const Module, inst: *const Inst) ?TrampGlobal {
    switch (inst.*) {
        .LoadGlobal => |lg| {
            if (lg.name.int() >= module.consts.items.len) return null;
            const name = module.consts.items[lg.name.int()];
            if (name != .String) return null;
            return .{ .dst = lg.dst, .name = name.String };
        },
        else => return null,
    }
}

fn isCallableValue(v: Value) bool {
    return switch (v) {
        .IrClosure, .Function, .Intrinsic, .BoundMethod, .BoundUserMethod => true,
        else => false,
    };
}

/// A positional `CallMember` the loop JIT can trampoline.
const TrampMember = struct {
    recv: Reg,
    name: []const u8,
    args_reg: u32,
    n_args: u32,
    dst: Reg,
    resolved: ?FuncId,
    dispatch_recv: ?Reg,
};

fn trampolinableMemberOf(module: *const Module, inst: *const Inst) ?TrampMember {
    // Subscripts / numeric conversions / bitwise infix ops also lower to
    // `CallMember` but are compiled natively, not trampolined — exclude them.
    if (arrayOpOf(module, inst) != null) return null;
    if (numericConvOf(module, inst) != null) return null;
    if (bitwiseOpOf(module, inst) != null) return null;
    switch (inst.*) {
        .CallMember => |cm| {
            if (cm.arg_names.len != 0 or cm.static_recv != null) return null;
            if (cm.n_args > 3) return null;
            if (cm.name.int() >= module.consts.items.len) return null;
            const name = module.consts.items[cm.name.int()];
            if (name != .String) return null;
            return .{
                .recv = cm.receiver,
                .name = name.String,
                .args_reg = cm.args.int(),
                .n_args = cm.n_args,
                .dst = cm.dst,
                .resolved = cm.resolved,
                .dispatch_recv = cm.dispatch_receiver,
            };
        },
        else => return null,
    }
}

/// `fn(user, receiver, method_name, args) -> resolved method FuncId | null`. The
/// loop JIT calls this at compile time (with the live receiver/args) to learn a
/// trampolined member call's return type; null means unresolvable/intrinsic, so
/// the call is not trampolined.
pub const MemberResolver = *const fn (*anyopaque, *const Value, []const u8, []const Value) ?FuncId;

/// A `GetField` the loop JIT can trampoline: a property read on a loop-invariant
/// boxed object, handled as a direct stored-field read (the receiver stays boxed
/// in the frame's registers, exactly like a member call's receiver).
const TrampField = struct { recv: Reg, name: []const u8, dst: Reg };

fn trampolinableFieldOf(module: *const Module, inst: *const Inst) ?TrampField {
    switch (inst.*) {
        .GetField => |gf| {
            if (gf.field.int() >= module.consts.items.len) return null;
            const name = module.consts.items[gf.field.int()];
            if (name != .String) return null;
            return .{ .recv = gf.receiver, .name = name.String, .dst = gf.dst };
        },
        else => return null,
    }
}

/// Inside a method body, an own-field access lowers to a scope-qualified
/// getter/setter sentinel `$sgetter$<owner>\u{1f}<field>` (resp. `$ssetter$`).
/// Return the bare field name for such a sentinel (so it can be resolved as a
/// plain stored field), or the name unchanged when it is already plain.
fn memberFieldName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "$sgetter$") or std.mem.startsWith(u8, name, "$ssetter$")) {
        if (std.mem.lastIndexOfScalar(u8, name, 0x1f)) |i| return name[i + 1 ..];
    }
    return name;
}

/// A `SetField` the loop JIT can compile: a write of a scalar value to a plain
/// stored field of a loop-invariant (or class-stable) boxed object.
const TrampFieldSet = struct { recv: Reg, name: []const u8, value: Reg };

fn trampolinableFieldSetOf(module: *const Module, inst: *const Inst) ?TrampFieldSet {
    switch (inst.*) {
        .SetField => |sf| {
            if (sf.field.int() >= module.consts.items.len) return null;
            const name = module.consts.items[sf.field.int()];
            if (name != .String) return null;
            return .{ .recv = sf.receiver, .name = name.String, .value = sf.value };
        },
        else => return null,
    }
}

/// `fn(user, receiver, field_name) -> stored field index | null`. The loop JIT
/// calls this at compile time; a non-null index means `name` is a plain stored
/// property (no custom getter) the trampoline can read directly. Null means the
/// read must stay interpreted (computed getter / delegated / extension property).
pub const FieldResolver = *const fn (*anyopaque, *const Value, []const u8) ?u32;

/// The scalar `RegType` a callee's declared return type maps to, or `.unknown`
/// for a non-scalar / nullable / `Unit` return (the call's result is then not
/// reboxed; a used non-scalar result makes the loop uncompilable).
fn isUnitReturn(ty: ir.TypeRef) bool {
    return !ty.nullable and (std.mem.eql(u8, ty.name, "Unit") or ty.name.len == 0);
}

fn retRegType(ty: ir.TypeRef) RegType {
    if (ty.nullable) return .unknown;
    const n = ty.name;
    if (std.mem.eql(u8, n, "Int") or std.mem.eql(u8, n, "Char") or
        std.mem.eql(u8, n, "Short") or std.mem.eql(u8, n, "Byte")) return .i32;
    if (std.mem.eql(u8, n, "Long")) return .i64;
    if (std.mem.eql(u8, n, "Double")) return .f64;
    if (std.mem.eql(u8, n, "Float")) return .f32;
    if (std.mem.eql(u8, n, "Boolean")) return .boolean;
    return .unknown;
}

threadlocal var ret_type_cache: std.AutoHashMapUnmanaged(usize, RegType) = .empty;

/// The scalar `RegType` a callee returns. Uses the declared return type when it
/// names a scalar; otherwise (an inferred expression-body return, recorded as
/// `Unit` in the IR) infers it from the callee's own body. Cached per function.
fn funcReturnRegType(module: *const Module, func: *const Func) RegType {
    const explicit = retRegType(func.return_ty);
    if (explicit != .unknown) return explicit;
    const key = @intFromPtr(func);
    if (ret_type_cache.get(key)) |c| return c;
    // Seed `.unknown` before inferring so a recursive (or mutually recursive)
    // callee re-entering here sees the in-progress entry and stops, instead of
    // looping forever; the real result overwrites it below.
    ret_type_cache.put(metadata_allocator, key, .unknown) catch {};
    const inferred = inferScalarReturnType(metadata_allocator, module, func) orelse .unknown;
    ret_type_cache.put(metadata_allocator, key, inferred) catch {};
    return inferred;
}

/// Infer a callee's scalar return type from its IR body: seed the parameter
/// registers from their declared types, propagate scalar types forward, and read
/// the type of the value(s) flowing into the `Return` terminator. Returns null
/// unless every value-return agrees on one scalar type (so a non-scalar or
/// ambiguous return stays uncompilable). A nested call to another inferred-return
/// function does not recurse — it simply stays `.unknown` here.
fn inferScalarReturnType(a: Allocator, module: *const Module, func: *const Func) ?RegType {
    if (func.blocks.len == 0) return null;
    const n = func.n_locals;
    if (n == 0) return null;
    const types = a.alloc(RegType, n) catch return null;
    defer a.free(types);
    @memset(types, .unknown);
    const empty_ai = a.alloc(?ArrayInfo, n) catch return null;
    defer a.free(empty_ai);
    @memset(empty_ai, null);
    const empty_ci = a.alloc(?RegType, n) catch return null;
    defer a.free(empty_ci);
    @memset(empty_ci, null);
    for (func.params, 0..) |p, i| {
        if (i >= n) break;
        types[i] = retRegType(p.ty);
    }
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < 16) : (iters += 1) {
        changed = false;
        for (func.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (setDefType(types, module, inst, empty_ai, empty_ci)) changed = true;
            }
        }
    }
    var result: RegType = .unknown;
    for (func.blocks) |*blk| {
        const r = switch (blk.terminator) {
            .Return => |maybe_r| maybe_r orelse continue,
            else => continue,
        };
        if (r.int() >= n) return null;
        const t = types[r.int()];
        if (!isScalarRt(t)) return null;
        if (result == .unknown) result = t else if (result != t) return null;
    }
    return if (result == .unknown) null else result;
}

/// The scalar result type of an arithmetic/division op on the two operand types,
/// following Kotlin's numeric promotion (`Double > Float > Long > Int`; the
/// narrower Byte/Short/Char already map to `i32`). A still-unknown operand yields
/// the other (partial inference); both unknown stays unknown.
fn promoteArith(lt: RegType, rt: RegType) RegType {
    if (lt == .f64 or rt == .f64) return .f64;
    if (lt == .f32 or rt == .f32) return .f32;
    if (lt == .i64 or rt == .i64) return .i64;
    if (lt == .i32 or rt == .i32) return .i32;
    return if (lt != .unknown) lt else rt;
}

/// Fill `ext[site.base .. site.base + callee.n_locals]` with the inlined callee's
/// register types: parameters seeded from the caller's argument types, then the
/// scalar propagation run over the callee's single block.
fn fillInlineTypes(a: Allocator, module: *const Module, site: *const InlineSite, caller_types: []const RegType, ext: []RegType, field_resolver: ?FieldResolver, resolver_user: ?*anyopaque, regs: []const Value) Allocator.Error!void {
    const callee = site.callee;
    const n = callee.n_locals;
    if (n == 0) return;
    const t = ext[site.base .. site.base + n];
    @memset(t, .unknown);
    const eai = try a.alloc(?ArrayInfo, n);
    defer a.free(eai);
    @memset(eai, null);
    const eci = try a.alloc(?RegType, n);
    defer a.free(eci);
    @memset(eci, null);
    // For a member inline, parameter index 1 maps to the first call argument (index
    // 0 is the receiver); a top-level inline maps index 0 to the first argument.
    const arg_base: i64 = if (site.is_member) @as(i64, site.args_reg) - 1 else @as(i64, site.args_reg);
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < 16) : (iters += 1) {
        changed = false;
        for (callee.blocks[0].insts) |*inst| {
            if (inst.* == .LoadParam) {
                const lp = inst.LoadParam;
                if (site.is_member and lp.idx == 0) continue; // receiver: not a scalar
                const ar = arg_base + lp.idx;
                const at: RegType = if (ar >= 0 and ar < caller_types.len) caller_types[@intCast(ar)] else .unknown;
                if (lp.dst.int() < n and setType(t, lp.dst, at)) changed = true;
                continue;
            }
            // A member body's `this`-field read types its dst from the live field.
            if (site.is_member) {
                if (trampolinableFieldOf(module, inst)) |fld| {
                    if (field_resolver) |fr| {
                        if (fr(resolver_user.?, &regs[site.recv_reg], memberFieldName(fld.name))) |idx| {
                            const g = regs[site.recv_reg].Instance.borrow();
                            const fv: ?Value = if (idx < g.get().fields.items.len) g.get().fields.items[idx].value else null;
                            g.deinit();
                            if (fv) |v| if (cellScalarType(v)) |rt| {
                                if (fld.dst.int() < n and setType(t, fld.dst, rt)) changed = true;
                            };
                        }
                    }
                    continue;
                }
                if (trampolinableFieldSetOf(module, inst) != null) continue;
            }
            if (setDefType(t, module, inst, eai, eci)) changed = true;
        }
    }
}

fn isScalarRt(t: RegType) bool {
    return switch (t) {
        .i32, .i64, .f64, .f32, .boolean => true,
        else => false,
    };
}

/// The `Value` union tag a native field store stamps for a scalar register kind.
fn tagForRt(t: RegType) ?u8 {
    const T = std.meta.Tag(Value);
    return switch (t) {
        .i32 => @intFromEnum(@as(T, .Int)),
        .i64 => @intFromEnum(@as(T, .Long)),
        .f64 => @intFromEnum(@as(T, .Double)),
        .f32 => @intFromEnum(@as(T, .Float)),
        .boolean => @intFromEnum(@as(T, .Bool)),
        else => null,
    };
}

/// The `RegType` for a live register value: a scalar kind, `.object` for a class
/// instance (the JIT holds it in `regs`, where it stays a GC root, and at run time
/// the register may also hold null), or null when it cannot be classified (a bare
/// `Null`/`Unit`, whose register would have an ambiguous static type).
fn liveValueRegType(v: Value) ?RegType {
    if (cellScalarType(v)) |s| return s;
    return switch (v) {
        .Null, .Unit => null,
        else => .object,
    };
}

/// The live element at `idx` of a `List` or reference `Array`, or null for an
/// out-of-range index or an unsupported container. Used to sample an object
/// collection's element type at compile time (a packed primitive array is handled
/// by the native array path, not here).
/// The scalar `RegType` of a `Map`'s values, sampled from any live entry (the
/// value type is uniform), or null for an empty map / non-scalar value type.
fn liveMapValueType(recv: Value) ?RegType {
    if (recv != .Map) return null;
    const g = recv.Map.entries.borrow();
    defer g.deinit();
    const pairs = g.get().pairs.items;
    if (pairs.len == 0) return null;
    return cellScalarType(pairs[0].value);
}

pub fn liveElementAt(recv: Value, idx: i64) ?Value {
    if (idx < 0) return null;
    const u: usize = @intCast(idx);
    switch (recv) {
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            const items = g.get().items;
            return if (u < items.len) items[u] else null;
        },
        .Array => |arr| return if (arr.prim == null and u < arr.len()) arr.get(u) else null,
        else => return null,
    }
}

/// The class-cell identity of an `Instance` value, used as the loop-entry guard
/// for a trampolined member call (a later activation whose receiver is a different
/// class deopts rather than dispatching against a stale return-type assumption).
pub fn instanceClassIdentity(v: Value) usize {
    const g = v.Instance.borrow();
    defer g.deinit();
    return g.get().class.identity();
}

/// Element register type + native access width for a packed array kind, or null
/// for kinds the JIT does not compile (Float). A `Double` element is moved as a
/// raw 8-byte (`b64`) value — its f64 bits live in the slot and are consumed by
/// the SSE arithmetic path.
fn arrayElemShape(kind: runtime.PrimitiveArrayKind) ?struct { rt: RegType, w: jit.ElemW, esize: u8 } {
    return switch (kind) {
        .Boolean => .{ .rt = .boolean, .w = .b8u, .esize = 1 },
        .Byte => .{ .rt = .i32, .w = .b8s, .esize = 1 },
        .UByte => .{ .rt = .i32, .w = .b8u, .esize = 1 },
        .Short => .{ .rt = .i32, .w = .b16s, .esize = 2 },
        .UShort => .{ .rt = .i32, .w = .b16u, .esize = 2 },
        .Char => .{ .rt = .i32, .w = .b16u, .esize = 2 },
        .Int => .{ .rt = .i32, .w = .b32s, .esize = 4 },
        .UInt => .{ .rt = .i32, .w = .b32u, .esize = 4 },
        .Long => .{ .rt = .i64, .w = .b64, .esize = 8 },
        .ULong => .{ .rt = .i64, .w = .b64, .esize = 8 },
        .Double => .{ .rt = .f64, .w = .b64, .esize = 8 },
        .Float => .{ .rt = .f32, .w = .b32u, .esize = 4 },
    };
}

/// Per-array compile-time shape, indexed by the IR register holding the array.
const ArrayInfo = struct {
    rt: RegType,
    w: jit.ElemW,
    esize: u8,
    ptr_slot: u32,
    len_slot: u32,
};

// --- whole-function static type inference -----------------------------------

fn inferTypes(a: Allocator, module: *const Module, func: *const Func, n_regs: u32, array_info: []const ?ArrayInfo, cell_info: []const ?RegType, regs: []const Value, member_ret: []const RegType) Allocator.Error![]RegType {
    const types = try a.alloc(RegType, n_regs);
    @memset(types, .unknown);
    // Member-call result types are resolved against the live receiver before this
    // pass (the IR alone cannot name the dispatched method); seed them so uses of
    // a member call's result propagate. Overridden by `setDefType` if some in-body
    // instruction also defines the reg.
    for (member_ret, 0..) |rt, r| {
        if (rt != .unknown) types[r] = rt;
    }
    // Seed every register from its live scalar kind: a loop that reads a
    // parameter or any prologue-computed value (a field read, a member
    // call's result — e.g. a hoisted range's `first`/`last`) has no
    // in-body instruction to infer that register's type from. This is
    // sound because the entry unbox re-checks each read reg against its
    // cached type and bails to the interpreter on any mismatch (e.g. a
    // later activation with a different type). A reg the loop writes is
    // overridden by `setDefType`; a non-scalar reg is left unknown (and
    // bails if read).
    {
        var p: usize = 0;
        while (p < n_regs and p < regs.len) : (p += 1) {
            if (array_info[p] != null or cell_info[p] != null) continue;
            if (cellScalarType(regs[p])) |rt| types[p] = rt;
        }
    }
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < 16) : (iters += 1) {
        changed = false;
        for (func.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (setDefType(types, module, inst, array_info, cell_info)) changed = true;
            }
        }
    }
    return types;
}

fn setDefType(types: []RegType, module: *const Module, inst: *const Inst, array_info: []const ?ArrayInfo, cell_info: []const ?RegType) bool {
    if (trampolinableGlobalOf(module, inst)) |lg| {
        return setType(types, lg.dst, .object);
    }
    // Array subscripts: a get yields the element type, a set yields Unit.
    if (arrayOpOf(module, inst)) |op| {
        const t: RegType = if (op.is_set) .unit else blk: {
            if (op.recv.int() < array_info.len) {
                if (array_info[op.recv.int()]) |ai| break :blk ai.rt;
            }
            break :blk .unknown;
        };
        return setType(types, op.dst, t);
    }
    // Numeric conversion (`x.toDouble()` etc.) yields the named target type.
    if (numericConvOf(module, inst)) |nc| {
        return setType(types, nc.dst, nc.to);
    }
    // Bitwise infix op yields its left operand's integer type.
    if (bitwiseOpOf(module, inst)) |bo| {
        return setType(types, bo.dst, typeOf(types, bo.lhs));
    }
    // A trampolined top-level call yields its callee's declared scalar return
    // type (`.unknown` for Unit/non-scalar — its result is then never reboxed).
    if (trampolinableCallOf(inst)) |tc| {
        const f = module.funcById(tc.func) orelse return false;
        return setType(types, tc.dst, funcReturnRegType(module, f));
    }
    // CellGet yields the cell's scalar type; CellSet has no def.
    if (inst.* == .CellGet) {
        const cg = inst.CellGet;
        const t: RegType = if (cg.cell.int() < cell_info.len) (cell_info[cg.cell.int()] orelse .unknown) else .unknown;
        return setType(types, cg.dst, t);
    }
    const dst_t: ?struct { r: Reg, t: RegType } = switch (inst.*) {
        .Const => |c| .{ .r = c.dst, .t = constType(module.consts.items[c.value.int()]) },
        .Move => |m| .{ .r = m.dst, .t = typeOf(types, m.src) },
        .BinOp => |b| blk: {
            if (isCmpBinOp(b.op)) break :blk .{ .r = b.dst, .t = .boolean };
            if (isArithBinOp(b.op) or isDivBinOp(b.op)) {
                break :blk .{ .r = b.dst, .t = promoteArith(typeOf(types, b.lhs), typeOf(types, b.rhs)) };
            }
            break :blk null;
        },
        .Not => |n| .{ .r = n.dst, .t = .boolean },
        .UnOp => |u| .{ .r = u.dst, .t = typeOf(types, u.operand) },
        else => null,
    };
    if (dst_t) |d| return setType(types, d.r, d.t);
    return false;
}

fn setType(types: []RegType, r: Reg, t: RegType) bool {
    if (r.int() >= types.len or t == .unknown or types[r.int()] == t) return false;
    // `.null_` is the bottom of a nullable merge (one branch assigns null, the
    // other a concrete value): never let it downgrade an already-known concrete
    // type, so a register merged from `{null, scalar}` settles on the scalar
    // (and one merged from `{null, object}` on the object) instead of oscillating.
    if (t == .null_ and types[r.int()] != .unknown) return false;
    types[r.int()] = t;
    return true;
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
        else => {},
    }
}

/// Every CFG successor of a terminator (all kinds), for dominance analysis.
fn fullSucc(term: ir.Terminator, out: *std.ArrayListUnmanaged(BlockId), a: Allocator) Allocator.Error!void {
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

/// `dom[i]` = `header` dominates block `i`: every path from the function entry
/// to `i` goes through `header`. Computed as the complement of "reachable from
/// entry without entering header". Caller frees.
fn dominatedSet(a: Allocator, func: *const Func, nb: usize, header: BlockId) Allocator.Error![]bool {
    const reach_no_h = try a.alloc(bool, nb);
    defer a.free(reach_no_h);
    @memset(reach_no_h, false);
    var stack: std.ArrayListUnmanaged(BlockId) = .empty;
    defer stack.deinit(a);
    var succ: std.ArrayListUnmanaged(BlockId) = .empty;
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

fn collectLoop(a: Allocator, func: *const Func, header: BlockId) Allocator.Error!?[]BlockId {
    const nb = func.blocks.len;
    if (nb == 0 or header.int() >= nb) return null;

    const dom = try dominatedSet(a, func, nb, header);
    defer a.free(dom);

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

    // Single-entry check: a genuine natural loop is entered only through its
    // header. If any non-header loop block has a predecessor outside the loop,
    // `header` is not the real loop entry (e.g. it is a body block of an
    // enclosing loop) — reject so we never compile a mis-rooted region.
    for (0..nb) |i| {
        if (!inloop[i] or i == header.int()) continue;
        for (preds[i].items) |p| {
            if (!inloop[p.int()]) return null;
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

// --- liveness ---------------------------------------------------------------

fn typeAt(types: []const RegType, r: Reg) RegType {
    return if (r.int() < types.len) types[r.int()] else .unknown;
}

/// Whether a `BinOp` is an object-vs-null comparison — recognized so the JIT
/// emits a null-test callback (reading the boxed register) instead of a native
/// scalar compare.
fn isNullCheckBinOp(types: []const RegType, b: anytype) bool {
    if (b.op != .Eq and b.op != .NotEq and b.op != .IdentEq and b.op != .IdentNeq) return false;
    const lt = typeAt(types, b.lhs);
    const rt = typeAt(types, b.rhs);
    return (lt == .object and rt == .null_) or (lt == .null_ and rt == .object) or (lt == .object and rt == .object);
}

fn instReadsDef(module: *const Module, inst: *const Inst, reads: *[4]Reg, n_reads: *usize, def: *?Reg, types: []const RegType) void {
    n_reads.* = 0;
    def.* = null;
    if (arrayOpOf(module, inst)) |op| {
        reads[0] = op.index;
        if (op.is_set) {
            // A subscript store reads the index and value; its "dst" is a
            // discarded result, never a scalar def.
            reads[1] = op.value;
            n_reads.* = 2;
            return;
        }
        n_reads.* = 1;
        // An object-collection / map subscript writes a boxed or nullable register,
        // not a plain scalar slot — only a packed-array element is a scalar def.
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
    // A trampolined call reads its (≤3) consecutive arg registers; its dst is a
    // def only when the callee returns a scalar (an unused/Unit result is not
    // tracked, so it does not force the dst into the scalar type requirement).
    if (trampolinableCallOf(inst)) |tc| {
        var k: u8 = 0;
        while (k < tc.n_args and k < 3) : (k += 1) reads[k] = Reg.from(tc.args_reg + k);
        n_reads.* = tc.n_args;
        if (isScalarRt(typeAt(types, tc.dst))) def.* = tc.dst;
        return;
    }
    // A trampolined member call reads scalar args and a scalar receiver. Object
    // receivers remain in frame registers for the host callback.
    if (trampolinableMemberOf(module, inst)) |mc| {
        const recv_scalar: usize = if (isScalarRt(typeAt(types, mc.recv))) 1 else 0;
        if (recv_scalar != 0) reads[0] = mc.recv;
        var k: u8 = 0;
        while (k < mc.n_args and k < 3) : (k += 1) {
            reads[recv_scalar + k] = Reg.from(mc.args_reg + k);
        }
        n_reads.* = recv_scalar + @as(usize, mc.n_args);
        if (isScalarRt(typeAt(types, mc.dst))) def.* = mc.dst;
        return;
    }
    // A trampolined field read takes no scalar inputs (the receiver stays boxed);
    // its dst is a scalar def only for a scalar field (an object field's dst is a
    // boxed register, not in the scalar sets).
    if (trampolinableFieldOf(module, inst)) |fld| {
        n_reads.* = 0;
        if (isScalarRt(typeAt(types, fld.dst))) def.* = fld.dst;
        return;
    }
    // A field store reads the scalar value (the receiver stays boxed); no def.
    if (trampolinableFieldSetOf(module, inst)) |fs| {
        reads[0] = fs.value;
        n_reads.* = 1;
        return;
    }
    // A trampolined value call reads its scalar args (the callee stays boxed in a
    // register); its result is discarded, so it has no scalar def.
    if (trampolinableCallValueOf(inst)) |cvc| {
        var k: u8 = 0;
        while (k < cvc.n_args and k < 3) : (k += 1) reads[k] = Reg.from(cvc.args_reg + k);
        n_reads.* = cvc.n_args;
        return;
    }
    if (trampolinableGlobalOf(module, inst) != null) return;
    switch (inst.*) {
        .Const => |c| def.* = c.dst,
        .Move => |m| {
            // An object move copies a boxed register; neither side is a scalar.
            if (typeAt(types, m.dst) == .object or typeAt(types, m.src) == .object) return;
            reads[0] = m.src;
            n_reads.* = 1;
            def.* = m.dst;
        },
        .BinOp => |b| {
            // An object null test reads boxed registers (not scalars); only its
            // boolean dst is a scalar def.
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
        // The cell register is unboxed at entry / reboxed at exit by the cell
        // machinery (not the scalar read/def sets), so it is not reported here.
        .CellGet => |cg| def.* = cg.dst,
        .CellSet => |cs| {
            reads[0] = cs.value;
            n_reads.* = 1;
        },
        else => {},
    }
}

const LoopSets = struct { read: []bool, def: []bool };

fn computeSets(a: Allocator, module: *const Module, func: *const Func, body: []const BlockId, header: BlockId, n_regs: u32, types: []const RegType) Allocator.Error!LoopSets {
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
        var reads: [4]Reg = undefined;
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
    var succ: std.ArrayListUnmanaged(BlockId) = .empty;
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

// --- compilation ------------------------------------------------------------

const Compiler = struct {
    a: Allocator,
    module: *const Module,
    func: *const Func,
    body: []const BlockId,
    types: []const RegType,
    array_info: []const ?ArrayInfo,
    cell_info: []const ?RegType,
    call_sites: []const CallSite,
    inline_sites: []const InlineSite,
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
    param_slot_base: u32 = 0,
    n_params: u32 = 0,
    result_slot: u32 = 0,
    em: jit.Emitter,
    block_label: []?jit.Label,
    exit_targets: std.ArrayListUnmanaged(BlockId),
    exit_labels: std.ArrayListUnmanaged(jit.Label),
    deopt_codes: std.ArrayListUnmanaged(u64),
    deopt_labels: std.ArrayListUnmanaged(jit.Label),
    epilogue: jit.Label,
    cur_block: BlockId = undefined,
    cur_inst: u32 = 0,

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
        const code = encodeResume(self.cur_block, self.cur_inst);
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
    fn emitInlinedCall(self: *Compiler, site: *const InlineSite) !void {
        const callee_blk = &site.callee.blocks[0];
        // Member inline: argument i is the (i-1)-th call argument (index 0 is the
        // receiver); a `this`-field access is one of the registered field sites,
        // emitted in body order.
        var field_n: u32 = 0;
        for (callee_blk.insts) |*ci| {
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
                    try self.emitCallSite(site.field_site_base + field_n);
                    field_n += 1;
                    continue;
                }
            }
            const rinst = remapInst(ci.*, site.base);
            try self.emitInstBody(&rinst);
        }
        if (site.has_result) {
            const ret = callee_blk.terminator.Return.?;
            try self.loadSlot(T0, Reg.from(site.base + ret.int()));
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
            // Tag guard: the field value must still hold the expected scalar kind.
            try self.em.loadMemB(T0, T1, tag_off);
            try self.em.cmpImm32(T0, site.tag);
            try self.em.jcc(.ne, try self.deoptLabel());
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
        if (self.inlineSiteAt()) |site| {
            try self.emitInlinedCall(site);
            return;
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
                if (maybe_reg) |r| {
                    try self.loadSlot(T0, r);
                    try self.em.storeMem(REGS, @intCast(@as(u64, self.result_slot) * 8), T0);
                }
                try self.em.movImm64(.rax, returnCode());
                try self.em.jmp(self.epilogue);
            },
            else => return jit.JitError.Unsupported,
        }
    }

    fn run(self: *Compiler) !void {
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

/// Try to compile the natural loop whose header is `header`, specializing array
/// accesses on the kinds observed in `regs` (the live frame). Returns a compiled
/// loop, or null if the loop is not a supported shape.
pub fn tryCompile(a: Allocator, module: *const Module, func: *const Func, header: BlockId, regs: []const Value, resolver: ?MemberResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver, resolver_user: ?*anyopaque, transient: *bool) Allocator.Error!?CompiledLoop {
    const body = (try collectLoop(a, func, header)) orelse return null;
    defer a.free(body);

    // Reject try-regions: deopt resumes mid-block, so we must not need to
    // re-establish catch/finally scope.
    var unsupported_shape = false;
    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        if (blk.catches.len != 0 or blk.finally != null) return null;
        switch (blk.terminator) {
            .Goto, .Branch => {},
            else => return null,
        }
        for (blk.insts) |*inst| {
            if (arrayOpOf(module, inst) != null) continue;
            if (numericConvOf(module, inst) != null) continue;
            if (bitwiseOpOf(module, inst) != null) continue;
            if (trampolinableCallOf(inst) != null) continue;
            if (trampolinableMemberOf(module, inst) != null) continue;
            if (trampolinableFieldOf(module, inst) != null) continue;
            if (trampolinableFieldSetOf(module, inst) != null) continue;
            if (trampolinableCallValueOf(inst) != null) continue;
            if (trampolinableGlobalOf(module, inst) != null) continue;
            switch (inst.*) {
                .Const, .Move, .BinOp, .Not, .UnOp, .Trace, .CellGet, .CellSet => {},
                else => {
                    if (debugEnabled()) std.debug.print("[jit]   uncompilable inst {s} in {s} b{d}\n", .{ @tagName(inst.*), func.name, bid.int() });
                    unsupported_shape = true;
                },
            }
        }
    }
    if (unsupported_shape) return null;
    if (debugEnabled()) std.debug.print("[jit]   shape accepted for {s} b{d}\n", .{ func.name, header.int() });

    const n_regs: u32 = func.n_locals;

    // Discover indexed arrays, specializing on the kinds in the live frame.
    const array_info = try a.alloc(?ArrayInfo, n_regs);
    defer a.free(array_info);
    @memset(array_info, null);
    var arrays: std.ArrayListUnmanaged(ArrayUnbox) = .empty;
    defer arrays.deinit(a);
    for (body) |bid| {
        for (func.blocks[bid.int()].insts) |*inst| {
            const op = arrayOpOf(module, inst) orelse continue;
            const rr = op.recv;
            if (rr.int() >= n_regs or rr.int() >= regs.len) return null;
            if (array_info[rr.int()] != null) continue;
            const v = regs[rr.int()];
            // Only a packed primitive array gets the native indexed path. A
            // non-packed receiver (a `List`/reference `Array` of objects, or a
            // `Map`) is left for the object-subscript / map paths; a non-packed
            // `set` is compilable only for a `Map`.
            const packed_ok = v == .Array and v.Array.prim != null and v.Array.storage == .scalars;
            if (!packed_ok) {
                if (op.is_set and v != .Map) return null;
                continue;
            }
            const kind = v.Array.prim.?;
            const shape = arrayElemShape(kind) orelse return null;
            const k: u32 = @intCast(arrays.items.len);
            array_info[rr.int()] = .{
                .rt = shape.rt,
                .w = shape.w,
                .esize = shape.esize,
                .ptr_slot = n_regs + 2 * k,
                .len_slot = n_regs + 2 * k + 1,
            };
            arrays.append(a, .{ .reg = rr, .kind = kind, .ptr_slot = n_regs + 2 * k, .len_slot = n_regs + 2 * k + 1 }) catch return null;
        }
    }

    // Inline small pure-scalar top-level callees: their single block is spliced in
    // place of the call, with registers shifted into an extended register space
    // [n_regs .. total_regs). Restricted to array-free loops so the slot layout
    // stays a simple register range followed by the call/nullable slots.
    var inline_sites: std.ArrayListUnmanaged(InlineSite) = .empty;
    defer inline_sites.deinit(a);
    var total_regs: u32 = n_regs;
    if (arrays.items.len == 0) {
        for (body) |bid| {
            for (func.blocks[bid.int()].insts, 0..) |*inst, ii| {
                if (trampolinableCallOf(inst)) |tc| {
                    const callee = module.funcById(tc.func) orelse continue;
                    if (!inlinableCallee(module, callee)) continue;
                    if (callee.params.len != tc.n_args) continue;
                    inline_sites.append(a, .{
                        .block = bid,
                        .inst = @intCast(ii),
                        .callee = callee,
                        .base = total_regs,
                        .args_reg = tc.args_reg,
                        .n_args = tc.n_args,
                        .dst = tc.dst,
                    }) catch return null;
                    total_regs += callee.n_locals;
                    if (total_regs > 4096) return null;
                    continue;
                }
                // Member call to a small `this`-field/scalar method: inline it.
                // Only for a loop-invariant receiver — inlining resolves one method
                // body, so a varying (polymorphic) receiver must keep dynamic dispatch.
                if (trampolinableMemberOf(module, inst)) |mc| {
                    if (mc.resolved != null or mc.dispatch_recv != null) continue;
                    if (resolver == null or field_resolver == null) continue;
                    if (mc.recv.int() >= regs.len or regs[mc.recv.int()] != .Instance) continue;
                    if (regWrittenInBody(func, body, mc.recv)) continue;
                    var av: [3]Value = undefined;
                    var k: u8 = 0;
                    while (k < mc.n_args and k < 3) : (k += 1) {
                        if (mc.args_reg + k >= regs.len) break;
                        av[k] = regs[mc.args_reg + k];
                    }
                    const fid = resolver.?(resolver_user.?, &regs[mc.recv.int()], mc.name, av[0..mc.n_args]) orelse continue;
                    const callee = module.funcById(fid) orelse continue;
                    var this_reg: u32 = 0;
                    if (!inlinableMemberCallee(module, callee, &this_reg)) continue;
                    if (callee.params.len != @as(usize, mc.n_args) + 1) continue; // receiver + args
                    // If the method writes a field, every field it reads must be a
                    // non-nullable scalar so the read can never deopt — otherwise a
                    // deopt would re-run the call and double an already-applied write.
                    var has_write = false;
                    for (callee.blocks[0].insts) |*ci| {
                        if (trampolinableFieldSetOf(module, ci) != null) has_write = true;
                    }
                    if (has_write) {
                        if (field_nn_resolver == null) continue;
                        var read_ok = true;
                        for (callee.blocks[0].insts) |*ci| {
                            if (trampolinableFieldOf(module, ci)) |fld| {
                                if (field_nn_resolver.?(resolver_user.?, &regs[mc.recv.int()], memberFieldName(fld.name)) == null) {
                                    read_ok = false;
                                    break;
                                }
                            }
                        }
                        if (!read_ok) continue;
                    }
                    if (debugEnabled()) std.debug.print("[jit]   inlining member {s}\n", .{callee.name});
                    const has_result = callee.blocks[0].terminator.Return != null;
                    inline_sites.append(a, .{
                        .block = bid,
                        .inst = @intCast(ii),
                        .callee = callee,
                        .base = total_regs,
                        .args_reg = mc.args_reg,
                        .n_args = mc.n_args,
                        .dst = mc.dst,
                        .is_member = true,
                        .recv_reg = mc.recv.int(),
                        .this_reg = this_reg,
                        .has_result = has_result,
                    }) catch return null;
                    total_regs += callee.n_locals;
                    if (total_regs > 4096) return null;
                }
            }
        }
    }
    const arr_slots: u32 = total_regs + 2 * @as(u32, @intCast(arrays.items.len));

    // Discover capture cells, specializing on the scalar kind each box holds in
    // the live frame. The cached scalar reuses the cell register's own slot, so
    // no extra slots are needed. Reject if two cell registers alias the same box
    // (caching + write-back would diverge from the shared-box interpreter).
    const cell_info = try a.alloc(?RegType, n_regs);
    defer a.free(cell_info);
    @memset(cell_info, null);
    var cells: std.ArrayListUnmanaged(CellUnbox) = .empty;
    defer cells.deinit(a);
    var cell_ptrs: std.ArrayListUnmanaged(usize) = .empty;
    defer cell_ptrs.deinit(a);
    for (body) |bid| {
        for (func.blocks[bid.int()].insts) |*inst| {
            const cr: Reg = switch (inst.*) {
                .CellGet => |cg| cg.cell,
                .CellSet => |cs| cs.cell,
                else => continue,
            };
            if (cr.int() >= n_regs or cr.int() >= regs.len) return null;
            if (cell_info[cr.int()] != null) continue;
            if (array_info[cr.int()] != null) return null; // can't be both
            const v = regs[cr.int()];
            if (v != .Cell) return null;
            const g = v.Cell.borrow();
            const inner = g.get().*;
            g.deinit();
            const rt = cellScalarType(inner) orelse return null;
            const box_ptr = v.Cell.identity();
            for (cell_ptrs.items) |p| if (p == box_ptr) return null; // aliased box
            cell_ptrs.append(a, box_ptr) catch return null;
            cell_info[cr.int()] = rt;
            cells.append(a, .{ .reg = cr, .rt = rt }) catch return null;
        }
    }

    // Resolve each dynamic member call's result type against its live receiver;
    // exact member calls carry the declaration identity in IR.
    const member_ret = try a.alloc(RegType, n_regs);
    defer a.free(member_ret);
    @memset(member_ret, .unknown);
    const field_idx_of = try a.alloc(u32, n_regs);
    defer a.free(field_idx_of);
    @memset(field_idx_of, 0);
    // Registers that are a `Map[key]` get result: a nullable scalar (the map's
    // value type, or null when absent). Folded into the nullable set below.
    const map_get_dst = try a.alloc(bool, n_regs);
    defer a.free(map_get_dst);
    @memset(map_get_dst, false);
    for (body) |bid| {
        for (func.blocks[bid.int()].insts) |*inst| {
            if (trampolinableMemberOf(module, inst)) |mc| {
                if (arrays.items.len != 0) return null;
                if (mc.recv.int() >= n_regs or mc.recv.int() >= regs.len) return null;
                var av: [3]Value = undefined;
                var k: u8 = 0;
                while (k < mc.n_args) : (k += 1) {
                    const ar = mc.args_reg + k;
                    if (ar >= regs.len) return null;
                    av[k] = regs[ar];
                }
                if (mc.resolved) |fid| {
                    if (module.funcById(fid)) |f| {
                        if (f.is_suspend) return null;
                        if (mc.dst.int() < n_regs) {
                            member_ret[mc.dst.int()] = funcReturnRegType(module, f);
                        }
                    }
                } else if (regs[mc.recv.int()] == .Instance and resolver != null) {
                    if (resolver.?(resolver_user.?, &regs[mc.recv.int()], mc.name, av[0..mc.n_args])) |fid| {
                        if (module.funcById(fid)) |f| {
                            if (f.is_suspend) return null;
                            if (mc.dst.int() < n_regs) member_ret[mc.dst.int()] = funcReturnRegType(module, f);
                        }
                    }
                }
                // Intrinsic/callable/continuation receivers have no FuncId to
                // inspect. Specialize the boxed result from the live loop state;
                // the callback validates that kind on every invocation.
                if (mc.dst.int() < n_regs and member_ret[mc.dst.int()] == .unknown and mc.dst.int() < regs.len) {
                    if (liveValueRegType(regs[mc.dst.int()])) |rt| member_ret[mc.dst.int()] = rt;
                }
                continue;
            }
            if (trampolinableFieldOf(module, inst)) |fld| {
                if (field_resolver == null or arrays.items.len != 0) return null;
                if (fld.recv.int() >= n_regs or fld.recv.int() >= regs.len) return null;
                if (regs[fld.recv.int()] != .Instance) {
                    // Receiver snapshot null/non-instance — retry on a later snapshot.
                    transient.* = true;
                    return null;
                }
                const idx = field_resolver.?(resolver_user.?, &regs[fld.recv.int()], fld.name) orelse return null;
                const g = regs[fld.recv.int()].Instance.borrow();
                const fv: ?Value = if (idx < g.get().fields.items.len) g.get().fields.items[idx].value else null;
                g.deinit();
                // A scalar field types its dst as that scalar; an instance field
                // types it `.object` (the read writes the boxed value into regs). A
                // null/unclassifiable snapshot is transient — retry later.
                const rt = if (fv) |v| (liveValueRegType(v) orelse {
                    transient.* = true;
                    return null;
                }) else {
                    transient.* = true;
                    return null;
                };
                if (fld.dst.int() >= n_regs) return null;
                member_ret[fld.dst.int()] = rt;
                field_idx_of[fld.dst.int()] = idx;
                continue;
            }
            // Object collection subscript / map subscript: a `get`/`set` on a
            // non-packed receiver. A `Map` receiver routes to the map paths; a
            // `List`/reference `Array` element that is an instance routes to the
            // object subscript.
            if (arrayOpOf(module, inst)) |op| {
                if (op.recv.int() >= n_regs or array_info[op.recv.int()] != null) continue; // packed -> native
                if (op.recv.int() >= regs.len) return null;
                if (regs[op.recv.int()] == .Map) {
                    // Map get types its dst as a nullable scalar (the value type);
                    // map set has no result. Key/value must be scalar.
                    const vt = liveMapValueType(regs[op.recv.int()]) orelse {
                        transient.* = true; // empty map snapshot or non-scalar value
                        return null;
                    };
                    if (op.is_set) continue; // validated in the collection pass
                    if (op.dst.int() >= n_regs) return null;
                    member_ret[op.dst.int()] = vt;
                    map_get_dst[op.dst.int()] = true;
                    continue;
                }
                if (op.is_set) continue;
                if (op.index.int() >= regs.len or op.dst.int() >= n_regs) return null;
                const idx_v = regs[op.index.int()];
                const idx_i: i64 = switch (idx_v) {
                    .Int => |x| x,
                    .Long => |x| x,
                    else => {
                        transient.* = true;
                        return null;
                    },
                };
                const elem = liveElementAt(regs[op.recv.int()], idx_i) orelse {
                    transient.* = true;
                    return null;
                };
                if (liveValueRegType(elem) != .object) return null;
                member_ret[op.dst.int()] = .object;
            }
        }
    }
    if (debugEnabled()) std.debug.print("[jit]   runtime types sampled for {s} b{d}\n", .{ func.name, header.int() });

    // Whole-function type inference must run before liveness so the read/def sets
    // can recognize object registers (held in `regs`, not slots) and exclude them.
    const types = if (total_regs == n_regs)
        try inferTypes(a, module, func, n_regs, array_info, cell_info, regs, member_ret)
    else ext_blk: {
        const caller_types = try inferTypes(a, module, func, n_regs, array_info, cell_info, regs, member_ret);
        defer a.free(caller_types);
        const ext = a.alloc(RegType, total_regs) catch return null;
        @memset(ext, .unknown);
        @memcpy(ext[0..n_regs], caller_types);
        for (inline_sites.items) |*site| try fillInlineTypes(a, module, site, caller_types, ext, field_resolver, resolver_user, regs);
        break :ext_blk ext;
    };
    var ok = false;
    defer if (!ok) a.free(types);
    if (debugEnabled()) std.debug.print("[jit]   types inferred for {s} b{d}\n", .{ func.name, header.int() });

    // Original value kind each `.i32` register boxes back to (see `box_tags`).
    // Live-in registers keep their sampled kind; an in-loop definition
    // overrides it — `Int` unless the defining instruction names the kind (a
    // resolved callee's declared `Char`/`Short`/`Byte` return, a `Const`).
    const tags = a.alloc(u8, total_regs) catch return null;
    var tags_ok = false;
    defer if (!tags_ok) a.free(tags);
    @memset(tags, INT_TAG);
    {
        const T = std.meta.Tag(Value);
        for (regs[0..@min(regs.len, n_regs)], 0..) |v, i| {
            switch (v) {
                .Char => tags[i] = @intFromEnum(@as(T, .Char)),
                .Short => tags[i] = @intFromEnum(@as(T, .Short)),
                .Byte => tags[i] = @intFromEnum(@as(T, .Byte)),
                else => {},
            }
        }
        for (body) |bid| {
            for (func.blocks[bid.int()].insts) |*inst| {
                const def = instAnyDst(inst) orelse continue;
                if (def.int() >= total_regs) continue;
                var t: u8 = INT_TAG;
                switch (inst.*) {
                    .Move => |mv| {
                        if (mv.src.int() < total_regs) t = tags[mv.src.int()];
                    },
                    .Const => |c2| {
                        if (c2.value.int() < module.consts.items.len) {
                            switch (module.consts.items[c2.value.int()]) {
                                .Char => t = @intFromEnum(@as(T, .Char)),
                                .Short => t = @intFromEnum(@as(T, .Short)),
                                .Byte => t = @intFromEnum(@as(T, .Byte)),
                                else => {},
                            }
                        }
                    },
                    else => {
                        if (trampolinableMemberOf(module, inst)) |mc| {
                            if (mc.resolved) |fid| {
                                if (module.funcById(fid)) |f2| {
                                    const rn = f2.return_ty.name;
                                    if (std.mem.eql(u8, rn, "Char")) {
                                        t = @intFromEnum(@as(T, .Char));
                                    } else if (std.mem.eql(u8, rn, "Short")) {
                                        t = @intFromEnum(@as(T, .Short));
                                    } else if (std.mem.eql(u8, rn, "Byte")) {
                                        t = @intFromEnum(@as(T, .Byte));
                                    }
                                }
                            }
                        }
                    },
                }
                tags[def.int()] = t;
            }
        }
    }

    // A cell register's slot caches a scalar, so it must not be read or written
    // as a plain scalar anywhere in the loop (only via CellGet/CellSet). Reject
    // if any other instruction (or a branch cond) touches a cell register.
    {
        var reads: [4]Reg = undefined;
        var nr: usize = 0;
        var df: ?Reg = null;
        for (body) |bid| {
            const blk = &func.blocks[bid.int()];
            for (blk.insts) |*inst| {
                instReadsDef(module, inst, &reads, &nr, &df, types);
                for (reads[0..nr]) |rr| {
                    if (rr.int() < n_regs and cell_info[rr.int()] != null) return null;
                }
                if (df) |dd| if (dd.int() < n_regs and cell_info[dd.int()] != null) return null;
            }
            switch (blk.terminator) {
                .Branch => |br| if (br.cond.int() < n_regs and cell_info[br.cond.int()] != null) return null,
                else => {},
            }
        }
    }

    const sets = if (total_regs == n_regs)
        try computeSets(a, module, func, body, header, n_regs, types)
    else sets_blk: {
        const s = try computeSets(a, module, func, body, header, n_regs, types);
        defer {
            a.free(s.read);
            a.free(s.def);
        }
        // Extend with the inlined-callee registers (always scratch: never unboxed
        // from or reboxed to the frame's register array).
        const rd = a.alloc(bool, total_regs) catch return null;
        @memset(rd, false);
        @memcpy(rd[0..n_regs], s.read);
        const df = a.alloc(bool, total_regs) catch return null;
        @memset(df, false);
        @memcpy(df[0..n_regs], s.def);
        break :sets_blk LoopSets{ .read = rd, .def = df };
    };
    defer if (!ok) {
        a.free(sets.read);
        a.free(sets.def);
    };
    if (debugEnabled()) std.debug.print("[jit]   liveness computed for {s} b{d}\n", .{ func.name, header.int() });

    // Array-receiver regs are unboxed as arrays, not scalars; exclude them from
    // the scalar read/def sets and the scalar type requirement.
    for (arrays.items) |au| {
        sets.read[au.reg.int()] = false;
        sets.def[au.reg.int()] = false;
    }
    // Cell regs are unboxed/reboxed through their box, not the scalar sets.
    for (cells.items) |cu| {
        sets.read[cu.reg.int()] = false;
        sets.def[cu.reg.int()] = false;
    }
    // Object regs live in `regs` (a GC root), never in a slot — exclude them.
    for (0..n_regs) |r| {
        if (types[r] == .object) {
            sets.read[r] = false;
            sets.def[r] = false;
        }
    }

    // Nullable-scalar registers: a register merged from a `null` literal and a
    // scalar value. It is typed as its scalar kind but may hold null at run time,
    // tracked by a companion flag slot. Detect them (a `Move` from a `Const null`
    // into a scalar-typed register) and exclude from the scalar read/def sets —
    // a flag-aware unbox/rebox replaces the plain scalar one.
    const nullable = try a.alloc(bool, n_regs);
    defer a.free(nullable);
    @memset(nullable, false);
    {
        const is_null_const = try a.alloc(bool, n_regs);
        defer a.free(is_null_const);
        @memset(is_null_const, false);
        for (body) |bid| for (func.blocks[bid.int()].insts) |*inst| {
            if (inst.* == .Const) {
                const c = inst.Const;
                if (c.dst.int() < n_regs and module.consts.items[c.value.int()] == .Null) is_null_const[c.dst.int()] = true;
            }
        };
        for (body) |bid| for (func.blocks[bid.int()].insts) |*inst| {
            if (inst.* == .Move) {
                const m = inst.Move;
                if (m.dst.int() < n_regs and m.src.int() < n_regs and is_null_const[m.src.int()] and isScalarRt(types[m.dst.int()]))
                    nullable[m.dst.int()] = true;
            }
        };
    }
    // A `Map[key]` result is also a nullable scalar.
    for (0..n_regs) |r| {
        if (map_get_dst[r] and isScalarRt(types[r])) nullable[r] = true;
    }
    var nullables: std.ArrayListUnmanaged(NullableUnbox) = .empty;
    defer nullables.deinit(a);
    const null_flag_slot = try a.alloc(u32, n_regs);
    defer a.free(null_flag_slot);
    @memset(null_flag_slot, 0);
    for (0..n_regs) |r| {
        if (!nullable[r]) continue;
        nullables.append(a, .{ .reg = Reg.from(@intCast(r)), .rt = types[r], .flag_slot = 0, .live_in = sets.read[r], .live_out = sets.def[r] }) catch return null;
        sets.read[r] = false;
        sets.def[r] = false;
    }

    for (0..n_regs) |r| {
        if ((sets.read[r] or sets.def[r]) and types[r] == .unknown) {
            if (debugEnabled()) std.debug.print("[jit]   bail: reg {d} read/def but unknown type in {s}\n", .{ r, func.name });
            return null;
        }
    }

    // Collect and validate trampolined call sites. A call may run arbitrary code
    // (and a GC), so a loop that also indexes arrays is rejected: the array buffer
    // pointer is cached in a slot and a callee could resize the backing store,
    // leaving the cache stale. Capture cells are safe to combine with calls — the
    // callee receives reboxed scalar args, never a reference to the caller's box,
    // and the cached scalar lives in a slot written back only at loop exit.
    var call_sites: std.ArrayListUnmanaged(CallSite) = .empty;
    defer call_sites.deinit(a);
    for (body) |bid| {
        const blk_insts = func.blocks[bid.int()].insts;
        for (blk_insts, 0..) |*inst, i| {
            const is_call = trampolinableCallOf(inst) != null;
            const is_member = trampolinableMemberOf(module, inst) != null;
            const is_field = trampolinableFieldOf(module, inst) != null;
            const is_obj_move = switch (inst.*) {
                .Move => |m| typeAt(types, m.dst) == .object or typeAt(types, m.src) == .object,
                else => false,
            };
            const is_null_check = switch (inst.*) {
                .BinOp => |b| isNullCheckBinOp(types, b),
                else => false,
            };
            const map_op = if (arrayOpOf(module, inst)) |op| (op.recv.int() < regs.len and regs[op.recv.int()] == .Map) else false;
            const is_obj_index = if (arrayOpOf(module, inst)) |op| (!op.is_set and !map_op and typeAt(types, op.dst) == .object) else false;
            const is_map_get = if (arrayOpOf(module, inst)) |op| (map_op and !op.is_set) else false;
            const is_map_set = if (arrayOpOf(module, inst)) |op| (map_op and op.is_set) else false;
            const is_call_value = trampolinableCallValueOf(inst) != null;
            const is_load_global = trampolinableGlobalOf(module, inst) != null;
            const is_field_set = trampolinableFieldSetOf(module, inst) != null;
            if (!is_call and !is_member and !is_field and !is_field_set and !is_obj_move and !is_null_check and !is_obj_index and !is_call_value and !is_load_global and !is_map_get and !is_map_set) continue;
            if (arrays.items.len != 0) {
                if (debugEnabled()) std.debug.print("[jit]   bail: call + {d} arrays in {s}\n", .{ arrays.items.len, func.name });
                return null;
            }
            // Every scalar arg must already live in a typed slot (field reads have none).
            const args_reg: u32 = if (is_call) trampolinableCallOf(inst).?.args_reg else if (is_member) trampolinableMemberOf(module, inst).?.args_reg else if (is_call_value) trampolinableCallValueOf(inst).?.args_reg else 0;
            const n_args: u32 = if (is_call) trampolinableCallOf(inst).?.n_args else if (is_member) trampolinableMemberOf(module, inst).?.n_args else if (is_call_value) trampolinableCallValueOf(inst).?.n_args else 0;
            var k: u8 = 0;
            while (k < n_args) : (k += 1) {
                const ar = args_reg + k;
                if (ar >= n_regs or !(isScalarRt(types[ar]) or types[ar] == .object or types[ar] == .null_)) {
                    if (debugEnabled()) std.debug.print("[jit]   bail: call arg reg {d} type {s} in {s}\n", .{ ar, @tagName(types[ar]), func.name });
                    return null;
                }
            }
            // Nearest preceding `.Trace` gives the call's source span.
            var span: ?ir.Span = null;
            var bj: usize = i;
            while (bj > 0) {
                bj -= 1;
                if (blk_insts[bj] == .Trace) {
                    span = blk_insts[bj].Trace.span;
                    break;
                }
            }
            // Per-arg live-tag source through the move chain (see
            // `CallSite.arg_tag_regs`).
            var arg_tag_regs: [3]u32 = .{ 0, 0, 0 };
            {
                var q: u8 = 0;
                while (q < n_args and q < 3) : (q += 1) {
                    arg_tag_regs[q] = argTagSourceReg(blk_insts, i, args_reg + q);
                }
            }
            if (is_load_global) {
                const lg = trampolinableGlobalOf(module, inst).?;
                if (lg.dst.int() >= n_regs) return null;
                call_sites.append(a, .{
                    .dst_reg = lg.dst.int(),
                    .name = lg.name,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_load_global = true,
                }) catch return null;
            } else if (is_map_set) {
                // Map store `map[key] = value` (loop-invariant map, scalar key+value).
                const op = arrayOpOf(module, inst).?;
                if (op.recv.int() >= n_regs or op.index.int() >= n_regs or op.value.int() >= n_regs) return null;
                if (!isScalarRt(typeAt(types, op.index)) or !isScalarRt(typeAt(types, op.value))) return null;
                if (sets.def[op.recv.int()]) return null; // map must be loop-invariant
                call_sites.append(a, .{
                    .dst_reg = 0,
                    .recv_reg = op.recv.int(),
                    .args_reg = op.index.int(),
                    .src_reg = op.value.int(),
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_map_set = true,
                }) catch return null;
            } else if (is_map_get) {
                // Map load `map[key]` -> nullable scalar (loop-invariant map, scalar key).
                const op = arrayOpOf(module, inst).?;
                if (op.recv.int() >= n_regs or op.index.int() >= n_regs or op.dst.int() >= n_regs) return null;
                if (!isScalarRt(typeAt(types, op.index))) return null;
                if (sets.def[op.recv.int()]) return null;
                call_sites.append(a, .{
                    .recv_reg = op.recv.int(),
                    .args_reg = op.index.int(),
                    .dst_reg = op.dst.int(),
                    .has_result = true,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_map_get = true,
                }) catch return null;
            } else if (is_call_value) {
                // Invoke a loop-invariant callable value; the result is discarded.
                const cvc = trampolinableCallValueOf(inst).?;
                if (cvc.callee.int() >= n_regs or cvc.callee.int() >= regs.len) return null;
                if (!isCallableValue(regs[cvc.callee.int()])) return null;
                // The callable must be loop-invariant: never written in the body.
                if (sets.def[cvc.callee.int()] or typeAt(types, cvc.callee) != .unknown) return null;
                call_sites.append(a, .{
                    .recv_reg = cvc.callee.int(),
                    .args_reg = cvc.args_reg,
                    .n_args = cvc.n_args,
                    .dst_reg = cvc.dst.int(),
                    .has_result = false,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .arg_tag_regs = arg_tag_regs,
                    .is_call_value = true,
                }) catch return null;
            } else if (is_obj_index) {
                // Object collection subscript: a `get` whose element is a boxed
                // object. The collection is the (loop-invariant) receiver; the
                // index is a scalar slot register.
                const op = arrayOpOf(module, inst).?;
                if (op.recv.int() >= n_regs or op.index.int() >= n_regs or op.dst.int() >= n_regs) return null;
                if (!isScalarRt(typeAt(types, op.index))) return null;
                call_sites.append(a, .{
                    .dst_reg = op.dst.int(),
                    .recv_reg = op.recv.int(),
                    .args_reg = op.index.int(),
                    .n_args = 1,
                    .has_result = true,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_obj_index = true,
                }) catch return null;
            } else if (is_obj_move) {
                // Copy a boxed register into another (both live in `regs`).
                const m = inst.Move;
                if (m.dst.int() >= n_regs or m.src.int() >= n_regs) return null;
                call_sites.append(a, .{
                    .dst_reg = m.dst.int(),
                    .src_reg = m.src.int(),
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_obj_move = true,
                }) catch return null;
            } else if (is_null_check) {
                // Boxed equality / identity test -> boolean slot. Both operands
                // stay in the GC-rooted frame (a null literal is synthesized by
                // the callback rather than read from its unused scalar slot).
                const b = inst.BinOp;
                if (b.lhs.int() >= n_regs or b.rhs.int() >= n_regs or b.dst.int() >= n_regs) return null;
                call_sites.append(a, .{
                    .dst_reg = b.dst.int(),
                    .recv_reg = b.lhs.int(),
                    .src_reg = b.rhs.int(),
                    .has_result = true,
                    .neg = b.op == .NotEq or b.op == .IdentNeq,
                    .identity = b.op == .IdentEq or b.op == .IdentNeq,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_null_check = true,
                }) catch return null;
            } else if (is_field) {
                const fld = trampolinableFieldOf(module, inst).?;
                if (fld.recv.int() >= n_regs or fld.recv.int() >= regs.len or regs[fld.recv.int()] != .Instance) return null;
                // A loop-invariant receiver is covered by the entry class guard; a
                // boxed receiver that varies (a chain intermediate) re-checks its
                // class on every read.
                // A receiver typed `.object` is a boxed register that may be
                // reassigned in the loop (a chain cursor); re-check its class on
                // every read. A loop-invariant receiver is covered by the entry guard.
                const recv_varies = typeAt(types, fld.recv) == .object;
                const rrt = member_ret[fld.dst.int()];
                if (rrt == .unknown or fld.dst.int() >= n_regs or types[fld.dst.int()] != rrt) return null;
                call_sites.append(a, .{
                    .func = @enumFromInt(0),
                    .args_reg = 0,
                    .n_args = 0,
                    .dst_reg = fld.dst.int(),
                    .has_result = true,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .recv_reg = fld.recv.int(),
                    .recv_class = instanceClassIdentity(regs[fld.recv.int()]),
                    .is_field = true,
                    .field_idx = field_idx_of[fld.dst.int()],
                    .recv_varies = recv_varies,
                }) catch return null;
            } else if (is_field_set) {
                const fs = trampolinableFieldSetOf(module, inst).?;
                if (fs.recv.int() >= n_regs or fs.recv.int() >= regs.len or regs[fs.recv.int()] != .Instance) {
                    transient.* = true;
                    return null;
                }
                if (fs.value.int() >= n_regs or !(isScalarRt(typeAt(types, fs.value)) or typeAt(types, fs.value) == .object or typeAt(types, fs.value) == .null_)) return null;
                if (field_resolver == null) return null;
                const idx = field_resolver.?(resolver_user.?, &regs[fs.recv.int()], fs.name) orelse return null;
                const recv_varies = typeAt(types, fs.recv) == .object;
                call_sites.append(a, .{
                    .dst_reg = 0,
                    .src_reg = fs.value.int(),
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .recv_reg = fs.recv.int(),
                    .recv_class = instanceClassIdentity(regs[fs.recv.int()]),
                    .is_field_set = true,
                    .field_idx = idx,
                    .recv_varies = recv_varies,
                }) catch return null;
            } else if (is_call) {
                // An inlined call is emitted in place, not trampolined.
                var inlined = false;
                for (inline_sites.items) |s| {
                    if (s.block.int() == bid.int() and s.inst == i) {
                        inlined = true;
                        break;
                    }
                }
                if (inlined) continue;
                const tc = trampolinableCallOf(inst).?;
                const f = module.funcById(tc.func) orelse return null;
                // The callee must run as a plain interpreted call: no suspend
                // machinery, no implicit receiver to thread.
                if (f.is_suspend or f.has_receiver_param) {
                    if (debugEnabled()) std.debug.print("[jit]   bail: callee {s} suspend/receiver in {s}\n", .{ f.name, func.name });
                    return null;
                }
                const rrt = funcReturnRegType(module, f);
                const has_result = rrt != .unknown;
                if (has_result and (tc.dst.int() >= n_regs or types[tc.dst.int()] != rrt)) {
                    if (debugEnabled()) std.debug.print("[jit]   bail: call dst type mismatch in {s}\n", .{func.name});
                    return null;
                }
                call_sites.append(a, .{
                    .func = tc.func,
                    .args_reg = tc.args_reg,
                    .n_args = tc.n_args,
                    .dst_reg = tc.dst.int(),
                    .has_result = has_result,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .arg_tag_regs = arg_tag_regs,
                }) catch return null;
            } else {
                // An inlined member call is emitted in place, not trampolined.
                var inlined_m = false;
                for (inline_sites.items) |s| {
                    if (s.block.int() == bid.int() and s.inst == i) {
                        inlined_m = true;
                        break;
                    }
                }
                if (inlined_m) continue;
                const mc = trampolinableMemberOf(module, inst).?;
                if (mc.recv.int() >= n_regs or mc.recv.int() >= regs.len) return null;
                if (mc.dispatch_recv) |dispatch| {
                    if (dispatch.int() >= n_regs or dispatch.int() >= regs.len) return null;
                }
                // A loop-invariant receiver is validated once by the entry guard; a
                // boxed receiver that varies (a chain cursor) re-checks its class on
                // every call. Either way the host reads it straight from the frame.
                const recv_varies = typeAt(types, mc.recv) == .object;
                const rrt = member_ret[mc.dst.int()];
                const has_result = rrt != .unknown;
                if (has_result and (mc.dst.int() >= n_regs or types[mc.dst.int()] != rrt)) return null;
                call_sites.append(a, .{
                    .func = @enumFromInt(0),
                    .args_reg = mc.args_reg,
                    .n_args = mc.n_args,
                    .dst_reg = mc.dst.int(),
                    .has_result = has_result,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .arg_tag_regs = arg_tag_regs,
                    .is_member = true,
                    .recv_reg = mc.recv.int(),
                    .recv_tag_reg = argTagSourceReg(blk_insts, i, mc.recv.int()),
                    .name = mc.name,
                    .resolved_member = mc.resolved,
                    .dispatch_recv_reg = if (mc.dispatch_recv) |reg| reg.int() else null,
                    .recv_class = if (regs[mc.recv.int()] == .Instance) instanceClassIdentity(regs[mc.recv.int()]) else 0,
                    .recv_varies = recv_varies or regs[mc.recv.int()] != .Instance,
                }) catch return null;
            }
        }
    }
    // Register the field-access call sites for each member inline (the body's
    // `this`-field reads/writes), contiguously, so the inline emit can reference
    // them by index. They share the call's (block, inst) — a field mismatch deopts
    // to re-run the call.
    for (inline_sites.items) |*site| {
        if (!site.is_member) continue;
        site.field_site_base = @intCast(call_sites.items.len);
        var nf: u32 = 0;
        const recv_varies = typeAt(types, Reg.from(site.recv_reg)) == .object;
        const recv_class = instanceClassIdentity(regs[site.recv_reg]);
        for (site.callee.blocks[0].insts) |*ci| {
            if (trampolinableFieldOf(module, ci)) |fld| {
                const idx = field_resolver.?(resolver_user.?, &regs[site.recv_reg], memberFieldName(fld.name)) orelse return null;
                const dst = site.base + fld.dst.int();
                if (dst >= total_regs or !isScalarRt(types[dst])) return null;
                call_sites.append(a, .{
                    .dst_reg = dst,
                    .has_result = true,
                    .block = site.block,
                    .inst = site.inst,
                    .recv_reg = site.recv_reg,
                    .recv_class = recv_class,
                    .is_field = true,
                    .field_idx = idx,
                    .recv_varies = recv_varies,
                }) catch return null;
                nf += 1;
            } else if (trampolinableFieldSetOf(module, ci)) |fs| {
                const idx = field_resolver.?(resolver_user.?, &regs[site.recv_reg], memberFieldName(fs.name)) orelse return null;
                const src = site.base + fs.value.int();
                if (src >= total_regs or !isScalarRt(types[src])) return null;
                call_sites.append(a, .{
                    .dst_reg = 0,
                    .src_reg = src,
                    .block = site.block,
                    .inst = site.inst,
                    .recv_reg = site.recv_reg,
                    .recv_class = recv_class,
                    .is_field_set = true,
                    .field_idx = idx,
                    .recv_varies = recv_varies,
                }) catch return null;
                nf += 1;
            }
        }
        site.n_field_sites = nf;
    }

    const has_calls = call_sites.items.len != 0;
    const uc_slot: u32 = arr_slots; // arrays.len == 0 when has_calls, so == n_regs
    const tramp_slot: u32 = arr_slots + 1;
    const calls_base: u32 = arr_slots + (if (has_calls) @as(u32, 2) else 0);
    // One null-flag slot per nullable-scalar register, after the array and call slots.
    for (nullables.items, 0..) |*nu, i| {
        nu.flag_slot = calls_base + @as(u32, @intCast(i));
        null_flag_slot[nu.reg.int()] = nu.flag_slot;
    }
    const nullable_end: u32 = calls_base + @as(u32, @intCast(nullables.items.len));
    if (debugEnabled() and inline_sites.items.len != 0) std.debug.print("[jit]   inlined {d} call(s) in {s}\n", .{ inline_sites.items.len, func.name });
    // A map-get site writes the nullable result; record its dst's flag slot.
    for (call_sites.items) |*site| {
        if (site.is_map_get) site.map_flag_slot = null_flag_slot[site.dst_reg];
    }

    // Native field access: a loop-invariant scalar field read/write is emitted as a
    // direct memory access instead of a callback. One field-base pointer slot is
    // cached per receiver (after the nullable slots); the field's expected Value tag
    // is sampled from the live instance (a read deopts on a tag mismatch).
    var field_bases: std.ArrayListUnmanaged(FieldBase) = .empty;
    defer field_bases.deinit(a);
    for (call_sites.items) |*site| {
        if (!(site.is_field or site.is_field_set) or site.recv_varies) continue;
        if (site.recv_reg >= regs.len or regs[site.recv_reg] != .Instance) continue;
        const vreg: u32 = if (site.is_field) site.dst_reg else site.src_reg;
        const rt = typeAt(types, Reg.from(vreg));
        if (!isScalarRt(rt)) continue;
        // A nullable-scalar value uses a companion null-flag the native path does
        // not manage; keep it on the callback (which syncs the flag).
        if (vreg < nullable.len and nullable[vreg]) continue;
        const tag: u8 = blk: {
            const g = regs[site.recv_reg].Instance.borrow();
            defer g.deinit();
            if (site.field_idx >= g.get().fields.items.len) break :blk 0xff;
            break :blk @intFromEnum(@as(std.meta.Tag(Value), g.get().fields.items[site.field_idx].value));
        };
        if (tag == 0xff) continue;
        // Reuse an existing base slot for the same receiver.
        var ptr_slot: u32 = 0;
        var found = false;
        for (field_bases.items) |fb| {
            if (fb.recv_reg == site.recv_reg) {
                ptr_slot = fb.ptr_slot;
                found = true;
                break;
            }
        }
        if (!found) {
            ptr_slot = nullable_end + @as(u32, @intCast(field_bases.items.len));
            field_bases.append(a, .{ .recv_reg = site.recv_reg, .ptr_slot = ptr_slot }) catch return null;
        }
        site.native = true;
        site.fbase_slot = ptr_slot;
        site.tag = tag;
    }
    const n_slots: u32 = nullable_end + @as(u32, @intCast(field_bases.items.len));
    if (debugEnabled() and field_bases.items.len != 0) std.debug.print("[jit]   native field access on {d} receiver(s) in {s}\n", .{ field_bases.items.len, func.name });

    var c = Compiler{
        .a = a,
        .module = module,
        .func = func,
        .body = body,
        .types = types,
        .array_info = array_info,
        .cell_info = cell_info,
        .call_sites = call_sites.items,
        .inline_sites = inline_sites.items,
        .nullable = nullable,
        .null_flag_slot = null_flag_slot,
        .uc_slot = uc_slot,
        .tramp_slot = tramp_slot,
        .n_regs = n_regs,
        .reg_slots = total_regs,
        .val_payload_off = valuePayloadOffset(),
        .val_tag_off = valueTagOffset(),
        .em = jit.Emitter.init(a),
        .block_label = try a.alloc(?jit.Label, func.blocks.len),
        .exit_targets = .empty,
        .exit_labels = .empty,
        .deopt_codes = .empty,
        .deopt_labels = .empty,
        .epilogue = undefined,
    };
    defer c.em.deinit();
    defer a.free(c.block_label);
    defer c.exit_targets.deinit(a);
    defer c.exit_labels.deinit(a);
    defer c.deopt_codes.deinit(a);
    defer c.deopt_labels.deinit(a);
    @memset(c.block_label, null);

    for (body) |bid| c.block_label[bid.int()] = c.em.newLabel() catch return null;
    c.epilogue = c.em.newLabel() catch return null;

    c.run() catch |e| {
        if (debugEnabled()) std.debug.print("[jit]   bail: codegen {s} in {s}\n", .{ @errorName(e), func.name });
        return null;
    };

    const exec = jit.finalize(c.em.code()) catch return null;
    const arrays_owned = arrays.toOwnedSlice(a) catch return null;
    const cells_owned = cells.toOwnedSlice(a) catch {
        a.free(arrays_owned);
        return null;
    };
    const sites_owned = call_sites.toOwnedSlice(a) catch {
        a.free(arrays_owned);
        a.free(cells_owned);
        return null;
    };
    const nullables_owned = nullables.toOwnedSlice(a) catch {
        a.free(arrays_owned);
        a.free(cells_owned);
        a.free(sites_owned);
        return null;
    };
    const fbases_owned = field_bases.toOwnedSlice(a) catch {
        a.free(arrays_owned);
        a.free(cells_owned);
        a.free(sites_owned);
        a.free(nullables_owned);
        return null;
    };
    ok = true;
    tags_ok = true;
    return CompiledLoop{
        .exec = exec,
        // Inlined-callee registers extend the register space; the unbox/rebox
        // loops range over all of them (the inline ones are scratch — skipped).
        .n_regs = total_regs,
        .n_slots = n_slots,
        .reg_types = types,
        .box_tags = tags,
        .read_set = sets.read,
        .def_set = sets.def,
        .arrays = arrays_owned,
        .cells = cells_owned,
        .nullables = nullables_owned,
        .field_bases = fbases_owned,
        .call_sites = sites_owned,
        .uc_slot = uc_slot,
        .tramp_slot = tramp_slot,
        .allocator = a,
    };
}

// --- runtime entry / unbox / rebox ------------------------------------------

pub const Resume = struct { block: BlockId, inst: u32 };

pub const RunResult = union(enum) {
    resume_at: Resume,
    bail,
};

pub fn runLoop(self: *const CompiledLoop, regs: []Value, slots: []i64, tags: []u8, tramp: ?TrampFn, user: ?*anyopaque) RunResult {
    @memcpy(tags[0..self.n_regs], self.box_tags[0..self.n_regs]);
    var r: usize = 0;
    while (r < self.n_regs) : (r += 1) {
        slots[r] = 0;
        if (!self.read_set[r]) continue;
        if (r >= regs.len) return .bail;
        const v = regs[r];
        switch (self.reg_types[r]) {
            .i32 => switch (v) {
                .Int => |x| slots[r] = x,
                .Char => |x| {
                    slots[r] = x;
                    // A live-in char read-only in the loop reboxes as itself;
                    // a redefined register keeps its statically-derived kind.
                    if (!self.def_set[r]) tags[r] = @intFromEnum(@as(std.meta.Tag(Value), .Char));
                },
                .Short => |x| {
                    slots[r] = x;
                    if (!self.def_set[r]) tags[r] = @intFromEnum(@as(std.meta.Tag(Value), .Short));
                },
                .Byte => |x| {
                    slots[r] = x;
                    if (!self.def_set[r]) tags[r] = @intFromEnum(@as(std.meta.Tag(Value), .Byte));
                },
                else => return .bail,
            },
            .i64 => switch (v) {
                .Long => |x| slots[r] = x,
                else => return .bail,
            },
            .f64 => switch (v) {
                .Double => |x| slots[r] = @bitCast(x),
                else => return .bail,
            },
            .f32 => switch (v) {
                .Float => |x| slots[r] = @as(u32, @bitCast(x)),
                else => return .bail,
            },
            .boolean => switch (v) {
                .Bool => |b| slots[r] = if (b) 1 else 0,
                else => return .bail,
            },
            .unit => if (v != .Unit) return .bail,
            .null_ => if (v != .Null) return .bail,
            // Object registers are never slot-backed (excluded from read_set);
            // they stay in `regs`. Reaching here would be a bug, but it is safe.
            .object => {},
            .unknown => return .bail,
        }
    }

    // Unbox each indexed array's buffer pointer + length into its high slots.
    // The kind must still match; the buffer pointer is stable for the native run
    // (no resize inside the loop, no GC safepoint).
    for (self.arrays) |au| {
        if (au.reg.int() >= regs.len) return .bail;
        const v = regs[au.reg.int()];
        if (v != .Array or v.Array.prim != au.kind or v.Array.storage != .scalars) return .bail;
        const g = v.Array.storage.scalars.borrow();
        const pb = g.get();
        slots[au.ptr_slot] = @bitCast(@intFromPtr(pb.bytes.items.ptr));
        slots[au.len_slot] = @intCast(pb.len());
        g.deinit();
    }

    // Unbox each capture cell's scalar into the cell register's own slot. No
    // calls or GC run inside the loop, so the box is unobserved by anyone else;
    // the cached scalar is written back through the box at exit.
    for (self.cells) |cu| {
        if (cu.reg.int() >= regs.len) return .bail;
        const v = regs[cu.reg.int()];
        if (v != .Cell) return .bail;
        const g = v.Cell.borrow();
        const inner = g.get().*;
        g.deinit();
        slots[cu.reg.int()] = cellSlotIn(cu.rt, inner) orelse return .bail;
    }

    // Unbox each loop-carried nullable-scalar register: a null value sets its
    // flag slot, otherwise the scalar lands in the value slot with the flag clear.
    for (self.nullables) |nu| {
        if (!nu.live_in) continue;
        if (nu.reg.int() >= regs.len) return .bail;
        const v = regs[nu.reg.int()];
        if (v == .Null) {
            slots[nu.reg.int()] = 0;
            slots[nu.flag_slot] = 1;
        } else {
            slots[nu.reg.int()] = cellSlotIn(nu.rt, v) orelse return .bail;
            slots[nu.flag_slot] = 0;
        }
    }

    // A loop with trampolined calls needs its reserved slots wired before entry:
    // one holds the `*TrampCtx` the native call sites load into rdi, the other the
    // host callback. `tctx` is a stack local live across the whole native run.
    var tctx: TrampCtx = undefined;
    if (self.call_sites.len != 0) {
        if (tramp == null or user == null) return .bail;
        // Each member call's receiver must still be an Instance of the class the
        // site was compiled against; otherwise its method (and return type) could
        // differ this activation — deopt to the interpreter.
        for (self.call_sites) |site| {
            // Loop-invariant member / field receivers are validated once here; a
            // varying receiver is re-checked by its callback each iteration.
            if (site.recv_varies or site.recv_class == 0 or !(site.is_member or site.is_field or site.is_field_set)) continue;
            if (site.recv_reg >= regs.len) return .bail;
            const rv = regs[site.recv_reg];
            if (rv != .Instance or instanceClassIdentity(rv) != site.recv_class) return .bail;
        }
        // Cache each native-field receiver's field buffer pointer. The receiver is
        // an already-validated loop-invariant Instance; the buffer does not move or
        // resize inside the native run, so the pointer stays valid throughout.
        for (self.field_bases) |fb| {
            if (fb.recv_reg >= regs.len or regs[fb.recv_reg] != .Instance) return .bail;
            const g = regs[fb.recv_reg].Instance.borrow();
            slots[fb.ptr_slot] = @bitCast(@intFromPtr(g.get().fields.items.ptr));
            g.deinit();
        }
        tctx = .{ .slots = slots.ptr, .compiled = self, .user = user.?, .tags = tags.ptr };
        slots[self.uc_slot] = @bitCast(@intFromPtr(&tctx));
        slots[self.tramp_slot] = @bitCast(@intFromPtr(tramp.?));
    }

    const fnptr = self.exec.entry(*const fn ([*]i64) callconv(.c) u64);
    const code = fnptr(slots.ptr);
    const target = BlockId.from(@intCast(code >> 32));
    const inst: u32 = @truncate(code & 0xffff_ffff);

    r = 0;
    while (r < self.n_regs) : (r += 1) {
        if (!self.def_set[r]) continue;
        if (r >= regs.len) continue;
        regs[r] = switch (self.reg_types[r]) {
            .i32 => valueFromSlotTagged(.i32, tags[r], slots[r]),
            .i64 => .{ .Long = slots[r] },
            .f64 => .{ .Double = @bitCast(slots[r]) },
            .f32 => .{ .Float = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(slots[r]))))) },
            .boolean => .{ .Bool = slots[r] != 0 },
            .unit => .Unit,
            .null_ => .Null,
            // Object registers were written straight to `regs` by callbacks
            // (never slot-backed); keep the current value.
            .object => regs[r],
            .unknown => regs[r],
        };
    }

    // Write each cell's final cached scalar back through its box. The old inner
    // value is a primitive of the same kind, so its release is a no-op — and
    // its TAG is the kind the writeback must restore (a captured `Char` var
    // must not come back as an `Int`; cells are type-stable in Kotlin).
    for (self.cells) |cu| {
        if (cu.reg.int() >= regs.len) continue;
        const v = regs[cu.reg.int()];
        if (v != .Cell) continue;
        const g = v.Cell.borrowMut();
        const prev_tag: u8 = @intFromEnum(std.meta.activeTag(g.get().*));
        g.get().* = valueFromSlotTagged(cu.rt, prev_tag, slots[cu.reg.int()]);
        g.deinit();
    }

    // Rebox each written nullable-scalar register: a set flag slot restores null,
    // otherwise the scalar value is reboxed.
    for (self.nullables) |nu| {
        if (!nu.live_out or nu.reg.int() >= regs.len) continue;
        regs[nu.reg.int()] = if (slots[nu.flag_slot] != 0) .Null else valueFromSlotTagged(nu.rt, tags[nu.reg.int()], slots[nu.reg.int()]);
    }
    return .{ .resume_at = .{ .block = target, .inst = inst } };
}

/// Read the cell's inner scalar into an i64 slot, or null if the box no longer
/// holds the specialized kind (deopt to interpreter).
pub fn cellSlotIn(rt: RegType, v: Value) ?i64 {
    return switch (rt) {
        .i32 => switch (v) {
            .Int => |x| x,
            .Char => |x| x,
            .Short => |x| x,
            .Byte => |x| x,
            else => null,
        },
        .i64 => switch (v) {
            .Long => |x| x,
            else => null,
        },
        .f64 => switch (v) {
            .Double => |x| @bitCast(x),
            else => null,
        },
        .f32 => switch (v) {
            .Float => |x| @as(u32, @bitCast(x)),
            else => null,
        },
        .boolean => switch (v) {
            .Bool => |b| if (b) 1 else 0,
            else => null,
        },
        else => null,
    };
}

pub fn valueFromSlot(rt: RegType, s: i64) Value {
    return switch (rt) {
        .i32 => .{ .Int = @truncate(s) },
        .i64 => .{ .Long = s },
        .f64 => .{ .Double = @bitCast(s) },
        .f32 => .{ .Float = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(s))))) },
        .boolean => .{ .Bool = s != 0 },
        else => .Unit,
    };
}

/// The default box tag for `box_tags`: `.Int`.
pub const INT_TAG: u8 = @intFromEnum(@as(std.meta.Tag(Value), .Int));

/// As `valueFromSlot`, but an `.i32` slot boxes back to its register's
/// ORIGINAL value kind (`Char`/`Short`/`Byte`) instead of always `.Int`.
pub fn valueFromSlotTagged(rt: RegType, tag: u8, s: i64) Value {
    if (rt == .i32) {
        const T = std.meta.Tag(Value);
        return switch (@as(T, @enumFromInt(tag))) {
            .Char => .{ .Char = @truncate(@as(u64, @bitCast(s))) },
            .Short => .{ .Short = @truncate(s) },
            .Byte => .{ .Byte = @truncate(s) },
            else => .{ .Int = @truncate(s) },
        };
    }
    return valueFromSlot(rt, s);
}

// --- per-function JIT state + the interpreter hook --------------------------

const HOT_THRESHOLD: u32 = 64;
/// A loop whose receiver/field types are read from the live frame can bail when
/// the snapshot catches an object register holding null (between traversals).
/// Such a bail is transient, so retry a few times (spaced by re-reaching the
/// threshold) before giving up — a later snapshot usually has a non-null sample.
const MAX_COMPILE_ATTEMPTS: u8 = 6;
const RETRY_GAP: u32 = 8;

pub const FuncJit = struct {
    /// Fingerprint of the function this state was built for: its `blocks` slice
    /// pointer. The `states` map is keyed by the `*Func` address, which a freed
    /// module's reallocation can reuse for a different function; on a hit whose
    /// fingerprint no longer matches, the stale state (and its compiled code) is
    /// discarded and rebuilt, so a reused address never runs another function's
    /// native body.
    blocks_fp: usize,
    counts: []u32,
    attempts: []u8,
    /// Per-block compiled unit / permanent-bail flag: plain arrays so the
    /// per-block-entry hot probe is two indexed loads, not map lookups.
    slots: []?*CompiledLoop,
    dead: []bool,
    /// Whole-function JIT (function-mode): a separate hot counter and compiled
    /// unit for the function entry. `func_tried` latches once the compile has
    /// been attempted (success leaves `func_jit` set, failure leaves it null).
    func_count: u32 = 0,
    func_tried: bool = false,
    func_jit: ?CompiledLoop = null,
    a: Allocator,

    pub fn deinit(self: *FuncJit) void {
        self.a.free(self.counts);
        self.a.free(self.attempts);
        for (self.slots) |maybe| if (maybe) |cl| {
            cl.deinit();
            self.a.destroy(cl);
        };
        self.a.free(self.slots);
        self.a.free(self.dead);
        if (self.func_jit) |*cl| cl.deinit();
    }
};

var jit_enabled_cache: ?bool = null;
var jit_debug_cache: ?bool = null;

/// Test-only: force the JIT on or off, bypassing the `KLIO_JIT` env probe, so
/// the corpus can be run through the native tier inside `zig build test`.
pub fn setEnabledForTest(on: bool) void {
    jit_enabled_cache = on;
}

pub fn enabled() bool {
    if (jit_enabled_cache) |e| return e; // test override
    return runtime.perf.get().jit_loop;
}

fn debugEnabled() bool {
    if (jit_debug_cache) |d| return d;
    const v = runtime.envOnce("KLIO_JIT_DEBUG");
    const on = v != null and v.?.len > 0 and !std.mem.eql(u8, v.?, "0");
    jit_debug_cache = on;
    return on;
}

var func_jit_cache: ?bool = null;

/// Whole-function JIT (function mode / native recursion). It compiles whole
/// bodies (including recursion) per thread without a cross-thread eviction path
/// — fine for a normal single-program process (the `fast` profile enables it),
/// but the in-process multi-program test harness keeps it off via the
/// conservative default profile so per-worker compiled code never accumulates.
pub fn funcEnabled() bool {
    if (!enabled()) return false;
    if (func_jit_cache) |f| return f; // test override
    return runtime.perf.get().jit_func;
}

/// Test-only: force function mode on/off, bypassing the env probe.
pub fn setFuncEnabledForTest(on: bool) void {
    func_jit_cache = on;
}

threadlocal var states: std.AutoHashMapUnmanaged(usize, *FuncJit) = .empty;

/// Small JIT bookkeeping and compiler data must be packed by a general-purpose
/// allocator. `page_allocator` rounds every FuncJit/count/attempt allocation up
/// to an OS page; a broad framework such as Compose touches thousands of cold
/// functions and otherwise retains several pages for each one before compiling
/// even a single native unit. Executable buffers still use the W^X mmap path in
/// `jit.finalize`.
const metadata_allocator = runtime.slab.allocator;

/// Total compiled native units (loops + function bodies) cached on this thread.
/// Bounds the per-thread cache so a long-running process — or a worker that runs
/// many programs in the in-process test harness — does not retain compiled code
/// without limit. Eviction happens only at a safe point (`evictIfOverBudget`,
/// called when no native frame is on the stack).
threadlocal var compiled_units: usize = 0;
/// Compiled-unit ceiling per thread before the cache is dropped wholesale at the
/// next safe point. High enough that an ordinary program never trips it; a
/// pathological generator or a long-lived multi-program worker recompiles its hot
/// code after a clear instead of growing unbounded.
const COMPILED_UNIT_CAP: usize = 2048;

fn noteCompiled() void {
    compiled_units += 1;
}

/// Drop this thread's JIT cache if it has grown past the ceiling. MUST be called
/// only at a safe point — no compiled code on the stack (the interpreter at
/// `eval_depth == 0`) — since it frees the mmap'd exec buffers.
pub fn evictIfOverBudget() void {
    if (compiled_units <= COMPILED_UNIT_CAP) return;
    if (debugEnabled()) std.debug.print("[jit] evicting {d} compiled unit(s)\n", .{compiled_units});
    clearStates();
}

fn clearStates() void {
    var it = states.valueIterator();
    while (it.next()) |s| {
        s.*.deinit();
        metadata_allocator.destroy(s.*);
    }
    states.clearAndFree(metadata_allocator);
    ret_type_cache.clearAndFree(metadata_allocator);
    compiled_units = 0;
}

/// The compiled whole-function body for `func`, if one was built (function-JIT
/// mode). Used by the call trampoline to recurse natively into a compiled callee
/// without rebuilding an interpreter frame.
pub fn compiledFunc(func: *const Func) ?*const CompiledLoop {
    if (!funcEnabled()) return null;
    const fj = states.get(@intFromPtr(func)) orelse return null;
    if (func.blocks.len == 0 or fj.blocks_fp != @intFromPtr(func.blocks.ptr)) return null;
    if (fj.func_jit) |*cl| return cl;
    return null;
}

/// Free and clear all per-function JIT state on this thread. Called between
/// programs by the in-process test harness so compiled code (and its mmap'd exec
/// buffers) from a finished program is not retained — and a reallocated module's
/// reused `*Func` address cannot inherit a stale compiled body.
pub fn resetForTest() void {
    clearStates();
}

pub fn forFunc(func: *const Func) ?*FuncJit {
    const a = metadata_allocator;
    const key = @intFromPtr(func);
    if (func.blocks.len == 0) return null;
    const fp = @intFromPtr(func.blocks.ptr);
    if (states.get(key)) |s| {
        if (s.blocks_fp == fp) return s;
        // Address reused for a different function (a freed module's storage):
        // drop the stale state (and its compiled code) and rebuild.
        s.deinit();
        a.destroy(s);
        _ = states.remove(key);
    }
    const s = a.create(FuncJit) catch return null;
    const counts = a.alloc(u32, func.blocks.len) catch {
        a.destroy(s);
        return null;
    };
    const attempts = a.alloc(u8, func.blocks.len) catch {
        a.free(counts);
        a.destroy(s);
        return null;
    };
    const slots = a.alloc(?*CompiledLoop, func.blocks.len) catch {
        a.free(attempts);
        a.free(counts);
        a.destroy(s);
        return null;
    };
    const dead = a.alloc(bool, func.blocks.len) catch {
        a.free(slots);
        a.free(attempts);
        a.free(counts);
        a.destroy(s);
        return null;
    };
    s.* = .{ .blocks_fp = fp, .counts = counts, .attempts = attempts, .slots = slots, .dead = dead, .a = a };
    @memset(s.counts, 0);
    @memset(s.attempts, 0);
    @memset(s.slots, null);
    @memset(s.dead, false);
    states.put(a, key, s) catch {
        a.free(counts);
        a.free(attempts);
        a.destroy(s);
        return null;
    };
    return s;
}

// --- whole-function JIT (function mode) -------------------------------------

/// Every block reachable from the function entry (the compile covers the whole
/// body, entry to `Return`). Caller frees.
fn collectFunc(a: Allocator, func: *const Func) Allocator.Error!?[]BlockId {
    const nb = func.blocks.len;
    if (nb == 0) return null;
    const reach = try a.alloc(bool, nb);
    defer a.free(reach);
    @memset(reach, false);
    var order: std.ArrayListUnmanaged(BlockId) = .empty;
    errdefer order.deinit(a);
    var succ: std.ArrayListUnmanaged(BlockId) = .empty;
    defer succ.deinit(a);
    const entry = func.entry.int();
    if (entry >= nb) return null;
    reach[entry] = true;
    try order.append(a, func.entry);
    var i: usize = 0;
    while (i < order.items.len) : (i += 1) {
        succ.clearRetainingCapacity();
        try succEach(func.blocks[order.items[i].int()].terminator, &succ, a);
        for (succ.items) |s| {
            if (s.int() < nb and !reach[s.int()]) {
                reach[s.int()] = true;
                try order.append(a, s);
            }
        }
    }
    return try order.toOwnedSlice(a);
}

/// Type inference for a whole function: seed `LoadParam` dsts from the live
/// argument kinds, then propagate (`setDefType`) over every block to a fixpoint.
fn inferFuncTypes(a: Allocator, module: *const Module, func: *const Func, n_regs: u32, params: []const Value) Allocator.Error![]RegType {
    const types = try a.alloc(RegType, n_regs);
    @memset(types, .unknown);
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < 16) : (iters += 1) {
        changed = false;
        for (func.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (inst.* == .LoadParam) {
                    const lp = inst.LoadParam;
                    if (lp.idx < params.len) {
                        if (cellScalarType(params[lp.idx])) |rt| {
                            if (setType(types, lp.dst, rt)) changed = true;
                        }
                    }
                    continue;
                }
                if (setDefType(types, module, inst, &.{}, &.{})) changed = true;
            }
        }
    }
    return types;
}

/// Try to compile the whole body of `func` to native code (function mode): a
/// scalar function whose params/locals/return are scalar and whose only calls
/// are positional top-level calls (so direct recursion stays native through the
/// call trampoline). `params` are the live arguments at the hot call, used to
/// specialize param kinds. Returns null for any unsupported shape.
pub fn tryCompileFunc(a: Allocator, module: *const Module, func: *const Func, params: []const Value, resolver: ?MemberResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver, resolver_user: ?*anyopaque) Allocator.Error!?CompiledLoop {
    _ = resolver;
    _ = field_resolver;
    _ = field_nn_resolver;
    _ = resolver_user;
    if (func.blocks.len == 0) return null;
    if (func.is_suspend or func.is_lambda or func.is_inline) return null;
    // Only user-code functions: stdlib / kotlinx-pack bodies are left to the
    // interpreter so the whole-function tier never alters the runtime machinery
    // (coroutine dispatch, cancellation) that cooperative scheduling relies on.
    if (std.mem.startsWith(u8, func.package, "kotlin")) return null;
    const n_params: u32 = @intCast(func.params.len);
    if (n_params > 16 or params.len < n_params) return null;
    // Result must be scalar or Unit.
    const result_rt: RegType = retRegType(func.return_ty);
    // Only a return type whose boxed form `valueFromSlot` reproduces exactly:
    // `Char`/`Short`/`Byte` map to `.i32` but rebox to `.Int`, so a function
    // returning one would hand back a wrong-tagged value. Restrict to the exact
    // kinds (or Unit).
    const exact_ret = !func.return_ty.nullable and (std.mem.eql(u8, func.return_ty.name, "Int") or
        std.mem.eql(u8, func.return_ty.name, "Long") or std.mem.eql(u8, func.return_ty.name, "Double") or
        std.mem.eql(u8, func.return_ty.name, "Float") or std.mem.eql(u8, func.return_ty.name, "Boolean"));
    const result_scalar = isScalarRt(result_rt) and exact_ret;
    if (!result_scalar and !(result_rt == .unknown and isUnitReturn(func.return_ty))) return null;

    const body = (try collectFunc(a, func)) orelse return null;
    defer a.free(body);

    // Validate shape: no try-regions; Goto/Branch/Return terminators; only scalar
    // ops + positional top-level calls.
    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        if (blk.catches.len != 0 or blk.finally != null) return null;
        switch (blk.terminator) {
            .Goto, .Branch, .Return => {},
            else => return null,
        }
        for (blk.insts) |*inst| {
            if (numericConvOf(module, inst) != null) continue;
            if (bitwiseOpOf(module, inst) != null) continue;
            if (trampolinableCallOf(inst)) |tc| {
                if (tc.n_args > 3) return null;
                continue;
            }
            switch (inst.*) {
                // `/` and `%` are excluded: a divide-by-zero is the only deopt a
                // function-mode body could raise, and a native recursive callee has
                // no frame to resume into — so without this the deopt fallback would
                // re-run a (possibly impure) callee. Functions using `/`/`%` stay on
                // the interpreter / loop-JIT path.
                .BinOp => |b| if (isDivBinOp(b.op)) return null,
                .Const, .Move, .Not, .UnOp, .Trace, .LoadParam => {},
                else => return null,
            }
        }
    }

    const n_regs: u32 = func.n_locals;

    // Each param must be a scalar value; record its kind for the entry guard.
    const param_rt = try a.alloc(RegType, n_params);
    var ok = false;
    defer if (!ok) a.free(param_rt);
    {
        var p: u32 = 0;
        while (p < n_params) : (p += 1) {
            param_rt[p] = cellScalarType(params[p]) orelse return null;
        }
    }

    const types = try inferFuncTypes(a, module, func, n_regs, params);
    defer if (!ok) a.free(types);

    // The return register must carry the declared scalar kind.
    if (result_scalar) {
        for (body) |bid| {
            const blk = &func.blocks[bid.int()];
            if (blk.terminator == .Return) {
                if (blk.terminator.Return) |rr| {
                    if (rr.int() >= n_regs or typeAt(types, rr) != result_rt) return null;
                }
            }
        }
    }

    // Def set: every register written somewhere in the body (reboxed on deopt).
    const def = try a.alloc(bool, n_regs);
    defer if (!ok) a.free(def);
    @memset(def, false);
    // read set is unused in function mode (no entry unbox); allocate an empty.
    const read = try a.alloc(bool, n_regs);
    defer if (!ok) a.free(read);
    @memset(read, false);

    var call_sites: std.ArrayListUnmanaged(CallSite) = .empty;
    defer if (!ok) call_sites.deinit(a);

    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        for (blk.insts, 0..) |*inst, i| {
            if (instAnyDst(inst)) |d| {
                if (d.int() < n_regs) def[d.int()] = true;
            }
            const tc = trampolinableCallOf(inst) orelse continue;
            // Args must already live in typed scalar slots.
            var k: u8 = 0;
            while (k < tc.n_args) : (k += 1) {
                const ar = tc.args_reg + k;
                if (ar >= n_regs or !isScalarRt(types[ar])) return null;
            }
            var span: ?ir.Span = null;
            var bj: usize = i;
            while (bj > 0) {
                bj -= 1;
                if (blk.insts[bj] == .Trace) {
                    span = blk.insts[bj].Trace.span;
                    break;
                }
            }
            const has_result = tc.dst.int() < n_regs and isScalarRt(typeAt(types, tc.dst));
            call_sites.append(a, .{
                .func = tc.func,
                .args_reg = tc.args_reg,
                .n_args = tc.n_args,
                .dst_reg = tc.dst.int(),
                .has_result = has_result,
                .block = bid,
                .inst = @intCast(i),
                .span = span,
            }) catch return null;
        }
    }

    const has_calls = call_sites.items.len != 0;
    const param_slot_base: u32 = n_regs;
    const after_params: u32 = n_regs + n_params;
    const uc_slot: u32 = after_params;
    const tramp_slot: u32 = after_params + 1;
    const calls_base: u32 = after_params + (if (has_calls) @as(u32, 2) else 0);
    const result_slot: u32 = calls_base;
    const n_slots: u32 = calls_base + 1;

    var c = Compiler{
        .a = a,
        .module = module,
        .func = func,
        .body = body,
        .types = types,
        .array_info = &.{},
        .cell_info = &.{},
        .call_sites = call_sites.items,
        .inline_sites = &.{},
        .nullable = &.{},
        .null_flag_slot = &.{},
        .uc_slot = uc_slot,
        .tramp_slot = tramp_slot,
        .n_regs = n_regs,
        .reg_slots = n_slots,
        .val_payload_off = valuePayloadOffset(),
        .val_tag_off = valueTagOffset(),
        .func_mode = true,
        .param_slot_base = param_slot_base,
        .n_params = n_params,
        .result_slot = result_slot,
        .em = jit.Emitter.init(a),
        .block_label = try a.alloc(?jit.Label, func.blocks.len),
        .exit_targets = .empty,
        .exit_labels = .empty,
        .deopt_codes = .empty,
        .deopt_labels = .empty,
        .epilogue = undefined,
    };
    defer c.em.deinit();
    defer a.free(c.block_label);
    defer c.exit_targets.deinit(a);
    defer c.exit_labels.deinit(a);
    defer c.deopt_codes.deinit(a);
    defer c.deopt_labels.deinit(a);
    @memset(c.block_label, null);

    for (body) |bid| c.block_label[bid.int()] = c.em.newLabel() catch return null;
    c.epilogue = c.em.newLabel() catch return null;

    c.run() catch |e| {
        if (debugEnabled()) std.debug.print("[jit]   bail: func codegen {s} in {s}\n", .{ @errorName(e), func.name });
        return null;
    };

    const exec = jit.finalize(c.em.code()) catch return null;
    const sites_owned = call_sites.toOwnedSlice(a) catch return null;
    // Function mode restricts returns/params to exact `Int`-boxing kinds (see
    // `exact_ret`), so the default `Int` tag is correct for every register.
    const fn_tags = a.alloc(u8, n_regs) catch {
        a.free(sites_owned);
        return null;
    };
    @memset(fn_tags, INT_TAG);
    ok = true;
    return CompiledLoop{
        .exec = exec,
        .n_regs = n_regs,
        .n_slots = n_slots,
        .reg_types = types,
        .box_tags = fn_tags,
        .read_set = read,
        .def_set = def,
        .arrays = &.{},
        .cells = &.{},
        .nullables = &.{},
        .field_bases = &.{},
        .call_sites = sites_owned,
        .uc_slot = uc_slot,
        .tramp_slot = tramp_slot,
        .func_mode = true,
        .n_params = n_params,
        .param_slot_base = param_slot_base,
        .result_slot = result_slot,
        .result_rt = result_rt,
        .param_rt = param_rt,
        .allocator = a,
    };
}

/// A whole-function native run's outcome. `code.inst == RETURN_INST` → the
/// function returned `value`; otherwise `code` is an interpreter resume point
/// (a div-by-zero deopt or a callee throw) with the frame's registers reboxed.
pub const FuncOutcome = struct { code: Resume, value: Value };

/// Run a compiled function body. Fills the param slots from `params` (deopting if
/// a kind no longer matches), runs the native code, and returns its outcome.
pub fn runFunc(self: *const CompiledLoop, regs: []Value, params: []const Value, slots: []i64, tags: []u8, tramp: ?TrampFn, user: ?*anyopaque) ?FuncOutcome {
    // No blanket slot zeroing: Kotlin's definite-assignment rule means the
    // compiled body never reads a register before writing it, and the param
    // / trampoline slots are seeded explicitly below. (The zero fill was
    // 70%+ of a native fib's per-call cost.)
    @memcpy(tags[0..self.n_regs], self.box_tags[0..self.n_regs]);
    var i: u32 = 0;
    while (i < self.n_params) : (i += 1) {
        if (i >= params.len) return null;
        const sv = cellSlotIn(self.param_rt[i], params[i]) orelse return null; // kind changed: interpret
        slots[self.param_slot_base + i] = sv;
    }
    var tctx: TrampCtx = undefined;
    if (self.call_sites.len != 0) {
        if (tramp == null or user == null) return null;
        tctx = .{ .slots = slots.ptr, .compiled = self, .user = user.?, .tags = tags.ptr };
        slots[self.uc_slot] = @bitCast(@intFromPtr(&tctx));
        slots[self.tramp_slot] = @bitCast(@intFromPtr(tramp.?));
    }
    const fnptr = self.exec.entry(*const fn ([*]i64) callconv(.c) u64);
    const code = fnptr(slots.ptr);
    const target = BlockId.from(@intCast(code >> 32));
    const inst: u32 = @truncate(code & 0xffff_ffff);
    if (inst == RETURN_INST) {
        return .{ .code = .{ .block = target, .inst = inst }, .value = valueFromSlot(self.result_rt, slots[self.result_slot]) };
    }
    // Deopt / throw: rebox written scalar registers so the interpreter resumes.
    var r: u32 = 0;
    while (r < self.n_regs) : (r += 1) {
        if (!self.def_set[r] or r >= regs.len) continue;
        switch (self.reg_types[r]) {
            .i32, .i64, .f64, .f32, .boolean => regs[r] = valueFromSlot(self.reg_types[r], slots[r]),
            else => {},
        }
    }
    return .{ .code = .{ .block = target, .inst = inst }, .value = .Unit };
}

/// Interpreter hook at function entry: once the function is hot, compile its
/// whole body and run it natively. Returns the outcome, or null to interpret.
/// Frame register buffers live outside the GC heap (see `eval.regsAlloc`);
/// growth here must use the same allocator.
inline fn regsGrowAlloc(fallback: Allocator) Allocator {
    if (!runtime.reclaimEnabled() and runtime.gc.gc_enabled) return std.heap.c_allocator;
    return fallback;
}

pub fn maybeRunHotFunc(module: *const Module, func: *const Func, regs: *std.ArrayList(Value), params: []const Value, allocator: Allocator, tramp: ?TrampFn, user: ?*anyopaque, resolver: ?MemberResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver) ?FuncOutcome {
    if (!funcEnabled()) return null;
    const fj = forFunc(func) orelse return null;
    if (!fj.func_tried) {
        fj.func_count += 1;
        if (fj.func_count < HOT_THRESHOLD) return null;
        fj.func_tried = true;
        const compiled = tryCompileFunc(metadata_allocator, module, func, params, resolver, field_resolver, field_nn_resolver, user) catch null;
        if (compiled == null) return null;
        if (debugEnabled()) std.debug.print("[jit] compiled function {s} n_slots={d} n_regs={d}\n", .{ func.name, compiled.?.n_slots, compiled.?.n_regs });
        fj.func_jit = compiled;
        noteCompiled();
    }
    if (fj.func_jit == null) return null;
    const cl = &fj.func_jit.?;
    if (params.len < cl.n_params) return null;
    if (regs.items.len < cl.n_regs) {
        regs.appendNTimes(regsGrowAlloc(allocator), .Unit, cl.n_regs - regs.items.len) catch return null;
    }
    var stack_slots: [128]i64 = undefined;
    var heap_slots: ?[]i64 = null;
    defer if (heap_slots) |hs| metadata_allocator.free(hs);
    const slots: []i64 = if (cl.n_slots <= stack_slots.len)
        stack_slots[0..cl.n_slots]
    else blk: {
        heap_slots = metadata_allocator.alloc(i64, cl.n_slots) catch return null;
        break :blk heap_slots.?;
    };
    var stack_tags: [128]u8 = undefined;
    var heap_tags: ?[]u8 = null;
    defer if (heap_tags) |ht| metadata_allocator.free(ht);
    const rtags: []u8 = if (cl.n_regs <= stack_tags.len)
        stack_tags[0..cl.n_regs]
    else blk: {
        heap_tags = metadata_allocator.alloc(u8, cl.n_regs) catch return null;
        break :blk heap_tags.?;
    };
    return runFunc(cl, regs.items, params, slots, rtags, tramp, user);
}

/// Interpreter hook: at the start of block `cur`, count the entry and — once
/// hot — compile and run the natural loop with that header. Returns the resume
/// point (registers reboxed) when a compiled loop ran, else null. KLIO_JIT only.
pub fn maybeRunHot(module: *const Module, func: *const Func, regs: *std.ArrayList(Value), allocator: Allocator, cur: BlockId, tramp: ?TrampFn, user: ?*anyopaque, resolver: ?MemberResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver) ?Resume {
    const fj = forFunc(func) orelse return null;
    return maybeRunHotPre(fj, module, func, regs, allocator, cur, tramp, user, resolver, field_resolver, field_nn_resolver);
}

/// The per-block-entry probe with the per-FUNCTION state already resolved
/// (the frame loop hoists `forFunc` to once per activation). The fast
/// paths — already compiled, or known-dead — are two array loads.
pub fn maybeRunHotPre(fj: *FuncJit, module: *const Module, func: *const Func, regs: *std.ArrayList(Value), allocator: Allocator, cur: BlockId, tramp: ?TrampFn, user: ?*anyopaque, resolver: ?MemberResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver) ?Resume {
    const bi = cur.int();
    if (bi >= fj.counts.len) return null;

    if (fj.slots[bi] == null) {
        if (fj.dead[bi]) return null;
        fj.counts[bi] += 1;
        if (fj.counts[bi] < HOT_THRESHOLD) return null;
        var transient = false;
        const compiled = tryCompile(metadata_allocator, module, func, cur, regs.items, resolver, field_resolver, field_nn_resolver, user, &transient) catch null;
        if (compiled == null) {
            // A transient bail (an object register snapshot held null) is worth
            // retrying a few times; a permanent bail is cached immediately.
            fj.attempts[bi] += 1;
            if (transient and fj.attempts[bi] < MAX_COMPILE_ATTEMPTS) {
                fj.counts[bi] = HOT_THRESHOLD - RETRY_GAP;
                return null;
            }
            fj.dead[bi] = true;
            return null;
        }
        if (debugEnabled()) std.debug.print("[jit] compiled {s} block {d}\n", .{ func.name, bi });
        const clp = fj.a.create(CompiledLoop) catch return null;
        clp.* = compiled.?;
        fj.slots[bi] = clp;
        noteCompiled();
    }

    const cl = fj.slots[bi].?;

    if (regs.items.len < cl.n_regs) {
        regs.appendNTimes(regsGrowAlloc(allocator), .Unit, cl.n_regs - regs.items.len) catch return null;
    }
    // Slots live in a per-activation buffer, never a shared one: a trampolined
    // call can re-enter this hook for a nested hot loop, and that inner run must
    // not alias (or reallocate) the outer loop's live slots. Small loops use a
    // stack buffer; the rare larger loop falls back to a freed heap allocation.
    var stack_slots: [128]i64 = undefined;
    var heap_slots: ?[]i64 = null;
    defer if (heap_slots) |hs| metadata_allocator.free(hs);
    const slots: []i64 = if (cl.n_slots <= stack_slots.len)
        stack_slots[0..cl.n_slots]
    else blk: {
        heap_slots = metadata_allocator.alloc(i64, cl.n_slots) catch return null;
        break :blk heap_slots.?;
    };
    var stack_tags: [128]u8 = undefined;
    var heap_tags: ?[]u8 = null;
    defer if (heap_tags) |ht| metadata_allocator.free(ht);
    const rtags: []u8 = if (cl.n_regs <= stack_tags.len)
        stack_tags[0..cl.n_regs]
    else blk: {
        heap_tags = metadata_allocator.alloc(u8, cl.n_regs) catch return null;
        break :blk heap_tags.?;
    };
    return switch (runLoop(cl, regs.items, slots, rtags, tramp, user)) {
        .resume_at => |res| res,
        .bail => null,
    };
}

test "JIT metadata uses packed storage and resets pointer-keyed caches" {
    const testing = std.testing;
    try testing.expect(metadata_allocator.vtable != std.heap.page_allocator.vtable);
    try ret_type_cache.put(metadata_allocator, 1, .i32);
    resetForTest();
    try testing.expectEqual(@as(usize, 0), ret_type_cache.count());
}

test "loop JIT recognizes a boxed global read trampoline" {
    const testing = std.testing;
    var module = Module.init(testing.allocator);
    defer module.deinit(testing.allocator);
    const name = try module.internConst(testing.allocator, .{ .String = "pkg.SINGLETON" });
    const inst = Inst{ .LoadGlobal = .{ .dst = Reg.from(3), .name = name } };
    const global = trampolinableGlobalOf(&module, &inst).?;
    try testing.expectEqual(@as(u32, 3), global.dst.int());
    try testing.expectEqualStrings("pkg.SINGLETON", global.name);
}

test "loop JIT preserves exact member-extension operands" {
    const testing = std.testing;
    var module = Module.init(testing.allocator);
    defer module.deinit(testing.allocator);
    const name = try module.internConst(testing.allocator, .{ .String = "pick" });
    const inst = Inst{ .CallMember = .{
        .dst = Reg.from(8),
        .receiver = Reg.from(3),
        .name = name,
        .args = Reg.from(4),
        .n_args = 1,
        .resolved = FuncId.from(17),
        .dispatch_receiver = Reg.from(2),
    } };
    const member = trampolinableMemberOf(&module, &inst).?;
    try testing.expectEqual(FuncId.from(17), member.resolved.?);
    try testing.expectEqual(Reg.from(2), member.dispatch_recv.?);
    try testing.expectEqual(Reg.from(3), member.recv);
    try testing.expectEqual(@as(u32, 4), member.args_reg);
}
