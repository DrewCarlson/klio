//! The machine type of a register, the class identifiers the emitter uses for
//! builtin shapes, and the operator mapping from IR to C.
const std = @import("std");
const stdlib = @import("stdlib");
const ir = @import("ir");
const Func = ir.Func;
const Module = ir.Module;
const cgen = @import("../cgen.zig");

const Error = cgen.Error;
const Parent = cgen.Parent;
const Program = cgen.Program;
const classIndexOfName = cgen.classIndexOfName;
const memberRoot = cgen.memberRoot;
const no = cgen.no;
const plainFieldName = cgen.plainFieldName;
const typeReaches = cgen.typeReaches;

/// Machine type of a register. A reference in a bare C local is invisible to the
/// precisely-rooted collector, so an object-typed register leaves the scalar subset.
pub const Ty = enum {
    i32,
    i64,
    f64,
    f32,
    boolean,
    unit,
    /// A UTF-16 code unit: an integer that prints and boxes as a character.
    char,
    /// Narrow integers. They compute as `Int`, but render as themselves.
    short,
    byte,
    /// Value classes over the signed widths, holding the same bits; only comparison,
    /// division and right shift read them differently, which C's unsigned types give.
    u32,
    u64,
    u16,
    u8,
    /// A reference. It lives in the frame's published slots, never a bare C local:
    /// the collector is precisely rooted and never scans the native stack.
    object,

    pub fn cName(self: Ty) []const u8 {
        return switch (self) {
            .i32 => "int32_t",
            .i64 => "int64_t",
            .f64 => "double",
            .f32 => "float",
            .boolean => "int32_t",
            .unit => "int32_t",
            .char => "uint16_t",
            .short => "int16_t",
            .byte => "int8_t",
            .u32 => "uint32_t",
            .u64 => "uint64_t",
            .u16 => "uint16_t",
            .u8 => "uint8_t",
            .object => "klio_value",
        };
    }

    pub fn isFloat(self: Ty) bool {
        return self == .f64 or self == .f32;
    }
};

/// The scalar type a declared Kotlin type names, or null for anything else.
pub fn tyOf(t: ir.TypeRef) ?Ty {
    // `Int?` admits null, so it is a reference and cannot live in an `int32_t`.
    if (t.nullable) return null;
    const n = t.name;
    if (std.mem.eql(u8, n, "Int")) return .i32;
    if (std.mem.eql(u8, n, "Long")) return .i64;
    if (std.mem.eql(u8, n, "Double")) return .f64;
    if (std.mem.eql(u8, n, "Float")) return .f32;
    if (std.mem.eql(u8, n, "Boolean")) return .boolean;
    if (std.mem.eql(u8, n, "Unit")) return .unit;
    if (std.mem.eql(u8, n, "Char")) return .char;
    if (std.mem.eql(u8, n, "Short")) return .short;
    if (std.mem.eql(u8, n, "Byte")) return .byte;
    if (std.mem.eql(u8, n, "UInt")) return .u32;
    if (std.mem.eql(u8, n, "ULong")) return .u64;
    if (std.mem.eql(u8, n, "UShort")) return .u16;
    if (std.mem.eql(u8, n, "UByte")) return .u8;
    return null;
}

/// The function's result type. `return_ty` is a placeholder `Unit` when the source
/// wrote no annotation, so the answer comes from the body's terminators.
pub fn funcRetTy(f: *const Func) ?Ty {
    // A declaration with no body has no register to read, so its annotation is all there is.
    if (f.blocks.len == 0) return tyOf(f.return_ty);
    var any_value = false;
    for (f.blocks) |*blk| {
        if (blk.terminator == .Return and blk.terminator.Return != null) any_value = true;
    }
    if (!any_value) return .unit;
    return tyOf(f.return_ty);
}

/// `funcRetTy` widened to the object case: a result only has to BE a reference.
pub fn funcRetTy2(m: *const Module, f: *const Func) ?Ty {
    if (funcRetTy(f)) |t| return t;
    _ = m;
    // An erased type parameter is still a reference; a member read off it refuses there.
    return .object;
}

pub fn constTy(c: ir.Const) ?Ty {
    return switch (c) {
        .Int => .i32,
        .Long => .i64,
        .Double => .f64,
        .Float => .f32,
        .Bool => .boolean,
        .Unit => .unit,
        .Char => .char,
        .Short => .short,
        .Byte => .byte,
        .UInt => .u32,
        .ULong => .u64,
        .UShort => .u16,
        .UByte => .u8,
        .String => .object,
        .Null => .object,
    };
}

/// Whether two machine types are the same bits read two ways: Kotlin's unsigned
/// integers are value classes over the signed widths, so a cast suffices.
pub fn sameWidthKind(a: Ty, b: Ty) bool {
    return switch (a) {
        .i32 => b == .u32,
        .u32 => b == .i32,
        .i64 => b == .u64,
        .u64 => b == .i64,
        .short => b == .u16 or b == .char,
        .u16 => b == .short or b == .char,
        .char => b == .u16 or b == .short,
        .byte => b == .u8,
        .u8 => b == .byte,
        else => false,
    };
}

pub fn isNumericTy(t: Ty) bool {
    return switch (t) {
        .i32, .i64, .f64, .f32, .char, .short, .byte, .u32, .u64, .u16, .u8 => true,
        else => false,
    };
}

/// The machine type a parameter takes. A `vararg` holds an ARRAY of its declared type.
pub fn paramTy(p: ir.Param) Ty {
    if (p.is_vararg) return .object;
    return tyOf(p.ty) orelse .object;
}

pub fn isStringReg(types: []const Ty, cls: []const ?u32, r: u32) bool {
    return types[r] == .object and cls[r] != null and cls[r].? == STRING_CLS;
}

/// A throwable. Exception classes are the runtime's own, carrying a message and a
/// stack rather than fields the emitter lays out, so construction goes through it.
pub const THROWABLE_CLS: u32 = std.math.maxInt(u32) - 3;

/// Recognised by a supertype chain ending at `Throwable`.
pub fn isThrowableClass(m: *const Module, cid: u32) bool {
    if (cid >= m.classes.items.len) return false;
    var cur = cid;
    var depth: u32 = 0;
    while (depth < 16) : (depth += 1) {
        const c = &m.classes.items[cur];
        if (std.mem.eql(u8, c.name, "Throwable")) return true;
        var next: ?u32 = null;
        for (c.supertypes) |sid| {
            if (sid.int() >= m.classes.items.len) continue;
            if (m.classes.items[sid.int()].is_interface) continue;
            next = sid.int();
        }
        cur = next orelse return false;
    }
    return false;
}

/// One type in the throwable hierarchy, numbered in preorder so every subtype of a
/// type falls in `[lo, hi)` and a handler tests two integers.
pub const ThrowTy = struct {
    name: []const u8,
    parent: ?u32 = null,
    lo: u32 = 0,
    hi: u32 = 0,
};

pub fn simpleName(n: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, n, '.')) |i| return n[i + 1 ..];
    return n;
}

/// The throwable hierarchy in preorder. Every type comes from the module's own class
/// table; a name it cannot place is refused rather than guessed at.
pub const ThrowTable = struct {
    types: []ThrowTy,

    pub fn deinit(self: *ThrowTable, gpa: std.mem.Allocator) void {
        gpa.free(self.types);
    }

    pub fn find(self: ThrowTable, name: []const u8) ?ThrowTy {
        const want = simpleName(name);
        for (self.types) |t| {
            if (std.mem.eql(u8, t.name, want)) return t;
        }
        return null;
    }
};

pub fn buildThrowTable(gpa: std.mem.Allocator, m: *const Module) Error!ThrowTable {
    var list: std.ArrayList(ThrowTy) = .empty;
    errdefer list.deinit(gpa);
    // Parent names resolve afterwards: a class can name a supertype not yet reached.
    var parent_names: std.ArrayList(?[]const u8) = .empty;
    defer parent_names.deinit(gpa);

    try list.append(gpa, .{ .name = "Throwable" });
    try parent_names.append(gpa, null);

    for (m.classes.items, 0..) |*c, i| {
        if (!isThrowableClass(m, @intCast(i))) continue;
        const nm = simpleName(c.name);
        var dup = false;
        for (list.items) |t| {
            if (std.mem.eql(u8, t.name, nm)) dup = true;
        }
        if (dup) continue;
        var pn: ?[]const u8 = null;
        for (c.supertypes) |sid| {
            if (sid.int() >= m.classes.items.len) continue;
            const sup = &m.classes.items[sid.int()];
            if (sup.is_interface) continue;
            pn = simpleName(sup.name);
        }
        try list.append(gpa, .{ .name = nm });
        try parent_names.append(gpa, pn);
    }
    // A type whose parent is not in the table hangs directly off `Throwable`.
    for (list.items, 0..) |*t, i| {
        if (i == 0) continue;
        t.parent = 0;
        const pn = parent_names.items[i] orelse continue;
        for (list.items, 0..) |cand, ci| {
            if (ci != i and std.mem.eql(u8, cand.name, pn)) {
                t.parent = @intCast(ci);
                break;
            }
        }
    }
    var next: u32 = 0;
    numberThrowSubtree(list.items, 0, &next, 0);
    return .{ .types = try list.toOwnedSlice(gpa) };
}

pub fn numberThrowSubtree(types: []ThrowTy, root: u32, next: *u32, depth: u32) void {
    if (depth > 32) return;
    types[root].lo = next.*;
    next.* += 1;
    for (types, 0..) |*t, i| {
        if (i == root) continue;
        if (t.parent != root) continue;
        numberThrowSubtree(types, @intCast(i), next, depth + 1);
    }
    types[root].hi = next.*;
}

/// A `List` register. Runtime values take handles outside the class table.
pub const LIST_CLS: u32 = std.math.maxInt(u32) - 1;

/// A capture cell: the box a `var` moves into when a lambda captures it.
pub const CELL_CLS: u32 = std.math.maxInt(u32) - 2;

/// An `Array<T>` or a primitive array; `elem` carries what it holds.
pub const ARRAY_CLS: u32 = std.math.maxInt(u32) - 4;

/// An iterator over a builtin container; `elem` carries what iteration yields.
pub const ITER_CLS: u32 = std.math.maxInt(u32) - 5;

/// An integer or character progression; `elem` carries what it counts.
pub const RANGE_CLS: u32 = std.math.maxInt(u32) - 6;

/// A builtin type's name used as a QUALIFIER: `Int` in `Int.MAX_VALUE`. Such a
/// register names a type and occupies nothing at run time.
pub const NUMCLS_BASE: u32 = std.math.maxInt(u32) - 40;

pub fn numCls(t: Ty) u32 {
    return NUMCLS_BASE + @intFromEnum(t);
}

pub fn numClsTy(cid: u32) ?Ty {
    if (cid < NUMCLS_BASE or cid > NUMCLS_BASE + 10) return null;
    return @enumFromInt(cid - NUMCLS_BASE);
}

pub fn builtinQualifier(name: []const u8) ?Ty {
    return tyOf(.{ .name = simpleName(name), .nullable = false, .args = &.{} });
}

/// One constant a builtin type's companion publishes, with its C spelling.
pub const BuiltinConst = struct { ty: Ty, text: []const u8 };

pub fn builtinConst(t: Ty, name: []const u8) ?BuiltinConst {
    const eq = std.mem.eql;
    if (eq(u8, name, "SIZE_BITS")) return switch (t) {
        .i32 => .{ .ty = .i32, .text = "INT32_C(32)" },
        .i64 => .{ .ty = .i32, .text = "INT32_C(64)" },
        .short, .char => .{ .ty = .i32, .text = "INT32_C(16)" },
        .byte => .{ .ty = .i32, .text = "INT32_C(8)" },
        .f64 => .{ .ty = .i32, .text = "INT32_C(64)" },
        .f32 => .{ .ty = .i32, .text = "INT32_C(32)" },
        else => null,
    };
    if (eq(u8, name, "SIZE_BYTES")) return switch (t) {
        .i32 => .{ .ty = .i32, .text = "INT32_C(4)" },
        .i64 => .{ .ty = .i32, .text = "INT32_C(8)" },
        .short, .char => .{ .ty = .i32, .text = "INT32_C(2)" },
        .byte => .{ .ty = .i32, .text = "INT32_C(1)" },
        .f64 => .{ .ty = .i32, .text = "INT32_C(8)" },
        .f32 => .{ .ty = .i32, .text = "INT32_C(4)" },
        else => null,
    };
    if (eq(u8, name, "MAX_VALUE")) return switch (t) {
        .i32 => .{ .ty = .i32, .text = "INT32_C(2147483647)" },
        .i64 => .{ .ty = .i64, .text = "INT64_C(9223372036854775807)" },
        .short => .{ .ty = .short, .text = "((int16_t)32767)" },
        .byte => .{ .ty = .byte, .text = "((int8_t)127)" },
        .char => .{ .ty = .char, .text = "((uint16_t)0xFFFF)" },
        .f64 => .{ .ty = .f64, .text = "1.7976931348623157e308" },
        .f32 => .{ .ty = .f32, .text = "3.4028234663852886e38f" },
        else => null,
    };
    if (eq(u8, name, "MIN_VALUE")) return switch (t) {
        // C has no negative literals, and the magnitude alone does not fit the type.
        .i32 => .{ .ty = .i32, .text = "(-INT32_C(2147483647) - 1)" },
        .i64 => .{ .ty = .i64, .text = "(-INT64_C(9223372036854775807) - 1)" },
        .short => .{ .ty = .short, .text = "((int16_t)(-32768))" },
        .byte => .{ .ty = .byte, .text = "((int8_t)(-128))" },
        .char => .{ .ty = .char, .text = "((uint16_t)0)" },
        // Kotlin's floating MIN_VALUE is the smallest positive value, a denormal.
        .f64 => .{ .ty = .f64, .text = "0x1p-1074" },
        .f32 => .{ .ty = .f32, .text = "0x1p-149f" },
        else => null,
    };
    if (eq(u8, name, "POSITIVE_INFINITY")) return switch (t) {
        .f64 => .{ .ty = .f64, .text = "((double)INFINITY)" },
        .f32 => .{ .ty = .f32, .text = "((float)INFINITY)" },
        else => null,
    };
    if (eq(u8, name, "NEGATIVE_INFINITY")) return switch (t) {
        .f64 => .{ .ty = .f64, .text = "(-(double)INFINITY)" },
        .f32 => .{ .ty = .f32, .text = "(-(float)INFINITY)" },
        else => null,
    };
    if (eq(u8, name, "NaN")) return switch (t) {
        .f64 => .{ .ty = .f64, .text = "((double)NAN)" },
        .f32 => .{ .ty = .f32, .text = "((float)NAN)" },
        else => null,
    };
    return null;
}

/// A function value of a given arity: `(Int) -> Int` is `FUNC_CLS_BASE + 1`; `elem`
/// carries what calling one yields.
pub const FUNC_CLS_BASE: u32 = std.math.maxInt(u32) - 20;

pub const FUNC_MAX_ARITY: u32 = 15;

pub fn funcCls(arity: u32) u32 {
    return FUNC_CLS_BASE + arity;
}

pub fn funcClsArity(cid: u32) ?u32 {
    if (cid < FUNC_CLS_BASE or cid > FUNC_CLS_BASE + FUNC_MAX_ARITY) return null;
    return cid - FUNC_CLS_BASE;
}

/// Parameter count from the `FunctionN` NAME, result from the last type argument:
/// a receiver or `#suspend` marker rides in the arguments ahead of the parameters.
pub fn functionTypeArity(name: []const u8) ?u32 {
    const tail = simpleName(name);
    if (!std.mem.startsWith(u8, tail, "Function")) return null;
    const digits = tail["Function".len..];
    if (digits.len == 0) return null;
    const n = std.fmt.parseInt(u32, digits, 10) catch return null;
    if (n > FUNC_MAX_ARITY) return null;
    return n;
}

/// The class a container's elements hold, read off the declared type: the `Shape`
/// of a `List<Shape>`. Null leaves a reference the emitter cannot dispatch on.
pub fn refElemCls(m: *const Module, c: ?u32, t: ir.TypeRef) ?u32 {
    const cid = c orelse return null;
    if (cid != LIST_CLS and cid != ARRAY_CLS) return null;
    if (t.args.len != 1) return null;
    if (tyOf(t.args[0]) != null) return null;
    return classIndexOfName(m, t.args[0]);
}

/// The class all of these registers hold: the first one's, walked up its supertypes.
pub fn commonCls(m: *const Module, cls: []const ?u32, base: u32, n: u32) ?u32 {
    if (n == 0) return null;
    var cand = cls[base] orelse return null;
    if (isBuiltinCls(cand)) return null;
    var steps: u32 = 0;
    while (steps < 32) : (steps += 1) {
        var all = true;
        var k: u32 = 1;
        while (k < n) : (k += 1) {
            const oc = cls[base + k] orelse return null;
            if (isBuiltinCls(oc)) return null;
            if (!typeReaches(m, oc, cand)) all = false;
        }
        if (all) return cand;
        if (cand >= m.classes.items.len) return null;
        const sup = m.classes.items[cand].supertypes;
        if (sup.len == 0) return null;
        cand = sup[0].int();
    }
    return null;
}

pub fn isToStringCall(name: []const u8, n_args: u32) bool {
    return n_args == 0 and std.mem.eql(u8, plainFieldName(name), "toString");
}

/// Whether a `toString()` site renders through the runtime rather than dispatching:
/// the receiver's class declares no override. Both passes ask, so they agree.
pub fn rendersToString(m: *const Module, prog: Program, cls: []const ?u32, recv: u32) bool {
    const rc = cls[recv] orelse return true;
    if (isBuiltinCls(rc)) return true;
    return memberRoot(m, prog, rc, "toString", 0) == null;
}

/// The class a call's result register carries. A declared `List` or `Array` is a
/// runtime value only when the runtime produces it: a body declared to return `List`
/// may return a class of its own, where a runtime list operation is a wrong answer.
pub fn callResultCls(m: *const Module, callee: *const Func) ?u32 {
    const cid = classIndexOfName(m, callee.return_ty) orelse return null;
    if (callee.hasBody() and (cid == LIST_CLS or cid == ARRAY_CLS)) return null;
    return cid;
}

pub fn refElemOf(c: ?u32, t: ir.TypeRef) ?Ty {
    const cid = c orelse return null;
    if (funcClsArity(cid) != null) return functionResultTy(t);
    if (cid == LIST_CLS and t.args.len == 1) return tyOf(t.args[0]);
    if (cid == ARRAY_CLS) {
        const ae = arrayElemOf(t);
        return if (ae == .unit) null else ae;
    }
    return null;
}

pub fn functionResultTy(t: ir.TypeRef) Ty {
    if (t.args.len == 0) return .object;
    return tyOf(t.args[t.args.len - 1]) orelse .object;
}

pub fn isBuiltinCls(cid: u32) bool {
    return cid == STRING_CLS or cid == LIST_CLS or cid == CELL_CLS or cid == THROWABLE_CLS or
        cid == ARRAY_CLS or cid == ITER_CLS or cid == RANGE_CLS or
        funcClsArity(cid) != null or numClsTy(cid) != null;
}

/// Element kind of a named array type, in `klio_nat_prim_array` order. Null for `Array<T>`.
pub fn primArrayKind(name: []const u8) ?u32 {
    const tail = simpleName(name);
    if (std.mem.eql(u8, tail, "IntArray")) return 0;
    if (std.mem.eql(u8, tail, "LongArray")) return 1;
    if (std.mem.eql(u8, tail, "DoubleArray")) return 2;
    if (std.mem.eql(u8, tail, "FloatArray")) return 3;
    if (std.mem.eql(u8, tail, "ShortArray")) return 4;
    if (std.mem.eql(u8, tail, "ByteArray")) return 5;
    if (std.mem.eql(u8, tail, "BooleanArray")) return 6;
    if (std.mem.eql(u8, tail, "CharArray")) return 7;
    return null;
}

/// The primitive-array kind a machine type packs into, in `klio_nat_prim_array` order.
pub fn primKindOfTy(t: Ty) ?u32 {
    return switch (t) {
        .i32 => 0,
        .i64 => 1,
        .f64 => 2,
        .f32 => 3,
        .short => 4,
        .byte => 5,
        .boolean => 6,
        .char => 7,
        else => null,
    };
}

pub fn primArrayElem(kind: u32) Ty {
    return switch (kind) {
        0 => .i32,
        1 => .i64,
        2 => .f64,
        3 => .f32,
        4 => .short,
        5 => .byte,
        6 => .boolean,
        7 => .char,
        else => .unit,
    };
}

/// The unsigned type a name denotes. Unsigned integers are value classes, so
/// `n.toUInt()` reinterprets the same bits rather than allocating.
pub fn unsignedTypeOf(name: []const u8) ?Ty {
    const tail = simpleName(name);
    if (std.mem.eql(u8, tail, "UInt")) return .u32;
    if (std.mem.eql(u8, tail, "ULong")) return .u64;
    if (std.mem.eql(u8, tail, "UShort")) return .u16;
    if (std.mem.eql(u8, tail, "UByte")) return .u8;
    return null;
}

pub fn isArrayTypeName(name: []const u8) bool {
    const tail = simpleName(name);
    return primArrayKind(name) != null or std.mem.eql(u8, tail, "Array");
}

pub fn arrayElemOf(t: ir.TypeRef) Ty {
    if (primArrayKind(t.name)) |k| return primArrayElem(k);
    if (t.args.len == 1) {
        if (tyOf(t.args[0])) |et| return et;
    }
    return .unit;
}

/// An array constructor spelled as a stdlib call: `intArrayOf(1, 2)`.
pub fn arrayOfIntrinsic(f: *const Func) ??u32 {
    if (!std.mem.startsWith(u8, f.fqn, "kotlin.")) return null;
    if (!std.mem.endsWith(u8, f.name, "ArrayOf")) {
        // `arrayOf` and `emptyArray` build a reference array, whose elements stay boxed.
        if (!std.mem.eql(u8, f.name, "arrayOf") and !std.mem.eql(u8, f.name, "emptyArray")) return null;
        return @as(?u32, null);
    }
    var buf: [32]u8 = undefined;
    const head = f.name[0 .. f.name.len - "ArrayOf".len];
    if (head.len == 0 or head.len + 5 > buf.len) return null;
    buf[0] = std.ascii.toUpper(head[0]);
    @memcpy(buf[1 .. head.len], head[1..]);
    @memcpy(buf[head.len .. head.len + 5], "Array");
    return primArrayKind(buf[0 .. head.len + 5]) orelse return null;
}

/// A `String` register: not a user class, so it takes a handle outside the table.
pub const STRING_CLS: u32 = std.math.maxInt(u32);

pub fn promote(a: Ty, b: Ty) ?Ty {
    if (a == .boolean or b == .boolean or a == .unit or b == .unit) return null;
    if (a == .object or b == .object) return null;
    if (a == .f64 or b == .f64) return .f64;
    if (a == .f32 or b == .f32) return .f32;
    // Kotlin has no implicit conversion between a signed and an unsigned integer.
    const a_u = a == .u32 or a == .u64 or a == .u16 or a == .u8;
    const b_u = b == .u32 or b == .u64 or b == .u16 or b == .u8;
    if (a_u != b_u) return null;
    if (a_u) {
        if (a == .u64 or b == .u64) return .u64;
        return .u32;
    }
    if (a == .i64 or b == .i64) return .i64;
    // Kotlin's arithmetic on `Char`, `Short` and `Byte` produces an `Int`.
    return .i32;
}

pub fn isCmp(op: ir.BinOp) bool {
    return switch (op) {
        .Eq, .NotEq, .Less, .LessEq, .Greater, .GreaterEq => true,
        else => false,
    };
}

pub fn isBitwise(op: ir.BinOp) bool {
    return switch (op) {
        .And, .Or, .Xor, .Shl, .Shr, .UShr => true,
        else => false,
    };
}

/// The unsigned C type of the same width, in which an integer operation is performed
/// so it wraps the way Kotlin's does. Null where C's own semantics already match.
pub fn wrapTy(t: Ty) ?[]const u8 {
    return switch (t) {
        .i32 => "uint32_t",
        .i64 => "uint64_t",
        .short => "uint16_t",
        .byte => "uint8_t",
        .char => "uint16_t",
        .u32, .u64, .u16, .u8 => null,
        else => null,
    };
}

pub fn cOp(op: ir.BinOp) ?[]const u8 {
    return switch (op) {
        .Add => "+",
        .Sub => "-",
        .Mul => "*",
        .Div => "/",
        .Mod => "%",
        .Eq => "==",
        .NotEq => "!=",
        .Less => "<",
        .LessEq => "<=",
        .Greater => ">",
        .GreaterEq => ">=",
        .And => "&",
        .Or => "|",
        .Xor => "^",
        .Shl => "<<",
        .Shr => ">>",
        else => null,
    };
}
