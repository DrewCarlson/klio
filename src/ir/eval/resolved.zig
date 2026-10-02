//! The frame interpreter's arms for the instructions lowered from sema
//! (`CallStatic` through `NewArray`): one `exec*` per variant, called from
//! `execInst`. Every operand is an id into `Module.resolved` or the
//! module's own tables; no arm reads a name, and a miss is an internal
//! error naming the ids, never a fallback.
//!
//! Calls run as flat activations: the arm leaves a `FlatCallReq` on the
//! thread's state and the driver pushes it, so a callee that suspends parks at
//! its call-return point with the call's `dst` as its resume register. A
//! callee's parameters are the call's argument run, read in place in the
//! caller's registers; a call that adds a receiver or a bound value first
//! copies them into an argument area on the value stack. An init
//! unit, an object's constructor and an exception's constructor run
//! recursively through `host.runResolved`, because the instruction needs
//! their result before it continues.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_state = @import("state.zig");
const ev_diag = @import("diag.zig");

const ev_values = @import("values.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const MethodSlotId = ir.MethodSlotId;
const NativeId = ir.NativeId;
const Reg = ir.Reg;
const Resolved = ir.resolved.Resolved;
const StateRef = ir.resolved.StateRef;
const ClosureBody = ir.resolved.ClosureBody;
const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const Frame = ev_frame.Frame;
const Step = ev_flow.Step;
const raiseStep = ev_flow.raiseStep;

// ---------------------------------------------------------------------------
// Shared pieces

/// An internal error: what the tables or the host lack, by id.
fn internal(a: Allocator, frame: *Frame, comptime fmt: []const u8, args: anytype) Allocator.Error!Step {
    const msg = try std.fmt.allocPrint(a, fmt, args);
    // `KLIO_ERR_TRACE`: where the tables or the host fell short.
    if (ev_diag.errTraceOn()) {
        std.debug.print("[errtrace] {s}\n", .{msg});
        ev_diag.dumpFrameChainForDiagAlways();
    }
    return raiseStep(frame, .{ .Unsupported = msg });
}

fn noTables(frame: *Frame, comptime variant: []const u8) Step {
    return raiseStep(frame, .{ .Unsupported = variant ++ ": the module has no resolved tables" });
}

fn noState(frame: *Frame, comptime variant: []const u8) Step {
    return raiseStep(frame, .{ .Unsupported = variant ++ ": the host has no resolved state" });
}

/// Writes a call's result, or raises its error.
fn land(frame: *Frame, res: EvalResult, dst: Reg) Allocator.Error!Step {
    switch (res) {
        .ok => |v| try frame.write(dst, v),
        .err => |e| return raiseStep(frame, e),
    }
    return .cont;
}

fn regAt(base: Reg, i: usize) Reg {
    return Reg.from(base.int() + @as(u32, @intCast(i)));
}

/// The run `args[from..n]` of the caller's registers, in place.
inline fn runOf(frame: *const Frame, args: Reg, from: u32, n: u32) []const Value {
    return ev_frame.argRun(frame, regAt(args, from), n - from);
}

/// An argument area holding `prefix` and then the run `args[from..n]`: the
/// parameters of a callee that takes a value before the call's arguments.
fn area(frame: *Frame, prefix: []const Value, args: Reg, from: u32, n: u32) Allocator.Error!ev_frame.ArgArea {
    return ev_frame.ArgArea.push(frame.tls, prefix, runOf(frame, args, from, n));
}

fn valueTag(v: *const Value) []const u8 {
    return @tagName(std.meta.activeTag(v.*));
}

/// The class of `v` in the tables: a closure's from the host's side table,
/// any other value's from `ir.resolved.classOf`.
fn valueClass(comptime H: type, host: *H, r: *const Resolved, v: *const Value) ?ClassId {
    if (v.* == .IrClosure) {
        const body = host.resolvedClosure(v) orelse return null;
        const arity = body.arity();
        const h = &r.host_class;
        // A suspend lambda is a `SuspendFunctionN`.
        const suspend_class = body.kind == .lambda and body.func.is_suspend and
            arity < h.suspend_function.len and h.suspend_function[arity].int() != ir.resolved.NONE;
        const by_arity: []const ClassId = switch (body.kind) {
            .property_ref => |p| if (p.setter != ir.NO_FUNC) h.mutable_property else h.property,
            else => if (suspend_class) h.suspend_function else h.function,
        };
        return if (arity < by_arity.len) by_arity[arity] else null;
    }
    return ir.resolved.classOf(r, v);
}

/// Runs `func` over `params`: its native when the tables bind one, else its
/// body as a flat activation (recursively when the flat driver is off).
/// `params` is the call's argument run or the argument area pushed at `at`,
/// which the callee's frame takes over, or which is popped here when the
/// call ends before one opens.
fn runFunc(
    comptime H: type,
    a: Allocator,
    frame: *Frame,
    host: *H,
    r: *const Resolved,
    func: FuncId,
    params: []const Value,
    at: ?ev_state.VsMark,
    dst: Reg,
) Allocator.Error!Step {
    const ev = frame.tls;
    if (runtime.envOnce("KLIO_FAULT_INJECT")) |spec| if (frame.module.funcById(func)) |f| if (injectedFault(spec, f.fqn)) {
        if (at) |m| ev.vstack.restore(m);
        return internal(a, frame, "injected internal error in `{s}`", .{f.fqn});
    };
    // A fast path the host fronts the body with answers first, or declines.
    if (func.int() < r.func_try.len and r.func_try[func.int()] != .none) {
        if (try host.tryNative(a, r.func_try[func.int()], params)) |res| {
            if (at) |m| ev.vstack.restore(m);
            return land(frame, res, dst);
        }
    }
    if (func.int() < r.func_native.len) {
        const nid = r.func_native[func.int()];
        if (nid != .none) {
            // A Kotlin receiver's own override of the member answers
            // (`NativeRt.slot`); `super` calls the native directly.
            const res = if (comptime @hasDecl(H, "callNativeSite"))
                (if (params.len != 0 and params[0] == .Instance) try host.callNativeSite(a, nid, params) else try host.callNative(a, nid, params))
            else
                try host.callNative(a, nid, params);
            if (at) |m| ev.vstack.restore(m);
            return land(frame, res, dst);
        }
    }
    const f = frame.module.funcById(func) orelse {
        if (at) |m| ev.vstack.restore(m);
        return internal(a, frame, "call: function #{d} is not in the module", .{func.int()});
    };
    if (!f.hasBody()) {
        if (at) |m| ev.vstack.restore(m);
        return internal(a, frame, "call: function #{d} ({s}) has no body and no native", .{ func.int(), f.fqn });
    }
    if (ev_flow.flatEnabled()) {
        ev.flat_call = .{ .func = f, .params = params, .area = at, .dst = dst };
        return .flat_call;
    }
    const res = try ev_enter.evalView(H, a, frame.module, null, f, params, &.{}, at, null, host);
    return land(frame, res, dst);
}

/// Throws the exception the VM raises for `which`, built by its constructor
/// with `message`.
fn throwVm(
    comptime H: type,
    a: Allocator,
    frame: *Frame,
    host: *H,
    r: *const Resolved,
    which: ?ir.resolved.Raised,
    comptime kind: []const u8,
    message: ?[]const u8,
) Allocator.Error!Step {
    const raised = which orelse return raiseStep(frame, .{ .Unsupported = "the tables name no class for " ++ kind });
    if (raised.class.int() >= r.classes.len) return internal(a, frame, kind ++ ": class #{d} is not in the tables", .{raised.class.int()});
    const exc = try ir.resolved.instantiate(a, r, raised.class);
    const msg_v: Value = if (message) |m| .{ .String = try runtime.strInit(a, m) } else .Null;
    defer msg_v.release(a);
    const res = try host.runResolved(a, frame.module, raised.ctor, &.{ exc, msg_v });
    switch (res) {
        .ok => |v| v.release(a),
        .err => |e| {
            exc.release(a);
            return raiseStep(frame, e);
        },
    }
    return raiseStep(frame, .{ .Throw = exc });
}

/// Whether `KLIO_FAULT_INJECT`'s `spec`, `internal-error@<fqn>`, names the
/// function `fqn`: a call of it then raises an internal error instead of
/// running, which the paths handling one are tested with.
fn injectedFault(spec: []const u8, fqn: []const u8) bool {
    const prefix = "internal-error@";
    if (!std.mem.startsWith(u8, spec, prefix)) return false;
    return std.mem.eql(u8, spec[prefix.len..], fqn);
}

test "a fault spec names one function by its qualified name" {
    try std.testing.expect(injectedFault("internal-error@trigger", "trigger"));
    try std.testing.expect(injectedFault("internal-error@demo.trigger", "demo.trigger"));
    try std.testing.expect(!injectedFault("internal-error@trigger", "demo.trigger"));
    try std.testing.expect(!injectedFault("trigger", "trigger"));
}

/// Headroom past the evaluation-depth cap for building the
/// `StackOverflowError` the cap raises: its constructor chain runs above
/// the frame that hit the cap. On a stack down to its reserve, half the
/// reserve opens for it the same way.
const overflow_headroom: usize = 64;

/// The `klio.StackOverflowError` a call past the evaluation-depth cap
/// throws in a module lowered from sema, built with a null message as the
/// JVM's is; null when the tables name no such class.
pub fn stackOverflowError(comptime H: type, a: Allocator, module: *const ir.Module, host: *H) Allocator.Error!?Value {
    const r = module.resolved orelse return null;
    const raised = r.exceptions.by_fqn.get("klio.StackOverflowError") orelse return null;
    if (raised.class.int() >= r.classes.len) return null;
    const tls = ev_state.evtlsPtr();
    const cap = ev_state.evalDepthCap(tls);
    tls.eval_depth_cap = cap + overflow_headroom;
    defer tls.eval_depth_cap = cap;
    const floor = runtime.openStackReserve();
    defer runtime.closeStackReserve(floor);
    var exc = try ir.resolved.instantiate(a, r, raised.class);
    // Its trace is the stack that overflowed, the innermost frames of it.
    try ev_diag.attachStackTrace(a, &exc);
    const res = try host.runResolved(a, module, raised.ctor, &.{ exc, .Null });
    switch (res) {
        .ok => |v| v.release(a),
        .err => {
            exc.release(a);
            return null;
        },
    }
    return exc;
}

fn throwNpe(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved, message: ?[]const u8) Allocator.Error!Step {
    return throwVm(H, a, frame, host, r, r.exceptions.null_pointer, "NullPointerException", message);
}

/// `!!` on null in a module lowered from sema.
pub fn throwNotNull(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved) Allocator.Error!Step {
    return throwNpe(H, a, frame, host, r, null);
}

/// A `lateinit` read before its first write, in a module lowered from sema.
pub fn throwUninitialized(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved, property: []const u8) Allocator.Error!Step {
    const msg = try std.fmt.allocPrint(a, "lateinit property {s} has not been initialized", .{property});
    return throwVm(H, a, frame, host, r, r.exceptions.uninitialized_property, "UninitializedPropertyAccessException", msg);
}

/// Integer division or remainder by zero, in a module lowered from sema.
pub fn throwArithmetic(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved) Allocator.Error!Step {
    return throwVm(H, a, frame, host, r, r.exceptions.arithmetic, "ArithmeticException", "/ by zero");
}

/// Whether `op` on `l` and `r` is the integer division by zero that
/// `applyBinop` refuses: `Byte`, `Short`, `Int` and `Long` operands in any
/// pairing, or two `UInt`s or two `ULong`s.
pub fn integralDivByZero(op: ir.BinOp, l: Value, r: Value) bool {
    if (op != .Div and op != .Mod) return false;
    const signed = struct {
        fn of(v: Value) ?i64 {
            return switch (v) {
                .Int => |x| x,
                .Long => |x| x,
                .Short => |x| x,
                .Byte => |x| x,
                else => null,
            };
        }
    }.of;
    if (signed(l) != null) {
        if (signed(r)) |d| return d == 0;
        return false;
    }
    return switch (l) {
        .UInt => r == .UInt and r.UInt == 0,
        .ULong => r == .ULong and r.ULong == 0,
        else => false,
    };
}

fn className(r: *const Resolved, c: ClassId) []const u8 {
    if (c.int() >= r.classes.len) return "?";
    return r.classes[c.int()].def.asPtrConst().fqn;
}

// ---------------------------------------------------------------------------
// Calls

pub fn execCallStatic(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "CallStatic");
    if (x.init != ir.NO_UNIT) {
        const st = host.resolvedState() orelse return noState(frame, "CallStatic");
        if (try ensureUnit(H, a, frame, host, r, st, x.init)) |e| return raiseStep(frame, e);
    }
    return runFunc(H, a, frame, host, r, x.func, runOf(frame, x.args, 0, x.n_args), null, x.dst);
}

/// Whether init unit `unit` has yet to finish, for a tier that cannot run
/// it in place.
pub fn unitPending(comptime H: type, host: *H, unit: u32) bool {
    const st = host.resolvedState() orelse return true;
    return !unitDone(st, unit);
}

/// Runs the init unit of the file whose facade declares `func`, as the JVM
/// initializes the class that declares `main` before running it.
pub fn ensureFacade(comptime H: type, a: Allocator, module: *const ir.Module, host: *H, func: FuncId) Allocator.Error!?EvalError {
    const r = module.resolved orelse return null;
    const unit = ir.resolved.facadeEntry(r, FuncId.from(ir.resolved.NONE), func);
    if (unit == ir.resolved.NONE) return null;
    const st = host.resolvedState() orelse return null;
    return ensureUnitIn(H, a, module, host, r, st, unit);
}

/// Runs the program's eager initializers, the `@EagerInitialization`
/// properties of every file in file order, as Kotlin/Native runs them when
/// the program starts. A unit already run (by an earlier start, or read
/// early by another eager initializer) is not run again. What one throws
/// fails the start, as an uncaught throwable before `main`.
pub fn runEagerUnits(comptime H: type, a: Allocator, module: *const ir.Module, host: *H) Allocator.Error!?EvalError {
    const r = module.resolved orelse return null;
    if (r.eager_units.len == 0) return null;
    const st = host.resolvedState() orelse return null;
    for (r.eager_units) |unit| {
        if (try ensureUnitIn(H, a, module, host, r, st, unit)) |e| return e;
    }
    return null;
}

/// Whether init unit `unit` has run to its end. A unit that finished stays
/// finished, so the flag is read without the state's lock; `ensureUnitIn`
/// publishes it with a release store.
fn unitDone(st: StateRef, unit: u32) bool {
    return @atomicLoad(ir.resolved.UnitState, &st.cell.data.unit_state[unit], .acquire) == .done;
}

pub fn execRCallVirtual(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "RCallVirtual");
    return dispatchRun(H, a, frame, host, r, x.slot, x.args, x.n_args, x.dst);
}

/// `iface` names the interface the call was written against; the slot alone
/// finds the implementation.
pub fn execCallInterface(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "CallInterface");
    return dispatchRun(H, a, frame, host, r, x.slot, x.args, x.n_args, x.dst);
}

/// Dispatches `slot` on the class of `args[0]`.
fn dispatchRun(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved, slot: MethodSlotId, args: Reg, n: u32, dst: Reg) Allocator.Error!Step {
    if (n == 0) return internal(a, frame, "virtual call of slot #{d} has no receiver", .{slot.int()});
    const recv = frame.read(args);
    if (recv == .Null) return throwNpe(H, a, frame, host, r, null);
    if (recv == .PropertyRef) if (r.host_class.callable_name) |name_slot| if (slot == name_slot) {
        try frame.write(dst, .{ .String = recv.PropertyRef.name.clone() });
        return .cont;
    };
    if (recv == .IrClosure) {
        if (host.resolvedClosure(&recv)) |body| switch (body.kind) {
            .property_ref => |p| if (try propertyMember(H, a, frame, host, r, &recv, body, p, slot, args, n, dst)) |step| return step,
            .function_ref => |target| if (r.host_class.callable_name) |name_slot| if (slot == name_slot) {
                const f = frame.module.funcById(target) orelse return internal(a, frame, "function reference: target #{d} is not in the module", .{target.int()});
                try frame.write(dst, .{ .String = try runtime.strInit(a, f.name) });
                return .cont;
            },
            .lambda => {},
        };
        if (try closureIdentity(H, a, frame, host, r, &recv, slot, args, n, dst)) |step| return step;
    }
    const cls_opt = valueClass(H, host, r, &recv);
    const target_opt = if (cls_opt) |c| ir.resolved.slotTarget(r, c, slot) else null;
    const target = target_opt orelse {
        // A host value (an iterator, an entry, a class value, ...) whose
        // class leaves the slot to the kind of value it is: the VM's
        // implementation of the slot's root.
        if ((recv != .Instance or cls_opt == null) and slot.int() < r.host_slot.len and r.host_slot[slot.int()] != .none) {
            return land(frame, try host.callNative(a, r.host_slot[slot.int()], runOf(frame, args, 0, n)), dst);
        }
        const cls = cls_opt orelse
            return internal(a, frame, "virtual call of slot #{d}: a {s} receiver has no class in the tables", .{ slot.int(), valueTag(&recv) });
        return internal(a, frame, "virtual call: class #{d} ({s}) has no implementation of slot #{d}", .{ cls.int(), className(r, cls), slot.int() });
    };
    return runFunc(H, a, frame, host, r, target, runOf(frame, args, 0, n), null, dst);
}

/// A closure answers `equals` and `hashCode` by what it is: a reference by
/// its target and its bound receiver, a lambda by identity; and `toString`
/// as kotlinc's does. Null for any other slot, or a closure the host does
/// not know.
fn closureIdentity(
    comptime H: type,
    a: Allocator,
    frame: *Frame,
    host: *H,
    r: *const Resolved,
    recv: *const Value,
    slot: MethodSlotId,
    args: Reg,
    n: u32,
    dst: Reg,
) Allocator.Error!?Step {
    const bx = host.resolvedClosure(recv) orelse return null;
    if (r.host_class.equals_slot) |es| if (slot == es and n == 2) {
        const other = frame.read(Reg.from(args.int() + 1));
        const eq = try closuresEqual(H, a, frame, host, r, recv, bx, &other);
        try frame.write(dst, .{ .Bool = eq });
        return .cont;
    };
    if (r.host_class.hash_code_slot) |hs| if (slot == hs and n == 1) {
        var h: i32 = switch (bx.kind) {
            .lambda => lambdaHash(bx),
            .function_ref => |t| @intCast(t.int() & 0x7fffffff),
            .property_ref => @intCast(bx.func.id.int() & 0x7fffffff),
        };
        if (bx.kind != .lambda) {
            const g = recv.IrClosure.borrow();
            defer g.deinit();
            for (g.get().captures) |*c| h = h *% 31 +% try hashOf(H, a, frame, host, r, c);
        }
        try frame.write(dst, .{ .Int = h });
        return .cont;
    };
    if (r.host_class.to_string_slot) |ts| if (slot == ts and n == 1) {
        const text = try closureText(a, frame.module, bx);
        try frame.write(dst, .{ .String = try runtime.strInitOwned(a, text) });
        return .cont;
    };
    return null;
}

/// A lambda is its own identity.
fn lambdaHash(bx: ClosureBody) i32 {
    return @truncate(@as(i64, @bitCast(bx.id)));
}

const no_reflection = " (Kotlin reflection is not available)";

/// What kotlinc's closure prints without kotlin-reflect: a reference names
/// its callable; a lambda is an instance of the hidden class the JVM makes
/// for its literal, named after the class or file facade declaring it, one
/// class per literal, with the instance's hash.
pub fn closureText(a: Allocator, m: *const ir.Module, bx: ClosureBody) Allocator.Error![]u8 {
    switch (bx.kind) {
        .function_ref => |t| {
            const f = m.funcById(t) orelse bx.module.funcById(t);
            const name = if (f) |ff| ff.name else "";
            if (std.mem.eql(u8, name, "<init>")) return a.dupe(u8, "constructor" ++ no_reflection);
            return std.fmt.allocPrint(a, "function {s}" ++ no_reflection, .{name});
        },
        .property_ref => |p| {
            const name = constString(bx.module, p.name) orelse constString(m, p.name) orelse "";
            return std.fmt.allocPrint(a, "property {s}" ++ no_reflection, .{name});
        },
        .lambda => {
            const owner = try lambdaOwner(a, bx.module, bx.func);
            return std.fmt.allocPrint(a, "{s}$$Lambda/0x{x:0>16}@{x}", .{ owner, bx.func.id.int(), @as(u32, @bitCast(lambdaHash(bx))) });
        },
    }
}

/// The JVM name of the class a lambda's literal is compiled into: its
/// nearest enclosing class, nested classes joined by `$`, or the facade of
/// its file (`app/main.kt` in package `p` is `p.MainKt`).
fn lambdaOwner(a: Allocator, m: *const ir.Module, f: *const ir.Func) Allocator.Error![]const u8 {
    const fqn = f.fqn;
    var cuts: std.ArrayList(usize) = .empty;
    defer cuts.deinit(a);
    for (fqn, 0..) |c, i| if (c == '.') try cuts.append(a, i);
    // The shortest prefix naming a class is the top-level class; each
    // longer one that still names a class is nested in it.
    var top: ?usize = null;
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(a);
    var last_class: usize = 0;
    for (cuts.items) |end| {
        if (!isClassFqn(m, fqn[0..end])) {
            if (top != null) break;
            continue;
        }
        if (top == null) {
            top = end;
        } else {
            try inner.append(a, '$');
            try inner.appendSlice(a, fqn[last_class + 1 .. end]);
        }
        last_class = end;
    }
    if (top) |t| return std.fmt.allocPrint(a, "{s}{s}", .{ fqn[0..t], inner.items });
    // A top-level declaration's package is what precedes it.
    var pkg: []const u8 = "";
    for (cuts.items) |end| {
        if (isFuncFqn(m, fqn[0..end])) {
            if (std.mem.findScalarLast(u8, fqn[0..end], '.')) |dot| pkg = fqn[0..dot];
            break;
        }
    }
    const path = ev_diag.funcFirstLoc(f).path;
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".kt")) base[0 .. base.len - 3] else base;
    var facade: std.ArrayList(u8) = .empty;
    defer facade.deinit(a);
    if (pkg.len != 0) {
        try facade.appendSlice(a, pkg);
        try facade.append(a, '.');
    }
    for (stem, 0..) |c, i| {
        const ok_char = std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
        try facade.append(a, if (!ok_char) '_' else if (i == 0) std.ascii.toUpper(c) else c);
    }
    try facade.appendSlice(a, "Kt");
    return a.dupe(u8, facade.items);
}

fn isClassFqn(m: *const ir.Module, fqn: []const u8) bool {
    for (m.classes.items) |*c| if (std.mem.eql(u8, c.fqn, fqn)) return true;
    return false;
}

fn isFuncFqn(m: *const ir.Module, fqn: []const u8) bool {
    for (m.funcs.items) |*f| if (std.mem.eql(u8, f.fqn, fqn)) return true;
    return false;
}

/// Whether two closures are one callable: the same closure, or references
/// to one target whose bound receivers are equal.
fn closuresEqual(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved, x: *const Value, bx: ir.resolved.ClosureBody, y: *const Value) Allocator.Error!bool {
    if (y.* != .IrClosure) return false;
    const by = host.resolvedClosure(y) orelse return false;
    if (bx.id == by.id) return true;
    const same_target = switch (bx.kind) {
        .lambda => false,
        // One target through one adapter: a reference adapted to another
        // function type is another callable.
        .function_ref => |t| by.kind == .function_ref and by.kind.function_ref == t and bx.func == by.func,
        .property_ref => by.kind == .property_ref and bx.func == by.func,
    };
    if (!same_target) return false;
    const gx = x.IrClosure.borrow();
    defer gx.deinit();
    const gy = y.IrClosure.borrow();
    defer gy.deinit();
    const cx = gx.get().captures;
    const cy = gy.get().captures;
    if (cx.len != cy.len) return false;
    for (cx, cy) |*u, *v| {
        if (!try valuesEqual(H, a, frame, host, r, u, v)) return false;
    }
    return true;
}

/// `u == v` for two captured values: both null, or `u.equals(v)` through
/// the class tables.
fn valuesEqual(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved, u: *const Value, v: *const Value) Allocator.Error!bool {
    if (u.* == .Null or v.* == .Null) return u.* == .Null and v.* == .Null;
    const res = try callMemberSlot(H, a, frame, host, r, u, r.host_class.equals_slot, &.{ u.*, v.* }) orelse
        return Value.structuralEq(u, v);
    return res == .Bool and res.Bool;
}

fn hashOf(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved, v: *const Value) Allocator.Error!i32 {
    if (v.* == .Null) return 0;
    const res = try callMemberSlot(H, a, frame, host, r, v, r.host_class.hash_code_slot, &.{v.*}) orelse return 0;
    return if (res == .Int) res.Int else 0;
}

/// Runs the implementation of `slot` for `recv`'s class over `args`, to
/// completion; null when the tables name none.
fn callMemberSlot(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved, recv: *const Value, slot: ?MethodSlotId, args: []const Value) Allocator.Error!?Value {
    const sl = slot orelse return null;
    const cls = valueClass(H, host, r, recv) orelse return null;
    const f = ir.resolved.slotTarget(r, cls, sl) orelse return null;
    const res = if (f.int() < r.func_native.len and r.func_native[f.int()] != .none)
        try host.callNative(a, r.func_native[f.int()], args)
    else
        try host.runResolved(a, frame.module, f, args);
    return switch (res) {
        .ok => |v| v,
        .err => null,
    };
}

/// A property reference answers `get`, `set` and `name` itself: the getter
/// and setter take the bound receiver, when there is one, before the
/// arguments. Null for any other slot, which dispatches on its class.
fn propertyMember(
    comptime H: type,
    a: Allocator,
    frame: *Frame,
    host: *H,
    r: *const Resolved,
    recv: *const Value,
    body: ClosureBody,
    p: ir.resolved.PropertyRef,
    slot: MethodSlotId,
    args: Reg,
    n: u32,
    dst: Reg,
) Allocator.Error!?Step {
    const h = &r.host_class;
    const arity = body.arity();
    if (h.callable_name) |name_slot| if (slot == name_slot) {
        const s = constString(frame.module, p.name) orelse return try internal(a, frame, "property reference: name constant #{d} is not a string", .{p.name.int()});
        try frame.write(dst, .{ .String = try runtime.strInit(a, s) });
        return .cont;
    };
    const is_get = arity < h.property_get.len and slot == h.property_get[arity];
    const is_set = arity < h.property_set.len and slot == h.property_set[arity];
    if (!is_get and !is_set) return null;
    const accessor: u32 = if (is_get) body.func.id.int() else p.setter;
    if (accessor == ir.NO_FUNC) return try internal(a, frame, "property reference: slot #{d} set on a read-only property", .{slot.int()});
    const bound = boundOf(recv, p.bound);
    const ar = try area(frame, if (bound) |*b| b[0..1] else &.{}, args, 1, n);
    return try runFunc(H, a, frame, host, r, accessorOf(frame.module, r, FuncId.from(accessor), ar.vals), ar.vals, ar.mark, dst);
}

/// The implementation of member accessor `accessor` for the receiver that
/// leads `params`: an interface's or an open class's property answers
/// through the receiver's class. The accessor itself for anything else.
fn accessorOf(m: *const ir.Module, r: *const Resolved, accessor: FuncId, params: []const Value) FuncId {
    if (params.len == 0) return accessor;
    const cls = ir.resolved.classOf(r, &params[0]) orelse return accessor;
    _ = m;
    return ir.resolved.slotTarget(r, cls, MethodSlotId.fromFunc(accessor)) orelse accessor;
}

/// The native the VM answers accessor `accessor` with on a host receiver
/// whose class has no implementation of it, or null.
fn hostAccessor(comptime H: type, host: *H, r: *const Resolved, accessor: FuncId, params: []const Value) ?NativeId {
    if (params.len == 0) return null;
    const recv = &params[0];
    if (recv.* == .Instance and valueClass(H, host, r, recv) != null) return null;
    if (accessor.int() >= r.host_slot.len) return null;
    const native = r.host_slot[accessor.int()];
    return if (native == .none) null else native;
}

/// A bound property reference's receiver, its capture 0; null otherwise.
fn boundOf(closure: *const Value, bound: bool) ?Value {
    if (!bound) return null;
    const g = closure.IrClosure.borrow();
    defer g.deinit();
    const caps = g.get().captures;
    if (caps.len == 0) return null;
    return caps[0];
}

fn constString(m: *const ir.Module, id: ir.ConstId) ?[]const u8 {
    if (id.int() >= m.consts.items.len) return null;
    return switch (m.consts.items[id.int()]) {
        .String => |s| s,
        else => null,
    };
}

pub fn execCallNative(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const run = runOf(frame, x.args, 0, x.n_args);
    if (comptime @hasDecl(H, "callNativeSite")) {
        if (!x.direct and run.len != 0 and run[0] == .Instance) return land(frame, try host.callNativeSite(a, x.native, run), x.dst);
    }
    return land(frame, try host.callNative(a, x.native, run), x.dst);
}

pub fn execRCallValue(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "RCallValue");
    const callee = frame.read(x.callee);
    switch (callee) {
        .IrClosure => |c| {
            const body = host.resolvedClosure(&callee) orelse
                return internal(a, frame, "RCallValue: closure #{d} was not made from sema's code", .{c.asPtrConst().id});
            if (x.n_args != body.arity())
                return internal(a, frame, "RCallValue: closure of #{d} ({s}) takes {d} arguments, called with {d}", .{ body.func.id.int(), body.func.fqn, body.arity(), x.n_args });
            switch (body.kind) {
                .property_ref => |p| {
                    const bound = boundOf(&callee, p.bound);
                    const ar = try area(frame, if (bound) |*b| b[0..1] else &.{}, x.args, 0, x.n_args);
                    const impl = accessorOf(frame.module, r, body.func.id, ar.vals);
                    // A host value's accessor the VM implements for that kind
                    // of value, as a virtual call through its slot reaches it.
                    if (impl == body.func.id) if (hostAccessor(H, host, r, body.func.id, ar.vals)) |native| {
                        const res = try host.callNative(a, native, ar.vals);
                        frame.tls.vstack.restore(ar.mark);
                        return land(frame, res, x.dst);
                    };
                    // An accessor bound to a native (`String::length`) runs
                    // it, as a direct call would.
                    return runFunc(H, a, frame, host, r, impl, ar.vals, ar.mark, x.dst);
                },
                else => {},
            }
            // The body reads a copy of the closure's captures, in an area of their own.
            const caps = blk: {
                const g = c.borrow();
                defer g.deinit();
                break :blk try ev_frame.ArgArea.push(frame.tls, &.{}, g.get().captures);
            };
            const params = runOf(frame, x.args, 0, x.n_args);
            if (ev_flow.flatEnabled()) {
                frame.tls.flat_call = .{
                    .func = body.func,
                    .run_module = body.module,
                    .owning = body.owning,
                    .params = params,
                    .captures = caps.vals,
                    .area = caps.mark,
                    .closure = c,
                    .dst = x.dst,
                };
                return .flat_call;
            }
            const res = try ev_enter.evalView(H, a, body.module, body.owning, body.func, params, caps.vals, caps.mark, c, host);
            return land(frame, res, x.dst);
        },
        .Instance => {
            const slots = r.host_class.invoke_slot;
            if (x.n_args >= slots.len)
                return internal(a, frame, "RCallValue: the tables have no invoke slot for arity {d}", .{x.n_args});
            const slot = slots[x.n_args];
            const cls = ir.resolved.classOf(r, &callee) orelse
                return internal(a, frame, "RCallValue: the callee's class is not in the tables", .{});
            // A class extending a suspend function type implements its
            // `SuspendFunctionN.invoke`.
            const suspend_slot: ?MethodSlotId = if (x.n_args < r.host_class.suspend_invoke_slot.len) r.host_class.suspend_invoke_slot[x.n_args] else null;
            const target = ir.resolved.slotTarget(r, cls, slot) orelse
                (if (suspend_slot) |ss| ir.resolved.slotTarget(r, cls, ss) else null) orelse
                return internal(a, frame, "RCallValue: class #{d} ({s}) has no implementation of invoke slot #{d}", .{ cls.int(), className(r, cls), slot.int() });
            const ar = try area(frame, &.{callee}, x.args, 0, x.n_args);
            return runFunc(H, a, frame, host, r, target, ar.vals, ar.mark, x.dst);
        },
        .Null => return throwNpe(H, a, frame, host, r, null),
        else => return internal(a, frame, "RCallValue: a {s} value is not a function", .{valueTag(&callee)}),
    }
}

pub fn execRNewInstance(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "RNewInstance");
    if (x.class.int() >= r.classes.len) return internal(a, frame, "RNewInstance: class #{d} is not in the tables", .{x.class.int()});
    // A host-backed class's constructor is a native that makes the host
    // value itself.
    if (x.ctor.int() < r.func_native.len and r.func_native[x.ctor.int()] != .none) {
        return land(frame, try host.callNative(a, r.func_native[x.ctor.int()], runOf(frame, x.args, 0, x.n_args)), x.dst);
    }
    var inst = try ir.resolved.instantiate(a, r, x.class);
    // A throwable's trace is where it is made, before its constructor runs.
    if (r.classes[x.class.int()].throwable) try ev_diag.attachStackTrace(a, &inst);
    // The register holds the instance while the constructor runs; the
    // constructor's result, `this`, then replaces it.
    try frame.write(x.dst, inst);
    const ar = try area(frame, &.{inst}, x.args, 0, x.n_args);
    return runFunc(H, a, frame, host, r, x.ctor, ar.vals, ar.mark, x.dst);
}

// ---------------------------------------------------------------------------
// Fields, statics, objects

pub fn execGetFieldSlot(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const obj = frame.read(x.obj);
    const inst = switch (obj) {
        .Instance => |i| i,
        .Null => {
            const r = frame.module.resolved orelse return noTables(frame, "GetFieldSlot");
            return throwNpe(H, a, frame, host, r, null);
        },
        // An unsigned value class is the host's unsigned value; its one
        // field, `data`, is the same bits read signed.
        .UByte, .UShort, .UInt, .ULong => if (x.slot == 0) {
            const v: Value = switch (obj) {
                .UByte => |u| .{ .Byte = @bitCast(u) },
                .UShort => |u| .{ .Short = @bitCast(u) },
                .UInt => |u| .{ .Int = @bitCast(u) },
                .ULong => |u| .{ .Long = @bitCast(u) },
                else => unreachable,
            };
            try frame.write(x.dst, v);
            return .cont;
        } else return internal(a, frame, "GetFieldSlot: slot {d} of a {s} value", .{ x.slot, valueTag(&obj) }),
        // An unsigned array is the host's array of that kind; its one
        // field, `storage`, is the signed array over the same buffer.
        .Array => |arr| {
            const signed: ?runtime.PrimitiveArrayKind = if (arr.primKind()) |k| switch (k) {
                .UByte => .Byte,
                .UShort => .Short,
                .UInt => .Int,
                .ULong => .Long,
                else => null,
            } else null;
            if (x.slot == 0) if (signed) |k| switch (arr.storage()) {
                .scalars => |pb| {
                    try frame.write(x.dst, .{ .Array = runtime.ArrayData.scalars(pb.clone(), k) });
                    return .cont;
                },
                .boxed => {},
            };
            return internal(a, frame, "GetFieldSlot: slot {d} of a {s} value", .{ x.slot, valueTag(&obj) });
        },
        else => return internal(a, frame, "GetFieldSlot: slot {d} of a {s} value", .{ x.slot, valueTag(&obj) }),
    };
    const v = runtime.InstanceData.slotGet(inst, x.slot) orelse
        return internal(a, frame, "GetFieldSlot: slot {d} is past the instance's fields", .{x.slot});
    v.retain();
    try frame.write(x.dst, v);
    return .cont;
}

pub fn execSetFieldSlot(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const obj = frame.read(x.obj);
    const inst = switch (obj) {
        .Instance => |i| i,
        .Null => {
            const r = frame.module.resolved orelse return noTables(frame, "SetFieldSlot");
            return throwNpe(H, a, frame, host, r, null);
        },
        else => return internal(a, frame, "SetFieldSlot: slot {d} of a {s} value", .{ x.slot, valueTag(&obj) }),
    };
    const v = frame.read(x.value);
    v.retain();
    const old = runtime.InstanceData.slotSet(inst, x.slot, v) orelse {
        v.release(a);
        return internal(a, frame, "SetFieldSlot: slot {d} is past the instance's fields", .{x.slot});
    };
    old.release(a);
    return .cont;
}

/// The calling thread, as an initializer's owner records it: never 0.
fn initThread() u64 {
    const raw: u64 = @intCast(std.Thread.getCurrentId());
    return if (raw == 0) 1 else raw;
}

/// One round of waiting for another thread's initializer, as a contended
/// monitor waits: spin, then yield, then sleep. A yield or a sleep is a
/// region the collector does not wait for: the initializer's thread may be
/// the one collecting, and a waiter yielding outside the bracket would hold
/// its rendezvous open.
fn initWait(rounds: *u32) void {
    rounds.* +|= 1;
    if (rounds.* <= 256) {
        std.atomic.spinLoopHint();
    } else if (rounds.* <= 2048) {
        runtime.gc.enterBlockingSafe();
        defer runtime.gc.exitBlockingSafe();
        std.Thread.yield() catch {};
    } else if (rounds.* <= 4096) {
        runtime.clockSleepMicros(100);
    } else {
        runtime.clockSleepMillis(1);
    }
}

/// A wait for an initializer given up at the run's end.
const init_abandoned: EvalError = .{ .Type = "daemon task abandoned at run boundary" };

/// Runs the init unit `unit` if nothing has touched it yet, as the JVM
/// initializes a class. The thread running it reads what it has written so
/// far, the seed for the rest; another thread waits for it to finish. A unit
/// whose initialization threw fails as the JVM's class initialization does
/// (`firstInitFailure`, then `laterInitFailure`).
fn ensureUnit(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved, st: StateRef, unit: u32) Allocator.Error!?EvalError {
    return ensureUnitIn(H, a, frame.module, host, r, st, unit);
}

fn ensureUnitIn(comptime H: type, a: Allocator, module: *const ir.Module, host: *H, r: *const Resolved, st: StateRef, unit: u32) Allocator.Error!?EvalError {
    if (unit == ir.resolved.NONE) return null;
    if (unit >= r.init_units.len) return .{ .Unsupported = "init unit is not in the tables" };
    if (unitDone(st, unit)) return null;
    const me = initThread();
    var rounds: u32 = 0;
    const was = while (true) {
        const claim: ?ir.resolved.UnitState = blk: {
            const g = st.borrowMut();
            defer g.deinit();
            const s = g.get();
            const w = s.unit_state[unit];
            if (w == .idle) {
                s.unit_state[unit] = .running;
                s.unit_owner[unit] = me;
            }
            if (w == .running and s.unit_owner[unit] != me) break :blk null;
            break :blk w;
        };
        if (claim) |w| break w;
        if (runtime.shouldAbandon()) return init_abandoned;
        initWait(&rounds);
    };
    switch (was) {
        .idle => {},
        .failed => {
            const first = blk: {
                const g = st.borrow();
                defer g.deinit();
                break :blk g.get().unit_failure[unit];
            };
            return try laterInitFailure(H, a, module, host, r, first, r.init_units[unit].name);
        },
        .running, .done => return null,
    }
    const res = try host.runResolved(a, module, r.init_units[unit].func, &.{});
    {
        const g = st.borrowMut();
        defer g.deinit();
        const end: ir.resolved.UnitState = if (res == .err and res.err == .Throw) .failed else .done;
        if (end == .failed) {
            res.err.Throw.retain();
            g.get().unit_failure[unit] = res.err.Throw;
        }
        g.get().unit_owner[unit] = 0;
        @atomicStore(ir.resolved.UnitState, &g.get().unit_state[unit], end, .release);
    }
    switch (res) {
        .ok => |v| v.release(a),
        .err => |e| return if (e == .Throw) try firstInitFailure(H, a, module, host, r, e.Throw) else e,
    }
    return null;
}

/// The first use of a failed initializer, as the JVM reports it (JVMS
/// 5.5): an `Error` the initializer threw is rethrown itself, anything else
/// is wrapped in an `ExceptionInInitializerError` with no message.
fn firstInitFailure(comptime H: type, a: Allocator, module: *const ir.Module, host: *H, r: *const Resolved, thrown: Value) Allocator.Error!EvalError {
    if (isErrorValue(module, r, &thrown)) return .{ .Throw = thrown };
    const cc = r.base.init_failed orelse return .{ .Throw = thrown };
    return switch (try buildThrowable(H, a, module, host, r, cc, null, thrown)) {
        .ok => |exc| .{ .Throw = exc },
        .err => |e| e,
    };
}

/// Every later use of a failed initializer: `NoClassDefFoundError("Could
/// not initialize class <name>")`, caused by an `ExceptionInInitializerError`
/// naming the first failure and its thread, as JDK 21 reports it.
fn laterInitFailure(comptime H: type, a: Allocator, module: *const ir.Module, host: *H, r: *const Resolved, first: ?Value, name: []const u8) Allocator.Error!EvalError {
    const nc = r.base.no_class_def orelse return if (first) |f| .{ .Throw = f } else .{ .Unsupported = "an initializer failed" };
    var cause: Value = .Null;
    if (first) |f| if (r.base.init_failed) |cc| {
        const text = try throwableText(H, a, module, host, r, f);
        const thread = runtime.threadName(a, std.Thread.getCurrentId()) orelse "main";
        const msg = try std.fmt.allocPrint(a, "Exception {s} [in thread \"{s}\"]", .{ text, thread });
        switch (try buildThrowable(H, a, module, host, r, cc, msg, .Null)) {
            .ok => |exc| cause = exc,
            .err => |e| return e,
        }
    };
    const msg = try std.fmt.allocPrint(a, "Could not initialize {s}", .{name});
    return switch (try buildThrowable(H, a, module, host, r, nc, msg, cause)) {
        .ok => |exc| .{ .Throw = exc },
        .err => |e| e,
    };
}

/// An instance of throwable class `cc` built by its `(message, cause)`
/// constructor.
fn buildThrowable(comptime H: type, a: Allocator, module: *const ir.Module, host: *H, r: *const Resolved, cc: ir.resolved.ClassCtor, message: ?[]const u8, cause: Value) Allocator.Error!union(enum) { ok: Value, err: EvalError } {
    const exc = try ir.resolved.instantiate(a, r, cc.class);
    const msg: Value = if (message) |m| .{ .String = try runtime.strInit(a, m) } else .Null;
    defer msg.release(a);
    const res = try host.runResolved(a, module, cc.ctor, &.{ exc, msg, cause });
    switch (res) {
        .ok => |v| v.release(a),
        .err => |e| {
            exc.release(a);
            return .{ .err = e };
        },
    }
    return .{ .ok = exc };
}

/// Whether `v` is an instance of `kotlin.Error`.
fn isErrorValue(module: *const ir.Module, r: *const Resolved, v: *const Value) bool {
    const err_cls = (r.exceptions.by_fqn.get("kotlin.Error") orelse return false).class;
    const cls = ir.resolved.classOf(r, v) orelse return false;
    return ir.resolved.isA(module, cls, err_cls);
}

/// What `toString` answers for throwable `v`, through the base's
/// `Any.toString` slot; its class name when that fails.
fn throwableText(comptime H: type, a: Allocator, module: *const ir.Module, host: *H, r: *const Resolved, v: Value) Allocator.Error![]const u8 {
    const cls = ir.resolved.classOf(r, &v) orelse return "kotlin.Throwable";
    if (r.well_known.get(.to_string)) |slot| if (ir.resolved.slotTarget(r, cls, slot)) |target| {
        switch (try host.runResolved(a, module, target, &.{v})) {
            .ok => |t| if (t == .String) return try a.dupe(u8, t.String.asPtrConst().bytes),
            .err => {},
        }
    };
    return className(r, cls);
}

pub fn execLoadStatic(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "LoadStatic");
    const st = host.resolvedState() orelse return noState(frame, "LoadStatic");
    const i = x.static.int();
    if (i >= r.statics.len) return internal(a, frame, "LoadStatic: static #{d} is not in the tables", .{i});
    if (try ensureUnit(H, a, frame, host, r, st, r.statics[i].unit)) |e| return raiseStep(frame, e);
    const v = st.cell.data.loadStatic(i);
    v.retain();
    try frame.write(x.dst, v);
    return .cont;
}

/// Static `static`, borrowed, once the unit that writes it has run; null when its arm must run
/// the unit first or report.
pub inline fn readyStatic(comptime H: type, frame: *const Frame, host: *H, static: u32) ?Value {
    const r = frame.module.resolved orelse return null;
    if (static >= r.statics.len) return null;
    const st = host.resolvedState() orelse return null;
    const unit = r.statics[static].unit;
    if (unit != ir.resolved.NONE and !unitDone(st, unit)) return null;
    return st.cell.data.loadStatic(static);
}

/// Store `v` in static `static` once the unit that writes it has run, taking one reference and
/// releasing the value it replaced; false, storing nothing, when its arm must run the unit first
/// or report.
pub inline fn storeReadyStatic(comptime H: type, a: Allocator, frame: *const Frame, host: *H, static: u32, v: Value) bool {
    const r = frame.module.resolved orelse return false;
    if (static >= r.statics.len) return false;
    const st = host.resolvedState() orelse return false;
    const unit = r.statics[static].unit;
    if (unit != ir.resolved.NONE and !unitDone(st, unit)) return false;
    v.retain();
    st.cell.data.storeStatic(static, v).release(a);
    return true;
}

/// Whether init unit `unit` has run, so a call it guards goes ahead; `NONE` guards nothing.
pub inline fn unitReady(comptime H: type, host: *H, unit: u32) bool {
    if (unit == ir.resolved.NONE) return true;
    const st = host.resolvedState() orelse return false;
    if (unit >= st.cell.data.unit_state.len) return false;
    return unitDone(st, unit);
}

/// A class test's answer for a value the tables classify by themselves, which a stream op
/// settles in place; null for a function value, whose class the host knows, and for a value
/// with no class in the tables, which its arm reports.
pub inline fn quickIsA(frame: *const Frame, v: *const Value, class: u32, nullable: bool) ?bool {
    switch (v.*) {
        .Null => return nullable,
        .Instance => |inst| {
            const id = inst.asPtrConst().class_id;
            if (id == std.math.maxInt(u32)) return null;
            return ir.resolved.isA(frame.module, ClassId.from(id), ClassId.from(class));
        },
        .IrClosure => return null,
        else => {
            const r = frame.module.resolved orelse return null;
            const c = ir.resolved.classOf(r, v) orelse return null;
            return ir.resolved.isA(frame.module, c, ClassId.from(class));
        },
    }
}

/// Static `id`'s value, its init unit run first, for the host outside a
/// frame.
pub fn staticValue(comptime H: type, a: Allocator, module: *const ir.Module, host: *H, id: ir.StaticId) Allocator.Error!EvalResult {
    const r = module.resolved orelse return .{ .err = .{ .Unsupported = "LoadStatic: the module has no resolved tables" } };
    const st = host.resolvedState() orelse return .{ .err = .{ .Unsupported = "LoadStatic: no run state" } };
    const i = id.int();
    if (i >= r.statics.len) return .{ .err = .{ .Unsupported = "LoadStatic: the static is not in the tables" } };
    if (try ensureUnitIn(H, a, module, host, r, st, r.statics[i].unit)) |e| return .{ .err = e };
    const v = st.cell.data.loadStatic(i);
    v.retain();
    return .{ .ok = v };
}

pub fn execStoreStatic(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "StoreStatic");
    const st = host.resolvedState() orelse return noState(frame, "StoreStatic");
    const i = x.static.int();
    if (i >= r.statics.len) return internal(a, frame, "StoreStatic: static #{d} is not in the tables", .{i});
    if (try ensureUnit(H, a, frame, host, r, st, r.statics[i].unit)) |e| return raiseStep(frame, e);
    const v = frame.read(x.value);
    v.retain();
    st.cell.data.storeStatic(i, v).release(a);
    return .cont;
}

/// The singleton of an object or companion. Once it is built, one atomic
/// load finds it; the first use builds it (`objectInstance`).
pub fn execLoadObject(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "LoadObject");
    // `Unit` is the host's Unit value, the one every Unit function returns.
    if (r.host_class.unit) |u| if (u == x.class) {
        try frame.write(x.dst, .Unit);
        return .cont;
    };
    const st = host.resolvedState() orelse return noState(frame, "LoadObject");
    const c = x.class.int();
    if (c >= r.classes.len) return internal(a, frame, "LoadObject: class #{d} is not in the tables", .{c});
    if (objectDone(st, c)) {
        const v = st.cell.data.singletons[c].?;
        v.retain();
        try frame.write(x.dst, v);
        return .cont;
    }
    if (r.classes[c].object_ctor == ir.NO_FUNC) return internal(a, frame, "LoadObject: class #{d} ({s}) is not an object", .{ c, className(r, x.class) });
    return land(frame, try objectInstance(H, a, frame.module, host, r, st, x.class), x.dst);
}

/// The singleton of object `class` when it is built (the host's Unit for
/// Unit), borrowed; null when the object's arm must build it or report.
pub inline fn builtObject(comptime H: type, frame: *const Frame, host: *H, class: u32) ?Value {
    const r = frame.module.resolved orelse return null;
    if (r.host_class.unit) |u| if (u.int() == class) return .Unit;
    if (class >= r.classes.len) return null;
    const st = host.resolvedState() orelse return null;
    if (!objectDone(st, class)) return null;
    return st.cell.data.singletons[class];
}

/// Whether object `c` is built. `done` is stored after its singleton, so
/// the singleton is read without the state's lock.
fn objectDone(st: StateRef, c: u32) bool {
    return @atomicLoad(ir.resolved.UnitState, &st.cell.data.object_state[c], .acquire) == .done;
}

/// The singleton of object `class`, built on first use as the JVM
/// initializes a class. The first use allocates it, publishes it to its own
/// thread, then runs its constructor, so the constructor and anything it
/// calls read the instance being built. Another thread waits until the
/// constructor finishes. An object whose constructor threw throws on every
/// later use (`firstInitFailure`, then `laterInitFailure`).
pub fn objectInstance(comptime H: type, a: Allocator, module: *const ir.Module, host: *H, r: *const Resolved, st: StateRef, class: ClassId) Allocator.Error!EvalResult {
    const c = class.int();
    if (objectDone(st, c)) {
        const v = st.cell.data.singletons[c].?;
        v.retain();
        return .{ .ok = v };
    }
    const ctor = r.classes[c].object_ctor;
    if (ctor == ir.NO_FUNC) return .{ .err = .{ .Unsupported = "an object without a constructor" } };
    const me = initThread();
    const Claim = union(enum) { build, have: Value, failed: ?Value, wait };
    var rounds: u32 = 0;
    while (true) {
        const claim: Claim = blk: {
            const g = st.borrowMut();
            defer g.deinit();
            const s = g.get();
            switch (s.object_state[c]) {
                .idle => {
                    s.object_state[c] = .running;
                    s.object_owner[c] = me;
                    break :blk .build;
                },
                .done => break :blk .{ .have = s.singletons[c].? },
                .failed => break :blk .{ .failed = s.failed_objects.get(c) },
                .running => {
                    if (s.object_owner[c] != me) break :blk .wait;
                    // The constructor's own thread reads the instance it is building.
                    break :blk if (s.singletons[c]) |v| .{ .have = v } else .wait;
                },
            }
        };
        switch (claim) {
            .build => break,
            .have => |v| {
                v.retain();
                return .{ .ok = v };
            },
            .failed => |first| return .{ .err = try laterInitFailure(H, a, module, host, r, first, r.classes[c].init_name) },
            .wait => {
                if (runtime.shouldAbandon()) return .{ .err = init_abandoned };
                initWait(&rounds);
            },
        }
    }
    const inst = try ir.resolved.instantiate(a, r, class);
    {
        const g = st.borrowMut();
        defer g.deinit();
        inst.retain();
        g.get().singletons[c] = inst;
    }
    const res = try host.runResolved(a, module, FuncId.from(ctor), &.{inst});
    switch (res) {
        .ok => |v| {
            v.release(a);
            const g = st.borrowMut();
            defer g.deinit();
            g.get().object_owner[c] = 0;
            @atomicStore(ir.resolved.UnitState, &g.get().object_state[c], .done, .release);
        },
        .err => |e| {
            // A constructor that threw leaves no singleton, and the object is
            // never initialized again. An internal error leaves it to a later
            // use to try again.
            {
                const g = st.borrowMut();
                defer g.deinit();
                g.get().singletons[c] = null;
                if (e == .Throw) {
                    e.Throw.retain();
                    try g.get().failed_objects.put(a, c, e.Throw);
                }
                g.get().object_owner[c] = 0;
                @atomicStore(ir.resolved.UnitState, &g.get().object_state[c], if (e == .Throw) .failed else .idle, .release);
            }
            // The table's reference, then this arm's.
            inst.release(a);
            inst.release(a);
            return .{ .err = if (e == .Throw) try firstInitFailure(H, a, module, host, r, e.Throw) else e };
        },
    }
    return .{ .ok = inst };
}

// ---------------------------------------------------------------------------
// Function values

pub fn execMakeClosure(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    // A literal that captures nothing is one instance for every evaluation.
    if (x.captures.len == 0) if (host.resolvedState()) |st| {
        const key = x.func.int();
        const existing = blk: {
            const g = st.borrow();
            defer g.deinit();
            break :blk g.get().lambdas.get(key);
        };
        if (existing) |v| {
            v.retain();
            try frame.write(x.dst, v);
            return .cont;
        }
        switch (try host.makeResolvedClosure(a, frame.module, x.func, &.{}, .lambda)) {
            .ok => |v| {
                {
                    const g = st.borrowMut();
                    defer g.deinit();
                    v.retain();
                    try g.get().lambdas.put(a, key, v);
                }
                try frame.write(x.dst, v);
                return .cont;
            },
            .err => |e| return raiseStep(frame, e),
        }
    };
    // A literal's few captures are gathered on the stack; the closure copies them.
    var buf: [8]Value = undefined;
    const caps = if (x.captures.len <= buf.len) buf[0..x.captures.len] else try a.alloc(Value, x.captures.len);
    defer if (x.captures.len > buf.len) a.free(caps);
    for (x.captures, caps) |reg, *c| c.* = frame.read(reg);
    return land(frame, try host.makeResolvedClosure(a, frame.module, x.func, caps, .lambda), x.dst);
}

pub fn execFunctionRef(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    var caps: [1]Value = undefined;
    const n: usize = if (x.bound) |b| blk: {
        caps[0] = frame.read(b);
        break :blk 1;
    } else 0;
    return land(frame, try host.makeResolvedClosure(a, frame.module, x.adapter, caps[0..n], .{ .function_ref = x.target }), x.dst);
}

/// A property reference over its accessors, or with no getter (a local
/// delegated property's `KProperty`, handed to its delegate) one that has
/// only its name.
pub fn execRPropertyRef(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    if (x.getter.int() == ir.NO_FUNC) {
        const s = constString(frame.module, x.name) orelse return internal(a, frame, "RPropertyRef: name constant #{d} is not a string", .{x.name.int()});
        try frame.write(x.dst, .{ .PropertyRef = .{ .name = try runtime.strInit(a, s) } });
        return .cont;
    }
    var caps: [1]Value = undefined;
    const n: usize = if (x.bound) |b| blk: {
        caps[0] = frame.read(b);
        break :blk 1;
    } else 0;
    const kind: ir.resolved.Callable = .{ .property_ref = .{ .setter = x.setter, .name = x.name, .bound = n != 0 } };
    return land(frame, try host.makeResolvedClosure(a, frame.module, x.getter, caps[0..n], kind), x.dst);
}

// ---------------------------------------------------------------------------
// Classes and type tests

fn kclass(a: Allocator, frame: *Frame, r: *const Resolved, c: ClassId, dst: Reg) Allocator.Error!Step {
    if (c.int() >= r.classes.len) return internal(a, frame, "class #{d} is not in the tables", .{c.int()});
    try frame.write(dst, .{ .Class = r.classes[c.int()].def.clone() });
    return .cont;
}

pub fn execClassLiteral(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    _ = host;
    const r = frame.module.resolved orelse return noTables(frame, "ClassLiteral");
    return kclass(a, frame, r, x.class, x.dst);
}

pub fn execClassOf(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "ClassOf");
    const v = frame.read(x.src);
    if (v == .Null) return throwNpe(H, a, frame, host, r, null);
    const c = valueClass(H, host, r, &v) orelse return internal(a, frame, "ClassOf: a {s} value has no class in the tables", .{valueTag(&v)});
    return kclass(a, frame, r, c, x.dst);
}

/// Whether `v` is a `class`: null passes when `nullable`. Null when `v`'s
/// class is not in the tables, after the internal error is raised.
fn testClass(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved, v: *const Value, class: ClassId, nullable: bool) Allocator.Error!?bool {
    if (v.* == .Null) return nullable;
    const c = valueClass(H, host, r, v) orelse {
        _ = try internal(a, frame, "type test against class #{d}: a {s} value has no class in the tables", .{ class.int(), valueTag(v) });
        return null;
    };
    if (ir.resolved.isA(frame.module, c, class)) return true;
    // A suspend function value takes its continuation as one more
    // argument: it is the `FunctionN` of its arity plus one too.
    return v.* == .IrClosure and ir.resolved.isContinuationForm(r, c, class);
}

pub fn execRInstanceOf(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "RInstanceOf");
    const v = frame.read(x.src);
    const is = (try testClass(H, a, frame, host, r, &v, x.class, x.nullable)) orelse return .raised;
    try frame.write(x.dst, .{ .Bool = is });
    return .cont;
}

/// `BoxValue`: an instance of the scalar value class over the number, which
/// runs no init block; an instance or a null is itself.
pub fn execBoxValue(a: Allocator, frame: *Frame, x: anytype) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "BoxValue");
    const v = frame.read(x.src);
    if (v == .Instance or v == .Null) {
        v.retain();
        try frame.write(x.dst, v);
        return .cont;
    }
    const boxed = try boxValue(a, r, x.class, x.slot, v);
    try frame.write(x.dst, boxed);
    return .cont;
}

/// The instance of scalar value class `class` holding `v` in field `slot`.
pub fn boxValue(a: Allocator, r: *const Resolved, class: ClassId, slot: u32, v: Value) Allocator.Error!Value {
    const boxed = try ir.resolved.instantiate(a, r, class);
    v.retain();
    if (runtime.InstanceData.slotSet(boxed.Instance, slot, v)) |old| {
        if (runtime.reclaimEnabled()) old.release(a);
    }
    return boxed;
}

/// `UnboxValue`: the number an instance of the scalar value class holds;
/// anything else is itself.
pub fn execUnboxValue(comptime H: type, a: Allocator, frame: *Frame, x: anytype) Allocator.Error!Step {
    _ = H;
    _ = a;
    const v = frame.read(x.src);
    const out = unboxValue(v, x.class.int(), x.slot);
    out.retain();
    try frame.write(x.dst, out);
    return .cont;
}

/// The number `v` holds when it is an instance of `class`, else `v`.
pub inline fn unboxValue(v: Value, class: u32, slot: u32) Value {
    if (v != .Instance) return v;
    if (v.Instance.asPtrConst().class_id != class) return v;
    return runtime.InstanceData.slotGet(v.Instance, slot) orelse v;
}

/// `as` and `as?`: the value itself when it is a `class` (null when
/// `nullable`), else null for `as?`, else `NullPointerException` for a null
/// and `ClassCastException` for anything else.
fn castTo(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved, v: Value, class: ClassId, nullable: bool, safe: bool, dst: Reg) Allocator.Error!Step {
    const is = (try testClass(H, a, frame, host, r, &v, class, nullable)) orelse return .raised;
    if (is) {
        v.retain();
        try frame.write(dst, v);
        return .cont;
    }
    if (safe) {
        try frame.write(dst, .Null);
        return .cont;
    }
    if (v == .Null) {
        const msg = try std.fmt.allocPrint(a, "null cannot be cast to non-null type {s}", .{className(r, class)});
        return throwNpe(H, a, frame, host, r, msg);
    }
    const from = valueClass(H, host, r, &v).?;
    const msg = try std.fmt.allocPrint(a, "class {s} cannot be cast to class {s}", .{ className(r, from), className(r, class) });
    return throwVm(H, a, frame, host, r, r.exceptions.class_cast, "ClassCastException", msg);
}

pub fn execRCast(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "RCast");
    return castTo(H, a, frame, host, r, frame.read(x.src), x.class, x.nullable, x.safe, x.dst);
}

/// The class a reified type value names.
const TypeTarget = struct { class: ClassId, nullable: bool };

/// The class a run-time type value names, and whether the type admits
/// null: a `KClass`, or the base's `KlioType` over one.
fn typeValueClass(a: Allocator, frame: *Frame, r: *const Resolved, ty: Reg) Allocator.Error!?TypeTarget {
    const tv = frame.read(ty);
    if (ir.resolved.classOfKClass(&tv)) |c| return .{ .class = c, .nullable = false };
    if (r.base.ktype) |kt| if (tv == .Instance and ir.resolved.classOf(r, &tv) == kt.class) {
        const classifier = runtime.InstanceData.slotGet(tv.Instance, kt.classifier);
        const nullable = runtime.InstanceData.slotGet(tv.Instance, kt.nullable);
        if (classifier != null and nullable != null) {
            if (ir.resolved.classOfKClass(&classifier.?)) |c| {
                return .{ .class = c, .nullable = nullable.? == .Bool and nullable.?.Bool };
            }
        }
    };
    _ = try internal(a, frame, "dynamic type test: a {s} value is not a type value", .{valueTag(&tv)});
    return null;
}

pub fn execInstanceOfDyn(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "InstanceOfDyn");
    const t = (try typeValueClass(a, frame, r, x.ty)) orelse return .raised;
    const v = frame.read(x.src);
    const is = (try testClass(H, a, frame, host, r, &v, t.class, x.nullable or t.nullable)) orelse return .raised;
    try frame.write(x.dst, .{ .Bool = is });
    return .cont;
}

pub fn execCastDyn(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "CastDyn");
    const t = (try typeValueClass(a, frame, r, x.ty)) orelse return .raised;
    return castTo(H, a, frame, host, r, frame.read(x.src), t.class, x.nullable or t.nullable, x.safe, x.dst);
}

// ---------------------------------------------------------------------------
// Arrays

fn indexOf(a: Allocator, frame: *Frame, reg: Reg) Allocator.Error!?i32 {
    const v = frame.read(reg);
    if (v == .Int) return v.Int;
    _ = try internal(a, frame, "array index is a {s}, not an Int", .{valueTag(&v)});
    return null;
}

fn lengthOf(v: *const Value) usize {
    return switch (v.*) {
        .Array => |arr| arr.len(),
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk g.get().u16_len;
        },
        else => 0,
    };
}

fn throwIndex(comptime H: type, a: Allocator, frame: *Frame, host: *H, r: *const Resolved, v: *const Value, index: i32) Allocator.Error!Step {
    const msg = try std.fmt.allocPrint(a, "Index {d} out of bounds for length {d}", .{ index, lengthOf(v) });
    const e = &r.exceptions;
    const which = if (v.* == .String) e.string_index_out_of_bounds orelse e.index_out_of_bounds else e.array_index_out_of_bounds orelse e.index_out_of_bounds;
    return throwVm(H, a, frame, host, r, which, "IndexOutOfBoundsException", msg);
}

pub fn execArrayGet(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "ArrayGet");
    const arr = frame.read(x.array);
    switch (arr) {
        .Array, .String => {},
        .Null => return throwNpe(H, a, frame, host, r, null),
        else => return internal(a, frame, "ArrayGet on a {s} value", .{valueTag(&arr)}),
    }
    const index = (try indexOf(a, frame, x.index)) orelse return .raised;
    const idx_v: Value = .{ .Int = index };
    const v = ev_values.fastIndexGet(&arr, &idx_v) orelse return throwIndex(H, a, frame, host, r, &arr, index);
    try frame.write(x.dst, v);
    return .cont;
}

pub fn execArraySet(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "ArraySet");
    const arr = frame.read(x.array);
    switch (arr) {
        .Array => {},
        .Null => return throwNpe(H, a, frame, host, r, null),
        else => return internal(a, frame, "ArraySet on a {s} value", .{valueTag(&arr)}),
    }
    const index = (try indexOf(a, frame, x.index)) orelse return .raised;
    const idx_v: Value = .{ .Int = index };
    _ = ev_values.fastIndexSet(a, &arr, &idx_v, frame.read(x.value)) orelse return throwIndex(H, a, frame, host, r, &arr, index);
    return .cont;
}

/// `IterOpen`: the stamp of a loop the host can run by position, else null.
pub fn execIterOpen(frame: *Frame, x: anytype) Allocator.Error!Step {
    const src = frame.read(x.src);
    try frame.write(x.dst, if (runtime.forloop.open(&src)) |at| .{ .Long = at } else .Null);
    return .cont;
}

/// `IterHas`: whether the loop has an element at its position.
pub fn execIterHas(a: Allocator, frame: *Frame, x: anytype) Allocator.Error!Step {
    const src = frame.read(x.src);
    const idx = frame.read(x.idx);
    const at = frame.read(x.stamp);
    if (idx != .Int or at != .Long) return internal(a, frame, "IterHas at a {s} over a {s} stamp", .{ valueTag(&idx), valueTag(&at) });
    try frame.write(x.dst, .{ .Bool = runtime.forloop.has(&src, idx.Int, at.Long) });
    return .cont;
}

/// `IterGet`: the loop's element at its position, or ConcurrentModificationException after a
/// structural change.
pub fn execIterGet(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    const r = frame.module.resolved orelse return noTables(frame, "IterGet");
    const src = frame.read(x.src);
    const idx = frame.read(x.idx);
    const at = frame.read(x.stamp);
    if (idx != .Int or at != .Long) return internal(a, frame, "IterGet at a {s} over a {s} stamp", .{ valueTag(&idx), valueTag(&at) });
    switch (runtime.forloop.get(&src, idx.Int, at.Long)) {
        .elem => |v| try frame.write(x.dst, v),
        .changed => return throwVm(H, a, frame, host, r, r.exceptions.by_fqn.get("kotlin.ConcurrentModificationException"), "ConcurrentModificationException", null),
    }
    return .cont;
}

pub fn execNewArray(comptime H: type, a: Allocator, frame: *Frame, x: anytype, host: *H) Allocator.Error!Step {
    _ = host;
    const r = frame.module.resolved orelse return noTables(frame, "NewArray");
    const h = &r.host_class;
    const run = runOf(frame, x.args, 0, x.n_args);
    if (h.array != null and h.array.? == x.class) {
        var list: std.ArrayList(Value) = .empty;
        try list.appendSlice(a, run);
        for (run) |v| v.retain();
        try frame.write(x.dst, runtime.ArrayData.fromBoxedList(try runtime.ValueList.init(a, list)));
        return .cont;
    }
    for (h.prim_array, 0..) |c, k| {
        if (c == null or c.? != x.class) continue;
        try frame.write(x.dst, try runtime.ArrayData.initPacked(a, @enumFromInt(k), run));
        return .cont;
    }
    return internal(a, frame, "NewArray: class #{d} ({s}) is not an array class in the tables", .{ x.class.int(), className(r, x.class) });
}

// ---------------------------------------------------------------------------
// Tests: the hand-built programs of `hand.zig` on the null host, which runs
// everything but natives and closures. `lower_driver`'s VM tests run them
// through the VM with the rest.

const testing = std.testing;
const hand = @import("hand.zig");
const NullHost = @import("host.zig").NullHost;

fn runOnNullHost(a: Allocator, build: *const fn (*hand.Hand) Allocator.Error!FuncId) !EvalResult {
    var h = try hand.Hand.init(a);
    const main = try build(&h);
    var host: NullHost = .{ .resolved_state = try ir.resolved.stateNew(a, h.r) };
    return ev_enter.evalWith(NullHost, a, h.m, h.funcPtr(main), .empty, &host);
}

fn expectInt(want: i32, res: EvalResult) !void {
    if (res == .err) std.debug.print("error: {any}\n", .{res.err});
    try testing.expect(res == .ok);
    try testing.expectEqual(want, res.ok.Int);
}

fn expectTrue(res: EvalResult) !void {
    if (res == .err) std.debug.print("error: {any}\n", .{res.err});
    try testing.expect(res == .ok);
    try testing.expect(res.ok == .Bool and res.ok.Bool);
}

test "a static call chain lands each result in its call's register" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectInt(42, try runOnNullHost(mem.allocator(), hand.staticChain));
}

test "virtual and interface calls find each class's implementation by slot" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectInt(790123, try runOnNullHost(mem.allocator(), hand.dispatch));
}

test "a constructor reads its slots' seeds before it writes them" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectTrue(try runOnNullHost(mem.allocator(), hand.seeds));
}

test "an init unit runs once, on first touch, and reads its own statics' seeds" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectInt(1471, try runOnNullHost(mem.allocator(), hand.statics));
}

test "an object's constructor sees the singleton it is building" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectTrue(try runOnNullHost(mem.allocator(), hand.singleton));
}

test "type tests and casts answer by class, null by nullable" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectTrue(try runOnNullHost(mem.allocator(), hand.typeTests));
}

test "a scalar value class boxes a number once, and unboxes an instance of it to the number" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectInt(14, try runOnNullHost(mem.allocator(), hand.boxing));
}

test "a catch handler takes a throw by its class" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectInt(2, try runOnNullHost(mem.allocator(), hand.catchByClass));
}

test "arrays and strings are indexed with bounds checks" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectInt(129, try runOnNullHost(mem.allocator(), hand.arrays));
}

test "the VM's own exceptions are instances of the tables' classes" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectInt(7, try runOnNullHost(mem.allocator(), hand.vmThrows));
}

test "!!, integer division by zero and lateinit throw the tables' classes" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    try expectTrue(try runOnNullHost(mem.allocator(), hand.reusedThrows));
}

test "a property reference with no getter answers its name and is a KProperty0" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try hand.Hand.init(a);
    const name_get = try h.func("KCallable.<get-name>", 1);
    const kprop0 = try h.class("KProperty0", .{});
    h.r.host_class.callable_name = MethodSlotId.fromFunc(name_get);
    h.r.host_class.property = try a.dupe(ClassId, &.{kprop0});
    const x = try h.constant(.{ .String = "x" });
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{
        .{ .RPropertyRef = .{ .dst = hand.reg(0), .getter = FuncId.from(ir.NO_FUNC), .bound = null, .name = x } },
        hand.callVirtual(1, name_get, 0, 1),
        hand.konst(2, x),
        hand.bin(3, .Eq, 1, 2),
        hand.instanceOf(4, 0, kprop0, false),
        hand.bin(5, .And, 3, 4),
    }, .term = hand.ret(5) }});
    try h.finish();
    var host: NullHost = .{ .resolved_state = try ir.resolved.stateNew(a, h.r) };
    try expectTrue(try ev_enter.evalWith(NullHost, a, h.m, h.funcPtr(main), .empty, &host));
}

test "only integer division by zero is refused" {
    try testing.expect(integralDivByZero(.Div, .{ .Int = 1 }, .{ .Int = 0 }));
    try testing.expect(integralDivByZero(.Mod, .{ .Long = 1 }, .{ .Short = 0 }));
    try testing.expect(integralDivByZero(.Div, .{ .ULong = 1 }, .{ .ULong = 0 }));
    try testing.expect(!integralDivByZero(.Div, .{ .Double = 1 }, .{ .Int = 0 }));
    try testing.expect(!integralDivByZero(.Div, .{ .Int = 1 }, .{ .Int = 2 }));
    try testing.expect(!integralDivByZero(.Mul, .{ .Int = 1 }, .{ .Int = 0 }));
}

test "a slot a class does not implement is an internal error, not a lookup" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try hand.Hand.init(a);
    const ctor = try hand.ctorReturningThis(&h);
    const c = try h.class("C", .{});
    const root = try h.func("I.m", 1);
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{ hand.newInstance(0, c, ctor, 0, 0), hand.callVirtual(1, root, 0, 1) }, .term = hand.ret(1) }});
    try h.finish();
    var host: NullHost = .{ .resolved_state = try ir.resolved.stateNew(a, h.r) };
    const res = try ev_enter.evalWith(NullHost, a, h.m, h.funcPtr(main), .empty, &host);
    try testing.expect(res == .err);
    try testing.expect(std.mem.find(u8, res.err.CalleeFailed, "has no implementation of slot") != null);
}

test "the null host declines natives, closures and state it was not given" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try hand.Hand.init(a);
    const lam = try h.func("lambda", 0);
    const main = try h.func("main", 0);
    try h.body(main, &.{.{ .insts = &.{.{ .MakeClosure = .{ .dst = hand.reg(0), .func = lam, .captures = &.{} } }}, .term = hand.ret(0) }});
    const obj_main = try h.func("objMain", 0);
    const o = try h.class("O", .{});
    try h.body(obj_main, &.{.{ .insts = &.{hand.loadObject(0, o)}, .term = hand.ret(0) }});
    try h.finish();
    var host: NullHost = .{};
    const closure = try ev_enter.evalWith(NullHost, a, h.m, h.funcPtr(main), .empty, &host);
    try testing.expect(closure == .err);
    const object = try ev_enter.evalWith(NullHost, a, h.m, h.funcPtr(obj_main), .empty, &host);
    try testing.expect(object == .err);
    try testing.expect(std.mem.find(u8, object.err.CalleeFailed, "no resolved state") != null);
}
