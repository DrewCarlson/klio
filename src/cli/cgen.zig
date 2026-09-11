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
        else => null,
    };
}

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
    /// Frame slot of each object register, or -1 for a scalar in a C local.
    slot: []i32,
    n_slots: u32,
    ret: Ty,

    pub fn deinit(self: *Compiled, gpa: std.mem.Allocator) void {
        gpa.free(self.types);
        gpa.free(self.cls);
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
        if (tyOf(p.ty) == null) return null;
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

/// The class a declared type names, when the program declares one.
fn classOfType(m: *const Module, t: ir.TypeRef) ?u32 {
    if (t.nullable) return null;
    for (m.classes.items, 0..) |*c, i| {
        if (std.mem.eql(u8, c.name, t.name) or std.mem.eql(u8, c.fqn, t.name)) {
            if (classFields(m, @enumFromInt(i)) == null) return null;
            return @intCast(i);
        }
    }
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

pub fn eligible(gpa: std.mem.Allocator, m: *const Module, f: *const Func) Error!?Compiled {
    if (f.is_suspend) return no(f, "suspend");
    // A method is an ordinary function whose first parameter is the receiver;
    // the call sites already move it into arg 0.
    if (f.has_receiver_param and receiverClass(m, f) == null) return no(f, "receiver class");
    if (!f.hasBody() or f.blocks.len == 0) return no(f, "no body");
    if (f.n_locals == 0) return no(f, "no locals");

    const ret = funcRetTy2(m, f) orelse return no(f, "return type");
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
                    if (c.dst.int() >= f.n_locals) return null;
                    if (c.value.int() >= m.consts.items.len) return null;
                    const t = constTy(m.consts.items[c.value.int()]) orelse return no(f, "const kind");
                    types[c.dst.int()] = t;
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
                    }
                    known[lp.dst.int()] = true;
                },
                .Move => |mv| {
                    if (mv.dst.int() >= f.n_locals or mv.src.int() >= f.n_locals) return no(f, "move reg");
                    if (!known[mv.src.int()]) return no(f, "move source");
                    types[mv.dst.int()] = types[mv.src.int()];
                    cls[mv.dst.int()] = cls[mv.src.int()];
                    known[mv.dst.int()] = true;
                },
                .BinOp => |b| {
                    if (b.dst.int() >= f.n_locals or b.lhs.int() >= f.n_locals or b.rhs.int() >= f.n_locals) return null;
                    if (!known[b.lhs.int()] or !known[b.rhs.int()]) return null;
                    const lt = types[b.lhs.int()];
                    const rt = types[b.rhs.int()];
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
                    const to = numConv(m, cm) orelse return instRefuse(f, inst);
                    if (cm.receiver.int() >= f.n_locals or !known[cm.receiver.int()]) return no(f, "conv receiver");
                    const rt2 = types[cm.receiver.int()];
                    if (rt2 == .boolean or rt2 == .unit) return no(f, "conv receiver type");
                    if (cm.dst.int() >= f.n_locals) return no(f, "conv dst");
                    // Kotlin saturates a floating value to Int.MIN/MAX and maps
                    // NaN to 0; a C cast leaves all three undefined.
                    if (rt2.isFloat() and (to == .i32 or to == .i64)) return no(f, "float to int");
                    types[cm.dst.int()] = to;
                    known[cm.dst.int()] = true;
                },
                .CallVirtual => |cv| {
                    const to = numConvVirtual(m, cv) orelse return instRefuse(f, inst);
                    if (cv.receiver.int() >= f.n_locals or !known[cv.receiver.int()]) return no(f, "conv receiver");
                    const rt3 = types[cv.receiver.int()];
                    if (rt3 == .boolean or rt3 == .unit) return no(f, "conv receiver type");
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
                        if (types[ar] != tyOf(fields[k].ty).?) return no(f, "ctor arg type");
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
                    if (gf.field.int() >= m.consts.items.len) return no(f, "field name");
                    const nm = m.consts.items[gf.field.int()];
                    if (nm != .String) return no(f, "field name kind");
                    const idx = fieldIndex(m, rc, nm.String) orelse return no(f, "field not laid out");
                    const fields = classFields(m, @enumFromInt(rc)).?;
                    if (gf.dst.int() >= f.n_locals) return no(f, "field dst");
                    types[gf.dst.int()] = tyOf(fields[idx].ty).?;
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
                    if (types[sf.value.int()] != tyOf(fields[idx].ty).?) return no(f, "field value type");
                },
                .Call => |c| {
                    if (c.arg_names.len != 0 or c.type_args.len != 0) return no(f, "call arg names/type args");
                    if (c.dst.int() >= f.n_locals) return null;
                    const callee = m.funcById(c.func) orelse return no(f, "call target missing");
                    if (isPrintln(callee)) {
                        if (c.n_args != 1) return no(f, "println arity");
                        const a0 = c.args.int();
                        if (a0 >= f.n_locals or !known[a0]) return no(f, "println arg");
                        if (types[a0] == .unit) return no(f, "println of Unit");
                        types[c.dst.int()] = .unit;
                        known[c.dst.int()] = true;
                    } else {
                        if (callee.params.len != c.n_args) return no(f, "call arity");
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
    var n_slots: u32 = 0;
    var r: u32 = 0;
    while (r < f.n_locals) : (r += 1) {
        if (types[r] != .object) continue;
        slot[r] = @intCast(n_slots);
        n_slots += 1;
    }
    return .{ .f = f, .types = types, .cls = cls, .slot = slot, .n_slots = n_slots, .ret = ret };
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

fn writeBody(gpa: std.mem.Allocator, w: *std.Io.Writer, m: *const Module, c: *const Compiled, uses_objects: bool) !void {
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
                    try w.print("  r{d} = ", .{k.dst.int()});
                    try writeConst(w, m.consts.items[k.value.int()]);
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
                    const op = cOp(b.op).?;
                    if ((b.op == .Div or b.op == .Mod) and !dt.isFloat() and !isCmp(b.op)) {
                        try writeDivGuard(w, b.rhs.int());
                    }
                    if (b.op == .UShr) {
                        const lt = c.types[b.lhs.int()];
                        const ut: []const u8 = if (lt == .i64) "uint64_t" else "uint32_t";
                        try w.print("  r{d} = ({s})(({s})r{d} >> (r{d} & {d}));\n", .{
                            b.dst.int(), dt.cName(), ut, b.lhs.int(), b.rhs.int(),
                            @as(u32, if (lt == .i64) 63 else 31),
                        });
                    } else if (b.op == .Shl or b.op == .Shr) {
                        // Kotlin masks the shift count; C leaves an over-wide
                        // shift undefined.
                        const lt = c.types[b.lhs.int()];
                        try w.print("  r{d} = ({s})(r{d} {s} (r{d} & {d}));\n", .{
                            b.dst.int(), dt.cName(), b.lhs.int(), op, b.rhs.int(),
                            @as(u32, if (lt == .i64) 63 else 31),
                        });
                    } else {
                        try w.print("  r{d} = ({s})(({s})r{d} {s} ({s})r{d});\n", .{
                            b.dst.int(),   dt.cName(),
                            if (isCmp(b.op)) promote(c.types[b.lhs.int()], c.types[b.rhs.int()]).?.cName() else dt.cName(),
                            b.lhs.int(),   op,
                            if (isCmp(b.op)) promote(c.types[b.lhs.int()], c.types[b.rhs.int()]).?.cName() else dt.cName(),
                            b.rhs.int(),
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
                    const t = c.types[cm.dst.int()];
                    const from = c.types[cm.receiver.int()];
                    if (t == .i32 and from.isFloat()) unreachable;
                    try w.print("  r{d} = ({s})r{d};\n", .{ cm.dst.int(), t.cName(), cm.receiver.int() });
                },
                .CallVirtual => |cv| {
                    const t = c.types[cv.dst.int()];
                    try w.print("  r{d} = ({s})r{d};\n", .{ cv.dst.int(), t.cName(), cv.receiver.int() });
                },
                .Call => |call| {
                    const callee = m.funcById(call.func).?;
                    if (isPrintln(callee)) {
                        const a0 = call.args.int();
                        const at = c.types[a0];
                        const fmt: []const u8 = switch (at) {
                            .i32 => "%\" PRId32 \"",
                            .i64 => "%\" PRId64 \"",
                            else => "",
                        };
                        if (at == .boolean) {
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
        const c = (try eligible(gpa, m, f)) orelse return false;
        try accepted.append(gpa, c);
        for (f.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (inst.* != .Call) continue;
                const callee = m.funcById(inst.Call.func) orelse return false;
                if (isPrintln(callee)) continue;
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
            var seen_cls = false;
            for (used_classes.items) |u| {
                if (u == cid) seen_cls = true;
            }
            if (!seen_cls) try used_classes.append(gpa, cid);
        }
    }
    const uses_objects = used_classes.items.len != 0;

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
    if (needs_div) try w.writeAll(
        \\/* Kotlin throws on integer division by zero; C leaves it undefined. */
        \\static void klio_arith_zero(void) {
        \\  fprintf(stderr, "Exception in thread \"main\" java.lang.ArithmeticException: / by zero\n");
        \\  exit(1);
        \\}
        \\
        \\
    );
    if (needs_fp) try w.writeAll(
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

    // Prototypes first: the call graph has cycles (recursion, mutual calls).
    for (accepted.items) |*c| {
        try writeProto(w, c);
        try w.writeAll(";\n");
    }
    try w.writeAll("\n");
    for (accepted.items) |*c| try writeBody(gpa, w, m, c, uses_objects);

    try w.writeAll("int main(void) {\n");
    if (uses_objects) try w.writeAll("  klio_nat_init(0);\n  klio_register_classes();\n  klio_nat_begin();\n");
    try w.writeAll("  ");
    try writeSymbol(w, entry);
    try w.writeAll("();\n  return 0;\n}\n");
    return true;
}
