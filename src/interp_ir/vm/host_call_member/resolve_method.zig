//! Method resolution: picking the instance method a member site names, and the
//! runtime virtual-target links behind a resolved slot.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const host_call_func = @import("../host_call_func.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const MethodSlotId = ir.MethodSlotId;
const EvalResult = ir.eval.EvalResult;

const applicability_probe = @import("applicability_probe.zig");
const argsRelaxedAdjudicable = applicability_probe.argsRelaxedAdjudicable;
const invokeMemberExtFuncId = applicability_probe.invokeMemberExtFuncId;
const pickArityForced = applicability_probe.pickArityForced;
const pickMethodOverload = applicability_probe.pickMethodOverload;
const receiverDefinitelyNotParam = applicability_probe.receiverDefinitelyNotParam;

const binding_probe = @import("binding_probe.zig");
const receiverClassChain = binding_probe.receiverClassChain;

const caches = @import("caches.zig");
const resolvedMemberName = caches.resolvedMemberName;

const flat_call = @import("flat_call.zig");
const prependReceiver = flat_call.prependReceiver;

const hcm = @import("../host_call_member.zig");
const callFuncNamedRec = hcm.callFuncNamedRec;
const callMemberRec = hcm.callMemberRec;
const simpleName = hcm.simpleName;

const member_ext_visibility = @import("member_ext_visibility.zig");
const interfaceDelegateFor = member_ext_visibility.interfaceDelegateFor;
const isMemberExt = member_ext_visibility.isMemberExt;

const receiver_probe = @import("receiver_probe.zig");
const allUppercase = receiver_probe.allUppercase;
const candidateArgsDisproven = receiver_probe.candidateArgsDisproven;
const isCallable = receiver_probe.isCallable;
const receiverImplementsHead = receiver_probe.receiverImplementsHead;

const reflect_anon = @import("reflect_anon.zig");
const AnonMethodEntry = reflect_anon.AnonMethodEntry;
const ResolvedMethod = reflect_anon.ResolvedMethod;
const funcAt = reflect_anon.funcAt;
const invokeAnonMethod = reflect_anon.invokeAnonMethod;
const lookupAnonMethodExact = reflect_anon.lookupAnonMethodExact;
const root_mod = reflect_anon.root_mod;

const static_tail = @import("static_tail.zig");
const freeDispatchMiss = static_tail.freeDispatchMiss;
const missTraceWant = static_tail.missTraceWant;

const virtual_tail = @import("virtual_tail.zig");
const invokeMethodFuncId = virtual_tail.invokeMethodFuncId;

/// Resolve `receiver.name(args)` to the user method `FuncId` it would dispatch,
/// or null for a non-`Instance` receiver or a name that resolves to an intrinsic
/// / extension / unresolved member. The loop JIT calls this at compile time to
/// learn a trampolined member call's return type; the call still dispatches
/// through normal member resolution at run time, so this never changes behavior.
/// Member methods take precedence over extensions in Kotlin, so a resolved member
/// is also what runs — its (override-invariant, for a scalar) return type is sound.
pub fn resolveMemberFuncId(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) ?FuncId {
    if (receiver.* != .Instance) return null;
    const rm = resolveInstanceMethod(self, allocator, receiver, name, args, null) catch return null;
    return if (rm) |m| m.fid else null;
}

/// Walk the receiver's class hierarchy resolving `name` to a user method
/// `FuncId`. `unambiguous` is set when the resolving class had exactly one
/// method of that name (so the choice does not depend on argument types and the
/// resolution may be cached for the inline dispatch cache).
/// A function/lambda argument bound to a member parameter typed as a bare
/// type-parameter (`value: T`) matches only because the receiver's type
/// argument is erased. When a same-name extension applicable to this receiver
/// takes that argument as a concrete function type, it is the more specific —
/// and in Kotlin the only applicable — overload (the member's `T` is the
/// receiver's non-function type argument, e.g. `CancellableContinuation<Unit>`,
/// which a function does not satisfy). Defer the member to it. Example:
/// `cont.tryResume(onCancellation)` must bind the `Boolean`-returning extension
/// `CancellableContinuation<Unit>.tryResume(onCancellation)`, not the member
/// `tryResume(value: T): Any?`.
/// Kotlin drops a member overload whose declared value-parameter types
/// PROVABLY reject the call's arguments, and a top-level extension
/// namesake binds instead: `builder.putAll(pairsArray)` inside the
/// stdlib `plusAssign` — the builder's member takes a `Map`, the stdlib
/// extension takes the `Array<out Pair>`. Only a definite per-arg
/// disproof WITH a surviving same-arity extension declines the member,
/// so erased/unknown argument shapes keep the member-first order.
pub fn memberArgsDisprovenExtensionApplies(self: *VmHost, mod: *const Module, name: []const u8, member: *const Func, args: []const Value) bool {
    if (!candidateArgsDisproven(self, member, args)) return false;
    for (mod.funcsBySimpleName(name)) |fid| {
        const cand = funcAt(mod, fid) orelse continue;
        if (cand.params.len != args.len + 1) continue;
        if (cand.params.len == 0 or !std.mem.eql(u8, cand.params[0].name, "this")) continue;
        if (isMemberExt(mod, fid)) continue;
        if (cand.low_priority) continue;
        if (candidateArgsDisproven(self, &cand, args)) continue;
        return true;
    }
    return false;
}

pub fn callableArgPrefersFunctionExtension(self: *VmHost, mod: *const Module, name: []const u8, member: *const Func, receiver: *const Value, args: []const Value) bool {
    const mskip: usize = if (member.params.len > 0 and std.mem.eql(u8, member.params[0].name, "this")) 1 else 0;
    var fn_arg_pos: ?usize = null;
    for (args, 0..) |*a, i| {
        // A function value, or a null where a (nullable) function is expected,
        // is the kind of argument the extension takes concretely.
        const fn_shaped = isCallable(a) or a.* == .Null;
        if (!fn_shaped) continue;
        const pi = mskip + i;
        if (pi >= member.params.len) continue;
        const mp = member.params[pi].ty;
        if (std.mem.startsWith(u8, mp.name, "Function")) return false; // member already takes a function here
        // The member binds this argument only through a bare type-parameter
        // slot (`value: T`) — it is the receiver's erased, non-function type
        // argument, which a function/null does not satisfy.
        if (mp.name.len <= 2 and allUppercase(mp.name)) fn_arg_pos = i;
    }
    const want_pos = fn_arg_pos orelse return false;

    const recv_chain = receiverClassChain(self, self.allocator, receiver.Instance) catch return false;
    defer @constCast(&recv_chain).deinit();

    for (mod.funcsBySimpleName(name)) |fid| {
        const ef = funcAt(mod, fid) orelse continue;
        if (ef.kind != .top_level_extension and ef.kind != .member_extension) continue;
        if (ef.params.len == 0) continue;
        const rt = ef.params[0].ty.name; // extension receiver type
        const recv_ok = recv_chain.contains(rt) or std.mem.eql(u8, rt, "Any") or (rt.len <= 2 and allUppercase(rt));
        if (!recv_ok) continue;
        const epi = 1 + want_pos; // skip the extension's `this`
        if (epi >= ef.params.len) continue;
        if (std.mem.startsWith(u8, ef.params[epi].ty.name, "Function")) return true;
    }
    return false;
}

/// The count of a function's OWN (method-level) type parameters. A subtype's
/// same-name overload that introduces its own type parameters (`get<T>(Key<T>)`
/// shadowing `Map.get(K)`) is the shape the static-receiver visibility filter
/// targets; a plain non-generic member is left alone.
pub fn funcTypeParamCount(self: *VmHost, fid: FuncId) usize {
    const mg = self.module.borrow();
    defer mg.deinit();
    const tps = mg.get().registry.func_type_params.get(fid) orelse return 0;
    return tps.items.len;
}

/// The IR class id in `receiver`'s runtime hierarchy whose simple name matches
/// the static receiver-type head `want`, or null when the static type is not a
/// nominal class in the hierarchy.
pub fn findClassInHierarchy(self: *VmHost, allocator: Allocator, receiver: *const Value, want: []const u8) Allocator.Error!?ir.ClassId {
    if (receiver.* != .Instance) return null;
    var recv_fqn: []const u8 = undefined;
    var class_name: []const u8 = undefined;
    {
        const g = receiver.Instance.borrow();
        const cg = g.get().class.borrow();
        class_name = cg.get().name;
        recv_fqn = cg.get().fqn;
        cg.deinit();
        g.deinit();
    }
    const WalkItem = struct { cid: ?ir.ClassId, name: []const u8, hint: []const u8 = "" };
    var queue: std.ArrayList(WalkItem) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    const start_cid: ?ir.ClassId = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classIdByFqn(recv_fqn);
    };
    try queue.append(allocator, .{ .cid = start_cid, .name = class_name });
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const item = queue.items[head];
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        var ir_class: ?ir.Class = null;
        var cid_of: ?ir.ClassId = item.cid;
        if (item.cid) |cid| {
            if (@intFromEnum(cid) < mod.classes.items.len) ir_class = mod.classes.items[@intFromEnum(cid)];
        }
        if (ir_class == null) {
            if (classByNamePreferring(mod, item.name, item.hint)) |hit| {
                ir_class = hit.cls;
                cid_of = hit.cid;
            }
        }
        const irc = ir_class orelse continue;
        if (seen.contains(irc.fqn)) continue;
        try seen.put(irc.fqn, {});
        if (std.mem.eql(u8, simpleName(irc.name), want) or std.mem.eql(u8, simpleName(irc.fqn), want))
            return cid_of;
        for (irc.supertypes) |sid| {
            if (@intFromEnum(sid) < mod.classes.items.len) {
                try queue.append(allocator, .{ .cid = sid, .name = mod.classes.items[@intFromEnum(sid)].name });
            }
        }
    }
    return null;
}

/// The set of class FQNs at or ABOVE `start_cid` in the class hierarchy: the
/// static receiver type and every supertype it inherits from. A member declared
/// on one of these is visible from the static receiver type; a member declared
/// on any OTHER class in the runtime receiver's hierarchy is a proper-descendant
/// member, invisible from the static type unless it overrides a visible one.
pub fn ancestorClosureFqns(self: *VmHost, allocator: Allocator, start_cid: ir.ClassId, out: *std.StringHashMap(void)) Allocator.Error!void {
    var queue: std.ArrayList(ir.ClassId) = .empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, start_cid);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cid = queue.items[head];
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (@intFromEnum(cid) >= mod.classes.items.len) continue;
        const irc = mod.classes.items[@intFromEnum(cid)];
        if (out.contains(irc.fqn)) continue;
        try out.put(irc.fqn, {});
        for (irc.supertypes) |sid| try queue.append(allocator, sid);
    }
}

pub fn isOperatorConventionName(name: []const u8) bool {
    const ops = [_][]const u8{ "plus", "minus", "times", "div", "rem", "get", "set", "contains", "rangeTo", "rangeUntil", "compareTo", "inc", "dec", "unaryPlus", "unaryMinus", "not", "invoke" };
    for (ops) |o| {
        if (std.mem.eql(u8, name, o)) return true;
    }
    return false;
}

pub fn staticIsInterface(mod: *const Module, cid: ir.ClassId) bool {
    if (@intFromEnum(cid) >= mod.classes.items.len) return false;
    return mod.classes.items[@intFromEnum(cid)].is_interface;
}

/// Whether the static receiver type's transitive member-name set contains
/// `name`, via the build-time `hierarchy_methods` registry. No registry
/// entry answers true, keeping the exclusion conservative.
pub fn closureHasMethodNamed(mod: *const Module, start_cid: ir.ClassId, name: []const u8) bool {
    // `Any`'s members are visible from every static type; the interface
    // registry sets do not record them.
    if (std.mem.eql(u8, name, "equals") or std.mem.eql(u8, name, "hashCode") or std.mem.eql(u8, name, "toString")) return true;
    if (@intFromEnum(start_cid) >= mod.classes.items.len) return true;
    const irc = mod.classes.items[@intFromEnum(start_cid)];
    const hm = mod.registry.hierarchy_methods.get(irc.fqn) orelse
        mod.registry.hierarchy_methods.get(irc.name) orelse
        mod.registry.hierarchy_methods.get(simpleName(irc.fqn)) orelse return true;
    return hm.contains(name);
}

/// Resolve a supertype recorded by SIMPLE NAME, preferring the candidate
/// whose fqn shares the longest dotted prefix with `hint_fqn` — the class
/// that recorded the name. Two packs both declare a `Segment`
/// (kotlinx.coroutines.internal and kotlinx.io); `ChannelSegment`'s parent
/// is the one beside it, and first-match-wins walked the wrong hierarchy.
pub const ClassByNameHit = struct { cls: ir.Class, cid: ir.ClassId };

pub fn classByNamePreferring(mod: *const Module, want: []const u8, hint_fqn: []const u8) ?ClassByNameHit {
    var best: ?ClassByNameHit = null;
    var best_score: usize = 0;
    for (mod.classes.items, 0..) |c, i| {
        if (!std.mem.eql(u8, c.name, want)) continue;
        var score: usize = 0;
        const n = @min(c.fqn.len, hint_fqn.len);
        while (score < n and c.fqn[score] == hint_fqn[score]) : (score += 1) {}
        if (best == null or score > best_score) {
            best = .{ .cls = c, .cid = @enumFromInt(i) };
            best_score = score;
        }
    }
    return best;
}

/// Whether the static receiver type `start_cid` (or one of its supertypes)
/// declares a method named `name` with exactly `tvc` OWN type parameters. A
/// generic same-name method a runtime subtype introduces is a legitimate
/// OVERRIDE only when the static type's own scope declares a generic member of
/// the same shape; otherwise it is a subtype-only overload (it may even carry
/// the `override` modifier for a DIFFERENT interface not visible from the static
/// type — `PersistentCompositionLocalHashMap.get<T>` overrides `CompositionLocalMap`,
/// not `Map`), and must not shadow the statically-bound member.
pub fn closureHasGenericMethod(self: *VmHost, allocator: Allocator, start_cid: ir.ClassId, name: []const u8, tvc: usize) Allocator.Error!bool {
    var queue: std.ArrayList(ir.ClassId) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    try queue.append(allocator, start_cid);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cid = queue.items[head];
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (@intFromEnum(cid) >= mod.classes.items.len) continue;
        const irc = mod.classes.items[@intFromEnum(cid)];
        if (seen.contains(irc.fqn)) continue;
        try seen.put(irc.fqn, {});
        for (irc.methods) |fid| {
            if (funcAt(mod, fid)) |f| {
                if (std.mem.eql(u8, f.name, name) and funcTypeParamCount(self, fid) == tvc) return true;
            }
        }
        // An interface's ABSTRACT member lowers no method fid, but its
        // declared header is registered — without this, a runtime override
        // of `operator fun <T> get(key: Key<T>)` on an interface-typed
        // receiver was excluded as a subtype-only generic and the walk fell
        // through to a delegated `Map.get` (the CompositionLocalMap read).
        for (mod.memberDecls(irc.fqn, name)) |fid| {
            if (funcTypeParamCount(self, fid) == tvc) return true;
        }
        for (irc.supertypes) |sid| try queue.append(allocator, sid);
    }
    return false;
}

pub fn resolveInstanceMethod(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8) Allocator.Error!?ResolvedMethod {
    const inst = receiver.Instance;
    // When the call carries a static receiver type (an implicit-`this` /
    // inline-spliced own-member call), Kotlin resolves it against that static
    // type's member scope. A candidate a runtime subtype introduces that is NOT
    // an override of a member visible from the static type is out of scope and
    // must not shadow the statically-bound member. Compute the static type's
    // ancestor closure so the walk can exclude such proper-descendant, non-
    // override candidates. `Map.getOrElse`'s inlined `get(key)` binds `Map.get`,
    // never a `CLMap: MapBase` receiver's own `get<T>(Key<T>)` (which self-recurses).
    var static_up: std.StringHashMap(void) = .init(allocator);
    defer static_up.deinit();
    var static_up_ready = false;
    var static_cid: ir.ClassId = undefined;
    if (static_recv) |sr| {
        const want = std.mem.trimEnd(u8, simpleName(sr), "?");
        if (try findClassInHierarchy(self, allocator, receiver, want)) |s_cid| {
            try ancestorClosureFqns(self, allocator, s_cid, &static_up);
            static_cid = s_cid;
            static_up_ready = true;
        }
    }
    var class_name: []const u8 = undefined;
    var recv_fqn: []const u8 = undefined;
    var local_runtime = false;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        class_name = cg.get().name;
        recv_fqn = cg.get().fqn;
        local_runtime = cg.get().is_local_runtime;
        cg.deinit();
        g.deinit();
    }
    // The best fit found so far that needed DEFAULTS to bind; used only when
    // the walk finds no exact-arity candidate anywhere in the hierarchy.
    var defaulted_hit: ?ResolvedMethod = null;
    // `runtime_only`: a class registered at run time (a local class) has no
    // IR row, and its name may coincide with a module class (`class B`
    // declared inside `B.foo`), so it is never resolved through the index;
    // the walk continues from its runtime ClassDef's supertypes.
    const WalkItem = struct { cid: ?ir.ClassId, name: []const u8, hint: []const u8 = "", runtime_only: bool = false };
    var queue: std.ArrayList(WalkItem) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    // Start from the receiver's ACTUAL class identity — its IR class id keyed
    // by exact FQN — so a same-simple-name class in another package can never
    // shadow it. The hierarchy is then walked by identity (each class's
    // resolved supertype ids), never re-resolved from a collidable simple name.
    const start_cid: ?ir.ClassId = blk: {
        if (local_runtime) break :blk null;
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classIdByFqn(recv_fqn);
    };
    try queue.append(allocator, .{ .cid = start_cid, .name = class_name, .runtime_only = local_runtime });
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const item = queue.items[head];
        // Resolve the IR class by identity (its id) when known; a
        // synthesized/anonymous shape with no unambiguous id falls back to a
        // simple-name match.
        var ir_class: ?ir.Class = null;
        var cur_name: []const u8 = item.name;
        {
            const mg = self.module.borrow();
            defer mg.deinit();
            const mod = mg.get();
            if (item.cid) |cid| {
                if (@intFromEnum(cid) < mod.classes.items.len) ir_class = mod.classes.items[@intFromEnum(cid)];
            }
            if (ir_class == null and !item.runtime_only) {
                if (classByNamePreferring(mod, cur_name, item.hint)) |hit| {
                    ir_class = hit.cls;
                }
            }
            // Dedup on the resolved class's FQN (identity) so two distinct
            // classes that share a simple name are each walked once.
            const dedup_key = if (ir_class) |irc| irc.fqn else cur_name;
            if (seen.contains(dedup_key)) continue;
            try seen.put(dedup_key, {});
            if (ir_class) |irc| {
                cur_name = irc.name;
                if (missTraceWant(name)) {
                    var matched: usize = 0;
                    for (irc.methods) |fid| {
                        if (funcAt(mod, fid)) |f| {
                            if (std.mem.eql(u8, f.name, name)) matched += 1;
                        }
                    }
                    std.debug.print("[rim] class={s} cid={?} methods={d} named={d} static_recv={s} static_up_ready={} in_up={}\n", .{
                        irc.fqn,
                        if (item.cid) |c| c.int() else null,
                        irc.methods.len,
                        matched,
                        static_recv orelse "-",
                        static_up_ready,
                        static_up.contains(irc.fqn),
                    });
                }
                // Gather candidates named `name`. A `@LowPriorityInOverloadResolution`
                // / `@Deprecated(level = ERROR)` member is a guard stub that only
                // applies when no ordinary candidate (member or top-level extension)
                // does; skip it here so resolution falls through to the extension
                // path. kotlinx.coroutines' `SelectBuilder.onTimeout` shadows its own
                // `onTimeout` extension this way, and binding the stub would
                // self-recurse (its body just calls the extension).
                var candidates: std.ArrayList(Func) = .empty;
                defer candidates.deinit(allocator);
                for (irc.methods) |fid| {
                    if (funcAt(mod, fid)) |f| {
                        if (std.mem.eql(u8, f.name, name) and !f.low_priority) {
                            // A member EXTENSION found among the class's own
                            // methods binds the dispatch receiver as its
                            // EXTENSION receiver (params[0]). When the receiver
                            // is only the owner/dispatch instance and provably
                            // not the declared extension-receiver type, that
                            // direct bind is wrong: the call resolves through
                            // the extension path instead (owner from the
                            // enclosing `this`, extension receiver from an outer
                            // implicit receiver — e.g. `with(node) { measure() }`
                            // inside a MeasureScope coordinator). Skip it so the
                            // receiver walk continues to the true extension
                            // receiver.
                            if (isMemberExt(mod, fid) and f.params.len > 0 and
                                std.mem.eql(u8, f.params[0].name, "this") and
                                receiverDefinitelyNotParam(self, &f.params[0].ty, receiver)) continue;
                            // Kotlin collection-stub bridge: a candidate whose
                            // declared param names a CLASS type param with a
                            // bound the runtime argument refutes is skipped,
                            // so the walk falls through to the inherited
                            // implementation (indexOf(nonEnum) on an
                            // EnumEntries answers -1 through AbstractList's
                            // scan, exactly as the generated bridge does).
                            if (classTypeParamRefutes(self, mod, irc.fqn, &f, args)) continue;
                            // A static-receiver-directed call is resolved in the
                            // static type's member scope. A candidate declared on a
                            // proper descendant of that type (not in its ancestor
                            // closure) that introduces its OWN type parameters is a
                            // subtype-only generic overload UNLESS the static type's
                            // own scope declares a generic member of the same shape
                            // for it to override. `PersistentCompositionLocalHashMap
                            // .get<T>` carries `override` (of `CompositionLocalMap`,
                            // a subtype of `Map`) yet is out of `Map`'s scope, so an
                            // `is_override` test is not enough — the closure check is.
                            // A plain non-generic member (a synthesized delegate or
                            // accessor) is left untouched by the generic-shape guard.
                            if (static_up_ready and !static_up.contains(irc.fqn)) {
                                const tvc = funcTypeParamCount(self, f.id);
                                if (tvc > 0 and !(try closureHasGenericMethod(self, allocator, static_cid, name, tvc))) continue;
                                // A NON-generic member declared outside the static
                                // type's closure is invisible when the static type is
                                // an INTERFACE whose transitive member set lacks the
                                // name: `this + dispatcher` on a CoroutineScope-typed
                                // receiver must not bind the runtime coroutine's
                                // inherited `CoroutineContext.Element.plus`; the
                                // `CoroutineScope.plus` extension is Kotlin's target.
                                // Interface-only: an interface's registry member set
                                // is exact, so the exclusion cannot drop a legitimate
                                // inherited member the set fails to record.
                                // Operator-convention names only: klio has no
                                // smart-cast narrowing, so a general exclusion
                                // loops when an extension's body re-calls the
                                // member under an `is` check (`Continuation.
                                // resumeCancellableWith` -> DispatchedContinuation
                                // member). Operators do not take that shape, and
                                // they are where the static-type divergence bites
                                // (`this + dispatcher` on CoroutineScope).
                                if (tvc == 0 and isOperatorConventionName(name) and
                                    staticIsInterface(mod, static_cid) and
                                    !closureHasMethodNamed(mod, static_cid, name)) continue;
                            }
                            try candidates.append(allocator, f);
                        }
                    }
                }
                if (missTraceWant(name)) {
                    std.debug.print("[rim2] class={s} collected={d} picked={} args={d}\n", .{
                        irc.fqn,
                        candidates.items.len,
                        pickMethodOverload(self, mod, candidates.items, args) != null,
                        args.len,
                    });
                }
                if (pickMethodOverload(self, mod, candidates.items, args)) |f| {
                    if (!callableArgPrefersFunctionExtension(self, mod, name, &f, receiver, args) and
                        !memberArgsDisprovenExtensionApplies(self, mod, name, &f, args))
                    {
                        const hit = ResolvedMethod{ .fid = f.id, .unambiguous = candidates.items.len == 1 or
                            (pickArityForced(self, candidates.items, args.len) and argsRelaxedAdjudicable(args)) };
                        // Kotlin resolves against the WHOLE member scope, and a
                        // candidate that binds without defaults is more specific
                        // than one that needs them. A fit leaning on defaults
                        // therefore cannot commit here — a supertype may declare
                        // the exact-arity overload (`WithTime.secondFraction(
                        // fixedLength)` under `AbstractWithTimeBuilder`'s
                        // `secondFraction(minLength, maxLength)`, where a
                        // one-argument call otherwise filled `maxLength` from its
                        // default). Keep the FIRST such fit so an override still
                        // outranks the base it overrides, and let the walk look
                        // for an exact one.
                        if (methodBindsWithoutDefaults(&f, args.len)) return hit;
                        if (defaulted_hit == null) defaulted_hit = hit;
                    }
                }
                // Enqueue the resolved supertypes by identity (their IR class
                // ids) so the inherited-method walk follows the real class
                // hierarchy, never a same-simple-name impostor.
                for (irc.supertypes) |sid| {
                    if (@intFromEnum(sid) < mod.classes.items.len) {
                        try queue.append(allocator, .{ .cid = sid, .name = mod.classes.items[@intFromEnum(sid)].name });
                    }
                }
                // A pack shim class's cross-root supertype ids can be
                // unresolved at load (ktor's KlioApplicationResponse :
                // BaseApplicationResponse walked as a leaf, so the inherited
                // `status` overloads were invisible). The registry's
                // name-chain evidence still records the declared parents —
                // continue the walk by name when identity resolution
                // recorded none.
                if (irc.supertypes.len == 0) {
                    const chain: []const []const u8 =
                        mod.registry.class_super_names.get(irc.fqn) orelse
                        mod.registry.class_super_names.get(irc.name) orelse &.{};
                    for (chain) |sup| {
                        try queue.append(allocator, .{ .cid = null, .name = sup, .hint = irc.fqn });
                    }
                }
            }
        }
        // Fallback for a receiver class with no unambiguous IR id (anonymous/
        // synthesized): expand supertypes from the registered simple names.
        if (ir_class == null) {
            const cg = self.classes.borrow();
            if (cg.get().get(cur_name)) |def| {
                const dg = def.borrow();
                for (dg.get().supertype_names) |sup| try queue.append(allocator, .{ .cid = null, .name = sup, .hint = dg.get().fqn });
                dg.deinit();
            }
            cg.deinit();
        }
    }
    return defaulted_hit;
}

/// Whether `f` binds a call of `argc` arguments with every parameter supplied
/// — no default filled, no vararg absorbing the tail. Kotlin ranks such a
/// candidate above one that needs either.
pub fn methodBindsWithoutDefaults(f: *const Func, argc: usize) bool {
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    if (f.params.len - skip != argc) return false;
    for (f.params[skip..]) |*p| {
        if (p.is_vararg) return false;
    }
    return true;
}

/// See the candidate loop in `resolveInstanceMethod`: whether a declared
/// param typed as one of `class_name`'s type parameters has a recorded
/// upper bound the runtime argument DEFINITIVELY refutes. Positive-proof
/// only — an unknown/incomplete relation never refutes.
pub fn classTypeParamRefutes(self: *VmHost, mod: *const Module, class_name: []const u8, f: *const Func, args: []const Value) bool {
    const bounds = mod.registry.class_type_param_bounds.get(class_name) orelse return false;
    const sig = mod.decl_sigs.get(f.id.int()) orelse return false;
    const owner = sig.enclosing_class orelse return false;
    const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    if (f.params.len <= recv_off) return false;
    for (f.params[recv_off..], 0..) |*p, i| {
        if (i >= args.len) break;
        const identity = ir.parseClassTypeParamIdentity(
            std.mem.trimEnd(u8, p.ty.name, "?"),
        ) orelse continue;
        if (identity.owner.int() != owner.int()) continue;
        for (bounds) |b| {
            if (!std.mem.eql(u8, b.param, identity.param)) continue;
            var bn = simpleName(b.bound);
            if (std.mem.findScalar(u8, bn, '<')) |lt| bn = bn[0..lt];
            bn = std.mem.trimEnd(u8, bn, "?");
            if (std.mem.eql(u8, bn, "Any")) continue;
            const arg = &args[i];
            if (arg.* == .Null) continue;
            if (std.mem.eql(u8, bn, "Enum")) {
                // An enum-entry instance's class is is_enum; anything else
                // can never satisfy an Enum bound.
                if (arg.* == .Instance) {
                    const g = arg.Instance.borrow();
                    const cg = g.get().class.borrow();
                    const is_enum = cg.get().is_enum;
                    cg.deinit();
                    g.deinit();
                    if (!is_enum) return true;
                } else {
                    return true;
                }
                continue;
            }
            const decidable = switch (arg.*) {
                .Null, .IrClosure, .Intrinsic, .BoundMethod => false,
                else => true,
            };
            if (decidable and !receiverImplementsHead(self, arg, bn)) return true;
        }
    }
    return false;
}

/// Invoke an already-resolved user method by `FuncId`: prepend the receiver,
/// pad defaults, pack varargs, and run the body. Shared by the cold resolve
/// path (`irMethodWalk`) and the inline-cache fast path.
/// Direct dispatch to a lowering-resolved member target
/// (`Inst.CallMember.resolved`): invoke `fid` on `receiver` with no name
/// resolution, applicability walk, or FQN scan. Missing targets are image/link
/// errors and remain errors rather than changing the declaration selected by
/// lowering.
pub fn typeHeadLast(s: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, s, "?");
    if (std.mem.findScalarLast(u8, t, '.')) |d| return t[d + 1 ..];
    return t;
}

pub fn invokeResolvedMember(
    self: *VmHost,
    allocator: Allocator,
    dispatch_receiver: ?*const Value,
    receiver: *const Value,
    fid: FuncId,
    args: []const Value,
    arg_names: []const ?[]const u8,
) Allocator.Error!EvalResult {
    // Lowering resolves a member the receiver's class does not declare to the
    // implementation it inherits — for a `by`-delegated interface that is the
    // interface's own default body, but Kotlin routes it to the delegate. The
    // static identity is only correct for a class that actually inherits the
    // member, so re-decide it here for a delegating receiver.
    if (receiver.* == .Instance) {
        if (resolvedMemberName(self, fid)) |name| {
            if (interfaceDelegateFor(self, allocator, receiver.Instance, name)) |d| {
                const r = try callMemberRec(self, allocator, &d, name, args);
                switch (r) {
                    .ok => return r,
                    .err => |e| if (e != .Unimplemented) return r else freeDispatchMiss(allocator, r),
                }
            }
        }
    }
    // A member-extension needs its declaring class's `this` seeded as an
    // enclosing receiver before the body runs; a plain member binds
    // `[receiver] ++ args` directly.
    const is_member_ext = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk isMemberExt(mg.get(), fid);
    };
    // NAMED arguments must bind by parameter name — the positional invokers
    // below would walk them into a vararg (`assertLines("12345", limit = 5)`
    // stringified the limit into the vararg and kept the default).
    var any_named = false;
    for (arg_names) |n| {
        if (n != null) any_named = true;
    }
    if (any_named) {
        const all = try prependReceiver(allocator, receiver, args);
        defer if (runtime.freeScratch()) allocator.free(all);
        const names = try allocator.alloc(?[]const u8, arg_names.len + 1);
        defer if (runtime.freeScratch()) allocator.free(names);
        names[0] = null;
        @memcpy(names[1..], arg_names);
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (funcAt(mod, fid) == null) {
            return .{ .err = .{ .Type = "resolved member target is missing" } };
        }
        if (is_member_ext) {
            const dispatch = dispatch_receiver orelse return .{
                .err = .{ .Type = "resolved member extension is missing its dispatch receiver" },
            };
            ir.eval.pushEnclosing(dispatch);
            defer ir.eval.popEnclosing();
            return try callFuncNamedRec(self, allocator, mod, fid, all, names);
        }
        return try callFuncNamedRec(self, allocator, mod, fid, all, names);
    }
    if (is_member_ext) {
        const dispatch = dispatch_receiver orelse return .{
            .err = .{ .Type = "resolved member extension is missing its dispatch receiver" },
        };
        return invokeMemberExtFuncId(
            self,
            allocator,
            dispatch,
            receiver,
            fid,
            args,
        );
    }
    return (try invokeMethodFuncId(self, allocator, receiver, fid, args)) orelse
        .{ .err = .{ .Type = "resolved member target is not executable" } };
}

/// Compile-time resolver for the loop JIT's virtual inline sites: the
/// FuncId the slot dispatches to on `receiver`'s class, via the same
/// resolved-id memo + main-module slot table the runtime path reads — with
/// NO fallback arms (an anonymous class, a host-backed member, an unlinked
/// or bodyless target all return null, so the site stays a trampoline and
/// runtime behavior is unchanged). The only state touched is the class's
/// own resolve memo, which the runtime path fills identically.
pub fn resolveVirtualFuncId(self: *VmHost, receiver: *const Value, slot: ir.MethodSlotId) ?FuncId {
    if (receiver.* != .Instance) return null;
    const runtime_def = blk: {
        const instance = receiver.Instance.borrow();
        defer instance.deinit();
        break :blk instance.get().class.clone();
    };
    defer runtime_def.deinit();
    {
        const class = runtime_def.borrow();
        defer class.deinit();
        if (class.get().is_anonymous) return null;
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    const memo_class_id: ?ir.ClassId = cid: {
        const class = runtime_def.borrow();
        defer class.deinit();
        const cdef = class.get();
        const mod_key = @intFromPtr(module);
        if (cdef.resolve_mod.load(.monotonic) == mod_key) {
            const plus1 = cdef.resolve_cid.load(.acquire);
            if (plus1 != 0) break :cid ir.ClassId.from(plus1 - 1);
        }
        const found = module.classIdByFqn(cdef.fqn) orelse break :cid null;
        const mut = @constCast(cdef);
        if (mut.resolve_mod.cmpxchgStrong(0, mod_key, .acq_rel, .monotonic) == null) {
            mut.resolve_cid.store(found.int() + 1, .release);
        }
        break :cid found;
    };
    const cls = memo_class_id orelse return null;
    const target = module.methodSlotTarget(cls, slot) orelse return null;
    if (!virtualTargetExecutable(module, target)) return null;
    return target;
}

pub fn runtimeVirtualCacheGet(self: *VmHost, key: root_mod.ProgramImage.RuntimeVirtualKey) ?root_mod.ProgramImage.RuntimeVirtualTarget {
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().runtime_virtual_cache.get(key);
}

pub fn runtimeVirtualCachePut(self: *VmHost, key: root_mod.ProgramImage.RuntimeVirtualKey, target: root_mod.ProgramImage.RuntimeVirtualTarget) void {
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().runtime_virtual_cache.put(key, target) catch {};
}

/// Resolve a runtime class-table entry without a simple-name fallback when the
/// caller supplied an FQN. Runtime-defined classes record their resolved
/// supertypes in this table even though they have no main-module `ClassId`.
pub fn runtimeClassDef(self: *VmHost, name: []const u8) ?ObjRef(ClassDef) {
    const classes = self.classes.borrow();
    defer classes.deinit();
    if (classes.get().get(name)) |def| return def.clone();
    var it = classes.get().valueIterator();
    while (it.next()) |def| {
        const dg = def.borrow();
        const matches = std.mem.eql(u8, dg.get().fqn, name);
        dg.deinit();
        if (matches) return def.clone();
    }
    return null;
}

/// Find this runtime class's body for a numeric slot. The slot root fixes the
/// method family; the exact arity-qualified side-table key only locates the
/// already-lowered body belonging to that family.
pub fn runtimeVirtualOverride(
    self: *VmHost,
    allocator: Allocator,
    runtime_def: ObjRef(ClassDef),
    root_func: Func,
) Allocator.Error!?AnonMethodEntry {
    const class_name = blk: {
        const dg = runtime_def.borrow();
        defer dg.deinit();
        break :blk dg.get().name;
    };
    const receiver_count: usize = if (root_func.params.len != 0 and
        std.mem.eql(u8, root_func.params[0].name, "this")) 1 else 0;
    const arity_name = try std.fmt.allocPrint(
        allocator,
        "{s}#{d}",
        .{ root_func.name, root_func.params.len - receiver_count },
    );
    defer if (runtime.freeScratch()) allocator.free(arity_name);
    // Two same-arity overrides of one name share the arity key and only the
    // last is reachable through it. Walk the indexed keys first and take the
    // one whose parameter types are the slot root's; the arity key is the
    // answer when the family has just one member.
    const hit = blk: {
        var index: usize = 0;
        while (true) : (index += 1) {
            const member = root_mod.anonOverloadMemberName(allocator, arity_name, index) catch break;
            defer if (runtime.freeScratch()) allocator.free(member);
            const candidate_hit = lookupAnonMethodExact(self, allocator, class_name, member) orelse break;
            const cg = candidate_hit.module.borrow();
            defer cg.deinit();
            const cf = funcAt(cg.get(), candidate_hit.func) orelse continue;
            if (root_mod.anonParamsMatch(cf.params, root_func.params)) break :blk candidate_hit;
        }
        break :blk lookupAnonMethodExact(self, allocator, class_name, arity_name) orelse return null;
    };
    const hg = hit.module.borrow();
    defer hg.deinit();
    const candidate = funcAt(hg.get(), hit.func) orelse return null;
    if (!candidate.is_override or !std.mem.eql(u8, candidate.name, root_func.name)) return null;
    const candidate_receiver_count: usize = if (candidate.params.len != 0 and
        std.mem.eql(u8, candidate.params[0].name, "this")) 1 else 0;
    if (candidate.params.len - candidate_receiver_count != root_func.params.len - receiver_count) return null;
    return hit;
}

/// Merge the complete slot tables of a runtime class's resolved direct
/// supertypes. Named supertypes stop the walk because their main-module vtable
/// already contains their transitive inheritance; runtime supertypes continue
/// through their recorded names.
pub fn runtimeInheritedVirtualTarget(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    runtime_def: ObjRef(ClassDef),
    slot: MethodSlotId,
) Allocator.Error!?FuncId {
    var queue: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        while (queue.pop()) |def| def.deinit();
        queue.deinit(allocator);
    }
    var seen = std.AutoHashMap(usize, void).init(allocator);
    defer seen.deinit();
    {
        const dg = runtime_def.borrow();
        defer dg.deinit();
        for (dg.get().supertype_names) |name| {
            if (runtimeClassDef(self, name)) |def| try queue.append(allocator, def);
        }
    }

    var best: ?FuncId = null;
    while (queue.pop()) |def| {
        defer def.deinit();
        const identity = def.identity();
        const gop = try seen.getOrPut(identity);
        if (gop.found_existing) continue;

        const dg = def.borrow();
        const fqn = dg.get().fqn;
        const class_name = dg.get().name;
        if (module.classIdByFqn(fqn) orelse
            (if (std.mem.eql(u8, fqn, class_name)) module.classId(class_name) else null)) |cid|
        {
            dg.deinit();
            if (module.methodSlotTarget(cid, slot)) |target| {
                best = if (best) |existing|
                    try module.preferredMethodSlotTarget(allocator, existing, target)
                else
                    target;
            }
            continue;
        }
        for (dg.get().supertype_names) |name| {
            if (runtimeClassDef(self, name)) |parent| try queue.append(allocator, parent);
        }
        dg.deinit();
    }
    return best;
}

pub fn linkRuntimeVirtualTarget(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    runtime_def: ObjRef(ClassDef),
    slot: MethodSlotId,
) Allocator.Error!?root_mod.ProgramImage.RuntimeVirtualTarget {
    const root_func = funcAt(module, FuncId.from(slot.int())) orelse return null;
    if (try runtimeVirtualOverride(self, allocator, runtime_def, root_func)) |hit| {
        return .{ .side_func = hit };
    }
    if (try runtimeInheritedVirtualTarget(self, allocator, module, runtime_def, slot)) |target| {
        return .{ .main_func = target.int() };
    }
    return null;
}

pub fn virtualTargetExecutable(module: *const Module, target: FuncId) bool {
    const f = funcAt(module, target) orelse return false;
    return f.hasBody();
}

pub fn runtimeVirtualTarget(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    runtime_def: ObjRef(ClassDef),
    slot: MethodSlotId,
) Allocator.Error!?root_mod.ProgramImage.RuntimeVirtualTarget {
    const key: root_mod.ProgramImage.RuntimeVirtualKey = .{
        .class_p = runtime_def.identity(),
        .slot = slot.int(),
    };
    if (runtimeVirtualCacheGet(self, key)) |cached| return cached;
    const target = (try linkRuntimeVirtualTarget(self, allocator, module, runtime_def, slot)) orelse return null;
    runtimeVirtualCachePut(self, key, target);
    return target;
}

pub fn invokeRuntimeVirtualSide(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    receiver: *const Value,
    root: FuncId,
    hit: AnonMethodEntry,
    args: []const Value,
    arg_params: ?[]const u32,
) Allocator.Error!EvalResult {
    if (arg_params) |params| {
        const bound = try host_call_func.bindFuncIndexedArgs(
            self,
            allocator,
            module,
            root,
            root,
            receiver,
            args,
            params,
        );
        switch (bound) {
            .ok => |ordered| {
                defer allocator.free(ordered);
                return invokeAnonMethod(self, allocator, receiver, hit, ordered[1..], receiver.Instance);
            },
            .err => |err| return .{ .err = err },
        }
    }
    return invokeAnonMethod(self, allocator, receiver, hit, args, receiver.Instance);
}

/// Name the slot family, receiver, and live frame chain when a virtual call
/// finds no target for its receiver class. Gated on `KLIO_ERR_TRACE`, like the
/// non-instance receiver diagnostic above: the bare error says a slot is
/// unlinked but not which method or on what, which is the whole question.
pub fn virtualSlotUnlinkedDiag(
    module: *const Module,
    slot: MethodSlotId,
    recv_fqn: []const u8,
    nargs: usize,
    which: []const u8,
) void {
    if (runtime.envOnce("KLIO_ERR_TRACE") == null) return;
    const root = FuncId.from(slot.int());
    const mname: []const u8 = if (module.funcById(root)) |f| f.fqn else "?";
    std.debug.print(
        "[vslot-unlinked] {s} slot={d} method={s} recv={s} nargs={d}\n",
        .{ which, slot.int(), mname, recv_fqn, nargs },
    );
    // Name the executing overload: same-named siblings (the FunctionN `invoke`
    // family) are indistinguishable in the frame chain, and which one is running
    // is exactly what identifies a misbound receiver.
    if (ir.eval.currentFrameFunc()) |cf| {
        std.debug.print("[vslot-unlinked]   in {s} params=[", .{cf.fqn});
        for (cf.params) |p| std.debug.print("{s} ", .{p.name});
        std.debug.print("]\n", .{});
    }
    ir.eval.dumpFrameChainForDiagAlways();
}
