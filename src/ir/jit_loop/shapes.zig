//! Instruction shape recognition: constant classification and the matchers
//! that decide whether a single IR instruction is an array access, a numeric
//! conversion, a bitwise op, or one of the trampolinable call/field forms.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const common = @import("common.zig");
const type_infer = @import("types.zig");

const Value = runtime.Value;
const Module = ir.Module;
const Func = ir.Func;
const Inst = ir.Inst;
const Reg = ir.Reg;
const BlockId = ir.BlockId;
const FuncId = ir.FuncId;

const RegType = common.RegType;
const tagForRt = type_infer.tagForRt;

// --- supported-shape predicates ---------------------------------------------

pub fn constType(c: ir.Const) RegType {
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
pub fn constFloatBits(c: ir.Const) i64 {
    return switch (c) {
        .Double => |x| @bitCast(x),
        .Float => |x| @as(u32, @bitCast(x)),
        else => 0,
    };
}

pub fn constI64(c: ir.Const) i64 {
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

pub fn isNumeric(t: RegType) bool {
    return t == .i32 or t == .i64;
}
pub fn isFloat(t: RegType) bool {
    return t == .f64 or t == .f32;
}

/// The scalar `RegType` a capture cell holds, or null for kinds the integer JIT
/// does not cache (the cell stays interpreter-only).
pub fn cellScalarType(v: Value) ?RegType {
    return switch (v) {
        .Int, .Char, .Short, .Byte => .i32,
        .Long => .i64,
        .Double => .f64,
        .Float => .f32,
        .Bool => .boolean,
        else => null,
    };
}

/// The element buffer behind a `List` or a reference `Array<T>`, or null when the
/// value is neither. A live view (`subList`, a map `values` view, `asList`) is
/// excluded: its `items` is a window cache refreshed from the source on access,
/// not the storage the source writes through.
pub fn boxedElemsOf(v: Value) ?runtime.ValueList {
    return switch (v) {
        .List => |l| if (l.backing != null) null else l.items,
        .Array => |ad| if (ad.primKind() != null) null else ad.storage().boxed,
        else => null,
    };
}

/// How many elements of a boxed buffer are sampled to pick its scalar kind. The
/// per-read tag guard is what makes the compiled code correct, so the sample only
/// has to name the kind the loop will actually see; a wrong guess deopts.
const BOXED_ELEM_SAMPLE: usize = 32;

pub fn boxedElemShape(vl: runtime.ValueList) ?struct { rt: RegType, tag: u8 } {
    const g = vl.borrow();
    defer g.deinit();
    const items = g.get().items;
    if (items.len == 0) return null;
    const rt = cellScalarType(items[0]) orelse return null;
    const tag = tagForRt(rt) orelse return null;
    for (items[0..@min(items.len, BOXED_ELEM_SAMPLE)]) |e| {
        if (@intFromEnum(std.meta.activeTag(e)) != tag) return null;
    }
    return .{ .rt = rt, .tag = tag };
}

pub fn isArithBinOp(op: ir.BinOp) bool {
    return switch (op) {
        .Add, .Sub, .Mul => true,
        else => false,
    };
}
pub fn isDivBinOp(op: ir.BinOp) bool {
    return op == .Div or op == .Mod;
}
/// Integer bitwise / shift operators. Their result takes the LEFT operand's
/// kind, the same rule `bitwiseOpOf` applies to the call-shaped spellings.
pub fn isBitwiseBinOp(op: ir.BinOp) bool {
    return switch (op) {
        .And, .Or, .Xor, .Shl, .Shr, .UShr => true,
        else => false,
    };
}
pub fn isCmpBinOp(op: ir.BinOp) bool {
    return switch (op) {
        .Eq, .NotEq, .Less, .LessEq, .Greater, .GreaterEq => true,
        else => false,
    };
}

// --- array subscripts -------------------------------------------------------

/// An array subscript recognized in the IR. Subscripts lower to `CallMember`
/// "get"/"set" (the interpreter fast-paths them), not to `Index`/`IndexSet`,
/// so the JIT matches that shape directly (and the dedicated instructions too).
pub const ArrayOp = struct { is_set: bool, recv: Reg, index: Reg, value: Reg, dst: Reg };

pub fn arrayOpOf(module: *const Module, inst: *const Inst) ?ArrayOp {
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

/// Whether any subscript in the body STORES through `recv`. A boxed element store
/// would have to release the element it overwrites and retag the slot, so those
/// receivers keep the interpreted subscript.
pub fn bodyStoresInto(module: *const Module, func: *const Func, body: []const BlockId, recv: Reg) bool {
    for (body) |bid| {
        for (func.blocks[bid.int()].insts) |*inst| {
            const op = arrayOpOf(module, inst) orelse continue;
            if (op.is_set and op.recv.int() == recv.int()) return true;
        }
    }
    return false;
}

/// A zero-arg numeric conversion (`x.toDouble()`/`toLong()`/`toInt()`), which
/// lowers to `CallMember`. The JIT compiles the always-exact directions
/// (int→double, int width changes); double→int is left to the interpreter
/// because `cvttsd2si` diverges from Kotlin on NaN/overflow (it clamps).
const NumConv = struct { dst: Reg, src: Reg, to: RegType };

pub fn numericConvOf(module: *const Module, inst: *const Inst) ?NumConv {
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
        // The same conversion on a scalar also lowers as a VIRTUAL call
        // (`k.toLong()` did), and the slot is rooted at its declaring
        // function — so the name comes from there. Only the builtin
        // declarations count: a user class's own `toLong()` is a real call.
        .CallVirtual => |cv| {
            if (cv.arg_names.len != 0 or cv.n_args != 0) return null;
            if (cv.arg_params != null or cv.trailing_lambda) return null;
            const decl = module.funcById(ir.FuncId.from(cv.slot.int())) orelse return null;
            if (!std.mem.startsWith(u8, decl.fqn, "kotlin.")) return null;
            const to: RegType = if (std.mem.eql(u8, decl.name, "toDouble"))
                .f64
            else if (std.mem.eql(u8, decl.name, "toFloat"))
                .f32
            else if (std.mem.eql(u8, decl.name, "toLong"))
                .i64
            else if (std.mem.eql(u8, decl.name, "toInt"))
                .i32
            else
                return null;
            return .{ .dst = cv.dst, .src = cv.receiver, .to = to };
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

pub fn bitwiseOpOf(module: *const Module, inst: *const Inst) ?BitOp {
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
const TrampCall = struct { func: FuncId, args_reg: u32, n_args: u32, dst: Reg };

pub fn trampolinableCallOf(inst: *const Inst) ?TrampCall {
    switch (inst.*) {
        .Call => |c| {
            if (c.arg_names.len != 0 or c.type_args.len != 0) return null;
            if (c.n_args > 6) return null;
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

pub fn trampolinableCallValueOf(inst: *const Inst) ?TrampCallValue {
    switch (inst.*) {
        .CallValue => |cv| {
            if (cv.arg_names.len != 0 or cv.type_args.len != 0) return null;
            if (cv.n_args > 6) return null;
            return .{ .callee = cv.callee, .args_reg = cv.args.int(), .n_args = cv.n_args, .dst = cv.dst };
        },
        else => return null,
    }
}

const TrampGlobal = struct { dst: Reg, name: []const u8 };

pub fn trampolinableGlobalOf(module: *const Module, inst: *const Inst) ?TrampGlobal {
    switch (inst.*) {
        .LoadGlobal => |lg| {
            // An identity-resolved binding (a function/class value) reads by
            // id, not by name — the by-name handler would find a different
            // (or no) value.
            if (lg.func != null or lg.class != null or lg.ctor_ref) return null;
            if (lg.name.int() >= module.consts.items.len) return null;
            const name = module.consts.items[lg.name.int()];
            if (name != .String) return null;
            return .{ .dst = lg.dst, .name = name.String };
        },
        else => return null,
    }
}

pub fn isCallableValue(v: Value) bool {
    return switch (v) {
        .IrClosure, .Intrinsic, .BoundMethod => true,
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
    /// Declared-receiver head for the dispatch (`callMemberNamedDeclared`);
    /// empty = plain by-name dispatch. Dropping it re-resolved an interface
    /// default's `this` call against the wrong surface.
    declared: []const u8,
};

pub fn trampolinableMemberOf(module: *const Module, inst: *const Inst) ?TrampMember {
    // Subscripts / numeric conversions / bitwise infix ops also lower to
    // `CallMember` but are compiled natively, not trampolined — exclude them.
    if (arrayOpOf(module, inst) != null) return null;
    if (numericConvOf(module, inst) != null) return null;
    if (bitwiseOpOf(module, inst) != null) return null;
    switch (inst.*) {
        .CallMember => |cm| {
            if (cm.arg_names.len != 0 or cm.static_recv != null) return null;
            if (cm.n_args > 6) return null;
            if (cm.name.int() >= module.consts.items.len) return null;
            const name = module.consts.items[cm.name.int()];
            if (name != .String) return null;
            var declared: []const u8 = "";
            if (cm.declared_recv) |did| {
                if (did.int() < module.consts.items.len and module.consts.items[did.int()] == .String) {
                    declared = module.consts.items[did.int()].String;
                } else return null;
            }
            return .{
                .recv = cm.receiver,
                .name = name.String,
                .args_reg = cm.args.int(),
                .n_args = cm.n_args,
                .dst = cm.dst,
                .resolved = cm.resolved,
                .dispatch_recv = cm.dispatch_receiver,
                .declared = declared,
            };
        },
        else => return null,
    }
}

/// A slot-resolved `CallVirtual` the loop JIT can trampoline: the callback
/// runs the host's virtual dispatch with the recorded slot. Positional only
/// (a param map, named args, or a trailing lambda keeps the interpreted arm's
/// binding machinery), at most three args like the other tramp forms.
const TrampVirtual = struct { recv: Reg, slot: u32, args_reg: u32, n_args: u32, dst: Reg };

pub fn trampolinableVirtualOf(inst: *const Inst) ?TrampVirtual {
    switch (inst.*) {
        .CallVirtual => |cv| {
            if (cv.arg_names.len != 0 or cv.arg_params != null) return null;
            if (cv.trailing_lambda) return null;
            if (cv.n_args > 6) return null;
            return .{ .recv = cv.receiver, .slot = cv.slot.int(), .args_reg = cv.args.int(), .n_args = cv.n_args, .dst = cv.dst };
        },
        else => return null,
    }
}

/// `fn(user, receiver, method_name, args) -> resolved method FuncId | null`. The
/// loop JIT calls this at compile time (with the live receiver/args) to learn a
/// trampolined member call's return type; null means unresolvable/intrinsic, so
/// the call is not trampolined.
pub const MemberResolver = *const fn (*anyopaque, *const Value, []const u8, []const Value) ?FuncId;

/// `fn(user, receiver, slot) -> the FuncId the virtual slot dispatches to on
/// the receiver's class | null`. Compile-time only, like `MemberResolver`:
/// it lets a loop-invariant virtual call inline its (monomorphic) target
/// natively; null keeps the site a trampoline.
pub const VirtResolver = *const fn (*anyopaque, *const Value, u32) ?FuncId;

/// A `GetField` the loop JIT can trampoline: a property read on a loop-invariant
/// boxed object, handled as a direct stored-field read (the receiver stays boxed
/// in the frame's registers, exactly like a member call's receiver).
const TrampField = struct { recv: Reg, name: []const u8, dst: Reg };

pub fn trampolinableFieldOf(module: *const Module, inst: *const Inst) ?TrampField {
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
pub fn memberFieldName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "$sgetter$") or std.mem.startsWith(u8, name, "$ssetter$")) {
        if (std.mem.findScalarLast(u8, name, 0x1f)) |i| return name[i + 1 ..];
    }
    return name;
}

/// A `SetField` the loop JIT can compile: a write of a scalar value to a plain
/// stored field of a loop-invariant (or class-stable) boxed object.
const TrampFieldSet = struct { recv: Reg, name: []const u8, value: Reg };

pub fn trampolinableFieldSetOf(module: *const Module, inst: *const Inst) ?TrampFieldSet {
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
