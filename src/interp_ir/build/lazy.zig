//! Lazy bodies: a base build that lowers its declarations' headers and runs
//! the program before its bodies. Each body a call reaches lowers on that
//! first call, on the thread that runs the program, into the module the
//! program runs; once the program returns, the pools lower every deferred
//! body into the base in their usual order, so the image the run then bakes
//! is the one an eager build would have baked. Off by default: the run
//! keeps the build alive for its whole duration, so its resident set is the
//! build's, and the image lands only after the program ends.

const std = @import("std");
const ir = @import("ir");
const ast = @import("ast");
const runtime = @import("runtime");
const body_pool = @import("body_pool.zig");
const overrides = @import("overrides.zig");
const base_mod = @import("base.zig");
const build_types = @import("types.zig");

const Allocator = std.mem.Allocator;
const FuncId = ir.FuncId;

/// What the driver runs once the base is built with its bodies deferred:
/// the program, against the base it is handed. Returns the exit code.
pub const RunInBuild = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, *base_mod.StdlibBase) u8,
};

const DeferredJob = struct { id: FuncId, job: body_pool.Job };

/// One module's view of the shard's additions: for every function and
/// constant the shard added since its fork, the id it has in this module,
/// or the sentinel when this module has not needed it yet.
const Target = struct {
    func_map: std.ArrayList(FuncId) = .empty,
    const_map: std.ArrayList(ir.ConstId) = .empty,
};
const unmapped_func = FuncId.from(std.math.maxInt(u32));
const unmapped_const = ir.ConstId.from(std.math.maxInt(u32));

pub const Plan = struct {
    a: Allocator,
    run: RunInBuild,
    /// The build's context, kept whole until `complete`.
    ctx: ?*overrides.BuildCtx = null,
    /// The deferred bodies by the id of the slot each fills.
    jobs: std.AutoHashMap(u32, body_pool.Job),
    /// The same in pool order, for the completion.
    order: std.ArrayList(DeferredJob) = .empty,
    /// The base the driver wrapped around the built module for the run.
    base: ?*base_mod.StdlibBase = null,
    exit_code: ?u8 = null,
    /// Set by the base builder: wraps the built module and runs the program,
    /// called by the driver while everything it installed is still in place.
    after_build: ?*const fn (*Plan, build_types.BuiltModule, []ast.Decl) void = null,
    files: []const ast.KotlinFile = &.{},
    main_policy: base_mod.MainPolicy = .allow,
    /// Bodies lowered on first call while the program ran.
    on_demand: usize = 0,
    lock: runtime.SpinMutex = .{},
    /// The module a body lowers in on first call: a shard forked from the
    /// base, complete where the run module's clone is not. Its new functions
    /// and constants are renumbered into the run module.
    shard: ?*body_pool.Shard = null,
    /// The shard's additions renumbered per module they were installed
    /// into: the program's module and any it clones (an anonymous object's
    /// side module), whose constant tables diverge as each interns its own.
    targets: std.AutoHashMap(usize, *Target),
    /// The lowering's thread state as the program's thread has it, for a
    /// body reached on another thread.
    build_state: ?ir.build.ThreadState = null,
    inline_state: ?ir.lower.inline_state.ThreadState = null,
    main_thread: std.Thread.Id = 0,

    pub fn deferBody(self: *Plan, id: FuncId, job: body_pool.Job) Allocator.Error!void {
        try self.jobs.put(id.int(), job);
        try self.order.append(self.a, .{ .id = id, .job = job });
    }
};

/// Armed by the driver for the next base build, which takes it.
pub var pending: ?*Plan = null;
/// The plan whose program is running: the hook lowers for it.
pub var active: ?*Plan = null;
/// The plan the module build just took, for the driver to run and complete.
pub var active_build: ?*Plan = null;
threadlocal var in_hook: bool = false;

pub fn arm(a: Allocator, run: RunInBuild) Allocator.Error!*Plan {
    const p = try a.create(Plan);
    p.* = .{ .a = a, .run = run, .jobs = std.AutoHashMap(u32, body_pool.Job).init(a), .targets = std.AutoHashMap(usize, *Target).init(a) };
    pending = p;
    return p;
}

pub fn take() ?*Plan {
    const p = pending;
    pending = null;
    return p;
}

/// Fills a slot with a lowered body, keeping the identity the header pass
/// gave it, as the eager placement does.
pub fn installBody(module: *ir.Module, id: FuncId, func: ir.Func) void {
    const slot = module.funcByIdMut(id) orelse return;
    var placed = func;
    placed.id = id;
    placed.fqn = slot.fqn;
    placed.package = slot.package;
    slot.* = placed;
}

/// The lowering thread state a program runs under in an eager run: the
/// build's own is restored before the program starts, so nothing of it
/// is installed.
const run_build_state: ir.build.ThreadState = .{
    .self_package = "",
    .file_private_renames = null,
    .file_private_func_renames = null,
    .file_type_renames = null,
    .pkg_type_renames = null,
    .file_pkgs = null,
    .owner_class = null,
    .anon_scope_renames = &.{},
    .anon_prop_heads = &.{},
    .anon_capture_names = &.{},
    .anon_boxed_names = &.{},
    .anon_scope_classes = &.{},
};

/// Taken on the build's thread before the program runs: the base's
/// lowering state, which every deferred body lowers under, on whichever
/// thread reaches it.
pub fn captureState() void {
    const p = active orelse return;
    p.build_state = ir.build.captureThreadState();
    // A build the program starts on this thread (an anonymous object's, for
    // one) replaces and frees this thread's tables, so another thread
    // lowers against the plan's own copies.
    p.inline_state = ir.lower.inline_state.cloneThreadState(p.a, ir.lower.inline_state.captureThreadState()) catch null;
    p.main_thread = std.Thread.getCurrentId();
}

/// Before the program runs. The shard every body lowers in forks now,
/// from the headers as the lowering sees them; then each deferred slot
/// takes the flags the VM binds a call against (suspension, kind, the
/// receiver slot), which the lowering must not see: a caller lowered
/// against a header flagged so lowers differently, and wrongly.
pub fn prepareRun() Allocator.Error!void {
    const p = active orelse return;
    const ctx = p.ctx orelse return;
    try ctx.module.warmLookupCaches();
    const sh = try p.a.create(body_pool.Shard);
    sh.* = .{ .index = 0, .module = undefined, .funcs_at_fork = 0, .consts_at_fork = 0, .sizes_at_fork = undefined, .thread = null };
    try sh.fork(0, ctx.module, p.a);
    p.shard = sh;
    setRunFlags(p, true);
}

/// The top-level stubs' flags, on for the run and off for the completion;
/// a member's header carries them from its reservation.
fn setRunFlags(p: *Plan, on: bool) void {
    const ctx = p.ctx orelse return;
    for (p.order.items) |d| {
        if (d.job.member != null) continue;
        const slot = ctx.module.funcByIdMut(d.id) orelse continue;
        if (slot.blocks.len != 0) continue;
        const f = d.job.f;
        slot.is_suspend = on and f.is_suspend;
        slot.has_receiver_param = on and f.receiver_type != null;
        slot.kind = if (on and f.receiver_type != null) .top_level_extension else .plain;
    }
}

/// The program is about to run: it runs under the state an eager run has,
/// with the build's own installed only around each body that lowers.
pub fn enterRun() void {
    ir.build.installThreadState(run_build_state);
}

/// The program returned: the build's state comes back, and the stubs their
/// headers as the lowering knows them, for the completion.
pub fn leaveRun() void {
    const p = active orelse return;
    if (p.build_state) |bs| ir.build.installThreadState(bs);
    setRunFlags(p, false);
}

/// The module's hook: a function about to execute with no blocks lowers
/// now, on this thread, and is installed into the module it runs in.
/// `func` may be the module's slot or a copy a dispatch table holds; both
/// end up filled. The body lowers in a shard forked from the base, whose
/// tables are complete where the run module's clone is not; the functions
/// and constants it adds are renumbered into the run module, as the pool's
/// merge renumbers a worker's.
pub fn hook(module_c: *const ir.Module, func: *ir.Func) void {
    const id = func.id;
    const p = active orelse return;
    if (in_hook) return;
    // The lowering below looks functions up itself; those lookups must not
    // come back here, and the slot's check goes through the lookup without
    // the hook.
    in_hook = true;
    defer in_hook = false;
    p.lock.lock();
    defer p.lock.unlock();
    const job = p.jobs.get(id.int()) orelse return;
    const ctx = p.ctx orelse return;
    const run: *ir.Module = @constCast(module_c);
    const slot = run.funcByIdMut(id) orelse return;
    if (slot.blocks.len != 0) {
        if (func != slot) func.* = slot.*;
        return;
    }
    // The body lowers under the base build's state; the program's thread
    // returns to the state a program runs under, another thread drops the
    // inline tables it was lent.
    const foreign = p.main_thread != 0 and std.Thread.getCurrentId() != p.main_thread;
    const bs = p.build_state orelse return;
    ir.build.installThreadState(bs);
    defer ir.build.installThreadState(run_build_state);
    if (foreign) {
        const is = p.inline_state orelse return;
        ir.lower.inline_state.installThreadState(is) catch return;
    }
    defer if (foreign) ir.lower.inline_state.dropThreadState();
    lowerInto(p, ctx, run, id, job) catch return;
    if (func != slot) func.* = slot.*;
    p.on_demand += 1;
}

fn lowerInto(p: *Plan, ctx: *overrides.BuildCtx, run: *ir.Module, id: FuncId, job: body_pool.Job) Allocator.Error!void {
    const a = p.a;
    const sh = p.shard orelse return;
    const m = &sh.module;
    const target = p.targets.get(@intFromPtr(run)) orelse blk: {
        const t = try a.create(Target);
        t.* = .{};
        try p.targets.put(@intFromPtr(run), t);
        break :blk t;
    };
    const funcs_from: u32 = @intCast(m.funcs.items.len);
    var lowered = try body_pool.lowerJob(m, job, &ctx.file_classes);
    // The shard's additions since the fork index this module's maps. Every
    // constant the shard holds gets this module's id, interned now where
    // an earlier body lowered for another module added it; the functions
    // this body added get fresh ids here.
    const funcs_to: u32 = @intCast(m.funcs.items.len);
    const consts_to: u32 = @intCast(m.consts.items.len);
    const old_f = target.func_map.items.len;
    try target.func_map.resize(a, funcs_to - sh.funcs_at_fork);
    for (target.func_map.items[old_f..]) |*e| e.* = unmapped_func;
    const old_c = target.const_map.items.len;
    try target.const_map.resize(a, consts_to - sh.consts_at_fork);
    for (target.const_map.items[old_c..]) |*e| e.* = unmapped_const;
    for (target.const_map.items, 0..) |*slot, i| {
        if (slot.* != unmapped_const) continue;
        slot.* = try run.internConst(run.func_name_index.allocator, m.consts.items[sh.consts_at_fork + i]);
    }
    const first = run.nextFuncId().int();
    var local = funcs_from;
    while (local < funcs_to) : (local += 1) {
        target.func_map.items[local - sh.funcs_at_fork] = FuncId.from(first + (local - funcs_from));
    }
    const map = ir.remap.IdMap{
        .func_base = sh.funcs_at_fork,
        .funcs = target.func_map.items,
        .const_base = sh.consts_at_fork,
        .consts = target.const_map.items,
    };
    local = funcs_from;
    while (local < funcs_to) : (local += 1) {
        var f = m.funcs.items[local];
        ir.remap.remapFunc(&f, &map);
        try run.appendFunc(f);
        const final = f.id.int();
        if (m.decl_span.get(local)) |v| try run.decl_span.put(final, v);
        if (m.decl_sigs.get(local)) |v| try run.decl_sigs.put(final, v);
        if (m.decl_user_params.get(local)) |v| try run.decl_user_params.put(final, v);
        if (m.decl_user_arity.get(local)) |v| try run.decl_user_arity.put(final, v);
        if (m.decl_user_sig.get(local)) |v| try run.decl_user_sig.put(final, v);
        if (m.decl_ast_body.contains(local)) try run.decl_ast_body.put(final, {});
    }
    ir.remap.remapFunc(&lowered, &map);
    installBody(run, id, lowered);
}

/// Lowers every deferred body into the base, in pool order, once the
/// program has returned. The context is the build's own, so this is the
/// eager build's pool run, late.
pub fn complete(p: *Plan) Allocator.Error!void {
    const ctx = p.ctx orelse return;
    var jobs: std.ArrayList(body_pool.Job) = .empty;
    defer jobs.deinit(p.a);
    try jobs.ensureTotalCapacity(p.a, p.order.items.len);
    for (p.order.items) |d| jobs.appendAssumeCapacity(d.job);
    const lowered = try overrides.lowerJobsFor(ctx, jobs.items);
    defer p.a.free(lowered);
    for (p.order.items, lowered) |d, func| installBody(ctx.module, d.id, func);
    if (runtime.envOnce("KLIO_LOWER_FINGERPRINT") != null) {
        const module = ctx.module;
        std.debug.print("[fn-block] {d} functions\n", .{module.funcs.items.len});
        for (module.funcs.items) |*fnc| {
            var n: usize = 0;
            for (fnc.blocks) |blk| n += blk.insts.len;
            std.debug.print("[fn] {d} {s} blocks={d} insts={d} hash={x}\n", .{ fnc.id.int(), fnc.fqn, fnc.blocks.len, n, ir.remap.semanticHash(fnc) });
        }
    }
    if (runtime.envOnce("KLIO_TRACE_STDLIB_IMAGE") != null) {
        std.debug.print("[stdlib-image]   lazy bodies: {d} deferred, {d} lowered on first call, all lowered after the run\n", .{ p.order.items.len, p.on_demand });
    }
}
