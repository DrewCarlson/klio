//! Shared instance-construction pieces: the constructor guard, argument-head
//! hints, the enum-entry preset, and the anonymous-object site caches.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const stdlib = @import("stdlib");

const root = @import("../../interp_ir.zig");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const host_classes = @import("../host_classes.zig");
const host_call_func = @import("../host_call_func.zig");
const host_call_member = @import("../host_call_member.zig");
const host_fields = @import("../host_fields.zig");
const host_call_value = @import("../host_call_value.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const build = @import("../../build.zig");
const FF = runtime.forest.ForestField;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ClassDef = runtime.ClassDef;
const Env = runtime.Env;
const PropertyDef = runtime.PropertyDef;
const MethodDef = runtime.MethodDef;
const SupertypeDelegate = runtime.SupertypeDelegate;
const TypeShape = runtime.TypeShape;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;
const Module = ir.Module;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const StrPair = ir.StrPair;
const StringSet = std.StringHashMap(void);
const AnonMethodEntry = root.AnonMethodEntry;
const NameValue = root.NameValue;

pub fn unsupported(name: []const u8) EvalResult {
    return .{ .err = .{ .Unsupported = name } };
}

pub fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalError {
    return .{ .Type = try std.fmt.allocPrint(allocator, fmt, args) };
}

// Breaks same-class shell recursion during secondary-ctor dispatch; lazy
// `object` re-entrancy uses the object-init state table in `host_globals.zig`.

pub threadlocal var ctor_guard: std.ArrayList([]const u8) = .empty;

/// `name`/`ordinal` for the enum-entry subclass about to be constructed;
/// Kotlin's `Enum` constructor sets them before the entry's own initializers
/// and `init` blocks run. Materialization consumes it once and fills `slot`.
pub const EnumEntryPreset = struct { class_fqn: []const u8, name: Value, ordinal: Value, slot: ?*Value = null };

pub threadlocal var enum_entry_preset: ?EnumEntryPreset = null;

/// The enum whose entries are being constructed: its companion initializes
/// only after every entry exists, so the first entry must not trigger it.
pub threadlocal var enum_under_init: ?[]const u8 = null;

pub fn setEnumUnderInit(fqn: ?[]const u8) ?[]const u8 {
    const prev = enum_under_init;
    enum_under_init = fqn;
    return prev;
}

pub fn setEnumEntryPreset(p: ?EnumEntryPreset) void {
    enum_entry_preset = p;
}

pub fn resetReceiverTls() void {
    std.debug.assert(ctor_guard.items.len == 0);
    ctor_guard.clearRetainingCapacity();
}

pub fn ctorGuardContains(name: []const u8) bool {
    for (ctor_guard.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

pub fn ctorGuardPush(name: []const u8) void {
    ctor_guard.append(std.heap.page_allocator, name) catch {};
}

pub fn ctorGuardPop() void {
    _ = ctor_guard.pop();
}

/// Static argument heads the current construction site supplied, consumed once:
/// a delegation or default thunk builds further instances and ranks on its own.
pub threadlocal var ctor_static_heads: ?[]const ?[]const u8 = null;

/// Heads live in a thread-owned buffer: the array a site hands over is freed
/// when the site returns. A site with more arguments ranks without static heads.
pub const CTOR_HEADS_MAX = 32;

pub threadlocal var ctor_static_heads_buf: [CTOR_HEADS_MAX]?[]const u8 = undefined;

pub fn setCtorArgStaticHeads(self: *VmHost, heads: []const ?[]const u8) void {
    _ = self;
    if (heads.len == 0 or heads.len > CTOR_HEADS_MAX) {
        ctor_static_heads = null;
        return;
    }
    @memcpy(ctor_static_heads_buf[0..heads.len], heads);
    ctor_static_heads = ctor_static_heads_buf[0..heads.len];
}

/// Forget heads left installed by a path that never took them: the slice they
/// name is freed when the site returns.
pub fn clearCtorArgStaticHeads(self: *VmHost) void {
    _ = self;
    ctor_static_heads = null;
}

/// Type-parameter bounds of the class under construction, so a constructor
/// parameter declared as a class type parameter ranks as its bound.
pub const CtorBounds = struct { names: []const []const u8, bounds: []const []const u8 };

pub threadlocal var ctor_bounds: ?CtorBounds = null;

pub fn installCtorBounds(class_def: ObjRef(ClassDef)) ?CtorBounds {
    const prev = ctor_bounds;
    const g = class_def.borrow();
    defer g.deinit();
    const d = g.get();
    ctor_bounds = if (d.type_params.len != 0 and d.type_param_bounds.len != 0)
        .{ .names = d.type_params, .bounds = d.type_param_bounds }
    else
        null;
    return prev;
}

/// `declared` with a class type parameter replaced by the head of its bound.
pub fn boundHead(declared: []const u8) []const u8 {
    const cb = ctor_bounds orelse return declared;
    for (cb.names, 0..) |n, i| {
        if (i >= cb.bounds.len) break;
        if (std.mem.eql(u8, n, declared) and cb.bounds[i].len != 0) return cb.bounds[i];
    }
    return declared;
}

pub fn takeCtorStaticHeads() ?[]const ?[]const u8 {
    const v = ctor_static_heads;
    ctor_static_heads = null;
    return v;
}

/// Stable synthetic class name per anonymous-object expression, keyed by AST
/// node address; page-allocated and permanent, bounding the registries by site.
pub var anon_site_names: std.AutoHashMapUnmanaged(usize, []const u8) = .empty;

pub var anon_site_lock: runtime.SpinMutex = .{};

pub fn anonSiteName(expr: *const ast.Expr) []const u8 {
    const key = @intFromPtr(expr);
    anon_site_lock.lock();
    defer anon_site_lock.unlock();
    if (anon_site_names.get(key)) |n| return n;
    const n = anon_site_names.count();
    const name = std.fmt.allocPrint(std.heap.page_allocator, "$anon${d}", .{n}) catch return "$anon$x";
    anon_site_names.put(std.heap.page_allocator, key, name) catch {};
    return name;
}

/// Side-module lowerings of an `object` literal's initializers; pure functions
/// of the AST site, so each site is lowered once and cached by its address.
pub const AnonComplexInit = struct { name: []const u8, module: ObjRef(Module), func: FuncId };

pub const AnonInitThunk = struct { module: ObjRef(Module), func: FuncId, prop_pos: usize };

pub const AnonSuperArgThunk = struct { module: ObjRef(Module), func: FuncId };

/// One `object : Iface by <expr> {}` delegate initializer, parallel to the
/// site's supertype list; null when no delegate or a captured name serves it.
pub const AnonDelegateThunk = struct { module: ObjRef(Module), func: FuncId };

pub const AnonSiteThunks = struct {
    complex_prop_inits: []const AnonComplexInit,
    init_thunks: []const AnonInitThunk,
    super_arg_thunks: []const []const ?AnonSuperArgThunk,
    delegate_thunks: []const ?AnonDelegateThunk = &.{},
};

pub var anon_site_thunks: std.AutoHashMapUnmanaged(usize, AnonSiteThunks) = .empty;

pub var anon_site_thunks_root_registered = std.atomic.Value(bool).init(false);

/// GC root: shade every cached anon-site thunk module so reused lowered IR is
/// never swept. Lockless: neither `get` nor `put` spans a safe point.
pub fn gcMarkAnonSites(m: *runtime.gc.Marker) void {
    var it = anon_site_thunks.valueIterator();
    while (it.next()) |t| {
        for (t.complex_prop_inits) |c| m.shade(&c.module.cell.hdr);
        for (t.init_thunks) |i| m.shade(&i.module.cell.hdr);
        for (t.super_arg_thunks) |slots| {
            for (slots) |s| if (s) |th| m.shade(&th.module.cell.hdr);
        }
        for (t.delegate_thunks) |s| if (s) |th| m.shade(&th.module.cell.hdr);
    }
}

pub fn anonSiteThunksGet(key: usize) ?AnonSiteThunks {
    anon_site_lock.lock();
    defer anon_site_lock.unlock();
    return anon_site_thunks.get(key);
}

/// Drop the anon-`object` site caches at a run boundary: keyed by AST address,
/// which a later run can reuse, so a stale entry names a dead thunk module.
pub fn resetAnonSiteCache() void {
    const pa = std.heap.page_allocator;
    anon_site_lock.lock();
    defer anon_site_lock.unlock();
    {
        var it = anon_site_names.valueIterator();
        while (it.next()) |n| pa.free(n.*);
        anon_site_names.clearAndFree(pa);
    }
    {
        var it = anon_site_thunks.valueIterator();
        while (it.next()) |t| {
            if (t.complex_prop_inits.len != 0) pa.free(t.complex_prop_inits);
            if (t.init_thunks.len != 0) pa.free(t.init_thunks);
            for (t.super_arg_thunks) |slots| if (slots.len != 0) pa.free(slots);
            if (t.super_arg_thunks.len != 0) pa.free(t.super_arg_thunks);
            if (t.delegate_thunks.len != 0) pa.free(t.delegate_thunks);
        }
        anon_site_thunks.clearAndFree(pa);
    }
    // The shared side-module clone must not cross a program boundary: its
    // identity gate compares run-module cell addresses, which get reused.
    if (shared_anon_module != null) {
        runtime.gc.forgetCell(&shared_anon_module.?.cell.hdr);
        shared_anon_module = null;
        if (shared_anon_arena) |holder| {
            holder.deinit();
            std.heap.page_allocator.destroy(holder);
            shared_anon_arena = null;
        }
    }
}

/// Publish a site's thunks, first publisher wins; the loser's modules are left
/// unrooted for the GC. Returns the entry now in the cache.
pub fn anonSiteThunksPut(key: usize, entry: AnonSiteThunks) AnonSiteThunks {
    anon_site_lock.lock();
    defer anon_site_lock.unlock();
    if (anon_site_thunks.get(key)) |existing| return existing;
    anon_site_thunks.put(std.heap.page_allocator, key, entry) catch return entry;
    return entry;
}

/// The side module a runtime-synthesized class's members lower into: one
/// process-wide `cloneForExtend` of the main module, so member bodies resolve
/// and bind statically as build-time lowering would. Appends serialize under
/// `anonLowerEnter`/`anonLowerExit`, held around lowering, never around a thunk.
pub var shared_anon_module: ?ObjRef(Module) = null;

pub var shared_anon_arena: ?*std.heap.ArenaAllocator = null;

/// Cell identity of the run module `shared_anon_module` was cloned from; a
/// mismatch re-clones, since the clone's shallow-shared tables would dangle.
pub var shared_anon_base_identity: usize = 0;

pub var anon_lower_mutex: runtime.SpinMutex = .{};

pub var anon_lower_owner: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub var anon_lower_depth: usize = 0;

pub fn anonLowerEnter() void {
    const me: u64 = @as(u64, @intCast(std.Thread.getCurrentId())) +% 1;
    if (anon_lower_owner.load(.acquire) == me) {
        anon_lower_depth += 1;
        return;
    }
    anon_lower_mutex.lock();
    anon_lower_owner.store(me, .release);
    anon_lower_depth = 1;
}

pub fn anonLowerExit() void {
    anon_lower_depth -= 1;
    if (anon_lower_depth == 0) {
        anon_lower_owner.store(0, .release);
        anon_lower_mutex.unlock();
    }
}

/// Caller must hold the anon-lower lock across this call AND every
/// `lowerMethod` into the returned module.
pub fn anonSiteModule(self: *VmHost, allocator: Allocator, cache: *?ObjRef(Module)) Allocator.Error!ObjRef(Module) {
    if (cache.*) |m| return m.clone();
    // `KLIO_ANON_BASE=0` selects an empty side module, leaving bodies dynamic.
    if (std.mem.eql(u8, runtime.envOnce("KLIO_ANON_BASE") orelse "1", "0")) {
        return ObjRef(Module).init(allocator, Module.default(allocator));
    }
    if (shared_anon_module != null and shared_anon_base_identity != self.module.identity()) {
        // `Module.deinit` cannot free a `cloneForExtend` product, which borrows
        // base buffers, so the clone owns an arena dropped wholesale here.
        runtime.gc.forgetCell(&shared_anon_module.?.cell.hdr);
        shared_anon_module = null;
        if (shared_anon_arena) |holder| {
            holder.deinit();
            std.heap.page_allocator.destroy(holder);
            shared_anon_arena = null;
        }
    }
    if (shared_anon_module == null) {
        shared_anon_base_identity = self.module.identity();
        const mg = self.module.borrow();
        defer mg.deinit();
        // The side module owns a real allocator, never the run arena: lowering
        // scratch rents from `module.registry.allocator` and frees on exit.
        const holder = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
        holder.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        shared_anon_arena = holder;
        var cloned = try mg.get().cloneForExtend(holder.allocator());
        cloned.anon_side = true;
        // Every anon site lowers into this one module while earlier sites'
        // bodies run in it: a growing func table must not move their funcs.
        cloned.funcs_live = true;
        // Permanent cell, never on the program-perm list: this cache outlives
        // programs and the identity swap above is its sole owner.
        const saved_perm = runtime.gc.alloc_perm;
        const saved_ppc = runtime.gc.program_perm_collect;
        runtime.gc.alloc_perm = true;
        runtime.gc.program_perm_collect = false;
        shared_anon_module = try ObjRef(Module).init(holder.allocator(), cloned);
        runtime.gc.program_perm_collect = saved_ppc;
        runtime.gc.alloc_perm = saved_perm;
    }
    const ref = shared_anon_module.?.clone();
    cache.* = ref.clone();
    return ref;
}
