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
    if (std.c.getenv("KLIO_NATIVE_TRACE") != null)
        std.debug.print("[rt] fillHotLayoutSlot slot=0x{x}\n", .{if (hot_layout_slot) |sl| @intFromPtr(sl) else 0});
    if (hot_layout_slot) |slot| {
        klio_rt_hot_layout(slot);
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
const InstCell = runtime.ObjRef(runtime.InstanceData).Cell;
const FieldList = std.ArrayList(runtime.InstanceData.Field);
/// A slice is `{ptr, len}` in that order; there is no `@offsetOf` for one.
const SLICE_PTR_OFF: u32 = 0;
const SLICE_LEN_OFF: u32 = @sizeOf(usize);

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
    tag_unit: u64,
    usable: u8,
    /// Frame `cur_span` (`?Span`) layout for the inlined trace store:
    /// three u32 field offsets plus the optional's presence byte and
    /// its set value. `span_usable == 0` keeps traces on the helper.
    span_usable: u8,
    span_file_off: u32,
    span_start_off: u32,
    span_end_off: u32,
    span_tag_off: u32,
    span_tag_set: u8,
    /// Char payload location + tag, for fused loops over Char scalars.
    char_off: u32,
    tag_char: u64,
    /// Object view: enough of the Instance layout for the emitted C to read
    /// a plain stored field inline behind a class guard. `obj_usable == 0`
    /// keeps every field read on the escape helper — it is set only under
    /// the tracing GC, where copying a `Value` into a register needs no
    /// retain. Offsets come from `@offsetOf` on the real structs, so a
    /// layout change moves them with the runtime instead of drifting.
    obj_usable: u8,
    tag_instance: u64,
    /// `Value.Instance` payload (the `ObjRef` cell pointer) inside a Value.
    inst_ptr_off: u32,
    /// `data` inside the cell's control block.
    cell_data_off: u32,
    /// `class` / `fields` inside `InstanceData`.
    inst_class_off: u32,
    inst_fields_off: u32,
    /// `items.ptr` / `items.len` inside the fields `ArrayList`.
    fields_ptr_off: u32,
    fields_len_off: u32,
    /// One `Field` record: its size and the offset of its `value`.
    field_stride: u32,
    field_value_off: u32,
};

fn tagOffset() struct { off: u32, size: u32 } {
    // The tag's location is compiler-chosen; find it by diffing values
    // that differ only in tag (payload bytes zero in both). Undefined
    // padding bytes are poisoned per-construction in safe builds, so a
    // same-tag pair first yields the padding mask to ignore.
    const N = @sizeOf(runtime.Value);
    // Zero the backing bytes BEFORE constructing each probe value: the
    // padding bytes of a struct assignment are undefined, and comparing
    // undefined memory is UB the optimizer may lower to a trap (it did —
    // the fill crashed the run thread and the hot view silently never
    // engaged). With zeroed backing, padding compares equal and only the
    // tag/payload fields differ.
    var z1: runtime.Value = undefined;
    var z2: runtime.Value = undefined;
    var a: runtime.Value = undefined;
    var b: runtime.Value = undefined;
    @memset(std.mem.asBytes(&z1), 0);
    @memset(std.mem.asBytes(&z2), 0);
    @memset(std.mem.asBytes(&a), 0);
    @memset(std.mem.asBytes(&b), 0);
    z1 = .{ .Int = 0 };
    z2 = .{ .Int = 0 };
    a = .{ .Int = 0 };
    b = .{ .Long = 0 };
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

/// Locate the fields of the frame's `?Span` slot by value probing:
/// distinct u32 patterns find each field; the presence byte is the one
/// that flips between null and set outside the payload (padding-masked
/// by comparing two identical null values).
const SpanProbe = struct {
    usable: u8,
    file_off: u32,
    start_off: u32,
    end_off: u32,
    tag_off: u32,
    tag_set: u8,
};

fn spanProbe() SpanProbe {
    const OptSpan = ?ir.Span;
    const N = @sizeOf(OptSpan);
    // Zero the backing bytes before construction: padding is undefined and
    // comparing undefined memory is UB the optimizer may lower to a trap
    // (the tagOffset probe crashed exactly this way).
    var set: OptSpan = undefined;
    var null1: OptSpan = undefined;
    var null2: OptSpan = undefined;
    @memset(std.mem.asBytes(&set), 0);
    @memset(std.mem.asBytes(&null1), 0);
    @memset(std.mem.asBytes(&null2), 0);
    set = .{ .file = @enumFromInt(@as(u32, 0x01020304)), .start = 0x05060708, .end = 0x090A0B0C };
    null1 = null;
    null2 = null;
    const ps: [*]const u8 = @ptrCast(&set);
    const p1: [*]const u8 = @ptrCast(&null1);
    const p2: [*]const u8 = @ptrCast(&null2);
    var out: SpanProbe = .{ .usable = 0, .file_off = 0, .start_off = 0, .end_off = 0, .tag_off = 0, .tag_set = 1 };
    var found_file: ?u32 = null;
    var found_start: ?u32 = null;
    var found_end: ?u32 = null;
    var i: u32 = 0;
    while (i + 4 <= N) : (i += 1) {
        var w: u32 = 0;
        @memcpy(std.mem.asBytes(&w), ps[i .. i + 4]);
        switch (w) {
            0x01020304 => found_file = i,
            0x05060708 => found_start = i,
            0x090A0B0C => found_end = i,
            else => {},
        }
    }
    const fo = found_file orelse return out;
    const so = found_start orelse return out;
    const eo = found_end orelse return out;
    // Presence byte: differs between null and set, is stable across two
    // nulls (excludes poisoned padding), and lies outside the payload.
    var tag: ?u32 = null;
    i = 0;
    while (i < N) : (i += 1) {
        if (p1[i] != p2[i]) continue;
        if ((i >= fo and i < fo + 4) or (i >= so and i < so + 4) or (i >= eo and i < eo + 4)) continue;
        if (p1[i] != ps[i]) {
            if (tag != null) return out; // ambiguous: decline
            tag = i;
        }
    }
    const to = tag orelse return out;
    out.file_off = fo;
    out.start_off = so;
    out.end_off = eo;
    out.tag_off = to;
    out.tag_set = ps[to];
    out.usable = 1;
    return out;
}

fn objViewOff() bool {
    const v = std.c.getenv("KLIO_OBJVIEW") orelse return false;
    return std.mem.span(v).len != 0 and std.mem.span(v)[0] == '0';
}

export fn klio_rt_hot_layout(out: *HotLayout) void {
    if (std.c.getenv("KLIO_NATIVE_TRACE") != null) std.debug.print("[rt] hot_layout enter out=0x{x}\n", .{@intFromPtr(out)});
    const t = tagOffset();
    if (std.c.getenv("KLIO_NATIVE_TRACE") != null) std.debug.print("[rt] tagOffset off={d} size={d}\n", .{ t.off, t.size });
    var vi: runtime.Value = undefined;
    var vl: runtime.Value = undefined;
    var vb: runtime.Value = undefined;
    var vu: runtime.Value = undefined;
    var vc: runtime.Value = undefined;
    var vinst: runtime.Value = undefined;
    @memset(std.mem.asBytes(&vi), 0);
    @memset(std.mem.asBytes(&vl), 0);
    @memset(std.mem.asBytes(&vb), 0);
    @memset(std.mem.asBytes(&vu), 0);
    @memset(std.mem.asBytes(&vc), 0);
    @memset(std.mem.asBytes(&vinst), 0);
    vinst = .{ .Instance = undefined };
    vi = .{ .Int = 0 };
    vl = .{ .Long = 0 };
    vb = .{ .Bool = false };
    vu = .{ .Unit = {} };
    vc = .{ .Char = 0 };
    const sp = spanProbe();
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
        .tag_unit = readTag(&vu, t.off, t.size),
        // The run path turns per-thread reclaim OFF unless the process
        // explicitly requested a reclaim mode (KLIO_RECLAIM); the live
        // flag is not yet set on this thread when the slot fills, so the
        // request is the decision that matters.
        .usable = @intFromBool(!runtime.reclaimRequested()),
        // The trace store has no ownership semantics, so span inlining
        // only needs the probe to have succeeded — any reclaim mode.
        .span_usable = sp.usable,
        .span_file_off = sp.file_off,
        .span_start_off = sp.start_off,
        .span_end_off = sp.end_off,
        .span_tag_off = sp.tag_off,
        .span_tag_set = sp.tag_set,
        .char_off = @intCast(@intFromPtr(&vc.Char) - @intFromPtr(&vc)),
        .tag_char = readTag(&vc, t.off, t.size),
        // Object view: only under the tracing GC, where a register write is
        // a plain copy (the reclaim backends would owe a retain).
        // KLIO_OBJVIEW=0 keeps field reads on the escape helper, for
        // single-binary A/B of the inline object view.
        .obj_usable = @intFromBool(!runtime.reclaimRequested() and !objViewOff()),
        .tag_instance = @intFromEnum(@as(std.meta.Tag(runtime.Value), .Instance)),
        .inst_ptr_off = @intCast(@intFromPtr(&vinst.Instance) - @intFromPtr(&vinst)),
        .cell_data_off = @offsetOf(InstCell, "data"),
        .inst_class_off = @offsetOf(runtime.InstanceData, "class"),
        .inst_fields_off = @offsetOf(runtime.InstanceData, "fields"),
        .fields_ptr_off = @offsetOf(FieldList, "items") + SLICE_PTR_OFF,
        .fields_len_off = @offsetOf(FieldList, "items") + SLICE_LEN_OFF,
        .field_stride = @sizeOf(runtime.InstanceData.Field),
        .field_value_off = @offsetOf(runtime.InstanceData.Field, "value"),
    };
    if (std.c.getenv("KLIO_NATIVE_TRACE") != null)
        std.debug.print("[rt] wrote usable={d} vsize={d} (sizeOf={d}) reclaimReq={}\n", .{ out.usable, out.value_size, @sizeOf(runtime.Value), runtime.reclaimRequested() });
}

/// Library version tag for the header/link handshake.
export fn klio_rt_abi_version() c_int {
    return 4;
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

export fn klio_op_field_route(ctx: *anyopaque, block: u32, inst_idx: u32, cls_out: *u64, slot_out: *i32) i32 {
    return eval.nativeOpFieldRoute(ctxOf(ctx), block, inst_idx, cls_out, slot_out);
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
