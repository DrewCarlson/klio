//! The stdlib/builtin member tail: convention calls, bridges, `KType` synthetics,
//! the `Any` fallback, and the throwable members.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const host_call_func = @import("../host_call_func.zig");
const host_fields = @import("../host_fields.zig");
const builtin_members = @import("../builtin_members.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const StdlibFn = runtime.StdlibFn;
const Func = ir.Func;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;
const dataValueInstanceEquals = builtin_members.dataValueInstanceEquals;
const annotationInstanceEquals = builtin_members.annotationInstanceEquals;
const kotlinHashCode = builtin_members.kotlinHashCode;

const applicability_probe = @import("applicability_probe.zig");
const argDefinitelyNotParamType = applicability_probe.argDefinitelyNotParamType;

const caches = @import("caches.zig");
const METHOD_MISS = caches.METHOD_MISS;
const instanceMethodCacheGetRaw = caches.instanceMethodCacheGetRaw;
const instanceMethodCachePutRaw = caches.instanceMethodCachePutRaw;
const tlResolveMatch = caches.tlResolveMatch;
const tlResolveSlot = caches.tlResolveSlot;
const tlResolveStore = caches.tlResolveStore;

const flat_call = @import("flat_call.zig");
const dispatchWithReceiver = flat_call.dispatchWithReceiver;

const hcm = @import("../host_call_member.zig");
const boolVal = hcm.boolVal;
const classDisplayName = hcm.classDisplayName;
const dispatchIntrinsic = hcm.dispatchIntrinsic;
const lookupIntrinsic = hcm.lookupIntrinsic;
const simpleName = hcm.simpleName;
const strVal = hcm.strVal;

const member_ext_visibility = @import("member_ext_visibility.zig");
const importedPackExtShadows = member_ext_visibility.importedPackExtShadows;
const isMemberExt = member_ext_visibility.isMemberExt;
const memberDeclArityMisfit = member_ext_visibility.memberDeclArityMisfit;
const userMemberExtShadows = member_ext_visibility.userMemberExtShadows;
const userToplevelExtNamedExists = member_ext_visibility.userToplevelExtNamedExists;
const userToplevelExtShadows = member_ext_visibility.userToplevelExtShadows;

const member_presence = @import("member_presence.zig");
const hostHasMember = member_presence.hostHasMember;
const memberNameIdentity = member_presence.memberNameIdentity;

const receiver_probe = @import("receiver_probe.zig");
const isCallable = receiver_probe.isCallable;
const receiverImplementsType = receiver_probe.receiverImplementsType;
const strictReceiverProven = receiver_probe.strictReceiverProven;

const reflect_anon = @import("reflect_anon.zig");
const funcAt = reflect_anon.funcAt;
const lookupAnonMethod = reflect_anon.lookupAnonMethod;
const root_mod = reflect_anon.root_mod;

const resolve_method = @import("resolve_method.zig");
const resolveInstanceMethod = resolve_method.resolveInstanceMethod;

const virtual_tail = @import("virtual_tail.zig");
const instanceMethodKeyRelaxed = virtual_tail.instanceMethodKeyRelaxed;
const instanceMethodKeyScoped = virtual_tail.instanceMethodKeyScoped;
const invokeMethodFuncId = virtual_tail.invokeMethodFuncId;

/// Whether a lambda argument makes the resolved MEMBER inapplicable while a
/// same-arity extension declares that slot as a function type. Kotlin ranks
/// members over extensions only among APPLICABLE candidates, so
/// `DateTimeFormat<DateTimeComponents>.format { … }` is the extension taking
/// a `DateTimeComponents.() -> Unit`, never the member `format(value: T)`.
/// Restricted to a member slot declared as a bare TYPE VARIABLE: a nominal
/// parameter can still take the lambda by SAM conversion, and there the
/// member keeps its precedence.
pub fn lambdaArgPrefersExtension(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    fid: FuncId,
    name: []const u8,
    args: []const Value,
) Allocator.Error!bool {
    if (args.len == 0 or !isCallable(&args[args.len - 1])) return false;
    var member_slot_is_tp = false;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const f = funcAt(mg.get(), fid) orelse return false;
        if (f.params.len != args.len + 1) return false;
        const raw = std.mem.trimEnd(u8, f.params[f.params.len - 1].ty.name, "?");
        const head = std.mem.trimEnd(u8, simpleName(raw), "?");
        member_slot_is_tp = (head.len != 0 and head.len <= 2 and std.ascii.isUpper(head[0])) or
            ir.parseClassTypeParamIdentity(raw) != null;
    }
    if (!member_slot_is_tp) return false;
    var cands: std.ArrayList(FuncId) = .empty;
    defer cands.deinit(allocator);
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        for (mod.funcsBySimpleName(name)) |cand| {
            const g = funcAt(mod, cand) orelse continue;
            if (!g.hasBody() or g.params.len != args.len + 1) continue;
            if (!std.mem.eql(u8, g.params[0].name, "this")) continue;
            if (isMemberExt(mod, cand)) continue;
            if (!std.mem.startsWith(u8, g.params[g.params.len - 1].ty.name, "Function")) continue;
            cands.append(allocator, cand) catch {};
        }
    }
    for (cands.items) |cand| {
        const rty = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const g = funcAt(mg.get(), cand) orelse break :blk null;
            break :blk &g.params[0].ty;
        } orelse continue;
        if (try strictReceiverProven(self, allocator, receiver, cand, rty)) return true;
    }
    return false;
}

/// The indexing convention binds `a[i, j] = v` to `set(i, j, v)` with the
/// VALUE in the last parameter: parameters between the indices and the value
/// take their defaults, and a vararg index parameter absorbs every index.
pub fn conventionSetCall(self: *VmHost, allocator: Allocator, receiver: *const Value, args: []const Value) Allocator.Error!?EvalResult {
    if (receiver.* != .Instance or args.len < 2) return null;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const cls_fqn = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk if (cg.get().fqn.len != 0) cg.get().fqn else cg.get().name;
    };
    var cur: ?ir.ClassId = mod.classIdByFqn(cls_fqn) orelse mod.classId(cls_fqn);
    var depth: usize = 0;
    var hit: ?FuncId = null;
    while (cur) |cid| : (depth += 1) {
        if (depth > 32 or cid.int() >= mod.classes.items.len) break;
        const c = &mod.classes.items[cid.int()];
        const decls = mod.memberDecls(c.fqn, "set");
        if (decls.len != 0) {
            hit = decls[0];
            break;
        }
        cur = if (c.supertypes.len != 0) c.supertypes[0] else null;
    }
    const fid = hit orelse return null;
    const f = mod.funcById(fid) orelse return null;
    const skip: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const params = f.params[skip..];
    if (params.len < 2) return null;
    var vararg_at: ?usize = null;
    for (params, 0..) |*p, i| if (p.is_vararg) {
        vararg_at = i;
    };
    const value_param = params.len - 1;
    if (params[value_param].is_vararg) return null;
    const n_idx = args.len - 1;
    // Already positionally exact with no vararg to pack: nothing to adapt.
    if (vararg_at == null and n_idx == value_param) return null;
    var adapted: std.ArrayList(Value) = .empty;
    defer adapted.deinit(allocator);
    if (vararg_at) |vi| {
        if (vi >= value_param) return null;
        try adapted.appendSlice(allocator, args[0..vi]);
        var packed_args: std.ArrayList(Value) = .empty;
        try packed_args.appendSlice(allocator, args[vi..n_idx]);
        const items = try runtime.ValueList.init(allocator, packed_args);
        try adapted.append(allocator, runtime.ArrayData.fromBoxedList(items));
        var k: usize = vi + 1;
        while (k < value_param) : (k += 1) {
            if (!params[k].has_default) return null;
            try adapted.append(allocator, .Null);
        }
    } else {
        // Defaults between the indices and the value: bind the value by
        // NAME so the gap takes its declared defaults.
        if (n_idx > value_param) return null;
        var k: usize = n_idx;
        while (k < value_param) : (k += 1) {
            if (!params[k].has_default) return null;
        }
        var named_args: std.ArrayList(Value) = .empty;
        defer named_args.deinit(allocator);
        var names: std.ArrayList(?[]const u8) = .empty;
        defer names.deinit(allocator);
        if (skip == 1) {
            try named_args.append(allocator, receiver.*);
            try names.append(allocator, null);
        }
        try named_args.appendSlice(allocator, args[0..n_idx]);
        try names.appendNTimes(allocator, null, n_idx);
        try named_args.append(allocator, args[n_idx]);
        try names.append(allocator, params[value_param].name);
        return try host_call_func.callFuncNamed(self, allocator, mod, fid, named_args.items, names.items);
    }
    try adapted.append(allocator, args[n_idx]);
    return try invokeMethodFuncId(self, allocator, receiver, fid, adapted.items);
}

pub fn irMethodWalk(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8) Allocator.Error!?EvalResult {
    if (std.mem.eql(u8, name, "set")) {
        if (try conventionSetCall(self, allocator, receiver, args)) |r| return r;
    }
    if (runtime.envSetOnce("KLIO_WALK_TRACE")) {
        std.debug.print("[ir-walk] {s} on {s} static={s}\n", .{ name, receiver.typeFqn(), static_recv orelse "-" });
    }
    runtime.prof.opRoute(9);
    // Inline cache: memoize the (class, method-name, arg-type-signature) →
    // FuncId resolution. The signature captures the argument primitive types the
    // overload pick depends on, so a hit returns the same target the full walk
    // would (a non-primitive arg yields no key, so those calls re-resolve rather
    // than risk a wrong cross-type hit). Only an unambiguous resolution is
    // cached; a call that declines to an extension is never stored. The fast
    // path at `callMemberInnerStatic`'s entry consults this same cache before the
    // probe ladder, so a repeat call skips the binding/builtin probes too.
    //
    // A `static_recv`-directed call keys with the scope folded in (see
    // `instanceMethodKeyScoped`): its resolution depends on the static receiver
    // type, so it caches apart from the ordinary call's entry — never served
    // one, never serves one.
    const strict_key = instanceMethodKeyScoped(self, receiver, name, args, static_recv, null);
    // A container-typed argument makes the strict signature unbuildable;
    // the RELAXED key (kind tags — see `instanceMethodKeyRelaxed`) keys the
    // member resolution then, so those calls stop re-walking per call.
    const key = strict_key orelse instanceMethodKeyRelaxed(self, receiver, name, args, static_recv);
    if (key) |k| {
        if (instanceMethodCacheGetRaw(self, k)) |raw| {
            if (raw == METHOD_MISS) return null;
            const cached: FuncId = @enumFromInt(raw);
            // The lambda-argument decline is a property of the CALL, not of
            // the cached resolution, so it applies on the hit path too.
            if (try lambdaArgPrefersExtension(self, allocator, receiver, cached, name, args)) return null;
            return try invokeMethodFuncId(self, allocator, receiver, cached, args);
        }
    }
    const resolved0 = try resolveInstanceMethod(self, allocator, receiver, name, args, static_recv);
    if (resolved0) |r0| {
        if (try lambdaArgPrefersExtension(self, allocator, receiver, r0.fid, name, args)) return null;
    }
    const resolved = resolved0 orelse {
        // Cache the miss: a member-accessed field (`obj.field`) re-runs this
        // walk every read otherwise. Only a proven, key-stable miss is stored.
        if (key) |k| instanceMethodCachePutRaw(self, k, METHOD_MISS);
        return null;
    };
    // The STRICT key folds every discriminator the overload pick consults:
    // each argument's tag plus its class identity, closure body, or function
    // decl pointer, alongside the receiver class and name that fix the
    // candidate set. For a fixed strict key the pick is therefore a pure
    // function of the key, and storing it cannot serve an overload the walk
    // would not have chosen — so a resolution that had SEVERAL candidates is
    // still cacheable. Only the RELAXED key (container kind tags, no
    // identity) needs the single-candidate guarantee, since two overloads can
    // share its coarser signature.
    if (resolved.unambiguous or strict_key != null) {
        if (key) |k| instanceMethodCachePutRaw(self, k, @intFromEnum(resolved.fid));
    }
    if (runtime.envSetOnce("KLIO_WALK_TRACE")) {
        std.debug.print("[ir-walk-fill] {s} strict={} key={} unamb={} -> cached={}\n", .{ name, strict_key != null, key != null, resolved.unambiguous, key != null and (resolved.unambiguous or strict_key != null) });
    }
    return try invokeMethodFuncId(self, allocator, receiver, resolved.fid, args);
}

/// `builtinBridgeDefault` for a virtual-slot call: the receiver class's
/// own declaration of `name` (or the nearest ancestor's) is the override
/// whose parameter type the bridge checks.
pub fn bridgeForReceiver(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value) ?Value {
    if (args.len != 1 or receiver.* != .Instance) return null;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    var cur: ?ObjRef(ClassDef) = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    var depth: usize = 0;
    while (cur) |cd| : (depth += 1) {
        const cg = cd.borrow();
        const fqn = if (cg.get().fqn.len != 0) cg.get().fqn else cg.get().name;
        const decls = mod.memberDecls(fqn, name);
        if (decls.len != 0) {
            const f = mod.funcById(decls[0]);
            cg.deinit();
            cd.deinit();
            return if (f) |ff| builtinBridgeDefault(self, receiver, ff, args) else null;
        }
        const next: ?ObjRef(ClassDef) = if (cg.get().parent) |pp| pp.clone() else null;
        cg.deinit();
        cd.deinit();
        if (depth > 32) {
            if (next) |n| n.deinit();
            return null;
        }
        cur = next;
    }
    return null;
}

/// The JVM's type-checking bridges on a user collection or map: an
/// argument outside the override's declared parameter type never reaches
/// the override. `get`/`remove` on a map answer null, `contains`,
/// `containsKey`, `containsValue` and a collection's `remove` answer
/// false, `indexOf`/`lastIndexOf` answer -1.
pub fn builtinBridgeDefault(self: *VmHost, receiver: *const Value, f: *const Func, args: []const Value) ?Value {
    const name = f.name;
    if (args.len != 1 or receiver.* != .Instance) return null;
    const is_map_name = std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "containsKey") or
        std.mem.eql(u8, name, "containsValue") or std.mem.eql(u8, name, "remove");
    const is_coll_name = std.mem.eql(u8, name, "contains") or std.mem.eql(u8, name, "remove") or
        std.mem.eql(u8, name, "indexOf") or std.mem.eql(u8, name, "lastIndexOf");
    if (!is_map_name and !is_coll_name) return null;
    const on_map = receiverImplementsType(self, receiver, "Map") or receiverImplementsType(self, receiver, "MutableMap");
    const on_coll = !on_map and (receiverImplementsType(self, receiver, "Collection") or receiverImplementsType(self, receiver, "MutableCollection") or
        receiverImplementsType(self, receiver, "List") or receiverImplementsType(self, receiver, "MutableList") or
        receiverImplementsType(self, receiver, "Set") or receiverImplementsType(self, receiver, "MutableSet"));
    if (!(on_map and is_map_name) and !(on_coll and is_coll_name)) return null;
    const skip: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    if (f.params.len != skip + 1) return null;
    const pty = &f.params[skip].ty;
    // Only a CONCRETE narrower parameter type has a bridge: a type
    // parameter of the class or the method (`contains(element: T)`,
    // `ConcurrentSet<Key : Any>.contains(element: Key)`) takes every
    // argument; `Any` excludes only null.
    var head = std.mem.trimEnd(u8, pty.name, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (head.len == 0 or head[0] == '#' or ir.parseClassTypeParamIdentity(head) != null) return null;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (mod.registry.func_type_params.get(f.id)) |tps| {
            for (tps.items) |tp| if (std.mem.eql(u8, tp, head)) return null;
        }
        const cls_fqn = blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk if (cg.get().fqn.len != 0) cg.get().fqn else cg.get().name;
        };
        var cur: ?ir.ClassId = mod.classIdByFqn(cls_fqn) orelse mod.classId(cls_fqn);
        var depth: usize = 0;
        while (cur) |cid| : (depth += 1) {
            if (depth > 32 or cid.int() >= mod.classes.items.len) break;
            const c = &mod.classes.items[cid.int()];
            for (c.type_params) |tp| if (std.mem.eql(u8, tp, head)) return null;
            cur = if (c.supertypes.len != 0) c.supertypes[0] else null;
        }
    }
    const misfit = if (args[0] == .Null) !pty.nullable else argDefinitelyNotParamType(self, pty, &args[0]);
    if (!misfit) return null;
    if (on_map and (std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "remove"))) return .Null;
    if (std.mem.eql(u8, name, "indexOf") or std.mem.eql(u8, name, "lastIndexOf")) return Value.newInt(-1);
    return .{ .Bool = false };
}

/// A SAM-converted `Sequence { ... }` / `Iterable { ... }` instance: its
/// `iterator` is served through `__sam_target__` rather than an IR
/// method, so `hostHasMember(.., "iterator")` cannot see it. The
/// iterable fallback drains these like any other iterator-bearing
/// instance.
pub fn samIterableInstance(self: *VmHost, allocator: Allocator, receiver: *const Value) bool {
    const class_name = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        // A SAM conversion carries the lambda under `__sam_target__`; a
        // lowered fun-interface object carries `iterator` as a callable
        // field; a full anon `object : Sequence<T>` registers `iterator`
        // in the anon-method table. Any of them can be drained.
        if (g.get().get("__sam_target__") != null) break :blk null;
        if (g.get().get("iterator")) |f| {
            if (isCallable(&f)) break :blk null;
        }
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    const cn = class_name orelse return true;
    return lookupAnonMethod(self, allocator, cn, "iterator/0", "iterator") != null;
}

pub fn isKTypeSynth(v: *const Value) bool {
    if (v.* != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return std.mem.eql(u8, cg.get().name, "kotlin.reflect.KType") or std.mem.eql(u8, cg.get().fqn, "kotlin.reflect.KType");
}

pub fn ktypeField(v: *const Value, name: []const u8) Value {
    const g = v.Instance.borrow();
    defer g.deinit();
    return g.get().get(name) orelse Value.Null;
}

pub fn ktypeClassifierName(v: *const Value) []const u8 {
    const c = ktypeField(v, "classifier");
    switch (c) {
        .Class => |cd| {
            const g = cd.borrow();
            defer g.deinit();
            return if (g.get().fqn.len != 0) g.get().fqn else g.get().name;
        },
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            return g.get().bytes;
        },
        else => return "",
    }
}

pub fn ktypeEquals(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) Allocator.Error!bool {
    if (!isKTypeSynth(b)) return false;
    if (!std.mem.eql(u8, ktypeClassifierName(a), ktypeClassifierName(b))) return false;
    const na = ktypeField(a, "isMarkedNullable");
    const nb = ktypeField(b, "isMarkedNullable");
    if ((na == .Bool and na.Bool) != (nb == .Bool and nb.Bool)) return false;
    const aa = ktypeField(a, "arguments");
    const ab = ktypeField(b, "arguments");
    if (aa != .List or ab != .List) return aa == .Null and ab == .Null;
    const ga = aa.List.items.borrow();
    defer ga.deinit();
    const gb = ab.List.items.borrow();
    defer gb.deinit();
    if (ga.get().items.len != gb.get().items.len) return false;
    for (ga.get().items, gb.get().items) |*pa, *pb| {
        if (pa.* != .Instance or pb.* != .Instance) return false;
        const ta = ktypeField(pa, "type");
        const tb = ktypeField(pb, "type");
        if (ta == .Null and tb == .Null) continue;
        if (ta != .Instance or tb != .Instance) return false;
        if (!try ktypeEquals(self, allocator, &ta, &tb)) return false;
    }
    return true;
}

pub fn ktypeHash(self: *VmHost, allocator: Allocator, v: *const Value) Allocator.Error!i32 {
    var h: i32 = builtin_members.javaStringHash(ktypeClassifierName(v));
    const n = ktypeField(v, "isMarkedNullable");
    h = h *% 31 +% @as(i32, if (n == .Bool and n.Bool) 1 else 0);
    const args = ktypeField(v, "arguments");
    if (args == .List) {
        const g = args.List.items.borrow();
        defer g.deinit();
        for (g.get().items) |*pa| {
            if (pa.* != .Instance) continue;
            const t = ktypeField(pa, "type");
            h = h *% 31 +% (if (t == .Instance) try ktypeHash(self, allocator, &t) else 0);
        }
    }
    return h;
}

pub fn ktypeRender(self: *VmHost, allocator: Allocator, v: *const Value, buf: *std.ArrayList(u8)) Allocator.Error!void {
    try buf.appendSlice(allocator, ktypeClassifierName(v));
    const args = ktypeField(v, "arguments");
    if (args == .List) {
        const g = args.List.items.borrow();
        defer g.deinit();
        if (g.get().items.len != 0) {
            try buf.append(allocator, '<');
            for (g.get().items, 0..) |*pa, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                const t = if (pa.* == .Instance) ktypeField(pa, "type") else Value.Null;
                if (t == .Instance) try ktypeRender(self, allocator, &t, buf) else try buf.append(allocator, '*');
            }
            try buf.append(allocator, '>');
        }
    }
    const n = ktypeField(v, "isMarkedNullable");
    if (n == .Bool and n.Bool) try buf.append(allocator, '?');
}

pub fn anyInstanceFallback(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    // A `KType` (`typeOf<T>()`) compares structurally: same classifier,
    // same arguments, same nullability; it renders as its classifier's
    // name with `?` for a nullable type.
    if (isKTypeSynth(receiver)) {
        if (args.len == 1 and std.mem.eql(u8, name, "equals")) {
            return .{ .ok = boolVal(try ktypeEquals(self, allocator, receiver, &args[0])) };
        }
        if (args.len == 0 and std.mem.eql(u8, name, "hashCode")) {
            return .{ .ok = Value.newInt(@as(i64, try ktypeHash(self, allocator, receiver))) };
        }
        if (args.len == 0 and std.mem.eql(u8, name, "toString")) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try ktypeRender(self, allocator, receiver, &buf);
            return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, try buf.toOwnedSlice(allocator)) } };
        }
    }
    // A bound or qualified callable reference (`v::m`, `V::m`, `Foo::ext`)
    // compares by name, receiver and adaptation, and hashes the same way.
    if (host_fields.boundRefParts(receiver)) |mine| {
        if (args.len == 1 and std.mem.eql(u8, name, "equals")) {
            const other = host_fields.boundRefParts(&args[0]) orelse return .{ .ok = boolVal(false) };
            if (!std.mem.eql(u8, mine.name, other.name) or !std.mem.eql(u8, mine.adapt, other.adapt)) return .{ .ok = boolVal(false) };
            return .{ .ok = boolVal(try builtin_members.deepValueEquals(self, allocator, &mine.receiver, &other.receiver)) };
        }
        if (args.len == 0 and std.mem.eql(u8, name, "hashCode")) {
            var h: i32 = builtin_members.javaStringHash(mine.name);
            h = h *% 31 +% try builtin_members.hashWithDispatch(self, allocator, &mine.receiver);
            h = h *% 31 +% builtin_members.javaStringHash(mine.adapt);
            return .{ .ok = Value.newInt(@as(i64, h)) };
        }
    }
    const inst = receiver.Instance;
    if (args.len == 0 and std.mem.eql(u8, name, "toString")) {
        if (instanceIsThrowable(self, allocator, inst)) {
            return .{ .ok = try inheritedInstanceToString(allocator, inst, true) };
        }
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        defer {
            cg.deinit();
            g.deinit();
        }
        if (cg.get().is_enum) {
            if (g.get().get("name")) |nv| {
                if (nv == .String) {
                    // Borrowed instance field escaping through callMember.
                    nv.retain();
                    return .{ .ok = nv };
                }
            }
        }
        if (cg.get().is_object) {
            return .{ .ok = try strVal(allocator, cg.get().name) };
        }
        if (cg.get().is_data) {
            return .{ .ok = try renderStructuralLocked(allocator, g.get(), cg.get()) };
        }
        const s = try std.fmt.allocPrint(allocator, "{s}@{x}", .{ cg.get().fqn, g.get().identity });
        return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
    }
    if (args.len == 0 and std.mem.eql(u8, name, "hashCode")) {
        const g = inst.borrow();
        // A data/value class without a hashCode override hashes
        // structurally, not by identity — a value class implementing an
        // interface that redeclares hashCode still has value semantics.
        const structural = blk: {
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk cg.get().is_data or cg.get().is_value;
        };
        g.deinit();
        if (structural) {
            return .{ .ok = .{ .Int = kotlinHashCode(receiver) } };
        }
        const g2 = inst.borrow();
        defer g2.deinit();
        return .{ .ok = Value.newInt(@bitCast(g2.get().identity)) };
    }
    if (args.len == 1 and std.mem.eql(u8, name, "equals")) {
        // A user `Map.Entry` implementation with no `equals` override follows
        // the `Map.Entry` contract: equal iff keys and values are equal,
        // regardless of the other operand's concrete type (a builtin
        // `MapEntry` or another `Map.Entry` instance).
        if (Value.mapEntryContractEq(receiver, &args[0])) |eq| {
            return .{ .ok = boolVal(eq) };
        }
        // Data/value classes compare structurally even when an interface
        // in their hierarchy redeclares equals (ValueTimeMark).
        {
            const g = inst.borrow();
            const cg = g.get().class.borrow();
            const structural = cg.get().is_data or cg.get().is_value;
            const annotation = cg.get().is_annotation;
            cg.deinit();
            g.deinit();
            if (annotation) {
                return .{ .ok = boolVal(try annotationInstanceEquals(self, allocator, inst, &args[0])) };
            }
            if (structural) {
                return .{ .ok = boolVal(try dataValueInstanceEquals(self, allocator, inst, &args[0])) };
            }
        }
        if (args[0] == .Instance) {
            return .{ .ok = boolVal(ObjRef(InstanceData).ptrEq(inst, args[0].Instance)) };
        }
        return .{ .ok = boolVal(false) };
    }
    return null;
}

pub fn renderStructuralLocked(allocator: Allocator, inst: *const InstanceData, cls: *const ClassDef) Allocator.Error!Value {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, classDisplayName(cls.name));
    try buf.append(allocator, '(');
    for (cls.primary_params, 0..) |p, idx| {
        if (idx > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, p.name);
        try buf.append(allocator, '=');
        const v = inst.get(p.name) orelse Value.Null;
        try buf.appendSlice(allocator, try v.display(allocator));
    }
    try buf.append(allocator, ')');
    return .{ .String = try runtime.strInitOwned(allocator, try buf.toOwnedSlice(allocator)) };
}

/// Format `"{prefix}.{name}"` into `buf` (stack scratch), returning the slice.
/// Probe FQNs are short and bounded, so this avoids the per-call heap churn of
/// `allocPrint` — member dispatch builds up to ~6 of these on every call.
pub inline fn probeFqn(buf: []u8, prefix: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ prefix, name }) catch buf[0..0];
}

/// Whether the call selects a DECLARED lambda-taking overload the
/// member-form intrinsic cannot represent: the last arg is callable, a
/// body-bearing receiver-formed declaration named `name` fits the call
/// arity exactly with a function-typed last parameter, AND a shorter
/// non-lambda sibling declaration also exists (the shape the intrinsic
/// actually implements — `copyOf(newSize)` vs
/// `copyOf(newSize, init)`). Without the sibling requirement every HOF
/// intrinsic (`map`, `filter`) would fall off its fast path.
/// Element kinds whose arithmetic differs per declared width — the only
/// erased receiver-type-arg ties resolution must refuse to guess.
pub fn numericWidthKind(name: []const u8) bool {
    const kinds = [_][]const u8{
        "Int",  "Long",  "Short",  "Byte",  "Double", "Float",
        "UInt", "ULong", "UShort", "UByte", "Char",
    };
    for (kinds) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
}

pub fn declaredLambdaOverloadWins(self: *VmHost, name: []const u8, args: []const Value) bool {
    if (args.len == 0 or !isCallable(&args[args.len - 1])) return false;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    var lambda_exact = false;
    var shorter_plain = false;
    for (mod.funcsBySimpleName(name)) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        if (!(f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this"))) continue;
        const last_is_fn = std.mem.startsWith(u8, f.params[f.params.len - 1].ty.name, "Function");
        if (f.hasBody() and f.params.len == args.len + 1 and last_is_fn) {
            lambda_exact = true;
        }
        if (f.params.len < args.len + 1 and (f.params.len == 1 or !last_is_fn)) {
            shorter_plain = true;
        }
        if (lambda_exact and shorter_plain) return true;
    }
    return false;
}

pub threadlocal var charseq_fallback_active: bool = false;

/// Whether the instance's class chain implements `CharSequence`.
pub fn instanceImplementsCharSequence(self: *VmHost, receiver: *const Value) bool {
    if (receiver.* != .Instance) return false;
    const cname = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.class_super_names.get(cname)) |chain| {
        for (chain) |sup| {
            if (std.mem.eql(u8, sup, "CharSequence")) return true;
        }
    }
    return false;
}

/// Whether the instance's class (or its recorded supertype chain)
/// implements `Sequence` — such receivers keep sequence laziness.
pub fn instanceImplementsSequence(self: *VmHost, receiver: *const Value) bool {
    if (receiver.* != .Instance) return false;
    const cname = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.class_super_names.get(cname)) |chain| {
        for (chain) |sup| {
            if (std.mem.eql(u8, sup, "Sequence")) return true;
        }
    }
    return false;
}

/// Whether a declared extension with receiver type `Sequence` and a real
/// body exists for `name` — the lazy source implementation that must win
/// over eager collection intrinsics for Sequence receivers.
pub fn declaredSequenceExtBody(self: *VmHost, name: []const u8) bool {
    return sequenceExtBodyFid(self, name, null) != null;
}

/// The declared Sequence-receiver extension with a body for `name` whose
/// arity accepts `n_args` value arguments (receiver excluded); any arity
/// when `n_args` is null.
pub fn sequenceExtBodyFid(self: *VmHost, name: []const u8, n_args: ?usize) ?FuncId {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    var best: ?FuncId = null;
    for (mod.funcsBySimpleName(name)) |fid| {
        const sig = mod.decl_sigs.get(fid.int()) orelse continue;
        const rt = sig.receiver_ty orelse continue;
        if (!std.mem.eql(u8, rt.name, "Sequence")) continue;
        const f = mod.funcById(fid) orelse continue;
        // Headers decode lazily: judge executability by the settled form
        // (body, sibling redirect, or native binding), not hasBody().
        if (n_args) |n| {
            if (!host_call_func.executableForm(self, mod, fid, n + 1)) continue;
            // DeclSig arity counts value params only (receiver excluded).
            if (n < sig.arity.required) continue;
            if (n > sig.arity.total and !sig.arity.has_vararg) continue;
            if (best == null or f.params.len < (mod.funcById(best.?) orelse f).params.len) best = fid;
        } else {
            if (!host_call_func.executableForm(self, mod, fid, sig.arity.required + 1)) continue;
            return fid;
        }
    }
    return best;
}

pub fn stdlibMemberDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    ir.eval.dispatchNote(.served_intrinsic);
    runtime.prof.opRoute(6);
    // A declared lambda-taking overload the intrinsic surface cannot
    // express wins resolution; decline so the walk's extension fallback
    // runs its body (declaration decides, the registry only serves).
    if (declaredLambdaOverloadWins(self, name, args)) return null;
    // A multi-index `a[i, j]` / `a[i, j] = v` desugars to `a.get(i, j)` /
    // `a.set(i, j, v)`, which only a user-declared operator provides — the
    // builtin indexed `get` takes ONE index and `set` takes (index, value).
    // Decline the over-arity call (args exclude the receiver) so the
    // extension fallback resolves the user operator instead of the builtin
    // silently dropping the extra index. Returned BEFORE the resolution
    // cache so the normal 1-index / (index,value) forms are unaffected.
    if (std.mem.eql(u8, name, "get") and args.len > 1) return null;
    if (std.mem.eql(u8, name, "set") and args.len > 2) return null;
    const type_fqn = receiver.typeFqn();
    // Resolution cache: the winning intrinsic (or "none") is a pure function
    // of (type, name, args-empty), so memoize it and skip the per-call probe
    // building + repeated `lookupIntrinsic` borrows. A non-Instance receiver
    // keys by its (static) type-fqn pointer. An Instance's typeFqn is not
    // class-specific, so it keys by class-cell identity instead — the same
    // identity `host_has_member_cache` uses, and everything the uncached body
    // consults for an Instance (hostHasMember, the shadow probes) is a
    // function of the class, not the individual instance. Array builders use
    // a different (no-prepend) dispatch and are excluded.
    // The resolution cache is keyed by exactly what decides the answer — the
    // receiver's class (or its static type-fqn), the name, and whether the
    // call has arguments — so it is probed FIRST. Everything that decides
    // whether an entry may be STORED (`isArrayBuilder`, and the top-level
    // extension probe, which borrows the module and hashes the name) is a
    // pure function of the same inputs, so a hit already proves it; computing
    // it ahead of the probe put a module borrow and a name-index lookup on
    // every intrinsic member dispatch.
    const name_p_opt = memberNameIdentity(self, name);
    if (name_p_opt) |name_p| {
        const type_p: usize = if (receiver.* == .Instance) blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            break :blk g.get().class.identity();
        } else @intFromPtr(type_fqn.ptr);
        const key: root_mod.ProgramImage.MemberResolveKey = .{
            .type_p = type_p,
            .name_p = name_p,
            .args_empty = args.len == 0,
        };
        // File-qualified sibling key: when an imported pack extension shadows
        // the stdlib surface the answer is a function of the call site's
        // import scope and the call's arity too, so those resolutions cache
        // under (file+1, argc) rather than not at all (`writable` /
        // `withCurrent` on a snapshot record re-ran the whole ladder tens of
        // thousands of times per state-list stress rep).
        const key_f: ?root_mod.ProgramImage.MemberResolveKey = blk: {
            const sp = ir.eval.currentCallSiteSpan() orelse break :blk null;
            var k = key;
            k.file = @as(u32, @intFromEnum(sp.file)) + 1;
            k.argc = @intCast(args.len);
            break :blk k;
        };
        // Thread-local L1 (see `tl_method_cache`): a hit avoids the shared
        // program cell's reader lock and its cross-core coherence traffic.
        for ([2]?root_mod.ProgramImage.MemberResolveKey{ key, key_f }) |k_opt| {
            const k = k_opt orelse continue;
            const e = &caches.tl_resolve_cache[tlResolveSlot(k)];
            if (tlResolveMatch(e, k)) {
                if (e.state == 1) return null;
                return try dispatchWithReceiver(self, allocator, e.fqn, e.func.?, receiver, args);
            }
        }
        for ([2]?root_mod.ProgramImage.MemberResolveKey{ key, key_f }) |k_opt| {
            const k = k_opt orelse continue;
            const hit: ?root_mod.ProgramImage.MemberResolveEntry = blk: {
                const pg = self.prog.borrow();
                defer pg.deinit();
                break :blk pg.get().member_resolve_cache.get(k);
            };
            if (hit) |entry| {
                tlResolveStore(k, entry);
                const func = entry.func orelse return null;
                return try dispatchWithReceiver(self, allocator, entry.fqn, func, receiver, args);
            }
        }
        const cacheable = !stdlib.isArrayBuilder(name) and
            !(try userToplevelExtNamedExists(self, allocator, receiver, name));
        return try stdlibMemberDispatchUncached(self, allocator, receiver, name, args, type_fqn, if (cacheable) key else null, if (cacheable) key_f else null);
    }
    return try stdlibMemberDispatchUncached(self, allocator, receiver, name, args, type_fqn, null, null);
}

pub fn stdlibMemberDispatchUncached(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, type_fqn: []const u8, cache_key: ?root_mod.ProgramImage.MemberResolveKey, cache_key_file: ?root_mod.ProgramImage.MemberResolveKey) Allocator.Error!?EvalResult {
    if (runtime.envOnce("KLIO_SDU_TRACE") != null)
        std.debug.print("[sdu] type={s} name={s} cacheable={}\n", .{ type_fqn, name, cache_key != null });
    // A Sequence receiver with a DECLARED Sequence-receiver extension body
    // must run that lazy source implementation — the package probes below
    // would bind an eager collection intrinsic (`kotlin.collections.chunked`
    // materializes the receiver, breaking Kotlin's sequence laziness).
    // Terminal names never reach here (the sequence arm handles them).
    if (receiver.* == .Sequence and declaredSequenceExtBody(self, name)) return null;
    // Probe FQNs in priority order, formatted into per-call stack buffers (no
    // heap traffic). `kotlin.<name>` etc. are formatted too so one code path
    // builds them all; the storage outlives the loop below.
    var bufs: [8][128]u8 = undefined;
    var probes: [8][]const u8 = undefined;
    // Which probes name a MEMBER of the receiver's type (keyed by the type's
    // FQN) rather than one of the stdlib's package-level EXTENSIONS. Kotlin
    // resolves a member before any extension, so a user extension shadows the
    // extension probes and never the member ones.
    var probe_is_member: [8]bool = @splat(false);
    var n: usize = 0;
    const type_probe = probeFqn(&bufs[0], type_fqn, name);
    if (args.len == 0) {
        probes[0] = type_probe;
        probe_is_member[0] = true;
        probes[1] = probeFqn(&bufs[1], "kotlin.collections", name);
        probes[2] = probeFqn(&bufs[2], "kotlin.text", name);
        probes[3] = probeFqn(&bufs[3], "kotlin.ranges", name);
        probes[4] = probeFqn(&bufs[4], "kotlin", name);
        n = 5;
    } else {
        probes[0] = probeFqn(&bufs[0], "kotlin.ranges", name);
        probes[1] = probeFqn(&bufs[1], "kotlin.collections", name);
        probes[2] = probeFqn(&bufs[2], "kotlin.text", name);
        probes[3] = probeFqn(&bufs[3], type_fqn, name);
        probe_is_member[3] = true;
        probes[4] = probeFqn(&bufs[4], "kotlin", name);
        n = 5;
    }
    // Sibling read-only/mutable collection type, inserted right after the
    // receiver-type probe so a `MutableList` op can resolve a `List`-declared
    // intrinsic (and vice versa).
    const sibling: ?[]const u8 = blk: {
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.MutableList")) break :blk "kotlin.collections.List";
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.MutableSet")) break :blk "kotlin.collections.Set";
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.MutableMap")) break :blk "kotlin.collections.Map";
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.List")) break :blk "kotlin.collections.MutableList";
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.Set")) break :blk "kotlin.collections.MutableSet";
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.Map")) break :blk "kotlin.collections.MutableMap";
        break :blk null;
    };
    if (sibling) |sib| {
        const sib_probe = probeFqn(&bufs[5], sib, name);
        // Find the receiver-type probe and insert the sibling right after it.
        var at: usize = n;
        for (probes[0..n], 0..) |p, idx| {
            if (std.mem.eql(u8, p, type_probe)) {
                at = idx + 1;
                break;
            }
        }
        var k: usize = n;
        while (k > at) : (k -= 1) {
            probes[k] = probes[k - 1];
            probe_is_member[k] = probe_is_member[k - 1];
        }
        probes[at] = sib_probe;
        probe_is_member[at] = true;
        n += 1;
    }
    // Throwable family probe.
    if (receiver.* == .Instance) {
        if (instanceIsThrowable(self, allocator, receiver.Instance)) {
            probes[n] = probeFqn(&bufs[6], "kotlin.Throwable", name);
            probe_is_member[n] = true;
            n += 1;
        }
    }

    const member_shadows_stdlib = receiver.* == .Instance and hostHasMember(self, receiver, name);
    const user_member_ext_shadows = try userMemberExtShadows(self, allocator, receiver, name, args.len);
    // Scope-aware pack-extension shadowing: an in-scope (imported) pack
    // extension outranks the implicit stdlib surface for this call site;
    // a merely-POTENTIAL one makes the resolution file-dependent, so the
    // (type, name) memoization below must stand down.
    const pack_ext_shadow = try importedPackExtShadows(self, allocator, receiver, name, args.len);
    const effective_cache_key: ?root_mod.ProgramImage.MemberResolveKey =
        if (pack_ext_shadow == .none) cache_key else cache_key_file;
    // `range in range`: the builtin `Range.contains` intrinsic takes an
    // ELEMENT, so a Range argument is inapplicable to every probe the
    // ladder could hit — leave it for the extension fallback, where a
    // range-over-range operator (`LongRange.contains(LongRange)`) binds.
    const range_in_range = receiver.* == .Range and args.len == 1 and
        args[0] == .Range and std.mem.eql(u8, name, "contains");

    // Array builder global factory direct dispatch.
    if (stdlib.isArrayBuilder(name) and !hostHasMember(self, receiver, name)) {
        const probe = probeFqn(&bufs[7], "kotlin", name);
        if (lookupIntrinsic(self, probe)) |func| {
            return try dispatchIntrinsic(self, allocator, probe, func, args);
        }
    }

    if (!member_shadows_stdlib and !user_member_ext_shadows and !range_in_range and
        pack_ext_shadow != .shadows and
        !stdlib.isToplevelFunction(name))
    {
        // A user extension shadows the stdlib's EXTENSIONS — but never its
        // MEMBERS. Kotlin resolves a member first, so `fun Long.toInt(): Int`
        // does not capture `7L.toInt()`; the member does, and the extension's
        // own `this.toInt()` reaches it (rather than calling itself for ever).
        const user_ext_shadows = try userToplevelExtShadows(self, allocator, receiver, name, args);
        // A member is applicable only at its declared arity: `list[i, j]`
        // with `operator fun ArrayList<T>.get(i: Int, j: Int)` declared is
        // the extension's call, never the one-index member's.
        const decl_owner: []const u8 = if (receiver.* == .Instance) blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk if (cg.get().fqn.len != 0) cg.get().fqn else cg.get().name;
        } else type_fqn;
        const member_arity_misfit = user_ext_shadows and memberDeclArityMisfit(self, decl_owner, name, args.len);
        for (probes[0..n], probe_is_member[0..n]) |probe, is_member| {
            if (user_ext_shadows and (!is_member or member_arity_misfit)) continue;
            // A member outranks an extension only while its host binding is
            // applicable. Intrinsics whose Kotlin declarations are pruned
            // from the runtime image carry this small predicate alongside
            // the binding, so `Int.or(Int)` cannot capture the distinct
            // `Int.or(NodeKind)` overload, and `String.repeat(Int)` cannot
            // capture a bare `repeat(times) { … }` reaching a String through
            // the enclosing-receiver walk.
            if (stdlib.implementationApplicable(probe, args)) |applies| {
                if (!applies) continue;
            }
            if (lookupIntrinsic(self, probe)) |func| {
                if (effective_cache_key) |key| memberCachePut(self, key, func, probe);
                return try dispatchWithReceiver(self, allocator, probe, func, receiver, args);
            }
        }
    }
    // No intrinsic resolved: memoize the miss so the next identical call skips
    // the probe build + lookups and falls straight through to extension/global.
    if (effective_cache_key) |key| memberCachePut(self, key, null, "");
    return null;
}

/// Store a member-resolution result on the shared program image. `func == null`
/// records a confirmed miss; a non-empty `fqn` is duped into the program's
/// allocator (lives for the program; bounded by distinct resolved members).
pub fn memberCachePut(self: *VmHost, key: root_mod.ProgramImage.MemberResolveKey, func: ?StdlibFn, fqn: []const u8) void {
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    const cache = &pg.get().member_resolve_cache;
    if (cache.contains(key)) return;
    const stored_fqn: []const u8 = if (func != null and fqn.len != 0)
        (cache.allocator.dupe(u8, fqn) catch return)
    else
        "";
    cache.put(key, .{ .func = func, .fqn = stored_fqn }) catch {
        if (stored_fqn.len != 0) cache.allocator.free(stored_fqn);
    };
}

/// `Throwable.printStackTrace()` / `.stackTraceToString()` rendered from the
/// stack captured at throw time. Returns null for a name these do not handle or
/// a receiver that is not a throwable, so normal dispatch proceeds.
pub fn throwableStackMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    if (args.len != 0) return null;
    const is_print = std.mem.eql(u8, name, "printStackTrace");
    const is_tostr = std.mem.eql(u8, name, "stackTraceToString");
    const is_elems = std.mem.eql(u8, name, "getStackTrace") or std.mem.eql(u8, name, "stackTrace");
    if (!is_print and !is_tostr and !is_elems) return null;

    switch (receiver.*) {
        .Exception => {},
        .Instance => |inst| {
            if (!instanceIsThrowable(self, allocator, inst)) return null;
        },
        else => return null,
    }
    if (is_elems) {
        return .{ .ok = (try ir.eval.stackTraceArray(allocator, receiver)) orelse runtime.ArrayData.fromBoxedList(try runtime.ValueList.initOwned(allocator, .empty)) };
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try ir.eval.formatThrowable(allocator, receiver, &buf, false, 0);
    if (is_print) {
        std.debug.print("{s}\n", .{buf.items});
        return .{ .ok = .Unit };
    }
    // Adopt a private copy: `buf` is freed on return, and `strInit`'s
    // arena fast path would otherwise alias (then dangle) `buf.items`.
    const owned = try allocator.dupe(u8, buf.items);
    return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, owned) } };
}

/// `addSuppressed`/`getSuppressed` on an INTERPRETED throwable instance. The
/// suppressed list lives in a hidden `__suppressed__` field on the instance
/// (a user throwable is a plain Instance until thrown), so every alias of
/// the instance observes the same set. Host `Exception` values carry their
/// list in the value itself and dispatch through the stdlib binding instead.
pub fn throwableSuppressedMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const is_add = std.mem.eql(u8, name, "addSuppressed") and args.len == 1;
    const is_get = std.mem.eql(u8, name, "getSuppressed") and args.len == 0;
    if (!is_add and !is_get) return null;
    const inst = switch (receiver.*) {
        .Instance => |i| i,
        else => return null,
    };
    {
        const g = inst.borrow();
        defer g.deinit();
        const declared = g.get().get(name) != null;
        if (declared) return null;
    }
    if (!instanceIsThrowable(self, allocator, inst)) return null;
    if (is_get) {
        const cur = instanceSuppressedList(inst);
        if (cur) |l| return .{ .ok = l };
        const items = try runtime.ValueList.init(allocator, .empty);
        return .{ .ok = try Value.newList(allocator, .{ .items = items, .mutable = false, .backing = null }) };
    }
    try appendInstanceSuppressed(inst, allocator, args[0]);
    return .{ .ok = .Unit };
}

/// The instance's `__suppressed__` list value, if one was created.
pub fn instanceSuppressedList(inst: ObjRef(InstanceData)) ?Value {
    const g = inst.borrow();
    defer g.deinit();
    const v = g.get().get("__suppressed__") orelse return null;
    if (v != .List) return null;
    return v;
}

/// Append to the instance's hidden suppressed list, creating it on first use.
pub fn appendInstanceSuppressed(inst: ObjRef(InstanceData), allocator: Allocator, e: Value) Allocator.Error!void {
    const list: Value = blk: {
        if (instanceSuppressedList(inst)) |l| break :blk l;
        const items = try runtime.ValueList.init(allocator, .empty);
        const fresh = try Value.newList(allocator, .{ .items = items, .mutable = true, .backing = null });
        const g = inst.borrowMut();
        defer g.deinit();
        try g.get().define(allocator, "__suppressed__", fresh);
        break :blk fresh;
    };
    const g = list.List.items.borrowMut();
    defer g.deinit();
    if (runtime.reclaimEnabled()) e.retain();
    try g.get().append(allocator, e);
}

pub fn instanceIsThrowable(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData)) bool {
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        stack.append(allocator, cg.get().name) catch return false;
        cg.deinit();
        g.deinit();
    }
    while (stack.pop()) |cn| {
        if (seen.contains(cn)) continue;
        seen.put(cn, {}) catch {};
        if (std.mem.eql(u8, cn, "Throwable") or std.mem.eql(u8, cn, "Exception") or
            std.mem.eql(u8, cn, "RuntimeException") or std.mem.eql(u8, cn, "Error") or
            std.mem.eql(u8, cn, "CancellationException")) return true;
        const cg = self.classes.borrow();
        if (cg.get().get(cn)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |s| stack.append(allocator, s) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

pub fn inheritedInstanceToString(allocator: Allocator, inst: ObjRef(InstanceData), is_throwable: bool) Allocator.Error!Value {
    const ig = inst.borrow();
    defer ig.deinit();
    const cg = ig.get().class.borrow();
    const fqn = cg.get().fqn;
    cg.deinit();
    if (is_throwable) {
        const msg: ?[]const u8 = if (ig.get().get("message")) |mv| switch (mv) {
            .String => |s| blk: {
                const sg = s.borrow();
                defer sg.deinit();
                break :blk try allocator.dupe(u8, sg.get().bytes);
            },
            else => null,
        } else null;
        const rendered = if (msg) |m|
            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ fqn, m })
        else
            try allocator.dupe(u8, fqn);
        return .{ .String = try runtime.strInitOwned(allocator, rendered) };
    }
    const rendered = try std.fmt.allocPrint(allocator, "{s}@{x}", .{ fqn, ig.get().identity });
    return .{ .String = try runtime.strInitOwned(allocator, rendered) };
}
