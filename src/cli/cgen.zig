//! Ahead-of-time C generation: the program itself, not a launcher for it.
//!
//! The emitted file is self-contained. Every function is a C function, every
//! block a label, every register a typed C local, and every constant a C
//! literal — nothing here names a block or an instruction index, so nothing
//! reads the module at run time and no image is loaded.
//!
//! This is the scalar core: the statically-typed arithmetic subset, which needs
//! no runtime at all. Everything outside it is refused by `eligible` and the
//! caller falls back, so the set can widen without a correctness cliff. See
//! `plans/native-c-backend.md`.
const std = @import("std");
/// The interpreter's own stdlib table. A member the backend does not perform
/// directly is not a gap to fill here: the operation already exists, named, and
/// compiled code calls the same entry the interpreter does.
const stdlib = @import("stdlib");
/// The interpreter's member dispatch. Which builtin member calls the runtime
/// can serve is its classification, read here at compile time so the backend
/// keeps no second table of the same names.
const member_dispatch = @import("interp_ir").member_dispatch;
const ir = @import("ir");

const Reg = ir.Reg;
const Func = ir.Func;
const Module = ir.Module;

/// The machine type of a register. The scalar core carries exactly what a C
/// local can hold without the GC needing to see it: an object reference in a
/// bare C local would be invisible to a precisely-rooted collector, so an
/// object-typed register is what puts a function out of this subset.
pub const Ty = enum {
    i32,
    i64,
    f64,
    f32,
    boolean,
    unit,
    /// A UTF-16 code unit. Machine-wise an integer, but it prints as a
    /// character and boxes as one, so it cannot just be an `Int`.
    char,
    /// Kotlin's narrow integers. They compute as `Int` and Kotlin has no
    /// arithmetic that returns them, but they render as themselves.
    short,
    byte,
    /// Kotlin's unsigned integers. They are value classes over the signed
    /// widths, so they hold the same bits; only comparison, division and the
    /// right shift read them differently, which is exactly what C's unsigned
    /// types give.
    u32,
    u64,
    u16,
    u8,
    /// A reference. It lives in the frame's published slots, never a bare C
    /// local: the collector is precisely rooted and never scans the native
    /// stack, so a reference it cannot see is a reference it will free.
    object,

    fn cName(self: Ty) []const u8 {
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

    fn isFloat(self: Ty) bool {
        return self == .f64 or self == .f32;
    }
};

/// The scalar type a declared Kotlin type names, or null when it is anything
/// else. A nullable annotation is not a scalar: it admits null.
fn tyOf(t: ir.TypeRef) ?Ty {
    // A nullable annotation admits null, so it is a reference even when the
    // underlying type is a scalar: `Int?` cannot live in an `int32_t`.
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

/// The function's result type. `return_ty` is a PLACEHOLDER `Unit` when the
/// source wrote no annotation, so a body that returns nothing is read from the
/// body: every terminator returning no value means the result is Unit,
/// whatever the placeholder says.
fn funcRetTy(f: *const Func) ?Ty {
    // A declaration with no body — an interface method, an abstract one — has
    // no register to read the answer from, so its annotation is all there is.
    if (f.blocks.len == 0) return tyOf(f.return_ty);
    var any_value = false;
    for (f.blocks) |*blk| {
        if (blk.terminator == .Return and blk.terminator.Return != null) any_value = true;
    }
    if (!any_value) return .unit;
    return tyOf(f.return_ty);
}

/// `funcRetTy` widened to the object case, which needs the module to know
/// whether the declared type names a class the emitter can lay out.
/// A result only has to BE a reference for the caller to hold it; what its
/// layout is matters at the point a field is read, not here. An interface type
/// has no layout at all and never will.
fn funcRetTy2(m: *const Module, f: *const Func) ?Ty {
    if (funcRetTy(f)) |t| return t;
    _ = m;
    // A return type that names nothing the module declares — an erased type
    // parameter — is still a reference. Reading a member off it refuses where
    // it is read; passing it on does not have to.
    return .object;
}

fn constTy(c: ir.Const) ?Ty {
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
        // A string literal is a reference like any other: it lives in the
        // published frame so the collector can see it.
        .String => .object,
        .Null => .object,
    };
}

/// A conversion's receiver has to be a number: `x.toLong()` on a reference is
/// a call, not a C cast.
/// Whether two machine types are the same bits read two ways: Kotlin's
/// unsigned integers are VALUE classes over the signed widths, so a literal
/// written unsigned arrives as the signed width holding the same bits and
/// needs no conversion, only a cast.
fn sameWidthKind(a: Ty, b: Ty) bool {
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

fn isNumericTy(t: Ty) bool {
    return switch (t) {
        .i32, .i64, .f64, .f32, .char, .short, .byte, .u32, .u64, .u16, .u8 => true,
        else => false,
    };
}

/// The machine type a parameter takes. A `vararg` parameter holds an ARRAY of
/// its declared type rather than one of them: the call site collects the
/// trailing arguments into one, exactly as the interpreter packs them.
fn paramTy(p: ir.Param) Ty {
    if (p.is_vararg) return .object;
    return tyOf(p.ty) orelse .object;
}

fn isStringReg(types: []const Ty, cls: []const ?u32, r: u32) bool {
    return types[r] == .object and cls[r] != null and cls[r].? == STRING_CLS;
}

/// A throwable. Exception classes are the runtime's own — they carry a message
/// and a stack, not fields the emitter lays out — so constructing one goes
/// through the runtime.
const THROWABLE_CLS: u32 = std.math.maxInt(u32) - 3;

/// Whether a class is one of the runtime's throwables rather than a shape the
/// emitter lays out. Recognised by the supertype chain ending at `Throwable`,
/// which is what makes a class throwable in the first place.
fn isThrowableClass(m: *const Module, cid: u32) bool {
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

/// One type in the program's throwable hierarchy. The hierarchy is numbered in
/// preorder, so every subtype of a type falls in `[lo, hi)`: a thrown value
/// carries its own `lo` and a handler tests two integers, which is what makes
/// `catch (e: AppError)` see an `AppError` subtype however deep it sits.
const ThrowTy = struct {
    name: []const u8,
    parent: ?u32 = null,
    lo: u32 = 0,
    hi: u32 = 0,
};

/// The last segment of a dotted name. A catch clause and a class declaration
/// can spell the same type either way.
fn simpleName(n: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, n, '.')) |i| return n[i + 1 ..];
    return n;
}

/// The program's throwable hierarchy, numbered in preorder. Every type in it
/// comes from the module's own class table, user types and the ones the stdlib
/// pack declares alike: the emitter knows no throwable the program did not
/// lower, and a name it cannot place is refused rather than guessed at.
const ThrowTable = struct {
    types: []ThrowTy,

    fn deinit(self: *ThrowTable, gpa: std.mem.Allocator) void {
        gpa.free(self.types);
    }

    /// The interval a handler for this name tests against, or null when the
    /// program has no such throwable type.
    fn find(self: ThrowTable, name: []const u8) ?ThrowTy {
        const want = simpleName(name);
        for (self.types) |t| {
            if (std.mem.eql(u8, t.name, want)) return t;
        }
        return null;
    }
};

fn buildThrowTable(gpa: std.mem.Allocator, m: *const Module) Error!ThrowTable {
    var list: std.ArrayList(ThrowTy) = .empty;
    errdefer list.deinit(gpa);
    // Parent names are recorded first and resolved after, because a class can
    // name a supertype the table has not reached yet.
    var parent_names: std.ArrayList(?[]const u8) = .empty;
    defer parent_names.deinit(gpa);

    // `Throwable` roots the hierarchy: the language defines it as the type a
    // `throw` takes and a bare `catch` sees. Its declaration still comes from
    // the lowering, like every other type here.
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
    // Resolve each parent name to its index. A type whose parent is not in the
    // table hangs directly off `Throwable`, which is where the hierarchy ends.
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
    // Preorder numbering. Walking children by scan keeps the table flat, and a
    // throwable hierarchy is small enough that building it once costs nothing.
    var next: u32 = 0;
    numberThrowSubtree(list.items, 0, &next, 0);
    return .{ .types = try list.toOwnedSlice(gpa) };
}

fn numberThrowSubtree(types: []ThrowTy, root: u32, next: *u32, depth: u32) void {
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

/// A `List` register. Lists are runtime values, not user classes, so like
/// `String` they take a handle outside the class table.
const LIST_CLS: u32 = std.math.maxInt(u32) - 1;

/// A capture cell: the box a `var` moves into when a lambda captures it. Like
/// `String` and `List` it is a runtime type, not a user class; `elem` carries
/// what it holds.
const CELL_CLS: u32 = std.math.maxInt(u32) - 2;

/// Whether a class handle names a runtime type rather than a user class. Such
/// a handle indexes no class table and gets no emitted descriptor.
/// An `Array<T>` or one of the primitive arrays. Like `String` and `List` it is
/// a runtime type rather than a user class, so it takes a handle outside the
/// class table; `elem` carries what it holds.
const ARRAY_CLS: u32 = std.math.maxInt(u32) - 4;

/// An iterator over a builtin container. Like the container itself it is a
/// runtime value the interpreter already knows how to step, so the handle sits
/// outside the class table and `elem` carries what the iteration yields.
const ITER_CLS: u32 = std.math.maxInt(u32) - 5;

/// An integer or character progression. Like a list it is a runtime value the
/// interpreter builds and steps, so the handle sits outside the class table and
/// `elem` carries what it counts.
const RANGE_CLS: u32 = std.math.maxInt(u32) - 6;

/// A builtin type's name used as a QUALIFIER: `Int` in `Int.MAX_VALUE`. Such
/// a register names a type rather than holding a value, so like a lambda's it
/// is typed Unit with the type recorded and occupies nothing at run time.
const NUMCLS_BASE: u32 = std.math.maxInt(u32) - 40;

fn numCls(t: Ty) u32 {
    return NUMCLS_BASE + @intFromEnum(t);
}

fn numClsTy(cid: u32) ?Ty {
    if (cid < NUMCLS_BASE or cid > NUMCLS_BASE + 10) return null;
    return @enumFromInt(cid - NUMCLS_BASE);
}

/// The builtin type a bare name denotes when it is used as a qualifier.
fn builtinQualifier(name: []const u8) ?Ty {
    return tyOf(.{ .name = simpleName(name), .nullable = false, .args = &.{} });
}

/// One constant a builtin type's companion publishes, with the C spelling of
/// its value. These are the language's own numbers, not something the stdlib
/// pack computes, so the emitter writes them directly.
const BuiltinConst = struct { ty: Ty, text: []const u8 };

fn builtinConst(t: Ty, name: []const u8) ?BuiltinConst {
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
        // The largest finite value of each floating type.
        .f64 => .{ .ty = .f64, .text = "1.7976931348623157e308" },
        .f32 => .{ .ty = .f32, .text = "3.4028234663852886e38f" },
        else => null,
    };
    if (eq(u8, name, "MIN_VALUE")) return switch (t) {
        // Written as a subtraction: C has no negative literals, and the
        // magnitude alone does not fit the type.
        .i32 => .{ .ty = .i32, .text = "(-INT32_C(2147483647) - 1)" },
        .i64 => .{ .ty = .i64, .text = "(-INT64_C(9223372036854775807) - 1)" },
        .short => .{ .ty = .short, .text = "((int16_t)(-32768))" },
        .byte => .{ .ty = .byte, .text = "((int8_t)(-128))" },
        .char => .{ .ty = .char, .text = "((uint16_t)0)" },
        // Kotlin's floating MIN_VALUE is the smallest POSITIVE value, which is
        // denormal; a hex float names it exactly.
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

/// A function value of a given arity: `(Int) -> Int` is `FUNC_CLS_BASE + 1`.
/// Like `String` and `List` these are runtime types rather than user classes,
/// so they take handles outside the class table; `elem` carries what calling
/// one yields.
const FUNC_CLS_BASE: u32 = std.math.maxInt(u32) - 20;
const FUNC_MAX_ARITY: u32 = 15;

fn funcCls(arity: u32) u32 {
    return FUNC_CLS_BASE + arity;
}

fn funcClsArity(cid: u32) ?u32 {
    if (cid < FUNC_CLS_BASE or cid > FUNC_CLS_BASE + FUNC_MAX_ARITY) return null;
    return cid - FUNC_CLS_BASE;
}

/// The value-parameter count a `FunctionN` type names, and the type calling it
/// yields. A receiver or a `#suspend` marker rides in the type arguments ahead
/// of the parameters, so the count comes from the NAME and the result from the
/// last argument.
fn functionTypeArity(name: []const u8) ?u32 {
    const tail = simpleName(name);
    if (!std.mem.startsWith(u8, tail, "Function")) return null;
    const digits = tail["Function".len..];
    if (digits.len == 0) return null;
    const n = std.fmt.parseInt(u32, digits, 10) catch return null;
    if (n > FUNC_MAX_ARITY) return null;
    return n;
}

/// What a reference of this declared type yields when it is read through: the
/// result of calling a function value, the element of a list or an array. Null
/// when the type says nothing, which leaves whatever was already inferred.
/// The CLASS a container's elements hold, read off the declared type: the
/// `Shape` of a `List<Shape>`. Null when the type says nothing, which leaves a
/// reference the emitter cannot dispatch on.
fn refElemCls(m: *const Module, c: ?u32, t: ir.TypeRef) ?u32 {
    const cid = c orelse return null;
    if (cid != LIST_CLS and cid != ARRAY_CLS) return null;
    if (t.args.len != 1) return null;
    if (tyOf(t.args[0]) != null) return null;
    return classIndexOfName(m, t.args[0]);
}

/// The class every one of these registers holds: the first one's, walked up
/// its supertypes until the rest reach it. A list literal of mixed shapes
/// answers the type they share, which is what a member call on an element
/// dispatches through.
fn commonCls(m: *const Module, cls: []const ?u32, base: u32, n: u32) ?u32 {
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

/// `x.toString()` written on a value that declares no override of its own —
/// a number, a string, a list. The runtime renders it the way it renders it
/// for printing.
fn isToStringCall(name: []const u8, n_args: u32) bool {
    return n_args == 0 and std.mem.eql(u8, plainFieldName(name), "toString");
}

/// Whether a `toString()` call site renders through the runtime rather than
/// dispatching: the receiver's class declares no override of its own. Both
/// passes ask this, so they agree on which route the site takes.
fn rendersToString(m: *const Module, prog: Program, cls: []const ?u32, recv: u32) bool {
    const rc = cls[recv] orelse return true;
    if (isBuiltinCls(rc)) return true;
    return memberRoot(m, prog, rc, "toString", 0) == null;
}

/// The class a CALL's result register carries. A declared `List` or `Array` is
/// a runtime value only when the runtime is what produces it: a Kotlin body
/// declared to return `List` may return a class of its own that implements it
/// — the stdlib's `EmptyList` is one — and calling a runtime list operation on
/// that instance is a wrong answer rather than a slow one.
fn callResultCls(m: *const Module, callee: *const Func) ?u32 {
    const cid = classIndexOfName(m, callee.return_ty) orelse return null;
    if (callee.hasBody() and (cid == LIST_CLS or cid == ARRAY_CLS)) return null;
    return cid;
}

fn refElemOf(c: ?u32, t: ir.TypeRef) ?Ty {
    const cid = c orelse return null;
    if (funcClsArity(cid) != null) return functionResultTy(t);
    if (cid == LIST_CLS and t.args.len == 1) return tyOf(t.args[0]);
    if (cid == ARRAY_CLS) {
        const ae = arrayElemOf(t);
        return if (ae == .unit) null else ae;
    }
    return null;
}

/// What calling a function value yields, read off the last type argument. A
/// type that records none says nothing, so the result passes as a reference.
fn functionResultTy(t: ir.TypeRef) Ty {
    if (t.args.len == 0) return .object;
    return tyOf(t.args[t.args.len - 1]) orelse .object;
}

fn isBuiltinCls(cid: u32) bool {
    return cid == STRING_CLS or cid == LIST_CLS or cid == CELL_CLS or cid == THROWABLE_CLS or
        cid == ARRAY_CLS or cid == ITER_CLS or cid == RANGE_CLS or
        funcClsArity(cid) != null or numClsTy(cid) != null;
}

/// The element kind of a named array type, in the order the runtime's
/// `klio_nat_prim_array` names them. Null for a reference `Array<T>`.
fn primArrayKind(name: []const u8) ?u32 {
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

/// The primitive-array kind a machine type packs into, in the order the
/// runtime's `klio_nat_prim_array` names them. A reference element has none:
/// it goes into an `Array<T>`.
fn primKindOfTy(t: Ty) ?u32 {
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

/// The element type a primitive array holds.
fn primArrayElem(kind: u32) Ty {
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

/// The unsigned type a name denotes. Kotlin's unsigned integers are VALUE
/// classes, so `n.toUInt()` constructs one — which is a reinterpretation of the
/// same bits, not an allocation.
fn unsignedTypeOf(name: []const u8) ?Ty {
    const tail = simpleName(name);
    if (std.mem.eql(u8, tail, "UInt")) return .u32;
    if (std.mem.eql(u8, tail, "ULong")) return .u64;
    if (std.mem.eql(u8, tail, "UShort")) return .u16;
    if (std.mem.eql(u8, tail, "UByte")) return .u8;
    return null;
}

fn isArrayTypeName(name: []const u8) bool {
    const tail = simpleName(name);
    return primArrayKind(name) != null or std.mem.eql(u8, tail, "Array");
}

/// What an array type's elements are: a primitive array says so in its own
/// name, and an `Array<T>` in its type argument. Unit when nothing says.
fn arrayElemOf(t: ir.TypeRef) Ty {
    if (primArrayKind(t.name)) |k| return primArrayElem(k);
    if (t.args.len == 1) {
        if (tyOf(t.args[0])) |et| return et;
    }
    return .unit;
}

/// An array constructor spelled as a stdlib call: `intArrayOf(1, 2)`. The
/// element kind is the call's own, so nothing has to be inferred.
fn arrayOfIntrinsic(f: *const Func) ??u32 {
    if (!std.mem.startsWith(u8, f.fqn, "kotlin.")) return null;
    if (!std.mem.endsWith(u8, f.name, "ArrayOf")) {
        // `arrayOf` and `emptyArray` both build a reference array, whose
        // elements stay boxed; `emptyArray` just takes none.
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

/// The class marker for a register the emitter knows holds a `String`. Strings
/// are not user classes, so they take a handle outside the class table rather
/// than a `ClassId`.
const STRING_CLS: u32 = std.math.maxInt(u32);

/// Kotlin's binary numeric promotion, over the kinds this subset carries.
fn promote(a: Ty, b: Ty) ?Ty {
    if (a == .boolean or b == .boolean or a == .unit or b == .unit) return null;
    if (a == .object or b == .object) return null;
    if (a == .f64 or b == .f64) return .f64;
    if (a == .f32 or b == .f32) return .f32;
    // An unsigned type mixes only with its own kind: Kotlin has no implicit
    // conversion between a signed and an unsigned integer.
    const a_u = a == .u32 or a == .u64 or a == .u16 or a == .u8;
    const b_u = b == .u32 or b == .u64 or b == .u16 or b == .u8;
    if (a_u != b_u) return null;
    if (a_u) {
        if (a == .u64 or b == .u64) return .u64;
        return .u32;
    }
    if (a == .i64 or b == .i64) return .i64;
    // Kotlin has no arithmetic that returns `Char`, `Short` or `Byte`: every
    // operator on them produces an `Int`.
    return .i32;
}

fn isCmp(op: ir.BinOp) bool {
    return switch (op) {
        .Eq, .NotEq, .Less, .LessEq, .Greater, .GreaterEq => true,
        else => false,
    };
}

fn isBitwise(op: ir.BinOp) bool {
    return switch (op) {
        .And, .Or, .Xor, .Shl, .Shr, .UShr => true,
        else => false,
    };
}

/// The unsigned C type of the same width, in which an integer operation is
/// performed so that it wraps the way Kotlin's does. Null for the types where
/// C's own semantics already match.
fn wrapTy(t: Ty) ?[]const u8 {
    return switch (t) {
        .i32 => "uint32_t",
        .i64 => "uint64_t",
        .short => "uint16_t",
        .byte => "uint8_t",
        .char => "uint16_t",
        // Already unsigned: C wraps these by definition.
        .u32, .u64, .u16, .u8 => null,
        else => null,
    };
}

fn cOp(op: ir.BinOp) ?[]const u8 {
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

/// A function accepted into the scalar core, with the machine type of every
/// register its body defines.
pub const Compiled = struct {
    f: *const Func,
    /// The values a lambda body receives ahead of its own parameters: what it
    /// captured, passed as arguments because the call site knows them. Empty
    /// for an ordinary function.
    caps: []const CapInfo,
    /// The parameters this body is compiled against. Usually the function's
    /// own, but a synthesized thunk declares none and reads its caller's
    /// positionally, so it is compiled against the signature it is handed.
    params: []const ir.Param,
    types: []Ty,
    /// The class an object register holds, where the emitter knows it. Needed
    /// to turn a field NAME into the index the compiled code addresses.
    cls: []?u32,
    /// For a register holding a lambda, the body it will run and the registers
    /// it captured. A lambda whose call site can see which body it holds is
    /// called directly, with its captures passed as leading arguments — no
    /// closure object, no dispatch.
    lam: []?LambdaInfo,
    /// For a `List` register, the machine type of its elements where the
    /// emitter knows it — a list built from a literal of one scalar kind. Unit
    /// means unknown, and reading such a list yields an untyped reference.
    elem: []Ty,
    /// For a container register, the CLASS its elements hold where the emitter
    /// knows it — written down in `List<Shape>`, or an enum's own entries.
    /// Null means unknown, and reading such a container yields a reference the
    /// emitter cannot dispatch on.
    elem_cls: []?u32,
    /// Frame slot of each object register, or -1 for a scalar in a C local.
    slot: []i32,
    n_slots: u32,
    ret: Ty,
    /// The class and element type of the returned register, where the body
    /// returns a reference. The DECLARED return type cannot say this for an
    /// inferred one — `val doubled = side * 2` lowers to a thunk carrying a
    /// placeholder — so it comes from what the body actually returns.
    ret_cls: ?u32 = null,
    ret_elem: Ty = .unit,
    /// True for a `suspend` body. Its registers live in a heap frame and it
    /// answers either its result or the SUSPENDED marker, because it can
    /// return in the middle of itself and be re-entered later.
    suspends: bool = false,
    /// How each bare-name read or write inside an inlined receiver body
    /// resolved. The interpreter searches its implicit receivers at run time;
    /// the emitter does that search once, and the answer belongs to the
    /// instruction rather than to a register.
    bare: std.AutoHashMapUnmanaged(*const ir.Inst, BareResolution) = .empty,

    pub fn deinit(self: *Compiled, gpa: std.mem.Allocator) void {
        gpa.free(self.types);
        gpa.free(self.cls);
        gpa.free(self.elem);
        gpa.free(self.elem_cls);
        gpa.free(self.lam);
        gpa.free(self.slot);
        self.bare.deinit(gpa);
    }
};

/// Where a bare name inside an inlined receiver body actually lives.
pub const BareResolution = union(enum) {
    /// A field of one of the implicit receivers, at the index resolved here.
    field: struct { recv: u32, idx: u32 },
    /// A computed property of one of them, read or written through its
    /// accessor.
    accessor: struct { recv: u32, func: ir.FuncId },
    /// Nothing owned the name, so it is the top-level property it falls back
    /// to, looked up by name where the emission knows which globals the
    /// program kept.
    global,
    /// A bare CALL that bound to a member of an implicit receiver: which body
    /// runs is the receiver's class, as for any member call.
    member: struct { recv: u32, slot: u32 },
    /// A bare call that bound to the top-level declaration the lowering
    /// resolved, because no implicit receiver declares the name.
    call: ir.FuncId,
};

/// The instance fields of a class, in the order the runtime lays them out:
/// the primary-constructor parameters that double as properties. A class this
/// returns null for is one the emitter cannot lay out, and any program touching
/// it is refused.
/// Everything the emitter resolves once about the whole program and then asks
/// about repeatedly: class layouts, the inheritance links that initialize
/// them, the accessors a class declares, the throwable hierarchy, and the
/// default-argument thunks. Resolving any of these walks the module's tables,
/// so they are computed once and read from here.
pub const Program = struct {
    fields: []const ?[]const FieldInfo,
    /// The superclass each laid-out class extends, and the thunks it passes to
    /// that superclass's constructor. A class is initialized by walking this
    /// chain, so it is kept alongside the flattened field list.
    parents: []const ?Parent = &.{},
    /// The declared body properties, kept so a refusal can be re-derived and
    /// reported against the class that actually blocked a program.
    layouts: []const ClassLayout = &.{},
    /// The program's throwable hierarchy, numbered so a catch is an interval
    /// test rather than a name match.
    throws: ThrowTable = .{ .types = &.{} },
    /// Default-argument thunks per function.
    defaults: []const FuncDefaults = &.{},

    fn of(self: Program, cid: u32) ?[]const FieldInfo {
        if (cid >= self.fields.len) return null;
        return self.fields[cid];
    }

    fn parentOf(self: Program, cid: u32) ?Parent {
        if (cid >= self.parents.len) return null;
        return self.parents[cid];
    }

    /// The thunk that fills parameter `idx` of this function when a call omits
    /// it, or null when the parameter has no default.
    fn defaultThunk(self: Program, func: ir.FuncId, idx: usize) ?ir.FuncId {
        for (self.defaults) |d| {
            if (d.func != func) continue;
            if (idx >= d.slots.len) return null;
            return d.slots[idx];
        }
        return null;
    }

    /// The accessor a class declares for a property that has no storage of its
    /// own. Walks the superclass chain, because a computed property is
    /// inherited exactly as a stored one is.
    fn accessor(self: Program, m: *const Module, cid: u32, name: []const u8, comptime which: enum { get, set }) ?ir.FuncId {
        const want = plainFieldName(name);
        var cur: ?u32 = cid;
        var depth: u32 = 0;
        while (cur) |c| : (depth += 1) {
            if (depth > 32 or c >= m.classes.items.len) return null;
            const cdef9 = &m.classes.items[c];
            if (layoutFor(self.layouts, cdef9)) |l| {
                for (l.props) |bp| {
                    if (!std.mem.eql(u8, bp.name, want)) continue;
                    return switch (which) {
                        .get => bp.getter,
                        .set => bp.setter,
                    };
                }
            }
            cur = if (self.parentOf(c)) |pp| pp.cid else null;
        }
        return null;
    }
};

/// The superclass a class extends: which class, and the one thunk per
/// superclass constructor parameter that computes the argument to pass up.
pub const Parent = struct { cid: u32, args: []const ir.FuncId };

/// One field of a laid-out class: where its value comes from and what machine
/// type it holds.
const FieldInfo = struct {
    name: []const u8,
    ty: Ty,
    cls: ?u32,
    /// What reading THROUGH this field yields: a list's element, an array's
    /// element, the result of calling a function value.
    elem: Ty = .unit,
    /// The constructor argument that fills it, or null when a thunk does.
    arg: ?u32,
    init: ?ir.FuncId,
    /// True when a superclass declares this field. The superclass's own
    /// initializer fills it, so this class's does not.
    from_parent: bool = false,
    /// True when whoever builds the instance fills this field rather than the
    /// class's initializer: an enum entry's `name` and `ordinal` belong to the
    /// entry, not to the enum's constructor.
    preset: bool = false,
};

/// A class's flattened fields plus the superclass link used to initialize them.
/// `complete` is false while a body property's type is still unresolved: the
/// fields ahead of it are correct and can type an initializer, but the class
/// is not laid out until every property it declares has a place.
const Laid = struct { fields: []FieldInfo, parent: ?Parent, complete: bool = true };

/// A class's instance fields in layout order: the constructor properties first,
/// then the properties declared in the body. A class this returns null for is
/// one the emitter cannot lay out, and any program touching it is refused.
fn classFields(gpa: std.mem.Allocator, m: *const Module, layouts: []const ClassLayout, cid: ir.ClassId, prev: ?*const Program, globals: []const Global, last: bool) Error!?Laid {
    return classFieldsAt(gpa, m, layouts, cid, 0, prev, globals, last);
}

fn classFieldsAt(gpa: std.mem.Allocator, m: *const Module, layouts: []const ClassLayout, cid: ir.ClassId, depth: u32, prev: ?*const Program, globals: []const Global, last: bool) Error!?Laid {
    if (cid.int() >= m.classes.items.len) return null;
    const c = &m.classes.items[cid.int()];
    // A class table with a cycle in it would recurse forever; a real hierarchy
    // is nowhere near this deep.
    if (depth > 32) return layoutNo(c, "inheritance depth");
    // Each reason is named: this list is the backlog for widening the backend,
    // and "class layout" alone says nothing about which class shape is missing.
    if (c.init_block != null) return layoutNo(c, "init block");
    // An interface contributes no fields, so implementing one changes nothing
    // about the layout. A superCLASS contributes its own, laid out ahead of
    // this class's so a field index means the same thing through either type.
    var parent_id: ?ir.ClassId = null;
    for (c.supertypes) |sid| {
        if (sid.int() >= m.classes.items.len) return layoutNo(c, "unknown supertype");
        const sup = &m.classes.items[sid.int()];
        if (sup.is_interface) continue;
        if (parent_id != null) return layoutNo(c, "several superclasses");
        parent_id = sid;
    }
    if (c.is_interface) return layoutNo(c, "interface");
    // An `object` declares no constructor; its fields are its body properties
    // and its single instance is created once, before the program runs.
    if (c.is_object and c.primary_params.len != 0) return layoutNo(c, "object with constructor params");
    if (c.is_inner) return layoutNo(c, "inner class");

    var out: std.ArrayList(FieldInfo) = .empty;
    errdefer out.deinit(gpa);
    if (c.is_enum) {
        // Every entry carries its own name and position, which is what
        // `name`, `ordinal`, `toString` and a `when` over the entries read.
        // The entry construction fills them, not the enum's constructor.
        try out.append(gpa, .{ .name = "name", .ty = .object, .cls = STRING_CLS, .arg = null, .init = null, .preset = true });
        try out.append(gpa, .{ .name = "ordinal", .ty = .i32, .cls = null, .arg = null, .init = null, .preset = true });
    }
    var parent: ?Parent = null;
    if (parent_id) |sid| {
        // The superclass's fields come first and keep their own layout, so a
        // field read through the base type and through this one address the
        // same slot. Its initializer fills them, handed the arguments this
        // class's thunks compute.
        const up = (try classFieldsAt(gpa, m, layouts, sid, depth + 1, prev, globals, last)) orelse {
            out.deinit(gpa);
            return layoutNo(c, "superclass layout");
        };
        defer gpa.free(up.fields);
        const sup = &m.classes.items[sid.int()];
        const pargs: []const ir.FuncId = if (layoutFor(layouts, c)) |l| l.parent_args else &.{};
        if (pargs.len != sup.primary_params.len) {
            out.deinit(gpa);
            return layoutNo(c, "super constructor arity");
        }
        for (up.fields) |fd| {
            try out.append(gpa, .{
                .name = fd.name,
                .ty = fd.ty,
                .cls = fd.cls,
                .elem = fd.elem,
                .arg = null,
                .init = null,
                .from_parent = true,
            });
        }
        parent = .{ .cid = sid.int(), .args = pargs };
    }
    for (c.primary_params, 0..) |p, i| {
        // A constructor parameter that is not a property is an input, not a
        // field: it feeds the superclass call or a body initializer.
        if (!p.is_property) continue;
        // A default is the CONSTRUCTION's business, exactly as it is for a
        // call: the field exists either way, and a construction that omits the
        // parameter runs the thunk the declaration lowered for it.
        if (p.is_vararg) {
            out.deinit(gpa);
            return layoutNo(c, "ctor param vararg");
        }
        if (p.default != null and ctorDefault(layouts, c, i) == null) {
            out.deinit(gpa);
            return layoutNo(c, "ctor param default without a thunk");
        }
        // A type the module has no class for is still a REFERENCE: Kotlin
        // erases generics, so a `T` parameter holds a value like any other and
        // every use of it that needs a layout refuses on its own.
        const t = tyOf(p.ty) orelse Ty.object;
        try out.append(gpa, .{
            .name = p.name,
            .ty = t,
            .cls = if (t == .object) classIndexOfName(m, p.ty) else null,
            .elem = if (t == .object) (refElemOf(classIndexOfName(m, p.ty), p.ty) orelse .unit) else .unit,
            .arg = @intCast(i),
            .init = null,
        });
    }
    var complete = true;
    if (layoutFor(layouts, c)) |l| {
        complete = false;
        inc: for (l.props) |bp| {
            // A property that stores nothing is not a field: a computed `val x
            // get() = ...` reads through its getter, and an abstract one is
            // storage only in whichever subclass declares it.
            if (!bp.has_backing or bp.is_abstract) continue;
            // A `lateinit var` reads as a thrown error until it is assigned,
            // which needs the unset marker the interpreter carries.
            if (bp.is_lateinit) {
                out.deinit(gpa);
                return layoutNo(c, "lateinit property");
            }
            if (bp.init == null and !bp.zero_init) {
                out.deinit(gpa);
                return layoutNo(c, "body property without an initializer");
            }
            var fcls: ?u32 = null;
            var felem: Ty = .unit;
            const t = tyOf(bp.ty) orelse blk: {
                if (bp.ty.name.len != 0) {
                    fcls = classIndexOfName(m, bp.ty);
                    break :blk Ty.object;
                }
                // The source annotated no type, so the property's type is
                // whatever its initializer computes. Asking the initializer
                // needs the layouts resolved so far — including the fields of
                // this very class ahead of this one — which is why the table is
                // built to a fixed point rather than in one pass. Stopping here
                // keeps the fields already placed at the indices they will
                // keep; the next pass resumes with more resolved.
                if (last and prev == null) {
                    out.deinit(gpa);
                    return layoutNoTy(c, "body property type", bp.ty);
                }
                const pv = prev orelse break :inc;
                const ifn = m.funcById(bp.init orelse break :inc) orelse break :inc;
                var ic = (try eligible(gpa, m, pv.*, ifn, globals, null, &.{})) orelse {
                    if (traceOn() and last) {
                        std.debug.print("[cgen] layout {s}: property `{s}` has no compilable initializer\n", .{ c.name, bp.name });
                    }
                    if (!last) break :inc;
                    out.deinit(gpa);
                    return layoutNoTy(c, "body property type", bp.ty);
                };
                defer ic.deinit(gpa);
                fcls = ic.ret_cls;
                felem = ic.ret_elem;
                break :blk ic.ret;
            };
            try out.append(gpa, .{
                .name = bp.name,
                .ty = t,
                .cls = if (t == .object) (fcls orelse classIndexOfName(m, bp.ty)) else null,
                .elem = if (t == .object) (refElemOf(fcls orelse classIndexOfName(m, bp.ty), bp.ty) orelse felem) else .unit,
                .arg = null,
                .init = bp.init,
            });
            continue;
        } else {
            // The loop ran to the end, so every property found a place.
            complete = true;
        }
    }
    return .{ .fields = try out.toOwnedSlice(gpa), .parent = parent, .complete = complete };
}

/// A property access inside the declaring class carries a synthesized accessor
/// name (`$sgetter$<Class><US><field>`); the stored field is the tail.
/// Whether this spelling names the BACKING FIELD rather than the property: the
/// lowering marks a `field` read or write inside an accessor this way, and
/// everything else goes through the accessor when one is declared. The
/// `$sgetter$<owner>` form is NOT one of these: it is an ordinary property read
/// that names the owner it was written against, and resolves to whatever the
/// receiver's own class declares.
fn isBackingAccess(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__klio_field__");
}

fn plainFieldName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "$sgetter$") or std.mem.startsWith(u8, name, "$ssetter$")) {
        if (std.mem.lastIndexOfScalar(u8, name, 0x1f)) |i| return name[i + 1 ..];
    }
    if (std.mem.startsWith(u8, name, "__klio_field__")) return name["__klio_field__".len..];
    return name;
}

/// The index of a named field, which is what compiled code addresses.
fn fieldIndex(prog: Program, cid: u32, name: []const u8) ?u32 {
    const fields = prog.of(cid) orelse return null;
    const want = plainFieldName(name);
    for (fields, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, want)) return @intCast(i);
    }
    return null;
}

/// The class a declared type NAMES, without asking whether its layout is one
/// A field only has to be a reference to be stored, and a value only has to be
/// one to be passed or returned; demanding the layout as well would recurse
/// forever on a class holding one of its own kind, and would refuse interface
/// types outright, which have no layout and never will. The layout is demanded
/// where a field is actually read.
fn classIndexOfName(m: *const Module, t: ir.TypeRef) ?u32 {
    if (t.name.len == 0) return null;
    if (std.mem.eql(u8, t.name, "String") or std.mem.eql(u8, t.name, "kotlin.String")) return STRING_CLS;
    if (std.mem.eql(u8, t.name, "List") or std.mem.eql(u8, t.name, "MutableList")) return LIST_CLS;
    if (isArrayTypeName(t.name)) return ARRAY_CLS;
    if (functionTypeArity(t.name)) |ar| return funcCls(ar);
    for (m.classes.items, 0..) |*c, i| {
        if (std.mem.eql(u8, c.name, t.name) or std.mem.eql(u8, c.fqn, t.name)) return @intCast(i);
    }
    return null;
}

/// The machine type of a class property: a scalar in place, or a reference.


/// A zero-argument numeric conversion (`x.toLong()`), which lowers to a
/// `CallMember`. Every direction is a C cast; Kotlin's `toInt()` on a floating
/// value saturates where C's cast is undefined, so that one is refused.
fn numConv(m: *const Module, cm: anytype) ?Ty {
    if (cm.n_args != 0 or cm.arg_names.len != 0) return null;
    if (cm.name.int() >= m.consts.items.len) return null;
    const nm = m.consts.items[cm.name.int()];
    if (nm != .String) return null;
    if (std.mem.eql(u8, nm.String, "toInt")) return .i32;
    if (std.mem.eql(u8, nm.String, "toLong")) return .i64;
    if (std.mem.eql(u8, nm.String, "toDouble")) return .f64;
    if (std.mem.eql(u8, nm.String, "toFloat")) return .f32;
    if (std.mem.eql(u8, nm.String, "toUInt")) return .u32;
    if (std.mem.eql(u8, nm.String, "toULong")) return .u64;
    if (std.mem.eql(u8, nm.String, "toUShort")) return .u16;
    if (std.mem.eql(u8, nm.String, "toUByte")) return .u8;
    if (std.mem.eql(u8, nm.String, "toShort")) return .short;
    if (std.mem.eql(u8, nm.String, "toByte")) return .byte;
    return null;
}

/// The same conversion spelled as a VIRTUAL call: `k.toLong()` on a scalar
/// lowers this way. Only the builtin declarations count — a user class's own
/// `toLong()` is a real call.
fn numConvVirtual(m: *const Module, cv: anytype) ?Ty {
    if (cv.n_args != 0 or cv.arg_names.len != 0) return null;
    const decl = m.funcById(ir.FuncId.from(cv.slot.int())) orelse return null;
    if (!std.mem.startsWith(u8, decl.fqn, "kotlin.")) return null;
    if (std.mem.eql(u8, decl.name, "toInt")) return .i32;
    if (std.mem.eql(u8, decl.name, "toLong")) return .i64;
    if (std.mem.eql(u8, decl.name, "toDouble")) return .f64;
    if (std.mem.eql(u8, decl.name, "toFloat")) return .f32;
    if (std.mem.eql(u8, decl.name, "toUInt")) return .u32;
    if (std.mem.eql(u8, decl.name, "toULong")) return .u64;
    if (std.mem.eql(u8, decl.name, "toUShort")) return .u16;
    if (std.mem.eql(u8, decl.name, "toUByte")) return .u8;
    if (std.mem.eql(u8, decl.name, "toShort")) return .short;
    if (std.mem.eql(u8, decl.name, "toByte")) return .byte;
    return null;
}

/// `println` is the one runtime service the scalar core needs, and printing a
/// scalar is a `printf`. It is recognised by name, and the format comes from
/// the ARGUMENT's static type rather than the parameter's: the resolved
/// overload takes `Any?`, so the parameter says nothing about what is printed.
/// Stdlib entry points the backend performs directly against the runtime's
/// own data structures. Recognised by name, like `println`: their Kotlin
/// bodies are generic and variadic, and compiling those is a different piece
/// of work from performing the operation.
const ListIntrinsic = enum { list_of, mutable_list_of };

fn listIntrinsic(f: *const Func) ?ListIntrinsic {
    if (std.mem.eql(u8, f.fqn, "kotlin.collections.listOf")) return .list_of;
    if (std.mem.eql(u8, f.fqn, "kotlin.collections.mutableListOf")) return .mutable_list_of;
    return null;
}

/// The stdlib entry that implements a declaration, if the interpreter has one.
/// A member the backend does not perform directly is not a gap: the operation
/// exists, named, and compiled code calls the same entry.
/// The member calls a compiled program hands back to the runtime. The
/// interpreter classifies a slot's declaration into a host operation served
/// from the receiver's own representation; the ones with no interpreter behind
/// them are exactly what a compiled program can run, so that classification is
/// the answer rather than a list of names kept here.
fn hostMemberOp(decl: *const Func) ?member_dispatch.HostSlotOp {
    const op = member_dispatch.hostSlotOpOfFqn(decl.fqn) orelse return null;
    return switch (op) {
        // The iteration protocol reads the container and the iterator, nothing
        // else. The remaining ops need a live module to dispatch through.
        .iterator_protocol, .collection_iterator => op,
        else => null,
    };
}

fn stdlibEntry(f: *const Func) ?[]const u8 {
    if (f.fqn.len == 0) return null;
    if (stdlib.implementations.lookup(f.fqn) != null) return f.fqn;
    // A declaration reached through a receiver is registered under the
    // RECEIVER-QUALIFIED form rather than its own package: `substring` is
    // declared in `kotlin.text` and implemented as `kotlin.String.substring`.
    // The receiver of an extension is its first parameter whether or not the
    // declaration is FLAGGED as having one: `kotlin.text.substring` takes its
    // String first and carries no receiver flag.
    const recv: ?[]const u8 = if (f.params.len != 0 and f.params[0].ty.name.len != 0)
        simpleName(f.params[0].ty.name)
    else
        null;
    if (stdlib.implementations.declarationHostSymbol(f.fqn, recv, f.name)) |sym| return sym;
    if (recv) |rn| {
        var buf: [160]u8 = undefined;
        const qualified = std.fmt.bufPrint(&buf, "kotlin.{s}.{s}", .{ rn, f.name }) catch return null;
        if (stdlib.implementations.lookup(qualified)) |_| {
            // The borrowed buffer dies with this call, so hand back the
            // table's own copy of the name.
            var it = stdlib.implementations.allFqns();
            while (it.next()) |cand| {
                if (std.mem.eql(u8, cand, qualified)) return cand;
            }
        }
    }
    return null;
}

/// `launch { … }`: a child coroutine queued on the driver that is running. It
/// is not a suspension: the caller keeps going.
fn isLaunch(f: *const Func) bool {
    return std.mem.eql(u8, f.fqn, "kotlinx.coroutines.launch") or
        std.mem.eql(u8, f.fqn, "kotlinx.coroutines.CoroutineScope.launch");
}

/// `delay(millis)`: the primitive suspension. It parks the CALLING frame and
/// asks the driver to resume it after that much virtual time, so there is no
/// callee to compile — the wait is the operation.
fn isDelay(f: *const Func) bool {
    return std.mem.eql(u8, f.fqn, "kotlinx.coroutines.delay");
}

/// `runBlocking { … }`: the root of a coroutine tree. It drives its block to
/// completion on the interpreter's own scheduler, so a compiled program and an
/// interpreted one order their coroutines identically.
fn isRunBlocking(f: *const Func) bool {
    return std.mem.eql(u8, f.fqn, "kotlinx.coroutines.runBlocking");
}

/// `arrayOfNulls<T>(n)`: a reference array of `n` nulls. Sized rather than
/// built from elements, so it is not the `arrayOf` shape.
fn isArrayOfNulls(f: *const Func) bool {
    return f.params.len == 1 and std.mem.startsWith(u8, f.fqn, "kotlin.") and
        std.mem.eql(u8, f.name, "arrayOfNulls");
}

/// A stdlib function with no Kotlin body, because the implementation is the
/// platform's. The backend performs it directly rather than compiling a
/// declaration that has nothing to compile.
const ScalarIntrinsic = enum { max, min, abs, print };

fn scalarIntrinsic(f: *const Func) ?ScalarIntrinsic {
    if (f.hasBody()) return null;
    if (f.params.len == 2 and std.mem.eql(u8, f.fqn, "kotlin.math.max")) return .max;
    if (f.params.len == 2 and std.mem.eql(u8, f.fqn, "kotlin.math.min")) return .min;
    if (f.params.len == 1 and std.mem.eql(u8, f.fqn, "kotlin.math.abs")) return .abs;
    if (f.params.len == 1 and (std.mem.eql(u8, f.fqn, "kotlin.io.print") or std.mem.eql(u8, f.fqn, "print"))) return .print;
    return null;
}

/// The member name a virtual slot dispatches to, for the builtin receivers
/// whose members the backend performs directly.
/// The method of `cls` that implements a virtual slot. A slot is numbered by
/// its root declaration, so the implementation is the class's method of the
/// same name and arity — which is what an override is.
fn slotImpl(m: *const Module, prog: Program, cid: u32, slot: ir.MethodSlotId) ?*const Func {
    const root = m.funcById(ir.FuncId.from(slot.int())) orelse return null;
    // A class answers a slot only if its TYPE includes the declaration. Name
    // and arity alone made every same-named method across the stdlib look like
    // an override, which dragged whole families of unrelated classes into the
    // compile through one `next()` call.
    if (!typeHasSlot(m, cid, root)) return null;
    var fallback: ?*const Func = null;
    // A class that does not override still answers with what it inherits, so
    // the walk goes up the chain and the nearest body wins.
    var cur: ?u32 = cid;
    var depth: u32 = 0;
    while (cur) |ci| : (depth += 1) {
        if (depth > 32 or ci >= m.classes.items.len) break;
        for (m.classes.items[ci].methods) |fid| {
            const mf = m.funcById(fid) orelse continue;
            if (!std.mem.eql(u8, mf.name, root.name)) continue;
            if (!mf.hasBody()) continue;
            if (mf.params.len == root.params.len) return mf;
            // An override may declare parameters the declaration does not,
            // when they carry defaults; it still answers the slot.
            if (mf.params.len > root.params.len and fallback == null) fallback = mf;
        }
        if (fallback != null) return fallback;
        // An interface may carry a default body, which a class that does not
        // override inherits.
        for (m.classes.items[ci].supertypes) |sid| {
            if (sid.int() >= m.classes.items.len) continue;
            const sup = &m.classes.items[sid.int()];
            if (!sup.is_interface) continue;
            for (sup.methods) |fid2| {
                const mf2 = m.funcById(fid2) orelse continue;
                if (!std.mem.eql(u8, mf2.name, root.name)) continue;
                if (!mf2.hasBody()) continue;
                if (mf2.params.len == root.params.len) return mf2;
                if (mf2.params.len > root.params.len and fallback == null) fallback = mf2;
            }
        }
        if (fallback != null) return fallback;
        cur = if (prog.parentOf(ci)) |pp| pp.cid else null;
    }
    return fallback;
}

/// The greatest number of parameters a call the emitter binds can have. A
/// signature past this is refused rather than truncated.
const MAX_CALL_PARAMS: u32 = 32;

/// Which argument fills each declared parameter. Kotlin binds positional
/// arguments in order and named ones by name, so the emitted call has to
/// reorder them into the callee's own order; a parameter nothing binds takes
/// its default.
const ArgBinding = struct {
    regs: [MAX_CALL_PARAMS]?u32 = @splat(null),
    n: u32 = 0,
    /// The `vararg` parameter, when the callee declares one: the trailing
    /// positional arguments are collected into an array rather than bound one
    /// to a parameter each. `regs` holds nothing for it.
    vararg_param: ?u32 = null,
    /// The contiguous register run those arguments occupy.
    vararg_base: u32 = 0,
    vararg_n: u32 = 0,
};

fn bindCallArgs(
    m: *const Module,
    params: []const ir.Param,
    args_base: u32,
    n_args: u32,
    arg_names: []const ?ir.ConstId,
) ?ArgBinding {
    if (params.len > MAX_CALL_PARAMS) return null;
    var b: ArgBinding = .{ .n = @intCast(params.len) };
    for (params, 0..) |p, pi| {
        if (p.is_vararg) {
            b.vararg_param = @intCast(pi);
            break;
        }
    }
    var next: u32 = 0;
    var i: u32 = 0;
    while (i < n_args) : (i += 1) {
        const reg = args_base + i;
        const named: ?ir.ConstId = if (i < arg_names.len) arg_names[i] else null;
        if (named) |cid| {
            if (cid.int() >= m.consts.items.len) return null;
            const nm = m.consts.items[cid.int()];
            if (nm != .String) return null;
            var found = false;
            for (params, 0..) |p, pi| {
                if (!std.mem.eql(u8, p.name, nm.String)) continue;
                if (b.regs[pi] != null) return null;
                b.regs[pi] = reg;
                found = true;
                break;
            }
            if (!found) return null;
            continue;
        }
        while (next < params.len and b.regs[next] != null) next += 1;
        // Every positional argument from the `vararg` parameter onward is one
        // ELEMENT of it, not a parameter of its own; a later parameter can only
        // be filled by name. The run is contiguous because the arguments are.
        if (b.vararg_param) |vp| {
            if (next == vp) {
                if (b.vararg_n == 0) b.vararg_base = reg;
                if (reg != b.vararg_base + b.vararg_n) return null;
                b.vararg_n += 1;
                continue;
            }
        }
        if (next >= params.len) return null;
        b.regs[next] = reg;
        next += 1;
    }
    return b;
}

/// The declaration a member call binds to: the TOPMOST class on the receiver's
/// chain that declares this name at this arity. Every class that overrides it
/// answers the same dispatcher, so a call resolved here dispatches exactly as
/// a `CallVirtual` on that slot does.
fn memberRoot(m: *const Module, prog: Program, cid: u32, name: []const u8, n_args: u32) ?*const Func {
    var found: ?*const Func = null;
    var cur: ?u32 = cid;
    var depth: u32 = 0;
    while (cur) |ci| : (depth += 1) {
        if (depth > 32 or ci >= m.classes.items.len) break;
        for (m.classes.items[ci].methods) |fid| {
            const mf = m.funcById(fid) orelse continue;
            if (!std.mem.eql(u8, mf.name, name)) continue;
            if (!mf.has_receiver_param or mf.params.len != n_args + 1) continue;
            found = mf;
        }
        // An interface a class implements declares the member too, and that
        // declaration is the root when it exists.
        for (m.classes.items[ci].supertypes) |sid| {
            if (sid.int() >= m.classes.items.len) continue;
            const sup = &m.classes.items[sid.int()];
            if (!sup.is_interface) continue;
            for (sup.methods) |fid2| {
                const mf2 = m.funcById(fid2) orelse continue;
                if (!std.mem.eql(u8, mf2.name, name)) continue;
                if (!mf2.has_receiver_param or mf2.params.len != n_args + 1) continue;
                found = mf2;
            }
        }
        cur = if (prog.parentOf(ci)) |pp| pp.cid else null;
    }
    return found;
}

/// The implicit receiver that owns a bare name, innermost first. `pref` is the
/// receiver the lowering already knows (an inline extension binds its receiver
/// as an ordinary register of the caller's frame, so the capture slot never
/// holds it). Null when nothing owns it, which makes the name a global.
/// Reconcile each register's type with the one it settled on. Returns the
/// register that took a second, different type, which cannot share one C local.
fn settleTypes(types: []Ty, known: []const bool, settled: []Ty, has_settled: []bool) ?u32 {
    for (types, 0..) |*t, r| {
        if (!known[r]) continue;
        if (!has_settled[r]) {
            has_settled[r] = true;
            settled[r] = t.*;
            continue;
        }
        if (settled[r] == t.*) continue;
        // Unit on either side is the placeholder, not a type of its own.
        if (settled[r] == .unit) {
            settled[r] = t.*;
            continue;
        }
        if (t.* == .unit) {
            t.* = settled[r];
            continue;
        }
        return @intCast(r);
    }
    return null;
}

fn noReg(f: *const Func, reg: u32) ?Compiled {
    if (traceOn()) std.debug.print("[cgen] refuse {s}: register type varies r{d}\n", .{ f.name, reg });
    return null;
}

/// The declared type of an array constructor's initializer. `IntArray(size,
/// init)` is declared `expect inline`, so there is no Kotlin body carrying the
/// signature and no primary parameter to read it off; the emitter performs the
/// construction and this is that builtin's own signature. The result is the
/// element type, and the one parameter is the index.
fn bareTy(name: []const u8) ir.TypeRef {
    return .{ .name = name, .nullable = false, .args = &.{} };
}

/// `(Int) -> E` for each array element kind, in the order
/// `klio_nat_prim_array` names them, with the reference `Array<T>` last. The
/// argument slices are mutable because `TypeRef.args` is, and nothing writes
/// them.
var array_init_args = [_][2]ir.TypeRef{
    .{ bareTy("Int"), bareTy("Int") },
    .{ bareTy("Int"), bareTy("Long") },
    .{ bareTy("Int"), bareTy("Double") },
    .{ bareTy("Int"), bareTy("Float") },
    .{ bareTy("Int"), bareTy("Short") },
    .{ bareTy("Int"), bareTy("Byte") },
    .{ bareTy("Int"), bareTy("Boolean") },
    .{ bareTy("Int"), bareTy("Char") },
    .{ bareTy("Int"), bareTy("Any") },
};

fn arrayInitFnType(class_name: []const u8) ?ir.TypeRef {
    const slot: usize = primArrayKind(class_name) orelse
        (if (isArrayTypeName(class_name)) array_init_args.len - 1 else return null);
    return .{ .name = "Function1", .nullable = false, .args = array_init_args[slot][0..] };
}

/// The function type a lambda is expected to have, read off where its value
/// goes: the declaration's return type when it is returned, the parameter's
/// type when it is passed. A lambda's own parameters carry no declared types —
/// the source writes `{ x -> x + n }` — so this is where they come from.
fn expectedFnType(m: *const Module, f: *const Func, dst: ir.Reg) ?ir.TypeRef {
    var want = dst;
    var hops: u32 = 0;
    while (hops < 8) : (hops += 1) {
        var moved: ?ir.Reg = null;
        for (f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                switch (inst.*) {
                    .Move => |mv| if (mv.src.int() == want.int()) {
                        moved = mv.dst;
                    },
                    .Call => |cl| {
                        const callee = m.funcById(cl.func) orelse continue;
                        var k: u32 = 0;
                        while (k < cl.n_args) : (k += 1) {
                            if (cl.args.int() + k != want.int()) continue;
                            if (k < callee.params.len and functionTypeArity(callee.params[k].ty.name) != null) {
                                return callee.params[k].ty;
                            }
                        }
                    },
                    .NewInstance => |ni| {
                        const cdef = if (ni.class.int() < m.classes.items.len) &m.classes.items[ni.class.int()] else continue;
                        var k2: u32 = 0;
                        while (k2 < ni.n_args) : (k2 += 1) {
                            if (ni.args.int() + k2 != want.int()) continue;
                            if (k2 < cdef.primary_params.len and functionTypeArity(cdef.primary_params[k2].ty.name) != null) {
                                return cdef.primary_params[k2].ty;
                            }
                            if (k2 == 1 and ni.n_args == 2) {
                                if (arrayInitFnType(cdef.name)) |t| return t;
                            }
                        }
                    },
                    else => {},
                }
            }
            if (blk.terminator == .Return) {
                if (blk.terminator.Return) |rr| {
                    if (rr.int() == want.int() and functionTypeArity(f.return_ty.name) != null) return f.return_ty;
                }
            }
        }
        want = moved orelse break;
    }
    return null;
}

/// The parameter list a lambda body compiles against, taken from the function
/// type its value is expected to have. The type's arguments end with the
/// result, and a receiver or a `#suspend` marker rides ahead of the parameters,
/// so the value parameters are the last `arity` before it.
fn lambdaParams(gpa: std.mem.Allocator, body: *const Func, t: ir.TypeRef) Error!?[]ir.Param {
    const arity = functionTypeArity(t.name) orelse return null;
    if (t.args.len < arity + 1) return null;
    const first = t.args.len - arity - 1;
    const out = try gpa.alloc(ir.Param, body.params.len);
    for (out, 0..) |*p, i| {
        p.* = body.params[i];
        if (i < arity) p.ty = t.args[first + i];
    }
    return out;
}

/// Whether a lambda register is ever used as anything but the callee of a
/// direct call. Such a use needs the value to exist, which means a closure
/// object; while every use is a direct call the call site passes the captures
/// itself and nothing is allocated.
fn lambdaEscapes(m: *const Module, f: *const Func, dst: ir.Reg) bool {
    for (f.blocks) |*blk| {
        for (blk.insts) |*inst| {
            if (inst.* == .CallValue and inst.CallValue.callee.int() == dst.int()) continue;
            if (inst.* == .AstLambda and inst.AstLambda.dst.int() == dst.int()) continue;
            // An array constructor's initializer is called once per index, not
            // kept: the emitted loop calls the body directly.
            if (inst.* == .NewInstance) {
                const ni2 = inst.NewInstance;
                if (ni2.n_args == 2 and ni2.args.int() + 1 == dst.int() and
                    ni2.class.int() < m.classes.items.len and
                    isArrayTypeName(m.classes.items[ni2.class.int()].name)) continue;
            }
            if (instReadsReg(inst, dst)) return true;
        }
        switch (blk.terminator) {
            .Return => |r| if (r) |rr| {
                if (rr.int() == dst.int()) return true;
            },
            .Throw => |t| if (t.int() == dst.int()) return true,
            .Branch => |br| if (br.cond.int() == dst.int()) return true,
            else => {},
        }
    }
    return false;
}

/// Whether an instruction names this register anywhere: the check behind the
/// escape question, so a shape the emitter has not enumerated reads as a use
/// rather than as an absence.
fn instReadsReg(inst: *const ir.Inst, r: ir.Reg) bool {
    const info = @typeInfo(ir.Inst).@"union";
    inline for (info.fields) |uf| {
        if (inst.* == @field(std.meta.Tag(ir.Inst), uf.name)) {
            const payload = @field(inst.*, uf.name);
            if (@typeInfo(@TypeOf(payload)) == .@"struct") {
                // An argument list is a BASE register plus a count, so a use
                // as any argument but the first is invisible field by field.
                if (@hasField(@TypeOf(payload), "args") and @hasField(@TypeOf(payload), "n_args")) {
                    const base = payload.args.int();
                    if (r.int() >= base and r.int() < base + payload.n_args) return true;
                }
                inline for (@typeInfo(@TypeOf(payload)).@"struct".fields) |pf| {
                    if (pf.type == ir.Reg) {
                        if (@field(payload, pf.name).int() == r.int()) return true;
                    } else if (pf.type == []ir.Reg or pf.type == []const ir.Reg) {
                        for (@field(payload, pf.name)) |rr| {
                            if (rr.int() == r.int()) return true;
                        }
                    }
                }
            }
        }
    }
    return false;
}

fn resolveBare(
    m: *const Module,
    prog: Program,
    types: []const Ty,
    cls: []const ?u32,
    known: []const bool,
    encl: []const u32,
    pref: ?u32,
    name: []const u8,
    set: bool,
) ?BareResolution {
    if (pref) |r| {
        if (bareOn(m, prog, types, cls, known, r, name, set)) |res| return res;
    }
    var i: usize = encl.len;
    while (i > 0) {
        i -= 1;
        if (bareOn(m, prog, types, cls, known, encl[i], name, set)) |res| return res;
    }
    return null;
}

fn bareOn(
    m: *const Module,
    prog: Program,
    types: []const Ty,
    cls: []const ?u32,
    known: []const bool,
    r: u32,
    name: []const u8,
    set: bool,
) ?BareResolution {
    if (r >= types.len or !known[r] or types[r] != .object) return null;
    const rc = cls[r] orelse return null;
    if (isBuiltinCls(rc)) return null;
    if (fieldIndex(prog, rc, name)) |idx| return .{ .field = .{ .recv = r, .idx = idx } };
    const acc = if (set) prog.accessor(m, rc, name, .set) else prog.accessor(m, rc, name, .get);
    if (acc) |g| return .{ .accessor = .{ .recv = r, .func = g } };
    return null;
}

/// One property read through a type that declares it without storage. Which
/// class answers may STORE it rather than compute it, so an arm is either a
/// getter call or a field read.
const PropUse = struct { name: []const u8, cid: u32, ret: Ty };

/// One lambda whose value the program materialises.
const LambdaUse = struct { body: ir.FuncId, n_caps: u32, arity: u32, ret: Ty };

/// Where a lambda that captures nothing keeps its ONE instance. Kotlin makes
/// such a literal a singleton, so every evaluation of it answers the same
/// object and `===` holds across them.
fn lambdaSingletonSlot(used: []const LambdaUse, body: ir.FuncId) ?usize {
    var n: usize = 0;
    for (used) |lu| {
        if (lu.n_caps != 0) continue;
        if (lu.body == body) return n;
        n += 1;
    }
    return null;
}

/// Whether a class's TYPE includes the declaration a slot is numbered by: the
/// slot's root names its owner in its fqn, and a class whose supertypes reach
/// that owner has the member whether or not it has a body for it. A class that
/// has the member and no body satisfies it by delegation, which forwards to
/// another object at run time.
fn typeHasSlot(m: *const Module, cid: u32, root: *const Func) bool {
    const dot = std.mem.lastIndexOfScalar(u8, root.fqn, '.') orelse return false;
    const owner = root.fqn[0..dot];
    if (owner.len == 0) return false;
    var stack: [64]u32 = undefined;
    var n: usize = 1;
    stack[0] = cid;
    var steps: u32 = 0;
    while (n != 0 and steps < 256) : (steps += 1) {
        n -= 1;
        const ci = stack[n];
        if (ci >= m.classes.items.len) continue;
        const c = &m.classes.items[ci];
        if (std.mem.eql(u8, c.name, owner) or std.mem.eql(u8, c.fqn, owner)) return true;
        for (c.supertypes) |sid| {
            if (n < stack.len) {
                stack[n] = sid.int();
                n += 1;
            }
        }
    }
    return false;
}

/// How a property read or write on a receiver of a known class is performed.
/// One place decides, because the typing pass, the emission, the reachable set
/// and the dispatcher list all have to agree on the answer.
const AccessPlan = union(enum) {
    /// Straight to the field at this index.
    field: u32,
    /// Through the accessor the class declares.
    accessor: ir.FuncId,
    /// Through a dispatcher: the type declares it without storage here, and
    /// which class answers is a run-time question.
    virtual,
    none,
};

fn accessPlan(m: *const Module, prog: Program, rc: u32, name: []const u8, set: bool) AccessPlan {
    if (isBuiltinCls(rc)) return .none;
    // A `field` read or write inside an accessor reaches the storage; anything
    // else goes through the accessor when the class declares one, even if the
    // property also has a backing field.
    if (!isBackingAccess(name)) {
        const acc = if (set)
            prog.accessor(m, rc, name, .set)
        else
            prog.accessor(m, rc, name, .get);
        if (acc) |a| return .{ .accessor = a };
    }
    if (fieldIndex(prog, rc, name)) |idx| return .{ .field = idx };
    if (!set and virtualProp(m, prog, rc, plainFieldName(name)) != null) return .virtual;
    return .none;
}

/// Where a property access actually lands. A name the receiver's own class does
/// not carry may belong to its COMPANION: `Label` read inside a member of
/// `Config` names `Config.Companion.Label`, and the companion is the singleton
/// the access runs against.
fn accessOwner(m: *const Module, prog: Program, rc: u32, name: []const u8, set: bool) ?u32 {
    if (std.meta.activeTag(accessPlan(m, prog, rc, name, set)) != .none) return null;
    if (rc >= m.classes.items.len) return null;
    const cc = companionObjectNamed(m, prog, m.classes.items[rc].fqn) orelse return null;
    if (std.meta.activeTag(accessPlan(m, prog, cc, name, set)) == .none) return null;
    return cc;
}

/// A property read through a type that declares it without storage: an
/// interface's `val`, or an abstract one. Which getter runs is the receiver's
/// class, exactly as for a method.
const VirtualProp = struct { ret: Ty, cls: ?u32, elem: Ty };

/// Whether `sub`'s type includes `base`: it IS that class, extends it, or
/// implements it.
fn typeReaches(m: *const Module, sub: u32, base: u32) bool {
    var stack: [64]u32 = undefined;
    var n: usize = 1;
    stack[0] = sub;
    var steps: u32 = 0;
    while (n != 0 and steps < 256) : (steps += 1) {
        n -= 1;
        const ci = stack[n];
        if (ci == base) return true;
        if (ci >= m.classes.items.len) continue;
        for (m.classes.items[ci].supertypes) |sid| {
            if (n < stack.len) {
                stack[n] = sid.int();
                n += 1;
            }
        }
    }
    return false;
}

/// The result of reading `name` off a receiver of class `rc`, when no class in
/// that position stores it but some class beneath it computes it. Null when
/// nothing does, or when the candidates disagree on what they return — the
/// dispatcher has one C signature, so they have to agree.
fn virtualProp(m: *const Module, prog: Program, rc: u32, name: []const u8) ?VirtualProp {
    var found: ?VirtualProp = null;
    var ci: u32 = 0;
    while (ci < m.classes.items.len) : (ci += 1) {
        if (prog.of(ci) == null) continue;
        if (!typeReaches(m, ci, rc)) continue;
        var gt: Ty = undefined;
        var gc: ?u32 = null;
        var ge: Ty = .unit;
        if (prog.accessor(m, ci, name, .get)) |g| {
            const gfn = m.funcById(g) orelse return null;
            gt = funcRetTy2(m, gfn) orelse return null;
            gc = if (gt == .object) classIndexOfName(m, gfn.return_ty) else null;
            ge = if (refElemOf(gc, gfn.return_ty)) |e| e else .unit;
        } else if (fieldIndex(prog, ci, name)) |fi5| {
            // An override that STORES the property answers with the field.
            const fds5 = prog.of(ci).?;
            gt = fds5[fi5].ty;
            gc = fds5[fi5].cls;
            ge = fds5[fi5].elem;
        } else continue;
        if (found) |prev| {
            if (prev.ret != gt) return null;
        } else {
            found = .{ .ret = gt, .cls = gc, .elem = ge };
        }
    }
    return found;
}

/// The `toString` a value of this class answers with, when its own type
/// declares one. Kotlin renders a value by calling it, so a compiled program
/// has to call it too rather than hand the value to the runtime's renderer —
/// which knows the shape of the class but not what the program wrote for it.
fn toStringOf(m: *const Module, prog: Program, rc: u32) ?*const Func {
    if (isBuiltinCls(rc)) return null;
    const root = memberRoot(m, prog, rc, "toString", 0) orelse return null;
    // A declaration with no body anywhere below is the universal one, which
    // is what the renderer already does.
    if (slotImpl(m, prog, rc, ir.MethodSlotId.from(root.id.int())) == null) return null;
    return root;
}

/// One virtual call site's shape: the slot and how many arguments it takes.
const SlotUse = struct { slot: u32, n_args: u32 };

fn listMemberName(m: *const Module, slot: ir.MethodSlotId) ?[]const u8 {
    const decl = m.funcById(ir.FuncId.from(slot.int())) orelse return null;
    return decl.name;
}

fn isPrintln(f: *const Func) bool {
    // Recognised by NAME. The declaration's own parameter list is not the
    // test: a bodyless stdlib entry can carry a different one depending on
    // where it was reached from, and the call site's arity is checked anyway.
    return std.mem.eql(u8, f.fqn, "kotlin.io.println") or std.mem.eql(u8, f.fqn, "println");
}

pub const Error = error{ OutOfMemory, WriteFailed, NoSpaceLeft };

/// `KLIO_CGEN_TRACE=1` names every function the subset refuses and why. The
/// refusal list IS the backlog for widening the backend, so it has to be
/// readable rather than inferred from an empty output file.
fn traceOn() bool {
    return std.c.getenv("KLIO_CGEN_TRACE") != null;
}

/// Why a class has no layout. Reported only when a program actually needed
/// one: the table is built for every class in the module, so reporting during
/// the build names classes nothing ever asked about — mostly library
/// interfaces, which have no layout by their nature.
var layout_quiet = true;

fn layoutNo(c: *const ir.Class, comptime why: []const u8) ?Laid {
    if (traceOn() and !layout_quiet) std.debug.print("[cgen] layout {s}: " ++ why ++ "\n", .{c.name});
    return null;
}

/// The same, naming the type that could not be laid out: which types are
/// missing is the backlog, and "ctor param type" alone does not say.
fn layoutNoTy(c: *const ir.Class, comptime why: []const u8, t: ir.TypeRef) ?Laid {
    if (traceOn() and !layout_quiet) std.debug.print("[cgen] layout {s}: " ++ why ++ " {s}\n", .{ c.name, t.name });
    return null;
}

fn instRefuse(f: *const Func, inst: *const ir.Inst) ?Compiled {
    if (traceOn()) std.debug.print("[cgen] refuse {s}: inst {s}\n", .{ f.fqn, @tagName(inst.*) });
    return null;
}

/// The same, naming the member a call could not bind. Which member a program
/// needs is the backlog; the instruction tag alone does not say.
fn instRefuseNamed(m: *const Module, f: *const Func, inst: *const ir.Inst, name_id: ir.ConstId) ?Compiled {
    if (traceOn()) {
        const nm = if (name_id.int() < m.consts.items.len) m.consts.items[name_id.int()] else ir.Const{ .Unit = {} };
        std.debug.print("[cgen] refuse {s}: inst {s} `{s}`\n", .{
            f.fqn, @tagName(inst.*), if (nm == .String) nm.String else "?",
        });
    }
    return null;
}

/// A refusal that names the callee, so the trace says which function to teach
/// the backend next rather than only that some call was not compilable.
fn noCallee(f: *const Func, callee: *const Func, comptime why: []const u8) ?Compiled {
    if (traceOn()) std.debug.print("[cgen] refuse {s}: " ++ why ++ " `{s}`\n", .{ f.fqn, callee.fqn });
    return null;
}

fn no(f: *const Func, comptime why: []const u8) ?Compiled {
    if (traceOn()) std.debug.print("[cgen] refuse {s}: " ++ why ++ "\n", .{f.fqn});
    return null;
}

/// The same, naming the thing that was not found. Which names a program needs
/// is the backlog, and "global not declared" alone does not say.
fn noName(f: *const Func, comptime why: []const u8, name: []const u8) ?Compiled {
    if (traceOn()) std.debug.print("[cgen] refuse {s}: " ++ why ++ " `{s}`\n", .{ f.name, name });
    return null;
}

/// Whether `f` lowers to the scalar core, and the register types if it does.
/// Refuses rather than guesses: every register the body defines must have a
/// scalar type, and every instruction must be one this emitter writes.
/// The class a function's receiver parameter names, for a method compiled as an
/// ordinary C function taking `this` first.
fn receiverClass(m: *const Module, f: *const Func) ?u32 {
    if (!f.has_receiver_param or f.params.len == 0) return null;
    return classIndexOfName(m, f.params[0].ty);
}

/// A top-level property's machine type, taken from the thunk that initializes
/// it. The declaration often carries no annotation (`var counter = 0`), so the
/// declared return type of the thunk says nothing; what the thunk COMPILES to
/// is the answer.
fn globalTy(gpa: std.mem.Allocator, m: *const Module, prog: Program, globals: []const Global, idx: usize) Error!?Ty {
    const gf = m.funcById(globals[idx].func) orelse return null;
    var c = (try eligible(gpa, m, prog, gf, globals, null, &.{})) orelse return null;
    defer c.deinit(gpa);
    return c.ret;
}

/// The class id of an `object` declaration with this name, when the emitter can
/// lay it out. Such a name reads as its single instance rather than as storage.
fn objectClassNamed(m: *const Module, prog: Program, name: []const u8) ?u32 {
    for (m.classes.items, 0..) |*c, i| {
        if (!c.is_object) continue;
        if (!std.mem.eql(u8, c.name, name) and !std.mem.eql(u8, c.fqn, name)) continue;
        if (prog.of(@intCast(i)) == null) return null;
        return @intCast(i);
    }
    return null;
}

/// The object a CLASS name denotes when it is used as a qualifier: `Config` in
/// `Config.Default` names Config's companion, which is an object declaration
/// like any other and carries the members the qualifier reads.
fn companionObjectNamed(m: *const Module, prog: Program, name: []const u8) ?u32 {
    if (name.len == 0) return null;
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}.Companion", .{name})) |qualified| {
        if (objectClassNamed(m, prog, qualified)) |oc| return oc;
    } else |_| {}
    var buf2: [512]u8 = undefined;
    const simple = std.fmt.bufPrint(&buf2, "{s}.Companion", .{simpleName(name)}) catch return null;
    return objectClassNamed(m, prog, simple);
}

/// The class a name denotes when it is read off another class: `Outer.Section`
/// names a type rather than a value. A class NAME resolves to its companion, so
/// the enclosing class of a companion is the one that owns the nested names.
/// The object a call or a read written on a class NAME runs against: that
/// class's companion. A register holding a class name carries no value, so the
/// companion singleton is the receiver.
fn companionReceiver(m: *const Module, prog: Program, types: []const Ty, cls: []const ?u32, r: u32) ?u32 {
    const sc = staticClassOf(types, cls, r) orelse return null;
    if (sc >= m.classes.items.len) return null;
    return companionObjectNamed(m, prog, m.classes.items[sc].fqn);
}

/// The top-level function a bare name in value position denotes: `::twice`
/// lowers to a read of the name, and the value it answers is the function
/// itself. Only when exactly one declaration owns the name — an overload set
/// has no single answer.
fn topLevelFuncNamed(m: *const Module, name: []const u8) ?*const ir.Func {
    var found: ?*const ir.Func = null;
    for (m.funcs.items) |*fn_| {
        if (!fn_.hasBody()) continue;
        if (fn_.has_receiver_param) continue;
        if (!std.mem.eql(u8, fn_.name, name) and !std.mem.eql(u8, fn_.fqn, name)) continue;
        if (found != null) return null;
        found = fn_;
    }
    return found;
}

/// The declaration a bare call binds to when the lowering left it open: among
/// the top-level functions of that name, the one whose parameters these
/// arguments fit. A machine type fits a reference parameter, because it boxes
/// on the way in; it fits a machine parameter only when they are the same
/// type. The candidate matching the most parameters EXACTLY wins, and a tie is
/// a refusal rather than a guess.
fn bareCallTarget(
    m: *const Module,
    prog: Program,
    name: []const u8,
    types: []const Ty,
    base: u32,
    n: u32,
    arg_names: []const ?ir.ConstId,
) ?*const ir.Func {
    var best: ?*const ir.Func = null;
    var tied = false;
    for (m.funcs.items) |*cand| {
        if (!cand.hasBody() or cand.has_receiver_param) continue;
        if (!std.mem.eql(u8, cand.name, name)) continue;
        if (cand.params.len < n) continue;
        const bnd = bindCallArgs(m, cand.params, base, n, arg_names) orelse continue;
        var fits = true;
        for (cand.params, 0..) |p, i| {
            if (p.is_vararg) {
                fits = false;
                break;
            }
            const reg = bnd.regs[i] orelse {
                // Nothing bound it, so it has to have a default to run.
                if (prog.defaultThunk(cand.id, @intCast(i)) == null) fits = false;
                if (!fits) break;
                continue;
            };
            const got = types[reg];
            if (tyOf(p.ty)) |want| {
                if (want != got) {
                    fits = false;
                    break;
                }
            }
        }
        if (!fits) continue;
        if (best != null) tied = true;
        best = cand;
    }
    // Two declarations the arguments fit equally is a question about scope and
    // shadowing that this pass does not answer. Refuse rather than guess.
    if (tied) return null;
    return best;
}

/// Whether more than one top-level declaration of this name takes these
/// arguments. The lowering records ONE of them on the call, but a name the
/// arguments do not separate is re-resolved at run time from the values, so a
/// compiled program must not freeze the lowering's pick.
fn ambiguousOverload(
    m: *const Module,
    prog: Program,
    name: []const u8,
    types: []const Ty,
    base: u32,
    n: u32,
    arg_names: []const ?ir.ConstId,
) bool {
    var fitting: u32 = 0;
    for (m.funcs.items) |*cand| {
        if (!cand.hasBody() or cand.has_receiver_param) continue;
        if (!std.mem.eql(u8, cand.name, name)) continue;
        if (cand.params.len < n) continue;
        const bnd = bindCallArgs(m, cand.params, base, n, arg_names) orelse continue;
        var fits = true;
        for (cand.params, 0..) |p, i| {
            if (p.is_vararg) {
                fits = false;
                break;
            }
            const reg = bnd.regs[i] orelse {
                if (prog.defaultThunk(cand.id, @intCast(i)) == null) fits = false;
                if (!fits) break;
                continue;
            };
            if (tyOf(p.ty)) |want| {
                if (want != types[reg]) {
                    fits = false;
                    break;
                }
            }
        }
        if (fits) fitting += 1;
        if (fitting > 1) return true;
    }
    return false;
}

/// Whether a class's primary constructor also takes these arguments, which is
/// what makes a bare call a question of constructor versus factory. Types match
/// EXACTLY here: Kotlin converts nothing implicitly when it picks an overload,
/// so a `Long` argument does not reach a `ULong` parameter.
fn ctorFits(
    m: *const Module,
    name: []const u8,
    types: []const Ty,
    base: u32,
    n: u32,
    arg_names: []const ?ir.ConstId,
) bool {
    const cid = classQualifierNamed(m, name) orelse return false;
    const cdef = &m.classes.items[cid];
    if (cdef.primary_params.len < n) return false;
    const bnd = bindCallArgs(m, cdef.primary_params, base, n, arg_names) orelse return false;
    for (cdef.primary_params, 0..) |p, i| {
        const reg = bnd.regs[i] orelse {
            if (p.default == null) return false;
            continue;
        };
        if (tyOf(p.ty)) |want| {
            if (want != types[reg]) return false;
        }
    }
    return true;
}

fn classQualifierNamed(m: *const Module, name: []const u8) ?u32 {
    for (m.classes.items, 0..) |*c, i| {
        if (std.mem.eql(u8, c.name, name) or std.mem.eql(u8, c.fqn, name)) return @intCast(i);
    }
    return null;
}

fn qualifierOwnerFqn(fqn: []const u8) []const u8 {
    const tail = ".Companion";
    if (std.mem.endsWith(u8, fqn, tail)) return fqn[0 .. fqn.len - tail.len];
    return fqn;
}

fn nestedClassNamed(m: *const Module, owner_fqn: []const u8, name: []const u8) ?u32 {
    var buf: [512]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "{s}.{s}", .{ owner_fqn, name }) catch return null;
    for (m.classes.items, 0..) |*c, i| {
        if (std.mem.eql(u8, c.fqn, want)) return @intCast(i);
    }
    return null;
}

fn isDispatched(slots: []const SlotUse, slot: u32) bool {
    for (slots) |u| {
        if (u.slot == slot) return true;
    }
    return false;
}

/// One instance the program builds once and roots for its whole life: an
/// `object` declaration, or one entry of an `enum class`.
const SingletonUse = struct { cid: u32, entry: ?u32 = null };

fn singletonSlot(singletons: []const SingletonUse, cid: u32, entry: ?u32) ?usize {
    for (singletons, 0..) |s2, i| {
        if (s2.cid != cid) continue;
        if (s2.entry == null and entry == null) return i;
        if (s2.entry != null and entry != null and s2.entry.? == entry.?) return i;
    }
    return null;
}

/// The enum class a bare name refers to, when the emitter can lay it out. Such
/// a name is a qualifier, not storage: `Color.RED` reads the entry.
fn enumClassNamed(m: *const Module, prog: Program, name: []const u8) ?u32 {
    for (m.classes.items, 0..) |*c, i| {
        if (!c.is_enum) continue;
        if (!std.mem.eql(u8, c.name, name) and !std.mem.eql(u8, c.fqn, name)) continue;
        if (prog.of(@intCast(i)) == null) return null;
        return @intCast(i);
    }
    return null;
}

/// The declaration position of an entry, which is also its ordinal.
fn enumEntryIndex(m: *const Module, prog: Program, cid: u32, name: []const u8) ?u32 {
    if (cid >= m.classes.items.len) return null;
    if (layoutFor(prog.layouts, &m.classes.items[cid])) |l| {
        for (l.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return @intCast(i);
        }
    }
    return null;
}

/// A register that names a CLASS rather than holding a value: `Color` in
/// `Color.RED` is a qualifier the emitter resolves, not storage. It is typed
/// Unit with the class recorded, so it occupies nothing at run time.
fn staticClassOf(types: []const Ty, cls: []const ?u32, r: u32) ?u32 {
    if (types[r] != .unit) return null;
    return cls[r];
}

/// The entries of an enum the emitter laid out.
fn enumEntries(m: *const Module, prog: Program, cid: u32) []const EnumEntryInfo {
    if (cid >= m.classes.items.len) return &.{};
    if (layoutFor(prog.layouts, &m.classes.items[cid])) |l| return l.entries;
    return &.{};
}

fn globalIndex(globals: []const Global, name: []const u8) ?usize {
    for (globals, 0..) |g, i| {
        if (std.mem.eql(u8, g.name, name)) return i;
    }
    return null;
}

pub fn eligible(gpa: std.mem.Allocator, m: *const Module, prog: Program, f: *const Func, globals: []const Global, synth: ?[]const ir.Param, caps: []const CapInfo) Error!?Compiled {
    // A synthesized thunk declares no parameters and reads its caller's
    // positionally, so it is compiled against the signature it will be handed.
    const params: []const ir.Param = synth orelse f.params;
    // A `suspend` body compiles to a state machine over a heap frame; the
    // result is boxed, because it answers either the value or SUSPENDED. A
    // lambda the lowering did not MARK suspending still needs that shape when
    // it calls something that suspends — a `runBlocking` block is written
    // without the keyword.
    const suspends = bodySuspends(m, f);
    // A method is an ordinary function whose first parameter is the receiver;
    // the call sites already move it into arg 0.
    if (f.has_receiver_param and receiverClass(m, f) == null) return no(f, "receiver class");
    // A body the image left deferred is decoded on first touch. The emitter
    // reaches only what the program can call, so this materialises exactly the
    // bodies it compiles.
    if (f.blocks.len == 0) _ = m.ensureFuncBody(@constCast(f));
    if (!f.hasBody() or f.blocks.len == 0) return no(f, "no body");
    if (f.n_locals == 0) return no(f, "no locals");

    // The declared return type is a starting point only. An unannotated
    // declaration (`var counter = 0` lowers to a thunk) carries a placeholder,
    // so the authority is the register the body actually returns; the declared
    // type settles the Unit case, where there is no register to ask.
    var ret = funcRetTy2(m, f) orelse Ty.unit;
    for (params) |p| {
        // A default is the CALLER's business: the callee takes the parameter
        // like any other, and a call that omits it runs the thunk.
        // A parameter whose type names nothing the module declares is an
        // erased reference, not a refusal: it can be passed, returned and
        // stored, and any use that needs its layout refuses where it is used.
        _ = p;
    }

    const types = try gpa.alloc(Ty, f.n_locals);
    errdefer gpa.free(types);
    @memset(types, .unit);
    const cls = try gpa.alloc(?u32, f.n_locals);
    errdefer gpa.free(cls);
    @memset(cls, null);
    const elem = try gpa.alloc(Ty, f.n_locals);
    errdefer gpa.free(elem);
    @memset(elem, .unit);
    const elem_cls = try gpa.alloc(?u32, f.n_locals);
    errdefer gpa.free(elem_cls);
    @memset(elem_cls, null);
    // The integer constant a register was JUST given. Any other instruction
    // clears the whole table, because which register it wrote is not modelled
    // here: a value still known to be constant is one nothing has touched.
    const const_at = try gpa.alloc(?i64, f.n_locals);
    defer gpa.free(const_at);
    @memset(const_at, null);
    var pending_const: ?struct { reg: u32, val: i64 } = null;
    const lam = try gpa.alloc(?LambdaInfo, f.n_locals);
    errdefer gpa.free(lam);
    @memset(lam, null);
    const slot = try gpa.alloc(i32, f.n_locals);
    errdefer gpa.free(slot);
    @memset(slot, -1);
    const known = try gpa.alloc(bool, f.n_locals);
    defer gpa.free(known);
    @memset(known, false);

    // Blocks in reverse postorder, so a register's definition is typed before
    // every use of it except across a back edge, where the lowering already
    // puts the definition ahead of the edge. Source order does not have that
    // property: a `when` writes its result in the arm blocks, which sit after
    // the block that returns it.
    // Where each bare name inside an inlined receiver body resolved. Owned by
    // the Compiled this returns; freed on refusal.
    var bare: std.AutoHashMapUnmanaged(*const ir.Inst, BareResolution) = .empty;
    errdefer bare.deinit(gpa);
    // The implicit receivers in scope, innermost last. `with(x) { … }` and
    // `apply` splice their bodies inline and push the subject here.
    var encl: std.ArrayList(u32) = .empty;
    defer encl.deinit(gpa);

    const order = try blockOrder(gpa, f);
    defer gpa.free(order);
    for (order) |bi| {
        const blk = &f.blocks[bi];
        // A `finally` has to run on every exit from its region, including a
        // throw passing through; that is a separate shape from a handler.
        if (blk.finally != null) return no(f, "finally");
        for (blk.catches) |h| {
            if (h.exception_reg.int() >= f.n_locals) return no(f, "catch register");
            // The handler tests an interval, so the caught type has to be one
            // the program's throwable hierarchy places.
            if (prog.throws.find(h.type_name) == null) return no(f, "catch type");
            types[h.exception_reg.int()] = .object;
            cls[h.exception_reg.int()] = THROWABLE_CLS;
            known[h.exception_reg.int()] = true;
        }
        for (blk.insts) |*inst| {
            // What the PREVIOUS instruction made constant, which is all this
            // pass claims to know: anything else may have written any register.
            @memset(const_at, null);
            if (pending_const) |pc| const_at[pc.reg] = pc.val;
            pending_const = null;
            if (inst.* == .Const) {
                const cv0 = inst.Const;
                if (cv0.value.int() < m.consts.items.len and cv0.dst.int() < f.n_locals) {
                    const kv0: ?i64 = switch (m.consts.items[cv0.value.int()]) {
                        .Int => |x| @as(i64, x),
                        .Long => |x| x,
                        .Short => |x| @as(i64, x),
                        .Byte => |x| @as(i64, x),
                        else => null,
                    };
                    if (kv0) |v0| pending_const = .{ .reg = cv0.dst.int(), .val = v0 };
                }
            }
            switch (inst.*) {
                .Trace => {},
                // The enclosing-subject chain exists for the interpreter's
                // dynamic resolution: a bare name or a member the lowering
                // could not bind consults it while a inlined body runs.
                // Compiled code resolves every one of those statically or
                // refuses, so there is nothing for the chain to answer.
                .EnclosingPush => |ep| {
                    if (ep.src.int() >= f.n_locals) return no(f, "enclosing src");
                    try encl.append(gpa, ep.src.int());
                },
                .EnclosingPop => {
                    if (encl.items.len != 0) _ = encl.pop();
                },
                // A bare name inside such a body: the interpreter searches the
                // implicit receivers innermost first and falls back to the
                // global. The emitter does that search once, here.
                .LoadFromThisOrGlobal => |lt| {
                    if (lt.name.int() >= m.consts.items.len) return no(f, "bare name");
                    const bn = m.consts.items[lt.name.int()];
                    if (bn != .String) return no(f, "bare name kind");
                    if (lt.dst.int() >= f.n_locals) return no(f, "bare dst");
                    if (resolveBare(m, prog, types, cls, known, encl.items, null, bn.String, false)) |res| {
                        try bare.put(gpa, inst, res);
                        switch (res) {
                            .field => |fl| {
                                const fds = prog.of(cls[fl.recv].?).?;
                                types[lt.dst.int()] = fds[fl.idx].ty;
                                cls[lt.dst.int()] = fds[fl.idx].cls;
                            },
                            .accessor => |ac| {
                                const gfn = m.funcById(ac.func) orelse return no(f, "bare getter");
                                const gt = funcRetTy2(m, gfn) orelse return no(f, "bare getter type");
                                types[lt.dst.int()] = gt;
                                if (gt == .object) cls[lt.dst.int()] = classIndexOfName(m, gfn.return_ty);
 if (refElemOf(cls[lt.dst.int()], gfn.return_ty)) |re_| elem[lt.dst.int()] = re_;
                    elem_cls[lt.dst.int()] = refElemCls(m, cls[lt.dst.int()], gfn.return_ty);
                            },
                            .global, .member, .call => unreachable,
                        }
                        known[lt.dst.int()] = true;
                        continue;
                    }
                    const gi5 = globalIndex(globals, bn.String) orelse return noName(f, "bare name", bn.String);
                    try bare.put(gpa, inst, .global);
                    const gt5 = (try globalTy(gpa, m, prog, globals, gi5)) orelse return no(f, "global type");
                    types[lt.dst.int()] = gt5;
                    if (gt5 == .object) {
                        const gf5 = m.funcById(globals[gi5].func).?;
                        cls[lt.dst.int()] = classIndexOfName(m, gf5.return_ty);
                        if (refElemOf(cls[lt.dst.int()], gf5.return_ty)) |re_| elem[lt.dst.int()] = re_;
                    elem_cls[lt.dst.int()] = refElemCls(m, cls[lt.dst.int()], gf5.return_ty);
                    }
                    known[lt.dst.int()] = true;
                },
                .StoreToThisOrGlobal => |st| {
                    if (st.name.int() >= m.consts.items.len) return no(f, "bare name");
                    const bn2 = m.consts.items[st.name.int()];
                    if (bn2 != .String) return no(f, "bare name kind");
                    if (st.value.int() >= f.n_locals or !known[st.value.int()]) return no(f, "bare value");
                    const pref: ?u32 = if (st.recv) |rv| rv.int() else null;
                    if (resolveBare(m, prog, types, cls, known, encl.items, pref, bn2.String, true)) |res| {
                        try bare.put(gpa, inst, res);
                        switch (res) {
                            .field => |fl| {
                                const fds = prog.of(cls[fl.recv].?).?;
                                if (types[st.value.int()] != fds[fl.idx].ty) return no(f, "bare value type");
                            },
                            .accessor => |ac| {
                                const sfn = m.funcById(ac.func) orelse return no(f, "bare setter");
                                const want6: Ty = if (sfn.params.len >= 2) (tyOf(sfn.params[1].ty) orelse .object) else return no(f, "bare setter arity");
                                if (want6 != .object and types[st.value.int()] != want6) return no(f, "bare value type");
                            },
                            .global, .member, .call => unreachable,
                        }
                        continue;
                    }
                    const gi6 = globalIndex(globals, bn2.String) orelse return noName(f, "bare name", bn2.String);
                    _ = gi6;
                    try bare.put(gpa, inst, .global);
                },
                // A bare call whose name may be a member of an implicit
                // receiver or a top-level declaration. The interpreter decides
                // at run time by searching the receivers; the emitter searches
                // the same ones once, here.
                .CallMemberOrGlobal => |cg2| {

                    if (cg2.name.int() >= m.consts.items.len) return no(f, "bare call name");
                    const cn2 = m.consts.items[cg2.name.int()];
                    if (cn2 != .String) return no(f, "bare call name kind");
                    var ka9: u32 = 0;
                    while (ka9 < cg2.n_args) : (ka9 += 1) {
                        const a9 = cg2.args.int() + ka9;
                        if (a9 >= f.n_locals or !known[a9]) return no(f, "bare call arg");
                    }
                    if (cg2.dst.int() >= f.n_locals) return no(f, "bare call dst");
                    // A bare call to a stdlib entry the backend performs
                    // directly is that operation, not a call to a body that
                    // does not exist.
                    if (cg2.func) |gfid0| {
                        if (m.funcById(gfid0)) |gfn0| {
                            if (isPrintln(gfn0) or scalarIntrinsic(gfn0) == .print) {
                                if (cg2.n_args != 1) return no(f, "println arity");
                                if (types[cg2.args.int()] == .unit) return no(f, "println of Unit");
                                try bare.put(gpa, inst, .{ .call = gfid0 });
                                types[cg2.dst.int()] = .unit;
                                known[cg2.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    // The innermost implicit receiver that declares the name
                    // wins, which is what shadows a same-named global.
                    var mi: usize = encl.items.len;
                    while (mi > 0) {
                        mi -= 1;
                        const r9 = encl.items[mi];
                        if (r9 >= f.n_locals or !known[r9] or types[r9] != .object) continue;
                        const rc9 = cls[r9] orelse continue;
                        if (isBuiltinCls(rc9)) continue;
                        // A FUNCTION-TYPED property of the receiver answers
                        // through the invoke convention, which outranks a
                        // global of the same name.
                        if (fieldIndex(prog, rc9, cn2.String) != null) return noName(f, "bare call names a property", cn2.String);
                        const root9b = memberRoot(m, prog, rc9, cn2.String, cg2.n_args) orelse continue;
                        const rt9 = funcRetTy2(m, root9b) orelse return no(f, "bare call return type");
                        try bare.put(gpa, inst, .{ .member = .{ .recv = r9, .slot = root9b.id.int() } });
                        types[cg2.dst.int()] = rt9;
                        if (rt9 == .object) {
                            cls[cg2.dst.int()] = classIndexOfName(m, root9b.return_ty);
                            if (refElemOf(cls[cg2.dst.int()], root9b.return_ty)) |re9| elem[cg2.dst.int()] = re9;
                    elem_cls[cg2.dst.int()] = refElemCls(m, cls[cg2.dst.int()], root9b.return_ty);
                        }
                        known[cg2.dst.int()] = true;
                        break;
                    } else {
                        // Which declaration a bare call names is a question of
                        // scope: an overload set the arguments do not separate,
                        // a class of the same name (constructor versus
                        // factory), or a property holding a function all answer
                        // it at run time in the interpreter. The emitter has to
                        // answer it once, so it answers only when the
                        // declaration is unambiguous.
                        const picked = bareCallTarget(m, prog, cn2.String, types, cg2.args.int(), cg2.n_args, cg2.arg_names);
                        if (picked == null) return noName(f, "bare call", cn2.String);
                        if (ctorFits(m, cn2.String, types, cg2.args.int(), cg2.n_args, cg2.arg_names))
                            return noName(f, "bare call", cn2.String);
                        if (globalIndex(globals, cn2.String) != null) return noName(f, "bare call", cn2.String);
                        const gfid = picked.?.id;
                        const gfn9 = m.funcById(gfid) orelse return no(f, "bare call target");
                        if (!gfn9.hasBody()) return noCallee(f, gfn9, "no body for");
                        if (gfn9.params.len < cg2.n_args) return noCallee(f, gfn9, "arity of");
                        // Arguments reach the callee in ITS order, and a
                        // parameter nothing binds runs the thunk for it.
                        const bb9 = bindCallArgs(m, gfn9.params, cg2.args.int(), cg2.n_args, cg2.arg_names) orelse
                            return noCallee(f, gfn9, "argument binding of");
                        var db9: u32 = 0;
                        while (db9 < bb9.n) : (db9 += 1) {
                            if (bb9.regs[db9] != null) continue;
                            const dfid9 = prog.defaultThunk(gfn9.id, db9) orelse return noCallee(f, gfn9, "arity of");
                            const dfn9b = m.funcById(dfid9) orelse return no(f, "default thunk");
                            if (funcRetTy2(m, dfn9b) == null) return no(f, "default thunk type");
                        }
                        const rt10 = funcRetTy2(m, gfn9) orelse return no(f, "bare call return type");
                        try bare.put(gpa, inst, .{ .call = gfid });
                        types[cg2.dst.int()] = rt10;
                        if (rt10 == .object) {
                            cls[cg2.dst.int()] = callResultCls(m, gfn9);
                            if (refElemOf(cls[cg2.dst.int()], gfn9.return_ty)) |re10| elem[cg2.dst.int()] = re10;
                    elem_cls[cg2.dst.int()] = refElemCls(m, cls[cg2.dst.int()], gfn9.return_ty);
                        }
                        known[cg2.dst.int()] = true;
                    }
                },
                .Const => |c| {
                    if (c.dst.int() >= f.n_locals) return no(f, "const dst");
                    if (c.value.int() >= m.consts.items.len) return no(f, "const id");
                    const t = constTy(m.consts.items[c.value.int()]) orelse return no(f, "const kind");
                    types[c.dst.int()] = t;
                    // A null literal has no class of its own; whatever it is
                    // compared against or assigned to supplies that.
                    if (t == .object and m.consts.items[c.value.int()] == .String) cls[c.dst.int()] = STRING_CLS;
                    known[c.dst.int()] = true;
                },
                .MakeCell => |mk| {
                    if (mk.dst.int() >= f.n_locals or mk.src.int() >= f.n_locals) return no(f, "cell reg");
                    if (!known[mk.src.int()]) return no(f, "cell source");
                    types[mk.dst.int()] = .object;
                    cls[mk.dst.int()] = CELL_CLS;
                    // A cell holds one machine type for its whole life, so it
                    // is the one every write agrees on. The lowering seeds a
                    // `var` with a Unit placeholder where the declaration has
                    // no initializer, which says nothing; writes that disagree
                    // leave the cell holding boxed values.
                    var cet = types[mk.src.int()];
                    for (f.blocks) |*b2| {
                        for (b2.insts) |*ci| {
                            if (ci.* != .CellSet) continue;
                            if (ci.CellSet.cell.int() != mk.dst.int()) continue;
                            const vr = ci.CellSet.value.int();
                            if (vr >= f.n_locals or !known[vr]) continue;
                            if (types[vr] == .unit) continue;
                            if (cet == .unit) {
                                cet = types[vr];
                            } else if (cet != types[vr]) {
                                cet = .object;
                            }
                        }
                    }
                    elem[mk.dst.int()] = cet;
                    known[mk.dst.int()] = true;
                },
                .CellGet => |cg| {
                    if (cg.cell.int() >= f.n_locals or !known[cg.cell.int()]) return no(f, "cell read");
                    if (cls[cg.cell.int()] == null or cls[cg.cell.int()].? != CELL_CLS) return no(f, "cell read of a non-cell");
                    if (cg.dst.int() >= f.n_locals) return no(f, "cell dst");
                    types[cg.dst.int()] = elem[cg.cell.int()];
                    known[cg.dst.int()] = true;
                },
                .CellSet => |cs| {
                    if (cs.cell.int() >= f.n_locals or !known[cs.cell.int()]) return no(f, "cell write");
                    if (cls[cs.cell.int()] == null or cls[cs.cell.int()].? != CELL_CLS) return no(f, "cell write to a non-cell");
                    if (cs.value.int() >= f.n_locals or !known[cs.value.int()]) return no(f, "cell value");
                    // A cell of boxed values takes anything; one of a machine
                    // type takes that type.
                    if (elem[cs.cell.int()] != .object and types[cs.value.int()] != elem[cs.cell.int()]) {
                        return no(f, "cell value type");
                    }
                },
                .LoadCapture => |lc| {
                    if (lc.dst.int() >= f.n_locals or lc.idx >= caps.len) return no(f, "load capture");
                    types[lc.dst.int()] = caps[lc.idx].ty;
                    cls[lc.dst.int()] = caps[lc.idx].cls;
                    elem[lc.dst.int()] = caps[lc.idx].elem;
                    known[lc.dst.int()] = true;
                },
                // `x as T`. The value passes through unchanged when the test
                // holds; otherwise a `ClassCastException`, or null for `as?`.
                // The named type is what the result register carries, which is
                // the point of writing the cast.
                .Cast => |ca| {
                    if (ca.src.int() >= f.n_locals or !known[ca.src.int()]) return no(f, "cast operand");
                    if (ca.dst.int() >= f.n_locals) return no(f, "cast dst");
                    // `as?` and `as T?` admit null, so the result is a
                    // reference whatever the named type is.
                    const scalar = if (ca.safe or ca.ty.nullable) null else tyOf(ca.ty);
                    if (scalar) |t| {
                        types[ca.dst.int()] = t;
                    } else {
                        types[ca.dst.int()] = .object;
                        cls[ca.dst.int()] = classIndexOfName(m, ca.ty);
                        if (refElemOf(cls[ca.dst.int()], ca.ty)) |re13| elem[ca.dst.int()] = re13;
                    elem_cls[ca.dst.int()] = refElemCls(m, cls[ca.dst.int()], ca.ty);
                    }
                    known[ca.dst.int()] = true;
                },
                // `x is T`. Which classes answer it is decided at emit time
                // from the hierarchy the program compiled; a value that is not
                // a compiled instance answers from its own representation.
                .InstanceOf => |io| {
                    if (io.src.int() >= f.n_locals or !known[io.src.int()]) return no(f, "is operand");
                    if (io.dst.int() >= f.n_locals) return no(f, "is dst");
                    types[io.dst.int()] = .boolean;
                    known[io.dst.int()] = true;
                },
                .LoadParam => |lp| {
                    if (lp.dst.int() >= f.n_locals or lp.idx >= params.len) return no(f, "load param");
                    const pt = params[lp.idx].ty;
                    if (params[lp.idx].is_vararg) {
                        // The parameter holds the array the call site built.
                        types[lp.dst.int()] = .object;
                        cls[lp.dst.int()] = ARRAY_CLS;
                        elem[lp.dst.int()] = tyOf(pt) orelse .unit;
                        known[lp.dst.int()] = true;
                        continue;
                    }
                    if (tyOf(pt)) |t| {
                        types[lp.dst.int()] = t;
                    } else {
                        types[lp.dst.int()] = .object;
                        cls[lp.dst.int()] = classIndexOfName(m, pt);
                        if (refElemOf(cls[lp.dst.int()], pt)) |re_| elem[lp.dst.int()] = re_;
                    elem_cls[lp.dst.int()] = refElemCls(m, cls[lp.dst.int()], pt);
                        // `List<Int>` says what its elements are; a list whose
                        // element type is written down needs no inference. An
                        // array says so in its own name.
                        if (cls[lp.dst.int()]) |rc| {
                            if (rc == LIST_CLS and pt.args.len == 1) {
                                if (tyOf(pt.args[0])) |et| elem[lp.dst.int()] = et;
                            }
                            if (rc == ARRAY_CLS) elem[lp.dst.int()] = arrayElemOf(pt);
                            // A function type's last argument is its result.
                            if (funcClsArity(rc) != null) elem[lp.dst.int()] = functionResultTy(pt);
                        }
                    }
                    known[lp.dst.int()] = true;
                },
                .Move => |mv| {
                    if (mv.dst.int() >= f.n_locals or mv.src.int() >= f.n_locals) return no(f, "move reg");
                    if (!known[mv.src.int()]) return no(f, "move source");
                    types[mv.dst.int()] = types[mv.src.int()];
                    cls[mv.dst.int()] = cls[mv.src.int()];
                    elem[mv.dst.int()] = elem[mv.src.int()];
                    elem_cls[mv.dst.int()] = elem_cls[mv.src.int()];
                    lam[mv.dst.int()] = lam[mv.src.int()];
                    known[mv.dst.int()] = true;
                },
                .BinOp => |b| {
                    if (b.dst.int() >= f.n_locals or b.lhs.int() >= f.n_locals or b.rhs.int() >= f.n_locals) return null;
                    if (!known[b.lhs.int()] or !known[b.rhs.int()]) return null;
                    const lt = types[b.lhs.int()];
                    const rt = types[b.rhs.int()];
                    // `==`/`!=` where either side is a reference is Kotlin's
                    // structural equality, which a null operand reduces to a
                    // null test. Either way the runtime decides it.
                    if ((b.op == .Eq or b.op == .NotEq) and (lt == .object or rt == .object)) {
                        if (b.dst.int() >= f.n_locals) return no(f, "compare dst");
                        types[b.dst.int()] = .boolean;
                        known[b.dst.int()] = true;
                        continue;
                    }
                    // `===` is referential identity, which never dispatches a
                    // user `equals`.
                    if (b.op == .IdentEq or b.op == .IdentNeq) {
                        if (b.dst.int() >= f.n_locals) return no(f, "compare dst");
                        types[b.dst.int()] = .boolean;
                        known[b.dst.int()] = true;
                        continue;
                    }
                    // Concatenation, either spelled as itself or as `+` with a
                    // string on one side. Kotlin renders the other operand
                    // through its own `toString`, so anything may be joined.
                    const str_join = b.op == .StringConcat or
                        (b.op == .Add and (isStringReg(types, cls, b.lhs.int()) or isStringReg(types, cls, b.rhs.int())));
                    if (str_join) {
                        if (b.dst.int() >= f.n_locals) return no(f, "concat dst");
                        types[b.dst.int()] = .object;
                        cls[b.dst.int()] = STRING_CLS;
                        known[b.dst.int()] = true;
                        continue;
                    }
                    // `a..b` and `a..<b` build a progression: a runtime value
                    // with its own bound and step resolution, which the
                    // interpreter performs and compiled code reuses.
                    if (b.op == .RangeTo or b.op == .RangeUntil) {
                        if (!isNumericTy(lt) or !isNumericTy(rt)) return no(f, "range operand types");
                        if (b.dst.int() >= f.n_locals) return no(f, "range dst");
                        types[b.dst.int()] = .object;
                        cls[b.dst.int()] = RANGE_CLS;
                        // A progression counts values of the operands' own
                        // type: `'a'..'e'` yields Chars, where the ARITHMETIC
                        // promotion of two Chars would be Int.
                        elem[b.dst.int()] = if (lt == rt) lt else (promote(lt, rt) orelse lt);
                        known[b.dst.int()] = true;
                        continue;
                    }
                    // `ushr` has no C spelling of its own — it is a cast to
                    // unsigned around `>>` — so it is admitted here and written
                    // out below rather than looked up.
                    if (b.op != .UShr and cOp(b.op) == null) {
                        if (traceOn()) std.debug.print("[cgen] refuse {s}: binop kind `{s}`\n", .{ f.fqn, @tagName(b.op) });
                        return null;
                    }
                    if (isCmp(b.op)) {
                        if (lt == .unit or rt == .unit) return null;
                        types[b.dst.int()] = .boolean;
                    } else if (isBitwise(b.op)) {
                        // Kotlin's shifts and bitwise ops are integer-only and
                        // take the LEFT operand's width.
                        if (lt.isFloat() or rt.isFloat() or lt == .unit or rt == .unit) return null;
                        if ((lt == .boolean) != (rt == .boolean)) return null;
                        types[b.dst.int()] = lt;
                    } else if (lt == .char and (b.op == .Add or b.op == .Sub) and
                        rt != .char and isNumericTy(rt) and !rt.isFloat())
                    {
                        // Kotlin's `Char + Int` and `Char - Int` answer a Char;
                        // `Char - Char` answers the distance, which promotes.
                        types[b.dst.int()] = .char;
                    } else {
                        types[b.dst.int()] = promote(lt, rt) orelse return no(f, "binop operand types");
                    }
                    known[b.dst.int()] = true;
                },
                .UnOp => |u| {
                    if (u.dst.int() >= f.n_locals or u.operand.int() >= f.n_locals) return no(f, "unop reg");
                    if (!known[u.operand.int()]) return no(f, "unop operand");
                    const ot = types[u.operand.int()];
                    if (!isNumericTy(ot)) return no(f, "unop operand type");
                    types[u.dst.int()] = switch (u.op) {
                        // Kotlin's unary minus and plus on a Byte or a Short
                        // answer an Int; every other width answers itself.
                        .Neg, .Plus => if (ot == .byte or ot == .short) Ty.i32 else ot,
                        // `inc()`/`dec()` keep the receiver's type, and wrap
                        // like the rest of Kotlin's integer arithmetic.
                        .Inc, .Dec => ot,
                    };
                    known[u.dst.int()] = true;
                },
                .Not => |n| {
                    if (n.dst.int() >= f.n_locals or n.src.int() >= f.n_locals) return no(f, "not reg");
                    if (!known[n.src.int()] or types[n.src.int()] != .boolean) return no(f, "not operand");
                    types[n.dst.int()] = .boolean;
                    known[n.dst.int()] = true;
                },
                .CallMember => |cm| {
                    // `toString()` on a value that declares no override of its
                    // own: the runtime renders it as it renders it for
                    // printing. A class that DOES override still dispatches.
                    if (cm.name.int() < m.consts.items.len) {
                        const tsn = m.consts.items[cm.name.int()];
                        if (tsn == .String and isToStringCall(tsn.String, cm.n_args) and
                            cm.receiver.int() < f.n_locals and known[cm.receiver.int()])
                        {
                            if (rendersToString(m, prog, cls, cm.receiver.int())) {
                                if (cm.dst.int() >= f.n_locals) return no(f, "member dst");
                                types[cm.dst.int()] = .object;
                                cls[cm.dst.int()] = STRING_CLS;
                                known[cm.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    // The iteration protocol on a builtin receiver, written
                    // by name rather than bound to a slot. Which members those
                    // are, and what each answers, is the interpreter's — the
                    // same classification the slot-bound route reads.
                    if (cm.arg_names.len == 0 and cm.name.int() < m.consts.items.len and
                        cm.receiver.int() < f.n_locals and known[cm.receiver.int()] and
                        types[cm.receiver.int()] == .object and cls[cm.receiver.int()] != null and
                        isBuiltinCls(cls[cm.receiver.int()].?))
                    {
                        const bmn = m.consts.items[cm.name.int()];
                        if (bmn == .String) {
                            if (member_dispatch.hostFreeMemberAnswer(plainFieldName(bmn.String))) |ans| {
                                var kkb: u32 = 0;
                                while (kkb < cm.n_args) : (kkb += 1) {
                                    const ab = cm.args.int() + kkb;
                                    if (ab >= f.n_locals or !known[ab]) return no(f, "host member arg");
                                }
                                if (cm.dst.int() >= f.n_locals) return no(f, "host member dst");
                                const et2 = elem[cm.receiver.int()];
                                switch (ans) {
                                    .iterator => {
                                        types[cm.dst.int()] = .object;
                                        cls[cm.dst.int()] = ITER_CLS;
                                        elem[cm.dst.int()] = et2;
                                        elem_cls[cm.dst.int()] = elem_cls[cm.receiver.int()];
                                    },
                                    .boolean => types[cm.dst.int()] = .boolean,
                                    .index => types[cm.dst.int()] = .i32,
                                    .unit => types[cm.dst.int()] = .unit,
                                    .element => {
                                        types[cm.dst.int()] = if (et2 == .unit) .object else et2;
                                        if (types[cm.dst.int()] == .object) cls[cm.dst.int()] = elem_cls[cm.receiver.int()];
                                    },
                                }
                                known[cm.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    if (cm.receiver.int() < f.n_locals and known[cm.receiver.int()] and
                        types[cm.receiver.int()] == .object and cls[cm.receiver.int()] != null and
                        cls[cm.receiver.int()].? == ARRAY_CLS)
                    {
                        if (cm.name.int() >= m.consts.items.len) return no(f, "member name");
                        const an = m.consts.items[cm.name.int()];
                        if (an != .String) return no(f, "member name kind");
                        const aa = cm.args.int();
                        var ka: u32 = 0;
                        while (ka < cm.n_args) : (ka += 1) {
                            if (aa + ka >= f.n_locals or !known[aa + ka]) return no(f, "array arg");
                        }
                        if (cm.dst.int() >= f.n_locals) return no(f, "array dst");
                        const aet = elem[cm.receiver.int()];
                        if (std.mem.eql(u8, an.String, "get") and cm.n_args == 1) {
                            if (types[aa] != .i32) return no(f, "array index type");
                            types[cm.dst.int()] = if (aet == .unit) .object else aet;
                            cls[cm.dst.int()] = null;
                        } else if (std.mem.eql(u8, an.String, "set") and cm.n_args == 2) {
                            if (types[aa] != .i32) return no(f, "array index type");
                            if (aet != .unit and types[aa + 1] != aet) return no(f, "array element type");
                            types[cm.dst.int()] = .unit;
                        } else return noName(f, "array member", an.String);
                        known[cm.dst.int()] = true;
                        continue;
                    }
                    if (cm.receiver.int() < f.n_locals and known[cm.receiver.int()] and
                        types[cm.receiver.int()] == .object and cls[cm.receiver.int()] != null and
                        cls[cm.receiver.int()].? == LIST_CLS)
                    {
                        if (cm.name.int() >= m.consts.items.len) return no(f, "member name");
                        const mn = m.consts.items[cm.name.int()];
                        if (mn != .String) return no(f, "member name kind");
                        const a0 = cm.args.int();
                        var kk: u32 = 0;
                        while (kk < cm.n_args) : (kk += 1) {
                            if (a0 + kk >= f.n_locals or !known[a0 + kk]) return no(f, "list arg");
                        }
                        if (cm.dst.int() >= f.n_locals) return no(f, "list dst");
                        if (std.mem.eql(u8, mn.String, "get") and cm.n_args == 1) {
                            if (types[a0] != .i32) return no(f, "list index type");
                            const et = elem[cm.receiver.int()];
                            types[cm.dst.int()] = if (et == .unit) .object else et;
                            cls[cm.dst.int()] = if (et == .unit) elem_cls[cm.receiver.int()] else null;
                            known[cm.dst.int()] = true;
                            continue;
                        }
                        if (std.mem.eql(u8, mn.String, "add") and cm.n_args == 1) {
                            types[cm.dst.int()] = .boolean;
                            known[cm.dst.int()] = true;
                            continue;
                        }
                        if (std.mem.eql(u8, mn.String, "set") and cm.n_args == 2) {
                            if (types[a0] != .i32) return no(f, "list index type");
                            types[cm.dst.int()] = .object;
                            cls[cm.dst.int()] = null;
                            known[cm.dst.int()] = true;
                            continue;
                        }
                        return no(f, "list member");
                    }
                    // A member CALLED on a class name runs on that class's
                    // companion: `Config.of(3)` is a call on the companion
                    // object, with the companion as the receiver.
                    if (numConv(m, cm) == null and cm.arg_names.len == 0 and cm.name.int() < m.consts.items.len) {
                        if (companionReceiver(m, prog, types, cls, cm.receiver.int())) |cc6| {
                            const mn6 = m.consts.items[cm.name.int()];
                            if (mn6 != .String) return no(f, "member name kind");
                            const root6 = memberRoot(m, prog, cc6, plainFieldName(mn6.String), cm.n_args) orelse
                                return noName(f, "companion member", mn6.String);
                            const mrt6 = funcRetTy2(m, root6) orelse return no(f, "member return type");
                            var kk6: u32 = 0;
                            while (kk6 < cm.n_args) : (kk6 += 1) {
                                const ar6b = cm.args.int() + kk6;
                                if (ar6b >= f.n_locals or !known[ar6b]) return no(f, "member arg");
                            }
                            if (cm.dst.int() >= f.n_locals) return no(f, "member dst");
                            types[cm.dst.int()] = mrt6;
                            if (mrt6 == .object) {
                                cls[cm.dst.int()] = classIndexOfName(m, root6.return_ty);
                                if (refElemOf(cls[cm.dst.int()], root6.return_ty)) |re6| elem[cm.dst.int()] = re6;
                    elem_cls[cm.dst.int()] = refElemCls(m, cls[cm.dst.int()], root6.return_ty);
                            }
                            known[cm.dst.int()] = true;
                            continue;
                        }
                    }
                    // A member call on a user class the lowering left by
                    // name. The declaration it binds to is decided here, and
                    // dispatch then runs exactly as it does for a slot the
                    // lowering resolved.
                    if (numConv(m, cm) == null and cm.arg_names.len == 0 and
                        cm.receiver.int() < f.n_locals and known[cm.receiver.int()] and
                        types[cm.receiver.int()] == .object)
                    {
                        if (cls[cm.receiver.int()]) |rc5| {
                            if (!isBuiltinCls(rc5) and cm.name.int() < m.consts.items.len) {
                                const mnm = m.consts.items[cm.name.int()];
                                if (mnm != .String) return no(f, "member name kind");
                                // A property holding a function, called by its
                                // name: read the property, then invoke what it
                                // holds.
                                if (fieldIndex(prog, rc5, mnm.String)) |fidx| {
                                    const fds5 = prog.of(rc5).?;
                                    const far = funcClsArity(fds5[fidx].cls orelse 0) orelse return noName(f, "member", mnm.String);
                                    if (far != cm.n_args) return no(f, "invoke arity");
                                    var kk7: u32 = 0;
                                    while (kk7 < cm.n_args) : (kk7 += 1) {
                                        const a7 = cm.args.int() + kk7;
                                        if (a7 >= f.n_locals or !known[a7]) return no(f, "invoke arg");
                                    }
                                    if (cm.dst.int() >= f.n_locals) return no(f, "invoke dst");
                                    types[cm.dst.int()] = fds5[fidx].elem;
                                    known[cm.dst.int()] = true;
                                    continue;
                                }
                                const root5 = memberRoot(m, prog, rc5, plainFieldName(mnm.String), cm.n_args) orelse {
                                    // A value with no `toString` of its own
                                    // renders the way the runtime renders it
                                    // for printing: one renderer, two callers.
                                    if (cm.n_args == 0 and std.mem.eql(u8, plainFieldName(mnm.String), "toString")) {
                                        if (cm.dst.int() >= f.n_locals) return no(f, "member dst");
                                        types[cm.dst.int()] = .object;
                                        cls[cm.dst.int()] = STRING_CLS;
                                        known[cm.dst.int()] = true;
                                        continue;
                                    }
                                    return noName(f, "member", mnm.String);
                                };
                                const mrt = funcRetTy2(m, root5) orelse return no(f, "member return type");
                                var kk5: u32 = 0;
                                while (kk5 < cm.n_args) : (kk5 += 1) {
                                    const ar5 = cm.args.int() + kk5;
                                    if (ar5 >= f.n_locals or !known[ar5]) return no(f, "member arg");
                                }
                                if (cm.dst.int() >= f.n_locals) return no(f, "member dst");
                                types[cm.dst.int()] = mrt;
                                if (mrt == .object) cls[cm.dst.int()] = classIndexOfName(m, root5.return_ty);
 if (refElemOf(cls[cm.dst.int()], root5.return_ty)) |re_| elem[cm.dst.int()] = re_;
                    elem_cls[cm.dst.int()] = refElemCls(m, cls[cm.dst.int()], root5.return_ty);
                                known[cm.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    const to = numConv(m, cm) orelse return instRefuseNamed(m, f, inst, cm.name);
                    if (cm.receiver.int() >= f.n_locals or !known[cm.receiver.int()]) return no(f, "conv receiver");
                    const rt2 = types[cm.receiver.int()];
                    if (!isNumericTy(rt2)) return no(f, "conv receiver type");
                    if (cm.dst.int() >= f.n_locals) return no(f, "conv dst");
                    // Kotlin saturates a floating value to Int.MIN/MAX and maps
                    // NaN to 0; a C cast leaves all three undefined.
                    if (rt2.isFloat() and (to == .i32 or to == .i64)) return no(f, "float to int");
                    types[cm.dst.int()] = to;
                    known[cm.dst.int()] = true;
                },
                .CallVirtual => |cv| {
                    // `toString()` on a value that declares no override of its
                    // own renders through the runtime; a class that DOES
                    // override still dispatches.
                    if (m.funcById(ir.FuncId.from(cv.slot.int()))) |tsd| {
                        if (isToStringCall(tsd.name, cv.n_args) and
                            cv.receiver.int() < f.n_locals and known[cv.receiver.int()])
                        {
                            if (rendersToString(m, prog, cls, cv.receiver.int())) {
                                if (cv.dst.int() >= f.n_locals) return no(f, "virtual dst");
                                types[cv.dst.int()] = .object;
                                cls[cv.dst.int()] = STRING_CLS;
                                known[cv.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    // A member the runtime serves from the receiver's own
                    // representation. The receiver has to be a runtime value
                    // rather than a compiled class: a user class that
                    // implements the same interface dispatches to its body.
                    if (cv.receiver.int() < f.n_locals and known[cv.receiver.int()] and
                        types[cv.receiver.int()] == .object and cls[cv.receiver.int()] != null and
                        isBuiltinCls(cls[cv.receiver.int()].?))
                    {
                        if (m.funcById(ir.FuncId.from(cv.slot.int()))) |decl| host: {
                            const op = hostMemberOp(decl) orelse break :host;
                            var kh: u32 = 0;
                            while (kh < cv.n_args) : (kh += 1) {
                                const ah = cv.args.int() + kh;
                                if (ah >= f.n_locals or !known[ah]) return no(f, "host member arg");
                            }
                            if (cv.dst.int() >= f.n_locals) return no(f, "host member dst");
                            if (op == .collection_iterator) {
                                types[cv.dst.int()] = .object;
                                cls[cv.dst.int()] = ITER_CLS;
                                elem[cv.dst.int()] = elem[cv.receiver.int()];
                                elem_cls[cv.dst.int()] = elem_cls[cv.receiver.int()];
                                known[cv.dst.int()] = true;
                                continue;
                            }
                            // The declaration says what the step answers. A
                            // return type that names neither a machine type
                            // nor a compiled class is the container's own
                            // element type, which the receiver carries.
                            const hrt = tyOf(decl.return_ty) orelse blk: {
                                if (classIndexOfName(m, decl.return_ty) == null and
                                    elem[cv.receiver.int()] != .unit) break :blk elem[cv.receiver.int()];
                                break :blk Ty.object;
                            };
                            types[cv.dst.int()] = hrt;
                            if (hrt == .object) {
                                cls[cv.dst.int()] = classIndexOfName(m, decl.return_ty) orelse
                                    elem_cls[cv.receiver.int()];
                            }
                            known[cv.dst.int()] = true;
                            continue;
                        }
                    }
                    if (cv.receiver.int() < f.n_locals and known[cv.receiver.int()] and
                        cls[cv.receiver.int()] != null and cls[cv.receiver.int()].? == LIST_CLS)
                    {
                        const mn = listMemberName(m, cv.slot) orelse return no(f, "list virtual member");
                        const a0 = cv.args.int();
                        var kk: u32 = 0;
                        while (kk < cv.n_args) : (kk += 1) {
                            if (a0 + kk >= f.n_locals or !known[a0 + kk]) return no(f, "list arg");
                        }
                        if (cv.dst.int() >= f.n_locals) return no(f, "list dst");
                        if (std.mem.eql(u8, mn, "get") and cv.n_args == 1) {
                            if (types[a0] != .i32) return no(f, "list index type");
                            const et = elem[cv.receiver.int()];
                            types[cv.dst.int()] = if (et == .unit) .object else et;
                            cls[cv.dst.int()] = if (et == .unit) elem_cls[cv.receiver.int()] else null;
                        } else if (std.mem.eql(u8, mn, "add") and cv.n_args == 1) {
                            types[cv.dst.int()] = .boolean;
                        } else if (std.mem.eql(u8, mn, "set") and cv.n_args == 2) {
                            if (types[a0] != .i32) return no(f, "list index type");
                            types[cv.dst.int()] = .object;
                            cls[cv.dst.int()] = null;
                        } else {
                            // Any other member of a builtin receiver is an
                            // operation the interpreter already implements.
                            const decl = m.funcById(ir.FuncId.from(cv.slot.int())) orelse return no(f, "list virtual member");
                            const sym = stdlibEntry(decl) orelse return noName(f, "list virtual member", decl.fqn);
                            _ = sym;
                            const vrt = tyOf(decl.return_ty) orelse Ty.object;
                            types[cv.dst.int()] = vrt;
                            if (vrt == .object) {
                                cls[cv.dst.int()] = classIndexOfName(m, decl.return_ty);
                                if (refElemOf(cls[cv.dst.int()], decl.return_ty)) |re12| elem[cv.dst.int()] = re12;
                    elem_cls[cv.dst.int()] = refElemCls(m, cls[cv.dst.int()], decl.return_ty);
                            }
                            known[cv.dst.int()] = true;
                            continue;
                        }
                        known[cv.dst.int()] = true;
                        continue;
                    }
                    if (cv.arg_names.len == 0 and cv.receiver.int() < f.n_locals and
                        known[cv.receiver.int()] and types[cv.receiver.int()] == .object)
                    {
                        if (m.funcById(ir.FuncId.from(cv.slot.int()))) |root| {
                            if (root.hasBody() or root.params.len != 0) {
                                // The slot's root declaration gives the result
                                // type and the argument shape; which body runs
                                // is decided at run time by the receiver.
                                const rt4 = funcRetTy2(m, root) orelse return no(f, "virtual return type");
                                // The dispatcher forwards what the site passes
                                // straight into the body it picks, so the site
                                // has to supply the declaration's parameters
                                // positionally. A site that omits one — a
                                // default, or a named argument the lowering
                                // reordered — needs the missing value computed
                                // HERE, before the receiver is known.
                                if (cv.n_args + 1 != root.params.len) return noCallee(f, root, "virtual call arity");
                                var kk2: u32 = 0;
                                while (kk2 < cv.n_args) : (kk2 += 1) {
                                    const ar2 = cv.args.int() + kk2;
                                    if (ar2 >= f.n_locals or !known[ar2]) return no(f, "virtual arg");
                                }
                                if (cv.dst.int() >= f.n_locals) return no(f, "virtual dst");
                                types[cv.dst.int()] = rt4;
                                if (rt4 == .object) cls[cv.dst.int()] = classIndexOfName(m, root.return_ty);
 if (refElemOf(cls[cv.dst.int()], root.return_ty)) |re_| elem[cv.dst.int()] = re_;
                    elem_cls[cv.dst.int()] = refElemCls(m, cls[cv.dst.int()], root.return_ty);
                                known[cv.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    const to = numConvVirtual(m, cv) orelse return instRefuse(f, inst);
                    if (cv.receiver.int() >= f.n_locals or !known[cv.receiver.int()]) return no(f, "conv receiver");
                    const rt3 = types[cv.receiver.int()];
                    if (!isNumericTy(rt3)) return no(f, "conv receiver type");
                    if (cv.dst.int() >= f.n_locals) return no(f, "conv dst");
                    if (rt3.isFloat() and (to == .i32 or to == .i64)) return no(f, "float to int");
                    types[cv.dst.int()] = to;
                    known[cv.dst.int()] = true;
                },
                .NewInstance => |ni| {
                    // An unsigned integer is a value class: constructing one
                    // reinterprets the same bits.
                    if (ni.class.int() < m.classes.items.len) {
                        if (unsignedTypeOf(m.classes.items[ni.class.int()].name)) |ut| {
                            if (ni.n_args != 1) return no(f, "unsigned ctor arity");
                            const ur = ni.args.int();
                            if (ur >= f.n_locals or !known[ur]) return no(f, "unsigned value");
                            if (!isNumericTy(types[ur])) return no(f, "unsigned value type");
                            if (ni.dst.int() >= f.n_locals) return no(f, "unsigned dst");
                            types[ni.dst.int()] = ut;
                            known[ni.dst.int()] = true;
                            continue;
                        }
                    }
                    if (ni.class.int() < m.classes.items.len and
                        isArrayTypeName(m.classes.items[ni.class.int()].name))
                    {
                        // `IntArray(n)` is a sized array, not an instance with
                        // fields. `IntArray(n) { i -> … }` runs a body per
                        // element, which is a loop rather than an allocation.
                        if (ni.n_args != 1 and ni.n_args != 2) return no(f, "array ctor arity");
                        const nr = ni.args.int();
                        if (nr >= f.n_locals or !known[nr]) return no(f, "array size");
                        if (types[nr] != .i32) return no(f, "array size type");
                        if (ni.n_args == 2) {
                            const lr = ni.args.int() + 1;
                            if (lr >= f.n_locals or !known[lr]) return no(f, "array initializer");
                            if (lam[lr] == null and funcClsArity(cls[lr] orelse 0) != @as(u32, 1)) {
                                return no(f, "array initializer shape");
                            }
                        }
                        if (ni.dst.int() >= f.n_locals) return no(f, "array dst");
                        types[ni.dst.int()] = .object;
                        cls[ni.dst.int()] = ARRAY_CLS;
                        elem[ni.dst.int()] = if (primArrayKind(m.classes.items[ni.class.int()].name)) |k|
                            primArrayElem(k)
                        else
                            .unit;
                        known[ni.dst.int()] = true;
                        continue;
                    }
                    if (isThrowableClass(m, ni.class.int())) {
                        if (ni.n_args > 1) return no(f, "throwable ctor arity");
                        if (ni.n_args == 1) {
                            const ar4 = ni.args.int();
                            if (ar4 >= f.n_locals or !known[ar4]) return no(f, "throwable message");
                        }
                        if (ni.dst.int() >= f.n_locals) return no(f, "throwable dst");
                        types[ni.dst.int()] = .object;
                        cls[ni.dst.int()] = THROWABLE_CLS;
                        known[ni.dst.int()] = true;
                        continue;
                    }
                    const fields = prog.of(ni.class.int()) orelse {
                        if (traceOn() and ni.class.int() < m.classes.items.len) {
                            layout_quiet = false;
                            if (try classFields(gpa, m, prog.layouts, ni.class, &prog, globals, true)) |junk| gpa.free(junk.fields);
                            layout_quiet = true;
                        }
                        return no(f, "class layout");
                    };
                    const cdef3 = &m.classes.items[ni.class.int()];
                    if (cdef3.primary_params.len < ni.n_args) return no(f, "ctor arity");
                    // A constructor takes its arguments in ITS order, whatever
                    // order the call writes them in.
                    const cb3 = bindCallArgs(m, cdef3.primary_params, ni.args.int(), ni.n_args, ni.arg_names) orelse
                        return no(f, "ctor argument binding");
                    // A parameter nothing binds runs the thunk the declaration
                    // lowered for its default.
                    var ci3: u32 = 0;
                    while (ci3 < cdef3.primary_params.len) : (ci3 += 1) {
                        if (cb3.regs[ci3] != null) continue;
                        const cdf = ctorDefault(prog.layouts, cdef3, ci3) orelse return no(f, "ctor arity");
                        const cdfn = m.funcById(cdf) orelse return no(f, "ctor default thunk");
                        if (funcRetTy2(m, cdfn) == null) return no(f, "ctor default thunk type");
                    }
                    for (fields) |fd| {
                        const ai = fd.arg orelse continue;
                        const ar = cb3.regs[ai] orelse continue;
                        if (ar >= f.n_locals or !known[ar]) return no(f, "ctor arg");
                        // A field that holds a REFERENCE takes any value: the
                        // call site boxes a machine type for it, which is what
                        // an erased type parameter needs.
                        // A narrower integer CONSTANT reaching a wider field
                        // is the same value, which is what an overload the
                        // lowering resolved to the constructor leaves behind.
                        // A negative one is not: widening it would sign-extend
                        // where the interpreter keeps the number it computed.
                        const widen_ok = isNumericTy(fd.ty) and isNumericTy(types[ar]) and
                            !fd.ty.isFloat() and !types[ar].isFloat() and
                            (if (const_at[ar]) |kv2| kv2 >= 0 else false);
                        if (types[ar] != fd.ty and fd.ty != .object and
                            !sameWidthKind(types[ar], fd.ty) and !widen_ok)
                        {
                            if (traceOn()) std.debug.print("[cgen]   field `{s}` is {s}, argument r{d} is {s}\n", .{ fd.name, @tagName(fd.ty), ar, @tagName(types[ar]) });
                            return no(f, "ctor arg type");
                        }
                        // An argument whose class is not the field's is a call
                        // to a SECONDARY constructor, which runs a body the
                        // emitter does not have. Matching arity alone made it
                        // look like the primary and stored the argument as it
                        // came.
                        if (fd.ty == .object) {
                            if (fd.cls) |want_c| {
                                const got_c = cls[ar] orelse return no(f, "ctor arg class");
                                if (got_c != want_c and !typeReaches(m, got_c, want_c)) {
                                    return no(f, "ctor arg class");
                                }
                            }
                        }
                    }
                    if (ni.dst.int() >= f.n_locals) return no(f, "ctor dst");
                    types[ni.dst.int()] = .object;
                    cls[ni.dst.int()] = ni.class.int();
                    known[ni.dst.int()] = true;
                },
                .GetField => |gf| {
                    if (gf.receiver.int() >= f.n_locals or !known[gf.receiver.int()]) return no(f, "field receiver");
                    // The lowering's sentinel for a bare name in value
                    // position: a CLASS resolves to its companion, and
                    // anything else is itself.
                    if (gf.field.int() < m.consts.items.len) {
                        const sen = m.consts.items[gf.field.int()];
                        if (sen == .String and std.mem.eql(u8, sen.String, "<class-companion-or-self>")) {
                            if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                            if (staticClassOf(types, cls, gf.receiver.int())) |scq| {
                                if (companionObjectNamed(m, prog, if (scq < m.classes.items.len) m.classes.items[scq].fqn else "")) |ccq| {
                                    types[gf.dst.int()] = .object;
                                    cls[gf.dst.int()] = ccq;
                                } else {
                                    types[gf.dst.int()] = .unit;
                                    cls[gf.dst.int()] = scq;
                                }
                            } else {
                                types[gf.dst.int()] = types[gf.receiver.int()];
                                cls[gf.dst.int()] = cls[gf.receiver.int()];
                                elem[gf.dst.int()] = elem[gf.receiver.int()];
                            }
                            known[gf.dst.int()] = true;
                            continue;
                        }
                    }
                    // A read off a class NAME whose member belongs to that
                    // class's companion: the companion answers it, so the
                    // access runs against the companion singleton.
                    var qual_recv: ?u32 = null;
                    if (staticClassOf(types, cls, gf.receiver.int())) |sc| {
                        if (gf.field.int() >= m.consts.items.len) return no(f, "field name");
                        const enm = m.consts.items[gf.field.int()];
                        if (enm != .String) return no(f, "field name kind");
                        if (numClsTy(sc)) |bt2| {
                            const bc3 = builtinConst(bt2, plainFieldName(enm.String)) orelse
                                return noName(f, "builtin constant", enm.String);
                            if (gf.dst.int() >= f.n_locals) return no(f, "constant dst");
                            types[gf.dst.int()] = bc3.ty;
                            known[gf.dst.int()] = true;
                            continue;
                        }
                        if (sc < m.classes.items.len) {
                            if (nestedClassNamed(m, qualifierOwnerFqn(m.classes.items[sc].fqn), plainFieldName(enm.String))) |nc| {
                                if (gf.dst.int() >= f.n_locals) return no(f, "qualifier dst");
                                types[gf.dst.int()] = .unit;
                                cls[gf.dst.int()] = nc;
                                known[gf.dst.int()] = true;
                                continue;
                            }
                        }
                        // `E.entries` is every entry of an enum, in
                        // declaration order, as a list.
                        if (std.mem.eql(u8, plainFieldName(enm.String), "entries") and
                            enumEntries(m, prog, sc).len != 0)
                        {
                            if (gf.dst.int() >= f.n_locals) return no(f, "entries dst");
                            types[gf.dst.int()] = .object;
                            cls[gf.dst.int()] = LIST_CLS;
                            elem_cls[gf.dst.int()] = sc;
                            known[gf.dst.int()] = true;
                            continue;
                        }
                        if (enumEntryIndex(m, prog, sc, plainFieldName(enm.String))) |_| {
                            if (gf.dst.int() >= f.n_locals) return no(f, "entry dst");
                            types[gf.dst.int()] = .object;
                            cls[gf.dst.int()] = sc;
                            known[gf.dst.int()] = true;
                            continue;
                        }
                        qual_recv = companionObjectNamed(m, prog, if (sc < m.classes.items.len) m.classes.items[sc].fqn else "") orelse {
                            if (traceOn()) {
                                std.debug.print("[cgen] refuse {s}: member `{s}` of the class `{s}`, which has no companion the program laid out\n", .{
                                    f.fqn, enm.String, if (sc < m.classes.items.len) m.classes.items[sc].fqn else "?",
                                });
                                // Say WHY the companion has no layout, which is
                                // the thing to fix.
                                var ci9: u32 = 0;
                                while (ci9 < m.classes.items.len) : (ci9 += 1) {
                                    if (!m.classes.items[ci9].is_object) continue;
                                    if (!std.mem.endsWith(u8, m.classes.items[ci9].fqn, ".Companion")) continue;
                                    const own9 = qualifierOwnerFqn(m.classes.items[ci9].fqn);
                                    if (sc >= m.classes.items.len) break;
                                    if (!std.mem.eql(u8, own9, m.classes.items[sc].fqn) and
                                        !std.mem.eql(u8, simpleName(own9), simpleName(m.classes.items[sc].fqn))) continue;
                                    layout_quiet = false;
                                    if (try classFields(gpa, m, prog.layouts, @enumFromInt(ci9), &prog, globals, true)) |j9| gpa.free(j9.fields);
                                    layout_quiet = true;
                                }
                            }
                            return null;
                        };
                    }
                    if (qual_recv == null and types[gf.receiver.int()] != .object) return no(f, "field on non-object");
                    var rc = qual_recv orelse (cls[gf.receiver.int()] orelse return no(f, "field receiver class"));
                    if (rc == STRING_CLS or rc == LIST_CLS or rc == ARRAY_CLS) {
                        const snm = m.consts.items[gf.field.int()];
                        if (snm != .String) return no(f, "builtin member name");
                        const want: []const u8 = if (rc == STRING_CLS) "length" else "size";
                        if (!std.mem.eql(u8, plainFieldName(snm.String), want)) return noName(f, "builtin member", snm.String);
                        if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                        types[gf.dst.int()] = .i32;
                        known[gf.dst.int()] = true;
                        continue;
                    }
                    // A progression answers its bounds and its step from its
                    // own record; the counted loop the lowering writes for
                    // `for (x in r)` reads exactly those three.
                    if (rc == RANGE_CLS) {
                        const pnm = m.consts.items[gf.field.int()];
                        if (pnm != .String) return no(f, "builtin member name");
                        const pn = plainFieldName(pnm.String);
                        const et = elem[gf.receiver.int()];
                        const pt: Ty = if (std.mem.eql(u8, pn, "step"))
                            (if (et == .i64 or et == .u64) Ty.i64 else Ty.i32)
                        else if (std.mem.eql(u8, pn, "first") or std.mem.eql(u8, pn, "last"))
                            (if (et == .unit) Ty.i32 else et)
                        else
                            return noName(f, "builtin member", pnm.String);
                        if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                        types[gf.dst.int()] = pt;
                        known[gf.dst.int()] = true;
                        continue;
                    }
                    if (gf.field.int() >= m.consts.items.len) return no(f, "field name");
                    const nm = m.consts.items[gf.field.int()];
                    if (nm != .String) return no(f, "field name kind");
                    // A nested class read off its outer names a type, not a
                    // value: the register is a qualifier and holds nothing.
                    if (rc < m.classes.items.len) {
                        if (nestedClassNamed(m, qualifierOwnerFqn(m.classes.items[rc].fqn), plainFieldName(nm.String))) |nc| {
                            if (gf.dst.int() >= f.n_locals) return no(f, "qualifier dst");
                            types[gf.dst.int()] = .unit;
                            cls[gf.dst.int()] = nc;
                            known[gf.dst.int()] = true;
                            continue;
                        }
                    }
                    if (qual_recv == null) {
                        if (accessOwner(m, prog, rc, nm.String, false)) |cc| {
                            rc = cc;
                            qual_recv = cc;
                        }
                    }
                    switch (accessPlan(m, prog, rc, nm.String, false)) {
                        .none => {
                            // Name why the class has no layout, when that is
                            // the reason the field is not there.
                            if (traceOn() and prog.of(rc) == null and rc < m.classes.items.len) {
                                layout_quiet = false;
                                if (try classFields(gpa, m, prog.layouts, @enumFromInt(rc), &prog, globals, true)) |junk2| {
                                    gpa.free(junk2.fields);
                                }
                                layout_quiet = true;
                            }
                            return noName(f, "field not laid out", nm.String);
                        },
                        .virtual => {
                            const vp = virtualProp(m, prog, rc, plainFieldName(nm.String)).?;
                            if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                            types[gf.dst.int()] = vp.ret;
                            cls[gf.dst.int()] = vp.cls;
                            elem[gf.dst.int()] = vp.elem;
                            known[gf.dst.int()] = true;
                            continue;
                        },
                        .accessor => |g| {
                            const gfn = m.funcById(g) orelse return no(f, "getter body");
                            const gt = funcRetTy2(m, gfn) orelse return no(f, "getter return type");
                            if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                            types[gf.dst.int()] = gt;
                            if (gt == .object) {
                                cls[gf.dst.int()] = classIndexOfName(m, gfn.return_ty);
                                if (refElemOf(cls[gf.dst.int()], gfn.return_ty)) |re_| elem[gf.dst.int()] = re_;
                    elem_cls[gf.dst.int()] = refElemCls(m, cls[gf.dst.int()], gfn.return_ty);
                            }
                            known[gf.dst.int()] = true;
                            continue;
                        },
                        .field => |idx| {
                            const fields = prog.of(rc).?;
                            if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                            types[gf.dst.int()] = fields[idx].ty;
                            cls[gf.dst.int()] = fields[idx].cls;
                            elem[gf.dst.int()] = fields[idx].elem;
                            known[gf.dst.int()] = true;
                        },
                    }
                },
                .SetField => |sf| {
                    if (sf.receiver.int() >= f.n_locals or !known[sf.receiver.int()]) return no(f, "field receiver");
                    if (types[sf.receiver.int()] != .object) return no(f, "field on non-object");
                    const rc = cls[sf.receiver.int()] orelse return no(f, "field receiver class");
                    if (sf.field.int() >= m.consts.items.len) return no(f, "field name");
                    const nm = m.consts.items[sf.field.int()];
                    if (nm != .String) return no(f, "field name kind");
                    switch (accessPlan(m, prog, rc, nm.String, true)) {
                        .none, .virtual => return noName(f, "field not laid out", nm.String),
                        .accessor => |st| {
                            const sfn = m.funcById(st) orelse return no(f, "setter body");
                            if (sf.value.int() >= f.n_locals or !known[sf.value.int()]) return no(f, "field value");
                            // The setter's own parameter decides what it takes.
                            const want: Ty = if (sfn.params.len >= 2)
                                (tyOf(sfn.params[1].ty) orelse .object)
                            else
                                return no(f, "setter arity");
                            if (want != .object and types[sf.value.int()] != want) return no(f, "setter value type");
                        },
                        .field => |idx| {
                            const fields = prog.of(rc).?;
                            if (sf.value.int() >= f.n_locals or !known[sf.value.int()]) return no(f, "field value");
                            if (types[sf.value.int()] != fields[idx].ty) return no(f, "field value type");
                        },
                    }
                },
                .LoadGlobal => |lg| {
                    if (lg.name.int() >= m.consts.items.len) return no(f, "global name");
                    const gn = m.consts.items[lg.name.int()];
                    if (gn != .String) return no(f, "global name kind");
                    if (objectClassNamed(m, prog, gn.String) orelse
                        companionObjectNamed(m, prog, gn.String)) |oc|
                    {
                        if (lg.dst.int() >= f.n_locals) return no(f, "singleton dst");
                        types[lg.dst.int()] = .object;
                        cls[lg.dst.int()] = oc;
                        known[lg.dst.int()] = true;
                        continue;
                    }
                    // A builtin type's name is a qualifier too: `Int` in
                    // `Int.MAX_VALUE` names the type, and the constant read
                    // off it is the language's own number.
                    if (builtinQualifier(gn.String)) |bt| {
                        if (globalIndex(globals, gn.String) == null) {
                            if (lg.dst.int() >= f.n_locals) return no(f, "qualifier dst");
                            types[lg.dst.int()] = .unit;
                            cls[lg.dst.int()] = numCls(bt);
                            known[lg.dst.int()] = true;
                            continue;
                        }
                    }
                    // An enum's own name is a qualifier: it carries no value,
                    // and the member read off it resolves at emit time.
                    if (enumClassNamed(m, prog, gn.String)) |ec| {
                        if (lg.dst.int() >= f.n_locals) return no(f, "qualifier dst");
                        types[lg.dst.int()] = .unit;
                        cls[lg.dst.int()] = ec;
                        known[lg.dst.int()] = true;
                        continue;
                    }
                    // Any other class name is a qualifier too: `Outer` in
                    // `Outer.Section` names the type the nested name is read
                    // off. A global of the same name is a value and wins.
                    if (globalIndex(globals, gn.String) == null) {
                        if (classQualifierNamed(m, gn.String)) |qc| {
                            if (lg.dst.int() >= f.n_locals) return no(f, "qualifier dst");
                            types[lg.dst.int()] = .unit;
                            cls[lg.dst.int()] = qc;
                            known[lg.dst.int()] = true;
                            continue;
                        }
                    }
                    if (globalIndex(globals, gn.String) == null) {
                        // A function's NAME in value position is the function
                        // itself: a callable with no captures, which is the
                        // same shape a lambda that captures nothing takes.
                        if (topLevelFuncNamed(m, gn.String)) |rf| {
                            if (rf.params.len <= FUNC_MAX_ARITY) {
                                if (lg.dst.int() >= f.n_locals) return no(f, "callable dst");
                                types[lg.dst.int()] = .object;
                                cls[lg.dst.int()] = funcCls(@intCast(rf.params.len));
                                elem[lg.dst.int()] = funcRetTy2(m, rf) orelse .object;
                                lam[lg.dst.int()] = .{ .body = rf.id, .captures = &.{} };
                                known[lg.dst.int()] = true;
                                continue;
                            }
                        }
                    }
                    const gi = globalIndex(globals, gn.String) orelse return noName(f, "global not declared", gn.String);
                    if (lg.dst.int() >= f.n_locals) return no(f, "global dst");
                    const gt = (try globalTy(gpa, m, prog, globals, gi)) orelse return no(f, "global type");
                    types[lg.dst.int()] = gt;
                    if (gt == .object) {
                        const gf = m.funcById(globals[gi].func).?;
                        cls[lg.dst.int()] = classIndexOfName(m, gf.return_ty);
                        if (refElemOf(cls[lg.dst.int()], gf.return_ty)) |re_| elem[lg.dst.int()] = re_;
                    elem_cls[lg.dst.int()] = refElemCls(m, cls[lg.dst.int()], gf.return_ty);
                    }
                    known[lg.dst.int()] = true;
                },
                .StoreGlobal => |sg| {
                    if (sg.name.int() >= m.consts.items.len) return no(f, "global name");
                    const gn = m.consts.items[sg.name.int()];
                    if (gn != .String) return no(f, "global name kind");
                    const gi = globalIndex(globals, gn.String) orelse return noName(f, "global not declared", gn.String);
                    if (sg.value.int() >= f.n_locals or !known[sg.value.int()]) return no(f, "global value");
                    const gt = (try globalTy(gpa, m, prog, globals, gi)) orelse return no(f, "global type");
                    if (types[sg.value.int()] != gt) {
                        if (traceOn()) std.debug.print("[cgen]   global `{s}` is {s}, stored value is {s}\n", .{ gn.String, @tagName(gt), @tagName(types[sg.value.int()]) });
                        return no(f, "global value type");
                    }
                },
                .AstLambda => |al| {
                    const body = al.body_func orelse return no(f, "lambda without a lowered body");
                    if (al.dst.int() >= f.n_locals) return no(f, "lambda dst");
                    for (al.captures) |cr| {
                        if (cr.int() >= f.n_locals or !known[cr.int()]) return no(f, "lambda capture");
                    }
                    lam[al.dst.int()] = .{ .body = body, .captures = al.captures };
                    known[al.dst.int()] = true;
                    if (!lambdaEscapes(m, f, al.dst)) {
                        // Never materialised: every use is a direct call, so
                        // the call site passes the captures itself.
                        types[al.dst.int()] = .unit;
                        continue;
                    }
                    // The value has to exist. It becomes an instance of a
                    // class the emitter synthesizes for this body, one field
                    // per capture, which is what lets the collector trace it
                    // and a call through it find the body again.
                    const bfn = m.funcById(body) orelse return no(f, "lambda body missing");
                    const arity = bfn.params.len;
                    if (arity > FUNC_MAX_ARITY) return no(f, "lambda arity");
                    const ct5 = try gpa.alloc(CapInfo, al.captures.len);
                    defer gpa.free(ct5);
                    for (al.captures, 0..) |cr5, ci6| ct5[ci6] = .{ .ty = types[cr5.int()], .cls = cls[cr5.int()], .elem = elem[cr5.int()] };
                    const fnty = expectedFnType(m, f, al.dst);
                    const lsynth = if (fnty) |t5| try lambdaParams(gpa, bfn, t5) else null;
                    defer if (lsynth) |ls5| gpa.free(ls5);
                    var lc = (try eligible(gpa, m, prog, bfn, globals, lsynth, ct5)) orelse return no(f, "lambda body");
                    const lret = lc.ret;
                    lc.deinit(gpa);
                    types[al.dst.int()] = .object;
                    cls[al.dst.int()] = funcCls(@intCast(arity));
                    elem[al.dst.int()] = lret;
                },
                // A bare call whose name is both a callable in scope and
                // possibly a member of the receiver. When the local is a
                // function value the local wins, which is what the interpreter
                // decides at run time by finding it first.
                .CallValueOrMember => |cvm| {
                    if (cvm.arg_names.len != 0) return no(f, "value call names");
                    if (cvm.callee.int() >= f.n_locals or !known[cvm.callee.int()]) return no(f, "value callee");
                    if (types[cvm.callee.int()] != .object) return instRefuse(f, inst);
                    const fc2 = cls[cvm.callee.int()] orelse return instRefuse(f, inst);
                    const ar7 = funcClsArity(fc2) orelse return instRefuse(f, inst);
                    if (cvm.n_args != ar7) return no(f, "value call arity");
                    var kk8: u32 = 0;
                    while (kk8 < cvm.n_args) : (kk8 += 1) {
                        const a8 = cvm.args.int() + kk8;
                        if (a8 >= f.n_locals or !known[a8]) return no(f, "value call arg");
                    }
                    if (cvm.dst.int() >= f.n_locals) return no(f, "value call dst");
                    types[cvm.dst.int()] = elem[cvm.callee.int()];
                    known[cvm.dst.int()] = true;
                },
                .CallValue => |cv2| {
                    if (cv2.arg_names.len != 0 or cv2.type_args.len != 0) return no(f, "value call names/type args");
                    if (cv2.callee.int() >= f.n_locals) return no(f, "value callee");
                    if (types[cv2.callee.int()] == .object) {
                        // A call through a function VALUE: the body is decided
                        // at run time by which closure the value is, so the
                        // arguments and the result pass boxed.
                        const fc = cls[cv2.callee.int()] orelse return no(f, "value callee class");
                        const ar6 = funcClsArity(fc) orelse return no(f, "value callee is not callable");
                        if (cv2.n_args != ar6) return no(f, "value call arity");
                        var kk6: u32 = 0;
                        while (kk6 < cv2.n_args) : (kk6 += 1) {
                            const a6 = cv2.args.int() + kk6;
                            if (a6 >= f.n_locals or !known[a6]) return no(f, "value call arg");
                        }
                        if (cv2.dst.int() >= f.n_locals) return no(f, "value call dst");
                        types[cv2.dst.int()] = elem[cv2.callee.int()];
                        known[cv2.dst.int()] = true;
                        continue;
                    }
                    const li = lam[cv2.callee.int()] orelse return no(f, "value call to an unknown callee");
                    const bf = m.funcById(li.body) orelse return no(f, "lambda body missing");
                    // The lowering always gives a lambda an `it` slot, so a
                    // zero-argument call leaves one parameter unsupplied. It is
                    // unreachable in a lambda that declares none, and gets the
                    // type's zero.
                    if (cv2.n_args > bf.params.len) return no(f, "lambda arity");
                    var kk3: u32 = 0;
                    while (kk3 < cv2.n_args) : (kk3 += 1) {
                        const ar3 = cv2.args.int() + kk3;
                        if (ar3 >= f.n_locals or !known[ar3]) return no(f, "lambda arg");
                    }
                    if (cv2.dst.int() >= f.n_locals) return no(f, "lambda dst");
                    // A lambda declares no return type, so the answer is what
                    // its body compiles to — with the captures it was made
                    // with, since those are part of its signature here.
                    const ct2 = try gpa.alloc(CapInfo, li.captures.len);
                    defer gpa.free(ct2);
                    for (li.captures, 0..) |cr2, ci5| ct2[ci5] = .{ .ty = types[cr2.int()], .cls = cls[cr2.int()], .elem = elem[cr2.int()] };
                    var bc = (try eligible(gpa, m, prog, bf, globals, null, ct2)) orelse return no(f, "lambda body");
                    const rt7 = bc.ret;
                    bc.deinit(gpa);
                    types[cv2.dst.int()] = rt7;
                    if (rt7 == .object) cls[cv2.dst.int()] = classIndexOfName(m, bf.return_ty);
 if (refElemOf(cls[cv2.dst.int()], bf.return_ty)) |re_| elem[cv2.dst.int()] = re_;
                    elem_cls[cv2.dst.int()] = refElemCls(m, cls[cv2.dst.int()], bf.return_ty);
                    known[cv2.dst.int()] = true;
                },
                .Call => |c| {
                    // Type arguments say nothing about which body runs for a
                    // call the lowering already resolved.
                    if (c.dst.int() >= f.n_locals) return null;
                    const callee = m.funcById(c.func) orelse return no(f, "call target missing");
                    if (isLaunch(callee)) {
                        if (c.n_args < 1) return no(f, "launch arity");
                        const lr5 = c.args.int() + c.n_args - 1;
                        if (lr5 >= f.n_locals or !known[lr5]) return no(f, "launch block");
                        if (types[lr5] != .object) return no(f, "launch block is not a value");
                        if (c.dst.int() >= f.n_locals) return no(f, "launch dst");
                        types[c.dst.int()] = .object;
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (isRunBlocking(callee)) {
                        // The block is the root coroutine. It has to be a
                        // lambda whose body this program compiled: the driver
                        // resumes it by calling it.
                        if (c.n_args < 1) return no(f, "runBlocking arity");
                        const br = c.args.int() + c.n_args - 1;
                        if (br >= f.n_locals or !known[br]) return no(f, "runBlocking block");
                        const li3 = lam[br] orelse return no(f, "runBlocking block is not a lambda");
                        const bfn3 = m.funcById(li3.body) orelse return no(f, "runBlocking block body");
                        if (!bodySuspends(m, bfn3)) return no(f, "runBlocking block is not suspending");
                        if (c.dst.int() >= f.n_locals) return no(f, "runBlocking dst");
                        types[c.dst.int()] = .object;
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (isArrayOfNulls(callee)) {
                        const nr3 = c.args.int();
                        if (c.n_args != 1 or nr3 >= f.n_locals or !known[nr3]) return no(f, "array size");
                        if (types[nr3] != .i32) return no(f, "array size type");
                        if (c.dst.int() >= f.n_locals) return no(f, "array dst");
                        types[c.dst.int()] = .object;
                        cls[c.dst.int()] = ARRAY_CLS;
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (arrayOfIntrinsic(callee)) |maybe_kind| {
                        const aa2 = c.args.int();
                        var ka2: u32 = 0;
                        while (ka2 < c.n_args) : (ka2 += 1) {
                            if (aa2 + ka2 >= f.n_locals or !known[aa2 + ka2]) return no(f, "array arg");
                        }
                        if (c.dst.int() >= f.n_locals) return no(f, "array dst");
                        types[c.dst.int()] = .object;
                        cls[c.dst.int()] = ARRAY_CLS;
                        if (maybe_kind) |k2| {
                            const et2 = primArrayElem(k2);
                            var ka3: u32 = 0;
                            while (ka3 < c.n_args) : (ka3 += 1) {
                                if (types[aa2 + ka3] != et2) return no(f, "array element type");
                            }
                            elem[c.dst.int()] = et2;
                        }
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (listIntrinsic(callee)) |_| {
                        var et: ?Ty = null;
                        var k: u32 = 0;
                        while (k < c.n_args) : (k += 1) {
                            const ar = c.args.int() + k;
                            if (ar >= f.n_locals or !known[ar]) return no(f, "list element");
                            if (k == 0) et = types[ar] else if (et.? != types[ar]) et = null;
                            if (et == null) break;
                        }
                        if (c.dst.int() >= f.n_locals) return no(f, "list dst");
                        types[c.dst.int()] = .object;
                        cls[c.dst.int()] = LIST_CLS;
                        elem[c.dst.int()] = if (et) |t| (if (t == .object) .unit else t) else .unit;
                        if (elem[c.dst.int()] == .unit) {
                            elem_cls[c.dst.int()] = commonCls(m, cls, c.args.int(), c.n_args);
                        }
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (scalarIntrinsic(callee)) |si| {
                        const sa = c.args.int();
                        var ks: u32 = 0;
                        while (ks < c.n_args) : (ks += 1) {
                            if (sa + ks >= f.n_locals or !known[sa + ks]) return no(f, "intrinsic arg");
                        }
                        if (c.dst.int() >= f.n_locals) return no(f, "intrinsic dst");
                        switch (si) {
                            .print => {
                                if (c.n_args != 1) return no(f, "print arity");
                                if (types[sa] == .unit) return no(f, "print of Unit");
                                types[c.dst.int()] = .unit;
                            },
                            // The floating forms differ from C's: Kotlin's
                            // `max` propagates NaN and orders -0.0 below 0.0,
                            // where `fmax` does neither.
                            .max, .min => {
                                if (c.n_args != 2) return no(f, "intrinsic arity");
                                if (types[sa] != types[sa + 1]) return no(f, "intrinsic operand types");
                                if (types[sa] != .i32 and types[sa] != .i64) return no(f, "intrinsic operand type");
                                types[c.dst.int()] = types[sa];
                            },
                            .abs => {
                                if (c.n_args != 1) return no(f, "intrinsic arity");
                                if (types[sa] != .i32 and types[sa] != .i64) return no(f, "intrinsic operand type");
                                types[c.dst.int()] = types[sa];
                            },
                        }
                        known[c.dst.int()] = true;
                        continue;
                    }
                    if (isPrintln(callee)) {
                        if (c.n_args != 1) return no(f, "println arity");
                        const a0 = c.args.int();
                        if (a0 >= f.n_locals or !known[a0]) return no(f, "println arg");
                        if (types[a0] == .unit) return no(f, "println of Unit");
                        types[c.dst.int()] = .unit;
                        known[c.dst.int()] = true;
                    } else if (isDelay(callee)) {
                        if (c.n_args < 1) return no(f, "delay arity");
                        const mr = c.args.int();
                        if (mr >= f.n_locals or !known[mr]) return no(f, "delay argument");
                        if (types[mr] != .i32 and types[mr] != .i64) return no(f, "delay argument type");
                        if (c.dst.int() >= f.n_locals) return no(f, "delay dst");
                        types[c.dst.int()] = .unit;
                        known[c.dst.int()] = true;
                    } else {
                        if (!callee.hasBody()) {
                            // No Kotlin body, but the interpreter implements
                            // it: compiled code runs the same entry.
                            if (stdlibEntry(callee) != null) {
                                var ks9: u32 = 0;
                                while (ks9 < c.n_args) : (ks9 += 1) {
                                    const a9 = c.args.int() + ks9;
                                    if (a9 >= f.n_locals or !known[a9]) return no(f, "stdlib arg");
                                }
                                if (c.dst.int() >= f.n_locals) return no(f, "stdlib dst");
                                // The table answers a value; the DECLARATION
                                // says what kind, so a result that is a machine
                                // type comes back as one rather than staying
                                // boxed and refusing the next `+`.
                                const srt = tyOf(callee.return_ty) orelse Ty.object;
                                types[c.dst.int()] = srt;
                                if (srt == .object) {
                                    cls[c.dst.int()] = classIndexOfName(m, callee.return_ty);
                                    if (refElemOf(cls[c.dst.int()], callee.return_ty)) |re11| elem[c.dst.int()] = re11;
                    elem_cls[c.dst.int()] = refElemCls(m, cls[c.dst.int()], callee.return_ty);
                                }
                                known[c.dst.int()] = true;
                                continue;
                            }
                            return noCallee(f, callee, "no body for");
                        }
                        // A name several declarations answer, which these
                        // arguments do not separate, is decided from the
                        // VALUES at run time; the lowering's pick is one
                        // candidate, not the answer.
                        if (!callee.has_receiver_param and
                            ambiguousOverload(m, prog, callee.name, types, c.args.int(), c.n_args, c.arg_names))
                        {
                            return noCallee(f, callee, "overload of");
                        }
                        const has_vararg = for (callee.params) |p| {
                            if (p.is_vararg) break true;
                        } else false;
                        if (callee.params.len < c.n_args and !has_vararg) return noCallee(f, callee, "arity of");
                        const bnd = bindCallArgs(m, callee.params, c.args.int(), c.n_args, c.arg_names) orelse
                            return noCallee(f, callee, "argument binding of");
                        // A parameter nothing binds is filled by the thunk the
                        // declaration lowered for it, run with the arguments
                        // ahead of it.
                        // A parameter declared as a class the emitter lays
                        // out cannot take a RUNTIME value: a body that reads
                        // its fields would address a list, a range or a string
                        // as though it were an instance.
                        var ai9: u32 = 0;
                        while (ai9 < bnd.n) : (ai9 += 1) {
                            const areg9 = bnd.regs[ai9] orelse continue;
                            if (types[areg9] != .object) continue;
                            const got9 = cls[areg9] orelse continue;
                            if (!isBuiltinCls(got9)) continue;
                            const want9 = classIndexOfName(m, callee.params[ai9].ty) orelse continue;
                            if (isBuiltinCls(want9)) continue;
                            const wf9 = prog.of(want9) orelse continue;
                            // A supertype with no storage — `Any`, an
                            // interface — is satisfied by a runtime value; one
                            // with fields is not, and a body reading them would
                            // address a list or a range as an instance.
                            if (wf9.len == 0) continue;
                            return noCallee(f, callee, "a runtime value where an instance is declared by");
                        }
                        var di: u32 = 0;
                        while (di < bnd.n) : (di += 1) {
                            if (bnd.regs[di] != null) continue;
                            // A `vararg` nothing filled is the empty array, not
                            // a missing argument.
                            if (bnd.vararg_param != null and bnd.vararg_param.? == di) continue;
                            const dfid = prog.defaultThunk(callee.id, di) orelse return noCallee(f, callee, "arity of");
                            const dfn = m.funcById(dfid) orelse return no(f, "default thunk");
                            if (funcRetTy2(m, dfn) == null) return no(f, "default thunk type");
                        }
                        const rt = funcRetTy2(m, callee) orelse return no(f, "callee return type");
                        types[c.dst.int()] = rt;
                        if (rt == .object) cls[c.dst.int()] = callResultCls(m, callee);
 if (refElemOf(cls[c.dst.int()], callee.return_ty)) |re_| elem[c.dst.int()] = re_;
                    elem_cls[c.dst.int()] = refElemCls(m, cls[c.dst.int()], callee.return_ty);
                        known[c.dst.int()] = true;
                    }
                    var k: u32 = 0;
                    while (k < c.n_args) : (k += 1) {
                        const ar = c.args.int() + k;
                        if (ar >= f.n_locals or !known[ar]) return null;
                    }
                },
                else => return instRefuse(f, inst),
            }
        }
        switch (blk.terminator) {
            .Goto => {},
            .Branch => |br| {
                if (br.cond.int() >= f.n_locals or !known[br.cond.int()]) return null;
            },
            .Return => |r| {
                if (r) |rr| {
                    if (rr.int() >= f.n_locals or !known[rr.int()]) return no(f, "return value");
                }
            },
            // A block carrying a catch handler is refused above, so a program
            // that compiles has no handler anywhere and a throw always leaves
            // it. That is what makes an uncaught throw the whole story here.
            .Throw => |t| {
                if (t.int() >= f.n_locals or !known[t.int()]) return no(f, "throw value");
            },
            else => return no(f, "terminator"),
        }
    }
    // Resolve the result from the returned registers, which the body pass has
    // now typed. Disagreeing returns mean the emitter cannot name one C type.
    var saw_ret = false;
    var ret_cls: ?u32 = null;
    var ret_elem: Ty = .unit;
    // Only the blocks the body can reach: an unreachable one was never typed,
    // and its terminator names a register nothing defined.
    const live_ret = try gpa.alloc(bool, f.blocks.len);
    defer gpa.free(live_ret);
    @memset(live_ret, false);
    for (order) |bi| live_ret[bi] = true;
    for (f.blocks, 0..) |*blk, bi2| {
        if (!live_ret[bi2]) continue;
        if (blk.terminator != .Return) continue;
        const rr = blk.terminator.Return orelse continue;
        if (rr.int() >= f.n_locals or !known[rr.int()]) return no(f, "return register");
        if (!saw_ret) {
            ret = types[rr.int()];
            ret_cls = cls[rr.int()];
            ret_elem = elem[rr.int()];
            saw_ret = true;
        } else if (ret != types[rr.int()]) return no(f, "returns differ");
    }
    if (!saw_ret) ret = .unit;

    var n_slots: u32 = 0;
    var r: u32 = 0;
    while (r < f.n_locals) : (r += 1) {
        if (types[r] != .object) continue;
        slot[r] = @intCast(n_slots);
        n_slots += 1;
    }
    return .{ .f = f, .caps = caps, .params = params, .types = types, .cls = cls, .elem = elem, .elem_cls = elem_cls, .lam = lam, .slot = slot, .n_slots = n_slots, .ret = ret, .ret_cls = ret_cls, .ret_elem = ret_elem, .suspends = suspends, .bare = bare };
}

/// A C identifier for the function. Derived from the fqn, never from the id:
/// ids are not stable across bakes, and a name that moves between builds would
/// silently link the wrong body.
/// A name as a C identifier fragment: the same escaping `writeSymbol` uses,
/// so two names that differ anywhere differ here too.
fn mangleName(name: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            if (n + 1 > buf.len) break;
            buf[n] = ch;
            n += 1;
        } else {
            if (n + 3 > buf.len) break;
            _ = std.fmt.bufPrint(buf[n..], "_{x:0>2}", .{ch}) catch break;
            n += 3;
        }
    }
    return buf[0..n];
}

fn writeSymbol(w: *std.Io.Writer, f: *const Func) !void {
    try w.writeAll("kc_");
    for (f.fqn) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try w.writeByte(ch);
        } else {
            try w.print("_{x:0>2}", .{ch});
        }
    }
    // The fqn alone is not unique: every lambda is named `<lambda>`. The id
    // distinguishes them, and only has to hold within this one file.
    try w.print("_{d}", .{f.id.int()});
}

/// A scalar as a `klio_value`, for the moment it crosses into the object world.
/// A class's own constructor parameter types, as the emitted initializer
/// declares them.
fn ctorParamTy(c: *const ir.Class, i: usize) Ty {
    return tyOf(c.primary_params[i].ty) orelse .object;
}

/// The thunk that fills a primary-constructor parameter a construction omits.
fn ctorDefault(layouts: []const ClassLayout, c: *const ir.Class, idx: usize) ?ir.FuncId {
    const l = layoutFor(layouts, c) orelse return null;
    if (idx >= l.ctor_defaults.len) return null;
    return l.ctor_defaults[idx];
}

/// The declarations a class contributes itself: its body properties in source
/// order and the init blocks between them. The table is keyed by whatever name
/// the built module used — the FQN for a class in a package, the simple name
/// for one without — so a lookup has to accept either.
fn ownLayout(prog: Program, name: []const u8) ?*const ClassLayout {
    for (prog.layouts) |*l| {
        if (std.mem.eql(u8, l.name, name)) return l;
    }
    return null;
}

fn layoutFor(layouts: []const ClassLayout, c: *const ir.Class) ?*const ClassLayout {
    for (layouts) |*l| {
        if (std.mem.eql(u8, l.name, c.name) or std.mem.eql(u8, l.name, c.fqn)) return l;
    }
    return null;
}

/// The prototype of a class's initializer. It fills an instance the caller has
/// already allocated, which is what lets a subclass hand its own instance to
/// the superclass's initializer rather than building a second one.
fn writeCtorProto(w: *std.Io.Writer, m: *const Module, cid: u32) !void {
    const c = &m.classes.items[cid];
    try w.print("static void kinit_{d}(klio_value self", .{cid});
    for (c.primary_params, 0..) |_, i| {
        try w.print(", {s} p{d}", .{ ctorParamTy(c, i).cName(), i });
    }
    try w.writeAll(")");
}

/// One call to a thunk the class table carries: a superclass-argument thunk
/// reads the constructor's parameters, a body-property thunk reads the
/// instance and then the parameters.
fn writeThunkCall(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    c: *const ir.Class,
    ifn: *const Func,
) !void {
    var sym: std.Io.Writer.Allocating = .init(gpa);
    defer sym.deinit();
    try writeSymbol(&sym.writer, ifn);
    try out.print("{s}(", .{sym.written()});
    var first = true;
    if (ifn.has_receiver_param) {
        try out.writeAll("self");
        first = false;
    }
    for (c.primary_params, 0..) |_, i| {
        if (!first) try out.writeAll(", ");
        first = false;
        const have = ctorParamTy(c, i);
        const pidx = i + @as(usize, if (ifn.has_receiver_param) 1 else 0);
        // The thunk's own signature decides: a parameter it declares as a
        // reference arrives boxed, whatever the constructor holds.
        const want: Ty = if (pidx < ifn.params.len) (tyOf(ifn.params[pidx].ty) orelse .object) else have;
        var nb: [16]u8 = undefined;
        const arg = std.fmt.bufPrint(&nb, "p{d}", .{i}) catch unreachable;
        var bx: [64]u8 = undefined;
        if (want == .object and have != .object) {
            try out.print("{s}", .{boxExpr(have, arg, &bx)});
        } else {
            try out.print("{s}", .{arg});
        }
    }
    try out.writeAll(")");
}

/// A class's initializer: the superclass's fields first, through its own
/// initializer, then the fields this class declares.
fn writeCtorBody(
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    m: *const Module,
    prog: Program,
    cid: u32,
) !void {
    const c = &m.classes.items[cid];
    const fields = prog.of(cid).?;
    try writeCtorProto(w, m, cid);
    try w.writeAll(" {\n");
    // A class whose fields are all filled elsewhere (an enum, whose entries
    // carry their own name and position) uses none of its arguments.
    try w.writeAll("  (void)self;");
    for (c.primary_params, 0..) |_, vi| try w.print("  (void)p{d};", .{vi});
    try w.writeAll("\n");
    if (prog.parentOf(cid)) |pp| {
        const sup = &m.classes.items[pp.cid];
        try w.print("  kinit_{d}(self", .{pp.cid});
        for (pp.args, 0..) |tf, i| {
            try w.writeAll(", ");
            const ifn = m.funcById(tf).?;
            var call: std.Io.Writer.Allocating = .init(gpa);
            defer call.deinit();
            try writeThunkCall(gpa, &call.writer, c, ifn);
            const want = ctorParamTy(sup, i);
            const have = funcRetTy2(m, ifn) orelse want;
            var bx: [320]u8 = undefined;
            if (want == .object and have != .object) {
                try w.print("{s}", .{boxExpr(have, call.written(), &bx)});
            } else {
                try w.print("{s}", .{call.written()});
            }
        }
        try w.writeAll(");\n");
    }
    // The class's own declarations run in SOURCE order: an init block sits
    // between the body properties it was written between, and Kotlin's rule is
    // that each one sees the properties declared above it and the zeros of
    // those below.
    const own = ownLayout(prog, c.name);
    const n_props: usize = if (own) |o| o.props.len else 0;
    var prop_i: usize = 0;
    var field_i: usize = 0;
    // The constructor's own properties are filled before any of it runs.
    for (fields, 0..) |fd, fi| {
        if (fd.from_parent or fd.preset) continue;
        const ai = fd.arg orelse continue;
        var bb0: [400]u8 = undefined;
        var nb0: [16]u8 = undefined;
        const arg0 = std.fmt.bufPrint(&nb0, "p{d}", .{ai}) catch unreachable;
        try w.print("  klio_nat_set(self, {d}, {s});\n", .{ fi, boxExpr(fd.ty, arg0, &bb0) });
        field_i = fi + 1;
    }
    while (prop_i <= n_props) : (prop_i += 1) {
        if (own) |o| {
            for (o.init_blocks, 0..) |ibf, ib_i| {
                const at: usize = if (ib_i < o.init_block_positions.len) o.init_block_positions[ib_i] else n_props;
                if (at != prop_i) continue;
                const ibn = m.funcById(ibf) orelse continue;
                var icall: std.Io.Writer.Allocating = .init(gpa);
                defer icall.deinit();
                try writeThunkCall(gpa, &icall.writer, c, ibn);
                try w.print("  {s};\n", .{icall.written()});
            }
        }
        if (prop_i == n_props) break;
        // The field this declaration contributes, when it has one.
        const want_name = if (own) |o| o.props[prop_i].name else "";
        var fi2: ?usize = null;
        for (fields, 0..) |fd2, k| {
            if (fd2.from_parent or fd2.preset or fd2.arg != null) continue;
            if (!std.mem.eql(u8, fd2.name, want_name)) continue;
            fi2 = k;
        }
        const fi3 = fi2 orelse continue;
        const fd = fields[fi3];
        var bb: [400]u8 = undefined;
        const ifid = fd.init orelse {
            // A declared non-nullable primitive with no initializer starts at
            // its type's zero, which is what the interpreter stores.
            const z = if (fd.ty == .object) "klio_nat_null()" else boxExpr(fd.ty, "0", &bb);
            try w.print("  klio_nat_set(self, {d}, {s});\n", .{ fi3, z });
            continue;
        };
        const ifn = m.funcById(ifid).?;
        var call: std.Io.Writer.Allocating = .init(gpa);
        defer call.deinit();
        try writeThunkCall(gpa, &call.writer, c, ifn);
        try w.print("  klio_nat_set(self, {d}, {s});\n", .{ fi3, boxExpr(fd.ty, call.written(), &bb) });
    }
    try w.writeAll("}\n");
}

/// A register as a `klio_value` ready to be rendered: a value whose class
/// declares `toString` renders as what that returns, which is what Kotlin
/// means by printing it.
fn renderExpr(
    gpa: std.mem.Allocator,
    m: *const Module,
    prog: Program,
    c: *const Compiled,
    reg: u32,
    out: *std.Io.Writer.Allocating,
) !void {
    var rb: [32]u8 = undefined;
    const name = regName(c, reg, &rb);
    if (c.types[reg] == .object) {
        if (c.cls[reg]) |rc| {
            if (toStringOf(m, prog, rc)) |ts| {
                try out.writer.print("kvirt_{d}({s})", .{ ts.id.int(), name });
                return;
            }
        }
    }
    var bb: [96]u8 = undefined;
    try out.writer.print("{s}", .{boxExpr(c.types[reg], name, &bb)});
    _ = gpa;
}

/// The runtime entry that boxes a machine type, or an empty name when the
/// value is already a reference.
/// A field's declared type as the runtime's zero-kind byte.
fn zeroKindOf(t: Ty) u8 {
    return switch (t) {
        .object, .unit => 0,
        .i32 => 1,
        .i64 => 2,
        .f64 => 3,
        .f32 => 4,
        .boolean => 5,
        .char => 6,
        .short => 7,
        .byte => 8,
        .u32 => 9,
        .u64 => 10,
        .u16 => 11,
        .u8 => 12,
    };
}

fn boxFnName(t: Ty) []const u8 {
    return switch (t) {
        .i32 => "klio_nat_box_int",
        .i64 => "klio_nat_box_long",
        .f64 => "klio_nat_box_double",
        .f32 => "klio_nat_box_float",
        .boolean => "klio_nat_box_bool",
        .char => "klio_nat_box_char",
        .short => "klio_nat_box_short",
        .byte => "klio_nat_box_byte",
        .u32 => "klio_nat_box_uint",
        .u64 => "klio_nat_box_ulong",
        .u16 => "klio_nat_box_ushort",
        .u8 => "klio_nat_box_ubyte",
        .unit, .object => "",
    };
}

/// The compiled parameter type of an accepted body, which is what its C
/// signature declares. A synthesized thunk and a lambda compile against a
/// signature the emitter chose, so the declaration is not the authority.
fn acceptedParamTy(accepted: []const Compiled, f: *const Func, idx: usize) ?Ty {
    for (accepted) |*cc| {
        if (cc.f != f) continue;
        if (idx >= cc.params.len) return null;
        return paramTy(cc.params[idx]);
    }
    return null;
}

/// An expression of type `have` as the C type `want` needs it: a machine type
/// boxed into a reference, a reference unboxed into a machine type. The
/// lowering reuses one register for values of both shapes, and the register's
/// own type is what its C local declares, so the conversion belongs at the
/// point of use.
fn convExpr(have: Ty, want: Ty, expr: []const u8, buf: []u8) []const u8 {
    if (have == want) return expr;
    if (want == .object) return boxExpr(have, expr, buf);
    if (have == .object) return unboxExpr(want, expr, buf);
    return expr;
}

fn boxExpr(t: Ty, expr: []const u8, buf: []u8) []const u8 {
    const fname = switch (t) {
        .i32 => "klio_nat_box_int",
        .i64 => "klio_nat_box_long",
        .f64 => "klio_nat_box_double",
        .f32 => "klio_nat_box_float",
        .boolean => "klio_nat_box_bool",
        .char => "klio_nat_box_char",
        .short => "klio_nat_box_short",
        .byte => "klio_nat_box_byte",
        .u32 => "klio_nat_box_uint",
        .u64 => "klio_nat_box_ulong",
        .u16 => "klio_nat_box_ushort",
        .u8 => "klio_nat_box_ubyte",
        // Boxing a Unit result must still run what produced it: the comma
        // keeps the expression and yields the Unit value. Returning a bare
        // `klio_nat_box_unit()` dropped the call.
        .unit => return std.fmt.bufPrint(buf, "((void)({s}), klio_nat_box_unit())", .{expr}) catch unreachable,
        .object => return std.fmt.bufPrint(buf, "{s}", .{expr}) catch unreachable,
    };
    return std.fmt.bufPrint(buf, "{s}({s})", .{ fname, expr }) catch unreachable;
}

/// The reverse: a `klio_value` known to hold `t`, back in a C local.
fn unboxExpr(t: Ty, expr: []const u8, buf: []u8) []const u8 {
    const fname = switch (t) {
        .i32 => "klio_nat_int",
        .i64 => "klio_nat_long",
        .f64 => "klio_nat_double",
        .f32 => "klio_nat_float",
        .boolean => "klio_nat_bool",
        .char => "klio_nat_char",
        .short => "klio_nat_short",
        .byte => "klio_nat_byte",
        .u32 => "klio_nat_uint",
        .u64 => "klio_nat_ulong",
        .u16 => "klio_nat_ushort",
        .u8 => "klio_nat_ubyte",
        // A Unit result is still a result: the expression that produced it
        // has to run. The comma keeps the call and yields the Unit register's
        // zero, where returning a bare `0` dropped the call entirely.
        .unit => return std.fmt.bufPrint(buf, "((void)({s}), 0)", .{expr}) catch unreachable,
        .object => return std.fmt.bufPrint(buf, "{s}", .{expr}) catch unreachable,
    };
    return std.fmt.bufPrint(buf, "{s}({s})", .{ fname, expr }) catch unreachable;
}

/// Where a register lives: a C local for a scalar, a published frame slot for
/// a reference.
fn regName(c: *const Compiled, r: u32, buf: []u8) []const u8 {
    // A suspend function's registers live in a HEAP frame: the body can return
    // in the middle and be re-entered later, so nothing may sit in a C local
    // that the return would discard.
    if (c.suspends) {
        if (c.types[r] == .object) {
            return std.fmt.bufPrint(buf, "fr->ks[{d}]", .{c.slot[r]}) catch unreachable;
        }
        return std.fmt.bufPrint(buf, "fr->r{d}", .{r}) catch unreachable;
    }
    if (c.types[r] == .object) {
        return std.fmt.bufPrint(buf, "KS[{d}]", .{c.slot[r]}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "r{d}", .{r}) catch unreachable;
}

fn writeProto(w: *std.Io.Writer, c: *const Compiled) !void {
    // A suspend body answers either its result or the SUSPENDED marker, so its
    // C result is a value rather than the declared machine type.
    try w.print("static {s} ", .{if (c.suspends) "klio_value" else c.ret.cName()});
    try writeSymbol(w, c.f);
    try w.writeByte('(');
    if (c.params.len == 0 and c.caps.len == 0) {
        try w.writeAll("void");
    } else {
        for (c.caps, 0..) |ct, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{s} k{d}", .{ ct.ty.cName(), i });
        }
        for (c.params, 0..) |p, i| {
            if (i != 0 or c.caps.len != 0) try w.writeAll(", ");
            try w.print("{s} p{d}", .{ paramTy(p).cName(), i });
        }
    }
    try w.writeByte(')');
}

fn writeConst(w: *std.Io.Writer, c: ir.Const) !void {
    switch (c) {
        .Int => |v| try w.print("INT32_C({d})", .{v}),
        .Long => |v| try w.print("INT64_C({d})", .{v}),
        .Bool => |v| try w.print("{d}", .{@intFromBool(v)}),
        .Char => |v| try w.print("{d}u", .{v}),
        .Short => |v| try w.print("{d}", .{v}),
        .Byte => |v| try w.print("{d}", .{v}),
        .UInt => |v| try w.print("UINT32_C({d})", .{v}),
        .ULong => |v| try w.print("UINT64_C({d})", .{v}),
        .UShort => |v| try w.print("((uint16_t){d}u)", .{v}),
        .UByte => |v| try w.print("((uint8_t){d}u)", .{v}),
        .Unit => try w.writeAll("0"),
        .Double => |v| try writeFloatLit(w, v, false),
        .Float => |v| try writeFloatLit(w, v, true),
        else => unreachable,
    }
}

/// A C string literal for arbitrary bytes. The source may hold anything,
/// including embedded NULs and invalid UTF-8, so every byte outside the plain
/// printable range is escaped numerically rather than passed through.
fn emitCLiteral(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeByte('"');
    for (bytes) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x20...0x21, 0x23...0x5B, 0x5D...0x7E => try w.writeByte(ch),
            else => try w.print("\\{o:0>3}", .{ch}),
        }
    }
    try w.writeByte('"');
}

/// A C floating literal for `v`. The shortest round-trip decimal is exact, but
/// it can come out with no decimal point at all (1e20 formats as
/// "100000000000000000000"), which C reads as an integer literal too large for
/// any integer type. A literal that carries neither a point nor an exponent
/// gets ".0" so it stays a double.
fn writeFloatLit(w: *std.Io.Writer, v: f64, is_f32: bool) !void {
    if (std.math.isNan(v)) {
        try w.print("(({s})NAN)", .{if (is_f32) "float" else "double"});
        return;
    }
    if (std.math.isInf(v)) {
        try w.print("(({s}{s})INFINITY)", .{ if (v < 0) "-" else "", if (is_f32) "float" else "double" });
        return;
    }
    // Scientific form, because plain decimal is neither always short (a
    // denormal expands to three hundred digits) nor always a float literal
    // (1e20 comes out as "100000000000000000000", which C reads as an integer
    // too large for any type). The shortest form that round-trips is exact.
    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{e}", .{v}) catch return error.WriteFailed;
    try w.writeAll(txt);
    if (std.mem.indexOfAny(u8, txt, ".eE") == null) try w.writeAll(".0");
    if (is_f32) try w.writeByte('f');
}

/// Integer division and remainder by zero throw in Kotlin; C makes them
/// undefined. The emitted body traps explicitly so a compiled program reports
/// the same failure rather than executing nonsense.
fn writeDivGuard(w: *std.Io.Writer, rhs: u32) !void {
    try w.print("  if (r{d} == 0) klio_arith_zero();\n", .{rhs});
}

/// Blocks some terminator can actually reach. Every emitted block ends in an
/// explicit `goto`/`return`, so nothing falls through and a block no edge names
/// is dead: emitting it would only leave the C compiler warning about a label
/// nothing jumps to.
/// The `i`th block control can reach from this one: its handlers first, then
/// wherever its terminator goes. Null once they are exhausted.
fn succOf(f: *const Func, blk: *const ir.Block, i: u32) ?u32 {
    _ = f;
    if (i < blk.catches.len) return blk.catches[i].handler.int();
    const k = i - @as(u32, @intCast(blk.catches.len));
    return switch (blk.terminator) {
        .Goto => |g| if (k == 0) g.int() else null,
        .Branch => |br| switch (k) {
            0 => br.t.int(),
            1 => br.f.int(),
            else => null,
        },
        else => null,
    };
}

/// The reachable blocks in reverse postorder from the entry. Catch handlers
/// are reached by a throw rather than a terminator, so they are edges too.
fn blockOrder(gpa: std.mem.Allocator, f: *const Func) Error![]u32 {
    const n = f.blocks.len;
    var post: std.ArrayList(u32) = .empty;
    errdefer post.deinit(gpa);
    const seen = try gpa.alloc(bool, n);
    defer gpa.free(seen);
    @memset(seen, false);
    // An explicit stack: a deeply nested function would otherwise recurse as
    // deep as it has blocks.
    const Frame = struct { bi: u32, next: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    if (n == 0) return try post.toOwnedSlice(gpa);
    seen[0] = true;
    try stack.append(gpa, .{ .bi = 0, .next = 0 });
    while (stack.items.len != 0) {
        const top = &stack.items[stack.items.len - 1];
        const blk = &f.blocks[top.bi];
        if (succOf(f, blk, top.next)) |s2| {
            top.next += 1;
            if (s2 < n and !seen[s2]) {
                seen[s2] = true;
                try stack.append(gpa, .{ .bi = s2, .next = 0 });
            }
            continue;
        }
        try post.append(gpa, top.bi);
        _ = stack.pop();
    }
    const out = try post.toOwnedSlice(gpa);
    std.mem.reverse(u32, out);
    return out;
}

fn reachableBlocks(gpa: std.mem.Allocator, f: *const Func) Error![]bool {
    const hit = try gpa.alloc(bool, f.blocks.len);
    @memset(hit, false);
    if (f.blocks.len != 0) hit[0] = true;
    var grew = true;
    while (grew) {
        grew = false;
        for (f.blocks, 0..) |*blk, bi| {
            if (!hit[bi]) continue;
            // A handler is reached by a throw, not by any terminator: without
            // this edge the block it jumps to looks dead and is dropped.
            for (blk.catches) |h| {
                if (h.handler.int() < hit.len and !hit[h.handler.int()]) {
                    hit[h.handler.int()] = true;
                    grew = true;
                }
            }
            switch (blk.terminator) {
                .Goto => |g| {
                    if (g.int() < hit.len and !hit[g.int()]) {
                        hit[g.int()] = true;
                        grew = true;
                    }
                },
                .Branch => |br| {
                    for ([_]u32{ br.t.int(), br.f.int() }) |t| {
                        if (t < hit.len and !hit[t]) {
                            hit[t] = true;
                            grew = true;
                        }
                    }
                },
                else => {},
            }
        }
    }
    return hit;
}

/// The type a body the emitter accepted actually returns, which is what its C
/// signature says. The DECLARED return type is not the authority: a thunk the
/// lowering synthesized carries a placeholder.
fn acceptedRet(accepted: []const Compiled, f: *const Func) ?Ty {
    for (accepted) |*cc| {
        if (cc.f == f) return cc.ret;
    }
    return null;
}

/// The suspending calls in a body, in emission order. Each is a point the
/// function can return from and be re-entered at, so each gets a state number
/// and a resume label.
fn suspendPoints(gpa: std.mem.Allocator, m: *const Module, f: *const Func, live: []const bool) Error![]const *const ir.Inst {
    var out: std.ArrayList(*const ir.Inst) = .empty;
    errdefer out.deinit(gpa);
    for (f.blocks, 0..) |*blk, bi| {
        if (!live[bi]) continue;
        for (blk.insts) |*inst| {
            if (!isSuspendingCall(m, inst)) continue;
            try out.append(gpa, inst);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Whether a body has to compile as a state machine: it is declared
/// `suspend`, or it calls something that is.
fn bodySuspends(m: *const Module, f: *const Func) bool {
    if (f.is_suspend) return true;
    for (f.blocks) |*blk| {
        for (blk.insts) |*inst| {
            if (isSuspendingCall(m, inst)) return true;
        }
    }
    return false;
}

fn isSuspendingCall(m: *const Module, inst: *const ir.Inst) bool {
    return switch (inst.*) {
        .Call => |cl| blk: {
            const callee = m.funcById(cl.func) orelse break :blk false;
            break :blk callee.is_suspend;
        },
        else => false,
    };
}

fn suspendIndex(points: []const *const ir.Inst, inst: *const ir.Inst) ?u32 {
    for (points, 0..) |p, i| {
        if (p == inst) return @intCast(i);
    }
    return null;
}

fn writeBody(gpa: std.mem.Allocator, w: *std.Io.Writer, m: *const Module, prog: Program, c: *const Compiled, uses_objects: bool, globals: []const Global, singletons: []const SingletonUse, slots: []const SlotUse, uses_try: bool, accepted: []const Compiled, registered: []const u32, lambdas: []const LambdaUse) !void {
    const f = c.f;
    const live = try reachableBlocks(gpa, f);
    defer gpa.free(live);
    const points = try suspendPoints(gpa, m, f, live);
    defer gpa.free(points);
    var has_catch = false;
    for (f.blocks) |*blk| {
        if (blk.catches.len != 0) has_catch = true;
    }
    if (c.suspends) {
        // The frame a suspension leaves behind: every register, plus the
        // resume label and the collector's view of the object slots. It is
        // heap memory because the body returns in the middle of itself.
        try w.print("typedef struct {{\n  uint32_t st;\n  klio_nat_frame gcf;\n  klio_value ks[{d}];\n", .{@max(c.n_slots, 1)});
        var sr: u32 = 0;
        while (sr < f.n_locals) : (sr += 1) {
            if (c.types[sr] == .object) continue;
            try w.print("  {s} r{d};\n", .{ c.types[sr].cName(), sr });
        }
        for (c.caps, 0..) |ct, ci| try w.print("  {s} k{d};\n", .{ ct.ty.cName(), ci });
        for (c.params, 0..) |p, pi| {
            const pt: Ty = tyOf(p.ty) orelse .object;
            try w.print("  {s} p{d};\n", .{ pt.cName(), pi });
        }
        try w.print("}} kfr_{d};\n", .{f.id.int()});
        // Building the frame is separate from running it: a coroutine the
        // DRIVER starts needs the frame handed over, not a body already
        // running.
        try w.print("static void *kcf_{d}(", .{f.id.int()});
        if (c.params.len == 0 and c.caps.len == 0) {
            try w.writeAll("void");
        } else {
            for (c.caps, 0..) |ct, i| {
                if (i != 0) try w.writeAll(", ");
                try w.print("{s} k{d}", .{ ct.ty.cName(), i });
            }
            for (c.params, 0..) |p, i| {
                if (i != 0 or c.caps.len != 0) try w.writeAll(", ");
                const pt: Ty = tyOf(p.ty) orelse .object;
                try w.print("{s} p{d}", .{ pt.cName(), i });
            }
        }
        try w.writeAll(") {\n");
        try w.print("  kfr_{d} *fr = (kfr_{d} *)klio_nat_coro_frame(sizeof(kfr_{d}), offsetof(kfr_{d}, gcf), offsetof(kfr_{d}, ks), {d});\n", .{
            f.id.int(), f.id.int(), f.id.int(), f.id.int(), f.id.int(), c.n_slots,
        });
        for (c.caps, 0..) |_, ci| try w.print("  fr->k{d} = k{d};\n", .{ ci, ci });
        for (c.params, 0..) |_, pi| try w.print("  fr->p{d} = p{d};\n", .{ pi, pi });
        try w.writeAll("  return fr;\n}\n");
        // The entry: build the frame, then run the body from its start.
        try writeProto(w, c);
        try w.writeAll(" {\n");
        try w.print("  return kco_{d}(kcf_{d}(", .{ f.id.int(), f.id.int() });
        for (c.caps, 0..) |_, ci| {
            if (ci != 0) try w.writeAll(", ");
            try w.print("k{d}", .{ci});
        }
        for (c.params, 0..) |_, pi| {
            if (pi != 0 or c.caps.len != 0) try w.writeAll(", ");
            try w.print("p{d}", .{pi});
        }
        try w.writeAll("), klio_nat_box_unit());\n}\n");
        // The continuation: entered fresh, and again at each resume.
        try w.print("static klio_value kco_{d}(void *fp, klio_value resumed) {{\n", .{f.id.int()});
        try w.print("  kfr_{d} *fr = (kfr_{d} *)fp;\n  (void)resumed;\n", .{ f.id.int(), f.id.int() });
        if (points.len != 0) {
            try w.writeAll("  switch (fr->st) {\n");
            var pi2: u32 = 0;
            while (pi2 < points.len) : (pi2 += 1) try w.print("    case {d}: goto RS{d};\n", .{ pi2 + 1, pi2 });
            try w.writeAll("    default: break;\n  }\n");
        }
        try w.writeAll("  goto B0;\n");
    } else {
        try writeProto(w, c);
        try w.writeAll(" {\n");
    }
    var r: u32 = 0;
    if (c.suspends) r = f.n_locals;
    while (r < f.n_locals) : (r += 1) {
        if (c.types[r] == .object) continue;
        // A local written after `setjmp` and read after the jump back is
        // indeterminate unless it is volatile. The object slots live in an
        // array, which is memory already.
        try w.print("  {s}{s} r{d} = 0;\n", .{ if (has_catch) "volatile " else "", c.types[r].cName(), r });
    }
    // Registers the lowering allocated but this body never reads: a C compiler
    // warns on them and the emitted file should be warning-clean. A suspend
    // body has no locals to void — its registers are frame fields.
    r = if (c.suspends) f.n_locals else 0;
    while (r < f.n_locals) : (r += 1) {
        if (c.types[r] == .object) continue;
        try w.print("  (void)r{d};", .{r});
    }
    try w.writeAll("\n");
    if (c.n_slots != 0 and !c.suspends) {
        // The references this body holds, published to the collector for the
        // duration of the call. Cleared first: a collection can happen before
        // the first assignment, and a slot holding whatever was on the stack is
        // a slot the collector will follow.
        try w.print("  klio_value KS[{d}];\n", .{c.n_slots});
        try w.print("  for (unsigned i = 0; i < {d}; i++) KS[i] = klio_nat_box_unit();\n", .{c.n_slots});
        try w.print("  klio_nat_frame KF; KF.n = {d}; KF.slots = KS; klio_nat_enter(&KF);\n", .{c.n_slots});
    }

    if (has_catch) {
        // The handler stack as this call found it. A `return` out of an armed
        // region leaves without reaching the block that disarms it, so every
        // return puts the stack back where it was: otherwise the next region
        // armed anywhere chains onto a `klio_try` in a frame that is gone.
        try w.writeAll("  klio_try *KTE = klio_try_top;\n");
    }
    if (!c.suspends) try w.writeAll("  goto B0;\n");
    for (f.blocks, 0..) |*blk, bi| {
        if (!live[bi]) continue;
        try w.print("B{d}:;\n", .{bi});
        if (blk.catch_done_for != null) try w.writeAll("  klio_try_disarm();\n");
        if (blk.catches.len != 0) {
            // Arm before the region's body. A throw inside it lands back here
            // with the value in flight, and each handler is tried in order.
            try w.print("  klio_try KT{d};\n", .{bi});
            // The published-frame chain at the moment of arming. A throw
            // reaching here skipped every frame's `leave` on the way, so the
            // landing pad puts the chain back before anything else runs.
            try w.print("  klio_nat_frame *KM{d} = klio_nat_frame_mark();\n", .{bi});
            try w.print("  klio_try_arm(&KT{d});\n", .{bi});
            try w.print("  if (setjmp(KT{d}.jb) != 0) {{\n", .{bi});
            try w.print("    klio_nat_frame_restore(KM{d});\n", .{bi});
            try w.writeAll("    klio_try_disarm();\n");
            for (blk.catches) |h| {
                var eb: [32]u8 = undefined;
                const ht = prog.throws.find(h.type_name).?;
                try w.print("    if (klio_nat_catches(klio_in_flight, {d}, {d})) {{ {s} = klio_in_flight; goto B{d}; }} /* {s} */\n", .{
                    ht.lo, ht.hi, regName(c, h.exception_reg.int(), &eb), h.handler.int(), h.type_name,
                });
            }
            try w.writeAll("    klio_do_throw(klio_in_flight);\n  }\n");
        }
        for (blk.insts) |*inst| {
            switch (inst.*) {
                .Trace => {},
                .EnclosingPush, .EnclosingPop => {},
                .CallMemberOrGlobal => |cg3| {
                    var nb18: [32]u8 = undefined;
                    const cdst = regName(c, cg3.dst.int(), &nb18);
                    switch (c.bare.get(inst).?) {
                        .member => |mb2| {
                            var rb18: [32]u8 = undefined;
                            try w.print("  {s} = kvirt_{d}({s}", .{ cdst, mb2.slot, regName(c, mb2.recv, &rb18) });
                            var aj18: u32 = 0;
                            while (aj18 < cg3.n_args) : (aj18 += 1) {
                                var ab18: [32]u8 = undefined;
                                try w.print(", {s}", .{regName(c, cg3.args.int() + aj18, &ab18)});
                            }
                            try w.writeAll(");\n");
                        },
                        .call => |cf2| {
                            const cfn2 = m.funcById(cf2).?;
                            if (isPrintln(cfn2) or scalarIntrinsic(cfn2) == .print) {
                                var rex3: std.Io.Writer.Allocating = .init(gpa);
                                defer rex3.deinit();
                                try renderExpr(gpa, m, prog, c, cg3.args.int(), &rex3);
                                try w.print("  {s}({s});\n", .{
                                    if (isPrintln(cfn2)) "klio_nat_println" else "klio_nat_print",
                                    rex3.written(),
                                });
                                continue;
                            }
                            const bn19 = bindCallArgs(m, cfn2.params, cg3.args.int(), cg3.n_args, cg3.arg_names).?;
                            var dj19: u32 = 0;
                            while (dj19 < bn19.n) : (dj19 += 1) {
                                if (bn19.regs[dj19] != null) continue;
                                const dfn19 = m.funcById(prog.defaultThunk(cfn2.id, dj19).?).?;
                                const dt19 = acceptedRet(accepted, dfn19) orelse funcRetTy2(m, dfn19).?;
                                var ds19: std.Io.Writer.Allocating = .init(gpa);
                                defer ds19.deinit();
                                try writeSymbol(&ds19.writer, dfn19);
                                try w.print("  {s} kb{d}_{d} = {s}(", .{ dt19.cName(), cg3.dst.int(), dj19, ds19.written() });
                                var dk19: u32 = 0;
                                while (dk19 < dj19) : (dk19 += 1) {
                                    if (dk19 != 0) try w.writeAll(", ");
                                    if (bn19.regs[dk19]) |br19| {
                                        var ab20: [32]u8 = undefined;
                                        try w.print("{s}", .{regName(c, br19, &ab20)});
                                    } else {
                                        try w.print("kb{d}_{d}", .{ cg3.dst.int(), dk19 });
                                    }
                                }
                                try w.writeAll(");\n");
                            }
                            try w.print("  {s} = ", .{cdst});
                            try writeSymbol(w, cfn2);
                            try w.writeByte('(');
                            var aj19: u32 = 0;
                            while (aj19 < bn19.n) : (aj19 += 1) {
                                if (aj19 != 0) try w.writeAll(", ");
                                var ab19: [32]u8 = undefined;
                                var cb19: [96]u8 = undefined;
                                const pw19 = acceptedParamTy(accepted, cfn2, aj19) orelse paramTy(cfn2.params[aj19]);
                                if (bn19.regs[aj19]) |ar19| {
                                    try w.print("{s}", .{convExpr(c.types[ar19], pw19, regName(c, ar19, &ab19), &cb19)});
                                    continue;
                                }
                                const dfn20 = m.funcById(prog.defaultThunk(cfn2.id, aj19).?).?;
                                const hv20 = acceptedRet(accepted, dfn20) orelse funcRetTy2(m, dfn20).?;
                                var tb20: [48]u8 = undefined;
                                const tn20 = try std.fmt.bufPrint(&tb20, "kb{d}_{d}", .{ cg3.dst.int(), aj19 });
                                try w.print("{s}", .{convExpr(hv20, pw19, tn20, &cb19)});
                            }
                            try w.writeAll(");\n");
                        },
                        else => unreachable,
                    }
                },
                .LoadFromThisOrGlobal => |lt| {
                    var nb8: [32]u8 = undefined;
                    const dst8 = regName(c, lt.dst.int(), &nb8);
                    switch (c.bare.get(inst).?) {
                        .field => |fl| {
                            var rb8: [32]u8 = undefined;
                            var gb8: [128]u8 = undefined;
                            const g8 = try std.fmt.bufPrint(&gb8, "klio_nat_get({s}, {d})", .{ regName(c, fl.recv, &rb8), fl.idx });
                            var ob8: [200]u8 = undefined;
                            try w.print("  {s} = {s};\n", .{ dst8, unboxExpr(c.types[lt.dst.int()], g8, &ob8) });
                        },
                        .accessor => |ac| {
                            var rb9: [32]u8 = undefined;
                            var sym8: std.Io.Writer.Allocating = .init(gpa);
                            defer sym8.deinit();
                            try writeSymbol(&sym8.writer, m.funcById(ac.func).?);
                            try w.print("  {s} = {s}({s});\n", .{ dst8, sym8.written(), regName(c, ac.recv, &rb9) });
                        },
                        .global => {
                            const gi8 = globalIndex(globals, m.consts.items[lt.name.int()].String).?;
                            var ob9: [96]u8 = undefined;
                            var src9: [32]u8 = undefined;
                            const from9 = try std.fmt.bufPrint(&src9, "KG[{d}]", .{gi8});
                            try w.print("  {s} = {s};\n", .{ dst8, unboxExpr(c.types[lt.dst.int()], from9, &ob9) });
                        },
                        .member, .call => unreachable,
                    }
                },
                .StoreToThisOrGlobal => |st| {
                    switch (c.bare.get(inst).?) {
                        .field => |fl| {
                            var rb10: [32]u8 = undefined;
                            var vb10: [32]u8 = undefined;
                            var bb10: [96]u8 = undefined;
                            try w.print("  klio_nat_set({s}, {d}, {s});\n", .{
                                regName(c, fl.recv, &rb10), fl.idx,
                                boxExpr(c.types[st.value.int()], regName(c, st.value.int(), &vb10), &bb10),
                            });
                        },
                        .accessor => |ac| {
                            var rb11: [32]u8 = undefined;
                            var vb11: [32]u8 = undefined;
                            var bb11: [96]u8 = undefined;
                            const sfn = m.funcById(ac.func).?;
                            var sym9: std.Io.Writer.Allocating = .init(gpa);
                            defer sym9.deinit();
                            try writeSymbol(&sym9.writer, sfn);
                            const want9: Ty = if (sfn.params.len >= 2) (tyOf(sfn.params[1].ty) orelse .object) else .object;
                            const arg9 = if (want9 == .object and c.types[st.value.int()] != .object)
                                boxExpr(c.types[st.value.int()], regName(c, st.value.int(), &vb11), &bb11)
                            else
                                regName(c, st.value.int(), &vb11);
                            try w.print("  {s}({s}, {s});\n", .{ sym9.written(), regName(c, ac.recv, &rb11), arg9 });
                        },
                        .global => {
                            const gi9 = globalIndex(globals, m.consts.items[st.name.int()].String).?;
                            var vb12: [32]u8 = undefined;
                            var bb12: [96]u8 = undefined;
                            try w.print("  KG[{d}] = {s};\n", .{
                                gi9, boxExpr(c.types[st.value.int()], regName(c, st.value.int(), &vb12), &bb12),
                            });
                        },
                        .member, .call => unreachable,
                    }
                },
                .Const => |k| {
                    const kv = m.consts.items[k.value.int()];
                    var nb: [32]u8 = undefined;
                    if (kv == .Null) {
                        try w.print("  {s} = klio_nat_null();\n", .{regName(c, k.dst.int(), &nb)});
                        continue;
                    }
                    if (kv == .String) {
                        try w.print("  {s} = klio_nat_string(", .{regName(c, k.dst.int(), &nb)});
                        try emitCLiteral(w, kv.String);
                        try w.print(", {d});\n", .{kv.String.len});
                        continue;
                    }
                    // The lowering declares a result register by writing Unit
                    // into it before the body that fills it runs, so a register
                    // that ends up holding a reference can still be assigned a
                    // scalar constant. The value is the same either way; the
                    // spelling is the register's.
                    if (c.types[k.dst.int()] == .object) {
                        var kb: [48]u8 = undefined;
                        var kw: std.Io.Writer = .fixed(&kb);
                        try writeConst(&kw, kv);
                        var bb13: [96]u8 = undefined;
                        try w.print("  {s} = {s};\n", .{
                            regName(c, k.dst.int(), &nb),
                            boxExpr(constTy(kv) orelse .unit, kw.buffered(), &bb13),
                        });
                        continue;
                    }
                    try w.print("  {s} = ", .{regName(c, k.dst.int(), &nb)});
                    try writeConst(w, kv);
                    try w.writeAll(";\n");
                },
                // A suspend body reads its parameters and captures from the
                // frame: the C arguments are gone by the time it resumes.
                .LoadParam => |lp| {
                    var nb: [32]u8 = undefined;
                    try w.print("  {s} = {s}p{d};\n", .{ regName(c, lp.dst.int(), &nb), if (c.suspends) "fr->" else "", lp.idx });
                },
                .LoadCapture => |lc| {
                    var nb: [32]u8 = undefined;
                    try w.print("  {s} = {s}k{d};\n", .{ regName(c, lc.dst.int(), &nb), if (c.suspends) "fr->" else "", lc.idx });
                },
                .MakeCell => |mk| {
                    var nb: [32]u8 = undefined;
                    var sb2: [32]u8 = undefined;
                    var bb4: [96]u8 = undefined;
                    try w.print("  {s} = klio_nat_cell({s});\n", .{
                        regName(c, mk.dst.int(), &nb),
                        boxExpr(c.types[mk.src.int()], regName(c, mk.src.int(), &sb2), &bb4),
                    });
                },
                .CellGet => |cg| {
                    var nb: [32]u8 = undefined;
                    var cb4: [32]u8 = undefined;
                    var gb2: [96]u8 = undefined;
                    const g2 = try std.fmt.bufPrint(&gb2, "klio_nat_cell_get({s})", .{regName(c, cg.cell.int(), &cb4)});
                    var ob2: [160]u8 = undefined;
                    try w.print("  {s} = {s};\n", .{
                        regName(c, cg.dst.int(), &nb), unboxExpr(c.types[cg.dst.int()], g2, &ob2),
                    });
                },
                .CellSet => |cs| {
                    var cb5: [32]u8 = undefined;
                    var vb2: [32]u8 = undefined;
                    var bb5: [96]u8 = undefined;
                    try w.print("  klio_nat_cell_set({s}, {s});\n", .{
                        regName(c, cs.cell.int(), &cb5),
                        boxExpr(c.types[cs.value.int()], regName(c, cs.value.int(), &vb2), &bb5),
                    });
                },
                .Move => |mv| {
                    var nb: [32]u8 = undefined;
                    var sb: [32]u8 = undefined;
                    const dt2 = c.types[mv.dst.int()];
                    const st2 = c.types[mv.src.int()];
                    const src2 = regName(c, mv.src.int(), &sb);
                    var bb14: [96]u8 = undefined;
                    const val2 = if (dt2 == .object and st2 != .object)
                        boxExpr(st2, src2, &bb14)
                    else if (dt2 != .object and st2 == .object)
                        unboxExpr(dt2, src2, &bb14)
                    else
                        src2;
                    try w.print("  {s} = {s};\n", .{ regName(c, mv.dst.int(), &nb), val2 });
                },
                .NewInstance => |ni| {
                    var nb: [32]u8 = undefined;
                    const dst = regName(c, ni.dst.int(), &nb);
                    if (isThrowableClass(m, ni.class.int())) {
                        const cn = m.classes.items[ni.class.int()];
                        const tid = prog.throws.find(cn.name) orelse prog.throws.find(cn.fqn);
                        try w.print("  {s} = klio_nat_exception(\"{s}\", ", .{ dst, cn.fqn });
                        if (ni.n_args == 1) {
                            var ab6: [32]u8 = undefined;
                            var bb7: [96]u8 = undefined;
                            const ar5 = ni.args.int();
                            try w.print("{s}", .{boxExpr(c.types[ar5], regName(c, ar5, &ab6), &bb7)});
                        } else {
                            try w.writeAll("klio_nat_box_unit()");
                        }
                        try w.print(", {d});\n", .{if (tid) |t| t.lo else 0});
                        continue;
                    }
                    if (unsignedTypeOf(m.classes.items[ni.class.int()].name)) |ut2| {
                        var ub9: [32]u8 = undefined;
                        try w.print("  {s} = ({s}){s};\n", .{
                            dst, ut2.cName(), regName(c, ni.args.int(), &ub9),
                        });
                        continue;
                    }
                    if (isArrayTypeName(m.classes.items[ni.class.int()].name)) {
                        var sb7: [32]u8 = undefined;
                        const nsz = regName(c, ni.args.int(), &sb7);
                        if (primArrayKind(m.classes.items[ni.class.int()].name)) |k7| {
                            try w.print("  {s} = klio_nat_prim_array({d}, {s});\n", .{ dst, k7, nsz });
                        } else {
                            try w.print("  {s} = klio_nat_ref_array_sized({s});\n", .{ dst, nsz });
                        }
                        if (ni.n_args == 2) {
                            // Each element is what the initializer returns for
                            // its index, which is a loop here rather than the
                            // per-element dispatch the interpreter runs.
                            const lr2 = ni.args.int() + 1;
                            var elem_call: std.Io.Writer.Allocating = .init(gpa);
                            defer elem_call.deinit();
                            var ety: Ty = .object;
                            if (c.lam[lr2]) |li2| {
                                const bf2 = m.funcById(li2.body).?;
                                ety = acceptedRet(accepted, bf2) orelse .object;
                                try writeSymbol(&elem_call.writer, bf2);
                                try elem_call.writer.writeByte('(');
                                for (li2.captures, 0..) |cr13, ci13| {
                                    if (ci13 != 0) try elem_call.writer.writeAll(", ");
                                    var cb13: [32]u8 = undefined;
                                    try elem_call.writer.print("{s}", .{regName(c, cr13.int(), &cb13)});
                                }
                                var pj: u32 = 0;
                                while (pj < bf2.params.len) : (pj += 1) {
                                    if (pj != 0 or li2.captures.len != 0) try elem_call.writer.writeAll(", ");
                                    if (pj == 0) {
                                        try elem_call.writer.print("ki{d}", .{ni.dst.int()});
                                    } else {
                                        try elem_call.writer.writeAll("0");
                                    }
                                }
                                try elem_call.writer.writeByte(')');
                            } else {
                                var fb16: [32]u8 = undefined;
                                ety = c.elem[lr2];
                                try elem_call.writer.print("klam_call_1({s}, klio_nat_box_int(ki{d}))", .{
                                    regName(c, lr2, &fb16), ni.dst.int(),
                                });
                                // The dispatcher already answers a boxed value.
                                ety = .object;
                            }
                            var bb20: [420]u8 = undefined;
                            try w.print(
                                "  for (int32_t ki{d} = 0; ki{d} < {s}; ki{d}++) klio_nat_array_set({s}, ki{d}, {s});\n",
                                .{ ni.dst.int(), ni.dst.int(), nsz, ni.dst.int(), dst, ni.dst.int(), boxExpr(ety, elem_call.written(), &bb20) },
                            );
                        }
                        continue;
                    }
                    const cdef2 = &m.classes.items[ni.class.int()];
                    const cb4 = bindCallArgs(m, cdef2.primary_params, ni.args.int(), ni.n_args, ni.arg_names).?;
                    // A parameter nothing binds runs the thunk the declaration
                    // lowered for its default, handed the arguments ahead of
                    // it; each lands in a local first, because a later default
                    // may read an earlier one.
                    var dp3: u32 = 0;
                    while (dp3 < cb4.n) : (dp3 += 1) {
                        if (cb4.regs[dp3] != null) continue;
                        const cdfn2 = m.funcById(ctorDefault(prog.layouts, cdef2, dp3).?).?;
                        const cdt = acceptedRet(accepted, cdfn2) orelse funcRetTy2(m, cdfn2).?;
                        var csym: std.Io.Writer.Allocating = .init(gpa);
                        defer csym.deinit();
                        try writeSymbol(&csym.writer, cdfn2);
                        try w.print("  {s} kcd{d}_{d} = {s}(klio_nat_null()", .{ cdt.cName(), ni.dst.int(), dp3, csym.written() });
                        // The thunk is compiled against the whole constructor
                        // signature; Kotlin forbids a default from reading a
                        // parameter declared after it, so the rest go in as
                        // whatever their C type zeroes to.
                        var ck3: u32 = 0;
                        while (ck3 < cb4.n) : (ck3 += 1) {
                            try w.writeAll(", ");
                            const cwant = ctorParamTy(cdef2, ck3);
                            if (ck3 >= dp3) {
                                if (cwant == .object) try w.writeAll("klio_nat_null()") else try w.writeAll("0");
                                continue;
                            }
                            var bx6: [96]u8 = undefined;
                            if (cb4.regs[ck3]) |br5| {
                                var ab6: [32]u8 = undefined;
                                try w.print("{s}", .{convExpr(c.types[br5], cwant, regName(c, br5, &ab6), &bx6)});
                            } else {
                                const pdfn = m.funcById(ctorDefault(prog.layouts, cdef2, ck3).?).?;
                                const phave = acceptedRet(accepted, pdfn) orelse funcRetTy2(m, pdfn).?;
                                var tb6: [48]u8 = undefined;
                                const tn6 = try std.fmt.bufPrint(&tb6, "kcd{d}_{d}", .{ ni.dst.int(), ck3 });
                                try w.print("{s}", .{convExpr(phave, cwant, tn6, &bx6)});
                            }
                        }
                        try w.writeAll(");\n");
                    }
                    try w.print("  {s} = klio_nat_alloc_instance(KCLS_{d});\n", .{ dst, ni.class.int() });
                    // The class's own initializer fills it, which is what lets
                    // a subclass hand the same instance up to its superclass's.
                    try w.print("  kinit_{d}({s}", .{ ni.class.int(), dst });
                    var pi3: u32 = 0;
                    while (pi3 < cb4.n) : (pi3 += 1) {
                        try w.writeAll(", ");
                        const want3: Ty = ctorParamTy(cdef2, pi3);
                        var ab5: [32]u8 = undefined;
                        var bx3: [96]u8 = undefined;
                        if (cb4.regs[pi3]) |areg3| {
                            try w.print("{s}", .{convExpr(c.types[areg3], want3, regName(c, areg3, &ab5), &bx3)});
                            continue;
                        }
                        const cdfn3 = m.funcById(ctorDefault(prog.layouts, cdef2, pi3).?).?;
                        const chave = acceptedRet(accepted, cdfn3) orelse funcRetTy2(m, cdfn3).?;
                        var tb5: [48]u8 = undefined;
                        const tn5 = try std.fmt.bufPrint(&tb5, "kcd{d}_{d}", .{ ni.dst.int(), pi3 });
                        try w.print("{s}", .{convExpr(chave, want3, tn5, &bx3)});
                    }
                    try w.writeAll(");\n");
                },
                .GetField => |gf| {
                    // A read whose result NAMES a class resolves at emit time
                    // and leaves nothing behind, exactly as loading the name
                    // of a class does.
                    if (staticClassOf(c.types, c.cls, gf.dst.int()) != null) continue;
                    {
                        const sen2 = m.consts.items[gf.field.int()];
                        if (sen2 == .String and std.mem.eql(u8, sen2.String, "<class-companion-or-self>")) {
                            var nb21: [32]u8 = undefined;
                            var rb21: [32]u8 = undefined;
                            if (staticClassOf(c.types, c.cls, gf.receiver.int())) |scq2| {
                                const ccq2 = companionObjectNamed(m, prog, m.classes.items[scq2].fqn).?;
                                try w.print("  {s} = KO[{d}];\n", .{
                                    regName(c, gf.dst.int(), &nb21), singletonSlot(singletons, ccq2, null).?,
                                });
                            } else {
                                try w.print("  {s} = {s};\n", .{
                                    regName(c, gf.dst.int(), &nb21), regName(c, gf.receiver.int(), &rb21),
                                });
                            }
                            continue;
                        }
                    }
                    var rc = c.cls[gf.receiver.int()].?;
                    // Where the value is read FROM: the receiver register, or
                    // the companion singleton when the receiver is a class
                    // name that answers through its companion.
                    var qrb: [32]u8 = undefined;
                    var recv_txt: []const u8 = regName(c, gf.receiver.int(), &qrb);
                    if (staticClassOf(c.types, c.cls, gf.receiver.int())) |sc| {
                        const enm = m.consts.items[gf.field.int()].String;
                        if (numClsTy(sc)) |bt3| {
                            var nb15: [32]u8 = undefined;
                            try w.print("  {s} = {s};\n", .{
                                regName(c, gf.dst.int(), &nb15),
                                builtinConst(bt3, plainFieldName(enm)).?.text,
                            });
                            continue;
                        }
                        if (std.mem.eql(u8, plainFieldName(enm), "entries") and
                            enumEntries(m, prog, sc).len != 0)
                        {
                            const ents4 = enumEntries(m, prog, sc);
                            var nb22: [32]u8 = undefined;
                            try w.print("  {{ klio_value ee[{d}];\n", .{ents4.len});
                            for (ents4, 0..) |_, ei4| {
                                try w.print("    ee[{d}] = KO[{d}];\n", .{
                                    ei4, singletonSlot(singletons, sc, @intCast(ei4)).?,
                                });
                            }
                            try w.print("    {s} = klio_nat_list(ee, {d}); }}\n", .{
                                regName(c, gf.dst.int(), &nb22), ents4.len,
                            });
                            continue;
                        }
                        if (enumEntryIndex(m, prog, sc, plainFieldName(enm))) |ei2| {
                            var nb3: [32]u8 = undefined;
                            try w.print("  {s} = KO[{d}];\n", .{
                                regName(c, gf.dst.int(), &nb3), singletonSlot(singletons, sc, ei2).?,
                            });
                            continue;
                        }
                        rc = companionObjectNamed(m, prog, m.classes.items[sc].fqn).?;
                        recv_txt = try std.fmt.bufPrint(&qrb, "KO[{d}]", .{singletonSlot(singletons, rc, null).?});
                    } else if (accessOwner(m, prog, rc, m.consts.items[gf.field.int()].String, false)) |cc| {
                        // The name is the companion's, not the receiver's.
                        rc = cc;
                        recv_txt = try std.fmt.bufPrint(&qrb, "KO[{d}]", .{singletonSlot(singletons, cc, null).?});
                    }
                    if (rc == STRING_CLS or rc == LIST_CLS or rc == ARRAY_CLS) {
                        var nb: [32]u8 = undefined;
                        var rb: [32]u8 = undefined;
                        try w.print("  {s} = {s}({s});\n", .{
                            regName(c, gf.dst.int(), &nb),
                            switch (rc) {
                                STRING_CLS => "klio_nat_str_length",
                                ARRAY_CLS => "klio_nat_array_size",
                                else => "klio_nat_list_size",
                            },
                            regName(c, gf.receiver.int(), &rb),
                        });
                        continue;
                    }
                    if (rc == RANGE_CLS) {
                        var nb18: [32]u8 = undefined;
                        var rb18: [32]u8 = undefined;
                        var pb18: [160]u8 = undefined;
                        var ob18: [220]u8 = undefined;
                        const call18 = try std.fmt.bufPrint(&pb18, "klio_nat_builtin_prop(\"{s}\", {s})", .{
                            plainFieldName(m.consts.items[gf.field.int()].String),
                            regName(c, gf.receiver.int(), &rb18),
                        });
                        try w.print("  {s} = {s};\n", .{
                            regName(c, gf.dst.int(), &nb18),
                            unboxExpr(c.types[gf.dst.int()], call18, &ob18),
                        });
                        continue;
                    }
                    const nm = m.consts.items[gf.field.int()].String;
                    switch (accessPlan(m, prog, rc, nm, false)) {
                        .none => unreachable,
                        .virtual => {
                            var nb17: [32]u8 = undefined;
                            var mangled: [96]u8 = undefined;
                            try w.print("  {s} = kprop_{d}_{s}({s});\n", .{
                                regName(c, gf.dst.int(), &nb17), rc,
                                mangleName(plainFieldName(nm), &mangled), recv_txt,
                            });
                        },
                        .accessor => |gacc| {
                            const gfn = m.funcById(gacc).?;
                            var nb2: [32]u8 = undefined;
                            var sym2: std.Io.Writer.Allocating = .init(gpa);
                            defer sym2.deinit();
                            try writeSymbol(&sym2.writer, gfn);
                            try w.print("  {s} = {s}({s});\n", .{
                                regName(c, gf.dst.int(), &nb2), sym2.written(), recv_txt,
                            });
                        },
                        .field => |idx| {
                            var nb: [32]u8 = undefined;
                            var ub: [128]u8 = undefined;
                            const get = try std.fmt.bufPrint(&ub, "klio_nat_get({s}, {d})", .{ recv_txt, idx });
                            var ob: [160]u8 = undefined;
                            try w.print("  {s} = {s};\n", .{
                                regName(c, gf.dst.int(), &nb), unboxExpr(c.types[gf.dst.int()], get, &ob),
                            });
                        },
                    }
                },
                .SetField => |sf| {
                    const rc = c.cls[sf.receiver.int()].?;
                    const nm = m.consts.items[sf.field.int()].String;
                    switch (accessPlan(m, prog, rc, nm, true)) {
                        .none, .virtual => unreachable,
                        .accessor => |sacc| {
                            const sfn = m.funcById(sacc).?;
                            var rb3: [32]u8 = undefined;
                            var vb3: [32]u8 = undefined;
                            var bx3: [96]u8 = undefined;
                            var sym3: std.Io.Writer.Allocating = .init(gpa);
                            defer sym3.deinit();
                            try writeSymbol(&sym3.writer, sfn);
                            const want3: Ty = if (sfn.params.len >= 2) (tyOf(sfn.params[1].ty) orelse .object) else .object;
                            const arg3 = convExpr(c.types[sf.value.int()], want3, regName(c, sf.value.int(), &vb3), &bx3);
                            try w.print("  {s}({s}, {s});\n", .{ sym3.written(), regName(c, sf.receiver.int(), &rb3), arg3 });
                        },
                        .field => |idx| {
                            var rb: [32]u8 = undefined;
                            var vb: [32]u8 = undefined;
                            var bb: [96]u8 = undefined;
                            try w.print("  klio_nat_set({s}, {d}, {s});\n", .{
                                regName(c, sf.receiver.int(), &rb), idx,
                                boxExpr(c.types[sf.value.int()], regName(c, sf.value.int(), &vb), &bb),
                            });
                        },
                    }
                },
                .BinOp => |b| {
                    const dt = c.types[b.dst.int()];
                    if (b.op == .IdentEq or b.op == .IdentNeq) {
                        var db4: [32]u8 = undefined;
                        var lb4: [32]u8 = undefined;
                        var rb4: [32]u8 = undefined;
                        var l4: [96]u8 = undefined;
                        var r4: [96]u8 = undefined;
                        try w.print("  {s} = {s}klio_nat_value_ident({s}, {s});\n", .{
                            regName(c, b.dst.int(), &db4),
                            if (b.op == .IdentNeq) "!" else "",
                            boxExpr(c.types[b.lhs.int()], regName(c, b.lhs.int(), &lb4), &l4),
                            boxExpr(c.types[b.rhs.int()], regName(c, b.rhs.int(), &rb4), &r4),
                        });
                        continue;
                    }
                    if ((b.op == .Eq or b.op == .NotEq) and
                        (c.types[b.lhs.int()] == .object or c.types[b.rhs.int()] == .object))
                    {
                        var db2: [32]u8 = undefined;
                        var lb2: [32]u8 = undefined;
                        var rb2: [32]u8 = undefined;
                        var l2: [96]u8 = undefined;
                        var r2: [96]u8 = undefined;
                        try w.print("  {s} = {s}klio_nat_value_eq({s}, {s});\n", .{
                            regName(c, b.dst.int(), &db2),
                            if (b.op == .NotEq) "!" else "",
                            boxExpr(c.types[b.lhs.int()], regName(c, b.lhs.int(), &lb2), &l2),
                            boxExpr(c.types[b.rhs.int()], regName(c, b.rhs.int(), &rb2), &r2),
                        });
                        continue;
                    }
                    if (dt == .object and (b.op == .RangeTo or b.op == .RangeUntil)) {
                        var db3: [32]u8 = undefined;
                        var lb3: [32]u8 = undefined;
                        var rb3: [32]u8 = undefined;
                        var l3: [96]u8 = undefined;
                        var r3: [96]u8 = undefined;
                        try w.print("  {s} = klio_nat_range({d}, {s}, {s});\n", .{
                            regName(c, b.dst.int(), &db3),
                            @as(u32, if (b.op == .RangeTo) 0 else 1),
                            boxExpr(c.types[b.lhs.int()], regName(c, b.lhs.int(), &lb3), &l3),
                            boxExpr(c.types[b.rhs.int()], regName(c, b.rhs.int(), &rb3), &r3),
                        });
                        continue;
                    }
                    if (dt == .object) {
                        // Concatenation: either operand may be any value, and
                        // the runtime renders it as Kotlin would.
                        var db: [32]u8 = undefined;
                        var lb: [32]u8 = undefined;
                        var rb: [32]u8 = undefined;
                        var l1: [96]u8 = undefined;
                        var r1: [96]u8 = undefined;
                        var lex: std.Io.Writer.Allocating = .init(gpa);
                        defer lex.deinit();
                        var rex2: std.Io.Writer.Allocating = .init(gpa);
                        defer rex2.deinit();
                        try renderExpr(gpa, m, prog, c, b.lhs.int(), &lex);
                        try renderExpr(gpa, m, prog, c, b.rhs.int(), &rex2);
                        _ = &lb;
                        _ = &rb;
                        _ = &l1;
                        _ = &r1;
                        try w.print("  {s} = klio_nat_concat({s}, {s});\n", .{
                            regName(c, b.dst.int(), &db), lex.written(), rex2.written(),
                        });
                        continue;
                    }
                    var lnb: [32]u8 = undefined;
                    var rnb: [32]u8 = undefined;
                    var dnb: [32]u8 = undefined;
                    const ln = regName(c, b.lhs.int(), &lnb);
                    const rn = regName(c, b.rhs.int(), &rnb);
                    const dn = regName(c, b.dst.int(), &dnb);
                    if (b.op == .UShr) {
                        // C has no unsigned right shift of a signed value, so
                        // it runs in the unsigned type of the same width;
                        // Kotlin masks the shift count where C leaves an
                        // over-wide shift undefined.
                        const lt5 = c.types[b.lhs.int()];
                        const ut5: []const u8 = if (lt5 == .i64) "uint64_t" else "uint32_t";
                        try w.print("  {s} = ({s})(({s}){s} >> ({s} & {d}));\n", .{
                            dn, dt.cName(), ut5, ln, rn,
                            @as(u32, if (lt5 == .i64) 63 else 31),
                        });
                        continue;
                    }
                    const op = cOp(b.op).?;
                    if ((b.op == .Div or b.op == .Mod) and !dt.isFloat() and !isCmp(b.op)) {
                        try w.print("  if ({s} == 0) klio_arith_zero();\n", .{rn});
                        // The most negative value divided by -1 overflows.
                        // Kotlin wraps it to itself and leaves the remainder
                        // zero; in C the division itself is undefined.
                        if (wrapTy(dt)) |ut4| {
                            if (b.op == .Div) {
                                try w.print("  if ({s} == -1) {{ {s} = ({s})(0 - ({s}){s}); }} else\n", .{
                                    rn, dn, dt.cName(), ut4, ln,
                                });
                            } else {
                                try w.print("  if ({s} == -1) {{ {s} = 0; }} else\n", .{ rn, dn });
                            }
                        }
                    }
                    if (b.op == .Shl or b.op == .Shr) {
                        // Kotlin masks the shift count; C leaves an over-wide
                        // shift undefined.
                        const lt = c.types[b.lhs.int()];
                        try w.print("  {s} = ({s})({s} {s} ({s} & {d}));\n", .{
                            dn, dt.cName(), ln, op, rn,
                            @as(u32, if (lt == .i64) 63 else 31),
                        });
                    } else if ((b.op == .Add or b.op == .Sub or b.op == .Mul) and wrapTy(dt) != null) {
                        // Kotlin's integer arithmetic WRAPS. C leaves signed
                        // overflow undefined, and an optimizer is entitled to
                        // assume it never happens, so the operation runs in the
                        // unsigned type of the same width and converts back.
                        // Only these three can overflow that way: division has
                        // its own case above, and the bitwise operations have
                        // no overflow to speak of.
                        const ut2 = wrapTy(dt).?;
                        try w.print("  {s} = ({s})(({s}){s} {s} ({s}){s});\n", .{
                            dn, dt.cName(), ut2, ln, op, ut2, rn,
                        });
                    } else {
                        const pt10: []const u8 = if (isCmp(b.op))
                            promote(c.types[b.lhs.int()], c.types[b.rhs.int()]).?.cName()
                        else
                            dt.cName();
                        try w.print("  {s} = ({s})(({s}){s} {s} ({s}){s});\n", .{
                            dn, dt.cName(), pt10, ln, op, pt10, rn,
                        });
                    }
                },
                .UnOp => |u| {
                    const t = c.types[u.dst.int()];
                    switch (u.op) {
                        // Negating the most negative value overflows, which
                        // Kotlin wraps and C leaves undefined.
                        .Neg => if (wrapTy(t)) |ut3| {
                            try w.print("  r{d} = ({s})(0{s} - ({s})r{d});\n", .{
                                u.dst.int(), t.cName(), if (t == .i64) "u" else "u", ut3, u.operand.int(),
                            });
                        } else {
                            try w.print("  r{d} = ({s})(-r{d});\n", .{ u.dst.int(), t.cName(), u.operand.int() });
                        },
                        .Plus => try w.print("  r{d} = ({s})r{d};\n", .{ u.dst.int(), t.cName(), u.operand.int() }),
                        // Kotlin's `inc`/`dec` wrap; in C a signed overflow is
                        // undefined, so the step runs in the unsigned type of
                        // the same width.
                        .Inc, .Dec => {
                            const step: []const u8 = if (u.op == .Inc) "+" else "-";
                            if (wrapTy(t)) |ut6| {
                                try w.print("  r{d} = ({s})(({s})r{d} {s} 1);\n", .{
                                    u.dst.int(), t.cName(), ut6, u.operand.int(), step,
                                });
                            } else {
                                try w.print("  r{d} = ({s})(r{d} {s} 1);\n", .{
                                    u.dst.int(), t.cName(), u.operand.int(), step,
                                });
                            }
                        },
                    }
                },
                .Not => |n| try w.print("  r{d} = !r{d};\n", .{ n.dst.int(), n.src.int() }),
                .Cast => |ca| {
                    var nb20: [32]u8 = undefined;
                    var rb20: [32]u8 = undefined;
                    var bx20: [96]u8 = undefined;
                    const sn = regName(c, ca.src.int(), &rb20);
                    // The test is asked of a VALUE; a register holding a
                    // machine type is boxed for it.
                    const sv = boxExpr(c.types[ca.src.int()], sn, &bx20);
                    const dn20 = regName(c, ca.dst.int(), &nb20);
                    const tname = simpleName(ca.ty.name);
                    try w.print("  {{ klio_value kc = {s};\n    uint32_t kt = klio_nat_class_of(kc);\n    (void)kt;\n    int32_t kok = ", .{sv});
                    if (classIndexOfName(m, ca.ty)) |tc2| {
                        if (!isBuiltinCls(tc2)) {
                            for (registered) |cid| {
                                if (!typeReaches(m, cid, tc2)) continue;
                                try w.print("(kt == KCLS_{d}) || ", .{cid});
                            }
                        }
                    }
                    try w.print("klio_nat_is_type(kc, \"{s}\", 1);\n", .{tname});
                    var ob20: [220]u8 = undefined;
                    const dv = convExpr(.object, c.types[ca.dst.int()], "kc", &ob20);
                    if (ca.safe) {
                        try w.print("    {s} = kok ? {s} : klio_nat_null(); }}\n", .{ dn20, dv });
                    } else {
                        try w.print("    if (!kok) klio_cast_fail(\"{s}\", {d});\n    {s} = {s}; }}\n", .{
                            tname, tname.len, dn20, dv,
                        });
                    }
                },
                .InstanceOf => |io| {
                    // The classes the program registered whose type includes
                    // the one asked about: an exact test for every compiled
                    // instance. Anything else answers from its representation.
                    var nb19: [32]u8 = undefined;
                    var rb19: [32]u8 = undefined;
                    var bx19: [96]u8 = undefined;
                    const target = classIndexOfName(m, io.ty);
                    const iv = boxExpr(c.types[io.src.int()], regName(c, io.src.int(), &rb19), &bx19);
                    try w.print("  {{ klio_value kc = {s};\n    uint32_t kt = klio_nat_class_of(kc);\n    (void)kt;\n    {s} = ", .{
                        iv, regName(c, io.dst.int(), &nb19),
                    });
                    if (target) |tc| {
                        if (!isBuiltinCls(tc)) {
                            for (registered) |cid| {
                                if (!typeReaches(m, cid, tc)) continue;
                                try w.print("(kt == KCLS_{d}) || ", .{cid});
                            }
                        }
                    }
                    try w.print("klio_nat_is_type(kc, \"{s}\", {d}); }}\n", .{
                        simpleName(io.ty.name),
                        @as(u32, if (io.ty.nullable) 1 else 0),
                    });
                },
                .CallMember => |cm| {
                    var nb: [32]u8 = undefined;
                    var rb: [32]u8 = undefined;
                    const recv = regName(c, cm.receiver.int(), &rb);
                    // `toString()` on a value with no override of its own.
                    if (isToStringCall(m.consts.items[cm.name.int()].String, cm.n_args) and
                        rendersToString(m, prog, c.cls, cm.receiver.int()))
                    {
                        var bx10: [96]u8 = undefined;
                        try w.print("  {s} = klio_nat_to_string({s});\n", .{
                            regName(c, cm.dst.int(), &nb),
                            boxExpr(c.types[cm.receiver.int()], recv, &bx10),
                        });
                        continue;
                    }
                    // The iteration protocol on a builtin receiver, written by
                    // name: the runtime picks the same handler by that name.
                    if (c.cls[cm.receiver.int()]) |brc| {
                        if (isBuiltinCls(brc) and member_dispatch.hostFreeMemberAnswer(plainFieldName(m.consts.items[cm.name.int()].String)) != null) {
                            try w.print("  {{ klio_value ma[{d}];\n    ma[0] = {s};\n", .{ cm.n_args + 1, recv });
                            var khb: u32 = 0;
                            while (khb < cm.n_args) : (khb += 1) {
                                const ahb = cm.args.int() + khb;
                                var abb: [32]u8 = undefined;
                                var bbb: [96]u8 = undefined;
                                try w.print("    ma[{d}] = {s};\n", .{
                                    khb + 1, boxExpr(c.types[ahb], regName(c, ahb, &abb), &bbb),
                                });
                            }
                            var hbb: [320]u8 = undefined;
                            var hob: [400]u8 = undefined;
                            const hcall2 = try std.fmt.bufPrint(&hbb, "klio_nat_member(\"{s}\", ma, {d})", .{
                                plainFieldName(m.consts.items[cm.name.int()].String), cm.n_args + 1,
                            });
                            try w.print("    {s} = {s}; }}\n", .{
                                regName(c, cm.dst.int(), &nb),
                                unboxExpr(c.types[cm.dst.int()], hcall2, &hob),
                            });
                            continue;
                        }
                    }
                    if (c.cls[cm.receiver.int()]) |rc| {
                        if (rc == ARRAY_CLS) {
                            const an2 = m.consts.items[cm.name.int()].String;
                            const aa4 = cm.args.int();
                            var ab7: [32]u8 = undefined;
                            if (std.mem.eql(u8, an2, "get")) {
                                var gb7: [160]u8 = undefined;
                                const g7 = try std.fmt.bufPrint(&gb7, "klio_nat_array_get({s}, {s})", .{ recv, regName(c, aa4, &ab7) });
                                var ob7: [220]u8 = undefined;
                                try w.print("  {s} = {s};\n", .{
                                    regName(c, cm.dst.int(), &nb), unboxExpr(c.types[cm.dst.int()], g7, &ob7),
                                });
                            } else {
                                var vb7: [32]u8 = undefined;
                                var bb7: [96]u8 = undefined;
                                try w.print("  klio_nat_array_set({s}, {s}, {s});\n", .{
                                    recv, regName(c, aa4, &ab7),
                                    boxExpr(c.types[aa4 + 1], regName(c, aa4 + 1, &vb7), &bb7),
                                });
                            }
                            continue;
                        }
                        if (rc == LIST_CLS) {
                            const mn = m.consts.items[cm.name.int()].String;
                            const a0 = cm.args.int();
                            var ab: [32]u8 = undefined;
                            var bb: [96]u8 = undefined;
                            if (std.mem.eql(u8, mn, "get")) {
                                var gb: [160]u8 = undefined;
                                const g = try std.fmt.bufPrint(&gb, "klio_nat_list_get({s}, {s})", .{ recv, regName(c, a0, &ab) });
                                var ob: [220]u8 = undefined;
                                try w.print("  {s} = {s};\n", .{
                                    regName(c, cm.dst.int(), &nb), unboxExpr(c.types[cm.dst.int()], g, &ob),
                                });
                            } else if (std.mem.eql(u8, mn, "add")) {
                                try w.print("  klio_nat_list_add({s}, {s});\n", .{
                                    recv, boxExpr(c.types[a0], regName(c, a0, &ab), &bb),
                                });
                                try w.print("  {s} = 1;\n", .{regName(c, cm.dst.int(), &nb)});
                            } else {
                                var vb: [32]u8 = undefined;
                                try w.print("  klio_nat_list_set({s}, {s}, {s});\n", .{
                                    recv, regName(c, a0, &ab),
                                    boxExpr(c.types[a0 + 1], regName(c, a0 + 1, &vb), &bb),
                                });
                                try w.print("  {s} = klio_nat_box_unit();\n", .{regName(c, cm.dst.int(), &nb)});
                            }
                            continue;
                        }
                    }
                    // A call written on a class NAME runs on that class's
                    // companion, and the singleton is the receiver.
                    if (companionReceiver(m, prog, c.types, c.cls, cm.receiver.int())) |cc7| {
                        const mn7 = m.consts.items[cm.name.int()].String;
                        const root7b = memberRoot(m, prog, cc7, plainFieldName(mn7), cm.n_args).?;
                        try w.print("  {s} = kvirt_{d}(KO[{d}]", .{
                            regName(c, cm.dst.int(), &nb), root7b.id.int(), singletonSlot(singletons, cc7, null).?,
                        });
                        var aj7: u32 = 0;
                        while (aj7 < cm.n_args) : (aj7 += 1) {
                            var ab7b: [32]u8 = undefined;
                            try w.print(", {s}", .{regName(c, cm.args.int() + aj7, &ab7b)});
                        }
                        try w.writeAll(");\n");
                        continue;
                    }
                    if (numConv(m, cm) == null and c.cls[cm.receiver.int()] != null and
                        !isBuiltinCls(c.cls[cm.receiver.int()].?))
                    {
                        const rc9 = c.cls[cm.receiver.int()].?;
                        const mn9 = m.consts.items[cm.name.int()].String;
                        if (fieldIndex(prog, rc9, mn9)) |fidx9| {
                            const fds9 = prog.of(rc9).?;
                            var call14: std.Io.Writer.Allocating = .init(gpa);
                            defer call14.deinit();
                            try call14.writer.print("klam_call_{d}(klio_nat_get({s}, {d})", .{
                                funcClsArity(fds9[fidx9].cls.?).?, recv, fidx9,
                            });
                            var aj14: u32 = 0;
                            while (aj14 < cm.n_args) : (aj14 += 1) {
                                const ar14 = cm.args.int() + aj14;
                                var ab14: [32]u8 = undefined;
                                var bb18: [96]u8 = undefined;
                                try call14.writer.print(", {s}", .{
                                    boxExpr(c.types[ar14], regName(c, ar14, &ab14), &bb18),
                                });
                            }
                            try call14.writer.writeByte(')');
                            var ob14: [400]u8 = undefined;
                            try w.print("  {s} = {s};\n", .{
                                regName(c, cm.dst.int(), &nb),
                                unboxExpr(c.types[cm.dst.int()], call14.written(), &ob14),
                            });
                            continue;
                        }
                        const root6 = memberRoot(m, prog, rc9, plainFieldName(mn9), cm.n_args) orelse {
                            var bx9: [96]u8 = undefined;
                            try w.print("  {s} = klio_nat_to_string({s});\n", .{
                                regName(c, cm.dst.int(), &nb),
                                boxExpr(c.types[cm.receiver.int()], recv, &bx9),
                            });
                            continue;
                        };
                        try w.print("  {s} = kvirt_{d}({s}", .{
                            regName(c, cm.dst.int(), &nb), root6.id.int(), recv,
                        });
                        var aj5: u32 = 0;
                        while (aj5 < cm.n_args) : (aj5 += 1) {
                            var ab5: [32]u8 = undefined;
                            try w.print(", {s}", .{regName(c, cm.args.int() + aj5, &ab5)});
                        }
                        try w.writeAll(");\n");
                        continue;
                    }
                    try w.print("  {s} = ({s}){s};\n", .{
                        regName(c, cm.dst.int(), &nb), c.types[cm.dst.int()].cName(), recv,
                    });
                },
                .CallVirtual => |cv| {
                    var nb: [32]u8 = undefined;
                    var rb: [32]u8 = undefined;
                    const recv = regName(c, cv.receiver.int(), &rb);
                    if (m.funcById(ir.FuncId.from(cv.slot.int()))) |tsd2| {
                        if (isToStringCall(tsd2.name, cv.n_args) and
                            rendersToString(m, prog, c.cls, cv.receiver.int()))
                        {
                            var bx11: [96]u8 = undefined;
                            try w.print("  {s} = klio_nat_to_string({s});\n", .{
                                regName(c, cv.dst.int(), &nb),
                                boxExpr(c.types[cv.receiver.int()], recv, &bx11),
                            });
                            continue;
                        }
                    }
                    if (c.cls[cv.receiver.int()]) |rc0| {
                        if (isBuiltinCls(rc0)) host: {
                            const decl0 = m.funcById(ir.FuncId.from(cv.slot.int())) orelse break :host;
                            if (hostMemberOp(decl0) == null) break :host;
                            // The runtime reads the declaration's name to pick
                            // the same operation the emitter classified, and
                            // takes the receiver as the first argument.
                            try w.print("  {{ klio_value ma[{d}];\n    ma[0] = {s};\n", .{ cv.n_args + 1, recv });
                            var kh: u32 = 0;
                            while (kh < cv.n_args) : (kh += 1) {
                                const ah = cv.args.int() + kh;
                                var ahb: [32]u8 = undefined;
                                var bhb: [96]u8 = undefined;
                                try w.print("    ma[{d}] = {s};\n", .{
                                    kh + 1, boxExpr(c.types[ah], regName(c, ah, &ahb), &bhb),
                                });
                            }
                            var hb: [320]u8 = undefined;
                            var hob: [400]u8 = undefined;
                            const hcall = try std.fmt.bufPrint(&hb, "klio_nat_member(\"{s}\", ma, {d})", .{ decl0.fqn, cv.n_args + 1 });
                            try w.print("    {s} = {s}; }}\n", .{
                                regName(c, cv.dst.int(), &nb),
                                unboxExpr(c.types[cv.dst.int()], hcall, &hob),
                            });
                            continue;
                        }
                    }
                    if (isDispatched(slots, cv.slot.int())) {
                        try w.print("  {s} = kvirt_{d}({s}", .{
                            regName(c, cv.dst.int(), &nb), cv.slot.int(), recv,
                        });
                        var aj2: u32 = 0;
                        while (aj2 < cv.n_args) : (aj2 += 1) {
                            var ab3: [32]u8 = undefined;
                            try w.print(", {s}", .{regName(c, cv.args.int() + aj2, &ab3)});
                        }
                        try w.writeAll(");\n");
                        continue;
                    }
                    if (c.cls[cv.receiver.int()]) |rc| {
                        if (rc == LIST_CLS) {
                            const mn = listMemberName(m, cv.slot).?;
                            const a0 = cv.args.int();
                            var ab: [32]u8 = undefined;
                            var bb: [96]u8 = undefined;
                            if (std.mem.eql(u8, mn, "get")) {
                                var gb: [160]u8 = undefined;
                                const g = try std.fmt.bufPrint(&gb, "klio_nat_list_get({s}, {s})", .{ recv, regName(c, a0, &ab) });
                                var ob: [220]u8 = undefined;
                                try w.print("  {s} = {s};\n", .{
                                    regName(c, cv.dst.int(), &nb), unboxExpr(c.types[cv.dst.int()], g, &ob),
                                });
                            } else if (std.mem.eql(u8, mn, "add") and cv.n_args == 1) {
                                try w.print("  klio_nat_list_add({s}, {s});\n", .{
                                    recv, boxExpr(c.types[a0], regName(c, a0, &ab), &bb),
                                });
                                try w.print("  {s} = 1;\n", .{regName(c, cv.dst.int(), &nb)});
                            } else if (std.mem.eql(u8, mn, "set") and cv.n_args == 2) {
                                var vb: [32]u8 = undefined;
                                try w.print("  klio_nat_list_set({s}, {s}, {s});\n", .{
                                    recv, regName(c, a0, &ab),
                                    boxExpr(c.types[a0 + 1], regName(c, a0 + 1, &vb), &bb),
                                });
                                try w.print("  {s} = klio_nat_box_unit();\n", .{regName(c, cv.dst.int(), &nb)});
                            } else {
                                // The interpreter's own entry, receiver first.
                                const decl2 = m.funcById(ir.FuncId.from(cv.slot.int())).?;
                                const sym2 = stdlibEntry(decl2).?;
                                try w.print("  {{ klio_value sa[{d}];\n    sa[0] = {s};\n", .{ cv.n_args + 1, recv });
                                var kv2: u32 = 0;
                                while (kv2 < cv.n_args) : (kv2 += 1) {
                                    const ar12 = cv.args.int() + kv2;
                                    var ab12: [32]u8 = undefined;
                                    var bb12: [96]u8 = undefined;
                                    try w.print("    sa[{d}] = {s};\n", .{
                                        kv2 + 1, boxExpr(c.types[ar12], regName(c, ar12, &ab12), &bb12),
                                    });
                                }
                                var ob15: [300]u8 = undefined;
                                var sb15: [260]u8 = undefined;
                                const sc15 = try std.fmt.bufPrint(&sb15, "klio_nat_stdlib(\"{s}\", sa, {d})", .{ sym2, cv.n_args + 1 });
                                try w.print("    {s} = {s}; }}\n", .{
                                    regName(c, cv.dst.int(), &nb),
                                    unboxExpr(c.types[cv.dst.int()], sc15, &ob15),
                                });
                            }
                            continue;
                        }
                    }
                    try w.print("  {s} = ({s}){s};\n", .{
                        regName(c, cv.dst.int(), &nb), c.types[cv.dst.int()].cName(), recv,
                    });
                },
                .LoadGlobal => |lg| {
                    const gn = m.consts.items[lg.name.int()].String;
                    // A class name used as a qualifier resolves at emit time
                    // and leaves nothing behind to load.
                    if (staticClassOf(c.types, c.cls, lg.dst.int()) != null) continue;
                    if (c.lam[lg.dst.int()]) |li10| {
                        var nb23: [32]u8 = undefined;
                        try w.print("  {s} = KL[{d}];\n", .{
                            regName(c, lg.dst.int(), &nb23), lambdaSingletonSlot(lambdas, li10.body).?,
                        });
                        continue;
                    }
                    if (c.cls[lg.dst.int()]) |rc| {
                        if (!isBuiltinCls(rc) and singletonSlot(singletons, rc, null) != null) {
                            var nb2: [32]u8 = undefined;
                            try w.print("  {s} = KO[{d}];\n", .{
                                regName(c, lg.dst.int(), &nb2), singletonSlot(singletons, rc, null).?,
                            });
                            continue;
                        }
                    }
                    const gi = globalIndex(globals, gn).?;
                    var nb: [32]u8 = undefined;
                    var ob: [96]u8 = undefined;
                    var src: [32]u8 = undefined;
                    const from = try std.fmt.bufPrint(&src, "KG[{d}]", .{gi});
                    try w.print("  {s} = {s};\n", .{
                        regName(c, lg.dst.int(), &nb), unboxExpr(c.types[lg.dst.int()], from, &ob),
                    });
                },
                .StoreGlobal => |sg| {
                    const gn = m.consts.items[sg.name.int()].String;
                    const gi = globalIndex(globals, gn).?;
                    var vb: [32]u8 = undefined;
                    var bb: [96]u8 = undefined;
                    try w.print("  KG[{d}] = {s};\n", .{
                        gi, boxExpr(c.types[sg.value.int()], regName(c, sg.value.int(), &vb), &bb),
                    });
                },
                .AstLambda => |al3| {
                    if (c.types[al3.dst.int()] != .object) {
                        // Nothing to materialise: every use is a direct call,
                        // so the call site passes the captures itself.
                        continue;
                    }
                    var nb12: [32]u8 = undefined;
                    const ldst = regName(c, al3.dst.int(), &nb12);
                    if (al3.captures.len == 0) {
                        // The literal's one instance, built before the program
                        // runs: two evaluations of it are the same object.
                        try w.print("  {s} = KL[{d}];\n", .{
                            ldst, lambdaSingletonSlot(lambdas, al3.body_func.?).?,
                        });
                        continue;
                    }
                    try w.print("  {s} = klio_nat_alloc_instance(KLAM_{d});\n", .{ ldst, al3.body_func.?.int() });
                    for (al3.captures, 0..) |cr12, ci12| {
                        var cb12: [32]u8 = undefined;
                        var bb16: [96]u8 = undefined;
                        try w.print("  klio_nat_set({s}, {d}, {s});\n", .{
                            ldst, ci12,
                            boxExpr(c.types[cr12.int()], regName(c, cr12.int(), &cb12), &bb16),
                        });
                    }
                },
                .CallValueOrMember => |cvm| {
                    var nb14: [32]u8 = undefined;
                    var fb14: [32]u8 = undefined;
                    var call15: std.Io.Writer.Allocating = .init(gpa);
                    defer call15.deinit();
                    try call15.writer.print("klam_call_{d}({s}", .{
                        funcClsArity(c.cls[cvm.callee.int()].?).?,
                        regName(c, cvm.callee.int(), &fb14),
                    });
                    var aj15: u32 = 0;
                    while (aj15 < cvm.n_args) : (aj15 += 1) {
                        const ar15 = cvm.args.int() + aj15;
                        var ab15: [32]u8 = undefined;
                        var bb19: [96]u8 = undefined;
                        try call15.writer.print(", {s}", .{
                            boxExpr(c.types[ar15], regName(c, ar15, &ab15), &bb19),
                        });
                    }
                    try call15.writer.writeByte(')');
                    var ob15: [400]u8 = undefined;
                    try w.print("  {s} = {s};\n", .{
                        regName(c, cvm.dst.int(), &nb14),
                        unboxExpr(c.types[cvm.dst.int()], call15.written(), &ob15),
                    });
                },
                .CallValue => |cv2| {
                    if (c.types[cv2.callee.int()] == .object) {
                        var nb13: [32]u8 = undefined;
                        var fb13: [32]u8 = undefined;
                        var call13: std.Io.Writer.Allocating = .init(gpa);
                        defer call13.deinit();
                        try call13.writer.print("klam_call_{d}({s}", .{
                            funcClsArity(c.cls[cv2.callee.int()].?).?,
                            regName(c, cv2.callee.int(), &fb13),
                        });
                        var aj13: u32 = 0;
                        while (aj13 < cv2.n_args) : (aj13 += 1) {
                            const ar13 = cv2.args.int() + aj13;
                            var ab13: [32]u8 = undefined;
                            var bb17: [96]u8 = undefined;
                            try call13.writer.print(", {s}", .{
                                boxExpr(c.types[ar13], regName(c, ar13, &ab13), &bb17),
                            });
                        }
                        try call13.writer.writeByte(')');
                        var ob13: [400]u8 = undefined;
                        try w.print("  {s} = {s};\n", .{
                            regName(c, cv2.dst.int(), &nb13),
                            unboxExpr(c.types[cv2.dst.int()], call13.written(), &ob13),
                        });
                        continue;
                    }
                    const li = c.lam[cv2.callee.int()].?;
                    const bf = m.funcById(li.body).?;
                    var nb3: [32]u8 = undefined;
                    try w.print("  {s} = ", .{regName(c, cv2.dst.int(), &nb3)});
                    try writeSymbol(w, bf);
                    try w.writeByte('(');
                    for (li.captures, 0..) |cr, ci3| {
                        if (ci3 != 0) try w.writeAll(", ");
                        var cb3: [32]u8 = undefined;
                        try w.print("{s}", .{regName(c, cr.int(), &cb3)});
                    }
                    var aj3: u32 = 0;
                    while (aj3 < cv2.n_args) : (aj3 += 1) {
                        if (li.captures.len != 0 or aj3 != 0) try w.writeAll(", ");
                        var ab5: [32]u8 = undefined;
                        try w.print("{s}", .{regName(c, cv2.args.int() + aj3, &ab5)});
                    }
                    var aj4: usize = cv2.n_args;
                    while (aj4 < bf.params.len) : (aj4 += 1) {
                        if (li.captures.len != 0 or aj4 != 0) try w.writeAll(", ");
                        const pt4: Ty = tyOf(bf.params[aj4].ty) orelse .object;
                        if (pt4 == .object) {
                            try w.writeAll("klio_nat_box_unit()");
                        } else {
                            try w.writeAll("0");
                        }
                    }
                    try w.writeAll(");\n");
                },
                .Call => |call| {
                    const callee = m.funcById(call.func).?;
                    if (scalarIntrinsic(callee)) |si| {
                        var db2: [32]u8 = undefined;
                        var a1b: [32]u8 = undefined;
                        var a2b: [32]u8 = undefined;
                        const sa = call.args.int();
                        const sdst = regName(c, call.dst.int(), &db2);
                        const x1 = regName(c, sa, &a1b);
                        switch (si) {
                            .print => {
                                var bx6: [96]u8 = undefined;
                                try w.print("  klio_nat_print({s});\n", .{boxExpr(c.types[sa], x1, &bx6)});
                            },
                            .max, .min => {
                                const x2 = regName(c, sa + 1, &a2b);
                                try w.print("  {s} = ({s} {s} {s}) ? {s} : {s};\n", .{
                                    sdst, x1, if (si == .max) ">" else "<", x2, x1, x2,
                                });
                            },
                            // Kotlin's `abs` on the most negative value returns
                            // it unchanged; negating it in C is undefined, so
                            // the negation runs unsigned and wraps.
                            .abs => try w.print("  {s} = ({s} < 0) ? ({s})(0u{s} - ({s}){s}) : {s};\n", .{
                                sdst, x1, c.types[sa].cName(),
                                if (c.types[sa] == .i64) "ll" else "",
                                if (c.types[sa] == .i64) "uint64_t" else "uint32_t",
                                x1, x1,
                            }),
                        }
                        continue;
                    }
                    if (isLaunch(callee)) {
                        const lr6 = call.args.int() + call.n_args - 1;
                        var db7: [32]u8 = undefined;
                        var lb7: [32]u8 = undefined;
                        try w.print("  {s} = klio_nat_coro_launch({s});\n", .{
                            regName(c, call.dst.int(), &db7), regName(c, lr6, &lb7),
                        });
                        continue;
                    }
                    if (isRunBlocking(callee)) {
                        const br2 = call.args.int() + call.n_args - 1;
                        const li4 = c.lam[br2].?;
                        const bfn4 = m.funcById(li4.body).?;
                        var db6: [32]u8 = undefined;
                        try w.print("  {s} = klio_nat_run_blocking(kco_{d}, kcf_{d}(", .{
                            regName(c, call.dst.int(), &db6), bfn4.id.int(), bfn4.id.int(),
                        });
                        for (li4.captures, 0..) |cr6, ci6| {
                            if (ci6 != 0) try w.writeAll(", ");
                            var cb6: [32]u8 = undefined;
                            try w.print("{s}", .{regName(c, cr6.int(), &cb6)});
                        }
                        // The block's own parameters (a receiver slot the
                        // lowering always gives it) start unset.
                        var pk6: usize = 0;
                        while (pk6 < bfn4.params.len) : (pk6 += 1) {
                            if (pk6 != 0 or li4.captures.len != 0) try w.writeAll(", ");
                            const pt6: Ty = tyOf(bfn4.params[pk6].ty) orelse .object;
                            var zb6: [64]u8 = undefined;
                            try w.print("{s}", .{if (pt6 == .object) "klio_nat_box_unit()" else boxExpr(.unit, "0", &zb6)});
                        }
                        try w.writeAll("));\n");
                        continue;
                    }
                    if (isArrayOfNulls(callee)) {
                        var db4: [32]u8 = undefined;
                        var nb16: [32]u8 = undefined;
                        try w.print("  {s} = klio_nat_ref_array_sized({s});\n", .{
                            regName(c, call.dst.int(), &db4), regName(c, call.args.int(), &nb16),
                        });
                        continue;
                    }
                    if (arrayOfIntrinsic(callee)) |maybe_kind| {
                        var db3: [32]u8 = undefined;
                        const adst = regName(c, call.dst.int(), &db3);
                        if (call.n_args == 0) {
                            if (maybe_kind) |k3| {
                                try w.print("  {s} = klio_nat_prim_array({d}, 0);\n", .{ adst, k3 });
                            } else {
                                try w.print("  {s} = klio_nat_ref_array(0, 0);\n", .{adst});
                            }
                            continue;
                        }
                        try w.print("  {{ klio_value av[{d}];\n", .{call.n_args});
                        var ka4: u32 = 0;
                        while (ka4 < call.n_args) : (ka4 += 1) {
                            const ar4 = call.args.int() + ka4;
                            var ab8: [32]u8 = undefined;
                            var bb8: [96]u8 = undefined;
                            try w.print("    av[{d}] = {s};\n", .{
                                ka4, boxExpr(c.types[ar4], regName(c, ar4, &ab8), &bb8),
                            });
                        }
                        if (maybe_kind) |k4| {
                            try w.print("    {s} = klio_nat_prim_array_of({d}, av, {d}); }}\n", .{ adst, k4, call.n_args });
                        } else {
                            try w.print("    {s} = klio_nat_ref_array(av, {d}); }}\n", .{ adst, call.n_args });
                        }
                        continue;
                    }
                    if (listIntrinsic(callee)) |kind| {
                        var db: [32]u8 = undefined;
                        const dst = regName(c, call.dst.int(), &db);
                        if (call.n_args == 0) {
                            try w.print("  {s} = {s}(0, 0);\n", .{
                                dst, if (kind == .list_of) "klio_nat_list" else "klio_nat_mutable_list",
                            });
                            continue;
                        }
                        try w.print("  {{ klio_value ev[{d}];\n", .{call.n_args});
                        var k: u32 = 0;
                        while (k < call.n_args) : (k += 1) {
                            const ar = call.args.int() + k;
                            var ab: [32]u8 = undefined;
                            var bb: [96]u8 = undefined;
                            try w.print("    ev[{d}] = {s};\n", .{
                                k, boxExpr(c.types[ar], regName(c, ar, &ab), &bb),
                            });
                        }
                        try w.print("    {s} = {s}(ev, {d}); }}\n", .{
                            dst, if (kind == .list_of) "klio_nat_list" else "klio_nat_mutable_list", call.n_args,
                        });
                        continue;
                    }
                    if (isPrintln(callee)) {
                        const a0 = call.args.int();
                        const at = c.types[a0];
                        // EVERYTHING prints through the runtime's renderer.
                        // How Kotlin renders a value — the shortest
                        // round-tripping decimal, `true`/`false`, a data class
                        // by its properties — is the interpreter's own code,
                        // and a second copy of it in emitted C is a second
                        // thing to keep in agreement. printf's buffered stream
                        // also interleaves wrongly with the runtime's writes.
                        _ = at;
                        var rex: std.Io.Writer.Allocating = .init(gpa);
                        defer rex.deinit();
                        try renderExpr(gpa, m, prog, c, a0, &rex);
                        try w.print("  klio_nat_println({s});\n", .{rex.written()});
                    } else if (!callee.hasBody()) {
                        // The interpreter's own entry, called by name with the
                        // arguments boxed: the table is typed in Kotlin.
                        const sym = stdlibEntry(callee).?;
                        var db11: [32]u8 = undefined;
                        if (call.n_args == 0) {
                            var ob13: [200]u8 = undefined;
                            var sb13: [220]u8 = undefined;
                            const sc13 = try std.fmt.bufPrint(&sb13, "klio_nat_stdlib(\"{s}\", 0, 0)", .{sym});
                            try w.print("  {s} = {s};\n", .{
                                regName(c, call.dst.int(), &db11),
                                unboxExpr(c.types[call.dst.int()], sc13, &ob13),
                            });
                            continue;
                        }
                        try w.print("  {{ klio_value sa[{d}];\n", .{call.n_args});
                        var ks11: u32 = 0;
                        while (ks11 < call.n_args) : (ks11 += 1) {
                            const ar11 = call.args.int() + ks11;
                            var ab11: [32]u8 = undefined;
                            var bb11: [96]u8 = undefined;
                            try w.print("    sa[{d}] = {s};\n", .{
                                ks11, boxExpr(c.types[ar11], regName(c, ar11, &ab11), &bb11),
                            });
                        }
                        var ob14: [300]u8 = undefined;
                        var sb14: [260]u8 = undefined;
                        const sc14 = try std.fmt.bufPrint(&sb14, "klio_nat_stdlib(\"{s}\", sa, {d})", .{ sym, call.n_args });
                        try w.print("    {s} = {s}; }}\n", .{
                            regName(c, call.dst.int(), &db11),
                            unboxExpr(c.types[call.dst.int()], sc14, &ob14),
                        });
                        continue;
                    } else {
                        // Arguments go to the callee in ITS order: positional
                        // ones bind in order and named ones by name. A
                        // parameter nothing binds runs the thunk for it, handed
                        // the arguments ahead of it; each lands in a local
                        // first, because a later default may read an earlier
                        // one.
                        const bnd2 = bindCallArgs(m, callee.params, call.args.int(), call.n_args, call.arg_names).?;
                        var di2: u32 = 0;
                        while (di2 < bnd2.n) : (di2 += 1) {
                            if (bnd2.regs[di2] != null) continue;
                            // A `vararg` takes the array built below, not a
                            // default thunk.
                            if (bnd2.vararg_param != null and bnd2.vararg_param.? == di2) continue;
                            const dfn = m.funcById(prog.defaultThunk(callee.id, di2).?).?;
                            const dt2 = acceptedRet(accepted, dfn) orelse funcRetTy2(m, dfn).?;
                            var dsym: std.Io.Writer.Allocating = .init(gpa);
                            defer dsym.deinit();
                            try writeSymbol(&dsym.writer, dfn);
                            try w.print("  {s} kd{d}_{d} = {s}(", .{ dt2.cName(), call.dst.int(), di2, dsym.written() });
                            var dk: u32 = 0;
                            while (dk < di2) : (dk += 1) {
                                if (dk != 0) try w.writeAll(", ");
                                if (bnd2.regs[dk]) |br| {
                                    var ab3: [32]u8 = undefined;
                                    try w.print("{s}", .{regName(c, br, &ab3)});
                                } else {
                                    try w.print("kd{d}_{d}", .{ call.dst.int(), dk });
                                }
                            }
                            try w.writeAll(");\n");
                        }
                        // A SUSPENDING call may not come back. The state is
                        // saved before it runs; if the callee suspends, this
                        // frame records its own continuation and answers
                        // SUSPENDED in turn, and the driver re-enters at the
                        // resume label with the value the suspension produced.
                        if (suspendIndex(points, inst)) |sp| {
                            var db9: [32]u8 = undefined;
                            if (isDelay(callee)) {
                                // The wait IS the suspension: it records this
                                // frame's continuation and answers SUSPENDED,
                                // which this frame hands straight back.
                                var mb9: [32]u8 = undefined;
                                var cb10: [96]u8 = undefined;
                                const mr9 = call.args.int();
                                try w.print("  fr->st = {d};\n  return klio_nat_coro_delay({s}, kco_{d}, fr);\n", .{
                                    sp + 1,
                                    convExpr(c.types[mr9], .i64, regName(c, mr9, &mb9), &cb10),
                                    f.id.int(),
                                });
                                var ob11: [200]u8 = undefined;
                                try w.print("RS{d}:;\n  {s} = {s};\n", .{
                                    sp,
                                    regName(c, call.dst.int(), &db9),
                                    unboxExpr(c.types[call.dst.int()], "resumed", &ob11),
                                });
                                continue;
                            }
                            try w.print("  fr->st = {d};\n  {{ klio_value sv = ", .{sp + 1});
                            try writeSymbol(w, callee);
                            try w.writeByte('(');
                            var sk: u32 = 0;
                            while (sk < bnd2.n) : (sk += 1) {
                                if (sk != 0) try w.writeAll(", ");
                                if (bnd2.regs[sk]) |br9| {
                                    var ab9: [32]u8 = undefined;
                                    var cb9: [96]u8 = undefined;
                                    const pw9 = acceptedParamTy(accepted, callee, sk) orelse
                                        (tyOf(callee.params[sk].ty) orelse .object);
                                    try w.print("{s}", .{convExpr(c.types[br9], pw9, regName(c, br9, &ab9), &cb9)});
                                } else {
                                    try w.writeAll("klio_nat_box_unit()");
                                }
                            }
                            try w.writeAll(");\n");
                            try w.print("    if (klio_nat_is_suspended(sv)) return klio_nat_coro_park(kco_{d}, fr);\n", .{f.id.int()});
                            var ob9: [200]u8 = undefined;
                            try w.print("    {s} = {s}; }}\n", .{
                                regName(c, call.dst.int(), &db9),
                                unboxExpr(c.types[call.dst.int()], "sv", &ob9),
                            });
                            try w.print("  goto RD{d};\n", .{sp});
                            // The resume lands here with the value the
                            // suspension produced, and both arms converge on
                            // the same register.
                            try w.print("RS{d}:;\n", .{sp});
                            var ob10: [200]u8 = undefined;
                            try w.print("  {s} = {s};\n", .{
                                regName(c, call.dst.int(), &db9),
                                unboxExpr(c.types[call.dst.int()], "resumed", &ob10),
                            });
                            try w.print("RD{d}:;\n", .{sp});
                            continue;
                        }
                        // The register the result lands in may hold a
                        // reference where the callee returns a machine type:
                        // the lowering reuses one register for both, and the
                        // register's own type is what the C local declares.
                        const cret = acceptedRet(accepted, callee) orelse funcRetTy2(m, callee) orelse .unit;
                        const dwant = c.types[call.dst.int()];
                        // A `vararg` parameter takes ONE array holding the
                        // trailing arguments, which the call site builds.
                        if (bnd2.vararg_param) |vp2| {
                            const vt = tyOf(callee.params[vp2].ty) orelse Ty.object;
                            const vkind = primKindOfTy(vt);
                            try w.print("  klio_value kva{d};\n  {{ klio_value ve[{d}];\n", .{
                                call.dst.int(), if (bnd2.vararg_n == 0) @as(u32, 1) else bnd2.vararg_n,
                            });
                            var vi: u32 = 0;
                            while (vi < bnd2.vararg_n) : (vi += 1) {
                                const vr = bnd2.vararg_base + vi;
                                var vab: [32]u8 = undefined;
                                var vbb: [96]u8 = undefined;
                                try w.print("    ve[{d}] = {s};\n", .{
                                    vi, boxExpr(c.types[vr], regName(c, vr, &vab), &vbb),
                                });
                            }
                            if (vkind) |kk9| {
                                try w.print("    kva{d} = klio_nat_prim_array_of({d}, ve, {d}); }}\n", .{
                                    call.dst.int(), kk9, bnd2.vararg_n,
                                });
                            } else {
                                try w.print("    kva{d} = klio_nat_ref_array(ve, {d}); }}\n", .{
                                    call.dst.int(), bnd2.vararg_n,
                                });
                            }
                        }
                        var db: [32]u8 = undefined;
                        // The call is built whole, then converted: a callee
                        // that answers Unit still has to RUN when its result
                        // lands in a reference register, which a bare box name
                        // cannot express.
                        var callx: std.Io.Writer.Allocating = .init(gpa);
                        defer callx.deinit();
                        const cw = &callx.writer;
                        try writeSymbol(cw, callee);
                        try cw.writeByte('(');
                        var k: u32 = 0;
                        while (k < bnd2.n) : (k += 1) {
                            if (k != 0) try cw.writeAll(", ");
                            if (bnd2.vararg_param != null and bnd2.vararg_param.? == k) {
                                try cw.print("kva{d}", .{call.dst.int()});
                                continue;
                            }
                            if (bnd2.regs[k]) |br2| {
                                var ab: [32]u8 = undefined;
                                var cb14: [96]u8 = undefined;
                                const pwant = acceptedParamTy(accepted, callee, k) orelse paramTy(callee.params[k]);
                                try cw.print("{s}", .{
                                    convExpr(c.types[br2], pwant, regName(c, br2, &ab), &cb14),
                                });
                                continue;
                            }
                            // The parameter's own type decides: a thunk that
                            // computed a scalar arrives boxed where the
                            // parameter is a reference.
                            const want4: Ty = paramTy(callee.params[k]);
                            const dfn4 = m.funcById(prog.defaultThunk(callee.id, k).?).?;
                            const have4 = acceptedRet(accepted, dfn4) orelse funcRetTy2(m, dfn4).?;
                            var tb4: [48]u8 = undefined;
                            const tn4 = try std.fmt.bufPrint(&tb4, "kd{d}_{d}", .{ call.dst.int(), k });
                            var bx4: [96]u8 = undefined;
                            if (want4 == .object and have4 != .object) {
                                try cw.print("{s}", .{boxExpr(have4, tn4, &bx4)});
                            } else {
                                try cw.print("{s}", .{tn4});
                            }
                        }
                        try cw.writeAll(")");
                        var cx: [420]u8 = undefined;
                        try w.print("  {s} = {s};\n", .{
                            regName(c, call.dst.int(), &db),
                            convExpr(cret, dwant, callx.written(), &cx),
                        });
                    }
                },
                else => unreachable,
            }
        }
        switch (blk.terminator) {
            .Goto => |g| {
                // A jump to a block at or before this one closes a loop, which
                // is where an allocating body would otherwise run to the end of
                // the heap before anything could collect.
                if (uses_objects and g.int() <= bi) try w.writeAll("  klio_nat_safepoint();\n");
                try w.print("  goto B{d};\n", .{g.int()});
            },
            .Branch => |br| {
                var cb: [32]u8 = undefined;
                var ub7: [96]u8 = undefined;
                // A condition is a Boolean in Kotlin even when it arrives
                // boxed — a property read through a dispatcher, say — so it
                // unboxes here rather than being tested as a reference.
                const cond = convExpr(c.types[br.cond.int()], .boolean, regName(c, br.cond.int(), &cb), &ub7);
                try w.print("  if ({s}) goto B{d}; else goto B{d};\n", .{ cond, br.t.int(), br.f.int() });
            },
            .Throw => |t| {
                var tb: [32]u8 = undefined;
                var bb6: [96]u8 = undefined;
                try w.print("  {s}({s});\n", .{
                    if (uses_try) "klio_do_throw" else "klio_nat_throw",
                    boxExpr(c.types[t.int()], regName(c, t.int(), &tb), &bb6),
                });
            },
            .Return => |ret| {
                if (c.suspends) {
                    // The frame dies with the last return out of the body.
                    var rb9: [32]u8 = undefined;
                    var bb9: [96]u8 = undefined;
                    const val9 = if (ret) |rr9|
                        boxExpr(c.types[rr9.int()], regName(c, rr9.int(), &rb9), &bb9)
                    else
                        "klio_nat_box_unit()";
                    try w.print("  {{ klio_value rv = {s};\n    klio_nat_coro_free(fr);\n    return rv; }}\n", .{val9});
                    continue;
                }
                if (has_catch) try w.writeAll("  klio_try_top = KTE;\n");
                if (c.n_slots != 0) try w.writeAll("  klio_nat_leave(&KF);\n");
                if (ret) |rr| {
                    var rb: [32]u8 = undefined;
                    try w.print("  return {s};\n", .{regName(c, rr.int(), &rb)});
                } else if (c.ret == .object) {
                    try w.writeAll("  return klio_nat_box_unit();\n");
                } else {
                    try w.writeAll("  return 0;\n");
                }
            },
            else => unreachable,
        }
    }
    try w.writeAll("}\n\n");
}

/// One top-level property: its storage name and the thunk that computes its
/// initial value. A compiled program keeps these in statics published to the
/// collector, and runs the thunks before `main` in declaration order, which is
/// the order the interpreter runs them in.
/// What a class contributes beyond its constructor: the properties declared in
/// its body, with the thunk that computes each one's initial value. The IR
/// does not carry these — the Vm builds them from the AST — so they arrive
/// from the built module alongside the class table.
pub const BodyProp = struct {
    name: []const u8,
    ty: ir.TypeRef,
    init: ?ir.FuncId,
    /// False for a property that stores nothing: a computed `val x get() = ...`
    /// is a getter, not a field, and must not take a slot in the layout.
    has_backing: bool = true,
    is_abstract: bool = false,
    is_lateinit: bool = false,
    /// A declared non-nullable primitive with no initializer, which starts at
    /// its type's zero rather than at a value a thunk computes.
    zero_init: bool = false,
    /// The accessors a property declares. A computed property has no storage,
    /// so reading it is a call to its getter and writing it a call to its
    /// setter.
    getter: ?ir.FuncId = null,
    setter: ?ir.FuncId = null,
};

/// One entry of an `enum class`: its name, and the thunk per constructor
/// argument the declaration writes for it.
pub const EnumEntryInfo = struct {
    name: []const u8,
    args: []const ir.FuncId = &.{},
};

pub const ClassLayout = struct {
    /// Simple class name, matching the IR class it describes.
    name: []const u8,
    props: []const BodyProp,
    /// One thunk per argument this class passes to its superclass constructor,
    /// each taking this class's own constructor arguments.
    parent_args: []const ir.FuncId = &.{},
    /// An `enum class`'s entries in declaration order, which is also their
    /// ordinal order.
    entries: []const EnumEntryInfo = &.{},
    /// The `init { … }` blocks the class declares, lowered as thunks taking
    /// the instance and the constructor's arguments, with the body-property
    /// index each one runs BEFORE. Kotlin runs them in source order
    /// interleaved with the property initializers.
    init_blocks: []const ir.FuncId = &.{},
    init_block_positions: []const usize = &.{},
    /// A `data class` renders and compares by its primary constructor's
    /// properties, which the runtime's own renderer does once it is told.
    is_data: bool = false,
    /// One thunk per primary-constructor parameter that declares a default,
    /// null for the rest. A construction that omits the parameter runs it.
    ctor_defaults: []const ?ir.FuncId = &.{},
};

/// A lambda a register holds: the body to run and the registers captured at
/// the point it was made.
/// A captured value's machine type and, when it is a reference, which class it
/// holds — a captured String is only usable as one if that travels with it.
pub const CapInfo = struct { ty: Ty, cls: ?u32 = null, elem: Ty = .unit };

pub const LambdaInfo = struct {
    body: ir.FuncId,
    captures: []const Reg,
};

pub const Global = struct {
    name: []const u8,
    func: ir.FuncId,
};

/// The default-argument thunks of one function, indexed by the parameter each
/// fills. A thunk takes the parameters ahead of its own, so a default that
/// reads an earlier argument compiles to a call with that argument in hand.
pub const FuncDefaults = struct {
    func: ir.FuncId,
    slots: []const ?ir.FuncId,
};

/// The accepted bodies of one emission, entry last so a body is always
/// declared before the definition that calls it.
pub const Accepted = struct {
    funcs: []Compiled,
    entry: *const Func,
};

/// Emit the whole program. Returns false when `main` itself is outside the
/// subset, which is the caller's signal to fall back.
pub fn emit(
    gpa: std.mem.Allocator,
    m: *const Module,
    entry: *const Func,
    globals: []const Global,
    layouts: []const ClassLayout,
    defaults: []const FuncDefaults,
    w: *std.Io.Writer,
    src_path: []const u8,
) Error!bool {
    var throws = try buildThrowTable(gpa, m);
    defer throws.deinit(gpa);

    // Resolve every class's layout: the emitter asks about the same classes
    // repeatedly, and resolving walks the class table each time. A property
    // the source left unannotated takes the type its initializer computes, and
    // asking the initializer needs the layouts resolved so far — so the table
    // is built to a fixed point rather than in one pass. The passes only ever
    // ADD fields, so it settles in as many rounds as an initializer chain is
    // deep.
    const table = try gpa.alloc(?[]const FieldInfo, m.classes.items.len);
    defer {
        for (table) |maybe| {
            if (maybe) |fs| gpa.free(fs);
        }
        gpa.free(table);
    }
    const parent_table = try gpa.alloc(?Parent, m.classes.items.len);
    defer gpa.free(parent_table);
    @memset(table, null);
    @memset(parent_table, null);
    var prog: Program = .{ .fields = table, .parents = parent_table, .layouts = layouts, .throws = throws, .defaults = defaults };
    const complete_table = try gpa.alloc(bool, m.classes.items.len);
    defer gpa.free(complete_table);
    @memset(complete_table, false);
    {
        const MAX_PASSES: u32 = 8;
        var pass: u32 = 0;
        while (pass < MAX_PASSES) : (pass += 1) {
            var grew_layout = false;
            const last = pass + 1 == MAX_PASSES;
            for (table, 0..) |*slot_p, i| {
                if (complete_table[i]) continue;
                const prev: ?*const Program = if (pass == 0) null else &prog;
                const laid = (try classFields(gpa, m, layouts, @enumFromInt(i), prev, globals, last)) orelse continue;
                const before: usize = if (slot_p.*) |old_fs| old_fs.len else std.math.maxInt(usize);
                complete_table[i] = laid.complete;
                if (before == laid.fields.len and !laid.complete) {
                    gpa.free(laid.fields);
                    continue;
                }
                if (slot_p.*) |old_fs| gpa.free(old_fs);
                slot_p.* = laid.fields;
                parent_table[i] = laid.parent;
                grew_layout = true;
            }
            if (!grew_layout) break;
        }
        // A class still missing a property has no usable layout: handing out a
        // partial one would address the wrong field.
        for (table, 0..) |*slot_p, i| {
            if (complete_table[i]) continue;
            if (slot_p.*) |old_fs| gpa.free(old_fs);
            slot_p.* = null;
            parent_table[i] = null;
        }
    }
    var accepted: std.ArrayList(Compiled) = .empty;
    defer {
        for (accepted.items) |*c| c.deinit(gpa);
        accepted.deinit(gpa);
    }
    var seen = std.AutoHashMap(u32, void).init(gpa);
    defer seen.deinit();
    const Pending = struct { f: *const Func, synth: ?[]const ir.Param, caps: []const CapInfo = &.{} };
    // Capture signatures outlive the queue entry that carried them.
    var synth_owned: std.ArrayList([]ir.Param) = .empty;
    defer {
        for (synth_owned.items) |sp| gpa.free(sp);
        synth_owned.deinit(gpa);
    }
    var cap_owned: std.ArrayList([]CapInfo) = .empty;
    defer {
        for (cap_owned.items) |ct| gpa.free(ct);
        cap_owned.deinit(gpa);
    }
    var queue: std.ArrayList(Pending) = .empty;
    defer queue.deinit(gpa);

    // Reachable closure from the entry: only what the program can call is
    // emitted, which is what keeps a whole-stdlib lowering from becoming tens
    // of thousands of C functions.
    try queue.append(gpa, .{ .f = entry, .synth = null });
    try seen.put(entry.id.int(), {});
    // Only a class the program CONSTRUCTS can answer a virtual call, so the
    // two sets grow together: draining the queue discovers constructions and
    // call sites, and pairing them can queue more bodies, which can construct
    // more classes. The walk runs until neither set grows.
    var constructed: std.ArrayList(u32) = .empty;
    defer constructed.deinit(gpa);
    var vsites: std.ArrayList(ir.MethodSlotId) = .empty;
    defer vsites.deinit(gpa);
    // A single refusal anywhere in the reachable set fails the whole emission:
    // a compiled program has no interpreter to fall back INTO, so a body it
    // cannot call is not a slow path, it is a missing one.
    while (true) {
    while (queue.pop()) |pending| {
        const f = pending.f;
        const c = (try eligible(gpa, m, prog, f, globals, pending.synth, pending.caps)) orelse return false;
        try accepted.append(gpa, c);
        for (f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                // A function's NAME in value position: the body it refers to
                // is reachable through the reference alone.
                if (inst.* == .LoadGlobal) {
                    if (c.lam[inst.LoadGlobal.dst.int()]) |li11| {
                        const rfn = m.funcById(li11.body) orelse return false;
                        if (!seen.contains(rfn.id.int())) {
                            try seen.put(rfn.id.int(), {});
                            try queue.append(gpa, .{ .f = rfn, .synth = null });
                        }
                    }
                }
                // The one instance an `object` declaration has, named either
                // by its own name or through the class whose companion it is.
                const singleton_cid: ?u32 = switch (inst.*) {
                    .LoadGlobal => |lg4| blk4: {
                        if (lg4.name.int() >= m.consts.items.len) break :blk4 null;
                        const gn4 = m.consts.items[lg4.name.int()];
                        if (gn4 != .String) break :blk4 null;
                        break :blk4 objectClassNamed(m, prog, gn4.String) orelse
                            companionObjectNamed(m, prog, gn4.String);
                    },
                    .CallMember => |cm4| blk6: {
                        break :blk6 companionReceiver(m, prog, c.types, c.cls, cm4.receiver.int());
                    },
                    .GetField => |gf4| blk5: {
                        if (gf4.field.int() >= m.consts.items.len) break :blk5 null;
                        const fn4 = m.consts.items[gf4.field.int()];
                        if (fn4 != .String) break :blk5 null;
                        if (staticClassOf(c.types, c.cls, gf4.receiver.int())) |sc4| {
                            if (sc4 >= m.classes.items.len) break :blk5 null;
                            break :blk5 companionObjectNamed(m, prog, m.classes.items[sc4].fqn);
                        }
                        const rc4 = c.cls[gf4.receiver.int()] orelse break :blk5 null;
                        break :blk5 accessOwner(m, prog, rc4, fn4.String, false);
                    },
                    else => null,
                };
                if (singleton_cid) |oc| {
                    var have_o = false;
                    for (constructed.items) |uo| {
                        if (uo == oc) have_o = true;
                    }
                    if (!have_o) try constructed.append(gpa, oc);
                    for (prog.of(oc).?) |fd| {
                        const ifid = fd.init orelse continue;
                        const ifn = m.funcById(ifid) orelse return false;
                        if (seen.contains(ifn.id.int())) continue;
                        try seen.put(ifn.id.int(), {});
                        try queue.append(gpa, .{ .f = ifn, .synth = null });
                    }
                }
                // A referenced global drags in the thunk that initializes it.
                // Only referenced ones: the list carries every top-level
                // property in the program AND its libraries, and pulling them
                // all in would compile the whole stdlib to run `main`.
                const gname: ?ir.ConstId = switch (inst.*) {
                    .LoadGlobal => |lg| lg.name,
                    .StoreGlobal => |sg| sg.name,
                    else => null,
                };
                if (gname) |cid| {
                    if (cid.int() < m.consts.items.len) {
                        const gn = m.consts.items[cid.int()];
                        if (gn == .String) {
                            if (globalIndex(globals, gn.String)) |gi| {
                                const gf = m.funcById(globals[gi].func) orelse return false;
                                if (!seen.contains(gf.id.int())) {
                                    try seen.put(gf.id.int(), {});
                                    try queue.append(gpa, .{ .f = gf, .synth = null });
                                }
                            }
                        }
                    }
                    continue;
                }
                // Constructing a class runs the thunks that initialize its body
                // properties, so those are reachable too.
                if (inst.* == .AstLambda) {
                    const al2 = inst.AstLambda;
                    const bfid = al2.body_func orelse return false;
                    const bfn = m.funcById(bfid) orelse return false;
                    if (!seen.contains(bfn.id.int())) {
                        // The body is compiled against what this site captured:
                        // those values arrive as leading arguments. Its own
                        // parameters carry no declared types, so they come from
                        // the function type the value is expected to have —
                        // the same signature `eligible` typed it against.
                        const ct = try gpa.alloc(CapInfo, al2.captures.len);
                        for (al2.captures, 0..) |cr, ci4| ct[ci4] = .{ .ty = c.types[cr.int()], .cls = c.cls[cr.int()], .elem = c.elem[cr.int()] };
                        try cap_owned.append(gpa, ct);
                        var lsyn: ?[]ir.Param = null;
                        if (expectedFnType(m, c.f, al2.dst)) |t6| {
                            lsyn = try lambdaParams(gpa, bfn, t6);
                        }
                        if (lsyn) |ls6| try synth_owned.append(gpa, ls6);
                        try seen.put(bfn.id.int(), {});
                        try queue.append(gpa, .{ .f = bfn, .synth = lsyn, .caps = ct });
                    }
                    continue;
                }
                if (inst.* == .CallMember) {
                    const cm3 = inst.CallMember;
                    if (numConv(m, cm3) == null) if (c.cls[cm3.receiver.int()]) |rc8| {
                        if (!isBuiltinCls(rc8) and cm3.name.int() < m.consts.items.len) {
                            const nmc = m.consts.items[cm3.name.int()];
                            if (nmc == .String and fieldIndex(prog, rc8, nmc.String) == null) {
                                if (memberRoot(m, prog, rc8, plainFieldName(nmc.String), cm3.n_args)) |root8| {
                                    var have8 = false;
                                    for (vsites.items) |sv2| {
                                        if (sv2.int() == root8.id.int()) have8 = true;
                                    }
                                    if (!have8) try vsites.append(gpa, ir.MethodSlotId.from(root8.id.int()));
                                }
                            }
                        }
                    };
                    continue;
                }
                // Rendering a value calls its `toString`, so that slot is a
                // call site like any other.
                {
                    const rendered: ?u32 = switch (inst.*) {
                        .BinOp => |b3| if (b3.op == .StringConcat or c.types[b3.dst.int()] == .object) b3.lhs.int() else null,
                        else => null,
                    };
                    if (rendered) |rr4| {
                        for ([_]u32{ rr4, inst.BinOp.rhs.int() }) |reg4| {
                            if (c.types[reg4] != .object) continue;
                            const rc4b = c.cls[reg4] orelse continue;
                            const ts4 = toStringOf(m, prog, rc4b) orelse continue;
                            var have4b = false;
                            for (vsites.items) |sv4| {
                                if (sv4.int() == ts4.id.int()) have4b = true;
                            }
                            if (!have4b) try vsites.append(gpa, ir.MethodSlotId.from(ts4.id.int()));
                        }
                    }
                }
                if (inst.* == .Call) {
                    const pc4 = m.funcById(inst.Call.func);
                    if (pc4) |pf4| {
                        if ((isPrintln(pf4) or scalarIntrinsic(pf4) == .print) and inst.Call.n_args == 1) {
                            const a4 = inst.Call.args.int();
                            if (c.types[a4] == .object) {
                                if (c.cls[a4]) |rc4c| {
                                    if (toStringOf(m, prog, rc4c)) |ts4b| {
                                        var have4c = false;
                                        for (vsites.items) |sv5| {
                                            if (sv5.int() == ts4b.id.int()) have4c = true;
                                        }
                                        if (!have4c) try vsites.append(gpa, ir.MethodSlotId.from(ts4b.id.int()));
                                    }
                                }
                            }
                        }
                    }
                }
                if (inst.* == .CallVirtual) {
                    const cv2 = inst.CallVirtual;
                    if (numConvVirtual(m, cv2) == null) {
                        var have_site = false;
                        for (vsites.items) |sv| {
                            if (sv == cv2.slot) have_site = true;
                        }
                        if (!have_site) try vsites.append(gpa, cv2.slot);
                    }
                }
                // Reading an entry off its enum's name builds that entry:
                // the thunks its declaration writes for the constructor run,
                // and so do the enum's own body-property initializers.
                if (inst.* == .GetField) {
                    const gq = inst.GetField;
                    if (staticClassOf(c.types, c.cls, gq.receiver.int())) |sq| {
                        const eqn = m.consts.items[gq.field.int()];
                        if (eqn == .String) {
                            const all_entries = std.mem.eql(u8, plainFieldName(eqn.String), "entries") and
                                enumEntries(m, prog, sq).len != 0;
                            if (all_entries) {
                                var have_q5 = false;
                                for (constructed.items) |uq| {
                                    if (uq == sq) have_q5 = true;
                                }
                                if (!have_q5) try constructed.append(gpa, sq);
                                const ents6 = enumEntries(m, prog, sq);
                                for (ents6) |e6| {
                                    for (e6.args) |afid6| {
                                        const afn6 = m.funcById(afid6) orelse return false;
                                        if (seen.contains(afn6.id.int())) continue;
                                        try seen.put(afn6.id.int(), {});
                                        try queue.append(gpa, .{ .f = afn6, .synth = null });
                                    }
                                }
                                for (prog.of(sq).?) |fd6| {
                                    if (fd6.from_parent or fd6.preset) continue;
                                    const ifid6 = fd6.init orelse continue;
                                    const ifn6 = m.funcById(ifid6) orelse return false;
                                    if (seen.contains(ifn6.id.int())) continue;
                                    try seen.put(ifn6.id.int(), {});
                                    try queue.append(gpa, .{ .f = ifn6, .synth = null });
                                }
                                continue;
                            }
                            if (enumEntryIndex(m, prog, sq, plainFieldName(eqn.String))) |eqi| {
                                var have_q = false;
                                for (constructed.items) |uq| {
                                    if (uq == sq) have_q = true;
                                }
                                if (!have_q) try constructed.append(gpa, sq);
                                const ents3 = enumEntries(m, prog, sq);
                                for (ents3[eqi].args) |afid| {
                                    const afn2 = m.funcById(afid) orelse return false;
                                    if (seen.contains(afn2.id.int())) continue;
                                    try seen.put(afn2.id.int(), {});
                                    try queue.append(gpa, .{ .f = afn2, .synth = null });
                                }
                                for (prog.of(sq).?) |fd2| {
                                    if (fd2.from_parent or fd2.preset) continue;
                                    const ifid2 = fd2.init orelse continue;
                                    const ifn2 = m.funcById(ifid2) orelse return false;
                                    if (seen.contains(ifn2.id.int())) continue;
                                    try seen.put(ifn2.id.int(), {});
                                    try queue.append(gpa, .{ .f = ifn2, .synth = null });
                                }
                                continue;
                            }
                        }
                    }
                }
                // A bare name inside an inlined receiver body resolved to a
                // computed property or to a top-level one; either way what it
                // resolved to has to be compiled.
                if (c.bare.get(inst)) |res| {
                    blkbare: switch (res) {
                        .field => {},
                        .accessor => |ac| {
                            const afn3 = m.funcById(ac.func) orelse return false;
                            if (!seen.contains(afn3.id.int())) {
                                try seen.put(afn3.id.int(), {});
                                try queue.append(gpa, .{ .f = afn3, .synth = null });
                            }
                        },
                        .global => {
                            const bname: ?[]const u8 = switch (inst.*) {
                                .LoadFromThisOrGlobal => |l3| m.consts.items[l3.name.int()].String,
                                .StoreToThisOrGlobal => |s3| m.consts.items[s3.name.int()].String,
                                else => null,
                            };
                            if (bname) |bn3| {
                                if (globalIndex(globals, bn3)) |gi3| {
                                    const gfn3 = m.funcById(globals[gi3].func) orelse return false;
                                    if (!seen.contains(gfn3.id.int())) {
                                        try seen.put(gfn3.id.int(), {});
                                        try queue.append(gpa, .{ .f = gfn3, .synth = null });
                                    }
                                }
                            }
                        },
                        .member => |mb| {
                            // Every class beneath the receiver's type may
                            // answer, which the virtual pairing then queues.
                            var have_m = false;
                            for (vsites.items) |sv6| {
                                if (sv6.int() == mb.slot) have_m = true;
                            }
                            if (!have_m) try vsites.append(gpa, ir.MethodSlotId.from(mb.slot));
                        },
                        .call => |cf| {
                            const cfn = m.funcById(cf) orelse return false;
                            if (isPrintln(cfn) or scalarIntrinsic(cfn) != null or
                                listIntrinsic(cfn) != null or arrayOfIntrinsic(cfn) != null or
                                isArrayOfNulls(cfn)) break :blkbare;
                            if (!seen.contains(cfn.id.int())) {
                                try seen.put(cfn.id.int(), {});
                                try queue.append(gpa, .{ .f = cfn, .synth = null });
                            }
                            // A parameter the call leaves unbound runs the
                            // thunk the declaration lowered for it.
                            if (inst.* == .CallMemberOrGlobal) {
                                const cgq = inst.CallMemberOrGlobal;
                                if (bindCallArgs(m, cfn.params, cgq.args.int(), cgq.n_args, cgq.arg_names)) |bq| {
                                    var dq2: u32 = 0;
                                    while (dq2 < bq.n) : (dq2 += 1) {
                                        if (bq.regs[dq2] != null) continue;
                                        const dfq = prog.defaultThunk(cfn.id, dq2) orelse break;
                                        const dfnq = m.funcById(dfq) orelse return false;
                                        if (seen.contains(dfnq.id.int())) continue;
                                        try seen.put(dfnq.id.int(), {});
                                        try queue.append(gpa, .{ .f = dfnq, .synth = null });
                                    }
                                }
                            }
                        },
                    }
                    continue;
                }
                // A computed property reads and writes through its accessors,
                // so those are reachable wherever the property is touched.
                const acc: ?struct { rc: u32, name: ir.ConstId, set: bool } = switch (inst.*) {
                    .GetField => |gf2| blk3: {
                        const rcx = c.cls[gf2.receiver.int()] orelse break :blk3 null;
                        break :blk3 .{ .rc = rcx, .name = gf2.field, .set = false };
                    },
                    .SetField => |sf2| blk4: {
                        const rcx = c.cls[sf2.receiver.int()] orelse break :blk4 null;
                        break :blk4 .{ .rc = rcx, .name = sf2.field, .set = true };
                    },
                    else => null,
                };
                if (acc) |a2| {
                    if (!isBuiltinCls(a2.rc) and a2.name.int() < m.consts.items.len) {
                        const anm = m.consts.items[a2.name.int()];
                        if (anm == .String) {
                            switch (accessPlan(m, prog, a2.rc, anm.String, a2.set)) {
                                .accessor => |fid3| {
                                    const afn = m.funcById(fid3) orelse return false;
                                    if (!seen.contains(afn.id.int())) {
                                        try seen.put(afn.id.int(), {});
                                        try queue.append(gpa, .{ .f = afn, .synth = null });
                                    }
                                },
                                .virtual => {
                                    // Every class beneath the receiver's type
                                    // may answer, so every getter is reachable.
                                    const pn = plainFieldName(anm.String);
                                    var pc: u32 = 0;
                                    while (pc < m.classes.items.len) : (pc += 1) {
                                        if (prog.of(pc) == null) continue;
                                        if (!typeReaches(m, pc, a2.rc)) continue;
                                        const pg = prog.accessor(m, pc, pn, .get) orelse continue;
                                        const pfn = m.funcById(pg) orelse return false;
                                        if (seen.contains(pfn.id.int())) continue;
                                        try seen.put(pfn.id.int(), {});
                                        try queue.append(gpa, .{ .f = pfn, .synth = null });
                                    }
                                },
                                .field, .none => {},
                            }
                        }
                    }
                    continue;
                }
                if (inst.* == .NewInstance) {
                    if (inst.NewInstance.class.int() < m.classes.items.len and
                        (isArrayTypeName(m.classes.items[inst.NewInstance.class.int()].name) or
                            unsignedTypeOf(m.classes.items[inst.NewInstance.class.int()].name) != null)) continue;
                    {
                        const nc2 = inst.NewInstance.class.int();
                        var have_c = false;
                        for (constructed.items) |uc| {
                            if (uc == nc2) have_c = true;
                        }
                        if (!have_c) try constructed.append(gpa, nc2);
                    }
                    // Constructing a class runs every initializer in its chain:
                    // each class's body-property thunks, and the thunks it
                    // passes to its superclass's constructor.
                    var walk: ?u32 = inst.NewInstance.class.int();
                    var steps: u32 = 0;
                    while (walk) |wc| : (steps += 1) {
                        if (steps > 32) break;
                        const fds = prog.of(wc) orelse break;
                        const wdef = &m.classes.items[wc];
                        // Constructing a class runs its init blocks too.
                        if (ownLayout(prog, wdef.name)) |ol| {
                            for (ol.init_blocks) |ibf2| {
                                const ibn2 = m.funcById(ibf2) orelse return false;
                                if (seen.contains(ibn2.id.int())) continue;
                                try seen.put(ibn2.id.int(), {});
                                try queue.append(gpa, .{ .f = ibn2, .synth = null });
                            }
                        }
                        // And the thunk behind every constructor parameter the
                        // construction may omit.
                        if (wc == inst.NewInstance.class.int()) {
                            var dpi: usize = 0;
                            while (dpi < wdef.primary_params.len) : (dpi += 1) {
                                const dfd = ctorDefault(prog.layouts, wdef, dpi) orelse continue;
                                const dfn5 = m.funcById(dfd) orelse return false;
                                if (seen.contains(dfn5.id.int())) continue;
                                try seen.put(dfn5.id.int(), {});
                                // Like a superclass-argument thunk, it
                                // declares no parameters and reads its
                                // caller's positionally: a synthesized
                                // receiver slot first, then the constructor
                                // arguments AHEAD of the one it fills.
                                const csyn = try gpa.alloc(ir.Param, 1 + wdef.primary_params.len);
                                try synth_owned.append(gpa, csyn);
                                csyn[0] = .{
                                    .name = "$ctor_default_recv",
                                    .ty = .{ .name = "", .nullable = true, .args = &.{} },
                                    .default = null,
                                };
                                @memcpy(csyn[1..], wdef.primary_params);
                                try queue.append(gpa, .{ .f = dfn5, .synth = csyn });
                            }
                        }
                        for (fds) |fd| {
                            if (fd.from_parent) continue;
                            const ifid = fd.init orelse continue;
                            const ifn = m.funcById(ifid) orelse return false;
                            if (seen.contains(ifn.id.int())) continue;
                            try seen.put(ifn.id.int(), {});
                            try queue.append(gpa, .{ .f = ifn, .synth = null });
                        }
                        const pp = prog.parentOf(wc) orelse break;
                        for (pp.args) |tf| {
                            const ifn = m.funcById(tf) orelse return false;
                            if (seen.contains(ifn.id.int())) continue;
                            try seen.put(ifn.id.int(), {});
                            // A superclass-argument thunk declares no
                            // parameters and reads its class's constructor
                            // arguments positionally, so it compiles against
                            // them.
                            try queue.append(gpa, .{ .f = ifn, .synth = wdef.primary_params });
                        }
                        walk = pp.cid;
                    }
                    continue;
                }
                if (inst.* != .Call) continue;
                const callee = m.funcById(inst.Call.func) orelse return false;
                if (isPrintln(callee) or listIntrinsic(callee) != null or scalarIntrinsic(callee) != null or
                    arrayOfIntrinsic(callee) != null or isArrayOfNulls(callee) or isRunBlocking(callee) or
                    isDelay(callee) or isLaunch(callee)) continue;
                // A declaration the interpreter implements has no body to
                // compile: the call reaches the same entry the interpreter
                // reaches.
                if (!callee.hasBody() and stdlibEntry(callee) != null) continue;
                // A call that leaves a parameter unbound runs the thunk for it.
                const bnd3 = bindCallArgs(m, callee.params, inst.Call.args.int(), inst.Call.n_args, inst.Call.arg_names) orelse
                    return false;
                var dq: u32 = 0;
                while (dq < bnd3.n) : (dq += 1) {
                    if (bnd3.regs[dq] != null) continue;
                    const dfid2 = prog.defaultThunk(callee.id, dq) orelse break;
                    const dfn2 = m.funcById(dfid2) orelse return false;
                    if (seen.contains(dfn2.id.int())) continue;
                    try seen.put(dfn2.id.int(), {});
                    // The thunk reads the parameters ahead of its own
                    // positionally, so it compiles against the callee's
                    // signature up to that point.
                    try queue.append(gpa, .{ .f = dfn2, .synth = callee.params[0..dq] });
                }
                if (seen.contains(callee.id.int())) continue;
                try seen.put(callee.id.int(), {});
                try queue.append(gpa, .{ .f = callee, .synth = null });
            }
        }
    }
        // Every construction the walk found, against every virtual call site
        // it found. A class the program never builds answers nothing, which is
        // what keeps an abstract library base out of the compile.
        var grew_reach = false;
        for (vsites.items) |slot| {
            for (constructed.items) |cid| {
                const impl = slotImpl(m, prog, cid, slot) orelse {
                    // The class has the member in its type but no body for it:
                    // it satisfies the interface by DELEGATION, which forwards
                    // to another object at run time. Refusing keeps that a
                    // refusal rather than an AbstractMethodError in a compiled
                    // program.
                    const root9 = m.funcById(ir.FuncId.from(slot.int())) orelse continue;
                    if (typeHasSlot(m, cid, root9)) {
                        if (traceOn()) {
                            std.debug.print("[cgen] refuse {s}: `{s}` is satisfied by delegation\n", .{
                                m.classes.items[cid].name, root9.name,
                            });
                        }
                        return false;
                    }
                    continue;
                };
                // An override declaring more parameters than the site supplies
                // fills them from its own default thunks, so those are
                // reachable wherever the dispatcher is.
                const vroot = m.funcById(ir.FuncId.from(slot.int()));
                var vk: u32 = 1;
                while (vk < impl.params.len) : (vk += 1) {
                    const vfid = prog.defaultThunk(impl.id, vk) orelse
                        (if (vroot) |vr| prog.defaultThunk(vr.id, vk) else null) orelse continue;
                    const vfn = m.funcById(vfid) orelse return false;
                    if (seen.contains(vfn.id.int())) continue;
                    try seen.put(vfn.id.int(), {});
                    try queue.append(gpa, .{ .f = vfn, .synth = impl.params[0..vk] });
                    grew_reach = true;
                }
                if (seen.contains(impl.id.int())) continue;
                try seen.put(impl.id.int(), {});
                try queue.append(gpa, .{ .f = impl, .synth = null });
                grew_reach = true;
            }
        }
        if (!grew_reach) break;
    }

    // Printing a floating value is the one place where C's formatting and
    // Kotlin's disagree, so the helper rides along only when it is used.
    // A program with any handler carries the try machinery, and its throws go
    // through it rather than straight out.
    var uses_try = false;
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            if (blk.catches.len != 0) uses_try = true;
        }
    }

    // Virtual call sites: each distinct slot gets one dispatcher, switching on
    // the receiver's class.
    var used_slots: std.ArrayList(SlotUse) = .empty;
    defer used_slots.deinit(gpa);
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (inst.* == .CallMember) {
                    const cm2 = inst.CallMember;
                    if (numConv(m, cm2) != null) continue;
                    if (companionReceiver(m, prog, c.types, c.cls, cm2.receiver.int())) |cc8| {
                        const root8 = memberRoot(m, prog, cc8, plainFieldName(m.consts.items[cm2.name.int()].String), cm2.n_args) orelse continue;
                        var have8 = false;
                        for (used_slots.items) |u| {
                            if (u.slot == root8.id.int()) have8 = true;
                        }
                        if (!have8) try used_slots.append(gpa, .{ .slot = root8.id.int(), .n_args = cm2.n_args });
                        continue;
                    }
                    const rc7 = c.cls[cm2.receiver.int()] orelse continue;
                    if (isBuiltinCls(rc7)) continue;
                    if (fieldIndex(prog, rc7, m.consts.items[cm2.name.int()].String) != null) continue;
                    const root7 = memberRoot(m, prog, rc7, plainFieldName(m.consts.items[cm2.name.int()].String), cm2.n_args) orelse continue;
                    var have7 = false;
                    for (used_slots.items) |u| {
                        if (u.slot == root7.id.int()) have7 = true;
                    }
                    if (!have7) try used_slots.append(gpa, .{ .slot = root7.id.int(), .n_args = cm2.n_args });
                    continue;
                }
                {
                    var regs4: [2]?u32 = .{ null, null };
                    switch (inst.*) {
                        .BinOp => |b5| {
                            if (c.types[b5.dst.int()] == .object) {
                                regs4[0] = b5.lhs.int();
                                regs4[1] = b5.rhs.int();
                            }
                        },
                        .Call => |cl5| {
                            const pf5 = m.funcById(cl5.func);
                            if (pf5) |p5| {
                                if ((isPrintln(p5) or scalarIntrinsic(p5) == .print) and cl5.n_args == 1) {
                                    regs4[0] = cl5.args.int();
                                }
                            }
                        },
                        else => {},
                    }
                    for (regs4) |maybe_r| {
                        const r5 = maybe_r orelse continue;
                        if (c.types[r5] != .object) continue;
                        const rc5b = c.cls[r5] orelse continue;
                        const ts5 = toStringOf(m, prog, rc5b) orelse continue;
                        var have5 = false;
                        for (used_slots.items) |us5| {
                            if (us5.slot == ts5.id.int()) have5 = true;
                        }
                        if (!have5) try used_slots.append(gpa, .{ .slot = ts5.id.int(), .n_args = 0 });
                    }
                }
                if (c.bare.get(inst)) |res2| {
                    if (res2 == .member) {
                        var have_s = false;
                        for (used_slots.items) |us6| {
                            if (us6.slot == res2.member.slot) have_s = true;
                        }
                        if (!have_s) {
                            const nargs6: u32 = switch (inst.*) {
                                .CallMemberOrGlobal => |cg6| cg6.n_args,
                                else => 0,
                            };
                            try used_slots.append(gpa, .{ .slot = res2.member.slot, .n_args = nargs6 });
                        }
                    }
                }
                if (inst.* != .CallVirtual) continue;
                const cv = inst.CallVirtual;
                if (c.cls[cv.receiver.int()]) |rc| {
                    if (rc == LIST_CLS) continue;
                }
                if (m.funcById(ir.FuncId.from(cv.slot.int()))) |tsd3| {
                    if (isToStringCall(tsd3.name, cv.n_args) and
                        rendersToString(m, prog, c.cls, cv.receiver.int())) continue;
                }
                if (numConvVirtual(m, cv) != null) continue;
                var have3 = false;
                for (used_slots.items) |u| {
                    if (u.slot == cv.slot.int()) have3 = true;
                }
                if (!have3) try used_slots.append(gpa, .{ .slot = cv.slot.int(), .n_args = cv.n_args });
            }
        }
    }

    // `object` declarations the program names. Each has ONE instance, created
    // before the program runs and rooted for its whole life.
    var used_singletons: std.ArrayList(SingletonUse) = .empty;
    defer used_singletons.deinit(gpa);
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                // An enum entry read off the enum's name is an instance built
                // once, exactly like an `object` declaration's.
                if (inst.* == .CallMember) {
                    if (companionReceiver(m, prog, c.types, c.cls, inst.CallMember.receiver.int())) |cc9| {
                        var have_c9 = false;
                        for (used_singletons.items) |u| {
                            if (u.cid == cc9 and u.entry == null) have_c9 = true;
                        }
                        if (!have_c9) try used_singletons.append(gpa, .{ .cid = cc9 });
                    }
                    continue;
                }
                if (inst.* == .GetField) {
                    const gf3 = inst.GetField;
                    // A property the receiver's own class does not carry is its
                    // companion's, and that singleton has to exist.
                    if (staticClassOf(c.types, c.cls, gf3.receiver.int()) == null) {
                        if (gf3.field.int() < m.consts.items.len) {
                            const fnm3 = m.consts.items[gf3.field.int()];
                            if (fnm3 == .String) {
                                if (c.cls[gf3.receiver.int()]) |rc3| {
                                    if (accessOwner(m, prog, rc3, fnm3.String, false)) |cc3| {
                                        var have_c3 = false;
                                        for (used_singletons.items) |u| {
                                            if (u.cid == cc3 and u.entry == null) have_c3 = true;
                                        }
                                        if (!have_c3) try used_singletons.append(gpa, .{ .cid = cc3 });
                                    }
                                }
                            }
                        }
                    }
                    if (staticClassOf(c.types, c.cls, gf3.receiver.int())) |sc2| {
                        const enm2 = m.consts.items[gf3.field.int()];
                        if (enm2 == .String) {
                            if (std.mem.eql(u8, plainFieldName(enm2.String), "entries")) {
                                const ents5 = enumEntries(m, prog, sc2);
                                for (ents5, 0..) |_, ei5| {
                                    var have_e5 = false;
                                    for (used_singletons.items) |u| {
                                        if (u.cid == sc2 and u.entry != null and u.entry.? == ei5) have_e5 = true;
                                    }
                                    if (!have_e5) try used_singletons.append(gpa, .{ .cid = sc2, .entry = @intCast(ei5) });
                                }
                            }
                            if (enumEntryIndex(m, prog, sc2, plainFieldName(enm2.String))) |ei3| {
                                var have_e = false;
                                for (used_singletons.items) |u| {
                                    if (u.cid == sc2 and u.entry != null and u.entry.? == ei3) have_e = true;
                                }
                                if (!have_e) try used_singletons.append(gpa, .{ .cid = sc2, .entry = ei3 });
                            } else if (sc2 < m.classes.items.len) {
                                // A member read off a class name answers from
                                // that class's companion, which is a singleton
                                // the program has to build.
                                if (companionObjectNamed(m, prog, m.classes.items[sc2].fqn)) |cc2| {
                                    var have_c = false;
                                    for (used_singletons.items) |u| {
                                        if (u.cid == cc2 and u.entry == null) have_c = true;
                                    }
                                    if (!have_c) try used_singletons.append(gpa, .{ .cid = cc2 });
                                }
                            }
                        }
                    }
                    continue;
                }
                if (inst.* != .LoadGlobal) continue;
                const cid2 = inst.LoadGlobal.name;
                if (cid2.int() >= m.consts.items.len) continue;
                const gn2 = m.consts.items[cid2.int()];
                if (gn2 != .String) continue;
                const oc = objectClassNamed(m, prog, gn2.String) orelse
                    companionObjectNamed(m, prog, gn2.String) orelse continue;
                var have2 = false;
                for (used_singletons.items) |u| {
                    if (u.cid == oc and u.entry == null) have2 = true;
                }
                if (!have2) try used_singletons.append(gpa, .{ .cid = oc });
            }
        }
    }

    // Properties read through a type that declares them without storage. One
    // dispatcher per (receiver type, name): which getter runs is the
    // receiver's class, exactly as for a method.
    var used_props: std.ArrayList(PropUse) = .empty;
    defer used_props.deinit(gpa);
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (inst.* != .GetField) continue;
                const gf4 = inst.GetField;
                const rc4 = c.cls[gf4.receiver.int()] orelse continue;
                if (isBuiltinCls(rc4)) continue;
                if (staticClassOf(c.types, c.cls, gf4.receiver.int()) != null) continue;
                const nm4 = m.consts.items[gf4.field.int()];
                if (nm4 != .String) continue;
                if (accessPlan(m, prog, rc4, nm4.String, false) != .virtual) continue;
                const pname = plainFieldName(nm4.String);
                const vp4 = virtualProp(m, prog, rc4, pname) orelse continue;
                var have_p = false;
                for (used_props.items) |u| {
                    if (u.cid == rc4 and std.mem.eql(u8, u.name, pname)) have_p = true;
                }
                if (!have_p) try used_props.append(gpa, .{ .name = pname, .cid = rc4, .ret = vp4.ret });
            }
        }
    }

    // Lambdas whose value has to exist. Each becomes a class the emitter
    // synthesizes for that body, one field per capture: the collector traces
    // it like any instance, and a call through the value finds the body again
    // by its class handle.
    var used_lambdas: std.ArrayList(LambdaUse) = .empty;
    defer used_lambdas.deinit(gpa);
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (inst.* == .LoadGlobal) {
                    const lr9 = inst.LoadGlobal.dst.int();
                    if (c.lam[lr9]) |li9| {
                        var have_r = false;
                        for (used_lambdas.items) |u| {
                            if (u.body == li9.body) have_r = true;
                        }
                        if (!have_r) {
                            try used_lambdas.append(gpa, .{
                                .body = li9.body,
                                .n_caps = 0,
                                .arity = funcClsArity(c.cls[lr9].?).?,
                                .ret = c.elem[lr9],
                            });
                        }
                    }
                    continue;
                }
                if (inst.* != .AstLambda) continue;
                const al2 = inst.AstLambda;
                if (c.types[al2.dst.int()] != .object) continue;
                const bfid = al2.body_func orelse continue;
                var have_l = false;
                for (used_lambdas.items) |u| {
                    if (u.body == bfid) have_l = true;
                }
                if (have_l) continue;
                try used_lambdas.append(gpa, .{
                    .body = bfid,
                    .n_caps = @intCast(al2.captures.len),
                    .arity = funcClsArity(c.cls[al2.dst.int()].?).?,
                    .ret = c.elem[al2.dst.int()],
                });
            }
        }
    }

    // Classes the program constructs or reads through. Emitted as descriptors
    // and registered before main: a compiled program carries its own layout
    // because there is no module to ask.
    var used_classes: std.ArrayList(u32) = .empty;
    defer used_classes.deinit(gpa);
    for (used_singletons.items) |su2| {
        var seen_o = false;
        for (used_classes.items) |u| {
            if (u == su2.cid) seen_o = true;
        }
        if (!seen_o) try used_classes.append(gpa, su2.cid);
    }
    for (accepted.items) |*c| {
        for (c.cls) |maybe| {
            const cid = maybe orelse continue;
            if (isBuiltinCls(cid)) continue;
            // A class the program never laid out has no descriptor to
            // register: an interface, or a library type a value merely passes
            // through. Nothing constructs one, and every read that would need
            // its fields is refused before it reaches here.
            if (prog.of(cid) == null) continue;
            var seen_cls = false;
            for (used_classes.items) |u| {
                if (u == cid) seen_cls = true;
            }
            if (!seen_cls) try used_classes.append(gpa, cid);
        }
    }
    // Classes the program actually constructs, and every superclass in their
    // chains: each gets an initializer, and a subclass's calls its parent's.
    var ctor_classes: std.ArrayList(u32) = .empty;
    defer ctor_classes.deinit(gpa);
    {
        var want: std.ArrayList(u32) = .empty;
        defer want.deinit(gpa);
        for (used_singletons.items) |su3| try want.append(gpa, su3.cid);
        for (accepted.items) |*cc| {
            for (cc.f.blocks) |*blk| {
                for (blk.insts) |*inst| {
                    if (inst.* != .NewInstance) continue;
                    const nc = inst.NewInstance.class.int();
                    if (isThrowableClass(m, nc)) continue;
                    // An array is a runtime value, not an instance the emitter
                    // lays out or initializes.
                    if (nc < m.classes.items.len and
                        (isArrayTypeName(m.classes.items[nc].name) or unsignedTypeOf(m.classes.items[nc].name) != null)) continue;
                    try want.append(gpa, nc);
                }
            }
        }
        var wi: usize = 0;
        while (wi < want.items.len) : (wi += 1) {
            const cid = want.items[wi];
            if (prog.of(cid) == null) continue;
            var have = false;
            for (ctor_classes.items) |u| {
                if (u == cid) have = true;
            }
            if (have) continue;
            try ctor_classes.append(gpa, cid);
            if (prog.parentOf(cid)) |pp| try want.append(gpa, pp.cid);
        }
    }

    // A string is a reference too: a program that only concatenates still needs
    // the runtime for its collector and renderer.
    var uses_objects_hint = false;
    var uses_objects = used_classes.items.len != 0;
    for (accepted.items) |*c| {
        for (c.types) |t| {
            // A `Char` prints as a character, a `Short`/`Byte` as itself, and
            // an unsigned value as unsigned, so a program holding one needs the
            // runtime's renderer even if it never touches the heap.
            switch (t) {
                .object, .char, .short, .byte, .u32, .u64, .u16, .u8 => uses_objects = true,
                else => {},
            }
        }
    }

    // Only the globals the program actually touches get storage.
    var used_globals: std.ArrayList(Global) = .empty;
    defer used_globals.deinit(gpa);
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                const nm: ?ir.ConstId = switch (inst.*) {
                    .LoadGlobal => |lg| lg.name,
                    .StoreGlobal => |sg| sg.name,
                    // A bare name that resolved to no implicit receiver is the
                    // top-level property it falls back to.
                    .LoadFromThisOrGlobal => |lt2| if (c.bare.get(inst)) |r2|
                        (if (r2 == .global) lt2.name else null)
                    else
                        null,
                    .StoreToThisOrGlobal => |st2| if (c.bare.get(inst)) |r3|
                        (if (r3 == .global) st2.name else null)
                    else
                        null,
                    else => null,
                };
                const cid = nm orelse continue;
                const gn = m.consts.items[cid.int()];
                if (gn != .String) continue;
                const gi = globalIndex(globals, gn.String) orelse continue;
                var have = false;
                for (used_globals.items) |u| {
                    if (std.mem.eql(u8, u.name, globals[gi].name)) have = true;
                }
                if (!have) try used_globals.append(gpa, globals[gi]);
            }
        }
    }
    if (used_globals.items.len != 0 or used_singletons.items.len != 0 or used_slots.items.len != 0 or uses_try) uses_objects_hint = true;

    var needs_div = false;
    var needs_cast = false;
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                switch (inst.*) {
                    .Cast => |ca| {
                        if (!ca.safe) needs_cast = true;
                        uses_objects_hint = true;
                    },
                    .InstanceOf => uses_objects_hint = true,
                    .BinOp => |b| {
                        if ((b.op == .Div or b.op == .Mod) and !c.types[b.dst.int()].isFloat()) needs_div = true;
                    },
                    // Printing goes through the runtime's renderer, so a
                    // program that prints anything links it.
                    .Call => |call| {
                        const callee = m.funcById(call.func) orelse continue;
                        if (isPrintln(callee) or scalarIntrinsic(callee) == .print) uses_objects_hint = true;
                    },
                    else => {},
                }
            }
        }
    }

    try w.print(
        \\/* Generated by `klio transpile --native {s}`. Do not edit.
        \\ * The program, not a launcher for it: no image is loaded and no
        \\ * interpreter runs. Build: zig cc -O2 <this file> -o prog */
        \\#include <stdio.h>
        \\#include <stdint.h>
        \\#include <stdlib.h>
        \\#include <math.h>
        \\#include <inttypes.h>
        \\#include <setjmp.h>
        \\
    , .{src_path});
    // Every hint is in: a program that prints, throws, holds a global or
    // dispatches needs the runtime, and the header has to say so before the
    // first declaration that uses it.
    if (uses_objects_hint) uses_objects = true;
    if (uses_objects) {
        try w.writeAll(
            \\#include <klio_rt.h>
            \\
            \\
        );
        for (used_classes.items) |cid| try w.print("static uint32_t KCLS_{d};\n", .{cid});
        for (used_lambdas.items) |lu| try w.print("static uint32_t KLAM_{d};\n", .{lu.body.int()});
        // The starter a lambda that suspends is registered under, declared
        // before the registration that names it.
        for (used_lambdas.items) |lu| {
            for (accepted.items) |*cc| {
                if (cc.f.id != lu.body or !cc.suspends) continue;
                try w.print("static klio_value kcs_{d}(klio_value self);\n", .{lu.body.int()});
            }
        }
        try w.writeAll("\nstatic void klio_register_classes(void) {\n");
        for (used_classes.items) |cid| {
            const cdef = &m.classes.items[cid];
            const fields = prog.of(cid).?;
            try w.print("  {{ static const char *const fn[] = {{", .{});
            for (fields, 0..) |fld, i| {
                if (i != 0) try w.writeAll(", ");
                try w.writeByte('"');
                try w.writeAll(fld.name);
                try w.writeByte('"');
            }
            if (fields.len == 0) try w.writeAll("0");
            // The primary constructor's properties are the fields this class
            // contributes from its own arguments: the parent's come first and
            // belong to the parent.
            var plo: u32 = 0;
            var phi: u32 = 0;
            for (fields, 0..) |fld2, fi2| {
                if (fld2.from_parent or fld2.arg == null) continue;
                if (phi == 0) plo = @intCast(fi2);
                phi = @intCast(fi2 + 1);
            }
            var flags: u32 = 0;
            if (layoutFor(prog.layouts, cdef)) |l2| {
                if (l2.is_data) flags |= 1;
            }
            if (cdef.is_enum) flags |= 2;
            if (cdef.is_object) flags |= 4;
            try w.writeAll("};\n    static const unsigned char fz[] = {");
            for (fields, 0..) |fld3, fz_i| {
                if (fz_i != 0) try w.writeAll(", ");
                try w.print("{d}", .{zeroKindOf(fld3.ty)});
            }
            if (fields.len == 0) try w.writeAll("0");
            try w.writeAll("};\n");
            try w.print("    KCLS_{d} = klio_nat_class(\"{s}\", {d}, fn, {d}, {d}, {d}, fz); }}\n", .{
                cid, cdef.name, fields.len, plo, phi, flags,
            });
        }
        for (used_lambdas.items) |lu| {
            try w.print("  {{ static const char *const fn[] = {{", .{});
            var ci7: u32 = 0;
            while (ci7 < lu.n_caps) : (ci7 += 1) {
                if (ci7 != 0) try w.writeAll(", ");
                try w.print("\"k{d}\"", .{ci7});
            }
            if (lu.n_caps == 0) try w.writeAll("0");
            try w.print("}}; KLAM_{d} = klio_nat_class(\"Function{d}\", {d}, fn, 0, 0, 0, 0); }}\n", .{ lu.body.int(), lu.arity, lu.n_caps });
            for (accepted.items) |*cc| {
                if (cc.f.id != lu.body) continue;
                if (!cc.suspends) continue;
                try w.print("  klio_nat_coro_starter(KLAM_{d}, kcs_{d});\n", .{ lu.body.int(), lu.body.int() });
            }
        }
        try w.writeAll("}\n\n");
    }
    if (uses_try) try w.writeAll(
        \\/* A try region. The handler stack and the in-flight value live here rather
        \\ * than in the runtime: `setjmp` has to be called in the frame that catches,
        \\ * so it cannot hide behind a function. Single-threaded, like the programs
        \\ * this backend accepts so far. */
        \\typedef struct klio_try { struct klio_try *prev; jmp_buf jb; } klio_try;
        \\static klio_try *klio_try_top = 0;
        \\static klio_value klio_in_flight;
        \\static klio_nat_frame klio_in_flight_frame;
        \\static void klio_try_arm(klio_try *t) { t->prev = klio_try_top; klio_try_top = t; }
        \\static void klio_try_disarm(void) { if (klio_try_top) klio_try_top = klio_try_top->prev; }
        \\KLIO_NORETURN static void klio_do_throw(klio_value e) {
        \\  if (klio_try_top) { klio_in_flight = e; longjmp(klio_try_top->jb, 1); }
        \\  klio_nat_throw(e);
        \\}
        \\
        \\
    );
    if (needs_cast) {
        // A failed `as` is a ClassCastException, a real throwable a handler in
        // the same program can catch.
        const cce = prog.throws.find("ClassCastException");
        try w.print(
            \\KLIO_NORETURN static void klio_cast_fail(const char *ty, size_t n) {{
            \\  {s}(klio_nat_exception("kotlin.ClassCastException",
            \\      klio_nat_string(ty, n), {d}));
            \\}}
            \\
            \\
        , .{ if (uses_try) "klio_do_throw" else "klio_nat_throw", if (cce) |t| t.lo else 0 });
    }
    if (needs_div) {
        // Kotlin THROWS on integer division by zero; C leaves it undefined.
        // It is a real throwable, so a `catch` in compiled code sees it and
        // an uncaught one is reported by the runtime, in the one place that
        // knows how a throwable reads.
        const az = prog.throws.find("ArithmeticException");
        try w.print(
            \\KLIO_NORETURN static void klio_arith_zero(void) {{
            \\  {s}(klio_nat_exception("kotlin.ArithmeticException",
            \\      klio_nat_string("/ by zero", 9), {d}));
            \\}}
            \\
            \\
        , .{ if (uses_try) "klio_do_throw" else "klio_nat_throw", if (az) |t| t.lo else 0 });
    }


    if (used_singletons.items.len != 0) {
        try w.print("\n/* `object` declarations: one instance each, built before the program\n" ++
            " * runs and rooted for its whole life. */\n", .{});
        try w.print("static klio_value KO[{d}];\n", .{used_singletons.items.len});
        try w.print("static klio_nat_frame KOF;\n", .{});
    }
    {
        var n_ls: usize = 0;
        for (used_lambdas.items) |lu| {
            if (lu.n_caps == 0) n_ls += 1;
        }
        if (n_ls != 0) {
            try w.print("\n/* A lambda literal that captures nothing is a SINGLETON in Kotlin:\n" ++
                " * every evaluation of the same literal yields the same instance, so\n" ++
                " * `===` holds across evaluations. One instance each, rooted for the\n" ++
                " * life of the program. */\n", .{});
            try w.print("static klio_value KL[{d}];\n", .{n_ls});
            try w.print("static klio_nat_frame KLF;\n", .{});
        }
    }
    if (used_globals.items.len != 0) {
        try w.print("\n/* Top-level properties. Published to the collector for the life of the\n" ++
            " * program: a global is a root, not a frame slot. */\n", .{});
        try w.print("static klio_value KG[{d}];\n", .{used_globals.items.len});
        try w.print("static klio_nat_frame KGF;\n", .{});
    }

    // Prototypes first: the call graph has cycles (recursion, mutual calls),
    // and a dispatcher is defined after the bodies it selects between.
    for (accepted.items) |*c| {
        try writeProto(w, c);
        try w.writeAll(";\n");
        // The continuation a suspend body is re-entered through.
        if (c.suspends) {
            try w.print("static klio_value kco_{d}(void *fp, klio_value resumed);\n", .{c.f.id.int()});
            try w.print("static void *kcf_{d}(", .{c.f.id.int()});
            if (c.params.len == 0 and c.caps.len == 0) {
                try w.writeAll("void");
            } else {
                for (c.caps, 0..) |ct, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.print("{s}", .{ct.ty.cName()});
                }
                for (c.params, 0..) |p, i| {
                    if (i != 0 or c.caps.len != 0) try w.writeAll(", ");
                    try w.print("{s}", .{(tyOf(p.ty) orelse Ty.object).cName()});
                }
            }
            try w.writeAll(");\n");
        }
    }
    for (used_slots.items) |su| {
        const root = m.funcById(ir.FuncId.from(su.slot)).?;
        const rt6 = funcRetTy2(m, root) orelse .unit;
        try w.print("static {s} kvirt_{d}(klio_value recv", .{ rt6.cName(), su.slot });
        var ai3: u32 = 0;
        while (ai3 < su.n_args) : (ai3 += 1) {
            const pt3: Ty = if (ai3 + 1 < root.params.len) (tyOf(root.params[ai3 + 1].ty) orelse .object) else .object;
            try w.print(", {s} a{d}", .{ pt3.cName(), ai3 });
        }
        try w.writeAll(");\n");
    }
    for (ctor_classes.items) |cid| {
        try writeCtorProto(w, m, cid);
        try w.writeAll(";\n");
    }
    for (used_props.items) |pu| {
        var mb: [96]u8 = undefined;
        try w.print("static {s} kprop_{d}_{s}(klio_value recv);\n", .{
            pu.ret.cName(), pu.cid, mangleName(pu.name, &mb),
        });
    }

    // One adapter per materialised lambda, and one dispatcher per arity called
    // through a value. A function value's arguments and result pass boxed,
    // because which body runs is a run-time answer and two bodies of the same
    // arity need not agree on machine types.
    for (used_lambdas.items) |lu| {
        try w.print("static klio_value klam_{d}(klio_value self", .{lu.body.int()});
        var ai7: u32 = 0;
        while (ai7 < lu.arity) : (ai7 += 1) try w.print(", klio_value a{d}", .{ai7});
        try w.writeAll(");\n");
    }
    {
        var seen_ar: [FUNC_MAX_ARITY + 1]bool = @splat(false);
        for (used_lambdas.items) |lu| {
            if (seen_ar[lu.arity]) continue;
            seen_ar[lu.arity] = true;
            try w.print("static klio_value klam_call_{d}(klio_value f", .{lu.arity});
            var ai8: u32 = 0;
            while (ai8 < lu.arity) : (ai8 += 1) try w.print(", klio_value a{d}", .{ai8});
            try w.writeAll(");\n");
        }
    }
    try w.writeAll("\n");
    for (accepted.items) |*c| try writeBody(gpa, w, m, prog, c, uses_objects, used_globals.items, used_singletons.items, used_slots.items, uses_try, accepted.items, used_classes.items, used_lambdas.items);

    for (used_slots.items) |su| {
        const root = m.funcById(ir.FuncId.from(su.slot)).?;
        const rt5 = funcRetTy2(m, root) orelse .unit;
        try w.print("\n/* Virtual dispatch for `{s}`. Which body runs is the receiver's\n" ++
            " * class, compared here against the handles registered at startup —\n" ++
            " * they are runtime values, so this is a chain and not a switch. */\n", .{root.name});
        try w.print("static {s} kvirt_{d}(klio_value recv", .{ rt5.cName(), su.slot });
        var ai: u32 = 0;
        while (ai < su.n_args) : (ai += 1) {
            const pt2: Ty = if (ai + 1 < root.params.len) (tyOf(root.params[ai + 1].ty) orelse .object) else .object;
            try w.print(", {s} a{d}", .{ pt2.cName(), ai });
        }
        // A slot no constructed class answers still needs a body: the call
        // site is reachable, and reaching it means no receiver implements the
        // method.
        try w.writeAll(") {\n  uint32_t k = klio_nat_class_of(recv);\n  (void)k;\n");
        for (used_classes.items) |cid| {
            const impl = slotImpl(m, prog, cid, ir.MethodSlotId.from(su.slot)) orelse continue;
            var in_set = false;
            for (accepted.items) |*cc| {
                if (cc.f == impl) in_set = true;
            }
            if (!in_set) continue;
            // The implementation may declare more parameters than the call
            // site supplies: an override can carry defaults the site omits.
            // Those run their thunks here, handed what came before them.
            try w.print("  if (k == KCLS_{d}) {{\n", .{cid});
            var dk9: u32 = su.n_args + 1;
            while (dk9 < impl.params.len) : (dk9 += 1) {
                // The default may be declared where the method is DECLARED
                // rather than where its body is: an interface can carry the
                // default for a method a superclass implements.
                const dfid9 = prog.defaultThunk(impl.id, dk9) orelse
                    prog.defaultThunk(root.id, dk9) orelse break;
                const dfn9 = m.funcById(dfid9) orelse break;
                const dt9 = acceptedRet(accepted.items, dfn9) orelse funcRetTy2(m, dfn9) orelse .unit;
                var dsym9: std.Io.Writer.Allocating = .init(gpa);
                defer dsym9.deinit();
                try writeSymbol(&dsym9.writer, dfn9);
                try w.print("    {s} vd{d} = {s}(recv", .{ dt9.cName(), dk9, dsym9.written() });
                var pk9: u32 = 1;
                while (pk9 < dk9) : (pk9 += 1) {
                    if (pk9 <= su.n_args) {
                        try w.print(", a{d}", .{pk9 - 1});
                    } else {
                        try w.print(", vd{d}", .{pk9});
                    }
                }
                try w.writeAll(");\n");
            }
            if (dk9 != impl.params.len) {
                // A parameter with no default and no argument: nothing can
                // fill it, so this receiver cannot answer at all. Leaving the
                // arm empty would let the call fall through to the
                // no-implementation tail at run time, which is a wrong answer
                // rather than a refusal.
                if (traceOn()) std.debug.print("[cgen] refuse {s}: dispatcher arm cannot fill a parameter of `{s}`\n", .{ root.name, impl.fqn });
                return false;
            }
            try w.writeAll("    return ");
            try writeSymbol(w, impl);
            try w.writeAll("(recv");
            var aj: u32 = 1;
            while (aj < impl.params.len) : (aj += 1) {
                if (aj <= su.n_args) {
                    try w.print(", a{d}", .{aj - 1});
                } else {
                    try w.print(", vd{d}", .{aj});
                }
            }
            try w.writeAll(");\n  }\n");
        }
        try w.print("  klio_nat_no_method(\"{s}\");\n", .{root.name});
        // `klio_nat_no_method` does not return, but C does not know that from
        // the declaration alone, so give the function a value to fall off with.
        if (rt5 == .object) {
            try w.writeAll("  return klio_nat_box_unit();\n");
        } else {
            try w.writeAll("  return 0;\n");
        }
        try w.writeAll("}\n");
    }
    if (ctor_classes.items.len != 0) try w.writeAll("\n");
    for (ctor_classes.items) |cid| try writeCtorBody(gpa, w, m, prog, cid);
    if (ctor_classes.items.len != 0) try w.writeAll("\n");
    // A lambda that suspends and can be handed to `launch` needs a starter:
    // the driver is given the closure VALUE and has to find the code.
    for (used_lambdas.items) |lu| {
        const sc9 = blk10: {
            for (accepted.items) |*cc| {
                if (cc.f.id == lu.body) break :blk10 cc;
            }
            return false;
        };
        if (!sc9.suspends) continue;
        try w.print("static klio_value kcs_{d}(klio_value self) {{\n  return kco_{d}(kcf_{d}(", .{
            lu.body.int(), lu.body.int(), lu.body.int(),
        });
        for (sc9.caps, 0..) |ct9, ci9| {
            if (ci9 != 0) try w.writeAll(", ");
            var gb10: [96]u8 = undefined;
            const g10 = try std.fmt.bufPrint(&gb10, "klio_nat_get(self, {d})", .{ci9});
            var ob12: [200]u8 = undefined;
            try w.print("{s}", .{unboxExpr(ct9.ty, g10, &ob12)});
        }
        for (sc9.params, 0..) |p10, pi10| {
            if (pi10 != 0 or sc9.caps.len != 0) try w.writeAll(", ");
            const pt10: Ty = tyOf(p10.ty) orelse .object;
            var zb10: [64]u8 = undefined;
            try w.print("{s}", .{if (pt10 == .object) "klio_nat_box_unit()" else boxExpr(.unit, "0", &zb10)});
        }
        try w.writeAll("), klio_nat_box_unit());\n}\n");
    }
    for (used_lambdas.items) |lu| {
        const bc2 = blk9: {
            for (accepted.items) |*cc| {
                if (cc.f.id == lu.body) break :blk9 cc;
            }
            return false;
        };
        try w.print("static klio_value klam_{d}(klio_value self", .{lu.body.int()});
        var ai9: u32 = 0;
        while (ai9 < lu.arity) : (ai9 += 1) try w.print(", klio_value a{d}", .{ai9});
        try w.writeAll(") {\n");
        if (lu.n_caps == 0) try w.writeAll("  (void)self;\n");
        // The lowering always gives a lambda an `it` slot, so a body can
        // declare fewer parameters than its type takes.
        var av9: u32 = 0;
        while (av9 < lu.arity) : (av9 += 1) try w.print("  (void)a{d};\n", .{av9});
        var call9: std.Io.Writer.Allocating = .init(gpa);
        defer call9.deinit();
        try writeSymbol(&call9.writer, bc2.f);
        try call9.writer.writeByte('(');
        for (bc2.caps, 0..) |ct9, ci9| {
            if (ci9 != 0) try call9.writer.writeAll(", ");
            var gb9: [96]u8 = undefined;
            const g9 = try std.fmt.bufPrint(&gb9, "klio_nat_get(self, {d})", .{ci9});
            var ob10: [200]u8 = undefined;
            try call9.writer.print("{s}", .{unboxExpr(ct9.ty, g9, &ob10)});
        }
        for (bc2.params, 0..) |p9, pi9| {
            if (pi9 != 0 or bc2.caps.len != 0) try call9.writer.writeAll(", ");
            const pt9: Ty = tyOf(p9.ty) orelse .object;
            var ab10: [16]u8 = undefined;
            // The lowering always gives a lambda an `it` slot, so a body may
            // declare a parameter the call never supplies; it gets the type's
            // zero, which is unreachable in a lambda that declares none.
            const src10 = if (pi9 < lu.arity)
                try std.fmt.bufPrint(&ab10, "a{d}", .{pi9})
            else
                "klio_nat_box_unit()";
            var ob11: [200]u8 = undefined;
            try call9.writer.print("{s}", .{unboxExpr(pt9, src10, &ob11)});
        }
        try call9.writer.writeByte(')');
        var bb15: [400]u8 = undefined;
        try w.print("  return {s};\n}}\n", .{boxExpr(bc2.ret, call9.written(), &bb15)});
    }
    {
        var seen_ar2: [FUNC_MAX_ARITY + 1]bool = @splat(false);
        for (used_lambdas.items) |lu| {
            if (seen_ar2[lu.arity]) continue;
            seen_ar2[lu.arity] = true;
            try w.print("static klio_value klam_call_{d}(klio_value f", .{lu.arity});
            var ai10: u32 = 0;
            while (ai10 < lu.arity) : (ai10 += 1) try w.print(", klio_value a{d}", .{ai10});
            try w.writeAll(") {\n  uint32_t k = klio_nat_class_of(f);\n  (void)k;\n");
            for (used_lambdas.items) |lu2| {
                if (lu2.arity != lu.arity) continue;
                try w.print("  if (k == KLAM_{d}) return klam_{d}(f", .{ lu2.body.int(), lu2.body.int() });
                var aj10: u32 = 0;
                while (aj10 < lu.arity) : (aj10 += 1) try w.print(", a{d}", .{aj10});
                try w.writeAll(");\n");
            }
            try w.writeAll("  klio_nat_no_method(\"invoke\");\n  return klio_nat_box_unit();\n}\n");
            // The same dispatcher in the uniform shape a stdlib entry calls
            // back through: `forEach` and its kind hand the runtime a closure
            // VALUE and an argument array.
            try w.print("static klio_value klam_inv_{d}(klio_value f, const klio_value *a) {{\n  (void)a;\n  return klam_call_{d}(f", .{ lu.arity, lu.arity });
            var ai11: u32 = 0;
            while (ai11 < lu.arity) : (ai11 += 1) try w.print(", a[{d}]", .{ai11});
            try w.writeAll(");\n}\n");
        }
    }
    for (used_props.items) |pu| {
        var mb2: [96]u8 = undefined;
        try w.print("static {s} kprop_{d}_{s}(klio_value recv) {{\n  uint32_t k = klio_nat_class_of(recv);\n  (void)k;\n", .{
            pu.ret.cName(), pu.cid, mangleName(pu.name, &mb2),
        });
        for (used_classes.items) |cid2| {
            if (!typeReaches(m, cid2, pu.cid)) continue;
            if (prog.accessor(m, cid2, pu.name, .get)) |g2| {
                const gfn2 = m.funcById(g2) orelse continue;
                var in_set2 = false;
                for (accepted.items) |*cc2| {
                    if (cc2.f == gfn2) in_set2 = true;
                }
                if (!in_set2) continue;
                try w.print("  if (k == KCLS_{d}) return ", .{cid2});
                try writeSymbol(w, gfn2);
                try w.writeAll("(recv);\n");
                continue;
            }
            const fi6 = fieldIndex(prog, cid2, pu.name) orelse continue;
            var gb6: [96]u8 = undefined;
            const g6 = try std.fmt.bufPrint(&gb6, "klio_nat_get(recv, {d})", .{fi6});
            var ob6: [160]u8 = undefined;
            try w.print("  if (k == KCLS_{d}) return {s};\n", .{ cid2, unboxExpr(pu.ret, g6, &ob6) });
        }
        try w.print("  klio_nat_no_method(\"{s}\");\n", .{pu.name});
        if (pu.ret == .object) {
            try w.writeAll("  return klio_nat_box_unit();\n}\n");
        } else {
            try w.writeAll("  return 0;\n}\n");
        }
    }
    if (used_lambdas.items.len != 0) try w.writeAll("\n");
    if (used_singletons.items.len != 0) {
        try w.writeAll("static void klio_init_singletons(void) {\n");
        try w.print("  for (unsigned i = 0; i < {d}; i++) KO[i] = klio_nat_box_unit();\n", .{used_singletons.items.len});
        try w.print("  KOF.n = {d}; KOF.slots = KO; klio_nat_enter(&KOF);\n", .{used_singletons.items.len});
        for (used_singletons.items, 0..) |su4, oi| {
            try w.print("  KO[{d}] = klio_nat_alloc_instance(KCLS_{d});\n", .{ oi, su4.cid });
            const ei = su4.entry orelse {
                try w.print("  kinit_{d}(KO[{d}]);\n", .{ su4.cid, oi });
                continue;
            };
            // An enum entry carries its own name and position, then runs the
            // enum's constructor with the arguments its declaration writes.
            const ents2 = enumEntries(m, prog, su4.cid);
            try w.print("  klio_nat_set(KO[{d}], 0, klio_nat_string(\"{s}\", {d}));\n", .{ oi, ents2[ei].name, ents2[ei].name.len });
            try w.print("  klio_nat_set(KO[{d}], 1, klio_nat_box_int({d}));\n", .{ oi, ei });
            const edef = &m.classes.items[su4.cid];
            try w.print("  kinit_{d}(KO[{d}]", .{ su4.cid, oi });
            for (edef.primary_params, 0..) |_, pi| {
                try w.writeAll(", ");
                const want = ctorParamTy(edef, pi);
                if (pi >= ents2[ei].args.len) {
                    try w.print("{s}", .{if (want == .object) "klio_nat_null()" else "0"});
                    continue;
                }
                const afn = m.funcById(ents2[ei].args[pi]).?;
                var sym4: std.Io.Writer.Allocating = .init(gpa);
                defer sym4.deinit();
                try writeSymbol(&sym4.writer, afn);
                var cb5: [220]u8 = undefined;
                const call5 = if (afn.has_receiver_param)
                    try std.fmt.bufPrint(&cb5, "{s}(KO[{d}])", .{ sym4.written(), oi })
                else
                    try std.fmt.bufPrint(&cb5, "{s}()", .{sym4.written()});
                const have5 = funcRetTy2(m, afn) orelse want;
                var bx5: [300]u8 = undefined;
                if (want == .object and have5 != .object) {
                    try w.print("{s}", .{boxExpr(have5, call5, &bx5)});
                } else {
                    try w.print("{s}", .{call5});
                }
            }
            try w.writeAll(");\n");
        }
        try w.writeAll("}\n\n");
    }
    if (used_globals.items.len != 0) {
        try w.writeAll("static void klio_init_globals(void) {\n");
        try w.print("  for (unsigned i = 0; i < {d}; i++) KG[i] = klio_nat_box_unit();\n", .{used_globals.items.len});
        try w.print("  KGF.n = {d}; KGF.slots = KG; klio_nat_enter(&KGF);\n", .{used_globals.items.len});
        for (used_globals.items, 0..) |g, i| {
            const gf = m.funcById(g.func).?;
            var acc_i: ?usize = null;
            for (accepted.items, 0..) |*cc, ci| {
                if (cc.f == gf) acc_i = ci;
            }
            const gt = accepted.items[acc_i.?].ret;
            var bb: [96]u8 = undefined;
            var call_buf: [160]u8 = undefined;
            var sym: std.Io.Writer.Allocating = .init(gpa);
            defer sym.deinit();
            try writeSymbol(&sym.writer, gf);
            const call = try std.fmt.bufPrint(&call_buf, "{s}()", .{sym.written()});
            try w.print("  KG[{d}] = {s};\n", .{ i, boxExpr(gt, call, &bb) });
        }
        try w.writeAll("}\n\n");
    }

    try w.writeAll("int main(void) {\n");
    if (uses_objects) try w.writeAll("  klio_nat_init(0);\n  klio_register_classes();\n");
    if (uses_try) try w.writeAll(
        "  klio_in_flight = klio_nat_box_unit();\n" ++
        "  klio_in_flight_frame.n = 1; klio_in_flight_frame.slots = &klio_in_flight;\n" ++
        "  klio_nat_enter(&klio_in_flight_frame);\n",
    );
    {
        // Every arity a closure can be called through, registered so a stdlib
        // entry that takes a lambda can reach compiled code.
        var seen_ar3: [FUNC_MAX_ARITY + 1]bool = @splat(false);
        for (used_lambdas.items) |lu| {
            if (seen_ar3[lu.arity]) continue;
            seen_ar3[lu.arity] = true;
            try w.print("  klio_nat_lambda_invoker({d}, klam_inv_{d});\n", .{ lu.arity, lu.arity });
        }
    }
    {
        var n_ls3: usize = 0;
        for (used_lambdas.items) |lu| {
            if (lu.n_caps == 0) n_ls3 += 1;
        }
        if (n_ls3 != 0) {
            // A lambda literal that captures nothing has ONE instance for the
            // life of the program, built here and rooted.
            try w.print("  for (unsigned i = 0; i < {d}; i++) KL[i] = klio_nat_box_unit();\n", .{n_ls3});
            try w.print("  KLF.n = {d}; KLF.slots = KL; klio_nat_enter(&KLF);\n", .{n_ls3});
            var li3: usize = 0;
            for (used_lambdas.items) |lu| {
                if (lu.n_caps != 0) continue;
                try w.print("  KL[{d}] = klio_nat_alloc_instance(KLAM_{d});\n", .{ li3, lu.body.int() });
                li3 += 1;
            }
        }
    }
    if (used_singletons.items.len != 0) try w.writeAll("  klio_init_singletons();\n");
    if (used_globals.items.len != 0) {
        // Top-level properties run their initializers in declaration order,
        // which is the order the interpreter runs them in, and BEFORE the
        // permanent phase ends: a global outlives every collection.
        try w.writeAll("  klio_init_globals();\n");
    }
    if (uses_objects) try w.writeAll("  klio_nat_begin();\n");
    try w.writeAll("  ");
    try writeSymbol(w, entry);
    try w.writeAll("();\n  return 0;\n}\n");
    return true;
}
