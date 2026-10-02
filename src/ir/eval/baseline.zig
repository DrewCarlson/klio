//! The JIT's baseline tier (`plans/jit.md`): a function's streams compiled
//! op by op into native code with an entry at every op, after which every op
//! of the streams is `jit`, whose handler jumps to that entry. Compiled code
//! has the op handlers' signature and calling convention. An op it compiles
//! runs its handler's fast path in place, and falls through to the next op's
//! code; an op it does not compile, or whose fast path's checks fail, tail-
//! calls the op's own handler with the op's pc before storing anything, and
//! the handler's dispatch of the next op comes back into compiled code.

const std = @import("std");
const builtin = @import("builtin");
const jit = @import("jit");
const runtime = @import("runtime");

const ir = @import("../ir.zig");
const bc = ir.bc;
const masm = @import("masm.zig");
const intrinsics = @import("intrinsics.zig");
const kinds_mod = @import("kinds.zig");
const opt_graph = @import("opt/graph.zig");
const opt_build = @import("opt/build.zig");
const opt_regalloc = @import("opt/regalloc.zig");
const opt_emit = @import("opt/emit.zig");
/// The optimizing tier's code generator for this build's target.
const opt_target = switch (builtin.cpu.arch) {
    .x86_64 => @import("opt/emit_x64.zig"),
    else => opt_emit,
};
const opt_passes = @import("opt/passes.zig");
const ev_frame = @import("frame.zig");
const ev_state = @import("state.zig");
const ev_flow = @import("flow.zig");
const ev_parent = @import("../eval.zig");

const Op = bc.Op;
const Activation = ev_flow.Activation;
const Value = runtime.Value;
const Tag = std.meta.Tag(Value);
const Frame = ev_frame.Frame;
const Masm = masm.Masm;
const T = masm.T;
const Cond = masm.Cond;

/// Whether this run compiles hot functions (`KLIO_JIT`, `defaultOn`).
pub var enabled: bool = false;
/// Entries and loop edges a function runs before it compiles
/// (`KLIO_JIT_THRESHOLD`); 0 compiles every function at its first entry. Past a
/// thousand, a startup's functions (compose's) compile and do not pay their
/// compile back; ten thousand leaves them, and a hot loop still compiles within
/// its first ten thousand turns.
pub var threshold: u32 = 10000;
/// Runs of call sites with open caches before a function compiles again.
pub const threshold_stale: u32 = 1000;
/// `KLIO_JIT_NATIVE=0`: every op tail-calls its handler, compiled code runs
/// nothing in place (the check that the plumbing alone changes nothing).
pub var native_ops: bool = true;
/// `KLIO_JIT_MIN_NATIVE`: the share of a function's ops, in percent, that must
/// compile to code of their own for it to compile at all. An op left to its
/// handler costs a jump to it and one back more than interpreting it does,
/// so a function of mostly such ops runs slower compiled.
pub var min_native: u32 = 70;
/// `KLIO_JIT_ENTRIES=0`: only loop edges count toward compiling a function,
/// not its entries.
pub var count_entries: bool = true;
/// `KLIO_JIT_INLINE=0`: calls stay calls; otherwise a call whose callee is
/// small and compiles runs the callee's code in place.
pub var inline_calls: bool = true;
/// `KLIO_JIT_INLINE_WORDS`: the largest callee, in code words, compiled into
/// its caller.
pub var inline_words: u32 = 250;
/// The code words of callees compiled into one function.
pub var inline_budget: u32 = 2000;
/// `KLIO_JIT_EXITS`: runs of one exit from a callee compiled in place after which that
/// callee is called rather than run in place (`FuncStreams.exits_hot`) and the function the
/// code was compiled from compiles again; 0 never.
pub var exit_threshold: u32 = 1000;
/// `KLIO_JIT_KINDS=0`: compiled code checks every register's tag, as though no
/// register's kind were known (`kinds.zig`).
pub var use_kinds: bool = true;
/// `KLIO_JIT_PINS=0`: no register of a loop is kept in a machine register.
pub var use_pins: bool = true;
/// Times a function compiles again for call sites whose caches were empty
/// when it compiled (`FuncStreams.stale`).
const max_recompiles = 3;
/// Times a function compiles again for callees it runs in place that leave its code too
/// often (`exit_threshold`), each of which it then calls.
const max_exit_recompiles = 8;

/// `KLIO_JIT_ONLY=lo-hi`: compile only functions whose id is in `lo..hi`, to
/// find the one whose compiled code misbehaves.
var only_lo: u32 = 0;
var only_hi: u32 = std.math.maxInt(u32);
/// `KLIO_JIT_LOG`: name each function as it compiles.
var log_compiles: bool = false;
/// `KLIO_JIT_DUMP=<id>`: the streams of function `id` as it compiles.
var dump_id: ?u32 = null;
/// `KLIO_JIT_SKIP=<op>,...`: ops left to their handlers, to find the one whose
/// compiled code misbehaves.
var skip_ops: [n_skip_kinds]bool = @splat(false);
const n_skip_kinds = @typeInfo(Op).@"enum".fields.len;
/// `KLIO_JIT_OPT`: `1` compiles a compiled function's innermost loops a second time over
/// values in machine registers (`plans/jit-opt.md`), where the tier takes every op of
/// the loop; `0` does not. On by default where the JIT is (`defaultOn`).
pub var opt_enabled: bool = false;
/// `KLIO_JIT_OPT_EXITS`: how often each optimized loop's exits and failed entries ran.
pub var opt_exits_on: bool = false;
pub const OptExits = struct { fqn: []const u8, head: u32, pcs: []u32, counts: []u64 };
pub var opt_exit_sets: std.ArrayList(*OptExits) = .empty;
/// Loops the optimizing tier compiled, and ones it refused.
pub var opt_count = std.atomic.Value(u32).init(0);
pub var opt_refused_count = std.atomic.Value(u32).init(0);
/// The optimized loops whose values took stack slots.
pub var opt_spill_count = std.atomic.Value(u32).init(0);
/// The most registers of each set the optimizing tier gives values: all of them, unless a
/// test takes fewer to have values kept in stack slots.
pub var opt_regs_cap: u8 = std.math.maxInt(u8);
/// `KLIO_JIT_OPT_DUMP`: each compiled function's innermost loops as the optimizing tier's
/// graphs (`opt/graph.zig`), or why a loop's was refused.
var opt_dump: bool = false;
/// `KLIO_JIT_MAP`: every compiled op's code address, op and function, one
/// `[jitmap]` line each on stderr, to attribute samples of compiled code.
var map_ops: bool = false;
/// `KLIO_JIT_CENSUS`: per op, how many ops of compiled and declined functions
/// were left to their handlers, and which ops kept callees from compiling in
/// place, printed with the stats.
pub var census_on: bool = false;
/// `KLIO_JIT_CENSUS=all`: every site the census counted, not the busiest 60.
var census_all: bool = false;
const n_op_kinds = @typeInfo(Op).@"enum".fields.len;
pub var census_compiled: [n_op_kinds]u32 = @splat(0);
var census_declined: [n_op_kinds]u32 = @splat(0);
var census_rejected: [n_op_kinds]u32 = @splat(0);
var census_exits: [n_op_kinds]u32 = @splat(0);
var census_other: [6]u32 = @splat(0);

/// `KLIO_JIT_CENSUS`: a call compiled code makes, or a way its callees in
/// place leave it, counted as it runs.
const SiteCount = struct {
    count: u64 = 0,
    caller: []const u8,
    what: []const u8,
    why: []const u8,
};
var census_sites: std.ArrayList(*SiteCount) = .empty;
/// Why the last callee `analyze` turned away was turned away.
var last_reject: []const u8 = "";

/// A counter for the census, kept for the run.
fn censusSite(caller: []const u8, what: []const u8, why: []const u8) !*SiteCount {
    const a = std.heap.smp_allocator;
    const site = try a.create(SiteCount);
    site.* = .{ .caller = caller, .what = what, .why = why };
    try census_sites.append(a, site);
    return site;
}

fn censusSitesDump() void {
    std.mem.sort(*SiteCount, census_sites.items, {}, struct {
        fn gt(_: void, x: *SiteCount, y: *SiteCount) bool {
            return x.count > y.count;
        }
    }.gt);
    var total: u64 = 0;
    for (census_sites.items) |x| total += x.count;
    std.debug.print("[jit-census] calls and exits run: {d}\n", .{total});
    const shown = if (census_all) census_sites.items.len else @min(60, census_sites.items.len);
    for (census_sites.items[0..shown]) |x| {
        if (x.count == 0) break;
        std.debug.print("[jit-census] {d:>9} {s} -> {s}: {s}\n", .{ x.count, x.caller, x.what, x.why });
    }
}

var configured = std.atomic.Value(bool).init(false);
/// Whether `KLIO_JIT` asked for the JIT, rather than a command turning it on by default.
var requested: bool = false;

/// `klio run` and bundled apps: hot functions compile, and their hot loops again in the
/// optimizing tier, unless `KLIO_JIT=0` or `KLIO_JIT_OPT=0` says otherwise; other commands
/// compile only when told. Called before `configure`. iOS gives an app no memory it both
/// writes and runs, so it stays off there.
pub fn defaultOn() void {
    if (comptime !jit.supported or builtin.os.tag == .ios) return;
    enabled = true;
    opt_enabled = true;
}

/// Reads `KLIO_JIT` (`0` off, anything else on), `KLIO_JIT_THRESHOLD` and
/// `KLIO_JIT_NATIVE` once. The JIT stays off where this build has no backend
/// or a value's layout is not the one compiled code is built for.
pub fn configure() void {
    if (configured.swap(true, .acq_rel)) return;
    if (comptime !jit.supported) return;
    if (runtime.envOnce("KLIO_JIT")) |v| {
        enabled = !std.mem.eql(u8, v, "0");
        requested = enabled;
    }
    if (runtime.envOnce("KLIO_JIT_THRESHOLD")) |v| {
        threshold = std.fmt.parseInt(u32, v, 10) catch threshold;
    }
    if (runtime.envOnce("KLIO_JIT_NATIVE")) |v| native_ops = !std.mem.eql(u8, v, "0");
    if (runtime.envOnce("KLIO_JIT_MIN_NATIVE")) |v| min_native = std.fmt.parseInt(u32, v, 10) catch min_native;
    if (runtime.envOnce("KLIO_JIT_ENTRIES")) |v| count_entries = !std.mem.eql(u8, v, "0");
    if (runtime.envOnce("KLIO_JIT_INLINE")) |v| inline_calls = !std.mem.eql(u8, v, "0");
    if (runtime.envOnce("KLIO_JIT_INLINE_WORDS")) |v| inline_words = std.fmt.parseInt(u32, v, 10) catch inline_words;
    if (runtime.envOnce("KLIO_JIT_EXITS")) |v| exit_threshold = std.fmt.parseInt(u32, v, 10) catch exit_threshold;
    if (runtime.envOnce("KLIO_JIT_KINDS")) |v| use_kinds = !std.mem.eql(u8, v, "0");
    if (runtime.envOnce("KLIO_JIT_PINS")) |v| use_pins = !std.mem.eql(u8, v, "0");
    if (runtime.envOnce("KLIO_JIT_ONLY")) |v| {
        var it = std.mem.splitScalar(u8, v, '-');
        only_lo = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
        only_hi = std.fmt.parseInt(u32, it.next() orelse "4294967295", 10) catch std.math.maxInt(u32);
    }
    log_compiles = runtime.envOnce("KLIO_JIT_LOG") != null;
    if (runtime.envOnce("KLIO_JIT_DUMP")) |v| dump_id = std.fmt.parseInt(u32, v, 10) catch null;
    if (runtime.envOnce("KLIO_JIT_SKIP")) |v| {
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |name| if (std.meta.stringToEnum(Op, name)) |op| {
            skip_ops[@intFromEnum(op)] = true;
        };
    }
    map_ops = runtime.envOnce("KLIO_JIT_MAP") != null;
    opt_dump = runtime.envOnce("KLIO_JIT_OPT_DUMP") != null;
    if (runtime.envOnce("KLIO_JIT_OPT")) |v| opt_enabled = !std.mem.eql(u8, v, "0");
    opt_exits_on = runtime.envOnce("KLIO_JIT_OPT_EXITS") != null;
    if (runtime.envOnce("KLIO_JIT_CENSUS")) |v| {
        census_on = true;
        census_all = std.mem.eql(u8, v, "all");
    }
    objects_native = objectLayoutHolds();
    const direct_env = runtime.envOnce("KLIO_JIT_DIRECT");
    direct_calls = directLayoutHolds() and !(if (direct_env) |v| std.mem.eql(u8, v, "0") else false);
    direct_entries = !(if (direct_env) |v| std.mem.eql(u8, v, "shared") else false);
    if (enabled and !layoutHolds()) {
        if (requested) std.debug.print("klio: the JIT is off: this build's value layout is not the one it compiles for\n", .{});
        enabled = false;
    }
}

// ------------------------------------------------------------------ layout --

/// Where the tag of a value sits: the byte after its eight-byte payload, in
/// its low six bits (the upper two are unspecified).
const tag_off: u32 = 8;

fn tagOf(comptime t: Tag) u8 {
    return @intFromEnum(t);
}

const frame_span: u32 = @offsetOf(Frame, "cur_span");
const frame_params: u32 = @offsetOf(Frame, "params");
const ev_spin: u32 = @offsetOf(ev_state.EvalTls, "spin_check_counter");
const ev_depth: u32 = @offsetOf(ev_state.EvalTls, "eval_depth");
const ev_depth_cap: u32 = @offsetOf(ev_state.EvalTls, "eval_depth_cap");
const ev_inline: u32 = @offsetOf(ev_state.EvalTls, "inline_regs");
const ev_spans: u32 = @offsetOf(ev_state.EvalTls, "inline_spans");
const ev_plain: u32 = @offsetOf(ev_state.EvalTls, "plain");
const ev_pool: u32 = @offsetOf(ev_state.EvalTls, "act_pool");
const ev_pool_len: u32 = @offsetOf(ev_state.EvalTls, "act_pool_len");
const ev_chain: u32 = @offsetOf(ev_state.EvalTls, "frame_chain");
const ev_vs_seg: u32 = @offsetOf(ev_state.EvalTls, "vstack") + @offsetOf(ev_state.ValueStack, "seg");
const ev_vs_top: u32 = @offsetOf(ev_state.EvalTls, "vstack") + @offsetOf(ev_state.ValueStack, "top");
const seg_buf: u32 = @offsetOf(ev_state.VsSegment, "buf");
/// A frame's field, in its activation.
fn actFrame(comptime field: []const u8) u32 {
    return @offsetOf(Activation, "frame") + @offsetOf(Frame, field);
}
/// A field of a call's record (`bc.DirectSite`).
fn siteField(comptime field: []const u8) u32 {
    return @offsetOf(bc.DirectSite, field);
}

const InstCell = runtime.ObjRef(runtime.InstanceData).Cell;
const inst_data: u32 = @offsetOf(InstCell, "data");
const inst_slots: u32 = inst_data + @offsetOf(runtime.InstanceData, "slots");
const inst_seq: u32 = inst_data + @offsetOf(runtime.InstanceData, "slot_seq");
const inst_class: u32 = inst_data + @offsetOf(runtime.InstanceData, "class_id");
const inst_gen: u32 = @offsetOf(InstCell, "hdr") + @offsetOf(runtime.gc.GcHeader, "gc_gen");
const inst_remembered: u32 = @offsetOf(InstCell, "hdr") + @offsetOf(runtime.gc.GcHeader, "gc_remembered");
const frame_captures: u32 = @offsetOf(Frame, "captures");
const ClosureCell = runtime.IrClosureRef.Cell;
const closure_captures: u32 = @offsetOf(ClosureCell, "data") + @offsetOf(runtime.IrClosureData, "captures");
const closure_body: u32 = @offsetOf(ClosureCell, "data") + @offsetOf(runtime.IrClosureData, "body");

/// An instance's identity: its header's spare word (`InstanceData.identityOf`).
const inst_identity: u32 = @offsetOf(InstCell, "hdr") + @offsetOf(runtime.gc.GcHeader, "gc_aux");
const ListCell = runtime.ValueList.Cell;
const list_items: u32 = @offsetOf(ListCell, "data") + @offsetOf(std.ArrayList(Value), "items");
const list_lock: u32 = @offsetOf(ListCell, "lock") + @offsetOf(@FieldType(ListCell, "lock"), "state");
const list_seq: u32 = @offsetOf(ListCell, "lock") + @offsetOf(@FieldType(ListCell, "lock"), "seq");
const list_data_backing: u32 = @offsetOf(runtime.ListData, "backing");
const list_data_items: u32 = @offsetOf(runtime.ListData, "items") + @offsetOf(runtime.ValueList, "cell");
const list_data_mutable: u32 = @offsetOf(runtime.ListData, "mutable");
const list_data_mod_count: u32 = @offsetOf(runtime.ListData, "mod_count");
const mod_count_value: u32 = @offsetOf(runtime.ModCountRef.Cell, "data") + @offsetOf(runtime.ModCount, "n");
const list_gen: u32 = @offsetOf(ListCell, "hdr") + @offsetOf(runtime.gc.GcHeader, "gc_gen");
const list_remembered: u32 = @offsetOf(ListCell, "hdr") + @offsetOf(runtime.gc.GcHeader, "gc_remembered");
comptime {
    std.debug.assert(@FieldType(@FieldType(ListCell, "lock"), "state") == std.atomic.Value(i32));
}
const PrimCell = runtime.ObjRef(runtime.PrimBuf).Cell;
const prim_items: u32 = @offsetOf(PrimCell, "data") + @offsetOf(runtime.PrimBuf, "bytes") + @offsetOf(std.ArrayList(u8), "items");
const prim_capacity: u32 = @offsetOf(PrimCell, "data") + @offsetOf(runtime.PrimBuf, "bytes") + @offsetOf(std.ArrayList(u8), "capacity");
const prim_trailing: u32 = @offsetOf(PrimCell, "data") + @offsetOf(runtime.PrimBuf, "trailing");
const prim_gc_bytes: u32 = @offsetOf(PrimCell, "hdr") + @offsetOf(runtime.gc.GcHeader, "gc_bytes");
/// The most element bytes a compiled `new` of a primitive array makes in place.
const prim_new_max: usize = 1024;
comptime {
    std.debug.assert(@FieldType(runtime.PrimBuf, "trailing") == u32);
    std.debug.assert(@FieldType(runtime.gc.GcHeader, "gc_bytes") == u32);
}

/// Each primitive array kind's cell as a compiled `new` copies it in before
/// setting its elements (`primNewOp`): built once, kept for the process as
/// the code that copies it is.
var prim_templates: [@typeInfo(runtime.PrimitiveArrayKind).@"enum".fields.len]?[]align(16) u8 = @splat(null);

fn primTemplate(k: runtime.PrimitiveArrayKind) ![]align(16) const u8 {
    const slot = &prim_templates[@intFromEnum(k)];
    if (slot.*) |t| return t;
    const image = try std.heap.smp_allocator.alignedAlloc(u8, .of(PrimCell), @sizeOf(PrimCell));
    runtime.ObjRef(runtime.PrimBuf).regionImage(@ptrCast(image.ptr), .{ .kind = k }, @sizeOf(PrimCell));
    slot.* = image;
    return image;
}

const StateCell = ir.resolved.StateRef.Cell;
const st_data: u32 = @offsetOf(StateCell, "data");
const st_object_state: u32 = st_data + @offsetOf(ir.resolved.ResolvedState, "object_state");
const st_singletons: u32 = st_data + @offsetOf(ir.resolved.ResolvedState, "singletons");
const st_statics: u32 = st_data + @offsetOf(ir.resolved.ResolvedState, "statics");
const st_static_seq: u32 = st_data + @offsetOf(ir.resolved.ResolvedState, "static_seq");
const st_unit_state: u32 = st_data + @offsetOf(ir.resolved.ResolvedState, "unit_state");

const Tlab = runtime.gc.region.Tlab;
const tlab_cursor: u32 = @offsetOf(Tlab, "main") + @offsetOf(runtime.gc.region.Run, "cursor");
const tlab_limit: u32 = @offsetOf(Tlab, "main") + @offsetOf(runtime.gc.region.Run, "limit");
/// The largest instance a compiled `new` copies in.
const inline_new_max: usize = masm.copy_max;

/// Whether an optional state reference is its cell pointer then a set byte,
/// and an optional value its value first, as native `load_object` reads them
/// (checked once: Zig does not fix an optional's layout).
var objects_native: bool = false;

/// Whether a call compiled code makes of a callee its site keeps goes straight to the
/// callee's frame and code (`Gen.directCall`) rather than through the call's handler: the
/// frame's words laid out as a direct entry writes them, and `KLIO_JIT_DIRECT` not 0.
pub var direct_calls: bool = false;
/// `KLIO_JIT_DIRECT=shared`: no function gets a direct entry, so every direct call goes
/// through the shared code (`directCall`).
pub var direct_entries: bool = true;

/// The words a function's direct entry writes where Zig does not fix their layout: a slice is its
/// pointer then its length, an optional value stack mark its mark then a flag byte, an
/// optional closure its reference then a flag byte, which zero words make null.
pub fn directLayoutHolds() bool {
    var sl: []Value = @as([*]Value, @ptrFromInt(0x1000))[0..7];
    const sb: *const [16]u8 = @ptrCast(&sl);
    if (@sizeOf([]Value) != 16 or std.mem.readInt(u64, sb[0..8], .little) != 0x1000 or std.mem.readInt(u64, sb[8..16], .little) != 7) return false;
    var cs: []const Value = @as([*]const Value, @ptrFromInt(0x2000))[0..3];
    const cb: *const [16]u8 = @ptrCast(&cs);
    if (std.mem.readInt(u64, cb[0..8], .little) != 0x2000 or std.mem.readInt(u64, cb[8..16], .little) != 3) return false;
    if (@sizeOf(?ev_state.VsMark) != 24) return false;
    var some: ?ev_state.VsMark = .{ .seg = @ptrFromInt(0x3000), .top = 5 };
    var none: ?ev_state.VsMark = null;
    const mb: *const [24]u8 = @ptrCast(&some);
    const nb: *const [24]u8 = @ptrCast(&none);
    if (std.mem.readInt(u64, mb[0..8], .little) != 0x3000 or std.mem.readInt(u64, mb[8..16], .little) != 5 or mb[16] != 1 or nb[16] != 0) return false;
    if (@sizeOf(?runtime.IrClosureRef) != 16) return false;
    var sc: ?runtime.IrClosureRef = .{ .cell = @ptrFromInt(0x4000) };
    var nc: ?runtime.IrClosureRef = null;
    const scb: *const [16]u8 = @ptrCast(&sc);
    const ncb: *const [16]u8 = @ptrCast(&nc);
    if (std.mem.readInt(u64, scb[0..8], .little) != 0x4000 or scb[8] != 1 or ncb[8] != 0) return false;
    return @offsetOf(Frame, "at_idx") == @offsetOf(Frame, "at_block") + 4;
}

pub fn objectLayoutHolds() bool {
    if (@sizeOf(?ir.resolved.StateRef) != 16) return false;
    var some: ?ir.resolved.StateRef = .{ .cell = @ptrFromInt(0x1230) };
    var none: ?ir.resolved.StateRef = null;
    const sb: *const [16]u8 = @ptrCast(&some);
    const nb: *const [16]u8 = @ptrCast(&none);
    if (std.mem.readInt(u64, sb[0..8], .little) != 0x1230 or sb[8] != 1 or nb[8] != 0) return false;
    // Only the payload and the tag: the padding around them is anything.
    var v: ?Value = .{ .Int = 0x11223344 };
    const vb: *const [16]u8 = @ptrCast(&v);
    if (std.mem.readInt(u32, vb[0..4], .little) != 0x11223344 or vb[tag_off] & 0x3f != @intFromEnum(Tag.Int)) return false;
    return @typeInfo(ir.resolved.UnitState).@"enum".tag_type == u8;
}

/// The bytes of `sp` as the evaluator stores an optional span.
fn spanBytes(sp: ?ir.Span) [@sizeOf(?ir.Span)]u8 {
    var buf: [@sizeOf(?ir.Span)]u8 = @splat(0);
    @as(*?ir.Span, @ptrCast(@alignCast(&buf))).* = sp;
    return buf;
}

/// The 16 bytes of `v` as the evaluator stores it.
fn bytesOf(v: Value) [16]u8 {
    var out: [16]u8 = @splat(0);
    const p: *Value = @ptrCast(@alignCast(&out));
    p.* = v;
    return out;
}

/// Whether values, slices and the tag byte sit where compiled code reads
/// them: checked once, since Zig does not fix a tagged union's layout.
pub fn layoutHolds() bool {
    if (@sizeOf(Value) != 16) return false;
    const probes = [_]Value{ .{ .Int = 0x11223344 }, .{ .Long = 0x0102030405060708 }, .{ .Bool = true }, .{ .Double = 1.5 }, .Null, .Unit };
    for (probes) |v| {
        const b = bytesOf(v);
        if (b[tag_off] & 0x3f != @intFromEnum(std.meta.activeTag(v))) return false;
    }
    if (std.mem.readInt(u32, bytesOf(.{ .Int = 0x11223344 })[0..4], .little) != 0x11223344) return false;
    if (std.mem.readInt(u64, bytesOf(.{ .Long = 0x0102030405060708 })[0..8], .little) != 0x0102030405060708) return false;
    if (bytesOf(.{ .Bool = true })[0] != 1 or bytesOf(.{ .Bool = false })[0] != 0) return false;
    // A slice is its pointer, then its length.
    var arr = [_]u8{ 1, 2, 3 };
    const sl: []u8 = &arr;
    const words: *const [2]usize = @ptrCast(&sl);
    if (words[0] != @intFromPtr(&arr) or words[1] != 3) return false;
    return true;
}

// --------------------------------------------------------------- compiling --

var heap: jit.mem.Heap = .{};
var lock: runtime.SpinMutex = .{};

/// Functions compiled, those the compiler gave up on, and the bytes of code.
pub var compiled_count = std.atomic.Value(u32).init(0);
pub var failed_count = std.atomic.Value(u32).init(0);
pub var declined_count = std.atomic.Value(u32).init(0);
pub var code_bytes = std.atomic.Value(usize).init(0);
pub var compile_ns = std.atomic.Value(u64).init(0);
/// Callees compiled in place of a call.
pub var inlined_count = std.atomic.Value(u32).init(0);
/// Static calls compiled code makes itself, into the callee's compiled code (`Gen.directCall`).
pub var direct_count = std.atomic.Value(u32).init(0);
/// In a test build, the calls the shared code took to the callee's frame (`directCall`), and
/// the calls direct entries took.
pub var direct_runs: u32 = 0;
pub var direct_entry_runs: u64 = 0;
/// In a test build, the calls the shared code made from the call's record alone.
pub var direct_shaped_runs: u32 = 0;
/// Callees compiled in place whose exits reached `exit_threshold`.
pub var exits_hot_count = std.atomic.Value(u32).init(0);
pub var recompiled_count = std.atomic.Value(u32).init(0);
/// Tag checks and tag stores compiled code leaves out where a register's kind is
/// known (`Gen.knows`).
pub var known_count = std.atomic.Value(u32).init(0);
/// Of those, the checks left out in callees compiled in place.
pub var known_in_place_count = std.atomic.Value(u32).init(0);
/// Slot count and plainness checks field accesses leave out where what an instance is
/// known to be proves them (`kinds.instFact`).
pub var fact_count = std.atomic.Value(u32).init(0);
/// Registers loops keep in machine registers (`choosePins`).
pub var pinned_count = std.atomic.Value(u32).init(0);
/// Functions compiled again without pins, a pin's kind having met another (`PinKind`).
pub var unpinned_count = std.atomic.Value(u32).init(0);

fn censusDump(title: []const u8, counts: *const [n_op_kinds]u32) void {
    var order: [n_op_kinds]u16 = undefined;
    for (&order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u16, &order, counts, struct {
        fn lt(c: *const [n_op_kinds]u32, a: u16, b: u16) bool {
            return c[a] > c[b];
        }
    }.lt);
    std.debug.print("[jit-census] {s}:", .{title});
    for (order[0..20]) |i| {
        if (counts[i] == 0) break;
        std.debug.print(" {s}={d}", .{ @tagName(@as(Op, @enumFromInt(i))), counts[i] });
    }
    std.debug.print("\n", .{});
}

/// `KLIO_JIT_STATS`: what the JIT compiled in the run.
pub fn statsDump() void {
    if (opt_exits_on) for (opt_exit_sets.items) |x| {
        for (x.pcs, 0..) |pc, i| if (x.counts[i] != 0) std.debug.print("[opt-exit] {s} loop b{d} exit to {d}: {d}\n", .{ x.fqn, x.head, pc, x.counts[i] });
        const fails = x.counts[x.pcs.len];
        if (fails != 0) std.debug.print("[opt-exit] {s} loop b{d} entry failed: {d}\n", .{ x.fqn, x.head, fails });
    };
    if (census_on) {
        censusDump("handler ops in compiled functions", &census_compiled);
        censusDump("handler ops in declined functions", &census_declined);
        censusDump("ops keeping callees from compiling in place", &census_rejected);
        censusDump("ops callees in place leave their code at", &census_exits);
        std.debug.print("[jit-census] callees too large={d} too deep={d} recursive={d} out of registers={d} no return in place={d} leaving often={d}\n", .{ census_other[0], census_other[1], census_other[2], census_other[3], census_other[4], census_other[5] });
        censusSitesDump();
    }
    if (runtime.envOnce("KLIO_JIT_STATS") == null) return;
    std.debug.print("[jit] enabled={any} threshold={d} compiled={d} recompiled={d} declined={d} failed={d} inlined={d} direct={d} exits_hot={d} known={d} known_in_place={d} facts={d} pinned={d} unpinned={d} code_bytes={d} compile_ms={d}\n", .{
        enabled, threshold, compiled_count.load(.monotonic), recompiled_count.load(.monotonic), declined_count.load(.monotonic), failed_count.load(.monotonic), inlined_count.load(.monotonic), direct_count.load(.monotonic), exits_hot_count.load(.monotonic), known_count.load(.monotonic), known_in_place_count.load(.monotonic), fact_count.load(.monotonic), pinned_count.load(.monotonic), unpinned_count.load(.monotonic), code_bytes.load(.monotonic), compile_ns.load(.monotonic) / 1_000_000,
    });
    std.debug.print("[jit] opt={any} loops={d} refused={d} spilled={d}\n", .{ opt_enabled, opt_count.load(.monotonic), opt_refused_count.load(.monotonic), opt_spill_count.load(.monotonic) });
}

/// The compiler for stream loop `S`, whose handler table and context its code
/// is built against.
pub fn Compiler(comptime S: type) type {
    return struct {
        const ctx_ev: u32 = @offsetOf(S.Ctx, "ev");
        const ctx_exit: u32 = @offsetOf(S.Ctx, "exit");
        const ctx_cache: u32 = @offsetOf(S.Ctx, "cache");
        const ctx_host: u32 = @offsetOf(S.Ctx, "host");
        const host_state: u32 = @offsetOf(S.Host, "resolved_state");
        const ctx_top: u32 = @offsetOf(S.Ctx, "top");
        const ctx_bs: u32 = @offsetOf(S.Ctx, "bs");
        const ctx_alloc: u32 = @offsetOf(S.Ctx, "allocator");
        const ctx_direct: u32 = @offsetOf(S.Ctx, "direct");
        const ctx_tlab: u32 = @offsetOf(S.Ctx, "tlab");

        /// Compiles `fs` unless it is compiled already; a function that does
        /// not compile stays interpreted.
        pub fn compile(fs: *const bc.FuncStreams, module: *const ir.Module) void {
            if (comptime !jit.supported) return;
            lock.lock();
            defer lock.unlock();
            if (fs.jit.load(.acquire) != null) return;
            const fid = fs.func.id.int();
            if (fid < only_lo or fid > only_hi) {
                @constCast(fs).hot.store(std.math.maxInt(u32), .monotonic);
                return;
            }
            if (log_compiles) std.debug.print("[jit] compile #{d} {s}\n", .{ fid, fs.func.fqn });
            if (dump_id == fid) dumpStreams(fs);
            const t0 = runtime.platform.monotonicNs() orelse 0;
            defer _ = compile_ns.fetchAdd((runtime.platform.monotonicNs() orelse t0) -| t0, .monotonic);
            compileLocked(fs, module) catch |e| {
                if (e == error.MostlyHandlers) {
                    _ = declined_count.fetchAdd(1, .monotonic);
                    @constCast(fs).hot.store(std.math.maxInt(u32), .monotonic);
                    return;
                }
                const n = failed_count.fetchAdd(1, .monotonic);
                if (n < 8) std.debug.print("[jit] could not compile #{d} {s}: {t}\n", .{ fid, fs.func.fqn, e });
                // Not again (`countSlow` stops counting at the maximum).
                @constCast(fs).hot.store(std.math.maxInt(u32), .monotonic);
                return;
            };
            _ = compiled_count.fetchAdd(1, .monotonic);
        }

        /// Compiles `fs` again once call sites whose caches were empty when it compiled have
        /// run (`FuncStreams.stale`), so what their caches hold now decides; a bounded number
        /// of times. The code it replaces stays for frames still running it.
        pub fn recompile(fs: *const bc.FuncStreams, module: *const ir.Module) void {
            if (comptime !jit.supported) return;
            lock.lock();
            defer lock.unlock();
            const m = @constCast(fs);
            if (m.stale.load(.monotonic) < threshold_stale) return;
            m.stale.store(0, .monotonic);
            if (m.recompiles >= max_recompiles) return;
            m.recompiles += 1;
            compileAgain(fs, module);
        }

        /// Compiles `fs` again once a callee its code runs in place has left the code too
        /// often (`exit_threshold`): the callee is called from the new code. Bounded as
        /// `recompile` is.
        pub fn recompileExits(fs: *const bc.FuncStreams, module: *const ir.Module) void {
            if (comptime !jit.supported) return;
            lock.lock();
            defer lock.unlock();
            const m = @constCast(fs);
            if (m.exit_recompiles >= max_exit_recompiles) return;
            m.exit_recompiles += 1;
            compileAgain(fs, module);
        }

        fn compileAgain(fs: *const bc.FuncStreams, module: *const ir.Module) void {
            if (fs.jit.load(.acquire) == null) return;
            if (log_compiles) std.debug.print("[jit] recompile #{d} {s}\n", .{ fs.func.id.int(), fs.func.fqn });
            const t0 = runtime.platform.monotonicNs() orelse 0;
            defer _ = compile_ns.fetchAdd((runtime.platform.monotonicNs() orelse t0) -| t0, .monotonic);
            compileLocked(fs, module) catch |e| {
                if (e != error.MostlyHandlers) _ = failed_count.fetchAdd(1, .monotonic);
                return;
            };
            _ = recompiled_count.fetchAdd(1, .monotonic);
        }

        fn compileLocked(fs: *const bc.FuncStreams, module: *const ir.Module) !void {
            const gpa = std.heap.smp_allocator;
            const n = fs.code.len;
            const offsets = try gpa.alloc(u32, n);
            defer gpa.free(offsets);
            const ops = try gpa.alloc(Op, n);
            errdefer gpa.free(ops);
            @memset(offsets, std.math.maxInt(u32));
            @memset(ops, .jit);
            const exits = try gpa.create(std.heap.ArenaAllocator);
            exits.* = std.heap.ArenaAllocator.init(gpa);
            errdefer {
                exits.deinit();
                gpa.destroy(exits);
            }
            var direct_off: ?u32 = null;
            var sites: std.ArrayList(*bc.DirectSite) = .empty;
            defer sites.deinit(gpa);
            const bytes = emit(gpa, exits.allocator(), fs, module, offsets, ops, true, &direct_off, &sites) catch |e| switch (e) {
                // A pin a template wrote another kind to: compiled again, with none.
                error.PinKind => blk: {
                    _ = unpinned_count.fetchAdd(1, .monotonic);
                    if (log_compiles) std.debug.print("[jit]   pins dropped: {s}\n", .{fs.func.fqn});
                    break :blk try emit(gpa, exits.allocator(), fs, module, offsets, ops, false, &direct_off, &sites);
                },
                else => return e,
            };
            defer gpa.free(bytes);
            const base = try jit.install(&heap, bytes);
            if (dump_id == fs.func.id.int() and runtime.envOnce("KLIO_JIT_DUMP_CODE") != null) dumpCode(bytes, offsets);
            _ = code_bytes.fetchAdd(bytes.len, .monotonic);
            if (opt_dump) dumpLoopGraphs(fs, module, ops);
            const entries = try gpa.alloc(usize, n);
            errdefer gpa.free(entries);
            for (offsets, entries) |o, *e| e.* = if (o == std.math.maxInt(u32)) bc.JitCode.no_entry else base + o;
            // Each direct call's way back: this code's entry after the call.
            for (sites.items) |rec| {
                const e = entries[rec.ret_pc];
                rec.back = if (e == bc.JitCode.no_entry) 0 else e;
            }
            const jc = try gpa.create(bc.JitCode);
            jc.* = .{ .entries = entries, .ops = ops, .exits = exits, .prev = fs.jit.load(.acquire) };
            if (map_ops) {
                writeMap(fs, entries, ops, base + bytes.len);
                for (slow_marks.items) |sm| std.debug.print("[jitmap] {x} slow:{s}:{t} {d} {s}\n", .{ base + sm.off, sm.kind, sm.op, sm.pc, sm.fqn orelse fs.func.fqn });
            }
            @constCast(fs).jit.store(jc, .release);
            @constCast(fs).jit_entries.store(entries.ptr, .release);
            @constCast(fs).direct_entry.store(if (direct_off) |o| base + o else 0, .release);
            // Every op now runs its compiled code; a thread that read an
            // opcode before its store runs that op in the interpreter.
            const code: [*]u32 = @constCast(fs.code.ptr);
            for (ops, 0..) |op, pc| {
                if (op != .jit) @atomicStore(u32, &code[pc], @intFromEnum(Op.jit), .release);
            }
        }

        /// `KLIO_JIT_OPT_DUMP`: the graphs of `fs`'s innermost loops, or why each was refused.
        fn dumpLoopGraphs(fs: *const bc.FuncStreams, module: *const ir.Module, ops: []const Op) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const kinds = kinds_mod.analyze(a, fs, module) catch return;
            const loops = naturalLoops(a, fs, ops) catch return;
            var aw: std.Io.Writer.Allocating = .init(a);
            for (loops) |l| {
                // Innermost: no other loop's head inside it.
                const inner = for (loops) |o| {
                    if (o.head != l.head and l.body[o.head]) break false;
                } else true;
                if (!inner) continue;
                aw.writer.print("[opt] {s} loop at b{d}:\n", .{ fs.func.fqn, l.head }) catch return;
                var g = opt_build.buildLeaving(a, .{ .fs = fs, .kinds = &kinds, .module = module, .loop = .{ .head = l.head, .body = l.body }, .hooks = &opt_hooks, .list_reads = runtime.lockfreeReads() and !S.reclaims }) catch |e| {
                    aw.writer.print("  refused: {s} ({t})\n", .{ opt_build.last_refusal, e }) catch return;
                    for (opt_build.last_cold, opt_build.last_cold_why) |pc, why| aw.writer.print("  leaving at {d}: {s}\n", .{ pc, why }) catch return;
                    continue;
                };
                for (opt_build.last_cold, opt_build.last_cold_why) |pc, why| aw.writer.print("  leaving at {d}: {s}\n", .{ pc, why }) catch return;
                opt_passes.simplify(&g) catch return;
                opt_passes.foldNew(&g) catch return;
                opt_passes.dedupChecks(&g, module) catch return;
                g.dump(&aw.writer) catch return;
            }
            std.debug.print("{s}", .{aw.written()});
        }

        /// The function's machine code as hex, 32 bytes a line at its offset, and where each op's
        /// code starts, for a disassembler.
        fn dumpCode(bytes: []const u8, offsets: []const u32) void {
            var off: usize = 0;
            while (off < bytes.len) : (off += 32) {
                std.debug.print("[jit-code] {x:0>6} {x}\n", .{ off, bytes[off..@min(off + 32, bytes.len)] });
            }
            for (offsets, 0..) |o, pc| if (o != std.math.maxInt(u32)) std.debug.print("[jit-op] {d} {x:0>6}\n", .{ pc, o });
        }

        fn dumpStreams(fs: *const bc.FuncStreams) void {
            var aw: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
            defer aw.deinit();
            for (0..fs.blocks.len) |bi| {
                aw.writer.print(" block b{d}:\n", .{bi}) catch return;
                bc.dumpBlock(&aw.writer, fs, bi) catch return;
            }
            std.debug.print("[jit] streams of {s}:\n{s}", .{ fs.func.fqn, aw.written() });
        }

        fn writeMap(fs: *const bc.FuncStreams, entries: []const usize, ops: []const Op, end: usize) void {
            for (entries, ops, 0..) |e, op, pc| {
                if (op == .jit) continue;
                std.debug.print("[jitmap] {x} {s} {d} {s}\n", .{ e, @tagName(op), pc, fs.func.fqn });
            }
            std.debug.print("[jitmap] {x} end 0 {s}\n", .{ end, fs.func.fqn });
        }

        const CompileError = masm.Error || std.mem.Allocator.Error;

        /// A handler call the code makes when a fast path's checks fail,
        /// placed after all the code so fast paths fall through. In a callee
        /// compiled into the code, `inlineExit` for `exit` instead.
        const Slow = struct {
            label: Masm.Label,
            op: Op,
            pc: usize,
            blk: u32,
            exit: ?*const bc.InlineExit = null,
            /// A call site whose cache held nothing to compile in place: its runs count
            /// toward compiling the function again (`recompile`).
            stale: bool = false,
            /// An `is` or `cast` whose class test's cache missed: `isFill` fills it first.
            fill: ?*u64 = null,
            /// The root's block the code leaves from: the op's, or its callee's call's.
            root_blk: u32 = 0,
            /// The pins the op's code runs with, written back before the code leaves: its
            /// block's, none for an op compiled without them.
            pins: []const masm.Pin = &.{},
        };

        /// A callee being compiled into the code in place of its call.
        const Level = struct {
            sc: *const bc.FuncStreams,
            an: *const Analysis,
            labels: []?Masm.Label,
            /// The callee's first register in the thread's inline registers.
            area: u32,
            call_pc: u32,
            call_blk: u32,
            /// The call's argument run and result register, in the caller's window.
            lo: u32,
            n: u32,
            dst: u32,
            /// A lambda's call: the caller's register holding the closure, whose captures its
            /// body reads.
            closure: ?u32 = null,
            /// The caller's op after the call.
            cont: Masm.Label,
            /// The registers written on every path to the op being compiled.
            written: std.DynamicBitSetUnmanaged,
            /// What an exit finds of this level while a callee of its own is compiled.
            frozen: bc.InlineLevel = undefined,
            /// The callee's register kinds, its parameters taking the kinds its call's
            /// arguments have (`kinds.analyzeWith`), and the op of it being compiled.
            kinds: ?*const kinds_mod.Kinds = null,
            cur_pc: usize = 0,
        };

        /// A loop the optimizing tier compiled: its graph, its registers, and its code's entry.
        const OptLoop = struct {
            head: u32,
            body: []const bool,
            g: opt_graph.Graph,
            al: opt_regalloc.Alloc,
            entry: Masm.Label,
            /// Whether the loop's code is entered, kept with the code.
            gate: *opt_emit.Gate,
        };

        /// What this compiler decides for the ops the optimizing tier compiles as it does.
        const opt_hooks: opt_build.Hooks = .{
            .new_plan = optNewPlan,
            .prim_new = optPrimNew,
            .static_intrinsic = staticIntrinsic,
            .class_tag = scalarClassTag,
            .native_intrinsic = intrinsicOf,
            .intrinsic_entry = S.intrinsicEntry,
            .host_tag = hostTag,
        };

        /// The tag of the values of class `class`, a class no other value has: Int's,
        /// Long's, Double's, Boolean's.
        fn scalarClassTag(module: *const ir.Module, class: u32) ?Tag {
            const r = module.resolved orelse return null;
            const h = &r.host_class;
            const by: [4]struct { ?ir.ClassId, Tag } = .{ .{ h.int, .Int }, .{ h.long, .Long }, .{ h.double, .Double }, .{ h.boolean, .Bool } };
            for (by) |x| if (x[0]) |c| if (c.int() == class) return x[1];
            return null;
        }

        fn optNewPlan(fs: *const bc.FuncStreams, pc: usize) ?opt_build.NewPlan {
            const p = newPlan(fs, pc) orelse return null;
            return .{ .stores = p.stores, .image = p.t.image };
        }

        fn optPrimNew(module: *const ir.Module, class: u32) ?opt_build.PrimNew {
            if (S.reclaims or ev_parent.call_hooks_on) return null;
            const k = primKindOf(module, class) orelse return null;
            return .{ .kind = k, .image = primTemplate(k) catch return null };
        }

        /// The innermost loops of `fs` the optimizing tier takes, each built and given its
        /// registers; a loop it refuses is left to the baseline.
        fn planOptLoops(g: *Gen, fs: *const bc.FuncStreams, ops: []const Op) ![]OptLoop {
            if (comptime (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64) or !runtime.plain_slots) return &.{};
            const kinds = g.kinds orelse return &.{};
            const loops = try naturalLoops(g.scratch, fs, ops);
            var out: std.ArrayList(OptLoop) = .empty;
            for (loops) |l| {
                const inner = for (loops) |o| {
                    if (o.head != l.head and l.body[o.head]) break false;
                } else true;
                if (!inner) continue;
                var graph = opt_build.buildLeaving(g.scratch, .{ .fs = fs, .kinds = kinds, .module = g.module, .loop = .{ .head = l.head, .body = l.body }, .hooks = &opt_hooks, .list_reads = runtime.lockfreeReads() and !S.reclaims }) catch |e| switch (e) {
                    error.Unsupported => {
                        _ = opt_refused_count.fetchAdd(1, .monotonic);
                        if (log_compiles) std.debug.print("[opt]   loop at b{d} refused: {s}\n", .{ l.head, opt_build.last_refusal });
                        continue;
                    },
                    else => return e,
                };
                try opt_passes.simplify(&graph);
                try opt_passes.foldNew(&graph);
                try opt_passes.dedupChecks(&graph, g.module);
                const al = opt_regalloc.allocate(g.scratch, &graph, @min(opt_regs_cap, opt_target.value_regs.len), @min(opt_regs_cap, opt_target.float_regs.len)) catch |e| switch (e) {
                    error.Unsupported => {
                        _ = opt_refused_count.fetchAdd(1, .monotonic);
                        if (log_compiles) std.debug.print("[opt]   loop at b{d} refused: out of registers\n", .{l.head});
                        continue;
                    },
                    else => return e,
                };
                if (log_compiles) std.debug.print("[opt]   loop at b{d}\n", .{l.head});
                if (al.spills != 0) _ = opt_spill_count.fetchAdd(1, .monotonic);
                const gate = try g.keep.create(opt_emit.Gate);
                gate.* = .{};
                try out.append(g.scratch, .{ .head = l.head, .body = l.body, .g = graph, .al = al, .entry = try g.m.label(), .gate = gate });
            }
            return out.items;
        }

        const Gen = struct {
            m: Masm,
            /// The function compiled, and the module it runs in.
            root: *const bc.FuncStreams,
            module: *const ir.Module,
            /// The function whose ops are being compiled: the root, or a callee compiled into it.
            fs: *const bc.FuncStreams,
            /// Per code word of `fs`: the label of the op starting there.
            labels: []?Masm.Label,
            slows: std.ArrayList(Slow) = .empty,
            /// The records of the code's direct calls, whose way back `compileLocked` sets once the
            /// code is installed.
            direct_sites: std.ArrayList(*bc.DirectSite) = .empty,
            /// `KLIO_JIT_MAP`: where each op of a callee compiled in place starts.
            in_marks: std.ArrayList(struct { label: Masm.Label, op: Op, pc: usize, sc: *const bc.FuncStreams }) = .empty,
            gpa: std.mem.Allocator,
            /// Kept with the code: the exits' records.
            keep: std.mem.Allocator,
            /// Freed after compiling: the callees' analyses and labels.
            scratch: std.mem.Allocator,
            /// The callees being compiled, the innermost last.
            levels: std.ArrayList(Level) = .empty,
            /// Code words of the callees compiled into the code so far.
            inlined_words: u32 = 0,
            /// Set by an op whose code only leads to its handler, for the share of ops
            /// that compile.
            handler_op: bool = false,
            /// The label bound right after the op being compiled, which a jump to needs no
            /// instruction.
            next_label: ?Masm.Label = null,
            /// `KLIO_JIT_CENSUS`: the root's ops that compiled.
            native_at: std.DynamicBitSetUnmanaged = .{},
            /// The root's register kinds at each of its ops (`kinds.zig`).
            kinds: ?*const kinds_mod.Kinds = null,
            /// The root op being compiled.
            cur_pc: usize = 0,
            /// Per block of the root, the registers its loop keeps in machine registers
            /// (`choosePins`); none outside a loop.
            pins_of_blk: []const []const masm.Pin = &.{},
            /// The loops the optimizing tier compiled, whose heads the edges from outside go
            /// to its code for (`opt/`).
            opt_loops: []OptLoop = &.{},
            /// The root's registers whose kind an op's code relies on, by the op's pc: an
            /// entry into the code from outside checks them first (`entryChecks`).
            relied: std.ArrayList(Relied) = .empty,

            const Relied = struct { pc: u32, reg: u32 };

            /// The tag register `r` holds whenever the op being compiled runs from compiled
            /// code, when the kinds of the function it is in show one: the root's, or those
            /// of a callee compiled in place, which a call's arguments seed.
            fn kindOf(g: *Gen, r: u32) ?Tag {
                return kinds_mod.tagOf(g.rawKind(r));
            }

            /// Register `r`'s kind as the kinds show it at the op being compiled, what is
            /// known of an instance with it (`kinds.instFact`).
            fn rawKind(g: *Gen, r: u32) kinds_mod.Kind {
                if (g.top()) |lv| {
                    const k = lv.kinds orelse return kinds_mod.unknown;
                    return k.kindAt(lv.cur_pc, r);
                }
                const k = g.kinds orelse return kinds_mod.unknown;
                return k.kindAt(g.cur_pc, r);
            }

            /// Whether register `r` always holds an instance with more than `slot` slots
            /// here, the op's code relying on it.
            fn knowsSlot(g: *Gen, r: u32, slot: u32) !bool {
                if (kinds_mod.factSlots(g.rawKind(r)) <= slot) return false;
                _ = fact_count.fetchAdd(1, .monotonic);
                return g.knows(r, .Instance);
            }

            /// Whether register `r` always holds an instance whose slots are plain here,
            /// the op's code relying on it.
            fn knowsPlain(g: *Gen, r: u32) !bool {
                if (!kinds_mod.factPlain(g.rawKind(r))) return false;
                _ = fact_count.fetchAdd(1, .monotonic);
                return g.knows(r, .Instance);
            }

            /// Whether register `r` holds tag `t` whenever this op runs from compiled code,
            /// the op's code relying on it from here. A root register relied on is checked
            /// by an entry from outside (`entryChecks`); a callee compiled in place is only
            /// ever entered from its call, whose arguments' kinds the root relies on
            /// (`inlineBody`).
            fn knows(g: *Gen, r: u32, t: Tag) !bool {
                if (g.kindOf(r) != t) return false;
                if (g.levels.items.len == 0) try g.relied.append(g.scratch, .{ .pc = @intCast(g.cur_pc), .reg = r }) else {
                    _ = known_in_place_count.fetchAdd(1, .monotonic);
                }
                _ = known_count.fetchAdd(1, .monotonic);
                return true;
            }

            /// To `fail` unless register `r` holds tag `t`: no check where it always does.
            fn guard(g: *Gen, r: u32, t: Tag, fail: Masm.Label) !void {
                if (try g.knows(r, t)) return;
                try g.m.guardTag(r, tag_off, @intFromEnum(t), fail);
            }

            /// Register `dst`'s tag = `t`, through scratch `s`: no store where it holds `t`
            /// already.
            fn putTag(g: *Gen, dst: u32, t: Tag, s: T) !void {
                if (try g.knows(dst, t)) return;
                try g.m.storeTag(dst, tag_off, @intFromEnum(t), s);
            }

            /// The width of registers `l` and `r` when both always hold Ints or both Longs,
            /// the op's code relying on it from here.
            fn knowsPair(g: *Gen, l: u32, r: u32) !?masm.Wd {
                const k = g.kindOf(l) orelse return null;
                if (k != .Int and k != .Long) return null;
                if (g.kindOf(r) != k) return null;
                _ = try g.knows(l, k);
                _ = try g.knows(r, k);
                return if (k == .Int) .w32 else .w64;
            }

            /// The width of register `r` when it always holds an Int or a Long, the op's
            /// code relying on it from here.
            fn knowsInteger(g: *Gen, r: u32) !?masm.Wd {
                const k = g.kindOf(r) orelse return null;
                if (k != .Int and k != .Long) return null;
                _ = try g.knows(r, k);
                return if (k == .Int) .w32 else .w64;
            }

            fn code(g: *const Gen, pc: usize, k: usize) u32 {
                return g.fs.code[pc + k];
            }

            fn top(g: *Gen) ?*Level {
                const n = g.levels.items.len;
                return if (n == 0) null else &g.levels.items[n - 1];
            }

            /// The window of the function whose ops are being compiled.
            fn win(g: *Gen) masm.Win {
                const lv = g.top() orelse return .{};
                return .{ .inline_area = true, .off = lv.area };
            }

            /// A label that tail-calls `op`'s handler for the op at `pc`, in a
            /// callee compiled into the code after giving it and its callers
            /// their frames.
            fn slow(g: *Gen, op: Op, pc: usize, blk: u32) !Masm.Label {
                const l = try g.m.label();
                const x: ?*const bc.InlineExit = if (g.levels.items.len == 0) null else try g.exitRecord(op, pc, blk);
                try g.slows.append(g.gpa, .{ .label = l, .op = op, .pc = pc, .blk = blk, .root_blk = g.rootBlk(blk), .pins = g.m.pins, .exit = x });
                return l;
            }

            /// `KLIO_JIT_CENSUS`: counts the runs of the call at `pc`, left a call for `why`.
            fn countCall(g: *Gen, op: Op, pc: usize, why: []const u8) !void {
                const callee: []const u8 = if (op == .call) (if (g.fs.callees[g.code(pc, 6)].load(.acquire)) |sc| sc.func.fqn else g.nativeName(g.code(pc, 2))) else if (op == .callv) (if (g.fs.lambdas[g.code(pc, 6)].load(.acquire)) |ls| ls.sc.func.fqn else "a lambda") else if (g.fs.vcallees[g.code(pc, 6)].load(.acquire)) |e| (if (e.streams[0]) |sc| sc.func.fqn else g.hostName(e.natives[0])) else "?";
                const site = try censusSite(g.fs.func.fqn, callee, why);
                try g.m.movImm(.t0, @intFromPtr(&site.count));
                try g.m.loadAt(.w64, .t1, .t0, 0);
                try g.m.addImm(.w64, .t1, .t1, 1);
                try g.m.storeAt(.w64, .t0, 0, .t1);
            }

            /// `KLIO_JIT_CENSUS`: counts the runs of the instruction the `escape` op at `pc` of
            /// block `blk` leaves to its arm, by the instruction's kind.
            fn countEscape(g: *Gen, pc: usize, blk: u32) !void {
                const insts = g.fs.func.blocks[blk].insts;
                const i = g.code(pc, 1);
                const what: []const u8 = if (i < insts.len) @tagName(std.meta.activeTag(insts[i])) else "?";
                const site = try censusSite(g.fs.func.fqn, what, "instruction arm");
                try g.m.movImm(.t0, @intFromPtr(&site.count));
                try g.m.loadAt(.w64, .t1, .t0, 0);
                try g.m.addImm(.w64, .t1, .t1, 1);
                try g.m.storeAt(.w64, .t0, 0, .t1);
            }

            /// `KLIO_JIT_CENSUS`: counts the runs of the host function the `native` op at `pc`
            /// calls.
            fn countNative(g: *Gen, pc: usize) !void {
                const site = try censusSite(g.fs.func.fqn, g.hostName(@enumFromInt(g.code(pc, 2))), "host function");
                try g.m.movImm(.t0, @intFromPtr(&site.count));
                try g.m.loadAt(.w64, .t1, .t0, 0);
                try g.m.addImm(.w64, .t1, .t1, 1);
                try g.m.storeAt(.w64, .t0, 0, .t1);
            }

            /// The intrinsic the `native` op at `pc` of `fs` runs as, when its arguments are
            /// the ones the intrinsic takes and lie in the frame.
            fn nativeIntrinsic(g: *Gen, fs: *const bc.FuncStreams, pc: usize) Intrinsic {
                const w = fs.code;
                const k = intrinsicOf(g.module, @enumFromInt(w[pc + 2]));
                if (!k.fits(w[pc + 3], w[pc + 4], w[pc + 5]) or w[pc + 3] + w[pc + 4] > fs.func.n_locals or w[pc + 5] >= fs.func.n_locals) return .none;
                return k;
            }

            /// The host function the tables bind to function `fid`, by name, or the function's.
            fn nativeName(g: *Gen, fid: u32) []const u8 {
                const r = g.module.resolved orelse return "?";
                if (fid < r.func_native.len and r.func_native[fid] != .none) return g.hostName(r.func_native[fid]);
                const f = g.module.funcById(ir.FuncId.from(fid)) orelse return "?";
                return f.fqn;
            }

            fn hostName(g: *Gen, nid: ir.NativeId) []const u8 {
                const r = g.module.resolved orelse return "(host)";
                if (nid == .none or nid.int() >= r.natives.len) return "(host)";
                return std.fmt.allocPrint(std.heap.smp_allocator, "host {s} [{s}]", .{ r.natives[nid.int()].name, r.natives[nid.int()].key }) catch "(host)";
            }

            /// `slow` for an `is` or `cast` whose class test's cache `cache` the way out fills.
            fn slowFill(g: *Gen, op: Op, pc: usize, blk: u32, cache: *u64) !Masm.Label {
                const l = try g.m.label();
                if (g.levels.items.len == 0) {
                    try g.slows.append(g.gpa, .{ .label = l, .op = op, .pc = pc, .blk = blk, .root_blk = g.rootBlk(blk), .pins = g.m.pins, .fill = cache });
                } else {
                    const x = try g.exitRecord(op, pc, blk);
                    @constCast(x).cache = cache;
                    try g.slows.append(g.gpa, .{ .label = l, .op = op, .pc = pc, .blk = blk, .root_blk = g.rootBlk(blk), .pins = g.m.pins, .exit = x });
                }
                return l;
            }

            /// A label that counts a run of a call site with an open cache (`Slow.stale`), then
            /// tail-calls the call's handler.
            fn staleSlow(g: *Gen, op: Op, pc: usize, blk: u32) !Masm.Label {
                const l = try g.m.label();
                try g.slows.append(g.gpa, .{ .label = l, .op = op, .pc = pc, .blk = blk, .root_blk = g.rootBlk(blk), .pins = g.m.pins, .stale = true });
                return l;
            }

            /// Where an exit at the op at `pc` in block `blk` of the innermost callee finds
            /// every level.
            fn exitRecord(g: *Gen, op: Op, pc: usize, blk: u32) !*const bc.InlineExit {
                const n = g.levels.items.len;
                const levels = try g.keep.alloc(bc.InlineLevel, n);
                for (g.levels.items[0 .. n - 1], levels[0 .. n - 1]) |lv, *d| d.* = lv.frozen;
                levels[n - 1] = try g.levelRecord(&g.levels.items[n - 1], blk);
                const x = try g.keep.create(bc.InlineExit);
                x.* = .{ .levels = levels, .op = op, .pc = @intCast(pc), .blk = blk };
                return x;
            }

            /// Level `lv` as an exit in its block `blk` finds it.
            fn levelRecord(g: *Gen, lv: *const Level, blk: u32) !bc.InlineLevel {
                var list: std.ArrayList(u16) = .empty;
                for (0..lv.sc.func.n_locals) |r| {
                    if (lv.written.isSet(r) or lv.an.prefill.isSet(r)) try list.append(g.keep, @intCast(r));
                }
                return .{
                    .sc = lv.sc,
                    .call_pc = lv.call_pc,
                    .call_blk = lv.call_blk,
                    .area = lv.area,
                    .written = try list.toOwnedSlice(g.keep),
                    .span = if (blk < lv.sc.entry_spans.len) switch (lv.sc.entry_spans[blk]) {
                        .known => |sp| .{ .known = sp },
                        .opens => .{ .known = null },
                        .dyn => .slot,
                    } else .slot,
                };
            }

            /// The root's block an exit in block `blk` of the ops being compiled leaves from.
            fn rootBlk(g: *Gen, blk: u32) u32 {
                return if (g.levels.items.len == 0) blk else g.levels.items[0].call_blk;
            }


            fn target(g: *Gen, pc: usize) Masm.Label {
                return g.labels[pc].?;
            }

            /// On the way into a loop keeping temporaries: each one's frame tag its kind, as the
            /// ops that write it would leave it, so the frame it is written back to reads as it
            /// would with no pin, whatever the loop has not yet written.
            fn prepareTemps(g: *Gen) !void {
                const pins = g.m.pins;
                g.m.pins = &.{};
                defer g.m.pins = pins;
                for (pins) |p| if (p.temp) {
                    try g.m.storeTag(p.vreg, tag_off, p.kind, .t3);
                };
            }

            /// Whether every path to the root op being compiled has written register `r`
            /// (`Kinds.written`).
            fn written(g: *Gen, r: u32) bool {
                if (g.levels.items.len != 0) return false;
                const k = g.kinds orelse return false;
                return k.written(g.cur_pc, r);
            }

            /// Stores the span an edge leaves in the frame, as `leaveSpan` does (its span
            /// words); a callee's edges leave theirs in its level's slot (`edge`).
            fn span(g: *Gen, at: usize) !void {
                if (g.levels.items.len != 0) return;
                if (g.fs.code[at] == bc.NO_SPAN) return;
                try g.m.storeFrameBytes(frame_span, &spanBytes(bc.wordsSpan(g.fs.code, at)));
            }

            /// An edge to `tpc` in block `tblk` from block `blk`, whose span words are at
            /// `span_at`: a back edge first runs the loop's guards as `edge` does,
            /// leaving for `fail` when they have work.
            fn edge(g: *Gen, tblk: u32, tpc: usize, blk: u32, span_at: usize, fail: Masm.Label) !void {
                if (tblk <= blk) {
                    try g.m.loadCtx(.t0, ctx_ev);
                    try g.m.loadAt(.w64, .t1, .t0, ev_spin);
                    try g.m.addImm(.w64, .t1, .t1, 1);
                    try g.m.bLow16Zero(.t1, fail);
                    try g.m.loadAbs32(.t2, @intFromPtr(&runtime.gc.edge_flags));
                    try g.m.bNonZero(.t2, fail);
                    try g.m.storeAt(.w64, .t0, ev_spin, .t1);
                }
                // A callee's target whose entry span differs by path finds the one its entering
                // edge left in the level's slot.
                if (g.levels.items.len != 0 and g.fs.code[span_at] != bc.NO_SPAN) try g.storeSlot(bc.wordsSpan(g.fs.code, span_at));
                if (g.levels.items.len == 0) if (g.optLoopAt(tblk)) |ol| {
                    // Into a loop the optimizing tier compiled, from outside or by its back
                    // edge, while its gate is open: its code takes the loop's registers from
                    // the frame.
                    const shut = try g.m.label();
                    try g.m.loadAbs32(.t2, @intFromPtr(&ol.gate.on));
                    try g.m.bZero(.t2, shut);
                    try g.m.writeBackPins();
                    try g.m.jump(ol.entry);
                    g.m.bind(shut);
                };
                if (g.levels.items.len == 0 and tblk < g.pins_of_blk.len) {
                    // Into or out of a loop that keeps pins: the frame gets this block's
                    // pins back, and the target's come out of it.
                    const here = g.m.pins;
                    const there = g.pins_of_blk[tblk];
                    if (here.ptr != there.ptr or here.len != there.len) {
                        try g.m.writeBackPins();
                        g.m.pins = there;
                        try g.prepareTemps();
                        try g.m.loadPins();
                        try g.m.jump(g.target(tpc));
                        g.m.pins = here;
                        return;
                    }
                }
                try g.goTo(g.target(tpc));
            }

            /// The optimized loop whose head is block `blk`, if there is one.
            fn optLoopAt(g: *Gen, blk: u32) ?*OptLoop {
                for (g.opt_loops) |*ol| if (ol.head == blk) return ol;
                return null;
            }

            /// A jump to `l`, none when `l` is bound right after this op.
            fn goTo(g: *Gen, l: Masm.Label) !void {
                if (g.next_label) |n| if (n == l) return;
                try g.m.jump(l);
            }

            /// The edges of a branch on the Bool in `t`: the edge to the op laid out next last,
            /// so it falls through.
            fn branchEdges(g: *Gen, t: T, blk: u32, tt: [2]u32, ft: [2]u32, span_at: usize, fail: Masm.Label) !void {
                const false_next = if (g.next_label) |n| n == g.target(ft[1]) else false;
                const other = try g.m.label();
                if (false_next) {
                    try g.m.bZero(t, other);
                    try g.edge(tt[0], tt[1], blk, span_at, fail);
                    g.m.bind(other);
                    try g.edge(ft[0], ft[1], blk, span_at, fail);
                } else {
                    try g.m.bNonZero(t, other);
                    try g.edge(ft[0], ft[1], blk, span_at, fail);
                    g.m.bind(other);
                    try g.edge(tt[0], tt[1], blk, span_at, fail);
                }
            }

            /// The innermost level's span slot = `sp`.
            fn storeSlot(g: *Gen, sp: ?ir.Span) !void {
                const k: u32 = @intCast(g.levels.items.len - 1);
                try g.m.loadCtx(.t1, ctx_ev);
                try g.m.storeBytesAt(.t1, ev_spans + k * @sizeOf(?ir.Span), &spanBytes(sp));
            }

            /// Writes Bool `t` (0 or 1) to register `dst`, as `put` does.
            fn putBool(g: *Gen, dst: u32, t: T) !void {
                try g.m.storePayloadByte(dst, t);
                try g.putTag(dst, .Bool, .t3);
            }

            /// `branchOn` at `at` with the Bool in `t`: its register, its span, its edges.
            fn branchOn(g: *Gen, at: usize, blk: u32, t: T, fail: Masm.Label) !void {
                try g.putBool(g.code(at, 3), t);
                try g.span(at + 10);
                try g.branchEdges(t, blk, .{ g.code(at, 6), g.code(at, 7) }, .{ g.code(at, 8), g.code(at, 9) }, at + 10, fail);
            }
        };

        /// `direct_off` = where the function's direct entry starts in the code, if it has one.
        fn emit(gpa: std.mem.Allocator, keep: std.mem.Allocator, fs: *const bc.FuncStreams, module: *const ir.Module, entries: []u32, ops: []Op, allow_pins: bool, direct_off: *?u32, sites: *std.ArrayList(*bc.DirectSite)) ![]u8 {
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            var g: Gen = .{ .m = Masm.init(gpa), .root = fs, .module = module, .fs = fs, .labels = try gpa.alloc(?Masm.Label, fs.code.len), .gpa = gpa, .keep = keep, .scratch = scratch.allocator() };
            defer g.m.deinit();
            defer gpa.free(g.labels);
            defer g.slows.deinit(gpa);
            defer g.direct_sites.deinit(gpa);
            if (census_on) g.native_at = try std.DynamicBitSetUnmanaged.initEmpty(g.scratch, fs.code.len);
            @memset(g.labels, null);
            const kinds = try kinds_mod.analyze(g.scratch, fs, module);
            if (use_kinds) g.kinds = &kinds;
            // Per op of the root: whether it ran in place, and its block.
            const native_op = try g.scratch.alloc(bool, fs.code.len);
            @memset(native_op, false);
            const blk_of = try g.scratch.alloc(u32, fs.code.len);
            // Per op left to its handler in a block that keeps pins: where an entry from
            // outside comes in, past the pins' write-back.
            const handler_entry = try g.scratch.alloc(?Masm.Label, fs.code.len);
            @memset(handler_entry, null);
            const unpinned = try g.scratch.alloc(bool, fs.code.len);
            @memset(unpinned, false);
            // Every op's label first, so any op can branch to any other.
            for (fs.blocks) |b| {
                var pc: usize = b.enter;
                while (pc <= b.end) {
                    const op = fs.opAt(pc);
                    ops[pc] = op;
                    g.labels[pc] = try g.m.label();
                    pc += bc.opLen(op, fs.code, pc);
                }
            }
            // The share of ops that compile counts a function's loops where it has any: the
            // code around a loop runs once for the loop's many turns.
            const in_loop = try loopBlocks(gpa, fs, ops);
            defer gpa.free(in_loop);
            const any_loop = std.mem.indexOfScalar(bool, in_loop, true) != null;
            if (g.kinds != null and allow_pins and use_pins) g.pins_of_blk = try choosePins(&g, fs, ops);
            if (opt_enabled and use_kinds and native_ops) g.opt_loops = try planOptLoops(&g, fs, ops);
            var n_native: u32 = 0;
            var n_ops: u32 = 0;
            // The second op of a pair whose first compiled runs only through its entry, from
            // the first's handler: out of the way.
            var pair_at: usize = std.math.maxInt(usize);
            for (fs.blocks, 0..) |b, bi| {
                var pc: usize = b.enter;
                while (pc <= b.end) {
                    const op = ops[pc];
                    const len = bc.opLen(op, fs.code, pc);
                    const is_pair = pc == pair_at;
                    const pair_sec: ?masm.Cold = if (is_pair) try g.m.cold() else null;
                    g.m.bind(g.labels[pc].?);
                    const after = if (isBinK(op) or isCmpBrK(op)) pc + 6 + bc.opLen(ops[pc + 6], fs.code, pc + 6) else pc + len;
                    g.next_label = if (is_pair or after >= fs.code.len or g.labels[after] == null) null else g.labels[after];
                    g.handler_op = false;
                    g.cur_pc = pc;
                    blk_of[pc] = @intCast(bi);
                    // The op a `bin_k` prefix fronts runs only from outside, the frame
                    // holding every register: no pins there.
                    g.m.pins = if (bi < g.pins_of_blk.len and !is_pair) g.pins_of_blk[bi] else &.{};
                    unpinned[pc] = is_pair;
                    // The op's code relies on each pin's kind as on a kind it reads: an entry
                    // from outside before the loop checks it (`entryChecks`).
                    for (g.m.pins) |p| {
                        if (p.temp and !kinds.written(pc, p.vreg)) continue;
                        try g.relied.append(g.scratch, .{ .pc = @intCast(pc), .reg = p.vreg });
                    }
                    const compiled = native_ops and try compileOp(&g, op, pc, @intCast(bi));
                    const native = compiled and !g.handler_op;
                    native_op[pc] = native;
                    if (native and census_on) g.native_at.set(pc);
                    if (!compiled) {
                        // Code falling into the op gives the frame its pins back; an entry
                        // from outside comes in after that, the frame holding them already.
                        try g.m.writeBackPins();
                        if (g.m.pins.len != 0) {
                            const outside = try g.m.label();
                            g.m.bind(outside);
                            handler_entry[pc] = outside;
                        }
                        try g.m.tailHandler(handlerOf(op), pc, @intCast(bi));
                    }
                    if (compiled and !native and g.m.pins.len != 0) {
                        // Code that only leads to the op's handler gives the frame its pins back
                        // on the way; an entry from outside goes to the handler straight.
                        const sec = try g.m.cold();
                        const outside = try g.m.label();
                        g.m.bind(outside);
                        handler_entry[pc] = outside;
                        try g.m.tailHandler(handlerOf(op), pc, @intCast(bi));
                        g.m.endCold(sec);
                    }
                    if (is_pair and native) {
                        // The op its prefix's handler runs goes on past the pair, with the
                        // block's pins out of the frame again.
                        g.m.pins = if (bi < g.pins_of_blk.len) g.pins_of_blk[bi] else &.{};
                        try g.m.loadPins();
                        if (g.labels[pc + len]) |cont| try g.m.jump(cont);
                    }
                    if (pair_sec) |ps| g.m.endCold(ps);
                    if (native and (isBinK(op) or isCmpBrK(op))) pair_at = pc + 6;
                    // A block's exit, its try entry and a throw run as the interpreter runs them
                    // either way.
                    if (op != .end and op != .block_entry and op != .term_exit and (!any_loop or in_loop[bi])) {
                        n_ops += 1;
                        if (native) n_native += 1;
                    }
                    pc += bc.opLen(op, fs.code, pc);
                }
            }
            const declined = n_native * 100 < min_native * n_ops;
            if (census_on) {
                const counts = if (declined) &census_declined else &census_compiled;
                for (fs.blocks) |b| {
                    var pc: usize = b.enter;
                    while (pc <= b.end) {
                        const op = ops[pc];
                        if (!g.native_at.isSet(pc) and op != .end and op != .block_entry) counts[@intFromEnum(op)] += 1;
                        pc += bc.opLen(op, fs.code, pc);
                    }
                }
            }
            if (declined) return error.MostlyHandlers;
            g.next_label = null;
            g.m.pins = &.{};
            const entry_labels = try entryChecks(&g, fs, ops, native_op, blk_of, unpinned);
            if (comptime builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64) if (g.opt_loops.len != 0) {
                // Each optimized loop's code, leaving to the baseline's code for the op it
                // leaves to as an entry from outside comes in; then an entry from outside at
                // a loop's head goes to it.
                const Targets = struct {
                    g: *Gen,
                    entry_labels: []const ?Masm.Label,
                    handler_entry: []const ?Masm.Label,
                    pub fn of(t: @This(), pc: u32) Masm.Label {
                        return t.entry_labels[pc] orelse t.handler_entry[pc] orelse t.g.labels[pc].?;
                    }
                };
                const targets: Targets = .{ .g = &g, .entry_labels = try g.scratch.dupe(?Masm.Label, entry_labels), .handler_entry = handler_entry };
                const lay: opt_emit.Layout = .{
                    .tag_off = tag_off,
                    .ctx_ev = ctx_ev,
                    .ev_spin = ev_spin,
                    .inst_slots = inst_slots,
                    .inst_seq = inst_seq,
                    .inst_gen = inst_gen,
                    .inst_remembered = inst_remembered,
                    .inst_class = inst_class,
                    .prim_items = prim_items,
                    .list_items = list_items,
                    .list_seq = list_seq,
                    .list_data_backing = list_data_backing,
                    .list_data_items = list_data_items,
                    .ev_depth = ev_depth,
                    .ev_depth_cap = ev_depth_cap,
                    .frame_span = frame_span,
                    .edge_flags = @intFromPtr(&runtime.gc.edge_flags),
                    .ctx_tlab = ctx_tlab,
                    .tlab_cursor = tlab_cursor,
                    .tlab_limit = tlab_limit,
                    .inst_cell = @sizeOf(InstCell),
                    .prim_cell = @sizeOf(PrimCell),
                    .prim_capacity = prim_capacity,
                    .prim_trailing = prim_trailing,
                    .prim_gc_bytes = prim_gc_bytes,
                    .region_bit = runtime.gc.region_bit,
                    .prim_new_max = prim_new_max,
                    .closure_body = closure_body,
                    .closure_captures = closure_captures,
                };
                for (g.opt_loops) |*ol| {
                    const head_pc = fs.blocks[ol.head].enter;
                    var l = lay;
                    l.gate = ol.gate;
                    if (opt_exits_on) {
                        const pa = std.heap.smp_allocator;
                        const set = try pa.create(OptExits);
                        set.* = .{ .fqn = fs.func.fqn, .head = ol.head, .pcs = try pa.alloc(u32, ol.g.exits.items.len), .counts = try pa.alloc(u64, ol.g.exits.items.len + 1) };
                        for (ol.g.exits.items, set.pcs) |ex, *p| p.* = ex.pc;
                        @memset(set.counts, 0);
                        try opt_exit_sets.append(pa, set);
                        l.exit_counts = set.counts;
                    }
                    try opt_target.emit(&g.m, g.scratch, &ol.g, ol.al, l, ol.entry, targets.of(head_pc), targets);
                    // An entry from outside the code at the loop's head goes to the loop's
                    // code while its gate is open.
                    const gated = try g.m.label();
                    g.m.bind(gated);
                    try g.m.loadAbs32(.t2, @intFromPtr(&ol.gate.on));
                    try g.m.bZero(.t2, targets.of(head_pc));
                    try g.m.jump(ol.entry);
                    entry_labels[head_pc] = gated;
                    _ = opt_count.fetchAdd(1, .monotonic);
                }
            };
            // The direct entry compiled callers go to, out of the way, going on where an entry
            // from a call's handler goes on.
            const direct_label: ?Masm.Label = if (directEntryFits(fs)) dl: {
                const npc: usize = if (fs.param_map.len != 0) fs.body_pc else fs.entry_pc;
                const enter = entry_labels[npc] orelse handler_entry[npc] orelse g.labels[npc].?;
                const l = try g.m.label();
                const dsec = try g.m.cold();
                g.m.bind(l);
                g.m.pins = &.{};
                try emitDirectEntry(&g, enter);
                g.m.endCold(dsec);
                break :dl l;
            } else null;
            const sec = try g.m.cold();
            for (g.slows.items) |s| {
                g.m.bind(s.label);
                g.m.pins = s.pins;
                try g.m.writeBackPins();
                g.m.pins = &.{};
                if (s.stale) {
                    const again = try g.m.label();
                    try g.m.movImm(.t0, @intFromPtr(&fs.stale));
                    try g.m.loadAt(.w32, .t1, .t0, 0);
                    try g.m.addImm(.w32, .t1, .t1, 1);
                    try g.m.storeAt(.w32, .t0, 0, .t1);
                    try g.m.movImm(.t2, threshold_stale);
                    try g.m.cmp(.w32, .t1, .t2);
                    try g.m.bCond(.ge, again);
                    try g.m.tailHandler(handlerOf(s.op), s.pc, s.blk);
                    g.m.bind(again);
                    try g.m.tailHandler(@intFromPtr(&S.recompileAt), s.pc, s.blk);
                } else if (s.fill) |cache| {
                    try g.m.movImm(.t0, @intFromPtr(cache));
                    try g.m.storeCtx(ctx_cache, .t0);
                    try g.m.tailHandler(@intFromPtr(&S.isFill), s.pc, s.blk);
                } else if (s.exit) |x| {
                    if (census_on) {
                        const inner = x.levels[x.levels.len - 1].sc;
                        const what = try std.fmt.allocPrint(std.heap.smp_allocator, "{s} leaves at {t} {d}", .{ inner.func.fqn, s.op, s.pc });
                        const site = try censusSite(fs.func.fqn, what, "exit");
                        try g.m.movImm(.t0, @intFromPtr(&site.count));
                        try g.m.loadAt(.w64, .t1, .t0, 0);
                        try g.m.addImm(.w64, .t1, .t1, 1);
                        try g.m.storeAt(.w64, .t0, 0, .t1);
                    }
                    try g.m.movImm(.t0, @intFromPtr(x));
                    try g.m.storeCtx(ctx_exit, .t0);
                    try g.m.tailHandler(@intFromPtr(&S.inlineExit), s.pc, s.blk);
                } else try g.m.tailHandler(handlerOf(s.op), s.pc, s.blk);
            }
            g.m.endCold(sec);
            const bytes = try g.m.finish();
            direct_off.* = if (direct_label) |l| g.m.labelOffset(l) else null;
            sites.* = g.direct_sites;
            g.direct_sites = .empty;
            for (g.labels, entry_labels, handler_entry, 0..) |l, e, h, pc| if (e orelse h orelse l) |lab| {
                entries[pc] = g.m.labelOffset(lab) orelse return error.Unsupported;
            };
            if (map_ops) {
                slow_marks.clearRetainingCapacity();
                for (g.slows.items) |sl| {
                    const kind: []const u8 = if (sl.stale) "stale" else if (sl.fill != null) "fill" else if (sl.exit != null) "exit" else "handler";
                    const off = g.m.labelOffset(sl.label) orelse continue;
                    slow_marks.append(gpa, .{ .off = off, .kind = kind, .op = sl.op, .pc = sl.pc }) catch break;
                }
                for (g.labels, ops, 0..) |l, op, pc| if (l) |lab| if (op != .jit) {
                    const off = g.m.labelOffset(lab) orelse continue;
                    slow_marks.append(gpa, .{ .off = off, .kind = "at", .op = op, .pc = pc }) catch break;
                };
                if (direct_off.*) |off| slow_marks.append(gpa, .{ .off = off, .kind = "direct", .op = .jit, .pc = 0 }) catch {};
                for (g.in_marks.items) |im| {
                    const off = g.m.labelOffset(im.label) orelse continue;
                    slow_marks.append(gpa, .{ .off = off, .kind = "in", .op = im.op, .pc = im.pc, .fqn = im.sc.func.fqn }) catch break;
                }
            }
            return bytes;
        }

        /// `KLIO_JIT_MAP`: the slow paths of the code `emit` made last on this thread, by
        /// offset, so samples in the code's cold part name what left there.
        const SlowMark = struct { off: u32, kind: []const u8, op: Op, pc: usize, fqn: ?[]const u8 = null };
        threadlocal var slow_marks: std.ArrayList(SlowMark) = .empty;

        /// Per op of the root, the code an entry from outside comes in at when the op's code,
        /// or code it goes on to in place, relies on the kinds of registers (`Gen.knows`):
        /// a check of each such register's tag that goes on to the op, or to its handler
        /// when one differs. Null where nothing needs checking, the op's own code the entry.
        fn entryChecks(g: *Gen, fs: *const bc.FuncStreams, ops: []const Op, native_op: []const bool, blk_of: []const u32, unpinned: []const bool) ![]?Masm.Label {
            const m = &g.m;
            const n = fs.func.n_locals;
            const entry_labels = try g.scratch.alloc(?Masm.Label, fs.code.len);
            @memset(entry_labels, null);
            const any_pins = for (g.pins_of_blk) |ps| {
                if (ps.len != 0) break true;
            } else false;
            if (g.relied.items.len == 0 and !any_pins) return entry_labels;
            const kinds = g.kinds.?;
            // The ops in order, and each op's relied registers, then the registers whose kinds
            // the code from each op on relies on before it writes them, to a fixed point
            // backward over the edges compiled code takes.
            var order: std.ArrayList(u32) = .empty;
            for (fs.blocks) |b| {
                var pc: usize = b.enter;
                while (pc <= b.end) : (pc += bc.opLen(ops[pc], fs.code, pc)) try order.append(g.scratch, @intCast(pc));
            }
            // Per op, by its place in `order`.
            const index = try g.scratch.alloc(u32, fs.code.len);
            @memset(index, std.math.maxInt(u32));
            for (order.items, 0..) |pc, i| index[pc] = @intCast(i);
            const live = try g.scratch.alloc(std.DynamicBitSetUnmanaged, order.items.len);
            for (live) |*l| l.* = try std.DynamicBitSetUnmanaged.initEmpty(g.scratch, n);
            const relied = try g.scratch.alloc(std.DynamicBitSetUnmanaged, order.items.len);
            for (relied) |*l| l.* = try std.DynamicBitSetUnmanaged.initEmpty(g.scratch, n);
            for (g.relied.items) |x| if (x.reg < n and index[x.pc] != std.math.maxInt(u32)) relied[index[x.pc]].set(x.reg);
            var defs = try std.DynamicBitSetUnmanaged.initEmpty(g.scratch, n);
            var out = try std.DynamicBitSetUnmanaged.initEmpty(g.scratch, n);
            var changed = true;
            while (changed) {
                changed = false;
                var k = order.items.len;
                while (k > 0) {
                    k -= 1;
                    const pc = order.items[k];
                    if (!native_op[pc]) continue;
                    out.setRangeValue(.{ .start = 0, .end = n }, false);
                    var succ: [2]u32 = undefined;
                    for (compiledSuccessors(fs, ops, pc, &succ)) |sp| {
                        if (sp < index.len and index[sp] != std.math.maxInt(u32)) out.setUnion(live[index[sp]]);
                    }
                    defs.setRangeValue(.{ .start = 0, .end = n }, false);
                    writesOf(&defs, fs.code, ops[pc], pc);
                    defs.toggleAll();
                    out.setIntersection(defs);
                    out.setUnion(relied[k]);
                    if (!out.eql(live[k])) {
                        live[k].setRangeValue(.{ .start = 0, .end = n }, false);
                        live[k].setUnion(out);
                        changed = true;
                    }
                }
            }
            const sec = try m.cold();
            for (order.items, 0..) |pc, i| {
                if (!native_op[pc] or g.labels[pc] == null) continue;
                const pins: []const masm.Pin = if (blk_of[pc] < g.pins_of_blk.len and !unpinned[pc]) g.pins_of_blk[blk_of[pc]] else &.{};
                var it = live[i].iterator(.{});
                var any = pins.len != 0;
                while (it.next()) |r| {
                    if (kinds_mod.tagOf(kinds.kindAt(pc, @intCast(r))) != null) any = true;
                }
                if (!any) continue;
                const entry = try m.label();
                const miss = try m.label();
                m.bind(entry);
                it = live[i].iterator(.{});
                while (it.next()) |r| {
                    const k = kinds.kindAt(pc, @intCast(r));
                    const t = kinds_mod.tagOf(k) orelse continue;
                    try m.loadTag(.t0, @intCast(r), tag_off);
                    try m.cmpTagImm(.t0, @intFromEnum(t));
                    try m.bCond(.ne, miss);
                    try instFactCheck(g, @intCast(r), k, miss);
                }
                // A pinned register's tag in the frame is its pin's kind, then its payload
                // comes out of the frame; a temporary not yet written here gets its tag.
                for (pins) |p| {
                    if (p.temp and !kinds.written(pc, p.vreg)) continue;
                    try m.loadTag(.t0, p.vreg, tag_off);
                    try m.cmpTagImm(.t0, p.kind);
                    try m.bCond(.ne, miss);
                }
                m.pins = pins;
                try g.prepareTemps();
                try m.loadPins();
                m.pins = &.{};
                try m.jump(g.labels[pc].?);
                m.bind(miss);
                try m.tailHandler(handlerOf(ops[pc]), pc, blk_of[pc]);
                entry_labels[pc] = entry;
            }
            m.endCold(sec);
            return entry_labels;
        }

        /// To `miss` unless the instance in register `r` (its tag checked) is what kind `k`
        /// knows of it (`kinds.instFact`): at least its slots, and plain ones.
        fn instFactCheck(g: *Gen, r: u32, k: kinds_mod.Kind, miss: Masm.Label) !void {
            const m = &g.m;
            if (!kinds_mod.isInstFact(k)) return;
            try m.loadPayload(.w64, .t0, r);
            const slots = kinds_mod.factSlots(k);
            if (slots != 0) {
                try m.loadAt(.w64, .t1, .t0, inst_slots + 8);
                try m.movImm(.t2, slots);
                try m.cmp(.w64, .t1, .t2);
                try m.bCond(.lt, miss);
            }
            // Only a build whose processor copies a slot whole makes plain slots.
            if (comptime runtime.plain_slots) if (kinds_mod.factPlain(k)) {
                try m.loadAt(.w32, .t1, .t0, inst_seq);
                try m.bBitClear(.t1, 31, miss);
            };
        }

        /// Per block of the root, the registers the loop it lies in keeps in machine
        /// registers: a loop is a back edge's target through its source, loops that
        /// overlap taken as one. A register is kept when it holds one integer kind at
        /// every op of the loop (`kinds.zig`) and no op of the loop loads it from the
        /// frame's parameters or captures; the most used ones, as many as the backend
        /// has registers for.
        fn choosePins(g: *Gen, fs: *const bc.FuncStreams, ops: []const Op) ![]const []const masm.Pin {
            const nb = fs.blocks.len;
            const out = try g.scratch.alloc([]const masm.Pin, nb);
            @memset(out, &.{});
            if (Masm.n_pin_regs == 0) return out;
            const kinds = g.kinds orelse return out;
            const none = std.math.maxInt(u32);
            const region = try g.scratch.alloc(u32, nb);
            @memset(region, none);
            var n_regions: u32 = 0;
            const c = fs.code;
            // Each block is in the region of the innermost loop holding it, so an inner
            // loop keeps pins of its own whatever its outer loop does between its runs.
            const loops = try naturalLoops(g.scratch, fs, ops);
            for (loops) |l| {
                var took = false;
                for (l.body, region) |in, *r| if (in and r.* == none) {
                    r.* = n_regions;
                    took = true;
                };
                n_regions += @intFromBool(took);
            }
            if (n_regions == 0) return out;
            const n = fs.func.n_locals;
            const Cand = struct { reg: u32, kind: u8, uses: u32, temp: bool };
            // For temporaries: what is live where, and the kinds after each op, made once.
            const live = try ir.regs.Live.init(g.scratch, fs.func.blocks, n);
            const afters = try g.scratch.alloc(?[]kinds_mod.Kind, c.len);
            @memset(afters, null);
            var cands: std.ArrayList(Cand) = .empty;
            var id: u32 = 0;
            while (id < n_regions) : (id += 1) {
                cands.clearRetainingCapacity();
                var any_block = false;
                for (region) |r| any_block = any_block or r == id;
                if (!any_block) continue;
                var r: u32 = 0;
                while (r < n) : (r += 1) {
                    var kind: ?u8 = null;
                    var ok = true;
                    var uses: u32 = 0;
                    // Unwritten at some op: a temporary the loop writes before it reads.
                    var temp = false;
                    for (fs.blocks, 0..) |b, bi| {
                        if (region[bi] != id) continue;
                        var pc: usize = b.enter;
                        while (pc <= b.end and ok) : (pc += bc.opLen(ops[pc], c, pc)) {
                            const row = kinds.at(pc) orelse continue;
                            const k = row[r];
                            if (k == kinds_mod.unreached) continue;
                            if (k == kinds_mod.unwritten) {
                                temp = true;
                                uses += usesOf(c, ops[pc], pc, r);
                                continue;
                            }
                            const t = kinds_mod.tagOf(k) orelse {
                                ok = false;
                                break;
                            };
                            if (!integerKind(t)) {
                                ok = false;
                                break;
                            }
                            if (kind) |kk| {
                                if (kk != k) ok = false;
                            } else kind = k;
                            switch (ops[pc]) {
                                .load_param, .load_capture => if (c[pc + 1] == r) {
                                    ok = false;
                                },
                                .load_params => for (0..c[pc + 1]) |q| {
                                    if (c[pc + 2 + 2 * q] == r) ok = false;
                                },
                                else => {},
                            }
                            uses += usesOf(c, ops[pc], pc, r);
                        }
                        if (!ok) break;
                    }
                    if (ok and temp and kind != null) ok = try tempFits(g, fs, ops, kinds, live, region, id, r, kind.?, afters);
                    if (ok and uses != 0) if (kind) |k| try cands.append(g.scratch, .{ .reg = r, .kind = k, .uses = uses, .temp = temp });
                }
                std.mem.sort(Cand, cands.items, {}, struct {
                    fn gt(_: void, x: Cand, y: Cand) bool {
                        return x.uses > y.uses;
                    }
                }.gt);
                const take = @min(cands.items.len, Masm.n_pin_regs);
                if (take == 0) continue;
                _ = pinned_count.fetchAdd(@intCast(take), .monotonic);
                const pins = try g.scratch.alloc(masm.Pin, take);
                for (cands.items[0..take], pins, 0..) |cd, *pin, k| pin.* = .{ .vreg = cd.reg, .reg = @intCast(k), .kind = cd.kind, .temp = cd.temp };
                for (region, 0..) |rg, bi| if (rg == id) {
                    out[bi] = pins;
                };
            }
            return out;
        }

        /// Whether register `r`, unwritten at some op of loop region `id` and of kind `kind`
        /// wherever it is known there, can be a temporary its loop keeps (`Pin.temp`): live on
        /// the way into none of the region's blocks, nor where a catch or a finally starts, so
        /// nothing it holds is lost when its frame tag is set on the way in; and every op of
        /// the region that writes it writing `kind`. "Unwritten" says only that some path has
        /// not written it: a move of a register a catch's block has not seen written writes
        /// what the kinds cannot tell.
        fn tempFits(g: *Gen, fs: *const bc.FuncStreams, ops: []const Op, kinds: *const kinds_mod.Kinds, live: ?ir.regs.Live, region: []const u32, id: u32, r: u32, kind: u8, afters: []?[]kinds_mod.Kind) !bool {
            const lv = live orelse return false;
            if (lv.isHandled(r)) return false;
            const c = fs.code;
            var one = try std.DynamicBitSetUnmanaged.initEmpty(g.scratch, fs.func.n_locals);
            for (fs.blocks, 0..) |b, bi| {
                if (region[bi] != id) continue;
                const in = lv.liveIn(bi);
                if ((in[r >> 6] >> @as(u6, @truncate(r))) & 1 != 0) return false;
                var pc: usize = b.enter;
                while (pc <= b.end) : (pc += bc.opLen(ops[pc], c, pc)) {
                    const row = kinds.at(pc) orelse continue;
                    const aft = afters[pc] orelse blk: {
                        const buf = try g.scratch.alloc(kinds_mod.Kind, row.len);
                        const x = kinds.after(fs, @intCast(bi), pc, buf) orelse continue;
                        afters[pc] = x;
                        break :blk x;
                    };
                    one.unsetAll();
                    writesOf(&one, c, ops[pc], pc);
                    const writes = one.isSet(r) or aft[r] != row[r];
                    if (writes and aft[r] != kind) return false;
                    if (ops[pc] == .end) break;
                }
            }
            return true;
        }

        /// Whether a pin may hold kind `t`: a value whose payload is its whole content.
        fn integerKind(t: Tag) bool {
            return switch (t) {
                .Int, .Long, .Bool, .Char, .Short, .Byte, .UInt, .ULong, .UShort, .UByte => true,
                else => false,
            };
        }

        /// How often the op at `pc` names register `r` among its operands and result, for
        /// choosing which registers a loop keeps.
        fn usesOf(c: []const u32, op: Op, pc: usize, r: u32) u32 {
            var n: u32 = 0;
            const words: []const u32 = switch (op) {
                .bin, .add, .sub, .cmp, .bin_mul, .bin_div, .bin_mod, .bin_and, .bin_or, .bin_xor, .bin_shl, .bin_shr, .bin_ushr, .bin_ident_eq, .bin_ident_neq, .cmp_br => c[pc + 3 .. pc + 6],
                .un, .un_inc, .un_dec, .un_neg, .conv_byte, .conv_short, .conv_int, .conv_long, .conv_float, .conv_double, .conv_char, .fn_inv => c[pc + 3 .. pc + 5],
                .const_int, .const_val, .move => c[pc + 1 .. pc + 3],
                .not, .not_null, .is, .cast, .get_field, .array_get, .iter_open => c[pc + 2 .. pc + 4],
                .set_field, .array_set => c[pc + 2 .. pc + 5],
                .iter_has, .iter_get => c[pc + 2 .. pc + 6],
                .br => c[pc + 1 .. pc + 2],
                // A call's argument run and result register.
                .call, .vcall, .callv, .native => {
                    if (r >= c[pc + 3] and r < c[pc + 3] + c[pc + 4]) n += 1;
                    if (c[pc + 5] == r) n += 1;
                    return n;
                },
                .new => {
                    if (r >= c[pc + 4] and r < c[pc + 4] + c[pc + 5]) n += 1;
                    if (c[pc + 6] == r) n += 1;
                    return n;
                },
                else => if (isBinK(op) or isCmpBrK(op)) blk: {
                    if (c[pc + 2] == r) n += 1;
                    if (c[pc + 9] == r) n += 1;
                    break :blk &.{};
                } else &.{},
            };
            for (words) |w| {
                if (w == r) n += 1;
            }
            return n;
        }

        /// Adds to `set` the register `op` at `pc` surely writes, where its layout names one;
        /// an op it does not know writes none here.
        fn writesOf(set: *std.DynamicBitSetUnmanaged, c: []const u32, op: Op, pc: usize) void {
            const r: u32 = switch (op) {
                .const_int, .const_val, .move, .load_param, .const_str, .load_capture, .const_load, .make_cell, .cell_get => c[pc + 1],
                .bin, .add, .sub, .cmp, .bin_mul, .bin_div, .bin_mod, .bin_and, .bin_or, .bin_xor, .bin_shl, .bin_shr, .bin_ushr, .bin_ident_eq, .bin_ident_neq, .cmp_br => c[pc + 3],
                .un, .un_inc, .un_dec, .un_neg, .conv_byte, .conv_short, .conv_int, .conv_long, .conv_float, .conv_double, .conv_char, .fn_inv, .fn_to_raw_bits, .fn_to_bits, .fn_float_from_bits, .fn_double_from_bits, .fn_count_trailing_zero_bits, .fn_uint_to_float, .fn_uint_to_double, .fn_ulong_to_float, .fn_ulong_to_double, .fn_sin, .fn_cos, .fn_sqrt, .fn_to_ulong, .fn_to_uint, .fn_to_ushort, .fn_to_ubyte, .fn_unsigned_bits => c[pc + 3],
                .not, .not_null, .get_field, .array_get, .load_object, .load_static, .is, .cast, .box_value, .unbox_value, .iter_open, .iter_has, .iter_get => c[pc + 2],
                .call, .vcall, .callv, .native => c[pc + 5],
                .new => c[pc + 6],
                else => {
                    if (isBinK(op) or isCmpBrK(op)) {
                        if (c[pc + 9] < set.bit_length) set.set(c[pc + 9]);
                    }
                    return;
                },
            };
            if (r < set.bit_length) set.set(r);
        }

        /// Where the root's op at `pc`, run in place, goes on to in compiled code: the next
        /// op, a branch's targets, past a `bin_k`'s fronted op; nowhere for an op that ends
        /// the code's run (a return, the frame loop's terminator).
        fn compiledSuccessors(fs: *const bc.FuncStreams, ops: []const Op, pc: usize, out: *[2]u32) []const u32 {
            const c = fs.code;
            const op = ops[pc];
            switch (op) {
                .jump, .goto_try => {
                    out[0] = c[pc + 2];
                    return out[0..1];
                },
                .br => {
                    out.* = .{ c[pc + 3], c[pc + 5] };
                    return out[0..2];
                },
                .cmp_br => {
                    out.* = .{ c[pc + 7], c[pc + 9] };
                    return out[0..2];
                },
                .cmp_br_k_less, .cmp_br_k_less_eq, .cmp_br_k_greater, .cmp_br_k_greater_eq, .cmp_br_k_eq, .cmp_br_k_not_eq, .cmp_br_k_boxed_eq, .cmp_br_k_boxed_not_eq, .cmp_br_k_ident_eq, .cmp_br_k_ident_neq => {
                    out.* = .{ c[pc + 13], c[pc + 15] };
                    return out[0..2];
                },
                .ret, .ret_try, .term_exit, .end => return out[0..0],
                else => {
                    out[0] = @intCast(if (isBinK(op)) pc + 12 else pc + bc.opLen(op, c, pc));
                    return out[0..1];
                },
            }
        }

        /// Per block, whether it lies between a back edge's target and its source, the
        /// blocks the loop's turns run.
        fn loopBlocks(gpa: std.mem.Allocator, fs: *const bc.FuncStreams, ops: []const Op) ![]bool {
            const in_loop = try gpa.alloc(bool, fs.blocks.len);
            @memset(in_loop, false);
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            for (try naturalLoops(arena.allocator(), fs, ops)) |l| {
                for (l.body, in_loop) |in, *il| il.* = il.* or in;
            }
            return in_loop;
        }

        const Loop = struct { head: u32, body: []bool, size: u32 };

        /// The function's loops, innermost first: a loop is a back edge's target and every
        /// block that reaches the edge's source without passing the target, the back edges
        /// to one target making one loop. A block laid out between them that no path back
        /// passes through is in none.
        fn naturalLoops(a: std.mem.Allocator, fs: *const bc.FuncStreams, ops: []const Op) ![]Loop {
            const nb = fs.blocks.len;
            const c = fs.code;
            // Each block's successors through its ops' edges and its terminator.
            const preds = try a.alloc(std.ArrayList(u32), nb);
            for (preds) |*l| l.* = .empty;
            const succs = try a.alloc(std.ArrayList(u32), nb);
            for (succs) |*l| l.* = .empty;
            for (fs.blocks, 0..) |b, bi| {
                var pc: usize = b.enter;
                while (pc <= b.end) : (pc += bc.opLen(ops[pc], c, pc)) {
                    var succ: [2]u32 = undefined;
                    const targets: []const u32 = switch (ops[pc]) {
                        .jump, .goto_try => blk: {
                            succ[0] = c[pc + 1];
                            break :blk succ[0..1];
                        },
                        .br => blk: {
                            succ = .{ c[pc + 2], c[pc + 4] };
                            break :blk succ[0..2];
                        },
                        .cmp_br => blk: {
                            succ = .{ c[pc + 6], c[pc + 8] };
                            break :blk succ[0..2];
                        },
                        .end, .term_exit => switch (fs.func.blocks[bi].terminator) {
                            .Goto => |t| blk: {
                                succ[0] = t.int();
                                break :blk succ[0..1];
                            },
                            .Branch => |br| blk: {
                                succ = .{ br.t.int(), br.f.int() };
                                break :blk succ[0..2];
                            },
                            else => &.{},
                        },
                        else => if (isCmpBrK(ops[pc])) blk: {
                            succ = .{ c[pc + 12], c[pc + 14] };
                            break :blk succ[0..2];
                        } else &.{},
                    };
                    for (targets) |t| if (t < nb) {
                        try preds[t].append(a, @intCast(bi));
                        try succs[bi].append(a, t);
                    };
                    if (ops[pc] == .end) break;
                }
            }
            // A back edge goes to a block on the depth-first path to its source, from the
            // entry and then from any block it does not reach (a handler's): an edge to a
            // block laid out earlier is no back edge unless it is one.
            var back: std.ArrayList([2]u32) = .empty;
            const state = try a.alloc(u8, nb); // 0 unseen, 1 on the path, 2 done
            @memset(state, 0);
            var path: std.ArrayList(struct { blk: u32, next: u32 }) = .empty;
            for (0..nb) |root| {
                if (state[root] != 0) continue;
                state[root] = 1;
                try path.append(a, .{ .blk = @intCast(root), .next = 0 });
                while (path.items.len != 0) {
                    const top = &path.items[path.items.len - 1];
                    const out = succs[top.blk].items;
                    if (top.next == out.len) {
                        state[top.blk] = 2;
                        _ = path.pop();
                        continue;
                    }
                    const t = out[top.next];
                    top.next += 1;
                    switch (state[t]) {
                        0 => {
                            state[t] = 1;
                            try path.append(a, .{ .blk = t, .next = 0 });
                        },
                        1 => try back.append(a, .{ t, top.blk }),
                        else => {},
                    }
                }
            }
            var loops: std.ArrayList(Loop) = .empty;
            var work: std.ArrayList(u32) = .empty;
            for (back.items) |e| {
                const head, const tail = e;
                const body = for (loops.items) |l| {
                    if (l.head == head) break l.body;
                } else blk: {
                    const b = try a.alloc(bool, nb);
                    @memset(b, false);
                    b[head] = true;
                    try loops.append(a, .{ .head = head, .body = b, .size = 0 });
                    break :blk b;
                };
                work.clearRetainingCapacity();
                if (!body[tail]) {
                    body[tail] = true;
                    try work.append(a, tail);
                }
                while (work.pop()) |x| {
                    for (preds[x].items) |p| if (!body[p]) {
                        body[p] = true;
                        try work.append(a, p);
                    };
                }
            }
            for (loops.items) |*l| {
                for (l.body) |in| l.size += @intFromBool(in);
            }
            std.mem.sort(Loop, loops.items, {}, struct {
                fn lt(_: void, x: Loop, y: Loop) bool {
                    return x.size < y.size;
                }
            }.lt);
            return loops.items;
        }

        fn handlerOf(op: Op) usize {
            return @intFromPtr(S.table[@intFromEnum(op)]);
        }

        /// The order mask's compare as a condition, null for one that always or never holds.
        fn condOf(mask: u32) ?Cond {
            return switch (mask) {
                0b001 => .lt,
                0b011 => .le,
                0b010 => .eq,
                0b101 => .ne,
                0b100 => .gt,
                0b110 => .ge,
                else => null,
            };
        }

        /// Emits `op` at `pc` natively when its fast path compiles; false leaves it to
        /// its handler. Every check comes before any store, so a failed one leaves
        /// nothing for the handler to see.
        fn compileOp(g: *Gen, op: Op, pc: usize, blk: u32) CompileError!bool {
            const m = &g.m;
            if (skip_ops[@intFromEnum(op)]) return false;
            switch (op) {
                .const_int => {
                    const dst = g.code(pc, 1);
                    try m.storeValue(dst, bytesOf(.{ .Int = @bitCast(g.code(pc, 2)) }));
                },
                .const_val => {
                    const dst = g.code(pc, 1);
                    try m.storeValue(dst, bytesOf(g.fs.values[g.code(pc, 2)]));
                },
                .move => {
                    const dst = g.code(pc, 1);
                    try m.copyValue(dst, g.code(pc, 2));
                },
                .load_param => if (g.levels.items.len != 0) try inlineParam(g, g.code(pc, 1), g.code(pc, 2)) else {
                    try loadParam(g, g.code(pc, 1), g.code(pc, 2));
                    try checkParams(g, op, pc, blk);
                },
                .load_params => {
                    const n = g.code(pc, 1);
                    for (0..n) |k| {
                        if (g.levels.items.len != 0) try inlineParam(g, g.code(pc, 2 + 2 * k), g.code(pc, 3 + 2 * k)) else try loadParam(g, g.code(pc, 2 + 2 * k), g.code(pc, 3 + 2 * k));
                    }
                    if (g.levels.items.len == 0) try checkParams(g, op, pc, blk);
                },
                .call, .vcall, .callv => return callOp(g, op, pc, blk),
                .new => return newOp(g, pc, blk),
                .escape => {
                    if (census_on) try g.countEscape(pc, blk);
                    return false;
                },
                .native => {
                    const k = g.nativeIntrinsic(g.fs, pc);
                    if (k == .none) {
                        if (census_on) try g.countNative(pc);
                        return false;
                    }
                    const fail = try g.slow(op, pc, blk);
                    try intrinsic(g, k, pc, fail);
                },
                .ret => {
                    if (g.levels.items.len == 0) return false;
                    try inlineRet(g, pc);
                },
                .jump => {
                    const fail = try g.slow(op, pc, blk);
                    try g.span(pc + 3);
                    try g.edge(g.code(pc, 1), g.code(pc, 2), blk, pc + 3, fail);
                },
                .br => {
                    const fail = try g.slow(op, pc, blk);
                    const cond = g.code(pc, 1);
                    try g.guard(cond, .Bool, fail);
                    // Not t0 or t3: storing the span goes through t0, a guard through t3.
                    try m.loadPayloadByte(.t2, cond);
                    try g.span(pc + 6);
                    try g.branchEdges(.t2, blk, .{ g.code(pc, 2), g.code(pc, 3) }, .{ g.code(pc, 4), g.code(pc, 5) }, pc + 6, fail);
                },
                .cmp_br => {
                    const kw = g.code(pc, 2);
                    const bop: ir.BinOp = @enumFromInt(kw & 0xff);
                    if (isIdent(bop)) {
                        const fail = try g.slow(op, pc, blk);
                        try identRegs(g, bop, g.code(pc, 4), g.code(pc, 5), fail);
                        try g.branchOn(pc, blk, .t2, fail);
                        return true;
                    }
                    const c = condOf(kw >> 8) orelse return false;
                    const fail = try g.slow(op, pc, blk);
                    try compareRegs(g, bop, g.code(pc, 4), g.code(pc, 5), c, fail);
                    try g.branchOn(pc, blk, .t2, fail);
                },
                .cmp_br_k_less, .cmp_br_k_less_eq, .cmp_br_k_greater, .cmp_br_k_greater_eq, .cmp_br_k_eq, .cmp_br_k_not_eq, .cmp_br_k_boxed_eq, .cmp_br_k_boxed_not_eq, .cmp_br_k_ident_eq, .cmp_br_k_ident_neq => {
                    const bop = kOp(op);
                    const fail = try g.slow(op, pc, blk);
                    if (!try compareK(g, pc, bop, fail)) return false;
                    try g.branchOn(pc + 6, blk, .t2, fail);
                },
                .bin_k_add, .bin_k_sub, .bin_k_mul, .bin_k_div, .bin_k_mod, .bin_k_and, .bin_k_or, .bin_k_xor, .bin_k_shl, .bin_k_shr, .bin_k_ushr, .bin_k_less, .bin_k_less_eq, .bin_k_greater, .bin_k_greater_eq, .bin_k_eq, .bin_k_not_eq, .bin_k_boxed_eq, .bin_k_boxed_not_eq, .bin_k_ident_eq, .bin_k_ident_neq => {
                    const bop = kOp(op);
                    const fail = try g.slow(op, pc, blk);
                    const dst = g.code(pc, 9);
                    if (bc.orderMask(bop) != 0 or isIdent(bop)) {
                        if (!try compareK(g, pc, bop, fail)) return false;
                        try g.putBool(dst, .t2);
                    } else {
                        if (!try arithK(g, pc, bop, dst, fail)) return false;
                    }
                    // The pair's second op only runs on the slow path.
                    try g.goTo(g.target(pc + 12));
                },
                .add, .sub => {
                    const fail = try g.slow(op, pc, blk);
                    try arithRegs(g, if (op == .add) .Add else .Sub, g.code(pc, 3), g.code(pc, 4), g.code(pc, 5), fail);
                },
                .bin_ident_eq, .bin_ident_neq => {
                    const fail = try g.slow(op, pc, blk);
                    try identRegs(g, if (op == .bin_ident_eq) .IdentEq else .IdentNeq, g.code(pc, 4), g.code(pc, 5), fail);
                    try g.putBool(g.code(pc, 3), .t2);
                },
                .fn_inv => {
                    const dst = g.code(pc, 3);
                    const src = g.code(pc, 4);
                    if (try g.knowsInteger(src)) |w| {
                        try m.loadPayload(w, .t1, src);
                        try m.notR(w, .t2, .t1);
                        try m.storePayload(w, dst, .t2);
                        try g.putTag(dst, if (w == .w32) .Int else .Long, .t3);
                        return true;
                    }
                    const fail = try g.slow(op, pc, blk);
                    const is_long = try m.label();
                    const done = try m.label();
                    try m.loadTag(.t0, src, tag_off);
                    try m.cmpTagImm(.t0, tagOf(.Int));
                    try m.bCond(.ne, is_long);
                    try m.loadPayload(.w32, .t1, src);
                    try m.notR(.w32, .t2, .t1);
                    try m.storePayload(.w32, dst, .t2);
                    try g.putTag(dst, .Int, .t3);
                    m.bind(done);
                    const sec = try m.cold();
                    m.bind(is_long);
                    try m.cmpTagImm(.t0, tagOf(.Long));
                    try m.bCond(.ne, fail);
                    try m.loadPayload(.w64, .t1, src);
                    try m.notR(.w64, .t2, .t1);
                    try m.storePayload(.w64, dst, .t2);
                    try g.putTag(dst, .Long, .t3);
                    try m.jump(done);
                    m.endCold(sec);
                },
.fn_to_ulong, .fn_to_uint, .fn_unsigned_bits, .fn_float_from_bits, .fn_double_from_bits, .fn_to_raw_bits => try bitView(g, op, pc, blk),
                .array_set => {
                    const fail = try g.slow(op, pc, blk);
                    try arraySet(g, g.code(pc, 2), g.code(pc, 3), g.code(pc, 4), fail);
                },
                .load_static => {
                    if (!objects_native) return false;
                    const r = g.module.resolved orelse return false;
                    const static = g.code(pc, 3);
                    if (static >= r.statics.len) return false;
                    const fail = try g.slow(op, pc, blk);
                    try loadStatic(g, g.code(pc, 2), static, r.statics[static].unit, fail);
                },
                .cmp => {
                    const kw = g.code(pc, 2);
                    const bop: ir.BinOp = @enumFromInt(kw & 0xff);
                    if (isIdent(bop)) {
                        const fail = try g.slow(op, pc, blk);
                        try identRegs(g, bop, g.code(pc, 4), g.code(pc, 5), fail);
                        try g.putBool(g.code(pc, 3), .t2);
                        return true;
                    }
                    const c = condOf(kw >> 8) orelse return false;
                    const fail = try g.slow(op, pc, blk);
                    try compareRegs(g, @enumFromInt(kw & 0xff), g.code(pc, 4), g.code(pc, 5), c, fail);
                    try g.putBool(g.code(pc, 3), .t2);
                },
                .bin, .bin_mul, .bin_div, .bin_and, .bin_or, .bin_xor, .bin_shl, .bin_shr, .bin_ushr => {
                    const kw = g.code(pc, 2);
                    const bop: ir.BinOp = @enumFromInt(kw & 0xff);
                    if (arithKind(bop) != .none) {
                        const fail = try g.slow(op, pc, blk);
                        try arithRegs(g, bop, g.code(pc, 3), g.code(pc, 4), g.code(pc, 5), fail);
                    } else if (condOf(bc.orderMask(bop))) |c| {
                        const fail = try g.slow(op, pc, blk);
                        try compareRegs(g, bop, g.code(pc, 4), g.code(pc, 5), c, fail);
                        try g.putBool(g.code(pc, 3), .t2);
                    } else return false;
                },
                .not => {
                    const fail = try g.slow(op, pc, blk);
                    const dst = g.code(pc, 2);
                    const src = g.code(pc, 3);
                    try g.guard(src, .Bool, fail);
                    try m.loadPayloadByte(.t0, src);
                    try m.xorImm1(.t2, .t0);
                    try g.putBool(dst, .t2);
                },
                .not_null => {
                    const fail = try g.slow(op, pc, blk);
                    const dst = g.code(pc, 2);
                    const src = g.code(pc, 3);
                    try m.loadTag(.t3, src, tag_off);
                    try m.cmpTagImm(.t3, tagOf(.Null));
                    try m.bCond(.eq, fail);
                    try m.copyValue(dst, src);
                },
                .un_inc, .un_dec, .un_neg => {
                    const dst = g.code(pc, 3);
                    const src = g.code(pc, 4);
                    if (try g.knowsInteger(src)) |w| {
                        try unary(g, op, w, dst, src);
                        try g.putTag(dst, if (w == .w32) .Int else .Long, .t3);
                        return true;
                    }
                    const fail = try g.slow(op, pc, blk);
                    const is_long = try m.label();
                    const done = try m.label();
                    try m.loadTag(.t0, src, tag_off);
                    try m.cmpTagImm(.t0, tagOf(.Int));
                    try m.bCond(.ne, is_long);
                    try unary(g, op, .w32, dst, src);
                    try g.putTag(dst, .Int, .t3);
                    m.bind(done);
                    const sec = try m.cold();
                    m.bind(is_long);
                    try m.cmpTagImm(.t0, tagOf(.Long));
                    try m.bCond(.ne, fail);
                    try unary(g, op, .w64, dst, src);
                    try g.putTag(dst, .Long, .t3);
                    try m.jump(done);
                    m.endCold(sec);
                },
                .conv_long => {
                    const fail = try g.slow(op, pc, blk);
                    const dst = g.code(pc, 3);
                    const src = g.code(pc, 4);
                    try g.guard(src, .Int, fail);
                    try m.loadPayload(.w32, .t0, src);
                    try m.signExtend32(.t0, .t0);
                    try m.storePayload(.w64, dst, .t0);
                    try g.putTag(dst, .Long, .t3);
                },
                .conv_int => {
                    const fail = try g.slow(op, pc, blk);
                    const dst = g.code(pc, 3);
                    const src = g.code(pc, 4);
                    try g.guard(src, .Long, fail);
                    try m.loadPayload(.w32, .t0, src);
                    try m.storePayload(.w32, dst, .t0);
                    try g.putTag(dst, .Int, .t3);
                },
                .get_field => {
                    const fail = try g.slow(op, pc, blk);
                    try getField(g, g.code(pc, 2), g.code(pc, 3), g.code(pc, 4), fail);
                },
                .set_field => {
                    const fail = try g.slow(op, pc, blk);
                    try setField(g, g.code(pc, 2), g.code(pc, 3), g.code(pc, 4), fail);
                },
                .unbox_value => {
                    // An instance of the class answers its field; anything else is itself.
                    const fail = try g.slow(op, pc, blk);
                    const dst = g.code(pc, 2);
                    const src = g.code(pc, 3);
                    const itself = try m.label();
                    const done = try m.label();
                    try m.loadTag(.t0, src, tag_off);
                    try m.cmpTagImm(.t0, tagOf(.Instance));
                    try m.bCond(.ne, itself);
                    try m.loadPayload(.w64, .t0, src);
                    try m.loadAt(.w32, .t1, .t0, inst_class);
                    try m.movImm(.t2, g.code(pc, 4));
                    try m.cmp(.w32, .t1, .t2);
                    try m.bCond(.ne, itself);
                    try getField(g, dst, src, g.code(pc, 5), fail);
                    m.bind(done);
                    const sec = try m.cold();
                    m.bind(itself);
                    try m.copyValue(dst, src);
                    try m.jump(done);
                    m.endCold(sec);
                },
                .box_value => {
                    // An instance or a null is itself; a number takes the handler, which makes one.
                    const fail = try g.slow(op, pc, blk);
                    const dst = g.code(pc, 2);
                    const src = g.code(pc, 3);
                    const itself = try m.label();
                    const not_instance = try m.label();
                    try m.loadTag(.t0, src, tag_off);
                    try m.cmpTagImm(.t0, tagOf(.Instance));
                    try m.bCond(.ne, not_instance);
                    m.bind(itself);
                    try m.copyValue(dst, src);
                    const sec = try m.cold();
                    m.bind(not_instance);
                    try m.cmpTagImm(.t0, tagOf(.Null));
                    try m.bCond(.ne, fail);
                    try m.jump(itself);
                    m.endCold(sec);
                },
                .const_str => {
                    const dst = g.code(pc, 1);
                    const slot = &g.fs.strings[g.code(pc, 3)];
                    const raw = slot.load(.acquire);
                    if (raw != 0) {
                        // Made once, in the permanent generation: the string is a constant now.
                        try m.storeValue(dst, bytesOf(.{ .String = .{ .cell = @ptrFromInt(raw) } }));
                    } else {
                        const fail = try g.slow(op, pc, blk);
                        try m.movImm(.t0, @intFromPtr(slot));
                        try m.loadAcquire(.w64, .t1, .t0, 0);
                        try m.bZero64(.t1, fail);
                        try m.storePayload(.w64, dst, .t1);
                        try g.putTag(dst, .String, .t3);
                    }
                },
                .load_object => {
                    if (!objects_native) return false;
                    const fail = try g.slow(op, pc, blk);
                    try loadObject(g, g.code(pc, 2), g.code(pc, 3), fail);
                },
                .is, .cast => try isOrCast(g, op, pc, blk),
                .array_get => {
                    const fail = try g.slow(op, pc, blk);
                    try arrayGet(g, g.code(pc, 2), g.code(pc, 3), g.code(pc, 4), fail);
                },
                .iter_has => {
                    // A list's or an array's loop: whether its position is not the size
                    // (`forloop.has`; an array's position never passes it); any other value
                    // in the handler.
                    const fail = try g.slow(op, pc, blk);
                    const src = g.code(pc, 3);
                    const idx = g.code(pc, 4);
                    const array = try m.label();
                    const have = try m.label();
                    try g.guard(idx, .Int, fail);
                    try m.loadTag(.t0, src, tag_off);
                    try m.cmpTagImm(.t0, tagOf(.List));
                    try m.bCond(.ne, array);
                    try listItems(g, src, fail);
                    try m.loadAt(.w64, .t1, .t0, list_items + 8);
                    try m.jump(have);
                    m.bind(array);
                    try arrayLen(g, src, fail);
                    m.bind(have);
                    try m.loadPayload(.w32, .t2, idx);
                    try m.signExtend32(.t2, .t2);
                    try m.cmp(.w64, .t2, .t1);
                    try m.setCond(.t2, .ne);
                    try g.putBool(g.code(pc, 2), .t2);
                },
                .iter_get => {
                    // A list's element while its structural count's low 32 bits are the
                    // stamp's high ones (`forloop.get`), an array's as `array_get` reads
                    // it; a change, a position past the end, a writer at work and any
                    // other value in the handler.
                    const fail = try g.slow(op, pc, blk);
                    const dst = g.code(pc, 2);
                    const src = g.code(pc, 3);
                    const idx = g.code(pc, 4);
                    const stamp = g.code(pc, 5);
                    const array = try m.label();
                    const done = try m.label();
                    try m.loadTag(.t0, src, tag_off);
                    try m.cmpTagImm(.t0, tagOf(.List));
                    try m.bCond(.ne, array);
                    try listData(g, src, fail);
                    try g.guard(stamp, .Long, fail);
                    try g.guard(idx, .Int, fail);
                    const counted = try m.label();
                    try m.loadAt(.w64, .t1, .t0, list_data_mod_count);
                    try m.bZero64(.t1, counted);
                    try m.loadAt(.w32, .t1, .t1, mod_count_value);
                    try m.loadPayload(.w64, .t2, stamp);
                    try m.lsrImm(.w64, .t2, .t2, 32);
                    try m.cmp(.w32, .t1, .t2);
                    try m.bCond(.ne, fail);
                    m.bind(counted);
                    try m.loadAt(.w64, .t0, .t0, list_data_items);
                    if (runtime.lockfreeReads() and !S.reclaims) try listRead(g, dst, idx, fail) else try boxedGet(g, dst, idx, fail);
                    try m.jump(done);
                    m.bind(array);
                    try arrayGet(g, dst, src, idx, fail);
                    m.bind(done);
                },
                .load_capture => {
                    if (g.top()) |lv| {
                        const cr = lv.closure orelse return false;
                        try loadCapture(g, cr, g.code(pc, 1), g.code(pc, 2));
                    } else try loadFrom(g, frame_captures, g.code(pc, 1), g.code(pc, 2));
                },
                else => return false,
            }
            return true;
        }

        /// After the root's parameter loads at `pc`: each loaded parameter the kinds take
        /// for its declared primitive type holds it, else the op runs in its handler, which
        /// loads them again (`kinds.paramKind`).
        fn checkParams(g: *Gen, op: Op, pc: usize, blk: u32) !void {
            if (g.kinds == null) return;
            const n: usize = if (op == .load_param) 1 else g.code(pc, 1);
            var fail: ?Masm.Label = null;
            for (0..n) |k| {
                const dst = if (op == .load_param) g.code(pc, 1) else g.code(pc, 2 + 2 * k);
                const idx = if (op == .load_param) g.code(pc, 2) else g.code(pc, 3 + 2 * k);
                const t = kinds_mod.tagOf(kinds_mod.paramKind(g.fs.func, idx)) orelse continue;
                if (fail == null) fail = try g.slow(op, pc, blk);
                try g.m.guardTag(dst, tag_off, @intFromEnum(t), fail.?);
            }
        }

        fn loadParam(g: *Gen, dst: u32, idx: u32) !void {
            return loadFrom(g, frame_params, dst, idx);
        }

        /// Register `dst` = element `idx` of the frame's value slice at `off` (its
        /// parameters or its captures), `Unit` past its end.
        /// Register `dst` = capture `idx` of the closure the caller's register `cr` holds, as
        /// the lambda's frame would read it from its captures: `Unit` past them.
        fn loadCapture(g: *Gen, cr: u32, dst: u32, idx: u32) !void {
            const m = &g.m;
            const inner = g.win();
            const outer: masm.Win = if (g.levels.items.len == 1) .{} else .{ .inline_area = true, .off = g.levels.items[g.levels.items.len - 2].area };
            m.setWin(outer);
            try m.loadPayload(.w64, .t3, cr);
            m.setWin(inner);
            const unit = try m.label();
            const done = try m.label();
            try m.loadAt(.w64, .t0, .t3, closure_captures + 8);
            try m.movImm(.t1, idx);
            try m.cmp(.w64, .t0, .t1);
            try m.bCond(.le, unit);
            try m.loadAt(.w64, .t2, .t3, closure_captures);
            try m.copyValueFrom(dst, .t2, idx * 16);
            m.bind(done);
            const sec = try m.cold();
            m.bind(unit);
            try m.storeValue(dst, bytesOf(.Unit));
            try m.jump(done);
            m.endCold(sec);
        }

        fn loadFrom(g: *Gen, off: u32, dst: u32, idx: u32) !void {
            const m = &g.m;
            const unit = try m.label();
            const done = try m.label();
            try m.loadFrame(.t0, off + 8);
            try m.movImm(.t1, idx);
            try m.cmp(.w64, .t0, .t1);
            try m.bCond(.le, unit);
            try m.loadFrame(.t2, off);
            try m.copyValueFrom(dst, .t2, idx * 16);
            m.bind(done);
            const sec = try m.cold();
            m.bind(unit);
            try m.storeValue(dst, bytesOf(.Unit));
            try m.jump(done);
            m.endCold(sec);
        }

        /// Whether `op` compares two floats as IEEE compares them (not boxed equality).
        fn floatCompare(op: ir.BinOp) bool {
            return switch (op) {
                .Less, .LessEq, .Greater, .GreaterEq, .Eq, .NotEq => true,
                else => false,
            };
        }

        /// `t2` = 1 when registers `l` and `r`, both Int, both Long, or for `op` a float
        /// compare both Double or both Float, compare as `c`.
        fn compareRegs(g: *Gen, op: ir.BinOp, l: u32, r: u32, c: Cond, fail: Masm.Label) !void {
            const m = &g.m;
            if (try g.knowsPair(l, r)) |w| {
                try m.loadPayload(w, .t0, l);
                try m.loadPayload(w, .t1, r);
                try m.cmp(w, .t0, .t1);
                try m.setCond(.t2, c);
                return;
            }
            const not_int = try m.label();
            const not_long = try m.label();
            const done = try m.label();
            try m.loadTag(.t0, l, tag_off);
            try m.cmpTagImm(.t0, tagOf(.Int));
            try m.bCond(.ne, not_int);
            try g.guard(r, .Int, fail);
            try m.loadPayload(.w32, .t0, l);
            try m.loadPayload(.w32, .t1, r);
            try m.cmp(.w32, .t0, .t1);
            try m.setCond(.t2, c);
            m.bind(done);
            // Every other pair out of the way of the Int one.
            const sec = try m.cold();
            m.bind(not_int);
            try m.cmpTagImm(.t0, tagOf(.Long));
            try m.bCond(.ne, not_long);
            try g.guard(r, .Long, fail);
            try m.loadPayload(.w64, .t0, l);
            try m.loadPayload(.w64, .t1, r);
            try m.cmp(.w64, .t0, .t1);
            try m.setCond(.t2, c);
            try m.jump(done);
            m.bind(not_long);
            if (isEquality(op)) {
                const other = try m.label();
                try nullBoolEq(g, l, r, c, fail, done, other);
                m.bind(other);
            }
            if (floatCompare(op)) {
                try floatPair(g, l, r, fail, struct {
                    fn body(gg: *Gen, dbl: bool, cc: Cond) !void {
                        try gg.m.fcmpSet(dbl, .t2, .f0, .f1, cc);
                    }
                }.body, c, done);
            } else try m.jump(fail);
            m.endCold(sec);
        }

        fn isEquality(op: ir.BinOp) bool {
            return switch (op) {
                .Eq, .NotEq, .BoxedEq, .BoxedNotEq => true,
                else => false,
            };
        }

        /// `t2` = `l == r` (as `c`, `eq` or `ne`) when either is null or both are Bools, as
        /// `eqQuick` answers, then to `done`; a captured variable's cell goes to `fail`, and
        /// any other pair to `other` with the left tag still in t0.
        fn nullBoolEq(g: *Gen, l: u32, r: u32, c: Cond, fail: Masm.Label, done: Masm.Label, other: Masm.Label) !void {
            const m = &g.m;
            const is_null = try m.label();
            try m.loadTag(.t1, r, tag_off);
            try m.cmpTagImm(.t0, tagOf(.Cell));
            try m.bCond(.eq, fail);
            try m.cmpTagImm(.t1, tagOf(.Cell));
            try m.bCond(.eq, fail);
            try m.cmpTagImm(.t0, tagOf(.Null));
            try m.bCond(.eq, is_null);
            try m.cmpTagImm(.t1, tagOf(.Null));
            try m.bCond(.eq, is_null);
            try m.cmpTagImm(.t0, tagOf(.Bool));
            try m.bCond(.ne, other);
            try m.cmpTagImm(.t1, tagOf(.Bool));
            try m.bCond(.ne, fail);
            try m.loadPayloadByte(.t0, l);
            try m.loadPayloadByte(.t1, r);
            try m.cmp(.w32, .t0, .t1);
            try m.setCond(.t2, c);
            try m.jump(done);
            // One is null: equal when both are, when their tags are.
            m.bind(is_null);
            try m.cmp(.w32, .t0, .t1);
            try m.setCond(.t2, c);
            try m.jump(done);
        }

        /// `t2` = `l === r` (`!==` for IdentNeq) when either is null or both are instances, as
        /// `identQuick` answers; anything else goes to `fail`.
        fn identRegs(g: *Gen, op: ir.BinOp, l: u32, r: u32, fail: Masm.Label) !void {
            const m = &g.m;
            const c: Cond = if (op == .IdentNeq) .ne else .eq;
            const is_null = try m.label();
            const done = try m.label();
            try m.loadTag(.t0, l, tag_off);
            try m.loadTag(.t1, r, tag_off);
            try m.cmpTagImm(.t0, tagOf(.Cell));
            try m.bCond(.eq, fail);
            try m.cmpTagImm(.t1, tagOf(.Cell));
            try m.bCond(.eq, fail);
            try m.cmpTagImm(.t0, tagOf(.Null));
            try m.bCond(.eq, is_null);
            try m.cmpTagImm(.t1, tagOf(.Null));
            try m.bCond(.eq, is_null);
            try m.cmpTagImm(.t0, tagOf(.Instance));
            try m.bCond(.ne, fail);
            try m.cmpTagImm(.t1, tagOf(.Instance));
            try m.bCond(.ne, fail);
            try m.loadPayload(.w64, .t0, l);
            try m.loadPayload(.w64, .t1, r);
            try m.cmp(.w64, .t0, .t1);
            try m.setCond(.t2, c);
            m.bind(done);
            const sec = try m.cold();
            m.bind(is_null);
            try m.cmp(.w32, .t0, .t1);
            try m.setCond(.t2, c);
            try m.jump(done);
            m.endCold(sec);
        }

        /// `toULong()`, `toUInt()` and an unsigned number's `data`: the same bits under the
        /// other type's tag, as `numfn` makes them, for an Int or a Long, and a ULong or a UInt.
        fn bitView(g: *Gen, op: Op, pc: usize, blk: u32) !void {
            const m = &g.m;
            const fail = try g.slow(op, pc, blk);
            const dst = g.code(pc, 3);
            const src = g.code(pc, 4);
            const second = try m.label();
            const done = try m.label();
            const Arm = struct { from: Tag, to: Tag, w: masm.Wd, extend: bool };
            const arms: [2]Arm = switch (op) {
                .fn_to_ulong => .{ .{ .from = .Long, .to = .ULong, .w = .w64, .extend = false }, .{ .from = .Int, .to = .ULong, .w = .w64, .extend = true } },
                .fn_to_uint => .{ .{ .from = .Int, .to = .UInt, .w = .w32, .extend = false }, .{ .from = .Long, .to = .UInt, .w = .w32, .extend = false } },
                .fn_unsigned_bits => .{ .{ .from = .ULong, .to = .Long, .w = .w64, .extend = false }, .{ .from = .UInt, .to = .Int, .w = .w32, .extend = false } },
                .fn_float_from_bits => .{ .{ .from = .Int, .to = .Float, .w = .w32, .extend = false }, .{ .from = .Long, .to = .Float, .w = .w32, .extend = false } },
                .fn_double_from_bits => .{ .{ .from = .Long, .to = .Double, .w = .w64, .extend = false }, .{ .from = .Int, .to = .Double, .w = .w64, .extend = true } },
                .fn_to_raw_bits => .{ .{ .from = .Float, .to = .Int, .w = .w32, .extend = false }, .{ .from = .Double, .to = .Long, .w = .w64, .extend = false } },
                else => unreachable,
            };
            try m.loadTag(.t0, src, tag_off);
            var sec: masm.Cold = undefined;
            for (arms, 0..) |arm, i| {
                try m.cmpTagImm(.t0, @intFromEnum(arm.from));
                try m.bCond(.ne, if (i == 0) second else fail);
                if (arm.extend) {
                    try m.loadPayload(.w32, .t1, src);
                    try m.signExtend32(.t1, .t1);
                } else try m.loadPayload(arm.w, .t1, src);
                try m.storePayload(arm.w, dst, .t1);
                try g.putTag(dst, arm.to, .t3);
                if (i == 0) {
                    m.bind(done);
                    sec = try m.cold();
                    m.bind(second);
                } else {
                    try m.jump(done);
                    m.endCold(sec);
                }
            }
        }

        /// For registers `l` and `r` both Double or both Float: loads them into f0 and f1
        /// and runs `body`, then goes to `done`; anything else goes to `fail`. Expects the
        /// left register's tag in t0.
        fn floatPair(g: *Gen, l: u32, r: u32, fail: Masm.Label, comptime body: anytype, arg: anytype, done: Masm.Label) !void {
            const m = &g.m;
            const single = try m.label();
            try m.cmpTagImm(.t0, tagOf(.Double));
            try m.bCond(.ne, single);
            try g.guard(r, .Double, fail);
            try m.loadF(true, .f0, l);
            try m.loadF(true, .f1, r);
            try body(g, true, arg);
            try m.jump(done);
            m.bind(single);
            try m.cmpTagImm(.t0, tagOf(.Float));
            try m.bCond(.ne, fail);
            try g.guard(r, .Float, fail);
            try m.loadF(false, .f0, l);
            try m.loadF(false, .f1, r);
            try body(g, false, arg);
            try m.jump(done);
        }

        const ArithKind = enum { none, int_only, both };

        /// Which operand types `op` computes in place: Int and Long for the bitwise and
        /// shift operators (Booleans too for `and`, `or` and `xor`), those and floats for
        /// `+ - *`, floats alone for `/` (an integer divisor may be zero).
        fn arithKind(op: ir.BinOp) ArithKind {
            return switch (op) {
                .Add, .Sub, .Mul => .both,
                .And, .Or, .Xor, .Shl, .Shr, .UShr => .int_only,
                .Div => .both,
                else => .none,
            };
        }

        /// Register `dst` = `l op r` for two Ints, two Longs, or for `+ - * /` two Doubles
        /// or two Floats; an integer `/` goes to `fail`.
        fn arithRegs(g: *Gen, op: ir.BinOp, dst: u32, l: u32, r: u32, fail: Masm.Label) !void {
            const m = &g.m;
            const not_int = try m.label();
            const not_long = try m.label();
            const done = try m.label();
            const ints = op != .Div;
            if (ints) return intFirstArith(g, op, dst, l, r, fail);
            try m.loadTag(.t0, l, tag_off);
            try m.cmpTagImm(.t0, tagOf(.Int));
            try m.bCond(.ne, not_int);
            if (ints) {
                try g.guard(r, .Int, fail);
                try m.loadPayload(.w32, .t0, l);
                try m.loadPayload(.w32, .t1, r);
                try arith(g, op, .w32);
                try m.storePayload(.w32, dst, .t2);
                try g.putTag(dst, .Int, .t3);
                try m.jump(done);
            } else try m.jump(fail);
            m.bind(not_int);
            try m.cmpTagImm(.t0, tagOf(.Long));
            try m.bCond(.ne, not_long);
            if (ints) {
                try g.guard(r, .Long, fail);
                try m.loadPayload(.w64, .t0, l);
                try m.loadPayload(.w64, .t1, r);
                try arith(g, op, .w64);
                try m.storePayload(.w64, dst, .t2);
                try g.putTag(dst, .Long, .t3);
                try m.jump(done);
            } else try m.jump(fail);
            m.bind(not_long);
            if (arithKind(op) == .both) {
                const Body = struct {
                    fn body(gg: *Gen, dbl: bool, a: struct { ir.BinOp, u32 }) !void {
                        try gg.m.fop(fop(a[0]), dbl, .f0, .f0, .f1);
                        try gg.m.storeF(dbl, a[1], .f0);
                        try gg.putTag(a[1], if (dbl) .Double else .Float, .t3);
                    }
                };
                try floatPair(g, l, r, fail, Body.body, .{ op, dst }, done);
            } else try m.jump(fail);
            m.bind(done);
        }

        /// `arithRegs` for an operator Ints and Longs compute: the Int pair in line, falling
        /// through, and every other pair out of the way.
        fn intFirstArith(g: *Gen, op: ir.BinOp, dst: u32, l: u32, r: u32, fail: Masm.Label) !void {
            const m = &g.m;
            if (try g.knowsPair(l, r)) |w| {
                try m.loadPayload(w, .t0, l);
                try m.loadPayload(w, .t1, r);
                try arith(g, op, w);
                try m.storePayload(w, dst, .t2);
                try g.putTag(dst, if (w == .w32) .Int else .Long, .t3);
                return;
            }
            const not_int = try m.label();
            const not_long = try m.label();
            const done = try m.label();
            try m.loadTag(.t0, l, tag_off);
            try m.cmpTagImm(.t0, tagOf(.Int));
            try m.bCond(.ne, not_int);
            try g.guard(r, .Int, fail);
            try m.loadPayload(.w32, .t0, l);
            try m.loadPayload(.w32, .t1, r);
            try arith(g, op, .w32);
            try m.storePayload(.w32, dst, .t2);
            try g.putTag(dst, .Int, .t3);
            m.bind(done);
            const sec = try m.cold();
            m.bind(not_int);
            try m.cmpTagImm(.t0, tagOf(.Long));
            try m.bCond(.ne, not_long);
            try g.guard(r, .Long, fail);
            try m.loadPayload(.w64, .t0, l);
            try m.loadPayload(.w64, .t1, r);
            try arith(g, op, .w64);
            try m.storePayload(.w64, dst, .t2);
            try g.putTag(dst, .Long, .t3);
            try m.jump(done);
            m.bind(not_long);
            if (arithKind(op) == .both) {
                const Body = struct {
                    fn body(gg: *Gen, dbl: bool, a: struct { ir.BinOp, u32 }) !void {
                        try gg.m.fop(fop(a[0]), dbl, .f0, .f0, .f1);
                        try gg.m.storeF(dbl, a[1], .f0);
                        try gg.putTag(a[1], if (dbl) .Double else .Float, .t3);
                    }
                };
                try floatPair(g, l, r, fail, Body.body, .{ op, dst }, done);
            } else if (op == .And or op == .Or or op == .Xor) {
                // Kotlin's `and`, `or` and `xor` on two Booleans.
                try m.cmpTagImm(.t0, tagOf(.Bool));
                try m.bCond(.ne, fail);
                try g.guard(r, .Bool, fail);
                try m.loadPayloadByte(.t0, l);
                try m.loadPayloadByte(.t1, r);
                try arith(g, op, .w32);
                try m.storePayloadByte(dst, .t2);
                try g.putTag(dst, .Bool, .t3);
                try m.jump(done);
            } else try m.jump(fail);
            m.endCold(sec);
        }

        fn fop(op: ir.BinOp) Masm.FOp {
            return switch (op) {
                .Add => .add,
                .Sub => .sub,
                .Mul => .mul,
                .Div => .div,
                else => unreachable,
            };
        }

        /// `t2` = `t0 op t1`; shift counts masked as Kotlin masks them.
        fn arith(g: *Gen, op: ir.BinOp, w: masm.Wd) !void {
            const m = &g.m;
            switch (op) {
                .Add => try m.add(w, .t2, .t0, .t1),
                .Sub => try m.sub(w, .t2, .t0, .t1),
                .Mul => try m.mul(w, .t2, .t0, .t1),
                .And => try m.andR(w, .t2, .t0, .t1),
                .Or => try m.orR(w, .t2, .t0, .t1),
                .Xor => try m.xorR(w, .t2, .t0, .t1),
                .Shl => try m.shl(w, .t2, .t0, .t1),
                .Shr => try m.sar(w, .t2, .t0, .t1),
                .UShr => try m.shr(w, .t2, .t0, .t1),
                else => unreachable,
            }
        }

        fn unary(g: *Gen, op: Op, w: masm.Wd, dst: u32, src: u32) !void {
            const m = &g.m;
            try m.loadPayload(w, .t0, src);
            switch (op) {
                .un_inc => try m.addImm(w, .t2, .t0, 1),
                .un_dec => try m.subImm(w, .t2, .t0, 1),
                .un_neg => try m.neg(w, .t2, .t0),
                else => unreachable,
            }
            try m.storePayload(w, dst, .t2);
        }

        /// The operator of a `bin_k` or `cmp_br_k` op.
        fn kOp(op: Op) ir.BinOp {
            return switch (op) {
                .bin_k_add => .Add,
                .bin_k_sub => .Sub,
                .bin_k_mul => .Mul,
                .bin_k_div => .Div,
                .bin_k_mod => .Mod,
                .bin_k_less, .cmp_br_k_less => .Less,
                .bin_k_less_eq, .cmp_br_k_less_eq => .LessEq,
                .bin_k_greater, .cmp_br_k_greater => .Greater,
                .bin_k_greater_eq, .cmp_br_k_greater_eq => .GreaterEq,
                .bin_k_eq, .cmp_br_k_eq => .Eq,
                .bin_k_not_eq, .cmp_br_k_not_eq => .NotEq,
                .bin_k_boxed_eq, .cmp_br_k_boxed_eq => .BoxedEq,
                .bin_k_boxed_not_eq, .cmp_br_k_boxed_not_eq => .BoxedNotEq,
                .bin_k_and => .And,
                .bin_k_or => .Or,
                .bin_k_xor => .Xor,
                .bin_k_shl => .Shl,
                .bin_k_shr => .Shr,
                .bin_k_ushr => .UShr,
                .bin_k_ident_eq, .cmp_br_k_ident_eq => .IdentEq,
                .bin_k_ident_neq, .cmp_br_k_ident_neq => .IdentNeq,
                else => unreachable,
            };
        }

        fn isIdent(op: ir.BinOp) bool {
            return op == .IdentEq or op == .IdentNeq;
        }

        /// `t2` = 1 when the op at `pc`'s register compares to its constant as `op` does, for
        /// an Int, a Long, or null against any register but a cell; false when this
        /// constant's type does not compile.
        fn compareK(g: *Gen, pc: usize, op: ir.BinOp, fail: Masm.Label) !bool {
            const m = &g.m;
            const kw = g.code(pc, 1);
            const x = g.code(pc, 2);
            const lo = g.code(pc, 4);
            const hi = g.code(pc, 5);
            switch (@as(bc.KType, @enumFromInt((kw >> 8) & 0xff))) {
                .int, .long => |k| {
                    const c = condOf(bc.orderMask(op)) orelse return false;
                    const w: masm.Wd = if (k == .int) .w32 else .w64;
                    try g.guard(x, if (k == .int) .Int else .Long, fail);
                    try m.loadPayload(w, .t0, x);
                    try m.movImm(.t1, if (k == .int) lo else (@as(u64, hi) << 32 | lo));
                    try m.cmp(w, .t0, .t1);
                    try m.setCond(.t2, c);
                },
                .float, .double => |k| {
                    if (!floatCompare(op)) return false;
                    const c = condOf(bc.orderMask(op)) orelse return false;
                    const dbl = k == .double;
                    try g.guard(x, if (dbl) .Double else .Float, fail);
                    try m.loadF(dbl, .f0, x);
                    try m.movF(dbl, .f1, if (dbl) (@as(u64, hi) << 32 | lo) else lo);
                    try m.fcmpSet(dbl, .t2, .f0, .f1, c);
                },
                .null => {
                    const is_eq = switch (op) {
                        .Eq, .BoxedEq, .IdentEq => true,
                        .NotEq, .BoxedNotEq, .IdentNeq => false,
                        else => return false,
                    };
                    try m.loadTag(.t0, x, tag_off);
                    try m.cmpTagImm(.t0, tagOf(.Cell));
                    try m.bCond(.eq, fail);
                    try m.cmpTagImm(.t0, tagOf(.Null));
                    try m.setCond(.t2, if (is_eq) .eq else .ne);
                },
                else => return false,
            }
            return true;
        }

        /// Register `dst` = the op at `pc`'s Int or Long register `op` its constant of the same
        /// type; false when this constant's type or operator does not compile.
        fn arithK(g: *Gen, pc: usize, op: ir.BinOp, dst: u32, fail: Masm.Label) !bool {
            const m = &g.m;
            const kw = g.code(pc, 1);
            const x = g.code(pc, 2);
            const lo = g.code(pc, 4);
            const hi = g.code(pc, 5);
            const k: bc.KType = @enumFromInt((kw >> 8) & 0xff);
            if (k == .float or k == .double) {
                switch (op) {
                    .Add, .Sub, .Mul, .Div => {},
                    else => return false,
                }
                const dbl = k == .double;
                try g.guard(x, if (dbl) .Double else .Float, fail);
                try m.loadF(dbl, .f0, x);
                try m.movF(dbl, .f1, if (dbl) (@as(u64, hi) << 32 | lo) else lo);
                try m.fop(fop(op), dbl, .f0, .f0, .f1);
                try m.storeF(dbl, dst, .f0);
                try g.putTag(dst, if (dbl) .Double else .Float, .t3);
                return true;
            }
            if (k != .int and k != .long) return false;
            const kv: u64 = if (k == .int) lo else (@as(u64, hi) << 32 | lo);
            const minus_one = if (k == .int) lo == 0xffff_ffff else kv == std.math.maxInt(u64);
            switch (op) {
                .Add, .Sub, .Mul, .And, .Or, .Xor, .Shl, .Shr, .UShr => {},
                // A divisor of 0 throws, in the handler.
                .Div, .Mod => if (kv == 0) return false,
                else => return false,
            }
            const w: masm.Wd = if (k == .int) .w32 else .w64;
            try g.guard(x, if (k == .int) .Int else .Long, fail);
            try m.loadPayload(w, .t0, x);
            try m.movImm(.t1, kv);
            if (op == .Div or op == .Mod) {
                // By -1 the quotient is the negation, wrapping as Kotlin's does, and the
                // remainder 0: no division, which would trap on x86-64 at the minimum.
                if (minus_one) {
                    if (op == .Div) try m.neg(w, .t2, .t0) else try m.movImm(.t2, 0);
                } else try m.divRem(w, op == .Mod, .t2, .t0, .t1);
            } else try arith(g, op, w);
            try m.storePayload(w, dst, .t2);
            try g.putTag(dst, if (k == .int) .Int else .Long, .t3);
            return true;
        }

        /// Register `dst` = slot `slot` of the instance in register `obj`, as `loadSlot`
        /// reads it: one load of both words where its slots are plain, else between two
        /// equal even readings of its store sequence.
        fn getField(g: *Gen, dst: u32, obj: u32, slot: u32, fail: Masm.Label) !void {
            const m = &g.m;
            try g.guard(obj, .Instance, fail);
            try m.loadPayload(.w64, .t0, obj);
            if (!try g.knowsSlot(obj, slot)) {
                try m.loadAt(.w64, .t1, .t0, inst_slots + 8);
                try m.movImm(.t2, slot);
                try m.cmp(.w64, .t1, .t2);
                try m.bCond(.le, fail);
            }
            if (comptime runtime.plain_slots) if (try g.knowsPlain(obj)) {
                try m.loadAt(.w64, .t1, .t0, inst_slots);
                try m.loadPair(.t3, .t1, .t1, slot * 16);
                try m.storeRegWord(dst, 0, .t3);
                try m.storeRegWord(dst, 1, .t1);
                return;
            };
            if (comptime runtime.plain_slots) {
                const ordered = try m.label();
                const done = try m.label();
                try m.loadAt(.w32, .t2, .t0, inst_seq);
                try m.bBitClear(.t2, 31, ordered);
                try m.loadAt(.w64, .t1, .t0, inst_slots);
                try m.loadPair(.t3, .t1, .t1, slot * 16);
                try m.storeRegWord(dst, 0, .t3);
                try m.storeRegWord(dst, 1, .t1);
                const sec = try m.cold();
                m.bind(ordered);
                try getOrdered(g, dst, slot, fail);
                try m.jump(done);
                m.endCold(sec);
                m.bind(done);
            } else try getOrdered(g, dst, slot, fail);
        }

        /// Register `dst` = slot `slot` of the instance data in `t0`, read between two
        /// equal even readings of its store sequence.
        fn getOrdered(g: *Gen, dst: u32, slot: u32, fail: Masm.Label) !void {
            const m = &g.m;
            try m.loadAcquire(.w32, .t2, .t0, inst_seq);
            try m.bBit(.t2, 0, fail);
            try m.loadAt(.w64, .t1, .t0, inst_slots);
            try m.movImm(.t3, slot * 16);
            try m.add(.w64, .t1, .t1, .t3);
            try m.loadAcquire(.w64, .t3, .t1, 0);
            try m.loadAcquire(.w64, .t1, .t1, 8);
            try m.loadAt(.w32, .t0, .t0, inst_seq);
            try m.cmp(.w32, .t0, .t2);
            try m.bCond(.ne, fail);
            try m.storeRegWord(dst, 0, .t3);
            try m.storeRegWord(dst, 1, .t1);
        }

        /// Register `dst` = element `idx` of the IntArray, LongArray or DoubleArray in register
        /// `arr`, read in place as `fastIndexGet` reads it; any other array, a negative index
        /// or one past the end goes to `fail`.
        fn arrayGet(g: *Gen, dst: u32, arr: u32, idx: u32, fail: Masm.Label) !void {
            const m = &g.m;
            const Kind = struct { bits: u8, shift: u6, w: masm.Wd, tag: Tag };
            const kinds = [_]Kind{
                .{ .bits = @intFromEnum(runtime.PrimitiveArrayKind.Int) + 1, .shift = 2, .w = .w32, .tag = .Int },
                .{ .bits = @intFromEnum(runtime.PrimitiveArrayKind.Long) + 1, .shift = 3, .w = .w64, .tag = .Long },
                .{ .bits = @intFromEnum(runtime.PrimitiveArrayKind.Double) + 1, .shift = 3, .w = .w64, .tag = .Double },
            };
            const done = try m.label();
            try g.guard(arr, .Array, fail);
            try g.guard(idx, .Int, fail);
            try m.loadPayload(.w64, .t0, arr);
            try m.andImm(.w64, .t1, .t0, 0xF);
            try m.andImm(.w64, .t0, .t0, -16);
            try m.loadPayload(.w32, .t3, idx);
            try m.signExtend32(.t3, .t3);
            try m.bNegative(.t3, fail);
            // An IntArray's read in line; the other kinds out of the way.
            var sec: masm.Cold = undefined;
            for (kinds, 0..) |k, i| {
                const next_kind = try m.label();
                try m.cmpTagImm(.t1, k.bits);
                try m.bCond(.ne, next_kind);
                try m.shlImm(.w64, .t3, .t3, k.shift);
                try m.loadAt(.w64, .t2, .t0, prim_items + 8);
                try m.cmp(.w64, .t3, .t2);
                try m.bCond(.ge, fail);
                try m.loadAt(.w64, .t2, .t0, prim_items);
                try m.add(.w64, .t2, .t2, .t3);
                try m.loadAt(k.w, .t1, .t2, 0);
                try m.storePayload(k.w, dst, .t1);
                try g.putTag(dst, k.tag, .t3);
                if (i == 0) {
                    m.bind(done);
                    sec = try m.cold();
                } else try m.jump(done);
                m.bind(next_kind);
            }
            // An `Array<T>`.
            try m.cmpTagImm(.t1, 0);
            try m.bCond(.ne, fail);
            try boxedRead(g, dst, idx, fail);
            try m.jump(done);
            m.endCold(sec);
        }

        /// `t1` = the length of the `Array<T>`, `IntArray`, `LongArray` or `DoubleArray` in
        /// register `arr`, the kinds `arrayGet` reads; any other value goes to `fail`.
        fn arrayLen(g: *Gen, arr: u32, fail: Masm.Label) !void {
            const m = &g.m;
            const boxed = try m.label();
            const wide = try m.label();
            const done = try m.label();
            try g.guard(arr, .Array, fail);
            try m.loadPayload(.w64, .t0, arr);
            try m.andImm(.w64, .t1, .t0, 0xF);
            try m.andImm(.w64, .t0, .t0, -16);
            try m.cmpTagImm(.t1, 0);
            try m.bCond(.eq, boxed);
            try m.cmpTagImm(.t1, @intFromEnum(runtime.PrimitiveArrayKind.Long) + 1);
            try m.bCond(.eq, wide);
            try m.cmpTagImm(.t1, @intFromEnum(runtime.PrimitiveArrayKind.Double) + 1);
            try m.bCond(.eq, wide);
            try m.cmpTagImm(.t1, @intFromEnum(runtime.PrimitiveArrayKind.Int) + 1);
            try m.bCond(.ne, fail);
            try m.loadAt(.w64, .t1, .t0, prim_items + 8);
            try m.lsrImm(.w64, .t1, .t1, 2);
            try m.jump(done);
            m.bind(wide);
            try m.loadAt(.w64, .t1, .t0, prim_items + 8);
            try m.lsrImm(.w64, .t1, .t1, 3);
            try m.jump(done);
            m.bind(boxed);
            try m.loadAt(.w64, .t1, .t0, list_items + 8);
            m.bind(done);
        }

        /// Register `dst` = element `idx` (an Int register) of the `Array<T>` storage cell in
        /// `t0`, read with no lock as `ObjRef.readAt` reads it: between two equal even readings
        /// of the cell's write sequence. A writer holding the lock or taking it meanwhile, or an
        /// index out of range, goes to `fail`.
        fn boxedRead(g: *Gen, dst: u32, idx: u32, fail: Masm.Label) !void {
            const m = &g.m;
            try m.loadAcquire(.w32, .t2, .t0, list_seq);
            try m.bBit(.t2, 0, fail);
            try m.loadAt(.w64, .t1, .t0, list_items + 8);
            try m.loadPayload(.w32, .t3, idx);
            try m.signExtend32(.t3, .t3);
            try m.bNegative(.t3, fail);
            try m.cmp(.w64, .t3, .t1);
            try m.bCond(.ge, fail);
            try m.shlImm(.w64, .t3, .t3, 4);
            try m.loadAt(.w64, .t1, .t0, list_items);
            try m.add(.w64, .t1, .t1, .t3);
            try m.loadAt(.w64, .t3, .t1, 0);
            try m.loadAt(.w64, .t1, .t1, 8);
            try m.fenceLoads();
            try m.cmpAt(.w32, .t0, list_seq, .t2);
            try m.bCond(.ne, fail);
            try m.storeRegWord(dst, 0, .t3);
            try m.storeRegWord(dst, 1, .t1);
        }

        /// Register `dst` = element `idx` (an Int register) of the list storage cell in `t0`,
        /// read with no lock as `ObjRef.readAtMoving` reads it: the buffer and length between
        /// two equal even readings of the write sequence, the element before a third. A writer
        /// holding the lock or taking it meanwhile, or an index out of range, goes to `fail`.
        fn listRead(g: *Gen, dst: u32, idx: u32, fail: Masm.Label) !void {
            const m = &g.m;
            try m.loadAcquire(.w32, .t2, .t0, list_seq);
            try m.bBit(.t2, 0, fail);
            try m.loadAt(.w64, .t1, .t0, list_items + 8);
            try m.loadPayload(.w32, .t3, idx);
            try m.signExtend32(.t3, .t3);
            try m.bNegative(.t3, fail);
            try m.cmp(.w64, .t3, .t1);
            try m.bCond(.ge, fail);
            try m.shlImm(.w64, .t3, .t3, 4);
            try m.loadAt(.w64, .t1, .t0, list_items);
            try m.add(.w64, .t1, .t1, .t3);
            try m.fenceLoads();
            try m.cmpAt(.w32, .t0, list_seq, .t2);
            try m.bCond(.ne, fail);
            try m.loadAt(.w64, .t3, .t1, 0);
            try m.loadAt(.w64, .t1, .t1, 8);
            try m.fenceLoads();
            try m.cmpAt(.w32, .t0, list_seq, .t2);
            try m.bCond(.ne, fail);
            try m.storeRegWord(dst, 0, .t3);
            try m.storeRegWord(dst, 1, .t1);
        }

        /// Register `dst` = element `idx` (an Int register) of the `Array<T>` or list storage
        /// cell in `t0`, read under the cell's shared lock as `fastIndexGet` borrows it; a
        /// writer holding it, or an index out of range, gives it back and goes to `fail`.
        fn boxedGet(g: *Gen, dst: u32, idx: u32, fail: Masm.Label) !void {
            const m = &g.m;
            const unlock_fail = try m.label();
            try m.atomicAdd32(.t0, list_lock, 1, .t2);
            try m.cmpTagImm(.t2, 0);
            try m.bCond(.lt, unlock_fail);
            try m.loadAt(.w64, .t2, .t0, list_items + 8);
            try m.loadPayload(.w32, .t3, idx);
            try m.signExtend32(.t3, .t3);
            try m.bNegative(.t3, unlock_fail);
            try m.cmp(.w64, .t3, .t2);
            try m.bCond(.ge, unlock_fail);
            try m.shlImm(.w64, .t3, .t3, 4);
            try m.loadAt(.w64, .t2, .t0, list_items);
            try m.add(.w64, .t2, .t2, .t3);
            try m.loadAt(.w64, .t3, .t2, 0);
            try m.loadAt(.w64, .t1, .t2, 8);
            try m.storeRegWord(dst, 0, .t3);
            try m.storeRegWord(dst, 1, .t1);
            try m.atomicAdd32(.t0, list_lock, -1, .t2);
            const sec = try m.cold();
            m.bind(unlock_fail);
            try m.atomicAdd32(.t0, list_lock, -1, .t2);
            try m.jump(fail);
            m.endCold(sec);
        }

        /// Element `idx` of the array in register `arr` = register `val`, stored in place. An
        /// IntArray, LongArray or DoubleArray takes a value of its element type, stored whole
        /// without the array's lock: its buffer never moves, and reads take none
        /// (`fastIndexGet`). Any other array or value, a negative index or one past the end
        /// goes to `fail`.
        fn arraySet(g: *Gen, arr: u32, idx: u32, val: u32, fail: Masm.Label) !void {
            const m = &g.m;
            const Kind = struct { bits: u8, shift: u6, w: masm.Wd, tag: Tag };
            const kinds = [_]Kind{
                .{ .bits = @intFromEnum(runtime.PrimitiveArrayKind.Int) + 1, .shift = 2, .w = .w32, .tag = .Int },
                .{ .bits = @intFromEnum(runtime.PrimitiveArrayKind.Long) + 1, .shift = 3, .w = .w64, .tag = .Long },
                .{ .bits = @intFromEnum(runtime.PrimitiveArrayKind.Double) + 1, .shift = 3, .w = .w64, .tag = .Double },
            };
            const done = try m.label();
            try g.guard(arr, .Array, fail);
            try g.guard(idx, .Int, fail);
            try m.loadPayload(.w64, .t0, arr);
            try m.andImm(.w64, .t1, .t0, 0xF);
            try m.andImm(.w64, .t0, .t0, -16);
            var sec: masm.Cold = undefined;
            for (kinds, 0..) |k, i| {
                const next_kind = try m.label();
                try m.cmpTagImm(.t1, k.bits);
                try m.bCond(.ne, next_kind);
                try g.guard(val, k.tag, fail);
                try m.loadPayload(.w32, .t3, idx);
                try m.signExtend32(.t3, .t3);
                try m.bNegative(.t3, fail);
                try m.shlImm(.w64, .t3, .t3, k.shift);
                try m.loadAt(.w64, .t2, .t0, prim_items + 8);
                try m.cmp(.w64, .t3, .t2);
                try m.bCond(.ge, fail);
                try m.loadAt(.w64, .t2, .t0, prim_items);
                try m.add(.w64, .t2, .t2, .t3);
                try m.loadPayload(k.w, .t3, val);
                try m.storeAt(k.w, .t2, 0, .t3);
                if (i == 0) {
                    m.bind(done);
                    sec = try m.cold();
                } else try m.jump(done);
                m.bind(next_kind);
            }
            // An `Array<T>`: its element stored under the array's exclusive lock, as
            // `fastIndexSet` borrows it, where the write barrier has nothing to record (a
            // young array, or an old one already remembered); a lock held, a barrier to
            // record or an index out of range fails.
            try m.cmpTagImm(.t1, 0);
            try m.bCond(.ne, fail);
            try m.andImm(.w64, .t1, .t0, -16);
            try boxedSet(g, idx, val, null, fail);
            try m.jump(done);
            m.endCold(sec);
        }

        /// Element `idx` (an Int register) of the `Array<T>` or list storage cell in `t1` =
        /// register `val`, stored under the cell's exclusive lock as `borrowMutAt` takes it,
        /// where the write barrier has nothing to record (a young cell, or an old one already
        /// remembered); register `old`, when there is one, = the element it replaces. A lock
        /// held, a barrier to record or an index out of range goes to `fail`, storing nothing.
        fn boxedSet(g: *Gen, idx: u32, val: u32, old: ?u32, fail: Masm.Label) !void {
            const m = &g.m;
            const unlock_fail = try m.label();
            try m.movImm(.t0, 0);
            try m.movImm(.t2, 0x8000_0000);
            try m.cas32(.t1, list_lock, .t0, .t2, fail);
            try m.loadPayload(.w32, .t3, idx);
            try m.signExtend32(.t3, .t3);
            try m.bNegative(.t3, unlock_fail);
            try m.loadAt(.w64, .t2, .t1, list_items + 8);
            try m.cmp(.w64, .t3, .t2);
            try m.bCond(.ge, unlock_fail);
            const barrier_done = try m.label();
            try m.loadByteAt(.t0, .t1, list_gen);
            try m.bZero(.t0, barrier_done);
            try m.loadByteAt(.t0, .t1, list_remembered);
            try m.bZero(.t0, unlock_fail);
            m.bind(barrier_done);
            // The write sequence odd before the element's stores can be seen, and even
            // after them, as `SeqRwLock` turns it.
            try m.loadAt(.w32, .t0, .t1, list_seq);
            try m.addImm(.w32, .t0, .t0, 1);
            try m.storeAt(.w32, .t1, list_seq, .t0);
            try m.fenceStores();
            try m.shlImm(.w64, .t3, .t3, 4);
            try m.loadAt(.w64, .t2, .t1, list_items);
            try m.add(.w64, .t2, .t2, .t3);
            if (old) |o| {
                try m.loadAt(.w64, .t0, .t2, 0);
                try m.storeRegWord(o, 0, .t0);
                try m.loadAt(.w64, .t0, .t2, 8);
                try m.storeRegWord(o, 1, .t0);
            }
            try m.loadRegWord(.t0, val, 0);
            try m.storeAt(.w64, .t2, 0, .t0);
            try m.loadRegWord(.t0, val, 1);
            try m.storeAt(.w64, .t2, 8, .t0);
            try m.loadAt(.w32, .t0, .t1, list_seq);
            try m.addImm(.w32, .t0, .t0, 1);
            try m.storeRelease(.w32, .t1, list_seq, .t0);
            try m.atomicAnd32(.t1, list_lock, 0x7fff_ffff);
            const sec = try m.cold();
            m.bind(unlock_fail);
            try m.atomicAnd32(.t1, list_lock, 0x7fff_ffff);
            try m.jump(fail);
            m.endCold(sec);
        }

        /// Register `dst` = static `static` once its init unit `unit` has run, read from the
        /// run's state between two equal even readings of its store sequence, as
        /// `readyStatic` reads it; anything else goes to `fail`.
        fn loadStatic(g: *Gen, dst: u32, static: u32, unit: u32, fail: Masm.Label) !void {
            const m = &g.m;
            try m.loadCtx(.t0, ctx_host);
            try m.loadByteAt(.t1, .t0, host_state + 8);
            try m.bZero(.t1, fail);
            try m.loadAt(.w64, .t1, .t0, host_state);
            if (unit != ir.resolved.NONE) {
                try m.loadAt(.w64, .t2, .t1, st_unit_state);
                try m.movImm(.t3, unit);
                try m.add(.w64, .t2, .t2, .t3);
                try m.loadAcquireByte(.t3, .t2);
                try m.movImm(.t2, @intFromEnum(ir.resolved.UnitState.done));
                try m.cmp(.w32, .t3, .t2);
                try m.bCond(.ne, fail);
            }
            try m.loadAcquire(.w32, .t2, .t1, st_static_seq);
            try m.bBit(.t2, 0, fail);
            try m.loadAt(.w64, .t0, .t1, st_statics);
            try m.movImm(.t3, static * 16);
            try m.add(.w64, .t0, .t0, .t3);
            try m.loadAcquire(.w64, .t3, .t0, 0);
            try m.loadAcquire(.w64, .t0, .t0, 8);
            try m.loadAt(.w32, .t1, .t1, st_static_seq);
            try m.cmp(.w32, .t1, .t2);
            try m.bCond(.ne, fail);
            try m.storeRegWord(dst, 0, .t3);
            try m.storeRegWord(dst, 1, .t0);
        }

        /// Register `dst` = the singleton of object `class` once it is built, read from the
        /// run's state as `builtObject` reads it; anything else goes to `fail`.
        fn loadObject(g: *Gen, dst: u32, class: u32, fail: Masm.Label) !void {
            const m = &g.m;
            try m.loadCtx(.t0, ctx_host);
            try m.loadByteAt(.t1, .t0, host_state + 8);
            try m.bZero(.t1, fail);
            try m.loadAt(.w64, .t1, .t0, host_state);
            try m.loadAt(.w64, .t2, .t1, st_object_state);
            try m.movImm(.t3, class);
            try m.add(.w64, .t2, .t2, .t3);
            try m.loadAcquireByte(.t3, .t2);
            try m.movImm(.t2, @intFromEnum(ir.resolved.UnitState.done));
            try m.cmp(.w32, .t3, .t2);
            try m.bCond(.ne, fail);
            try m.loadAt(.w64, .t2, .t1, st_singletons);
            try m.movImm(.t3, class * @sizeOf(?Value));
            try m.add(.w64, .t2, .t2, .t3);
            try m.loadAt(.w64, .t0, .t2, 0);
            try m.loadAt(.w64, .t1, .t2, 8);
            try m.storeRegWord(dst, 0, .t0);
            try m.storeRegWord(dst, 1, .t1);
        }

        /// `is` and `cast` over a null, which its flags answer, or an instance, answered by
        /// a cache of the last class the op tested (`isFill`); anything else, a class the
        /// cache does not hold and a failing `as` go to the handler.
        fn isOrCast(g: *Gen, op: Op, pc: usize, blk: u32) !void {
            const m = &g.m;
            const dst = g.code(pc, 2);
            const src = g.code(pc, 3);
            const flags = g.code(pc, 5);
            const nullable = flags & 1 != 0;
            const safe = op == .cast and flags & 2 != 0;
            // Empty: no class id is this one, and one no class in the tables has
            // (`maxInt`) never matches it.
            const cache = try g.keep.create(u64);
            cache.* = std.math.maxInt(u32) - 1;
            const fail = try g.slowFill(op, pc, blk, cache);
            const is_null = try m.label();
            const done = try m.label();
            try m.loadTag(.t0, src, tag_off);
            try m.cmpTagImm(.t0, tagOf(.Null));
            try m.bCond(.eq, is_null);
            try m.cmpTagImm(.t0, tagOf(.Instance));
            try m.bCond(.ne, fail);
            try m.loadPayload(.w64, .t1, src);
            try m.loadAt(.w32, .t1, .t1, inst_class);
            try m.movImm(.t2, @intFromPtr(cache));
            try m.loadAcquire(.w64, .t2, .t2, 0);
            try m.cmp(.w32, .t1, .t2);
            try m.bCond(.ne, fail);
            try m.lsrImm(.w64, .t2, .t2, 32);
            // An instance the cache answers in line; a null and a failing `as?` out of the way.
            const no = try m.label();
            if (op == .is) {
                try g.putBool(dst, .t2);
            } else {
                try m.bZero(.t2, no);
                try m.copyValue(dst, src);
            }
            m.bind(done);
            const sec = try m.cold();
            if (op == .cast) {
                m.bind(no);
                if (!safe) try m.jump(fail) else {
                    try m.storeValue(dst, bytesOf(.Null));
                    try m.jump(done);
                }
            }
            m.bind(is_null);
            if (op == .is) {
                try m.movImm(.t2, @intFromBool(nullable));
                try g.putBool(dst, .t2);
                try m.jump(done);
            } else if (nullable or safe) {
                try m.storeValue(dst, bytesOf(.Null));
                try m.jump(done);
            } else try m.jump(fail);
            m.endCold(sec);
        }

        /// Slot `slot` of the instance in register `obj` = register `val`, as `storeSlot`
        /// stores it: the barrier, which only a store the collector must see into a cell it
        /// has not remembered leaves to the handler, then, where the slots are plain, both
        /// words in one store, after a fence when the value is a reference; else the store
        /// turn taken, both words released, and the turn given back.
        fn setField(g: *Gen, obj: u32, slot: u32, val: u32, fail: Masm.Label) !void {
            const m = &g.m;
            try g.guard(obj, .Instance, fail);
            try m.loadPayload(.w64, .t1, obj);
            if (!try g.knowsSlot(obj, slot)) {
                try m.loadAt(.w64, .t2, .t1, inst_slots + 8);
                try m.movImm(.t3, slot);
                try m.cmp(.w64, .t2, .t3);
                try m.bCond(.le, fail);
            }
            // A value that is no reference takes no barrier and needs no fence before it.
            if (comptime runtime.plain_slots) if (try g.knowsPlain(obj)) if (g.kindOf(val)) |vt| if (@intFromEnum(vt) <= tagOf(.Bool)) {
                _ = try g.knows(val, vt);
                try m.loadAt(.w64, .t2, .t1, inst_slots);
                try m.loadRegWord(.t3, val, 0);
                try m.loadRegWord(.t0, val, 1);
                try m.storePair(.t2, slot * 16, .t3, .t0);
                return;
            };
            // A young instance takes no barrier, in line; an old one's checks out of the way.
            const stored = try m.label();
            const old = try m.label();
            try m.loadByteAt(.t2, .t1, inst_gen);
            try m.bNonZero(.t2, old);
            m.bind(stored);
            const done = try m.label();
            const ordered = try m.label();
            if (comptime runtime.plain_slots) {
                const bare = try m.label();
                try m.loadAt(.w32, .t0, .t1, inst_seq);
                try m.bBitClear(.t0, 31, ordered);
                try m.loadAt(.w64, .t2, .t1, inst_slots);
                try m.loadTag(.t3, val, tag_off);
                try m.cmpTagImm(.t3, tagOf(.Bool));
                try m.bCond(.le, bare);
                try m.fenceStores();
                m.bind(bare);
                try m.loadRegWord(.t3, val, 0);
                try m.loadRegWord(.t0, val, 1);
                try m.storePair(.t2, slot * 16, .t3, .t0);
            } else try setOrdered(g, slot, val, fail);
            m.bind(done);
            const sec = try m.cold();
            if (comptime runtime.plain_slots) {
                m.bind(ordered);
                try setOrdered(g, slot, val, fail);
                try m.jump(done);
            }
            m.bind(old);
            try m.loadTag(.t2, val, tag_off);
            try m.cmpTagImm(.t2, tagOf(.Bool));
            try m.bCond(.le, stored);
            try m.loadByteAt(.t2, .t1, inst_remembered);
            try m.bZero(.t2, fail);
            try m.jump(stored);
            m.endCold(sec);
        }

        /// Slot `slot` of the instance data in `t1` = register `val`: the store turn taken,
        /// both words released, and the turn given back.
        fn setOrdered(g: *Gen, slot: u32, val: u32, fail: Masm.Label) !void {
            const m = &g.m;
            try m.loadAt(.w32, .t0, .t1, inst_seq);
            try m.bBit(.t0, 0, fail);
            try m.addImm(.w32, .t2, .t0, 1);
            try m.cas32(.t1, inst_seq, .t0, .t2, fail);
            try m.loadAt(.w64, .t2, .t1, inst_slots);
            try m.movImm(.t3, slot * 16);
            try m.add(.w64, .t2, .t2, .t3);
            try m.loadRegWord(.t3, val, 0);
            try m.storeRelease(.w64, .t2, 0, .t3);
            try m.loadRegWord(.t3, val, 1);
            try m.storeRelease(.w64, .t2, 8, .t3);
            // The next even sequence, wrapping below the plain flag.
            try m.addImm(.w32, .t0, .t0, 2);
            try m.andImm(.w32, .t0, .t0, 0x7fff_ffff);
            try m.storeRelease(.w32, .t1, inst_seq, .t0);
        }

        // ------------------------------------------------------------ inlining --

        /// A callee compiled into its caller at one of the call's receiver classes (any, for
        /// a static call).
        const Target = struct {
            class: u32,
            sc: *const bc.FuncStreams = undefined,
            an: *const Analysis = undefined,
            /// A host function compiled as its instructions, in place of the callee's code.
            host: Intrinsic = .none,
            /// A `callv`'s lambda, which runs when the callee is a closure over its record.
            lambda: ?*const bc.LambdaSite = null,
        };

        const Intrinsic = intrinsics.Intrinsic;
        /// What host function `nid` compiles to: an intrinsic compiled code compiles as its
        /// instructions, else none.
        fn intrinsicOf(module: *const ir.Module, nid: ir.NativeId) Intrinsic {
            const k = intrinsics.of(module, nid);
            return if (k.compiled() or k.called()) k else .none;
        }

        /// Whether the tables bind function `fid` to a host function, whose call caches no callee.
        fn hostFunction(module: *const ir.Module, fid: u32) bool {
            const r = module.resolved orelse return false;
            return fid < r.func_native.len and r.func_native[fid] != .none;
        }

        /// The host function a static call of `fid` runs as it is (`nativeOf`), as an intrinsic.
        fn staticIntrinsic(module: *const ir.Module, fid: u32) Intrinsic {
            const r = module.resolved orelse return .none;
            if (fid >= r.func_native.len or r.func_native[fid] == .none) return .none;
            if (fid < r.func_try.len and r.func_try[fid] != .none) return .none;
            return intrinsicOf(module, r.func_native[fid]);
        }

        /// `t0` = the storage cell of the list in register `recv`, a list that is no view of
        /// another collection (`recvListItems` then reads its items as they are); anything
        /// else goes to `fail`.
        fn listItems(g: *Gen, recv: u32, fail: Masm.Label) !void {
            const m = &g.m;
            try listData(g, recv, fail);
            try m.loadAt(.w64, .t0, .t0, list_data_items);
        }

        /// `t0` = the data of the list in register `recv`, a list that is no view.
        fn listData(g: *Gen, recv: u32, fail: Masm.Label) !void {
            const m = &g.m;
            try g.guard(recv, .List, fail);
            try m.loadPayload(.w64, .t0, recv);
            try m.loadAt(.w64, .t1, .t0, list_data_backing);
            try m.bNonZero(.t1, fail);
        }

        /// The tag of the values a call site keeps host functions under `class` for, when it
        /// is the class of every value with the tag (a list's, a map's, a builder's).
        fn hostTag(module: *const ir.Module, class: u32) ?Tag {
            const r = module.resolved orelse return null;
            for (r.host_class.by_tag, 0..) |c, i| {
                if (c) |cls| if (cls.int() == class) return @enumFromInt(i);
            }
            return null;
        }

        /// Register `dst` = rotation or count of one bits `k` of the `w`-wide integer in register
        /// `recv`: a rotation by the Int in the next register, its count taken modulo the width
        /// as Kotlin's shifts take theirs, so rotating left by `n` is `x shl n or x ushr -n`.
        fn bitOp(g: *Gen, k: Intrinsic, w: masm.Wd, recv: u32, dst: u32, fail: Masm.Label) !void {
            const m = &g.m;
            const long = w == .w64;
            try m.loadPayload(w, .t0, recv);
            if (k == .count_one_bits) {
                const ones: u64 = if (long) 0xffff_ffff_ffff_ffff else 0xffff_ffff;
                try m.lsrImm(w, .t1, .t0, 1);
                try m.movImm(.t3, 0x5555_5555_5555_5555 & ones);
                try m.andR(w, .t1, .t1, .t3);
                try m.sub(w, .t0, .t0, .t1);
                try m.movImm(.t3, 0x3333_3333_3333_3333 & ones);
                try m.andR(w, .t1, .t0, .t3);
                try m.lsrImm(w, .t0, .t0, 2);
                try m.andR(w, .t0, .t0, .t3);
                try m.add(w, .t0, .t0, .t1);
                try m.lsrImm(w, .t1, .t0, 4);
                try m.add(w, .t0, .t0, .t1);
                try m.movImm(.t3, 0x0f0f_0f0f_0f0f_0f0f & ones);
                try m.andR(w, .t0, .t0, .t3);
                try m.movImm(.t3, 0x0101_0101_0101_0101 & ones);
                try m.mul(w, .t0, .t0, .t3);
                try m.lsrImm(w, .t2, .t0, if (long) 56 else 24);
                try m.storePayload(.w32, dst, .t2);
                try g.putTag(dst, .Int, .t3);
                return;
            }
            try g.guard(recv + 1, .Int, fail);
            try m.loadPayload(.w32, .t1, recv + 1);
            if (k == .rotate_left) try m.shl(w, .t2, .t0, .t1) else try m.shr(w, .t2, .t0, .t1);
            try m.neg(.w32, .t1, .t1);
            if (k == .rotate_left) try m.shr(w, .t3, .t0, .t1) else try m.shl(w, .t3, .t0, .t1);
            try m.orR(w, .t2, .t2, .t3);
            try m.storePayload(w, dst, .t2);
            try g.putTag(dst, if (long) .Long else .Int, .t3);
        }

        /// The call's result register = what intrinsic `k` answers for the receiver in its first
        /// argument register; a receiver it does not take goes to `fail`.
        fn intrinsic(g: *Gen, k: Intrinsic, pc: usize, fail: Masm.Label) !void {
            const m = &g.m;
            const recv = g.code(pc, 3);
            const dst = g.code(pc, 5);
            if (k.called()) {
                try m.callHost(S.intrinsicEntry(k), @intFromPtr(g.module), recv, dst);
                try m.bZero(.t0, fail);
                return;
            }
            switch (k) {
                .none, .map_get, .map_put, .map_set, .map_size, .list_add, .sb_append, .sb_length, .iter_has_next, .iter_next, .entry_key, .entry_value => unreachable,
                .any_hash => {
                    try g.guard(recv, .Instance, fail);
                    try m.loadPayload(.w64, .t1, recv);
                    try m.takeIdentity(.t1, inst_identity, .t2, @intFromPtr(runtime.InstanceData.identityCounter()));
                },
                .long_hash => {
                    try g.guard(recv, .Long, fail);
                    try m.loadPayload(.w64, .t0, recv);
                    try m.lsrImm(.w64, .t1, .t0, 32);
                    try m.xorR(.w64, .t2, .t0, .t1);
                },
                .array_size => |bits| {
                    try g.guard(recv, .Array, fail);
                    try m.loadPayload(.w64, .t0, recv);
                    try m.andImm(.w64, .t1, .t0, 0xF);
                    try m.cmpTagImm(.t1, bits);
                    try m.bCond(.ne, fail);
                    try m.andImm(.w64, .t0, .t0, -16);
                    if (bits == 0) {
                        try m.loadAt(.w64, .t2, .t0, list_items + 8);
                    } else {
                        const kind: runtime.PrimitiveArrayKind = @enumFromInt(bits - 1);
                        try m.loadAt(.w64, .t2, .t0, prim_items + 8);
                        try m.lsrImm(.w64, .t2, .t2, std.math.log2_int(usize, kind.elemSize()));
                    }
                },
                .list_size => {
                    try listItems(g, recv, fail);
                    try m.loadAt(.w64, .t2, .t0, list_items + 8);
                },
                .list_get => {
                    try listItems(g, recv, fail);
                    try g.guard(recv + 1, .Int, fail);
                    if (runtime.lockfreeReads() and !S.reclaims) try listRead(g, dst, recv + 1, fail) else try boxedGet(g, dst, recv + 1, fail);
                    return;
                },
                .list_set => {
                    // `readOnlyMutationGuard`: a list made read-only, or frozen, throws.
                    try listData(g, recv, fail);
                    try m.loadByteAt(.t1, .t0, list_data_mutable);
                    try m.bZero(.t1, fail);
                    const counted = try m.label();
                    try m.loadAt(.w64, .t1, .t0, list_data_mod_count);
                    try m.bZero64(.t1, counted);
                    try m.loadAt(.w64, .t1, .t1, mod_count_value);
                    try m.bNegative(.t1, fail);
                    m.bind(counted);
                    try m.loadAt(.w64, .t1, .t0, list_data_items);
                    try g.guard(recv + 1, .Int, fail);
                    try boxedSet(g, recv + 1, recv + 2, dst, fail);
                    return;
                },
                .rotate_left, .rotate_right, .count_one_bits => {
                    // An Int's in line, a Long's out of the way; any other receiver fails.
                    const long = try m.label();
                    const done = try m.label();
                    try m.loadTag(.t0, recv, tag_off);
                    try m.cmpTagImm(.t0, tagOf(.Int));
                    try m.bCond(.ne, long);
                    try bitOp(g, k, .w32, recv, dst, fail);
                    m.bind(done);
                    const sec = try m.cold();
                    m.bind(long);
                    try m.cmpTagImm(.t0, tagOf(.Long));
                    try m.bCond(.ne, fail);
                    try bitOp(g, k, .w64, recv, dst, fail);
                    try m.jump(done);
                    m.endCold(sec);
                    return;
                },
            }
            try m.storePayload(.w32, dst, .t2);
            try g.putTag(dst, .Int, .t3);
        }

        /// How a call compiles: the callees it runs in place, tried in order; any other
        /// receiver runs the call.
        const Plan = struct {
            targets: [2]Target = undefined,
            n: u32 = 0,
            /// Code words of the callees, theirs included.
            words: u32 = 0,
        };

        /// Where each op of a callee compiled into its caller runs and what it finds there.
        const Analysis = struct {
            /// Per code word: an op the callee's code reaches from its entry.
            reach: []bool,
            /// Per code word: an op compiled in place (else it leaves the code).
            native: []bool,
            /// Per block: the registers written on every path to its entry.
            d_in: []std.DynamicBitSetUnmanaged,
            /// Registers some path to an op may have written and another not: the
            /// callee's entry writes `Unit` to them, so every exit knows what it has.
            prefill: std.DynamicBitSetUnmanaged,
            /// The calls it compiles in place, by pc.
            plans: std.AutoHashMapUnmanaged(u32, Plan) = .empty,
            words: u32,
        };

        /// Whether `op` at `pc` compiles in place (`compileOp` agrees; a call is decided by its
        /// plan).
        fn canNative(fs: *const bc.FuncStreams, op: Op, pc: usize) bool {
            const code = fs.code;
            return switch (op) {
                .const_int, .const_val, .move, .load_param, .load_params, .jump, .br, .not, .not_null, .un_inc, .un_dec, .un_neg, .conv_long, .conv_int, .get_field, .set_field, .unbox_value, .box_value, .add, .sub, .ret => true,
                .cmp, .cmp_br => condOf(code[pc + 2] >> 8) != null or isIdent(@enumFromInt(code[pc + 2] & 0xff)),
                .bin_ident_eq, .bin_ident_neq, .fn_inv, .fn_to_ulong, .fn_to_uint, .fn_unsigned_bits, .fn_float_from_bits, .fn_double_from_bits, .fn_to_raw_bits, .const_str, .is, .cast, .array_get, .array_set, .iter_has, .iter_get => true,
                .load_static => objects_native,
                .load_object => objects_native,
                .bin, .bin_mul, .bin_div, .bin_and, .bin_or, .bin_xor, .bin_shl, .bin_shr, .bin_ushr => blk: {
                    const bop: ir.BinOp = @enumFromInt(code[pc + 2] & 0xff);
                    break :blk arithKind(bop) != .none or condOf(bc.orderMask(bop)) != null;
                },
                .bin_k_add, .bin_k_sub, .bin_k_mul, .bin_k_div, .bin_k_mod, .bin_k_and, .bin_k_or, .bin_k_xor, .bin_k_shl, .bin_k_shr, .bin_k_ushr, .bin_k_less, .bin_k_less_eq, .bin_k_greater, .bin_k_greater_eq, .bin_k_eq, .bin_k_not_eq, .bin_k_boxed_eq, .bin_k_boxed_not_eq, .bin_k_ident_eq, .bin_k_ident_neq, .cmp_br_k_less, .cmp_br_k_less_eq, .cmp_br_k_greater, .cmp_br_k_greater_eq, .cmp_br_k_eq, .cmp_br_k_not_eq, .cmp_br_k_boxed_eq, .cmp_br_k_boxed_not_eq, .cmp_br_k_ident_eq, .cmp_br_k_ident_neq => kNative(op, code[pc + 1], @as(u64, code[pc + 5]) << 32 | code[pc + 4]),
                else => false,
            };
        }

        /// The constructor the `new` op at `pc` of `fs` runs, and its class's template,
        /// when the op compiles in place: a constructor that only stores its parameters in
        /// its fields, whose site has run it and made the template for the op's class.
        fn newPlan(fs: *const bc.FuncStreams, pc: usize) ?struct { stores: []const bc.FieldStore, t: *const runtime.InstanceData.Template } {
            if (S.reclaims or ev_parent.call_hooks_on) return null;
            const code = fs.code;
            const cfs = fs.callees[code[pc + 7]].load(.acquire) orelse return null;
            if (cfs.leaf != .set_fields) return null;
            const sf = cfs.leaf.set_fields;
            if (sf.super != null or sf.object != bc.NO_OBJECT) return null;
            const t = cfs.new_template.load(.acquire) orelse return null;
            const made: *const InstCell = @ptrCast(t.image.ptr);
            if (made.data.class_id != code[pc + 2] or t.image.len > inline_new_max) return null;
            const n = code[pc + 5];
            for (sf.stores) |st| if (st.param > n or st.slot >= t.n_slots) return null;
            return .{ .stores = sf.stores, .t = t };
        }

        /// `new` compiled in place (`newPlan`), as `opNew`'s leaf does it: the instance
        /// bumped out of the thread's region hole as a copy of its class's template, its
        /// fields stored from the argument run. A hole without room leaves the op to its
        /// handler, which checks all again.
        fn newOp(g: *Gen, pc: usize, blk: u32) !bool {
            if (primKindOf(g.module, g.code(pc, 2))) |k| return primNewOp(g, pc, blk, k);
            const plan = newPlan(g.fs, pc) orelse return false;
            const m = &g.m;
            const size: u32 = @intCast(plan.t.image.len);
            const lo = g.code(pc, 4);
            const dst = g.code(pc, 6);
            const fail = try g.slow(.new, pc, blk);
            try m.loadCtx(.t2, ctx_tlab);
            try m.loadAt(.w64, .t3, .t2, tlab_cursor);
            try m.loadAt(.w64, .t0, .t2, tlab_limit);
            try m.sub(.w64, .t0, .t0, .t3);
            try m.subImm(.w64, .t0, .t0, size);
            try m.bNegative(.t0, fail);
            // The instance is t3 from here on; nothing leaves after the bump.
            try m.addImm(.w64, .t0, .t3, size);
            try m.storeAt(.w64, .t2, tlab_cursor, .t0);
            try m.copyFrom(.t3, plan.t.image);
            try m.addImm(.w64, .t2, .t3, @sizeOf(InstCell));
            try m.storeAt(.w64, .t3, inst_slots, .t2);
            for (plan.stores) |st| {
                const off: u32 = @intCast(@sizeOf(InstCell) + st.slot * @sizeOf(Value));
                if (st.param == 0) {
                    // Parameter 0 is the instance.
                    try m.storeAt(.w64, .t3, off, .t3);
                    try m.movImm(.t2, tagOf(.Instance));
                    try m.storeAt(.w64, .t3, off + tag_off, .t2);
                    continue;
                }
                const r = lo + st.param - 1;
                try m.loadRegWord(.t2, r, 0);
                try m.storeAt(.w64, .t3, off, .t2);
                try m.loadRegWord(.t2, r, 1);
                try m.storeAt(.w64, .t3, off + 8, .t2);
            }
            try m.storePayload(.w64, dst, .t3);
            try g.putTag(dst, .Instance, .t2);
            return true;
        }

        /// The primitive array kind whose class `class` is.
        fn primKindOf(module: *const ir.Module, class: u32) ?runtime.PrimitiveArrayKind {
            const r = module.resolved orelse return null;
            for (r.host_class.prim_array, 0..) |c, k| {
                if (c != null and c.?.int() == class) return @enumFromInt(k);
            }
            return null;
        }

        /// `new` of a primitive array of `k` with a size, as `opNew` makes it: the cell bumped out
        /// of the thread's region hole as a copy of the kind's template, its elements after it,
        /// zeroed. Any other argument, a size over `prim_new_max` bytes or a hole without room
        /// leaves the op to its handler.
        fn primNewOp(g: *Gen, pc: usize, blk: u32, k: runtime.PrimitiveArrayKind) !bool {
            if (S.reclaims or ev_parent.call_hooks_on or g.code(pc, 5) != 1) return false;
            const image = try primTemplate(k);
            const m = &g.m;
            const n = g.code(pc, 4);
            const dst = g.code(pc, 6);
            const shift: u6 = @intCast(std.math.log2_int(usize, k.elemSize()));
            const fail = try g.slow(.new, pc, blk);
            try g.guard(n, .Int, fail);
            try m.loadPayload(.w32, .t0, n);
            try m.signExtend32(.t0, .t0);
            try m.bNegative(.t0, fail);
            try m.movImm(.t1, prim_new_max >> shift);
            try m.cmp(.w64, .t0, .t1);
            try m.bCond(.gt, fail);
            // t1: the cell and its elements, rounded as the hole bumps.
            try m.shlImm(.w64, .t0, .t0, shift);
            try m.addImm(.w64, .t1, .t0, @sizeOf(PrimCell) + 15);
            try m.andImm(.w64, .t1, .t1, -16);
            try m.loadCtx(.t2, ctx_tlab);
            try m.loadAt(.w64, .t3, .t2, tlab_cursor);
            try m.loadAt(.w64, .t0, .t2, tlab_limit);
            try m.sub(.w64, .t0, .t0, .t3);
            try m.cmp(.w64, .t0, .t1);
            try m.bCond(.lt, fail);
            // The array is t3 from here on; nothing leaves after the bump.
            try m.add(.w64, .t0, .t3, .t1);
            try m.storeAt(.w64, .t2, tlab_cursor, .t0);
            try m.copyFrom(.t3, image);
            try m.loadPayload(.w32, .t0, n);
            try m.signExtend32(.t0, .t0);
            try m.shlImm(.w64, .t0, .t0, shift);
            try m.addImm(.w64, .t1, .t3, @sizeOf(PrimCell));
            try m.storeAt(.w64, .t3, prim_items, .t1);
            try m.storeAt(.w64, .t3, prim_items + 8, .t0);
            try m.storeAt(.w64, .t3, prim_capacity, .t0);
            try m.storeAt(.w32, .t3, prim_trailing, .t0);
            try m.addImm(.w64, .t2, .t0, @sizeOf(PrimCell));
            try m.movImm(.t1, runtime.gc.region_bit);
            try m.orR(.w64, .t2, .t2, .t1);
            try m.storeAt(.w32, .t3, prim_gc_bytes, .t2);
            // Zero the elements and the rest of the rounding: t1 up to t2.
            try m.addImm(.w64, .t2, .t0, @sizeOf(PrimCell) + 15);
            try m.andImm(.w64, .t2, .t2, -16);
            try m.add(.w64, .t2, .t2, .t3);
            try m.addImm(.w64, .t1, .t3, @sizeOf(PrimCell));
            try m.movImm(.t0, 0);
            const loop = try m.label();
            const done = try m.label();
            m.bind(loop);
            try m.cmp(.w64, .t1, .t2);
            try m.bCond(.ge, done);
            try m.storeAt(.w64, .t1, 0, .t0);
            try m.storeAt(.w64, .t1, 8, .t0);
            try m.addImm(.w64, .t1, .t1, 16);
            try m.jump(loop);
            m.bind(done);
            try m.movImm(.t1, @intFromEnum(k) + 1);
            try m.orR(.w64, .t0, .t3, .t1);
            try m.storePayload(.w64, dst, .t0);
            try g.putTag(dst, .Array, .t2);
            return true;
        }

        /// Whether a `bin_k` or `cmp_br_k` op with kind word `kw` compiles in place, as
        /// `compareK` and `arithK` decide.
        fn kNative(op: Op, kw: u32, kv: u64) bool {
            const bop = kOp(op);
            const k: bc.KType = @enumFromInt((kw >> 8) & 0xff);
            const is_cmp = bc.orderMask(bop) != 0 or isIdent(bop) or @intFromEnum(op) >= @intFromEnum(Op.cmp_br_k_less);
            if (is_cmp) return switch (k) {
                .int, .long => condOf(bc.orderMask(bop)) != null,
                .float, .double => floatCompare(bop) and condOf(bc.orderMask(bop)) != null,
                .null => switch (bop) {
                    .Eq, .BoxedEq, .IdentEq, .NotEq, .BoxedNotEq, .IdentNeq => true,
                    else => false,
                },
                else => false,
            };
            return switch (k) {
                .float, .double => switch (bop) {
                    .Add, .Sub, .Mul, .Div => true,
                    else => false,
                },
                .int, .long => switch (bop) {
                    .Add, .Sub, .Mul, .And, .Or, .Xor, .Shl, .Shr, .UShr => true,
                    .Div, .Mod => (if (k == .int) kv & 0xffff_ffff else kv) != 0,
                    else => false,
                },
                else => false,
            };
        }

        /// Adds the registers `op` at `pc` writes when it runs in place to `set`.
        fn addDsts(set: *std.DynamicBitSetUnmanaged, code: []const u32, op: Op, pc: usize) void {
            switch (op) {
                .const_int, .const_val, .move, .load_param, .const_str, .load_capture => set.set(code[pc + 1]),
                .load_object, .is, .cast, .array_get, .load_static, .iter_has, .iter_get => set.set(code[pc + 2]),
                .array_set => {},
                .load_params => for (0..code[pc + 1]) |k| set.set(code[pc + 2 + 2 * k]),
                .not, .not_null, .get_field, .unbox_value, .box_value => set.set(code[pc + 2]),
                .set_field => {},
                .add, .sub, .cmp, .bin, .bin_mul, .bin_div, .bin_and, .bin_or, .bin_xor, .bin_shl, .bin_shr, .bin_ushr, .bin_ident_eq, .bin_ident_neq, .un_inc, .un_dec, .un_neg, .conv_long, .conv_int, .fn_inv, .fn_to_ulong, .fn_to_uint, .fn_unsigned_bits, .fn_float_from_bits, .fn_double_from_bits, .fn_to_raw_bits, .cmp_br => set.set(code[pc + 3]),
                .call, .vcall, .native, .callv => set.set(code[pc + 5]),
                .jump, .br, .ret => {},
                else => set.set(code[pc + 9]),
            }
        }

        /// The block and pc pairs `op` at `pc` goes to when it runs in place; a
        /// `bin_k` goes on past the op it fronts.
        fn successors(code: []const u32, op: Op, pc: usize, out: *[2][2]u32) []const [2]u32 {
            switch (op) {
                .jump => {
                    out[0] = .{ code[pc + 1], code[pc + 2] };
                    return out[0..1];
                },
                .br => {
                    out[0] = .{ code[pc + 2], code[pc + 3] };
                    out[1] = .{ code[pc + 4], code[pc + 5] };
                    return out[0..2];
                },
                .cmp_br => {
                    out[0] = .{ code[pc + 6], code[pc + 7] };
                    out[1] = .{ code[pc + 8], code[pc + 9] };
                    return out[0..2];
                },
                .cmp_br_k_less, .cmp_br_k_less_eq, .cmp_br_k_greater, .cmp_br_k_greater_eq, .cmp_br_k_eq, .cmp_br_k_not_eq, .cmp_br_k_boxed_eq, .cmp_br_k_boxed_not_eq, .cmp_br_k_ident_eq, .cmp_br_k_ident_neq => {
                    out[0] = .{ code[pc + 12], code[pc + 13] };
                    out[1] = .{ code[pc + 14], code[pc + 15] };
                    return out[0..2];
                },
                .ret => return out[0..0],
                else => unreachable,
            }
        }

        fn isBranch(op: Op) bool {
            return switch (op) {
                .jump, .br, .cmp_br, .ret, .cmp_br_k_less, .cmp_br_k_less_eq, .cmp_br_k_greater, .cmp_br_k_greater_eq, .cmp_br_k_eq, .cmp_br_k_not_eq, .cmp_br_k_boxed_eq, .cmp_br_k_boxed_not_eq, .cmp_br_k_ident_eq, .cmp_br_k_ident_neq => true,
                else => false,
            };
        }

        fn isCmpBrK(op: Op) bool {
            return @intFromEnum(op) >= @intFromEnum(Op.cmp_br_k_less) and @intFromEnum(op) <= @intFromEnum(Op.cmp_br_k_ident_neq);
        }

        fn isBinK(op: Op) bool {
            return @intFromEnum(op) >= @intFromEnum(Op.bin_k_add) and @intFromEnum(op) <= @intFromEnum(Op.bin_k_ident_neq);
        }

        /// Whether the cache of call site `op` at `pc` may yet hold what the code could
        /// compile in place: no callee, or one class of a virtual call's two.
        fn siteOpen(fs: *const bc.FuncStreams, op: Op, pc: usize) bool {
            const site = fs.code[pc + 6];
            if (op == .call) return fs.callees[site].load(.acquire) == null;
            if (op == .callv) return fs.lambdas[site].load(.acquire) == null;
            const e = fs.vcallees[site].load(.acquire) orelse return true;
            return e.n < 2;
        }

        /// How the call `op` at `pc` of `fs` compiles, or null when it stays a call. `chain`
        /// holds the functions it is compiled into, `area` its callee's first inline register.
        fn planFor(g: *Gen, fs: *const bc.FuncStreams, op: Op, pc: usize, chain: []const *const bc.FuncStreams, area: u32) std.mem.Allocator.Error!?Plan {
            if (!inline_calls or ev_parent.call_hooks_on) return null;
            const code = fs.code;
            const lo = code[pc + 3];
            const n = code[pc + 4];
            if (lo + n > fs.func.n_locals or code[pc + 5] >= fs.func.n_locals) return null;
            var plan: Plan = .{};
            if (op == .call) {
                const sc = fs.callees[code[pc + 6]].load(.acquire) orelse {
                    // A host function the call runs as it is has no callee to cache.
                    const k = staticIntrinsic(g.module, code[pc + 2]);
                    if (!k.fits(lo, n, code[pc + 5])) return null;
                    plan.targets[0] = .{ .class = 0, .host = k };
                    plan.n = 1;
                    return plan;
                };
                const an = (try analyze(g, sc, chain, area, false)) orelse return null;
                plan.targets[0] = .{ .class = 0, .sc = sc, .an = an };
                plan.n = 1;
                plan.words = an.words;
                return plan;
            }
            if (op == .callv) {
                // The lambda's body is compiled against this module's tables.
                const ls = fs.lambdas[code[pc + 6]].load(.acquire) orelse return null;
                if (ls.module != g.module or ls.owning != null) return null;
                const an = (try analyze(g, ls.sc, chain, area, true)) orelse return null;
                plan.targets[0] = .{ .class = 0, .sc = ls.sc, .an = an, .lambda = ls };
                plan.n = 1;
                plan.words = an.words;
                return plan;
            }
            const e = fs.vcallees[code[pc + 6]].load(.acquire) orelse return null;
            for (0..e.n) |i| {
                const sc = e.streams[i] orelse {
                    const k = intrinsicOf(g.module, e.natives[i]);
                    if (k.fits(lo, n, code[pc + 5])) {
                        plan.targets[plan.n] = .{ .class = e.classes[i], .host = k };
                        plan.n += 1;
                    }
                    continue;
                };
                const an = (try analyze(g, sc, chain, area, false)) orelse continue;
                plan.targets[plan.n] = .{ .class = e.classes[i], .sc = sc, .an = an };
                plan.n += 1;
                plan.words += an.words;
            }
            return if (plan.n == 0) null else plan;
        }

        /// What compiling `sc` into a caller finds, or null when it is not compiled in: too
        /// large, recursive, with a try region, or with an op the code leaves at outside its
        /// blocks that throw.
        fn analyze(g: *Gen, sc: *const bc.FuncStreams, chain: []const *const bc.FuncStreams, area: u32, lambda: bool) std.mem.Allocator.Error!?*const Analysis {
            if (chain.len >= ev_state.INLINE_LEVELS + 1) return reject(sc, "too deep", 0);
            if (sc.code.len > inline_words) return reject(sc, "too large", 0);
            const nl = sc.func.n_locals;
            if (area + nl > ev_state.INLINE_REGS) return reject(sc, "no registers left", 0);
            for (chain) |f| if (f == sc) return reject(sc, "recursive", 0);
            // A throw in a callee with a try region routes through its handlers.
            if (sc.has_try) return reject(sc, "try", 0);
            // Code that ran it in place left it too often at an op it does not run there.
            if (sc.exits_hot.load(.monotonic)) return reject(sc, "leaves often", 0);
            const a = g.scratch;
            const code = sc.code;
            const n = code.len;
            const an = try a.create(Analysis);
            an.* = .{
                .reach = try a.alloc(bool, n),
                .native = try a.alloc(bool, n),
                .d_in = try a.alloc(std.DynamicBitSetUnmanaged, sc.blocks.len),
                .prefill = try std.DynamicBitSetUnmanaged.initEmpty(a, nl),
                .words = @intCast(n),
            };
            @memset(an.reach, false);
            @memset(an.native, false);
            const blk_of = try a.alloc(u32, n);
            const sub_chain = try a.alloc(*const bc.FuncStreams, chain.len + 1);
            @memcpy(sub_chain[0..chain.len], chain);
            sub_chain[chain.len] = sc;
            for (sc.blocks, 0..) |b, bi| {
                var pc: usize = b.enter;
                while (pc <= b.end) {
                    const op = sc.opAt(pc);
                    blk_of[pc] = @intCast(bi);
                    switch (op) {
                        .block_entry, .goto_try, .ret_try => return reject(sc, @tagName(op), pc),
                        // A lambda compiled in place reads its captures from its closure.
                        .load_capture => if (lambda) {
                            an.native[pc] = true;
                        } else return reject(sc, @tagName(op), pc),
                        .call, .vcall, .callv => if (try planFor(g, sc, op, pc, sub_chain, area + nl)) |p| {
                            try an.plans.put(a, @intCast(pc), p);
                            an.native[pc] = true;
                            an.words += p.words;
                        },
                        .native => an.native[pc] = g.nativeIntrinsic(sc, pc) != .none,
                        else => an.native[pc] = canNative(sc, op, pc),
                    }
                    pc += bc.opLen(op, code, pc);
                }
            }
            if (an.words > inline_words * 2) return reject(sc, "too large with its callees", 0);
            // Reachable ops, from the entry through ops that run in place. An op that does not
            // leaves the code for the frame the call would have had, which costs what the call
            // costs; a callee none of whose paths returns in place would only add to it.
            var work: std.ArrayList(u32) = .empty;
            try work.append(a, sc.entry_pc);
            an.reach[sc.entry_pc] = true;
            var returns = false;
            var first_exit: ?struct { Op, usize } = null;
            while (work.pop()) |start| {
                var pc: usize = start;
                while (true) {
                    const op = sc.opAt(pc);
                    if (!an.native[pc]) {
                        if (census_on) census_exits[@intFromEnum(op)] += 1;
                        if (first_exit == null) first_exit = .{ op, pc };
                        break;
                    }
                    if (op == .ret) returns = true;
                    if (isBranch(op)) {
                        var out: [2][2]u32 = undefined;
                        for (successors(code, op, pc, &out)) |s| if (!an.reach[s[1]]) {
                            an.reach[s[1]] = true;
                            try work.append(a, s[1]);
                        };
                        break;
                    }
                    pc += if (isBinK(op)) 12 else bc.opLen(op, code, pc);
                    if (an.reach[pc]) break;
                    an.reach[pc] = true;
                }
            }
            if (!returns) {
                if (census_on) if (first_exit) |x| {
                    last_reject = std.fmt.allocPrint(std.heap.smp_allocator, "no return in place ({t} at {d})", .{ x[0], x[1] }) catch "no return in place";
                    census_other[4] += 1;
                    return null;
                };
                return reject(sc, "no return in place", 0);
            }
            // Registers written on every path (d_in) and on some (m_in) to each block, and the
            // span each block's entry finds, to a fixed point.
            const m_in = try a.alloc(std.DynamicBitSetUnmanaged, sc.blocks.len);
            const seen = try a.alloc(bool, sc.blocks.len);
            @memset(seen, false);
            for (an.d_in, m_in) |*d, *mm| {
                d.* = try std.DynamicBitSetUnmanaged.initFull(a, nl);
                mm.* = try std.DynamicBitSetUnmanaged.initEmpty(a, nl);
            }
            const entry_blk = blk_of[sc.entry_pc];
            an.d_in[entry_blk].unsetAll();
            seen[entry_blk] = true;
            var d = try std.DynamicBitSetUnmanaged.initEmpty(a, nl);
            var mw = try std.DynamicBitSetUnmanaged.initEmpty(a, nl);
            var changed = true;
            while (changed) {
                changed = false;
                for (sc.blocks, 0..) |b, bi| {
                    if (!seen[bi]) continue;
                    d.setRangeValue(.{ .start = 0, .end = nl }, false);
                    d.setUnion(an.d_in[bi]);
                    mw.setRangeValue(.{ .start = 0, .end = nl }, false);
                    mw.setUnion(m_in[bi]);
                    var pc: usize = if (bi == entry_blk) sc.entry_pc else b.enter;
                    while (pc <= b.end and an.reach[pc] and an.native[pc]) {
                        const op = sc.opAt(pc);
                        addDsts(&d, code, op, pc);
                        addDsts(&mw, code, op, pc);
                        if (isBranch(op)) {
                            var out: [2][2]u32 = undefined;
                            for (successors(code, op, pc, &out)) |s| {
                                const t = s[0];
                                if (!seen[t]) {
                                    seen[t] = true;
                                    an.d_in[t].setRangeValue(.{ .start = 0, .end = nl }, false);
                                    an.d_in[t].setUnion(d);
                                    changed = true;
                                } else {
                                    const before = an.d_in[t].count();
                                    an.d_in[t].setIntersection(d);
                                    if (an.d_in[t].count() != before) changed = true;
                                }
                                const mb = m_in[t].count();
                                m_in[t].setUnion(mw);
                                if (m_in[t].count() != mb) changed = true;
                            }
                            break;
                        }
                        pc += if (isBinK(op)) 12 else bc.opLen(op, code, pc);
                    }
                }
            }
            for (an.d_in, m_in, seen) |di, mi, s| {
                if (!s) continue;
                var diff = try mi.clone(a);
                var not_d = try di.clone(a);
                not_d.toggleAll();
                diff.setIntersection(not_d);
                an.prefill.setUnion(diff);
            }
            return an;
        }

        /// No analysis: `sc` is not compiled into a caller, for `why` (at `pc`).
        fn reject(sc: *const bc.FuncStreams, why: []const u8, pc: usize) ?*const Analysis {
            if (log_compiles) std.debug.print("[jit]   not in place: {s}: {s} at {d}\n", .{ sc.func.fqn, why, pc });
            if (census_on) {
                last_reject = if (std.meta.stringToEnum(Op, why) != null) std.fmt.allocPrint(std.heap.smp_allocator, "{s} at {d}", .{ why, pc }) catch why else why;
                if (std.meta.stringToEnum(Op, why)) |op| census_rejected[@intFromEnum(op)] += 1 else if (std.mem.startsWith(u8, why, "too large")) {
                    census_other[0] += 1;
                } else if (std.mem.eql(u8, why, "too deep")) {
                    census_other[1] += 1;
                } else if (std.mem.eql(u8, why, "recursive")) {
                    census_other[2] += 1;
                } else if (std.mem.eql(u8, why, "no return in place")) {
                    census_other[4] += 1;
                } else if (std.mem.eql(u8, why, "leaves often")) {
                    census_other[5] += 1;
                } else census_other[3] += 1;
            }
            return null;
        }

        /// A `call` or `vcall` at `pc`: its callees compiled in place, each behind its receiver
        /// class's test for a `vcall`, when its plan has any; false leaves it to its handler.
        /// A static call the code does not run in place, to a callee its site keeps, or a
        /// virtual call whose site keeps one class and a function of it: the code gives the
        /// frame its pins and goes to `directCall` with the site's record (`bc.DirectSite`),
        /// shared code that opens the callee's frame and goes on in its code, or
        /// leaves what it does not take to the call's handler; the return comes back to this
        /// code's entry after the call as any return does. A call of the function itself, its
        /// record in the context, goes to its direct entry (`FuncStreams.direct_entry`), the
        /// same work compiled for this function: code at every call site, or an entry for every
        /// callee, costs more in instruction fetch over a program's many callees than the work
        /// it saves.
        fn directCall(g: *Gen, op: Op, pc: usize, blk: u32, stale: bool) CompileError!bool {
            const d = directTarget(g, op, pc) orelse return false;
            const idx = g.code(pc, 1);
            const lo = g.code(pc, 3);
            const nargs = g.code(pc, 4);
            const sc = d.sc;
            const npc: u32 = if (sc.param_map.len != 0) sc.body_pc else @intCast(sc.entry_pc);
            const rec = &(try g.keep.alignedAlloc(bc.DirectSite, .fromByteUnits(64), 1))[0];
            rec.* = .{
                .sc = sc,
                .func = sc.func,
                .code = sc.code.ptr,
                .entry = 0,
                .back = 0,
                .caller = g.fs,
                .caller_code = g.fs.code.ptr,
                .blk = blk,
                .idx = idx,
                .lo16 = lo * 16,
                .nargs = nargs,
                .n_locals = sc.func.n_locals,
                .npc = npc,
                .eb = sc.func.entry.int(),
                .npairs = 0,
                .ret_idx = idx + 1,
                .ret_pc = @intCast(pc + bc.opLen(op, g.fs.code, pc)),
                .dst = @enumFromInt(g.code(pc, 5)),
                .class = d.class orelse bc.DirectSite.no_class,
                .pairs = @splat(0),
                .pc = @intCast(pc),
                .op = op,
                .stale = stale,
                .shaped = false,
            };
            // The callee's shape, when it is compiled already; else the first call that finds it
            // compiled takes it (`directCall`).
            if (sc.jit_entries.load(.acquire)) |entries| rec.takeShape(entries);
            try g.direct_sites.append(g.gpa, rec);
            const m = &g.m;
            try m.writeBackPins();
            // A direct entry reads the parameters its function loads from the arguments.
            var k: usize = 0;
            const reads_args = while (k < d.sc.param_map.len) : (k += 2) {
                if (d.sc.param_map[k + 1] >= nargs) break false;
            } else true;
            if (d.sc == g.fs and reads_args) {
                const shared = try m.label();
                try m.movImm(.t0, @intFromPtr(rec));
                try m.storeCtx(ctx_direct, .t0);
                // A virtual call's receiver: an instance of the class its site keeps.
                if (d.class) |cls| {
                    try g.guard(lo, .Instance, shared);
                    try m.loadPayload(.w64, .t0, lo);
                    try m.loadAt(.w32, .t1, .t0, inst_class);
                    try m.movImm(.t2, cls);
                    try m.cmp(.w32, .t1, .t2);
                    try m.bCond(.ne, shared);
                }
                try m.movImm(.t1, @intFromPtr(&d.sc.direct_entry));
                try m.loadAt(.w64, .t1, .t1, 0);
                try m.bZero64(.t1, shared);
                try m.jumpTo(.t1);
                const sec = try m.cold();
                m.bind(shared);
                try m.tailHandler(@intFromPtr(&S.directCall), @intFromPtr(rec), blk);
                m.endCold(sec);
            } else try m.tailHandler(@intFromPtr(&S.directCall), @intFromPtr(rec), blk);
            _ = direct_count.fetchAdd(1, .monotonic);
            return true;
        }

        /// Whether `fs`, compiled, takes its calls of itself at a direct entry: a site of it
        /// keeps it, and a call that opens its frame writes nothing past `openFast`'s common
        /// case (no whole-window fill, no try stack of its own, no span read at its entry).
        fn directEntryFits(fs: *const bc.FuncStreams) bool {
            if (S.reclaims or !direct_calls or !direct_entries or fs.leaf != .none) return false;
            const open = fs.open;
            if (open.fill_all or open.keeps_try or open.clear_span or fs.fill.len > 8) return false;
            for (fs.callees) |*c| if (c.load(.acquire) == fs) return true;
            for (fs.vcallees) |*v| if (v.load(.acquire)) |e| {
                for (e.streams[0..e.n]) |sc| if (sc == fs) return true;
            };
            return false;
        }

        /// The function's direct entry (`FuncStreams.direct_entry`), entered with the caller's
        /// frame, registers and code and the call's record in the context (`Ctx.direct`): opens
        /// the function's frame as `openFast` does, over an activation from the thread's pool,
        /// loads its parameters and goes on at `enter`, where a call's handler would go on. What
        /// `openFast` or the call's guards would not take goes to `directCall`, the caller's
        /// state untouched.
        fn emitDirectEntry(g: *Gen, enter: Masm.Label) CompileError!void {
            const sc = g.fs;
            const m = &g.m;
            const pairs = sc.param_map;
            const n: u32 = sc.func.n_locals;
            const npc: usize = if (pairs.len != 0) sc.body_pc else sc.entry_pc;
            const eb = sc.func.entry.int();
            const fail = try m.label();
            // The caller stands at the call, as the handler would record it.
            try m.loadCtx(.t1, ctx_direct);
            try m.loadAt(.w64, .t2, .t1, siteField("blk"));
            try m.storeFrame(@offsetOf(Frame, "at_block"), .t2);
            // What `openFast` asks, and the call's guards (`enteredGuards`).
            try m.loadCtx(.t0, ctx_ev);
            try m.loadByteAt(.t1, .t0, ev_plain);
            try m.bZero(.t1, fail);
            try m.loadAt(.w64, .t1, .t0, ev_depth);
            try m.loadAt(.w64, .t2, .t0, ev_depth_cap);
            try m.cmp(.w64, .t1, .t2);
            try m.bCond(.ge, fail);
            try m.loadAt(.w64, .t1, .t0, ev_pool_len);
            try m.bZero64(.t1, fail);
            try m.loadAbs32(.t2, @intFromPtr(&runtime.gc.edge_flags));
            try m.bNonZero(.t2, fail);
            try m.loadAt(.w64, .t2, .t0, ev_spin);
            try m.addImm(.w64, .t2, .t2, 1);
            try m.bLow16Zero(.t2, fail);
            try m.storeAt(.w64, .t0, ev_spin, .t2);
            // Room for the window on the value stack.
            try m.loadAt(.w64, .t3, .t0, ev_vs_seg);
            try m.bZero64(.t3, fail);
            try m.loadAt(.w64, .t2, .t3, seg_buf + 8);
            try m.loadAt(.w64, .t3, .t0, ev_vs_top);
            try m.sub(.w64, .t2, .t2, .t3);
            try m.movImm(.t3, n);
            try m.cmp(.w64, .t2, .t3);
            try m.bCond(.lt, fail);
            // The activation, off the pool; the depth one more.
            try m.loadAt(.w64, .t1, .t0, ev_pool_len);
            try m.subImm(.w64, .t1, .t1, 1);
            try m.storeAt(.w64, .t0, ev_pool_len, .t1);
            try m.shlImm(.w64, .t1, .t1, 3);
            try m.add(.w64, .t1, .t1, .t0);
            try m.loadAt(.w64, .t1, .t1, ev_pool);
            try m.loadAt(.w64, .t2, .t0, ev_depth);
            try m.addImm(.w64, .t2, .t2, 1);
            try m.storeAt(.w64, .t0, ev_depth, .t2);
            // The window: where the value stack stood, which the frame pops back to.
            try m.loadAt(.w64, .t2, .t0, ev_vs_seg);
            try m.storeAt(.w64, .t1, actFrame("vs_mark"), .t2);
            try m.loadAt(.w64, .t3, .t0, ev_vs_top);
            try m.storeAt(.w64, .t1, actFrame("vs_mark") + 8, .t3);
            try m.addImm(.w64, .t3, .t3, n);
            try m.storeAt(.w64, .t0, ev_vs_top, .t3);
            try m.subImm(.w64, .t3, .t3, n);
            try m.shlImm(.w64, .t3, .t3, 4);
            try m.loadAt(.w64, .t2, .t2, seg_buf);
            try m.add(.w64, .t2, .t2, .t3);
            // The frame below it on the collector's chain, and this one on top.
            try m.loadAt(.w64, .t3, .t0, ev_chain);
            try m.storeAt(.w64, .t1, actFrame("gc_link"), .t3);
            try m.addImm(.w64, .t3, .t1, @offsetOf(Activation, "frame"));
            try m.storeAt(.w64, .t0, ev_chain, .t3);
            // The frame's words, as `Frame.enterPooledWindow` writes them.
            try m.loadFrame(.t3, @offsetOf(Frame, "module"));
            try m.storeAt(.w64, .t1, actFrame("module"), .t3);
            try m.storeAt(.w64, .t1, actFrame("regs"), .t2);
            try m.loadCtx(.t3, ctx_direct);
            try m.loadAt(.w32, .t3, .t3, siteField("lo16"));
            try m.windowPlus(.t3, .t3);
            try m.storeAt(.w64, .t1, actFrame("params"), .t3);
            try m.loadCtx(.t3, ctx_alloc);
            try m.storeAt(.w64, .t1, actFrame("allocator"), .t3);
            try m.loadCtx(.t3, ctx_alloc + 8);
            try m.storeAt(.w64, .t1, actFrame("allocator") + 8, .t3);
            try m.loadCtx(.t3, ctx_top);
            try m.storeAt(.w64, .t1, @offsetOf(Activation, "caller"), .t3);
            try m.storeCtx(ctx_top, .t1);
            const no_values: []const Value = &.{};
            try m.storeBytesAt(.t1, actFrame("func"), &std.mem.toBytes(@intFromPtr(sc.func)));
            try m.storeBytesAt(.t1, actFrame("regs") + 8, &std.mem.toBytes(@as(u64, n)));
            try m.storeBytesAt(.t1, actFrame("captures"), &(std.mem.toBytes(@intFromPtr(no_values.ptr)) ++ std.mem.toBytes(@as(u64, 0))));
            try m.storeBytesAt(.t1, actFrame("vs_mark") + 16, &std.mem.toBytes(@as(u64, 1)));
            try m.storeBytesAt(.t1, actFrame("module_arc"), &std.mem.toBytes(@as(u64, 0)));
            try m.storeBytesAt(.t1, actFrame("closure"), &std.mem.toBytes(@as(u128, 0)));
            try m.storeBytesAt(.t1, actFrame("at_block"), &(std.mem.toBytes(eb) ++ std.mem.toBytes(ev_frame.block_start)));
            for (sc.fill) |r| try m.storeBytesAt(.t2, r * 16, &bytesOf(.Unit));
            // The call's own words: its argument count and return point.
            try m.loadCtx(.t3, ctx_direct);
            try m.loadAt(.w32, .t0, .t3, siteField("nargs"));
            try m.storeAt(.w64, .t1, actFrame("params") + 8, .t0);
            try m.loadAt(.w64, .t0, .t3, siteField("back"));
            try m.storeAt(.w64, .t1, @offsetOf(Activation, "ret_code"), .t0);
            try m.loadAt(.w64, .t0, .t3, siteField("caller_code"));
            try m.storeAt(.w64, .t1, @offsetOf(Activation, "ret_codeptr"), .t0);
            try m.loadAt(.w64, .t0, .t3, siteField("caller"));
            try m.storeAt(.w64, .t1, @offsetOf(Activation, "ret_streams"), .t0);
            try m.loadAt(.w32, .t0, .t3, siteField("blk"));
            try m.storeAt(.w32, .t1, @offsetOf(Activation, "ret_block"), .t0);
            try m.loadAt(.w32, .t0, .t3, siteField("ret_idx"));
            try m.storeAt(.w32, .t1, @offsetOf(Activation, "ret_idx"), .t0);
            try m.loadAt(.w32, .t0, .t3, siteField("ret_pc"));
            try m.storeAt(.w32, .t1, @offsetOf(Activation, "ret_pc"), .t0);
            try m.loadAt(.w32, .t0, .t3, siteField("dst"));
            try m.storeAt(.w32, .t1, @offsetOf(Activation, "ret_dst"), .t0);
            // The arguments into the parameter registers.
            if (pairs.len != 0) {
                try m.loadAt(.w32, .t3, .t3, siteField("lo16"));
                try m.windowPlus(.t3, .t3);
                var k: usize = 0;
                while (k < pairs.len) : (k += 2) {
                    try m.loadAt(.w64, .t0, .t3, pairs[k + 1] * 16);
                    try m.storeAt(.w64, .t2, pairs[k] * 16, .t0);
                    try m.loadAt(.w64, .t0, .t3, pairs[k + 1] * 16 + 8);
                    try m.storeAt(.w64, .t2, pairs[k] * 16 + 8, .t0);
                }
            }
            try m.movImm(.t3, @intFromPtr(sc));
            try m.storeCtx(ctx_bs, .t3);
            if (builtin.is_test) {
                try m.movImm(.t3, @intFromPtr(&direct_entry_runs));
                try m.loadAt(.w64, .t0, .t3, 0);
                try m.addImm(.w64, .t0, .t0, 1);
                try m.storeAt(.w64, .t3, 0, .t0);
            }
            if (@offsetOf(Activation, "frame") != 0) try m.addImm(.w64, .t1, .t1, @offsetOf(Activation, "frame"));
            try m.enterHere(.t1, .t2, @intFromPtr(sc.code.ptr), npc, eb);
            try m.jump(enter);
            m.bind(fail);
            try m.tailHandlerCtx(@intFromPtr(&S.directCall), ctx_direct);
        }

        /// The callee a direct call enters, and for a virtual call the class its receiver is.
        const Direct = struct { sc: *const bc.FuncStreams, class: ?u32 };

        fn directTarget(g: *Gen, op: Op, pc: usize) ?Direct {
            if ((op != .call and op != .vcall) or g.levels.items.len != 0 or S.reclaims or !direct_calls) return null;
            const site = g.code(pc, 6);
            var class: ?u32 = null;
            const sc = if (op == .call) g.fs.callees[site].load(.acquire) orelse return null else vc: {
                const e = g.fs.vcallees[site].load(.acquire) orelse return null;
                if (e.n != 1) return null;
                class = e.classes[0];
                break :vc e.streams[0] orelse return null;
            };
            // A callee that only reads or stores fields runs as its handler runs it.
            if (sc.leaf != .none) return null;
            if (g.code(pc, 3) + g.code(pc, 4) > g.fs.func.n_locals) return null;
            return .{ .sc = sc, .class = class };
        }

        fn callOp(g: *Gen, op: Op, pc: usize, blk: u32) CompileError!bool {
            const m = &g.m;
            // A site of the function compiled whose cache holds no callee yet, or one class of a
            // virtual call's two, counts its runs toward compiling the function again.
            const stale = g.levels.items.len == 0 and g.fs.recompiles < max_recompiles and siteOpen(g.fs, op, pc) and
                !(op == .call and hostFunction(g.module, g.code(pc, 2)));
            const plan: Plan = if (g.top()) |lv|
                lv.an.plans.get(@intCast(pc)) orelse return false
            else blk: {
                if (census_on) last_reject = "no callee cached";
                const p = (try planFor(g, g.fs, op, pc, &.{g.root}, 0)) orelse {
                    if (census_on) try g.countCall(op, pc, last_reject);
                    if (try directCall(g, op, pc, blk, stale)) return true;
                    if (!stale) return false;
                    try m.jump(try g.staleSlow(op, pc, blk));
                    g.handler_op = true;
                    return true;
                };
                if (g.inlined_words + p.words > inline_budget) {
                    if (census_on) try g.countCall(op, pc, "over the function's budget");
                    return directCall(g, op, pc, blk, stale);
                }
                g.inlined_words += p.words;
                break :blk p;
            };
            const fail = if (stale) try g.staleSlow(op, pc, blk) else try g.slow(op, pc, blk);
            const level: u32 = @intCast(g.levels.items.len);
            const cont = g.target(pc + bc.opLen(op, g.fs.code, pc));
            const call_next = g.next_label;
            // A virtual call's receiver is an instance of a class the site keeps, or a list,
            // whose class every list has.
            var by_tag = false;
            for (plan.targets[0..plan.n]) |t| {
                if (op == .vcall and t.host != .none and hostTag(g.module, t.class) != null) by_tag = true;
            }
            if (op == .vcall and !by_tag) {
                const recv = g.code(pc, 3);
                try g.guard(recv, .Instance, fail);
            }
            if (op == .callv) {
                // The callee is a closure over the lambda's record.
                const callee = g.code(pc, 2);
                try g.guard(callee, .IrClosure, fail);
                try m.loadPayload(.w64, .t0, callee);
                try m.loadAt(.w64, .t1, .t0, closure_body);
                try m.movImm(.t2, @intFromPtr(plan.targets[0].lambda.?.record));
                try m.cmp(.w64, .t1, .t2);
                try m.bCond(.ne, fail);
            }
            for (plan.targets[0..plan.n], 0..) |t, i| {
                const other = if (i + 1 < plan.n) try m.label() else fail;
                if (op == .vcall) {
                    if (if (t.host != .none) hostTag(g.module, t.class) else null) |tag| {
                        try g.guard(g.code(pc, 3), tag, other);
                    } else {
                        if (by_tag) try g.guard(g.code(pc, 3), .Instance, other);
                        try m.loadPayload(.w64, .t0, g.code(pc, 3));
                        try m.loadAt(.w32, .t1, .t0, inst_class);
                        try m.movImm(.t2, t.class);
                        try m.cmp(.w32, .t1, .t2);
                        try m.bCond(.ne, other);
                    }
                }
                const after: ?Masm.Label = if (i + 1 < plan.n) other else call_next;
                if (t.host != .none) {
                    try intrinsic(g, t.host, pc, fail);
                    g.next_label = after;
                    try g.goTo(cont);
                    if (i + 1 < plan.n) m.bind(other);
                    continue;
                }
                // The depth a call would reach: past the bound, the call throws.
                try m.loadCtx(.t0, ctx_ev);
                try m.loadAt(.w64, .t1, .t0, ev_depth);
                try m.loadAt(.w64, .t2, .t0, ev_depth_cap);
                if (level != 0) try m.addImm(.w64, .t1, .t1, level);
                try m.cmp(.w64, .t1, .t2);
                try m.bCond(.ge, fail);
                if (log_compiles) std.debug.print("[jit]   in place: {s}\n", .{t.sc.func.fqn});
                try inlineBody(g, t, pc, blk, cont, after);
                _ = inlined_count.fetchAdd(1, .monotonic);
                if (i + 1 < plan.n) m.bind(other);
            }
            return true;
        }

        /// `t`'s code in place of the call at `pc`, going on at `cont`.
        fn inlineBody(g: *Gen, t: Target, pc: usize, blk: u32, cont: Masm.Label, after: ?Masm.Label) CompileError!void {
            const m = &g.m;
            const sc = t.sc;
            const an = t.an;
            const outer_win = g.win();
            const area: u32 = if (g.top()) |lv| lv.area + lv.sc.func.n_locals else 0;
            if (g.top()) |lv| lv.frozen = try g.levelRecord(lv, blk) else try m.loadInlineBase(ctx_ev, ev_inline);
            const labels = try g.scratch.alloc(?Masm.Label, sc.code.len);
            @memset(labels, null);
            for (sc.blocks) |b| {
                var p: usize = b.enter;
                while (p <= b.end) {
                    const op = sc.opAt(p);
                    if (an.reach[p]) labels[p] = try m.label();
                    p += bc.opLen(op, sc.code, p);
                }
            }
            // The callee's kinds, its parameters taking what its arguments hold at the call.
            const n_args = g.code(pc, 4);
            const arg_kinds = try g.scratch.alloc(kinds_mod.Kind, n_args);
            for (arg_kinds, 0..) |*k, i| {
                const r: u32 = g.code(pc, 3) + @as(u32, @intCast(i));
                k.* = if (g.kindOf(r) != null) blk: {
                    if (g.levels.items.len == 0) try g.relied.append(g.scratch, .{ .pc = @intCast(g.cur_pc), .reg = r });
                    break :blk g.rawKind(r);
                } else kinds_mod.unknown;
            }
            const callee_kinds: ?*const kinds_mod.Kinds = if (g.kinds != null and use_kinds and t.lambda == null) blk: {
                const ck = try g.scratch.create(kinds_mod.Kinds);
                ck.* = try kinds_mod.analyzeWith(g.scratch, sc, arg_kinds, g.module);
                break :blk ck;
            } else null;
            const saved_fs = g.fs;
            const saved_labels = g.labels;
            try g.levels.append(g.gpa, .{
                .sc = sc,
                .an = an,
                .labels = labels,
                .area = area,
                .call_pc = @intCast(pc),
                .call_blk = blk,
                .lo = g.code(pc, 3),
                .n = g.code(pc, 4),
                .dst = g.code(pc, 5),
                .closure = if (t.lambda != null) g.code(pc, 2) else null,
                .cont = cont,
                .written = try std.DynamicBitSetUnmanaged.initEmpty(g.scratch, sc.func.n_locals),
                .kinds = callee_kinds,
            });
            g.fs = sc;
            g.labels = labels;
            m.setWin(g.win());
            defer {
                _ = g.levels.pop();
                g.fs = saved_fs;
                g.labels = saved_labels;
                m.setWin(outer_win);
            }
            var it = an.prefill.iterator(.{});
            while (it.next()) |r| try m.storeValue(@intCast(r), bytesOf(.Unit));
            const entry_blk = blockOf(sc, sc.entry_pc);
            if (sc.entry_spans.len > entry_blk and sc.entry_spans[entry_blk] == .dyn) try g.storeSlot(null);
            if (firstReached(sc, an) != sc.entry_pc) try m.jump(labels[sc.entry_pc].?);
            // The ops in the order they are laid out, for the label each is followed by.
            var order: std.ArrayList(u32) = .empty;
            for (sc.blocks) |b| {
                var p: usize = b.enter;
                while (p <= b.end) : (p += bc.opLen(sc.opAt(p), sc.code, p)) {
                    if (an.reach[p]) try order.append(g.scratch, @intCast(p));
                }
            }
            var k: usize = 0;
            for (sc.blocks, 0..) |b, bi| {
                const lv = g.top().?;
                lv.written.setRangeValue(.{ .start = 0, .end = sc.func.n_locals }, false);
                lv.written.setUnion(an.d_in[bi]);
                var p: usize = b.enter;
                while (p <= b.end) {
                    const op = sc.opAt(p);
                    const len = bc.opLen(op, sc.code, p);
                    defer p += len;
                    if (!an.reach[p]) continue;
                    m.bind(labels[p].?);
                    k += 1;
                    if (map_ops) try g.in_marks.append(g.scratch, .{ .label = labels[p].?, .op = op, .pc = p, .sc = sc });
                    g.next_label = if (k < order.items.len) labels[order.items[k]] else after;
                    g.top().?.cur_pc = p;
                    const native = an.native[p] and try compileOp(g, op, p, @intCast(bi));
                    if (!native) {
                        try m.jump(try g.slow(op, p, @intCast(bi)));
                        continue;
                    }
                    addDsts(&g.top().?.written, sc.code, op, p);
                }
            }
        }

        /// The first op `inlineBody` emits of `sc`'s reached ops.
        fn firstReached(sc: *const bc.FuncStreams, an: *const Analysis) usize {
            for (sc.blocks) |b| {
                var p: usize = b.enter;
                while (p <= b.end) {
                    if (an.reach[p]) return p;
                    p += bc.opLen(sc.opAt(p), sc.code, p);
                }
            }
            unreachable;
        }

        fn blockOf(sc: *const bc.FuncStreams, pc: usize) u32 {
            for (sc.blocks, 0..) |b, bi| if (pc >= b.enter and pc <= b.end) return @intCast(bi);
            unreachable;
        }

        /// A callee's return: its value to the call's result register, then the caller's op
        /// after the call.
        fn inlineRet(g: *Gen, pc: usize) !void {
            const m = &g.m;
            const lv = g.top().?;
            const inner = g.win();
            const outer: masm.Win = if (g.levels.items.len == 1) .{} else .{ .inline_area = true, .off = g.levels.items[g.levels.items.len - 2].area };
            if (g.code(pc, 1) != 0) {
                try m.loadRegWord(.t0, g.code(pc, 2), 0);
                try m.loadRegWord(.t1, g.code(pc, 2), 1);
                m.setWin(outer);
                try m.storeRegWord(lv.dst, 0, .t0);
                try m.storeRegWord(lv.dst, 1, .t1);
            } else {
                m.setWin(outer);
                try m.storeValue(lv.dst, bytesOf(.Unit));
            }
            m.setWin(inner);
            try g.goTo(lv.cont);
        }

        /// A callee's parameter load: its caller's argument, or `Unit` past the run.
        fn inlineParam(g: *Gen, dst: u32, idx: u32) !void {
            const m = &g.m;
            const lv = g.top().?;
            const inner = g.win();
            if (idx >= lv.n) return m.storeValue(dst, bytesOf(.Unit));
            const outer: masm.Win = if (g.levels.items.len == 1) .{} else .{ .inline_area = true, .off = g.levels.items[g.levels.items.len - 2].area };
            m.setWin(outer);
            try m.loadRegWord(.t0, lv.lo + idx, 0);
            try m.loadRegWord(.t1, lv.lo + idx, 1);
            m.setWin(inner);
            try m.storeRegWord(dst, 0, .t0);
            try m.storeRegWord(dst, 1, .t1);
        }
    };
}
