//! Named-argument member dispatch: the `callMemberNamed*` entry points and the
//! named-candidate walk behind them.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const applicability = @import("applicability");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const VmHost = vmhost.VmHost;
const trace = @import("../trace.zig");
const compose = @import("../compose.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const Func = ir.Func;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;

const applicability_probe = @import("applicability_probe.zig");
const argDefinitelyNotParamType = applicability_probe.argDefinitelyNotParamType;
const funcDefaults = applicability_probe.funcDefaults;
const paramHasDefault = applicability_probe.paramHasDefault;
const pickMethodOverload = applicability_probe.pickMethodOverload;
const receiverDefinitelyNotParam = applicability_probe.receiverDefinitelyNotParam;
const runtimeMemberApplicability = applicability_probe.runtimeMemberApplicability;

const binding_probe = @import("binding_probe.zig");
const instanceBindingNamedProbe = binding_probe.instanceBindingNamedProbe;

const caches = @import("caches.zig");
const METHOD_MISS = caches.METHOD_MISS;
const extMethodCacheGet = caches.extMethodCacheGet;
const extMethodCachePut = caches.extMethodCachePut;
const tlSlot = caches.tlSlot;

const ext_fallback = @import("ext_fallback.zig");
const Candidate = ext_fallback.Candidate;
const builtinReceiverDisproven = ext_fallback.builtinReceiverDisproven;
const memberExtOwnerInstance = ext_fallback.memberExtOwnerInstance;
const scoreExtCandidates = ext_fallback.scoreExtCandidates;

const flat_call = @import("flat_call.zig");
const instanceInvokeWantsPair = flat_call.instanceInvokeWantsPair;
const prependReceiver = flat_call.prependReceiver;
const receiverHasMemberNamed = flat_call.receiverHasMemberNamed;
const recvFnFieldInvoke = flat_call.recvFnFieldInvoke;

const hcm = @import("../host_call_member.zig");
const cacheGen = hcm.cacheGen;
const callFuncNamedRec = hcm.callFuncNamedRec;
const dispatchIntrinsic = hcm.dispatchIntrinsic;
const lookupIntrinsic = hcm.lookupIntrinsic;
const reconstructDataClass = hcm.reconstructDataClass;
const simpleName = hcm.simpleName;
const unimplemented = hcm.unimplemented;

const member_ext_visibility = @import("member_ext_visibility.zig");
const delegateForwardNamed = member_ext_visibility.delegateForwardNamed;
const enclosingOwnerSet = member_ext_visibility.enclosingOwnerSet;
const interfaceDelegateFor = member_ext_visibility.interfaceDelegateFor;
const isMemberExt = member_ext_visibility.isMemberExt;
const memberExtVisible = member_ext_visibility.memberExtVisible;
const privateFnHiddenHere = member_ext_visibility.privateFnHiddenHere;

const receiver_probe = @import("receiver_probe.zig");
const allUppercase = receiver_probe.allUppercase;
const isCallable = receiver_probe.isCallable;
const receiverViolatesTypeParamBound = receiver_probe.receiverViolatesTypeParamBound;
const resolveAliasName = receiver_probe.resolveAliasName;
const strictReceiverProven = receiver_probe.strictReceiverProven;

const reflect_anon = @import("reflect_anon.zig");
const funcAt = reflect_anon.funcAt;
const root_mod = reflect_anon.root_mod;

const resolve_method = @import("resolve_method.zig");
const classByNamePreferring = resolve_method.classByNamePreferring;

const static_tail = @import("static_tail.zig");
const callMemberInnerStatic = static_tail.callMemberInnerStatic;
const freeDispatchMiss = static_tail.freeDispatchMiss;
const missTraceWant = static_tail.missTraceWant;
const nuTraceEnv = static_tail.nuTraceEnv;

const virtual_tail = @import("virtual_tail.zig");
const instanceMethodKeyScoped = virtual_tail.instanceMethodKeyScoped;
const invokeMethodFuncId = virtual_tail.invokeMethodFuncId;
const methodArgSigRelaxed = virtual_tail.methodArgSigRelaxed;

// -------------------------------------------------------------------------
// Remaining public entry points.
// -------------------------------------------------------------------------

pub fn callMemberNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, false, null, false, null);
}

/// `callMemberNamed` with the receiver's DECLARED type head (a bare call
/// on the implicit `this` of an extension body). Extension dispatch then
/// resolves against the static type, as kotlinc does.
pub fn callMemberNamedStatic(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, false, static_recv, false, null);
}

/// Per-receiver probe for the bare-name resolver's innermost-first
/// candidate walk: members and *receiver-compatible* extensions of this
/// one receiver. The unproven-compatibility extension pick reports a
/// clean miss here so it cannot pre-empt a real member of an outer
/// receiver; the resolver retries leniently (`callMemberNamed`) only
/// after every receiver missed strictly.
///
/// `static_recv` is the receiver's DECLARED type head when the caller
/// knows it (the bare-call resolver inside an extension body, whose
/// implicit `this` has the extension's declared receiver type). Kotlin
/// resolves extensions against the static receiver type, so when present
/// it replaces the runtime-type proof in the extension fallback: inside
/// `fun I.helper()` a bare `describe()` binds `I.describe` even when the
/// runtime value is a subtype with its own `describe` extension.
pub fn callMemberStrictExt(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
    var r = try callMemberNamedInner(self, allocator, receiver, name, args, arg_names, true, static_recv, false, null);
    // An ARG-BEARING call that got back its own CLASSIFIER (the class
    // value, or the companion instance, under the call's own name) did
    // not run anything — the dispatch fetched a reference. Kotlin never
    // calls a classifier reference: either a constructor applies (the
    // NewInstance path) or an outer candidate (the top-level factory
    // fn) wins. Refuse so the bare-name walk falls through — a KClass
    // tower candidate was swallowing `Constraints(minWidth = ...)`
    // (private-ctor value class + top-level factory) this way.
    if (r == .ok and args.len != 0) {
        const classifier_echo = switch (r.ok) {
            .Class => |c| blk: {
                const cg = c.borrow();
                defer cg.deinit();
                break :blk std.mem.eql(u8, cg.get().name, name);
            },
            .Instance => |inst| blk: {
                const g = inst.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                const fqn = cg.get().fqn;
                if (!std.mem.endsWith(u8, fqn, ".Companion")) break :blk false;
                const owner = fqn[0 .. fqn.len - ".Companion".len];
                const simple = if (std.mem.lastIndexOfScalar(u8, owner, '.')) |d| owner[d + 1 ..] else owner;
                break :blk std.mem.eql(u8, simple, name);
            },
            else => false,
        };
        if (classifier_echo) {
            r.ok.release(allocator);
            r = try unimplemented(allocator, "Vm::call_member `{s}` classifier echo refused", .{name});
        }
    }
    if (nuTraceEnv()) |w| {
        if (std.mem.eql(u8, w, name)) {
            const tag: []const u8 = switch (r) {
                .ok => "ok",
                .err => |e| @tagName(e),
            };
            const detail: []const u8 = switch (r) {
                .err => |e| switch (e) {
                    .Unimplemented => |m| m,
                    else => "",
                },
                else => "",
            };
            std.debug.print("[strictext] name={s} recv={s} -> {s} {s}\n", .{ name, receiver.typeFqn(), tag, detail });
        }
    }
    return r;
}

/// Whether the committed extension target's declared receiver definitely
/// excludes `recv` — the deferred direct-call leg falls back to name-based
/// resolution instead of executing a target the receiver cannot satisfy.
pub fn committedExtReceiverDisproven(self: *VmHost, fid: FuncId, recv: *const Value) bool {
    const mg = self.module.borrow();
    const f = mg.get().funcById(fid);
    mg.deinit();
    const ff = f orelse return true;
    if (ff.params.len == 0) return true;
    if (receiverViolatesTypeParamBound(self, fid, &ff.params[0].ty, recv)) return true;
    return argDefinitelyNotParamType(self, &ff.params[0].ty, recv);
}

/// The committed extension target's declared receiver is strictly PROVEN
/// by `recv` (the walk's pass-1 criterion; erasure-unprovable receivers
/// fall to the not-disproven pass).
pub fn committedExtReceiverProven(self: *VmHost, allocator: Allocator, fid: FuncId, recv: *const Value) bool {
    const mg = self.module.borrow();
    const f = mg.get().funcById(fid);
    mg.deinit();
    const ff = f orelse return false;
    if (ff.params.len == 0) return false;
    return strictReceiverProven(self, allocator, recv, fid, &ff.params[0].ty) catch false;
}

/// Members-only dispatch: the strict member walk with the extension
/// fallback suppressed, for a call whose extension target the lowering
/// already committed.
pub fn callMemberMembersOnly(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, true, static_recv, true, null);
}

/// The lenient members-only pass (erasure-unprovable receivers), extension
/// fallback still suppressed.
pub fn callMemberMembersOnlyLenient(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, false, static_recv, true, null);
}

/// Member dispatch with the receiver's DECLARED type constraining only the
/// extension selection (Kotlin's static member-vs-extension resolution).
pub fn callMemberNamedDeclared(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, declared_recv: ?[]const u8) Allocator.Error!EvalResult {
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, false, null, false, declared_recv);
}

pub fn callMemberNamedInner(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names_in: []const ?[]const u8, strict_ext: bool, static_recv: ?[]const u8, no_ext: bool, declared_recv: ?[]const u8) Allocator.Error!EvalResult {
    runtime.prof.opRoute(10);
    // Receiver-function-typed property invoked as a call (see
    // `recvFnFieldInvoke` on the static ladder): the stored lambda runs
    // with the owning instance as its receiver.
    if (try recvFnFieldInvoke(self, allocator, receiver, name, args)) |r| return r;
    // A member of a `by`-delegated interface the class does not override
    // belongs to the delegate, defaulted interface bodies included.
    if (receiver.* == .Instance and !strict_ext and !no_ext) {
        if (interfaceDelegateFor(self, allocator, receiver.Instance, name)) |d| {
            const r = try callMemberNamed(self, allocator, &d, name, args, arg_names_in);
            switch (r) {
                .ok => return r,
                .err => |e| if (e != .Unimplemented) return r else freeDispatchMiss(allocator, r),
            }
        }
    }
    // A member `invoke` whose only named arguments are plugin-synthetic
    // (`$composer = c, $changed = n`): the names were emitted against a
    // transformed closure's literal parameter names, but a memo-wrapped
    // value is a ComposableLambdaImpl whose `invoke(composer, changed)`
    // members use plain names, so the named binding can never match. The
    // pair is appended in declaration order, so positional binding is
    // exact — drop the synthetic names.
    var arg_names = arg_names_in;
    if (receiver.* == .Instance and std.mem.eql(u8, name, "invoke")) {
        var any_synth = false;
        var all_synth = true;
        for (arg_names) |n| {
            if (n) |nn| {
                any_synth = true;
                if (!std.mem.startsWith(u8, nn, "$")) all_synth = false;
            }
        }
        if (any_synth and all_synth) arg_names = &.{};
    }
    var any_named = false;
    for (arg_names) |n| {
        if (n != null) any_named = true;
    }

    // data-class `copy(name = …)`.
    if (std.mem.eql(u8, name, "copy") and receiver.* == .Instance) {
        if (try copyNamed(self, allocator, receiver, args, arg_names)) |r| return r;
    }

    // `CharArray.concatToString(startIndex = …)` / `(endIndex = …)`: the
    // subrange overload is handled inline by the array-member dispatch, not
    // the intrinsic table, so its `(startIndex = 0, endIndex = size)` defaults
    // are filled here before the positional handler runs.
    if (any_named and receiver.* == .Array and std.mem.eql(u8, name, "concatToString")) {
        const size: i64 = @intCast(receiver.Array.len());
        var start: i64 = 0;
        var end: i64 = size;
        for (args, 0..) |a, i| {
            const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
            if (nm) |an| {
                if (std.mem.eql(u8, an, "startIndex")) start = a.asI64() orelse 0;
                if (std.mem.eql(u8, an, "endIndex")) end = a.asI64() orelse size;
            }
        }
        const filled = [_]Value{ .{ .Int = @intCast(start) }, .{ .Int = @intCast(end) } };
        return try callMemberInnerStatic(self, allocator, receiver, name, &filled, strict_ext, static_recv, no_ext, declared_recv);
    }

    // Unified named→positional rewrite: a cached binding permutation for
    // this exact (class, name, arg shape, name vector) reorders the args
    // once and enters the POSITIONAL ladder — every positional fast path
    // (member cache, native bindings, ext cache) then applies. The perm
    // can only exist because a prior call of this shape resolved through
    // a terminal whose earlier named arms had declined it.
    if (any_named and receiver.* == .Instance) {
        if (namedOrderKey(self, receiver, name, args, arg_names)) |k| {
            const tslot = &caches.tl_perm_cache[tlSlot(k)];
            var perm: ?root_mod.ProgramImage.NamedPerm = null;
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
                if (shared) |p| {
                    tslot.* = .{ .class_p = k.class_p, .name_p = k.name_p, .n_args = k.n_args, .sig = k.sig, .raw_plus = 1, .gen = cacheGen(), .perm = p };
                    perm = p;
                }
            }
            if (perm) |p| {
                if (p.n != 0xFF and p.n <= args.len) {
                    var ok = true;
                    var buf: [15]Value = undefined;
                    for (0..p.n) |pi| {
                        if (p.src[pi] >= args.len) {
                            ok = false;
                            break;
                        }
                        buf[pi] = args[p.src[pi]];
                    }
                    if (ok) {
                        const r = try callMemberInnerStatic(self, allocator, receiver, name, buf[0..p.n], strict_ext, static_recv, no_ext, declared_recv);
                        // A positional-ladder MISS keeps the named ladder's
                        // own fallbacks (the hierarchy walk, the compose
                        // invoke completion) exactly as before the rewrite.
                        if (!(r == .err and r.err == .Unimplemented)) {
                            ir.eval.callStatsProbe("<named-perm-hit>");
                            return r;
                        }
                        freeDispatchMiss(allocator, r);
                    }
                }
            }
        }
    }

    // Named member-resolution memo: a prior walk pick for this exact
    // (class, name, arg shape, name vector) serves directly — the walk's
    // own terminal, with the self-delegation guard consulted at serve
    // time. The entry can only exist because every earlier named arm
    // declined the same shape when it was filled.
    if (any_named and receiver.* == .Instance) {
        if (namedMethodKey(self, receiver, name, args, arg_names)) |k| {
            if (extMethodCacheGet(self, k)) |raw| {
                if (raw != METHOD_MISS) {
                    const fid: FuncId = @enumFromInt(raw);
                    if (!walkActive(fid, receiverIdent(receiver))) {
                        if (try serveNamedFid(self, allocator, receiver, name, fid, args, arg_names)) |r| return r;
                    }
                }
            }
        }
    }

    // Stdlib intrinsic dispatch with named args.
    if (any_named) {
        ir.eval.callStatsProbe(name);
        if (try stdlibNamedDispatch(self, allocator, receiver, name, args, arg_names)) |r| {
            ir.eval.callStatsProbe("<named-stdlib-hit>");
            return r;
        }
        // Pack-installed host bindings take their arguments positionally; a
        // named call reaches them only after being put back in declaration
        // order.
        if (try instanceBindingNamedProbe(self, allocator, receiver, name, args, arg_names)) |r| {
            ir.eval.callStatsProbe("<named-binding-hit>");
            return r;
        }
    }

    // User extension / member fn with named args.
    if (any_named) {
        if (try userMethodNamed(self, allocator, receiver, name, args, arg_names)) |r| {
            ir.eval.callStatsProbe("<named-user-hit>");
            return r;
        }
    }

    // Nested-class construction on a class receiver with named arguments
    // (`Outer.Nested(x, field = y)`). The positional path constructs by
    // `newInstanceById`, which cannot honor the names — a primary-ctor
    // default skipped by a named argument would otherwise bind positionally.
    // Resolve the nested class the same way the positional path does and
    // construct it through the name-aware path. (A companion `invoke`
    // operator routes the call here rather than to a bare `NewInstance`.)
    if (any_named and receiver.* == .Class) {
        const cg = receiver.Class.borrow();
        const cname = cg.get().name;
        const cfqn = cg.get().fqn;
        cg.deinit();
        const mg = self.module.borrow();
        const mod = mg.get();
        var class_id: ?ir.ClassId = blk: {
            const rid = mod.classIdByFqn(cfqn) orelse mod.classId(cname) orelse break :blk null;
            break :blk mod.classIdNestedIn(rid, name);
        };
        if (class_id == null) {
            const fqn_probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cfqn, name });
            defer if (runtime.freeScratch()) allocator.free(fqn_probe);
            class_id = mod.classIdByFqn(fqn_probe);
        }
        mg.deinit();
        if (class_id) |cid| {
            return self.newInstanceNamed(allocator, cid, args, arg_names, null);
        }
    }

    // Named companion-member forwarding for a class receiver
    // (`StringValues.build(caseInsensitiveName = true) { … }`): resolve the
    // companion singleton and re-enter the named ladder on it, so a named
    // argument can skip a leading defaulted parameter. A miss on the
    // singleton falls through to the positional ladder exactly as before.
    if (any_named and receiver.* == .Class) {
        const cg2 = receiver.Class.borrow();
        const cls_name = cg2.get().name;
        const cls_fqn = cg2.get().fqn;
        cg2.deinit();
        var comp_name: ?[]const u8 = null;
        {
            const mg = self.module.borrow();
            defer mg.deinit();
            const comp = &mg.get().registry.companion_singletons;
            comp_name = comp.get(cls_name) orelse comp.get(cls_fqn) orelse comp.get(simpleName(cls_fqn));
        }
        if (comp_name) |cn| {
            const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                .ok => |maybe| maybe,
                .err => |e| return .{ .err = e },
            };
            if (singleton) |s| if (s == .Instance) {
                const r = try callMemberNamedInner(self, allocator, &s, name, args, arg_names, strict_ext, null, no_ext, null);
                if (!(r == .err and r.err == .Unimplemented)) return r;
                freeDispatchMiss(allocator, r);
            };
        }
    }

    // Named nested-class construction through an OBJECT qualifier
    // (`Object.Nested(field = y)`, e.g. `MaterialTheme.Values(typography = t)`):
    // the object's bare name lowered to its singleton value, so the receiver is
    // an `.Instance`, not a `.Class`. Honor the names here — the positional path
    // would bind a differently-ordered named-arg list to the wrong ctor params.
    if (any_named and receiver.* == .Instance) {
        const cid: ?ir.ClassId = blk: {
            const ig = receiver.Instance.borrow();
            defer ig.deinit();
            const icg = ig.get().class.borrow();
            defer icg.deinit();
            if (!host_globals.progHasObjectName(self, icg.get().name)) break :blk null;
            const mg = self.module.borrow();
            defer mg.deinit();
            const rid = mg.get().classIdByFqn(icg.get().fqn) orelse mg.get().classId(icg.get().name) orelse break :blk null;
            break :blk mg.get().classIdNestedIn(rid, name);
        };
        if (cid) |c| return self.newInstanceNamed(allocator, c, args, arg_names, null);
    }

    // Positional dispatch first.
    runtime.prof.opRoute(17);
    const primary = try callMemberInnerStatic(self, allocator, receiver, name, args, strict_ext, static_recv, no_ext, declared_recv);
    if (!(primary == .err and primary.err == .Unimplemented)) {
        // A NAMED call served by the positional fallback in its given
        // order: memoize the identity permutation so later calls of this
        // shape take the unified rewrite up front and skip the whole
        // named ladder (whose every arm just declined).
        if (any_named) ir.eval.callStatsProbe("<named-pos-hit>");
        // Any non-miss outcome (including thrown control flow — the
        // pausable machinery completes composable calls via throws)
        // proves the positional dispatch bound this order.
        if (any_named and receiver.* == .Instance and args.len <= 15) {
            if (namedOrderKey(self, receiver, name, args, arg_names)) |k| {
                var src: [15]u8 = @splat(0xFF);
                for (0..args.len) |i| src[i] = @intCast(i);
                const perm = root_mod.ProgramImage.NamedPerm{ .n = @intCast(args.len), .src = src };
                {
                    const pg = self.prog.borrowMut();
                    defer pg.deinit();
                    pg.get().named_perm_cache.put(k, perm) catch {};
                }
                caches.tl_perm_cache[tlSlot(k)] = .{ .class_p = k.class_p, .name_p = k.name_p, .n_args = k.n_args, .sig = k.sig, .raw_plus = 1, .gen = cacheGen(), .perm = perm };
            }
        }
        return primary;
    }
    runtime.prof.opRoute(18);

    // Class-hierarchy method walk for a class-qualified lowered name.
    if (receiver.* == .Instance) {
        const fallback = instanceMethodWalkNamed(self, allocator, receiver, name, args, null) catch |alloc_err| {
            freeDispatchMiss(allocator, primary);
            return alloc_err;
        };
        if (fallback) |r| {
            freeDispatchMiss(allocator, primary);
            return r;
        }
    }
    if (any_named) ir.eval.callStatsProbe("<named-miss>");
    // Compose ABI completion on the explicit `.invoke()` route — same
    // completion `callMember` applies (the two entries do not share a
    // miss tail).
    if (receiver.* == .Instance and std.mem.eql(u8, name, "invoke")) {
        if (compose.currentComposer()) |c| {
            if (instanceInvokeWantsPair(self, receiver, args.len)) {
                freeDispatchMiss(allocator, primary);
                var ext: std.ArrayList(Value) = .empty;
                defer ext.deinit(allocator);
                try ext.ensureTotalCapacityPrecise(allocator, args.len + 2);
                ext.appendSliceAssumeCapacity(args);
                ext.appendAssumeCapacity(c);
                ext.appendAssumeCapacity(.{ .Int = 0 });
                return callMemberInnerStatic(self, allocator, receiver, name, ext.items, strict_ext, static_recv, no_ext, declared_recv);
            }
        }
    }
    return primary;
}

pub fn copyNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var is_data = false;
    var n_params: usize = 0;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        is_data = cg.get().is_data;
        n_params = cg.get().primary_params.len;
        cg.deinit();
        g.deinit();
    }
    if (!is_data) return null;
    var slots = try allocator.alloc(?Value, n_params);
    defer allocator.free(slots);
    for (slots) |*s| s.* = null;
    var positional_idx: usize = 0;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        for (args, 0..) |a, i| {
            const named: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
            if (named) |arg_name| {
                for (cg.get().primary_params, 0..) |p, pos| {
                    if (std.mem.eql(u8, p.name, arg_name)) {
                        slots[pos] = a;
                        break;
                    }
                }
            } else {
                if (positional_idx < n_params) slots[positional_idx] = a;
                positional_idx += 1;
            }
        }
        cg.deinit();
        g.deinit();
    }
    var new_args: std.ArrayList(Value) = .empty;
    defer new_args.deinit(allocator);
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        for (cg.get().primary_params, 0..) |p, idx| {
            const v = slots[idx] orelse (g.get().get(p.name) orelse Value.Null);
            try new_args.append(allocator, v);
        }
        cg.deinit();
        g.deinit();
    }
    return try reconstructDataClass(self, allocator, inst, new_args.items);
}

pub fn stdlibNamedDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    const type_fqn = receiver.typeFqn();
    const probes = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_fqn, name }),
        try std.fmt.allocPrint(allocator, "kotlin.text.{s}", .{name}),
        try std.fmt.allocPrint(allocator, "kotlin.collections.{s}", .{name}),
        try std.fmt.allocPrint(allocator, "kotlin.{s}", .{name}),
    };
    // The probe keys are scratch for the lookup loop; free them on exit (a
    // per-stdlib-call leak on the ktor request path).
    defer if (runtime.freeScratch()) for (probes) |p| allocator.free(p);
    for (probes) |probe| {
        const params = stdlib.paramNames(probe) orelse continue;
        var slots = try allocator.alloc(?Value, params.len);
        defer allocator.free(slots);
        for (slots) |*s| s.* = null;
        var positionals: std.ArrayList(Value) = .empty;
        defer positionals.deinit(allocator);
        var shape_mismatch = false;
        for (args, 0..) |a, i| {
            const named: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
            if (named) |arg_name| {
                var matched = false;
                for (params, 0..) |p, pos| {
                    if (std.mem.eql(u8, p, arg_name)) {
                        slots[pos] = a;
                        matched = true;
                        break;
                    }
                }
                // A named argument this signature does not declare means the
                // call targets a DIFFERENT overload (the stdlib's internal
                // `indexOf(..., last = true)` reaching the public 3-param
                // table): silently dropping it truncated real arguments.
                if (!matched) shape_mismatch = true;
            } else {
                try positionals.append(allocator, a);
            }
        }
        if (shape_mismatch) continue;
        // Trailing lambda binds to the last parameter.
        if (positionals.items.len != 0) {
            const last = positionals.items[positionals.items.len - 1];
            if (last == .IrClosure and params.len != 0 and slots[params.len - 1] == null) {
                slots[params.len - 1] = positionals.pop();
            }
        }
        var pit: usize = 0;
        for (slots) |*slot| {
            if (slot.* == null) {
                if (pit < positionals.items.len) {
                    slot.* = positionals.items[pit];
                    pit += 1;
                } else break;
            }
        }
        // Positional arguments beyond this signature's parameter count mean
        // the call targets a different overload; dropping them truncated
        // real arguments (the internal indexOf's ignoreCase flag).
        if (pit < positionals.items.len) continue;
        var reordered: std.ArrayList(Value) = .empty;
        defer reordered.deinit(allocator);
        for (slots) |s| try reordered.append(allocator, s orelse Value.Null);
        while (reordered.items.len != 0 and reordered.items[reordered.items.len - 1] == .Null) {
            _ = reordered.pop();
        }
        if (lookupIntrinsic(self, probe)) |func| {
            const all_args = try prependReceiver(allocator, receiver, reordered.items);
            defer if (runtime.freeScratch()) allocator.free(all_args);
            return try dispatchIntrinsic(self, allocator, probe, func, all_args);
        }
        break;
    }
    return null;
}

pub fn userMethodNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    // An applicable member of the receiver's own class outranks every
    // extension (kotlinc: members win) — `buffer.write(bytes, startIndex =
    // …)` binds the `ByteArray` member, not the `ByteString` extension.
    if (receiver.* == .Instance) {
        if (try instanceMethodWalkNamed(self, allocator, receiver, name, args, arg_names)) |r| return r;
        // Class delegation with named arguments: a delegated interface
        // member (`class LayoutNodeDrawScope(...) : DrawScope by
        // canvasDrawScope` serving `drawRoundRect(brush = …, …)`) forwards
        // to the delegate with the names intact — the positional forward
        // later in the ladder scrambles the binding.
        if (try delegateForwardNamed(self, allocator, receiver, name, args, arg_names)) |r| return r;
    }
    if (resolveExtOverloadLocal(self, allocator, name, receiver, args, arg_names)) |fid| {
        const all = try prependReceiver(allocator, receiver, args);
        defer if (runtime.freeScratch()) allocator.free(all);
        var names = try allocator.alloc(?[]const u8, arg_names.len + 1);
        defer if (runtime.freeScratch()) allocator.free(names);
        names[0] = null;
        @memcpy(names[1..], arg_names);
        const mg = self.module.borrow();
        const mod = mg.get();
        // A member-extension's body has its declaring class's `this` in
        // lexical scope. Seed the callee frame with that owner instance,
        // exactly as `extensionFnFallback` does — without it a bare
        // sibling call inside the body (`placeApparentToRealOffset`
        // inside `PlacementScope`'s `placeWithLayer`) has no owner
        // candidate and misses.
        var pushed_owner = false;
        if (mod.registry.member_ext_owner_class.get(fid)) |owner| {
            if (try memberExtOwnerInstance(self, allocator, receiver, owner)) |inst| {
                ir.eval.pushEnclosing(&inst);
                pushed_owner = true;
            }
        }
        const r = try callFuncNamedRec(self, allocator, mod, fid, all, names);
        if (pushed_owner) ir.eval.popEnclosing();
        mg.deinit();
        return r;
    }
    return null;
}

/// Resolve the user extension/top-level fn an unqualified `recv.name(args)`
/// would dispatch to (same candidate selection as `extensionFnFallback`).
pub fn resolveExtOverloadLocal(self: *VmHost, allocator: Allocator, name: []const u8, receiver: *const Value, args: []const Value, arg_names: []const ?[]const u8) ?FuncId {
    var bound_thinned = false;
    const want = args.len + 1;
    var visible_owners = enclosingOwnerSet(self, allocator) catch return null;
    defer visible_owners.deinit();
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        for (mod.funcsBySimpleName(name)) |fid| {
            const f = funcAt(mod, fid) orelse continue;
            if (!(f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this"))) continue;
            // Shape gate with a vararg allowance: a vararg param absorbs
            // surplus positional args, so the declared param count may sit
            // below the supplied count.
            if (f.params.len < want) {
                var has_vararg = false;
                for (f.params) |*p| {
                    if (p.is_vararg) {
                        has_vararg = true;
                        break;
                    }
                }
                if (!has_vararg) continue;
            }
            if (privateFnHiddenHere(self, mod, fid)) {
                if (missTraceWant(name)) std.debug.print("[extlocal] {s}#{d} drop=private-hidden\n", .{ name, fid.int() });
                continue;
            }
            if (!memberExtVisible(self, mod, fid, &visible_owners)) {
                if (missTraceWant(name)) std.debug.print("[extlocal] {s}#{d} drop=owner-invisible\n", .{ name, fid.int() });
                continue;
            }
            // A candidate whose declared receiver definitely excludes this
            // runtime receiver is not applicable at all (kotlinc drops it):
            // `UIntArray.fill` never binds a plain `Array` receiver even when
            // no other overload survives the walk.
            if (receiverViolatesTypeParamBound(self, fid, &f.params[0].ty, receiver)) {
                bound_thinned = true;
                continue;
            }
            if (builtinReceiverDisproven(receiver, f.params[0].ty.name)) continue;
            if (argDefinitelyNotParamType(self, &f.params[0].ty, receiver)) continue;
            // Full applicability under the actual binding (kotlinc semantics):
            // each supplied name must hit a declared param, positional args
            // fill leading params (with the trailing-lambda rule), every
            // argument's type must be compatible with the param it binds, and
            // every unbound param must be defaulted/vararg. This subsumes the
            // bare "every name is a param" filter and, crucially, rejects an
            // overload whose positional slot takes an argument of the wrong
            // type — e.g. `produce(ctx, cap, onBufferOverflow, start = …,
            // block = …)` must not bind the 5-param `produce(ctx, cap, start,
            // onCompletion, block)` (the `BufferOverflow` would land in
            // `start: CoroutineStart`).
            if (!memberApplicableForWalkNamed(self, &f, args, arg_names)) continue;
            candidates.append(allocator, .{ .fid = fid, .func = f }) catch {};
        }
    }
    if (trace.enabled(name)) {
        for (candidates.items) |c| {
            const recv_ty = if (c.func.params.len > 0) c.func.params[0].ty.name else "?";
            trace.emit("extLocal cand fid={d} fqn={s} recv_ty={s} nparams={d}", .{ c.fid.int(), c.func.fqn, recv_ty, c.func.params.len });
        }
    }
    if (candidates.items.len == 0) return null;
    // A member of the receiver beats every extension: when bound
    // refutation THINNED this set, a sole survivor that used to lose a
    // tie must not newly commit past the member tail — the ranges
    // `contains` family's own `element != null && contains(element)`
    // re-entered itself exactly here.
    if (bound_thinned and receiverHasMemberNamed(self, receiver, name)) return null;
    if (candidates.items.len == 1) return candidates.items[0].fid;
    const chosen = scoreExtCandidates(self, allocator, receiver, candidates.items, args) catch return null;
    if (trace.enabled(name)) {
        if (chosen) |c| trace.emit("extLocal chose fid={d} fqn={s} recv_ty={s}", .{ c.fid.int(), c.func.fqn, c.func.params[0].ty.name });
    }
    return if (chosen) |c| c.fid else null;
}

/// Applicability for the class-hierarchy walk's name match: positional
/// fit (via `pickMethodOverload`'s single-candidate rules) or Kotlin's
/// trailing-lambda alignment — the trailing callable binds to the LAST
/// function-typed parameter with every skipped middle parameter
/// defaulted.
pub fn memberApplicableForWalk(self: *VmHost, f: *const Func, args: []const Value) bool {
    {
        const one = [_]Func{f.*};
        if (pickMethodOverload(self, null, &one, args) != null) return true;
    }
    if (args.len == 0) return false;
    const last_arg = args[args.len - 1];
    const trailing_callable = switch (last_arg) {
        .IrClosure, .BoundMethod, .Intrinsic => true,
        else => false,
    };
    if (!trailing_callable) return false;
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const effective = f.params[skip..];
    if (args.len > effective.len or effective.len == 0) return false;
    const last_ty = resolveAliasName(self, effective[effective.len - 1].ty.name);
    const last_is_fn = std.mem.startsWith(u8, last_ty, "Function") or
        std.mem.indexOf(u8, last_ty, "->") != null or
        (last_ty.len > 0 and last_ty.len <= 2 and allUppercase(last_ty));
    if (!last_is_fn) return false;
    // Leading args fill the leading params; the middle params between the
    // last positional arg and the trailing-lambda slot must be defaulted
    // (or varargs).
    const defaults = funcDefaults(self, f);
    var k: usize = args.len - 1;
    while (k + 1 < effective.len) : (k += 1) {
        if (!(effective[k].is_vararg or paramHasDefault(defaults, skip + k))) return false;
    }
    return true;
}

/// `memberApplicableForWalk` for a call that supplies argument names:
/// every supplied name must name a declared value parameter (kotlinc: a
/// candidate without the named param is not applicable), each argument is
/// checked against the parameter it would actually bind (by name when
/// named, by leading position otherwise), and every unbound parameter
/// must be defaulted or a vararg.
pub fn memberApplicableForWalkNamed(self: *VmHost, f: *const Func, args: []const Value, arg_names: ?[]const ?[]const u8) bool {
    const names = arg_names orelse return memberApplicableForWalk(self, f, args);
    var any_named = false;
    for (names) |n| {
        if (n != null) any_named = true;
    }
    if (!any_named) return memberApplicableForWalk(self, f, args);

    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const effective = f.params[skip..];
    var bound = [_]bool{false} ** 64;
    if (effective.len > bound.len) return memberApplicableForWalk(self, f, args);
    var positional: usize = 0;
    for (args, 0..) |*a, i| {
        const supplied_name: ?[]const u8 = if (i < names.len) names[i] else null;
        var param: ?*const ir.Param = null;
        if (supplied_name) |nm| {
            for (effective, 0..) |*p, k| {
                if (std.mem.eql(u8, p.name, nm)) {
                    // A named argument that targets a parameter already filled
                    // (by a leading positional argument) makes this overload
                    // inapplicable — kotlinc rejects the double binding. This
                    // is what distinguishes `produce(ctx, cap, onBufferOverflow,
                    // start = …)` from the 5-param `produce(ctx, cap, start,
                    // onCompletion, …)`, whose 3rd positional already fills
                    // `start` that `start = …` then re-targets.
                    if (bound[k]) return false;
                    param = p;
                    bound[k] = true;
                    break;
                }
            }
            if (param == null) {
                // A named argument that names no parameter is inapplicable —
                // the generated pair included, now that the pre-resolution
                // threading oracle is retired and a pair only reaches calls
                // whose resolved target (or completion probe) declares it.
                return false;
            }
        } else if (i == args.len - 1 and isCallable(a) and effective.len > 0 and
            !bound[effective.len - 1] and
            lastParamIsFunctionShaped(self, &effective[effective.len - 1]))
        {
            // Kotlin's trailing-lambda rule: the unnamed trailing callable
            // binds the LAST function-typed parameter (the middle gap must
            // be defaulted, which the unbound-parameter check below
            // enforces).
            param = &effective[effective.len - 1];
            bound[effective.len - 1] = true;
        } else {
            if (positional < effective.len) {
                param = &effective[positional];
                bound[positional] = true;
                // A vararg parameter absorbs this and every later unnamed
                // positional argument (Kotlin: params after a vararg bind
                // by name only), so the cursor stays on it.
                if (!effective[positional].is_vararg) positional += 1;
            } else if (effective.len == 0 or !effective[effective.len - 1].is_vararg) {
                return false;
            } else {
                positional += 1;
            }
        }
        if (param) |p| {
            if (!p.is_vararg and argDefinitelyNotParamType(self, &p.ty, a)) return false;
        }
    }
    const defaults = funcDefaults(self, f);
    for (effective, 0..) |*p, k| {
        if (bound[k] or p.is_vararg or paramHasDefault(defaults, skip + k)) continue;
        return false;
    }
    return true;
}

/// Score an applicable named-call candidate by summing each argument's type
/// match against the parameter it binds (positional or by name), mirroring
/// `memberApplicableForWalkNamed`'s arg→param mapping. Higher is a better fit;
/// an argument that only weakly matches (or is a wrong-but-not-disproven type
/// like a `Color` against a `Brush` parameter) contributes less, so the closer
/// overload wins. Used to break ties among same-named overloads of one class.
/// How many of `f`'s declared parameters the call leaves UNBOUND — the ones a
/// default (or an empty vararg) has to fill. Kotlin's specificity rule ranks a
/// candidate that needs no default-filling above one that does, which is what
/// separates two overloads whose parameter lists are otherwise a subset/superset
/// pair: `DrawScope.drawImage(…, blendMode)` and
/// `DrawScope.drawImage(…, blendMode, filterQuality)` both accept the same nine
/// named arguments, and the concrete one delegates BY NAME to the abstract one —
/// so picking the superset re-selected the caller itself and recursed forever.
pub fn unboundParamCount(f: *const Func, args: []const Value, arg_names: ?[]const ?[]const u8) usize {
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const effective = f.params[skip..];
    var bound = [_]bool{false} ** 64;
    if (effective.len > bound.len) return 0;
    var positional: usize = 0;
    for (args, 0..) |_, i| {
        const supplied_name: ?[]const u8 = if (arg_names) |ns| (if (i < ns.len) ns[i] else null) else null;
        if (supplied_name) |nm| {
            for (effective, 0..) |*p, k| {
                if (!bound[k] and std.mem.eql(u8, p.name, nm)) {
                    bound[k] = true;
                    break;
                }
            }
        } else {
            while (positional < effective.len and bound[positional]) positional += 1;
            if (positional < effective.len) {
                bound[positional] = true;
                positional += 1;
            }
        }
    }
    var n: usize = 0;
    for (effective, 0..) |*p, k| {
        if (!bound[k] and !p.is_vararg) n += 1;
    }
    return n;
}

pub fn scoreNamedMemberCandidate(
    self: *VmHost,
    allocator: Allocator,
    f: *const Func,
    args: []const Value,
    arg_names: ?[]const ?[]const u8,
) Allocator.Error!?i32 {
    const score = try runtimeMemberApplicability(self, allocator, f, args, arg_names, true);
    return if (score) |s| s.points else null;
}

/// Mirrors `memberApplicableForWalk`'s last-param shape test: a declared
/// function type, a typealias expanding to one, or a bare type parameter.
pub fn lastParamIsFunctionShaped(self: *VmHost, p: *const ir.Param) bool {
    const last_ty = resolveAliasName(self, p.ty.name);
    return std.mem.startsWith(u8, last_ty, "Function") or
        std.mem.indexOf(u8, last_ty, "->") != null or
        (last_ty.len > 0 and last_ty.len <= 2 and allUppercase(last_ty));
}

/// Member invocations the named walk currently has on the stack, as
/// (FuncId, receiver identity) pairs. An interface DEFAULT method whose body
/// delegates BY NAME to a sibling overload must not re-select ITSELF: klio's
/// class method table omits abstract members, so the walk sees only the default
/// and re-binds it, defaulting the parameter the sibling does not declare and
/// recursing forever (`DrawScope.drawImage(…, filterQuality)` delegating to the
/// abstract `drawImage(…, blendMode)` — every `Image` composable hung). Skipping
/// the in-flight frame lets the ladder continue to the class-delegate forward,
/// which is where the real override lives (`LayoutNodeDrawScope : DrawScope by
/// canvasDrawScope`). Bounded; overflow simply disables the guard for the excess.
pub threadlocal var walk_active: [64]struct { fid: u32, ident: usize } = undefined;
pub threadlocal var walk_active_len: usize = 0;

pub fn receiverIdent(v: *const Value) usize {
    return switch (v.*) {
        .Instance => |i| @intFromPtr(i.cell),
        else => 0,
    };
}

pub fn walkActive(fid: FuncId, ident: usize) bool {
    if (ident == 0) return false;
    for (walk_active[0..walk_active_len]) |e| {
        if (e.fid == fid.int() and e.ident == ident) return true;
    }
    return false;
}

/// ORDER key for the named-binding permutation map: unlike the resolution
/// key it folds NO arg-type signature — the binding ORDER is a pure
/// function of (class, name, arg count, name vector, per-arg callability):
/// names and positions drive the slot binding, and callability is the only
/// value property the trailing-lambda/compose-pair rules consult. The perm
/// serve REWRITES to a positional dispatch that re-resolves with the real
/// values, so overload selection never rides this key. This keys shapes
/// whose container-typed args make the full signature unbuildable — the
/// bulk of the named traffic.
pub fn namedOrderKey(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    var k = instanceMethodKeyScoped(self, receiver, name, &.{}, null, null) orelse return null;
    k.n_args = @intCast(args.len);
    var h = std.hash.Wyhash.init(0x1f83d9abfb41bd6b);
    for (args, 0..) |*a, i| {
        const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        var tag: u8 = 3;
        if (nm != null) {
            tag = 1;
        } else if (vmhost.host_call_func.callableForTrailing(self, a)) {
            tag = 2;
        }
        h.update((&tag)[0..1]);
        const p: usize = if (nm) |n| @intFromPtr(n.ptr) else 0;
        h.update(std.mem.asBytes(&p));
    }
    k.sig = h.final() ^ 0x0DDB_A11C_0FFE_E000;
    if (k.sig == 0) k.sig = 7;
    return k;
}

/// WALK key for the named hierarchy-walk memo: class/name identity plus
/// the RELAXED arg signature (see `methodArgSigRelaxed` — container kinds,
/// never null) and the name vector. Member overload sets are fully
/// discriminated at erasure granularity by the relaxed tags, so the pick
/// is a pure function of this key wherever the strict key would simply
/// have been unbuildable.
pub fn namedWalkKey(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    var k = instanceMethodKeyScoped(self, receiver, name, &.{}, null, null) orelse return null;
    k.n_args = @intCast(args.len);
    var h = std.hash.Wyhash.init(0xbe5466cf34e90c6c);
    const rs = methodArgSigRelaxed(self, args);
    h.update(std.mem.asBytes(&rs));
    for (arg_names) |n| {
        const pp: usize = if (n) |nn| @intFromPtr(nn.ptr) else 1;
        h.update(std.mem.asBytes(&pp));
    }
    k.sig = h.final() ^ 0xFACE_0FF5_1DE0_0DD5;
    if (k.sig == 0) k.sig = 9;
    return k;
}

/// Cache key for a NAMED member resolution: the positional key with the
/// arg-name vector folded in (names are module-interned, so pointer
/// identity keys them) and a salt so entries never collide with the
/// positional/extension entries sharing the map.
pub fn namedMethodKey(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    var k = instanceMethodKeyScoped(self, receiver, name, args, null, null) orelse return null;
    var h = std.hash.Wyhash.init(0x6a09e667f3bcc909);
    for (arg_names) |n| {
        const p: usize = if (n) |nn| @intFromPtr(nn.ptr) else 1;
        h.update(std.mem.asBytes(&p));
    }
    k.sig ^= h.final() ^ 0x517c_c1b7_2722_0a95;
    if (k.sig == 0) k.sig = 3;
    return k;
}

/// Compute the replayable arg→param permutation for a resolved NAMED call,
/// following exactly the safe subset of `callFuncNamed`'s binding (named
/// bind by parameter name, the trailing-lambda and compose-pair rules, the
/// positional walk) over the user params (`f.params[1..]`; the walk binds
/// the receiver at slot 0). Null when the shape needs the full binder —
/// varargs, defaults, over/under-application, duplicate names. Every
/// consulted fact is folded into the memo key (param list per fid, arg
/// tags via the sig, name vector via the names hash), so the permutation
/// is a pure function of the key.
pub fn namedBindPerm(self: *VmHost, f: *const ir.Func, args: []const Value, arg_names: []const ?[]const u8) ?root_mod.ProgramImage.NamedPerm {
    for (f.params) |*p| {
        if (p.is_vararg) return null;
    }
    if (f.params.len == 0) return null;
    const up = f.params[1..];
    if (up.len > 15 or args.len != up.len) return null;
    var src: [15]u8 = @splat(0xFF);
    var used: [15]bool = @splat(false);
    for (args, 0..) |_, i| {
        if (i >= arg_names.len) continue;
        const an = arg_names[i] orelse continue;
        var bound = false;
        for (up, 0..) |p, pos| {
            if (applicability.paramNameMatchesArg(p.name, an)) {
                if (src[pos] != 0xFF) return null;
                src[pos] = @intCast(i);
                used[i] = true;
                bound = true;
                break;
            }
        }
        if (!bound) return null;
    }
    var trailing: ?usize = null;
    if (args.len > 0 and up.len > 0) {
        const last = args.len - 1;
        const last_named = last < arg_names.len and arg_names[last] != null;
        const lp = up.len - 1;
        if (!last_named and src[lp] == 0xFF and root_mod.isFunctionType(&up[lp].ty) and
            vmhost.host_call_func.callableForTrailing(self, &args[last]))
        {
            src[lp] = @intCast(last);
            used[last] = true;
            trailing = last;
        }
        if (trailing == null and args.len >= 3 and up.len >= 3) {
            const ci = args.len - 2;
            const bi = args.len - 3;
            const cn = if (ci < arg_names.len) arg_names[ci] else null;
            const gn = if (last < arg_names.len) arg_names[last] else null;
            const bn = if (bi < arg_names.len) arg_names[bi] else null;
            const upos = up.len - 3;
            if (cn != null and gn != null and bn == null and
                std.mem.eql(u8, cn.?, "$composer") and
                std.mem.eql(u8, gn.?, "$changed") and
                std.mem.eql(u8, up[up.len - 2].name, "$composer") and
                std.mem.eql(u8, up[up.len - 1].name, "$changed") and
                src[upos] == 0xFF and
                root_mod.isFunctionType(&up[upos].ty) and
                vmhost.host_call_func.callableForTrailing(self, &args[bi]))
            {
                src[upos] = @intCast(bi);
                used[bi] = true;
                trailing = bi;
            }
        }
    }
    var positional_idx: usize = 0;
    for (args, 0..) |_, i| {
        if (used[i]) continue;
        if (i < arg_names.len and arg_names[i] != null) continue;
        while (positional_idx < up.len and src[positional_idx] != 0xFF) positional_idx += 1;
        if (positional_idx >= up.len) return null;
        src[positional_idx] = @intCast(i);
        positional_idx += 1;
    }
    var seen_gap = false;
    for (up, 0..) |_, pos| {
        if (src[pos] == 0xFF) {
            // A TRAILING unfilled param defaults at invocation (the
            // positional invoker's binding fills it); an interior gap
            // cannot be expressed positionally and keeps the named path.
            src[pos] = 0xFE;
            seen_gap = true;
        } else if (seen_gap) {
            return null;
        }
    }
    return .{ .n = @intCast(up.len), .src = src };
}

/// Serve a memoized named-member resolution: replay the cached binding
/// permutation as a positional dispatch when one exists (or can be
/// computed and cached), else run the full named terminal. The
/// self-delegation guard brackets both dispatches, exactly as the walk's
/// own terminal pushes it.
pub fn serveNamedFid(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, fid: FuncId, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    // Perm entries live under the ORDER key (see `namedOrderKey`), shared
    // with the unified rewrite's probe.
    const key = namedOrderKey(self, receiver, name, args, arg_names) orelse
        return try invokeMethodNamedFid(self, allocator, receiver, fid, args, arg_names);
    // Thread-local L1 over the perm map (same rationale as
    // `tl_method_cache`: the shared reader lock's cache-line traffic).
    var perm: ?root_mod.ProgramImage.NamedPerm = null;
    const tslot = &caches.tl_perm_cache[tlSlot(key)];
    if (tslot.raw_plus != 0 and tslot.gen == cacheGen() and tslot.class_p == key.class_p and tslot.name_p == key.name_p and
        tslot.sig == key.sig and tslot.n_args == key.n_args)
    {
        perm = tslot.perm;
    }
    if (perm == null) {
        perm = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().named_perm_cache.get(key);
        };
        if (perm) |p| {
            tslot.* = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .raw_plus = 1, .gen = cacheGen(), .perm = p };
        }
    }
    if (perm == null) {
        const computed: ?root_mod.ProgramImage.NamedPerm = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const f = mg.get().funcById(fid) orelse break :blk null;
            break :blk namedBindPerm(self, f, args, arg_names);
        };
        const store = computed orelse root_mod.ProgramImage.NamedPerm{ .n = 0xFF, .src = @splat(0xFF) };
        {
            const pg = self.prog.borrowMut();
            defer pg.deinit();
            pg.get().named_perm_cache.put(key, store) catch {};
        }
        tslot.* = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .raw_plus = 1, .perm = store };
        perm = store;
    }
    if (perm.?.n != 0xFF) {
        const p = perm.?;
        var buf: [15]Value = undefined;
        var m: usize = 0;
        while (m < p.n and p.src[m] != 0xFE) : (m += 1) buf[m] = args[p.src[m]];
        const ident = receiverIdent(receiver);
        const pushed = ident != 0 and walk_active_len < walk_active.len;
        if (pushed) {
            walk_active[walk_active_len] = .{ .fid = @intCast(fid.int()), .ident = ident };
            walk_active_len += 1;
        }
        const r = try invokeMethodFuncId(self, allocator, receiver, fid, buf[0..m]);
        if (pushed) walk_active_len -= 1;
        if (r) |rr| return rr;
    }
    return try invokeMethodNamedFid(self, allocator, receiver, fid, args, arg_names);
}

/// The named walk's invoke terminal, shared by the walk and its memo serve:
/// `[receiver] ++ args` with a null-shifted name vector, the self-delegation
/// guard pushed, dispatched through the named caller.
pub fn invokeMethodNamedFid(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, args: []const Value, arg_names: ?[]const ?[]const u8) Allocator.Error!?EvalResult {
    ir.eval.dispatchNote(.served_user_body);
    const all = try prependReceiver(allocator, receiver, args);
    defer if (runtime.freeScratch()) allocator.free(all);
    var names = try allocator.alloc(?[]const u8, all.len);
    defer if (runtime.freeScratch()) allocator.free(names);
    names[0] = null;
    if (arg_names) |an| {
        for (an, 0..) |n, i| {
            if (i + 1 < names.len) names[i + 1] = n;
        }
        var k = an.len + 1;
        while (k < names.len) : (k += 1) names[k] = null;
    } else {
        var k: usize = 1;
        while (k < names.len) : (k += 1) names[k] = null;
    }
    const mg = self.module.borrow();
    const mod = mg.get();
    const ident = receiverIdent(receiver);
    const pushed = ident != 0 and walk_active_len < walk_active.len;
    if (pushed) {
        walk_active[walk_active_len] = .{ .fid = @intCast(fid.int()), .ident = ident };
        walk_active_len += 1;
    }
    const r = try callFuncNamedRec(self, allocator, mod, fid, all, names);
    if (pushed) walk_active_len -= 1;
    mg.deinit();
    return r;
}

pub fn instanceMethodWalkNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: ?[]const ?[]const u8) Allocator.Error!?EvalResult {
    // Memo serve for both the named path and the positional fallback: a
    // prior completed walk's pick (or confirmed miss) short-circuits the
    // whole hierarchy traversal. The self-delegation guard is re-checked
    // at serve time; an active entry declines to the full walk, whose
    // fills are vetoed while the guard filters.
    if (namedWalkKey(self, receiver, name, args, arg_names orelse &.{})) |k| {
        if (extMethodCacheGet(self, k)) |raw| {
            if (raw == METHOD_MISS) return null;
            const fid: FuncId = @enumFromInt(raw);
            if (!walkActive(fid, receiverIdent(receiver))) {
                return try serveNamedFid(self, allocator, receiver, name, fid, args, arg_names orelse &.{});
            }
        }
    }
    const inst = receiver.Instance;
    var start_name: []const u8 = undefined;
    var recv_fqn: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        start_name = cg.get().name;
        recv_fqn = cg.get().fqn;
        cg.deinit();
        g.deinit();
    }
    const WalkItem = struct { cid: ?ir.ClassId, name: []const u8, hint: []const u8 = "" };
    var queue: std.ArrayList(WalkItem) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    // Walk the receiver's real class hierarchy by identity (IR class ids),
    // starting from its exact FQN, so a same-simple-name class in another
    // package can never shadow an inherited method.
    const start_cid: ?ir.ClassId = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classIdByFqn(recv_fqn);
    };
    try queue.append(allocator, .{ .cid = start_cid, .name = start_name });
    var method_fid: ?FuncId = null;
    var walk_active_skipped = false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const item = queue.items[head];
        var ir_class: ?ir.Class = null;
        {
            const mg = self.module.borrow();
            defer mg.deinit();
            const mod = mg.get();
            if (item.cid) |cid| {
                if (@intFromEnum(cid) < mod.classes.items.len) ir_class = mod.classes.items[@intFromEnum(cid)];
            }
            if (ir_class == null) {
                if (classByNamePreferring(mod, item.name, item.hint)) |hit| {
                    ir_class = hit.cls;
                }
            }
            // Dedup on the resolved class's FQN (identity) so two distinct
            // classes that share a simple name are each walked once.
            const dedup_key = if (ir_class) |irc| irc.fqn else item.name;
            if (seen.contains(dedup_key)) continue;
            try seen.put(dedup_key, {});
            if (ir_class) |irc| {
                if (nuTraceEnv()) |want| {
                    if (std.mem.eql(u8, want, name)) {
                        std.debug.print("[mwalk-class] {s} methods={d} supers=", .{ irc.fqn, irc.methods.len });
                        for (irc.supertypes, 0..) |sid, si| {
                            if (si != 0) std.debug.print(",", .{});
                            if (@intFromEnum(sid) < mod.classes.items.len) {
                                std.debug.print("{s}", .{mod.classes.items[@intFromEnum(sid)].fqn});
                            } else {
                                std.debug.print("#{d}", .{@intFromEnum(sid)});
                            }
                        }
                        std.debug.print("\n", .{});
                    }
                }
                // Among the applicable same-named overloads declared by THIS
                // class, pick the best by argument-type score — not merely the
                // first. Two overloads that differ only in one parameter's type
                // (`drawRoundRect(color: Color, …)` vs `(brush: Brush, …)`) are
                // both "applicable" when neither arg is provably wrong-typed, so
                // taking the first would bind the wrong one and scramble the
                // trailing defaulted parameters.
                var best_score: i32 = std.math.minInt(i32);
                var best_unbound: usize = std.math.maxInt(usize);
                for (irc.methods) |fid| {
                    if (funcAt(mod, fid)) |f| {
                        if (std.mem.eql(u8, f.name, name) or std.mem.eql(u8, simpleName(f.name), name)) {
                            if (nuTraceEnv()) |want| {
                                if (std.mem.eql(u8, want, name)) {
                                    const defaults = funcDefaults(self, &f);
                                    std.debug.print("[mwalk] class={s} fid={d} params=", .{ irc.fqn, fid.int() });
                                    for (f.params, 0..) |p, pi| {
                                        if (pi != 0) std.debug.print(",", .{});
                                        std.debug.print("{s}{s}", .{ p.name, if (paramHasDefault(defaults, pi)) "=" else "" });
                                    }
                                    std.debug.print("\n", .{});
                                }
                            }
                            // A member EXTENSION found among the class's own
                            // methods binds the dispatch receiver as its
                            // EXTENSION receiver (params[0]). When the receiver
                            // is only the owner/dispatch instance and provably
                            // not the declared extension-receiver type, the
                            // direct bind is wrong: the call resolves through the
                            // extension path (owner from the enclosing `this`,
                            // extension receiver from an outer implicit receiver).
                            // Skip it so this walk does not mis-bind the owner as
                            // the extension receiver.
                            if (isMemberExt(mod, fid) and f.params.len > 0 and
                                std.mem.eql(u8, f.params[0].name, "this") and
                                receiverDefinitelyNotParam(self, &f.params[0].ty, receiver)) continue;
                            // A name match alone is not a candidate:
                            // the member must be *applicable* to the
                            // supplied args (an unsupplied param needs
                            // a default or vararg slot, a named arg
                            // needs a matching param, a typed arg must
                            // not definitely mismatch), or Kotlin
                            // resolution moves on to the next tier.
                            // Already executing this exact method on this exact
                            // receiver: re-selecting it is the self-delegation
                            // loop described on `walk_active`. Decline, so the
                            // ladder reaches the class-delegate forward.
                            if (walkActive(fid, receiverIdent(receiver))) {
                                walk_active_skipped = true;
                                continue;
                            }
                            if (memberApplicableForWalkNamed(self, &f, args, arg_names)) {
                                const sc = (try scoreNamedMemberCandidate(self, allocator, &f, args, arg_names)) orelse continue;
                                // Argument types decide first; a tie goes to the
                                // MORE SPECIFIC signature — the one leaving fewer
                                // parameters for defaults to fill.
                                const ub = unboundParamCount(&f, args, arg_names);
                                if (method_fid == null or sc > best_score or
                                    (sc == best_score and ub < best_unbound))
                                {
                                    method_fid = fid;
                                    best_score = sc;
                                    best_unbound = ub;
                                }
                            }
                        }
                    }
                }
                if (method_fid == null) {
                    // Enqueue resolved supertypes by identity so the walk
                    // follows the real hierarchy, never a same-simple-name
                    // impostor.
                    for (irc.supertypes) |sid| {
                        if (@intFromEnum(sid) < mod.classes.items.len) {
                            try queue.append(allocator, .{ .cid = sid, .name = mod.classes.items[@intFromEnum(sid)].name });
                        }
                    }
                }
            }
        }
        if (method_fid != null) break;
        // Fallback for a receiver class with no unambiguous IR id (anonymous/
        // synthesized): expand supertypes from the registered simple names.
        if (ir_class == null) {
            const cg = self.classes.borrow();
            if (cg.get().get(item.name)) |def| {
                const dg = def.borrow();
                for (dg.get().supertype_names) |sn| try queue.append(allocator, .{ .cid = null, .name = sn, .hint = dg.get().fqn });
                dg.deinit();
            }
            cg.deinit();
        }
    }
    if (method_fid) |fid| {
        // Memoize the pick so later named calls of this exact shape skip
        // the hierarchy walk and the overload scoring; the serve replays
        // this same terminal (self-delegation guard included). Only a
        // non-active resolution memoizes — an entry picked while the
        // `walk_active` guard filtered a candidate is context-dependent.
        if (!walk_active_skipped) {
            if (namedWalkKey(self, receiver, name, args, arg_names orelse &.{})) |k| {
                extMethodCachePut(self, k, @intFromEnum(fid));
            }
        }
        return try invokeMethodNamedFid(self, allocator, receiver, fid, args, arg_names);
    }
    // A completed walk with no applicable method is a stable verdict for
    // this (class, name, shape) too; memoize the miss so the ladder's
    // fallback stops re-walking the hierarchy per call.
    if (!walk_active_skipped) {
        if (namedWalkKey(self, receiver, name, args, arg_names orelse &.{})) |k| {
            extMethodCachePut(self, k, METHOD_MISS);
        }
    }
    return null;
}
