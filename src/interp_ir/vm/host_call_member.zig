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
const host_classes = @import("host_classes.zig");
const ClassTable = @import("../build.zig").ClassTable;
const host_globals = @import("host_globals.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;
const trace = @import("trace.zig");
const persistent_map_eq = @import("persistent_map_eq.zig");
const persistent_list_eq = @import("persistent_list_eq.zig");
const persistent_list_mut = @import("persistent_list_mut.zig");
const persistent_map_mut = @import("persistent_map_mut.zig");
const overload_match = @import("overload_match.zig");
const host_call_func = @import("host_call_func.zig");
const host_call_value = @import("host_call_value.zig");
const host_fields = @import("host_fields.zig");
const compose = @import("compose.zig");
const builtin_members = @import("builtin_members.zig");

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

// The builtin-receiver member surface, lifted to builtin_members.zig.
const Ordering = builtin_members.Ordering;
const arrayShapeOps = builtin_members.arrayShapeOps;
const builtinIterator = builtin_members.builtinIterator;
const captureModCount = builtin_members.captureModCount;
const collectionMutators = builtin_members.collectionMutators;
pub const collectionsEqualHostAware = builtin_members.collectionsEqualHostAware;
const comparatorMember = builtin_members.comparatorMember;
const compareValuesBuiltin = builtin_members.compareValuesBuiltin;
const componentMembers = builtin_members.componentMembers;
const dataClassAutoMembers = builtin_members.dataClassAutoMembers;
const dataValueInstanceEquals = builtin_members.dataValueInstanceEquals;
const annotationInstanceEquals = builtin_members.annotationInstanceEquals;
pub const deepValueEquals = builtin_members.deepValueEquals;
const drainIterableToList = builtin_members.drainIterableToList;
const hashWithDispatch = builtin_members.hashWithDispatch;
const isSequenceTerminal = builtin_members.isSequenceTerminal;
const iteratorMember = builtin_members.iteratorMember;
pub const kotlinHashCode = builtin_members.kotlinHashCode;
const mapContainsKeyEq = builtin_members.mapContainsKeyEq;
const materialiseRangeItems = builtin_members.materialiseRangeItems;
const materializeUserMap = builtin_members.materializeUserMap;
const rangeIterMember = builtin_members.rangeIterMember;
const seqIterMember = builtin_members.seqIterMember;
const sequenceMember = builtin_members.sequenceMember;
const sortedInstances = builtin_members.sortedInstances;
const valueStructuralHash = builtin_members.valueStructuralHash;

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

pub fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalError {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    return .{ .Type = msg };
}

pub fn throwExc(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!EvalError {
    return .{ .Throw = try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, fqn),
        .message = .from(if (message) |m| try runtime.strInit(allocator, m) else null),
        .cause = null,
    }) };
}

pub fn strVal(allocator: Allocator, s: []const u8) Allocator.Error!Value {
    return .{ .String = try runtime.strInit(allocator, s) };
}

pub fn boolVal(b: bool) Value {
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
pub fn classDisplayName(name: []const u8) []const u8 {
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
pub fn callMemberRec(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!EvalResult {
    return callMember(self, allocator, receiver, name, args);
}

/// Whether a closure's body is compose-pass threaded: its declared params
/// end with the synthetic `($composer, $changed)` pair. Such a closure
/// invoked without the pair completes it from the ambient composer inside
/// `callValue`, so arity checks must accept the pair-less shape too.
fn closurePairTailed(self: *VmHost, info: anytype) bool {
    const module: *const Module = info.module orelse self.module.asPtr();
    const func = module.funcById(info.body_func) orelse return false;
    return func.params.len >= 2 and
        std.mem.eql(u8, func.params[func.params.len - 1].name, "$changed") and
        std.mem.eql(u8, func.params[func.params.len - 2].name, "$composer");
}

pub fn callValueRec(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!EvalResult {
    // A receiver-typed callable invoked function-style with the receiver
    // as its first argument (`content.item(itemScope, localIndex)` where
    // `item: LazyItemScope.(Int) -> Unit`): one arg more than the
    // declared params plus a `this` capture slot is that shape — bind
    // args[0] as the receiver, not as the first parameter.
    if (callee.* == .IrClosure and args.len >= 1) {
        if (self.closures.get(@intCast(callee.IrClosure.id))) |info| {
            if (args.len == info.n_params + 1 or
                (args.len + 2 == info.n_params + 1 and closurePairTailed(self, info)))
            {
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

pub fn reconstructDataClass(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), args: []const Value) Allocator.Error!EvalResult {
    const class_def = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    var callee: Value = .{ .Class = class_def };
    defer callee.deinit(allocator);
    return host_call_value.callValue(self, allocator, &callee, args);
}

pub fn getFieldRec(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
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
    stdlib.implementations.string.clearRecvMemo();
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

pub fn makeIntrinsicHost(self: *VmHost) VmIntrinsicHost {
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

pub fn deinitIntrinsicHost(h: *VmIntrinsicHost) void {
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

pub fn mapRuntimeError(allocator: Allocator, e: RuntimeError) Allocator.Error!EvalError {
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
        .IrClosure, .Intrinsic, .BoundMethod => true,
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
    // it proves like an unbounded one — UNLESS a class of that exact name
    // is registered: `class I` + `fun I.offsetIn(...)` declares a receiver
    // on the CLASS, and reading it as a type param proved every receiver
    // (any subject satisfied any short-named extension). A class-level
    // generic colliding with a registered 1-2-letter class name loses this
    // trade; kotlinc resolves the same spelling to the class there too.
    if (pn.len > 0 and pn.len <= 2 and allUppercase(pn)) {
        const registered = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            break :blk cg.get().get(pn) != null;
        };
        if (!registered) return true;
    }
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
    // A receiver that IS the owner class's type parameter (`C.collectionSize`
    // inside `CollectionSerializer<E, C, B>`) accepts any static hint — the
    // hint may itself be another class's type parameter that happens to
    // spell a real class's name (upstream names one `Collection`).
    if (ir.parseClassTypeParamIdentity(std.mem.trimEnd(u8, ty.name, "?")) != null) return true;
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
    // The candidate scan below is O(classes) with per-entry hierarchy walks
    // and depends only on (module, sn, pn); memoize its verdict. The class
    // count folds into the key so a post-finalize class addition starts a
    // fresh entry instead of serving a stale verdict.
    const sra_key = blk: {
        var h = std.hash.Wyhash.init(0x53524143);
        const mp: usize = @intFromPtr(mod);
        h.update(std.mem.asBytes(&mp));
        const n: usize = mod.class_index.items.len;
        h.update(std.mem.asBytes(&n));
        h.update(sn);
        h.update(&[_]u8{0});
        h.update(pn);
        break :blk h.final();
    };
    if (sra_cache.get(sra_key)) |v| return switch (v) {
        0 => false,
        1 => true,
        else => null,
    };
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
    const verdict: u8 = if (relates) 1 else if (matches != 1) 2 else 0;
    sra_cache.put(std.heap.page_allocator, sra_key, verdict) catch {};
    if (relates) return true;
    if (matches != 1) return null;
    return false;
}

/// Memoized verdicts of `staticReceiverApplicable`'s candidate scan, keyed by
/// (module identity, class count, sn, pn). Thread-local: dispatch runs on
/// several threads and the scan verdict is cheap to fill per thread.
threadlocal var sra_cache: std.AutoHashMapUnmanaged(u64, u8) = .empty;

/// Drop this thread's memoized scan verdicts at a program-run boundary (an
/// in-process re-run may mint a new module at a reused address).
pub fn resetStaticApplicabilityCache() void {
    sra_cache.clearRetainingCapacity();
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
    return extArityApplicableTL(self, f, want, false);
}

/// `extArityApplicable` with Kotlin's trailing-lambda rule: when the call's
/// LAST argument is a callable and the candidate's LAST parameter is
/// function-typed, that argument binds the last parameter and only the GAP
/// parameters between them need defaults — `produce<Any> { … }` is
/// applicable to `produce(context = …, capacity = …, block)`.
fn extArityApplicableTL(self: *VmHost, f: *const Func, want: usize, last_arg_callable: bool) bool {
    if (f.params.len == want) return true;
    if (f.params.len < want) {
        return f.params.len > 0 and f.params[f.params.len - 1].is_vararg;
    }
    const defaults = funcDefaults(self, f);
    const trailing_bind = last_arg_callable and want > 0 and
        isFunctionTypeRef(&f.params[f.params.len - 1].ty);
    const gap_from: usize = if (trailing_bind) want - 1 else want;
    const gap_to: usize = if (trailing_bind) f.params.len - 1 else f.params.len;
    var k: usize = gap_from;
    while (k < gap_to) : (k += 1) {
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
        .IrClosure, .Intrinsic, .BoundMethod => {},
        else => return false,
    }
    const digits = pn["Function".len..];
    if (digits.len == 0) return true;
    const n = std.fmt.parseInt(usize, digits, 10) catch return true;
    // A parameterless lambda lowers with the synthetic implicit `it`
    // slot, so a stored arity of 1 also proves `Function0`.
    return switch (receiver.*) {
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

fn valueNominalFqn(v: *const Value) []const u8 {
    if (v.* != .Instance) return v.typeFqn();
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return cg.get().fqn;
}

/// Whether a lambda ARGUMENT's own declared parameter types disprove a
/// candidate's function-typed parameter. A literal that annotates its
/// parameters states them, and kotlinc drops a candidate that cannot accept
/// them: inside `buildString { … }` a bare
/// `forEachIndexed { index: Int, element: TestValueClass -> … }` must not
/// reach `CharSequence.forEachIndexed`, whose element is a `Char`. It did,
/// and iterating the builder while the body appended to it never terminated.
/// Refutes only on a DEFINITE mismatch: two different builtin scalars, or a
/// builtin scalar against a class this build declares.
fn closureParamsDisproveFnParam(self: *VmHost, pty: *const TypeRef, arg: *const Value) bool {
    if (arg.* != .IrClosure) return false;
    if (!std.mem.startsWith(u8, pty.name, "Function")) return false;
    const info = self.closures.get(@intCast(arg.IrClosure.id)) orelse return false;
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = if (info.module) |m| m else mg.get();
    const cf = module.funcById(info.body_func) orelse return false;
    const expected = fnTypeValueParams(pty) orelse return false;
    const skip: usize = if (cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this")) 1 else 0;
    if (cf.params.len <= skip) return false;
    const got = cf.params[skip..];
    const n = @min(got.len, expected.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const gh = fnParamHead(got[i].ty.name);
        const eh = fnParamHead(expected[i].name);
        if (gh.len == 0 or eh.len == 0) continue;
        if (std.mem.eql(u8, gh, eh)) continue;
        const g_scalar = scalarHeadOf(gh) != null;
        const e_scalar = scalarHeadOf(eh) != null;
        if (g_scalar and e_scalar) return true;
        if (e_scalar and knownClassHead(module, gh)) return true;
        if (g_scalar and knownClassHead(module, eh)) return true;
    }
    return false;
}

/// The declared VALUE parameter types of a lowered function type. Encoding:
/// `[#suspend?] [receiver?] params… ret [#markers]`.
fn fnTypeValueParams(ty: *const TypeRef) ?[]const TypeRef {
    const want = std.fmt.parseInt(usize, ty.name["Function".len..], 10) catch return null;
    var hi: usize = ty.args.len;
    while (hi > 0 and ty.args[hi - 1].name.len != 0 and ty.args[hi - 1].name[0] == '#') hi -= 1;
    if (hi == 0) return null;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, ty.args[lo].name, "#suspend")) lo += 1;
    hi -= 1;
    if (hi < lo) return null;
    var params = ty.args[lo..hi];
    if (params.len > want) params = params[params.len - want ..];
    return params;
}

fn fnParamHead(name: []const u8) []const u8 {
    var h = simpleName(std.mem.trimEnd(u8, name, "?"));
    if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
    return h;
}

fn scalarHeadOf(h: []const u8) ?[]const u8 {
    const scalars = [_][]const u8{
        "Int",  "Long",  "Short",  "Byte",   "Double",  "Float",
        "UInt", "ULong", "UShort", "UByte",  "Boolean", "Char",
        "String",
    };
    for (scalars) |sc| {
        if (std.mem.eql(u8, h, sc)) return sc;
    }
    return null;
}

/// Whether `h` names a class this build declares. A one-letter or
/// unresolvable head is a type parameter and proves nothing.
fn knownClassHead(module: *const Module, h: []const u8) bool {
    if (h.len <= 1) return false;
    if (std.mem.eql(u8, h, "Any")) return false;
    if (std.mem.startsWith(u8, h, "Function")) return false;
    return module.classId(h) != null;
}

fn candidateArgsDisproven(self: *VmHost, f: *const Func, args: []const Value) bool {
    if (f.params.len <= 1 or args.len == 0) return false;
    // A single TRAILING vararg adjudicates every remaining arg against its
    // ELEMENT type — the `appendAll(vararg Pair<String, String>)` overload
    // must decline a `Pair<String, List<String>>` argument so its
    // `Pair<String, Iterable<String>>` sibling binds. A NON-final vararg
    // repositions everything after it; decline as before.
    var vararg_trailing = false;
    for (f.params, 0..) |*pp, pi| {
        if (pp.is_vararg) {
            if (pi + 1 != f.params.len) return false;
            vararg_trailing = true;
        }
    }
    if (vararg_trailing) {
        const lead = f.params.len - 2; // params[0] is `this`
        for (args, 0..) |*a, ai| {
            const pty = if (ai < lead) &f.params[ai + 1].ty else &f.params[f.params.len - 1].ty;
            if (std.mem.startsWith(u8, pty.name, "Function") and instanceHierarchyHasInvoke(self, a)) continue;
            if (argDefinitelyNotParamType(self, pty, a)) {
                if (missTraceWant(f.name)) {
                    std.debug.print("[extfb]  vararg arg#{d} {s} rejects {s}\n", .{ ai, pty.name, valueNominalFqn(a) });
                }
                return true;
            }
        }
        return false;
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
        if (argDefinitelyNotParamType(self, pty, a)) {
            if (missTraceWant(f.name)) {
                std.debug.print("[extfb]  arg#{d} {s} rejects {s}\n", .{ i, pty.name, valueNominalFqn(a) });
            }
            return true;
        }
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
        // A bound that is itself one of the function's type parameters
        // (`fun <C, R> C.ifEmpty(...): R where C : Collection<*>, C : R`)
        // names no class: it constrains the inferred `R`, not the receiver,
        // and cannot be decided against a runtime value.
        if (typeParamOf(self, fid, bn)) continue;
        // Decide the bound for any receiver whose full type is known: an
        // Instance carries its class chain, and a concrete builtin's
        // `isRuntimeType` supertype set is authoritative (a `String` receiver
        // is provably not a `Number`, so `<T : Number> T.f()` does not apply to
        // it and the outer member wins). Only an erased function/lambda value
        // against a functional-interface bound stays undecided — SAM conversion
        // could satisfy it — so the strict prover owns those.
        const decidable = switch (receiver.*) {
            .Null, .IrClosure, .Intrinsic, .BoundMethod => false,
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
fn paramTypeIsTypeVar(self: *VmHost, f: *const Func, ty: *const TypeRef) bool {
    return fidTypeVar(self, f.id, ty);
}

/// `paramTypeIsTypeVar` keyed by `FuncId` (the shared applicability engine's
/// `type_var` callback shape).
fn fidTypeVar(self: *VmHost, fid: FuncId, ty: *const TypeRef) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (ty.args) |arg| {
        if (std.mem.startsWith(u8, arg.name, "#qual:")) return false;
    }
    const raw = std.mem.trimEnd(u8, ty.name, "?");
    if (ir.parseClassTypeParamIdentity(raw)) |identity| {
        const sig = mod.decl_sigs.get(fid.int()) orelse return false;
        if (sig.enclosing_class == null or
            sig.enclosing_class.?.int() != identity.owner.int() or
            identity.owner.int() >= mod.classes.items.len)
        {
            return false;
        }
        const owner = &mod.classes.items[identity.owner.int()];
        const bounds = mod.registry.class_type_param_bounds.get(owner.fqn) orelse
            return false;
        for (bounds) |bound| {
            if (std.mem.eql(u8, bound.param, identity.param)) return true;
        }
        return false;
    }
    return typeParamOf(self, fid, raw);
}

/// `ApplicabilityScope.type_var`: wraps `fidTypeVar`.
fn applicTypeVarCbM(ctx: *anyopaque, fid: FuncId, ty: *const TypeRef) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    return fidTypeVar(self, fid, ty);
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
fn headNamesRegisteredClass(self: *VmHost, head: []const u8) bool {
    const cg = self.classes.borrow();
    defer cg.deinit();
    return cg.get().get(head) != null;
}

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
                // Kotlin declares `Enum<E> : Comparable<E>`, so every enum
                // entry satisfies a `Comparable` bound without the supertype
                // appearing in its declaration. Without this,
                // `<T : Comparable<T>> T.coerceAtMost(...)` and its siblings
                // were skipped for an enum receiver and the call missed.
                const is_enum = cg.get().is_enum;
                cg.deinit();
                g.deinit();
                if (is_enum and (std.mem.eql(u8, pn, "Comparable") or std.mem.eql(u8, pn, "Enum"))) return true;
            }
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
                // A file-collision mangle (`X$f12`) satisfies its source
                // spelling `X`.
                if (std.mem.eql(u8, stripFileMangle(sn), pn)) return true;
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
            // The name walk sees only the ClassTable's simple-name entries;
            // a chain that crosses a host-synth class can break
            // where a name is registered differently. `instanceOf` is the
            // authoritative subtype answer — the same one `is` uses.
            return host_classes.instanceOf(self, receiver, .{ .name = pn, .nullable = false, .args = &.{} });
        },
        else => return receiver.isRuntimeType(pn),
    }
}

/// Does the receiver's actual runtime type satisfy `ty_name`?
pub fn receiverImplementsType(self: *VmHost, receiver: *const Value, ty_name: []const u8) bool {
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
    // A short all-caps head is a TYPE PARAMETER (`T`, `R`, `E1`), which any
    // receiver satisfies -- unless the program declares a class of that name,
    // in which case it is that user type and must be proven like any other.
    if (pn.len > 0 and pn.len <= 2 and allUppercase(pn)) {
        const declared = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().classId(pn) != null;
        };
        if (!declared) return true;
    }
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

fn receiverImplementsOwnerIdentity(
    self: *VmHost,
    receiver: *const Value,
    owner: []const u8,
) bool {
    if (std.mem.indexOfScalar(u8, owner, '.') == null) {
        return receiverImplementsType(self, receiver, owner);
    }
    if (receiver.* != .Instance) return false;
    var closure: std.ArrayList(*const ClassDef) = .empty;
    defer closure.deinit(self.allocator);
    var seen: std.ArrayList(*const ClassDef) = .empty;
    defer seen.deinit(self.allocator);
    {
        const instance = receiver.Instance.borrow();
        collectClassClosure(
            instance.get().class.asPtr(),
            &closure,
            &seen,
            self.allocator,
        );
        instance.deinit();
    }
    for (closure.items) |class| {
        if (std.mem.eql(u8, class.fqn, owner)) return true;
    }
    return false;
}

// -------------------------------------------------------------------------
// `hostHasMember`.
// -------------------------------------------------------------------------

/// One remembered `name slice -> canonical string` mapping. The canonical
/// string is program-lifetime, so `canon` stays valid; `src` is only a hint
/// and every hit is confirmed by comparing bytes, which keeps the entry sound
/// even if a transient string is freed and its address reused.
const NameIdSlot = struct { src: usize = 0, gen: u32 = 0, canon: []const u8 = &.{} };
threadlocal var name_id_cache: [8192]NameIdSlot = @splat(.{});

/// Canonical pointer identity for a dispatch-cache method name. Runtime
/// callable references carry collected String storage, so their raw byte
/// address must never enter a program-lifetime cache key.
///
/// Almost every caller passes a name slice straight out of the IR, whose
/// address is stable for the life of the program — so the mapping is
/// remembered per source address (multiplicatively mixed: arena-allocated
/// name storage repeats at fixed strides, which a modulo of the raw
/// address turned into constant slot ping-pong) and confirmed with a byte
/// compare, which takes the interning hash + shared-map probe off the
/// dispatch path. A miss probes the intern under the SHARED borrow first;
/// only a genuinely new spelling takes the exclusive insert path.
pub fn memberNameIdentity(self: *VmHost, name: []const u8) ?usize {
    const src = @intFromPtr(name.ptr);
    const slot = &name_id_cache[((src *% 0x9E3779B97F4A7C15) >> 32) % name_id_cache.len];
    if (slot.src == src and slot.gen == cacheGen() and slot.canon.len == name.len and std.mem.eql(u8, slot.canon, name)) {
        return @intFromPtr(slot.canon.ptr);
    }
    const id = blk: {
        {
            const pg = self.prog.borrow();
            defer pg.deinit();
            if (pg.get().memberNameIdentityExisting(name)) |id| break :blk id;
        }
        const pg = self.prog.borrowMut();
        defer pg.deinit();
        break :blk pg.get().memberNameIdentity(name) orelse return null;
    };
    slot.* = .{ .src = src, .gen = cacheGen(), .canon = @as([*]const u8, @ptrFromInt(id))[0..name.len] };
    return id;
}

pub fn hostHasMember(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    // A CLASS receiver's members live on its companion (or object
    // singleton): `X.serializer()` is a member call there, never a call of
    // some same-named local value.
    if (receiver.* == .Class) {
        const comp = (host_fields.companionOfClassValue(self, receiver) catch null) orelse return false;
        if (comp == .Null) return false;
        return hostHasMember(self, &comp, name);
    }
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
    const sig = methodArgSig(self, args) orelse return null;
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
    if (!ir.eval.dispatchCacheStable()) return;
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
    var cls_ident: usize = 0;
    {
        const g = inst.borrow();
        cls_ident = g.get().class.identity();
        const cg = g.get().class.borrow();
        cls_name = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    if (std.mem.indexOf(u8, cls_name, "$Companion$") != null) return null;
    // The ordered ancestor-companion list is a pure function of the class
    // (supertype graph + lexical enclosing chain + companion registry, all
    // static); the walk that produced it per call was the dominant cost of
    // every bare-name candidate build. Only the per-NAME membership check
    // below stays dynamic. Most classes cache the empty list and return in
    // two probes.
    const cached: ?[]const []const u8 = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().companion_chain_cache.get(cls_ident);
    };
    if (cached) |chain| return companionChainProbe(self, chain, name);
    var built = try companionChainBuild(self, allocator, cls_name);
    defer built.deinit(allocator);
    {
        const pg = self.prog.borrowMut();
        defer pg.deinit();
        const cache = &pg.get().companion_chain_cache;
        if (!cache.contains(cls_ident)) {
            if (pg.get().allocator.dupe([]const u8, built.items) catch null) |owned| {
                cache.put(cls_ident, owned) catch pg.get().allocator.free(owned);
            }
        }
    }
    return companionChainProbe(self, built.items, name);
}

/// Probe the ordered ancestor-companion list for a singleton owning `name`.
fn companionChainProbe(self: *VmHost, chain: []const []const u8, name: []const u8) Allocator.Error!?Value {
    for (chain) |cn| {
        const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
            .ok => |maybe| maybe,
            .err => return null,
        };
        if (singleton) |sv| {
            if (sv == .Instance) return sv;
        }
    }
    return null;
}

/// The BFS `companionWithMember` ran per call, producing the visit-ordered
/// companion-singleton names of the class's ancestors (supertype graph +
/// lexical enclosing classes).
fn companionChainBuild(self: *VmHost, allocator: Allocator, cls_name: []const u8) Allocator.Error!std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
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
        if (comp_name) |cn| try out.append(allocator, cn);
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
    return out;
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

/// Direct dispatch of a lowering-resolved member extension. Both Kotlin
/// receivers are explicit: `dispatch_receiver` is the declaring class/object
/// instance and `receiver` is the extension receiver.
fn invokeMemberExtFuncId(
    self: *VmHost,
    allocator: Allocator,
    dispatch_receiver: *const Value,
    receiver: *const Value,
    fid: FuncId,
    args: []const Value,
) Allocator.Error!EvalResult {
    const all = try prependReceiver(allocator, receiver, args);
    defer if (runtime.freeScratch()) allocator.free(all);
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    if (funcAt(mod, fid) == null) {
        return .{ .err = .{ .Type = "resolved member target is missing" } };
    }
    ir.eval.pushEnclosing(dispatch_receiver);
    defer ir.eval.popEnclosing();
    return try callFuncRec(self, allocator, mod, fid, all);
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
/// `lambda_arity` from an `IrClosure` only (never `Function`/`Class`), and
/// `is_lambda` from `isCallable` (the trailing-lambda gate), not the broader
/// `valueIsCallable`.
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
    const r = overload_match.crossPackageIdentityConflict(self, param_ty, v);
    if (r and runtime.envOnce("KLIO_APPLIC_TRACE") != null)
        std.debug.print("[applic-idconf] ty={s} arg={s}\n", .{ param_ty.name, v.typeFqn() });
    return r;
}

fn applicExactHeadCbM(ctx: *anyopaque, param_head: []const u8, arg_head: []const u8) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const key = mangledClassKeyOf(self, param_head) orelse return false;
    return std.mem.eql(u8, key, arg_head);
}

/// `ApplicabilityScope.subtype`: the member instance-subtype BFS
/// (`instanceSubtypeDistance`, simple-name matched — unlike the global BFS).
fn applicSubtypeCbM(ctx: *anyopaque, value: *const anyopaque, target: []const u8) ?i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const arg: *const Value = @ptrCast(@alignCast(value));
    if (arg.* != .Instance) return null;
    const dist = instanceSubtypeDistance(self, arg, target) orelse {
        if (runtime.envOnce("KLIO_APPLIC_TRACE") != null)
            blk2: {
                const g2 = arg.Instance.borrow();
                defer g2.deinit();
                const cg2 = g2.get().class.borrow();
                defer cg2.deinit();
                std.debug.print("[applic-subtype-miss] target={s} arg_cls={s}\n", .{ target, cg2.get().fqn });
                break :blk2;
            }
        return null;
    };
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
        const matches = if (std.mem.indexOfScalar(u8, owner, '.') != null)
            std.mem.eql(u8, co, owner)
        else
            std.mem.eql(u8, simpleName(co), owner);
        if (matches) {
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

fn runtimeMemberApplicability(
    self: *VmHost,
    allocator: Allocator,
    f: *const Func,
    args: []const Value,
    arg_names: ?[]const ?[]const u8,
    named: bool,
) Allocator.Error!?applicability.Score {
    // [6] not [24]: safety builds 0xAA-fill the whole declared array per
    // entry; >6 args fall to the heap branch below (rare).
    var shapes_buf: [6]applicability.ArgShape = undefined;
    const shapes = if (args.len <= shapes_buf.len)
        shapes_buf[0..args.len]
    else
        try allocator.alloc(applicability.ArgShape, args.len);
    defer if (args.len > shapes_buf.len) allocator.free(shapes);
    for (args, 0..) |*arg, i| {
        shapes[i] = shapeOfValueMember(self, arg);
        if (named) {
            shapes[i].named = if (arg_names) |names|
                if (i < names.len) names[i] else null
            else
                null;
        }
    }
    const sig = sigViewOfMember(self, f, false);
    const scope = applicability.ApplicabilityScope{
        .member = true,
        .named = named,
        .recv_external = named and f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this"),
        .ctx = @ptrCast(self),
        .refine = applicRefineCbM,
        .subtype = applicSubtypeCbM,
        .func_type = applicFuncTypeCbM,
        .identity_conflict = applicIdentityConflictCbM,
        .type_var = applicTypeVarCbM,
        .exact_head = applicExactHeadCbM,
        .erased_integer_widths = true,
    };
    return applicability.applicable(&sig, shapes, scope);
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
        // A pack-loaded ComposableLambdaImpl keeps its invoke overloads in
        // the lowered module, which this fn must NOT borrow (callers hold
        // exclusive module borrows — a consult deadlocks); the wrapper's
        // class identity answers directly.
        {
            const cg0 = g.get().class.borrow();
            defer cg0.deinit();
            if (std.mem.indexOf(u8, cg0.get().fqn, "ComposableLambda") != null) return true;
        }
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
/// The owner simple name of a companion-object type name (`kotlin.Char.Companion`
/// → `Char`), or null when the name does not head a companion.
fn companionOwnerName(name: []const u8) ?[]const u8 {
    const suffix = ".Companion";
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    const head = name[0 .. name.len - suffix.len];
    if (head.len == 0) return null;
    return simpleName(head);
}

/// A companion-object receiver type (`X.Companion`) is owner-specific: the
/// runtime companion instance's class fqn names its own owner, so a candidate
/// declared on a DIFFERENT owner's companion is inapplicable. Without this
/// every `T.Companion.f()` extension in scope survives the lenient pass and the
/// first-declared one wins (`String.serializer()` binding
/// `Char.Companion.serializer`).
fn companionOwnerMismatch(self: *VmHost, param_name: []const u8, receiver: *const Value) bool {
    const want = companionOwnerName(param_name) orelse return false;
    const g = receiver.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    if (companionOwnerName(cg.get().fqn)) |got| return !std.mem.eql(u8, want, got);
    // A NAMED companion (`companion object Named`) carries no `.Companion`
    // fqn segment; the registry maps the owner to its companion class.
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.companion_singletons.get(want)) |cn| {
        if (std.mem.eql(u8, cn, cg.get().name)) return false;
    }
    // The receiver is not `want`'s companion under either naming, so a
    // `want.Companion` receiver type cannot bind it.
    return true;
}

/// Whether the ClassDef `d` (or any supertype / resolved interface of it)
/// is named `want`, walking the instance's REAL class rather than a
/// name-keyed registry that collides across packs.
fn classDefIsA(d: *const ClassDef, want: []const u8) bool {
    return classDefIsAImpl(d, want, 0);
}

fn classDefIsAImpl(d: *const ClassDef, want: []const u8, depth: u32) bool {
    if (depth > 24) return false;
    if (std.mem.eql(u8, d.name, want) or std.mem.eql(u8, d.fqn, want) or
        std.mem.eql(u8, simpleName(d.fqn), want)) return true;
    for (d.supertype_names) |sn| {
        if (std.mem.eql(u8, sn, want) or std.mem.eql(u8, simpleName(sn), want)) return true;
    }
    for (d.interfaces) |iface| {
        const fg = iface.borrow();
        defer fg.deinit();
        if (classDefIsAImpl(fg.get(), want, depth + 1)) return true;
    }
    return false;
}

fn receiverDefinitelyNotParam(self: *VmHost, param_ty: *const TypeRef, receiver: *const Value) bool {
    if (receiver.* == .Instance and companionOwnerMismatch(self, param_ty.name, receiver)) return true;
    // `fun Unit.f()` applies to `Unit` alone. An interpreted instance is never
    // `Unit`, so such an extension must not survive as a lenient candidate for
    // it — `Unit.serializer()` otherwise answered `PlainObject.serializer()`.
    if (receiver.* == .Instance and !param_ty.nullable and
        std.mem.eql(u8, simpleName(param_ty.name), "Unit")) return true;
    if (argDefinitelyNotParamType(self, param_ty, receiver)) return true;
    // A function value implements only the Function* surface (plus
    // Any/type variables): a NOMINAL receiver type it does not satisfy
    // is definite. Without this a sole lenient extension survivor like
    // `Comparable<T>.compareTo` binds a lambda receiver, and its body's
    // member re-dispatch loops back to the same pick forever (two
    // lambdas compared through a pack's same-named member).
    // A `receiver::method` reference is a function value too, even though it
    // is carried as a synthetic Instance: `source::produce` satisfies
    // `(() -> T).asFlow()` and nothing else, so `Iterable<T>.asFlow()` must
    // not survive beside it.
    const callable_like = switch (receiver.*) {
        .IrClosure, .BoundMethod => true,
        .Instance => isBoundReference(receiver),
        else => false,
    };
    if (callable_like) {
        {
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
        }
    }
    if (receiver.* == .Class) {
        const pn = param_ty.name;
        if (param_ty.nullable) return false;
        // A companion-owner mismatch is definite through the class value too:
        // `Foo.f()` may bind `fun Foo.Companion.f()`, never another owner's.
        if (companionOwnerName(pn)) |want| {
            const g = receiver.Class.borrow();
            defer g.deinit();
            return !std.mem.eql(u8, want, g.get().name) and
                !std.mem.eql(u8, want, simpleName(g.get().fqn));
        }
        if (std.mem.eql(u8, pn, "Any")) return false;
        // A class value is never `Unit`. Without this every `fun Unit.f()`
        // extension in scope stays a lenient survivor for `X.f()`
        // (`Unit.serializer()` answered `Foo.serializer()`).
        if (std.mem.eql(u8, pn, "Unit")) return true;
        if (std.mem.startsWith(u8, pn, "Function")) return true;
        if (pn.len <= 2 and allUppercase(pn)) return false;
        // A class value IS a `KClass` / `KClassifier`. The reflection heads it
        // reports must not be disproven merely because the stdlib registers a
        // ClassDef under that name — that dropped every `KClass<T>.f()`
        // extension (`isInterface`, `serializerOrNull`) from the candidate set.
        if (receiver.isRuntimeType(simpleName(pn))) return false;
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

/// The source-level name behind a file-collision mangle (`X$f12` -> `X`).
/// Nested-lift names (`Outer$Name`) keep their shape: the stripped suffix
/// must be `$f` followed by digits only.
fn stripFileMangle(n: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, n, '$') orelse return n;
    if (i + 2 >= n.len or n[i + 1] != 'f') return n;
    for (n[i + 2 ..]) |c| {
        if (c < '0' or c > '9') return n;
    }
    return n[0..i];
}

/// Whether the class table registers any file-mangled variant of `name`
/// (`name$f<digits>`). A private/internal classifier whose simple name
/// collides across files registers ONLY under its mangled name, so a
/// declared type spelled with the source name still names a known class.
fn anyFileMangledVariant(classes: *const ClassTable, name: []const u8) bool {
    var it = classes.keyIterator();
    while (it.next()) |k| {
        const kn = k.*;
        if (kn.len > name.len + 2 and std.mem.startsWith(u8, kn, name) and
            kn[name.len] == '$' and stripFileMangle(kn).len == name.len) return true;
    }
    return false;
}

/// Memo key for `argDefinitelyNotParamType`: the adjudication is a pure
/// function of (param type, arg's runtime TYPE) for scalars, callables,
/// Null, and Instances (whose arm reads only the class and its static
/// hierarchy). Container/tuple/range args adjudicate their CONTENTS, so
/// they stay unmemoized (null key).
fn admArgKey(arg: *const Value) ?usize {
    return switch (arg.*) {
        .Instance => |i| @intFromPtr(i.asPtrConst().class.asPtrConst()),
        .List, .Set, .Map, .Array, .Sequence, .Range, .Pair, .Triple, .MapEntry => null,
        else => (@as(usize, @intFromEnum(std.meta.activeTag(arg.*))) << 1) | 1,
    };
}

const TlAdmEntry = struct { ty: usize = 0, akey: usize = 0, gen: u32 = 0, verdict: u8 = 0 };
threadlocal var tl_adm_cache: [4096]TlAdmEntry = @splat(.{});

/// Per-call front for the type-disproof adjudicator: overload resolution
/// consults it per (candidate param, arg) on every dispatch that walks
/// candidates, and the uncached ladder pays alias/class-registry string
/// probes plus a heap-allocating supertype BFS each time — measured as the
/// dominant string-eql source on recompose-heavy workloads.
pub fn argDefinitelyNotParamType(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) bool {
    const akey = admArgKey(arg) orelse return argDefinitelyNotParamTypeUncached(self, param_ty, arg);
    const ty = @intFromPtr(param_ty);
    const h = (@as(u64, @intCast(ty)) *% 0x9E3779B97F4A7C15) ^ @as(u64, @intCast(akey));
    const e = &tl_adm_cache[@as(usize, @intCast((h ^ (h >> 17)) & (tl_adm_cache.len - 1)))];
    const gen = cacheGen();
    if (e.verdict != 0 and e.ty == ty and e.akey == akey and e.gen == gen) return e.verdict == 2;
    const v = argDefinitelyNotParamTypeUncached(self, param_ty, arg);
    e.* = .{ .ty = ty, .akey = akey, .gen = gen, .verdict = if (v) 2 else 1 };
    return v;
}

fn argDefinitelyNotParamTypeUncached(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) bool {
    var pn = param_ty.name;
    // A QUALIFIED function-type head (`kotlin.Function1`) must reach the
    // Function arm below, not the qualified-name early-out: the callable
    // disproof is head-shaped and package-independent.
    if (std.mem.indexOfScalar(u8, pn, '.') != null and
        std.mem.startsWith(u8, simpleName(pn), "Function"))
    {
        pn = simpleName(pn);
    }
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
    // (kotlinc resolves the extension; the member is inapplicable). The same
    // holds for any REGISTERED class that is not a `fun interface`: no SAM
    // conversion exists, so a lambda never satisfies `FlowCollector` — the
    // member `collect(FlowCollector)` stands aside for the extension
    // `collect(action)` exactly as kotlinc binds it. A head naming no
    // registered class (a typealias of a function type) stays non-definite.
    if (isCallable(arg)) {
        if (runtime.envOnce("KLIO_ADM_TRACE") != null) {
            const cg2 = self.classes.borrow();
            defer cg2.deinit();
            std.debug.print("[adm] callable-vs pn={s} orig={s} reg={}\n", .{ pn, orig, cg2.get().get(pn) != null });
        }
        if (isDefinitelyNonFunctionTypeName(pn)) return true;
        if (!std.mem.startsWith(u8, pn, "Function") and
            !std.mem.eql(u8, pn, "Any") and !std.mem.eql(u8, pn, "Unit"))
        {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(pn) orelse cg.get().get(orig)) |d| {
                const dg = d.borrow();
                defer dg.deinit();
                if (!dg.get().is_fun_interface) return true;
            }
        }
    }
    if (std.mem.startsWith(u8, pn, "Function")) {
        // Callables and Null stay non-definite; a value kind that PLAINLY
        // carries no invoke surface is definite — a `List` is not a
        // predicate, so `removeAll(listOf(2, 4))` must fall past a
        // subclass's lone `removeAll(predicate)` to the inherited
        // `removeAll(Collection)` (SmallPersistentVector under
        // SnapshotStateList was the live case). Kinds that CAN be invoked
        // without being tagged callable — a `Class` constructor reference
        // fed to a factory param, a bound member — stay non-definite
        // (`FixupList.createAndInsertNode`'s factory broke on the broad
        // form of this arm).
        return switch (arg.*) {
            .String, .Bool, .Char, .Byte, .Short, .Int, .Long, .Float, .Double, .UByte, .UShort, .UInt, .ULong => true,
            .List, .Map, .Set, .Array, .Range, .Sequence, .Pair, .Triple, .MapEntry => true,
            .Instance => !instanceHasInvokeSurface(self, arg),
            else => false,
        };
    }
    // A Pair/Triple argument adjudicates its components against the declared
    // generic arguments: `appendAll(vararg values: Pair<String, String>)`
    // must decline a `Pair<String, List<String>>` so the sibling
    // `Pair<String, Iterable<String>>` overload binds, exactly as kotlinc
    // picks.
    if (arg.* == .Pair and std.mem.eql(u8, pn, "Pair") and param_ty.args.len == 2) {
        if (argDefinitelyNotParamType(self, &param_ty.args[0], arg.Pair.first.asPtr())) return true;
        if (argDefinitelyNotParamType(self, &param_ty.args[1], arg.Pair.second.asPtr())) return true;
        return false;
    }
    if (arg.* == .Triple and std.mem.eql(u8, pn, "Triple") and param_ty.args.len == 3) {
        if (argDefinitelyNotParamType(self, &param_ty.args[0], arg.Triple.first.asPtr())) return true;
        if (argDefinitelyNotParamType(self, &param_ty.args[1], arg.Triple.second.asPtr())) return true;
        if (argDefinitelyNotParamType(self, &param_ty.args[2], arg.Triple.third.asPtr())) return true;
        return false;
    }
    // A List argument adjudicates its RANGE content against a concrete
    // declared element range type: Kotlin generics are invariant, so a
    // List of LongRanges never binds `List<IntRange>` — RangesTest's
    // private `assertEquals(List<IntRange>, List<LongRange>)` delegates
    // to kotlin.test's on its mapped args instead of recursing into
    // itself. Progressions and non-range elements stay non-definite.
    if (arg.* == .List and param_ty.args.len == 1 and
        (std.mem.eql(u8, pn, "List") or std.mem.eql(u8, pn, "MutableList") or
            std.mem.eql(u8, pn, "Collection") or std.mem.eql(u8, pn, "Iterable")))
    {
        const want: ?runtime.RangeKind = blk: {
            const en = std.mem.trimEnd(u8, param_ty.args[0].name, "?");
            if (std.mem.eql(u8, en, "IntRange")) break :blk .Int;
            if (std.mem.eql(u8, en, "LongRange")) break :blk .Long;
            if (std.mem.eql(u8, en, "CharRange")) break :blk .Char;
            break :blk null;
        };
        if (want) |wk| {
            const g = arg.List.items.borrow();
            defer g.deinit();
            for (g.get().items) |*e| {
                if (e.* != .Range) break;
                if (e.Range.progression) continue;
                if (e.Range.kind != wk) return true;
            }
        }
    }
    // A container/tuple value never satisfies a scalar or String parameter
    // head (an `Array` head stays out: vararg packing hands pre-packed
    // arrays through here).
    if (overload_match.builtinParamKind(pn)) |pk| {
        if (pk != .array) switch (arg.*) {
            .List, .Map, .Set, .Sequence, .Pair, .Triple, .MapEntry => return true,
            else => {},
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
            // An Array satisfies no non-array container head (an
            // `Array<Pair>` is never a `Map`, so `putAll(pairs)` inside the
            // stdlib `plusAssign` drops the builder's member `putAll(Map)`
            // and the `Array<out Pair>` extension binds). The array-modeled
            // interfaces (`Iterable`/`Collection`/...) and array-named
            // params stay non-definite, same as the nominal arm below.
            .Array => return std.mem.indexOf(u8, pn, "Array") == null and !isArrayRelatedIface(pn),
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
        if (cg.get().get(pn) == null and cg.get().get(orig) == null and
            !anyFileMangledVariant(cg.get(), pn)) return false;
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
    var start_fqn: []const u8 = "";
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        start = cg.get().name;
        start_fqn = cg.get().fqn;
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
    // Positive proof from the instance's OWN ClassDef, which carries the
    // real supertype names and resolved interface handles. This is immune
    // to the simple-name registry collision that defeats the name-keyed
    // `class_super_names` lookup below (a receiver kotlinx.io.Buffer vs an
    // unrelated okio Buffer both key "Buffer"): a Buffer really IS a Sink.
    {
        const g = inst.borrow();
        const cd = g.get().class.clone();
        g.deinit();
        defer cd.deinit();
        const dg = cd.borrow();
        const isa = classDefIsA(dg.get(), pn) or classDefIsA(dg.get(), orig);
        dg.deinit();
        if (isa) return false;
    }
    // The lowering-recorded transitive chain includes interface links the
    // runtime classes map never registers (interfaces are not instantiated),
    // so it decides cases the BFS below would silently truncate: a companion
    // implementing Plugin through the BaseApplicationPlugin interface IS-A
    // Plugin.
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        // Prefer the fqn-keyed chain: a simple name that collides across
        // packs (a receiver kotlinx.io.Buffer vs an unrelated okio Buffer)
        // would otherwise read the wrong class's supers and miss Sink.
        const chain_by_fqn = if (start_fqn.len != 0) mg.get().registry.class_super_names.get(start_fqn) else null;
        if (chain_by_fqn orelse mg.get().registry.class_super_names.get(start)) |chain|
        {
            const tailMatch = struct {
                fn m(cur: []const u8, want: []const u8) bool {
                    if (std.mem.eql(u8, cur, want)) return true;
                    if (std.mem.eql(u8, stripFileMangle(cur), want)) return true;
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
        // arg IS-A param type (under either reading of an aliased name). A
        // chain entry may carry a file-collision mangle (`X$f12`) the
        // declared type's source spelling does not — compare its source
        // name too.
        if (std.mem.eql(u8, cur, pn) or std.mem.eql(u8, cur, orig)) return false;
        const cur_src = stripFileMangle(cur);
        if (cur_src.ptr != cur.ptr and
            (std.mem.eql(u8, cur_src, pn) or std.mem.eql(u8, cur_src, orig))) return false;
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
    if (runtime.envOnce("KLIO_ADM_TRACE") != null) {
        std.debug.print("[adm] definite-mismatch pn={s} orig={s} start={s} walked={d}\n", .{ pn, orig, start, queue.items.len });
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

/// Whether the call's ARG COUNT leaves exactly one of the collected
/// same-name candidates able to bind: every other candidate has a plain
/// (no-vararg) parameter list whose arity can never accept `n_args`. The
/// arg count is folded into every method-cache key, so a pick forced this
/// way is a pure function of the RELAXED key too — the single-candidate
/// cacheability gate widens to it (`addAll(Collection)` beside
/// `addAll(index, Collection)` re-walked on every call because the
/// name-level candidate count read as ambiguous). A candidate with
/// defaults or a vararg counts as viable at any arity (conservative), and
/// a pass-threaded composable pair bails outright — its effective arity
/// consults the ambient composer, which no key folds.
fn pickArityForced(self: *VmHost, candidates: []const Func, n_args: usize) bool {
    var viable: usize = 0;
    for (candidates) |*f| {
        const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const effective = f.params[skip..];
        if (effective.len >= 2 and
            std.mem.eql(u8, effective[effective.len - 1].name, "$changed") and
            std.mem.eql(u8, effective[effective.len - 2].name, "$composer")) return false;
        var has_vararg = false;
        for (effective) |*p| {
            if (p.is_vararg) has_vararg = true;
        }
        const viable_c = has_vararg or effective.len == n_args or
            (effective.len > n_args and funcDefaults(self, f) != null);
        if (viable_c) {
            viable += 1;
            if (viable > 1) return false;
        }
    }
    return viable == 1;
}

/// Whether every argument's shape is fully discriminated by the RELAXED
/// signature fold at the level the applicability tests consult: value
/// tags, Instance class identities, closure bodies, primitive array
/// kinds, and container KINDS (the tests are nominal/kind-level — they
/// never inspect elements). Object arrays and every other value shape
/// stay out: the fold cannot tell them apart as finely as a test might.
fn argsRelaxedAdjudicable(args: []const Value) bool {
    for (args) |*a| {
        switch (a.*) {
            .Int, .Long, .Double, .Float, .Short, .Byte, .Char, .Bool, .UInt, .ULong, .UShort, .UByte, .Instance, .String, .Unit, .IrClosure, .Null, .Result, .List, .Set, .Map => {},
            .Array => |arr| {
                if (arr.prim == null) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn pickMethodOverload(self: *VmHost, mod_opt: ?*const Module, candidates: []const Func, args_in: []const Value) ?Func {
    if (candidates.len == 0) return null;
    const args = args_in;
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
        var effective = f.params[skip..];
        var eff_args = args_in;
        // A pass-threaded composable MEMBER carries a trailing ($composer,
        // $changed) pair the call site appended positionally
        // (`consumer.Varargs(0, 1, 2, 3, $composer, $changed)` with
        // `Varargs(vararg ints, $composer, $changed)`): judge the USER shape
        // pair-trimmed — the mid-vararg check otherwise refuses on the
        // undefaulted pair params. Only when the tail VALUES look like the
        // pair (a Composer instance + the changed Int).
        if (effective.len >= 2 and
            std.mem.eql(u8, effective[effective.len - 1].name, "$changed") and
            std.mem.eql(u8, effective[effective.len - 2].name, "$composer"))
        {
            if (eff_args.len >= 2 and eff_args[eff_args.len - 1] == .Int and
                eff_args[eff_args.len - 2] == .Instance)
            {
                effective = effective[0 .. effective.len - 2];
                eff_args = eff_args[0 .. eff_args.len - 2];
            } else if (compose.currentComposer() != null) {
                // Pairless call in composition: the dispatch completes the
                // pair from the ambient composer; judge the user shape.
                effective = effective[0 .. effective.len - 2];
            }
        }
        // Non-final vararg (a vararg before trailing defaulted / named-only
        // params): the prefix binds positionally, the vararg consumes the
        // remaining positional eff_args, and the post-vararg params take their
        // defaults. The naive eff_args[i]-vs-effective[i] pairing below would
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
            if (eff_args.len < vp) {
                var k: usize = eff_args.len;
                while (k < vp) : (k += 1) {
                    if (!paramHasDefault(defaults, skip + k)) return null;
                }
            }
            // Post-vararg params can't be reached positionally → must default.
            var k: usize = vp + 1;
            while (k < effective.len) : (k += 1) {
                if (!paramHasDefault(defaults, skip + k)) return null;
            }
            // Prefix eff_args against prefix params; the rest against the vararg
            // element type. A param typed as an in-scope type variable is
            // never adjudicated nominally.
            var i: usize = 0;
            while (i < eff_args.len and i < vp) : (i += 1) {
                if (argDefinitelyNotParamType(self, &effective[i].ty, &eff_args[i]) and
                    !paramTypeIsTypeVar(self, &f, &effective[i].ty)) return null;
            }
            var j: usize = vp;
            while (j < eff_args.len) : (j += 1) {
                if (argDefinitelyNotParamType(self, &effective[vp].ty, &eff_args[j]) and
                    !paramTypeIsTypeVar(self, &f, &effective[vp].ty)) return null;
            }
            return f;
        }
        // Over-supply with no vararg tail can't bind: decline so an
        // applicable top-level/extension overload wins — e.g. the stdlib
        // `buildString { … }` inside an extension on a class that declares
        // its own zero-arg `buildString()` member (`URLBuilder.authority`).
        if (eff_args.len > effective.len and
            (effective.len == 0 or !effective[effective.len - 1].is_vararg))
        {
            if (missTraceWant(f.name)) std.debug.print("[pmo] `{s}` decline=oversupply eff_args={d} params={d}\n", .{ f.name, eff_args.len, effective.len });
            return null;
        }
        if (eff_args.len < effective.len) {
            const defaults = funcDefaults(self, &f);
            // Trailing-lambda rule: a final callable arg binds the LAST
            // parameter when that parameter is function-typed; only the GAP
            // parameters between it and the lead positional eff_args need
            // defaults. `observe(readObserver) { block }` on
            // `(readObserver = null, writeObserver = null, block)` is
            // applicable -- block is filled by the lambda, writeObserver by
            // its default.
            const trailing_bind = eff_args.len > 0 and
                isFunctionTypeRef(&effective[effective.len - 1].ty) and
                isCallable(&eff_args[eff_args.len - 1]);
            const first_unfilled = if (trailing_bind) eff_args.len - 1 else eff_args.len;
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
        // class's) is never adjudicated nominally. Under the trailing-lambda
        // rule (undersupplied call whose final callable arg binds the LAST
        // function-typed param), the final arg adjudicates against that last
        // param, not the positional slot the defaulted gap left behind —
        // `build { … }` on `build(flag: Boolean = false, builder: () -> T)`
        // must judge the lambda against `builder`, not `flag`.
        const tail_lambda_bind = eff_args.len > 0 and eff_args.len < effective.len and
            isFunctionTypeRef(&effective[effective.len - 1].ty) and
            isCallable(&eff_args[eff_args.len - 1]);
        var i: usize = 0;
        while (i < eff_args.len and i < effective.len) : (i += 1) {
            const pi = if (tail_lambda_bind and i == eff_args.len - 1) effective.len - 1 else i;
            // A LONE member whose function-typed parameter meets an Instance
            // argument whose class chain declares `invoke` stays applicable:
            // a memo-wrapped ComposableLambdaImpl keeps its invoke overloads
            // in the pack registry, which the borrow-free disproof cannot
            // see, so `setContent(content)` was dropped on its only
            // candidate. Answered from the caller's live module borrow; an
            // invoke-less instance (a JobNode against a CompletionHandler
            // parameter) still declines so the extension wins.
            if (eff_args[i] == .Instance and std.mem.startsWith(u8, effective[pi].ty.name, "Function")) {
                if (mod_opt) |m| {
                    if (classChainHasInvokeIn(m, &eff_args[i])) continue;
                }
            }
            if (argDefinitelyNotParamType(self, &effective[pi].ty, &eff_args[i]) and
                !paramTypeIsTypeVar(self, &f, &effective[pi].ty))
            {
                if (missTraceWant(f.name)) std.debug.print("[pmo] `{s}` decline=arg-type param#{d} ty={s} arg={s}\n", .{ f.name, pi, effective[pi].ty.name, @tagName(std.meta.activeTag(eff_args[i])) });
                return null;
            }
        }
        return f;
    }
    // [6] not [24]: safety builds 0xAA-fill the whole declared array per
    // entry; >6 args fall to the heap branch below (rare).
    var shapes_buf: [6]applicability.ArgShape = undefined;
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
    if (candidates.len > 0 and missTraceWant(candidates[0].name)) {
        for (shapes, 0..) |sh, i| {
            var cn: []const u8 = "-";
            if (args[i] == .IrClosure) {
                if (self.closures.get(@intCast(args[i].IrClosure.id))) |info| {
                    { const mg2 = self.module.borrow(); defer mg2.deinit(); if (funcAt(mg2.get(), info.body_func)) |cf| cn = cf.fqn; }
                }
            }
            std.debug.print("[pmo-shape] #{d} tag={s} rc={s} lambda={} arity={?d} functyped={} fqn={s} closure={s}\n", .{ i, @tagName(std.meta.activeTag(args[i])), sh.runtime_class orelse "-", sh.is_lambda, sh.lambda_arity, sh.func_typed, args[i].typeFqn(), cn });
        }
    }
    const scope = applicability.ApplicabilityScope{
        .member = true,
        .ctx = @ptrCast(self),
        .refine = applicRefineCbM,
        .subtype = applicSubtypeCbM,
        .func_type = applicFuncTypeCbM,
        .identity_conflict = applicIdentityConflictCbM,
        .type_var = applicTypeVarCbM,
        .exact_head = applicExactHeadCbM,
        .erased_integer_widths = true,
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
        const applic = applicability.applicable(&sig, shapes, scope) orelse {
            if (missTraceWant(f.name)) {
                std.debug.print("[pmo-multi] `{s}`#{d} inapplicable params:", .{ f.name, f.id.int() });
                for (f.params) |p| std.debug.print(" {s}:{s}", .{ p.name, p.ty.name });
                std.debug.print("\n", .{});
            }
            continue;
        };
        // The `+5` exact-arity bonus and `-1000` low-priority penalty are the
        // member caller's tiebreaks, applied from the returned `Score`.
        const score = appliedMemberScore(applic.points, applic.exact_arity, applic.low_priority);
        if (missTraceWant(f.name)) {
            std.debug.print("[pmo-multi] `{s}`#{d} score={d} params:", .{ f.name, f.id.int(), score });
            for (f.params) |p| std.debug.print(" {s}:{s}", .{ p.name, p.ty.name });
            std.debug.print("\n", .{});
        }
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

// -------------------------------------------------------------------------
// Small construction helpers.
// -------------------------------------------------------------------------

pub fn listOf(allocator: Allocator, items: std.ArrayList(Value), mutable: bool) Allocator.Error!Value {
    return try Value.newList(allocator, .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
    });
}

pub fn cloneItemsList(allocator: Allocator, src: runtime.ValueList) Allocator.Error!std.ArrayList(Value) {
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

fn instanceInvokeWantsPair(self: *VmHost, receiver: *const Value, nargs: usize) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const recv_fqn = blk: {
        const ig = receiver.Instance.borrow();
        defer ig.deinit();
        const cg = ig.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    const cid = mod.classIdByFqn(recv_fqn) orelse return false;
    const irc = &mod.classes.items[cid.int()];
    var paired = false;
    for (irc.methods) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        if (!std.mem.eql(u8, f.name, "invoke")) continue;
        const has_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        const n = f.params.len - @intFromBool(has_this);
        // The wrapper's overloads are real source (`invoke(p1, c: Composer,
        // changed: Int)`), so the pair is recognized by shape: a
        // Composer-typed slot followed by the changed flags. Reaching this
        // helper at all means the plain dispatch missed, so a same-arity
        // sibling needs no exclusion — nothing bound.
        if (n == nargs + 2 and
            std.mem.endsWith(u8, f.params[f.params.len - 2].ty.name, "Composer") and
            std.mem.eql(u8, f.params[f.params.len - 1].ty.name, "Int")) paired = true;
    }
    return paired;
}

/// The `provideDelegate` convention at a delegated property's creation:
/// the delegate expression's value receives `provideDelegate(thisRef, ::p)`
/// when a member or extension operator applies; a dispatch miss keeps the
/// value, any other failure is the property's initialization failure.
pub fn provideDelegateFor(self: *VmHost, allocator: Allocator, this_ref: Value, prop_ref: Value, v: Value) Allocator.Error!EvalResult {
    // A property reference delegate (`by contents::zone`) forwards every
    // member call to its target, so it is never offered the convention.
    switch (v) {
        .PropertyRef => return .{ .ok = v },
        .Instance => |inst| {
            const forwards = blk: {
                const g = inst.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                break :blk std.mem.startsWith(u8, cg.get().name, "$bound_ref$");
            };
            if (forwards) return .{ .ok = v };
        },
        else => {},
    }
    const r = try callMemberInner(self, allocator, &v, "provideDelegate", &.{ this_ref, prop_ref }, false);
    switch (r) {
        .ok => return r,
        .err => |e| {
            // Only the dispatch miss for `provideDelegate` itself means the
            // convention does not apply; a miss raised inside an operator
            // that ran is the property's initialization failure.
            if (e == .Unimplemented and std.mem.indexOf(u8, e.Unimplemented, "`provideDelegate`") != null) return .{ .ok = v };
            return r;
        },
    }
}

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
        (receiver.* == .IrClosure))
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
        if (samTraceOn()) std.debug.print("[sam-direct] name={s} nargs={d}\n", .{ name, args.len });
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
    // Compose ABI completion at the callable-instance surface: a composable
    // lambda wrapper invoked as a plain value (`receiver.content()`) arrives
    // WITHOUT the pass-appended ($composer, $changed) pair — the pass leaves
    // unclassified value invocations unthreaded and relies on the runtime to
    // complete the pair. The closure route completes it already; this is the
    // same completion for a wrapper CLASS whose only matching `invoke`
    // overload carries the trailing pair.
    if (r == .err and r.err == .Unimplemented and receiver.* == .Instance and
        std.mem.eql(u8, name, "invoke"))
    {
        if (missTraceWant(name)) std.debug.print("[inv-pair] reach recv={s} nargs={d} composer={} wants={}\n", .{ receiver.typeFqn(), args.len, compose.currentComposer() != null, instanceInvokeWantsPair(self, receiver, args.len) });
        if (compose.currentComposer()) |c| {
            if (instanceInvokeWantsPair(self, receiver, args.len)) {
                freeDispatchMiss(allocator, r);
                var ext: std.ArrayList(Value) = .empty;
                defer ext.deinit(allocator);
                try ext.ensureTotalCapacityPrecise(allocator, args.len + 2);
                ext.appendSliceAssumeCapacity(args);
                ext.appendAssumeCapacity(c);
                ext.appendAssumeCapacity(.{ .Int = 0 });
                return callMemberInner(self, allocator, receiver, name, ext.items, false);
            }
        }
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

/// The classifier head of a source-spelled supertype name: generic args
/// and nullability stripped (`Flow<T>` -> `Flow`).
fn supertypeHead(raw: []const u8) []const u8 {
    var h = raw;
    if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
    return std.mem.trimEnd(u8, std.mem.trim(u8, h, " "), "?");
}

pub fn valueCouldServeName(self: *VmHost, allocator: Allocator, v: *const Value, name: []const u8, argc: usize) bool {
    if (v.* != .Instance) {
        // A builtin-backed value (a List, String, Array, Sequence...) serves
        // a name through the stdlib ladder or a source extension on its
        // nominal type. Answering false for these let the SAM-candidate arm
        // swallow a bare call that belongs to a DEEPER receiver: inside
        // `asFlow`'s block the collector closure took `forEach`, ran the
        // user's collect action with the forEach action as its element, and
        // the list never iterated.
        if (v.* == .Null or v.* == .Unit) return false;
        if (receiverHasMemberNamed(self, v, name)) return true;
        const nominal = simpleName(valueNominalFqn(v));
        const mg = self.module.borrow();
        defer mg.deinit();
        return @constCast(mg.get()).extCouldApply(allocator, nominal, name, argc);
    }
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
        // An anonymous object's class name says nothing; its SUPERTYPES
        // carry the declared members (an `object : Flow<T>` serves
        // `collect` through the interface). Walk the chain so the
        // SAM-candidate arm declines in favor of the real receiver.
        for (cg.get().supertype_names) |sup| {
            const head = supertypeHead(sup);
            if (m.registry.hierarchy_methods.get(head)) |methods| {
                if (methods.contains(name)) return true;
            }
        }
        // extCouldApply rebuilds its lazy index when the func table has
        // grown; VM execution is single-threaded, so the cast is sound.
        if (@constCast(m).extCouldApply(allocator, cls_name, name, argc)) return true;
        for (cg.get().supertype_names) |sup| {
            if (@constCast(m).extCouldApply(allocator, supertypeHead(sup), name, argc)) return true;
        }
    }
    // A runtime-lowered anon object registers its methods in the per-site
    // table, not the class def.
    {
        var mbuf: [96]u8 = undefined;
        if (std.fmt.bufPrint(&mbuf, "{s}/{d}", .{ name, argc })) |mkey| {
            if (lookupAnonMethod(self, allocator, cls_name, mkey, name) != null) return true;
        } else |_| {}
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
/// Per-thread gate for `recvFnPropHeadOf`: most modules declare ZERO
/// receiver-function-typed properties, and the registry is fully populated
/// before any dispatch runs, so one count check per (thread, module) skips
/// the per-call supertype walk entirely. When props DO exist, two bit
/// masks over the declared prop names' (length, first byte) signatures
/// filter the overwhelming majority of member names without hashing —
/// a false positive just runs the walk.
threadlocal var recv_fn_gate_mod: ?*const Module = null;
threadlocal var recv_fn_gate_any: bool = true;
threadlocal var recv_fn_len_mask: u64 = ~@as(u64, 0);
threadlocal var recv_fn_byte_mask: u64 = ~@as(u64, 0);

fn recvFnPropsAny(self: *VmHost) bool {
    const mp: *const Module = self.module.asPtr();
    if (recv_fn_gate_mod == mp) return recv_fn_gate_any;
    const g = self.module.borrow();
    const reg = &g.get().registry;
    const any = reg.recv_fn_props.count() != 0;
    var lm: u64 = 0;
    var bm: u64 = 0;
    if (any) {
        var it = reg.recv_fn_props.iterator();
        while (it.next()) |e| {
            const pn = e.key_ptr.b;
            if (pn.len == 0) continue;
            lm |= @as(u64, 1) << @intCast(@min(pn.len, 63));
            bm |= @as(u64, 1) << @intCast(pn[0] & 63);
            if (runtime.envOnce("KLIO_RFP_DUMP") != null) {
                std.debug.print("[rfp] {s}.{s}\n", .{ e.key_ptr.a, pn });
            }
        }
    }
    g.deinit();
    recv_fn_len_mask = lm;
    recv_fn_byte_mask = bm;
    recv_fn_gate_mod = mp;
    recv_fn_gate_any = any;
    return any;
}

fn recvFnPropHeadOf(self: *VmHost, receiver: *const Value, name: []const u8) ?[]const u8 {
    if (receiver.* != .Instance) return null;
    if (!recvFnPropsAny(self)) return null;
    if (name.len == 0) return null;
    if ((recv_fn_len_mask >> @intCast(@min(name.len, 63))) & 1 == 0) return null;
    if ((recv_fn_byte_mask >> @intCast(name[0] & 63)) & 1 == 0) return null;
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
    if (runtime.envOnce("KLIO_HEAD_TRACE") != null)
        std.debug.print("[recvfn] head={s} passed={s}/{s} implements={} registered={}\n", .{ head, debugClassNameOf(self, receiver), @tagName(receiver.*), receiverImplementsHead(self, receiver, head), headNamesRegisteredClass(self, head) });
    if (head.len == 0 or receiverImplementsHead(self, receiver, head)) return receiver.*;
    // A head that names NO registered class (a bare type parameter --
    // `with`'s `T.()` block) proves nothing about any receiver: the value
    // the invoke supplied stands. Walking the chain here replaced a
    // `with(list)` subject with whatever Instance happened to be enclosing
    // once the subject tower put one there.
    if (!headNamesRegisteredClass(self, head)) return receiver.*;
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
    runtime.prof.opRoute(7);
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
    runtime.prof.opRoute(8);
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

/// Named-call flat prepare: replay a cached binding permutation (see
/// `namedOrderKey`) to reorder the arguments into declaration order, then
/// run the ordinary positional prepare on them. This is what lets a NAMED
/// member call run as a pushed activation instead of a recursive host
/// frame — the perm exists only because a prior call of this exact shape
/// bound and dispatched that order, and the positional prepare re-resolves
/// the target from the member cache with the reordered values, declining
/// (to the recursive ladder) on any miss, vararg, or defaulted shape.
pub fn prepareMemberFlatCallNamed(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    args: []const Value,
    arg_names: []const ?[]const u8,
    static_recv: ?[]const u8,
    declared_recv: ?[]const u8,
) Allocator.Error!?ir.eval.FlatCallReq {
    if (receiver.* != .Instance) return null;
    if (args.len > 15) return null;
    const k = namedOrderKey(self, receiver, name, args, arg_names) orelse return null;
    var perm: ?root_mod.ProgramImage.NamedPerm = null;
    const tslot = &tl_perm_cache[tlSlot(k)];
    if (tslot.raw_plus != 0 and tslot.gen == cacheGen() and tslot.class_p == k.class_p and tslot.name_p == k.name_p and
        tslot.sig == k.sig and tslot.n_args == k.n_args)
    {
        perm = tslot.perm;
    } else {
        const shared: ?root_mod.ProgramImage.NamedPerm = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().named_perm_cache.get(k);
        };
        if (shared) |sp| {
            tslot.* = .{ .class_p = k.class_p, .name_p = k.name_p, .n_args = k.n_args, .sig = k.sig, .raw_plus = 1, .gen = cacheGen(), .perm = sp };
            perm = sp;
        }
    }
    const p = perm orelse return null;
    if (p.n == 0xFF) return null;
    var buf: [15]Value = undefined;
    var m: usize = 0;
    while (m < p.n and p.src[m] != 0xFE) : (m += 1) {
        if (p.src[m] >= args.len) return null;
        buf[m] = args[p.src[m]];
    }
    return prepareMemberFlatCall(self, allocator, receiver, name, buf[0..m], static_recv, declared_recv, true);
}

/// Resolve an all-positional member call into a ready flat-call request when
/// the resolved-method (or resolved-extension) cache already names the
/// target and the call is the fully-applied no-vararg shape — the exact
/// calls `invokeMethodFuncId`'s fast path serves. Anything else (a stored
/// field shadowing the name, `copy`, defaults, varargs, a cache miss)
/// returns null and the recursive ladder runs unchanged. Mirrors the ladder
/// up to `invokeMethodFuncId`'s `evalWith` terminal, including the threaded
/// ambient-composer push (undone at activation close via `flatCallClosed`).
pub fn prepareMemberFlatCall(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8, declared_recv: ?[]const u8, allow_ext_cache: bool) Allocator.Error!?ir.eval.FlatCallReq {
    // Persistent-vector contains/indexOf are host-served (the ladder's
    // intercept); a flat-prepared interpreted body would bypass that.
    if (args.len == 1 and receiver.* == .Instance and
        (std.mem.eql(u8, name, "contains") or std.mem.eql(u8, name, "indexOf")) and
        persistent_list_eq.isVectorClass(receiver.Instance))
    {
        return null;
    }
    // Builder removeRange/addAll are host-served the same way.
    if (((args.len == 2 and std.mem.eql(u8, name, "removeRange")) or
        (args.len == 1 and std.mem.eql(u8, name, "addAll"))) and
        receiver.* == .Instance and
        persistent_list_mut.isBuilderClass(receiver.Instance))
    {
        return null;
    }
    // Map-builder put/build are host-served (persistent_map_mut.zig).
    if (((args.len == 2 and std.mem.eql(u8, name, "put")) or
        (args.len == 0 and std.mem.eql(u8, name, "build"))) and
        receiver.* == .Instance and
        persistent_map_mut.isBuilderClass(receiver.Instance))
    {
        return null;
    }
    // `map.builder()` is host-served once the builder template exists.
    if (args.len == 0 and std.mem.eql(u8, name, "builder") and
        receiver.* == .Instance and
        persistent_map_mut.isMapClass(receiver.Instance))
    {
        return null;
    }
    // SnapshotStateMap.put is host-served (whole write cycle).
    if (args.len == 2 and std.mem.eql(u8, name, "put") and
        receiver.* == .Instance and
        persistent_map_mut.isSnapshotMapClass(receiver.Instance))
    {
        return null;
    }
    // `closure.invoke(args…)`: the ladder lands at `callValueRec(receiver,
    // args)` with no closure-specific step before it, so the plain closure
    // invocation flattens identically.
    if (receiver.* == .IrClosure and std.mem.eql(u8, name, "invoke")) {
        return host_call_value.prepareClosureFlatCall(self, allocator, receiver, args);
    }
    if (receiver.* != .Instance) {
        // A non-Instance receiver keyable by identity (scalar, array,
        // closure, Result) flat-serves its cached top-level-extension
        // resolution: the ext cache only fills after every builtin/stdlib
        // arm declined for the same key, so a hit proves the ladder tail —
        // these calls (gap-buffer array accessors, coroutine-boundary
        // closure extensions) otherwise walk the full ladder per call.
        if (!allow_ext_cache) return null;
        const k = instanceMethodKeyScoped(self, receiver, name, args, static_recv, declared_recv) orelse return null;
        const raw = extMethodCacheGet(self, k) orelse return null;
        if (raw == METHOD_MISS) return null;
        return prepareFlatFromFid(self, allocator, receiver, args, @enumFromInt(raw));
    }
    // Data-class `copy` runs before the cache in the ladder; decline so it
    // keeps its precedence.
    if (std.mem.eql(u8, name, "copy")) return null;
    const strict_k = instanceMethodKeyScoped(self, receiver, name, args, static_recv, null);
    const k = strict_k orelse
        (instanceMethodKeyRelaxed(self, receiver, name, args, static_recv) orelse return null);
    var fid: ?FuncId = null;
    if (instanceMethodCacheGetRaw(self, k)) |raw| {
        if (raw != METHOD_MISS) fid = @enumFromInt(raw);
    }
    // A member-cache hit needs no stored-field shadow scan: when the walk
    // filled the entry the ladder's field arms had declined this key, a
    // vararg pick declines below (so `varargShadowedFieldInvoke` keeps its
    // claim through the recursive path), and Kotlin resolves a member
    // function ahead of any property/field-invoke convention anyway. The
    // scan still guards the ext-cache branch — a member field outranks a
    // top-level extension.
    if (fid == null) {
        {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            if (g.get().get(name) != null) return null;
        }
        // Same owner-independence guards the ext cache was populated under
        // (and the strict/members-only probes never consult it). A
        // scope-directed call probes under its scope-FOLDED key — the same
        // key `extensionFnFallback` caches it under, so it can only be
        // served what its own resolution stored. The RELAXED member key
        // never touches the extension caches.
        if (allow_ext_cache and static_recv == null and declared_recv == null) {
            if (strict_k) |sk| {
                if (extMethodCacheGet(self, sk)) |raw| {
                    if (raw != METHOD_MISS) fid = @enumFromInt(raw);
                }
            }
        } else if (allow_ext_cache) {
            if (instanceMethodKeyScoped(self, receiver, name, args, static_recv, declared_recv)) |k2| {
                if (extMethodCacheGet(self, k2)) |raw| {
                    if (raw != METHOD_MISS) fid = @enumFromInt(raw);
                }
            }
        }
    }
    const target = fid orelse return null;
    return prepareFlatFromFid(self, allocator, receiver, args, target);
}

/// Shared flat-request tail: resolve `target`, admit only the fully-applied
/// no-vararg shape, and build the `[receiver] ++ args` frame vector with the
/// threaded-composer push the recursive invoker would perform.
/// Whether the receiver's type declares a member of `name`, for ANY
/// receiver kind. `hostHasMember` answers only for interpreted Instances;
/// a HOST container (`.List`, `.Map`, a scalar) dispatches its members
/// through the FQN-keyed host table, so probe that table under the value's
/// nominal type and its builtin supertypes. The member-first guards lean
/// on this: with the Instance-only test they were blind to exactly the
/// receivers the `contains` self-loop runs on.
fn receiverHasMemberNamed(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    if (receiver.* == .Instance) return hostHasMember(self, receiver, name);
    var buf: [192]u8 = undefined;
    const nominal = valueNominalFqn(receiver);
    if (std.fmt.bufPrint(&buf, "{s}.{s}", .{ nominal, name })) |fqn| {
        if (lookupIntrinsic(self, fqn) != null) return true;
    } else |_| {}
    const simple = simpleName(nominal);
    for (applicability.builtinSupersOf(simple)) |sup| {
        if (std.fmt.bufPrint(&buf, "kotlin.collections.{s}.{s}", .{ sup, name })) |fqn| {
            if (lookupIntrinsic(self, fqn) != null) return true;
        } else |_| {}
        if (std.fmt.bufPrint(&buf, "kotlin.{s}.{s}", .{ sup, name })) |fqn| {
            if (lookupIntrinsic(self, fqn) != null) return true;
        } else |_| {}
    }
    return false;
}

/// A cached by-name extension resolution must never serve the frame that
/// is currently EXECUTING it: the bare call inside `Iterable.contains`'s
/// own body hitting the same (receiver-class, name, argc) key as the call
/// that entered it is an unconditional self-loop, and kotlinc resolves
/// that inner call to the receiver's member. Skipping the serve falls
/// down the ladder to the member probes.
fn cacheServesExecutingFrame(raw_fid: u32) bool {
    const cf = ir.eval.currentFrameFunc() orelse return false;
    return cf.id.int() == raw_fid;
}

fn prepareFlatFromFid(self: *VmHost, allocator: Allocator, receiver: *const Value, args: []const Value, target: FuncId) Allocator.Error!?ir.eval.FlatCallReq {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const f = mod.funcById(target) orelse return null;
    // The fast fully-applied shape only: no vararg anywhere, no default
    // padding, no trailing-lambda rebind.
    for (f.params) |*p| {
        if (p.is_vararg) return null;
    }
    if (args.len + 1 < f.params.len) return null;
    if (nuTraceEnv()) |want| {
        if (std.mem.eql(u8, want, f.name)) {
            std.debug.print("[invoke-method] {s}#{d} params={d} recv={s} FLAT\n", .{ f.fqn, target.int(), f.params.len, receiver.typeFqn() });
        }
    }
    var list = try ir.eval.acquireArgsCap(allocator, args.len + 1);
    list.appendAssumeCapacity(receiver.*);
    list.appendSliceAssumeCapacity(args);
    if (trace.invariantsEnabled()) {
        checkFuncInRange(self, "irMethodWalk", f.id);
        checkReceiverChain(self, allocator, "irMethodWalk", receiver, null);
    }
    vmhost.emitPath(allocator, "member_ir_walk", f.fqn, f.id, receiver, args);
    const threaded: ?Value = compose.threadedComposerArg(f.params, args);
    if (threaded) |c| compose.pushComposer(c);
    return .{
        .func = f,
        .run_module = mod,
        .args = list,
        .composer_pushed = threaded != null,
        .dst = undefined,
    };
}

/// `KLIO_VFLAT_TRACE=1` — one line per declined virtual flat prepare, with
/// the reason, for diagnosing why a slot population stays recursive.
var vflat_trace_cached: ?bool = null;
fn vflatTraceOn() bool {
    if (vflat_trace_cached) |b| return b;
    const b = runtime.envOnce("KLIO_VFLAT_TRACE") != null;
    vflat_trace_cached = b;
    return b;
}

/// Argument-type signature for a CallMember instruction-site memo: the same
/// strict primitive/identity fold the (class, name, sig) method cache keys
/// under, so a site replay can never serve an overload the cache would have
/// discriminated. Null = an unfingerprintable run; the site must not claim.
pub fn memberSiteSig(self: *VmHost, args: []const Value) ?u64 {
    // A zero-arg run has exactly one signature; skip the hash entirely —
    // `next()`/`hasNext()` style calls dominate the replay population.
    if (args.len == 0) return 2;
    const sig = methodArgSig(self, args) orelse return null;
    return if (sig == 0) 1 else sig;
}

/// Host-serve kinds a CallMember instruction-site memo can claim: route
/// word bit0 = 0, kind in the remaining bits (the flat-target form keeps
/// bit0 = 1 with the FuncId above it). The claimed class identity plus the
/// serve's own shape validation make a stale claim a safe bail.
pub const HostServeKind = enum(u32) {
    map_put = 1,
    map_build = 2,
    snapshot_map_put = 3,
};

/// Probe a (receiver, name, args) run for a host member serve at the
/// CallMember exec site, BEFORE the ladder entry: on a hit the value is
/// served and the kind returned so the site memo can claim the route.
pub fn hostMemberServeProbe(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    args: []const Value,
) Allocator.Error!?struct { kind: u32, val: Value } {
    if (receiver.* != .Instance) return null;
    if (args.len == 2 and std.mem.eql(u8, name, "put") and
        persistent_map_mut.isBuilderClass(receiver.Instance))
    {
        if (try persistent_map_mut.tryPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
            return .{ .kind = @intFromEnum(HostServeKind.map_put), .val = v };
        }
        return null;
    }
    if (args.len == 0 and std.mem.eql(u8, name, "build") and
        persistent_map_mut.isBuilderClass(receiver.Instance))
    {
        if (try persistent_map_mut.tryBuild(self, allocator, receiver.Instance)) |v| {
            return .{ .kind = @intFromEnum(HostServeKind.map_build), .val = v };
        }
        return null;
    }
    if (args.len == 2 and std.mem.eql(u8, name, "put") and
        persistent_map_mut.isSnapshotMapClass(receiver.Instance))
    {
        if (try persistent_map_mut.trySnapshotMapPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
            return .{ .kind = @intFromEnum(HostServeKind.snapshot_map_put), .val = v };
        }
        return null;
    }
    return null;
}

/// Replay a site-claimed host-serve kind. Any shape surprise returns null
/// and the call falls back to the full dispatch path.
pub fn hostMemberServeKind(
    self: *VmHost,
    allocator: Allocator,
    kind: u32,
    receiver: *const Value,
    args: []const Value,
) Allocator.Error!?Value {
    if (receiver.* != .Instance) return null;
    switch (kind) {
        @intFromEnum(HostServeKind.map_put) => {
            if (args.len != 2 or !persistent_map_mut.isBuilderClass(receiver.Instance)) return null;
            return persistent_map_mut.tryPut(self, allocator, receiver.Instance, &args[0], &args[1]);
        },
        @intFromEnum(HostServeKind.map_build) => {
            if (args.len != 0 or !persistent_map_mut.isBuilderClass(receiver.Instance)) return null;
            return persistent_map_mut.tryBuild(self, allocator, receiver.Instance);
        },
        @intFromEnum(HostServeKind.snapshot_map_put) => {
            if (args.len != 2 or !persistent_map_mut.isSnapshotMapClass(receiver.Instance)) return null;
            return persistent_map_mut.trySnapshotMapPut(self, allocator, receiver.Instance, &args[0], &args[1]);
        },
        else => return null,
    }
}

/// Replay a CallMember site memo's claimed target as a flat call. A stored
/// same-named instance field outranks a cached top-level extension (and an
/// invoke-convention callable can shadow), so the presence of one declines
/// to the full by-name path, exactly as the by-name prepare does.
pub fn prepareMemberFlatFromFid(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    args: []const Value,
    target: FuncId,
) Allocator.Error!?ir.eval.FlatCallReq {
    if (receiver.* == .Instance) {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        if (g.get().get(name) != null) return null;
    }
    return prepareFlatFromFid(self, allocator, receiver, args, target);
}

/// Flat-serve a bound virtual slot: resolve it against the receiver's class
/// exactly as `invokeVirtualMember`'s main path does, admitting only the
/// shape whose recursive serve would be a plain `[receiver] ++ args` frame —
/// a named main-module receiver class whose slot entry is an executable
/// interpreted body. Anonymous receivers (intrinsic shadowing, SAM targets,
/// name-ladder fallbacks), runtime-defined classes, and unlinked or bodyless
/// entries all decline to the recursive invoker unchanged.

fn slotNameForTrace(self: *VmHost, slot: MethodSlotId) []const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    const f = mg.get().funcById(FuncId.from(slot.int())) orelse return "?";
    return f.name;
}

pub fn prepareVirtualFlatCall(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    slot: MethodSlotId,
    args: []const Value,
) Allocator.Error!?ir.eval.FlatCallReq {
    const vtrace = vflatTraceOn();
    // Persistent-vector contains/indexOf are host-served (the
    // invokeVirtualMember intercept); a flat-prepared interpreted body
    // would bypass that.
    if (args.len == 1 and receiver.* == .Instance and
        persistent_list_eq.isVectorClass(receiver.Instance))
    {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vn| {
            if (std.mem.eql(u8, vn, "contains") or std.mem.eql(u8, vn, "indexOf")) return null;
        }
    }
    // Builder removeRange/addAll are host-served the same way.
    if ((args.len == 1 or args.len == 2) and receiver.* == .Instance and
        persistent_list_mut.isBuilderClass(receiver.Instance))
    {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vn| {
            if (args.len == 2 and std.mem.eql(u8, vn, "removeRange")) return null;
            if (args.len == 1 and std.mem.eql(u8, vn, "addAll")) return null;
        }
    }
    // Map-builder put/build/builder are host-served (persistent_map_mut.zig).
    if ((args.len == 0 or args.len == 2) and receiver.* == .Instance and
        (persistent_map_mut.isBuilderClass(receiver.Instance) or
            persistent_map_mut.isMapClass(receiver.Instance)))
    {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vn| {
            if (args.len == 2 and std.mem.eql(u8, vn, "put")) return null;
            if (args.len == 0 and (std.mem.eql(u8, vn, "build") or std.mem.eql(u8, vn, "builder"))) return null;
        }
    }
    // SnapshotStateMap.put is host-served (whole write cycle).
    if (args.len == 2 and receiver.* == .Instance and
        persistent_map_mut.isSnapshotMapClass(receiver.Instance))
    {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vn| {
            if (std.mem.eql(u8, vn, "put")) return null;
        }
    }
    if (receiver.* != .Instance) {
        if (vtrace) {
            const nm = virtualSlotInterfaceMember(self, slot) orelse slotNameForTrace(self, slot);
            std.debug.print("[vflat] decline non-instance {s} name={s}\n", .{ @tagName(std.meta.activeTag(receiver.*)), nm });
        }
        return null;
    }
    // A delegating receiver re-decides an interface-declared slot (see
    // `invokeVirtualMember`); decline so the call takes that route.
    if (virtualSlotInterfaceMember(self, slot)) |name| {
        if (interfaceDelegateFor(self, allocator, receiver.Instance, name) != null) {
            if (vtrace) std.debug.print("[vflat] decline delegated {s}\n", .{name});
            return null;
        }
    }
    const target = blk: {
        const instance = receiver.Instance.borrow();
        defer instance.deinit();
        const class = instance.get().class.borrow();
        defer class.deinit();
        if (class.get().is_anonymous) {
            if (vtrace) std.debug.print("[vflat] decline anon {s}\n", .{class.get().fqn});
            return null;
        }
        const mg = self.module.borrow();
        defer mg.deinit();
        const module = mg.get();
        const runtime_class = cid: {
            // Replay the class's resolved-id memo before the string-keyed
            // registry probe (see `ClassDef.resolve_mod`).
            const cdef = class.get();
            const mod_key = @intFromPtr(module);
            if (cdef.resolve_mod.load(.monotonic) == mod_key) {
                const plus1 = cdef.resolve_cid.load(.acquire);
                if (plus1 != 0) break :cid ir.ClassId.from(plus1 - 1);
            }
            const found = module.classIdByFqn(cdef.fqn) orelse {
                if (vtrace) std.debug.print("[vflat] decline no-classid {s}\n", .{cdef.fqn});
                return null;
            };
            const mut = @constCast(cdef);
            if (mut.resolve_mod.cmpxchgStrong(0, mod_key, .acq_rel, .monotonic) == null) {
                mut.resolve_cid.store(found.int() + 1, .release);
            }
            break :cid found;
        };
        const t = module.methodSlotTarget(runtime_class, slot) orelse {
            if (vtrace) std.debug.print("[vflat] decline no-slot-target {s} slot={d}\n", .{ class.get().fqn, slot.int() });
            return null;
        };
        if (!virtualTargetExecutable(module, t)) {
            if (vtrace) std.debug.print("[vflat] decline not-executable {s}\n", .{class.get().fqn});
            return null;
        }
        // A barrier member whose argument fails the type-safe bridge check
        // must not flat-enter the body; the recursive path answers the
        // bridge default.
        if (module.funcById(FuncId.from(slot.int()))) |rootf| {
            if (barrierSpec(rootf.name)) |kind| {
                if (typeSafeBarrierAnswer(self, module, t, kind, args) != null) {
                    if (vtrace) std.debug.print("[vflat] decline barrier {s}\n", .{rootf.name});
                    return null;
                }
            }
        }
        break :blk t;
    };
    const req = try prepareFlatFromFid(self, allocator, receiver, args, target);
    if (vtrace and req == null) std.debug.print("[vflat] decline shape fid={d}\n", .{target.int()});
    return req;
}

/// Flat-serve a lowering-resolved plain member. Member extensions need their
/// declaring class's `this` seeded as an enclosing receiver, and a bodyless
/// declaration runs as its linked host symbol; both keep the recursive path.
pub fn prepareResolvedFlatCall(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    fid: FuncId,
    args: []const Value,
) Allocator.Error!?ir.eval.FlatCallReq {
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const module = mg.get();
        if (isMemberExt(module, fid)) return null;
        const f = funcAt(module, fid) orelse return null;
        if (!f.hasBody()) return null;
    }
    // A delegating receiver re-decides an interface-declared target (see
    // `invokeResolvedMember`); decline so the call takes that route.
    if (receiver.* == .Instance) {
        if (resolvedMemberName(self, fid)) |name| {
            if (interfaceDelegateFor(self, allocator, receiver.Instance, name) != null) return null;
        }
    }
    return prepareFlatFromFid(self, allocator, receiver, args, fid);
}

var route_trace_init: bool = false;
var route_trace_val: ?[]const u8 = null;
fn routeTraceOn(name: []const u8) bool {
    if (!route_trace_init) {
        route_trace_val = if (std.c.getenv("KLIO_ROUTE")) |w| std.mem.span(w) else null;
        route_trace_init = true;
    }
    const w = route_trace_val orelse return false;
    return std.mem.eql(u8, w, name);
}

/// A resolution the intrinsic member dispatch already settled for a BUILTIN
/// receiver, answered before the probe ladder runs.
///
/// `stdlibMemberDispatch` memoizes the winning intrinsic per (receiver type,
/// name, arity-is-zero) — but it sits far down the ladder, so every
/// `Array.copyInto` / `Int.coerceAtMost` in a loop re-walked the arms above it
/// to reach an answer that was already known. An entry exists only for a pair
/// whose earlier arms declined once and whose resolution was judged cacheable
/// (no user extension shadows it), so replaying it changes nothing but the
/// path taken. Instance receivers keep the full walk: their arms consult the
/// class hierarchy, which the earlier method caches already cover.
fn builtinIntrinsicReplay(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const name_p = memberNameIdentity(self, name) orelse return null;
    const key: root_mod.ProgramImage.MemberResolveKey = .{
        .type_p = @intFromPtr(receiver.typeFqn().ptr),
        .name_p = name_p,
        .args_empty = args.len == 0,
    };
    const e = &tl_resolve_cache[tlResolveSlot(key)];
    if (e.state == 2 and e.gen == cacheGen() and e.type_p == key.type_p and e.name_p == key.name_p and e.args_empty == key.args_empty) {
        return try dispatchWithReceiver(self, allocator, e.fqn, e.func.?, receiver, args);
    }
    return null;
}

/// How many named member calls the builtin intrinsic REPLAY serves outright,
/// versus reaching the probe ladder proper. `member_ladder` counts the route,
/// not the work, so the two are not the same number.
var replay_hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn replayHits() u64 {
    return replay_hits.load(.monotonic);
}

fn callMemberInnerStatic(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8, no_ext: bool, declared_recv: ?[]const u8) Allocator.Error!EvalResult {
    // A callable reference's `equals`/`hashCode` follow reference equality
    // (target, receiver, adaptation), never the string or scalar builtins.
    if (receiver.* == .IrClosure or receiver.* == .PropertyRef) {
        if (args.len == 1 and std.mem.eql(u8, name, "equals")) {
            const eq = if (args[0] == .IrClosure or args[0] == .PropertyRef) try builtin_members.deepValueEquals(self, allocator, receiver, &args[0]) else false;
            return .{ .ok = boolVal(eq) };
        }
        if (args.len == 0 and std.mem.eql(u8, name, "hashCode")) {
            return .{ .ok = Value.newInt(@as(i64, try builtin_members.hashWithDispatch(self, allocator, receiver))) };
        }
    }
    // The delegated-property creation convention, served with its own
    // fallback (a dispatch miss keeps the delegate).
    if (args.len == 2 and name.len == "$provideDelegate".len and name[0] == '$' and std.mem.eql(u8, name, "$provideDelegate")) {
        return provideDelegateFor(self, allocator, args[0], args[1], receiver.*);
    }
    // Vendored persistent-map equality: answered host-side with trie
    // node-identity pruning (see persistent_map_eq.zig). Bails (null) for
    // any operand or element the host does not own equality for.
    if (args.len == 1 and receiver.* == .Instance and args[0] == .Instance and
        std.mem.eql(u8, name, "equals"))
    {
        if (persistent_map_eq.tryEquals(receiver.Instance, args[0].Instance)) |eq| {
            return .{ .ok = .{ .Bool = eq } };
        }
        if (persistent_list_eq.tryEquals(receiver.Instance, args[0].Instance)) |eq| {
            return .{ .ok = .{ .Bool = eq } };
        }
    }
    // Vendored persistent-vector scans: `contains`/`indexOf` otherwise
    // iterate the trie through a fully interpreted iterator with a
    // dispatched equals per element (~4.5ms per contains on 1000
    // elements); the host walks the leaf arrays directly.
    if (args.len == 1 and receiver.* == .Instance and
        (std.mem.eql(u8, name, "contains") or std.mem.eql(u8, name, "indexOf")))
    {
        if (persistent_list_eq.tryIndexOf(receiver.Instance, &args[0])) |idx| {
            if (name.len == 8) return .{ .ok = .{ .Bool = idx >= 0 } };
            return .{ .ok = Value.newInt(idx) };
        }
    }
    // Vendored persistent-vector builder bulk ops: `removeRange` otherwise
    // runs one interpreted removeAt per element with a suffix shift each,
    // and `addAll` an interpreted per-element buffer fill (see
    // persistent_list_mut.zig).
    if (args.len == 2 and receiver.* == .Instance and std.mem.eql(u8, name, "removeRange")) {
        if (try persistent_list_mut.tryRemoveRange(allocator, receiver.Instance, &args[0], &args[1])) |v| {
            return .{ .ok = v };
        }
    }
    if (args.len == 1 and receiver.* == .Instance and std.mem.eql(u8, name, "addAll")) {
        if (try persistent_list_mut.tryAddAll(allocator, receiver.Instance, &args[0])) |v| {
            return .{ .ok = v };
        }
    }
    // Vendored persistent-map builder ops: `put` walks the CHAMP trie
    // through framed calls per map write, `build` re-wraps it (see
    // persistent_map_mut.zig).
    if (receiver.* == .Instance and persistent_map_mut.isBuilderClass(receiver.Instance)) {
        if (args.len == 2 and std.mem.eql(u8, name, "put")) {
            if (try persistent_map_mut.tryPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
                return .{ .ok = v };
            }
        }
        if (args.len == 0 and std.mem.eql(u8, name, "build")) {
            if (try persistent_map_mut.tryBuild(self, allocator, receiver.Instance)) |v| {
                return .{ .ok = v };
            }
        }
    }
    if (args.len == 0 and receiver.* == .Instance and std.mem.eql(u8, name, "builder")) {
        if (try persistent_map_mut.tryBuilder(self, allocator, receiver.Instance)) |v| {
            return .{ .ok = v };
        }
    }
    // The whole-cycle SnapshotStateMap.put serve (persistent_map_mut.zig).
    if (args.len == 2 and receiver.* == .Instance and std.mem.eql(u8, name, "put") and
        persistent_map_mut.isSnapshotMapClass(receiver.Instance))
    {
        if (try persistent_map_mut.trySnapshotMapPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
            return .{ .ok = v };
        }
    }

    if (receiver.* != .Instance and !strict_ext and !no_ext and static_recv == null and declared_recv == null) {
        if (try builtinIntrinsicReplay(self, allocator, receiver, name, args)) |r| {
            _ = replay_hits.fetchAdd(1, .monotonic);
            return r;
        }
    }
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
    // A member of a `by`-delegated interface the class does not override is
    // the delegate's, even when the interface supplies a default body — the
    // ladder below would reach that default first.
    if (receiver.* == .Instance and !strict_ext and !no_ext) {
        if (interfaceDelegateFor(self, allocator, receiver.Instance, name)) |d| {
            const r = try callMemberRec(self, allocator, &d, name, args);
            switch (r) {
                .ok => return r,
                .err => |e| if (e != .Unimplemented) return r else freeDispatchMiss(allocator, r),
            }
        }
    }
    runtime.prof.opRoute(15);

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
        const head_strict = instanceMethodKeyScoped(self, receiver, name, args, static_recv, null);
        if (head_strict == null) {
            // Container-typed args: probe the member cache under the
            // RELAXED key (fills come from `irMethodWalk`); the extension
            // caches stay strict-key-only below.
            if (instanceMethodKeyRelaxed(self, receiver, name, args, static_recv)) |rk| {
                if (instanceMethodCacheGetRaw(self, rk)) |raw| {
                    if (raw != METHOD_MISS and !cacheServesExecutingFrame(raw)) {
                        if (routeTraceOn(name)) std.debug.print("[route] L4083\n", .{});
                        if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(raw), args)) |r| return r;
                    }
                }
            }
        }
        if (head_strict) |k| {
            if (instanceMethodCacheGetRaw(self, k)) |raw| {
                if (raw != METHOD_MISS and !cacheServesExecutingFrame(raw)) {
                    if (routeTraceOn(name)) std.debug.print("[route] L4092\n", .{});
                    if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(raw), args)) |r| return r;
                }
                // A cached miss falls through to the probe ladder (stdlib /
                // extension / field), but `irMethodWalk` will skip the walk.
            }
            // Member-miss that resolved to a top-level extension: dispatch it
            // here, before the whole builtin probe ladder, exactly as the
            // member fast path above does. Same owner-independence guards the
            // cache was populated under. A scope-directed call probes under
            // its scope-FOLDED key — the same key `extensionFnFallback`
            // caches it under, so it can only be served what its own
            // resolution stored.
            if (!strict_ext and !no_ext and static_recv == null and declared_recv == null) {
                if (extMethodCacheGet(self, k)) |fid| {
                    // A top-level extension's `param[0]` is its receiver, so the
                    // member invoker binds `[receiver] ++ args` correctly — and
                    // it builds the frame args in one allocation (no prepend
                    // scratch slice), matching the member fast path's speed.
                    if (fid != METHOD_MISS and !cacheServesExecutingFrame(fid)) {
                        if (routeTraceOn(name)) std.debug.print("[route] L4111\n", .{});
                        if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(fid), args)) |r| return r;
                    }
                }
            } else if (!strict_ext and !no_ext) {
                if (instanceMethodKeyScoped(self, receiver, name, args, static_recv, declared_recv)) |k2| {
                    if (extMethodCacheGet(self, k2)) |fid| {
                        if (fid != METHOD_MISS and !cacheServesExecutingFrame(fid)) {
                            if (routeTraceOn(name)) std.debug.print("[route] L4118\n", .{});
                            if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(fid), args)) |r| return r;
                        }
                    }
                }
            }
        }
    }
    // A non-Instance receiver keyable by identity (scalar, array, closure,
    // Result) serves its cached top-level-extension resolution here too:
    // the ext cache only fills after every arm between this probe and the
    // fallback declined for the same key, so a hit proves the ladder tail.
    if (receiver.* != .Instance and !strict_ext and !no_ext) {
        if (instanceMethodKeyScoped(self, receiver, name, args, static_recv, declared_recv)) |k| {
            if (extMethodCacheGet(self, k)) |fid| {
                if (fid != METHOD_MISS and !cacheServesExecutingFrame(fid)) {
                    if (routeTraceOn(name)) std.debug.print("[route] L4133\n", .{});
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
        if (routeTraceOn(name)) std.debug.print("[route] L4156\n", .{});
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
            return .{ .err = .{ .Throw = try Value.newException(allocator, .{
                .fqn = try runtime.strInit(allocator, "kotlin.IndexOutOfBoundsException"),
                .message = .from(try runtime.strInitOwned(allocator, msg)),
                .cause = null,
            }) } };
        }
        const start: usize = @intCast(idx);
        if (stdlib.implementations.collections.sublistViewStale(receiver)) {
            return .{ .err = try throwExc(allocator, "kotlin.ConcurrentModificationException", null) };
        }
        const cap = try captureModCount(allocator, receiver.List.mod_count.get());
        // Share the backing list (not a snapshot) so a `MutableListIterator`'s
        // `set`/`add`/`remove` mutate the underlying list, matching Kotlin. The
        // iterator is mutable only when the source list is.
        return .{ .ok = try Value.newIterator(allocator, .{
            .items = receiver.List.items.clone(),
            .prim = null,
            .mod_count = .from(cap.mod_count),
            .mutable = receiver.List.mutable and receiver.List.backing == null and
                !stdlib.implementations.collections.modCountFrozen(receiver.List.mod_count), .pos = start, .exp_mod = cap.exp_mod }) };
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
                // An inner class of a LOCAL class has no module index entry:
                // its runtime definition is the class (`Local().Inner(k)`).
                const cls_val: Value = .{ .Class = def.clone() };
                defer if (runtime.reclaimEnabled()) cls_val.release(allocator);
                const r = try host_call_value.callValue(self, allocator, &cls_val, args);
                if (r == .ok and r.ok == .Instance) {
                    const ig = r.ok.Instance.borrowMut();
                    ig.get().outer = .{ .Instance = receiver.Instance.clone() };
                    ig.deinit();
                }
                return r;
            }
        }
    }

    // `KClass.isInstance(value)`. The value-side predicate walks the
    // captured-env supertype chain, which dead-ends when a parent class
    // is not env-visible (a cross-pack ancestor like `ClosedByteChannel-
    // Exception : kotlinx.io.IOException`); fall through to the host's
    // registry-backed walk so `isInstance` agrees with `is`.
    if (receiver.* == .Class and std.mem.eql(u8, name, "isInstance") and args.len == 1) {
        const cg = receiver.Class.borrow();
        const cname = cg.get().name;
        var hit = args[0].isRuntimeType(cname);
        if (!hit and args[0] == .Instance) hit = receiverImplementsType(self, &args[0], cname);
        const r = boolVal(hit);
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
        const casts = args[0].isRuntimeType(cname) or
            (args[0] == .Instance and receiverImplementsType(self, &args[0], cname));
        if (casts) {
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
        mg.deinit();
        if (class_id) |cid| {
            return newInstanceById(self, allocator, cid, args, null);
        }
    }

    // Companion forwarding + enum values/valueOf for a class receiver.
    if (receiver.* == .Class) {
        if (try classCompanionAndEnum(self, allocator, receiver, name, args)) |r| return r;
    }

    // Last-resort nested-class construction by SIMPLE name, for a nested
    // class the nesting tree could not link to its parent (a lifted class
    // under a legacy simple-name stub). It runs AFTER companion forwarding:
    // an unrelated global of the same simple name must never outrank the
    // receiver's own companion member — `ParseResult.Error(pos) { … }` is
    // the companion's factory, not `kotlin.Error`.
    if (receiver.* == .Class) {
        const cid = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().classId(name);
        };
        if (cid) |c| return newInstanceById(self, allocator, c, args, null);
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
        // `Double.equals`/`Float.equals` compare the boxed representation:
        // `(-0.0).equals(0.0)` is false and `NaN.equals(NaN)` is true, unlike
        // the IEEE `==` on the primitive.
        if ((receiver.* == .Double or receiver.* == .Float) and args.len == 1) {
            return .{ .ok = boolVal(Value.structuralEqBoxed(receiver, &args[0])) };
        }
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
        if (samTraceOn()) std.debug.print("[sam-gate] name={s} nargs={d} has_ext={} arity_ok={} tl={}\n", .{ name, args.len, has_ext, arity_ok, toplevel_serves });
        if (!std.mem.eql(u8, name, "invoke") and !has_ext and arity_ok and !toplevel_serves) {
            if (samTraceOn()) std.debug.print("[sam-arm] name={s} nargs={d} arity_ok={} tl={}\n", .{ name, args.len, arity_ok, toplevel_serves });
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
    if (receiver.* == .IrClosure) {
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
        if (routeTraceOn(name)) std.debug.print("[route] L4660\n", .{});
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
        if (routeTraceOn(name)) std.debug.print("[route] L4766\n", .{});
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
    runtime.prof.opRoute(16);

    // Class-delegation pre-pass.
    if (receiver.* == .Instance) {
        if (try delegateForward(self, allocator, receiver, name, args, true)) |r| return r;
    }

    // Extension-fn fallback.
    // A members-only probe (the caller holds a lowering-committed extension
    // target): Kotlin selects extensions statically, so only a true member
    // may shadow it — the by-name extension re-pick must not re-select a
    // sibling overload the static evidence excluded.
    // A runtime-registered LOCAL class's companion serves a member call on
    // the class value ahead of any extension on `KClass`, as a module
    // class's companion does through the registry.
    if (receiver.* == .Class) {
        if (try localClassCompanionForward(self, allocator, receiver, name, args)) |r| return r;
    }
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
        // The same for a NAMED enclosing class: a member extension the
        // lowerer could not bind statically because the receiver's declared
        // type was unavailable at the call site.
        if (try enclosingNamedMemberExtDispatch(self, allocator, receiver, name, args)) |r| return r;
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
        if (routeTraceOn(name)) std.debug.print("[route] L4890\n", .{});
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
    // An enum's bare name is published as its COMPANION instance once it
    // has one, so `Color.values()` written in another file arrives here
    // with the companion as receiver. The enum statics (`values`,
    // `valueOf`, `entries`) belong to the enum class: redirect.
    if (receiver.* == .Instance and (std.mem.eql(u8, name, "values") or std.mem.eql(u8, name, "valueOf") or std.mem.eql(u8, name, "entries"))) {
        const comp_cls: ObjRef(ClassDef) = blk: {
            const ig = receiver.Instance.borrow();
            defer ig.deinit();
            break :blk ig.get().class.clone();
        };
        defer comp_cls.deinit();
        const is_companion = blk: {
            const cg = comp_cls.borrow();
            defer cg.deinit();
            const n = cg.get().name;
            break :blk std.mem.endsWith(u8, n, "$Companion") or std.mem.endsWith(u8, n, ".Companion") or std.mem.eql(u8, n, "Companion");
        };
        if (is_companion) {
            const cv = Value{ .Class = comp_cls };
            if (try companionOwnerClassValue(self, &cv)) |owner| {
                defer owner.release(allocator);
                const owner_is_enum = blk: {
                    const og = owner.Class.borrow();
                    defer og.deinit();
                    break :blk og.get().is_enum;
                };
                if (owner_is_enum) return try callMember(self, allocator, &owner, name, args);
            }
        }
    }

    // `serializer()` on a `@Serializable` declaration is the GENERATED
    // companion member (src/serialization_pass), reached above through
    // classCompanionForward. A CLASS VALUE receiver that has no such
    // member is a `KClass` — `Foo::class.serializer()` — and resolves to
    // kotlinx-serialization's `KClass<T>.serializer()` extension, exactly
    // as any extension on a KClass receiver would.
    if (receiver.* == .Class and std.mem.eql(u8, name, "serializer")) {
        const ext_fid: ?FuncId = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const m = mg.get();
            for (m.funcsBySimpleName("serializer")) |cand| {
                const cf = m.funcById(cand) orelse continue;
                if (!std.mem.eql(u8, cf.fqn, "kotlinx.serialization.serializer")) continue;
                if (cf.params.len != args.len + 1) continue;
                if (!std.mem.eql(u8, cf.params[0].name, "this")) continue;
                if (!std.mem.eql(u8, simpleName(cf.params[0].ty.name), "KClass")) continue;
                break :blk cand;
            }
            break :blk null;
        };
        if (ext_fid) |fid| {
            var call_args: std.ArrayList(Value) = .empty;
            defer call_args.deinit(allocator);
            try call_args.append(allocator, receiver.*);
            try call_args.appendSlice(allocator, args);
            return try callFuncRec(self, allocator, self.module.asPtr(), fid, call_args.items);
        }
    }

    // `@Serializer(forClass = C::class)` marks a declaration the kotlinx
    // plugin fills in: the object IS C's serializer, and its `descriptor`,
    // `serialize` and `deserialize` are generated. klio has no plugin, so a
    // member the declaration does not itself define is answered by C's own
    // serializer.
    if (try serializerForClassTarget(self, allocator, receiver)) |ser| {
        defer ser.release(allocator);
        if (routeTraceOn(name)) std.debug.print("[route] serializer-forClass\n", .{});
        return callMemberRec(self, allocator, &ser, name, args);
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
        if (field == null and missTraceWant(name)) {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            std.debug.print("[fnprop] no own field `{s}`; fields:", .{name});
            for (g.get().fields.items) |f| std.debug.print(" {s}", .{f.name});
            std.debug.print("\n", .{});
        }
        if (field) |v| {
            if (missTraceWant(name)) {
                const np: i64 = if (v == .IrClosure)
                    if (self.closures.get(@intCast(v.IrClosure.id))) |info| @intCast(info.n_params) else -1
                else
                    -2;
                std.debug.print("[fnprop] own-field hit tag={s} callable={} n_params={d} args={d}\n", .{ @tagName(v), isCallable(&v), np, args.len });
            }
            if (isCallable(&v) or v == .Instance) {
                // A RECEIVER-function-typed property binds an implicit
                // receiver of its declared head at invocation; with none
                // in scope the property does not apply — skip the arm.
                if (recvFnPropHeadOf(self, receiver, name)) |head| {
                    // One arg more than the stored lambda's declared params
                    // is the function-style invoke with the receiver passed
                    // first (`content.item(itemScope, localIndex)` where
                    // `item: LazyItemScope.(Int) -> Unit`). Kotlin selects
                    // that shape by arity, ahead of any implicit scope
                    // receiver — callValueRec binds args[0] as the receiver.
                    const first_arg_recv = blk: {
                        if (v != .IrClosure or args.len == 0) break :blk false;
                        const info = self.closures.get(@intCast(v.IrClosure.id)) orelse break :blk false;
                        break :blk args.len == info.n_params + 1 or
                            (args.len + 2 == info.n_params + 1 and closurePairTailed(self, info));
                    };
                    if (first_arg_recv) return callValueRec(self, allocator, &v, args);
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
        if (routeTraceOn(name)) std.debug.print("[route] L5074\n", .{});
        const sres = try callMemberRec(self, allocator, receiver, "toString", &.{});
        switch (sres) {
            .ok => |sv| {
                if (sv == .String) {
                    if (routeTraceOn(name)) std.debug.print("[route] L5078\n", .{});
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
                if (routeTraceOn(name)) std.debug.print("[route] L5100\n", .{});
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
                // The call shape must fit SOME source declaration of this
                // name for an iterable receiver. Inside KlioPath (which has
                // an `iterator()`), `max(1, 4)` is the imported
                // kotlin.math.max global — the zero-argument collection
                // `max` must not swallow it by draining the path into a
                // list and returning its largest segment.
                const arity_fits = blk2: {
                    const mg2 = self.module.borrow();
                    defer mg2.deinit();
                    const m2 = @constCast(mg2.get());
                    break :blk2 m2.extCouldApply(allocator, "Iterable", name, args.len) or
                        m2.extCouldApply(allocator, "List", name, args.len) or
                        m2.extCouldApply(allocator, "Collection", name, args.len);
                };
                if (!arity_fits) {
                    if (routeTraceOn(name)) std.debug.print("[route] L5147-arity-skip\n", .{});
                } else {
                // `toTypedArray` must observe a user `toArray()` override
                // before any drain (JS/native `collectionToArray` semantics);
                // its intrinsic handles Instance receivers itself.
                if (std.mem.eql(u8, name, "toTypedArray")) {
                    return try dispatchWithReceiver(self, allocator, matched, f, receiver, args);
                }
                if (runtime.envSetOnce("KLIO_DRAIN_TRACE")) {
                    std.debug.print("[drain] {s} on {s} caller={s} span={?any}\n", .{
                        name,
                        receiver.typeFqn(),
                        if (ir.eval.currentFrameFunc()) |cfn| cfn.fqn else "<none>",
                        ir.eval.currentCallSiteSpan(),
                    });
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
                .IrClosure, .Class => {
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
                .IrClosure => return callValueRec(self, allocator, &g, args),
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
            // The terminal by-name scan must not re-pick the EXECUTING
            // function when the receiver's own type declares this member:
            // kotlinc binds the member, and re-entering the caller is the
            // armed `Iterable.contains` self-loop (`contains(element)` on
            // a List inside contains' own smart-cast branch). Skipping
            // falls through to the host member probes below.
            const self_repick = blk: {
                const cf = ir.eval.currentFrameFunc() orelse break :blk false;
                break :blk cf.id.int() == fid.int() and
                    receiverHasMemberNamed(self, receiver, name);
            };
            if (!self_repick) {
                const mg = self.module.borrow();
                const mod: *const Module = mg.get();
                mg.deinit();
                const call_args = try allocator.alloc(Value, args.len + 1);
                defer allocator.free(call_args);
                call_args[0] = receiver.*;
                @memcpy(call_args[1..], args);
                if (routeTraceOn(name)) std.debug.print("[route] L5263\n", .{});
                return host_call_func.callFunc(self, allocator, mod, fid, call_args);
            }
        }
        if (retry_leaf) |leaf| {
            // No body-bearing overload under the aliased FQN: the target is
            // intrinsic-backed (`kotlin.text.uppercase`). Re-dispatch under
            // the target's real name. Self-recapture guard: a delegating
            // wrapper bearing that simple name must not rebind itself.
            const cur = ir.eval.currentFuncName() orelse "";
            if (!std.mem.eql(u8, cur, leaf)) {
                if (routeTraceOn(name)) std.debug.print("[route] L5273\n", .{});
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
                if (routeTraceOn(name)) std.debug.print("[route] L5289\n", .{});
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
        if (try composeMemberPairRetry(self, allocator, receiver, name, args, strict_ext, static_recv, no_ext, declared_recv)) |r| return r;
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        missTraceMaybe(name);
        if (missTraceWant(name)) missDumpClassChain(receiver);
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

    if (try composeMemberPairRetry(self, allocator, receiver, name, args, strict_ext, static_recv, no_ext, declared_recv)) |r| return r;
    // A host-backed value whose runtime class ships interpreted SOURCE
    // (`UByteArray : Collection<UByte>` declares `isEmpty`): resolve the
    // member against that class and run its body — the representation
    // reads inside (`storage`) are host-served. Sits at the total-miss
    // tail so every intrinsic and operator tail above still wins.
    {
        const target: ?FuncId = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const module = mg.get();
            const cid = module.classIdByFqn(receiver.typeFqn()) orelse break :blk null;
            const caller_file = if (ir.eval.currentCallSiteSpan()) |sp| sp.file else ir.FileId.from(0);
            const resolved = module.resolveMemberCall(cid, name, &.{}, .{
                .caller_file = caller_file,
                .lexical_owner = null,
                .actual_type_param_bounds = &.{},
            });
            const t = resolved.target orelse break :blk null;
            // Only a member the receiver's OWN class hierarchy declares may
            // run here: a same-named member of an unrelated class (UInt.or
            // for an Int receiver) reads representation the value does not
            // have.
            const sig = module.decl_sigs.get(t.int()) orelse break :blk null;
            const owner = sig.enclosing_class orelse break :blk null;
            if (owner.int() != cid.int()) {
                if (owner.int() >= module.classes.items.len) break :blk null;
                const owner_fqn = module.classes.items[owner.int()].fqn;
                const recv_class = &module.classes.items[cid.int()];
                var in_chain = false;
                if (module.registry.class_super_names.get(recv_class.name)) |chain| {
                    for (chain) |cn| {
                        if (std.mem.eql(u8, cn, owner_fqn) or
                            std.mem.eql(u8, typeHeadLast(cn), typeHeadLast(owner_fqn)))
                        {
                            in_chain = true;
                            break;
                        }
                    }
                }
                if (!in_chain) break :blk null;
            }
            break :blk t;
        };
        if (target) |t| {
            if (try invokeMethodFuncId(self, allocator, receiver, t, args)) |r| return r;
        }
    }
    missTraceMaybe(name);
    if (missTraceEnv() != null) {
        std.debug.print("[member-miss] `{s}` on `{s}` span={any}\n", .{ name, receiver.typeFqn(), ir.eval.currentCallSiteSpan() });
        ir.eval.dumpCurrentFrameParamsForDiag();
        ir.eval.debugPrintFrames();
    }
    return unimplemented(allocator, "Vm::call_member `{s}` on `{s}`", .{ name, receiver.typeFqn() });
}

/// Compose ABI completion at the member-miss tails. A bare sibling call to
/// a `@Composable` METHOD keeps its source argument shape (the pass defers
/// bare calls to resolution), and a runtime-dispatched member has no
/// lowering-side completion — so the threaded method's trailing
/// `($composer, $changed)` params go unsupplied and every overload
/// declines. When an ambient composer exists, retry the whole dispatch once
/// with the pair appended, exactly as the closure invoke path completes a
/// typeless composable value call. Miss-tail only: a call that resolved
/// without the pair is never touched, and the strict receiver probes (whose
/// misses are an expected part of the bare-name walk) never retry.
/// Whether the receiver's class hierarchy declares a method `name` whose
/// params end with the generated composer pair and whose user arity fits
/// `args.len + 2` — the proof that the miss is an unthreaded call to a
/// threaded composable member, not an arbitration probe that must stay
/// missed so its caller's next arm (an extension, a global) can win.
fn receiverHasThreadedMember(self: *VmHost, receiver: *const Value, name: []const u8, nargs: usize) bool {
    if (receiver.* != .Instance) return false;
    const recv_name = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    // Walk the receiver's class chain by simple name (methods live on the
    // class, not in the top-level function index). Bounded like the
    // dispatch walk itself.
    var cur: ?[]const u8 = recv_name;
    var hops: usize = 0;
    while (cur) |cn| : (hops += 1) {
        if (hops > 32) break;
        const cid = m.uniqueClassIdBySimpleName(cn) orelse break;
        const class = &m.classes.items[cid.int()];
        for (class.methods) |fid| {
            const f = m.funcById(fid) orelse continue;
            if (!std.mem.eql(u8, f.name, name)) continue;
            if (f.params.len < 3) continue;
            if (!std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer")) continue;
            if (!std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed")) continue;
            const skip: usize = if (std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            // At least the pair beyond the supplied args; a LARGER gap is a
            // defaulted middle (CardDefaults.cardElevation's five Dp
            // defaults) — the retried dispatch's own applicability check
            // still validates that every unfilled param defaults.
            if (f.params.len - skip < nargs + 2) continue;
            return true;
        }
        const supers = m.registry.class_super_names.get(cn) orelse break;
        cur = if (supers.len != 0) supers[0] else null;
    }
    // A threaded composable EXTENSION reached by member syntax
    // (`colorScheme.applyTonalElevation(...)`): same proof over the
    // top-level index, with the declared receiver checked against the
    // receiver's hierarchy.
    for (m.funcsBySimpleName(name)) |fid| {
        const f = m.funcById(fid) orelse continue;
        if (f.params.len < 3) continue;
        if (!std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (!std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer")) continue;
        if (!std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed")) continue;
        if (f.params.len - 1 < nargs + 2) continue;
        const recv_head = applicability.simpleName(std.mem.trimEnd(u8, f.params[0].ty.name, "?"));
        if (m.classIsOrExtends(recv_name, recv_head)) return true;
    }
    return false;
}

fn composeMemberPairRetry(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8, no_ext: bool, declared_recv: ?[]const u8) Allocator.Error!?EvalResult {
    _ = static_recv;
    _ = no_ext;
    _ = declared_recv;
    if (strict_ext) return null;
    const comp = compose.currentComposer() orelse return null;
    // A retried dispatch already carries the pair this completion appended;
    // recognize it by the ambient composer's identity in the second-to-last
    // slot rather than a flag — a flag's lifetime would span the retried
    // callee's whole EXECUTION and suppress the completion for every nested
    // call in its body (the private-member fixture's `inner` inside the
    // completed `outer`).
    if (args.len >= 2 and args[args.len - 1] == .Int and
        args[args.len - 2] == .Instance and comp == .Instance and
        ObjRef(InstanceData).ptrEq(args[args.len - 2].Instance, comp.Instance)) return null;
    if (!receiverHasThreadedMember(self, receiver, name, args.len)) return null;
    const buf = try allocator.alloc(Value, args.len + 2);
    defer if (runtime.freeScratch()) allocator.free(buf);
    @memcpy(buf[0..args.len], args);
    buf[args.len] = comp;
    buf[args.len + 1] = .{ .Int = 0 };
    // The pair binds BY NAME: a threaded member may declare defaulted
    // params between the user args and the pair (CardDefaults.cardElevation's
    // five Dp defaults) — appended positionally the composer would land in
    // the first defaulted slot. The named walk reorders and default-fills.
    const names_buf = try allocator.alloc(?[]const u8, args.len + 2);
    defer if (runtime.freeScratch()) allocator.free(names_buf);
    for (names_buf[0..args.len]) |*nn| nn.* = null;
    names_buf[args.len] = "$composer";
    names_buf[args.len + 1] = "$changed";
    const r = try callMemberNamed(self, allocator, receiver, name, buf, names_buf);
    if (r == .ok) return r;
    if (r == .err and r.err != .Unimplemented) return r;
    return null;
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

/// `KLIO_MISS_TRACE` helper: dump the receiver's runtime class chain and
/// each class's declared method names, so a total miss shows whether the
/// name exists anywhere on the chain the walk should have covered.
pub fn missDumpClassChain(receiver: *const Value) void {
    if (receiver.* != .Instance) return;
    var cur: ?ObjRef(runtime.ClassDef) = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        break :blk g.get().class;
    };
    var depth: usize = 0;
    while (cur) |c| : (depth += 1) {
        if (depth > 12) break;
        const cg = c.borrow();
        const cd = cg.get();
        std.debug.print("[chain {d}] {s} methods:", .{ depth, cd.fqn });
        for (cd.methods) |m| std.debug.print(" {s}", .{m.name});
        std.debug.print(" supers:", .{});
        for (cd.supertype_names) |sn| std.debug.print(" {s}", .{sn});
        std.debug.print(" parent={}\n", .{cd.parent != null});
        const nxt = cd.parent;
        cg.deinit();
        cur = nxt;
    }
}

/// Cached hot-path trace gates: the memoized `getenvSlice` still takes a
/// lock + hashmap probe per consult; these sit on per-call dispatch paths.
var miss_trace_init: bool = false;
var miss_trace_val: ?[]const u8 = null;
fn missTraceEnv() ?[]const u8 {
    if (!miss_trace_init) {
        miss_trace_val = runtime.envOnce("KLIO_MISS_TRACE");
        miss_trace_init = true;
    }
    return miss_trace_val;
}
var nu_trace_init: bool = false;
var nu_trace_val: ?[]const u8 = null;
fn nuTraceEnv() ?[]const u8 {
    if (!nu_trace_init) {
        nu_trace_val = runtime.envOnce("KLIO_NU_TRACE");
        nu_trace_init = true;
    }
    return nu_trace_val;
}
var sam_trace_cached: ?bool = null;
fn samTraceOn() bool {
    if (sam_trace_cached) |b| return b;
    const b = runtime.envOnce("KLIO_SAM_TRACE") != null;
    sam_trace_cached = b;
    return b;
}

fn missTraceWant(name: []const u8) bool {
    const want = missTraceEnv() orelse return false;
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
    var src: [15]u8 = @splat(0xFF);
    var next_positional: usize = 0;
    for (args, 0..) |a, i| {
        const supplied: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        if (supplied) |an| {
            var placed = false;
            for (params, 0..) |pn, pos| {
                if (!std.mem.eql(u8, pn, an)) continue;
                if (slots[pos] != null) return null;
                slots[pos] = a;
                if (pos < 15) src[pos] = @intCast(@min(i, 0xFE));
                placed = true;
                break;
            }
            if (!placed) return null;
        } else {
            while (next_positional < slots.len and slots[next_positional] != null) next_positional += 1;
            if (next_positional >= slots.len) return null;
            slots[next_positional] = a;
            if (next_positional < 15) src[next_positional] = @intCast(@min(i, 0xFE));
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
    // The reorder is a pure function of (class, name, arg shape, name
    // vector); memoize it so later calls of this shape rewrite to a
    // POSITIONAL dispatch up front and skip the whole named ladder
    // (the stdlib named probes, the per-call param-name walk, and this
    // slot binding).
    if (params.len <= 15 and args.len == params.len and args.len <= 15) {
        if (namedOrderKey(self, receiver, name, args, arg_names)) |k| {
            const perm = root_mod.ProgramImage.NamedPerm{ .n = @intCast(params.len), .src = src };
            {
                const pg = self.prog.borrowMut();
                defer pg.deinit();
                pg.get().named_perm_cache.put(k, perm) catch {};
            }
            tl_perm_cache[tlSlot(k)] = .{ .class_p = k.class_p, .name_p = k.name_p, .n_args = k.n_args, .sig = k.sig, .raw_plus = 1, .gen = cacheGen(), .perm = perm };
        }
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
            // A binding that declares itself inapplicable to this call shape
            // (a property getter handed arguments) is not the target; keep
            // walking so the library extension of the same name binds.
            if (stdlib.implementationApplicable(p, args)) |applies| {
                if (!applies) continue;
            }
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
        .IrClosure, .Intrinsic => true,
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
        return .{ .ok = try Value.newList(allocator, .{
            .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
            .mutable = false,
            .enum_entries = true,
            .backing = null,
        }) };
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
            // A SAM method declared with `context(A, …)` parameters passes
            // each context, resolved from the call site's context scope, as
            // a leading argument of the wrapped callable (kotlinc's adapted
            // reference `valueParamFun(a: A, i: String)` for
            // `context(i: A) fun accept(s: String)`).
            var with_ctx: std.ArrayList(Value) = .empty;
            defer with_ctx.deinit(allocator);
            const call_args: []const Value = blk: {
                const ctx_types = samMemberCtxTypes(self, cls_name, name) orelse break :blk args;
                var it = std.mem.splitScalar(u8, ctx_types, '|');
                while (it.next()) |ty| {
                    if (ty.len == 0) continue;
                    const v = self.ctxResolve(ty, false) orelse break :blk args;
                    try with_ctx.append(allocator, v);
                }
                try with_ctx.appendSlice(allocator, args);
                break :blk with_ctx.items;
            };
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
                        return try host_call_value.callValueWithThis(self, allocator, &t, &e.v, call_args, &.{});
                    }
                }
            }
            return try callValueRec(self, allocator, &t, call_args);
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

/// A member EXTENSION declared by a NAMED class on the enclosing receiver
/// tower (`class T { private fun List<Annotation>.getCustom() = … }`). The
/// lowerer binds such a call statically when it can name the receiver's type;
/// when the receiver's static type is unknown — a property read whose declared
/// type comes from another module — the call arrives here instead, and without
/// this tail it reports a member miss on the builtin receiver.
fn enclosingNamedMemberExtDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const mptr: *const Module = self.module.asPtr();
    const candidates = mptr.funcsBySimpleName(name);
    if (candidates.len == 0) return null;
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    if (entries.len == 0) return null;
    for (entries) |e| {
        if (e.v != .Instance) continue;
        var cls_name: []const u8 = undefined;
        var cls_fqn: []const u8 = undefined;
        {
            const g = e.v.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            cls_name = cg.get().name;
            cls_fqn = cg.get().fqn;
        }
        for (candidates) |fid| {
            const owner = mptr.registry.member_ext_owner_class.get(fid) orelse continue;
            if (!std.mem.eql(u8, owner, cls_name) and !std.mem.eql(u8, owner, cls_fqn)) continue;
            const f = mptr.funcById(fid) orelse continue;
            if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
            if (f.params.len - 1 != args.len) continue;
            if (!receiverImplementsType(self, receiver, f.params[0].ty.name)) continue;
            const all = try prependReceiver(allocator, receiver, args);
            defer if (runtime.freeScratch()) allocator.free(all);
            ir.eval.pushEnclosing(&e.v);
            defer ir.eval.popEnclosing();
            return try callFuncRec(self, allocator, mptr, fid, all);
        }
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
fn samMemberCtxTypes(self: *VmHost, cls: []const u8, name: []const u8) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    return mg.get().registry.iface_member_ctx_types.get(.{ .a = cls, .b = name });
}
fn samMemberExtRecvType(self: *VmHost, cls: []const u8, name: []const u8) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    return mg.get().registry.iface_member_ext_recv.get(.{ .a = cls, .b = name });
}

/// A `receiver::member` reference is carried as a synthetic Instance holding
/// the captured receiver and the member name.
fn isBoundReference(receiver: *const Value) bool {
    if (receiver.* != .Instance) return false;
    const g = receiver.Instance.borrow();
    defer g.deinit();
    return g.get().get("__bound_receiver__") != null and g.get().get("__bound_name__") != null;
}

fn boundRefDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var rc: ?Value = null;
    var n_str: ?[]const u8 = null;
    var exact_func: ?FuncId = null;
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
        if (g.get().get("__bound_func__")) |fv| {
            if (fv == .Int and fv.Int >= 0) exact_func = FuncId.from(@intCast(fv.Int));
        }
        g.deinit();
    }
    if (rc == null or n_str == null) return null;
    const recv_capt = rc.?;
    const n = n_str.?;
    if (std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "simpleName")) {
        return null; // handled by get_field
    }
    // `KMutableProperty.set` / `KProperty.get`: an UNBOUND property
    // reference (`T::prop`, captured receiver = the class) takes the target
    // first; a bound one uses the captured receiver.
    if (std.mem.eql(u8, name, "set") or std.mem.eql(u8, name, "get")) {
        // Arity decides bound vs unbound: `T::prop` captures the CLASS (or
        // its companion stand-in) and takes the target first; `x::prop`
        // captures the instance. `set` is 2 args unbound / 1 bound; `get`
        // is 1 / 0.
        if (std.mem.eql(u8, name, "set")) {
            if (args.len == 2) {
                switch (try host_fields.setField(self, allocator, &args[0], n, args[1])) {
                    .ok => return .{ .ok = .Unit },
                    .err => |e| return .{ .err = e },
                }
            }
            if (args.len == 1 and recv_capt != .Class) {
                switch (try host_fields.setField(self, allocator, &recv_capt, n, args[0])) {
                    .ok => return .{ .ok = .Unit },
                    .err => |e| return .{ .err = e },
                }
            }
        } else {
            if (args.len == 1) {
                return try host_fields.getField(self, allocator, &args[0], n);
            }
            if (args.len == 0 and recv_capt != .Class) {
                return try host_fields.getField(self, allocator, &recv_capt, n);
            }
        }
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
    if (exact_func) |func| {
        if (std.mem.eql(u8, name, "invoke") or std.mem.eql(u8, name, "call")) {
            var exact_args: std.ArrayList(Value) = .empty;
            defer exact_args.deinit(allocator);
            if (recv_capt == .Class) {
                try exact_args.appendSlice(allocator, args);
            } else {
                try exact_args.append(allocator, recv_capt);
                try exact_args.appendSlice(allocator, args);
            }
            const mg = self.module.borrow();
            defer mg.deinit();
            return try host_call_func.callFunc(
                self,
                allocator,
                mg.get(),
                func,
                exact_args.items,
            );
        }
    }
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
    // An EXTENSION declared on a function type serves the reference itself,
    // not the member it names: `source::produce` is a `() -> Int`, so
    // `.asFlow()` on it is `(() -> T).asFlow()`. Forwarding every unknown
    // name to the bound member turned that into `produce()`'s value. Decline
    // so the ordinary member/extension walk runs; `invoke`/`call` are the
    // reference's own surface and keep forwarding.
    if (!std.mem.eql(u8, name, "invoke") and !std.mem.eql(u8, name, "call") and
        extWithThisLongerThanArgs(self, name, args.len)) return null;
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
                .IrClosure => return try callValueRec(self, allocator, &callable, args),
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
            .IrClosure => true,
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

pub fn isIteratorNext(name: []const u8) bool {
    const ns = [_][]const u8{ "next", "nextInt", "nextLong", "nextChar", "nextByte", "nextShort", "nextDouble", "nextFloat", "nextBoolean" };
    for (ns) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

pub fn funcAt(module: *const Module, fid: FuncId) ?Func {
    return if (module.funcById(fid)) |f| f.* else null;
}

fn argsListFromSlice(allocator: Allocator, slice: []const Value) Allocator.Error!std.ArrayList(Value) {
    var l = try ir.eval.acquireArgsCap(allocator, slice.len);
    l.appendSliceAssumeCapacity(slice);
    return l;
}

fn anonMethodDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var class_name: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        class_name = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ name, args.len });
    // Scratch lookup key (lookupAnonMethod dupes what it stores); free it.
    defer if (runtime.freeScratch()) allocator.free(arity_name);
    if (missTraceEnv()) |want| if (std.mem.eql(u8, want, name)) {
        const hit0 = lookupAnonMethod(self, allocator, class_name, arity_name, name);
        std.debug.print("[anon-disp] name={s} class={s} hit={} dis={}\n", .{ name, class_name, hit0 != null, if (hit0) |h| anonMethodDisproven(self, h, args) else false });
    };

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
        // A type-variable-typed param (the method's own, or one inherited
        // from the object expression's enclosing declaration) never names a
        // nominal class; adjudicating it as one would let an unrelated
        // registered class of the same simple name refute valid arguments.
        if (fidTypeVar(self, f.id, &effective[i].ty)) continue;
        // A LOCAL class's own type parameter (`Target` in a function-body
        // `class PropertyAndItsValue<Target, Value>`) is registered on the
        // synthesized ClassDef, not the method fid; reading it as a nominal
        // class refuted every argument (`set(target: Target)` missed).
        if (localClassTypeParam(self, f, &effective[i].ty)) continue;
        if (argDefinitelyNotParamType(self, &effective[i].ty, &args[i])) return true;
    }
    return false;
}

fn localClassTypeParam(self: *VmHost, f: *const ir.Func, ty: *const ir.TypeRef) bool {
    const head = std.mem.trimEnd(u8, simpleName(ty.name), "?");
    if (head.len == 0) return false;
    // A runtime-lowered local-class member's params[0] is `this`, typed by
    // the class; that names the ClassDef holding the declared type params.
    if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) return false;
    const cls_name = std.mem.trimEnd(u8, f.params[0].ty.name, "?");
    const cg = self.classes.borrow();
    defer cg.deinit();
    const def = cg.get().get(cls_name) orelse return false;
    const dg = def.borrow();
    defer dg.deinit();
    for (dg.get().type_params) |tp| {
        if (std.mem.eql(u8, tp, head)) return true;
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
    if (tbl.get().count() == 0) return null;
    // Probe keys live in a stack buffer — this runs per dynamic dispatch, and
    // the old per-probe allocPrint pair was measurable in the profile. The
    // heap fallback covers pathological name lengths.
    var kb: [256]u8 = undefined;
    if (std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ class_name, arity_name })) |ak| {
        if (tbl.get().get(ak)) |e| return e;
    } else |_| {
        const ak = anonKey(allocator, class_name, arity_name) catch return null;
        defer allocator.free(ak);
        if (tbl.get().get(ak)) |e| return e;
    }
    if (std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ class_name, name })) |pk| {
        if (tbl.get().get(pk)) |e| return e;
    } else |_| {
        const pk = anonKey(allocator, class_name, name) catch return null;
        defer allocator.free(pk);
        if (tbl.get().get(pk)) |e| return e;
    }
    return null;
}

/// Exact anonymous/local-class method lookup used while linking a numeric
/// virtual slot. Unlike the legacy named-member path, this never falls back to
/// the arity-agnostic key.
fn lookupAnonMethodExact(self: *VmHost, allocator: Allocator, class_name: []const u8, arity_name: []const u8) ?AnonMethodEntry {
    const tbl = self.anon_methods.borrow();
    defer tbl.deinit();
    if (tbl.get().count() == 0) return null;
    var kb: [256]u8 = undefined;
    if (std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ class_name, arity_name })) |key| {
        return tbl.get().get(key);
    } else |_| {}
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

    // Scalar-replay leaf on the anon/companion method (receiver rides as
    // opaque param 0); a bail falls through to the framed invoke, which
    // re-runs the pure body exactly. The gate takes the MODULE'S Func
    // record, not the local copy — the leaf_route memo written through a
    // copy is discarded, re-pricing every companion dispatch with the
    // registry mutex + fqn lookup the memo exists to kill.
    if (receiver.* != .Null and all.items.len == f.params.len) {
        const lfp = module_rc.funcById(hit.func) orelse unreachable;
        if (try ir.eval.tryLeafValues(VmHost, allocator, module_rc, lfp, all.items, self, null)) |lo| {
            all.deinit(allocator);
            switch (lo) {
                .val => |v| return .{ .ok = v },
                .raise => |e| return .{ .err = e },
            }
        }
    }

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
                const padded = try padArgsWithDefaultsFor(self, allocator, main_mod, f.params.len, all.items, defaults, f.params);
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
    return padArgsWithDefaultsFor(self, allocator, module, n_params, provided, defaults, &.{});
}
fn padArgsWithDefaultsFor(self: *VmHost, allocator: Allocator, module: *const Module, n_params: usize, provided: []const Value, defaults: ?[]const ?FuncId, params: []const ir.Param) Allocator.Error!union(enum) { ok: []Value, err: EvalError } {
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
        // An omitted vararg with no default of its own is the empty array —
        // never a placeholder the packer would take as an element.
        if (i < params.len and params[i].is_vararg and
            (defaults == null or i >= defaults.?.len or defaults.?[i] == null))
        {
            const empty: std.ArrayList(Value) = .empty;
            try call_args.append(allocator, runtime.ArrayData.fromBoxedList(try ObjRef(std.ArrayList(Value)).init(allocator, empty)));
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

/// `unambiguous` = the pick is a pure function of the RELAXED method-cache
/// key: the resolving class collected exactly one candidate, or the call's
/// arg count forced the pick among several (see `pickArityForced`) with
/// every argument relaxed-adjudicable. Gates whether a relaxed-key cache
/// entry may be stored.
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
/// Kotlin drops a member overload whose declared value-parameter types
/// PROVABLY reject the call's arguments, and a top-level extension
/// namesake binds instead: `builder.putAll(pairsArray)` inside the
/// stdlib `plusAssign` — the builder's member takes a `Map`, the stdlib
/// extension takes the `Array<out Pair>`. Only a definite per-arg
/// disproof WITH a surviving same-arity extension declines the member,
/// so erased/unknown argument shapes keep the member-first order.
fn memberArgsDisprovenExtensionApplies(self: *VmHost, mod: *const Module, name: []const u8, member: *const Func, args: []const Value) bool {
    if (!candidateArgsDisproven(self, member, args)) return false;
    for (mod.funcsBySimpleName(name)) |fid| {
        const cand = funcAt(mod, fid) orelse continue;
        if (cand.params.len != args.len + 1) continue;
        if (cand.params.len == 0 or !std.mem.eql(u8, cand.params[0].name, "this")) continue;
        if (isMemberExt(mod, fid)) continue;
        if (cand.low_priority) continue;
        if (candidateArgsDisproven(self, &cand, args)) continue;
        return true;
    }
    return false;
}

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
    const WalkItem = struct { cid: ?ir.ClassId, name: []const u8, hint: []const u8 = "" };
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
            if (classByNamePreferring(mod, item.name, item.hint)) |hit| {
                ir_class = hit.cls;
                cid_of = hit.cid;
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
    const hm = mod.registry.hierarchy_methods.get(irc.fqn) orelse
        mod.registry.hierarchy_methods.get(irc.name) orelse
        mod.registry.hierarchy_methods.get(simpleName(irc.fqn)) orelse return true;
    return hm.contains(name);
}

/// Resolve a supertype recorded by SIMPLE NAME, preferring the candidate
/// whose fqn shares the longest dotted prefix with `hint_fqn` — the class
/// that recorded the name. Two packs both declare a `Segment`
/// (kotlinx.coroutines.internal and kotlinx.io); `ChannelSegment`'s parent
/// is the one beside it, and first-match-wins walked the wrong hierarchy.
const ClassByNameHit = struct { cls: ir.Class, cid: ir.ClassId };

fn classByNamePreferring(mod: *const Module, want: []const u8, hint_fqn: []const u8) ?ClassByNameHit {
    var best: ?ClassByNameHit = null;
    var best_score: usize = 0;
    for (mod.classes.items, 0..) |c, i| {
        if (!std.mem.eql(u8, c.name, want)) continue;
        var score: usize = 0;
        const n = @min(c.fqn.len, hint_fqn.len);
        while (score < n and c.fqn[score] == hint_fqn[score]) : (score += 1) {}
        if (best == null or score > best_score) {
            best = .{ .cls = c, .cid = @enumFromInt(i) };
            best_score = score;
        }
    }
    return best;
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
        // An interface's ABSTRACT member lowers no method fid, but its
        // declared header is registered — without this, a runtime override
        // of `operator fun <T> get(key: Key<T>)` on an interface-typed
        // receiver was excluded as a subtype-only generic and the walk fell
        // through to a delegated `Map.get` (the CompositionLocalMap read).
        for (mod.memberDecls(irc.fqn, name)) |fid| {
            if (funcTypeParamCount(self, fid) == tvc) return true;
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
    // The best fit found so far that needed DEFAULTS to bind; used only when
    // the walk finds no exact-arity candidate anywhere in the hierarchy.
    var defaulted_hit: ?ResolvedMethod = null;
    const WalkItem = struct { cid: ?ir.ClassId, name: []const u8, hint: []const u8 = "" };
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
                if (classByNamePreferring(mod, cur_name, item.hint)) |hit| {
                    ir_class = hit.cls;
                }
            }
            // Dedup on the resolved class's FQN (identity) so two distinct
            // classes that share a simple name are each walked once.
            const dedup_key = if (ir_class) |irc| irc.fqn else cur_name;
            if (seen.contains(dedup_key)) continue;
            try seen.put(dedup_key, {});
            if (ir_class) |irc| {
                cur_name = irc.name;
                if (missTraceWant(name)) {
                    var matched: usize = 0;
                    for (irc.methods) |fid| {
                        if (funcAt(mod, fid)) |f| {
                            if (std.mem.eql(u8, f.name, name)) matched += 1;
                        }
                    }
                    std.debug.print("[rim] class={s} cid={?} methods={d} named={d} static_recv={s} static_up_ready={} in_up={}\n", .{
                        irc.fqn,
                        if (item.cid) |c| c.int() else null,
                        irc.methods.len,
                        matched,
                        static_recv orelse "-",
                        static_up_ready,
                        static_up.contains(irc.fqn),
                    });
                }
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
                            if (classTypeParamRefutes(self, mod, irc.fqn, &f, args)) continue;
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
                if (missTraceWant(name)) {
                    std.debug.print("[rim2] class={s} collected={d} picked={} args={d}\n", .{
                        irc.fqn,
                        candidates.items.len,
                        pickMethodOverload(self, mod, candidates.items, args) != null,
                        args.len,
                    });
                }
                if (pickMethodOverload(self, mod, candidates.items, args)) |f| {
                    if (!callableArgPrefersFunctionExtension(self, mod, name, &f, receiver, args) and
                        !memberArgsDisprovenExtensionApplies(self, mod, name, &f, args))
                    {
                        const hit = ResolvedMethod{ .fid = f.id, .unambiguous = candidates.items.len == 1 or
                            (pickArityForced(self, candidates.items, args.len) and argsRelaxedAdjudicable(args)) };
                        // Kotlin resolves against the WHOLE member scope, and a
                        // candidate that binds without defaults is more specific
                        // than one that needs them. A fit leaning on defaults
                        // therefore cannot commit here — a supertype may declare
                        // the exact-arity overload (`WithTime.secondFraction(
                        // fixedLength)` under `AbstractWithTimeBuilder`'s
                        // `secondFraction(minLength, maxLength)`, where a
                        // one-argument call otherwise filled `maxLength` from its
                        // default). Keep the FIRST such fit so an override still
                        // outranks the base it overrides, and let the walk look
                        // for an exact one.
                        if (methodBindsWithoutDefaults(&f, args.len)) return hit;
                        if (defaulted_hit == null) defaulted_hit = hit;
                    }
                }
                // Enqueue the resolved supertypes by identity (their IR class
                // ids) so the inherited-method walk follows the real class
                // hierarchy, never a same-simple-name impostor.
                for (irc.supertypes) |sid| {
                    if (@intFromEnum(sid) < mod.classes.items.len) {
                        try queue.append(allocator, .{ .cid = sid, .name = mod.classes.items[@intFromEnum(sid)].name });
                    }
                }
                // A pack shim class's cross-root supertype ids can be
                // unresolved at load (ktor's KlioApplicationResponse :
                // BaseApplicationResponse walked as a leaf, so the inherited
                // `status` overloads were invisible). The registry's
                // name-chain evidence still records the declared parents —
                // continue the walk by name when identity resolution
                // recorded none.
                if (irc.supertypes.len == 0) {
                    const chain: []const []const u8 =
                        mod.registry.class_super_names.get(irc.fqn) orelse
                        mod.registry.class_super_names.get(irc.name) orelse &.{};
                    for (chain) |sup| {
                        try queue.append(allocator, .{ .cid = null, .name = sup, .hint = irc.fqn });
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
                for (dg.get().supertype_names) |sup| try queue.append(allocator, .{ .cid = null, .name = sup, .hint = dg.get().fqn });
                dg.deinit();
            }
            cg.deinit();
        }
    }
    return defaulted_hit;
}

/// Whether `f` binds a call of `argc` arguments with every parameter supplied
/// — no default filled, no vararg absorbing the tail. Kotlin ranks such a
/// candidate above one that needs either.
fn methodBindsWithoutDefaults(f: *const Func, argc: usize) bool {
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    if (f.params.len - skip != argc) return false;
    for (f.params[skip..]) |*p| {
        if (p.is_vararg) return false;
    }
    return true;
}

/// See the candidate loop in `resolveInstanceMethod`: whether a declared
/// param typed as one of `class_name`'s type parameters has a recorded
/// upper bound the runtime argument DEFINITIVELY refutes. Positive-proof
/// only — an unknown/incomplete relation never refutes.
fn classTypeParamRefutes(self: *VmHost, mod: *const Module, class_name: []const u8, f: *const Func, args: []const Value) bool {
    const bounds = mod.registry.class_type_param_bounds.get(class_name) orelse return false;
    const sig = mod.decl_sigs.get(f.id.int()) orelse return false;
    const owner = sig.enclosing_class orelse return false;
    const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    if (f.params.len <= recv_off) return false;
    for (f.params[recv_off..], 0..) |*p, i| {
        if (i >= args.len) break;
        const identity = ir.parseClassTypeParamIdentity(
            std.mem.trimEnd(u8, p.ty.name, "?"),
        ) orelse continue;
        if (identity.owner.int() != owner.int()) continue;
        for (bounds) |b| {
            if (!std.mem.eql(u8, b.param, identity.param)) continue;
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
            const decidable = switch (arg.*) {
                .Null, .IrClosure, .Intrinsic, .BoundMethod => false,
                else => true,
            };
            if (decidable and !receiverImplementsHead(self, arg, bn)) return true;
        }
    }
    return false;
}

/// Invoke an already-resolved user method by `FuncId`: prepend the receiver,
/// pad defaults, pack varargs, and run the body. Shared by the cold resolve
/// path (`irMethodWalk`) and the inline-cache fast path.
/// Direct dispatch to a lowering-resolved member target
/// (`Inst.CallMember.resolved`): invoke `fid` on `receiver` with no name
/// resolution, applicability walk, or FQN scan. Missing targets are image/link
/// errors and remain errors rather than changing the declaration selected by
/// lowering.
fn typeHeadLast(s: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, s, "?");
    if (std.mem.lastIndexOfScalar(u8, t, '.')) |d| return t[d + 1 ..];
    return t;
}

pub fn invokeResolvedMember(
    self: *VmHost,
    allocator: Allocator,
    dispatch_receiver: ?*const Value,
    receiver: *const Value,
    fid: FuncId,
    args: []const Value,
    arg_names: []const ?[]const u8,
) Allocator.Error!EvalResult {
    // Lowering resolves a member the receiver's class does not declare to the
    // implementation it inherits — for a `by`-delegated interface that is the
    // interface's own default body, but Kotlin routes it to the delegate. The
    // static identity is only correct for a class that actually inherits the
    // member, so re-decide it here for a delegating receiver.
    if (receiver.* == .Instance) {
        if (resolvedMemberName(self, fid)) |name| {
            if (interfaceDelegateFor(self, allocator, receiver.Instance, name)) |d| {
                const r = try callMemberRec(self, allocator, &d, name, args);
                switch (r) {
                    .ok => return r,
                    .err => |e| if (e != .Unimplemented) return r else freeDispatchMiss(allocator, r),
                }
            }
        }
    }
    // A member-extension needs its declaring class's `this` seeded as an
    // enclosing receiver before the body runs; a plain member binds
    // `[receiver] ++ args` directly.
    const is_member_ext = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk isMemberExt(mg.get(), fid);
    };
    // NAMED arguments must bind by parameter name — the positional invokers
    // below would walk them into a vararg (`assertLines("12345", limit = 5)`
    // stringified the limit into the vararg and kept the default).
    var any_named = false;
    for (arg_names) |n| {
        if (n != null) any_named = true;
    }
    if (any_named) {
        const all = try prependReceiver(allocator, receiver, args);
        defer if (runtime.freeScratch()) allocator.free(all);
        const names = try allocator.alloc(?[]const u8, arg_names.len + 1);
        defer if (runtime.freeScratch()) allocator.free(names);
        names[0] = null;
        @memcpy(names[1..], arg_names);
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (funcAt(mod, fid) == null) {
            return .{ .err = .{ .Type = "resolved member target is missing" } };
        }
        if (is_member_ext) {
            const dispatch = dispatch_receiver orelse return .{
                .err = .{ .Type = "resolved member extension is missing its dispatch receiver" },
            };
            ir.eval.pushEnclosing(dispatch);
            defer ir.eval.popEnclosing();
            return try callFuncNamedRec(self, allocator, mod, fid, all, names);
        }
        return try callFuncNamedRec(self, allocator, mod, fid, all, names);
    }
    if (is_member_ext) {
        const dispatch = dispatch_receiver orelse return .{
            .err = .{ .Type = "resolved member extension is missing its dispatch receiver" },
        };
        return invokeMemberExtFuncId(
            self,
            allocator,
            dispatch,
            receiver,
            fid,
            args,
        );
    }
    return (try invokeMethodFuncId(self, allocator, receiver, fid, args)) orelse
        .{ .err = .{ .Type = "resolved member target is not executable" } };
}

/// Compile-time resolver for the loop JIT's virtual inline sites: the
/// FuncId the slot dispatches to on `receiver`'s class, via the same
/// resolved-id memo + main-module slot table the runtime path reads — with
/// NO fallback arms (an anonymous class, a host-backed member, an unlinked
/// or bodyless target all return null, so the site stays a trampoline and
/// runtime behavior is unchanged). The only state touched is the class's
/// own resolve memo, which the runtime path fills identically.
pub fn resolveVirtualFuncId(self: *VmHost, receiver: *const Value, slot: ir.MethodSlotId) ?FuncId {
    if (receiver.* != .Instance) return null;
    const runtime_def = blk: {
        const instance = receiver.Instance.borrow();
        defer instance.deinit();
        break :blk instance.get().class.clone();
    };
    defer runtime_def.deinit();
    {
        const class = runtime_def.borrow();
        defer class.deinit();
        if (class.get().is_anonymous) return null;
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    const memo_class_id: ?ir.ClassId = cid: {
        const class = runtime_def.borrow();
        defer class.deinit();
        const cdef = class.get();
        const mod_key = @intFromPtr(module);
        if (cdef.resolve_mod.load(.monotonic) == mod_key) {
            const plus1 = cdef.resolve_cid.load(.acquire);
            if (plus1 != 0) break :cid ir.ClassId.from(plus1 - 1);
        }
        const found = module.classIdByFqn(cdef.fqn) orelse break :cid null;
        const mut = @constCast(cdef);
        if (mut.resolve_mod.cmpxchgStrong(0, mod_key, .acq_rel, .monotonic) == null) {
            mut.resolve_cid.store(found.int() + 1, .release);
        }
        break :cid found;
    };
    const cls = memo_class_id orelse return null;
    const target = module.methodSlotTarget(cls, slot) orelse return null;
    if (!virtualTargetExecutable(module, target)) return null;
    return target;
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
    // Two same-arity overrides of one name share the arity key and only the
    // last is reachable through it. Walk the indexed keys first and take the
    // one whose parameter types are the slot root's; the arity key is the
    // answer when the family has just one member.
    const hit = blk: {
        var index: usize = 0;
        while (true) : (index += 1) {
            const member = root_mod.anonOverloadMemberName(allocator, arity_name, index) catch break;
            defer if (runtime.freeScratch()) allocator.free(member);
            const candidate_hit = lookupAnonMethodExact(self, allocator, class_name, member) orelse break;
            const cg = candidate_hit.module.borrow();
            defer cg.deinit();
            const cf = funcAt(cg.get(), candidate_hit.func) orelse continue;
            if (root_mod.anonParamsMatch(cf.params, root_func.params)) break :blk candidate_hit;
        }
        break :blk lookupAnonMethodExact(self, allocator, class_name, arity_name) orelse return null;
    };
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

/// Name the slot family, receiver, and live frame chain when a virtual call
/// finds no target for its receiver class. Gated on `KLIO_ERR_TRACE`, like the
/// non-instance receiver diagnostic above: the bare error says a slot is
/// unlinked but not which method or on what, which is the whole question.
fn virtualSlotUnlinkedDiag(
    module: *const Module,
    slot: MethodSlotId,
    recv_fqn: []const u8,
    nargs: usize,
    which: []const u8,
) void {
    if (runtime.envOnce("KLIO_ERR_TRACE") == null) return;
    const root = FuncId.from(slot.int());
    const mname: []const u8 = if (module.funcById(root)) |f| f.fqn else "?";
    std.debug.print(
        "[vslot-unlinked] {s} slot={d} method={s} recv={s} nargs={d}\n",
        .{ which, slot.int(), mname, recv_fqn, nargs },
    );
    // Name the executing overload: same-named siblings (the FunctionN `invoke`
    // family) are indistinguishable in the frame chain, and which one is running
    // is exactly what identifies a misbound receiver.
    if (ir.eval.currentFrameFunc()) |cf| {
        std.debug.print("[vslot-unlinked]   in {s} params=[", .{cf.fqn});
        for (cf.params) |p| std.debug.print("{s} ", .{p.name});
        std.debug.print("]\n", .{});
    }
    ir.eval.dumpFrameChainForDiagAlways();
}

/// `KLIO_NOINST_TRACE=1`: report each virtual slot resolved against the runtime
/// class of a host-backed (non-`Instance`) receiver. Resolved once — this sits
/// on the member-dispatch path, where the env cache's mutex would show up.
/// Counts every time a STATICALLY BOUND virtual slot call degrades to a
/// by-name member walk. `execArmCallVirtual` documents that arm as having no
/// name-based fallback — "a missing slot is a link error in the program
/// image" — and this host has one. Both cannot be true, and a bytecode VM or
/// a C backend needs the unlinked slot to be a build error rather than a
/// walk. Counting it is the prerequisite for making that so.
var slot_by_name_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn slotByNameFallbacks() u64 {
    return slot_by_name_count.load(.monotonic);
}

/// A builtin member whose implementation is a host function reached by
/// RECEIVER VARIANT rather than by FQN, so `linkBodyless` finds no native for
/// it and a statically bound slot call declines to a member-name walk
/// (`KLIO_NOINST_WHY` reports `target-not-executable`). Binding the target
/// `FuncId` to the handler settles the call by id instead.
///
/// The FQN comparison happens ONCE per `FuncId` per thread; every later call
/// on that slot is an integer probe. The handlers are the existing ones — a
/// second implementation here is exactly the duplication this avoids.
const HostSlotOp = enum {
    iterator_protocol,
    collection_iterator,
    kclass_is_instance,
    comparator_member,
    array_get,
    sequence_iterator,
};

threadlocal var host_slot_ops: ?std.AutoHashMapUnmanaged(u32, ?HostSlotOp) = null;

fn hostSlotOpFor(module: *const Module, target: FuncId) ?HostSlotOp {
    if (host_slot_ops == null) host_slot_ops = .{};
    const map = &host_slot_ops.?;
    if (map.get(target.int())) |cached| return cached;
    const fqn = if (module.funcById(target)) |f| f.fqn else return null;
    const op: ?HostSlotOp = blk: {
        const owner = fqn[0 .. std.mem.lastIndexOfScalar(u8, fqn, '.') orelse break :blk null];
        const name = fqn[owner.len + 1 ..];
        const iter_owner = std.mem.eql(u8, owner, "kotlin.collections.Iterator") or
            std.mem.eql(u8, owner, "kotlin.collections.MutableIterator") or
            std.mem.eql(u8, owner, "kotlin.collections.ListIterator") or
            std.mem.eql(u8, owner, "kotlin.collections.MutableListIterator") or
            // The primitive-iterator abstract classes: their `next()` source
            // body delegates to `nextInt()`-family members the host serves
            // through the same protocol handler.
            (std.mem.startsWith(u8, owner, "kotlin.collections.") and
                std.mem.endsWith(u8, owner, "Iterator"));
        if (iter_owner and (isIteratorProtocol(name) or isIteratorNext(name)))
            break :blk .iterator_protocol;
        // `iterator()` on a collection: the host builds the iterator from the
        // receiver's own representation, and no native is registered under
        // the interface's FQN either.
        if (std.mem.eql(u8, name, "iterator") and
            (std.mem.eql(u8, owner, "kotlin.collections.Iterable") or
                std.mem.eql(u8, owner, "kotlin.collections.MutableIterable") or
                std.mem.eql(u8, owner, "kotlin.collections.Collection") or
                std.mem.eql(u8, owner, "kotlin.collections.MutableCollection") or
                std.mem.eql(u8, owner, "kotlin.collections.List") or
                std.mem.eql(u8, owner, "kotlin.collections.MutableList") or
                std.mem.eql(u8, owner, "kotlin.collections.Set") or
                std.mem.eql(u8, owner, "kotlin.collections.MutableSet") or
                std.mem.eql(u8, owner, "kotlin.collections.ArrayList") or
                std.mem.eql(u8, owner, "kotlin.collections.HashSet") or
                std.mem.eql(u8, owner, "kotlin.collections.LinkedHashSet")))
            break :blk .collection_iterator;
        // The remaining interface members the host serves from the value's
        // own representation, measured off the noinst-why decline tally:
        // KClass.isInstance, Comparator.compare, indexed array get, and a
        // Sequence's lazy iterator.
        if (std.mem.eql(u8, owner, "kotlin.reflect.KClass") and
            std.mem.eql(u8, name, "isInstance")) break :blk .kclass_is_instance;
        if (std.mem.eql(u8, owner, "kotlin.Comparator") and
            std.mem.eql(u8, name, "compare")) break :blk .comparator_member;
        if (std.mem.eql(u8, name, "get") and
            std.mem.startsWith(u8, owner, "kotlin.") and
            std.mem.endsWith(u8, owner, "Array") and
            std.mem.indexOfScalar(u8, owner["kotlin.".len..], '.') == null)
            break :blk .array_get;
        if (std.mem.eql(u8, owner, "kotlin.sequences.Sequence") and
            std.mem.eql(u8, name, "iterator")) break :blk .sequence_iterator;
        break :blk null;
    };
    map.put(std.heap.page_allocator, target.int(), op) catch return op;
    return op;
}

fn runHostSlotOp(self: *VmHost, allocator: Allocator, op: HostSlotOp, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    switch (op) {
        .iterator_protocol => switch (receiver.*) {
            .Iterator => return iteratorMember(self, allocator, receiver, name, args),
            .RangeIter => return rangeIterMember(self, allocator, receiver, name, args),
            .SeqIter => return seqIterMember(self, allocator, receiver, name, args),
            else => return null,
        },
        .collection_iterator => {
            if (args.len != 0) return null;
            // The self-iterator convention first, exactly as the named path
            // applies it, then the builtin collection/range iterator.
            switch (receiver.*) {
                .Iterator, .RangeIter, .SeqIter => return .{ .ok = receiver.* },
                else => {},
            }
            return builtinIterator(self, allocator, receiver);
        },
        .kclass_is_instance => {
            if (receiver.* != .Class or args.len != 1) return null;
            const cg = receiver.Class.borrow();
            const cname = cg.get().name;
            var hit = args[0].isRuntimeType(cname);
            if (!hit and args[0] == .Instance) hit = receiverImplementsType(self, &args[0], cname);
            const r = boolVal(hit);
            cg.deinit();
            return .{ .ok = r };
        },
        .comparator_member => switch (receiver.*) {
            .Comparator => return comparatorMember(self, allocator, receiver, name, args),
            else => return null,
        },
        .array_get => {
            if (receiver.* != .Array or args.len != 1) return null;
            const idx = args[0].asI64() orelse return null;
            const arr = receiver.Array;
            const n = arr.len();
            if (idx >= 0 and @as(usize, @intCast(idx)) < n) {
                const elem = arr.get(@intCast(idx));
                elem.retain();
                return .{ .ok = elem };
            }
            const msg = try std.fmt.allocPrint(allocator, "Index {d} out of bounds for length {d}", .{ idx, n });
            defer if (runtime.freeScratch()) allocator.free(msg);
            return .{ .err = try throwExc(allocator, "kotlin.ArrayIndexOutOfBoundsException", msg) };
        },
        .sequence_iterator => switch (receiver.*) {
            .Sequence => return sequenceMember(self, allocator, receiver, name, args),
            else => return null,
        },
    }
}

/// Names the builtin iterator variants own outright.
fn isIteratorProtocol(name: []const u8) bool {
    return std.mem.eql(u8, name, "hasNext") or std.mem.eql(u8, name, "next") or
        std.mem.eql(u8, name, "hasPrevious") or std.mem.eql(u8, name, "previous") or
        std.mem.eql(u8, name, "nextIndex") or std.mem.eql(u8, name, "previousIndex");
}

fn noteSlotByName2(self: *VmHost, slot: MethodSlotId, name: []const u8, receiver: *const Value) void {
    _ = slot_by_name_count.fetchAdd(1, .monotonic);
    if (!runtime.envSetOnce("KLIO_SLOT_BYNAME")) return;
    if (runtime.envOnce("KLIO_SLOT_RECV") != null) {
        std.debug.print("[slot-recv] {s} recv_ty={s}\n", .{ name, receiver.typeFqn() });
        return;
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    const root = FuncId.from(slot.int());
    std.debug.print("[slot-byname] {s} root={s}\n", .{
        name,
        if (mg.get().funcById(root)) |f| f.fqn else "?",
    });
}

/// A value that IS its own representation — no host wrapper for the by-name
/// walk to unpack on the way in.
fn isScalarValue(v: *const Value) bool {
    return switch (v.*) {
        .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float, .Bool, .Char => true,
        else => false,
    };
}


fn noinstTraceOn() bool {
    const S = struct {
        var known: ?bool = null;
    };
    if (S.known) |k| return k;
    const k = runtime.envSetOnce("KLIO_NOINST_TRACE");
    S.known = k;
    return k;
}

/// Invoke a statically resolved virtual family by numeric slot. The runtime
/// receiver contributes its exact class identity; named and runtime-defined
/// classes both resolve to an O(1) `(class, slot)` target.
/// kotlinc's type-safe collection bridges, by member name. A generic
/// collection member called through an erased signature (`indexOf(Object)`)
/// checks the argument against the class type parameter's bound and answers
/// a fixed default for a foreign value instead of running the body against a
/// representation the value does not have. The member set and defaults are
/// kotlinc's BuiltinSpecialBridges.
const BarrierKind = enum { bool_false, int_neg1, null_or_false, second_arg };

fn barrierSpec(name: []const u8) ?BarrierKind {
    const eql = std.mem.eql;
    if (eql(u8, name, "contains") or eql(u8, name, "containsKey") or
        eql(u8, name, "containsValue")) return .bool_false;
    if (eql(u8, name, "indexOf") or eql(u8, name, "lastIndexOf")) return .int_neg1;
    if (eql(u8, name, "get") or eql(u8, name, "remove")) return .null_or_false;
    if (eql(u8, name, "getOrDefault")) return .second_arg;
    return null;
}

/// The bridge's answer when the first argument fails the class type
/// parameter's erased-bound check, or null when the bridge admits the call
/// (no tp-typed param, no bound, or the value passes `is Bound`).
fn typeSafeBarrierAnswer(
    self: *VmHost,
    module: *const ir.Module,
    target: FuncId,
    kind: BarrierKind,
    args: []const Value,
) ?Value {
    const btr = runtime.envOnce("KLIO_BARRIER_TRACE") != null;
    if (args.len == 0) return null;
    const f = module.funcById(target) orelse return null;
    const sig = module.decl_sigs.get(target.int()) orelse return null;
    if (!sig.has_body) return null;
    const owner = sig.enclosing_class orelse {
        if (btr) std.debug.print("[barrier] {s}: no owner\n", .{f.name});
        return null;
    };
    if (owner.int() >= module.classes.items.len) return null;
    const cls = &module.classes.items[owner.int()];
    const has_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
    const pi: usize = @intFromBool(has_this);
    if (pi >= f.params.len) return null;
    const pty_name = f.params[pi].ty.name;
    var tp_name: []const u8 = undefined;
    if (ir.parseClassTypeParamIdentity(pty_name)) |identity| {
        if (identity.owner.int() != owner.int()) {
            if (btr) std.debug.print("[barrier] {s}: mangle owner {d} != {d}\n", .{ f.name, identity.owner.int(), owner.int() });
            return null;
        }
        tp_name = identity.param;
    } else {
        var declared = false;
        for (cls.type_params) |tp| {
            if (std.mem.eql(u8, tp, pty_name)) {
                declared = true;
                break;
            }
        }
        if (!declared) {
            if (btr) std.debug.print("[barrier] {s}: param ty {s} not a tp of {s} (n={d})\n", .{ f.name, pty_name, cls.name, cls.type_params.len });
            return null;
        }
        tp_name = pty_name;
    }
    const bounds = module.registry.class_type_param_bounds.get(cls.fqn) orelse {
        if (btr) std.debug.print("[barrier] {s}: no bounds for {s}\n", .{ f.name, cls.fqn });
        return null;
    };
    var bound_head: ?[]const u8 = null;
    for (bounds) |bd| {
        if (std.mem.eql(u8, bd.param, tp_name)) {
            var h = std.mem.trimEnd(u8, bd.bound, "?");
            if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
            bound_head = h;
            break;
        }
    }
    // Bounds may be recorded fqn-qualified; the instance check and the
    // Any-universal test both speak simple heads.
    const bh_raw = bound_head orelse return null;
    const bh = simpleName(bh_raw);
    if (bh.len == 0 or std.mem.eql(u8, bh, "Any")) return null;
    // A bound that is itself a type parameter proves nothing about values.
    if (bh.len <= 2 or ir.parseClassTypeParamIdentity(bh) != null) return null;
    if (self.instanceOf(&args[0], .{ .name = bh, .nullable = false, .args = &.{} })) return null;
    if (btr) std.debug.print("[barrier] TRIP {s} on {s}: arg={s} !is {s}\n", .{ f.name, cls.fqn, args[0].typeFqn(), bh });
    return switch (kind) {
        .bool_false => .{ .Bool = false },
        .int_neg1 => .{ .Int = -1 },
        .null_or_false => if (std.mem.eql(u8, f.return_ty.name, "Boolean"))
            .{ .Bool = false }
        else
            .Null,
        .second_arg => if (args.len > 1) args[1] else .Null,
    };
}

/// Claim and fill a CallVirtual host-receiver site memo (single-fill; the
/// tagged `site_native` release store is the validity gate, so a concurrent
/// replayer either sees the whole memo or takes the slow path). `name` must
/// be module-owned so its pointer outlives every replay. Verdict encoding:
/// low bits 00 = a direct StdlibFn pointer, tag 3 = (op << 2) with 0xFF
/// meaning "no host op, member-name walk only".
fn stampVirtSite(site: ?ir.VirtNativeSite, receiver: *const Value, encoded: u64, name: []const u8) void {
    const st = site orelse return;
    if (encoded == 0 or (encoded & 3 != 0 and encoded & 3 != 3)) return;
    const key: u64 = @intFromPtr(receiver.typeFqn().ptr);
    if (key == 0) return;
    if (@cmpxchgStrong(u64, st.cls, 0, key, .acq_rel, .monotonic) != null) return;
    st.name_ptr.* = @intFromPtr(name.ptr);
    st.name_len.* = @intCast(name.len);
    @atomicStore(u64, st.native, encoded, .release);
}


fn slotNameOrNull(self: *VmHost, slot: MethodSlotId) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    const f = mg.get().funcById(FuncId.from(slot.int())) orelse return null;
    return f.name;
}

pub fn invokeVirtualMember(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    slot: MethodSlotId,
    args: []const Value,
    arg_names_in: []const ?[]const u8,
    arg_params: ?[]const u32,
    site: ?ir.VirtNativeSite,
) Allocator.Error!EvalResult {
    // Vendored persistent-vector scans (see the callMemberInnerStatic
    // intercept): the hot `readable.contains(element)` arrives as a
    // virtual slot, so serve it here too.
    if (args.len == 1 and receiver.* == .Instance) {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vname| {
            if (std.mem.eql(u8, vname, "contains") or std.mem.eql(u8, vname, "indexOf")) {
                if (persistent_list_eq.tryIndexOf(receiver.Instance, &args[0])) |idx| {
                    if (vname.len == 8) return .{ .ok = .{ .Bool = idx >= 0 } };
                    return .{ .ok = Value.newInt(idx) };
                }
            }
        }
    }
    // Vendored persistent-vector builder bulk ops (see the
    // callMemberInnerStatic intercept): `subList(...).clear()` reaches the
    // builder's `removeRange` as a virtual slot, and `addAll` likewise.
    if ((args.len == 1 or args.len == 2) and receiver.* == .Instance) {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vname| {
            if (args.len == 2 and std.mem.eql(u8, vname, "removeRange")) {
                if (try persistent_list_mut.tryRemoveRange(allocator, receiver.Instance, &args[0], &args[1])) |v| {
                    return .{ .ok = v };
                }
            }
            if (args.len == 1 and std.mem.eql(u8, vname, "addAll")) {
                if (try persistent_list_mut.tryAddAll(allocator, receiver.Instance, &args[0])) |v| {
                    return .{ .ok = v };
                }
            }
        }
    }
    // Map-builder put/build/builder reached as virtual slots.
    if ((args.len == 0 or args.len == 2) and receiver.* == .Instance) {
        if (virtualSlotInterfaceMember(self, slot) orelse slotNameOrNull(self, slot)) |vname| {
            if (args.len == 2 and std.mem.eql(u8, vname, "put")) {
                if (try persistent_map_mut.tryPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
                    return .{ .ok = v };
                }
            }
            if (args.len == 0 and std.mem.eql(u8, vname, "build")) {
                if (try persistent_map_mut.tryBuild(self, allocator, receiver.Instance)) |v| {
                    return .{ .ok = v };
                }
            }
            if (args.len == 0 and std.mem.eql(u8, vname, "builder")) {
                if (try persistent_map_mut.tryBuilder(self, allocator, receiver.Instance)) |v| {
                    return .{ .ok = v };
                }
            }
            // Whole-cycle SnapshotStateMap.put via its virtual slot.
            if (args.len == 2 and std.mem.eql(u8, vname, "put") and
                persistent_map_mut.isSnapshotMapClass(receiver.Instance))
            {
                if (try persistent_map_mut.trySnapshotMapPut(self, allocator, receiver.Instance, &args[0], &args[1])) |v| {
                    return .{ .ok = v };
                }
            }
        }
    }
    // Replay a stamped host-receiver site: same interned type FQN means the
    // walk below would reach the same verdict, so serve it without the
    // registry probes. Verdicts are tagged in `site_native`'s low bits
    // (see `stampVirtSite`).
    if (site) |st| replay: {
        if (receiver.* == .Instance or isCallable(receiver)) break :replay;
        const key: u64 = @intFromPtr(receiver.typeFqn().ptr);
        if (@atomicLoad(u64, st.cls, .monotonic) != key) break :replay;
        const native_raw = @atomicLoad(u64, st.native, .acquire);
        if (native_raw == 0) break :replay;
        const np: [*]const u8 = @ptrFromInt(st.name_ptr.*);
        const mname = np[0..st.name_len.*];
        if (native_raw & 3 == 3) {
            // Slot-op / by-name verdict: the host op first (a per-receiver
            // decline falls through), then the member-name walk — the exact
            // tail the probes below would have reached.
            const opv = native_raw >> 2;
            if (opv != 0xFF) {
                const op: HostSlotOp = @enumFromInt(@as(u8, @intCast(opv)));
                if (try runHostSlotOp(self, allocator, op, receiver, mname, args)) |r| return r;
            }
            return callMemberNamed(self, allocator, receiver, mname, args, arg_names_in);
        }
        const native: StdlibFn = @ptrFromInt(native_raw);
        var fqn_buf: [192]u8 = undefined;
        const member_fqn = std.fmt.bufPrint(&fqn_buf, "{s}.{s}", .{ receiver.typeFqn(), mname }) catch break :replay;
        var argbuf = try allocator.alloc(Value, args.len + 1);
        defer allocator.free(argbuf);
        argbuf[0] = receiver.*;
        @memcpy(argbuf[1..], args);
        return dispatchIntrinsic(self, allocator, member_fqn, native, argbuf);
    }
    // Named arguments folded into `arg_params` at lowering must survive
    // every re-dispatching arm below (the interface-delegate forward, an
    // unlinked slot, a bodyless target): derive the names back from the
    // slot root's declared params, or a delegated `emit(tag = ..., scale =
    // ...)` re-binds its arguments positionally.
    var derived_names: []?[]const u8 = &.{};
    defer if (derived_names.len != 0 and runtime.freeScratch()) allocator.free(derived_names);
    const arg_names: []const ?[]const u8 = blk: {
        const params = arg_params orelse break :blk arg_names_in;
        if (params.len != args.len) break :blk arg_names_in;
        const mg0 = self.module.borrow();
        defer mg0.deinit();
        const rootf = mg0.get().funcById(FuncId.from(slot.int())) orelse break :blk arg_names_in;
        derived_names = try allocator.alloc(?[]const u8, args.len);
        for (params, derived_names) |ui, *out| {
            const pi = @as(usize, ui) + 1;
            out.* = if (pi < rootf.params.len) rootf.params[pi].name else null;
        }
        break :blk derived_names;
    };
    // A `by`-delegated interface member the class does not override belongs
    // to the delegate. The slot resolves against the class hierarchy, which
    // for a defaulted interface member lands on the interface's own body —
    // Kotlin routes it to the delegate instead.
    if (receiver.* == .Instance) {
        if (virtualSlotInterfaceMember(self, slot)) |name| {
            if (interfaceDelegateFor(self, allocator, receiver.Instance, name)) |d| {
                const r = try callMemberNamed(self, allocator, &d, name, args, arg_names);
                switch (r) {
                    .ok => return r,
                    .err => |e| if (e != .Unimplemented) return r else freeDispatchMiss(allocator, r),
                }
            }
        }
    }
    if (receiver.* != .Instance) {
        if (isCallable(receiver)) {
            const root = FuncId.from(slot.int());
            // A CALLABLE-shaped receiver on a non-interface slot is not an
            // interpreted instance, but it can still be a host value that
            // serves the member natively — `kotlin.concurrent.thread` hands
            // back a handle whose `join`/`isAlive`/`name` the host answers,
            // and once that type carries a real declaration its member calls
            // arrive here as virtual slots. The by-name dispatch is the one
            // that knows those handles, and it re-borrows the module, so the
            // decision is made under the borrow and acted on outside it.
            const decided: union(enum) { by_name: []const u8, err: []const u8, call_iface } = blk_c: {
                const mg = self.module.borrow();
                defer mg.deinit();
                const module = mg.get();
                const sig = module.decl_sigs.get(root.int()) orelse
                    break :blk_c .{ .err = "virtual callable slot has no declaration" };
                const owner = sig.enclosing_class orelse
                    break :blk_c .{ .err = "virtual callable slot has no interface owner" };
                if (sig.has_body or owner.int() >= module.classes.items.len or
                    !module.classes.items[owner.int()].is_interface)
                {
                    if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
                        const mname: []const u8 = if (module.funcById(root)) |f| f.fqn else "?";
                        std.debug.print("[vcall-callable] slot={d} method={s} recv_ty={s} has_body={} nargs={d} caller={s}\n", .{
                            slot.int(),
                            mname,
                            receiver.typeFqn(),
                            sig.has_body,
                            args.len,
                            if (ir.eval.currentFrameFunc()) |f| f.fqn else "<none>",
                        });
                        ir.eval.dumpFrameChainForDiagAlways();
                    }
                    if (module.funcById(root)) |rf| break :blk_c .{ .by_name = rf.name };
                    break :blk_c .{ .err = "virtual call receiver is not an instance" };
                }
                break :blk_c .call_iface;
            };
            switch (decided) {
                .err => |msg| return .{ .err = .{ .Type = msg } },
                .by_name => |mname| {
                    const named = try callMemberNamed(self, allocator, receiver, mname, args, arg_names);
                    switch (named) {
                        .ok => return named,
                        .err => return .{ .err = .{ .Type = "virtual call receiver is not an instance" } },
                    }
                },
                .call_iface => {},
            }
            const mg = self.module.borrow();
            defer mg.deinit();
            if (arg_params) |params| {
                return callCallableIndexed(self, allocator, mg.get(), root, receiver, receiver, args, params);
            }
            return host_call_value.callValue(self, allocator, receiver, args);
        }
        // A virtual slot names an interface member, and an interface-typed value
        // need not be an interpreted `Instance`: a `Sequence` is a host-backed
        // generator, a `CharSequence` can be a string. Keep slot semantics by
        // resolving the slot against the value's RUNTIME class rather than
        // rejecting the receiver, and fall back to the member's name only when
        // that class implements it natively and there is no body to enter.
        const NonInstanceTarget = struct { target: ?FuncId, name: ?[]const u8 };
        const noinst: NonInstanceTarget = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const module = mg.get();
            const root = FuncId.from(slot.int());
            const mname: ?[]const u8 = if (module.funcById(root)) |f| f.name else null;
            // `typeFqn` on a non-Instance value is a comptime literal, so the
            // pointer-identity memo applies.
            const runtime_class = module.classIdByStaticFqn(receiver.typeFqn()) orelse
                break :blk .{ .target = null, .name = mname };
            // A host-backed receiver executes its members as native
            // intrinsics keyed by its runtime class's FQN, and that binding
            // is the most-derived override of the slot: the interpreted
            // source body reads a source-level representation the host value
            // never materializes (`Result.toString` matches on the `Failure`
            // wrapper; the host Result stores a discriminant and the raw
            // payload). Same rule as the host-synth Instance probe below.
            if (mname) |n| {
                var fqn_buf: [192]u8 = undefined;
                if (std.fmt.bufPrint(&fqn_buf, "{s}.{s}", .{ receiver.typeFqn(), n })) |member_fqn| {
                    if (lookupIntrinsic(self, member_fqn)) |native| {
                        // A SCALAR receiver is its own representation: there
                        // is no wrapper for the by-name walk to unpack, so
                        // reaching the identical host symbol by FuncId is the
                        // same call without the lookup. Wrapper-backed values
                        // (`Result` stores a discriminant and a raw payload,
                        // an `Iterator` is a host generator) keep the walk —
                        // that is where the conversion lives, and binding
                        // them by id returned `Success` for a `Failure`.
                        // Only where the native IS the whole implementation.
                        // A declaration that also carries a BODY is written
                        // against the boxed representation — `UInt.toString()`
                        // is `uintToString(data)`, and `data` does not exist on
                        // a scalar — so reaching it by FuncId runs a body the
                        // receiver cannot satisfy. The by-name walk is what
                        // lands on the intrinsic for those.
                        if (isScalarValue(receiver)) {
                            if (module.methodSlotTarget(runtime_class, slot)) |slot_target| {
                                if (!host_call_func.funcHasBody(self, module, slot_target)) {
                                    if (host_call_func.resolvedNativeForm(self, slot_target)) |target_native| {
                                        if (target_native == native)
                                            break :blk .{ .target = slot_target, .name = n };
                                    }
                                }
                            }
                        }
                        // A host COLLECTION is not a wrapper: `add`/`set`/
                        // `get` take the value as it stands, so the intrinsic
                        // already in hand IS what the walk would land on and
                        // calling it here skips a name search that changes
                        // nothing. Restricted to the container variants —
                        // `Result` and the iterator generators are the shapes
                        // whose conversion lives on the named path.
                        const direct = switch (receiver.*) {
                            // `Array` holds its elements inline, a
                            // `StringBuilder` its bytes, a `Comparator` its
                            // comparison — none of them a discriminant over a
                            // payload the intrinsic would have to unpack. A
                            // `String` and every scalar are likewise their own
                            // representation (the walk lands on this very
                            // native; the FuncId hazard was running a BODY
                            // written against the boxed form, which a direct
                            // NATIVE dispatch never does).
                            .List, .Set, .Map, .Array, .StringBuilder, .Comparator, .String => true,
                            else => isScalarValue(receiver),
                        };
                        if (direct) {
                            stampVirtSite(site, receiver, @intFromPtr(native), n);
                            var argbuf = try allocator.alloc(Value, args.len + 1);
                            defer allocator.free(argbuf);
                            argbuf[0] = receiver.*;
                            @memcpy(argbuf[1..], args);
                            return dispatchIntrinsic(self, allocator, member_fqn, native, argbuf);
                        }
                        stampVirtSite(site, receiver, (0xFF << 2) | 3, n);
                        break :blk .{ .target = null, .name = n };
                    }
                } else |_| {}
            }
            const target = module.methodSlotTarget(runtime_class, slot) orelse {
                // No entry for this class, but the ROOT still names the
                // declaration the call was bound to, and for a builtin whose
                // implementation is a host handler that is enough to settle
                // it by id (`ListIterator.hasPrevious` on a host iterator).
                if (hostSlotOpFor(module, root)) |op| {
                    const nm2: []const u8 = if (module.funcById(root)) |f| f.name else (mname orelse "");
                    // Replay must mirror this exact tail (op, then the name
                    // walk), so a null `mname` — whose fall-through errors
                    // rather than walking — must not stamp, and the op name
                    // must be the walk name.
                    if (mname != null and std.mem.eql(u8, nm2, mname.?))
                        stampVirtSite(site, receiver, (@as(u64, @intFromEnum(op)) << 2) | 3, mname.?);
                    if (try runHostSlotOp(self, allocator, op, receiver, nm2, args)) |r| return r;
                } else if (mname) |n| {
                    stampVirtSite(site, receiver, (0xFF << 2) | 3, n);
                }
                if (runtime.envOnce("KLIO_NOINST_WHY") != null)
                    std.debug.print("[noinst-why] no-slot-entry recv={s} root={s}\n", .{ receiver.typeFqn(), if (module.funcById(root)) |f| f.fqn else "?" });
                break :blk .{ .target = null, .name = mname };
            };
            // A bodyless declaration linked to a host symbol is executable —
            // as that symbol. Dispatching through it is the whole point of
            // binding the slot: it reaches the implementation by FuncId
            // instead of matching the member by string.
            if (!virtualTargetExecutable(module, target) and
                host_call_func.resolvedNativeForm(self, target) == null)
            {
                if (hostSlotOpFor(module, target)) |op| {
                    const nm2: []const u8 = if (module.funcById(target)) |f| f.name else (mname orelse "");
                    if (mname != null and std.mem.eql(u8, nm2, mname.?))
                        stampVirtSite(site, receiver, (@as(u64, @intFromEnum(op)) << 2) | 3, mname.?);
                    if (try runHostSlotOp(self, allocator, op, receiver, nm2, args)) |r| return r;
                } else if (mname) |n| {
                    stampVirtSite(site, receiver, (0xFF << 2) | 3, n);
                }
                if (runtime.envOnce("KLIO_NOINST_WHY") != null)
                    std.debug.print("[noinst-why] target-not-executable recv={s} root={s} target={s}\n", .{ receiver.typeFqn(), if (module.funcById(root)) |f| f.fqn else "?", if (module.funcById(target)) |f| f.fqn else "?" });
                break :blk .{ .target = null, .name = mname };
            }
            if (noinstTraceOn()) {
                std.debug.print("[noinst] recv_ty={s} slot={d} root={s} -> target={s}\n", .{
                    receiver.typeFqn(),
                    slot.int(),
                    if (module.funcById(root)) |f| f.fqn else "?",
                    if (module.funcById(target)) |f| f.fqn else "?",
                });
            }
            break :blk .{ .target = target, .name = mname };
        };
        if (noinst.target) |target| {
            if (arg_params) |params| {
                const mg = self.module.borrow();
                defer mg.deinit();
                return callFuncIndexedRec(
                    self,
                    allocator,
                    mg.get(),
                    target,
                    FuncId.from(slot.int()),
                    receiver,
                    args,
                    params,
                );
            }
            if (try invokeMethodFuncId(self, allocator, receiver, target, args)) |r| return r;
        }
        if (noinst.name) |mname| {
            noteSlotByName2(self, slot, mname, receiver);
            return callMemberNamed(self, allocator, receiver, mname, args, arg_names);
        }
        if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
            const mg = self.module.borrow();
            defer mg.deinit();
            const module = mg.get();
            const root = FuncId.from(slot.int());
            const mname: []const u8 = if (module.funcById(root)) |f| f.fqn else "?";
            std.debug.print("[vcall-noinst] slot={d} method={s} recv_tag={s} recv_ty={s} nargs={d} caller={s}\n", .{
                slot.int(),
                mname,
                @tagName(std.meta.activeTag(receiver.*)),
                receiver.typeFqn(),
                args.len,
                if (ir.eval.currentFrameFunc()) |f| f.fqn else "<none>",
            });
            ir.eval.dumpCurrentFrameParamsForDiag();
            ir.eval.dumpFrameChainForDiagAlways();
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
    // A slot is a static hint, not a guarantee that the runtime can honour it.
    // When the receiver's class has no entry for it, or the entry names a
    // declaration with nothing to execute, dispatch by the member's name — the
    // same result the site produced before it was bound, rather than a failure.
    const slot_name: ?[]const u8 = if (module.funcById(FuncId.from(slot.int()))) |f| f.name else null;
    // A host-synthesized class implements its members as native intrinsics
    // keyed by its own FQN, and that binding is the most-derived override of
    // the slot. The synth's `supertype_names` exist for type checks, so
    // linking the slot through them would enter the supertype's Kotlin body —
    // which reads internal fields the native implementation never
    // materializes. Only anonymous (runtime-built) classes can carry such
    // bindings, so named classes skip the probe.
    if (slot_name) |n| {
        const anon = blk: {
            const class = runtime_def.borrow();
            defer class.deinit();
            break :blk class.get().is_anonymous;
        };
        if (anon) {
            var fqn_buf: [192]u8 = undefined;
            if (std.fmt.bufPrint(&fqn_buf, "{s}.{s}", .{ recv_fqn, n })) |member_fqn| {
                if (lookupIntrinsic(self, member_fqn) != null)
                    return callMemberNamed(self, allocator, receiver, n, args, arg_names);
            } else |_| {}
        }
    }
    const memo_class_id: ?ir.ClassId = cid: {
        // Replay the class's resolved-id memo before the string-keyed
        // registry probe (see `ClassDef.resolve_mod`).
        const class = runtime_def.borrow();
        defer class.deinit();
        const cdef = class.get();
        const mod_key = @intFromPtr(module);
        if (cdef.resolve_mod.load(.monotonic) == mod_key) {
            const plus1 = cdef.resolve_cid.load(.acquire);
            if (plus1 != 0) break :cid ir.ClassId.from(plus1 - 1);
        }
        const found = module.classIdByFqn(cdef.fqn) orelse break :cid null;
        const mut = @constCast(cdef);
        if (mut.resolve_mod.cmpxchgStrong(0, mod_key, .acq_rel, .monotonic) == null) {
            mut.resolve_cid.store(found.int() + 1, .release);
        }
        break :cid found;
    };
    var linked: root_mod.ProgramImage.RuntimeVirtualTarget = if (memo_class_id) |runtime_class|
        .{ .main_func = (module.methodSlotTarget(runtime_class, slot) orelse {
            virtualSlotUnlinkedDiag(module, slot, recv_fqn, args.len, "receiver class");
            if (slot_name) |n| return callMemberNamed(self, allocator, receiver, n, args, arg_names);
            return .{ .err = .{ .Type = "virtual method slot is not linked for receiver class" } };
        }).int() }
    else
        (try runtimeVirtualTarget(self, allocator, module, runtime_def, slot)) orelse {
            virtualSlotUnlinkedDiag(module, slot, recv_fqn, args.len, "runtime class");
            if (slot_name) |n| return callMemberNamed(self, allocator, receiver, n, args, arg_names);
            return .{ .err = .{ .Type = "virtual method slot is not linked for runtime class" } };
        };
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
    // A main-module slot link on an ANONYMOUS receiver class is a
    // supertype-matched guess: the synth lists upstream classes for type
    // checks, and entering the supertype's Kotlin body bypasses the pack's
    // shadowing extension properties. Dispatch by name so the full ladder
    // (host bindings, extension properties, anon methods) serves; a SAM
    // conversion keeps the slot path (its stored lambda is served below by
    // target signature).
    if (linked == .main_func) {
        const anon_recv = blk: {
            const class = runtime_def.borrow();
            defer class.deinit();
            break :blk class.get().is_anonymous;
        };
        if (anon_recv) {
            const sam = blk: {
                const instance = receiver.Instance.borrow();
                defer instance.deinit();
                break :blk instance.get().get("__sam_target__");
            };
            if (sam == null) {
                if (slot_name) |n| return callMemberNamed(self, allocator, receiver, n, args, arg_names);
            }
        }
    }
    const target = FuncId.from(linked.main_func);
    // The type-safe bridge check runs only for the fixed barrier-member
    // names, before the resolved source body binds a foreign argument.
    if (slot_name) |bn| {
        if (barrierSpec(bn)) |kind| {
            if (typeSafeBarrierAnswer(self, module, target, kind, args)) |answer| {
                return .{ .ok = answer };
            }
        }
    }

    // The slot resolved, but to a declaration with nothing behind it: no
    // body, no linked host symbol, and no SAM callable on the instance.
    // Dispatch by name rather than entering an empty frame.
    if (!virtualTargetExecutable(module, target) and
        host_call_func.resolvedNativeForm(self, target) == null)
    {
        const sam = blk: {
            const instance = receiver.Instance.borrow();
            defer instance.deinit();
            break :blk instance.get().get("__sam_target__");
        };
        if (sam == null) {
            if (slot_name) |n| return callMemberNamed(self, allocator, receiver, n, args, arg_names);
        }
    }
    // A bodyless header WITH a linked host symbol is executable — but only
    // for receivers whose runtime REPR the intrinsic serves. An interpreted
    // Instance whose class hierarchy declares the member has a MORE DERIVED
    // interpreted override the name ladder finds; running the header's
    // native form instead fed a `PersistentList` instance to
    // `kotlin.collections.List.isEmpty` (host-List-only). The name ladder
    // still reaches host bindings through its own tails when the hierarchy
    // has no interpreted body.
    if (!virtualTargetExecutable(module, target) and
        host_call_func.resolvedNativeForm(self, target) != null)
    {
        if (slot_name) |n| {
            const declares = blk: {
                const class = runtime_def.borrow();
                defer class.deinit();
                const c = class.get();
                if (module.registry.hierarchy_methods.get(c.name)) |s| {
                    if (s.contains(n)) break :blk true;
                }
                if (module.registry.hierarchy_methods.get(c.fqn)) |s| {
                    if (s.contains(n)) break :blk true;
                }
                break :blk false;
            };
            if (declares) return callMemberNamed(self, allocator, receiver, n, args, arg_names);
        }
    }

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

    if (!any_named) {
        if (try invokeMethodFuncId(self, allocator, receiver, target, args)) |r| return r;
        if (slot_name) |n| return callMemberNamed(self, allocator, receiver, n, args, arg_names);
        return .{ .err = .{ .Type = "virtual method target is not executable" } };
    }

    const all = try prependReceiver(allocator, receiver, args);
    defer if (runtime.freeScratch()) allocator.free(all);
    const names = try allocator.alloc(?[]const u8, arg_names.len + 1);
    defer if (runtime.freeScratch()) allocator.free(names);
    names[0] = null;
    @memcpy(names[1..], arg_names);
    return callFuncNamedRec(self, allocator, module, target, all, names);
}

fn invokeMethodFuncId(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, args_in: []const Value) Allocator.Error!?EvalResult {
    // Vendored persistent-vector scans: a memoized contains/indexOf site
    // replays straight to its FuncId, so the host walk must intercept at
    // the invoker too (see the callMemberInnerStatic intercept).
    if (args_in.len == 1 and receiver.* == .Instance) {
        const fname = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const f = mg.get().funcById(fid) orelse break :blk "";
            break :blk f.name;
        };
        if (std.mem.eql(u8, fname, "contains") or std.mem.eql(u8, fname, "indexOf")) {
            if (persistent_list_eq.tryIndexOf(receiver.Instance, &args_in[0])) |idx| {
                if (fname.len == 8) return .{ .ok = .{ .Bool = idx >= 0 } };
                return .{ .ok = Value.newInt(idx) };
            }
        }
    }
    // Vendored persistent-vector builder bulk ops (see the
    // callMemberInnerStatic intercept): serve a memoized removeRange or
    // addAll site replaying straight to its FuncId.
    if (args_in.len <= 2 and receiver.* == .Instance) {
        const fname2 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const f = mg.get().funcById(fid) orelse break :blk "";
            break :blk f.name;
        };
        if (args_in.len == 2 and std.mem.eql(u8, fname2, "removeRange")) {
            if (try persistent_list_mut.tryRemoveRange(allocator, receiver.Instance, &args_in[0], &args_in[1])) |v| {
                return .{ .ok = v };
            }
        }
        if (args_in.len == 1 and std.mem.eql(u8, fname2, "addAll")) {
            if (try persistent_list_mut.tryAddAll(allocator, receiver.Instance, &args_in[0])) |v| {
                return .{ .ok = v };
            }
        }
        if (args_in.len == 2 and std.mem.eql(u8, fname2, "put")) {
            if (try persistent_map_mut.tryPut(self, allocator, receiver.Instance, &args_in[0], &args_in[1])) |v| {
                return .{ .ok = v };
            }
        }
        if (args_in.len == 0 and std.mem.eql(u8, fname2, "build")) {
            if (try persistent_map_mut.tryBuild(self, allocator, receiver.Instance)) |v| {
                return .{ .ok = v };
            }
        }
        if (args_in.len == 0 and std.mem.eql(u8, fname2, "builder")) {
            if (try persistent_map_mut.tryBuilder(self, allocator, receiver.Instance)) |v| {
                return .{ .ok = v };
            }
        }
    }
    // Scalar-replay leaf on the resolved member: the receiver rides as
    // param 0 (opaque genre when non-scalar — a body that touches it
    // bails); a bail falls through to the ordinary invoke, which re-runs
    // the pure body exactly.
    leaf: {
        if (receiver.* == .Null) break :leaf;
        const mg2 = self.module.borrow();
        defer mg2.deinit();
        const m2 = mg2.get();
        const lf = m2.funcById(fid) orelse break :leaf;
        if (args_in.len + 1 > 8) break :leaf;
        var all: [8]Value = undefined;
        all[0] = receiver.*;
        for (args_in, 0..) |a, i| all[i + 1] = a;
        if (try ir.eval.tryLeafValues(VmHost, allocator, m2, lf, all[0 .. args_in.len + 1], self, null)) |lo| switch (lo) {
            .val => |v| return .{ .ok = v },
            .raise => |e| return .{ .err = e },
        };
    }
    ir.eval.dispatchNote(.served_user_body);
    runtime.prof.opRoute(4);
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const f = funcAt(mod, fid) orelse return null;
    // A bodyless declaration linked to a host symbol runs as that intrinsic,
    // not as an empty frame. Every fast path below enters a frame directly, so
    // route it through the general call path, which consults the linkage.
    if (!f.hasBody() and host_call_func.resolvedNativeForm(self, fid) != null) {
        const all = try prependReceiver(allocator, receiver, args_in);
        defer if (runtime.freeScratch()) allocator.free(all);
        return try callFuncRec(self, allocator, mod, fid, all);
    }
    // Frameless serve for the canonical getter shape on a claimed class.
    // Uses the module-owned func pointer so the shape/route memo persists.
    if (args_in.len == 0) {
        if (mod.funcById(fid)) |fp| {
            if (vmhost.host_fields.accessorFastGet(self, mod, fp, receiver)) |r| return r;
        }
    }
    // The wider leaf-expression shape: a body that only reads its arguments
    // and stored fields and combines them with primitive operators runs
    // without a frame.
    if (mod.funcById(fid)) |fp| {
        if (fp.has_receiver_param and args_in.len + 1 == fp.params.len and
            args_in.len < ir.LEAF_MAX_REGS)
        {
            // Two tiers: safety builds 0xAA-fill an `undefined` stack array
            // at its DECLARED size on every entry, and the 64-slot buffer's
            // 2.5KB fill was a top profile frame across member-call-heavy
            // suites. Nearly every call fits eight slots.
            if (args_in.len + 1 <= 8) {
                var argbuf: [8]Value = undefined;
                argbuf[0] = receiver.*;
                for (args_in, 0..) |a, i| argbuf[i + 1] = a;
                if (try ir.eval.leafExprServe(VmHost, allocator, mod, fp, argbuf[0 .. args_in.len + 1], self)) |r| return r;
            } else {
                var argbuf: [ir.LEAF_MAX_REGS]Value = undefined;
                argbuf[0] = receiver.*;
                for (args_in, 0..) |a, i| argbuf[i + 1] = a;
                if (try ir.eval.leafExprServe(VmHost, allocator, mod, fp, argbuf[0 .. args_in.len + 1], self)) |r| return r;
            }
        }
    }
    if (nuTraceEnv()) |want| {
        if (std.mem.eql(u8, want, f.name)) {
            std.debug.print("[invoke-method] {s}#{d} params={d} recv={s} args=", .{ f.fqn, fid.int(), f.params.len, receiver.typeFqn() });
            for (args_in) |a| switch (a) {
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
    const threaded_composer: ?Value = compose.threadedComposerArg(f.params, args_in);
    if (threaded_composer) |c| compose.pushComposer(c);
    defer if (threaded_composer != null) compose.popComposer();

    // Pairless composable member call accepted by the pair-trimmed pick
    // (`ReadStringCompositionLocal(local)` against `(this, local, $composer,
    // $changed)`): complete the pair from the ambient composer before
    // binding, or the body runs with Unit in `$composer`.
    var pair_ext: ?[]Value = null;
    defer if (pair_ext) |pe| if (runtime.freeScratch()) allocator.free(pe);
    var args = args_in;
    if (f.params.len >= 2 and
        std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed") and
        std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer") and
        args.len + 3 <= f.params.len and threaded_composer == null)
    {
        if (compose.currentComposer()) |c| {
            // Defaulted user params omitted at the call site (`Test()` against
            // `(this, number$arg = marker, $composer, $changed)`): a positional
            // append would land the composer in the first open user slot, so
            // bind the pair BY NAME and let the named binder fill the middle
            // defaults.
            if (args.len + 3 < f.params.len) {
                const all = try prependReceiver(allocator, receiver, args);
                defer if (runtime.freeScratch()) allocator.free(all);
                const full = try allocator.alloc(Value, all.len + 2);
                defer if (runtime.freeScratch()) allocator.free(full);
                @memcpy(full[0..all.len], all);
                full[all.len] = c;
                full[all.len + 1] = .{ .Int = 0 };
                const names = try allocator.alloc(?[]const u8, full.len);
                defer if (runtime.freeScratch()) allocator.free(names);
                for (names[0..all.len]) |*n| n.* = null;
                names[all.len] = "$composer";
                names[all.len + 1] = "$changed";
                compose.pushComposer(c);
                defer compose.popComposer();
                return try callFuncNamedRec(self, allocator, mod, fid, full, names);
            }
            const pe = try allocator.alloc(Value, args.len + 2);
            @memcpy(pe[0..args.len], args);
            pe[args.len] = c;
            pe[args.len + 1] = .{ .Int = 0 };
            pair_ext = pe;
            args = pe;
            compose.pushComposer(c);
        }
    }
    const pushed_completed = pair_ext != null;
    defer if (pushed_completed) compose.popComposer();

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
        var list = try ir.eval.acquireArgsCap(allocator, args.len + 1);
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
        const padded = try padArgsWithDefaultsFor(self, allocator, mod, f.params.len, all, defaults, f.params);
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
/// Relaxed argument signature for the NAMED member-walk memo: never null.
/// Where the strict signature declines container shapes (their extension
/// applicability inspects value content), member OVERLOADS cannot differ
/// only by a generic element type (Kotlin erasure forbids it), so a
/// container KIND tag discriminates every declarable member overload set.
/// Instances still fold class identity; closures fold body identity.
fn methodArgSigRelaxed(self: *VmHost, args: []const Value) u64 {
    var h = std.hash.Wyhash.init(0x452821e638d01377 +% args.len);
    for (args) |*a| {
        const tag: u8 = @intFromEnum(std.meta.activeTag(a.*));
        h.update((&tag)[0..1]);
        switch (a.*) {
            .Instance => |inst| {
                const id = runtime.InstanceData.classIdentityUnlocked(inst);
                h.update(std.mem.asBytes(&id));
            },
            .IrClosure => |c| {
                if (self.closures.get(@intCast(c.id))) |info| {
                    h.update(std.mem.asBytes(&info.body_func));
                }
            },
            .Array => |arr| {
                const pk: u8 = if (arr.prim) |p| @as(u8, @intFromEnum(p)) + 1 else 0;
                h.update((&pk)[0..1]);
            },
            else => {},
        }
    }
    const v = h.final();
    return if (v == 0) 1 else v;
}

/// Arg-side RELAXED variant of `instanceMethodKeyScoped` for the MEMBER
/// cache only: receiver keying rules are identical (identity-keyable
/// receivers only — receiver-side relaxation is where the measured
/// regressions lived), but the arg signature uses container-kind tags
/// (see `methodArgSigRelaxed`), which fully discriminate any declarable
/// member overload set under Kotlin erasure. Salted apart from strict
/// entries. The extension caches never use this key.
fn instanceMethodKeyRelaxed(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    var k = instanceMethodKeyScoped(self, receiver, name, &.{}, static_recv, null) orelse return null;
    k.n_args = @intCast(args.len);
    k.sig = (k.sig ^ methodArgSigRelaxed(self, args)) *% 0x9E3779B97F4A7C15 ^ 0x00C0_FFEE_D00D_5EED;
    if (k.sig == 0) k.sig = 11;
    return k;
}

fn methodArgSig(self: *VmHost, args: []const Value) ?u64 {
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
            // A closure argument keys by its BODY identity (folded below):
            // overload applicability consults the declared shape, a pure
            // function of the body, never the captured values. Without a
            // tag every call carrying a lambda had no key at all, and
            // extension-heavy lambda-argument code re-ran the full
            // extension walk per call.
            .IrClosure => 16,
                        // A `Null` argument at a fixed position keys soundly: the walk
            // scores an identical tag vector identically every time (its
            // null-compat check consults only the PARAM's declared
            // nullability), so the resolution is a pure function of the
            // key. Excluding it made every nullable-trailing-arg call
            // (`resumeCancellableWithInternal`'s `onCancellation = null`)
            // re-walk per call.
            .Null => 18,
            // A PRIMITIVE array argument keys by its prim kind — the same
            // granularity the receiver-identity case uses; an object array
            // (erased element type) stays uncacheable.
            .Array => 19,
            // A `Result` argument is `kotlin.Result` at exactly typeFqn
            // granularity (the payload type is erased), mirroring the
            // receiver-identity case. The coroutine resume path passes one
            // on every `resumeWith`-family call.
            .Result => 20,
            else => return null,
        };
        h.update((&tag)[0..1]);
        switch (a.*) {
            .Instance => |inst| {
                const id = runtime.InstanceData.classIdentityUnlocked(inst);
                h.update(std.mem.asBytes(&id));
            },
            .Array => |arr| {
                const pk: u8 = if (arr.prim) |p| @as(u8, @intFromEnum(p)) + 1 else return null;
                h.update((&pk)[0..1]);
            },
            .IrClosure => |c| {
                const info = self.closures.get(@intCast(c.id)) orelse return null;
                h.update(std.mem.asBytes(&info.body_func));
                const mp: usize = @intFromPtr(info.module);
                h.update(std.mem.asBytes(&mp));
            },
            else => {},
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
    // Non-Instance receivers with a stable type identity key too: a
    // closure's resolution is fixed by its BODY (the declared shape —
    // arity, receiver head, suspendness — is a pure function of the body
    // func), and a `Result`'s by its tag (extensions on `Result<T>` are
    // erased). The synthesized identity is forced ODD so it can never
    // collide with a real class-cell pointer (those are aligned). The
    // hot coroutine boundary (`startCoroutineUninterceptedOrReturn` on a
    // suspend block, `throwOnFailure` on a `Result`) re-ran the full
    // extension walk per call without this.
    const class_identity: usize = switch (receiver.*) {
        .Instance => |inst| runtime.InstanceData.classIdentityUnlocked(inst),
        .IrClosure => |c| blk: {
            const info = self.closures.get(@intCast(c.id)) orelse return null;
            var h = std.hash.Wyhash.init(0x2545f4914f6cdd1d);
            h.update(std.mem.asBytes(&info.body_func));
            const mp: usize = @intFromPtr(info.module);
            h.update(std.mem.asBytes(&mp));
            break :blk h.final() | 1;
        },
        .Result => 0x5261 | 1,
        // A CLASS value (`Snapshot`'s companion-forwarding class receiver, a
        // `::class`): member/extension resolution is a pure function of the
        // referenced class cell — `currentSnapshot` on the snapshot companion
        // class re-ran the full extension walk 90k times per benchmark.
        .Class => |c| c.identity(),
        // Runtime shapes whose extension resolution is fully fixed by the
        // value's type tag, at exactly `typeFqn` granularity (prim kind for
        // arrays, kind + step-refinement for ranges). Identities are forced
        // ODD so they never collide with an aligned class-cell pointer.
        .Array => |arr| blk: {
            const k: usize = if (arr.prim) |pk| @as(usize, @intFromEnum(pk)) + 1 else 0;
            break :blk (0xA100 + (k << 8)) | 1;
        },
        .Int => 0xA401 | 1,
        .Long => 0xA411 | 1,
        .Short => 0xA421 | 1,
        .Byte => 0xA431 | 1,
        .UInt => 0xA441 | 1,
        .ULong => 0xA451 | 1,
        .UShort => 0xA461 | 1,
        .UByte => 0xA471 | 1,
        .Double => 0xA481 | 1,
        .Float => 0xA491 | 1,
        .Bool => 0xA4A1 | 1,
        .Char => 0xA4B1 | 1,
        else => return null,
    };
    var sig = methodArgSig(self, args) orelse return null;
    if (static_recv != null or declared_recv != null) {
        var h = std.hash.Wyhash.init(0x517cc1b727220a95);
        if (static_recv) |s| h.update(s);
        h.update(&[_]u8{0});
        if (declared_recv) |d| h.update(d);
        sig ^= h.final();
        // Keep 0 reserved for the unscoped empty-arg case.
        if (sig == 0) sig = 1;
    }
    const name_p = memberNameIdentity(self, name) orelse return null;
    return .{
        .class_p = class_identity,
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

/// Thread-local L1 in front of the shared method-resolution caches. The
/// shared maps live behind the program cell's reader lock, whose atomic
/// state word ping-pongs between cores on every borrow — at millions of
/// probes per second across two threads that coherence traffic dominated
/// the background-thread stress profiles. Entries mirror the shared maps
/// (which are add-only and never re-map a key to a different target), so a
/// stale or evicted slot just falls through to the shared probe.
const TL_METHOD_CACHE_SIZE = 2048;

/// Generation stamp for every process-global / thread-local dispatch cache.
/// An in-process driver that runs MANY programs in one process (the parity
/// itests, e2e, the fuzzer) frees each program's module and arena; pointer
/// identities (class cells, name storage) are then reused by the next
/// program, and a surviving cache entry keyed on them replays the PREVIOUS
/// program's resolution — wrong overloads at best, calls into freed IR at
/// worst (the census's cross-test contamination family). Such drivers bump
/// the generation at each program boundary; entries from an older
/// generation never hit.
pub var dispatch_cache_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);
pub fn dispatchCacheGen() u32 {
    return dispatch_cache_gen.load(.monotonic);
}

pub fn bumpDispatchCacheGen() void {
    _ = dispatch_cache_gen.fetchAdd(1, .monotonic);
}
inline fn cacheGen() u32 {
    return dispatch_cache_gen.load(.monotonic);
}

const TlMethodEntry = struct { class_p: usize = 0, name_p: usize = 0, n_args: u32 = 0, sig: u64 = 0, raw_plus: u64 = 0, gen: u32 = 0, miss_ttl: u8 = 0 };

/// `raw_plus` sentinel: the SHARED map had no entry for this key when last
/// probed. The shared maps are add-only, so the only staleness is an entry
/// appearing later; `miss_ttl` re-probes every 64th consult to pick it up,
/// amortizing the program-cell borrow (whose atomic word ping-pongs between
/// cores) instead of paying it on every miss forever.
const TL_ABSENT: u64 = std.math.maxInt(u64);
threadlocal var tl_method_cache: [TL_METHOD_CACHE_SIZE]TlMethodEntry = @splat(.{});
threadlocal var tl_ext_cache: [TL_METHOD_CACHE_SIZE]TlMethodEntry = @splat(.{});

inline fn tlSlot(key: root_mod.ProgramImage.InstanceMethodKey) usize {
    const h = key.sig ^ (@as(u64, @intCast(key.class_p)) *% 0x9E3779B97F4A7C15) ^ @as(u64, @intCast(key.name_p));
    return @intCast((h ^ (h >> 17)) & (TL_METHOD_CACHE_SIZE - 1));
}

const TlProbe = union(enum) { hit: u32, absent, unknown };

inline fn tlGet(cache: *[TL_METHOD_CACHE_SIZE]TlMethodEntry, key: root_mod.ProgramImage.InstanceMethodKey) TlProbe {
    const e = &cache[tlSlot(key)];
    if (e.raw_plus != 0 and e.gen == cacheGen() and e.class_p == key.class_p and e.name_p == key.name_p and
        e.sig == key.sig and e.n_args == key.n_args)
    {
        if (e.raw_plus == TL_ABSENT) {
            if (e.miss_ttl > 0) {
                e.miss_ttl -= 1;
                return .absent;
            }
            return .unknown;
        }
        return .{ .hit = @intCast(e.raw_plus - 1) };
    }
    return .unknown;
}

inline fn tlPut(cache: *[TL_METHOD_CACHE_SIZE]TlMethodEntry, key: root_mod.ProgramImage.InstanceMethodKey, raw: u32) void {
    cache[tlSlot(key)] = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .raw_plus = @as(u64, raw) + 1, .gen = cacheGen() };
}

inline fn tlPutAbsent(cache: *[TL_METHOD_CACHE_SIZE]TlMethodEntry, key: root_mod.ProgramImage.InstanceMethodKey) void {
    cache[tlSlot(key)] = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .raw_plus = TL_ABSENT, .gen = cacheGen(), .miss_ttl = 63 };
}

/// Thread-local L1 for the named-binding permutation map.
const TlPermEntry = struct { class_p: usize = 0, name_p: usize = 0, n_args: u32 = 0, sig: u64 = 0, raw_plus: u8 = 0, gen: u32 = 0, perm: root_mod.ProgramImage.NamedPerm = .{ .n = 0xFF, .src = @splat(0xFF) } };
threadlocal var tl_perm_cache: [TL_METHOD_CACHE_SIZE]TlPermEntry = @splat(.{});

/// Thread-local L1 for the stdlib member-resolve cache. `state`: 0 empty,
/// 1 confirmed-none, 2 resolved.
const TlResolveEntry = struct { type_p: usize = 0, name_p: usize = 0, args_empty: bool = false, file: u32 = 0, argc: u32 = 0, state: u8 = 0, gen: u32 = 0, func: ?StdlibFn = null, fqn: []const u8 = "" };
threadlocal var tl_resolve_cache: [TL_METHOD_CACHE_SIZE]TlResolveEntry = @splat(.{});

inline fn tlResolveSlot(key: root_mod.ProgramImage.MemberResolveKey) usize {
    const h = (@as(u64, @intCast(key.type_p)) *% 0x9E3779B97F4A7C15) ^ @as(u64, @intCast(key.name_p)) ^ @intFromBool(key.args_empty) ^ (@as(u64, key.file) << 32) ^ (@as(u64, key.argc) << 20);
    return @intCast((h ^ (h >> 17)) & (TL_METHOD_CACHE_SIZE - 1));
}

inline fn tlResolveMatch(e: *const TlResolveEntry, key: root_mod.ProgramImage.MemberResolveKey) bool {
    return e.state != 0 and e.gen == cacheGen() and e.type_p == key.type_p and e.name_p == key.name_p and
        e.args_empty == key.args_empty and e.file == key.file and e.argc == key.argc;
}

fn tlResolveStore(key: root_mod.ProgramImage.MemberResolveKey, entry: root_mod.ProgramImage.MemberResolveEntry) void {
    tl_resolve_cache[tlResolveSlot(key)] = .{
        .type_p = key.type_p,
        .name_p = key.name_p,
        .args_empty = key.args_empty,
        .file = key.file,
        .argc = key.argc,
        .state = if (entry.func == null) 1 else 2,
        .gen = cacheGen(),
        .func = entry.func,
        .fqn = entry.fqn,
    };
}

fn instanceMethodCacheGetRaw(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey) ?u32 {
    switch (tlGet(&tl_method_cache, key)) {
        .hit => |raw| return raw,
        .absent => return null,
        .unknown => {},
    }
    const raw: ?u32 = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().instance_method_cache.get(key);
    };
    if (raw) |r| tlPut(&tl_method_cache, key, r) else tlPutAbsent(&tl_method_cache, key);
    return raw;
}

fn instanceMethodCachePutRaw(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey, raw: u32) void {
    if (!ir.eval.dispatchCacheStable()) return;
    tlPut(&tl_method_cache, key, raw);
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().instance_method_cache.put(key, raw) catch {};
}

fn extMethodCacheGet(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey) ?u32 {
    switch (tlGet(&tl_ext_cache, key)) {
        .hit => |raw| return raw,
        .absent => return null,
        .unknown => {},
    }
    const raw: ?u32 = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().ext_method_cache.get(key);
    };
    if (raw) |r| tlPut(&tl_ext_cache, key, r) else tlPutAbsent(&tl_ext_cache, key);
    return raw;
}

fn extMethodCachePut(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey, fid: u32) void {
    if (!ir.eval.dispatchCacheStable()) return;
    tlPut(&tl_ext_cache, key, fid);
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().ext_method_cache.put(key, fid) catch {};
}

/// Thread-local L1 for the pack-binding inline cache: a member call served
/// by a native binding (or its cached "no intrinsic" miss) otherwise pays a
/// program-cell borrow plus a shared-map probe on every single call. `state`:
/// 0 empty, 1 mirrored. Same add-only/gen-stamp discipline as the method L1s.
const TlIntrinsicEntry = struct { class_p: usize = 0, name_p: usize = 0, n_args: u32 = 0, sig: u64 = 0, state: u8 = 0, gen: u32 = 0, miss_ttl: u8 = 0, entry: root_mod.ProgramImage.MemberResolveEntry = .{ .func = null, .fqn = "" } };
threadlocal var tl_intrinsic_cache: [TL_METHOD_CACHE_SIZE]TlIntrinsicEntry = @splat(.{});

fn instanceIntrinsicCacheGet(self: *VmHost, key: root_mod.ProgramImage.InstanceMethodKey) ?root_mod.ProgramImage.MemberResolveEntry {
    const e = &tl_intrinsic_cache[tlSlot(key)];
    if (e.state != 0 and e.gen == cacheGen() and e.class_p == key.class_p and e.name_p == key.name_p and
        e.sig == key.sig and e.n_args == key.n_args)
    {
        if (e.state == 2) {
            if (e.miss_ttl > 0) {
                e.miss_ttl -= 1;
                return null;
            }
        } else return e.entry;
    }
    const hit: ?root_mod.ProgramImage.MemberResolveEntry = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().instance_intrinsic_cache.get(key);
    };
    if (hit) |h| {
        e.* = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .state = 1, .gen = cacheGen(), .entry = h };
    } else {
        e.* = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .state = 2, .gen = cacheGen(), .miss_ttl = 63, .entry = .{ .func = null, .fqn = "" } };
    }
    return hit;
}

/// The member name a virtual slot stands for, but ONLY when the slot's root
/// declaration belongs to an INTERFACE — the one case where a delegating
/// receiver must re-decide the call.
fn virtualSlotInterfaceMember(self: *VmHost, slot: MethodSlotId) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    const root = FuncId.from(slot.int());
    const sig = module.decl_sigs.get(root.int()) orelse return null;
    const owner = sig.enclosing_class orelse return null;
    if (owner.int() >= module.classes.items.len) return null;
    if (!module.classes.items[owner.int()].is_interface) return null;
    const f = module.funcById(root) orelse return null;
    return f.name;
}

/// The member name a lowering-resolved target stands for, but ONLY when its
/// declaring class is an interface — the one case where a delegating receiver
/// must re-decide the call. Everything else answers null so the resolved
/// identity runs untouched.
fn resolvedMemberName(self: *VmHost, fid: FuncId) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const owner = declaringClassSimpleName(self, mod, fid) orelse return null;
    const cid = mod.classId(owner) orelse return null;
    if (cid.int() >= mod.classes.items.len) return null;
    if (!mod.classes.items[cid.int()].is_interface) return null;
    const f = mod.funcById(fid) orelse return null;
    return f.name;
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
    const dcs_trace = runtime.envOnce("KLIO_DCS_TRACE") != null;
    if (dcs_trace) std.debug.print("[dcs] module={x} n_classes={d} fid={d}\n", .{ @intFromPtr(module), module.classes.items.len, @intFromEnum(fid) });
    for (module.classes.items, 0..) |*c, ci| {
        if (dcs_trace) std.debug.print("[dcs]   class[{d}] ptr={x} methods.ptr={x} methods.len={d}\n", .{ ci, @intFromPtr(c), @intFromPtr(c.methods.ptr), c.methods.len });
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

/// Whether a lambda argument makes the resolved MEMBER inapplicable while a
/// same-arity extension declares that slot as a function type. Kotlin ranks
/// members over extensions only among APPLICABLE candidates, so
/// `DateTimeFormat<DateTimeComponents>.format { … }` is the extension taking
/// a `DateTimeComponents.() -> Unit`, never the member `format(value: T)`.
/// Restricted to a member slot declared as a bare TYPE VARIABLE: a nominal
/// parameter can still take the lambda by SAM conversion, and there the
/// member keeps its precedence.
fn lambdaArgPrefersExtension(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    fid: FuncId,
    name: []const u8,
    args: []const Value,
) Allocator.Error!bool {
    if (args.len == 0 or !isCallable(&args[args.len - 1])) return false;
    var member_slot_is_tp = false;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const f = funcAt(mg.get(), fid) orelse return false;
        if (f.params.len != args.len + 1) return false;
        const raw = std.mem.trimEnd(u8, f.params[f.params.len - 1].ty.name, "?");
        const head = std.mem.trimEnd(u8, simpleName(raw), "?");
        member_slot_is_tp = (head.len != 0 and head.len <= 2 and std.ascii.isUpper(head[0])) or
            ir.parseClassTypeParamIdentity(raw) != null;
    }
    if (!member_slot_is_tp) return false;
    var cands: std.ArrayList(FuncId) = .empty;
    defer cands.deinit(allocator);
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        for (mod.funcsBySimpleName(name)) |cand| {
            const g = funcAt(mod, cand) orelse continue;
            if (!g.hasBody() or g.params.len != args.len + 1) continue;
            if (!std.mem.eql(u8, g.params[0].name, "this")) continue;
            if (isMemberExt(mod, cand)) continue;
            if (!std.mem.startsWith(u8, g.params[g.params.len - 1].ty.name, "Function")) continue;
            cands.append(allocator, cand) catch {};
        }
    }
    for (cands.items) |cand| {
        const rty = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const g = funcAt(mg.get(), cand) orelse break :blk null;
            break :blk &g.params[0].ty;
        } orelse continue;
        if (try strictReceiverProven(self, allocator, receiver, cand, rty)) return true;
    }
    return false;
}

fn irMethodWalk(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, static_recv: ?[]const u8) Allocator.Error!?EvalResult {
    if (runtime.envSetOnce("KLIO_WALK_TRACE")) {
        std.debug.print("[ir-walk] {s} on {s} static={s}\n", .{ name, receiver.typeFqn(), static_recv orelse "-" });
    }
    runtime.prof.opRoute(9);
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
    const strict_key = instanceMethodKeyScoped(self, receiver, name, args, static_recv, null);
    // A container-typed argument makes the strict signature unbuildable;
    // the RELAXED key (kind tags — see `instanceMethodKeyRelaxed`) keys the
    // member resolution then, so those calls stop re-walking per call.
    const key = strict_key orelse instanceMethodKeyRelaxed(self, receiver, name, args, static_recv);
    if (key) |k| {
        if (instanceMethodCacheGetRaw(self, k)) |raw| {
            if (raw == METHOD_MISS) return null;
            const cached: FuncId = @enumFromInt(raw);
            // The lambda-argument decline is a property of the CALL, not of
            // the cached resolution, so it applies on the hit path too.
            if (try lambdaArgPrefersExtension(self, allocator, receiver, cached, name, args)) return null;
            return try invokeMethodFuncId(self, allocator, receiver, cached, args);
        }
    }
    const resolved0 = try resolveInstanceMethod(self, allocator, receiver, name, args, static_recv);
    if (resolved0) |r0| {
        if (try lambdaArgPrefersExtension(self, allocator, receiver, r0.fid, name, args)) return null;
    }
    const resolved = resolved0 orelse {
        // Cache the miss: a member-accessed field (`obj.field`) re-runs this
        // walk every read otherwise. Only a proven, key-stable miss is stored.
        if (key) |k| instanceMethodCachePutRaw(self, k, METHOD_MISS);
        return null;
    };
    // The STRICT key folds every discriminator the overload pick consults:
    // each argument's tag plus its class identity, closure body, or function
    // decl pointer, alongside the receiver class and name that fix the
    // candidate set. For a fixed strict key the pick is therefore a pure
    // function of the key, and storing it cannot serve an overload the walk
    // would not have chosen — so a resolution that had SEVERAL candidates is
    // still cacheable. Only the RELAXED key (container kind tags, no
    // identity) needs the single-candidate guarantee, since two overloads can
    // share its coarser signature.
    if (resolved.unambiguous or strict_key != null) {
        if (key) |k| instanceMethodCachePutRaw(self, k, @intFromEnum(resolved.fid));
    }
    if (runtime.envSetOnce("KLIO_WALK_TRACE")) {
        std.debug.print("[ir-walk-fill] {s} strict={} key={} unamb={} -> cached={}\n", .{ name, strict_key != null, key != null, resolved.unambiguous, key != null and (resolved.unambiguous or strict_key != null) });
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

fn isKTypeSynth(v: *const Value) bool {
    if (v.* != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return std.mem.eql(u8, cg.get().name, "kotlin.reflect.KType") or std.mem.eql(u8, cg.get().fqn, "kotlin.reflect.KType");
}

fn ktypeField(v: *const Value, name: []const u8) Value {
    const g = v.Instance.borrow();
    defer g.deinit();
    return g.get().get(name) orelse Value.Null;
}

fn ktypeClassifierName(v: *const Value) []const u8 {
    const c = ktypeField(v, "classifier");
    switch (c) {
        .Class => |cd| {
            const g = cd.borrow();
            defer g.deinit();
            return if (g.get().fqn.len != 0) g.get().fqn else g.get().name;
        },
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            return g.get().bytes;
        },
        else => return "",
    }
}

fn ktypeEquals(self: *VmHost, allocator: Allocator, a: *const Value, b: *const Value) Allocator.Error!bool {
    if (!isKTypeSynth(b)) return false;
    if (!std.mem.eql(u8, ktypeClassifierName(a), ktypeClassifierName(b))) return false;
    const na = ktypeField(a, "isMarkedNullable");
    const nb = ktypeField(b, "isMarkedNullable");
    if ((na == .Bool and na.Bool) != (nb == .Bool and nb.Bool)) return false;
    const aa = ktypeField(a, "arguments");
    const ab = ktypeField(b, "arguments");
    if (aa != .List or ab != .List) return aa == .Null and ab == .Null;
    const ga = aa.List.items.borrow();
    defer ga.deinit();
    const gb = ab.List.items.borrow();
    defer gb.deinit();
    if (ga.get().items.len != gb.get().items.len) return false;
    for (ga.get().items, gb.get().items) |*pa, *pb| {
        if (pa.* != .Instance or pb.* != .Instance) return false;
        const ta = ktypeField(pa, "type");
        const tb = ktypeField(pb, "type");
        if (ta == .Null and tb == .Null) continue;
        if (ta != .Instance or tb != .Instance) return false;
        if (!try ktypeEquals(self, allocator, &ta, &tb)) return false;
    }
    return true;
}

fn ktypeHash(self: *VmHost, allocator: Allocator, v: *const Value) Allocator.Error!i32 {
    var h: i32 = builtin_members.javaStringHash(ktypeClassifierName(v));
    const n = ktypeField(v, "isMarkedNullable");
    h = h *% 31 +% @as(i32, if (n == .Bool and n.Bool) 1 else 0);
    const args = ktypeField(v, "arguments");
    if (args == .List) {
        const g = args.List.items.borrow();
        defer g.deinit();
        for (g.get().items) |*pa| {
            if (pa.* != .Instance) continue;
            const t = ktypeField(pa, "type");
            h = h *% 31 +% (if (t == .Instance) try ktypeHash(self, allocator, &t) else 0);
        }
    }
    return h;
}

fn ktypeRender(self: *VmHost, allocator: Allocator, v: *const Value, buf: *std.ArrayList(u8)) Allocator.Error!void {
    try buf.appendSlice(allocator, ktypeClassifierName(v));
    const args = ktypeField(v, "arguments");
    if (args == .List) {
        const g = args.List.items.borrow();
        defer g.deinit();
        if (g.get().items.len != 0) {
            try buf.append(allocator, '<');
            for (g.get().items, 0..) |*pa, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                const t = if (pa.* == .Instance) ktypeField(pa, "type") else Value.Null;
                if (t == .Instance) try ktypeRender(self, allocator, &t, buf) else try buf.append(allocator, '*');
            }
            try buf.append(allocator, '>');
        }
    }
    const n = ktypeField(v, "isMarkedNullable");
    if (n == .Bool and n.Bool) try buf.append(allocator, '?');
}

fn anyInstanceFallback(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    // A `KType` (`typeOf<T>()`) compares structurally: same classifier,
    // same arguments, same nullability; it renders as its classifier's
    // name with `?` for a nullable type.
    if (isKTypeSynth(receiver)) {
        if (args.len == 1 and std.mem.eql(u8, name, "equals")) {
            return .{ .ok = boolVal(try ktypeEquals(self, allocator, receiver, &args[0])) };
        }
        if (args.len == 0 and std.mem.eql(u8, name, "hashCode")) {
            return .{ .ok = Value.newInt(@as(i64, try ktypeHash(self, allocator, receiver))) };
        }
        if (args.len == 0 and std.mem.eql(u8, name, "toString")) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try ktypeRender(self, allocator, receiver, &buf);
            return .{ .ok = .{ .String = try runtime.strInitOwned(allocator, try buf.toOwnedSlice(allocator)) } };
        }
    }
    // A bound or qualified callable reference (`v::m`, `V::m`, `Foo::ext`)
    // compares by name, receiver and adaptation, and hashes the same way.
    if (host_fields.boundRefParts(receiver)) |mine| {
        if (args.len == 1 and std.mem.eql(u8, name, "equals")) {
            const other = host_fields.boundRefParts(&args[0]) orelse return .{ .ok = boolVal(false) };
            if (!std.mem.eql(u8, mine.name, other.name) or !std.mem.eql(u8, mine.adapt, other.adapt)) return .{ .ok = boolVal(false) };
            return .{ .ok = boolVal(try builtin_members.deepValueEquals(self, allocator, &mine.receiver, &other.receiver)) };
        }
        if (args.len == 0 and std.mem.eql(u8, name, "hashCode")) {
            var h: i32 = builtin_members.javaStringHash(mine.name);
            h = h *% 31 +% try builtin_members.hashWithDispatch(self, allocator, &mine.receiver);
            h = h *% 31 +% builtin_members.javaStringHash(mine.adapt);
            return .{ .ok = Value.newInt(@as(i64, h)) };
        }
    }
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
            const annotation = cg.get().is_annotation;
            cg.deinit();
            g.deinit();
            if (annotation) {
                return .{ .ok = boolVal(try annotationInstanceEquals(self, allocator, inst, &args[0])) };
            }
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
    ir.eval.dispatchNote(.served_intrinsic);
    runtime.prof.opRoute(6);
    // A declared lambda-taking overload the intrinsic surface cannot
    // express wins resolution; decline so the walk's extension fallback
    // runs its body (declaration decides, the registry only serves).
    if (declaredLambdaOverloadWins(self, name, args)) return null;
    const type_fqn = receiver.typeFqn();
    // Resolution cache: the winning intrinsic (or "none") is a pure function
    // of (type, name, args-empty), so memoize it and skip the per-call probe
    // building + repeated `lookupIntrinsic` borrows. A non-Instance receiver
    // keys by its (static) type-fqn pointer. An Instance's typeFqn is not
    // class-specific, so it keys by class-cell identity instead — the same
    // identity `host_has_member_cache` uses, and everything the uncached body
    // consults for an Instance (hostHasMember, the shadow probes) is a
    // function of the class, not the individual instance. Array builders use
    // a different (no-prepend) dispatch and are excluded.
    // The resolution cache is keyed by exactly what decides the answer — the
    // receiver's class (or its static type-fqn), the name, and whether the
    // call has arguments — so it is probed FIRST. Everything that decides
    // whether an entry may be STORED (`isArrayBuilder`, and the top-level
    // extension probe, which borrows the module and hashes the name) is a
    // pure function of the same inputs, so a hit already proves it; computing
    // it ahead of the probe put a module borrow and a name-index lookup on
    // every intrinsic member dispatch.
    const name_p_opt = memberNameIdentity(self, name);
    if (name_p_opt) |name_p| {
        const type_p: usize = if (receiver.* == .Instance) blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            break :blk g.get().class.identity();
        } else @intFromPtr(type_fqn.ptr);
        const key: root_mod.ProgramImage.MemberResolveKey = .{
            .type_p = type_p,
            .name_p = name_p,
            .args_empty = args.len == 0,
        };
        // File-qualified sibling key: when an imported pack extension shadows
        // the stdlib surface the answer is a function of the call site's
        // import scope and the call's arity too, so those resolutions cache
        // under (file+1, argc) rather than not at all (`writable` /
        // `withCurrent` on a snapshot record re-ran the whole ladder tens of
        // thousands of times per state-list stress rep).
        const key_f: ?root_mod.ProgramImage.MemberResolveKey = blk: {
            const sp = ir.eval.currentCallSiteSpan() orelse break :blk null;
            var k = key;
            k.file = @as(u32, @intFromEnum(sp.file)) + 1;
            k.argc = @intCast(args.len);
            break :blk k;
        };
        // Thread-local L1 (see `tl_method_cache`): a hit avoids the shared
        // program cell's reader lock and its cross-core coherence traffic.
        for ([2]?root_mod.ProgramImage.MemberResolveKey{ key, key_f }) |k_opt| {
            const k = k_opt orelse continue;
            const e = &tl_resolve_cache[tlResolveSlot(k)];
            if (tlResolveMatch(e, k)) {
                if (e.state == 1) return null;
                return try dispatchWithReceiver(self, allocator, e.fqn, e.func.?, receiver, args);
            }
        }
        for ([2]?root_mod.ProgramImage.MemberResolveKey{ key, key_f }) |k_opt| {
            const k = k_opt orelse continue;
            const hit: ?root_mod.ProgramImage.MemberResolveEntry = blk: {
                const pg = self.prog.borrow();
                defer pg.deinit();
                break :blk pg.get().member_resolve_cache.get(k);
            };
            if (hit) |entry| {
                tlResolveStore(k, entry);
                const func = entry.func orelse return null;
                return try dispatchWithReceiver(self, allocator, entry.fqn, func, receiver, args);
            }
        }
        const cacheable = !stdlib.isArrayBuilder(name) and
            !(try userToplevelExtNamedExists(self, allocator, receiver, name));
        return try stdlibMemberDispatchUncached(self, allocator, receiver, name, args, type_fqn, if (cacheable) key else null, if (cacheable) key_f else null);
    }
    return try stdlibMemberDispatchUncached(self, allocator, receiver, name, args, type_fqn, null, null);
}

fn stdlibMemberDispatchUncached(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, type_fqn: []const u8, cache_key: ?root_mod.ProgramImage.MemberResolveKey, cache_key_file: ?root_mod.ProgramImage.MemberResolveKey) Allocator.Error!?EvalResult {
    if (runtime.envOnce("KLIO_SDU_TRACE") != null)
        std.debug.print("[sdu] type={s} name={s} cacheable={}\n", .{ type_fqn, name, cache_key != null });
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
        if (pack_ext_shadow == .none) cache_key else cache_key_file;
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
            // `Int.or(NodeKind)` overload, and `String.repeat(Int)` cannot
            // capture a bare `repeat(times) { … }` reaching a String through
            // the enclosing-receiver walk.
            if (stdlib.implementationApplicable(probe, args)) |applies| {
                if (!applies) continue;
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
        return .{ .ok = try Value.newList(allocator, .{ .items = items, .mutable = false, .backing = null }) };
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
        const fresh = try Value.newList(allocator, .{ .items = items, .mutable = true, .backing = null });
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
fn isMemberExtFid(self: *VmHost, fid: FuncId) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    return isMemberExt(mg.get(), fid);
}

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
    if (missTraceEnv() != null) {
        if (mod.funcById(fid)) |f| {
            if (missTraceWant(f.name)) std.debug.print("[priv-hidden] {s} decl_file={d} site_file={d} hidden={} exec={s}\n", .{ f.name, decl_file.int(), sp.file.int(), sp.file.int() != decl_file.int(), if (ir.eval.currentFrameFunc()) |cf| (if (cf.fqn.len != 0) cf.fqn else cf.name) else "<none>" });
        }
    }
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

fn memberExtVisible(self: *VmHost, mod: *const Module, fid: FuncId, visible_owners: *const OwnerSet) bool {
    if (!isMemberExt(mod, fid)) return true;
    const owner = mod.registry.member_ext_owner_class.get(fid) orelse return true;
    if (nuTraceEnv()) |want| {
        if (funcAt(mod, fid)) |f| {
            if (std.mem.eql(u8, f.name, want) or std.mem.eql(u8, want, "1")) {
                std.debug.print("[mev] fid={d} owner={s} vis={}\n", .{ fid.int(), owner, visible_owners.contains(owner) });
                std.debug.print("[mev] receivers:", .{});
                for (visible_owners.sig[0..visible_owners.n]) |p| {
                    const cd: *const ClassDef = @ptrFromInt(p);
                    std.debug.print(" {s}", .{cd.fqn});
                }
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
    const runtime_owner = if (mod.classIdByFqn(owner)) |id|
        mod.classes.items[id.int()].name
    else
        owner;
    const sups: []const []const u8 = blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        const d = g.get().get(runtime_owner) orelse break :blk &.{};
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
    return memberExtOwnerObjectClass(self, owner) != null;
}

/// Exact class identity for an object/companion member-extension owner.
fn memberExtOwnerObjectClass(self: *VmHost, owner: []const u8) ?ir.ClassId {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const id = mod.classIdByFqn(owner) orelse return null;
    if (id.int() >= mod.classes.items.len or !mod.classes.items[id.int()].is_object) {
        return null;
    }
    return id;
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
    const dbg = blk: {
        const S = struct {
            var cached: ?bool = null;
        };
        if (S.cached) |b| break :blk b;
        const b = runtime.envOnce("KLIO_SHADOW_TRACE") != null;
        S.cached = b;
        break :blk b;
    };
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

/// The member EXTENSION named `name` with `nparams` parameters that
/// `receiver`'s class declares or inherits, most-derived first. Answers from
/// the module's per-class member index, so a bare member-extension dispatch
/// costs a walk of the receiver's own supertypes instead of a scan of every
/// same-named declaration in the program.
const MEXT_OVERRIDE_MAX = 4;
const MextOverrideEntry = struct {
    cls: u64 = 0,
    name_p: usize = 0,
    nparams: u32 = 0,
    n: u32 = 0,
    fids: [MEXT_OVERRIDE_MAX]u32 = @splat(0),
    valid: bool = false,
};
const MEXT_OVERRIDE_SLOTS = 1024;
threadlocal var mext_override_cache: [MEXT_OVERRIDE_SLOTS]MextOverrideEntry = @splat(.{});

/// The member EXTENSIONS named `name` with `nparams` parameters that
/// `receiver`'s class declares or inherits, most-derived first (at most
/// `out.len`). Answers from the module's per-class member index behind a
/// direct-mapped per-thread cache, so a repeated bare member-extension
/// dispatch — the changelist executes one operation per node update — costs
/// a probe instead of a scan over every same-named declaration in the
/// program. Returns how many entries of `out` were written.
pub fn memberExtOverridesFor(self: *VmHost, receiver: *const Value, name: []const u8, nparams: usize, out: []ir.FuncId) usize {
    if (receiver.* != .Instance) return 0;
    const cls_id: u64 = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        break :blk @intCast(g.get().class.identity());
    };
    const slot = (cls_id ^ (@intFromPtr(name.ptr) >> 3) ^ (nparams *% 0x9E37)) & (MEXT_OVERRIDE_SLOTS - 1);
    const e = mext_override_cache[slot];
    if (e.valid and e.cls == cls_id and e.name_p == @intFromPtr(name.ptr) and e.nparams == nparams) {
        const n = @min(e.n, out.len);
        for (0..n) |i| out[i] = @enumFromInt(e.fids[i]);
        return n;
    }
    var found: [MEXT_OVERRIDE_MAX]ir.FuncId = @splat(@enumFromInt(0));
    const n = memberExtOverrideLookup(self, receiver, name, nparams, &found);
    var entry = MextOverrideEntry{
        .cls = cls_id,
        .name_p = @intFromPtr(name.ptr),
        .nparams = @intCast(nparams),
        .n = @intCast(n),
        .valid = true,
    };
    for (0..n) |i| entry.fids[i] = @intCast(found[i].int());
    mext_override_cache[slot] = entry;
    const m = @min(n, out.len);
    for (0..m) |i| out[i] = found[i];
    return m;
}

fn memberExtOverrideLookup(self: *VmHost, receiver: *const Value, name: []const u8, nparams: usize, out: []ir.FuncId) usize {
    const a = self.allocator;
    var closure: std.ArrayList(*const ClassDef) = .empty;
    defer closure.deinit(a);
    var seen: std.ArrayList(*const ClassDef) = .empty;
    defer seen.deinit(a);
    {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        collectClassClosure(g.get().class.asPtr(), &closure, &seen, a);
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    var n: usize = 0;
    for (closure.items) |cd| {
        for ([2][]const u8{ cd.fqn, cd.name }) |owner| {
            if (owner.len == 0) continue;
            for (mod.memberDecls(owner, name)) |fid| {
                const fp = mod.funcById(fid) orelse continue;
                if (fp.kind != .member_extension) continue;
                if (fp.params.len != nparams) continue;
                if (fp.params.len == 0 or !std.mem.eql(u8, fp.params[0].name, "this")) continue;
                // Pack functions are lazy-bodied: an unensured declaration
                // reports no body and silently vanished from the pick
                // (foundation-layout's Density.targetConstraints getter
                // fell through to an unresolved global). Ensure first.
                if (fp.blocks.len == 0) _ = mod.ensureFuncBody(@constCast(fp));
                if (!fp.hasBody()) continue;
                var dup = false;
                for (out[0..n]) |seen_fid| {
                    if (seen_fid.int() == fid.int()) dup = true;
                }
                if (dup) continue;
                out[n] = fid;
                n += 1;
                if (n == out.len) return n;
            }
            if (std.mem.eql(u8, cd.fqn, cd.name)) break;
        }
    }
    return n;
}

/// Set of class names (with the full supertype closure — superclasses AND
/// interfaces) reachable through the enclosing-this chain, including each
/// instance's `outer` links, and through the executing frames' own
/// receivers, which the dynamic chain does not carry (an extension body
/// binds its receiver in `params[0]`, never by pushing it; inside
/// `ColumnMeasurePolicy.measure(MeasureScope)` the `MeasureScope` is a
/// `Density`, which is what makes `Dp.roundToPx()` visible there).
///
/// Held as the chain's class identities; a membership probe asks each
/// class's memoized closure-name set (`classClosureNames`). An extension
/// call whose candidates include a member-extension is never served by the
/// inline cache, so it asks for this set on every call, and building it —
/// a closure walk per receiver plus a fresh hash map of every name — grew
/// with the nesting depth of the composition it ran in. Nothing is
/// allocated per call now beyond the chain snapshot.
const OwnerSet = struct {
    sig: [OWNER_SIG_MAX]usize = @splat(0),
    n: u32 = 0,
    /// The walked set for a chain longer than `sig` holds.
    owned: ?std.StringHashMap(void) = null,
    fn contains(self: *const OwnerSet, key: []const u8) bool {
        if (self.owned) |*m| return m.contains(key);
        for (self.sig[0..self.n]) |p| {
            if (classClosureNames(@ptrFromInt(p)).contains(key)) return true;
        }
        return false;
    }
    fn deinit(self: *OwnerSet) void {
        if (self.owned) |*m| m.deinit();
    }
    fn add(self: *OwnerSet, cls: usize) bool {
        for (self.sig[0..self.n]) |p| if (p == cls) return true;
        if (self.n == OWNER_SIG_MAX) return false;
        self.sig[self.n] = cls;
        self.n += 1;
        return true;
    }
};
const OWNER_SIG_MAX = 48;
/// One memoized closure-name set. Class definitions are arena-backed and
/// immutable after linking, so the set is built once per class for the
/// process and shared; the entry is validated by the class's `fqn` slice,
/// which keeps it sound should a definition's address ever be reused.
const ClosureNamesEntry = struct { fqn_p: usize, fqn_len: usize, set: *const std.StringHashMap(void) };
const ClosureNamesFront = struct { cls: usize = 0, fqn_p: usize = 0, fqn_len: usize = 0, set: ?*const std.StringHashMap(void) = null };
const CLOSURE_NAMES_FRONT_SLOTS = 512;
threadlocal var closure_names_front: [CLOSURE_NAMES_FRONT_SLOTS]ClosureNamesFront = @splat(.{});
var closure_names_lock = std.atomic.Value(bool).init(false);
var closure_names_map: ?std.AutoHashMap(usize, ClosureNamesEntry) = null;
fn classClosureNames(cls: *const ClassDef) *const std.StringHashMap(void) {
    const key = @intFromPtr(cls);
    const fqn_p = @intFromPtr(cls.fqn.ptr);
    const front = &closure_names_front[((key *% 0x9E3779B97F4A7C15) >> 32) % CLOSURE_NAMES_FRONT_SLOTS];
    if (front.cls == key and front.fqn_p == fqn_p and front.fqn_len == cls.fqn.len) {
        if (front.set) |s| return s;
    }
    const pa = std.heap.page_allocator;
    while (closure_names_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer closure_names_lock.store(false, .release);
    if (closure_names_map == null) closure_names_map = .init(pa);
    const map = &closure_names_map.?;
    const set: *const std.StringHashMap(void) = blk: {
        if (map.get(key)) |e| {
            if (e.fqn_p == fqn_p and e.fqn_len == cls.fqn.len) break :blk e.set;
        }
        const s = pa.create(std.StringHashMap(void)) catch @panic("out of memory");
        s.* = .init(pa);
        var closure: std.ArrayList(*const ClassDef) = .empty;
        defer closure.deinit(pa);
        var seen: std.ArrayList(*const ClassDef) = .empty;
        defer seen.deinit(pa);
        collectClassClosure(cls, &closure, &seen, pa);
        for (closure.items) |cd| {
            s.put(cd.name, {}) catch {};
            s.put(cd.fqn, {}) catch {};
        }
        map.put(key, .{ .fqn_p = fqn_p, .fqn_len = cls.fqn.len, .set = s }) catch {};
        break :blk s;
    };
    front.* = .{ .cls = key, .fqn_p = fqn_p, .fqn_len = cls.fqn.len, .set = set };
    return set;
}
fn enclosingOwnerSet(self: *VmHost, allocator: Allocator) Allocator.Error!OwnerSet {
    var out: OwnerSet = .{};
    var overflow = false;
    {
        const chain = try enclosingThisChain(self, allocator);
        defer allocator.free(chain);
        for (chain) |v| {
            var cur: ?Value = v;
            while (cur) |cv| {
                if (cv != .Instance) break;
                const g = cv.Instance.borrow();
                const cls = @intFromPtr(g.get().class.asPtr());
                const outer = g.get().outer;
                g.deinit();
                if (!out.add(cls)) overflow = true;
                cur = outer;
            }
        }
        var fit = ir.eval.frameThisChainIter();
        while (fit.next()) |fv| {
            var cur: ?Value = fv;
            while (cur) |cv| {
                if (cv != .Instance) break;
                const g = cv.Instance.borrow();
                const cls = @intFromPtr(g.get().class.asPtr());
                const outer = g.get().outer;
                g.deinit();
                if (!out.add(cls)) overflow = true;
                cur = outer;
            }
        }
    }
    if (!overflow) return out;
    out.owned = try enclosingOwnerSetWalk(self, allocator);
    return out;
}
/// The walked form of `enclosingOwnerSet`: every closure name of every
/// receiver in scope, in one caller-owned map.
fn enclosingOwnerSetWalk(self: *VmHost, allocator: Allocator) Allocator.Error!std.StringHashMap(void) {
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
            if (cv != .Instance) break;
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
        }
    }
    var fit = ir.eval.frameThisChainIter();
    while (fit.next()) |fv| {
        var cur: ?Value = fv;
        while (cur) |cv| {
            if (cv != .Instance) break;
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
/// The delegate a `by` clause makes responsible for `name`, or null when the
/// receiver answers it itself.
///
/// Kotlin generates a forwarding member for EVERY member of a delegated
/// interface the class does not override — including members the interface
/// supplies a default body for. Resolution reaches an inherited default first,
/// so without this the default runs against the wrapper and the delegate is
/// never consulted (`SerialDescriptor.annotations` has a default body, and a
/// `ContextDescriptor(original) : SerialDescriptor by original` reported the
/// empty default instead of the wrapped descriptor's annotations).
pub fn interfaceDelegateFor(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8) ?Value {
    var has_delegate = false;
    {
        const g = inst.borrow();
        defer g.deinit();
        for (g.get().fields.items) |f| {
            if (std.mem.startsWith(u8, f.name, "__delegate__")) {
                has_delegate = true;
                break;
            }
        }
    }
    if (!has_delegate) return null;
    // A member the receiver's own class chain declares is not forwarded —
    // that is exactly the `override` the compiler skips generating for.
    if (concreteChainDeclares(self, allocator, inst, name)) return null;
    const g = inst.borrow();
    defer g.deinit();
    for (g.get().fields.items) |f| {
        if (!std.mem.startsWith(u8, f.name, "__delegate__")) continue;
        const iface = f.name["__delegate__".len..];
        if (delegatedInterfaceDeclares(self, allocator, inst, iface, name) != true) continue;
        return f.value;
    }
    return null;
}

/// Whether the anon-method table holds a member `name` for `class_name`, at
/// any arity or as an accessor. Entries are keyed `class\x1fname#arity` and
/// `class\x1fname`, so a prefix scan answers "declared at all".
fn anonClassDeclares(self: *VmHost, allocator: Allocator, class_name: []const u8, name: []const u8) bool {
    const tbl = self.anon_methods.borrow();
    defer tbl.deinit();
    if (tbl.get().count() == 0) return false;
    var kb: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ class_name, name }) catch {
        const p = anonKey(allocator, class_name, name) catch return false;
        defer allocator.free(p);
        return anonTableHasPrefix(tbl.get(), p);
    };
    return anonTableHasPrefix(tbl.get(), prefix);
}

fn anonTableHasPrefix(tbl: anytype, prefix: []const u8) bool {
    if (tbl.get(prefix) != null) return true;
    var it = tbl.keyIterator();
    while (it.next()) |k| {
        if (!std.mem.startsWith(u8, k.*, prefix)) continue;
        // Either an exact hit or the `name#arity` form — never a longer name.
        if (k.len == prefix.len or k.*[prefix.len] == '#') return true;
    }
    return false;
}

/// Whether the receiver's own CLASS chain (never its interfaces) declares
/// `name`. An interface's own body is exactly what a `by` clause replaces; a
/// class's is an `override`, which the compiler honours over the delegate.
fn concreteChainDeclares(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8) bool {
    {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        for (cg.get().primary_params) |*p| {
            if (p.property != null and std.mem.eql(u8, p.name, name)) return true;
        }
        for (cg.get().body_properties) |*p| {
            if (std.mem.eql(u8, p.name, name)) return true;
        }
    }
    // An anonymous / local class keeps its members in the anon-method table
    // rather than on its `ClassDef`, and `object : I by d { override … }` is
    // the shape that most often carries the override.
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        const class_name = cg.get().name;
        const is_anon = cg.get().is_anonymous;
        const found = is_anon and anonClassDeclares(self, allocator, class_name, name);
        cg.deinit();
        g.deinit();
        if (found) return true;
    }
    const cls = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    defer cls.deinit();
    if (ClassDef.findMethod(cls, allocator, name)) |hit| {
        const cg = hit.class.borrow();
        const from_class = !cg.get().is_interface;
        cg.deinit();
        hit.class.deinit();
        if (from_class) return true;
    }
    // The runtime class def carries only what the class body lowered; the
    // module's class table is the authority on which declaration owns a
    // method, so walk the CLASS supertypes there too.
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    var cur: ?ir.ClassId = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk module.classIdByFqn(cg.get().fqn) orelse module.classId(cg.get().name);
    };
    var hops: u8 = 0;
    while (cur) |cid| : (hops += 1) {
        if (hops > ClassDef.MAX_WALK or cid.int() >= module.classes.items.len) break;
        const c = &module.classes.items[cid.int()];
        if (c.is_interface) break;
        for (c.methods) |mfid| {
            const f = module.funcById(mfid) orelse continue;
            if (std.mem.eql(u8, f.name, name)) return true;
        }
        cur = null;
        for (c.supertypes) |sid| {
            if (sid.int() >= module.classes.items.len) continue;
            if (module.classes.items[sid.int()].is_interface) continue;
            cur = sid;
            break;
        }
    }
    return false;
}

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

/// Extension-fn resolution with scope-aware memoization. The winner (or a
/// confirmed miss) is a pure function of (receiver identity, name, arg sig,
/// static/declared scope, strict-probe bit) whenever no member-extension
/// competes for the name — member-extension applicability depends on the
/// enclosing-`this` chain, so `saw_member_ext` vetoes the store both ways.
/// The strict bare-name probe folds a scope bit rather than being excluded:
/// bare accessor calls inside engine methods took the full candidate walk on
/// every single call (half of a recompose workload's runtime), and a walk
/// MISS memoizes as METHOD_MISS so non-extension calls stop re-walking.
/// Serve a memoized MEMBER-EXTENSION winner: re-find its owner on the
/// enclosing chain and invoke it with that owner pushed, exactly as the walk
/// does. The cache entry is keyed by the chain SHAPE, so the owner sits at
/// the same position with the same class; only the instance differs per
/// call. Declines (null) whenever the shape is not the plain one the walk
/// resolved, and the caller re-walks.
fn serveCachedMemberExt(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, args: []const Value) Allocator.Error!?EvalResult {
    const mg = self.module.borrow();
    const mod = mg.get();
    const f = funcAt(mod, fid) orelse {
        mg.deinit();
        return null;
    };
    if (!f.hasBody() or f.params.len != args.len + 1) {
        mg.deinit();
        return null;
    }
    const owner = mod.registry.member_ext_owner_class.get(fid) orelse {
        mg.deinit();
        return null;
    };
    const inst_opt = memberExtOwnerInstance(self, allocator, receiver, owner) catch {
        mg.deinit();
        return null;
    };
    const inst = inst_opt orelse {
        mg.deinit();
        return null;
    };
    if (inst != .Instance) {
        mg.deinit();
        return null;
    }
    const all = try prependReceiver(allocator, receiver, args);
    defer if (runtime.freeScratch()) allocator.free(all);
    ir.eval.pushEnclosing(&inst);
    const r = try callFuncRec(self, allocator, mod, fid, all);
    ir.eval.popEnclosing();
    mg.deinit();
    return r;
}

pub fn extFbCounts() [4]u64 {
    return .{ ext_fb_total, ext_fb_plain_hit, ext_fb_chain_hit, ext_fb_walk };
}

pub var ext_fb_total: u64 = 0;
pub var ext_fb_plain_hit: u64 = 0;
pub var ext_fb_chain_hit: u64 = 0;
pub var ext_fb_walk: u64 = 0;

fn extensionFnFallback(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8, declared_recv: ?[]const u8) Allocator.Error!?EvalResult {

    runtime.prof.opRoute(3);
    ext_fb_total += 1;
    var cache_key: ?root_mod.ProgramImage.InstanceMethodKey =
        instanceMethodKeyScoped(self, receiver, name, args, static_recv, declared_recv);
    if (cache_key != null and strict_ext) {
        cache_key.?.sig ^= 0xA5A5_5A5A_C0DE_F00D;
        if (cache_key.?.sig == 0) cache_key.?.sig = 1;
    }
    if (cache_key) |k| {
        if (extMethodCacheGet(self, k)) |fid| {
            ext_fb_plain_hit += 1;
            if (fid == METHOD_MISS) return null;
            if (missTraceWant(name)) std.debug.print("[extfb] PLAIN-HIT fid={d} name={s} member_ext={}\n", .{ fid, name, isMemberExtFid(self, @enumFromInt(fid)) });
            if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(fid), args)) |r| return r;
        }
    }
    // Chain-folded key: when a member-extension competes for the name the
    // resolution is a pure function of (key, enclosing-chain shape) instead
    // of the key alone. Folding the chain hash keys those calls too — but
    // only PLAIN winners (a top-level pick, no owner push) and misses store
    // under it; a member-extension winner needs its owner-instance push and
    // stays walk-resolved.
    const chain_key: ?root_mod.ProgramImage.InstanceMethodKey = blk: {
        var ck = cache_key orelse break :blk null;
        ck.sig ^= ir.eval.enclosingChainClassHash() *% 0x9E3779B97F4A7C15;
        if (ck.sig == 0) ck.sig = 2;
        break :blk ck;
    };
    if (chain_key) |k| {
        if (extMethodCacheGet(self, k)) |fid| {
            ext_fb_chain_hit += 1;
            if (fid == METHOD_MISS) return null;
            const f: FuncId = @enumFromInt(fid);
            if (isMemberExtFid(self, f)) {
                if (try serveCachedMemberExt(self, allocator, receiver, f, args)) |r| return r;
            } else if (try invokeMethodFuncId(self, allocator, receiver, f, args)) |r| return r;
        }
    }
    var saw_member_ext = false;
    if (runtime.envSetOnce("KLIO_WALK_TRACE")) {
        std.debug.print("[extfb-walk] {s} on {s} strict={} static={s} keyed={}\n", .{ name, receiver.typeFqn(), strict_ext, static_recv orelse "-", cache_key != null });
    }
    ext_fb_walk += 1;
    const r = try extensionFnFallbackWalk(self, allocator, receiver, name, args, strict_ext, static_recv, declared_recv, cache_key, chain_key, &saw_member_ext);
    if (r == null) {
        if (!saw_member_ext) {
            if (cache_key) |k| extMethodCachePut(self, k, METHOD_MISS);
        } else if (chain_key) |k| {
            extMethodCachePut(self, k, METHOD_MISS);
        }
    }
    return r;
}

/// The full extension-candidate walk. `cache_key` is the scope-folded key the
/// shell computed (null = uncacheable call); `saw_member_ext_out` reports
/// whether any candidate was a member-extension, which makes the resolution
/// context-dependent and vetoes both positive and negative memoization.
fn extensionFnFallbackWalk(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8, declared_recv: ?[]const u8, cache_key: ?root_mod.ProgramImage.InstanceMethodKey, chain_key: ?root_mod.ProgramImage.InstanceMethodKey, saw_member_ext_out: *bool) Allocator.Error!?EvalResult {
    var bound_thinned = false;
    ir.eval.callStatsProbe(name);
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
        std.debug.print("[extfb] ENTRY strict={} nargs={d} recv={s} static={s} declared={s}\n", .{
            strict_ext, args.len, rk, static_recv orelse "-", declared_recv orelse "-",
        });
    }

    // Inline-cache fast path. A prior *owner-independent* resolution of this
    // (receiver class, name, arg types) to a top-level extension dispatches
    // straight through `callFuncRec`, skipping the candidate collection, the
    // enclosing-owner set allocation, and the filter/score passes below —
    // the dominant cost of extension-heavy hot loops. Only keyed when no
    // receiver override is in play (a static/declared receiver, or the strict
    // bare-name probe, can resolve the same names differently).
    // A `declared_recv`-directed call keys with the scope FOLDED into the
    // sig (`instanceMethodKeyScoped`): its resolution is a pure function of
    // (receiver identity, name, arg-sig, declared scope), so it caches
    // apart from the unscoped call — never served one, never serves one.
    // The hot coroutine boundary (`fn.startCoroutineUninterceptedOrReturn`
    // lowered with declared receiver `Function1`) re-walked per call when
    // any declared scope disabled the key outright.
    var visible_owners = try enclosingOwnerSet(self, allocator);
    defer visible_owners.deinit();

    // Whether any candidate for this name is a member-extension (its
    // visibility/selection depends on the enclosing-`this` chain). When one
    // exists the resolution is context-dependent and must not be cached.
    saw_member_ext_out.* = false;

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        const mtrace = if (missTraceEnv()) |w| std.mem.eql(u8, w, name) else false;
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
                    .IrClosure => true,
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
            if (isMemberExt(mod, fid)) saw_member_ext_out.* = true;
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
            if (receiverViolatesTypeParamBound(self, c.fid, &c.func.params[0].ty, receiver)) {
                if (missTraceWant(name)) std.debug.print("[extfb]  fid={d} strict bound-thinned\n", .{c.fid.int()});
                bound_thinned = true;
                continue;
            }
            if (!extArityApplicableTL(self, &c.func, want, args.len != 0 and isCallable(&args[args.len - 1]))) {
                if (missTraceWant(name)) std.debug.print("[extfb]  fid={d} strict arity nparams={d} want={d}\n", .{ c.fid.int(), c.func.params.len, want });
                continue;
            }
            const strict_lam_disproof = blk_sld: {
                if (c.func.params.len < 2) break :blk_sld false;
                for (args, 0..) |*av, ai| {
                    const pi = ai + 1;
                    if (pi >= c.func.params.len) break;
                    if (closureParamsDisproveFnParam(self, &c.func.params[pi].ty, av)) break :blk_sld true;
                }
                break :blk_sld false;
            };
            if (strict_lam_disproof) {
                if (missTraceWant(name)) std.debug.print("[extfb]  fid={d} strict lambda-param-disproof\n", .{c.fid.int()});
                continue;
            }
            if (candidateArgsDisproven(self, &c.func, args)) {
                if (missTraceWant(name)) std.debug.print("[extfb]  fid={d} strict args-disproven\n", .{c.fid.int()});
                continue;
            }
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
        if (missTraceWant(name)) std.debug.print("[extfb] strict survivors={d}\n", .{candidates.items.len});
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
                    bound_thinned = true;
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
                    // The RUNTIME receiver proving the declared receiver type
                    // outranks a mismatched static hint: an explicit
                    // `this.SimulatedIf(...)` inside a headerless receiver
                    // lambda carries the ENCLOSING scope's declared receiver
                    // (CompositionTestScope) while the value is the lambda's
                    // own MockViewListValidator — a proven subtype match must
                    // not be refused on that stale evidence.
                    const self_repick = blk: {
                        const cf = ir.eval.currentFrameFunc() orelse break :blk false;
                        break :blk cf.id.int() == c.fid.int();
                    };
                    // A class-value receiver (`TopE.serializer()`) records the
                    // CLASS as its declared receiver, but the value flowing in
                    // is a `KClass`. An extension declared on `KClass` is
                    // exactly what such a call binds, so the value's own
                    // reflection heads outrank the class-shaped hint.
                    const class_reflection_proves = receiver.* == .Class and
                        receiver.isRuntimeType(simpleName(rty.name));
                    const runtime_proves = !self_repick and
                        (committedExtReceiverProven(self, allocator, c.fid, receiver) or
                            class_reflection_proves);
                    if (!is_companion_recv and !runtime_proves and staticReceiverApplicable(self, allocator, dn, c.fid, rty) == false) {
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
    // A function-typed receiver's DECLARED head decides which member of a
    // same-named extension family binds. `suspend R.() -> T` lowers to
    // `Function0` (its receiver rides in the type args) while
    // `suspend (P) -> T` lowers to `Function1`; both are the same runtime
    // class, so nothing below can separate them, and the receiver form won
    // every call — `block.startCoroutineUninterceptedOrReturn(value, cont)`
    // on a `suspend (V) -> T` ran the block with `value` bound as `this`
    // and its value parameter left null.
    if (candidates.items.len > 1) {
        if (declared_recv) |dn| {
            if (std.mem.startsWith(u8, dn, "Function")) {
                var n_exact: usize = 0;
                for (candidates.items) |c| {
                    const rh = std.mem.trimEnd(u8, c.func.params[0].ty.name, "?");
                    if (std.mem.eql(u8, rh, dn)) n_exact += 1;
                }
                if (n_exact != 0 and n_exact != candidates.items.len) {
                    var filtered: std.ArrayList(Candidate) = .empty;
                    for (candidates.items) |c| {
                        const rh = std.mem.trimEnd(u8, c.func.params[0].ty.name, "?");
                        if (std.mem.eql(u8, rh, dn)) filtered.append(allocator, c) catch {};
                    }
                    candidates.deinit(allocator);
                    candidates = filtered;
                }
            }
        }
    }

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
            // The file tier orders TOP-LEVEL declarations only. A MEMBER
            // extension's scope level is its owner's position in the
            // implicit-receiver chain (the scorer's owner rank), not its
            // declaring file: `with(focusableNode) { applySemantics() }`
            // written in Clickable.kt must reach FocusableNode's override
            // in Focusable.kt over the enclosing node's own same-file
            // member — filtering by file inverted that into infinite
            // recursion. Skip the tier when every surviving candidate is
            // a member extension.
            var all_member_ext = true;
            for (candidates.items) |c| {
                if (!isMemberExt(smod, c.fid)) {
                    all_member_ext = false;
                    break;
                }
            }
            var same_file: usize = 0;
            for (candidates.items) |c| {
                const ds = smod.decl_span.get(c.fid.int()) orelse continue;
                if (ds.file.int() == sf.int()) same_file += 1;
            }
            if (!all_member_ext and same_file != 0 and same_file != candidates.items.len) {
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
            if (try runtimeMemberApplicability(self, allocator, &c.func, args, null, false) == null)
                unique_exact = null;
        }
    }

    if (missTraceWant(name)) std.debug.print("[extpick] n={d} unique_exact={}\n", .{ candidates.items.len, unique_exact != null });
    var chosen: ?Candidate = null;
    if (candidates.items.len <= 1) {
        chosen = if (candidates.items.len == 1) candidates.items[0] else null;
    } else if (unique_exact != null) {
        chosen = unique_exact;
    } else {
        chosen = try scoreExtCandidates(self, allocator, receiver, candidates.items, args);
    }
    if (missTraceWant(name)) std.debug.print("[extpick] chosen={?d}\n", .{if (chosen) |c| c.fid.int() else null});

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

    // Kotlin gives a receiver MEMBER precedence over any extension. When
    // bound refutation THINNED this walk's candidate set, a pick that used
    // to decline on a tie can newly commit — and `Iterable.contains`'s own
    // `if (this is Collection) return contains(element)` then re-enters
    // itself instead of reaching the List member. Scoped to the thinned
    // case so unarmed behavior is unchanged.
    // `range in range` never defers: the builtin `Range.contains` member
    // surface takes an ELEMENT, so a Range argument leaves the chosen
    // extension (`operator LongRange.contains(LongRange)`) as the only
    // applicable candidate — same predicate as the ladder's
    // `range_in_range` standdown.
    const member_could_take_args = !(receiver.* == .Range and args.len == 1 and
        args[0] == .Range and std.mem.eql(u8, name, "contains"));
    const defer_to_member = bound_thinned and member_could_take_args and
        receiverHasMemberNamed(self, receiver, name);
    if (!defer_to_property and !defer_to_iterable and !defer_to_member) {
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
        if (!pushed_owner) maybeWarnLenientExtBind(self, mod, c.fid);
        // Memoize an owner-independent pick: no member-extension competes for
        // this name and the winner is itself top-level, so the (receiver
        // class, name, arg types) key fully determines the target. When a
        // member-extension DID compete but lost to a top-level pick, the
        // chain-folded key captures the full resolution input instead. A
        // future call hits the fast path above and skips this whole
        // resolution.
        if (!pushed_owner) {
            if (!saw_member_ext_out.*) {
                if (cache_key) |k| extMethodCachePut(self, k, @intFromEnum(c.fid));
            } else if (chain_key) |k| {
                extMethodCachePut(self, k, @intFromEnum(c.fid));
            }
        } else if (sam_target == null and c.func.params.len == args.len + 1) {
            // A member-extension winner is owner-dependent, but the owner is
            // recovered from the chain at serve time and the key folds the
            // chain SHAPE, so the resolution is still a pure function of the
            // key. Without this every such call re-ran the whole ladder
            // (3.0us vs 0.37us for a plain member call).
            if (chain_key) |k| extMethodCachePut(self, k, @intFromEnum(c.fid));
        }
        const r = try callFuncRec(self, allocator, mod, c.fid, all);
        if (pushed_owner) ir.eval.popEnclosing();
        mg.deinit();
        return r;
    }
    return null;
}

/// Once-per-declaration guard for `maybeWarnLenientExtBind`.
var lenient_warned_mutex: runtime.SpinMutex = .{};
var lenient_warned: ?std.AutoHashMap(u32, void) = null;

/// The extension fallback bound a shipped pack's top-level extension for a
/// call whose file never imports it. Kotlin rejects that call (an extension
/// resolves only when imported or same-package), so the program runs on
/// klio's leniency alone — and the trailing lambdas of such calls lower
/// without their declared receiver, which surfaces later as baffling
/// unresolved bare members inside the handler. Say so once, with the exact
/// import to add. Quiet for pack-internal callers (their own resolution
/// legitimately spans a pack's packages) and for `kotlin.*` (default
/// imports).
fn maybeWarnLenientExtBind(self: *VmHost, mod: *const Module, fid: FuncId) void {
    _ = self;
    const f = funcAt(mod, fid) orelse return;
    if (f.package.len == 0) return;
    if (std.mem.eql(u8, f.package, "kotlin") or std.mem.startsWith(u8, f.package, "kotlin.")) return;
    if (!stdlib.isKnownPackage(f.package)) return;
    const sp = ir.eval.currentCallSiteSpan() orelse return;
    const caller_pkg = mod.packageOfFile(sp.file) orelse "";
    if (std.mem.eql(u8, caller_pkg, f.package)) return;
    if (caller_pkg.len != 0 and stdlib.isKnownPackage(caller_pkg)) return;
    if (mod.importWildcardIn(sp.file, f.package)) return;
    for (mod.importAliasPathsIn(sp.file, f.name)) |p| {
        if (std.mem.eql(u8, p.fqn, f.fqn)) return;
    }
    lenient_warned_mutex.lock();
    defer lenient_warned_mutex.unlock();
    if (lenient_warned == null) lenient_warned = std.AutoHashMap(u32, void).init(std.heap.page_allocator);
    const gop = lenient_warned.?.getOrPut(@intFromEnum(fid)) catch return;
    if (gop.found_existing) return;
    std.debug.print(
        "warning: `{s}` binds `{s}` without an import; add `import {s}` — kotlinc rejects the unimported call, and klio may type its lambda arguments incorrectly\n",
        .{ f.name, f.fqn, f.fqn },
    );
}

/// The lenient-bind warning prints once per function per PROGRAM RUN. The
/// memo is process-global, so an in-process harness running many programs
/// must reset it at each run boundary or later programs lose the warning
/// their pinned output carries.
pub fn resetLenientWarned() void {
    lenient_warned_mutex.lock();
    defer lenient_warned_mutex.unlock();
    if (lenient_warned) |*m| m.clearRetainingCapacity();
}

/// The instance serving as a member-extension's dispatch receiver: the
/// innermost enclosing receiver (including access entries pushed for this
/// dispatch) whose class hierarchy carries `owner`, else the explicit
/// receiver itself when it does.
pub fn memberExtOwnerInstance(self: *VmHost, allocator: Allocator, receiver: *const Value, owner: []const u8) Allocator.Error!?Value {
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    if (runtime.envOnce("KLIO_MEOI_TRACE")) |w| {
        if (std.mem.eql(u8, owner, w)) {
            std.debug.print("[meoi] owner={s} nentries={d}:", .{ owner, entries.len });
            for (entries) |e| {
                if (e.v == .Instance) {
                    const g = e.v.Instance.borrow();
                    const cg = g.get().class.borrow();
                    std.debug.print(" {s}={}", .{ cg.get().name, receiverImplementsOwnerIdentity(self, &e.v, owner) });
                    cg.deinit();
                    g.deinit();
                } else std.debug.print(" {s}", .{@tagName(e.v)});
            }
            std.debug.print("\n", .{});
        }
    }
    for (entries) |e| {
        if (e.v != .Instance) continue;
        if (receiverImplementsOwnerIdentity(self, &e.v, owner)) return e.v;
        // The owner may sit on the entry's class-nesting tower.
        if (!e.isSubject()) {
            var cur: ?Value = instanceOuterLink(&e.v);
            while (cur) |o| {
                if (o != .Instance) break;
                if (receiverImplementsOwnerIdentity(self, &o, owner)) return o;
                cur = instanceOuterLink(&o);
            }
        }
    }
    if (receiver.* == .Instance and
        receiverImplementsOwnerIdentity(self, receiver, owner)) return receiver.*;
    // The lexical receiver tower of the executing call stack: a getter
    // reached through nested lambdas (`placeable.mainAxisSize` inside a
    // `with(scope) { repeat { … } }` body) has its owner bound as an
    // outer frame's `this`, never on the dynamic enclosing chain.
    {
        const lex = try ir.eval.frameThisChainAlloc(allocator);
        defer allocator.free(lex);
        for (lex) |v| {
            if (v != .Instance) continue;
            if (receiverImplementsOwnerIdentity(self, &v, owner)) return v;
        }
    }
    // An `object`/companion owner is its own dispatch receiver: the
    // singleton is materializable from anywhere it can be imported.
    if (memberExtOwnerObjectClass(self, owner)) |owner_id| {
        if (host_globals.lookupGlobalById(
            self,
            allocator,
            null,
            owner_id,
            false,
        )) |sv| {
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
const ExtKey = [9]i32;

fn extKeyGreater(a: ExtKey, b: ExtKey) bool {
    inline for (0..a.len) |i| {
        if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
}

fn scoreExtCandidates(self: *VmHost, allocator: Allocator, receiver: *const Value, candidates: []const Candidate, args: []const Value) Allocator.Error!?Candidate {
    // [6] not [24]: safety builds 0xAA-fill the whole declared array per
    // entry; >6 args fall to the heap branch below (rare).
    var shapes_buf: [6]applicability.ArgShape = undefined;
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
        .exact_head = applicExactHeadCbM,
        .erased_integer_widths = true,
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
    var best_key: ExtKey = .{std.math.minInt(i32)} ** 9;
    for (candidates, 0..) |c, idx| {
        // The per-candidate ExtKey — applicability is Kotlin's hard gate
        // (`ext_key[0]`), then user-vs-shipped, subtype specificity, receiver
        // specificity, the numeric score, owner rank, parameter specificity,
        // and the stable lowest-FuncId discriminator.
        const applied = applicability.applicable(&all_sigs[idx], shapes, scope);
        if (candidates.len > 0 and missTraceWant(candidates[0].func.name)) {
            const mg = self.module.borrow();
            defer mg.deinit();
            const owner = mg.get().registry.member_ext_owner_class.get(c.fid) orelse "-";
            if (applied) |ap| {
                std.debug.print("[extscore] fid={d} owner={s} key={any}\n", .{ c.fid.int(), owner, ap.ext_key.? });
            } else {
                std.debug.print("[extscore] fid={d} owner={s} INAPPLICABLE\n", .{ c.fid.int(), owner });
            }
        }
        const key = (applied orelse continue).ext_key.?;
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
                for (closure.items) |cd| try v.append(allocator, cd.fqn);
                const outer = g.get().outer;
                g.deinit();
                cur = outer;
            } else break;
        }
    }
    return v;
}

/// A runtime-registered LOCAL class publishes its companion instance under
/// the `$companion:<name>` global at registration; a member call on the
/// class value forwards there.
fn localClassCompanionForward(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const cname: []const u8 = blk: {
        const cg = receiver.Class.borrow();
        defer cg.deinit();
        if (!cg.get().is_local_runtime) return null;
        break :blk cg.get().name;
    };
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "$companion:{s}", .{cname}) catch return null;
    const local_comp: ?Value = blk: {
        const g = self.globals.borrow();
        defer g.deinit();
        break :blk g.get().lookup(key);
    };
    const lc = local_comp orelse return null;
    if (lc != .Instance) return null;
    const r = try callMemberRec(self, allocator, &lc, name, args);
    if (r == .ok) return r;
    freeDispatchMiss(allocator, r);
    return null;
}

fn classCompanionForward(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const cls = receiver.Class;
    var cname: []const u8 = undefined;
    {
        const cg = cls.borrow();
        cname = cg.get().name;
        // An enum's synthetic statics (`values()`, `valueOf`, `entries`)
        // belong to the enum class, never to its companion — `Color.values()`
        // is legal with a companion present and must not forward there.
        if (cg.get().is_enum and (std.mem.eql(u8, name, "values") or std.mem.eql(u8, name, "valueOf") or std.mem.eql(u8, name, "entries"))) {
            cg.deinit();
            return null;
        }
        cg.deinit();
    }
    const simple = simpleName(cname);
    if (try localClassCompanionForward(self, allocator, receiver, name, args)) |r| return r;
    const cfqn: []const u8 = blk: {
        const cg = cls.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    const comp_name = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const comp = &mg.get().registry.companion_singletons;
        // Dotted fqn suffixes longest-first: a nested class with a
        // same-named cousin elsewhere resolves its OWN companion.
        var start: usize = 0;
        while (true) {
            if (comp.get(cfqn[start..])) |c| break :blk c;
            const dot = std.mem.indexOfScalarPos(u8, cfqn, start, '.') orelse break;
            start = dot + 1;
            // Never the bare simple name here: that key is a top-level
            // class's; the class's own name is tried next.
            if (std.mem.indexOfScalarPos(u8, cfqn, start, '.') == null) break;
        }
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
    var r = try callMemberNamedInner(self, allocator, receiver, name, args, arg_names, true, static_recv, false, null);
    // An ARG-BEARING call that got back its own CLASSIFIER (the class
    // value, or the companion instance, under the call's own name) did
    // not run anything — the dispatch fetched a reference. Kotlin never
    // calls a classifier reference: either a constructor applies (the
    // NewInstance path) or an outer candidate (the top-level factory
    // fn) wins. Refuse so the bare-name walk falls through — a KClass
    // tower candidate was swallowing `Constraints(minWidth = ...)`
    // (private-ctor value class + top-level factory) this way.
    if (r == .ok and args.len != 0) {
        const classifier_echo = switch (r.ok) {
            .Class => |c| blk: {
                const cg = c.borrow();
                defer cg.deinit();
                break :blk std.mem.eql(u8, cg.get().name, name);
            },
            .Instance => |inst| blk: {
                const g = inst.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                const fqn = cg.get().fqn;
                if (!std.mem.endsWith(u8, fqn, ".Companion")) break :blk false;
                const owner = fqn[0 .. fqn.len - ".Companion".len];
                const simple = if (std.mem.lastIndexOfScalar(u8, owner, '.')) |d| owner[d + 1 ..] else owner;
                break :blk std.mem.eql(u8, simple, name);
            },
            else => false,
        };
        if (classifier_echo) {
            r.ok.release(allocator);
            r = try unimplemented(allocator, "Vm::call_member `{s}` classifier echo refused", .{name});
        }
    }
    if (nuTraceEnv()) |w| {
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
    runtime.prof.opRoute(10);
    // Receiver-function-typed property invoked as a call (see
    // `recvFnFieldInvoke` on the static ladder): the stored lambda runs
    // with the owning instance as its receiver.
    if (try recvFnFieldInvoke(self, allocator, receiver, name, args)) |r| return r;
    // A member of a `by`-delegated interface the class does not override
    // belongs to the delegate, defaulted interface bodies included.
    if (receiver.* == .Instance and !strict_ext and !no_ext) {
        if (interfaceDelegateFor(self, allocator, receiver.Instance, name)) |d| {
            const r = try callMemberNamed(self, allocator, &d, name, args, arg_names_in);
            switch (r) {
                .ok => return r,
                .err => |e| if (e != .Unimplemented) return r else freeDispatchMiss(allocator, r),
            }
        }
    }
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

    // Unified named→positional rewrite: a cached binding permutation for
    // this exact (class, name, arg shape, name vector) reorders the args
    // once and enters the POSITIONAL ladder — every positional fast path
    // (member cache, native bindings, ext cache) then applies. The perm
    // can only exist because a prior call of this shape resolved through
    // a terminal whose earlier named arms had declined it.
    if (any_named and receiver.* == .Instance) {
        if (namedOrderKey(self, receiver, name, args, arg_names)) |k| {
            const tslot = &tl_perm_cache[tlSlot(k)];
            var perm: ?root_mod.ProgramImage.NamedPerm = null;
            if (tslot.raw_plus != 0 and tslot.gen == cacheGen() and tslot.class_p == k.class_p and tslot.name_p == k.name_p and
                tslot.sig == k.sig and tslot.n_args == k.n_args)
            {
                perm = tslot.perm;
            } else {
                const shared: ?root_mod.ProgramImage.NamedPerm = blk: {
                    const pg = self.prog.borrow();
                    defer pg.deinit();
                    break :blk pg.get().named_perm_cache.get(k);
                };
                if (shared) |p| {
                    tslot.* = .{ .class_p = k.class_p, .name_p = k.name_p, .n_args = k.n_args, .sig = k.sig, .raw_plus = 1, .gen = cacheGen(), .perm = p };
                    perm = p;
                }
            }
            if (perm) |p| {
                if (p.n != 0xFF and p.n <= args.len) {
                    var ok = true;
                    var buf: [15]Value = undefined;
                    for (0..p.n) |pi| {
                        if (p.src[pi] >= args.len) {
                            ok = false;
                            break;
                        }
                        buf[pi] = args[p.src[pi]];
                    }
                    if (ok) {
                        const r = try callMemberInnerStatic(self, allocator, receiver, name, buf[0..p.n], strict_ext, static_recv, no_ext, declared_recv);
                        // A positional-ladder MISS keeps the named ladder's
                        // own fallbacks (the hierarchy walk, the compose
                        // invoke completion) exactly as before the rewrite.
                        if (!(r == .err and r.err == .Unimplemented)) {
                            ir.eval.callStatsProbe("<named-perm-hit>");
                            return r;
                        }
                        freeDispatchMiss(allocator, r);
                    }
                }
            }
        }
    }

    // Named member-resolution memo: a prior walk pick for this exact
    // (class, name, arg shape, name vector) serves directly — the walk's
    // own terminal, with the self-delegation guard consulted at serve
    // time. The entry can only exist because every earlier named arm
    // declined the same shape when it was filled.
    if (any_named and receiver.* == .Instance) {
        if (namedMethodKey(self, receiver, name, args, arg_names)) |k| {
            if (extMethodCacheGet(self, k)) |raw| {
                if (raw != METHOD_MISS) {
                    const fid: FuncId = @enumFromInt(raw);
                    if (!walkActive(fid, receiverIdent(receiver))) {
                        if (try serveNamedFid(self, allocator, receiver, name, fid, args, arg_names)) |r| return r;
                    }
                }
            }
        }
    }

    // Stdlib intrinsic dispatch with named args.
    if (any_named) {
        ir.eval.callStatsProbe(name);
        if (try stdlibNamedDispatch(self, allocator, receiver, name, args, arg_names)) |r| {
            ir.eval.callStatsProbe("<named-stdlib-hit>");
            return r;
        }
        // Pack-installed host bindings take their arguments positionally; a
        // named call reaches them only after being put back in declaration
        // order.
        if (try instanceBindingNamedProbe(self, allocator, receiver, name, args, arg_names)) |r| {
            ir.eval.callStatsProbe("<named-binding-hit>");
            return r;
        }
    }

    // User extension / member fn with named args.
    if (any_named) {
        if (try userMethodNamed(self, allocator, receiver, name, args, arg_names)) |r| {
            ir.eval.callStatsProbe("<named-user-hit>");
            return r;
        }
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

    // Named companion-member forwarding for a class receiver
    // (`StringValues.build(caseInsensitiveName = true) { … }`): resolve the
    // companion singleton and re-enter the named ladder on it, so a named
    // argument can skip a leading defaulted parameter. A miss on the
    // singleton falls through to the positional ladder exactly as before.
    if (any_named and receiver.* == .Class) {
        const cg2 = receiver.Class.borrow();
        const cls_name = cg2.get().name;
        const cls_fqn = cg2.get().fqn;
        cg2.deinit();
        var comp_name: ?[]const u8 = null;
        {
            const mg = self.module.borrow();
            defer mg.deinit();
            const comp = &mg.get().registry.companion_singletons;
            comp_name = comp.get(cls_name) orelse comp.get(cls_fqn) orelse comp.get(simpleName(cls_fqn));
        }
        if (comp_name) |cn| {
            const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                .ok => |maybe| maybe,
                .err => |e| return .{ .err = e },
            };
            if (singleton) |s| if (s == .Instance) {
                const r = try callMemberNamedInner(self, allocator, &s, name, args, arg_names, strict_ext, null, no_ext, null);
                if (!(r == .err and r.err == .Unimplemented)) return r;
                freeDispatchMiss(allocator, r);
            };
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
    runtime.prof.opRoute(17);
    const primary = try callMemberInnerStatic(self, allocator, receiver, name, args, strict_ext, static_recv, no_ext, declared_recv);
    if (!(primary == .err and primary.err == .Unimplemented)) {
        // A NAMED call served by the positional fallback in its given
        // order: memoize the identity permutation so later calls of this
        // shape take the unified rewrite up front and skip the whole
        // named ladder (whose every arm just declined).
        if (any_named) ir.eval.callStatsProbe("<named-pos-hit>");
        // Any non-miss outcome (including thrown control flow — the
        // pausable machinery completes composable calls via throws)
        // proves the positional dispatch bound this order.
        if (any_named and receiver.* == .Instance and args.len <= 15) {
            if (namedOrderKey(self, receiver, name, args, arg_names)) |k| {
                var src: [15]u8 = @splat(0xFF);
                for (0..args.len) |i| src[i] = @intCast(i);
                const perm = root_mod.ProgramImage.NamedPerm{ .n = @intCast(args.len), .src = src };
                {
                    const pg = self.prog.borrowMut();
                    defer pg.deinit();
                    pg.get().named_perm_cache.put(k, perm) catch {};
                }
                tl_perm_cache[tlSlot(k)] = .{ .class_p = k.class_p, .name_p = k.name_p, .n_args = k.n_args, .sig = k.sig, .raw_plus = 1, .gen = cacheGen(), .perm = perm };
            }
        }
        return primary;
    }
    runtime.prof.opRoute(18);

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
    if (any_named) ir.eval.callStatsProbe("<named-miss>");
    // Compose ABI completion on the explicit `.invoke()` route — same
    // completion `callMember` applies (the two entries do not share a
    // miss tail).
    if (receiver.* == .Instance and std.mem.eql(u8, name, "invoke")) {
        if (compose.currentComposer()) |c| {
            if (instanceInvokeWantsPair(self, receiver, args.len)) {
                freeDispatchMiss(allocator, primary);
                var ext: std.ArrayList(Value) = .empty;
                defer ext.deinit(allocator);
                try ext.ensureTotalCapacityPrecise(allocator, args.len + 2);
                ext.appendSliceAssumeCapacity(args);
                ext.appendAssumeCapacity(c);
                ext.appendAssumeCapacity(.{ .Int = 0 });
                return callMemberInnerStatic(self, allocator, receiver, name, ext.items, strict_ext, static_recv, no_ext, declared_recv);
            }
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
        var shape_mismatch = false;
        for (args, 0..) |a, i| {
            const named: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
            if (named) |arg_name| {
                var matched = false;
                for (params, 0..) |p, pos| {
                    if (std.mem.eql(u8, p, arg_name)) {
                        slots[pos] = a;
                        matched = true;
                        break;
                    }
                }
                // A named argument this signature does not declare means the
                // call targets a DIFFERENT overload (the stdlib's internal
                // `indexOf(..., last = true)` reaching the public 3-param
                // table): silently dropping it truncated real arguments.
                if (!matched) shape_mismatch = true;
            } else {
                try positionals.append(allocator, a);
            }
        }
        if (shape_mismatch) continue;
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
        // Positional arguments beyond this signature's parameter count mean
        // the call targets a different overload; dropping them truncated
        // real arguments (the internal indexOf's ignoreCase flag).
        if (pit < positionals.items.len) continue;
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
    var bound_thinned = false;
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
            if (privateFnHiddenHere(self, mod, fid)) {
                if (missTraceWant(name)) std.debug.print("[extlocal] {s}#{d} drop=private-hidden\n", .{ name, fid.int() });
                continue;
            }
            if (!memberExtVisible(self, mod, fid, &visible_owners)) {
                if (missTraceWant(name)) std.debug.print("[extlocal] {s}#{d} drop=owner-invisible\n", .{ name, fid.int() });
                continue;
            }
            // A candidate whose declared receiver definitely excludes this
            // runtime receiver is not applicable at all (kotlinc drops it):
            // `UIntArray.fill` never binds a plain `Array` receiver even when
            // no other overload survives the walk.
            if (receiverViolatesTypeParamBound(self, fid, &f.params[0].ty, receiver)) {
                bound_thinned = true;
                continue;
            }
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
    // A member of the receiver beats every extension: when bound
    // refutation THINNED this set, a sole survivor that used to lose a
    // tie must not newly commit past the member tail — the ranges
    // `contains` family's own `element != null && contains(element)`
    // re-entered itself exactly here.
    if (bound_thinned and receiverHasMemberNamed(self, receiver, name)) return null;
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
        .IrClosure, .BoundMethod, .Intrinsic => true,
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
            if (param == null) {
                // A named argument that names no parameter is inapplicable —
                // the generated pair included, now that the pre-resolution
                // threading oracle is retired and a pair only reaches calls
                // whose resolved target (or completion probe) declares it.
                return false;
            }
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

fn scoreNamedMemberCandidate(
    self: *VmHost,
    allocator: Allocator,
    f: *const Func,
    args: []const Value,
    arg_names: ?[]const ?[]const u8,
) Allocator.Error!?i32 {
    const score = try runtimeMemberApplicability(self, allocator, f, args, arg_names, true);
    return if (score) |s| s.points else null;
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

/// ORDER key for the named-binding permutation map: unlike the resolution
/// key it folds NO arg-type signature — the binding ORDER is a pure
/// function of (class, name, arg count, name vector, per-arg callability):
/// names and positions drive the slot binding, and callability is the only
/// value property the trailing-lambda/compose-pair rules consult. The perm
/// serve REWRITES to a positional dispatch that re-resolves with the real
/// values, so overload selection never rides this key. This keys shapes
/// whose container-typed args make the full signature unbuildable — the
/// bulk of the named traffic.
fn namedOrderKey(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    var k = instanceMethodKeyScoped(self, receiver, name, &.{}, null, null) orelse return null;
    k.n_args = @intCast(args.len);
    var h = std.hash.Wyhash.init(0x1f83d9abfb41bd6b);
    for (args, 0..) |*a, i| {
        const nm: ?[]const u8 = if (i < arg_names.len) arg_names[i] else null;
        var tag: u8 = 3;
        if (nm != null) {
            tag = 1;
        } else if (vmhost.host_call_func.callableForTrailing(self, a)) {
            tag = 2;
        }
        h.update((&tag)[0..1]);
        const p: usize = if (nm) |n| @intFromPtr(n.ptr) else 0;
        h.update(std.mem.asBytes(&p));
    }
    k.sig = h.final() ^ 0x0DDB_A11C_0FFE_E000;
    if (k.sig == 0) k.sig = 7;
    return k;
}

/// WALK key for the named hierarchy-walk memo: class/name identity plus
/// the RELAXED arg signature (see `methodArgSigRelaxed` — container kinds,
/// never null) and the name vector. Member overload sets are fully
/// discriminated at erasure granularity by the relaxed tags, so the pick
/// is a pure function of this key wherever the strict key would simply
/// have been unbuildable.
fn namedWalkKey(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    var k = instanceMethodKeyScoped(self, receiver, name, &.{}, null, null) orelse return null;
    k.n_args = @intCast(args.len);
    var h = std.hash.Wyhash.init(0xbe5466cf34e90c6c);
    const rs = methodArgSigRelaxed(self, args);
    h.update(std.mem.asBytes(&rs));
    for (arg_names) |n| {
        const pp: usize = if (n) |nn| @intFromPtr(nn.ptr) else 1;
        h.update(std.mem.asBytes(&pp));
    }
    k.sig = h.final() ^ 0xFACE_0FF5_1DE0_0DD5;
    if (k.sig == 0) k.sig = 9;
    return k;
}

/// Cache key for a NAMED member resolution: the positional key with the
/// arg-name vector folded in (names are module-interned, so pointer
/// identity keys them) and a salt so entries never collide with the
/// positional/extension entries sharing the map.
fn namedMethodKey(self: *VmHost, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) ?root_mod.ProgramImage.InstanceMethodKey {
    var k = instanceMethodKeyScoped(self, receiver, name, args, null, null) orelse return null;
    var h = std.hash.Wyhash.init(0x6a09e667f3bcc909);
    for (arg_names) |n| {
        const p: usize = if (n) |nn| @intFromPtr(nn.ptr) else 1;
        h.update(std.mem.asBytes(&p));
    }
    k.sig ^= h.final() ^ 0x517c_c1b7_2722_0a95;
    if (k.sig == 0) k.sig = 3;
    return k;
}

/// Compute the replayable arg→param permutation for a resolved NAMED call,
/// following exactly the safe subset of `callFuncNamed`'s binding (named
/// bind by parameter name, the trailing-lambda and compose-pair rules, the
/// positional walk) over the user params (`f.params[1..]`; the walk binds
/// the receiver at slot 0). Null when the shape needs the full binder —
/// varargs, defaults, over/under-application, duplicate names. Every
/// consulted fact is folded into the memo key (param list per fid, arg
/// tags via the sig, name vector via the names hash), so the permutation
/// is a pure function of the key.
fn namedBindPerm(self: *VmHost, f: *const ir.Func, args: []const Value, arg_names: []const ?[]const u8) ?root_mod.ProgramImage.NamedPerm {
    for (f.params) |*p| {
        if (p.is_vararg) return null;
    }
    if (f.params.len == 0) return null;
    const up = f.params[1..];
    if (up.len > 15 or args.len != up.len) return null;
    var src: [15]u8 = @splat(0xFF);
    var used: [15]bool = @splat(false);
    for (args, 0..) |_, i| {
        if (i >= arg_names.len) continue;
        const an = arg_names[i] orelse continue;
        var bound = false;
        for (up, 0..) |p, pos| {
            if (applicability.paramNameMatchesArg(p.name, an)) {
                if (src[pos] != 0xFF) return null;
                src[pos] = @intCast(i);
                used[i] = true;
                bound = true;
                break;
            }
        }
        if (!bound) return null;
    }
    var trailing: ?usize = null;
    if (args.len > 0 and up.len > 0) {
        const last = args.len - 1;
        const last_named = last < arg_names.len and arg_names[last] != null;
        const lp = up.len - 1;
        if (!last_named and src[lp] == 0xFF and root_mod.isFunctionType(&up[lp].ty) and
            vmhost.host_call_func.callableForTrailing(self, &args[last]))
        {
            src[lp] = @intCast(last);
            used[last] = true;
            trailing = last;
        }
        if (trailing == null and args.len >= 3 and up.len >= 3) {
            const ci = args.len - 2;
            const bi = args.len - 3;
            const cn = if (ci < arg_names.len) arg_names[ci] else null;
            const gn = if (last < arg_names.len) arg_names[last] else null;
            const bn = if (bi < arg_names.len) arg_names[bi] else null;
            const upos = up.len - 3;
            if (cn != null and gn != null and bn == null and
                std.mem.eql(u8, cn.?, "$composer") and
                std.mem.eql(u8, gn.?, "$changed") and
                std.mem.eql(u8, up[up.len - 2].name, "$composer") and
                std.mem.eql(u8, up[up.len - 1].name, "$changed") and
                src[upos] == 0xFF and
                root_mod.isFunctionType(&up[upos].ty) and
                vmhost.host_call_func.callableForTrailing(self, &args[bi]))
            {
                src[upos] = @intCast(bi);
                used[bi] = true;
                trailing = bi;
            }
        }
    }
    var positional_idx: usize = 0;
    for (args, 0..) |_, i| {
        if (used[i]) continue;
        if (i < arg_names.len and arg_names[i] != null) continue;
        while (positional_idx < up.len and src[positional_idx] != 0xFF) positional_idx += 1;
        if (positional_idx >= up.len) return null;
        src[positional_idx] = @intCast(i);
        positional_idx += 1;
    }
    var seen_gap = false;
    for (up, 0..) |_, pos| {
        if (src[pos] == 0xFF) {
            // A TRAILING unfilled param defaults at invocation (the
            // positional invoker's binding fills it); an interior gap
            // cannot be expressed positionally and keeps the named path.
            src[pos] = 0xFE;
            seen_gap = true;
        } else if (seen_gap) {
            return null;
        }
    }
    return .{ .n = @intCast(up.len), .src = src };
}

/// Serve a memoized named-member resolution: replay the cached binding
/// permutation as a positional dispatch when one exists (or can be
/// computed and cached), else run the full named terminal. The
/// self-delegation guard brackets both dispatches, exactly as the walk's
/// own terminal pushes it.
fn serveNamedFid(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, fid: FuncId, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    // Perm entries live under the ORDER key (see `namedOrderKey`), shared
    // with the unified rewrite's probe.
    const key = namedOrderKey(self, receiver, name, args, arg_names) orelse
        return try invokeMethodNamedFid(self, allocator, receiver, fid, args, arg_names);
    // Thread-local L1 over the perm map (same rationale as
    // `tl_method_cache`: the shared reader lock's cache-line traffic).
    var perm: ?root_mod.ProgramImage.NamedPerm = null;
    const tslot = &tl_perm_cache[tlSlot(key)];
    if (tslot.raw_plus != 0 and tslot.gen == cacheGen() and tslot.class_p == key.class_p and tslot.name_p == key.name_p and
        tslot.sig == key.sig and tslot.n_args == key.n_args)
    {
        perm = tslot.perm;
    }
    if (perm == null) {
        perm = blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().named_perm_cache.get(key);
        };
        if (perm) |p| {
            tslot.* = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .raw_plus = 1, .gen = cacheGen(), .perm = p };
        }
    }
    if (perm == null) {
        const computed: ?root_mod.ProgramImage.NamedPerm = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const f = mg.get().funcById(fid) orelse break :blk null;
            break :blk namedBindPerm(self, f, args, arg_names);
        };
        const store = computed orelse root_mod.ProgramImage.NamedPerm{ .n = 0xFF, .src = @splat(0xFF) };
        {
            const pg = self.prog.borrowMut();
            defer pg.deinit();
            pg.get().named_perm_cache.put(key, store) catch {};
        }
        tslot.* = .{ .class_p = key.class_p, .name_p = key.name_p, .n_args = key.n_args, .sig = key.sig, .raw_plus = 1, .perm = store };
        perm = store;
    }
    if (perm.?.n != 0xFF) {
        const p = perm.?;
        var buf: [15]Value = undefined;
        var m: usize = 0;
        while (m < p.n and p.src[m] != 0xFE) : (m += 1) buf[m] = args[p.src[m]];
        const ident = receiverIdent(receiver);
        const pushed = ident != 0 and walk_active_len < walk_active.len;
        if (pushed) {
            walk_active[walk_active_len] = .{ .fid = @intCast(fid.int()), .ident = ident };
            walk_active_len += 1;
        }
        const r = try invokeMethodFuncId(self, allocator, receiver, fid, buf[0..m]);
        if (pushed) walk_active_len -= 1;
        if (r) |rr| return rr;
    }
    return try invokeMethodNamedFid(self, allocator, receiver, fid, args, arg_names);
}

/// The named walk's invoke terminal, shared by the walk and its memo serve:
/// `[receiver] ++ args` with a null-shifted name vector, the self-delegation
/// guard pushed, dispatched through the named caller.
fn invokeMethodNamedFid(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, args: []const Value, arg_names: ?[]const ?[]const u8) Allocator.Error!?EvalResult {
    ir.eval.dispatchNote(.served_user_body);
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

fn instanceMethodWalkNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: ?[]const ?[]const u8) Allocator.Error!?EvalResult {
    // Memo serve for both the named path and the positional fallback: a
    // prior completed walk's pick (or confirmed miss) short-circuits the
    // whole hierarchy traversal. The self-delegation guard is re-checked
    // at serve time; an active entry declines to the full walk, whose
    // fills are vetoed while the guard filters.
    if (namedWalkKey(self, receiver, name, args, arg_names orelse &.{})) |k| {
        if (extMethodCacheGet(self, k)) |raw| {
            if (raw == METHOD_MISS) return null;
            const fid: FuncId = @enumFromInt(raw);
            if (!walkActive(fid, receiverIdent(receiver))) {
                return try serveNamedFid(self, allocator, receiver, name, fid, args, arg_names orelse &.{});
            }
        }
    }
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
    const WalkItem = struct { cid: ?ir.ClassId, name: []const u8, hint: []const u8 = "" };
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
    var walk_active_skipped = false;
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
                if (classByNamePreferring(mod, item.name, item.hint)) |hit| {
                    ir_class = hit.cls;
                }
            }
            // Dedup on the resolved class's FQN (identity) so two distinct
            // classes that share a simple name are each walked once.
            const dedup_key = if (ir_class) |irc| irc.fqn else item.name;
            if (seen.contains(dedup_key)) continue;
            try seen.put(dedup_key, {});
            if (ir_class) |irc| {
                if (nuTraceEnv()) |want| {
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
                            if (nuTraceEnv()) |want| {
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
                            if (walkActive(fid, receiverIdent(receiver))) {
                                walk_active_skipped = true;
                                continue;
                            }
                            if (memberApplicableForWalkNamed(self, &f, args, arg_names)) {
                                const sc = (try scoreNamedMemberCandidate(self, allocator, &f, args, arg_names)) orelse continue;
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
                for (dg.get().supertype_names) |sn| try queue.append(allocator, .{ .cid = null, .name = sn, .hint = dg.get().fqn });
                dg.deinit();
            }
            cg.deinit();
        }
    }
    if (method_fid) |fid| {
        // Memoize the pick so later named calls of this exact shape skip
        // the hierarchy walk and the overload scoring; the serve replays
        // this same terminal (self-delegation guard included). Only a
        // non-active resolution memoizes — an entry picked while the
        // `walk_active` guard filtered a candidate is context-dependent.
        if (!walk_active_skipped) {
            if (namedWalkKey(self, receiver, name, args, arg_names orelse &.{})) |k| {
                extMethodCachePut(self, k, @intFromEnum(fid));
            }
        }
        return try invokeMethodNamedFid(self, allocator, receiver, fid, args, arg_names);
    }
    // A completed walk with no applicable method is a stable verdict for
    // this (class, name, shape) too; memoize the miss so the ladder's
    // fallback stops re-walking the hierarchy per call.
    if (!walk_active_skipped) {
        if (namedWalkKey(self, receiver, name, args, arg_names orelse &.{})) |k| {
            extMethodCachePut(self, k, METHOD_MISS);
        }
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
    return memberRefResolved(self, allocator, receiver, name, null);
}

pub fn memberRefExact(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    func: FuncId,
) Allocator.Error!EvalResult {
    return memberRefResolved(self, allocator, receiver, name, func);
}

/// The value-parameter count of the member a bound reference names, so the
/// reference can report the `FunctionN` it satisfies. Null when the target
/// cannot be identified (an unbound/type-form reference, a dynamic name).
fn boundRefArity(self: *VmHost, receiver: *const Value, name: []const u8, func: ?FuncId) ?usize {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    if (func) |fid| {
        if (mod.funcById(fid)) |f| {
            const skip: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            return f.params.len - skip;
        }
    }
    if (receiver.* != .Instance) return null;
    const cls_fqn = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    var found: ?usize = null;
    for (mod.memberDecls(cls_fqn, name)) |fid| {
        const f = mod.funcById(fid) orelse continue;
        const skip: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const n = f.params.len - skip;
        if (found != null and found.? != n) return null; // overloaded: no single arity
        found = n;
    }
    return found;
}

fn memberRefResolved(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    func: ?FuncId,
) Allocator.Error!EvalResult {
    // `X::class` is a class reference — return the class itself. For an
    // instance receiver, reach into the runtime ClassDef.
    if (std.mem.eql(u8, name, "class")) {
        if (receiver.* == .Instance) {
            const cls: ObjRef(ClassDef) = blk: {
                const ig = receiver.Instance.borrow();
                defer ig.deinit();
                break :blk ig.get().class.clone();
            };
            // `A::class` on a class that has a companion reaches here with
            // the COMPANION instance (the bare name's global is the
            // companion); the class literal is the owner, never the
            // companion's own class.
            const cv = Value{ .Class = cls };
            const is_companion = blk: {
                const cg = cls.borrow();
                defer cg.deinit();
                const n = cg.get().name;
                break :blk std.mem.endsWith(u8, n, "$Companion") or std.mem.endsWith(u8, n, ".Companion") or std.mem.eql(u8, n, "Companion");
            };
            if (is_companion) {
                if (try companionOwnerClassValue(self, &cv)) |owner| {
                    cls.deinit();
                    return .{ .ok = owner };
                }
            }
            return .{ .ok = cv };
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
    // A bound reference IS a function value: `s::produce` satisfies
    // `() -> Int`, answers `is Function0<*>`, and takes every extension
    // declared on a function type (`(() -> T).asFlow()`). Name the
    // function supertypes so the dispatch walk and `is` see them; without
    // them a member call on the reference found no candidate and fell back
    // to invoking the bound method itself.
    const supers: []const []const u8 = blk: {
        const arity = boundRefArity(self, receiver, name, func) orelse
            break :blk try allocator.dupe([]const u8, &.{"kotlin.Function"});
        const fn_name = try std.fmt.allocPrint(allocator, "Function{d}", .{arity});
        break :blk try allocator.dupe([]const u8, &.{ fn_name, "kotlin.Function" });
    };
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
        .supertype_names = supers,
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
    if (func) |fid| {
        try fields.append(allocator, .{ .name = "__bound_func__", .value = .{ .Int = @intCast(fid.int()) } });
    }
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
            // An unrecorded getter return lowers as Unit — no knowledge, so
            // no refutation (a real property getter is never Unit-typed).
            if (std.mem.eql(u8, rt.name, "kotlin.Unit") or std.mem.eql(u8, rt.name, "Unit") or rt.name.len == 0) return true;
            if (isFunctionTypeRefResolved(self, &rt)) return true;
            // A TYPE-PARAMETER return (`State<T>.value: T`) says nothing —
            // and its short name can collide with a registered class
            // (a test's `class T`), which wrongly refuted the probe.
            if (rt.name.len <= 2 and blk: {
                for (rt.name) |ch| {
                    if (!std.ascii.isUpper(ch)) break :blk false;
                }
                break :blk rt.name.len != 0;
            }) return true;
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

var qt_trace_init: bool = false;
var qt_trace_val: ?[]const u8 = null;
fn qtTraceWant() ?[]const u8 {
    if (!qt_trace_init) {
        qt_trace_val = if (std.c.getenv("KLIO_QT_TRACE")) |w| std.mem.span(w) else null;
        qt_trace_init = true;
    }
    return qt_trace_val;
}

pub fn qualifiedThis(self: *VmHost, allocator: Allocator, receiver: *const Value, qualifier: []const u8) Allocator.Error!EvalResult {
    const qt_trace = if (qtTraceWant()) |w0| std.mem.indexOf(u8, qualifier, w0) != null else false;
    if (std.mem.indexOfScalar(u8, qualifier, '.') != null) {
        var walk: ?Value = receiver.*;
        var steps: usize = 0;
        while (walk) |value| {
            if (steps > 128 or value != .Instance) break;
            steps += 1;
            if (qt_trace) std.debug.print("[qt] cand={s} qual={s}\n", .{ debugClassNameOf(self, &value), qualifier });
            if (receiverImplementsOwnerIdentity(self, &value, qualifier)) {
                if (qt_trace) std.debug.print("[qt]   -> matched receiver walk\n", .{});
                return .{ .ok = value };
            }
            walk = instanceOuterLink(&value);
        }
        const exact_chain = try enclosingThisChain(self, allocator);
        defer allocator.free(exact_chain);
        for (exact_chain) |enclosing| {
            walk = enclosing;
            steps = 0;
            while (walk) |value| {
                if (steps > 128 or value != .Instance) break;
                steps += 1;
                if (qt_trace) std.debug.print("[qt] encl-cand={s}\n", .{debugClassNameOf(self, &value)});
                if (receiverImplementsOwnerIdentity(self, &value, qualifier)) {
                    if (qt_trace) std.debug.print("[qt]   -> matched enclosing chain\n", .{});
                    return .{ .ok = value };
                }
                walk = instanceOuterLink(&value);
            }
        }
        if (qt_trace) std.debug.print("[qt] NO MATCH for {s}\n", .{qualifier});
        return .{ .err = try typeErr(
            allocator,
            "qualified this `{s}` is not in the implicit receiver scope",
            .{qualifier},
        ) };
    }
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
    if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
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
    // The unsigned value classes hash their SIGNED storage: 65535u is -1.
    try testing.expectEqual(@as(i32, -1), kotlinHashCode(&.{ .UShort = 65535 }));
    try testing.expectEqual(@as(i32, -1), kotlinHashCode(&.{ .UByte = 255 }));
    try testing.expectEqual(@as(i32, 1), kotlinHashCode(&.{ .UShort = 1 }));
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

/// The serializer a `@Serializer(forClass = C::class)` declaration stands for.
/// The kotlinx plugin generates that declaration's whole body from `C`; klio
/// answers the members it never wrote by forwarding to `C`'s own serializer.
/// Null unless the receiver's class carries the annotation with a resolvable
/// class argument that is not the receiver itself.
pub fn serializerForClassTarget(self: *VmHost, allocator: Allocator, receiver: *const Value) Allocator.Error!?Value {
    const cls: ObjRef(ClassDef) = switch (receiver.*) {
        .Class => |c| c.clone(),
        .Instance => |inst| blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().class.clone();
        },
        else => return null,
    };
    defer cls.deinit();
    const for_class: []const u8 = blk: {
        const g = cls.borrow();
        defer g.deinit();
        for (g.get().annotation_records) |rec| {
            if (!rec.is("Serializer") and !rec.is("kotlinx.serialization.Serializer")) continue;
            for (rec.args) |arg| {
                if (arg == .ClassRef) break :blk arg.ClassRef;
            }
        }
        return null;
    };
    const target = host_globals.lookupGlobal(self, for_class) orelse return null;
    if (target != .Class) return null;
    // `@Serializer(forClass = Self::class)` would forward to itself.
    {
        const tg = target.Class.borrow();
        defer tg.deinit();
        const cg = cls.borrow();
        defer cg.deinit();
        if (std.mem.eql(u8, tg.get().fqn, cg.get().fqn)) return null;
    }
    const fid = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().funcIdByFqn("kotlinx.serialization.__klsx_reflectiveSerializer") orelse return null;
    };
    const call_args = [_]Value{target};
    const r = try callFuncRec(self, allocator, self.module.asPtr(), fid, &call_args);
    switch (r) {
        .ok => |v| {
            if (v == .Null) return null;
            return v;
        },
        .err => |e| {
            freeDispatchMiss(allocator, .{ .err = e });
            return null;
        },
    }
}

/// The class a companion object belongs to, as a `Value.Class`. Null when the
/// argument is not a registered companion.
fn companionOwnerClassValue(self: *VmHost, kc: *const Value) Allocator.Error!?Value {
    if (kc.* != .Class) return null;
    const comp_name = blk: {
        const g = kc.Class.borrow();
        defer g.deinit();
        break :blk g.get().name;
    };
    const owner: ?[]const u8 = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const reg = &mg.get().registry;
        // The instance's class may carry the `$Companion` suffix once more
        // than the registered singleton name does; peel it until a
        // registered owner appears.
        var probe = comp_name;
        var hops: usize = 0;
        while (hops < 3) : (hops += 1) {
            var it = reg.companion_singletons.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.value_ptr.*, probe)) break :blk e.key_ptr.*;
            }
            if (reg.enclosing_class.get(probe)) |o| break :blk o;
            if (hops != 0 and mg.get().classId(probe) != null) break :blk probe;
            if (std.mem.endsWith(u8, probe, "$Companion")) {
                probe = probe[0 .. probe.len - "$Companion".len];
            } else if (std.mem.endsWith(u8, probe, ".Companion")) {
                probe = probe[0 .. probe.len - ".Companion".len];
            } else break;
        }
        break :blk null;
    };
    const name = owner orelse return null;
    // The class table is the authority for the owner's class value: a
    // by-name global may be a same-named property of another package
    // (`kotlin.math.E` beside a user `enum class E`).
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(name)) |def| return Value{ .Class = def.clone() };
    }
    const v = host_globals.lookupGlobal(self, name) orelse return null;
    if (v != .Class) return null;
    return v;
}
