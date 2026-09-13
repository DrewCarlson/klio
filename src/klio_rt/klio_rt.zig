//! The C ABI surface of the klio runtime: program bootstrap plus the per-op
//! helpers the transpiled C calls. The helpers are thin casts into the
//! evaluator's own arm bodies, so emitted code shares interpreter semantics.

const std = @import("std");
const cli = @import("cli");
const runtime = @import("runtime");
const ir = @import("ir");
const eval = ir.eval;
const stdlib = @import("stdlib");

/// Generated code registers its layout globals here. The run entries fill them
/// after the performance profile is chosen, since that decides `usable`.
var hot_layout_slot: ?*HotLayout = null;

export fn klio_rt_register_hot_layout(slot: *HotLayout) void {
    hot_layout_slot = slot;
}

/// The generated file's emit-time copy of the layout. A .c linked against a
/// runtime whose layout differs gets the whole hot view disabled.
var hot_frozen_slot: ?*const HotLayout = null;

export fn klio_rt_register_hot_frozen(frozen: *const HotLayout) void {
    hot_frozen_slot = frozen;
}

fn fillHotLayoutSlot() void {
    if (std.c.getenv("KLIO_NATIVE_TRACE") != null)
        std.debug.print("[rt] fillHotLayoutSlot slot=0x{x}\n", .{if (hot_layout_slot) |sl| @intFromPtr(sl) else 0});
    if (hot_layout_slot) |slot| {
        klio_rt_hot_layout(slot);
        // Frozen constants that disagree with the live layout read garbage.
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
    // The same backing the `klio` binary installs: the collector over the slab.
    var arena: ?std.heap.ArenaAllocator = null;
    defer if (arena) |*a| a.deinit();
    const gpa = runtime.allocTrackWrap(runtime.backing.processAllocator(&arena));
    var features = cli.commands.RequestedFeatures.init(gpa);
    defer features.deinit();
    return @intCast(cli.commands.runFileIrVm(gpa, path, &features));
}

/// Run the Kotlin program at `path` as `klio run` would. Returns the exit code,
/// 0 for success and 1 for diagnostics or a runtime error. Runs on an explicit
/// large stack switched to in place, since a transpiled binary's C `main` gets
/// only the process rlimit, and stays on the caller's thread so an emitted
/// `main` that opens a window keeps the process main thread.
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

/// Run `path` against the pre-baked dependency base `base_image`, as
/// `klio run-image` would. The emitted ids bind to that exact artifact.
export fn klio_rt_run_image(base_image: [*:0]const u8, path: [*:0]const u8) c_int {
    runtime.tls_fast.claimOwner();
    runtime.runstats.markStart();
    return runtime.runOnBigStackMainThread(ImageRunCtx, c_int, runImageBody, .{
        .base = std.mem.span(base_image),
        .path = std.mem.span(path),
    });
}

/// Run the whole-program image at `path`: the module is complete, so nothing
/// parses or lowers. The emitted ids bind to exactly this artifact.
export fn klio_rt_run_program_image(image_path: [*:0]const u8) c_int {
    runtime.tls_fast.claimOwner();
    runtime.runstats.markStart();
    return runtime.runOnBigStackMainThread([:0]const u8, c_int, runProgramImageBody, std.mem.span(image_path));
}

/// Byte offsets into `runtime.Value`, measured against the same build the
/// library runs. `usable` is false when the process runs a reclaim mode whose
/// register writes must release the old value; emitted code then uses helpers.
pub const HotLayout = ir.hot_layout.HotLayout;

fn objViewOff() bool {
    const v = std.c.getenv("KLIO_OBJVIEW") orelse return false;
    return std.mem.span(v).len != 0 and std.mem.span(v)[0] == '0';
}

export fn klio_rt_hot_layout(out: *HotLayout) void {
    if (std.c.getenv("KLIO_NATIVE_TRACE") != null) std.debug.print("[rt] hot_layout enter out=0x{x}\n", .{@intFromPtr(out)});
    ir.hot_layout.fillLayout(out);
    // Per-thread reclaim is off unless the process requested KLIO_RECLAIM, and
    // the live flag is unset here, so the request decides. KLIO_OBJVIEW=0 too.
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

/// Register a transpiled body for `fid`, run in place of the bytecode stream.
/// Call before `klio_rt_run_file`: the table is read-only once the program runs.
/// `fqn` guards the fid; a name mismatch is ignored.
export fn klio_rt_register_native(fid: u32, f: eval.NativeFn, fqn: [*:0]const u8) void {
    eval.registerNative(fid, f, std.mem.span(fqn));
}

/// Register a scalar-replay leaf body. Same fqn guard as `klio_rt_register_native`.
export fn klio_rt_register_native_leaf(fid: u32, f: eval.NativeLeafFn, fqn: [*:0]const u8) void {
    eval.registerNativeLeaf(fid, f, std.mem.span(fqn));
}

/// Declare the emitter's module table sizes. A frame whose module disagrees
/// runs interpreted: emitted const and func ids index these tables.
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

/// GC write barrier before the emitted C stores a Value into a cell.
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

// The native object ABI. Compiled code is the program, with no module to look a
// class up in, so a class arrives as an emitted descriptor built at startup and
// a field is addressed by index. Instances are ordinary `InstanceData` cells,
// so a compiled object flows into runtime collections and is traced normally.

/// A `Value` as C sees it: two words, no tag union, never read by compiled code.
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

/// Class shape bits: a data class compares by its primary ctor's properties.
const KLIO_CLASS_DATA: u32 = 1;
const KLIO_CLASS_ENUM: u32 = 2;
const KLIO_CLASS_OBJECT: u32 = 4;

/// `primary_lo`/`primary_hi` bound the slice of `field_names` that is the
/// primary constructor's properties, in declaration order.
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
            // A backing field holds its type's zero from allocation, as on the JVM.
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

/// A fresh instance of a registered class, every field Unit.
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

// Roots: the collector never scans the native stack, so a frame publishes its slots.

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
    // A suspend body's frame is not on the chain: it outlives its C stack.
    for (parked_frames.items) |pf| {
        var i: u32 = 0;
        while (i < pf.gcf.n) : (i += 1) {
            var v = fromC(pf.gcf.slots[i]);
            v.gcMark(m);
        }
    }
}

var nat_roots_registered = false;

/// Turns the collector on; a compiled program calls no `klio_rt_run_*` entry.
export fn klio_nat_init(void_arg: u32) void {
    _ = void_arg;
    if (nat_roots_registered) return;
    nat_roots_registered = true;
    runtime.gc.registerRoot(markNatFrames);
    runtime.backing.configureGcFromEnv();
}

/// Called between class registration and the program body: cells minted up to
/// here are program-lifetime and stay off the sweep registry.
export fn klio_nat_begin() void {
    runtime.gc.alloc_perm = false;
}

/// The safe point, polled at loop back edges; no borrow is held across it.
export fn klio_nat_safepoint() void {
    if (!runtime.gc.pending()) return;
    runtime.gc.collect();
}


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


export fn klio_nat_string(bytes: [*]const u8, len: usize) CValue {
    const a = natAlloc();
    const s = runtime.strInit(a, bytes[0..len]) catch @panic("klio_nat_string: out of memory");
    return toC(.{ .String = s });
}

/// `a + b` with a string operand; Kotlin renders the other through its `toString`.
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

/// Print a value the way the interpreter prints it, so rendering never drifts.
export fn klio_nat_println(v: CValue) void {
    const a = natAlloc();
    const val = fromC(v);
    const txt = val.display(a) catch @panic("klio_nat_println: out of memory");
    defer a.free(txt);
    natWrite(txt);
    natWrite("\n");
}

/// `x.toString()` with no override: the print renderer answers both.
export fn klio_nat_to_string(v: CValue) CValue {
    const a = natAlloc();
    const val = fromC(v);
    const txt = val.display(a) catch @panic("klio_nat_to_string: out of memory");
    return toC(.{ .String = runtime.strInitOwned(a, txt) catch
        @panic("klio_nat_to_string: out of memory") });
}

export fn klio_nat_print(v: CValue) void {
    const a = natAlloc();
    const val = fromC(v);
    const txt = val.display(a) catch @panic("klio_nat_print: out of memory");
    defer a.free(txt);
    natWrite(txt);
}

// Lists: collection work performed directly on the runtime's own types.

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

// Arrays: a primitive array is a packed scalar buffer of the emitter's element kind.

/// The zero of a field's declared type. Null is the zero of every reference type.
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

export fn klio_nat_prim_array_of(kind: u32, argv: [*]const CValue, argc: u32) CValue {
    const a = natAlloc();
    const items = a.alloc(runtime.Value, argc) catch @panic("klio_nat_prim_array_of: out of memory");
    defer a.free(items);
    var i: u32 = 0;
    while (i < argc) : (i += 1) items[i] = fromC(argv[i]);
    return toC(runtime.ArrayData.initPacked(a, primKindOf(kind), items) catch
        @panic("klio_nat_prim_array_of: out of memory"));
}

export fn klio_nat_ref_array(argv: [*]const CValue, argc: u32) CValue {
    const a = natAlloc();
    var items: std.ArrayList(runtime.Value) = .empty;
    items.ensureTotalCapacity(a, argc) catch @panic("klio_nat_ref_array: out of memory");
    var i: u32 = 0;
    while (i < argc) : (i += 1) items.appendAssumeCapacity(fromC(argv[i]));
    const vl = runtime.ValueList.initOwned(a, items) catch @panic("klio_nat_ref_array: out of memory");
    return toC(runtime.ArrayData.fromBoxedList(vl));
}

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

// Coroutines: a compiled suspend function keeps its registers in a heap frame
// and answers its result or COROUTINE_SUSPENDED, pushing its continuation onto
// the suspension the interpreter's driver already parks.

// The stdlib, called directly: a compiled program calls the same named table
// entries the interpreter does. It supplies only how to invoke a closure.

const LambdaInvoker = struct {
    arity: u32,
    call: *const fn (CValue, [*]const CValue) callconv(.c) CValue,
};
var lambda_invokers: std.ArrayList(LambdaInvoker) = .empty;

export fn klio_nat_lambda_invoker(arity: u32, call: *const fn (CValue, [*]const CValue) callconv(.c) CValue) void {
    lambda_invokers.append(natAlloc(), .{ .arity = arity, .call = call }) catch
        @panic("klio_nat_lambda_invoker: out of memory");
}

fn natInvokeCallable(ctx: *anyopaque, callable: *const runtime.Value, args: []const runtime.Value, out: runtime.Output) std.mem.Allocator.Error!runtime.EvalResult {
    _ = ctx;
    _ = out;
    var buf: [8]CValue = undefined;
    if (args.len > buf.len) return .{ .err = .{ .Type = "too many arguments for a compiled closure" } };
    for (args, 0..) |a, i| buf[i] = toC(a);
    for (lambda_invokers.items) |inv| {
        if (inv.arity != args.len) continue;
        return .{ .ok = fromC(inv.call(toC(callable.*), &buf)) };
    }
    return .{ .err = .{ .Type = "no compiled closure dispatcher of this arity" } };
}

fn natInvokeCallableWithThis(ctx: *anyopaque, callable: *const runtime.Value, args: []const runtime.Value, this_value: *const runtime.Value, out: runtime.Output) std.mem.Allocator.Error!runtime.EvalResult {
    _ = this_value;
    return natInvokeCallable(ctx, callable, args, out);
}

const nat_intrinsic_vtable: runtime.IntrinsicHost.VTable = .{
    .invoke_callable = natInvokeCallable,
    .invoke_callable_with_this = natInvokeCallableWithThis,
};
var nat_intrinsic_ctx: u8 = 0;

fn natIntrinsicHost() runtime.IntrinsicHost {
    return .{ .ctx = @ptrCast(&nat_intrinsic_ctx), .vtable = &nat_intrinsic_vtable };
}

/// Run one stdlib declaration by name; the receiver, if any, is the first argument.
export fn klio_nat_stdlib(fqn: [*:0]const u8, argv: [*]const CValue, argc: u32) CValue {
    const a = natAlloc();
    const name = std.mem.span(fqn);
    const impl = stdlib.implementations.lookup(name) orelse natNoStdlib(name);
    const args = a.alloc(runtime.Value, argc) catch @panic("klio_nat_stdlib: out of memory");
    defer a.free(args);
    var i: u32 = 0;
    while (i < argc) : (i += 1) args[i] = fromC(argv[i]);
    var ctx: runtime.CallCtx = .{
        .args = args,
        .out = natOutput(),
        .host = natIntrinsicHost(),
        .allocator = a,
    };
    const r = impl(&ctx) catch @panic("klio_nat_stdlib: out of memory");
    return switch (r) {
        .ok => |v| toC(v),
        .err => |e| natStdlibFailed(name, e),
    };
}

/// One builtin member call, named by the declaration the call site bound; a
/// compiled program has no module, so it reaches the same bodies here.
export fn klio_nat_member(fqn: [*:0]const u8, argv: [*]const CValue, argc: u32) CValue {
    const a = natAlloc();
    const name = std.mem.span(fqn);
    const dispatch = cli.interp_ir.member_dispatch;
    // A bare-name call site carries the member alone, with no qualifier to strip.
    const member = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name[dot + 1 ..] else name;
    if (argc == 0) natNoMember(name);
    const recv = fromC(argv[0]);
    const args = a.alloc(runtime.Value, argc - 1) catch @panic("klio_nat_member: out of memory");
    defer a.free(args);
    var i: u32 = 1;
    while (i < argc) : (i += 1) args[i - 1] = fromC(argv[i]);
    const r = if (dispatch.hostSlotOpOfFqn(name)) |op|
        dispatch.runHostFreeSlotOp(a, op, &recv, member, args) catch
            @panic("klio_nat_member: out of memory")
    else
        dispatch.hostFreeMemberByName(a, &recv, member, args) catch
            @panic("klio_nat_member: out of memory");
    const got = r orelse natNoMember(name);
    return switch (got) {
        .ok => |v| toC(v),
        .err => natMemberFailed(name),
    };
}

/// `x is T` from the value's own representation; instances test by class handle.
export fn klio_nat_is_type(v: CValue, name: [*:0]const u8, nullable: i32) i32 {
    const val = fromC(v);
    // `null is T?` holds for any nullable type; `null is T` never does.
    if (val == .Null) return nullable;
    const nm = std.mem.span(name);
    // `Any` is the universal supertype of every non-null value.
    if (std.mem.eql(u8, nm, "Any")) return 1;
    return @intFromBool(val.isRuntimeType(nm));
}

/// One property of a builtin receiver: a progression's `first`, `last`, `step`.
export fn klio_nat_builtin_prop(name: [*:0]const u8, recv: CValue) CValue {
    const nm = std.mem.span(name);
    const v = fromC(recv);
    const got = cli.interp_ir.member_fields.hostFreeProperty(&v, nm) orelse natNoMember(nm);
    return toC(got);
}

/// `a..b` (kind 0) or `a..<b` (kind 1), with the evaluator's empty-range cases.
export fn klio_nat_range(kind: u32, lhs: CValue, rhs: CValue) CValue {
    const a = natAlloc();
    const l = fromC(lhs);
    const r = fromC(rhs);
    const op: ir.BinOp = if (kind == 0) .RangeTo else .RangeUntil;
    const v = (eval.rangeValue(a, op, &l, &r) catch @panic("klio_nat_range: out of memory")) orelse
        natNoMember("rangeTo");
    return toC(v);
}

fn natNoMember(name: []const u8) noreturn {
    const pre = "runtime error: no implementation of ";
    _ = std.c.write(2, pre.ptr, pre.len);
    _ = std.c.write(2, name.ptr, name.len);
    _ = std.c.write(2, "\n", 1);
    std.c.exit(1);
}

fn natMemberFailed(name: []const u8) noreturn {
    const pre = "runtime error: ";
    _ = std.c.write(2, pre.ptr, pre.len);
    _ = std.c.write(2, name.ptr, name.len);
    _ = std.c.write(2, " failed\n", 8);
    std.c.exit(1);
}

fn natNoStdlib(name: []const u8) noreturn {
    const pre = "runtime error: no implementation of ";
    _ = std.c.write(2, pre.ptr, pre.len);
    _ = std.c.write(2, name.ptr, name.len);
    _ = std.c.write(2, "\n", 1);
    std.c.exit(1);
}

fn natStdlibFailed(name: []const u8, e: runtime.RuntimeError) noreturn {
    _ = e;
    const pre = "runtime error: ";
    _ = std.c.write(2, pre.ptr, pre.len);
    _ = std.c.write(2, name.ptr, name.len);
    _ = std.c.write(2, " failed\n", 8);
    std.c.exit(1);
}

/// Start a compiled suspending lambda; registered per lambda class before `main`.
const CoroStarter = struct { cls: u32, start: *const fn (CValue) callconv(.c) CValue };
var coro_starters: std.ArrayList(CoroStarter) = .empty;

export fn klio_nat_coro_starter(cls: u32, start: *const fn (CValue) callconv(.c) CValue) void {
    coro_starters.append(natAlloc(), .{ .cls = cls, .start = start }) catch
        @panic("klio_nat_coro_starter: out of memory");
}

fn coroStarterFor(v: runtime.Value) ?*const fn (CValue) callconv(.c) CValue {
    if (v != .Instance) return null;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    const name = cg.get().name;
    for (nat_classes.items, 0..) |def, i| {
        const dg = def.borrow();
        defer dg.deinit();
        if (dg.get() != cg.get()) continue;
        for (coro_starters.items) |st| {
            if (st.cls == @as(u32, @intCast(i))) return st.start;
        }
    }
    _ = name;
    return null;
}

/// Queue a compiled `launch { … }` child on the driver that is running.
export fn klio_nat_coro_launch(block: CValue) CValue {
    var host: NativeCoroHost = .{ .allocator = natAlloc() };
    const b = fromC(block);
    const unit: runtime.Value = .Unit;
    _ = cli.interp_ir.coroutines_diag.coroutineLaunch(&host, &b, &unit, natOutput()) catch
        @panic("klio_nat_coro_launch: out of memory");
    return toC(.Unit);
}

/// What the coroutine driver needs from a compiled program: start a queued
/// block, resume a parked continuation. Everything above that is shared.
const NativeCoroHost = struct {
    allocator: std.mem.Allocator,
    launched: u32 = 0,

    /// A queued child; every compiled closure is an emitted lambda class.
    pub fn evalClosureRaw(
        self: *NativeCoroHost,
        block: *const runtime.Value,
        args: []const runtime.Value,
        scope: ?*const runtime.Value,
        out: runtime.Output,
    ) std.mem.Allocator.Error!ir.eval.EvalResult {
        _ = args;
        _ = scope;
        _ = out;
        const start = coroStarterFor(block.*) orelse
            return .{ .err = .{ .Type = "no compiled body registered for this coroutine block" } };
        const produced = fromC(start(toC(block.*)));
        if (produced == .CoroutineSuspended) {
            const st = ir.eval.takeInFlightSuspend(self.allocator) orelse
                return .{ .err = .{ .Type = "compiled child suspended without a continuation" } };
            return .{ .err = .{ .Suspended = st } };
        }
        return .{ .ok = produced };
    }

    pub fn resumeRaw(
        self: *NativeCoroHost,
        state: *ir.eval.SuspendState,
        value: runtime.Value,
        out: runtime.Output,
    ) std.mem.Allocator.Error!ir.eval.EvalResult {
        _ = out;
        // Every snapshot here is native, so the replay is a sequence of calls.
        return ir.eval.resumeNativeContinuation(self.allocator, state, value);
    }
};

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

/// A suspend frame, heap-allocated because the body re-enters, and rooted.
const ParkedFrame = struct { mem: []u8, gcf: *NatFrame };
var parked_frames: std.ArrayList(ParkedFrame) = .empty;

export fn klio_nat_coro_frame(size: usize, gcf_off: usize, slots_off: usize, n_slots: u32) ?*anyopaque {
    const a = natAlloc();
    const mem = a.alignedAlloc(u8, .of(u64), size) catch @panic("klio_nat_coro_frame: out of memory");
    @memset(mem, 0);
    const gcf: *NatFrame = @ptrCast(@alignCast(mem.ptr + gcf_off));
    const slots: [*]runtime.Value = @ptrCast(@alignCast(mem.ptr + slots_off));
    var i: u32 = 0;
    while (i < n_slots) : (i += 1) slots[i] = .Unit;
    gcf.* = .{ .prev = null, .n = n_slots, .slots = @ptrCast(slots) };
    parked_frames.append(a, .{ .mem = mem, .gcf = gcf }) catch @panic("klio_nat_coro_frame: out of memory");
    return @ptrCast(mem.ptr);
}

export fn klio_nat_coro_free(fp: ?*anyopaque) void {
    const p = fp orelse return;
    const a = natAlloc();
    var i: usize = parked_frames.items.len;
    while (i > 0) {
        i -= 1;
        if (@intFromPtr(parked_frames.items[i].mem.ptr) != @intFromPtr(p)) continue;
        const mem = parked_frames.items[i].mem;
        _ = parked_frames.swapRemove(i);
        a.free(mem);
        return;
    }
}

/// The value a suspending call answers with when it did not produce a result.
export fn klio_nat_suspended() CValue {
    return toC(.CoroutineSuspended);
}

export fn klio_nat_is_suspended(v: CValue) i32 {
    return @intFromBool(fromC(v) == .CoroutineSuspended);
}

/// Park the calling frame and answer SUSPENDED, innermost first, the replay order.
export fn klio_nat_coro_park(
    call: *const fn (?*anyopaque, CValue) callconv(.c) CValue,
    frame: ?*anyopaque,
) CValue {
    ir.eval.pushNativePark(natAlloc(), call, frame, 0) catch
        @panic("klio_nat_coro_park: out of memory");
    return toC(.CoroutineSuspended);
}

/// `delay(millis)` in virtual time; the caller parks itself on the way out.
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


export fn klio_nat_null() CValue {
    return toC(.Null);
}

export fn klio_nat_is_null(v: CValue) i32 {
    return if (fromC(v) == .Null) 1 else 0;
}

/// Kotlin `==` on references: structural equality, a null test for a null operand.
export fn klio_nat_value_eq(av: CValue, bv: CValue) i32 {
    const a = fromC(av);
    const b = fromC(bv);
    return if (a.structuralEq(&b)) 1 else 0;
}

/// Kotlin `===`: referential identity, never dispatching a user `equals`.
export fn klio_nat_value_ident(av: CValue, bv: CValue) i32 {
    const a = fromC(av);
    const b = fromC(bv);
    return @intFromBool(runtime.Value.referenceEq(&a, &b));
}

fn natNpe() noreturn {
    const msg = "Exception in thread \"main\" java.lang.NullPointerException\n";
    _ = std.c.write(2, msg.ptr, msg.len);
    std.c.exit(1);
}

// `Char` prints as a character and `Short`/`Byte` render as themselves, so the box carries kind.

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

// Kotlin unsigned integers are value classes over the signed widths: same bits.

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

/// The class handle a compiled dispatcher switches on; 0 for anything else.
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

/// A virtual call no arm handles. A compiled program reports and stops.
export fn klio_nat_no_method(name: [*:0]const u8) noreturn {
    const nm = std.mem.span(name);
    const pre = "Exception in thread \"main\" java.lang.AbstractMethodError: no implementation of ";
    _ = std.c.write(2, pre.ptr, pre.len);
    _ = std.c.write(2, nm.ptr, nm.len);
    _ = std.c.write(2, "\n", 1);
    std.c.exit(1);
}

// Capture cells: a `var` a lambda captures becomes a shared box.

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

/// An uncaught throw. The backend refuses any catch, so a throw always escapes.
export fn klio_nat_throw(v: CValue) noreturn {
    const a = natAlloc();
    const val = fromC(v);
    const txt = val.display(a) catch "exception";
    // The interpreter's wording, so the same program reports identically.
    const pre = "runtime error: uncaught ";
    _ = std.c.write(2, pre.ptr, pre.len);
    _ = std.c.write(2, txt.ptr, txt.len);
    _ = std.c.write(2, "\n", 1);
    std.c.exit(1);
}

/// A throwable of the named type; `type_id` is its preorder number.
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

/// Whether a throw is caught by a handler for `[lo, hi)`. Preorder numbering
/// makes a type's subtree one interval, so a subtype test is two comparisons.
export fn klio_nat_catches(v: CValue, lo: u32, hi: u32) i32 {
    const val = fromC(v);
    if (val != .Exception) return 0;
    const id = val.Exception.type_id;
    return @intFromBool(id >= lo and id < hi);
}

/// The published-frame chain top and a way back; a `longjmp` skips every leave.
export fn klio_nat_frame_mark() ?*NatFrame {
    return nat_top;
}

export fn klio_nat_frame_restore(mark: ?*NatFrame) void {
    nat_top = mark;
}
