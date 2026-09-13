//! Extension-property resolution: declared getter/setter lookup, the
//! owner-keyed scoping probe a private member extension needs, delegate forms.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const root = @import("../../interp_ir.zig");
const host_call_member = @import("../host_call_member.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;

const host_fields = @import("../host_fields.zig");
const NO_FID = host_fields.NO_FID;
const OwnerKeyedSlot = host_fields.OwnerKeyedSlot;
const fldTls = host_fields.fldTls;
const getField = host_fields.getField;
const missTraceEnvCached = host_fields.missTraceEnvCached;

const common = @import("common.zig");
const className = common.className;
const containsStr = common.containsStr;
const errRes = common.errRes;
const evalGetterTagged = common.evalGetterTagged;
const lastSegment = common.lastSegment;
const lookupPairFunc = common.lookupPairFunc;
const ok = common.ok;

const read_paths = @import("read_paths.zig");
const freeFieldMiss = read_paths.freeFieldMiss;
const getMemberField = read_paths.getMemberField;

const class_access = @import("class_access.zig");
const companionInstanceForClass = class_access.companionInstanceForClass;

/// Resolve the in-scope extension-property `FuncId` for `(recv_simple, name)`.
pub fn resolveExtensionProp(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    recv_simple: []const u8,
    name: []const u8,
) Allocator.Error!?FuncId {
    const fid = try resolveExtensionPropImpl(self, allocator, receiver, recv_simple, name, false) orelse return null;
    if (try memberExtOutOfScope(self, allocator, receiver, fid)) return null;
    return fid;
}

/// A member extension property (`class C { val R.p get() = ... }`) is in scope only
/// while an implicit receiver of its owner class is; otherwise it would shadow a member.
pub fn memberExtOutOfScope(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId) Allocator.Error!bool {
    switch (receiver.*) {
        .Instance, .Class => return false,
        else => {},
    }
    const mptr: *const Module = self.module.asPtr();
    const owner = mptr.registry.member_ext_owner_class.get(fid) orelse return false;
    return (try host_call_member.memberExtOwnerInstance(self, allocator, receiver, owner)) == null;
}

/// Whether the receiver's extension property is registered under the companion key.
pub fn classExtPropUsesCompanion(self: *VmHost, allocator: Allocator, recv_simple: []const u8, name: []const u8) Allocator.Error!bool {
    const comp_key = try std.fmt.allocPrint(allocator, "{s}.Companion", .{recv_simple});
    defer allocator.free(comp_key);
    const pg = self.prog.borrow();
    defer pg.deinit();
    return lookupPairFunc(pg.get().extension_props, comp_key, name) != null;
}

/// Evaluate an extension or delegated extension property getter for `receiver`.
/// Entered from `$extread$`, so it skips the stored-field and member-getter arms.
pub fn extensionPropRead(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const recv_simple: []const u8 = switch (receiver.*) {
        .Instance => |i| className(i),
        .Class => |c| blk: {
            const g = c.borrow();
            defer g.deinit();
            break :blk lastSegment(g.get().name);
        },
        else => lastSegment(receiver.typeFqn()),
    };
    if (try resolveExtensionProp(self, allocator, receiver, recv_simple, name)) |fid| {
        const mptr: *const Module = self.module.asPtr();
        if (fid.int() >= mptr.funcCount()) return null;
        // A companion extension's getter runs with the companion instance as `this`.
        var getter_recv = receiver.*;
        if (receiver.* == .Class and try classExtPropUsesCompanion(self, allocator, recv_simple, name)) {
            if (try companionInstanceForClass(self, recv_simple)) |comp| getter_recv = comp;
        }
        // A member extension's getter body has its declaring class's `this` in scope.
        var pushed_owner = false;
        if (mptr.registry.member_ext_owner_class.get(fid)) |owner| {
            if (try host_call_member.memberExtOwnerInstance(self, allocator, &getter_recv, owner)) |inst| {
                ir.eval.pushEnclosing(&inst);
                pushed_owner = true;
            }
        }
        const r = try evalGetterTagged(self, allocator, fid, getter_recv, "ext-prop");
        if (pushed_owner) ir.eval.popEnclosing();
        return r;
    }
    if (try resolveExtPropDelegate(self, allocator, receiver, recv_simple, name)) |hit| {
        const d = try extPropDelegateInstance(self, allocator, hit.key, name, hit.fid);
        const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name) } };
        return try delegateCall(self, allocator, &d, "getValue", &.{ receiver.*, prop_ref }, receiver);
    }
    return null;
}

/// The setter half of `resolveExtensionProp`: the same receiver, supertype, companion
/// and `Any` candidate set against the registered extension-property setters.
pub fn resolveExtensionPropSetter(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    recv_simple: []const u8,
    name: []const u8,
) Allocator.Error!?FuncId {
    return resolveExtensionPropImpl(self, allocator, receiver, recv_simple, name, true);
}

/// `getValue`/`setValue` on a delegate, with the delegated property's owner pushed
/// as an enclosing receiver: the operator may be a member extension of the owner.
pub fn delegateCall(self: *VmHost, allocator: Allocator, d: *const Value, name: []const u8, args: []const Value, owner: *const Value) Allocator.Error!EvalResult {
    const pushed = owner.* == .Instance;
    if (pushed) host_call_member.pushAccessEnclosing(self, owner);
    defer if (pushed) host_call_member.popAccessEnclosing(self);
    return self.callMember(allocator, d, name, args);
}

pub fn hostHasExtProp(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) bool {
    const recv_simple: []const u8 = switch (receiver.*) {
        .Instance => |i| className(i),
        else => lastSegment(receiver.typeFqn()),
    };
    const fid = resolveExtensionProp(self, allocator, receiver, recv_simple, name) catch return false;
    if (fid != null) return true;
    const delegated = resolveExtPropDelegate(self, allocator, receiver, recv_simple, name) catch return false;
    return delegated != null;
}

/// Whether the extension property `name` is declared with a callable type, so
/// `recv.name(args)` is `recv.name.invoke(args)`. Reading it would run its getter.
pub fn extPropDeclaredCallable(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) bool {
    const recv_simple: []const u8 = switch (receiver.*) {
        .Instance => |i| className(i),
        else => lastSegment(receiver.typeFqn()),
    };
    const fid: FuncId = blk: {
        if (resolveExtensionProp(self, allocator, receiver, recv_simple, name) catch null) |f| break :blk f;
        if (resolveExtPropDelegate(self, allocator, receiver, recv_simple, name) catch null) |hit| break :blk hit.fid;
        return false;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    var head: ?[]const u8 = recv_simple;
    var depth: usize = 0;
    while (head) |h| : (depth += 1) {
        if (depth > 32) break;
        if (mod.registry.ext_prop_type_heads.get(.{ .a = h, .b = name })) |declared| {
            if (std.mem.eql(u8, declared, "<function>")) return true;
            const dt = ir.TypeRef{ .name = declared, .nullable = false, .args = &.{} };
            return declaredTypeIsCallable(mod, &dt);
        }
        head = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            const def = cg.get().get(h) orelse break :blk null;
            const dg = def.borrow();
            defer dg.deinit();
            const p = dg.get().parent orelse break :blk null;
            const pg = p.borrow();
            defer pg.deinit();
            break :blk pg.get().name;
        };
    }
    const f = mod.funcById(fid) orelse return false;
    return declaredTypeIsCallable(mod, &f.return_ty);
}

pub fn declaredTypeIsCallable(mod: *const ir.Module, ty: *const ir.TypeRef) bool {
    if (root.isFunctionType(ty)) return true;
    var head = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    const cid = mod.classId(head) orelse mod.classIdByFqn(head) orelse return false;
    return mod.classHierarchyDeclaresMember(cid, "invoke");
}

/// A bare name in a nested class's body can name a member of an enclosing class's
/// companion: Kotlin's static scope of the enclosing classes, walked outward.
pub fn enclosingCompanionMember(self: *VmHost, allocator: Allocator, inst: *const Value, name: []const u8, args: ?[]const Value) Allocator.Error!?EvalResult {
    if (inst.* != .Instance) return null;
    var cur: ?[]const u8 = className(inst.Instance);
    var depth: usize = 0;
    while (cur) |c| : (depth += 1) {
        if (depth > 16) break;
        const enc = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.enclosing_class.get(c);
        } orelse break;
        var owner: ?[]const u8 = enc;
        var updepth: usize = 0;
        while (owner) |o| : (updepth += 1) {
            if (updepth > 32) break;
            if (try companionInstanceForClass(self, o)) |comp| {
                if (comp == .Instance and host_call_member.hostHasMember(self, &comp, name)) {
                    if (args) |a| return try host_call_member.callMember(self, allocator, &comp, name, a);
                    return try getField(self, allocator, &comp, name);
                }
                if (args == null) {
                    const has_field = blk: {
                        const g = comp.Instance.borrow();
                        defer g.deinit();
                        break :blk g.get().get(name) != null;
                    };
                    if (has_field) return try getField(self, allocator, &comp, name);
                }
            }
            owner = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                const def = cg.get().get(o) orelse break :blk null;
                const dg = def.borrow();
                defer dg.deinit();
                const p = dg.get().parent orelse break :blk null;
                const pg = p.borrow();
                defer pg.deinit();
                break :blk pg.get().name;
            };
        }
        cur = enc;
    }
    return null;
}

pub fn hostHasExtPropSetter(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) bool {
    const recv_simple: []const u8 = switch (receiver.*) {
        .Instance => |i| className(i),
        else => lastSegment(receiver.typeFqn()),
    };
    const fid = resolveExtensionPropSetter(self, allocator, receiver, recv_simple, name) catch return false;
    return fid != null;
}

pub const ExtDelegateHit = struct { key: []const u8, fid: FuncId };

/// Resolve a delegated extension property (`val R.x by expr`): exact receiver, then
/// the supertype chain. Returns the declaring key so one cached delegate serves subtypes.
pub fn resolveExtPropDelegate(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    recv_simple: []const u8,
    name: []const u8,
) Allocator.Error!?ExtDelegateHit {
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (pg.get().extension_prop_delegates.count() == 0) return null;
        if (lookupPairFunc(pg.get().extension_prop_delegates, recv_simple, name)) |fid| {
            return .{ .key = recv_simple, .fid = fid };
        }
    }
    if (receiver.* == .Instance) {
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(allocator);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            for (cg.get().supertype_names) |s| try queue.append(allocator, s);
        }
        var head: usize = 0;
        while (head < queue.items.len) {
            const sup = queue.items[head];
            head += 1;
            if (containsStr(seen.items, sup)) continue;
            try seen.append(allocator, sup);
            {
                const pg = self.prog.borrow();
                defer pg.deinit();
                if (lookupPairFunc(pg.get().extension_prop_delegates, sup, name)) |fid| {
                    return .{ .key = sup, .fid = fid };
                }
            }
            const def: ?ObjRef(ClassDef) = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                break :blk cg.get().get(sup);
            };
            if (def) |d| {
                const dg = d.borrow();
                defer dg.deinit();
                for (dg.get().supertype_names) |s| try queue.append(allocator, s);
            }
        }
    }
    return null;
}

/// Run the delegate thunk once; cache the result as a hidden global keyed by
/// declaring receiver and property name.
pub fn extPropDelegateInstance(
    self: *VmHost,
    allocator: Allocator,
    key: []const u8,
    name: []const u8,
    fid: FuncId,
) Allocator.Error!Value {
    var kb: [256]u8 = undefined;
    const cache_name = std.fmt.bufPrint(&kb, "__ext_delegate\x1f{s}\x1f{s}", .{ key, name }) catch
        return runThunkValue(self, allocator, fid);
    {
        const gg = self.globals.borrow();
        defer gg.deinit();
        if (gg.get().lookup(cache_name)) |v| return v;
    }
    const v = try runThunkValue(self, allocator, fid);
    const owned_name = try allocator.dupe(u8, cache_name);
    const g = self.globals.borrowMut();
    defer g.deinit();
    g.get().define(owned_name, v) catch {};
    return v;
}

pub fn runThunkValue(self: *VmHost, allocator: Allocator, fid: FuncId) Allocator.Error!Value {
    const mptr: *const Module = self.module.asPtr();
    const r = try self.callFunc(allocator, mptr, fid, &.{});
    return switch (r) {
        .ok => |v| v,
        .err => Value.Null,
    };
}

pub fn ownerKeyedSlotKey(cls_ident: usize, recv_key: []const u8, name: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
    h.update(std.mem.asBytes(&cls_ident));
    h.update(recv_key);
    h.update(&[_]u8{0});
    h.update(name);
    const v = h.final();
    return if (v == 0) 1 else v;
}

/// Probe the owner-qualified extension-prop keys (`"<Owner>\x00<recv>"`) for one class.
pub fn ownerKeyedForClass(cls: ObjRef(runtime.ClassDef), map: anytype, recv_key: []const u8, name: []const u8) ?FuncId {
    // The whole parent chain, not one supertype level: a member extension declared
    // on an ancestor is in scope for every subclass body.
    var kb: [512]u8 = undefined;
    var cur: ObjRef(runtime.ClassDef) = cls;
    var depth: usize = 0;
    while (depth < runtime.ClassDef.MAX_WALK) : (depth += 1) {
        const cg = cur.borrow();
        const cd = cg.get();
        if (ownerKeyedProbeOne(cd.fqn, kb[0..], map, recv_key, name)) |fid| {
            cg.deinit();
            return fid;
        }
        if (ownerKeyedProbeOne(cd.name, kb[0..], map, recv_key, name)) |fid| {
            cg.deinit();
            return fid;
        }
        for (cd.supertype_names) |sn| {
            if (ownerKeyedProbeOne(sn, kb[0..], map, recv_key, name)) |fid| {
                cg.deinit();
                return fid;
            }
        }
        const parent = cd.parent orelse {
            cg.deinit();
            return null;
        };
        cg.deinit();
        cur = parent;
    }
    return null;
}

pub fn ownerKeyedProbeOne(owner: []const u8, kb: []u8, map: anytype, recv_key: []const u8, name: []const u8) ?FuncId {
    if (std.fmt.bufPrint(kb, "{s}\x00{s}", .{ owner, recv_key })) |okey| {
        return lookupPairFunc(map, okey, name);
    } else |_| {
        // An oversized key still has to resolve: the probe decides which declaration binds.
        const heap = std.heap.page_allocator;
        const okey = std.fmt.allocPrint(heap, "{s}\x00{s}", .{ owner, recv_key }) catch return null;
        defer heap.free(okey);
        return lookupPairFunc(map, okey, name);
    }
}

/// Probe the owner-qualified keys for every class on the lexical receiver tower:
/// private member extensions share a (receiver, name) pair, and only the in-scope owner binds.
pub fn ownerKeyedExtProp(comptime setters: bool, map: anytype, recv_key: []const u8, name: []const u8) ?FuncId {
    const memo: *[1024]OwnerKeyedSlot = if (setters) &fldTls().owner_keyed_memo_set else &fldTls().owner_keyed_memo;
    var it = ir.eval.frameThisChainIter();
    while (it.next()) |v| {
        if (v != .Instance) continue;
        const cls = blk: {
            const g = v.Instance.borrow();
            defer g.deinit();
            break :blk g.get().class;
        };
        const k = ownerKeyedSlotKey(cls.identity(), recv_key, name);
        const slot = &memo[(k >> 7) % memo.len];
        const gen = host_call_member.dispatch_cache_gen.load(.monotonic);
        if (slot.key == k and slot.gen == gen) {
            if (slot.hit) return FuncId.from(slot.fid);
        } else {
            const found = ownerKeyedForClass(cls, map, recv_key, name);
            slot.* = .{ .key = k, .gen = gen, .hit = found != null, .fid = if (found) |f| f.int() else NO_FID };
            if (found) |fid| return fid;
        }
        if (ownerKeyedViaDelegates(&v, map, recv_key, name)) |fid| return fid;
    }
    // The bare member-extension call arm pushes its dispatch owner on the enclosing
    // chain, never as a frame `this`; probe those receivers with the same memo.
    var eit = ir.eval.enclosingChainIter();
    while (eit.next()) |v| {
        if (v != .Instance) continue;
        const cls = blk: {
            const g = v.Instance.borrow();
            defer g.deinit();
            break :blk g.get().class;
        };
        const k = ownerKeyedSlotKey(cls.identity(), recv_key, name);
        const slot = &memo[(k >> 7) % memo.len];
        const gen = host_call_member.dispatch_cache_gen.load(.monotonic);
        if (slot.key == k and slot.gen == gen) {
            if (slot.hit) return FuncId.from(slot.fid);
        } else {
            const found = ownerKeyedForClass(cls, map, recv_key, name);
            slot.* = .{ .key = k, .gen = gen, .hit = found != null, .fid = if (found) |f| f.int() else NO_FID };
            if (found) |fid| return fid;
        }
        if (ownerKeyedViaDelegates(&v, map, recv_key, name)) |fid| return fid;
    }
    return null;
}

/// A member extension declared by a `by`-delegate of the receiver is in scope through
/// the wrapper. The delegate's runtime class varies per instance, so this is not memoized.
pub fn ownerKeyedViaDelegates(v: *const Value, map: anytype, recv_key: []const u8, name: []const u8) ?FuncId {
    var di: usize = 0;
    while (host_call_member.delegateFieldAt(v, di)) |d| : (di += 1) {
        if (d != .Instance) continue;
        const dcls = blk: {
            const g = d.Instance.borrow();
            defer g.deinit();
            break :blk g.get().class;
        };
        if (ownerKeyedForClass(dcls, map, recv_key, name)) |fid| return fid;
    }
    return null;
}

/// An imported companion/member extension property is in scope in its importing file
/// without the owner on the receiver tower: the import's fqn minus its leaf is the owner.
pub fn importOwnedExtProp(self: *VmHost, map: anytype, recv_key: []const u8, name: []const u8) ?FuncId {
    const f = ir.eval.currentFrameFunc() orelse {
        if (missTraceEnvCached()) |w| {
            if (std.mem.eql(u8, w, name)) std.debug.print("[imp-ext] no frame func\n", .{});
        }
        return null;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    const file = (module.decl_span.get(f.id.int()) orelse {
        if (missTraceEnvCached()) |w| {
            if (std.mem.eql(u8, w, name)) std.debug.print("[imp-ext] no decl_span for {s}#{d}\n", .{ f.name, f.id.int() });
        }
        return null;
    }).file;
    if (missTraceEnvCached()) |w| {
        if (std.mem.eql(u8, w, name)) std.debug.print("[imp-ext] fn={s} file={any} paths={d}\n", .{ f.name, file, module.importAliasPathsIn(file, name).len });
    }
    for (module.importAliasPathsIn(file, name)) |path| {
        if (path.fqn.len <= name.len + 1) continue;
        const owner = path.fqn[0 .. path.fqn.len - name.len - 1];
        var kb: [512]u8 = undefined;
        if (ownerKeyedProbeOne(owner, kb[0..], map, recv_key, name)) |fid| return fid;
        if (ownerKeyedProbeOne(owner, kb[0..], map, "Any", name)) |fid| return fid;
    }
    return null;
}

pub fn resolveExtensionPropImpl(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    recv_simple: []const u8,
    name: []const u8,
    comptime setters: bool,
) Allocator.Error!?FuncId {
    const Pick = struct {
        fn map(p: anytype) @TypeOf(if (setters) p.extension_prop_setters else p.extension_props) {
            return if (setters) p.extension_prop_setters else p.extension_props;
        }
    };
    // A class-value receiver matches only a companion extension (keyed `X.Companion`),
    // never `val X.name`: the bare key would run an instance getter with the class as `this`.
    if (receiver.* == .Class) {
        const comp_key = try std.fmt.allocPrint(allocator, "{s}.Companion", .{recv_simple});
        defer allocator.free(comp_key);
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (lookupPairFunc(Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
        // A private member extension registers only under the owner-qualified key.
        if (pg.get().owner_keyed_ext_names.contains(name)) {
            if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
            if (importOwnedExtProp(self, Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
        }
        // A class value is a `KClass`: `val KClass<*>.x` applies with the class as `this`.
        if (lookupPairFunc(Pick.map(pg.get().*), "KClass", name)) |fid| return fid;
        if (lookupPairFunc(Pick.map(pg.get().*), "Any", name)) |fid| return fid;
        return null;
    }
    // A null receiver dispatches an extension declared on a nullable receiver type;
    // kotlinc resolves that statically. Only an unambiguous declaration binds by bare name.
    if (receiver.* == .Null and !setters) {
        const pg = self.prog.borrow();
        defer pg.deinit();
        // The frame's package first: same-name nullable extensions elsewhere blank the bare-name entry.
        if (ir.eval.currentFramePackage()) |pkg| {
            var buf: [256]u8 = undefined;
            if (pkg.len + 1 + name.len <= buf.len) {
                const key = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ pkg, name }) catch null;
                if (key) |k| {
                    if (pg.get().nullable_ext_props.get(k)) |maybe| {
                        if (maybe) |fid| return fid;
                    }
                }
            }
        }
        if (pg.get().nullable_ext_props.get(name)) |maybe| {
            if (maybe) |fid| return fid;
        }
        return null;
    }
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        // A companion receiver arrives mangled (`Target$Companion$Companion`) but
        // registers under the source-written type (`Target.Companion`); try both.
        var comp_alias_buf: [256]u8 = undefined;
        const comp_alias: ?[]const u8 = blk: {
            const at = std.mem.find(u8, recv_simple, "$Companion") orelse break :blk null;
            if (at == 0) break :blk null;
            break :blk std.fmt.bufPrint(&comp_alias_buf, "{s}.Companion", .{recv_simple[0..at]}) catch null;
        };

        if (pg.get().owner_keyed_ext_names.contains(name)) {
            if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), recv_simple, name)) |fid| return fid;
            if (importOwnedExtProp(self, Pick.map(pg.get().*), recv_simple, name)) |fid| return fid;
            // The companion alias needs the owner-qualified probe too.
            if (comp_alias) |alias| {
                if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), alias, name)) |fid| return fid;
                if (importOwnedExtProp(self, Pick.map(pg.get().*), alias, name)) |fid| return fid;
            }
        }
        if (missTraceEnvCached()) |w| {
            if (std.mem.eql(u8, w, name))
                std.debug.print("[extprop-walk] try=({s},{s})\n", .{ recv_simple, name });
        }
        if (lookupPairFunc(Pick.map(pg.get().*), recv_simple, name)) |fid| return fid;
        if (comp_alias) |alias| {
            if (lookupPairFunc(Pick.map(pg.get().*), alias, name)) |fid| return fid;
        }
        // A file-mangled class (`KeyInfo$f352`) registers under the source-written receiver name.
        if (std.mem.find(u8, recv_simple, "$f")) |dol| {
            if (dol > 0 and dol + 2 < recv_simple.len and
                std.ascii.isDigit(recv_simple[dol + 2]))
            {
                if (lookupPairFunc(Pick.map(pg.get().*), recv_simple[0..dol], name)) |fid| return fid;
            }
        }
    }
    if (receiver.* != .Instance) {
        const sups: []const []const u8 = switch (receiver.*) {
            .Int, .Long, .Short, .Byte, .Float, .Double => &.{ "Number", "Comparable" },
            .String => &.{ "CharSequence", "Comparable" },
            .Char, .Bool, .UInt, .ULong, .UShort, .UByte => &.{"Comparable"},
            else => &.{},
        };
        const pg = self.prog.borrow();
        defer pg.deinit();
        for (sups) |sup| {
            if (pg.get().owner_keyed_ext_names.contains(name)) {
                if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), sup, name)) |fid| return fid;
            }
            if (lookupPairFunc(Pick.map(pg.get().*), sup, name)) |fid| return fid;
        }
    }
    if (receiver.* == .Instance) {
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(allocator);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            for (cg.get().supertype_names) |s| try queue.append(allocator, s);
        }
        var head: usize = 0;
        while (head < queue.items.len) {
            const sup = queue.items[head];
            head += 1;
            if (containsStr(seen.items, sup)) continue;
            try seen.append(allocator, sup);
            {
                const pg = self.prog.borrow();
                defer pg.deinit();
                if (pg.get().owner_keyed_ext_names.contains(name)) {
                    if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), sup, name)) |fid| return fid;
                }
                if (lookupPairFunc(Pick.map(pg.get().*), sup, name)) |fid| return fid;
            }
            const def: ?ObjRef(ClassDef) = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                break :blk cg.get().get(sup);
            };
            if (def) |d| {
                const dg = d.borrow();
                defer dg.deinit();
                for (dg.get().supertype_names) |s| try queue.append(allocator, s);
            }
        }
    }
    // A `Type.Companion` extension registers under `<outer>.Companion`; a companion
    // instance keys the lookup by its outer class's companion path.
    if (receiver.* == .Instance) {
        const cls = className(receiver.Instance);
        if (std.mem.find(u8, cls, "$Companion")) |i| {
            const outer = cls[0..i];
            const comp_key = try std.fmt.allocPrint(allocator, "{s}.Companion", .{outer});
            defer allocator.free(comp_key);
            const pg = self.prog.borrow();
            defer pg.deinit();
            if (lookupPairFunc(Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
        }
    }
    // An "Any"-keyed extension applies to every receiver, owner-gated ones included.
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (pg.get().owner_keyed_ext_names.contains(name)) {
            if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), "Any", name)) |fid| return fid;
        }
        if (lookupPairFunc(Pick.map(pg.get().*), "Any", name)) |fid| return fid;
    }
    return null;
}

/// A member of the declaring class of the member extension the innermost frame is
/// executing, read off the instance that made the extension visible. That receiver
/// outranks a top-level name; the probe is member-only, so it cannot reach the global tiers.
pub fn memberExtOwnerRead(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const f = ir.eval.currentFrameFunc() orelse return null;
    if (f.kind != .member_extension) return null;
    const owner = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().registry.member_ext_owner_class.get(f.id);
    } orelse return null;
    const inst = try vmhost.host_call_member.memberExtOwnerInstance(self, allocator, receiver, owner) orelse return null;
    if (inst == .Instance and receiver.* == .Instance and
        ObjRef(InstanceData).ptrEq(inst.Instance, receiver.Instance)) return null;
    switch (try getMemberField(self, allocator, &inst, name)) {
        .ok => |v| return ok(v),
        .err => |e| {
            if (e == .Unimplemented) {
                freeFieldMiss(allocator, e);
                return null;
            }
            return errRes(e);
        },
    }
}

/// Whether the instance's runtime class chain declares `name` as a `by`-delegated body
/// property. Local classes never reach the module registry, so the chain decides for them.
pub fn runtimeClassDelegatesProp(inst: anytype, name: []const u8) bool {
    var cur: ?ObjRef(ClassDef) = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    var hops: u8 = 0;
    while (cur) |c| : (hops += 1) {
        if (hops > 16) {
            c.deinit();
            return false;
        }
        const g = c.borrow();
        for (g.get().body_properties) |bp| {
            if (bp.delegate != null and std.mem.eql(u8, bp.name, name)) {
                g.deinit();
                c.deinit();
                return true;
            }
        }
        const next: ?ObjRef(ClassDef) = if (g.get().parent) |p| p.clone() else null;
        g.deinit();
        c.deinit();
        cur = next;
    }
    return false;
}

/// Whether (class, prop) is a registered `by`-delegated body property. The registry keys
/// packaged classes by FQN, so a simple-name hop also consults the class-index FQN.
pub fn delegatedPropRegistered(self: *VmHost, cn: []const u8, prop: []const u8) bool {
    const g = self.module.borrow();
    defer g.deinit();
    const mod = g.get();
    if (mod.registry.delegated_body_props.contains(.{ .a = cn, .b = prop })) return true;
    if (mod.classId(cn)) |cid| {
        if (cid.int() < mod.classes.items.len) {
            const fqn = mod.classes.items[cid.int()].fqn;
            if (!std.mem.eql(u8, fqn, cn) and
                mod.registry.delegated_body_props.contains(.{ .a = fqn, .b = prop })) return true;
        }
    }
    return false;
}
