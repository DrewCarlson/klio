//! `VmHost` global resolution: reading and writing top-level names,
//! the throwing variant used during top-level init, on-demand lazy
//! `object` initialization, and the shadowing-capture check.
//!
//! Free functions over `*VmHost`, wired into the `ir.eval.Host` vtable
//! by `vmhost.zig`. The name-resolution probe chain in `lookupGlobal`
//! mirrors the Rust `lookup_global`: cached global, deferred-`object`
//! init, top-level-property init, delegate auto-resolve, user
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
// Thread-local re-entrancy state. Mirrors the `lib.rs` thread-locals the
// Rust `lookup_global` reads: the active-constructor guard stack (a
// deferred `object` is only driven on-access when its own ctor is not
// already running) and the in-top-level-init flag (a forward reference
// during startup re-drives the real initializer rather than observing the
// `Null` placeholder).
// -------------------------------------------------------------------------

threadlocal var ctor_guard: std.ArrayListUnmanaged([]const u8) = .empty;
threadlocal var top_level_init_depth: usize = 0;

/// True while a top-level property initializer is running on this thread.
fn inTopLevelInit() bool {
    return top_level_init_depth > 0;
}

/// True when `name` is on the active-constructor guard stack.
fn ctorGuardContains(name: []const u8) bool {
    for (ctor_guard.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
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
fn dispatchIntrinsic(self: *VmHost, allocator: Allocator, func: StdlibFn, args: []const Value) Allocator.Error!union(enum) { ok: Value, err: EvalError } {
    var intrinsic = VmIntrinsicHost{
        .scheduler = self.scheduler,
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
        .parent = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .interfaces = try ObjRef(std.ArrayList(ObjRef(ClassDef))).init(allocator, .empty),
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = false,
        .secondary_ctors = &.{},
        .enum_entries = try ObjRef(std.ArrayList(ClassDef.EnumEntry)).init(allocator, .empty),
        .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .nested_classes = try ObjRef(std.ArrayList(ClassDef.NestedClass)).init(allocator, .empty),
        .captured_env = env,
        .supertype_delegates = try ObjRef(std.ArrayList(runtime.SupertypeDelegate)).init(allocator, .empty),
        .delegate_forwarders = try ObjRef(std.ArrayList(runtime.MethodDef)).init(allocator, .empty),
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

    // On-demand init of a deferred `object`: its eager startup init threw
    // (a missing dependency it is never expected to need unless used), so
    // it was skipped. Initialize it now, on first access, matching
    // Kotlin's lazy `object` initialization.
    if (cached == null and progHasObjectName(self, name) and !ctorGuardContains(name)) {
        const class_id_opt: ?ir.ClassId = blk_cid: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk_cid mg.get().classId(name);
        };
        if (class_id_opt) |class_id| {
            const iface = self.hostInterface();
            const r = iface.newInstance(allocator, class_id, &.{}) catch return null;
            if (r == .ok and r.ok == .Instance) {
                const inst = r.ok;
                if (std.mem.indexOf(u8, name, "$Companion$")) |sep| {
                    const outer_name = name[0..sep];
                    const outer_def: ?ObjRef(ClassDef) = blk2: {
                        const cg = self.classes.borrow();
                        defer cg.deinit();
                        if (cg.get().get(outer_name)) |c| break :blk2 c.clone();
                        break :blk2 null;
                    };
                    if (outer_def) |od| {
                        const ig = inst.Instance.borrowMut();
                        defer ig.deinit();
                        ig.get().outer = .{ .Class = od };
                    }
                }
                {
                    const g = self.globals.borrowMut();
                    defer g.deinit();
                    g.get().define(name, inst) catch return null;
                }
                return inst;
            }
        }
    }

    // Top-level property whose own initializer has not produced its value
    // yet. A deferred prop (`cached == null`) is re-driven on first
    // access; a forward reference during startup (`Null` placeholder,
    // still inside top-level init) is driven so the real value is seen.
    if (progHasTopLevelPropInit(self, name) and
        (cached == null or (inTopLevelInit() and cached != null and cached.? == .Null)))
    {
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
                const iface = self.hostInterface();
                const r = iface.callMember(allocator, &v, "getValue", &.{ Value.Null, prop_ref }) catch return null;
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
                    const iface = self.hostInterface();
                    const r = iface.callValue(allocator, &prod, &.{}) catch return v;
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
                    const r = dispatchIntrinsic(self, allocator, func, &.{}) catch return null;
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
                const iface = self.hostInterface();
                const r = try iface.callMember(allocator, &d, "setValue", &.{ Value.Null, prop_ref, value });
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
                    const iface = self.hostInterface();
                    const r = try iface.callValue(allocator, &on_change, &.{ prop_ref, old, value });
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
                const iface = self.hostInterface();
                const r = try iface.callMember(allocator, &rv, "getValue", &.{ Value.Null, prop_ref });
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
        .Lambda, .IrClosure, .Function => true,
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

test "ctor guard and top-level-init flag default empty" {
    try testing.expect(!inTopLevelInit());
    try testing.expect(!ctorGuardContains("Foo"));
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
