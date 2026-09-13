//! Shared pieces of instance construction: the two error constructors every
//! path uses, the per-thread constructor guard and argument-head hints, the
//! enum-entry preset, and the anonymous-object site caches.

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

// -------------------------------------------------------------------------
// Per-thread constructor-shell recursion guard for secondary-ctor shell
// construction. Lazy `object` re-entrancy is handled separately by the
// shared object-init state table in `host_globals.zig`; this stack only
// breaks same-class shell recursion during secondary-ctor dispatch.
// -------------------------------------------------------------------------

pub threadlocal var ctor_guard: std.ArrayList([]const u8) = .empty;

/// `name`/`ordinal` for the enum-entry subclass instance about to be
/// constructed: Kotlin's `Enum` constructor sets them before the entry's
/// own initializers and `init` blocks run (`init { println(this.name) }`
/// inside an entry body sees the name). Set by the enum's initialization,
/// consumed once by the matching class's materialization, which also
/// publishes the shell into the entry's table slot (`slot`).
pub const EnumEntryPreset = struct { class_fqn: []const u8, name: Value, ordinal: Value, slot: ?*Value = null };

pub threadlocal var enum_entry_preset: ?EnumEntryPreset = null;

/// The enum whose entries are being constructed: its companion waits until
/// every entry exists (kotlinc initializes the entries first, then the
/// companion), so the first entry's construction must not trigger it.
pub threadlocal var enum_under_init: ?[]const u8 = null;

pub fn setEnumUnderInit(fqn: ?[]const u8) ?[]const u8 {
    const prev = enum_under_init;
    enum_under_init = fqn;
    return prev;
}

pub fn setEnumEntryPreset(p: ?EnumEntryPreset) void {
    enum_entry_preset = p;
}

/// Assert (Debug) the constructor-shell guard is clear at a run boundary
/// and reset it so leaked-across-runs state is a loud failure.
pub fn resetReceiverTls() void {
    std.debug.assert(ctor_guard.items.len == 0);
    ctor_guard.clearRetainingCapacity();
}

/// True while `name`'s constructor shell is being built on this thread.
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

/// The static argument heads the current construction site supplied, set by
/// the eval arm and consumed ONCE: a delegation or a default thunk builds
/// further instances underneath and must rank on its own terms.
pub threadlocal var ctor_static_heads: ?[]const ?[]const u8 = null;

/// The construction site's static heads live in this thread-owned buffer:
/// the array a site hands over is freed when the site returns (the bytecode
/// tier's NewInstance arm never takes it back), and a later secondary-ctor
/// ranking on the same thread read the freed array. The head strings are
/// module constants, so copying the slice array is enough. A site with more
/// arguments than the buffer holds ranks without static heads.
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

/// Forget any construction-site heads left installed by a path that never
/// took them (a host class, a factory, a value-class shortcut): the slice
/// they name is freed when the site returns, and the next secondary-ctor
/// ranking on this thread would read it.
pub fn clearCtorArgStaticHeads(self: *VmHost) void {
    _ = self;
    ctor_static_heads = null;
}

/// The class under construction's type-parameter bounds, so a constructor
/// parameter declared as a class type parameter (`Z<T : Int>(val x: T)`)
/// ranks as its bound: `this(n as T)` from a `constructor(vararg ys: Long)`
/// must reach the primary, not re-select the vararg secondary.
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

/// Stable synthetic class name for an anonymous-object expression, keyed by the
/// AST node address (the program is immutable, so the address is a stable site
/// id). The first instantiation of a site mints `$anon$<n>` and registers the
/// site's class + methods under it; later instantiations of the same site reuse
/// that name, so the `classes`/`anon_methods` registries stay bounded by the
/// number of `object` expressions in the program instead of growing per instance
/// (a per-request leak for a server). Names are permanent (page-allocator) since
/// they are used as long-lived map keys.
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

/// An `object` literal's field/init/super-arg initializers that need real
/// evaluation are lowered into side modules. Those modules are site-stable
/// (pure functions of the AST site — captures resolve at run time, not lowering
/// time), so they are lowered once per site and cached here, keyed by the
/// site's AST address. Reused by every instantiation: a per-request `object`
/// literal evaluates the cached thunks instead of re-lowering them into fresh
/// Module cells that, when swept, free only their header and leak the lowered
/// IR they own.
pub const AnonComplexInit = struct { name: []const u8, module: ObjRef(Module), func: FuncId };

pub const AnonInitThunk = struct { module: ObjRef(Module), func: FuncId, prop_pos: usize };

pub const AnonSuperArgThunk = struct { module: ObjRef(Module), func: FuncId };

/// One `object : Iface by <expr> {}` delegate initializer, parallel to the
/// site's supertype list; null when the slot has no delegate or a bare
/// captured name serves it directly.
pub const AnonDelegateThunk = struct { module: ObjRef(Module), func: FuncId };

pub const AnonSiteThunks = struct {
    complex_prop_inits: []const AnonComplexInit,
    init_thunks: []const AnonInitThunk,
    super_arg_thunks: []const []const ?AnonSuperArgThunk,
    delegate_thunks: []const ?AnonDelegateThunk = &.{},
};

pub var anon_site_thunks: std.AutoHashMapUnmanaged(usize, AnonSiteThunks) = .empty;

pub var anon_site_thunks_root_registered = std.atomic.Value(bool).init(false);

/// GC root: shade every cached anon-site thunk sub-module so the cached lowered
/// IR is never swept (it is reused across all instantiations of the site). Read
/// without locking: the stop-the-world handshake parks every mutator at a safe
/// point and neither `get` nor `put` spans a safe point, so the map is stable
/// here.
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

/// Clear the process-global anon-`object` site caches at a program-run
/// boundary. Both are keyed by AST-node address, which is only stable within a
/// single run; a later run can reuse a freed address, so a stale entry would
/// dispatch through a thunk sub-module owned by the finished run's allocator
/// (a cross-run use-after-free). Frees the permanent (page-allocator) site
/// names and thunk-list spines; the thunk sub-module cells are GC cells the
/// collector reclaims once unrooted. Run-boundary only (no workers live).
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
    // identity gate compares run-module CELL ADDRESSES, and an arena-reusing
    // driver hands the next program's module the same address — the stale
    // clone then serves classes whose shallow-shared method slices point
    // into the finished program's freed storage.
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

/// Publish a site's thunks (first publisher wins). A racing second build of the
/// same site loses; the loser's modules are left unrooted and GC reclaims them.
/// Returns the entry now in the cache.
pub fn anonSiteThunksPut(key: usize, entry: AnonSiteThunks) AnonSiteThunks {
    anon_site_lock.lock();
    defer anon_site_lock.unlock();
    if (anon_site_thunks.get(key)) |existing| return existing;
    anon_site_thunks.put(std.heap.page_allocator, key, entry) catch return entry;
    return entry;
}

/// The side module a runtime-synthesized class's members lower into: a
/// `cloneForExtend` of the main module, built lazily ONCE per synthesis call
/// and shared by every member/thunk lowering of that site. The clone sees the
/// whole image — classes, registries, the shared lazy func-id space — so a
/// member body's calls resolve and bind statically exactly as build-time
/// lowering would, and an emitted main-space FuncId/slot resolves both
/// through the host and through the side module itself (the cloned header
/// section serves ids below the append range). `Module.default` (the old
/// empty side module) left every call in every anon body name-dynamic.
/// `KLIO_ANON_BASE=0` restores the empty side module.
/// One process-wide side module shared by every synthesis site: a compose
/// run synthesizes hundreds of sites, and per-site clones of the image's
/// registry/indices blew the RSS cap. Appends serialize under
/// `anonLowerEnter`/`anonLowerExit`, held by callers around LOWERING
/// sections only (never around thunk execution).
pub var shared_anon_module: ?ObjRef(Module) = null;

pub var shared_anon_arena: ?*std.heap.ArenaAllocator = null;

/// Cell identity of the run module `shared_anon_module` was cloned from.
/// An in-process driver that builds and frees a module PER PROGRAM (the
/// parity itests) must not serve a later program from a side module whose
/// shallow-shared tables point into the freed earlier module — the stale
/// clone's appended-class method slices dangle and the first anon-method
/// bare call segfaults. A base-identity mismatch drops the cache and
/// re-clones from the live module.
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
    // Default ON: the image-clone side module makes anon bodies resolve
    // and bind statically. The historical RSS blowup was the shared
    // clone renting the RUN ARENA — with the side module on its own real
    // allocator (below), a full compose suite measures RSS-neutral
    // against the empty-module mode, and single classes measure neutral
    // or better. `KLIO_ANON_BASE=0` restores the empty side module.
    if (std.mem.eql(u8, runtime.envOnce("KLIO_ANON_BASE") orelse "1", "0")) {
        return ObjRef(Module).init(allocator, Module.default(allocator));
    }
    if (shared_anon_module != null and shared_anon_base_identity != self.module.identity()) {
        // A real free, not the refcount-gated `deinit` (a no-op under the
        // arena and tracing-GC modes): the retired clone is a whole deep
        // Module (~tens of MB) and a multi-program harness swaps it every
        // program — leaking it ratcheted the process into the RSS cap.
        // `Module.deinit` cannot free a cloneForExtend product (it would
        // free base buffers the clone only borrows), so the clone lives in
        // its OWN arena and retirement drops the arena wholesale. Handles
        // the finished program handed out are dead with it.
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
        // The shared side module owns a REAL allocator, never the run
        // arena: every lowering's scratch (candidate lists, type clones,
        // solved bindings) rents from `module.registry.allocator` and
        // frees on the way out — frees that were no-ops against the
        // harness arena, which is what accumulated an entire suite's
        // lowering scratch into the RSS cap. Persistent appends (the
        // lowered funcs themselves) stay bounded and live for the
        // process, matching the module's own lifetime.
        const holder = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
        holder.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        shared_anon_arena = holder;
        var cloned = try mg.get().cloneForExtend(holder.allocator());
        cloned.anon_side = true;
        // Every anon site lowers into this one module while earlier sites'
        // bodies run in it: a growing func table must not move their funcs.
        cloned.funcs_live = true;
        // PERMANENT cell, and never on the program-perm list: this cache
        // outlives programs and is freed only by the identity swap above.
        // A nursery mint here was swept by the next unrelated major (no
        // root shades it) — the swap's arena teardown is the sole owner.
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
