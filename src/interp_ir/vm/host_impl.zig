//! `VmHost` lifecycle helpers that are not host-dispatch methods:
//! on-demand top-level property init, spawned-thread join, and the
//! spawned-thread liveness check.
//!
//! In Rust the `impl Host for VmHost` glue lived here; in Zig the IR
//! evaluator is generic over its host type and `vmhost.zig` aliases the
//! per-operation free functions over `*VmHost` as `VmHost` methods, so
//! this file holds the inherent free functions that are not part of that
//! dispatch surface.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const vmhost = @import("vmhost.zig");
const VmHost = vmhost.VmHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalError = ir.eval.EvalError;

/// `Result<?Value, EvalError>` for `ensureTopLevelInited`.
pub const MaybeValueResult = ir.eval.MaybeValueResult;

/// Top-level property initializers currently executing on this thread —
/// breaks initializer cycles, mirroring Rust's `IN_PROGRESS` thread-local.
/// Stores the program-image-owned key slices (run-stable, shared by the
/// `prog` handle), so the entries outlive the borrowed `name` slice without
/// per-key duplication. Page-allocator backed and cleared capacity-retaining
/// like the sibling resolution guards, so it leaks nothing across runs.
threadlocal var in_progress: std.ArrayListUnmanaged([]const u8) = .empty;

/// Assert (Debug) the in-progress top-level-init set is empty at a run
/// boundary and clear it capacity-retaining, so state leaked across runs is a
/// loud failure rather than silently threaded into the next run.
pub fn resetReceiverTls() void {
    std.debug.assert(in_progress.items.len == 0);
    in_progress.clearRetainingCapacity();
}

/// True when `name` is already initializing on this thread's stack.
fn inProgressContains(name: []const u8) bool {
    for (in_progress.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Clears a top-level property name from the in-progress set when an
/// on-demand initializer returns, breaking re-entrant init cycles. Removes
/// the matching key by identity (the run-stable key, not a fresh copy).
const InitGuard = struct {
    key: []const u8,

    fn release(self: InitGuard) void {
        var i: usize = in_progress.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, in_progress.items[i], self.key)) {
                _ = in_progress.orderedRemove(i);
                return;
            }
        }
    }
};

/// Drive a top-level property's initializer on demand when it is read
/// before the in-order startup pass has reached it (an earlier top-level
/// initializer constructs a class whose body reads a property declared
/// later). Returns the value (also cached into `globals` so the later
/// startup pass and subsequent reads are consistent), or `null` if `name`
/// is not a top-level property. A thread-local guard breaks initializer
/// cycles: a re-entrant read returns `null`, matching the JVM static-field
/// zero/null default rather than recursing.
pub fn ensureTopLevelInited(self: *VmHost, name: []const u8) Allocator.Error!MaybeValueResult {
    {
        const g = self.globals.borrow();
        defer g.deinit();
        if (g.get().lookup(name)) |v| {
            return .{ .ok = v };
        }
    }
    const init = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        const inits = &pg.get().top_level_prop_inits;
        const fid = inits.get(name) orelse return .{ .ok = null };
        // The program-image key is run-stable (shared by the `prog` handle),
        // so it outlives this guard frame without a per-key copy.
        break :blk .{ .fid = fid, .key = inits.getKey(name) orelse name };
    };
    const fid = init.fid;
    const init_key = init.key;
    if (inProgressContains(init_key)) {
        return .{ .ok = null };
    }
    in_progress.append(std.heap.page_allocator, init_key) catch {};
    const guard = InitGuard{ .key = init_key };
    defer guard.release();

    const func = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (fid.int() >= m.funcs.items.len) {
            const msg = try std.fmt.allocPrint(self.allocator, "top-level prop init FuncId {d} out of range", .{fid.int()});
            return .{ .err = .{ .Type = msg } };
        }
        break :blk &m.funcs.items[fid.int()];
    };
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    vmhost.emitPath(self.allocator, "top_level_init", func.fqn, fid, null, &.{});
    const r = try ir.eval.evalWith(VmHost, self.allocator, mg.get(), func, .empty, self);
    switch (r) {
        .ok => |v| {
            const g = self.globals.borrowMut();
            defer g.deinit();
            g.get().define(name, v) catch {};
            return .{ .ok = v };
        },
        .err => |e| return .{ .err = e },
    }
}

/// `Result<void, RuntimeError>` for the join helpers.
pub const JoinResult = union(enum) { ok: void, err: RuntimeError };

/// Join the spawned OS thread `id`, propagating a thrown Throwable as a
/// `RuntimeError`. Idempotent: a second join (or an unknown id) is a no-op
/// since the happens-before edge was already established. The join() below
/// is itself the memory-model boundary.
pub fn joinSpawned(self: *VmHost, id: u64) JoinResult {
    const handle = blk: {
        const g = self.threads.borrowMut();
        defer g.deinit();
        const entry = g.get().getPtr(id) orelse break :blk null;
        const h = entry.handle;
        entry.handle = null;
        break :blk h;
    };
    const h = handle orelse return .{ .ok = {} };
    // join() establishes happens-before with the worker's writes.
    h.join();
    const g = self.threads.borrow();
    defer g.deinit();
    const entry = g.get().getPtr(id) orelse return .{ .ok = {} };
    return switch (entry.result orelse .ok) {
        .ok => .{ .ok = {} },
        .err => |e| .{ .err = e },
    };
}

/// Whether spawned thread `id` is still running.
pub fn threadAlive(self: *VmHost, id: u64) bool {
    const g = self.threads.borrow();
    defer g.deinit();
    const entry = g.get().getPtr(id) orelse return false;
    return entry.handle != null and !entry.finished.load(.acquire);
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}
