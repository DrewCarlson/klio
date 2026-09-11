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
    if (classIndexOfName(m, f.return_ty) != null) return .object;
    return null;
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
        // A string literal is a reference like any other: it lives in the
        // published frame so the collector can see it.
        .String => .object,
        .Null => .object,
        else => null,
    };
}

/// A conversion's receiver has to be a number: `x.toLong()` on a reference is
/// a call, not a C cast.
fn isNumericTy(t: Ty) bool {
    return switch (t) {
        .i32, .i64, .f64, .f32, .char, .short, .byte => true,
        else => false,
    };
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
fn isBuiltinCls(cid: u32) bool {
    return cid == STRING_CLS or cid == LIST_CLS or cid == CELL_CLS or cid == THROWABLE_CLS;
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
    /// Frame slot of each object register, or -1 for a scalar in a C local.
    slot: []i32,
    n_slots: u32,
    ret: Ty,

    pub fn deinit(self: *Compiled, gpa: std.mem.Allocator) void {
        gpa.free(self.types);
        gpa.free(self.cls);
        gpa.free(self.elem);
        gpa.free(self.lam);
        gpa.free(self.slot);
    }
};

/// The instance fields of a class, in the order the runtime lays them out:
/// the primary-constructor parameters that double as properties. A class this
/// returns null for is one the emitter cannot lay out, and any program touching
/// it is refused.
/// Every class's resolved layout, indexed by class id. Computed once, because
/// resolving a layout walks the class table and the emitter asks about the
/// same classes repeatedly.
pub const Layouts = struct {
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

    fn of(self: Layouts, cid: u32) ?[]const FieldInfo {
        if (cid >= self.fields.len) return null;
        return self.fields[cid];
    }

    fn parentOf(self: Layouts, cid: u32) ?Parent {
        if (cid >= self.parents.len) return null;
        return self.parents[cid];
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
    /// The constructor argument that fills it, or null when a thunk does.
    arg: ?u32,
    init: ?ir.FuncId,
    /// True when a superclass declares this field. The superclass's own
    /// initializer fills it, so this class's does not.
    from_parent: bool = false,
};

/// A class's flattened fields plus the superclass link used to initialize them.
const Laid = struct { fields: []FieldInfo, parent: ?Parent };

/// A class's instance fields in layout order: the constructor properties first,
/// then the properties declared in the body. A class this returns null for is
/// one the emitter cannot lay out, and any program touching it is refused.
fn classFields(gpa: std.mem.Allocator, m: *const Module, layouts: []const ClassLayout, cid: ir.ClassId) Error!?Laid {
    return classFieldsAt(gpa, m, layouts, cid, 0);
}

fn classFieldsAt(gpa: std.mem.Allocator, m: *const Module, layouts: []const ClassLayout, cid: ir.ClassId, depth: u32) Error!?Laid {
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
    if (c.is_enum) return layoutNo(c, "enum");
    // An `object` declares no constructor; its fields are its body properties
    // and its single instance is created once, before the program runs.
    if (c.is_object and c.primary_params.len != 0) return layoutNo(c, "object with constructor params");
    if (c.is_inner) return layoutNo(c, "inner class");

    var out: std.ArrayList(FieldInfo) = .empty;
    errdefer out.deinit(gpa);
    var parent: ?Parent = null;
    if (parent_id) |sid| {
        // The superclass's fields come first and keep their own layout, so a
        // field read through the base type and through this one address the
        // same slot. Its initializer fills them, handed the arguments this
        // class's thunks compute.
        const up = (try classFieldsAt(gpa, m, layouts, sid, depth + 1)) orelse {
            out.deinit(gpa);
            return layoutNo(c, "superclass layout");
        };
        defer gpa.free(up.fields);
        const sup = &m.classes.items[sid.int()];
        var pargs: []const ir.FuncId = &.{};
        for (layouts) |l| {
            if (std.mem.eql(u8, l.name, c.name)) pargs = l.parent_args;
        }
        if (pargs.len != sup.primary_params.len) {
            out.deinit(gpa);
            return layoutNo(c, "super constructor arity");
        }
        for (up.fields) |fd| {
            try out.append(gpa, .{
                .name = fd.name,
                .ty = fd.ty,
                .cls = fd.cls,
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
        if (p.default != null or p.is_vararg) {
            out.deinit(gpa);
            return layoutNo(c, "ctor param default/vararg");
        }
        const t = tyOf(p.ty) orelse blk: {
            if (classIndexOfName(m, p.ty) == null) {
                out.deinit(gpa);
                return layoutNoTy(c, "ctor param type", p.ty);
            }
            break :blk Ty.object;
        };
        try out.append(gpa, .{
            .name = p.name,
            .ty = t,
            .cls = if (t == .object) classIndexOfName(m, p.ty) else null,
            .arg = @intCast(i),
            .init = null,
        });
    }
    for (layouts) |l| {
        if (!std.mem.eql(u8, l.name, c.name)) continue;
        for (l.props) |bp| {
            const fid = bp.init orelse {
                out.deinit(gpa);
                return layoutNo(c, "body property without an initializer");
            };
            const t = tyOf(bp.ty) orelse blk: {
                if (bp.ty.name.len == 0 or classIndexOfName(m, bp.ty) == null) {
                    out.deinit(gpa);
                    return layoutNoTy(c, "body property type", bp.ty);
                }
                break :blk Ty.object;
            };
            try out.append(gpa, .{
                .name = bp.name,
                .ty = t,
                .cls = if (t == .object) classIndexOfName(m, bp.ty) else null,
                .arg = null,
                .init = fid,
            });
        }
        break;
    }
    return .{ .fields = try out.toOwnedSlice(gpa), .parent = parent };
}

/// A property access inside the declaring class carries a synthesized accessor
/// name (`$sgetter$<Class><US><field>`); the stored field is the tail.
fn plainFieldName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "$sgetter$") or std.mem.startsWith(u8, name, "$ssetter$")) {
        if (std.mem.lastIndexOfScalar(u8, name, 0x1f)) |i| return name[i + 1 ..];
    }
    return name;
}

/// The index of a named field, which is what compiled code addresses.
fn fieldIndex(ls: Layouts, cid: u32, name: []const u8) ?u32 {
    const fields = ls.of(cid) orelse return null;
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

/// The member name a virtual slot dispatches to, for the builtin receivers
/// whose members the backend performs directly.
/// The method of `cls` that implements a virtual slot. A slot is numbered by
/// its root declaration, so the implementation is the class's method of the
/// same name and arity — which is what an override is.
fn slotImpl(m: *const Module, cid: u32, slot: ir.MethodSlotId) ?*const Func {
    const root = m.funcById(ir.FuncId.from(slot.int())) orelse return null;
    if (cid >= m.classes.items.len) return null;
    for (m.classes.items[cid].methods) |fid| {
        const mf = m.funcById(fid) orelse continue;
        if (!std.mem.eql(u8, mf.name, root.name)) continue;
        if (mf.params.len != root.params.len) continue;
        if (!mf.hasBody()) continue;
        return mf;
    }
    return null;
}

/// One virtual call site's shape: the slot and how many arguments it takes.
const SlotUse = struct { slot: u32, n_args: u32 };

fn listMemberName(m: *const Module, slot: ir.MethodSlotId) ?[]const u8 {
    const decl = m.funcById(ir.FuncId.from(slot.int())) orelse return null;
    return decl.name;
}

fn isPrintln(f: *const Func) bool {
    return f.params.len == 1 and
        (std.mem.eql(u8, f.fqn, "kotlin.io.println") or std.mem.eql(u8, f.fqn, "println"));
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
fn globalTy(gpa: std.mem.Allocator, m: *const Module, ls: Layouts, globals: []const Global, idx: usize) Error!?Ty {
    const gf = m.funcById(globals[idx].func) orelse return null;
    var c = (try eligible(gpa, m, ls, gf, globals, null, &.{})) orelse return null;
    defer c.deinit(gpa);
    return c.ret;
}

/// The class id of an `object` declaration with this name, when the emitter can
/// lay it out. Such a name reads as its single instance rather than as storage.
fn objectClassNamed(m: *const Module, ls: Layouts, name: []const u8) ?u32 {
    for (m.classes.items, 0..) |*c, i| {
        if (!c.is_object) continue;
        if (!std.mem.eql(u8, c.name, name) and !std.mem.eql(u8, c.fqn, name)) continue;
        if (ls.of(@intCast(i)) == null) return null;
        return @intCast(i);
    }
    return null;
}

fn isDispatched(slots: []const SlotUse, slot: u32) bool {
    for (slots) |u| {
        if (u.slot == slot) return true;
    }
    return false;
}

fn singletonSlot(singletons: []const u32, cid: u32) ?usize {
    for (singletons, 0..) |s2, i| {
        if (s2 == cid) return i;
    }
    return null;
}

fn globalIndex(globals: []const Global, name: []const u8) ?usize {
    for (globals, 0..) |g, i| {
        if (std.mem.eql(u8, g.name, name)) return i;
    }
    return null;
}

pub fn eligible(gpa: std.mem.Allocator, m: *const Module, ls: Layouts, f: *const Func, globals: []const Global, synth: ?[]const ir.Param, caps: []const CapInfo) Error!?Compiled {
    // A synthesized thunk declares no parameters and reads its caller's
    // positionally, so it is compiled against the signature it will be handed.
    const params: []const ir.Param = synth orelse f.params;
    if (f.is_suspend) return no(f, "suspend");
    // A method is an ordinary function whose first parameter is the receiver;
    // the call sites already move it into arg 0.
    if (f.has_receiver_param and receiverClass(m, f) == null) return no(f, "receiver class");
    if (!f.hasBody() or f.blocks.len == 0) return no(f, "no body");
    if (f.n_locals == 0) return no(f, "no locals");

    // The declared return type is a starting point only. An unannotated
    // declaration (`var counter = 0` lowers to a thunk) carries a placeholder,
    // so the authority is the register the body actually returns; the declared
    // type settles the Unit case, where there is no register to ask.
    var ret = funcRetTy2(m, f) orelse Ty.unit;
    for (params) |p| {
        if (p.default != null or p.is_vararg) return no(f, "param default/vararg");
        if (tyOf(p.ty) == null and classIndexOfName(m, p.ty) == null) return no(f, "param type");
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
    const lam = try gpa.alloc(?LambdaInfo, f.n_locals);
    errdefer gpa.free(lam);
    @memset(lam, null);
    const slot = try gpa.alloc(i32, f.n_locals);
    errdefer gpa.free(slot);
    @memset(slot, -1);
    const known = try gpa.alloc(bool, f.n_locals);
    defer gpa.free(known);
    @memset(known, false);

    // One forward pass suffices: the lowering emits a register's definition
    // before every use, and a loop-carried register is defined ahead of the
    // back edge by the same rule.
    for (f.blocks) |*blk| {
        // A `finally` has to run on every exit from its region, including a
        // throw passing through; that is a separate shape from a handler.
        if (blk.finally != null) return no(f, "finally");
        for (blk.catches) |h| {
            if (h.exception_reg.int() >= f.n_locals) return no(f, "catch register");
            // The handler tests an interval, so the caught type has to be one
            // the program's throwable hierarchy places.
            if (ls.throws.find(h.type_name) == null) return no(f, "catch type");
            types[h.exception_reg.int()] = .object;
            cls[h.exception_reg.int()] = THROWABLE_CLS;
            known[h.exception_reg.int()] = true;
        }
        for (blk.insts) |*inst| {
            switch (inst.*) {
                .Trace => {},
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
                    elem[mk.dst.int()] = types[mk.src.int()];
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
                    if (types[cs.value.int()] != elem[cs.cell.int()]) return no(f, "cell value type");
                },
                .LoadCapture => |lc| {
                    if (lc.dst.int() >= f.n_locals or lc.idx >= caps.len) return no(f, "load capture");
                    types[lc.dst.int()] = caps[lc.idx].ty;
                    cls[lc.dst.int()] = caps[lc.idx].cls;
                    elem[lc.dst.int()] = caps[lc.idx].elem;
                    known[lc.dst.int()] = true;
                },
                .LoadParam => |lp| {
                    if (lp.dst.int() >= f.n_locals or lp.idx >= params.len) return no(f, "load param");
                    const pt = params[lp.idx].ty;
                    if (tyOf(pt)) |t| {
                        types[lp.dst.int()] = t;
                    } else {
                        types[lp.dst.int()] = .object;
                        cls[lp.dst.int()] = classIndexOfName(m, pt);
                        // `List<Int>` says what its elements are; a list whose
                        // element type is written down needs no inference.
                        if (cls[lp.dst.int()]) |rc| {
                            if (rc == LIST_CLS and pt.args.len == 1) {
                                if (tyOf(pt.args[0])) |et| elem[lp.dst.int()] = et;
                            }
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
                    // `ushr` has no C spelling of its own — it is a cast to
                    // unsigned around `>>` — so it is admitted here and written
                    // out below rather than looked up.
                    if (b.op != .UShr and cOp(b.op) == null) return no(f, "binop kind");
                    if (isCmp(b.op)) {
                        if (lt == .unit or rt == .unit) return null;
                        types[b.dst.int()] = .boolean;
                    } else if (isBitwise(b.op)) {
                        // Kotlin's shifts and bitwise ops are integer-only and
                        // take the LEFT operand's width.
                        if (lt.isFloat() or rt.isFloat() or lt == .unit or rt == .unit) return null;
                        if ((lt == .boolean) != (rt == .boolean)) return null;
                        types[b.dst.int()] = lt;
                    } else {
                        types[b.dst.int()] = promote(lt, rt) orelse return no(f, "binop operand types");
                    }
                    known[b.dst.int()] = true;
                },
                .UnOp => |u| {
                    if (u.dst.int() >= f.n_locals or u.operand.int() >= f.n_locals) return no(f, "unop reg");
                    if (!known[u.operand.int()]) return no(f, "unop operand");
                    const ot = types[u.operand.int()];
                    if (ot == .boolean or ot == .unit) return no(f, "unop operand type");
                    switch (u.op) {
                        .Neg, .Plus => {},
                        // `++`/`--` on a scalar register is a read-modify-write
                        // the lowering already splits; seeing one here means a
                        // shape this subset has not modelled.
                        .Inc, .Dec => return no(f, "inc/dec"),
                    }
                    types[u.dst.int()] = ot;
                    known[u.dst.int()] = true;
                },
                .Not => |n| {
                    if (n.dst.int() >= f.n_locals or n.src.int() >= f.n_locals) return no(f, "not reg");
                    if (!known[n.src.int()] or types[n.src.int()] != .boolean) return no(f, "not operand");
                    types[n.dst.int()] = .boolean;
                    known[n.dst.int()] = true;
                },
                .CallMember => |cm| {
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
                            cls[cm.dst.int()] = null;
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
                    const to = numConv(m, cm) orelse return instRefuse(f, inst);
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
                            cls[cv.dst.int()] = null;
                        } else if (std.mem.eql(u8, mn, "add") and cv.n_args == 1) {
                            types[cv.dst.int()] = .boolean;
                        } else if (std.mem.eql(u8, mn, "set") and cv.n_args == 2) {
                            if (types[a0] != .i32) return no(f, "list index type");
                            types[cv.dst.int()] = .object;
                            cls[cv.dst.int()] = null;
                        } else return no(f, "list virtual member");
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
                                var kk2: u32 = 0;
                                while (kk2 < cv.n_args) : (kk2 += 1) {
                                    const ar2 = cv.args.int() + kk2;
                                    if (ar2 >= f.n_locals or !known[ar2]) return no(f, "virtual arg");
                                }
                                if (cv.dst.int() >= f.n_locals) return no(f, "virtual dst");
                                types[cv.dst.int()] = rt4;
                                if (rt4 == .object) cls[cv.dst.int()] = classIndexOfName(m, root.return_ty);
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
                    if (ni.arg_names.len != 0) return no(f, "ctor arg names");
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
                    const fields = ls.of(ni.class.int()) orelse {
                        if (traceOn() and ni.class.int() < m.classes.items.len) {
                            layout_quiet = false;
                            if (try classFields(gpa, m, ls.layouts, ni.class)) |junk| gpa.free(junk.fields);
                            layout_quiet = true;
                        }
                        return no(f, "class layout");
                    };
                    if (m.classes.items[ni.class.int()].primary_params.len != ni.n_args) return no(f, "ctor arity");
                    for (fields) |fd| {
                        const ai = fd.arg orelse continue;
                        const ar = ni.args.int() + ai;
                        if (ar >= f.n_locals or !known[ar]) return no(f, "ctor arg");
                        if (types[ar] != fd.ty) return no(f, "ctor arg type");
                    }
                    if (ni.dst.int() >= f.n_locals) return no(f, "ctor dst");
                    types[ni.dst.int()] = .object;
                    cls[ni.dst.int()] = ni.class.int();
                    known[ni.dst.int()] = true;
                },
                .GetField => |gf| {
                    if (gf.receiver.int() >= f.n_locals or !known[gf.receiver.int()]) return no(f, "field receiver");
                    if (types[gf.receiver.int()] != .object) return no(f, "field on non-object");
                    const rc = cls[gf.receiver.int()] orelse return no(f, "field receiver class");
                    if (rc == STRING_CLS or rc == LIST_CLS) {
                        const snm = m.consts.items[gf.field.int()];
                        if (snm != .String) return no(f, "builtin member name");
                        const want: []const u8 = if (rc == STRING_CLS) "length" else "size";
                        if (!std.mem.eql(u8, plainFieldName(snm.String), want)) return no(f, "builtin member");
                        if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                        types[gf.dst.int()] = .i32;
                        known[gf.dst.int()] = true;
                        continue;
                    }
                    if (gf.field.int() >= m.consts.items.len) return no(f, "field name");
                    const nm = m.consts.items[gf.field.int()];
                    if (nm != .String) return no(f, "field name kind");
                    const idx = fieldIndex(ls, rc, nm.String) orelse return no(f, "field not laid out");
                    const fields = ls.of(rc).?;
                    if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                    types[gf.dst.int()] = fields[idx].ty;
                    cls[gf.dst.int()] = fields[idx].cls;
                    known[gf.dst.int()] = true;
                },
                .SetField => |sf| {
                    if (sf.receiver.int() >= f.n_locals or !known[sf.receiver.int()]) return no(f, "field receiver");
                    if (types[sf.receiver.int()] != .object) return no(f, "field on non-object");
                    const rc = cls[sf.receiver.int()] orelse return no(f, "field receiver class");
                    if (sf.field.int() >= m.consts.items.len) return no(f, "field name");
                    const nm = m.consts.items[sf.field.int()];
                    if (nm != .String) return no(f, "field name kind");
                    const idx = fieldIndex(ls, rc, nm.String) orelse return no(f, "field not laid out");
                    const fields = ls.of(rc).?;
                    if (sf.value.int() >= f.n_locals or !known[sf.value.int()]) return no(f, "field value");
                    if (types[sf.value.int()] != fields[idx].ty) return no(f, "field value type");
                },
                .LoadGlobal => |lg| {
                    if (lg.name.int() >= m.consts.items.len) return no(f, "global name");
                    const gn = m.consts.items[lg.name.int()];
                    if (gn != .String) return no(f, "global name kind");
                    if (objectClassNamed(m, ls, gn.String)) |oc| {
                        if (lg.dst.int() >= f.n_locals) return no(f, "singleton dst");
                        types[lg.dst.int()] = .object;
                        cls[lg.dst.int()] = oc;
                        known[lg.dst.int()] = true;
                        continue;
                    }
                    const gi = globalIndex(globals, gn.String) orelse return noName(f, "global not declared", gn.String);
                    if (lg.dst.int() >= f.n_locals) return no(f, "global dst");
                    const gt = (try globalTy(gpa, m, ls, globals, gi)) orelse return no(f, "global type");
                    types[lg.dst.int()] = gt;
                    if (gt == .object) {
                        const gf = m.funcById(globals[gi].func).?;
                        cls[lg.dst.int()] = classIndexOfName(m, gf.return_ty);
                    }
                    known[lg.dst.int()] = true;
                },
                .StoreGlobal => |sg| {
                    if (sg.name.int() >= m.consts.items.len) return no(f, "global name");
                    const gn = m.consts.items[sg.name.int()];
                    if (gn != .String) return no(f, "global name kind");
                    const gi = globalIndex(globals, gn.String) orelse return noName(f, "global not declared", gn.String);
                    if (sg.value.int() >= f.n_locals or !known[sg.value.int()]) return no(f, "global value");
                    const gt = (try globalTy(gpa, m, ls, globals, gi)) orelse return no(f, "global type");
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
                    // The value itself is never materialised while every use is
                    // a direct call; a lambda that escapes into a value is
                    // refused rather than silently losing its captures.
                    types[al.dst.int()] = .unit;
                    lam[al.dst.int()] = .{ .body = body, .captures = al.captures };
                    known[al.dst.int()] = true;
                },
                .CallValue => |cv2| {
                    if (cv2.arg_names.len != 0 or cv2.type_args.len != 0) return no(f, "value call names/type args");
                    if (cv2.callee.int() >= f.n_locals) return no(f, "value callee");
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
                    var bc = (try eligible(gpa, m, ls, bf, globals, null, ct2)) orelse return no(f, "lambda body");
                    const rt7 = bc.ret;
                    bc.deinit(gpa);
                    types[cv2.dst.int()] = rt7;
                    if (rt7 == .object) cls[cv2.dst.int()] = classIndexOfName(m, bf.return_ty);
                    known[cv2.dst.int()] = true;
                },
                .Call => |c| {
                    if (c.arg_names.len != 0 or c.type_args.len != 0) return no(f, "call arg names/type args");
                    if (c.dst.int() >= f.n_locals) return null;
                    const callee = m.funcById(c.func) orelse return no(f, "call target missing");
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
                    } else {
                        if (!callee.hasBody()) return noCallee(f, callee, "no body for");
                        if (callee.params.len != c.n_args) return noCallee(f, callee, "arity of");
                        const rt = funcRetTy2(m, callee) orelse return no(f, "callee return type");
                        types[c.dst.int()] = rt;
                        if (rt == .object) cls[c.dst.int()] = classIndexOfName(m, callee.return_ty);
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
    for (f.blocks) |*blk| {
        if (blk.terminator != .Return) continue;
        const rr = blk.terminator.Return orelse continue;
        if (rr.int() >= f.n_locals or !known[rr.int()]) return no(f, "return register");
        if (!saw_ret) {
            ret = types[rr.int()];
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
    return .{ .f = f, .caps = caps, .params = params, .types = types, .cls = cls, .elem = elem, .lam = lam, .slot = slot, .n_slots = n_slots, .ret = ret };
}

/// A C identifier for the function. Derived from the fqn, never from the id:
/// ids are not stable across bakes, and a name that moves between builds would
/// silently link the wrong body.
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
    ls: Layouts,
    cid: u32,
) !void {
    const c = &m.classes.items[cid];
    const fields = ls.of(cid).?;
    try writeCtorProto(w, m, cid);
    try w.writeAll(" {\n");
    if (c.primary_params.len == 0 and fields.len == 0) try w.writeAll("  (void)self;\n");
    if (ls.parentOf(cid)) |pp| {
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
    for (fields, 0..) |fd, fi| {
        if (fd.from_parent) continue;
        var bb: [400]u8 = undefined;
        if (fd.arg) |ai| {
            var nb: [16]u8 = undefined;
            const arg = std.fmt.bufPrint(&nb, "p{d}", .{ai}) catch unreachable;
            try w.print("  klio_nat_set(self, {d}, {s});\n", .{ fi, boxExpr(fd.ty, arg, &bb) });
            continue;
        }
        const ifn = m.funcById(fd.init.?).?;
        var call: std.Io.Writer.Allocating = .init(gpa);
        defer call.deinit();
        try writeThunkCall(gpa, &call.writer, c, ifn);
        try w.print("  klio_nat_set(self, {d}, {s});\n", .{ fi, boxExpr(fd.ty, call.written(), &bb) });
    }
    try w.writeAll("}\n");
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
        .unit => return std.fmt.bufPrint(buf, "klio_nat_box_unit()", .{}) catch unreachable,
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
        .unit => return std.fmt.bufPrint(buf, "0", .{}) catch unreachable,
        .object => return std.fmt.bufPrint(buf, "{s}", .{expr}) catch unreachable,
    };
    return std.fmt.bufPrint(buf, "{s}({s})", .{ fname, expr }) catch unreachable;
}

/// Where a register lives: a C local for a scalar, a published frame slot for
/// a reference.
fn regName(c: *const Compiled, r: u32, buf: []u8) []const u8 {
    if (c.types[r] == .object) {
        return std.fmt.bufPrint(buf, "KS[{d}]", .{c.slot[r]}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "r{d}", .{r}) catch unreachable;
}

fn writeProto(w: *std.Io.Writer, c: *const Compiled) !void {
    try w.print("static {s} ", .{c.ret.cName()});
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
            const pt: Ty = tyOf(p.ty) orelse .object;
            try w.print("{s} p{d}", .{ pt.cName(), i });
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

fn writeBody(gpa: std.mem.Allocator, w: *std.Io.Writer, m: *const Module, ls: Layouts, c: *const Compiled, uses_objects: bool, globals: []const Global, singletons: []const u32, slots: []const SlotUse, uses_try: bool) !void {
    const f = c.f;
    const live = try reachableBlocks(gpa, f);
    defer gpa.free(live);
    try writeProto(w, c);
    try w.writeAll(" {\n");
    var has_catch = false;
    for (f.blocks) |*blk| {
        if (blk.catches.len != 0) has_catch = true;
    }
    var r: u32 = 0;
    while (r < f.n_locals) : (r += 1) {
        if (c.types[r] == .object) continue;
        // A local written after `setjmp` and read after the jump back is
        // indeterminate unless it is volatile. The object slots live in an
        // array, which is memory already.
        try w.print("  {s}{s} r{d} = 0;\n", .{ if (has_catch) "volatile " else "", c.types[r].cName(), r });
    }
    // Registers the lowering allocated but this body never reads: a C compiler
    // warns on them and the emitted file should be warning-clean.
    r = 0;
    while (r < f.n_locals) : (r += 1) {
        if (c.types[r] == .object) continue;
        try w.print("  (void)r{d};", .{r});
    }
    try w.writeAll("\n");
    if (c.n_slots != 0) {
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
    try w.writeAll("  goto B0;\n");
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
                const ht = ls.throws.find(h.type_name).?;
                try w.print("    if (klio_nat_catches(klio_in_flight, {d}, {d})) {{ {s} = klio_in_flight; goto B{d}; }} /* {s} */\n", .{
                    ht.lo, ht.hi, regName(c, h.exception_reg.int(), &eb), h.handler.int(), h.type_name,
                });
            }
            try w.writeAll("    klio_do_throw(klio_in_flight);\n  }\n");
        }
        for (blk.insts) |*inst| {
            switch (inst.*) {
                .Trace => {},
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
                    try w.print("  {s} = ", .{regName(c, k.dst.int(), &nb)});
                    try writeConst(w, kv);
                    try w.writeAll(";\n");
                },
                .LoadParam => |lp| {
                    var nb: [32]u8 = undefined;
                    try w.print("  {s} = p{d};\n", .{ regName(c, lp.dst.int(), &nb), lp.idx });
                },
                .LoadCapture => |lc| {
                    var nb: [32]u8 = undefined;
                    try w.print("  {s} = k{d};\n", .{ regName(c, lc.dst.int(), &nb), lc.idx });
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
                    try w.print("  {s} = {s};\n", .{ regName(c, mv.dst.int(), &nb), regName(c, mv.src.int(), &sb) });
                },
                .NewInstance => |ni| {
                    var nb: [32]u8 = undefined;
                    const dst = regName(c, ni.dst.int(), &nb);
                    if (isThrowableClass(m, ni.class.int())) {
                        const cn = m.classes.items[ni.class.int()];
                        const tid = ls.throws.find(cn.name) orelse ls.throws.find(cn.fqn);
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
                    try w.print("  {s} = klio_nat_alloc_instance(KCLS_{d});\n", .{ dst, ni.class.int() });
                    // The class's own initializer fills it, which is what lets
                    // a subclass hand the same instance up to its superclass's.
                    try w.print("  kinit_{d}({s}", .{ ni.class.int(), dst });
                    const cdef2 = &m.classes.items[ni.class.int()];
                    var pi3: u32 = 0;
                    while (pi3 < ni.n_args) : (pi3 += 1) {
                        try w.writeAll(", ");
                        const areg3 = ni.args.int() + pi3;
                        var ab5: [32]u8 = undefined;
                        const want3: Ty = if (pi3 < cdef2.primary_params.len)
                            ctorParamTy(cdef2, pi3)
                        else
                            c.types[areg3];
                        if (want3 == .object and c.types[areg3] != .object) {
                            var bx3: [96]u8 = undefined;
                            try w.print("{s}", .{boxExpr(c.types[areg3], regName(c, areg3, &ab5), &bx3)});
                        } else {
                            try w.print("{s}", .{regName(c, areg3, &ab5)});
                        }
                    }
                    try w.writeAll(");\n");
                },
                .GetField => |gf| {
                    const rc = c.cls[gf.receiver.int()].?;
                    if (rc == STRING_CLS or rc == LIST_CLS) {
                        var nb: [32]u8 = undefined;
                        var rb: [32]u8 = undefined;
                        try w.print("  {s} = {s}({s});\n", .{
                            regName(c, gf.dst.int(), &nb),
                            if (rc == STRING_CLS) "klio_nat_str_length" else "klio_nat_list_size",
                            regName(c, gf.receiver.int(), &rb),
                        });
                        continue;
                    }
                    const nm = m.consts.items[gf.field.int()].String;
                    const idx = fieldIndex(ls, rc, nm).?;
                    var nb: [32]u8 = undefined;
                    var rb: [32]u8 = undefined;
                    var ub: [128]u8 = undefined;
                    const get = try std.fmt.bufPrint(&ub, "klio_nat_get({s}, {d})", .{ regName(c, gf.receiver.int(), &rb), idx });
                    var ob: [160]u8 = undefined;
                    try w.print("  {s} = {s};\n", .{
                        regName(c, gf.dst.int(), &nb), unboxExpr(c.types[gf.dst.int()], get, &ob),
                    });
                },
                .SetField => |sf| {
                    const rc = c.cls[sf.receiver.int()].?;
                    const nm = m.consts.items[sf.field.int()].String;
                    const idx = fieldIndex(ls, rc, nm).?;
                    var rb: [32]u8 = undefined;
                    var vb: [32]u8 = undefined;
                    var bb: [96]u8 = undefined;
                    try w.print("  klio_nat_set({s}, {d}, {s});\n", .{
                        regName(c, sf.receiver.int(), &rb), idx,
                        boxExpr(c.types[sf.value.int()], regName(c, sf.value.int(), &vb), &bb),
                    });
                },
                .BinOp => |b| {
                    const dt = c.types[b.dst.int()];
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
                    if (dt == .object) {
                        // Concatenation: either operand may be any value, and
                        // the runtime renders it as Kotlin would.
                        var db: [32]u8 = undefined;
                        var lb: [32]u8 = undefined;
                        var rb: [32]u8 = undefined;
                        var l1: [96]u8 = undefined;
                        var r1: [96]u8 = undefined;
                        try w.print("  {s} = klio_nat_concat({s}, {s});\n", .{
                            regName(c, b.dst.int(), &db),
                            boxExpr(c.types[b.lhs.int()], regName(c, b.lhs.int(), &lb), &l1),
                            boxExpr(c.types[b.rhs.int()], regName(c, b.rhs.int(), &rb), &r1),
                        });
                        continue;
                    }
                    const op = cOp(b.op).?;
                    var lnb: [32]u8 = undefined;
                    var rnb: [32]u8 = undefined;
                    var dnb: [32]u8 = undefined;
                    const ln = regName(c, b.lhs.int(), &lnb);
                    const rn = regName(c, b.rhs.int(), &rnb);
                    const dn = regName(c, b.dst.int(), &dnb);
                    if ((b.op == .Div or b.op == .Mod) and !dt.isFloat() and !isCmp(b.op)) {
                        try w.print("  if ({s} == 0) klio_arith_zero();\n", .{rn});
                    }
                    if (b.op == .UShr) {
                        const lt = c.types[b.lhs.int()];
                        const ut: []const u8 = if (lt == .i64) "uint64_t" else "uint32_t";
                        try w.print("  {s} = ({s})(({s}){s} >> ({s} & {d}));\n", .{
                            dn, dt.cName(), ut, ln, rn,
                            @as(u32, if (lt == .i64) 63 else 31),
                        });
                    } else if (b.op == .Shl or b.op == .Shr) {
                        // Kotlin masks the shift count; C leaves an over-wide
                        // shift undefined.
                        const lt = c.types[b.lhs.int()];
                        try w.print("  {s} = ({s})({s} {s} ({s} & {d}));\n", .{
                            dn, dt.cName(), ln, op, rn,
                            @as(u32, if (lt == .i64) 63 else 31),
                        });
                    } else {
                        try w.print("  {s} = ({s})(({s}){s} {s} ({s}){s});\n", .{
                            dn,  dt.cName(),
                            if (isCmp(b.op)) promote(c.types[b.lhs.int()], c.types[b.rhs.int()]).?.cName() else dt.cName(),
                            ln,  op,
                            if (isCmp(b.op)) promote(c.types[b.lhs.int()], c.types[b.rhs.int()]).?.cName() else dt.cName(),
                            rn,
                        });
                    }
                },
                .UnOp => |u| {
                    const t = c.types[u.dst.int()];
                    switch (u.op) {
                        .Neg => try w.print("  r{d} = ({s})(-r{d});\n", .{ u.dst.int(), t.cName(), u.operand.int() }),
                        .Plus => try w.print("  r{d} = r{d};\n", .{ u.dst.int(), u.operand.int() }),
                        else => unreachable,
                    }
                },
                .Not => |n| try w.print("  r{d} = !r{d};\n", .{ n.dst.int(), n.src.int() }),
                .CallMember => |cm| {
                    var nb: [32]u8 = undefined;
                    var rb: [32]u8 = undefined;
                    const recv = regName(c, cm.receiver.int(), &rb);
                    if (c.cls[cm.receiver.int()]) |rc| {
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
                    try w.print("  {s} = ({s}){s};\n", .{
                        regName(c, cm.dst.int(), &nb), c.types[cm.dst.int()].cName(), recv,
                    });
                },
                .CallVirtual => |cv| {
                    var nb: [32]u8 = undefined;
                    var rb: [32]u8 = undefined;
                    const recv = regName(c, cv.receiver.int(), &rb);
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
                            } else if (std.mem.eql(u8, mn, "add")) {
                                try w.print("  klio_nat_list_add({s}, {s});\n", .{
                                    recv, boxExpr(c.types[a0], regName(c, a0, &ab), &bb),
                                });
                                try w.print("  {s} = 1;\n", .{regName(c, cv.dst.int(), &nb)});
                            } else {
                                var vb: [32]u8 = undefined;
                                try w.print("  klio_nat_list_set({s}, {s}, {s});\n", .{
                                    recv, regName(c, a0, &ab),
                                    boxExpr(c.types[a0 + 1], regName(c, a0 + 1, &vb), &bb),
                                });
                                try w.print("  {s} = klio_nat_box_unit();\n", .{regName(c, cv.dst.int(), &nb)});
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
                    if (c.cls[lg.dst.int()]) |rc| {
                        if (!isBuiltinCls(rc) and singletonSlot(singletons, rc) != null) {
                            var nb2: [32]u8 = undefined;
                            try w.print("  {s} = KO[{d}];\n", .{
                                regName(c, lg.dst.int(), &nb2), singletonSlot(singletons, rc).?,
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
                .AstLambda => {
                    // Nothing to materialise: the call site knows the body and
                    // passes the captures itself.
                },
                .CallValue => |cv2| {
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
                        const fmt: []const u8 = switch (at) {
                            .i32 => "%\" PRId32 \"",
                            .i64 => "%\" PRId64 \"",
                            else => "",
                        };

                        // When the runtime is linked, everything prints through
                        // its renderer: two renderers would be two chances to
                        // drift, and printf's buffered stream interleaves
                        // wrongly with the runtime's own writes.
                        if (uses_objects) {
                            var ab2: [32]u8 = undefined;
                            var bx: [96]u8 = undefined;
                            try w.print("  klio_nat_println({s});\n", .{
                                boxExpr(at, regName(c, a0, &ab2), &bx),
                            });
                        } else if (at == .boolean) {
                            try w.print("  printf(\"%s\\n\", r{d} ? \"true\" : \"false\");\n", .{a0});
                        } else if (at.isFloat()) {
                            try w.print("  klio_print_fp((double)r{d}, {d});\n", .{ a0, @intFromBool(at == .f32) });
                        } else {
                            try w.print("  printf(\"{s}\\n\", r{d});\n", .{ fmt, a0 });
                        }
                    } else {
                        var db: [32]u8 = undefined;
                        try w.print("  {s} = ", .{regName(c, call.dst.int(), &db)});
                        try writeSymbol(w, callee);
                        try w.writeByte('(');
                        var k: u32 = 0;
                        while (k < call.n_args) : (k += 1) {
                            if (k != 0) try w.writeAll(", ");
                            var ab: [32]u8 = undefined;
                            try w.print("{s}", .{regName(c, call.args.int() + k, &ab)});
                        }
                        try w.writeAll(");\n");
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
                try w.print("  if ({s}) goto B{d}; else goto B{d};\n", .{
                    regName(c, br.cond.int(), &cb), br.t.int(), br.f.int(),
                });
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
};

pub const ClassLayout = struct {
    /// Simple class name, matching the IR class it describes.
    name: []const u8,
    props: []const BodyProp,
    /// One thunk per argument this class passes to its superclass constructor,
    /// each taking this class's own constructor arguments.
    parent_args: []const ir.FuncId = &.{},
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

pub const Program = struct {
    /// Functions accepted into the scalar core, entry last so a body is always
    /// declared before the definition that calls it.
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
    w: *std.Io.Writer,
    src_path: []const u8,
) Error!bool {
    // Resolve every class's layout once: the emitter asks about the same
    // classes repeatedly, and resolving walks the class table each time.
    const table = try gpa.alloc(?[]const FieldInfo, m.classes.items.len);
    defer {
        for (table) |maybe| {
            if (maybe) |fs| gpa.free(fs);
        }
        gpa.free(table);
    }
    const parent_table = try gpa.alloc(?Parent, m.classes.items.len);
    defer gpa.free(parent_table);
    for (table, 0..) |*slot_p, i| {
        if (try classFields(gpa, m, layouts, @enumFromInt(i))) |laid| {
            slot_p.* = laid.fields;
            parent_table[i] = laid.parent;
        } else {
            slot_p.* = null;
            parent_table[i] = null;
        }
    }

    var throws = try buildThrowTable(gpa, m);
    defer throws.deinit(gpa);
    const ls: Layouts = .{ .fields = table, .parents = parent_table, .layouts = layouts, .throws = throws };
    var accepted: std.ArrayList(Compiled) = .empty;
    defer {
        for (accepted.items) |*c| c.deinit(gpa);
        accepted.deinit(gpa);
    }
    var seen = std.AutoHashMap(u32, void).init(gpa);
    defer seen.deinit();
    const Pending = struct { f: *const Func, synth: ?[]const ir.Param, caps: []const CapInfo = &.{} };
    // Capture signatures outlive the queue entry that carried them.
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
    // A single refusal anywhere in the reachable set fails the whole emission:
    // a compiled program has no interpreter to fall back INTO, so a body it
    // cannot call is not a slow path, it is a missing one.
    while (queue.pop()) |pending| {
        const f = pending.f;
        const c = (try eligible(gpa, m, ls, f, globals, pending.synth, pending.caps)) orelse return false;
        try accepted.append(gpa, c);
        for (f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (inst.* == .LoadGlobal) {
                    const cid3 = inst.LoadGlobal.name;
                    if (cid3.int() < m.consts.items.len) {
                        const gn3 = m.consts.items[cid3.int()];
                        if (gn3 == .String) {
                            if (objectClassNamed(m, ls, gn3.String)) |oc| {
                                for (ls.of(oc).?) |fd| {
                                    const ifid = fd.init orelse continue;
                                    const ifn = m.funcById(ifid) orelse return false;
                                    if (seen.contains(ifn.id.int())) continue;
                                    try seen.put(ifn.id.int(), {});
                                    try queue.append(gpa, .{ .f = ifn, .synth = null });
                                }
                            }
                        }
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
                        // those values arrive as leading arguments.
                        const ct = try gpa.alloc(CapInfo, al2.captures.len);
                        for (al2.captures, 0..) |cr, ci4| ct[ci4] = .{ .ty = c.types[cr.int()], .cls = c.cls[cr.int()], .elem = c.elem[cr.int()] };
                        try cap_owned.append(gpa, ct);
                        try seen.put(bfn.id.int(), {});
                        try queue.append(gpa, .{ .f = bfn, .synth = null, .caps = ct });
                    }
                    continue;
                }
                if (inst.* == .CallVirtual) {
                    const cv2 = inst.CallVirtual;
                    if (numConvVirtual(m, cv2) == null) {
                        // Any class the program can construct may answer this
                        // slot, so every implementation is reachable.
                        var ci2: u32 = 0;
                        while (ci2 < m.classes.items.len) : (ci2 += 1) {
                            if (ls.of(ci2) == null) continue;
                            const impl = slotImpl(m, ci2, cv2.slot) orelse continue;
                            if (seen.contains(impl.id.int())) continue;
                            try seen.put(impl.id.int(), {});
                            try queue.append(gpa, .{ .f = impl, .synth = null });
                        }
                    }
                }
                if (inst.* == .NewInstance) {
                    // Constructing a class runs every initializer in its chain:
                    // each class's body-property thunks, and the thunks it
                    // passes to its superclass's constructor.
                    var walk: ?u32 = inst.NewInstance.class.int();
                    var steps: u32 = 0;
                    while (walk) |wc| : (steps += 1) {
                        if (steps > 32) break;
                        const fds = ls.of(wc) orelse break;
                        const wdef = &m.classes.items[wc];
                        for (fds) |fd| {
                            if (fd.from_parent) continue;
                            const ifid = fd.init orelse continue;
                            const ifn = m.funcById(ifid) orelse return false;
                            if (seen.contains(ifn.id.int())) continue;
                            try seen.put(ifn.id.int(), {});
                            try queue.append(gpa, .{ .f = ifn, .synth = null });
                        }
                        const pp = ls.parentOf(wc) orelse break;
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
                if (isPrintln(callee) or listIntrinsic(callee) != null) continue;
                if (seen.contains(callee.id.int())) continue;
                try seen.put(callee.id.int(), {});
                try queue.append(gpa, .{ .f = callee, .synth = null });
            }
        }
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
                if (inst.* != .CallVirtual) continue;
                const cv = inst.CallVirtual;
                if (c.cls[cv.receiver.int()]) |rc| {
                    if (rc == LIST_CLS) continue;
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
    var used_singletons: std.ArrayList(u32) = .empty;
    defer used_singletons.deinit(gpa);
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (inst.* != .LoadGlobal) continue;
                const cid2 = inst.LoadGlobal.name;
                if (cid2.int() >= m.consts.items.len) continue;
                const gn2 = m.consts.items[cid2.int()];
                if (gn2 != .String) continue;
                const oc = objectClassNamed(m, ls, gn2.String) orelse continue;
                var have2 = false;
                for (used_singletons.items) |u| {
                    if (u == oc) have2 = true;
                }
                if (!have2) try used_singletons.append(gpa, oc);
            }
        }
    }

    // Classes the program constructs or reads through. Emitted as descriptors
    // and registered before main: a compiled program carries its own layout
    // because there is no module to ask.
    var used_classes: std.ArrayList(u32) = .empty;
    defer used_classes.deinit(gpa);
    for (used_singletons.items) |oc| {
        var seen_o = false;
        for (used_classes.items) |u| {
            if (u == oc) seen_o = true;
        }
        if (!seen_o) try used_classes.append(gpa, oc);
    }
    for (accepted.items) |*c| {
        for (c.cls) |maybe| {
            const cid = maybe orelse continue;
            if (isBuiltinCls(cid)) continue;
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
        for (used_singletons.items) |oc| try want.append(gpa, oc);
        for (accepted.items) |*cc| {
            for (cc.f.blocks) |*blk| {
                for (blk.insts) |*inst| {
                    if (inst.* != .NewInstance) continue;
                    const nc = inst.NewInstance.class.int();
                    if (isThrowableClass(m, nc)) continue;
                    try want.append(gpa, nc);
                }
            }
        }
        var wi: usize = 0;
        while (wi < want.items.len) : (wi += 1) {
            const cid = want.items[wi];
            if (ls.of(cid) == null) continue;
            var have = false;
            for (ctor_classes.items) |u| {
                if (u == cid) have = true;
            }
            if (have) continue;
            try ctor_classes.append(gpa, cid);
            if (ls.parentOf(cid)) |pp| try want.append(gpa, pp.cid);
        }
    }

    // A string is a reference too: a program that only concatenates still needs
    // the runtime for its collector and renderer.
    var uses_objects_hint = false;
    var uses_objects = used_classes.items.len != 0;
    for (accepted.items) |*c| {
        for (c.types) |t| {
            // A `Char` prints as a character and a `Short`/`Byte` as itself, so
            // a program holding one needs the runtime's renderer even if it
            // never touches the heap.
            if (t == .object or t == .char or t == .short or t == .byte) uses_objects = true;
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

    var needs_fp = false;
    var needs_div = false;
    for (accepted.items) |*c| {
        for (c.f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                switch (inst.*) {
                    .BinOp => |b| {
                        if ((b.op == .Div or b.op == .Mod) and !c.types[b.dst.int()].isFloat()) needs_div = true;
                    },
                    .Call => |call| {
                        const callee = m.funcById(call.func) orelse continue;
                        if (!isPrintln(callee)) continue;
                        if (c.types[call.args.int()].isFloat()) needs_fp = true;
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
    if (uses_objects) {
        try w.writeAll(
            \\#include <klio_rt.h>
            \\
            \\
        );
        for (used_classes.items) |cid| try w.print("static uint32_t KCLS_{d};\n", .{cid});
        try w.writeAll("\nstatic void klio_register_classes(void) {\n");
        for (used_classes.items) |cid| {
            const cdef = &m.classes.items[cid];
            const fields = ls.of(cid).?;
            try w.print("  {{ static const char *const fn[] = {{", .{});
            for (fields, 0..) |fld, i| {
                if (i != 0) try w.writeAll(", ");
                try w.writeByte('"');
                try w.writeAll(fld.name);
                try w.writeByte('"');
            }
            if (fields.len == 0) try w.writeAll("0");
            try w.print("}}; KCLS_{d} = klio_nat_class(\"{s}\", {d}, fn); }}\n", .{ cid, cdef.name, fields.len });
        }
        try w.writeAll("}\n\n");
    }
    if (uses_objects_hint) uses_objects = true;
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
    if (needs_div) try w.writeAll(
        \\/* Kotlin throws on integer division by zero; C leaves it undefined. */
        \\static void klio_arith_zero(void) {
        \\  fprintf(stderr, "Exception in thread \"main\" java.lang.ArithmeticException: / by zero\n");
        \\  exit(1);
        \\}
        \\
        \\
    );
    if (needs_fp and !uses_objects) try w.writeAll(
        \\/* Kotlin renders a floating value as the SHORTEST decimal that reads
        \\ * back as the same double, always with a fractional part, and switches
        \\ * to scientific form outside [1e-3, 1e7). printf("%g") agrees with none
        \\ * of that: it would print 17.0 as "17". The search starts at two
        \\ * significant digits because the reference renderer does: the smallest
        \\ * subnormal prints as 4.9E-324, though 5E-324 reads back as the same
        \\ * value. Trailing zeros are trimmed, so a value that needs one digit
        \\ * still prints as one. */
        \\static void klio_print_fp(double d, int is_float) {
        \\  if (d != d) { printf("NaN\n"); return; }
        \\  if (d > 1.7976931348623157e308) { printf("Infinity\n"); return; }
        \\  if (d < -1.7976931348623157e308) { printf("-Infinity\n"); return; }
        \\  char buf[64];
        \\  int prec;
        \\  int max = is_float ? 9 : 17;
        \\  for (prec = 2; prec < max; prec++) {
        \\    snprintf(buf, sizeof buf, "%.*e", prec - 1, d);
        \\    double back = strtod(buf, NULL);
        \\    if (is_float ? ((float)back == (float)d) : (back == d)) break;
        \\  }
        \\  snprintf(buf, sizeof buf, "%.*e", prec - 1, d);
        \\  /* Split the mantissa digits from the exponent. */
        \\  char digits[32];
        \\  int neg = 0, nd = 0, exp10 = 0;
        \\  const char *p = buf;
        \\  if (*p == '-') { neg = 1; p++; }
        \\  for (; *p && *p != 'e' && *p != 'E'; p++) {
        \\    if (*p >= '0' && *p <= '9' && nd < (int)sizeof digits) digits[nd++] = *p;
        \\  }
        \\  if (*p) exp10 = atoi(p + 1);
        \\  while (nd > 1 && digits[nd - 1] == '0') nd--;
        \\  if (neg) putchar('-');
        \\  if (exp10 >= -3 && exp10 < 7) {
        \\    if (exp10 >= 0) {
        \\      for (int i = 0; i <= exp10; i++) putchar(i < nd ? digits[i] : '0');
        \\      putchar('.');
        \\      if (nd > exp10 + 1) { for (int i = exp10 + 1; i < nd; i++) putchar(digits[i]); }
        \\      else putchar('0');
        \\    } else {
        \\      printf("0.");
        \\      for (int i = 0; i < -exp10 - 1; i++) putchar('0');
        \\      for (int i = 0; i < nd; i++) putchar(digits[i]);
        \\    }
        \\  } else {
        \\    putchar(digits[0]);
        \\    putchar('.');
        \\    if (nd > 1) { for (int i = 1; i < nd; i++) putchar(digits[i]); }
        \\    else putchar('0');
        \\    printf("E%d", exp10);
        \\  }
        \\  putchar('\n');
        \\}
        \\
        \\
    );

    if (used_singletons.items.len != 0) {
        try w.print("\n/* `object` declarations: one instance each, built before the program\n" ++
            " * runs and rooted for its whole life. */\n", .{});
        try w.print("static klio_value KO[{d}];\n", .{used_singletons.items.len});
        try w.print("static klio_nat_frame KOF;\n", .{});
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
    try w.writeAll("\n");
    for (accepted.items) |*c| try writeBody(gpa, w, m, ls, c, uses_objects, used_globals.items, used_singletons.items, used_slots.items, uses_try);

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
        try w.writeAll(") {\n  uint32_t k = klio_nat_class_of(recv);\n");
        for (used_classes.items) |cid| {
            const impl = slotImpl(m, cid, ir.MethodSlotId.from(su.slot)) orelse continue;
            var in_set = false;
            for (accepted.items) |*cc| {
                if (cc.f == impl) in_set = true;
            }
            if (!in_set) continue;
            try w.print("  if (k == KCLS_{d}) return ", .{cid});
            try writeSymbol(w, impl);
            try w.writeAll("(recv");
            var aj: u32 = 0;
            while (aj < su.n_args) : (aj += 1) try w.print(", a{d}", .{aj});
            try w.writeAll(");\n");
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
    for (ctor_classes.items) |cid| try writeCtorBody(gpa, w, m, ls, cid);
    if (ctor_classes.items.len != 0) try w.writeAll("\n");
    if (used_singletons.items.len != 0) {
        try w.writeAll("static void klio_init_singletons(void) {\n");
        try w.print("  for (unsigned i = 0; i < {d}; i++) KO[i] = klio_nat_box_unit();\n", .{used_singletons.items.len});
        try w.print("  KOF.n = {d}; KOF.slots = KO; klio_nat_enter(&KOF);\n", .{used_singletons.items.len});
        for (used_singletons.items, 0..) |oc, oi| {
            try w.print("  KO[{d}] = klio_nat_alloc_instance(KCLS_{d});\n", .{ oi, oc });
            try w.print("  kinit_{d}(KO[{d}]);\n", .{ oc, oi });
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
