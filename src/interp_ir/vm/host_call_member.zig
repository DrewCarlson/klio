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

const vmhost = @import("vmhost.zig");
const host_globals = @import("host_globals.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;
const trace = @import("trace.zig");
const overload_match = @import("overload_match.zig");

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
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;

// -------------------------------------------------------------------------
// Thread-local resolution state. In Rust these live as file-spanning
// thread-locals in `lib.rs`/`host_globals.rs`; the slices of that state
// member-dispatch reads/writes are kept here.
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
        .fqn = try StringRef.init(allocator, fqn),
        .message = if (message) |m| try StringRef.init(allocator, m) else null,
        .cause = null,
    } } };
}

fn strVal(allocator: Allocator, s: []const u8) Allocator.Error!Value {
    return .{ .String = try StringRef.init(allocator, s) };
}

fn boolVal(b: bool) Value {
    return .{ .Bool = b };
}

/// Simple-name tail of a possibly-qualified name (`a.b.C` -> `C`).
fn simpleName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
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
    const n = mg.get().funcs.items.len;
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

fn callValueRec(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!EvalResult {
    return self.callValue(allocator, callee, args);
}

fn callValueWithThisRec(self: *VmHost, allocator: Allocator, callee: *const Value, this_value: *const Value, args: []const Value) Allocator.Error!EvalResult {
    return self.callValueWithThis(allocator, callee, this_value, args, &.{});
}

fn newInstanceById(self: *VmHost, allocator: Allocator, class: ir.ClassId, args: []const Value, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    return self.newInstance(allocator, class, args, outer_hint);
}

fn getFieldRec(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return self.getField(allocator, receiver, name);
}

fn callFuncRec(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value) Allocator.Error!EvalResult {
    return self.callFunc(allocator, module, func, args);
}

fn callFuncNamedRec(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, names: []const ?[]const u8) Allocator.Error!EvalResult {
    return self.callFuncNamed(allocator, module, func, args, names);
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
    const r = try func(&ctx);
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
        else => |other| try typeErr(allocator, "{s}", .{@tagName(other)}),
    };
}

// -------------------------------------------------------------------------
// Pure helpers ported from `lib.rs` (their Rust home is the crate root;
// they are pure functions over `Value` / `Module` and live here so the
// member-dispatch file is self-contained).
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
    out[fixed] = .{ .Array = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, rest_list), .prim = null } };
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

/// Kotlin-faithful `hashCode()` for builtin value types.
fn kotlinHashCode(v: *const Value) i32 {
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
        .Float => |f| @bitCast(f),
        .Double => |d| blk: {
            const b: i64 = @bitCast(d);
            break :blk @truncate(b ^ @as(i64, @bitCast(@as(u64, @bitCast(b)) >> 32)));
        },
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            const bytes = g.get().*;
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
            for (g.get().items) |kv| h = h +% (kotlinHashCode(&kv.key) ^ kotlinHashCode(&kv.value));
            break :blk h;
        },
        .Array => |arr| blk: {
            const g = arr.items.borrow();
            defer g.deinit();
            var h: i32 = 1;
            for (g.get().items) |e| h = h *% 31 +% kotlinHashCode(&e);
            break :blk h;
        },
        .Range => |r| blk: {
            const f: i32 = @truncate(r.start);
            const l: i32 = @truncate(r.end);
            const s: i32 = @truncate(r.step);
            const empty = if (r.step > 0) r.start > r.end else r.start < r.end;
            if (empty) break :blk @as(i32, -1);
            if (r.step == 1) break :blk @as(i32, 31) *% f +% l;
            break :blk (@as(i32, 31) *% (@as(i32, 31) *% f +% l)) +% s;
        },
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
            h.update(g.get().*);
        },
        else => h.update(std.mem.asBytes(&@as(i32, 7))),
    }
    return @truncate(@as(i64, @bitCast(h.final())));
}

/// Materialise an integer/char progression's elements.
fn materialiseRangeItems(allocator: Allocator, start: i64, end: i64, step: i64, kind: RangeKind) Allocator.Error!std.ArrayList(Value) {
    var out: std.ArrayList(Value) = .empty;
    var cur = start;
    if (step > 0) {
        while (cur <= end) {
            try out.append(allocator, rangeElem(cur, kind));
            cur +|= step;
            if (cur > end) break;
        }
    } else if (step < 0) {
        while (cur >= end) {
            try out.append(allocator, rangeElem(cur, kind));
            cur +|= step;
            if (cur < end) break;
        }
    }
    return out;
}

fn rangeElem(cur: i64, kind: RangeKind) Value {
    return switch (kind) {
        .Int => Value.newInt(cur),
        .Long => .{ .Long = cur },
        .Char => .{ .Char = @truncate(@as(u64, @bitCast(cur))) },
    };
}

// -------------------------------------------------------------------------
// Self-contained `VmHost` helpers (their Rust home is this file).
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
fn mapContainsKeyEq(self: *VmHost, allocator: Allocator, entries: ObjRef(std.ArrayList(MapPair)), needle: *const Value) Allocator.Error!union(enum) { ok: bool, err: EvalError } {
    if (needle.* != .Instance) {
        const g = entries.borrow();
        defer g.deinit();
        for (g.get().items) |kv| {
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
        for (g.get().items) |kv| try keys.append(allocator, kv.key);
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
    const entries_r = try callMemberRec(self, allocator, recv, "entries", &.{});
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
    return .{ .ok = .{ .Map = .{ .entries = try ObjRef(std.ArrayList(MapPair)).init(allocator, pairs), .mutable = false } } };
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
    for (builtinSupers(v_ty), 0..) |s, pos| {
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
    return elementsProveArgs(self, allocator, receiver, fid, pn, ty_args, fuel);
}

/// Whether an extension whose declared receiver head is `ty` applies to
/// a receiver whose STATIC (declared) type head is `static_name`. Kotlin
/// resolves extension calls against the static receiver type, so inside
/// `fun I.helper()` a bare extension call binds I's extensions even when
/// the runtime value is a subtype carrying a same-name extension.
/// `null` ⇒ undecidable statically (unresolvable static class); the
/// caller falls back to the runtime-type proof.
fn staticReceiverApplicable(self: *VmHost, allocator: Allocator, static_name: []const u8, fid: FuncId, ty: *const TypeRef) ?bool {
    var pn = simpleName(ty.name);
    pn = std.mem.trimEnd(u8, pn, "?");
    // Receivers that accept anything statically, mirroring the runtime
    // prover's universal cases.
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return true;
    if (typeParamOf(self, fid, pn)) return true;
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
    if (mg.get().classIsOrExtends(sn, pn)) return true;
    // The static head is unknown to the recorded hierarchy: undecidable.
    if (mg.get().registry.class_super_names.get(sn) == null) return null;
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
fn typeParamOf(self: *VmHost, fid: FuncId, pn: []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const tps = mg.get().registry.func_type_params.get(fid) orelse return false;
    for (tps.items) |tp| {
        if (std.mem.eql(u8, tp, pn)) return true;
    }
    return false;
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
        const entries = g.get().items;
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
        .Array => |arr| if (std.mem.eql(u8, pn, "Array")) arr.items else null,
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
fn receiverImplementsHead(self: *VmHost, receiver: *const Value, pn: []const u8) bool {
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
                if (std.mem.eql(u8, simpleName(c), pn)) return true;
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
                if (std.mem.eql(u8, simpleName(c), pn)) return true;
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

pub fn hostHasMember(self: *VmHost, receiver: *const Value, name: []const u8) bool {
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
                if (std.mem.eql(u8, p.name, name)) {
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
                if (std.mem.eql(u8, p.name, name)) {
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
        .enum_class = null,
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
// Overload scoring + method/extension selection (ported from `vmhost.rs`).
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
    if (std.mem.eql(u8, nm, v_ty)) {
        const d = overload_match.refineByDeclaredArgs(self, param_ty, arg) orelse return null;
        return 100 + d;
    }
    if (std.mem.eql(u8, nm, "Any") or std.mem.eql(u8, nm, "Any?")) return 10;
    if (arg.* == .Null and param_ty.nullable) return 50;
    if (std.mem.eql(u8, nm, "Long") and std.mem.eql(u8, v_ty, "Int")) return 40;
    if ((std.mem.eql(u8, nm, "Double") or std.mem.eql(u8, nm, "Float")) and std.mem.eql(u8, v_ty, "Int")) return 30;
    if (std.mem.eql(u8, nm, "Double") and std.mem.eql(u8, v_ty, "Long")) return 30;

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
    const builtin_supers = builtinSupers(v_ty);
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
    const tn = simpleName(target);
    while (head < queue.items.len) : (head += 1) {
        const e = queue.items[head];
        if (seen.contains(e.name)) continue;
        seen.put(e.name, {}) catch {};
        if (std.mem.eql(u8, simpleName(e.name), tn)) return e.depth;
        const cg = self.classes.borrow();
        if (cg.get().get(e.name)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |sn| queue.append(a, .{ .name = sn, .depth = e.depth + 1 }) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return null;
}

fn builtinSupers(nm: []const u8) []const []const u8 {
    const s = simpleName(nm);
    if (std.mem.eql(u8, s, "List")) {
        return &.{ "Collection", "Iterable", "MutableList", "MutableCollection", "MutableIterable" };
    } else if (std.mem.eql(u8, s, "MutableList")) {
        return &.{ "List", "Collection", "Iterable", "MutableCollection", "MutableIterable" };
    } else if (std.mem.eql(u8, s, "Collection")) {
        return &.{ "Iterable", "MutableCollection", "MutableIterable" };
    } else if (std.mem.eql(u8, s, "Set")) {
        return &.{ "Collection", "Iterable", "MutableSet", "MutableCollection", "MutableIterable" };
    } else if (std.mem.eql(u8, s, "MutableSet")) {
        return &.{ "Set", "Collection", "Iterable", "MutableCollection", "MutableIterable" };
    } else if (std.mem.eql(u8, s, "Map")) {
        return &.{"MutableMap"};
    } else if (std.mem.eql(u8, s, "MutableMap")) {
        return &.{"Map"};
    } else if (std.mem.eql(u8, s, "IntRange")) {
        return &.{ "IntProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    } else if (std.mem.eql(u8, s, "LongRange")) {
        return &.{ "LongProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    } else if (std.mem.eql(u8, s, "CharRange")) {
        return &.{ "CharProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    } else if (std.mem.eql(u8, s, "IntProgression") or std.mem.eql(u8, s, "LongProgression") or std.mem.eql(u8, s, "CharProgression")) {
        return &.{"Iterable"};
    } else if (std.mem.eql(u8, s, "String")) {
        return &.{ "CharSequence", "Comparable" };
    }
    return &.{};
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
/// Conservative: only the builtin value types and `String`/`CharSequence`,
/// so a typealiased function type or user interface is never adjudicated.
fn isDefinitelyNonFunctionTypeName(pn: []const u8) bool {
    const names = [_][]const u8{
        "String", "CharSequence", "Boolean", "Char",  "Byte",  "Short",
        "Int",    "Long",         "Float",   "Double", "UByte", "UShort",
        "UInt",   "ULong",        "Number",
    };
    for (names) |n| {
        if (std.mem.eql(u8, pn, n)) return true;
    }
    return false;
}

fn argDefinitelyNotParamType(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) bool {
    var pn = param_ty.name;
    // A qualified reference (`Owner.Pocket`) names a lifted nested/inner
    // class whose registered name the supertype walk cannot relate;
    // decline to adjudicate.
    if (std.mem.indexOfScalar(u8, pn, '.') != null) return false;
    // A typealiased param type adjudicates under its expansion, never the
    // alias's simple name — another file may register an unrelated class
    // under that name (the coroutines file-private `typealias Node =
    // LockFreeLinkedListNode` vs ktor's nested `engines.Node`).
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
    // Only adjudicate when the parameter names a known user class.
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(pn) == null) return false;
    }
    const inst = switch (arg.*) {
        .Instance => |i| i,
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
    const a = self.allocator;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    queue.append(a, start) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (std.mem.eql(u8, cur, pn)) return false; // arg IS-A param type.
        // A lifted nested/inner class is registered under `Outer$Name`;
        // a type reference written `Outer.Name` collapses to `Name`, so
        // match the mangled tail too.
        if (cur.len > pn.len and cur[cur.len - pn.len - 1] == '$' and
            std.mem.endsWith(u8, cur, pn)) return false;
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
fn pickMethodOverload(self: *VmHost, candidates: []const Func, args: []const Value) ?Func {
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
        // Over-supply with no vararg tail can't bind: decline so an
        // applicable top-level/extension overload wins — e.g. the stdlib
        // `buildString { … }` inside an extension on a class that declares
        // its own zero-arg `buildString()` member (`URLBuilder.authority`).
        if (args.len > effective.len and
            (effective.len == 0 or !effective[effective.len - 1].is_vararg))
        {
            return null;
        }
        if (args.len < effective.len) {
            const defaults = funcDefaults(self, &f);
            var k: usize = args.len;
            while (k < effective.len) : (k += 1) {
                if (!(effective[k].is_vararg or paramHasDefault(defaults, skip + k))) return null;
            }
        }
        // By type: a definite argument-type mismatch must fall through so
        // the hierarchy walk continues to the real target.
        var i: usize = 0;
        while (i < args.len and i < effective.len) : (i += 1) {
            if (argDefinitelyNotParamType(self, &effective[i].ty, &args[i])) return null;
        }
        return f;
    }
    var best: ?Func = null;
    var best_score: i32 = std.math.minInt(i32);
    // Track candidates that scored equal to the current best, for the
    // overload-uniqueness invariant (KLIO_TRACE_INVARIANTS). Only populated
    // when the gate is on; otherwise stays empty and costs nothing.
    const check_inv = trace.invariantsEnabled();
    var tied: std.ArrayList(Func) = .empty;
    defer tied.deinit(self.allocator);
    for (candidates) |f| {
        const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const effective = f.params[skip..];
        // Trailing-lambda rule: a `recv.f(a, …) { lambda }` call binds the
        // trailing lambda to the LAST function-typed param, with the
        // intermediate gap defaulted.
        if (args.len < effective.len and args.len > 0 and
            effective.len > 0 and isFunctionTypeRefResolved(self, &effective[effective.len - 1].ty) and
            isCallable(&args[args.len - 1]))
        {
            const lead = args.len - 1;
            const last_param = effective.len - 1;
            const defaults = funcDefaults(self, &f);
            var gap_defaulted = true;
            var k: usize = lead;
            while (k < last_param) : (k += 1) {
                if (!paramHasDefault(defaults, skip + k)) {
                    gap_defaulted = false;
                    break;
                }
            }
            if (gap_defaulted) {
                var total: i32 = 0;
                var ok = true;
                var j: usize = 0;
                while (j < lead) : (j += 1) {
                    if (overloadScoreArg(self, &effective[j].ty, &args[j])) |s| {
                        total += s;
                    } else {
                        ok = false;
                        break;
                    }
                }
                if (ok) {
                    if (overloadScoreArg(self, &effective[last_param].ty, &args[lead])) |s| {
                        total += s;
                    } else ok = false;
                }
                if (ok) {
                    // A `@Deprecated(HIDDEN)` / low-priority overload is
                    // only kotlinc's pick when no ordinary candidate
                    // applies; rank it strictly below every ordinary one.
                    if (f.low_priority) total -= 1000;
                    if (check_inv and total == best_score) tied.append(self.allocator, f) catch {};
                    if (total > best_score) {
                        best_score = total;
                        best = f;
                        if (check_inv) {
                            tied.clearRetainingCapacity();
                            tied.append(self.allocator, f) catch {};
                        }
                    }
                }
                continue;
            }
        }
        // Accept an exact-arity match, or a call supplying fewer args when
        // every unsupplied trailing parameter has a default.
        if (args.len > effective.len) continue;
        if (args.len < effective.len) {
            const defaults = funcDefaults(self, &f);
            var all_defaulted = true;
            var k: usize = args.len;
            while (k < effective.len) : (k += 1) {
                if (!paramHasDefault(defaults, skip + k)) {
                    all_defaulted = false;
                    break;
                }
            }
            if (!all_defaulted) continue;
        }
        var score: i32 = 0;
        var ok = true;
        var i: usize = 0;
        while (i < args.len and i < effective.len) : (i += 1) {
            if (overloadScoreArg(self, &effective[i].ty, &args[i])) |s| {
                score += s;
            } else {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        // Prefer an exact-arity overload over one relying on defaults.
        if (args.len == effective.len) score += 5;
        // A `@Deprecated(HIDDEN)` / low-priority overload is only
        // kotlinc's pick when no ordinary candidate applies; rank it
        // strictly below every ordinary one.
        if (f.low_priority) score -= 1000;
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
        .enum_class = null,
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

/// Prepend `receiver` to `args`, returning a freshly-allocated slice.
fn prependReceiver(allocator: Allocator, receiver: *const Value, args: []const Value) Allocator.Error![]Value {
    var all = try allocator.alloc(Value, args.len + 1);
    all[0] = receiver.*;
    @memcpy(all[1..], args);
    return all;
}

// -------------------------------------------------------------------------
// `callMember` — the central dispatch.
// -------------------------------------------------------------------------

pub fn callMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!EvalResult {
    return callMemberInner(self, allocator, receiver, name, args, false);
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
    return callMemberInnerStatic(self, allocator, receiver, name, args, strict_ext, null);
}

fn callMemberInnerStatic(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8) Allocator.Error!EvalResult {
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
                    return .{ .ok = .{ .String = try StringRef.initOwned(allocator, overridden) } };
                }
                const s = try std.fmt.allocPrint(allocator, "klio-thread-{d}", .{id});
                return .{ .ok = .{ .String = try StringRef.initOwned(allocator, s) } };
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
    if (receiver.* == .Intrinsic) {
        const probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ receiver.Intrinsic.fqn, name });
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
        const probe_simple = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cname, name });
        if (lookupIntrinsic(self, probe_simple)) |func| return dispatchIntrinsic(self, allocator, probe_simple, func, args);
        const probe_fqn = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cfqn, name });
        if (lookupIntrinsic(self, probe_fqn)) |func| return dispatchIntrinsic(self, allocator, probe_fqn, func, args);
    }

    // `List.optimizeReadOnlyList()` — no-op.
    if (std.mem.eql(u8, name, "optimizeReadOnlyList") and args.len == 0 and receiver.* == .List) {
        return .{ .ok = receiver.* };
    }

    // `listIterator(index)` / `listIterator()` on a List.
    if (std.mem.eql(u8, name, "listIterator") and args.len <= 1 and receiver.* == .List) {
        const start: usize = if (args.len > 0) blk: {
            break :blk switch (args[0]) {
                .Int => |n| @intCast(@max(n, 0)),
                .Long => |n| @intCast(@max(n, 0)),
                else => 0,
            };
        } else 0;
        const items = try cloneItemsList(allocator, receiver.List.items);
        return .{ .ok = .{ .Iterator = .{
            .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
            .pos = try ObjRef(usize).init(allocator, start),
            .prim = null,
        } } };
    }

    // Self-iterator convention.
    if (std.mem.eql(u8, name, "iterator") and args.len == 0 and (receiver.* == .Iterator or receiver.* == .RangeIter)) {
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

    // Nested-class construction on a class receiver.
    if (receiver.* == .Class) {
        const cg = receiver.Class.borrow();
        const cname = cg.get().name;
        const cfqn = cg.get().fqn;
        cg.deinit();
        const mg = self.module.borrow();
        const mod = mg.get();
        const fqn_probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cfqn, name });
        var class_id = mod.classIdByFqn(fqn_probe);
        if (class_id == null and !std.mem.eql(u8, cname, cfqn)) {
            const name_probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cname, name });
            class_id = mod.classIdByFqn(name_probe);
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

    // Null-receiver `equals`.
    if (receiver.* == .Null and std.mem.eql(u8, name, "equals") and args.len == 1) {
        return .{ .ok = boolVal(args[0] == .Null) };
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

    // SAM conversion on a callable receiver.
    if (isCallableOrIntrinsic(receiver)) {
        const has_ext = extWithThisLongerThanArgs(self, name, args.len);
        if (!std.mem.eql(u8, name, "invoke") and !has_ext) {
            const r = try callValueRec(self, allocator, receiver, args);
            if (r == .ok) return r;
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
    if (std.mem.eql(u8, name, "contains") and args.len == 1 and receiver.* == .Range) {
        const r = receiver.Range;
        const inside = blk: {
            if (args[0] == .Char and r.kind == .Char) {
                const cv: i64 = @intCast(args[0].Char);
                break :blk cv >= r.start and cv <= r.end and @rem(cv - r.start, r.step) == 0;
            }
            if (args[0].asI64()) |v| {
                break :blk v >= r.start and v <= r.end and @rem(v - r.start, r.step) == 0;
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
            for (g.get().items) |kv| {
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
        return .{ .ok = .{ .Array = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .prim = null } } };
    }
    if (receiver.* == .Array) {
        if (try arrayShapeOps(self, allocator, receiver, name, args)) |r| return r;
    }

    // Indexed get/set on Array.
    if (std.mem.eql(u8, name, "get") and args.len == 1 and receiver.* == .Array) {
        if (args[0].asI64()) |idx| {
            const g = receiver.Array.items.borrow();
            defer g.deinit();
            const items = g.get().items;
            if (idx >= 0 and @as(usize, @intCast(idx)) < items.len) {
                const elem = items[@intCast(idx)];
                // Borrowed element: the array still owns it, so retain before
                // handing it to the register that will own the result.
                elem.retain();
                return .{ .ok = elem };
            }
            const msg = try std.fmt.allocPrint(allocator, "Index {d} out of bounds for length {d}", .{ idx, items.len });
            defer if (runtime.reclaimEnabled()) allocator.free(msg);
            return .{ .err = try throwExc(allocator, "kotlin.ArrayIndexOutOfBoundsException", msg) };
        }
    }
    if (std.mem.eql(u8, name, "set") and args.len == 2 and receiver.* == .Array) {
        if (args[0].asI64()) |idx| {
            const g = receiver.Array.items.borrowMut();
            defer g.deinit();
            const items = g.get().items;
            if (idx >= 0 and @as(usize, @intCast(idx)) < items.len) {
                // The array owns one ref per element: release the value being
                // overwritten and retain the incoming borrow. No-op under arena.
                if (runtime.reclaimEnabled()) {
                    items[@intCast(idx)].release(allocator);
                    args[1].retain();
                }
                items[@intCast(idx)] = args[1];
                return .{ .ok = .Unit };
            }
            const msg = try std.fmt.allocPrint(allocator, "Index {d} out of bounds for length {d}", .{ idx, items.len });
            defer if (runtime.reclaimEnabled()) allocator.free(msg);
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
        if (try irMethodWalk(self, allocator, receiver, name, args)) |r| return r;
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

    // `hashCode()` on a builtin value type.
    if (args.len == 0 and std.mem.eql(u8, name, "hashCode") and
        receiver.* != .Instance and receiver.* != .Class and receiver.* != .PropertyRef)
    {
        return .{ .ok = Value.newInt(@as(i64, kotlinHashCode(receiver))) };
    }

    // Stdlib member dispatch (type-FQN + package extension probes).
    if (try stdlibMemberDispatch(self, allocator, receiver, name, args)) |r| return r;

    // Range → List re-dispatch.
    if (receiver.* == .Range) {
        const r = receiver.Range;
        const items = try materialiseRangeItems(allocator, r.start, r.end, r.step, r.kind);
        const as_list = try listOf(allocator, items, false);
        return callMemberRec(self, allocator, &as_list, name, args);
    }

    // Class-delegation pre-pass.
    if (receiver.* == .Instance) {
        if (try delegateForward(self, allocator, receiver, name, args, true)) |r| return r;
    }

    // Extension-fn fallback.
    if (try extensionFnFallback(self, allocator, receiver, name, args, strict_ext, static_recv)) |r| return r;

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
            if (isCallable(&v) or v == .Instance) {
                return callValueRec(self, allocator, &v, args);
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
        var sink = self.out_sink;
        var intrinsic = makeIntrinsicHost(self);
        defer deinitIntrinsicHost(&intrinsic);
        var ihost = intrinsic.intrinsicHost();
        const r = try ihost.invokeCallableWithThis(&v, args, receiver, sink.output());
        if (pushed_outer) popAccessEnclosing(self);
        return mapRuntimeResult(allocator, r);
    }


    // Map fallback.
    if (receiver.* == .Instance and !map_fallback_active and
        hostHasMember(self, receiver, "entries") and !hostHasMember(self, receiver, "iterator"))
    {
        const probe = try std.fmt.allocPrint(allocator, "kotlin.collections.Map.{s}", .{name});
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
            return dispatchIntrinsic(self, allocator, probe, f, new_args);
        }
    }

    // Iterable fallback.
    if (receiver.* == .Instance and !iterable_fallback_active and hostHasMember(self, receiver, "iterator")) {
        const p1 = try std.fmt.allocPrint(allocator, "kotlin.collections.Iterable.{s}", .{name});
        var matched: []const u8 = p1;
        var intrinsic = lookupIntrinsic(self, p1);
        if (intrinsic == null) {
            const p2 = try std.fmt.allocPrint(allocator, "kotlin.collections.List.{s}", .{name});
            intrinsic = lookupIntrinsic(self, p2);
            matched = p2;
        }
        if (intrinsic) |f| {
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
            return dispatchIntrinsic(self, allocator, matched, f, new_args);
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
                .Function, .IrClosure, .Class => return callValueRec(self, allocator, &f, args),
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

    // Dispatch-miss: the message carries `Vm::call_member `name` on `fqn``,
    // which downstream fallbacks pattern-match (e.g. the object-singleton walk)
    // to tell a top-level miss for *this* name from a deeper genuine error.
    // Discard sites free it via `freeDispatchMiss` (it is recognizable and
    // allocated here), so it does not leak per call.
    if (receiver.* == .Instance) {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        return unimplemented(allocator, "Vm::call_member `{s}` on `{s}`", .{ name, cg.get().fqn });
    }
    return unimplemented(allocator, "Vm::call_member `{s}` on `{s}`", .{ name, receiver.typeFqn() });
}

/// Free an `Unimplemented` result's message iff it is the dispatch-miss message
/// allocated by `callMemberInnerStatic` (recognizable by its `Vm::call_member`
/// prefix). Safe to call at any discard site: a static `.Unimplemented`
/// literal does not match, so it is never freed. No-op under the arena.
fn freeDispatchMiss(allocator: Allocator, r: EvalResult) void {
    if (!runtime.reclaimEnabled()) return;
    if (r == .err and r.err == .Unimplemented) {
        const m = r.err.Unimplemented;
        if (std.mem.indexOf(u8, m, "Vm::call_member") != null) allocator.free(m);
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

    var probes: std.ArrayList([]const u8) = .empty;
    // Probe FQNs are per-call scratch (all `allocPrint`ed below); free them and
    // the list. No-op under the arena; reclaims under a freeing allocator.
    defer {
        if (runtime.reclaimEnabled()) for (probes.items) |p| allocator.free(p);
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
            const all_args = try prependReceiver(allocator, receiver, args);
            return try dispatchIntrinsic(self, allocator, p, func, all_args);
        }
    }

    // klio-stdlib intrinsics on an anonymous/synth class.
    if (is_anonymous) {
        const synth = [_][]const u8{
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_fqn, name }),
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_name, name }),
        };
        for (synth) |p| {
            if (lookupIntrinsic(self, p)) |func| {
                const all_args = try prependReceiver(allocator, receiver, args);
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
            if (@intFromEnum(fid) < mod.funcs.items.len) {
                const f = mod.funcs.items[@intFromEnum(fid)];
                if (f.blocks.len != 0 and f.params.len > 0 and
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
                const all_args = try prependReceiver(allocator, receiver, args);
                return try dispatchIntrinsic(self, allocator, p, func, all_args);
            }
        }
    }
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
    switch (receiver.*) {
        .List => |l| {
            // A mutable list shares its backing so `MutableIterator.remove()`
            // mutates the source (and the iterating loop observes it); an
            // immutable list snapshots, as before.
            if (l.mutable and l.backing == null) {
                return .{ .ok = .{ .Iterator = .{ .items = l.items.clone(), .pos = try ObjRef(usize).init(allocator, 0), .prim = null } } };
            }
            const items = try cloneItemsList(allocator, l.items);
            return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .pos = try ObjRef(usize).init(allocator, 0), .prim = null } } };
        },
        .Set => |s| {
            const items = try cloneItemsList(allocator, s.items);
            return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .pos = try ObjRef(usize).init(allocator, 0), .prim = null } } };
        },
        .Map => |m| {
            const g = m.entries.borrow();
            defer g.deinit();
            var items: std.ArrayList(Value) = .empty;
            for (g.get().items) |kv| {
                kv.key.retain();
                kv.value.retain();
                const k = try Value.boxRef(allocator, kv.key);
                const v = try Value.boxRef(allocator, kv.value);
                try items.append(allocator, .{ .MapEntry = .{ .key = k, .value = v, .backing = null } });
            }
            return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .pos = try ObjRef(usize).init(allocator, 0), .prim = null } } };
        },
        .Range => |r| {
            return .{ .ok = .{ .RangeIter = .{ .cur = try ObjRef(i64).init(allocator, r.start), .end = r.end, .step = r.step, .kind = r.kind } } };
        },
        .Array => |arr| {
            const items = try cloneItemsList(allocator, arr.items);
            return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .pos = try ObjRef(usize).init(allocator, 0), .prim = arr.prim } } };
        },
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            var items: std.ArrayList(Value) = .empty;
            const view = std.unicode.Utf8View.init(g.get().*) catch {
                for (g.get().*) |b| try items.append(allocator, .{ .Char = b });
                return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .pos = try ObjRef(usize).init(allocator, 0), .prim = null } } };
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
            return .{ .ok = .{ .Iterator = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .pos = try ObjRef(usize).init(allocator, 0), .prim = null } } };
        },
        else => return null,
    }
}

fn isBuiltinScalar(v: *const Value) bool {
    return switch (v.*) {
        .String, .Int, .Long, .Short, .Byte, .Double, .Float, .Bool, .Char => true,
        else => false,
    };
}

fn eqIgnoreCase(allocator: Allocator, a: StringRef, b: StringRef) bool {
    const ag = a.borrow();
    defer ag.deinit();
    const bg = b.borrow();
    defer bg.deinit();
    const la = std.ascii.allocLowerString(allocator, ag.get().*) catch return false;
    const lb = std.ascii.allocLowerString(allocator, bg.get().*) catch return false;
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
        if (@intFromEnum(fid) < mod.funcs.items.len) {
            const f = mod.funcs.items[@intFromEnum(fid)];
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
            if (args[0].asI64()) |n| break :blk .{ .Take = n };
        }
        if (std.mem.eql(u8, name, "drop") and args.len == 1) {
            if (args[0].asI64()) |n| break :blk .{ .Drop = n };
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
    if (std.mem.eql(u8, name, "constrainOnce") and args.len == 0) return .{ .ok = receiver.* };
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
        "toList",          "toMutableList", "toSet",   "count",      "sum",        "average",
        "sumOf",           "last",          "lastOrNull", "forEach", "fold",       "reduce",
        "iterator",        "max",           "maxOrNull", "min",      "minOrNull",  "maxBy",
        "minBy",           "maxByOrNull",   "minByOrNull", "maxOf",  "minOf",      "joinToString",
        "all",             "contains",      "groupBy", "associate",  "associateBy", "associateWith",
        "partition",       "indexOf",       "indexOfFirst", "toMap", "toHashSet",  "toMutableSet",
        "windowed",        "chunked",       "zipWithNext", "zip",     "unzip",      "scan",
        "runningFold",     "runningReduce", "plus",    "minus",      "reduceOrNull", "foldRight",
        "reduceRight",
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
                defer if (runtime.reclaimEnabled()) allocator.free(no_such);
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
        const enum_name = try StringRef.init(allocator, cg.get().name);
        cg.deinit();
        return .{ .ok = .{ .List = .{
            .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
            .mutable = false,
            .enum_class = enum_name,
            .backing = null,
        } } };
    }
    // Enum.valueOf("X")
    if (is_enum and std.mem.eql(u8, name, "valueOf") and args.len == 1 and args[0] == .String) {
        const cg = cls.borrow();
        const sg = args[0].String.borrow();
        const want = sg.get().*;
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
        defer if (runtime.reclaimEnabled()) allocator.free(msg);
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
            return try callValueRec(self, allocator, &t, args);
        }
    }
    return null;
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
                n_str = sg.get().*;
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
        return .{ .ok = .{ .String = try StringRef.initOwned(allocator, s) } };
    }
    return null;
}

fn kfunctionReflection(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const info = self.closures.get(@intCast(receiver.IrClosure.id)) orelse return null;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = info.module orelse mg.get();
    if (@intFromEnum(info.body_func) >= mod.funcs.items.len) return null;
    const f = mod.funcs.items[@intFromEnum(info.body_func)];
    if (std.mem.eql(u8, name, "name")) {
        return .{ .ok = .{ .String = try StringRef.init(allocator, f.name) } };
    }
    if (std.mem.eql(u8, name, "parameters")) {
        var items: std.ArrayList(Value) = .empty;
        for (f.params) |p| try items.append(allocator, .{ .String = try StringRef.init(allocator, p.name) });
        return .{ .ok = try listOf(allocator, items, false) };
    }
    return null;
}

fn propertyRefDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const pg = receiver.PropertyRef.name.borrow();
    const pname = pg.get().*;
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
    if ((std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "call") or std.mem.eql(u8, name, "invoke")) and args.len == 1) {
        return try getFieldRec(self, allocator, &args[0], pname);
    }
    if (std.mem.eql(u8, name, "hashCode") and args.len == 0) {
        return .{ .ok = Value.newInt(@as(i64, valueStructuralHash(receiver))) };
    }
    if (std.mem.eql(u8, name, "equals") and args.len == 1) {
        return .{ .ok = boolVal(Value.structuralEq(receiver, &args[0])) };
    }
    if (std.mem.eql(u8, name, "toString") and args.len == 0) {
        const s = try std.fmt.allocPrint(allocator, "property {s}", .{pname});
        return .{ .ok = .{ .String = try StringRef.initOwned(allocator, s) } };
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

/// Builtin natural-order comparison. `null` when the pair is not
/// builtin-comparable (mirrors `compare_values` rejecting Instances).
fn compareValuesBuiltin(a: *const Value, b: *const Value) ?Ordering {
    if (a.* == .String and b.* == .String) {
        const ag = a.String.borrow();
        defer ag.deinit();
        const bg = b.String.borrow();
        defer bg.deinit();
        return switch (std.mem.order(u8, ag.get().*, bg.get().*)) {
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
        return if (x < y) .lt else if (x > y) .gt else .eq;
    }
    const x = a.asI64() orelse (if (a.* == .Char) @as(i64, a.Char) else return null);
    const y = b.asI64() orelse (if (b.* == .Char) @as(i64, b.Char) else return null);
    return if (x < y) .lt else if (x > y) .gt else .eq;
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
    if (std.mem.eql(u8, name, "compare") and args.len == 2) {
        const a = args[0];
        const b = args[1];
        var ord: Ordering = .eq;
        const sg = cmp.steps.borrow();
        const steps = sg.get().*;
        const descending = cmp.descending;
        sg.deinit();
        if (steps.len == 0) {
            ord = compareValuesBuiltin(&a, &b) orelse return .{ .err = try typeErr(allocator, "incomparable values", .{}) };
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
                    break :blk compareValuesBuiltin(&ka, &kb) orelse return .{ .err = try typeErr(allocator, "incomparable values", .{}) };
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
        const items = try cloneItemsList(allocator, arr.items);
        return .{ .ok = try listOf(allocator, items, false) };
    }
    if (std.mem.eql(u8, name, "toMutableList") and args.len == 0) {
        const items = try cloneItemsList(allocator, arr.items);
        return .{ .ok = try listOf(allocator, items, true) };
    }
    if (std.mem.eql(u8, name, "asList") and args.len == 0) {
        const items = try cloneItemsList(allocator, arr.items);
        return .{ .ok = try listOf(allocator, items, false) };
    }
    if (std.mem.eql(u8, name, "toTypedArray") and args.len == 0) {
        const items = try cloneItemsList(allocator, arr.items);
        return .{ .ok = .{ .Array = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .prim = null } } };
    }
    if (std.mem.eql(u8, name, "toSet") and args.len == 0) {
        const items = try cloneItemsList(allocator, arr.items);
        return .{ .ok = .{ .Set = .{ .items = try ObjRef(std.ArrayList(Value)).init(allocator, items), .mutable = false, .backing = null } } };
    }
    if (std.mem.eql(u8, name, "concatToString") and (args.len == 0 or args.len == 2)) {
        const g = arr.items.borrow();
        defer g.deinit();
        const chars = g.get().items;
        var start: usize = 0;
        var end: usize = chars.len;
        if (args.len == 2) {
            const s: usize = @intCast(@max(args[0].asI64() orelse 0, 0));
            const e: usize = @intCast(@max(args[1].asI64() orelse @as(i64, @intCast(chars.len)), 0));
            start = @min(s, chars.len);
            end = @min(e, chars.len);
        }
        var units: std.ArrayList(u16) = .empty;
        defer units.deinit(allocator);
        var i = start;
        while (i < @max(end, start)) : (i += 1) {
            if (chars[i] == .Char) try units.append(allocator, chars[i].Char);
        }
        const s = try runtime.charUnitsToString(allocator, units.items);
        return .{ .ok = .{ .String = try StringRef.initOwned(allocator, s) } };
    }
    return null;
}

fn collectionMutators(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    _ = self;
    switch (receiver.*) {
        .List => |l| {
            if (!l.mutable) return null;
            if (std.mem.eql(u8, name, "plusAssign") and args.len == 1) {
                const g = l.items.borrowMut();
                defer g.deinit();
                try g.get().append(allocator, args[0]);
                return .{ .ok = .Unit };
            }
            if (std.mem.eql(u8, name, "minusAssign") and args.len == 1) {
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
                        for (og.get().items) |kv| {
                            if (runtime.reclaimEnabled()) {
                                kv.key.retain();
                                kv.value.retain();
                            }
                            try to_put.append(allocator, kv);
                        }
                    },
                    .List => |lst| try collectPairs(allocator, &to_put, lst.items),
                    .Set => |st| try collectPairs(allocator, &to_put, st.items),
                    else => {},
                }
                const g = m.entries.borrowMut();
                defer g.deinit();
                for (to_put.items) |kv| {
                    var found = false;
                    for (g.get().items) |*slot| {
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
                    if (!found) try g.get().append(allocator, kv);
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

fn componentMembers(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    switch (receiver.*) {
        .Pair => |p| {
            if (std.mem.eql(u8, name, "component1") or std.mem.eql(u8, name, "first")) return extractOwned(p.first);
            if (std.mem.eql(u8, name, "component2") or std.mem.eql(u8, name, "second")) return extractOwned(p.second);
        },
        .Triple => |t| {
            if (std.mem.eql(u8, name, "component1") or std.mem.eql(u8, name, "first")) return extractOwned(t.first);
            if (std.mem.eql(u8, name, "component2") or std.mem.eql(u8, name, "second")) return extractOwned(t.second);
            if (std.mem.eql(u8, name, "component3") or std.mem.eql(u8, name, "third")) return extractOwned(t.third);
        },
        .MapEntry => |me| {
            if (std.mem.eql(u8, name, "component1") or std.mem.eql(u8, name, "key")) return extractOwned(me.key);
            if (std.mem.eql(u8, name, "component2") or std.mem.eql(u8, name, "value")) return extractOwned(me.value);
            if (std.mem.eql(u8, name, "setValue")) {
                const new_v = if (args.len > 0) args[0] else Value.Unit;
                const prev = me.value.asPtr().*;
                // host-returns-owned: the old value escapes as the result.
                if (runtime.reclaimEnabled()) prev.retain();
                if (me.backing) |entries| {
                    const g = entries.borrowMut();
                    defer g.deinit();
                    for (g.get().items) |*slot| {
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

fn iteratorMember(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    _ = self;
    const it = receiver.Iterator;
    if (std.mem.eql(u8, name, "hasNext") and args.len == 0) {
        const pg = it.pos.borrow();
        const p = pg.get().*;
        pg.deinit();
        const ig = it.items.borrow();
        const len = ig.get().items.len;
        ig.deinit();
        return .{ .ok = boolVal(p < len) };
    }
    if (isIteratorNext(name) and args.len == 0) {
        const pg = it.pos.borrow();
        const p = pg.get().*;
        pg.deinit();
        const ig = it.items.borrow();
        if (p >= ig.get().items.len) {
            ig.deinit();
            return .{ .err = try throwExc(allocator, "kotlin.NoSuchElementException", "iterator exhausted") };
        }
        const v = ig.get().items[p];
        // Borrowed element: the backing list still owns it, so retain before
        // handing it to the register that will own the iteration result.
        if (runtime.reclaimEnabled()) v.retain();
        ig.deinit();
        const pmg = it.pos.borrowMut();
        pmg.get().* = p + 1;
        pmg.deinit();
        return .{ .ok = v };
    }
    // `MutableIterator.remove()` — drop the element last returned by `next()`
    // (at `pos - 1`) from the backing list and rewind the cursor so the
    // following `next()` resumes correctly. A no-op before the first `next()`.
    if (std.mem.eql(u8, name, "remove") and args.len == 0) {
        const pg = it.pos.borrow();
        const p = pg.get().*;
        pg.deinit();
        if (p == 0) return .{ .ok = .Unit };
        const g = it.items.borrowMut();
        defer g.deinit();
        if (p - 1 < g.get().items.len) {
            _ = g.get().orderedRemove(p - 1);
            const pmg = it.pos.borrowMut();
            pmg.get().* = p - 1;
            pmg.deinit();
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
    const more = blk: {
        const cg = ri.cur.borrow();
        const c = cg.get().*;
        cg.deinit();
        if (ri.step > 0) break :blk c <= ri.end;
        if (ri.step < 0) break :blk c >= ri.end;
        break :blk false;
    };
    if (std.mem.eql(u8, name, "hasNext") and args.len == 0) {
        return .{ .ok = boolVal(more) };
    }
    if (isIteratorNext(name) and args.len == 0) {
        if (!more) return .{ .err = try throwExc(allocator, "kotlin.NoSuchElementException", "iterator exhausted") };
        const cg = ri.cur.borrowMut();
        const c = cg.get().*;
        cg.get().* = c +| ri.step;
        cg.deinit();
        return .{ .ok = rangeElem(c, ri.kind) };
    }
    return null;
}

fn funcAt(module: *const Module, fid: FuncId) ?Func {
    const i = @intFromEnum(fid);
    if (i >= module.funcs.items.len) return null;
    return module.funcs.items[i];
}

fn argsListFromSlice(allocator: Allocator, slice: []const Value) Allocator.Error!std.ArrayList(Value) {
    var l: std.ArrayList(Value) = .empty;
    try l.appendSlice(allocator, slice);
    return l;
}

/// Whether the class `name` (or any supertype, breadth-first) declares an
/// IR method named `mname`.
fn classHasUserMethod(self: *VmHost, allocator: Allocator, start: []const u8, mname: []const u8) bool {
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
    const has_user_override = classHasUserMethod(self, allocator, class_name, name);

    if (is_data and is_object and !has_user_override and std.mem.eql(u8, name, "toString")) {
        return .{ .ok = try strVal(allocator, class_name) };
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
        var class_name2: []const u8 = undefined;
        var class_fqn2: []const u8 = undefined;
        var n_params: usize = undefined;
        {
            const g = inst.borrow();
            const cg = g.get().class.borrow();
            class_name2 = cg.get().name;
            class_fqn2 = cg.get().fqn;
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
            // The receiver's ClassDef carries the FQN: copy() rebuilds
            // the SAME class, never a same-simple-name one from another
            // package.
            const mg2 = self.module.borrow();
            const cid_opt = mg2.get().classIdByFqn(class_fqn2) orelse mg2.get().classId(class_name2);
            mg2.deinit();
            if (cid_opt) |cid| {
                return try newInstanceById(self, allocator, cid, new_args.items, null);
            }
        }
    }
    if ((is_data or is_value) and !has_user_override and args.len == 1 and std.mem.eql(u8, name, "equals")) {
        var class_fqn: []const u8 = undefined;
        {
            const g = inst.borrow();
            const cg = g.get().class.borrow();
            class_fqn = cg.get().fqn;
            cg.deinit();
            g.deinit();
        }
        const same = args[0] == .Instance and blk: {
            const og = args[0].Instance.borrow();
            const ocg = og.get().class.borrow();
            const r = std.mem.eql(u8, ocg.get().fqn, class_fqn);
            ocg.deinit();
            og.deinit();
            break :blk r;
        };
        if (!same) return .{ .ok = boolVal(false) };
        const o = args[0].Instance;
        const lg = inst.borrow();
        const lcg = lg.get().class.borrow();
        const rg = o.borrow();
        defer {
            rg.deinit();
            lcg.deinit();
            lg.deinit();
        }
        for (lcg.get().primary_params) |p| {
            const a = lg.get().get(p.name) orelse Value.Null;
            const b = rg.get().get(p.name) orelse Value.Null;
            if (!Value.structuralEq(&a, &b)) return .{ .ok = boolVal(false) };
        }
        return .{ .ok = boolVal(true) };
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
    try buf.appendSlice(allocator, cg.get().name);
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
    return .{ .String = try StringRef.initOwned(allocator, try buf.toOwnedSlice(allocator)) };
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
                entry_tag = sg.get().*;
                sg.deinit();
            }
        }
        g.deinit();
    }
    const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ name, args.len });

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
        if (!anonMethodDisproven(self, hit, args)) {
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
    const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    const effective = f.params[skip..];
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
    const ak = anonKey(allocator, class_name, arity_name) catch return null;
    if (tbl.get().get(ak)) |e| return e;
    const pk = anonKey(allocator, class_name, name) catch return null;
    if (tbl.get().get(pk)) |e| return e;
    return null;
}

fn invokeAnonMethod(self: *VmHost, allocator: Allocator, receiver: *const Value, hit: AnonMethodEntry, args: []const Value, padding_inst: ?ObjRef(InstanceData)) Allocator.Error!EvalResult {
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

    // Layer captured outer-env names onto globals + build the capture vec.
    const prev = self.globals.clone();
    defer {
        self.globals.deinit();
        self.globals = prev;
    }
    if (hit.captures.len != 0) {
        const scoped = try ObjRef(runtime.Env).init(allocator, runtime.Env.withParent(allocator, self.globals.clone()));
        const sg = scoped.borrowMut();
        for (hit.captures) |nv| sg.get().define(nv.name, nv.value) catch {};
        sg.deinit();
        self.globals = scoped;
    }
    var cap_vec: std.ArrayList(Value) = .empty;
    for (f.capture_order) |cn| {
        if (std.mem.eql(u8, cn, "this")) {
            try cap_vec.append(allocator, receiver.*);
        } else {
            var found: Value = .Null;
            for (hit.captures) |nv| {
                if (std.mem.eql(u8, nv.name, cn)) found = nv.value;
            }
            try cap_vec.append(allocator, found);
        }
    }
    var packed_list = try argsListFromSlice(allocator, packed_args);
    _ = &packed_list;
    vmhost.emitPath(allocator, "member_anon", f.fqn, f.id, receiver, args);
    return ir.eval.evalWithCapturesIn(VmHost, allocator, module_rc, module_rc, &f, packed_list, cap_vec, self);
}

/// Build the `n_params`-length argument vector, filling positions past
/// the provided args from default-arg thunks.
fn padArgsWithDefaults(self: *VmHost, allocator: Allocator, module: *const Module, n_params: usize, provided: []const Value, defaults: ?[]const ?FuncId) Allocator.Error!union(enum) { ok: []Value, err: EvalError } {
    var call_args: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < n_params) : (i += 1) {
        if (i < provided.len) {
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

fn irMethodWalk(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
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
    var first = true;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    try queue.append(allocator, class_name);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur_name = queue.items[head];
        if (seen.contains(cur_name)) continue;
        try seen.put(cur_name, {});

        // Resolve the IR class: prefer FQN for the receiver's own class.
        var ir_class: ?ir.Class = null;
        {
            const mg = self.module.borrow();
            const mod = mg.get();
            if (first) {
                if (mod.classIdByFqn(recv_fqn)) |cid| {
                    if (@intFromEnum(cid) < mod.classes.items.len) ir_class = mod.classes.items[@intFromEnum(cid)];
                }
            }
            if (ir_class == null) {
                for (mod.classes.items) |c| {
                    if (std.mem.eql(u8, c.name, cur_name)) {
                        ir_class = c;
                        break;
                    }
                }
            }
            first = false;
            if (ir_class) |irc| {
                // Gather candidates named `name`.
                var candidates: std.ArrayList(Func) = .empty;
                defer candidates.deinit(allocator);
                for (irc.methods) |fid| {
                    if (funcAt(mod, fid)) |f| {
                        if (std.mem.eql(u8, f.name, name)) try candidates.append(allocator, f);
                    }
                }
                if (pickMethodOverload(self, candidates.items, args)) |f| {
                    var all = try prependReceiver(allocator, receiver, args);
                    // Pad defaults.
                    const defaults = blk: {
                        const pg = self.prog.borrow();
                        defer pg.deinit();
                        if (pg.get().func_defaults.get(@intFromEnum(f.id))) |d| break :blk try allocator.dupe(?FuncId, d);
                        break :blk null;
                    };
                    if (defaults != null and all.len < f.params.len) {
                        const padded = try padArgsWithDefaults(self, allocator, mod, f.params.len, all, defaults);
                        switch (padded) {
                            .ok => |p| all = p,
                            .err => |e| {
                                mg.deinit();
                                return .{ .err = e };
                            },
                        }
                    }
                    const packed_args = try packVarargArgs(self, allocator, &f, all);
                    var packed_list = try argsListFromSlice(allocator, packed_args);
                    _ = &packed_list;
                    if (trace.invariantsEnabled()) {
                        checkFuncInRange(self, "irMethodWalk", f.id);
                        checkReceiverChain(self, allocator, "irMethodWalk", receiver, null);
                    }
                    vmhost.emitPath(allocator, "member_ir_walk", f.fqn, f.id, receiver, args);
                    const r = try ir.eval.evalWith(VmHost, allocator, mod, &f, packed_list, self);
                    mg.deinit();
                    return r;
                }
            }
            mg.deinit();
        }
        const cg = self.classes.borrow();
        if (cg.get().get(cur_name)) |def| {
            const dg = def.borrow();
            for (dg.get().supertype_names) |sup| try queue.append(allocator, sup);
            dg.deinit();
        }
        cg.deinit();
    }
    return null;
}

fn anyInstanceFallback(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    _ = self;
    const inst = receiver.Instance;
    if (args.len == 0 and std.mem.eql(u8, name, "toString")) {
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
        return .{ .ok = .{ .String = try StringRef.initOwned(allocator, s) } };
    }
    if (args.len == 0 and std.mem.eql(u8, name, "hashCode")) {
        const g = inst.borrow();
        defer g.deinit();
        return .{ .ok = Value.newInt(@bitCast(g.get().identity)) };
    }
    if (args.len == 1 and std.mem.eql(u8, name, "equals")) {
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
    try buf.appendSlice(allocator, cls.name);
    try buf.append(allocator, '(');
    for (cls.primary_params, 0..) |p, idx| {
        if (idx > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, p.name);
        try buf.append(allocator, '=');
        const v = inst.get(p.name) orelse Value.Null;
        try buf.appendSlice(allocator, try v.display(allocator));
    }
    try buf.append(allocator, ')');
    return .{ .String = try StringRef.initOwned(allocator, try buf.toOwnedSlice(allocator)) };
}

fn stdlibMemberDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const type_fqn = receiver.typeFqn();
    var probes: std.ArrayList([]const u8) = .empty;
    // Probe FQNs are per-call scratch (all `allocPrint`ed below); free them and
    // the list. No-op under the arena; reclaims under a freeing allocator.
    defer {
        if (runtime.reclaimEnabled()) for (probes.items) |p| allocator.free(p);
        probes.deinit(allocator);
    }
    if (args.len == 0) {
        try probes.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_fqn, name }));
        try probes.append(allocator, try std.fmt.allocPrint(allocator, "kotlin.collections.{s}", .{name}));
        try probes.append(allocator, try std.fmt.allocPrint(allocator, "kotlin.text.{s}", .{name}));
        try probes.append(allocator, try std.fmt.allocPrint(allocator, "kotlin.ranges.{s}", .{name}));
        try probes.append(allocator, try std.fmt.allocPrint(allocator, "kotlin.{s}", .{name}));
    } else {
        try probes.append(allocator, try std.fmt.allocPrint(allocator, "kotlin.ranges.{s}", .{name}));
        try probes.append(allocator, try std.fmt.allocPrint(allocator, "kotlin.collections.{s}", .{name}));
        try probes.append(allocator, try std.fmt.allocPrint(allocator, "kotlin.text.{s}", .{name}));
        try probes.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_fqn, name }));
        try probes.append(allocator, try std.fmt.allocPrint(allocator, "kotlin.{s}", .{name}));
    }
    // Sibling read-only/mutable collection type.
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
        const probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sib, name });
        const anchor = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_fqn, name });
        defer if (runtime.reclaimEnabled()) allocator.free(anchor);
        var inserted = false;
        for (probes.items, 0..) |p, idx| {
            if (std.mem.eql(u8, p, anchor)) {
                try probes.insert(allocator, idx + 1, probe);
                inserted = true;
                break;
            }
        }
        if (!inserted) try probes.append(allocator, probe);
    }
    // Throwable family probe.
    if (receiver.* == .Instance) {
        if (instanceIsThrowable(self, allocator, receiver.Instance)) {
            try probes.append(allocator, try std.fmt.allocPrint(allocator, "kotlin.Throwable.{s}", .{name}));
        }
    }

    const member_shadows_stdlib = receiver.* == .Instance and hostHasMember(self, receiver, name);
    const user_member_ext_shadows = try userMemberExtShadows(self, allocator, name, args.len);

    // Array builder global factory direct dispatch.
    if (stdlib.isArrayBuilder(name) and !hostHasMember(self, receiver, name)) {
        const probe = try std.fmt.allocPrint(allocator, "kotlin.{s}", .{name});
        defer if (runtime.reclaimEnabled()) allocator.free(probe);
        if (lookupIntrinsic(self, probe)) |func| {
            return try dispatchIntrinsic(self, allocator, probe, func, args);
        }
    }

    if (!member_shadows_stdlib and !user_member_ext_shadows and !stdlib.isToplevelFunction(name)) {
        for (probes.items) |probe| {
            if (lookupIntrinsic(self, probe)) |func| {
                const all_args = try prependReceiver(allocator, receiver, args);
                defer if (runtime.reclaimEnabled()) allocator.free(all_args);
                return try dispatchIntrinsic(self, allocator, probe, func, all_args);
            }
        }
    }
    return null;
}

fn instanceIsThrowable(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData)) bool {
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
fn memberExtVisible(self: *VmHost, mod: *const Module, fid: FuncId, visible_owners: *const std.StringHashMap(void)) bool {
    if (!isMemberExt(mod, fid)) return true;
    const owner = mod.registry.member_ext_owner_class.get(fid) orelse return true;
    if (visible_owners.contains(owner)) return true;
    // A member extension declared in an `object`/companion is callable
    // wherever the singleton is importable (`import C.Companion.f`): its
    // dispatch receiver is the singleton itself, which is always
    // materializable, so the enclosing-`this` chain need not carry it.
    return ownerIsObjectSingleton(self, owner);
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
fn userMemberExtShadows(self: *VmHost, allocator: Allocator, name: []const u8, argc: usize) Allocator.Error!bool {
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
            if (f.params.len != 0 and f.params.len >= want) return true;
        }
    }
    return false;
}

/// Set of class names (with parents) reachable through the enclosing-this
/// chain, including each instance's `outer` links.
fn enclosingOwnerSet(self: *VmHost, allocator: Allocator) Allocator.Error!std.StringHashMap(void) {
    var set: std.StringHashMap(void) = .init(allocator);
    const chain = try enclosingThisChain(self, allocator);
    defer allocator.free(chain);
    for (chain) |v| {
        var cur: ?Value = v;
        while (cur) |cv| {
            if (cv == .Instance) {
                const g = cv.Instance.borrow();
                const cg = g.get().class.borrow();
                set.put(cg.get().name, {}) catch {};
                set.put(cg.get().fqn, {}) catch {};
                var p = blk: {
                    const pp = cg.get().parent;
                    break :blk if (pp) |x| x.clone() else null;
                };
                cg.deinit();
                while (p) |pp| {
                    const ppg = pp.borrow();
                    set.put(ppg.get().name, {}) catch {};
                    set.put(ppg.get().fqn, {}) catch {};
                    const next = ppg.get().parent;
                    ppg.deinit();
                    pp.deinit();
                    p = if (next) |x| x.clone() else null;
                }
                const outer = g.get().outer;
                g.deinit();
                cur = outer;
            } else break;
        }
    }
    return set;
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
                // else: swallow all errors and continue.
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

fn extensionFnFallback(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8) Allocator.Error!?EvalResult {
    const want = args.len + 1;
    var visible_owners = try enclosingOwnerSet(self, allocator);
    defer visible_owners.deinit();

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        for (mod.funcsBySimpleName(name)) |fid| {
            const f = funcAt(mod, fid) orelse continue;
            if (!(f.params.len >= want and f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this"))) continue;
            if (!memberExtVisible(self, mod, fid, &visible_owners)) continue;
            try candidates.append(allocator, .{ .fid = fid, .func = f });
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
            if (!recv_fits) continue;
            if (!extArityApplicable(self, &c.func, want)) continue;
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
        var any_compat = false;
        for (candidates.items) |c| {
            if (receiverCompatibleWithParam(receiver, &c.func.params[0].ty) and
                !receiverDefinitelyNotParam(self, &c.func.params[0].ty, receiver)) any_compat = true;
        }
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
        chosen = try scoreExtCandidates(self, allocator, receiver, candidates.items, args, want);
    }

    if (chosen == null) return null;

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
        const seq = try std.fmt.allocPrint(allocator, "kotlin.sequences.{s}", .{name});
        if (!(std.mem.eql(u8, c.func.fqn, coll) or std.mem.eql(u8, c.func.fqn, seq))) break :blk false;
        if (!hostHasMember(self, receiver, "iterator")) break :blk false;
        const ip = try std.fmt.allocPrint(allocator, "kotlin.collections.Iterable.{s}", .{name});
        const lp = try std.fmt.allocPrint(allocator, "kotlin.collections.List.{s}", .{name});
        break :blk (lookupIntrinsic(self, ip) != null) or (lookupIntrinsic(self, lp) != null);
    };

    if (!defer_to_property and !defer_to_iterable) {
        const c = chosen.?;
        const all = try prependReceiver(allocator, receiver, args);
        const mg = self.module.borrow();
        const mod = mg.get();
        // A member-extension's body has its declaring class's `this` in
        // lexical scope (the dispatch receiver that made it visible
        // here). Seed the callee frame with that owner instance: push it
        // as a transferable enclosing receiver for the duration of the
        // call.
        var pushed_owner = false;
        if (mod.registry.member_ext_owner_class.get(c.fid)) |owner| {
            if (try memberExtOwnerInstance(self, allocator, receiver, owner)) |inst| {
                ir.eval.pushEnclosing(&inst);
                pushed_owner = true;
            }
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
///   0. receiver specificity — the candidate whose receiver param most
///      specifically matches the receiver's runtime type (a `Flow` receiver
///      selects `Flow.forEach`, not the generic `Iterable.forEach`);
///   1. applicability score — the numeric arg/param compatibility;
///   2. owner rank — a member extension visible nearer on the enclosing-`this`
///      chain;
///   3. subtype specificity — how many other candidates' receiver types are
///      supertypes of this one;
///   4. parameter specificity — the most-specific declared parameter types
///      for the supplied value args;
///   5. a stable key (lowest `FuncId`) so the winner is always unique.
const ExtKey = [7]i32;

fn extKeyGreater(a: ExtKey, b: ExtKey) bool {
    inline for (0..a.len) |i| {
        if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
}

fn scoreExtCandidates(self: *VmHost, allocator: Allocator, receiver: *const Value, candidates: []const Candidate, args: []const Value, want: usize) Allocator.Error!?Candidate {
    var chain_owners = try enclosingChainClassOrder(self, allocator);
    defer chain_owners.deinit(allocator);

    const check_inv = trace.invariantsEnabled();
    var tied: std.ArrayList(Func) = .empty;
    defer tied.deinit(self.allocator);
    var best: ?Candidate = null;
    var best_key: ExtKey = .{std.math.minInt(i32)} ** 7;
    for (candidates, 0..) |c, idx| {
        const f = c.func;
        const recv_score = overloadScoreArg(self, &f.params[0].ty, receiver) orelse -1;
        var score: i32 = recv_score *| 1000;
        var param_spec: i32 = 0;
        // Applicability is Kotlin's hard gate: a candidate whose declared
        // parameter type a supplied value argument definitely does not
        // satisfy is removed from the overload set before any specificity
        // ranking. Without this the receiver-specificity tier could elect an
        // inapplicable sibling whose receiver matches more tightly (e.g.
        // `install(RoutingRoot, …)` selecting `Application.install(plugin:
        // ContentNegotiation, …)` over the generic `Plugin` overload).
        var applicable: i32 = 1;
        for (args, 0..) |*a, i| {
            if (f.params.len > i + 1) {
                const arg_score = overloadScoreArg(self, &f.params[i + 1].ty, a);
                if (arg_score == null and !f.params[i + 1].has_default and !f.params[i + 1].is_vararg) {
                    applicable = 0;
                }
                score += arg_score orelse -1;
                // A concrete (non-top, non-generic) param type that the arg
                // satisfies is more specific than a top/`Any`/`T` param.
                if (!isTopOrGenericType(f.params[i + 1].ty.name)) param_spec += 1;
            }
        }
        if (f.params.len == want) score += 5;
        // Receiver specificity: most-specific receiver-type match wins.
        const recv_match = extReceiverSpecificity(self, receiver, f.params[0].ty.name);
        // Subtype specificity: how many other candidates' receiver types are
        // supertypes of this one.
        var spec: i32 = 0;
        for (candidates, 0..) |o, j| {
            if (j == idx) continue;
            if (isSubtypeName(self, allocator, f.params[0].ty.name, o.func.params[0].ty.name)) spec += 1;
        }
        // Owner rank.
        var owner_rank: i32 = 0;
        {
            const mg = self.module.borrow();
            const mod = mg.get();
            if (isMemberExt(mod, c.fid)) {
                if (mod.registry.member_ext_owner_class.get(c.fid)) |owner| {
                    for (chain_owners.items, 0..) |co, pos| {
                        if (std.mem.eql(u8, co, owner)) {
                            owner_rank = @as(i32, @intCast(chain_owners.items.len)) - @as(i32, @intCast(pos));
                            break;
                        }
                    }
                }
            }
            mg.deinit();
        }
        // Stable final discriminator: lowest FuncId. Negated so a smaller id
        // ranks higher, guaranteeing a unique winner.
        const neg_fid: i32 = -@as(i32, @intCast(@intFromEnum(c.fid) & 0x7fff_ffff));
        const key: ExtKey = .{ applicable, recv_match, score, owner_rank, spec, param_spec, neg_fid };
        if (check_inv and best != null and std.mem.eql(i32, &key, &best_key)) {
            tied.append(self.allocator, f) catch {};
        }
        if (best == null or extKeyGreater(key, best_key)) {
            best = c;
            best_key = key;
            if (check_inv) {
                tied.clearRetainingCapacity();
                tied.append(self.allocator, f) catch {};
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
    for (chain) |value| {
        var cur: ?Value = value;
        while (cur) |cv| {
            if (cv == .Instance) {
                const g = cv.Instance.borrow();
                const cg = g.get().class.borrow();
                try v.append(allocator, cg.get().name);
                var p = blk: {
                    const pp = cg.get().parent;
                    break :blk if (pp) |x| x.clone() else null;
                };
                cg.deinit();
                while (p) |pp| {
                    const ppg = pp.borrow();
                    try v.append(allocator, ppg.get().name);
                    const next = ppg.get().parent;
                    ppg.deinit();
                    pp.deinit();
                    p = if (next) |x| x.clone() else null;
                }
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
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, false, null);
}

/// `callMemberNamed` with the receiver's DECLARED type head (a bare call
/// on the implicit `this` of an extension body). Extension dispatch then
/// resolves against the static type, as kotlinc does.
pub fn callMemberNamedStatic(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, false, static_recv);
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
    return callMemberNamedInner(self, allocator, receiver, name, args, arg_names, true, static_recv);
}

fn callMemberNamedInner(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, strict_ext: bool, static_recv: ?[]const u8) Allocator.Error!EvalResult {
    var any_named = false;
    for (arg_names) |n| {
        if (n != null) any_named = true;
    }

    // data-class `copy(name = …)`.
    if (std.mem.eql(u8, name, "copy") and receiver.* == .Instance) {
        if (try copyNamed(self, allocator, receiver, args, arg_names)) |r| return r;
    }

    // Stdlib intrinsic dispatch with named args.
    if (any_named) {
        if (try stdlibNamedDispatch(self, allocator, receiver, name, args, arg_names)) |r| return r;
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
        const fqn_probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cfqn, name });
        var class_id = mod.classIdByFqn(fqn_probe);
        if (class_id == null and !std.mem.eql(u8, cname, cfqn)) {
            const name_probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cname, name });
            class_id = mod.classIdByFqn(name_probe);
        }
        mg.deinit();
        if (class_id) |cid| {
            return self.newInstanceNamed(allocator, cid, args, arg_names, null);
        }
    }

    // Positional dispatch first.
    const primary = try callMemberInnerStatic(self, allocator, receiver, name, args, strict_ext, static_recv);
    if (!(primary == .err and primary.err == .Unimplemented)) return primary;

    // Class-hierarchy method walk for a class-qualified lowered name.
    if (receiver.* == .Instance) {
        if (try instanceMethodWalkNamed(self, allocator, receiver, name, args, null)) |r| return r;
    }
    return primary;
}

fn copyNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var is_data = false;
    var n_params: usize = 0;
    var class_name: []const u8 = undefined;
    var class_fqn: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        is_data = cg.get().is_data;
        n_params = cg.get().primary_params.len;
        class_name = cg.get().name;
        class_fqn = cg.get().fqn;
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
    // Same FQN-keyed rebuild as the positional `copy` path.
    const mg2 = self.module.borrow();
    const cid_opt = mg2.get().classIdByFqn(class_fqn) orelse mg2.get().classId(class_name);
    mg2.deinit();
    if (cid_opt) |cid| {
        return try newInstanceById(self, allocator, cid, new_args.items, null);
    }
    return null;
}

fn stdlibNamedDispatch(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    const type_fqn = receiver.typeFqn();
    const probes = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_fqn, name }),
        try std.fmt.allocPrint(allocator, "kotlin.text.{s}", .{name}),
        try std.fmt.allocPrint(allocator, "kotlin.collections.{s}", .{name}),
        try std.fmt.allocPrint(allocator, "kotlin.{s}", .{name}),
    };
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
    }
    if (resolveExtOverloadLocal(self, allocator, name, receiver, args, arg_names)) |fid| {
        const all = try prependReceiver(allocator, receiver, args);
        var names = try allocator.alloc(?[]const u8, arg_names.len + 1);
        names[0] = null;
        @memcpy(names[1..], arg_names);
        const mg = self.module.borrow();
        const mod = mg.get();
        const r = try callFuncNamedRec(self, allocator, mod, fid, all, names);
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
            if (!(f.params.len >= want and f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this"))) continue;
            if (!memberExtVisible(self, mod, fid, &visible_owners)) continue;
            // Every supplied argument name must name one of the candidate's
            // params (kotlinc: a candidate without the named param is not
            // applicable) — `invokeOnCompletion(onCancelling = true) { }`
            // must not bind an extension that has no `onCancelling`.
            var names_fit = true;
            for (arg_names) |maybe_n| {
                const n = maybe_n orelse continue;
                var found = false;
                for (f.params) |*p| {
                    if (std.mem.eql(u8, p.name, n)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    names_fit = false;
                    break;
                }
            }
            if (!names_fit) continue;
            candidates.append(allocator, .{ .fid = fid, .func = f }) catch {};
        }
    }
    if (candidates.items.len == 0) return null;
    if (candidates.items.len == 1) return candidates.items[0].fid;
    const chosen = scoreExtCandidates(self, allocator, receiver, candidates.items, args, want) catch return null;
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
        if (pickMethodOverload(self, &one, args) != null) return true;
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
            } else if (effective.len == 0 or !effective[effective.len - 1].is_vararg) {
                return false;
            }
            positional += 1;
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

/// Mirrors `memberApplicableForWalk`'s last-param shape test: a declared
/// function type, a typealias expanding to one, or a bare type parameter.
fn lastParamIsFunctionShaped(self: *VmHost, p: *const ir.Param) bool {
    const last_ty = resolveAliasName(self, p.ty.name);
    return std.mem.startsWith(u8, last_ty, "Function") or
        std.mem.indexOf(u8, last_ty, "->") != null or
        (last_ty.len > 0 and last_ty.len <= 2 and allUppercase(last_ty));
}

fn instanceMethodWalkNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: ?[]const ?[]const u8) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var start: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        start = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    try queue.append(allocator, start);
    var method_fid: ?FuncId = null;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (seen.contains(cur)) continue;
        try seen.put(cur, {});
        {
            const mg = self.module.borrow();
            const mod = mg.get();
            for (mod.classes.items) |c| {
                if (std.mem.eql(u8, c.name, cur)) {
                    for (c.methods) |fid| {
                        if (funcAt(mod, fid)) |f| {
                            if (std.mem.eql(u8, f.name, name) or std.mem.eql(u8, simpleName(f.name), name)) {
                                // A name match alone is not a candidate:
                                // the member must be *applicable* to the
                                // supplied args (an unsupplied param needs
                                // a default or vararg slot, a named arg
                                // needs a matching param, a typed arg must
                                // not definitely mismatch), or Kotlin
                                // resolution moves on to the next tier.
                                if (memberApplicableForWalkNamed(self, &f, args, arg_names)) {
                                    method_fid = fid;
                                    break;
                                }
                            }
                        }
                    }
                }
                if (method_fid != null) break;
            }
            mg.deinit();
        }
        if (method_fid != null) break;
        const cg = self.classes.borrow();
        if (cg.get().get(cur)) |def| {
            const dg = def.borrow();
            for (dg.get().supertype_names) |s| try queue.append(allocator, s);
            dg.deinit();
        }
        cg.deinit();
    }
    if (method_fid) |fid| {
        const all = try prependReceiver(allocator, receiver, args);
        var names = try allocator.alloc(?[]const u8, all.len);
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
        const r = try callFuncNamedRec(self, allocator, mod, fid, all, names);
        mg.deinit();
        return r;
    }
    return null;
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
        return .{ .ok = receiver.* };
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
    try fields.append(allocator, .{ .name = "__bound_name__", .value = .{ .String = try ObjRef([]const u8).initOwned(allocator, name_dup) } });
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
    return allocator.dupe(u8, sups[0]) catch null;
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
    var parent_name: ?[]const u8 = null;
    if (qualifier) |q| {
        if (ownerHasSupertype(self, owner_class, q)) {
            parent_name = try allocator.dupe(u8, q);
        } else {
            parent_name = firstSupertypeName(self, allocator, q);
        }
    } else {
        parent_name = firstSupertypeName(self, allocator, owner_class);
    }
    const start = parent_name orelse {
        return .{ .err = try typeErr(allocator, "super.{s}: owner_class `{s}` has no parent", .{ name, owner_class }) };
    };

    // Walk the supertype chain starting at `start` and dispatch the first
    // class on the chain that declares the method. Falling through to
    // call_member would re-enter virtual dispatch on the original
    // receiver and recurse forever for overriding methods.
    var current: ?[]const u8 = start;
    var step: usize = 0;
    while (current) |cname| {
        if (step > 128) break;
        step += 1;
        current = null;
        // First, an IR class method named `name` on this class.
        {
            const mg = self.module.borrow();
            const m = mg.get();
            var found_fid: ?FuncId = null;
            for (m.classes.items) |*cls_ir| {
                if (!std.mem.eql(u8, cls_ir.name, cname)) continue;
                for (cls_ir.methods) |fid| {
                    const i = @intFromEnum(fid);
                    if (i >= m.funcs.items.len) continue;
                    if (std.mem.eql(u8, m.funcs.items[i].name, name)) {
                        found_fid = fid;
                        break;
                    }
                }
                break;
            }
            if (found_fid) |fid| {
                const func = m.funcs.items[@intFromEnum(fid)];
                mg.deinit();
                var all: std.ArrayList(Value) = .empty;
                try all.append(allocator, receiver.*);
                try all.appendSlice(allocator, args);
                const module_ref = self.module.clone();
                defer module_ref.deinit();
                emitSuperPath(allocator, func.fqn, fid, cname, args);
                return ir.eval.evalWith(VmHost, allocator, module_ref.borrow().get(), &func, all, self);
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
                const i = @intFromEnum(fid);
                const mg = self.module.borrow();
                const m = mg.get();
                if (i < m.funcs.items.len) {
                    const func = m.funcs.items[i];
                    mg.deinit();
                    var all: std.ArrayList(Value) = .empty;
                    try all.append(allocator, receiver.*);
                    const module_ref = self.module.clone();
                    defer module_ref.deinit();
                    emitSuperPath(allocator, func.fqn, fid, cname, args);
                    return ir.eval.evalWith(VmHost, allocator, module_ref.borrow().get(), &func, all, self);
                }
                mg.deinit();
            }
        }
        // Step to the next non-interface supertype.
        current = firstSupertypeName(self, allocator, cname);
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
            const is_throwable = instanceIsThrowable(self, allocator, inst);
            const ig = inst.borrow();
            defer ig.deinit();
            const fqn = blk: {
                const cg = ig.get().class.borrow();
                defer cg.deinit();
                break :blk cg.get().fqn;
            };
            if (is_throwable) {
                const msg: ?[]const u8 = if (ig.get().get("message")) |mv| switch (mv) {
                    .String => |s| blk2: {
                        const sg = s.borrow();
                        defer sg.deinit();
                        break :blk2 try allocator.dupe(u8, sg.get().*);
                    },
                    else => null,
                } else null;
                const s = if (msg) |m|
                    try std.fmt.allocPrint(allocator, "{s}: {s}", .{ fqn, m })
                else
                    try allocator.dupe(u8, fqn);
                return .{ .ok = .{ .String = try ObjRef([]const u8).initOwned(allocator, s) } };
            }
            const s = try std.fmt.allocPrint(allocator, "{s}@{x}", .{ fqn, ig.get().identity });
            return .{ .ok = .{ .String = try ObjRef([]const u8).initOwned(allocator, s) } };
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
        const o_inst = encl_v.Instance;
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
    return .{ .err = try typeErr(allocator, "`this@{s}` is not bound in this scope", .{qualifier}) };
}

const testing = std.testing;

test "simpleName returns the trailing dotted segment" {
    try testing.expectEqualStrings("C", simpleName("a.b.C"));
    try testing.expectEqualStrings("C", simpleName("C"));
    try testing.expectEqualStrings("", simpleName("a."));
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
    const s = try StringRef.init(testing.allocator, "ABC");
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
    const a = try StringRef.init(testing.allocator, "abc");
    defer a.deinit();
    const b = try StringRef.init(testing.allocator, "abd");
    defer b.deinit();
    try testing.expectEqual(Ordering.lt, compareValuesBuiltin(&.{ .String = a }, &.{ .String = b }).?);
}

test {
    testing.refAllDecls(@This());
}
