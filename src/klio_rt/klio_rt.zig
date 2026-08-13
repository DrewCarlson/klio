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

fn runFileBody(path: [:0]const u8, code_out: *c_int) void {
    runtime.perf.setProfile(runtime.perf.resolveBinaryProfile(&.{}));
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
