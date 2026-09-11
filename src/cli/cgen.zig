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
    return null;
}

/// The function's result type. `return_ty` is a PLACEHOLDER `Unit` when the
/// source wrote no annotation, so a body that returns nothing is read from the
/// body: every terminator returning no value means the result is Unit,
/// whatever the placeholder says.
fn funcRetTy(f: *const Func) ?Ty {
    var any_value = false;
    for (f.blocks) |*blk| {
        if (blk.terminator == .Return and blk.terminator.Return != null) any_value = true;
    }
    if (!any_value) return .unit;
    return tyOf(f.return_ty);
}

/// `funcRetTy` widened to the object case, which needs the module to know
/// whether the declared type names a class the emitter can lay out.
fn funcRetTy2(m: *const Module, f: *const Func) ?Ty {
    if (funcRetTy(f)) |t| return t;
    if (classOfType(m, f.return_ty) != null) return .object;
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
        .i32, .i64, .f64, .f32 => true,
        else => false,
    };
}

fn isStringReg(types: []const Ty, cls: []const ?u32, r: u32) bool {
    return types[r] == .object and cls[r] != null and cls[r].? == STRING_CLS;
}

/// A `List` register. Lists are runtime values, not user classes, so like
/// `String` they take a handle outside the class table.
const LIST_CLS: u32 = std.math.maxInt(u32) - 1;

/// Whether a class handle names a runtime type rather than a user class. Such
/// a handle indexes no class table and gets no emitted descriptor.
fn isBuiltinCls(cid: u32) bool {
    return cid == STRING_CLS or cid == LIST_CLS;
}

/// The class marker for a register the emitter knows holds a `String`. Strings
/// are not user classes, so they take a handle outside the class table rather
/// than a `ClassId`.
const STRING_CLS: u32 = std.math.maxInt(u32);

/// Kotlin's binary numeric promotion, over the kinds this subset carries.
fn promote(a: Ty, b: Ty) ?Ty {
    if (a == .boolean or b == .boolean or a == .unit or b == .unit) return null;
    if (a == .f64 or b == .f64) return .f64;
    if (a == .f32 or b == .f32) return .f32;
    if (a == .i64 or b == .i64) return .i64;
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
    types: []Ty,
    /// The class an object register holds, where the emitter knows it. Needed
    /// to turn a field NAME into the index the compiled code addresses.
    cls: []?u32,
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
        gpa.free(self.slot);
    }
};

/// The instance fields of a class, in the order the runtime lays them out:
/// the primary-constructor parameters that double as properties. A class this
/// returns null for is one the emitter cannot lay out, and any program touching
/// it is refused.
fn classFields(m: *const Module, cid: ir.ClassId) ?[]const ir.Param {
    if (cid.int() >= m.classes.items.len) return null;
    const c = &m.classes.items[cid.int()];
    if (c.init_block != null) return null;
    if (c.supertypes.len != 0) return null;
    if (c.is_abstract or c.is_inner) return null;
    for (c.primary_params) |p| {
        if (!p.is_property) return null;
        if (p.default != null or p.is_vararg) return null;
        if (tyOf(p.ty) == null and classIndexOfName(m, p.ty) == null) return null;
    }
    return c.primary_params;
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
fn fieldIndex(m: *const Module, cid: u32, name: []const u8) ?u32 {
    const fields = classFields(m, @enumFromInt(cid)) orelse return null;
    const want = plainFieldName(name);
    for (fields, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, want)) return @intCast(i);
    }
    return null;
}

/// The class a declared type NAMES, without asking whether its layout is one
/// the emitter can produce. Kept separate from `classOfType` because a field
/// only has to be a reference to be stored; needing the layout too would
/// recurse forever on a class holding one of its own kind.
fn classIndexOfName(m: *const Module, t: ir.TypeRef) ?u32 {
    if (t.name.len == 0) return null;
    if (std.mem.eql(u8, t.name, "String") or std.mem.eql(u8, t.name, "kotlin.String")) return STRING_CLS;
    if (std.mem.eql(u8, t.name, "List") or std.mem.eql(u8, t.name, "MutableList")) return LIST_CLS;
    for (m.classes.items, 0..) |*c, i| {
        if (std.mem.eql(u8, c.name, t.name) or std.mem.eql(u8, c.fqn, t.name)) return @intCast(i);
    }
    return null;
}

/// The class a declared type names AND whose layout the emitter can produce —
/// what a register holding it needs before its fields can be addressed.
fn classOfType(m: *const Module, t: ir.TypeRef) ?u32 {
    const idx = classIndexOfName(m, t) orelse return null;
    if (idx == STRING_CLS or idx == LIST_CLS) return idx;
    if (classFields(m, @enumFromInt(idx)) == null) return null;
    return idx;
}

/// The machine type of a class property: a scalar in place, or a reference.
fn fieldTy(m: *const Module, p: ir.Param) ?Ty {
    if (tyOf(p.ty)) |t| return t;
    if (classIndexOfName(m, p.ty) != null) return .object;
    return null;
}

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

/// Whether `f` lowers to the scalar core, and the register types if it does.
/// Refuses rather than guesses: every register the body defines must have a
/// scalar type, and every instruction must be one this emitter writes.
/// The class a function's receiver parameter names, for a method compiled as an
/// ordinary C function taking `this` first.
fn receiverClass(m: *const Module, f: *const Func) ?u32 {
    if (!f.has_receiver_param or f.params.len == 0) return null;
    return classOfType(m, f.params[0].ty);
}

/// A top-level property's machine type, taken from the thunk that initializes
/// it. The declaration often carries no annotation (`var counter = 0`), so the
/// declared return type of the thunk says nothing; what the thunk COMPILES to
/// is the answer.
fn globalTy(gpa: std.mem.Allocator, m: *const Module, globals: []const Global, idx: usize) Error!?Ty {
    const gf = m.funcById(globals[idx].func) orelse return null;
    var c = (try eligible(gpa, m, gf, globals)) orelse return null;
    defer c.deinit(gpa);
    return c.ret;
}

fn globalIndex(globals: []const Global, name: []const u8) ?usize {
    for (globals, 0..) |g, i| {
        if (std.mem.eql(u8, g.name, name)) return i;
    }
    return null;
}

pub fn eligible(gpa: std.mem.Allocator, m: *const Module, f: *const Func, globals: []const Global) Error!?Compiled {
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
    for (f.params) |p| {
        if (p.default != null or p.is_vararg) return no(f, "param default/vararg");
        if (tyOf(p.ty) == null and classOfType(m, p.ty) == null) return no(f, "param type");
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
        if (blk.catches.len != 0 or blk.finally != null) return no(f, "try/finally");
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
                .LoadParam => |lp| {
                    if (lp.dst.int() >= f.n_locals or lp.idx >= f.params.len) return no(f, "load param");
                    const pt = f.params[lp.idx].ty;
                    if (tyOf(pt)) |t| {
                        types[lp.dst.int()] = t;
                    } else {
                        types[lp.dst.int()] = .object;
                        cls[lp.dst.int()] = classOfType(m, pt);
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
                    const fields = classFields(m, ni.class) orelse return no(f, "class layout");
                    if (fields.len != ni.n_args) return no(f, "ctor arity");
                    var k: u32 = 0;
                    while (k < ni.n_args) : (k += 1) {
                        const ar = ni.args.int() + k;
                        if (ar >= f.n_locals or !known[ar]) return no(f, "ctor arg");
                        if (types[ar] != (fieldTy(m, fields[k]) orelse return no(f, "ctor field type"))) return no(f, "ctor arg type");
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
                    const idx = fieldIndex(m, rc, nm.String) orelse return no(f, "field not laid out");
                    const fields = classFields(m, @enumFromInt(rc)).?;
                    if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                    types[gf.dst.int()] = fieldTy(m, fields[idx]) orelse return no(f, "field type");
                    if (types[gf.dst.int()] == .object) cls[gf.dst.int()] = classIndexOfName(m, fields[idx].ty);
                    known[gf.dst.int()] = true;
                },
                .SetField => |sf| {
                    if (sf.receiver.int() >= f.n_locals or !known[sf.receiver.int()]) return no(f, "field receiver");
                    if (types[sf.receiver.int()] != .object) return no(f, "field on non-object");
                    const rc = cls[sf.receiver.int()] orelse return no(f, "field receiver class");
                    if (sf.field.int() >= m.consts.items.len) return no(f, "field name");
                    const nm = m.consts.items[sf.field.int()];
                    if (nm != .String) return no(f, "field name kind");
                    const idx = fieldIndex(m, rc, nm.String) orelse return no(f, "field not laid out");
                    const fields = classFields(m, @enumFromInt(rc)).?;
                    if (sf.value.int() >= f.n_locals or !known[sf.value.int()]) return no(f, "field value");
                    if (types[sf.value.int()] != (fieldTy(m, fields[idx]) orelse return no(f, "field type"))) return no(f, "field value type");
                },
                .LoadGlobal => |lg| {
                    if (lg.name.int() >= m.consts.items.len) return no(f, "global name");
                    const gn = m.consts.items[lg.name.int()];
                    if (gn != .String) return no(f, "global name kind");
                    const gi = globalIndex(globals, gn.String) orelse return no(f, "global not declared");
                    if (lg.dst.int() >= f.n_locals) return no(f, "global dst");
                    const gt = (try globalTy(gpa, m, globals, gi)) orelse return no(f, "global type");
                    types[lg.dst.int()] = gt;
                    if (gt == .object) {
                        const gf = m.funcById(globals[gi].func).?;
                        cls[lg.dst.int()] = classOfType(m, gf.return_ty);
                    }
                    known[lg.dst.int()] = true;
                },
                .StoreGlobal => |sg| {
                    if (sg.name.int() >= m.consts.items.len) return no(f, "global name");
                    const gn = m.consts.items[sg.name.int()];
                    if (gn != .String) return no(f, "global name kind");
                    const gi = globalIndex(globals, gn.String) orelse return no(f, "global not declared");
                    if (sg.value.int() >= f.n_locals or !known[sg.value.int()]) return no(f, "global value");
                    const gt = (try globalTy(gpa, m, globals, gi)) orelse return no(f, "global type");
                    if (types[sg.value.int()] != gt) {
                        if (traceOn()) std.debug.print("[cgen]   global `{s}` is {s}, stored value is {s}\n", .{ gn.String, @tagName(gt), @tagName(types[sg.value.int()]) });
                        return no(f, "global value type");
                    }
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
                        if (rt == .object) cls[c.dst.int()] = classOfType(m, callee.return_ty);
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
                    if (rr.int() >= f.n_locals or !known[rr.int()]) return null;
                }
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
    return .{ .f = f, .types = types, .cls = cls, .elem = elem, .slot = slot, .n_slots = n_slots, .ret = ret };
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
}

/// A scalar as a `klio_value`, for the moment it crosses into the object world.
fn boxExpr(t: Ty, expr: []const u8, buf: []u8) []const u8 {
    const fname = switch (t) {
        .i32 => "klio_nat_box_int",
        .i64 => "klio_nat_box_long",
        .f64 => "klio_nat_box_double",
        .f32 => "klio_nat_box_float",
        .boolean => "klio_nat_box_bool",
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
    if (c.f.params.len == 0) {
        try w.writeAll("void");
    } else {
        for (c.f.params, 0..) |p, i| {
            if (i != 0) try w.writeAll(", ");
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

fn writeBody(gpa: std.mem.Allocator, w: *std.Io.Writer, m: *const Module, c: *const Compiled, uses_objects: bool, globals: []const Global) !void {
    const f = c.f;
    const live = try reachableBlocks(gpa, f);
    defer gpa.free(live);
    try writeProto(w, c);
    try w.writeAll(" {\n");
    var r: u32 = 0;
    while (r < f.n_locals) : (r += 1) {
        if (c.types[r] == .object) continue;
        try w.print("  {s} r{d} = 0;\n", .{ c.types[r].cName(), r });
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

    try w.writeAll("  goto B0;\n");
    for (f.blocks, 0..) |*blk, bi| {
        if (!live[bi]) continue;
        try w.print("B{d}:;\n", .{bi});
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
                .Move => |mv| {
                    var nb: [32]u8 = undefined;
                    var sb: [32]u8 = undefined;
                    try w.print("  {s} = {s};\n", .{ regName(c, mv.dst.int(), &nb), regName(c, mv.src.int(), &sb) });
                },
                .NewInstance => |ni| {
                    var nb: [32]u8 = undefined;
                    const dst = regName(c, ni.dst.int(), &nb);
                    try w.print("  {s} = klio_nat_alloc_instance(KCLS_{d});\n", .{ dst, ni.class.int() });
                    var k: u32 = 0;
                    while (k < ni.n_args) : (k += 1) {
                        const ar = ni.args.int() + k;
                        var ab: [32]u8 = undefined;
                        var bb: [96]u8 = undefined;
                        try w.print("  klio_nat_set({s}, {d}, {s});\n", .{
                            dst, k, boxExpr(c.types[ar], regName(c, ar, &ab), &bb),
                        });
                    }
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
                    const idx = fieldIndex(m, rc, nm).?;
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
                    const idx = fieldIndex(m, rc, nm).?;
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
            .Return => |ret| {
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
    w: *std.Io.Writer,
    src_path: []const u8,
) Error!bool {
    var accepted: std.ArrayList(Compiled) = .empty;
    defer {
        for (accepted.items) |*c| c.deinit(gpa);
        accepted.deinit(gpa);
    }
    var seen = std.AutoHashMap(u32, void).init(gpa);
    defer seen.deinit();
    var queue: std.ArrayList(*const Func) = .empty;
    defer queue.deinit(gpa);

    // Reachable closure from the entry: only what the program can call is
    // emitted, which is what keeps a whole-stdlib lowering from becoming tens
    // of thousands of C functions.
    try queue.append(gpa, entry);
    try seen.put(entry.id.int(), {});
    // A single refusal anywhere in the reachable set fails the whole emission:
    // a compiled program has no interpreter to fall back INTO, so a body it
    // cannot call is not a slow path, it is a missing one.
    while (queue.pop()) |f| {
        const c = (try eligible(gpa, m, f, globals)) orelse return false;
        try accepted.append(gpa, c);
        for (f.blocks) |*blk| {
            for (blk.insts) |*inst| {
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
                                    try queue.append(gpa, gf);
                                }
                            }
                        }
                    }
                    continue;
                }
                if (inst.* != .Call) continue;
                const callee = m.funcById(inst.Call.func) orelse return false;
                if (isPrintln(callee) or listIntrinsic(callee) != null) continue;
                if (seen.contains(callee.id.int())) continue;
                try seen.put(callee.id.int(), {});
                try queue.append(gpa, callee);
            }
        }
    }

    // Printing a floating value is the one place where C's formatting and
    // Kotlin's disagree, so the helper rides along only when it is used.
    // Classes the program constructs or reads through. Emitted as descriptors
    // and registered before main: a compiled program carries its own layout
    // because there is no module to ask.
    var used_classes: std.ArrayList(u32) = .empty;
    defer used_classes.deinit(gpa);
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
    // A string is a reference too: a program that only concatenates still needs
    // the runtime for its collector and renderer.
    var uses_objects_hint = false;
    var uses_objects = used_classes.items.len != 0;
    for (accepted.items) |*c| {
        for (c.types) |t| {
            if (t == .object) uses_objects = true;
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
    if (used_globals.items.len != 0) uses_objects_hint = true;

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
            const fields = classFields(m, @enumFromInt(cid)).?;
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

    if (used_globals.items.len != 0) {
        try w.print("\n/* Top-level properties. Published to the collector for the life of the\n" ++
            " * program: a global is a root, not a frame slot. */\n", .{});
        try w.print("static klio_value KG[{d}];\n", .{used_globals.items.len});
        try w.print("static klio_nat_frame KGF;\n", .{});
    }

    // Prototypes first: the call graph has cycles (recursion, mutual calls).
    for (accepted.items) |*c| {
        try writeProto(w, c);
        try w.writeAll(";\n");
    }
    try w.writeAll("\n");
    for (accepted.items) |*c| try writeBody(gpa, w, m, c, uses_objects, used_globals.items);

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
