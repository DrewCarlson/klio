//! Extension-property resolution: the declared getter/setter lookup, the
//! owner-keyed scoping probe a private member-extension property needs, the
//! delegate forms, and the runtime-delegation registry.

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

/// Resolve a top-level / supertype / `Type.Companion` / `Any` extension
/// property `FuncId` for `(recv_simple, name)`. Mirrors the chained
/// `.or_else` probe in `get_field`.
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

/// A MEMBER extension property (`class C { val R.p get() = … }`) is in scope
/// only while an implicit receiver of its owner class is. For a BUILTIN
/// receiver that already answers the name itself, applying an out-of-scope
/// member extension shadows the member — which Kotlin never does. Upstream
/// kotlinx-serialization's `MapEntrySerializer` declares
/// `override val Map.Entry<K, V>.value get() = this.value`; without this guard
/// every `entry.value` read anywhere binds that getter, and the getter's own
/// `this.value` re-enters it without bound.
pub fn memberExtOutOfScope(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId) Allocator.Error!bool {
    switch (receiver.*) {
        .Instance, .Class => return false,
        else => {},
    }
    const mptr: *const Module = self.module.asPtr();
    const owner = mptr.registry.member_ext_owner_class.get(fid) orelse return false;
    return (try host_call_member.memberExtOwnerInstance(self, allocator, receiver, owner)) == null;
}

/// Whether a class-value receiver's resolved extension property was
/// registered under the COMPANION key (`X.Companion`). Only that registration
/// runs its getter with the companion instance as `this`; a `KClass`/`Any`
/// keyed extension keeps the class value itself.
pub fn classExtPropUsesCompanion(self: *VmHost, allocator: Allocator, recv_simple: []const u8, name: []const u8) Allocator.Error!bool {
    const comp_key = try std.fmt.allocPrint(allocator, "{s}.Companion", .{recv_simple});
    defer allocator.free(comp_key);
    const pg = self.prog.borrow();
    defer pg.deinit();
    return lookupPairFunc(pg.get().extension_props, comp_key, name) != null;
}

/// Resolve and evaluate a (member-)extension property getter for `receiver`,
/// or a delegated extension property. Mirrors the extension arm of the field
/// ladder (`resolveExtensionProp` + owner-`this` seeding) but is entered
/// directly from the `$extread$` marker, so it never consults the
/// stored-field / member-getter-shadow arms. Null when no extension applies.
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
        // A companion extension's getter `this` is the class's companion
        // instance; route the class value to it. A KClass/Any keyed
        // extension keeps the class value itself.
        var getter_recv = receiver.*;
        if (receiver.* == .Class and try classExtPropUsesCompanion(self, allocator, recv_simple, name)) {
            if (try companionInstanceForClass(self, recv_simple)) |comp| getter_recv = comp;
        }
        // A member-extension property's getter body has its declaring class's
        // `this` in lexical scope; seed the getter frame with the owner
        // instance from the enclosing chain.
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

/// The setter half of `resolveExtensionProp`: walks the same
/// receiver/supertype/companion/`Any` candidate set against the registered
/// extension-property *setters*, so `var T.x set(value)` resolves for a
/// subtype receiver (`var ApplicationCall.receiveType` on a
/// `RoutingPipelineCall`) — not just the exact declared receiver type.
pub fn resolveExtensionPropSetter(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    recv_simple: []const u8,
    name: []const u8,
) Allocator.Error!?FuncId {
    return resolveExtensionPropImpl(self, allocator, receiver, recv_simple, name, true);
}

/// Whether `name` is settable on `receiver` through an extension-property
/// setter (`var T.name set(value)`) declared on the receiver's type or any
/// supertype. Used by the bare-name write path to route an implicit-`this`
/// assignment to the extension setter instead of a top-level binding.
/// `getValue`/`setValue` on a delegate, with the delegated property's owner
/// pushed as an enclosing receiver: the operator may be a MEMBER EXTENSION
/// of the owner (`class A { operator fun Delegate.getValue(...) }`).
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

/// Whether the extension property `name` on this receiver is DECLARED with
/// a callable type (a function type, or a class declaring `invoke`), so
/// that `recv.name(args)` is `recv.name.invoke(args)`. Decided from the
/// declaration alone: reading the property to look at its value would run
/// its getter.
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
    // The declaration's own type, keyed by the declared receiver head: the
    // receiver's class and each supertype the property could bind through.
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

/// A function type, or a class whose hierarchy declares `invoke`.
pub fn declaredTypeIsCallable(mod: *const ir.Module, ty: *const ir.TypeRef) bool {
    if (root.isFunctionType(ty)) return true;
    var head = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
    const cid = mod.classId(head) orelse mod.classIdByFqn(head) orelse return false;
    return mod.classHierarchyDeclaresMember(cid, "invoke");
}

/// A bare name inside a nested class's body that names a member of an
/// ENCLOSING class's companion object (or of a companion the enclosing class
/// inherits): Kotlin's static scope of the enclosing classes. Walks the
/// nesting chain outward from the instance's class; null when no companion
/// on the chain declares `name`.
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

/// Resolve a delegated extension property (`val R.x by expr`) for this
/// receiver: exact declared receiver, then the instance supertype chain.
/// Returns the DECLARING registry key alongside the thunk so the cached
/// delegate object is shared across subtype receivers.
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

/// The materialised delegate object for a delegated extension property:
/// run the delegate thunk once and cache the result as a hidden global
/// keyed by the declaring receiver + property name.
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

/// Probe the owner-qualified extension-prop keys (`"<Owner>\x00<recv>"`)
/// for one class on the lexical receiver tower.
pub fn ownerKeyedForClass(cls: ObjRef(runtime.ClassDef), map: anytype, recv_key: []const u8, name: []const u8) ?FuncId {
    // Probe the WHOLE resolved parent chain, not one supertype level: a
    // coroutine instance's class is several classes below JobSupport, and a
    // member extension declared there is in scope for every subclass body.
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
        // A key longer than the inline buffer is vanishingly rare but must
        // still resolve — the probe decides which declaration binds.
        const heap = std.heap.page_allocator;
        const okey = std.fmt.allocPrint(heap, "{s}\x00{s}", .{ owner, recv_key }) catch return null;
        defer heap.free(okey);
        return lookupPairFunc(map, okey, name);
    }
}

/// Probe the owner-qualified extension-prop keys (`"<Owner>\x00<recv>"`)
/// for every class on the lexical receiver tower — a PRIVATE member-ext
/// property (`private val Placeable.mainAxisSize` in each lazy item type)
/// shares its (receiver, name) pair across owners, and only the
/// declaration whose owner is in scope is the one kotlinc bound.
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
    // The bare member-extension call arm passes its DISPATCH OWNER by
    // pushing it on the enclosing chain, never as a frame `this` — inside
    // `MeasureScope.measure` reached via `with(node) { measure(...) }`,
    // the node (which owns `private val Density.targetConstraints`) is
    // only there. Probe those receivers with the same memo.
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

/// A member-extension property declared by a `by`-delegate of the receiver
/// (`class Test : IFoo by impl`, `impl` overriding `val S.extVal`) is in
/// scope through the wrapper. The delegate's runtime class can differ per
/// instance, so this probe is never memoized by the wrapper's class.
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

/// An IMPORTED companion/member extension property (`import
/// kotlin.time.Duration.Companion.seconds`) is in scope in its importing
/// file without the owner on the receiver tower. Probe the owner-keyed
/// entries named by the executing frame's file imports: the import's fqn
/// minus its leaf IS the declaring owner the registration keyed.
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
    // A class-value receiver (`X.name`) matches only a companion extension
    // (`val X.Companion.name`, keyed `X.Companion`), never a plain type
    // extension `val X.name` (which applies to instances of `X`). Falling back
    // to the bare `X` key would invoke an instance extension's getter with the
    // class/companion as `this` and recurse.
    if (receiver.* == .Class) {
        const comp_key = try std.fmt.allocPrint(allocator, "{s}.Companion", .{recv_simple});
        defer allocator.free(comp_key);
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (lookupPairFunc(Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
        // A PRIVATE member extension on the companion registers ONLY under
        // the owner-qualified key, so the plain pair above cannot see it:
        // `class H { private val Float.Companion.p get() = … }` is reached
        // from `Float.p` through these two.
        if (pg.get().owner_keyed_ext_names.contains(name)) {
            if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
            if (importOwnedExtProp(self, Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
        }
        // A class value IS a `KClass`: a `val KClass<*>.x` extension applies
        // to it directly (`qualifiedOrSimpleName` behind `KClass.cast`'s
        // error message). The getter runs with the class value as `this`,
        // never the companion.
        if (lookupPairFunc(Pick.map(pg.get().*), "KClass", name)) |fid| return fid;
        if (lookupPairFunc(Pick.map(pg.get().*), "Any", name)) |fid| return fid;
        return null;
    }
    // A null receiver dispatches an extension property declared on a NULLABLE
    // receiver type (`val RowColumnParentData?.weight get() = this?.weight ?:
    // 0f`) — kotlinc resolves that statically, so `parentData.weight` with a
    // null parentData runs the getter, never a field read. Only an
    // unambiguous single declaration binds by bare name.
    if (receiver.* == .Null and !setters) {
        const pg = self.prog.borrow();
        defer pg.deinit();
        // The executing frame's package first: same-name nullable
        // extension properties in different packages blank the bare-name
        // entry, but internal visibility means the reading code sits in
        // the declaring package.
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
        // A companion-object receiver arrives under its MANGLED runtime class
        // name (`Target$Companion$Companion`); extension properties on a
        // companion are registered under the SOURCE-WRITTEN receiver type
        // (`Target.Companion`). Every lookup below has to try both, or a
        // companion extension is unreachable from a companion instance.
        var comp_alias_buf: [256]u8 = undefined;
        const comp_alias: ?[]const u8 = blk: {
            const at = std.mem.indexOf(u8, recv_simple, "$Companion") orelse break :blk null;
            if (at == 0) break :blk null;
            break :blk std.fmt.bufPrint(&comp_alias_buf, "{s}.Companion", .{recv_simple[0..at]}) catch null;
        };

        if (pg.get().owner_keyed_ext_names.contains(name)) {
            if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), recv_simple, name)) |fid| return fid;
            if (importOwnedExtProp(self, Pick.map(pg.get().*), recv_simple, name)) |fid| return fid;
            // A PRIVATE member extension registers ONLY under the
            // owner-qualified key, so the companion alias must be tried here
            // too — this is the arm that resolves
            // `class H { private val T.Companion.p get() = … }`.
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
        // A file-mangled class (`KeyInfo$f352`, one of two same-simple-name
        // internal classes) registers its extension properties under the
        // SOURCE-WRITTEN receiver name: retry with the base name.
        if (std.mem.indexOf(u8, recv_simple, "$f")) |dol| {
            if (dol > 0 and dol + 2 < recv_simple.len and
                std.ascii.isDigit(recv_simple[dol + 2]))
            {
                if (lookupPairFunc(Pick.map(pg.get().*), recv_simple[0..dol], name)) |fid| return fid;
            }
        }
    }
    // A builtin scalar receiver has builtin supertypes: `val Number.half`
    // applies to an `Int`, `val CharSequence.n` to a `String`.
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
    // An extension property on a supertype applies to a subtype receiver.
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
    // A `Type.Companion` extension property registers under `<outer>.Companion`;
    // a companion-instance receiver (the synthetic `$Companion` class) keys the
    // lookup by its outer class's companion path.
    if (receiver.* == .Instance) {
        const cls = className(receiver.Instance);
        if (std.mem.indexOf(u8, cls, "$Companion")) |i| {
            const outer = cls[0..i];
            const comp_key = try std.fmt.allocPrint(allocator, "{s}.Companion", .{outer});
            defer allocator.free(comp_key);
            const pg = self.prog.borrow();
            defer pg.deinit();
            if (lookupPairFunc(Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
        }
    }
    // An `Any` extension property applies to every receiver — including an
    // owner-gated member extension (`private val Any?.exceptionOrNull` in
    // JobSupport) whose registration recv key is "Any" while the receiver's
    // own head is anything at all; the tower probe above only tried that
    // head.
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

/// Resolve a field on an `Value::Instance` receiver: delegate getValue,
/// custom getter (with override rules), raw slot (lateinit / built-in
/// delegate auto-unwrap), companion/parent walk, outer-chain, enum
/// entries, nested classes, globals.
/// A member of the DECLARING class of the member-extension the innermost frame is
/// executing, read off the instance that made the extension visible.
///
/// `fun Dp.toPx(): Float = value * density` is declared inside `interface Density`:
/// `this` is the `Dp`, and `density` is a member of the enclosing `Density`. That
/// enclosing receiver is in scope for the body and OUTRANKS a top-level name, so
/// both global fallbacks below consult it first. Without this, a `density` reachable
/// as a global -- a lambda's captured parameter, materialised into the global env
/// when the lambda runs as a real closure -- answered the read, and `Dp.toPx` inside
/// `with(density) { size.toPx() }` multiplied by the Density OBJECT instead of its
/// `density: Float`. The probe is member-only, so it cannot recurse back into the
/// global tiers.
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

/// Whether the instance's RUNTIME class chain declares `name` as a
/// `by`-delegated body property. Local classes register at runtime and never
/// reach the module registry's `delegated_body_props`, so the classdef chain
/// is the authority for them.
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

/// Whether (class, prop) is a registered `by`-delegated body property. The
/// registry keys packaged classes by FQN (a bare simple-name alias let a
/// foreign namesake intercept an unrelated class's field), so a simple-name
/// hop also consults the class-index FQN.
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
