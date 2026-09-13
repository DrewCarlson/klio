//! Reflection-shaped receivers (bound references, property references, `KClass` /
//! `KFunction` members) and anonymous/local class method dispatch.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const VmHost = vmhost.VmHost;
const host_call_func = @import("../host_call_func.zig");
const host_call_value = @import("../host_call_value.zig");
const host_fields = @import("../host_fields.zig");
const builtin_members = @import("../builtin_members.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const valueStructuralHash = builtin_members.valueStructuralHash;

const applicability_probe = @import("applicability_probe.zig");
const argDefinitelyNotParamType = applicability_probe.argDefinitelyNotParamType;

const binding_probe = @import("binding_probe.zig");
const extWithThisLongerThanArgs = binding_probe.extWithThisLongerThanArgs;
const lookupGlobalValue = binding_probe.lookupGlobalValue;

const flat_call = @import("flat_call.zig");
const listOf = flat_call.listOf;

const hcm = @import("../host_call_member.zig");
const boolVal = hcm.boolVal;
const callMemberRec = hcm.callMemberRec;
const callValueRec = hcm.callValueRec;
const getFieldRec = hcm.getFieldRec;
const simpleName = hcm.simpleName;
const typeErr = hcm.typeErr;

const member_ext_visibility = @import("member_ext_visibility.zig");
const boundRefFile = member_ext_visibility.boundRefFile;

const receiver_probe = @import("receiver_probe.zig");
const fidTypeVar = receiver_probe.fidTypeVar;
const inheritedMemberDefaults = receiver_probe.inheritedMemberDefaults;
const isCallable = receiver_probe.isCallable;
const memberIsProperty = receiver_probe.memberIsProperty;
const packVarargArgs = receiver_probe.packVarargArgs;
const receiverImplementsType = receiver_probe.receiverImplementsType;

const static_tail = @import("static_tail.zig");
const freeDispatchMiss = static_tail.freeDispatchMiss;
const isDispatchMissFor = static_tail.isDispatchMissFor;
const missTraceEnv = static_tail.missTraceEnv;

const stdlib_tail = @import("stdlib_tail.zig");
const builtinBridgeDefault = stdlib_tail.builtinBridgeDefault;

pub fn boundRefDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var rc: ?Value = null;
    var n_str: ?[]const u8 = null;
    var exact_func: ?FuncId = null;
    {
        const g = inst.borrow();
        rc = g.get().get("__bound_receiver__");
        if (g.get().get("__bound_name__")) |nv| {
            if (nv == .String) {
                const sg = nv.String.borrow();
                n_str = sg.get().bytes;
                sg.deinit();
            }
        }
        if (g.get().get("__bound_func__")) |fv| {
            if (fv == .Int and fv.Int >= 0) exact_func = FuncId.from(@intCast(fv.Int));
        }
        g.deinit();
    }
    if (rc == null or n_str == null) return null;
    const recv_capt = rc.?;
    const n = n_str.?;
    if (runtime.envOnce("KLIO_ERR_TRACE") != null) std.debug.print("[boundref-dispatch] {s} via {s} recv={s} args={d} exact={}\n", .{ n, name, recv_capt.typeFqn(), args.len, exact_func != null });
    if (std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "simpleName")) {
        return null; // handled by get_field
    }
    // `KMutableProperty.set` / `KProperty.get`: an UNBOUND property
    // reference (`T::prop`, captured receiver = the class) takes the target
    // first; a bound one uses the captured receiver.
    if (std.mem.eql(u8, name, "set") or std.mem.eql(u8, name, "get")) {
        // Arity decides bound vs unbound: `T::prop` captures the CLASS (or
        // its companion stand-in) and takes the target first; `x::prop`
        // captures the instance. `set` is 2 args unbound / 1 bound; `get`
        // is 1 / 0.
        if (std.mem.eql(u8, name, "set")) {
            if (args.len == 2) {
                switch (try host_fields.setField(self, allocator, &args[0], n, args[1])) {
                    .ok => return .{ .ok = .Unit },
                    .err => |e| return .{ .err = e },
                }
            }
            if (args.len == 1 and recv_capt != .Class) {
                switch (try host_fields.setField(self, allocator, &recv_capt, n, args[0])) {
                    .ok => return .{ .ok = .Unit },
                    .err => |e| return .{ .err = e },
                }
            }
        } else {
            if (args.len == 1) {
                return try host_fields.getField(self, allocator, &args[0], n);
            }
            if (args.len == 0 and recv_capt != .Class) {
                return try host_fields.getField(self, allocator, &recv_capt, n);
            }
        }
    }
    // Dispatch under the reference's creation-site file (private
    // visibility is decided where the reference was written).
    var ref_pushed = false;
    var ref_prev: ?ir.eval.RefSiteOverride = null;
    if (boundRefFile(receiver)) |bf| {
        ref_prev = ir.eval.pushRefSiteFile(bf);
        ref_pushed = true;
    }
    defer if (ref_pushed) ir.eval.popRefSiteFile(ref_prev);
    if (exact_func) |func| {
        if (std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "call")) {
            var exact_args: std.ArrayList(Value) = .empty;
            defer exact_args.deinit(allocator);
            if (recv_capt == .Class) {
                try exact_args.appendSlice(allocator, args);
            } else {
                try exact_args.append(allocator, recv_capt);
                try exact_args.appendSlice(allocator, args);
            }
            const mg = self.module.borrow();
            defer mg.deinit();
            return try host_call_func.callFunc(
                self,
                allocator,
                mg.get(),
                func,
                exact_args.items,
            );
        }
    }
    // Property-delegation protocol on a bound property reference
    // (`var x by data::prop` / `by Data::prop`): read/write the
    // referenced property. A Class-bound ref takes the instance from
    // the delegation call's thisRef argument.
    if (std.mem.eql(u8, name, "getValue") and args.len >= 2) {
        const target: *const Value = if (recv_capt == .Class) &args[0] else &recv_capt;
        var r = try getFieldRec(self, allocator, target, n);
        if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
        return r;
    }
    if (std.mem.eql(u8, name, "setValue") and args.len >= 3) {
        const target: *const Value = if (recv_capt == .Class) &args[0] else &recv_capt;
        return switch (try host_fields.setField(self, allocator, target, n, args[2])) {
            .ok => .{ .ok = .Unit },
            .err => |e| .{ .err = e },
        };
    }
    // `ref.set(v)` on a bound mutable property reference.
    if (std.mem.eql(u8, name, "set") and recv_capt != .Class and args.len == 1) {
        return switch (try host_fields.setField(self, allocator, &recv_capt, n, args[0])) {
            .ok => .{ .ok = .Unit },
            .err => |e| .{ .err = e },
        };
    }
    if (std.mem.eql(u8, name, "set") and recv_capt == .Class and args.len == 2) {
        return switch (try host_fields.setField(self, allocator, &args[0], n, args[1])) {
            .ok => .{ .ok = .Unit },
            .err => |e| .{ .err = e },
        };
    }
    if (recv_capt == .Class) {
        if ((std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "call") or std.mem.eql(u8, name, "invoke")) and args.len != 0) {
            const first = args[0];
            const rest = args[1..];
            if (rest.len == 0 and (memberIsProperty(self, &first, n) or
                (!host_call_value.extensionFnNamed(self, n) and host_fields.hostHasExtProp(self, allocator, &first, n))))
            {
                // getFieldRec returns the field borrowed; this escapes as a
                // callMember return whose register takes ownership, so retain.
                var r = try getFieldRec(self, allocator, &first, n);
                if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
                return r;
            }
            const r = try callMemberRec(self, allocator, &first, n, rest);
            // `Int::extProp` invoked with its receiver reads the extension
            // property once the member forward has missed the name itself.
            if (rest.len == 0 and isDispatchMissFor(r, n)) {
                var r2 = try getFieldRec(self, allocator, &first, n);
                if (runtime.envOnce("KLIO_ERR_TRACE") != null) std.debug.print("[boundref-unbound] {s} on {s}: field read {s}\n", .{ n, first.typeFqn(), if (r2 == .ok) "ok" else "miss" });
                if (r2 == .ok) {
                    freeDispatchMiss(allocator, r);
                    if (runtime.reclaimEnabled()) r2.ok.retain();
                    return r2;
                }
            }
            if (runtime.envOnce("KLIO_ERR_TRACE") != null) std.debug.print("[boundref-unbound] {s} on {s}: forward {s}\n", .{ n, first.typeFqn(), if (r == .ok) "ok" else "err" });
            return r;
        }
        return null;
    }
    if ((std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "call") or std.mem.eql(u8, name, "invoke")) and
        args.len == 0 and memberIsProperty(self, &recv_capt, n))
    {
        var r = try getFieldRec(self, allocator, &recv_capt, n);
        if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
        return r;
    }
    // A bound EXTENSION-property reference (`local::extVal`): the name is
    // not a member of the receiver's class, but `get()` still reads the
    // property — the field path resolves extension getters and delegated
    // extension properties. Only a clean read wins; a miss falls through
    // to the bound-method forward below.
    if (std.mem.eql(u8, name, "get") and args.len == 0) {
        var r = try getFieldRec(self, allocator, &recv_capt, n);
        if (r == .ok) {
            if (runtime.reclaimEnabled()) r.ok.retain();
            return r;
        }
    }
    // An EXTENSION declared on a function type serves the reference itself,
    // not the member it names: `source::produce` is a `() -> Int`, so
    // `.asFlow()` on it is `(() -> T).asFlow()`. Forwarding every unknown
    // name to the bound member turned that into `produce()`'s value. Decline
    // so the ordinary member/extension walk runs; `invoke`/`call` are the
    // reference's own surface and keep forwarding.
    if (!std.mem.eql(u8, name, "invoke") and !std.mem.eql(u8, name, "call") and
        extWithThisLongerThanArgs(self, name, args.len)) return null;
    // Bound method reference: forward the call.
    const r = try callMemberRec(self, allocator, &recv_capt, n, args);
    if ((std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "call")) and r == .err and r.err == .Unimplemented) {
        // A bound EXTENSION-property reference invoked (`(::extProp)()`)
        // reads the property once the member forward has missed the name.
        if (args.len == 0 and isDispatchMissFor(r, n)) {
            var r2 = try getFieldRec(self, allocator, &recv_capt, n);
            if (r2 == .ok) {
                freeDispatchMiss(allocator, r);
                if (runtime.reclaimEnabled()) r2.ok.retain();
                return r2;
            }
        }
        // The receiver's class declares no such member: the reference
        // names a top-level function (a `::fn` lowered as a member ref
        // before the function's header was registered). Resolve it
        // through the full global probe chain — the raw env holds no
        // top-level functions.
        if (host_globals.lookupGlobal(self, n)) |callable| {
            switch (callable) {
                .IrClosure => return try callValueRec(self, allocator, &callable, args),
                else => {},
            }
        }
    }
    return r;
}

pub fn kclassMembers(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    _ = self;
    const cg = receiver.Class.borrow();
    defer cg.deinit();
    const a_name = cg.get().name;
    if (std.mem.eql(u8, name, "equals") and args.len == 1) {
        const eq = if (args[0] == .Class) blk: {
            const bg = args[0].Class.borrow();
            defer bg.deinit();
            break :blk std.mem.eql(u8, a_name, bg.get().name);
        } else false;
        return .{ .ok = boolVal(eq) };
    }
    if (std.mem.eql(u8, name, "hashCode") and args.len == 0) {
        var h = std.hash.Wyhash.init(0);
        h.update(a_name);
        return .{ .ok = Value.newInt(@bitCast(h.final())) };
    }
    if (std.mem.eql(u8, name, "toString") and args.len == 0) {
        const s = try std.fmt.allocPrint(allocator, "class {s}", .{a_name});
        return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
    }
    return null;
}

pub fn kfunctionReflection(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const info = self.closures.get(@intCast(receiver.IrClosure.asPtr().id)) orelse return null;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = info.module orelse mg.get();
    const f = mod.funcById(info.body_func) orelse return null;
    if (std.mem.eql(u8, name, "name")) {
        return .{ .ok = .{ .String = try runtime.strInit(allocator, f.name) } };
    }
    if (std.mem.eql(u8, name, "parameters")) {
        var items: std.ArrayList(Value) = .empty;
        for (f.params) |p| try items.append(allocator, .{ .String = try runtime.strInit(allocator, p.name) });
        return .{ .ok = try listOf(allocator, items, false) };
    }
    return null;
}

pub fn propertyRefDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const pg = receiver.PropertyRef.name.borrow();
    const pname = pg.get().bytes;
    pg.deinit();
    if (std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "call")) {
        const has_fn = self.module.borrow().get().hasFuncNamed(pname);
        const callable = lookupGlobalValue(self, pname);
        const is_callable_global = callable != null and switch (callable.?) {
            .IrClosure => true,
            else => false,
        };
        if ((has_fn or is_callable_global) and callable != null) {
            return try callValueRec(self, allocator, &callable.?, args);
        }
    }
    // Unbound `KProperty0` / `KMutableProperty0`: `get()` (and the
    // `() -> V` `invoke()`/`call()` forms) read the referenced top-level
    // property, and `set(v)` writes it. The reference carries only the
    // property name, so resolve the value the same way a bare read does —
    // a stored `val`/`var` from globals (driving a deferred initializer on
    // demand), otherwise a custom `get()` accessor's 0-arg getter func.
    if ((std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "call") or std.mem.eql(u8, name, "invoke")) and args.len == 0) {
        if (try topLevelPropertyGet(self, allocator, pname)) |r| return r;
    }
    if (std.mem.eql(u8, name, "set") and args.len == 1) {
        const r = try self.storeGlobal(allocator, pname, args[0]);
        return switch (r) {
            .ok => .{ .ok = Value.Unit },
            .err => |e| .{ .err = e },
        };
    }
    if ((std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "call") or std.mem.eql(u8, name, "invoke")) and args.len == 1) {
        return try getFieldRec(self, allocator, &args[0], pname);
    }
    // Property-delegation protocol on an unbound reference
    // (`var x by ::topVar`, `val y by ::intVar` in a class body): a
    // member of the delegation thisRef wins, else the top-level slot.
    if (std.mem.eql(u8, name, "getValue") and args.len >= 2) {
        if (args[0] == .Instance and memberIsProperty(self, &args[0], pname)) {
            var r = try getFieldRec(self, allocator, &args[0], pname);
            if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
            return r;
        }
        if (try topLevelPropertyGet(self, allocator, pname)) |r| return r;
        if (args[0] != .Null) {
            var r = try getFieldRec(self, allocator, &args[0], pname);
            if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
            return r;
        }
    }
    if (std.mem.eql(u8, name, "setValue") and args.len >= 3) {
        if (args[0] == .Instance and memberIsProperty(self, &args[0], pname)) {
            return switch (try host_fields.setField(self, allocator, &args[0], pname, args[2])) {
                .ok => .{ .ok = .Unit },
                .err => |e| .{ .err = e },
            };
        }
        return switch (try self.storeGlobal(allocator, pname, args[2])) {
            .ok => .{ .ok = Value.Unit },
            .err => |e| .{ .err = e },
        };
    }
    if (std.mem.eql(u8, name, "hashCode") and args.len == 0) {
        return .{ .ok = Value.newInt(@as(i64, valueStructuralHash(receiver))) };
    }
    if (std.mem.eql(u8, name, "equals") and args.len == 1) {
        return .{ .ok = boolVal(Value.structuralEq(receiver, &args[0])) };
    }
    if (std.mem.eql(u8, name, "toString") and args.len == 0) {
        const s = try std.fmt.allocPrint(allocator, "property {s}", .{pname});
        return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
    }
    return null;
}

/// Read the top-level property `pname` for an unbound property reference's
/// `get()`. Mirrors the `LoadGlobal` resolution: a stored `val`/`var` comes
/// from globals (driving a deferred initializer and resolving delegates),
/// and a property declared with only a custom `get()` re-runs its 0-arg
/// getter func on each read. Returns `null` when `pname` names no top-level
/// property, leaving the remaining dispatch branches to handle it.
pub fn topLevelPropertyGet(self: *VmHost, allocator: Allocator, pname: []const u8) Allocator.Error!?EvalResult {
    switch (try self.lookupGlobalThrowing(allocator, pname)) {
        .ok => |maybe| if (maybe) |v| {
            v.retain();
            return .{ .ok = v };
        },
        .err => |e| return .{ .err = e },
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    if (mod.registry.top_level_prop_getters.get(pname)) |fid| {
        return try self.callFunc(allocator, mod, fid, &.{});
    }
    return null;
}

pub fn isIteratorNext(name: []const u8) bool {
    const ns = [_][]const u8{ "next", "nextInt", "nextLong", "nextChar", "nextByte", "nextShort", "nextDouble", "nextFloat", "nextBoolean" };
    for (ns) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

pub fn funcAt(module: *const Module, fid: FuncId) ?Func {
    return if (module.funcById(fid)) |f| f.* else null;
}

pub fn argsListFromSlice(allocator: Allocator, slice: []const Value) Allocator.Error!std.ArrayList(Value) {
    var l = try ir.eval.acquireArgsCap(allocator, slice.len);
    l.appendSliceAssumeCapacity(slice);
    return l;
}

pub fn anonMethodDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var class_name: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        class_name = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ name, args.len });
    // Scratch lookup key (lookupAnonMethod dupes what it stores); free it.
    defer if (runtime.freeScratch()) allocator.free(arity_name);
    if (missTraceEnv()) |want| if (std.mem.eql(u8, want, name)) {
        const hit0 = lookupAnonMethod(self, allocator, class_name, arity_name, name);
        std.debug.print("[anon-disp] name={s} class={s} hit={} dis={}\n", .{ name, class_name, hit0 != null, if (hit0) |h| anonMethodDisproven(self, h, args) else false });
    };

    if (lookupAnonMethod(self, allocator, class_name, arity_name, name)) |hit| {
        // Param-type disproof, mirroring the named-class member walk: an
        // anon-object `trace(message: String)` declines a trailing-lambda
        // call so the inline `Logger.trace(() -> String)` extension binds.
        // One module borrow serves both the param-type disproof and the
        // member-extension receiver gate (this path is hot enough that a
        // second borrow per anon hit showed up in DeepRecursive timing).
        const hit_info: struct { disproven: bool, ext_recv_ty: ?[]const u8 } = blk: {
            const hg = hit.module.borrow();
            defer hg.deinit();
            const hf = funcAt(hg.get(), hit.func) orelse break :blk .{ .disproven = false, .ext_recv_ty = null };
            const dis = anonMethodDisprovenFn(self, &hf, args);
            var rt: ?[]const u8 = null;
            if (hf.kind == .member_extension and hf.params.len != 0 and std.mem.eql(u8, hf.params[0].name, "this")) {
                rt = hf.params[0].ty.name;
            }
            break :blk .{ .disproven = dis, .ext_recv_ty = rt };
        };
        if (!hit_info.disproven) {
            // A MEMBER-EXTENSION override binds its extension receiver from
            // the enclosing implicit receivers, never from the dispatch
            // owner itself: `with(policy) { measure(...) }` inside a
            // MeasureScope runs the anon policy's `MeasureScope.measure`
            // with the scope as `this` and the policy in dispatch scope.
            if (hit_info.ext_recv_ty) |rt| {
                if (!receiverImplementsType(self, receiver, rt)) {
                    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
                    defer allocator.free(entries);
                    for (entries) |e| {
                        if (e.v != .Instance) continue;
                        if (!receiverImplementsType(self, &e.v, rt)) continue;
                        ir.eval.pushEnclosing(receiver);
                        defer ir.eval.popEnclosing();
                        return try invokeAnonMethodFrom(self, allocator, &e.v, receiver, hit, args, inst);
                    }
                    // No satisfying receiver in scope: decline so the walk
                    // can try the next candidate.
                    return null;
                }
            }
            return try invokeAnonMethod(self, allocator, receiver, hit, args, inst);
        }
    }
    // A method inherited from a runtime-local supertype (`inner class
    // Inner : Local()` with `Local` a local class): its body is registered
    // under the ancestor's name and runs with the ancestor's captured
    // scope, the receiver staying the instance.
    var cur: ?ObjRef(ClassDef) = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk if (cg.get().parent) |p| p.clone() else null;
    };
    var steps: usize = 0;
    while (cur) |c| : (steps += 1) {
        if (steps > 64) {
            c.deinit();
            break;
        }
        const info: struct { name: []const u8, local: bool, next: ?ObjRef(ClassDef) } = blk: {
            const g = c.borrow();
            defer g.deinit();
            break :blk .{
                .name = g.get().name,
                .local = g.get().is_local_runtime,
                .next = if (g.get().parent) |p| p.clone() else null,
            };
        };
        if (info.local) {
            if (lookupAnonMethod(self, allocator, info.name, arity_name, name)) |hit| {
                if (!anonMethodDisproven(self, hit, args)) {
                    if (info.next) |n| n.deinit();
                    defer c.deinit();
                    const src: Value = .{ .Class = c };
                    return try invokeAnonMethodFrom(self, allocator, receiver, &src, hit, args, inst);
                }
            }
        }
        c.deinit();
        cur = info.next;
    }
    return null;
}

/// Run a thunk registered under a runtime-local class (`$default$<i>`)
/// in the class's captured scope, before any instance of it exists.
/// `receiver` is the enclosing receiver the class captured (or Null).
pub fn invokeLocalClassThunk(self: *VmHost, allocator: Allocator, cls: ObjRef(ClassDef), name: []const u8, receiver: *const Value, args: []const Value) Allocator.Error!EvalResult {
    const cls_name = blk: {
        const g = cls.borrow();
        defer g.deinit();
        break :blk g.get().name;
    };
    const hit = lookupAnonMethod(self, allocator, cls_name, name, name) orelse {
        return .{ .err = try typeErr(allocator, "local class `{s}` has no `{s}` thunk", .{ cls_name, name }) };
    };
    const src: Value = .{ .Class = cls };
    return invokeAnonMethodFrom(self, allocator, receiver, &src, hit, args, null);
}

/// Whether some supplied argument definitely cannot bind the anon method's
/// corresponding declared parameter (so the candidate must decline and the
/// dispatch walk continue to extensions).
pub fn anonMethodDisproven(self: *VmHost, hit: AnonMethodEntry, args: []const Value) bool {
    const mg = hit.module.borrow();
    defer mg.deinit();
    const f = funcAt(mg.get(), hit.func) orelse return false;
    return anonMethodDisprovenFn(self, &f, args);
}

pub fn anonMethodDisprovenFn(self: *VmHost, f: *const ir.Func, args: []const Value) bool {
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const effective = f.params[skip..];
    // Over-application: more args than the method declares and no trailing
    // vararg to absorb them cannot bind. Without this, `lookupAnonMethod`'s
    // arity-agnostic fallback answers a call with the wrong-arity member --
    // an `object : Iterable` whose 0-arg `override fun iterator()` would answer
    // the stdlib `iterator { block }` builder call and self-recurse forever.
    // Mirrors the named-class `pickMethodOverload` over-supply guard.
    if (args.len > effective.len and
        (effective.len == 0 or !effective[effective.len - 1].is_vararg)) return true;
    var i: usize = 0;
    while (i < args.len and i < effective.len) : (i += 1) {
        // A type-variable-typed param (the method's own, or one inherited
        // from the object expression's enclosing declaration) never names a
        // nominal class; adjudicating it as one would let an unrelated
        // registered class of the same simple name refute valid arguments.
        if (fidTypeVar(self, f.id, &effective[i].ty)) continue;
        // A LOCAL class's own type parameter (`Target` in a function-body
        // `class PropertyAndItsValue<Target, Value>`) is registered on the
        // synthesized ClassDef, not the method fid; reading it as a nominal
        // class refuted every argument (`set(target: Target)` missed).
        if (localClassTypeParam(self, f, &effective[i].ty)) continue;
        if (argDefinitelyNotParamType(self, &effective[i].ty, &args[i])) return true;
    }
    return false;
}

pub fn localClassTypeParam(self: *VmHost, f: *const ir.Func, ty: *const ir.TypeRef) bool {
    const head = std.mem.trimEnd(u8, simpleName(ty.name), "?");
    if (head.len == 0) return false;
    // A runtime-lowered local-class member's params[0] is `this`, typed by
    // the class; that names the ClassDef holding the declared type params.
    if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) return false;
    const cls_name = std.mem.trimEnd(u8, f.params[0].ty.name, "?");
    const cg = self.classes.borrow();
    defer cg.deinit();
    const def = cg.get().get(cls_name) orelse return false;
    const dg = def.borrow();
    defer dg.deinit();
    for (dg.get().type_params) |tp| {
        if (std.mem.eql(u8, tp, head)) return true;
    }
    return false;
}

pub const root_mod = @import("../../interp_ir.zig");
pub const NameValue = root_mod.NameValue;
pub const AnonMethodEntry = root_mod.AnonMethodEntry;

/// `(class, member)` key for `anon_methods`, unit-separated so the two
/// segments can't collide. Must match `run.zig`/`host_fields.zig`.
pub fn anonKey(allocator: Allocator, class_name: []const u8, member: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ class_name, member });
}

pub fn lookupAnonMethod(self: *VmHost, allocator: Allocator, class_name: []const u8, arity_name: []const u8, name: []const u8) ?AnonMethodEntry {
    const tbl = self.anon_methods.borrow();
    defer tbl.deinit();
    if (tbl.get().count() == 0) return null;
    // Probe keys live in a stack buffer — this runs per dynamic dispatch, and
    // the old per-probe allocPrint pair was measurable in the profile. The
    // heap fallback covers pathological name lengths.
    var kb: [256]u8 = undefined;
    if (std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ class_name, arity_name })) |ak| {
        if (tbl.get().get(ak)) |e| return e;
    } else |_| {
        const ak = anonKey(allocator, class_name, arity_name) catch return null;
        defer allocator.free(ak);
        if (tbl.get().get(ak)) |e| return e;
    }
    if (std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ class_name, name })) |pk| {
        if (tbl.get().get(pk)) |e| return e;
    } else |_| {
        const pk = anonKey(allocator, class_name, name) catch return null;
        defer allocator.free(pk);
        if (tbl.get().get(pk)) |e| return e;
    }
    return null;
}

/// Exact anonymous/local-class method lookup used while linking a numeric
/// virtual slot. Unlike the legacy named-member path, this never falls back to
/// the arity-agnostic key.
pub fn lookupAnonMethodExact(self: *VmHost, allocator: Allocator, class_name: []const u8, arity_name: []const u8) ?AnonMethodEntry {
    const tbl = self.anon_methods.borrow();
    defer tbl.deinit();
    if (tbl.get().count() == 0) return null;
    var kb: [256]u8 = undefined;
    if (std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ class_name, arity_name })) |key| {
        return tbl.get().get(key);
    } else |_| {}
    const key = anonKey(allocator, class_name, arity_name) catch return null;
    defer allocator.free(key);
    return tbl.get().get(key);
}

pub fn invokeAnonMethod(self: *VmHost, allocator: Allocator, receiver: *const Value, hit: AnonMethodEntry, args: []const Value, padding_inst: ?ObjRef(InstanceData)) Allocator.Error!EvalResult {
    return invokeAnonMethodFrom(self, allocator, receiver, receiver, hit, args, padding_inst);
}

/// `invokeAnonMethod` with the CAPTURE SOURCE decoupled from the bound
/// receiver: a member-extension override runs with the EXTENSION receiver
/// as `this` (params[0]) while its captures still live on the anon OWNER
/// instance (`capture_src`).
pub fn invokeAnonMethodFrom(self: *VmHost, allocator: Allocator, receiver: *const Value, capture_src: *const Value, hit: AnonMethodEntry, args: []const Value, padding_inst: ?ObjRef(InstanceData)) Allocator.Error!EvalResult {
    const mg = hit.module.borrow();
    const module_rc = mg.get();
    defer mg.deinit();
    const f = funcAt(module_rc, hit.func) orelse {
        return .{ .err = try typeErr(allocator, "anon method FuncId {d} out of range", .{@intFromEnum(hit.func)}) };
    };
    if (builtinBridgeDefault(self, receiver, &f, args)) |dflt| return .{ .ok = dflt };
    var all: std.ArrayList(Value) = .empty;
    try all.append(allocator, receiver.*);
    try all.appendSlice(allocator, args);

    // Scalar-replay leaf on the anon/companion method (receiver rides as
    // opaque param 0); a bail falls through to the framed invoke, which
    // re-runs the pure body exactly. The gate takes the MODULE'S Func
    // record, not the local copy — the leaf_route memo written through a
    // copy is discarded, re-pricing every companion dispatch with the
    // registry mutex + fqn lookup the memo exists to kill.
    if (receiver.* != .Null and all.items.len == f.params.len) {
        const lfp = module_rc.funcById(hit.func) orelse unreachable;
        if (try ir.eval.tryLeafValues(VmHost, allocator, module_rc, lfp, all.items, self, null)) |lo| {
            all.deinit(allocator);
            switch (lo) {
                .val => |v| return .{ .ok = v },
                .raise => |e| return .{ .err = e },
            }
        }
    }

    // Pad omitted trailing args from inherited defaults.
    if (padding_inst) |inst| {
        if (all.items.len < f.params.len) {
            var supertypes: [][]const u8 = &.{};
            const sg = inst.borrow();
            const scg = sg.get().class.borrow();
            supertypes = try allocator.alloc([]const u8, scg.get().supertype_names.len);
            for (scg.get().supertype_names, 0..) |s, i| supertypes[i] = s;
            scg.deinit();
            sg.deinit();
            if (try inheritedMemberDefaults(self, allocator, supertypes, f.name)) |defaults| {
                const mmg = self.module.borrow();
                const main_mod = mmg.get();
                const padded = try padArgsWithDefaultsFor(self, allocator, main_mod, f.params.len, all.items, defaults, f.params);
                mmg.deinit();
                switch (padded) {
                    .ok => |p| {
                        all.deinit(allocator);
                        all = try argsListFromSlice(allocator, p);
                    },
                    .err => |e| return .{ .err = e },
                }
            }
        }
    }
    const packed_args = try packVarargArgs(self, allocator, &f, try all.toOwnedSlice(allocator));

    // Captures come from the instance for an anonymous-object expression
    // (`buildObject` stores them per-instance, registry entry empty), or from
    // the registry entry for a local class (`registerClassCaptured` registers
    // once per declaration — site-stable, no leak). Prefer the instance; fall
    // back to the entry. `InstanceData.Capture` and `NameValue` are the same
    // shape, so the instance slice reinterprets as `[]const NameValue`.
    comptime std.debug.assert(@sizeOf(InstanceData.Capture) == @sizeOf(NameValue));
    const inst_caps: []const InstanceData.Capture = blk: {
        if (capture_src.* != .Instance) break :blk &.{};
        const g = capture_src.Instance.borrow();
        defer g.deinit();
        break :blk g.get().anon_captures;
    };
    // A runtime-local class carries its declaration scope on its def
    // (`ClassDef.local_captures`, one registration = one scope), so an
    // instance reads the scope it was declared in even after the same
    // declaration ran again; a `.Class` source is a thunk running before
    // any instance exists (a constructor default).
    const class_caps: []const InstanceData.Capture = blk: {
        if (inst_caps.len != 0) break :blk &.{};
        const cls: ObjRef(ClassDef) = switch (capture_src.*) {
            .Instance => |i| inner: {
                const g = i.borrow();
                defer g.deinit();
                break :inner g.get().class.clone();
            },
            .Class => |c| c.clone(),
            else => break :blk &.{},
        };
        defer cls.deinit();
        const g = cls.borrow();
        defer g.deinit();
        break :blk g.get().local_captures;
    };
    const chain_seed: []const ir.eval.EnclosingEntry = blk: {
        const cls: ObjRef(ClassDef) = switch (capture_src.*) {
            .Instance => |i| inner: {
                const g = i.borrow();
                defer g.deinit();
                if (g.get().anon_enclosing.len != 0) break :blk g.get().anon_enclosing;
                break :inner g.get().class.clone();
            },
            .Class => |c| c.clone(),
            else => break :blk &.{},
        };
        defer cls.deinit();
        const g = cls.borrow();
        defer g.deinit();
        break :blk g.get().local_enclosing;
    };
    const caps: []const NameValue = if (inst_caps.len != 0)
        @ptrCast(inst_caps)
    else if (class_caps.len != 0)
        @ptrCast(class_caps)
    else
        hit.captures;

    // Layer captured outer-env names onto globals + build the capture vec.
    const prev = self.globals.clone();
    defer {
        self.globals.deinit();
        self.globals = prev;
    }
    if (caps.len != 0) {
        const scoped = try ObjRef(runtime.Env).init(allocator, runtime.Env.withParent(allocator, self.globals.clone()));
        const sg = scoped.borrowMut();
        for (caps) |nv| sg.get().define(nv.name, nv.value) catch {};
        sg.deinit();
        self.globals = scoped;
    }
    // The host's active globals scope is only held in this stack-local VmHost
    // field; pin it so a collection during the body eval cannot sweep the
    // transient capture-layer env (its parent chain reaches the rooted globals).
    const ka = self.ka.mark();
    defer self.ka.restore(ka);
    runtime.keepalivePushCell(&self.globals.cell.hdr);
    var cap_vec: std.ArrayList(Value) = .empty;
    for (f.capture_order) |cn| {
        if (std.mem.eql(u8, cn, "this")) {
            try cap_vec.append(allocator, receiver.*);
        } else {
            var found: Value = .Null;
            for (caps) |nv| {
                if (std.mem.eql(u8, nv.name, cn)) found = nv.value;
            }
            try cap_vec.append(allocator, found);
        }
    }
    var packed_list = try argsListFromSlice(allocator, packed_args);
    // `argsListFromSlice` copied the args into the frame-owned list; the
    // `packed_args` buffer (a full allocation from `packVarargArgs`) is dead.
    if (runtime.freeScratch()) allocator.free(packed_args);
    _ = &packed_list;
    vmhost.emitPath(allocator, "member_anon", f.fqn, f.id, receiver, args);
    return ir.eval.evalWithCapturesChained(VmHost, allocator, module_rc, module_rc, &f, packed_list, cap_vec, chain_seed, null, self);
}

/// Build the `n_params`-length argument vector, filling positions past
/// the provided args from default-arg thunks.
pub fn padArgsWithDefaults(self: *VmHost, allocator: Allocator, module: *const Module, n_params: usize, provided: []const Value, defaults: ?[]const ?FuncId) Allocator.Error!union(enum) { ok: []Value, err: EvalError } {
    return padArgsWithDefaultsFor(self, allocator, module, n_params, provided, defaults, &.{});
}
pub fn padArgsWithDefaultsFor(self: *VmHost, allocator: Allocator, module: *const Module, n_params: usize, provided: []const Value, defaults: ?[]const ?FuncId, params: []const ir.Param) Allocator.Error!union(enum) { ok: []Value, err: EvalError } {
    // Kotlin binds a trailing lambda to the LAST parameter. When the
    // positional layout would leave a default-less last parameter empty
    // while the last provided arg is callable, the call was the
    // trailing-lambda form over defaulted middle params
    // (`items(3) { … }` against `items(count, key = …, type = …,
    // itemContent)`) — a straight positional fill would be a kotlinc
    // compile error, so the shift never changes a legal layout.
    var last_shift: ?Value = null;
    var pos_len = provided.len;
    if (provided.len > 0 and provided.len < n_params) {
        const last_default: ?FuncId = if (defaults) |d| (if (n_params - 1 < d.len) d[n_params - 1] else null) else null;
        const lastp = provided[provided.len - 1];
        if (last_default == null and isCallable(&lastp)) {
            last_shift = lastp;
            pos_len -= 1;
        }
    }
    var call_args: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < n_params) : (i += 1) {
        if (i + 1 == n_params) {
            if (last_shift) |lv| {
                try call_args.append(allocator, lv);
                continue;
            }
        }
        if (i < pos_len) {
            try call_args.append(allocator, provided[i]);
            continue;
        }
        // An omitted vararg with no default of its own is the empty array —
        // never a placeholder the packer would take as an element.
        if (i < params.len and params[i].is_vararg and
            (defaults == null or i >= defaults.?.len or defaults.?[i] == null))
        {
            const empty: std.ArrayList(Value) = .empty;
            try call_args.append(allocator, runtime.ArrayData.fromBoxedList(try ObjRef(std.ArrayList(Value)).init(allocator, empty)));
            continue;
        }
        const dfid: ?FuncId = if (defaults) |d| (if (i < d.len) d[i] else null) else null;
        if (dfid) |df| {
            const dfunc = funcAt(module, df) orelse {
                call_args.deinit(allocator);
                return .{ .err = try typeErr(allocator, "default-arg FuncId {d} out of range", .{@intFromEnum(df)}) };
            };
            var captures: std.ArrayList(Value) = .empty;
            if (call_args.items.len != 0) try captures.append(allocator, call_args.items[0]);
            const cur = try argsListFromSlice(allocator, call_args.items);
            vmhost.emitPath(allocator, "member_default_thunk", dfunc.fqn, df, null, provided);
            const r = try ir.eval.evalWithCaptures(VmHost, allocator, module, &dfunc, cur, captures, self);
            switch (r) {
                .ok => |v| try call_args.append(allocator, v),
                .err => |e| {
                    call_args.deinit(allocator);
                    return .{ .err = e };
                },
            }
        } else {
            try call_args.append(allocator, .Null);
        }
    }
    return .{ .ok = try call_args.toOwnedSlice(allocator) };
}

/// Trailing-lambda syntax bit of the member call currently dispatching
/// (`recv.f(x) { … }` vs `recv.f(x, { … })`) — see `Inst.CallMember.
/// trailing_lambda`. Saved/restored by the exec sites around each dispatch
/// so nested member calls (walk probes running accessors) cannot clobber
/// the outer call's bit. Read non-destructively by the under-applied
/// trailing-lambda arm in `irMethodWalk`.
pub threadlocal var trailing_member_call: bool = false;

pub fn setTrailingMemberCall(on: bool) bool {
    const prev = trailing_member_call;
    trailing_member_call = on;
    return prev;
}

/// `unambiguous` = the pick is a pure function of the RELAXED method-cache
/// key: the resolving class collected exactly one candidate, or the call's
/// arg count forced the pick among several (see `pickArityForced`) with
/// every argument relaxed-adjudicable. Gates whether a relaxed-key cache
/// entry may be stored.
pub const ResolvedMethod = struct { fid: FuncId, unambiguous: bool };
