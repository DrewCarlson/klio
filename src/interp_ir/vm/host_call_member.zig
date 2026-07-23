//! `VmHost` member dispatch — the largest slice of host behaviour:
//! resolving a named member on a receiver (instance / class / builtin),
//! member references, `super.foo(...)` and `this@Outer` resolution, the
//! enclosing-`this` chain, and the member-only probe Kotlin's member-vs-
//! extension precedence rule needs.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked directly by the generic IR evaluator.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const applicability = @import("applicability");

const vmhost = @import("vmhost.zig");
const host_globals = @import("host_globals.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;
const trace = @import("trace.zig");
const overload_match = @import("overload_match.zig");
const host_call_func = @import("host_call_func.zig");
const host_call_value = @import("host_call_value.zig");
const host_fields = @import("host_fields.zig");
const compose = @import("compose.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const StringRef = runtime.StringRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const MapPair = runtime.MapPair;
const RangeKind = runtime.RangeKind;
const DelegateKind = runtime.DelegateKind;
const SeqOp = runtime.SeqOp;
const SequenceData = runtime.SequenceData;
const ComparatorStep = runtime.ComparatorStep;
const RuntimeError = runtime.RuntimeError;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;

const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const MethodSlotId = ir.MethodSlotId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;

// -------------------------------------------------------------------------
// Thread-local resolution state kept here for the member-dispatch
// fallbacks below.
// -------------------------------------------------------------------------

/// Guards `materializeUserMap` re-entry while the Map fallback runs.
threadlocal var map_fallback_active: bool = false;

/// Guards `drainIterableToList` re-entry while the Iterable fallback runs.
threadlocal var iterable_fallback_active: bool = false;

/// Assert (Debug) the member-dispatch re-entrancy flags are clear at a run
/// boundary and reset them so leaked-across-runs state is a loud failure.
pub fn resetReceiverTls() void {
    std.debug.assert(!map_fallback_active);
    std.debug.assert(!iterable_fallback_active);
    map_fallback_active = false;
    iterable_fallback_active = false;
}

fn unsupported(name: []const u8) EvalResult {
    return .{ .err = .{ .Unsupported = name } };
}

fn unimplemented(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalResult {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    return .{ .err = .{ .Unimplemented = msg } };
}

fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalError {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    return .{ .Type = msg };
}

fn throwExc(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!EvalError {
    return .{ .Throw = .{ .Exception = .{
        .fqn = try runtime.strInit(allocator, fqn),
        .message = if (message) |m| try runtime.strInit(allocator, m) else null,
        .cause = null,
    } } };
}

fn strVal(allocator: Allocator, s: []const u8) Allocator.Error!Value {
    return .{ .String = try runtime.strInit(allocator, s) };
}

fn boolVal(b: bool) Value {
    return .{ .Bool = b };
}

/// Whether a value is a primitive number (integer or floating tag).
fn isNumericValue(v: *const Value) bool {
    return switch (v.*) {
        .Int, .Long, .Short, .Byte, .Double, .Float, .UInt, .ULong, .UShort, .UByte => true,
        else => false,
    };
}

/// The binary operator a numeric type's named operator member maps to
/// (`x.rem(y)` → `%`), or null when the name is not such a member.
fn numericOpMethod(name: []const u8) ?ir.BinOp {
    const eql = std.mem.eql;
    if (eql(u8, name, "plus")) return .Add;
    if (eql(u8, name, "minus")) return .Sub;
    if (eql(u8, name, "times")) return .Mul;
    if (eql(u8, name, "div")) return .Div;
    if (eql(u8, name, "rem")) return .Mod;
    // `mod` is NOT mapped to `%`: Kotlin's `mod` differs from `rem` for
    // negative operands (mod matches the divisor's sign), so it must keep the
    // stdlib implementation. Bitwise/shift members (and/or/xor/shl/shr/ushr)
    // likewise fall through — `applyBinop` implements only arithmetic.
    return null;
}

/// Simple-name tail of a possibly-qualified name (`a.b.C` -> `C`).
fn simpleName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// Remove nullability and type arguments from a declared receiver name so it
/// can address the host binding registered for the receiver's class.
fn staticReceiverBindingHead(name: []const u8) []const u8 {
    var head = std.mem.trim(u8, name, " ");
    head = std.mem.trimEnd(u8, head, "?");
    if (std.mem.indexOfScalar(u8, head, '<')) |i| head = head[0..i];
    return std.mem.trim(u8, head, " ");
}

/// The Kotlin simple name shown by `toString`/`KClass.simpleName` for a
/// class whose internal `name` may be a lifted-nested mangle. A nested
/// class lifts to a flat top-level name like `Outer$Data`; Kotlin reports
/// just `Data`. `$` cannot appear in a source class name, so the segment
/// after the last `$` (then the last `.`) is the source simple name.
fn classDisplayName(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.lastIndexOfScalar(u8, n, '$')) |i| n = n[i + 1 ..];
    return simpleName(n);
}

// -------------------------------------------------------------------------
// Dispatch invariants (KLIO_TRACE_INVARIANTS, default OFF). These detect — but
// never repair — structural dispatch hazards at the candidate-selection choke
// point (execution-architecture §5.3). A violation emits one machine-readable
// `[INVARIANT]` line through the tracer; it is not a panic, so the default
// build stays green.
// -------------------------------------------------------------------------

/// Invariant (i): the overload candidate set must select a unique winner.
/// When two distinct candidates tie on the chosen score, declaration order
/// silently breaks the tie — a non-deterministic resolution hazard. Called
/// with the candidates that scored equal to the winner; emits a violation
/// when more than one (distinct) function ties.
fn checkOverloadUnique(name: []const u8, winner: *const Func, tied: []const Func) void {
    if (!trace.invariantsEnabled()) return;
    var distinct: usize = 0;
    for (tied) |f| {
        if (@intFromEnum(f.id) != @intFromEnum(winner.id)) distinct += 1;
    }
    if (distinct == 0) return;
    trace.invariant(
        "kind=overload_tie site=pickMethodOverload name={s} chosen_fid={d} chosen_fqn={s} tied_count={d}",
        .{ name, @intFromEnum(winner.id), winner.fqn, distinct + 1 },
    );
}

/// Invariant (ii): a selected `FuncId` must be in range for the module's func
/// table and its `params` slice must be addressable. Emits a violation and
/// returns when out of range.
fn checkFuncInRange(self: *VmHost, site: []const u8, fid: FuncId) void {
    if (!trace.invariantsEnabled()) return;
    const mg = self.module.borrow();
    defer mg.deinit();
    const n = mg.get().funcCount();
    if (@intFromEnum(fid) >= n) {
        trace.invariant(
            "kind=funcid_oob site={s} fid={d} func_count={d}",
            .{ site, @intFromEnum(fid), n },
        );
    }
}

/// Instance identity (control-block pointer) of a `Value`, or `null` for
/// non-instances.
fn instancePtr(v: *const Value) ?*const anyopaque {
    return switch (v.*) {
        .Instance => |i| @ptrCast(i.cell),
        else => null,
    };
}

/// Invariant (iii): receiver-chain consistency. When both a `"this"` param and
/// a `"this"` capture are present they must refer to the same `Instance`, and
/// the enclosing-`this` chain must have no interior `Null`/`Unit` entries
/// (those indicate a receiver that was lost or never set). Emits one violation
/// line per inconsistency found; never repairs.
fn checkReceiverChain(self: *VmHost, allocator: Allocator, site: []const u8, this_param: ?*const Value, this_capture: ?*const Value) void {
    if (!trace.invariantsEnabled()) return;
    if (this_param != null and this_capture != null) {
        const pp = instancePtr(this_param.?);
        const cp = instancePtr(this_capture.?);
        if (pp != null and cp != null and pp.? != cp.?) {
            trace.invariant(
                "kind=this_mismatch site={s} param_tag={s} capture_tag={s}",
                .{ site, @tagName(this_param.?.*), @tagName(this_capture.?.*) },
            );
        }
    }
    const chain = enclosingThisChain(self, allocator) catch return;
    defer allocator.free(chain);
    if (chain.len < 2) return;
    // Interior entries are everything but the outermost element; a Null/Unit
    // interior receiver is a hole in the enclosing-`this` chain.
    for (chain[0 .. chain.len - 1], 0..) |v, i| {
        switch (v) {
            .Null, .Unit => trace.invariant(
                "kind=chain_hole site={s} index={d} tag={s} depth={d}",
                .{ site, i, @tagName(v), chain.len },
            ),
            else => {},
        }
    }
}

// -------------------------------------------------------------------------
// Recursive dispatch in this file routes back through `VmHost`'s own
// host methods (the same ones the generic IR evaluator invokes).
// -------------------------------------------------------------------------

/// Recursive `callMember` — used for the many self-forwarding branches
/// (`map.containsKey`, delegation, companion forwarding, range
/// materialisation, …).
fn callMemberRec(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!EvalResult {
    return callMember(self, allocator, receiver, name, args);
}

/// Recursive value equality: dispatches a user `equals` override for Instance
/// operands and compares List/Set/Map element/entry-wise (so `setOf(P)==setOf(P)`
/// and nested collections honour element `equals`, which bare structural
/// equality — identity for a non-data Instance — does not). Collections are
/// compared under a live borrow (never a heap snapshot, which the GC would not
/// root across the nested VM dispatch), mirroring `collectionsEqualHostAware`.
pub fn deepValueEquals(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) Allocator.Error!bool {
    // A NATIVE collection on the left compares against a user Instance
    // implementing the matching collection interface by the Kotlin
    // collection contract (same size, equal elements/entries) — that is
    // what the native receiver's own `equals` does. The instance side
    // need not override `equals` for `setOf(x) == wrapper` to hold.
    if (a.* != .Instance and b.* == .Instance) {
        switch (a.*) {
            .Set => if (receiverImplementsHead(self, b, "Set")) {
                const dr = try drainIterableToList(self, allocator, b);
                const drained = switch (dr) {
                    .ok => |v| v,
                    .err => return false,
                };
                defer if (runtime.reclaimEnabled()) drained.release(allocator);
                const ga = a.Set.items.borrow();
                defer ga.deinit();
                const gb = drained.List.items.borrow();
                defer gb.deinit();
                const xa = ga.get().items;
                const xb = gb.get().items;
                if (xa.len != xb.len) return false;
                for (xa) |*ea| {
                    var found = false;
                    for (xb) |*eb| {
                        if (try deepValueEquals(self, allocator, ea, eb)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                }
                return true;
            },
            .List => if (receiverImplementsHead(self, b, "List")) {
                const dr = try drainIterableToList(self, allocator, b);
                const drained = switch (dr) {
                    .ok => |v| v,
                    .err => return false,
                };
                defer if (runtime.reclaimEnabled()) drained.release(allocator);
                a.refreshArrayView();
                a.refreshSublistView();
                const ga = a.List.items.borrow();
                defer ga.deinit();
                const gb = drained.List.items.borrow();
                defer gb.deinit();
                const xa = ga.get().items;
                const xb = gb.get().items;
                if (xa.len != xb.len) return false;
                for (xa, xb) |*ea, *eb| {
                    if (!try deepValueEquals(self, allocator, ea, eb)) return false;
                }
                return true;
            },
            .Map => if (receiverImplementsHead(self, b, "Map")) {
                const er = try self.callMember(allocator, b, "entries", &.{});
                const entries_val = switch (er) {
                    .ok => |v| v,
                    .err => return false,
                };
                defer if (runtime.reclaimEnabled()) entries_val.release(allocator);
                const dr = try drainIterableToList(self, allocator, &entries_val);
                const drained = switch (dr) {
                    .ok => |v| v,
                    .err => return false,
                };
                defer if (runtime.reclaimEnabled()) drained.release(allocator);
                const ga = a.Map.entries.borrow();
                defer ga.deinit();
                const gb = drained.List.items.borrow();
                defer gb.deinit();
                const pa = ga.get().pairs.items;
                const xb = gb.get().items;
                if (pa.len != xb.len) return false;
                for (pa) |*ka| {
                    var found = false;
                    for (xb) |*eb| {
                        const kr = try self.getField(allocator, eb, "key");
                        const key = switch (kr) {
                            .ok => |v| v,
                            .err => continue,
                        };
                        defer if (runtime.reclaimEnabled()) key.release(allocator);
                        if (!try deepValueEquals(self, allocator, &ka.key, &key)) continue;
                        const vr = try self.getField(allocator, eb, "value");
                        const val = switch (vr) {
                            .ok => |v| v,
                            .err => continue,
                        };
                        defer if (runtime.reclaimEnabled()) val.release(allocator);
                        if (try deepValueEquals(self, allocator, &ka.value, &val)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                }
                return true;
            },
            else => {},
        }
    }
    if (a.* == .Instance or b.* == .Instance) {
        if (a.* == .Instance and b.* == .Instance) {
            switch (try callMemberRec(self, allocator, a, "equals", &.{b.*})) {
                .ok => |v| return v == .Bool and v.Bool,
                .err => {},
            }
        }
        return Value.structuralEqBoxed(a, b);
    }
    switch (a.*) {
        .List => {
            if (b.* != .List) return Value.structuralEqBoxed(a, b);
            // Sync array-backed / sublist views to their live backing store
            // before reading (mirrors structuralEqBoxed); otherwise an
            // `IntArray.asList()` view or a `subList` compares stale contents.
            a.refreshArrayView();
            b.refreshArrayView();
            a.refreshSublistView();
            b.refreshSublistView();
            const ga = a.List.items.borrow();
            defer ga.deinit();
            const gb = b.List.items.borrow();
            defer gb.deinit();
            const xa = ga.get().items;
            const xb = gb.get().items;
            if (xa.len != xb.len) return false;
            for (xa, xb) |*ea, *eb| {
                if (!try deepValueEquals(self, allocator, ea, eb)) return false;
            }
            return true;
        },
        .Set => {
            if (b.* != .Set) return Value.structuralEqBoxed(a, b);
            const ga = a.Set.items.borrow();
            defer ga.deinit();
            const gb = b.Set.items.borrow();
            defer gb.deinit();
            const xa = ga.get().items;
            const xb = gb.get().items;
            if (xa.len != xb.len) return false;
            for (xa) |*ea| {
                var found = false;
                for (xb) |*eb| {
                    if (try deepValueEquals(self, allocator, ea, eb)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        },
        .Map => {
            if (b.* != .Map) return Value.structuralEqBoxed(a, b);
            const ga = a.Map.entries.borrow();
            defer ga.deinit();
            const gb = b.Map.entries.borrow();
            defer gb.deinit();
            const pa = ga.get().pairs.items;
            const pb = gb.get().pairs.items;
            if (pa.len != pb.len) return false;
            for (pa) |*ka| {
                var found = false;
                for (pb) |*kb| {
                    if (try deepValueEquals(self, allocator, &ka.key, &kb.key) and
                        try deepValueEquals(self, allocator, &ka.value, &kb.value))
                    {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        },
        // Pair/Triple recurse component-wise so a nested native-vs-instance
        // collection (a `snapshot to setOf(state)` against a
        // `snapshot to ScatterSetWrapper`) compares by the same rules.
        .Pair => |x| {
            if (b.* != .Pair) return Value.structuralEqBoxed(a, b);
            return try deepValueEquals(self, allocator, x.first.asPtr(), b.Pair.first.asPtr()) and
                try deepValueEquals(self, allocator, x.second.asPtr(), b.Pair.second.asPtr());
        },
        .Triple => |x| {
            if (b.* != .Triple) return Value.structuralEqBoxed(a, b);
            return try deepValueEquals(self, allocator, x.first.asPtr(), b.Triple.first.asPtr()) and
                try deepValueEquals(self, allocator, x.second.asPtr(), b.Triple.second.asPtr()) and
                try deepValueEquals(self, allocator, x.third.asPtr(), b.Triple.third.asPtr());
        },
        else => return Value.structuralEqBoxed(a, b),
    }
}

fn callValueRec(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!EvalResult {
    // A receiver-typed callable invoked function-style with the receiver
    // as its first argument (`content.item(itemScope, localIndex)` where
    // `item: LazyItemScope.(Int) -> Unit`): one arg more than the
    // declared params plus a `this` capture slot is that shape — bind
    // args[0] as the receiver, not as the first parameter.
    if (callee.* == .IrClosure and args.len >= 1) {
        if (self.closures.get(@intCast(callee.IrClosure.id))) |info| {
            if (args.len == info.n_params + 1) {
                var has_this = false;
                for (info.capture_names) |n| {
                    if (std.mem.eql(u8, n, "this")) {
                        has_this = true;
                        break;
                    }
                }
                if (has_this) {
                    return self.callValueWithThis(allocator, callee, &args[0], args[1..], &.{});
                }
                // No `this` slot: the lambda never READS its receiver —
                // bind the declared params without it. The receiver still
                // scopes the body's dispatch (a member-extension declared
                // on its class resolves through it), so it rides along as
                // the innermost subject, exactly like the value-call path.
                const pushed = args[0] == .Instance or args[0] == .Null;
                if (pushed) pushAccessEnclosingSubject(self, &args[0]);
                const r = self.callValue(allocator, callee, args[1..]);
                if (pushed) popAccessEnclosing(self);
                return r;
            }
        }
    }
    return self.callValue(allocator, callee, args);
}

fn callValueWithThisRec(self: *VmHost, allocator: Allocator, callee: *const Value, this_value: *const Value, args: []const Value) Allocator.Error!EvalResult {
    return self.callValueWithThis(allocator, callee, this_value, args, &.{});
}

fn newInstanceById(self: *VmHost, allocator: Allocator, class: ir.ClassId, args: []const Value, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    return self.newInstance(allocator, class, args, outer_hint);
}

fn reconstructDataClass(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), args: []const Value) Allocator.Error!EvalResult {
    const class_def = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    var callee: Value = .{ .Class = class_def };
    defer callee.deinit(allocator);
    return host_call_value.callValue(self, allocator, &callee, args);
}

fn getFieldRec(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return self.getField(allocator, receiver, name);
}

fn callFuncRec(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value) Allocator.Error!EvalResult {
    // Forward the member call's trailing-lambda syntax bit to the
    // function binder: every member-dispatch route funnels here, so the
    // under-applied default-fill in `callFunc` binds the lambda to the
    // LAST param exactly when the source used trailing syntax.
    if (trailing_member_call) host_call_func.setTrailingLambdaCall(true);
    const r = self.callFunc(allocator, module, func, args);
    host_call_func.setTrailingLambdaCall(false);
    return r;
}

fn callFuncNamedRec(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, names: []const ?[]const u8) Allocator.Error!EvalResult {
    if (trailing_member_call) host_call_func.setTrailingLambdaCall(true);
    const r = self.callFuncNamed(allocator, module, func, args, names);
    host_call_func.setTrailingLambdaCall(false);
    return r;
}

fn callFuncIndexedRec(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    func: FuncId,
    defaults_from: FuncId,
    receiver: *const Value,
    args: []const Value,
    arg_params: []const u32,
) Allocator.Error!EvalResult {
    if (trailing_member_call) host_call_func.setTrailingLambdaCall(true);
    const r = host_call_func.callFuncIndexed(self, allocator, module, func, defaults_from, receiver, args, arg_params);
    host_call_func.setTrailingLambdaCall(false);
    return r;
}

// -------------------------------------------------------------------------
// Intrinsic resolution / dispatch.
// -------------------------------------------------------------------------

/// Resolve a stdlib intrinsic by FQN: a pack-installed binding shadows the
/// shipped implementation.
fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
    const pg = self.prog.borrow();
    defer pg.deinit();
    const bg = pg.get().installed_bindings.borrow();
    defer bg.deinit();
    if (bg.get().resolve(fqn)) |f| return f;
    return stdlib.implementation(fqn);
}

/// Build a `VmIntrinsicHost` bound to this host's shared handles, run the
/// intrinsic, and map any `RuntimeError` into the IR evaluator's
/// `EvalError`. Mirrors `dispatch_intrinsic`.
fn dispatchIntrinsic(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(allocator, "intrinsic_call_member", fqn, null, null, args);
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePushSlice(args);
    var intrinsic = makeIntrinsicHost(self);
    defer deinitIntrinsicHost(&intrinsic);
    var ihost = intrinsic.intrinsicHost();
    _ = &ihost;
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = intrinsic.intrinsicHost(),
        .allocator = allocator,
    };
    const prev_fqn = runtime.leaktrack.current_fqn;
    runtime.leaktrack.current_fqn = fqn;
    const r = try func(&ctx);
    runtime.leaktrack.current_fqn = prev_fqn;
    return mapRuntimeResult(allocator, r);
}

fn makeIntrinsicHost(self: *VmHost) VmIntrinsicHost {
    return .{
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
}

fn deinitIntrinsicHost(h: *VmIntrinsicHost) void {
    h.object_states.deinit();
    h.module.deinit();
    h.closures.deinit();
    h.globals.deinit();
    h.classes.deinit();
    h.prog.deinit();
    h.anon_methods.deinit();
    h.class_default_outer.deinit();
    h.instance_id_counter.deinit();
    h.out_sink.deinit();
    h.threads.deinit();
}

fn mapRuntimeResult(allocator: Allocator, r: runtime.EvalResult) Allocator.Error!EvalResult {
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = try mapRuntimeError(allocator, e) },
    };
}

fn mapRuntimeError(allocator: Allocator, e: RuntimeError) Allocator.Error!EvalError {
    return switch (e) {
        .Thrown => |v| .{ .Throw = v },
        .Return => |v| .{ .NonLocalReturn = v },
        .Suspend => |wake| blk: {
            const ss = try allocator.create(ir.eval.SuspendState);
            ss.* = .{ .token = 0, .frames = .empty, .wake_in_millis = wake, .pending_resume_reg = null };
            break :blk .{ .Suspended = ss };
        },
        .CalleeFailed => |m| .{ .CalleeFailed = m },
        // Preserve each message-carrying variant's TEXT: collapsing to the
        // tag name (`@tagName`) buries the real failure ("IR eval: Type"
        // instead of the actual diagnostic), which hides the true bug.
        .Type => |s| .{ .Type = s },
        .Unbound => |s| .{ .Unbound = s },
        .Unimplemented => |s| .{ .Unimplemented = s },
        .Arity => |s| .{ .Arity = s },
        else => |other| try typeErr(allocator, "unexpected intrinsic result: {s}", .{@tagName(other)}),
    };
}

// -------------------------------------------------------------------------
// Pure helpers: pure functions over `Value` / `Module` that live here so
// the member-dispatch file is self-contained.
// -------------------------------------------------------------------------

fn isCallable(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure, .Function, .BoundMethod => true,
        else => false,
    };
}

/// A `TypeRef` denoting a Kotlin function type (`FunctionN` or `... -> ...`).
fn isFunctionTypeRef(ty: *const TypeRef) bool {
    return std.mem.startsWith(u8, simpleName(ty.name), "Function") or
        std.mem.indexOf(u8, ty.name, "->") != null;
}

/// `ty`'s name with `typealias` indirection resolved (bounded hops), so a
/// param declared as `handler: CompletionHandler` (an alias for a function
/// type) is recognised as function-typed by applicability checks.
fn resolveAliasName(self: *VmHost, name: []const u8) []const u8 {
    var cur = name;
    var hops: usize = 0;
    while (hops < 4) : (hops += 1) {
        const next = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.type_aliases.get(simpleName(cur));
        } orelse return cur;
        if (std.mem.eql(u8, next, cur)) return cur;
        cur = next;
    }
    return cur;
}

/// `isFunctionTypeRef` with typealias indirection resolved.
fn isFunctionTypeRefResolved(self: *VmHost, ty: *const TypeRef) bool {
    if (isFunctionTypeRef(ty)) return true;
    const resolved = resolveAliasName(self, ty.name);
    return std.mem.startsWith(u8, simpleName(resolved), "Function") or
        std.mem.indexOf(u8, resolved, "->") != null;
}

/// Pack trailing positional args into a single `Value::Array` when the
/// target's last param is `vararg`. `args` is consumed and freed.
fn packVarargArgs(self: *VmHost, allocator: Allocator, func: *const Func, args: []Value) Allocator.Error![]Value {
    _ = self;
    if (func.params.len == 0) return args;
    const last = func.params[func.params.len - 1];
    if (!last.is_vararg) return args;
    const fixed = func.params.len - 1;
    if (args.len == func.params.len and args[args.len - 1] == .Array) return args;
    var out = try allocator.alloc(Value, func.params.len);
    var i: usize = 0;
    while (i < fixed and i < args.len) : (i += 1) out[i] = args[i];
    const rest_len = if (args.len > fixed) args.len - fixed else 0;
    var rest = try allocator.alloc(Value, rest_len);
    var j: usize = 0;
    while (fixed + j < args.len) : (j += 1) rest[j] = args[fixed + j];
    var rest_list: std.ArrayList(Value) = .empty;
    try rest_list.appendSlice(allocator, rest[0..rest_len]);
    allocator.free(rest);
    out[fixed] = runtime.ArrayData.fromBoxedList(try ObjRef(std.ArrayList(Value)).init(allocator, rest_list));
    allocator.free(args);
    return out[0 .. fixed + 1];
}

/// Whether `name` is a property (not a method) reachable from the
/// receiver's class chain. Used by bound property-ref invocation.
fn memberIsProperty(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    var start: ObjRef(ClassDef) = undefined;
    switch (receiver.*) {
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            if (g.get().get(name) != null) return true;
            start = g.get().class.clone();
        },
        .Class => |cls| start = cls.clone(),
        else => return false,
    }
    defer start.deinit();
    const a = self.allocator;
    var stack: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (stack.items) |s| s.deinit();
        stack.deinit(a);
    }
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(a);
    stack.append(a, start.clone()) catch return false;
    while (stack.pop()) |c| {
        defer c.deinit();
        const cg = c.borrow();
        const cd = cg.get();
        var skip = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, cd.name)) skip = true;
        }
        if (skip) {
            cg.deinit();
            continue;
        }
        seen.append(a, cd.name) catch {};
        for (cd.primary_params) |p| {
            if (p.property != null and std.mem.eql(u8, p.name, name)) {
                cg.deinit();
                return true;
            }
        }
        for (cd.body_properties) |p| {
            if (std.mem.eql(u8, p.name, name)) {
                cg.deinit();
                return true;
            }
        }
        if (cd.parent) |p| stack.append(a, p.clone()) catch {};
        const classes_g = self.classes.borrow();
        for (cd.supertype_names) |sn| {
            if (classes_g.get().get(sn)) |sc| stack.append(a, sc.clone()) catch {};
        }
        classes_g.deinit();
        cg.deinit();
    }
    return false;
}

/// Permissive receiver/param-type compatibility used by extension
/// overload pickers.
fn receiverCompatibleWithParam(receiver: *const Value, param_ty: *const TypeRef) bool {
    if (receiver.* == .Instance) return true;
    const pn = simpleName(param_ty.name);
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Any?") or std.mem.eql(u8, pn, "Unit")) return true;
    if (std.mem.startsWith(u8, pn, "Function")) return true;
    if (pn.len <= 2 and pn.len > 0 and allUppercase(pn)) return true;
    return receiver.isRuntimeType(pn);
}

fn allUppercase(s: []const u8) bool {
    for (s) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
    }
    return true;
}

// Coarse builtin value kinds for definite argument-type disproof live in
// overload_match.zig, shared with the declared-type scorer refinement.
const builtinKindMismatch = overload_match.builtinKindMismatch;

/// `kotlinHashCode` with member dispatch for user instances: containers
/// fold their elements' USER hashCode() overrides, exactly as the JVM
/// does. Non-container scalars delegate to the pure hash.
fn hashWithDispatch(self: *VmHost, allocator: Allocator, v: *const Value) Allocator.Error!i32 {
    switch (v.*) {
        .Instance, .Exception => {
            const r = try callMember(self, allocator, v, "hashCode", &.{});
            switch (r) {
                .ok => |hv| {
                    if (hv == .Int) return @truncate(hv.Int);
                    return kotlinHashCode(v);
                },
                .err => return kotlinHashCode(v),
            }
        },
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            var h: i32 = 1;
            for (g.get().items) |*e| h = h *% 31 +% try hashWithDispatch(self, allocator, e);
            return h;
        },
        .Array => |arr| {
            var h: i32 = 1;
            const n = arr.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var e = arr.get(i);
                h = h *% 31 +% try hashWithDispatch(self, allocator, &e);
            }
            return h;
        },
        .Set => |st| {
            const g = st.items.borrow();
            defer g.deinit();
            var h: i32 = 0;
            for (g.get().items) |*e| h = h +% try hashWithDispatch(self, allocator, e);
            return h;
        },
        .Map => |m| {
            const g = m.entries.borrow();
            defer g.deinit();
            var h: i32 = 0;
            for (g.get().pairs.items) |*kv| h = h +% ((try hashWithDispatch(self, allocator, &kv.key)) ^ (try hashWithDispatch(self, allocator, &kv.value)));
            return h;
        },
        .Pair => |pr| return (try hashWithDispatch(self, allocator, pr.first.asPtr())) *% 31 +% try hashWithDispatch(self, allocator, pr.second.asPtr()),
        .Triple => |t| return ((try hashWithDispatch(self, allocator, t.first.asPtr())) *% 31 +% try hashWithDispatch(self, allocator, t.second.asPtr())) *% 31 +% try hashWithDispatch(self, allocator, t.third.asPtr()),
        .MapEntry => |e| return (try hashWithDispatch(self, allocator, e.key.asPtr())) ^ (try hashWithDispatch(self, allocator, e.value.asPtr())),
        else => return kotlinHashCode(v),
    }
}

/// Kotlin-faithful `hashCode()` for builtin value types.
pub fn kotlinHashCode(v: *const Value) i32 {
    return switch (v.*) {
        .Null => 0,
        .Bool => |b| if (b) @as(i32, 1231) else @as(i32, 1237),
        .Char => |c| @as(i32, c),
        .Byte => |x| @as(i32, x),
        .Short => |x| @as(i32, x),
        .Int => |x| x,
        .UByte => |x| @as(i32, x),
        .UShort => |x| @as(i32, x),
        .UInt => |x| @bitCast(x),
        .Long => |l| @truncate(l ^ @as(i64, @bitCast(@as(u64, @bitCast(l)) >> 32))),
        .ULong => |u| @truncate(@as(i64, @bitCast(u ^ (u >> 32)))),
        // Java's to*Bits canonicalizes every NaN payload before hashing.
        .Float => |f| if (std.math.isNan(f)) @as(i32, @bitCast(@as(u32, 0x7fc0_0000))) else @bitCast(f),
        .Double => |d| blk: {
            const b: i64 = if (std.math.isNan(d)) @bitCast(@as(u64, 0x7ff8_0000_0000_0000)) else @bitCast(d);
            break :blk @truncate(b ^ @as(i64, @bitCast(@as(u64, @bitCast(b)) >> 32)));
        },
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            const bytes = g.get().bytes;
            var h: i32 = 0;
            const view = std.unicode.Utf8View.init(bytes) catch {
                for (bytes) |ch| h = h *% 31 +% @as(i32, ch);
                break :blk h;
            };
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp <= 0xFFFF) {
                    h = h *% 31 +% @as(i32, @intCast(cp));
                } else {
                    const v2 = cp - 0x10000;
                    const hi: i32 = @intCast(0xD800 + (v2 >> 10));
                    const lo: i32 = @intCast(0xDC00 + (v2 & 0x3FF));
                    h = h *% 31 +% hi;
                    h = h *% 31 +% lo;
                }
            }
            break :blk h;
        },
        .List => |l| blk: {
            const g = l.items.borrow();
            defer g.deinit();
            var h: i32 = 1;
            for (g.get().items) |e| h = h *% 31 +% kotlinHashCode(&e);
            break :blk h;
        },
        // Kotlin data-class hashCode: first*31 + second (+ *31 + third).
        .Pair => |p| kotlinHashCode(p.first.asPtr()) *% 31 +% kotlinHashCode(p.second.asPtr()),
        .Triple => |t| (kotlinHashCode(t.first.asPtr()) *% 31 +% kotlinHashCode(t.second.asPtr())) *% 31 +% kotlinHashCode(t.third.asPtr()),
        .Set => |s| blk: {
            const g = s.items.borrow();
            defer g.deinit();
            var h: i32 = 0;
            for (g.get().items) |e| h = h +% kotlinHashCode(&e);
            break :blk h;
        },
        .Map => |m| blk: {
            const g = m.entries.borrow();
            defer g.deinit();
            var h: i32 = 0;
            for (g.get().pairs.items) |kv| h = h +% (kotlinHashCode(&kv.key) ^ kotlinHashCode(&kv.value));
            break :blk h;
        },
        .Array => |arr| blk: {
            var h: i32 = 1;
            const n = arr.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var e = arr.get(i);
                h = h *% 31 +% kotlinHashCode(&e);
            }
            break :blk h;
        },
        .Range => |r| blk: {
            // Elements hash with their own Kotlin hashCode first: Long/ULong
            // fold high and low words (`v xor (v ushr 32)`), Int/Char/UInt
            // truncate. `(10L downTo 1L).hashCode()` needs step -1L to hash
            // as 0, not -1.
            const elem = struct {
                fn hash(kind: RangeKind, x: i64) i32 {
                    return switch (kind) {
                        .Long, .ULong => @truncate(x ^ @as(i64, @bitCast(@as(u64, @bitCast(x)) >> 32))),
                        .Int, .Char, .UInt => @truncate(x),
                    };
                }
            };
            const f: i32 = elem.hash(r.kind, r.start);
            const l: i32 = elem.hash(r.kind, r.end);
            const s: i32 = elem.hash(r.kind, r.step);
            const empty = if (r.step > 0) r.start > r.end else r.start < r.end;
            if (empty) break :blk @as(i32, -1);
            if (r.step == 1 and !r.progression) break :blk @as(i32, 31) *% f +% l;
            break :blk (@as(i32, 31) *% (@as(i32, 31) *% f +% l)) +% s;
        },
        // `Map.Entry.hashCode()` is `key.hashCode() xor value.hashCode()`, so a
        // Set-of-entries (a map's `entries`) folds to the map's hashCode.
        .MapEntry => |e| kotlinHashCode(e.key.asPtr()) ^ kotlinHashCode(e.value.asPtr()),
        else => valueStructuralHash(v),
    };
}

/// Structural digest matching `Value.structuralEq`, folded to i32.
fn valueStructuralHash(v: *const Value) i32 {
    var h = std.hash.Wyhash.init(0);
    switch (v.*) {
        .Unit => h.update(std.mem.asBytes(&@as(i32, 0))),
        .Null => h.update(std.mem.asBytes(&@as(i32, 1))),
        .Bool => |b| {
            h.update(std.mem.asBytes(&@as(i32, 2)));
            h.update(std.mem.asBytes(&b));
        },
        .Char => |c| {
            h.update(std.mem.asBytes(&@as(i32, 3)));
            h.update(std.mem.asBytes(&c));
        },
        .Int => |i| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, i)));
        },
        .Long => |l| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&l));
        },
        .Short => |s| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, s)));
        },
        .Byte => |b| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, b)));
        },
        .UInt => |u| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, u)));
        },
        .ULong => |u| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&u));
        },
        .UShort => |u| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, u)));
        },
        .UByte => |u| {
            h.update(std.mem.asBytes(&@as(i32, 4)));
            h.update(std.mem.asBytes(&@as(i64, u)));
        },
        .Float => |f| {
            h.update(std.mem.asBytes(&@as(i32, 5)));
            const bits: u32 = @bitCast(f);
            h.update(std.mem.asBytes(&bits));
        },
        .Double => |d| {
            h.update(std.mem.asBytes(&@as(i32, 5)));
            const bits: u64 = @bitCast(d);
            h.update(std.mem.asBytes(&bits));
        },
        .String => |s| {
            h.update(std.mem.asBytes(&@as(i32, 6)));
            const g = s.borrow();
            defer g.deinit();
            h.update(g.get().bytes);
        },
        else => h.update(std.mem.asBytes(&@as(i32, 7))),
    }
    return @truncate(@as(i64, @bitCast(h.final())));
}

/// Materialise an integer/char progression's elements.
fn materialiseRangeItems(allocator: Allocator, start: i64, end: i64, step: i64, kind: RangeKind) Allocator.Error!std.ArrayList(Value) {
    var out: std.ArrayList(Value) = .empty;
    if (step == 0) return out;
    var cur = start;
    // `inBounds` compares unsigned for ULong (so `MaxUL..MinUL` is empty). `end`
    // is the exact final element (normalized), so stop once it is yielded —
    // advancing past it would overflow/wrap (Long.MAX, or a ULong past MaxUL).
    while (kind.inBounds(cur, end, step)) {
        try out.append(allocator, rangeElem(cur, kind));
        if (cur == end) break;
        const adv = cur +| step;
        if (adv == cur) break;
        cur = adv;
    }
    return out;
}

fn rangeElem(cur: i64, kind: RangeKind) Value {
    return switch (kind) {
        .Int => Value.newInt(cur),
        .Long => .{ .Long = cur },
        .Char => .{ .Char = @truncate(@as(u64, @bitCast(cur))) },
        .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(cur))) },
        .ULong => .{ .ULong = @bitCast(cur) },
    };
}

// -------------------------------------------------------------------------
// Self-contained `VmHost` helpers.
// -------------------------------------------------------------------------

/// Default-arg thunk slots for `method` as declared on a supertype of the
/// receiver, walking the supertype chain via the runtime class table.
pub fn inheritedMemberDefaults(self: *VmHost, allocator: Allocator, supertypes: []const []const u8, method: []const u8) Allocator.Error!?[]const ?FuncId {
    const mg = self.module.borrow();
    defer mg.deinit();
    const amd = &mg.get().registry.abstract_member_defaults;

    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    for (supertypes) |s| try queue.append(allocator, s);

    while (queue.pop()) |cn| {
        if (seen.contains(cn)) continue;
        try seen.put(cn, {});
        const simple = simpleName(cn);
        if (amd.get(.{ .a = cn, .b = method })) |slots| {
            return try allocator.dupe(?FuncId, slots.items);
        }
        if (amd.get(.{ .a = simple, .b = method })) |slots| {
            return try allocator.dupe(?FuncId, slots.items);
        }
        const cg = self.classes.borrow();
        if (cg.get().get(cn)) |def| {
            const dg = def.borrow();
            for (dg.get().supertype_names) |sn| try queue.append(allocator, sn);
            dg.deinit();
        }
        cg.deinit();
    }
    return null;
}

/// `map.containsKey(needle)` honoring a key instance's custom `equals`.
fn mapContainsKeyEq(self: *VmHost, allocator: Allocator, entries: runtime.MapEntries, needle: *const Value) Allocator.Error!union(enum) { ok: bool, err: EvalError } {
    if (needle.* != .Instance) {
        const g = entries.borrow();
        defer g.deinit();
        for (g.get().pairs.items) |kv| {
            if (Value.structuralEqBoxed(&kv.key, needle)) return .{ .ok = true };
        }
        return .{ .ok = false };
    }
    // Snapshot keys so the `equals` call can't conflict with the borrow.
    var keys: std.ArrayList(Value) = .empty;
    defer keys.deinit(allocator);
    {
        const g = entries.borrow();
        defer g.deinit();
        for (g.get().pairs.items) |kv| try keys.append(allocator, kv.key);
    }
    for (keys.items) |k| {
        const r = try callMemberRec(self, allocator, &k, "equals", &.{needle.*});
        switch (r) {
            .ok => |rv| switch (rv) {
                .Bool => |b| if (b) return .{ .ok = true },
                else => if (Value.structuralEqBoxed(&k, needle)) return .{ .ok = true },
            },
            .err => if (Value.structuralEqBoxed(&k, needle)) return .{ .ok = true },
        }
    }
    return .{ .ok = false };
}

/// Build a builtin `Value::Map` from a user `Map` implementation.
fn materializeUserMap(self: *VmHost, allocator: Allocator, recv: *const Value) Allocator.Error!EvalResult {
    // `entries` is a property (custom getter), so read it through the field
    // path; a plain method dispatch would not resolve a property getter.
    const entries_r = try getFieldRec(self, allocator, recv, "entries");
    const entries_val = switch (entries_r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    // `entries_val` is an owned container (host-returns-owned). entry_items only
    // borrows its elements; the pairs loop retains what it keeps, so release it
    // at function exit. No-op under the arena fast path.
    defer if (runtime.reclaimEnabled()) entries_val.release(allocator);
    // The Instance arm drains into an owned list whose elements `entry_items`
    // borrows; keep it alive until after the pairs loop, then release.
    var drained: ?Value = null;
    defer if (runtime.reclaimEnabled()) if (drained) |d| d.release(allocator);
    var entry_items: std.ArrayList(Value) = .empty;
    defer entry_items.deinit(allocator);
    switch (entries_val) {
        .Set => |s| {
            const g = s.items.borrow();
            defer g.deinit();
            try entry_items.appendSlice(allocator, g.get().items);
        },
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            try entry_items.appendSlice(allocator, g.get().items);
        },
        .Instance => {
            const dr = try drainIterableToList(self, allocator, &entries_val);
            switch (dr) {
                .ok => |dv| {
                    drained = dv; // released after the pairs loop (see defer)
                    switch (dv) {
                        .List => |l| {
                            const g = l.items.borrow();
                            defer g.deinit();
                            try entry_items.appendSlice(allocator, g.get().items);
                        },
                        else => {},
                    }
                },
                .err => |e| return .{ .err = e },
            }
        },
        else => {},
    }
    var pairs: std.ArrayList(MapPair) = .empty;
    for (entry_items.items) |e| {
        const kv = try mapEntryKv(self, allocator, &e);
        switch (kv) {
            .ok => |pair| try pairs.append(allocator, pair),
            .err => |err| {
                pairs.deinit(allocator);
                return .{ .err = err };
            },
        }
    }
    return .{ .ok = .{ .Map = .{ .entries = try runtime.MapEntries.init(allocator, .{ .pairs = pairs }), .mutable = false } } };
}

/// Extract `(key, value)` from a map-entry value.
fn mapEntryKv(self: *VmHost, allocator: Allocator, e: *const Value) Allocator.Error!union(enum) { ok: MapPair, err: EvalError } {
    switch (e.*) {
        .MapEntry => |me| {
            const k = me.key.asPtr().*;
            const v = me.value.asPtr().*;
            k.retain();
            v.retain();
            return .{ .ok = .{ .key = k, .value = v } };
        },
        .Pair => |p| {
            const k = p.first.asPtr().*;
            const v = p.second.asPtr().*;
            k.retain();
            v.retain();
            return .{ .ok = .{ .key = k, .value = v } };
        },
        else => {
            const kr = try callMemberRec(self, allocator, e, "key", &.{});
            const k = switch (kr) {
                .ok => |v| v,
                .err => |err| return .{ .err = err },
            };
            const vr = try callMemberRec(self, allocator, e, "value", &.{});
            const v = switch (vr) {
                .ok => |v| v,
                .err => |err| return .{ .err = err },
            };
            return .{ .ok = .{ .key = k, .value = v } };
        },
    }
}

/// Read a boxed component slot and return an owned copy to the interpreter.
/// The boxed `Value` stays in its slot; the caller receives its own ref.
fn extractOwned(box: runtime.ObjRef(Value)) EvalResult {
    const out = box.asPtr().*;
    out.retain();
    return .{ .ok = out };
}

/// Find a function-typed property `name` reachable from the enclosing-this
/// chain or any of those instances' `outer` links.
fn enclosingCallableProperty(self: *VmHost, allocator: Allocator, name: []const u8) Allocator.Error!?Value {
    var work: std.ArrayList(Value) = .empty;
    defer work.deinit(allocator);
    {
        const chain = try enclosingThisChain(self, allocator);
        defer allocator.free(chain);
        try work.appendSlice(allocator, chain);
    }
    var seen: std.AutoHashMap(u64, void) = .init(allocator);
    defer seen.deinit();
    var i: usize = 0;
    while (i < work.items.len) : (i += 1) {
        const v = work.items[i];
        const inst = switch (v) {
            .Instance => |inst| inst,
            else => continue,
        };
        const g = inst.borrow();
        const data = g.get();
        if (seen.contains(data.identity)) {
            g.deinit();
            continue;
        }
        try seen.put(data.identity, {});
        for (data.fields.items) |f| {
            if (std.mem.eql(u8, f.name, name) and isCallable(&f.value)) {
                const found = f.value;
                g.deinit();
                return found;
            }
        }
        const outer = data.outer;
        g.deinit();
        if (outer) |o| try work.append(allocator, o);
    }
    return null;
}

/// Whether `ty_name` denotes a top type or a bare type parameter — a
/// maximally-unspecific receiver/param type that every value satisfies but
/// which loses to any concrete match during most-specific selection.
fn isTopOrGenericType(ty_name: []const u8) bool {
    var pn = simpleName(ty_name);
    pn = std.mem.trimEnd(u8, pn, "?");
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return true;
    if (std.mem.startsWith(u8, pn, "Function")) return true;
    if (pn.len > 0 and pn.len <= 2 and allUppercase(pn)) return true;
    return false;
}

/// Most-specific receiver ranking for overload selection. Returns how
/// specifically the receiver's runtime type satisfies `ty_name`:
///   * a positive rank when the receiver concretely IS-A `ty_name` — larger
///     for a closer (smaller subtype-distance) match;
///   * `0` for a top type or bare type parameter (`Any`, `T`, `FunctionN`):
///     satisfied by everything, so least specific;
///   * `-1` when the receiver definitely does not satisfy a concrete
///     `ty_name`.
/// This is the primary discriminator the most-specific rule ranks on: a
/// `Flow` receiver prefers a `Flow` receiver param over the generic
/// `Iterable`, and an `Iterable`-implementing collection prefers an
/// `Iterable` param over an unrelated `CharSequence`/`Sequence`/`Array`.
fn extReceiverSpecificity(self: *VmHost, receiver: *const Value, ty_name: []const u8) i32 {
    if (isTopOrGenericType(ty_name)) return 0;
    const pn = std.mem.trimEnd(u8, simpleName(ty_name), "?");
    if (receiver.* == .Instance) {
        if (instanceSubtypeDistance(self, receiver, pn)) |dist| {
            const d: i32 = @intCast(@min(dist, @as(usize, 50)));
            return 100 - d;
        }
        // Builtin interface (Iterable/Collection/CharSequence/…) reached
        // through the instance's supertype names but not the user-class graph.
        if (receiverImplementsType(self, receiver, pn)) return 50;
        return -1;
    }
    if (receiver.isRuntimeType(pn)) return 100;
    const v_ty = simpleName(receiver.typeFqn());
    for (applicability.builtinSupersOf(v_ty), 0..) |s, pos| {
        if (std.mem.eql(u8, s, pn)) {
            const d: i32 = @intCast(@min(pos, @as(usize, 50)));
            return 90 - d;
        }
    }
    return -1;
}

/// Strict extension-receiver proof for the bare-name resolver's
/// innermost-first walk: does the candidate's declared receiver type
/// *provably* accept this runtime receiver? Unlike the lenient
/// `receiverImplementsType`, nothing is assumed:
///   * a function-shape receiver (`(() -> R).f()`) proves only against an
///     actual function value (with the arity checked where the value
///     carries one);
///   * a declared type parameter proves unconditionally only when
///     unbounded; a bounded one (`<T : Number>`) requires the receiver to
///     satisfy every declared bound;
///   * a typealias receiver is expanded through the registry before the
///     head check;
///   * generic arguments participate where the runtime value carries
///     element knowledge (`List<String>.f()` on a list of Ints is
///     disproven; on a list of Strings proven). An empty container
///     proves through the declared element head its creation site
///     recorded (`listOf<String>()`); where neither is available
///     (untyped empty literals flowing through erased generics) the
///     candidate is NOT proven and falls to the resolver's ordered
///     lenient pass.
fn strictReceiverProven(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, ty: *const TypeRef) Allocator.Error!bool {
    // A null receiver (a `with(t)` subject whose value is null) is
    // provably accepted only by a nullable receiver type.
    if (receiver.* == .Null) return ty.nullable;
    return strictReceiverProvenName(self, allocator, receiver, fid, ty.name, ty.args, 0);
}

fn strictReceiverProvenName(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, ty_name: []const u8, ty_args: []const TypeRef, fuel: u8) Allocator.Error!bool {
    if (fuel > 8) return false;
    var pn = simpleName(ty_name);
    pn = std.mem.trimEnd(u8, pn, "?");
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return true;
    // Function-shape receivers prove only against function values.
    if (std.mem.startsWith(u8, pn, "Function")) {
        return receiverIsFunctionShaped(self, receiver, pn);
    }
    // Declared type parameter of this candidate: unbounded accepts
    // anything; bounded requires the receiver to satisfy every bound.
    if (typeParamOf(self, fid, pn)) {
        const bounds: []const ir.ModuleRegistry.TypeParamBound = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.func_type_param_bounds.get(fid) orelse &.{};
        };
        for (bounds) |b| {
            if (!std.mem.eql(u8, b.param, pn)) continue;
            if (!try strictReceiverProvenName(self, allocator, receiver, fid, b.bound, &.{}, fuel + 1)) return false;
        }
        return true;
    }
    // A short all-uppercase head that is not a registered type parameter
    // is still a type parameter in shapes the registry does not record
    // (class-level generics, member extensions); no bound is knowable, so
    // it proves like an unbounded one.
    if (pn.len > 0 and pn.len <= 2 and allUppercase(pn)) return true;
    // Typealias expansion (the registry stores the target's simple head
    // name; its generic arguments are not recorded, so the expansion
    // proves on the head alone).
    {
        const target: ?[]const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.type_aliases.get(pn);
        };
        if (target) |t| {
            if (!std.mem.eql(u8, t, pn)) {
                return strictReceiverProvenName(self, allocator, receiver, fid, t, &.{}, fuel + 1);
            }
        }
    }
    if (!receiverImplementsHead(self, receiver, pn)) return false;
    if (ty_args.len == 0) return true;
    // A user `Instance` carries no reified generic arguments, so the head
    // match is the strongest provable check (kotlinc resolves the type
    // arguments statically). Treat it as sufficient: an extension on a
    // generic user class — `CompareContext<Collection<T>>.collectionBehavior`
    // called on a `CompareContext<…>` lambda receiver — then proves strictly
    // on the innermost receiver instead of deferring to the lenient pass,
    // where a same-named member on an OUTER receiver would otherwise preempt
    // it. `elementsProveArgs` only introspects the builtin container shapes.
    if (receiver.* == .Instance) return true;
    return elementsProveArgs(self, allocator, receiver, fid, pn, ty_args, fuel);
}

/// Whether an extension whose declared receiver head is `ty` applies to
/// a receiver whose STATIC (declared) type head is `static_name`. Kotlin
/// resolves extension calls against the static receiver type, so inside
/// `fun I.helper()` a bare extension call binds I's extensions even when
/// the runtime value is a subtype carrying a same-name extension.
/// `null` ⇒ undecidable statically (unresolvable static class); the
/// caller falls back to the runtime-type proof.
/// The lifted key for a dotted nested-class reference (`Modifier.Node` ->
/// its scope-keyed mangled name when the simple name collided at lift), or
/// null when the name is not dotted / carries no mangle entry.
fn mangledNestedKey(mod: *const Module, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '.') == null) return null;
    // Last two segments (`a.b.C.D` -> `C.D`) key the mangle table.
    var last: ?usize = null;
    var prev: ?usize = null;
    for (name, 0..) |ch, i| {
        if (ch == '.') {
            prev = last;
            last = i;
        }
    }
    const start = if (prev) |p| p + 1 else 0;
    return mod.registry.mangled_nested.get(name[start..]);
}

/// Whether two class-name strings name the same type head across the
/// lift's spellings: literal match, mangle-table canonical match, or the
/// bare head (dots and the `Outer$` lift prefix stripped) match. The head
/// fallback carries the same simple-name semantics the rest of the
/// hierarchy walks use — a dotted supertype (`Modifier.Node`) must satisfy
/// a parameter lowered to its bare head (`Node`).
pub fn classHeadsMatch(self: *VmHost, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const ka = mangledClassKeyOf(self, a) orelse a;
    const kb = mangledClassKeyOf(self, b) orelse b;
    if (std.mem.eql(u8, ka, kb)) return true;
    return std.mem.eql(u8, bareHead(a), bareHead(b));
}

fn bareHead(name: []const u8) []const u8 {
    var sn = name;
    if (std.mem.lastIndexOfScalar(u8, sn, '.')) |i| sn = sn[i + 1 ..];
    if (std.mem.indexOfScalar(u8, sn, '<')) |lt| sn = sn[0..lt];
    if (std.mem.lastIndexOfScalar(u8, sn, '$')) |i| {
        if (i + 1 < sn.len) sn = sn[i + 1 ..];
    }
    return std.mem.trimEnd(u8, sn, "?");
}

/// The lifted mangle key for a dotted class-name string via the module's
/// mangle table, or null when none applies. Precise: only a table hit
/// canonicalizes, so two unrelated same-simple-name classes never merge.
pub fn mangledClassKeyOf(self: *VmHost, name: []const u8) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    return mangledNestedKey(mg.get(), name);
}

fn staticReceiverApplicable(self: *VmHost, allocator: Allocator, static_name: []const u8, fid: FuncId, ty: *const TypeRef) ?bool {
    var pn = simpleName(ty.name);
    pn = std.mem.trimEnd(u8, pn, "?");
    // Receivers that accept anything statically, mirroring the runtime
    // prover's universal cases.
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return true;
    if (typeParamOf(self, fid, pn)) return true;
    // A dotted nested receiver whose class lifted under a mangled key
    // (`Modifier.Node` when another `Node` exists) canonicalizes to that
    // key, so it compares equal to a hint that resolved the same class
    // through the lexical rename ladder.
    {
        const mg0 = self.module.borrow();
        defer mg0.deinit();
        if (mangledNestedKey(mg0.get(), std.mem.trimEnd(u8, ty.name, "?"))) |m| pn = m;
    }
    // The short-all-uppercase type-param heuristic only applies to a
    // head that is NOT a registered class (`W5` is a class, `T`/`TT`
    // are type params).
    const head_is_class = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().registry.class_super_names.get(pn) != null or mg.get().classId(pn) != null;
    };
    if (!head_is_class and pn.len > 0 and pn.len <= 2 and allUppercase(pn)) return true;
    {
        const target: ?[]const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.type_aliases.get(pn);
        };
        if (target) |t| {
            if (!std.mem.eql(u8, t, pn)) pn = simpleName(t);
        }
    }
    var sn = simpleName(static_name);
    if (std.mem.indexOfScalar(u8, sn, '<')) |lt| sn = sn[0..lt];
    sn = std.mem.trimEnd(u8, std.mem.trim(u8, sn, " "), "?");
    if (std.mem.eql(u8, sn, pn)) return true;
    _ = allocator;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    // A dotted hint canonicalizes through the same mangle table as `pn`.
    if (mangledNestedKey(mod, std.mem.trimEnd(u8, static_name, "?"))) |m| sn = m;
    if (std.mem.eql(u8, sn, pn)) return true;
    // Resolve `sn` against EVERY class sharing that simple name, not just the
    // one the simple-name-keyed hierarchy map happens to hold. Compose vendors
    // two distinct `Node` types (`Modifier.Node : DelegatableNode` and an
    // unrelated `Node : NodeParent`); the map keeps only the first, so a lookup
    // of the wrong one would claim a spurious mismatch. A definite `false` may
    // be returned only when the name resolves unambiguously and still fails to
    // reach `pn`; an ambiguous or unknown head is undecidable (`null`), which
    // keeps the candidate for the runtime-type check to judge.
    var matches: usize = 0;
    var relates = false;
    for (mod.class_index.items) |entry| {
        // A lift-mangled nested class (`Modifier$Node`) still answers for its
        // source simple name: a bare hint (`Node`) recorded where the rename
        // ladder could not see the mangle is ambiguous across ALL variants,
        // and the mangled entry itself may be the one that relates.
        const ehead = blk: {
            const sn2 = simpleName(entry.name);
            if (std.mem.lastIndexOfScalar(u8, sn2, '$')) |i| {
                if (i + 1 < sn2.len) break :blk sn2[i + 1 ..];
            }
            break :blk sn2;
        };
        if (!(std.mem.eql(u8, simpleName(entry.name), sn) or std.mem.eql(u8, ehead, sn))) continue;
        matches += 1;
        if (std.mem.eql(u8, simpleName(entry.name), pn) or std.mem.eql(u8, entry.name, pn)) {
            relates = true;
            continue;
        }
        if (mod.registry.class_super_names.get(entry.name)) |chain| {
            for (chain) |s| {
                if (std.mem.eql(u8, simpleName(s), pn)) {
                    relates = true;
                    break;
                }
                // A dotted supertype whose class lifted mangled compares by
                // its canonical key (`: Modifier.Node()` vs pn `Modifier$Node`).
                if (mangledNestedKey(mod, s)) |m| {
                    if (std.mem.eql(u8, m, pn)) {
                        relates = true;
                        break;
                    }
                }
            }
        }
    }
    if (relates) return true;
    if (matches != 1) return null;
    return false;
}

/// Whether the DECLARED signature refuses `n_args` user args outright:
/// fewer than the required count (params without defaults), or more
/// than total without a vararg. Conservative — a missing `DeclSig`
/// refuses nothing.
fn declArityRefuses(self: *VmHost, fid: FuncId, n_args: usize) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const sig = mg.get().decl_sigs.get(fid.int()) orelse return false;
    if (n_args < sig.arity.required) return true;
    if (n_args > sig.arity.total and !sig.arity.has_vararg) return true;
    return false;
}

/// Can the candidate take `want` positional args (receiver included)?
/// Exact arity fits; extra declared params must each carry a default or
/// be a vararg; extra args only fit a trailing vararg.
fn extArityApplicable(self: *VmHost, f: *const Func, want: usize) bool {
    if (f.params.len == want) return true;
    if (f.params.len < want) {
        return f.params.len > 0 and f.params[f.params.len - 1].is_vararg;
    }
    const defaults = funcDefaults(self, f);
    var k: usize = want;
    while (k < f.params.len) : (k += 1) {
        if (!(f.params[k].is_vararg or paramHasDefault(defaults, k))) return false;
    }
    return true;
}

/// Is the receiver an actual function value of the declared shape?
/// `pn` is `"Function"` or `"FunctionN"`; the arity is checked where the
/// value carries one (an AST function's params, an IR closure's declared
/// param count) and accepted otherwise (intrinsics, bound methods).
fn receiverIsFunctionShaped(self: *VmHost, receiver: *const Value, pn: []const u8) bool {
    switch (receiver.*) {
        .Function, .IrClosure, .Intrinsic, .BoundMethod, .BoundUserMethod => {},
        else => return false,
    }
    const digits = pn["Function".len..];
    if (digits.len == 0) return true;
    const n = std.fmt.parseInt(usize, digits, 10) catch return true;
    // A parameterless lambda lowers with the synthetic implicit `it`
    // slot, so a stored arity of 1 also proves `Function0`.
    return switch (receiver.*) {
        .Function => |f| f.decl.params.len == n or (n == 0 and f.decl.params.len == 1),
        .IrClosure => |c| blk: {
            const info = self.closures.get(@intCast(c.id)) orelse break :blk true;
            break :blk info.n_params == n or (n == 0 and info.n_params == 1);
        },
        else => true,
    };
}

/// Is `pn` a declared type parameter of `fid`?
/// A type-parameter extension receiver constrains dispatch by its declared
/// bound: when the candidate's receiver head is one of its own type params
/// and the runtime receiver's hierarchy provably excludes the bound head,
/// the candidate is not applicable (kotlinc never considers
/// `fun <P : Pipeline<...>> P.install` on a value that is not a Pipeline).
/// Any positional value argument the candidate's declared parameter type
/// definitely excludes (kotlinc applicability covers arguments, not just
/// the receiver: `install(RoutingRoot, ...)` can never bind the overload
/// whose plugin parameter is the unrelated ContentNegotiation object).
/// Whether the instance's class hierarchy declares a member named `invoke`.
/// klio accepts such an instance where a function-typed parameter is
/// declared (`listOf("a","b").map(tagger)`), so the argument-applicability
/// filter must not disprove it — the pre-existing dispatch arms keep their
/// stricter surface (SAM targets and bound references only).
fn instanceHierarchyHasInvoke(self: *VmHost, v: *const Value) bool {
    if (v.* != .Instance) return false;
    var cls: []const u8 = undefined;
    {
        const g = v.Instance.borrow();
        const cg = g.get().class.borrow();
        cls = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.hierarchy_methods.get(cls)) |hm| {
        return hm.contains("invoke");
    }
    return false;
}

fn candidateArgsDisproven(self: *VmHost, f: *const Func, args: []const Value) bool {
    if (f.params.len <= 1 or args.len == 0) return false;
    // A vararg tail repositions everything after it; decline.
    for (f.params) |*pp| {
        if (pp.is_vararg) return false;
    }
    var n = args.len;
    // Trailing-lambda binding: a callable last argument bound to the LAST
    // function-typed parameter over a defaulted gap (`joinTo(out, "&") {..}`)
    // adjudicates the positional prefix only.
    if (isCallable(&args[args.len - 1]) and
        isFunctionTypeRef(&f.params[f.params.len - 1].ty) and
        args.len < f.params.len - 1)
    {
        n = args.len - 1;
    }
    for (args[0..n], 0..) |*a, i| {
        if (i + 1 >= f.params.len) break;
        const pty = &f.params[i + 1].ty;
        if (std.mem.startsWith(u8, pty.name, "Function") and instanceHierarchyHasInvoke(self, a)) continue;
        if (argDefinitelyNotParamType(self, pty, a)) return true;
    }
    return false;
}

fn receiverViolatesTypeParamBound(self: *VmHost, fid: FuncId, param_ty: *const TypeRef, receiver: *const Value) bool {
    const pn0 = std.mem.trimEnd(u8, simpleName(param_ty.name), "?");
    if (!typeParamOf(self, fid, pn0)) return false;
    const bounds: []const ir.ModuleRegistry.TypeParamBound = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().registry.func_type_param_bounds.get(fid) orelse return false;
    };
    for (bounds) |b| {
        if (!std.mem.eql(u8, b.param, pn0)) continue;
        var bn = simpleName(b.bound);
        if (std.mem.indexOfScalar(u8, bn, '<')) |lt| bn = bn[0..lt];
        bn = std.mem.trimEnd(u8, std.mem.trim(u8, bn, " "), "?");
        if (std.mem.eql(u8, bn, "Any")) continue;
        // Decide the bound for any receiver whose full type is known: an
        // Instance carries its class chain, and a concrete builtin's
        // `isRuntimeType` supertype set is authoritative (a `String` receiver
        // is provably not a `Number`, so `<T : Number> T.f()` does not apply to
        // it and the outer member wins). Only an erased function/lambda value
        // against a functional-interface bound stays undecided — SAM conversion
        // could satisfy it — so the strict prover owns those.
        const decidable = switch (receiver.*) {
            .Null, .Function, .IrClosure, .Intrinsic, .BoundMethod, .BoundUserMethod => false,
            else => true,
        };
        if (decidable and !receiverImplementsHead(self, receiver, bn)) return true;
    }
    return false;
}

fn typeParamOf(self: *VmHost, fid: FuncId, pn: []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const tps = mg.get().registry.func_type_params.get(fid) orelse return false;
    for (tps.items) |tp| {
        if (std.mem.eql(u8, tp, pn)) return true;
    }
    return false;
}

/// Whether a candidate's declared parameter type names a TYPE VARIABLE in
/// scope for it: one of the function's own type parameters, or (for an
/// instance method, receiver in `params[0]`) a type parameter of the owning
/// class. Such a parameter never names a nominal class, so argument
/// adjudication must not read it as one — `ConcurrentMap<Key, Value>.put(
/// key: Key, value: Value)` accepts any key even when an unrelated class
/// named `Key` is registered. Bound enforcement is separate
/// (`classTypeParamRefutes` at the member candidate walk).
fn paramTypeIsTypeVar(self: *VmHost, f: *const Func, pn_raw: []const u8) bool {
    return fidTypeVar(self, f.id, pn_raw);
}

/// `paramTypeIsTypeVar` keyed by `FuncId` (the shared applicability engine's
/// `type_var` callback shape).
fn fidTypeVar(self: *VmHost, fid: FuncId, pn_raw: []const u8) bool {
    const pn = std.mem.trimEnd(u8, simpleName(pn_raw), "?");
    if (typeParamOf(self, fid, pn)) return true;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    // Owning class by method-list scan (the lowered receiver param does not
    // carry the owner's name). Only reached when a nominal adjudication is
    // about to refute the candidate, so the scan is off the hot path.
    for (mod.classes.items) |*c| {
        for (c.methods) |m| {
            if (m != fid) continue;
            const bounds = mod.registry.class_type_param_bounds.get(c.name) orelse return false;
            for (bounds) |b| {
                if (std.mem.eql(u8, b.param, pn)) return true;
            }
            return false;
        }
    }
    return false;
}

/// `ApplicabilityScope.type_var`: wraps `fidTypeVar`.
fn applicTypeVarCbM(ctx: *anyopaque, fid: FuncId, name: []const u8) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    return fidTypeVar(self, fid, name);
}

/// Generic-argument proof over the receiver's actual elements. Only
/// builtin containers carry element knowledge; an empty container proves
/// through the declared element head its creation site recorded (an
/// explicit `listOf<String>()` type argument), and everything else is
/// unprovable and reports false so the candidate falls to the lenient
/// pass.
fn elementsProveArgs(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, pn: []const u8, ty_args: []const TypeRef, fuel: u8) Allocator.Error!bool {
    if (std.mem.eql(u8, pn, "Map") or std.mem.eql(u8, pn, "MutableMap")) {
        if (receiver.* != .Map or ty_args.len < 2) return false;
        const g = receiver.Map.entries.borrow();
        defer g.deinit();
        const entries = g.get().pairs.items;
        if (entries.len == 0) {
            return overload_match.declaredElemProves(self, &ty_args[0], receiver.Map.declared_key) and
                overload_match.declaredElemProves(self, &ty_args[1], receiver.Map.declared_value);
        }
        for (entries) |*e| {
            if (!try elementSatisfies(self, allocator, &e.key, fid, &ty_args[0], fuel)) return false;
            if (!try elementSatisfies(self, allocator, &e.value, fid, &ty_args[1], fuel)) return false;
        }
        return true;
    }
    const items: ?runtime.ValueList = switch (receiver.*) {
        .List => |l| if (isListHead(pn)) l.items else null,
        .Set => |st| if (isSetHead(pn)) st.items else null,
        .Array => |arr| if (std.mem.eql(u8, pn, "Array")) arr.boxedList() else null,
        else => null,
    };
    const list = items orelse return false;
    if (ty_args.len < 1) return false;
    const declared_elem: ?[]const u8 = switch (receiver.*) {
        .List => |l| l.declared_elem,
        .Set => |st| st.declared_elem,
        else => null,
    };
    const g = list.borrow();
    defer g.deinit();
    const elems = g.get().items;
    if (elems.len == 0) return overload_match.declaredElemProves(self, &ty_args[0], declared_elem);
    for (elems) |*e| {
        if (!try elementSatisfies(self, allocator, e, fid, &ty_args[0], fuel)) return false;
    }
    return true;
}

fn isListHead(pn: []const u8) bool {
    return std.mem.eql(u8, pn, "List") or std.mem.eql(u8, pn, "MutableList") or
        std.mem.eql(u8, pn, "Collection") or std.mem.eql(u8, pn, "MutableCollection") or
        std.mem.eql(u8, pn, "Iterable") or std.mem.eql(u8, pn, "MutableIterable");
}

fn isSetHead(pn: []const u8) bool {
    return std.mem.eql(u8, pn, "Set") or std.mem.eql(u8, pn, "MutableSet") or
        std.mem.eql(u8, pn, "Collection") or std.mem.eql(u8, pn, "MutableCollection") or
        std.mem.eql(u8, pn, "Iterable") or std.mem.eql(u8, pn, "MutableIterable");
}

/// One element against one declared generic argument. A star projection
/// or type-parameter argument accepts anything; a nullable argument
/// accepts `null`.
fn elementSatisfies(self: *VmHost, allocator: Allocator, elem: *const Value, fid: FuncId, arg: *const TypeRef, fuel: u8) Allocator.Error!bool {
    if (std.mem.eql(u8, arg.name, "*")) return true;
    var head = arg.name;
    if (std.mem.startsWith(u8, head, "in#")) head = head["in#".len..];
    if (std.mem.startsWith(u8, head, "out#")) head = head["out#".len..];
    if (arg.nullable and elem.* == .Null) return true;
    if (elem.* == .Null) return false;
    return strictReceiverProvenName(self, allocator, elem, fid, head, arg.args, fuel + 1);
}

/// Head-name check against the receiver's actual runtime type: the user
/// class hierarchy for an `Instance`, the runtime type-name sets
/// otherwise. No generosity for generics or function shapes — callers
/// handle those.
pub fn receiverImplementsHead(self: *VmHost, receiver: *const Value, pn: []const u8) bool {
    switch (receiver.*) {
        .Instance => |inst| {
            const a = self.allocator;
            var queue: std.ArrayList([]const u8) = .empty;
            defer queue.deinit(a);
            var seen: std.StringHashMap(void) = .init(a);
            defer seen.deinit();
            {
                const g = inst.borrow();
                const cg = g.get().class.borrow();
                queue.append(a, cg.get().name) catch {};
                cg.deinit();
                g.deinit();
            }
            while (queue.pop()) |c| {
                if (seen.contains(c)) continue;
                seen.put(c, {}) catch {};
                const sn = simpleName(c);
                if (std.mem.eql(u8, sn, pn)) return true;
                // A lifted nested class registers under its mangled name
                // (`Modifier$Node`); a bound written `Modifier.Node` carries
                // the simple head `Node`, so match the `$` tail too.
                if (sn.len > pn.len and sn[sn.len - pn.len - 1] == '$' and
                    std.mem.endsWith(u8, sn, pn)) return true;
                const cg = self.classes.borrow();
                if (cg.get().get(c)) |d| {
                    const dg = d.borrow();
                    for (dg.get().supertype_names) |sup| queue.append(a, sup) catch {};
                    dg.deinit();
                }
                cg.deinit();
            }
            return false;
        },
        else => return receiver.isRuntimeType(pn),
    }
}

/// Does the receiver's actual runtime type satisfy `ty_name`?
fn receiverImplementsType(self: *VmHost, receiver: *const Value, ty_name: []const u8) bool {
    var pn = simpleName(ty_name);
    pn = std.mem.trimEnd(u8, pn, "?");
    // Expand typealiases: a member extension declared on `TestResult`
    // (= Unit) must accept a Unit receiver. The registry stores the
    // target's simple head, so expansion iterates on heads; the bound
    // guards a self-referential entry.
    var alias_fuel: u8 = 4;
    while (alias_fuel > 0) : (alias_fuel -= 1) {
        const target: ?[]const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.type_aliases.get(pn);
        };
        const t = target orelse break;
        if (std.mem.eql(u8, t, pn)) break;
        pn = std.mem.trimEnd(u8, simpleName(t), "?");
    }
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return true;
    if (std.mem.startsWith(u8, pn, "Function")) return true;
    if (pn.len > 0 and pn.len <= 2 and allUppercase(pn)) return true;
    switch (receiver.*) {
        .Instance => |inst| {
            const a = self.allocator;
            var queue: std.ArrayList([]const u8) = .empty;
            defer queue.deinit(a);
            var seen: std.StringHashMap(void) = .init(a);
            defer seen.deinit();
            {
                const g = inst.borrow();
                const cg = g.get().class.borrow();
                queue.append(a, cg.get().name) catch {};
                cg.deinit();
                g.deinit();
            }
            while (queue.pop()) |c| {
                if (seen.contains(c)) continue;
                seen.put(c, {}) catch {};
                const sn = simpleName(c);
                if (std.mem.eql(u8, sn, pn)) return true;
                // A lifted nested class registers under its mangled name
                // (`Modifier$Node`); a bound written `Modifier.Node` carries
                // the simple head `Node`, so match the `$` tail too.
                if (sn.len > pn.len and sn[sn.len - pn.len - 1] == '$' and
                    std.mem.endsWith(u8, sn, pn)) return true;
                const cg = self.classes.borrow();
                if (cg.get().get(c)) |d| {
                    const dg = d.borrow();
                    for (dg.get().supertype_names) |s| queue.append(a, s) catch {};
                    dg.deinit();
                }
                cg.deinit();
            }
            return false;
        },
        else => return receiver.isRuntimeType(pn),
    }
}

// -------------------------------------------------------------------------
// `hostHasMember`.
// -------------------------------------------------------------------------

/// Canonical pointer identity for a dispatch-cache method name. Runtime
/// callable references carry collected String storage, so their raw byte
/// address must never enter a program-lifetime cache key.
fn memberNameIdentity(self: *VmHost, name: []const u8) ?usize {
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    return pg.get().memberNameIdentity(name);
}

pub fn hostHasMember(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    if (receiver.* != .Instance) return false;
    const name_p = memberNameIdentity(self, name) orelse return hostHasMemberUncached(self, receiver, name);
    const key: root_mod.ProgramImage.MemberHasKey = .{
        .class_p = blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            break :blk g.get().class.identity();
        },
        .name_p = name_p,
    };
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (pg.get().host_has_member_cache.get(key)) |v| return v;
    }
    const result = hostHasMemberUncached(self, receiver, name);
    {
        const pg = self.prog.borrowMut();
        defer pg.deinit();
        pg.get().host_has_member_cache.put(key, result) catch {};
    }
    return result;
}

fn cmgGlobalKey(self: *VmHost, receiver: *const Value, func_p: usize, name: []const u8, args: []const Value) ?root_mod.ProgramImage.CmgGlobalKey {
    if (receiver.* != .Instance) return null;
    // The arg-type signature keys the entry: a global miss on `f(String)` must
    // not skip the member dispatch of a sibling `f(Int)`. A non-primitive arg
    // yields no signature, so such a call is never cached.
    const sig = methodArgSig(args) orelse return null;
    const g = receiver.Instance.borrow();
    defer g.deinit();
    const name_p = memberNameIdentity(self, name) orelse return null;
    return .{
        .func_p = func_p,
        .class_p = g.get().class.identity(),
        .name_p = name_p,
        .sig = sig,
    };
}

/// True when this `(enclosing func, receiver class, name, arg-sig)` was recorded
/// as resolving to a global — the member-dispatch passes can be skipped.
pub fn cmgGlobalSkip(self: *VmHost, func_p: usize, receiver: *const Value, name: []const u8, args: []const Value) bool {
    const key = cmgGlobalKey(self, receiver, func_p, name, args) orelse return false;
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().cmg_global_cache.contains(key);
}

/// Record that this call resolved to a global with a single implicit-receiver
/// candidate, so a repeat skips the member passes.
pub fn cmgGlobalRecord(self: *VmHost, func_p: usize, receiver: *const Value, name: []const u8, args: []const Value) void {
    const key = cmgGlobalKey(self, receiver, func_p, name, args) orelse return;
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().cmg_global_cache.put(key, {}) catch {};
}

fn hostHasMemberUncached(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    const inst = switch (receiver.*) {
        .Instance => |inst| inst,
        else => return false,
    };
    const a = self.allocator;
    var cls_name: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        cls_name = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.hierarchy_methods.get(cls_name)) |m| {
            if (m.contains(name)) return true;
        }
    }
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    queue.append(a, cls_name) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch {};
        const cg = self.classes.borrow();
        if (cg.get().get(cur)) |def| {
            const dg = def.borrow();
            const d = dg.get();
            for (d.methods) |m| {
                if (std.mem.eql(u8, m.name, name) or std.mem.eql(u8, simpleName(m.name), name)) {
                    dg.deinit();
                    cg.deinit();
                    return true;
                }
            }
            for (d.primary_params) |p| {
                // Only `val`/`var` ctor params (`property != null`) become
                // accessible members; a plain ctor parameter is local to the
                // initializer and is not a member of instances.
                if (p.property != null and std.mem.eql(u8, p.name, name)) {
                    dg.deinit();
                    cg.deinit();
                    return true;
                }
            }
            for (d.body_properties) |p| {
                if (std.mem.eql(u8, p.name, name)) {
                    dg.deinit();
                    cg.deinit();
                    return true;
                }
            }
            for (d.supertype_names) |sn| queue.append(a, sn) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

/// Does the receiver's class hierarchy declare a *property* (primary-ctor
/// property or body property) named `name`? The bare-name write resolver
/// gates on this rather than `hostHasMember`: a Kotlin assignment LHS can
/// only resolve to a property or variable, never to a function, so a
/// method of this name must not capture the write.
pub fn hostHasProperty(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    const inst = switch (receiver.*) {
        .Instance => |inst| inst,
        else => return false,
    };
    const a = self.allocator;
    var cls_name: []const u8 = undefined;
    {
        const g = inst.borrow();
        // A property already materialized on the instance (default-initialized
        // at construction) counts — covers pack/IR-backed classes whose defs
        // aren't in the tree-walker class registry walked below (e.g. a
        // builder receiver like `HexFormat.Builder`'s `upperCase`).
        if (g.get().get(name) != null) {
            g.deinit();
            return true;
        }
        const cg = g.get().class.borrow();
        cls_name = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    queue.append(a, cls_name) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch {};
        const cg = self.classes.borrow();
        if (cg.get().get(cur)) |def| {
            const dg = def.borrow();
            const d = dg.get();
            for (d.primary_params) |p| {
                // Only `val`/`var` ctor params are properties; a plain ctor
                // parameter (`property == null`) is not.
                if (p.property != null and std.mem.eql(u8, p.name, name)) {
                    dg.deinit();
                    cg.deinit();
                    return true;
                }
            }
            for (d.body_properties) |p| {
                if (std.mem.eql(u8, p.name, name)) {
                    dg.deinit();
                    cg.deinit();
                    return true;
                }
            }
            for (d.supertype_names) |sn| queue.append(a, sn) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

/// The companion-object singleton serving as an implicit receiver at this
/// instance's class depth, when the class (or a supertype) declares a
/// companion that owns a member named `name`. Kotlin puts a class's
/// companion in scope inside the class's own members — below the instance
/// receiver, above the next receiver out — so the bare-name resolver adds
/// it as a candidate right after the dispatch receiver. The singleton is
/// only materialised when its class really owns the member, so candidate
/// enumeration for unrelated names stays side-effect free.
pub fn companionWithMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?Value {
    const inst = switch (receiver.*) {
        .Instance => |inst| inst,
        else => return null,
    };
    var cls_name: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        cls_name = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    if (std.mem.indexOf(u8, cls_name, "$Companion$") != null) return null;
    // Walk the full supertype graph (not just the first supertype): a
    // class may list an interface before its superclass
    // (`HeadersImpl : Headers, StringValuesImpl(...)`), and the companion
    // holding `name` can sit on any ancestor — class or interface.
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);
    try queue.append(allocator, cls_name);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cname = queue.items[head];
        var already = false;
        for (seen.items) |sname| {
            if (std.mem.eql(u8, sname, cname)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        try seen.append(allocator, cname);
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cname);
        };
        if (comp_name) |cn| {
            const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                .ok => |maybe| maybe,
                .err => return null,
            };
            if (singleton) |sv| {
                if (sv == .Instance) return sv;
            }
        }
        {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(cname)) |def| {
                const dg = def.borrow();
                defer dg.deinit();
                for (dg.get().supertype_names) |sn| try queue.append(allocator, sn);
            }
        }
        // An inner class reaches the lexically ENCLOSING class's
        // companion too (AbstractList.ListIteratorImpl's init calls
        // checkPositionIndex on AbstractList's companion).
        if (std.mem.lastIndexOfAny(u8, cname, ".$")) |sep| {
            if (sep > 0) try queue.append(allocator, cname[0..sep]);
        }
    }
    return null;
}

// -------------------------------------------------------------------------
// `drainIterableToList` — used by the Iterable fallback and
// `materializeUserMap`. Drains a user `iterator()` into a builtin List.
// -------------------------------------------------------------------------

fn drainIterableToList(self: *VmHost, allocator: Allocator, receiver: *const Value) Allocator.Error!EvalResult {
    const iter_r = try callMemberRec(self, allocator, receiver, "iterator", &.{});
    const iter = switch (iter_r) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    // `iter` is an owned iterator container (host-returns-owned); release it on
    // every exit path. The per-next() elements are transferred into `items`.
    defer if (runtime.reclaimEnabled()) iter.release(allocator);
    var items: std.ArrayList(Value) = .empty;
    var guard: usize = 0;
    while (guard < 1_000_000) : (guard += 1) {
        const hn_r = try callMemberRec(self, allocator, &iter, "hasNext", &.{});
        const has = switch (hn_r) {
            .ok => |v| switch (v) {
                .Bool => |b| b,
                else => false,
            },
            .err => |e| {
                items.deinit(allocator);
                return .{ .err = e };
            },
        };
        if (!has) break;
        const nx_r = try callMemberRec(self, allocator, &iter, "next", &.{});
        switch (nx_r) {
            .ok => |v| try items.append(allocator, v),
            .err => |e| {
                items.deinit(allocator);
                return .{ .err = e };
            },
        }
    }
    return .{ .ok = .{ .List = .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    } } };
}

// -------------------------------------------------------------------------
// Enclosing-this stack accessors.
// -------------------------------------------------------------------------

// The enclosing-`this` chain is the *current eval frame's* live state
// (`Frame.enclosing_this`), snapshotted into `FrameSnapshot` on suspend and
// restored on resume, so it travels with a parked continuation instead of
// living in process-global state. These thin wrappers delegate to the
// frame-scoped primitives in `ir.eval`; a push made by member dispatch just
// before invoking a callable is inherited by the invoked frame and removed by
// the matching pop once the call returns.

pub fn enclosingThis(self: *VmHost) ?Value {
    _ = self;
    return ir.eval.enclosingThisLast();
}

pub fn enclosingThisChain(self: *VmHost, allocator: Allocator) Allocator.Error![]Value {
    _ = self;
    return ir.eval.enclosingThisChainAlloc(allocator);
}

pub fn pushAccessEnclosing(self: *VmHost, v: *const Value) void {
    _ = self;
    ir.eval.pushEnclosing(v);
}

/// `pushAccessEnclosing` for a receiver-lambda subject; see
/// `pushOuterSubject`.
pub fn pushAccessEnclosingSubject(self: *VmHost, v: *const Value) void {
    _ = self;
    ir.eval.pushEnclosingSubject(v);
}

pub fn popAccessEnclosing(self: *VmHost) void {
    _ = self;
    ir.eval.popEnclosing();
}

/// Push/pop the enclosing-`this` chain without a `VmHost` handle. Used by the
/// intrinsic-host receiver-lambda dispatch, which displaces a lambda's
/// captured `this` with an explicit receiver and must keep the displaced
/// instance reachable as an outer implicit receiver for the lambda body.
pub fn pushOuterThis(allocator: Allocator, v: *const Value) void {
    _ = allocator;
    ir.eval.pushEnclosing(v);
}

/// Push a receiver-lambda subject (`with(x) { … }`'s `x`). Tagged so
/// inner-class outer selection knows the subject's own `outer` links are not
/// receivers in scope inside the lambda body; bare-name resolution treats it
/// like any other enclosing receiver.
pub fn pushOuterSubject(allocator: Allocator, v: *const Value) void {
    _ = allocator;
    ir.eval.pushEnclosingSubject(v);
}

pub fn popOuterThis() void {
    ir.eval.popEnclosing();
}

// -------------------------------------------------------------------------
// Overload scoring + method/extension selection.
// -------------------------------------------------------------------------

/// Score an arg/param compatibility for overload resolution. Higher is
/// better. `null` disqualifies the candidate.
fn overloadScoreArg(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) ?i32 {
    const nm = param_ty.name;
    var v_ty: []const u8 = undefined;
    switch (arg.*) {
        .Instance => |i| {
            const g = i.borrow();
            const cg = g.get().class.borrow();
            v_ty = cg.get().name;
            cg.deinit();
            g.deinit();
        },
        else => v_ty = simpleName(arg.typeFqn()),
    }
    const nm_mangled = mangledClassKeyOf(self, nm);
    if (std.mem.eql(u8, nm, v_ty) or
        (nm_mangled != null and std.mem.eql(u8, nm_mangled.?, v_ty)))
    {
        const d = overload_match.refineByDeclaredArgs(self, param_ty, arg) orelse return null;
        return 100 + d;
    }
    if (std.mem.eql(u8, nm, "Any") or std.mem.eql(u8, nm, "Any?")) return 10;
    if (arg.* == .Null and param_ty.nullable) return 50;
    if (std.mem.eql(u8, nm, "Long") and std.mem.eql(u8, v_ty, "Int")) return 40;
    if ((std.mem.eql(u8, nm, "Double") or std.mem.eql(u8, nm, "Float")) and std.mem.eql(u8, v_ty, "Int")) return 30;
    if (std.mem.eql(u8, nm, "Double") and std.mem.eql(u8, v_ty, "Long")) return 30;
    // Float values are stored Double-tagged (and vice versa after arithmetic):
    // the two float widths are one value domain at runtime, so either width's
    // parameter accepts either tag — `Density(density = 1f)` must bind the
    // `density: Float` factory when the value arrives as a Double.
    if ((std.mem.eql(u8, nm, "Float") and std.mem.eql(u8, v_ty, "Double")) or
        (std.mem.eql(u8, nm, "Double") and std.mem.eql(u8, v_ty, "Float"))) return 60;

    const arg_arity: ?usize = switch (arg.*) {
        .IrClosure => |c| blk: {
            if (self.closures.get(@intCast(c.id))) |info| break :blk info.n_params;
            break :blk null;
        },
        else => null,
    };
    const callable = arg_arity != null or std.mem.startsWith(u8, arg.typeFqn(), "kotlin.Function");
    if (callable) {
        if (std.mem.startsWith(u8, nm, "Function")) {
            const want = std.fmt.parseInt(usize, nm["Function".len..], 10) catch return 20;
            if (arg_arity) |got| {
                if (got == want or got == want + 1) {
                    const d = overload_match.refineByDeclaredArgs(self, param_ty, arg) orelse return null;
                    return 90 + d;
                }
                return 20;
            }
            return 20;
        }
        // A callable can never bind a concrete non-function parameter type
        // (`Iterable`/`Collection`/`Array`/`String`/`Int`…): disqualify the
        // candidate so a sibling function-typed overload wins. Without this a
        // lambda scores a weak-but-positive 8 against `removeAll(Iterable)`,
        // and the receiver-specificity tier (ranked above arg fit) then elects
        // that Iterable form over `removeAll(predicate)` → infinite recursion.
        if (isDefinitelyNonFunctionTypeName(simpleName(nm))) return null;
        return 8;
    }
    // Subtype distance scoring for an instance argument.
    if (arg.* == .Instance) {
        if (instanceSubtypeDistance(self, arg, nm)) |dist| {
            const d: i32 = @intCast(@min(dist, @as(usize, 20)));
            return 75 - d;
        }
    }
    // Builtin runtime types satisfy their nominal supertypes (a `String`
    // arg matches a `CharSequence` param, a `List` matches `Iterable`,
    // etc.). Key the supertype list on the *argument's* value type and
    // check whether the *parameter* name is among them.
    const builtin_supers = applicability.builtinSupersOf(v_ty);
    const nm_simple = simpleName(nm);
    for (builtin_supers, 0..) |s, pos| {
        if (std.mem.eql(u8, s, nm) or std.mem.eql(u8, s, nm_simple)) {
            const dist: i32 = @intCast(@min(pos, @as(usize, 20)));
            const d = overload_match.refineByDeclaredArgs(self, param_ty, arg) orelse return null;
            return 75 - dist + d;
        }
    }
    if (nm.len <= 2 and allUppercase(nm)) return 5;
    if (std.mem.eql(u8, nm, "Unit")) return 1;
    return null;
}

/// Direct dispatch of a lowering-resolved member-EXTENSION target: seed the
/// declaring class's `this` as an enclosing receiver (the owner-find), then run
/// the body. `null` when the owner is not reachable, so the caller falls back to
/// the name walk. A statically-baked member-ext `resolved` target dispatches
/// through here.
fn invokeMemberExtFuncId(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, args: []const Value) Allocator.Error!?EvalResult {
    const all = try prependReceiver(allocator, receiver, args);
    defer if (runtime.freeScratch()) allocator.free(all);
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    if (funcAt(mod, fid) == null) return null;
    var pushed = false;
    if (mod.registry.member_ext_owner_class.get(fid)) |owner| {
        const inst = (try memberExtOwnerInstance(self, allocator, receiver, owner)) orelse return null;
        if (funcAt(mod, fid) != null and !funcAt(mod, fid).?.hasBody()) return null; // SAM: use the walk
        ir.eval.pushEnclosing(&inst);
        pushed = true;
    }
    const r = try callFuncRec(self, allocator, mod, fid, all);
    if (pushed) ir.eval.popEnclosing();
    return r;
}

/// Distance from an instance's runtime class to `target` along the
/// supertype graph, or `null` when unreachable.
fn instanceSubtypeDistance(self: *VmHost, arg: *const Value, target: []const u8) ?usize {
    const inst = switch (arg.*) {
        .Instance => |i| i,
        else => return null,
    };
    const a = self.allocator;
    const Entry = struct { name: []const u8, depth: usize };
    var queue: std.ArrayList(Entry) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        queue.append(a, .{ .name = cg.get().name, .depth = 0 }) catch return null;
        cg.deinit();
        g.deinit();
    }
    var head: usize = 0;
    // Compare SOURCE simple names on both sides. A nested class lifts to a
    // flat `Outer$Name`, which is what a subclass records as its supertype,
    // while a parameter declared `Outer.Name` lowers its head to the bare
    // `Name` — so a raw simple-name compare never matches the two, and every
    // instance of a lifted nested type failed to prove its own supertype
    // (`Modifier.Node` against a `SuspendingPointerInputModifierNodeImpl`).
    const tn = classDisplayName(target);
    while (head < queue.items.len) : (head += 1) {
        const e = queue.items[head];
        if (seen.contains(e.name)) continue;
        seen.put(e.name, {}) catch {};
        if (std.mem.eql(u8, classDisplayName(e.name), tn)) return e.depth;
        const cg = self.classes.borrow();
        const e_key = mangledClassKeyOf(self, e.name) orelse e.name;
        if (cg.get().get(e.name) orelse cg.get().get(e_key)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |sn| queue.append(a, .{ .name = sn, .depth = e.depth + 1 }) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return null;
}

// -------------------------------------------------------------------------
// Shared applicability engine — member / extension adapters.
//
// `pickMethodOverload` and `scoreExtCandidates` select through the shared
// `applicable()` engine. These adapters project a runtime value into an
// `ArgShape`, a `Func` into a `SigView`, and wrap the value-dependent
// refinement / subtype / extension-ranking callbacks the engine invokes.
// -------------------------------------------------------------------------

/// `ArgShape` for one runtime value, in the MEMBER scorer's conventions:
/// `lambda_arity` from an `IrClosure` only (never `Function`/`Class`, mirroring
/// `overloadScoreArg`), and `is_lambda` from `isCallable` (the trailing-lambda
/// gate), not the broader `valueIsCallable`.
fn shapeOfValueMember(self: *VmHost, v: *const Value) applicability.ArgShape {
    var arity_authoritative = false;
    const arity: ?u8 = switch (v.*) {
        .IrClosure => |c| blk: {
            const info = self.closures.get(@intCast(c.id)) orelse break :blk null;
            const up = host_call_func.closureUserParamsChecked(self, info);
            arity_authoritative = up.stripped;
            break :blk std.math.cast(u8, up.n);
        },
        .Instance => blk: {
            const cli = host_call_func.composableLambdaBlockArity(self, v) orelse break :blk null;
            arity_authoritative = cli.authoritative;
            break :blk cli.n;
        },
        else => null,
    };
    return .{
        .runtime_class = overload_match.runtimeHead(v),
        .is_null = v.* == .Null,
        .is_lambda = isCallable(v),
        .lambda_arity = arity,
        .lambda_is_literal = arity_authoritative,
        .func_typed = std.mem.startsWith(u8, v.typeFqn(), "kotlin.Function"),
        .value = @ptrCast(v),
    };
}

/// Per-candidate `SigView` for the shared scorer, read off the `Func`.
fn sigViewOfMember(self: *VmHost, f: *const Func, is_ext: bool) applicability.SigView {
    return .{
        .params = f.params,
        .defaults = funcDefaults(self, f),
        .has_body = f.hasBody(),
        .low_priority = f.low_priority,
        .is_member = !is_ext,
        .is_extension = is_ext,
        .fid = f.id,
        .package = f.package,
    };
}

/// `ApplicabilityScope.refine`: wraps `refineByDeclaredArgs`.
fn applicRefineCbM(ctx: *anyopaque, param_ty: *const TypeRef, value: *const anyopaque) ?i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const v: *const Value = @ptrCast(@alignCast(value));
    return overload_match.refineByDeclaredArgs(self, param_ty, v);
}

/// `ApplicabilityScope.identity_conflict`: cross-package class-identity disproof
/// for member overloads (same shared exact-name tier as the global scorer).
fn applicIdentityConflictCbM(ctx: *anyopaque, param_ty: *const TypeRef, value: *const anyopaque) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const v: *const Value = @ptrCast(@alignCast(value));
    return overload_match.crossPackageIdentityConflict(self, param_ty, v);
}

/// `ApplicabilityScope.subtype`: the member instance-subtype BFS
/// (`instanceSubtypeDistance`, simple-name matched — unlike the global BFS).
fn applicSubtypeCbM(ctx: *anyopaque, value: *const anyopaque, target: []const u8) ?i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const arg: *const Value = @ptrCast(@alignCast(value));
    if (arg.* != .Instance) return null;
    const dist = instanceSubtypeDistance(self, arg, target) orelse return null;
    return @intCast(@min(dist, @as(usize, std.math.maxInt(i32))));
}

/// `ApplicabilityScope.func_type`: `isFunctionTypeRefResolved`.
fn applicFuncTypeCbM(ctx: *anyopaque, ty: *const TypeRef) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    return isFunctionTypeRefResolved(self, ty);
}

/// `ApplicabilityScope.ext_recv_match`: `extReceiverSpecificity`.
fn applicExtRecvMatchCb(ctx: *anyopaque, value: *const anyopaque, ty_name: []const u8) i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const v: *const Value = @ptrCast(@alignCast(value));
    return extReceiverSpecificity(self, v, ty_name);
}

/// `ApplicabilityScope.ext_is_subtype_name`: `isSubtypeName`.
fn applicExtSubtypeNameCb(ctx: *anyopaque, a: []const u8, b: []const u8) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    return isSubtypeName(self, self.allocator, a, b);
}

/// `ApplicabilityScope.ext_owner_rank`: member-extension enclosing-chain rank.
fn applicExtOwnerRankCb(ctx: *anyopaque, fid: FuncId) i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const owner: []const u8 = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (!isMemberExt(mod, fid)) return 0;
        break :blk mod.registry.member_ext_owner_class.get(fid) orelse return 0;
    };
    var chain = enclosingChainClassOrder(self, self.allocator) catch return 0;
    defer chain.deinit(self.allocator);
    for (chain.items, 0..) |co, pos| {
        if (std.mem.eql(u8, co, owner)) {
            return @as(i32, @intCast(chain.items.len)) - @as(i32, @intCast(pos));
        }
    }
    return 0;
}

/// `ApplicabilityScope.ext_known_package`: `stdlib.isKnownPackage`.
fn applicKnownPackageCb(pkg: []const u8) bool {
    return stdlib.isKnownPackage(pkg);
}

fn appliedMemberScore(pts: i32, exact_arity: bool, low_priority: bool) i32 {
    var s = pts;
    if (exact_arity) s += 5;
    if (low_priority) s -= 1000;
    return s;
}

/// Default-arg thunk slots recorded for `f` (indexed by lowered-param
/// position, including the implicit `this` slot), or `null` when none.
fn funcDefaults(self: *VmHost, f: *const Func) ?[]const ?FuncId {
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().func_defaults.get(@intFromEnum(f.id));
}

/// Whether the parameter at lowered position `idx` (with the implicit
/// `this` offset already folded in) is satisfiable by a defaulted slot.
fn paramHasDefault(defaults: ?[]const ?FuncId, idx: usize) bool {
    const d = defaults orelse return false;
    if (idx >= d.len) return false;
    return d[idx] != null;
}

/// Conservative type-incompatibility check for a single instance arg
/// against a user-class parameter. Returns `true` only when we can
/// prove the argument's class is not the parameter type nor any of its
/// supertypes; primitives, builtins, and generics are never adjudicated
/// here (they are scored elsewhere). A function-typed parameter is
/// definite against a plain data value: kotlinc drops such a candidate
/// (String is no Function subtype), so a member `url(block: (T) -> Unit)`
/// can't pre-empt the same-named `url(urlString: String)` extension.
/// Whether an instance can stand in for a function-typed parameter:
/// it carries a SAM-conversion target, or its supertype closure names a
/// `Function*` type (kotlinc: assignability needs the type relation — a
/// class merely declaring an `invoke` member is not a Function subtype).
fn instanceHasInvokeSurface(self: *VmHost, v: *const Value) bool {
    // A class declaring `operator fun invoke` is function-like whatever its
    // nominal supertypes: a memo-wrapped ComposableLambdaImpl (22 invoke
    // overloads, no Function* supertype in common code) satisfies a
    // function-typed parameter exactly like a lambda. This runs under
    // callers holding module borrows (some exclusive), so it may only read
    // the instance's own class chain — ClassDef method tables. Pack-loaded
    // classes keep their methods in the lowered registry and their
    // ClassDef.methods EMPTY: an empty chain means the member surface is
    // UNKNOWN here, and a disproof needs knowledge — report the invoke
    // surface as possible so the candidate survives to real dispatch.
    {
        const g = v.Instance.borrow();
        defer g.deinit();
        var cls: ?ObjRef(runtime.ClassDef) = g.get().class.clone();
        while (cls) |c| {
            const cg = c.borrow();
            for (cg.get().methods) |m| {
                if (std.mem.eql(u8, m.name, "invoke")) {
                    cg.deinit();
                    c.deinit();
                    return true;
                }
            }
            const parent = if (cg.get().parent) |p| p.clone() else null;
            cg.deinit();
            c.deinit();
            cls = parent;
        }
    }
    {
        const g = v.Instance.borrow();
        defer g.deinit();
        if (g.get().get("__sam_target__") != null) return true;
        // A `recv::method` / `::prop` callable reference is a synthetic
        // instance carrying `__bound_name__`; it dispatches through the
        // call_value path, so it satisfies a function-typed parameter.
        if (g.get().get("__bound_name__") != null) return true;
    }
    var start: []const u8 = undefined;
    {
        const g = v.Instance.borrow();
        const cg = g.get().class.borrow();
        start = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    const a = self.allocator;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    queue.append(a, start) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch {};
        if (std.mem.startsWith(u8, simpleName(cur), "Function")) return true;
        const cg = self.classes.borrow();
        if (cg.get().get(cur)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |sn| queue.append(a, sn) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

/// Definite receiver disproof for the lenient extension pass: an
/// instance whose known hierarchy excludes the declared receiver class
/// (`argDefinitelyNotParamType`), or a class value against a concrete
/// receiver class — a `KClass` is never an instance of `Pipeline`, so
/// `Pipeline.execute` is not a candidate at that receiver (kotlinc drops
/// it outright).
fn receiverDefinitelyNotParam(self: *VmHost, param_ty: *const TypeRef, receiver: *const Value) bool {
    if (argDefinitelyNotParamType(self, param_ty, receiver)) return true;
    // A function value implements only the Function* surface (plus
    // Any/type variables): a NOMINAL receiver type it does not satisfy
    // is definite. Without this a sole lenient extension survivor like
    // `Comparable<T>.compareTo` binds a lambda receiver, and its body's
    // member re-dispatch loops back to the same pick forever (two
    // lambdas compared through a pack's same-named member).
    switch (receiver.*) {
        .Function, .IrClosure, .BoundMethod, .BoundUserMethod => {
            const pn = simpleName(param_ty.name);
            if (param_ty.nullable) return false;
            if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return false;
            if (pn.len <= 2 and allUppercase(pn)) return false;
            // Any function-shaped type name stays a candidate for a
            // callable receiver: `Function*`, suspend forms, and the
            // lowered `<function>` marker (`startCoroutineCancellable`
            // on `(suspend () -> Unit)`).
            if (std.mem.indexOf(u8, pn, "Function") != null) return false;
            if (std.mem.indexOf(u8, pn, "->") != null) return false;
            if (std.mem.startsWith(u8, pn, "suspend")) return false;
            if (std.mem.eql(u8, pn, "<function>")) return false;
            if (receiver.isRuntimeType(pn)) return false;
            // A `fun interface` (SAM) receiver type: a lambda serves it
            // (`emitAll` on a FlowCollector-shaped collector lambda), so
            // it is never definite. A plain interface (`Comparable`) or
            // class is: kotlinc converts lambdas only to fun interfaces.
            // An UNKNOWN name (no registered ClassDef) stays a candidate.
            {
                const cg = self.classes.borrow();
                defer cg.deinit();
                if (cg.get().get(pn)) |def| {
                    const dg = def.borrow();
                    defer dg.deinit();
                    if (dg.get().is_fun_interface) return false;
                } else {
                    return false;
                }
            }
            return true;
        },
        else => {},
    }
    if (receiver.* == .Class) {
        const pn = param_ty.name;
        if (param_ty.nullable) return false;
        if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return false;
        if (std.mem.startsWith(u8, pn, "Function")) return true;
        if (pn.len <= 2 and allUppercase(pn)) return false;
        const cg = self.classes.borrow();
        defer cg.deinit();
        return cg.get().get(simpleName(pn)) != null;
    }
    return false;
}

/// Parameter-type names that can never bind a function-typed argument.
/// Conservative: the builtin value types, `String`/`CharSequence`, and the
/// concrete container types — none of which is ever a function type or a
/// typealias to one. This lets a trailing-lambda call drop a same-named
/// collection-typed member (`removeAll(elements: Collection)`) so the
/// predicate extension (`removeAll(predicate: (T) -> Boolean)`) binds.
fn isDefinitelyNonFunctionTypeName(pn: []const u8) bool {
    const names = [_][]const u8{
        "String",          "CharSequence", "Boolean",     "Char",       "Byte",              "Short",
        "Int",             "Long",         "Float",       "Double",     "UByte",             "UShort",
        "UInt",            "ULong",        "Number",      "Collection", "MutableCollection", "Iterable",
        "MutableIterable", "List",         "MutableList", "Set",        "MutableSet",        "Map",
        "MutableMap",      "Array",        "Sequence",
    };
    for (names) |n| {
        if (std.mem.eql(u8, pn, n)) return true;
    }
    return false;
}

/// Nominal interfaces klio models a Kotlin array as satisfying (so the stdlib
/// `Array<T>.first()` / iteration extensions bind). An array vs one of these is
/// NOT a definite type mismatch, unlike an array vs an arbitrary user interface.
fn isArrayRelatedIface(pn: []const u8) bool {
    const set = [_][]const u8{
        "Iterable",  "MutableIterable", "Collection",   "MutableCollection",
        "Sequence",  "Comparable",      "CharSequence", "Serializable",
        "Cloneable",
    };
    for (set) |s| {
        if (std.mem.eql(u8, pn, s)) return true;
    }
    return false;
}

/// The Kotlin type name of a scalar runtime value's kind, or null for
/// non-scalars. Used to compare a scalar argument against a value class's
/// underlying representation.
fn scalarKindName(arg: *const Value) ?[]const u8 {
    return switch (arg.*) {
        .Bool => "Boolean",
        .Char => "Char",
        .Byte => "Byte",
        .Short => "Short",
        .Int => "Int",
        .Long => "Long",
        .Float => "Float",
        .Double => "Double",
        .UByte => "UByte",
        .UShort => "UShort",
        .UInt => "UInt",
        .ULong => "ULong",
        .String => "String",
        else => null,
    };
}

fn isScalarKindName(n: []const u8) bool {
    const set = [_][]const u8{
        "Boolean", "Char",  "Byte",   "Short", "Int",   "Long",   "Float",
        "Double",  "UByte", "UShort", "UInt",  "ULong", "String",
    };
    for (set) |s| {
        if (std.mem.eql(u8, n, s)) return true;
    }
    return false;
}

pub fn argDefinitelyNotParamType(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) bool {
    var pn = param_ty.name;
    // A qualified reference (`Owner.Pocket`) names a lifted nested/inner
    // class whose registered name the supertype walk cannot relate;
    // decline to adjudicate.
    if (std.mem.indexOfScalar(u8, pn, '.') != null) return false;
    // A typealiased param type also adjudicates under its expansion. But the
    // alias table is keyed by SIMPLE NAME globally, so a file-private
    // `typealias` in one module shadows an unrelated real class of the same
    // name in another (compose foundation's `internal typealias NodeList =
    // MutableIntList` vs kotlinx.coroutines' real `class NodeList`). Adjudicate
    // the arg against BOTH the original name and the expansion — a match on
    // either is not a definite mismatch, so an ambiguous name never refutes a
    // value that satisfies one of its readings.
    const orig = pn;
    pn = resolveAliasName(self, pn);
    if (std.mem.indexOfScalar(u8, pn, '.') != null) return false;

    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return false;
    // A nullable parameter (`TypeInfo?`) accepts `null` — that is never a
    // definite mismatch — but a non-null argument must still match the
    // underlying type, so a `User` does not satisfy `typeInfo: TypeInfo?`
    // (which would otherwise let the engine's `respond(message, typeInfo)`
    // shadow the reified `respond(status, message)` for `respond(Created,
    // user)`). Adjudicate the non-null case against the underlying type below.
    if (param_ty.nullable and arg.* == .Null) return false;
    if (pn.len <= 2 and allUppercase(pn)) return false;
    // A callable argument definitely does not satisfy a primitive/String
    // parameter: `logger.trace { … }` must drop the member `trace(String)`
    // so the inline `Logger.trace(message: () -> String)` extension binds
    // (kotlinc resolves the extension; the member is inapplicable).
    if (isCallable(arg) and isDefinitelyNonFunctionTypeName(pn)) return true;
    if (std.mem.startsWith(u8, pn, "Function")) {
        // Callables and Null stay non-definite; a plain data value is
        // definite, and so is an instance with no `invoke` surface (a
        // `JobNode` is not a `CompletionHandler` — kotlinc drops the
        // member and binds the JobNode-typed extension).
        return switch (arg.*) {
            .String, .Bool, .Char, .Byte, .Short, .Int, .Long, .Float, .Double, .UByte, .UShort, .UInt, .ULong => true,
            .Instance => !instanceHasInvokeSurface(self, arg),
            else => false,
        };
    }
    // Builtin value-kind disproof: a String argument can never bind an
    // Int parameter (kotlinc does not consider the candidate at all, so
    // the receiver walk must fall through to an outer receiver instead
    // of executing it). Same-kind pairs stay non-definite — a lowered
    // literal may carry a narrower tag than the declared type (`f(5)`
    // binding `f(n: Long)`).
    if (builtinKindMismatch(pn, arg)) return true;
    // A range/progression argument (`0..3`) is definitely not a scalar or array
    // builtin parameter (Int/Long/String/Array/…). Without this, a class that
    // overrides one overload — `get(Int, Int)` — of a method whose other
    // overloads are inherited interface defaults — `get(IntRange, IntRange)` —
    // captures a range-indexed call: the lone own candidate matches on arity, so
    // the hierarchy walk never reaches the inherited range overload. Refuting the
    // scalar param lets the walk fall through to it.
    if (arg.* == .Range and overload_match.builtinParamKind(pn) != null) return true;
    // Builtin container/range-family parameter heads: a scalar/String/
    // Bool/Char argument definitely does not satisfy them (a String is
    // never a `List<IntRange>`), and a container argument whose element
    // knowledge provably contradicts the declared generic arguments is
    // definite too (`List<LongRange>` offered to `List<IntRange>`). A
    // packed `Array` stays non-definite through `valueDefinitelyNot`
    // (pre-packed varargs), as does a wrong-kind range (already decided
    // above for scalar heads, and by the element walk here).
    const container_or_range_head = overload_match.isContainerOrRangeHead(pn);
    if (container_or_range_head) {
        switch (arg.*) {
            .String, .Bool, .Char, .Byte, .Short, .Int, .Long, .Float, .Double, .UByte, .UShort, .UInt, .ULong => return true,
            .List, .Set, .Map, .Range => return overload_match.valueDefinitelyNot(self, param_ty, arg),
            // An Instance falls through to the hierarchy walk below: a
            // user class that never reaches the container head in its
            // supertype closure is definite (a `RangesSpecifier` is not a
            // `List<IntRange>`), while an implementing class stays a
            // candidate.
            .Instance => {},
            else => return false,
        }
    }
    // Only adjudicate when the parameter names a known user class, or a
    // builtin container/range head an Instance was offered to (above).
    if (!container_or_range_head) {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(pn) == null and cg.get().get(orig) == null) return false;
    }
    const inst = switch (arg.*) {
        .Instance => |i| i,
        // A Kotlin array satisfies no NOMINAL user/pack interface, so an
        // `Array`/`XxxArray` argument offered such a parameter is a definite
        // mismatch — decline the lone member `Buffer.readTo(RawSink, Long)` so
        // the extension `Source.readTo(ByteArray, startIndex, endIndex)` binds.
        // EXCEPT the collection interfaces klio DOES model arrays against
        // (`Iterable`/`Collection`/`Sequence`, which back `Array.first()` and
        // friends) and any array-named param — those stay non-definite.
        .Array => return std.mem.indexOf(u8, pn, "Array") == null and !isArrayRelatedIface(pn),
        // A SCALAR against a known user class: definite — except a VALUE
        // class whose underlying representation has the SAME kind, since
        // value-class instances circulate unboxed (a Long could be an `Sz`
        // over Long, but an Int could not). Without the definite arm, a
        // private `Sz.compareTo` member-extension shadows the Int
        // intrinsic inside its OWN body and the dispatch loops.
        .Bool, .Char, .Byte, .Short, .Int, .Long, .Float, .Double, .UByte, .UShort, .UInt, .ULong, .String => {
            // The scalar may satisfy the param NOMINALLY (a String is a
            // CharSequence/Comparable, an Int is a Number): non-definite.
            if (arg.isRuntimeType(pn)) return false;
            // A param naming a DIFFERENT scalar kind stays non-definite
            // too: kotlinc widens integer literals at the call site
            // (`fromEpochMilliseconds(0)` binds the Long param), which
            // the runtime tag cannot see.
            if (isScalarKindName(pn)) return false;
            const cg = self.classes.borrow();
            defer cg.deinit();
            const def = cg.get().get(pn) orelse cg.get().get(orig) orelse return false;
            var dg = def.borrow();
            if (!dg.get().is_value) {
                dg.deinit();
                return true;
            }
            // Chase the value class's underlying declared type (through
            // nested value classes) to a scalar kind name; an unknown or
            // generic underlying stays a candidate.
            var hops: u8 = 0;
            while (hops < 4) : (hops += 1) {
                const params = dg.get().primary_params;
                if (params.len == 0) {
                    dg.deinit();
                    return false;
                }
                const dt_raw = params[0].declared_type orelse {
                    dg.deinit();
                    return false;
                };
                const dt = std.mem.trimEnd(u8, simpleName(dt_raw), "?");
                dg.deinit();
                if (scalarKindName(arg)) |kn| {
                    if (isScalarKindName(dt)) return !std.mem.eql(u8, dt, kn);
                }
                const inner = cg.get().get(dt) orelse return false;
                dg = inner.borrow();
                if (!dg.get().is_value) {
                    dg.deinit();
                    return false;
                }
            }
            dg.deinit();
            return false;
        },
        else => return false,
    };
    var start: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        start = cg.get().name;
        // The arg's own class must be known so its supertype closure is
        // complete; otherwise we cannot be definite.
        const known = blk: {
            const ccg = self.classes.borrow();
            defer ccg.deinit();
            break :blk ccg.get().get(start) != null;
        };
        cg.deinit();
        g.deinit();
        if (!known) return false;
    }
    // The lowering-recorded transitive chain includes interface links the
    // runtime classes map never registers (interfaces are not instantiated),
    // so it decides cases the BFS below would silently truncate: a companion
    // implementing Plugin through the BaseApplicationPlugin interface IS-A
    // Plugin.
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.class_super_names.get(start)) |chain| {
            const tailMatch = struct {
                fn m(cur: []const u8, want: []const u8) bool {
                    if (std.mem.eql(u8, cur, want)) return true;
                    return cur.len > want.len and cur[cur.len - want.len - 1] == '$' and
                        std.mem.endsWith(u8, cur, want);
                }
            }.m;
            // Positive proof only: a chain may itself truncate at a pack
            // boundary, so its silence never upgrades to definite mismatch.
            if (tailMatch(start, pn) or tailMatch(start, orig)) return false;
            for (chain) |sup| {
                if (tailMatch(sup, pn) or tailMatch(sup, orig)) return false;
            }
        }
    }
    const a = self.allocator;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    queue.append(a, start) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        // arg IS-A param type (under either reading of an aliased name).
        if (std.mem.eql(u8, cur, pn) or std.mem.eql(u8, cur, orig)) return false;
        // A lifted nested/inner class is registered under `Outer$Name`;
        // a type reference written `Outer.Name` collapses to `Name`, so
        // match the mangled tail too.
        if ((cur.len > pn.len and cur[cur.len - pn.len - 1] == '$' and
            std.mem.endsWith(u8, cur, pn)) or
            (cur.len > orig.len and cur[cur.len - orig.len - 1] == '$' and
                std.mem.endsWith(u8, cur, orig))) return false;
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch {};
        const cg = self.classes.borrow();
        if (cg.get().get(cur)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |sn| queue.append(a, sn) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return true;
}

/// Pick the best-scoring method overload from `candidates` for `args`.
/// Each candidate's slot 0 is the implicit `this` receiver, so value
/// arguments score against params 1..n.
/// Whether the runtime class chain of an Instance value declares an
/// `invoke` member, answered from an ALREADY-BORROWED module's registry
/// (pack classes keep their methods there; their ClassDef tables stay
/// empty). Callers without a live borrow pass null and keep the
/// conservative disproof.
fn classChainHasInvokeIn(mod: *const Module, v: *const Value) bool {
    if (v.* != .Instance) return false;
    const cls_name: []const u8 = blk: {
        const g = v.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    const reg = &mod.registry;
    var cur: ?[]const u8 = cls_name;
    var hops: usize = 0;
    while (cur) |cn| : (hops += 1) {
        if (hops > 32) break;
        if (reg.hierarchy_methods.get(cn)) |methods| {
            if (methods.contains("invoke")) return true;
        }
        const chain = reg.class_super_names.get(cn) orelse break;
        if (chain.len == 0) break;
        var sn = chain[0];
        if (std.mem.lastIndexOfScalar(u8, sn, '.')) |i| sn = sn[i + 1 ..];
        cur = sn;
    }
    return false;
}

fn pickMethodOverload(self: *VmHost, mod_opt: ?*const Module, candidates: []const Func, args: []const Value) ?Func {
    if (candidates.len == 0) return null;
    if (candidates.len == 1) {
        // Even a lone same-named member must be *applicable*. By arity:
        // when fewer args are supplied than it declares and an unsupplied
        // parameter is neither defaulted nor a vararg, it can't bind
        // (dispatch would pad the slot with Unit). Decline so an
        // applicable extension overload wins — e.g. `buffer.readTo(bytes)`
        // falls through the member `Buffer.readTo(RawSink, byteCount: Long)`
        // to the extension `Source.readTo(ByteArray, startIndex = 0,
        // endIndex = size)`.
        const f = candidates[0];
        const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const effective = f.params[skip..];
        // Non-final vararg (a vararg before trailing defaulted / named-only
        // params): the prefix binds positionally, the vararg consumes the
        // remaining positional args, and the post-vararg params take their
        // defaults. The naive args[i]-vs-effective[i] pairing below would
        // wrongly type-check a vararg-bound arg against a post-vararg param
        // (e.g. `report("A", 1, 2)` checking `2` against `footer: String`).
        var nf_vararg: ?usize = null;
        for (effective, 0..) |*p, k| {
            if (p.is_vararg) {
                if (k + 1 < effective.len) nf_vararg = k;
                break;
            }
        }
        if (nf_vararg) |vp| {
            const defaults = funcDefaults(self, &f);
            // Prefix params not supplied positionally must be defaulted.
            if (args.len < vp) {
                var k: usize = args.len;
                while (k < vp) : (k += 1) {
                    if (!paramHasDefault(defaults, skip + k)) return null;
                }
            }
            // Post-vararg params can't be reached positionally → must default.
            var k: usize = vp + 1;
            while (k < effective.len) : (k += 1) {
                if (!paramHasDefault(defaults, skip + k)) return null;
            }
            // Prefix args against prefix params; the rest against the vararg
            // element type. A param typed as an in-scope type variable is
            // never adjudicated nominally.
            var i: usize = 0;
            while (i < args.len and i < vp) : (i += 1) {
                if (argDefinitelyNotParamType(self, &effective[i].ty, &args[i]) and
                    !paramTypeIsTypeVar(self, &f, effective[i].ty.name)) return null;
            }
            var j: usize = vp;
            while (j < args.len) : (j += 1) {
                if (argDefinitelyNotParamType(self, &effective[vp].ty, &args[j]) and
                    !paramTypeIsTypeVar(self, &f, effective[vp].ty.name)) return null;
            }
            return f;
        }
        // Over-supply with no vararg tail can't bind: decline so an
        // applicable top-level/extension overload wins — e.g. the stdlib
        // `buildString { … }` inside an extension on a class that declares
        // its own zero-arg `buildString()` member (`URLBuilder.authority`).
        if (args.len > effective.len and
            (effective.len == 0 or !effective[effective.len - 1].is_vararg))
        {
            if (missTraceWant(f.name)) std.debug.print("[pmo] `{s}` decline=oversupply args={d} params={d}\n", .{ f.name, args.len, effective.len });
            return null;
        }
        if (args.len < effective.len) {
            const defaults = funcDefaults(self, &f);
            // Trailing-lambda rule: a final callable arg binds the LAST
            // parameter when that parameter is function-typed; only the GAP
            // parameters between it and the lead positional args need
            // defaults. `observe(readObserver) { block }` on
            // `(readObserver = null, writeObserver = null, block)` is
            // applicable -- block is filled by the lambda, writeObserver by
            // its default.
            const trailing_bind = args.len > 0 and
                isFunctionTypeRef(&effective[effective.len - 1].ty) and
                isCallable(&args[args.len - 1]);
            const first_unfilled = if (trailing_bind) args.len - 1 else args.len;
            const last_checked = if (trailing_bind) effective.len - 1 else effective.len;
            var k: usize = first_unfilled;
            while (k < last_checked) : (k += 1) {
                if (!(effective[k].is_vararg or paramHasDefault(defaults, skip + k))) {
                    if (missTraceWant(f.name)) std.debug.print("[pmo] `{s}` decline=undersupply param#{d}\n", .{ f.name, k });
                    return null;
                }
            }
        }
        // By type: a definite argument-type mismatch must fall through so
        // the hierarchy walk continues to the real target. A param typed as
        // an in-scope type variable (the function's own, or the owning
        // class's) is never adjudicated nominally.
        var i: usize = 0;
        while (i < args.len and i < effective.len) : (i += 1) {
            // A LONE member whose function-typed parameter meets an Instance
            // argument whose class chain declares `invoke` stays applicable:
            // a memo-wrapped ComposableLambdaImpl keeps its invoke overloads
            // in the pack registry, which the borrow-free disproof cannot
            // see, so `setContent(content)` was dropped on its only
            // candidate. Answered from the caller's live module borrow; an
            // invoke-less instance (a JobNode against a CompletionHandler
            // parameter) still declines so the extension wins.
            if (args[i] == .Instance and std.mem.startsWith(u8, effective[i].ty.name, "Function")) {
                if (mod_opt) |m| {
                    if (classChainHasInvokeIn(m, &args[i])) continue;
                }
            }
            if (argDefinitelyNotParamType(self, &effective[i].ty, &args[i]) and
                !paramTypeIsTypeVar(self, &f, effective[i].ty.name))
            {
                if (missTraceWant(f.name)) std.debug.print("[pmo] `{s}` decline=arg-type param#{d} ty={s} arg={s}\n", .{ f.name, i, effective[i].ty.name, @tagName(std.meta.activeTag(args[i])) });
                return null;
            }
        }
        return f;
    }
    var shapes_buf: [24]applicability.ArgShape = undefined;
    var shapes_heap: ?[]applicability.ArgShape = null;
    defer if (shapes_heap) |h| self.allocator.free(h);
    const shapes: []applicability.ArgShape = if (args.len <= shapes_buf.len)
        shapes_buf[0..args.len]
    else blk: {
        const h = self.allocator.alloc(applicability.ArgShape, args.len) catch return null;
        shapes_heap = h;
        break :blk h;
    };
    for (args, 0..) |*a, i| shapes[i] = shapeOfValueMember(self, a);
    const scope = applicability.ApplicabilityScope{
        .member = true,
        .ctx = @ptrCast(self),
        .refine = applicRefineCbM,
        .subtype = applicSubtypeCbM,
        .func_type = applicFuncTypeCbM,
        .identity_conflict = applicIdentityConflictCbM,
        .type_var = applicTypeVarCbM,
    };

    var best: ?Func = null;
    var best_score: i32 = std.math.minInt(i32);
    // Track candidates that scored equal to the current best, for the
    // overload-uniqueness invariant (KLIO_TRACE_INVARIANTS). Only populated
    // when the gate is on; otherwise stays empty and costs nothing.
    const check_inv = trace.invariantsEnabled();
    var tied: std.ArrayList(Func) = .empty;
    defer tied.deinit(self.allocator);
    for (candidates) |f| {
        var sig = sigViewOfMember(self, &f, false);
        const applic = applicability.applicable(&sig, shapes, scope) orelse continue;
        // The `+5` exact-arity bonus and `-1000` low-priority penalty are the
        // member caller's tiebreaks, applied from the returned `Score`.
        const score = appliedMemberScore(applic.points, applic.exact_arity, applic.low_priority);
        if (check_inv and score == best_score) tied.append(self.allocator, f) catch {};
        if (score > best_score) {
            best_score = score;
            best = f;
            if (check_inv) {
                tied.clearRetainingCapacity();
                tied.append(self.allocator, f) catch {};
            }
        }
    }
    if (check_inv) {
        if (best) |w| {
            const name: []const u8 = if (candidates.len > 0) candidates[0].name else "";
            checkOverloadUnique(name, &w, tied.items);
            checkFuncInRange(self, "pickMethodOverload", w.id);
        }
    }
    return best;
}

/// Materialise a lazy sequence pipeline into a list. Delegates to the
/// stdlib sequence materialiser through a `VmIntrinsicHost`.
fn materialiseSequence(self: *VmHost, allocator: Allocator, seq_val: *const Value) Allocator.Error!union(enum) { ok: std.ArrayList(Value), err: EvalError } {
    var sink = self.out_sink;
    var intrinsic = makeIntrinsicHost(self);
    defer deinitIntrinsicHost(&intrinsic);
    const ihost = intrinsic.intrinsicHost();
    const outcome = try stdlib.materialise_sequence(allocator, ihost, sink.output(), seq_val.*);
    switch (outcome) {
        .items => |items| {
            var list: std.ArrayList(Value) = .empty;
            try list.appendSlice(allocator, items);
            return .{ .ok = list };
        },
        .err => |e| return .{ .err = try mapRuntimeError(allocator, e) },
    }
}

// -------------------------------------------------------------------------
// Small construction helpers.
// -------------------------------------------------------------------------

fn listOf(allocator: Allocator, items: std.ArrayList(Value), mutable: bool) Allocator.Error!Value {
    return .{ .List = .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
    } };
}

fn cloneItemsList(allocator: Allocator, src: runtime.ValueList) Allocator.Error!std.ArrayList(Value) {
    const g = src.borrow();
    defer g.deinit();
    var out: std.ArrayList(Value) = .empty;
    try out.appendSlice(allocator, g.get().items);
    // An owned copy: every wrapper built from this list (a new List/Array/Set/
    // Iterator, or a `sorted` list that escapes) takes one reference per element,
    // so retain each. The source still owns its own refs. No-op under the arena.
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return out;
}

/// `cloneItemsList` for an `Array` receiver (boxed or packed): an owned,
/// element-retained `ArrayList` copy for a new wrapper (iterator, list, …).
fn cloneArrayItems(allocator: Allocator, arr: runtime.ArrayData) Allocator.Error!std.ArrayList(Value) {
    const snap = try arr.snapshot(allocator);
    defer if (runtime.freeScratch()) allocator.free(snap);
    var out: std.ArrayList(Value) = .empty;
    try out.appendSlice(allocator, snap);
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return out;
}

/// Prepend `receiver` to `args`, returning a freshly-allocated slice.
fn isArrayContentFn(name: []const u8) bool {
    const fns = [_][]const u8{ "contentToString", "contentHashCode", "contentDeepToString", "contentDeepHashCode", "contentEquals", "contentDeepEquals" };
    for (fns) |f| if (std.mem.eql(u8, name, f)) return true;
    return false;
}

fn prependReceiver(allocator: Allocator, receiver: *const Value, args: []const Value) Allocator.Error![]Value {
    var all = try allocator.alloc(Value, args.len + 1);
    all[0] = receiver.*;
    @memcpy(all[1..], args);
    return all;
}

fn callCallableIndexed(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    root: FuncId,
    receiver: *const Value,
    callable: *const Value,
    args: []const Value,
    arg_params: []const u32,
) Allocator.Error!EvalResult {
    const bound = try host_call_func.bindFuncIndexedArgs(self, allocator, module, root, root, receiver, args, arg_params);
    switch (bound) {
        .ok => |ordered| {
            defer allocator.free(ordered);
            if (ordered.len == 0) return .{ .err = .{ .Type = "virtual callable slot has no receiver" } };
            return host_call_value.callValue(self, allocator, callable, ordered[1..]);
        },
        .err => |err| return .{ .err = err },
    }
}

/// Dispatch an intrinsic with the receiver prepended to `args`, using a stack
/// buffer for the common small-arity case so a member call needs no heap
/// allocation for its argument vector. The prepended slice never outlives the
/// call (`dispatchIntrinsic` is synchronous and intrinsics read their args
/// during the call — the heap path here freed it immediately too), so the stack
/// buffer is exactly as safe. Falls back to the heap for large arities.
fn dispatchWithReceiver(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, receiver: *const Value, args: []const Value) Allocator.Error!EvalResult {
    var stackbuf: [16]Value = undefined;
    if (args.len + 1 <= stackbuf.len) {
        stackbuf[0] = receiver.*;
        @memcpy(stackbuf[1 .. 1 + args.len], args);
        return dispatchIntrinsic(self, allocator, fqn, func, stackbuf[0 .. 1 + args.len]);
    }
    const all_args = try prependReceiver(allocator, receiver, args);
    defer if (runtime.freeScratch()) allocator.free(all_args);
    return dispatchIntrinsic(self, allocator, fqn, func, all_args);
}

// -------------------------------------------------------------------------
// `callMember` — the central dispatch.
// -------------------------------------------------------------------------

pub fn callMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!EvalResult {
    const r = try callMemberInner(self, allocator, receiver, name, args, false);
    // A raw callable value asked for a member nothing serves: the value
    // stands in for a SAM instance (a lambda flowing where a fun interface
    // is expected — `FlowCollector`'s `emit` on a collector that arrived as
    // a plain function), so the single-abstract-method call IS an
    // invocation of the callable. Direct-dispatch only: the bare-name
    // resolver's candidate walks must keep their misses so outer receivers
    // and extensions still get their turn.
    if (r == .err and r.err == .Unimplemented and
        (receiver.* == .Function or receiver.* == .IrClosure))
    {
        // Interface-method reading is only plausible when the callable's
        // declared parameter count matches the call (except `invoke`,
        // which is every callable's own surface). Without the gate, an
        // unresolved helper name dispatched with the block as `this`
        // (`probeCoroutineResumed(completion)` inside
        // `startCoroutineUndispatched`) invoked the coroutine block —
        // every UNDISPATCHED launch body ran twice.
        if (!std.mem.eql(u8, name, "invoke")) {
            const n = callableFieldArity(self, receiver) orelse return r;
            if (n != args.len) return r;
        }
        freeDispatchMiss(allocator, r);
        if (runtime.getenvSlice("KLIO_SAM_TRACE") != null) std.debug.print("[sam-direct] name={s} nargs={d}\n", .{ name, args.len });
        // The interface method may declare an extension receiver
        // (`PointerInputEventHandler`'s `PointerInputScope.invoke()`):
        // Kotlin resolves it from the call site's enclosing implicit
        // receivers, and the lambda body's bare-member calls
        // (`awaitPointerEventScope { … }`) resolve against it. Hand the
        // innermost enclosing instance as `this`; a body that never
        // reads a receiver is unaffected.
        const encl = ir.eval.enclosingEntriesAlloc(allocator) catch &.{};
        defer allocator.free(@constCast(encl));
        for (encl) |e| {
            if (e.v != .Instance) continue;
            return host_call_value.callValueWithThis(self, allocator, receiver, &e.v, args, &.{});
        }
        return host_call_value.callValue(self, allocator, receiver, args);
    }
    return r;
}

/// `strict_ext` restricts the extension fallback to candidates whose
/// declared receiver type provably accepts this receiver. The bare-name
/// resolver's innermost-first candidate walk uses it so an extension that
/// is not applicable to an inner receiver cannot pre-empt a real member
/// of an outer one (kotlinc: a receiver-incompatible extension is not a
/// candidate at that receiver at all); the unproven-compatibility pick
/// stays available as the resolver's later lenient pass and as the
/// explicit-dispatch default.
fn callMemberInner(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool) Allocator.Error!EvalResult {
    return callMemberInnerStatic(self, allocator, receiver, name, args, strict_ext, null, false, null);
}

/// An `IrClosure`/`Function` field's declared parameter count, or null when
/// the value is not a closure-style callable.
pub fn callableFieldArity(self: *VmHost, v: *const Value) ?usize {
    switch (v.*) {
        .IrClosure => |c| {
            const info = self.closures.get(@intCast(c.id)) orelse return null;
            const mr = self.module.clone();
            defer mr.deinit();
            const module = info.module orelse mr.asPtr();
            const func = module.funcById(info.body_func) orelse return null;
            return func.params.len;
        },
        .Function => |f| return f.decl.params.len,
        else => return null,
    }
}

/// Whether instance `v` could serve bare `name` as a receiver: a member
/// somewhere in its class hierarchy (the lowered `hierarchy_methods`
/// name set, which covers abstract members and overrides alike), a
/// method/body property on its `ClassDef` chain, or an extension whose
/// declared receiver the class chain reaches. The SAM-callable walk arm
/// consults DEEPER candidates through this before invoking an in-scope
/// callable as a fun-interface method — kotlinc binds an outer implicit
/// receiver's member or extension (`collect(this)` inside an
/// `unsafeFlow` block binds the outer Flow's `collect`) over the
/// interface-method reading of a captured lambda.
pub fn debugClassNameOf(self: *VmHost, v: *const Value) []const u8 {
    _ = self;
    if (v.* != .Instance) return "-";
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return cg.get().name;
}

pub fn valueCouldServeName(self: *VmHost, allocator: Allocator, v: *const Value, name: []const u8) bool {
    if (v.* != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    const cls_name = cg.get().name;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (m.registry.hierarchy_methods.get(cls_name)) |methods| {
            if (methods.contains(name)) return true;
        }
        // extCouldApply rebuilds its lazy index when the func table has
        // grown; VM execution is single-threaded, so the cast is sound.
        if (@constCast(m).extCouldApply(allocator, cls_name, name)) return true;
    }
    const def = g.get().class.clone();
    defer def.deinit();
    if (ClassDef.findMethod(def, allocator, name)) |hit| {
        hit.class.deinit();
        return true;
    }
    return false;
}

/// A function-typed property can share its name with a vararg member method
/// (`val createFrom: (Array<out String>) -> T` alongside
/// `fun createFrom(vararg items: String): T = createFrom(items)`). Kotlin
/// resolves `createFrom("a", "b")` (several args) to the vararg method and
/// `createFrom(items)` (one array, matching the property's single parameter)
/// to the property's `invoke`. KLIO dispatches members by name, so the method
/// shadows the property and the method body recurses. When the receiver holds
/// a callable field whose arity matches the call and the class also has a
/// same-named vararg method, invoke the field: the property is the intended
/// target for this argument shape.
/// The declared receiver-type head of a RECEIVER-function-typed property
/// `name` on the receiver's class (or a superclass), or null when the
/// property is not receiver-fn-typed.
fn recvFnPropHeadOf(self: *VmHost, receiver: *const Value, name: []const u8) ?[]const u8 {
    if (receiver.* != .Instance) return null;
    const mg = self.module.borrow();
    defer mg.deinit();
    const reg = &mg.get().registry;
    var cur: ?[]const u8 = blk2: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk2 cg.get().name;
    };
    var hops: usize = 0;
    while (cur) |cn| : (hops += 1) {
        if (hops > 32) break;
        if (reg.recv_fn_props.get(.{ .a = cn, .b = name })) |h| return h;
        const chain = reg.class_super_names.get(cn) orelse break;
        if (chain.len == 0) break;
        var sn = chain[0];
        if (std.mem.lastIndexOfScalar(u8, sn, '.')) |i| sn = sn[i + 1 ..];
        cur = sn;
    }
    return null;
}

/// The receiver a stored receiver-typed lambda binds at invocation: the
/// owning instance when it implements the declared head
/// (`scope.handler()` with `handler: Scope.() -> Unit`), else the
/// innermost implicit receiver that does. Null when none is in scope —
/// the property does not apply to this call and the walk must continue
/// (`receiver.block()` inside `kotlin.with` must reach with's own `block`
/// PARAM when the receiver carries a same-named receiver-typed field it
/// cannot satisfy, or the whole `with(node) { … }` body is silently
/// replaced by the field's lambda).
fn recvFnReceiverFor(self: *VmHost, allocator: Allocator, receiver: *const Value, head: []const u8) Allocator.Error!?Value {
    if (head.len == 0 or receiverImplementsHead(self, receiver, head)) return receiver.*;
    const chain = try enclosingThisChain(self, allocator);
    defer allocator.free(chain);
    for (chain) |c| {
        if (c != .Instance) continue;
        if (receiverImplementsHead(self, &c, head)) return c;
    }
    return null;
}

/// Select the innermost implicit receiver satisfying `head`, starting with
/// `receiver` and then walking the frame's enclosing-receiver tower.
pub fn implicitReceiverForHead(self: *VmHost, allocator: Allocator, receiver: *const Value, head: []const u8) Allocator.Error!?Value {
    return recvFnReceiverFor(self, allocator, receiver, head);
}

fn recvFnFieldInvoke(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    if (receiver.* != .Instance) return null;
    const head = recvFnPropHeadOf(self, receiver, name) orelse return null;
    const field_val: Value = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const v = g.get().get(name) orelse return null;
        v.retain();
        break :blk v;
    };
    defer field_val.release(allocator);
    const arity = callableFieldArity(self, &field_val) orelse return null;
    // The call supplies the lambda's receiver POSITIONALLY — one arg more than
    // the lambda declares (`getOrBuildCachedDrawBlock(this).block(this)` for a
    // `ContentDrawScope.() -> Unit` field). Split arg0 off as the receiver here
    // rather than leaning on the invoke path's arity heuristic: the owner need
    // not satisfy the head at all, and a stray `it` must not swallow the
    // receiver.
    if (args.len == arity + 1) {
        return try host_call_value.callValueWithThis(self, allocator, &field_val, &args[0], args[1..], &.{});
    }
    {
        // Receiver-bound form (`scope.handler()`): the lambda's receiver can
        // only be the owner, so a field whose declared receiver type the owner
        // cannot satisfy does not apply here. Decline WITHOUT scanning the
        // dynamic chain, so `receiver.block()` inside a generic function reaches
        // the in-scope callable rather than a same-named field on the runtime
        // receiver.
        if (head.len != 0 and !receiverImplementsHead(self, receiver, head)) return null;
    }
    return try host_call_value.callValueWithThis(self, allocator, &field_val, receiver, args, &.{});
}

fn varargShadowedFieldInvoke(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    if (receiver.* != .Instance) return null;
    const field_val: Value = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const v = g.get().get(name) orelse return null;
        v.retain();
        break :blk v;
    };
    defer field_val.release(allocator);

    const arity = callableFieldArity(self, &field_val) orelse return null;
    if (arity != args.len) return null;

    // Only intervene when a same-named vararg method would otherwise shadow
    // the field; a plain function property keeps its ordinary dispatch.
    const resolved = (try resolveInstanceMethod(self, allocator, receiver, name, args, null)) orelse return null;
    const is_vararg = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const f = mg.get().funcById(resolved.fid) orelse break :blk false;
        break :blk f.params.len > 0 and f.params[f.params.len - 1].is_vararg;
    };
    if (!is_vararg) return null;

    // The property's single parameter is the *packed* array form (e.g.
    // `(Array<out String>) -> T`); invoke it only when the sole argument is
    // actually an array (`createFrom(items)`). A non-array single argument
    // (`createFrom("foo")`) is the vararg-element form and must bind the
    // vararg method, which packs it — invoking the property would pass the
    // element where its body expects an array (then `*it` spreads a scalar).
    if (args.len == 1 and args[0] != .Array) return null;

    return try callValueRec(self, allocator, &field_val, args);
}

fn callMemberInnerStatic(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8, no_ext: bool, declared_recv: ?[]const u8) Allocator.Error!EvalResult {
    // A property whose declared type is a RECEIVER function type
    // (`var handler: (suspend Scope.() -> Unit)?`) invoked as a call:
    // Kotlin runs the stored lambda with the owning instance as its
    // receiver (`_deprecatedPointerInputHandler!!()` inside the
    // pointer-input node runs on the node's PointerInputScope). Without
    // the receiver the lambda's bare member reads fall to globals.
    if (try recvFnFieldInvoke(self, allocator, receiver, name, args)) |r| return r;
    // A function-typed property shadowed by a same-named vararg method: invoke
    // the property when the call's argument shape matches it (see the helper).
    if (try varargShadowedFieldInvoke(self, allocator, receiver, name, args)) |r| return r;

    // Fast path: a previously-resolved zero-arg user instance method bypasses the
    // whole probe ladder. The cache is only populated by `irMethodWalk` *after*
    // the per-instance binding probe and every builtin check declined, and those
    // decisions are a pure function of (class, name) — stable across calls — so
    // consulting the cache here is identical to letting them decline again, just
    // without the per-call FQN building, supertype walk, and ~35 type checks.
    // The key folds `static_recv` in, so a statically-directed call is cached
    // apart from the unscoped one (see `instanceMethodKeyScoped`). It matches
    // `irMethodWalk`'s key exactly — that walk populates the entries served
    // here. `declared_recv` is not folded: a user instance method's resolution
    // never depends on it (it only directs the extension fallback, which the
    // ext-cache probe below guards separately).
    if (receiver.* == .Instance) {
        if (instanceMethodKeyScoped(self, receiver, name, args, static_recv, null)) |k| {
            if (instanceMethodCacheGetRaw(self, k)) |raw| {
                if (raw != METHOD_MISS) {
                    if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(raw), args)) |r| return r;
                }
                // A cached miss falls through to the probe ladder (stdlib /
                // extension / field), but `irMethodWalk` will skip the walk.
            }
            // Member-miss that resolved to a top-level extension: dispatch it
            // here, before the whole builtin probe ladder, exactly as the
            // member fast path above does. Same owner-independence guards the
            // cache was populated under.
            if (!strict_ext and !no_ext and static_recv == null and declared_recv == null) {
                if (extMethodCacheGet(self, k)) |fid| {
                    // A top-level extension's `param[0]` is its receiver, so the
                    // member invoker binds `[receiver] ++ args` correctly — and
                    // it builds the frame args in one allocation (no prepend
                    // scratch slice), matching the member fast path's speed.
                    if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(fid), args)) |r| return r;
                }
            }
        }
    }

    // `Throwable.printStackTrace()` / `.stackTraceToString()` over the trace
    // captured when the throwable was thrown.
    if (try throwableStackMember(self, allocator, receiver, name, args)) |r| return r;

    // `Throwable.addSuppressed(e)` / `.getSuppressed()` on an interpreted
    // throwable instance (host `Exception` values route through the stdlib
    // binding).
    if (try throwableSuppressedMember(self, allocator, receiver, name, args)) |r| return r;

    // Built-in delegate protocol.
    if (receiver.* == .Delegate) {
        if (try delegateMember(self, allocator, receiver.Delegate, name, args)) |r| return r;
    }

    // Pack-installed binding overlay + stdlib intrinsic probes for an
    // Instance receiver.
    if (receiver.* == .Instance) {
        if (try instanceBindingProbe(self, allocator, receiver, name, args)) |r| return r;
    }

    // `kotlin.concurrent.Thread` handle members.
    if (receiver.* == .BoundMethod) {
        const bm = receiver.BoundMethod;
        if (std.mem.eql(u8, bm.fqn, "kotlin.concurrent.Thread")) {
            const id: u64 = switch (bm.receiver.asPtr().*) {
                .Long => |v| @bitCast(v),
                else => 0,
            };
            if (std.mem.eql(u8, name, "join")) {
                switch (vmhost.host_impl.joinSpawned(self, id)) {
                    .ok => return .{ .ok = .Unit },
                    .err => |e| return .{ .err = try mapRuntimeError(allocator, e) },
                }
            } else if (std.mem.eql(u8, name, "isAlive")) {
                return .{ .ok = boolVal(vmhost.host_impl.threadAlive(self, id)) };
            } else if (std.mem.eql(u8, name, "name")) {
                // A dispatcher pool worker reports its registered
                // upstream-shaped name (`DefaultDispatcher-worker-N`).
                if (runtime.threadName(allocator, id)) |overridden| {
                    return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, overridden) } };
                }
                const s = try std.fmt.allocPrint(allocator, "klio-thread-{d}", .{id});
                return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
            } else if (std.mem.eql(u8, name, "start") or std.mem.eql(u8, name, "interrupt")) {
                return .{ .ok = .Unit };
            }
        }
    }

    // `Delegates.notNull` / `observable`.
    if (receiver.* == .Intrinsic and std.mem.eql(u8, receiver.Intrinsic.fqn, "kotlin.properties.Delegates")) {
        if (std.mem.eql(u8, name, "notNull") and args.len == 0) {
            return .{ .ok = .{ .Delegate = try ObjRef(DelegateKind).init(allocator, .{ .NotNull = .{ .value = null, .name = "" } }) } };
        }
        if (std.mem.eql(u8, name, "observable") and args.len == 2) {
            return .{ .ok = .{ .Delegate = try ObjRef(DelegateKind).init(allocator, .{ .Observable = .{ .value = args[0], .on_change = args[1] } }) } };
        }
    }

    // Static call on an Intrinsic receiver: probe `<fqn>.<name>`.
    // `Any` surface on a type-in-value-position value (`val c: Any =
    // UByte; c.toString()` — the companion reference lowers to the
    // type's constructor/conversion FUNCTION in a class context):
    // identity string, never the conversion itself.
    if (receiver.* == .Function and std.mem.eql(u8, name, "toString") and args.len == 0) {
        const dn = receiver.Function.decl.name.name;
        if (dn.len > 0 and std.ascii.isUpper(dn[0])) {
            return .{ .ok = try strVal(allocator, dn) };
        }
    }
    if (receiver.* == .Intrinsic) {
        // Same surface for the intrinsic-valued form.
        if (std.mem.eql(u8, name, "toString") and args.len == 0) {
            return .{ .ok = try strVal(allocator, receiver.Intrinsic.fqn) };
        }
        if (std.mem.eql(u8, name, "hashCode") and args.len == 0) {
            return .{ .ok = Value.newInt(@as(i64, @intCast(@intFromPtr(receiver.Intrinsic.fqn.ptr) & 0x7fffffff))) };
        }
        const probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ receiver.Intrinsic.fqn, name });
        defer if (runtime.freeScratch()) allocator.free(probe);
        if (lookupIntrinsic(self, probe)) |func| {
            return dispatchIntrinsic(self, allocator, probe, func, args);
        }
    }
    if (receiver.* == .Class) {
        const cls = receiver.Class;
        const cg = cls.borrow();
        const cname = cg.get().name;
        const cfqn = cg.get().fqn;
        cg.deinit();
        // `Any.toString` on a class/companion value: the class label,
        // never a same-named number intrinsic (`kotlin.UByte.toString`
        // expects a UByte receiver, not the type).
        if (std.mem.eql(u8, name, "toString") and args.len == 0) {
            const label = try std.fmt.allocPrint(allocator, "class {s}", .{cname});
            return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, label) } };
        }
        const probe_simple = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cname, name });
        const probe_fqn = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cfqn, name });
        // `dispatchIntrinsic` borrows the key for the call only; free both
        // scratch probe keys on exit (a per-Class-member-call leak).
        defer if (runtime.freeScratch()) {
            allocator.free(probe_simple);
            allocator.free(probe_fqn);
        };
        if (lookupIntrinsic(self, probe_simple)) |func| return dispatchIntrinsic(self, allocator, probe_simple, func, args);
        if (lookupIntrinsic(self, probe_fqn)) |func| return dispatchIntrinsic(self, allocator, probe_fqn, func, args);
    }

    // `List.optimizeReadOnlyList()` — no-op.
    if (std.mem.eql(u8, name, "optimizeReadOnlyList") and args.len == 0 and receiver.* == .List) {
        return .{ .ok = receiver.* };
    }

    // `listIterator(index)` / `listIterator()` on a List.
    if (std.mem.eql(u8, name, "listIterator") and args.len <= 1 and receiver.* == .List) {
        const size: i64 = blk_sz: {
            const g = receiver.List.items.borrow();
            defer g.deinit();
            break :blk_sz @intCast(g.get().items.len);
        };
        const idx: i64 = if (args.len > 0) (args[0].asI64() orelse 0) else 0;
        // `List.listIterator(index)` throws when `index !in 0..size`.
        if (idx < 0 or idx > size) {
            const msg = try std.fmt.allocPrint(allocator, "index: {d}, size: {d}", .{ idx, size });
            return .{ .err = .{ .Throw = .{ .Exception = .{
                .fqn = try runtime.strInit(allocator, "kotlin.IndexOutOfBoundsException"),
                .message = try runtime.strInitOwned(allocator, msg),
                .cause = null,
            } } } };
        }
        const start: usize = @intCast(idx);
        if (stdlib.implementations.collections.sublistViewStale(receiver)) {
            return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
        }
        const cap = try captureModCount(allocator, receiver.List.mod_count);
        // Share the backing list (not a snapshot) so a `MutableListIterator`'s
        // `set`/`add`/`remove` mutate the underlying list, matching Kotlin. The
        // iterator is mutable only when the source list is.
        return .{ .ok = .{ .Iterator = .{
            .items = receiver.List.items.clone(),
            .cursor = try newCursor(allocator, start, cap.exp_mod),
            .prim = null,
            .mod_count = cap.mod_count,
            .mutable = receiver.List.mutable and receiver.List.backing == null and
                !stdlib.implementations.collections.modCountFrozen(receiver.List.mod_count),
        } } };
    }

    // Self-iterator convention.
    if (std.mem.eql(u8, name, "iterator") and args.len == 0 and (receiver.* == .Iterator or receiver.* == .RangeIter or receiver.* == .SeqIter)) {
        return .{ .ok = receiver.* };
    }

    // Built-in iterator protocol for collections + ranges.
    if (std.mem.eql(u8, name, "iterator") and args.len == 0) {
        if (try builtinIterator(self, allocator, receiver)) |r| return r;
    }

    // Sequence terminal + pipeline ops.
    if (receiver.* == .Sequence) {
        if (try sequenceMember(self, allocator, receiver, name, args)) |r| return r;
    }

    // Inner-class construction: `outer.Inner(args)`. The inner class's
    // registered FQN is `{outer fqn}.{name}`, so the receiver's own class
    // (then its parents) resolves the exact nested class; the bare
    // simple-name view is only the fallback for synthesized shapes.
    if (receiver.* == .Instance) {
        const def_opt = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            var outer_cls: ?ObjRef(ClassDef) = blk2: {
                const g = receiver.Instance.borrow();
                defer g.deinit();
                break :blk2 g.get().class.clone();
            };
            var hops: usize = 0;
            while (outer_cls) |oc| : (hops += 1) {
                if (hops > 64) {
                    oc.deinit();
                    break;
                }
                const og = oc.borrow();
                const outer_fqn = og.get().fqn;
                const qualified = std.fmt.allocPrint(allocator, "{s}.{s}", .{ outer_fqn, name }) catch {
                    og.deinit();
                    oc.deinit();
                    break;
                };
                defer allocator.free(qualified);
                const next: ?ObjRef(ClassDef) = if (og.get().parent) |p| p.clone() else null;
                og.deinit();
                oc.deinit();
                if (cg.get().get(qualified)) |d| {
                    if (next) |n| n.deinit();
                    break :blk d.clone();
                }
                outer_cls = next;
            }
            if (cg.get().get(name)) |d| break :blk d.clone();
            break :blk null;
        };
        if (def_opt) |def| {
            defer def.deinit();
            const dg = def.borrow();
            const is_inner = dg.get().is_inner;
            const def_fqn = dg.get().fqn;
            dg.deinit();
            if (is_inner) {
                // The runtime ClassDef carries the FQN, so resolve the
                // module class by it; a same-simple-name class from
                // another package cannot swap in.
                const mg2 = self.module.borrow();
                const cid_opt = mg2.get().classIdByFqn(def_fqn) orelse mg2.get().classId(name);
                mg2.deinit();
                if (cid_opt) |class_id| {
                    const r = try newInstanceById(self, allocator, class_id, args, receiver);
                    if (r == .ok and r.ok == .Instance) {
                        const ig = r.ok.Instance.borrowMut();
                        ig.get().outer = .{ .Instance = receiver.Instance.clone() };
                        ig.deinit();
                    }
                    return r;
                }
            }
        }
    }

    // `KClass.isInstance(value)`.
    if (receiver.* == .Class and std.mem.eql(u8, name, "isInstance") and args.len == 1) {
        const cg = receiver.Class.borrow();
        const cname = cg.get().name;
        const r = boolVal(args[0].isRuntimeType(cname));
        cg.deinit();
        return .{ .ok = r };
    }
    // `KClass.safeCast(value)` / `KClass.cast(value)` — the value itself
    // on a type match (assertSame identity), else null / a thrown
    // ClassCastException.
    if (receiver.* == .Class and args.len == 1 and
        (std.mem.eql(u8, name, "safeCast") or std.mem.eql(u8, name, "cast")))
    {
        const cg = receiver.Class.borrow();
        const cname = cg.get().name;
        if (args[0].isRuntimeType(cname)) {
            cg.deinit();
            var v = args[0];
            if (runtime.reclaimEnabled()) v.retain();
            return .{ .ok = v };
        }
        if (std.mem.eql(u8, name, "safeCast")) {
            cg.deinit();
            return .{ .ok = .Null };
        }
        const msg = try std.fmt.allocPrint(allocator, "Value cannot be cast to {s}", .{cg.get().fqn});
        defer if (runtime.freeScratch()) allocator.free(msg);
        cg.deinit();
        return .{ .err = try throwExc(allocator, "kotlin.ClassCastException", msg) };
    }

    // Nested-class construction on a class receiver.
    if (receiver.* == .Class) {
        const cg = receiver.Class.borrow();
        const cname = cg.get().name;
        const cfqn = cg.get().fqn;
        cg.deinit();
        const mg = self.module.borrow();
        const mod = mg.get();
        // The nesting tree answers directly from the receiver's class id;
        // the string-joined fqn probes remain only for classes the tree
        // could not link (a legacy simple-name stub parent).
        var class_id: ?ir.ClassId = blk: {
            const rid = mod.classIdByFqn(cfqn) orelse mod.classId(cname) orelse break :blk null;
            break :blk mod.classIdNestedIn(rid, name);
        };
        if (class_id == null) {
            const fqn_probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cfqn, name });
            defer if (runtime.freeScratch()) allocator.free(fqn_probe);
            class_id = mod.classIdByFqn(fqn_probe);
        }
        if (class_id == null) class_id = mod.classId(name);
        mg.deinit();
        if (class_id) |cid| {
            return newInstanceById(self, allocator, cid, args, null);
        }
    }

    // Companion forwarding + enum values/valueOf for a class receiver.
    if (receiver.* == .Class) {
        if (try classCompanionAndEnum(self, allocator, receiver, name, args)) |r| return r;
    }

    // A null value has no useful runtime type, but a statically-directed call
    // still has an exact declared receiver. Use that receiver to address its
    // host binding before the runtime-type member ladder. This is how a
    // `String?::plus` reference invokes `kotlin.String.plus` when its eventual
    // receiver is null, without widening to unrelated `plus` extensions.
    if (receiver.* == .Null) {
        if (static_recv) |declared| {
            const head = staticReceiverBindingHead(declared);
            if (head.len != 0) {
                var fqn_buf: [256]u8 = undefined;
                const fqn = if (std.mem.indexOfScalar(u8, head, '.') != null)
                    std.fmt.bufPrint(&fqn_buf, "{s}.{s}", .{ head, name }) catch null
                else
                    std.fmt.bufPrint(&fqn_buf, "kotlin.{s}.{s}", .{ head, name }) catch null;
                if (fqn) |binding_fqn| {
                    if (lookupIntrinsic(self, binding_fqn)) |func| {
                        return dispatchWithReceiver(self, allocator, binding_fqn, func, receiver, args);
                    }
                }
            }
        }
    }

    // Null-receiver `equals` — 1-arg `Any?.equals` and 2-arg
    // `String?.equals(other, ignoreCase)` both reduce to `other === null`.
    if (receiver.* == .Null and std.mem.eql(u8, name, "equals") and args.len >= 1) {
        return .{ .ok = boolVal(args[0] == .Null) };
    }
    // Null-receiver `toString()` (`null.toString()` is the string "null"); the
    // bodyless `Any?.toString()` actual would otherwise evaluate to Unit.
    if (receiver.* == .Null and std.mem.eql(u8, name, "toString") and args.len == 0) {
        return .{ .ok = .{ .String = try runtime.strInit(allocator, "null") } };
    }
    if (receiver.* == .Null and std.mem.eql(u8, name, "hashCode") and args.len == 0) {
        return .{ .ok = .{ .Int = 0 } };
    }
    // Null-receiver array `content*` extensions: `(null as IntArray?).contentToString()`
    // and friends declare a nullable array receiver, so a null receiver is valid
    // (`"null"`, `0`, or null-equality). The intrinsics are registered under
    // `kotlin.Array.*` and already branch on a `.Null` receiver, but a null's type
    // is `kotlin.Nothing`, so the type-probe never reaches them and the bodyless
    // `expect` actual would otherwise evaluate to Unit.
    if (receiver.* == .Null and isArrayContentFn(name)) {
        var key_buf: [64]u8 = undefined;
        const fqn = std.fmt.bufPrint(&key_buf, "kotlin.Array.{s}", .{name}) catch unreachable;
        if (lookupIntrinsic(self, fqn)) |func| {
            return dispatchWithReceiver(self, allocator, fqn, func, receiver, args);
        }
    }

    // `equals` on a builtin scalar/String.
    if (std.mem.eql(u8, name, "equals") and isBuiltinScalar(receiver)) {
        if (receiver.* == .String and args.len > 1 and args[1] == .Bool and args[1].Bool) {
            if (args.len > 0 and args[0] == .String) {
                const eq = eqIgnoreCase(allocator, receiver.String, args[0].String);
                return .{ .ok = boolVal(eq) };
            }
            return .{ .ok = boolVal(false) };
        }
        // `Char.equals(other, ignoreCase = true)`.
        if (receiver.* == .Char and args.len > 1 and args[1] == .Bool and args[1].Bool) {
            if (args.len > 0 and args[0] == .Char) {
                const eq = stdlib.implementations.char.charEqIgnoreCase(receiver.Char, args[0].Char);
                return .{ .ok = boolVal(eq) };
            }
            return .{ .ok = boolVal(false) };
        }
        if (args.len > 0) {
            return .{ .ok = boolVal(Value.structuralEq(receiver, &args[0])) };
        }
    }

    // SAM-instance dispatch via `__sam_target__`.
    if (receiver.* == .Instance) {
        if (try samInstanceDispatch(self, allocator, receiver, name, args)) |r| return r;
    }

    // Bound method/property-reference dispatch.
    if (receiver.* == .Instance) {
        if (try boundRefDispatch(self, allocator, receiver, name, args)) |r| return r;
    }

    // A constructor reference (`::Throwable`, `::Foo`) invoked through its
    // `invoke`/`call` member constructs. The SAM block below deliberately
    // skips `invoke`, so route class / constructor-intrinsic receivers here.
    if ((receiver.* == .Class or receiver.* == .Intrinsic) and
        (std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "call")))
    {
        const r = try callValueRec(self, allocator, receiver, args);
        if (r == .ok) return r;
    }

    // SAM conversion on a callable receiver. The interface-method reading
    // is only plausible when the callable's declared parameter count
    // matches the call: without the gate, any unresolved helper name
    // probed against a coroutine block invoked the block itself
    // (`probeCoroutineResumed(completion)` inside
    // `startCoroutineUndispatched` — every UNDISPATCHED launch body ran
    // twice, `samsusp` ×N).
    if (isCallableOrIntrinsic(receiver)) {
        const has_ext = extWithThisLongerThanArgs(self, name, args.len);
        // A SAM-converted value may carry one extra leading slot (the
        // adapter's receiver): `callback.shouldPause()` on a wrapped
        // `() -> Boolean` reads as arity 1. The invoke path binds the
        // receiver, so +1 is as unambiguous as an exact match.
        const arity_ok = if (callableFieldArity(self, receiver)) |n| n == args.len or n == args.len + 1 else true;
        // A bare name a top-level NON-extension function serves is that
        // function, never the callable's interface method: kotlinc
        // resolves `probeCoroutineResumed(completion)` to the top-level
        // helper even inside an extension on a function type. Names with
        // only member/extension forms (`FlowCollector`'s `emit` on a
        // collector that arrived as a plain lambda) keep the SAM arm.
        const toplevel_serves = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const mod = mg.get();
            for (mod.funcsBySimpleName(name)) |fid| {
                const f = funcAt(mod, fid) orelse continue;
                if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
                break :blk true;
            }
            break :blk false;
        };
        if (runtime.getenvSlice("KLIO_SAM_TRACE") != null) std.debug.print("[sam-gate] name={s} nargs={d} has_ext={} arity_ok={} tl={}\n", .{ name, args.len, has_ext, arity_ok, toplevel_serves });
        if (!std.mem.eql(u8, name, "invoke") and !has_ext and arity_ok and !toplevel_serves) {
            if (runtime.getenvSlice("KLIO_SAM_TRACE") != null) std.debug.print("[sam-arm] name={s} nargs={d} arity_ok={} tl={}\n", .{ name, args.len, arity_ok, toplevel_serves });
            const r = try callValueRec(self, allocator, receiver, args);
            switch (r) {
                .ok => return r,
                .err => |e| switch (e) {
                    .Suspended, .CalleeFailed, .Throw, .NonLocalReturn, .LabeledReturn => return r,
                    else => {},
                },
            }
        }
    }

    // KClass equality + hash + toString.
    if (receiver.* == .Class) {
        if (try kclassMembers(self, allocator, receiver, name, args)) |r| return r;
    }

    // KFunction reflection surface on a callable value.
    if (receiver.* == .IrClosure or receiver.* == .Function) {
        if (std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "call")) {
            return callValueRec(self, allocator, receiver, args);
        }
        if (args.len == 0 and receiver.* == .IrClosure) {
            if (try kfunctionReflection(self, allocator, receiver, name)) |r| return r;
        }
        if (try samMemberExtOnCallable(self, allocator, receiver, name, args)) |r| return r;
    }

    // PropertyRef invocation.
    if (receiver.* == .PropertyRef) {
        if (try propertyRefDispatch(self, allocator, receiver, name, args)) |r| return r;
    }

    // Enum entries compare by ordinal.
    if (std.mem.eql(u8, name, "compareTo") and args.len == 1 and receiver.* == .Instance and args[0] == .Instance) {
        const ag = receiver.Instance.borrow();
        const cg = ag.get().class.borrow();
        const is_enum = cg.get().is_enum;
        cg.deinit();
        if (is_enum) {
            const ord_a: i64 = if (ag.get().get("ordinal")) |v| (v.asI64() orelse 0) else 0;
            ag.deinit();
            const bg = args[0].Instance.borrow();
            const ord_b: i64 = if (bg.get().get("ordinal")) |v| (v.asI64() orelse 0) else 0;
            bg.deinit();
            return .{ .ok = Value.newInt(ord_a - ord_b) };
        }
        ag.deinit();
    }

    // Natural-order sort on a list of Instances via `compareTo`.
    if ((std.mem.eql(u8, name, "sorted") or std.mem.eql(u8, name, "sortedDescending")) and args.len == 0 and receiver.* == .List) {
        if (try sortedInstances(self, allocator, receiver, name)) |r| return r;
    }

    // Comparator chaining + reversal + compare.
    if (receiver.* == .Comparator) {
        if (try comparatorMember(self, allocator, receiver, name, args)) |r| return r;
    }

    // `r.contains(x)` on a Range.
    if (std.mem.eql(u8, name, "contains") and args.len == 1 and receiver.* == .Range and
        args[0] != .Range)
    {
        const r = receiver.Range;
        // A descending progression (step < 0) has start > end; the membership
        // bounds run low..high regardless of iteration direction.
        const lo = if (r.step > 0) r.start else r.end;
        const hi = if (r.step > 0) r.end else r.start;
        const inside = blk: {
            if (args[0] == .Char and r.kind == .Char) {
                const cv: i64 = @intCast(args[0].Char);
                break :blk cv >= lo and cv <= hi and @rem(cv - r.start, r.step) == 0;
            }
            // Unsigned ranges span the full u64 space stored as raw i64
            // bits; the membership compare must be unsigned
            // (`0uL until ULong.MAX_VALUE` has end bits -2).
            if (r.kind == .ULong or r.kind == .UInt) {
                const uv: u64 = args[0].asU64() orelse
                    (if (args[0].asI64()) |sv| @as(u64, @bitCast(sv)) else break :blk false);
                const us: u64 = @bitCast(r.start);
                const ue: u64 = @bitCast(r.end);
                const ulo = @min(us, ue);
                const uhi = @max(us, ue);
                const diff = @as(i128, uv) - @as(i128, us);
                break :blk uv >= ulo and uv <= uhi and @rem(diff, @as(i128, r.step)) == 0;
            }
            if (args[0].asI64()) |v| {
                // Widen the step-alignment difference: `v - r.start` overflows
                // i64 for a range spanning most of the type (`MIN..MAX`), which
                // Kotlin's `in` check tolerates.
                const diff = @as(i128, v) - @as(i128, r.start);
                break :blk v >= lo and v <= hi and @rem(diff, @as(i128, r.step)) == 0;
            }
            break :blk false;
        };
        return .{ .ok = boolVal(inside) };
    }

    // `key in map` on a *user* Map implementation.
    if (std.mem.eql(u8, name, "contains") and args.len == 1 and receiver.* == .Instance and
        hostHasMember(self, receiver, "containsKey") and !hostHasMember(self, receiver, "contains"))
    {
        return callMemberRec(self, allocator, receiver, "containsKey", args);
    }

    // `m.contains/containsKey/containsValue` for a Map.
    if (receiver.* == .Map) {
        if (std.mem.eql(u8, name, "contains") or std.mem.eql(u8, name, "containsKey")) {
            if (args.len == 1) {
                const r = try mapContainsKeyEq(self, allocator, receiver.Map.entries, &args[0]);
                return switch (r) {
                    .ok => |b| .{ .ok = boolVal(b) },
                    .err => |e| .{ .err = e },
                };
            }
        } else if (std.mem.eql(u8, name, "containsValue") and args.len == 1) {
            const g = receiver.Map.entries.borrow();
            defer g.deinit();
            var has = false;
            for (g.get().pairs.items) |kv| {
                if (Value.structuralEqBoxed(&kv.value, &args[0])) {
                    has = true;
                    break;
                }
            }
            return .{ .ok = boolVal(has) };
        }
    }

    // Array shape ops.
    if (receiver.* == .List and std.mem.eql(u8, name, "toTypedArray") and args.len == 0) {
        const items = try cloneItemsList(allocator, receiver.List.items);
        return .{ .ok = runtime.ArrayData.fromBoxedList(try ObjRef(std.ArrayList(Value)).init(allocator, items)) };
    }
    if (receiver.* == .Array) {
        if (try arrayShapeOps(self, allocator, receiver, name, args)) |r| return r;
        // `Any.toString` on an array is the identity string (no member
        // or extension overrides it): the same `fqn@identity` form
        // instances use. Notably NOT the contents — a self-referencing
        // array's `toString()` must not recurse
        // (ArraysTest.contentDeepToStringNoRecursion).
        if (std.mem.eql(u8, name, "toString") and args.len == 0) {
            const s = try std.fmt.allocPrint(allocator, "{s}@{x}", .{ receiver.typeFqn(), receiver.Array.identity() });
            return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
        }
    }

    // Indexed get/set on Array.
    if (std.mem.eql(u8, name, "get") and args.len == 1 and receiver.* == .Array) {
        if (args[0].asI64()) |idx| {
            const arr = receiver.Array;
            const n = arr.len();
            if (idx >= 0 and @as(usize, @intCast(idx)) < n) {
                const elem = arr.get(@intCast(idx));
                // Borrowed element: the array still owns it, so retain before
                // handing it to the register that will own the result (packed
                // scalars are fresh, so the retain is a no-op).
                elem.retain();
                return .{ .ok = elem };
            }
            const msg = try std.fmt.allocPrint(allocator, "Index {d} out of bounds for length {d}", .{ idx, n });
            defer if (runtime.freeScratch()) allocator.free(msg);
            return .{ .err = try throwExc(allocator, "kotlin.ArrayIndexOutOfBoundsException", msg) };
        }
    }
    if (std.mem.eql(u8, name, "set") and args.len == 2 and receiver.* == .Array) {
        if (args[0].asI64()) |idx| {
            const arr = receiver.Array;
            const n = arr.len();
            if (idx >= 0 and @as(usize, @intCast(idx)) < n) {
                arr.set(allocator, @intCast(idx), args[1]);
                return .{ .ok = .Unit };
            }
            const msg = try std.fmt.allocPrint(allocator, "Index {d} out of bounds for length {d}", .{ idx, n });
            defer if (runtime.freeScratch()) allocator.free(msg);
            return .{ .err = try throwExc(allocator, "kotlin.ArrayIndexOutOfBoundsException", msg) };
        }
    }

    // Built-in collection in-place mutation operators.
    if (try collectionMutators(self, allocator, receiver, name, args)) |r| return r;

    // Pair / Triple / MapEntry components.
    if (try componentMembers(self, allocator, receiver, name, args)) |r| return r;

    // Iterator + RangeIter protocols.
    if (receiver.* == .Iterator) {
        if (try iteratorMember(self, allocator, receiver, name, args)) |r| return r;
    }
    if (receiver.* == .RangeIter) {
        if (try rangeIterMember(self, allocator, receiver, name, args)) |r| return r;
    }
    if (receiver.* == .SeqIter) {
        if (try seqIterMember(self, allocator, receiver, name, args)) |r| return r;
    }

    // Data-class / value-class auto members.
    if (receiver.* == .Instance) {
        if (try dataClassAutoMembers(self, allocator, receiver, name, args)) |r| return r;
    }

    // Runtime-lowered anon-object / local-class method dispatch.
    if (receiver.* == .Instance) {
        if (try anonMethodDispatch(self, allocator, receiver, name, args)) |r| return r;
    }

    // IR class + supertype method walk.
    if (receiver.* == .Instance) {
        if (try irMethodWalk(self, allocator, receiver, name, args, static_recv)) |r| return r;
    }

    // Generic Any.toString / equals / hashCode fallback for Instances.
    if (receiver.* == .Instance) {
        if (try anyInstanceFallback(self, allocator, receiver, name, args)) |r| return r;
    }

    // `kotlin.Unit` Any methods.
    if (receiver.* == .Unit) {
        if (std.mem.eql(u8, name, "equals") and args.len == 1) {
            return .{ .ok = boolVal(args[0] == .Unit) };
        }
        if (std.mem.eql(u8, name, "hashCode") and args.len == 0) return .{ .ok = Value.newInt(0) };
        if (std.mem.eql(u8, name, "toString") and args.len == 0) return .{ .ok = try strVal(allocator, "kotlin.Unit") };
    }

    // `Boolean` operator members: `b.not()`, `b.and(x)`, `b.or(x)`,
    // `b.xor(x)`, `b.compareTo(x)`. The `!`/`&&`/`||` syntax lowers to
    // unary/binops, but the named members are also callable (e.g.
    // `isEmpty().not()`), and are not otherwise resolved for a `Bool` value.
    if (receiver.* == .Bool) {
        const b = receiver.Bool;
        if (std.mem.eql(u8, name, "not") and args.len == 0) return .{ .ok = boolVal(!b) };
        if (args.len == 1 and args[0] == .Bool) {
            const o = args[0].Bool;
            if (std.mem.eql(u8, name, "and")) return .{ .ok = boolVal(b and o) };
            if (std.mem.eql(u8, name, "or")) return .{ .ok = boolVal(b or o) };
            if (std.mem.eql(u8, name, "xor")) return .{ .ok = boolVal(b != o) };
            if (std.mem.eql(u8, name, "compareTo")) {
                const bi: i64 = @intFromBool(b);
                const oi: i64 = @intFromBool(o);
                return .{ .ok = Value.newInt(if (bi < oi) @as(i64, -1) else if (bi > oi) @as(i64, 1) else 0) };
            }
        }
    }

    // `hashCode()` on a builtin value type. Containers hash their
    // elements through member dispatch so a user class's hashCode()
    // override participates (kotlin: listOf(x).hashCode() folds
    // x.hashCode()).
    if (args.len == 0 and std.mem.eql(u8, name, "hashCode") and
        receiver.* != .Instance and receiver.* != .Class and receiver.* != .PropertyRef)
    {
        if (stdlib.implementations.collections.sublistViewStale(receiver)) {
            return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
        }
        return .{ .ok = Value.newInt(@as(i64, try hashWithDispatch(self, allocator, receiver))) };
    }

    // A stale subList view rejects `equals` too (`SubList.equals` runs
    // checkForComodification before comparing).
    if (args.len == 1 and std.mem.eql(u8, name, "equals") and receiver.* == .List and
        stdlib.implementations.collections.sublistViewStale(receiver))
    {
        return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
    }

    // A DECLARED receiver head overrides the runtime-type surface:
    // kotlinc resolves against the static type, so `data - "foo"` where
    // `data: T` is bounded by Iterable dispatches `Iterable.minus`
    // (returning a List) even when the runtime value is a Set. Only the
    // generic iterable surfaces divert — a declared List/Set head equals
    // the runtime surface anyway.
    if (declared_recv) |dn| {
        if (std.mem.eql(u8, dn, "Iterable") or std.mem.eql(u8, dn, "Collection") or
            std.mem.eql(u8, dn, "MutableCollection"))
        {
            var buf: [96]u8 = undefined;
            const fqn = std.fmt.bufPrint(&buf, "kotlin.collections.Iterable.{s}", .{name}) catch buf[0..0];
            if (lookupIntrinsic(self, fqn)) |func| {
                return dispatchWithReceiver(self, allocator, fqn, func, receiver, args);
            }
        }
    }

    // Stdlib member dispatch (type-FQN + package extension probes).
    if (try stdlibMemberDispatch(self, allocator, receiver, name, args)) |r| return r;

    // Class-delegation pre-pass.
    if (receiver.* == .Instance) {
        if (try delegateForward(self, allocator, receiver, name, args, true)) |r| return r;
    }

    // Extension-fn fallback.
    // A members-only probe (the caller holds a lowering-committed extension
    // target): Kotlin selects extensions statically, so only a true member
    // may shadow it — the by-name extension re-pick must not re-select a
    // sibling overload the static evidence excluded.
    if (!no_ext) {
        if (try extensionFnFallback(self, allocator, receiver, name, args, strict_ext, static_recv, declared_recv)) |r| return r;
        // An enclosing SAM conversion of a fun interface whose single
        // abstract method is a MEMBER EXTENSION on this receiver's type
        // (`with(policy) { scope.measure(w, h) }` where `policy` is
        // `MeasurePolicy { ... }`): the abstract slot lowers no func, so
        // the extension fallback has no candidate — the stored lambda
        // serves the call with the receiver bound as its `this`.
        if (try enclosingSamMemberExtDispatch(self, allocator, receiver, name, args)) |r| return r;
        // The same shape with the lambda UNWRAPPED: `with(measurePolicy) { measure(…) }`
        // where the policy is the trailing lambda of `Layout(modifier, content) { … }`.
        // No SAM instance was built, so the receiver tower carries the raw closure and
        // the arm above (which looks for `__sam_target__`) has nothing to find.
        if (try enclosingSamLambdaDispatch(self, allocator, receiver, name, args)) |r| return r;
        // An enclosing anonymous-object instance whose site declares a
        // MEMBER-EXTENSION override accepting this receiver
        // (`with(verticalArrangement) { measureScope.arrange(...) }` where
        // the arrangement is `object : Vertical { override fun
        // Density.arrange(...) }`): anonymous classes register methods in
        // the per-site table, not the module func index, so the extension
        // fallback never sees them.
        if (try enclosingAnonMemberExtDispatch(self, allocator, receiver, name, args)) |r| return r;
    }

    // Range → List re-dispatch: a last-resort member surface only. It must
    // run after the extension fallback so receiver-generic extensions
    // (`let`, `also`, the interpreted `Iterable` surface) keep the real
    // progression receiver — materialising first would hand the callable a
    // `List` and lose the receiver's identity (`first`/`last`/`step`,
    // progression `hashCode`/`toString`).
    if (receiver.* == .Range) {
        const r = receiver.Range;
        const items = try materialiseRangeItems(allocator, r.start, r.end, r.step, r.kind);
        const as_list = try listOf(allocator, items, false);
        return callMemberRec(self, allocator, &as_list, name, args);
    }

    // Class-delegation forwarding (swallow all errors).
    if (receiver.* == .Instance) {
        if (try delegateForward(self, allocator, receiver, name, args, false)) |r| return r;
    }

    // Companion-method forwarding for a class receiver.
    if (receiver.* == .Class) {
        if (try classCompanionForward(self, allocator, receiver, name, args)) |r| return r;
    }

    // Reflective KSerializer synthesis.
    if (std.mem.eql(u8, name, "serializer") and args.len == 0 and
        (receiver.* == .Class or receiver.* == .BoundInnerClass))
    {
        const factory = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get("ReflectiveKSerializer")) |d| break :blk d.clone();
            break :blk null;
        };
        if (factory) |def| {
            defer def.deinit();
            const dg = def.borrow();
            const dn = dg.get().name;
            dg.deinit();
            if (self.module.borrow().get().classId(dn)) |cid| {
                const ctor_args = [_]Value{receiver.*};
                return newInstanceById(self, allocator, cid, &ctor_args, null);
            }
        }
    }

    // Companion fallback for an instance receiver.
    if (receiver.* == .Instance) {
        if (try instanceCompanionFallback(self, allocator, receiver, name, args)) |r| return r;
    }

    // COROUTINE_SUSPENDED member surface.
    if (receiver.* == .CoroutineSuspended) {
        if (std.mem.eql(u8, name, "toString")) return .{ .ok = try strVal(allocator, "COROUTINE_SUSPENDED") };
        if (std.mem.eql(u8, name, "hashCode")) return .{ .ok = .{ .Int = 0 } };
        if (std.mem.eql(u8, name, "equals")) {
            return .{ .ok = boolVal(args.len > 0 and args[0] == .CoroutineSuspended) };
        }
    }

    // Function-typed property invoked by name.
    if (receiver.* == .Instance) {
        const field = blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            for (g.get().fields.items) |f| {
                if (std.mem.eql(u8, f.name, name)) break :blk f.value;
            }
            break :blk null;
        };
        if (field) |v| {
            if (missTraceWant(name)) std.debug.print("[fnprop] own-field hit tag={s} callable={}\n", .{ @tagName(v), isCallable(&v) });
            if (isCallable(&v) or v == .Instance) {
                // A RECEIVER-function-typed property binds an implicit
                // receiver of its declared head at invocation; with none
                // in scope the property does not apply — skip the arm.
                if (recvFnPropHeadOf(self, receiver, name)) |head| {
                    if (try recvFnReceiverFor(self, allocator, receiver, head)) |rv| {
                        return try host_call_value.callValueWithThis(self, allocator, &v, &rv, args, &.{});
                    }
                } else {
                    return callValueRec(self, allocator, &v, args);
                }
            }
        } else if (blk: {
            // Accessor-backed property holding a callable (`state.value()`
            // where `value` has a custom getter): probe the member-only
            // property read — no global/outer tails, so a genuine miss
            // stays a miss and the walk continues. Gated on the name having
            // ANY custom getter in the program, so an ordinary method-miss
            // name (`resumeWith` on every DeepRecursive iteration) never
            // pays the property-resolution machinery.
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().getter_prop_names.contains(name) and
                receiverPropCanHoldCallable(self, receiver, name);
        }) {
            const pr = try host_fields.getMemberField(self, allocator, receiver, name);
            if (missTraceWant(name)) {
                switch (pr) {
                    .ok => |v| std.debug.print("[fnprop] getMemberField ok tag={s} callable={}\n", .{ @tagName(v), isCallable(&v) }),
                    .err => |e| switch (e) {
                        .Unsupported, .Type => |m| std.debug.print("[fnprop] getMemberField err: {s}\n", .{m}),
                        else => std.debug.print("[fnprop] getMemberField err tag={s}\n", .{@tagName(e)}),
                    },
                }
            }
            if (pr == .ok and (isCallable(&pr.ok) or pr.ok == .Instance)) {
                return callValueRec(self, allocator, &pr.ok, args);
            }
        }
    }

    // Extension-function-typed member invoked with an explicit receiver.
    if (try enclosingCallableProperty(self, allocator, name)) |v| {
        // `invoke_callable_with_this` overrides the callable's captured
        // `this` slot with `receiver` for the duration of the body. The
        // displaced prior capture (the lexically-enclosing receiver the
        // body closed over) must stay reachable as an outer implicit
        // receiver, or a bare member call in the body that targets it
        // (e.g. an `unsafeFlow { collect { … } }` operator block whose
        // `collect` runs on the captured upstream flow, not on the
        // collector receiver) re-resolves against the dynamic enclosing
        // `this` and recurses. Push that prior `this` (when distinct from
        // the receiver) so the body sees it, mirroring the value-call path.
        const prior_this: ?Value = blk: {
            if (v != .IrClosure) break :blk null;
            const info = self.closures.get(@intCast(v.IrClosure.id)) orelse break :blk null;
            var this_idx: ?usize = null;
            for (info.capture_names, 0..) |n, idx| {
                if (std.mem.eql(u8, n, "this")) {
                    this_idx = idx;
                    break;
                }
            }
            const idx = this_idx orelse break :blk null;
            const cg = info.captures.borrow();
            defer cg.deinit();
            if (idx < cg.get().items.len) break :blk cg.get().items[idx];
            break :blk null;
        };
        const pushed_outer = po: {
            const pt = prior_this orelse break :po false;
            if (pt == .Null or pt == .Unit) break :po false;
            if (pt == .Instance and receiver.* == .Instance) {
                break :po !ObjRef(InstanceData).ptrEq(pt.Instance, receiver.Instance);
            }
            break :po true;
        };
        if (pushed_outer) {
            if (prior_this) |p| pushAccessEnclosing(self, &p);
        }
        // Dispatch on the main evaluator path (`callValueWithThis`), not the
        // intrinsic-host invoke: that path snapshots frames so a suspension
        // inside the receiver-lambda body parks + resumes correctly. The
        // intrinsic-host invoke strands the activation, so a `suspend
        // FlowCollector.() -> Unit` field invoked as `collector.block()` (every
        // `flow {}` producer) re-runs from the top or resumes a non-closure.
        const r = try self.callValueWithThis(allocator, &v, receiver, args, &.{});
        if (pushed_outer) popAccessEnclosing(self);
        return r;
    }

    // Map fallback.
    if (receiver.* == .Instance and !map_fallback_active and
        hostHasMember(self, receiver, "entries") and !hostHasMember(self, receiver, "iterator"))
    {
        const probe = try std.fmt.allocPrint(allocator, "kotlin.collections.Map.{s}", .{name});
        defer if (runtime.freeScratch()) allocator.free(probe);
        if (lookupIntrinsic(self, probe)) |f| {
            const built = blk: {
                map_fallback_active = true;
                defer map_fallback_active = false;
                break :blk try materializeUserMap(self, allocator, receiver);
            };
            const map_val = switch (built) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            const new_args = try prependReceiver(allocator, &map_val, args);
            defer if (runtime.freeScratch()) allocator.free(new_args);
            return dispatchIntrinsic(self, allocator, probe, f, new_args);
        }
    }

    // CharSequence fallback: a user CharSequence implementation gets the
    // full text surface by materializing through its own toString() and
    // re-dispatching on the String — text ops never mutate the receiver.
    // Runs after the member walk missed, so an op the class itself
    // declares still wins.
    if (receiver.* == .Instance and !charseq_fallback_active and
        instanceImplementsCharSequence(self, receiver))
    {
        charseq_fallback_active = true;
        defer charseq_fallback_active = false;
        const sres = try callMemberRec(self, allocator, receiver, "toString", &.{});
        switch (sres) {
            .ok => |sv| {
                if (sv == .String) {
                    return try callMemberRec(self, allocator, &sv, name, args);
                }
            },
            .err => {},
        }
    }

    // Iterable fallback.
    if (receiver.* == .Instance and !iterable_fallback_active and
        (hostHasMember(self, receiver, "iterator") or samIterableInstance(self, allocator, receiver)))
    {
        // An instance whose class chain implements SEQUENCE keeps
        // Kotlin's sequence laziness: when a declared Sequence-receiver
        // extension body serves this name, run that lazy source
        // implementation instead of the eager drain-to-List.
        if (instanceImplementsSequence(self, receiver)) {
            if (sequenceExtBodyFid(self, name, args.len)) |fid| {
                const mg = self.module.borrow();
                const mod: *const Module = mg.get();
                mg.deinit();
                const new_args = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(new_args);
                return try host_call_func.callFunc(self, allocator, mod, fid, new_args);
            }
        }
        {
            const p1 = try std.fmt.allocPrint(allocator, "kotlin.collections.Iterable.{s}", .{name});
            defer if (runtime.freeScratch()) allocator.free(p1);
            var matched: []const u8 = p1;
            var intrinsic = lookupIntrinsic(self, p1);
            var p2_owned: ?[]const u8 = null;
            defer if (runtime.freeScratch()) if (p2_owned) |p| allocator.free(p);
            if (intrinsic == null) {
                const p2 = try std.fmt.allocPrint(allocator, "kotlin.collections.List.{s}", .{name});
                p2_owned = p2;
                intrinsic = lookupIntrinsic(self, p2);
                matched = p2;
            }
            if (intrinsic) |f| {
                // `toTypedArray` must observe a user `toArray()` override
                // before any drain (JS/native `collectionToArray` semantics);
                // its intrinsic handles Instance receivers itself.
                if (std.mem.eql(u8, name, "toTypedArray")) {
                    return try dispatchWithReceiver(self, allocator, matched, f, receiver, args);
                }
                const drained = blk: {
                    iterable_fallback_active = true;
                    defer iterable_fallback_active = false;
                    break :blk try drainIterableToList(self, allocator, receiver);
                };
                const dv = switch (drained) {
                    .ok => |v| v,
                    .err => |e| return .{ .err = e },
                };
                const new_args = try prependReceiver(allocator, &dv, args);
                defer if (runtime.freeScratch()) allocator.free(new_args);
                return dispatchIntrinsic(self, allocator, matched, f, new_args);
            }
        }
    }

    // Function-typed property called with parentheses.
    if (receiver.* == .Instance) {
        const field = blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            break :blk g.get().get(name);
        };
        if (field) |f| {
            switch (f) {
                .Function, .IrClosure, .Class => {
                    // Same receiver-fn-typed applicability gate as the
                    // by-name arm above.
                    if (recvFnPropHeadOf(self, receiver, name)) |head| {
                        if (try recvFnReceiverFor(self, allocator, receiver, head)) |rv| {
                            return try host_call_value.callValueWithThis(self, allocator, &f, &rv, args, &.{});
                        }
                    } else {
                        return callValueRec(self, allocator, &f, args);
                    }
                },
                else => {},
            }
        }
    }

    // A property `name` next to a top-level `fun name()` — call the function.
    if (receiver.* == .Instance and hostHasMember(self, receiver, name)) {
        if (lookupGlobalValue(self, name)) |g| {
            switch (g) {
                .Function, .IrClosure => return callValueRec(self, allocator, &g, args),
                else => {},
            }
        }
    }

    // `recv.prop { lambda }` where `prop` is an extension property (not a
    // member method) whose value is a callable instance: Kotlin parses this
    // as `(recv.prop)(lambda)`. When no `prop` method resolves, get the
    // extension-property value and invoke it with the trailing lambda. This
    // is how `channel.onReceive { … }` works — `onReceive` is a
    // `SelectClause1` property whose `invoke` operator (supplied by the
    // enclosing `SelectBuilder`) registers the clause. Resolved via
    // `getMemberField` (receiver-owned only, no global/top-level fallback)
    // and gated on (a) an `Instance` property value and (b) a trailing
    // callable argument — the clause-invoke shape — so an ordinary member
    // call whose method resolution legitimately missed (and is handled by a
    // downstream fallback) is never pre-empted. Leading positional args before
    // the trailing lambda are passed through, so a `SelectClause2`
    // (`channel.onSend(value) { … }`) invokes with `(value, block)`.
    if (receiver.* == .Instance and args.len >= 1 and isCallable(&args[args.len - 1])) {
        const got = self.getMemberField(allocator, receiver, name) catch EvalResult{ .err = .{ .Type = "" } };
        if (got == .ok) {
            const pv = got.ok;
            if (pv == .Instance) {
                defer pv.release(allocator);
                return try callValueRec(self, allocator, &pv, args);
            }
            pv.release(allocator);
        } else {
            host_fields.freeFieldMiss(allocator, got.err);
        }
    }

    // A RENAMING import (`import a.b.f as g`) reached as a receiver call
    // the lowering did not rewrite: on a total miss, resolve the alias
    // from the call site's file and bind the aliased extension by FQN.
    // The FQN restriction keeps a same-receiver namesake under the
    // target's ORIGINAL name (a delegating wrapper) from capturing the
    // retry and recursing. O(1)-gated: one hashmap probe per total miss.
    if (ir.eval.currentCallSiteSpan()) |sp| {
        var chosen: ?ir.FuncId = null;
        var chosen_exact = false;
        var retry_leaf: ?[]const u8 = null;
        {
            const mg = self.module.borrow();
            defer mg.deinit();
            const m = mg.get();
            const paths = m.importAliasPathsIn(sp.file, name);
            if (paths.len == 1 and paths[0].segs.len >= 2) {
                const target_leaf = paths[0].segs[paths[0].segs.len - 1];
                if (!std.mem.eql(u8, target_leaf, name)) {
                    retry_leaf = target_leaf;
                    for (m.funcsBySimpleName(target_leaf)) |fid| {
                        const f = m.funcById(fid) orelse continue;
                        if (!f.hasBody()) continue;
                        if (!std.mem.eql(u8, f.fqn, paths[0].fqn)) continue;
                        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
                        const user = f.params.len - 1;
                        const exact = user == args.len;
                        const arity_ok = exact or (args.len < user and blk: {
                            for (f.params[1 + args.len ..]) |p| {
                                if (p.default == null and !p.is_vararg) break :blk false;
                            }
                            break :blk true;
                        }) or (args.len > user and f.params[f.params.len - 1].is_vararg);
                        if (!arity_ok) continue;
                        if (chosen == null or (exact and !chosen_exact)) {
                            chosen = fid;
                            chosen_exact = exact;
                        }
                    }
                }
            }
        }
        if (chosen) |fid| {
            const mg = self.module.borrow();
            const mod: *const Module = mg.get();
            mg.deinit();
            const call_args = try allocator.alloc(Value, args.len + 1);
            defer allocator.free(call_args);
            call_args[0] = receiver.*;
            @memcpy(call_args[1..], args);
            return host_call_func.callFunc(self, allocator, mod, fid, call_args);
        }
        if (retry_leaf) |leaf| {
            // No body-bearing overload under the aliased FQN: the target is
            // intrinsic-backed (`kotlin.text.uppercase`). Re-dispatch under
            // the target's real name. Self-recapture guard: a delegating
            // wrapper bearing that simple name must not rebind itself.
            const cur = ir.eval.currentFuncName() orelse "";
            if (!std.mem.eql(u8, cur, leaf)) {
                return callMemberRec(self, allocator, receiver, leaf, args);
            }
        }
    }

    // Dispatch-miss: the message carries `Vm::call_member `name` on `fqn``,
    // which downstream fallbacks pattern-match (e.g. the object-singleton walk)
    // to tell a top-level miss for *this* name from a deeper genuine error.
    // Discard sites free it via `freeDispatchMiss` (it is recognizable and
    // allocated here), so it does not leak per call.
    if (receiver.* == .Instance) {
        // A bare call to an inherited companion function (`orderedEquals`,
        // `checkElementIndex`) is folded into the class's member scope but is
        // not an instance member; resolve it on the class-hierarchy companion.
        if (try companionWithMember(self, allocator, receiver, name)) |comp| {
            if (!Value.referenceEq(&comp, receiver)) {
                return callMemberRec(self, allocator, &comp, name, args);
            }
        }
        // A nested-class constructor resolved onto a `*.Companion` instance:
        // an inline factory's `Outer.Nested(args)` where `Outer` resolved to
        // its companion. Construct the enclosing class's nested class.
        if (name.len > 0 and std.ascii.isUpper(name[0])) {
            const enc_fqn: ?[]const u8 = blk: {
                const ig = receiver.Instance.borrow();
                defer ig.deinit();
                const icg = ig.get().class.borrow();
                defer icg.deinit();
                const fqn = icg.get().fqn;
                // Default companion: fqn ends `.Companion`. A NAMED companion
                // (`companion object Factory`) instead has fqn
                // `Enclosing.<Name>` and its lifted class name carries the
                // `$Companion$` marker — strip the last fqn segment to the
                // enclosing class so `Outer.Nested(args)` still constructs the
                // nested class rather than missing as a companion member.
                if (std.mem.endsWith(u8, fqn, ".Companion"))
                    break :blk fqn[0 .. fqn.len - ".Companion".len];
                if (std.mem.indexOf(u8, icg.get().name, "$Companion$") != null) {
                    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| break :blk fqn[0..dot];
                }
                // An object singleton used as a nested-class qualifier
                // (`Object.Nested(args)`): the bare object name lowered to its
                // singleton value, so the enclosing class is the object's own.
                if (host_globals.progHasObjectName(self, icg.get().name)) break :blk fqn;
                break :blk null;
            };
            if (enc_fqn) |enc| {
                const nested_fqn = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ enc, name });
                defer if (runtime.freeScratch()) allocator.free(nested_fqn);
                const cid = blk: {
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    break :blk mg.get().classIdByFqn(nested_fqn);
                };
                if (cid) |c| return newInstanceById(self, allocator, c, args, null);
            }
        }
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        missTraceMaybe(name);
        return unimplemented(allocator, "Vm::call_member `{s}` on `{s}`", .{ name, cg.get().fqn });
    }
    // Last resort for a primitive number whose named arithmetic operator
    // member (`x.rem(y)`, `x.div(y)`, `x.unaryMinus()`) did not otherwise
    // resolve — upstream Compose calls `slot.rem(SLOTS_PER_INT)` directly.
    // Placed at the miss tail so it never preempts the stdlib operator
    // dispatch (which handles overflow, `mod` vs `rem`, bitwise, etc.).
    if (isNumericValue(receiver)) {
        if (args.len == 1) {
            if (numericOpMethod(name)) |op| {
                return ir.eval.applyBinop(allocator, op, receiver, &args[0]);
            }
        } else if (args.len == 0) {
            if (std.mem.eql(u8, name, "unaryMinus")) {
                const zero = Value.newInt(0);
                return ir.eval.applyBinop(allocator, .Sub, &zero, receiver);
            }
            if (std.mem.eql(u8, name, "unaryPlus")) return .{ .ok = receiver.* };
        }
    }

    missTraceMaybe(name);
    if (runtime.getenvSlice("KLIO_MISS_TRACE") != null) {
        std.debug.print("[member-miss] `{s}` on `{s}` span={any}\n", .{ name, receiver.typeFqn(), ir.eval.currentCallSiteSpan() });
        ir.eval.debugPrintFrames();
    }
    return unimplemented(allocator, "Vm::call_member `{s}` on `{s}`", .{ name, receiver.typeFqn() });
}

/// `KLIO_MISS_TRACE=<name>` diagnostic: when a call_member dispatch for
/// exactly `<name>` reaches the total-miss tail, print the live frame chain
/// (the miss may still be tolerated by an outer walk; each firing is one
/// candidate path that failed).
fn missTraceMaybe(name: []const u8) void {
    if (!missTraceWant(name)) return;
    std.debug.print("[miss] call_member `{s}` total miss\n", .{name});
    ir.eval.dumpFrameChainForDiagAlways();
}

fn missTraceWant(name: []const u8) bool {
    const want = runtime.getenvSlice("KLIO_MISS_TRACE") orelse return false;
    return std.mem.eql(u8, want, name);
}

/// Free an `Unimplemented` result's message iff it is the dispatch-miss message
/// allocated by `callMemberInnerStatic` (recognizable by its `Vm::call_member`
/// prefix). Safe to call at any discard site: a static `.Unimplemented`
/// literal does not match, so it is never freed. No-op under the arena.
fn freeDispatchMiss(allocator: Allocator, r: EvalResult) void {
    if (!runtime.freeScratch()) return;
    if (r == .err and r.err == .Unimplemented) {
        const m = r.err.Unimplemented;
        if (std.mem.startsWith(u8, m, "Vm::call_member")) allocator.free(m);
    }
}

// -------------------------------------------------------------------------
// callMember sub-handlers.
// -------------------------------------------------------------------------

fn delegateMember(self: *VmHost, allocator: Allocator, d: ObjRef(DelegateKind), name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    if (std.mem.eql(u8, name, "getValue")) {
        const state = blk: {
            const g = d.borrow();
            defer g.deinit();
            break :blk g.get().*;
        };
        switch (state) {
            .Lazy => |lz| {
                if (lz.cached) |c| return .{ .ok = c };
                const r = try callValueRec(self, allocator, &lz.producer, &.{});
                if (r == .ok) {
                    const g = d.borrowMut();
                    if (g.get().* == .Lazy) g.get().Lazy.cached = r.ok;
                    g.deinit();
                }
                return r;
            },
            .Observable => |ob| return .{ .ok = ob.value },
            .NotNull => |nn| {
                if (nn.value) |x| return .{ .ok = x };
                return .{ .err = try throwExc(allocator, "kotlin.IllegalStateException", "Property should be initialized before get.") };
            },
        }
    }
    if (std.mem.eql(u8, name, "setValue")) {
        if (args.len > 2) {
            const new_v = args[2];
            const g = d.borrowMut();
            switch (g.get().*) {
                .Lazy => g.get().Lazy.cached = new_v,
                .Observable => {
                    const old = g.get().Observable.value;
                    g.get().Observable.value = new_v;
                    const cb = g.get().Observable.on_change;
                    g.deinit();
                    if (cb != .Null) {
                        _ = try callValueRec(self, allocator, &cb, &.{ .Null, old, new_v });
                    }
                    return .{ .ok = .Unit };
                },
                .NotNull => g.get().NotNull.value = new_v,
            }
            g.deinit();
        }
        return .{ .ok = .Unit };
    }
    return null;
}

/// The declared parameter names of `name` on the receiver's class (or a
/// supertype), from the Kotlin declaration the pack ships. A pack-installed
/// host binding carries no parameter names of its own, so this is what a
/// named-argument call is matched against.
fn classMethodParamNames(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?[][]const u8 {
    if (receiver.* != .Instance) return null;
    var cname: []const u8 = "";
    var cfqn: []const u8 = "";
    {
        const ig = receiver.Instance.borrow();
        defer ig.deinit();
        const cg = ig.get().class.borrow();
        defer cg.deinit();
        cname = cg.get().name;
        cfqn = cg.get().fqn;
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const cid = mod.classIdByFqn(cfqn) orelse mod.classId(cname) orelse return null;
    if (cid.int() >= mod.classes.items.len) return null;
    const cls = &mod.classes.items[cid.int()];
    for (cls.methods) |fid| {
        const f = mod.funcById(fid) orelse continue;
        if (!std.mem.eql(u8, f.name, name) and !std.mem.eql(u8, simpleName(f.name), name)) continue;
        // A member's leading `this` parameter is the receiver, not an argument.
        const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const out = try allocator.alloc([]const u8, f.params.len - skip);
        for (f.params[skip..], out) |pd, *o| o.* = pd.name;
        return out;
    }
    return null;
}

/// A named-argument call into a pack-installed host binding. The binding takes
/// its arguments positionally, so the names are matched against the Kotlin
/// declaration's parameters and the call is re-issued in declaration order.
/// Without this the call fell through to the Kotlin body the pack ships, which
/// for atomicfu is a stub that the host binding is meant to shadow — so
/// `compareAndSet(expect = false, update = true)` always answered `false` while
/// `compareAndSet(false, true)` worked.
fn instanceBindingNamedProbe(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    args: []const Value,
    arg_names: []const ?[]const u8,
) Allocator.Error!?EvalResult {
    if (receiver.* != .Instance) return null;
    const params = (try classMethodParamNames(self, allocator, receiver, name)) orelse return null;
    defer if (runtime.freeScratch()) allocator.free(params);
    if (args.len > params.len) return null;

    const slots = try allocator.alloc(?Value, params.len);
    defer if (runtime.freeScratch()) allocator.free(slots);
    for (slots) |*s| s.* = null;
    var next_positional: usize = 0;
    for (args, 0..) |a, i| {
        const supplied: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        if (supplied) |an| {
            var placed = false;
            for (params, 0..) |pn, pos| {
                if (!std.mem.eql(u8, pn, an)) continue;
                if (slots[pos] != null) return null;
                slots[pos] = a;
                placed = true;
                break;
            }
            if (!placed) return null;
        } else {
            while (next_positional < slots.len and slots[next_positional] != null) next_positional += 1;
            if (next_positional >= slots.len) return null;
            slots[next_positional] = a;
            next_positional += 1;
        }
    }
    // Every parameter must be supplied: a host binding has no default thunks.
    var filled: std.ArrayList(Value) = .empty;
    defer filled.deinit(allocator);
    for (slots) |s| {
        const v = s orelse return null;
        try filled.append(allocator, v);
    }
    return instanceBindingProbe(self, allocator, receiver, name, filled.items);
}

fn instanceBindingProbe(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var cls_fqn: []const u8 = undefined;
    var cls_name: []const u8 = undefined;
    var is_anonymous = false;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        cls_fqn = cg.get().fqn;
        cls_name = cg.get().name;
        is_anonymous = cg.get().is_anonymous;
        cg.deinit();
        g.deinit();
    }

    // Inline cache: a prior resolution of this (class, name, arg-sig) returns
    // straight to its intrinsic (or to a cached "no intrinsic" miss) without
    // rebuilding the probe FQNs or walking the supertype chain. Only a
    // primitive-arg call is keyed (`instanceMethodKey`); anything else falls
    // through to the full probe below.
    const ib_key = instanceMethodKey(self, receiver, name, args);
    if (ib_key) |k| {
        if (instanceIntrinsicCacheGet(self, k)) |entry| {
            const func = entry.func orelse return null;
            const all_args = try prependReceiver(allocator, receiver, args);
            defer if (runtime.freeScratch()) allocator.free(all_args);
            return try dispatchIntrinsic(self, allocator, entry.fqn, func, all_args);
        }
    }

    var probes: std.ArrayList([]const u8) = .empty;
    // Probe FQNs are per-call scratch (all `allocPrint`ed below); free them and
    // the list. No-op under the arena; reclaims under a freeing allocator.
    defer {
        if (runtime.freeScratch()) for (probes.items) |p| allocator.free(p);
        probes.deinit(allocator);
    }
    try probes.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_fqn, name }));
    try probes.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_name, name }));
    // Walk supertype chain.
    {
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(allocator);
        var seen: std.StringHashMap(void) = .init(allocator);
        defer seen.deinit();
        try queue.append(allocator, cls_name);
        try queue.append(allocator, cls_fqn);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const cur = queue.items[head];
            if (seen.contains(cur)) continue;
            try seen.put(cur, {});
            const cg = self.classes.borrow();
            if (cg.get().get(cur)) |def| {
                const dg = def.borrow();
                for (dg.get().supertype_names) |sup| {
                    try probes.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sup, name }));
                    try queue.append(allocator, sup);
                }
                dg.deinit();
            }
            cg.deinit();
        }
    }
    for (probes.items) |p| {
        const installed = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            const bg = pg.get().installed_bindings.borrow();
            defer bg.deinit();
            break :blk bg.get().resolve(p);
        };
        if (installed) |func| {
            if (ib_key) |k| instanceIntrinsicCachePut(self, k, func, p);
            const all_args = try prependReceiver(allocator, receiver, args);
            defer if (runtime.freeScratch()) allocator.free(all_args);
            return try dispatchIntrinsic(self, allocator, p, func, all_args);
        }
    }

    // klio-stdlib intrinsics on an anonymous/synth class.
    if (is_anonymous) {
        const synth = [_][]const u8{
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_fqn, name }),
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_name, name }),
        };
        // The synthesized lookup keys are scratch; free them once probed (a
        // per-anon-method-call leak — the ktor pipeline calls anon-object
        // methods on every request).
        defer if (runtime.freeScratch()) {
            allocator.free(synth[0]);
            allocator.free(synth[1]);
        };
        for (synth) |p| {
            if (lookupIntrinsic(self, p)) |func| {
                const all_args = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(all_args);
                return try dispatchIntrinsic(self, allocator, p, func, all_args);
            }
        }
    }

    // Built-in Any/AutoCloseable extension probes, unless a real
    // user/source extension on the receiver type chain exists.
    const recv_chain = try receiverClassChain(self, allocator, inst);
    defer {
        var it = recv_chain.keyIterator();
        _ = &it;
        @constCast(&recv_chain).deinit();
    }
    const has_recv_ext = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        for (mod.funcsBySimpleName(name)) |fid| {
            if (mod.funcById(fid)) |f| {
                if (f.hasBody() and f.params.len > 0 and
                    std.mem.eql(u8, f.params[0].name, "this") and recv_chain.contains(f.params[0].ty.name))
                {
                    break :blk true;
                }
            }
        }
        break :blk false;
    };
    if (!has_recv_ext) {
        // Link-settled name → FQN map over the builtin kotlin.io /
        // AutoCloseable / Any member surfaces; replaces the per-call
        // probe loop with one deterministic edge per name.
        const mapped: ?[]const u8 = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().anyMemberGlobal(name);
        };
        if (mapped) |p| {
            if (lookupIntrinsic(self, p)) |func| {
                if (ib_key) |k| instanceIntrinsicCachePut(self, k, func, p);
                const all_args = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(all_args);
                return try dispatchIntrinsic(self, allocator, p, func, all_args);
            }
        }
    }
    // No intrinsic for this (class, name, arg-sig) through any probe stage:
    // cache the miss so the next call returns immediately.
    if (ib_key) |k| instanceIntrinsicCachePut(self, k, null, "");
    return null;
}

fn receiverClassChain(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData)) Allocator.Error!std.StringHashMap(void) {
    var seen: std.StringHashMap(void) = .init(allocator);
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        try stack.append(allocator, cg.get().name);
        try stack.append(allocator, cg.get().fqn);
        cg.deinit();
        g.deinit();
    }
    while (stack.pop()) |cn| {
        if (seen.contains(cn)) continue;
        try seen.put(cn, {});
        const cg = self.classes.borrow();
        if (cg.get().get(cn)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |s| try stack.append(allocator, s);
            dg.deinit();
        }
        cg.deinit();
    }
    return seen;
}

fn builtinIterator(self: *VmHost, allocator: Allocator, receiver: *const Value) Allocator.Error!?EvalResult {
    _ = self;
    // An array `.asList()` view re-reads its scalar source so the iterator
    // snapshot reflects later array writes.
    receiver.refreshArrayView();
    receiver.refreshSublistView();
    switch (receiver.*) {
        .List => |l| {
            if (stdlib.implementations.collections.sublistViewStale(receiver)) {
                return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
            }
            // A mutable list shares its backing so `MutableIterator.remove()`
            // mutates the source (and the iterating loop observes it); an
            // immutable list snapshots, as before. A live map `values` view is
            // also mutable (no read-only error; CME still fires on concurrent
            // map modification); only a genuinely read-only list snapshots.
            if (l.mutable and !stdlib.implementations.collections.modCountFrozen(l.mod_count)) {
                const cap = try captureModCount(allocator, l.mod_count);
                return .{ .ok = .{ .Iterator = .{ .items = l.items.clone(), .cursor = try newCursor(allocator, 0, cap.exp_mod), .prim = null, .mod_count = cap.mod_count, .mutable = true } } };
            }
            // A snapshot iterator (immutable list, or a live map `values` view):
            // still capture `mod_count` so a concurrent structural change to the
            // source (the map) fails the iterator fast.
            const items = try cloneItemsList(allocator, l.items);
            const cap = try captureModCount(allocator, l.mod_count);
            return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .cursor = try newCursor(allocator, 0, cap.exp_mod), .prim = null, .mod_count = cap.mod_count } } };
        },
        .Set => |s| {
            // A mutable set shares its backing so `MutableIterator.remove()`
            // mutates the source set (the `filterInPlace` removeAll/retainAll
            // path iterates + removes); an immutable set snapshots. A live map
            // `keys`/`entries` view is also mutable (its iterator supports
            // remove and reports CME on concurrent map modification); only a
            // genuinely read-only set yields a read-only iterator.
            if (s.mutable and !stdlib.implementations.collections.modCountFrozen(s.mod_count)) {
                const cap = try captureModCount(allocator, s.mod_count);
                return .{ .ok = .{ .Iterator = .{ .items = s.items.clone(), .cursor = try newCursor(allocator, 0, cap.exp_mod), .prim = null, .mod_count = cap.mod_count, .mutable = true } } };
            }
            // Snapshot iterator (immutable set, or a live map `keys`/`entries`
            // view): capture `mod_count` so a concurrent map mutation fails fast.
            const items = try cloneItemsList(allocator, s.items);
            const cap = try captureModCount(allocator, s.mod_count);
            return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .cursor = try newCursor(allocator, 0, cap.exp_mod), .prim = null, .mod_count = cap.mod_count } } };
        },
        .Map => |m| {
            const g = m.entries.borrow();
            const src_mc = g.get().mod_count;
            const live = m.mutable and !stdlib.implementations.collections.modCountFrozen(src_mc);
            const stamp: u64 = blk: {
                const cell = src_mc orelse break :blk 0;
                const cg = cell.borrow();
                defer cg.deinit();
                break :blk cg.get().*;
            };
            var items: std.ArrayList(Value) = .empty;
            for (g.get().pairs.items) |kv| {
                kv.key.retain();
                kv.value.retain();
                const k = try Value.boxRef(allocator, kv.key);
                const v = try Value.boxRef(allocator, kv.value);
                // A mutable map's iterator yields live entries: `setValue`
                // writes through, and `MutableIterator.remove` deletes from the
                // backing via this reference (the `items` list is a snapshot).
                try items.append(allocator, .{ .MapEntry = .{ .key = k, .value = v, .backing = if (live) m.entries else null, .exp_mod = stamp } });
            }
            g.deinit();
            const cap = try captureModCount(allocator, src_mc);
            return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .cursor = try newCursor(allocator, 0, cap.exp_mod), .prim = null, .mod_count = cap.mod_count, .mutable = live } } };
        },
        .Range => |r| {
            return .{ .ok = .{ .RangeIter = .{ .cur = try ObjRef(i64).init(allocator, r.start), .end = r.end, .step = r.step, .kind = r.kind, .done = try ObjRef(bool).init(allocator, false) } } };
        },
        .Array => |arr| {
            const items = try cloneArrayItems(allocator, arr);
            return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .cursor = try newCursor(allocator, 0, 0), .prim = arr.prim } } };
        },
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            var items: std.ArrayList(Value) = .empty;
            const view = std.unicode.Utf8View.init(g.get().bytes) catch {
                for (g.get().bytes) |b| try items.append(allocator, .{ .Char = b });
                return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .cursor = try newCursor(allocator, 0, 0), .prim = null } } };
            };
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp <= 0xFFFF) {
                    try items.append(allocator, .{ .Char = @intCast(cp) });
                } else {
                    const v2 = cp - 0x10000;
                    try items.append(allocator, .{ .Char = @intCast(0xD800 + (v2 >> 10)) });
                    try items.append(allocator, .{ .Char = @intCast(0xDC00 + (v2 & 0x3FF)) });
                }
            }
            return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .cursor = try newCursor(allocator, 0, 0), .prim = null } } };
        },
        else => return null,
    }
}

fn isBuiltinScalar(v: *const Value) bool {
    return switch (v.*) {
        .String, .Int, .Long, .Short, .Byte, .Double, .Float, .Bool, .Char => true,
        .UInt, .ULong, .UShort, .UByte => true,
        else => false,
    };
}

fn eqIgnoreCase(allocator: Allocator, a: StringRef, b: StringRef) bool {
    const ag = a.borrow();
    defer ag.deinit();
    const bg = b.borrow();
    defer bg.deinit();
    const la = std.ascii.allocLowerString(allocator, ag.get().bytes) catch return false;
    defer if (runtime.freeScratch()) allocator.free(la);
    const lb = std.ascii.allocLowerString(allocator, bg.get().bytes) catch return false;
    defer if (runtime.freeScratch()) allocator.free(lb);
    return std.mem.eql(u8, la, lb);
}

fn isCallableOrIntrinsic(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure, .Function, .Intrinsic => true,
        else => false,
    };
}

fn extWithThisLongerThanArgs(self: *VmHost, name: []const u8, argc: usize) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        if (mod.funcById(fid)) |f| {
            // Only true EXTENSIONS gate the SAM arm. An interface's own
            // method also leads with `this` (`ShouldPauseCallback.
            // shouldPause()`), but for a CALLABLE receiver that method IS
            // the SAM dispatch — invoking the callable is the reading
            // kotlinc takes, exactly like `FlowCollector.emit` on a
            // collector that arrived as a plain lambda.
            if (f.kind != .top_level_extension and f.kind != .member_extension) continue;
            if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this") and f.params.len > argc) return true;
        }
    }
    return false;
}

fn lookupGlobalValue(self: *VmHost, name: []const u8) ?Value {
    const g = self.globals.borrow();
    defer g.deinit();
    return g.get().lookup(name);
}

fn sequenceMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const seq = receiver.Sequence;
    // `Sequence.iterator()` is lazy: a `SeqIter` pulls one element at a time so
    // an infinite source never materialises (`sequence{}` / `generateSequence`).
    if (std.mem.eql(u8, name, "iterator") and args.len == 0) {
        // A `sequence{}`/`iterator{}` builder Sequence is re-iterable: each
        // `iterator()` drives a fresh coroutine cursor (clone), leaving the
        // embedded template untouched so a second consumption is not empty.
        {
            var intrinsic = makeIntrinsicHost(self);
            defer deinitIntrinsicHost(&intrinsic);
            const ihost = intrinsic.intrinsicHost();
            if (try stdlib.freshBuilderSeq(ihost, allocator, receiver.*)) |fresh| {
                return .{ .ok = try stdlib.makeSeqIter(allocator, fresh) };
            }
        }
        if (stdlib.oneShotConsumeCheck(allocator, receiver.*) catch null) |re| {
            return .{ .err = try mapRuntimeError(allocator, re) };
        }
        var sv = receiver.*;
        if (runtime.reclaimEnabled()) sv.retain();
        return .{ .ok = try stdlib.makeSeqIter(allocator, sv) };
    }
    // `zip` with a Sequence argument is lazy: a `Merged` source pulls both
    // children alternately (left, then right, one element per output pair),
    // so shared-state builders observe `MergingSequence`'s interleave
    // instead of two full materialisations back to back.
    if (std.mem.eql(u8, name, "zip") and (args.len == 1 or args.len == 2) and args[0] == .Sequence) {
        var left = receiver.*;
        var right = args[0];
        if (runtime.reclaimEnabled()) {
            left.retain();
            right.retain();
        }
        const transform: ?runtime.ValueBox = if (args.len == 2) blk: {
            var t = args[1];
            if (runtime.reclaimEnabled()) t.retain();
            break :blk try Value.boxRef(allocator, t);
        } else null;
        return .{ .ok = .{ .Sequence = try ObjRef(SequenceData).init(allocator, .{
            .source = .{ .Merged = .{
                .left = try Value.boxRef(allocator, left),
                .right = try Value.boxRef(allocator, right),
                .transform = transform,
            } },
            .ops = &.{},
        }) } };
    }
    const terminal = isSequenceTerminal(name);
    if (terminal) {
        const m = try materialiseSequence(self, allocator, receiver);
        const items = switch (m) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
        const as_list = try listOf(allocator, items, false);
        var margs = try allocator.alloc(Value, args.len);
        for (args, 0..) |a, i| {
            if (a == .Sequence) {
                const ms = try materialiseSequence(self, allocator, &a);
                switch (ms) {
                    .ok => |it| margs[i] = try listOf(allocator, it, false),
                    .err => |e| return .{ .err = e },
                }
            } else margs[i] = a;
        }
        return try callMemberRec(self, allocator, &as_list, name, margs);
    }
    // Pipeline ops.
    const new_op: ?SeqOp = blk: {
        if (std.mem.eql(u8, name, "map") and args.len == 1) break :blk .{ .Map = args[0] };
        if (std.mem.eql(u8, name, "onEach") and args.len == 1) break :blk .{ .OnEach = args[0] };
        if (std.mem.eql(u8, name, "mapIndexed") and args.len == 1) break :blk .{ .MapIndexed = args[0] };
        if (std.mem.eql(u8, name, "filterIndexed") and args.len == 1) break :blk .{ .FilterIndexed = args[0] };
        if (std.mem.eql(u8, name, "filter") and args.len == 1) break :blk .{ .Filter = args[0] };
        if (std.mem.eql(u8, name, "filterNot") and args.len == 1) break :blk .{ .FilterNot = args[0] };
        if (std.mem.eql(u8, name, "take") and args.len == 1) {
            if (args[0].asI64()) |n| {
                if (n < 0) {
                    const msg = try std.fmt.allocPrint(allocator, "Requested element count {d} is less than zero.", .{n});
                    return .{ .err = try throwExc(allocator, "kotlin.IllegalArgumentException", msg) };
                }
                break :blk .{ .Take = n };
            }
        }
        if (std.mem.eql(u8, name, "drop") and args.len == 1) {
            if (args[0].asI64()) |n| {
                if (n < 0) {
                    const msg = try std.fmt.allocPrint(allocator, "Requested element count {d} is less than zero.", .{n});
                    return .{ .err = try throwExc(allocator, "kotlin.IllegalArgumentException", msg) };
                }
                break :blk .{ .Drop = n };
            }
        }
        if (std.mem.eql(u8, name, "takeWhile") and args.len == 1) break :blk .{ .TakeWhile = args[0] };
        if (std.mem.eql(u8, name, "dropWhile") and args.len == 1) break :blk .{ .DropWhile = args[0] };
        if (std.mem.eql(u8, name, "flatMap") and args.len == 1) break :blk .{ .FlatMap = args[0] };
        if (std.mem.eql(u8, name, "distinct") and args.len == 0) break :blk .Distinct;
        if (std.mem.eql(u8, name, "distinctBy") and args.len == 1) break :blk .{ .DistinctBy = args[0] };
        if (std.mem.eql(u8, name, "sorted") and args.len == 0) break :blk .{ .Sorted = false };
        if (std.mem.eql(u8, name, "sortedDescending") and args.len == 0) break :blk .{ .Sorted = true };
        if (std.mem.eql(u8, name, "sortedBy") and args.len == 1) break :blk .{ .SortedBy = .{ .selector = args[0], .descending = false } };
        if (std.mem.eql(u8, name, "sortedByDescending") and args.len == 1) break :blk .{ .SortedBy = .{ .selector = args[0], .descending = true } };
        if (std.mem.eql(u8, name, "sortedWith") and args.len == 1) break :blk .{ .SortedWith = args[0] };
        break :blk null;
    };
    if (new_op) |op| {
        const g = seq.borrow();
        const src = g.get().source;
        const old_ops = g.get().ops;
        var ops = try allocator.alloc(SeqOp, old_ops.len + 1);
        @memcpy(ops[0..old_ops.len], old_ops);
        ops[old_ops.len] = op;
        g.deinit();
        return .{ .ok = .{ .Sequence = try ObjRef(SequenceData).init(allocator, .{ .source = src, .ops = ops }) } };
    }
    return null;
}

fn isSequenceTerminal(name: []const u8) bool {
    const terms = [_][]const u8{
        "toList",    "toMutableList", "toSet",        "count",        "sum",         "average",
        "sumOf",     "last",          "lastOrNull",   "forEach",      "fold",        "reduce",
        "iterator",  "max",           "maxOrNull",    "min",          "minOrNull",   "maxBy",
        "minBy",     "maxByOrNull",   "minByOrNull",  "maxOf",        "minOf",       "joinToString",
        "all",       "contains",      "groupBy",      "associate",    "associateBy", "associateWith",
        "partition", "indexOf",       "indexOfFirst", "toMap",        "toHashSet",   "toMutableSet",
        "zip",       "unzip",         "plus",         "reduceOrNull", "foldRight",   "reduceRight",
    };
    for (terms) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

/// Whether some user extension function named `name` declares a receiver
/// (`this` param) whose simple type name matches one of `targets`.
fn extensionTargetsAny(self: *VmHost, name: []const u8, targets: []const []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        const recv_simple = simpleName(f.params[0].ty.name);
        for (targets) |t| {
            if (std.mem.eql(u8, simpleName(t), recv_simple)) return true;
        }
    }
    return false;
}

fn classCompanionAndEnum(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const cls = receiver.Class;
    var cls_name: []const u8 = undefined;
    var cls_fqn: []const u8 = undefined;
    var is_enum = false;
    {
        const cg = cls.borrow();
        cls_name = cg.get().name;
        cls_fqn = cg.get().fqn;
        is_enum = cg.get().is_enum;
        cg.deinit();
    }
    // Probe-class set (name, fqn, supertype parents via runtime def).
    var probe_classes: std.ArrayList([]const u8) = .empty;
    defer probe_classes.deinit(allocator);
    try probe_classes.append(allocator, cls_name);
    if (cls_fqn.len != 0 and !std.mem.eql(u8, cls_fqn, cls_name)) try probe_classes.append(allocator, cls_fqn);
    {
        const cg = self.classes.borrow();
        if (cg.get().get(cls_name)) |def| {
            var cur = blk: {
                const dg = def.borrow();
                const p = dg.get().parent;
                dg.deinit();
                break :blk if (p) |pp| pp.clone() else null;
            };
            while (cur) |p| {
                const pg = p.borrow();
                try probe_classes.append(allocator, pg.get().name);
                if (pg.get().fqn.len != 0 and !std.mem.eql(u8, pg.get().fqn, pg.get().name)) try probe_classes.append(allocator, pg.get().fqn);
                const next = pg.get().parent;
                pg.deinit();
                p.deinit();
                cur = if (next) |n| n.clone() else null;
            }
        }
        cg.deinit();
    }
    // Companion-extension receiver: `fun LocalDate.Companion.Format(...)` called
    // as `LocalDate.Format { }`. Its declared receiver is `<Class>.Companion`,
    // so add that probe name; `extensionTargetsAny` then matches it (by the
    // "Companion" simple name), the companion singleton is constructed, and the
    // extension dispatches on it. A false match against another class's
    // companion extension simply misses on this companion and falls through.
    var comp_probe_buf: [160]u8 = undefined;
    const comp_probe = std.fmt.bufPrint(&comp_probe_buf, "{s}.Companion", .{cls_name}) catch cls_name;
    try probe_classes.append(allocator, comp_probe);
    var comp_name: ?[]const u8 = null;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const comp = &mg.get().registry.companion_singletons;
        for (probe_classes.items) |k| {
            if (comp.get(k)) |c| {
                comp_name = c;
                break;
            }
            if (comp.get(simpleName(k))) |c| {
                comp_name = c;
                break;
            }
        }
    }
    if (comp_name) |cn| {
        // First access through a companion member constructs the
        // companion (once, thread-safe); a miss probe for a non-member
        // (an enum entry, a nested class) leaves it uninitialized.
        var singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
            .ok => |maybe| maybe,
            .err => |e| return .{ .err = e },
        };
        // A user extension whose declared receiver is the class (or an
        // ancestor) also dispatches through the companion value:
        // `Json.encodeToString(x)` binds `fun Json.encodeToString(...)`
        // with the companion (`Json.Default`, an instance of `Json`) as
        // its receiver, so construct the companion for it too.
        if (singleton == null and extensionTargetsAny(self, name, probe_classes.items)) {
            singleton = switch (try host_globals.ensureObjectSingleton(self, cn)) {
                .ok => |maybe| maybe,
                .err => |e| return .{ .err = e },
            };
        }
        if (singleton) |s| {
            if (s == .Instance) {
                const no_such = try std.fmt.allocPrint(allocator, "`{s}` on", .{name});
                defer if (runtime.freeScratch()) allocator.free(no_such);
                const r = try callMemberRec(self, allocator, &s, name, args);
                switch (r) {
                    .ok => return r,
                    .err => |e| switch (e) {
                        .Unimplemented => |m| {
                            if (!(std.mem.indexOf(u8, m, "Vm::call_member") != null and std.mem.indexOf(u8, m, no_such) != null)) return r;
                            // Top-level miss for `name` on the singleton: fall
                            // through to other dispatch; the miss message is
                            // discarded here, so free it.
                            freeDispatchMiss(allocator, r);
                        },
                        else => return r,
                    },
                }
            }
        }
    }
    // Enum.values()
    if (is_enum and std.mem.eql(u8, name, "values") and args.len == 0) {
        const cg = cls.borrow();
        var items: std.ArrayList(Value) = .empty;
        for (cg.get().enum_entries) |e| {
            e.value.retain();
            try items.append(allocator, e.value);
        }
        cg.deinit();
        return .{ .ok = .{ .List = .{
            .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
            .mutable = false,
            .enum_entries = true,
            .backing = null,
        } } };
    }
    // Enum.valueOf("X")
    if (is_enum and std.mem.eql(u8, name, "valueOf") and args.len == 1 and args[0] == .String) {
        const cg = cls.borrow();
        const sg = args[0].String.borrow();
        const want = sg.get().bytes;
        for (cg.get().enum_entries) |e| {
            if (std.mem.eql(u8, e.name, want)) {
                const v = e.value;
                // host-returns-owned: the singleton is owned by the ClassDef.
                v.retain();
                sg.deinit();
                cg.deinit();
                return .{ .ok = v };
            }
        }
        const msg = try std.fmt.allocPrint(allocator, "No enum constant {s}.{s}", .{ cg.get().fqn, want });
        defer if (runtime.freeScratch()) allocator.free(msg);
        sg.deinit();
        cg.deinit();
        return .{ .err = try throwExc(allocator, "kotlin.IllegalArgumentException", msg) };
    }
    return null;
}

fn samInstanceDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    const target = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().get("__sam_target__");
    };
    if (target) |t| {
        var cls_name: []const u8 = undefined;
        {
            const g = inst.borrow();
            const cg = g.get().class.borrow();
            cls_name = cg.get().name;
            cg.deinit();
            g.deinit();
        }
        const dispatch_lambda = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            if (mg.get().registry.hierarchy_methods.get(cls_name)) |methods| {
                if (methods.count() != 0) break :blk methods.contains(name);
            }
            break :blk true;
        };
        if (dispatch_lambda) {
            // A fun interface whose single abstract method is a MEMBER
            // EXTENSION (`fun interface MeasurePolicy { fun
            // MeasureScope.measure(...) }`): kotlinc scopes the SAM lambda's
            // body with the extension receiver as `this`, so a bare
            // `layout(...)` inside `MeasurePolicy { ... }` resolves against
            // the MeasureScope. Bind the innermost enclosing receiver that
            // implements the declared extension-receiver type.
            if (samMemberExtRecvType(self, cls_name, name)) |recv_ty| {
                const entries = try ir.eval.enclosingEntriesAlloc(allocator);
                defer allocator.free(entries);
                for (entries) |e| {
                    if (e.v != .Instance) continue;
                    if (receiverImplementsType(self, &e.v, recv_ty)) {
                        return try host_call_value.callValueWithThis(self, allocator, &t, &e.v, args, &.{});
                    }
                }
            }
            return try callValueRec(self, allocator, &t, args);
        }
    }
    return null;
}

/// Dispatch `receiver.name(args)` through an enclosing anonymous-object
/// instance whose class declares a member-extension method of this name
/// accepting the receiver: the anon-site method runs with the receiver
/// bound as its extension `this` and the anon instance as the enclosing
/// dispatch receiver.
fn enclosingAnonMemberExtDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ name, args.len });
    defer allocator.free(arity_name);
    for (entries) |e| {
        if (e.v != .Instance) continue;
        var cls_name: []const u8 = undefined;
        {
            const g = e.v.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            cls_name = cg.get().name;
            cg.deinit();
        }
        const hit = lookupAnonMethod(self, allocator, cls_name, arity_name, name) orelse continue;
        // Only a member-EXTENSION method serves this arm; its lowered form
        // binds the extension receiver as `this` (params[0]) with the
        // declared receiver type.
        const hg = hit.module.borrow();
        const hf = funcAt(hg.get(), hit.func);
        const is_member_ext = hf != null and hf.?.kind == .member_extension and
            hf.?.params.len != 0 and std.mem.eql(u8, hf.?.params[0].name, "this");
        const recv_ty: []const u8 = if (is_member_ext) hf.?.params[0].ty.name else "";
        hg.deinit();
        if (!is_member_ext) continue;
        if (!receiverImplementsType(self, receiver, recv_ty)) continue;
        ir.eval.pushEnclosing(&e.v);
        defer ir.eval.popEnclosing();
        return try invokeAnonMethod(self, allocator, receiver, hit, args, null);
    }
    return null;
}

threadlocal var sam_ext_memo_name: ?[]const u8 = null;
threadlocal var sam_ext_memo_ty: ?[]const u8 = null;

/// The extension-receiver type of `name` when some `fun interface` declares it as
/// its abstract member-EXTENSION method, else null. `fun interface MeasurePolicy`
/// declares `fun MeasureScope.measure(measurables, constraints)`, so `measure`
/// answers `MeasureScope`.
fn samAbstractExtRecvType(self: *VmHost, name: []const u8) ?[]const u8 {
    if (sam_ext_memo_name) |n| {
        if (std.mem.eql(u8, n, name)) return sam_ext_memo_ty;
    }
    var found: ?[]const u8 = null;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        var it = mg.get().registry.iface_member_ext_recv.iterator();
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.key_ptr.b, name)) continue;
            // Only a FUN interface can be served by a lambda. An ordinary
            // interface's abstract member extension (`Density.toPx`) never is, and
            // matching one would hand the call to whatever same-arity lambda happens
            // to sit on the receiver tower -- every no-arg `toPx()` would find some
            // `() -> Unit` content lambda.
            if (!classIsFunInterface(self, e.key_ptr.a)) continue;
            found = e.value_ptr.*;
            break;
        }
    }
    sam_ext_memo_name = name;
    sam_ext_memo_ty = found;
    return found;
}

/// Dispatch `name(args)` where the dispatch receiver is a LAMBDA that was SAM-converted
/// to a fun interface whose abstract method is a member extension.
///
/// `with(measurePolicy) { measure(measurables, constraints) }` is the shape: when the
/// policy came from `Layout(modifier, content) { measurables, constraints -> … }` the
/// receiver is the lambda itself, and the lambda IS the method body. Without this arm
/// the callable had no member of that name, and the walk fell through to a
/// same-named member extension on an unrelated class -- every SAM-lambda layout ran
/// `BasicText`'s private `EmptyMeasurePolicy`, which sizes to the incoming
/// constraints, so a text field measured itself to the unbounded scroll height.
///
/// The extension receiver comes off the enclosing tower: the innermost `this` that
/// implements the interface method's declared receiver type (the coordinator, a
/// `MeasureScope`).
fn samMemberExtOnCallable(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const recv_ty = samAbstractExtRecvType(self, name) orelse return null;
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    for (entries) |e| {
        if (!receiverImplementsType(self, &e.v, recv_ty)) continue;
        var this_v = e.v;
        return try host_call_value.callValueWithThis(self, allocator, receiver, &this_v, args, &.{});
    }
    return null;
}

/// Dispatch `receiver.name(args)` through an enclosing SAM instance whose
/// fun interface declares `name` as an abstract member extension accepting
/// this receiver: the stored lambda runs with the receiver bound as `this`.
fn enclosingSamMemberExtDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    for (entries) |e| {
        if (e.v != .Instance) continue;
        var cls_name: []const u8 = undefined;
        var target: ?Value = null;
        {
            const g = e.v.Instance.borrow();
            defer g.deinit();
            target = g.get().get("__sam_target__");
            if (target == null) continue;
            const cg = g.get().class.borrow();
            cls_name = cg.get().name;
            cg.deinit();
        }
        const recv_ty = samMemberExtRecvType(self, cls_name, name) orelse continue;
        if (!receiverImplementsType(self, receiver, recv_ty)) continue;
        return try host_call_value.callValueWithThis(self, allocator, &target.?, receiver, args, &.{});
    }
    return null;
}

/// Dispatch `receiver.name(args)` through a LAMBDA on the enclosing receiver tower
/// that stands in for a fun interface whose abstract member extension is `name`.
///
/// `with(measurePolicy) { measure(measurables, constraints) }`: the policy came from
/// `Layout(modifier, content) { measurables, constraints -> … }` and is still a raw
/// closure, so it carries no `__sam_target__` for the SAM-instance arm to find. The
/// closure IS the method body, and the call's receiver (a `MeasureScope`) is the
/// extension receiver the abstract slot declares.
///
/// Without this the walk fell through to the by-name extension fallback, which
/// answered with a same-named member extension on an unrelated class -- every
/// SAM-lambda layout ran `BasicText`'s `EmptyMeasurePolicy`, sizing itself to the
/// incoming constraints.
fn enclosingSamLambdaDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const recv_ty = samAbstractExtRecvType(self, name) orelse return null;
    if (!receiverImplementsType(self, receiver, recv_ty)) return null;
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    for (entries) |e| {
        const arity: usize = switch (e.v) {
            .IrClosure => |c| blk: {
                const info = self.closures.get(@intCast(c.id)) orelse continue;
                break :blk info.n_params;
            },
            else => continue,
        };
        if (arity != args.len) continue;
        var callee = e.v;
        return try host_call_value.callValueWithThis(self, allocator, &callee, receiver, args, &.{});
    }
    return null;
}

/// The declared extension-receiver type head of `cls`'s abstract member
/// extension named `name`, when the class (a fun interface serving a SAM
/// conversion) declares one — null otherwise.
fn samMemberExtRecvType(self: *VmHost, cls: []const u8, name: []const u8) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    return mg.get().registry.iface_member_ext_recv.get(.{ .a = cls, .b = name });
}

fn boundRefDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var rc: ?Value = null;
    var n_str: ?[]const u8 = null;
    {
        const g = inst.borrow();
        rc = g.get().get("__bound_receiver__");
        if (g.get().get("__bound_name__")) |nv| {
            if (nv == .String) {
                const sg = nv.String.borrow();
                n_str = sg.get().bytes;
                sg.deinit();
            }
        }
        g.deinit();
    }
    if (rc == null or n_str == null) return null;
    const recv_capt = rc.?;
    const n = n_str.?;
    if (std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "simpleName")) {
        return null; // handled by get_field
    }
    // Dispatch under the reference's creation-site file (private
    // visibility is decided where the reference was written).
    var ref_pushed = false;
    var ref_prev: ?ir.eval.RefSiteOverride = null;
    if (boundRefFile(receiver)) |bf| {
        ref_prev = ir.eval.pushRefSiteFile(bf);
        ref_pushed = true;
    }
    defer if (ref_pushed) ir.eval.popRefSiteFile(ref_prev);
    // Property-delegation protocol on a bound property reference
    // (`var x by data::prop` / `by Data::prop`): read/write the
    // referenced property. A Class-bound ref takes the instance from
    // the delegation call's thisRef argument.
    if (std.mem.eql(u8, name, "getValue") and args.len >= 2) {
        const target: *const Value = if (recv_capt == .Class) &args[0] else &recv_capt;
        var r = try getFieldRec(self, allocator, target, n);
        if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
        return r;
    }
    if (std.mem.eql(u8, name, "setValue") and args.len >= 3) {
        const target: *const Value = if (recv_capt == .Class) &args[0] else &recv_capt;
        return switch (try host_fields.setField(self, allocator, target, n, args[2])) {
            .ok => .{ .ok = .Unit },
            .err => |e| .{ .err = e },
        };
    }
    // `ref.set(v)` on a bound mutable property reference.
    if (std.mem.eql(u8, name, "set") and recv_capt != .Class and args.len == 1) {
        return switch (try host_fields.setField(self, allocator, &recv_capt, n, args[0])) {
            .ok => .{ .ok = .Unit },
            .err => |e| .{ .err = e },
        };
    }
    if (std.mem.eql(u8, name, "set") and recv_capt == .Class and args.len == 2) {
        return switch (try host_fields.setField(self, allocator, &args[0], n, args[1])) {
            .ok => .{ .ok = .Unit },
            .err => |e| .{ .err = e },
        };
    }
    if (recv_capt == .Class) {
        if ((std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "call") or std.mem.eql(u8, name, "invoke")) and args.len != 0) {
            const first = args[0];
            const rest = args[1..];
            if (rest.len == 0 and memberIsProperty(self, &first, n)) {
                // getFieldRec returns the field borrowed; this escapes as a
                // callMember return whose register takes ownership, so retain.
                var r = try getFieldRec(self, allocator, &first, n);
                if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
                return r;
            }
            return try callMemberRec(self, allocator, &first, n, rest);
        }
        return null;
    }
    if ((std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "call") or std.mem.eql(u8, name, "invoke")) and
        args.len == 0 and memberIsProperty(self, &recv_capt, n))
    {
        var r = try getFieldRec(self, allocator, &recv_capt, n);
        if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
        return r;
    }
    // A bound EXTENSION-property reference (`local::extVal`): the name is
    // not a member of the receiver's class, but `get()` still reads the
    // property — the field path resolves extension getters and delegated
    // extension properties. Only a clean read wins; a miss falls through
    // to the bound-method forward below.
    if (std.mem.eql(u8, name, "get") and args.len == 0) {
        var r = try getFieldRec(self, allocator, &recv_capt, n);
        if (r == .ok) {
            if (runtime.reclaimEnabled()) r.ok.retain();
            return r;
        }
    }
    // Bound method reference: forward the call.
    const r = try callMemberRec(self, allocator, &recv_capt, n, args);
    if ((std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "call")) and r == .err and r.err == .Unimplemented) {
        // The receiver's class declares no such member: the reference
        // names a top-level function (a `::fn` lowered as a member ref
        // before the function's header was registered). Resolve it
        // through the full global probe chain — the raw env holds no
        // top-level functions.
        if (host_globals.lookupGlobal(self, n)) |callable| {
            switch (callable) {
                .Function, .IrClosure => return try callValueRec(self, allocator, &callable, args),
                else => {},
            }
        }
    }
    return r;
}

fn kclassMembers(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    _ = self;
    const cg = receiver.Class.borrow();
    defer cg.deinit();
    const a_name = cg.get().name;
    if (std.mem.eql(u8, name, "equals") and args.len == 1) {
        const eq = if (args[0] == .Class) blk: {
            const bg = args[0].Class.borrow();
            defer bg.deinit();
            break :blk std.mem.eql(u8, a_name, bg.get().name);
        } else false;
        return .{ .ok = boolVal(eq) };
    }
    if (std.mem.eql(u8, name, "hashCode") and args.len == 0) {
        var h = std.hash.Wyhash.init(0);
        h.update(a_name);
        return .{ .ok = Value.newInt(@bitCast(h.final())) };
    }
    if (std.mem.eql(u8, name, "toString") and args.len == 0) {
        const s = try std.fmt.allocPrint(allocator, "class {s}", .{a_name});
        return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
    }
    return null;
}

fn kfunctionReflection(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const info = self.closures.get(@intCast(receiver.IrClosure.id)) orelse return null;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = info.module orelse mg.get();
    const f = mod.funcById(info.body_func) orelse return null;
    if (std.mem.eql(u8, name, "name")) {
        return .{ .ok = .{ .String = try runtime.strInit(allocator, f.name) } };
    }
    if (std.mem.eql(u8, name, "parameters")) {
        var items: std.ArrayList(Value) = .empty;
        for (f.params) |p| try items.append(allocator, .{ .String = try runtime.strInit(allocator, p.name) });
        return .{ .ok = try listOf(allocator, items, false) };
    }
    return null;
}

fn propertyRefDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const pg = receiver.PropertyRef.name.borrow();
    const pname = pg.get().bytes;
    pg.deinit();
    if (std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "call")) {
        const has_fn = self.module.borrow().get().hasFuncNamed(pname);
        const callable = lookupGlobalValue(self, pname);
        const is_callable_global = callable != null and switch (callable.?) {
            .Function, .IrClosure => true,
            else => false,
        };
        if ((has_fn or is_callable_global) and callable != null) {
            return try callValueRec(self, allocator, &callable.?, args);
        }
    }
    // Unbound `KProperty0` / `KMutableProperty0`: `get()` (and the
    // `() -> V` `invoke()`/`call()` forms) read the referenced top-level
    // property, and `set(v)` writes it. The reference carries only the
    // property name, so resolve the value the same way a bare read does —
    // a stored `val`/`var` from globals (driving a deferred initializer on
    // demand), otherwise a custom `get()` accessor's 0-arg getter func.
    if ((std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "call") or std.mem.eql(u8, name, "invoke")) and args.len == 0) {
        if (try topLevelPropertyGet(self, allocator, pname)) |r| return r;
    }
    if (std.mem.eql(u8, name, "set") and args.len == 1) {
        const r = try self.storeGlobal(allocator, pname, args[0]);
        return switch (r) {
            .ok => .{ .ok = Value.Unit },
            .err => |e| .{ .err = e },
        };
    }
    if ((std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "call") or std.mem.eql(u8, name, "invoke")) and args.len == 1) {
        return try getFieldRec(self, allocator, &args[0], pname);
    }
    // Property-delegation protocol on an unbound reference
    // (`var x by ::topVar`, `val y by ::intVar` in a class body): a
    // member of the delegation thisRef wins, else the top-level slot.
    if (std.mem.eql(u8, name, "getValue") and args.len >= 2) {
        if (args[0] == .Instance and memberIsProperty(self, &args[0], pname)) {
            var r = try getFieldRec(self, allocator, &args[0], pname);
            if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
            return r;
        }
        if (try topLevelPropertyGet(self, allocator, pname)) |r| return r;
        if (args[0] != .Null) {
            var r = try getFieldRec(self, allocator, &args[0], pname);
            if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
            return r;
        }
    }
    if (std.mem.eql(u8, name, "setValue") and args.len >= 3) {
        if (args[0] == .Instance and memberIsProperty(self, &args[0], pname)) {
            return switch (try host_fields.setField(self, allocator, &args[0], pname, args[2])) {
                .ok => .{ .ok = .Unit },
                .err => |e| .{ .err = e },
            };
        }
        return switch (try self.storeGlobal(allocator, pname, args[2])) {
            .ok => .{ .ok = Value.Unit },
            .err => |e| .{ .err = e },
        };
    }
    if (std.mem.eql(u8, name, "hashCode") and args.len == 0) {
        return .{ .ok = Value.newInt(@as(i64, valueStructuralHash(receiver))) };
    }
    if (std.mem.eql(u8, name, "equals") and args.len == 1) {
        return .{ .ok = boolVal(Value.structuralEq(receiver, &args[0])) };
    }
    if (std.mem.eql(u8, name, "toString") and args.len == 0) {
        const s = try std.fmt.allocPrint(allocator, "property {s}", .{pname});
        return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
    }
    return null;
}

/// Read the top-level property `pname` for an unbound property reference's
/// `get()`. Mirrors the `LoadGlobal` resolution: a stored `val`/`var` comes
/// from globals (driving a deferred initializer and resolving delegates),
/// and a property declared with only a custom `get()` re-runs its 0-arg
/// getter func on each read. Returns `null` when `pname` names no top-level
/// property, leaving the remaining dispatch branches to handle it.
fn topLevelPropertyGet(self: *VmHost, allocator: Allocator, pname: []const u8) Allocator.Error!?EvalResult {
    switch (try self.lookupGlobalThrowing(allocator, pname)) {
        .ok => |maybe| if (maybe) |v| {
            v.retain();
            return .{ .ok = v };
        },
        .err => |e| return .{ .err = e },
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    if (mod.registry.top_level_prop_getters.get(pname)) |fid| {
        return try self.callFunc(allocator, mod, fid, &.{});
    }
    return null;
}

fn sortedInstances(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    var snap = try cloneItemsList(allocator, receiver.List.items);
    defer snap.deinit(allocator);
    var has_inst = false;
    for (snap.items) |v| {
        if (v == .Instance) has_inst = true;
    }
    if (!has_inst) return null;
    var sorted: std.ArrayList(Value) = .empty;
    try sorted.appendSlice(allocator, snap.items);
    const descending = std.mem.eql(u8, name, "sortedDescending");
    var i: usize = 1;
    while (i < sorted.items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const a = sorted.items[j - 1];
            const b = sorted.items[j];
            const cmp_r = try callMemberRec(self, allocator, &a, "compareTo", &.{b});
            const ncmp: i64 = switch (cmp_r) {
                .ok => |v| v.asI64() orelse 0,
                .err => |e| {
                    sorted.deinit(allocator);
                    return .{ .err = e };
                },
            };
            const greater = if (descending) ncmp < 0 else ncmp > 0;
            if (greater) {
                std.mem.swap(Value, &sorted.items[j - 1], &sorted.items[j]);
                j -= 1;
            } else break;
        }
    }
    return .{ .ok = try listOf(allocator, sorted, false) };
}

const Ordering = enum { lt, eq, gt };

fn flipOrd(o: Ordering) Ordering {
    return switch (o) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

fn ordToInt(o: Ordering) i64 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// Natural-order compare falling back to the user `compareTo` when the
/// pair is not builtin-comparable (Uuid, user Comparable classes).
fn compareValuesHostAware(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) Allocator.Error!union(enum) { ord: Ordering, err: EvalError } {
    if (compareValuesBuiltin(a, b)) |o| return .{ .ord = o };
    const r = try callMemberRec(self, allocator, a, "compareTo", &.{b.*});
    switch (r) {
        .ok => |v| {
            const i = v.asI64() orelse return .{ .err = try typeErr(allocator, "incomparable values", .{}) };
            return .{ .ord = if (i < 0) .lt else if (i > 0) .gt else .eq };
        },
        .err => |e| return .{ .err = e },
    }
}

/// Builtin natural-order comparison. `null` when the pair is not
/// builtin-comparable (mirrors `compare_values` rejecting Instances).
fn compareValuesBuiltin(a: *const Value, b: *const Value) ?Ordering {
    // Kotlin `compareValues`: null is ordered first (null < non-null, null ==
    // null). A `compareBy { selectorReturningNull }` relies on this.
    if (a.* == .Null or b.* == .Null) {
        if (a.* == .Null and b.* == .Null) return .eq;
        return if (a.* == .Null) .lt else .gt;
    }
    if (a.* == .String and b.* == .String) {
        const ag = a.String.borrow();
        defer ag.deinit();
        const bg = b.String.borrow();
        defer bg.deinit();
        return switch (std.mem.order(u8, ag.get().bytes, bg.get().bytes)) {
            .lt => .lt,
            .eq => .eq,
            .gt => .gt,
        };
    }
    if (a.* == .Bool and b.* == .Bool) {
        const x: u8 = @intFromBool(a.Bool);
        const y: u8 = @intFromBool(b.Bool);
        return if (x < y) .lt else if (x > y) .gt else .eq;
    }
    if (a.isFloating() or b.isFloating()) {
        const x = floatOf(a) orelse return null;
        const y = floatOf(b) orelse return null;
        return kotlinFloatTotalCmp(x, y);
    }
    const x = a.asI64() orelse (if (a.* == .Char) @as(i64, a.Char) else return null);
    const y = b.asI64() orelse (if (b.* == .Char) @as(i64, b.Char) else return null);
    return if (x < y) .lt else if (x > y) .gt else .eq;
}

/// Total order over IEEE-754 doubles matching Kotlin's `Double.compareTo`:
/// `-0.0 < 0.0` and every `NaN` sorts above `+Infinity`.
fn kotlinFloatTotalCmp(a: f64, b: f64) Ordering {
    if (a < b) return .lt;
    if (a > b) return .gt;
    const bits = struct {
        fn of(x: f64) i64 {
            if (std.math.isNan(x)) return @bitCast(@as(u64, 0x7ff8_0000_0000_0000));
            return @bitCast(x);
        }
    };
    return switch (std.math.order(bits.of(a), bits.of(b))) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

fn floatOf(v: *const Value) ?f64 {
    return switch (v.*) {
        .Double => |d| d,
        .Float => |f| @as(f64, f),
        else => if (v.asI64()) |i| @as(f64, @floatFromInt(i)) else null,
    };
}

fn comparatorMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const cmp = receiver.Comparator;
    // `Comparator` is a `fun interface`, so `comparator(a, b)` and an explicit
    // `comparator.invoke(a, b)` both call `compare`.
    if ((std.mem.eql(u8, name, "compare") or std.mem.eql(u8, name, "invoke")) and args.len == 2) {
        const a = args[0];
        const b = args[1];
        var ord: Ordering = .eq;
        const sg = cmp.steps.borrow();
        const steps = sg.get().*;
        const descending = cmp.descending;
        sg.deinit();
        if (steps.len == 0) {
            ord = switch (try compareValuesHostAware(self, allocator, &a, &b)) {
                .ord => |o| o,
                .err => |e| return .{ .err = e },
            };
        } else {
            for (steps) |step| {
                const sel = step.selector;
                const n_params: usize = switch (sel) {
                    .IrClosure => |c| blk: {
                        if (self.closures.get(@intCast(c.id))) |info| break :blk info.n_params;
                        break :blk 1;
                    },
                    else => 1,
                };
                const o: Ordering = if (n_params >= 2) blk: {
                    const r = try callValueRec(self, allocator, &sel, &.{ a, b });
                    const nval: i64 = switch (r) {
                        .ok => |v| v.asI64() orelse 0,
                        .err => |e| return .{ .err = e },
                    };
                    break :blk if (nval < 0) .lt else if (nval > 0) .gt else .eq;
                } else blk: {
                    const ka_r = try callValueRec(self, allocator, &sel, &.{a});
                    const ka = switch (ka_r) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    const kb_r = try callValueRec(self, allocator, &sel, &.{b});
                    const kb = switch (kb_r) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    // `compareBy(comparator, selector)`: order the selected keys
                    // by the step's comparator rather than their natural order.
                    if (step.key_comparator) |kc| {
                        const r = try callMemberRec(self, allocator, &kc, "compare", &.{ ka, kb });
                        const nval: i64 = switch (r) {
                            .ok => |v| v.asI64() orelse 0,
                            .err => |e| return .{ .err = e },
                        };
                        break :blk if (nval < 0) .lt else if (nval > 0) .gt else .eq;
                    }
                    break :blk switch (try compareValuesHostAware(self, allocator, &ka, &kb)) {
                        .ord => |o| o,
                        .err => |e| return .{ .err = e },
                    };
                };
                const flipped = if (step.descending) flipOrd(o) else o;
                if (flipped != .eq) {
                    ord = flipped;
                    break;
                }
            }
        }
        if (descending) ord = flipOrd(ord);
        return .{ .ok = Value.newInt(ordToInt(ord)) };
    }
    if ((std.mem.eql(u8, name, "thenBy") or std.mem.eql(u8, name, "thenByDescending")) and args.len == 1) {
        const sg = cmp.steps.borrow();
        var chain = try allocator.alloc(ComparatorStep, sg.get().len + 1);
        @memcpy(chain[0..sg.get().len], sg.get().*);
        chain[sg.get().len] = .{ .selector = args[0], .descending = std.mem.eql(u8, name, "thenByDescending") };
        sg.deinit();
        return .{ .ok = .{ .Comparator = .{ .steps = try ObjRef([]ComparatorStep).init(allocator, chain), .descending = cmp.descending } } };
    }
    if ((std.mem.eql(u8, name, "then") or std.mem.eql(u8, name, "thenComparing") or
        std.mem.eql(u8, name, "thenDescending") or std.mem.eql(u8, name, "thenComparator")) and args.len == 1)
    {
        const invert = std.mem.eql(u8, name, "thenDescending");
        switch (args[0]) {
            .Comparator => |other| {
                const sg = cmp.steps.borrow();
                const og = other.steps.borrow();
                var chain = try allocator.alloc(ComparatorStep, sg.get().len + og.get().len);
                @memcpy(chain[0..sg.get().len], sg.get().*);
                for (og.get().*, 0..) |st, i| {
                    chain[sg.get().len + i] = .{ .selector = st.selector, .descending = (st.descending != other.descending) != invert };
                }
                og.deinit();
                sg.deinit();
                return .{ .ok = .{ .Comparator = .{ .steps = try ObjRef([]ComparatorStep).init(allocator, chain), .descending = cmp.descending } } };
            },
            .IrClosure => {
                const sg = cmp.steps.borrow();
                var chain = try allocator.alloc(ComparatorStep, sg.get().len + 1);
                @memcpy(chain[0..sg.get().len], sg.get().*);
                chain[sg.get().len] = .{ .selector = args[0], .descending = invert };
                sg.deinit();
                return .{ .ok = .{ .Comparator = .{ .steps = try ObjRef([]ComparatorStep).init(allocator, chain), .descending = cmp.descending } } };
            },
            else => {},
        }
    }
    if (std.mem.eql(u8, name, "reversed") and args.len == 0) {
        return .{ .ok = .{ .Comparator = .{ .steps = cmp.steps.clone(), .descending = !cmp.descending } } };
    }
    return null;
}

fn arrayShapeOps(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    _ = self;
    const arr = receiver.Array;
    if (std.mem.eql(u8, name, "toList") and args.len == 0) {
        const items = try cloneArrayItems(allocator, arr);
        return .{ .ok = try listOf(allocator, items, false) };
    }
    if (std.mem.eql(u8, name, "toMutableList") and args.len == 0) {
        const items = try cloneArrayItems(allocator, arr);
        return .{ .ok = try listOf(allocator, items, true) };
    }
    if (std.mem.eql(u8, name, "asList") and args.len == 0) {
        // Read-only, fixed-size live view over the array (element writes show
        // through); not a copy.
        return .{ .ok = try stdlib.implementations.collections.arrayAsListView(allocator, arr) };
    }
    if (std.mem.eql(u8, name, "toTypedArray") and args.len == 0) {
        const items = try cloneArrayItems(allocator, arr);
        return .{ .ok = runtime.ArrayData.fromBoxedList(try ObjRef(std.ArrayList(Value)).init(allocator, items)) };
    }
    if (std.mem.eql(u8, name, "toSet") and args.len == 0) {
        const items = try cloneArrayItems(allocator, arr);
        return .{ .ok = .{ .Set = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .mutable = false, .backing = null } } };
    }
    if (std.mem.eql(u8, name, "concatToString") and (args.len == 0 or args.len == 2)) {
        const chars = try arr.snapshot(allocator);
        defer if (runtime.freeScratch()) allocator.free(chars);
        var start: usize = 0;
        var end: usize = chars.len;
        if (args.len == 2) {
            const si = args[0].asI64() orelse 0;
            const ei = args[1].asI64() orelse @as(i64, @intCast(chars.len));
            const size: i64 = @intCast(chars.len);
            // `CharArray.concatToString(startIndex, endIndex)` validates via
            // `checkBoundsIndexes`: out-of-range bounds throw
            // IndexOutOfBoundsException, an inverted range throws
            // IllegalArgumentException.
            if (si < 0 or ei > size) {
                const msg = try std.fmt.allocPrint(allocator, "startIndex: {d}, endIndex: {d}, size: {d}", .{ si, ei, size });
                return .{ .err = try throwExc(allocator, "kotlin.IndexOutOfBoundsException", msg) };
            }
            if (si > ei) {
                const msg = try std.fmt.allocPrint(allocator, "startIndex: {d} > endIndex: {d}", .{ si, ei });
                return .{ .err = try throwExc(allocator, "kotlin.IllegalArgumentException", msg) };
            }
            start = @intCast(si);
            end = @intCast(ei);
        }
        var units: std.ArrayList(u16) = .empty;
        defer units.deinit(allocator);
        var i = start;
        while (i < @max(end, start)) : (i += 1) {
            if (chars[i] == .Char) try units.append(allocator, chars[i].Char);
        }
        const s = try runtime.charUnitsToString(allocator, units.items);
        return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
    }
    return null;
}

fn collectionMutators(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    // `+= elements` / `-= elements` over a multi-element collection argument
    // flattens (addAll / removeAll); a single element add/removes that one
    // element. Delegate the collection case so dedup / element semantics stay
    // in one place.
    const arg_is_multi = args.len == 1 and switch (args[0]) {
        .List, .Set, .Range, .Sequence, .Array => true,
        else => false,
    };
    switch (receiver.*) {
        .List => |l| {
            if (!l.mutable) return null;
            if (std.mem.eql(u8, name, "plusAssign") and args.len == 1) {
                if (arg_is_multi) return try self.callMember(allocator, receiver, "addAll", args);
                const g = l.items.borrowMut();
                defer g.deinit();
                try g.get().append(allocator, args[0]);
                return .{ .ok = .Unit };
            }
            if (std.mem.eql(u8, name, "minusAssign") and args.len == 1) {
                if (arg_is_multi) return try self.callMember(allocator, receiver, "removeAll", args);
                const g = l.items.borrowMut();
                defer g.deinit();
                for (g.get().items, 0..) |x, idx| {
                    if (Value.structuralEq(&x, &args[0])) {
                        _ = g.get().orderedRemove(idx);
                        break;
                    }
                }
                return .{ .ok = .Unit };
            }
        },
        .Set => |s| {
            if (!s.mutable) return null;
            if (std.mem.eql(u8, name, "plusAssign") and args.len == 1) {
                if (arg_is_multi) return try self.callMember(allocator, receiver, "addAll", args);
                const g = s.items.borrowMut();
                defer g.deinit();
                var present = false;
                for (g.get().items) |x| {
                    if (Value.structuralEq(&x, &args[0])) present = true;
                }
                if (!present) try g.get().append(allocator, args[0]);
                return .{ .ok = .Unit };
            }
            if (std.mem.eql(u8, name, "minusAssign") and args.len == 1) {
                if (arg_is_multi) return try self.callMember(allocator, receiver, "removeAll", args);
                const g = s.items.borrowMut();
                defer g.deinit();
                for (g.get().items, 0..) |x, idx| {
                    if (Value.structuralEq(&x, &args[0])) {
                        _ = g.get().orderedRemove(idx);
                        break;
                    }
                }
                return .{ .ok = .Unit };
            }
        },
        .Map => |m| {
            if (!m.mutable) return null;
            if (std.mem.eql(u8, name, "plusAssign") and args.len == 1) {
                var to_put: std.ArrayList(MapPair) = .empty;
                defer to_put.deinit(allocator);
                const a2 = args[0];
                switch (a2) {
                    .Pair => |p| {
                        const k = p.first.asPtr().*;
                        const v = p.second.asPtr().*;
                        k.retain();
                        v.retain();
                        try to_put.append(allocator, .{ .key = k, .value = v });
                    },
                    .Map => |other| {
                        const og = other.entries.borrow();
                        defer og.deinit();
                        // Entries are borrowed from `other`; the destination map
                        // owns its own ref per key+value, so retain each.
                        for (og.get().pairs.items) |kv| {
                            if (runtime.reclaimEnabled()) {
                                kv.key.retain();
                                kv.value.retain();
                            }
                            try to_put.append(allocator, kv);
                        }
                    },
                    .List => |lst| try collectPairs(allocator, &to_put, lst.items),
                    .Set => |st| try collectPairs(allocator, &to_put, st.items),
                    .Array => |arr| if (arr.boxedList()) |bl| try collectPairs(allocator, &to_put, bl),
                    .Sequence => {
                        const ms = try materialiseSequence(self, allocator, &a2);
                        var items = switch (ms) {
                            .ok => |it| it,
                            .err => |e| return .{ .err = e },
                        };
                        defer items.deinit(allocator);
                        for (items.items) |v| {
                            if (v == .Pair) {
                                const k = v.Pair.first.asPtr().*;
                                const val = v.Pair.second.asPtr().*;
                                k.retain();
                                val.retain();
                                try to_put.append(allocator, .{ .key = k, .value = val });
                            }
                        }
                    },
                    else => {},
                }
                const g = m.entries.borrowMut();
                defer g.deinit();
                for (to_put.items) |kv| {
                    var found = false;
                    for (g.get().pairs.items) |*slot| {
                        if (Value.structuralEq(&slot.key, &kv.key)) {
                            // Overwrite: release the displaced value and the
                            // staged (now-orphaned) key; transfer the staged value.
                            if (runtime.reclaimEnabled()) {
                                slot.value.release(allocator);
                                kv.key.release(allocator);
                            }
                            slot.value = kv.value;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try g.get().pairs.append(allocator, kv);
                        try g.get().noteAppended(allocator, g.get().pairs.items.len - 1);
                    }
                }
                return .{ .ok = .Unit };
            }
        },
        else => {},
    }
    return null;
}

fn collectPairs(allocator: Allocator, out: *std.ArrayList(MapPair), items: runtime.ValueList) Allocator.Error!void {
    const g = items.borrow();
    defer g.deinit();
    for (g.get().items) |v| {
        if (v == .Pair) {
            const k = v.Pair.first.asPtr().*;
            const val = v.Pair.second.asPtr().*;
            k.retain();
            val.retain();
            try out.append(allocator, .{ .key = k, .value = val });
        }
    }
}

/// Element-wise equality for builtin Lists whose elements include user
/// INSTANCES (a `windowed` tail yields the raw `RingBuffer`, a List on
/// the JVM). Pure structural equality cannot dispatch the element's
/// `equals`; this walks pairs, dispatching through the member walk when
/// either side is an Instance. Returns null when neither operand needs
/// host dispatch (caller falls back to the pure compare).
pub fn collectionsEqualHostAware(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) ?bool {
    if (a.* != .List or b.* != .List) return null;
    const needs_host = blk: {
        inline for ([_]*const Value{ a, b }) |v| {
            const g = v.List.items.borrow();
            defer g.deinit();
            for (g.get().items) |e| {
                if (e == .Instance) break :blk true;
            }
        }
        break :blk false;
    };
    if (!needs_host) return null;
    const ga = a.List.items.borrow();
    defer ga.deinit();
    const gb = b.List.items.borrow();
    defer gb.deinit();
    const ia = ga.get().items;
    const ib = gb.get().items;
    if (ia.len != ib.len) return false;
    for (ia, ib) |ea, eb| {
        if (ea == .Instance or eb == .Instance) {
            const recv = if (ea == .Instance) &ea else &eb;
            const arg = if (ea == .Instance) eb else ea;
            const r = callMemberRec(self, allocator, recv, "equals", &.{arg}) catch return false;
            switch (r) {
                .ok => |v| {
                    if (!(v == .Bool and v.Bool)) return false;
                },
                .err => return false,
            }
            continue;
        }
        if (ea == .List or eb == .List) {
            if (collectionsEqualHostAware(self, allocator, &ea, &eb)) |eq| {
                if (!eq) return false;
                continue;
            }
        }
        if (!Value.structuralEqBoxed(&ea, &eb)) return false;
    }
    return true;
}

fn componentMembers(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    switch (receiver.*) {
        .Pair => |p| {
            if (std.mem.eql(u8, name, "component1") or std.mem.eql(u8, name, "first")) return extractOwned(p.first);
            if (std.mem.eql(u8, name, "component2") or std.mem.eql(u8, name, "second")) return extractOwned(p.second);
            if (std.mem.eql(u8, name, "equals") and args.len == 1) return .{ .ok = boolVal(Value.structuralEq(receiver, &args[0])) };
            if (std.mem.eql(u8, name, "hashCode") and args.len == 0) return .{ .ok = .{ .Int = kotlinHashCode(receiver) } };
        },
        .Triple => |t| {
            if (std.mem.eql(u8, name, "component1") or std.mem.eql(u8, name, "first")) return extractOwned(t.first);
            if (std.mem.eql(u8, name, "component2") or std.mem.eql(u8, name, "second")) return extractOwned(t.second);
            if (std.mem.eql(u8, name, "component3") or std.mem.eql(u8, name, "third")) return extractOwned(t.third);
            if (std.mem.eql(u8, name, "equals") and args.len == 1) return .{ .ok = boolVal(Value.structuralEq(receiver, &args[0])) };
            if (std.mem.eql(u8, name, "hashCode") and args.len == 0) return .{ .ok = .{ .Int = kotlinHashCode(receiver) } };
        },
        .MapEntry => |me| {
            // A live entry (backing set) is a view: after a structural map
            // change every member access throws CME; before that, reads
            // resolve the live pair so non-structural value updates show
            // through (JVM HashMap.Node semantics for reads, common-code
            // fail-fast semantics for structural changes).
            if (me.backing) |entries| {
                const g = entries.borrow();
                var stale = false;
                if (g.get().mod_count) |cell| {
                    const cg = cell.borrow();
                    stale = cg.get().* != me.exp_mod;
                    cg.deinit();
                }
                if (stale) {
                    g.deinit();
                    return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
                }
                for (g.get().pairs.items) |*slot| {
                    if (Value.structuralEq(&slot.key, me.key.asPtr())) {
                        const live = slot.value;
                        if (!Value.structuralEq(me.value.asPtr(), &live)) {
                            if (runtime.reclaimEnabled()) {
                                live.retain();
                                me.value.asPtr().release(allocator);
                            }
                            me.value.asPtr().* = live;
                        }
                        break;
                    }
                }
                g.deinit();
            }
            if (std.mem.eql(u8, name, "component1") or std.mem.eql(u8, name, "key")) return extractOwned(me.key);
            if (std.mem.eql(u8, name, "component2") or std.mem.eql(u8, name, "value")) return extractOwned(me.value);
            // `Map.Entry` equality contract: compare by key and value, so a
            // builtin entry equals a user `Map.Entry` instance with the same
            // key/value (`structuralEqBoxed` applies the contract).
            if (std.mem.eql(u8, name, "equals") and args.len == 1) return .{ .ok = boolVal(Value.structuralEqBoxed(receiver, &args[0])) };
            if (std.mem.eql(u8, name, "hashCode") and args.len == 0) return .{ .ok = .{ .Int = kotlinHashCode(receiver) } };
            if (std.mem.eql(u8, name, "setValue")) {
                // No backing = a read-only map's entry: mutation throws
                // instead of silently succeeding on the snapshot.
                if (me.backing == null) {
                    return .{ .err = try throwExc(allocator, "kotlin.UnsupportedOperationException", null) };
                }
                const new_v = if (args.len > 0) args[0] else Value.Unit;
                const prev = me.value.asPtr().*;
                // host-returns-owned: the old value escapes as the result.
                if (runtime.reclaimEnabled()) prev.retain();
                if (me.backing) |entries| {
                    const g = entries.borrowMut();
                    defer g.deinit();
                    for (g.get().pairs.items) |*slot| {
                        if (Value.structuralEq(&slot.key, me.key.asPtr())) {
                            // The slot owns its value: release the old, retain the new.
                            if (runtime.reclaimEnabled()) {
                                new_v.retain();
                                slot.value.release(allocator);
                            }
                            slot.value = new_v;
                            break;
                        }
                    }
                }
                return .{ .ok = prev };
            }
        },
        .Instance => {
            if (std.mem.eql(u8, name, "component1") and
                (receiverImplementsType(self, receiver, "Entry") or receiverImplementsType(self, receiver, "MutableEntry")))
            {
                // getFieldRec returns the field borrowed; this result escapes
                // through callMember, so retain (host-returns-owned).
                var r = try getFieldRec(self, allocator, receiver, "key");
                if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
                return r;
            }
            if (std.mem.eql(u8, name, "component2") and
                (receiverImplementsType(self, receiver, "Entry") or receiverImplementsType(self, receiver, "MutableEntry")))
            {
                var r = try getFieldRec(self, allocator, receiver, "value");
                if (r == .ok and runtime.reclaimEnabled()) r.ok.retain();
                return r;
            }
        },
        else => {},
    }
    return null;
}

/// Current structural counter of a map's entries store (0 when uncounted).
fn mapEntriesCounter(entries: runtime.MapEntries) u64 {
    const g = entries.borrow();
    defer g.deinit();
    const cell = g.get().mod_count orelse return 0;
    const cg = cell.borrow();
    defer cg.deinit();
    return cg.get().*;
}

const ModCapture = struct { mod_count: ?ObjRef(u64), exp_mod: u64 };

/// Capture a list's `mod_count` (shared) plus its current value (the iterator's
/// expectation), so the iterator can fail-fast. `mod_count` is null for a
/// read-only / un-counted source, which makes the expectation meaningless.
fn captureModCount(allocator: Allocator, src: ?ObjRef(u64)) Allocator.Error!ModCapture {
    _ = allocator;
    const mc = src orelse return .{ .mod_count = null, .exp_mod = 0 };
    const cur = blk: {
        const g = mc.borrow();
        defer g.deinit();
        break :blk g.get().*;
    };
    return .{ .mod_count = mc.clone(), .exp_mod = cur };
}

/// A fresh cursor box for an iterator starting at `start`.
fn newCursor(allocator: Allocator, start: usize, exp_mod: u64) Allocator.Error!ObjRef(runtime.IterCursor) {
    return ObjRef(runtime.IterCursor).init(allocator, .{ .pos = start, .last_ret = -1, .exp_mod = exp_mod });
}

/// `ConcurrentModificationException` when the source mutated structurally since
/// the iterator captured it (`null` when consistent or uncounted).
fn iteratorCheckMod(allocator: Allocator, it: anytype) Allocator.Error!?EvalResult {
    const mc = it.mod_count orelse return null;
    const cur = blk: {
        const g = mc.borrow();
        defer g.deinit();
        break :blk g.get().*;
    };
    const exp = blk: {
        const g = it.cursor.borrow();
        defer g.deinit();
        break :blk g.get().exp_mod;
    };
    if (cur != exp) return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
    return null;
}

/// After the iterator's OWN structural mutation, resync its expectation so the
/// next `next`/`hasNext` does not flag its own change as concurrent.
fn iteratorResyncMod(it: anytype) void {
    const mc = it.mod_count orelse return;
    const cur = blk: {
        const g = mc.borrow();
        defer g.deinit();
        break :blk g.get().*;
    };
    const g = it.cursor.borrowMut();
    defer g.deinit();
    g.get().exp_mod = cur;
}

/// The iterator's own `add`/`remove` is a structural change of the backing list
/// (it mutates `items` directly, bypassing the list intrinsics): bump the shared
/// `mod_count` so OTHER iterators fail-fast, then resync this one's expectation.
fn iteratorOwnStructuralMod(it: anytype) void {
    if (it.mod_count) |mc| {
        const g = mc.borrowMut();
        g.get().* +%= 1;
        g.deinit();
    }
    iteratorResyncMod(it);
}

fn iteratorSetLast(it: anytype, idx: i64) void {
    const g = it.cursor.borrowMut();
    defer g.deinit();
    g.get().last_ret = idx;
}

/// Index the last `next()`/`previous()` returned, or -1 when none.
fn iteratorLastRet(it: anytype) i64 {
    const g = it.cursor.borrow();
    defer g.deinit();
    return g.get().last_ret;
}

fn iteratorMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    _ = self;
    const it = receiver.Iterator;
    if (std.mem.eql(u8, name, "hasNext") and args.len == 0) {
        const pg = it.cursor.borrow();
        const p = pg.get().pos;
        pg.deinit();
        const ig = it.items.borrow();
        const len = ig.get().items.len;
        ig.deinit();
        return .{ .ok = boolVal(p < len) };
    }
    if (isIteratorNext(name) and args.len == 0) {
        if (try iteratorCheckMod(allocator, it)) |e| return e;
        const pg = it.cursor.borrow();
        const p = pg.get().pos;
        pg.deinit();
        const ig = it.items.borrow();
        if (p >= ig.get().items.len) {
            ig.deinit();
            return .{ .err = try throwExc(allocator, "kotlin.NoSuchElementException", "iterator exhausted") };
        }
        var v = ig.get().items[p];
        // A live map entry is re-stamped at yield time, so entries handed
        // out after an iterator-driven structural change stay readable while
        // earlier ones fail fast.
        if (v == .MapEntry) {
            if (v.MapEntry.backing) |entries| {
                v.MapEntry.exp_mod = mapEntriesCounter(entries);
            }
        }
        // Borrowed element: the backing list still owns it, so retain before
        // handing it to the register that will own the iteration result.
        if (runtime.reclaimEnabled()) v.retain();
        ig.deinit();
        const pmg = it.cursor.borrowMut();
        pmg.get().pos = p + 1;
        pmg.deinit();
        iteratorSetLast(it, @intCast(p));
        return .{ .ok = v };
    }
    // `ListIterator` navigation over the same `items`/`pos` cursor.
    if (std.mem.eql(u8, name, "hasPrevious") and args.len == 0) {
        const pg = it.cursor.borrow();
        defer pg.deinit();
        return .{ .ok = boolVal(pg.get().pos > 0) };
    }
    if (std.mem.eql(u8, name, "nextIndex") and args.len == 0) {
        const pg = it.cursor.borrow();
        defer pg.deinit();
        return .{ .ok = Value.newInt(@intCast(pg.get().pos)) };
    }
    if (std.mem.eql(u8, name, "previousIndex") and args.len == 0) {
        const pg = it.cursor.borrow();
        defer pg.deinit();
        return .{ .ok = Value.newInt(@as(i64, @intCast(pg.get().pos)) - 1) };
    }
    if (std.mem.eql(u8, name, "previous") and args.len == 0) {
        if (try iteratorCheckMod(allocator, it)) |e| return e;
        const pg = it.cursor.borrow();
        const p = pg.get().pos;
        pg.deinit();
        if (p == 0) {
            return .{ .err = try throwExc(allocator, "kotlin.NoSuchElementException", "iterator at start") };
        }
        const ig = it.items.borrow();
        const v = ig.get().items[p - 1];
        if (runtime.reclaimEnabled()) v.retain();
        ig.deinit();
        const pmg = it.cursor.borrowMut();
        pmg.get().pos = p - 1;
        pmg.deinit();
        iteratorSetLast(it, @as(i64, @intCast(p)) - 1);
        return .{ .ok = v };
    }
    // `MutableListIterator.set(x)` — overwrite the element last returned.
    if (std.mem.eql(u8, name, "set") and args.len == 1) {
        // Check concurrent modification before the read-only guard: a
        // mutable collection's view iterator modified during iteration must
        // report CME, while a genuinely immutable iterator (whose mod count
        // never advances) still falls through to UnsupportedOperationException.
        if (try iteratorCheckMod(allocator, it)) |e| return e;
        if (!it.mutable) return .{ .err = try throwExc(allocator, "kotlin.UnsupportedOperationException", null) };
        const li = iteratorLastRet(it);
        if (li < 0) {
            return .{ .err = try throwExc(allocator, "kotlin.IllegalStateException", "set() called before next()/previous()") };
        }
        const lu: usize = @intCast(li);
        const g = it.items.borrowMut();
        defer g.deinit();
        if (lu < g.get().items.len) {
            if (runtime.reclaimEnabled()) g.get().items[lu].release(allocator);
            var nv = args[0];
            if (runtime.reclaimEnabled()) nv.retain();
            g.get().items[lu] = nv;
        }
        return .{ .ok = .Unit };
    }
    // `MutableListIterator.add(x)` — insert before the element a subsequent
    // `next()` would return (at the cursor) and advance the cursor past it,
    // so the inserted element is skipped by the following `next()`.
    if (std.mem.eql(u8, name, "add") and args.len == 1) {
        // Check concurrent modification before the read-only guard: a
        // mutable collection's view iterator modified during iteration must
        // report CME, while a genuinely immutable iterator (whose mod count
        // never advances) still falls through to UnsupportedOperationException.
        if (try iteratorCheckMod(allocator, it)) |e| return e;
        if (!it.mutable) return .{ .err = try throwExc(allocator, "kotlin.UnsupportedOperationException", null) };
        const pg = it.cursor.borrow();
        const p = pg.get().pos;
        pg.deinit();
        const g = it.items.borrowMut();
        defer g.deinit();
        var nv = args[0];
        if (runtime.reclaimEnabled()) nv.retain();
        const idx = if (p <= g.get().items.len) p else g.get().items.len;
        try g.get().insert(allocator, idx, nv);
        const pmg = it.cursor.borrowMut();
        pmg.get().pos = p + 1;
        pmg.deinit();
        iteratorSetLast(it, -1);
        iteratorOwnStructuralMod(it);
        return .{ .ok = .Unit };
    }
    // `MutableIterator.remove()` — drop the element last returned by `next()`
    // (at `pos - 1`) from the backing list and rewind the cursor so the
    // following `next()` resumes correctly. A no-op before the first `next()`.
    if (std.mem.eql(u8, name, "remove") and args.len == 0) {
        // Check concurrent modification before the read-only guard: a
        // mutable collection's view iterator modified during iteration must
        // report CME, while a genuinely immutable iterator (whose mod count
        // never advances) still falls through to UnsupportedOperationException.
        if (try iteratorCheckMod(allocator, it)) |e| return e;
        if (!it.mutable) return .{ .err = try throwExc(allocator, "kotlin.UnsupportedOperationException", null) };
        const pg = it.cursor.borrow();
        const p = pg.get().pos;
        pg.deinit();
        const li = iteratorLastRet(it);
        if (li < 0) {
            return .{ .err = try throwExc(allocator, "kotlin.IllegalStateException", "remove() called before next()") };
        }
        const lu: usize = @intCast(li);
        const g = it.items.borrowMut();
        defer g.deinit();
        if (lu < g.get().items.len) {
            const removed = g.get().items[lu];
            // A map iterator's element is a live MapEntry over a snapshot list;
            // also delete the entry from the backing map (by key).
            if (removed == .MapEntry) {
                if (removed.MapEntry.backing) |entries| {
                    const eg = entries.borrowMut();
                    defer eg.deinit();
                    const key = removed.MapEntry.key.asPtr();
                    for (eg.get().pairs.items, 0..) |*slot, i| {
                        if (Value.structuralEq(&slot.key, key)) {
                            if (runtime.reclaimEnabled()) {
                                slot.key.release(allocator);
                                slot.value.release(allocator);
                            }
                            _ = eg.get().pairs.orderedRemove(i);
                            break;
                        }
                    }
                }
            }
            _ = g.get().orderedRemove(lu);
            // The cursor slides back only when the removed slot was
            // BEFORE it (remove-after-next); after previous() the cursor
            // already sits at the removed index.
            if (lu < p) {
                const pmg = it.cursor.borrowMut();
                pmg.get().pos = p - 1;
                pmg.deinit();
            }
            iteratorSetLast(it, -1);
            iteratorOwnStructuralMod(it);
        }
        return .{ .ok = .Unit };
    }
    return null;
}

fn isIteratorNext(name: []const u8) bool {
    const ns = [_][]const u8{ "next", "nextInt", "nextLong", "nextChar", "nextByte", "nextShort", "nextDouble", "nextFloat", "nextBoolean" };
    for (ns) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn rangeIterMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    _ = self;
    const ri = receiver.RangeIter;
    const done = blk: {
        const dg = ri.done.borrow();
        defer dg.deinit();
        break :blk dg.get().*;
    };
    const more = blk: {
        if (done or ri.step == 0) break :blk false;
        const cg = ri.cur.borrow();
        const c = cg.get().*;
        cg.deinit();
        break :blk ri.kind.inBounds(c, ri.end, ri.step);
    };
    if (std.mem.eql(u8, name, "hasNext") and args.len == 0) {
        return .{ .ok = boolVal(more) };
    }
    if (isIteratorNext(name) and args.len == 0) {
        if (!more) return .{ .err = try throwExc(allocator, "kotlin.NoSuchElementException", "iterator exhausted") };
        const cg = ri.cur.borrowMut();
        const c = cg.get().*;
        const adv = c +| ri.step;
        // `end` is the exact final element; once it is yielded, stop. Also stop
        // if the cursor saturates (`adv == c`). Both avoid advancing past the
        // end — a Long.MAX overflow or a ULong wrap past MaxUL that `more`
        // (unsigned for ULong) would otherwise read as still in-bounds.
        if (c == ri.end or adv == c) {
            cg.deinit();
            const dg = ri.done.borrowMut();
            dg.get().* = true;
            dg.deinit();
        } else {
            cg.get().* = adv;
            cg.deinit();
        }
        return .{ .ok = rangeElem(c, ri.kind) };
    }
    return null;
}

// -------------------------------------------------------------------------
// Lazy `SeqIter` — one-element-at-a-time iteration over a `Sequence` (the
// `Sequence.iterator()` / `iterator { }` result). Pulls a single source
// element per step and runs it through the op pipeline, so an infinite source
// is never materialised.
// -------------------------------------------------------------------------

const SeqIterState = runtime.SeqIterState;

/// Lazily allocate the per-op streaming counters on first use.
fn seqIterEnsureState(allocator: Allocator, st: *SeqIterState, n_ops: usize) Allocator.Error!void {
    if (st.taken.len == n_ops or n_ops == 0) return;
    st.taken = try allocator.alloc(usize, n_ops);
    st.dropped = try allocator.alloc(usize, n_ops);
    st.take_while_live = try allocator.alloc(bool, n_ops);
    st.drop_while_live = try allocator.alloc(bool, n_ops);
    st.indices = try allocator.alloc(usize, n_ops);
    @memset(st.taken, 0);
    @memset(st.dropped, 0);
    @memset(st.take_while_live, true);
    @memset(st.drop_while_live, true);
    @memset(st.indices, 0);
}

/// Pull one raw element from the sequence source (no ops). Returns the element,
/// `null` at exhaustion, or an error.
fn seqIterSourcePull(self: *VmHost, allocator: Allocator, st: *SeqIterState, out: runtime.Output) Allocator.Error!union(enum) { value: Value, done, err: EvalError } {
    const sg = st.seq.Sequence.borrow();
    const src = sg.get().source;
    sg.deinit();
    switch (src) {
        .Items => |v| {
            const g = v.borrow();
            defer g.deinit();
            const items = g.get().*;
            const i = st.src_pos;
            if (i >= items.len) return .done;
            st.src_pos = i + 1;
            var e = items[i];
            if (runtime.reclaimEnabled()) e.retain();
            return .{ .value = e };
        },
        .Builder => |bstate| {
            var intrinsic = makeIntrinsicHost(self);
            defer deinitIntrinsicHost(&intrinsic);
            const ihost = intrinsic.intrinsicHost();
            const step = try ihost.builderStep(bstate, out);
            return switch (step) {
                .value => |val| .{ .value = val },
                .done => .done,
                .err => |re| .{ .err = try mapRuntimeError(allocator, re) },
            };
        },
        .IteratorFn => |fnbox| {
            if (st.done) return .done;
            var intrinsic = makeIntrinsicHost(self);
            defer deinitIntrinsicHost(&intrinsic);
            const ihost = intrinsic.intrinsicHost();
            if (st.iter_obj == null) {
                const r = try ihost.invokeCallable(&fnbox.asPtr().*, &.{}, out);
                switch (r) {
                    .ok => |v| st.iter_obj = v,
                    .err => |re| return .{ .err = try mapRuntimeError(allocator, re) },
                }
            }
            const iter = st.iter_obj.?;
            const hn = try callMemberRec(self, allocator, &iter, "hasNext", &.{});
            const has = switch (hn) {
                .ok => |x| x == .Bool and x.Bool,
                .err => |e| return .{ .err = e },
            };
            if (!has) {
                st.done = true;
                return .done;
            }
            const nx = try callMemberRec(self, allocator, &iter, "next", &.{});
            return switch (nx) {
                .ok => |v| .{ .value = v },
                .err => |e| .{ .err = e },
            };
        },
        .Merged => |mz| {
            if (st.done) return .done;
            if (st.iter_left == null) {
                switch (try callMemberRec(self, allocator, &mz.left.asPtr().*, "iterator", &.{})) {
                    .ok => |v| st.iter_left = v,
                    .err => |e| return .{ .err = e },
                }
                switch (try callMemberRec(self, allocator, &mz.right.asPtr().*, "iterator", &.{})) {
                    .ok => |v| st.iter_right = v,
                    .err => |e| return .{ .err = e },
                }
            }
            const lit = st.iter_left.?;
            const rit = st.iter_right.?;
            // Strict interleave: left hasNext, right hasNext, left next,
            // right next — the order `MergingSequence` pulls in.
            const lh = switch (try callMemberRec(self, allocator, &lit, "hasNext", &.{})) {
                .ok => |x| x == .Bool and x.Bool,
                .err => |e| return .{ .err = e },
            };
            if (!lh) {
                st.done = true;
                return .done;
            }
            const rh = switch (try callMemberRec(self, allocator, &rit, "hasNext", &.{})) {
                .ok => |x| x == .Bool and x.Bool,
                .err => |e| return .{ .err = e },
            };
            if (!rh) {
                st.done = true;
                return .done;
            }
            const av = switch (try callMemberRec(self, allocator, &lit, "next", &.{})) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            const bv = switch (try callMemberRec(self, allocator, &rit, "next", &.{})) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            if (mz.transform) |t| {
                var intrinsic = makeIntrinsicHost(self);
                defer deinitIntrinsicHost(&intrinsic);
                const ihost = intrinsic.intrinsicHost();
                const r = try ihost.invokeCallable(&t.asPtr().*, &.{ av, bv }, out);
                return switch (r) {
                    .ok => |v| .{ .value = v },
                    .err => |re| .{ .err = try mapRuntimeError(allocator, re) },
                };
            }
            return .{ .value = .{ .Pair = .{
                .first = try Value.boxRef(allocator, av),
                .second = try Value.boxRef(allocator, bv),
            } } };
        },
        .Generate => |gen| {
            if (st.done) return .done;
            if (!st.gen_started) {
                st.gen_started = true;
                if (gen.seed) |s| {
                    var sv = s.asPtr().*;
                    if (gen.seed_is_fn) {
                        var intr = makeIntrinsicHost(self);
                        defer deinitIntrinsicHost(&intr);
                        const ih = intr.intrinsicHost();
                        const r = try ih.invokeCallable(&sv, &.{}, out);
                        switch (r) {
                            .ok => |rv| {
                                if (rv == .Null) {
                                    st.done = true;
                                    return .done;
                                }
                                var v = rv;
                                if (runtime.reclaimEnabled()) v.retain();
                                st.gen_cur = v;
                                return .{ .value = v };
                            },
                            .err => |re| return .{ .err = try mapRuntimeError(allocator, re) },
                        }
                    }
                    if (runtime.reclaimEnabled()) sv.retain();
                    st.gen_cur = sv;
                    return .{ .value = sv };
                }
                // Nullary form: first element comes from next().
            }
            var intrinsic = makeIntrinsicHost(self);
            defer deinitIntrinsicHost(&intrinsic);
            const ihost = intrinsic.intrinsicHost();
            const arg: []const Value = if (st.gen_cur) |c| &.{c} else &.{};
            const r = try ihost.invokeCallable(&gen.next.asPtr().*, arg, out);
            switch (r) {
                .ok => |nv| {
                    if (nv == .Null) {
                        st.done = true;
                        return .done;
                    }
                    var v = nv;
                    if (runtime.reclaimEnabled()) v.retain();
                    st.gen_cur = v;
                    return .{ .value = v };
                },
                .err => |re| return .{ .err = try mapRuntimeError(allocator, re) },
            }
        },
    }
}

/// Pull one OUTPUT element: pull source elements and run each through the ops
/// until one passes (or the source is exhausted / a Take cap is hit).
fn seqIterPull(self: *VmHost, allocator: Allocator, st: *SeqIterState, out: runtime.Output) Allocator.Error!union(enum) { value: Value, done, err: EvalError } {
    const n_ops = blk: {
        const sg = st.seq.Sequence.borrow();
        defer sg.deinit();
        break :blk sg.get().ops.len;
    };
    try seqIterEnsureState(allocator, st, n_ops);

    var intrinsic = makeIntrinsicHost(self);
    defer deinitIntrinsicHost(&intrinsic);
    const ihost = intrinsic.intrinsicHost();

    outer: while (true) {
        // Stop pulling the source once any Take cap is reached.
        {
            const sg = st.seq.Sequence.borrow();
            const ops = sg.get().ops;
            var capped = false;
            for (ops, 0..) |op, i| {
                if (op == .Take and st.taken[i] >= @as(usize, @intCast(@max(op.Take, 0)))) capped = true;
            }
            sg.deinit();
            if (capped) return .done;
        }

        var current = switch (try seqIterSourcePull(self, allocator, st, out)) {
            .value => |v| v,
            .done => return .done,
            .err => |e| return .{ .err = e },
        };

        const sg = st.seq.Sequence.borrow();
        const ops = sg.get().ops;
        for (ops, 0..) |op, idx| {
            switch (op) {
                .Map => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| current = rv,
                        .err => |e| {
                            sg.deinit();
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .OnEach => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    if (r == .err) {
                        sg.deinit();
                        return .{ .err = try mapRuntimeError(allocator, r.err) };
                    }
                },
                .MapIndexed => |f| {
                    const i = st.indices[idx];
                    st.indices[idx] += 1;
                    const r = try ihost.invokeCallable(&f, &.{ Value.newInt(@intCast(i)), current }, out);
                    switch (r) {
                        .ok => |rv| current = rv,
                        .err => |e| {
                            sg.deinit();
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .FilterIndexed => |f| {
                    const i = st.indices[idx];
                    st.indices[idx] += 1;
                    const r = try ihost.invokeCallable(&f, &.{ Value.newInt(@intCast(i)), current }, out);
                    switch (r) {
                        .ok => |rv| if (!(rv == .Bool and rv.Bool)) {
                            sg.deinit();
                            continue :outer;
                        },
                        .err => |e| {
                            sg.deinit();
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .Filter => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| if (!(rv == .Bool and rv.Bool)) {
                            sg.deinit();
                            continue :outer;
                        },
                        .err => |e| {
                            sg.deinit();
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .FilterNot => |f| {
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| if (rv == .Bool and rv.Bool) {
                            sg.deinit();
                            continue :outer;
                        },
                        .err => |e| {
                            sg.deinit();
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .Take => |n| {
                    if (st.taken[idx] >= @as(usize, @intCast(@max(n, 0)))) {
                        sg.deinit();
                        return .done;
                    }
                    st.taken[idx] += 1;
                },
                .Drop => |n| {
                    if (st.dropped[idx] < @as(usize, @intCast(@max(n, 0)))) {
                        st.dropped[idx] += 1;
                        sg.deinit();
                        continue :outer;
                    }
                },
                .TakeWhile => |f| {
                    if (!st.take_while_live[idx]) {
                        sg.deinit();
                        return .done;
                    }
                    const r = try ihost.invokeCallable(&f, &.{current}, out);
                    switch (r) {
                        .ok => |rv| if (!(rv == .Bool and rv.Bool)) {
                            st.take_while_live[idx] = false;
                            sg.deinit();
                            return .done;
                        },
                        .err => |e| {
                            sg.deinit();
                            return .{ .err = try mapRuntimeError(allocator, e) };
                        },
                    }
                },
                .DropWhile => |f| {
                    if (st.drop_while_live[idx]) {
                        const r = try ihost.invokeCallable(&f, &.{current}, out);
                        switch (r) {
                            .ok => |rv| {
                                if (rv == .Bool and rv.Bool) {
                                    sg.deinit();
                                    continue :outer;
                                }
                                st.drop_while_live[idx] = false;
                            },
                            .err => |e| {
                                sg.deinit();
                                return .{ .err = try mapRuntimeError(allocator, e) };
                            },
                        }
                    }
                },
                // Buffering ops (sort/flatMap/distinct/...) cannot stream one at
                // a time; iterating such a sequence materialises it eagerly.
                else => {
                    sg.deinit();
                    const mr = try materialiseSequence(self, allocator, &st.seq);
                    switch (mr) {
                        .ok => |list| {
                            // Replace the source with the buffered items and clear
                            // ops so subsequent pulls stream from the buffer.
                            var owned = list;
                            const slice = try owned.toOwnedSlice(allocator);
                            const items_ref = try runtime.ValueSlice.init(allocator, slice);
                            const data = try ObjRef(runtime.SequenceData).init(allocator, .{
                                .source = .{ .Items = items_ref },
                                .ops = &.{},
                            });
                            if (runtime.reclaimEnabled()) st.seq.release(allocator);
                            st.seq = .{ .Sequence = data };
                            st.src_pos = 0;
                            st.taken = &.{};
                            st.dropped = &.{};
                            st.take_while_live = &.{};
                            st.drop_while_live = &.{};
                            st.indices = &.{};
                            return seqIterPull(self, allocator, st, out);
                        },
                        .err => |e| return .{ .err = e },
                    }
                },
            }
        }
        sg.deinit();
        return .{ .value = current };
    }
}

/// Ensure `st.buffered` holds the next element (or marks done). Returns whether
/// an element is available, or an error.
fn seqIterEnsure(self: *VmHost, allocator: Allocator, st: *SeqIterState, out: runtime.Output) Allocator.Error!union(enum) { has: bool, err: EvalError } {
    if (st.buffered != null) return .{ .has = true };
    if (st.done) return .{ .has = false };
    switch (try seqIterPull(self, allocator, st, out)) {
        .value => |v| {
            st.buffered = v;
            return .{ .has = true };
        },
        .done => {
            st.done = true;
            return .{ .has = false };
        },
        .err => |e| return .{ .err = e },
    }
}

fn seqIterMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const ref = receiver.SeqIter;
    if (std.mem.eql(u8, name, "hasNext") and args.len == 0) {
        const g = ref.borrowMut();
        defer g.deinit();
        return switch (try seqIterEnsure(self, allocator, g.get(), self.out)) {
            .has => |b| .{ .ok = boolVal(b) },
            .err => |e| .{ .err = e },
        };
    }
    if (isIteratorNext(name) and args.len == 0) {
        const g = ref.borrowMut();
        defer g.deinit();
        const st = g.get();
        switch (try seqIterEnsure(self, allocator, st, self.out)) {
            .has => |b| if (!b) return .{ .err = try throwExc(allocator, "kotlin.NoSuchElementException", "iterator exhausted") },
            .err => |e| return .{ .err = e },
        }
        const v = st.buffered.?;
        st.buffered = null;
        return .{ .ok = v };
    }
    return null;
}

fn funcAt(module: *const Module, fid: FuncId) ?Func {
    return if (module.funcById(fid)) |f| f.* else null;
}

fn argsListFromSlice(allocator: Allocator, slice: []const Value) Allocator.Error!std.ArrayList(Value) {
    var l: std.ArrayList(Value) = .empty;
    try l.appendSlice(allocator, slice);
    return l;
}

/// Whether the class `name` (or any supertype, breadth-first) declares an
/// IR method named `mname`.
fn classHasUserMethod(self: *VmHost, allocator: Allocator, start: []const u8, mname: []const u8) bool {
    // Fast path: the precomputed per-class hierarchy method-name set answers
    // this in O(1). It collects the same user-declared method names up the
    // supertype chain the walk below would. Built for every source class; a
    // class with no entry (a synthesized/anon shape) falls back to the walk.
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.hierarchy_methods.get(start)) |set| {
            return set.contains(mname);
        }
    }
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    queue.append(allocator, start) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch {};
        {
            const mg = self.module.borrow();
            const mod = mg.get();
            for (mod.classes.items) |c| {
                if (std.mem.eql(u8, c.name, cur)) {
                    for (c.methods) |fid| {
                        if (funcAt(mod, fid)) |f| {
                            if (std.mem.eql(u8, f.name, mname)) {
                                mg.deinit();
                                return true;
                            }
                        }
                    }
                }
            }
            mg.deinit();
        }
        const cg = self.classes.borrow();
        if (cg.get().get(cur)) |def| {
            const dg = def.borrow();
            for (dg.get().supertype_names) |s| queue.append(allocator, s) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

fn dataValueInstanceEquals(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), other: *const Value) Allocator.Error!bool {
    if (other.* != .Instance) return false;
    const rhs = other.Instance;
    const lg = inst.borrow();
    const lcg = lg.get().class.borrow();
    const rg = rhs.borrow();
    const rcg = rg.get().class.borrow();
    defer {
        rcg.deinit();
        rg.deinit();
        lcg.deinit();
        lg.deinit();
    }
    if (!std.mem.eql(u8, lcg.get().fqn, rcg.get().fqn)) return false;
    for (lcg.get().primary_params) |p| {
        const left = lg.get().get(p.name) orelse Value.Null;
        const right = rg.get().get(p.name) orelse Value.Null;
        if (!try deepValueEquals(self, allocator, &left, &right)) return false;
    }
    return true;
}

fn dataClassAutoMembers(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var is_data = false;
    var is_value = false;
    var is_object = false;
    var class_name: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        is_data = cg.get().is_data;
        is_value = cg.get().is_value;
        is_object = cg.get().is_object;
        class_name = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    // Auto members are only synthesized for data/value/object classes; a plain
    // class has none, so skip the per-call hierarchy walk (which allocates a
    // queue + seen-set) that only feeds the `has_user_override` guards below.
    if (!is_data and !is_value and !is_object) return null;
    const has_user_override = classHasUserMethod(self, allocator, class_name, name);

    if (is_data and is_object and !has_user_override and std.mem.eql(u8, name, "toString")) {
        return .{ .ok = try strVal(allocator, classDisplayName(class_name)) };
    }
    if ((is_data or is_value) and !has_user_override and args.len == 0) {
        if (is_data and std.mem.startsWith(u8, name, "component")) {
            const rest = name["component".len..];
            if (std.fmt.parseInt(usize, rest, 10) catch null) |n| {
                if (n >= 1) {
                    const g = inst.borrow();
                    const cg = g.get().class.borrow();
                    if (n - 1 < cg.get().primary_params.len) {
                        const pname = cg.get().primary_params[n - 1].name;
                        if (g.get().get(pname)) |v| {
                            cg.deinit();
                            g.deinit();
                            // Borrowed instance field; the register owns the
                            // result, so retain before returning (host-returns-owned).
                            if (runtime.reclaimEnabled()) v.retain();
                            return .{ .ok = v };
                        }
                    }
                    cg.deinit();
                    g.deinit();
                }
            }
        }
        if (std.mem.eql(u8, name, "toString")) {
            return .{ .ok = try renderStructural(self, allocator, inst) };
        }
        if (std.mem.eql(u8, name, "hashCode")) {
            const g = inst.borrow();
            const cg = g.get().class.borrow();
            var h: i32 = 0;
            for (cg.get().primary_params) |p| {
                const v = g.get().get(p.name) orelse Value.Null;
                h = h *% 31 +% valueStructuralHash(&v);
            }
            cg.deinit();
            g.deinit();
            return .{ .ok = Value.newInt(@as(i64, h)) };
        }
    }
    if (is_data and !has_user_override and std.mem.eql(u8, name, "copy")) {
        var n_params: usize = undefined;
        {
            const g = inst.borrow();
            const cg = g.get().class.borrow();
            n_params = cg.get().primary_params.len;
            cg.deinit();
            g.deinit();
        }
        if (args.len <= n_params) {
            var new_args: std.ArrayList(Value) = .empty;
            defer new_args.deinit(allocator);
            const g = inst.borrow();
            const cg = g.get().class.borrow();
            for (cg.get().primary_params, 0..) |p, idx| {
                if (idx < args.len) {
                    try new_args.append(allocator, args[idx]);
                } else {
                    try new_args.append(allocator, g.get().get(p.name) orelse Value.Null);
                }
            }
            cg.deinit();
            g.deinit();
            return try reconstructDataClass(self, allocator, inst, new_args.items);
        }
    }
    if ((is_data or is_value) and !has_user_override and args.len == 1 and std.mem.eql(u8, name, "equals")) {
        return .{ .ok = boolVal(try dataValueInstanceEquals(self, allocator, inst, &args[0])) };
    }
    return null;
}

/// `Name(p1=v1, …)` structural rendering of a data class.
fn renderStructural(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData)) Allocator.Error!Value {
    const g = inst.borrow();
    const cg = g.get().class.borrow();
    defer {
        cg.deinit();
        g.deinit();
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, classDisplayName(cg.get().name));
    try buf.append(allocator, '(');
    for (cg.get().primary_params, 0..) |p, idx| {
        if (idx > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, p.name);
        try buf.append(allocator, '=');
        const v = g.get().get(p.name) orelse Value.Null;
        const s = try v.display(allocator);
        try buf.appendSlice(allocator, s);
    }
    try buf.append(allocator, ')');
    _ = self;
    return .{ .String = try runtime.strInitOwned(allocator, try buf.toOwnedSlice(allocator)) };
}

fn anonMethodDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var class_name: []const u8 = undefined;
    var entry_tag: ?[]const u8 = null;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        class_name = cg.get().name;
        cg.deinit();
        if (g.get().get("__enum_entry_class__")) |t| {
            if (t == .String) {
                const sg = t.String.borrow();
                entry_tag = sg.get().bytes;
                sg.deinit();
            }
        }
        g.deinit();
    }
    const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ name, args.len });
    // Scratch lookup key (lookupAnonMethod dupes what it stores); free it.
    defer if (runtime.freeScratch()) allocator.free(arity_name);

    // Enum-entry override class first.
    if (entry_tag) |tag| {
        if (lookupAnonMethod(self, allocator, tag, arity_name, name)) |hit| {
            return try invokeAnonMethod(self, allocator, receiver, hit, args, null);
        }
    }

    if (lookupAnonMethod(self, allocator, class_name, arity_name, name)) |hit| {
        // Param-type disproof, mirroring the named-class member walk: an
        // anon-object `trace(message: String)` declines a trailing-lambda
        // call so the inline `Logger.trace(() -> String)` extension binds.
        // One module borrow serves both the param-type disproof and the
        // member-extension receiver gate (this path is hot enough that a
        // second borrow per anon hit showed up in DeepRecursive timing).
        const hit_info: struct { disproven: bool, ext_recv_ty: ?[]const u8 } = blk: {
            const hg = hit.module.borrow();
            defer hg.deinit();
            const hf = funcAt(hg.get(), hit.func) orelse break :blk .{ .disproven = false, .ext_recv_ty = null };
            const dis = anonMethodDisprovenFn(self, &hf, args);
            var rt: ?[]const u8 = null;
            if (hf.kind == .member_extension and hf.params.len != 0 and std.mem.eql(u8, hf.params[0].name, "this")) {
                rt = hf.params[0].ty.name;
            }
            break :blk .{ .disproven = dis, .ext_recv_ty = rt };
        };
        if (!hit_info.disproven) {
            // A MEMBER-EXTENSION override binds its extension receiver from
            // the enclosing implicit receivers, never from the dispatch
            // owner itself: `with(policy) { measure(...) }` inside a
            // MeasureScope runs the anon policy's `MeasureScope.measure`
            // with the scope as `this` and the policy in dispatch scope.
            if (hit_info.ext_recv_ty) |rt| {
                if (!receiverImplementsType(self, receiver, rt)) {
                    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
                    defer allocator.free(entries);
                    for (entries) |e| {
                        if (e.v != .Instance) continue;
                        if (!receiverImplementsType(self, &e.v, rt)) continue;
                        ir.eval.pushEnclosing(receiver);
                        defer ir.eval.popEnclosing();
                        return try invokeAnonMethodFrom(self, allocator, &e.v, receiver, hit, args, inst);
                    }
                    // No satisfying receiver in scope: decline so the walk
                    // can try the next candidate.
                    return null;
                }
            }
            return try invokeAnonMethod(self, allocator, receiver, hit, args, inst);
        }
    }
    return null;
}

/// Whether some supplied argument definitely cannot bind the anon method's
/// corresponding declared parameter (so the candidate must decline and the
/// dispatch walk continue to extensions).
fn anonMethodDisproven(self: *VmHost, hit: AnonMethodEntry, args: []const Value) bool {
    const mg = hit.module.borrow();
    defer mg.deinit();
    const f = funcAt(mg.get(), hit.func) orelse return false;
    return anonMethodDisprovenFn(self, &f, args);
}

fn anonMethodDisprovenFn(self: *VmHost, f: *const ir.Func, args: []const Value) bool {
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const effective = f.params[skip..];
    // Over-application: more args than the method declares and no trailing
    // vararg to absorb them cannot bind. Without this, `lookupAnonMethod`'s
    // arity-agnostic fallback answers a call with the wrong-arity member --
    // an `object : Iterable` whose 0-arg `override fun iterator()` would answer
    // the stdlib `iterator { block }` builder call and self-recurse forever.
    // Mirrors the named-class `pickMethodOverload` over-supply guard.
    if (args.len > effective.len and
        (effective.len == 0 or !effective[effective.len - 1].is_vararg)) return true;
    var i: usize = 0;
    while (i < args.len and i < effective.len) : (i += 1) {
        if (argDefinitelyNotParamType(self, &effective[i].ty, &args[i])) return true;
    }
    return false;
}

const root_mod = @import("../interp_ir.zig");
const NameValue = root_mod.NameValue;
const AnonMethodEntry = root_mod.AnonMethodEntry;

/// `(class, member)` key for `anon_methods`, unit-separated so the two
/// segments can't collide. Must match `run.zig`/`host_fields.zig`.
fn anonKey(allocator: Allocator, class_name: []const u8, member: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ class_name, member });
}

fn lookupAnonMethod(self: *VmHost, allocator: Allocator, class_name: []const u8, arity_name: []const u8, name: []const u8) ?AnonMethodEntry {
    const tbl = self.anon_methods.borrow();
    defer tbl.deinit();
    // The lookup keys are scratch — the map copies what it needs, so free them
    // on exit. The GC does not manage these raw allocations; leaving them (the
    // old arena-only assumption) leaks per dispatch under the freeing backends.
    const ak = anonKey(allocator, class_name, arity_name) catch return null;
    defer allocator.free(ak);
    if (tbl.get().get(ak)) |e| return e;
    const pk = anonKey(allocator, class_name, name) catch return null;
    defer allocator.free(pk);
    if (tbl.get().get(pk)) |e| return e;
    return null;
}

/// Exact anonymous/local-class method lookup used while linking a numeric
/// virtual slot. Unlike the legacy named-member path, this never falls back to
/// the arity-agnostic key.
fn lookupAnonMethodExact(self: *VmHost, allocator: Allocator, class_name: []const u8, arity_name: []const u8) ?AnonMethodEntry {
    const tbl = self.anon_methods.borrow();
    defer tbl.deinit();
    const key = anonKey(allocator, class_name, arity_name) catch return null;
    defer allocator.free(key);
    return tbl.get().get(key);
}

fn invokeAnonMethod(self: *VmHost, allocator: Allocator, receiver: *const Value, hit: AnonMethodEntry, args: []const Value, padding_inst: ?ObjRef(InstanceData)) Allocator.Error!EvalResult {
    return invokeAnonMethodFrom(self, allocator, receiver, receiver, hit, args, padding_inst);
}

/// `invokeAnonMethod` with the CAPTURE SOURCE decoupled from the bound
/// receiver: a member-extension override runs with the EXTENSION receiver
/// as `this` (params[0]) while its captures still live on the anon OWNER
/// instance (`capture_src`).
fn invokeAnonMethodFrom(self: *VmHost, allocator: Allocator, receiver: *const Value, capture_src: *const Value, hit: AnonMethodEntry, args: []const Value, padding_inst: ?ObjRef(InstanceData)) Allocator.Error!EvalResult {
    const mg = hit.module.borrow();
    const module_rc = mg.get();
    defer mg.deinit();
    const f = funcAt(module_rc, hit.func) orelse {
        return .{ .err = try typeErr(allocator, "anon method FuncId {d} out of range", .{@intFromEnum(hit.func)}) };
    };
    var all: std.ArrayList(Value) = .empty;
    try all.append(allocator, receiver.*);
    try all.appendSlice(allocator, args);

    // Pad omitted trailing args from inherited defaults.
    if (padding_inst) |inst| {
        if (all.items.len < f.params.len) {
            var supertypes: [][]const u8 = &.{};
            const sg = inst.borrow();
            const scg = sg.get().class.borrow();
            supertypes = try allocator.alloc([]const u8, scg.get().supertype_names.len);
            for (scg.get().supertype_names, 0..) |s, i| supertypes[i] = s;
            scg.deinit();
            sg.deinit();
            if (try inheritedMemberDefaults(self, allocator, supertypes, f.name)) |defaults| {
                const mmg = self.module.borrow();
                const main_mod = mmg.get();
                const padded = try padArgsWithDefaults(self, allocator, main_mod, f.params.len, all.items, defaults);
                mmg.deinit();
                switch (padded) {
                    .ok => |p| {
                        all.deinit(allocator);
                        all = try argsListFromSlice(allocator, p);
                    },
                    .err => |e| return .{ .err = e },
                }
            }
        }
    }
    const packed_args = try packVarargArgs(self, allocator, &f, try all.toOwnedSlice(allocator));

    // Captures come from the instance for an anonymous-object expression
    // (`buildObject` stores them per-instance, registry entry empty), or from
    // the registry entry for a local class (`registerClassCaptured` registers
    // once per declaration — site-stable, no leak). Prefer the instance; fall
    // back to the entry. `InstanceData.Capture` and `NameValue` are the same
    // shape, so the instance slice reinterprets as `[]const NameValue`.
    comptime std.debug.assert(@sizeOf(InstanceData.Capture) == @sizeOf(NameValue));
    const inst_caps: []const InstanceData.Capture = blk: {
        if (capture_src.* != .Instance) break :blk &.{};
        const g = capture_src.Instance.borrow();
        defer g.deinit();
        break :blk g.get().anon_captures;
    };
    const chain_seed: []const ir.eval.EnclosingEntry = blk: {
        if (capture_src.* != .Instance) break :blk &.{};
        const g = capture_src.Instance.borrow();
        defer g.deinit();
        break :blk g.get().anon_enclosing;
    };
    const caps: []const NameValue = if (inst_caps.len != 0) @ptrCast(inst_caps) else hit.captures;

    // Layer captured outer-env names onto globals + build the capture vec.
    const prev = self.globals.clone();
    defer {
        self.globals.deinit();
        self.globals = prev;
    }
    if (caps.len != 0) {
        const scoped = try ObjRef(runtime.Env).init(allocator, runtime.Env.withParent(allocator, self.globals.clone()));
        const sg = scoped.borrowMut();
        for (caps) |nv| sg.get().define(nv.name, nv.value) catch {};
        sg.deinit();
        self.globals = scoped;
    }
    // The host's active globals scope is only held in this stack-local VmHost
    // field; pin it so a collection during the body eval cannot sweep the
    // transient capture-layer env (its parent chain reaches the rooted globals).
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    runtime.keepalivePushCell(&self.globals.cell.hdr);
    var cap_vec: std.ArrayList(Value) = .empty;
    for (f.capture_order) |cn| {
        if (std.mem.eql(u8, cn, "this")) {
            try cap_vec.append(allocator, receiver.*);
        } else {
            var found: Value = .Null;
            for (caps) |nv| {
                if (std.mem.eql(u8, nv.name, cn)) found = nv.value;
            }
            try cap_vec.append(allocator, found);
        }
    }
    var packed_list = try argsListFromSlice(allocator, packed_args);
    // `argsListFromSlice` copied the args into the frame-owned list; the
    // `packed_args` buffer (a full allocation from `packVarargArgs`) is dead.
    if (runtime.freeScratch()) allocator.free(packed_args);
    _ = &packed_list;
    vmhost.emitPath(allocator, "member_anon", f.fqn, f.id, receiver, args);
    return ir.eval.evalWithCapturesChained(VmHost, allocator, module_rc, module_rc, &f, packed_list, cap_vec, chain_seed, null, self);
}

/// Build the `n_params`-length argument vector, filling positions past
/// the provided args from default-arg thunks.
fn padArgsWithDefaults(self: *VmHost, allocator: Allocator, module: *const Module, n_params: usize, provided: []const Value, defaults: ?[]const ?FuncId) Allocator.Error!union(enum) { ok: []Value, err: EvalError } {
    // Kotlin binds a trailing lambda to the LAST parameter. When the
    // positional layout would leave a default-less last parameter empty
    // while the last provided arg is callable, the call was the
    // trailing-lambda form over defaulted middle params
    // (`items(3) { … }` against `items(count, key = …, type = …,
    // itemContent)`) — a straight positional fill would be a kotlinc
    // compile error, so the shift never changes a legal layout.
    var last_shift: ?Value = null;
    var pos_len = provided.len;
    if (provided.len > 0 and provided.len < n_params) {
        const last_default: ?FuncId = if (defaults) |d| (if (n_params - 1 < d.len) d[n_params - 1] else null) else null;
        const lastp = provided[provided.len - 1];
        if (last_default == null and isCallable(&lastp)) {
            last_shift = lastp;
            pos_len -= 1;
        }
    }
    var call_args: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < n_params) : (i += 1) {
        if (i + 1 == n_params) {
            if (last_shift) |lv| {
                try call_args.append(allocator, lv);
                continue;
            }
        }
        if (i < pos_len) {
            try call_args.append(allocator, provided[i]);
            continue;
        }
        const dfid: ?FuncId = if (defaults) |d| (if (i < d.len) d[i] else null) else null;
        if (dfid) |df| {
            const dfunc = funcAt(module, df) orelse {
                call_args.deinit(allocator);
                return .{ .err = try typeErr(allocator, "default-arg FuncId {d} out of range", .{@intFromEnum(df)}) };
            };
            var captures: std.ArrayList(Value) = .empty;
            if (call_args.items.len != 0) try captures.append(allocator, call_args.items[0]);
            const cur = try argsListFromSlice(allocator, call_args.items);
            vmhost.emitPath(allocator, "member_default_thunk", dfunc.fqn, df, null, provided);
            const r = try ir.eval.evalWithCaptures(VmHost, allocator, module, &dfunc, cur, captures, self);
            switch (r) {
                .ok => |v| try call_args.append(allocator, v),
                .err => |e| {
                    call_args.deinit(allocator);
                    return .{ .err = e };
                },
            }
        } else {
            try call_args.append(allocator, .Null);
        }
    }
    return .{ .ok = try call_args.toOwnedSlice(allocator) };
}

/// Trailing-lambda syntax bit of the member call currently dispatching
/// (`recv.f(x) { … }` vs `recv.f(x, { … })`) — see `Inst.CallMember.
/// trailing_lambda`. Saved/restored by the exec sites around each dispatch
/// so nested member calls (walk probes running accessors) cannot clobber
/// the outer call's bit. Read non-destructively by the under-applied
/// trailing-lambda arm in `irMethodWalk`.
threadlocal var trailing_member_call: bool = false;

pub fn setTrailingMemberCall(on: bool) bool {
    const prev = trailing_member_call;
    trailing_member_call = on;
    return prev;
}

const ResolvedMethod = struct { fid: FuncId, unambiguous: bool };

/// Resolve `receiver.name(args)` to the user method `FuncId` it would dispatch,
/// or null for a non-`Instance` receiver or a name that resolves to an intrinsic
/// / extension / unresolved member. The loop JIT calls this at compile time to
/// learn a trampolined member call's return type; the call still dispatches
/// through normal member resolution at run time, so this never changes behavior.
/// Member methods take precedence over extensions in Kotlin, so a resolved member
/// is also what runs — its (override-invariant, for a scalar) return type is sound.
pub fn resolveMemberFuncId(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) ?FuncId {
    if (receiver.* != .Instance) return null;
    const rm = resolveInstanceMethod(self, allocator, receiver, name, args, null) catch return null;
    return if (rm) |m| m.fid else null;
}

/// Walk the receiver's class hierarchy resolving `name` to a user method
/// `FuncId`. `unambiguous` is set when the resolving class had exactly one
/// method of that name (so the choice does not depend on argument types and the
/// resolution may be cached for the inline dispatch cache).
/// A function/lambda argument bound to a member parameter typed as a bare
/// type-parameter (`value: T`) matches only because the receiver's type
/// argument is erased. When a same-name extension applicable to this receiver
/// takes that argument as a concrete function type, it is the more specific —
/// and in Kotlin the only applicable — overload (the member's `T` is the
/// receiver's non-function type argument, e.g. `CancellableContinuation<Unit>`,
/// which a function does not satisfy). Defer the member to it. Example:
/// `cont.tryResume(onCancellation)` must bind the `Boolean`-returning extension
/// `CancellableContinuation<Unit>.tryResume(onCancellation)`, not the member
/// `tryResume(value: T): Any?`.
fn callableArgPrefersFunctionExtension(self: *VmHost, mod: *const Module, name: []const u8, member: *const Func, receiver: *const Value, args: []const Value) bool {
    const mskip: usize = if (member.params.len > 0 and std.mem.eql(u8, member.params[0].name, "this")) 1 else 0;
    var fn_arg_pos: ?usize = null;
    for (args, 0..) |*a, i| {
        // A function value, or a null where a (nullable) function is expected,
        // is the kind of argument the extension takes concretely.
        const fn_shaped = isCallable(a) or a.* == .Null;
        if (!fn_shaped) continue;
        const pi = mskip + i;
        if (pi >= member.params.len) continue;
        const mp = member.params[pi].ty;
        if (std.mem.startsWith(u8, mp.name, "Function")) return false; // member already takes a function here
        // The member binds this argument only through a bare type-parameter
        // slot (`value: T`) — it is the receiver's erased, non-function type
        // argument, which a function/null does not satisfy.
        if (mp.name.len <= 2 and allUppercase(mp.name)) fn_arg_pos = i;
    }
    const want_pos = fn_arg_pos orelse return false;

    const recv_chain = receiverClassChain(self, self.allocator, receiver.Instance) catch return false;
    defer @constCast(&recv_chain).deinit();

    for (mod.funcsBySimpleName(name)) |fid| {
        const ef = funcAt(mod, fid) orelse continue;
        if (ef.kind != .top_level_extension and ef.kind != .member_extension) continue;
        if (ef.params.len == 0) continue;
        const rt = ef.params[0].ty.name; // extension receiver type
        const recv_ok = recv_chain.contains(rt) or std.mem.eql(u8, rt, "Any") or (rt.len <= 2 and allUppercase(rt));
        if (!recv_ok) continue;
        const epi = 1 + want_pos; // skip the extension's `this`
        if (epi >= ef.params.len) continue;
        if (std.mem.startsWith(u8, ef.params[epi].ty.name, "Function")) return true;
    }
    return false;
}

/// The count of a function's OWN (method-level) type parameters. A subtype's
/// same-name overload that introduces its own type parameters (`get<T>(Key<T>)`
/// shadowing `Map.get(K)`) is the shape the static-receiver visibility filter
/// targets; a plain non-generic member is left alone.
fn funcTypeParamCount(self: *VmHost, fid: FuncId) usize {
    const mg = self.module.borrow();
    defer mg.deinit();
    const tps = mg.get().registry.func_type_params.get(fid) orelse return 0;
    return tps.items.len;
}

/// The IR class id in `receiver`'s runtime hierarchy whose simple name matches
/// the static receiver-type head `want`, or null when the static type is not a
/// nominal class in the hierarchy.
fn findClassInHierarchy(self: *VmHost, allocator: Allocator, receiver: *const Value, want: []const u8) Allocator.Error!?ir.ClassId {
    if (receiver.* != .Instance) return null;
    var recv_fqn: []const u8 = undefined;
    var class_name: []const u8 = undefined;
    {
        const g = receiver.Instance.borrow();
        const cg = g.get().class.borrow();
        class_name = cg.get().name;
        recv_fqn = cg.get().fqn;
        cg.deinit();
        g.deinit();
    }
    const WalkItem = struct { cid: ?ir.ClassId, name: []const u8 };
    var queue: std.ArrayList(WalkItem) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    const start_cid: ?ir.ClassId = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classIdByFqn(recv_fqn);
    };
    try queue.append(allocator, .{ .cid = start_cid, .name = class_name });
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const item = queue.items[head];
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        var ir_class: ?ir.Class = null;
        var cid_of: ?ir.ClassId = item.cid;
        if (item.cid) |cid| {
            if (@intFromEnum(cid) < mod.classes.items.len) ir_class = mod.classes.items[@intFromEnum(cid)];
        }
        if (ir_class == null) {
            for (mod.classes.items, 0..) |c, i| {
                if (std.mem.eql(u8, c.name, item.name)) {
                    ir_class = c;
                    cid_of = @enumFromInt(i);
                    break;
                }
            }
        }
        const irc = ir_class orelse continue;
        if (seen.contains(irc.fqn)) continue;
        try seen.put(irc.fqn, {});
        if (std.mem.eql(u8, simpleName(irc.name), want) or std.mem.eql(u8, simpleName(irc.fqn), want))
            return cid_of;
        for (irc.supertypes) |sid| {
            if (@intFromEnum(sid) < mod.classes.items.len) {
                try queue.append(allocator, .{ .cid = sid, .name = mod.classes.items[@intFromEnum(sid)].name });
            }
        }
    }
    return null;
}

/// The set of class FQNs at or ABOVE `start_cid` in the class hierarchy: the
/// static receiver type and every supertype it inherits from. A member declared
/// on one of these is visible from the static receiver type; a member declared
/// on any OTHER class in the runtime receiver's hierarchy is a proper-descendant
/// member, invisible from the static type unless it overrides a visible one.
fn ancestorClosureFqns(self: *VmHost, allocator: Allocator, start_cid: ir.ClassId, out: *std.StringHashMap(void)) Allocator.Error!void {
    var queue: std.ArrayList(ir.ClassId) = .empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, start_cid);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cid = queue.items[head];
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (@intFromEnum(cid) >= mod.classes.items.len) continue;
        const irc = mod.classes.items[@intFromEnum(cid)];
        if (out.contains(irc.fqn)) continue;
        try out.put(irc.fqn, {});
        for (irc.supertypes) |sid| try queue.append(allocator, sid);
    }
}

fn isOperatorConventionName(name: []const u8) bool {
    const ops = [_][]const u8{ "plus", "minus", "times", "div", "rem", "get", "set", "contains", "rangeTo", "rangeUntil", "compareTo", "inc", "dec", "unaryPlus", "unaryMinus", "not", "invoke" };
    for (ops) |o| {
        if (std.mem.eql(u8, name, o)) return true;
    }
    return false;
}

fn staticIsInterface(mod: *const Module, cid: ir.ClassId) bool {
    if (@intFromEnum(cid) >= mod.classes.items.len) return false;
    return mod.classes.items[@intFromEnum(cid)].is_interface;
}

/// Whether the static receiver type's transitive member-name set contains
/// `name`, via the build-time `hierarchy_methods` registry. No registry
/// entry answers true, keeping the exclusion conservative.
fn closureHasMethodNamed(mod: *const Module, start_cid: ir.ClassId, name: []const u8) bool {
    // `Any`'s members are visible from every static type; the interface
    // registry sets do not record them.
    if (std.mem.eql(u8, name, "equals") or std.mem.eql(u8, name, "hashCode") or std.mem.eql(u8, name, "toString")) return true;
    if (@intFromEnum(start_cid) >= mod.classes.items.len) return true;
    const irc = mod.classes.items[@intFromEnum(start_cid)];
    const hm = mod.registry.hierarchy_methods.get(irc.name) orelse
        mod.registry.hierarchy_methods.get(simpleName(irc.fqn)) orelse return true;
    return hm.contains(name);
}

/// Whether the static receiver type `start_cid` (or one of its supertypes)
/// declares a method named `name` with exactly `tvc` OWN type parameters. A
/// generic same-name method a runtime subtype introduces is a legitimate
/// OVERRIDE only when the static type's own scope declares a generic member of
/// the same shape; otherwise it is a subtype-only overload (it may even carry
/// the `override` modifier for a DIFFERENT interface not visible from the static
/// type — `PersistentCompositionLocalHashMap.get<T>` overrides `CompositionLocalMap`,
/// not `Map`), and must not shadow the statically-bound member.
fn closureHasGenericMethod(self: *VmHost, allocator: Allocator, start_cid: ir.ClassId, name: []const u8, tvc: usize) Allocator.Error!bool {
    var queue: std.ArrayList(ir.ClassId) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    try queue.append(allocator, start_cid);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cid = queue.items[head];
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (@intFromEnum(cid) >= mod.classes.items.len) continue;
        const irc = mod.classes.items[@intFromEnum(cid)];
        if (seen.contains(irc.fqn)) continue;
        try seen.put(irc.fqn, {});
        for (irc.methods) |fid| {
            if (funcAt(mod, fid)) |f| {
                if (std.mem.eql(u8, f.name, name) and funcTypeParamCount(self, fid) == tvc) return true;
            }
        }
        for (irc.supertypes) |sid| try queue.append(allocator, sid);
    }
    return false;
}

fn resolveInstanceMethod(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8) Allocator.Error!?ResolvedMethod {
    const inst = receiver.Instance;
    // When the call carries a static receiver type (an implicit-`this` /
    // inline-spliced own-member call), Kotlin resolves it against that static
    // type's member scope. A candidate a runtime subtype introduces that is NOT
    // an override of a member visible from the static type is out of scope and
    // must not shadow the statically-bound member. Compute the static type's
    // ancestor closure so the walk can exclude such proper-descendant, non-
    // override candidates. `Map.getOrElse`'s inlined `get(key)` binds `Map.get`,
    // never a `CLMap: MapBase` receiver's own `get<T>(Key<T>)` (which self-recurses).
    var static_up: std.StringHashMap(void) = .init(allocator);
    defer static_up.deinit();
    var static_up_ready = false;
    var static_cid: ir.ClassId = undefined;
    if (static_recv) |sr| {
        const want = std.mem.trimEnd(u8, simpleName(sr), "?");
        if (try findClassInHierarchy(self, allocator, receiver, want)) |s_cid| {
            try ancestorClosureFqns(self, allocator, s_cid, &static_up);
            static_cid = s_cid;
            static_up_ready = true;
        }
    }
    var class_name: []const u8 = undefined;
    var recv_fqn: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        class_name = cg.get().name;
        recv_fqn = cg.get().fqn;
        cg.deinit();
        g.deinit();
    }
    const WalkItem = struct { cid: ?ir.ClassId, name: []const u8 };
    var queue: std.ArrayList(WalkItem) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    // Start from the receiver's ACTUAL class identity — its IR class id keyed
    // by exact FQN — so a same-simple-name class in another package can never
    // shadow it. The hierarchy is then walked by identity (each class's
    // resolved supertype ids), never re-resolved from a collidable simple name.
    const start_cid: ?ir.ClassId = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classIdByFqn(recv_fqn);
    };
    try queue.append(allocator, .{ .cid = start_cid, .name = class_name });
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const item = queue.items[head];
        // Resolve the IR class by identity (its id) when known; a
        // synthesized/anonymous shape with no unambiguous id falls back to a
        // simple-name match.
        var ir_class: ?ir.Class = null;
        var cur_name: []const u8 = item.name;
        {
            const mg = self.module.borrow();
            defer mg.deinit();
            const mod = mg.get();
            if (item.cid) |cid| {
                if (@intFromEnum(cid) < mod.classes.items.len) ir_class = mod.classes.items[@intFromEnum(cid)];
            }
            if (ir_class == null) {
                for (mod.classes.items) |c| {
                    if (std.mem.eql(u8, c.name, cur_name)) {
                        ir_class = c;
                        break;
                    }
                }
            }
            // Dedup on the resolved class's FQN (identity) so two distinct
            // classes that share a simple name are each walked once.
            const dedup_key = if (ir_class) |irc| irc.fqn else cur_name;
            if (seen.contains(dedup_key)) continue;
            try seen.put(dedup_key, {});
            if (ir_class) |irc| {
                cur_name = irc.name;
                // Gather candidates named `name`. A `@LowPriorityInOverloadResolution`
                // / `@Deprecated(level = ERROR)` member is a guard stub that only
                // applies when no ordinary candidate (member or top-level extension)
                // does; skip it here so resolution falls through to the extension
                // path. kotlinx.coroutines' `SelectBuilder.onTimeout` shadows its own
                // `onTimeout` extension this way, and binding the stub would
                // self-recurse (its body just calls the extension).
                var candidates: std.ArrayList(Func) = .empty;
                defer candidates.deinit(allocator);
                for (irc.methods) |fid| {
                    if (funcAt(mod, fid)) |f| {
                        if (std.mem.eql(u8, f.name, name) and !f.low_priority) {
                            // A member EXTENSION found among the class's own
                            // methods binds the dispatch receiver as its
                            // EXTENSION receiver (params[0]). When the receiver
                            // is only the owner/dispatch instance and provably
                            // not the declared extension-receiver type, that
                            // direct bind is wrong: the call resolves through
                            // the extension path instead (owner from the
                            // enclosing `this`, extension receiver from an outer
                            // implicit receiver — e.g. `with(node) { measure() }`
                            // inside a MeasureScope coordinator). Skip it so the
                            // receiver walk continues to the true extension
                            // receiver.
                            if (isMemberExt(mod, fid) and f.params.len > 0 and
                                std.mem.eql(u8, f.params[0].name, "this") and
                                receiverDefinitelyNotParam(self, &f.params[0].ty, receiver)) continue;
                            // Kotlin collection-stub bridge: a candidate whose
                            // declared param names a CLASS type param with a
                            // bound the runtime argument refutes is skipped,
                            // so the walk falls through to the inherited
                            // implementation (indexOf(nonEnum) on an
                            // EnumEntries answers -1 through AbstractList's
                            // scan, exactly as the generated bridge does).
                            if (classTypeParamRefutes(self, mod, cur_name, &f, args)) continue;
                            // A static-receiver-directed call is resolved in the
                            // static type's member scope. A candidate declared on a
                            // proper descendant of that type (not in its ancestor
                            // closure) that introduces its OWN type parameters is a
                            // subtype-only generic overload UNLESS the static type's
                            // own scope declares a generic member of the same shape
                            // for it to override. `PersistentCompositionLocalHashMap
                            // .get<T>` carries `override` (of `CompositionLocalMap`,
                            // a subtype of `Map`) yet is out of `Map`'s scope, so an
                            // `is_override` test is not enough — the closure check is.
                            // A plain non-generic member (a synthesized delegate or
                            // accessor) is left untouched by the generic-shape guard.
                            if (static_up_ready and !static_up.contains(irc.fqn)) {
                                const tvc = funcTypeParamCount(self, f.id);
                                if (tvc > 0 and !(try closureHasGenericMethod(self, allocator, static_cid, name, tvc))) continue;
                                // A NON-generic member declared outside the static
                                // type's closure is invisible when the static type is
                                // an INTERFACE whose transitive member set lacks the
                                // name: `this + dispatcher` on a CoroutineScope-typed
                                // receiver must not bind the runtime coroutine's
                                // inherited `CoroutineContext.Element.plus`; the
                                // `CoroutineScope.plus` extension is Kotlin's target.
                                // Interface-only: an interface's registry member set
                                // is exact, so the exclusion cannot drop a legitimate
                                // inherited member the set fails to record.
                                // Operator-convention names only: klio has no
                                // smart-cast narrowing, so a general exclusion
                                // loops when an extension's body re-calls the
                                // member under an `is` check (`Continuation.
                                // resumeCancellableWith` -> DispatchedContinuation
                                // member). Operators do not take that shape, and
                                // they are where the static-type divergence bites
                                // (`this + dispatcher` on CoroutineScope).
                                if (tvc == 0 and isOperatorConventionName(name) and
                                    staticIsInterface(mod, static_cid) and
                                    !closureHasMethodNamed(mod, static_cid, name)) continue;
                            }
                            try candidates.append(allocator, f);
                        }
                    }
                }
                if (pickMethodOverload(self, mod, candidates.items, args)) |f| {
                    if (!callableArgPrefersFunctionExtension(self, mod, name, &f, receiver, args))
                        return .{ .fid = f.id, .unambiguous = candidates.items.len == 1 };
                }
                // Enqueue the resolved supertypes by identity (their IR class
                // ids) so the inherited-method walk follows the real class
                // hierarchy, never a same-simple-name impostor.
                for (irc.supertypes) |sid| {
                    if (@intFromEnum(sid) < mod.classes.items.len) {
                        try queue.append(allocator, .{ .cid = sid, .name = mod.classes.items[@intFromEnum(sid)].name });
                    }
                }
            }
        }
        // Fallback for a receiver class with no unambiguous IR id (anonymous/
        // synthesized): expand supertypes from the registered simple names.
        if (ir_class == null) {
            const cg = self.classes.borrow();
            if (cg.get().get(cur_name)) |def| {
                const dg = def.borrow();
                for (dg.get().supertype_names) |sup| try queue.append(allocator, .{ .cid = null, .name = sup });
                dg.deinit();
            }
            cg.deinit();
        }
    }
    return null;
}

/// See the candidate loop in `resolveInstanceMethod`: whether a declared
/// param typed as one of `class_name`'s type parameters has a recorded
/// upper bound the runtime argument DEFINITIVELY refutes. Positive-proof
/// only — an unknown/incomplete relation never refutes.
fn classTypeParamRefutes(self: *VmHost, mod: *const Module, class_name: []const u8, f: *const Func, args: []const Value) bool {
    const bounds = mod.registry.class_type_param_bounds.get(class_name) orelse return false;
    const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    if (f.params.len <= recv_off) return false;
    for (f.params[recv_off..], 0..) |*p, i| {
        if (i >= args.len) break;
        const pn = std.mem.trimEnd(u8, simpleName(p.ty.name), "?");
        for (bounds) |b| {
            if (!std.mem.eql(u8, b.param, pn)) continue;
            var bn = simpleName(b.bound);
            if (std.mem.indexOfScalar(u8, bn, '<')) |lt| bn = bn[0..lt];
            bn = std.mem.trimEnd(u8, bn, "?");
            if (std.mem.eql(u8, bn, "Any")) continue;
            const arg = &args[i];
            if (arg.* == .Null) continue;
            if (std.mem.eql(u8, bn, "Enum")) {
                // An enum-entry instance's class is is_enum; anything else
                // can never satisfy an Enum bound.
                if (arg.* == .Instance) {
                    const g = arg.Instance.borrow();
                    const cg = g.get().class.borrow();
                    const is_enum = cg.get().is_enum;
                    cg.deinit();
                    g.deinit();
                    if (!is_enum) return true;
                } else {
                    return true;
                }
                continue;
            }
            if (arg.* == .Instance and !receiverImplementsHead(self, arg, bn)) return true;
        }
    }
    return false;
}

/// Invoke an already-resolved user method by `FuncId`: prepend the receiver,
/// pad defaults, pack varargs, and run the body. Shared by the cold resolve
/// path (`irMethodWalk`) and the inline-cache fast path.
/// Direct dispatch to a lowering-resolved monomorphic member target
/// (`Inst.CallMember.resolved`): invoke `fid` on `receiver` with no name
/// resolution, applicability walk, or FQN scan. Returns `null` only if the
/// target vanished (unresolvable fid); the caller then falls back to the
/// name-based path, so a stale bake can never miscall — it degrades to the
/// existing dispatch. Positional args only (the lowerer bakes `resolved`
/// solely for name-arg-free calls).
pub fn invokeResolvedMember(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, args: []const Value) Allocator.Error!?EvalResult {
    // A member-extension needs its declaring class's `this` seeded as an
    // enclosing receiver (the owner-find the walk performs) before the body
    // runs; a plain member / top-level extension binds `[receiver] ++ args`
    // directly. Route member-extensions through the owner-replay path, which
    // returns null (fall back to the name walk) when the owner is unreachable.
    const is_member_ext = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk isMemberExt(mg.get(), fid);
    };
    if (is_member_ext) return invokeMemberExtFuncId(self, allocator, receiver, fid, args);
    return invokeMethodFuncId(self, allocator, receiver, fid, args);
}

fn runtimeVirtualCacheGet(self: *VmHost, key: root_mod.ProgramImage.RuntimeVirtualKey) ?root_mod.ProgramImage.RuntimeVirtualTarget {
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().runtime_virtual_cache.get(key);
}

fn runtimeVirtualCachePut(self: *VmHost, key: root_mod.ProgramImage.RuntimeVirtualKey, target: root_mod.ProgramImage.RuntimeVirtualTarget) void {
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().runtime_virtual_cache.put(key, target) catch {};
}

/// Resolve a runtime class-table entry without a simple-name fallback when the
/// caller supplied an FQN. Runtime-defined classes record their resolved
/// supertypes in this table even though they have no main-module `ClassId`.
fn runtimeClassDef(self: *VmHost, name: []const u8) ?ObjRef(ClassDef) {
    const classes = self.classes.borrow();
    defer classes.deinit();
    if (classes.get().get(name)) |def| return def.clone();
    var it = classes.get().valueIterator();
    while (it.next()) |def| {
        const dg = def.borrow();
        const matches = std.mem.eql(u8, dg.get().fqn, name);
        dg.deinit();
        if (matches) return def.clone();
    }
    return null;
}

/// Find this runtime class's body for a numeric slot. The slot root fixes the
/// method family; the exact arity-qualified side-table key only locates the
/// already-lowered body belonging to that family.
fn runtimeVirtualOverride(
    self: *VmHost,
    allocator: Allocator,
    runtime_def: ObjRef(ClassDef),
    root_func: Func,
) Allocator.Error!?AnonMethodEntry {
    const class_name = blk: {
        const dg = runtime_def.borrow();
        defer dg.deinit();
        break :blk dg.get().name;
    };
    const receiver_count: usize = if (root_func.params.len != 0 and
        std.mem.eql(u8, root_func.params[0].name, "this")) 1 else 0;
    const arity_name = try std.fmt.allocPrint(
        allocator,
        "{s}#{d}",
        .{ root_func.name, root_func.params.len - receiver_count },
    );
    defer if (runtime.freeScratch()) allocator.free(arity_name);
    const hit = lookupAnonMethodExact(self, allocator, class_name, arity_name) orelse return null;
    const hg = hit.module.borrow();
    defer hg.deinit();
    const candidate = funcAt(hg.get(), hit.func) orelse return null;
    if (!candidate.is_override or !std.mem.eql(u8, candidate.name, root_func.name)) return null;
    const candidate_receiver_count: usize = if (candidate.params.len != 0 and
        std.mem.eql(u8, candidate.params[0].name, "this")) 1 else 0;
    if (candidate.params.len - candidate_receiver_count != root_func.params.len - receiver_count) return null;
    return hit;
}

/// Merge the complete slot tables of a runtime class's resolved direct
/// supertypes. Named supertypes stop the walk because their main-module vtable
/// already contains their transitive inheritance; runtime supertypes continue
/// through their recorded names.
fn runtimeInheritedVirtualTarget(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    runtime_def: ObjRef(ClassDef),
    slot: MethodSlotId,
) Allocator.Error!?FuncId {
    var queue: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        while (queue.pop()) |def| def.deinit();
        queue.deinit(allocator);
    }
    var seen = std.AutoHashMap(usize, void).init(allocator);
    defer seen.deinit();
    {
        const dg = runtime_def.borrow();
        defer dg.deinit();
        for (dg.get().supertype_names) |name| {
            if (runtimeClassDef(self, name)) |def| try queue.append(allocator, def);
        }
    }

    var best: ?FuncId = null;
    while (queue.pop()) |def| {
        defer def.deinit();
        const identity = def.identity();
        const gop = try seen.getOrPut(identity);
        if (gop.found_existing) continue;

        const dg = def.borrow();
        const fqn = dg.get().fqn;
        const class_name = dg.get().name;
        if (module.classIdByFqn(fqn) orelse
            (if (std.mem.eql(u8, fqn, class_name)) module.classId(class_name) else null)) |cid|
        {
            dg.deinit();
            if (module.methodSlotTarget(cid, slot)) |target| {
                best = if (best) |existing|
                    try module.preferredMethodSlotTarget(allocator, existing, target)
                else
                    target;
            }
            continue;
        }
        for (dg.get().supertype_names) |name| {
            if (runtimeClassDef(self, name)) |parent| try queue.append(allocator, parent);
        }
        dg.deinit();
    }
    return best;
}

fn linkRuntimeVirtualTarget(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    runtime_def: ObjRef(ClassDef),
    slot: MethodSlotId,
) Allocator.Error!?root_mod.ProgramImage.RuntimeVirtualTarget {
    const root_func = funcAt(module, FuncId.from(slot.int())) orelse return null;
    if (try runtimeVirtualOverride(self, allocator, runtime_def, root_func)) |hit| {
        return .{ .side_func = hit };
    }
    if (try runtimeInheritedVirtualTarget(self, allocator, module, runtime_def, slot)) |target| {
        return .{ .main_func = target.int() };
    }
    return null;
}

fn virtualTargetExecutable(module: *const Module, target: FuncId) bool {
    const f = funcAt(module, target) orelse return false;
    return f.hasBody();
}

fn runtimeVirtualTarget(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    runtime_def: ObjRef(ClassDef),
    slot: MethodSlotId,
) Allocator.Error!?root_mod.ProgramImage.RuntimeVirtualTarget {
    const key: root_mod.ProgramImage.RuntimeVirtualKey = .{
        .class_p = runtime_def.identity(),
        .slot = slot.int(),
    };
    if (runtimeVirtualCacheGet(self, key)) |cached| return cached;
    const target = (try linkRuntimeVirtualTarget(self, allocator, module, runtime_def, slot)) orelse return null;
    runtimeVirtualCachePut(self, key, target);
    return target;
}

fn invokeRuntimeVirtualSide(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    receiver: *const Value,
    root: FuncId,
    hit: AnonMethodEntry,
    args: []const Value,
    arg_params: ?[]const u32,
) Allocator.Error!EvalResult {
    if (arg_params) |params| {
        const bound = try host_call_func.bindFuncIndexedArgs(
            self,
            allocator,
            module,
            root,
            root,
            receiver,
            args,
            params,
        );
        switch (bound) {
            .ok => |ordered| {
                defer allocator.free(ordered);
                return invokeAnonMethod(self, allocator, receiver, hit, ordered[1..], receiver.Instance);
            },
            .err => |err| return .{ .err = err },
        }
    }
    return invokeAnonMethod(self, allocator, receiver, hit, args, receiver.Instance);
}

/// Invoke a statically resolved virtual family by numeric slot. The runtime
/// receiver contributes its exact class identity; named and runtime-defined
/// classes both resolve to an O(1) `(class, slot)` target.
pub fn invokeVirtualMember(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    slot: MethodSlotId,
    args: []const Value,
    arg_names: []const ?[]const u8,
    arg_params: ?[]const u32,
) Allocator.Error!EvalResult {
    if (receiver.* != .Instance) {
        if (isCallable(receiver)) {
            const mg = self.module.borrow();
            defer mg.deinit();
            const module = mg.get();
            const root = FuncId.from(slot.int());
            const sig = module.decl_sigs.get(root.int()) orelse
                return .{ .err = .{ .Type = "virtual callable slot has no declaration" } };
            const owner = sig.enclosing_class orelse
                return .{ .err = .{ .Type = "virtual callable slot has no interface owner" } };
            if (sig.has_body or owner.int() >= module.classes.items.len or !module.classes.items[owner.int()].is_interface) {
                return .{ .err = .{ .Type = "virtual call receiver is not an instance" } };
            }
            if (arg_params) |params| {
                return callCallableIndexed(self, allocator, module, root, receiver, receiver, args, params);
            }
            return host_call_value.callValue(self, allocator, receiver, args);
        }
        if (runtime.getenvSlice("KLIO_ERR_TRACE") != null) {
            const mg = self.module.borrow();
            defer mg.deinit();
            const module = mg.get();
            const root = FuncId.from(slot.int());
            const mname: []const u8 = if (module.funcById(root)) |f| f.fqn else "?";
            std.debug.print("[vcall-noinst] slot={d} method={s} recv_tag={s} recv_ty={s} nargs={d}\n", .{ slot.int(), mname, @tagName(std.meta.activeTag(receiver.*)), receiver.typeFqn(), args.len });
        }
        return .{ .err = .{ .Type = "virtual call receiver is not an instance" } };
    }
    const runtime_def = blk: {
        const instance = receiver.Instance.borrow();
        defer instance.deinit();
        break :blk instance.get().class.clone();
    };
    defer runtime_def.deinit();
    const recv_fqn = blk: {
        const class = runtime_def.borrow();
        defer class.deinit();
        break :blk class.get().fqn;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    var linked: root_mod.ProgramImage.RuntimeVirtualTarget = if (module.classIdByFqn(recv_fqn)) |runtime_class|
        .{ .main_func = (module.methodSlotTarget(runtime_class, slot) orelse
            return .{ .err = .{ .Type = "virtual method slot is not linked for receiver class" } }).int() }
    else
        (try runtimeVirtualTarget(self, allocator, module, runtime_def, slot)) orelse
            return .{ .err = .{ .Type = "virtual method slot is not linked for runtime class" } };
    // A runtime-defined or anonymous class can share the source interface's
    // nominal FQN. The main-module table then identifies the correct slot
    // family but lands on its bodyless declaration header; use the runtime
    // class identity to locate the concrete override.
    switch (linked) {
        .main_func => |target| if (!virtualTargetExecutable(module, FuncId.from(target))) {
            linked = (try runtimeVirtualTarget(self, allocator, module, runtime_def, slot)) orelse linked;
        },
        .side_func => {},
    }

    if (linked == .side_func) {
        return invokeRuntimeVirtualSide(
            self,
            allocator,
            module,
            receiver,
            FuncId.from(slot.int()),
            linked.side_func,
            args,
            arg_params,
        );
    }
    const target = FuncId.from(linked.main_func);

    if (arg_params) |params| {
        const sig = module.decl_sigs.get(target.int());
        if (sig != null and !sig.?.has_body) {
            const instance = receiver.Instance.borrow();
            const sam_target = instance.get().get("__sam_target__");
            instance.deinit();
            if (sam_target) |callable| {
                const root = FuncId.from(slot.int());
                return callCallableIndexed(self, allocator, module, root, receiver, &callable, args, params);
            }
        }
        return callFuncIndexedRec(self, allocator, module, target, FuncId.from(slot.int()), receiver, args, params);
    }

    var any_named = false;
    for (arg_names) |name| if (name != null) {
        any_named = true;
        break;
    };

    // A synthetic fun-interface instance implements its abstract slot with
    // the callable stored by SAM conversion, rather than an IR method body.
    if (!any_named) {
        const sig = module.decl_sigs.get(target.int());
        if (sig != null and !sig.?.has_body) {
            const instance = receiver.Instance.borrow();
            const sam_target = instance.get().get("__sam_target__");
            instance.deinit();
            if (sam_target) |callable| {
                return host_call_value.callValue(self, allocator, &callable, args);
            }
        }
    }

    if (!any_named) return (try invokeMethodFuncId(self, allocator, receiver, target, args)) orelse
        .{ .err = .{ .Type = "virtual method target is not executable" } };

    const all = try prependReceiver(allocator, receiver, args);
    defer if (runtime.freeScratch()) allocator.free(all);
    const names = try allocator.alloc(?[]const u8, arg_names.len + 1);
    defer if (runtime.freeScratch()) allocator.free(names);
    names[0] = null;
    @memcpy(names[1..], arg_names);
    return callFuncNamedRec(self, allocator, module, target, all, names);
}

fn invokeMethodFuncId(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, args: []const Value) Allocator.Error!?EvalResult {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const f = funcAt(mod, fid) orelse return null;
    if (runtime.getenvSlice("KLIO_NU_TRACE")) |want| {
        if (std.mem.eql(u8, want, f.name)) {
            std.debug.print("[invoke-method] {s}#{d} params={d} recv={s} args=", .{ f.fqn, fid.int(), f.params.len, receiver.typeFqn() });
            for (args) |a| switch (a) {
                .Int => |v| std.debug.print(" Int({d})", .{v}),
                else => std.debug.print(" {s}", .{@tagName(a)}),
            };
            std.debug.print("\n", .{});
        }
    }

    // A pass-threaded `@Composable` member method re-invoked during recompose
    // (`this.Child($composer, $changed)`) must publish its threaded composer as
    // the ambient composer for the call, exactly like the free-function
    // (`composableEval`) and value-call paths: a `@Composable` property getter
    // reached from the body (e.g. `currentRecomposeScope`) reads it through the
    // `__compose_currentComposer` intrinsic. Initial composition masks the miss
    // because the enclosing composable's composer is still on the stack; a
    // restart re-invocation runs the invalidated scope directly with an empty
    // stack. A member `f.params` carries the receiver as an explicit leading
    // `this` param, while `args` is receiver-excluded — `threadedComposerArg`
    // handles that alignment.
    const threaded_composer: ?Value = if (host_call_func.composePluginEnabled())
        compose.threadedComposerArg(f.params, args)
    else
        null;
    if (threaded_composer) |c| compose.pushComposer(c);
    defer if (threaded_composer != null) compose.popComposer();

    // Non-final vararg (a vararg before trailing defaulted / named-only params):
    // the prepend + trailing-collapse path cannot bind it — the vararg must
    // consume the mid-list positional args at its own position while the
    // trailing parameters take their defaults. Route through the reorder-aware
    // func binder (receiver prepended, all-positional), which handles it.
    if (f.params.len > 1) {
        for (f.params[0 .. f.params.len - 1]) |*p| {
            if (p.is_vararg) {
                const all = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(all);
                return try callFuncNamedRec(self, allocator, mod, fid, all, &.{});
            }
        }
    }

    // Fast path: no vararg tail and the call is fully applied (no default
    // padding), so the frame argument list is exactly `[receiver] ++ args`.
    // Build it in one allocation directly into the frame-owned list, skipping
    // the `prependReceiver` scratch slice + its copy/free (a per-call win on the
    // hot member-dispatch path).
    const has_vararg = f.params.len > 0 and f.params[f.params.len - 1].is_vararg;
    if (!has_vararg and args.len + 1 >= f.params.len) {
        var list: std.ArrayList(Value) = .empty;
        try list.ensureTotalCapacityPrecise(allocator, args.len + 1);
        list.appendAssumeCapacity(receiver.*);
        list.appendSliceAssumeCapacity(args);
        if (trace.invariantsEnabled()) {
            checkFuncInRange(self, "irMethodWalk", f.id);
            checkReceiverChain(self, allocator, "irMethodWalk", receiver, null);
        }
        vmhost.emitPath(allocator, "member_ir_walk", f.fqn, f.id, receiver, args);
        return try ir.eval.evalWith(VmHost, allocator, mod, &f, list, self);
    }

    var all = try prependReceiver(allocator, receiver, args);
    // Kotlin trailing-lambda rule for an under-applied member call: the final
    // supplied callable binds the LAST function-typed parameter, with the
    // intervening defaulted parameters filled from their defaults rather than
    // bound left-to-right. `padArgsWithDefaults` fills positionally (lambda →
    // first gap param), so route this shape through the shared positional
    // binder, which implements the rule uniformly (and varargs/defaults).
    if (all.len < f.params.len and all.len != 0 and
        isFunctionTypeRefResolved(self, &f.params[f.params.len - 1].ty) and
        isCallable(&all[all.len - 1]) and (all.len - 1) < (f.params.len - 1))
    {
        if (trailing_member_call) host_call_func.setTrailingLambdaCall(true);
        const r = try callFuncRec(self, allocator, mod, fid, all);
        host_call_func.setTrailingLambdaCall(false);
        if (runtime.freeScratch()) allocator.free(all);
        return r;
    }
    const defaults = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (pg.get().func_defaults.get(@intFromEnum(fid))) |d| break :blk try allocator.dupe(?FuncId, d);
        break :blk null;
    };
    defer if (defaults) |d| if (runtime.freeScratch()) allocator.free(d);
    if (defaults != null and all.len < f.params.len) {
        const padded = try padArgsWithDefaults(self, allocator, mod, f.params.len, all, defaults);
        switch (padded) {
            .ok => |p| {
                if (runtime.freeScratch()) allocator.free(all);
                all = p;
            },
            .err => |e| {
                if (runtime.freeScratch()) allocator.free(all);
                return .{ .err = e };
            },
        }
    }
    const packed_args = try packVarargArgs(self, allocator, &f, all);
    var packed_list = try argsListFromSlice(allocator, packed_args);
    if (runtime.freeScratch()) allocator.free(packed_args);
    _ = &packed_list;
    if (trace.invariantsEnabled()) {
        checkFuncInRange(self, "irMethodWalk", f.id);
        checkReceiverChain(self, allocator, "irMethodWalk", receiver, null);
    }
    vmhost.emitPath(allocator, "member_ir_walk", f.fqn, f.id, receiver, args);
    return try ir.eval.evalWith(VmHost, allocator, mod, &f, packed_list, self);
}

/// Build the inline-cache key for an instance method call, or `null` for a
/// non-Instance receiver. Keyed by class-cell identity + interned method-name
/// pointer + arity (all stable for the program lifetime).
/// Compact signature of an argument run's primitive types, distinguishing the
/// overloads a method-name resolution can depend on. Returns null for a
/// non-primitive arg (or > 12 args), which means "do not cache this call" — the
/// resolution then re-runs each time rather than risk a wrong cross-type hit.
fn methodArgSig(args: []const Value) ?u64 {
    if (args.len == 0) return 0;
    if (args.len > 12) return null;
    // Hash a per-arg type discriminator. Primitives contribute their tag;
    // an `Instance` also folds in its class identity, so an overload picked
    // by the argument's class (`LocalDate.plus(DatePeriod)` vs
    // `LocalDate.plus(DateTimeUnit)`) gets a distinct, cacheable key rather
    // than the pre-hash scheme's "non-primitive → no key" bail. Any other
    // value shape yields no key (that call re-resolves) so the cache never
    // conflates argument types the overload dispatch would distinguish.
    var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15 +% args.len);
    for (args) |*a| {
        const tag: u8 = switch (a.*) {
            .Int => 1,
            .Long => 2,
            .Double => 3,
            .Float => 4,
            .Short => 5,
            .Byte => 6,
            .Char => 7,
            .Bool => 8,
            .UInt => 9,
            .ULong => 10,
            .UShort => 11,
            .UByte => 12,
            .Instance => 13,
            // A `String` is always `kotlin.String` and a `Unit` always
            // `kotlin.Unit`: their runtime shape fully fixes the type the
            // overload walk sees, so folding a stable tag is sound and keeps
            // the common String-argument calls (pervasive on the coroutine
            // resume path) on the inline-cache fast path. `Null` stays
            // uncacheable — it matches any nullable parameter, so its
            // resolution is not a pure function of the value shape.
            .String => 14,
            .Unit => 15,
            else => return null,
        };
        h.update((&tag)[0..1]);
        if (a.* == .Instance) {
            const g = a.Instance.borrow();
            const id = g.get().class.identity();
            g.deinit();
            h.update(std.mem.asBytes(&id));
        }
    }
    const v = h.final();
    // 0 is reserved for the empty-arg case; the key also carries `n_args`,
    // so a non-empty sig colliding to 0 stays distinct from `args.len == 0`.
    return if (v == 0) 1 else v;
}

fn instanceMethodKey(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value) ?root_mod.ProgramImage.InstanceMethodKey {
    return instanceMethodKeyScoped(self, receiver, name, args, null, null);
}

/// Scope-aware cache key. A `static_recv`/`declared_recv`-directed call
/// resolves in the STATIC type's scope, not the runtime class's, so its
/// resolution must never be conflated with the unscoped one — `Map.getOrElse`'s
/// inlined `get` must not be served a cached subtype `get<T>` (which
/// self-recurses), nor vice versa. Folding the scope names into `sig` keeps
/// both resolutions cached under distinct keys; resolution is a pure function
/// of (class, name, arg-sig, scope), so each entry stays sound.
fn instanceMethodKeyScoped(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8, declared_recv: ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    if (receiver.* != .Instance) return null;
    var sig = methodArgSig(args) orelse return null;
    if (static_recv != null or declared_recv != null) {
        var h = std.hash.Wyhash.init(0x517cc1b727220a95);
        if (static_recv) |s| h.update(s);
        h.update(&[_]u8{0});
        if (declared_recv) |d| h.update(d);
        sig ^= h.final();
        // Keep 0 reserved for the unscoped empty-arg case.
        if (sig == 0) sig = 1;
    }
    const inst = receiver.Instance;
    const g = inst.borrow();
    defer g.deinit();
    const name_p = memberNameIdentity(self, name) orelse return null;
    return .{
        .class_p = g.get().class.identity(),
        .name_p = name_p,
        .n_args = @intCast(args.len),
        .sig = sig,
    };
}

/// Sentinel cache value: this (class, name, arg-sig) is known to resolve to NO
/// user instance method, so the next call skips the resolution walk and falls
/// straight to the stdlib/extension/field paths. Sound because the resolution is
/// a pure function of the key (classes are static).
const METHOD_MISS: u32 = std.math.maxInt(u32);

fn instanceMethodCacheGetRaw(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey) ?u32 {
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().instance_method_cache.get(key);
}

fn instanceMethodCachePutRaw(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey, raw: u32) void {
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().instance_method_cache.put(key, raw) catch {};
}

fn extMethodCacheGet(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey) ?u32 {
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().ext_method_cache.get(key);
}

fn extMethodCachePut(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey, fid: u32) void {
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().ext_method_cache.put(key, fid) catch {};
}

fn instanceIntrinsicCacheGet(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey) ?root_mod.ProgramImage.MemberResolveEntry {
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().instance_intrinsic_cache.get(key);
}

/// Simple name of the class that DECLARES `fid` in `module`'s class table,
/// memoized per `(module, FuncId)`. An instance method's implicit-`this` bare
/// call resolves against its declaring class's static member scope (Kotlin), so
/// dispatch needs this static type; the this-param's nominal type is a
/// placeholder that cannot serve it. `null` when no class owns the func.
pub fn declaringClassSimpleName(self: *VmHost, module: *const Module, fid: FuncId) ?[]const u8 {
    const key = root_mod.ProgramImage.FuncOwnerKey{ .module_p = @intFromPtr(module), .func_p = @intFromEnum(fid) };
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (pg.get().func_owner_class_cache.get(key)) |hit| return hit;
    }
    var owner: ?[]const u8 = null;
    for (module.classes.items) |*c| {
        for (c.methods) |mfid| {
            if (@intFromEnum(mfid) == @intFromEnum(fid)) {
                owner = c.name;
                break;
            }
        }
        if (owner != null) break;
    }
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().func_owner_class_cache.put(key, owner) catch {};
    return owner;
}

/// Memoize the `instanceBindingProbe` outcome for `key`. `func == null` caches
/// "no intrinsic" so the next call returns immediately without rebuilding the
/// probe FQNs or walking the supertype chain. The `fqn` (the winning probe, or
/// "" for a miss) is duped into the image-owned allocator on first store.
fn instanceIntrinsicCachePut(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey, func: ?StdlibFn, fqn: []const u8) void {
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    const cache = &pg.get().instance_intrinsic_cache;
    if (cache.contains(key)) return;
    const owned: []const u8 = if (fqn.len == 0) "" else (pg.get().allocator.dupe(u8, fqn) catch return);
    cache.put(key, .{ .func = func, .fqn = owned }) catch {
        if (owned.len != 0) pg.get().allocator.free(owned);
    };
}

fn irMethodWalk(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8) Allocator.Error!?EvalResult {
    // Inline cache: memoize the (class, method-name, arg-type-signature) →
    // FuncId resolution. The signature captures the argument primitive types the
    // overload pick depends on, so a hit returns the same target the full walk
    // would (a non-primitive arg yields no key, so those calls re-resolve rather
    // than risk a wrong cross-type hit). Only an unambiguous resolution is
    // cached; a call that declines to an extension is never stored. The fast
    // path at `callMemberInnerStatic`'s entry consults this same cache before the
    // probe ladder, so a repeat call skips the binding/builtin probes too.
    //
    // A `static_recv`-directed call keys with the scope folded in (see
    // `instanceMethodKeyScoped`): its resolution depends on the static receiver
    // type, so it caches apart from the ordinary call's entry — never served
    // one, never serves one.
    const key = instanceMethodKeyScoped(self, receiver, name, args, static_recv, null);
    if (key) |k| {
        if (instanceMethodCacheGetRaw(self, k)) |raw| {
            if (raw == METHOD_MISS) return null;
            return try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(raw), args);
        }
    }
    const resolved = (try resolveInstanceMethod(self, allocator, receiver, name, args, static_recv)) orelse {
        // Cache the miss: a member-accessed field (`obj.field`) re-runs this
        // walk every read otherwise. Only a proven, key-stable miss is stored.
        if (key) |k| instanceMethodCachePutRaw(self, k, METHOD_MISS);
        return null;
    };
    if (resolved.unambiguous) {
        if (key) |k| instanceMethodCachePutRaw(self, k, @intFromEnum(resolved.fid));
    }
    return try invokeMethodFuncId(self, allocator, receiver, resolved.fid, args);
}

/// A SAM-converted `Sequence { ... }` / `Iterable { ... }` instance: its
/// `iterator` is served through `__sam_target__` rather than an IR
/// method, so `hostHasMember(.., "iterator")` cannot see it. The
/// iterable fallback drains these like any other iterator-bearing
/// instance.
fn samIterableInstance(self: *VmHost, allocator: Allocator, receiver: *const Value) bool {
    const class_name = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        // A SAM conversion carries the lambda under `__sam_target__`; a
        // lowered fun-interface object carries `iterator` as a callable
        // field; a full anon `object : Sequence<T>` registers `iterator`
        // in the anon-method table. Any of them can be drained.
        if (g.get().get("__sam_target__") != null) break :blk null;
        if (g.get().get("iterator")) |f| {
            if (isCallable(&f)) break :blk null;
        }
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    const cn = class_name orelse return true;
    return lookupAnonMethod(self, allocator, cn, "iterator/0", "iterator") != null;
}

fn anyInstanceFallback(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    if (args.len == 0 and std.mem.eql(u8, name, "toString")) {
        if (instanceIsThrowable(self, allocator, inst)) {
            return .{ .ok = try inheritedInstanceToString(allocator, inst, true) };
        }
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        defer {
            cg.deinit();
            g.deinit();
        }
        if (cg.get().is_enum) {
            if (g.get().get("name")) |nv| {
                if (nv == .String) {
                    // Borrowed instance field escaping through callMember.
                    nv.retain();
                    return .{ .ok = nv };
                }
            }
        }
        if (cg.get().is_object) {
            return .{ .ok = try strVal(allocator, cg.get().name) };
        }
        if (cg.get().is_data) {
            return .{ .ok = try renderStructuralLocked(allocator, g.get(), cg.get()) };
        }
        const s = try std.fmt.allocPrint(allocator, "{s}@{x}", .{ cg.get().fqn, g.get().identity });
        return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, s) } };
    }
    if (args.len == 0 and std.mem.eql(u8, name, "hashCode")) {
        const g = inst.borrow();
        // A data/value class without a hashCode override hashes
        // structurally, not by identity — a value class implementing an
        // interface that redeclares hashCode still has value semantics.
        const structural = blk: {
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk cg.get().is_data or cg.get().is_value;
        };
        g.deinit();
        if (structural) {
            return .{ .ok = .{ .Int = kotlinHashCode(receiver) } };
        }
        const g2 = inst.borrow();
        defer g2.deinit();
        return .{ .ok = Value.newInt(@bitCast(g2.get().identity)) };
    }
    if (args.len == 1 and std.mem.eql(u8, name, "equals")) {
        // A user `Map.Entry` implementation with no `equals` override follows
        // the `Map.Entry` contract: equal iff keys and values are equal,
        // regardless of the other operand's concrete type (a builtin
        // `MapEntry` or another `Map.Entry` instance).
        if (Value.mapEntryContractEq(receiver, &args[0])) |eq| {
            return .{ .ok = boolVal(eq) };
        }
        // Data/value classes compare structurally even when an interface
        // in their hierarchy redeclares equals (ValueTimeMark).
        {
            const g = inst.borrow();
            const cg = g.get().class.borrow();
            const structural = cg.get().is_data or cg.get().is_value;
            cg.deinit();
            g.deinit();
            if (structural) {
                return .{ .ok = boolVal(try dataValueInstanceEquals(self, allocator, inst, &args[0])) };
            }
        }
        if (args[0] == .Instance) {
            return .{ .ok = boolVal(ObjRef(InstanceData).ptrEq(inst, args[0].Instance)) };
        }
        return .{ .ok = boolVal(false) };
    }
    return null;
}

fn renderStructuralLocked(allocator: Allocator, inst: *const InstanceData, cls: *const ClassDef) Allocator.Error!Value {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, classDisplayName(cls.name));
    try buf.append(allocator, '(');
    for (cls.primary_params, 0..) |p, idx| {
        if (idx > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, p.name);
        try buf.append(allocator, '=');
        const v = inst.get(p.name) orelse Value.Null;
        try buf.appendSlice(allocator, try v.display(allocator));
    }
    try buf.append(allocator, ')');
    return .{ .String = try runtime.strInitOwned(allocator, try buf.toOwnedSlice(allocator)) };
}

/// Format `"{prefix}.{name}"` into `buf` (stack scratch), returning the slice.
/// Probe FQNs are short and bounded, so this avoids the per-call heap churn of
/// `allocPrint` — member dispatch builds up to ~6 of these on every call.
inline fn probeFqn(buf: []u8, prefix: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ prefix, name }) catch buf[0..0];
}

/// Whether the call selects a DECLARED lambda-taking overload the
/// member-form intrinsic cannot represent: the last arg is callable, a
/// body-bearing receiver-formed declaration named `name` fits the call
/// arity exactly with a function-typed last parameter, AND a shorter
/// non-lambda sibling declaration also exists (the shape the intrinsic
/// actually implements — `copyOf(newSize)` vs
/// `copyOf(newSize, init)`). Without the sibling requirement every HOF
/// intrinsic (`map`, `filter`) would fall off its fast path.
/// Element kinds whose arithmetic differs per declared width — the only
/// erased receiver-type-arg ties resolution must refuse to guess.
fn numericWidthKind(name: []const u8) bool {
    const kinds = [_][]const u8{
        "Int",  "Long",  "Short",  "Byte",  "Double", "Float",
        "UInt", "ULong", "UShort", "UByte", "Char",
    };
    for (kinds) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
}

fn declaredLambdaOverloadWins(self: *VmHost, name: []const u8, args: []const Value) bool {
    if (args.len == 0 or !isCallable(&args[args.len - 1])) return false;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    var lambda_exact = false;
    var shorter_plain = false;
    for (mod.funcsBySimpleName(name)) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        if (!(f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this"))) continue;
        const last_is_fn = std.mem.startsWith(u8, f.params[f.params.len - 1].ty.name, "Function");
        if (f.hasBody() and f.params.len == args.len + 1 and last_is_fn) {
            lambda_exact = true;
        }
        if (f.params.len < args.len + 1 and (f.params.len == 1 or !last_is_fn)) {
            shorter_plain = true;
        }
        if (lambda_exact and shorter_plain) return true;
    }
    return false;
}

threadlocal var charseq_fallback_active: bool = false;

/// Whether the instance's class chain implements `CharSequence`.
fn instanceImplementsCharSequence(self: *VmHost, receiver: *const Value) bool {
    if (receiver.* != .Instance) return false;
    const cname = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.class_super_names.get(cname)) |chain| {
        for (chain) |sup| {
            if (std.mem.eql(u8, sup, "CharSequence")) return true;
        }
    }
    return false;
}

/// Whether the instance's class (or its recorded supertype chain)
/// implements `Sequence` — such receivers keep sequence laziness.
fn instanceImplementsSequence(self: *VmHost, receiver: *const Value) bool {
    if (receiver.* != .Instance) return false;
    const cname = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.class_super_names.get(cname)) |chain| {
        for (chain) |sup| {
            if (std.mem.eql(u8, sup, "Sequence")) return true;
        }
    }
    return false;
}

/// Whether a declared extension with receiver type `Sequence` and a real
/// body exists for `name` — the lazy source implementation that must win
/// over eager collection intrinsics for Sequence receivers.
fn declaredSequenceExtBody(self: *VmHost, name: []const u8) bool {
    return sequenceExtBodyFid(self, name, null) != null;
}

/// The declared Sequence-receiver extension with a body for `name` whose
/// arity accepts `n_args` value arguments (receiver excluded); any arity
/// when `n_args` is null.
fn sequenceExtBodyFid(self: *VmHost, name: []const u8, n_args: ?usize) ?FuncId {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    var best: ?FuncId = null;
    for (mod.funcsBySimpleName(name)) |fid| {
        const sig = mod.decl_sigs.get(fid.int()) orelse continue;
        const rt = sig.receiver_ty orelse continue;
        if (!std.mem.eql(u8, rt.name, "Sequence")) continue;
        const f = mod.funcById(fid) orelse continue;
        // Headers decode lazily: judge executability by the settled form
        // (body, sibling redirect, or native binding), not hasBody().
        if (n_args) |n| {
            if (!host_call_func.executableForm(self, mod, fid, n + 1)) continue;
            // DeclSig arity counts value params only (receiver excluded).
            if (n < sig.arity.required) continue;
            if (n > sig.arity.total and !sig.arity.has_vararg) continue;
            if (best == null or f.params.len < (mod.funcById(best.?) orelse f).params.len) best = fid;
        } else {
            if (!host_call_func.executableForm(self, mod, fid, sig.arity.required + 1)) continue;
            return fid;
        }
    }
    return best;
}

fn stdlibMemberDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    // A declared lambda-taking overload the intrinsic surface cannot
    // express wins resolution; decline so the walk's extension fallback
    // runs its body (declaration decides, the registry only serves).
    if (declaredLambdaOverloadWins(self, name, args)) return null;
    const type_fqn = receiver.typeFqn();
    // Resolution cache: for a non-`Instance`, non-array-builder receiver, the
    // winning intrinsic (or "none") is a pure function of (type, name,
    // args-empty), so memoize it and skip the per-call probe building + repeated
    // `lookupIntrinsic` borrows. Instance receivers vary by `hostHasMember` per
    // instance and are not cached; array builders use a different (no-prepend)
    // dispatch and are excluded.
    const cacheable = receiver.* != .Instance and !stdlib.isArrayBuilder(name) and
        !(try userToplevelExtNamedExists(self, allocator, receiver, name));
    if (cacheable) {
        const name_p = memberNameIdentity(self, name) orelse
            return try stdlibMemberDispatchUncached(self, allocator, receiver, name, args, type_fqn, null);
        const key: root_mod.ProgramImage.MemberResolveKey = .{
            .type_p = @intFromPtr(type_fqn.ptr),
            .name_p = name_p,
            .args_empty = args.len == 0,
        };
        const hit: ?root_mod.ProgramImage.MemberResolveEntry = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().member_resolve_cache.get(key);
        };
        if (hit) |entry| {
            const func = entry.func orelse return null;
            return try dispatchWithReceiver(self, allocator, entry.fqn, func, receiver, args);
        }
        return try stdlibMemberDispatchUncached(self, allocator, receiver, name, args, type_fqn, key);
    }
    return try stdlibMemberDispatchUncached(self, allocator, receiver, name, args, type_fqn, null);
}

fn stdlibMemberDispatchUncached(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, type_fqn: []const u8, cache_key: ?root_mod.ProgramImage.MemberResolveKey) Allocator.Error!?EvalResult {
    // A Sequence receiver with a DECLARED Sequence-receiver extension body
    // must run that lazy source implementation — the package probes below
    // would bind an eager collection intrinsic (`kotlin.collections.chunked`
    // materializes the receiver, breaking Kotlin's sequence laziness).
    // Terminal names never reach here (the sequence arm handles them).
    if (receiver.* == .Sequence and declaredSequenceExtBody(self, name)) return null;
    // Probe FQNs in priority order, formatted into per-call stack buffers (no
    // heap traffic). `kotlin.<name>` etc. are formatted too so one code path
    // builds them all; the storage outlives the loop below.
    var bufs: [8][128]u8 = undefined;
    var probes: [8][]const u8 = undefined;
    // Which probes name a MEMBER of the receiver's type (keyed by the type's
    // FQN) rather than one of the stdlib's package-level EXTENSIONS. Kotlin
    // resolves a member before any extension, so a user extension shadows the
    // extension probes and never the member ones.
    var probe_is_member: [8]bool = @splat(false);
    var n: usize = 0;
    const type_probe = probeFqn(&bufs[0], type_fqn, name);
    if (args.len == 0) {
        probes[0] = type_probe;
        probe_is_member[0] = true;
        probes[1] = probeFqn(&bufs[1], "kotlin.collections", name);
        probes[2] = probeFqn(&bufs[2], "kotlin.text", name);
        probes[3] = probeFqn(&bufs[3], "kotlin.ranges", name);
        probes[4] = probeFqn(&bufs[4], "kotlin", name);
        n = 5;
    } else {
        probes[0] = probeFqn(&bufs[0], "kotlin.ranges", name);
        probes[1] = probeFqn(&bufs[1], "kotlin.collections", name);
        probes[2] = probeFqn(&bufs[2], "kotlin.text", name);
        probes[3] = probeFqn(&bufs[3], type_fqn, name);
        probe_is_member[3] = true;
        probes[4] = probeFqn(&bufs[4], "kotlin", name);
        n = 5;
    }
    // Sibling read-only/mutable collection type, inserted right after the
    // receiver-type probe so a `MutableList` op can resolve a `List`-declared
    // intrinsic (and vice versa).
    const sibling: ?[]const u8 = blk: {
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.MutableList")) break :blk "kotlin.collections.List";
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.MutableSet")) break :blk "kotlin.collections.Set";
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.MutableMap")) break :blk "kotlin.collections.Map";
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.List")) break :blk "kotlin.collections.MutableList";
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.Set")) break :blk "kotlin.collections.MutableSet";
        if (std.mem.eql(u8, type_fqn, "kotlin.collections.Map")) break :blk "kotlin.collections.MutableMap";
        break :blk null;
    };
    if (sibling) |sib| {
        const sib_probe = probeFqn(&bufs[5], sib, name);
        // Find the receiver-type probe and insert the sibling right after it.
        var at: usize = n;
        for (probes[0..n], 0..) |p, idx| {
            if (std.mem.eql(u8, p, type_probe)) {
                at = idx + 1;
                break;
            }
        }
        var k: usize = n;
        while (k > at) : (k -= 1) {
            probes[k] = probes[k - 1];
            probe_is_member[k] = probe_is_member[k - 1];
        }
        probes[at] = sib_probe;
        probe_is_member[at] = true;
        n += 1;
    }
    // Throwable family probe.
    if (receiver.* == .Instance) {
        if (instanceIsThrowable(self, allocator, receiver.Instance)) {
            probes[n] = probeFqn(&bufs[6], "kotlin.Throwable", name);
            probe_is_member[n] = true;
            n += 1;
        }
    }

    const member_shadows_stdlib = receiver.* == .Instance and hostHasMember(self, receiver, name);
    const user_member_ext_shadows = try userMemberExtShadows(self, allocator, receiver, name, args.len);
    // Scope-aware pack-extension shadowing: an in-scope (imported) pack
    // extension outranks the implicit stdlib surface for this call site;
    // a merely-POTENTIAL one makes the resolution file-dependent, so the
    // (type, name) memoization below must stand down.
    const pack_ext_shadow = try importedPackExtShadows(self, allocator, receiver, name, args.len);
    const effective_cache_key: ?root_mod.ProgramImage.MemberResolveKey =
        if (pack_ext_shadow == .none) cache_key else null;
    // `range in range`: the builtin `Range.contains` intrinsic takes an
    // ELEMENT, so a Range argument is inapplicable to every probe the
    // ladder could hit — leave it for the extension fallback, where a
    // range-over-range operator (`LongRange.contains(LongRange)`) binds.
    const range_in_range = receiver.* == .Range and args.len == 1 and
        args[0] == .Range and std.mem.eql(u8, name, "contains");

    // Array builder global factory direct dispatch.
    if (stdlib.isArrayBuilder(name) and !hostHasMember(self, receiver, name)) {
        const probe = probeFqn(&bufs[7], "kotlin", name);
        if (lookupIntrinsic(self, probe)) |func| {
            return try dispatchIntrinsic(self, allocator, probe, func, args);
        }
    }

    if (!member_shadows_stdlib and !user_member_ext_shadows and !range_in_range and
        pack_ext_shadow != .shadows and
        !stdlib.isToplevelFunction(name))
    {
        // A user extension shadows the stdlib's EXTENSIONS — but never its
        // MEMBERS. Kotlin resolves a member first, so `fun Long.toInt(): Int`
        // does not capture `7L.toInt()`; the member does, and the extension's
        // own `this.toInt()` reaches it (rather than calling itself for ever).
        const user_ext_shadows = try userToplevelExtShadows(self, allocator, receiver, name, args);
        for (probes[0..n], probe_is_member[0..n]) |probe, is_member| {
            if (user_ext_shadows and !is_member) continue;
            // A member outranks an extension only while its host binding is
            // applicable. Intrinsics whose Kotlin declarations are pruned
            // from the runtime image carry this small predicate alongside
            // the binding, so `Int.or(Int)` cannot capture the distinct
            // `Int.or(NodeKind)` overload.
            if (user_ext_shadows and is_member) {
                if (stdlib.implementationApplicable(probe, args)) |applies| {
                    if (!applies) continue;
                }
            }
            if (lookupIntrinsic(self, probe)) |func| {
                if (effective_cache_key) |key| memberCachePut(self, key, func, probe);
                return try dispatchWithReceiver(self, allocator, probe, func, receiver, args);
            }
        }
    }
    // No intrinsic resolved: memoize the miss so the next identical call skips
    // the probe build + lookups and falls straight through to extension/global.
    if (effective_cache_key) |key| memberCachePut(self, key, null, "");
    return null;
}

/// Store a member-resolution result on the shared program image. `func == null`
/// records a confirmed miss; a non-empty `fqn` is duped into the program's
/// allocator (lives for the program; bounded by distinct resolved members).
fn memberCachePut(self: *VmHost, key: root_mod.ProgramImage.MemberResolveKey, func: ?StdlibFn, fqn: []const u8) void {
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    const cache = &pg.get().member_resolve_cache;
    if (cache.contains(key)) return;
    const stored_fqn: []const u8 = if (func != null and fqn.len != 0)
        (cache.allocator.dupe(u8, fqn) catch return)
    else
        "";
    cache.put(key, .{ .func = func, .fqn = stored_fqn }) catch {
        if (stored_fqn.len != 0) cache.allocator.free(stored_fqn);
    };
}

/// `Throwable.printStackTrace()` / `.stackTraceToString()` rendered from the
/// stack captured at throw time. Returns null for a name these do not handle or
/// a receiver that is not a throwable, so normal dispatch proceeds.
fn throwableStackMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    if (args.len != 0) return null;
    const is_print = std.mem.eql(u8, name, "printStackTrace");
    const is_tostr = std.mem.eql(u8, name, "stackTraceToString");
    const is_elems = std.mem.eql(u8, name, "getStackTrace") or std.mem.eql(u8, name, "stackTrace");
    if (!is_print and !is_tostr and !is_elems) return null;

    switch (receiver.*) {
        .Exception => {},
        .Instance => |inst| {
            if (!instanceIsThrowable(self, allocator, inst)) return null;
        },
        else => return null,
    }
    if (is_elems) {
        return .{ .ok = (try ir.eval.stackTraceArray(allocator, receiver)) orelse runtime.ArrayData.fromBoxedList(try runtime.ValueList.initOwned(allocator, .empty)) };
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try ir.eval.formatThrowable(allocator, receiver, &buf, false, 0);
    if (is_print) {
        std.debug.print("{s}\n", .{buf.items});
        return .{ .ok = .Unit };
    }
    // Adopt a private copy: `buf` is freed on return, and `strInit`'s
    // arena fast path would otherwise alias (then dangle) `buf.items`.
    const owned = try allocator.dupe(u8, buf.items);
    return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, owned) } };
}

/// `addSuppressed`/`getSuppressed` on an INTERPRETED throwable instance. The
/// suppressed list lives in a hidden `__suppressed__` field on the instance
/// (a user throwable is a plain Instance until thrown), so every alias of
/// the instance observes the same set. Host `Exception` values carry their
/// list in the value itself and dispatch through the stdlib binding instead.
fn throwableSuppressedMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const is_add = std.mem.eql(u8, name, "addSuppressed") and args.len == 1;
    const is_get = std.mem.eql(u8, name, "getSuppressed") and args.len == 0;
    if (!is_add and !is_get) return null;
    const inst = switch (receiver.*) {
        .Instance => |i| i,
        else => return null,
    };
    {
        const g = inst.borrow();
        defer g.deinit();
        const declared = g.get().get(name) != null;
        if (declared) return null;
    }
    if (!instanceIsThrowable(self, allocator, inst)) return null;
    if (is_get) {
        const cur = instanceSuppressedList(inst);
        if (cur) |l| return .{ .ok = l };
        const items = try runtime.ValueList.init(allocator, .empty);
        return .{ .ok = .{ .List = .{ .items = items, .mutable = false, .backing = null } } };
    }
    try appendInstanceSuppressed(inst, allocator, args[0]);
    return .{ .ok = .Unit };
}

/// The instance's `__suppressed__` list value, if one was created.
pub fn instanceSuppressedList(inst: ObjRef(InstanceData)) ?Value {
    const g = inst.borrow();
    defer g.deinit();
    const v = g.get().get("__suppressed__") orelse return null;
    if (v != .List) return null;
    return v;
}

/// Append to the instance's hidden suppressed list, creating it on first use.
pub fn appendInstanceSuppressed(inst: ObjRef(InstanceData), allocator: Allocator, e: Value) Allocator.Error!void {
    const list: Value = blk: {
        if (instanceSuppressedList(inst)) |l| break :blk l;
        const items = try runtime.ValueList.init(allocator, .empty);
        const fresh = Value{ .List = .{ .items = items, .mutable = true, .backing = null } };
        const g = inst.borrowMut();
        defer g.deinit();
        try g.get().define(allocator, "__suppressed__", fresh);
        break :blk fresh;
    };
    const g = list.List.items.borrowMut();
    defer g.deinit();
    if (runtime.reclaimEnabled()) e.retain();
    try g.get().append(allocator, e);
}

pub fn instanceIsThrowable(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData)) bool {
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        stack.append(allocator, cg.get().name) catch return false;
        cg.deinit();
        g.deinit();
    }
    while (stack.pop()) |cn| {
        if (seen.contains(cn)) continue;
        seen.put(cn, {}) catch {};
        if (std.mem.eql(u8, cn, "Throwable") or std.mem.eql(u8, cn, "Exception") or
            std.mem.eql(u8, cn, "RuntimeException") or std.mem.eql(u8, cn, "Error") or
            std.mem.eql(u8, cn, "CancellationException")) return true;
        const cg = self.classes.borrow();
        if (cg.get().get(cn)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |s| stack.append(allocator, s) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

fn inheritedInstanceToString(allocator: Allocator, inst: ObjRef(InstanceData), is_throwable: bool) Allocator.Error!Value {
    const ig = inst.borrow();
    defer ig.deinit();
    const cg = ig.get().class.borrow();
    const fqn = cg.get().fqn;
    cg.deinit();
    if (is_throwable) {
        const msg: ?[]const u8 = if (ig.get().get("message")) |mv| switch (mv) {
            .String => |s| blk: {
                const sg = s.borrow();
                defer sg.deinit();
                break :blk try allocator.dupe(u8, sg.get().bytes);
            },
            else => null,
        } else null;
        const rendered = if (msg) |m|
            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ fqn, m })
        else
            try allocator.dupe(u8, fqn);
        return .{ .String = try runtime.strInitOwned(allocator, rendered) };
    }
    const rendered = try std.fmt.allocPrint(allocator, "{s}@{x}", .{ fqn, ig.get().identity });
    return .{ .String = try runtime.strInitOwned(allocator, rendered) };
}

/// Whether `fid` is a member extension. Authoritative via the func's
/// first-class `kind`; the `member_ext_owner_class` side table carries the
/// owner-gating data (the kind selects which funcs are gated, the side
/// table says by which owner class).
fn isMemberExt(mod: *const Module, fid: FuncId) bool {
    if (funcAt(mod, fid)) |f| return f.kind == .member_extension;
    return false;
}

/// Member-extension visibility gate: a member-extension `fid` is visible
/// at a call site only when its declaring (owner) class is reachable
/// through `visible_owners`. Non-member-extensions are unconditionally
/// visible (this function gates nothing for them). Preserves the prior
/// `member_ext_owner_class.get(fid)`-then-`visible_owners.contains(owner)`
/// behavior exactly: the kind selects the gated funcs, the side table
/// supplies the owner.
/// Whether `fid` is a FILE-PRIVATE top-level function whose declaring file
/// is not the currently executing frame's file — Kotlin scopes a private
/// top-level declaration to its file, so such a candidate is invisible here
/// (a file-private `Rect.size()` must never capture `changes.size()`).
fn privateFnHiddenHere(self: *VmHost, mod: *const Module, fid: FuncId) bool {
    _ = self;
    const decl_file = mod.registry.private_fn_files.get(fid) orelse return false;
    // A dispatching bound reference carries its creation-site file; the
    // reference site, not the dynamic caller, decides private visibility.
    if (ir.eval.refSiteFile()) |f| return f.int() != decl_file.int();
    const sp = ir.eval.currentCallSiteSpan() orelse return false;
    return sp.file.int() != decl_file.int();
}

/// A bound reference's creation-site file (`__bound_file__`), if recorded
/// on its synth instance. The invoke arms re-install it around their
/// by-name dispatch via `ir.eval.pushRefSiteFile`.
pub fn boundRefFile(callee: *const Value) ?ir.FileId {
    if (callee.* != .Instance) return null;
    const g = callee.Instance.borrow();
    defer g.deinit();
    const v = g.get().get("__bound_file__") orelse return null;
    if (v != .Int) return null;
    return ir.FileId.from(@intCast(v.Int));
}

fn memberExtVisible(self: *VmHost, mod: *const Module, fid: FuncId, visible_owners: *const std.StringHashMap(void)) bool {
    if (!isMemberExt(mod, fid)) return true;
    const owner = mod.registry.member_ext_owner_class.get(fid) orelse return true;
    if (runtime.getenvSlice("KLIO_NU_TRACE")) |want| {
        if (funcAt(mod, fid)) |f| {
            if (std.mem.eql(u8, f.name, want) or std.mem.eql(u8, want, "1")) {
                std.debug.print("[mev] fid={d} owner={s} vis={}\n", .{ fid.int(), owner, visible_owners.contains(owner) });
                var it = visible_owners.keyIterator();
                std.debug.print("[mev] set:", .{});
                while (it.next()) |k| std.debug.print(" {s}", .{k.*});
                std.debug.print("\n", .{});
            }
        }
    }
    if (visible_owners.contains(owner)) return true;
    // An interface implementation is not an importable extension. `private object
    // EmptyMeasurePolicy : MeasurePolicy { override fun MeasureScope.measure(…) }`
    // declares an interface method body, reachable only with the object as the
    // dispatch receiver -- never by name from an unrelated site. Letting the
    // singleton hatch below hand it out made EVERY `with(policy) { measure(…) }`
    // run `BasicText`'s policy, which sizes to the incoming constraints: a text
    // field then measured itself to the unbounded scroll height.
    if (implementsSupertypeMemberExt(self, mod, owner, fid)) return false;
    // A member extension declared in an `object`/companion is callable
    // wherever the singleton is importable (`import C.Companion.f`): its
    // dispatch receiver is the singleton itself, which is always
    // materializable, so the enclosing-`this` chain need not carry it.
    return ownerIsObjectSingleton(self, owner);
}

/// Whether `owner`'s member extension `fid` implements a same-named member
/// extension declared by one of `owner`'s supertypes -- i.e. it is an interface
/// method body, not an importable extension. `object EmptyMeasurePolicy :
/// MeasurePolicy` overriding `MeasureScope.measure` is the shape: the only way to
/// reach it is with the object as the dispatch receiver.
///
/// Read off the supertypes rather than an `override` modifier: the lowering does
/// not carry the modifier this far, and a supertype declaration is what `override`
/// means anyway.
fn implementsSupertypeMemberExt(self: *VmHost, mod: *const Module, owner: []const u8, fid: FuncId) bool {
    const f = funcAt(mod, fid) orelse return false;
    const sups: []const []const u8 = blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        const d = g.get().get(owner) orelse break :blk &.{};
        const dg = d.borrow();
        defer dg.deinit();
        break :blk dg.get().supertype_names;
    };
    // The supertype's declaration is ABSTRACT: it carries no body and lowers no
    // func, so it cannot be found among the interface's methods. `iface_member_ext_recv`
    // is where an abstract member EXTENSION is recorded -- keyed by (interface, name),
    // which is exactly the question here.
    for (sups) |sup| {
        if (mod.registry.iface_member_ext_recv.get(.{ .a = sup, .b = f.name }) != null) return true;
    }
    return false;
}

/// Whether a member-extension owner class is a registered `object` /
/// companion singleton.
fn ownerIsObjectSingleton(self: *VmHost, owner: []const u8) bool {
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().object_names.contains(owner);
}

/// A visible member-extension on the receiver type declared in the
/// enclosing-class chain shadows the stdlib type-name probe.
fn userMemberExtShadows(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, argc: usize) Allocator.Error!bool {
    var owners = try enclosingOwnerSet(self, allocator);
    defer owners.deinit();
    const want = argc + 1;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        if (!isMemberExt(mod, fid)) continue;
        const owner = mod.registry.member_ext_owner_class.get(fid) orelse continue;
        if (!owners.contains(owner)) continue;
        if (funcAt(mod, fid)) |f| {
            if (f.params.len == 0 or f.params.len < want) continue;
            // The shadow holds only while the member-extension could
            // actually bind this receiver: a definitely-disproven declared
            // receiver (a private `IntRange.toLong()` against a `Long`)
            // must leave the stdlib probe ladder in charge. Erased-generic
            // receivers stay non-definite and keep shadowing.
            if (argDefinitelyNotParamType(self, &f.params[0].ty, receiver)) continue;
            return true;
        }
    }
    return false;
}

/// A shipped-pack top-level extension the CALL SITE's file has in scope
/// (same package, wildcard import, or named import) whose declared
/// receiver provably holds shadows the stdlib type-name probe: Kotlin's
/// scoping ranks an explicitly imported extension above the implicitly
/// imported stdlib one (ktor's `Char.isLowerCase()` inside a ktor file
/// importing `io.ktor.util.*` beats `kotlin.text.isLowerCase`). Returns
/// `.shadows` when the ladder must stand down for THIS call site,
/// `.potential` when such a candidate exists but is not in scope here
/// (the resolution is file-dependent, so the caller must not memoize),
/// and `.none` otherwise.
const PackExtShadow = enum { none, potential, shadows };

fn importedPackExtShadows(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, argc: usize) Allocator.Error!PackExtShadow {
    _ = allocator;
    const want = argc + 1;
    const sp = ir.eval.currentCallSiteSpan();
    const dbg = runtime.getenvSlice("KLIO_SHADOW_TRACE") != null;
    if (dbg) std.debug.print("[shadow] probe name={s} argc={d} cands={d} span={any}\n", .{ name, argc, blk: {
        const mg2 = self.module.borrow();
        defer mg2.deinit();
        break :blk mg2.get().funcsBySimpleName(name).len;
    }, sp });
    var result: PackExtShadow = .none;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (isMemberExt(mod, fid)) continue;
        if (!f.hasBody()) continue;
        if (f.package.len == 0) continue;
        // The stdlib's own packages ARE the ladder's surface.
        if (std.mem.eql(u8, f.package, "kotlin") or std.mem.startsWith(u8, f.package, "kotlin.")) continue;
        // Only shipped/pack packages here; plain user declarations are
        // `userToplevelExtShadows`'s domain.
        if (dbg) std.debug.print("[shadow] cand fqn={s} pkg={s} known={} body={}\n", .{ f.fqn, f.package, stdlib.isKnownPackage(f.package), f.hasBody() });
        if (!stdlib.isKnownPackage(f.package)) continue;
        if (f.params.len < want) {
            var has_vararg = false;
            for (f.params) |*p| {
                if (p.is_vararg) {
                    has_vararg = true;
                    break;
                }
            }
            if (!has_vararg) continue;
        } else if (!extArityApplicable(self, &f, want)) continue;
        // NOMINAL receiver match only: a generic / `Any` / function-shape
        // receiver accepts anything and must not stand the whole ladder
        // down (a pack `fun <T> T.get(...)` would otherwise shadow
        // `String.get`). The declared head must be a concrete type the
        // runtime receiver implements.
        {
            var rn = simpleName(f.params[0].ty.name);
            rn = std.mem.trimEnd(u8, rn, "?");
            if (std.mem.eql(u8, rn, "Any") or std.mem.eql(u8, rn, "Unit")) continue;
            if (std.mem.startsWith(u8, rn, "Function")) continue;
            if (rn.len > 0 and rn.len <= 2 and allUppercase(rn)) continue;
            if (typeParamOf(self, fid, rn)) continue;
            if (mod.registry.type_aliases.get(rn)) |t| {
                if (!std.mem.eql(u8, t, rn)) rn = simpleName(t);
            }
            if (!receiverImplementsHead(self, receiver, rn)) continue;
        }
        result = .potential;
        const file = (sp orelse continue).file;
        const in_scope = mod.importWildcardIn(file, f.package) or blk: {
            for (mod.importAliasPathsIn(file, name)) |p| {
                if (std.mem.eql(u8, p.fqn, f.fqn)) break :blk true;
            }
            break :blk false;
        };
        if (in_scope) return .shadows;
    }
    return result;
}

/// A visible USER (non-shipped) top-level extension whose declared
/// receiver type provably holds for this receiver shadows the stdlib
/// type-name probe: a same-package extension (`fun Int.to(o: Int)`)
/// outranks an implicitly imported stdlib extension of the same name
/// (`kotlin.to`), so the stdlib probe ladder must stand down and let the
/// extension fallback bind the user's declaration.
/// Whether the user program declares ANY top-level extension named `name`
/// whose receiver type accepts `receiver` (ignoring the arguments). When true,
/// the `(type, name)` → stdlib-member resolution is ARGUMENT-dependent (the
/// extension shadows the builtin only for arguments it applies to), so it must
/// NOT be memoized by (type, name) alone — else the first call's winner
/// (`1 or 2` → builtin `Int.or`) is wrongly replayed for a different argument
/// shape (`1 or NodeKind` → must reach the extension).
fn userToplevelExtNamedExists(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (isMemberExt(mod, fid)) continue;
        // A pack/stdlib package's extension normally must not pre-empt the
        // probe ladder it dispatches — EXCEPT on a builtin scalar receiver,
        // where the builtin operators (`Int.or`, …) are host intrinsics, not
        // FuncIds, so a pack's operator overload (`Int.or(NodeKind)`) is a
        // genuine distinct overload that must apply for its own argument type.
        if (stdlib.isKnownPackage(f.package) and
            (std.mem.startsWith(u8, f.package, "kotlin") or !isBuiltinScalar(receiver))) continue;
        if (try strictReceiverProven(self, allocator, receiver, fid, &f.params[0].ty)) return true;
    }
    return false;
}

fn userToplevelExtShadows(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!bool {
    const want = args.len + 1;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        // A top-level extension carries `this` as its leading param and is
        // not a member-extension (those go through userMemberExtShadows).
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (isMemberExt(mod, fid)) continue;
        // Only the user's own program shadows the stdlib: a package the
        // stdlib registry or an installed pack owns (kotlin.*, io.ktor.*,
        // …) is the very surface the probe ladder dispatches, so its
        // same-named extensions must not pre-empt it. A user declaration
        // lives in a package no registry knows.
        if (stdlib.isKnownPackage(f.package) and
            (std.mem.startsWith(u8, f.package, "kotlin") or !isBuiltinScalar(receiver))) continue;
        if (f.params.len < want) continue;
        if (!extArityApplicable(self, &f, want)) continue;
        // Only a proven receiver match shadows: an inapplicable namesake
        // (a `String.to` against an `Int` receiver) leaves the stdlib path.
        if (!(try strictReceiverProven(self, allocator, receiver, fid, &f.params[0].ty))) continue;
        // The ARGUMENTS must also be applicable, else this extension is not a
        // candidate for THIS call and must not shadow a same-named stdlib
        // member: `fun Int.or(NodeKind)` does not apply to `1 or 2`, so the
        // builtin `Int.or(Int)` must still win (a member outranks an
        // inapplicable extension). A scalar argument against a user-class
        // parameter is a definite mismatch.
        var args_ok = true;
        for (args, 0..) |*arg, i| {
            if (i + 1 >= f.params.len) break;
            if (!receiverCompatibleWithParam(arg, &f.params[i + 1].ty)) {
                args_ok = false;
                break;
            }
        }
        if (args_ok) return true;
    }
    return false;
}

/// Append `cls` and its full transitive supertype closure — the superclass
/// chain AND every implemented interface, recursively — to `out` in
/// innermost-first order, deduped by pointer identity through `seen`. A
/// member-extension declared as a superclass or interface default body is in
/// scope wherever an enclosing `this` carries that owner ANYWHERE in its
/// hierarchy, so the closure (not just the single `parent` chain) is what
/// gates its visibility. Class pointers are arena-backed and immutable after
/// linking, so reading `name`/`fqn`/`parent`/`interfaces` off `asPtr()` needs
/// no borrow (mirrors `ClassDef.findMethodWalk`).
fn collectClassClosure(
    cls: *const ClassDef,
    out: *std.ArrayList(*const ClassDef),
    seen: *std.ArrayList(*const ClassDef),
    allocator: Allocator,
) void {
    for (seen.items) |p| if (p == cls) return;
    if (seen.items.len > ClassDef.MAX_WALK) return;
    seen.append(allocator, cls) catch return;
    out.append(allocator, cls) catch return;
    if (cls.parent) |p| collectClassClosure(p.asPtr(), out, seen, allocator);
    for (cls.interfaces) |iface| collectClassClosure(iface.asPtr(), out, seen, allocator);
}

/// Set of class names (with the full supertype closure — superclasses AND
/// interfaces) reachable through the enclosing-this chain, including each
/// instance's `outer` links.
fn enclosingOwnerSet(self: *VmHost, allocator: Allocator) Allocator.Error!std.StringHashMap(void) {
    var set: std.StringHashMap(void) = .init(allocator);
    const chain = try enclosingThisChain(self, allocator);
    defer allocator.free(chain);
    var closure: std.ArrayList(*const ClassDef) = .empty;
    defer closure.deinit(allocator);
    var seen: std.ArrayList(*const ClassDef) = .empty;
    defer seen.deinit(allocator);
    for (chain) |v| {
        var cur: ?Value = v;
        while (cur) |cv| {
            if (cv == .Instance) {
                const g = cv.Instance.borrow();
                closure.clearRetainingCapacity();
                collectClassClosure(g.get().class.asPtr(), &closure, &seen, allocator);
                for (closure.items) |cd| {
                    set.put(cd.name, {}) catch {};
                    set.put(cd.fqn, {}) catch {};
                }
                const outer = g.get().outer;
                g.deinit();
                cur = outer;
            } else break;
        }
    }
    return set;
}

/// `delegateForward` with argument names threaded through, so a delegated
/// member invoked with named arguments binds its parameters by name.
fn delegateForwardNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var delegates: std.ArrayList(Value) = .empty;
    defer delegates.deinit(allocator);
    {
        const g = inst.borrow();
        defer g.deinit();
        for (g.get().fields.items) |f| {
            if (!std.mem.startsWith(u8, f.name, "__delegate__")) continue;
            const iface = f.name["__delegate__".len..];
            if (delegatedInterfaceDeclares(self, allocator, inst, iface, name) == false) continue;
            try delegates.append(allocator, f.value);
        }
    }
    for (delegates.items) |d| {
        const r = try callMemberNamed(self, allocator, &d, name, args, arg_names);
        switch (r) {
            .ok => return r,
            .err => |e| {
                if (e != .Unimplemented) return r;
                freeDispatchMiss(allocator, r);
            },
        }
    }
    return null;
}

fn delegateForward(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, swallow_unimplemented_only: bool) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var delegates: std.ArrayList(Value) = .empty;
    defer delegates.deinit(allocator);
    {
        const g = inst.borrow();
        defer g.deinit();
        for (g.get().fields.items) |f| {
            if (!std.mem.startsWith(u8, f.name, "__delegate__")) continue;
            // Kotlin class delegation forwards only the members the
            // delegated interface itself declares. An extension function
            // or an unrelated name must NOT fall through to the delegate:
            // it would rebind `this` to the delegate object (e.g.
            // `Continuation.resumeCancellableWithInternal` running against
            // the wrapped continuation instead of the DispatchedContinuation
            // wrapper, which silently skipped the dispatcher).
            const iface = f.name["__delegate__".len..];
            if (delegatedInterfaceDeclares(self, allocator, inst, iface, name) == false) continue;
            try delegates.append(allocator, f.value);
        }
    }
    for (delegates.items) |d| {
        const r = try callMemberRec(self, allocator, &d, name, args);
        switch (r) {
            .ok => return r,
            .err => |e| {
                if (swallow_unimplemented_only) {
                    if (e != .Unimplemented) return r;
                }
                // else: swallow all errors and continue. The swallowed miss's
                // `Vm::call_member` message is discarded here; free it.
                freeDispatchMiss(allocator, r);
            },
        }
    }
    return null;
}

/// Whether the interface a class delegates to (named by the suffix of a
/// `__delegate__<iface>` field) declares a member `name` anywhere on its
/// hierarchy. Returns `null` when the interface cannot be resolved (the
/// caller keeps the legacy forward-anything behavior), `true`/`false`
/// when membership is decidable.
pub fn delegatedInterfaceDeclares(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), iface_name_raw: []const u8, name: []const u8) ?bool {
    // The key carries the source-spelled supertype; strip generic args
    // (`Continuation<T>` -> `Continuation`).
    var iface_name = iface_name_raw;
    if (std.mem.indexOfScalar(u8, iface_name, '<')) |lt| iface_name = iface_name[0..lt];
    iface_name = std.mem.trim(u8, iface_name, " ");
    if (std.mem.lastIndexOfScalar(u8, iface_name, '.')) |dot| iface_name = iface_name[dot + 1 ..];
    if (iface_name.len == 0) return null;

    // Resolve lexically first (the class's captured declaration env), then
    // via the global class table.
    // The lowered hierarchy registry covers what `ClassDef.findMethod`
    // cannot see: abstract interface members have no lowered body, so
    // they never appear in `methods`, yet Kotlin forwards exactly those
    // through `by` delegation (`interface Greeter { fun greet(): String }`).
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.hierarchy_methods.get(iface_name)) |methods| {
            if (methods.contains(name)) return true;
        }
    }
    const iface_def: ?ObjRef(ClassDef) = blk: {
        {
            const g = inst.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            const eg = cg.get().captured_env.borrow();
            defer eg.deinit();
            if (eg.get().lookup(iface_name)) |v| {
                if (v == .Class) break :blk v.Class.clone();
            }
        }
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(iface_name)) |d| break :blk d.clone();
        break :blk null;
    };
    const def = iface_def orelse return null;
    defer def.deinit();
    if (ClassDef.findMethod(def, allocator, name)) |hit| {
        hit.class.deinit();
        return true;
    }
    if (ClassDef.findBodyProperty(def, allocator, name)) |hit| {
        hit.class.deinit();
        return true;
    }

    // A property may be dispatched through its synthesized accessor name.
    if (std.mem.startsWith(u8, name, "$get$") or std.mem.startsWith(u8, name, "$set$")) {
        const prop = name["$get$".len..];
        if (ClassDef.findBodyProperty(def, allocator, prop)) |hit| {
            hit.class.deinit();
            return true;
        }
    }
    return false;
}

const Candidate = struct { fid: FuncId, func: Func };

/// A candidate whose declared receiver names a specific BUILTIN shape a
/// builtin runtime value definitely is not (UIntArray.fill offered a
/// plain Array, String.x offered a List). Instances stay unproven —
/// their hierarchies decide elsewhere.
pub fn builtinReceiverDisproven(receiver: *const Value, declared: []const u8) bool {
    const unsigned_arrays = [_][]const u8{ "UIntArray", "ULongArray", "UShortArray", "UByteArray" };
    switch (receiver.*) {
        .Array => |arr| {
            for (unsigned_arrays) |ua| {
                if (std.mem.eql(u8, declared, ua)) {
                    const view = arr.prim orelse return true;
                    // Compare against the ARRAY type name: the kind's
                    // simpleName is the element ("UByte"), never the
                    // declared receiver ("UByteArray").
                    return !std.mem.eql(u8, simpleName(view.typeFqn()), declared);
                }
            }
            return false;
        },
        // A user instance can never be a builtin array (array types are
        // final): a `TestCollection` receiver must not bind
        // `UIntArray.toTypedArray`.
        .Instance => {
            if (overload_match.builtinParamKind(declared)) |pk| {
                return pk == .array;
            }
            return false;
        },
        else => return false,
    }
}

/// Resolve an extension candidate's declared receiver-type simple name to a
/// fully-qualified class, in the candidate's OWN declaration-file scope: its
/// non-wildcard imports first, then its declaring package, then its wildcard
/// imports. Returns the canonical FQN of the resolved class, or null when the
/// name resolves to no known class (a generic / `Any` / builtin receiver, or
/// a name klio cannot place). Two same-simple-name receivers declared against
/// classes in different packages resolve to DISTINCT FQNs here — the key to
/// telling cross-package extension twins apart from the runtime receiver.
fn resolveExtReceiverFqn(allocator: Allocator, mod: *const Module, c: *const Candidate) ?[]const u8 {
    if (c.func.params.len == 0) return null;
    const nm = std.mem.trimEnd(u8, c.func.params[0].ty.name, "?");
    // An already-qualified receiver reference resolves directly.
    if (std.mem.indexOfScalar(u8, nm, '.') != null) {
        if (mod.classIdByFqn(nm)) |cid| return mod.classFqnById(cid);
    }
    const simple = simpleName(nm);
    const ds = mod.decl_span.get(c.fid.int()) orelse return null;
    const file = ds.file;
    // Named imports of this leaf (file-scoped) take precedence.
    for (mod.importAliasPathsIn(file, simple)) |p| {
        if (mod.classIdByFqn(p.fqn)) |cid| return mod.classFqnById(cid);
    }
    // The candidate's own package.
    if (c.func.package.len != 0) {
        const cand = std.fmt.allocPrint(allocator, "{s}.{s}", .{ c.func.package, simple }) catch return null;
        defer if (runtime.freeScratch()) allocator.free(cand);
        if (mod.classIdByFqn(cand)) |cid| return mod.classFqnById(cid);
    }
    // Wildcard imports of the file.
    if (mod.registry.import_wildcards.get(file)) |list| {
        for (list.items) |pkg| {
            const cand = std.fmt.allocPrint(allocator, "{s}.{s}", .{ pkg, simple }) catch return null;
            defer if (runtime.freeScratch()) allocator.free(cand);
            if (mod.classIdByFqn(cand)) |cid| return mod.classFqnById(cid);
        }
    }
    return null;
}

/// When the surviving extension candidates include cross-package twins whose
/// declared receiver types share a simple name but resolve to different
/// classes, the RUNTIME receiver's actual class decides which twin Kotlin
/// binds. klio stores the receiver type as its simple name, so a
/// `gapbuffer.SlotTable` receiver and a `linkbuffer.SlotTable` receiver both
/// read as `SlotTable` and either same-named extension looks applicable — the
/// wrong twin then runs against fields it lacks (`unresolved global root`).
/// When the runtime object's class FQN exactly equals one twin's resolved
/// receiver FQN, every OTHER same-simple-name candidate resolving to a
/// different concrete class is inapplicable: drop it. A no-op unless a genuine
/// same-name twin conflict exists AND the runtime class picks a winner, so an
/// ordinary single-receiver-type overload set (every candidate resolving to
/// the same FQN, or to none) is left untouched.
fn narrowSameNameExtensionTwins(self: *VmHost, allocator: Allocator, receiver: *const Value, candidates: *std.ArrayList(Candidate)) void {
    if (receiver.* != .Instance) return;
    if (candidates.items.len < 2) return;
    const recv_fqn: []const u8 = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const n = candidates.items.len;
    const fqns = allocator.alloc(?[]const u8, n) catch return;
    defer allocator.free(fqns);
    for (candidates.items, 0..) |*c, i| fqns[i] = resolveExtReceiverFqn(allocator, mod, c);
    const remove = allocator.alloc(bool, n) catch return;
    defer allocator.free(remove);
    for (remove) |*r| r.* = false;
    var any_removed = false;
    for (candidates.items, 0..) |*c, i| {
        if (c.func.params.len == 0) continue;
        const simple_i = simpleName(std.mem.trimEnd(u8, c.func.params[0].ty.name, "?"));
        // Does candidate i's same-simple-name group contain a sibling whose
        // resolved receiver FQN is EXACTLY the runtime class?
        var exact_present = false;
        for (candidates.items, 0..) |*o, j| {
            if (o.func.params.len == 0) continue;
            const simple_j = simpleName(std.mem.trimEnd(u8, o.func.params[0].ty.name, "?"));
            if (!std.mem.eql(u8, simple_i, simple_j)) continue;
            const fj = fqns[j] orelse continue;
            if (std.mem.eql(u8, fj, recv_fqn)) {
                exact_present = true;
                break;
            }
        }
        if (!exact_present) continue;
        const fi = fqns[i] orelse continue; // unresolvable → undecidable, keep
        if (!std.mem.eql(u8, fi, recv_fqn)) {
            remove[i] = true;
            any_removed = true;
        }
    }
    if (!any_removed) return;
    var filtered: std.ArrayList(Candidate) = .empty;
    for (candidates.items, 0..) |cc, i| {
        if (!remove[i]) filtered.append(allocator, cc) catch {};
    }
    candidates.deinit(allocator);
    candidates.* = filtered;
}

fn extensionFnFallback(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8, declared_recv: ?[]const u8) Allocator.Error!?EvalResult {
    const want = args.len + 1;
    if (missTraceWant(name)) {
        const rk: []const u8 = switch (receiver.*) {
            .Instance => |inst| blk: {
                const g = inst.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                break :blk cg.get().fqn;
            },
            else => receiver.typeFqn(),
        };
        std.debug.print("[extfb] ENTRY strict={} nargs={d} recv={s}\n", .{ strict_ext, args.len, rk });
    }

    // Inline-cache fast path. A prior *owner-independent* resolution of this
    // (receiver class, name, arg types) to a top-level extension dispatches
    // straight through `callFuncRec`, skipping the candidate collection, the
    // enclosing-owner set allocation, and the filter/score passes below —
    // the dominant cost of extension-heavy hot loops. Only keyed when no
    // receiver override is in play (a static/declared receiver, or the strict
    // bare-name probe, can resolve the same names differently).
    const cache_key: ?root_mod.ProgramImage.InstanceMethodKey =
        if (!strict_ext and static_recv == null and declared_recv == null)
            instanceMethodKey(self, receiver, name, args)
        else
            null;
    if (cache_key) |k| {
        if (extMethodCacheGet(self, k)) |fid| {
            if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(fid), args)) |r| return r;
        }
    }

    var visible_owners = try enclosingOwnerSet(self, allocator);
    defer visible_owners.deinit();

    // Whether any candidate for this name is a member-extension (its
    // visibility/selection depends on the enclosing-`this` chain). When one
    // exists the resolution is context-dependent and must not be cached.
    var saw_member_ext = false;

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        const mtrace = if (runtime.getenvSlice("KLIO_MISS_TRACE")) |w| std.mem.eql(u8, w, name) else false;
        if (mtrace) {
            std.debug.print("[extfb] name={s} simple-name fids={d} want={d} args:", .{ name, mod.funcsBySimpleName(name).len, want });
            for (args) |*a| std.debug.print(" {s}", .{@tagName(std.meta.activeTag(a.*))});
            std.debug.print("\n", .{});
        }
        for (mod.funcsBySimpleName(name)) |fid| {
            const f = funcAt(mod, fid) orelse continue;
            if (!(f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this"))) {
                if (mtrace) std.debug.print("[extfb]  fid={d} shape-skip nparams={d}\n", .{ fid.int(), f.params.len });
                continue;
            }
            // Shape gate: enough declared params for the supplied args, OR
            // a vararg param absorbing the surplus (`appendPathSegments
            // (vararg components, encodeSlash = ...)` takes any number of
            // positional components).
            const has_vararg = blk: {
                for (f.params) |*p| {
                    if (p.is_vararg) break :blk true;
                }
                break :blk false;
            };
            if (f.params.len < want and !has_vararg) {
                if (mtrace) std.debug.print("[extfb]  fid={d} shape-skip nparams={d}\n", .{ fid.int(), f.params.len });
                continue;
            }
            // Surplus declared params beyond the supplied args are only
            // fillable when every one carries a default (or is a
            // vararg). Without this, the 3-user-param
            // `(suspend R.(P) -> T).startCoroutineUninterceptedOrReturn`
            // ranked for a 2-arg call, ran the coroutine block with the
            // completion slot empty, failed late, and the walk re-ran
            // the block through the right overload — every UNDISPATCHED
            // launch body executed twice.
            if (f.params.len > want) {
                const defaults = funcDefaults(self, &f);
                // A trailing callable argument binds the LAST declared
                // parameter (the trailing-lambda convention), so the
                // default-fillable gap sits between the positional args
                // and that last slot (`launch(context, start, block)`
                // called as `launch { }` needs defaults on context/start
                // only). Otherwise the gap is everything past the args.
                const last_arg_callable = args.len > 0 and switch (args[args.len - 1]) {
                    .IrClosure, .Function => true,
                    else => false,
                };
                const last_param_fn = std.mem.startsWith(u8, f.params[f.params.len - 1].ty.name, "Function") or
                    std.mem.eql(u8, f.params[f.params.len - 1].ty.name, "<function>");
                var lo: usize = want;
                var hi: usize = f.params.len;
                if (last_arg_callable and last_param_fn) {
                    lo = want - 1;
                    hi = f.params.len - 1;
                }
                var fillable = true;
                var k: usize = lo;
                while (k < hi) : (k += 1) {
                    if (!(f.params[k].is_vararg or paramHasDefault(defaults, k))) {
                        fillable = false;
                        break;
                    }
                }
                if (!fillable) {
                    if (mtrace) std.debug.print("[extfb]  fid={d} surplus-skip nparams={d}\n", .{ fid.int(), f.params.len });
                    continue;
                }
            }
            if (isMemberExt(mod, fid)) saw_member_ext = true;
            if (privateFnHiddenHere(self, mod, fid)) {
                if (mtrace) std.debug.print("[extfb]  fid={d} private-skip\n", .{fid.int()});
                continue;
            }
            if (!memberExtVisible(self, mod, fid, &visible_owners)) {
                if (mtrace) std.debug.print("[extfb]  fid={d} owner-skip\n", .{fid.int()});
                continue;
            }
            // An unsettled bodyless header is not executable — selecting
            // it would re-enter `callFunc`'s bodyless ladder and cycle,
            // and it must not outrank a real serving in a later walk arm.
            // A call statically bound to such a header no-ops in
            // `callFunc`'s bodyless arm; here it simply never competes.
            if (!host_call_func.executableForm(self, mod, fid, want)) {
                if (mtrace) std.debug.print("[extfb]  fid={d} bodyless-skip\n", .{fid.int()});
                continue;
            }
            if (mtrace) std.debug.print("[extfb]  fid={d} CANDIDATE recv={s}\n", .{ fid.int(), if (mod.decl_sigs.get(fid.int())) |sg| (if (sg.receiver_ty) |rt| rt.name else "-") else "-" });
            try candidates.append(allocator, .{ .fid = fid, .func = f });
        }
    }

    // A low-priority candidate (`@Deprecated(level = ERROR/HIDDEN)`,
    // `@LowPriorityInOverloadResolution`) is only a candidate when no ordinary
    // overload applies — kotlinc hides it from resolution. Drop them up front
    // when any ordinary candidate exists, for BOTH the strict and lenient
    // passes below. Without this, the lenient pass can bind a HIDDEN
    // binary-compat stub that delegates to a sibling overload but self-recurses
    // (`buffer(capacity) = buffer(capacity)`, conflate → stack overflow).
    {
        var any_ordinary = false;
        for (candidates.items) |c| {
            if (!c.func.low_priority) {
                any_ordinary = true;
                break;
            }
        }
        if (any_ordinary) {
            var filtered: std.ArrayList(Candidate) = .empty;
            for (candidates.items) |c| {
                if (!c.func.low_priority) filtered.append(allocator, c) catch {};
            }
            candidates.deinit(allocator);
            candidates = filtered;
        }
    }

    // Receiver-type filter. The strict probe (the bare-name resolver's
    // innermost-first walk) demands a *proven* receiver match — the
    // declared receiver type (or a generic / `Any` / function-shape
    // receiver, which accepts anything) must hold for this receiver's
    // class hierarchy — so an inapplicable extension cannot bind at an
    // inner receiver and pre-empt a real member of an outer one. The
    // lenient form keeps the score-anyway pick for receivers whose
    // runtime type cannot prove the match.
    if (strict_ext) {
        var filtered: std.ArrayList(Candidate) = .empty;
        for (candidates.items) |c| {
            // A low-priority candidate (`@LowPriorityInOverloadResolution`
            // / deprecated-ERROR guard stub) is never a strict pick: it
            // only applies when no ordinary candidate does, which the
            // resolver's later tiers decide.
            if (c.func.low_priority) continue;
            // Both the receiver AND the value-argument arity must
            // provably fit — an extension whose extra params carry no
            // defaults is not applicable to this call. With a known
            // STATIC receiver type, applicability is decided against it
            // (Kotlin extension resolution is static): an extension on a
            // runtime subtype is not a candidate inside an extension
            // body whose `this` is declared as the supertype.
            const recv_fits = if (static_recv) |sname|
                staticReceiverApplicable(self, allocator, sname, c.fid, &c.func.params[0].ty) orelse
                    try strictReceiverProven(self, allocator, receiver, c.fid, &c.func.params[0].ty)
            else
                try strictReceiverProven(self, allocator, receiver, c.fid, &c.func.params[0].ty);
            if (!recv_fits) {
                if (missTraceWant(name)) std.debug.print("[extfb]  fid={d} strict recv-unproven static_recv={s}\n", .{ c.fid.int(), static_recv orelse "-" });
                continue;
            }
            // A type-parameter receiver's declared bounds bind in the strict
            // pass too: `fun <T> T.observeReads where T : Modifier.Node`
            // never takes a ContentDrawScope receiver, however generically
            // the bare head reads. The static-hint shortcut above cannot see
            // the bounds, so re-check them against the runtime receiver.
            if (receiverViolatesTypeParamBound(self, c.fid, &c.func.params[0].ty, receiver)) continue;
            if (!extArityApplicable(self, &c.func, want)) continue;
            if (candidateArgsDisproven(self, &c.func, args)) continue;
            // Kotlin selects extensions against the receiver's DECLARED
            // type: a definite static mismatch drops the candidate. But a
            // COMPANION extension (`fun X.Companion.f`) invoked through the
            // class value `X.f` has declared receiver `X` and receiver type
            // `X.Companion`: the class-value access forwards to the companion,
            // which `strictReceiverProven` above already confirmed for this
            // receiver, so do not drop it on the class-vs-companion mismatch.
            if (declared_recv) |dn| {
                const rty = &c.func.params[0].ty;
                const is_companion_recv = std.mem.endsWith(u8, rty.name, ".Companion") or
                    std.mem.eql(u8, rty.name, "Companion");
                if (!is_companion_recv and staticReceiverApplicable(self, allocator, dn, c.fid, rty) == false) continue;
            }
            filtered.append(allocator, c) catch {};
        }
        candidates.deinit(allocator);
        candidates = filtered;
        if (candidates.items.len == 0) return null;
    } else {
        // With a known static receiver type, drop candidates that are
        // statically inapplicable before any runtime-type ranking: an
        // extension on a runtime subtype is not a candidate at all when
        // `this` is declared as the supertype.
        if (static_recv) |sname| {
            var filtered: std.ArrayList(Candidate) = .empty;
            for (candidates.items) |c| {
                const fits = staticReceiverApplicable(self, allocator, sname, c.fid, &c.func.params[0].ty) orelse true;
                if (fits) filtered.append(allocator, c) catch {};
            }
            candidates.deinit(allocator);
            candidates = filtered;
            if (candidates.items.len == 0) return null;
        }
        // Lenient pass: keep candidates whose receiver match cannot be
        // proven (erased generics) — but a definite DISPROOF still drops
        // the candidate: when the declared receiver heads a known class
        // and the runtime receiver's full hierarchy excludes it, kotlinc
        // never considers the extension (`Pipeline.execute` is not a
        // candidate on a coroutine receiver).
        {
            const mtr = missTraceWant(name);
            var filtered: std.ArrayList(Candidate) = .empty;
            for (candidates.items) |c| {
                if (receiverViolatesTypeParamBound(self, c.fid, &c.func.params[0].ty, receiver)) {
                    if (mtr) std.debug.print("[extfb]  fid={d} lenient bound-skip\n", .{c.fid.int()});
                    continue;
                }
                if (builtinReceiverDisproven(receiver, c.func.params[0].ty.name)) {
                    if (mtr) std.debug.print("[extfb]  fid={d} lenient builtin-disproof\n", .{c.fid.int()});
                    continue;
                }
                if (candidateArgsDisproven(self, &c.func, args)) {
                    if (mtr) std.debug.print("[extfb]  fid={d} lenient args-disproof\n", .{c.fid.int()});
                    continue;
                }
                // Arity applicability holds in the lenient pass too: a
                // candidate that REQUIRES more args than supplied cannot
                // take this call — Null-padding it silently runs the
                // wrong overload (`subList(..).sortDescending()` bound
                // the `(fromIndex, toIndex)` variant with Null indices).
                // Judged by the DECLARED arity (required/vararg), which
                // is authoritative where per-fid default thunks are not.
                if (declArityRefuses(self, c.fid, args.len)) {
                    if (mtr) std.debug.print("[extfb]  fid={d} lenient arity-refuse\n", .{c.fid.int()});
                    continue;
                }
                if (declared_recv) |dn| {
                    // A companion extension (`fun X.Companion.f`) called through
                    // the class value (`X.f`) has declared receiver `X` but a
                    // `X.Companion` receiver type; the class-value access
                    // forwards to the companion, so the class-vs-companion
                    // mismatch must not drop it.
                    const rty = &c.func.params[0].ty;
                    const is_companion_recv = std.mem.endsWith(u8, rty.name, ".Companion") or
                        std.mem.eql(u8, rty.name, "Companion");
                    if (!is_companion_recv and staticReceiverApplicable(self, allocator, dn, c.fid, rty) == false) {
                        if (mtr) std.debug.print("[extfb]  fid={d} lenient static-recv-refuse dn={s}\n", .{ c.fid.int(), dn });
                        continue;
                    }
                }
                filtered.append(allocator, c) catch {};
            }
            candidates.deinit(allocator);
            candidates = filtered;
            if (candidates.items.len == 0) return null;
        }
        var any_compat = false;
        for (candidates.items) |c| {
            if (receiverCompatibleWithParam(receiver, &c.func.params[0].ty) and
                !receiverDefinitelyNotParam(self, &c.func.params[0].ty, receiver)) any_compat = true;
        }
        if (missTraceWant(name)) std.debug.print("[extfb] lenient survivors={d} any_compat={}\n", .{ candidates.items.len, any_compat });
        if (any_compat) {
            var filtered: std.ArrayList(Candidate) = .empty;
            for (candidates.items) |c| {
                if (receiverCompatibleWithParam(receiver, &c.func.params[0].ty) and
                    !receiverDefinitelyNotParam(self, &c.func.params[0].ty, receiver)) filtered.append(allocator, c) catch {};
            }
            candidates.deinit(allocator);
            candidates = filtered;
        } else {
            // Every candidate is either incompatible or definitely
            // disproven: nothing to pick leniently.
            var any_undisproven = false;
            for (candidates.items) |c| {
                if (!receiverDefinitelyNotParam(self, &c.func.params[0].ty, receiver)) any_undisproven = true;
            }
            if (!any_undisproven) return null;
        }
    }

    // Kotlin resolves scope level by scope level, and a class body is an
    // INNER scope relative to its file: a member extension of an enclosing
    // class outranks a same-named top-level extension for calls inside the
    // class. Surviving member-ext candidates already passed
    // `memberExtVisible`, so their owner is on the enclosing-`this` chain —
    // exactly the calls where kotlinc binds the member extension. Without
    // this tier a same-shape pair ties in scoring and the pick falls to
    // declaration order (SlotWriter's gap-aware `IntArray.nodeIndex` lost
    // to the file-level raw-anchor accessor, correct for positive anchors
    // and silently wrong for end-relative ones).
    if (candidates.items.len > 1) {
        const mg2 = self.module.borrow();
        defer mg2.deinit();
        const mod2 = mg2.get();
        var n_member: usize = 0;
        for (candidates.items) |c| {
            if (isMemberExt(mod2, c.fid)) n_member += 1;
        }
        if (n_member != 0 and n_member != candidates.items.len) {
            var filtered: std.ArrayList(Candidate) = .empty;
            for (candidates.items) |c| {
                if (isMemberExt(mod2, c.fid)) filtered.append(allocator, c) catch {};
            }
            candidates.deinit(allocator);
            candidates = filtered;
        }
    }

    // Kotlin gathers candidates scope level by scope level — the call
    // site's own file (its file-privates included) before anything from
    // another file — and resolution stops at the innermost level with an
    // applicable candidate. With several receiver-fitting candidates,
    // keep the call-site file's own when any exist: a file-private
    // `MockViewValidator.Text` outranks another package's same-signature
    // extension the file never imported.
    if (candidates.items.len > 1) {
        const site_file: ?ir.FileId = ir.eval.refSiteFile() orelse
            if (ir.eval.currentCallSiteSpan()) |csp| csp.file else null;
        if (site_file) |sf| {
            const smg = self.module.borrow();
            defer smg.deinit();
            const smod = smg.get();
            var same_file: usize = 0;
            for (candidates.items) |c| {
                const ds = smod.decl_span.get(c.fid.int()) orelse continue;
                if (ds.file.int() == sf.int()) same_file += 1;
            }
            if (same_file != 0 and same_file != candidates.items.len) {
                var filtered: std.ArrayList(Candidate) = .empty;
                for (candidates.items) |c| {
                    const ds = smod.decl_span.get(c.fid.int()) orelse continue;
                    if (ds.file.int() == sf.int()) filtered.append(allocator, c) catch {};
                }
                candidates.deinit(allocator);
                candidates = filtered;
            }
        }
    }

    // Cross-package same-simple-name extension twins: the runtime receiver's
    // actual class FQN, not the shared receiver simple name, decides which
    // twin binds. Runs after the scope tiers so it only adjudicates a residual
    // genuine twin conflict.
    if (candidates.items.len > 1) {
        narrowSameNameExtensionTwins(self, allocator, receiver, &candidates);
        if (candidates.items.len == 0) return null;
    }

    // Unique-exact-arity pick — only when every supplied argument can
    // bind its parameter. An arity-exact candidate whose param types the
    // args definitely don't satisfy is inapplicable (kotlinc drops it),
    // so a defaulted-arity sibling can win on type fit instead:
    // `fetch("url")` must reach `fetch(urlString, block = {})`, not the
    // arity-exact `fetch(block: () -> Unit)`.
    var unique_exact: ?Candidate = null;
    {
        var count: usize = 0;
        for (candidates.items) |c| {
            if (c.func.params.len == want) {
                count += 1;
                unique_exact = c;
            }
        }
        if (count != 1) unique_exact = null;
        if (unique_exact) |c| {
            for (args, 0..) |*a, i| {
                if (c.func.params.len > i + 1 and
                    overloadScoreArg(self, &c.func.params[i + 1].ty, a) == null)
                {
                    unique_exact = null;
                    break;
                }
            }
        }
    }

    var chosen: ?Candidate = null;
    if (candidates.items.len <= 1) {
        chosen = if (candidates.items.len == 1) candidates.items[0] else null;
    } else if (unique_exact != null) {
        chosen = unique_exact;
    } else {
        chosen = try scoreExtCandidates(self, allocator, receiver, candidates.items, args);
    }

    if (chosen == null) return null;

    // An erased receiver-TYPE-ARG tie is undecidable here: sibling
    // overloads that differ ONLY in the receiver's element type
    // (`Sequence<UInt>.sum()` vs `Sequence<Int>.sum()` — same head, same
    // params) select by a static type argument the runtime receiver does
    // not carry. Picking one silently runs the wrong element arithmetic;
    // decline instead so the walk's element-tag-aware arms (the
    // iterable/list intrinsic fallbacks) serve the call dynamically.
    {
        const c = chosen.?;
        const crt = &c.func.params[0].ty;
        if (crt.args.len != 0) {
            for (candidates.items) |o| {
                if (o.fid.int() == c.fid.int()) continue;
                const ort = &o.func.params[0].ty;
                if (!std.mem.eql(u8, ort.name, crt.name)) continue;
                if (o.func.params.len != c.func.params.len) continue;
                if (ort.args.len != crt.args.len or ort.args.len == 0) continue;
                // Only a NUMERIC-WIDTH element difference is undecidable
                // (the arithmetic changes per width); container-kind
                // differences (Sequence<Sequence> vs Sequence<Iterable>
                // for `flatten`) dispatch fine per element at runtime.
                if (!numericWidthKind(ort.args[0].name) or !numericWidthKind(crt.args[0].name)) continue;
                if (!std.mem.eql(u8, ort.args[0].name, crt.args[0].name)) {
                    if (trace.enabled(name)) {
                        trace.emit("map=erased_recv_tie_decline name={s} a={s} b={s}", .{ name, c.func.fqn, o.func.fqn });
                    }
                    return null;
                }
            }
        }
    }

    // Defer to a function-typed enclosing property when the chosen
    // member-extension's receiver doesn't accept the actual receiver.
    const defer_to_property = blk: {
        const c = chosen.?;
        const is_member_ext = isMemberExt(self.module.borrow().get(), c.fid);
        if (!is_member_ext) break :blk false;
        if (c.func.params.len == 0) break :blk false;
        if (receiverImplementsType(self, receiver, c.func.params[0].ty.name)) break :blk false;
        break :blk (try enclosingCallableProperty(self, allocator, name)) != null;
    };

    // Defer to the Iterable fallback for a bare-package stdlib extension
    // chosen for a user collection.
    const defer_to_iterable = blk: {
        if (receiver.* != .Instance) break :blk false;
        const c = chosen.?;
        const coll = try std.fmt.allocPrint(allocator, "kotlin.collections.{s}", .{name});
        defer if (runtime.freeScratch()) allocator.free(coll);
        const seq = try std.fmt.allocPrint(allocator, "kotlin.sequences.{s}", .{name});
        defer if (runtime.freeScratch()) allocator.free(seq);
        if (!(std.mem.eql(u8, c.func.fqn, coll) or std.mem.eql(u8, c.func.fqn, seq))) break :blk false;
        if (!hostHasMember(self, receiver, "iterator")) break :blk false;
        const ip = try std.fmt.allocPrint(allocator, "kotlin.collections.Iterable.{s}", .{name});
        defer if (runtime.freeScratch()) allocator.free(ip);
        const lp = try std.fmt.allocPrint(allocator, "kotlin.collections.List.{s}", .{name});
        defer if (runtime.freeScratch()) allocator.free(lp);
        break :blk (lookupIntrinsic(self, ip) != null) or (lookupIntrinsic(self, lp) != null);
    };

    if (!defer_to_property and !defer_to_iterable) {
        const c = chosen.?;
        if (trace.enabled(name)) {
            const d = funcDefaults(self, &c.func);
            trace.emit("map=ext_fallback_pick name={s} fqn={s} fid={d} strict={} nparams={d} ndefaults={d} recv_ty={s} p0={s} owner={s}", .{
                name,                     c.func.fqn,
                c.fid.int(),              strict_ext,
                c.func.params.len,        if (d) |dd| dd.len else 0,
                c.func.params[0].ty.name, c.func.params[0].name,
                blk: {
                    const mg2 = self.module.borrow();
                    defer mg2.deinit();
                    break :blk mg2.get().registry.member_ext_owner_class.get(c.fid) orelse "-";
                },
            });
        }
        const all = try prependReceiver(allocator, receiver, args);
        defer if (runtime.freeScratch()) allocator.free(all);
        const mg = self.module.borrow();
        const mod = mg.get();
        // A member-extension's body has its declaring class's `this` in
        // lexical scope (the dispatch receiver that made it visible
        // here). Seed the callee frame with that owner instance: push it
        // as a transferable enclosing receiver for the duration of the
        // call.
        var pushed_owner = false;
        var sam_target: ?Value = null;
        if (mod.registry.member_ext_owner_class.get(c.fid)) |owner| {
            if (try memberExtOwnerInstance(self, allocator, receiver, owner)) |inst| {
                // A bodyless member-extension declaration whose owner is a
                // SAM conversion (`MeasurePolicy { measurables, constraints
                // -> ... }`): the fun interface's single method IS the
                // member-extension, so the stored lambda serves the call —
                // with the EXTENSION receiver bound as the lambda's `this`,
                // exactly as kotlinc scopes the lambda body (`layout(...)`
                // inside it resolves against the MeasureScope receiver).
                if (funcAt(mod, c.fid) != null and !funcAt(mod, c.fid).?.hasBody()) {
                    if (inst == .Instance) {
                        const g = inst.Instance.borrow();
                        sam_target = g.get().get("__sam_target__");
                        g.deinit();
                    }
                }
                if (sam_target == null) {
                    ir.eval.pushEnclosing(&inst);
                    pushed_owner = true;
                }
            }
        }
        if (sam_target) |t| {
            const r2 = try host_call_value.callValueWithThis(self, allocator, &t, &all[0], all[1..], &.{});
            mg.deinit();
            return r2;
        }
        // Memoize an owner-independent pick: no member-extension competes for
        // this name and the winner is itself top-level, so the (receiver
        // class, name, arg types) key fully determines the target. A future
        // call hits the fast path above and skips this whole resolution.
        if (!pushed_owner and !saw_member_ext) {
            if (cache_key) |k| extMethodCachePut(self, k, @intFromEnum(c.fid));
        }
        const r = try callFuncRec(self, allocator, mod, c.fid, all);
        if (pushed_owner) ir.eval.popEnclosing();
        mg.deinit();
        return r;
    }
    return null;
}

/// The instance serving as a member-extension's dispatch receiver: the
/// innermost enclosing receiver (including access entries pushed for this
/// dispatch) whose class hierarchy carries `owner`, else the explicit
/// receiver itself when it does.
pub fn memberExtOwnerInstance(self: *VmHost, allocator: Allocator, receiver: *const Value, owner: []const u8) Allocator.Error!?Value {
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    if (runtime.getenvSlice("KLIO_NU_TRACE") != null and std.mem.eql(u8, owner, "PlacementScope")) {
        std.debug.print("[meoi] owner={s} nentries={d}:", .{ owner, entries.len });
        for (entries) |e| {
            if (e.v == .Instance) {
                const g = e.v.Instance.borrow();
                const cg = g.get().class.borrow();
                std.debug.print(" {s}={}", .{ cg.get().name, receiverImplementsType(self, &e.v, owner) });
                cg.deinit();
                g.deinit();
            } else std.debug.print(" {s}", .{@tagName(e.v)});
        }
        std.debug.print("\n", .{});
    }
    for (entries) |e| {
        if (e.v != .Instance) continue;
        if (receiverImplementsType(self, &e.v, owner)) return e.v;
        // The owner may sit on the entry's class-nesting tower.
        if (!e.isSubject()) {
            var cur: ?Value = instanceOuterLink(&e.v);
            while (cur) |o| {
                if (o != .Instance) break;
                if (receiverImplementsType(self, &o, owner)) return o;
                cur = instanceOuterLink(&o);
            }
        }
    }
    if (receiver.* == .Instance and receiverImplementsType(self, receiver, owner)) return receiver.*;
    // The lexical receiver tower of the executing call stack: a getter
    // reached through nested lambdas (`placeable.mainAxisSize` inside a
    // `with(scope) { repeat { … } }` body) has its owner bound as an
    // outer frame's `this`, never on the dynamic enclosing chain.
    {
        const lex = try ir.eval.frameThisChainAlloc(allocator);
        defer allocator.free(lex);
        for (lex) |v| {
            if (v != .Instance) continue;
            if (receiverImplementsType(self, &v, owner)) return v;
        }
    }
    // An `object`/companion owner is its own dispatch receiver: the
    // singleton is materializable from anywhere it can be imported.
    if (ownerIsObjectSingleton(self, owner)) {
        if (host_globals.objectSingletonQuiet(self, owner)) |sv| {
            if (sv == .Instance) return sv;
        }
    }
    return null;
}

/// The captured/constructed `outer` link of an `Instance` value.
fn instanceOuterLink(v: *const Value) ?Value {
    return switch (v.*) {
        .Instance => |i| blk: {
            const g = i.borrow();
            defer g.deinit();
            break :blk g.get().outer;
        },
        else => null,
    };
}

/// Kotlin-faithful most-specific extension-overload selection.
///
/// Each candidate is ranked by a strict, total ordering so the winner is
/// unique and deterministic (no declaration-order tie-break). Ranked, in
/// descending priority:
///   0. subtype specificity — how many other candidates' receiver types are
///      supertypes of this one. Kotlin's most-specific rule is decided by the
///      subtyping lattice, not by runtime hierarchy distance: with a receiver
///      that satisfies several unrelated extension-receiver types (a coroutine
///      is both a `Job` and a `CoroutineScope`), the candidate whose receiver
///      is a subtype of another candidate's (`Job` <: `CoroutineContext`) is
///      the more specific one even when an unrelated sibling sits nearer in
///      the runtime class graph. When the lattice cannot decide (no candidate
///      is a subtype of another) this ties at zero and the runtime-distance
///      tier below breaks it;
///   1. receiver specificity — the candidate whose receiver param most
///      specifically matches the receiver's runtime type (a `Flow` receiver
///      selects `Flow.forEach`, not the generic `Iterable.forEach`);
///   2. applicability score — the numeric arg/param compatibility;
///   3. owner rank — a member extension visible nearer on the enclosing-`this`
///      chain;
///   4. parameter specificity — the most-specific declared parameter types
///      for the supplied value args;
///   5. a stable key (lowest `FuncId`) so the winner is always unique.
const ExtKey = [8]i32;

fn extKeyGreater(a: ExtKey, b: ExtKey) bool {
    inline for (0..a.len) |i| {
        if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
}

fn scoreExtCandidates(self: *VmHost, allocator: Allocator, receiver: *const Value, candidates: []const Candidate, args: []const Value) Allocator.Error!?Candidate {
    var shapes_buf: [24]applicability.ArgShape = undefined;
    const shapes: []applicability.ArgShape = if (args.len <= shapes_buf.len)
        shapes_buf[0..args.len]
    else
        try allocator.alloc(applicability.ArgShape, args.len);
    defer if (args.len > shapes_buf.len) allocator.free(shapes);
    for (args, 0..) |*a, i| shapes[i] = shapeOfValueMember(self, a);

    const all_sigs = try allocator.alloc(applicability.SigView, candidates.len);
    defer allocator.free(all_sigs);
    for (candidates, 0..) |c, i| all_sigs[i] = sigViewOfMember(self, &c.func, true);

    const recv_shape = shapeOfValueMember(self, receiver);
    const scope = applicability.ApplicabilityScope{
        .member = true,
        .rank_extensions = true,
        .is_extension = true,
        .receiver = recv_shape,
        .all_candidates = all_sigs,
        .ctx = @ptrCast(self),
        .refine = applicRefineCbM,
        .subtype = applicSubtypeCbM,
        .identity_conflict = applicIdentityConflictCbM,
        .ext_recv_match = applicExtRecvMatchCb,
        .ext_is_subtype_name = applicExtSubtypeNameCb,
        .ext_owner_rank = applicExtOwnerRankCb,
        .ext_known_package = applicKnownPackageCb,
        .type_var = applicTypeVarCbM,
    };

    const check_inv = trace.invariantsEnabled();
    var tied: std.ArrayList(Func) = .empty;
    defer tied.deinit(self.allocator);
    var best: ?Candidate = null;
    var best_key: ExtKey = .{std.math.minInt(i32)} ** 8;
    for (candidates, 0..) |c, idx| {
        // The per-candidate ExtKey — applicability is Kotlin's hard gate
        // (`ext_key[0]`), then user-vs-shipped, subtype specificity, receiver
        // specificity, the numeric score, owner rank, parameter specificity,
        // and the stable lowest-FuncId discriminator.
        const key = (applicability.applicable(&all_sigs[idx], shapes, scope) orelse continue).ext_key.?;
        if (check_inv and best != null and std.mem.eql(i32, &key, &best_key)) {
            tied.append(self.allocator, c.func) catch {};
        }
        if (best == null or extKeyGreater(key, best_key)) {
            best = c;
            best_key = key;
            if (check_inv) {
                tied.clearRetainingCapacity();
                tied.append(self.allocator, c.func) catch {};
            }
        }
    }
    if (check_inv) {
        if (best) |w| {
            const name: []const u8 = if (candidates.len > 0) candidates[0].func.name else "";
            checkOverloadUnique(name, &w.func, tied.items);
            checkFuncInRange(self, "scoreExtCandidates", w.fid);
        }
    }
    return best;
}

fn isSubtypeName(self: *VmHost, allocator: Allocator, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return false;
    var q: std.ArrayList([]const u8) = .empty;
    defer q.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    q.append(allocator, a) catch return false;
    while (q.pop()) |c| {
        if (seen.contains(c)) continue;
        seen.put(c, {}) catch {};
        if (std.mem.eql(u8, c, b)) return true;
        const cg = self.classes.borrow();
        if (cg.get().get(c)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |s| q.append(allocator, s) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

fn enclosingChainClassOrder(self: *VmHost, allocator: Allocator) Allocator.Error!std.ArrayList([]const u8) {
    var v: std.ArrayList([]const u8) = .empty;
    const chain = try enclosingThisChain(self, allocator);
    defer allocator.free(chain);
    var closure: std.ArrayList(*const ClassDef) = .empty;
    defer closure.deinit(allocator);
    // Persistent across the whole chain: a supertype shared by an inner and
    // an outer `this` is ranked at its innermost occurrence (first match
    // wins in `applicExtOwnerRankCb`), so it must appear only once.
    var seen: std.ArrayList(*const ClassDef) = .empty;
    defer seen.deinit(allocator);
    for (chain) |value| {
        var cur: ?Value = value;
        while (cur) |cv| {
            if (cv == .Instance) {
                const g = cv.Instance.borrow();
                closure.clearRetainingCapacity();
                collectClassClosure(g.get().class.asPtr(), &closure, &seen, allocator);
                for (closure.items) |cd| try v.append(allocator, cd.name);
                const outer = g.get().outer;
                g.deinit();
                cur = outer;
            } else break;
        }
    }
    return v;
}

fn classCompanionForward(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const cls = receiver.Class;
    var cname: []const u8 = undefined;
    {
        const cg = cls.borrow();
        cname = cg.get().name;
        cg.deinit();
    }
    const simple = simpleName(cname);
    const comp_name = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const comp = &mg.get().registry.companion_singletons;
        if (comp.get(cname)) |c| break :blk c;
        if (comp.get(simple)) |c| break :blk c;
        break :blk null;
    };
    if (comp_name) |cn| {
        const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
            .ok => |maybe| maybe,
            .err => |e| return .{ .err = e },
        };
        if (singleton) |s| {
            if (s == .Instance) {
                const r = try callMemberRec(self, allocator, &s, name, args);
                if (r == .ok) return r;
                freeDispatchMiss(allocator, r);
            }
        }
    }
    return null;
}

fn instanceCompanionFallback(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var recv_id: u64 = undefined;
    var start: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        recv_id = g.get().identity;
        start = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    // Walk the full supertype graph (not just the first supertype): a
    // class may list an interface ahead of the superclass whose companion
    // declares `name`.
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    try queue.append(allocator, start);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cname = queue.items[head];
        if (seen.contains(cname)) continue;
        try seen.put(cname, {});
        const comp_name = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.companion_singletons.get(cname);
        };
        if (comp_name) |cn| {
            const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                .ok => |maybe| maybe,
                .err => |e| return .{ .err = e },
            };
            if (singleton) |s| {
                if (s == .Instance) {
                    const sg = s.Instance.borrow();
                    const sid = sg.get().identity;
                    sg.deinit();
                    if (sid != recv_id) {
                        const r = try callMemberRec(self, allocator, &s, name, args);
                        if (r == .ok) return r;
                        // The companion probe missed; free its discarded
                        // `Vm::call_member` message before trying the next.
                        freeDispatchMiss(allocator, r);
                    }
                }
            }
        }
        const cg = self.classes.borrow();
        if (cg.get().get(cname)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |sn| queue.append(allocator, sn) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return null;
}

// -------------------------------------------------------------------------
// Remaining public entry points.
// -------------------------------------------------------------------------

pub fn callMemberNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, false, null, false, null);
}

/// `callMemberNamed` with the receiver's DECLARED type head (a bare call
/// on the implicit `this` of an extension body). Extension dispatch then
/// resolves against the static type, as kotlinc does.
pub fn callMemberNamedStatic(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, false, static_recv, false, null);
}

/// Per-receiver probe for the bare-name resolver's innermost-first
/// candidate walk: members and *receiver-compatible* extensions of this
/// one receiver. The unproven-compatibility extension pick reports a
/// clean miss here so it cannot pre-empt a real member of an outer
/// receiver; the resolver retries leniently (`callMemberNamed`) only
/// after every receiver missed strictly.
///
/// `static_recv` is the receiver's DECLARED type head when the caller
/// knows it (the bare-call resolver inside an extension body, whose
/// implicit `this` has the extension's declared receiver type). Kotlin
/// resolves extensions against the static receiver type, so when present
/// it replaces the runtime-type proof in the extension fallback: inside
/// `fun I.helper()` a bare `describe()` binds `I.describe` even when the
/// runtime value is a subtype with its own `describe` extension.
pub fn callMemberStrictExt(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
    const r = try callMemberNamedInner(self, allocator, receiver, name, args, arg_names, true, static_recv, false, null);
    if (runtime.getenvSlice("KLIO_NU_TRACE")) |w| {
        if (std.mem.eql(u8, w, name)) {
            const tag: []const u8 = switch (r) {
                .ok => "ok",
                .err => |e| @tagName(e),
            };
            const detail: []const u8 = switch (r) {
                .err => |e| switch (e) {
                    .Unimplemented => |m| m,
                    else => "",
                },
                else => "",
            };
            std.debug.print("[strictext] name={s} recv={s} -> {s} {s}\n", .{ name, receiver.typeFqn(), tag, detail });
        }
    }
    return r;
}

/// Whether the committed extension target's declared receiver definitely
/// excludes `recv` — the deferred direct-call leg falls back to name-based
/// resolution instead of executing a target the receiver cannot satisfy.
pub fn committedExtReceiverDisproven(self: *VmHost, fid: FuncId, recv: *const Value) bool {
    const mg = self.module.borrow();
    const f = mg.get().funcById(fid);
    mg.deinit();
    const ff = f orelse return true;
    if (ff.params.len == 0) return true;
    if (receiverViolatesTypeParamBound(self, fid, &ff.params[0].ty, recv)) return true;
    return argDefinitelyNotParamType(self, &ff.params[0].ty, recv);
}

/// The committed extension target's declared receiver is strictly PROVEN
/// by `recv` (the walk's pass-1 criterion; erasure-unprovable receivers
/// fall to the not-disproven pass).
pub fn committedExtReceiverProven(self: *VmHost, allocator: Allocator, fid: FuncId, recv: *const Value) bool {
    const mg = self.module.borrow();
    const f = mg.get().funcById(fid);
    mg.deinit();
    const ff = f orelse return false;
    if (ff.params.len == 0) return false;
    return strictReceiverProven(self, allocator, recv, fid, &ff.params[0].ty) catch false;
}

/// Members-only dispatch: the strict member walk with the extension
/// fallback suppressed, for a call whose extension target the lowering
/// already committed.
pub fn callMemberMembersOnly(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, true, static_recv, true, null);
}

/// The lenient members-only pass (erasure-unprovable receivers), extension
/// fallback still suppressed.
pub fn callMemberMembersOnlyLenient(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, false, static_recv, true, null);
}

/// Member dispatch with the receiver's DECLARED type constraining only the
/// extension selection (Kotlin's static member-vs-extension resolution).
pub fn callMemberNamedDeclared(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, declared_recv: ?[]const u8) Allocator.Error!EvalResult {
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, false, null, false, declared_recv);
}

fn callMemberNamedInner(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names_in: []const ?[]const u8, strict_ext: bool, static_recv: ?[]const u8, no_ext: bool, declared_recv: ?[]const u8) Allocator.Error!EvalResult {
    // Receiver-function-typed property invoked as a call (see
    // `recvFnFieldInvoke` on the static ladder): the stored lambda runs
    // with the owning instance as its receiver.
    if (try recvFnFieldInvoke(self, allocator, receiver, name, args)) |r| return r;
    // A member `invoke` whose only named arguments are plugin-synthetic
    // (`$composer = c, $changed = n`): the names were emitted against a
    // transformed closure's literal parameter names, but a memo-wrapped
    // value is a ComposableLambdaImpl whose `invoke(composer, changed)`
    // members use plain names, so the named binding can never match. The
    // pair is appended in declaration order, so positional binding is
    // exact — drop the synthetic names.
    var arg_names = arg_names_in;
    if (receiver.* == .Instance and std.mem.eql(u8, name, "invoke")) {
        var any_synth = false;
        var all_synth = true;
        for (arg_names) |n| {
            if (n) |nn| {
                any_synth = true;
                if (!std.mem.startsWith(u8, nn, "$")) all_synth = false;
            }
        }
        if (any_synth and all_synth) arg_names = &.{};
    }
    var any_named = false;
    for (arg_names) |n| {
        if (n != null) any_named = true;
    }

    // data-class `copy(name = …)`.
    if (std.mem.eql(u8, name, "copy") and receiver.* == .Instance) {
        if (try copyNamed(self, allocator, receiver, args, arg_names)) |r| return r;
    }

    // `CharArray.concatToString(startIndex = …)` / `(endIndex = …)`: the
    // subrange overload is handled inline by the array-member dispatch, not
    // the intrinsic table, so its `(startIndex = 0, endIndex = size)` defaults
    // are filled here before the positional handler runs.
    if (any_named and receiver.* == .Array and std.mem.eql(u8, name, "concatToString")) {
        const size: i64 = @intCast(receiver.Array.len());
        var start: i64 = 0;
        var end: i64 = size;
        for (args, 0..) |a, i| {
            const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
            if (nm) |an| {
                if (std.mem.eql(u8, an, "startIndex")) start = a.asI64() orelse 0;
                if (std.mem.eql(u8, an, "endIndex")) end = a.asI64() orelse size;
            }
        }
        const filled = [_]Value{ .{ .Int = @intCast(start) }, .{ .Int = @intCast(end) } };
        return try callMemberInnerStatic(self, allocator, receiver, name, &filled, strict_ext, static_recv, no_ext, declared_recv);
    }

    // Stdlib intrinsic dispatch with named args.
    if (any_named) {
        if (try stdlibNamedDispatch(self, allocator, receiver, name, args, arg_names)) |r| return r;
        // Pack-installed host bindings take their arguments positionally; a
        // named call reaches them only after being put back in declaration
        // order.
        if (try instanceBindingNamedProbe(self, allocator, receiver, name, args, arg_names)) |r| return r;
    }

    // User extension / member fn with named args.
    if (any_named) {
        if (try userMethodNamed(self, allocator, receiver, name, args, arg_names)) |r| return r;
    }

    // Nested-class construction on a class receiver with named arguments
    // (`Outer.Nested(x, field = y)`). The positional path constructs by
    // `newInstanceById`, which cannot honor the names — a primary-ctor
    // default skipped by a named argument would otherwise bind positionally.
    // Resolve the nested class the same way the positional path does and
    // construct it through the name-aware path. (A companion `invoke`
    // operator routes the call here rather than to a bare `NewInstance`.)
    if (any_named and receiver.* == .Class) {
        const cg = receiver.Class.borrow();
        const cname = cg.get().name;
        const cfqn = cg.get().fqn;
        cg.deinit();
        const mg = self.module.borrow();
        const mod = mg.get();
        var class_id: ?ir.ClassId = blk: {
            const rid = mod.classIdByFqn(cfqn) orelse mod.classId(cname) orelse break :blk null;
            break :blk mod.classIdNestedIn(rid, name);
        };
        if (class_id == null) {
            const fqn_probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cfqn, name });
            defer if (runtime.freeScratch()) allocator.free(fqn_probe);
            class_id = mod.classIdByFqn(fqn_probe);
        }
        mg.deinit();
        if (class_id) |cid| {
            return self.newInstanceNamed(allocator, cid, args, arg_names, null);
        }
    }

    // Named nested-class construction through an OBJECT qualifier
    // (`Object.Nested(field = y)`, e.g. `MaterialTheme.Values(typography = t)`):
    // the object's bare name lowered to its singleton value, so the receiver is
    // an `.Instance`, not a `.Class`. Honor the names here — the positional path
    // would bind a differently-ordered named-arg list to the wrong ctor params.
    if (any_named and receiver.* == .Instance) {
        const cid: ?ir.ClassId = blk: {
            const ig = receiver.Instance.borrow();
            defer ig.deinit();
            const icg = ig.get().class.borrow();
            defer icg.deinit();
            if (!host_globals.progHasObjectName(self, icg.get().name)) break :blk null;
            const mg = self.module.borrow();
            defer mg.deinit();
            const rid = mg.get().classIdByFqn(icg.get().fqn) orelse mg.get().classId(icg.get().name) orelse break :blk null;
            break :blk mg.get().classIdNestedIn(rid, name);
        };
        if (cid) |c| return self.newInstanceNamed(allocator, c, args, arg_names, null);
    }

    // Positional dispatch first.
    const primary = try callMemberInnerStatic(self, allocator, receiver, name, args, strict_ext, static_recv, no_ext, declared_recv);
    if (!(primary == .err and primary.err == .Unimplemented)) return primary;

    // Class-hierarchy method walk for a class-qualified lowered name.
    if (receiver.* == .Instance) {
        const fallback = instanceMethodWalkNamed(self, allocator, receiver, name, args, null) catch |alloc_err| {
            freeDispatchMiss(allocator, primary);
            return alloc_err;
        };
        if (fallback) |r| {
            freeDispatchMiss(allocator, primary);
            return r;
        }
    }
    return primary;
}

fn copyNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var is_data = false;
    var n_params: usize = 0;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        is_data = cg.get().is_data;
        n_params = cg.get().primary_params.len;
        cg.deinit();
        g.deinit();
    }
    if (!is_data) return null;
    var slots = try allocator.alloc(?Value, n_params);
    defer allocator.free(slots);
    for (slots) |*s| s.* = null;
    var positional_idx: usize = 0;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        for (args, 0..) |a, i| {
            const named: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
            if (named) |arg_name| {
                for (cg.get().primary_params, 0..) |p, pos| {
                    if (std.mem.eql(u8, p.name, arg_name)) {
                        slots[pos] = a;
                        break;
                    }
                }
            } else {
                if (positional_idx < n_params) slots[positional_idx] = a;
                positional_idx += 1;
            }
        }
        cg.deinit();
        g.deinit();
    }
    var new_args: std.ArrayList(Value) = .empty;
    defer new_args.deinit(allocator);
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        for (cg.get().primary_params, 0..) |p, idx| {
            const v = slots[idx] orelse (g.get().get(p.name) orelse Value.Null);
            try new_args.append(allocator, v);
        }
        cg.deinit();
        g.deinit();
    }
    return try reconstructDataClass(self, allocator, inst, new_args.items);
}

fn stdlibNamedDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    const type_fqn = receiver.typeFqn();
    const probes = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_fqn, name }),
        try std.fmt.allocPrint(allocator, "kotlin.text.{s}", .{name}),
        try std.fmt.allocPrint(allocator, "kotlin.collections.{s}", .{name}),
        try std.fmt.allocPrint(allocator, "kotlin.{s}", .{name}),
    };
    // The probe keys are scratch for the lookup loop; free them on exit (a
    // per-stdlib-call leak on the ktor request path).
    defer if (runtime.freeScratch()) for (probes) |p| allocator.free(p);
    for (probes) |probe| {
        const params = stdlib.paramNames(probe) orelse continue;
        var slots = try allocator.alloc(?Value, params.len);
        defer allocator.free(slots);
        for (slots) |*s| s.* = null;
        var positionals: std.ArrayList(Value) = .empty;
        defer positionals.deinit(allocator);
        for (args, 0..) |a, i| {
            const named: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
            if (named) |arg_name| {
                for (params, 0..) |p, pos| {
                    if (std.mem.eql(u8, p, arg_name)) {
                        slots[pos] = a;
                        break;
                    }
                }
            } else {
                try positionals.append(allocator, a);
            }
        }
        // Trailing lambda binds to the last parameter.
        if (positionals.items.len != 0) {
            const last = positionals.items[positionals.items.len - 1];
            if (last == .IrClosure and params.len != 0 and slots[params.len - 1] == null) {
                slots[params.len - 1] = positionals.pop();
            }
        }
        var pit: usize = 0;
        for (slots) |*slot| {
            if (slot.* == null) {
                if (pit < positionals.items.len) {
                    slot.* = positionals.items[pit];
                    pit += 1;
                } else break;
            }
        }
        var reordered: std.ArrayList(Value) = .empty;
        defer reordered.deinit(allocator);
        for (slots) |s| try reordered.append(allocator, s orelse Value.Null);
        while (reordered.items.len != 0 and reordered.items[reordered.items.len - 1] == .Null) {
            _ = reordered.pop();
        }
        if (lookupIntrinsic(self, probe)) |func| {
            const all_args = try prependReceiver(allocator, receiver, reordered.items);
            defer if (runtime.freeScratch()) allocator.free(all_args);
            return try dispatchIntrinsic(self, allocator, probe, func, all_args);
        }
        break;
    }
    return null;
}

fn userMethodNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    // An applicable member of the receiver's own class outranks every
    // extension (kotlinc: members win) — `buffer.write(bytes, startIndex =
    // …)` binds the `ByteArray` member, not the `ByteString` extension.
    if (receiver.* == .Instance) {
        if (try instanceMethodWalkNamed(self, allocator, receiver, name, args, arg_names)) |r| return r;
        // Class delegation with named arguments: a delegated interface
        // member (`class LayoutNodeDrawScope(...) : DrawScope by
        // canvasDrawScope` serving `drawRoundRect(brush = …, …)`) forwards
        // to the delegate with the names intact — the positional forward
        // later in the ladder scrambles the binding.
        if (try delegateForwardNamed(self, allocator, receiver, name, args, arg_names)) |r| return r;
    }
    if (resolveExtOverloadLocal(self, allocator, name, receiver, args, arg_names)) |fid| {
        const all = try prependReceiver(allocator, receiver, args);
        defer if (runtime.freeScratch()) allocator.free(all);
        var names = try allocator.alloc(?[]const u8, arg_names.len + 1);
        defer if (runtime.freeScratch()) allocator.free(names);
        names[0] = null;
        @memcpy(names[1..], arg_names);
        const mg = self.module.borrow();
        const mod = mg.get();
        // A member-extension's body has its declaring class's `this` in
        // lexical scope. Seed the callee frame with that owner instance,
        // exactly as `extensionFnFallback` does — without it a bare
        // sibling call inside the body (`placeApparentToRealOffset`
        // inside `PlacementScope`'s `placeWithLayer`) has no owner
        // candidate and misses.
        var pushed_owner = false;
        if (mod.registry.member_ext_owner_class.get(fid)) |owner| {
            if (try memberExtOwnerInstance(self, allocator, receiver, owner)) |inst| {
                ir.eval.pushEnclosing(&inst);
                pushed_owner = true;
            }
        }
        const r = try callFuncNamedRec(self, allocator, mod, fid, all, names);
        if (pushed_owner) ir.eval.popEnclosing();
        mg.deinit();
        return r;
    }
    return null;
}

/// Resolve the user extension/top-level fn an unqualified `recv.name(args)`
/// would dispatch to (same candidate selection as `extensionFnFallback`).
fn resolveExtOverloadLocal(self: *VmHost, allocator: Allocator, name: []const u8, receiver: *const Value, args: []const Value, arg_names: []const ?[]const u8) ?FuncId {
    const want = args.len + 1;
    var visible_owners = enclosingOwnerSet(self, allocator) catch return null;
    defer visible_owners.deinit();
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        for (mod.funcsBySimpleName(name)) |fid| {
            const f = funcAt(mod, fid) orelse continue;
            if (!(f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this"))) continue;
            // Shape gate with a vararg allowance: a vararg param absorbs
            // surplus positional args, so the declared param count may sit
            // below the supplied count.
            if (f.params.len < want) {
                var has_vararg = false;
                for (f.params) |*p| {
                    if (p.is_vararg) {
                        has_vararg = true;
                        break;
                    }
                }
                if (!has_vararg) continue;
            }
            if (privateFnHiddenHere(self, mod, fid)) continue;
            if (!memberExtVisible(self, mod, fid, &visible_owners)) continue;
            // A candidate whose declared receiver definitely excludes this
            // runtime receiver is not applicable at all (kotlinc drops it):
            // `UIntArray.fill` never binds a plain `Array` receiver even when
            // no other overload survives the walk.
            if (receiverViolatesTypeParamBound(self, fid, &f.params[0].ty, receiver)) continue;
            if (builtinReceiverDisproven(receiver, f.params[0].ty.name)) continue;
            if (argDefinitelyNotParamType(self, &f.params[0].ty, receiver)) continue;
            // Full applicability under the actual binding (kotlinc semantics):
            // each supplied name must hit a declared param, positional args
            // fill leading params (with the trailing-lambda rule), every
            // argument's type must be compatible with the param it binds, and
            // every unbound param must be defaulted/vararg. This subsumes the
            // bare "every name is a param" filter and, crucially, rejects an
            // overload whose positional slot takes an argument of the wrong
            // type — e.g. `produce(ctx, cap, onBufferOverflow, start = …,
            // block = …)` must not bind the 5-param `produce(ctx, cap, start,
            // onCompletion, block)` (the `BufferOverflow` would land in
            // `start: CoroutineStart`).
            if (!memberApplicableForWalkNamed(self, &f, args, arg_names)) continue;
            candidates.append(allocator, .{ .fid = fid, .func = f }) catch {};
        }
    }
    if (trace.enabled(name)) {
        for (candidates.items) |c| {
            const recv_ty = if (c.func.params.len > 0) c.func.params[0].ty.name else "?";
            trace.emit("extLocal cand fid={d} fqn={s} recv_ty={s} nparams={d}", .{ c.fid.int(), c.func.fqn, recv_ty, c.func.params.len });
        }
    }
    if (candidates.items.len == 0) return null;
    if (candidates.items.len == 1) return candidates.items[0].fid;
    const chosen = scoreExtCandidates(self, allocator, receiver, candidates.items, args) catch return null;
    if (trace.enabled(name)) {
        if (chosen) |c| trace.emit("extLocal chose fid={d} fqn={s} recv_ty={s}", .{ c.fid.int(), c.func.fqn, c.func.params[0].ty.name });
    }
    return if (chosen) |c| c.fid else null;
}

/// Applicability for the class-hierarchy walk's name match: positional
/// fit (via `pickMethodOverload`'s single-candidate rules) or Kotlin's
/// trailing-lambda alignment — the trailing callable binds to the LAST
/// function-typed parameter with every skipped middle parameter
/// defaulted.
fn memberApplicableForWalk(self: *VmHost, f: *const Func, args: []const Value) bool {
    {
        const one = [_]Func{f.*};
        if (pickMethodOverload(self, null, &one, args) != null) return true;
    }
    if (args.len == 0) return false;
    const last_arg = args[args.len - 1];
    const trailing_callable = switch (last_arg) {
        .IrClosure, .Function, .BoundMethod, .BoundUserMethod, .Intrinsic => true,
        else => false,
    };
    if (!trailing_callable) return false;
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const effective = f.params[skip..];
    if (args.len > effective.len or effective.len == 0) return false;
    const last_ty = resolveAliasName(self, effective[effective.len - 1].ty.name);
    const last_is_fn = std.mem.startsWith(u8, last_ty, "Function") or
        std.mem.indexOf(u8, last_ty, "->") != null or
        (last_ty.len > 0 and last_ty.len <= 2 and allUppercase(last_ty));
    if (!last_is_fn) return false;
    // Leading args fill the leading params; the middle params between the
    // last positional arg and the trailing-lambda slot must be defaulted
    // (or varargs).
    const defaults = funcDefaults(self, f);
    var k: usize = args.len - 1;
    while (k + 1 < effective.len) : (k += 1) {
        if (!(effective[k].is_vararg or paramHasDefault(defaults, skip + k))) return false;
    }
    return true;
}

/// `memberApplicableForWalk` for a call that supplies argument names:
/// every supplied name must name a declared value parameter (kotlinc: a
/// candidate without the named param is not applicable), each argument is
/// checked against the parameter it would actually bind (by name when
/// named, by leading position otherwise), and every unbound parameter
/// must be defaulted or a vararg.
fn memberApplicableForWalkNamed(self: *VmHost, f: *const Func, args: []const Value, arg_names: ?[]const ?[]const u8) bool {
    const names = arg_names orelse return memberApplicableForWalk(self, f, args);
    var any_named = false;
    for (names) |n| {
        if (n != null) any_named = true;
    }
    if (!any_named) return memberApplicableForWalk(self, f, args);

    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const effective = f.params[skip..];
    var bound = [_]bool{false} ** 64;
    if (effective.len > bound.len) return memberApplicableForWalk(self, f, args);
    var positional: usize = 0;
    for (args, 0..) |*a, i| {
        const supplied_name: ?[]const u8 = if (i < names.len) names[i] else null;
        var param: ?*const ir.Param = null;
        if (supplied_name) |nm| {
            for (effective, 0..) |*p, k| {
                if (std.mem.eql(u8, p.name, nm)) {
                    // A named argument that targets a parameter already filled
                    // (by a leading positional argument) makes this overload
                    // inapplicable — kotlinc rejects the double binding. This
                    // is what distinguishes `produce(ctx, cap, onBufferOverflow,
                    // start = …)` from the 5-param `produce(ctx, cap, start,
                    // onCompletion, …)`, whose 3rd positional already fills
                    // `start` that `start = …` then re-targets.
                    if (bound[k]) return false;
                    param = p;
                    bound[k] = true;
                    break;
                }
            }
            if (param == null) return false;
        } else if (i == args.len - 1 and isCallable(a) and effective.len > 0 and
            !bound[effective.len - 1] and
            lastParamIsFunctionShaped(self, &effective[effective.len - 1]))
        {
            // Kotlin's trailing-lambda rule: the unnamed trailing callable
            // binds the LAST function-typed parameter (the middle gap must
            // be defaulted, which the unbound-parameter check below
            // enforces).
            param = &effective[effective.len - 1];
            bound[effective.len - 1] = true;
        } else {
            if (positional < effective.len) {
                param = &effective[positional];
                bound[positional] = true;
                // A vararg parameter absorbs this and every later unnamed
                // positional argument (Kotlin: params after a vararg bind
                // by name only), so the cursor stays on it.
                if (!effective[positional].is_vararg) positional += 1;
            } else if (effective.len == 0 or !effective[effective.len - 1].is_vararg) {
                return false;
            } else {
                positional += 1;
            }
        }
        if (param) |p| {
            if (!p.is_vararg and argDefinitelyNotParamType(self, &p.ty, a)) return false;
        }
    }
    const defaults = funcDefaults(self, f);
    for (effective, 0..) |*p, k| {
        if (bound[k] or p.is_vararg or paramHasDefault(defaults, skip + k)) continue;
        return false;
    }
    return true;
}

/// Score an applicable named-call candidate by summing each argument's type
/// match against the parameter it binds (positional or by name), mirroring
/// `memberApplicableForWalkNamed`'s arg→param mapping. Higher is a better fit;
/// an argument that only weakly matches (or is a wrong-but-not-disproven type
/// like a `Color` against a `Brush` parameter) contributes less, so the closer
/// overload wins. Used to break ties among same-named overloads of one class.
/// How many of `f`'s declared parameters the call leaves UNBOUND — the ones a
/// default (or an empty vararg) has to fill. Kotlin's specificity rule ranks a
/// candidate that needs no default-filling above one that does, which is what
/// separates two overloads whose parameter lists are otherwise a subset/superset
/// pair: `DrawScope.drawImage(…, blendMode)` and
/// `DrawScope.drawImage(…, blendMode, filterQuality)` both accept the same nine
/// named arguments, and the concrete one delegates BY NAME to the abstract one —
/// so picking the superset re-selected the caller itself and recursed forever.
fn unboundParamCount(f: *const Func, args: []const Value, arg_names: ?[]const ?[]const u8) usize {
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const effective = f.params[skip..];
    var bound = [_]bool{false} ** 64;
    if (effective.len > bound.len) return 0;
    var positional: usize = 0;
    for (args, 0..) |_, i| {
        const supplied_name: ?[]const u8 = if (arg_names) |ns| (if (i < ns.len) ns[i] else null) else null;
        if (supplied_name) |nm| {
            for (effective, 0..) |*p, k| {
                if (!bound[k] and std.mem.eql(u8, p.name, nm)) {
                    bound[k] = true;
                    break;
                }
            }
        } else {
            while (positional < effective.len and bound[positional]) positional += 1;
            if (positional < effective.len) {
                bound[positional] = true;
                positional += 1;
            }
        }
    }
    var n: usize = 0;
    for (effective, 0..) |*p, k| {
        if (!bound[k] and !p.is_vararg) n += 1;
    }
    return n;
}

fn scoreNamedMemberCandidate(self: *VmHost, f: *const Func, args: []const Value, arg_names: ?[]const ?[]const u8) i32 {
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const effective = f.params[skip..];
    var bound = [_]bool{false} ** 64;
    if (effective.len > bound.len) return 0;
    var positional: usize = 0;
    var total: i32 = 0;
    for (args, 0..) |*a, i| {
        const supplied_name: ?[]const u8 = if (arg_names) |ns| (if (i < ns.len) ns[i] else null) else null;
        var param: ?*const ir.Param = null;
        if (supplied_name) |nm| {
            for (effective, 0..) |*p, k| {
                if (!bound[k] and std.mem.eql(u8, p.name, nm)) {
                    param = p;
                    bound[k] = true;
                    break;
                }
            }
        } else {
            while (positional < effective.len and bound[positional]) positional += 1;
            if (positional < effective.len) {
                param = &effective[positional];
                bound[positional] = true;
                positional += 1;
            }
        }
        if (param) |p| {
            if (p.is_vararg) continue;
            if (overloadScoreArg(self, &p.ty, a)) |s| {
                total += s;
            } else {
                total -= 1000;
            }
        }
    }
    return total;
}

/// Mirrors `memberApplicableForWalk`'s last-param shape test: a declared
/// function type, a typealias expanding to one, or a bare type parameter.
fn lastParamIsFunctionShaped(self: *VmHost, p: *const ir.Param) bool {
    const last_ty = resolveAliasName(self, p.ty.name);
    return std.mem.startsWith(u8, last_ty, "Function") or
        std.mem.indexOf(u8, last_ty, "->") != null or
        (last_ty.len > 0 and last_ty.len <= 2 and allUppercase(last_ty));
}

/// Member invocations the named walk currently has on the stack, as
/// (FuncId, receiver identity) pairs. An interface DEFAULT method whose body
/// delegates BY NAME to a sibling overload must not re-select ITSELF: klio's
/// class method table omits abstract members, so the walk sees only the default
/// and re-binds it, defaulting the parameter the sibling does not declare and
/// recursing forever (`DrawScope.drawImage(…, filterQuality)` delegating to the
/// abstract `drawImage(…, blendMode)` — every `Image` composable hung). Skipping
/// the in-flight frame lets the ladder continue to the class-delegate forward,
/// which is where the real override lives (`LayoutNodeDrawScope : DrawScope by
/// canvasDrawScope`). Bounded; overflow simply disables the guard for the excess.
threadlocal var walk_active: [64]struct { fid: u32, ident: usize } = undefined;
threadlocal var walk_active_len: usize = 0;

fn receiverIdent(v: *const Value) usize {
    return switch (v.*) {
        .Instance => |i| @intFromPtr(i.cell),
        else => 0,
    };
}

fn walkActive(fid: FuncId, ident: usize) bool {
    if (ident == 0) return false;
    for (walk_active[0..walk_active_len]) |e| {
        if (e.fid == fid.int() and e.ident == ident) return true;
    }
    return false;
}

fn instanceMethodWalkNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: ?[]const ?[]const u8) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var start_name: []const u8 = undefined;
    var recv_fqn: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        start_name = cg.get().name;
        recv_fqn = cg.get().fqn;
        cg.deinit();
        g.deinit();
    }
    const WalkItem = struct { cid: ?ir.ClassId, name: []const u8 };
    var queue: std.ArrayList(WalkItem) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    // Walk the receiver's real class hierarchy by identity (IR class ids),
    // starting from its exact FQN, so a same-simple-name class in another
    // package can never shadow an inherited method.
    const start_cid: ?ir.ClassId = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classIdByFqn(recv_fqn);
    };
    try queue.append(allocator, .{ .cid = start_cid, .name = start_name });
    var method_fid: ?FuncId = null;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const item = queue.items[head];
        var ir_class: ?ir.Class = null;
        {
            const mg = self.module.borrow();
            defer mg.deinit();
            const mod = mg.get();
            if (item.cid) |cid| {
                if (@intFromEnum(cid) < mod.classes.items.len) ir_class = mod.classes.items[@intFromEnum(cid)];
            }
            if (ir_class == null) {
                for (mod.classes.items) |c| {
                    if (std.mem.eql(u8, c.name, item.name)) {
                        ir_class = c;
                        break;
                    }
                }
            }
            // Dedup on the resolved class's FQN (identity) so two distinct
            // classes that share a simple name are each walked once.
            const dedup_key = if (ir_class) |irc| irc.fqn else item.name;
            if (seen.contains(dedup_key)) continue;
            try seen.put(dedup_key, {});
            if (ir_class) |irc| {
                if (runtime.getenvSlice("KLIO_NU_TRACE")) |want| {
                    if (std.mem.eql(u8, want, name)) {
                        std.debug.print("[mwalk-class] {s} methods={d} supers=", .{ irc.fqn, irc.methods.len });
                        for (irc.supertypes, 0..) |sid, si| {
                            if (si != 0) std.debug.print(",", .{});
                            if (@intFromEnum(sid) < mod.classes.items.len) {
                                std.debug.print("{s}", .{mod.classes.items[@intFromEnum(sid)].fqn});
                            } else {
                                std.debug.print("#{d}", .{@intFromEnum(sid)});
                            }
                        }
                        std.debug.print("\n", .{});
                    }
                }
                // Among the applicable same-named overloads declared by THIS
                // class, pick the best by argument-type score — not merely the
                // first. Two overloads that differ only in one parameter's type
                // (`drawRoundRect(color: Color, …)` vs `(brush: Brush, …)`) are
                // both "applicable" when neither arg is provably wrong-typed, so
                // taking the first would bind the wrong one and scramble the
                // trailing defaulted parameters.
                var best_score: i32 = std.math.minInt(i32);
                var best_unbound: usize = std.math.maxInt(usize);
                for (irc.methods) |fid| {
                    if (funcAt(mod, fid)) |f| {
                        if (std.mem.eql(u8, f.name, name) or std.mem.eql(u8, simpleName(f.name), name)) {
                            if (runtime.getenvSlice("KLIO_NU_TRACE")) |want| {
                                if (std.mem.eql(u8, want, name)) {
                                    const defaults = funcDefaults(self, &f);
                                    std.debug.print("[mwalk] class={s} fid={d} params=", .{ irc.fqn, fid.int() });
                                    for (f.params, 0..) |p, pi| {
                                        if (pi != 0) std.debug.print(",", .{});
                                        std.debug.print("{s}{s}", .{ p.name, if (paramHasDefault(defaults, pi)) "=" else "" });
                                    }
                                    std.debug.print("\n", .{});
                                }
                            }
                            // A member EXTENSION found among the class's own
                            // methods binds the dispatch receiver as its
                            // EXTENSION receiver (params[0]). When the receiver
                            // is only the owner/dispatch instance and provably
                            // not the declared extension-receiver type, the
                            // direct bind is wrong: the call resolves through the
                            // extension path (owner from the enclosing `this`,
                            // extension receiver from an outer implicit receiver).
                            // Skip it so this walk does not mis-bind the owner as
                            // the extension receiver.
                            if (isMemberExt(mod, fid) and f.params.len > 0 and
                                std.mem.eql(u8, f.params[0].name, "this") and
                                receiverDefinitelyNotParam(self, &f.params[0].ty, receiver)) continue;
                            // A name match alone is not a candidate:
                            // the member must be *applicable* to the
                            // supplied args (an unsupplied param needs
                            // a default or vararg slot, a named arg
                            // needs a matching param, a typed arg must
                            // not definitely mismatch), or Kotlin
                            // resolution moves on to the next tier.
                            // Already executing this exact method on this exact
                            // receiver: re-selecting it is the self-delegation
                            // loop described on `walk_active`. Decline, so the
                            // ladder reaches the class-delegate forward.
                            if (walkActive(fid, receiverIdent(receiver))) continue;
                            if (memberApplicableForWalkNamed(self, &f, args, arg_names)) {
                                const sc = scoreNamedMemberCandidate(self, &f, args, arg_names);
                                // Argument types decide first; a tie goes to the
                                // MORE SPECIFIC signature — the one leaving fewer
                                // parameters for defaults to fill.
                                const ub = unboundParamCount(&f, args, arg_names);
                                if (method_fid == null or sc > best_score or
                                    (sc == best_score and ub < best_unbound))
                                {
                                    method_fid = fid;
                                    best_score = sc;
                                    best_unbound = ub;
                                }
                            }
                        }
                    }
                }
                if (method_fid == null) {
                    // Enqueue resolved supertypes by identity so the walk
                    // follows the real hierarchy, never a same-simple-name
                    // impostor.
                    for (irc.supertypes) |sid| {
                        if (@intFromEnum(sid) < mod.classes.items.len) {
                            try queue.append(allocator, .{ .cid = sid, .name = mod.classes.items[@intFromEnum(sid)].name });
                        }
                    }
                }
            }
        }
        if (method_fid != null) break;
        // Fallback for a receiver class with no unambiguous IR id (anonymous/
        // synthesized): expand supertypes from the registered simple names.
        if (ir_class == null) {
            const cg = self.classes.borrow();
            if (cg.get().get(item.name)) |def| {
                const dg = def.borrow();
                for (dg.get().supertype_names) |s| try queue.append(allocator, .{ .cid = null, .name = s });
                dg.deinit();
            }
            cg.deinit();
        }
    }
    if (method_fid) |fid| {
        const all = try prependReceiver(allocator, receiver, args);
        defer if (runtime.freeScratch()) allocator.free(all);
        var names = try allocator.alloc(?[]const u8, all.len);
        defer if (runtime.freeScratch()) allocator.free(names);
        names[0] = null;
        if (arg_names) |an| {
            for (an, 0..) |n, i| {
                if (i + 1 < names.len) names[i + 1] = n;
            }
            var k = an.len + 1;
            while (k < names.len) : (k += 1) names[k] = null;
        } else {
            var k: usize = 1;
            while (k < names.len) : (k += 1) names[k] = null;
        }
        const mg = self.module.borrow();
        const mod = mg.get();
        const ident = receiverIdent(receiver);
        const pushed = ident != 0 and walk_active_len < walk_active.len;
        if (pushed) {
            walk_active[walk_active_len] = .{ .fid = @intCast(fid.int()), .ident = ident };
            walk_active_len += 1;
        }
        const r = try callFuncNamedRec(self, allocator, mod, fid, all, names);
        if (pushed) walk_active_len -= 1;
        mg.deinit();
        return r;
    }
    return null;
}

/// A minimal `KClass` value carrying just a simple name (the last FQN
/// segment) and the fully-qualified name. Enough for `simpleName`,
/// `qualifiedName`, and FQN-keyed equality — used to give a builtin value or a
/// classId-less type a class literal.
pub fn syntheticClassFromFqn(allocator: Allocator, fqn: []const u8) Allocator.Error!Value {
    const dot = std.mem.lastIndexOfScalar(u8, fqn, '.');
    const simple = if (dot) |i| fqn[i + 1 ..] else fqn;
    const cd = try ObjRef(ClassDef).init(allocator, .{
        .name = try allocator.dupe(u8, simple),
        .fqn = try allocator.dupe(u8, fqn),
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
        .captured_env = try ObjRef(runtime.Env).init(allocator, runtime.Env.init(allocator)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    });
    return .{ .Class = cd };
}

/// True when `simple` names an unsigned primitive-array type, whose bare name
/// lowers to a constructor value (no IR classId) rather than a class.
fn isUnsignedArrayName(simple: []const u8) bool {
    const known = [_][]const u8{ "UIntArray", "ULongArray", "UByteArray", "UShortArray" };
    for (known) |k| {
        if (std.mem.eql(u8, simple, k)) return true;
    }
    return false;
}

pub fn memberRef(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    // `X::class` is a class reference — return the class itself. For an
    // instance receiver, reach into the runtime ClassDef.
    if (std.mem.eql(u8, name, "class")) {
        if (receiver.* == .Instance) {
            const ig = receiver.Instance.borrow();
            defer ig.deinit();
            return .{ .ok = .{ .Class = ig.get().class.clone() } };
        }
        // A `Type::class` value is already a class literal.
        if (receiver.* == .Class) return .{ .ok = receiver.* };
        // An unsigned-array TYPE literal lowers to its constructor
        // (`ULongArray::class`): recover the type name from the constructor.
        if (receiver.* == .Intrinsic) {
            const dot = std.mem.lastIndexOfScalar(u8, receiver.Intrinsic.fqn, '.');
            const simple = if (dot) |i| receiver.Intrinsic.fqn[i + 1 ..] else receiver.Intrinsic.fqn;
            if (isUnsignedArrayName(simple)) return .{ .ok = try syntheticClassFromFqn(allocator, receiver.Intrinsic.fqn) };
            return .{ .ok = try syntheticClassFromFqn(allocator, receiver.typeFqn()) };
        }
        if (receiver.* == .Function) {
            if (isUnsignedArrayName(receiver.Function.decl.name.name)) {
                const fqn = try std.fmt.allocPrint(allocator, "kotlin.{s}", .{receiver.Function.decl.name.name});
                return .{ .ok = try syntheticClassFromFqn(allocator, fqn) };
            }
            return .{ .ok = try syntheticClassFromFqn(allocator, receiver.typeFqn()) };
        }
        // A builtin throwable carries its dynamic class in its `fqn` field;
        // the static `typeFqn` would collapse every one to `kotlin.Throwable`.
        if (receiver.* == .Exception) {
            const g = receiver.Exception.fqn.borrow();
            defer g.deinit();
            return .{ .ok = try syntheticClassFromFqn(allocator, g.get().bytes) };
        }
        // `value::class` — the runtime KClass of a plain value or callable.
        return .{ .ok = try syntheticClassFromFqn(allocator, receiver.typeFqn()) };
    }
    // `recv::method` produces a callable wrapper backed by a synthetic
    // Instance carrying `__bound_receiver__` + `__bound_name__`; the
    // call_value path dispatches through them.
    const identity = blk: {
        const g = self.instance_id_counter.borrowMut();
        defer g.deinit();
        break :blk g.get().fetchAdd(1, .monotonic) + 1;
    };
    const cls_name = try std.fmt.allocPrint(allocator, "$bound_ref${s}", .{name});
    const env = try ObjRef(runtime.Env).init(allocator, runtime.Env.init(allocator));
    const synth_class = try ObjRef(ClassDef).init(allocator, .{
        .name = cls_name,
        .fqn = cls_name,
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
        .is_anonymous = true,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .nested_classes = &.{},
        .captured_env = env,
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    });
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(allocator, .{ .name = "__bound_receiver__", .value = receiver.* });
    const name_dup = try allocator.dupe(u8, name);
    try fields.append(allocator, .{ .name = "__bound_name__", .value = .{ .String = try runtime.strInitOwned(allocator, name_dup) } });
    // The reference's creation-site file: visibility of a file-private
    // target is decided where the reference is written, so the invoke
    // path re-installs this file while it dispatches by name.
    if (ir.eval.currentCallSiteSpan()) |sp| {
        try fields.append(allocator, .{ .name = "__bound_file__", .value = .{ .Int = @intCast(sp.file.int()) } });
    }
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = synth_class,
        .fields = fields,
        .outer = null,
        .identity = identity,
        .native_state = null,
    });
    return .{ .ok = .{ .Instance = inst } };
}

/// First supertype name registered for `class_name` in the runtime class
/// table (the head of the inheritance chain), if any. Caller owns nothing.
fn firstSupertypeName(self: *VmHost, allocator: Allocator, class_name: []const u8) ?[]const u8 {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return null;
    const dg = d.borrow();
    defer dg.deinit();
    const sups = dg.get().supertype_names;
    if (sups.len == 0) return null;
    // Class-table-owned (program-lifetime); returned borrowed per the contract.
    _ = allocator;
    return sups[0];
}

/// Whether the RECEIVER's own accessor-backed property `name` could hold a callable.
///
/// `getter_prop_names` is keyed by NAME alone, so ANY class with a getter-backed
/// property of that name arms the probe for EVERY receiver. That is how
/// `TextRange.min` -- `val min: Int get() = min(start, end)`, where the call is the
/// imported `kotlin.math.min` -- ended up reading itself: the member method missed,
/// the probe read the property, and the property's getter called `min` again,
/// forever.
///
/// The receiver's own getter decides. A declared function type can hold a callable;
/// a scalar or a registered concrete class cannot. A type parameter or a typealias
/// (`typealias Handler = () -> Unit`) names no registered class, so it stays
/// permissive -- either can be a function at runtime.
fn receiverPropCanHoldCallable(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    if (receiver.* != .Instance) return true;
    var cur: ?[]const u8 = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    var step: usize = 0;
    while (cur) |cn| {
        if (step > 64) return true;
        step += 1;
        const fid: ?FuncId = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().instance_prop_getters.get(.{ .a = cn, .b = name });
        };
        if (fid) |f| {
            const mg = self.module.borrow();
            defer mg.deinit();
            const func = mg.get().funcById(f) orelse return true;
            const rt = func.return_ty;
            if (isFunctionTypeRefResolved(self, &rt)) return true;
            if (isScalarKindName(rt.name)) return false;
            const known = blk: {
                const g = self.classes.borrow();
                defer g.deinit();
                break :blk g.get().get(rt.name) != null;
            };
            if (known and !classIsFunInterface(self, rt.name)) return false;
            return true;
        }
        cur = firstSupertypeName(self, self.allocator, cn);
    }
    return true;
}

/// Whether `class_name` names a registered `fun interface` (one abstract method,
/// so a lambda SAM-converts to it).
fn classIsFunInterface(self: *VmHost, class_name: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    return dg.get().is_fun_interface;
}

/// Whether `class_name` names a registered interface.
fn classIsInterface(self: *VmHost, class_name: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    return dg.get().is_interface;
}

/// `class_name`'s supertypes with the superclass ahead of the interfaces.
///
/// A supertype list keeps source order, and Kotlin does not require the
/// superclass to come first: `class FocusRequesterNode : FocusRequesterModifierNode,
/// Modifier.Node()` names the interface first. `super.onAttach()` there means
/// `Modifier.Node`'s, so a search that follows the list as written walks into the
/// interface and never reaches the class that actually declares the method.
/// Names are class-table-owned (program-lifetime); the returned slice is the
/// caller's.
fn supertypesClassFirst(self: *VmHost, allocator: Allocator, class_name: []const u8) Allocator.Error![]const []const u8 {
    const sups: []const []const u8 = blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        const d = g.get().get(class_name) orelse break :blk &.{};
        const dg = d.borrow();
        defer dg.deinit();
        break :blk dg.get().supertype_names;
    };
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (sups) |s| {
        if (!classIsInterface(self, s)) try out.append(allocator, s);
    }
    for (sups) |s| {
        if (classIsInterface(self, s)) try out.append(allocator, s);
    }
    return out.toOwnedSlice(allocator);
}

/// Whether `q` is one of `class_name`'s registered supertypes.
fn ownerHasSupertype(self: *VmHost, class_name: []const u8, q: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    for (dg.get().supertype_names) |s| {
        if (std.mem.eql(u8, s, q)) return true;
    }
    return false;
}

/// `[PATH]` record for a super-qualified dispatch, labelled with the
/// resolved static target class (`super(Base)`) rather than the runtime
/// receiver — super dispatch is static, so keying on the runtime class
/// would collide with the virtual call's key while legitimately selecting
/// a different declaration.
fn emitSuperPath(allocator: Allocator, decl_fqn: []const u8, fid: FuncId, target_class: []const u8, args: []const Value) void {
    if (!trace.pathEnabled()) return;
    const label = std.fmt.allocPrint(allocator, "super({s})", .{target_class}) catch return;
    defer allocator.free(label);
    vmhost.emitPathLabeled(allocator, "member_super", decl_fqn, fid, label, args);
}

pub fn callSuper(self: *VmHost, allocator: Allocator, receiver: *const Value, owner_class: []const u8, qualifier: ?[]const u8, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    _ = arg_names;
    // Find the parent class of owner_class — `super.method()` walks one
    // step up the inheritance chain. With `super<Q>`, dispatch on Q
    // directly; with `super@Q`, dispatch on Q's own parent.
    var pending: std.ArrayList([]const u8) = .empty;
    defer pending.deinit(allocator);
    if (qualifier) |q| {
        if (ownerHasSupertype(self, owner_class, q)) {
            // `q` is the const-pool super qualifier (program-lifetime); borrow it.
            try pending.append(allocator, q);
        } else {
            const sups = try supertypesClassFirst(self, allocator, q);
            defer allocator.free(sups);
            try pending.appendSlice(allocator, sups);
        }
    } else {
        const sups = try supertypesClassFirst(self, allocator, owner_class);
        defer allocator.free(sups);
        try pending.appendSlice(allocator, sups);
    }
    if (pending.items.len == 0) {
        const owner_fqn: []const u8 = blk: {
            const g = self.classes.borrow();
            defer g.deinit();
            const d = g.get().get(owner_class) orelse break :blk "<unregistered>";
            const dg = d.borrow();
            defer dg.deinit();
            break :blk dg.get().fqn;
        };
        return .{ .err = try typeErr(allocator, "super.{s}: owner_class `{s}` (table entry `{s}`) has no parent", .{ name, owner_class, owner_fqn }) };
    }
    var visited: std.StringHashMap(void) = .init(allocator);
    defer visited.deinit();

    // Search the supertypes, superclass before interfaces at every level, and
    // dispatch the first one that declares the method. Falling through to
    // call_member would re-enter virtual dispatch on the original
    // receiver and recurse forever for overriding methods.
    var step: usize = 0;
    while (pending.items.len != 0) {
        if (step > 128) break;
        step += 1;
        const cname = pending.orderedRemove(0);
        if (visited.contains(cname)) continue;
        try visited.put(cname, {});
        // First, an IR class method named `name` on this class.
        {
            const mg = self.module.borrow();
            const m = mg.get();
            var found_fid: ?FuncId = null;
            for (m.classes.items) |*cls_ir| {
                if (!std.mem.eql(u8, cls_ir.name, cname)) continue;
                // Collect every same-named method, then pick the overload that
                // matches the call's arity/types. Resolving by name alone binds
                // `super.listIterator(index)` to a no-arg `listIterator()` whose
                // body re-dispatches `listIterator(0)` virtually — an infinite
                // super/override cycle (AbstractMutableList$SubList).
                var cands: std.ArrayList(Func) = .empty;
                defer cands.deinit(allocator);
                for (cls_ir.methods) |fid| {
                    const cf = m.funcById(fid) orelse continue;
                    if (std.mem.eql(u8, cf.name, name)) cands.append(allocator, cf.*) catch {};
                }
                if (cands.items.len != 0) {
                    const chosen = pickMethodOverload(self, m, cands.items, args) orelse cands.items[0];
                    found_fid = chosen.id;
                }
                break;
            }
            if (found_fid) |fid| {
                const func = m.funcById(fid).?;
                mg.deinit();
                var all: std.ArrayList(Value) = .empty;
                try all.append(allocator, receiver.*);
                try all.appendSlice(allocator, args);
                const module_ref = self.module.clone();
                defer module_ref.deinit();
                emitSuperPath(allocator, func.fqn, fid, cname, args);
                return ir.eval.evalWith(VmHost, allocator, module_ref.borrow().get(), func, all, self);
            }
            mg.deinit();
        }
        // `super.<prop>` (a property read, lowered as a 0-arg CallSuper):
        // no method named `name` on this class — look for its property
        // getter. Walking from the parent skips the overriding subclass's
        // getter, so `override val x get() = super.x` reads the base.
        if (args.len == 0) {
            const getter_fid: ?FuncId = blk: {
                const pg = self.prog.borrow();
                defer pg.deinit();
                break :blk pg.get().instance_prop_getters.get(.{ .a = cname, .b = name });
            };
            if (getter_fid) |fid| {
                const mg = self.module.borrow();
                const m = mg.get();
                if (m.funcById(fid)) |func| {
                    mg.deinit();
                    var all: std.ArrayList(Value) = .empty;
                    try all.append(allocator, receiver.*);
                    const module_ref = self.module.clone();
                    defer module_ref.deinit();
                    emitSuperPath(allocator, func.fqn, fid, cname, args);
                    return ir.eval.evalWith(VmHost, allocator, module_ref.borrow().get(), func, all, self);
                }
                mg.deinit();
            }
        }
        // Not here: continue through this class's own supertypes.
        const sups = try supertypesClassFirst(self, allocator, cname);
        defer allocator.free(sups);
        try pending.appendSlice(allocator, sups);
    }

    // `super.<prop>` where the base property has no custom getter (a stored
    // val/var): read the backing field off the receiver instance directly.
    if (args.len == 0 and receiver.* == .Instance) {
        const ig = receiver.Instance.borrow();
        defer ig.deinit();
        if (ig.get().get(name)) |v| return .{ .ok = v };
    }

    // The chain bottomed out at a builtin (`Any` / `Throwable`), which
    // declares no IR method. Supply the inherited `Any`/`Throwable`
    // semantics so `override fun toString() = "${super.toString()} …"`
    // works through the exception hierarchy.
    if (receiver.* == .Instance) {
        const inst = receiver.Instance;
        if (std.mem.eql(u8, name, "toString") and args.len == 0) {
            return .{ .ok = try inheritedInstanceToString(allocator, inst, instanceIsThrowable(self, allocator, inst)) };
        }
        if (std.mem.eql(u8, name, "hashCode") and args.len == 0) {
            const ig = inst.borrow();
            defer ig.deinit();
            const hash: i64 = @bitCast(ig.get().identity);
            return .{ .ok = Value.newInt(hash) };
        }
        if (std.mem.eql(u8, name, "equals") and args.len == 1) {
            const same = switch (args[0]) {
                .Instance => |o| ObjRef(InstanceData).ptrEq(inst, o),
                else => false,
            };
            return .{ .ok = .{ .Bool = same } };
        }
    }
    return .{ .err = try typeErr(allocator, "super.{s}: no matching method up the supertype chain from `{s}`", .{ name, owner_class }) };
}

pub fn qualifiedThis(self: *VmHost, allocator: Allocator, receiver: *const Value, qualifier: []const u8) Allocator.Error!EvalResult {
    // Walk parent chain on the receiver's class for direct matches, then
    // traverse the `outer` chain for inner-class / local-class scenarios.
    // `this@Outer` from an Inner method walks to the captured outer.
    if (receiver.* == .Instance) {
        var cur: ?ObjRef(ClassDef) = blk: {
            const ig = receiver.Instance.borrow();
            defer ig.deinit();
            break :blk ig.get().class.clone();
        };
        var step: usize = 0;
        while (cur) |c| {
            if (step > 128) {
                c.deinit();
                break;
            }
            step += 1;
            const cg = c.borrow();
            const matched = std.mem.eql(u8, cg.get().name, qualifier) or std.mem.eql(u8, cg.get().fqn, qualifier);
            const next = blk: {
                break :blk if (cg.get().parent) |p| p.clone() else null;
            };
            cg.deinit();
            c.deinit();
            if (matched) return .{ .ok = receiver.* };
            cur = next;
        }
        // Walk the `outer` chain (inner-class / local-class capture).
        var outer: ?Value = blk: {
            const ig = receiver.Instance.borrow();
            defer ig.deinit();
            break :blk ig.get().outer;
        };
        var ostep: usize = 0;
        while (outer) |ov| {
            if (ostep > 128) break;
            ostep += 1;
            if (ov != .Instance) break;
            const o_inst = ov.Instance;
            var ocur: ?ObjRef(ClassDef) = blk: {
                const ig = o_inst.borrow();
                defer ig.deinit();
                break :blk ig.get().class.clone();
            };
            var inner_step: usize = 0;
            while (ocur) |c| {
                if (inner_step > 128) {
                    c.deinit();
                    break;
                }
                inner_step += 1;
                const cg = c.borrow();
                const matched = std.mem.eql(u8, cg.get().name, qualifier) or std.mem.eql(u8, cg.get().fqn, qualifier);
                const next = blk: {
                    break :blk if (cg.get().parent) |p| p.clone() else null;
                };
                cg.deinit();
                c.deinit();
                if (matched) return .{ .ok = .{ .Instance = o_inst.clone() } };
                ocur = next;
            }
            outer = blk: {
                const ig = o_inst.borrow();
                defer ig.deinit();
                break :blk ig.get().outer;
            };
        }
    }
    // No class match — `this@<fn-label>` (extension/lambda label) resolves
    // to the immediate receiver if the qualifier isn't a known class.
    // First try matching the qualifier against the enclosing-`this` chain.
    const chain = try enclosingThisChain(self, allocator);
    defer allocator.free(chain);
    for (chain) |encl_v| {
        if (encl_v != .Instance) continue;
        // Each enclosing receiver is checked through its own OUTER links
        // too: `this@Outer` inside an inner-class context (a delegation
        // expression, a nested lambda) reaches the enclosing instance
        // through the inner instance's outer chain — the enclosing
        // receiver itself is the inner instance, not the target.
        var walk: ?Value = encl_v;
        var outer_step: usize = 0;
        while (walk) |wv| {
            if (outer_step > 128) break;
            outer_step += 1;
            if (wv != .Instance) break;
            const o_inst = wv.Instance;
            var ocur: ?ObjRef(ClassDef) = blk: {
                const ig = o_inst.borrow();
                defer ig.deinit();
                break :blk ig.get().class.clone();
            };
            var inner_step: usize = 0;
            while (ocur) |c| {
                if (inner_step > 128) {
                    c.deinit();
                    break;
                }
                inner_step += 1;
                const cg = c.borrow();
                const matched = std.mem.eql(u8, cg.get().name, qualifier) or std.mem.eql(u8, cg.get().fqn, qualifier);
                const next = blk: {
                    break :blk if (cg.get().parent) |p| p.clone() else null;
                };
                cg.deinit();
                c.deinit();
                if (matched) return .{ .ok = .{ .Instance = o_inst.clone() } };
                ocur = next;
            }
            walk = blk: {
                const ig = o_inst.borrow();
                defer ig.deinit();
                break :blk ig.get().outer;
            };
        }
    }
    // `this@MeasureScope` where the label names an INTERFACE a candidate
    // implements (an interface default method's labeled receiver, captured
    // by a nested anon): the parent-class name chains above never list
    // interfaces. A SECOND pass keeps the supertype-graph walk off the
    // name-match fast path (`this@DeepRecursiveScopeImpl` resolves by name
    // every `callRecursive`).
    for (chain) |encl_v| {
        if (encl_v != .Instance) continue;
        var walk: ?Value = encl_v;
        var outer_step: usize = 0;
        while (walk) |wv| {
            if (outer_step > 128) break;
            outer_step += 1;
            if (wv != .Instance) break;
            if (receiverImplementsType(self, &wv, qualifier)) {
                return .{ .ok = .{ .Instance = wv.Instance.clone() } };
            }
            walk = blk: {
                const ig = wv.Instance.borrow();
                defer ig.deinit();
                break :blk ig.get().outer;
            };
        }
    }
    const known_class = blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        break :blk g.get().contains(qualifier);
    };
    if (!known_class and receiver.* != .Null) {
        // `this@<fn-label>` — the qualifier is an extension/fn label.
        // When the receiver isn't a real bound Instance, prefer the
        // enclosing receiver if it differs from the lambda's own `this`.
        const receiver_is_bound_instance = receiver.* == .Instance;
        if (!receiver_is_bound_instance and chain.len > 0) {
            const encl = chain[0];
            const same = switch (encl) {
                .Instance => |a| switch (receiver.*) {
                    .Instance => |b| ObjRef(InstanceData).ptrEq(a, b),
                    else => false,
                },
                else => false,
            };
            if (!same and encl != .Null and encl != .Unit) {
                return .{ .ok = encl };
            }
        }
        return .{ .ok = receiver.* };
    }
    if (runtime.getenvSlice("KLIO_ERR_TRACE") != null) {
        std.debug.print("[labeled-this] qualifier={s} recv={s} chain_len={d}\n", .{ qualifier, @tagName(std.meta.activeTag(receiver.*)), chain.len });
        for (chain, 0..) |cv, i| {
            const cname: []const u8 = if (cv == .Instance) blk: {
                const g = cv.Instance.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                break :blk cg.get().name;
            } else @tagName(std.meta.activeTag(cv));
            std.debug.print("[labeled-this]   chain[{d}]={s}\n", .{ i, cname });
        }
        ir.eval.dumpFrameChainForDiagAlways();
    }
    return .{ .err = try typeErr(allocator, "`this@{s}` is not bound in this scope", .{qualifier}) };
}

const testing = std.testing;

test "unsigned prim-array kinds resolve to their ARRAY receiver name" {
    // builtinReceiverDisproven compares a declared unsigned-array receiver
    // against simpleName(view.typeFqn()); the kind's own simpleName is the
    // ELEMENT name and must never be used for that comparison.
    const kinds = [_]runtime.PrimitiveArrayKind{ .UInt, .ULong, .UShort, .UByte };
    const names = [_][]const u8{ "UIntArray", "ULongArray", "UShortArray", "UByteArray" };
    for (kinds, names) |k, n| {
        try std.testing.expectEqualStrings(n, simpleName(k.typeFqn()));
        try std.testing.expect(!std.mem.eql(u8, k.simpleName(), n));
    }
}

test "simpleName returns the trailing dotted segment" {
    try testing.expectEqualStrings("C", simpleName("a.b.C"));
    try testing.expectEqualStrings("C", simpleName("C"));
    try testing.expectEqualStrings("", simpleName("a."));
}

test "static receiver binding head removes Kotlin type suffixes" {
    try testing.expectEqualStrings("kotlin.String", staticReceiverBindingHead("kotlin.String?"));
    try testing.expectEqualStrings("List", staticReceiverBindingHead(" List<String>? "));
}

test "allUppercase recognizes type-parameter-style names" {
    try testing.expect(allUppercase("T"));
    try testing.expect(allUppercase("K2"));
    try testing.expect(!allUppercase("Foo"));
    try testing.expect(!allUppercase("ab"));
}

test "kotlinHashCode matches Kotlin for builtins" {
    try testing.expectEqual(@as(i32, 0), kotlinHashCode(&.Null));
    try testing.expectEqual(@as(i32, 1231), kotlinHashCode(&.{ .Bool = true }));
    try testing.expectEqual(@as(i32, 1237), kotlinHashCode(&.{ .Bool = false }));
    try testing.expectEqual(@as(i32, 65), kotlinHashCode(&.{ .Char = 'A' }));
    try testing.expectEqual(@as(i32, 42), kotlinHashCode(&.{ .Int = 42 }));
}

test "kotlinHashCode of a String uses the polynomial hash" {
    const s = try runtime.strInit(testing.allocator, "ABC");
    defer s.deinit();
    // 'A'*31^2 + 'B'*31 + 'C' = 65*961 + 66*31 + 67 = 64578.
    try testing.expectEqual(@as(i32, 64578), kotlinHashCode(&.{ .String = s }));
}

test "isSequenceTerminal classifies terminal vs pipeline ops" {
    try testing.expect(isSequenceTerminal("toList"));
    try testing.expect(isSequenceTerminal("count"));
    try testing.expect(!isSequenceTerminal("map"));
    try testing.expect(!isSequenceTerminal("filter"));
}

test "materialiseRangeItems builds inclusive progressions" {
    var asc = try materialiseRangeItems(testing.allocator, 1, 5, 2, .Int);
    defer asc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), asc.items.len);
    try testing.expectEqual(@as(i64, 1), asc.items[0].asI64().?);
    try testing.expectEqual(@as(i64, 5), asc.items[2].asI64().?);

    var desc = try materialiseRangeItems(testing.allocator, 3, 1, -1, .Int);
    defer desc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), desc.items.len);
    try testing.expectEqual(@as(i64, 3), desc.items[0].asI64().?);
    try testing.expectEqual(@as(i64, 1), desc.items[2].asI64().?);
}

test "compareValuesBuiltin orders scalars and strings" {
    try testing.expectEqual(Ordering.lt, compareValuesBuiltin(&.{ .Int = 1 }, &.{ .Int = 2 }).?);
    try testing.expectEqual(Ordering.gt, compareValuesBuiltin(&.{ .Double = 2.5 }, &.{ .Int = 2 }).?);
    try testing.expectEqual(
        Ordering.gt,
        compareValuesBuiltin(
            &.{ .ULong = std.math.maxInt(u64) },
            &.{ .ULong = 0 },
        ).?,
    );
    const a = try runtime.strInit(testing.allocator, "abc");
    defer a.deinit();
    const b = try runtime.strInit(testing.allocator, "abd");
    defer b.deinit();
    try testing.expectEqual(Ordering.lt, compareValuesBuiltin(&.{ .String = a }, &.{ .String = b }).?);
}

test "discarded member probes release their owned miss message" {
    const msg = try testing.allocator.dupe(u8, "Vm::call_member `f` on `T`");
    freeDispatchMiss(testing.allocator, .{ .err = .{ .Unimplemented = msg } });
    freeDispatchMiss(testing.allocator, .{ .err = .{ .Unimplemented = "nested: Vm::call_member is static" } });
}

test {
    testing.refAllDecls(@This());
}
