//! The virtual-member dispatch tail and the argument-signature cache keys.

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
    // Vendored persistent-vector scans, as in the callMemberInnerStatic intercept.
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
            if (args.len == 2 and std.mem.eql(u8, vname, "put") and
                persistent_map_mut.isSnapshotMapClass(receiver.Instance))
            {
                if (try persistent_map_mut.trySnapshotMapPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
                    return .{ .ok = v };
                }
            }
        }
    }
    // Replay a stamped host-receiver site: the same interned type FQN means the
    // walk below reaches the same verdict. `stampVirtSite` tags it in low bits.
    if (site) |st| replay: {
        if (receiver.* == .Instance or isCallable(receiver)) break :replay;
        const key: u64 = @intFromPtr(receiver.typeFqn().ptr);
        if (@atomicLoad(u64, st.cls, .monotonic) != key) break :replay;
        const native_raw = @atomicLoad(u64, st.native, .acquire);
        if (native_raw == 0) break :replay;
        const np: [*]const u8 = @ptrFromInt(st.name_ptr.*);
        const mname = np[0..st.name_len.*];
        if (native_raw & 3 == 3) {
            // Slot-op then by-name verdict, the exact tail the probes below
            // reach: a per-receiver decline of the host op falls through.
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
    // Named arguments folded into `arg_params` at lowering must survive every
    // re-dispatching arm below, so derive them back from the slot root's params.
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
    // The slot resolves against the class hierarchy and lands on a defaulted
    // interface member's own body; Kotlin routes it to the delegate instead.
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
            // A callable receiver can still be a host value serving the member
            // natively; by-name dispatch re-borrows, so act outside this borrow.
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
                    // The slot's owner is the call's static receiver type, so an
                    // upcast receiver binds that type's member, not a subtype twin.
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
        // An interface-typed value need not be an interpreted `Instance`, so
        // resolve the slot against its runtime class, then fall back to the name.
        const NonInstanceTarget = struct { target: ?FuncId, name: ?[]const u8 };
        const noinst: NonInstanceTarget = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const module = mg.get();
            const root = FuncId.from(slot.int());
            const mname: ?[]const u8 = if (module.funcById(root)) |f| f.name else null;
            const runtime_class = module.classIdByStaticFqn(receiver.typeFqn()) orelse
                break :blk .{ .target = null, .name = mname };
            // A host-backed receiver runs its members as native intrinsics keyed
            // by its runtime class FQN, the slot's most-derived override.
            if (mname) |n| {
                var fqn_buf: [192]u8 = undefined;
                if (std.fmt.bufPrint(&fqn_buf, "{s}.{s}", .{ receiver.typeFqn(), n })) |member_fqn| {
                    if (lookupIntrinsic(self, member_fqn)) |native| {
                        // A scalar is its own representation, so the same host
                        // symbol by FuncId is the same call; a body is not.
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
                        // A host collection is not a wrapper, so the intrinsic
                        // in hand is what the name walk would reach.
                        const direct = switch (receiver.*) {
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
                // No entry for this class, but the root still names the bound
                // declaration, enough to settle a host-handler builtin by id.
                if (hostSlotOpFor(module, root)) |op| {
                    const nm2: []const u8 = if (module.funcById(root)) |f| f.name else (mname orelse "");
                    // Replay must mirror this tail, op then name walk: a null
                    // `mname` must not stamp, and the op name is the walk name.
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
            // A bodyless declaration linked to a host symbol is executable as
            // that symbol, reached by FuncId instead of by member name.
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
    // A slot is a static hint: with no entry, or nothing to execute behind it,
    // dispatch by name. The declaration may live in the frame's side module.
    const slot_name: ?[]const u8 = blk: {
        if (module.funcById(FuncId.from(slot.int()))) |f| break :blk f.name;
        const fm = ir.eval.currentFrameModule() orelse break :blk null;
        if (fm == module) break :blk null;
        if (fm.funcById(FuncId.from(slot.int()))) |f| break :blk f.name;
        break :blk null;
    };
    // A host-synthesized class implements its members as native intrinsics keyed
    // by its own FQN; its `supertype_names` exist only for type checks.
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
        // Replay the class's resolved-id memo before the string-keyed probe.
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
    // An anonymous class can share the source interface's nominal FQN, so the
    // main-module table lands on a bodyless header; use the runtime identity.
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
    // A slot link on an anonymous receiver class is a supertype guess whose body
    // bypasses shadowing extension properties; a SAM conversion keeps the path.
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

    // The slot resolved to a declaration with no body, no linked host symbol and
    // no SAM callable: dispatch by name rather than entering an empty frame.
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
    // A bodyless header with a linked host symbol serves only receivers whose
    // repr the intrinsic accepts; a declared member has a more derived override.
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

    // A fun-interface instance implements its abstract slot with the SAM callable.
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
    // A memoized contains/indexOf site replays straight to its FuncId, so the
    // vendored scan intercept repeats at the invoker.
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
    // Scalar-replay leaf on the resolved member: the receiver rides as param 0,
    // opaque when non-scalar; a bail falls through to the ordinary invoke.
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
    // A bodyless declaration linked to a host symbol runs as that intrinsic; the
    // fast paths below enter a frame directly, so route it through the linkage.
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
    // The wider leaf shape: a body of argument and field reads combined with
    // primitive operators runs without a frame.
    if (mod.funcById(fid)) |fp| {
        if (fp.has_receiver_param and args_in.len + 1 == fp.params.len and
            args_in.len < ir.LEAF_MAX_REGS)
        {
            // Two tiers: safety builds fill an `undefined` stack array at its
            // declared size on entry, and nearly every call fits eight slots.
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

    // A pass-threaded `@Composable` member publishes its threaded composer as the
    // ambient one: a recompose restart runs the scope with an empty stack.
    const threaded_composer: ?Value = compose.threadedComposerArg(f.params, args_in);
    if (threaded_composer) |c| compose.pushComposer(c);
    defer if (threaded_composer != null) compose.popComposer();

    // A pairless composable member call accepted by the pair-trimmed pick:
    // complete the pair from the ambient composer, or `$composer` binds Unit.
    var pair_ext: ?[]Value = null;
    defer if (pair_ext) |pe| if (runtime.freeScratch()) allocator.free(pe);
    var args = args_in;
    if (f.params.len >= 2 and
        std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed") and
        std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer") and
        args.len + 3 <= f.params.len and threaded_composer == null)
    {
        if (compose.currentComposer()) |c| {
            // A positional append would land the composer in the first open user
            // slot, so bind the pair by name and let the binder fill the defaults.
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

    // A vararg before trailing defaulted parameters consumes the mid-list
    // positional args at its own position, which only the func binder does.
    if (f.params.len > 1) {
        for (f.params[0 .. f.params.len - 1]) |*p| {
            if (p.is_vararg) {
                const all = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(all);
                return try callFuncNamedRec(self, allocator, mod, fid, all, &.{});
            }
        }
    }

    // No vararg tail and a fully applied call: the argument list is exactly
    // `[receiver] ++ args`, built in one allocation into the frame-owned list.
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
    // Kotlin binds the final callable of an under-applied member call to the last
    // function-typed parameter, the gaps taking defaults; the shared binder does.
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

/// Relaxed argument signature for the named member-walk memo; never null. Kotlin
/// erasure forbids overloads differing only by element type, so a kind tag serves.
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

/// Arg-side relaxed variant of `instanceMethodKeyScoped` for the member cache:
/// identical receiver keying, container-kind argument tags, salted apart.
pub fn instanceMethodKeyRelaxed(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    var k = instanceMethodKeyScoped(self, receiver, name, &.{}, static_recv, null) orelse return null;
    k.n_args = @intCast(args.len);
    k.sig = (k.sig ^ methodArgSigRelaxed(self, args)) *% 0x9E3779B97F4A7C15 ^ 0x00C0_FFEE_D00D_5EED;
    if (k.sig == 0) k.sig = 11;
    return k;
}

/// Compact signature of an argument run's types, discriminating the overloads a
/// resolution depends on. Null for an unkeyable argument or more than 12 of them.
pub fn methodArgSig(self: *VmHost, args: []const Value) ?u64 {
    if (args.len == 0) return 0;
    if (args.len > 12) return null;
    // Hash a per-arg type discriminator; an `Instance` folds in its class
    // identity. Any other shape yields no key, so no two types are conflated.
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
            // `kotlin.Unit`, so the runtime shape fixes the type the walk sees.
            .String => 14,
            .Unit => 15,
            // A closure keys by its body identity, folded below: applicability
            // consults the declared shape, never the captured values.
            .IrClosure => 16,
            // A `Null` argument keys soundly: the null-compat check consults
            // only the parameter's declared nullability, never the value.
            .Null => 18,
            // A primitive array keys by prim kind; an object array, whose element
            // type is erased, stays uncacheable.
            .Array => 19,
            // A `Result` keys at exactly typeFqn granularity; its payload is erased.
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

/// Scope-aware cache key: a `static_recv`/`declared_recv`-directed call resolves
/// in the static type's scope, so the scope names fold into `sig`.
pub fn instanceMethodKeyScoped(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8, declared_recv: ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    // Non-Instance receivers with a stable type identity key too. A synthesized
    // identity is forced odd so it never collides with an aligned class pointer.
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
        // A class value resolves purely from the referenced class cell.
        .Class => |c| c.identity(),
        // Runtime shapes whose extension resolution is fixed by the value's type
        // tag at exactly `typeFqn` granularity, prim kind for arrays.
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
