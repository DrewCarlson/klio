//! `VmHost` lifecycle helpers outside the host-dispatch surface `vmhost.zig`
//! aliases: on-demand top-level property init, spawned-thread join and liveness.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const build = @import("../build.zig");
const vmhost = @import("vmhost.zig");
const VmHost = vmhost.VmHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalError = ir.eval.EvalError;

pub const MaybeValueResult = ir.eval.MaybeValueResult;

/// True while the startup pass runs the top-level initializers in file order here.
/// Inside the window a forward read takes the declared type's default, as `<clinit>` does.
threadlocal var startup_inits_active: bool = false;

/// Properties whose startup turn came and deferred to on-access driving, so they keep
/// the drive path. Holds run-stable `top_level_props` name slices for the window only.
threadlocal var startup_deferred: std.ArrayList([]const u8) = .empty;

/// Set by `vmRunBody` around the in-order top-level init loop.
pub fn setStartupInitsActive(active: bool) void {
    startup_inits_active = active;
    if (!active) startup_deferred.clearRetainingCapacity();
}

pub fn noteStartupDeferred(name: []const u8) void {
    startup_deferred.append(std.heap.page_allocator, name) catch {};
}

/// The declared type's pre-init default for a top-level property read before its
/// initializer runs; null outside the window or with no usable annotation.
pub fn pendingTypedDefault(self: *VmHost, name: []const u8) ?Value {
    if (!startup_inits_active) return null;
    for (startup_deferred.items) |n| {
        if (std.mem.eql(u8, n, name)) return null;
    }
    const pg = self.prog.borrow();
    defer pg.deinit();
    const entry = pg.get().top_level_prop_inits.get(name) orelse return null;
    // Default only a same-file forward read, whose `<clinit>` is already running: a prop
    // whose file clinit has not started is a cross-file dependency Kotlin forces, so
    // drive it instead.
    if (!inProgressFileContains(entry.file)) return null;
    return typedDefaultValue(entry.default);
}

/// Null for `.none`: no annotation to default from.
fn typedDefaultValue(kind: build.TypedDefault) ?Value {
    return switch (kind) {
        .none => null,
        .int => .{ .Int = 0 },
        .long => .{ .Long = 0 },
        .short => .{ .Short = 0 },
        .byte => .{ .Byte = 0 },
        .uint => .{ .UInt = 0 },
        .ulong => .{ .ULong = 0 },
        .ushort => .{ .UShort = 0 },
        .ubyte => .{ .UByte = 0 },
        .boolean => .{ .Bool = false },
        .char => .{ .Char = 0 },
        .float => .{ .Float = 0.0 },
        .double => .{ .Double = 0.0 },
        .null_ref => .Null,
    };
}

/// Top-level property initializers executing on this thread, which breaks init cycles.
/// Keys are program-image-owned slices, so an entry outlives a borrowed `name`.
threadlocal var in_progress: std.ArrayList([]const u8) = .empty;

/// FileIds whose top-level `<clinit>` is running on this thread. Kotlin initializes
/// top-level `val`s per FILE, lazily on first access: a prop whose file clinit already
/// runs takes the declared-type default, one whose clinit has not started is driven.
threadlocal var in_progress_files: std.ArrayList(u32) = .empty;

fn inProgressFileContains(file: u32) bool {
    for (in_progress_files.items) |f| {
        if (f == file) return true;
    }
    return false;
}

/// Mark a prop as initializing, so a re-entrant drive of the same file skips it.
pub fn pushInitProp(name: []const u8) void {
    in_progress.append(std.heap.page_allocator, name) catch {};
}

pub fn popInitProp(name: []const u8) void {
    (InitGuard{ .key = name }).release();
}

pub fn pushInitFile(file: u32) void {
    in_progress_files.append(std.heap.page_allocator, file) catch {};
}

pub fn popInitFile(file: u32) void {
    var i: usize = in_progress_files.items.len;
    while (i > 0) {
        i -= 1;
        if (in_progress_files.items[i] == file) {
            _ = in_progress_files.orderedRemove(i);
            return;
        }
    }
}

/// Assert (Debug) the in-progress init set is empty at a run boundary, then clear it.
pub fn resetReceiverTls() void {
    std.debug.assert(in_progress.items.len == 0);
    in_progress.clearRetainingCapacity();
    in_progress_files.clearRetainingCapacity();
}

fn inProgressContains(name: []const u8) bool {
    for (in_progress.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Matches the run-stable key rather than a fresh copy.
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

/// Drive a top-level property's initializer on demand, caching into `globals`. Null for
/// a non-top-level name or a re-entrant read inside a cycle.
pub fn ensureTopLevelInited(self: *VmHost, name: []const u8) Allocator.Error!MaybeValueResult {
    {
        const g = self.globals.borrow();
        defer g.deinit();
        if (g.get().lookup(name)) |v| {
            return .{ .ok = v };
        }
    }
    // A pre-init forward read takes the declared-type default and stays queued.
    if (pendingTypedDefault(self, name)) |d| return .{ .ok = d };
    const file: u32 = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        const entry = pg.get().top_level_prop_inits.get(name) orelse return .{ .ok = null };
        break :blk entry.file;
    };
    // Drive `name`'s file `<clinit>`: every top-level prop of that file in declaration
    // order, so an earlier prop is assigned before a later one reads it. Kotlin runs a
    // whole facade `<clinit>` on access to any of its top-level members.
    pushInitFile(file);
    defer popInitFile(file);
    const props = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().top_level_props_ordered;
    };
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const m = mg.get();
    for (props) |nf| {
        if (nf.file != file) continue;
        {
            const g = self.globals.borrow();
            const done = g.get().lookup(nf.name) != null;
            g.deinit();
            if (done) continue;
        }
        // A prop initializer re-reading its own name: leave it null, do not recurse.
        if (inProgressContains(nf.name)) continue;
        in_progress.append(std.heap.page_allocator, nf.name) catch {};
        const guard = InitGuard{ .key = nf.name };
        defer guard.release();
        const func = m.funcById(nf.func) orelse continue;
        vmhost.emitPath(self.allocator, "top_level_init", func.fqn, nf.func, null, &.{});
        const r = try ir.eval.evalWith(VmHost, self.allocator, m, func, .empty, self);
        switch (r) {
            .ok => |v| {
                const g = self.globals.borrowMut();
                defer g.deinit();
                g.get().define(nf.name, v) catch {};
            },
            .err => |e| return .{ .err = e },
        }
    }
    {
        const g = self.globals.borrow();
        defer g.deinit();
        if (g.get().lookup(name)) |v| return .{ .ok = v };
    }
    return .{ .ok = null };
}

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
