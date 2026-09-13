//! Shared JIT vocabulary: machine-layout constants, scratch register
//! assignments, the resume/deopt encoding, and the compiled-loop data model
//! (`CompiledLoop` and the side tables its trampoline sites read).

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

// --- instance field memory layout (for native field access) ------------------
// An instance's fields are a contiguous `[]Field` (name + Value); a scalar field
// is read/written directly out of the boxed receiver's field buffer. The Value's
// scalar payload sits at offset 0; its 1-byte tag at `value_tag_offset`. These are
// computed from the real types so the codegen tracks any layout change.
pub const FIELD_STRIDE: u32 = @sizeOf(runtime.InstanceData.Field);
pub const FIELD_VALUE_OFF: u32 = @offsetOf(runtime.InstanceData.Field, "value");

/// Offsets a native receiver guard walks: from a frame `Value` to the instance
/// cell, and from there to the class cell. `ObjRef.identity` is the address of
/// a cell's `data`, so comparing classes is comparing pointers — no borrow.
/// Derived from the live types, like `valuePayloadOffset`, so a layout change
/// carries automatically.
const InstCell = runtime.ObjRef(runtime.InstanceData).Cell;
pub const VALUE_SIZE: u32 = @sizeOf(Value);
/// The per-activation stack slot buffer's capacity. A loop needing more still
/// runs, on a heap buffer; only a direct call's callee window has to fit, since
/// that window is addressed as a fixed offset inside the caller's slots.
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
pub const REGS: E = .rbx;
pub const T0: E = .rax; // index / lhs / result
pub const T1: E = .rcx; // rhs / len / ptr
pub const T2: E = .rdx; // array element scratch
// SSE scratch for `f64` arithmetic. A double IR register keeps its bit pattern
// in its i64 slot and is moved in/out with `movsd`.
pub const X0: jit.Xmm = .xmm0;
pub const X1: jit.Xmm = .xmm1;

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
pub fn encodeResume(blk: BlockId, inst: u32) u64 {
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
    /// A register whose value the trampoline handler already delivered BOXED
    /// into the frame (a call result whose runtime kind missed the slot's
    /// static type). The post-run deopt rebox must not clobber it from the
    /// never-filled slot. `maxInt` = none.
    deopt_skip_reg: u32 = std.math.maxInt(u32),
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
    arg_tag_regs: [6]u32 = .{ 0, 0, 0, 0, 0, 0 },
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
    /// Declared-receiver head for by-name dispatch (empty = plain).
    declared_name: []const u8 = "",
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
    /// `is_field` variant whose receiver varies per activation (function-JIT):
    /// the handler resolves the stored index BY NAME on the live receiver each
    /// call, deopting when the member is not a plain stored field.
    field_named: bool = false,
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
    /// Slot-resolved virtual dispatch (`CallVirtual`): the callback rebuilds
    /// the receiver + args and runs the host's `invokeVirtualMember` with
    /// `virt_slot` — dispatch stays dynamic (correct for any receiver class),
    /// so no class guard is needed.
    is_virtual: bool = false,
    virt_slot: u32 = 0,
    /// NN-proven native field READ: the stored value can never be null and
    /// its scalar kind is declared-stable, so the read carries no tag guard
    /// (and therefore no deopt edge).
    nn: bool = false,
    /// ESCAPE site: run the interpreter's own arm for this instruction
    /// against the live frame (full scalar spill before, unspill after —
    /// an unspill kind-mismatch deopts with the frame already correct).
    /// `.flat_call` from the arm discards the prepared request and deopts
    /// (the arm is effect-free up to that point), so the interpreter
    /// re-runs the instruction with its own flat machinery.
    is_exec: bool = false,
    exec_inst: ?*const Inst = null,
};

/// One packed array a compiled loop indexes: the register holding it, the
/// element kind specialized at compile time, and the scratch slots where the
/// entry unbox writes its buffer pointer and length.
pub const ArrayUnbox = struct {
    reg: Reg,
    kind: runtime.PrimitiveArrayKind,
    ptr_slot: u32,
    len_slot: u32,
    /// Seed from a `List`'s element buffer instead of a packed array's bytes.
    boxed: bool = false,
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
pub const ObjParamLoad = struct { param_idx: u16, reg: u32 };

/// One `this`-field the method body accesses natively: the stored index the
/// body was compiled against and the field's name bytes, re-verified against
/// the LIVE receiver at every entry — an instance's field ORDER is not
/// class-static (dynamic `define`s append), and a shifted index would
/// corrupt an unrelated field.
pub const MethodFieldCheck = struct { idx: u32, name: []const u8 };

/// Monomorphic inline cache for a by-name member site. Lowering resolves most
/// member calls; the ones it cannot (`CallMemberOrGlobal`, an overload set, a
/// receiver whose class is only known at run time) reached the interpreter's
/// FULL by-name dispatch on EVERY call from compiled code — candidate scan,
/// overload ranking, the lot. The cache records what the last dispatch at this
/// site resolved to and the shape it resolved for; a later call with the same
/// shape calls that target directly.
///
/// The key is the receiver's class AND the arguments' shape, because overload
/// selection reads the arguments, not just the receiver: caching on the class
/// alone would keep one overload's target for a call that should pick another.
pub const MemberIC = struct {
    key: u64 = 0,
    target: FuncId = @enumFromInt(0),
    valid: bool = false,
};

/// Shape key for an inline-cache probe: the receiver class plus each argument's
/// tag, and for an instance argument its class too. Zero means "do not cache"
/// (a receiver with no class identity).
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
    /// The class the cached field indices were resolved against. Entry proves the
    /// receiver still has it: a field index means nothing on another class, and
    /// the register is only guaranteed not to be rewritten INSIDE the loop —
    /// between entries it can hold anything.
    recv_class: usize,
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
    /// Method mode (function-JIT over a `this` receiver): params[0] must be an
    /// Instance of exactly `guard_class` (else the call declines to the
    /// interpreter), and its field-buffer pointer is seeded into
    /// `entry_fbase_slot` so `this`-field reads/writes run as native memory
    /// accesses. A method body has effects and holds an object, so it never
    /// runs as a native-recursed callee (`no_native_recurse`).
    method_mode: bool = false,
    guard_class: usize = 0,
    entry_fbase_slot: u32 = 0,
    no_native_recurse: bool = false,
    /// False only for a method body PROVEN unable to deopt or throw: no
    /// calls, no division, and every `this`-field read NN-proven (so reads
    /// carry no tag guard). Such a body is a pure native function over
    /// (receiver fields, scalar args) and may run at the RECURSIVE CALL SEAM
    /// with no frame at all — its only outcome is RETURN.
    can_deopt: bool = true,
    /// Whether the body stores to any `this`-field. A deopt out of a body that
    /// has already written one cannot be answered by re-running the call — the
    /// write would land twice — so this is what decides whether a CALLER may
    /// reach this body through a direct call that deopts.
    writes_fields: bool = true,
    /// Any call site that actually calls back through the trampoline (a
    /// NATIVE field site is direct memory access and needs none).
    has_tramp_sites: bool = true,
    /// Object params: each `LoadParam` of an object-kind param maps its
    /// destination FRAME register, seeded (borrowed — the frame's params
    /// list keeps the value alive, and the unset write-mask means an
    /// in-body overwrite releases nothing it does not own) before entry.
    obj_param_loads: []ObjParamLoad = &.{},
    /// Lambda captures whose LoadCapture destinations seed FRAME registers
    /// (borrowed, like object params); `param_idx` is the capture index.
    capture_loads: []ObjParamLoad = &.{},
    method_fields: []MethodFieldCheck = &.{},
    /// One inline cache per call site, indexed alongside `call_sites`. Mutable
    /// through a const unit: the cache is runtime state, not compiled code.
    member_ics: []MemberIC = &.{},
    /// The compile-time receiver's LAYOUT identity, bound to the verified
    /// `method_fields` (index, name) pairs under one borrow. An entry whose
    /// live receiver matches it skips the per-field name loop (`shape is not
    /// a claim key` — the class guard above still runs; the shape only
    /// licenses the verify skip).
    guard_shape: u64 = 0,
    /// The return register to read from the LIVE FRAME on RETURN when the
    /// escape chain left it untyped (result_rt then describes the declared
    /// kind for the caller's rebox validation).
    /// Function-JIT: slot holding the RETURNING REGISTER's index for a
    /// frame-resident (object / escape-typed) result, written by each
    /// `Return` emit; `maxInt(u32)` there means the scalar `result_slot`
    /// (or Unit) carries the value instead.
    result_reg_slot: u32 = 0,
    /// Slot holding the FRAME register base. A guarded arm reads its receiver's
    /// `Value` from there, because object registers are not slot-backed.
    regs_ptr_slot: u32 = 0,
    /// Calls that go STRAIGHT into another compiled unit's native code. The
    /// callee is a deopt-free method body over the same receiver, so it needs
    /// no frame, no trampoline and no resume machinery: this unit seeds the
    /// callee's argument slots and receiver field base inside its own slot
    /// array, calls it, and reads its result slot.
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

/// One direct call between compiled units. `slot_base` is where the callee's
/// whole slot window lives inside the caller's slot array, so the call is a
/// pointer bump and a `call` — no boxing, no host callback, no frame.
///
/// The callee's code address is baked into the caller. That address outlives
/// every run of the caller: reaching the caller's compiled body goes through
/// its own `FuncJit`, whose fingerprint is re-checked first, so a state map
/// that dropped the callee (a freed module whose `*Func` address was reused)
/// has already invalidated the caller too.
pub const DirectSite = struct {
    block: BlockId,
    inst: u32,
    callee: *const CompiledLoop,
    slot_base: u32,
    /// The call's argument register base; index 0 is the receiver, so callee
    /// parameter `i` reads caller register `args_reg + i`.
    args_reg: u32,
    n_args: u32,
    dst: Reg,
    has_result: bool,
    /// The callee can deopt, so the caller tests the returned resume code and
    /// re-runs the whole call interpreted when it is not RETURN.
    may_deopt: bool = false,
    /// Where that re-run resumes: the receiver `Move` this call removed.
    resume_at: BodyInstPos,
    /// The receiver register, so loop entry can prove the callee's field layout
    /// against the instance it will read. Unused by the function tier, whose
    /// receiver is the caller's own `this`.
    recv_reg: u32 = 0,
    /// The slot holding the RECEIVER's field-buffer pointer, which the callee
    /// reads as its own `this`. In the function tier that is the caller's entry
    /// base (a self call shares the receiver); in the loop tier it is the base
    /// cached at loop entry for a loop-invariant receiver.
    fbase_slot: u32 = 0,
};
