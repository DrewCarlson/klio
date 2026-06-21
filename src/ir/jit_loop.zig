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

// Native register assignment. `REGS` (callee-saved) holds the slot-file base
// pointer; `T0`-`T3` are per-instruction scratch.
const REGS: E = .rbx;
const T0: E = .rax; // index / lhs / result
const T1: E = .rcx; // rhs / len / ptr
const T2: E = .rdx; // array element scratch
// SSE scratch for `f64` arithmetic. A double IR register keeps its bit pattern
// in its i64 slot and is moved in/out with `movsd`.
const X0: jit.Emitter.Xmm = .xmm0;
const X1: jit.Emitter.Xmm = .xmm1;

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

/// Runtime context the JIT'd loop hands its trampoline: the live slot file, the
/// compiled loop (for per-site descriptors + reg types), and the host's opaque
/// loop ctx. Its address sits in a reserved slot the native call site loads.
pub const TrampCtx = extern struct {
    slots: [*]i64,
    compiled: *const CompiledLoop,
    user: *anyopaque,
};
/// `fn(trampctx, call_site_index) -> 0 to continue native, else a resume code`.
pub const TrampFn = *const fn (*anyopaque, u64) callconv(.c) u64;

/// One trampolined call site in a compiled loop. Arg/result types come from the
/// loop's `reg_types` (a slot index == its reg index).
pub const CallSite = struct {
    func: FuncId = @enumFromInt(0),
    args_reg: u32 = 0,
    n_args: u8 = 0,
    dst_reg: u32,
    has_result: bool = false,
    block: BlockId,
    inst: u32,
    /// Source span of the call (from the nearest preceding `.Trace`), so the
    /// trampoline can refresh the calling frame's position before dispatch — the
    /// native loop does not execute `.Trace`, so the frame's span is otherwise
    /// stale when a trampolined call throws.
    span: ?ir.Span = null,
    /// Member-call fields. `is_member` selects `receiver.name(args)` dispatch (the
    /// receiver stays boxed in the frame's registers and is read by the host);
    /// `recv_class` is the receiver's class identity at compile time, re-checked at
    /// loop entry so a later activation with a different receiver class deopts.
    is_member: bool = false,
    recv_reg: u32 = 0,
    name: []const u8 = "",
    recv_class: usize = 0,
    /// Field-read fields. `is_field` selects a direct stored-field read from the
    /// boxed receiver at `field_idx` (the field's stable position in the instance,
    /// valid for the guarded receiver class). When `dst_reg`'s type is `.object`
    /// the read writes the boxed value into the frame register; otherwise a scalar
    /// slot. `recv_varies` marks a non-loop-invariant boxed receiver, so the read
    /// re-checks the receiver's class each call instead of relying on the entry
    /// guard. No side effects.
    is_field: bool = false,
    field_idx: u32 = 0,
    recv_varies: bool = false,
    /// Object-vs-null test: read boxed register `recv_reg`, write `0`/`1` (negated
    /// when `neg`) to the scalar `dst_reg` slot. `is_obj_move` instead copies boxed
    /// register `src_reg` into `dst_reg` (both frame registers).
    is_null_check: bool = false,
    is_obj_move: bool = false,
    neg: bool = false,
    src_reg: u32 = 0,
    /// Object collection subscript: `regs[dst] = regs[recv_reg].get(slot[args_reg])`
    /// where the element is a boxed object. The index is a scalar slot register.
    is_obj_index: bool = false,
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

pub const CompiledLoop = struct {
    exec: jit.ExecBuf,
    n_regs: u32,
    n_slots: u32, // register slots + 2 per indexed array (ptr,len)
    reg_types: []RegType,
    read_set: []bool, // reg is read somewhere in the loop (must unbox at entry)
    def_set: []bool, // reg is written somewhere in the loop (rebox at exit)
    arrays: []ArrayUnbox,
    cells: []CellUnbox,
    /// Trampolined call sites, indexed by the site index the native code passes
    /// the host callback. Empty when the loop makes no calls.
    call_sites: []CallSite,
    /// Reserved slot holding the `*TrampCtx` the native call sites load into rdi,
    /// and the slot holding the host `TrampFn` pointer. Only valid when
    /// `call_sites.len != 0`.
    uc_slot: u32,
    tramp_slot: u32,
    allocator: Allocator,

    pub fn deinit(self: *CompiledLoop) void {
        self.exec.deinit();
        self.allocator.free(self.reg_types);
        self.allocator.free(self.read_set);
        self.allocator.free(self.def_set);
        self.allocator.free(self.arrays);
        self.allocator.free(self.cells);
        self.allocator.free(self.call_sites);
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

/// A top-level `Call` the loop JIT can trampoline: a native call site invokes the
/// host, which reboxes the scalar args, runs the callee interpreted, and reboxes a
/// scalar result. v1 handles only the bare positional form (no named args, no
/// reified type args) with at most three args.
const TrampCall = struct { func: FuncId, args_reg: u32, n_args: u8, dst: Reg };

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

/// A `CallMember` the loop JIT can trampoline: an instance-method call whose
/// receiver is a loop-invariant boxed object (read by the host from the frame's
/// registers, never unboxed into a slot). v1 handles only the bare positional form
/// (no named args, no static-receiver pin) with at most three scalar args.
const TrampMember = struct { recv: Reg, name: []const u8, args_reg: u32, n_args: u8, dst: Reg };

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
            return .{ .recv = cm.receiver, .name = name.String, .args_reg = cm.args.int(), .n_args = cm.n_args, .dst = cm.dst };
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

/// `fn(user, receiver, field_name) -> stored field index | null`. The loop JIT
/// calls this at compile time; a non-null index means `name` is a plain stored
/// property (no custom getter) the trampoline can read directly. Null means the
/// read must stay interpreted (computed getter / delegated / extension property).
pub const FieldResolver = *const fn (*anyopaque, *const Value, []const u8) ?u32;

/// The scalar `RegType` a callee's declared return type maps to, or `.unknown`
/// for a non-scalar / nullable / `Unit` return (the call's result is then not
/// reboxed; a used non-scalar result makes the loop uncompilable).
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
    ret_type_cache.put(std.heap.page_allocator, key, .unknown) catch {};
    const inferred = inferScalarReturnType(std.heap.page_allocator, module, func) orelse .unknown;
    ret_type_cache.put(std.heap.page_allocator, key, inferred) catch {};
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

fn isScalarRt(t: RegType) bool {
    return switch (t) {
        .i32, .i64, .f64, .f32, .boolean => true,
        else => false,
    };
}

/// The `RegType` for a live register value: a scalar kind, `.object` for a class
/// instance (the JIT holds it in `regs`, where it stays a GC root, and at run time
/// the register may also hold null), or null when it cannot be classified (a bare
/// `Null`/`Unit`, whose register would have an ambiguous static type).
fn liveValueRegType(v: Value) ?RegType {
    if (cellScalarType(v)) |s| return s;
    return switch (v) {
        .Instance => .object,
        else => null,
    };
}

/// The live element at `idx` of a `List` or reference `Array`, or null for an
/// out-of-range index or an unsupported container. Used to sample an object
/// collection's element type at compile time (a packed primitive array is handled
/// by the native array path, not here).
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
fn arrayElemShape(kind: runtime.PrimitiveArrayKind) ?struct { rt: RegType, w: jit.Emitter.ElemW, esize: u8 } {
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
    w: jit.Emitter.ElemW,
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
    // Seed parameter registers from their live scalar kind: a function whose hot
    // loop only reads its parameters has no in-body instruction to infer their
    // type from. This is sound because the entry unbox re-checks each read reg
    // against its cached type and bails to the interpreter on any mismatch (e.g.
    // a later activation of a generic function called with a different type). A
    // param the loop writes is overridden by `setDefType`; a non-scalar param is
    // left unknown (and bails if read).
    {
        const nparams = @min(func.params.len, n_regs);
        var p: usize = 0;
        while (p < nparams and p < regs.len) : (p += 1) {
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
    if (r.int() < types.len and types[r.int()] != t and t != .unknown) {
        types[r.int()] = t;
        return true;
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
    if (b.op != .Eq and b.op != .NotEq) return false;
    const lt = typeAt(types, b.lhs);
    const rt = typeAt(types, b.rhs);
    return (lt == .object and rt == .null_) or (lt == .null_ and rt == .object) or (lt == .object and rt == .object);
}

fn instReadsDef(module: *const Module, inst: *const Inst, reads: *[3]Reg, n_reads: *usize, def: *?Reg, types: []const RegType) void {
    n_reads.* = 0;
    def.* = null;
    if (arrayOpOf(module, inst)) |op| {
        reads[0] = op.index;
        if (op.is_set) {
            reads[1] = op.value;
            n_reads.* = 2;
        } else {
            n_reads.* = 1;
        }
        // An object-collection subscript writes a boxed register (in `regs`), not
        // a scalar slot — only a packed-array element is a scalar def.
        if (!op.is_set and typeAt(types, op.dst) == .object) return;
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
    // A trampolined member call reads its scalar args (the receiver stays boxed in
    // a register and is read directly by the host, so it is NOT a scalar read); its
    // dst is a scalar def only when the resolved method returns a scalar.
    if (trampolinableMemberOf(module, inst)) |mc| {
        var k: u8 = 0;
        while (k < mc.n_args and k < 3) : (k += 1) reads[k] = Reg.from(mc.args_reg + k);
        n_reads.* = mc.n_args;
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
        var reads: [3]Reg = undefined;
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
    uc_slot: u32,
    tramp_slot: u32,
    n_regs: u32,
    em: jit.Emitter,
    block_label: []?jit.Emitter.Label,
    exit_targets: std.ArrayListUnmanaged(BlockId),
    exit_labels: std.ArrayListUnmanaged(jit.Emitter.Label),
    deopt_codes: std.ArrayListUnmanaged(u64),
    deopt_labels: std.ArrayListUnmanaged(jit.Emitter.Label),
    epilogue: jit.Emitter.Label,
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
        if (off > std.math.maxInt(i32) or r.int() >= self.n_regs) return null;
        return @intCast(off);
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
    fn loadF64Slot(self: *Compiler, x: jit.Emitter.Xmm, r: Reg) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.movsdLoad(x, REGS, d);
    }
    fn storeF64Slot(self: *Compiler, r: Reg, x: jit.Emitter.Xmm) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.movsdStore(REGS, d, x);
    }
    /// Load/store an f32 register's slot (f32 bits in the low 4 bytes).
    fn loadF32Slot(self: *Compiler, x: jit.Emitter.Xmm, r: Reg) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.movssLoad(x, REGS, d);
    }
    fn storeF32Slot(self: *Compiler, r: Reg, x: jit.Emitter.Xmm) !void {
        const d = self.slotDisp(r) orelse return jit.JitError.Unsupported;
        try self.em.movssStore(REGS, d, x);
    }

    fn loadFloat(self: *Compiler, x: jit.Emitter.Xmm, r: Reg, is32: bool) !void {
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
    fn ucomiFloat(self: *Compiler, x: jit.Emitter.Xmm, y: jit.Emitter.Xmm, is32: bool) !void {
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

    fn exitLabel(self: *Compiler, blk: BlockId) !jit.Emitter.Label {
        for (self.exit_targets.items, 0..) |t, i| {
            if (t.int() == blk.int()) return self.exit_labels.items[i];
        }
        const l = try self.em.newLabel();
        self.exit_targets.append(self.a, blk) catch return jit.JitError.OutOfMemory;
        self.exit_labels.append(self.a, l) catch return jit.JitError.OutOfMemory;
        return l;
    }

    fn edgeLabel(self: *Compiler, target: BlockId) !jit.Emitter.Label {
        if (self.inBody(target)) return self.block_label[target.int()].?;
        return self.exitLabel(target);
    }

    /// A deopt stub for resuming the interpreter at the current instruction.
    fn deoptLabel(self: *Compiler) !jit.Emitter.Label {
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
    fn emitCallSite(self: *Compiler, si: u32) !void {
        try self.em.loadMem(.rdi, REGS, @intCast(@as(u64, self.uc_slot) * 8));
        try self.em.movImm64(.rsi, @intCast(si));
        try self.em.loadMem(.rax, REGS, @intCast(@as(u64, self.tramp_slot) * 8));
        try self.em.callReg(.rax);
        try self.em.testReg(.rax, .rax);
        try self.em.jcc(.ne, self.epilogue);
    }

    fn emitInst(self: *Compiler, inst: *const Inst) !void {
        // A trampolined site (call / member / field / object op / subscript) is a
        // host callback; checked first so an object-collection subscript is not
        // mistaken for a native packed-array access.
        if (self.siteIndexAt()) |si| {
            try self.emitCallSite(si);
            return;
        }
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
pub fn tryCompile(a: Allocator, module: *const Module, func: *const Func, header: BlockId, regs: []const Value, resolver: ?MemberResolver, field_resolver: ?FieldResolver, resolver_user: ?*anyopaque, transient: *bool) Allocator.Error!?CompiledLoop {
    const body = (try collectLoop(a, func, header)) orelse return null;
    defer a.free(body);

    // Reject try-regions: deopt resumes mid-block, so we must not need to
    // re-establish catch/finally scope.
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
            switch (inst.*) {
                .Const, .Move, .BinOp, .Not, .UnOp, .Trace, .CellGet, .CellSet => {},
                else => {
                    if (debugEnabled()) std.debug.print("[jit]   uncompilable inst {s} in {s} b{d}\n", .{ @tagName(inst.*), func.name, bid.int() });
                    return null;
                },
            }
        }
    }

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
            // non-packed receiver (a `List` or reference `Array` of objects) is
            // left for the object-subscript path — but only for a `get`; a
            // non-packed `set` is not compilable here.
            const packed_ok = v == .Array and v.Array.prim != null and v.Array.storage == .scalars;
            if (!packed_ok) {
                if (op.is_set) return null;
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
    const arr_slots: u32 = n_regs + 2 * @as(u32, @intCast(arrays.items.len));

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

    // Resolve each trampolined member call's result type against its live receiver
    // (the IR cannot name the dispatched method) and each trampolined field read's
    // type + stable index. Both require Instance receivers and the matching
    // resolver; a suspend method, or a loop that also indexes arrays (a method
    // could resize the backing store), is rejected. `field_idx_of` records the
    // stored-field index per field-read dst for the collection pass.
    const member_ret = try a.alloc(RegType, n_regs);
    defer a.free(member_ret);
    @memset(member_ret, .unknown);
    const field_idx_of = try a.alloc(u32, n_regs);
    defer a.free(field_idx_of);
    @memset(field_idx_of, 0);
    for (body) |bid| {
        for (func.blocks[bid.int()].insts) |*inst| {
            if (trampolinableMemberOf(module, inst)) |mc| {
                if (resolver == null or arrays.items.len != 0) return null;
                if (mc.recv.int() >= n_regs or mc.recv.int() >= regs.len) return null;
                if (regs[mc.recv.int()] != .Instance) {
                    // Receiver snapshot was null/non-instance; a later snapshot may
                    // have a usable sample, so this bail is worth retrying.
                    transient.* = true;
                    return null;
                }
                var av: [3]Value = undefined;
                var k: u8 = 0;
                while (k < mc.n_args) : (k += 1) {
                    const ar = mc.args_reg + k;
                    if (ar >= regs.len) return null;
                    av[k] = regs[ar];
                }
                if (resolver.?(resolver_user.?, &regs[mc.recv.int()], mc.name, av[0..mc.n_args])) |fid| {
                    if (module.funcById(fid)) |f| {
                        if (f.is_suspend) return null;
                        if (mc.dst.int() < n_regs) member_ret[mc.dst.int()] = funcReturnRegType(module, f);
                    }
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
            // Object collection subscript: a `get` on a non-packed receiver whose
            // live element is an instance. Types the dst `.object`; the element is
            // fetched at run time through the normal `get` dispatch.
            if (arrayOpOf(module, inst)) |op| {
                if (op.is_set) continue;
                if (op.recv.int() >= n_regs or array_info[op.recv.int()] != null) continue; // packed -> native
                if (op.recv.int() >= regs.len or op.index.int() >= regs.len or op.dst.int() >= n_regs) return null;
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

    // Whole-function type inference must run before liveness so the read/def sets
    // can recognize object registers (held in `regs`, not slots) and exclude them.
    const types = try inferTypes(a, module, func, n_regs, array_info, cell_info, regs, member_ret);
    var ok = false;
    defer if (!ok) a.free(types);

    // A cell register's slot caches a scalar, so it must not be read or written
    // as a plain scalar anywhere in the loop (only via CellGet/CellSet). Reject
    // if any other instruction (or a branch cond) touches a cell register.
    {
        var reads: [3]Reg = undefined;
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

    const sets = try computeSets(a, module, func, body, header, n_regs, types);
    defer if (!ok) {
        a.free(sets.read);
        a.free(sets.def);
    };

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
            const is_obj_index = if (arrayOpOf(module, inst)) |op| (!op.is_set and typeAt(types, op.dst) == .object) else false;
            if (!is_call and !is_member and !is_field and !is_obj_move and !is_null_check and !is_obj_index) continue;
            if (arrays.items.len != 0) {
                if (debugEnabled()) std.debug.print("[jit]   bail: call + {d} arrays in {s}\n", .{ arrays.items.len, func.name });
                return null;
            }
            // Every scalar arg must already live in a typed slot (field reads have none).
            const args_reg: u32 = if (is_call) trampolinableCallOf(inst).?.args_reg else if (is_member) trampolinableMemberOf(module, inst).?.args_reg else 0;
            const n_args: u8 = if (is_call) trampolinableCallOf(inst).?.n_args else if (is_member) trampolinableMemberOf(module, inst).?.n_args else 0;
            var k: u8 = 0;
            while (k < n_args) : (k += 1) {
                const ar = args_reg + k;
                if (ar >= n_regs or !isScalarRt(types[ar])) {
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
            if (is_obj_index) {
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
                // Object-vs-null test -> boolean slot. Identify the boxed operand;
                // an object-vs-object identity test is not supported.
                const b = inst.BinOp;
                const obj_reg: Reg = if (typeAt(types, b.lhs) == .object and typeAt(types, b.rhs) == .null_)
                    b.lhs
                else if (typeAt(types, b.rhs) == .object and typeAt(types, b.lhs) == .null_)
                    b.rhs
                else
                    return null;
                if (obj_reg.int() >= n_regs or b.dst.int() >= n_regs) return null;
                call_sites.append(a, .{
                    .dst_reg = b.dst.int(),
                    .recv_reg = obj_reg.int(),
                    .has_result = true,
                    .neg = b.op == .NotEq,
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
            } else if (is_call) {
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
                }) catch return null;
            } else {
                const mc = trampolinableMemberOf(module, inst).?;
                if (mc.recv.int() >= n_regs or mc.recv.int() >= regs.len or regs[mc.recv.int()] != .Instance) return null;
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
                    .is_member = true,
                    .recv_reg = mc.recv.int(),
                    .name = mc.name,
                    .recv_class = instanceClassIdentity(regs[mc.recv.int()]),
                    .recv_varies = recv_varies,
                }) catch return null;
            }
        }
    }
    const has_calls = call_sites.items.len != 0;
    const uc_slot: u32 = arr_slots; // arrays.len == 0 when has_calls, so == n_regs
    const tramp_slot: u32 = arr_slots + 1;
    const n_slots: u32 = arr_slots + (if (has_calls) @as(u32, 2) else 0);

    var c = Compiler{
        .a = a,
        .module = module,
        .func = func,
        .body = body,
        .types = types,
        .array_info = array_info,
        .cell_info = cell_info,
        .call_sites = call_sites.items,
        .uc_slot = uc_slot,
        .tramp_slot = tramp_slot,
        .n_regs = n_regs,
        .em = jit.Emitter.init(a),
        .block_label = try a.alloc(?jit.Emitter.Label, func.blocks.len),
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
    ok = true;
    return CompiledLoop{
        .exec = exec,
        .n_regs = n_regs,
        .n_slots = n_slots,
        .reg_types = types,
        .read_set = sets.read,
        .def_set = sets.def,
        .arrays = arrays_owned,
        .cells = cells_owned,
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

pub fn runLoop(self: *const CompiledLoop, regs: []Value, slots: []i64, tramp: ?TrampFn, user: ?*anyopaque) RunResult {
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
            if (site.recv_varies or !(site.is_member or site.is_field)) continue;
            if (site.recv_reg >= regs.len) return .bail;
            const rv = regs[site.recv_reg];
            if (rv != .Instance or instanceClassIdentity(rv) != site.recv_class) return .bail;
        }
        tctx = .{ .slots = slots.ptr, .compiled = self, .user = user.? };
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
            .i32 => .{ .Int = @truncate(slots[r]) },
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
    // value is a primitive of the same kind, so its release is a no-op.
    for (self.cells) |cu| {
        if (cu.reg.int() >= regs.len) continue;
        const v = regs[cu.reg.int()];
        if (v != .Cell) continue;
        const g = v.Cell.borrowMut();
        g.get().* = valueFromSlot(cu.rt, slots[cu.reg.int()]);
        g.deinit();
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

// --- per-function JIT state + the interpreter hook --------------------------

const HOT_THRESHOLD: u32 = 64;
/// A loop whose receiver/field types are read from the live frame can bail when
/// the snapshot catches an object register holding null (between traversals).
/// Such a bail is transient, so retry a few times (spaced by re-reaching the
/// threshold) before giving up — a later snapshot usually has a non-null sample.
const MAX_COMPILE_ATTEMPTS: u8 = 6;
const RETRY_GAP: u32 = 8;

pub const FuncJit = struct {
    counts: []u32,
    attempts: []u8,
    loops: std.AutoHashMapUnmanaged(u32, ?CompiledLoop) = .empty,
    a: Allocator,

    pub fn deinit(self: *FuncJit) void {
        self.a.free(self.counts);
        self.a.free(self.attempts);
        var it = self.loops.valueIterator();
        while (it.next()) |v| if (v.*) |*cl| cl.deinit();
        self.loops.deinit(self.a);
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
    if (jit_enabled_cache) |e| return e;
    const v = runtime.getenvSlice("KLIO_JIT");
    const on = v != null and v.?.len > 0 and !std.mem.eql(u8, v.?, "0");
    jit_enabled_cache = on;
    return on;
}

fn debugEnabled() bool {
    if (jit_debug_cache) |d| return d;
    const v = runtime.getenvSlice("KLIO_JIT_DEBUG");
    const on = v != null and v.?.len > 0 and !std.mem.eql(u8, v.?, "0");
    jit_debug_cache = on;
    return on;
}

threadlocal var states: std.AutoHashMapUnmanaged(usize, *FuncJit) = .empty;

fn forFunc(func: *const Func) ?*FuncJit {
    const a = std.heap.page_allocator;
    const key = @intFromPtr(func);
    if (states.get(key)) |s| return s;
    if (func.blocks.len == 0) return null;
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
    s.* = .{ .counts = counts, .attempts = attempts, .a = a };
    @memset(s.counts, 0);
    @memset(s.attempts, 0);
    states.put(a, key, s) catch {
        a.free(counts);
        a.free(attempts);
        a.destroy(s);
        return null;
    };
    return s;
}

/// Interpreter hook: at the start of block `cur`, count the entry and — once
/// hot — compile and run the natural loop with that header. Returns the resume
/// point (registers reboxed) when a compiled loop ran, else null. KLIO_JIT only.
pub fn maybeRunHot(module: *const Module, func: *const Func, regs: *std.ArrayList(Value), allocator: Allocator, cur: BlockId, tramp: ?TrampFn, user: ?*anyopaque, resolver: ?MemberResolver, field_resolver: ?FieldResolver) ?Resume {
    const fj = forFunc(func) orelse return null;
    const bi = cur.int();
    if (bi >= fj.counts.len) return null;

    if (!fj.loops.contains(bi)) {
        fj.counts[bi] += 1;
        if (fj.counts[bi] < HOT_THRESHOLD) return null;
        var transient = false;
        const compiled = tryCompile(std.heap.page_allocator, module, func, cur, regs.items, resolver, field_resolver, user, &transient) catch null;
        if (compiled == null) {
            // A transient bail (an object register snapshot held null) is worth
            // retrying a few times; a permanent bail is cached immediately.
            fj.attempts[bi] += 1;
            if (transient and fj.attempts[bi] < MAX_COMPILE_ATTEMPTS) {
                fj.counts[bi] = HOT_THRESHOLD - RETRY_GAP;
                return null;
            }
            fj.loops.put(fj.a, bi, null) catch return null;
            return null;
        }
        if (debugEnabled()) std.debug.print("[jit] compiled {s} block {d}\n", .{ func.name, bi });
        fj.loops.put(fj.a, bi, compiled) catch return null;
    }

    const entry = fj.loops.get(bi).?;
    if (entry == null) return null;
    const cl = &entry.?;

    if (regs.items.len < cl.n_regs) {
        regs.appendNTimes(allocator, .Unit, cl.n_regs - regs.items.len) catch return null;
    }
    // Slots live in a per-activation buffer, never a shared one: a trampolined
    // call can re-enter this hook for a nested hot loop, and that inner run must
    // not alias (or reallocate) the outer loop's live slots. Small loops use a
    // stack buffer; the rare larger loop falls back to a freed heap allocation.
    var stack_slots: [128]i64 = undefined;
    var heap_slots: ?[]i64 = null;
    defer if (heap_slots) |hs| std.heap.page_allocator.free(hs);
    const slots: []i64 = if (cl.n_slots <= stack_slots.len)
        stack_slots[0..cl.n_slots]
    else blk: {
        heap_slots = std.heap.page_allocator.alloc(i64, cl.n_slots) catch return null;
        break :blk heap_slots.?;
    };
    return switch (runLoop(cl, regs.items, slots, tramp, user)) {
        .resume_at => |res| res,
        .bail => null,
    };
}
