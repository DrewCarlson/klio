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

// -------------------------------------------------------------------------
// `hostHasMember`.
// -------------------------------------------------------------------------

/// One remembered `name slice -> canonical string` mapping. The canonical
/// string is program-lifetime, so `canon` stays valid; `src` is only a hint
/// and every hit is confirmed by comparing bytes, which keeps the entry sound
/// even if a transient string is freed and its address reused.
pub const NameIdSlot = struct { src: usize = 0, gen: u32 = 0, canon: []const u8 = &.{} };
pub threadlocal var name_id_cache: [8192]NameIdSlot = @splat(.{});

/// Canonical pointer identity for a dispatch-cache method name. Runtime
/// callable references carry collected String storage, so their raw byte
/// address must never enter a program-lifetime cache key.
///
/// Almost every caller passes a name slice straight out of the IR, whose
/// address is stable for the life of the program — so the mapping is
/// remembered per source address (multiplicatively mixed: arena-allocated
/// name storage repeats at fixed strides, which a modulo of the raw
/// address turned into constant slot ping-pong) and confirmed with a byte
/// compare, which takes the interning hash + shared-map probe off the
/// dispatch path. A miss probes the intern under the SHARED borrow first;
/// only a genuinely new spelling takes the exclusive insert path.
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
    // A CLASS receiver's members live on its companion (or object
    // singleton): `X.serializer()` is a member call there, never a call of
    // some same-named local value.
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
    // The arg-type signature keys the entry: a global miss on `f(String)` must
    // not skip the member dispatch of a sibling `f(Int)`. A non-primitive arg
    // yields no signature, so such a call is never cached.
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

/// True when this `(enclosing func, receiver class, name, arg-sig)` was recorded
/// as resolving to a global — the member-dispatch passes can be skipped.
pub fn cmgGlobalSkip(self: *VmHost, func_p: usize, receiver: *const Value, name: []const u8, args: []const Value) bool {
    const key = cmgGlobalKey(self, receiver, func_p, name, args) orelse return false;
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().cmg_global_cache.contains(key);
}

/// Record that this call resolved to a global with a single implicit-receiver
/// candidate, so a repeat skips the member passes.
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
                // Only `val`/`var` ctor params (`property != null`) become
                // accessible members; a plain ctor parameter is local to the
                // initializer and is not a member of instances.
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

/// Does the receiver's class hierarchy declare a *property* (primary-ctor
/// property or body property) named `name`? The bare-name write resolver
/// gates on this rather than `hostHasMember`: a Kotlin assignment LHS can
/// only resolve to a property or variable, never to a function, so a
/// method of this name must not capture the write.
pub fn hostHasProperty(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    const inst = switch (receiver.*) {
        .Instance => |inst| inst,
        else => return false,
    };
    const a = self.allocator;
    var cls_name: []const u8 = undefined;
    {
        const g = inst.borrow();
        // A property already materialized on the instance (default-initialized
        // at construction) counts — covers pack/IR-backed classes whose defs
        // aren't in the tree-walker class registry walked below (e.g. a
        // builder receiver like `HexFormat.Builder`'s `upperCase`).
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
                // Only `val`/`var` ctor params are properties; a plain ctor
                // parameter (`property == null`) is not.
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

/// The companion-object singleton serving as an implicit receiver at this
/// instance's class depth, when the class (or a supertype) declares a
/// companion that owns a member named `name`. Kotlin puts a class's
/// companion in scope inside the class's own members — below the instance
/// receiver, above the next receiver out — so the bare-name resolver adds
/// it as a candidate right after the dispatch receiver. The singleton is
/// only materialised when its class really owns the member, so candidate
/// enumeration for unrelated names stays side-effect free.
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
    // The ordered ancestor-companion list is a pure function of the class
    // (supertype graph + lexical enclosing chain + companion registry, all
    // static); the walk that produced it per call was the dominant cost of
    // every bare-name candidate build. Only the per-NAME membership check
    // below stays dynamic. Most classes cache the empty list and return in
    // two probes.
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

/// Probe the ordered ancestor-companion list for a singleton owning `name`.
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

/// The BFS `companionWithMember` ran per call, producing the visit-ordered
/// companion-singleton names of the class's ancestors (supertype graph +
/// lexical enclosing classes).
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
        // An enclosing `object` declaration reached through the lexical
        // walk is itself a singleton in scope for the nested class's bodies.
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
        // A nested class reaches the lexically ENCLOSING declaration's
        // companion (AbstractList.ListIteratorImpl's init calls
        // checkPositionIndex on AbstractList's companion) and an enclosing
        // object's members. The runtime name carries the owner for a
        // dotted or mangled nested name; a simple name resolves its owner
        // through the registry's enclosing-class map.
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

/// Whether `name` is a registered `object` declaration (not an anonymous
/// object's synthetic class).
pub fn classIsObjectDecl(self: *VmHost, name: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    return dg.get().is_object and !dg.get().is_anonymous;
}

// -------------------------------------------------------------------------
// Enclosing-this stack accessors.
// -------------------------------------------------------------------------

// The enclosing-`this` chain is the *current eval frame's* live state
// (`Frame.enclosing_this`), snapshotted into `FrameSnapshot` on suspend and
// restored on resume, so it travels with a parked continuation instead of
// living in process-global state. These thin wrappers delegate to the
// frame-scoped primitives in `ir.eval`; a push made by member dispatch just
// before invoking a callable is inherited by the invoked frame and removed by
// the matching pop once the call returns.

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

/// `pushAccessEnclosing` for a receiver-lambda subject; see
/// `pushOuterSubject`.
pub fn pushAccessEnclosingSubject(self: *VmHost, v: *const Value) void {
    _ = self;
    ir.eval.pushEnclosingSubject(v);
}

pub fn popAccessEnclosing(self: *VmHost) void {
    _ = self;
    ir.eval.popEnclosing();
}

/// Push/pop the enclosing-`this` chain without a `VmHost` handle. Used by the
/// intrinsic-host receiver-lambda dispatch, which displaces a lambda's
/// captured `this` with an explicit receiver and must keep the displaced
/// instance reachable as an outer implicit receiver for the lambda body.
pub fn pushOuterThis(allocator: Allocator, v: *const Value) void {
    _ = allocator;
    ir.eval.pushEnclosing(v);
}

/// Push a receiver-lambda subject (`with(x) { … }`'s `x`). Tagged so
/// inner-class outer selection knows the subject's own `outer` links are not
/// receivers in scope inside the lambda body; bare-name resolution treats it
/// like any other enclosing receiver.
pub fn pushOuterSubject(allocator: Allocator, v: *const Value) void {
    _ = allocator;
    ir.eval.pushEnclosingSubject(v);
}

pub fn popOuterThis() void {
    ir.eval.popEnclosing();
}
