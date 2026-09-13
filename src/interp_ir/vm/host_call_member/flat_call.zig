//! The `callMember` entry point and the flat-call preparation surface the IR
//! evaluator calls to bind a member site without re-walking the ladder.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const applicability = @import("applicability");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const trace = @import("../trace.zig");
const persistent_list_eq = @import("../persistent_list_eq.zig");
const persistent_list_mut = @import("../persistent_list_mut.zig");
const persistent_map_mut = @import("../persistent_map_mut.zig");
const host_call_func = @import("../host_call_func.zig");
const host_call_value = @import("../host_call_value.zig");
const compose = @import("../compose.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const StdlibFn = runtime.StdlibFn;
const Module = ir.Module;
const FuncId = ir.FuncId;
const MethodSlotId = ir.MethodSlotId;
const EvalResult = ir.eval.EvalResult;

const caches = @import("caches.zig");
const METHOD_MISS = caches.METHOD_MISS;
const extMethodCacheGet = caches.extMethodCacheGet;
const instanceMethodCacheGetRaw = caches.instanceMethodCacheGetRaw;
const resolvedMemberName = caches.resolvedMemberName;
const tlResolveSlot = caches.tlResolveSlot;
const tlSlot = caches.tlSlot;
const virtualSlotInterfaceMember = caches.virtualSlotInterfaceMember;

const hcm = @import("../host_call_member.zig");
const cacheGen = hcm.cacheGen;
const callValueRec = hcm.callValueRec;
const checkFuncInRange = hcm.checkFuncInRange;
const checkReceiverChain = hcm.checkReceiverChain;
const dispatchIntrinsic = hcm.dispatchIntrinsic;
const lookupIntrinsic = hcm.lookupIntrinsic;
const simpleName = hcm.simpleName;

const member_ext_visibility = @import("member_ext_visibility.zig");
const interfaceDelegateFor = member_ext_visibility.interfaceDelegateFor;
const isMemberExt = member_ext_visibility.isMemberExt;

const member_presence = @import("member_presence.zig");
const enclosingThisChain = member_presence.enclosingThisChain;
const hostHasMember = member_presence.hostHasMember;
const memberNameIdentity = member_presence.memberNameIdentity;

const named_call = @import("named_call.zig");
const namedOrderKey = named_call.namedOrderKey;

const receiver_probe = @import("receiver_probe.zig");
const headNamesRegisteredClass = receiver_probe.headNamesRegisteredClass;
const receiverImplementsHead = receiver_probe.receiverImplementsHead;
const valueNominalFqn = receiver_probe.valueNominalFqn;

const reflect_anon = @import("reflect_anon.zig");
const funcAt = reflect_anon.funcAt;
const lookupAnonMethod = reflect_anon.lookupAnonMethod;
const root_mod = reflect_anon.root_mod;

const resolve_method = @import("resolve_method.zig");
const resolveInstanceMethod = resolve_method.resolveInstanceMethod;
const virtualTargetExecutable = resolve_method.virtualTargetExecutable;

const slot_ops = @import("slot_ops.zig");
const barrierSpec = slot_ops.barrierSpec;
const slotNameOrNull = slot_ops.slotNameOrNull;
const typeSafeBarrierAnswer = slot_ops.typeSafeBarrierAnswer;

const static_tail = @import("static_tail.zig");
const callMemberInnerStatic = static_tail.callMemberInnerStatic;
const freeDispatchMiss = static_tail.freeDispatchMiss;
const missTraceWant = static_tail.missTraceWant;
const nuTraceEnv = static_tail.nuTraceEnv;
const samTraceOn = static_tail.samTraceOn;

const stdlib_tail = @import("stdlib_tail.zig");
const bridgeForReceiver = stdlib_tail.bridgeForReceiver;

const virtual_tail = @import("virtual_tail.zig");
const instanceMethodKeyRelaxed = virtual_tail.instanceMethodKeyRelaxed;
const instanceMethodKeyScoped = virtual_tail.instanceMethodKeyScoped;
const methodArgSig = virtual_tail.methodArgSig;

// -------------------------------------------------------------------------
// Small construction helpers.
// -------------------------------------------------------------------------

pub fn listOf(allocator: Allocator, items: std.ArrayList(Value), mutable: bool) Allocator.Error!Value {
    return try Value.newList(allocator, .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
    });
}

pub fn cloneItemsList(allocator: Allocator, src: runtime.ValueList) Allocator.Error!std.ArrayList(Value) {
    const g = src.borrow();
    defer g.deinit();
    var out: std.ArrayList(Value) = .empty;
    try out.appendSlice(allocator, g.get().items);
    // An owned copy: every wrapper built from this list (a new List/Array/Set/
    // Iterator, or a `sorted` list that escapes) takes one reference per element,
    // so retain each. The source still owns its own refs. No-op under the arena.
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return out;
}

/// Prepend `receiver` to `args`, returning a freshly-allocated slice.
pub fn isArrayContentFn(name: []const u8) bool {
    const fns = [_][]const u8{ "contentToString", "contentHashCode", "contentDeepToString", "contentDeepHashCode", "contentEquals", "contentDeepEquals" };
    for (fns) |f| if (std.mem.eql(u8, name, f)) return true;
    return false;
}

pub fn prependReceiver(allocator: Allocator, receiver: *const Value, args: []const Value) Allocator.Error![]Value {
    var all = try allocator.alloc(Value, args.len + 1);
    all[0] = receiver.*;
    @memcpy(all[1..], args);
    return all;
}

pub fn callCallableIndexed(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    root: FuncId,
    receiver: *const Value,
    callable: *const Value,
    args: []const Value,
    arg_params: []const u32,
) Allocator.Error!EvalResult {
    const bound = try host_call_func.bindFuncIndexedArgs(self, allocator, module, root, root, receiver, args, arg_params);
    switch (bound) {
        .ok => |ordered| {
            defer allocator.free(ordered);
            if (ordered.len == 0) return .{ .err = .{ .Type = "virtual callable slot has no receiver" } };
            return host_call_value.callValue(self, allocator, callable, ordered[1..]);
        },
        .err => |err| return .{ .err = err },
    }
}

/// Dispatch an intrinsic with the receiver prepended to `args`, using a stack
/// buffer for the common small-arity case so a member call needs no heap
/// allocation for its argument vector. The prepended slice never outlives the
/// call (`dispatchIntrinsic` is synchronous and intrinsics read their args
/// during the call — the heap path here freed it immediately too), so the stack
/// buffer is exactly as safe. Falls back to the heap for large arities.
pub fn dispatchWithReceiver(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, receiver: *const Value, args: []const Value) Allocator.Error!EvalResult {
    var stackbuf: [16]Value = undefined;
    if (args.len + 1 <= stackbuf.len) {
        stackbuf[0] = receiver.*;
        @memcpy(stackbuf[1 .. 1 + args.len], args);
        return dispatchIntrinsic(self, allocator, fqn, func, stackbuf[0 .. 1 + args.len]);
    }
    const all_args = try prependReceiver(allocator, receiver, args);
    defer if (runtime.freeScratch()) allocator.free(all_args);
    return dispatchIntrinsic(self, allocator, fqn, func, all_args);
}

// -------------------------------------------------------------------------
// `callMember` — the central dispatch.
// -------------------------------------------------------------------------

pub fn instanceInvokeWantsPair(self: *VmHost, receiver: *const Value, nargs: usize) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const recv_fqn = blk: {
        const ig = receiver.Instance.borrow();
        defer ig.deinit();
        const cg = ig.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    const cid = mod.classIdByFqn(recv_fqn) orelse return false;
    const irc = &mod.classes.items[cid.int()];
    var paired = false;
    for (irc.methods) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        if (!std.mem.eql(u8, f.name, "invoke")) continue;
        const has_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        const n = f.params.len - @intFromBool(has_this);
        // The wrapper's overloads are real source (`invoke(p1, c: Composer,
        // changed: Int)`), so the pair is recognized by shape: a
        // Composer-typed slot followed by the changed flags. Reaching this
        // helper at all means the plain dispatch missed, so a same-arity
        // sibling needs no exclusion — nothing bound.
        if (n == nargs + 2 and
            std.mem.endsWith(u8, f.params[f.params.len - 2].ty.name, "Composer") and
            std.mem.eql(u8, f.params[f.params.len - 1].ty.name, "Int")) paired = true;
    }
    return paired;
}

/// The `provideDelegate` convention at a delegated property's creation:
/// the delegate expression's value receives `provideDelegate(thisRef, ::p)`
/// when a member or extension operator applies; a dispatch miss keeps the
/// value, any other failure is the property's initialization failure.
pub fn provideDelegateFor(self: *VmHost, allocator: Allocator, this_ref: Value, prop_ref: Value, v: Value) Allocator.Error!EvalResult {
    // A property reference delegate (`by contents::zone`) forwards every
    // member call to its target, so it is never offered the convention.
    switch (v) {
        .PropertyRef => return .{ .ok = v },
        .Instance => |inst| {
            const forwards = blk: {
                const g = inst.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                break :blk std.mem.startsWith(u8, cg.get().name, "$bound_ref$");
            };
            if (forwards) return .{ .ok = v };
        },
        else => {},
    }
    const r = try callMemberInner(self, allocator, &v, "provideDelegate", &.{ this_ref, prop_ref }, false);
    switch (r) {
        .ok => return r,
        .err => |e| {
            // Only the dispatch miss for `provideDelegate` itself means the
            // convention does not apply; a miss raised inside an operator
            // that ran is the property's initialization failure.
            if (e == .Unimplemented and std.mem.find(u8, e.Unimplemented, "`provideDelegate`") != null) return .{ .ok = v };
            return r;
        },
    }
}

pub fn callMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!EvalResult {
    const r = try callMemberInner(self, allocator, receiver, name, args, false);
    // A raw callable value asked for a member nothing serves: the value
    // stands in for a SAM instance (a lambda flowing where a fun interface
    // is expected — `FlowCollector`'s `emit` on a collector that arrived as
    // a plain function), so the single-abstract-method call IS an
    // invocation of the callable. Direct-dispatch only: the bare-name
    // resolver's candidate walks must keep their misses so outer receivers
    // and extensions still get their turn.
    if (r == .err and r.err == .Unimplemented and
        (receiver.* == .IrClosure))
    {
        // Interface-method reading is only plausible when the callable's
        // declared parameter count matches the call (except `invoke`,
        // which is every callable's own surface). Without the gate, an
        // unresolved helper name dispatched with the block as `this`
        // (`probeCoroutineResumed(completion)` inside
        // `startCoroutineUndispatched`) invoked the coroutine block —
        // every UNDISPATCHED launch body ran twice.
        if (!std.mem.eql(u8, name, "invoke")) {
            const n = callableFieldArity(self, receiver) orelse return r;
            if (n != args.len) return r;
        }
        freeDispatchMiss(allocator, r);
        if (samTraceOn()) std.debug.print("[sam-direct] name={s} nargs={d}\n", .{ name, args.len });
        // The interface method may declare an extension receiver
        // (`PointerInputEventHandler`'s `PointerInputScope.invoke()`):
        // Kotlin resolves it from the call site's enclosing implicit
        // receivers, and the lambda body's bare-member calls
        // (`awaitPointerEventScope { … }`) resolve against it. Hand the
        // innermost enclosing instance as `this`; a body that never
        // reads a receiver is unaffected.
        const encl = ir.eval.enclosingEntriesAlloc(allocator) catch &.{};
        defer allocator.free(@constCast(encl));
        for (encl) |e| {
            if (e.v != .Instance) continue;
            return host_call_value.callValueWithThis(self, allocator, receiver, &e.v, args, &.{});
        }
        return host_call_value.callValue(self, allocator, receiver, args);
    }
    // Compose ABI completion at the callable-instance surface: a composable
    // lambda wrapper invoked as a plain value (`receiver.content()`) arrives
    // WITHOUT the pass-appended ($composer, $changed) pair — the pass leaves
    // unclassified value invocations unthreaded and relies on the runtime to
    // complete the pair. The closure route completes it already; this is the
    // same completion for a wrapper CLASS whose only matching `invoke`
    // overload carries the trailing pair.
    if (r == .err and r.err == .Unimplemented and receiver.* == .Instance and
        std.mem.eql(u8, name, "invoke"))
    {
        if (missTraceWant(name)) std.debug.print("[inv-pair] reach recv={s} nargs={d} composer={} wants={}\n", .{ receiver.typeFqn(), args.len, compose.currentComposer() != null, instanceInvokeWantsPair(self, receiver, args.len) });
        if (compose.currentComposer()) |c| {
            if (instanceInvokeWantsPair(self, receiver, args.len)) {
                freeDispatchMiss(allocator, r);
                var ext: std.ArrayList(Value) = .empty;
                defer ext.deinit(allocator);
                try ext.ensureTotalCapacityPrecise(allocator, args.len + 2);
                ext.appendSliceAssumeCapacity(args);
                ext.appendAssumeCapacity(c);
                ext.appendAssumeCapacity(.{ .Int = 0 });
                return callMemberInner(self, allocator, receiver, name, ext.items, false);
            }
        }
    }
    return r;
}

/// `strict_ext` restricts the extension fallback to candidates whose
/// declared receiver type provably accepts this receiver. The bare-name
/// resolver's innermost-first candidate walk uses it so an extension that
/// is not applicable to an inner receiver cannot pre-empt a real member
/// of an outer one (kotlinc: a receiver-incompatible extension is not a
/// candidate at that receiver at all); the unproven-compatibility pick
/// stays available as the resolver's later lenient pass and as the
/// explicit-dispatch default.
pub fn callMemberInner(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool) Allocator.Error!EvalResult {
    return callMemberInnerStatic(self, allocator, receiver, name, args, strict_ext, null, false, null);
}

/// An `IrClosure`/`Function` field's declared parameter count, or null when
/// the value is not a closure-style callable.
pub fn callableFieldArity(self: *VmHost, v: *const Value) ?usize {
    switch (v.*) {
        .IrClosure => |c| {
            const info = self.closures.get(@intCast(c.asPtr().id)) orelse return null;
            const mr = self.module.clone();
            defer mr.deinit();
            const module = info.module orelse mr.asPtr();
            const func = module.funcById(info.body_func) orelse return null;
            return func.params.len;
        },
                else => return null,
    }
}

/// Whether instance `v` could serve bare `name` as a receiver: a member
/// somewhere in its class hierarchy (the lowered `hierarchy_methods`
/// name set, which covers abstract members and overrides alike), a
/// method/body property on its `ClassDef` chain, or an extension whose
/// declared receiver the class chain reaches. The SAM-callable walk arm
/// consults DEEPER candidates through this before invoking an in-scope
/// callable as a fun-interface method — kotlinc binds an outer implicit
/// receiver's member or extension (`collect(this)` inside an
/// `unsafeFlow` block binds the outer Flow's `collect`) over the
/// interface-method reading of a captured lambda.
pub fn debugClassNameOf(self: *VmHost, v: *const Value) []const u8 {
    _ = self;
    if (v.* != .Instance) return "-";
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return cg.get().name;
}

/// The classifier head of a source-spelled supertype name: generic args
/// and nullability stripped (`Flow<T>` -> `Flow`).
pub fn supertypeHead(raw: []const u8) []const u8 {
    var h = raw;
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    return std.mem.trimEnd(u8, std.mem.trim(u8, h, " "), "?");
}

pub fn valueCouldServeName(self: *VmHost, allocator: Allocator, v: *const Value, name: []const u8, argc: usize) bool {
    if (v.* != .Instance) {
        // A builtin-backed value (a List, String, Array, Sequence...) serves
        // a name through the stdlib ladder or a source extension on its
        // nominal type. Answering false for these let the SAM-candidate arm
        // swallow a bare call that belongs to a DEEPER receiver: inside
        // `asFlow`'s block the collector closure took `forEach`, ran the
        // user's collect action with the forEach action as its element, and
        // the list never iterated.
        if (v.* == .Null or v.* == .Unit) return false;
        if (receiverHasMemberNamed(self, v, name)) return true;
        const nominal = simpleName(valueNominalFqn(v));
        const mg = self.module.borrow();
        defer mg.deinit();
        return @constCast(mg.get()).extCouldApply(allocator, nominal, name, argc);
    }
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    const cls_name = cg.get().name;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (m.registry.hierarchy_methods.get(cls_name)) |methods| {
            if (methods.contains(name)) return true;
        }
        // An anonymous object's class name says nothing; its SUPERTYPES
        // carry the declared members (an `object : Flow<T>` serves
        // `collect` through the interface). Walk the chain so the
        // SAM-candidate arm declines in favor of the real receiver.
        for (cg.get().supertype_names) |sup| {
            const head = supertypeHead(sup);
            if (m.registry.hierarchy_methods.get(head)) |methods| {
                if (methods.contains(name)) return true;
            }
        }
        // extCouldApply rebuilds its lazy index when the func table has
        // grown; VM execution is single-threaded, so the cast is sound.
        if (@constCast(m).extCouldApply(allocator, cls_name, name, argc)) return true;
        for (cg.get().supertype_names) |sup| {
            if (@constCast(m).extCouldApply(allocator, supertypeHead(sup), name, argc)) return true;
        }
    }
    // A runtime-lowered anon object registers its methods in the per-site
    // table, not the class def.
    {
        var mbuf: [96]u8 = undefined;
        if (std.fmt.bufPrint(&mbuf, "{s}/{d}", .{ name, argc })) |mkey| {
            if (lookupAnonMethod(self, allocator, cls_name, mkey, name) != null) return true;
        } else |_| {}
    }
    const def = g.get().class.clone();
    defer def.deinit();
    if (ClassDef.findMethod(def, allocator, name)) |hit| {
        hit.class.deinit();
        return true;
    }
    return false;
}

/// A function-typed property can share its name with a vararg member method
/// (`val createFrom: (Array<out String>) -> T` alongside
/// `fun createFrom(vararg items: String): T = createFrom(items)`). Kotlin
/// resolves `createFrom("a", "b")` (several args) to the vararg method and
/// `createFrom(items)` (one array, matching the property's single parameter)
/// to the property's `invoke`. KLIO dispatches members by name, so the method
/// shadows the property and the method body recurses. When the receiver holds
/// a callable field whose arity matches the call and the class also has a
/// same-named vararg method, invoke the field: the property is the intended
/// target for this argument shape.
/// The declared receiver-type head of a RECEIVER-function-typed property
/// `name` on the receiver's class (or a superclass), or null when the
/// property is not receiver-fn-typed.
/// Per-thread gate for `recvFnPropHeadOf`: most modules declare ZERO
/// receiver-function-typed properties, and the registry is fully populated
/// before any dispatch runs, so one count check per (thread, module) skips
/// the per-call supertype walk entirely. When props DO exist, two bit
/// masks over the declared prop names' (length, first byte) signatures
/// filter the overwhelming majority of member names without hashing —
/// a false positive just runs the walk.
/// One threadlocal, not five. Darwin resolves each `threadlocal` through a
/// `_tlv_get_addr` call, and this gate is inlined into the hottest member
/// dispatch there is: splitting its state across separate variables put one
/// call per variable at every inlined site (measured 250ms -> 2380ms on a
/// compose startup when a fifth was added).
pub const RecvFnGate = struct {
    mod: ?*const Module = null,
    /// The module ADDRESS alone cannot say the answer is current — the next
    /// program in this process can mint a module at the same address — so the
    /// gate also rides the generation the program boundary bumps.
    gen: u32 = 0,
    any: bool = true,
    len_mask: u64 = ~@as(u64, 0),
    byte_mask: u64 = ~@as(u64, 0),
};
pub threadlocal var recv_fn_gate: RecvFnGate = .{};

pub fn recvFnPropsAny(self: *VmHost) bool {
    const mp: *const Module = self.module.asPtr();
    const gate = &recv_fn_gate;
    if (gate.mod == mp and gate.gen == cacheGen()) return gate.any;
    const g = self.module.borrow();
    const reg = &g.get().registry;
    const any = reg.recv_fn_props.count() != 0;
    var lm: u64 = 0;
    var bm: u64 = 0;
    if (any) {
        var it = reg.recv_fn_props.iterator();
        while (it.next()) |e| {
            const pn = e.key_ptr.b;
            if (pn.len == 0) continue;
            lm |= @as(u64, 1) << @intCast(@min(pn.len, 63));
            bm |= @as(u64, 1) << @intCast(pn[0] & 63);
            if (runtime.envOnce("KLIO_RFP_DUMP") != null) {
                std.debug.print("[rfp] {s}.{s}\n", .{ e.key_ptr.a, pn });
            }
        }
    }
    g.deinit();
    gate.len_mask = lm;
    gate.byte_mask = bm;
    gate.mod = mp;
    gate.gen = cacheGen();
    gate.any = any;
    return any;
}

pub fn recvFnPropHeadOf(self: *VmHost, receiver: *const Value, name: []const u8) ?[]const u8 {
    if (receiver.* != .Instance) return null;
    if (!recvFnPropsAny(self)) return null;
    if (name.len == 0) return null;
    const gate = &recv_fn_gate;
    if ((gate.len_mask >> @intCast(@min(name.len, 63))) & 1 == 0) return null;
    if ((gate.byte_mask >> @intCast(name[0] & 63)) & 1 == 0) return null;
    const mg = self.module.borrow();
    defer mg.deinit();
    const reg = &mg.get().registry;
    var cur: ?[]const u8 = blk2: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk2 cg.get().name;
    };
    var hops: usize = 0;
    while (cur) |cn| : (hops += 1) {
        if (hops > 32) break;
        if (reg.recv_fn_props.get(.{ .a = cn, .b = name })) |h| return h;
        const chain = reg.class_super_names.get(cn) orelse break;
        if (chain.len == 0) break;
        var sn = chain[0];
        if (std.mem.findScalarLast(u8, sn, '.')) |i| sn = sn[i + 1 ..];
        cur = sn;
    }
    return null;
}

/// The receiver a stored receiver-typed lambda binds at invocation: the
/// owning instance when it implements the declared head
/// (`scope.handler()` with `handler: Scope.() -> Unit`), else the
/// innermost implicit receiver that does. Null when none is in scope —
/// the property does not apply to this call and the walk must continue
/// (`receiver.block()` inside `kotlin.with` must reach with's own `block`
/// PARAM when the receiver carries a same-named receiver-typed field it
/// cannot satisfy, or the whole `with(node) { … }` body is silently
/// replaced by the field's lambda).
pub fn recvFnReceiverFor(self: *VmHost, allocator: Allocator, receiver: *const Value, head: []const u8) Allocator.Error!?Value {
    if (runtime.envOnce("KLIO_HEAD_TRACE") != null)
        std.debug.print("[recvfn] head={s} passed={s}/{s} implements={} registered={}\n", .{ head, debugClassNameOf(self, receiver), @tagName(receiver.*), receiverImplementsHead(self, receiver, head), headNamesRegisteredClass(self, head) });
    if (head.len == 0 or receiverImplementsHead(self, receiver, head)) return receiver.*;
    // A head that names NO registered class (a bare type parameter --
    // `with`'s `T.()` block) proves nothing about any receiver: the value
    // the invoke supplied stands. Walking the chain here replaced a
    // `with(list)` subject with whatever Instance happened to be enclosing
    // once the subject tower put one there.
    if (!headNamesRegisteredClass(self, head)) return receiver.*;
    const chain = try enclosingThisChain(self, allocator);
    defer allocator.free(chain);
    for (chain) |c| {
        if (c != .Instance) continue;
        if (receiverImplementsHead(self, &c, head)) return c;
    }
    return null;
}

/// Select the innermost implicit receiver satisfying `head`, starting with
/// `receiver` and then walking the frame's enclosing-receiver tower.
pub fn implicitReceiverForHead(self: *VmHost, allocator: Allocator, receiver: *const Value, head: []const u8) Allocator.Error!?Value {
    return recvFnReceiverFor(self, allocator, receiver, head);
}

pub fn recvFnFieldInvoke(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    if (receiver.* != .Instance) return null;
    const head = recvFnPropHeadOf(self, receiver, name) orelse return null;
    runtime.prof.opRoute(7);
    const field_val: Value = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const v = g.get().get(name) orelse return null;
        v.retain();
        break :blk v;
    };
    defer field_val.release(allocator);
    const arity = callableFieldArity(self, &field_val) orelse return null;
    // The call supplies the lambda's receiver POSITIONALLY — one arg more than
    // the lambda declares (`getOrBuildCachedDrawBlock(this).block(this)` for a
    // `ContentDrawScope.() -> Unit` field). Split arg0 off as the receiver here
    // rather than leaning on the invoke path's arity heuristic: the owner need
    // not satisfy the head at all, and a stray `it` must not swallow the
    // receiver.
    if (args.len == arity + 1) {
        return try host_call_value.callValueWithThis(self, allocator, &field_val, &args[0], args[1..], &.{});
    }
    {
        // Receiver-bound form (`scope.handler()`): the lambda's receiver can
        // only be the owner, so a field whose declared receiver type the owner
        // cannot satisfy does not apply here. Decline WITHOUT scanning the
        // dynamic chain, so `receiver.block()` inside a generic function reaches
        // the in-scope callable rather than a same-named field on the runtime
        // receiver.
        if (head.len != 0 and !receiverImplementsHead(self, receiver, head)) return null;
    }
    return try host_call_value.callValueWithThis(self, allocator, &field_val, receiver, args, &.{});
}

pub fn varargShadowedFieldInvoke(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    runtime.prof.opRoute(8);
    if (receiver.* != .Instance) return null;
    const field_val: Value = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const v = g.get().get(name) orelse return null;
        v.retain();
        break :blk v;
    };
    defer field_val.release(allocator);

    const arity = callableFieldArity(self, &field_val) orelse return null;
    if (arity != args.len) return null;

    // Only intervene when a same-named vararg method would otherwise shadow
    // the field; a plain function property keeps its ordinary dispatch.
    const resolved = (try resolveInstanceMethod(self, allocator, receiver, name, args, null)) orelse return null;
    const is_vararg = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const f = mg.get().funcById(resolved.fid) orelse break :blk false;
        break :blk f.params.len > 0 and f.params[f.params.len - 1].is_vararg;
    };
    if (!is_vararg) return null;

    // The property's single parameter is the *packed* array form (e.g.
    // `(Array<out String>) -> T`); invoke it only when the sole argument is
    // actually an array (`createFrom(items)`). A non-array single argument
    // (`createFrom("foo")`) is the vararg-element form and must bind the
    // vararg method, which packs it — invoking the property would pass the
    // element where its body expects an array (then `*it` spreads a scalar).
    if (args.len == 1 and args[0] != .Array) return null;

    return try callValueRec(self, allocator, &field_val, args);
}

/// Named-call flat prepare: replay a cached binding permutation (see
/// `namedOrderKey`) to reorder the arguments into declaration order, then
/// run the ordinary positional prepare on them. This is what lets a NAMED
/// member call run as a pushed activation instead of a recursive host
/// frame — the perm exists only because a prior call of this exact shape
/// bound and dispatched that order, and the positional prepare re-resolves
/// the target from the member cache with the reordered values, declining
/// (to the recursive ladder) on any miss, vararg, or defaulted shape.
pub fn prepareMemberFlatCallNamed(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    args: []const Value,
    arg_names: []const ?[]const u8,
    static_recv: ?[]const u8,
    declared_recv: ?[]const u8,
) Allocator.Error!?ir.eval.FlatCallReq {
    if (receiver.* != .Instance) return null;
    if (args.len > 15) return null;
    const k = namedOrderKey(self, receiver, name, args, arg_names) orelse return null;
    var perm: ?root_mod.ProgramImage.NamedPerm = null;
    const tslot = &caches.tl_perm_cache[tlSlot(k)];
    if (tslot.raw_plus != 0 and tslot.gen == cacheGen() and tslot.class_p == k.class_p and tslot.name_p == k.name_p and
        tslot.sig == k.sig and tslot.n_args == k.n_args)
    {
        perm = tslot.perm;
    } else {
        const shared: ?root_mod.ProgramImage.NamedPerm = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().named_perm_cache.get(k);
        };
        if (shared) |sp| {
            tslot.* = .{ .class_p = k.class_p, .name_p = k.name_p, .n_args = k.n_args, .sig = k.sig, .raw_plus = 1, .gen = cacheGen(), .perm = sp };
            perm = sp;
        }
    }
    const p = perm orelse return null;
    if (p.n == 0xFF) return null;
    var buf: [15]Value = undefined;
    var m: usize = 0;
    while (m < p.n and p.src[m] != 0xFE) : (m += 1) {
        if (p.src[m] >= args.len) return null;
        buf[m] = args[p.src[m]];
    }
    return prepareMemberFlatCall(self, allocator, receiver, name, buf[0..m], static_recv, declared_recv, true);
}

/// Resolve an all-positional member call into a ready flat-call request when
/// the resolved-method (or resolved-extension) cache already names the
/// target and the call is the fully-applied no-vararg shape — the exact
/// calls `invokeMethodFuncId`'s fast path serves. Anything else (a stored
/// field shadowing the name, `copy`, defaults, varargs, a cache miss)
/// returns null and the recursive ladder runs unchanged. Mirrors the ladder
/// up to `invokeMethodFuncId`'s `evalWith` terminal, including the threaded
/// ambient-composer push (undone at activation close via `flatCallClosed`).
pub fn prepareMemberFlatCall(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8, declared_recv: ?[]const u8, allow_ext_cache: bool) Allocator.Error!?ir.eval.FlatCallReq {
    // Persistent-vector contains/indexOf are host-served (the ladder's
    // intercept); a flat-prepared interpreted body would bypass that.
    if (args.len == 1 and receiver.* == .Instance and
        (std.mem.eql(u8, name, "contains") or std.mem.eql(u8, name, "indexOf")) and
        persistent_list_eq.isVectorClass(receiver.Instance))
    {
        return null;
    }
    // Builder removeRange/addAll are host-served the same way.
    if (((args.len == 2 and std.mem.eql(u8, name, "removeRange")) or
        (args.len == 1 and std.mem.eql(u8, name, "addAll"))) and
        receiver.* == .Instance and
        persistent_list_mut.isBuilderClass(receiver.Instance))
    {
        return null;
    }
    // Map-builder put/build are host-served (persistent_map_mut.zig).
    if (((args.len == 2 and std.mem.eql(u8, name, "put")) or
        (args.len == 0 and std.mem.eql(u8, name, "build"))) and
        receiver.* == .Instance and
        persistent_map_mut.isBuilderClass(receiver.Instance))
    {
        return null;
    }
    // `map.builder()` is host-served once the builder template exists.
    if (args.len == 0 and std.mem.eql(u8, name, "builder") and
        receiver.* == .Instance and
        persistent_map_mut.isMapClass(receiver.Instance))
    {
        return null;
    }
    // SnapshotStateMap.put is host-served (whole write cycle).
    if (args.len == 2 and std.mem.eql(u8, name, "put") and
        receiver.* == .Instance and
        persistent_map_mut.isSnapshotMapClass(receiver.Instance))
    {
        return null;
    }
    // `closure.invoke(args…)`: the ladder lands at `callValueRec(receiver,
    // args)` with no closure-specific step before it, so the plain closure
    // invocation flattens identically.
    if (receiver.* == .IrClosure and std.mem.eql(u8, name, "invoke")) {
        return host_call_value.prepareClosureFlatCall(self, allocator, receiver, args);
    }
    if (receiver.* != .Instance) {
        // A non-Instance receiver keyable by identity (scalar, array,
        // closure, Result) flat-serves its cached top-level-extension
        // resolution: the ext cache only fills after every builtin/stdlib
        // arm declined for the same key, so a hit proves the ladder tail —
        // these calls (gap-buffer array accessors, coroutine-boundary
        // closure extensions) otherwise walk the full ladder per call.
        if (!allow_ext_cache) return null;
        const k = instanceMethodKeyScoped(self, receiver, name, args, static_recv, declared_recv) orelse return null;
        const raw = extMethodCacheGet(self, k) orelse return null;
        if (raw == METHOD_MISS) return null;
        return prepareFlatFromFid(self, allocator, receiver, args, @enumFromInt(raw));
    }
    // Data-class `copy` runs before the cache in the ladder; decline so it
    // keeps its precedence.
    if (std.mem.eql(u8, name, "copy")) return null;
    const strict_k = instanceMethodKeyScoped(self, receiver, name, args, static_recv, null);
    const k = strict_k orelse
        (instanceMethodKeyRelaxed(self, receiver, name, args, static_recv) orelse return null);
    var fid: ?FuncId = null;
    if (instanceMethodCacheGetRaw(self, k)) |raw| {
        if (raw != METHOD_MISS) fid = @enumFromInt(raw);
    }
    // A member-cache hit needs no stored-field shadow scan: when the walk
    // filled the entry the ladder's field arms had declined this key, a
    // vararg pick declines below (so `varargShadowedFieldInvoke` keeps its
    // claim through the recursive path), and Kotlin resolves a member
    // function ahead of any property/field-invoke convention anyway. The
    // scan still guards the ext-cache branch — a member field outranks a
    // top-level extension.
    if (fid == null) {
        {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            if (g.get().get(name) != null) return null;
        }
        // Same owner-independence guards the ext cache was populated under
        // (and the strict/members-only probes never consult it). A
        // scope-directed call probes under its scope-FOLDED key — the same
        // key `extensionFnFallback` caches it under, so it can only be
        // served what its own resolution stored. The RELAXED member key
        // never touches the extension caches.
        if (allow_ext_cache and static_recv == null and declared_recv == null) {
            if (strict_k) |sk| {
                if (extMethodCacheGet(self, sk)) |raw| {
                    if (raw != METHOD_MISS) fid = @enumFromInt(raw);
                }
            }
        } else if (allow_ext_cache) {
            if (instanceMethodKeyScoped(self, receiver, name, args, static_recv, declared_recv)) |k2| {
                if (extMethodCacheGet(self, k2)) |raw| {
                    if (raw != METHOD_MISS) fid = @enumFromInt(raw);
                }
            }
        }
    }
    const target = fid orelse return null;
    return prepareFlatFromFid(self, allocator, receiver, args, target);
}

/// Shared flat-request tail: resolve `target`, admit only the fully-applied
/// no-vararg shape, and build the `[receiver] ++ args` frame vector with the
/// threaded-composer push the recursive invoker would perform.
/// Whether the receiver's type declares a member of `name`, for ANY
/// receiver kind. `hostHasMember` answers only for interpreted Instances;
/// a HOST container (`.List`, `.Map`, a scalar) dispatches its members
/// through the FQN-keyed host table, so probe that table under the value's
/// nominal type and its builtin supertypes. The member-first guards lean
/// on this: with the Instance-only test they were blind to exactly the
/// receivers the `contains` self-loop runs on.
pub fn receiverHasMemberNamed(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    if (receiver.* == .Instance) return hostHasMember(self, receiver, name);
    var buf: [192]u8 = undefined;
    const nominal = valueNominalFqn(receiver);
    if (std.fmt.bufPrint(&buf, "{s}.{s}", .{ nominal, name })) |fqn| {
        if (lookupIntrinsic(self, fqn) != null) return true;
    } else |_| {}
    const simple = simpleName(nominal);
    for (applicability.builtinSupersOf(simple)) |sup| {
        if (std.fmt.bufPrint(&buf, "kotlin.collections.{s}.{s}", .{ sup, name })) |fqn| {
            if (lookupIntrinsic(self, fqn) != null) return true;
        } else |_| {}
        if (std.fmt.bufPrint(&buf, "kotlin.{s}.{s}", .{ sup, name })) |fqn| {
            if (lookupIntrinsic(self, fqn) != null) return true;
        } else |_| {}
    }
    return false;
}

/// A cached by-name extension resolution must never serve the frame that
/// is currently EXECUTING it: the bare call inside `Iterable.contains`'s
/// own body hitting the same (receiver-class, name, argc) key as the call
/// that entered it is an unconditional self-loop, and kotlinc resolves
/// that inner call to the receiver's member. Skipping the serve falls
/// down the ladder to the member probes.
pub fn cacheServesExecutingFrame(raw_fid: u32) bool {
    const cf = ir.eval.currentFrameFunc() orelse return false;
    return cf.id.int() == raw_fid;
}

pub fn prepareFlatFromFid(self: *VmHost, allocator: Allocator, receiver: *const Value, args: []const Value, target: FuncId) Allocator.Error!?ir.eval.FlatCallReq {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const f = mod.funcById(target) orelse return null;
    // The fast fully-applied shape only: no vararg anywhere, no default
    // padding, no trailing-lambda rebind.
    for (f.params) |*p| {
        if (p.is_vararg) return null;
    }
    if (args.len + 1 < f.params.len) return null;
    if (nuTraceEnv()) |want| {
        if (std.mem.eql(u8, want, f.name)) {
            std.debug.print("[invoke-method] {s}#{d} params={d} recv={s} FLAT\n", .{ f.fqn, target.int(), f.params.len, receiver.typeFqn() });
        }
    }
    var list = try ir.eval.acquireArgsCap(allocator, args.len + 1);
    list.appendAssumeCapacity(receiver.*);
    list.appendSliceAssumeCapacity(args);
    if (trace.invariantsEnabled()) {
        checkFuncInRange(self, "irMethodWalk", f.id);
        checkReceiverChain(self, allocator, "irMethodWalk", receiver, null);
    }
    vmhost.emitPath(allocator, "member_ir_walk", f.fqn, f.id, receiver, args);
    const threaded: ?Value = compose.threadedComposerArg(f.params, args);
    if (threaded) |c| compose.pushComposer(c);
    return .{
        .func = f,
        .run_module = mod,
        .args = list,
        .composer_pushed = threaded != null,
        .dst = undefined,
    };
}

/// `KLIO_VFLAT_TRACE=1` — one line per declined virtual flat prepare, with
/// the reason, for diagnosing why a slot population stays recursive.
pub var vflat_trace_cached: ?bool = null;
pub fn vflatTraceOn() bool {
    if (vflat_trace_cached) |b| return b;
    const b = runtime.envOnce("KLIO_VFLAT_TRACE") != null;
    vflat_trace_cached = b;
    return b;
}

/// Argument-type signature for a CallMember instruction-site memo: the same
/// strict primitive/identity fold the (class, name, sig) method cache keys
/// under, so a site replay can never serve an overload the cache would have
/// discriminated. Null = an unfingerprintable run; the site must not claim.
pub fn memberSiteSig(self: *VmHost, args: []const Value) ?u64 {
    // A zero-arg run has exactly one signature; skip the hash entirely —
    // `next()`/`hasNext()` style calls dominate the replay population.
    if (args.len == 0) return 2;
    const sig = methodArgSig(self, args) orelse return null;
    return if (sig == 0) 1 else sig;
}

/// Host-serve kinds a CallMember instruction-site memo can claim: route
/// word bit0 = 0, kind in the remaining bits (the flat-target form keeps
/// bit0 = 1 with the FuncId above it). The claimed class identity plus the
/// serve's own shape validation make a stale claim a safe bail.
pub const HostServeKind = enum(u32) {
    map_put = 1,
    map_build = 2,
    snapshot_map_put = 3,
};

/// Probe a (receiver, name, args) run for a host member serve at the
/// CallMember exec site, BEFORE the ladder entry: on a hit the value is
/// served and the kind returned so the site memo can claim the route.
pub fn hostMemberServeProbe(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    args: []const Value,
) Allocator.Error!?struct { kind: u32, val: Value } {
    if (receiver.* != .Instance) return null;
    if (args.len == 2 and std.mem.eql(u8, name, "put") and
        persistent_map_mut.isBuilderClass(receiver.Instance))
    {
        if (try persistent_map_mut.tryPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
            return .{ .kind = @intFromEnum(HostServeKind.map_put), .val = v };
        }
        return null;
    }
    if (args.len == 0 and std.mem.eql(u8, name, "build") and
        persistent_map_mut.isBuilderClass(receiver.Instance))
    {
        if (try persistent_map_mut.tryBuild(self, allocator, receiver.Instance)) |v| {
            return .{ .kind = @intFromEnum(HostServeKind.map_build), .val = v };
        }
        return null;
    }
    if (args.len == 2 and std.mem.eql(u8, name, "put") and
        persistent_map_mut.isSnapshotMapClass(receiver.Instance))
    {
        if (try persistent_map_mut.trySnapshotMapPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
            return .{ .kind = @intFromEnum(HostServeKind.snapshot_map_put), .val = v };
        }
        return null;
    }
    return null;
}

/// Replay a site-claimed host-serve kind. Any shape surprise returns null
/// and the call falls back to the full dispatch path.
pub fn hostMemberServeKind(
    self: *VmHost,
    allocator: Allocator,
    kind: u32,
    receiver: *const Value,
    args: []const Value,
) Allocator.Error!?Value {
    if (receiver.* != .Instance) return null;
    switch (kind) {
        @intFromEnum(HostServeKind.map_put) => {
            if (args.len != 2 or !persistent_map_mut.isBuilderClass(receiver.Instance)) return null;
            return persistent_map_mut.tryPut(self, allocator, receiver.Instance, &args[0], &args[1]);
        },
        @intFromEnum(HostServeKind.map_build) => {
            if (args.len != 0 or !persistent_map_mut.isBuilderClass(receiver.Instance)) return null;
            return persistent_map_mut.tryBuild(self, allocator, receiver.Instance);
        },
        @intFromEnum(HostServeKind.snapshot_map_put) => {
            if (args.len != 2 or !persistent_map_mut.isSnapshotMapClass(receiver.Instance)) return null;
            return persistent_map_mut.trySnapshotMapPut(self, allocator, receiver.Instance, &args[0], &args[1]);
        },
        else => return null,
    }
}

/// Replay a CallMember site memo's claimed target as a flat call. A stored
/// same-named instance field outranks a cached top-level extension (and an
/// invoke-convention callable can shadow), so the presence of one declines
/// to the full by-name path, exactly as the by-name prepare does.
pub fn prepareMemberFlatFromFid(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    args: []const Value,
    target: FuncId,
) Allocator.Error!?ir.eval.FlatCallReq {
    if (receiver.* == .Instance) {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        if (g.get().get(name) != null) return null;
    }
    return prepareFlatFromFid(self, allocator, receiver, args, target);
}

/// Flat-serve a bound virtual slot: resolve it against the receiver's class
/// exactly as `invokeVirtualMember`'s main path does, admitting only the
/// shape whose recursive serve would be a plain `[receiver] ++ args` frame —
/// a named main-module receiver class whose slot entry is an executable
/// interpreted body. Anonymous receivers (intrinsic shadowing, SAM targets,
/// name-ladder fallbacks), runtime-defined classes, and unlinked or bodyless
/// entries all decline to the recursive invoker unchanged.

pub fn slotNameForTrace(self: *VmHost, slot: MethodSlotId) []const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    const f = mg.get().funcById(FuncId.from(slot.int())) orelse return "?";
    return f.name;
}

pub fn prepareVirtualFlatCall(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    slot: MethodSlotId,
    args: []const Value,
) Allocator.Error!?ir.eval.FlatCallReq {
    const vtrace = vflatTraceOn();
    if (args.len == 1 and receiver.* == .Instance) {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vn| {
            if (bridgeForReceiver(self, receiver, vn, args) != null) return null;
        }
    }
    // Persistent-vector contains/indexOf are host-served (the
    // invokeVirtualMember intercept); a flat-prepared interpreted body
    // would bypass that.
    if (args.len == 1 and receiver.* == .Instance and
        persistent_list_eq.isVectorClass(receiver.Instance))
    {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vn| {
            if (std.mem.eql(u8, vn, "contains") or std.mem.eql(u8, vn, "indexOf")) return null;
        }
    }
    // Builder removeRange/addAll are host-served the same way.
    if ((args.len == 1 or args.len == 2) and receiver.* == .Instance and
        persistent_list_mut.isBuilderClass(receiver.Instance))
    {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vn| {
            if (args.len == 2 and std.mem.eql(u8, vn, "removeRange")) return null;
            if (args.len == 1 and std.mem.eql(u8, vn, "addAll")) return null;
        }
    }
    // Map-builder put/build/builder are host-served (persistent_map_mut.zig).
    if ((args.len == 0 or args.len == 2) and receiver.* == .Instance and
        (persistent_map_mut.isBuilderClass(receiver.Instance) or
            persistent_map_mut.isMapClass(receiver.Instance)))
    {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vn| {
            if (args.len == 2 and std.mem.eql(u8, vn, "put")) return null;
            if (args.len == 0 and (std.mem.eql(u8, vn, "build") or std.mem.eql(u8, vn, "builder"))) return null;
        }
    }
    // SnapshotStateMap.put is host-served (whole write cycle).
    if (args.len == 2 and receiver.* == .Instance and
        persistent_map_mut.isSnapshotMapClass(receiver.Instance))
    {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vn| {
            if (std.mem.eql(u8, vn, "put")) return null;
        }
    }
    if (receiver.* != .Instance) {
        if (vtrace) {
            const nm = virtualSlotInterfaceMember(self, slot) orelse slotNameForTrace(self, slot);
            std.debug.print("[vflat] decline non-instance {s} name={s}\n", .{ @tagName(std.meta.activeTag(receiver.*)), nm });
        }
        return null;
    }
    // A delegating receiver re-decides an interface-declared slot (see
    // `invokeVirtualMember`); decline so the call takes that route.
    if (virtualSlotInterfaceMember(self, slot)) |name| {
        if (interfaceDelegateFor(self, allocator, receiver.Instance, name) != null) {
            if (vtrace) std.debug.print("[vflat] decline delegated {s}\n", .{name});
            return null;
        }
    }
    const target = blk: {
        const instance = receiver.Instance.borrow();
        defer instance.deinit();
        const class = instance.get().class.borrow();
        defer class.deinit();
        if (class.get().is_anonymous) {
            if (vtrace) std.debug.print("[vflat] decline anon {s}\n", .{class.get().fqn});
            return null;
        }
        const mg = self.module.borrow();
        defer mg.deinit();
        const module = mg.get();
        const runtime_class = cid: {
            // Replay the class's resolved-id memo before the string-keyed
            // registry probe (see `ClassDef.resolve_mod`).
            const cdef = class.get();
            const mod_key = @intFromPtr(module);
            if (cdef.resolve_mod.load(.monotonic) == mod_key) {
                const plus1 = cdef.resolve_cid.load(.acquire);
                if (plus1 != 0) break :cid ir.ClassId.from(plus1 - 1);
            }
            const found = module.classIdByFqn(cdef.fqn) orelse {
                if (vtrace) std.debug.print("[vflat] decline no-classid {s}\n", .{cdef.fqn});
                return null;
            };
            const mut = @constCast(cdef);
            if (mut.resolve_mod.cmpxchgStrong(0, mod_key, .acq_rel, .monotonic) == null) {
                mut.resolve_cid.store(found.int() + 1, .release);
            }
            break :cid found;
        };
        const t = module.methodSlotTarget(runtime_class, slot) orelse {
            if (vtrace) std.debug.print("[vflat] decline no-slot-target {s} slot={d}\n", .{ class.get().fqn, slot.int() });
            return null;
        };
        if (!virtualTargetExecutable(module, t)) {
            if (vtrace) std.debug.print("[vflat] decline not-executable {s}\n", .{class.get().fqn});
            return null;
        }
        // A barrier member whose argument fails the type-safe bridge check
        // must not flat-enter the body; the recursive path answers the
        // bridge default.
        if (module.funcById(FuncId.from(slot.int()))) |rootf| {
            if (barrierSpec(rootf.name)) |kind| {
                if (typeSafeBarrierAnswer(self, module, t, kind, args) != null) {
                    if (vtrace) std.debug.print("[vflat] decline barrier {s}\n", .{rootf.name});
                    return null;
                }
            }
        }
        break :blk t;
    };
    const req = try prepareFlatFromFid(self, allocator, receiver, args, target);
    if (vtrace and req == null) std.debug.print("[vflat] decline shape fid={d}\n", .{target.int()});
    return req;
}

/// Flat-serve a lowering-resolved plain member. Member extensions need their
/// declaring class's `this` seeded as an enclosing receiver, and a bodyless
/// declaration runs as its linked host symbol; both keep the recursive path.
pub fn prepareResolvedFlatCall(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    fid: FuncId,
    args: []const Value,
) Allocator.Error!?ir.eval.FlatCallReq {
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const module = mg.get();
        if (isMemberExt(module, fid)) return null;
        const f = funcAt(module, fid) orelse return null;
        if (!f.hasBody()) return null;
    }
    // A delegating receiver re-decides an interface-declared target (see
    // `invokeResolvedMember`); decline so the call takes that route.
    if (receiver.* == .Instance) {
        if (resolvedMemberName(self, fid)) |name| {
            if (interfaceDelegateFor(self, allocator, receiver.Instance, name) != null) return null;
        }
    }
    return prepareFlatFromFid(self, allocator, receiver, args, fid);
}

pub var route_trace_init: bool = false;
pub var route_trace_val: ?[]const u8 = null;
pub fn routeTraceOn(name: []const u8) bool {
    if (!route_trace_init) {
        route_trace_val = if (std.c.getenv("KLIO_ROUTE")) |w| std.mem.span(w) else null;
        route_trace_init = true;
    }
    const w = route_trace_val orelse return false;
    return std.mem.eql(u8, w, name);
}

/// A resolution the intrinsic member dispatch already settled for a BUILTIN
/// receiver, answered before the probe ladder runs.
///
/// `stdlibMemberDispatch` memoizes the winning intrinsic per (receiver type,
/// name, arity-is-zero) — but it sits far down the ladder, so every
/// `Array.copyInto` / `Int.coerceAtMost` in a loop re-walked the arms above it
/// to reach an answer that was already known. An entry exists only for a pair
/// whose earlier arms declined once and whose resolution was judged cacheable
/// (no user extension shadows it), so replaying it changes nothing but the
/// path taken. Instance receivers keep the full walk: their arms consult the
/// class hierarchy, which the earlier method caches already cover.
pub fn builtinIntrinsicReplay(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const name_p = memberNameIdentity(self, name) orelse return null;
    const key: root_mod.ProgramImage.MemberResolveKey = .{
        .type_p = @intFromPtr(receiver.typeFqn().ptr),
        .name_p = name_p,
        .args_empty = args.len == 0,
    };
    const e = &caches.tl_resolve_cache[tlResolveSlot(key)];
    if (e.state == 2 and e.gen == cacheGen() and e.type_p == key.type_p and e.name_p == key.name_p and e.args_empty == key.args_empty) {
        return try dispatchWithReceiver(self, allocator, e.fqn, e.func.?, receiver, args);
    }
    return null;
}

/// How many named member calls the builtin intrinsic REPLAY serves outright,
/// versus reaching the probe ladder proper. `member_ladder` counts the route,
/// not the work, so the two are not the same number.
pub var replay_hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn replayHits() u64 {
    return replay_hits.load(.monotonic);
}
