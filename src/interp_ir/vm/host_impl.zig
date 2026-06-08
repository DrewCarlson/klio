//! `VmHost` lifecycle helpers that are not part of the `ir.eval.Host`
//! vtable: on-demand top-level property init, spawned-thread join, and
//! the spawned-thread liveness check.
//!
//! In Rust the `impl Host for VmHost` glue lived here; in Zig that glue
//! is the vtable wiring in `vmhost.zig`, so this file holds the inherent
//! free functions over `*VmHost` instead.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const VmHost = @import("vmhost.zig").VmHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalError = ir.eval.EvalError;

/// `Result<?Value, EvalError>` for `ensureTopLevelInited`.
pub const MaybeValueResult = ir.eval.MaybeValueResult;

/// Top-level property initializers currently executing on this thread —
/// breaks initializer cycles, mirroring Rust's `IN_PROGRESS` thread-local.
/// Owns its key copies (allocated from `std.heap.page_allocator`, like the
/// owned `String` Rust pushed) so they outlive the borrowed `name` slice.
threadlocal var in_progress: std.StringHashMapUnmanaged(void) = .empty;

/// Clears a top-level property name from the in-progress set when an
/// on-demand initializer returns, breaking re-entrant init cycles.
const InitGuard = struct {
    name: []const u8,

    fn release(self: InitGuard) void {
        if (in_progress.fetchRemove(self.name)) |kv| {
            std.heap.page_allocator.free(kv.key);
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
    const fid = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().top_level_prop_inits.get(name) orelse return .{ .ok = null };
    };
    if (in_progress.contains(name)) {
        return .{ .ok = null };
    }
    const owned = try std.heap.page_allocator.dupe(u8, name);
    try in_progress.put(std.heap.page_allocator, owned, {});
    const guard = InitGuard{ .name = owned };
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
    var iface = self.hostInterface();
    const r = try ir.eval.evalWith(self.allocator, mg.get(), func, .empty, &iface);
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
