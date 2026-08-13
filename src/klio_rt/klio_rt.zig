//! The C ABI surface of the klio runtime (`plans/c-transpiler-plan.md`):
//! program bootstrap plus the per-op helpers the transpiled C calls. The
//! helpers are thin casts into the evaluator's own arm bodies
//! (`ir.eval.nativeOp*`), so the emitted code shares interpreter
//! semantics by construction.

const std = @import("std");
const cli = @import("cli");
const runtime = @import("runtime");
const ir = @import("ir");
const eval = ir.eval;

/// Generated code registers its layout globals here; the run entries
/// fill them AFTER the performance profile (and so the reclaim mode) is
/// chosen, which is what decides `usable`.
var hot_layout_slot: ?*HotLayout = null;

export fn klio_rt_register_hot_layout(slot: *HotLayout) void {
    hot_layout_slot = slot;
}

fn fillHotLayoutSlot() void {
    if (hot_layout_slot) |slot| klio_rt_hot_layout(slot);
}

fn runFileBody(path: [:0]const u8, code_out: *c_int) void {
    runtime.perf.setProfile(runtime.perf.resolveBinaryProfile(&.{}));
    fillHotLayoutSlot();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = runtime.allocTrackWrap(arena.allocator());
    var features = cli.commands.RequestedFeatures.init(gpa);
    defer features.deinit();
    code_out.* = @intCast(cli.commands.runFileIrVm(gpa, path, &features));
}

/// Run the Kotlin program at `path` exactly as `klio run <path>` would,
/// on the default process-lifetime arena profile. Returns the process
/// exit code (0 success, 1 diagnostics/runtime error).
///
/// The work runs on a dedicated thread with an explicit large stack: the
/// klio binary's Zig start code honors the executable's 16MB GNU_STACK
/// request, but a transpiled binary's C `main` runs on the libc crt with
/// whatever the process rlimit gives (typically 8MB), and lowering a
/// deeply-nested expression recurses past that.
export fn klio_rt_run_file(path: [*:0]const u8) c_int {
    var code: c_int = 1;
    const t = std.Thread.spawn(
        .{ .stack_size = 256 << 20 },
        runFileBody,
        .{ std.mem.span(path), &code },
    ) catch return 1;
    t.join();
    return code;
}

fn runImageBody(base: [:0]const u8, path: [:0]const u8, code_out: *c_int) void {
    runtime.perf.setProfile(runtime.perf.resolveBinaryProfile(&.{}));
    fillHotLayoutSlot();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = runtime.allocTrackWrap(arena.allocator());
    code_out.* = @intCast(cli.bundle.runImage(gpa, base, &.{path}, &.{}));
}

/// Run the Kotlin program at `path` against the pre-baked dependency base
/// at `base_image`, exactly as `klio run-image` would. This is the entry
/// transpiled programs use: the emitted ids are only meaningful against
/// the module assembled from that exact artifact. Same large-stack thread
/// as `klio_rt_run_file`.
export fn klio_rt_run_image(base_image: [*:0]const u8, path: [*:0]const u8) c_int {
    var code: c_int = 1;
    const t = std.Thread.spawn(
        .{ .stack_size = 256 << 20 },
        runImageBody,
        .{ std.mem.span(base_image), std.mem.span(path), &code },
    ) catch return 1;
    t.join();
    return code;
}

/// The hot-view layout descriptor: byte offsets into `runtime.Value`
/// measured against the SAME build the library runs, so the generated
/// C's inline scalar ops (`klio_hot.h` section of the emitted file) are
/// correct by construction rather than by a frozen contract. `usable`
/// is false when the process runs a reclaim mode whose register writes
/// must release the old value — the emitted code then falls back to the
/// exported per-op helpers.
pub const HotLayout = extern struct {
    value_size: u32,
    tag_off: u32,
    tag_size: u32,
    int_off: u32,
    long_off: u32,
    bool_off: u32,
    tag_int: u64,
    tag_long: u64,
    tag_bool: u64,
    usable: u8,
};

fn tagOffset() struct { off: u32, size: u32 } {
    // The tag's location is compiler-chosen; find it by diffing values
    // that differ only in tag (payload bytes zero in both). Undefined
    // padding bytes are poisoned per-construction in safe builds, so a
    // same-tag pair first yields the padding mask to ignore.
    const N = @sizeOf(runtime.Value);
    var z1: runtime.Value = .{ .Int = 0 };
    var z2: runtime.Value = .{ .Int = 0 };
    var a: runtime.Value = .{ .Int = 0 };
    var b: runtime.Value = .{ .Long = 0 };
    const p1: [*]const u8 = @ptrCast(&z1);
    const p2: [*]const u8 = @ptrCast(&z2);
    const pa: [*]const u8 = @ptrCast(&a);
    const pb: [*]const u8 = @ptrCast(&b);
    var first: ?u32 = null;
    var last: u32 = 0;
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        if (p1[i] != p2[i]) continue; // padding: unstable even same-tag
        if (pa[i] != pb[i]) {
            if (first == null) first = i;
            last = i;
        }
    }
    const off = first orelse 0;
    var size = last - off + 1;
    if (size > 8) size = 8;
    return .{ .off = off, .size = size };
}

fn readTag(v: *const runtime.Value, off: u32, size: u32) u64 {
    const p: [*]const u8 = @ptrCast(v);
    var out: u64 = 0;
    @memcpy(std.mem.asBytes(&out)[0..size], p[off .. off + size]);
    return out;
}

export fn klio_rt_hot_layout(out: *HotLayout) void {
    const t = tagOffset();
    var vi: runtime.Value = .{ .Int = 0 };
    var vl: runtime.Value = .{ .Long = 0 };
    var vb: runtime.Value = .{ .Bool = false };
    out.* = .{
        .value_size = @sizeOf(runtime.Value),
        .tag_off = t.off,
        .tag_size = t.size,
        .int_off = @intCast(@intFromPtr(&vi.Int) - @intFromPtr(&vi)),
        .long_off = @intCast(@intFromPtr(&vl.Long) - @intFromPtr(&vl)),
        .bool_off = @intCast(@intFromPtr(&vb.Bool) - @intFromPtr(&vb)),
        .tag_int = readTag(&vi, t.off, t.size),
        .tag_long = readTag(&vl, t.off, t.size),
        .tag_bool = readTag(&vb, t.off, t.size),
        .usable = @intFromBool(!runtime.reclaimEnabled()),
    };
}

/// Library version tag for the header/link handshake.
export fn klio_rt_abi_version() c_int {
    return 2;
}

/// Register a transpiled function for `fid`; the interpreter's frame loop
/// runs it in place of the bytecode stream. Call before `klio_rt_run_file`
/// — the table is read-only once the program runs. `fqn` guards the fid:
/// an entry whose name does not match the function the runtime lowered to
/// that fid is ignored (full interpretation, never the wrong body).
export fn klio_rt_register_native(fid: u32, f: eval.NativeFn, fqn: [*:0]const u8) void {
    eval.registerNative(fid, f, std.mem.span(fqn));
}

/// Declare the table sizes of the module the emitter walked. A frame
/// whose module disagrees runs interpreted — the emitted const/func ids
/// index these tables and mean nothing against any other module.
export fn klio_rt_register_module_check(n_funcs: u64, n_consts: u64) void {
    eval.setNativeModuleCheck(@intCast(n_funcs), @intCast(n_consts));
}

inline fn ctxOf(p: *anyopaque) *eval.NativeCtx {
    return @ptrCast(@alignCast(p));
}

export fn klio_op_trace(ctx: *anyopaque, file: u32, start: u32, end: u32) void {
    eval.nativeOpTrace(ctxOf(ctx), file, start, end);
}

export fn klio_op_const_load(ctx: *anyopaque, dst: u32, const_id: u32) i32 {
    return eval.nativeOpConstLoad(ctxOf(ctx), dst, const_id);
}

export fn klio_op_const_int(ctx: *anyopaque, dst: u32, payload: i32) void {
    eval.nativeOpConstInt(ctxOf(ctx), dst, payload);
}

export fn klio_op_move(ctx: *anyopaque, dst: u32, src: u32) void {
    eval.nativeOpMove(ctxOf(ctx), dst, src);
}

export fn klio_op_load_param(ctx: *anyopaque, dst: u32, idx: u32) void {
    eval.nativeOpLoadParam(ctxOf(ctx), dst, idx);
}

export fn klio_op_cell_get(ctx: *anyopaque, dst: u32, cell: u32) void {
    eval.nativeOpCellGet(ctxOf(ctx), dst, cell);
}

export fn klio_op_bin(ctx: *anyopaque, block: u32, inst_idx: u32, kind: u32, dst: u32, lhs: u32, rhs: u32) i32 {
    return eval.nativeOpBin(ctxOf(ctx), block, inst_idx, kind, dst, lhs, rhs);
}

export fn klio_op_escape(ctx: *anyopaque, block: u32, inst_idx: u32) i32 {
    return eval.nativeOpEscape(ctxOf(ctx), block, inst_idx);
}

export fn klio_op_call(ctx: *anyopaque, block: u32, inst_idx: u32) i32 {
    return eval.nativeOpCall(ctxOf(ctx), block, inst_idx);
}

export fn klio_op_edge(ctx: *anyopaque) i32 {
    return eval.nativeOpEdge(ctxOf(ctx));
}

export fn klio_op_br(ctx: *anyopaque, block: u32, cond: u32) i32 {
    return eval.nativeOpBr(ctxOf(ctx), block, cond);
}

export fn klio_op_cmp_br(ctx: *anyopaque, block: u32, inst_idx: u32, kind: u32, dst: u32, lhs: u32, rhs: u32) i32 {
    return eval.nativeOpCmpBr(ctxOf(ctx), block, inst_idx, kind, dst, lhs, rhs);
}

export fn klio_op_ret(ctx: *anyopaque, has_val: u32, reg: u32) void {
    eval.nativeOpRet(ctxOf(ctx), has_val, reg);
}

export fn klio_op_term(ctx: *anyopaque, block: u32) void {
    eval.nativeOpTerm(ctxOf(ctx), block);
}

export fn klio_op_goto_exit(ctx: *anyopaque, block: u32) void {
    eval.nativeOpGotoExit(ctxOf(ctx), block);
}
