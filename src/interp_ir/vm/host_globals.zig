//! `VmHost` global resolution: top-level name reads and writes, the throwing
//! read variant, the lazy first-access `object` / companion init gate, and
//! the shadowing-capture check. Free functions over `*VmHost`, aliased as
//! `VmHost` methods by `vmhost.zig`.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const vmhost = @import("vmhost.zig");
const host_impl = @import("host_impl.zig");
const host_instances = @import("host_instances.zig");
const trace = @import("trace.zig");
const host_call_member = @import("host_call_member.zig");

const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const StringRef = runtime.StringRef;
const DelegateKind = runtime.DelegateKind;
const RuntimeError = runtime.RuntimeError;
const CallCtx = runtime.CallCtx;
const StdlibFn = runtime.StdlibFn;
const ValueSlice = runtime.ValueSlice;
const IrClosureRef = runtime.IrClosureRef;

const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalError = ir.eval.EvalError;
const MaybeValueResult = ir.eval.MaybeValueResult;
const UnitResult = ir.eval.UnitResult;
const SuspendState = ir.eval.SuspendState;

// Kotlin initializes an `object` at its first access and a companion at the
// first instantiation of its owning class, exactly once across all threads.
// Every singleton read routes through `ensureObjectSingleton`, never `globals`
// directly; the `object_states` writer lock serializes the claim, so a racer
// waits and a re-entrant read sees the in-flight instance. Failure is terminal:
// later accesses throw `FileFailedToInitializeException` with no cause.

const ObjectInitState = root.ObjectInitState;

/// Thrown when an `object` / companion initializer fails, named after the
/// kotlinc exception. `Error`-side: `catch (e: Exception)` does not match it.
pub const FILE_INIT_FAILED_FQN = "kotlin.native.internal.FileFailedToInitializeException";
const FILE_INIT_FAILED_MSG = "There was an error during file or class initialization";

/// `KLIO_INIT_DEBUG` trace of the raw error that failed an initializer.
fn initDebugLog(name: []const u8, e: EvalError) void {
    if (runtime.envOnce("KLIO_INIT_DEBUG") == null) return;
    switch (e) {
        .Throw => |t| switch (t) {
            .Exception => |ex| {
                const fg = ex.fqn.borrow();
                defer fg.deinit();
                std.debug.print("[init-debug] {s} FAILED: throw {s}", .{ name, fg.get().bytes });
                if (ex.message.get()) |m| {
                    const mg = m.borrow();
                    defer mg.deinit();
                    std.debug.print(": {s}", .{mg.get().bytes});
                }
                std.debug.print("\n", .{});
            },
            .Instance => |inst| {
                const g = inst.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                std.debug.print("[init-debug] {s} FAILED: throw instance {s}\n", .{ name, cg.get().fqn });
            },
            else => std.debug.print("[init-debug] {s} FAILED: throw <value>\n", .{name}),
        },
        .Unbound => |s| std.debug.print("[init-debug] {s} FAILED: Unbound `{s}`\n", .{ name, s }),
        .CalleeFailed => |s| std.debug.print("[init-debug] {s} FAILED: CalleeFailed `{s}`\n", .{ name, s }),
        .Unimplemented => |s| std.debug.print("[init-debug] {s} FAILED: Unimplemented `{s}`\n", .{ name, s }),
        .Type => |s| std.debug.print("[init-debug] {s} FAILED: Type `{s}`\n", .{ name, s }),
        .Unsupported => |s| std.debug.print("[init-debug] {s} FAILED: Unsupported `{s}`\n", .{ name, s }),
        else => std.debug.print("[init-debug] {s} FAILED: eval error {s}\n", .{ name, @tagName(e) }),
    }
}

fn fileInitFailedThrow(allocator: Allocator, cause: ?Value) Allocator.Error!EvalError {
    const fqn = try runtime.strInit(allocator, FILE_INIT_FAILED_FQN);
    const msg = try runtime.strInit(allocator, FILE_INIT_FAILED_MSG);
    const cause_box = if (cause) |c| (try Value.boxRef(allocator, c)).cell else null;
    return .{ .Throw = try Value.newException(allocator, .{ .fqn = fqn, .message = .from(msg), .cause = cause_box }) };
}

const ClaimOutcome = union(enum) {
    construct,
    /// Already constructing on this thread; the in-flight instance, if any.
    reentrant: ?Value,
    wait,
    /// A previous construction failed; the cause is taken once.
    failed: ?Value,
};

fn objectInitOwner(self: *VmHost, key: []const u8) ?std.Thread.Id {
    const g = self.object_states.borrow();
    defer g.deinit();
    if (g.get().getPtr(key)) |entry| {
        if (entry.* == .InProgress) return entry.InProgress.thread;
    }
    return null;
}

fn claimObjectInit(self: *VmHost, key: []const u8) ClaimOutcome {
    const tid = std.Thread.getCurrentId();
    const g = self.object_states.borrowMut();
    defer g.deinit();
    if (g.get().getPtr(key)) |entry| {
        switch (entry.*) {
            .InProgress => |ip| {
                if (ip.thread == tid) return .{ .reentrant = ip.instance };
                return .wait;
            },
            .Failed => |*f| {
                const c = f.cause;
                f.cause = null;
                if (runtime.envOnce("KLIO_INIT_DEBUG") != null)
                    std.debug.print("[init-debug] {s} failed-take cause={}\n", .{ key, c != null });
                return .{ .failed = c };
            },
        }
    }
    g.get().put(key, .{ .InProgress = .{ .thread = tid, .instance = null } }) catch return .wait;
    return .construct;
}

/// Record the in-flight instance shell so re-entrant reads through the rest
/// of construction see it. False when no entry exists: the caller publishes.
pub fn noteObjectInFlight(self: *VmHost, name: []const u8, instance: Value) bool {
    const tid = std.Thread.getCurrentId();
    const g = self.object_states.borrowMut();
    defer g.deinit();
    if (g.get().getPtr(name)) |entry| {
        if (entry.* == .InProgress and entry.InProgress.thread == tid) {
            entry.InProgress.instance = instance;
            return true;
        }
    }
    return false;
}

fn singletonFromSharedRegistry(self: *VmHost, name: []const u8) ?Value {
    const class_id = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classId(name) orelse return null;
    };
    const sg = self.singletons_by_id.borrow();
    defer sg.deinit();
    if (sg.get().get(class_id.int())) |v| {
        if (v == .Instance) return v;
    }
    return null;
}

/// Resolve a registered `object` / companion singleton by its lifted global
/// name, constructing on first access. `.ok = null` when `name` is no
/// registered object, or is mid-construction here with no shell yet.
pub fn ensureObjectSingleton(self: *VmHost, raw_name: []const u8) Allocator.Error!MaybeValueResult {
    const allocator = self.allocator;
    {
        const g = self.globals.borrow();
        defer g.deinit();
        if (g.get().lookup(raw_name)) |v| {
            if (v == .Instance) return .{ .ok = v };
        }
    }
    // Canonicalize to the run-stable image key: the entry outlives the call.
    const name = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().object_names.getKey(raw_name) orelse return .{ .ok = null };
    };
    // `globals` can be a transient per-context scope, so the id-keyed registry
    // is authoritative: skip it and each scope builds its own, breaking `===`.
    if (singletonFromSharedRegistry(self, name)) |v| return .{ .ok = v };
    var wait_rounds: u32 = 0;
    while (true) {
        {
            const g = self.globals.borrow();
            defer g.deinit();
            if (g.get().lookup(name)) |v| {
                if (v == .Instance) return .{ .ok = v };
            }
        }
        switch (claimObjectInit(self, name)) {
            .construct => {},
            .reentrant => |inst| return .{ .ok = inst },
            .failed => |stashed| return .{ .err = try fileInitFailedThrow(allocator, stashed) },
            // Unbounded wait on interpreted init: park 1ms, GC-safe.
            .wait => {
                wait_rounds +|= 1;
                if (wait_rounds <= 64) {
                    std.Thread.yield() catch {};
                } else {
                    if (wait_rounds == 2000 and runtime.envOnce("KLIO_ERR_TRACE") != null) {
                        std.debug.print("[init-wait] {s} owner={?d} self={d}\n", .{ name, objectInitOwner(self, name), std.Thread.getCurrentId() });
                        runtime.trace.dumpCurrent(.{});
                    }
                    runtime.clockSleepMillis(1);
                }
                continue;
            },
        }
        // Re-check `globals` after winning the claim: a finisher publishes then
        // clears, and the claim's acquire orders after that clear.
        {
            const published: ?Value = blk: {
                const g = self.globals.borrow();
                defer g.deinit();
                break :blk g.get().lookup(name);
            };
            if (published) |v| {
                if (v == .Instance) {
                    clearObjectState(self, name);
                    return .{ .ok = v };
                }
            }
        }
        break;
    }

    // This thread owns the claim: every exit must resolve the entry.
    const class_id_opt: ?ir.ClassId = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classId(name);
    };
    const class_id = class_id_opt orelse {
        clearObjectState(self, name);
        return .{ .ok = null };
    };
    // An object singleton is never abstract: such a pick is a collision with a
    // nested object the flat index cannot rank. Decline; the scope walk goes on.
    {
        const bad = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const m = mg.get();
            if (class_id.int() >= m.classes.items.len) break :blk true;
            const c = &m.classes.items[class_id.int()];
            break :blk c.is_abstract;
        };
        if (bad) {
            clearObjectState(self, name);
            return .{ .ok = null };
        }
    }

    if (try enumOwnerInitForCompanion(self, name)) |e| {
        clearObjectState(self, name);
        return .{ .err = e };
    }
    const r = self.newInstance(allocator, class_id, &.{}, null) catch |e| {
        clearObjectState(self, name);
        return e;
    };
    switch (r) {
        .ok => |inst| {
            if (inst != .Instance) {
                clearObjectState(self, name);
                return .{ .ok = inst };
            }
            // A companion's `outer` is its enclosing class, for its statics.
            if (std.mem.find(u8, name, "$Companion$")) |sep| {
                const outer_name = name[0..sep];
                const outer_def: ?ObjRef(ClassDef) = blk: {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    if (cg.get().get(outer_name)) |c| break :blk c.clone();
                    break :blk null;
                };
                if (outer_def) |od| {
                    const ig = inst.Instance.borrowMut();
                    defer ig.deinit();
                    ig.get().outer = .{ .Class = od };
                }
            }
            // Publish before clearing, so a waiter always finds the singleton.
            {
                const sg = self.singletons_by_id.borrowMut();
                defer sg.deinit();
                sg.get().put(class_id.int(), inst) catch {};
            }
            {
                const g = self.globals.borrowMut();
                defer g.deinit();
                g.get().define(name, inst) catch {};
            }
            clearObjectState(self, name);
            return .{ .ok = inst };
        },
        .err => |e| {
            initDebugLog(name, e);
            markObjectFailed(self, name, null);
            switch (e) {
                .Throw => |cause| return .{ .err = try fileInitFailedThrow(allocator, cause) },
                else => return .{ .err = e },
            }
        },
    }
}

/// Id-directed singleton access keyed by the class FQN, so a same-named
/// top-level value elsewhere can neither satisfy nor shadow this first access.
pub fn ensureObjectSingletonById(self: *VmHost, class_id: ir.ClassId) Allocator.Error!MaybeValueResult {
    const allocator = self.allocator;
    const fqn: []const u8, const simple: []const u8 = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (class_id.int() >= m.classes.items.len) return .{ .ok = null };
        break :blk .{ m.classes.items[class_id.int()].fqn, m.classes.items[class_id.int()].name };
    };
    // Decline the simple-name collision: an object is never abstract.
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(fqn) orelse cg.get().get(simple)) |d| {
            const dg = d.borrow();
            const bad = dg.get().is_interface or dg.get().is_abstract;
            dg.deinit();
            if (bad) return .{ .ok = null };
        }
    }
    {
        const sg = self.singletons_by_id.borrow();
        defer sg.deinit();
        if (sg.get().get(class_id.int())) |v| {
            if (v == .Instance) return .{ .ok = v };
        }
    }
    var wait_rounds: u32 = 0;
    while (true) {
        {
            const g = self.globals.borrow();
            defer g.deinit();
            if (g.get().lookup(fqn)) |v| {
                if (v == .Instance) return .{ .ok = v };
            }
        }
        switch (claimObjectInit(self, fqn)) {
            .construct => {},
            .reentrant => |inst| return .{ .ok = inst },
            .failed => |stashed| return .{ .err = try fileInitFailedThrow(allocator, stashed) },
            .wait => {
                wait_rounds +|= 1;
                if (wait_rounds <= 64) {
                    std.Thread.yield() catch {};
                } else {
                    if (wait_rounds == 2000 and runtime.envOnce("KLIO_ERR_TRACE") != null) {
                        std.debug.print("[init-wait] {s} owner={?d} self={d}\n", .{ fqn, objectInitOwner(self, fqn), std.Thread.getCurrentId() });
                        runtime.trace.dumpCurrent(.{});
                    }
                    runtime.clockSleepMillis(1);
                }
                continue;
            },
        }
        {
            const published: ?Value = blk: {
                const g = self.globals.borrow();
                defer g.deinit();
                break :blk g.get().lookup(fqn);
            };
            if (published) |v| {
                if (v == .Instance) {
                    clearObjectState(self, fqn);
                    return .{ .ok = v };
                }
            }
        }
        break;
    }
    if (try enumOwnerInitForCompanion(self, simple)) |e| {
        clearObjectState(self, fqn);
        return .{ .err = e };
    }
    const r = self.newInstance(allocator, class_id, &.{}, null) catch |e| {
        clearObjectState(self, fqn);
        return e;
    };
    switch (r) {
        .ok => |inst| {
            if (inst != .Instance) {
                clearObjectState(self, fqn);
                return .{ .ok = inst };
            }
            if (std.mem.find(u8, simple, "$Companion$")) |sep| {
                const outer_name = simple[0..sep];
                const outer_def: ?ObjRef(ClassDef) = blk: {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    if (cg.get().get(outer_name)) |c| break :blk c.clone();
                    break :blk null;
                };
                if (outer_def) |od| {
                    const ig = inst.Instance.borrowMut();
                    defer ig.deinit();
                    ig.get().outer = .{ .Class = od };
                }
            }
            {
                const sg = self.singletons_by_id.borrowMut();
                defer sg.deinit();
                sg.get().put(class_id.int(), inst) catch {};
            }
            {
                const g = self.globals.borrowMut();
                defer g.deinit();
                g.get().define(fqn, inst) catch {};
                if (g.get().lookup(simple) == null) g.get().define(simple, inst) catch {};
            }
            clearObjectState(self, fqn);
            return .{ .ok = inst };
        },
        .err => |e| {
            initDebugLog(fqn, e);
            markObjectFailed(self, fqn, null);
            switch (e) {
                .Throw => |cause| return .{ .err = try fileInitFailedThrow(allocator, cause) },
                else => return .{ .err = e },
            }
        },
    }
}

/// Non-throwing gate for chains with no error channel: a failure resolves to
/// null, its cause restashed so the first throwing read still surfaces it.
pub fn objectSingletonQuiet(self: *VmHost, name: []const u8) ?Value {
    const r = ensureObjectSingleton(self, name) catch return null;
    return switch (r) {
        .ok => |v| v,
        .err => |e| blk: {
            if (runtime.envOnce("KLIO_INIT_DEBUG") != null)
                std.debug.print("[init-debug] {s} quiet-swallow err={s}\n", .{ name, @tagName(e) });
            if (e == .Throw and e.Throw == .Exception) {
                if (e.Throw.Exception.cause) |cause_cell| {
                    const cause = (runtime.ValueBox{ .cell = cause_cell }).asPtr().*;
                    restashObjectCause(self, name, cause);
                }
            }
            break :blk null;
        },
    };
}

fn restashObjectCause(self: *VmHost, raw_name: []const u8, cause: Value) void {
    // The id-directed path marks failure under the raw FQN, so fall back to it.
    const name = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().object_names.getKey(raw_name) orelse raw_name;
    };
    const g = self.object_states.borrowMut();
    defer g.deinit();
    if (g.get().getPtr(name)) |entry| {
        if (entry.* == .Failed and entry.Failed.cause == null) {
            if (runtime.reclaimEnabled()) cause.retain();
            entry.Failed.cause = cause;
            if (runtime.envOnce("KLIO_INIT_DEBUG") != null)
                std.debug.print("[init-debug] {s} restash-cause\n", .{name});
        }
    }
}

/// An enum's companion initializes last in the enum's own initialization, so
/// a first access through it initializes the enum and its entries first.
fn enumOwnerInitForCompanion(self: *VmHost, name: []const u8) Allocator.Error!?EvalError {
    const sep = std.mem.find(u8, name, "$Companion$") orelse return null;
    const owner_name = name[0..sep];
    const owner: ObjRef(ClassDef) = blk: {
        const cg = self.classes.borrow();
        defer cg.deinit();
        break :blk (cg.get().get(owner_name) orelse return null).clone();
    };
    defer owner.deinit();
    const is_enum = blk: {
        const g = owner.borrow();
        defer g.deinit();
        break :blk g.get().is_enum;
    };
    if (!is_enum) return null;
    return try ensureEnumInit(self, owner);
}

/// Kotlin initializes an enum on its first active use (an entry read,
/// `values`/`valueOf`/`entries`, a companion member), never on access of a
/// nested object. Entries construct in order, then the companion; failure sticks.
pub fn ensureEnumInit(self: *VmHost, cdef: ObjRef(ClassDef)) Allocator.Error!?EvalError {
    const fqn: []const u8 = blk: {
        const g = cdef.borrow();
        defer g.deinit();
        const c = g.get();
        if (!c.is_enum or c.enum_entries.len == 0) return null;
        if (c.enum_init_state.load(.acquire) == 2) return null;
        break :blk c.fqn;
    };
    var wait_rounds: u32 = 0;
    while (true) {
        if (cdef.asPtr().enum_init_state.load(.acquire) == 2) return null;
        switch (claimObjectInit(self, fqn)) {
            .construct => break,
            .reentrant => return null,
            .failed => |stashed| return try fileInitFailedThrow(self.allocator, stashed),
            .wait => {
                wait_rounds +|= 1;
                if (wait_rounds <= 64) {
                    std.Thread.yield() catch {};
                } else {
                    if (wait_rounds == 2000 and runtime.envOnce("KLIO_ERR_TRACE") != null) {
                        std.debug.print("[init-wait] {s} owner={?d} self={d}\n", .{ fqn, objectInitOwner(self, fqn), std.Thread.getCurrentId() });
                        runtime.trace.dumpCurrent(.{});
                    }
                    runtime.clockSleepMillis(1);
                }
                continue;
            },
        }
    }
    cdef.asPtr().enum_init_state.store(1, .release);
    if (try buildEnumClass(self, cdef, fqn)) |e| {
        initDebugLog(fqn, e);
        markObjectFailed(self, fqn, null);
        return switch (e) {
            .Throw => |cause| try fileInitFailedThrow(self.allocator, cause),
            else => e,
        };
    }
    cdef.asPtr().enum_init_state.store(2, .release);
    clearObjectState(self, fqn);
    return null;
}

/// `ensureEnumInit` with no error channel: false on failure, cause restashed.
pub fn ensureEnumInitQuiet(self: *VmHost, cdef: ObjRef(ClassDef)) bool {
    const r = ensureEnumInit(self, cdef) catch return false;
    const e = r orelse return true;
    if (e == .Throw and e.Throw == .Exception) {
        if (e.Throw.Exception.cause) |cause_cell| {
            const cause = (runtime.ValueBox{ .cell = cause_cell }).asPtr().*;
            const fqn = blk: {
                const g = cdef.borrow();
                defer g.deinit();
                break :blk g.get().fqn;
            };
            restashObjectCause(self, fqn, cause);
        }
    }
    return false;
}

/// Whether the enum's entries are constructed (no initialization is driven).
pub fn enumInitDone(cdef: ObjRef(ClassDef)) bool {
    return cdef.asPtr().enum_init_state.load(.acquire) == 2;
}

fn enumSimpleName(fqn: []const u8) []const u8 {
    return if (std.mem.findScalarLast(u8, fqn, '.')) |dot| fqn[dot + 1 ..] else fqn;
}

fn buildEnumClass(self: *VmHost, cdef: ObjRef(ClassDef), enum_fqn: []const u8) Allocator.Error!?EvalError {
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    const pa: Allocator = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().patch_allocator orelse self.allocator;
    };
    const prev_under_init = host_instances.setEnumUnderInit(enum_fqn);
    defer _ = host_instances.setEnumUnderInit(prev_under_init);

    if (try patchEnumEntryArgs(self, module, cdef, pa)) |e| return e;
    if (try instantiateEnumEntries(self, module, cdef, enum_fqn, pa)) |e| return e;

    // The companion initializes after every entry, before any other use.
    const class_name = blk: {
        const g = cdef.borrow();
        defer g.deinit();
        break :blk g.get().name;
    };
    const companion = module.registry.companion_singletons.get(class_name) orelse
        module.registry.companion_singletons.get(enumSimpleName(enum_fqn));
    if (companion) |cn| {
        _ = host_instances.setEnumUnderInit(prev_under_init);
        defer _ = host_instances.setEnumUnderInit(enum_fqn);
        switch (try ensureObjectSingleton(self, cn)) {
            .ok => {},
            .err => |e| return e,
        }
    }
    return null;
}

/// A body-less entry is the build-time instance: evaluate its constructor
/// arguments into its fields before any entry body or companion runs.
fn patchEnumEntryArgs(self: *VmHost, module: *const Module, cdef: ObjRef(ClassDef), pa: Allocator) Allocator.Error!?EvalError {
    const allocator = self.allocator;
    const inits = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().enum_entry_arg_inits;
    };
    const class_name = blk: {
        const g = cdef.borrow();
        defer g.deinit();
        break :blk g.get().name;
    };
    var param_names: std.ArrayList([]const u8) = .empty;
    defer param_names.deinit(allocator);
    {
        const dg = cdef.borrow();
        defer dg.deinit();
        for (dg.get().primary_params) |p| try param_names.append(allocator, p.name);
    }
    for (inits) |entry| {
        if (!std.mem.eql(u8, entry.class_name, class_name)) continue;
        var entry_inst: ?ObjRef(InstanceData) = null;
        {
            const dg = cdef.borrow();
            defer dg.deinit();
            for (dg.get().enum_entries) |e| {
                if (std.mem.eql(u8, e.name, entry.entry_name)) {
                    if (e.value == .Instance) entry_inst = e.value.Instance.clone();
                    break;
                }
            }
        }
        const inst = entry_inst orelse continue;
        defer inst.deinit();
        // An entry rebuilt through the ordinary path already bound its ctor
        // fields; re-patching would put page values in a slab-owned instance.
        {
            const g = inst.borrow();
            defer g.deinit();
            const icg = g.get().class.borrow();
            const built_class = icg.get().is_enum and icg.get().enum_entries.len == 0;
            icg.deinit();
            if (built_class or g.get().get("__enum_entry_built__") != null) continue;
        }
        // These instances are shared across per-program Vms and the ctor args
        // are constants, so re-patching only crosses allocators on release.
        const already_patched = blk: {
            const g = inst.borrow();
            defer g.deinit();
            for (param_names.items) |pn| {
                if (g.get().get(pn) == null) break :blk false;
            }
            break :blk true;
        };
        if (already_patched) continue;
        for (entry.funcs, 0..) |fid, idx| {
            const init_func = module.funcById(fid) orelse continue;
            var thunk_args: std.ArrayList(Value) = .empty;
            try thunk_args.append(allocator, .{ .Class = cdef.clone() });
            const v = switch (try ir.eval.evalWith(VmHost, allocator, module, init_func, thunk_args, self)) {
                .ok => |val| val,
                .err => |e| return e,
            };
            if (idx >= param_names.items.len) continue;
            // The instance outlives this Vm through the base cache, so copy
            // strings into the patch allocator; scalars are by value.
            const stored: Value = switch (v) {
                .String => |sref| blk: {
                    const sg = sref.borrow();
                    defer sg.deinit();
                    break :blk .{ .String = try runtime.strInit(pa, sg.get().bytes) };
                },
                else => v,
            };
            const g = inst.borrowMut();
            defer g.deinit();
            // A baked enum instance carries every ctor-param field, so this
            // replaces in place; an append means the bake dropped a field.
            if (g.get().get(param_names.items[idx]) == null and
                runtime.envOnce("KLIO_ENUM_INIT_TRACE") != null)
            {
                std.debug.print("[enum-init-append] class={s} entry={s} field={s}\n", .{
                    entry.class_name, entry.entry_name, param_names.items[idx],
                });
            }
            g.get().define(pa, param_names.items[idx], stored) catch {};
        }
    }
    return null;
}

/// An enum entry with a body instantiates the synthesized nested class
/// `$<entry> : Enum(args)` through the ordinary class path, carrying the name
/// and ordinal over. Secondary/vararg ctors and init blocks route every entry.
fn instantiateEnumEntries(self: *VmHost, module: *const Module, cdef: ObjRef(ClassDef), enum_fqn: []const u8, pa: Allocator) Allocator.Error!?EvalError {
    const allocator = self.allocator;
    const n_entries = blk: {
        const dg = cdef.borrow();
        defer dg.deinit();
        break :blk dg.get().enum_entries.len;
    };
    const enum_cid = module.classIdByFqn(enum_fqn) orelse return null;
    const class_name = blk: {
        const dg = cdef.borrow();
        defer dg.deinit();
        break :blk dg.get().name;
    };
    const has_secondary = blk: {
        const dg = cdef.borrow();
        defer dg.deinit();
        if (dg.get().secondary_ctors.len != 0) break :blk true;
        // A vararg primary parameter needs the ordinary argument packing.
        for (module.classes.items[enum_cid.int()].primary_params) |prm| if (prm.is_vararg) break :blk true;
        if (dg.get().init_blocks.len != 0) break :blk true;
        for (dg.get().body_properties) |bp| if (bp.init != null) break :blk true;
        break :blk false;
    };
    // Install the rebuilt entries before constructing any: construction spans
    // safe points, and an instance held only in a local is unreachable.
    const replaced: []runtime.ClassDef.EnumEntry = blk: {
        const dg = cdef.borrow();
        defer dg.deinit();
        const copy = try pa.alloc(runtime.ClassDef.EnumEntry, n_entries);
        @memcpy(copy, dg.get().enum_entries);
        break :blk copy;
    };
    {
        const dg = cdef.borrowMut();
        dg.get().enum_entries = replaced;
        dg.deinit();
    }
    for (0..n_entries) |i| {
        var entry_name: []const u8 = undefined;
        var current_class: []const u8 = "";
        var entry_rebuilt = false;
        {
            const e = replaced[i];
            entry_name = e.name;
            if (e.value == .Instance) {
                const ig = e.value.Instance.borrow();
                const icg = ig.get().class.borrow();
                current_class = icg.get().name;
                icg.deinit();
                entry_rebuilt = ig.get().get("__enum_entry_built__") != null;
                ig.deinit();
            }
        }
        const synth = try std.fmt.allocPrint(allocator, "${s}", .{entry_name});
        defer allocator.free(synth);
        const body_cid = module.classIdNestedIn(enum_cid, synth);
        if (body_cid == null and !has_secondary) continue;
        if (body_cid != null and std.mem.eql(u8, current_class, synth)) continue;
        if (body_cid == null and entry_rebuilt) continue;
        var ctor_args: std.ArrayList(Value) = .empty;
        defer ctor_args.deinit(allocator);
        if (body_cid == null) {
            const inits = blk: {
                const pg = self.prog.borrow();
                defer pg.deinit();
                break :blk pg.get().enum_entry_arg_inits;
            };
            for (inits) |init_entry| {
                if (!std.mem.eql(u8, init_entry.class_name, class_name) or !std.mem.eql(u8, init_entry.entry_name, entry_name)) continue;
                for (init_entry.funcs) |fid| {
                    const init_func = module.funcById(fid) orelse continue;
                    var thunk_args: std.ArrayList(Value) = .empty;
                    try thunk_args.append(allocator, .{ .Class = cdef.clone() });
                    switch (try ir.eval.evalWith(VmHost, allocator, module, init_func, thunk_args, self)) {
                        .ok => |val| try ctor_args.append(allocator, val),
                        .err => |e| return e,
                    }
                }
                break;
            }
        }
        const target_cid = body_cid orelse enum_cid;
        if (runtime.envOnce("KLIO_ENUM_INIT_TRACE") != null) std.debug.print("[enum-init] build {s}.{s} via {s} (body={}, secondary={}, nargs={d})\n", .{ enum_fqn, entry_name, module.classes.items[target_cid.int()].fqn, body_cid != null, has_secondary, ctor_args.items.len });
        // Pinned until the instance owns them: header thunks run user code.
        const preset_name: Value = .{ .String = try runtime.strInit(allocator, entry_name) };
        const entry_keepalive = self.ka.mark();
        defer self.ka.restore(entry_keepalive);
        self.ka.push(preset_name);
        self.ka.pushSlice(ctor_args.items);
        // The slot takes the instance as soon as its shell exists: the entry's
        // own initializers name it mid-construction, as kotlinc binds them.
        host_instances.setEnumEntryPreset(.{
            .class_fqn = module.classes.items[target_cid.int()].fqn,
            .name = preset_name,
            .ordinal = Value.newInt(@intCast(i)),
            .slot = &replaced[i].value,
        });
        const made = switch (try self.newInstance(allocator, target_cid, ctor_args.items, null)) {
            .ok => |v| v,
            .err => |e| {
                host_instances.setEnumEntryPreset(null);
                return e;
            },
        };
        host_instances.setEnumEntryPreset(null);
        if (made != .Instance) continue;
        if (body_cid == null) {
            // The instance's own allocator: a patch-allocated list frees via
            // the slab.
            const g = made.Instance.borrowMut();
            defer g.deinit();
            try g.get().define(allocator, "__enum_entry_built__", .{ .Bool = true });
        }
        const published = replaced[i].value == .Instance and replaced[i].value.Instance.ptrEq(made.Instance);
        if (!published) replaced[i].value = made;
    }
    return null;
}

/// Whether singleton class `class_name` transitively declares member `name`.
pub fn objectClassDeclaresMethod(self: *VmHost, class_name: []const u8, name: []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.hierarchy_methods.get(class_name)) |methods| {
        if (methods.contains(name)) return true;
    }
    return false;
}

pub fn objectClassDeclaresProp(self: *VmHost, class_name: []const u8, name: []const u8) bool {
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (pg.get().instance_prop_getters.get(.{ .a = class_name, .b = name }) != null) return true;
        if (pg.get().extension_props.get(.{ .a = class_name, .b = name }) != null) return true;
    }
    var cur: ?ObjRef(ClassDef) = blk: {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(class_name)) |d| break :blk d.clone();
        break :blk null;
    };
    var depth: usize = 0;
    while (cur) |c| {
        defer c.deinit();
        if (depth > 64) break;
        depth += 1;
        const g = c.borrow();
        defer g.deinit();
        for (g.get().body_properties) |bp| {
            if (std.mem.eql(u8, bp.name, name)) return true;
        }
        for (g.get().primary_params) |pp| {
            if (pp.property != null and std.mem.eql(u8, pp.name, name)) return true;
        }
        cur = if (g.get().parent) |pp| pp.clone() else null;
    }
    return false;
}

/// Companion read gate for member probes: construct only when the class declares `member`.
pub fn objectSingletonForMember(self: *VmHost, name: []const u8, member: []const u8) Allocator.Error!MaybeValueResult {
    // Applies to the initialized fast path too, or the probe steals an extension's call.
    if (!(objectClassDeclaresProp(self, name, member) or objectClassDeclaresMethod(self, name, member))) {
        return .{ .ok = null };
    }
    {
        const g = self.globals.borrow();
        defer g.deinit();
        if (g.get().lookup(name)) |v| {
            if (v == .Instance) return .{ .ok = v };
        }
    }
    return ensureObjectSingleton(self, name);
}

fn clearObjectState(self: *VmHost, name: []const u8) void {
    const g = self.object_states.borrowMut();
    defer g.deinit();
    _ = g.get().remove(name);
}

/// Record a terminal init failure. A set `cause` is retained into the state
/// table so the first throwing read surfaces it; a throwing site passes null.
fn markObjectFailed(self: *VmHost, name: []const u8, cause: ?Value) void {
    const g = self.object_states.borrowMut();
    defer g.deinit();
    if (cause) |c| {
        if (runtime.reclaimEnabled()) c.retain();
    }
    g.get().put(name, .{ .Failed = .{ .cause = cause } }) catch {};
}

/// Look up an intrinsic by FQN; a pack's `installed_bindings` shadows stdlib.
fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
    // Post-link the bindings table is read-only, so the link flag gates a lock-free read.
    {
        const img = self.prog.asPtrConst();
        if (@atomicLoad(bool, &img.resolved_linked, .acquire)) {
            if (img.installed_bindings.asPtrConst().resolve(fqn)) |f| return f;
            return stdlib.implementation(fqn);
        }
    }
    const pg = self.prog.borrow();
    defer pg.deinit();
    const bg = pg.get().installed_bindings.borrow();
    defer bg.deinit();
    if (bg.get().resolve(fqn)) |f| return f;
    return stdlib.implementation(fqn);
}

/// Invoke an intrinsic through the `VmIntrinsicHost` side-channel so HOF
/// bindings reach IR lambdas; maps control-flow errors, keeping the `Value`.
fn dispatchIntrinsic(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!union(enum) { ok: Value, err: EvalError } {
    vmhost.emitPath(allocator, "intrinsic_globals", fqn, null, null, args);
    const keepalive = self.ka.mark();
    defer self.ka.restore(keepalive);
    self.ka.pushSlice(args);
    var intrinsic = VmIntrinsicHost{
        .module = self.module.clone(),
        .closures = self.closures.clone(),
        .globals = self.globals.clone(),
        .classes = self.classes.clone(),
        .prog = self.prog.clone(),
        .anon_methods = self.anon_methods.clone(),
        .class_default_outer = self.class_default_outer.clone(),
        .instance_id_counter = self.instance_id_counter.clone(),
        .out_sink = self.out_sink.clone(),
        .threads = self.threads.clone(),
        .object_states = self.object_states.clone(),
        .singletons_by_id = self.singletons_by_id.clone(),
        .allocator = self.allocator,
    };
    defer {
        intrinsic.module.deinit();
        intrinsic.closures.deinit();
        intrinsic.globals.deinit();
        intrinsic.classes.deinit();
        intrinsic.prog.deinit();
        intrinsic.anon_methods.deinit();
        intrinsic.class_default_outer.deinit();
        intrinsic.instance_id_counter.deinit();
        intrinsic.out_sink.deinit();
        intrinsic.threads.deinit();
        intrinsic.object_states.deinit();
    }
    stdlib.implementations.string.clearRecvMemo();
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = intrinsic.intrinsicHost(),
        .allocator = allocator,
    };
    const prev_fqn_lt = runtime.leaktrack.current_fqn;
    runtime.leaktrack.current_fqn = fqn;
    const r = try func(&ctx);
    runtime.leaktrack.current_fqn = prev_fqn_lt;
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| switch (e) {
            .Thrown => |v| .{ .err = .{ .Throw = v } },
            .Return => |v| .{ .err = .{ .NonLocalReturn = v } },
            // A parked primitive: each enclosing `eval` frame fills this in.
            .Suspend => |wake| blk: {
                const state = try allocator.create(SuspendState);
                state.* = .{
                    .token = 0,
                    .frames = .empty,
                    .wake_in_millis = wake,
                    .pending_resume_reg = null,
                };
                break :blk .{ .err = .{ .Suspended = state } };
            },
            else => .{ .err = .{ .Type = runtimeErrorMessage(allocator, e) } },
        },
    };
}

fn runtimeErrorMessage(allocator: Allocator, e: RuntimeError) []const u8 {
    return switch (e) {
        .Unbound => |s| s,
        .Type => |s| s,
        .Arity => |s| s,
        .Unimplemented => |s| s,
        .CalleeFailed => |s| s,
        .NoMain => "no main function",
        else => std.fmt.allocPrint(allocator, "{any}", .{e}) catch "runtime error",
    };
}

/// Whether `fid` is an extension: its first param is the synthetic `this`.
fn isExtFid(fid: FuncId, m: *const Module) bool {
    const f = m.funcById(fid) orelse return false;
    if (f.params.len == 0) return false;
    return std.mem.eql(u8, f.params[0].name, "this");
}

fn idGet(funcs: []const ir.Func, idx: u32) ?*const ir.Func {
    if (idx >= funcs.len) return null;
    return &funcs[idx];
}

/// Kotlin constant naming: upper-case, underscore and digits (`MAX_VALUE`).
fn looksConst(tail: []const u8) bool {
    if (tail.len == 0) return false;
    for (tail) |c| {
        if (!(std.ascii.isUpper(c) or c == '_' or std.ascii.isDigit(c))) return false;
    }
    return true;
}

/// Synthetic `Thread` static surface: a direct call errors; the static-call
/// probe routes `sleep`/`currentThread` to `kotlin.concurrent.Thread.*`.
fn threadStaticStub(ctx: *CallCtx) Allocator.Error!runtime.EvalResult {
    _ = ctx;
    return .{ .err = .{ .Type = "Thread: use Thread.sleep(ms) / Thread.currentThread()" } };
}

/// Synthetic `Delegates`; its member calls are intercepted in `call_member`.
fn delegatesStub(ctx: *CallCtx) Allocator.Error!runtime.EvalResult {
    _ = ctx;
    return .{ .err = .{ .Type = "Delegates: use Delegates.notNull / Delegates.observable / Delegates.vetoable" } };
}

const PRIMITIVE_TYPE_NAMES = [_][]const u8{
    "Int",     "Long",  "Short", "Byte",   "Float", "Double",
    "Boolean", "Char",  "String", "Unit",  "Any",   "Nothing",
    "UInt",    "ULong", "UShort", "UByte", "Number",
};

fn isPrimitiveTypeName(name: []const u8) bool {
    for (PRIMITIVE_TYPE_NAMES) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Synthetic `ClassDef` for a primitive type name, with fqn `kotlin.<name>`.
fn primitiveClassDef(allocator: Allocator, name: []const u8) Allocator.Error!ObjRef(ClassDef) {
    const fqn = try std.fmt.allocPrint(allocator, "kotlin.{s}", .{name});
    const env = try ObjRef(runtime.Env).init(allocator, runtime.Env.init(allocator));
    const cd: ClassDef = .{
        .name = name,
        .fqn = fqn,
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = false,
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
        .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .nested_classes = &.{},
        .captured_env = env,
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    };
    return ObjRef(ClassDef).init(allocator, cd);
}

/// The runtime value of one top-level function: a closure over its lowered
/// body, or the native binding link time settled for a bodyless declaration.
fn funcValueById(self: *VmHost, allocator: Allocator, fid: FuncId) ?Value {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    const func = m.funcById(fid) orelse return null;
    if (func.hasBody()) {
        const caps = ObjRef(std.ArrayList(Value)).init(allocator, .empty) catch return null;
        const id = self.closures.push(.{
            .body_func = fid,
            .is_ref = true,
            .n_params = func.params.len,
            .receiver_shape_known = func.lambda_receiver_shape_known,
            .has_receiver = func.lambda_has_receiver,
            .capture_names = &.{},
            .captures = caps,
        }) catch return null;
        const empty = IrClosureRef.init(allocator, .{ .id = id, .captures = &.{} }) catch return null;
        return .{ .IrClosure = empty };
    }
    const linked: ?StdlibFn = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().resolvedNativeForm(fid);
    };
    if (linked) |func_native| {
        return Value.internIntrinsic(func.fqn, func_native);
    }
    return null;
}

/// Resolve a lowering-bound global by exact identity, so no name-keyed
/// re-resolution swaps in a same-simple-name twin. Null falls to the name path.
pub fn lookupGlobalById(self: *VmHost, allocator: Allocator, func: ?FuncId, class: ?ir.ClassId, ctor_ref: bool) ?Value {
    if (runtime.envOnce("KLIO_GLOBAL_TRACE") != null) {
        if (class) |cid| {
            const mg = self.module.borrow();
            defer mg.deinit();
            const m = mg.get();
            if (cid.int() < m.classes.items.len and std.mem.eql(u8, runtime.envOnce("KLIO_GLOBAL_TRACE").?, m.classes.items[cid.int()].name)) std.debug.print("[global-by-id] class {s}\n", .{m.classes.items[cid.int()].name});
        }
    }
    if (func) |fid| {
        // A `@LowPriorityInOverloadResolution` function is never bound by id:
        // kotlinc does not let it outrank a same-name constructor, and a stub
        // calling that constructor by name would re-bind itself and recurse.
        const is_low = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const cf = mg.get().funcById(fid) orelse break :blk false;
            break :blk cf.low_priority;
        };
        if (!is_low) {
            if (funcValueById(self, allocator, fid)) |v| return v;
        }
    }
    if (class) |cid| {
        // The id table is authoritative: a name binding cannot shadow it.
        if (!ctor_ref) {
            const sg = self.singletons_by_id.borrow();
            const own = sg.get().get(cid.int());
            sg.deinit();
            if (own) |v| return v;
            // A class with a companion also answers with the companion's
            // singleton, as a DIRECT child: `classIdNestedIn` walks up.
            const comp_id: ?ir.ClassId = blk: {
                const mg = self.module.borrow();
                defer mg.deinit();
                const m = mg.get();
                if (cid.int() >= m.classes.items.len) break :blk null;
                break :blk m.classDirectChild(cid, "Companion");
            };
            if (comp_id) |cc| {
                const sg2 = self.singletons_by_id.borrow();
                const cv = sg2.get().get(cc.int());
                sg2.deinit();
                if (cv) |v| return v;
            }
        }
        const fqn: ?[]const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const m = mg.get();
            if (cid.int() >= m.classes.items.len) break :blk null;
            break :blk m.classes.items[cid.int()].fqn;
        };
        if (fqn) |f| {
            const found: ?ObjRef(ClassDef) = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                if (cg.get().get(f)) |def| break :blk def.clone();
                break :blk null;
            };
            if (found) |def| {
                const cls_name, const is_object = blk: {
                    const dg = def.borrow();
                    defer dg.deinit();
                    break :blk .{ dg.get().name, dg.get().is_object };
                };
                // In value position a class with a companion is its companion
                // singleton and a plain `object` its own, only once published.
                const singleton_name: ?[]const u8 = blk: {
                    if (ctor_ref and !is_object) break :blk null;
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    const m = mg.get();
                    // `companion_singletons` is keyed by SIMPLE name: forward
                    // only when cid declares a nested `Companion` or the
                    // singleton name starts with cid's (`Owner$Companion$...`).
                    if (!is_object) {
                        const cn_opt = m.registry.companion_singletons.get(cls_name);
                        const own = m.classIdNestedIn(cid, "Companion") != null or
                            (cn_opt != null and std.mem.startsWith(u8, cn_opt.?, cls_name));
                        if (!own) break :blk null;
                    }
                    if (m.registry.companion_singletons.get(cls_name)) |cn| break :blk cn;
                    if (is_object) break :blk cls_name;
                    break :blk null;
                };
                if (singleton_name) |sn| {
                    def.deinit();
                    if (is_object) {
                        // A built singleton reads by FQN.
                        {
                            const gg = self.globals.borrow();
                            defer gg.deinit();
                            if (gg.get().lookup(f)) |v| {
                                if (v == .Instance) return v;
                            }
                        }
                        const simple_bound: ?Value = blk: {
                            const gg = self.globals.borrow();
                            defer gg.deinit();
                            break :blk gg.get().lookup(sn);
                        };
                        // Our own singleton under the simple name is no collision.
                        if (simple_bound) |v| {
                            if (v == .Instance) {
                                const icls: ?[]const u8 = blk: {
                                    const g2 = v.Instance.borrow();
                                    defer g2.deinit();
                                    const cg2 = g2.get().class.borrow();
                                    defer cg2.deinit();
                                    break :blk cg2.get().fqn;
                                };
                                if (icls != null and std.mem.eql(u8, icls.?, f)) return v;
                            }
                        }
                        // Driven by the committed id: the bare name is mangled
                        // out of the flat index when two packages share it.
                        const rr = ensureObjectSingletonById(self, cid) catch return null;
                        return switch (rr) {
                            .ok => |maybe| if (maybe) |v| (if (v == .Instance) v else null) else null,
                            // No error channel: restash for the throwing read.
                            .err => |e| blk: {
                                if (e == .Throw and e.Throw == .Exception) {
                                    if (e.Throw.Exception.cause) |cause_cell| {
                                        const cause = (runtime.ValueBox{ .cell = cause_cell }).asPtr().*;
                                        restashObjectCause(self, f, cause);
                                    }
                                }
                                break :blk null;
                            },
                        };
                    }
                    const published: ?Value = blk: {
                        const gg = self.globals.borrow();
                        defer gg.deinit();
                        break :blk gg.get().lookup(sn);
                    };
                    if (published) |v| {
                        if (v == .Instance) return v;
                    }
                    // Companion unpublished: the class itself is the value.
                    const again: ?ObjRef(ClassDef) = blk: {
                        const cg = self.classes.borrow();
                        defer cg.deinit();
                        if (cg.get().get(f)) |d| break :blk d.clone();
                        break :blk null;
                    };
                    if (again) |d| return .{ .Class = d };
                    return null;
                }
                return .{ .Class = def };
            }
        }
    }
    return null;
}


/// The effective lookup key for a top-level property read. A `var` with a
/// custom setter but a default getter stores under `__klio_topfield__<name>`
/// so plain-name writes dispatch the setter; a custom getter keeps the miss.
fn topPropReadKey(self: *VmHost, name: []const u8, buf: []u8) []const u8 {
    const reg = &self.module.asPtr().registry;
    if (reg.top_level_prop_setters.count() == 0) return name;
    if (std.mem.startsWith(u8, name, "__klio_topfield__")) return name;
    if (reg.top_level_prop_setters.get(name) == null) return name;
    if (reg.top_level_prop_getters.get(name) != null) return name;
    return std.fmt.bufPrint(buf, "__klio_topfield__{s}", .{name}) catch name;
}

/// A leaf serve's global read: the bound value under the effective storage
/// key, scalars only. Drives no initializer, gate or delegate; a miss defers.
pub fn leafGlobalGet(self: *VmHost, name_in: []const u8) ?Value {
    var buf: [256]u8 = undefined;
    const name = topPropReadKey(self, name_in, &buf);
    const cached: ?Value = blk: {
        const g = self.globals.borrow();
        defer g.deinit();
        break :blk g.get().lookup(name);
    };
    const v = cached orelse return null;
    return switch (v) {
        .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Bool, .Char => v,
        else => null,
    };
}

/// Whether a bare simple-name global-fn pick is visible from the executing
/// reference site. Only a confirmed unimported foreign package rejects it.
fn bareGlobalFnVisible(self: *VmHost, m: *const Module, fid: FuncId, name: []const u8) bool {
    _ = self;
    const f = m.funcById(fid) orelse return true;
    if (f.package.len == 0) return true;
    const ref_file: ?ir.FileId = ir.eval.refSiteFile() orelse
        (if (ir.eval.currentCallSiteSpan()) |sp| sp.file else null);
    // The reference package follows the executing statement's file when the
    // module records it; the frame's declared package is the fallback.
    const file_pkg: ?[]const u8 = if (ref_file) |rf| m.packageOfFile(rf) else null;
    const ref_pkg = file_pkg orelse (ir.eval.nearestFramePackage() orelse return true);
    const cfile = ref_file orelse ir.FileId.from(std.math.maxInt(u32));
    return m.scopeTier(f.fqn, f.package, name, ref_pkg, cfile) != ir.Module.other_package_tier;
}

/// Bind a reified type-parameter name to the class its type argument names,
/// returning the shadowed global for restore, as `callFuncTyped` does.
pub fn bindTypeParamGlobal(self: *VmHost, tp_name: []const u8, arg_name_in: []const u8) ?Value {
    // A generic spelling resolves by head, a nullable one by the class named.
    const arg_head = if (std.mem.findScalar(u8, arg_name_in, '<')) |lt| arg_name_in[0..lt] else arg_name_in;
    const arg_name = std.mem.trimEnd(u8, arg_head, "?");
    const cls_value: ?Value = blk: {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(arg_name)) |c| break :blk Value{ .Class = c.clone() };
        break :blk lookupGlobal(self, arg_name);
    };
    const prev = blk: {
        const g = self.globals.borrow();
        defer g.deinit();
        break :blk g.get().lookup(tp_name);
    };
    if (cls_value) |v| {
        const g = self.globals.borrowMut();
        defer g.deinit();
        g.get().define(tp_name, v) catch {};
    }
    return prev;
}

/// The full generic spelling of a bound type argument, kept beside the class
/// binding under the key `<tp><>` so `typeOf<T>()` materialises its arguments.
/// Returns the key's previous value; null when the spelling has no arguments.
pub fn bindTypeParamSpelling(self: *VmHost, allocator: Allocator, tp_name: []const u8, arg_name_in: []const u8) ?struct { key: []const u8, prev: ?Value } {
    // The class binding carries neither type arguments nor nullability.
    if (std.mem.findScalar(u8, arg_name_in, '<') == null and !std.mem.endsWith(u8, arg_name_in, "?")) return null;
    const key = std.fmt.allocPrint(allocator, "{s}<>", .{tp_name}) catch return null;
    const prev = blk: {
        const g = self.globals.borrow();
        defer g.deinit();
        break :blk g.get().lookup(key);
    };
    const owned = allocator.dupe(u8, arg_name_in) catch return null;
    const sv = runtime.strInitOwned(allocator, owned) catch return null;
    if (runtime.envOnce("KLIO_KTYPE_TRACE") != null) std.debug.print("[ktype] bind {s} := {s}\n", .{ key, arg_name_in });
    {
        const g = self.globals.borrowMut();
        defer g.deinit();
        g.get().define(key, Value{ .String = sv }) catch {};
    }
    return .{ .key = key, .prev = prev };
}

pub fn restoreGlobalBinding(self: *VmHost, name: []const u8, prev: ?Value) void {
    const g = self.globals.borrowMut();
    defer g.deinit();
    if (prev) |v| {
        g.get().define(name, v) catch {};
    } else {
        g.get().removeLocal(name);
    }
}

/// Threadlocal memo of the two snapshot-core globals `currentSnapshot` reads,
/// off the shared reader lock; `private val`s, so only the gen invalidates.
const SnapGlobals = struct { gen: u32 = 0, ts: Value = .Null, gs: Value = .Null };
threadlocal var snap_globals: SnapGlobals = .{};

pub fn composeSnapshotGlobals(self: *VmHost) ?struct { ts: Value, gs: Value } {
    const gen = host_call_member.dispatch_cache_gen.load(.monotonic);
    if (snap_globals.gen == gen) {
        return .{ .ts = snap_globals.ts, .gs = snap_globals.gs };
    }
    const ts = lookupGlobal(self, "threadSnapshot") orelse return null;
    const gs = lookupGlobal(self, "globalSnapshot") orelse return null;
    if (ts != .Instance or gs != .Instance) return null;
    snap_globals = .{ .gen = gen, .ts = ts, .gs = gs };
    return .{ .ts = ts, .gs = gs };
}

pub fn lookupGlobal(self: *VmHost, name_in_raw: []const u8) ?Value {
    const allocator = self.allocator;
    var top_prop_buf: [256]u8 = undefined;
    // A nullable spelling (`A?`) names the same class.
    const name_in = if (std.mem.endsWith(u8, name_in_raw, "?")) name_in_raw[0 .. name_in_raw.len - 1] else name_in_raw;
    const name = topPropReadKey(self, name_in, &top_prop_buf);
    const gtrace = blk: {
        const S = struct {
            var init: bool = false;
            var val: ?[]const u8 = null;
        };
        if (!S.init) {
            S.val = runtime.envOnce("KLIO_GLOBAL_TRACE");
            S.init = true;
        }
        const w = S.val orelse break :blk false;
        break :blk std.mem.eql(u8, w, name);
    };

    const cached: ?Value = blk: {
        const g = self.globals.borrow();
        defer g.deinit();
        break :blk g.get().lookup(name);
    };

    // First access constructs the singleton through the shared gate; a
    // non-Instance cached value still drives it and outranks a stdlib alias.
    if ((cached == null or cached.? != .Instance) and progHasObjectName(self, name)) {
        if (objectSingletonQuiet(self, name)) |v| return v;
    }

    // A deferred top-level property is driven on first access. In the startup
    // pass a read ahead of the initializer takes the declared type's default,
    // which must surface even as `Null`, so it returns before the unwrap.
    if (cached == null and progHasTopLevelPropInit(self, name)) {
        if (host_impl.pendingTypedDefault(self, name)) |d| return d;
        const r = host_impl.ensureTopLevelInited(self, name) catch return null;
        if (r == .ok) {
            if (r.ok) |v| {
                if (v != .Null) return v;
            }
        }
    }

    // Any value with a `getValue` operator, member or extension, can delegate.
    if (registryHasDelegatedProp(self, name)) {
        if (cached) |v| {
            if (v != .Null) {
                const prop_ref = makePropertyRef(allocator, name) catch return null;
                const r = self.callMember(allocator, &v, "getValue", &.{ Value.Null, prop_ref }) catch return null;
                if (r == .ok) return r.ok;
            }
        }
    }

    if (cached) |v| {
        if (gtrace) std.debug.print("[gtrace] {s} arm=cached kind={s}\n", .{ name, @tagName(v) });
        if (v == .Delegate) {
            const d = v.Delegate;
            const kind: DelegateKind = blk2: {
                const g = d.borrow();
                defer g.deinit();
                break :blk2 g.get().*;
            };
            switch (kind) {
                .Lazy => |lz| {
                    if (lz.cached) |c| return c;
                    const prod = lz.producer;
                    const r = self.callValue(allocator, &prod, &.{}) catch return v;
                    if (r == .ok) {
                        const result = r.ok;
                        const g = d.borrowMut();
                        defer g.deinit();
                        if (g.get().* == .Lazy) {
                            g.get().Lazy.cached = result;
                        }
                        return result;
                    }
                    return v;
                },
                .NotNull => |nn| {
                    if (nn.value) |x| return x;
                    // Kotlin throws ISE on read-before-write; this path nulls.
                    return null;
                },
                .Observable => |ob| {
                    return ob.value;
                },
            }
        }
        // A boxed capture reads through the cell; the cell is a carrier.
        if (v == .Cell) {
            const cg = v.Cell.borrow();
            defer cg.deinit();
            return cg.get().*;
        }
        return v;
    }

    // A `Value.Class` lets `Foo(args)` dispatch and reflection resolve.
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(name)) |def| {
            return .{ .Class = def.clone() };
        }
    }

    // A top-level function surfaces as a synthetic closure for `::name`. A bare
    // reference never binds an extension; a dotted name is an exact FQN.
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        // An extension twin shares the receiverless FQN (`Func.fqn` carries no
        // receiver segment) and a value reference cannot supply a receiver.
        const by_fqn: ?FuncId = if (std.mem.findScalarLast(u8, name, '.')) |dot| pick: {
            for (m.funcsBySimpleName(name[dot + 1 ..])) |fid| {
                const f = m.funcById(fid) orelse continue;
                if (!std.mem.eql(u8, f.fqn, name)) continue;
                if (isExtFid(fid, m)) continue;
                break :pick fid;
            }
            break :pick null;
        } else null;
        var chosen: ?FuncId = by_fqn orelse if (m.funcId(name)) |fid| pick: {
            if (isExtFid(fid, m)) {
                for (m.funcsBySimpleName(name)) |c| {
                    if (!isExtFid(c, m)) {
                        if (m.funcById(c)) |f| {
                            if (f.hasBody()) break :pick c;
                        }
                    }
                }
                break :pick null;
            } else {
                break :pick fid;
            }
        } else null;
        // A bare pick must be visible from the reference site: a namesake in an
        // unimported package is not Kotlin's target. Dotted refs bind as written.
        if (by_fqn == null) {
            if (chosen) |fid| {
                if (!bareGlobalFnVisible(self, m, fid, name)) {
                    var replacement: ?FuncId = null;
                    for (m.funcsBySimpleName(name)) |c| {
                        if (c.int() == fid.int()) continue;
                        if (isExtFid(c, m)) continue;
                        const f = m.funcById(c) orelse continue;
                        if (!f.hasBody()) continue;
                        if (bareGlobalFnVisible(self, m, c, name)) {
                            replacement = c;
                            break;
                        }
                    }
                    // Discard the invisible pick only when a visible sibling
                    // or the stdlib below can serve the name; else keep it.
                    if (replacement != null) {
                        chosen = replacement;
                    } else {
                        const stdlib_serves = lookupIntrinsic(self, name) != null or blk: {
                            const pg = self.prog.borrow();
                            defer pg.deinit();
                            break :blk pg.get().defaultImportGlobal(name) != null or pg.get().packBareAlias(name) != null;
                        };
                        if (stdlib_serves) chosen = null;
                    }
                }
            }
        }
        if (chosen) |fid| {
            if (gtrace) std.debug.print("[gtrace] {s} arm=fn fid={d} fqn={s}\n", .{ name, fid.int(), if (m.funcById(fid)) |ff| ff.fqn else "?" });
            if (funcValueById(self, allocator, fid)) |v| return v;
        }
    }

    // Stdlib resolution: a dotted name is an exact FQN; a bare one goes through
    // the link-settled default-import map, then the pack bare aliases.
    {
        const mapped: ?[]const u8 = if (lookupIntrinsic(self, name) != null)
            name
        else blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().defaultImportGlobal(name) orelse pg.get().packBareAlias(name);
        };
        if (mapped) |m| {
            if (lookupIntrinsic(self, m)) |func| {
                // `m` is a program-lifetime string, so `Intrinsic.fqn` borrows
                // it: never freed, and a dup would leak per discarded reference.
                const fqn = m;
                if (trace.enabled(name)) {
                    trace.emit("map=global_fqn name={s} fqn={s}", .{ name, fqn });
                }
                const tail = if (std.mem.findScalarLast(u8, fqn, '.')) |i| fqn[i + 1 ..] else fqn;
                if (looksConst(tail)) {
                    const r = dispatchIntrinsic(self, allocator, fqn, func, &.{}) catch return null;
                    if (r == .ok) return r.ok;
                }
                if (gtrace) std.debug.print("[gtrace] {s} arm=intrinsic fqn={s}\n", .{ name, fqn });
                return Value.internIntrinsic(fqn, func);
            }
        }
    }

    if (std.mem.eql(u8, name, "Thread")) {
        return Value.internIntrinsic("kotlin.concurrent.Thread", threadStaticStub);
    }

    if (std.mem.eql(u8, name, "Delegates")) {
        return Value.internIntrinsic("kotlin.properties.Delegates", delegatesStub);
    }

    if (isPrimitiveTypeName(name)) {
        const def = primitiveClassDef(allocator, name) catch return null;
        return .{ .Class = def };
    }

    if (std.mem.findScalar(u8, name, '.')) |dot| {
        const ty = name[0..dot];
        const member = name[dot + 1 ..];
        if (stdlib.primitive_companion_const(ty, member)) |v| {
            return v;
        }
    }

    // Package-qualified class reference: the class table is keyed by simple
    // name, so retry the trailing segment once every other probe missed.
    if (std.mem.findScalarLast(u8, name, '.')) |dot| {
        const tail = name[dot + 1 ..];
        if (!std.mem.eql(u8, tail, name) and tail.len != 0) {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(tail)) |def| {
                return .{ .Class = def.clone() };
            }
        }
    }

    // `typealias Alias = Target`: follow the chain with a cycle guard.
    {
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        var cur = name;
        while (true) {
            const target: ?[]const u8 = blk2: {
                const mg = self.module.borrow();
                defer mg.deinit();
                break :blk2 mg.get().registry.type_aliases.get(cur);
            };
            const t = target orelse break;
            var already = false;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, cur)) {
                    already = true;
                    break;
                }
            }
            if (already) break;
            seen.append(allocator, cur) catch break;
            if (lookupGlobal(self, t)) |v| return v;
            cur = t;
        }
    }

    return null;
}

pub fn storeGlobal(self: *VmHost, allocator: Allocator, name: []const u8, value: Value) Allocator.Error!UnitResult {
    if (runtime.envOnce("KLIO_GLOBAL_TRACE")) |w| {
        if (std.mem.eql(u8, w, name)) {
            std.debug.print("[gstore] {s} = {s}\n", .{ name, @tagName(value) });
            ir.eval.dumpFrameChainForDiagAlways();
        }
    }
    if (!std.mem.startsWith(u8, name, "__klio_topfield__")) {
        // A plain-name write to a `var` with a custom setter runs the setter;
        // the thunk's own `field =` targets the raw key and skips this.
        const setter_fid: ?ir.FuncId = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.top_level_prop_setters.get(name);
        };
        if (setter_fid) |fid| {
            const r = try self.callFunc(allocator, self.module.asPtr(), fid, &.{value});
            if (r == .err) return .{ .err = r.err };
            return .{ .ok = {} };
        }
        // With storage under the raw key (custom getter, default setter), a
        // plain-name write with no plain binding lands on the raw binding.
        const plain_exists = blk: {
            const g = self.globals.borrow();
            defer g.deinit();
            break :blk g.get().lookup(name) != null;
        };
        if (!plain_exists) {
            const raw = try std.fmt.allocPrint(allocator, "__klio_topfield__{s}", .{name});
            const raw_exists = blk: {
                const g = self.globals.borrow();
                defer g.deinit();
                break :blk g.get().lookup(raw) != null;
            };
            if (raw_exists) {
                defer if (runtime.freeScratch()) allocator.free(raw);
                return storeGlobal(self, allocator, raw, value);
            }
            if (runtime.freeScratch()) allocator.free(raw);
        }
    }
    if (registryHasDelegatedProp(self, name)) {
        const existing: ?Value = blk: {
            const g = self.globals.borrow();
            defer g.deinit();
            break :blk g.get().lookup(name);
        };
        if (existing) |d| {
            if (d != .Null) {
                const prop_ref = try makePropertyRef(allocator, name);
                const r = try self.callMember(allocator, &d, "setValue", &.{ Value.Null, prop_ref, value });
                if (r == .err) return .{ .err = r.err };
                return .{ .ok = {} };
            }
        }
    }

    // A `NotNull`/`Observable` slot takes the write through setValue semantics.
    const existing: ?Value = blk: {
        const g = self.globals.borrow();
        defer g.deinit();
        break :blk g.get().lookup(name);
    };
    if (existing) |ev| {
        if (ev == .Delegate) {
            const d = ev.Delegate;
            const kind: DelegateKind = blk2: {
                const g = d.borrow();
                defer g.deinit();
                break :blk2 g.get().*;
            };
            switch (kind) {
                .NotNull => |nn| {
                    const g = d.borrowMut();
                    defer g.deinit();
                    g.get().* = .{ .NotNull = .{ .value = value, .name = nn.name } };
                    return .{ .ok = {} };
                },
                .Observable => |ob| {
                    const old = ob.value;
                    const on_change = ob.on_change;
                    {
                        const g = d.borrowMut();
                        defer g.deinit();
                        g.get().* = .{ .Observable = .{ .value = value, .on_change = on_change } };
                    }
                    const prop_ref = try makePropertyRef(allocator, name);
                    const r = try self.callValue(allocator, &on_change, &.{ prop_ref, old, value });
                    if (r == .err) return .{ .err = r.err };
                    return .{ .ok = {} };
                },
                .Lazy => {},
            }
        }
    }

    // A boxed capture takes the write through the cell so every holder sees it.
    if (existing) |ev| {
        if (ev == .Cell) {
            const cg = ev.Cell.borrowMut();
            defer cg.deinit();
            if (runtime.reclaimEnabled()) {
                value.retain();
                cg.get().release(allocator);
            }
            cg.get().* = value;
            return .{ .ok = {} };
        }
    }

    // Assign through the scope chain so a write from a child scope mutates the
    // real top-level binding; only a genuinely new name defines here.
    const g = self.globals.borrowMut();
    defer g.deinit();
    if (g.get().assign(name, value) != null) {
        try g.get().define(name, value);
    }
    return .{ .ok = {} };
}

/// Whether `fid` names `name` in the MAIN module's table, the id space
/// lowering commits for cross-module calls; a sub-module frame validates here.
pub fn mainFuncNameMatches(self: *VmHost, fid: ir.FuncId, name: []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const f = mg.get().funcById(fid) orelse return false;
    return std.mem.eql(u8, f.name, name);
}

pub fn lookupGlobalThrowing(self: *VmHost, allocator: Allocator, name_in: []const u8) Allocator.Error!MaybeValueResult {
    var top_prop_buf: [256]u8 = undefined;
    const name = topPropReadKey(self, name_in, &top_prop_buf);
    if (runtime.envOnce("KLIO_GLOBAL_TRACE")) |w| {
        if (std.mem.eql(u8, w, name)) std.debug.print("[global-throwing] {s}\n", .{name});
    }
    const raw: ?Value = blk: {
        const g = self.globals.borrow();
        defer g.deinit();
        break :blk g.get().lookup(name);
    };

    // First access constructs the singleton and PROPAGATES an init failure that
    // the non-throwing `lookupGlobal` below would swallow.
    if ((raw == null or raw.? != .Instance) and progHasObjectName(self, name)) {
        switch (try ensureObjectSingleton(self, name)) {
            .ok => |maybe| if (maybe) |v| return .{ .ok = v },
            .err => |e| return .{ .err = e },
        }
    }
    // A package-qualified `object` reference is keyed by FQN: map it to the
    // simple name, but only when that name is a registered object.
    if (raw == null or raw.? != .Instance) {
        const obj_simple: ?[]const u8 = blk_obj: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const m = mg.get();
            const cid = m.classIdByFqn(name) orelse break :blk_obj null;
            if (cid.int() >= m.classes.items.len) break :blk_obj null;
            const simple = m.classes.items[cid.int()].name;
            if (!progHasObjectName(self, simple)) break :blk_obj null;
            break :blk_obj simple;
        };
        if (obj_simple) |simple| {
            switch (try ensureObjectSingleton(self, simple)) {
                .ok => |maybe| if (maybe) |v| return .{ .ok = v },
                .err => |e| return .{ .err = e },
            }
        }
    }
    if (raw) |rv| {
        if (rv == .Delegate) {
            const is_uninit_notnull = blk2: {
                const g = rv.Delegate.borrow();
                defer g.deinit();
                break :blk2 (g.get().* == .NotNull and g.get().NotNull.value == null);
            };
            if (is_uninit_notnull) {
                const fqn = try runtime.strInit(allocator, "kotlin.IllegalStateException");
                const msg_text = try std.fmt.allocPrint(allocator, "Property {s} should be initialized before get.", .{name});
                const msg = try runtime.strInitOwned(allocator, msg_text);
                return .{ .err = .{ .Throw = try Value.newException(allocator, .{ .fqn = fqn, .message = .from(msg), .cause = null }) } };
            }
        }
    }

    // An Instance-backed delegated property dispatches getValue and PROPAGATES
    // its throw; `lookupGlobal` swallows it and yields the delegate instead.
    if (registryHasDelegatedProp(self, name)) {
        if (raw) |rv| {
            if (rv != .Null) {
                const prop_ref = try makePropertyRef(allocator, name);
                const r = try self.callMember(allocator, &rv, "getValue", &.{ Value.Null, prop_ref });
                switch (r) {
                    .ok => |result| return .{ .ok = result },
                    .err => |e| return .{ .err = e },
                }
            }
        }
    }

    // `coroutineContext` as a plain global read: the active scope's context, or
    // the empty context from the root driver, unless a user global shadows it.
    if (raw == null and
        (std.mem.eql(u8, name, "coroutineContext") or
            std.mem.eql(u8, name, "kotlin.coroutines.coroutineContext")) and
        lookupGlobal(self, name) == null)
    {
        if (vmhost.coroutines.activeCoroScope()) |scope| {
            switch (try vmhost.host_fields.getField(self, allocator, &scope, "coroutineContext")) {
                .ok => |v| return .{ .ok = v },
                .err => {},
            }
            // A `Continuation(context) {}` completion declares only `context`.
            switch (try vmhost.host_fields.getField(self, allocator, &scope, "context")) {
                .ok => |v| return .{ .ok = v },
                .err => {},
            }
        }
        switch (try ensureObjectSingleton(self, "EmptyCoroutineContext")) {
            .ok => |maybe| if (maybe) |v| return .{ .ok = v },
            .err => |e| return .{ .err = e },
        }
    }

    const found = lookupGlobal(self, name);
    // A top-level `lateinit var` binds on first write; no binding is the error.
    if (found == null and registryHasLateinitProp(self, name)) {
        return .{ .err = try ir.eval.lateinitThrow(allocator, name) };
    }
    return .{ .ok = found };
}

/// Whether an ACTIVE scoped-global layer (captured enclosing locals) binds
/// `name`; it is nearer than any receiver's EXTENSION property.
pub fn scopedLocalBinds(self: *VmHost, name: []const u8) bool {
    const g = self.globals.borrow();
    defer g.deinit();
    if (!g.get().hasParent()) return false;
    return g.get().lookupLocal(name) != null;
}

pub fn isShadowingCapture(self: *VmHost, name: []const u8) bool {
    const g = self.globals.borrow();
    defer g.deinit();
    if (!g.get().hasParent()) {
        return false;
    }
    const v = g.get().lookupLocal(name) orelse return false;
    return switch (v) {
        .IrClosure => true,
        else => false,
    };
}

pub fn progHasObjectName(self: *VmHost, name: []const u8) bool {
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().object_names.contains(name);
}

fn progHasTopLevelPropInit(self: *VmHost, name: []const u8) bool {
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().top_level_prop_inits.contains(name);
}

fn registryHasDelegatedProp(self: *VmHost, name: []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    return mg.get().registry.top_level_delegated_props.contains(name);
}

pub fn registryHasLateinitProp(self: *VmHost, name: []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    return mg.get().registry.top_level_lateinit_props.contains(name);
}

fn makePropertyRef(allocator: Allocator, name: []const u8) Allocator.Error!Value {
    return .{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name) } };
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "looks_const recognizes constant-style identifiers" {
    try testing.expect(looksConst("PI"));
    try testing.expect(looksConst("MAX_VALUE"));
    try testing.expect(looksConst("SIZE_BITS"));
    try testing.expect(!looksConst("min"));
    try testing.expect(!looksConst("buildList"));
    try testing.expect(!looksConst(""));
}

test "is_primitive_type_name matches the builtin set only" {
    try testing.expect(isPrimitiveTypeName("Int"));
    try testing.expect(isPrimitiveTypeName("String"));
    try testing.expect(isPrimitiveTypeName("Number"));
    try testing.expect(!isPrimitiveTypeName("Widget"));
    try testing.expect(!isPrimitiveTypeName("List"));
}

test "ctor guard defaults empty" {
    try testing.expect(!host_instances.ctorGuardContains("Foo"));
}

const root = @import("../interp_ir.zig");
const Vm = root.Vm;

/// A `VmHost` over an empty-module `Vm`; every handle, the env, the program
/// image and any synthetic `ClassDef` are arena-backed for one `deinit()`.
const HostFixture = struct {
    vm: Vm,
    host: VmHost,
    cap: *runtime.CaptureOutput,

    fn init(arena: Allocator) !HostFixture {
        var module = Module.default(arena);
        try module.rebuildFuncNameIndex(arena);
        const module_ref = try ObjRef(Module).init(arena, module);
        const vm = try Vm.new(arena, module_ref);
        const cap = try arena.create(runtime.CaptureOutput);
        cap.* = runtime.CaptureOutput.init(arena);
        var self = HostFixture{ .vm = vm, .host = undefined, .cap = cap };
        self.host = self.vm.makeHost(cap.output());
        return self;
    }
};

test "store_global then lookup_global round-trips a plain binding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try HostFixture.init(a);

    const r = try storeGlobal(&fx.host, a, "answer", .{ .Int = 42 });
    try testing.expect(r == .ok);
    const got = lookupGlobal(&fx.host, "answer");
    try testing.expect(got != null);
    try testing.expect(got.? == .Int and got.?.Int == 42);
}

test "lookup_global resolves a primitive type name to a class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try HostFixture.init(a);

    const got = lookupGlobal(&fx.host, "Int");
    try testing.expect(got != null);
    try testing.expect(got.? == .Class);
    const cg = got.?.Class.borrow();
    defer cg.deinit();
    try testing.expectEqualStrings("Int", cg.get().name);
    try testing.expectEqualStrings("kotlin.Int", cg.get().fqn);
}

test "lookup_global resolves a primitive companion constant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try HostFixture.init(a);

    const got = lookupGlobal(&fx.host, "Int.MAX_VALUE");
    try testing.expect(got != null);
    try testing.expect(got.? == .Int and got.?.Int == std.math.maxInt(i32));
}

test "is_shadowing_capture is false at the top level" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try HostFixture.init(a);

    // The Vm's global env is the root scope, so a capture cannot shadow it.
    try testing.expect(!isShadowingCapture(&fx.host, "anything"));
}

test "object init gate: claim is once per thread, re-entrant, clearable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try HostFixture.init(a);

    try testing.expect(claimObjectInit(&fx.host, "O") == .construct);
    {
        const second = claimObjectInit(&fx.host, "O");
        try testing.expect(second == .reentrant);
        try testing.expect(second.reentrant == null);
    }

    try testing.expect(noteObjectInFlight(&fx.host, "O", .{ .Int = 7 }));
    {
        const third = claimObjectInit(&fx.host, "O");
        try testing.expect(third == .reentrant);
        try testing.expect(third.reentrant != null);
        try testing.expect(third.reentrant.?.Int == 7);
    }

    clearObjectState(&fx.host, "O");
    try testing.expect(claimObjectInit(&fx.host, "O") == .construct);
    clearObjectState(&fx.host, "O");

    try testing.expect(!noteObjectInFlight(&fx.host, "P", .{ .Int = 1 }));
}

test "object init gate: failed state throws the no-cause wrapper" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try HostFixture.init(a);

    // Register the name as an object so the gate consults the state table.
    {
        const pg = fx.host.prog.borrowMut();
        defer pg.deinit();
        try pg.get().object_names.put("O", {});
    }
    markObjectFailed(&fx.host, "O", null);
    try testing.expect(claimObjectInit(&fx.host, "O") == .failed);

    const r = try ensureObjectSingleton(&fx.host, "O");
    try testing.expect(r == .err);
    try testing.expect(r.err == .Throw);
    const exc = r.err.Throw;
    try testing.expect(exc == .Exception);
    const fg = exc.Exception.fqn.borrow();
    defer fg.deinit();
    try testing.expectEqualStrings(FILE_INIT_FAILED_FQN, fg.get().bytes);
    try testing.expect(exc.Exception.cause == null);
}

test "object init gate: unknown names resolve to null without state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try HostFixture.init(a);

    const r = try ensureObjectSingleton(&fx.host, "NotAnObject");
    try testing.expect(r == .ok);
    try testing.expect(r.ok == null);
    const g = fx.host.object_states.borrow();
    defer g.deinit();
    try testing.expect(g.get().count() == 0);
}

test "object singleton dedup: shared id registry serves a transient globals scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try HostFixture.init(a);

    // Register class "O" -> id 7 so `classId("O")` resolves.
    const id = ir.ClassId.from(7);
    {
        const mg = fx.host.module.borrowMut();
        defer mg.deinit();
        try mg.get().class_index.append(a, .{ .name = "O", .id = id });
    }

    // Publish only into the shared registry, never `globals`, mirroring a
    // singleton built under another context's transient scope.
    const cd = try primitiveClassDef(a, "O");
    const inst_ref = try ObjRef(InstanceData).init(a, .{
        .class = cd,
        .fields = .empty,
        .outer = null,
        .identity = 4242,
        .native_state = null,
    });
    {
        const sg = fx.host.singletons_by_id.borrowMut();
        defer sg.deinit();
        try sg.get().put(id.int(), .{ .Instance = inst_ref });
    }

    const got = singletonFromSharedRegistry(&fx.host, "O");
    try testing.expect(got != null);
    try testing.expect(got.? == .Instance);
    {
        const gg = got.?.Instance.borrow();
        defer gg.deinit();
        try testing.expectEqual(@as(u64, 4242), gg.get().identity);
    }

    try testing.expect(singletonFromSharedRegistry(&fx.host, "Unregistered") == null);
}
