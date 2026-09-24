//! Member references, `super.foo(...)`, `this@Outer`, and `@Serializer` targets.

const std = @import("std");
const host_classes = @import("../host_classes.zig");
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

/// A minimal `KClass` value carrying only the simple and qualified names, enough
/// for `simpleName`, `qualifiedName` and FQN-keyed equality.
pub fn syntheticClassFromFqn(allocator: Allocator, fqn: []const u8) Allocator.Error!Value {
    const dot = std.mem.findScalarLast(u8, fqn, '.');
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

/// An unsigned primitive-array type name, whose bare form lowers to a constructor.
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

/// Value-parameter count of the member a bound reference names, so it can report
/// the `FunctionN` it satisfies. Null when the target is unidentifiable.
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
    if (std.mem.eql(u8, name, "class")) {
        if (receiver.* == .Instance) {
            const cls: ObjRef(ClassDef) = blk: {
                const ig = receiver.Instance.borrow();
                defer ig.deinit();
                break :blk ig.get().class.clone();
            };
            // `A::class` on a class with a companion arrives with the companion
            // instance, but the class literal is the owner, not the companion.
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
        if (receiver.* == .Class) return .{ .ok = receiver.* };
        if (receiver.* == .Intrinsic) {
            const dot = std.mem.findScalarLast(u8, receiver.Intrinsic.fqn, '.');
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
        return .{ .ok = try syntheticClassFromFqn(allocator, receiver.typeFqn()) };
    }
    // `recv::method` wraps a synthetic Instance holding `__bound_receiver__` and
    // `__bound_name__`, which `callValue` dispatches on.
    const identity = blk: {
        const g = self.instance_id_counter.borrowMut();
        defer g.deinit();
        break :blk g.get().fetchAdd(1, .monotonic) + 1;
    };
    const cls_name = try std.fmt.allocPrint(allocator, "$bound_ref${s}", .{name});
    const env = try ObjRef(runtime.Env).init(allocator, runtime.Env.init(allocator));
    // A bound reference is a function value, so name the function supertypes.
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
    // Visibility of a file-private target is decided where the reference is
    // written, so the invoke path re-installs this file while dispatching.
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

/// First supertype name registered for `class_name`; the caller owns nothing.
pub fn firstSupertypeName(self: *VmHost, allocator: Allocator, class_name: []const u8) ?[]const u8 {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return null;
    const dg = d.borrow();
    defer dg.deinit();
    const sups = dg.get().supertype_names;
    if (sups.len == 0) return null;
    _ = allocator;
    return sups[0];
}

/// Whether the receiver's own accessor-backed property `name` could hold a
/// callable. Its own getter decides: a declared function type can, a scalar or
/// registered class cannot, a type parameter or typealias stays permissive.
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
            // An unrecorded getter return lowers as Unit, so it refutes nothing.
            if (std.mem.eql(u8, rt.name, "kotlin.Unit") or std.mem.eql(u8, rt.name, "Unit") or rt.name.len == 0) return true;
            if (isFunctionTypeRefResolved(self, &rt)) return true;
            // A type-parameter return says nothing, and can collide with a class.
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

pub fn classIsFunInterface(self: *VmHost, class_name: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    return dg.get().is_fun_interface;
}

pub fn classIsInterface(self: *VmHost, class_name: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    return dg.get().is_interface;
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
    const qt_trace = if (qtTraceWant()) |w0| std.mem.find(u8, qualifier, w0) != null else false;
    if (std.mem.findScalar(u8, qualifier, '.') != null) {
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
    // Match the class parent chain first, then the captured `outer` chain.
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
    // No class match: try the enclosing-`this` chain before the receiver.
    const chain = try enclosingThisChain(self, allocator);
    defer allocator.free(chain);
    for (chain) |encl_v| {
        if (encl_v != .Instance) continue;
        // Each enclosing receiver is walked through its own outer links too.
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
    // A label can name an interface, which the parent chains above never list.
    // A second pass keeps the supertype walk off the name-match fast path.
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
        // With no bound Instance receiver, prefer a differing enclosing receiver.
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

/// The serializer a `@Serializer(forClass = C::class)` declaration stands for:
/// its unwritten members forward to `C`'s own. Null when `C` is the receiver.
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

/// The class a companion object belongs to; null when it is not a companion.
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
        // The class may carry `$Companion` once more than the registered name.
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
    // The class table is the authority over a same-named by-name global.
    {
        if (host_classes.classDefLookup(self, name)) |def| return Value{ .Class = def.clone() };
    }
    const v = host_globals.lookupGlobal(self, name) orelse return null;
    if (v != .Class) return null;
    return v;
}
