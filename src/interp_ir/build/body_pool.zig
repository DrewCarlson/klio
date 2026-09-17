//! Top-level function bodies lowered on a pool. Headers reserve every body's
//! FuncId before any body lowers, so bodies are independent: each reads the
//! module's tables and appends only the lambdas, thunks and constants of its
//! own. A worker lowers into a shard, a copy of the module whose appendable
//! tables are its own, allocating those ids locally; the driver then merges
//! the shards in declaration order, renumbering the ids as a serial pass would
//! have allocated them, so the module comes out the same either way.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir");
const ast = @import("ast");
const runtime = @import("runtime");
const overrides = @import("overrides.zig");
const module_trace = @import("module.zig");

const BuildCtx = overrides.BuildCtx;
const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const ConstId = ir.ConstId;

pub const Job = struct {
    f: *const ast.Function,
    /// The reserved slot of a top-level body; unused for a member, which
    /// `placeMember` files by its declaration span.
    id: FuncId,
    pkg: []const u8,
    member: ?Member = null,

    pub const Member = struct {
        owner_class: []const u8,
        own_members: *const std.StringHashMap(void),
        enclosing: *const std.StringHashMap(void),
        own_member_arity: *const std.StringHashMap(u64),
        class_fqn: []const u8,
        class_pkg: []const u8,
    };
};

const Result = struct {
    func: Func = undefined,
    funcs_from: u32 = 0,
    funcs_to: u32 = 0,
    consts_from: u32 = 0,
    consts_to: u32 = 0,
    shard: u32 = 0,
};

const Work = struct {
    jobs: []const Job,
    results: []Result,
    file_classes: *const overrides.FileClasses,
    module: *const Module,
    allocator: Allocator,
    next: std.atomic.Value(usize) = .init(0),
    build_state: ir.build.ThreadState,
    inline_state: ir.lower.inline_state.ThreadState,
};

/// The registry tables a body may write. Every other table is read only while
/// bodies lower, so a shard shares it.
const registry_writable = [_][]const u8{
    "abstract_member_arity",   "abstract_member_defaults", "class_type_param_bounds",
    "func_type_param_bounds",  "func_type_params",         "iface_member_ctx_types",
    "iface_member_ext_recv",   "import_aliases",           "import_wildcards",
    "local_fn_defaults",       "member_ext_owner_class",   "member_method_fids",
    "private_fn_files",        "class_super_names",
};

/// The module tables a body may append to, keyed by or holding FuncIds.
const fid_maps = [_][]const u8{ "decl_span", "decl_sigs", "decl_user_params", "decl_user_arity", "decl_user_sig" };

const Shard = struct {
    index: u32,
    module: Module,
    funcs_at_fork: u32,
    consts_at_fork: u32,
    sizes_at_fork: Sizes,
    func_map: []FuncId = &.{},
    const_map: []ConstId = &.{},
    thread: ?std.Thread = null,
    failed: bool = false,
    forked: bool = false,

    /// Fills the shard's own tables; the spawner's `thread` stays as it is.
    fn fork(self: *Shard, index: u32, main: *const Module, a: Allocator) Allocator.Error!void {
        var m = main.*;
        m.funcs = .empty;
        try m.funcs.appendSlice(a, main.funcs.items);
        m.late_funcs = .empty;
        m.consts = .empty;
        try m.consts.appendSlice(a, main.consts.items);
        m.const_dedup = try main.const_dedup.clone(a);
        m.top_level = .empty;
        m.resolve_diags = .empty;
        m.tailrec_fn_names = .empty;
        try m.tailrec_fn_names.appendSlice(a, main.tailrec_fn_names.items);
        m.classes = .empty;
        try m.classes.appendSlice(a, main.classes.items);
        m.class_index = .empty;
        try m.class_index.appendSlice(a, main.class_index.items);
        m.func_index = .empty;
        try m.func_index.appendSlice(a, main.func_index.items);
        m.func_name_index = try cloneListMap(FuncId, a, &main.func_name_index);
        m.member_name_index = try cloneListMap(FuncId, a, &main.member_name_index);
        m.method_dispatch = try main.method_dispatch.clone();
        m.decl_ast_body = try main.decl_ast_body.clone();
        inline for (fid_maps) |name| @field(m, name) = try @field(main, name).clone();
        m.func_by_decl_span = if (main.func_by_decl_span) |fm| try fm.clone() else null;
        m.ext_resolve_cache = null;
        m.recv_verdict_cache = null;
        inline for (registry_writable) |name| @field(m.registry, name) = try @field(main.registry, name).clone();
        m.registry.evidence_supers = .empty;
        m.registry.evidence_supers_gen = m.registry.class_super_gen;
        self.index = index;
        self.module = m;
        self.funcs_at_fork = @intCast(main.funcs.items.len);
        self.consts_at_fork = @intCast(main.consts.items.len);
        self.sizes_at_fork = Sizes.of(main);
        self.forked = true;
    }

    fn release(self: *Shard, a: Allocator) void {
        const m = &self.module;
        m.funcs.deinit(a);
        m.late_funcs.deinit(a);
        for (m.consts.items[self.consts_at_fork..]) |c| {
            if (c == .String) a.free(c.String);
        }
        m.consts.deinit(a);
        m.const_dedup.deinit(a);
        m.top_level.deinit(a);
        m.resolve_diags.deinit(a);
        m.tailrec_fn_names.deinit(a);
        m.classes.deinit(a);
        m.class_index.deinit(a);
        m.func_index.deinit(a);
        releaseListMap(FuncId, a, &m.func_name_index);
        releaseListMap(FuncId, a, &m.member_name_index);
        m.method_dispatch.deinit();
        m.decl_ast_body.deinit();
        inline for (fid_maps) |name| @field(m, name).deinit();
        if (m.func_by_decl_span) |*fm| fm.deinit();
        if (m.ext_resolve_cache) |c| {
            c.arena.deinit();
            a.destroy(c);
        }
        if (m.recv_verdict_cache) |c| {
            c.clear(a);
            c.map.deinit(a);
            a.destroy(c);
        }
        inline for (registry_writable) |name| @field(m.registry, name).deinit();
        m.registry.dropEvidenceSupers();
        m.registry.evidence_supers.deinit(m.registry.allocator);
        a.free(self.func_map);
        a.free(self.const_map);
    }
};

fn cloneListMap(comptime V: type, a: Allocator, src: anytype) Allocator.Error!@TypeOf(src.*) {
    var out = @TypeOf(src.*).init(a);
    var it = src.iterator();
    while (it.next()) |e| {
        var list: std.ArrayList(V) = .empty;
        try list.appendSlice(a, e.value_ptr.items);
        try out.put(e.key_ptr.*, list);
    }
    return out;
}

fn releaseListMap(comptime V: type, a: Allocator, m: anytype) void {
    _ = V;
    var it = m.valueIterator();
    while (it.next()) |list| list.deinit(a);
    m.deinit();
}

/// Entry counts of every module and registry table, so a shard that touched a
/// table the merge does not carry over is caught.
const Sizes = struct {
    module: [256]usize,
    registry: [256]usize,

    fn of(m: *const Module) Sizes {
        var s: Sizes = undefined;
        _ = tableSizes(Module, m, &s.module);
        _ = tableSizes(@TypeOf(m.registry), &m.registry, &s.registry);
        return s;
    }
};

fn tableSizes(comptime T: type, v: *const T, out: []usize) usize {
    var n: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const FT = f.type;
        const info = @typeInfo(FT);
        if (info == .@"struct" and @hasDecl(FT, "count") and (@hasField(FT, "unmanaged") or @hasField(FT, "metadata"))) {
            out[n] = @field(v, f.name).count();
        } else if (info == .@"struct" and @hasField(FT, "items")) {
            out[n] = @field(v, f.name).items.len;
        } else if (info == .optional and @typeInfo(info.optional.child) == .@"struct" and @hasDecl(info.optional.child, "count") and (@hasField(info.optional.child, "unmanaged") or @hasField(info.optional.child, "metadata"))) {
            out[n] = if (@field(v, f.name)) |m| m.count() else 0;
        } else {
            out[n] = std.math.maxInt(usize);
        }
        n += 1;
    }
    return n;
}

/// Tables a shard is expected to grow: the merge carries them over.
fn journaled(comptime T: type, comptime name: []const u8) bool {
    if (T == Module) {
        inline for (fid_maps) |n| if (std.mem.eql(u8, n, name)) return true;
        inline for (.{ "funcs", "consts", "const_dedup", "top_level", "resolve_diags", "decl_ast_body", "func_by_decl_span" }) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
    inline for (.{ "evidence_supers", "recv_fn_props" }) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn grewOutside(comptime T: type, label: []const u8, v: *const T, before: []const usize) bool {
    var after: [256]usize = undefined;
    _ = tableSizes(T, v, &after);
    var grew = false;
    var i: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (before[i] != std.math.maxInt(usize) and before[i] != after[i] and !journaled(T, f.name)) {
            if (module_trace.phase.on()) std.debug.print("[lower] body pool: shard grew {s}.{s} {d} -> {d}; lowering serially\n", .{ label, f.name, before[i], after[i] });
            grew = true;
        }
        i += 1;
    }
    return grew;
}

fn threadCount(n_jobs: usize) usize {
    var n: usize = std.Thread.getCpuCount() catch 1;
    if (runtime.envOnce("KLIO_MAX_WORKERS")) |v| {
        if (std.fmt.parseInt(usize, v, 10)) |x| {
            if (x != 0) n = @min(n, x);
        } else |_| {}
    }
    if (runtime.envOnce("KLIO_LOWER_THREADS")) |v| {
        if (std.fmt.parseInt(usize, v, 10)) |x| n = x else |_| {}
    }
    n = @min(n, n_jobs / 16);
    return @max(n, 1);
}

fn workerMain(work: *Work, shard: *Shard, index: u32) void {
    // Each worker copies the module for itself: the copies are the pool's
    // serial cost otherwise, and the source is read-only while they are made.
    shard.fork(index, work.module, work.allocator) catch {
        shard.failed = true;
        return;
    };
    ir.build.installThreadState(work.build_state);
    ir.lower.inline_state.installThreadState(work.inline_state) catch {
        shard.failed = true;
        return;
    };
    defer ir.lower.inline_state.dropThreadState();
    const m = &shard.module;
    while (true) {
        const j = work.next.fetchAdd(1, .monotonic);
        if (j >= work.jobs.len) return;
        const job = work.jobs[j];
        const funcs_from: u32 = @intCast(m.funcs.items.len);
        const consts_from: u32 = @intCast(m.consts.items.len);
        const func = lowerJob(m, job, work.file_classes) catch {
            shard.failed = true;
            return;
        };
        work.results[j] = .{
            .func = func,
            .funcs_from = funcs_from,
            .funcs_to = @intCast(m.funcs.items.len),
            .consts_from = consts_from,
            .consts_to = @intCast(m.consts.items.len),
            .shard = shard.index,
        };
    }
}

/// One job's body, on whichever thread and module it runs.
pub fn lowerJob(m: *Module, job: Job, file_classes: *const overrides.FileClasses) Allocator.Error!Func {
    if (job.member) |mem| {
        const prev = ir.lower.decl.enterClassContext(mem.class_fqn, mem.class_pkg);
        defer ir.lower.decl.leaveClassContext(prev);
        return ir.lower.decl.lowerMemberBody(m, job.f, mem.owner_class, mem.own_members, mem.enclosing, mem.own_member_arity);
    }
    const prev_pkg = ir.lower.decl.setLowerSelfPackage(job.pkg);
    defer _ = ir.lower.decl.setLowerSelfPackage(prev_pkg);
    return ir.lower.lowerFunctionBodyInto(m, job.f, file_classes);
}

/// Lowers `jobs` on a pool and returns each body, its ids as a serial pass
/// would have allocated them, ready to place in job order. Null when the pool
/// did not run or a shard did something the merge cannot carry over; the
/// caller then lowers serially, the module untouched. The caller frees the
/// slice.
pub fn lower(ctx: *BuildCtx, jobs: []const Job) Allocator.Error!?[]Func {
    const threads = threadCount(jobs.len);
    if (threads < 2 or ctx.base != null) return null;
    const a = ctx.module.registry.allocator;
    const t0 = runtime.clockMonotonicNanos();
    try ctx.module.warmLookupCaches();

    var work = Work{
        .jobs = jobs,
        .results = try a.alloc(Result, jobs.len),
        .file_classes = &ctx.file_classes,
        .module = ctx.module,
        .allocator = a,
        .build_state = ir.build.captureThreadState(),
        .inline_state = ir.lower.inline_state.captureThreadState(),
    };
    defer a.free(work.results);
    const shards = try a.alloc(Shard, threads);
    defer a.free(shards);
    for (shards) |*s| s.* = .{ .index = 0, .module = undefined, .funcs_at_fork = 0, .consts_at_fork = 0, .sizes_at_fork = undefined, .thread = null };
    defer for (shards) |*s| {
        if (s.forked) s.release(a);
    };
    var spawned: usize = 0;
    for (shards, 0..) |*s, i| {
        s.thread = std.Thread.spawn(.{ .stack_size = 256 << 20 }, workerMain, .{ &work, s, @as(u32, @intCast(i)) }) catch break;
        spawned += 1;
    }
    if (spawned == 0) return null;
    for (shards[0..spawned]) |*s| s.thread.?.join();
    if (work.next.load(.monotonic) < jobs.len) return error.OutOfMemory;
    for (shards[0..spawned]) |*s| {
        if (s.failed) return error.OutOfMemory;
        if (s.module.late_funcs.items.len != 0) return null;
        if (grewOutside(Module, "module", &s.module, &s.sizes_at_fork.module)) return null;
        if (grewOutside(@TypeOf(s.module.registry), "registry", &s.module.registry, &s.sizes_at_fork.registry)) return null;
        s.func_map = try a.alloc(FuncId, s.module.funcs.items.len - s.funcs_at_fork);
        s.const_map = try a.alloc(ConstId, s.module.consts.items.len - s.consts_at_fork);
    }
    const t1 = runtime.clockMonotonicNanos();

    const main = ctx.module;
    for (work.results) |*r| {
        const s = &shards[r.shard];
        // Constants first: a body's constants keep their creation order and the
        // module's dedup, exactly as interning them while lowering did.
        var local = r.consts_from;
        while (local < r.consts_to) : (local += 1) {
            const final = try main.internConst(a, s.module.consts.items[local]);
            s.const_map[local - s.consts_at_fork] = final;
        }
        // The body's lambdas and thunks take the next ids in creation order.
        const first_final = main.nextFuncId().int();
        local = r.funcs_from;
        while (local < r.funcs_to) : (local += 1) {
            s.func_map[local - s.funcs_at_fork] = FuncId.from(first_final + (local - r.funcs_from));
        }
        const map = ir.remap.IdMap{
            .func_base = s.funcs_at_fork,
            .funcs = s.func_map,
            .const_base = s.consts_at_fork,
            .consts = s.const_map,
        };
        local = r.funcs_from;
        while (local < r.funcs_to) : (local += 1) {
            var f = s.module.funcs.items[local];
            ir.remap.remapFunc(&f, &map);
            std.debug.assert(f.id.int() == first_final + (local - r.funcs_from));
            try main.appendFunc(f);
            const final = f.id.int();
            inline for (fid_maps) |name| {
                if (@field(s.module, name).get(local)) |v| try @field(main, name).put(final, v);
            }
            if (s.module.decl_ast_body.contains(local)) try main.decl_ast_body.put(final, {});
        }
        ir.remap.remapFunc(&r.func, &map);
        for (s.module.resolve_diags.items) |d| try main.resolve_diags.append(a, d);
        s.module.resolve_diags.clearRetainingCapacity();
    }
    const out = try a.alloc(Func, jobs.len);
    for (work.results, out) |*r, *o| o.* = r.func;
    if (module_trace.phase.on()) {
        const t2 = runtime.clockMonotonicNanos();
        std.debug.print("[lower] body pool: {d} bodies on {d} threads, lower {d}ms, merge {d}ms\n", .{ jobs.len, spawned, (t1 - t0) / 1_000_000, (t2 - t1) / 1_000_000 });
    }
    return out;
}
