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
    if (std.mem.eql(u8, name, "set") or std.mem.eql(u8, name, "get")) {
        // Arity decides bound vs unbound: `set` is 2 args unbound / 1 bound.
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
    // Private visibility is decided where the reference was written.
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
    // Property delegation: a Class-bound ref takes the instance from thisRef.
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
                // The borrowed field escapes as a callMember return, so retain.
                var r = try getFieldRec(self, allocator, &first, n);
                if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
                return r;
            }
            const r = try callMemberRec(self, allocator, &first, n, rest);
            // An extension property is read once the member forward has missed.
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
    // On a bound extension-property reference only a clean field read wins.
    if (std.mem.eql(u8, name, "get") and args.len == 0) {
        var r = try getFieldRec(self, allocator, &recv_capt, n);
        if (r == .ok) {
            if (runtime.reclaimEnabled()) r.ok.retain();
            return r;
        }
    }
    // An extension declared on a function type serves the reference itself, not
    // the member it names; `invoke`/`call` keep forwarding to the member.
    if (!std.mem.eql(u8, name, "invoke") and !std.mem.eql(u8, name, "call") and
        extWithThisLongerThanArgs(self, name, args.len)) return null;
    const r = try callMemberRec(self, allocator, &recv_capt, n, args);
    if ((std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "call")) and r == .err and r.err == .Unimplemented) {
        // An invoked extension-property reference reads the property on a miss.
        if (args.len == 0 and isDispatchMissFor(r, n)) {
            var r2 = try getFieldRec(self, allocator, &recv_capt, n);
            if (r2 == .ok) {
                freeDispatchMiss(allocator, r);
                if (runtime.reclaimEnabled()) r2.ok.retain();
                return r2;
            }
        }
        // No such member: the reference names a top-level function, which only
        // the global probe chain resolves (the raw env holds none).
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
    // Unbound `KProperty0`: `get`/`invoke`/`call` read the top-level property.
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
    // On an unbound reference a member of the thisRef wins, else the global slot.
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

/// Read the top-level property `pname`, mirroring `LoadGlobal` resolution.
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
        // Param-type disproof, mirroring the named-class member walk, so an anon
        // method declines a call whose argument cannot bind its parameter.
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
            // A member-extension override binds its extension receiver from the
            // enclosing implicit receivers, never from the dispatch owner.
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
                    // No satisfying receiver in scope: decline to the next candidate.
                    return null;
                }
            }
            return try invokeAnonMethod(self, allocator, receiver, hit, args, inst);
        }
    }
    // A method inherited from a runtime-local supertype runs in the ancestor's
    // captured scope, the receiver staying the instance.
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

/// Run a thunk registered under a runtime-local class (`$default$<i>`) in the
/// class's captured scope, before any instance of it exists.
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

/// Whether some argument definitely cannot bind its declared parameter, so the
/// candidate declines and the walk continues to extensions.
pub fn anonMethodDisproven(self: *VmHost, hit: AnonMethodEntry, args: []const Value) bool {
    const mg = hit.module.borrow();
    defer mg.deinit();
    const f = funcAt(mg.get(), hit.func) orelse return false;
    return anonMethodDisprovenFn(self, &f, args);
}

pub fn anonMethodDisprovenFn(self: *VmHost, f: *const ir.Func, args: []const Value) bool {
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const effective = f.params[skip..];
    // Over-application cannot bind: `lookupAnonMethod`'s arity-agnostic fallback
    // would otherwise answer with a wrong-arity member.
    if (args.len > effective.len and
        (effective.len == 0 or !effective[effective.len - 1].is_vararg)) return true;
    var i: usize = 0;
    while (i < args.len and i < effective.len) : (i += 1) {
        // A type-variable-typed param names no nominal class, so never adjudicate it.
        if (fidTypeVar(self, f.id, &effective[i].ty)) continue;
        // A local class's type parameter is registered on the synthesized
        // ClassDef, not the method fid.
        if (localClassTypeParam(self, f, &effective[i].ty)) continue;
        if (argDefinitelyNotParamType(self, &effective[i].ty, &args[i])) return true;
    }
    return false;
}

pub fn localClassTypeParam(self: *VmHost, f: *const ir.Func, ty: *const ir.TypeRef) bool {
    const head = std.mem.trimEnd(u8, simpleName(ty.name), "?");
    if (head.len == 0) return false;
    // params[0] is `this`, typed by the class holding the declared type params.
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
    // Probe keys live in a stack buffer; the heap fallback covers long names.
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

/// Exact lookup for linking a numeric virtual slot: no arity-agnostic fallback.
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

/// `invokeAnonMethod` with the capture source decoupled from the receiver: a
/// member-extension override keeps its captures on the anon owner instance.
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

    // Scalar-replay leaf, receiver riding as opaque param 0; a bail falls through
    // to the framed invoke. The gate takes the module's own Func record so the
    // leaf_route memo it writes survives.
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

    // Captures come from the instance for an anonymous-object expression, else
    // from the registry entry for a local class. `InstanceData.Capture` and
    // `NameValue` share a shape, so the instance slice reinterprets as one.
    comptime std.debug.assert(@sizeOf(InstanceData.Capture) == @sizeOf(NameValue));
    const inst_caps: []const InstanceData.Capture = blk: {
        if (capture_src.* != .Instance) break :blk &.{};
        const g = capture_src.Instance.borrow();
        defer g.deinit();
        break :blk g.get().anon_captures;
    };
    // A runtime-local class carries its declaration scope on its def, so an
    // instance reads the scope it was declared in.
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
    // The active globals scope lives only in this stack-local VmHost field; pin
    // it so a collection during body eval cannot sweep the capture-layer env.
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
    // The args are copied into the frame-owned list, so `packed_args` is dead.
    if (runtime.freeScratch()) allocator.free(packed_args);
    _ = &packed_list;
    vmhost.emitPath(allocator, "member_anon", f.fqn, f.id, receiver, args);
    return ir.eval.evalWithCapturesChained(VmHost, allocator, module_rc, module_rc, &f, packed_list, cap_vec, chain_seed, null, self);
}

/// The filled argument vector, or the error raised while evaluating a default.
pub const PaddedArgs = union(enum) { ok: []Value, err: EvalError };

pub fn padArgsWithDefaults(self: *VmHost, allocator: Allocator, module: *const Module, n_params: usize, provided: []const Value, defaults: ?[]const ?FuncId) Allocator.Error!PaddedArgs {
    return padArgsWithDefaultsFor(self, allocator, module, n_params, provided, defaults, &.{});
}
pub fn padArgsWithDefaultsFor(self: *VmHost, allocator: Allocator, module: *const Module, n_params: usize, provided: []const Value, defaults: ?[]const ?FuncId, params: []const ir.Param) Allocator.Error!PaddedArgs {
    // Kotlin binds a trailing lambda to the last parameter, so a callable last
    // argument facing a default-less last parameter is the trailing-lambda form.
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
        // An omitted vararg with no default of its own is the empty array.
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

/// Trailing-lambda syntax bit of the member call currently dispatching. Saved
/// and restored by the exec sites so a nested call cannot clobber it.
pub threadlocal var trailing_member_call: bool = false;

pub fn setTrailingMemberCall(on: bool) bool {
    const prev = trailing_member_call;
    trailing_member_call = on;
    return prev;
}

/// `unambiguous` means the pick is a pure function of the relaxed method-cache
/// key: one candidate, or an arity-forced pick with every argument
/// relaxed-adjudicable. Gates whether a relaxed-key entry may be stored.
pub const ResolvedMethod = struct { fid: FuncId, unambiguous: bool };
