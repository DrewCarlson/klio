//! The static-member tail: `callMemberInnerStatic`, the ladder every non-flat
//! member call walks, plus the dispatch-miss trace surface.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const applicability = @import("applicability");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const VmHost = vmhost.VmHost;
const persistent_map_eq = @import("../persistent_map_eq.zig");
const persistent_list_eq = @import("../persistent_list_eq.zig");
const persistent_list_mut = @import("../persistent_list_mut.zig");
const persistent_map_mut = @import("../persistent_map_mut.zig");
const host_call_func = @import("../host_call_func.zig");
const host_call_value = @import("../host_call_value.zig");
const host_fields = @import("../host_fields.zig");
const compose = @import("../compose.zig");
const builtin_members = @import("../builtin_members.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const DelegateKind = runtime.DelegateKind;
const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;
const arrayShapeOps = builtin_members.arrayShapeOps;
const builtinIterator = builtin_members.builtinIterator;
const captureModCount = builtin_members.captureModCount;
const collectionMutators = builtin_members.collectionMutators;
const comparatorMember = builtin_members.comparatorMember;
const componentMembers = builtin_members.componentMembers;
const dataClassAutoMembers = builtin_members.dataClassAutoMembers;
const drainIterableToList = builtin_members.drainIterableToList;
const hashWithDispatch = builtin_members.hashWithDispatch;
const iteratorMember = builtin_members.iteratorMember;
const mapContainsKeyEq = builtin_members.mapContainsKeyEq;
const materialiseRangeItems = builtin_members.materialiseRangeItems;
const materializeUserMap = builtin_members.materializeUserMap;
const rangeIterMember = builtin_members.rangeIterMember;
const seqIterMember = builtin_members.seqIterMember;
const sequenceMember = builtin_members.sequenceMember;
const sortedInstances = builtin_members.sortedInstances;

const applicability_probe = @import("applicability_probe.zig");
const rangeContainsArgKindMatches = applicability_probe.rangeContainsArgKindMatches;

const binding_probe = @import("binding_probe.zig");
const classCompanionAndEnum = binding_probe.classCompanionAndEnum;
const delegateMember = binding_probe.delegateMember;
const enclosingAnonMemberExtDispatch = binding_probe.enclosingAnonMemberExtDispatch;
const enclosingNamedMemberExtDispatch = binding_probe.enclosingNamedMemberExtDispatch;
const enclosingSamLambdaDispatch = binding_probe.enclosingSamLambdaDispatch;
const enclosingSamMemberExtDispatch = binding_probe.enclosingSamMemberExtDispatch;
const eqIgnoreCase = binding_probe.eqIgnoreCase;
const extWithThisLongerThanArgs = binding_probe.extWithThisLongerThanArgs;
const instanceBindingProbe = binding_probe.instanceBindingProbe;
const isBuiltinScalar = binding_probe.isBuiltinScalar;
const isCallableOrIntrinsic = binding_probe.isCallableOrIntrinsic;
const lookupGlobalValue = binding_probe.lookupGlobalValue;
const samInstanceDispatch = binding_probe.samInstanceDispatch;
const samMemberExtOnCallable = binding_probe.samMemberExtOnCallable;

const caches = @import("caches.zig");
const METHOD_MISS = caches.METHOD_MISS;
const extMethodCacheGet = caches.extMethodCacheGet;
const instanceMethodCacheGetRaw = caches.instanceMethodCacheGetRaw;

const ext_fallback = @import("ext_fallback.zig");
const classCompanionForward = ext_fallback.classCompanionForward;
const extensionFnFallback = ext_fallback.extensionFnFallback;
const instanceCompanionFallback = ext_fallback.instanceCompanionFallback;
const localClassCompanionForward = ext_fallback.localClassCompanionForward;

const flat_call = @import("flat_call.zig");
const builtinIntrinsicReplay = flat_call.builtinIntrinsicReplay;
const cacheServesExecutingFrame = flat_call.cacheServesExecutingFrame;
const callMember = flat_call.callMember;
const callableFieldArity = flat_call.callableFieldArity;
const cloneItemsList = flat_call.cloneItemsList;
const dispatchWithReceiver = flat_call.dispatchWithReceiver;
const isArrayContentFn = flat_call.isArrayContentFn;
const listOf = flat_call.listOf;
const prependReceiver = flat_call.prependReceiver;
const provideDelegateFor = flat_call.provideDelegateFor;
const receiverHasMemberNamed = flat_call.receiverHasMemberNamed;
const recvFnFieldInvoke = flat_call.recvFnFieldInvoke;
const recvFnPropHeadOf = flat_call.recvFnPropHeadOf;
const recvFnReceiverFor = flat_call.recvFnReceiverFor;
const routeTraceOn = flat_call.routeTraceOn;
const varargShadowedFieldInvoke = flat_call.varargShadowedFieldInvoke;

const hcm = @import("../host_call_member.zig");
const boolVal = hcm.boolVal;
const callFuncRec = hcm.callFuncRec;
const callMemberRec = hcm.callMemberRec;
const callValueRec = hcm.callValueRec;
const closurePairTailed = hcm.closurePairTailed;
const dispatchIntrinsic = hcm.dispatchIntrinsic;
const isNumericValue = hcm.isNumericValue;
const lookupIntrinsic = hcm.lookupIntrinsic;
const mapRuntimeError = hcm.mapRuntimeError;
const newInstanceById = hcm.newInstanceById;
const numericOpMethod = hcm.numericOpMethod;
const simpleName = hcm.simpleName;
const staticReceiverBindingHead = hcm.staticReceiverBindingHead;
const strVal = hcm.strVal;
const throwExc = hcm.throwExc;
const unimplemented = hcm.unimplemented;

const member_ext_visibility = @import("member_ext_visibility.zig");
const delegateForward = member_ext_visibility.delegateForward;
const interfaceDelegateFor = member_ext_visibility.interfaceDelegateFor;

const member_presence = @import("member_presence.zig");
const companionWithMember = member_presence.companionWithMember;
const hostHasMember = member_presence.hostHasMember;
const popAccessEnclosing = member_presence.popAccessEnclosing;
const pushAccessEnclosing = member_presence.pushAccessEnclosing;

const member_ref_super = @import("member_ref_super.zig");
const companionOwnerClassValue = member_ref_super.companionOwnerClassValue;
const receiverPropCanHoldCallable = member_ref_super.receiverPropCanHoldCallable;
const serializerForClassTarget = member_ref_super.serializerForClassTarget;

const named_call = @import("named_call.zig");
const callMemberNamed = named_call.callMemberNamed;

const receiver_probe = @import("receiver_probe.zig");
const enclosingCallableProperty = receiver_probe.enclosingCallableProperty;
const fakeOverrideInheritedDefault = receiver_probe.fakeOverrideInheritedDefault;
const isCallable = receiver_probe.isCallable;
const receiverImplementsType = receiver_probe.receiverImplementsType;

const reflect_anon = @import("reflect_anon.zig");
const anonMethodDispatch = reflect_anon.anonMethodDispatch;
const boundRefDispatch = reflect_anon.boundRefDispatch;
const funcAt = reflect_anon.funcAt;
const kclassMembers = reflect_anon.kclassMembers;
const kfunctionReflection = reflect_anon.kfunctionReflection;
const propertyRefDispatch = reflect_anon.propertyRefDispatch;
const topLevelPropertyGet = reflect_anon.topLevelPropertyGet;

const resolve_method = @import("resolve_method.zig");
const typeHeadLast = resolve_method.typeHeadLast;

const stdlib_tail = @import("stdlib_tail.zig");
const anyInstanceFallback = stdlib_tail.anyInstanceFallback;
const instanceImplementsCharSequence = stdlib_tail.instanceImplementsCharSequence;
const instanceImplementsSequence = stdlib_tail.instanceImplementsSequence;
const irMethodWalk = stdlib_tail.irMethodWalk;
const samIterableInstance = stdlib_tail.samIterableInstance;
const sequenceExtBodyFid = stdlib_tail.sequenceExtBodyFid;
const stdlibMemberDispatch = stdlib_tail.stdlibMemberDispatch;
const throwableStackMember = stdlib_tail.throwableStackMember;
const throwableSuppressedMember = stdlib_tail.throwableSuppressedMember;

const virtual_tail = @import("virtual_tail.zig");
const instanceMethodKeyRelaxed = virtual_tail.instanceMethodKeyRelaxed;
const instanceMethodKeyScoped = virtual_tail.instanceMethodKeyScoped;
const invokeMethodFuncId = virtual_tail.invokeMethodFuncId;

pub fn callMemberInnerStatic(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8, no_ext: bool, declared_recv: ?[]const u8) Allocator.Error!EvalResult {
    // A callable reference's `equals`/`hashCode` follow reference equality.
    if (receiver.* == .IrClosure or receiver.* == .PropertyRef) {
        if (args.len == 1 and std.mem.eql(u8, name, "equals")) {
            const eq = if (args[0] == .IrClosure or args[0] == .PropertyRef) try builtin_members.deepValueEquals(self, allocator, receiver, &args[0]) else false;
            return .{ .ok = boolVal(eq) };
        }
        if (args.len == 0 and std.mem.eql(u8, name, "hashCode")) {
            return .{ .ok = Value.newInt(@as(i64, try builtin_members.hashWithDispatch(self, allocator, receiver))) };
        }
    }
    // Delegated-property creation convention; a dispatch miss keeps the delegate.
    if (args.len == 2 and name.len == "$provideDelegate".len and name[0] == '$' and std.mem.eql(u8, name, "$provideDelegate")) {
        return provideDelegateFor(self, allocator, args[0], args[1], receiver.*);
    }
    // Persistent map and list equality, answered host-side; bails for unowned operands.
    if (args.len == 1 and receiver.* == .Instance and args[0] == .Instance and
        std.mem.eql(u8, name, "equals"))
    {
        if (persistent_map_eq.tryEquals(receiver.Instance, args[0].Instance)) |eq| {
            return .{ .ok = .{ .Bool = eq } };
        }
        if (persistent_list_eq.tryEquals(receiver.Instance, args[0].Instance)) |eq| {
            return .{ .ok = .{ .Bool = eq } };
        }
    }
    // Persistent-vector scans walk the leaf arrays directly.
    if (args.len == 1 and receiver.* == .Instance and
        (std.mem.eql(u8, name, "contains") or std.mem.eql(u8, name, "indexOf")))
    {
        if (persistent_list_eq.tryIndexOf(receiver.Instance, &args[0])) |idx| {
            if (name.len == 8) return .{ .ok = .{ .Bool = idx >= 0 } };
            return .{ .ok = Value.newInt(idx) };
        }
    }
    // Persistent-vector builder bulk ops (persistent_list_mut.zig).
    if (args.len == 2 and receiver.* == .Instance and std.mem.eql(u8, name, "removeRange")) {
        if (try persistent_list_mut.tryRemoveRange(allocator, receiver.Instance, &args[0], &args[1])) |v| {
            return .{ .ok = v };
        }
    }
    if (args.len == 1 and receiver.* == .Instance and std.mem.eql(u8, name, "addAll")) {
        if (try persistent_list_mut.tryAddAll(allocator, receiver.Instance, &args[0])) |v| {
            return .{ .ok = v };
        }
    }
    // Persistent-map builder ops (persistent_map_mut.zig).
    if (receiver.* == .Instance and persistent_map_mut.isBuilderClass(receiver.Instance)) {
        if (args.len == 2 and std.mem.eql(u8, name, "put")) {
            if (try persistent_map_mut.tryPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
                return .{ .ok = v };
            }
        }
        if (args.len == 0 and std.mem.eql(u8, name, "build")) {
            if (try persistent_map_mut.tryBuild(self, allocator, receiver.Instance)) |v| {
                return .{ .ok = v };
            }
        }
    }
    if (args.len == 0 and receiver.* == .Instance and std.mem.eql(u8, name, "builder")) {
        if (try persistent_map_mut.tryBuilder(self, allocator, receiver.Instance)) |v| {
            return .{ .ok = v };
        }
    }
    if (args.len == 2 and receiver.* == .Instance and std.mem.eql(u8, name, "put") and
        persistent_map_mut.isSnapshotMapClass(receiver.Instance))
    {
        if (try persistent_map_mut.trySnapshotMapPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
            return .{ .ok = v };
        }
    }

    if (receiver.* != .Instance and !strict_ext and !no_ext and static_recv == null and declared_recv == null) {
        if (try builtinIntrinsicReplay(self, allocator, receiver, name, args)) |r| {
            _ = flat_call.replay_hits.fetchAdd(1, .monotonic);
            return r;
        }
    }
    // A receiver-function-typed property runs with the owning instance as `this`.
    if (try recvFnFieldInvoke(self, allocator, receiver, name, args)) |r| return r;
    // Invoke a vararg-shadowed function-typed property when the arg shape matches.
    if (try varargShadowedFieldInvoke(self, allocator, receiver, name, args)) |r| return r;
    // A member of a `by`-delegated interface the class does not override is the
    // delegate's, even when the interface supplies a default the ladder reaches first.
    if (receiver.* == .Instance and !strict_ext and !no_ext) {
        if (interfaceDelegateFor(self, allocator, receiver.Instance, name)) |d| {
            const r = try callMemberRec(self, allocator, &d, name, args);
            switch (r) {
                .ok => return r,
                .err => |e| if (e != .Unimplemented) return r else freeDispatchMiss(allocator, r),
            }
        }
    }
    runtime.prof.opRoute(15);

    // Fast path: a resolved user instance method bypasses the probe ladder.
    // `irMethodWalk` fills the cache only after the binding probe and every builtin
    // check declined, decisions that are a pure function of (class, name). The key
    // folds in `static_recv` but not `declared_recv`, which only directs extensions.
    if (receiver.* == .Instance) {
        const head_strict = instanceMethodKeyScoped(self, receiver, name, args, static_recv, null);
        if (head_strict == null) {
            // Container-typed args probe the member cache under the relaxed key.
            if (instanceMethodKeyRelaxed(self, receiver, name, args, static_recv)) |rk| {
                if (instanceMethodCacheGetRaw(self, rk)) |raw| {
                    if (raw != METHOD_MISS and !cacheServesExecutingFrame(raw)) {
                        if (routeTraceOn(name)) std.debug.print("[route] L4083\n", .{});
                        if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(raw), args)) |r| return r;
                    }
                }
            }
        }
        if (head_strict) |k| {
            if (instanceMethodCacheGetRaw(self, k)) |raw| {
                if (raw != METHOD_MISS and !cacheServesExecutingFrame(raw)) {
                    if (routeTraceOn(name)) std.debug.print("[route] L4092\n", .{});
                    if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(raw), args)) |r| return r;
                }
                // A cached miss falls through to the probe ladder; the walk is skipped.
            }
            // A member miss that resolved to a top-level extension dispatches here,
            // under the same scope-folded key `extensionFnFallback` caches it under.
            if (!strict_ext and !no_ext and static_recv == null and declared_recv == null) {
                if (extMethodCacheGet(self, k)) |fid| {
                    // A top-level extension's `param[0]` is its receiver; the invoker binds it first.
                    if (fid != METHOD_MISS and !cacheServesExecutingFrame(fid)) {
                        if (routeTraceOn(name)) std.debug.print("[route] L4111\n", .{});
                        if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(fid), args)) |r| return r;
                    }
                }
            } else if (!strict_ext and !no_ext) {
                if (instanceMethodKeyScoped(self, receiver, name, args, static_recv, declared_recv)) |k2| {
                    if (extMethodCacheGet(self, k2)) |fid| {
                        if (fid != METHOD_MISS and !cacheServesExecutingFrame(fid)) {
                            if (routeTraceOn(name)) std.debug.print("[route] L4118\n", .{});
                            if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(fid), args)) |r| return r;
                        }
                    }
                }
            }
        }
    }
    // A non-Instance receiver keyable by identity serves its cached top-level
    // extension too: the cache fills only after every arm below declined.
    if (receiver.* != .Instance and !strict_ext and !no_ext) {
        if (instanceMethodKeyScoped(self, receiver, name, args, static_recv, declared_recv)) |k| {
            if (extMethodCacheGet(self, k)) |fid| {
                if (fid != METHOD_MISS and !cacheServesExecutingFrame(fid)) {
                    if (routeTraceOn(name)) std.debug.print("[route] L4133\n", .{});
                    if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(fid), args)) |r| return r;
                }
            }
        }
    }

    if (try throwableStackMember(self, allocator, receiver, name, args)) |r| return r;

    if (try throwableSuppressedMember(self, allocator, receiver, name, args)) |r| return r;

    if (receiver.* == .Delegate) {
        if (try delegateMember(self, allocator, receiver.Delegate, name, args)) |r| return r;
    }

    if (receiver.* == .Instance) {
        if (routeTraceOn(name)) std.debug.print("[route] L4156\n", .{});
        if (try instanceBindingProbe(self, allocator, receiver, name, args)) |r| return r;
    }

    // `kotlin.concurrent.Thread` handle members.
    if (receiver.* == .BoundMethod) {
        const bm = receiver.BoundMethod;
        if (std.mem.eql(u8, bm.fqn, "kotlin.concurrent.Thread")) {
            const id: u64 = switch (bm.receiver.asPtr().*) {
                .Long => |v| @bitCast(v),
                else => 0,
            };
            if (std.mem.eql(u8, name, "join")) {
                switch (vmhost.host_impl.joinSpawned(self, id)) {
                    .ok => return .{ .ok = .Unit },
                    .err => |e| return .{ .err = try mapRuntimeError(allocator, e) },
                }
            } else if (std.mem.eql(u8, name, "isAlive")) {
                return .{ .ok = boolVal(vmhost.host_impl.threadAlive(self, id)) };
            } else if (std.mem.eql(u8, name, "name")) {
                // A dispatcher pool worker reports its registered name.
                if (runtime.threadName(allocator, id)) |overridden| {
                    return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, overridden) } };
                }
                const s = try std.fmt.allocPrint(allocator, "klio-thread-{d}", .{id});
                return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
            } else if (std.mem.eql(u8, name, "start") or std.mem.eql(u8, name, "interrupt")) {
                return .{ .ok = .Unit };
            }
        }
    }

    if (receiver.* == .Intrinsic and std.mem.eql(u8, receiver.Intrinsic.fqn, "kotlin.properties.Delegates")) {
        if (std.mem.eql(u8, name, "notNull") and args.len == 0) {
            return .{ .ok = .{ .Delegate = try ObjRef(DelegateKind).init(allocator, .{ .NotNull = .{ .value = null, .name = "" } }) } };
        }
        if (std.mem.eql(u8, name, "observable") and args.len == 2) {
            return .{ .ok = .{ .Delegate = try ObjRef(DelegateKind).init(allocator, .{ .Observable = .{ .value = args[0], .on_change = args[1] } }) } };
        }
    }

    // Static call on an Intrinsic receiver: probe `<fqn>.<name>`. `toString` on a
    // type-in-value-position value is the identity string, not a conversion.
    if (receiver.* == .Intrinsic) {
        if (std.mem.eql(u8, name, "toString") and args.len == 0) {
            return .{ .ok = try strVal(allocator, receiver.Intrinsic.fqn) };
        }
        if (std.mem.eql(u8, name, "hashCode") and args.len == 0) {
            return .{ .ok = Value.newInt(@as(i64, @intCast(@intFromPtr(receiver.Intrinsic.fqn.ptr) & 0x7fffffff))) };
        }
        const probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ receiver.Intrinsic.fqn, name });
        defer if (runtime.freeScratch()) allocator.free(probe);
        if (lookupIntrinsic(self, probe)) |func| {
            return dispatchIntrinsic(self, allocator, probe, func, args);
        }
    }
    if (receiver.* == .Class) {
        const cls = receiver.Class;
        const cg = cls.borrow();
        const cname = cg.get().name;
        const cfqn = cg.get().fqn;
        cg.deinit();
        // `Any.toString` on a class value is the class label, never a same-named
        // number intrinsic that expects a value receiver.
        if (std.mem.eql(u8, name, "toString") and args.len == 0) {
            const label = try std.fmt.allocPrint(allocator, "class {s}", .{cname});
            return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, label) } };
        }
        const probe_simple = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cname, name });
        const probe_fqn = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cfqn, name });
        // `dispatchIntrinsic` borrows the key for the call only; free both probes here.
        defer if (runtime.freeScratch()) {
            allocator.free(probe_simple);
            allocator.free(probe_fqn);
        };
        if (lookupIntrinsic(self, probe_simple)) |func| return dispatchIntrinsic(self, allocator, probe_simple, func, args);
        if (lookupIntrinsic(self, probe_fqn)) |func| return dispatchIntrinsic(self, allocator, probe_fqn, func, args);
    }

    if (std.mem.eql(u8, name, "optimizeReadOnlyList") and args.len == 0 and receiver.* == .List) {
        return .{ .ok = receiver.* };
    }

    if (std.mem.eql(u8, name, "listIterator") and args.len <= 1 and receiver.* == .List) {
        const size: i64 = blk_sz: {
            const g = receiver.List.items.borrow();
            defer g.deinit();
            break :blk_sz @intCast(g.get().items.len);
        };
        const idx: i64 = if (args.len > 0) (args[0].asI64() orelse 0) else 0;
        if (idx < 0 or idx > size) {
            const msg = try std.fmt.allocPrint(allocator, "index: {d}, size: {d}", .{ idx, size });
            return .{ .err = .{ .Throw = try Value.newException(allocator, .{
                .fqn = try runtime.strInit(allocator, "kotlin.IndexOutOfBoundsException"),
                .message = .from(try runtime.strInitOwned(allocator, msg)),
                .cause = null,
            }) } };
        }
        const start: usize = @intCast(idx);
        if (stdlib.implementations.collections.sublistViewStale(receiver)) {
            return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
        }
        const cap = try captureModCount(allocator, receiver.List.mod_count.get());
        // Share the backing list, not a snapshot, so a `MutableListIterator`'s
        // `set`/`add`/`remove` mutate the underlying list as Kotlin requires.
        return .{ .ok = try Value.newIterator(allocator, .{
            .items = receiver.List.items.clone(),
            .prim = null,
            .mod_count = .from(cap.mod_count),
            .mutable = receiver.List.mutable and receiver.List.backing == null and
                !stdlib.implementations.collections.modCountFrozen(receiver.List.mod_count), .pos = start, .exp_mod = cap.exp_mod }) };
    }

    if (std.mem.eql(u8, name, "iterator") and args.len == 0 and (receiver.* == .Iterator or receiver.* == .RangeIter or receiver.* == .SeqIter)) {
        return .{ .ok = receiver.* };
    }

    if (std.mem.eql(u8, name, "iterator") and args.len == 0) {
        if (try builtinIterator(allocator, receiver)) |r| return r;
    }

    if (receiver.* == .Sequence) {
        if (try sequenceMember(self, allocator, receiver, name, args)) |r| return r;
    }

    // Inner-class construction `outer.Inner(args)`: the inner class registers under
    // `{outer fqn}.{name}`, so the receiver's class then its parents resolve it.
    if (receiver.* == .Instance) {
        const def_opt = blk: {
            // A runtime-local receiver uses its own registration family's nested class.
            {
                const g = receiver.Instance.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                for (cg.get().local_captures) |c| {
                    if (c.value == .Class and std.mem.eql(u8, c.name, name)) break :blk c.value.Class.clone();
                }
            }
            const cg = self.classes.borrow();
            defer cg.deinit();
            var outer_cls: ?ObjRef(ClassDef) = blk2: {
                const g = receiver.Instance.borrow();
                defer g.deinit();
                break :blk2 g.get().class.clone();
            };
            var hops: usize = 0;
            while (outer_cls) |oc| : (hops += 1) {
                if (hops > 64) {
                    oc.deinit();
                    break;
                }
                const og = oc.borrow();
                const outer_fqn = og.get().fqn;
                const qualified = std.fmt.allocPrint(allocator, "{s}.{s}", .{ outer_fqn, name }) catch {
                    og.deinit();
                    oc.deinit();
                    break;
                };
                defer allocator.free(qualified);
                const next: ?ObjRef(ClassDef) = if (og.get().parent) |p| p.clone() else null;
                og.deinit();
                oc.deinit();
                if (cg.get().get(qualified)) |d| {
                    if (next) |n| n.deinit();
                    break :blk d.clone();
                }
                outer_cls = next;
            }
            if (cg.get().get(name)) |d| break :blk d.clone();
            break :blk null;
        };
        if (def_opt) |def| {
            defer def.deinit();
            const dg = def.borrow();
            const is_inner = dg.get().is_inner;
            const def_fqn = dg.get().fqn;
            dg.deinit();
            if (is_inner) {
                // Resolve by FQN so a same-simple-name class from another package cannot swap in.
                const mg2 = self.module.borrow();
                const cid_opt = mg2.get().classIdByFqn(def_fqn) orelse mg2.get().classId(name);
                mg2.deinit();
                if (cid_opt) |class_id| {
                    const r = try newInstanceById(self, allocator, class_id, args, receiver);
                    if (r == .ok and r.ok == .Instance) {
                        const ig = r.ok.Instance.borrowMut();
                        ig.get().outer = .{ .Instance = receiver.Instance.clone() };
                        ig.deinit();
                    }
                    return r;
                }
                // An inner class of a local class has no module entry; its ClassDef is the class.
                const cls_val: Value = .{ .Class = def.clone() };
                defer if (runtime.reclaimEnabled()) cls_val.release(allocator);
                const r = try host_call_value.callValue(self, allocator, &cls_val, args);
                if (r == .ok and r.ok == .Instance) {
                    // An inner class of an anonymous object reads captures through its outer.
                    const outer_caps: []const InstanceData.Capture = ocap: {
                        const og = receiver.Instance.borrow();
                        defer og.deinit();
                        break :ocap og.get().anon_captures;
                    };
                    const ig = r.ok.Instance.borrowMut();
                    ig.get().outer = .{ .Instance = receiver.Instance.clone() };
                    if (outer_caps.len != 0 and ig.get().anon_captures.len == 0) {
                        const copy = try allocator.alloc(InstanceData.Capture, outer_caps.len);
                        for (outer_caps, copy) |c, *slot| {
                            if (runtime.reclaimEnabled()) c.value.retain();
                            slot.* = c;
                        }
                        ig.get().anon_captures = copy;
                    }
                    ig.deinit();
                }
                return r;
            }
        }
    }

    // `KClass.isInstance`: the value-side predicate dead-ends when a parent class
    // is not env-visible, so fall back to the registry walk that `is` uses.
    if (receiver.* == .Class and std.mem.eql(u8, name, "isInstance") and args.len == 1) {
        const cg = receiver.Class.borrow();
        const cname = cg.get().name;
        var hit = args[0].isRuntimeType(cname);
        if (!hit and args[0] == .Instance) hit = receiverImplementsType(self, &args[0], cname);
        const r = boolVal(hit);
        cg.deinit();
        return .{ .ok = r };
    }
    // `KClass.safeCast` / `cast`: the value itself on a match, else null or a throw.
    if (receiver.* == .Class and args.len == 1 and
        (std.mem.eql(u8, name, "safeCast") or std.mem.eql(u8, name, "cast")))
    {
        const cg = receiver.Class.borrow();
        const cname = cg.get().name;
        const casts = args[0].isRuntimeType(cname) or
            (args[0] == .Instance and receiverImplementsType(self, &args[0], cname));
        if (casts) {
            cg.deinit();
            var v = args[0];
            if (runtime.reclaimEnabled()) v.retain();
            return .{ .ok = v };
        }
        if (std.mem.eql(u8, name, "safeCast")) {
            cg.deinit();
            return .{ .ok = .Null };
        }
        const msg = try std.fmt.allocPrint(allocator, "Value cannot be cast to {s}", .{cg.get().fqn});
        defer if (runtime.freeScratch()) allocator.free(msg);
        cg.deinit();
        return .{ .err = try throwExc(allocator, "kotlin.ClassCastException", msg) };
    }

    if (receiver.* == .Class) {
        const cg = receiver.Class.borrow();
        const cname = cg.get().name;
        const cfqn = cg.get().fqn;
        cg.deinit();
        const mg = self.module.borrow();
        const mod = mg.get();
        // The nesting tree answers from the class id; the fqn probe covers unlinked classes.
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
            return newInstanceById(self, allocator, cid, args, null);
        }
    }

    if (receiver.* == .Class) {
        if (try classCompanionAndEnum(self, allocator, receiver, name, args)) |r| return r;
    }

    // Last-resort nested-class construction by simple name. It runs after companion
    // forwarding so an unrelated global of that name never outranks the companion.
    if (receiver.* == .Class) {
        const cid = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().classId(name);
        };
        if (cid) |c| return newInstanceById(self, allocator, c, args, null);
    }

    // A null value has no runtime type, but a statically-directed call has an exact
    // declared receiver: address its host binding before the member ladder.
    if (receiver.* == .Null) {
        if (static_recv) |declared| {
            const head = staticReceiverBindingHead(declared);
            if (head.len != 0) {
                var fqn_buf: [256]u8 = undefined;
                const fqn = if (std.mem.findScalar(u8, head, '.') != null)
                    std.fmt.bufPrint(&fqn_buf, "{s}.{s}", .{ head, name }) catch null
                else
                    std.fmt.bufPrint(&fqn_buf, "kotlin.{s}.{s}", .{ head, name }) catch null;
                if (fqn) |binding_fqn| {
                    if (lookupIntrinsic(self, binding_fqn)) |func| {
                        return dispatchWithReceiver(self, allocator, binding_fqn, func, receiver, args);
                    }
                }
            }
        }
    }

    // Null-receiver `equals` reduces to `other === null` at either arity.
    if (receiver.* == .Null and std.mem.eql(u8, name, "equals") and args.len >= 1) {
        return .{ .ok = boolVal(args[0] == .Null) };
    }
    // `null.toString()` is the string null, not the Unit a bodyless actual returns.
    if (receiver.* == .Null and std.mem.eql(u8, name, "toString") and args.len == 0) {
        return .{ .ok = .{ .String = try runtime.strInit(allocator, "null") } };
    }
    if (receiver.* == .Null and std.mem.eql(u8, name, "hashCode") and args.len == 0) {
        return .{ .ok = .{ .Int = 0 } };
    }
    // Array `content*` extensions declare a nullable array receiver, but a null's type
    // is `kotlin.Nothing`, so the probe never reaches the `kotlin.Array.*` intrinsics.
    if (receiver.* == .Null and isArrayContentFn(name)) {
        var key_buf: [64]u8 = undefined;
        const fqn = std.fmt.bufPrint(&key_buf, "kotlin.Array.{s}", .{name}) catch unreachable;
        if (lookupIntrinsic(self, fqn)) |func| {
            return dispatchWithReceiver(self, allocator, fqn, func, receiver, args);
        }
    }

    // `equals` on an array is identity (`contentEquals` compares content).
    if (receiver.* == .Array and std.mem.eql(u8, name, "equals") and args.len == 1) {
        return .{ .ok = boolVal(Value.structuralEq(receiver, &args[0])) };
    }
    if (std.mem.eql(u8, name, "equals") and isBuiltinScalar(receiver)) {
        // `Double.equals`/`Float.equals` compare the boxed representation:
        // `(-0.0).equals(0.0)` is false and `NaN.equals(NaN)` is true.
        if ((receiver.* == .Double or receiver.* == .Float) and args.len == 1) {
            return .{ .ok = boolVal(Value.structuralEqBoxed(receiver, &args[0])) };
        }
        if (receiver.* == .String and args.len > 1 and args[1] == .Bool and args[1].Bool) {
            if (args.len > 0 and args[0] == .String) {
                const eq = eqIgnoreCase(allocator, receiver.String, args[0].String);
                return .{ .ok = boolVal(eq) };
            }
            return .{ .ok = boolVal(false) };
        }
        if (receiver.* == .Char and args.len > 1 and args[1] == .Bool and args[1].Bool) {
            if (args.len > 0 and args[0] == .Char) {
                const eq = stdlib.implementations.char.charEqIgnoreCase(receiver.Char, args[0].Char);
                return .{ .ok = boolVal(eq) };
            }
            return .{ .ok = boolVal(false) };
        }
        if (args.len > 0) {
            return .{ .ok = boolVal(Value.structuralEq(receiver, &args[0])) };
        }
    }

    if (receiver.* == .Instance) {
        if (try samInstanceDispatch(self, allocator, receiver, name, args)) |r| return r;
    }

    if (receiver.* == .Instance) {
        if (try boundRefDispatch(self, allocator, receiver, name, args)) |r| return r;
    }

    // A constructor reference invoked through `invoke`/`call` constructs. The SAM
    // block below skips `invoke`, so class receivers route here.
    if ((receiver.* == .Class or receiver.* == .Intrinsic) and
        (std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "call")))
    {
        const r = try callValueRec(self, allocator, receiver, args);
        if (r == .ok) return r;
    }

    // SAM conversion on a callable receiver, gated on its declared parameter count.
    if (isCallableOrIntrinsic(receiver)) {
        const has_ext = extWithThisLongerThanArgs(self, name, args.len);
        // A SAM-converted value may carry one extra leading slot for the adapter's
        // receiver, which the invoke path binds, so +1 matches as well.
        const arity_ok = if (callableFieldArity(self, receiver)) |n| n == args.len or n == args.len + 1 else true;
        // A name a top-level non-extension function serves is that function, never
        // the callable's interface method; member-only names keep the SAM arm.
        const toplevel_serves = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const mod = mg.get();
            for (mod.funcsBySimpleName(name)) |fid| {
                const f = funcAt(mod, fid) orelse continue;
                if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
                break :blk true;
            }
            break :blk false;
        };
        if (samTraceOn()) std.debug.print("[sam-gate] name={s} nargs={d} has_ext={} arity_ok={} tl={}\n", .{ name, args.len, has_ext, arity_ok, toplevel_serves });
        if (!std.mem.eql(u8, name, "invoke") and !has_ext and arity_ok and !toplevel_serves) {
            if (samTraceOn()) std.debug.print("[sam-arm] name={s} nargs={d} arity_ok={} tl={}\n", .{ name, args.len, arity_ok, toplevel_serves });
            const r = try callValueRec(self, allocator, receiver, args);
            switch (r) {
                .ok => return r,
                .err => |e| switch (e) {
                    .Suspended, .CalleeFailed, .Throw, .NonLocalReturn, .LabeledReturn => return r,
                    else => {},
                },
            }
        }
    }

    if (receiver.* == .Class) {
        if (try kclassMembers(self, allocator, receiver, name, args)) |r| return r;
    }

    if (receiver.* == .IrClosure) {
        if (std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "call")) {
            return callValueRec(self, allocator, receiver, args);
        }
        if (args.len == 0 and receiver.* == .IrClosure) {
            if (try kfunctionReflection(self, allocator, receiver, name)) |r| return r;
        }
        if (try samMemberExtOnCallable(self, allocator, receiver, name, args)) |r| return r;
    }

    if (receiver.* == .PropertyRef) {
        if (try propertyRefDispatch(self, allocator, receiver, name, args)) |r| return r;
    }

    // Enum entries compare by ordinal.
    if (std.mem.eql(u8, name, "compareTo") and args.len == 1 and receiver.* == .Instance and args[0] == .Instance) {
        const ag = receiver.Instance.borrow();
        const cg = ag.get().class.borrow();
        const is_enum = cg.get().is_enum;
        cg.deinit();
        if (is_enum) {
            const ord_a: i64 = if (ag.get().get("ordinal")) |v| (v.asI64() orelse 0) else 0;
            ag.deinit();
            const bg = args[0].Instance.borrow();
            const ord_b: i64 = if (bg.get().get("ordinal")) |v| (v.asI64() orelse 0) else 0;
            bg.deinit();
            return .{ .ok = Value.newInt(ord_a - ord_b) };
        }
        ag.deinit();
    }

    if ((std.mem.eql(u8, name, "sorted") or std.mem.eql(u8, name, "sortedDescending")) and args.len == 0 and receiver.* == .List) {
        if (try sortedInstances(self, allocator, receiver, name)) |r| return r;
    }

    if (receiver.* == .Comparator) {
        if (try comparatorMember(self, allocator, receiver, name, args)) |r| return r;
    }

    if (std.mem.eql(u8, name, "contains") and args.len == 1 and receiver.* == .Range and
        args[0] != .Range and !rangeContainsArgKindMatches(receiver.Range.kind, &args[0]))
    {
        if (try extensionFnFallback(self, allocator, receiver, name, args, strict_ext, static_recv, declared_recv)) |r| return r;
        // `ClosedRange<Int>.contains(element: Int?)`: a null element is never in the range.
        if (args[0] == .Null) return .{ .ok = boolVal(false) };
    }
    if (std.mem.eql(u8, name, "contains") and args.len == 1 and receiver.* == .Range and
        args[0] != .Range and rangeContainsArgKindMatches(receiver.Range.kind, &args[0]))
    {
        const r = receiver.Range;
        // A descending progression has start > end; membership bounds run low..high.
        const lo = if (r.step > 0) r.start else r.end;
        const hi = if (r.step > 0) r.end else r.start;
        const inside = blk: {
            if (args[0] == .Char and r.kind == .Char) {
                const cv: i64 = @intCast(args[0].Char);
                break :blk cv >= lo and cv <= hi and @rem(cv - r.start, r.step) == 0;
            }
            // Unsigned ranges store the full u64 space as raw i64 bits; compare unsigned.
            if (r.kind == .ULong or r.kind == .UInt) {
                const uv: u64 = args[0].asU64() orelse
                    (if (args[0].asI64()) |sv| @as(u64, @bitCast(sv)) else break :blk false);
                const us: u64 = @bitCast(r.start);
                const ue: u64 = @bitCast(r.end);
                // Bounds follow the step direction, so an ascending `3u..1u` stays empty.
                const ulo = if (r.step > 0) us else ue;
                const uhi = if (r.step > 0) ue else us;
                const diff = @as(i128, uv) - @as(i128, us);
                break :blk uv >= ulo and uv <= uhi and @rem(diff, @as(i128, r.step)) == 0;
            }
            if (args[0].asI64()) |v| {
                // Widen the difference: `v - r.start` overflows i64 for a near-full-type range.
                const diff = @as(i128, v) - @as(i128, r.start);
                break :blk v >= lo and v <= hi and @rem(diff, @as(i128, r.step)) == 0;
            }
            break :blk false;
        };
        return .{ .ok = boolVal(inside) };
    }

    // `key in map` on a user Map implementation.
    if (std.mem.eql(u8, name, "contains") and args.len == 1 and receiver.* == .Instance and
        hostHasMember(self, receiver, "containsKey") and !hostHasMember(self, receiver, "contains"))
    {
        if (routeTraceOn(name)) std.debug.print("[route] L4660\n", .{});
        return callMemberRec(self, allocator, receiver, "containsKey", args);
    }

    if (receiver.* == .Map) {
        if (std.mem.eql(u8, name, "contains") or std.mem.eql(u8, name, "containsKey")) {
            if (args.len == 1) {
                const r = try mapContainsKeyEq(self, allocator, receiver.Map.entries, &args[0]);
                return switch (r) {
                    .ok => |b| .{ .ok = boolVal(b) },
                    .err => |e| .{ .err = e },
                };
            }
        } else if (std.mem.eql(u8, name, "containsValue") and args.len == 1) {
            const g = receiver.Map.entries.borrow();
            defer g.deinit();
            var has = false;
            for (g.get().pairs.items) |kv| {
                if (Value.structuralEqBoxed(&kv.value, &args[0])) {
                    has = true;
                    break;
                }
            }
            return .{ .ok = boolVal(has) };
        }
    }

    if (receiver.* == .List and std.mem.eql(u8, name, "toTypedArray") and args.len == 0) {
        const items = try cloneItemsList(allocator, receiver.List.items);
        return .{ .ok = runtime.ArrayData.fromBoxedList(try ObjRef(std.ArrayList(Value)).init(allocator, items)) };
    }
    if (receiver.* == .Array) {
        if (try arrayShapeOps(self, allocator, receiver, name, args)) |r| return r;
        // `Any.toString` on an array is the `fqn@identity` string, never the
        // contents: a self-referencing array must not recurse.
        if (std.mem.eql(u8, name, "toString") and args.len == 0) {
            const s = try std.fmt.allocPrint(allocator, "{s}@{x}", .{ receiver.typeFqn(), receiver.Array.identity() });
            return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
        }
    }

    if (std.mem.eql(u8, name, "get") and args.len == 1 and receiver.* == .Array) {
        if (args[0].asI64()) |idx| {
            const arr = receiver.Array;
            const n = arr.len();
            if (idx >= 0 and @as(usize, @intCast(idx)) < n) {
                const elem = arr.get(@intCast(idx));
                // The array owns the element; retain before the result register takes it.
                elem.retain();
                return .{ .ok = elem };
            }
            const msg = try std.fmt.allocPrint(allocator, "Index {d} out of bounds for length {d}", .{ idx, n });
            defer if (runtime.freeScratch()) allocator.free(msg);
            return .{ .err = try throwExc(allocator, "kotlin.ArrayIndexOutOfBoundsException", msg) };
        }
    }
    if (std.mem.eql(u8, name, "set") and args.len == 2 and receiver.* == .Array) {
        if (args[0].asI64()) |idx| {
            const arr = receiver.Array;
            const n = arr.len();
            if (idx >= 0 and @as(usize, @intCast(idx)) < n) {
                arr.set(allocator, @intCast(idx), args[1]);
                return .{ .ok = .Unit };
            }
            const msg = try std.fmt.allocPrint(allocator, "Index {d} out of bounds for length {d}", .{ idx, n });
            defer if (runtime.freeScratch()) allocator.free(msg);
            return .{ .err = try throwExc(allocator, "kotlin.ArrayIndexOutOfBoundsException", msg) };
        }
    }

    if (try collectionMutators(self, allocator, receiver, name, args)) |r| return r;

    if (try componentMembers(self, allocator, receiver, name, args)) |r| return r;

    if (receiver.* == .Iterator) {
        if (try iteratorMember(allocator, receiver, name, args)) |r| return r;
    }
    if (receiver.* == .RangeIter) {
        if (try rangeIterMember(allocator, receiver, name, args)) |r| return r;
    }
    if (receiver.* == .SeqIter) {
        if (try seqIterMember(self, allocator, receiver, name, args)) |r| return r;
    }

    if (receiver.* == .Instance) {
        if (try dataClassAutoMembers(self, allocator, receiver, name, args)) |r| return r;
    }

    if (receiver.* == .Instance) {
        if (try anonMethodDispatch(self, allocator, receiver, name, args)) |r| return r;
    }

    if (receiver.* == .Instance) {
        if (routeTraceOn(name)) std.debug.print("[route] L4766\n", .{});
        if (try irMethodWalk(self, allocator, receiver, name, args, static_recv)) |r| return r;
    }

    if (receiver.* == .Instance) {
        if (try anyInstanceFallback(self, allocator, receiver, name, args)) |r| return r;
    }

    if (receiver.* == .Unit) {
        if (std.mem.eql(u8, name, "equals") and args.len == 1) {
            return .{ .ok = boolVal(args[0] == .Unit) };
        }
        if (std.mem.eql(u8, name, "hashCode") and args.len == 0) return .{ .ok = Value.newInt(0) };
        if (std.mem.eql(u8, name, "toString") and args.len == 0) return .{ .ok = try strVal(allocator, "kotlin.Unit") };
    }

    // Named `Boolean` operator members; `!`/`&&`/`||` lower to binops instead.
    if (receiver.* == .Bool) {
        const b = receiver.Bool;
        if (std.mem.eql(u8, name, "not") and args.len == 0) return .{ .ok = boolVal(!b) };
        if (args.len == 1 and args[0] == .Bool) {
            const o = args[0].Bool;
            if (std.mem.eql(u8, name, "and")) return .{ .ok = boolVal(b and o) };
            if (std.mem.eql(u8, name, "or")) return .{ .ok = boolVal(b or o) };
            if (std.mem.eql(u8, name, "xor")) return .{ .ok = boolVal(b != o) };
            if (std.mem.eql(u8, name, "compareTo")) {
                const bi: i64 = @intFromBool(b);
                const oi: i64 = @intFromBool(o);
                return .{ .ok = Value.newInt(if (bi < oi) @as(i64, -1) else if (bi > oi) @as(i64, 1) else 0) };
            }
        }
    }

    // `hashCode()` on a builtin value type. Containers hash elements through
    // member dispatch so a user `hashCode()` override participates.
    if (args.len == 0 and std.mem.eql(u8, name, "hashCode") and
        receiver.* != .Instance and receiver.* != .Class and receiver.* != .PropertyRef)
    {
        if (stdlib.implementations.collections.sublistViewStale(receiver)) {
            return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
        }
        return .{ .ok = Value.newInt(@as(i64, try hashWithDispatch(self, allocator, receiver))) };
    }

    // A stale subList view rejects `equals`: it checks comodification first.
    if (args.len == 1 and std.mem.eql(u8, name, "equals") and receiver.* == .List and
        stdlib.implementations.collections.sublistViewStale(receiver))
    {
        return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
    }

    // A declared receiver head overrides the runtime-type surface: Kotlin resolves
    // against the static type, so a `T : Iterable` receiver dispatches `Iterable.minus`.
    if (declared_recv) |dn| {
        if (std.mem.eql(u8, dn, "Iterable") or std.mem.eql(u8, dn, "Collection") or
            std.mem.eql(u8, dn, "MutableCollection"))
        {
            var buf: [96]u8 = undefined;
            const fqn = std.fmt.bufPrint(&buf, "kotlin.collections.Iterable.{s}", .{name}) catch buf[0..0];
            if (lookupIntrinsic(self, fqn)) |func| {
                return dispatchWithReceiver(self, allocator, fqn, func, receiver, args);
            }
        }
    }

    if (try stdlibMemberDispatch(self, allocator, receiver, name, args)) |r| return r;
    runtime.prof.opRoute(16);

    // Class-delegation pre-pass.
    if (receiver.* == .Instance) {
        if (try delegateForward(self, allocator, receiver, name, args, true)) |r| return r;
    }

    // Kotlin selects extensions statically, so a caller holding a committed
    // extension target passes `no_ext`: only a true member may shadow it.
    if (receiver.* == .Class) {
        if (try localClassCompanionForward(self, allocator, receiver, name, args)) |r| return r;
    }
    if (!no_ext) {
        if (try extensionFnFallback(self, allocator, receiver, name, args, strict_ext, static_recv, declared_recv)) |r| return r;
        // A fun interface whose single abstract method is a member extension on this
        // receiver's type lowers no func, so the stored lambda serves the call.
        if (try enclosingSamMemberExtDispatch(self, allocator, receiver, name, args)) |r| return r;
        // The same shape with the lambda unwrapped: no SAM instance exists, so the
        // receiver tower carries the raw closure and the arm above misses.
        if (try enclosingSamLambdaDispatch(self, allocator, receiver, name, args)) |r| return r;
        // An enclosing anonymous object declaring a member-extension override
        // registers in the per-site table, not the module func index.
        if (try enclosingAnonMemberExtDispatch(self, allocator, receiver, name, args)) |r| return r;
        // The same for a named enclosing class whose extension was not bound statically.
        if (try enclosingNamedMemberExtDispatch(self, allocator, receiver, name, args)) |r| return r;
    }

    // Range to List re-dispatch, last resort only: it runs after the extension
    // fallback so receiver-generic extensions keep the real progression receiver.
    if (receiver.* == .Range) {
        const r = receiver.Range;
        const items = try materialiseRangeItems(allocator, r.start, r.end, r.step, r.kind);
        const as_list = try listOf(allocator, items, false);
        if (routeTraceOn(name)) std.debug.print("[route] L4890\n", .{});
        return callMemberRec(self, allocator, &as_list, name, args);
    }

    // Class-delegation forwarding (swallow all errors).
    if (receiver.* == .Instance) {
        if (try delegateForward(self, allocator, receiver, name, args, false)) |r| return r;
    }

    if (receiver.* == .Class) {
        if (try classCompanionForward(self, allocator, receiver, name, args)) |r| return r;
    }
    // An enum's bare name publishes as its companion instance once it has one, so
    // redirect the enum statics from the companion to the enum class.
    if (receiver.* == .Instance and (std.mem.eql(u8, name, "values") or std.mem.eql(u8, name, "valueOf") or std.mem.eql(u8, name, "entries"))) {
        const comp_cls: ObjRef(ClassDef) = blk: {
            const ig = receiver.Instance.borrow();
            defer ig.deinit();
            break :blk ig.get().class.clone();
        };
        defer comp_cls.deinit();
        const is_companion = blk: {
            const cg = comp_cls.borrow();
            defer cg.deinit();
            const n = cg.get().name;
            break :blk std.mem.endsWith(u8, n, "$Companion") or std.mem.endsWith(u8, n, ".Companion") or std.mem.eql(u8, n, "Companion");
        };
        if (is_companion) {
            const cv = Value{ .Class = comp_cls };
            if (try companionOwnerClassValue(self, &cv)) |owner| {
                defer owner.release(allocator);
                const owner_is_enum = blk: {
                    const og = owner.Class.borrow();
                    defer og.deinit();
                    break :blk og.get().is_enum;
                };
                if (owner_is_enum) return try callMember(self, allocator, &owner, name, args);
            }
        }
    }

    // A `@Serializable` declaration's generated companion `serializer()` is reached
    // above; a class value without it takes the `KClass<T>.serializer()` extension.
    if (receiver.* == .Class and std.mem.eql(u8, name, "serializer")) {
        const ext_fid: ?FuncId = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const m = mg.get();
            for (m.funcsBySimpleName("serializer")) |cand| {
                const cf = m.funcById(cand) orelse continue;
                if (!std.mem.eql(u8, cf.fqn, "kotlinx.serialization.serializer")) continue;
                if (cf.params.len != args.len + 1) continue;
                if (!std.mem.eql(u8, cf.params[0].name, "this")) continue;
                if (!std.mem.eql(u8, simpleName(cf.params[0].ty.name), "KClass")) continue;
                break :blk cand;
            }
            break :blk null;
        };
        if (ext_fid) |fid| {
            var call_args: std.ArrayList(Value) = .empty;
            defer call_args.deinit(allocator);
            try call_args.append(allocator, receiver.*);
            try call_args.appendSlice(allocator, args);
            return try callFuncRec(self, allocator, self.module.asPtr(), fid, call_args.items);
        }
    }

    // `@Serializer(forClass = C::class)` marks a declaration the kotlinx plugin
    // fills in; a member it does not define is answered by C's own serializer.
    if (try serializerForClassTarget(self, allocator, receiver)) |ser| {
        defer ser.release(allocator);
        if (routeTraceOn(name)) std.debug.print("[route] serializer-forClass\n", .{});
        return callMemberRec(self, allocator, &ser, name, args);
    }

    if (receiver.* == .Instance) {
        if (try instanceCompanionFallback(self, allocator, receiver, name, args)) |r| return r;
    }

    if (receiver.* == .CoroutineSuspended) {
        if (std.mem.eql(u8, name, "toString")) return .{ .ok = try strVal(allocator, "COROUTINE_SUSPENDED") };
        if (std.mem.eql(u8, name, "hashCode")) return .{ .ok = .{ .Int = 0 } };
        if (std.mem.eql(u8, name, "equals")) {
            return .{ .ok = boolVal(args.len > 0 and args[0] == .CoroutineSuspended) };
        }
    }

    // Function-typed property invoked by name.
    if (receiver.* == .Instance) {
        const field = blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            for (g.get().fields.items) |f| {
                if (std.mem.eql(u8, f.name, name)) break :blk f.value;
            }
            break :blk null;
        };
        if (field == null and missTraceWant(name)) {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            std.debug.print("[fnprop] no own field `{s}`; fields:", .{name});
            for (g.get().fields.items) |f| std.debug.print(" {s}", .{f.name});
            std.debug.print("\n", .{});
        }
        if (field) |v| {
            if (missTraceWant(name)) {
                const np: i64 = if (v == .IrClosure)
                    if (self.closures.get(@intCast(v.IrClosure.asPtr().id))) |info| @intCast(info.n_params) else -1
                else
                    -2;
                std.debug.print("[fnprop] own-field hit tag={s} callable={} n_params={d} args={d}\n", .{ @tagName(v), isCallable(&v), np, args.len });
            }
            if (isCallable(&v) or v == .Instance) {
                // A receiver-function-typed property binds an implicit receiver of
                // its declared head; with none in scope the arm does not apply.
                if (recvFnPropHeadOf(self, receiver, name)) |head| {
                    // One arg more than the lambda's declared params is the
                    // function-style invoke, which Kotlin selects by arity.
                    const first_arg_recv = blk: {
                        if (v != .IrClosure or args.len == 0) break :blk false;
                        const info = self.closures.get(@intCast(v.IrClosure.asPtr().id)) orelse break :blk false;
                        break :blk args.len == info.n_params + 1 or
                            (args.len + 2 == info.n_params + 1 and closurePairTailed(self, info));
                    };
                    if (first_arg_recv) return callValueRec(self, allocator, &v, args);
                    if (try recvFnReceiverFor(self, allocator, receiver, head)) |rv| {
                        return try host_call_value.callValueWithThis(self, allocator, &v, &rv, args, &.{});
                    }
                } else {
                    return callValueRec(self, allocator, &v, args);
                }
            }
        } else if (blk: {
            // Accessor-backed property holding a callable: a member-only read, so a
            // genuine miss continues the walk. Gated on the name having a custom getter.
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().getter_prop_names.contains(name) and
                receiverPropCanHoldCallable(self, receiver, name);
        }) {
            const pr = try host_fields.getMemberField(self, allocator, receiver, name);
            if (missTraceWant(name)) {
                switch (pr) {
                    .ok => |v| std.debug.print("[fnprop] getMemberField ok tag={s} callable={}\n", .{ @tagName(v), isCallable(&v) }),
                    .err => |e| switch (e) {
                        .Unsupported, .Type => |m| std.debug.print("[fnprop] getMemberField err: {s}\n", .{m}),
                        else => std.debug.print("[fnprop] getMemberField err tag={s}\n", .{@tagName(e)}),
                    },
                }
            }
            if (pr == .ok and (isCallable(&pr.ok) or pr.ok == .Instance)) {
                return callValueRec(self, allocator, &pr.ok, args);
            }
        } else if (!hostHasMember(self, receiver, name) and host_fields.extPropDeclaredCallable(self, allocator, receiver, name)) {
            // An extension property holding a callable takes its receiver first.
            const pr = try host_fields.getField(self, allocator, receiver, name);
            if (pr == .ok and (isCallable(&pr.ok) or pr.ok == .Instance)) {
                return callValueRec(self, allocator, &pr.ok, args);
            }
        }
    }

    // A top-level property holding a receiver-callable: with no member or function
    // of the name, `a.x(lambda)` is `x.invoke(a, lambda)`.
    if (receiver.* == .Instance and !hostHasMember(self, receiver, name) and blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (mod.funcsBySimpleName(name).len != 0) break :blk false;
        // A custom getter runs only when its declared type is callable.
        if (host_globals.lookupGlobal(self, name) != null) break :blk true;
        const getter = mod.registry.top_level_prop_getters.get(name) orelse break :blk false;
        const gf = mod.funcById(getter) orelse break :blk false;
        break :blk host_fields.declaredTypeIsCallable(mod, &gf.return_ty);
    }) {
        if (try topLevelPropertyGet(self, allocator, name)) |pr| {
            if (pr == .ok and pr.ok == .IrClosure) {
                const has_recv = if (self.closures.get(@intCast(pr.ok.IrClosure.asPtr().id))) |info| info.has_receiver else false;
                if (has_recv) return try host_call_value.callValueWithThis(self, allocator, &pr.ok, receiver, args, &.{});
            }
        }
    }
    // An extension property on a builtin receiver holding a callable.
    if (receiver.* != .Instance and receiver.* != .Class and receiver.* != .Null and
        host_fields.extPropDeclaredCallable(self, allocator, receiver, name))
    {
        const pr = try host_fields.getField(self, allocator, receiver, name);
        if (pr == .ok and (isCallable(&pr.ok) or pr.ok == .Instance)) {
            return callValueRec(self, allocator, &pr.ok, args);
        }
    }
    // A top-level property holding a receiver-callable, on a builtin receiver.
    if (receiver.* != .Instance and receiver.* != .Class and receiver.* != .Null and blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().funcsBySimpleName(name).len == 0 and host_globals.lookupGlobal(self, name) != null;
    }) {
        if (host_globals.lookupGlobal(self, name)) |gv| {
            if (gv == .IrClosure) {
                const has_recv = if (self.closures.get(@intCast(gv.IrClosure.asPtr().id))) |info| info.has_receiver else false;
                if (has_recv) return try host_call_value.callValueWithThis(self, allocator, &gv, receiver, args, &.{});
            }
        }
    }
    // Extension-function-typed member invoked with an explicit receiver.
    if (try enclosingCallableProperty(self, allocator, name)) |v| {
        // Overriding the callable's captured `this` displaces the lexically
        // enclosing receiver; push it as an outer implicit receiver, or a bare
        // member call targeting it re-resolves against this `this` and recurses.
        const prior_this: ?Value = blk: {
            if (v != .IrClosure) break :blk null;
            const info = self.closures.get(@intCast(v.IrClosure.asPtr().id)) orelse break :blk null;
            var this_idx: ?usize = null;
            for (info.capture_names, 0..) |n, idx| {
                if (std.mem.eql(u8, n, "this")) {
                    this_idx = idx;
                    break;
                }
            }
            const idx = this_idx orelse break :blk null;
            const cg = info.captures.borrow();
            defer cg.deinit();
            if (idx < cg.get().items.len) break :blk cg.get().items[idx];
            break :blk null;
        };
        const pushed_outer = po: {
            const pt = prior_this orelse break :po false;
            if (pt == .Null or pt == .Unit) break :po false;
            if (pt == .Instance and receiver.* == .Instance) {
                break :po !ObjRef(InstanceData).ptrEq(pt.Instance, receiver.Instance);
            }
            break :po true;
        };
        if (pushed_outer) {
            if (prior_this) |p| pushAccessEnclosing(self, &p);
        }
        // Dispatch on the main evaluator path, not the intrinsic-host invoke: it
        // snapshots frames so a suspension in the lambda body parks and resumes.
        const r = try self.callValueWithThis(allocator, &v, receiver, args, &.{});
        if (pushed_outer) popAccessEnclosing(self);
        return r;
    }

    if (receiver.* == .Instance and !hcm.map_fallback_active and
        hostHasMember(self, receiver, "entries") and !hostHasMember(self, receiver, "iterator"))
    {
        const probe = try std.fmt.allocPrint(allocator, "kotlin.collections.Map.{s}", .{name});
        defer if (runtime.freeScratch()) allocator.free(probe);
        if (lookupIntrinsic(self, probe)) |f| {
            const built = blk: {
                hcm.map_fallback_active = true;
                defer hcm.map_fallback_active = false;
                break :blk try materializeUserMap(self, allocator, receiver);
            };
            const map_val = switch (built) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            const new_args = try prependReceiver(allocator, &map_val, args);
            defer if (runtime.freeScratch()) allocator.free(new_args);
            return dispatchIntrinsic(self, allocator, probe, f, new_args);
        }
    }

    // CharSequence fallback: materialize through the class's own `toString()` and
    // re-dispatch. Runs after the member walk missed, so a declared op still wins.
    if (receiver.* == .Instance and !stdlib_tail.charseq_fallback_active and
        instanceImplementsCharSequence(self, receiver))
    {
        stdlib_tail.charseq_fallback_active = true;
        defer stdlib_tail.charseq_fallback_active = false;
        if (routeTraceOn(name)) std.debug.print("[route] L5074\n", .{});
        const sres = try callMemberRec(self, allocator, receiver, "toString", &.{});
        switch (sres) {
            .ok => |sv| {
                if (sv == .String) {
                    if (routeTraceOn(name)) std.debug.print("[route] L5078\n", .{});
                    return try callMemberRec(self, allocator, &sv, name, args);
                }
            },
            .err => {},
        }
    }

    if (receiver.* == .Instance and !hcm.iterable_fallback_active and
        (hostHasMember(self, receiver, "iterator") or samIterableInstance(self, allocator, receiver)))
    {
        // A class chain implementing Sequence keeps Kotlin's laziness: run the
        // declared Sequence-receiver extension instead of draining to a List.
        if (instanceImplementsSequence(self, receiver)) {
            if (sequenceExtBodyFid(self, name, args.len)) |fid| {
                const mg = self.module.borrow();
                const mod: *const Module = mg.get();
                mg.deinit();
                const new_args = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(new_args);
                if (routeTraceOn(name)) std.debug.print("[route] L5100\n", .{});
                return try host_call_func.callFunc(self, allocator, mod, fid, new_args);
            }
        }
        {
            const p1 = try std.fmt.allocPrint(allocator, "kotlin.collections.Iterable.{s}", .{name});
            defer if (runtime.freeScratch()) allocator.free(p1);
            var matched: []const u8 = p1;
            var intrinsic = lookupIntrinsic(self, p1);
            var p2_owned: ?[]const u8 = null;
            defer if (runtime.freeScratch()) if (p2_owned) |p| allocator.free(p);
            if (intrinsic == null) {
                const p2 = try std.fmt.allocPrint(allocator, "kotlin.collections.List.{s}", .{name});
                p2_owned = p2;
                intrinsic = lookupIntrinsic(self, p2);
                matched = p2;
            }
            if (intrinsic) |f| {
                // The call shape must fit some source declaration of this name for
                // an iterable receiver, or an unrelated global gets swallowed.
                const arity_fits = blk2: {
                    const mg2 = self.module.borrow();
                    defer mg2.deinit();
                    const m2 = @constCast(mg2.get());
                    break :blk2 m2.extCouldApply(allocator, "Iterable", name, args.len) or
                        m2.extCouldApply(allocator, "List", name, args.len) or
                        m2.extCouldApply(allocator, "Collection", name, args.len);
                };
                if (!arity_fits) {
                    if (routeTraceOn(name)) std.debug.print("[route] L5147-arity-skip\n", .{});
                } else {
                // `toTypedArray` observes a user `toArray()` override before any drain.
                if (std.mem.eql(u8, name, "toTypedArray")) {
                    return try dispatchWithReceiver(self, allocator, matched, f, receiver, args);
                }
                if (runtime.envSetOnce("KLIO_DRAIN_TRACE")) {
                    std.debug.print("[drain] {s} on {s} caller={s} span={?any}\n", .{
                        name,
                        receiver.typeFqn(),
                        if (ir.eval.currentFrameFunc()) |cfn| cfn.fqn else "<none>",
                        ir.eval.currentCallSiteSpan(),
                    });
                }
                const drained = blk: {
                    hcm.iterable_fallback_active = true;
                    defer hcm.iterable_fallback_active = false;
                    break :blk try drainIterableToList(self, allocator, receiver);
                };
                const dv = switch (drained) {
                    .ok => |v| v,
                    .err => |e| return .{ .err = e },
                };
                const new_args = try prependReceiver(allocator, &dv, args);
                defer if (runtime.freeScratch()) allocator.free(new_args);
                return dispatchIntrinsic(self, allocator, matched, f, new_args);
                }
            }
        }
    }

    // Function-typed property called with parentheses.
    if (receiver.* == .Instance) {
        const field = blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            break :blk g.get().get(name);
        };
        if (field) |f| {
            switch (f) {
                .IrClosure, .Class => {
                    // Same receiver-fn applicability gate as the by-name arm above.
                    if (recvFnPropHeadOf(self, receiver, name)) |head| {
                        if (try recvFnReceiverFor(self, allocator, receiver, head)) |rv| {
                            return try host_call_value.callValueWithThis(self, allocator, &f, &rv, args, &.{});
                        }
                    } else {
                        return callValueRec(self, allocator, &f, args);
                    }
                },
                else => {},
            }
        }
    }

    // A property `name` next to a top-level `fun name()`: call the function.
    if (receiver.* == .Instance and hostHasMember(self, receiver, name)) {
        if (lookupGlobalValue(self, name)) |g| {
            switch (g) {
                .IrClosure => return callValueRec(self, allocator, &g, args),
                else => {},
            }
        }
    }

    // `recv.prop { lambda }` where `prop` holds a callable instance parses as
    // `(recv.prop)(lambda)`. Gated on a receiver-owned `Instance` value and a trailing
    // callable so an ordinary member miss is never pre-empted; leading args pass through.
    if (receiver.* == .Instance and args.len >= 1 and isCallable(&args[args.len - 1])) {
        const got = self.getMemberField(allocator, receiver, name) catch EvalResult{ .err = .{ .Type = "" } };
        if (got == .ok) {
            const pv = got.ok;
            if (pv == .Instance) {
                defer pv.release(allocator);
                return try callValueRec(self, allocator, &pv, args);
            }
            pv.release(allocator);
        } else {
            host_fields.freeFieldMiss(allocator, got.err);
        }
    }

    // A renaming import reached as a receiver call: on a total miss, resolve the alias
    // from the call site's file and bind the aliased extension by FQN, not by name.
    if (ir.eval.currentCallSiteSpan()) |sp| {
        var chosen: ?ir.FuncId = null;
        var chosen_exact = false;
        var retry_leaf: ?[]const u8 = null;
        {
            const mg = self.module.borrow();
            defer mg.deinit();
            const m = mg.get();
            const paths = m.importAliasPathsIn(sp.file, name);
            if (paths.len == 1 and paths[0].segs.len >= 2) {
                const target_leaf = paths[0].segs[paths[0].segs.len - 1];
                if (!std.mem.eql(u8, target_leaf, name)) {
                    retry_leaf = target_leaf;
                    for (m.funcsBySimpleName(target_leaf)) |fid| {
                        const f = m.funcById(fid) orelse continue;
                        if (!f.hasBody()) continue;
                        if (!std.mem.eql(u8, f.fqn, paths[0].fqn)) continue;
                        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
                        const user = f.params.len - 1;
                        const exact = user == args.len;
                        const arity_ok = exact or (args.len < user and blk: {
                            for (f.params[1 + args.len ..]) |p| {
                                if (p.default == null and !p.is_vararg) break :blk false;
                            }
                            break :blk true;
                        }) or (args.len > user and f.params[f.params.len - 1].is_vararg);
                        if (!arity_ok) continue;
                        if (chosen == null or (exact and !chosen_exact)) {
                            chosen = fid;
                            chosen_exact = exact;
                        }
                    }
                }
            }
        }
        if (chosen) |fid| {
            // The by-name scan must not re-pick the executing function when the
            // receiver's own type declares this member; that is a self-loop.
            const self_repick = blk: {
                const cf = ir.eval.currentFrameFunc() orelse break :blk false;
                break :blk cf.id.int() == fid.int() and
                    receiverHasMemberNamed(self, receiver, name);
            };
            if (!self_repick) {
                const mg = self.module.borrow();
                const mod: *const Module = mg.get();
                mg.deinit();
                const call_args = try allocator.alloc(Value, args.len + 1);
                defer allocator.free(call_args);
                call_args[0] = receiver.*;
                @memcpy(call_args[1..], args);
                if (routeTraceOn(name)) std.debug.print("[route] L5263\n", .{});
                return host_call_func.callFunc(self, allocator, mod, fid, call_args);
            }
        }
        if (retry_leaf) |leaf| {
            // No body-bearing overload under the aliased FQN means an intrinsic-backed
            // target: re-dispatch under its real name, guarding against self-recapture.
            const cur = ir.eval.currentFuncName() orelse "";
            if (!std.mem.eql(u8, cur, leaf)) {
                if (routeTraceOn(name)) std.debug.print("[route] L5273\n", .{});
                return callMemberRec(self, allocator, receiver, leaf, args);
            }
        }
    }

    // Dispatch miss: the message carries `Vm::call_member `name` on `fqn``, which
    // downstream fallbacks match to tell a miss for this name from a deeper error.
    // Discard sites free it via `freeDispatchMiss`.
    if (receiver.* == .Instance) {
        // A bare call to an inherited companion function folds into the class's
        // member scope but is not an instance member; resolve it on the companion.
        if (try companionWithMember(self, allocator, receiver, name)) |comp| {
            if (!Value.referenceEq(&comp, receiver)) {
                if (routeTraceOn(name)) std.debug.print("[route] L5289\n", .{});
                return callMemberRec(self, allocator, &comp, name, args);
            }
        }
        // `Outer.Nested(args)` where `Outer` resolved to its companion constructs
        // the enclosing class's nested class.
        if (name.len > 0 and std.ascii.isUpper(name[0])) {
            const enc_fqn: ?[]const u8 = blk: {
                const ig = receiver.Instance.borrow();
                defer ig.deinit();
                const icg = ig.get().class.borrow();
                defer icg.deinit();
                const fqn = icg.get().fqn;
                // A default companion's fqn ends `.Companion`; a named one has fqn
                // `Enclosing.<Name>` and a `$Companion$` marker in its lifted class name.
                if (std.mem.endsWith(u8, fqn, ".Companion"))
                    break :blk fqn[0 .. fqn.len - ".Companion".len];
                if (std.mem.find(u8, icg.get().name, "$Companion$") != null) {
                    if (std.mem.findScalarLast(u8, fqn, '.')) |dot| break :blk fqn[0..dot];
                }
                // An object singleton qualifier lowered to its singleton, so its fqn encloses.
                if (host_globals.progHasObjectName(self, icg.get().name)) break :blk fqn;
                break :blk null;
            };
            if (enc_fqn) |enc| {
                const nested_fqn = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ enc, name });
                defer if (runtime.freeScratch()) allocator.free(nested_fqn);
                // A class nested in the companion itself is keyed under the companion's fqn.
                const own_fqn = blk: {
                    const ig = receiver.Instance.borrow();
                    defer ig.deinit();
                    const icg = ig.get().class.borrow();
                    defer icg.deinit();
                    break :blk try std.fmt.allocPrint(allocator, "{s}.{s}", .{ icg.get().fqn, name });
                };
                defer if (runtime.freeScratch()) allocator.free(own_fqn);
                const cid = blk: {
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    break :blk mg.get().classIdByFqn(own_fqn) orelse mg.get().classIdByFqn(nested_fqn);
                };
                if (cid) |c| return newInstanceById(self, allocator, c, args, null);
            }
        }
        if (try composeMemberPairRetry(self, allocator, receiver, name, args, strict_ext, static_recv, no_ext, declared_recv)) |r| return r;
        // A fake override inheriting `f`'s body from a superclass and `f`'s default from
        // an interface: fill from the interface's default thunk, then run the body.
        if (try fakeOverrideInheritedDefault(self, allocator, receiver, name, args)) |r| return r;
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        missTraceMaybe(name);
        if (missTraceWant(name)) missDumpClassChain(receiver);
        return unimplemented(allocator, "Vm::call_member `{s}` on `{s}`", .{ name, cg.get().fqn });
    }
    // Last resort for named arithmetic operator members, at the miss tail so it
    // never preempts stdlib operator dispatch. `Char` arithmetic by name:
    // `'A'.plus(1)` is a Char, `'B'.minus('A')` an Int, `'B'.minus(1)` a Char.
    if (receiver.* == .Char and args.len == 1) {
        const c: i64 = @intCast(receiver.Char);
        if (std.mem.eql(u8, name, "plus")) {
            if (args[0] == .Int) return .{ .ok = .{ .Char = @intCast(@mod(c + args[0].Int, 0x10000)) } };
        } else if (std.mem.eql(u8, name, "minus")) {
            if (args[0] == .Char) return .{ .ok = Value.newInt(c - @as(i64, @intCast(args[0].Char))) };
            if (args[0] == .Int) return .{ .ok = .{ .Char = @intCast(@mod(c - args[0].Int, 0x10000)) } };
        } else if (std.mem.eql(u8, name, "compareTo")) {
            if (args[0] == .Char) return .{ .ok = Value.newInt(c - @as(i64, @intCast(args[0].Char))) };
        }
    }
    if (isNumericValue(receiver)) {
        if (args.len == 1) {
            if (numericOpMethod(name)) |op| {
                return ir.eval.applyBinop(allocator, op, receiver, &args[0]);
            }
        } else if (args.len == 0) {
            if (std.mem.eql(u8, name, "unaryMinus")) {
                const zero = Value.newInt(0);
                return ir.eval.applyBinop(allocator, .Sub, &zero, receiver);
            }
            if (std.mem.eql(u8, name, "unaryPlus")) return .{ .ok = receiver.* };
        }
    }

    if (try composeMemberPairRetry(self, allocator, receiver, name, args, strict_ext, static_recv, no_ext, declared_recv)) |r| return r;
    // A host-backed value whose runtime class ships interpreted source
    // (`UByteArray` declares `isEmpty`) runs that body, at the total-miss tail.
    {
        const target: ?FuncId = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const module = mg.get();
            const cid = module.classIdByFqn(receiver.typeFqn()) orelse break :blk null;
            const caller_file = if (ir.eval.currentCallSiteSpan()) |sp| sp.file else ir.FileId.from(0);
            const resolved = module.resolveMemberCall(cid, name, &.{}, .{
                .caller_file = caller_file,
                .lexical_owner = null,
                .actual_type_param_bounds = &.{},
            });
            const t = resolved.target orelse break :blk null;
            // Only a member the receiver's own class hierarchy declares may run
            // here; an unrelated namesake reads a representation the value lacks.
            const sig = module.decl_sigs.get(t.int()) orelse break :blk null;
            const owner = sig.enclosing_class orelse break :blk null;
            if (owner.int() != cid.int()) {
                if (owner.int() >= module.classes.items.len) break :blk null;
                const owner_fqn = module.classes.items[owner.int()].fqn;
                const recv_class = &module.classes.items[cid.int()];
                var in_chain = false;
                if (module.registry.class_super_names.get(recv_class.name)) |chain| {
                    for (chain) |cn| {
                        if (std.mem.eql(u8, cn, owner_fqn) or
                            std.mem.eql(u8, typeHeadLast(cn), typeHeadLast(owner_fqn)))
                        {
                            in_chain = true;
                            break;
                        }
                    }
                }
                if (!in_chain) break :blk null;
            }
            break :blk t;
        };
        if (target) |t| {
            if (try invokeMethodFuncId(self, allocator, receiver, t, args)) |r| return r;
        }
    }
    missTraceMaybe(name);
    if (missTraceEnv() != null) {
        std.debug.print("[member-miss] `{s}` on `{s}` span={any}\n", .{ name, receiver.typeFqn(), ir.eval.currentCallSiteSpan() });
        ir.eval.dumpCurrentFrameParamsForDiag();
        ir.eval.debugPrintFrames();
    }
    return unimplemented(allocator, "Vm::call_member `{s}` on `{s}`", .{ name, receiver.typeFqn() });
}

/// Whether the receiver's hierarchy declares a method `name` whose params end with
/// the generated composer pair and whose user arity fits `nargs + 2`: the proof that
/// a miss is an unthreaded call to a threaded composable member.
pub fn receiverHasThreadedMember(self: *VmHost, receiver: *const Value, name: []const u8, nargs: usize) bool {
    if (receiver.* != .Instance) return false;
    const recv_name = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    // Methods live on the class, not the top-level index; walk by simple name.
    var cur: ?[]const u8 = recv_name;
    var hops: usize = 0;
    while (cur) |cn| : (hops += 1) {
        if (hops > 32) break;
        const cid = m.uniqueClassIdBySimpleName(cn) orelse break;
        const class = &m.classes.items[cid.int()];
        for (class.methods) |fid| {
            const f = m.funcById(fid) orelse continue;
            if (!std.mem.eql(u8, f.name, name)) continue;
            if (f.params.len < 3) continue;
            if (!std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer")) continue;
            if (!std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed")) continue;
            const skip: usize = if (std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            // At least the pair beyond the supplied args; a larger gap is a defaulted middle.
            if (f.params.len - skip < nargs + 2) continue;
            return true;
        }
        const supers = m.registry.class_super_names.get(cn) orelse break;
        cur = if (supers.len != 0) supers[0] else null;
    }
    // A threaded composable extension reached by member syntax: same proof over
    // the top-level index, with the declared receiver checked against the chain.
    for (m.funcsBySimpleName(name)) |fid| {
        const f = m.funcById(fid) orelse continue;
        if (f.params.len < 3) continue;
        if (!std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (!std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer")) continue;
        if (!std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed")) continue;
        if (f.params.len - 1 < nargs + 2) continue;
        const recv_head = applicability.simpleName(std.mem.trimEnd(u8, f.params[0].ty.name, "?"));
        if (m.classIsOrExtends(recv_name, recv_head)) return true;
    }
    return false;
}

/// Retries a member dispatch once with the `($composer, $changed)` pair appended,
/// when an ambient composer exists and the receiver has a threaded member.
pub fn composeMemberPairRetry(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8, no_ext: bool, declared_recv: ?[]const u8) Allocator.Error!?EvalResult {
    _ = static_recv;
    _ = no_ext;
    _ = declared_recv;
    if (strict_ext) return null;
    const comp = compose.currentComposer() orelse return null;
    // A retried dispatch already carries the appended pair; recognize it by the
    // composer's identity in the second-to-last slot rather than by a flag.
    if (args.len >= 2 and args[args.len - 1] == .Int and
        args[args.len - 2] == .Instance and comp == .Instance and
        ObjRef(InstanceData).ptrEq(args[args.len - 2].Instance, comp.Instance)) return null;
    if (!receiverHasThreadedMember(self, receiver, name, args.len)) return null;
    const buf = try allocator.alloc(Value, args.len + 2);
    defer if (runtime.freeScratch()) allocator.free(buf);
    @memcpy(buf[0..args.len], args);
    buf[args.len] = comp;
    buf[args.len + 1] = .{ .Int = 0 };
    // The pair binds by name: a threaded member may declare defaulted params
    // between the user args and the pair, so the named walk reorders and fills.
    const names_buf = try allocator.alloc(?[]const u8, args.len + 2);
    defer if (runtime.freeScratch()) allocator.free(names_buf);
    for (names_buf[0..args.len]) |*nn| nn.* = null;
    names_buf[args.len] = "$composer";
    names_buf[args.len + 1] = "$changed";
    const r = try callMemberNamed(self, allocator, receiver, name, buf, names_buf);
    if (r == .ok) return r;
    if (r == .err and r.err != .Unimplemented) return r;
    return null;
}

/// `KLIO_MISS_TRACE=<name>` diagnostic: print the live frame chain when a
/// dispatch for exactly `<name>` reaches the total-miss tail.
pub fn missTraceMaybe(name: []const u8) void {
    if (!missTraceWant(name)) return;
    std.debug.print("[miss] call_member `{s}` total miss\n", .{name});
    ir.eval.dumpFrameChainForDiagAlways();
}

/// `KLIO_MISS_TRACE` helper: dump the receiver's class chain and each class's
/// declared method names, to show whether the name exists on the chain.
pub fn missDumpClassChain(receiver: *const Value) void {
    if (receiver.* != .Instance) return;
    var cur: ?ObjRef(runtime.ClassDef) = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        break :blk g.get().class;
    };
    var depth: usize = 0;
    while (cur) |c| : (depth += 1) {
        if (depth > 12) break;
        const cg = c.borrow();
        const cd = cg.get();
        std.debug.print("[chain {d}] {s} methods:", .{ depth, cd.fqn });
        for (cd.methods) |m| std.debug.print(" {s}", .{m.name});
        std.debug.print(" supers:", .{});
        for (cd.supertype_names) |sn| std.debug.print(" {s}", .{sn});
        std.debug.print(" parent={}\n", .{cd.parent != null});
        const nxt = cd.parent;
        cg.deinit();
        cur = nxt;
    }
}

/// Cached trace gates: `getenvSlice` takes a lock and hashmap probe per consult,
/// and these sit on per-call dispatch paths.
pub var miss_trace_init: bool = false;
pub var miss_trace_val: ?[]const u8 = null;
pub fn missTraceEnv() ?[]const u8 {
    if (!miss_trace_init) {
        miss_trace_val = runtime.envOnce("KLIO_MISS_TRACE");
        miss_trace_init = true;
    }
    return miss_trace_val;
}
pub var nu_trace_init: bool = false;
pub var nu_trace_val: ?[]const u8 = null;
pub fn nuTraceEnv() ?[]const u8 {
    if (!nu_trace_init) {
        nu_trace_val = runtime.envOnce("KLIO_NU_TRACE");
        nu_trace_init = true;
    }
    return nu_trace_val;
}
pub var sam_trace_cached: ?bool = null;
pub fn samTraceOn() bool {
    if (sam_trace_cached) |b| return b;
    const b = runtime.envOnce("KLIO_SAM_TRACE") != null;
    sam_trace_cached = b;
    return b;
}

pub fn missTraceWant(name: []const u8) bool {
    const want = missTraceEnv() orelse return false;
    return std.mem.eql(u8, want, name);
}

/// Free an `Unimplemented` message only when it is the dispatch miss allocated here,
/// recognized by its `Vm::call_member` prefix. No-op under the arena.
pub fn freeDispatchMiss(allocator: Allocator, r: EvalResult) void {
    if (!runtime.freeScratch()) return;
    if (r == .err and r.err == .Unimplemented) {
        const m = r.err.Unimplemented;
        if (std.mem.startsWith(u8, m, "Vm::call_member")) allocator.free(m);
    }
}

/// Whether `r` is the top-level dispatch miss for `name` itself, as opposed to a
/// genuine error raised deeper in a member that did resolve.
pub fn isDispatchMissFor(r: EvalResult, name: []const u8) bool {
    if (!(r == .err and r.err == .Unimplemented)) return false;
    const prefix = "Vm::call_member `";
    const m = r.err.Unimplemented;
    if (!std.mem.startsWith(u8, m, prefix)) return false;
    const rest = m[prefix.len..];
    return rest.len > name.len and std.mem.startsWith(u8, rest, name) and rest[name.len] == '`';
}
