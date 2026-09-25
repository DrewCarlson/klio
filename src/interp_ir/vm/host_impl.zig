//! A spawned OS thread's join, name and liveness, which `Thread`'s members
//! the host implements read.

const std = @import("std");

const runtime = @import("runtime");

const vmhost = @import("vmhost.zig");
const VmHost = vmhost.VmHost;

const RuntimeError = runtime.RuntimeError;

pub const JoinResult = union(enum) { ok: void, err: RuntimeError };

/// Join the spawned OS thread `id`, propagating a thrown Throwable; a repeat is a no-op.
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
    // join() establishes happens-before with the worker's writes. The joining
    // thread is blocked, so it counts as parked for a collection the worker
    // starts; otherwise the collector waits on it forever.
    runtime.gc.enterBlockingSafe();
    h.join();
    runtime.gc.exitBlockingSafe();
    const g = self.threads.borrow();
    defer g.deinit();
    const entry = g.get().getPtr(id) orelse return .{ .ok = {} };
    return switch (entry.result orelse .ok) {
        .ok => .{ .ok = {} },
        .err => |e| .{ .err = e },
    };
}

/// The name `thread { }` handle `id` was started with.
pub fn threadNameOf(self: *VmHost, id: u64) ?[]const u8 {
    const g = self.threads.borrow();
    defer g.deinit();
    const entry = g.get().getPtr(id) orelse return null;
    return if (entry.name.len != 0) entry.name else null;
}

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
