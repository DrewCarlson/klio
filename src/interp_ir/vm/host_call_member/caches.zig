//! Thread-local L1 caches in front of the shared dispatch maps.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const StdlibFn = runtime.StdlibFn;
const Module = ir.Module;
const FuncId = ir.FuncId;
const MethodSlotId = ir.MethodSlotId;

const hcm = @import("../host_call_member.zig");
const cacheGen = hcm.cacheGen;

const reflect_anon = @import("reflect_anon.zig");
const root_mod = reflect_anon.root_mod;

/// Sentinel: no user instance method resolves for this (class, name, arg-sig).
pub const METHOD_MISS: u32 = std.math.maxInt(u32);

/// Thread-local L1 in front of the shared method-resolution caches. Those maps
/// are add-only, so a stale or evicted slot falls through to the shared probe.
pub const TL_METHOD_CACHE_SIZE = 2048;

pub const TlMethodEntry = struct { class_p: usize = 0, name_p: usize = 0, n_args: u32 = 0, sig: u64 = 0, raw_plus: u64 = 0, gen: u32 = 0, miss_ttl: u8 = 0 };

/// `raw_plus` sentinel: the shared map had no entry when last probed. The only
/// staleness is a later insert, so `miss_ttl` re-probes every 64th consult.
pub const TL_ABSENT: u64 = std.math.maxInt(u64);
pub threadlocal var tl_method_cache: [TL_METHOD_CACHE_SIZE]TlMethodEntry = @splat(.{});
pub threadlocal var tl_ext_cache: [TL_METHOD_CACHE_SIZE]TlMethodEntry = @splat(.{});

pub inline fn tlSlot(key: root_mod.ProgramImage.InstanceMethodKey) usize {
    const h = key.sig ^ (@as(u64, @intCast(key.class_p)) *% 0x9E3779B97F4A7C15) ^ @as(u64, @intCast(key.name_p));
    return @intCast((h ^ (h >> 17)) & (TL_METHOD_CACHE_SIZE - 1));
}

pub const TlProbe = union(enum) { hit: u32, absent, unknown };

pub inline fn tlGet(cache: *[TL_METHOD_CACHE_SIZE]TlMethodEntry, key: root_mod.ProgramImage.InstanceMethodKey) TlProbe {
    const e = &cache[tlSlot(key)];
    if (e.raw_plus != 0 and e.gen == cacheGen() and e.class_p == key.class_p and e.name_p == key.name_p and
        e.sig == key.sig and e.n_args == key.n_args)
    {
        if (e.raw_plus == TL_ABSENT) {
            if (e.miss_ttl > 0) {
                e.miss_ttl -= 1;
                return .absent;
            }
            return .unknown;
        }
        return .{ .hit = @intCast(e.raw_plus - 1) };
    }
    return .unknown;
}

pub inline fn tlPut(cache: *[TL_METHOD_CACHE_SIZE]TlMethodEntry, key: root_mod.ProgramImage.InstanceMethodKey, raw: u32) void {
    cache[tlSlot(key)] = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .raw_plus = @as(u64, raw) + 1, .gen = cacheGen() };
}

pub inline fn tlPutAbsent(cache: *[TL_METHOD_CACHE_SIZE]TlMethodEntry, key: root_mod.ProgramImage.InstanceMethodKey) void {
    cache[tlSlot(key)] = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .raw_plus = TL_ABSENT, .gen = cacheGen(), .miss_ttl = 63 };
}

pub const TlPermEntry = struct { class_p: usize = 0, name_p: usize = 0, n_args: u32 = 0, sig: u64 = 0, raw_plus: u8 = 0, gen: u32 = 0, perm: root_mod.ProgramImage.NamedPerm = .{ .n = 0xFF, .src = @splat(0xFF) } };
pub threadlocal var tl_perm_cache: [TL_METHOD_CACHE_SIZE]TlPermEntry = @splat(.{});

/// Stdlib member-resolve L1. `state`: 0 empty, 1 confirmed-none, 2 resolved.
pub const TlResolveEntry = struct { type_p: usize = 0, name_p: usize = 0, args_empty: bool = false, file: u32 = 0, argc: u32 = 0, state: u8 = 0, gen: u32 = 0, func: ?StdlibFn = null, fqn: []const u8 = "" };
pub threadlocal var tl_resolve_cache: [TL_METHOD_CACHE_SIZE]TlResolveEntry = @splat(.{});

pub inline fn tlResolveSlot(key: root_mod.ProgramImage.MemberResolveKey) usize {
    const h = (@as(u64, @intCast(key.type_p)) *% 0x9E3779B97F4A7C15) ^ @as(u64, @intCast(key.name_p)) ^ @intFromBool(key.args_empty) ^ (@as(u64, key.file) << 32) ^ (@as(u64, key.argc) << 20);
    return @intCast((h ^ (h >> 17)) & (TL_METHOD_CACHE_SIZE - 1));
}

pub inline fn tlResolveMatch(e: *const TlResolveEntry, key: root_mod.ProgramImage.MemberResolveKey) bool {
    return e.state != 0 and e.gen == cacheGen() and e.type_p == key.type_p and e.name_p == key.name_p and
        e.args_empty == key.args_empty and e.file == key.file and e.argc == key.argc;
}

pub fn tlResolveStore(key: root_mod.ProgramImage.MemberResolveKey, entry: root_mod.ProgramImage.MemberResolveEntry) void {
    tl_resolve_cache[tlResolveSlot(key)] = .{
        .type_p = key.type_p,
        .name_p = key.name_p,
        .args_empty = key.args_empty,
        .file = key.file,
        .argc = key.argc,
        .state = if (entry.func == null) 1 else 2,
        .gen = cacheGen(),
        .func = entry.func,
        .fqn = entry.fqn,
    };
}

pub fn instanceMethodCacheGetRaw(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey) ?u32 {
    switch (tlGet(&tl_method_cache, key)) {
        .hit => |raw| return raw,
        .absent => return null,
        .unknown => {},
    }
    const raw: ?u32 = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().instance_method_cache.get(key);
    };
    if (raw) |r| tlPut(&tl_method_cache, key, r) else tlPutAbsent(&tl_method_cache, key);
    return raw;
}

pub fn instanceMethodCachePutRaw(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey, raw: u32) void {
    if (!ir.eval.dispatchCacheStable()) return;
    tlPut(&tl_method_cache, key, raw);
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().instance_method_cache.put(key, raw) catch {};
}

pub fn extMethodCacheGet(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey) ?u32 {
    switch (tlGet(&tl_ext_cache, key)) {
        .hit => |raw| return raw,
        .absent => return null,
        .unknown => {},
    }
    const raw: ?u32 = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().ext_method_cache.get(key);
    };
    if (raw) |r| tlPut(&tl_ext_cache, key, r) else tlPutAbsent(&tl_ext_cache, key);
    return raw;
}

pub fn extMethodCachePut(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey, fid: u32) void {
    if (!ir.eval.dispatchCacheStable()) return;
    tlPut(&tl_ext_cache, key, fid);
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().ext_method_cache.put(key, fid) catch {};
}

/// Pack-binding inline cache L1. `state`: 0 empty, 1 mirrored, 2 known-miss.
pub const TlIntrinsicEntry = struct { class_p: usize = 0, name_p: usize = 0, n_args: u32 = 0, sig: u64 = 0, state: u8 = 0, gen: u32 = 0, miss_ttl: u8 = 0, entry: root_mod.ProgramImage.MemberResolveEntry = .{ .func = null, .fqn = "" } };
pub threadlocal var tl_intrinsic_cache: [TL_METHOD_CACHE_SIZE]TlIntrinsicEntry = @splat(.{});

pub fn instanceIntrinsicCacheGet(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey) ?root_mod.ProgramImage.MemberResolveEntry {
    const e = &tl_intrinsic_cache[tlSlot(key)];
    if (e.state != 0 and e.gen == cacheGen() and e.class_p == key.class_p and e.name_p == key.name_p and
        e.sig == key.sig and e.n_args == key.n_args)
    {
        if (e.state == 2) {
            if (e.miss_ttl > 0) {
                e.miss_ttl -= 1;
                return null;
            }
        } else return e.entry;
    }
    const hit: ?root_mod.ProgramImage.MemberResolveEntry = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().instance_intrinsic_cache.get(key);
    };
    if (hit) |h| {
        e.* = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .state = 1, .gen = cacheGen(), .entry = h };
    } else {
        e.* = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .state = 2, .gen = cacheGen(), .miss_ttl = 63, .entry = .{ .func = null, .fqn = "" } };
    }
    return hit;
}

/// Member name a virtual slot stands for, only when its root declaration belongs
/// to an interface: the one case where a delegating receiver must re-decide.
pub fn virtualSlotInterfaceMember(self: *VmHost, slot: MethodSlotId) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    const root = FuncId.from(slot.int());
    const sig = module.decl_sigs.get(root.int()) orelse return null;
    const owner = sig.enclosing_class orelse return null;
    if (owner.int() >= module.classes.items.len) return null;
    if (!module.classes.items[owner.int()].is_interface) return null;
    const f = module.funcById(root) orelse return null;
    return f.name;
}

/// As `virtualSlotInterfaceMember`, for a lowering-resolved target.
pub fn resolvedMemberName(self: *VmHost, fid: FuncId) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const owner = declaringClassSimpleName(self, mod, fid) orelse return null;
    const cid = mod.classId(owner) orelse return null;
    if (cid.int() >= mod.classes.items.len) return null;
    if (!mod.classes.items[cid.int()].is_interface) return null;
    const f = mod.funcById(fid) orelse return null;
    return f.name;
}

/// Simple name of the class declaring `fid`, memoized per `(module, FuncId)`;
/// Kotlin resolves an implicit-`this` bare call against that class's static scope.
pub fn declaringClassSimpleName(self: *VmHost, module: *const Module, fid: FuncId) ?[]const u8 {
    const key = root_mod.ProgramImage.FuncOwnerKey{ .module_p = @intFromPtr(module), .func_p = @intFromEnum(fid) };
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (pg.get().func_owner_class_cache.get(key)) |hit| return hit;
    }
    var owner: ?[]const u8 = null;
    const dcs_trace = runtime.envOnce("KLIO_DCS_TRACE") != null;
    if (dcs_trace) std.debug.print("[dcs] module={x} n_classes={d} fid={d}\n", .{ @intFromPtr(module), module.classes.items.len, @intFromEnum(fid) });
    for (module.classes.items, 0..) |*c, ci| {
        if (dcs_trace) std.debug.print("[dcs]   class[{d}] ptr={x} methods.ptr={x} methods.len={d}\n", .{ ci, @intFromPtr(c), @intFromPtr(c.methods.ptr), c.methods.len });
        for (c.methods) |mfid| {
            if (@intFromEnum(mfid) == @intFromEnum(fid)) {
                owner = c.name;
                break;
            }
        }
        if (owner != null) break;
    }
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().func_owner_class_cache.put(key, owner) catch {};
    return owner;
}

/// Memoize the `instanceBindingProbe` outcome; `func == null` caches "no
/// intrinsic". `fqn` is duped into the image-owned allocator on first store.
pub fn instanceIntrinsicCachePut(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey, func: ?StdlibFn, fqn: []const u8) void {
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    const cache = &pg.get().instance_intrinsic_cache;
    if (cache.contains(key)) return;
    const owned: []const u8 = if (fqn.len == 0) "" else (pg.get().allocator.dupe(u8, fqn) catch return);
    cache.put(key, .{ .func = func, .fqn = owned }) catch {
        if (owned.len != 0) pg.get().allocator.free(owned);
    };
}
