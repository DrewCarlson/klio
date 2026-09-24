//! How a call runs, chosen from the callee's declaration: a static, virtual
//! or interface call, a native, a primitive operation, array access, an
//! inline instantiation, a value invoke or a construction.

const sema = @import("sema");

const ir = @import("../../ir.zig");
const bridge = @import("../../core/bridge.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const operator = @import("operator.zig");

const Builder = builder.Builder;
const Program = builder.Program;
const Error = records.Error;
const CallRec = records.CallRec;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const MethodSlotId = ir.MethodSlotId;
const NativeId = ir.NativeId;
const Reg = ir.Reg;
const Sym = sema.Sym;

pub const How = union(enum) {
    static: FuncId,
    virtual: MethodSlotId,
    interface: struct { iface: ClassId, slot: MethodSlotId },
    native: NativeId,
    /// A `super` call of a member a native implements: that native, which
    /// no receiver's override redirects (`CallNative.direct`).
    super_native: NativeId,
    /// C3's table.
    prim: operator.PrimOp,
    array_get,
    array_set,
    /// D instantiates.
    inline_: FuncId,
    /// `RCallValue`: the run's first register is the function value.
    value,
    ctor: struct { class: ClassId, ctor: FuncId },
};

/// How `rec` runs, before any argument is omitted: `call.emitCall` sends a
/// call with an omitted argument through the callee's defaults bridge.
/// Fails for a callee the bridge gave no identity.
pub fn choose(p: *const Program, rec: *const CallRec) Error!How {
    const s = p.s;
    const br = p.br;
    const callee = rec.callee;
    if (callee == .none) return error.Unrecorded;
    switch (rec.form) {
        .ctor => return .{ .ctor = .{
            .class = classIdOf(br, s.syms.owner(callee)) orelse return error.Unsupported,
            .ctor = funcIdOf(br, callee) orelse return error.Unsupported,
        } },
        // On the instance being built.
        .this_delegation, .super_delegation => return .{ .static = funcIdOf(br, callee) orelse return error.Unsupported },
        // `Iface { ... }` constructs the interface's SAM class.
        .sam_ctor => return .{ .ctor = .{
            .class = samClassOf(s, br, callee) orelse return error.Unsupported,
            .ctor = funcIdOf(br, callee) orelse return error.Unsupported,
        } },
        .value_invoke, .plain, .super_ => {},
    }
    // A function value is invoked by its own body, whether called `f(x)`
    // or `f.invoke(x)`.
    if (isFunctionInvoke(s, callee)) return .value;
    if (p.prims.get(callee)) |op| return .{ .prim = op };
    const f = funcIdOf(br, callee) orelse return error.Unsupported;
    const native = br.nativeOf(callee);
    // An inline function is instantiated from its body; one a native
    // implements (`arrayOf`) is called like any other.
    if (s.syms.flags(callee).inline_ and native == .none) return .{ .inline_ = f };
    // `super` names the declaration that runs, its native included, which
    // no receiver's override may redirect (`NativeRt.slot`).
    if (rec.form == .super_) {
        if (funcNative(br, f) orelse (if (native != .none) native else null)) |id| return .{ .super_native = id };
        return .{ .static = f };
    }
    // Nothing overrides a local, top-level, private or final one.
    if (isLocal(br, f) or !overridable(s, callee)) {
        return if (native != .none) .{ .native = native } else .{ .static = f };
    }
    const slot = slotOf(br, f) orelse return error.Unsupported;
    const owner = s.syms.owner(callee);
    if (s.syms.classInfo(owner).kind == .interface) {
        return .{ .interface = .{ .iface = classIdOf(br, owner) orelse return error.Unsupported, .slot = slot } };
    }
    return .{ .virtual = slot };
}

/// Emits `how` over the argument run `run` of `n` registers into `dst`.
/// `inline_` is instantiated by `call.emitCall`, which holds the lambdas.
pub fn emitHow(b: *Builder, how: How, dst: Reg, run: Reg, n: u32) Error!void {
    switch (how) {
        .static => |f| try b.emit(.{ .CallStatic = .{ .dst = dst, .func = f, .args = run, .n_args = n } }),
        .virtual => |slot| try b.emit(.{ .RCallVirtual = .{ .dst = dst, .slot = slot, .args = run, .n_args = n } }),
        .interface => |x| try b.emit(.{ .CallInterface = .{ .dst = dst, .iface = x.iface, .slot = x.slot, .args = run, .n_args = n } }),
        .native => |id| try b.emit(.{ .CallNative = .{ .dst = dst, .native = id, .args = run, .n_args = n } }),
        .super_native => |id| try b.emit(.{ .CallNative = .{ .dst = dst, .native = id, .args = run, .n_args = n, .direct = true } }),
        .prim => |op| try operator.emitPrim(b, op, dst, run, n),
        .array_get => try operator.emitPrim(b, .array_get, dst, run, n),
        .array_set => try operator.emitPrim(b, .array_set, dst, run, n),
        .inline_ => return error.Unsupported,
        .value => {
            if (n == 0) return error.Unsupported;
            try b.emit(.{ .RCallValue = .{ .dst = dst, .callee = run, .args = Reg.from(run.int() + 1), .n_args = n - 1 } });
        },
        .ctor => |c| try b.emit(.{ .RNewInstance = .{ .dst = dst, .class = c.class, .ctor = c.ctor, .args = run, .n_args = n } }),
    }
}

// ------------------------------------------------------------ identities --

pub fn funcIdOf(br: *const bridge.Bridge, s: Sym) ?FuncId {
    if (s == .none or s.int() >= br.func_of.len) return null;
    const f = br.func_of[s.int()];
    return if (f.int() == bridge.NONE) null else f;
}

pub fn classIdOf(br: *const bridge.Bridge, s: Sym) ?ClassId {
    if (s == .none or s.int() >= br.class_of.len) return null;
    const c = br.class_of[s.int()];
    return if (c.int() == bridge.NONE) null else c;
}

/// The SAM class of the fun interface whose SAM constructor is `ctor`.
pub fn samClassOf(s: *sema.Sema, br: *const bridge.Bridge, ctor: Sym) ?ClassId {
    const iface = s.types.classSym(s.syms.functionInfo(ctor).ret);
    if (iface == .none or iface.int() >= br.sam_class_of.len) return null;
    const c = br.sam_class_of[iface.int()];
    return if (c.int() == bridge.NONE) null else c;
}

/// The root slot a virtual or interface call of `f` names.
pub fn slotOf(br: *const bridge.Bridge, f: FuncId) ?MethodSlotId {
    if (f.int() >= br.slot_of.len) return null;
    const slot = br.slot_of[f.int()];
    return if (slot.int() == bridge.NONE) null else slot;
}

/// The native the tables bind function `f` to, if any.
fn funcNative(br: *const bridge.Bridge, f: FuncId) ?NativeId {
    const r = br.m.resolved orelse return null;
    if (f.int() >= r.func_native.len) return null;
    const n = r.func_native[f.int()];
    return if (n == .none) null else n;
}

/// A lambda, anonymous function or local function: its captures lead its
/// parameters and nothing overrides it.
pub fn isLocal(br: *const bridge.Bridge, f: FuncId) bool {
    return f.int() < br.origin.len and br.origin[f.int()] == .lambda;
}

// --------------------------------------------------------- declarations --

/// Called on an instance: declared in a class and not on the class itself.
pub fn isMember(s: *sema.Sema, f: Sym) bool {
    return s.syms.kind(s.syms.owner(f)) == .class and !s.syms.flags(f).static;
}

/// Whether a subclass can replace member `m`: it is not private or final,
/// and its class can have subclasses.
pub fn overridable(s: *sema.Sema, m: Sym) bool {
    if (!isMember(s, m)) return false;
    const fl = s.syms.flags(m);
    if (fl.visibility == .private or fl.modality == .final) return false;
    const owner = s.syms.owner(m);
    return switch (s.syms.classInfo(owner).kind) {
        .interface, .enum_class => true,
        .class => s.syms.flags(owner).modality != .final,
        .object, .companion, .anonymous, .enum_entry, .annotation => false,
    };
}

/// `invoke` of `FunctionN` or `SuspendFunctionN`: an invoke of a function
/// value, whatever class implements it.
pub fn isFunctionInvoke(s: *sema.Sema, f: Sym) bool {
    if (s.syms.kind(f) != .function) return false;
    const owner = s.syms.owner(f);
    const n: u32 = @intCast(s.syms.functionInfo(f).params.len);
    return (s.function_classes.get(n) orelse Sym.none) == owner or
        (s.suspend_function_classes.get(n) orelse Sym.none) == owner;
}

/// A `FunctionN` or `SuspendFunctionN` class.
pub fn isFunctionClass(s: *sema.Sema, cls: Sym, arity: u32) bool {
    if (cls == .none) return false;
    return (s.function_classes.get(arity) orelse Sym.none) == cls or
        (s.suspend_function_classes.get(arity) orelse Sym.none) == cls;
}
