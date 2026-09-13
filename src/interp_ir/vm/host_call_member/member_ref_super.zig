//! Member references, `super.foo(...)`, `this@Outer`, and the serializer target a
//! `@Serializer(forClass = ...)` declaration stands for.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const VmHost = vmhost.VmHost;
const trace = @import("../trace.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const Func = ir.Func;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;

const applicability_probe = @import("applicability_probe.zig");
const isScalarKindName = applicability_probe.isScalarKindName;
const pickMethodOverload = applicability_probe.pickMethodOverload;

const ext_fallback = @import("ext_fallback.zig");
const instanceOuterLink = ext_fallback.instanceOuterLink;

const flat_call = @import("flat_call.zig");
const debugClassNameOf = flat_call.debugClassNameOf;

const hcm = @import("../host_call_member.zig");
const callFuncRec = hcm.callFuncRec;
const callMemberRec = hcm.callMemberRec;
const newInstanceById = hcm.newInstanceById;
const simpleName = hcm.simpleName;
const typeErr = hcm.typeErr;

const member_presence = @import("member_presence.zig");
const enclosingThisChain = member_presence.enclosingThisChain;

const receiver_probe = @import("receiver_probe.zig");
const isFunctionTypeRefResolved = receiver_probe.isFunctionTypeRefResolved;
const receiverImplementsOwnerIdentity = receiver_probe.receiverImplementsOwnerIdentity;
const receiverImplementsType = receiver_probe.receiverImplementsType;

const static_tail = @import("static_tail.zig");
const freeDispatchMiss = static_tail.freeDispatchMiss;

const stdlib_tail = @import("stdlib_tail.zig");
const inheritedInstanceToString = stdlib_tail.inheritedInstanceToString;
const instanceIsThrowable = stdlib_tail.instanceIsThrowable;

/// A minimal `KClass` value carrying just a simple name (the last FQN
/// segment) and the fully-qualified name. Enough for `simpleName`,
/// `qualifiedName`, and FQN-keyed equality — used to give a builtin value or a
/// classId-less type a class literal.
pub fn syntheticClassFromFqn(allocator: Allocator, fqn: []const u8) Allocator.Error!Value {
    const dot = std.mem.lastIndexOfScalar(u8, fqn, '.');
    const simple = if (dot) |i| fqn[i + 1 ..] else fqn;
    const cd = try ObjRef(ClassDef).init(allocator, .{
        .name = try allocator.dupe(u8, simple),
        .fqn = try allocator.dupe(u8, fqn),
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = false,
        .is_sealed = false,
        .supertype_names = &.{},
        .parent = null,
        .interfaces = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = false,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .nested_classes = &.{},
        .captured_env = try ObjRef(runtime.Env).init(allocator, runtime.Env.init(allocator)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    });
    return .{ .Class = cd };
}

/// True when `simple` names an unsigned primitive-array type, whose bare name
/// lowers to a constructor value (no IR classId) rather than a class.
pub fn isUnsignedArrayName(simple: []const u8) bool {
    const known = [_][]const u8{ "UIntArray", "ULongArray", "UByteArray", "UShortArray" };
    for (known) |k| {
        if (std.mem.eql(u8, simple, k)) return true;
    }
    return false;
}

pub fn memberRef(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return memberRefResolved(self, allocator, receiver, name, null);
}

pub fn memberRefExact(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    func: FuncId,
) Allocator.Error!EvalResult {
    return memberRefResolved(self, allocator, receiver, name, func);
}

/// The value-parameter count of the member a bound reference names, so the
/// reference can report the `FunctionN` it satisfies. Null when the target
/// cannot be identified (an unbound/type-form reference, a dynamic name).
pub fn boundRefArity(self: *VmHost, receiver: *const Value, name: []const u8, func: ?FuncId) ?usize {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    if (func) |fid| {
        if (mod.funcById(fid)) |f| {
            const skip: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            return f.params.len - skip;
        }
    }
    if (receiver.* != .Instance) return null;
    const cls_fqn = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    var found: ?usize = null;
    for (mod.memberDecls(cls_fqn, name)) |fid| {
        const f = mod.funcById(fid) orelse continue;
        const skip: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const n = f.params.len - skip;
        if (found != null and found.? != n) return null; // overloaded: no single arity
        found = n;
    }
    return found;
}

pub fn memberRefResolved(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    func: ?FuncId,
) Allocator.Error!EvalResult {
    // `X::class` is a class reference — return the class itself. For an
    // instance receiver, reach into the runtime ClassDef.
    if (std.mem.eql(u8, name, "class")) {
        if (receiver.* == .Instance) {
            const cls: ObjRef(ClassDef) = blk: {
                const ig = receiver.Instance.borrow();
                defer ig.deinit();
                break :blk ig.get().class.clone();
            };
            // `A::class` on a class that has a companion reaches here with
            // the COMPANION instance (the bare name's global is the
            // companion); the class literal is the owner, never the
            // companion's own class.
            const cv = Value{ .Class = cls };
            const is_companion = blk: {
                const cg = cls.borrow();
                defer cg.deinit();
                const n = cg.get().name;
                break :blk std.mem.endsWith(u8, n, "$Companion") or std.mem.endsWith(u8, n, ".Companion") or std.mem.eql(u8, n, "Companion");
            };
            if (is_companion) {
                if (try companionOwnerClassValue(self, &cv)) |owner| {
                    cls.deinit();
                    return .{ .ok = owner };
                }
            }
            return .{ .ok = cv };
        }
        // A `Type::class` value is already a class literal.
        if (receiver.* == .Class) return .{ .ok = receiver.* };
        // An unsigned-array TYPE literal lowers to its constructor
        // (`ULongArray::class`): recover the type name from the constructor.
        if (receiver.* == .Intrinsic) {
            const dot = std.mem.lastIndexOfScalar(u8, receiver.Intrinsic.fqn, '.');
            const simple = if (dot) |i| receiver.Intrinsic.fqn[i + 1 ..] else receiver.Intrinsic.fqn;
            if (isUnsignedArrayName(simple)) return .{ .ok = try syntheticClassFromFqn(allocator, receiver.Intrinsic.fqn) };
            return .{ .ok = try syntheticClassFromFqn(allocator, receiver.typeFqn()) };
        }
        // A builtin throwable carries its dynamic class in its `fqn` field;
        // the static `typeFqn` would collapse every one to `kotlin.Throwable`.
        if (receiver.* == .Exception) {
            const g = receiver.Exception.fqn.borrow();
            defer g.deinit();
            return .{ .ok = try syntheticClassFromFqn(allocator, g.get().bytes) };
        }
        // `value::class` — the runtime KClass of a plain value or callable.
        return .{ .ok = try syntheticClassFromFqn(allocator, receiver.typeFqn()) };
    }
    // `recv::method` produces a callable wrapper backed by a synthetic
    // Instance carrying `__bound_receiver__` + `__bound_name__`; the
    // call_value path dispatches through them.
    const identity = blk: {
        const g = self.instance_id_counter.borrowMut();
        defer g.deinit();
        break :blk g.get().fetchAdd(1, .monotonic) + 1;
    };
    const cls_name = try std.fmt.allocPrint(allocator, "$bound_ref${s}", .{name});
    const env = try ObjRef(runtime.Env).init(allocator, runtime.Env.init(allocator));
    // A bound reference IS a function value: `s::produce` satisfies
    // `() -> Int`, answers `is Function0<*>`, and takes every extension
    // declared on a function type (`(() -> T).asFlow()`). Name the
    // function supertypes so the dispatch walk and `is` see them; without
    // them a member call on the reference found no candidate and fell back
    // to invoking the bound method itself.
    const supers: []const []const u8 = blk: {
        const arity = boundRefArity(self, receiver, name, func) orelse
            break :blk try allocator.dupe([]const u8, &.{"kotlin.Function"});
        const fn_name = try std.fmt.allocPrint(allocator, "Function{d}", .{arity});
        break :blk try allocator.dupe([]const u8, &.{ fn_name, "kotlin.Function" });
    };
    const synth_class = try ObjRef(ClassDef).init(allocator, .{
        .name = cls_name,
        .fqn = cls_name,
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = false,
        .is_sealed = false,
        .supertype_names = supers,
        .parent = null,
        .interfaces = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = true,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .nested_classes = &.{},
        .captured_env = env,
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    });
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(allocator, .{ .name = "__bound_receiver__", .value = receiver.* });
    const name_dup = try allocator.dupe(u8, name);
    try fields.append(allocator, .{ .name = "__bound_name__", .value = .{ .String = try runtime.strInitOwned(allocator, name_dup) } });
    if (func) |fid| {
        try fields.append(allocator, .{ .name = "__bound_func__", .value = .{ .Int = @intCast(fid.int()) } });
    }
    // The reference's creation-site file: visibility of a file-private
    // target is decided where the reference is written, so the invoke
    // path re-installs this file while it dispatches by name.
    if (ir.eval.currentCallSiteSpan()) |sp| {
        try fields.append(allocator, .{ .name = "__bound_file__", .value = .{ .Int = @intCast(sp.file.int()) } });
    }
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = synth_class,
        .fields = fields,
        .outer = null,
        .identity = identity,
        .native_state = null,
    });
    return .{ .ok = .{ .Instance = inst } };
}

/// First supertype name registered for `class_name` in the runtime class
/// table (the head of the inheritance chain), if any. Caller owns nothing.
pub fn firstSupertypeName(self: *VmHost, allocator: Allocator, class_name: []const u8) ?[]const u8 {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return null;
    const dg = d.borrow();
    defer dg.deinit();
    const sups = dg.get().supertype_names;
    if (sups.len == 0) return null;
    // Class-table-owned (program-lifetime); returned borrowed per the contract.
    _ = allocator;
    return sups[0];
}

/// Whether the RECEIVER's own accessor-backed property `name` could hold a callable.
///
/// `getter_prop_names` is keyed by NAME alone, so ANY class with a getter-backed
/// property of that name arms the probe for EVERY receiver. That is how
/// `TextRange.min` -- `val min: Int get() = min(start, end)`, where the call is the
/// imported `kotlin.math.min` -- ended up reading itself: the member method missed,
/// the probe read the property, and the property's getter called `min` again,
/// forever.
///
/// The receiver's own getter decides. A declared function type can hold a callable;
/// a scalar or a registered concrete class cannot. A type parameter or a typealias
/// (`typealias Handler = () -> Unit`) names no registered class, so it stays
/// permissive -- either can be a function at runtime.
pub fn receiverPropCanHoldCallable(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    if (receiver.* != .Instance) return true;
    var cur: ?[]const u8 = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    var step: usize = 0;
    while (cur) |cn| {
        if (step > 64) return true;
        step += 1;
        const fid: ?FuncId = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().instance_prop_getters.get(.{ .a = cn, .b = name });
        };
        if (fid) |f| {
            const mg = self.module.borrow();
            defer mg.deinit();
            const func = mg.get().funcById(f) orelse return true;
            const rt = func.return_ty;
            // An unrecorded getter return lowers as Unit — no knowledge, so
            // no refutation (a real property getter is never Unit-typed).
            if (std.mem.eql(u8, rt.name, "kotlin.Unit") or std.mem.eql(u8, rt.name, "Unit") or rt.name.len == 0) return true;
            if (isFunctionTypeRefResolved(self, &rt)) return true;
            // A TYPE-PARAMETER return (`State<T>.value: T`) says nothing —
            // and its short name can collide with a registered class
            // (a test's `class T`), which wrongly refuted the probe.
            if (rt.name.len <= 2 and blk: {
                for (rt.name) |ch| {
                    if (!std.ascii.isUpper(ch)) break :blk false;
                }
                break :blk rt.name.len != 0;
            }) return true;
            if (isScalarKindName(rt.name)) return false;
            const known = blk: {
                const g = self.classes.borrow();
                defer g.deinit();
                break :blk g.get().get(rt.name) != null;
            };
            if (known and !classIsFunInterface(self, rt.name)) return false;
            return true;
        }
        cur = firstSupertypeName(self, self.allocator, cn);
    }
    return true;
}

/// Whether `class_name` names a registered `fun interface` (one abstract method,
/// so a lambda SAM-converts to it).
pub fn classIsFunInterface(self: *VmHost, class_name: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    return dg.get().is_fun_interface;
}

/// Whether `class_name` names a registered interface.
pub fn classIsInterface(self: *VmHost, class_name: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    return dg.get().is_interface;
}

/// `class_name`'s supertypes with the superclass ahead of the interfaces.
///
/// A supertype list keeps source order, and Kotlin does not require the
/// superclass to come first: `class FocusRequesterNode : FocusRequesterModifierNode,
/// Modifier.Node()` names the interface first. `super.onAttach()` there means
/// `Modifier.Node`'s, so a search that follows the list as written walks into the
/// interface and never reaches the class that actually declares the method.
/// Names are class-table-owned (program-lifetime); the returned slice is the
/// caller's.
pub fn supertypesClassFirst(self: *VmHost, allocator: Allocator, class_name: []const u8) Allocator.Error![]const []const u8 {
    const sups: []const []const u8 = blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        const d = g.get().get(class_name) orelse break :blk &.{};
        const dg = d.borrow();
        defer dg.deinit();
        break :blk dg.get().supertype_names;
    };
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (sups) |s| {
        if (!classIsInterface(self, s)) try out.append(allocator, s);
    }
    for (sups) |s| {
        if (classIsInterface(self, s)) try out.append(allocator, s);
    }
    return out.toOwnedSlice(allocator);
}

/// Whether the class table holds an entry named `class_name`.
pub fn classIsRegistered(self: *VmHost, class_name: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    return g.get().get(class_name) != null;
}

/// The registered supertype of `class_name` whose dotted name ends in
/// `.simple`, when the qualifier was written with the simple name only.
pub fn ownerSupertypeBySuffix(self: *VmHost, class_name: []const u8, simple: []const u8) ?[]const u8 {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return null;
    const dg = d.borrow();
    defer dg.deinit();
    for (dg.get().supertype_names) |s| {
        if (s.len > simple.len + 1 and std.mem.endsWith(u8, s, simple) and s[s.len - simple.len - 1] == '.') return s;
    }
    return null;
}

/// Whether `q` is one of `class_name`'s registered supertypes.
pub fn ownerHasSupertype(self: *VmHost, class_name: []const u8, q: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    for (dg.get().supertype_names) |s| {
        if (std.mem.eql(u8, s, q)) return true;
    }
    return false;
}

/// `[PATH]` record for a super-qualified dispatch, labelled with the
/// resolved static target class (`super(Base)`) rather than the runtime
/// receiver — super dispatch is static, so keying on the runtime class
/// would collide with the virtual call's key while legitimately selecting
/// a different declaration.
pub fn emitSuperPath(allocator: Allocator, decl_fqn: []const u8, fid: FuncId, target_class: []const u8, args: []const Value) void {
    if (!trace.pathEnabled()) return;
    const label = std.fmt.allocPrint(allocator, "super({s})", .{target_class}) catch return;
    defer allocator.free(label);
    vmhost.emitPathLabeled(allocator, "member_super", decl_fqn, fid, label, args);
}

pub fn callSuper(self: *VmHost, allocator: Allocator, receiver: *const Value, owner_class: []const u8, qualifier: ?[]const u8, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    _ = arg_names;
    // `super.method()` walks the supertypes of owner_class (the class the
    // call is written in, or the labeled `super@Outer`); `super<Q>` starts
    // the walk at Q itself.
    var pending: std.ArrayList([]const u8) = .empty;
    defer pending.deinit(allocator);
    if (qualifier) |q| {
        // `q` is the const-pool super qualifier (program-lifetime); borrow it.
        // A simple qualifier naming a nested supertype registered under its
        // dotted name (`super<Base>` for `Outer.Base`) resolves through the
        // owner's supertype list.
        if (ownerHasSupertype(self, owner_class, q) or classIsRegistered(self, q)) {
            try pending.append(allocator, q);
        } else if (ownerSupertypeBySuffix(self, owner_class, q)) |full| {
            try pending.append(allocator, full);
        } else {
            try pending.append(allocator, q);
        }
    } else {
        const sups = try supertypesClassFirst(self, allocator, owner_class);
        defer allocator.free(sups);
        try pending.appendSlice(allocator, sups);
    }
    // A class with no declared supertype still has `Any` above it:
    // `super.hashCode()` / `super.toString()` / `super.equals(x)` in a
    // value class reach the identity implementations below.
    var visited: std.StringHashMap(void) = .init(allocator);
    defer visited.deinit();

    // Search the supertypes, superclass before interfaces at every level, and
    // dispatch the first one that declares the method. Falling through to
    // call_member would re-enter virtual dispatch on the original
    // receiver and recurse forever for overriding methods.
    var step: usize = 0;
    while (pending.items.len != 0) {
        if (step > 128) break;
        step += 1;
        const cname = pending.orderedRemove(0);
        if (visited.contains(cname)) continue;
        try visited.put(cname, {});
        // First, an IR class method named `name` on this class.
        {
            const mg = self.module.borrow();
            const m = mg.get();
            var found_fid: ?FuncId = null;
            for (m.classes.items) |*cls_ir| {
                if (!std.mem.eql(u8, cls_ir.name, cname)) continue;
                // Collect every same-named method, then pick the overload that
                // matches the call's arity/types. Resolving by name alone binds
                // `super.listIterator(index)` to a no-arg `listIterator()` whose
                // body re-dispatches `listIterator(0)` virtually — an infinite
                // super/override cycle (AbstractMutableList$SubList).
                var cands: std.ArrayList(Func) = .empty;
                defer cands.deinit(allocator);
                for (cls_ir.methods) |fid| {
                    const cf = m.funcById(fid) orelse continue;
                    if (std.mem.eql(u8, cf.name, name)) cands.append(allocator, cf.*) catch {};
                }
                if (cands.items.len != 0) {
                    const chosen = pickMethodOverload(self, m, cands.items, args) orelse cands.items[0];
                    found_fid = chosen.id;
                }
                break;
            }
            if (found_fid) |fid| {
                const func = m.funcById(fid).?;
                mg.deinit();
                var all: std.ArrayList(Value) = .empty;
                try all.append(allocator, receiver.*);
                try all.appendSlice(allocator, args);
                const module_ref = self.module.clone();
                defer module_ref.deinit();
                emitSuperPath(allocator, func.fqn, fid, cname, args);
                return ir.eval.evalWith(VmHost, allocator, module_ref.borrow().get(), func, all, self);
            }
            mg.deinit();
        }
        // `super.<prop>` (a property read, lowered as a 0-arg CallSuper):
        // no method named `name` on this class — look for its property
        // getter. Walking from the parent skips the overriding subclass's
        // getter, so `override val x get() = super.x` reads the base.
        if (args.len == 0) {
            const getter_fid: ?FuncId = blk: {
                const pg = self.prog.borrow();
                defer pg.deinit();
                break :blk pg.get().instance_prop_getters.get(.{ .a = cname, .b = name });
            };
            if (getter_fid) |fid| {
                const mg = self.module.borrow();
                const m = mg.get();
                if (m.funcById(fid)) |func| {
                    mg.deinit();
                    var all: std.ArrayList(Value) = .empty;
                    try all.append(allocator, receiver.*);
                    const module_ref = self.module.clone();
                    defer module_ref.deinit();
                    emitSuperPath(allocator, func.fqn, fid, cname, args);
                    return ir.eval.evalWith(VmHost, allocator, module_ref.borrow().get(), func, all, self);
                }
                mg.deinit();
            }
        }
        // A builtin collection supertype has no IR class: the instance holds
        // the host collection as its delegate for that supertype, and
        // `super<ArrayList>.add(el)` dispatches on it.
        if (receiver.* == .Instance) {
            var kb: [96]u8 = undefined;
            if (std.fmt.bufPrint(&kb, "__delegate__{s}", .{simpleName(cname)}) catch null) |key| {
                const delegate: ?Value = blk: {
                    const ig = receiver.Instance.borrow();
                    defer ig.deinit();
                    break :blk ig.get().get(key);
                };
                if (delegate) |d| return callMemberRec(self, allocator, &d, name, args);
            }
        }
        // Not here: continue through this class's own supertypes.
        const sups = try supertypesClassFirst(self, allocator, cname);
        defer allocator.free(sups);
        try pending.appendSlice(allocator, sups);
    }

    // `super.<prop>` where the base property has no custom getter (a stored
    // val/var): read the backing field off the receiver instance directly.
    if (args.len == 0 and receiver.* == .Instance) {
        const ig = receiver.Instance.borrow();
        defer ig.deinit();
        if (ig.get().get(name)) |v| return .{ .ok = v };
    }

    // The chain bottomed out at a builtin (`Any` / `Throwable`), which
    // declares no IR method. Supply the inherited `Any`/`Throwable`
    // semantics so `override fun toString() = "${super.toString()} …"`
    // works through the exception hierarchy.
    if (receiver.* == .Instance) {
        const inst = receiver.Instance;
        if (std.mem.eql(u8, name, "toString") and args.len == 0) {
            return .{ .ok = try inheritedInstanceToString(allocator, inst, instanceIsThrowable(self, allocator, inst)) };
        }
        if (std.mem.eql(u8, name, "hashCode") and args.len == 0) {
            const ig = inst.borrow();
            defer ig.deinit();
            const hash: i64 = @bitCast(ig.get().identity);
            return .{ .ok = Value.newInt(hash) };
        }
        if (std.mem.eql(u8, name, "equals") and args.len == 1) {
            const same = switch (args[0]) {
                .Instance => |o| ObjRef(InstanceData).ptrEq(inst, o),
                else => false,
            };
            return .{ .ok = .{ .Bool = same } };
        }
    }
    // `super.Inner(args)`: an inner class of a supertype constructs
    // through `this` as its outer instance.
    if (receiver.* == .Instance) {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        var cur: ?ir.ClassId = mod.classId(owner_class) orelse mod.classIdByFqn(owner_class);
        var depth: usize = 0;
        while (cur) |cid| : (depth += 1) {
            if (depth > 32 or cid.int() >= mod.classes.items.len) break;
            const c = &mod.classes.items[cid.int()];
            if (mod.classIdNestedIn(cid, name)) |nested| {
                if (nested.int() < mod.classes.items.len and mod.classes.items[nested.int()].is_inner) {
                    return try newInstanceById(self, allocator, nested, args, receiver);
                }
            }
            cur = if (c.supertypes.len != 0) c.supertypes[0] else null;
        }
    }
    return .{ .err = try typeErr(allocator, "super.{s}: no matching method up the supertype chain from `{s}`", .{ name, owner_class }) };
}

pub var qt_trace_init: bool = false;
pub var qt_trace_val: ?[]const u8 = null;
pub fn qtTraceWant() ?[]const u8 {
    if (!qt_trace_init) {
        qt_trace_val = if (std.c.getenv("KLIO_QT_TRACE")) |w| std.mem.span(w) else null;
        qt_trace_init = true;
    }
    return qt_trace_val;
}

pub fn qualifiedThis(self: *VmHost, allocator: Allocator, receiver: *const Value, qualifier: []const u8) Allocator.Error!EvalResult {
    const qt_trace = if (qtTraceWant()) |w0| std.mem.indexOf(u8, qualifier, w0) != null else false;
    if (std.mem.indexOfScalar(u8, qualifier, '.') != null) {
        var walk: ?Value = receiver.*;
        var steps: usize = 0;
        while (walk) |value| {
            if (steps > 128 or value != .Instance) break;
            steps += 1;
            if (qt_trace) std.debug.print("[qt] cand={s} qual={s}\n", .{ debugClassNameOf(self, &value), qualifier });
            if (receiverImplementsOwnerIdentity(self, &value, qualifier)) {
                if (qt_trace) std.debug.print("[qt]   -> matched receiver walk\n", .{});
                return .{ .ok = value };
            }
            walk = instanceOuterLink(&value);
        }
        const exact_chain = try enclosingThisChain(self, allocator);
        defer allocator.free(exact_chain);
        for (exact_chain) |enclosing| {
            walk = enclosing;
            steps = 0;
            while (walk) |value| {
                if (steps > 128 or value != .Instance) break;
                steps += 1;
                if (qt_trace) std.debug.print("[qt] encl-cand={s}\n", .{debugClassNameOf(self, &value)});
                if (receiverImplementsOwnerIdentity(self, &value, qualifier)) {
                    if (qt_trace) std.debug.print("[qt]   -> matched enclosing chain\n", .{});
                    return .{ .ok = value };
                }
                walk = instanceOuterLink(&value);
            }
        }
        if (qt_trace) std.debug.print("[qt] NO MATCH for {s}\n", .{qualifier});
        return .{ .err = try typeErr(
            allocator,
            "qualified this `{s}` is not in the implicit receiver scope",
            .{qualifier},
        ) };
    }
    // Walk parent chain on the receiver's class for direct matches, then
    // traverse the `outer` chain for inner-class / local-class scenarios.
    // `this@Outer` from an Inner method walks to the captured outer.
    if (receiver.* == .Instance) {
        var cur: ?ObjRef(ClassDef) = blk: {
            const ig = receiver.Instance.borrow();
            defer ig.deinit();
            break :blk ig.get().class.clone();
        };
        var step: usize = 0;
        while (cur) |c| {
            if (step > 128) {
                c.deinit();
                break;
            }
            step += 1;
            const cg = c.borrow();
            const matched = std.mem.eql(u8, cg.get().name, qualifier) or std.mem.eql(u8, cg.get().fqn, qualifier);
            const next = blk: {
                break :blk if (cg.get().parent) |p| p.clone() else null;
            };
            cg.deinit();
            c.deinit();
            if (matched) return .{ .ok = receiver.* };
            cur = next;
        }
        // Walk the `outer` chain (inner-class / local-class capture).
        var outer: ?Value = blk: {
            const ig = receiver.Instance.borrow();
            defer ig.deinit();
            break :blk ig.get().outer;
        };
        var ostep: usize = 0;
        while (outer) |ov| {
            if (ostep > 128) break;
            ostep += 1;
            if (ov != .Instance) break;
            const o_inst = ov.Instance;
            var ocur: ?ObjRef(ClassDef) = blk: {
                const ig = o_inst.borrow();
                defer ig.deinit();
                break :blk ig.get().class.clone();
            };
            var inner_step: usize = 0;
            while (ocur) |c| {
                if (inner_step > 128) {
                    c.deinit();
                    break;
                }
                inner_step += 1;
                const cg = c.borrow();
                const matched = std.mem.eql(u8, cg.get().name, qualifier) or std.mem.eql(u8, cg.get().fqn, qualifier);
                const next = blk: {
                    break :blk if (cg.get().parent) |p| p.clone() else null;
                };
                cg.deinit();
                c.deinit();
                if (matched) return .{ .ok = .{ .Instance = o_inst.clone() } };
                ocur = next;
            }
            outer = blk: {
                const ig = o_inst.borrow();
                defer ig.deinit();
                break :blk ig.get().outer;
            };
        }
    }
    // No class match — `this@<fn-label>` (extension/lambda label) resolves
    // to the immediate receiver if the qualifier isn't a known class.
    // First try matching the qualifier against the enclosing-`this` chain.
    const chain = try enclosingThisChain(self, allocator);
    defer allocator.free(chain);
    for (chain) |encl_v| {
        if (encl_v != .Instance) continue;
        // Each enclosing receiver is checked through its own OUTER links
        // too: `this@Outer` inside an inner-class context (a delegation
        // expression, a nested lambda) reaches the enclosing instance
        // through the inner instance's outer chain — the enclosing
        // receiver itself is the inner instance, not the target.
        var walk: ?Value = encl_v;
        var outer_step: usize = 0;
        while (walk) |wv| {
            if (outer_step > 128) break;
            outer_step += 1;
            if (wv != .Instance) break;
            const o_inst = wv.Instance;
            var ocur: ?ObjRef(ClassDef) = blk: {
                const ig = o_inst.borrow();
                defer ig.deinit();
                break :blk ig.get().class.clone();
            };
            var inner_step: usize = 0;
            while (ocur) |c| {
                if (inner_step > 128) {
                    c.deinit();
                    break;
                }
                inner_step += 1;
                const cg = c.borrow();
                const matched = std.mem.eql(u8, cg.get().name, qualifier) or std.mem.eql(u8, cg.get().fqn, qualifier);
                const next = blk: {
                    break :blk if (cg.get().parent) |p| p.clone() else null;
                };
                cg.deinit();
                c.deinit();
                if (matched) return .{ .ok = .{ .Instance = o_inst.clone() } };
                ocur = next;
            }
            walk = blk: {
                const ig = o_inst.borrow();
                defer ig.deinit();
                break :blk ig.get().outer;
            };
        }
    }
    // `this@MeasureScope` where the label names an INTERFACE a candidate
    // implements (an interface default method's labeled receiver, captured
    // by a nested anon): the parent-class name chains above never list
    // interfaces. A SECOND pass keeps the supertype-graph walk off the
    // name-match fast path (`this@DeepRecursiveScopeImpl` resolves by name
    // every `callRecursive`).
    for (chain) |encl_v| {
        if (encl_v != .Instance) continue;
        var walk: ?Value = encl_v;
        var outer_step: usize = 0;
        while (walk) |wv| {
            if (outer_step > 128) break;
            outer_step += 1;
            if (wv != .Instance) break;
            if (receiverImplementsType(self, &wv, qualifier)) {
                return .{ .ok = .{ .Instance = wv.Instance.clone() } };
            }
            walk = blk: {
                const ig = wv.Instance.borrow();
                defer ig.deinit();
                break :blk ig.get().outer;
            };
        }
    }
    const known_class = blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        break :blk g.get().contains(qualifier);
    };
    if (!known_class and receiver.* != .Null) {
        // `this@<fn-label>` — the qualifier is an extension/fn label.
        // When the receiver isn't a real bound Instance, prefer the
        // enclosing receiver if it differs from the lambda's own `this`.
        const receiver_is_bound_instance = receiver.* == .Instance;
        if (!receiver_is_bound_instance and chain.len > 0) {
            const encl = chain[0];
            const same = switch (encl) {
                .Instance => |a| switch (receiver.*) {
                    .Instance => |b| ObjRef(InstanceData).ptrEq(a, b),
                    else => false,
                },
                else => false,
            };
            if (!same and encl != .Null and encl != .Unit) {
                return .{ .ok = encl };
            }
        }
        return .{ .ok = receiver.* };
    }
    if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
        std.debug.print("[labeled-this] qualifier={s} recv={s} chain_len={d}\n", .{ qualifier, @tagName(std.meta.activeTag(receiver.*)), chain.len });
        for (chain, 0..) |cv, i| {
            const cname: []const u8 = if (cv == .Instance) blk: {
                const g = cv.Instance.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                break :blk cg.get().name;
            } else @tagName(std.meta.activeTag(cv));
            std.debug.print("[labeled-this]   chain[{d}]={s}\n", .{ i, cname });
        }
        ir.eval.dumpFrameChainForDiagAlways();
    }
    return .{ .err = try typeErr(allocator, "`this@{s}` is not bound in this scope", .{qualifier}) };
}

/// The serializer a `@Serializer(forClass = C::class)` declaration stands for.
/// The kotlinx plugin generates that declaration's whole body from `C`; klio
/// answers the members it never wrote by forwarding to `C`'s own serializer.
/// Null unless the receiver's class carries the annotation with a resolvable
/// class argument that is not the receiver itself.
pub fn serializerForClassTarget(self: *VmHost, allocator: Allocator, receiver: *const Value) Allocator.Error!?Value {
    const cls: ObjRef(ClassDef) = switch (receiver.*) {
        .Class => |c| c.clone(),
        .Instance => |inst| blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().class.clone();
        },
        else => return null,
    };
    defer cls.deinit();
    const for_class: []const u8 = blk: {
        const g = cls.borrow();
        defer g.deinit();
        for (g.get().annotation_records) |rec| {
            if (!rec.is("Serializer") and !rec.is("kotlinx.serialization.Serializer")) continue;
            for (rec.args) |arg| {
                if (arg == .ClassRef) break :blk arg.ClassRef;
            }
        }
        return null;
    };
    const target = host_globals.lookupGlobal(self, for_class) orelse return null;
    if (target != .Class) return null;
    // `@Serializer(forClass = Self::class)` would forward to itself.
    {
        const tg = target.Class.borrow();
        defer tg.deinit();
        const cg = cls.borrow();
        defer cg.deinit();
        if (std.mem.eql(u8, tg.get().fqn, cg.get().fqn)) return null;
    }
    const fid = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().funcIdByFqn("kotlinx.serialization.__klsx_reflectiveSerializer") orelse return null;
    };
    const call_args = [_]Value{target};
    const r = try callFuncRec(self, allocator, self.module.asPtr(), fid, &call_args);
    switch (r) {
        .ok => |v| {
            if (v == .Null) return null;
            return v;
        },
        .err => |e| {
            freeDispatchMiss(allocator, .{ .err = e });
            return null;
        },
    }
}

/// The class a companion object belongs to, as a `Value.Class`. Null when the
/// argument is not a registered companion.
pub fn companionOwnerClassValue(self: *VmHost, kc: *const Value) Allocator.Error!?Value {
    if (kc.* != .Class) return null;
    const comp_name = blk: {
        const g = kc.Class.borrow();
        defer g.deinit();
        break :blk g.get().name;
    };
    const owner: ?[]const u8 = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const reg = &mg.get().registry;
        // The instance's class may carry the `$Companion` suffix once more
        // than the registered singleton name does; peel it until a
        // registered owner appears.
        var probe = comp_name;
        var hops: usize = 0;
        while (hops < 3) : (hops += 1) {
            var it = reg.companion_singletons.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.value_ptr.*, probe)) break :blk e.key_ptr.*;
            }
            if (reg.enclosing_class.get(probe)) |o| break :blk o;
            if (hops != 0 and mg.get().classId(probe) != null) break :blk probe;
            if (std.mem.endsWith(u8, probe, "$Companion")) {
                probe = probe[0 .. probe.len - "$Companion".len];
            } else if (std.mem.endsWith(u8, probe, ".Companion")) {
                probe = probe[0 .. probe.len - ".Companion".len];
            } else break;
        }
        break :blk null;
    };
    const name = owner orelse return null;
    // The class table is the authority for the owner's class value: a
    // by-name global may be a same-named property of another package
    // (`kotlin.math.E` beside a user `enum class E`).
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(name)) |def| return Value{ .Class = def.clone() };
    }
    const v = host_globals.lookupGlobal(self, name) orelse return null;
    if (v != .Class) return null;
    return v;
}
