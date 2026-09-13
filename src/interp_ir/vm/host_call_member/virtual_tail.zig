//! The virtual-member tail: `invokeVirtualMember`, `invokeMethodFuncId`, and the
//! argument-signature keys their caches are addressed by.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
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
const StdlibFn = runtime.StdlibFn;
const FuncId = ir.FuncId;
const MethodSlotId = ir.MethodSlotId;
const EvalResult = ir.eval.EvalResult;

const caches = @import("caches.zig");
const virtualSlotInterfaceMember = caches.virtualSlotInterfaceMember;

const flat_call = @import("flat_call.zig");
const callCallableIndexed = flat_call.callCallableIndexed;
const prependReceiver = flat_call.prependReceiver;

const hcm = @import("../host_call_member.zig");
const callFuncIndexedRec = hcm.callFuncIndexedRec;
const callFuncNamedRec = hcm.callFuncNamedRec;
const callFuncRec = hcm.callFuncRec;
const checkFuncInRange = hcm.checkFuncInRange;
const checkReceiverChain = hcm.checkReceiverChain;
const dispatchIntrinsic = hcm.dispatchIntrinsic;
const lookupIntrinsic = hcm.lookupIntrinsic;

const member_ext_visibility = @import("member_ext_visibility.zig");
const interfaceDelegateFor = member_ext_visibility.interfaceDelegateFor;

const member_presence = @import("member_presence.zig");
const memberNameIdentity = member_presence.memberNameIdentity;

const named_call = @import("named_call.zig");
const callMemberNamed = named_call.callMemberNamed;
const callMemberNamedDeclared = named_call.callMemberNamedDeclared;

const receiver_probe = @import("receiver_probe.zig");
const isCallable = receiver_probe.isCallable;
const isFunctionTypeRefResolved = receiver_probe.isFunctionTypeRefResolved;
const packVarargArgs = receiver_probe.packVarargArgs;

const reflect_anon = @import("reflect_anon.zig");
const argsListFromSlice = reflect_anon.argsListFromSlice;
const funcAt = reflect_anon.funcAt;
const padArgsWithDefaultsFor = reflect_anon.padArgsWithDefaultsFor;
const root_mod = reflect_anon.root_mod;

const resolve_method = @import("resolve_method.zig");
const invokeRuntimeVirtualSide = resolve_method.invokeRuntimeVirtualSide;
const runtimeVirtualTarget = resolve_method.runtimeVirtualTarget;
const virtualSlotUnlinkedDiag = resolve_method.virtualSlotUnlinkedDiag;
const virtualTargetExecutable = resolve_method.virtualTargetExecutable;

const slot_ops = @import("slot_ops.zig");
const HostSlotOp = slot_ops.HostSlotOp;
const barrierSpec = slot_ops.barrierSpec;
const hostSlotOpFor = slot_ops.hostSlotOpFor;
const isScalarValue = slot_ops.isScalarValue;
const noinstTraceOn = slot_ops.noinstTraceOn;
const noteSlotByName2 = slot_ops.noteSlotByName2;
const runHostSlotOp = slot_ops.runHostSlotOp;
const slotNameOrNull = slot_ops.slotNameOrNull;
const slotOwnerSimpleName = slot_ops.slotOwnerSimpleName;
const stampVirtSite = slot_ops.stampVirtSite;
const typeSafeBarrierAnswer = slot_ops.typeSafeBarrierAnswer;

const static_tail = @import("static_tail.zig");
const freeDispatchMiss = static_tail.freeDispatchMiss;
const nuTraceEnv = static_tail.nuTraceEnv;

const stdlib_tail = @import("stdlib_tail.zig");
const bridgeForReceiver = stdlib_tail.bridgeForReceiver;
const builtinBridgeDefault = stdlib_tail.builtinBridgeDefault;

pub fn invokeVirtualMember(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    slot: MethodSlotId,
    args: []const Value,
    arg_names_in: []const ?[]const u8,
    arg_params: ?[]const u32,
    site: ?ir.VirtNativeSite,
) Allocator.Error!EvalResult {
    // Vendored persistent-vector scans (see the callMemberInnerStatic
    // intercept): the hot `readable.contains(element)` arrives as a
    // virtual slot, so serve it here too.
    if (args.len == 1 and receiver.* == .Instance) {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vname| {
            if (bridgeForReceiver(self, receiver, vname, args)) |dflt| return .{ .ok = dflt };
            if (std.mem.eql(u8, vname, "contains") or std.mem.eql(u8, vname, "indexOf")) {
                if (persistent_list_eq.tryIndexOf(receiver.Instance, &args[0])) |idx| {
                    if (vname.len == 8) return .{ .ok = .{ .Bool = idx >= 0 } };
                    return .{ .ok = Value.newInt(idx) };
                }
            }
        }
    }
    // Vendored persistent-vector builder bulk ops (see the
    // callMemberInnerStatic intercept): `subList(...).clear()` reaches the
    // builder's `removeRange` as a virtual slot, and `addAll` likewise.
    if ((args.len == 1 or args.len == 2) and receiver.* == .Instance) {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vname| {
            if (args.len == 2 and std.mem.eql(u8, vname, "removeRange")) {
                if (try persistent_list_mut.tryRemoveRange(allocator, receiver.Instance, &args[0], &args[1])) |v| {
                    return .{ .ok = v };
                }
            }
            if (args.len == 1 and std.mem.eql(u8, vname, "addAll")) {
                if (try persistent_list_mut.tryAddAll(allocator, receiver.Instance, &args[0])) |v| {
                    return .{ .ok = v };
                }
            }
        }
    }
    // Map-builder put/build/builder reached as virtual slots.
    if ((args.len == 0 or args.len == 2) and receiver.* == .Instance) {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vname| {
            if (args.len == 2 and std.mem.eql(u8, vname, "put")) {
                if (try persistent_map_mut.tryPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
                    return .{ .ok = v };
                }
            }
            if (args.len == 0 and std.mem.eql(u8, vname, "build")) {
                if (try persistent_map_mut.tryBuild(self, allocator, receiver.Instance)) |v| {
                    return .{ .ok = v };
                }
            }
            if (args.len == 0 and std.mem.eql(u8, vname, "builder")) {
                if (try persistent_map_mut.tryBuilder(self, allocator, receiver.Instance)) |v| {
                    return .{ .ok = v };
                }
            }
            // Whole-cycle SnapshotStateMap.put via its virtual slot.
            if (args.len == 2 and std.mem.eql(u8, vname, "put") and
                persistent_map_mut.isSnapshotMapClass(receiver.Instance))
            {
                if (try persistent_map_mut.trySnapshotMapPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
                    return .{ .ok = v };
                }
            }
        }
    }
    // Replay a stamped host-receiver site: same interned type FQN means the
    // walk below would reach the same verdict, so serve it without the
    // registry probes. Verdicts are tagged in `site_native`'s low bits
    // (see `stampVirtSite`).
    if (site) |st| replay: {
        if (receiver.* == .Instance or isCallable(receiver)) break :replay;
        const key: u64 = @intFromPtr(receiver.typeFqn().ptr);
        if (@atomicLoad(u64, st.cls, .monotonic) != key) break :replay;
        const native_raw = @atomicLoad(u64, st.native, .acquire);
        if (native_raw == 0) break :replay;
        const np: [*]const u8 = @ptrFromInt(st.name_ptr.*);
        const mname = np[0..st.name_len.*];
        if (native_raw & 3 == 3) {
            // Slot-op / by-name verdict: the host op first (a per-receiver
            // decline falls through), then the member-name walk — the exact
            // tail the probes below would have reached.
            const opv = native_raw >> 2;
            if (opv != 0xFF) {
                const op: HostSlotOp = @enumFromInt(@as(u8, @intCast(opv)));
                if (try runHostSlotOp(self, allocator, op, receiver, mname, args)) |r| return r;
            }
            return callMemberNamedDeclared(self, allocator, receiver, mname, args, arg_names_in, slotOwnerSimpleName(self, slot));
        }
        const native: StdlibFn = @ptrFromInt(native_raw);
        var fqn_buf: [192]u8 = undefined;
        const member_fqn = std.fmt.bufPrint(&fqn_buf, "{s}.{s}", .{ receiver.typeFqn(), mname }) catch break :replay;
        var argbuf = try allocator.alloc(Value, args.len + 1);
        defer allocator.free(argbuf);
        argbuf[0] = receiver.*;
        @memcpy(argbuf[1..], args);
        return dispatchIntrinsic(self, allocator, member_fqn, native, argbuf);
    }
    // Named arguments folded into `arg_params` at lowering must survive
    // every re-dispatching arm below (the interface-delegate forward, an
    // unlinked slot, a bodyless target): derive the names back from the
    // slot root's declared params, or a delegated `emit(tag = ..., scale =
    // ...)` re-binds its arguments positionally.
    var derived_names: []?[]const u8 = &.{};
    defer if (derived_names.len != 0 and runtime.freeScratch()) allocator.free(derived_names);
    const arg_names: []const ?[]const u8 = blk: {
        const params = arg_params orelse break :blk arg_names_in;
        if (params.len != args.len) break :blk arg_names_in;
        const mg0 = self.module.borrow();
        defer mg0.deinit();
        const rootf = mg0.get().funcById(FuncId.from(slot.int())) orelse break :blk arg_names_in;
        derived_names = try allocator.alloc(?[]const u8, args.len);
        for (params, derived_names) |ui, *out| {
            const pi = @as(usize, ui) + 1;
            out.* = if (pi < rootf.params.len) rootf.params[pi].name else null;
        }
        break :blk derived_names;
    };
    // A `by`-delegated interface member the class does not override belongs
    // to the delegate. The slot resolves against the class hierarchy, which
    // for a defaulted interface member lands on the interface's own body —
    // Kotlin routes it to the delegate instead.
    if (receiver.* == .Instance) {
        if (virtualSlotInterfaceMember(self, slot)) |name| {
            if (interfaceDelegateFor(self, allocator, receiver.Instance, name)) |d| {
                const r = try callMemberNamed(self, allocator, &d, name, args, arg_names);
                switch (r) {
                    .ok => return r,
                    .err => |e| if (e != .Unimplemented) return r else freeDispatchMiss(allocator, r),
                }
            }
        }
    }
    if (receiver.* != .Instance) {
        if (isCallable(receiver)) {
            const root = FuncId.from(slot.int());
            // A CALLABLE-shaped receiver on a non-interface slot is not an
            // interpreted instance, but it can still be a host value that
            // serves the member natively — `kotlin.concurrent.thread` hands
            // back a handle whose `join`/`isAlive`/`name` the host answers,
            // and once that type carries a real declaration its member calls
            // arrive here as virtual slots. The by-name dispatch is the one
            // that knows those handles, and it re-borrows the module, so the
            // decision is made under the borrow and acted on outside it.
            const decided: union(enum) { by_name: []const u8, err: []const u8, call_iface } = blk_c: {
                const mg = self.module.borrow();
                defer mg.deinit();
                const module = mg.get();
                const sig = module.decl_sigs.get(root.int()) orelse
                    break :blk_c .{ .err = "virtual callable slot has no declaration" };
                const owner = sig.enclosing_class orelse
                    break :blk_c .{ .err = "virtual callable slot has no interface owner" };
                if (sig.has_body or owner.int() >= module.classes.items.len or
                    !module.classes.items[owner.int()].is_interface)
                {
                    if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
                        const mname: []const u8 = if (module.funcById(root)) |f| f.fqn else "?";
                        std.debug.print("[vcall-callable] slot={d} method={s} recv_ty={s} has_body={} nargs={d} caller={s}\n", .{
                            slot.int(),
                            mname,
                            receiver.typeFqn(),
                            sig.has_body,
                            args.len,
                            if (ir.eval.currentFrameFunc()) |f| f.fqn else "<none>",
                        });
                        ir.eval.dumpFrameChainForDiagAlways();
                    }
                    if (module.funcById(root)) |rf| break :blk_c .{ .by_name = rf.name };
                    break :blk_c .{ .err = "virtual call receiver is not an instance" };
                }
                break :blk_c .call_iface;
            };
            switch (decided) {
                .err => |msg| return .{ .err = .{ .Type = msg } },
                .by_name => |mname| {
                    // The slot's owner is the call's static receiver type:
                    // `(this as ClosedRange<Int>).contains(value)` must bind the
                    // `ClosedRange` extension, not a runtime subtype's twin.
                    const named = try callMemberNamedDeclared(self, allocator, receiver, mname, args, arg_names, slotOwnerSimpleName(self, slot));
                    switch (named) {
                        .ok => return named,
                        .err => return .{ .err = .{ .Type = "virtual call receiver is not an instance" } },
                    }
                },
                .call_iface => {},
            }
            const mg = self.module.borrow();
            defer mg.deinit();
            if (arg_params) |params| {
                return callCallableIndexed(self, allocator, mg.get(), root, receiver, receiver, args, params);
            }
            return host_call_value.callValue(self, allocator, receiver, args);
        }
        // A virtual slot names an interface member, and an interface-typed value
        // need not be an interpreted `Instance`: a `Sequence` is a host-backed
        // generator, a `CharSequence` can be a string. Keep slot semantics by
        // resolving the slot against the value's RUNTIME class rather than
        // rejecting the receiver, and fall back to the member's name only when
        // that class implements it natively and there is no body to enter.
        const NonInstanceTarget = struct { target: ?FuncId, name: ?[]const u8 };
        const noinst: NonInstanceTarget = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const module = mg.get();
            const root = FuncId.from(slot.int());
            const mname: ?[]const u8 = if (module.funcById(root)) |f| f.name else null;
            // `typeFqn` on a non-Instance value is a comptime literal, so the
            // pointer-identity memo applies.
            const runtime_class = module.classIdByStaticFqn(receiver.typeFqn()) orelse
                break :blk .{ .target = null, .name = mname };
            // A host-backed receiver executes its members as native
            // intrinsics keyed by its runtime class's FQN, and that binding
            // is the most-derived override of the slot: the interpreted
            // source body reads a source-level representation the host value
            // never materializes (`Result.toString` matches on the `Failure`
            // wrapper; the host Result stores a discriminant and the raw
            // payload). Same rule as the host-synth Instance probe below.
            if (mname) |n| {
                var fqn_buf: [192]u8 = undefined;
                if (std.fmt.bufPrint(&fqn_buf, "{s}.{s}", .{ receiver.typeFqn(), n })) |member_fqn| {
                    if (lookupIntrinsic(self, member_fqn)) |native| {
                        // A SCALAR receiver is its own representation: there
                        // is no wrapper for the by-name walk to unpack, so
                        // reaching the identical host symbol by FuncId is the
                        // same call without the lookup. Wrapper-backed values
                        // (`Result` stores a discriminant and a raw payload,
                        // an `Iterator` is a host generator) keep the walk —
                        // that is where the conversion lives, and binding
                        // them by id returned `Success` for a `Failure`.
                        // Only where the native IS the whole implementation.
                        // A declaration that also carries a BODY is written
                        // against the boxed representation — `UInt.toString()`
                        // is `uintToString(data)`, and `data` does not exist on
                        // a scalar — so reaching it by FuncId runs a body the
                        // receiver cannot satisfy. The by-name walk is what
                        // lands on the intrinsic for those.
                        if (isScalarValue(receiver)) {
                            if (module.methodSlotTarget(runtime_class, slot)) |slot_target| {
                                if (!host_call_func.funcHasBody(self, module, slot_target)) {
                                    if (host_call_func.resolvedNativeForm(self, slot_target)) |target_native| {
                                        if (target_native == native)
                                            break :blk .{ .target = slot_target, .name = n };
                                    }
                                }
                            }
                        }
                        // A host COLLECTION is not a wrapper: `add`/`set`/
                        // `get` take the value as it stands, so the intrinsic
                        // already in hand IS what the walk would land on and
                        // calling it here skips a name search that changes
                        // nothing. Restricted to the container variants —
                        // `Result` and the iterator generators are the shapes
                        // whose conversion lives on the named path.
                        const direct = switch (receiver.*) {
                            // `Array` holds its elements inline, a
                            // `StringBuilder` its bytes, a `Comparator` its
                            // comparison — none of them a discriminant over a
                            // payload the intrinsic would have to unpack. A
                            // `String` and every scalar are likewise their own
                            // representation (the walk lands on this very
                            // native; the FuncId hazard was running a BODY
                            // written against the boxed form, which a direct
                            // NATIVE dispatch never does).
                            .List, .Set, .Map, .Array, .StringBuilder, .Comparator, .String => true,
                            else => isScalarValue(receiver),
                        };
                        if (direct) {
                            stampVirtSite(site, receiver, @intFromPtr(native), n);
                            var argbuf = try allocator.alloc(Value, args.len + 1);
                            defer allocator.free(argbuf);
                            argbuf[0] = receiver.*;
                            @memcpy(argbuf[1..], args);
                            return dispatchIntrinsic(self, allocator, member_fqn, native, argbuf);
                        }
                        stampVirtSite(site, receiver, (0xFF << 2) | 3, n);
                        break :blk .{ .target = null, .name = n };
                    }
                } else |_| {}
            }
            const target = module.methodSlotTarget(runtime_class, slot) orelse {
                // No entry for this class, but the ROOT still names the
                // declaration the call was bound to, and for a builtin whose
                // implementation is a host handler that is enough to settle
                // it by id (`ListIterator.hasPrevious` on a host iterator).
                if (hostSlotOpFor(module, root)) |op| {
                    const nm2: []const u8 = if (module.funcById(root)) |f| f.name else (mname orelse "");
                    // Replay must mirror this exact tail (op, then the name
                    // walk), so a null `mname` — whose fall-through errors
                    // rather than walking — must not stamp, and the op name
                    // must be the walk name.
                    if (mname != null and std.mem.eql(u8, nm2, mname.?))
                        stampVirtSite(site, receiver, (@as(u64, @intFromEnum(op)) << 2) | 3, mname.?);
                    if (try runHostSlotOp(self, allocator, op, receiver, nm2, args)) |r| return r;
                } else if (mname) |n| {
                    stampVirtSite(site, receiver, (0xFF << 2) | 3, n);
                }
                if (runtime.envOnce("KLIO_NOINST_WHY") != null)
                    std.debug.print("[noinst-why] no-slot-entry recv={s} root={s}\n", .{ receiver.typeFqn(), if (module.funcById(root)) |f| f.fqn else "?" });
                break :blk .{ .target = null, .name = mname };
            };
            // A bodyless declaration linked to a host symbol is executable —
            // as that symbol. Dispatching through it is the whole point of
            // binding the slot: it reaches the implementation by FuncId
            // instead of matching the member by string.
            if (!virtualTargetExecutable(module, target) and
                host_call_func.resolvedNativeForm(self, target) == null)
            {
                if (hostSlotOpFor(module, target)) |op| {
                    const nm2: []const u8 = if (module.funcById(target)) |f| f.name else (mname orelse "");
                    if (mname != null and std.mem.eql(u8, nm2, mname.?))
                        stampVirtSite(site, receiver, (@as(u64, @intFromEnum(op)) << 2) | 3, mname.?);
                    if (try runHostSlotOp(self, allocator, op, receiver, nm2, args)) |r| return r;
                } else if (mname) |n| {
                    stampVirtSite(site, receiver, (0xFF << 2) | 3, n);
                }
                if (runtime.envOnce("KLIO_NOINST_WHY") != null)
                    std.debug.print("[noinst-why] target-not-executable recv={s} root={s} target={s}\n", .{ receiver.typeFqn(), if (module.funcById(root)) |f| f.fqn else "?", if (module.funcById(target)) |f| f.fqn else "?" });
                break :blk .{ .target = null, .name = mname };
            }
            if (noinstTraceOn()) {
                std.debug.print("[noinst] recv_ty={s} slot={d} root={s} -> target={s}\n", .{
                    receiver.typeFqn(),
                    slot.int(),
                    if (module.funcById(root)) |f| f.fqn else "?",
                    if (module.funcById(target)) |f| f.fqn else "?",
                });
            }
            break :blk .{ .target = target, .name = mname };
        };
        if (noinst.target) |target| {
            if (arg_params) |params| {
                const mg = self.module.borrow();
                defer mg.deinit();
                return callFuncIndexedRec(
                    self,
                    allocator,
                    mg.get(),
                    target,
                    FuncId.from(slot.int()),
                    receiver,
                    args,
                    params,
                );
            }
            if (try invokeMethodFuncId(self, allocator, receiver, target, args)) |r| return r;
        }
        if (noinst.name) |mname| {
            noteSlotByName2(self, slot, mname, receiver);
            return callMemberNamedDeclared(self, allocator, receiver, mname, args, arg_names, slotOwnerSimpleName(self, slot));
        }
        if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
            const mg = self.module.borrow();
            defer mg.deinit();
            const module = mg.get();
            const root = FuncId.from(slot.int());
            const mname: []const u8 = if (module.funcById(root)) |f| f.fqn else "?";
            std.debug.print("[vcall-noinst] slot={d} method={s} recv_tag={s} recv_ty={s} nargs={d} caller={s}\n", .{
                slot.int(),
                mname,
                @tagName(std.meta.activeTag(receiver.*)),
                receiver.typeFqn(),
                args.len,
                if (ir.eval.currentFrameFunc()) |f| f.fqn else "<none>",
            });
            ir.eval.dumpCurrentFrameParamsForDiag();
            ir.eval.dumpFrameChainForDiagAlways();
        }
        return .{ .err = .{ .Type = "virtual call receiver is not an instance" } };
    }
    const runtime_def = blk: {
        const instance = receiver.Instance.borrow();
        defer instance.deinit();
        break :blk instance.get().class.clone();
    };
    defer runtime_def.deinit();
    const recv_fqn = blk: {
        const class = runtime_def.borrow();
        defer class.deinit();
        break :blk class.get().fqn;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    // A slot is a static hint, not a guarantee that the runtime can honour it.
    // When the receiver's class has no entry for it, or the entry names a
    // declaration with nothing to execute, dispatch by the member's name — the
    // same result the site produced before it was bound, rather than a failure.
    // The slot's declaration may live in the calling frame's SIDE module: a
    // call site lowered inside a local class's method (or a closure in it)
    // reserved its header there, and the main module has no func at that id.
    const slot_name: ?[]const u8 = blk: {
        if (module.funcById(FuncId.from(slot.int()))) |f| break :blk f.name;
        const fm = ir.eval.currentFrameModule() orelse break :blk null;
        if (fm == module) break :blk null;
        if (fm.funcById(FuncId.from(slot.int()))) |f| break :blk f.name;
        break :blk null;
    };
    // A host-synthesized class implements its members as native intrinsics
    // keyed by its own FQN, and that binding is the most-derived override of
    // the slot. The synth's `supertype_names` exist for type checks, so
    // linking the slot through them would enter the supertype's Kotlin body —
    // which reads internal fields the native implementation never
    // materializes. Only anonymous (runtime-built) classes can carry such
    // bindings, so named classes skip the probe.
    if (slot_name) |n| {
        const anon = blk: {
            const class = runtime_def.borrow();
            defer class.deinit();
            break :blk class.get().is_anonymous;
        };
        if (anon) {
            var fqn_buf: [192]u8 = undefined;
            if (std.fmt.bufPrint(&fqn_buf, "{s}.{s}", .{ recv_fqn, n })) |member_fqn| {
                if (lookupIntrinsic(self, member_fqn) != null)
                    return callMemberNamed(self, allocator, receiver, n, args, arg_names);
            } else |_| {}
        }
    }
    const memo_class_id: ?ir.ClassId = cid: {
        // Replay the class's resolved-id memo before the string-keyed
        // registry probe (see `ClassDef.resolve_mod`).
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
    var linked: root_mod.ProgramImage.RuntimeVirtualTarget = if (memo_class_id) |runtime_class|
        .{ .main_func = (module.methodSlotTarget(runtime_class, slot) orelse {
            virtualSlotUnlinkedDiag(module, slot, recv_fqn, args.len, "receiver class");
            if (slot_name) |n| return callMemberNamed(self, allocator, receiver, n, args, arg_names);
            return .{ .err = .{ .Type = "virtual method slot is not linked for receiver class" } };
        }).int() }
    else
        (try runtimeVirtualTarget(self, allocator, module, runtime_def, slot)) orelse {
            virtualSlotUnlinkedDiag(module, slot, recv_fqn, args.len, "runtime class");
            if (slot_name) |n| return callMemberNamed(self, allocator, receiver, n, args, arg_names);
            return .{ .err = .{ .Type = "virtual method slot is not linked for runtime class" } };
        };
    // A runtime-defined or anonymous class can share the source interface's
    // nominal FQN. The main-module table then identifies the correct slot
    // family but lands on its bodyless declaration header; use the runtime
    // class identity to locate the concrete override.
    switch (linked) {
        .main_func => |target| if (!virtualTargetExecutable(module, FuncId.from(target))) {
            linked = (try runtimeVirtualTarget(self, allocator, module, runtime_def, slot)) orelse linked;
        },
        .side_func => {},
    }

    if (linked == .side_func) {
        return invokeRuntimeVirtualSide(
            self,
            allocator,
            module,
            receiver,
            FuncId.from(slot.int()),
            linked.side_func,
            args,
            arg_params,
        );
    }
    // A main-module slot link on an ANONYMOUS receiver class is a
    // supertype-matched guess: the synth lists upstream classes for type
    // checks, and entering the supertype's Kotlin body bypasses the pack's
    // shadowing extension properties. Dispatch by name so the full ladder
    // (host bindings, extension properties, anon methods) serves; a SAM
    // conversion keeps the slot path (its stored lambda is served below by
    // target signature).
    if (linked == .main_func) {
        const anon_recv = blk: {
            const class = runtime_def.borrow();
            defer class.deinit();
            break :blk class.get().is_anonymous;
        };
        if (anon_recv) {
            const sam = blk: {
                const instance = receiver.Instance.borrow();
                defer instance.deinit();
                break :blk instance.get().get("__sam_target__");
            };
            if (sam == null) {
                if (slot_name) |n| return callMemberNamed(self, allocator, receiver, n, args, arg_names);
            }
        }
    }
    const target = FuncId.from(linked.main_func);
    // The type-safe bridge check runs only for the fixed barrier-member
    // names, before the resolved source body binds a foreign argument.
    if (slot_name) |bn| {
        if (barrierSpec(bn)) |kind| {
            if (typeSafeBarrierAnswer(self, module, target, kind, args)) |answer| {
                return .{ .ok = answer };
            }
        }
    }

    // The slot resolved, but to a declaration with nothing behind it: no
    // body, no linked host symbol, and no SAM callable on the instance.
    // Dispatch by name rather than entering an empty frame.
    if (!virtualTargetExecutable(module, target) and
        host_call_func.resolvedNativeForm(self, target) == null)
    {
        const sam = blk: {
            const instance = receiver.Instance.borrow();
            defer instance.deinit();
            break :blk instance.get().get("__sam_target__");
        };
        if (sam == null) {
            if (slot_name) |n| return callMemberNamed(self, allocator, receiver, n, args, arg_names);
        }
    }
    // A bodyless header WITH a linked host symbol is executable — but only
    // for receivers whose runtime REPR the intrinsic serves. An interpreted
    // Instance whose class hierarchy declares the member has a MORE DERIVED
    // interpreted override the name ladder finds; running the header's
    // native form instead fed a `PersistentList` instance to
    // `kotlin.collections.List.isEmpty` (host-List-only). The name ladder
    // still reaches host bindings through its own tails when the hierarchy
    // has no interpreted body.
    if (!virtualTargetExecutable(module, target) and
        host_call_func.resolvedNativeForm(self, target) != null)
    {
        if (slot_name) |n| {
            const declares = blk: {
                const class = runtime_def.borrow();
                defer class.deinit();
                const c = class.get();
                if (module.registry.hierarchy_methods.get(c.name)) |s| {
                    if (s.contains(n)) break :blk true;
                }
                if (module.registry.hierarchy_methods.get(c.fqn)) |s| {
                    if (s.contains(n)) break :blk true;
                }
                break :blk false;
            };
            if (declares) return callMemberNamed(self, allocator, receiver, n, args, arg_names);
        }
    }

    if (arg_params) |params| {
        const sig = module.decl_sigs.get(target.int());
        if (sig != null and !sig.?.has_body) {
            const instance = receiver.Instance.borrow();
            const sam_target = instance.get().get("__sam_target__");
            instance.deinit();
            if (sam_target) |callable| {
                const root = FuncId.from(slot.int());
                return callCallableIndexed(self, allocator, module, root, receiver, &callable, args, params);
            }
        }
        return callFuncIndexedRec(self, allocator, module, target, FuncId.from(slot.int()), receiver, args, params);
    }

    var any_named = false;
    for (arg_names) |name| if (name != null) {
        any_named = true;
        break;
    };

    // A synthetic fun-interface instance implements its abstract slot with
    // the callable stored by SAM conversion, rather than an IR method body.
    if (!any_named) {
        const sig = module.decl_sigs.get(target.int());
        if (sig != null and !sig.?.has_body) {
            const instance = receiver.Instance.borrow();
            const sam_target = instance.get().get("__sam_target__");
            instance.deinit();
            if (sam_target) |callable| {
                return host_call_value.callValue(self, allocator, &callable, args);
            }
        }
    }

    if (!any_named) {
        if (try invokeMethodFuncId(self, allocator, receiver, target, args)) |r| return r;
        if (slot_name) |n| return callMemberNamed(self, allocator, receiver, n, args, arg_names);
        return .{ .err = .{ .Type = "virtual method target is not executable" } };
    }

    const all = try prependReceiver(allocator, receiver, args);
    defer if (runtime.freeScratch()) allocator.free(all);
    const names = try allocator.alloc(?[]const u8, arg_names.len + 1);
    defer if (runtime.freeScratch()) allocator.free(names);
    names[0] = null;
    @memcpy(names[1..], arg_names);
    return callFuncNamedRec(self, allocator, module, target, all, names);
}

pub fn invokeMethodFuncId(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, args_in: []const Value) Allocator.Error!?EvalResult {
    // Vendored persistent-vector scans: a memoized contains/indexOf site
    // replays straight to its FuncId, so the host walk must intercept at
    // the invoker too (see the callMemberInnerStatic intercept).
    if (args_in.len == 1 and receiver.* == .Instance) {
        const fname = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const f = mg.get().funcById(fid) orelse break :blk "";
            break :blk f.name;
        };
        if (blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk if (mg.get().funcById(fid)) |f| builtinBridgeDefault(self, receiver, f, args_in) else null;
        }) |dflt| return .{ .ok = dflt };
        if (std.mem.eql(u8, fname, "contains") or std.mem.eql(u8, fname, "indexOf")) {
            if (persistent_list_eq.tryIndexOf(receiver.Instance, &args_in[0])) |idx| {
                if (fname.len == 8) return .{ .ok = .{ .Bool = idx >= 0 } };
                return .{ .ok = Value.newInt(idx) };
            }
        }
    }
    // Vendored persistent-vector builder bulk ops (see the
    // callMemberInnerStatic intercept): serve a memoized removeRange or
    // addAll site replaying straight to its FuncId.
    if (args_in.len <= 2 and receiver.* == .Instance) {
        const fname2 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const f = mg.get().funcById(fid) orelse break :blk "";
            break :blk f.name;
        };
        if (args_in.len == 2 and std.mem.eql(u8, fname2, "removeRange")) {
            if (try persistent_list_mut.tryRemoveRange(allocator, receiver.Instance, &args_in[0], &args_in[1])) |v| {
                return .{ .ok = v };
            }
        }
        if (args_in.len == 1 and std.mem.eql(u8, fname2, "addAll")) {
            if (try persistent_list_mut.tryAddAll(allocator, receiver.Instance, &args_in[0])) |v| {
                return .{ .ok = v };
            }
        }
        if (args_in.len == 2 and std.mem.eql(u8, fname2, "put")) {
            if (try persistent_map_mut.tryPut(self, allocator, receiver.Instance, &args_in[0], &args_in[1])) |v| {
                return .{ .ok = v };
            }
        }
        if (args_in.len == 0 and std.mem.eql(u8, fname2, "build")) {
            if (try persistent_map_mut.tryBuild(self, allocator, receiver.Instance)) |v| {
                return .{ .ok = v };
            }
        }
        if (args_in.len == 0 and std.mem.eql(u8, fname2, "builder")) {
            if (try persistent_map_mut.tryBuilder(self, allocator, receiver.Instance)) |v| {
                return .{ .ok = v };
            }
        }
    }
    // Scalar-replay leaf on the resolved member: the receiver rides as
    // param 0 (opaque genre when non-scalar — a body that touches it
    // bails); a bail falls through to the ordinary invoke, which re-runs
    // the pure body exactly.
    leaf: {
        if (receiver.* == .Null) break :leaf;
        const mg2 = self.module.borrow();
        defer mg2.deinit();
        const m2 = mg2.get();
        const lf = m2.funcById(fid) orelse break :leaf;
        if (args_in.len + 1 > 8) break :leaf;
        var all: [8]Value = undefined;
        all[0] = receiver.*;
        for (args_in, 0..) |a, i| all[i + 1] = a;
        if (try ir.eval.tryLeafValues(VmHost, allocator, m2, lf, all[0 .. args_in.len + 1], self, null)) |lo| switch (lo) {
            .val => |v| return .{ .ok = v },
            .raise => |e| return .{ .err = e },
        };
    }
    ir.eval.dispatchNote(.served_user_body);
    runtime.prof.opRoute(4);
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const f = funcAt(mod, fid) orelse return null;
    // A bodyless declaration linked to a host symbol runs as that intrinsic,
    // not as an empty frame. Every fast path below enters a frame directly, so
    // route it through the general call path, which consults the linkage.
    if (!f.hasBody() and host_call_func.resolvedNativeForm(self, fid) != null) {
        const all = try prependReceiver(allocator, receiver, args_in);
        defer if (runtime.freeScratch()) allocator.free(all);
        return try callFuncRec(self, allocator, mod, fid, all);
    }
    // Frameless serve for the canonical getter shape on a claimed class.
    // Uses the module-owned func pointer so the shape/route memo persists.
    if (args_in.len == 0) {
        if (mod.funcById(fid)) |fp| {
            if (vmhost.host_fields.accessorFastGet(self, mod, fp, receiver)) |r| return r;
        }
    }
    // The wider leaf-expression shape: a body that only reads its arguments
    // and stored fields and combines them with primitive operators runs
    // without a frame.
    if (mod.funcById(fid)) |fp| {
        if (fp.has_receiver_param and args_in.len + 1 == fp.params.len and
            args_in.len < ir.LEAF_MAX_REGS)
        {
            // Two tiers: safety builds 0xAA-fill an `undefined` stack array
            // at its DECLARED size on every entry, and the 64-slot buffer's
            // 2.5KB fill was a top profile frame across member-call-heavy
            // suites. Nearly every call fits eight slots.
            if (args_in.len + 1 <= 8) {
                var argbuf: [8]Value = undefined;
                argbuf[0] = receiver.*;
                for (args_in, 0..) |a, i| argbuf[i + 1] = a;
                if (try ir.eval.leafExprServe(VmHost, allocator, mod, fp, argbuf[0 .. args_in.len + 1], self)) |r| return r;
            } else {
                var argbuf: [ir.LEAF_MAX_REGS]Value = undefined;
                argbuf[0] = receiver.*;
                for (args_in, 0..) |a, i| argbuf[i + 1] = a;
                if (try ir.eval.leafExprServe(VmHost, allocator, mod, fp, argbuf[0 .. args_in.len + 1], self)) |r| return r;
            }
        }
    }
    if (nuTraceEnv()) |want| {
        if (std.mem.eql(u8, want, f.name)) {
            std.debug.print("[invoke-method] {s}#{d} params={d} recv={s} args=", .{ f.fqn, fid.int(), f.params.len, receiver.typeFqn() });
            for (args_in) |a| switch (a) {
                .Int => |v| std.debug.print(" Int({d})", .{v}),
                else => std.debug.print(" {s}", .{@tagName(a)}),
            };
            std.debug.print("\n", .{});
        }
    }

    // A pass-threaded `@Composable` member method re-invoked during recompose
    // (`this.Child($composer, $changed)`) must publish its threaded composer as
    // the ambient composer for the call, exactly like the free-function
    // (`composableEval`) and value-call paths: a `@Composable` property getter
    // reached from the body (e.g. `currentRecomposeScope`) reads it through the
    // `__compose_currentComposer` intrinsic. Initial composition masks the miss
    // because the enclosing composable's composer is still on the stack; a
    // restart re-invocation runs the invalidated scope directly with an empty
    // stack. A member `f.params` carries the receiver as an explicit leading
    // `this` param, while `args` is receiver-excluded — `threadedComposerArg`
    // handles that alignment.
    const threaded_composer: ?Value = compose.threadedComposerArg(f.params, args_in);
    if (threaded_composer) |c| compose.pushComposer(c);
    defer if (threaded_composer != null) compose.popComposer();

    // Pairless composable member call accepted by the pair-trimmed pick
    // (`ReadStringCompositionLocal(local)` against `(this, local, $composer,
    // $changed)`): complete the pair from the ambient composer before
    // binding, or the body runs with Unit in `$composer`.
    var pair_ext: ?[]Value = null;
    defer if (pair_ext) |pe| if (runtime.freeScratch()) allocator.free(pe);
    var args = args_in;
    if (f.params.len >= 2 and
        std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed") and
        std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer") and
        args.len + 3 <= f.params.len and threaded_composer == null)
    {
        if (compose.currentComposer()) |c| {
            // Defaulted user params omitted at the call site (`Test()` against
            // `(this, number$arg = marker, $composer, $changed)`): a positional
            // append would land the composer in the first open user slot, so
            // bind the pair BY NAME and let the named binder fill the middle
            // defaults.
            if (args.len + 3 < f.params.len) {
                const all = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(all);
                const full = try allocator.alloc(Value, all.len + 2);
                defer if (runtime.freeScratch()) allocator.free(full);
                @memcpy(full[0..all.len], all);
                full[all.len] = c;
                full[all.len + 1] = .{ .Int = 0 };
                const names = try allocator.alloc(?[]const u8, full.len);
                defer if (runtime.freeScratch()) allocator.free(names);
                for (names[0..all.len]) |*n| n.* = null;
                names[all.len] = "$composer";
                names[all.len + 1] = "$changed";
                compose.pushComposer(c);
                defer compose.popComposer();
                return try callFuncNamedRec(self, allocator, mod, fid, full, names);
            }
            const pe = try allocator.alloc(Value, args.len + 2);
            @memcpy(pe[0..args.len], args);
            pe[args.len] = c;
            pe[args.len + 1] = .{ .Int = 0 };
            pair_ext = pe;
            args = pe;
            compose.pushComposer(c);
        }
    }
    const pushed_completed = pair_ext != null;
    defer if (pushed_completed) compose.popComposer();

    // Non-final vararg (a vararg before trailing defaulted / named-only params):
    // the prepend + trailing-collapse path cannot bind it — the vararg must
    // consume the mid-list positional args at its own position while the
    // trailing parameters take their defaults. Route through the reorder-aware
    // func binder (receiver prepended, all-positional), which handles it.
    if (f.params.len > 1) {
        for (f.params[0 .. f.params.len - 1]) |*p| {
            if (p.is_vararg) {
                const all = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(all);
                return try callFuncNamedRec(self, allocator, mod, fid, all, &.{});
            }
        }
    }

    // Fast path: no vararg tail and the call is fully applied (no default
    // padding), so the frame argument list is exactly `[receiver] ++ args`.
    // Build it in one allocation directly into the frame-owned list, skipping
    // the `prependReceiver` scratch slice + its copy/free (a per-call win on the
    // hot member-dispatch path).
    const has_vararg = f.params.len > 0 and f.params[f.params.len - 1].is_vararg;
    if (!has_vararg and args.len + 1 >= f.params.len) {
        var list = try ir.eval.acquireArgsCap(allocator, args.len + 1);
        list.appendAssumeCapacity(receiver.*);
        list.appendSliceAssumeCapacity(args);
        if (trace.invariantsEnabled()) {
            checkFuncInRange(self, "irMethodWalk", f.id);
            checkReceiverChain(self, allocator, "irMethodWalk", receiver, null);
        }
        vmhost.emitPath(allocator, "member_ir_walk", f.fqn, f.id, receiver, args);
        return try ir.eval.evalWith(VmHost, allocator, mod, &f, list, self);
    }

    var all = try prependReceiver(allocator, receiver, args);
    // Kotlin trailing-lambda rule for an under-applied member call: the final
    // supplied callable binds the LAST function-typed parameter, with the
    // intervening defaulted parameters filled from their defaults rather than
    // bound left-to-right. `padArgsWithDefaults` fills positionally (lambda →
    // first gap param), so route this shape through the shared positional
    // binder, which implements the rule uniformly (and varargs/defaults).
    if (all.len < f.params.len and all.len != 0 and
        isFunctionTypeRefResolved(self, &f.params[f.params.len - 1].ty) and
        isCallable(&all[all.len - 1]) and (all.len - 1) < (f.params.len - 1))
    {
        if (reflect_anon.trailing_member_call) host_call_func.setTrailingLambdaCall(true);
        const r = try callFuncRec(self, allocator, mod, fid, all);
        host_call_func.setTrailingLambdaCall(false);
        if (runtime.freeScratch()) allocator.free(all);
        return r;
    }
    const defaults = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (pg.get().func_defaults.get(@intFromEnum(fid))) |d| break :blk try allocator.dupe(?FuncId, d);
        break :blk null;
    };
    defer if (defaults) |d| if (runtime.freeScratch()) allocator.free(d);
    if (defaults != null and all.len < f.params.len) {
        const padded = try padArgsWithDefaultsFor(self, allocator, mod, f.params.len, all, defaults, f.params);
        switch (padded) {
            .ok => |p| {
                if (runtime.freeScratch()) allocator.free(all);
                all = p;
            },
            .err => |e| {
                if (runtime.freeScratch()) allocator.free(all);
                return .{ .err = e };
            },
        }
    }
    const packed_args = try packVarargArgs(self, allocator, &f, all);
    var packed_list = try argsListFromSlice(allocator, packed_args);
    if (runtime.freeScratch()) allocator.free(packed_args);
    _ = &packed_list;
    if (trace.invariantsEnabled()) {
        checkFuncInRange(self, "irMethodWalk", f.id);
        checkReceiverChain(self, allocator, "irMethodWalk", receiver, null);
    }
    vmhost.emitPath(allocator, "member_ir_walk", f.fqn, f.id, receiver, args);
    return try ir.eval.evalWith(VmHost, allocator, mod, &f, packed_list, self);
}

/// Build the inline-cache key for an instance method call, or `null` for a
/// non-Instance receiver. Keyed by class-cell identity + interned method-name
/// pointer + arity (all stable for the program lifetime).
/// Compact signature of an argument run's primitive types, distinguishing the
/// overloads a method-name resolution can depend on. Returns null for a
/// non-primitive arg (or > 12 args), which means "do not cache this call" — the
/// resolution then re-runs each time rather than risk a wrong cross-type hit.
/// Relaxed argument signature for the NAMED member-walk memo: never null.
/// Where the strict signature declines container shapes (their extension
/// applicability inspects value content), member OVERLOADS cannot differ
/// only by a generic element type (Kotlin erasure forbids it), so a
/// container KIND tag discriminates every declarable member overload set.
/// Instances still fold class identity; closures fold body identity.
pub fn methodArgSigRelaxed(self: *VmHost, args: []const Value) u64 {
    var h = std.hash.Wyhash.init(0x452821e638d01377 +% args.len);
    for (args) |*a| {
        const tag: u8 = @intFromEnum(std.meta.activeTag(a.*));
        h.update((&tag)[0..1]);
        switch (a.*) {
            .Instance => |inst| {
                const id = runtime.InstanceData.classIdentityUnlocked(inst);
                h.update(std.mem.asBytes(&id));
            },
            .IrClosure => |c| {
                if (self.closures.get(@intCast(c.asPtr().id))) |info| {
                    h.update(std.mem.asBytes(&info.body_func));
                }
            },
            .Array => |arr| {
                const pk: u8 = if (arr.primKind()) |p| @as(u8, @intFromEnum(p)) + 1 else 0;
                h.update((&pk)[0..1]);
            },
            else => {},
        }
    }
    const v = h.final();
    return if (v == 0) 1 else v;
}

/// Arg-side RELAXED variant of `instanceMethodKeyScoped` for the MEMBER
/// cache only: receiver keying rules are identical (identity-keyable
/// receivers only — receiver-side relaxation is where the measured
/// regressions lived), but the arg signature uses container-kind tags
/// (see `methodArgSigRelaxed`), which fully discriminate any declarable
/// member overload set under Kotlin erasure. Salted apart from strict
/// entries. The extension caches never use this key.
pub fn instanceMethodKeyRelaxed(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    var k = instanceMethodKeyScoped(self, receiver, name, &.{}, static_recv, null) orelse return null;
    k.n_args = @intCast(args.len);
    k.sig = (k.sig ^ methodArgSigRelaxed(self, args)) *% 0x9E3779B97F4A7C15 ^ 0x00C0_FFEE_D00D_5EED;
    if (k.sig == 0) k.sig = 11;
    return k;
}

pub fn methodArgSig(self: *VmHost, args: []const Value) ?u64 {
    if (args.len == 0) return 0;
    if (args.len > 12) return null;
    // Hash a per-arg type discriminator. Primitives contribute their tag;
    // an `Instance` also folds in its class identity, so an overload picked
    // by the argument's class (`LocalDate.plus(DatePeriod)` vs
    // `LocalDate.plus(DateTimeUnit)`) gets a distinct, cacheable key rather
    // than the pre-hash scheme's "non-primitive → no key" bail. Any other
    // value shape yields no key (that call re-resolves) so the cache never
    // conflates argument types the overload dispatch would distinguish.
    var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15 +% args.len);
    for (args) |*a| {
        const tag: u8 = switch (a.*) {
            .Int => 1,
            .Long => 2,
            .Double => 3,
            .Float => 4,
            .Short => 5,
            .Byte => 6,
            .Char => 7,
            .Bool => 8,
            .UInt => 9,
            .ULong => 10,
            .UShort => 11,
            .UByte => 12,
            .Instance => 13,
            // A `String` is always `kotlin.String` and a `Unit` always
            // `kotlin.Unit`: their runtime shape fully fixes the type the
            // overload walk sees, so folding a stable tag is sound and keeps
            // the common String-argument calls (pervasive on the coroutine
            // resume path) on the inline-cache fast path. `Null` stays
            // uncacheable — it matches any nullable parameter, so its
            // resolution is not a pure function of the value shape.
            .String => 14,
            .Unit => 15,
            // A closure argument keys by its BODY identity (folded below):
            // overload applicability consults the declared shape, a pure
            // function of the body, never the captured values. Without a
            // tag every call carrying a lambda had no key at all, and
            // extension-heavy lambda-argument code re-ran the full
            // extension walk per call.
            .IrClosure => 16,
                        // A `Null` argument at a fixed position keys soundly: the walk
            // scores an identical tag vector identically every time (its
            // null-compat check consults only the PARAM's declared
            // nullability), so the resolution is a pure function of the
            // key. Excluding it made every nullable-trailing-arg call
            // (`resumeCancellableWithInternal`'s `onCancellation = null`)
            // re-walk per call.
            .Null => 18,
            // A PRIMITIVE array argument keys by its prim kind — the same
            // granularity the receiver-identity case uses; an object array
            // (erased element type) stays uncacheable.
            .Array => 19,
            // A `Result` argument is `kotlin.Result` at exactly typeFqn
            // granularity (the payload type is erased), mirroring the
            // receiver-identity case. The coroutine resume path passes one
            // on every `resumeWith`-family call.
            .Result => 20,
            else => return null,
        };
        h.update((&tag)[0..1]);
        switch (a.*) {
            .Instance => |inst| {
                const id = runtime.InstanceData.classIdentityUnlocked(inst);
                h.update(std.mem.asBytes(&id));
            },
            .Array => |arr| {
                const pk: u8 = if (arr.primKind()) |p| @as(u8, @intFromEnum(p)) + 1 else return null;
                h.update((&pk)[0..1]);
            },
            .IrClosure => |c| {
                const info = self.closures.get(@intCast(c.asPtr().id)) orelse return null;
                h.update(std.mem.asBytes(&info.body_func));
                const mp: usize = @intFromPtr(info.module);
                h.update(std.mem.asBytes(&mp));
            },
            else => {},
        }
    }
    const v = h.final();
    // 0 is reserved for the empty-arg case; the key also carries `n_args`,
    // so a non-empty sig colliding to 0 stays distinct from `args.len == 0`.
    return if (v == 0) 1 else v;
}

pub fn instanceMethodKey(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value) ?root_mod.ProgramImage.InstanceMethodKey {
    return instanceMethodKeyScoped(self, receiver, name, args, null, null);
}

/// Scope-aware cache key. A `static_recv`/`declared_recv`-directed call
/// resolves in the STATIC type's scope, not the runtime class's, so its
/// resolution must never be conflated with the unscoped one — `Map.getOrElse`'s
/// inlined `get` must not be served a cached subtype `get<T>` (which
/// self-recurses), nor vice versa. Folding the scope names into `sig` keeps
/// both resolutions cached under distinct keys; resolution is a pure function
/// of (class, name, arg-sig, scope), so each entry stays sound.
pub fn instanceMethodKeyScoped(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8, declared_recv: ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    // Non-Instance receivers with a stable type identity key too: a
    // closure's resolution is fixed by its BODY (the declared shape —
    // arity, receiver head, suspendness — is a pure function of the body
    // func), and a `Result`'s by its tag (extensions on `Result<T>` are
    // erased). The synthesized identity is forced ODD so it can never
    // collide with a real class-cell pointer (those are aligned). The
    // hot coroutine boundary (`startCoroutineUninterceptedOrReturn` on a
    // suspend block, `throwOnFailure` on a `Result`) re-ran the full
    // extension walk per call without this.
    const class_identity: usize = switch (receiver.*) {
        .Instance => |inst| runtime.InstanceData.classIdentityUnlocked(inst),
        .IrClosure => |c| blk: {
            const info = self.closures.get(@intCast(c.asPtr().id)) orelse return null;
            var h = std.hash.Wyhash.init(0x2545f4914f6cdd1d);
            h.update(std.mem.asBytes(&info.body_func));
            const mp: usize = @intFromPtr(info.module);
            h.update(std.mem.asBytes(&mp));
            break :blk h.final() | 1;
        },
        .Result => 0x5261 | 1,
        // A CLASS value (`Snapshot`'s companion-forwarding class receiver, a
        // `::class`): member/extension resolution is a pure function of the
        // referenced class cell — `currentSnapshot` on the snapshot companion
        // class re-ran the full extension walk 90k times per benchmark.
        .Class => |c| c.identity(),
        // Runtime shapes whose extension resolution is fully fixed by the
        // value's type tag, at exactly `typeFqn` granularity (prim kind for
        // arrays, kind + step-refinement for ranges). Identities are forced
        // ODD so they never collide with an aligned class-cell pointer.
        .Array => |arr| blk: {
            const k: usize = if (arr.primKind()) |pk| @as(usize, @intFromEnum(pk)) + 1 else 0;
            break :blk (0xA100 + (k << 8)) | 1;
        },
        .Int => 0xA401 | 1,
        .Long => 0xA411 | 1,
        .Short => 0xA421 | 1,
        .Byte => 0xA431 | 1,
        .UInt => 0xA441 | 1,
        .ULong => 0xA451 | 1,
        .UShort => 0xA461 | 1,
        .UByte => 0xA471 | 1,
        .Double => 0xA481 | 1,
        .Float => 0xA491 | 1,
        .Bool => 0xA4A1 | 1,
        .Char => 0xA4B1 | 1,
        else => return null,
    };
    var sig = methodArgSig(self, args) orelse return null;
    if (static_recv != null or declared_recv != null) {
        var h = std.hash.Wyhash.init(0x517cc1b727220a95);
        if (static_recv) |s| h.update(s);
        h.update(&[_]u8{0});
        if (declared_recv) |d| h.update(d);
        sig ^= h.final();
        // Keep 0 reserved for the unscoped empty-arg case.
        if (sig == 0) sig = 1;
    }
    const name_p = memberNameIdentity(self, name) orelse return null;
    return .{
        .class_p = class_identity,
        .name_p = name_p,
        .n_args = @intCast(args.len),
        .sig = sig,
    };
}
