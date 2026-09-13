//! The native host surface: the compiled-code function tables, the leaf
//! native entry points, and the per-opcode callbacks the JIT emits.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BinOp = ir.BinOp;
const Func = ir.Func;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const ConstId = ir.ConstId;
const Inst = ir.Inst;
const Module = ir.Module;
const TypeRef = ir.TypeRef;

const exec_call = @import("../exec_call.zig");

const argNamesAllNull = exec_call.argNamesAllNull;
const constStr = exec_call.constStr;
const execArmCall = exec_call.execArmCall;
const freeArgNames = exec_call.freeArgNames;
const resolveArgNames = exec_call.resolveArgNames;
const testing = std.testing;

const parent = @import("../eval.zig");
const ev_activation = @import("activation.zig");
const ev_diag = @import("diag.zig");
const ev_enter = @import("enter.zig");
const ev_exec = @import("exec.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_inst = @import("inst.zig");
const ev_leaf = @import("leaf.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");

const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const FlatCallSite = ev_flow.FlatCallSite;
const Frame = ev_frame.Frame;
const ParkPoint = ev_flow.ParkPoint;
const Step = ev_flow.Step;
const afterStep = ev_exec.afterStep;
const binFast = ev_exec.binFast;
const constToValue = ev_values.constToValue;
const discardFlatReq = ev_activation.discardFlatReq;
const errResult = ev_flow.errResult;
const execArmBinOp = ev_inst.execArmBinOp;
const execInst = ev_inst.execInst;
const funcOwnedBy = ev_enter.funcOwnedBy;
const fusedEdgeGuard = ev_exec.fusedEdgeGuard;
const leafExprServe = ev_enter.leafExprServe;
const leafReqServable = ev_leaf.leafReqServable;
const nowMonotonicMs = ev_diag.nowMonotonicMs;
const ok = ev_flow.ok;
const raiseStep = ev_flow.raiseStep;
const scalarBin = ev_exec.scalarBin;
const spinDumpMaybe = ev_diag.spinDumpMaybe;
const wallCapFire = ev_diag.wallCapFire;
const writeFastU = ev_exec.writeFastU;

/// Compiled body for one fid, run by the frame loop in place of the bytecode stream. The
/// emitted C touches no interpreter state: every op calls a `nativeOp*` helper over a `NativeCtx`.
pub const NativeFn = *const fn (ctx: ?*anyopaque, entry_block: u32) callconv(.c) void;

var native_mutex: runtime.SpinMutex = .{};

const NativeEntry = struct { f: NativeFn, fqn: []const u8 };

var native_table: std.AutoHashMapUnmanaged(u32, NativeEntry) = .empty;

pub var native_any: std.atomic.Value(bool) = .init(false);

/// Set at the first lookup; a later registration would race the lock-free reads and is refused.
var native_frozen: std.atomic.Value(bool) = .init(false);

var native_slots: []const ?NativeEntry = &.{};

/// Flatten the registered table into a fid-indexed array and close registration.
fn freezeNativeTable() void {
    native_mutex.lock();
    defer native_mutex.unlock();
    if (native_frozen.load(.acquire)) return;
    var max_fid: u32 = 0;
    var it = native_table.keyIterator();
    while (it.next()) |k| max_fid = @max(max_fid, k.*);
    if (std.heap.smp_allocator.alloc(?NativeEntry, max_fid + 1)) |slots| {
        @memset(slots, null);
        var ei = native_table.iterator();
        while (ei.next()) |e| slots[e.key_ptr.*] = e.value_ptr.*;
        native_slots = slots;
    } else |_| {}
    native_frozen.store(true, .release);
}

/// Registration runs from the transpiled binary's `main`, before the program. `fqn` guards the
/// fid: on a mismatch the lookup falls back to interpretation rather than a wrong body.
pub fn registerNative(fid: u32, f: NativeFn, fqn: []const u8) void {
    native_mutex.lock();
    defer native_mutex.unlock();
    const owned = std.heap.smp_allocator.dupe(u8, fqn) catch return;
    if (native_frozen.load(.acquire)) return; // execution started; the table is read lock-free now
    native_table.put(std.heap.smp_allocator, fid, .{ .f = f, .fqn = owned }) catch return;
    native_any.store(true, .release);
}

pub fn nativeFor(fid: u32, fqn: []const u8) ?NativeFn {
    if (!native_any.load(.acquire)) return null;
    if (!native_frozen.load(.acquire)) freezeNativeTable();
    const slots = native_slots;
    if (fid >= slots.len) return null;
    const e = slots[fid] orelse return null;
    if (!std.mem.eql(u8, e.fqn, fqn)) {
        if (runtime.envOnce("KLIO_NATIVE_TRACE") != null) {
            std.debug.print("[native-fqn] fid={d} table={s} frame={s}\n", .{ fid, e.fqn, fqn });
        }
        return null;
    }
    return e.f;
}

/// Scalar-replay leaf body (`kl_<fid>`) over (int64 value, genre) pairs: genres 0 Int, 1 Long,
/// 2 Bool, 3 Unit, 4 Char, 5 Double, 6 Float, 7 opaque, 8 instance handle. Zero = bailed.
pub const NativeLeafFn = *const fn (
    ctx: ?*anyopaque,
    ev: *NativeEdgeView,
    argv: [*]const i64,
    argg: [*]const i32,
    ret: *i64,
    retg: *i32,
    depth: u32,
    aux: [*]i64,
    auxg: [*]i32,
) callconv(.c) i32;

/// Ctor-tail return (`*retg == leaf_ctor_tail_genre`): `*ret` is block<<16 | inst index into
/// the leaf's own IR and `aux`/`auxg` hold the ctor args, so the gate constructs ONCE, exactly.
pub const leaf_ctor_tail_genre: i32 = 200;

/// Zig mirror of the emitted C `klio_ctor_site` (see klio_rt.h).
pub const CtorSite = extern struct {
    fqn: [*:0]const u8,
    block: u32,
    inst: u32,
    memo: u64,
};

/// Threadlocal interp edge view, rebuilt only when the serving host changes.
threadlocal var leaf_ev_cache: NativeEdgeView = undefined;

threadlocal var leaf_ev_host: ?*anyopaque = null;

threadlocal var leaf_ev_counter: u64 = 0;

const NativeLeafEntry = struct { f: NativeLeafFn, fqn: []const u8 };

var native_leaf_table: std.AutoHashMapUnmanaged(u32, NativeLeafEntry) = .empty;

/// FQN-keyed leaves: a prebuilt leaf library cannot use fids, which are not cross-process stable.
var native_leaf_by_fqn: std.StringHashMapUnmanaged(NativeLeafFn) = .empty;

var native_leaf_any: std.atomic.Value(bool) = .init(false);

/// One character per declared param type, appended to a leaf's fqn so OVERLOADS cannot alias.
pub fn leafSigChar(ty: []const u8) u8 {
    const base = if (std.mem.findScalarLast(u8, ty, '.')) |d| ty[d + 1 ..] else ty;
    const eq = std.mem.eql;
    if (eq(u8, base, "Int")) return 'i';
    if (eq(u8, base, "Long")) return 'l';
    if (eq(u8, base, "Boolean")) return 'b';
    if (eq(u8, base, "Char")) return 'c';
    if (eq(u8, base, "Double")) return 'd';
    if (eq(u8, base, "Float")) return 'f';
    if (eq(u8, base, "Short")) return 's';
    if (eq(u8, base, "Byte")) return 'y';
    return 'o';
}

/// `fqn#<sig>`, the collision-proof registration key: a non-scalar param contributes its declared
/// type HEAD in braces, so same-fqn object-receiver overloads can never serve each other.
pub fn leafKeyAlloc(gpa2: std.mem.Allocator, f: *const Func) ?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(gpa2, f.fqn) catch return null;
    buf.append(gpa2, '#') catch return null;
    for (f.params) |*p| {
        const c = leafSigChar(p.ty.name);
        if (c != 'o') {
            buf.append(gpa2, c) catch return null;
            continue;
        }
        const nm = p.ty.name;
        const head = if (std.mem.findScalarLast(u8, nm, '.')) |d| nm[d + 1 ..] else nm;
        if (head.len == 0) {
            buf.append(gpa2, 'o') catch return null;
        } else {
            buf.append(gpa2, '{') catch return null;
            buf.appendSlice(gpa2, head) catch return null;
            buf.append(gpa2, '}') catch return null;
        }
    }
    return buf.toOwnedSlice(gpa2) catch null;
}

test "leafKeyAlloc separates object-receiver overloads by type head" {
    const gpa2 = std.testing.allocator;
    const mk = struct {
        fn key(al: std.mem.Allocator, ty_name: []const u8) ![]u8 {
            var params = [_]ir.Param{.{
                .name = "this",
                .ty = .{ .name = ty_name, .nullable = false, .args = &.{} },
                .default = null,
                .is_property = false,
                .is_vararg = false,
                .has_default = false,
            }};
            var f = std.mem.zeroInit(Func, .{
                .fqn = "kotlin.collections.iterator",
                .name = "iterator",
                .params = params[0..],
            });
            return leafKeyAlloc(al, &f) orelse error.OutOfMemory;
        }
    };
    const a2 = try mk.key(gpa2, "Map");
    defer gpa2.free(a2);
    const b2 = try mk.key(gpa2, "Iterator");
    defer gpa2.free(b2);
    try std.testing.expect(!std.mem.eql(u8, a2, b2));
    try std.testing.expectEqualStrings("kotlin.collections.iterator#{Map}", a2);
}

pub fn registerNativeLeafFqn(fqn: []const u8, f: NativeLeafFn) void {
    native_mutex.lock();
    defer native_mutex.unlock();
    const owned = std.heap.smp_allocator.dupe(u8, fqn) catch return;
    native_leaf_by_fqn.put(std.heap.smp_allocator, owned, f) catch return;
    native_leaf_any.store(true, .release);
}

pub fn registerNativeLeaf(fid: u32, f: NativeLeafFn, fqn: []const u8) void {
    native_mutex.lock();
    defer native_mutex.unlock();
    const owned = std.heap.smp_allocator.dupe(u8, fqn) catch return;
    native_leaf_table.put(std.heap.smp_allocator, fid, .{ .f = f, .fqn = owned }) catch return;
    native_leaf_any.store(true, .release);
}

var leaf_diag_serve = std.atomic.Value(u64).init(0);

var leaf_diag_bail = std.atomic.Value(u64).init(0);

var leaf_diag_try = std.atomic.Value(u64).init(0);

var leaf_diag_nokey = std.atomic.Value(u64).init(0);

pub fn leafDiagDump() void {
    if (runtime.envOnce("KLIO_LEAF_DIAG") == null) return;
    std.debug.print("[leaf-diag] served={d} bailed={d} tried={d} nokey={d}\n", .{ leaf_diag_serve.load(.monotonic), leaf_diag_bail.load(.monotonic), leaf_diag_try.load(.monotonic), leaf_diag_nokey.load(.monotonic) });
}

pub const LeafOutcome = union(enum) { val: Value, raise: EvalError };

/// Value-level scalar-replay leaf gate. Null = not leaf-served and the caller re-runs the pure
/// body exactly; a genre-200 ctor-tail constructs ONCE through the host, never re-run.
pub fn tryLeafValues(comptime H: type, allocator: Allocator, module: *const Module, cf: *const Func, args: []const Value, host: *H, nctx: ?*NativeCtx) Allocator.Error!?LeafOutcome {
    if (!native_leaf_any.load(.acquire)) return null;
    if (args.len > 8 or args.len != cf.params.len) return null;

    // Per-Func route memo: the table is write-once, so one resolution is final.
    _ = leaf_diag_try.fetchAdd(1, .monotonic);
    const route = cf.leaf_route.load(.acquire);
    const klf: NativeLeafFn = switch (route) {
        0 => blk_r: {
            // A symbol the link step settled onto a native binding never runs its lowered body, so
            // serving the leaf would bypass the host intrinsic. Checked once; the memo pins it.
            const runs_body = if (comptime @hasDecl(H, "funcRunsItsBody"))
                host.funcRunsItsBody(cf.id)
            else
                true;
            const f0: ?NativeLeafFn = if (!runs_body)
                null
            else
                nativeLeafFor(cf.id.int(), cf.fqn) orelse nativeLeafForFunc(cf);
            if (f0 == null) _ = leaf_diag_nokey.fetchAdd(1, .monotonic);
            const enc: usize = if (f0) |fp| @intFromPtr(fp) else 1;
            @constCast(cf).leaf_route.store(enc, .release);
            break :blk_r f0 orelse return null;
        },
        1 => return null,
        else => @ptrFromInt(route),
    };
    var argv: [8]i64 = undefined;
    var argg: [8]i32 = undefined;
    for (args, 0..) |a, i| {
        switch (a) {
            .Int => |v| {
                argv[i] = v;
                argg[i] = 0;
            },
            .Long => |v| {
                argv[i] = v;
                argg[i] = 1;
            },
            .Bool => |v| {
                argv[i] = @intFromBool(v);
                argg[i] = 2;
            },
            .Unit => {
                argv[i] = 0;
                argg[i] = 3;
            },
            .Char => |v| {
                argv[i] = v;
                argg[i] = 4;
            },
            .Double => |v| {
                argv[i] = @bitCast(v);
                argg[i] = 5;
            },
            .Float => |v| {
                argv[i] = @as(u32, @bitCast(v));
                argg[i] = 6;
            },
            .Instance => |inst| {
                // Genre 8: a borrowed instance HANDLE, the raw cell, rooted by the caller's frame and
                // never moved by the GC. Leaf field reads go through the view's field_route.
                argv[i] = @bitCast(@as(u64, @intFromPtr(inst.cell)));
                argg[i] = 8;
            },
            else => {
                // Genre 7: opaque cargo, and every emitted op on genre > 6 bails.
                argv[i] = 0;
                argg[i] = 7;
            },
        }
    }
    var ev: NativeEdgeView = undefined;
    if (nctx) |nc| {
        nativeEdgeView(nc, &ev);
        ev.route_ctx = @ptrCast(host);
        ev.field_route = &LeafFieldRoute(H).route;
        ev.type_route = &LeafTypeRoute(H).route;
        ev.statics_route = &LeafStaticsRoute(H).route;
    } else {
        // Threadlocal edge view: every pointer in it is process- or thread-stable, so a call refreshes
        // only the mode flags. The counter accumulates across calls; the guard thresholds per call.
        if (leaf_ev_host != @as(?*anyopaque, @ptrCast(host))) {
            leaf_ev_cache = .{
                .rare = &leafEdgeRareInterp,
                .route_ctx = @ptrCast(host),
                .field_route = &LeafFieldRoute(H).route,
                .type_route = &LeafTypeRoute(H).route,
                .statics_route = &LeafStaticsRoute(H).route,
                .counter = &leaf_ev_counter,
                .idle = runtime.gc.idleTickPtr(),
                .abandonable = runtime.abandonablePtr(),
                .rb_abandon = runtime.runBoundaryAbandonPtr(),
                .abandon_req = runtime.abandonRequestedPtr(),
                .gc_pending = runtime.gc.pendingFlagPtr(),
                .gc_on = 0,
                .always = 0,
            };
            leaf_ev_host = @ptrCast(host);
        }
        leaf_ev_cache.gc_on = @intFromBool(runtime.gc.gc_enabled);
        leaf_ev_cache.always = @intFromBool(runtime.gc.stressActive());
    }
    const evp: *NativeEdgeView = if (nctx != null) &ev else &leaf_ev_cache;
    var rl: i64 = 0;
    var rg: i32 = 0;
    var aux: [8]i64 = undefined;
    var auxg: [8]i32 = undefined;
    const cctx: ?*anyopaque = if (nctx) |nc| @ptrCast(nc) else null;
    if (klf(cctx, evp, &argv, &argg, &rl, &rg, 0, &aux, &auxg) == 0) {
        _ = leaf_diag_bail.fetchAdd(1, .monotonic);
        // Bail damper: a leaf that has NEVER served and keeps bailing is structural for this program's
        // call shapes, so stop attempting it. The served bit is sticky, so a genre-mixed fn stays on.
        const probe = @constCast(cf).leaf_bail_probe.fetchAdd(1, .monotonic);
        if (probe & 0x8000_0000 == 0 and (probe & 0x7FFF_FFFF) >= 64) {
            @constCast(cf).leaf_route.store(1, .release);
        }
        return null;
    }
    _ = leaf_diag_serve.fetchAdd(1, .monotonic);
    const probe0 = cf.leaf_bail_probe.load(.monotonic);
    if (probe0 & 0x8000_0000 == 0) {
        _ = @constCast(cf).leaf_bail_probe.fetchOr(0x8000_0000, .monotonic);
    }
    if (runtime.envOnce("KLIO_LEAF_TRACE_SERVE") != null) {
        std.debug.print("[leaf-serve] {s} rg={d} rl={d}\n", .{ cf.fqn, rg, rl });
    }
    if (rg == leaf_ctor_tail_genre) {
        const sd: *CtorSite = @ptrFromInt(@as(usize, @bitCast(rl)));
        const memo = @atomicLoad(u64, &sd.memo, .acquire);
        const site_fid: u32 = if (memo != 0) @intCast(memo - 1) else fid_blk: {
            const want = std.mem.span(sd.fqn);
            const hash_pos = std.mem.findScalarLast(u8, want, '#') orelse return null;
            const want_fqn = want[0..hash_pos];
            const dot = std.mem.findScalarLast(u8, want_fqn, '.') orelse return null;
            var found: ?u32 = null;
            for (module.funcsBySimpleName(want_fqn[dot + 1 ..])) |cand| {
                const cf2 = module.funcById(cand) orelse continue;
                if (!std.mem.eql(u8, cf2.fqn, want_fqn)) continue;
                var buf2: [512]u8 = undefined;
                var fbs2 = std.heap.FixedBufferAllocator.init(&buf2);
                const k2 = leafKeyAlloc(fbs2.allocator(), cf2) orelse continue;
                if (std.mem.eql(u8, k2, want)) {
                    found = cand.int();
                    break;
                }
            }
            const got = found orelse return null;
            @atomicStore(u64, &sd.memo, @as(u64, got) + 1, .release);
            break :fid_blk got;
        };
        const tbi: usize = sd.block;
        const tii: usize = sd.inst;
        const sf = module.funcById(ir.FuncId.from(site_fid)) orelse return null;
        if (tbi >= sf.blocks.len or tii >= sf.blocks[tbi].insts.len) return null;
        const SiteCtor = struct { class: ir.ClassId, n_args: u32, arg_names: []const ?ir.ConstId, heads: []const ?ir.ConstId };
        const sc: SiteCtor = switch (sf.blocks[tbi].insts[tii]) {
            .NewInstance => |*ni| .{ .class = ni.class, .n_args = ni.n_args, .arg_names = ni.arg_names, .heads = ni.arg_static_heads },
            .CallMemberOrGlobal => |*cg| if (cg.class) |cl| SiteCtor{ .class = cl, .n_args = cg.n_args, .arg_names = cg.arg_names, .heads = &.{} } else return null,
            else => return null,
        };
        var vals: [8]Value = undefined;
        for (0..sc.n_args) |ai| {
            vals[ai] = switch (auxg[ai]) {
                0 => .{ .Int = @intCast(aux[ai]) },
                1 => .{ .Long = aux[ai] },
                2 => .{ .Bool = aux[ai] != 0 },
                3 => .Unit,
                4 => .{ .Char = @intCast(aux[ai]) },
                5 => .{ .Double = @bitCast(aux[ai]) },
                6 => .{ .Float = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(aux[ai]))))) },
                // A genre-8 aux is a borrowed handle used as a ctor arg; the construction
                // retains what it stores, and the caller's frame roots it for the call.
                8 => .{ .Instance = .{ .cell = @ptrFromInt(@as(usize, @bitCast(aux[ai]))) } },
                else => return null,
            };
        }
        const names = try resolveArgNames(allocator, module, sc.arg_names);
        defer freeArgNames(allocator, names);
        const static_heads = try resolveArgNames(allocator, module, sc.heads);
        defer freeArgNames(allocator, static_heads);
        if (comptime @hasDecl(H, "setCtorArgStaticHeads")) {
            host.setCtorArgStaticHeads(static_heads);
        }
        switch (try host.newInstanceNamed(allocator, sc.class, vals[0..sc.n_args], names, null)) {
            .ok => |v| return .{ .val = v },
            .err => |e| return .{ .raise = e },
        }
    }
    const v: Value = switch (rg) {
        0 => .{ .Int = @intCast(rl) },
        1 => .{ .Long = rl },
        2 => .{ .Bool = rl != 0 },
        3 => .Unit,
        4 => .{ .Char = @intCast(rl) },
        5 => .{ .Double = @bitCast(rl) },
        6 => .{ .Float = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(rl))))) },
        8 => blk8: {
            // A genre-8 handle coming BACK is a borrowed cell becoming an owned
            // Value: retain before it escapes the call window.
            const iv = Value{ .Instance = .{ .cell = @ptrFromInt(@as(usize, @bitCast(rl))) } };
            iv.retain();
            break :blk8 iv;
        },
        else => return null,
    };
    return .{ .val = v };
}

pub fn tryLeafCall(comptime H: type, allocator: Allocator, frame: *Frame, c: anytype, host: *H, nctx: ?*NativeCtx) Allocator.Error!?Step {
    if (!native_leaf_any.load(.acquire)) return null;
    if (c.type_args.len != 0 or !argNamesAllNull(c.arg_names)) return null;
    const cf = frame.module.funcById(c.func) orelse return null;
    const base = c.args.int();
    if (base + c.n_args > frame.regs.items.len) return null;
    const outcome = (try tryLeafValues(H, allocator, frame.module, cf, frame.regs.items[base .. base + c.n_args], host, nctx)) orelse return null;
    switch (outcome) {
        .val => |v| {
            try frame.write(c.dst, v);
            return .cont;
        },
        .raise => |e| return raiseStep(frame, e),
    }
}

fn nativeLeafFor(fid: u32, fqn: []const u8) ?NativeLeafFn {
    if (!native_leaf_any.load(.acquire)) return null;
    native_mutex.lock();
    defer native_mutex.unlock();
    if (native_leaf_table.get(fid)) |e| {
        if (std.mem.eql(u8, e.fqn, fqn)) return e.f;
    }
    return null;
}

/// Fqn-map lookup by the collision-proof key (fqn#sig).
fn nativeLeafForFunc(cf: *const Func) ?NativeLeafFn {
    if (!native_leaf_any.load(.acquire)) return null;
    var buf: [512]u8 = undefined;
    var fbs = std.heap.FixedBufferAllocator.init(&buf);
    const key = leafKeyAlloc(fbs.allocator(), cf) orelse return null;
    native_mutex.lock();
    defer native_mutex.unlock();
    return native_leaf_by_fqn.get(key);
}

var native_expect_funcs: usize = 0;

var native_expect_consts: usize = 0;

/// The emitted operands index the emitter's module tables, so a frame whose module carries
/// FEWER funcs or consts runs interpreted. A prefix bound: execution only ever appends.
pub fn setNativeModuleCheck(n_funcs: usize, n_consts: usize) void {
    native_expect_funcs = n_funcs;
    native_expect_consts = n_consts;
}

pub fn nativeModuleOk(module: *const Module) bool {
    if (native_expect_funcs == 0 and native_expect_consts == 0) return true;
    const match = module.funcs.items.len >= native_expect_funcs and
        module.consts.items.len >= native_expect_consts;
    if (!match and runtime.envOnce("KLIO_NATIVE_TRACE") != null) {
        std.debug.print("[native-modcheck] funcs {d} (want {d}) consts {d} (want {d})\n", .{
            module.funcs.items.len, native_expect_funcs,
            module.consts.items.len, native_expect_consts,
        });
    }
    return match;
}

/// The stream loop's own exits: `term`/`goto` mirror `bc_term`/`bc_goto`, `brk` is the unwind
/// break with `thrown`/`unwound` set, `ret` returns `ret_v`, `none` means block not compiled.
pub const NativeOutcome = enum(u8) { none, term, goto, brk, ret, oom };

const NativeStep = enum { cont, brk, ret, oom };

/// Recursive native serving stops here and flat-parks instead: each level stacks kf + glue +
/// serve frames, so this sits well under the C stack while clearing any realistic call chain.
pub const NATIVE_RECURSE_MAX_DEPTH: usize = 200;

pub const NativeCtx = struct {
    frame: *Frame,
    allocator: Allocator,
    ftls: *EvalTls,
    host: *anyopaque,
    flat_out: *?FlatCallSite,
    park_out: *?ParkPoint,
    thrown: *?Value,
    unwound: *?EvalError,
    ret_v: *EvalResult,
    /// Host-typed glue: run the inst at (block, idx) through its interpreter arm plus `afterStep`.
    arm_bin: *const fn (*NativeCtx, u32, u32) NativeStep,
    escape: *const fn (*NativeCtx, u32, u32) NativeStep,
    call: *const fn (*NativeCtx, u32, u32) NativeStep,
    /// Resolve a `GetField` site to (class cell identity, stored slot) so the emitted C can read the
    /// slot inline behind a class guard. Zero when the site is not a plain stored read.
    field_route: *const fn (*NativeCtx, u32, u32, *u64, *i32) i32,
    /// The same for a `SetField` site; the emitted C stores behind the GC write barrier.
    field_write_route: *const fn (*NativeCtx, u32, u32, *u64, *i32) i32,
    outcome: NativeOutcome = .none,
    out_block: u32 = 0,
};

pub fn NativeGlue(comptime H: type) type {
    return struct {
        pub fn armBin(ctx: *NativeCtx, block: u32, idx: u32) NativeStep {
            const host: *H = @ptrCast(@alignCast(ctx.host));
            const frame = ctx.frame;
            const inst = &frame.func.blocks[block].insts[idx];
            const r = execArmBinOp(H, ctx.allocator, frame, inst.BinOp, host) catch return .oom;
            return glueAfter(ctx, r, inst, idx, block);
        }
        pub fn fieldRoute(ctx: *NativeCtx, block: u32, idx: u32, cls_out: *u64, slot_out: *i32) i32 {
            if (comptime !@hasDecl(H, "fieldSiteRoute")) return 0;
            const host: *H = @ptrCast(@alignCast(ctx.host));
            const frame = ctx.frame;
            const inst = &frame.func.blocks[block].insts[idx];
            if (inst.* != .GetField) return 0;
            const gf = inst.GetField;
            const recv = frame.read(gf.receiver);
            if (recv != .Instance) return 0;
            const name = constStr(frame.module, gf.field) orelse return 0;
            // Only a PLAIN STORED slot (tag 1) may be read inline. A getter route, an outer-hop read or
            // a delegated property keeps the escape path, which is what forces a `by lazy` to run.
            const claim = host.fieldSiteRoute(&recv, name) orelse return 0;
            if (claim.route & 3 != 1) return 0;
            const slot: usize = @intCast(claim.route >> 2);
            {
                const g = recv.Instance.borrow();
                defer g.deinit();
                const fields = g.get().fields.items;
                if (slot >= fields.len) return 0;
                // Re-verify by name and decline what the serve declines: a null slot may
                // be an unset lateinit, and a Delegate needs its own read protocol.
                const fld = fields[slot];
                if (!std.mem.eql(u8, fld.name, name) and
                    !H.sgetterNameMatches(name, fld.name)) return 0;
                if (fld.value == .Null or fld.value == .Delegate) return 0;
                // The identity the emitted C compares is the raw CELL pointer out of
                // `InstanceData.class`; `asPtr` would hand back the payload address.
                cls_out.* = @intFromPtr(g.get().class.cell);
            }
            slot_out.* = @intCast(slot);
            return 1;
        }
        pub fn fieldWriteRoute(ctx: *NativeCtx, block: u32, idx: u32, cls_out: *u64, slot_out: *i32) i32 {
            if (comptime !@hasDecl(H, "fieldWriteSiteRoute")) return 0;
            const host: *H = @ptrCast(@alignCast(ctx.host));
            const frame = ctx.frame;
            const inst = &frame.func.blocks[block].insts[idx];
            if (inst.* != .SetField) return 0;
            const sf = inst.SetField;
            const recv = frame.read(sf.receiver);
            if (recv != .Instance) return 0;
            const name = constStr(frame.module, sf.field) orelse return 0;
            const claim = host.fieldWriteSiteRoute(&recv, name) orelse return 0;
            if (claim.route & 3 != 1) return 0;
            cls_out.* = claim.cls;
            slot_out.* = @intCast(claim.route >> 2);
            return 1;
        }
        pub fn escape(ctx: *NativeCtx, block: u32, idx: u32) NativeStep {
            const host: *H = @ptrCast(@alignCast(ctx.host));
            const frame = ctx.frame;
            const inst = &frame.func.blocks[block].insts[idx];
            const r = execInst(H, ctx.allocator, frame, inst, host) catch return .oom;
            return glueAfter(ctx, r, inst, idx, block);
        }
        pub fn call(ctx: *NativeCtx, block: u32, idx: u32) NativeStep {
            const host: *H = @ptrCast(@alignCast(ctx.host));
            const frame = ctx.frame;
            const inst = &frame.func.blocks[block].insts[idx];
            // Recursive serving stacks a native + glue + serve slice per level, so past this depth the C
            // stack faults before the eval-depth cap can raise StackOverflow. Deeper chains flat-park.
            const recurse_ok = ev_state.evtls.eval_depth < NATIVE_RECURSE_MAX_DEPTH;
            // A monomorphic plain call whose callee LEAF-serves is answered in place. The gate mirrors
            // execArmCall's fast path minus what the leaf bank cannot take (extensions, ambiguous fids).
            if (recurse_ok) direct: {
                const c = &inst.Call;
                if (c.type_args.len != 0 or !argNamesAllNull(c.arg_names)) break :direct;
                const cf = frame.module.funcById(c.func) orelse break :direct;
                if (tryLeafCall(H, ctx.allocator, frame, c, host, ctx) catch return .oom) |st| {
                    if (st == .cont) return .cont;
                    return glueAfter(ctx, st, inst, idx, block);
                }
                if (!cf.leafExprBody()) break :direct;
                var plan = cf.fast_call;
                if (plan == 0) {
                    if (comptime @hasDecl(H, "fastCallPlan")) {
                        plan = host.fastCallPlan(frame.module, c.func);
                        @constCast(cf).fast_call = plan;
                    } else break :direct;
                }
                if (plan & ir.FAST_CALL_EXT_FLAG != 0) break :direct;
                if (plan & ir.FAST_CALL_AMBIG_FLAG != 0) break :direct;
                const plan_arity = plan & 0x1FFF;
                if (plan_arity < 2 or plan_arity - 2 != c.n_args) break :direct;
                const base = c.args.int();
                if (base + c.n_args > frame.regs.items.len) break :direct;
                const argv = frame.regs.items[base .. base + c.n_args];
                const lr = leafExprServe(H, ctx.allocator, frame.module, cf, argv, host) catch return .oom;
                if (lr) |served| {
                    frame.write(c.dst, served.ok) catch return .oom;
                    return .cont;
                }
            }
            const r = execArmCall(H, ctx.allocator, frame, &inst.Call, host, !recurse_ok) catch return .oom;
            // A flat request whose callee LEAF-serves is answered in place: identical serve and module
            // choice, without the kf_ unwind and stream resume the flat driver would pay for it.
            if (r == .flat_call) leaf: {
                const req = frame.flat_call.?;
                if (!leafReqServable(req)) break :leaf;
                const callee_mod: *const Module = req.run_module orelse blk: {
                    if (funcOwnedBy(frame.module, req.func)) break :blk frame.module;
                    if (comptime @hasDecl(H, "ownerModuleForFunc")) {
                        if (host.ownerModuleForFunc(req.func)) |m| break :blk m;
                    }
                    break :blk frame.module;
                };
                const lr = leafExprServe(H, ctx.allocator, callee_mod, req.func, req.args.items, host) catch return .oom;
                if (lr) |served| {
                    frame.flat_call = null;
                    const dst = req.dst;
                    discardFlatReq(H, ctx.allocator, req, host);
                    frame.write(dst, served.ok) catch return .oom;
                    return .cont;
                }
            }
            return glueAfter(ctx, r, inst, idx, block);
        }
    };
}

fn glueAfter(ctx: *NativeCtx, r: Step, inst: *const Inst, idx: u32, block: u32) NativeStep {
    const a = afterStep(
        ctx.allocator,
        ctx.frame,
        r,
        inst,
        idx,
        @enumFromInt(block),
        ctx.flat_out,
        ctx.park_out,
        ctx.thrown,
        ctx.unwound,
        ctx.ret_v,
    ) catch return .oom;
    return switch (a) {
        .cont => .cont,
        .brk => .brk,
        .ret => .ret,
    };
}

/// The activation's register file as raw bytes; regs are sized once, so the base is stable.
pub fn nativeFrameRegs(ctx: *NativeCtx) [*]u8 {
    return @ptrCast(ctx.frame.regs.items.ptr);
}

pub fn nativeOpTrace(ctx: *NativeCtx, file: u32, start: u32, end: u32) void {
    ctx.frame.cur_span = .{ .file = @enumFromInt(file), .start = start, .end = end };
}

/// The frame's `cur_span` as raw bytes for the emitted C's inline trace store; no ownership.
pub fn nativeFrameSpanSlot(ctx: *NativeCtx) [*]u8 {
    return @ptrCast(&ctx.frame.cur_span);
}

/// The flag addresses the emitted C polls to inline the fused edge guard, whose slow work runs
/// only when a trigger fires. Per-THREAD pointers, so refetch at every activation entry.
pub const NativeEdgeView = extern struct {
    counter: *u64,
    idle: *u64,
    abandonable: *const bool,
    rb_abandon: *const bool,
    abandon_req: *const bool,
    gc_pending: *const bool,
    gc_on: u8,
    always: u8,
    /// Rare-trigger handler for this view's context (see klio_rt.h).
    rare: *const fn (ctx: ?*anyopaque, reasons: u32) callconv(.c) i32,
    /// Field-read route resolver for leaf genre-8 handles; null outside the leaf gates.
    route_ctx: ?*anyopaque = null,
    field_route: ?*const fn (route_ctx: ?*anyopaque, recv_cell: ?*anyopaque, name: [*:0]const u8, cls48_out: *u64, slot_out: *i32) callconv(.c) i32 = null,
    /// Instance-of verdict for leaf genre-8 handles: 1 = the receiver's class IS the named type,
    /// 2 = it is not, 0 = miss. The site binds the verdict to the receiver's class word.
    type_route: ?*const fn (route_ctx: ?*anyopaque, recv_cell: ?*anyopaque, name: [*:0]const u8) callconv(.c) i32 = null,
    /// Static-member resolver for genre-9 class handles: fills (value, genre); enum entries only.
    statics_route: ?*const fn (route_ctx: ?*anyopaque, owner: [*:0]const u8, name: [*:0]const u8, out_v: *i64, out_g: *i32) callconv(.c) i32 = null,
};

/// Per-host statics thunk for leaf bodies: enum entries only, the one borrow-safe family.
fn LeafStaticsRoute(comptime H: type) type {
    return struct {
        fn route(rctx: ?*anyopaque, owner: [*:0]const u8, name: [*:0]const u8, out_v: *i64, out_g: *i32) callconv(.c) i32 {
            if (comptime !@hasDecl(H, "leafStaticMember")) return 0;
            const host: *H = @ptrCast(@alignCast(rctx orelse return 0));
            const v = host.leafStaticMember(std.mem.span(owner), std.mem.span(name)) orelse return 0;
            switch (v) {
                .Int => |x| {
                    out_v.* = x;
                    out_g.* = 0;
                },
                .Long => |x| {
                    out_v.* = x;
                    out_g.* = 1;
                },
                .Bool => |x| {
                    out_v.* = @intFromBool(x);
                    out_g.* = 2;
                },
                .Char => |x| {
                    out_v.* = x;
                    out_g.* = 4;
                },
                .Instance => |inst| {
                    out_v.* = @bitCast(@as(u64, @intFromPtr(inst.cell)));
                    out_g.* = 8;
                },
                else => return 0,
            }
            return 1;
        }
    };
}

/// Per-host instance-of thunk for leaf genre-8 handles: 1 = yes, 2 = no, 0 = bail.
fn LeafTypeRoute(comptime H: type) type {
    return struct {
        fn route(rctx: ?*anyopaque, recv_cell: ?*anyopaque, name: [*:0]const u8) callconv(.c) i32 {
            if (comptime !@hasDecl(H, "instanceOf")) return 0;
            const host: *H = @ptrCast(@alignCast(rctx orelse return 0));
            const cell = recv_cell orelse return 0;
            const v = Value{ .Instance = .{ .cell = @ptrCast(@alignCast(cell)) } };
            const ty = TypeRef{ .name = std.mem.span(name), .nullable = false, .args = &.{} };
            return if (host.instanceOf(&v, ty)) 1 else 2;
        }
    };
}

/// Per-host field-route thunk: a borrowed Instance view over the raw cell (no retain, the
/// leaf's caller roots it). Only a PLAIN STORED slot resolves; everything else bails.
fn LeafFieldRoute(comptime H: type) type {
    return struct {
        fn route(rctx: ?*anyopaque, recv_cell: ?*anyopaque, name: [*:0]const u8, cls48_out: *u64, slot_out: *i32) callconv(.c) i32 {
            if (comptime !@hasDecl(H, "fieldSiteRoute")) return 0;
            const host: *H = @ptrCast(@alignCast(rctx orelse return 0));
            const cell = recv_cell orelse return 0;
            const v = Value{ .Instance = .{ .cell = @ptrCast(@alignCast(cell)) } };
            var claim = host.fieldSiteRoute(&v, std.mem.span(name)) orelse {
                if (runtime.envOnce("KLIO_LEAF_ROUTE_TRACE") != null)
                    std.debug.print("[leaf-route] {s}: no claim\n", .{std.mem.span(name)});
                return 0;
            };
            if (runtime.envOnce("KLIO_LEAF_ROUTE_TRACE") != null)
                std.debug.print("[leaf-route] {s}: tag={d}\n", .{ std.mem.span(name), claim.route & 3 });
            if (claim.route & 3 == 2) {
                // A GETTER route chases one level to the trivial accessor's backing slot.
                if (comptime !@hasDecl(H, "hostModulePtr")) return 0;
                const mod2 = host.hostModulePtr();
                const gfid: u32 = @intCast(claim.route >> 2);
                const gf = mod2.funcById(ir.FuncId.from(gfid)) orelse return 0;
                const fc = gf.accessorFieldConstIn(mod2) orelse return 0;
                if (fc.int() >= mod2.consts.items.len) return 0;
                const under: []const u8 = switch (mod2.consts.items[fc.int()]) {
                    .String => |sv| sv,
                    else => return 0,
                };
                claim = host.fieldSiteRoute(&v, under) orelse return 0;
            }
            if (claim.route & 3 != 1) return 0;
            const slot = claim.route >> 2;
            if (slot > std.math.maxInt(i32)) return 0;
            cls48_out.* = claim.cls & 0xFFFF_FFFF_FFFF;
            slot_out.* = @intCast(slot);
            return 1;
        }
    };
}

/// Rare handler for the INTERPRETER's leaf gate: with no NativeCtx, a persistent condition
/// (abandon, pending GC, expired test deadline) bails the leaf, and persisting keeps it loop-free.
fn leafEdgeRareInterp(ctx: ?*anyopaque, reasons: u32) callconv(.c) i32 {
    _ = ctx;
    if (reasons & 0x2 != 0 and runtime.shouldAbandon()) return 1;
    if (reasons & 0x4 != 0) return 1;
    if (reasons & 0x1 != 0) {
        spinDumpMaybe();
        const wall_dl = parent.test_wall_deadline_ms.load(.monotonic);
        if (wall_dl != 0 and nowMonotonicMs() > wall_dl) return 1;
    }
    return 0;
}

fn nativeOpEdgeRareC(ctx: ?*anyopaque, reasons: u32) callconv(.c) i32 {
    return nativeOpEdgeRare(@ptrCast(@alignCast(ctx.?)), reasons);
}

pub fn nativeEdgeView(ctx: *NativeCtx, out: *NativeEdgeView) void {
    out.* = .{
        .rare = &nativeOpEdgeRareC,
        .counter = &ctx.ftls.spin_check_counter,
        .idle = runtime.gc.idleTickPtr(),
        .abandonable = runtime.abandonablePtr(),
        .rb_abandon = runtime.runBoundaryAbandonPtr(),
        .abandon_req = runtime.abandonRequestedPtr(),
        .gc_pending = runtime.gc.pendingFlagPtr(),
        .gc_on = @intFromBool(runtime.gc.gc_enabled),
        .always = @intFromBool(runtime.gc.stressActive()),
    };
}

/// Edge-guard slow path: `reasons` bit 0 = counter cadence, 1 = abandon flags, 2 = gc pending,
/// 3 = stress, 4 = idle cadence; the actions mirror `fusedEdgeGuard` for those triggers.
pub fn nativeOpEdgeRare(ctx: *NativeCtx, reasons: u32) i32 {
    if (reasons & 0x2 != 0 and runtime.shouldAbandon()) {
        ctx.ret_v.* = errResult(.{ .Type = "daemon task abandoned at run boundary" });
        ctx.outcome = .ret;
        return 1;
    }
    if (reasons & 0x1 != 0) {
        spinDumpMaybe();
        const wall_dl = parent.test_wall_deadline_ms.load(.monotonic);
        if (wall_dl != 0 and nowMonotonicMs() > wall_dl) {
            ctx.ret_v.* = wallCapFire(ctx.allocator) catch
                errResult(.{ .Type = "test wall-clock deadline exceeded" });
            ctx.outcome = .ret;
            return 1;
        }
    }
    if (reasons & 0x8 != 0) {
        // Stress mode runs the full guard's gc arm (`pending()` carries the stress counters).
        if (runtime.gc.gc_enabled and runtime.gc.pending()) runtime.gc.safePoint();
        return 0;
    }
    if (reasons & 0x10 != 0) runtime.gc.idleProbeNow();
    if (reasons & 0x4 != 0) {
        if (runtime.gc.gc_enabled) runtime.gc.safePoint();
    }
    return 0;
}

pub fn nativeOpConstLoad(ctx: *NativeCtx, dst: u32, const_id: u32) i32 {
    const v = constToValue(ctx.allocator, &ctx.frame.module.consts.items[const_id]) catch {
        ctx.outcome = .oom;
        return 1;
    };
    writeFastU(ctx.frame, @enumFromInt(dst), v, ctx.allocator);
    return 0;
}

pub fn nativeOpConstInt(ctx: *NativeCtx, dst: u32, payload: i32) void {
    writeFastU(ctx.frame, @enumFromInt(dst), .{ .Int = payload }, ctx.allocator);
}

pub fn nativeOpMove(ctx: *NativeCtx, dst: u32, src: u32) void {
    const v = ctx.frame.regs.items.ptr[src];
    v.retain();
    writeFastU(ctx.frame, @enumFromInt(dst), v, ctx.allocator);
}

pub fn nativeOpLoadParam(ctx: *NativeCtx, dst: u32, pidx: u32) void {
    const frame = ctx.frame;
    const v = if (pidx < frame.params.items.len) frame.params.items[pidx] else Value.Unit;
    v.retain();
    writeFastU(frame, @enumFromInt(dst), v, ctx.allocator);
}

pub fn nativeOpCellGet(ctx: *NativeCtx, dst: u32, cell: u32) void {
    const frame = ctx.frame;
    const v = switch (frame.regs.items.ptr[cell]) {
        .Cell => |c| vblk: {
            const g = c.borrow();
            defer g.deinit();
            break :vblk g.get().*;
        },
        else => |other| other,
    };
    v.retain();
    writeFastU(frame, @enumFromInt(dst), v, ctx.allocator);
}

/// Nonzero = the emitted function must return (outcome set on the ctx).
pub fn nativeOpBin(ctx: *NativeCtx, block: u32, inst_idx: u32, kind: u32, dst: u32, lhs: u32, rhs: u32) i32 {
    if (binFast(ctx.frame, @enumFromInt(kind), @enumFromInt(dst), @enumFromInt(lhs), @enumFromInt(rhs), ctx.allocator)) return 0;
    switch (ctx.arm_bin(ctx, block, inst_idx)) {
        .cont => return 0,
        .brk => {
            ctx.outcome = .brk;
            ctx.out_block = block;
            return 1;
        },
        .ret => {
            ctx.outcome = .ret;
            return 1;
        },
        .oom => {
            ctx.outcome = .oom;
            return 1;
        },
    }
}

/// A statically-bound `.Call` escape served recursively, keeping the emitted caller on the C stack.
pub fn nativeOpCall(ctx: *NativeCtx, block: u32, inst_idx: u32) i32 {
    if (runtime.envOnce("KLIO_NATIVE_TRACE") != null) {
        std.debug.print("[native-call] from={s} b{d} i{d}\n", .{ ctx.frame.func.fqn, block, inst_idx });
    }
    switch (ctx.call(ctx, block, inst_idx)) {
        .cont => return 0,
        .brk => {
            ctx.outcome = .brk;
            ctx.out_block = block;
            return 1;
        },
        .ret => {
            ctx.outcome = .ret;
            return 1;
        },
        .oom => {
            ctx.outcome = .oom;
            return 1;
        },
    }
}

/// Resolve a `GetField` site for the emitted C's inline read: 1 with `cls_out`/`slot_out` filled
/// when the site is a plain stored field on the receiver's class, 0 leaves it on the escape.
pub fn nativeOpFieldRoute(ctx: *NativeCtx, block: u32, inst_idx: u32, cls_out: *u64, slot_out: *i32) i32 {
    return ctx.field_route(ctx, block, inst_idx, cls_out, slot_out);
}

pub fn nativeOpFieldWriteRoute(ctx: *NativeCtx, block: u32, inst_idx: u32, cls_out: *u64, slot_out: *i32) i32 {
    return ctx.field_write_route(ctx, block, inst_idx, cls_out, slot_out);
}

pub fn nativeOpEscape(ctx: *NativeCtx, block: u32, inst_idx: u32) i32 {
    switch (ctx.escape(ctx, block, inst_idx)) {
        .cont => return 0,
        .brk => {
            ctx.outcome = .brk;
            ctx.out_block = block;
            return 1;
        },
        .ret => {
            ctx.outcome = .ret;
            return 1;
        },
        .oom => {
            ctx.outcome = .oom;
            return 1;
        },
    }
}

/// The per-taken-edge guards on a fused `goto`. Nonzero = return.
pub fn nativeOpEdge(ctx: *NativeCtx) i32 {
    if (fusedEdgeGuard(ctx.allocator, ctx.ftls)) |er| {
        ctx.ret_v.* = er;
        ctx.outcome = .ret;
        return 1;
    }
    return 0;
}

/// Fused Branch: 1 = take the true edge, 0 = the false edge, 2 = return (a non-Bool condition
/// exits to the real terminator; an edge-guard abort).
pub fn nativeOpBr(ctx: *NativeCtx, block: u32, cond: u32) i32 {
    const cv = ctx.frame.regs.items.ptr[cond];
    if (cv != .Bool) {
        ctx.outcome = .term;
        ctx.out_block = block;
        return 2;
    }
    if (fusedEdgeGuard(ctx.allocator, ctx.ftls)) |er| {
        ctx.ret_v.* = er;
        ctx.outcome = .ret;
        return 2;
    }
    return @intFromBool(cv.Bool);
}

/// Fused compare-and-branch; same return contract as `nativeOpBr`.
pub fn nativeOpCmpBr(ctx: *NativeCtx, block: u32, inst_idx: u32, kind: u32, dst: u32, lhs: u32, rhs: u32) i32 {
    const frame = ctx.frame;
    var taken: ?bool = null;
    {
        const regs = frame.regs.items.ptr;
        if (scalarBin(@enumFromInt(kind), regs[lhs], regs[rhs])) |out| {
            if (out == .Bool) {
                const old = regs[dst];
                regs[dst] = out;
                frame.wmask.set(dst);
                if (runtime.reclaimEnabled()) old.release(ctx.allocator);
                taken = out.Bool;
            }
        }
    }
    if (taken == null) {
        switch (ctx.arm_bin(ctx, block, inst_idx)) {
            .cont => {},
            .brk => {
                ctx.outcome = .brk;
                ctx.out_block = block;
                return 2;
            },
            .ret => {
                ctx.outcome = .ret;
                return 2;
            },
            .oom => {
                ctx.outcome = .oom;
                return 2;
            },
        }
        const cv = frame.read(@enumFromInt(dst));
        if (cv != .Bool) {
            ctx.outcome = .term;
            ctx.out_block = block;
            return 2;
        }
        taken = cv.Bool;
    }
    if (fusedEdgeGuard(ctx.allocator, ctx.ftls)) |er| {
        ctx.ret_v.* = er;
        ctx.outcome = .ret;
        return 2;
    }
    return @intFromBool(taken.?);
}

pub fn nativeOpRet(ctx: *NativeCtx, has_val: u32, reg: u32) void {
    const v: Value = if (has_val != 0) ctx.frame.regs.items.ptr[reg] else .Unit;
    v.retain();
    ctx.ret_v.* = ok(v);
    ctx.outcome = .ret;
}

pub fn nativeOpTerm(ctx: *NativeCtx, block: u32) void {
    ctx.outcome = .term;
    ctx.out_block = block;
}

pub fn nativeOpGotoExit(ctx: *NativeCtx, block: u32) void {
    ctx.outcome = .goto;
    ctx.out_block = block;
}
