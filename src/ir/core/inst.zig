const std = @import("std");
const runtime = @import("runtime");
const root_ir = @import("../ir.zig");
const core_ids = @import("ids.zig");

const BlockId = core_ids.BlockId;
const ClassId = core_ids.ClassId;
const ConstId = core_ids.ConstId;
const FuncId = core_ids.FuncId;
const MethodSlotId = core_ids.MethodSlotId;
const NativeId = core_ids.NativeId;
const StaticId = core_ids.StaticId;
const NO_FUNC = core_ids.NO_FUNC;
const Reg = core_ids.Reg;
const Span = root_ir.Span;
const TypeRef = core_ids.TypeRef;

/// `CatchHandler.class_raw` when the handler names no class.
pub const NO_CLASS: u32 = std.math.maxInt(u32);

/// `CallStatic.init` when the call runs no init unit first.
pub const NO_UNIT: u32 = std.math.maxInt(u32);

/// One instruction. Every operand is an id; nothing is looked up by name.
pub const Inst = union(enum) {
    Const: struct { dst: Reg, value: ConstId },
    LoadParam: struct { dst: Reg, idx: u16 },
    LoadCapture: struct { dst: Reg, idx: u16 },
    Move: struct { dst: Reg, src: Reg },
    /// Box `src` into a capture cell for a `var` a nested lambda captures (Kotlin `Ref`).
    MakeCell: struct { dst: Reg, src: Reg },
    CellGet: struct { dst: Reg, cell: Reg },
    /// Store through the capture cell in `cell`, keeping the shared cell so every holder sees it.
    CellSet: struct { cell: Reg, value: Reg },
    /// Binary primitive operation; sema guarantees the operand types.
    BinOp: struct {
        dst: Reg,
        op: BinOp,
        lhs: Reg,
        rhs: Reg,
        /// The combine step of a compound assignment. For a mutable collection left operand
        /// the evaluator dispatches the in-place `<op>Assign`, keeping the receiver mutable.
        compound: bool = false,
    },
    UnOp: struct { dst: Reg, op: UnOp, operand: Reg },
    Not: struct { dst: Reg, src: Reg },
    NotNullAssert: struct { dst: Reg, src: Reg },
    /// Read of a local `lateinit var`: `src` still holding the declaration's `Null` means
    /// unassigned, which throws `kotlin.UninitializedPropertyAccessException` naming `name`.
    LateinitCheck: struct { dst: Reg, src: Reg, name: ConstId },
    Trace: struct { span: Span },
    /// Run `func` over the argument run: its native when it has one, else its body.
    /// `init`: the init unit the call runs first, the file of the facade that
    /// declares `func` when the caller is not code of that facade; `NO_UNIT`
    /// for none.
    CallStatic: struct { dst: Reg, func: FuncId, args: Reg, n_args: u32, init: u32 = NO_UNIT },
    /// Run the implementation of `slot` for the class of `args[0]`.
    RCallVirtual: struct { dst: Reg, slot: MethodSlotId, args: Reg, n_args: u32 },
    /// As `RCallVirtual`, through a member of interface `iface`.
    CallInterface: struct { dst: Reg, iface: ClassId, slot: MethodSlotId, args: Reg, n_args: u32 },
    /// Run host function `native` over the argument run.
    /// `direct`: a `super` call, which runs the native as it is. Otherwise a
    /// Kotlin receiver whose class overrides the member the native
    /// implements runs its override (`resolved.NativeRt.slot`).
    CallNative: struct { dst: Reg, native: NativeId, args: Reg, n_args: u32, direct: bool = false },
    /// Invoke the function value in `callee` with the argument run.
    RCallValue: struct { dst: Reg, callee: Reg, args: Reg, n_args: u32 },
    /// Allocate an instance of `class` with its slots seeded, then run `ctor`
    /// with the instance prepended; `dst` receives the constructor's `this`.
    RNewInstance: struct { dst: Reg, class: ClassId, ctor: FuncId, args: Reg, n_args: u32 },
    GetFieldSlot: struct { dst: Reg, obj: Reg, slot: u32 },
    SetFieldSlot: struct { obj: Reg, slot: u32, value: Reg },
    /// Read a static, running its init unit on first touch.
    LoadStatic: struct { dst: Reg, static: StaticId },
    StoreStatic: struct { static: StaticId, value: Reg },
    /// The singleton of an object or companion, constructed on first use.
    LoadObject: struct { dst: Reg, class: ClassId },
    /// A closure over `func` capturing the registers' values.
    MakeClosure: struct { dst: Reg, func: FuncId, captures: []const Reg },
    /// A callable reference: a closure over `adapter` with `bound` as capture
    /// 0; equality and `name` answer from `target`.
    FunctionRef: struct { dst: Reg, adapter: FuncId, target: FuncId, bound: ?Reg },
    /// A property reference; `setter` is `NO_FUNC` for a read-only property.
    RPropertyRef: struct { dst: Reg, getter: FuncId, setter: u32 = NO_FUNC, bound: ?Reg, name: ConstId },
    /// The `KClass` of `class`.
    ClassLiteral: struct { dst: Reg, class: ClassId },
    /// The `KClass` of the run-time class of `src`.
    ClassOf: struct { dst: Reg, src: Reg },
    RInstanceOf: struct { dst: Reg, src: Reg, class: ClassId, nullable: bool },
    /// A failed cast throws `ClassCastException`, or gives null when `safe`.
    RCast: struct { dst: Reg, src: Reg, class: ClassId, nullable: bool, safe: bool },
    /// As `RInstanceOf`, against the reified type value in `ty`.
    InstanceOfDyn: struct { dst: Reg, src: Reg, ty: Reg, nullable: bool },
    CastDyn: struct { dst: Reg, src: Reg, ty: Reg, nullable: bool, safe: bool },
    ArrayGet: struct { dst: Reg, array: Reg, index: Reg },
    ArraySet: struct { array: Reg, index: Reg, value: Reg },
    /// An array of `class` holding the argument run.
    NewArray: struct { dst: Reg, class: ClassId, args: Reg, n_args: u32 },
};

pub const BinOp = enum {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Pow,
    Eq,
    NotEq,
    Less,
    LessEq,
    Greater,
    GreaterEq,
    /// Equality on a value that came through `as Any` or a statically-Any-typed path.
    /// `Double` and `Float` compare bitwise, so NaN == NaN and +0.0 != -0.0.
    BoxedEq,
    BoxedNotEq,
    /// `===` / `!==`: compares heap values by backing-cell pointer, never dispatching `equals`.
    IdentEq,
    IdentNeq,
    And,
    Or,
    Xor,
    Shl,
    Shr,
    UShr,
    RangeTo,
    RangeUntil,
    DownTo,
    Elvis,
    StringConcat,
};

pub const UnOp = enum {
    Neg,
    Plus,
    Inc,
    Dec,
};

/// Visit every register operand of one instruction, generically over the `Inst` union:
/// `Reg`, `?Reg`, `[]Reg`, and the `args`+`n_args` contiguous-run convention. A field named `dst` reports `is_def = true`. Comptime-generated, so a new
/// variant is covered by construction.
pub fn visitInstRegs(inst: *const Inst, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Reg, bool) void) void {
    switch (inst.*) {
        inline else => |*payload| visitPayloadRegs(payload, ctx, cb),
    }
}

/// Same enumeration for a block terminator.
pub fn visitTerminatorRegs(t: *const Terminator, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Reg, bool) void) void {
    switch (t.*) {
        inline else => |*payload| visitPayloadRegs(payload, ctx, cb),
    }
}

pub fn visitPayloadRegs(payload: anytype, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Reg, bool) void) void {
    const P = @TypeOf(payload.*);
    if (P == Reg) {
        cb(ctx, payload.*, false);
        return;
    }
    if (P == ?Reg) {
        if (payload.*) |r| cb(ctx, r, false);
        return;
    }
    switch (@typeInfo(P)) {
        // A boxed payload: the registers sit behind the pointer.
        .pointer => |p| if (p.size == .one) visitPayloadRegs(payload.*, ctx, cb),
        .@"struct" => |st| {
            inline for (st.fields) |f| {
                const is_def = comptime std.mem.eql(u8, f.name, "dst");
                if (f.type == Reg) {
                    if (comptime std.mem.eql(u8, f.name, "args")) {
                        if (comptime @hasField(P, "n_args")) {
                            var k: u32 = 0;
                            while (k < payload.n_args) : (k += 1) {
                                cb(ctx, Reg.from(@field(payload, f.name).int() + k), false);
                            }
                            continue;
                        }
                    }
                    cb(ctx, @field(payload, f.name), is_def);
                } else if (f.type == ?Reg) {
                    if (@field(payload, f.name)) |r| cb(ctx, r, is_def);
                } else if (f.type == []Reg or f.type == []const Reg) {
                    for (@field(payload, f.name)) |r| cb(ctx, r, false);
                }
            }
        },
        else => {},
    }
}

pub const Terminator = union(enum) {
    Goto: BlockId,
    Branch: struct {
        cond: Reg,
        t: BlockId,
        f: BlockId,
    },
    Return: ?Reg,
    Throw: Reg,
    Unreachable,
};

/// Catch handler on a try-body block: on a Throw the evaluator pops handlers in stack
/// order and jumps to the first whose `type_name` matches; `exception_reg` gets the value.
pub const CatchHandler = struct {
    type_name: []const u8,
    handler: BlockId,
    exception_reg: Reg,
    /// The caught class, for a handler lowered from sema: it matches by
    /// `Module.classIsA` and `type_name` is not read. `NO_CLASS` otherwise.
    class_raw: u32 = NO_CLASS,
};

test "the instruction union stays within half a cache line" {
    // The evaluator's dispatch loop reads instructions linearly, so a union
    // that grows costs every arm and not just the one that grew it.
    try std.testing.expect(@sizeOf(Inst) <= 32);
}
