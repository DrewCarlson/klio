//! Compiled-code cache and tiering policy: the `KLIO_JIT` gates, per-function JIT state and
//! its invalidation, the method seam, and the entries deciding whether to enter compiled code.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const common = @import("common.zig");
const shapes = @import("shapes.zig");
const type_infer = @import("types.zig");
const compile_loop = @import("compile_loop.zig");
const run_mod = @import("run.zig");
const compile_func = @import("compile_func.zig");

const Value = runtime.Value;
const Module = ir.Module;
const Func = ir.Func;
const BlockId = ir.BlockId;
const Allocator = std.mem.Allocator;

const CompiledLoop = common.CompiledLoop;
const TrampFn = common.TrampFn;
const tryCompileFunc = compile_func.tryCompileFunc;
const tryCompile = compile_loop.tryCompile;
const FuncOutcome = run_mod.FuncOutcome;
const Resume = run_mod.Resume;
const regsGrowAlloc = run_mod.regsGrowAlloc;
const runFunc = run_mod.runFunc;
const runLoop = run_mod.runLoop;
const FieldResolver = shapes.FieldResolver;
const MemberResolver = shapes.MemberResolver;
const VirtResolver = shapes.VirtResolver;

const HOT_THRESHOLD: u32 = 64;

/// Back edges a fused body may follow before handing its loop to the framed engine so this
/// tier can compile it. Above the framed threshold, so a short loop stays on the fused walk.
pub const FUSED_YIELD_BACK_EDGES: u32 = 128;

/// `Func.func_jit_probe` encoding: low 30 bits count activations, bit 30 means COMPILED
/// somewhere (consult the per-thread state), bit 31 means DECLINED and is sticky, so a
/// never-compiled body stops walking the state map on every activation.
const PROBE_COMPILED: u32 = 1 << 30;
const PROBE_DECLINED: u32 = 1 << 31;
const PROBE_COUNT_MASK: u32 = PROBE_COMPILED - 1;

inline fn probeWord(func: *const Func) *std.atomic.Value(u32) {
    return &@constCast(func).func_jit_probe;
}

/// Bumps the shared activation count, bounded since the walker can outrun the compiling hook.
inline fn probeCount(func: *const Func) bool {
    const pw = probeWord(func);
    const pr = pw.load(.monotonic);
    const n = pr & PROBE_COUNT_MASK;
    // Counts past the threshold too: the yield budget reads this to notice a body that stayed hot.
    if (n < HOT_THRESHOLD * 4) _ = pw.fetchAdd(1, .monotonic);
    return n + 1 >= HOT_THRESHOLD;
}
/// A transient bail (a snapshot holding a null object register) is retried a few times, spaced
/// by re-reaching the threshold, before the loop is given up.
const MAX_COMPILE_ATTEMPTS: u8 = 6;
const RETRY_GAP: u32 = 8;

pub const FuncJit = struct {
    /// Fingerprint of the function this state was built for, its `blocks` slice pointer. The `states`
    /// map is keyed by `*Func` address, which a freed module's reallocation can reuse, so a hit whose
    /// fingerprint no longer matches is discarded and rebuilt.
    blocks_fp: usize,
    counts: []u32,
    attempts: []u8,
    /// Plain arrays, so the per-block-entry hot probe is two indexed loads, not map lookups.
    slots: []?*CompiledLoop,
    dead: []bool,
    /// Whole-function JIT: a separate hot counter and compiled unit for the function entry.
    /// `func_tried` latches once a compile was attempted, success leaving `func_jit` set.
    func_count: u32 = 0,
    func_tried: bool = false,
    func_jit: ?CompiledLoop = null,
    a: Allocator,

    pub fn deinit(self: *FuncJit) void {
        self.a.free(self.counts);
        self.a.free(self.attempts);
        for (self.slots) |maybe| if (maybe) |cl| {
            cl.deinit();
            self.a.destroy(cl);
        };
        self.a.free(self.slots);
        self.a.free(self.dead);
        if (self.func_jit) |*cl| cl.deinit();
    }
};

var jit_enabled_cache: ?bool = null;
var jit_debug_cache: ?bool = null;

/// Test-only: force the JIT on or off, bypassing the `KLIO_JIT` env probe.
pub fn setEnabledForTest(on: bool) void {
    jit_enabled_cache = on;
}

pub fn enabled() bool {
    if (jit_enabled_cache) |e| return e; // test override
    return runtime.perf.get().jit_loop;
}

var fj_fields_cache: ?bool = null;
pub fn fjFieldsEnabled() bool {
    if (fj_fields_cache) |v| return v;
    const on = if (runtime.envOnce("KLIO_FJ_FIELDS")) |v| !(v.len != 0 and v[0] == '0') else true;
    fj_fields_cache = on;
    return on;
}

var fj_escape_cache: ?bool = null;
/// Escapes let a compiled body keep the instructions this tier cannot emit natively: it calls back
/// into the interpreter for that one instruction instead of the whole function being disqualified.
/// Opt-in (`KLIO_FJ_ESCAPE=1`): an escaped instruction costs what the interpreter would have.
pub fn fjEscapeEnabled() bool {
    if (fj_escape_cache) |v| return v;
    const on = if (runtime.envOnce("KLIO_FJ_ESCAPE")) |v| v.len != 0 and v[0] == '1' else false;
    fj_escape_cache = on;
    return on;
}

var fj_member_cache: ?bool = null;
pub fn fjMemberEnabled() bool {
    if (fj_member_cache) |v| return v;
    const on = if (runtime.envOnce("KLIO_FJ_MEMBER")) |v| v.len != 0 and v[0] == '1' else true;
    fj_member_cache = on;
    return on;
}

pub fn debugEnabled() bool {
    if (jit_debug_cache) |d| return d;
    const v = runtime.envOnce("KLIO_JIT_DEBUG");
    const on = v != null and v.?.len > 0 and !std.mem.eql(u8, v.?, "0");
    jit_debug_cache = on;
    return on;
}

var func_jit_cache: ?bool = null;

/// Whole-function JIT (function mode, native recursion): whole bodies compiled per thread with no
/// cross-thread eviction path, so it is off by default and the in-process harness accumulates none.
pub fn funcEnabled() bool {
    if (!enabled()) return false;
    if (func_jit_cache) |f| return f; // test override
    return runtime.perf.get().jit_func;
}

pub fn setFuncEnabledForTest(on: bool) void {
    func_jit_cache = on;
}

threadlocal var states: std.AutoHashMapUnmanaged(usize, *FuncJit) = .empty;

/// JIT bookkeeping goes through a general-purpose allocator: `page_allocator` rounds each FuncJit,
/// count and attempt up to an OS page. Executable buffers still use the W^X mmap path.
pub const metadata_allocator = runtime.slab.allocator;

/// Total compiled native units cached on this thread, bounding the per-thread cache. Eviction
/// happens only at a safe point (`evictIfOverBudget`, with no native frame on the stack).
threadlocal var compiled_units: usize = 0;
/// Compiled-unit ceiling per thread before the cache is dropped wholesale at the next safe point;
/// a pathological generator recompiles its hot code instead of growing unbounded.
const COMPILED_UNIT_CAP: usize = 2048;

fn noteCompiled() void {
    compiled_units += 1;
}

/// Drops this thread's JIT cache once it has grown past the ceiling. MUST run only at a safe
/// point, no compiled code on the stack (`eval_depth == 0`), since it frees the mmap'd buffers.
pub fn evictIfOverBudget() void {
    if (compiled_units <= COMPILED_UNIT_CAP) return;
    if (debugEnabled()) std.debug.print("[jit] evicting {d} compiled unit(s)\n", .{compiled_units});
    clearStates();
}

fn clearStates() void {
    seam_gen +%= 1;
    var it = states.valueIterator();
    while (it.next()) |s| {
        s.*.deinit();
        metadata_allocator.destroy(s.*);
    }
    states.clearAndFree(metadata_allocator);
    type_infer.ret_type_cache.clearAndFree(metadata_allocator);
    compiled_units = 0;
}

pub fn compiledFunc(func: *const Func) ?*const CompiledLoop {
    if (!funcEnabled()) return null;
    const fj = states.get(@intFromPtr(func)) orelse return null;
    if (func.blocks.len == 0 or fj.blocks_fp != @intFromPtr(func.blocks.ptr)) return null;
    if (fj.func_jit) |*cl| return cl;
    return null;
}

/// Frees and clears all per-function JIT state on this thread, so a finished program's compiled
/// code is not retained and a reallocated module's reused `*Func` inherits no stale body.
pub fn resetForTest() void {
    clearStates();
}

pub fn forFunc(func: *const Func) ?*FuncJit {
    const a = metadata_allocator;
    const key = @intFromPtr(func);
    if (func.blocks.len == 0) return null;
    const fp = @intFromPtr(func.blocks.ptr);
    if (states.get(key)) |s| {
        if (s.blocks_fp == fp) return s;
        // Address reused for a different function: drop the stale state and its compiled code.
        seam_gen +%= 1;
        s.deinit();
        a.destroy(s);
        _ = states.remove(key);
    }
    const s = a.create(FuncJit) catch return null;
    const counts = a.alloc(u32, func.blocks.len) catch {
        a.destroy(s);
        return null;
    };
    const attempts = a.alloc(u8, func.blocks.len) catch {
        a.free(counts);
        a.destroy(s);
        return null;
    };
    const slots = a.alloc(?*CompiledLoop, func.blocks.len) catch {
        a.free(attempts);
        a.free(counts);
        a.destroy(s);
        return null;
    };
    const dead = a.alloc(bool, func.blocks.len) catch {
        a.free(slots);
        a.free(attempts);
        a.free(counts);
        a.destroy(s);
        return null;
    };
    s.* = .{ .blocks_fp = fp, .counts = counts, .attempts = attempts, .slots = slots, .dead = dead, .a = a };
    @memset(s.counts, 0);
    @memset(s.attempts, 0);
    @memset(s.slots, null);
    @memset(s.dead, false);
    states.put(a, key, s) catch {
        a.free(counts);
        a.free(attempts);
        a.destroy(s);
        return null;
    };
    return s;
}

/// Recursive-seam method tier: a member-dispatched body reaches neither the framed entry hook nor,
/// when fusable, any frame, so the seam counts and runs it. Only a deopt-free body (`can_deopt ==
/// false`) is served here, RETURN being its only outcome.
pub const SeamProbe = union(enum) { run: *const CompiledLoop, compile, no };

pub fn methodSeamPeek(func: *const Func) ?*const CompiledLoop {
    if (!funcEnabled()) return null;
    if (probeWord(func).load(.monotonic) & PROBE_COMPILED == 0) return null;
    const fj = (states.get(@intFromPtr(func))) orelse return null;
    if (func.blocks.len == 0 or fj.blocks_fp != @intFromPtr(func.blocks.ptr)) return null;
    if (fj.func_jit) |*cl| {
        if (cl.method_mode and !cl.can_deopt) return cl;
    }
    return null;
}

/// Compiled-unit lookup for the seam, keyed by function pointer, because `forFunc` is a threadlocal
/// hash probe the seam would run on every member call. Entries carry the state generation, so a
/// rebuilt `states` map invalidates them wholesale.
const SeamEntry = struct { fp: usize = 0, gen: u32 = 0, cl: ?*CompiledLoop = null };
threadlocal var seam_cache: [64]SeamEntry = @splat(.{});
threadlocal var seam_gen: u32 = 1;

inline fn seamSlot(func: *const Func) *SeamEntry {
    return &seam_cache[(@intFromPtr(func) >> 4) & (seam_cache.len - 1)];
}

pub fn methodSeamProbe(func: *const Func) SeamProbe {
    if (!funcEnabled()) return .no;
    const pr = probeWord(func).load(.monotonic);
    if (pr & PROBE_DECLINED != 0) return .no;
    if (pr & PROBE_COMPILED != 0) {
        const slot = seamSlot(func);
        if (slot.fp == @intFromPtr(func) and slot.gen == seam_gen) {
            if (slot.cl) |cl| {
                if (cl.method_mode and !cl.can_deopt) return .{ .run = cl };
            }
            return .no;
        }
        const fj = forFunc(func) orelse return .no;
        if (fj.func_jit) |*cl| {
            slot.* = .{ .fp = @intFromPtr(func), .gen = seam_gen, .cl = cl };
            if (cl.method_mode and !cl.can_deopt) return .{ .run = cl };
            return .no;
        }
        // Another thread compiled; this one still needs its own copy.
        if (fj.func_tried) return .no;
        return .compile;
    }
    if (probeCount(func)) return .compile;
    return .no;
}

/// One-shot compile for a seam-probed body; marks the state tried either way.
pub fn methodSeamCompile(module: *const Module, func: *const Func, params: []const Value, resolver: ?MemberResolver, virt_resolver: ?VirtResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver, user: ?*anyopaque) void {
    // A lambda's captures are not in hand here; leave it untried for the hooks that hold them.
    if (func.is_lambda) return;
    const fj = forFunc(func) orelse return;
    if (fj.func_tried) return;
    fj.func_tried = true;
    const compiled = tryCompileFunc(metadata_allocator, module, func, params, &.{}, resolver, virt_resolver, field_resolver, field_nn_resolver, user) catch null;
    if (compiled) |cl| {
        if (debugEnabled()) std.debug.print("[jit] compiled method {s} (fqn={s} mfields={d} sites={d} guard={x} deopt-free={})\n", .{ func.name, func.fqn, cl.method_fields.len, cl.call_sites.len, cl.guard_class, !cl.can_deopt });
        fj.func_jit = cl;
        noteCompiled();
        _ = probeWord(func).fetchOr(PROBE_COMPILED, .monotonic);
    } else {
        if (debugEnabled()) std.debug.print("[jit]   method-tier declined {s}\n", .{func.name});
        _ = probeWord(func).fetchOr(PROBE_DECLINED, .monotonic);
    }
}

/// Yields a hot fused body is allowed before the tier must have produced something. A body served
/// by a path carrying no compile hook would otherwise yield forever, neither compiled nor declined.
const YIELD_BUDGET: u32 = HOT_THRESHOLD;

pub fn fusedShouldYieldToFuncTier(func: *const Func) bool {
    if (!funcEnabled()) return false;
    const pr = probeWord(func).load(.monotonic);
    if (pr & PROBE_DECLINED != 0) return false;
    if (pr & PROBE_COMPILED == 0 and (pr & PROBE_COUNT_MASK) >= HOT_THRESHOLD + YIELD_BUDGET) {
        // Hot long enough that a compile would have happened; stop paying the framed path for it.
        _ = probeWord(func).fetchOr(PROBE_DECLINED, .monotonic);
        if (debugEnabled()) std.debug.print("[jit]   yield budget spent, staying fused: {s}\n", .{func.name});
        return false;
    }
    if (pr & PROBE_COMPILED != 0) {
        // Compiled is not the same as RUNNABLE HERE: the seam refuses a unit that can deopt, so yielding
        // for one buys a framed activation per call and runs the compiled code never.
        return methodSeamProbe(func) == .run;
    }
    return probeCount(func);
}

/// Compiles a callee reached from COMPILED code. The tier's probes live on the interpreter's call
/// paths, so a function only ever called from compiled code is never counted and its caller
/// trampolines out every iteration. Offered once, under the bookkeeping that blocks a retry.
pub fn compileCalleeForCall(
    module: *const Module,
    func: *const Func,
    params: []const Value,
    resolver: ?MemberResolver,
    virt_resolver: ?VirtResolver,
    field_resolver: ?FieldResolver,
    field_nn_resolver: ?FieldResolver,
    resolver_user: ?*anyopaque,
) ?*const CompiledLoop {
    if (!funcEnabled()) return null;
    const pr = probeWord(func).load(.monotonic);
    if (pr & PROBE_DECLINED != 0) return null;
    const fj = forFunc(func) orelse return null;
    if (fj.func_jit) |*cl| return cl;
    if (fj.func_tried) return null;
    fj.func_tried = true;
    const compiled = tryCompileFunc(metadata_allocator, module, func, params, &.{}, resolver, virt_resolver, field_resolver, field_nn_resolver, resolver_user) catch null;
    if (compiled == null) {
        if (debugEnabled()) std.debug.print("[jit]   callee-for-call declined {s}\n", .{func.name});
        _ = probeWord(func).fetchOr(PROBE_DECLINED, .monotonic);
        return null;
    }
    fj.func_jit = compiled;
    noteCompiled();
    _ = probeWord(func).fetchOr(PROBE_COMPILED, .monotonic);
    if (debugEnabled()) std.debug.print("[jit] compiled callee {s} for a native call\n", .{func.name});
    return &fj.func_jit.?;
}

pub fn maybeRunHotFunc(module: *const Module, func: *const Func, regs: *std.ArrayList(Value), params: []const Value, captures: []const Value, allocator: Allocator, tramp: ?TrampFn, user: ?*anyopaque, resolver: ?MemberResolver, virt_resolver: ?VirtResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver) ?FuncOutcome {
    if (!funcEnabled()) return null;
    // Shared probe first: a declined body costs one atomic load per activation, never a map walk.
    const pr = probeWord(func).load(.monotonic);
    if (pr & PROBE_DECLINED != 0) return null;
    if (pr & PROBE_COMPILED == 0) {
        if (!probeCount(func)) return null;
    }
    const fj = forFunc(func) orelse return null;
    if (!fj.func_tried) {
        fj.func_tried = true;
        const compiled = tryCompileFunc(metadata_allocator, module, func, params, captures, resolver, virt_resolver, field_resolver, field_nn_resolver, user) catch |e| blk: {
            if (debugEnabled()) std.debug.print("[jit]   fdecl {s}: ERR {s}\n", .{ func.name, @errorName(e) });
            break :blk null;
        };
        if (compiled == null) {
            if (debugEnabled()) std.debug.print("[jit]   func-tier declined {s}\n", .{func.name});
            _ = probeWord(func).fetchOr(PROBE_DECLINED, .monotonic);
            return null;
        }
        _ = probeWord(func).fetchOr(PROBE_COMPILED, .monotonic);
        if (debugEnabled()) std.debug.print("[jit] compiled function {s} (fqn={s} p0={s} mfields={d} sites={d} method={} guard={x}) n_slots={d} n_regs={d}\n", .{ func.name, func.fqn, if (func.params.len > 0) func.params[0].name else "-", compiled.?.method_fields.len, compiled.?.call_sites.len, compiled.?.method_mode, compiled.?.guard_class, compiled.?.n_slots, compiled.?.n_regs });
        fj.func_jit = compiled;
        noteCompiled();
    }
    if (fj.func_jit == null) return null;
    const cl = &fj.func_jit.?;
    if (params.len < cl.n_params) return null;
    if (regs.items.len < cl.n_regs) {
        regs.appendNTimes(regsGrowAlloc(allocator), .Unit, cl.n_regs - regs.items.len) catch return null;
    }
    for (cl.obj_param_loads) |opl| {
        if (opl.param_idx >= params.len or opl.reg >= regs.items.len) return null;
        // The body was specialized on an Instance here, so any other kind, an unboxed value-class
        // receiver or a null, declines to the interpreter before anything runs.
        if (params[opl.param_idx] != .Instance) return null;
        regs.items[opl.reg] = params[opl.param_idx];
    }
    for (cl.capture_loads) |cpl| {
        if (cpl.param_idx >= captures.len or cpl.reg >= regs.items.len) return null;
        regs.items[cpl.reg] = captures[cpl.param_idx];
    }
    var stack_slots: [192]i64 = undefined;
    var heap_slots: ?[]i64 = null;
    defer if (heap_slots) |hs| metadata_allocator.free(hs);
    const slots: []i64 = if (cl.n_slots <= stack_slots.len)
        stack_slots[0..cl.n_slots]
    else blk: {
        heap_slots = metadata_allocator.alloc(i64, cl.n_slots) catch return null;
        break :blk heap_slots.?;
    };
    var stack_tags: [128]u8 = undefined;
    var heap_tags: ?[]u8 = null;
    defer if (heap_tags) |ht| metadata_allocator.free(ht);
    const rtags: []u8 = if (cl.n_regs <= stack_tags.len)
        stack_tags[0..cl.n_regs]
    else blk: {
        heap_tags = metadata_allocator.alloc(u8, cl.n_regs) catch return null;
        break :blk heap_tags.?;
    };
    return runFunc(cl, regs.items, params, slots, rtags, tramp, user);
}

/// Whether this tier already gave up on the loop with that header. The fused walker asks before
/// handing its loop over, so a body the JIT cannot compile keeps its cheaper fused walk.
pub fn loopDeclined(func: *const Func, block: u32) bool {
    const s = states.get(@intFromPtr(func)) orelse return false;
    if (s.blocks_fp != @intFromPtr(func.blocks.ptr)) return false;
    return block < s.dead.len and s.dead[block];
}

/// Compiles the hot loop at `header` now, for a tier that must commit before handing it over: the
/// fused walker's move to a real frame is one-way and framed is slower than the walk it left, so it
/// moves only when compiled code exists. A refusal is recorded as the block-entry probe records it.
pub fn compileHotLoopFor(
    module: *const Module,
    func: *const Func,
    header: BlockId,
    regs: []const Value,
    resolver: ?MemberResolver,
    virt_resolver: ?VirtResolver,
    field_resolver: ?FieldResolver,
    field_nn_resolver: ?FieldResolver,
    resolver_user: ?*anyopaque,
) bool {
    const fj = forFunc(func) orelse return false;
    const bi = header.int();
    if (bi >= fj.counts.len) return false;
    if (fj.slots[bi] != null) return true;
    if (fj.dead[bi]) return false;
    var transient = false;
    const compiled = tryCompile(metadata_allocator, module, func, header, regs, resolver, virt_resolver, field_resolver, field_nn_resolver, resolver_user, &transient) catch null;
    if (compiled == null) {
        fj.attempts[bi] += 1;
        if (transient and fj.attempts[bi] < MAX_COMPILE_ATTEMPTS) return false;
        fj.dead[bi] = true;
        return false;
    }
    const clp = fj.a.create(CompiledLoop) catch return false;
    clp.* = compiled.?;
    fj.slots[bi] = clp;
    fj.counts[bi] = HOT_THRESHOLD;
    noteCompiled();
    @constCast(func).bc_jit_owned = true;
    if (debugEnabled()) std.debug.print("[jit] compiled {s} block {d} (for the fused walker)\n", .{ func.name, bi });
    return true;
}

/// Stream-tier back edge: the bytecode tier follows branches inside its own loop, so a hot loop
/// never reaches the frame loop's block-entry probe. True gives the block back to the frame loop.
pub fn streamBackEdge(fj: *FuncJit, block: u32) bool {
    if (block >= fj.counts.len) return false;
    if (fj.slots[block] != null) return true;
    if (fj.dead[block]) return false;
    fj.counts[block] +|= 1;
    return fj.counts[block] >= HOT_THRESHOLD;
}

/// Interpreter hook: counts the entry to block `cur` and, once hot, compiles and runs the natural
/// loop with that header, returning the resume point with registers reboxed. `KLIO_JIT` only.
pub fn maybeRunHot(module: *const Module, func: *const Func, regs: *std.ArrayList(Value), allocator: Allocator, cur: BlockId, tramp: ?TrampFn, user: ?*anyopaque, resolver: ?MemberResolver, virt_resolver: ?VirtResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver) ?Resume {
    const fj = forFunc(func) orelse return null;
    return maybeRunHotPre(fj, module, func, regs, allocator, cur, tramp, user, resolver, virt_resolver, field_resolver, field_nn_resolver);
}

/// The per-block-entry probe with the per-FUNCTION state already resolved.
pub fn maybeRunHotPre(fj: *FuncJit, module: *const Module, func: *const Func, regs: *std.ArrayList(Value), allocator: Allocator, cur: BlockId, tramp: ?TrampFn, user: ?*anyopaque, resolver: ?MemberResolver, virt_resolver: ?VirtResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver) ?Resume {
    const bi = cur.int();
    if (bi >= fj.counts.len) return null;

    if (fj.slots[bi] == null) {
        if (fj.dead[bi]) return null;
        fj.counts[bi] += 1;
        if (debugEnabled() and fj.counts[bi] == 1)
            std.debug.print("[jit]   probe reached {s} b{d}\n", .{ func.name, bi });
        if (fj.counts[bi] < HOT_THRESHOLD) return null;
        var transient = false;
        const compiled = tryCompile(metadata_allocator, module, func, cur, regs.items, resolver, virt_resolver, field_resolver, field_nn_resolver, user, &transient) catch null;
        if (compiled == null) {
            // A transient bail is worth retrying a few times; a permanent bail is cached immediately.
            fj.attempts[bi] += 1;
            if (transient and fj.attempts[bi] < MAX_COMPILE_ATTEMPTS) {
                fj.counts[bi] = HOT_THRESHOLD - RETRY_GAP;
                return null;
            }
            fj.dead[bi] = true;
            return null;
        }
        if (debugEnabled()) std.debug.print("[jit] compiled {s} block {d}\n", .{ func.name, bi });
        // Compiled code deopts to an instruction index, so this function's streams must stop fusing.
        @constCast(func).bc_jit_owned = true;
        const clp = fj.a.create(CompiledLoop) catch return null;
        clp.* = compiled.?;
        fj.slots[bi] = clp;
        noteCompiled();
    }

    const cl = fj.slots[bi].?;

    if (regs.items.len < cl.n_regs) {
        regs.appendNTimes(regsGrowAlloc(allocator), .Unit, cl.n_regs - regs.items.len) catch return null;
    }
    // Slots live in a per-activation buffer: a trampolined call can re-enter this hook for a nested
    // hot loop, and that inner run must not alias or reallocate the outer loop's live slots.
    var stack_slots: [192]i64 = undefined;
    var heap_slots: ?[]i64 = null;
    defer if (heap_slots) |hs| metadata_allocator.free(hs);
    const slots: []i64 = if (cl.n_slots <= stack_slots.len)
        stack_slots[0..cl.n_slots]
    else blk: {
        heap_slots = metadata_allocator.alloc(i64, cl.n_slots) catch return null;
        break :blk heap_slots.?;
    };
    var stack_tags: [128]u8 = undefined;
    var heap_tags: ?[]u8 = null;
    defer if (heap_tags) |ht| metadata_allocator.free(ht);
    const rtags: []u8 = if (cl.n_regs <= stack_tags.len)
        stack_tags[0..cl.n_regs]
    else blk: {
        heap_tags = metadata_allocator.alloc(u8, cl.n_regs) catch return null;
        break :blk heap_tags.?;
    };
    return switch (runLoop(cl, regs.items, slots, rtags, tramp, user)) {
        .resume_at => |res| res,
        .bail => null,
    };
}
