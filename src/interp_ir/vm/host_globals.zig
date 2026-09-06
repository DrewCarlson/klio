//! `VmHost` global resolution: reading and writing top-level names,
//! the throwing variant used during top-level init, the lazy
//! first-access `object` / companion initialization gate, and the
//! shadowing-capture check.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked directly by the generic IR evaluator.
//! The name-resolution probe chain in `lookupGlobal` runs: cached
//! global, first-access `object` init, top-level-property init,
//! delegate auto-resolve, user class/function, stdlib FQN probes, the
//! loaded-pack overlay, the synthetic `Thread`/`Delegates` surfaces,
//! primitive type names and their companion constants, package-qualified
//! bare refs, and typealias follow.

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

const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalError = ir.eval.EvalError;
const MaybeValueResult = ir.eval.MaybeValueResult;
const UnitResult = ir.eval.UnitResult;
const SuspendState = ir.eval.SuspendState;

// -------------------------------------------------------------------------
// Lazy `object` / companion first-access initialization.
//
// Kotlin initializes an `object` singleton at its first access — never at
// program start, exactly once across all threads — and a companion
// additionally at the first instantiation of its owning class. The gate
// below owns that contract: every singleton read path (bare-name
// `LoadGlobal`, companion forwarding on a class receiver, qualified
// nested-object access, `::class.objectInstance`, pack natives) routes
// through `ensureObjectSingleton` instead of reading `globals` directly.
//
// State lives in the shared `object_states` table (one cell per program,
// shared by handle with every OS thread). The cell's writer lock
// serializes the first-access claim: the claiming thread constructs, any
// other thread that races the same name waits for the entry to resolve,
// and the constructing thread's own re-entrant reads observe the
// in-flight instance (an object referencing itself during its own init).
// The singleton publishes into `globals` only after construction
// completes, so no other thread can observe a partially-initialized
// instance. A construction failure is terminal: the initializer is never
// retried, and every access after the first failure throws
// `FileFailedToInitializeException` without the original cause, matching
// kotlinc.
// -------------------------------------------------------------------------

const ObjectInitState = root.ObjectInitState;

/// Wrapper thrown when an `object` / companion initializer fails, named
/// after the kotlinc-native exception so `e::class.simpleName` and catch
/// matching agree with the reference. It is an `Error`-side throwable:
/// `catch (e: Throwable)` and `catch (e: Error)` match it,
/// `catch (e: Exception)` does not.
pub const FILE_INIT_FAILED_FQN = "kotlin.native.internal.FileFailedToInitializeException";
const FILE_INIT_FAILED_MSG = "There was an error during file or class initialization";

/// Env-gated (`KLIO_INIT_DEBUG`) trace of the raw error that failed an
/// `object`/companion initializer, printed at the point of first failure so
/// the true root cause is visible even when later re-accesses (`.failed`)
/// bury it under a cause-less `FileFailedToInitializeException`.
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

/// What the claim step decided for one gate pass.
const ClaimOutcome = union(enum) {
    /// This thread inserted the in-progress entry and must construct.
    construct,
    /// Construction is already running on this thread; the in-flight
    /// instance (if the shell exists yet) is the singleton.
    reentrant: ?Value,
    /// Another thread is constructing — wait and re-check.
    wait,
    /// A previous construction failed; throw without retrying. Carries
    /// the stashed original cause when this is the first throwing read to
    /// reach the failure (take-once — later reads observe null).
    failed: ?Value,
};

/// The thread holding an in-flight construction claim for `key`, for
/// the wait diagnostic.
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

/// Record the just-materialized instance shell for an in-flight `object`
/// construction owned by the current thread, so re-entrant reads during
/// the rest of construction (delegates, body properties, init blocks)
/// observe the singleton. Returns false when no in-flight entry exists —
/// the construction was not driven through the gate (a runtime-registered
/// local object), and the caller publishes directly instead.
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

/// The instance already published for `name`'s class in the shared,
/// handle-shared `singletons_by_id` registry, or null. The registry is the
/// process-global store for `object` / companion singletons: unlike the
/// `globals` env (which can be a transient per-coroutine scope), it is
/// visible from every execution context, so it deduplicates a singleton
/// across scope boundaries.
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

/// Resolve a registered `object` / companion singleton by its lifted
/// global name, constructing it on first access. `.ok = null` when `name`
/// is not a registered object (or is mid-construction on this thread with
/// no shell yet); `.err` carries an init failure to the access site.
pub fn ensureObjectSingleton(self: *VmHost, raw_name: []const u8) Allocator.Error!MaybeValueResult {
    const allocator = self.allocator;
    // Fast path: already published (construction completed).
    {
        const g = self.globals.borrow();
        defer g.deinit();
        if (g.get().lookup(raw_name)) |v| {
            if (v == .Instance) return .{ .ok = v };
        }
    }
    // Canonicalize to the run-stable program-image key: callers may pass
    // a transient slice (a formatted `Outer$Nested` qualifier), and the
    // claim entry / `globals` binding outlive the call.
    const name = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().object_names.getKey(raw_name) orelse return .{ .ok = null };
    };
    // Process-global fallback: `globals` may be a transient per-context
    // scope (a coroutine frame's env is not the program root), so a
    // singleton published into one scope's `globals` is invisible to the
    // fast path of another. The id-keyed `singletons_by_id` registry is
    // shared by handle across every context, so it is the authoritative
    // store — consult it before (re)constructing, or the same `object` /
    // companion is materialized once per scope and identity comparisons
    // against it (e.g. `slot === Composer.Empty`) break.
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
            // Another thread is running the singleton's interpreted
            // constructor — an unbounded wait, so escalate from yield to
            // a millisecond park instead of burning a core until it
            // finishes (the sleep is GC blocking-safe).
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
        // Re-check `globals` after winning the claim: a finishing
        // constructor publishes and then clears its entry, so a thread
        // whose pre-claim globals check raced ahead of the publish could
        // otherwise construct a second instance. The claim's writer-lock
        // acquire orders after the finisher's clear, which is sequenced
        // after its publish, so the singleton is visible here.
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

    // This thread owns the claim. Any exit that does not publish must
    // resolve the entry, or racing threads would wait forever.
    const class_id_opt: ?ir.ClassId = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classId(name);
    };
    const class_id = class_id_opt orelse {
        clearObjectState(self, name);
        return .{ .ok = null };
    };
    // An object singleton is never an interface or abstract class; a
    // simple-name pick resolving to one is a collision with a nested/
    // scoped object the flat index cannot rank. Decline so the caller's
    // scope walk continues.
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
            // A companion's enclosing class is its `outer`, so
            // `this`-relative resolution inside companion members sees
            // the owning class's statics.
            if (std.mem.indexOf(u8, name, "$Companion$")) |sep| {
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
            // Publish, then resolve the claim. Publish-before-clear so a
            // waiter that re-checks `globals` after the entry vanishes
            // always finds the singleton.
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
            // First access surfaces the failure wrapped with the original
            // throwable as its cause; non-throw eval errors (an unresolved
            // call inside init) propagate as-is.
            switch (e) {
                .Throw => |cause| return .{ .err = try fileInitFailedThrow(allocator, cause) },
                else => return .{ .err = e },
            }
        },
    }
}

/// Id-directed singleton access, keyed by the class's FQN so a same-named
/// top-level value in another package can never satisfy (or be shadowed
/// by) this object's first access: `import ...server...ContentNegotiation`
/// must construct THE imported object even while the client package binds
/// the same simple name to a val. Publishes under the FQN, plus the simple
/// name when that is still unbound (uncollided readers keep the name key).
pub fn ensureObjectSingletonById(self: *VmHost, class_id: ir.ClassId) Allocator.Error!MaybeValueResult {
    const allocator = self.allocator;
    const fqn: []const u8, const simple: []const u8 = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (class_id.int() >= m.classes.items.len) return .{ .ok = null };
        break :blk .{ m.classes.items[class_id.int()].fqn, m.classes.items[class_id.int()].name };
    };
    // An object singleton is never an interface or abstract class: a
    // simple-name pick that resolves to one is a collision with a nested/
    // scoped object the flat index cannot rank (CoroutineContext.Key vs a
    // nested `object Key`). Decline so the caller's scope walk continues.
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
    // Process-global fallback ahead of the per-context `globals` fast path:
    // the id-keyed registry is shared by handle across every execution
    // context, so it deduplicates the singleton even when it was first
    // published into another scope's transient `globals` env.
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
            // Same escalation as the simple-name arm: the constructing
            // thread runs interpreted init, so park instead of spinning.
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
            // A companion's enclosing class is its `outer` (same wiring as
            // the name-keyed path): `this`-relative resolution inside
            // companion members must see the owning class's statics.
            if (std.mem.indexOf(u8, simple, "$Companion$")) |sep| {
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

/// Non-throwing gate for resolution chains that cannot carry an error
/// (`lookupGlobal`, pack-native lookups). An init failure resolves to
/// null here; the throwing read paths surface it. The swallowed wrapper's
/// original cause is put back into the failed state so the first THROWING
/// read still surfaces it — without this, a quiet gate driving the
/// construction consumed the cause and every visible throw was cause-less.
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

/// Put a swallowed init-failure cause back into the `.Failed` state entry
/// (keyed by the canonical object name), so the next throwing read's
/// take-once still surfaces it.
fn restashObjectCause(self: *VmHost, raw_name: []const u8, cause: Value) void {
    // Canonical program-image key when the name registry knows it; the
    // id-directed path marks failure under the raw FQN, so fall back to
    // the raw key (the entry lookup below tolerates a miss either way).
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

/// Whether the (possibly not-yet-initialized) singleton class
/// `class_name` declares member function `name`, transitively over its
/// supertypes. Drives the companion-forwarding call paths: a first access
/// only constructs the companion when the member genuinely lives on it,
/// so a miss probe (an enum entry, a nested class) does not initialize.
pub fn objectClassDeclaresMethod(self: *VmHost, class_name: []const u8, name: []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.hierarchy_methods.get(class_name)) |methods| {
        if (methods.contains(name)) return true;
    }
    return false;
}

/// Whether the (possibly not-yet-initialized) singleton class
/// `class_name` declares property `name`: body properties / primary
/// params along the runtime parent chain, a custom getter, or a
/// companion-scoped extension property.
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

/// Companion read gate for the speculative member-probe paths: resolve
/// the singleton when already initialized; construct it on first access
/// only when its class declares `name` (as a property or function).
pub fn objectSingletonForMember(self: *VmHost, name: []const u8, member: []const u8) Allocator.Error!MaybeValueResult {
    // The declares gate applies to the already-initialized fast path too:
    // an initialized companion (every `newInstance` initializes its
    // class's companions) must not be offered as the owner of a member
    // its class never declares, or the speculative probe redirects a call
    // whose real target is an extension on the original receiver.
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

/// Record a terminal init failure. `cause` (when set) is the original
/// throwable, retained into the state table so the first THROWING read can
/// surface it — the construction attempt may have been driven by a quiet
/// resolution gate whose wrapper never reached user code. A throwing
/// construction site passes null (it surfaces the cause itself).
fn markObjectFailed(self: *VmHost, name: []const u8, cause: ?Value) void {
    const g = self.object_states.borrowMut();
    defer g.deinit();
    if (cause) |c| {
        if (runtime.reclaimEnabled()) c.retain();
    }
    g.get().put(name, .{ .Failed = .{ .cause = cause } }) catch {};
}

// -------------------------------------------------------------------------
// Intrinsic resolution / dispatch. The resolution chain in `lookupGlobal`
// calls them, so they are kept here as file-local helpers over `*VmHost`.
// -------------------------------------------------------------------------

/// Look up an intrinsic by FQN. Probes the pack-supplied
/// `installed_bindings` overlay first so a loaded pack's binding shadows
/// the stdlib's default implementation.
fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
    // Post-link the bindings table is read-only; consult it unguarded
    // (gated on the published link flag) instead of taking two shared
    // reader locks per lookup.
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

/// Invoke an intrinsic with `args`, building the `VmIntrinsicHost`
/// side-channel so HOF bindings can call back into IR-lowered lambdas.
/// Maps a thrown / control-flow `RuntimeError` onto the matching
/// `EvalError`, preserving the thrown `Value` for try/catch matching.
fn dispatchIntrinsic(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!union(enum) { ok: Value, err: EvalError } {
    vmhost.emitPath(allocator, "intrinsic_globals", fqn, null, null, args);
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePushSlice(args);
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
            // Preserve the thrown Value so the IR evaluator's try/catch
            // can match the handler against the exception class.
            .Thrown => |v| .{ .err = .{ .Throw = v } },
            .Return => |v| .{ .err = .{ .NonLocalReturn = v } },
            // A suspending primitive asked to park. Seed a fresh
            // SuspendState; each enclosing `eval` frame snapshots itself
            // as it unwinds and the coroutine driver parks the result.
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

/// Render a non-control-flow `RuntimeError` to its message text.
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

/// Whether the function at `fid` is an extension (its first lowered
/// param is the synthetic `this`).
fn isExtFid(fid: FuncId, m: *const Module) bool {
    const f = m.funcById(fid) orelse return false;
    if (f.params.len == 0) return false;
    return std.mem.eql(u8, f.params[0].name, "this");
}

fn idGet(funcs: []const ir.Func, idx: u32) ?*const ir.Func {
    if (idx >= funcs.len) return null;
    return &funcs[idx];
}

/// All-uppercase / underscore / digit final segment — Kotlin's constant
/// naming convention (`PI`, `MAX_VALUE`).
fn looksConst(tail: []const u8) bool {
    if (tail.len == 0) return false;
    for (tail) |c| {
        if (!(std.ascii.isUpper(c) or c == '_' or std.ascii.isDigit(c))) return false;
    }
    return true;
}

/// Synthetic `Thread` static surface stub: any direct call is an error;
/// the static-call probe routes `Thread.sleep` / `Thread.currentThread`
/// through the `kotlin.concurrent.Thread.*` bindings.
fn threadStaticStub(ctx: *CallCtx) Allocator.Error!runtime.EvalResult {
    _ = ctx;
    return .{ .err = .{ .Type = "Thread: use Thread.sleep(ms) / Thread.currentThread()" } };
}

/// Synthetic `Delegates` singleton stub: member calls (`notNull`,
/// `observable`, `vetoable`) are intercepted in `call_member`.
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

/// Build a synthetic `ClassDef` for a primitive type name so `Int::class`
/// and `Int.MAX_VALUE` resolve. The simple name plus a `kotlin.*` fqn back
/// reflection-style reads.
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

// -------------------------------------------------------------------------
// Public host functions.
// -------------------------------------------------------------------------

/// Resolve a top-level / qualifier-position name to a `Value`. One ordered
/// probe chain (cached global, delegate auto-resolve, user class/function,
/// stdlib FQN probes, synthetic class names, typealias follow); splitting
/// it would fragment the fallthrough.
/// The runtime value of one exact top-level function: a closure over its
/// lowered body, or — for a bodyless decl whose single executable form
/// was settled at link time — that native binding. Null when the func id
/// is unknown or carries neither form.
fn funcValueById(self: *VmHost, allocator: Allocator, fid: FuncId) ?Value {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    const func = m.funcById(fid) orelse return null;
    if (func.hasBody()) {
        const caps = ObjRef(std.ArrayList(Value)).init(allocator, .empty) catch return null;
        const id = self.closures.push(.{
            .body_func = fid,
            .n_params = func.params.len,
            .receiver_shape_known = func.lambda_receiver_shape_known,
            .has_receiver = func.lambda_has_receiver,
            .capture_names = &.{},
            .captures = caps,
        }) catch return null;
        const empty = ValueSlice.init(allocator, &.{}) catch return null;
        return .{ .IrClosure = .{ .id = id, .captures = empty } };
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

/// Resolve a lowering-bound global reference by exact identity: the
/// symbol index already picked the declaration, so no name-keyed
/// re-resolution can swap in a same-simple-name twin. Returns null when
/// the id carries no runtime value (the caller falls back to the
/// name-keyed path).
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
        // A `@LowPriorityInOverloadResolution` / deprecated-stub function is
        // never bound by id: it must not outrank a same-name class constructor
        // (kotlinc), and a stub whose body calls the constructor by name would
        // re-bind itself and recurse without bound (kotlinx-datetime's
        // deprecated `fun LocalDateTime(...)`). Skip it so the class leg — or,
        // when the committed class id is absent, the caller's name-keyed lookup
        // — finds the constructor instead.
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
        // The id table is the authoritative singleton read: publication
        // under a name can never shadow what a committed class id yields.
        if (!ctor_ref) {
            const sg = self.singletons_by_id.borrow();
            const own = sg.get().get(cid.int());
            sg.deinit();
            if (own) |v| return v;
            // A class with a companion answers with the companion's
            // published singleton by ID as well. This must be the class's OWN
            // companion (a DIRECT child) — not `classIdNestedIn`, which walks up
            // the enclosing chain, so a nested class with no companion of its
            // own (`enum LayoutNode.LayoutState`) would wrongly answer with the
            // ENCLOSING class's companion, turning the nested-class value into
            // `Outer.Companion`.
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
                // An `object` in value position is its singleton, not
                // the bare class value (matching the name-keyed read).
                // Only an already-published singleton resolves here;
                // first-access construction stays with the name-keyed
                // throwing path, which drives the init gate exactly once
                // and surfaces an init failure with its cause.
                const cls_name, const is_object = blk: {
                    const dg = def.borrow();
                    defer dg.deinit();
                    break :blk .{ dg.get().name, dg.get().is_object };
                };
                // In value position a class with a companion is its companion
                // singleton (Kotlin: `C` ⇒ `C.Companion`); a plain `object` is
                // its own singleton. Both only when the singleton is already
                // published — first access stays on the name-keyed throwing
                // path that drives the init gate once.
                const singleton_name: ?[]const u8 = blk: {
                    // A constructor reference (`::C`) is the class, never
                    // the companion; an `object`'s singleton still applies
                    // (its "constructor" is the singleton itself).
                    if (ctor_ref and !is_object) break :blk null;
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    const m = mg.get();
                    // `companion_singletons` is keyed by SIMPLE class name, so a
                    // different class of the same simple name (e.g. a nested
                    // value class in another pack sharing a top-level enum's
                    // name) would otherwise hijack this resolution — routing the
                    // enum to the other class's companion. Only forward to the
                    // companion when it actually belongs to THIS class (cid):
                    // either cid declares a nested `Companion`, or the recorded
                    // singleton name is one of cid's own lifted members (a
                    // lifted companion is renamed away from the literal
                    // `Companion`, e.g. `LineHeightStyle$Alignment$Companion$…`).
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
                        // Identity-keyed: an already-built singleton reads
                        // by FQN. Unbuilt, the name-keyed throwing path owns
                        // first construction (its claim carries the init
                        // failure with its cause) — EXCEPT when the simple
                        // name is already bound to a FOREIGN value (a
                        // cross-package top-level val colliding with the
                        // imported object): then only the id-directed path
                        // can ever construct it.
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
                        // Our own singleton published under the simple name
                        // (the name-keyed first construction) is not a
                        // collision — return it, never rebuild.
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
                        // First-access construction driven by the authoritative
                        // id. The caller committed an exact object class id, so
                        // build it directly rather than deferring to the
                        // name-keyed path — which cannot construct a
                        // collision-mangled object (two packages share the
                        // simple name `Operation.InsertSlotsWithFixups`, so the
                        // bare name is ambiguous / mangled out of the flat
                        // index). `ensureObjectSingletonById` shares the same
                        // init gate (`claimObjectInit`), so this stays
                        // once-only; `simple_bound` is irrelevant now.
                        const rr = ensureObjectSingletonById(self, cid) catch return null;
                        return switch (rr) {
                            .ok => |maybe| if (maybe) |v| (if (v == .Instance) v else null) else null,
                            // This lookup has no error channel; the throwing
                            // read path re-surfaces the failure. Put the
                            // swallowed wrapper's original cause back into
                            // the failed state so that throw still carries it.
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
                    // The companion is not published yet: the bound class
                    // itself is the value (member dispatch on it reaches the
                    // companion), never a same-named global of another
                    // package.
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
/// custom setter but a DEFAULT getter keeps its storage under the raw
/// `__klio_topfield__` key (so plain-name writes dispatch the setter); the
/// plain-name read IS the raw-slot read. A property with a custom getter
/// keeps the plain-name miss so the getter thunk dispatches instead.
fn topPropReadKey(self: *VmHost, name: []const u8, buf: []u8) []const u8 {
    const reg = &self.module.asPtr().registry;
    if (reg.top_level_prop_setters.count() == 0) return name;
    if (std.mem.startsWith(u8, name, "__klio_topfield__")) return name;
    if (reg.top_level_prop_setters.get(name) == null) return name;
    if (reg.top_level_prop_getters.get(name) != null) return name;
    return std.fmt.bufPrint(buf, "__klio_topfield__{s}", .{name}) catch name;
}

/// A leaf serve's global read: the already-bound value under the effective
/// storage key, immediate scalars only. No initializer, singleton gate, or
/// delegate is driven — any name whose read would need one misses here and
/// the serve abandons to the frame path, which drives it exactly once.
/// A custom-getter property has no plain binding, so it misses naturally.
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

/// Whether a bare simple-name global-fn pick is visible from the
/// executing reference site (frame package + current statement's file).
/// No frame context, or a candidate without package metadata, keeps the
/// pick — only a confirmed unimported foreign package rejects it.
fn bareGlobalFnVisible(self: *VmHost, m: *const Module, fid: FuncId, name: []const u8) bool {
    _ = self;
    const f = m.funcById(fid) orelse return true;
    if (f.package.len == 0) return true;
    const ref_file: ?ir.FileId = ir.eval.refSiteFile() orelse
        (if (ir.eval.currentCallSiteSpan()) |sp| sp.file else null);
    // The reference package follows the executing statement's FILE when
    // the module records it (synthesized accessor frames carry no
    // package of their own); the frame's declared package is the
    // fallback. No context at all keeps the pick.
    const file_pkg: ?[]const u8 = if (ref_file) |rf| m.packageOfFile(rf) else null;
    const ref_pkg = file_pkg orelse (ir.eval.nearestFramePackage() orelse return true);
    const cfile = ref_file orelse ir.FileId.from(std.math.maxInt(u32));
    return m.scopeTier(f.fqn, f.package, name, ref_pkg, cfile) != ir.Module.other_package_tier;
}

/// Bind a reified type-parameter NAME to the class value its type-ARGUMENT
/// name resolves to, returning the shadowed global for restore. The same
/// binding `callFuncTyped` installs, exposed for dispatch sites that must
/// keep the normal member walk (its enclosing pushes) while a committed
/// inline member's reified parameters stay live.
pub fn bindTypeParamGlobal(self: *VmHost, tp_name: []const u8, arg_name_in: []const u8) ?Value {
    // A stamped generic spelling (`List<Int>`) resolves its class by head;
    // a nullable spelling (`A?`) by the class it names.
    const arg_head = if (std.mem.indexOfScalar(u8, arg_name_in, '<')) |lt| arg_name_in[0..lt] else arg_name_in;
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

/// The FULL generic spelling of a bound type argument, kept beside the
/// class binding under `<tp><>` so a `typeOf<T>()` reached through the
/// framed body materialises the arguments. Returns the previous value of
/// the spelling key; null when the spelling carries no arguments (nothing
/// is bound then).
pub fn bindTypeParamSpelling(self: *VmHost, allocator: Allocator, tp_name: []const u8, arg_name_in: []const u8) ?struct { key: []const u8, prev: ?Value } {
    // Arguments or nullability: both are the KType's business, and the
    // class binding alone carries neither.
    if (std.mem.indexOfScalar(u8, arg_name_in, '<') == null and !std.mem.endsWith(u8, arg_name_in, "?")) return null;
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

/// Threadlocal memo of the two snapshot-core globals the snapshot-fast
/// `currentSnapshot` serve reads per call: probing the shared globals
/// cell's reader lock from every worker on every read ping-ponged its
/// line under the concurrent map test (the serve LOST 30% to the framed
/// path there while winning 30% single-threaded). Both are top-level
/// `private val`s — the VALUES never change within a program; the
/// dispatch-cache generation invalidates across program boundaries.
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
    // A NULLABLE type spelling (`A?` bound as a reified argument) names
    // the same class; nullability is the KType's business.
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

    // First access to an `object` / companion singleton constructs it —
    // once, thread-safe — through the shared gate. A non-Instance cached
    // value still drives the gate: a user object outranks a same-named
    // implicit stdlib alias pre-defined in globals (`object E` vs
    // `kotlin.math.E`). Errors cannot surface through this non-throwing
    // chain (a failed init resolves to null and falls through);
    // `lookupGlobalThrowing` drives the gate on the throwing read path
    // and propagates the failure to the access site.
    if ((cached == null or cached.? != .Instance) and progHasObjectName(self, name)) {
        if (objectSingletonQuiet(self, name)) |v| return v;
    }

    // Top-level property whose own initializer has not produced its value
    // yet: a deferred prop (`cached == null`) is driven on first access.
    // During the startup pass an annotated property read ahead of its
    // initializer resolves to its declared type's default instead — and
    // that default must surface even when it is `Null` (a forward-read
    // String prints "null" on the JVM), so it returns before the
    // Null-dropping unwrap below.
    if (cached == null and progHasTopLevelPropInit(self, name)) {
        if (host_impl.pendingTypedDefault(self, name)) |d| return d;
        const r = host_impl.ensureTopLevelInited(self, name) catch return null;
        if (r == .ok) {
            if (r.ok) |v| {
                if (v != .Null) return v;
            }
        }
    }

    // Any value with a `getValue` operator (member or extension) can be the
    // delegate: a `String` delegate reads through `String.getValue`.
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
        // Delegate auto-resolve for top-level `var/val X by <delegate>`.
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
                    // Reading a `Delegates.notNull` slot before it has
                    // been written throws IllegalStateException per
                    // Kotlin; the non-throwing path returns null here.
                    return null;
                },
                .Observable => |ob| {
                    return ob.value;
                },
            }
        }
        // A boxed capture (an anon-object method's captured outer `var`)
        // reads THROUGH the cell; the cell itself is a carrier, never a
        // user value.
        if (v == .Cell) {
            const cg = v.Cell.borrow();
            defer cg.deinit();
            return cg.get().*;
        }
        return v;
    }

    // User-class lookup: a `Value.Class` lets call sites like `Foo(args)`
    // dispatch through new_instance and lets reflection resolve.
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(name)) |def| {
            return .{ .Class = def.clone() };
        }
    }

    // User-declared top-level function: surface its body via a synthetic
    // closure value so `val f = ::name; f(args)` routes through call_value.
    // A bare (unqualified, receiverless) reference must never resolve to
    // an extension function (a synthetic `this` first param) — prefer a
    // non-extension same-named sibling, otherwise fall through. A dotted
    // name is an exact-FQN reference (the lowerer's index-resolved
    // emission); it binds that one declaration or nothing.
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        // A dotted name is an exact-FQN reference, but it must still
        // never bind an extension form: a top-level extension twin
        // shares the receiverless FQN string (`build` puts no receiver
        // segment in `Func.fqn`), and a value reference cannot supply
        // its receiver — so the non-extension declaration under the FQN
        // is the only candidate.
        const by_fqn: ?FuncId = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| pick: {
            // Match by simple name (lazy-friendly), then confirm the full fqn.
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
        // A bare simple-name pick must be visible from the executing
        // reference site: a first-registered namesake from an unimported
        // foreign package (`androidx...unit.max` for a `kotlin.math.*`
        // caller) is not Kotlin's target — prefer a visible sibling, or
        // fall through so the stdlib/intrinsic resolution below serves
        // the name. Exact-FQN (dotted) references bind as written.
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
                    // Discard the invisible pick only when something
                    // visible can actually serve the name — a visible
                    // sibling, or the stdlib/intrinsic resolution below.
                    // Otherwise keep the lenient pick: turning a
                    // previously-resolving reference into `unresolved
                    // global` breaks receivers the walk still serves
                    // (`LongSparseArray.set` reached through an inline
                    // splice with no import record at runtime).
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

    // Stdlib resolution: an exact-FQN reference (the lowerer emits dotted
    // names fully qualified) resolves directly; a bare simple name
    // resolves through the link-settled name → FQN maps — the
    // default-import map over the implicit stdlib surface, then the
    // pack-binding bare aliases. One deterministic edge per name, built
    // once by `linkResolvedForms`, replacing the per-call prefix-probe
    // ladder and the hash-order suffix scan.
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
                // `m` is a program-lifetime string (the instruction's const-pool
                // name, or a prog-owned default-import / pack-alias entry), so the
                // resolved value can borrow it directly: `Intrinsic.fqn` is a raw
                // slice the collector never frees, and a duped copy would leak on
                // every discarded bare-name intrinsic reference.
                const fqn = m;
                if (trace.enabled(name)) {
                    trace.emit("map=global_fqn name={s} fqn={s}", .{ name, fqn });
                }
                const tail = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |i| fqn[i + 1 ..] else fqn;
                if (looksConst(tail)) {
                    const r = dispatchIntrinsic(self, allocator, fqn, func, &.{}) catch return null;
                    if (r == .ok) return r.ok;
                }
                if (gtrace) std.debug.print("[gtrace] {s} arm=intrinsic fqn={s}\n", .{ name, fqn });
                return Value.internIntrinsic(fqn, func);
            }
        }
    }

    // `Thread` static surface — a synthetic intrinsic value exposing
    // `Thread.sleep(ms)` and `Thread.currentThread()`.
    if (std.mem.eql(u8, name, "Thread")) {
        return Value.internIntrinsic("kotlin.concurrent.Thread", threadStaticStub);
    }

    // `Delegates` singleton — a synthetic intrinsic value exposing
    // `notNull`, `observable`, and `vetoable` member calls.
    if (std.mem.eql(u8, name, "Delegates")) {
        return Value.internIntrinsic("kotlin.properties.Delegates", delegatesStub);
    }

    // Primitive type names — `Int`, `Long`, `String`, etc. — resolve to a
    // synthetic `Value.Class` so `Int::class` and `Int.MAX_VALUE` work.
    if (isPrimitiveTypeName(name)) {
        const def = primitiveClassDef(allocator, name) catch return null;
        return .{ .Class = def };
    }

    // Primitive-companion constants (`Int.MAX_VALUE`, `Double.NaN`, …).
    // The IR lowers these as a single dotted-name global ref; split on
    // `.` and consult the stdlib's primitive-companion table.
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        const ty = name[0..dot];
        const member = name[dot + 1 ..];
        if (stdlib.primitive_companion_const(ty, member)) |v| {
            return v;
        }
    }

    // Package-qualified reference (not a call) to a user / pack top-level
    // class. The class table is keyed by simple name, so retry the
    // trailing segment. Reached only after every other probe returned
    // null, so a name that already resolves is untouched.
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        const tail = name[dot + 1 ..];
        if (!std.mem.eql(u8, tail, name) and tail.len != 0) {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(tail)) |def| {
                return .{ .Class = def.clone() };
            }
        }
    }

    // `typealias Alias = Target` — resolve the alias to the aliased
    // declaration. Follow chains with a cycle guard.
    {
        var seen: std.ArrayListUnmanaged([]const u8) = .empty;
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
        // A top-level `var` with a custom setter: the plain-name write runs
        // the setter thunk. Its own `field =` write targets the raw
        // `__klio_topfield__` storage key, which skips this dispatch.
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
        // Storage moved to the raw key (custom getter over a backing
        // field, default setter): a plain-name write with no plain
        // binding lands on the raw storage binding.
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

    // Delegate-aware write: if the slot currently holds a
    // `Value.Delegate(NotNull/Observable)`, route the write through the
    // delegate's setValue semantics. Observable fires its on_change
    // callback (oldValue, newValue).
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

    // A boxed capture (shared Cell) takes the write THROUGH the cell so
    // every holder observes it — an anon-object method writing a captured
    // outer `var` must not replace the binding in its transient capture
    // layer.
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

    // Assign through the scope chain so a write to an existing (top-level)
    // binding from inside a child scope mutates the real global instead of
    // shadowing it with a transient local. Only a genuinely new name
    // defines here.
    const g = self.globals.borrowMut();
    defer g.deinit();
    if (g.get().assign(name, value) != null) {
        try g.get().define(name, value);
    }
    return .{ .ok = {} };
}

/// Whether `fid` names `name` in the MAIN module's function table — the id
/// space lowering commits for cross-module bare calls. A sub-module frame
/// validates a committed id here before serving it by id.
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

    // First access to an `object` / companion singleton: construct it and
    // PROPAGATE an init failure to the access site (the non-throwing
    // `lookupGlobal` below would swallow it). A non-Instance cached value
    // still drives the gate — a user object outranks a same-named
    // implicit stdlib alias pre-defined in globals.
    if ((raw == null or raw.? != .Instance) and progHasObjectName(self, name)) {
        switch (try ensureObjectSingleton(self, name)) {
            .ok => |maybe| if (maybe) |v| return .{ .ok = v },
            .err => |e| return .{ .err = e },
        }
    }
    // A package-qualified reference to an `object` (`demo.Singleton`,
    // `androidx…drawscope.Fill`) is keyed by its FQN, not the by-simple-name
    // object registry, so the read above misses and the raw global is the
    // classifier. Map the FQN to the object's simple name and resolve through
    // the SAME path the bare name takes, so both yield the one singleton — but
    // only when the FQN names a genuine object (its simple name is a registered
    // object), so a qualified reference to a regular class stays the class value.
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

    // Top-level delegated property backed by an Instance delegate (e.g.
    // `by Delegates.notNull()` which inlines to a NotNullProperty
    // instance): dispatch getValue and PROPAGATE its throw. `lookupGlobal`
    // calls getValue too but swallows the error and falls back to the
    // delegate instance, so a NotNullProperty read-before-init silently
    // yielded the delegate instead of throwing IllegalStateException.
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

    // Suspend-implicit `coroutineContext` intrinsic reached as a plain
    // global read (a top-level suspend body has no receiver to probe):
    // the active coroutine scope's context, or — from the root driver,
    // e.g. `suspend fun main` — the empty context. Only when no user
    // global shadows the name.
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
            // A `startCoroutine` completion built by the stdlib
            // `Continuation(context) {}` factory declares only `context`;
            // the intrinsic is the current continuation's context, so read
            // that before falling back to the empty context.
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

    return .{ .ok = lookupGlobal(self, name) };
}

/// Whether an ACTIVE scoped-global layer (a runtime-lowered method body's
/// captured enclosing locals) binds `name`. The layered lookup is the
/// runtime materialization of a nearer lexical scope, so a hit here
/// outranks any implicit receiver's EXTENSION property in bare-name
/// resolution (real members stay nearer — the caller checks those first).
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

// -------------------------------------------------------------------------
// Small accessors over the shared program/module tables.
// -------------------------------------------------------------------------

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

fn makePropertyRef(allocator: Allocator, name: []const u8) Allocator.Error!Value {
    return .{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name) } };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

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

/// A `VmHost` over an empty-module `Vm`, allocated from a caller-owned
/// arena. Every shared handle, the env, the program image, and any
/// synthetic `ClassDef` `lookupGlobal` builds are arena-backed, so a
/// single `arena.deinit()` reclaims them — the runtime `ClassDef` has no
/// destructor (it is arena-owned in the real build), so leak-checked
/// per-handle frees would otherwise report it.
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

    // The Vm's global env is the root scope (no parent), so a capture can
    // never shadow it.
    try testing.expect(!isShadowingCapture(&fx.host, "anything"));
}

test "object init gate: claim is once per thread, re-entrant, clearable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try HostFixture.init(a);

    // First claim wins construction; a re-entrant claim on the same
    // thread observes the in-flight state instead of re-constructing.
    try testing.expect(claimObjectInit(&fx.host, "O") == .construct);
    {
        const second = claimObjectInit(&fx.host, "O");
        try testing.expect(second == .reentrant);
        try testing.expect(second.reentrant == null);
    }

    // Recording the in-flight shell makes re-entrant access observe it.
    try testing.expect(noteObjectInFlight(&fx.host, "O", .{ .Int = 7 }));
    {
        const third = claimObjectInit(&fx.host, "O");
        try testing.expect(third == .reentrant);
        try testing.expect(third.reentrant != null);
        try testing.expect(third.reentrant.?.Int == 7);
    }

    // Clearing resolves the entry; the next claim constructs again.
    clearObjectState(&fx.host, "O");
    try testing.expect(claimObjectInit(&fx.host, "O") == .construct);
    clearObjectState(&fx.host, "O");

    // An in-flight note with no entry reports not-gate-driven.
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
    // No state entry is left behind for a non-object name.
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

    // Publish an object instance ONLY into the shared, handle-shared
    // `singletons_by_id` registry — never into `globals`. This mirrors a
    // companion / `object` singleton that was first constructed under
    // another execution context whose `globals` env is a transient
    // per-coroutine scope, invisible to this context's fast path.
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

    // The registry must serve the SAME instance even though the current
    // `globals` env has no "O" binding — otherwise a second instance is
    // materialized per scope and `===` against the singleton breaks.
    const got = singletonFromSharedRegistry(&fx.host, "O");
    try testing.expect(got != null);
    try testing.expect(got.? == .Instance);
    {
        const gg = got.?.Instance.borrow();
        defer gg.deinit();
        try testing.expectEqual(@as(u64, 4242), gg.get().identity);
    }

    // No class id, or no registry entry for the id, yields null.
    try testing.expect(singletonFromSharedRegistry(&fx.host, "Unregistered") == null);
}
