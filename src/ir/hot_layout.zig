//! The transpiler hot-view layout: every offset/tag the emitted C's inline
//! fast paths need to touch `runtime.Value` slots, instance fields, arrays,
//! and the frame's `?Span` trace slot. One fill implementation serves both
//! sides of the ABI: `klio_rt` fills the runtime slot the generated C
//! registers, and `klio transpile` fills the same struct at EMIT time to
//! freeze the values as compile-time constants in the generated header
//! (the runtime fill then verifies the frozen copy and disables the view
//! on any mismatch, so a .c linked against a different runtime falls back
//! to the exported helpers instead of reading through wrong offsets).

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");

const InstCell = runtime.ObjRef(runtime.InstanceData).Cell;
const FieldList = std.ArrayList(runtime.InstanceData.Field);
const PrimBufCell = runtime.ObjRef(runtime.PrimBuf).Cell;

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
    /// Array view: an `IntArray` element read, inline. `arr_prim_word` is
    /// the 8 bytes at `arr_prim_off` that mean "primitive Int storage" —
    /// the optional-enum encoding is compiler-chosen, so it is probed from
    /// two constructed values rather than assumed.
    tag_array: u64,
    arr_cell_off: u32,
    arr_prim_off: u32,
    arr_prim_int_word: u64,
    primbuf_ptr_off: u32,
    primbuf_len_off: u32,
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

/// The 8 bytes at `off` inside `v`, for a probe whose encoding is
/// compiler-chosen (an optional enum's niche).
fn readWord(v: *const runtime.Value, off: u32) u64 {
    var w: u64 = 0;
    const bytes = std.mem.asBytes(v);
    const n = @min(@as(usize, 8), bytes.len - off);
    @memcpy(std.mem.asBytes(&w)[0..n], bytes[off..][0..n]);
    return w;
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

/// Fill every LAYOUT field of `out` from the live runtime structs.
/// The policy gates come back as pure probe results (`usable`/`obj_usable`
/// = 1, `span_usable` = the probe's verdict); the runtime caller ANDs its
/// own policy (reclaim mode, `KLIO_OBJVIEW`) on top, and the emit-time
/// caller ignores them (frozen constants carry layout only).
pub fn fillLayout(out: *HotLayout) void {
    const t = tagOffset();
    var vi: runtime.Value = undefined;
    var vl: runtime.Value = undefined;
    var vb: runtime.Value = undefined;
    var vu: runtime.Value = undefined;
    var vc: runtime.Value = undefined;
    var vinst: runtime.Value = undefined;
    var vai: runtime.Value = undefined;
    @memset(std.mem.asBytes(&vi), 0);
    @memset(std.mem.asBytes(&vl), 0);
    @memset(std.mem.asBytes(&vb), 0);
    @memset(std.mem.asBytes(&vu), 0);
    @memset(std.mem.asBytes(&vc), 0);
    @memset(std.mem.asBytes(&vinst), 0);
    vinst = .{ .Instance = undefined };
    @memset(std.mem.asBytes(&vai), 0);
    vai = .{ .Array = .{ .cell = @ptrFromInt(0x1000), .prim = .Int } };
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
        .usable = 1,
        .span_usable = sp.usable,
        .span_file_off = sp.file_off,
        .span_start_off = sp.start_off,
        .span_end_off = sp.end_off,
        .span_tag_off = sp.tag_off,
        .span_tag_set = sp.tag_set,
        .char_off = @intCast(@intFromPtr(&vc.Char) - @intFromPtr(&vc)),
        .tag_char = readTag(&vc, t.off, t.size),
        .obj_usable = 1,
        .tag_instance = @intFromEnum(@as(std.meta.Tag(runtime.Value), .Instance)),
        .inst_ptr_off = @intCast(@intFromPtr(&vinst.Instance) - @intFromPtr(&vinst)),
        .cell_data_off = @offsetOf(InstCell, "data"),
        .inst_class_off = @offsetOf(runtime.InstanceData, "class"),
        .inst_fields_off = @offsetOf(runtime.InstanceData, "fields"),
        .fields_ptr_off = @offsetOf(FieldList, "items") + SLICE_PTR_OFF,
        .fields_len_off = @offsetOf(FieldList, "items") + SLICE_LEN_OFF,
        .field_stride = @sizeOf(runtime.InstanceData.Field),
        .field_value_off = @offsetOf(runtime.InstanceData.Field, "value"),
        .tag_array = @intFromEnum(@as(std.meta.Tag(runtime.Value), .Array)),
        .arr_cell_off = @intCast(@intFromPtr(&vai.Array.cell) - @intFromPtr(&vai)),
        .arr_prim_off = @intCast(@intFromPtr(&vai.Array.prim) - @intFromPtr(&vai)),
        .arr_prim_int_word = readWord(&vai, @intCast(@intFromPtr(&vai.Array.prim) - @intFromPtr(&vai))),
        .primbuf_ptr_off = @offsetOf(PrimBufCell, "data") + @offsetOf(runtime.PrimBuf, "bytes") + SLICE_PTR_OFF,
        .primbuf_len_off = @offsetOf(PrimBufCell, "data") + @offsetOf(runtime.PrimBuf, "bytes") + SLICE_LEN_OFF,
    };
}

/// Whether every LAYOUT field of `frozen` matches `live` (the policy
/// gates are excluded — they are runtime decisions, not layout).
pub fn layoutMatches(frozen: *const HotLayout, live: *const HotLayout) bool {
    inline for (@typeInfo(HotLayout).@"struct".fields) |f| {
        comptime if (std.mem.eql(u8, f.name, "usable") or
            std.mem.eql(u8, f.name, "obj_usable") or
            std.mem.eql(u8, f.name, "span_usable")) continue;
        if (@field(frozen, f.name) != @field(live, f.name)) return false;
    }
    return true;
}

test "fillLayout probes a coherent scalar layout" {
    var l: HotLayout = undefined;
    fillLayout(&l);
    try std.testing.expectEqual(@as(u32, @sizeOf(runtime.Value)), l.value_size);
    try std.testing.expect(l.tag_size >= 1 and l.tag_size <= 8);
    try std.testing.expect(l.tag_int != l.tag_long);
    try std.testing.expect(l.tag_int != l.tag_bool);
    try std.testing.expect(l.int_off < l.value_size);
    try std.testing.expect(l.long_off + 8 <= l.value_size);
    try std.testing.expectEqual(@as(u8, 1), l.usable);
    var l2: HotLayout = undefined;
    fillLayout(&l2);
    try std.testing.expect(layoutMatches(&l, &l2));
}
