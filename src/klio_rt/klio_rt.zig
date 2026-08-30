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

/// The generated file's EMIT-TIME copy of the layout, frozen as constants
/// in its inline fast paths. Verified against the live fill: a .c linked
/// against a runtime with a different layout gets the whole hot view
/// disabled (helpers fall back to the exported per-op entry points)
/// instead of reading through wrong offsets.
var hot_frozen_slot: ?*const HotLayout = null;

export fn klio_rt_register_hot_frozen(frozen: *const HotLayout) void {
    hot_frozen_slot = frozen;
}

fn fillHotLayoutSlot() void {
    if (std.c.getenv("KLIO_NATIVE_TRACE") != null)
        std.debug.print("[rt] fillHotLayoutSlot slot=0x{x}\n", .{if (hot_layout_slot) |sl| @intFromPtr(sl) else 0});
    if (hot_layout_slot) |slot| {
        klio_rt_hot_layout(slot);
        // The generated file's frozen constants must match the live
        // layout exactly, or every inline fast path reads garbage —
        // disable the whole view and let the exported helpers carry it.
        if (hot_frozen_slot) |fz| {
            if (!ir.hot_layout.layoutMatches(fz, slot)) {
                slot.usable = 0;
                slot.obj_usable = 0;
                slot.span_usable = 0;
                if (std.c.getenv("KLIO_NATIVE_TRACE") != null)
                    std.debug.print("[rt] FROZEN LAYOUT MISMATCH — hot view disabled\n", .{});
            }
        }
        if (std.c.getenv("KLIO_NATIVE_TRACE") != null)
            std.debug.print("[rt] filled usable={d} size={d}\n", .{ slot.usable, slot.value_size });
    }
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
pub const HotLayout = ir.hot_layout.HotLayout;

fn objViewOff() bool {
    const v = std.c.getenv("KLIO_OBJVIEW") orelse return false;
    return std.mem.span(v).len != 0 and std.mem.span(v)[0] == '0';
}

export fn klio_rt_hot_layout(out: *HotLayout) void {
    if (std.c.getenv("KLIO_NATIVE_TRACE") != null) std.debug.print("[rt] hot_layout enter out=0x{x}\n", .{@intFromPtr(out)});
    ir.hot_layout.fillLayout(out);
    // Policy gates on top of the pure layout probe: the run path turns
    // per-thread reclaim OFF unless the process explicitly requested a
    // reclaim mode (KLIO_RECLAIM); the live flag is not yet set on this
    // thread when the slot fills, so the request is the decision that
    // matters. The object view additionally honors KLIO_OBJVIEW=0 for
    // single-binary A/B.
    if (runtime.reclaimRequested()) {
        out.usable = 0;
        out.obj_usable = 0;
    }
    if (objViewOff()) out.obj_usable = 0;
    if (std.c.getenv("KLIO_NATIVE_TRACE") != null)
        std.debug.print("[rt] wrote usable={d} vsize={d} (sizeOf={d}) reclaimReq={}\n", .{ out.usable, out.value_size, @sizeOf(runtime.Value), runtime.reclaimRequested() });
}

/// Library version tag for the header/link handshake.
export fn klio_rt_abi_version() c_int {
    return 5;
}

/// Register a transpiled function for `fid`; the interpreter's frame loop
/// runs it in place of the bytecode stream. Call before `klio_rt_run_file`
/// — the table is read-only once the program runs. `fqn` guards the fid:
/// an entry whose name does not match the function the runtime lowered to
/// that fid is ignored (full interpretation, never the wrong body).
export fn klio_rt_register_native(fid: u32, f: eval.NativeFn, fqn: [*:0]const u8) void {
    eval.registerNative(fid, f, std.mem.span(fqn));
}

/// Register a scalar-replay leaf body (`kl_<fid>`). Same fqn guard as
/// `klio_rt_register_native`.
export fn klio_rt_register_native_leaf(fid: u32, f: eval.NativeLeafFn, fqn: [*:0]const u8) void {
    eval.registerNativeLeaf(fid, f, std.mem.span(fqn));
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

export fn klio_op_regs(ctx: *anyopaque) [*]u8 {
    return eval.nativeFrameRegs(ctxOf(ctx));
}

export fn klio_op_trace(ctx: *anyopaque, file: u32, start: u32, end: u32) void {
    eval.nativeOpTrace(ctxOf(ctx), file, start, end);
}

export fn klio_op_span_slot(ctx: *anyopaque) [*]u8 {
    return eval.nativeFrameSpanSlot(ctxOf(ctx));
}

export fn klio_op_edge_view(ctx: *anyopaque, out: *eval.NativeEdgeView) void {
    eval.nativeEdgeView(ctxOf(ctx), out);
}

export fn klio_op_edge_rare(ctx: *anyopaque, reasons: u32) i32 {
    return eval.nativeOpEdgeRare(ctxOf(ctx), reasons);
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

/// The GC write barrier for a cell the emitted C is about to store a Value
/// into. A stored field can hold a reference, so the containing cell must be
/// remembered exactly as the interpreter's own store does it.
export fn klio_rt_write_barrier(cell: *anyopaque) void {
    const c: *runtime.ObjRef(runtime.InstanceData).Cell = @ptrCast(@alignCast(cell));
    runtime.gc.writeBarrier(&c.hdr);
}

export fn klio_op_field_route(ctx: *anyopaque, block: u32, inst_idx: u32, cls_out: *u64, slot_out: *i32) i32 {
    return eval.nativeOpFieldRoute(ctxOf(ctx), block, inst_idx, cls_out, slot_out);
}

export fn klio_op_field_write_route(ctx: *anyopaque, block: u32, inst_idx: u32, cls_out: *u64, slot_out: *i32) i32 {
    return eval.nativeOpFieldWriteRoute(ctxOf(ctx), block, inst_idx, cls_out, slot_out);
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
