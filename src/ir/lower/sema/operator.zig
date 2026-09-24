//! Operators: the primitive table binding the base's operator declarations
//! to instructions, and the binary, unary, index, compound and increment
//! constructs. Every operator is the call sema recorded; the table decides
//! only whether that call is one instruction.

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const body = @import("body.zig");
const call = @import("call.zig");
const name = @import("name.zig");

const Allocator = std.mem.Allocator;
const Builder = builder.Builder;
const Error = records.Error;
const CallRec = records.CallRec;
const NameRec = records.NameRec;
const NodeId = ast.NodeId;
const Reg = ir.Reg;
const Sym = sema.Sym;
const TypeId = sema.TypeId;

/// How a primitive `compareTo` orders its operands when called: integral
/// and `Char`, `Boolean` operands compare by value; floating ones
/// by the total order `Double.compareTo` has (`NaN` above everything,
/// `-0.0` below `0.0`).
pub const CompareKind = enum { integral, floating };

/// What a declaration the table binds lowers to.
pub const PrimOp = union(enum) {
    bin: ir.BinOp,
    un: ir.UnOp,
    not,
    identity,
    native: ir.NativeId,
    /// `compareTo` between primitives: `<`, `<=`, `>` and `>=` lower to the
    /// matching `BinOp`; a call is a three-way comparison.
    compare: CompareKind,
    /// `get` of an array or string element.
    array_get,
    /// `set` of an array element.
    array_set,
};

/// The primitive classes a value of a static type is, for the choices
/// Kotlin makes by static type (`==`, templates, the table's signatures).
pub const Prim = enum { boolean, char, byte, short, int, long, float, double, string };

pub fn isNumeric(p: Prim) bool {
    return switch (p) {
        .byte, .short, .int, .long, .float, .double => true,
        else => false,
    };
}

fn isFloating(p: Prim) bool {
    return p == .float or p == .double;
}

/// The primitive class `cls` is, or null.
pub fn primOfClass(s: *const sema.Sema, cls: Sym) ?Prim {
    if (cls == .none) return null;
    const bi = &s.builtins;
    if (cls == bi.boolean) return .boolean;
    if (cls == bi.char) return .char;
    if (cls == bi.byte) return .byte;
    if (cls == bi.short) return .short;
    if (cls == bi.int) return .int;
    if (cls == bi.long) return .long;
    if (cls == bi.float) return .float;
    if (cls == bi.double) return .double;
    if (cls == bi.string) return .string;
    return null;
}

/// The primitive class of type `t` (nullable or not), or null.
pub fn primOf(s: *const sema.Sema, t: TypeId) ?Prim {
    if (t == .none) return null;
    return primOfClass(s, s.types.classSym(t));
}

/// The array classes whose `get` and `set` are element access.
const array_classes = [_][]const u8{
    "kotlin.Array",       "kotlin.IntArray",   "kotlin.LongArray",
    "kotlin.ShortArray",  "kotlin.ByteArray",  "kotlin.CharArray",
    "kotlin.BooleanArray", "kotlin.DoubleArray", "kotlin.FloatArray",
};

pub const PrimTable = struct {
    map: std.AutoHashMapUnmanaged(Sym, PrimOp) = .empty,

    /// Binds the members of the base's primitive classes, `String` and the
    /// arrays by name and signature, once. A declaration whose meaning is
    /// not one instruction (a conversion, `toString`, `rangeTo`) is left to
    /// its body or native.
    pub fn init(a: Allocator, s: *sema.Sema) Error!PrimTable {
        var t: PrimTable = .{};
        const bi = &s.builtins;
        const classes = [_]Sym{ bi.boolean, bi.char, bi.byte, bi.short, bi.int, bi.long, bi.float, bi.double, bi.string };
        for (classes) |cls| {
            if (cls == .none) continue;
            try t.bindClass(a, s, cls, primOfClass(s, cls).?);
        }
        for (array_classes) |fqn| {
            const cls = s.classByFqn(fqn);
            if (cls == .none) continue;
            try t.bindArray(a, s, cls);
        }
        return t;
    }

    pub fn get(self: *const PrimTable, callee: Sym) ?PrimOp {
        return self.map.get(callee);
    }

    fn bindClass(t: *PrimTable, a: Allocator, s: *sema.Sema, cls: Sym, recv: Prim) Error!void {
        var it = s.syms.classInfo(cls).members.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |m| {
                if (s.syms.kind(m) != .function) continue;
                if (s.syms.flags(m).static) continue;
                try sema.headers.functionHeader(s, m);
                const info = s.syms.functionInfo(m);
                if (info.receiver != .none or info.context_params.len != 0 or info.type_params.len != 0) continue;
                var params: [2]?Prim = .{ null, null };
                var any_param = false;
                if (info.params.len > params.len) continue;
                for (info.params, 0..) |p, i| {
                    if (s.syms.flags(p).vararg) continue;
                    const pt = try sema.headers.paramType(s, p);
                    params[i] = if (s.types.isNullable(pt)) null else primOf(s, pt);
                    any_param = any_param or (s.types.classSym(pt) == s.builtins.any and s.types.isNullable(pt));
                }
                const op = bindMember(s.str(s.syms.name(m)), recv, info.params.len, params, any_param) orelse continue;
                try t.map.put(a, m, op);
            }
        }
    }

    fn bindArray(t: *PrimTable, a: Allocator, s: *sema.Sema, cls: Sym) Error!void {
        var it = s.syms.classInfo(cls).members.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |m| {
                if (s.syms.kind(m) != .function) continue;
                try sema.headers.functionHeader(s, m);
                const info = s.syms.functionInfo(m);
                if (info.receiver != .none) continue;
                const n = s.str(s.syms.name(m));
                if (info.params.len == 0) continue;
                const index_t = try sema.headers.paramType(s, info.params[0]);
                if (primOf(s, index_t) != .int or s.types.isNullable(index_t)) continue;
                if (std.mem.eql(u8, n, "get") and info.params.len == 1) {
                    try t.map.put(a, m, .array_get);
                } else if (std.mem.eql(u8, n, "set") and info.params.len == 2) {
                    try t.map.put(a, m, .array_set);
                }
            }
        }
    }
};

/// The operation a member `n` of primitive class `recv` with `arity`
/// parameters of primitive classes `params` is, or null. `any_param`: the
/// single parameter is `Any?` (`equals`).
fn bindMember(n: []const u8, recv: Prim, arity: usize, params: [2]?Prim, any_param: bool) ?PrimOp {
    const eql = std.mem.eql;
    const numeric = isNumeric(recv);
    if (arity == 0) {
        if (eql(u8, n, "not") and recv == .boolean) return .not;
        if (eql(u8, n, "unaryMinus") and numeric) return .{ .un = .Neg };
        // `Byte.unaryPlus()` and `Short.unaryPlus()` widen to `Int`.
        if (eql(u8, n, "unaryPlus") and (recv == .int or recv == .long or isFloating(recv))) return .identity;
        if (eql(u8, n, "inc") and (numeric or recv == .char)) return .{ .un = .Inc };
        if (eql(u8, n, "dec") and (numeric or recv == .char)) return .{ .un = .Dec };
        if (convertsTo(n)) |target| if (target == recv) return .identity;
        return null;
    }
    if (arity != 1) return null;
    // `equals` is boxed equality: a `Double` NaN equals itself, and an
    // `Int` never equals a `Long`.
    if (eql(u8, n, "equals") and any_param) return .{ .bin = .BoxedEq };
    const p = params[0] orelse return null;
    if (eql(u8, n, "get") and recv == .string and p == .int) return .array_get;
    if (eql(u8, n, "compareTo")) {
        // `String.compareTo` answers the difference at the first unequal
        // character, which its native computes.
        const same_family = (numeric and isNumeric(p)) or (recv == p and (recv == .char or recv == .boolean));
        if (!same_family) return null;
        return .{ .compare = if (isFloating(recv) or isFloating(p)) .floating else .integral };
    }
    const arith: ?ir.BinOp = if (eql(u8, n, "plus"))
        .Add
    else if (eql(u8, n, "minus"))
        .Sub
    else if (eql(u8, n, "times"))
        .Mul
    else if (eql(u8, n, "div"))
        .Div
    else if (eql(u8, n, "rem"))
        .Mod
    else
        null;
    if (arith) |op| {
        if (numeric and isNumeric(p)) return .{ .bin = op };
        // `Char + Int`, `Char - Int` and `Char - Char`.
        if (recv == .char and p == .int and (op == .Add or op == .Sub)) return .{ .bin = op };
        if (recv == .char and p == .char and op == .Sub) return .{ .bin = op };
        return null;
    }
    const bitwise: ?ir.BinOp = if (eql(u8, n, "and"))
        .And
    else if (eql(u8, n, "or"))
        .Or
    else if (eql(u8, n, "xor"))
        .Xor
    else
        null;
    if (bitwise) |op| {
        if (recv == p and (recv == .boolean or recv == .int or recv == .long)) return .{ .bin = op };
        return null;
    }
    const shift: ?ir.BinOp = if (eql(u8, n, "shl"))
        .Shl
    else if (eql(u8, n, "shr"))
        .Shr
    else if (eql(u8, n, "ushr"))
        .UShr
    else
        null;
    if (shift) |op| {
        if ((recv == .int or recv == .long) and p == .int) return .{ .bin = op };
        return null;
    }
    return null;
}

/// The primitive a conversion `toX()` makes.
fn convertsTo(n: []const u8) ?Prim {
    const table = .{
        .{ "toInt", Prim.int },   .{ "toLong", Prim.long },     .{ "toShort", Prim.short },
        .{ "toByte", Prim.byte }, .{ "toDouble", Prim.double }, .{ "toFloat", Prim.float },
        .{ "toChar", Prim.char },
    };
    inline for (table) |row| if (std.mem.eql(u8, n, row[0])) return row[1];
    return null;
}

// ------------------------------------------------------------ emission ----

/// Emits `op` over `regs` (the receiver, then the arguments) into `dst`.
pub fn emitPrimRegs(b: *Builder, op: PrimOp, dst: Reg, regs: []const Reg) Error!void {
    switch (op) {
        .bin => |bo| try b.emit(.{ .BinOp = .{ .dst = dst, .op = bo, .lhs = regs[0], .rhs = regs[1] } }),
        .un => |uo| try b.emit(.{ .UnOp = .{ .dst = dst, .op = uo, .operand = regs[0] } }),
        .not => try b.emit(.{ .Not = .{ .dst = dst, .src = regs[0] } }),
        .identity => try b.emit(.{ .Move = .{ .dst = dst, .src = regs[0] } }),
        .native => |nid| {
            const run = try b.run(regs);
            try b.emit(.{ .CallNative = .{ .dst = dst, .native = nid, .args = run, .n_args = @intCast(regs.len) } });
        },
        .compare => |kind| try emitThreeWay(b, kind, dst, regs[0], regs[1]),
        .array_get => try b.emit(.{ .ArrayGet = .{ .dst = dst, .array = regs[0], .index = regs[1] } }),
        .array_set => {
            try b.emit(.{ .ArraySet = .{ .array = regs[0], .index = regs[1], .value = regs[2] } });
            try b.emit(.{ .Move = .{ .dst = dst, .src = try b.emitConst(.Unit) } });
        },
    }
}

/// `emitPrimRegs` over the contiguous run of `n` registers at `run`, for a
/// call whose `How` is `.prim`.
pub fn emitPrim(b: *Builder, op: PrimOp, dst: Reg, run: Reg, n: u32) Error!void {
    var regs: [3]Reg = undefined;
    if (n > regs.len) return error.Unsupported;
    for (regs[0..n], 0..) |*r, i| r.* = Reg.from(run.int() + @as(u32, @intCast(i)));
    return emitPrimRegs(b, op, dst, regs[0..n]);
}

/// `a.compareTo(b)` on primitives: -1, 0 or 1.
fn emitThreeWay(b: *Builder, kind: CompareKind, dst: Reg, l: Reg, r: Reg) Error!void {
    const join = try b.newBlock();
    const less = try b.newBlock();
    const not_less = try b.newBlock();
    const greater = try b.newBlock();
    const not_greater = try b.newBlock();
    try branchOn(b, .Less, l, r, less, not_less);
    b.switchTo(less);
    try moveConst(b, dst, .{ .Int = -1 }, join);
    b.switchTo(not_less);
    try branchOn(b, .Greater, l, r, greater, not_greater);
    b.switchTo(greater);
    try moveConst(b, dst, .{ .Int = 1 }, join);
    b.switchTo(not_greater);
    switch (kind) {
        .integral => try moveConst(b, dst, .{ .Int = 0 }, join),
        .floating => {
            // Neither is below the other: equal, a NaN, or a zero of each
            // sign. The operands may be of different types (`2.compareTo(2f)`),
            // so nothing here compares their representations.
            // `l` is NaN when it is not equal to itself: NaN sorts last, and
            // equals itself.
            const l_nan = try b.newBlock();
            const l_num = try b.newBlock();
            try branchOn(b, .NotEq, l, l, l_nan, l_num);
            b.switchTo(l_nan);
            const both_nan = try b.newBlock();
            const only_l = try b.newBlock();
            try branchOn(b, .NotEq, r, r, both_nan, only_l);
            b.switchTo(both_nan);
            try moveConst(b, dst, .{ .Int = 0 }, join);
            b.switchTo(only_l);
            try moveConst(b, dst, .{ .Int = 1 }, join);
            b.switchTo(l_num);
            const r_nan = try b.newBlock();
            const equal = try b.newBlock();
            try branchOn(b, .NotEq, r, r, r_nan, equal);
            b.switchTo(r_nan);
            try moveConst(b, dst, .{ .Int = -1 }, join);
            // Numerically equal. Only zeros differ further: `-0.0` sorts
            // below `0.0`, and the sign of `1 / x` says which zero `x` is.
            b.switchTo(equal);
            // A zero is neither below nor above `0.0`; the relational
            // comparisons, unlike `==`, compare across the operand types.
            const zero = try b.emitConst(.{ .Double = 0.0 });
            const same = try b.newBlock();
            const not_below = try b.newBlock();
            try branchOn(b, .Less, l, zero, same, not_below);
            b.switchTo(not_below);
            const zeros = try b.newBlock();
            try branchOn(b, .Greater, l, zero, same, zeros);
            b.switchTo(same);
            try moveConst(b, dst, .{ .Int = 0 }, join);
            b.switchTo(zeros);
            const one = try b.emitConst(.{ .Double = 1.0 });
            const inv_l = b.newReg();
            try b.emit(.{ .BinOp = .{ .dst = inv_l, .op = .Div, .lhs = one, .rhs = l } });
            const inv_r = b.newReg();
            try b.emit(.{ .BinOp = .{ .dst = inv_r, .op = .Div, .lhs = one, .rhs = r } });
            const neg = try b.newBlock();
            const not_neg = try b.newBlock();
            try branchOn(b, .Less, inv_l, inv_r, neg, not_neg);
            b.switchTo(neg);
            try moveConst(b, dst, .{ .Int = -1 }, join);
            b.switchTo(not_neg);
            const pos = try b.newBlock();
            const signs_same = try b.newBlock();
            try branchOn(b, .Greater, inv_l, inv_r, pos, signs_same);
            b.switchTo(pos);
            try moveConst(b, dst, .{ .Int = 1 }, join);
            b.switchTo(signs_same);
            try moveConst(b, dst, .{ .Int = 0 }, join);
        },
    }
    b.switchTo(join);
}

fn branchOn(b: *Builder, op: ir.BinOp, l: Reg, r: Reg, t: ir.BlockId, f: ir.BlockId) Error!void {
    const c = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = c, .op = op, .lhs = l, .rhs = r } });
    b.terminate(.{ .Branch = .{ .cond = c, .t = t, .f = f } });
}

fn moveConst(b: *Builder, dst: Reg, c: ir.Const, next: ir.BlockId) Error!void {
    const v = try b.emitConst(c);
    try b.emit(.{ .Move = .{ .dst = dst, .src = v } });
    b.terminate(.{ .Goto = next });
}

/// A body for each function the table binds, so a virtual or interface call
/// reaches the operation (`Comparable<Int>.compareTo` on an `Int`): the
/// receiver and each parameter from their `LoadParam`, then the operation.
pub fn lowerPrimBody(b: *Builder, callee: Sym) Error!void {
    const op = b.p.prims.get(callee) orelse return error.Unsupported;
    const n = 1 + b.p.s.syms.functionInfo(callee).params.len;
    var regs: [3]Reg = undefined;
    if (n > regs.len) return error.Unsupported;
    for (regs[0..n], 0..) |*r, i| {
        r.* = b.newReg();
        try b.emit(.{ .LoadParam = .{ .dst = r.*, .idx = @intCast(i) } });
    }
    const dst = b.newReg();
    try emitPrimRegs(b, op, dst, regs[0..n]);
    b.terminate(.{ .Return = dst });
}

// ---------------------------------------------------------- constructs ----

/// Emits the call `rec` with receiver `recv` over already lowered operands:
/// one instruction when the table binds the callee, else through `emitCall`.
pub fn callOn(b: *Builder, rec: *const CallRec, recv: Reg, operands: []const Reg) Error!Reg {
    if (b.p.prims.get(rec.callee)) |op| {
        var regs: [3]Reg = undefined;
        if (operands.len + 1 > regs.len) return error.Unsupported;
        regs[0] = recv;
        @memcpy(regs[1 .. operands.len + 1], operands);
        const dst = b.newReg();
        try emitPrimRegs(b, op, dst, regs[0 .. operands.len + 1]);
        return dst;
    }
    const exprs = try b.p.a.alloc(?*const ast.Expr, operands.len);
    @memset(exprs, null);
    const regs = try b.p.a.alloc(?Reg, operands.len);
    for (operands, regs) |o, *r| r.* = o;
    return call.emitCall(b, rec, .{ .exprs = exprs, .regs = regs, .receiver = recv });
}

/// Arithmetic, comparisons, `==`, `in`, ranges, `&&`, `||`, `?:`, `===`.
pub fn lowerBinary(b: *Builder, e: *const ast.Expr) Error!Reg {
    const x = e.Binary;
    switch (x.op) {
        .And, .Or => return lowerShortCircuit(b, x.op == .And, x.lhs, x.rhs),
        .Elvis => return lowerElvis(b, x.lhs, x.rhs),
        .IdentEq, .IdentNeq => {
            const l = try body.lowerExpr(b, x.lhs);
            const r = try body.lowerExpr(b, x.rhs);
            const dst = b.newReg();
            try b.emit(.{ .BinOp = .{ .dst = dst, .op = if (x.op == .IdentEq) .IdentEq else .IdentNeq, .lhs = l, .rhs = r } });
            return dst;
        },
        .Eq, .Neq => {
            const l = try body.lowerExpr(b, x.lhs);
            const r = try body.lowerExpr(b, x.rhs);
            const eq = if (x.lhs.* == .NullLit or x.rhs.* == .NullLit)
                try identity(b, l, r)
            else
                try equality(b, l, b.exprType(x.lhs.id()), r, b.exprType(x.rhs.id()), try b.call(e.id()));
            return if (x.op == .Neq) negate(b, eq) else eq;
        },
        .In, .NotIn => {
            // `x in c` is `c.contains(x)`: the container is evaluated
            // first, as kotlinc does.
            const container = try body.lowerExpr(b, x.rhs);
            const elem = try body.lowerExpr(b, x.lhs);
            const rec = try b.call(e.id());
            const r = try callOn(b, &rec, container, &.{elem});
            return if (x.op == .NotIn) negate(b, r) else r;
        },
        .Lt, .Le, .Gt, .Ge => {
            const l = try body.lowerExpr(b, x.lhs);
            const r = try body.lowerExpr(b, x.rhs);
            const rec = try b.call(e.id());
            const cmp: ir.BinOp = switch (x.op) {
                .Lt => .Less,
                .Le => .LessEq,
                .Gt => .Greater,
                else => .GreaterEq,
            };
            const dst = b.newReg();
            if (b.p.prims.get(rec.callee)) |op| if (op == .compare) {
                try b.emit(.{ .BinOp = .{ .dst = dst, .op = cmp, .lhs = l, .rhs = r } });
                return dst;
            };
            // `compareTo`'s result against zero.
            const order = try callOn(b, &rec, l, &.{r});
            const zero = try b.emitConst(.{ .Int = 0 });
            try b.emit(.{ .BinOp = .{ .dst = dst, .op = cmp, .lhs = order, .rhs = zero } });
            return dst;
        },
        .Add, .Sub, .Mul, .Div, .Rem, .Range, .RangeUntil => {
            // Arithmetic over integer literals: a constant of the type sema
            // gave it.
            if (sema.body.intConstValue(e) != null) return foldedArithmetic(b, e);
            const l = try body.lowerExpr(b, x.lhs);
            const r = try body.lowerExpr(b, x.rhs);
            const rec = try b.call(e.id());
            return callOn(b, &rec, l, &.{r});
        },
        // A statement, never an expression the parser leaves here.
        .Assign => return b.fail(e.span(), "an assignment used as a value", .{}),
    }
}

/// `a == b` by the operands' static types: IEEE-754 on floating operands
/// and value equality on other primitives; otherwise the recorded `equals`,
/// as `a?.equals(b) ?: (b === null)` when `a` may be null.
pub fn equality(b: *Builder, l: Reg, lt: TypeId, r: Reg, rt: TypeId, rec: CallRec) Error!Reg {
    const s = b.p.s;
    const lp = primOf(s, lt);
    const rp = primOf(s, rt);
    if (lp != null and rp != null and lp.? != .string and rp.? != .string) {
        const dst = b.newReg();
        try b.emit(.{ .BinOp = .{ .dst = dst, .op = .Eq, .lhs = l, .rhs = r } });
        return dst;
    }
    const numeric_left = lp != null and lp.? != .string;
    if (!mayBeNull(s, lt)) return if (numeric_left) primEquals(b, l, lt, r, rec) else callOn(b, &rec, l, &.{r});
    const result = b.newReg();
    const on_null = try b.newBlock();
    const on_value = try b.newBlock();
    const join = try b.newBlock();
    const null_reg = try b.emitConst(.Null);
    const is_null = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = is_null, .op = .IdentEq, .lhs = l, .rhs = null_reg } });
    b.terminate(.{ .Branch = .{ .cond = is_null, .t = on_null, .f = on_value } });
    b.switchTo(on_null);
    const both = try identity(b, r, null_reg);
    try b.emit(.{ .Move = .{ .dst = result, .src = both } });
    b.terminate(.{ .Goto = join });
    b.switchTo(on_value);
    const eq = if (numeric_left) try primEquals(b, l, lt, r, rec) else try callOn(b, &rec, l, &.{r});
    try b.emit(.{ .Move = .{ .dst = result, .src = eq } });
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return result;
}

/// A primitive's `equals(other)` on a value of any type: false unless
/// `other` is of the same class, which the host's numeric equality would
/// otherwise widen (`1 == (1L as Any)` is false).
fn primEquals(b: *Builder, l: Reg, lt: TypeId, r: Reg, rec: CallRec) Error!Reg {
    const cls = b.p.br.classOfOpt(b.p.s.types.classSym(lt)) orelse return callOn(b, &rec, l, &.{r});
    const same = b.newReg();
    try b.emit(.{ .RInstanceOf = .{ .dst = same, .src = r, .class = cls, .nullable = false } });
    const result = b.newReg();
    const yes = try b.newBlock();
    const no = try b.newBlock();
    const join = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = same, .t = yes, .f = no } });
    b.switchTo(yes);
    try b.emit(.{ .Move = .{ .dst = result, .src = try callOn(b, &rec, l, &.{r}) } });
    b.terminate(.{ .Goto = join });
    b.switchTo(no);
    try b.emit(.{ .Move = .{ .dst = result, .src = try b.emitConst(.{ .Bool = false }) } });
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return result;
}

/// Whether a value of static type `t` can be null at run time.
pub fn mayBeNull(s: *sema.Sema, t: TypeId) bool {
    if (t == .none) return true;
    return switch (s.types.get(t)) {
        .class => |c| c.nullable,
        .param => |p| p.nullable or !p.dnn,
        else => true,
    };
}

fn identity(b: *Builder, l: Reg, r: Reg) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = dst, .op = .IdentEq, .lhs = l, .rhs = r } });
    return dst;
}

pub fn negate(b: *Builder, v: Reg) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .Not = .{ .dst = dst, .src = v } });
    return dst;
}

/// `a && b`, `a || b`: `b` runs only when `a` does not decide.
fn lowerShortCircuit(b: *Builder, is_and: bool, lhs: *const ast.Expr, rhs: *const ast.Expr) Error!Reg {
    const result = b.newReg();
    const l = try body.lowerExpr(b, lhs);
    try b.emit(.{ .Move = .{ .dst = result, .src = l } });
    const rhs_blk = try b.newBlock();
    const join = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = l, .t = if (is_and) rhs_blk else join, .f = if (is_and) join else rhs_blk } });
    b.switchTo(rhs_blk);
    const r = try body.lowerExpr(b, rhs);
    if (!b.terminated()) {
        try b.emit(.{ .Move = .{ .dst = result, .src = r } });
        b.terminate(.{ .Goto = join });
    }
    b.switchTo(join);
    return result;
}

/// `a ?: b`: `b` runs only when `a` is null.
fn lowerElvis(b: *Builder, lhs: *const ast.Expr, rhs: *const ast.Expr) Error!Reg {
    const result = b.newReg();
    const l = try body.lowerExpr(b, lhs);
    try b.emit(.{ .Move = .{ .dst = result, .src = l } });
    const null_reg = try b.emitConst(.Null);
    const is_null = try identity(b, l, null_reg);
    const rhs_blk = try b.newBlock();
    const join = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = is_null, .t = rhs_blk, .f = join } });
    b.switchTo(rhs_blk);
    const r = try body.lowerExpr(b, rhs);
    if (!b.terminated()) {
        try b.emit(.{ .Move = .{ .dst = result, .src = r } });
        b.terminate(.{ .Goto = join });
    }
    b.switchTo(join);
    return result;
}

/// `-`, `+`, `!`. A negated integer literal is a constant of the type sema
/// gave the expression.
pub fn lowerUnary(b: *Builder, e: *const ast.Expr) Error!Reg {
    const u = e.Unary;
    if (u.expr.* != .IntLit and sema.body.intConstValue(e) != null) return foldedArithmetic(b, e);
    const rec = b.call(e.id()) catch |err| switch (err) {
        error.Unrecorded => if ((u.op == .Neg or u.op == .Pos) and (u.expr.* == .IntLit or u.expr.* == .FloatLit))
            return foldedLiteral(b, e)
        else
            return err,
        else => return err,
    };
    const v = try body.lowerExpr(b, u.expr);
    return callOn(b, &rec, v, &.{});
}

/// Arithmetic over integer literals, folded in the width of the type sema
/// gave it.
fn foldedArithmetic(b: *Builder, e: *const ast.Expr) Error!Reg {
    const s = b.p.s;
    var t = b.exprType(e.id());
    if (t == .none) return b.fail(e.span(), "integer literal arithmetic with no type", .{});
    switch (s.types.get(t)) {
        .int_lit => |l| t = try sema.infer.intLitDefault(s, l),
        else => {},
    }
    t = try s.types.makeNotNull(t);
    const c = s.t;
    const bits: u8 = if (t == c.long or t == c.ulong) 64 else if (t == c.short or t == c.ushort) 16 else if (t == c.byte or t == c.ubyte) 8 else 32;
    const v = sema.body.intConstValueIn(e, bits) orelse return b.fail(e.span(), "integer literal arithmetic that does not fold", .{});
    return b.emitConst(try intConst(b, e, v));
}

fn foldedLiteral(b: *Builder, e: *const ast.Expr) Error!Reg {
    const u = e.Unary;
    const neg = u.op == .Neg;
    return switch (u.expr.*) {
        .IntLit => |lit| b.emitConst(try intConst(b, e, if (neg) -%lit.value else lit.value)),
        .FloatLit => |lit| b.emitConst(try floatConst(b, e, if (neg) -lit.value else lit.value, lit.kind)),
        else => unreachable,
    };
}

/// The integer constant `value` as the type sema gave node `e`.
pub fn intConst(b: *Builder, e: *const ast.Expr, value: i64) Error!ir.Const {
    const s = b.p.s;
    var t = b.exprType(e.id());
    if (t == .none) return b.fail(e.span(), "an integer literal with no type", .{});
    switch (s.types.get(t)) {
        .int_lit => |l| t = try sema.infer.intLitDefault(s, l),
        else => {},
    }
    t = try s.types.makeNotNull(t);
    const c = s.t;
    const bits: u64 = @bitCast(value);
    if (t == c.long) return .{ .Long = value };
    if (t == c.short) return .{ .Short = @truncate(value) };
    if (t == c.byte) return .{ .Byte = @truncate(value) };
    if (t == c.uint) return .{ .UInt = @truncate(bits) };
    if (t == c.ulong) return .{ .ULong = bits };
    if (t == c.ushort) return .{ .UShort = @truncate(bits) };
    if (t == c.ubyte) return .{ .UByte = @truncate(bits) };
    // `Int`, and a literal whose expected type is not integral (`Any`,
    // `Number`, `Comparable<Int>`) is an `Int` too.
    return .{ .Int = @truncate(value) };
}

pub fn floatConst(b: *Builder, e: *const ast.Expr, value: f64, kind: ast.FloatLitKind) Error!ir.Const {
    const s = b.p.s;
    const t = b.exprType(e.id());
    const is_float = if (t != .none) s.types.classSym(t) == s.builtins.float else kind == .Float;
    return if (is_float) .{ .Float = @floatCast(value) } else .{ .Double = value };
}

/// `recv[args]`.
pub fn lowerIndex(b: *Builder, e: *const ast.Expr) Error!Reg {
    const ix = e.Index;
    const recv = try body.lowerExpr(b, ix.receiver);
    const rec = try b.call(e.id());
    const idx = try lowerAll(b, ix.args);
    return callOn(b, &rec, recv, idx);
}

/// `recv[args] = value`: the `set` recorded on the assignment `node`.
pub fn lowerIndexSet(b: *Builder, target: *const ast.Expr, value: *const ast.Expr, node: NodeId) Error!void {
    const ix = target.Index;
    const recv = try body.lowerExpr(b, ix.receiver);
    const rec = try b.call(node);
    const regs = try b.p.a.alloc(Reg, ix.args.len + 1);
    for (ix.args, regs[0..ix.args.len]) |*arg, *r| r.* = try body.lowerExpr(b, arg);
    regs[ix.args.len] = try body.lowerExpr(b, value);
    _ = try callOn(b, &rec, recv, regs);
}

fn lowerAll(b: *Builder, exprs: []const ast.Expr) Error![]Reg {
    const regs = try b.p.a.alloc(Reg, exprs.len);
    for (exprs, regs) |*x, *r| r.* = try body.lowerExpr(b, x);
    return regs;
}

/// A compound assignment's or increment's target, its receiver and index
/// arguments evaluated once.
const Target = union(enum) {
    /// `recv[args]`: read by `get`, written by `set`.
    index: struct { recv: Reg, args: []Reg },
    /// A name or member: written through its name record on `recv`, and
    /// read through `read`, which is null for a target read as a whole.
    name: struct { recv: ?Reg, write: ?NameRec, read: ?NameRec = null },
};

/// Evaluates `target`'s receiver and indices and reads its value. `node`
/// holds the construct's records (`get`, `set`, the member read and
/// write); a bare name's read is on its own node. `pre` is a member
/// target's receiver when the caller has evaluated it already.
fn readTarget(b: *Builder, target: *const ast.Expr, c: *const records.Compound, pre: ?Reg) Error!struct { t: Target, value: Reg } {
    switch (target.*) {
        .Index => |ix| {
            const recv = try body.lowerExpr(b, ix.receiver);
            const args = try lowerAll(b, ix.args);
            const get = c.get orelse return error.Unrecorded;
            const v = try callOn(b, &get, recv, args);
            return .{ .t = .{ .index = .{ .recv = recv, .args = args } }, .value = v };
        },
        .Member => |m| {
            // An object or companion qualifier (`Obj.x += 1`) is no
            // expression: its object's record is on the member's node.
            if (c.read) |rd| {
                const recv = pre orelse try name.memberReceiver(b, target.id(), m.receiver);
                const v = try name.read(b, &rd, recv);
                return .{ .t = .{ .name = .{ .recv = recv, .write = c.write, .read = rd } }, .value = v };
            }
            // A qualifier or `super` receiver: the target reads as a whole
            // and the write finds its receiver from its record.
            const v = try name.lowerName(b, target);
            const recv: ?Reg = if (c.write) |w| if (takesExpr(&w)) try name.memberReceiver(b, target.id(), m.receiver) else null else null;
            return .{ .t = .{ .name = .{ .recv = recv, .write = c.write } }, .value = v };
        },
        .Path => |p| {
            // The segments before the last read once, as a receiver.
            var recv: ?Reg = null;
            for (p.segments[0 .. p.segments.len - 1]) |seg| {
                const rd = b.nameAt(target.id(), seg.span.start) orelse continue;
                recv = try name.read(b, &rd, if (takesExpr(&rd)) recv else null);
            }
            const last = p.segments[p.segments.len - 1];
            const rd = if (p.segments.len == 1) try b.name(target.id()) else b.nameAt(target.id(), last.span.start) orelse return error.Unrecorded;
            const v = try name.read(b, &rd, if (takesExpr(&rd)) recv else null);
            return .{ .t = .{ .name = .{ .recv = recv, .write = c.write, .read = rd } }, .value = v };
        },
        else => return b.fail(target.span(), "an assignment target that is not a name, member or index", .{}),
    }
}

/// A prefix increment's value: the target read again after the write, or
/// `written` itself for a local, whose register holds it.
fn rereadTarget(b: *Builder, target: *const ast.Expr, t: Target, c: *const records.Compound, written: Reg) Error!Reg {
    switch (t) {
        .index => |ix| {
            const get = c.get orelse return error.Unrecorded;
            return callOn(b, &get, ix.recv, ix.args);
        },
        .name => |n| {
            const rd = n.read orelse return name.lowerName(b, target);
            if (rd.kind != .property) return written;
            return name.read(b, &rd, if (takesExpr(&rd)) n.recv else null);
        },
    }
}

fn isNameTarget(target: *const ast.Expr) bool {
    return switch (target.*) {
        .Index, .Member, .Path => true,
        else => false,
    };
}

fn takesExpr(rec: *const NameRec) bool {
    return rec.dispatch == .expr or rec.extension == .expr;
}

fn writeTarget(b: *Builder, t: Target, c: *const records.Compound, value: Reg, sp: @import("span").Span) Error!void {
    switch (t) {
        .index => |ix| {
            const set = c.set orelse return error.Unrecorded;
            const regs = try b.p.a.alloc(Reg, ix.args.len + 1);
            @memcpy(regs[0..ix.args.len], ix.args);
            regs[ix.args.len] = value;
            _ = try callOn(b, &set, ix.recv, regs);
        },
        .name => |n| {
            const w = n.write orelse return b.fail(sp, "a compound assignment with no recorded write", .{});
            try name.write(b, &w, if (takesExpr(&w)) n.recv else null, value);
        },
    }
}

/// The receiver of a `?.` member target whose receiver is an expression
/// (`a?.x += v`, `a?.x++`), evaluated once for the caller to test; null for
/// any other target.
fn safeReceiver(b: *Builder, target: *const ast.Expr, c: *const records.Compound) Error!?Reg {
    if (target.* != .Member or !target.Member.safe or c.read == null) return null;
    return try body.lowerExpr(b, target.Member.receiver);
}

/// `a op= b`: `opAssign` on the target's value when sema chose it, else
/// `a = a op b` with the target's receiver and indices evaluated once. On
/// a `?.` target nothing is evaluated past a null receiver.
pub fn lowerCompound(b: *Builder, a: *const ast.AssignStmt) Error!void {
    const c = try b.compound(a.id);
    // `opAssign` on a target that is no name, member or index
    // (`clauses!! += x`) calls it on the target's value, and nothing is
    // written back.
    if (c.assign_form and !isNameTarget(&a.target)) {
        const recv = try body.lowerExpr(b, &a.target);
        const v = try body.lowerExpr(b, &a.value);
        _ = try callOn(b, &c.op, recv, &.{v});
        return;
    }
    const pre = try safeReceiver(b, &a.target, &c);
    const join = if (pre) |r| blk: {
        const split = try b.branchOnNull(r);
        const join = try b.newBlock();
        b.switchTo(split.is_null);
        b.terminate(.{ .Goto = join });
        b.switchTo(split.not_null);
        break :blk join;
    } else null;
    const tgt = try readTarget(b, &a.target, &c, pre);
    const v = try body.lowerExpr(b, &a.value);
    const res = try callOn(b, &c.op, tgt.value, &.{v});
    if (!c.assign_form) try writeTarget(b, tgt.t, &c, res, a.span);
    if (join) |j| {
        b.terminate(.{ .Goto = j });
        b.switchTo(j);
    }
}

/// `++` and `--`, prefix and postfix: `inc` or `dec` on the target's value,
/// written back; the expression is the new value for a prefix and the old
/// one for a postfix. A prefix on a property or an index reads the target
/// again after the write, through its getter or `get` on the receiver and
/// indices already evaluated, as the JVM backend does (KT-42077). On a `?.` target it is null when the receiver is,
/// and nothing is read or written.
pub fn lowerIncDec(b: *Builder, e: *const ast.Expr) Error!Reg {
    const operand, const prefix = switch (e.*) {
        .Unary => |u| .{ u.expr, true },
        .Postfix => |p| .{ p.expr, false },
        else => unreachable,
    };
    const c = try b.compound(e.id());
    const pre = try safeReceiver(b, operand, &c);
    const result = if (pre != null) b.newReg() else undefined;
    const join = if (pre) |r| blk: {
        const split = try b.branchOnNull(r);
        const join = try b.newBlock();
        b.switchTo(split.is_null);
        try b.emit(.{ .Move = .{ .dst = result, .src = try b.nullValue() } });
        b.terminate(.{ .Goto = join });
        b.switchTo(split.not_null);
        break :blk join;
    } else null;
    const tgt = try readTarget(b, operand, &c, pre);
    // The read may be the local's own register, which the write replaces.
    const old = b.newReg();
    try b.emit(.{ .Move = .{ .dst = old, .src = tgt.value } });
    const res = try callOn(b, &c.op, old, &.{});
    try writeTarget(b, tgt.t, &c, res, e.span());
    const value = if (prefix) try rereadTarget(b, operand, tgt.t, &c, res) else old;
    const j = join orelse return value;
    try b.emit(.{ .Move = .{ .dst = result, .src = value } });
    b.terminate(.{ .Goto = j });
    b.switchTo(j);
    return result;
}
