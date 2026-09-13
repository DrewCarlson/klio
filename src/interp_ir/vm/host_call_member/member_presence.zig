//! Member presence: `hostHasMember` / `hostHasProperty`, the companion-chain probe
//! behind them, and the enclosing-`this` stack accessors.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const VmHost = vmhost.VmHost;
const host_fields = @import("../host_fields.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;

const hcm = @import("../host_call_member.zig");
const cacheGen = hcm.cacheGen;
const simpleName = hcm.simpleName;

const reflect_anon = @import("reflect_anon.zig");
const root_mod = reflect_anon.root_mod;

const virtual_tail = @import("virtual_tail.zig");
const methodArgSig = virtual_tail.methodArgSig;

/// One remembered `name slice -> canonical string` mapping. The canonical string is
/// program-lifetime; `src` is a hint, and every hit is byte-compared before it is used.
pub const NameIdSlot = struct { src: usize = 0, gen: u32 = 0, canon: []const u8 = &.{} };
pub threadlocal var name_id_cache: [8192]NameIdSlot = @splat(.{});

/// Canonical pointer identity for a dispatch-cache method name. Runtime callable
/// references carry collected String storage, so a raw byte address must never enter a
/// program-lifetime key; the mapping is per source address, confirmed by byte compare.
pub fn memberNameIdentity(self: *VmHost, name: []const u8) ?usize {
    const src = @intFromPtr(name.ptr);
    const slot = &name_id_cache[((src *% 0x9E3779B97F4A7C15) >> 32) % name_id_cache.len];
    if (slot.src == src and slot.gen == cacheGen() and slot.canon.len == name.len and std.mem.eql(u8, slot.canon, name)) {
        return @intFromPtr(slot.canon.ptr);
    }
    const id = blk: {
        {
            const pg = self.prog.borrow();
            defer pg.deinit();
            if (pg.get().memberNameIdentityExisting(name)) |id| break :blk id;
        }
        const pg = self.prog.borrowMut();
        defer pg.deinit();
        break :blk pg.get().memberNameIdentity(name) orelse return null;
    };
    slot.* = .{ .src = src, .gen = cacheGen(), .canon = @as([*]const u8, @ptrFromInt(id))[0..name.len] };
    return id;
}

pub fn hostHasMember(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    // A class receiver's members live on its companion or object singleton:
    // `X.serializer()` is a member call there, never a call of a same-named local.
    if (receiver.* == .Class) {
        const comp = (host_fields.companionOfClassValue(self, receiver) catch null) orelse return false;
        if (comp == .Null) return false;
        return hostHasMember(self, &comp, name);
    }
    if (receiver.* != .Instance) return false;
    const name_p = memberNameIdentity(self, name) orelse return hostHasMemberUncached(self, receiver, name);
    const key: root_mod.ProgramImage.MemberHasKey = .{
        .class_p = blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            break :blk g.get().class.identity();
        },
        .name_p = name_p,
    };
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (pg.get().host_has_member_cache.get(key)) |v| return v;
    }
    const result = hostHasMemberUncached(self, receiver, name);
    {
        const pg = self.prog.borrowMut();
        defer pg.deinit();
        pg.get().host_has_member_cache.put(key, result) catch {};
    }
    return result;
}

pub fn cmgGlobalKey(self: *VmHost, receiver: *const Value, func_p: usize, name: []const u8, args: []const Value) ?root_mod.ProgramImage.CmgGlobalKey {
    if (receiver.* != .Instance) return null;
    // The arg-type signature keys the entry: a global miss on `f(String)` must not
    // skip the member dispatch of a sibling `f(Int)`. No signature, no caching.
    const sig = methodArgSig(self, args) orelse return null;
    const g = receiver.Instance.borrow();
    defer g.deinit();
    const name_p = memberNameIdentity(self, name) orelse return null;
    return .{
        .func_p = func_p,
        .class_p = g.get().class.identity(),
        .name_p = name_p,
        .sig = sig,
    };
}

pub fn cmgGlobalSkip(self: *VmHost, func_p: usize, receiver: *const Value, name: []const u8, args: []const Value) bool {
    const key = cmgGlobalKey(self, receiver, func_p, name, args) orelse return false;
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().cmg_global_cache.contains(key);
}

/// Record that this call resolved to a global with a single implicit-receiver candidate.
pub fn cmgGlobalRecord(self: *VmHost, func_p: usize, receiver: *const Value, name: []const u8, args: []const Value) void {
    if (!ir.eval.dispatchCacheStable()) return;
    const key = cmgGlobalKey(self, receiver, func_p, name, args) orelse return;
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().cmg_global_cache.put(key, {}) catch {};
}

pub fn hostHasMemberUncached(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    const inst = switch (receiver.*) {
        .Instance => |inst| inst,
        else => return false,
    };
    const a = self.allocator;
    var cls_name: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        cls_name = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.hierarchy_methods.get(cls_name)) |m| {
            if (m.contains(name)) return true;
        }
    }
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    queue.append(a, cls_name) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch {};
        const cg = self.classes.borrow();
        if (cg.get().get(cur)) |def| {
            const dg = def.borrow();
            const d = dg.get();
            for (d.methods) |m| {
                if (std.mem.eql(u8, m.name, name) or std.mem.eql(u8, simpleName(m.name), name)) {
                    dg.deinit();
                    cg.deinit();
                    return true;
                }
            }
            for (d.primary_params) |p| {
                // Only `val`/`var` ctor params become members.
                if (p.property != null and std.mem.eql(u8, p.name, name)) {
                    dg.deinit();
                    cg.deinit();
                    return true;
                }
            }
            for (d.body_properties) |p| {
                if (std.mem.eql(u8, p.name, name)) {
                    dg.deinit();
                    cg.deinit();
                    return true;
                }
            }
            for (d.supertype_names) |sn| queue.append(a, sn) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

/// Whether the receiver's hierarchy declares a property named `name`. A Kotlin
/// assignment LHS resolves only to a property or variable, never to a function.
pub fn hostHasProperty(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    const inst = switch (receiver.*) {
        .Instance => |inst| inst,
        else => return false,
    };
    const a = self.allocator;
    var cls_name: []const u8 = undefined;
    {
        const g = inst.borrow();
        // A property already materialized on the instance counts: pack/IR-backed
        // classes have no def in the registry walked below.
        if (g.get().get(name) != null) {
            g.deinit();
            return true;
        }
        const cg = g.get().class.borrow();
        cls_name = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    queue.append(a, cls_name) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch {};
        const cg = self.classes.borrow();
        if (cg.get().get(cur)) |def| {
            const dg = def.borrow();
            const d = dg.get();
            for (d.primary_params) |p| {
                // Only `val`/`var` ctor params are properties.
                if (p.property != null and std.mem.eql(u8, p.name, name)) {
                    dg.deinit();
                    cg.deinit();
                    return true;
                }
            }
            for (d.body_properties) |p| {
                if (std.mem.eql(u8, p.name, name)) {
                    dg.deinit();
                    cg.deinit();
                    return true;
                }
            }
            for (d.supertype_names) |sn| queue.append(a, sn) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

/// The companion-object singleton serving as an implicit receiver at this instance's
/// class depth. Kotlin scopes a class's companion inside the class's own members,
/// below the instance receiver and above the next receiver out.
pub fn companionWithMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?Value {
    const inst = switch (receiver.*) {
        .Instance => |inst| inst,
        else => return null,
    };
    var cls_name: []const u8 = undefined;
    var cls_ident: usize = 0;
    {
        const g = inst.borrow();
        cls_ident = g.get().class.identity();
        const cg = g.get().class.borrow();
        cls_name = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    if (std.mem.find(u8, cls_name, "$Companion$") != null) return null;
    // The ordered ancestor-companion list is a pure function of the class, so it caches
    // per class identity; only the per-name membership check below stays dynamic.
    const cached: ?[]const []const u8 = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().companion_chain_cache.get(cls_ident);
    };
    if (cached) |chain| return companionChainProbe(self, chain, name);
    var built = try companionChainBuild(self, allocator, cls_name);
    defer built.deinit(allocator);
    {
        const pg = self.prog.borrowMut();
        defer pg.deinit();
        const cache = &pg.get().companion_chain_cache;
        if (!cache.contains(cls_ident)) {
            if (pg.get().allocator.dupe([]const u8, built.items) catch null) |owned| {
                cache.put(cls_ident, owned) catch pg.get().allocator.free(owned);
            }
        }
    }
    return companionChainProbe(self, built.items, name);
}

pub fn companionChainProbe(self: *VmHost, chain: []const []const u8, name: []const u8) Allocator.Error!?Value {
    for (chain) |cn| {
        const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
            .ok => |maybe| maybe,
            .err => return null,
        };
        if (singleton) |sv| {
            if (sv == .Instance) return sv;
        }
    }
    return null;
}

/// Visit-ordered companion-singleton names of the class's ancestors.
pub fn companionChainBuild(self: *VmHost, allocator: Allocator, cls_name: []const u8) Allocator.Error!std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);
    try queue.append(allocator, cls_name);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cname = queue.items[head];
        var already = false;
        for (seen.items) |sname| {
            if (std.mem.eql(u8, sname, cname)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        try seen.append(allocator, cname);
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cname);
        };
        if (comp_name) |cn| try out.append(allocator, cn);
        // An enclosing `object` declaration is itself a singleton in scope here.
        if (head != 0 and classIsObjectDecl(self, cname)) try out.append(allocator, cname);
        {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(cname)) |def| {
                const dg = def.borrow();
                defer dg.deinit();
                for (dg.get().supertype_names) |sn| try queue.append(allocator, sn);
            }
        }
        // A nested class reaches the enclosing declaration's companion: a dotted or
        // mangled name carries its owner, a simple name resolves through the registry.
        const enclosing: ?[]const u8 = blk: {
            if (std.mem.findLastAny(u8, cname, ".$")) |sep| {
                if (sep > 0) break :blk cname[0..sep];
            }
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.enclosing_class.get(cname);
        };
        if (enclosing) |enc| try queue.append(allocator, enc);
    }
    return out;
}

pub fn classIsObjectDecl(self: *VmHost, name: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    return dg.get().is_object and !dg.get().is_anonymous;
}

// The enclosing-`this` chain is the current eval frame's live state, snapshotted into
// `FrameSnapshot` on suspend and restored on resume, so it travels with a parked
// continuation. A push before a call is inherited by the invoked frame, popped after.

pub fn enclosingThis(self: *VmHost) ?Value {
    _ = self;
    return ir.eval.enclosingThisLast();
}

pub fn enclosingThisChain(self: *VmHost, allocator: Allocator) Allocator.Error![]Value {
    _ = self;
    return ir.eval.enclosingThisChainAlloc(allocator);
}

pub fn pushAccessEnclosing(self: *VmHost, v: *const Value) void {
    _ = self;
    ir.eval.pushEnclosing(v);
}

pub fn pushAccessEnclosingSubject(self: *VmHost, v: *const Value) void {
    _ = self;
    ir.eval.pushEnclosingSubject(v);
}

pub fn popAccessEnclosing(self: *VmHost) void {
    _ = self;
    ir.eval.popEnclosing();
}

/// Push/pop the enclosing-`this` chain without a `VmHost` handle: receiver-lambda
/// dispatch displaces a lambda's captured `this` and must keep it reachable as an outer
/// implicit receiver.
pub fn pushOuterThis(allocator: Allocator, v: *const Value) void {
    _ = allocator;
    ir.eval.pushEnclosing(v);
}

/// Push a receiver-lambda subject (`with(x) { … }`'s `x`). Tagged so inner-class outer
/// selection knows the subject's own `outer` links are not receivers inside the body.
pub fn pushOuterSubject(allocator: Allocator, v: *const Value) void {
    _ = allocator;
    ir.eval.pushEnclosingSubject(v);
}

pub fn popOuterThis() void {
    ir.eval.popEnclosing();
}
