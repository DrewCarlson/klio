//! The C ABI surface of the klio runtime (`plans/c-transpiler-plan.md (git history)`):
//! program bootstrap plus the per-op helpers the transpiled C calls. The
//! helpers are thin casts into the evaluator's own arm bodies
//! (`ir.eval.nativeOp*`), so the emitted code shares interpreter
//! semantics by construction.

const std = @import("std");
const cli = @import("cli");
const runtime = @import("runtime");
const ir = @import("ir");
const eval = ir.eval;
const stdlib = @import("stdlib");

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

fn runFileBody(path: [:0]const u8) c_int {
    runtime.perf.setProfile(runtime.perf.resolveBinaryProfile(&.{}));
    fillHotLayoutSlot();
    // The same backing the `klio` binary installs for the resolved profile:
    // the default is the collector over the page-returning slab, not the
    // never-free arena this used to hardcode.
    var arena: ?std.heap.ArenaAllocator = null;
    defer if (arena) |*a| a.deinit();
    const gpa = runtime.allocTrackWrap(runtime.backing.processAllocator(&arena));
    var features = cli.commands.RequestedFeatures.init(gpa);
    defer features.deinit();
    return @intCast(cli.commands.runFileIrVm(gpa, path, &features));
}

/// Run the Kotlin program at `path` exactly as `klio run <path>` would,
/// on the default process-lifetime arena profile. Returns the process
/// exit code (0 success, 1 diagnostics/runtime error).
///
/// The work runs on an explicit large stack, switched to in place on the
/// calling thread: a transpiled binary's C `main` runs on the libc crt with
/// whatever the process rlimit gives (typically 8MB), and lowering a
/// deeply-nested expression recurses past that. The switch keeps the program
/// on the thread the caller invoked it from — the process main thread for the
/// emitted `main`, which is where a program that opens a window must run.
export fn klio_rt_run_file(path: [*:0]const u8) c_int {
    runtime.tls_fast.claimOwner();
    runtime.runstats.markStart();
    return runtime.runOnBigStackMainThread([:0]const u8, c_int, runFileBody, std.mem.span(path));
}

const ImageRunCtx = struct {
    base: [:0]const u8,
    path: [:0]const u8,
};

fn runProgramImageBody(image_path: [:0]const u8) c_int {
    runtime.perf.setProfile(runtime.perf.resolveBinaryProfile(&.{}));
    fillHotLayoutSlot();
    var arena: ?std.heap.ArenaAllocator = null;
    defer if (arena) |*a| a.deinit();
    const gpa = runtime.allocTrackWrap(runtime.backing.processAllocator(&arena));
    return @intCast(cli.bundle.runProgramImage(gpa, image_path, &.{}));
}

fn runImageBody(ctx: ImageRunCtx) c_int {
    runtime.perf.setProfile(runtime.perf.resolveBinaryProfile(&.{}));
    fillHotLayoutSlot();
    var arena: ?std.heap.ArenaAllocator = null;
    defer if (arena) |*a| a.deinit();
    const gpa = runtime.allocTrackWrap(runtime.backing.processAllocator(&arena));
    return @intCast(cli.bundle.runImage(gpa, ctx.base, &.{ctx.path}, &.{}));
}

/// Run the Kotlin program at `path` against the pre-baked dependency base
/// at `base_image`, exactly as `klio run-image` would. This is the entry
/// transpiled programs use: the emitted ids are only meaningful against
/// the module assembled from that exact artifact. Same large-stack switch
/// as `klio_rt_run_file`.
export fn klio_rt_run_image(base_image: [*:0]const u8, path: [*:0]const u8) c_int {
    runtime.tls_fast.claimOwner();
    runtime.runstats.markStart();
    return runtime.runOnBigStackMainThread(ImageRunCtx, c_int, runImageBody, .{
        .base = std.mem.span(base_image),
        .path = std.mem.span(path),
    });
}

/// Run the whole-program image at `path`: the module is complete, so this
/// neither parses nor lowers — the boot a bundle gets, for a transpiled binary.
/// The emitted ids are meaningful against exactly this artifact.
export fn klio_rt_run_program_image(image_path: [*:0]const u8) c_int {
    runtime.tls_fast.claimOwner();
    runtime.runstats.markStart();
    return runtime.runOnBigStackMainThread([:0]const u8, c_int, runProgramImageBody, std.mem.span(image_path));
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

// ---------------------------------------------------------------------------
// The native object ABI: what a COMPILED program calls.
//
// Compiled code is the program — there is no module to look a class up in — so
// a class arrives as an emitted descriptor and is built here at startup. From
// then on a field is addressed by its index, resolved when the C was written,
// so nothing on this path searches by name.
//
// Instances are ordinary `InstanceData` cells, which is what lets a compiled
// object flow into runtime collections, print through the runtime's renderer,
// and be traced by the collector exactly as an interpreted one is.
// ---------------------------------------------------------------------------

/// A `Value` as C sees it: two words, no tag union. Compiled code never reads
/// the inside; it hands them back to the entry points below.
/// The C-ABI shape of a `Value`, and the conversions, live in the runtime: the
/// coroutine driver resumes NATIVE continuations through the same form, so one
/// definition serves both.
pub const CValue = runtime.CValue;
const toC = runtime.toC;
const fromC = runtime.fromC;

comptime {
    if (@sizeOf(runtime.Value) != @sizeOf(CValue)) {
        @compileError("the native ABI passes a Value as two words; it is no longer that size");
    }
}

fn natAlloc() std.mem.Allocator {
    return std.heap.c_allocator;
}

var nat_classes: std.ArrayListUnmanaged(runtime.ObjRef(runtime.ClassDef)) = .empty;

/// Per-instance identity, the same monotonic counter the interpreter keeps.
var nat_identity = std.atomic.Value(u64).init(1);

fn nextNatIdentity() u64 {
    return nat_identity.fetchAdd(1, .monotonic);
}

/// Register an emitted class and return the handle its allocations use. Called
/// once per class before `main` runs.
/// Class shape bits, matching the header's. A data class renders and compares
/// by its primary constructor's properties, an enum entry by its name, and an
/// object by the declaration's.
const KLIO_CLASS_DATA: u32 = 1;
const KLIO_CLASS_ENUM: u32 = 2;
const KLIO_CLASS_OBJECT: u32 = 4;

/// Register a class the emitter laid out. `primary_lo`/`primary_hi` name the
/// slice of `field_names` that is the primary constructor's properties, in
/// declaration order: a data class renders and compares by exactly those, so
/// they have to be recorded rather than inferred from the field list.
export fn klio_nat_class(
    name: [*:0]const u8,
    n_fields: u32,
    field_names: [*]const [*:0]const u8,
    primary_lo: u32,
    primary_hi: u32,
    flags: u32,
    field_zeros: ?[*]const u8,
) u32 {
    const a = natAlloc();
    const nm = std.mem.span(name);
    const props = a.alloc(runtime.PropertyDef, n_fields) catch @panic("klio_nat_class: out of memory");
    var i: u32 = 0;
    while (i < n_fields) : (i += 1) {
        props[i] = .{
            .name = std.mem.span(field_names[i]),
            .mutable = true,
            .init = null,
            .getter = null,
            .setter = null,
            .delegate = null,
            .is_abstract = false,
            .is_lateinit = false,
            // A backing field exists from allocation holding its type's zero,
            // exactly as on the JVM: a superclass constructor that calls an
            // overridden method sees the subclass's field as 0/false/null.
            .primitive_zero = if (field_zeros) |fz| zeroOfKind(fz[i]) else null,
        };
    }
    const cls = runtime.ObjRef(runtime.ClassDef).init(a, .{
        .name = nm,
        .fqn = nm,
        .annotation_names = &.{},
        .primary_params = blk: {
            if (primary_hi <= primary_lo or primary_hi > n_fields) break :blk &.{};
            const n = primary_hi - primary_lo;
            const ps = a.alloc(runtime.ClassParamDef, n) catch @panic("klio_nat_class: out of memory");
            var pi: u32 = 0;
            while (pi < n) : (pi += 1) {
                ps[pi] = .{
                    .property = true,
                    .name = std.mem.span(field_names[primary_lo + pi]),
                    .default = null,
                    .declared_type = null,
                    .declared_shape = null,
                };
            }
            break :blk ps;
        },
        .methods = &.{},
        .body_properties = props,
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = (flags & KLIO_CLASS_DATA) != 0,
        .is_value = false,
        .is_object = (flags & KLIO_CLASS_OBJECT) != 0,
        .is_enum = (flags & KLIO_CLASS_ENUM) != 0,
        .is_sealed = false,
        .supertype_names = &.{},
        .parent = null,
        .interfaces = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = false,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = runtime.ObjRef(?runtime.ObjRef(runtime.InstanceData)).init(a, null) catch @panic("oom"),
        .enclosing_class = runtime.ObjRef(?runtime.ObjRef(runtime.ClassDef)).init(a, null) catch @panic("oom"),
        .nested_classes = &.{},
        .captured_env = runtime.ObjRef(runtime.Env).init(a, runtime.Env.init(a)) catch @panic("oom"),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = runtime.ObjRef(?runtime.ObjRef(runtime.InstanceData)).init(a, null) catch @panic("oom"),
    }) catch @panic("klio_nat_class: out of memory");
    nat_classes.append(a, cls) catch @panic("klio_nat_class: out of memory");
    return @intCast(nat_classes.items.len - 1);
}

/// A fresh instance of a registered class, every field Unit. The compiled
/// constructor stores the real values through `klio_nat_set`.
export fn klio_nat_alloc_instance(cls: u32) CValue {
    const a = natAlloc();
    const def = nat_classes.items[cls];
    const g = def.borrow();
    const n = g.get().body_properties.len;
    const names = g.get().body_properties;
    var fields: std.ArrayList(runtime.InstanceData.Field) = .empty;
    fields.ensureTotalCapacity(a, n) catch @panic("klio_nat_alloc_instance: out of memory");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        fields.appendAssumeCapacity(.{
            .name = names[i].name,
            .value = names[i].primitive_zero orelse .Null,
        });
    }
    g.deinit();
    const inst = runtime.ObjRef(runtime.InstanceData).init(a, .{
        .class = def.clone(),
        .fields = fields,
        .outer = null,
        .identity = nextNatIdentity(),
        .native_state = null,
    }) catch @panic("klio_nat_alloc_instance: out of memory");
    return toC(.{ .Instance = inst });
}

export fn klio_nat_get(recv: CValue, idx: u32) CValue {
    const v = fromC(recv);
    if (v != .Instance) natNpe();
    const g = v.Instance.borrow();
    defer g.deinit();
    return toC(g.get().fields.items[idx].value);
}

export fn klio_nat_set(recv: CValue, idx: u32, val: CValue) void {
    const v = fromC(recv);
    if (v != .Instance) natNpe();
    const g = v.Instance.borrowMut();
    defer g.deinit();
    const slot = &g.get().fields.items[idx];
    slot.value = fromC(val);
    runtime.gc.writeBarrier(&v.Instance.cell.hdr);
}

// --- roots -----------------------------------------------------------------
//
// The collector is precisely rooted and never scans the native stack, so a
// compiled frame publishes its object slots here. Scalars stay in C locals and
// are not published: nothing on the heap depends on them.

pub const NatFrame = extern struct {
    prev: ?*NatFrame,
    n: u32,
    slots: [*]CValue,
};

threadlocal var nat_top: ?*NatFrame = null;

export fn klio_nat_enter(f: *NatFrame) void {
    f.prev = nat_top;
    nat_top = f;
}

export fn klio_nat_leave(f: *NatFrame) void {
    nat_top = f.prev;
}

fn markNatFrames(m: *runtime.gc.Marker) void {
    var cur = nat_top;
    while (cur) |f| : (cur = f.prev) {
        var i: u32 = 0;
        while (i < f.n) : (i += 1) {
            var v = fromC(f.slots[i]);
            v.gcMark(m);
        }
    }
}

var nat_roots_registered = false;

/// Called once by generated code before `main`. Turns the collector on and
/// installs its view of compiled frames. Without this a compiled program never
/// collects: the GC is normally armed by the `klio_rt_run_*` entries, and a
/// compiled program calls none of them.
export fn klio_nat_init(void_arg: u32) void {
    _ = void_arg;
    if (nat_roots_registered) return;
    nat_roots_registered = true;
    runtime.gc.registerRoot(markNatFrames);
    runtime.backing.configureGcFromEnv();
}

/// Called after the emitted class descriptors are registered and before the
/// program body runs. Cells minted up to here are program-lifetime (the class
/// graph) and stay off the sweep registry; everything the body allocates is
/// collectable. The interpreter flips the same switch in `vmRun`, which a
/// compiled program never reaches — without this every allocation is minted
/// permanent and the heap only grows.
export fn klio_nat_begin() void {
    runtime.gc.alloc_perm = false;
}

/// The safe point. Compiled code polls at loop back edges, which is where an
/// allocating loop would otherwise run to the end of the heap: every slot the
/// collector may follow is in a published frame at that moment, and nothing
/// holds a borrow across it.
export fn klio_nat_safepoint() void {
    if (!runtime.gc.pending()) return;
    runtime.gc.collect();
}

// --- boxing ----------------------------------------------------------------

export fn klio_nat_box_int(v: i32) CValue {
    return toC(.{ .Int = v });
}
export fn klio_nat_box_long(v: i64) CValue {
    return toC(.{ .Long = v });
}
export fn klio_nat_box_double(v: f64) CValue {
    return toC(.{ .Double = v });
}
export fn klio_nat_box_float(v: f32) CValue {
    return toC(.{ .Float = v });
}
export fn klio_nat_box_bool(v: i32) CValue {
    return toC(.{ .Bool = v != 0 });
}
export fn klio_nat_box_unit() CValue {
    return toC(.Unit);
}
export fn klio_nat_int(v: CValue) i32 {
    return fromC(v).Int;
}
export fn klio_nat_long(v: CValue) i64 {
    return fromC(v).Long;
}
export fn klio_nat_double(v: CValue) f64 {
    return fromC(v).Double;
}
export fn klio_nat_float(v: CValue) f32 {
    return fromC(v).Float;
}
export fn klio_nat_bool(v: CValue) i32 {
    return if (fromC(v).Bool) 1 else 0;
}

// --- strings ---------------------------------------------------------------

/// A string literal, materialised once per evaluation of its `Const`.
export fn klio_nat_string(bytes: [*]const u8, len: usize) CValue {
    const a = natAlloc();
    const s = runtime.strInit(a, bytes[0..len]) catch @panic("klio_nat_string: out of memory");
    return toC(.{ .String = s });
}

/// `a + b` where either side is a string. Kotlin renders the other operand
/// through its own `toString`, which is what `Value.display` is.
export fn klio_nat_concat(av: CValue, bv: CValue) CValue {
    const a = natAlloc();
    const x = fromC(av);
    const y = fromC(bv);
    const xs = x.display(a) catch @panic("klio_nat_concat: out of memory");
    defer a.free(xs);
    const ys = y.display(a) catch @panic("klio_nat_concat: out of memory");
    defer a.free(ys);
    const joined = std.mem.concat(a, u8, &.{ xs, ys }) catch @panic("klio_nat_concat: out of memory");
    const s = runtime.strInitOwned(a, joined) catch @panic("klio_nat_concat: out of memory");
    return toC(.{ .String = s });
}

/// Kotlin's `length` counts UTF-16 code units, which is not the byte count.
export fn klio_nat_str_length(v: CValue) i32 {
    const s = fromC(v);
    const g = s.String.borrow();
    defer g.deinit();
    return @intCast(stdlib.text.utf16Len(g.get().bytes));
}

fn natWrite(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(1, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

/// Print a value the way the interpreter prints it. Compiled code uses this
/// for anything but a plain scalar, so rendering never drifts from the
/// interpreter's.
export fn klio_nat_println(v: CValue) void {
    const a = natAlloc();
    const val = fromC(v);
    const txt = val.display(a) catch @panic("klio_nat_println: out of memory");
    defer a.free(txt);
    natWrite(txt);
    natWrite("\n");
}

export fn klio_nat_print(v: CValue) void {
    const a = natAlloc();
    const val = fromC(v);
    const txt = val.display(a) catch @panic("klio_nat_print: out of memory");
    defer a.free(txt);
    natWrite(txt);
}

// --- lists -----------------------------------------------------------------
//
// Collection operations are data-structure work on the runtime's own types, so
// a compiled program performs them directly rather than through any dispatch.
// The emitter recognises the stdlib entry points by name and calls these.

fn newValueList(argv: [*]const CValue, argc: u32, mutable: bool) CValue {
    const a = natAlloc();
    var items: std.ArrayList(runtime.Value) = .empty;
    items.ensureTotalCapacity(a, argc) catch @panic("klio_nat_list: out of memory");
    var i: u32 = 0;
    while (i < argc) : (i += 1) items.appendAssumeCapacity(fromC(argv[i]));
    const vl = runtime.ValueList.initOwned(a, items) catch @panic("klio_nat_list: out of memory");
    const v = runtime.Value.newList(a, .{
        .items = vl,
        .mutable = mutable,
        .backing = null,
    }) catch @panic("klio_nat_list: out of memory");
    return toC(v);
}

export fn klio_nat_list(argv: [*]const CValue, argc: u32) CValue {
    return newValueList(argv, argc, false);
}

export fn klio_nat_mutable_list(argv: [*]const CValue, argc: u32) CValue {
    return newValueList(argv, argc, true);
}

export fn klio_nat_list_size(v: CValue) i32 {
    const l = fromC(v);
    const g = l.List.items.borrow();
    defer g.deinit();
    return @intCast(g.get().items.len);
}

/// Kotlin throws on an out-of-range index; C would read past the end.
export fn klio_nat_list_get(v: CValue, idx: i32) CValue {
    const l = fromC(v);
    const g = l.List.items.borrow();
    defer g.deinit();
    const items = g.get().items;
    if (idx < 0 or @as(usize, @intCast(idx)) >= items.len) natIndexOob(idx, items.len);
    return toC(items[@intCast(idx)]);
}

export fn klio_nat_list_set(v: CValue, idx: i32, x: CValue) void {
    const l = fromC(v);
    const g = l.List.items.borrowMut();
    defer g.deinit();
    const items = g.get().items;
    if (idx < 0 or @as(usize, @intCast(idx)) >= items.len) natIndexOob(idx, items.len);
    items[@intCast(idx)] = fromC(x);
    runtime.gc.writeBarrier(&l.List.items.cell.hdr);
}

export fn klio_nat_list_add(v: CValue, x: CValue) void {
    const a = natAlloc();
    const l = fromC(v);
    const g = l.List.items.borrowMut();
    defer g.deinit();
    g.get().append(a, fromC(x)) catch @panic("klio_nat_list_add: out of memory");
    runtime.gc.writeBarrier(&l.List.items.cell.hdr);
}

// --- arrays ----------------------------------------------------------------
//
// A primitive array is a packed scalar buffer, so an `IntArray` holds int32
// elements rather than boxed values. The emitter knows the element kind
// statically and names it here, which is what keeps an indexed read a load
// rather than an unbox.

/// The zero of a field's declared type, in the emitter's own type order. Null
/// is the zero of every reference type.
fn zeroOfKind(k: u8) ?runtime.Value {
    return switch (k) {
        1 => runtime.Value.newInt(0),
        2 => .{ .Long = 0 },
        3 => .{ .Double = 0 },
        4 => .{ .Float = 0 },
        5 => .{ .Bool = false },
        6 => .{ .Char = 0 },
        7 => .{ .Short = 0 },
        8 => .{ .Byte = 0 },
        9 => .{ .UInt = 0 },
        10 => .{ .ULong = 0 },
        11 => .{ .UShort = 0 },
        12 => .{ .UByte = 0 },
        else => null,
    };
}

fn primKindOf(kind: u32) runtime.PrimitiveArrayKind {
    return switch (kind) {
        0 => .Int,
        1 => .Long,
        2 => .Double,
        3 => .Float,
        4 => .Short,
        5 => .Byte,
        6 => .Boolean,
        7 => .Char,
        else => .Int,
    };
}

/// A zero-filled primitive array of `n` elements. `kind` is the element kind,
/// in the order the emitter's `Ty` names them.
export fn klio_nat_prim_array(kind: u32, n: i32) CValue {
    const a = natAlloc();
    if (n < 0) natNegativeSize(n);
    const k = primKindOf(kind);
    var pb = runtime.PrimBuf{ .kind = k };
    pb.bytes.appendNTimes(a, 0, @as(usize, @intCast(n)) * k.elemSize()) catch
        @panic("klio_nat_prim_array: out of memory");
    const cell = runtime.ObjRef(runtime.PrimBuf).initOwned(a, pb) catch
        @panic("klio_nat_prim_array: out of memory");
    return toC(.{ .Array = runtime.ArrayData.scalars(cell, k) });
}

/// A primitive array holding the given elements.
export fn klio_nat_prim_array_of(kind: u32, argv: [*]const CValue, argc: u32) CValue {
    const a = natAlloc();
    const items = a.alloc(runtime.Value, argc) catch @panic("klio_nat_prim_array_of: out of memory");
    defer a.free(items);
    var i: u32 = 0;
    while (i < argc) : (i += 1) items[i] = fromC(argv[i]);
    return toC(runtime.ArrayData.initPacked(a, primKindOf(kind), items) catch
        @panic("klio_nat_prim_array_of: out of memory"));
}

/// A reference `Array<T>` holding the given elements.
export fn klio_nat_ref_array(argv: [*]const CValue, argc: u32) CValue {
    const a = natAlloc();
    var items: std.ArrayList(runtime.Value) = .empty;
    items.ensureTotalCapacity(a, argc) catch @panic("klio_nat_ref_array: out of memory");
    var i: u32 = 0;
    while (i < argc) : (i += 1) items.appendAssumeCapacity(fromC(argv[i]));
    const vl = runtime.ValueList.initOwned(a, items) catch @panic("klio_nat_ref_array: out of memory");
    return toC(runtime.ArrayData.fromBoxedList(vl));
}

/// A reference `Array<T>` of `n` nulls.
export fn klio_nat_ref_array_sized(n: i32) CValue {
    const a = natAlloc();
    if (n < 0) natNegativeSize(n);
    var items: std.ArrayList(runtime.Value) = .empty;
    items.appendNTimes(a, .Null, @intCast(n)) catch @panic("klio_nat_ref_array_sized: out of memory");
    const vl = runtime.ValueList.initOwned(a, items) catch @panic("klio_nat_ref_array_sized: out of memory");
    return toC(runtime.ArrayData.fromBoxedList(vl));
}

export fn klio_nat_array_size(v: CValue) i32 {
    return @intCast(fromC(v).Array.len());
}

export fn klio_nat_array_get(v: CValue, idx: i32) CValue {
    const arr = fromC(v).Array;
    const n = arr.len();
    if (idx < 0 or @as(usize, @intCast(idx)) >= n) natIndexOob(idx, n);
    return toC(arr.get(@intCast(idx)));
}

export fn klio_nat_array_set(v: CValue, idx: i32, x: CValue) void {
    const arr = fromC(v).Array;
    const n = arr.len();
    if (idx < 0 or @as(usize, @intCast(idx)) >= n) natIndexOob(idx, n);
    arr.set(natAlloc(), @intCast(idx), fromC(x));
    switch (arr.storage()) {
        .boxed => |vl| runtime.gc.writeBarrier(&vl.cell.hdr),
        .scalars => {},
    }
}

fn natNegativeSize(n: i32) noreturn {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "Exception in thread \"main\" java.lang.NegativeArraySizeException: {d}\n",
        .{n},
    ) catch "Exception in thread \"main\" java.lang.NegativeArraySizeException\n";
    _ = std.c.write(2, msg.ptr, msg.len);
    std.c.exit(1);
}

// --- coroutines ------------------------------------------------------------
//
// A compiled suspend function keeps its registers in a heap frame and answers
// either its result or COROUTINE_SUSPENDED. When it suspends it pushes its own
// continuation — the emitted resume function plus that frame — onto the
// suspension the interpreter's coroutine driver already knows how to park.
// Everything above that point is shared: the scheduler, the virtual clock, the
// Job graph, `delay`, `runBlocking`.

/// What the coroutine driver needs from a COMPILED program. The driver is the
/// interpreter's own — the scheduler, the virtual clock, the Job graph, the
/// park and resume order — and it asks its host for exactly two things: start a
/// queued block, and resume a parked continuation. In a compiled program both
/// are native calls, so the whole driver is shared rather than written twice.
const NativeCoroHost = struct {
    allocator: std.mem.Allocator,
    launched: u32 = 0,

    /// A queued child. In a compiled program every closure is one of the
    /// emitted lambda classes, dispatched through the value protocol.
    pub fn evalClosureRaw(
        self: *NativeCoroHost,
        block: *const runtime.Value,
        args: []const runtime.Value,
        scope: ?*const runtime.Value,
        out: runtime.Output,
    ) std.mem.Allocator.Error!ir.eval.EvalResult {
        _ = self;
        _ = args;
        _ = scope;
        _ = out;
        _ = block;
        return .{ .err = .{ .Type = "a compiled program cannot start a closure child yet" } };
    }

    pub fn resumeRaw(
        self: *NativeCoroHost,
        state: *ir.eval.SuspendState,
        value: runtime.Value,
        out: runtime.Output,
    ) std.mem.Allocator.Error!ir.eval.EvalResult {
        _ = out;
        // Every snapshot in a compiled program's suspension is native, so the
        // replay is a sequence of calls: no module, no frame rebuild, and no
        // need to instantiate the evaluator against a stub host.
        return ir.eval.resumeNativeContinuation(self.allocator, state, value);
    }
};

/// Where the driver's own writes go in a compiled program: the same descriptor
/// every other emitted print uses, so ordering is one stream.
const nat_out_vtable: runtime.Output.VTable = .{
    .writeln = struct {
        fn f(ctx: *anyopaque, str: []const u8) void {
            _ = ctx;
            natWrite(str);
            natWrite("\n");
        }
    }.f,
    .write = struct {
        fn f(ctx: *anyopaque, str: []const u8) void {
            _ = ctx;
            natWrite(str);
        }
    }.f,
};
var nat_out_ctx: u8 = 0;

fn natOutput() runtime.Output {
    return .{ .ctx = @ptrCast(&nat_out_ctx), .vtable = &nat_out_vtable };
}

/// Run a compiled `runBlocking { … }` body to completion on the shared driver.
export fn klio_nat_run_blocking(
    call: *const fn (?*anyopaque, CValue) callconv(.c) CValue,
    frame: ?*anyopaque,
) CValue {
    var host: NativeCoroHost = .{ .allocator = natAlloc() };
    const res = cli.interp_ir.coroutines_diag.driveRootNative(&host, call, frame, natOutput()) catch
        @panic("klio_nat_run_blocking: out of memory");
    return switch (res) {
        .ok => |v| toC(v),
        .err => toC(.Unit),
    };
}

/// The value a suspending call answers with when it did not produce a result.
export fn klio_nat_suspended() CValue {
    return toC(.CoroutineSuspended);
}

export fn klio_nat_is_suspended(v: CValue) i32 {
    return @intFromBool(fromC(v) == .CoroutineSuspended);
}

/// Park the calling frame: record its continuation and answer SUSPENDED. Each
/// emitted frame calls this as it unwinds, innermost first, which is the order
/// the driver replays them in.
export fn klio_nat_coro_park(
    call: *const fn (?*anyopaque, CValue) callconv(.c) CValue,
    frame: ?*anyopaque,
) CValue {
    ir.eval.pushNativePark(natAlloc(), call, frame, 0) catch
        @panic("klio_nat_coro_park: out of memory");
    return toC(.CoroutineSuspended);
}

/// `delay(millis)`: ask the driver to resume after that much virtual time. The
/// caller parks itself on the way out like any other suspension.
export fn klio_nat_coro_delay(
    millis: i64,
    call: *const fn (?*anyopaque, CValue) callconv(.c) CValue,
    frame: ?*anyopaque,
) CValue {
    ir.eval.pushNativePark(natAlloc(), call, frame, millis) catch
        @panic("klio_nat_coro_delay: out of memory");
    return toC(.CoroutineSuspended);
}

fn natIndexOob(idx: i32, len: usize) noreturn {
    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "Exception in thread \"main\" java.lang.IndexOutOfBoundsException: Index {d} out of bounds for length {d}\n",
        .{ idx, len },
    ) catch "Exception in thread \"main\" java.lang.IndexOutOfBoundsException\n";
    _ = std.c.write(2, msg.ptr, msg.len);
    std.c.exit(1);
}

// --- null and reference comparison -----------------------------------------

export fn klio_nat_null() CValue {
    return toC(.Null);
}

export fn klio_nat_is_null(v: CValue) i32 {
    return if (fromC(v) == .Null) 1 else 0;
}

/// Kotlin's `==` on references: structural equality, which for a null operand
/// is a null test and otherwise is the runtime's own comparison.
export fn klio_nat_value_eq(av: CValue, bv: CValue) i32 {
    const a = fromC(av);
    const b = fromC(bv);
    return if (a.structuralEq(&b)) 1 else 0;
}

fn natNpe() noreturn {
    const msg = "Exception in thread \"main\" java.lang.NullPointerException\n";
    _ = std.c.write(2, msg.ptr, msg.len);
    std.c.exit(1);
}

// --- the remaining scalar kinds --------------------------------------------
//
// `Char` prints as a character and `Short`/`Byte` render as themselves, so they
// cannot simply ride in an `Int`: the box has to carry the kind.

export fn klio_nat_box_char(v: u16) CValue {
    return toC(.{ .Char = v });
}
export fn klio_nat_box_short(v: i16) CValue {
    return toC(.{ .Short = v });
}
export fn klio_nat_box_byte(v: i8) CValue {
    return toC(.{ .Byte = v });
}
export fn klio_nat_char(v: CValue) u16 {
    return fromC(v).Char;
}
export fn klio_nat_short(v: CValue) i16 {
    return fromC(v).Short;
}
export fn klio_nat_byte(v: CValue) i8 {
    return fromC(v).Byte;
}

// Kotlin's unsigned integers are value classes over the signed widths: the
// bits are the same, and only the box's kind and the operations differ.

export fn klio_nat_box_uint(v: u32) CValue {
    return toC(.{ .UInt = v });
}
export fn klio_nat_box_ulong(v: u64) CValue {
    return toC(.{ .ULong = v });
}
export fn klio_nat_box_ushort(v: u16) CValue {
    return toC(.{ .UShort = v });
}
export fn klio_nat_box_ubyte(v: u8) CValue {
    return toC(.{ .UByte = v });
}
export fn klio_nat_uint(v: CValue) u32 {
    return fromC(v).UInt;
}
export fn klio_nat_ulong(v: CValue) u64 {
    return fromC(v).ULong;
}
export fn klio_nat_ushort(v: CValue) u16 {
    return fromC(v).UShort;
}
export fn klio_nat_ubyte(v: CValue) u8 {
    return fromC(v).UByte;
}

/// The registered class handle of an instance, which is what a compiled
/// dispatcher switches on. A value that is not an instance, or an instance of a
/// class this program did not register, reports no class.
export fn klio_nat_class_of(v: CValue) u32 {
    const val = fromC(v);
    if (val != .Instance) return std.math.maxInt(u32);
    const g = val.Instance.borrow();
    const cls = g.get().class;
    g.deinit();
    for (nat_classes.items, 0..) |c, i| {
        if (c.cell == cls.cell) return @intCast(i);
    }
    return std.math.maxInt(u32);
}

/// A virtual call that reached a receiver no arm handles. The interpreter would
/// raise a dispatch failure; a compiled program has no interpreter to fall into,
/// so it says so and stops rather than running the wrong body.
export fn klio_nat_no_method(name: [*:0]const u8) noreturn {
    const nm = std.mem.span(name);
    const pre = "Exception in thread \"main\" java.lang.AbstractMethodError: no implementation of ";
    _ = std.c.write(2, pre.ptr, pre.len);
    _ = std.c.write(2, nm.ptr, nm.len);
    _ = std.c.write(2, "\n", 1);
    std.c.exit(1);
}

// --- capture cells ---------------------------------------------------------
//
// A `var` a lambda captures becomes a shared box: the lambda and the enclosing
// function must see each other's writes, so the variable moves to the heap.

export fn klio_nat_cell(v: CValue) CValue {
    const a = natAlloc();
    return toC(runtime.Value.newCell(a, fromC(v)) catch @panic("klio_nat_cell: out of memory"));
}

export fn klio_nat_cell_get(c: CValue) CValue {
    const v = fromC(c);
    const g = v.Cell.borrow();
    defer g.deinit();
    return toC(g.get().*);
}

export fn klio_nat_cell_set(c: CValue, v: CValue) void {
    const cv = fromC(c);
    const g = cv.Cell.borrowMut();
    defer g.deinit();
    g.get().* = fromC(v);
    runtime.gc.writeBarrier(&cv.Cell.cell.hdr);
}

/// An uncaught throw. A program the backend accepts has no catch handler
/// anywhere — any block carrying one is refused — so a throw always leaves the
/// program, and this reports it the way an uncaught exception is reported.
export fn klio_nat_throw(v: CValue) noreturn {
    const a = natAlloc();
    const val = fromC(v);
    const txt = val.display(a) catch "exception";
    // The interpreter's wording, so a compiled program reports an uncaught
    // throw the way the same program reports it interpreted. The stack trace
    // it prints below this line has no compiled equivalent.
    const pre = "runtime error: uncaught ";
    _ = std.c.write(2, pre.ptr, pre.len);
    _ = std.c.write(2, txt.ptr, txt.len);
    _ = std.c.write(2, "\n", 1);
    std.c.exit(1);
}

/// A throwable of the named type. The exception classes are the runtime's own,
/// not shapes the emitter lays out, so a compiled program builds one through
/// here rather than as an instance with fields. `type_id` is the type's
/// preorder number in the program's throwable hierarchy, which is what a
/// handler tests against.
export fn klio_nat_exception(fqn: [*:0]const u8, message: CValue, type_id: u32) CValue {
    const a = natAlloc();
    const name = runtime.strInit(a, std.mem.span(fqn)) catch @panic("klio_nat_exception: out of memory");
    var msg: runtime.OptRef(runtime.StringData) = .{};
    const mv = fromC(message);
    if (mv == .String) msg = .{ .cell = mv.String.cell };
    return toC(runtime.Value.newException(a, .{
        .fqn = name,
        .message = msg,
        .cause = null,
        .type_id = type_id,
    }) catch @panic("klio_nat_exception: out of memory"));
}

/// Whether a thrown value is caught by a handler for the type spanning
/// `[lo, hi)`. The emitter numbers the throwable hierarchy in preorder, so a
/// type's subtree is one contiguous interval and a subtype test is two
/// comparisons: no name matching, no walk, and a `catch (e: AppError)` sees
/// every type under `AppError` however deep.
export fn klio_nat_catches(v: CValue, lo: u32, hi: u32) i32 {
    const val = fromC(v);
    if (val != .Exception) return 0;
    const id = val.Exception.type_id;
    return @intFromBool(id >= lo and id < hi);
}

/// The current top of the published-frame chain, and a way back to it. A
/// `longjmp` to a handler skips every `klio_nat_leave` between the throw and
/// the catch, so without restoring this the collector would keep walking frames
/// whose C stack is gone.
export fn klio_nat_frame_mark() ?*NatFrame {
    return nat_top;
}

export fn klio_nat_frame_restore(mark: ?*NatFrame) void {
    nat_top = mark;
}
