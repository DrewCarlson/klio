//! What the emitter resolves about a program before deciding anything: member
//! lookup, intrinsic recognition, bare-name binding, access plans, and refusals.
const std = @import("std");
const stdlib = @import("stdlib");
const member_dispatch = @import("interp_ir").member_dispatch;
const ir = @import("ir");
const Func = ir.Func;
const Module = ir.Module;
const cgen = @import("../cgen.zig");

const BareResolution = cgen.BareResolution;
const Compiled = cgen.Compiled;
const EnumEntryInfo = cgen.EnumEntryInfo;
const Error = cgen.Error;
const Global = cgen.Global;
const Laid = cgen.Laid;
const Program = cgen.Program;
const Ty = cgen.Ty;
const classIndexOfName = cgen.classIndexOfName;
const eligible = cgen.eligible;
const fieldIndex = cgen.fieldIndex;
const funcRetTy2 = cgen.funcRetTy2;
const functionTypeArity = cgen.functionTypeArity;
const isArrayTypeName = cgen.isArrayTypeName;
const isBackingAccess = cgen.isBackingAccess;
const isBuiltinCls = cgen.isBuiltinCls;
const layoutFor = cgen.layoutFor;
const plainFieldName = cgen.plainFieldName;
const primArrayKind = cgen.primArrayKind;
const refElemOf = cgen.refElemOf;
const simpleName = cgen.simpleName;
const tyOf = cgen.tyOf;


/// A zero-argument numeric conversion (`x.toLong()`), lowered as a `CallMember`. Every
/// direction is a C cast, but Kotlin's `toInt()` on a floating value saturates, so it is refused.
pub fn numConv(m: *const Module, cm: anytype) ?Ty {
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

pub fn numConvVirtual(m: *const Module, cv: anytype) ?Ty {
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

/// Stdlib entries the backend performs directly: their Kotlin bodies are generic and variadic.
pub const ListIntrinsic = enum { list_of, mutable_list_of };

pub fn listIntrinsic(f: *const Func) ?ListIntrinsic {
    if (std.mem.eql(u8, f.fqn, "kotlin.collections.listOf")) return .list_of;
    if (std.mem.eql(u8, f.fqn, "kotlin.collections.mutableListOf")) return .mutable_list_of;
    return null;
}

/// The member calls a compiled program hands back to the runtime, from the interpreter's
/// own slot classification.
pub fn hostMemberOp(decl: *const Func) ?member_dispatch.HostSlotOp {
    const op = member_dispatch.hostSlotOpOfFqn(decl.fqn) orelse return null;
    return switch (op) {
        // The iteration protocol reads only the container and the iterator.
        .iterator_protocol, .collection_iterator => op,
        else => null,
    };
}

pub fn stdlibEntry(f: *const Func) ?[]const u8 {
    if (f.fqn.len == 0) return null;
    if (stdlib.implementations.lookup(f.fqn) != null) return f.fqn;
    // A declaration reached through a receiver is registered under the RECEIVER-QUALIFIED
    // form: `kotlin.text.substring` is implemented as `kotlin.String.substring`, and an
    // extension's receiver is its first parameter whether or not it carries the flag.
    const recv: ?[]const u8 = if (f.params.len != 0 and f.params[0].ty.name.len != 0)
        simpleName(f.params[0].ty.name)
    else
        null;
    if (stdlib.implementations.declarationHostSymbol(f.fqn, recv, f.name)) |sym| return sym;
    if (recv) |rn| {
        var buf: [160]u8 = undefined;
        const qualified = std.fmt.bufPrint(&buf, "kotlin.{s}.{s}", .{ rn, f.name }) catch return null;
        if (stdlib.implementations.lookup(qualified)) |_| {
            // The borrowed buffer dies with this call, so hand back the table's own copy.
            var it = stdlib.implementations.allFqns();
            while (it.next()) |cand| {
                if (std.mem.eql(u8, cand, qualified)) return cand;
            }
        }
    }
    return null;
}

/// `launch { … }`: a child coroutine queued on the running driver, not a suspension.
pub fn isLaunch(f: *const Func) bool {
    return std.mem.eql(u8, f.fqn, "kotlinx.coroutines.launch") or
        std.mem.eql(u8, f.fqn, "kotlinx.coroutines.CoroutineScope.launch");
}

/// `delay(millis)`: the primitive suspension, parking the CALLING frame, so no callee compiles.
pub fn isDelay(f: *const Func) bool {
    return std.mem.eql(u8, f.fqn, "kotlinx.coroutines.delay");
}

/// `runBlocking { … }`: drives its block on the interpreter's own scheduler, so compiled
/// and interpreted programs order their coroutines identically.
pub fn isRunBlocking(f: *const Func) bool {
    return std.mem.eql(u8, f.fqn, "kotlinx.coroutines.runBlocking");
}

pub fn isArrayOfNulls(f: *const Func) bool {
    return f.params.len == 1 and std.mem.startsWith(u8, f.fqn, "kotlin.") and
        std.mem.eql(u8, f.name, "arrayOfNulls");
}

/// A stdlib function with no Kotlin body: the backend performs it directly.
pub const ScalarIntrinsic = enum { max, min, abs, print };

pub fn scalarIntrinsic(f: *const Func) ?ScalarIntrinsic {
    if (f.hasBody()) return null;
    if (f.params.len == 2 and std.mem.eql(u8, f.fqn, "kotlin.math.max")) return .max;
    if (f.params.len == 2 and std.mem.eql(u8, f.fqn, "kotlin.math.min")) return .min;
    if (f.params.len == 1 and std.mem.eql(u8, f.fqn, "kotlin.math.abs")) return .abs;
    if (f.params.len == 1 and (std.mem.eql(u8, f.fqn, "kotlin.io.print") or std.mem.eql(u8, f.fqn, "print"))) return .print;
    return null;
}

/// The method of `cls` implementing a virtual slot: the root declaration's name and arity.
pub fn slotImpl(m: *const Module, prog: Program, cid: u32, slot: ir.MethodSlotId) ?*const Func {
    const root = m.funcById(ir.FuncId.from(slot.int())) orelse return null;
    // A class answers a slot only if its TYPE includes the declaration; name and arity alone
    // make every same-named stdlib method look like an override.
    if (!typeHasSlot(m, cid, root)) return null;
    var fallback: ?*const Func = null;
    var cur: ?u32 = cid;
    var depth: u32 = 0;
    while (cur) |ci| : (depth += 1) {
        if (depth > 32 or ci >= m.classes.items.len) break;
        for (m.classes.items[ci].methods) |fid| {
            const mf = m.funcById(fid) orelse continue;
            if (!std.mem.eql(u8, mf.name, root.name)) continue;
            if (!mf.hasBody()) continue;
            if (mf.params.len == root.params.len) return mf;
            // An override may declare extra parameters carrying defaults and still answer the slot.
            if (mf.params.len > root.params.len and fallback == null) fallback = mf;
        }
        if (fallback != null) return fallback;
        // An interface may carry a default body, inherited by a class that does not override.
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

/// The greatest parameter count a bound call may have; a wider signature is refused.
pub const MAX_CALL_PARAMS: u32 = 32;

/// Which argument fills each declared parameter: positional in order, named by name,
/// reordered into the callee's order; an unbound parameter takes its default.
pub const ArgBinding = struct {
    regs: [MAX_CALL_PARAMS]?u32 = @splat(null),
    n: u32 = 0,
    /// The `vararg` parameter: trailing positional arguments collect into an array, not `regs`.
    vararg_param: ?u32 = null,
    vararg_base: u32 = 0,
    vararg_n: u32 = 0,
};

pub fn bindCallArgs(
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
        // From the `vararg` parameter on, a positional argument is an ELEMENT of it, and a
        // later parameter can only be filled by name.
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

/// The declaration a member call binds to: the TOPMOST class on the receiver's chain
/// declaring this name at this arity, so the call dispatches as a `CallVirtual` does.
pub fn memberRoot(m: *const Module, prog: Program, cid: u32, name: []const u8, n_args: u32) ?*const Func {
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
        // An interface a class implements declares the member too, and is the root when it does.
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

/// Reconcile each register's type with the one it settled on, returning the register that
/// took a second type and so cannot share one C local.
pub fn settleTypes(types: []Ty, known: []const bool, settled: []Ty, has_settled: []bool) ?u32 {
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

pub fn noReg(f: *const Func, reg: u32) ?Compiled {
    if (traceOn()) std.debug.print("[cgen] refuse {s}: register type varies r{d}\n", .{ f.name, reg });
    return null;
}

/// The declared type of an array constructor's initializer. `IntArray(size, init)` is `expect
/// inline` with no Kotlin body carrying a signature, so this is the builtin's own: the result
/// is the element type, the one parameter the index.
pub fn bareTy(name: []const u8) ir.TypeRef {
    return .{ .name = name, .nullable = false, .args = &.{} };
}

/// `(Int) -> E` per array element kind, in `klio_nat_prim_array` order, `Array<T>` last.
pub var array_init_args = [_][2]ir.TypeRef{
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

pub fn arrayInitFnType(class_name: []const u8) ?ir.TypeRef {
    const slot: usize = primArrayKind(class_name) orelse
        (if (isArrayTypeName(class_name)) array_init_args.len - 1 else return null);
    return .{ .name = "Function1", .nullable = false, .args = array_init_args[slot][0..] };
}

/// The function type a lambda is expected to have, read off where its value goes: its own
/// parameters carry no declared types.
pub fn expectedFnType(m: *const Module, f: *const Func, dst: ir.Reg) ?ir.TypeRef {
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

/// The parameter list a lambda body compiles against, from the function type its value is
/// expected to have: the last `arity` arguments before the trailing result, since a receiver
/// or `#suspend` marker rides ahead of them.
pub fn lambdaParams(gpa: std.mem.Allocator, body: *const Func, t: ir.TypeRef) Error!?[]ir.Param {
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

/// Whether a lambda register is used as anything but the callee of a direct call. Such a
/// use needs a closure object; a direct call just passes the captures.
pub fn lambdaEscapes(m: *const Module, f: *const Func, dst: ir.Reg) bool {
    for (f.blocks) |*blk| {
        for (blk.insts) |*inst| {
            if (inst.* == .CallValue and inst.CallValue.callee.int() == dst.int()) continue;
            if (inst.* == .AstLambda and inst.AstLambda.dst.int() == dst.int()) continue;
            // An array constructor's initializer is called once per index, not kept.
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

/// Whether an instruction names this register: an unenumerated shape reads as a use.
pub fn instReadsReg(inst: *const ir.Inst, r: ir.Reg) bool {
    const info = @typeInfo(ir.Inst).@"union";
    inline for (info.fields) |uf| {
        if (inst.* == @field(std.meta.Tag(ir.Inst), uf.name)) {
            const payload = @field(inst.*, uf.name);
            if (@typeInfo(@TypeOf(payload)) == .@"struct") {
                // An argument list is a base register plus a count, so later ones are implicit.
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

pub fn resolveBare(
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

pub fn bareOn(
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

/// One property read through a type that declares it without storage; the class that
/// answers may store it rather than compute it.
pub const PropUse = struct { name: []const u8, cid: u32, ret: Ty };

pub const LambdaUse = struct { body: ir.FuncId, n_caps: u32, arity: u32, ret: Ty };

/// Where a lambda that captures nothing keeps its ONE instance: Kotlin makes such a
/// literal a singleton, so `===` holds across every evaluation of it.
pub fn lambdaSingletonSlot(used: []const LambdaUse, body: ir.FuncId) ?usize {
    var n: usize = 0;
    for (used) |lu| {
        if (lu.n_caps != 0) continue;
        if (lu.body == body) return n;
        n += 1;
    }
    return null;
}

/// Whether a class's TYPE includes the declaration a slot is numbered by: the root names
/// its owner in its fqn, and a class reaching that owner has the member even with no body.
pub fn typeHasSlot(m: *const Module, cid: u32, root: *const Func) bool {
    const dot = std.mem.findScalarLast(u8, root.fqn, '.') orelse return false;
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

/// How a property read or write on a receiver of a known class is performed, decided in
/// one place so every pass agrees.
pub const AccessPlan = union(enum) {
    field: u32,
    accessor: ir.FuncId,
    /// Through a dispatcher: which class answers is a run-time question.
    virtual,
    none,
};

pub fn accessPlan(m: *const Module, prog: Program, rc: u32, name: []const u8, set: bool) AccessPlan {
    if (isBuiltinCls(rc)) return .none;
    // A `field` access inside an accessor reaches the storage; anything else goes through
    // the accessor when the class declares one.
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

/// Where a property access lands: a name the receiver's own class lacks may belong to its
/// COMPANION, the singleton the access runs against.
pub fn accessOwner(m: *const Module, prog: Program, rc: u32, name: []const u8, set: bool) ?u32 {
    if (std.meta.activeTag(accessPlan(m, prog, rc, name, set)) != .none) return null;
    if (rc >= m.classes.items.len) return null;
    const cc = companionObjectNamed(m, prog, m.classes.items[rc].fqn) orelse return null;
    if (std.meta.activeTag(accessPlan(m, prog, cc, name, set)) == .none) return null;
    return cc;
}

pub const VirtualProp = struct { ret: Ty, cls: ?u32, elem: Ty };

pub fn typeReaches(m: *const Module, sub: u32, base: u32) bool {
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

/// Reading `name` off a receiver of class `rc` where no class in that position stores it
/// but one beneath computes it. Null when candidates disagree: one dispatcher signature.
pub fn virtualProp(m: *const Module, prog: Program, rc: u32, name: []const u8) ?VirtualProp {
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

/// The `toString` a class's own type declares. Kotlin renders by calling it, so a compiled
/// program calls it rather than using the runtime's renderer.
pub fn toStringOf(m: *const Module, prog: Program, rc: u32) ?*const Func {
    if (isBuiltinCls(rc)) return null;
    const root = memberRoot(m, prog, rc, "toString", 0) orelse return null;
    // A declaration with no body anywhere below is the universal one the renderer does.
    if (slotImpl(m, prog, rc, ir.MethodSlotId.from(root.id.int())) == null) return null;
    return root;
}

pub const SlotUse = struct { slot: u32, n_args: u32 };

pub fn listMemberName(m: *const Module, slot: ir.MethodSlotId) ?[]const u8 {
    const decl = m.funcById(ir.FuncId.from(slot.int())) orelse return null;
    return decl.name;
}

pub fn isPrintln(f: *const Func) bool {
    // Recognised by NAME: a bodyless stdlib entry's parameter list varies with the caller.
    return std.mem.eql(u8, f.fqn, "kotlin.io.println") or std.mem.eql(u8, f.fqn, "println");
}

/// `KLIO_CGEN_TRACE=1` names every function the subset refuses and why.
pub fn traceOn() bool {
    return std.c.getenv("KLIO_CGEN_TRACE") != null;
}

pub fn layoutNo(c: *const ir.Class, comptime why: []const u8) ?Laid {
    if (traceOn() and !cgen.layout_quiet) std.debug.print("[cgen] layout {s}: " ++ why ++ "\n", .{c.name});
    return null;
}

pub fn layoutNoTy(c: *const ir.Class, comptime why: []const u8, t: ir.TypeRef) ?Laid {
    if (traceOn() and !cgen.layout_quiet) std.debug.print("[cgen] layout {s}: " ++ why ++ " {s}\n", .{ c.name, t.name });
    return null;
}

pub fn instRefuse(f: *const Func, inst: *const ir.Inst) ?Compiled {
    if (traceOn()) std.debug.print("[cgen] refuse {s}: inst {s}\n", .{ f.fqn, @tagName(inst.*) });
    return null;
}

pub fn instRefuseNamed(m: *const Module, f: *const Func, inst: *const ir.Inst, name_id: ir.ConstId) ?Compiled {
    if (traceOn()) {
        const nm = if (name_id.int() < m.consts.items.len) m.consts.items[name_id.int()] else ir.Const{ .Unit = {} };
        std.debug.print("[cgen] refuse {s}: inst {s} `{s}`\n", .{
            f.fqn, @tagName(inst.*), if (nm == .String) nm.String else "?",
        });
    }
    return null;
}

pub fn noCallee(f: *const Func, callee: *const Func, comptime why: []const u8) ?Compiled {
    if (traceOn()) std.debug.print("[cgen] refuse {s}: " ++ why ++ " `{s}`\n", .{ f.fqn, callee.fqn });
    return null;
}

pub fn no(f: *const Func, comptime why: []const u8) ?Compiled {
    if (traceOn()) std.debug.print("[cgen] refuse {s}: " ++ why ++ "\n", .{f.fqn});
    return null;
}

pub fn noName(f: *const Func, comptime why: []const u8, name: []const u8) ?Compiled {
    if (traceOn()) std.debug.print("[cgen] refuse {s}: " ++ why ++ " `{s}`\n", .{ f.name, name });
    return null;
}

/// The class a receiver parameter names, for a method compiled as a C function taking `this` first.
pub fn receiverClass(m: *const Module, f: *const Func) ?u32 {
    if (!f.has_receiver_param or f.params.len == 0) return null;
    return classIndexOfName(m, f.params[0].ty);
}

/// A top-level property's machine type, from what its initializer thunk compiles to: the
/// declaration often carries no annotation (`var counter = 0`).
pub fn globalTy(gpa: std.mem.Allocator, m: *const Module, prog: Program, globals: []const Global, idx: usize) Error!?Ty {
    const gf = m.funcById(globals[idx].func) orelse return null;
    var c = (try eligible(gpa, m, prog, gf, globals, null, &.{})) orelse return null;
    defer c.deinit(gpa);
    return c.ret;
}

/// The class id of an `object` declaration with this name: it reads as its single instance.
pub fn objectClassNamed(m: *const Module, prog: Program, name: []const u8) ?u32 {
    for (m.classes.items, 0..) |*c, i| {
        if (!c.is_object) continue;
        if (!std.mem.eql(u8, c.name, name) and !std.mem.eql(u8, c.fqn, name)) continue;
        if (prog.of(@intCast(i)) == null) return null;
        return @intCast(i);
    }
    return null;
}

/// The object a CLASS name denotes as a qualifier: `Config` in `Config.Default` is its
/// companion, which carries the members the qualifier reads.
pub fn companionObjectNamed(m: *const Module, prog: Program, name: []const u8) ?u32 {
    if (name.len == 0) return null;
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}.Companion", .{name})) |qualified| {
        if (objectClassNamed(m, prog, qualified)) |oc| return oc;
    } else |_| {}
    var buf2: [512]u8 = undefined;
    const simple = std.fmt.bufPrint(&buf2, "{s}.Companion", .{simpleName(name)}) catch return null;
    return objectClassNamed(m, prog, simple);
}

/// The object a call or read written on a class NAME runs against: that class's companion.
pub fn companionReceiver(m: *const Module, prog: Program, types: []const Ty, cls: []const ?u32, r: u32) ?u32 {
    const sc = staticClassOf(types, cls, r) orelse return null;
    if (sc >= m.classes.items.len) return null;
    return companionObjectNamed(m, prog, m.classes.items[sc].fqn);
}

/// The top-level function a bare name in value position denotes (`::twice`), only when one
/// declaration owns the name.
pub fn topLevelFuncNamed(m: *const Module, name: []const u8) ?*const ir.Func {
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

/// The declaration a bare call binds to when the lowering left it open: among the
/// top-level functions of that name, the one whose parameters these arguments fit. A
/// machine type fits a reference parameter (it boxes) and a machine one only when
/// identical; most exact matches wins, and a tie is a refusal.
pub fn bareCallTarget(
    m: *const Module,
    prog: Program,
    name: []const u8,
    types: []const Ty,
    base: u32,
    n: u32,
    arg_names: []const ?ir.ConstId,
) ?*const ir.Func {
    var best: ?*const ir.Func = null;
    var best_score: u32 = 0;
    var best_defaults: u32 = 0;
    var tied = false;
    for (m.funcs.items) |*cand| {
        if (!cand.hasBody() or cand.has_receiver_param) continue;
        if (!std.mem.eql(u8, cand.name, name)) continue;
        if (cand.params.len < n) continue;
        const bnd = bindCallArgs(m, cand.params, base, n, arg_names) orelse continue;
        var fits = true;
        // Kotlin prefers the more specific declaration, which separates `atomic(Int)` from
        // `atomic(T)`, and prefers one that needs no default over one that does.
        var score: u32 = 0;
        var defaults_used: u32 = 0;
        for (cand.params, 0..) |p, i| {
            if (p.is_vararg) {
                fits = false;
                break;
            }
            const reg = bnd.regs[i] orelse {
                if (prog.defaultThunk(cand.id, @intCast(i)) == null) fits = false;
                if (!fits) break;
                defaults_used += 1;
                continue;
            };
            if (tyOf(p.ty)) |want| {
                if (want != types[reg]) {
                    fits = false;
                    break;
                }
                score += 1;
            } else if (classIndexOfName(m, p.ty) != null) {
                score += 1;
            }
        }
        if (!fits) continue;
        const better = best == null or defaults_used < best_defaults or
            (defaults_used == best_defaults and score > best_score);
        const same = best != null and defaults_used == best_defaults and score == best_score;
        if (better) {
            best = cand;
            best_score = score;
            best_defaults = defaults_used;
            tied = false;
        } else if (same) {
            tied = true;
        }
    }
    // Two equally specific declarations is a question about scope this pass does not answer.
    if (tied) return null;
    return best;
}

/// Whether these arguments cannot settle a name several declarations answer: such a name
/// is re-resolved at run time, so a compiled program must not freeze the recorded pick.
pub fn ambiguousOverload(
    m: *const Module,
    prog: Program,
    name: []const u8,
    types: []const Ty,
    base: u32,
    n: u32,
    arg_names: []const ?ir.ConstId,
) bool {
    if (bareCallTarget(m, prog, name, types, base, n, arg_names) != null) return false;
    var seen_one = false;
    for (m.funcs.items) |*cand| {
        if (!cand.hasBody() or cand.has_receiver_param) continue;
        if (!std.mem.eql(u8, cand.name, name)) continue;
        if (seen_one) return true;
        seen_one = true;
    }
    return false;
}

/// Whether a class's primary constructor also takes these arguments, the constructor
/// versus factory question. Types match EXACTLY: Kotlin converts nothing implicitly when
/// it picks an overload, so a `Long` argument does not reach a `ULong` parameter.
pub fn ctorFits(
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

pub fn classQualifierNamed(m: *const Module, name: []const u8) ?u32 {
    for (m.classes.items, 0..) |*c, i| {
        if (std.mem.eql(u8, c.name, name) or std.mem.eql(u8, c.fqn, name)) return @intCast(i);
    }
    return null;
}

pub fn qualifierOwnerFqn(fqn: []const u8) []const u8 {
    const tail = ".Companion";
    if (std.mem.endsWith(u8, fqn, tail)) return fqn[0 .. fqn.len - tail.len];
    return fqn;
}

pub fn nestedClassNamed(m: *const Module, owner_fqn: []const u8, name: []const u8) ?u32 {
    var buf: [512]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "{s}.{s}", .{ owner_fqn, name }) catch return null;
    for (m.classes.items, 0..) |*c, i| {
        if (std.mem.eql(u8, c.fqn, want)) return @intCast(i);
    }
    return null;
}

pub fn isDispatched(slots: []const SlotUse, slot: u32) bool {
    for (slots) |u| {
        if (u.slot == slot) return true;
    }
    return false;
}

/// One instance built once and rooted for the program's life: an `object`, or an enum entry.
pub const SingletonUse = struct { cid: u32, entry: ?u32 = null };

pub fn singletonSlot(singletons: []const SingletonUse, cid: u32, entry: ?u32) ?usize {
    for (singletons, 0..) |s2, i| {
        if (s2.cid != cid) continue;
        if (s2.entry == null and entry == null) return i;
        if (s2.entry != null and entry != null and s2.entry.? == entry.?) return i;
    }
    return null;
}

/// The enum class a bare name refers to: a qualifier, not storage (`Color.RED`).
pub fn enumClassNamed(m: *const Module, prog: Program, name: []const u8) ?u32 {
    for (m.classes.items, 0..) |*c, i| {
        if (!c.is_enum) continue;
        if (!std.mem.eql(u8, c.name, name) and !std.mem.eql(u8, c.fqn, name)) continue;
        if (prog.of(@intCast(i)) == null) return null;
        return @intCast(i);
    }
    return null;
}

pub fn enumEntryIndex(m: *const Module, prog: Program, cid: u32, name: []const u8) ?u32 {
    if (cid >= m.classes.items.len) return null;
    if (layoutFor(prog.layouts, &m.classes.items[cid])) |l| {
        for (l.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return @intCast(i);
        }
    }
    return null;
}

/// A register naming a CLASS rather than holding a value: typed Unit with the class recorded.
pub fn staticClassOf(types: []const Ty, cls: []const ?u32, r: u32) ?u32 {
    if (types[r] != .unit) return null;
    return cls[r];
}

pub fn enumEntries(m: *const Module, prog: Program, cid: u32) []const EnumEntryInfo {
    if (cid >= m.classes.items.len) return &.{};
    if (layoutFor(prog.layouts, &m.classes.items[cid])) |l| return l.entries;
    return &.{};
}

pub fn globalIndex(globals: []const Global, name: []const u8) ?usize {
    for (globals, 0..) |g, i| {
        if (std.mem.eql(u8, g.name, name)) return i;
    }
    return null;
}
