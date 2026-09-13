//! Shared JIT vocabulary: machine-layout constants, scratch register assignments, the
//! resume and deopt encoding, and the compiled-loop data model with its side tables.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
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

const inline_analysis = @import("inline_analysis.zig");
const type_infer = @import("types.zig");

const BodyInstPos = inline_analysis.BodyInstPos;
const instanceClassIdentity = type_infer.instanceClassIdentity;

// An instance's fields are a contiguous `[]Field` (name + Value): the Value's scalar payload
// sits at offset 0, its 1-byte tag at `value_tag_offset`. Offsets come from the real types.
pub const FIELD_STRIDE: u32 = @sizeOf(runtime.InstanceData.Field);
pub const FIELD_VALUE_OFF: u32 = @offsetOf(runtime.InstanceData.Field, "value");

/// Offsets a native receiver guard walks, from a frame `Value` to the instance cell and on to
/// the class cell. `ObjRef.identity` is a cell's `data` address, so a class compare is a pointer compare.
const InstCell = runtime.ObjRef(runtime.InstanceData).Cell;
pub const VALUE_SIZE: u32 = @sizeOf(Value);
/// Per-activation slot buffer capacity; a loop needing more runs on a heap buffer. Only a
/// direct call's callee window must fit, being addressed at a fixed offset in the caller's slots.
pub const MAX_SLOTS: u32 = 192;
pub const CELL_DATA_OFF: u32 = @offsetOf(InstCell, "data");
pub const INST_CLASS_OFF: u32 = CELL_DATA_OFF + @offsetOf(runtime.InstanceData, "class");

pub fn instanceTagValue() u8 {
    return @intFromEnum(@as(std.meta.Tag(Value), .Instance));
}

pub fn valuePayloadOffset() u32 {
    var v: Value = .{ .Long = 0 };
    return @intCast(@intFromPtr(&v.Long) - @intFromPtr(&v));
}
pub fn valueTagOffset() u32 {
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

// `REGS` (callee-saved) holds the slot-file base pointer; `T0`-`T3` are per-op scratch.
pub const REGS: E = .rbx;
pub const T0: E = .rax; // index / lhs / result
pub const T1: E = .rcx; // rhs / len / ptr
pub const T2: E = .rdx; // array element scratch
// SSE scratch for `f64`: a double register keeps its bits in its i64 slot, moved with `movsd`.
pub const X0: jit.Xmm = .xmm0;
pub const X1: jit.Xmm = .xmm1;

/// Static type of an IR register. `object` marks one holding a full `Value` reference: it lives
/// in the frame's register array, a GC root, never in a scalar slot, and only callbacks touch it.
pub const RegType = enum(u8) { i32, i64, f64, f32, boolean, unit, null_, object, unknown };

/// The native loop returns `(block_id << 32) | inst_index`, the interpreter resume point. A normal exit
/// resumes at the target block's first instruction; a deopt resumes at the faulting instruction.
pub fn encodeResume(blk: BlockId, inst: u32) u64 {
    return (@as(u64, blk.int()) << 32) | inst;
}
pub fn encodeResumePub(blk: BlockId, inst: u32) u64 {
    return encodeResume(blk, inst);
}
/// Sentinel inst index: the trampolined call threw. The host stashed the exception, and the
/// interpreter re-raises it at the call's block instead of re-executing the call.
pub const THROW_INST: u32 = 0xffff_ffff;
pub fn throwCode(blk: BlockId) u64 {
    return encodeResume(blk, THROW_INST);
}
/// Sentinel inst index: deopt and re-execute at the stashed instruction, as a field read whose value
/// is no longer the cached scalar does. Non-zero, so it never reads as continue.
pub const DEOPT_INST: u32 = 0xffff_fffe;
pub fn deoptCode(blk: BlockId) u64 {
    return encodeResume(blk, DEOPT_INST);
}
/// Sentinel inst index: the compiled function returned, its result in `result_slot`. Non-zero,
/// so it is never mistaken for continue.
pub const RETURN_INST: u32 = 0xffff_fffd;
pub fn returnCode() u64 {
    return encodeResume(BlockId.from(0), RETURN_INST);
}

/// Context the JIT'd loop hands its trampoline: the live slot file, the compiled loop, and
/// the host's opaque ctx. Its address sits in a reserved slot the native call site loads.
pub const TrampCtx = extern struct {
    slots: [*]i64,
    compiled: *const CompiledLoop,
    user: *anyopaque,
    /// Runtime value-kind tag per `.i32` register, seeded from `box_tags` and the live entry values. A call's
    /// result write refreshes its dst tag, so an intrinsic with no static return kind still reboxes correctly.
    tags: [*]u8,
    /// A register the trampoline handler already delivered BOXED into the frame; the post-run
    /// deopt rebox must not clobber it from the never-filled slot. `maxInt` means none.
    deopt_skip_reg: u32 = std.math.maxInt(u32),
};
/// `fn(trampctx, call_site_index) -> 0 to continue native, else a resume code`.
pub const TrampFn = *const fn (*anyopaque, u64) callconv(.c) u64;

pub const CallSite = struct {
    func: FuncId = @enumFromInt(0),
    args_reg: u32 = 0,
    n_args: u32 = 0,
    dst_reg: u32,
    has_result: bool = false,
    block: BlockId,
    inst: u32,
    /// Source span of the call, so the trampoline can refresh the frame's position before
    /// dispatch: the native loop does not execute `.Trace`, so the span is otherwise stale.
    span: ?ir.Span = null,
    /// The register whose LIVE tag governs each argument's rebox. Native code copies argument SLOTS
    /// through `Move`s without touching the tag array, so the tag is read through the move chain's SOURCE.
    arg_tag_regs: [6]u32 = .{ 0, 0, 0, 0, 0, 0 },
    recv_tag_reg: u32 = 0,
    /// `is_member` selects `receiver.name(args)` dispatch: a scalar receiver is rebuilt from its slot, an object
    /// one stays boxed. `recv_class` is re-checked at loop entry, so another class deopts.
    is_member: bool = false,
    recv_reg: u32 = 0,
    name: []const u8 = "",
    resolved_member: ?FuncId = null,
    dispatch_recv_reg: ?u32 = null,
    /// Declared-receiver head for by-name dispatch (empty = plain).
    declared_name: []const u8 = "",
    recv_class: usize = 0,
    is_field: bool = false,
    is_field_set: bool = false,
    field_idx: u32 = 0,
    recv_varies: bool = false,
    /// Native field access, no callback: `fbase_slot` holds the receiver's field buffer pointer
    /// cached at loop entry, and `tag` the field value's expected `Value` tag, a mismatch deopting.
    native: bool = false,
    fbase_slot: u32 = 0,
    tag: u8 = 0,
    /// Object-vs-null test: read boxed `recv_reg`, write 0 or 1 (negated when `neg`) to the
    /// scalar `dst_reg` slot. `is_obj_move` instead copies boxed `src_reg` into `dst_reg`.
    is_null_check: bool = false,
    is_obj_move: bool = false,
    neg: bool = false,
    identity: bool = false,
    src_reg: u32 = 0,
    is_obj_index: bool = false,
    /// Global read: resolve `name` through the host into the frame register, keeping a GC reference
    /// out of the scalar slot file.
    is_load_global: bool = false,
    /// `is_field` whose receiver varies per activation: the handler resolves the stored index
    /// by name on the live receiver each call, deopting when it is not a plain stored field.
    field_named: bool = false,
    is_call_value: bool = false,
    /// Map subscript on the loop-invariant map in `recv_reg`: `is_map_get` writes the nullable
    /// scalar into `dst_reg` plus `map_flag_slot`, `is_map_set` stores `slot[src_reg]` at the key.
    is_map_get: bool = false,
    is_map_set: bool = false,
    map_flag_slot: u32 = 0,
    /// Slot-resolved virtual dispatch through `virt_slot`; dispatch stays dynamic, so no class guard.
    is_virtual: bool = false,
    virt_slot: u32 = 0,
    /// NN-proven native field READ: never null and kind-stable, so no tag guard and no deopt edge.
    nn: bool = false,
    /// ESCAPE site: run the interpreter's own arm for this instruction against the live frame, spilling every
    /// scalar before and unspilling after; a `.flat_call` from the arm discards its request and deopts.
    is_exec: bool = false,
    exec_inst: ?*const Inst = null,
};

/// One packed array a loop indexes: its register, the element kind specialized at compile time,
/// and the scratch slots holding its buffer pointer and length.
pub const ArrayUnbox = struct {
    reg: Reg,
    kind: runtime.PrimitiveArrayKind,
    ptr_slot: u32,
    len_slot: u32,
    boxed: bool = false,
};

/// One capture cell a loop reads or writes. The cached inner scalar lives in the cell
/// register's own slot, unboxed from the box at entry and written back through it at exit.
pub const CellUnbox = struct {
    reg: Reg,
    rt: RegType,
};

/// A register holding a scalar of kind `rt` or null: the value lives in the register's own
/// slot, `flag_slot` holds 1 when null, and both sync with the boxed `Value` at entry and exit.
pub const NullableUnbox = struct {
    reg: Reg,
    rt: RegType,
    flag_slot: u32,
    live_in: bool,
    live_out: bool,
};

pub const ObjParamLoad = struct { param_idx: u16, reg: u32 };

/// One `this`-field the method body accesses natively: the stored index it was compiled against and the
/// field's name, re-verified at every entry, since field ORDER is not class-static.
pub const MethodFieldCheck = struct { idx: u32, name: []const u8 };

/// Monomorphic inline cache for a by-name member site: the last dispatch's target and the shape it resolved
/// for. The key is receiver class AND argument shape, because overload selection reads the arguments.
pub const MemberIC = struct {
    key: u64 = 0,
    target: FuncId = @enumFromInt(0),
    valid: bool = false,
};

/// Shape key for an inline-cache probe: the receiver class plus each argument's tag, and an
/// instance argument's class too. Zero means do not cache.
pub fn memberICKey(recv: *const Value, args: []const Value) u64 {
    if (recv.* != .Instance) return 0;
    var h: u64 = instanceClassIdentity(recv.*);
    if (h == 0) return 0;
    h = h *% 0x9E3779B97F4A7C15;
    for (args) |*a| {
        h = (h ^ @intFromEnum(std.meta.activeTag(a.*))) *% 0x100000001B3;
        if (a.* == .Instance) h = (h ^ instanceClassIdentity(a.*)) *% 0x100000001B3;
    }
    return h | 1; // never 0: 0 marks an unusable key
}

pub const FieldBase = struct {
    recv_reg: u32,
    ptr_slot: u32,
    /// The class the cached field indices were resolved against; entry proves the receiver still
    /// has it, the register being guaranteed stable only INSIDE the loop.
    recv_class: usize,
};

pub const CompiledLoop = struct {
    exec: jit.ExecBuf,
    n_regs: u32,
    n_slots: u32, // register slots + 2 per indexed array (ptr,len)
    reg_types: []RegType,
    /// Value tag each `.i32` register boxes back to: `.i32` covers `Int`/`Char`/`Short`/`Byte` in machine
    /// terms, but a rebox must restore the ORIGINAL tag. Refined from callee return types and live samples.
    box_tags: []u8,
    read_set: []bool, // reg is read somewhere in the loop (must unbox at entry)
    def_set: []bool, // reg is written somewhere in the loop (rebox at exit)
    arrays: []ArrayUnbox,
    cells: []CellUnbox,
    nullables: []NullableUnbox,
    field_bases: []FieldBase,
    call_sites: []CallSite,
    /// Reserved slot holding the `*TrampCtx` the native sites load into rdi, and the slot holding
    /// the host `TrampFn`. Valid only when `call_sites.len != 0`.
    uc_slot: u32,
    tramp_slot: u32,
    /// Function-JIT mode: the unit is a whole function body, not a natural loop. `n_params` scalar params load
    /// into the slots at `param_slot_base`; a `Return` writes `result_slot` and exits with `RETURN_INST`.
    func_mode: bool = false,
    n_params: u32 = 0,
    param_slot_base: u32 = 0,
    result_slot: u32 = 0,
    result_rt: RegType = .unit,
    param_rt: []RegType = &.{},
    /// Method mode: params[0] must be an Instance of exactly `guard_class`, else the call declines to the
    /// interpreter; its field-buffer pointer is seeded into `entry_fbase_slot` so `this`-field access is native.
    method_mode: bool = false,
    guard_class: usize = 0,
    entry_fbase_slot: u32 = 0,
    no_native_recurse: bool = false,
    /// False only for a method body proven unable to deopt or throw: no calls, no division, every
    /// `this`-field read NN-proven. Such a body may run at the recursive call seam with no frame.
    can_deopt: bool = true,
    /// Whether the body stores to any `this`-field. A deopt after such a write cannot be answered
    /// by re-running the call, so this decides whether a caller may reach the body by direct call.
    writes_fields: bool = true,
    /// Any site that actually calls back through the trampoline; a native field site does not.
    has_tramp_sites: bool = true,
    /// Each `LoadParam` of an object-kind param maps its destination FRAME register, seeded borrowed: the
    /// frame's params list keeps the value alive, and the unset write-mask means an overwrite releases nothing.
    obj_param_loads: []ObjParamLoad = &.{},
    capture_loads: []ObjParamLoad = &.{},
    method_fields: []MethodFieldCheck = &.{},
    /// One inline cache per call site; runtime state, so mutable through a const unit.
    member_ics: []MemberIC = &.{},
    /// The compile-time receiver's LAYOUT identity, bound to the verified `method_fields` pairs under
    /// one borrow. A live receiver matching it skips the per-field name loop; the class guard still runs.
    guard_shape: u64 = 0,
    /// Function-JIT: slot holding the returning register's index for a frame-resident result, written
    /// by each `Return` emit; `maxInt(u32)` means the scalar `result_slot`, or Unit, carries it.
    result_reg_slot: u32 = 0,
    /// Slot holding the FRAME register base, since object registers are not slot-backed.
    regs_ptr_slot: u32 = 0,
    /// Calls going STRAIGHT into another compiled unit's native code: the callee is a deopt-free method body over
    /// the same receiver, so this unit seeds its slots in its own array, calls it, and reads its result slot.
    direct_sites: []const DirectSite = &.{},
    self_dbg_name: []const u8 = "",
    allocator: Allocator,

    pub fn deinit(self: *CompiledLoop) void {
        self.exec.deinit();
        self.allocator.free(self.reg_types);
        self.allocator.free(self.box_tags);
        self.allocator.free(self.read_set);
        self.allocator.free(self.def_set);
        if (self.obj_param_loads.len != 0) self.allocator.free(self.obj_param_loads);
        if (self.capture_loads.len != 0) self.allocator.free(self.capture_loads);
        if (self.method_fields.len != 0) self.allocator.free(self.method_fields);
        if (self.member_ics.len != 0) self.allocator.free(self.member_ics);
        self.allocator.free(self.arrays);
        self.allocator.free(self.cells);
        self.allocator.free(self.nullables);
        self.allocator.free(self.field_bases);
        self.allocator.free(self.call_sites);
        if (self.param_rt.len != 0) self.allocator.free(self.param_rt);
        if (self.direct_sites.len != 0) self.allocator.free(self.direct_sites);
    }
};

/// One direct call between compiled units. `slot_base` is where the callee's whole slot window lives inside
/// the caller's slot array, so the call is a pointer bump and a `call`. The baked-in callee address outlives
/// every run: reaching the caller's body re-checks its own `FuncJit` fingerprint first.
pub const DirectSite = struct {
    block: BlockId,
    inst: u32,
    callee: *const CompiledLoop,
    slot_base: u32,
    /// Index 0 is the receiver, so callee parameter `i` reads caller register `args_reg + i`.
    args_reg: u32,
    n_args: u32,
    dst: Reg,
    has_result: bool,
    /// The callee can deopt, so the caller tests the resume code and re-runs the call interpreted.
    may_deopt: bool = false,
    /// Where that re-run resumes: the receiver `Move` this call removed.
    resume_at: BodyInstPos,
    /// The receiver register, so entry can prove the callee's field layout against the instance it reads.
    recv_reg: u32 = 0,
    /// Slot holding the RECEIVER's field-buffer pointer, read by the callee as its own `this`: the
    /// caller's entry base in the function tier, the loop-entry cache in the loop tier.
    fbase_slot: u32 = 0,
};
