//! Receiver binding probes: delegates, host bindings, the class/companion/enum
//! surface, and the SAM-instance dispatch routes.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const VmHost = vmhost.VmHost;
const host_call_value = @import("../host_call_value.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const StringRef = runtime.StringRef;
const InstanceData = runtime.InstanceData;
const DelegateKind = runtime.DelegateKind;
const Module = ir.Module;
const EvalResult = ir.eval.EvalResult;

const caches = @import("caches.zig");
const instanceIntrinsicCacheGet = caches.instanceIntrinsicCacheGet;
const instanceIntrinsicCachePut = caches.instanceIntrinsicCachePut;
const tlSlot = caches.tlSlot;

const flat_call = @import("flat_call.zig");
const prependReceiver = flat_call.prependReceiver;

const hcm = @import("../host_call_member.zig");
const cacheGen = hcm.cacheGen;
const callFuncRec = hcm.callFuncRec;
const callMemberRec = hcm.callMemberRec;
const callValueRec = hcm.callValueRec;
const dispatchIntrinsic = hcm.dispatchIntrinsic;
const lookupIntrinsic = hcm.lookupIntrinsic;
const simpleName = hcm.simpleName;
const throwExc = hcm.throwExc;

const member_ref_super = @import("member_ref_super.zig");
const classIsFunInterface = member_ref_super.classIsFunInterface;

const named_call = @import("named_call.zig");
const namedOrderKey = named_call.namedOrderKey;

const receiver_probe = @import("receiver_probe.zig");
const receiverImplementsType = receiver_probe.receiverImplementsType;

const reflect_anon = @import("reflect_anon.zig");
const funcAt = reflect_anon.funcAt;
const invokeAnonMethod = reflect_anon.invokeAnonMethod;
const lookupAnonMethod = reflect_anon.lookupAnonMethod;
const root_mod = reflect_anon.root_mod;

const static_tail = @import("static_tail.zig");
const freeDispatchMiss = static_tail.freeDispatchMiss;
const isDispatchMissFor = static_tail.isDispatchMissFor;

const virtual_tail = @import("virtual_tail.zig");
const instanceMethodKey = virtual_tail.instanceMethodKey;

pub fn delegateMember(self: *VmHost, allocator: Allocator, d: ObjRef(DelegateKind), name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    if (std.mem.eql(u8, name, "getValue")) {
        const state = blk: {
            const g = d.borrow();
            defer g.deinit();
            break :blk g.get().*;
        };
        switch (state) {
            .Lazy => |lz| {
                if (lz.cached) |c| return .{ .ok = c };
                const r = try callValueRec(self, allocator, &lz.producer, &.{});
                if (r == .ok) {
                    const g = d.borrowMut();
                    if (g.get().* == .Lazy) g.get().Lazy.cached = r.ok;
                    g.deinit();
                }
                return r;
            },
            .Observable => |ob| return .{ .ok = ob.value },
            .NotNull => |nn| {
                if (nn.value) |x| return .{ .ok = x };
                return .{ .err = try throwExc(allocator, "kotlin.IllegalStateException", "Property should be initialized before get.") };
            },
        }
    }
    if (std.mem.eql(u8, name, "setValue")) {
        if (args.len > 2) {
            const new_v = args[2];
            const g = d.borrowMut();
            switch (g.get().*) {
                .Lazy => g.get().Lazy.cached = new_v,
                .Observable => {
                    const old = g.get().Observable.value;
                    g.get().Observable.value = new_v;
                    const cb = g.get().Observable.on_change;
                    g.deinit();
                    if (cb != .Null) {
                        _ = try callValueRec(self, allocator, &cb, &.{ .Null, old, new_v });
                    }
                    return .{ .ok = .Unit };
                },
                .NotNull => g.get().NotNull.value = new_v,
            }
            g.deinit();
        }
        return .{ .ok = .Unit };
    }
    return null;
}

/// Declared parameter names of `name` on the receiver's class or a supertype.
/// A pack host binding carries none, so named arguments match against these.
pub fn classMethodParamNames(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?[][]const u8 {
    if (receiver.* != .Instance) return null;
    var cname: []const u8 = "";
    var cfqn: []const u8 = "";
    {
        const ig = receiver.Instance.borrow();
        defer ig.deinit();
        const cg = ig.get().class.borrow();
        defer cg.deinit();
        cname = cg.get().name;
        cfqn = cg.get().fqn;
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const cid = mod.classIdByFqn(cfqn) orelse mod.classId(cname) orelse return null;
    if (cid.int() >= mod.classes.items.len) return null;
    const cls = &mod.classes.items[cid.int()];
    for (cls.methods) |fid| {
        const f = mod.funcById(fid) orelse continue;
        if (!std.mem.eql(u8, f.name, name) and !std.mem.eql(u8, simpleName(f.name), name)) continue;
        // A member's leading `this` parameter is the receiver, not an argument.
        const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const out = try allocator.alloc([]const u8, f.params.len - skip);
        for (f.params[skip..], out) |pd, *o| o.* = pd.name;
        return out;
    }
    return null;
}

/// A named-argument call into a pack-installed host binding: the binding takes
/// arguments positionally, so names match the Kotlin declaration's parameters.
pub fn instanceBindingNamedProbe(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    args: []const Value,
    arg_names: []const ?[]const u8,
) Allocator.Error!?EvalResult {
    if (receiver.* != .Instance) return null;
    const params = (try classMethodParamNames(self, allocator, receiver, name)) orelse return null;
    defer if (runtime.freeScratch()) allocator.free(params);
    if (args.len > params.len) return null;

    const slots = try allocator.alloc(?Value, params.len);
    defer if (runtime.freeScratch()) allocator.free(slots);
    for (slots) |*s| s.* = null;
    var src: [15]u8 = @splat(0xFF);
    var next_positional: usize = 0;
    for (args, 0..) |a, i| {
        const supplied: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        if (supplied) |an| {
            var placed = false;
            for (params, 0..) |pn, pos| {
                if (!std.mem.eql(u8, pn, an)) continue;
                if (slots[pos] != null) return null;
                slots[pos] = a;
                if (pos < 15) src[pos] = @intCast(@min(i, 0xFE));
                placed = true;
                break;
            }
            if (!placed) return null;
        } else {
            while (next_positional < slots.len and slots[next_positional] != null) next_positional += 1;
            if (next_positional >= slots.len) return null;
            slots[next_positional] = a;
            if (next_positional < 15) src[next_positional] = @intCast(@min(i, 0xFE));
            next_positional += 1;
        }
    }
    // Every parameter must be supplied: a host binding has no default thunks.
    var filled: std.ArrayList(Value) = .empty;
    defer filled.deinit(allocator);
    for (slots) |s| {
        const v = s orelse return null;
        try filled.append(allocator, v);
    }
    // The reorder is a pure function of (class, name, arg shape, name vector),
    // so memoize it: later calls of this shape dispatch positionally up front.
    if (params.len <= 15 and args.len == params.len and args.len <= 15) {
        if (namedOrderKey(self, receiver, name, args, arg_names)) |k| {
            const perm = root_mod.ProgramImage.NamedPerm{ .n = @intCast(params.len), .src = src };
            {
                const pg = self.prog.borrowMut();
                defer pg.deinit();
                pg.get().named_perm_cache.put(k, perm) catch {};
            }
            caches.tl_perm_cache[tlSlot(k)] = .{ .class_p = k.class_p, .name_p = k.name_p, .n_args = k.n_args, .sig = k.sig, .raw_plus = 1, .gen = cacheGen(), .perm = perm };
        }
    }
    return instanceBindingProbe(self, allocator, receiver, name, filled.items);
}

pub fn instanceBindingProbe(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var cls_fqn: []const u8 = undefined;
    var cls_name: []const u8 = undefined;
    var is_anonymous = false;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        cls_fqn = cg.get().fqn;
        cls_name = cg.get().name;
        is_anonymous = cg.get().is_anonymous;
        cg.deinit();
        g.deinit();
    }

    // Inline cache on (class, name, arg-sig) holding a resolved intrinsic or a
    // recorded miss. Only a primitive-arg call is keyed.
    const ib_key = instanceMethodKey(self, receiver, name, args);
    if (ib_key) |k| {
        if (instanceIntrinsicCacheGet(self, k)) |entry| {
            const func = entry.func orelse return null;
            const all_args = try prependReceiver(allocator, receiver, args);
            defer if (runtime.freeScratch()) allocator.free(all_args);
            return try dispatchIntrinsic(self, allocator, entry.fqn, func, all_args);
        }
    }

    var probes: std.ArrayList([]const u8) = .empty;
    // Probe FQNs are per-call scratch; freeing is a no-op under the arena.
    defer {
        if (runtime.freeScratch()) for (probes.items) |p| allocator.free(p);
        probes.deinit(allocator);
    }
    try probes.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_fqn, name }));
    try probes.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_name, name }));
    {
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(allocator);
        var seen: std.StringHashMap(void) = .init(allocator);
        defer seen.deinit();
        try queue.append(allocator, cls_name);
        try queue.append(allocator, cls_fqn);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const cur = queue.items[head];
            if (seen.contains(cur)) continue;
            try seen.put(cur, {});
            const cg = self.classes.borrow();
            if (cg.get().get(cur)) |def| {
                const dg = def.borrow();
                for (dg.get().supertype_names) |sup| {
                    try probes.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sup, name }));
                    try queue.append(allocator, sup);
                }
                dg.deinit();
            }
            cg.deinit();
        }
    }
    for (probes.items) |p| {
        const installed = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            const bg = pg.get().installed_bindings.borrow();
            defer bg.deinit();
            break :blk bg.get().resolve(p);
        };
        if (installed) |func| {
            // A binding inapplicable to this call shape is not the target.
            if (stdlib.implementationApplicable(p, args)) |applies| {
                if (!applies) continue;
            }
            if (ib_key) |k| instanceIntrinsicCachePut(self, k, func, p);
            const all_args = try prependReceiver(allocator, receiver, args);
            defer if (runtime.freeScratch()) allocator.free(all_args);
            return try dispatchIntrinsic(self, allocator, p, func, all_args);
        }
    }

    // klio-stdlib intrinsics on an anonymous/synth class.
    if (is_anonymous) {
        const synth = [_][]const u8{
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_fqn, name }),
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_name, name }),
        };
        // The synthesized lookup keys are scratch; free them once probed.
        defer if (runtime.freeScratch()) {
            allocator.free(synth[0]);
            allocator.free(synth[1]);
        };
        for (synth) |p| {
            if (lookupIntrinsic(self, p)) |func| {
                const all_args = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(all_args);
                return try dispatchIntrinsic(self, allocator, p, func, all_args);
            }
        }
    }

    // Builtin Any/AutoCloseable probes, unless a user extension on the chain exists.
    const recv_chain = try receiverClassChain(self, allocator, inst);
    defer {
        var it = recv_chain.keyIterator();
        _ = &it;
        @constCast(&recv_chain).deinit();
    }
    const has_recv_ext = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        for (mod.funcsBySimpleName(name)) |fid| {
            if (mod.funcById(fid)) |f| {
                if (f.hasBody() and f.params.len > 0 and
                    std.mem.eql(u8, f.params[0].name, "this") and recv_chain.contains(f.params[0].ty.name))
                {
                    break :blk true;
                }
            }
        }
        break :blk false;
    };
    if (!has_recv_ext) {
        // Link-settled name-to-FQN map over the builtin kotlin.io,
        // AutoCloseable and Any surfaces: one deterministic edge per name.
        const mapped: ?[]const u8 = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().anyMemberGlobal(name);
        };
        if (mapped) |p| {
            if (lookupIntrinsic(self, p)) |func| {
                if (ib_key) |k| instanceIntrinsicCachePut(self, k, func, p);
                const all_args = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(all_args);
                return try dispatchIntrinsic(self, allocator, p, func, all_args);
            }
        }
    }
    // No intrinsic through any probe stage: cache the miss.
    if (ib_key) |k| instanceIntrinsicCachePut(self, k, null, "");
    return null;
}

pub fn receiverClassChain(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData)) Allocator.Error!std.StringHashMap(void) {
    var seen: std.StringHashMap(void) = .init(allocator);
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        try stack.append(allocator, cg.get().name);
        try stack.append(allocator, cg.get().fqn);
        cg.deinit();
        g.deinit();
    }
    while (stack.pop()) |cn| {
        if (seen.contains(cn)) continue;
        try seen.put(cn, {});
        const cg = self.classes.borrow();
        if (cg.get().get(cn)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |s| try stack.append(allocator, s);
            dg.deinit();
        }
        cg.deinit();
    }
    return seen;
}

pub fn isBuiltinScalar(v: *const Value) bool {
    return switch (v.*) {
        .String, .Int, .Long, .Short, .Byte, .Double, .Float, .Bool, .Char => true,
        .UInt, .ULong, .UShort, .UByte => true,
        else => false,
    };
}

pub fn eqIgnoreCase(allocator: Allocator, a: StringRef, b: StringRef) bool {
    const ag = a.borrow();
    defer ag.deinit();
    const bg = b.borrow();
    defer bg.deinit();
    const la = std.ascii.allocLowerString(allocator, ag.get().bytes) catch return false;
    defer if (runtime.freeScratch()) allocator.free(la);
    const lb = std.ascii.allocLowerString(allocator, bg.get().bytes) catch return false;
    defer if (runtime.freeScratch()) allocator.free(lb);
    return std.mem.eql(u8, la, lb);
}

pub fn isCallableOrIntrinsic(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure, .Intrinsic => true,
        else => false,
    };
}

pub fn extWithThisLongerThanArgs(self: *VmHost, name: []const u8, argc: usize) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        if (mod.funcById(fid)) |f| {
            // Only true extensions gate the SAM arm: an interface's own method
            // also leads with `this` but is the SAM dispatch on a callable.
            if (f.kind != .top_level_extension and f.kind != .member_extension) continue;
            if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this") and f.params.len > argc) return true;
        }
    }
    return false;
}

pub fn lookupGlobalValue(self: *VmHost, name: []const u8) ?Value {
    const g = self.globals.borrow();
    defer g.deinit();
    return g.get().lookup(name);
}

pub fn extensionTargetsAny(self: *VmHost, name: []const u8, targets: []const []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        const recv_simple = simpleName(f.params[0].ty.name);
        for (targets) |t| {
            if (std.mem.eql(u8, simpleName(t), recv_simple)) return true;
        }
    }
    return false;
}

pub fn classCompanionAndEnum(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const cls = receiver.Class;
    var cls_name: []const u8 = undefined;
    var cls_fqn: []const u8 = undefined;
    var is_enum = false;
    {
        const cg = cls.borrow();
        cls_name = cg.get().name;
        cls_fqn = cg.get().fqn;
        is_enum = cg.get().is_enum;
        cg.deinit();
    }
    // Probe-class set (name, fqn, supertype parents via runtime def).
    var probe_classes: std.ArrayList([]const u8) = .empty;
    defer probe_classes.deinit(allocator);
    try probe_classes.append(allocator, cls_name);
    if (cls_fqn.len != 0 and !std.mem.eql(u8, cls_fqn, cls_name)) try probe_classes.append(allocator, cls_fqn);
    {
        const cg = self.classes.borrow();
        if (cg.get().get(cls_name)) |def| {
            var cur = blk: {
                const dg = def.borrow();
                const p = dg.get().parent;
                dg.deinit();
                break :blk if (p) |pp| pp.clone() else null;
            };
            while (cur) |p| {
                const pg = p.borrow();
                try probe_classes.append(allocator, pg.get().name);
                if (pg.get().fqn.len != 0 and !std.mem.eql(u8, pg.get().fqn, pg.get().name)) try probe_classes.append(allocator, pg.get().fqn);
                const next = pg.get().parent;
                pg.deinit();
                p.deinit();
                cur = if (next) |n| n.clone() else null;
            }
        }
        cg.deinit();
    }
    // A companion-extension receiver is declared as `<Class>.Companion`, so add
    // that probe name; the companion singleton is then built and dispatched on.
    var comp_probe_buf: [160]u8 = undefined;
    const comp_probe = std.fmt.bufPrint(&comp_probe_buf, "{s}.Companion", .{cls_name}) catch cls_name;
    try probe_classes.append(allocator, comp_probe);
    var comp_name: ?[]const u8 = null;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const comp = &mg.get().registry.companion_singletons;
        for (probe_classes.items) |k| {
            if (comp.get(k)) |c| {
                comp_name = c;
                break;
            }
            if (comp.get(simpleName(k))) |c| {
                comp_name = c;
                break;
            }
        }
    }
    if (comp_name) |cn| {
        // The first access through a companion member constructs the companion.
        var singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
            .ok => |maybe| maybe,
            .err => |e| return .{ .err = e },
        };
        // An extension on the class or an ancestor dispatches through it too.
        if (singleton == null and extensionTargetsAny(self, name, probe_classes.items)) {
            singleton = switch (try host_globals.ensureObjectSingleton(self, cn)) {
                .ok => |maybe| maybe,
                .err => |e| return .{ .err = e },
            };
        }
        if (singleton) |s| {
            if (s == .Instance) {
                const no_such = try std.fmt.allocPrint(allocator, "`{s}` on", .{name});
                defer if (runtime.freeScratch()) allocator.free(no_such);
                const r = try callMemberRec(self, allocator, &s, name, args);
                switch (r) {
                    .ok => return r,
                    .err => |e| switch (e) {
                        .Unimplemented => |m| {
                            if (!(std.mem.find(u8, m, "Vm::call_member") != null and std.mem.find(u8, m, no_such) != null)) return r;
                            // The discarded miss message is freed here.
                            freeDispatchMiss(allocator, r);
                            // A companion property holding a callable calls its `invoke`.
                            const field: ?Value = blk: {
                                const ig = s.Instance.borrow();
                                defer ig.deinit();
                                break :blk ig.get().get(name);
                            };
                            if (field) |fv| {
                                if (fv == .Instance) {
                                    const r2 = try callMemberRec(self, allocator, &fv, "invoke", args);
                                    if (!isDispatchMissFor(r2, "invoke")) return r2;
                                    freeDispatchMiss(allocator, r2);
                                }
                            }
                        },
                        else => return r,
                    },
                }
            }
        }
    }
    // An enum entry as callee runs its `invoke`; naming one initializes the enum.
    if (is_enum and !std.mem.eql(u8, name, "values") and !std.mem.eql(u8, name, "valueOf")) {
        const names_entry = blk: {
            const cg = cls.borrow();
            defer cg.deinit();
            for (cg.get().enum_entries) |e| {
                if (std.mem.eql(u8, e.name, name)) break :blk true;
            }
            break :blk false;
        };
        if (names_entry) {
            if (try host_globals.ensureEnumInit(self, cls)) |e| return .{ .err = e };
            const entry: ?Value = blk: {
                const cg = cls.borrow();
                defer cg.deinit();
                for (cg.get().enum_entries) |e| {
                    if (std.mem.eql(u8, e.name, name)) break :blk e.value;
                }
                break :blk null;
            };
            if (entry) |ev| {
                if (ev == .Instance) {
                    const r = try callMemberRec(self, allocator, &ev, "invoke", args);
                    if (!isDispatchMissFor(r, "invoke")) return r;
                    freeDispatchMiss(allocator, r);
                }
            }
        }
    }
    // `values()`/`valueOf()` are static uses, so the first one initializes it.
    if (is_enum and ((std.mem.eql(u8, name, "values") and args.len == 0) or
        (std.mem.eql(u8, name, "valueOf") and args.len == 1 and args[0] == .String)))
    {
        if (try host_globals.ensureEnumInit(self, cls)) |e| return .{ .err = e };
    }
    if (is_enum and std.mem.eql(u8, name, "values") and args.len == 0) {
        const cg = cls.borrow();
        var items: std.ArrayList(Value) = .empty;
        for (cg.get().enum_entries) |e| {
            e.value.retain();
            try items.append(allocator, e.value);
        }
        cg.deinit();
        return .{ .ok = try Value.newList(allocator, .{
            .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
            .mutable = false,
            .enum_entries = true,
            .backing = null,
        }) };
    }
    if (is_enum and std.mem.eql(u8, name, "valueOf") and args.len == 1 and args[0] == .String) {
        const cg = cls.borrow();
        const sg = args[0].String.borrow();
        const want = sg.get().bytes;
        for (cg.get().enum_entries) |e| {
            if (std.mem.eql(u8, e.name, want)) {
                const v = e.value;
                // host-returns-owned: the singleton is owned by the ClassDef.
                v.retain();
                sg.deinit();
                cg.deinit();
                return .{ .ok = v };
            }
        }
        const msg = try std.fmt.allocPrint(allocator, "No enum constant {s}.{s}", .{ cg.get().fqn, want });
        defer if (runtime.freeScratch()) allocator.free(msg);
        sg.deinit();
        cg.deinit();
        return .{ .err = try throwExc(allocator, "kotlin.IllegalArgumentException", msg) };
    }
    return null;
}

pub fn samInstanceDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    const target = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().get("__sam_target__");
    };
    if (target) |t| {
        var cls_name: []const u8 = undefined;
        {
            const g = inst.borrow();
            const cg = g.get().class.borrow();
            cls_name = cg.get().name;
            cg.deinit();
            g.deinit();
        }
        const dispatch_lambda = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            if (mg.get().registry.hierarchy_methods.get(cls_name)) |methods| {
                if (methods.count() != 0) break :blk methods.contains(name);
            }
            break :blk true;
        };
        if (dispatch_lambda) {
            // A `context(...)` SAM method takes each resolved context as a leading arg.
            var with_ctx: std.ArrayList(Value) = .empty;
            defer with_ctx.deinit(allocator);
            const call_args: []const Value = blk: {
                const ctx_types = samMemberCtxTypes(self, cls_name, name) orelse break :blk args;
                var it = std.mem.splitScalar(u8, ctx_types, '|');
                while (it.next()) |ty| {
                    if (ty.len == 0) continue;
                    const v = self.ctxResolve(ty, false) orelse break :blk args;
                    try with_ctx.append(allocator, v);
                }
                try with_ctx.appendSlice(allocator, args);
                break :blk with_ctx.items;
            };
            // When the abstract method is a member extension, kotlinc scopes the
            // lambda body with the innermost enclosing receiver of that type as `this`.
            if (samMemberExtRecvType(self, cls_name, name)) |recv_ty| {
                const entries = try ir.eval.enclosingEntriesAlloc(allocator);
                defer allocator.free(entries);
                for (entries) |e| {
                    if (e.v != .Instance) continue;
                    if (receiverImplementsType(self, &e.v, recv_ty)) {
                        return try host_call_value.callValueWithThis(self, allocator, &t, &e.v, call_args, &.{});
                    }
                }
            }
            return try callValueRec(self, allocator, &t, call_args);
        }
    }
    return null;
}

/// Dispatch through an enclosing anonymous-object instance declaring a
/// member-extension `name`: the receiver becomes its extension `this`.
pub fn enclosingAnonMemberExtDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ name, args.len });
    defer allocator.free(arity_name);
    for (entries) |e| {
        if (e.v != .Instance) continue;
        var cls_name: []const u8 = undefined;
        {
            const g = e.v.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            cls_name = cg.get().name;
            cg.deinit();
        }
        const hit = lookupAnonMethod(self, allocator, cls_name, arity_name, name) orelse continue;
        // Only a member extension serves this arm; params[0] is its receiver.
        const hg = hit.module.borrow();
        const hf = funcAt(hg.get(), hit.func);
        const is_member_ext = hf != null and hf.?.kind == .member_extension and
            hf.?.params.len != 0 and std.mem.eql(u8, hf.?.params[0].name, "this");
        const recv_ty: []const u8 = if (is_member_ext) hf.?.params[0].ty.name else "";
        hg.deinit();
        if (!is_member_ext) continue;
        if (!receiverImplementsType(self, receiver, recv_ty)) continue;
        ir.eval.pushEnclosing(&e.v);
        defer ir.eval.popEnclosing();
        return try invokeAnonMethod(self, allocator, receiver, hit, args, null);
    }
    return null;
}

/// A member extension declared by a named class on the enclosing receiver tower.
/// The lowerer binds it statically unless the receiver's static type is unknown.
pub fn enclosingNamedMemberExtDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const mptr: *const Module = self.module.asPtr();
    const candidates = mptr.funcsBySimpleName(name);
    if (candidates.len == 0) return null;
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    if (entries.len == 0) return null;
    for (entries) |e| {
        if (e.v != .Instance) continue;
        var cls_name: []const u8 = undefined;
        var cls_fqn: []const u8 = undefined;
        {
            const g = e.v.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            cls_name = cg.get().name;
            cls_fqn = cg.get().fqn;
        }
        for (candidates) |fid| {
            const owner = mptr.registry.member_ext_owner_class.get(fid) orelse continue;
            if (!std.mem.eql(u8, owner, cls_name) and !std.mem.eql(u8, owner, cls_fqn)) continue;
            const f = mptr.funcById(fid) orelse continue;
            if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
            if (f.params.len - 1 != args.len) continue;
            if (!receiverImplementsType(self, receiver, f.params[0].ty.name)) continue;
            const all = try prependReceiver(allocator, receiver, args);
            defer if (runtime.freeScratch()) allocator.free(all);
            ir.eval.pushEnclosing(&e.v);
            defer ir.eval.popEnclosing();
            return try callFuncRec(self, allocator, mptr, fid, all);
        }
        // `class Test : IFoo by impl` forwards member extensions to the delegate.
        var di: usize = 0;
        while (delegateFieldAt(&e.v, di)) |d| : (di += 1) {
            if (d != .Instance) continue;
            var d_name: []const u8 = undefined;
            var d_fqn: []const u8 = undefined;
            {
                const g = d.Instance.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                d_name = cg.get().name;
                d_fqn = cg.get().fqn;
            }
            for (candidates) |fid| {
                const owner = mptr.registry.member_ext_owner_class.get(fid) orelse continue;
                if (!std.mem.eql(u8, owner, d_name) and !std.mem.eql(u8, owner, d_fqn)) continue;
                const f = mptr.funcById(fid) orelse continue;
                if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
                if (f.params.len - 1 != args.len) continue;
                if (!receiverImplementsType(self, receiver, f.params[0].ty.name)) continue;
                const all = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(all);
                ir.eval.pushEnclosing(&d);
                defer ir.eval.popEnclosing();
                return try callFuncRec(self, allocator, mptr, fid, all);
            }
        }
    }
    return null;
}

/// The `idx`-th `by`-delegate stored on an instance (`__delegate__<iface>`
/// fields, declaration order), or null past the last one.
pub fn delegateFieldAt(v: *const Value, idx: usize) ?Value {
    if (v.* != .Instance) return null;
    const g = v.Instance.borrow();
    defer g.deinit();
    var seen: usize = 0;
    for (g.get().fields.items) |f| {
        if (!std.mem.startsWith(u8, f.name, "__delegate__")) continue;
        if (seen == idx) return f.value;
        seen += 1;
    }
    return null;
}

/// Both slices point into the module's name storage and dangle once its program
/// ends; the generation bumped at that boundary keeps later reads off freed IR.
pub threadlocal var sam_ext_memo_name: ?[]const u8 = null;
pub threadlocal var sam_ext_memo_ty: ?[]const u8 = null;
pub threadlocal var sam_ext_memo_gen: u32 = 0;

/// The receiver type when a `fun interface` declares `name` as a member extension.
pub fn samAbstractExtRecvType(self: *VmHost, name: []const u8) ?[]const u8 {
    if (sam_ext_memo_gen != cacheGen()) {
        sam_ext_memo_name = null;
        sam_ext_memo_ty = null;
        sam_ext_memo_gen = cacheGen();
    }
    if (sam_ext_memo_name) |n| {
        if (std.mem.eql(u8, n, name)) return sam_ext_memo_ty;
    }
    var found: ?[]const u8 = null;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        var it = mg.get().registry.iface_member_ext_recv.iterator();
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.key_ptr.b, name)) continue;
            // Only a fun interface can be served by a lambda.
            if (!classIsFunInterface(self, e.key_ptr.a)) continue;
            found = e.value_ptr.*;
            break;
        }
    }
    sam_ext_memo_name = name;
    sam_ext_memo_ty = found;
    return found;
}

/// Whether the enclosing `this` chain holds a fun-interface (SAM) instance whose
/// abstract member extension is `name`; `samMemberExtOnCallable` then stands down.
pub fn enclosingSamInstanceHandles(self: *VmHost, allocator: Allocator, name: []const u8) Allocator.Error!bool {
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    for (entries) |e| {
        if (e.v != .Instance) continue;
        var cls_name: []const u8 = undefined;
        {
            const g = e.v.Instance.borrow();
            defer g.deinit();
            if (g.get().get("__sam_target__") == null) continue;
            const cg = g.get().class.borrow();
            cls_name = cg.get().name;
            cg.deinit();
        }
        if (samMemberExtRecvType(self, cls_name, name) != null) return true;
    }
    return false;
}

pub fn samMemberExtOnCallable(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8,args: []const Value) Allocator.Error!?EvalResult {
    const recv_ty = samAbstractExtRecvType(self, name) orelse return null;
    // Stand down when an enclosing SAM instance owns this abstract method: the
    // callable receiver is then the extension receiver, not the body.
    if (try enclosingSamInstanceHandles(self, allocator, name)) return null;
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    for (entries) |e| {
        if (!receiverImplementsType(self, &e.v, recv_ty)) continue;
        var this_v = e.v;
        return try host_call_value.callValueWithThis(self, allocator, receiver, &this_v, args, &.{});
    }
    return null;
}

/// Dispatch through an enclosing SAM instance's stored lambda, receiver as `this`.
pub fn enclosingSamMemberExtDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    for (entries) |e| {
        if (e.v != .Instance) continue;
        var cls_name: []const u8 = undefined;
        var target: ?Value = null;
        {
            const g = e.v.Instance.borrow();
            defer g.deinit();
            target = g.get().get("__sam_target__");
            if (target == null) continue;
            const cg = g.get().class.borrow();
            cls_name = cg.get().name;
            cg.deinit();
        }
        const recv_ty = samMemberExtRecvType(self, cls_name, name) orelse continue;
        if (!receiverImplementsType(self, receiver, recv_ty)) continue;
        // A bound reference takes the extension receiver as a leading argument.
        if (isBoundReference(&target.?)) {
            const call_args = try allocator.alloc(Value, args.len + 1);
            defer allocator.free(call_args);
            call_args[0] = receiver.*;
            @memcpy(call_args[1..], args);
            return try callValueRec(self, allocator, &target.?, call_args);
        }
        return try host_call_value.callValueWithThis(self, allocator, &target.?, receiver, args, &.{});
    }
    return null;
}

/// Dispatch through a lambda on the enclosing receiver tower standing in for a
/// fun interface whose abstract member extension is `name`: the closure is the body.
pub fn enclosingSamLambdaDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const recv_ty = samAbstractExtRecvType(self, name) orelse return null;
    if (!receiverImplementsType(self, receiver, recv_ty)) return null;
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    for (entries) |e| {
        const arity: usize = switch (e.v) {
            .IrClosure => |c| blk: {
                const info = self.closures.get(@intCast(c.asPtr().id)) orelse continue;
                break :blk info.n_params;
            },
            else => continue,
        };
        if (arity != args.len) continue;
        var callee = e.v;
        return try host_call_value.callValueWithThis(self, allocator, &callee, receiver, args, &.{});
    }
    return null;
}

/// The `context(...)` parameter types of `cls`'s abstract member `name`, `|`-separated.
pub fn samMemberCtxTypes(self: *VmHost, cls: []const u8, name: []const u8) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    return mg.get().registry.iface_member_ctx_types.get(.{ .a = cls, .b = name });
}
pub fn samMemberExtRecvType(self: *VmHost, cls: []const u8, name: []const u8) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    return mg.get().registry.iface_member_ext_recv.get(.{ .a = cls, .b = name });
}

/// A `receiver::member` reference is a synthetic Instance holding both parts.
pub fn isBoundReference(receiver: *const Value) bool {
    if (receiver.* != .Instance) return false;
    const g = receiver.Instance.borrow();
    defer g.deinit();
    return g.get().get("__bound_receiver__") != null and g.get().get("__bound_name__") != null;
}
