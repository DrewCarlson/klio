//! `VmHost` top-level / named-function dispatch: resolving and invoking
//! a `FuncId` (with named args, type args, and overload selection) plus
//! the `call_named_overload` probe the IR evaluator uses for bare-name
//! calls.
//!
//! Free functions over `*VmHost`, wired into the `ir.eval.Host` vtable
//! by `vmhost.zig`.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const trace = @import("trace.zig");
const host_call_member = @import("host_call_member.zig");
const host_globals = @import("host_globals.zig");

const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const RuntimeError = runtime.RuntimeError;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;

const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const EvalError = ir.eval.EvalError;
const EvalResult = ir.eval.EvalResult;
const MaybeValueResult = ir.eval.MaybeValueResult;
const SuspendState = ir.eval.SuspendState;

// -------------------------------------------------------------------------
// Small data-error / args helpers.
// -------------------------------------------------------------------------

fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) EvalError {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "IR type error";
    return .{ .Type = msg };
}

/// Move a slice of `Value`s into a freshly allocated `std.ArrayList`
/// the IR evaluator can take ownership of. The `Value`s themselves are
/// shallow-copied (their `ObjRef` handles stay shared), matching the Vm's
/// `Vec<Value>` hand-off discipline.
fn argsFromSlice(allocator: Allocator, items: []const Value) Allocator.Error!std.ArrayList(Value) {
    var out: std.ArrayList(Value) = .empty;
    try out.appendSlice(allocator, items);
    return out;
}

/// Look up a `Func` by id, returning a borrowed pointer into the module's
/// `funcs` (the module outlives the call). `null` when out of range.
fn funcAt(module: *const Module, id: FuncId) ?*const Func {
    const idx = id.int();
    if (idx >= module.funcs.items.len) return null;
    return &module.funcs.items[idx];
}

fn paramIsThis(params: []const ir.Param) bool {
    return params.len > 0 and std.mem.eql(u8, params[0].name, "this");
}

fn lastIsVararg(params: []const ir.Param) bool {
    return params.len > 0 and params[params.len - 1].is_vararg;
}

/// `func.params.last()` default thunk lookup for `func`.
fn funcDefaults(self: *VmHost, func: FuncId) ?[]?FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().func_defaults.get(func.int());
}

// -------------------------------------------------------------------------
// Vararg packing (mirrors `pack_vararg_args` in lib.rs).
// -------------------------------------------------------------------------

/// Collapse the trailing positional args of a vararg call into a single
/// `Array` slot. Consumes `args` (an owned `ArrayList`), returning the
/// packed list. A `f(*arr)` spread (a lone `Array` already in the slot)
/// passes through untouched.
fn packVarargArgs(allocator: Allocator, func: *const Func, args: *std.ArrayList(Value)) Allocator.Error!std.ArrayList(Value) {
    if (!lastIsVararg(func.params)) return args.*;
    const n_params = func.params.len;
    const fixed = if (n_params == 0) 0 else n_params - 1;
    if (args.items.len == n_params and args.items[args.items.len - 1] == .Array) {
        return args.*;
    }
    var out: std.ArrayList(Value) = .empty;
    try out.ensureTotalCapacity(allocator, n_params);
    var i: usize = 0;
    while (i < fixed and i < args.items.len) : (i += 1) {
        out.appendAssumeCapacity(args.items[i]);
    }
    var rest: std.ArrayList(Value) = .empty;
    var j: usize = fixed;
    while (j < args.items.len) : (j += 1) {
        try rest.append(allocator, args.items[j]);
    }
    try out.append(allocator, .{ .Array = .{ .items = try ValueList.init(allocator, rest), .prim = null } });
    args.deinit(allocator);
    return out;
}

// -------------------------------------------------------------------------
// Intrinsic resolution + dispatch (mirror `lookup_intrinsic` /
// `dispatch_intrinsic` in vmhost.rs).
// -------------------------------------------------------------------------

/// Look up an intrinsic by FQN. Probes the pack-supplied
/// `installed_bindings` overlay first so a loaded pack's binding shadows
/// the stdlib's default implementation.
fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
    {
        const g = self.prog.borrow();
        defer g.deinit();
        const bg = g.get().installed_bindings.borrow();
        defer bg.deinit();
        if (bg.get().resolve(fqn)) |f| return f;
    }
    return stdlib.implementation(fqn);
}

/// Build a `VmIntrinsicHost` mirroring `dispatch_intrinsic`'s, drive the
/// intrinsic through a `CallCtx`, and convert any `RuntimeError` back into
/// the IR evaluator's `EvalError` data path.
fn dispatchIntrinsic(self: *VmHost, allocator: Allocator, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
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
        .err => |e| .{ .err = runtimeErrorToEval(allocator, e) },
    };
}

/// Map a `runtime.RuntimeError` raised by an intrinsic into the IR
/// evaluator's `EvalError`, preserving thrown values and control flow.
fn runtimeErrorToEval(allocator: Allocator, e: RuntimeError) EvalError {
    return switch (e) {
        // Preserve the thrown Value so the IR evaluator's try/catch can
        // match the handler against the exception class.
        .Thrown => |v| .{ .Throw = v },
        .Return => |v| .{ .NonLocalReturn = v },
        // A suspending primitive (`delay` / `yield`) asked to park. Seed a
        // fresh SuspendState; each enclosing `eval` frame snapshots itself
        // as it unwinds, and the coroutine driver parks the result.
        .Suspend => |wake| blk: {
            const st = allocator.create(SuspendState) catch break :blk EvalError{ .Type = "out of memory seeding suspend" };
            st.* = .{ .token = 0, .frames = .empty, .wake_in_millis = wake, .pending_resume_reg = null };
            break :blk EvalError{ .Suspended = st };
        },
        .Unbound => |s| .{ .Unbound = s },
        .Type => |s| .{ .Type = s },
        .Arity => |s| .{ .Arity = s },
        .Unimplemented => |s| .{ .Unimplemented = s },
        else => typeErr(allocator, "{s}", .{@tagName(e)}),
    };
}

// -------------------------------------------------------------------------
// Overload scoring + selection (mirror `overload_score_arg`,
// `overload_score`, `pick_overload` in vmhost.rs).
// -------------------------------------------------------------------------

fn simpleName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

fn allAsciiUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// Score an arg/param compatibility for overload resolution. Higher is
/// better; `null` disqualifies the candidate.
fn overloadScoreArg(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) ?i32 {
    const nm = param_ty.name;
    // Runtime type-simple-name of the argument.
    var inst_name_buf: ?[]const u8 = null;
    const v_ty: []const u8 = switch (arg.*) {
        .Instance => |i| blk: {
            const g = i.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            inst_name_buf = cg.get().name;
            break :blk cg.get().name;
        },
        else => blk: {
            const fqn = arg.typeFqn();
            break :blk simpleName(fqn);
        },
    };

    if (std.mem.eql(u8, nm, v_ty)) return 100;
    if (std.mem.eql(u8, nm, "Any") or std.mem.eql(u8, nm, "Any?")) return 10;
    if (arg.* == .Null and param_ty.nullable) return 50;

    // Numeric widening: Int → Long, Int → Double, Long → Double.
    if (std.mem.eql(u8, nm, "Long") and std.mem.eql(u8, v_ty, "Int")) return 40;
    if ((std.mem.eql(u8, nm, "Double") or std.mem.eql(u8, nm, "Float")) and std.mem.eql(u8, v_ty, "Int")) return 30;
    if (std.mem.eql(u8, nm, "Double") and std.mem.eql(u8, v_ty, "Long")) return 30;

    // A callable argument against a function-typed parameter.
    const arg_arity: ?usize = switch (arg.*) {
        .Lambda => |l| blk: {
            const pg = l.params.borrow();
            defer pg.deinit();
            break :blk pg.get().*.len;
        },
        .IrClosure => |c| if (self.closures.get(c.id)) |info| info.n_params else null,
        else => null,
    };
    const is_callable = arg_arity != null or std.mem.startsWith(u8, arg.typeFqn(), "kotlin.Function");
    if (is_callable) {
        // `FunctionN` carries the expected lambda arity.
        if (std.mem.startsWith(u8, nm, "Function")) {
            const expected = nm["Function".len..];
            if (std.fmt.parseInt(usize, expected, 10)) |want| {
                if (arg_arity) |got| {
                    return if (got == want or got == want + 1) @as(i32, 90) else 20;
                }
                return 20;
            } else |_| {}
        }
        // SAM conversion / receiver-style function types: low, but scored.
        return 8;
    }

    // Subtype: an instance argument whose class transitively extends /
    // implements the parameter's nominal type matches (distance-weighted).
    if (arg.* == .Instance) {
        var queue: std.ArrayList(QItem) = .empty;
        defer queue.deinit(self.allocator);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(self.allocator);
        queue.append(self.allocator, .{ .name = v_ty, .depth = 0 }) catch return null;
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const cur = queue.items[head];
            var already = false;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, cur.name)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            seen.append(self.allocator, cur.name) catch return null;
            if (std.mem.eql(u8, cur.name, nm)) {
                const d: i32 = if (cur.depth > 50) 50 else cur.depth;
                return 60 - d;
            }
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(cur.name)) |def_ref| {
                const dg = def_ref.borrow();
                defer dg.deinit();
                for (dg.get().supertype_names) |sup| {
                    queue.append(self.allocator, .{ .name = sup, .depth = cur.depth + 1 }) catch return null;
                }
            }
        }
    }

    // Builtin runtime types satisfy their nominal supertypes.
    const builtin_supers: []const []const u8 = builtinSupersFor(v_ty);
    const nm_simple = simpleName(nm);
    for (builtin_supers, 0..) |s, pos| {
        if (std.mem.eql(u8, s, nm) or std.mem.eql(u8, s, nm_simple)) {
            const dist: i32 = if (pos > 20) 20 else @intCast(pos);
            return 75 - dist;
        }
    }

    // Generic single-letter type-parameter — accept any.
    if (nm.len <= 2 and allAsciiUpper(nm)) return 5;
    // Unit param type (no info preserved at lower time) — accept anything
    // but rank lowest.
    if (std.mem.eql(u8, nm, "Unit")) return 1;
    return null;
}

const QItem = struct { name: []const u8, depth: i32 };

fn builtinSupersFor(v_ty: []const u8) []const []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, v_ty, "List")) return &.{ "Collection", "Iterable", "MutableList", "MutableCollection", "MutableIterable" };
    if (eq(u8, v_ty, "MutableList")) return &.{ "List", "Collection", "Iterable", "MutableCollection", "MutableIterable" };
    if (eq(u8, v_ty, "Set")) return &.{ "Collection", "Iterable", "MutableSet", "MutableCollection", "MutableIterable" };
    if (eq(u8, v_ty, "MutableSet")) return &.{ "Set", "Collection", "Iterable", "MutableCollection", "MutableIterable" };
    if (eq(u8, v_ty, "Map")) return &.{"MutableMap"};
    if (eq(u8, v_ty, "MutableMap")) return &.{"Map"};
    if (eq(u8, v_ty, "IntRange")) return &.{ "IntProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    if (eq(u8, v_ty, "LongRange")) return &.{ "LongProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    if (eq(u8, v_ty, "CharRange")) return &.{ "CharProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    if (eq(u8, v_ty, "IntProgression") or eq(u8, v_ty, "LongProgression") or eq(u8, v_ty, "CharProgression")) return &.{"Iterable"};
    if (eq(u8, v_ty, "String")) return &.{ "CharSequence", "Comparable" };
    return &.{};
}

/// Score a single candidate's applicability for `args`. `null` means
/// inapplicable; a higher score means a better match.
fn overloadScore(self: *VmHost, module: *const Module, cand: FuncId, args: []const Value) ?i32 {
    const f = funcAt(module, cand) orelse return null;
    // A bodyless `expect` declaration must never be selected over a
    // body-carrying sibling or the host intrinsic backing the name.
    if (f.blocks.len == 0) return null;
    const last_vararg = lastIsVararg(f.params);
    if (f.params.len < args.len and !last_vararg) return null;

    // Trailing-lambda rule (mirrors `call_func`).
    if (f.params.len > args.len and args.len > 0 and
        isFunctionType(&f.params[f.params.len - 1].ty) and
        valueIsCallable(&args[args.len - 1]))
    {
        const lead = args.len - 1;
        const last_param = f.params.len - 1;
        if (lead <= last_param) {
            const defaults = funcDefaults(self, cand);
            var gap_defaulted = true;
            var i = lead;
            while (i < last_param) : (i += 1) {
                const has = defaults != null and i < defaults.?.len and defaults.?[i] != null;
                if (!has) {
                    gap_defaulted = false;
                    break;
                }
            }
            if (!gap_defaulted) return null;
            var total: i32 = -1;
            var k: usize = 0;
            while (k < lead) : (k += 1) {
                const s = overloadScoreArg(self, &f.params[k].ty, &args[k]) orelse return null;
                total += s;
            }
            const ls = overloadScoreArg(self, &f.params[last_param].ty, &args[lead]) orelse return null;
            total += ls;
            return total;
        }
    }

    if (f.params.len > args.len) {
        const defaults = funcDefaults(self, cand);
        var all_defaulted = true;
        var i = args.len;
        while (i < f.params.len) : (i += 1) {
            const has = defaults != null and i < defaults.?.len and defaults.?[i] != null;
            if (!has) {
                all_defaulted = false;
                break;
            }
        }
        if (!all_defaulted) return null;
    }

    var total: i32 = if (f.params.len == args.len) 0 else -1;
    var idx: usize = 0;
    while (idx < f.params.len and idx < args.len) : (idx += 1) {
        const s = overloadScoreArg(self, &f.params[idx].ty, &args[idx]) orelse return null;
        total += s;
    }
    return total;
}

/// When the target function shares its name with siblings, pick the best
/// match for the runtime arg types. `null` when there is nothing better.
fn pickOverload(self: *VmHost, module: *const Module, func: FuncId, args: []const Value) ?FuncId {
    const f = funcAt(module, func) orelse return null;
    const name = f.name;
    const candidates = module.funcsBySimpleName(name);
    if (candidates.len < 2) return null;

    var best_func: ?FuncId = null;
    var best_score: i32 = 0;
    if (overloadScore(self, module, func, args)) |s| {
        best_func = func;
        best_score = s;
    }
    for (candidates) |cand| {
        if (cand.int() == func.int()) continue;
        if (overloadScore(self, module, cand, args)) |total| {
            if (best_func == null or total > best_score) {
                best_func = cand;
                best_score = total;
            }
        }
    }
    return best_func;
}

// Function-type / callability helpers shared with the root module.
const isFunctionType = root.isFunctionType;
const valueIsCallable = root.valueIsCallable;
const primitiveParamAccepts = root.primitiveParamAccepts;
const extDeclRecvIsUserClass = root.extDeclRecvIsUserClass;
const valueIsBuiltin = root.valueIsBuiltin;

// -------------------------------------------------------------------------
// Public dispatch entry points.
// -------------------------------------------------------------------------

/// Single function-call dispatch flow.
pub fn callFunc(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args_in: []const Value) Allocator.Error!EvalResult {
    const f = funcAt(module, func) orelse
        return .{ .err = typeErr(allocator, "unknown FuncId {d}", .{func.int()}) };

    if (trace.enabled(f.name)) {
        trace.emit("call_func {s} fid={d} fqn={s} argc={d}", .{ f.name, func.int(), f.fqn, args_in.len });
    }

    // Pack-installed binding fast path: a top-level function whose
    // package-qualified FQN matches a registered binding shadows the shim
    // body shipped in source.
    {
        const g = self.prog.borrow();
        const bg = g.get().installed_bindings.borrow();
        const hit = bg.get().resolve(f.fqn);
        bg.deinit();
        g.deinit();
        if (hit) |intrinsic| return dispatchIntrinsic(self, allocator, intrinsic, args_in);
    }

    // Mis-bound type-specialized overload fallback. A bare call is lowered
    // to a single FuncId with no argument-type information, so it can bind
    // to the wrong type-specialized overload. When the resolved body's
    // concrete primitive parameter types definitely mismatch the runtime
    // arguments and a same-FQN intrinsic exists, dispatch the intrinsic.
    if (f.blocks.len != 0 and args_in.len != 0) {
        const user_offset: usize = if (paramIsThis(f.params)) 1 else 0;
        var mismatch = false;
        for (args_in, 0..) |*v, i| {
            const pidx = user_offset + i;
            if (pidx < f.params.len) {
                const p = &f.params[pidx];
                if (!p.is_vararg and !primitiveParamAccepts(p.ty.name, v)) {
                    mismatch = true;
                    break;
                }
            }
        }
        if (mismatch) {
            if (lookupIntrinsic(self, f.fqn)) |intrinsic| {
                return dispatchIntrinsic(self, allocator, intrinsic, args_in);
            }
        }
    }

    // Bodyless `expect` decl: redirect to a same-name same-arity sibling
    // with a body, or fall through to the intrinsic table.
    if (f.blocks.len == 0) {
        const want = args_in.len;
        const cands = module.funcsBySimpleName(f.name);
        for (cands) |cand| {
            if (cand.int() == func.int()) continue;
            const g = funcAt(module, cand) orelse continue;
            if (g.blocks.len == 0) continue;
            const g_params = g.params.len;
            const g_user_params = if (paramIsThis(g.params)) g_params - 1 else g_params;
            if (g_user_params != want and !lastIsVararg(g.params)) continue;
            return callFunc(self, allocator, module, cand, args_in);
        }
        // No same-name body sibling — try the declared FQN first, then
        // probe the common stdlib packages by simple name.
        if (lookupIntrinsic(self, f.fqn)) |intrinsic| {
            return dispatchIntrinsic(self, allocator, intrinsic, args_in);
        }
        const simple = f.name;
        const prefixes = [_][]const u8{
            "kotlin.",
            "kotlin.io.",
            "kotlin.math.",
            "kotlin.text.",
            "kotlin.collections.",
            "kotlin.ranges.",
            "kotlin.comparisons.",
            "kotlin.concurrent.",
            "kotlin.coroutines.",
            "kotlin.coroutines.intrinsics.",
            "kotlin.internal.",
        };
        for (prefixes) |pfx| {
            const probe = std.fmt.allocPrint(allocator, "{s}{s}", .{ pfx, simple }) catch continue;
            defer allocator.free(probe);
            if (lookupIntrinsic(self, probe)) |intrinsic| {
                return dispatchIntrinsic(self, allocator, intrinsic, args_in);
            }
        }
    }

    // Pad missing positional args with each param's default value.
    var args = try argsFromSlice(allocator, args_in);
    defer args.deinit(allocator);

    // Kotlin trailing-lambda rule: when fewer args are supplied than
    // params and the last param is a function type while a default-valued
    // param sits before it, the final supplied callable binds the LAST
    // param; the gap params fall back to their defaults.
    if (args.items.len < f.params.len and args.items.len != 0) {
        const last_is_fn = f.params.len > 0 and isFunctionType(&f.params[f.params.len - 1].ty);
        const trailing_is_callable = valueIsCallable(&args.items[args.items.len - 1]);
        if (last_is_fn and trailing_is_callable) {
            const lead = args.items.len - 1;
            const last_param = f.params.len - 1;
            if (lead < last_param) {
                if (funcDefaults(self, func)) |defaults| {
                    const trailing = args.items[args.items.len - 1];
                    args.items.len -= 1;
                    var idx = lead;
                    while (idx < last_param) : (idx += 1) {
                        if (idx < defaults.len and defaults[idx] != null) {
                            const dfid = defaults[idx].?;
                            const dfunc = funcAt(module, dfid) orelse
                                return .{ .err = typeErr(allocator, "default-arg FuncId {d} out of range", .{dfid.int()}) };
                            var thunk_args = try argsFromSlice(allocator, args.items);
                            var iface = self.hostInterface();
                            const r = try ir.eval.evalWith(allocator, module, dfunc, thunk_args, &iface);
                            switch (r) {
                                .ok => |v| try args.append(allocator, v),
                                .err => |e| return .{ .err = e },
                            }
                            _ = &thunk_args;
                        } else {
                            try args.append(allocator, .Null);
                        }
                    }
                    try args.append(allocator, trailing);
                }
            }
        }
    }

    if (args.items.len < f.params.len) {
        if (funcDefaults(self, func)) |defaults| {
            var idx = args.items.len;
            while (idx < f.params.len) : (idx += 1) {
                if (idx < defaults.len and defaults[idx] != null) {
                    const dfid = defaults[idx].?;
                    const dfunc = funcAt(module, dfid) orelse
                        return .{ .err = typeErr(allocator, "default-arg FuncId {d} out of range", .{dfid.int()}) };
                    // A thunk lowered inside an extension fn body that
                    // references the receiver records `this` as a capture,
                    // not a param — seed capture[0] with the receiver.
                    var captures: std.ArrayList(Value) = .empty;
                    if (args.items.len != 0) try captures.append(allocator, args.items[0]);
                    var thunk_args = try argsFromSlice(allocator, args.items);
                    var iface = self.hostInterface();
                    const r = try ir.eval.evalWithCaptures(allocator, module, dfunc, thunk_args, captures, &iface);
                    _ = &thunk_args;
                    switch (r) {
                        .ok => |v| try args.append(allocator, v),
                        .err => |e| return .{ .err = e },
                    }
                } else {
                    try args.append(allocator, .Null);
                }
            }
        }
    }

    const packed_args = try packVarargArgs(allocator, f, &args);
    // `packVarargArgs` either returns `args` itself or a fresh list after
    // deiniting `args`; the outer `defer args.deinit` would then double
    // free. Take ownership of the final list and disarm the defer.
    args = .empty;
    var iface = self.hostInterface();
    return ir.eval.evalWith(allocator, module, f, packed_args, &iface);
}

/// Single named-argument call dispatch flow.
pub fn callFuncNamed(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    var any_named = false;
    for (arg_names) |n| {
        if (n != null) {
            any_named = true;
            break;
        }
    }
    if (any_named) {
        if (funcAt(module, func)) |f| {
            const params = f.params;
            // Reorder named args against the declared parameter list.
            var slots = try allocator.alloc(?Value, params.len);
            defer allocator.free(slots);
            for (slots) |*s| s.* = null;

            // Bind named arguments first.
            for (args, 0..) |a, i| {
                if (i < arg_names.len) {
                    if (arg_names[i]) |arg_name| {
                        for (params, 0..) |p, pos| {
                            if (std.mem.eql(u8, p.name, arg_name)) {
                                slots[pos] = a;
                                break;
                            }
                        }
                    }
                }
            }

            // Vararg-aware positional walk.
            var vararg_pos: ?usize = null;
            for (params, 0..) |p, pi| {
                if (p.is_vararg) {
                    vararg_pos = pi;
                    break;
                }
            }
            var positional_idx: usize = 0;
            var vararg_acc: std.ArrayList(Value) = .empty;
            defer vararg_acc.deinit(allocator);
            var hit_vararg = false;
            for (args, 0..) |a, i| {
                const is_named = i < arg_names.len and arg_names[i] != null;
                if (is_named) continue;
                while (positional_idx < params.len and slots[positional_idx] != null) positional_idx += 1;
                if (vararg_pos != null and positional_idx == vararg_pos.?) {
                    if (a == .Array and vararg_acc.items.len == 0) {
                        // Spread case: a single Array at the vararg position
                        // passes through untouched.
                        slots[positional_idx] = a;
                        positional_idx += 1;
                        continue;
                    }
                    try vararg_acc.append(allocator, a);
                    hit_vararg = true;
                    continue;
                }
                if (positional_idx < params.len) slots[positional_idx] = a;
                positional_idx += 1;
            }
            if (vararg_pos) |vp| {
                if (hit_vararg) {
                    var acc: std.ArrayList(Value) = .empty;
                    try acc.appendSlice(allocator, vararg_acc.items);
                    slots[vp] = .{ .Array = .{ .items = try ValueList.init(allocator, acc), .prim = null } };
                } else if (slots[vp] == null) {
                    const empty_acc: std.ArrayList(Value) = .empty;
                    slots[vp] = .{ .Array = .{ .items = try ValueList.init(allocator, empty_acc), .prim = null } };
                }
            }

            // Fill omitted slots from the function's default-arg thunks.
            const defaults = funcDefaults(self, func);
            var reordered: std.ArrayList(Value) = .empty;
            defer reordered.deinit(allocator);
            var truncated = false;
            for (slots, 0..) |slot, i| {
                if (slot) |v| {
                    try reordered.append(allocator, v);
                    continue;
                }
                const dfid: ?FuncId = if (defaults != null and i < defaults.?.len) defaults.?[i] else null;
                if (dfid) |id| {
                    const dfunc = funcAt(module, id) orelse
                        return .{ .err = typeErr(allocator, "default-arg FuncId {d} out of range", .{id.int()}) };
                    var thunk_args = try argsFromSlice(allocator, reordered.items);
                    var iface = self.hostInterface();
                    const r = try ir.eval.evalWith(allocator, module, dfunc, thunk_args, &iface);
                    _ = &thunk_args;
                    switch (r) {
                        .ok => |v| try reordered.append(allocator, v),
                        .err => |e| return .{ .err = e },
                    }
                } else {
                    // No value and no default: a trailing omitted param.
                    // Hand the prefix to call_func, whose own padding
                    // finishes the job.
                    truncated = true;
                    break;
                }
            }
            if (!truncated) {
                while (reordered.items.len != 0 and reordered.items[reordered.items.len - 1] == .Null) {
                    _ = reordered.pop();
                }
            }
            return callFunc(self, allocator, module, func, reordered.items);
        }
    }
    return callFunc(self, allocator, module, func, args);
}

pub fn callFuncTyped(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8, type_args: []const []const u8, exact: bool) Allocator.Error!EvalResult {
    // Reified enum reflection: `enumValues<T>()` / `enumValueOf<T>(name)`.
    if (funcAt(module, func)) |f| {
        if (std.mem.startsWith(u8, f.fqn, "kotlin") and
            (std.mem.eql(u8, f.name, "enumValues") or std.mem.eql(u8, f.name, "enumValueOf")))
        {
            if (type_args.len > 0 and type_args[0].len != 0) {
                const tn = type_args[0];
                const cls_value: ?Value = blk: {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    if (cg.get().get(tn)) |c| break :blk Value{ .Class = c.clone() };
                    break :blk host_globals.lookupGlobal(self, tn);
                };
                if (cls_value) |cv| {
                    if (cv == .Class) {
                        const cls = cv.Class;
                        const cd = cls.borrow();
                        const is_enum = cd.get().is_enum;
                        if (is_enum) {
                            if (std.mem.eql(u8, f.name, "enumValues")) {
                                var items: std.ArrayList(Value) = .empty;
                                const eg = cd.get().enum_entries.borrow();
                                for (eg.get().items) |entry| {
                                    items.append(allocator, entry.value) catch {};
                                }
                                eg.deinit();
                                const enum_class = try StringRef.init(allocator, cd.get().name);
                                cd.deinit();
                                return .{ .ok = .{ .List = .{
                                    .items = try ValueList.init(allocator, items),
                                    .mutable = false,
                                    .enum_class = enum_class,
                                    .backing = null,
                                } } };
                            }
                            // enumValueOf<T>(name)
                            if (args.len > 0 and args[0] == .String) {
                                const sg = args[0].String.borrow();
                                const want = sg.get().*;
                                const eg = cd.get().enum_entries.borrow();
                                for (eg.get().items) |entry| {
                                    if (std.mem.eql(u8, entry.name, want)) {
                                        const out = entry.value;
                                        eg.deinit();
                                        sg.deinit();
                                        cd.deinit();
                                        return .{ .ok = out };
                                    }
                                }
                                eg.deinit();
                                const fqn = try StringRef.init(allocator, "kotlin.IllegalArgumentException");
                                const msg = try StringRef.init(allocator, try std.fmt.allocPrint(allocator, "No enum constant {s}.{s}", .{ cd.get().fqn, want }));
                                sg.deinit();
                                cd.deinit();
                                return .{ .err = .{ .Throw = .{ .Exception = .{ .fqn = fqn, .message = msg, .cause = null } } } };
                            }
                        }
                        cd.deinit();
                    }
                }
            }
        }
    }

    // Overload resolution. Skipped for an `exact` call: the lowering
    // already resolved the overload from an explicit argument cast.
    const resolved: FuncId = if (exact) func else (pickOverload(self, module, func, args) orelse func);

    // Incompatible-receiver guard: a bare call baked to a top-level
    // extension whose declared receiver is a user/pack class, with an
    // actual receiver that is a builtin value, cannot be correct.
    // Re-dispatch as a member call so the builtin member wins.
    if (funcAt(module, resolved)) |f| {
        if (paramIsThis(f.params) and args.len != 0 and
            extDeclRecvIsUserClass(f.params[0].ty.name) and valueIsBuiltin(&args[0]))
        {
            const fname = f.name;
            const recv = args[0];
            const rest = args[1..];
            return host_call_member.callMember(self, allocator, &recv, fname, rest);
        }
    }

    // Bind each call-site type-arg name to a synth `Value::Class` global
    // for the duration of the call so reified type-param reads resolve.
    var names: []const []const u8 = &.{};
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.func_type_params.get(resolved)) |list| {
            names = list.items;
        }
    }
    const Saved = struct { name: []const u8, prev: ?Value };
    var saved: std.ArrayList(Saved) = .empty;
    defer saved.deinit(allocator);
    for (names, 0..) |type_name, idx| {
        const arg_name: []const u8 = if (idx < type_args.len) type_args[idx] else "";
        if (arg_name.len == 0) continue;
        const cls_value = host_globals.lookupGlobal(self, arg_name);
        const prev = blk: {
            const g = self.globals.borrow();
            defer g.deinit();
            break :blk g.get().lookup(type_name);
        };
        try saved.append(allocator, .{ .name = type_name, .prev = prev });
        if (cls_value) |v| {
            const g = self.globals.borrowMut();
            defer g.deinit();
            g.get().define(type_name, v) catch {};
        }
    }

    const result = try callFuncNamed(self, allocator, module, resolved, args, arg_names);

    var ri: usize = saved.items.len;
    while (ri > 0) {
        ri -= 1;
        const s = saved.items[ri];
        const g = self.globals.borrowMut();
        defer g.deinit();
        if (s.prev) |v| {
            g.get().define(s.name, v) catch {};
        } else {
            g.get().removeLocal(s.name);
        }
    }
    return result;
}

pub fn callNamedOverload(self: *VmHost, allocator: Allocator, module: *const Module, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!MaybeValueResult {
    // Only intercept genuine overload sets: a single top-level function
    // keeps the plain global-value path.
    var candidates: std.ArrayList(FuncId) = .empty;
    defer candidates.deinit(allocator);
    for (module.func_index.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) try candidates.append(allocator, entry.id);
    }
    if (candidates.items.len < 2) return .{ .ok = null };

    // Pick the best body-carrying overload by runtime arg types.
    var best_func: ?FuncId = null;
    var best_score: i32 = 0;
    for (candidates.items) |cand| {
        if (overloadScore(self, module, cand, args)) |score| {
            if (best_func == null or score > best_score) {
                best_func = cand;
                best_score = score;
            }
        }
    }
    const func = best_func orelse return .{ .ok = null };

    if (trace.enabled(name)) {
        trace.emit("global-overload {s} -> fid={d} (of {d} candidates)", .{ name, func.int(), candidates.items.len });
    }

    const r = try callFuncTyped(self, allocator, module, func, args, arg_names, &.{}, false);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = e },
    };
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}
