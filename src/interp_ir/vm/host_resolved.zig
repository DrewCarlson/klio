//! The `VmHost` side of the instructions lowered from sema: the run state,
//! natives by `NativeId`, recursive runs for init units and constructors,
//! and closures in the shared side table. Free functions over `*VmHost`,
//! aliased as methods by `vmhost.zig`. Nothing here resolves a name.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const vmhost = @import("vmhost.zig");
const host_call_func = @import("host_call_func.zig");

const VmHost = vmhost.VmHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const IrClosureRef = runtime.IrClosureRef;
const Module = ir.Module;
const FuncId = ir.FuncId;
const NativeId = ir.NativeId;
const EvalResult = ir.eval.EvalResult;

fn fail(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalResult {
    return .{ .err = .{ .Unsupported = try std.fmt.allocPrint(allocator, fmt, args) } };
}

pub fn resolvedState(self: *VmHost) ?ir.resolved.StateRef {
    return self.resolved_state;
}

/// Whether `fid`'s body runs wherever it is called: a body the host fronts
/// with a fast path runs only where the call asks the fast path first, which
/// the fused tier does not.
pub fn funcRunsItsBody(self: *VmHost, fid: FuncId) bool {
    const r = self.module.asPtrConst().resolved orelse return true;
    return fid.int() >= r.func_try.len or r.func_try[fid.int()] == .none;
}

/// The module `func`'s body indexes against when that is the program's own.
pub fn ownerModuleForFunc(self: *VmHost, func: *const ir.Func) ?*const Module {
    const m = self.module.asPtrConst();
    return if (m.funcById(func.id) == func) m else null;
}

/// Runs native `id` of the main module's tables over `args`.
pub fn callNative(self: *VmHost, allocator: Allocator, id: NativeId, args: []const Value) Allocator.Error!EvalResult {
    const r = self.module.asPtrConst().resolved orelse return fail(allocator, "CallNative: the module has no resolved tables", .{});
    if (id.int() >= r.natives.len) return fail(allocator, "CallNative: native #{d} is not in the tables", .{id.int()});
    const n = &r.natives[id.int()];
    // A member the VM implements, over a host value as the call passes it.
    if (n.host_fn) |f| if (!n.static_ and n.reified == 0 and n.vararg_back == null and (args.len == 0 or args[0] != .Instance)) {
        return hostResult(self, allocator, try f(self, allocator, args));
    };
    var spread: std.ArrayList(Value) = .empty;
    defer spread.deinit(allocator);
    const own = if (n.static_ and args.len != 0) args[1..] else args;
    var run = if (n.reified != 0 or n.vararg_back != null) try spreadRun(allocator, &spread, n.*, own) else own;
    // An instance extending a class the host constructs is served as the
    // host value it holds.
    var based: std.ArrayList(Value) = .empty;
    defer based.deinit(allocator);
    if (n.receiver and run.len != 0) if (hostBase(r, &run[0])) |hv| {
        try based.appendSlice(allocator, run);
        based.items[0] = hv;
        run = based.items;
    };
    switch (n.op) {
        .none => {},
        .coroutine_context => return coroutineContext(self, allocator),
        .generated_serializer => return generatedSerializer(self, allocator, run),
        .stack_frames => {
            if (run.len == 0) return fail(allocator, "stack frames: no throwable", .{});
            if (try ir.eval.stackTraceArray(allocator, &run[0])) |arr| return .{ .ok = arr };
            return .{ .ok = runtime.ArrayData.fromBoxedList(try runtime.ValueList.initOwned(allocator, .empty)) };
        },
        .print_err => {
            if (run.len != 0 and run[0] == .String) {
                const g = run[0].String.borrow();
                defer g.deinit();
                std.debug.print("{s}\n", .{g.get().bytes});
            }
            return .{ .ok = .Unit };
        },
    }
    if (n.host_fn) |f| return hostResult(self, allocator, try f(self, allocator, run));
    return kotlinThrow(self, allocator, try host_call_func.dispatchIntrinsic(self, allocator, n.name, n.func, run));
}

/// Runs native `id` where a call site bound it statically. A Kotlin
/// instance whose class overrides the member the native implements
/// (`NativeRt.slot`) runs its own implementation instead, as the JVM
/// dispatches a subclass of `ArrayList`; a host value runs the native.
pub fn callNativeSite(self: *VmHost, allocator: Allocator, id: NativeId, args: []const Value) Allocator.Error!EvalResult {
    const module = self.module.asPtrConst();
    if (module.resolved) |r| if (id.int() < r.natives.len and args.len != 0 and args[0] == .Instance) {
        const slot = r.natives[id.int()].slot;
        if (slot != ir.resolved.NONE) if (ir.resolved.classOf(r, &args[0])) |cls| {
            if (ir.resolved.slotTarget(r, cls, ir.MethodSlotId.from(slot))) |impl| {
                const native = if (impl.int() < r.func_native.len) r.func_native[impl.int()] else .none;
                if (native == .none) return runResolved(self, allocator, module, impl, args);
                if (native != id) return callNative(self, allocator, native, args);
            }
        };
    };
    return callNative(self, allocator, id, args);
}

/// The fast path native `id` puts in front of a body: its answer, or null
/// when it declines and the body runs.
pub fn tryNative(self: *VmHost, allocator: Allocator, id: NativeId, args: []const Value) Allocator.Error!?EvalResult {
    const r = self.module.asPtrConst().resolved orelse return null;
    if (id.int() >= r.natives.len) return null;
    const t = r.natives[id.int()].host_try orelse return null;
    const res = (try t(self, allocator, args)) orelse return null;
    return try hostResult(self, allocator, res);
}

/// A host member's result as code lowered from sema reads it: a value
/// needing no conversion as it is, else as `kotlinThrow` makes it.
fn hostResult(self: *VmHost, allocator: Allocator, res: EvalResult) Allocator.Error!EvalResult {
    if (res == .ok and res.ok != .Result and res.ok != .CoroutineSuspended) return res;
    return kotlinThrow(self, allocator, res);
}

/// The host value an instance of a class extending a host-constructed
/// class holds, or null.
fn hostBase(r: *const ir.Resolved, v: *const Value) ?Value {
    const inst = switch (v.*) {
        .Instance => |i| i,
        else => return null,
    };
    const cls = ir.resolved.classOf(r, v) orelse return null;
    if (cls.int() >= r.classes.len) return null;
    const slot = r.classes[cls.int()].host_slot;
    if (slot == ir.resolved.NONE) return null;
    return InstanceData.slotGet(inst, slot);
}

/// `coroutineContext`: the context of the coroutine the pump made active,
/// read as a continuation's `context` or a scope's `coroutineContext`, else
/// `EmptyCoroutineContext` outside any coroutine.
fn coroutineContext(self: *VmHost, allocator: Allocator) Allocator.Error!EvalResult {
    if (vmhost.coroutines.activeCoroScope()) |scope| {
        if (try callWellKnown(self, allocator, &scope, .context, &.{})) |r| return r;
        if (try callWellKnown(self, allocator, &scope, .coroutine_context, &.{})) |r| return r;
    }
    const module = self.module.asPtrConst();
    const r = module.resolved orelse return fail(allocator, "coroutineContext: the module has no resolved tables", .{});
    const cls = r.base.empty_coroutine_context orelse return fail(allocator, "coroutineContext: the base declares no EmptyCoroutineContext", .{});
    return objectValue(self, allocator, module, cls);
}

/// `__klsx_companionSerializer(kClass, args)`: the serializer the
/// serialization pass generated for the class `kClass` names, made by its
/// companion's (or, for an object, its own) `serializer` over the type
/// argument serializers `args`; null for a class without one.
fn generatedSerializer(self: *VmHost, allocator: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const module = self.module.asPtrConst();
    const r = module.resolved orelse return .{ .ok = .Null };
    if (args.len == 0) return .{ .ok = .Null };
    const cls = ir.resolved.classOfKClass(&args[0]) orelse return .{ .ok = .Null };
    if (cls.int() >= r.serializers.len) return .{ .ok = .Null };
    const entry = r.serializers[cls.int()] orelse return .{ .ok = .Null };
    var call: std.ArrayList(Value) = .empty;
    defer call.deinit(allocator);
    const holder = switch (try objectValue(self, allocator, module, entry.holder)) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    try call.append(allocator, holder);
    if (args.len > 1 and args[1] == .List) {
        const g = args[1].List.items.borrow();
        defer g.deinit();
        try call.appendSlice(allocator, g.get().items);
    }
    if (call.items.len != entry.arity + 1) return .{ .ok = .Null };
    return runResolved(self, allocator, module, entry.func, call.items);
}

/// The next identity from the host's instance counter, counting from 1, for
/// an instance a host member makes itself.
pub fn mintInstanceId(self: *VmHost) u64 {
    const g = self.instance_id_counter.borrowMut();
    defer g.deinit();
    return g.get().fetchAdd(1, .monotonic) + 1;
}

fn nextIdentity(st: ir.resolved.StateRef) u64 {
    const g = st.borrowMut();
    defer g.deinit();
    g.get().next_identity += 1;
    return g.get().next_identity;
}

/// Object `class`'s instance, made and constructed on first use, as
/// `LoadObject` makes it.
fn objectValue(self: *VmHost, allocator: Allocator, module: *const Module, class: ir.ClassId) Allocator.Error!EvalResult {
    const r = module.resolved orelse return fail(allocator, "an object outside the resolved tables", .{});
    const st = self.resolved_state orelse return fail(allocator, "an object without a run state", .{});
    return ir.eval.resolved_ops.objectInstance(VmHost, allocator, module, self, r, st, class);
}

/// A new instance of `cc.class` built by its constructor over `arg`.
pub fn construct(self: *VmHost, allocator: Allocator, module: *const Module, cc: ir.resolved.ClassCtor, arg: Value) Allocator.Error!EvalResult {
    return constructWith(self, allocator, module, cc, &.{arg});
}

/// A new instance of `cc.class` built by its constructor over `args`.
pub fn constructWith(self: *VmHost, allocator: Allocator, module: *const Module, cc: ir.resolved.ClassCtor, args: []const Value) Allocator.Error!EvalResult {
    const r = module.resolved.?;
    const st = self.resolved_state orelse return fail(allocator, "a construction without a run state", .{});
    const inst = try ir.resolved.instantiate(allocator, r, cc.class, nextIdentity(st));
    const call = try allocator.alloc(Value, args.len + 1);
    defer allocator.free(call);
    call[0] = inst;
    @memcpy(call[1..], args);
    const built = try runResolved(self, allocator, module, cc.ctor, call);
    switch (built) {
        .ok => |v| v.release(allocator),
        .err => {
            inst.release(allocator);
            return built;
        },
    }
    return .{ .ok = inst };
}

/// The value a parked activation resumes with, as code lowered from sema
/// reads it: a host `Result` becomes the base's. `ir.eval.resumeContinuation`
/// asks once the parked frames are rooted, since the conversion constructs.
pub fn resumeValue(self: *VmHost, allocator: Allocator, v: Value) Allocator.Error!Value {
    if (v != .Result or self.module.asPtrConst().resolved == null) return v;
    const mark = runtime.keepaliveMark();
    runtime.keepalivePush(v);
    defer runtime.keepaliveRestore(mark);
    return switch (try kotlinValue(self, allocator, v)) {
        .ok => |x| x,
        .err => v,
    };
}

/// A host `Result` becomes the base's `Result` over its value, or over a
/// `Result.Failure` holding the exception, as Kotlin code reads it. Any
/// other value is itself.
pub fn kotlinValue(self: *VmHost, allocator: Allocator, v: Value) Allocator.Error!EvalResult {
    if (v != .Result and v != .CoroutineSuspended) return .{ .ok = v };
    const module = self.module.asPtrConst();
    const r = module.resolved orelse return .{ .ok = v };
    // The host's suspension sentinel is `CoroutineSingletons.COROUTINE_SUSPENDED`.
    if (v == .CoroutineSuspended) {
        const st = r.base.coroutine_suspended orelse return .{ .ok = v };
        return ir.eval.resolved_ops.staticValue(VmHost, allocator, module, self, st);
    }
    const rc = r.base.result orelse return .{ .ok = v };
    const payload = v.Result.payload.asPtrConst().*;
    var inner = payload;
    if (!v.Result.ok) {
        const fc = r.base.result_failure orelse return .{ .ok = v };
        const exc = (try kotlinException(self, allocator, payload)) orelse payload;
        inner = switch (try construct(self, allocator, module, fc, exc)) {
            .ok => |x| x,
            .err => |e| return .{ .err = e },
        };
    }
    return construct(self, allocator, module, rc, inner);
}

/// The run a native that takes a vararg's elements in its place, and no
/// type values, is called with.
fn spreadRun(allocator: Allocator, out: *std.ArrayList(Value), n: ir.resolved.NativeRt, args: []const Value) Allocator.Error![]const Value {
    const kept = args[0 .. args.len -| n.reified];
    const back = n.vararg_back orelse return kept;
    if (back >= kept.len) return kept;
    const at = kept.len - 1 - back;
    try out.appendSlice(allocator, kept[0..at]);
    switch (kept[at]) {
        .Array => |arr| {
            var i: usize = 0;
            while (i < arr.len()) : (i += 1) try out.append(allocator, arr.get(i));
        },
        else => try out.append(allocator, kept[at]),
    }
    try out.appendSlice(allocator, kept[at + 1 ..]);
    return out.items;
}

/// A native's result, with a host exception it threw replaced by an
/// instance of the Kotlin class of the same name, built with its message,
/// so code lowered from sema catches and reads it like any other.
fn kotlinThrow(self: *VmHost, allocator: Allocator, res: EvalResult) Allocator.Error!EvalResult {
    const exc = switch (res) {
        .err => |e| switch (e) {
            .Throw => |v| v,
            else => return res,
        },
        .ok => |v| return kotlinValue(self, allocator, v),
    };
    const inst = (try kotlinException(self, allocator, exc)) orelse return res;
    exc.release(allocator);
    return .{ .err = .{ .Throw = inst } };
}

/// The value a catch in code lowered from sema binds: a host exception (a
/// wall-clock cap's, a VM check's) as the instance of the Kotlin class of
/// its name, as a native's throw is; anything else as it is.
pub fn caughtValue(self: *VmHost, allocator: Allocator, exc: Value) Allocator.Error!Value {
    const inst = (try kotlinException(self, allocator, exc)) orelse return exc;
    exc.release(allocator);
    return inst;
}

/// A host exception as an instance of the Kotlin class of the same name,
/// built with its message; null for any other value, or when the base
/// declares no such class.
fn kotlinException(self: *VmHost, allocator: Allocator, exc: Value) Allocator.Error!?Value {
    if (exc != .Exception) return null;
    const module = self.module.asPtrConst();
    const r = module.resolved orelse return null;
    const fqn = exc.exceptionFqn() orelse return null;
    const raised = r.exceptions.by_fqn.get(fqn) orelse return null;
    if (self.resolved_state == null) return null;
    const msg: Value = if (exc.Exception.message.get()) |m| .{ .String = m.clone() } else .Null;
    defer msg.release(allocator);
    return switch (try construct(self, allocator, module, raised, msg)) {
        .ok => |v| v,
        .err => null,
    };
}

/// `member` of a value through its class's slot for the base's
/// declaration: an instance's own implementation answers, as a Kotlin call
/// through that member would, and a host value's the native its class
/// binds or the VM gives its kind. Null for a value the tables do not
/// cover, or a member its class does not implement.
pub fn callWellKnown(self: *VmHost, allocator: Allocator, recv: *const Value, member: runtime.WellKnown, args: []const Value) Allocator.Error!?EvalResult {
    switch (recv.*) {
        .Null, .IrClosure, .PropertyRef, .Cell => return null,
        else => {},
    }
    const module = self.module.asPtrConst();
    const r = module.resolved orelse return null;
    if (member == .invoke) return callInvoke(self, allocator, module, r, recv, args);
    const slot = r.well_known.get(member) orelse return null;
    return callSlot(self, allocator, module, recv, slot, args);
}

/// `invoke` of the function type of `args`' arity that `recv`'s class
/// implements, a plain or a suspend one; null when it implements neither.
fn callInvoke(self: *VmHost, allocator: Allocator, module: *const Module, r: *const ir.Resolved, recv: *const Value, args: []const Value) Allocator.Error!?EvalResult {
    const h = &r.host_class;
    if (args.len < h.invoke_slot.len) if (try callSlot(self, allocator, module, recv, h.invoke_slot[args.len], args)) |res| return res;
    if (args.len < h.suspend_invoke_slot.len) return callSlot(self, allocator, module, recv, h.suspend_invoke_slot[args.len], args);
    return null;
}

/// A new `class` over `args` through its primary constructor; null when
/// the tables do not declare it.
pub fn constructWellKnown(self: *VmHost, allocator: Allocator, class: runtime.WellKnownClass, args: []const Value) Allocator.Error!?EvalResult {
    const module = self.module.asPtrConst();
    const r = module.resolved orelse return null;
    const cc = r.well_known_classes.get(class) orelse return null;
    return try constructWith(self, allocator, module, cc, args);
}

/// `member` of `recv` through its class's slot, as a call in Kotlin
/// dispatches it; an error for a value whose class the tables give no such
/// member.
pub fn wellKnownMember(self: *VmHost, allocator: Allocator, recv: *const Value, member: runtime.WellKnown, args: []const Value) Allocator.Error!EvalResult {
    if (try callWellKnown(self, allocator, recv, member, args)) |r| return r;
    return fail(allocator, "no `{s}` for a {s}", .{ member.memberName(), recv.typeFqn() });
}

/// `object` from the tables, made on first use as `LoadObject` makes it;
/// null when they do not declare it.
pub fn wellKnownObject(self: *VmHost, allocator: Allocator, object: runtime.WellKnownObject) Allocator.Error!?EvalResult {
    const module = self.module.asPtrConst();
    const r = module.resolved orelse return null;
    const cls = r.well_known_objects.get(object) orelse return null;
    return try objectValue(self, allocator, module, cls);
}

/// The value of top-level property `w`, its file initialized first; null
/// when the tables do not declare it.
pub fn wellKnownStatic(self: *VmHost, allocator: Allocator, w: runtime.WellKnownStatic) Allocator.Error!?EvalResult {
    const module = self.module.asPtrConst();
    const r = module.resolved orelse return null;
    const id = r.well_known_statics.get(w) orelse return null;
    return try ir.eval.resolved_ops.staticValue(VmHost, allocator, module, self, id);
}

/// Runs the implementation `recv`'s class has for `slot` over `recv` and
/// `args`; null when the class is not in the tables or has none. A host
/// value runs only what the host implements (a bound native, or the VM's
/// member of the slot's root), never a Kotlin body that reads it as an
/// instance.
fn callSlot(self: *VmHost, allocator: Allocator, module: *const Module, recv: *const Value, slot: ir.MethodSlotId, args: []const Value) Allocator.Error!?EvalResult {
    const r = module.resolved orelse return null;
    const cls = ir.resolved.classOf(r, recv) orelse return null;
    const host_value = recv.* != .Instance;
    const target = ir.resolved.slotTarget(r, cls, slot);
    // A host value whose class declares the member with a Kotlin body
    // (`Pair.toString`) runs the VM's member of the slot's root instead.
    const bound: NativeId = if (target) |f| (if (f.int() < r.func_native.len) r.func_native[f.int()] else .none) else .none;
    const native: NativeId = if (bound != .none)
        bound
    else if (host_value and slot.int() < r.host_slot.len)
        r.host_slot[slot.int()]
    else
        .none;
    if (native == .none and (host_value or target == null)) return null;
    var list: std.ArrayList(Value) = .empty;
    defer list.deinit(allocator);
    try list.append(allocator, recv.*);
    try list.appendSlice(allocator, args);
    if (native != .none) return try callNative(self, allocator, native, list.items);
    return try runResolved(self, allocator, module, target.?, list.items);
}

/// A host entry's `equals` against an instance lowered from sema whose class
/// implements `Map.Entry`: the instance's key and value come from its own
/// getters, as `other.key` and `other.value` read them in Kotlin. Null for
/// any other argument.
pub fn entryEquals(self: *VmHost, allocator: Allocator, key: *const Value, value: *const Value, other: *const Value) Allocator.Error!?EvalResult {
    if (other.* != .Instance) return null;
    const module = self.module.asPtrConst();
    const r = module.resolved orelse return null;
    const h = &r.host_class;
    const entry = h.map_entry orelse return null;
    const cls = ir.resolved.classOf(r, other) orelse return null;
    if (!ir.resolved.isA(module, cls, entry)) return .{ .ok = .{ .Bool = false } };
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    const other_key = switch (try getterValue(self, allocator, module, cls, h.entry_key_slot, other)) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    runtime.keepalivePush(other_key);
    const other_value = switch (try getterValue(self, allocator, module, cls, h.entry_value_slot, other)) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return .{ .ok = .{ .Bool = Value.structuralEqBoxed(key, &other_key) and Value.structuralEqBoxed(value, &other_value) } };
}

/// Runs the implementation `cls` has for the getter at `slot` on `recv`.
fn getterValue(self: *VmHost, allocator: Allocator, module: *const Module, cls: ir.ClassId, slot: ?ir.MethodSlotId, recv: *const Value) Allocator.Error!EvalResult {
    const r = module.resolved.?;
    const target = ir.resolved.slotTarget(r, cls, slot orelse return fail(allocator, "Map.Entry declares no getter slot", .{})) orelse
        return fail(allocator, "class #{d} implements no Map.Entry getter", .{cls.int()});
    const native = if (target.int() < r.func_native.len) r.func_native[target.int()] else .none;
    if (native != .none) return callNative(self, allocator, native, &.{recv.*});
    return runResolved(self, allocator, module, target, &.{recv.*});
}

/// Whether an instance lowered from sema is of a class whose simple name
/// is `head` (`Set` for a class implementing `kotlin.collections.Set`),
/// answered from the resolved tables; null for any other value.
/// Whether `recv` is an instance of a class implementing `iface`, one of
/// the host class table's interfaces; false for any other value.
pub fn instanceImplements(self: *VmHost, recv: *const Value, iface: ?ir.ClassId) bool {
    if (recv.* != .Instance) return false;
    const want = iface orelse return false;
    const module = self.module.asPtrConst();
    const r = module.resolved orelse return false;
    const cls = ir.resolved.classOf(r, recv) orelse return false;
    return ir.resolved.isA(module, cls, want);
}

/// Runs `f` of `module` recursively, for an instruction that needs the
/// result before it continues.
pub fn runResolved(self: *VmHost, allocator: Allocator, module: *const Module, f: FuncId, args: []const Value) Allocator.Error!EvalResult {
    if (module.resolved) |r| if (f.int() < r.func_try.len and r.func_try[f.int()] != .none) {
        if (try tryNative(self, allocator, r.func_try[f.int()], args)) |res| return res;
    };
    const func = module.funcById(f) orelse return fail(allocator, "function #{d} is not in the module", .{f.int()});
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(allocator, args);
    return ir.eval.evalWith(VmHost, allocator, module, func, list, self);
}

/// A closure over `func` of `module` holding `captures`, registered in the
/// side table so a native can invoke it and the collector can find it.
pub fn makeResolvedClosure(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    func: FuncId,
    captures: []const Value,
    kind: ir.resolved.Callable,
) Allocator.Error!EvalResult {
    const f = module.funcById(func) orelse return fail(allocator, "closure: function #{d} is not in the module", .{func.int()});
    // The names are display-only; one per capture keeps a capturing closure
    // from reading as a non-capturing singleton.
    const names = try allocator.alloc([]const u8, captures.len);
    @memset(names, "");
    var store: std.ArrayList(Value) = .empty;
    try store.appendSlice(allocator, captures);
    const body: ir.resolved.ClosureBody = .{ .id = 0, .func = f, .module = module, .kind = kind };
    const id = try self.closures.push(.{
        .body_func = func,
        .is_ref = kind != .lambda,
        .module = if (module == self.module.asPtrConst()) null else module,
        .n_params = body.arity(),
        .receiver_shape_known = true,
        .has_receiver = false,
        .capture_names = names,
        .captures = try ObjRef(std.ArrayList(Value)).init(allocator, store),
        .resolved = kind,
    });
    if (runtime.reclaimEnabled()) for (captures) |c| c.retain();
    const ref = try IrClosureRef.init(allocator, .{ .id = id, .captures = try allocator.dupe(Value, captures) });
    return .{ .ok = .{ .IrClosure = ref } };
}

/// Runs a closure made from sema's code over `args`, with `this_value` as
/// its first argument when given; null for any other callee.
pub fn callResolvedClosure(self: *VmHost, allocator: Allocator, callee: *const Value, this_value: ?*const Value, args: []const Value) Allocator.Error!?EvalResult {
    const body = resolvedClosure(self, callee) orelse return null;
    const given = args.len + @intFromBool(this_value != null);
    if (given != body.arity()) return try fail(allocator, "closure of {s} takes {d} arguments, called with {d}", .{ body.func.fqn, body.arity(), given });
    var params: std.ArrayList(Value) = .empty;
    var caps: std.ArrayList(Value) = .empty;
    {
        const g = callee.IrClosure.borrow();
        defer g.deinit();
        const closure_caps = g.get().captures;
        switch (body.kind) {
            .property_ref => |p| if (p.bound and closure_caps.len != 0) try params.append(allocator, closure_caps[0]),
            else => try caps.appendSlice(allocator, closure_caps),
        }
    }
    if (this_value) |t| try params.append(allocator, t.*);
    try params.appendSlice(allocator, args);
    return try ir.eval.evalClosure(VmHost, allocator, body.module, body.owning, body.func, params, caps, body.id, self);
}

/// The body of a closure lowered from sema, or null for any other value.
/// Kept out of line: inlined into the dispatch loop and the host's call
/// paths, it displaces other inlining in the resolved dispatch helpers, and
/// every lambda call runs about 35 more instructions.
pub noinline fn resolvedClosure(self: *VmHost, v: *const Value) ?ir.resolved.ClosureBody {
    if (v.* != .IrClosure) return null;
    const id = v.IrClosure.asPtrConst().id;
    const info = self.closures.get(@intCast(id)) orelse return null;
    const kind = info.resolved orelse return null;
    const module = info.module orelse self.module.asPtrConst();
    const func = module.funcById(info.body_func) orelse return null;
    return .{ .id = id, .func = func, .module = module, .owning = info.module, .kind = kind };
}
