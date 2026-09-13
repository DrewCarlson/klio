//! The enclosing-receiver chain: the implicit receivers an expression sees
//! from the frames above it.

const std = @import("std");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;
const InstanceData = runtime.InstanceData;

const ev_state = @import("state.zig");

const DEFAULT_MAX_EVAL_DEPTH = ev_state.DEFAULT_MAX_EVAL_DEPTH;
const EnclosingEntry = ev_state.EnclosingEntry;
const EvalTls = ev_state.EvalTls;

/// Iterate the pushed enclosing receivers, innermost first. The values are borrowed from the live chain.
pub const EnclosingChainIter = struct {
    idx: usize,
    pub fn next(self: *EnclosingChainIter) ?Value {
        const chain = ev_state.evtls.active_chain orelse return null;
        while (self.idx > 0) {
            self.idx -= 1;
            const e = chain.items[self.idx];
            if (e.kind == .receiver or e.kind == .subject) return e.v;
        }
        return null;
    }
};

pub fn enclosingChainIter() EnclosingChainIter {
    const chain = ev_state.evtls.active_chain orelse return .{ .idx = 0 };
    return .{ .idx = chain.items.len };
}

/// Push an implicit receiver for the about-to-be-invoked callable, which picks it up at entry. A no-op when no frame is active.
pub fn pushEnclosing(v: *const Value) void {
    const chain = ev_state.evtls.active_chain orelse return;
    chain.append(chainAllocator(), .{ .v = v.*, .kind = .receiver }) catch {};
}

/// Push a receiver-lambda subject (`with(x) { … }`'s `x`): a receiver inside the lambda body, but its `outer` links are not.
pub fn pushEnclosingSubject(v: *const Value) void {
    const chain = ev_state.evtls.active_chain orelse return;
    chain.append(chainAllocator(), .{ .v = v.*, .kind = .subject }) catch {};
}

/// Push `v` for dispatch-time visibility only; the entry never enters a callee frame's lexical receiver scope.
pub fn pushEnclosingAccess(v: *const Value) void {
    const chain = ev_state.evtls.active_chain orelse return;
    chain.append(chainAllocator(), .{ .v = v.*, .kind = .access }) catch {};
}

/// Pop the most recent push. A no-op when no frame is active or the chain is empty.
pub fn popEnclosing() void {
    const chain = ev_state.evtls.active_chain orelse return;
    if (chain.items.len > 0) _ = chain.pop();
}

/// The innermost enclosing `this`, or `null` when the chain is empty.
pub fn enclosingThisLast() ?Value {
    const chain = ev_state.evtls.active_chain orelse return null;
    if (chain.items.len == 0) return null;
    return chain.items[chain.items.len - 1].v;
}

/// The enclosing-`this` chain, innermost first. Caller owns the returned slice.
pub fn enclosingThisChainAlloc(allocator: Allocator) Allocator.Error![]Value {
    const chain = ev_state.evtls.active_chain orelse return allocator.alloc(Value, 0);
    var out = try allocator.alloc(Value, chain.items.len);
    var i: usize = 0;
    while (i < chain.items.len) : (i += 1) {
        out[i] = chain.items[chain.items.len - 1 - i].v;
    }
    return out;
}

/// Fold the chain's shape (entry kinds plus receiver class identities) into a hash, without allocating.
/// Keys chain-dependent resolutions in the extension cache: identical shapes resolve identically.
pub fn enclosingChainClassHash() u64 {
    var h = std.hash.Wyhash.init(0x8f14e45fceea167a);
    if (ev_state.evtls.active_chain) |chain| {
        for (chain.items) |e| {
            const kb: u8 = @intFromEnum(e.kind);
            h.update((&kb)[0..1]);
            var k: u64 = undefined;
            if (e.v == .Instance) {
                k = @intCast(runtime.InstanceData.classIdentityUnlocked(e.v.Instance));
            } else {
                k = @as(u64, @intFromEnum(std.meta.activeTag(e.v))) +% 0x2b8c;
            }
            h.update(std.mem.asBytes(&k));
        }
    }
    return h.final() | 1;
}

/// The enclosing-`this` chain with subject tags, innermost first. Caller owns the returned slice.
pub fn enclosingEntriesAlloc(allocator: Allocator) Allocator.Error![]EnclosingEntry {
    const chain = ev_state.evtls.active_chain orelse return allocator.alloc(EnclosingEntry, 0);
    var out = try allocator.alloc(EnclosingEntry, chain.items.len);
    var i: usize = 0;
    while (i < chain.items.len) : (i += 1) {
        out[i] = chain.items[chain.items.len - 1 - i];
    }
    return out;
}

/// The receivers a closure created here lexically sees (storage order innermost last, `access` entries excluded):
/// Kotlin resolves bare names at the creation site, so this seeds every later body frame. Caller owns the slice.
pub fn captureChainAlloc(allocator: Allocator) Allocator.Error![]EnclosingEntry {
    var out: std.ArrayList(EnclosingEntry) = .empty;
    errdefer out.deinit(allocator);
    if (ev_state.evtls.active_chain) |chain| {
        for (chain.items) |e| {
            if (e.kind == .access) continue;
            try out.append(allocator, e);
        }
    }
    // The creating function's own receiver (`this`, params[0]) is the innermost lexical receiver at the literal, yet it lives in the frame's params, not on the chain.
    if (ev_state.evtls.frame_chain) |fr| {
        if (fr.func.params.len != 0 and std.mem.eql(u8, fr.func.params[0].name, "this") and
            fr.params.items.len != 0)
        {
            const own = fr.params.items[0];
            const dup = blk: {
                if (out.items.len == 0) break :blk false;
                const last = out.items[out.items.len - 1].v;
                if (last == .Instance and own == .Instance)
                    break :blk last.Instance.identity() == own.Instance.identity();
                break :blk false;
            };
            if (!dup and own != .Null and own != .Unit) {
                try out.append(allocator, .{ .v = own, .kind = .receiver });
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn traceEnclosingEntries(label: []const u8, entries: []const EnclosingEntry) void {
    std.debug.print("[{s}]", .{label});
    for (entries, 0..) |e, i| {
        if (e.v == .Instance) {
            const ig = e.v.Instance.borrow();
            const cg = ig.get().class.borrow();
            std.debug.print(" [{d}]{s}/{s}", .{ i, cg.get().name, @tagName(e.kind) });
            cg.deinit();
            ig.deinit();
        } else {
            std.debug.print(" [{d}]{s}/{s}", .{ i, @tagName(e.v), @tagName(e.kind) });
        }
    }
    std.debug.print("\n", .{});
}

/// Backing allocator for a frame's `enclosing_this` chain: the process-wide slab, since a suspend snapshot copies the chain and can outlive the per-call arena.
pub fn chainAllocator() Allocator {
    return runtime.slab.allocator;
}

/// Per-thread free list of chain buffers; the backing is process-global, so a recycled buffer is safe for any later frame on this thread.
pub const CHAIN_POOL_MAX: usize = 128;

pub fn chainAcquire(ev: *EvalTls) std.ArrayList(EnclosingEntry) {
    if (ev.chain_pool_len > 0) {
        ev.chain_pool_len -= 1;
        const buf = ev.chain_pool[ev.chain_pool_len];
        return .{ .items = buf[0..0], .capacity = buf.len };
    }
    return .empty;
}

pub fn chainRelease(ev: *EvalTls, list: *std.ArrayList(EnclosingEntry)) void {
    if (list.capacity > 0 and ev.chain_pool_len < CHAIN_POOL_MAX) {
        ev.chain_pool[ev.chain_pool_len] = list.allocatedSlice();
        ev.chain_pool_len += 1;
        list.* = .empty;
        return;
    }
    list.deinit(chainAllocator());
}

pub fn maxEvalDepth() usize {
    if (ev_state.evtls.eval_depth_cap != 0) return ev_state.evtls.eval_depth_cap;
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
    ev_state.evtls.eval_depth_cap = cap;
    return cap;
}
