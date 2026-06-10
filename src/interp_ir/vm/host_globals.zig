//! `VmHost` global resolution: reading and writing top-level names,
//! the throwing variant used during top-level init, the lazy
//! first-access `object` / companion initialization gate, and the
//! shadowing-capture check.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked directly by the generic IR evaluator.
//! The name-resolution probe chain in `lookupGlobal`
//! mirrors the Rust `lookup_global`: cached global, first-access
//! `object` init, top-level-property init, delegate auto-resolve, user
//! class/function, stdlib FQN probes, the loaded-pack overlay, the
//! synthetic `Thread`/`Delegates` surfaces, primitive type names and
//! their companion constants, package-qualified bare refs, and
//! typealias follow.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const vmhost = @import("vmhost.zig");
const host_impl = @import("host_impl.zig");
const host_instances = @import("host_instances.zig");

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

fn fileInitFailedThrow(allocator: Allocator, cause: ?Value) Allocator.Error!EvalError {
    const fqn = try StringRef.init(allocator, FILE_INIT_FAILED_FQN);
    const msg = try StringRef.init(allocator, FILE_INIT_FAILED_MSG);
    const cause_ptr: ?*Value = if (cause) |c| blk: {
        const p = try allocator.create(Value);
        p.* = c;
        break :blk p;
    } else null;
    return .{ .Throw = .{ .Exception = .{ .fqn = fqn, .message = msg, .cause = cause_ptr } } };
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
    /// A previous construction failed; throw without retrying.
    failed,
};

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
            .Failed => return .failed,
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
            .failed => return .{ .err = try fileInitFailedThrow(allocator, null) },
            .wait => {
                std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
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
                const g = self.globals.borrowMut();
                defer g.deinit();
                g.get().define(name, inst) catch {};
            }
            clearObjectState(self, name);
            return .{ .ok = inst };
        },
        .err => |e| {
            markObjectFailed(self, name);
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

/// Non-throwing gate for resolution chains that cannot carry an error
/// (`lookupGlobal`, pack-native lookups). An init failure resolves to
/// null here; the throwing read paths surface it.
pub fn objectSingletonQuiet(self: *VmHost, name: []const u8) ?Value {
    const r = ensureObjectSingleton(self, name) catch return null;
    return switch (r) {
        .ok => |v| v,
        .err => null,
    };
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
    {
        const g = self.globals.borrow();
        defer g.deinit();
        if (g.get().lookup(name)) |v| {
            if (v == .Instance) return .{ .ok = v };
        }
    }
    if (objectClassDeclaresProp(self, name, member) or objectClassDeclaresMethod(self, name, member)) {
        return ensureObjectSingleton(self, name);
    }
    return .{ .ok = null };
}

fn clearObjectState(self: *VmHost, name: []const u8) void {
    const g = self.object_states.borrowMut();
    defer g.deinit();
    _ = g.get().remove(name);
}

fn markObjectFailed(self: *VmHost, name: []const u8) void {
    const g = self.object_states.borrowMut();
    defer g.deinit();
    g.get().put(name, .Failed) catch {};
}

// -------------------------------------------------------------------------
// Intrinsic resolution / dispatch. The Rust equivalents live on `VmHost`
// in `vmhost.rs`; the resolution chain in `lookupGlobal` calls them, so
// they are kept here as file-local helpers over `*VmHost`.
// -------------------------------------------------------------------------

/// Look up an intrinsic by FQN. Probes the pack-supplied
/// `installed_bindings` overlay first so a loaded pack's binding shadows
/// the stdlib's default implementation.
fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
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
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = intrinsic.intrinsicHost(),
        .allocator = allocator,
    };
    const r = try func(&ctx);
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

/// Render a non-control-flow `RuntimeError` to the message text the Rust
/// `format!("{other}")` conversion produces.
fn runtimeErrorMessage(allocator: Allocator, e: RuntimeError) []const u8 {
    return switch (e) {
        .Unbound => |s| s,
        .Type => |s| s,
        .Arity => |s| s,
        .Unimplemented => |s| s,
        .NoMain => "no main function",
        else => std.fmt.allocPrint(allocator, "{any}", .{e}) catch "runtime error",
    };
}

/// Whether the function at `fid` is an extension (its first lowered
/// param is the synthetic `this`).
fn isExtFid(fid: FuncId, m: *const Module) bool {
    const f = idGet(m.funcs.items, fid.int()) orelse return false;
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
pub fn lookupGlobal(self: *VmHost, name: []const u8) ?Value {
    const allocator = self.allocator;

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
    if (cached == null and progHasTopLevelPropInit(self, name)) {
        const r = host_impl.ensureTopLevelInited(self, name) catch return null;
        if (r == .ok) {
            if (r.ok) |v| {
                if (v != .Null) return v;
            }
        }
    }

    if (registryHasDelegatedProp(self, name)) {
        if (cached) |v| {
            if (v == .Instance) {
                const prop_ref = makePropertyRef(allocator, name) catch return null;
                const r = self.callMember(allocator, &v, "getValue", &.{ Value.Null, prop_ref }) catch return null;
                if (r == .ok) return r.ok;
            }
        }
    }

    if (cached) |v| {
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
    // non-extension same-named sibling, otherwise fall through.
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        const chosen: ?FuncId = if (m.funcId(name)) |fid| pick: {
            if (isExtFid(fid, m)) {
                for (m.funcsBySimpleName(name)) |c| {
                    if (!isExtFid(c, m)) {
                        if (idGet(m.funcs.items, c.int())) |f| {
                            if (f.blocks.len != 0) break :pick c;
                        }
                    }
                }
                break :pick null;
            } else {
                break :pick fid;
            }
        } else null;
        if (chosen) |fid| {
            if (idGet(m.funcs.items, fid.int())) |func| {
                if (func.blocks.len != 0) {
                    const n_params = func.params.len;
                    const caps = ObjRef(std.ArrayList(Value)).init(allocator, .empty) catch return null;
                    const id = self.closures.push(.{
                        .body_func = fid,
                        .n_params = n_params,
                        .capture_names = &.{},
                        .captures = caps,
                    }) catch return null;
                    const empty = ValueSlice.init(allocator, &.{}) catch return null;
                    return .{ .IrClosure = .{ .id = id, .captures = empty } };
                }
            }
        }
    }

    // Probe stdlib by FQN for known package surfaces. A bare reference can
    // only bind a *top-level* function — probe the top-level packages
    // (`math`, `comparisons`, `io`) before the receiver-extension packages
    // so `min`/`max` resolve to `kotlin.math.min` rather than a collection
    // extension of the same name.
    {
        // Each probe owns a stable, heap-allocated FQN slice.
        const prefixes = [_]?[]const u8{
            null,
            "kotlin",
            "kotlin.math",
            "kotlin.comparisons",
            "kotlin.io",
            "kotlin.collections",
            "kotlin.text",
            "kotlin.ranges",
            "kotlin.concurrent",
            "kotlin.coroutines",
            "kotlin.coroutines.intrinsics",
            "kotlin.internal",
        };
        for (prefixes) |pre| {
            const fqn = if (pre) |p|
                (std.fmt.allocPrint(allocator, "{s}.{s}", .{ p, name }) catch return null)
            else
                (allocator.dupe(u8, name) catch return null);
            if (lookupIntrinsic(self, fqn)) |func| {
                const tail = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |i| fqn[i + 1 ..] else fqn;
                if (looksConst(tail)) {
                    const r = dispatchIntrinsic(self, allocator, fqn, func, &.{}) catch return null;
                    if (r == .ok) return r.ok;
                }
                return .{ .Intrinsic = .{ .fqn = fqn, .func = func } };
            }
            allocator.free(fqn);
        }
    }

    // Loaded packs register their FQNs in `installed_bindings`. For a
    // bare-name reference, scan the overlay for a key that ends with
    // `.{name}`. Runs after `direct_probes` so a top-level `kotlin.*`
    // function wins over a same-named receiver-extension.
    {
        const suffix = std.fmt.allocPrint(allocator, ".{s}", .{name}) catch return null;
        defer allocator.free(suffix);
        const pg = self.prog.borrow();
        defer pg.deinit();
        const bg = pg.get().installed_bindings.borrow();
        defer bg.deinit();
        var it = bg.get().table.iterator();
        while (it.next()) |entry| {
            if (std.mem.endsWith(u8, entry.key_ptr.*, suffix)) {
                return .{ .Intrinsic = .{ .fqn = entry.key_ptr.*, .func = entry.value_ptr.* } };
            }
        }
    }

    // `Thread` static surface — a synthetic intrinsic value exposing
    // `Thread.sleep(ms)` and `Thread.currentThread()`.
    if (std.mem.eql(u8, name, "Thread")) {
        return .{ .Intrinsic = .{ .fqn = "kotlin.concurrent.Thread", .func = threadStaticStub } };
    }

    // `Delegates` singleton — a synthetic intrinsic value exposing
    // `notNull`, `observable`, and `vetoable` member calls.
    if (std.mem.eql(u8, name, "Delegates")) {
        return .{ .Intrinsic = .{ .fqn = "kotlin.properties.Delegates", .func = delegatesStub } };
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
    if (registryHasDelegatedProp(self, name)) {
        const existing: ?Value = blk: {
            const g = self.globals.borrow();
            defer g.deinit();
            break :blk g.get().lookup(name);
        };
        if (existing) |d| {
            if (d == .Instance) {
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

pub fn lookupGlobalThrowing(self: *VmHost, allocator: Allocator, name: []const u8) Allocator.Error!MaybeValueResult {
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
    if (raw) |rv| {
        if (rv == .Delegate) {
            const is_uninit_notnull = blk2: {
                const g = rv.Delegate.borrow();
                defer g.deinit();
                break :blk2 (g.get().* == .NotNull and g.get().NotNull.value == null);
            };
            if (is_uninit_notnull) {
                const fqn = try StringRef.init(allocator, "kotlin.IllegalStateException");
                const msg_text = try std.fmt.allocPrint(allocator, "Property {s} should be initialized before get.", .{name});
                const msg = try StringRef.init(allocator, msg_text);
                return .{ .err = .{ .Throw = .{ .Exception = .{ .fqn = fqn, .message = msg, .cause = null } } } };
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
            if (rv == .Instance) {
                const prop_ref = try makePropertyRef(allocator, name);
                const r = try self.callMember(allocator, &rv, "getValue", &.{ Value.Null, prop_ref });
                switch (r) {
                    .ok => |result| return .{ .ok = result },
                    .err => |e| return .{ .err = e },
                }
            }
        }
    }

    return .{ .ok = lookupGlobal(self, name) };
}

pub fn isShadowingCapture(self: *VmHost, name: []const u8) bool {
    const g = self.globals.borrow();
    defer g.deinit();
    if (!g.get().hasParent()) {
        return false;
    }
    const v = g.get().lookupLocal(name) orelse return false;
    return switch (v) {
        .IrClosure, .Function => true,
        else => false,
    };
}

// -------------------------------------------------------------------------
// Small accessors over the shared program/module tables.
// -------------------------------------------------------------------------

fn progHasObjectName(self: *VmHost, name: []const u8) bool {
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
    return .{ .PropertyRef = .{ .name = try StringRef.init(allocator, name) } };
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
    markObjectFailed(&fx.host, "O");
    try testing.expect(claimObjectInit(&fx.host, "O") == .failed);

    const r = try ensureObjectSingleton(&fx.host, "O");
    try testing.expect(r == .err);
    try testing.expect(r.err == .Throw);
    const exc = r.err.Throw;
    try testing.expect(exc == .Exception);
    const fg = exc.Exception.fqn.borrow();
    defer fg.deinit();
    try testing.expectEqualStrings(FILE_INIT_FAILED_FQN, fg.get().*);
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
