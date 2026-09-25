//! The evaluation depth cap.

const std = @import("std");
const runtime = @import("runtime");



const ev_state = @import("state.zig");

const DEFAULT_MAX_EVAL_DEPTH = ev_state.DEFAULT_MAX_EVAL_DEPTH;

pub fn maxEvalDepth() usize {
    if (ev_state.evtlsPtr().eval_depth_cap != 0) return ev_state.evtlsPtr().eval_depth_cap;
    // `procEnvGetVar` reads the whole environment block into the scratch allocator, so a fixed buffer would fail.
    const a = std.heap.page_allocator;
    const cap = blk: {
        const raw = runtime.procEnvGetVar(a, "KLIO_MAX_EVAL_DEPTH") catch break :blk DEFAULT_MAX_EVAL_DEPTH;
        const v = raw orelse break :blk DEFAULT_MAX_EVAL_DEPTH;
        defer a.free(v);
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        const parsed = std.fmt.parseInt(usize, trimmed, 10) catch break :blk DEFAULT_MAX_EVAL_DEPTH;
        if (parsed == 0) break :blk DEFAULT_MAX_EVAL_DEPTH;
        break :blk parsed;
    };
    ev_state.evtlsPtr().eval_depth_cap = cap;
    return cap;
}
