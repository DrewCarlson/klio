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

/// The user method `FuncId` `receiver.name(args)` dispatches to, or null for a
/// non-`Instance` receiver or an intrinsic, extension or unresolved name.
/// Members outrank extensions in Kotlin, so the resolved member is what runs.
pub fn resolveMemberFuncId(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) ?FuncId {
    if (receiver.* != .Instance) return null;
    const rm = resolveInstanceMethod(self, allocator, receiver, name, args, null) catch return null;
    return if (rm) |m| m.fid else null;
}

/// Whether Kotlin drops `member` because its value-parameter types provably
/// reject the arguments while a same-arity top-level extension namesake applies.
/// Short of a definite per-arg disproof the member-first order holds.
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

/// Whether a function-shaped argument the member binds only through a bare type
/// parameter makes a same-name extension taking it concretely the more specific,
/// and so in Kotlin the only applicable, overload.
pub fn callableArgPrefersFunctionExtension(self: *VmHost, mod: *const Module, name: []const u8, member: *const Func, receiver: *const Value, args: []const Value) bool {
    const mskip: usize = if (member.params.len > 0 and std.mem.eql(u8, member.params[0].name, "this")) 1 else 0;
    var fn_arg_pos: ?usize = null;
    for (args, 0..) |*a, i| {
        const fn_shaped = isCallable(a) or a.* == .Null;
        if (!fn_shaped) continue;
        const pi = mskip + i;
        if (pi >= member.params.len) continue;
        const mp = member.params[pi].ty;
        if (std.mem.startsWith(u8, mp.name, "Function")) return false; // member already takes a function here
        // A bare type-parameter slot, which a function does not satisfy.
        if (mp.name.len <= 2 and allUppercase(mp.name)) fn_arg_pos = i;
    }
    const want_pos = fn_arg_pos orelse return false;

    const recv_chain = receiverClassChain(self, self.allocator, receiver.Instance) catch return false;
    defer @constCast(&recv_chain).deinit();

    for (mod.funcsBySimpleName(name)) |fid| {
        const ef = funcAt(mod, fid) orelse continue;
        if (ef.kind != .top_level_extension and ef.kind != .member_extension) continue;
        if (ef.params.len == 0) continue;
        const rt = ef.params[0].ty.name;
        const recv_ok = recv_chain.contains(rt) or std.mem.eql(u8, rt, "Any") or (rt.len <= 2 and allUppercase(rt));
        if (!recv_ok) continue;
        const epi = 1 + want_pos; // skip the extension's `this`
        if (epi >= ef.params.len) continue;
        if (std.mem.startsWith(u8, ef.params[epi].ty.name, "Function")) return true;
    }
    return false;
}

/// Count of `fid`'s own method-level type parameters, not the class's.
pub fn funcTypeParamCount(self: *VmHost, fid: FuncId) usize {
    const mg = self.module.borrow();
    defer mg.deinit();
    const tps = mg.get().registry.func_type_params.get(fid) orelse return 0;
    return tps.items.len;
}

/// The IR class id in `receiver`'s hierarchy whose simple name matches the
/// static receiver-type head `want`, or null when that type is not nominal.
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

/// The FQNs at or above `start_cid`, the classes a member must be declared on to
/// be visible from the static receiver type; one declared elsewhere in the
/// runtime hierarchy is invisible unless it overrides a visible member.
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
/// `name`. A missing registry entry answers true, keeping callers conservative.
pub fn closureHasMethodNamed(mod: *const Module, start_cid: ir.ClassId, name: []const u8) bool {
    // `Any`'s members are visible everywhere and the registry sets omit them.
    if (std.mem.eql(u8, name, "equals") or std.mem.eql(u8, name, "hashCode") or std.mem.eql(u8, name, "toString")) return true;
    if (@intFromEnum(start_cid) >= mod.classes.items.len) return true;
    const irc = mod.classes.items[@intFromEnum(start_cid)];
    const hm = mod.registry.hierarchy_methods.get(irc.fqn) orelse
        mod.registry.hierarchy_methods.get(irc.name) orelse
        mod.registry.hierarchy_methods.get(simpleName(irc.fqn)) orelse return true;
    return hm.contains(name);
}

pub const ClassByNameHit = struct { cls: ir.Class, cid: ir.ClassId };

/// Resolve a supertype recorded by simple name, preferring the candidate sharing
/// the longest dotted prefix with `hint_fqn`, the class that recorded it: two
/// packs may each declare a class of that simple name.
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

/// Whether `start_cid` or a supertype declares `name` with exactly `tvc` own
/// type parameters. A generic same-name method a runtime subtype introduces
/// shadows the statically-bound member only when the static scope declares that
/// shape; `override` alone may name an interface the static type cannot see.
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
        // An interface's abstract member lowers no method fid, so consult the
        // registered declaration headers too.
        for (mod.memberDecls(irc.fqn, name)) |fid| {
            if (funcTypeParamCount(self, fid) == tvc) return true;
        }
        for (irc.supertypes) |sid| try queue.append(allocator, sid);
    }
    return false;
}

/// Walk `receiver`'s class hierarchy resolving `name` to a user method.
/// `unambiguous` marks a resolution independent of argument types, so the inline
/// dispatch cache may keep it.
pub fn resolveInstanceMethod(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8) Allocator.Error!?ResolvedMethod {
    const inst = receiver.Instance;
    // A call carrying a static receiver type resolves in that type's member scope,
    // so the closure excludes a subtype candidate overriding nothing visible there.
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
    // Best fit so far that needed defaults, used only if no exact-arity one exists.
    var defaulted_hit: ?ResolvedMethod = null;
    // `runtime_only`: a run-time class has no IR row and its name may collide with
    // a module class, so the walk uses its runtime ClassDef, not the index.
    const WalkItem = struct { cid: ?ir.ClassId, name: []const u8, hint: []const u8 = "", runtime_only: bool = false };
    var queue: std.ArrayList(WalkItem) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    // Start from the IR class id keyed by exact FQN and walk by resolved supertype
    // id, so a same-simple-name class in another package can never shadow it.
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
                // A `@LowPriorityInOverloadResolution` or ERROR-deprecated member is a
                // guard stub applying only when no ordinary candidate does; skipping it
                // falls through to the extension it forwards to.
                var candidates: std.ArrayList(Func) = .empty;
                defer candidates.deinit(allocator);
                for (irc.methods) |fid| {
                    if (funcAt(mod, fid)) |f| {
                        if (std.mem.eql(u8, f.name, name) and !f.low_priority) {
                            // A member extension binds the dispatch receiver
                            // as its extension receiver, so keep walking when
                            // that receiver is provably not the declared type.
                            if (isMemberExt(mod, fid) and f.params.len > 0 and
                                std.mem.eql(u8, f.params[0].name, "this") and
                                receiverDefinitelyNotParam(self, &f.params[0].ty, receiver)) continue;
                            // Collection-stub bridge: a param naming a class
                            // type param the argument refutes takes the walk on
                            // to the inherited body.
                            if (classTypeParamRefutes(self, mod, irc.fqn, &f, args)) continue;
                            // A candidate outside the static type's ancestor
                            // closure introducing its own type parameters is a
                            // subtype-only overload, absent that shape above.
                            if (static_up_ready and !static_up.contains(irc.fqn)) {
                                const tvc = funcTypeParamCount(self, f.id);
                                if (tvc > 0 and !(try closureHasGenericMethod(self, allocator, static_cid, name, tvc))) continue;
                                // A non-generic member outside the closure is
                                // invisible when an interface static type's set
                                // lacks the name. Operator names only: a wider
                                // exclusion loops on extensions re-calling it.
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
                        // Kotlin ranks a candidate binding without defaults above
                        // one needing them, so a defaulted fit waits on a supertype's
                        // exact-arity overload; keep the first, an override.
                        if (methodBindsWithoutDefaults(&f, args.len)) return hit;
                        if (defaulted_hit == null) defaulted_hit = hit;
                    }
                }
                // Enqueue supertypes by IR class id, never by simple name.
                for (irc.supertypes) |sid| {
                    if (@intFromEnum(sid) < mod.classes.items.len) {
                        try queue.append(allocator, .{ .cid = sid, .name = mod.classes.items[@intFromEnum(sid)].name });
                    }
                }
                // A pack shim's cross-root supertype ids can be unresolved at load,
                // so fall back to the parent names the registry records.
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
        // A receiver class with no IR id expands supertypes from registered names.
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

/// Whether `f` binds `argc` arguments with every parameter supplied: no default
/// filled, no vararg absorbing the tail. Kotlin ranks such a candidate higher.
pub fn methodBindsWithoutDefaults(f: *const Func, argc: usize) bool {
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    if (f.params.len - skip != argc) return false;
    for (f.params[skip..]) |*p| {
        if (p.is_vararg) return false;
    }
    return true;
}

/// Whether a param typed as one of `class_name`'s type parameters has a recorded
/// upper bound the argument definitively refutes; an unknown relation never does.
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
                // Only an enum-entry instance can satisfy an Enum bound.
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

pub fn typeHeadLast(s: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, s, "?");
    if (std.mem.findScalarLast(u8, t, '.')) |d| return t[d + 1 ..];
    return t;
}

/// Invoke a lowering-resolved member target: prepend the receiver, pad defaults,
/// pack varargs, run the body. No name resolution, so a missing target is a link
/// error rather than a re-selection.
pub fn invokeResolvedMember(
    self: *VmHost,
    allocator: Allocator,
    dispatch_receiver: ?*const Value,
    receiver: *const Value,
    fid: FuncId,
    args: []const Value,
    arg_names: []const ?[]const u8,
) Allocator.Error!EvalResult {
    // Lowering resolves an undeclared member to the inherited implementation, the
    // interface default body; Kotlin routes a `by` delegation to the delegate.
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
    // A member extension needs its declaring class's `this` seeded as an
    // enclosing receiver; a plain member binds `[receiver] ++ args` directly.
    const is_member_ext = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk isMemberExt(mg.get(), fid);
    };
    // Named arguments bind by name; the positional invokers walk them into a vararg.
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

/// The `FuncId` a virtual slot dispatches to on `receiver`'s class, from the same
/// resolved-id memo and slot table the runtime path reads. No fallback arms: an
/// anonymous class, host-backed member or bodyless target returns null.
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

/// Resolve a runtime class-table entry, with no simple-name fallback when given
/// an FQN. Runtime classes record supertypes here, having no main-module `ClassId`.
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

/// This runtime class's body for a numeric slot. The slot root fixes the method
/// family; the arity-qualified side-table key only locates the lowered body.
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
    // Two same-arity overrides share the arity key and only the last is reachable
    // through it, so the indexed keys decide by the slot root's parameter types.
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

/// Merge the slot tables of a runtime class's direct supertypes. A named one stops
/// the walk, its vtable already transitive; runtime ones continue through names.
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

/// Name the slot family, receiver and frame chain of an unlinked virtual call.
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
    // Same-named siblings are indistinguishable in the frame chain alone.
    if (ir.eval.currentFrameFunc()) |cf| {
        std.debug.print("[vslot-unlinked]   in {s} params=[", .{cf.fqn});
        for (cf.params) |p| std.debug.print("{s} ", .{p.name});
        std.debug.print("]\n", .{});
    }
    ir.eval.dumpFrameChainForDiagAlways();
}
