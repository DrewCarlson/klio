//! Evaluator entry points: argument coercion, the `eval*` family, and the
//! frame boundary that converts a non-local return into a value.

const std = @import("std");
const runtime = @import("runtime");
const span = @import("span");
const ir = @import("../ir.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BinOp = ir.BinOp;
const Func = ir.Func;
const Module = ir.Module;
const TypeRef = ir.TypeRef;



const ev_activation = @import("activation.zig");
const ev_diag = @import("diag.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_host = @import("host.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");

const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const Frame = ev_frame.Frame;
const ArgArea = ev_frame.ArgArea;
const VsMark = ev_state.VsMark;
const NullHost = ev_host.NullHost;
const TryFrame = ev_snapshot.TryFrame;
const callStatsBumpId = ev_diag.callStatsBumpId;
const currentFrameFunc = ev_state.currentFrameFunc;
const dumpFrameChainForDiagAlways = ev_diag.dumpFrameChainForDiagAlways;
const errResult = ev_flow.errResult;
const gcPopFrame = ev_state.gcPopFrame;
const gcPushFrame = ev_state.gcPushFrame;
const lrTraceOn = ev_flow.lrTraceOn;
const nullHost = ev_host.nullHost;
const ok = ev_flow.ok;
const runFrame = ev_activation.runFrame;

/// Normalize an `Int` occupying a non-nullable `Long` slot. Kotlin types an integer literal by
/// its expected type; only `Int` values are touched, so an `Int` in an `Int` slot is untouched.
fn coerceIntToLongTy(ty: TypeRef, v: *Value) void {
    if (v.* == .Int and !ty.nullable and std.mem.eql(u8, ty.name, "Long")) {
        const n = v.Int;
        v.* = .{ .Long = @as(i64, n) };
    }
}

/// Run a function body positionally, returning the terminating `Return`'s value or `Unit` on a
/// fall-off, against `nullHost`. `args` ownership transfers in as the frame's params backing.
pub fn eval(allocator: Allocator, module: *const Module, func: *const Func, args: std.ArrayList(Value)) Allocator.Error!EvalResult {
    var host = nullHost();
    return evalWith(NullHost, allocator, module, func, args, &host);
}

/// Whether `module` is the one `func`'s body indexes against: its ids must name this very `Func`.
pub fn funcOwnedBy(module: *const Module, func: *const Func) bool {
    return module.funcById(func.id) == func;
}

/// Like `eval`, but routes non-trivial dispatch through `H`, a comptime-duck-typed concrete host.

pub fn evalWith(comptime H: type, allocator: Allocator, module: *const Module, func: *const Func, args: std.ArrayList(Value), host: *H) Allocator.Error!EvalResult {
    dumpFnIfRequested(func);
    boolThisTrap(func, args.items);
    return evalWithCaptures(H, allocator, module, func, args, .empty, host);
}

/// `KLIO_THIS_TRAP=1`: print every frame entry binding a Bool into a `this` param, the ext-receiver misbind signature.
var bool_this_trap_state: u8 = 0;

pub inline fn boolThisTrap(func: *const Func, args: []const Value) void {
    if (bool_this_trap_state == 1) return;
    boolThisTrapSlow(func, args);
}

fn boolThisTrapSlow(func: *const Func, args: []const Value) void {
    if (bool_this_trap_state == 0)
        bool_this_trap_state = if (runtime.envOnce("KLIO_THIS_TRAP") != null) 2 else 1;
    if (bool_this_trap_state != 2) return;
    if (func.params.len == 0 or args.len == 0) return;
    if (!std.mem.eql(u8, func.params[0].name, "this")) return;
    if (args[0] != .Bool and args[0] != .Int) return;
    const cf = currentFrameFunc();
    std.debug.print("[this-trap] fn={s}#{d} nargs={d} caller={s}#{d} vals:", .{
        func.fqn,
        func.id.int(),
        args.len,
        if (cf) |c| c.fqn else "<none>",
        if (cf) |c| c.id.int() else 0,
    });
    for (args) |a| std.debug.print(" {s}", .{@tagName(std.meta.activeTag(a))});
    std.debug.print("\n", .{});
}

/// `KLIO_DUMP_FN=<name>`: print the named function's lowered instruction stream the first time
/// it runs, the only view of what an emit path produced for a body inside a baked pack.
var dump_fn_done: bool = false;

/// Cached `KLIO_DUMP_FN` value; an empty slice means unset.
var dump_fn_want: ?[]const u8 = null;

pub inline fn dumpFnIfRequested(func: *const Func) void {
    if (dump_fn_done) return;
    dumpFnSlow(func);
}

fn dumpFnSlow(func: *const Func) void {
    const want = dump_fn_want orelse blk: {
        const w = runtime.envOnce("KLIO_DUMP_FN") orelse "";
        dump_fn_want = w;
        break :blk w;
    };
    // Unset: stop asking.
    if (want.len == 0) {
        dump_fn_done = true;
        return;
    }
    // `#<id>` selects by FuncId, the only handle for the synthetic names (`<lambda>`) many functions share.
    if (want.len > 1 and want[0] == '#') {
        const id = std.fmt.parseInt(u32, want[1..], 10) catch return;
        if (func.id.int() != id) return;
    } else if (std.mem.findScalar(u8, want, '.') != null) {
        if (!std.mem.eql(u8, func.fqn, want)) return;
    } else if (!std.mem.eql(u8, func.name, want)) return;
    // A deferred body has no blocks yet; wait for the post-materialize call.
    if (func.blocks.len == 0) return;
    dump_fn_done = true;
    std.debug.print("[dump-fn] {s}#{d} params={d} blocks={d} recv_ty={?s} caps=", .{ func.fqn, func.id.int(), func.params.len, func.blocks.len, func.x().lambda_receiver_ty });
    for (func.x().capture_order) |cn| std.debug.print("{s},", .{cn});
    std.debug.print("\n", .{});
    for (func.blocks, 0..) |*blk, bi| {
        std.debug.print("  block {d}:", .{bi});
        const h = blk.h();
        for (h.catches) |c| std.debug.print(" catch(class={d} -> b{d} into r{d})", .{ c.class.int(), c.handler.int(), c.exception_reg.int() });
        if (h.finally) |f| std.debug.print(" finally=b{d}", .{f.int()});
        if (h.finally_done) |f| std.debug.print(" finally_done=b{d}", .{f.int()});
        std.debug.print("\n", .{});
        for (blk.insts, 0..) |*inst, ii| {
            std.debug.print("    {d}: {s}", .{ ii, @tagName(std.meta.activeTag(inst.*)) });
            switch (inst.*) {
                .Trace => |t| {
                    if (span.active_map) |m| {
                        if (m.getChecked(t.span.file)) |sf| {
                            const lc = sf.lineCol(t.span.start);
                            std.debug.print(" {s}:{d}", .{ sf.path, lc.line });
                        }
                    }
                },
                inline else => |payload| dumpFields(payload),
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("    term: {s}", .{@tagName(std.meta.activeTag(blk.terminator))});
        switch (blk.terminator) {
            inline else => |payload| dumpFields(payload),
        }
        std.debug.print("\n", .{});
    }
}

/// Each field of an instruction's or terminator's payload, as `name=value`: registers as `rN`,
/// blocks as `bN`, other ids as their number.
fn dumpFields(payload: anytype) void {
    const P = @TypeOf(payload);
    switch (@typeInfo(P)) {
        .@"struct" => |st| inline for (st.fields) |f| {
            std.debug.print(" {s}=", .{f.name});
            dumpValue(@field(payload, f.name));
        },
        .void => {},
        else => {
            std.debug.print(" ", .{});
            dumpValue(payload);
        },
    }
}

fn dumpValue(v: anytype) void {
    const T = @TypeOf(v);
    if (T == ir.Reg) return std.debug.print("r{d}", .{v.int()});
    if (T == ir.BlockId) return std.debug.print("b{d}", .{v.int()});
    switch (@typeInfo(T)) {
        .optional => if (v) |x| dumpValue(x) else std.debug.print("null", .{}),
        .@"enum" => |e| if (e.is_exhaustive) std.debug.print("{s}", .{@tagName(v)}) else std.debug.print("{d}", .{@intFromEnum(v)}),
        .int, .comptime_int => std.debug.print("{d}", .{v}),
        .bool => std.debug.print("{}", .{v}),
        .pointer => |p| if (p.size == .slice) {
            std.debug.print("[", .{});
            for (v, 0..) |x, i| {
                if (i != 0) std.debug.print(",", .{});
                dumpValue(x);
            }
            std.debug.print("]", .{});
        } else dumpFields(v.*),
        else => std.debug.print("?", .{}),
    }
}

/// Like `evalWith` but seeds the frame with a captured-values vector, which `Inst.LoadCapture` reads.
pub fn evalWithCaptures(comptime H: type, allocator: Allocator, module: *const Module, func: *const Func, args: std.ArrayList(Value), captures: std.ArrayList(Value), host: *H) Allocator.Error!EvalResult {
    return evalWithCapturesIn(H, allocator, module, null, func, args, captures, host);
}

/// Run a method or closure lowered into a per-method sub-module; the frame records `owning` so a
/// suspension resolves its `FuncId` against it. `module` must be `owning` when `owning` is non-null.
pub fn evalWithCapturesIn(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    owning: ?*const Module,
    func: *const Func,
    args: std.ArrayList(Value),
    captures: std.ArrayList(Value),
    host: *H,
) Allocator.Error!EvalResult {
    return evalClosure(H, allocator, module, owning, func, args, captures, null, host);
}

/// Where a non-local return goes once this frame's finallys have run: a labeled return to the
/// frame carrying its label, an untargeted one to the nearest non-lambda non-inline frame.
pub fn unwindTerminal(frame: *Frame, e: EvalError) EvalResult {
    switch (e) {
        .NonLocalReturn => |v| {
            if (frame.func.is_lambda or frame.func.is_inline) {
                return errResult(.{ .NonLocalReturn = v });
            }
            return ok(v);
        },
        .LabeledReturn => |lr| {
            if (frameMatchesLabel(frame.func, lr.label)) {
                return ok(lr.value);
            }
            return errResult(e);
        },
        else => return errResult(e),
    }
}

/// A lambda's body func is named synthetically, so an explicit or implicit label matches only
/// through `implicit_label`.
fn frameMatchesLabel(func: *const Func, label: []const u8) bool {
    if (std.mem.eql(u8, func.name, label)) return true;
    // A collision-mangled declaration (`makePending$f172`) still answers its source-name label.
    if (func.name.len > label.len and func.name[label.len] == '$' and
        std.mem.startsWith(u8, func.name, label))
    {
        return true;
    }
    if (func.x().implicit_label) |il| return std.mem.eql(u8, il, label);
    return false;
}

/// Runs `func` over `args` and `captures` as the body of `closure` (null for a
/// plain call), reading its ids against `module`; `owning` is the sub-module
/// a suspension resumes in. The lists' values are borrowed: they move into an
/// argument area and the lists are freed.
pub fn evalClosure(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    owning: ?*const Module,
    func: *const Func,
    args: std.ArrayList(Value),
    captures: std.ArrayList(Value),
    closure: ?runtime.IrClosureRef,
    host: *H,
) Allocator.Error!EvalResult {
    var a = args;
    var c = captures;
    defer a.deinit(allocator);
    defer c.deinit(allocator);
    return evalSlices(H, allocator, module, owning, func, a.items, c.items, closure, host);
}

/// `evalClosure` over parameter and capture slices, which the argument area copies before the
/// body runs: a host's call into Kotlin needs no list of its own.
pub fn evalSlices(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    owning: ?*const Module,
    func: *const Func,
    args: []const Value,
    captures: []const Value,
    closure: ?runtime.IrClosureRef,
    host: *H,
) Allocator.Error!EvalResult {
    const ar = try ArgArea.push(ev_state.evtlsPtr(), args, captures);
    const np = args.len;
    return evalView(H, allocator, module, owning, func, ar.vals[0..np], ar.vals[np..], ar.mark, closure, host);
}

/// `evalClosure` over parameter and capture views: a run of the caller's
/// registers, or the argument area pushed at `at`, which the frame takes over.
pub fn evalView(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    owning: ?*const Module,
    func: *const Func,
    params: []const Value,
    captures: []const Value,
    at: ?VsMark,
    closure: ?runtime.IrClosureRef,
    host: *H,
) Allocator.Error!EvalResult {
    const ev: *EvalTls = ev_state.evtlsPtr();
    dumpFnIfRequested(func);
    boolThisTrap(func, params);
    callStatsBumpId(func.fqn, func.id.int(), module);
    var try_stack: std.ArrayList(TryFrame) = .empty;
    defer try_stack.deinit(ev_snapshot.try_alloc);
    var frame: Frame = undefined;
    frame.enter(ev, allocator, module, func, params, captures, at) catch |e| {
        if (at) |m| ev.vstack.restore(m);
        return e;
    };
    frame.closure = closure;
    defer frame.deinitIn(ev);
    gcPushFrame(&frame);
    defer gcPopFrame(&frame);
    frame.module_arc = owning;
    const cur = func.entry;
    const result = try runFrame(H, allocator, module, &frame, &try_stack, cur, 0, host);
    return frameBoundary(func, result);
}

/// The transforms every frame's result crosses at its callee boundary: absorb a labeled return
/// this function owns, normalize an `Int` in a `Long` return slot, and re-tag a ran body's
/// resolution-class escape as `CalleeFailed` so no candidate walk re-executes its side effects.
pub fn frameBoundary(func: *const Func, result_in: EvalResult) EvalResult {
    var result = result_in;
    // A labeled return targeting this function exits it normally; other labels propagate outward.
    if (result == .err and result.err == .LabeledReturn) {
        if (lrTraceOn()) {
            std.debug.print("[lr-exit] label={s} func={s} match={}\n", .{ result.err.LabeledReturn.label, func.name, frameMatchesLabel(func, result.err.LabeledReturn.label) });
        }
    }
    if (result == .err and result.err == .LabeledReturn and
        frameMatchesLabel(func, result.err.LabeledReturn.label))
    {
        result = ok(result.err.LabeledReturn.value);
    }
    if (result == .err and result.err == .LabeledReturn) {
        if (lrTraceOn()) {
            std.debug.print("[lr] label={s} passed_frame={s} implicit={s}\n", .{ result.err.LabeledReturn.label, func.name, func.x().implicit_label orelse "-" });
        }
    }
    // A bare integer literal returned into a declared `Long` carries an `Int` tag out of the body.
    if (result == .ok) {
        coerceIntToLongTy(func.return_ty, &result.ok);
    }
    if (result == .err) {
        switch (result.err) {
            .Unimplemented, .Unbound, .Type, .Unsupported, .Arity => |m| {
                // `KLIO_AMP_TRACE=<substr>`: the frames are gone by the time the error surfaces, so this names the run body.
                if (runtime.envOnce("KLIO_AMP_TRACE")) |w| {
                    if (std.mem.find(u8, m, w) != null) {
                        std.debug.print("[amp] body={s} fqn={s} err={s} msg={s}\n", .{ func.name, func.fqn, @tagName(std.meta.activeTag(result.err)), m });
                        dumpFrameChainForDiagAlways();
                    }
                }
                result = errResult(.{ .CalleeFailed = m });
            },
            else => {},
        }
    }
    return result;
}
