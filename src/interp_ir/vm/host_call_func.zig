//! `VmHost` dispatch for top-level and named functions: resolving a `FuncId` with
//! named args, type args, and overloads. Aliased as `VmHost` methods by `vmhost.zig`.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const applicability = @import("applicability");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const trace = @import("trace.zig");
const host_call_member = @import("host_call_member.zig");
const host_globals = @import("host_globals.zig");
const intrinsic_host = @import("intrinsic_host.zig");
const overload_match = @import("overload_match.zig");
const compose = @import("compose.zig");
const host_instances = @import("host_instances.zig");

const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const InstanceData = runtime.InstanceData;
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

fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) EvalError {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "IR type error";
    return .{ .Type = msg };
}

/// Copy `items` into an `ArrayList` the evaluator owns, sharing `ObjRef` handles.
fn argsFromSlice(allocator: Allocator, items: []const Value) Allocator.Error!std.ArrayList(Value) {
    // From the size-classed carrier pool; the frame's teardown releases it.
    var out = try ir.eval.acquireArgsCap(allocator, items.len);
    if (out.capacity >= items.len) {
        out.appendSliceAssumeCapacity(items);
    } else {
        try out.appendSlice(allocator, items);
    }
    return out;
}

/// Borrowed pointer into the module's `funcs`; the module outlives the call.
fn funcAt(module: *const Module, id: FuncId) ?*const Func {
    return module.funcById(id);
}

fn paramIsThis(params: []const ir.Param) bool {
    return params.len > 0 and std.mem.eql(u8, params[0].name, "this");
}

fn lastIsVararg(params: []const ir.Param) bool {
    return params.len > 0 and params[params.len - 1].is_vararg;
}

/// A `vararg` before the last parameter, which Kotlin allows. `packVarargArgs`
/// cannot bind it, so the call routes through `callFuncNamed`'s reorder binder.
fn hasNonFinalVararg(params: []const ir.Param) bool {
    if (params.len == 0) return false;
    for (params[0 .. params.len - 1]) |p| {
        if (p.is_vararg) return true;
    }
    return false;
}

fn funcDefaults(self: *VmHost, func: FuncId) ?[]?FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().func_defaults.get(func.int());
}

/// Primitive-array kind for a vararg element type, null for a reference element:
/// Kotlin materializes `vararg Byte` as a `ByteArray`, not a boxed `Array`.
fn varargPrimKind(elem: []const u8) ?runtime.PrimitiveArrayKind {
    const K = runtime.PrimitiveArrayKind;
    const table = [_]struct { n: []const u8, k: K }{
        .{ .n = "Byte", .k = .Byte },       .{ .n = "Int", .k = .Int },
        .{ .n = "Long", .k = .Long },       .{ .n = "Short", .k = .Short },
        .{ .n = "Double", .k = .Double },   .{ .n = "Float", .k = .Float },
        .{ .n = "Boolean", .k = .Boolean }, .{ .n = "Char", .k = .Char },
        .{ .n = "UByte", .k = .UByte },     .{ .n = "UInt", .k = .UInt },
        .{ .n = "ULong", .k = .ULong },     .{ .n = "UShort", .k = .UShort },
    };
    for (table) |e| {
        if (std.mem.eql(u8, elem, e.n)) return e.k;
    }
    return null;
}

/// Consumes `list`, packing it into a primitive array when `elem_ty` is primitive,
/// else a boxed `Array`.
pub fn packVarargArray(allocator: Allocator, elem_ty: []const u8, list: std.ArrayList(Value)) Allocator.Error!Value {
    if (varargPrimKind(elem_ty)) |k| {
        var l = list;
        const v = try runtime.ArrayData.initPacked(allocator, k, l.items);
        if (runtime.reclaimEnabled()) for (l.items) |e| e.release(allocator);
        l.deinit(allocator);
        return v;
    }
    return runtime.ArrayData.fromBoxedList(try ValueList.init(allocator, list));
}

/// Collapse the positional args of a vararg call into one `Array` slot,
/// consuming `args`. An `f(*arr)` spread already in the slot passes through.
fn packVarargArgs(allocator: Allocator, func: *const Func, args: *std.ArrayList(Value)) Allocator.Error!std.ArrayList(Value) {
    const n_params = func.params.len;
    // Kotlin allows the vararg before trailing fixed params, so it absorbs the
    // middle positional args and leaves the trailing params' worth at the end.
    var vararg_pos: ?usize = null;
    for (func.params, 0..) |p, i| {
        if (p.is_vararg) {
            vararg_pos = i;
            break;
        }
    }
    const vp = vararg_pos orelse return args.*;
    // Kotlin fills a defaulted post-vararg parameter by name, so it reserves no positional.
    var tail_fixed: usize = 0;
    for (func.params[vp + 1 ..]) |*tp| {
        if (tp.default == null) tail_fixed += 1;
    }
    // A pairless call, with no Composer instance and Int tail, lets the vararg absorb
    // everything.
    var pairless_pair = false;
    if (tail_fixed >= 2 and n_params >= 2 and
        std.mem.eql(u8, func.params[n_params - 1].name, "$changed") and
        std.mem.eql(u8, func.params[n_params - 2].name, "$composer"))
    {
        const has_pair_tail = args.items.len >= 2 and
            args.items[args.items.len - 1] == .Int and
            args.items[args.items.len - 2] == .Instance and blk: {
                const ig = args.items[args.items.len - 2].Instance.borrow();
                defer ig.deinit();
                const cg = ig.get().class.borrow();
                defer cg.deinit();
                break :blk std.mem.indexOf(u8, cg.get().name, "Composer") != null;
            };
        if (!has_pair_tail) {
            tail_fixed -|= 2;
            pairless_pair = true;
        }
    }
    if (args.items.len == n_params and args.items[vp] == .Array) {
        return args.*;
    }
    // Underfilled before the trailing fixed params; the defaults machinery fills them.
    if (tail_fixed != 0 and args.items.len < vp + tail_fixed) return args.*;
    const n_var = if (args.items.len > vp + tail_fixed) args.items.len - vp - tail_fixed else 0;
    var out = try ir.eval.acquireArgsCap(allocator, n_params);
    var i: usize = 0;
    while (i < vp and i < args.items.len) : (i += 1) {
        out.appendAssumeCapacity(args.items[i]);
    }
    var rest: std.ArrayList(Value) = .empty;
    var j: usize = vp;
    while (j < vp + n_var and j < args.items.len) : (j += 1) {
        try rest.append(allocator, args.items[j]);
    }
    const velem = func.params[vp].ty.name;
    try out.append(allocator, try packVarargArray(allocator, velem, rest));
    j = vp + n_var;
    while (j < args.items.len) : (j += 1) {
        try out.append(allocator, args.items[j]);
    }
    // Pairless pair slots stay Null; `callFuncTypedInner` completes them.
    if (pairless_pair) {
        try out.append(allocator, .Null);
        try out.append(allocator, .Null);
    }
    ir.eval.releaseArgs(allocator, args);
    return out;
}

/// Intrinsic by FQN; the `installed_bindings` overlay shadows the stdlib default.
fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
    // Post-link the bindings table is read-only; the link flag gates an unguarded read.
    {
        const img = self.prog.asPtrConst();
        if (@atomicLoad(bool, &img.resolved_linked, .acquire)) {
            if (img.installed_bindings.asPtrConst().resolve(fqn)) |f| return f;
            return stdlib.implementation(fqn);
        }
    }
    {
        const g = self.prog.borrow();
        defer g.deinit();
        const bg = g.get().installed_bindings.borrow();
        defer bg.deinit();
        if (bg.get().resolve(fqn)) |f| return f;
    }
    return stdlib.implementation(fqn);
}

/// Retag a List of Ints in place to Short/Byte when the declared parameter is an
/// iterable of that kind and every element fits; static typing allows no other.
fn narrowIntListArg(param_ty: *const TypeRef, arg: *const Value) void {
    if (arg.* != .List) return;
    const pn = param_ty.name;
    const iterable_like = std.mem.eql(u8, pn, "Iterable") or std.mem.eql(u8, pn, "Collection") or
        std.mem.eql(u8, pn, "List") or std.mem.eql(u8, pn, "MutableList") or std.mem.eql(u8, pn, "Set");
    if (!iterable_like or param_ty.args.len != 1) return;
    const en = param_ty.args[0].name;
    const to_short = std.mem.eql(u8, en, "Short");
    const to_byte = std.mem.eql(u8, en, "Byte");
    if (!to_short and !to_byte) return;
    const g = arg.List.items.borrowMut();
    defer g.deinit();
    for (g.get().items) |*v| {
        if (v.* != .Int) return;
        const x = v.Int;
        if (to_short and (x < std.math.minInt(i16) or x > std.math.maxInt(i16))) return;
        if (to_byte and (x < std.math.minInt(i8) or x > std.math.maxInt(i8))) return;
    }
    for (g.get().items) |*v| {
        const x = v.Int;
        v.* = if (to_short) .{ .Short = @intCast(x) } else .{ .Byte = @intCast(x) };
    }
}

/// Bind an unspellable reified type argument from the arguments: the first value
/// parameter declared as that bare type variable binds its runtime class, head only.
fn inferTypeArgFromArgs(self: *VmHost, allocator: Allocator, f: *const ir.Func, type_name: []const u8, args: []const Value) ?Value {
    for (f.params, 0..) |*p, i| {
        if (i >= args.len) break;
        if (!std.mem.eql(u8, p.ty.name, type_name)) continue;
        const v = args[i];
        switch (v) {
            .Instance => |inst| {
                const g = inst.borrow();
                defer g.deinit();
                return Value{ .Class = g.get().class.clone() };
            },
            .Null => continue,
            else => {
                // A builtin binds its classifier, head only, so `typeOf<T>()` names the
                // real type.
                const fqn = v.typeFqn();
                const head = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
                {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    if (cg.get().get(head)) |c| return Value{ .Class = c.clone() };
                }
                return host_call_member.syntheticClassFromFqn(allocator, fqn) catch null;
            },
        }
    }
    return null;
}

/// Read-side binding of reified `name` from the innermost frame's own arguments,
/// the first parameter declared as the bare variable; never a stale splice global.
pub fn reifiedFromFrame(self: *VmHost, allocator: Allocator, name: []const u8) ?Value {
    const fr = ir.eval.currentFrameFunc() orelse return null;
    const names: []const []const u8 = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.func_type_params.get(fr.id)) |l| break :blk l.items;
        break :blk &.{};
    };
    var declared = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) declared = true;
    }
    if (!declared) return null;
    for (fr.params, 0..) |*p, i| {
        if (!std.mem.eql(u8, p.ty.name, name)) continue;
        const v = ir.eval.currentFrameParam(i) orelse continue;
        switch (v) {
            .Instance => |inst| {
                const g = inst.borrow();
                defer g.deinit();
                return Value{ .Class = g.get().class.clone() };
            },
            .Null => continue,
            else => {
                const fqn = v.typeFqn();
                const head = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
                {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    if (cg.get().get(head)) |c| return Value{ .Class = c.clone() };
                }
                return host_call_member.syntheticClassFromFqn(allocator, fqn) catch null;
            },
        }
    }
    return null;
}

/// Globals key holding a reified parameter's full generic spelling beside its
/// `.Class` binding: `T` binds the class, `T<>` the `List<Int>` spelling.
fn reifiedSpellingKey(allocator: Allocator, type_name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}<>", .{type_name});
}

fn typeArgUnbound(arg_name: []const u8, names: []const []const u8) bool {
    if (arg_name.len == 0) return true;
    for (names) |n| {
        if (std.mem.eql(u8, n, arg_name)) return true;
    }
    return false;
}

/// Synthetic `KType` for a reified type name: `classifier` is the registered
/// class when known, else a minimal KClass, and `isMarkedNullable` mirrors `?`.
fn makeKTypeValue(self: *VmHost, allocator: Allocator, type_name: []const u8) Allocator.Error!Value {
    if (runtime.envOnce("KLIO_KTYPE_TRACE") != null) {
        const in_fn = if (ir.eval.currentFrameFunc()) |f| f.name else "-";
        std.debug.print("[ktype] raw='{s}' in_fn={s}\n", .{ type_name, in_fn });
    }
    const trimmed = std.mem.trim(u8, type_name, " ");
    const nullable = std.mem.endsWith(u8, trimmed, "?");
    const base = if (nullable) trimmed[0 .. trimmed.len - 1] else trimmed;
    // Split `Head<A, B>`: the head is the classifier, the arguments become
    // `KTypeProjection`s.
    var head = base;
    var generic_args: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, base, '<')) |lt| {
        if (std.mem.lastIndexOfScalar(u8, base, '>')) |gt| {
            if (gt > lt) {
                head = base[0..lt];
                generic_args = base[lt + 1 .. gt];
            }
        }
    }
    // Lowering mangles a local class head as `$lc<fn>`; the runtime class is
    // registered under the simple declared name, which the KType needs.
    if (std.mem.indexOf(u8, head, "$lc")) |lci| head = head[0..lci];
    // A bare type-variable head resolves through the bound type-param global, not a
    // class named `T`.
    const bound_head: []const u8 = blk: {
        if (std.mem.indexOfScalar(u8, head, '.') != null) break :blk head;
        const fr = ir.eval.currentFrameFunc() orelse break :blk head;
        const names: []const []const u8 = nb: {
            const mg = self.module.borrow();
            defer mg.deinit();
            if (mg.get().registry.func_type_params.get(fr.id)) |l| break :nb l.items;
            break :nb &.{};
        };
        var is_tp = false;
        for (names) |n| {
            if (std.mem.eql(u8, n, head)) is_tp = true;
        }
        if (!is_tp) break :blk head;
        {
            const key = try reifiedSpellingKey(allocator, head);
            // The globals borrow is released before the recursive materialisation.
            const spelled_owned: ?[]const u8 = blk2: {
                const g = self.globals.borrow();
                defer g.deinit();
                const sv = g.get().lookup(key) orelse break :blk2 null;
                if (sv != .String) break :blk2 null;
                const sg = sv.String.borrow();
                defer sg.deinit();
                const spelled = sg.get().bytes;
                if (std.mem.eql(u8, spelled, head) or (std.mem.indexOfScalar(u8, spelled, '<') == null and !std.mem.endsWith(u8, spelled, "?"))) break :blk2 null;
                break :blk2 try allocator.dupe(u8, spelled);
            };
            if (runtime.envOnce("KLIO_KTYPE_TRACE") != null) std.debug.print("[ktype] spelling {s} -> {?s}\n", .{ key, spelled_owned });
            if (spelled_owned) |sp| {
                return makeKTypeValue(self, allocator, sp);
            }
        }
        if (reifiedFromFrame(self, allocator, head)) |fv| {
            if (fv == .Class) {
                const fg = fv.Class.borrow();
                defer fg.deinit();
                break :blk try allocator.dupe(u8, fg.get().name);
            }
        }
        const g = self.globals.borrow();
        defer g.deinit();
        const bv = g.get().lookup(head) orelse break :blk head;
        if (bv != .Class) break :blk head;
        const cg2 = bv.Class.borrow();
        defer cg2.deinit();
        break :blk try allocator.dupe(u8, cg2.get().name);
    };
    const classifier: Value = blk: {
        {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (runtime.envOnce("KLIO_KTYPE_TRACE") != null) std.debug.print("[ktype] classifier head='{s}' direct={}\n", .{ bound_head, cg.get().get(bound_head) != null });
            if (cg.get().get(bound_head)) |c| break :blk Value{ .Class = c.clone() };
            // A LIFTED nested spelling (`Outer$Inner`) resolves through the
            // dotted form or the innermost simple name the table holds.
            if (std.mem.indexOfScalar(u8, bound_head, '$')) |_| {
                const dotted = try allocator.dupe(u8, bound_head);
                for (dotted) |*ch| {
                    if (ch.* == '$') ch.* = '.';
                }
                if (cg.get().get(dotted)) |c| break :blk Value{ .Class = c.clone() };
                const last = bound_head[std.mem.lastIndexOfScalar(u8, bound_head, '$').? + 1 ..];
                if (cg.get().get(last)) |c| break :blk Value{ .Class = c.clone() };
            }
        }
        if (std.mem.indexOfScalar(u8, bound_head, '.')) |_| {
            var segs = std.mem.splitScalar(u8, bound_head, '.');
            var cur: ?ObjRef(runtime.ClassDef) = null;
            var ok_walk = true;
            while (segs.next()) |seg| {
                if (cur == null) {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    cur = cg.get().get(seg);
                    if (cur == null) {
                        // The root may itself be nested in an executing receiver.
                        var it0 = ir.eval.frameThisChainIter();
                        while (it0.next()) |v| {
                            const owner0: ?ObjRef(runtime.ClassDef) = switch (v) {
                                .Instance => |inst| ib: {
                                    const g = inst.borrow();
                                    defer g.deinit();
                                    break :ib g.get().class;
                                },
                                .Class => |c| c,
                                else => null,
                            };
                            const oc0 = owner0 orelse continue;
                            const og0 = oc0.borrow();
                            defer og0.deinit();
                            for (og0.get().nested_classes) |nc| {
                                if (std.mem.eql(u8, nc.name, seg)) cur = nc.class;
                            }
                            if (cur != null) break;
                        }
                    }
                    if (cur == null) {
                        ok_walk = false;
                        break;
                    }
                } else {
                    var found: ?ObjRef(runtime.ClassDef) = null;
                    {
                        const og = cur.?.borrow();
                        defer og.deinit();
                        for (og.get().nested_classes) |nc| {
                            if (std.mem.eql(u8, nc.name, seg)) found = nc.class;
                        }
                    }
                    if (found == null) {
                        ok_walk = false;
                        break;
                    }
                    cur = found;
                }
            }
            if (ok_walk and cur != null) break :blk Value{ .Class = cur.?.clone() };
        }
        // A nested class written by its simple name resolves through the executing
        // receivers.
        var it = ir.eval.frameThisChainIter();
        while (it.next()) |v| {
            const owner: ?ObjRef(runtime.ClassDef) = switch (v) {
                .Instance => |inst| ib: {
                    const g = inst.borrow();
                    defer g.deinit();
                    break :ib g.get().class;
                },
                .Class => |c| c,
                else => null,
            };
            const oc = owner orelse continue;
            const og = oc.borrow();
            defer og.deinit();
            for (og.get().nested_classes) |nc| {
                if (std.mem.eql(u8, nc.name, bound_head)) break :blk Value{ .Class = nc.class.clone() };
            }
        }
        break :blk try host_call_member.syntheticClassFromFqn(allocator, bound_head);
    };
    var args_accum: std.ArrayList(Value) = .empty;
    if (generic_args) |ga| {
        var depth: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= ga.len) : (i += 1) {
            const at_end = i == ga.len;
            const c: u8 = if (at_end) ',' else ga[i];
            if (c == '<') depth += 1;
            if (c == '>' and depth > 0) depth -= 1;
            if (c == ',' and depth == 0) {
                const piece = std.mem.trim(u8, ga[start..i], " ");
                start = i + 1;
                if (piece.len == 0) continue;
                var view0 = VmIntrinsicHost.borrowed(vmhost.SharedHandles.fromHost(self));
                const pid = intrinsic_host.allocInstanceId(&view0);
                const proj_ty: Value = if (std.mem.eql(u8, piece, "*"))
                    .Null
                else
                    try makeKTypeValue(self, allocator, piece);
                const pfields = [_]InstanceData.Field{
                    .{ .name = "type", .value = proj_ty },
                };
                const proj = try intrinsic_host.newSynthInstance(&view0, "kotlin.reflect.KTypeProjection", pid, &pfields);
                try args_accum.append(allocator, proj);
            }
        }
    }
    const args_value: Value = try Value.newList(allocator, .{
        .items = try ValueList.init(allocator, args_accum),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    });
    var view = VmIntrinsicHost.borrowed(vmhost.SharedHandles.fromHost(self));
    const id = intrinsic_host.allocInstanceId(&view);
    const fields = [_]InstanceData.Field{
        .{ .name = "classifier", .value = classifier },
        .{ .name = "arguments", .value = args_value },
        .{ .name = "isMarkedNullable", .value = .{ .Bool = nullable } },
    };
    return intrinsic_host.newSynthInstance(&view, "kotlin.reflect.KType", id, &fields);
}

/// Run `func` through a `CallCtx` on a borrowed `VmIntrinsicHost`.
fn dispatchIntrinsic(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(allocator, "intrinsic_call_func", fqn, null, null, args);
    const keepalive = self.ka.mark();
    defer self.ka.restore(keepalive);
    self.ka.pushSlice(args);
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
        intrinsic.singletons_by_id.deinit();
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
        .err => |e| .{ .err = runtimeErrorToEval(allocator, e) },
    };
}

fn runtimeErrorToEval(allocator: Allocator, e: RuntimeError) EvalError {
    return switch (e) {
        .Thrown => |v| .{ .Throw = v },
        .Return => |v| .{ .NonLocalReturn = v },
        // A suspending primitive asked to park: seed a fresh SuspendState, which
        // each enclosing `eval` frame fills as it unwinds for the driver to park.
        .Suspend => |wake| blk: {
            const st = allocator.create(SuspendState) catch break :blk EvalError{ .Type = "out of memory seeding suspend" };
            st.* = .{ .token = 0, .frames = .empty, .wake_in_millis = wake, .pending_resume_reg = null };
            break :blk EvalError{ .Suspended = st };
        },
        .Unbound => |s| .{ .Unbound = s },
        .Type => |s| .{ .Type = s },
        .Arity => |s| .{ .Arity = s },
        .Unimplemented => |s| .{ .Unimplemented = s },
        .CalleeFailed => |s| .{ .CalleeFailed = s },
        // A labeled return crossing a host intrinsic keeps unwinding, not flattened to
        // a Type error.
        .LabeledReturn => |lr| .{ .LabeledReturn = .{ .label = lr.label, .value = lr.value } },
        else => typeErr(allocator, "{s}", .{@tagName(e)}),
    };
}

/// The single executable native form bound to `func`, settled by
/// `ProgramImage.linkResolvedForms`. Null when the form is its lowered body.
pub fn resolvedNativeForm(self: *VmHost, func: FuncId) ?StdlibFn {
    // Post-link the table is read-only; skip the lock, which ping-pongs across threads.
    const img = self.prog.asPtrConst();
    if (@atomicLoad(bool, &img.resolved_linked, .acquire)) {
        return img.resolvedNativeForm(func);
    }
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().resolvedNativeForm(func);
}

/// Whether `func` can run: a lowered body, or a link-settled form (native binding,
/// same-FQN intrinsic, body-sibling redirect). An unsettled header would cycle.
pub fn executableForm(self: *VmHost, module: *const Module, func: FuncId, argc: usize) bool {
    const f = funcAt(module, func) orelse return false;
    if (f.hasBody()) return true;
    if (resolvedNativeForm(self, func) != null) return true;
    if (lookupIntrinsic(self, f.fqn) != null) return true;
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().resolvedRedirectTarget(module, func, argc) != null;
}

/// Whether a deferred bare call that missed every arm names an unsettled header,
/// an `expect` with no `actual` here. Such a call is a no-op returning Unit.
pub fn bareUnsettledHeaderNoOp(self: *VmHost, module: *const Module, name: []const u8, argc: usize) bool {
    for (module.funcsBySimpleName(name)) |fid| {
        const f = funcAt(module, fid) orelse continue;
        if (f.hasBody()) continue;
        const receiver_formed = paramIsThis(f.params);
        const want = if (receiver_formed) argc + 1 else argc;
        if (f.params.len < want) continue;
        if (executableForm(self, module, fid, want)) continue;
        if (trace.enabled(name)) {
            trace.emit("map=bare_unsettled_noop name={s} fqn={s}", .{ name, f.fqn });
        }
        return true;
    }
    return false;
}

/// Prefixes the audit probes for a bodyless declaration, in order.
const deleted_bodyless_prefixes = [_][]const u8{
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

/// Overlay-then-embedded FQN probe, kept clear of the tables under audit.
fn auditIntrinsicProbe(self: *VmHost, fqn: []const u8) ?StdlibFn {
    {
        const g = self.prog.borrow();
        defer g.deinit();
        const bg = g.get().installed_bindings.borrow();
        defer bg.deinit();
        if (bg.get().resolve(fqn)) |i| return i;
    }
    return stdlib.implementation(fqn);
}

/// `KLIO_LINK_AUDIT`: re-derive per-call dispatch for `func` from the raw sources
/// and log any divergence from the link-settled tables.
pub fn linkAuditCheck(self: *VmHost, module: *const Module, func: FuncId, f: *const ir.Func, args_in: []const Value) void {
    if (!linkAuditOn()) return;
    if (f.hasBody()) {
        const per_call: ?StdlibFn = blk: {
            const g = self.prog.borrow();
            defer g.deinit();
            const bg = g.get().installed_bindings.borrow();
            defer bg.deinit();
            break :blk bg.get().resolve(f.fqn);
        };
        const linked = resolvedNativeForm(self, func);
        if (per_call != linked) {
            std.debug.print(
                "[KLIO_LINK_AUDIT] divergence: fid={d} fqn={s} per_call={s} linked={s}\n",
                .{ func.int(), f.fqn, if (per_call != null) "native" else "body", if (linked != null) "native" else "body" },
            );
        }
        return;
    }

    // Rung 1: sibling scan, first body-bearing arity-fitting namesake.
    const per_call_sibling: ?FuncId = blk: {
        for (module.funcsBySimpleName(f.name)) |cand| {
            if (cand.int() == func.int()) continue;
            const g = funcAt(module, cand) orelse continue;
            if (!g.hasBody()) continue;
            const g_user = if (paramIsThis(g.params)) g.params.len - 1 else g.params.len;
            if (g_user != args_in.len and !lastIsVararg(g.params)) continue;
            break :blk cand;
        }
        break :blk null;
    };
    const linked_sibling: ?FuncId = blk: {
        const g = self.prog.borrow();
        defer g.deinit();
        break :blk g.get().resolvedRedirectTarget(module, func, args_in.len);
    };
    if ((per_call_sibling == null) != (linked_sibling == null) or
        (per_call_sibling != null and per_call_sibling.?.int() != linked_sibling.?.int()))
    {
        std.debug.print(
            "[KLIO_LINK_AUDIT] divergence: fid={d} fqn={s} sibling per_call={?} linked={?}\n",
            .{ func.int(), f.fqn, per_call_sibling, linked_sibling },
        );
    }
    if (per_call_sibling != null) return;

    // Rungs 2 and 3: declared FQN, then the prefix sequence.
    const per_call_native: ?StdlibFn = blk: {
        if (auditIntrinsicProbe(self, f.fqn)) |i| break :blk i;
        var buf: [128]u8 = undefined;
        for (deleted_bodyless_prefixes) |pfx| {
            if (pfx.len + f.name.len > buf.len) continue;
            const probe = std.fmt.bufPrint(&buf, "{s}{s}", .{ pfx, f.name }) catch continue;
            if (auditIntrinsicProbe(self, probe)) |i| break :blk i;
        }
        break :blk null;
    };
    const linked_native = resolvedNativeForm(self, func);
    if (per_call_native != linked_native) {
        std.debug.print(
            "[KLIO_LINK_AUDIT] divergence: fid={d} fqn={s} per_call={s} linked={s}\n",
            .{ func.int(), f.fqn, if (per_call_native != null) "native" else "body", if (linked_native != null) "native" else "body" },
        );
    }
}

var link_audit_checked: bool = false;
var link_audit_enabled: bool = false;

fn linkAuditOn() bool {
    if (!link_audit_checked) {
        link_audit_checked = true;
        const a = std.heap.page_allocator;
        if (runtime.procEnvGetVar(a, "KLIO_LINK_AUDIT") catch null) |v| {
            a.free(v);
            link_audit_enabled = true;
        }
    }
    return link_audit_enabled;
}

const QItem = struct { name: []const u8, depth: i32 };

/// Pack each arg's primitive scalar tag into a 64-bit signature: 4 bits per
/// arg, arity in the top byte. Null for a non-scalar arg or more than 12. The
/// tag settles overload selection, so `(module, func, sig)` soundly keys a memo.
fn argSigPrimitive(args: []const Value) ?u64 {
    if (args.len > 12) return null;
    var sig: u64 = @as(u64, args.len) << 56;
    for (args, 0..) |*a, i| {
        const tag: u64 = switch (a.*) {
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
            else => return null,
        };
        sig |= tag << @intCast(i * 4);
    }
    return sig;
}

fn overloadCacheGet(self: *VmHost, key: root.ProgramImage.OverloadKey) ?FuncId {
    const pg = self.prog.borrow();
    defer pg.deinit();
    if (pg.get().overload_cache.get(key)) |raw| return @enumFromInt(raw);
    return null;
}

fn overloadCachePut(self: *VmHost, key: root.ProgramImage.OverloadKey, fid: FuncId) void {
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    pg.get().overload_cache.put(key, @intFromEnum(fid)) catch {};
}

/// `pickOverload` memoized on `(module, func, sig)`, only for all-primitive args.
fn pickOverloadCached(self: *VmHost, module: *const Module, func: FuncId, args: []const Value) ?FuncId {
    if (argSigPrimitive(args)) |sig| {
        const key = root.ProgramImage.OverloadKey{ .module_p = @intFromPtr(module), .func_p = func.int(), .sig = sig };
        if (overloadCacheGet(self, key)) |cached| return cached;
        const r = pickOverload(self, module, func, args);
        // Memoize the effective target; the base func stands for "nothing better".
        overloadCachePut(self, key, r orelse func);
        return r;
    }
    return pickOverload(self, module, func, args);
}

/// A closure's source-level param count. The compose plugin appends
/// `($composer, $changed)`, and the +2 shift would mis-rank overloads.
pub fn closureUserParams(self: *VmHost, info: anytype) usize {
    return closureUserParamsChecked(self, info).n;
}

/// As `closureUserParams`, also reporting whether the composer pair was stripped:
/// a stripped count is authoritative for ranking and breaks the want/want+1 tie.
pub fn closureUserParamsChecked(self: *VmHost, info: anytype) struct { n: usize, stripped: bool } {
    var n: usize = info.n_params;
    var stripped = false;
    if (n >= 2) {
        const module_ref = self.module.clone();
        defer module_ref.deinit();
        const module = info.module orelse module_ref.asPtr();
        if (module.funcById(info.body_func)) |bf| {
            const p = bf.params;
            if (p.len >= 2 and std.mem.eql(u8, p[p.len - 1].name, "$changed") and
                std.mem.eql(u8, p[p.len - 2].name, "$composer"))
            {
                n -= 2;
                stripped = true;
            }
        }
    }
    return .{ .n = n, .stripped = stripped };
}

/// A ComposableLambdaImpl ranks by its wrapped `_block` closure's source arity:
/// its invoke family serves every arity, yet arity-keyed overloads must bind.
pub fn composableLambdaBlockArity(self: *VmHost, v: *const Value) ?struct { n: u8, authoritative: bool } {
    if (v.* != .Instance) return null;
    const g = v.Instance.borrow();
    defer g.deinit();
    {
        const cg = g.get().class.borrow();
        defer cg.deinit();
        if (!std.mem.eql(u8, cg.get().fqn, "androidx.compose.runtime.internal.ComposableLambdaImpl")) return null;
    }
    const blk = g.get().get("_block") orelse return null;
    if (blk != .IrClosure) return null;
    const info = self.closures.get(@intCast(blk.IrClosure.asPtr().id)) orelse return null;
    const up = closureUserParamsChecked(self, info);
    const n = std.math.cast(u8, up.n) orelse return null;
    return .{ .n = n, .authoritative = up.stripped };
}

/// `ArgShape` for one runtime value; the positional path leaves `named` null.
fn shapeOfValue(self: *VmHost, v: *const Value) applicability.ArgShape {
    var arity_authoritative = false;
    const arity: ?u8 = switch (v.*) {
        .IrClosure => |c| blk: {
            const info = self.closures.get(c.asPtr().id) orelse break :blk null;
            const up = closureUserParamsChecked(self, info);
            arity_authoritative = up.stripped;
            break :blk std.math.cast(u8, up.n);
        },
                .Class => 0,
        .Instance => blk: {
            const cli = composableLambdaBlockArity(self, v) orelse break :blk null;
            arity_authoritative = cli.authoritative;
            break :blk cli.n;
        },
        else => null,
    };
    return .{
        .runtime_class = overload_match.runtimeHead(v),
        .is_null = v.* == .Null,
        // A ComposableLambdaImpl wrap ranks as a lambda, binding a sink param across
        // defaulted middles.
        .is_lambda = valueIsCallable(v) or (v.* == .Instance and arity != null),
        .lambda_arity = arity,
        .lambda_is_literal = arity_authoritative,
        .func_typed = std.mem.startsWith(u8, v.typeFqn(), "kotlin.Function"),
        .value = @ptrCast(v),
    };
}

fn applicRefineCb(ctx: *anyopaque, param_ty: *const TypeRef, value: *const anyopaque) ?i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const v: *const Value = @ptrCast(@alignCast(value));
    return overload_match.refineByDeclaredArgs(self, param_ty, v);
}

/// `ApplicabilityScope.identity_conflict`: the exact-name overload tier rejects
/// a same-simple-name argument from a different package.
fn applicIdentityConflictCb(ctx: *anyopaque, param_ty: *const TypeRef, value: *const anyopaque) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const v: *const Value = @ptrCast(@alignCast(value));
    return overload_match.crossPackageIdentityConflict(self, param_ty, v);
}

fn applicExactHeadCb(ctx: *anyopaque, param_head: []const u8, arg_head: []const u8) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const key = host_call_member.mangledClassKeyOf(self, param_head) orelse return false;
    return std.mem.eql(u8, key, arg_head);
}

/// `ApplicabilityScope.subtype`: instance-supertype BFS returning the match
/// depth, null when the value is not an instance or never reaches `target`.
fn applicSubtypeCb(ctx: *anyopaque, value: *const anyopaque, target: []const u8) ?i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const arg: *const Value = @ptrCast(@alignCast(value));
    const strace = if (runtime.envOnce("KLIO_SUBTYPE_TRACE")) |w| (std.mem.indexOf(u8, target, w) != null) else false;
    if (arg.* != .Instance) {
        if (strace) std.debug.print("[sub] target={s} arg-tag={s} -> null\n", .{ target, @tagName(std.meta.activeTag(arg.*)) });
        return null;
    }
    if (strace) std.debug.print("[sub] target={s} head={s}\n", .{ target, overload_match.runtimeHead(arg) });
    var queue: std.ArrayList(QItem) = .empty;
    defer queue.deinit(self.allocator);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(self.allocator);
    queue.append(self.allocator, .{ .name = overload_match.runtimeHead(arg), .depth = 0 }) catch return null;
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
        const cur_key = host_call_member.mangledClassKeyOf(self, cur.name) orelse cur.name;
        if (host_call_member.classHeadsMatch(self, cur.name, target)) {
            return cur.depth;
        }
        const cg = self.classes.borrow();
        defer cg.deinit();
        // A dotted supertype ascends through its mangled entry.
        if (cg.get().get(cur.name) orelse cg.get().get(cur_key)) |def_ref| {
            const dg = def_ref.borrow();
            defer dg.deinit();
            for (dg.get().supertype_names) |sup| {
                queue.append(self.allocator, .{ .name = sup, .depth = cur.depth + 1 }) catch return null;
            }
        }
    }
    return null;
}

/// Parameters of a candidate with every bare bounded type parameter replaced by
/// its bound: `fun <S : B> foo(s: S)` is applicable to a `B`, not to a `C`.
threadlocal var bounded_params_cache: ?std.AutoHashMap(u32, []const ir.Param) = null;
threadlocal var bounded_params_gen: u32 = 0;

/// Entries key on a bare `FuncId` and point into module-owned type names, so
/// one dangles past its program; the cache rides the dispatch-cache generation.
fn boundedParamsCache() *std.AutoHashMap(u32, []const ir.Param) {
    const gen = host_call_member.dispatchCacheGen();
    if (bounded_params_cache == null) {
        bounded_params_cache = std.AutoHashMap(u32, []const ir.Param).init(std.heap.page_allocator);
    } else if (bounded_params_gen != gen) {
        var it = bounded_params_cache.?.valueIterator();
        while (it.next()) |v| std.heap.page_allocator.free(v.*);
        bounded_params_cache.?.clearRetainingCapacity();
    }
    bounded_params_gen = gen;
    return &bounded_params_cache.?;
}

pub fn boundedParams(module: *const Module, cand: FuncId, f: *const Func) ?[]const ir.Param {
    const bounds = module.registry.func_type_param_bounds.get(cand) orelse return null;
    if (bounds.len == 0) return null;
    const cache = boundedParamsCache();
    if (cache.get(cand.int())) |cached| return cached;
    var any = false;
    for (f.params) |*p| {
        var head = std.mem.trimEnd(u8, p.ty.name, "?");
        if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
        for (bounds) |b| {
            if (std.mem.eql(u8, b.param, head) and !std.mem.eql(u8, applicability.simpleName(b.bound), "Any")) any = true;
        }
    }
    if (!any) return null;
    const a = std.heap.page_allocator;
    const out = a.alloc(ir.Param, f.params.len) catch return null;
    for (f.params, out) |*p, *o| {
        o.* = p.*;
        var head = std.mem.trimEnd(u8, p.ty.name, "?");
        if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
        for (bounds) |b| {
            if (!std.mem.eql(u8, b.param, head)) continue;
            var bn = std.mem.trim(u8, b.bound, " ");
            if (std.mem.indexOfScalar(u8, bn, '<')) |lt| bn = bn[0..lt];
            const bn_nullable = std.mem.endsWith(u8, bn, "?");
            bn = std.mem.trimEnd(u8, bn, "?");
            if (std.mem.eql(u8, applicability.simpleName(bn), "Any")) continue;
            o.ty = .{ .name = bn, .nullable = p.ty.nullable or bn_nullable, .args = &.{} };
        }
    }
    cache.put(cand.int(), out) catch {};
    return out;
}

fn sigViewOfFunc(self: *VmHost, module: *const Module, cand: FuncId, argc: usize) ?applicability.SigView {
    const f = funcAt(module, cand) orelse return null;
    return .{
        .params = boundedParams(module, cand, f) orelse f.params,
        .defaults = funcDefaults(self, cand),
        .has_body = executableForm(self, module, cand, argc),
        .low_priority = f.low_priority,
    };
}

/// Applicability points for one positional candidate, null when it does not bind.
fn positionalPoints(self: *VmHost, module: *const Module, cand: FuncId, shapes: []const applicability.ArgShape, scope: applicability.ApplicabilityScope) ?i32 {
    const sig = sigViewOfFunc(self, module, cand, shapes.len) orelse return null;
    const sc = applicability.applicable(&sig, shapes, scope);
    if (sc == null and runtime.envOnce("KLIO_APPLIC_TRACE") != null) {
        std.debug.print("[pp-null] cand={d} named={} nshapes={d} shape0named={s} shape0class={s}\n", .{
            cand.int(),
            scope.named,
            shapes.len,
            if (shapes.len != 0) (shapes[0].named orelse "<pos>") else "-",
            if (shapes.len != 0) (shapes[0].runtime_class orelse "<none>") else "-",
        });
    }
    return (sc orelse return null).points;
}

fn runtimeApplicabilityScope(self: *VmHost) applicability.ApplicabilityScope {
    return .{
        .ctx = @ptrCast(self),
        .refine = applicRefineCb,
        .subtype = applicSubtypeCb,
        .identity_conflict = applicIdentityConflictCb,
        .exact_head = applicExactHeadCb,
    };
}

/// Score one runtime value against a declared parameter, for paths with no IR `Func`.
pub fn runtimeParamPoints(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) ?i32 {
    const params = [_]ir.Param{.{
        .name = "value",
        .ty = param_ty.*,
        .default = null,
    }};
    const shapes = [_]applicability.ArgShape{shapeOfValue(self, arg)};
    const sig = applicability.SigView{ .params = &params };
    const score = applicability.applicable(&sig, &shapes, runtimeApplicabilityScope(self)) orelse return null;
    return score.points;
}

/// Score a complete runtime call against one declaration, as dispatch does.
pub fn runtimeFuncApplicability(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    cand: FuncId,
    args: []const Value,
) Allocator.Error!?applicability.Score {
    // Safety builds 0xAA-fill the whole declared array per entry; >6 args heap.
    if (args.len <= 6) {
        var shapes_buf: [6]applicability.ArgShape = undefined;
        const shapes = shapes_buf[0..args.len];
        for (args, 0..) |*arg, i| shapes[i] = shapeOfValue(self, arg);
        const sig = sigViewOfFunc(self, module, cand, args.len) orelse return null;
        return applicability.applicable(&sig, shapes, runtimeApplicabilityScope(self));
    }
    const shapes = try allocator.alloc(applicability.ArgShape, args.len);
    defer allocator.free(shapes);
    for (args, 0..) |*arg, i| shapes[i] = shapeOfValue(self, arg);
    const sig = sigViewOfFunc(self, module, cand, args.len) orelse return null;
    return applicability.applicable(&sig, shapes, runtimeApplicabilityScope(self));
}

/// Declared arity of a function-type reference: `Function2` is 2; an arrow form
/// counts its generic args less the trailing return type. Null when unknown.
fn fnTypeArity(ty: *const TypeRef) ?usize {
    const n = applicability.simpleName(ty.name);
    if (std.mem.startsWith(u8, n, "Function")) {
        const digits = n["Function".len..];
        if (digits.len != 0) {
            if (std.fmt.parseInt(usize, digits, 10)) |k| {
                return k;
            } else |_| {}
        }
    }
    if (std.mem.indexOf(u8, ty.name, "->") != null and ty.args.len != 0) {
        return ty.args.len - 1;
    }
    return null;
}

pub fn callableDeclaredArity(self: *VmHost, v: *const Value) ?usize {
    return switch (v.*) {
        .IrClosure => |c| if (self.closures.get(c.asPtr().id)) |info| info.n_params else null,
        .Instance => if (composableLambdaBlockArity(self, v)) |cli| cli.n else null,
        else => null,
    };
}

/// Whether `cand` sits outside the baked target's overload set: another package,
/// against a bodyless target with no signature to score.
fn crossPackageNonCandidate(module: *const Module, f: *const Func, cand: FuncId) bool {
    if (f.hasBody()) return false;
    const cf = funcAt(module, cand) orelse return false;
    return !std.mem.eql(u8, cf.package, f.package);
}

fn pickOverload(self: *VmHost, module: *const Module, func: FuncId, args: []const Value) ?FuncId {
    const f = funcAt(module, func) orelse return null;
    // A pack side-module's simple-name index is partial while the overload set
    // lives program-wide, so re-enter through the main module to re-resolve.
    if (module.funcsBySimpleName(f.name).len < 2) {
        const mg = self.module.borrow();
        defer mg.deinit();
        const main_mod = mg.get();
        if (@intFromPtr(main_mod) != @intFromPtr(module) and
            main_mod.funcsBySimpleName(f.name).len >= 2 and
            main_mod.funcById(func) != null)
        {
            return pickOverloadInner(self, main_mod, func, args);
        }
        return null;
    }
    return pickOverloadInner(self, module, func, args);
}

fn pickOverloadInner(self: *VmHost, module: *const Module, func: FuncId, args: []const Value) ?FuncId {
    const f = funcAt(module, func) orelse return null;
    // A statically-bound instance method is not in this set: lowering resolved it by scope.
    if (f.kind == .instance_method or f.kind == .member_extension) return null;
    const name = f.name;
    const candidates = module.funcsBySimpleName(name);
    if (candidates.len < 2) return null;

    // Safety builds 0xAA-fill the whole declared array per entry; >6 args heap.
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
    for (args, 0..) |*a, i| shapes[i] = shapeOfValue(self, a);
    const scope = applicability.ApplicabilityScope{
        .ctx = @ptrCast(self),
        .refine = applicRefineCb,
        .subtype = applicSubtypeCb,
        .identity_conflict = applicIdentityConflictCb,
        .exact_head = applicExactHeadCb,
        .erased_integer_widths = true,
    };

    // A `@Deprecated(level = ERROR|HIDDEN)` or `@LowPriorityInOverloadResolution`
    // overload ranks apart: an ordinary one wins whenever one applies.
    var best_ord: ?FuncId = null;
    var best_ord_score: i32 = std.math.minInt(i32);
    var best_low: ?FuncId = null;
    var best_low_score: i32 = std.math.minInt(i32);
    if (positionalPoints(self, module, func, shapes, scope)) |s| {
        if (f.low_priority) {
            best_low = func;
            best_low_score = s;
        } else {
            best_ord = func;
            best_ord_score = s;
        }
    }
    if (runtime.envOnce("KLIO_PICK_TRACE")) |w| if (std.mem.eql(u8, w, name)) {
        std.debug.print("[pick] {s} base=#{d} base_score={?} cands={d}\n", .{ name, func.int(), positionalPoints(self, module, func, shapes, scope), candidates.len });
    };
    for (candidates) |cand| {
        if (cand.int() == func.int()) continue;
        if (crossPackageNonCandidate(module, f, cand)) continue;
        const total_dbg = positionalPoints(self, module, cand, shapes, scope);
        if (runtime.envOnce("KLIO_PICK_TRACE")) |w| if (std.mem.eql(u8, w, name)) {
            std.debug.print("[pick]   cand=#{d} score={?}\n", .{ cand.int(), total_dbg });
        };
        const total = total_dbg orelse continue;
        const is_low = if (funcAt(module, cand)) |cf| cf.low_priority else false;
        if (is_low) {
            if (best_low == null or total > best_low_score) {
                best_low = cand;
                best_low_score = total;
            }
        } else if (best_ord == null or total > best_ord_score) {
            best_ord = cand;
            best_ord_score = total;
        }
    }

    return best_ord orelse best_low;
}

const isFunctionType = root.isFunctionType;
const valueIsCallable = root.valueIsCallable;
const primitiveParamAccepts = root.primitiveParamAccepts;
const extDeclRecvIsUserClass = root.extDeclRecvIsUserClass;
const valueIsBuiltin = root.valueIsBuiltin;

/// Fast-path plan for `func`, cached on the `Func`: `1` is ineligible,
/// `n_params + 2` eligible, OR-ed with `FAST_CALL_EXT_FLAG` for a
/// receiver-carrying body and `FAST_CALL_AMBIG_FLAG` when the site settles the
/// pick. Bodyless, native, inline, vararg, defaulted and same-arity-sibling no.
pub fn fastCallPlan(self: *VmHost, module: *const Module, func: FuncId) u16 {
    const fp_trace = if (runtime.envOnce("KLIO_FASTPLAN_TRACE")) |w| blk: {
        const f0 = funcAt(module, func) orelse break :blk false;
        break :blk std.mem.indexOf(u8, f0.name, w) != null;
    } else false;
    const f = funcAt(module, func) orelse return 1;
    if (!f.hasBody()) {
        if (fp_trace) std.debug.print("[fastplan] {s}: no body\n", .{f.name});
        return 1;
    }
    // Inline bodies splice, so a runtime call to one keeps the full path.
    if (f.is_inline) {
        if (fp_trace) std.debug.print("[fastplan] {s}: inline\n", .{f.name});
        return 1;
    }
    // A `@Composable` function needs no exclusion: composition is already in the
    // body and `flatPlainCallOpen` publishes the threaded `$composer`.
    if (f.params.len > 253) {
        if (fp_trace) std.debug.print("[fastplan] {s}: too many params\n", .{f.name});
        return 1;
    }
    if (lastIsVararg(f.params)) {
        if (fp_trace) std.debug.print("[fastplan] {s}: trailing vararg\n", .{f.name});
        return 1;
    }
    if (hasNonFinalVararg(f.params)) {
        if (fp_trace) std.debug.print("[fastplan] {s}: non-final vararg\n", .{f.name});
        return 1;
    }
    if (funcDefaults(self, func) != null) {
        if (fp_trace) std.debug.print("[fastplan] {s}: has defaults\n", .{f.name});
        return 1;
    }
    if (resolvedNativeForm(self, func) != null) {
        if (fp_trace) std.debug.print("[fastplan] {s}: native form\n", .{f.name});
        return 1;
    }
    // Only a same-arity sibling competes. A pack side-module's index is partial,
    // so consult main before calling a name sibling-free.
    const same_name = blk: {
        const local = module.funcsBySimpleName(f.name);
        if (local.len >= 2) break :blk local;
        const mg2 = self.module.borrow();
        defer mg2.deinit();
        const global = mg2.get().funcsBySimpleName(f.name);
        break :blk if (global.len > local.len) global else local;
    };
    if (same_name.len > 1) {
        var arity_peers: usize = 0;
        for (same_name) |c| {
            const cf = funcAt(module, c) orelse blk2: {
                const mg3 = self.module.borrow();
                defer mg3.deinit();
                break :blk2 mg3.get().funcById(c) orelse continue;
            };
            if (cf.params.len == f.params.len) arity_peers += 1;
            // A defaulted or variadic peer accepts a range of counts, so it competes.
            if (cf.params.len != f.params.len and peerSpansArity(self, c, cf, f.params.len)) arity_peers += 1;
        }
        if (arity_peers != 1) {
            // Same name and arity: only the call site's scope settles the winner.
            if (fp_trace) std.debug.print("[fastplan] {s}: {d} same-arity peers of {d} candidates -> site decides\n", .{ f.name, arity_peers, same_name.len });
            const b = @as(u16, @intCast(f.params.len)) + 2;
            const ext: u16 = if (paramIsThis(f.params) or f.has_receiver_param) ir.FAST_CALL_EXT_FLAG else 0;
            return b | ext | ir.FAST_CALL_AMBIG_FLAG;
        }
    }
    // A non-inline function carries no reified binding, since reified requires inline.
    const base = @as(u16, @intCast(f.params.len)) + 2;
    // The flag tells the call site to seed the caller's `this` as an enclosing receiver.
    if (paramIsThis(f.params) or f.has_receiver_param)
        return base | ir.FAST_CALL_EXT_FLAG;
    return base;
}

/// Whether the baked target of an ambiguous-by-arity call is what scope picks
/// from `caller_pkg`/`caller_file`; tier ranking answers as the re-pick would.
pub fn fuseSiteBinds(self: *VmHost, module: *const Module, func: FuncId, caller_pkg: []const u8, caller_file: ?ir.FileId) bool {
    const f = funcAt(module, func) orelse return false;
    const file = caller_file orelse ir.FileId.from(std.math.maxInt(u32));
    const own = module.scopeTier(f.fqn, f.package, f.name, caller_pkg, file);
    if (own == ir.Module.other_package_tier) return false;
    // The executing module's name index can be partial, so judge peers against the widest.
    const peers = blk: {
        const local = module.funcsBySimpleName(f.name);
        if (local.len >= 2) break :blk local;
        const mg = self.module.borrow();
        defer mg.deinit();
        const global = mg.get().funcsBySimpleName(f.name);
        break :blk if (global.len > local.len) global else local;
    };
    for (peers) |c| {
        if (c.int() == func.int()) continue;
        const cf = funcAt(module, c) orelse blk2: {
            const mg2 = self.module.borrow();
            defer mg2.deinit();
            break :blk2 mg2.get().funcById(c) orelse continue;
        };
        if (cf.params.len != f.params.len and !peerSpansArity(self, c, cf, f.params.len)) continue;
        // A peer at the same or better tier means scope does not settle it.
        if (module.scopeTier(cf.fqn, cf.package, cf.name, caller_pkg, file) <= own) return false;
    }
    return true;
}

/// Whether a same-named candidate accepts `n_args` despite a different declared
/// parameter count: a vararg tail or a default makes its arity a range.
fn peerSpansArity(self: *VmHost, id: FuncId, cf: *const ir.Func, n_args: usize) bool {
    if (lastIsVararg(cf.params) and n_args >= cf.params.len -| 1) return true;
    if (funcDefaults(self, id) != null and n_args <= cf.params.len) return true;
    for (cf.params) |*p| {
        if (p.has_default and n_args <= cf.params.len) return true;
    }
    return false;
}

/// Run the body with `args_list` transferred as the frame's params, no copy.
/// Eligibility rules out re-resolution, extension push, reified and defaults.
pub fn callFuncFast(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args_list: std.ArrayList(Value)) Allocator.Error!EvalResult {
    const f = funcAt(module, func).?;
    const pushed = flatPlainCallOpen(self, f, args_list.items);
    defer if (pushed) flatCallClosed(self);
    return ir.eval.evalWith(VmHost, allocator, module, f, args_list, self);
}

/// Host-entry effects of a flat plain call: a `@Composable` publishes its
/// threaded `$composer` as ambient. Returns whether the close must pop it.
pub fn flatPlainCallOpen(self: *VmHost, f: *const ir.Func, args: []const Value) bool {
    _ = self;
    if (compose.threadedComposerArgFor(f.fqn, f.params, args)) |c| {
        compose.pushComposer(c);
        return true;
    }
    return false;
}

/// Close hook for every prepare that pushed an ambient composer.
fn flatCallClosed(self: *VmHost) void {
    _ = self;
    compose.popComposer();
}

/// Trailing-lambda syntax bit for the next `callFunc` bind, set by the `Call`
/// exec: Kotlin binds it to the last parameter regardless of arity fit.
threadlocal var trailing_lambda_call: bool = false;

pub fn setTrailingLambdaCall(on: bool) void {
    trailing_lambda_call = on;
}

/// Receiver-formed bodyless redirects on the dispatch stack, as (fid, receiver
/// identity) pairs. Overflow entries drop and the guard cannot fire for them.
threadlocal var bodyless_active: [32]struct { fid: u32, ident: u64 } = undefined;
threadlocal var bodyless_active_len: usize = 0;

fn ownerIsFunInterface(self: *VmHost, class_name: []const u8) bool {
    const g = self.classes.borrow();
    defer g.deinit();
    const d = g.get().get(class_name) orelse return false;
    const dg = d.borrow();
    defer dg.deinit();
    return dg.get().is_fun_interface;
}

/// Serve a bodyless member-extension of a `fun interface` from the SAM lambda on
/// the enclosing tower: the innermost fitting callable runs on `args_in[0]`.
fn samLambdaOnTower(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, f: *const ir.Func, args_in: []const Value) Allocator.Error!?EvalResult {
    if (f.kind != .member_extension) return null;
    const owner = module.registry.member_ext_owner_class.get(func) orelse return null;
    if (!ownerIsFunInterface(self, owner)) return null;
    const want = args_in.len - 1;
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    for (entries) |e| {
        const arity: usize = switch (e.v) {
            .IrClosure => |c| blk: {
                const info = self.closures.get(@intCast(c.asPtr().id)) orelse continue;
                break :blk info.n_params;
            },
            else => continue,
        };
        if (arity != want) continue;
        return try @import("host_call_value.zig").callValueWithThis(self, allocator, &e.v, &args_in[0], args_in[1..], &.{});
    }
    return null;
}

fn bodylessRedirectActive(func: FuncId, ident: u64) bool {
    for (bodyless_active[0..bodyless_active_len]) |e| {
        if (e.fid == func.int() and e.ident == ident) return true;
    }
    return false;
}

fn bodylessRedirectPush(func: FuncId, ident: u64) void {
    if (bodyless_active_len < bodyless_active.len) {
        bodyless_active[bodyless_active_len] = .{ .fid = @intCast(func.int()), .ident = ident };
        bodyless_active_len += 1;
    }
}

fn bodylessRedirectPop() void {
    if (bodyless_active_len > 0) bodyless_active_len -= 1;
}

fn missingActual(allocator: Allocator, f: *const Func) EvalResult {
    return .{ .err = typeErr(
        allocator,
        "`{s}` is an `expect` with no `actual` on this platform, and no klio intrinsic backs it. " ++
            "Run `klio check --unimplemented <file>` to list every unimplemented declaration this program reaches.",
        .{f.fqn},
    ) };
}

/// Direct-mapped memo of which parameters take a `fun interface`, a bitmask over the
/// first 32. Keys are reusable `*const Func` addresses, so entries ride `gen`.
const SamMaskEntry = struct { func_p: usize = 0, mask: u32 = 0, valid: bool = false, gen: u32 = 0 };
threadlocal var sam_mask_cache: [1024]SamMaskEntry = @splat(.{});

fn samParamMask(self: *VmHost, func: *const ir.Func) u32 {
    const key = @intFromPtr(func);
    const gen = host_call_member.dispatchCacheGen();
    const slot = &sam_mask_cache[(key >> 4) % sam_mask_cache.len];
    if (slot.valid and slot.func_p == key and slot.gen == gen) return slot.mask;
    var mask: u32 = 0;
    for (func.params, 0..) |*p, i| {
        if (i >= 32) break;
        if (p.is_vararg) continue;
        if (host_instances.paramTypeIsFunInterface(self, p.ty.name)) mask |= @as(u32, 1) << @intCast(i);
    }
    slot.* = .{ .func_p = key, .mask = mask, .valid = true, .gen = gen };
    return mask;
}

/// Kotlin converts a lambda to a `fun interface` at the call boundary, so the callee's
/// parameter holds an interface instance. Converts in place at activation setup, the
/// one point every call shape passes; the argument's reference moves into the wrapper.
pub fn samConvertActivationArgs(self: *VmHost, allocator: Allocator, func: *const ir.Func, args: []Value) Allocator.Error!void {
    const mask = samParamMask(self, func);
    if (mask == 0) return;
    for (args, 0..) |*a, i| {
        if (i >= 32 or a.* != .IrClosure) continue;
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        if (try host_instances.samWrapForParamType(self, allocator, a, func.params[i].ty.name)) |w| a.* = w;
    }
}

pub fn callFunc(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args_in: []const Value) Allocator.Error!EvalResult {
    const trailing_syntax = trailing_lambda_call;
    trailing_lambda_call = false;
    const f = funcAt(module, func) orelse
        return .{ .err = typeErr(allocator, "unknown FuncId {d}", .{func.int()}) };

    if (trace.enabled(f.name)) {
        trace.emit("call_func {s} fid={d} fqn={s} argc={d}", .{ f.name, func.int(), f.fqn, args_in.len });
    }

    for (f.params, 0..) |*p, i| {
        if (i >= args_in.len) break;
        narrowIntListArg(&p.ty, &args_in[i]);
    }

    linkAuditCheck(self, module, func, f, args_in);

    // A non-final vararg routes through the named binder unless already pre-packed.
    if (hasNonFinalVararg(f.params) and f.hasBody()) {
        const prepacked = blk: {
            // A short prefix counts as pre-packed when its vararg slot holds an
            // Array: the named binder hands back that shape, so re-routing loops.
            if (args_in.len > f.params.len) break :blk false;
            for (f.params, 0..) |*p, i| {
                if (p.is_vararg) break :blk i < args_in.len and args_in[i] == .Array;
            }
            break :blk false;
        };
        if (!prepacked) {
            const no_names = try allocator.alloc(?[]const u8, args_in.len);
            defer allocator.free(no_names);
            @memset(no_names, null);
            return callFuncNamed(self, allocator, module, func, args_in, no_names);
        }
    }

    // An abstract member-extension of a `fun interface` called with a lambda in the
    // dispatch-receiver position: the lambda is the method body, and only the
    // extension receiver rides in `args_in[0]`.
    if (!f.hasBody() and args_in.len != 0) {
        if (try samLambdaOnTower(self, allocator, module, func, f, args_in)) |r| return r;
    }

    // A bodyless declaration with its own linked host symbol dispatches that
    // symbol; the sibling redirect below is keyed by simple name alone.
    if (!f.hasBody()) {
        if (resolvedNativeForm(self, func)) |intrinsic| {
            if (trace.enabled(f.name)) {
                trace.emit("map=bodyless_native_own name={s} fqn={s}", .{ f.name, f.fqn });
            }
            // A slot-exact Array argument passes through as given: unpacking it is
            // ambiguous.
            return dispatchIntrinsic(self, allocator, f.fqn, intrinsic, args_in);
        }
    }

    // Bodyless `expect` or header-only decl: `linkResolvedForms` settled its
    // body siblings in declaration order, and the first whose arity fits runs.
    if (!f.hasBody()) {
        const target: ?FuncId = blk: {
            const g = self.prog.borrow();
            defer g.deinit();
            break :blk g.get().resolvedRedirectTargetShaped(module, func, args_in);
        };
        if (target) |cand| {
            // Re-entrancy guard: an abstract member re-entered through its own redirect
            // on the same receiver would recurse forever; receiverless headers are exempt.
            const has_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
            const recv_ident: u64 = if (has_this and args_in.len != 0) blk: {
                const v = args_in[0];
                break :blk switch (v) {
                    .Instance => |i| @intFromPtr(i.cell),
                    .IrClosure => |c| @as(u64, @intCast(c.asPtr().id)),
                    .Int => |x| @as(u64, @bitCast(@as(i64, x))),
                    .Long => |x| @as(u64, @bitCast(x)),
                    else => @as(u64, @intFromEnum(std.meta.activeTag(v))),
                };
            } else 0;
            if (has_this and bodylessRedirectActive(func, recv_ident)) {
                return .{ .err = typeErr(allocator, "abstract `{s}` has no implementation applicable to this receiver", .{f.name}) };
            }
            if (trace.enabled(f.name)) {
                const g = funcAt(module, cand);
                trace.emit("map=bodyless_sibling name={s} fqn={s}", .{ f.name, if (g) |gg| gg.fqn else "?" });
            }
            if (has_this) {
                bodylessRedirectPush(func, recv_ident);
                defer bodylessRedirectPop();
                return callFunc(self, allocator, module, cand, args_in);
            }
            return callFunc(self, allocator, module, cand, args_in);
        }
    }

    // One executable form per symbol: a linked native binding wins over the lowered
    // shim body.
    if (resolvedNativeForm(self, func)) |intrinsic| {
        if (!f.hasBody() and trace.enabled(f.name)) {
            trace.emit("map=bodyless_native name={s} fqn={s}", .{ f.name, f.fqn });
        }
        return dispatchIntrinsic(self, allocator, f.fqn, intrinsic, args_in);
    }

    // A bodyless declaration the link could not settle. A receiver-formed one is a
    // member-form intrinsic's header (`Array<T>.fill` has no package FQN), so it
    // dispatches through the member walk; a miss returns Unit, as does a receiverless one.
    if (!f.hasBody()) {
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this") and args_in.len != 0) {
            if (trace.enabled(f.name)) {
                trace.emit("map=bodyless_member name={s} fqn={s}", .{ f.name, f.fqn });
            }
            const r = try host_call_member.callMember(self, allocator, &args_in[0], f.name, args_in[1..]);
            if (r == .err and r.err == .Unimplemented) {
                const m = r.err.Unimplemented;
                if (std.mem.indexOf(u8, m, "Vm::call_member") != null) {
                    if (runtime.freeScratch()) allocator.free(m);
                    if (f.is_expect) return missingActual(allocator, f);
                    return .{ .ok = .Unit };
                }
            }
            return r;
        }
        if (f.is_expect) return missingActual(allocator, f);
        return .{ .ok = .Unit };
    }

    // A bare call bakes one FuncId with no argument-type information, so it can bind
    // the wrong specialization: on a primitive mismatch a same-FQN intrinsic takes it.
    if (f.hasBody() and args_in.len != 0) {
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
                return dispatchIntrinsic(self, allocator, f.fqn, intrinsic, args_in);
            }
        }
    }

    var args = try argsFromSlice(allocator, args_in);
    defer args.deinit(allocator);

    // Kotlin binds a trailing lambda to the last parameter: with fewer args than
    // params, the final callable takes it and the gap params take their defaults.
    if (args.items.len < f.params.len and args.items.len != 0) {
        const last_is_fn = f.params.len > 0 and isFunctionType(&f.params[f.params.len - 1].ty);
        const trailing_is_callable = valueIsCallable(&args.items[args.items.len - 1]) or
            (args.items[args.items.len - 1] == .Instance and
                composableLambdaBlockArity(self, &args.items[args.items.len - 1]) != null);
        if (last_is_fn and trailing_is_callable) {
            const lead = args.items.len - 1;
            const last_param = f.params.len - 1;
            // The syntax bit does not survive lowering, so gate the shift on fit:
            // a callable matching the positional slot's arity is a positional bind.
            const positional_fits = lead < f.params.len and
                isFunctionType(&f.params[lead].ty) and blk: {
                const pa = fnTypeArity(&f.params[lead].ty) orelse break :blk true;
                const ca = callableDeclaredArity(self, &args.items[args.items.len - 1]) orelse break :blk true;
                break :blk pa == ca;
            };
            if (lead < last_param and (trailing_syntax or !positional_fits)) {
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
                            vmhost.emitPath(allocator, "call_func_default_thunk", dfunc.fqn, dfid, null, args.items);
                            const r = try ir.eval.evalWith(VmHost, allocator, module, dfunc, thunk_args, self);
                            switch (r) {
                                .ok => |v| try args.append(allocator, v),
                                .err => |e| return .{ .err = e },
                            }
                            _ = &thunk_args;
                        } else if (f.params[idx].is_vararg) {
                            // An omitted vararg is the empty array, not an element.
                            const empty: std.ArrayList(Value) = .empty;
                            try args.append(allocator, try packVarargArray(allocator, f.params[idx].ty.name, empty));
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
                    // A thunk in an extension body records `this` as capture[0], not a
                    // param.
                    var captures: std.ArrayList(Value) = .empty;
                    if (args.items.len != 0) try captures.append(allocator, args.items[0]);
                    var thunk_args = try argsFromSlice(allocator, args.items);
                    vmhost.emitPath(allocator, "call_func_default_thunk", dfunc.fqn, dfid, null, args.items);
                    const r = try ir.eval.evalWithCaptures(VmHost, allocator, module, dfunc, thunk_args, captures, self);
                    _ = &thunk_args;
                    switch (r) {
                        .ok => |v| try args.append(allocator, v),
                        .err => |e| return .{ .err = e },
                    }
                } else if (f.params[idx].is_vararg) {
                    // An omitted vararg is the empty array, not an element.
                    const empty: std.ArrayList(Value) = .empty;
                    try args.append(allocator, try packVarargArray(allocator, f.params[idx].ty.name, empty));
                } else {
                    try args.append(allocator, .Null);
                }
            }
        }
    }

    var packed_args = try packVarargArgs(allocator, f, &args);
    // `packVarargArgs` consumes or returns `args`, so disarm the outer defer.
    args = .empty;
    // Compose ABI completion: a pairless call left its ($composer, $changed) tail Null.
    if (f.params.len >= 2 and
        std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed") and
        std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer") and
        packed_args.items.len == f.params.len and
        packed_args.items[f.params.len - 2] == .Null)
    {
        if (compose.currentComposer()) |c| {
            packed_args.items[f.params.len - 2] = c;
            packed_args.items[f.params.len - 1] = .{ .Int = 0 };
        }
    }
    vmhost.emitPath(allocator, "call_func", f.fqn, func, null, args_in);
    return composableEval(self, allocator, module, f, packed_args);
}

/// Free the packed argument list's backing without running the body. Elements
/// are borrowed from the caller's `args_in`, so only the list itself is freed.
fn discardArgs(allocator: Allocator, packed_args: std.ArrayList(Value)) void {
    var list = packed_args;
    list.deinit(allocator);
}

/// `KLIO_MISS_TRACE`, resolved once: the env store lookup takes a global mutex.
var hcf_miss_trace_state: u8 = 0;
var hcf_miss_trace_want: []const u8 = "";
fn hcfMissTraceEnv() ?[]const u8 {
    if (hcf_miss_trace_state == 0) {
        if (runtime.envOnce("KLIO_MISS_TRACE")) |w| {
            hcf_miss_trace_want = w;
            hcf_miss_trace_state = 2;
        } else {
            hcf_miss_trace_state = 1;
        }
    }
    return if (hcf_miss_trace_state == 2) hcf_miss_trace_want else null;
}

fn composableEval(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    f: *const Func,
    packed_args: std.ArrayList(Value),
) Allocator.Error!EvalResult {
    if (hcfMissTraceEnv()) |w| {
        if (std.mem.eql(u8, w, f.name)) {
            std.debug.print("[fn-entry] {s}#{d} caller={s}@{?any}:", .{ f.fqn, f.id.int(), if (ir.eval.currentFrameFunc()) |cf| cf.fqn else "<none>", ir.eval.currentCallSiteSpan() });
            for (f.params, 0..) |p, i| {
                if (i >= packed_args.items.len) break;
                const v = &packed_args.items[i];
                std.debug.print(" {s}={s}", .{ p.name, @tagName(std.meta.activeTag(v.*)) });
                if (v.* == .Int) std.debug.print(":{d}", .{v.Int});
                if (v.* == .Long) std.debug.print(":{d}", .{v.Long});
                if (v.* == .ULong) std.debug.print(":{x}", .{v.ULong});
                if (v.* == .Instance) {
                    const ig = v.Instance.borrow();
                    const cg = ig.get().class.borrow();
                    std.debug.print(":{s}", .{cg.get().name});
                    cg.deinit();
                    ig.deinit();
                }
            }
            std.debug.print("\n", .{});
        }
    }
    // Publish the threaded `$composer` as ambient: a `@Composable` getter reached from
    // here has no composer param and reads this stack via `__compose_currentComposer`.
    if (compose.threadedComposerArgFor(f.fqn, f.params, packed_args.items)) |c| {
        compose.pushComposer(c);
        defer compose.popComposer();
        return ir.eval.evalWith(VmHost, allocator, module, f, packed_args, self);
    }
    return ir.eval.evalWith(VmHost, allocator, module, f, packed_args, self);
}

/// `SigView` for a candidate on the named path. Unlike `sigViewOfFunc`, a
/// bodyless declaration backed by a native intrinsic is selectable via `has_body`.
fn sigViewOfNamed(self: *VmHost, module: *const Module, cand: FuncId) ?applicability.SigView {
    const f = funcAt(module, cand) orelse return null;
    const selectable = f.hasBody() or resolvedNativeForm(self, cand) != null or lookupIntrinsic(self, f.fqn) != null;
    return .{
        .params = f.params,
        .defaults = funcDefaults(self, cand),
        .has_body = selectable,
        .low_priority = f.low_priority,
    };
}

/// Applicability points for one named-call candidate, null when it does not bind.
fn namedPoints(self: *VmHost, module: *const Module, cand: FuncId, shapes: []const applicability.ArgShape, scope: applicability.ApplicabilityScope) ?i32 {
    const sig = sigViewOfNamed(self, module, cand) orelse return null;
    const sc = applicability.applicable(&sig, shapes, scope) orelse return null;
    return sc.points;
}

/// Whether the candidate extension's declared receiver head names a class this
/// program knows and the value provably lacks. Unknown heads never disqualify.
fn extRecvDisprovenByValue(self: *VmHost, ty: *const TypeRef, v: *const Value) bool {
    var head = applicability.simpleName(ty.name);
    head = std.mem.trimEnd(u8, head, "?");
    if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (head.len == 0 or std.mem.eql(u8, head, "Any")) return false;
    if (std.mem.startsWith(u8, head, "Function")) return false;
    if (v.* != .Instance) return false;
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(head) == null) return false;
    }
    return !host_call_member.receiverImplementsHead(self, v, head);
}

/// Re-pick the overload for a named call: Kotlin resolves by parameter name while the
/// IR baked one FuncId by positional arity. `recv_external` says an unbaked implicit
/// receiver is in scope, so an extension can win.
pub fn pickNamedOverloadId(
    self: *VmHost,
    module: *const Module,
    func: FuncId,
    args: []const Value,
    arg_names: []const ?[]const u8,
    recv_external: bool,
) ?FuncId {
    return pickNamedOverloadIdRecv(self, module, func, args, arg_names, recv_external, null);
}

/// As `pickNamedOverloadId`, with the caller's implicit `this` when the baked target
/// is not an extension: a candidate that receiver provably lacks is excluded.
pub fn pickNamedOverloadIdRecv(
    self: *VmHost,
    module: *const Module,
    func: FuncId,
    args: []const Value,
    arg_names: []const ?[]const u8,
    recv_external: bool,
    external_recv: ?*const Value,
) ?FuncId {
    const f0 = funcAt(module, func) orelse return null;
    const candidates = module.funcsBySimpleName(f0.name);
    if (candidates.len < 2) return null;
    const baked_is_ext = paramIsThis(f0.params);

    // Safety builds 0xAA-fill the whole declared array per entry; >6 args heap.
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
    for (args, 0..) |*a, i| {
        shapes[i] = shapeOfValue(self, a);
        shapes[i].named = if (i < arg_names.len) arg_names[i] else null;
    }
    const scope = applicability.ApplicabilityScope{
        .named = true,
        .recv_external = recv_external,
        .ctx = @ptrCast(self),
        .refine = applicRefineCb,
        .subtype = applicSubtypeCb,
        .identity_conflict = applicIdentityConflictCb,
        .exact_head = applicExactHeadCb,
        .erased_integer_widths = true,
    };

    // A `@Deprecated(level = ERROR|HIDDEN)` or `@LowPriorityInOverloadResolution`
    // overload applies only when no ordinary one does, so rank the two apart.
    const pno_trace = if (hcfMissTraceEnv()) |w| std.mem.eql(u8, w, f0.name) else false;
    var best_ord: ?FuncId = null;
    var best_ord_score: i32 = std.math.minInt(i32);
    var best_low: ?FuncId = null;
    var best_low_score: i32 = std.math.minInt(i32);
    for (candidates) |cand| {
        if (!baked_is_ext) {
            if (external_recv) |rv| {
                if (funcAt(module, cand)) |cf| {
                    if (paramIsThis(cf.params) and
                        extRecvDisprovenByValue(self, &cf.params[0].ty, rv)) continue;
                }
            }
        }
        const score = namedPoints(self, module, cand, shapes, scope);
        if (pno_trace) {
            const cf0 = funcAt(module, cand);
            std.debug.print("[pno] {s} cand={d} nparams={d} score={?}\n", .{ f0.name, cand.int(), if (cf0) |cf| cf.params.len else 0, score });
        }
        const sc = score orelse continue;
        const is_low = if (funcAt(module, cand)) |cf| cf.low_priority else false;
        if (is_low) {
            if (best_low == null or sc > best_low_score) {
                best_low = cand;
                best_low_score = sc;
            }
        } else if (best_ord == null or sc > best_ord_score) {
            best_ord = cand;
            best_ord_score = sc;
        }
    }
    if (pno_trace) std.debug.print("[pno] {s} baked={d} -> best_ord={?} best_low={?}\n", .{ f0.name, func.int(), if (best_ord) |b0| b0.int() else null, if (best_low) |b0| b0.int() else null });

    return best_ord orelse best_low;
}

pub const IndexedArgsResult = union(enum) {
    ok: []Value,
    err: EvalError,
};

/// Bind source-order member arguments to the declaration ABI lowering selected.
/// The caller owns the returned slice, whose parameter zero is the receiver.
/// Omitted parameters evaluate from `defaults_from`, so an override inherits defaults.
pub fn bindFuncIndexedArgs(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    func: FuncId,
    defaults_from: FuncId,
    receiver: *const Value,
    args: []const Value,
    arg_params: []const u32,
) Allocator.Error!IndexedArgsResult {
    const f = funcAt(module, func) orelse
        return .{ .err = typeErr(allocator, "indexed-call FuncId {d} out of range", .{func.int()}) };
    if (f.params.len == 0 or arg_params.len != args.len) {
        return .{ .err = typeErr(allocator, "indexed-call argument map does not match target", .{}) };
    }

    const slots = try allocator.alloc(?Value, f.params.len);
    defer allocator.free(slots);
    for (slots) |*slot| slot.* = null;
    slots[0] = receiver.*;

    var vararg_param: ?usize = null;
    for (f.params, 0..) |param, i| if (param.is_vararg) {
        vararg_param = i;
        break;
    };
    var vararg_values: std.ArrayList(Value) = .empty;
    defer vararg_values.deinit(allocator);
    for (args, arg_params) |arg, user_index| {
        const param_index: usize = @as(usize, user_index) + 1;
        if (param_index >= slots.len) {
            return .{ .err = typeErr(allocator, "indexed-call parameter map is invalid", .{}) };
        }
        if (f.params[param_index].is_vararg) {
            try vararg_values.append(allocator, arg);
            continue;
        }
        if (slots[param_index] != null) {
            return .{ .err = typeErr(allocator, "indexed-call parameter map is invalid", .{}) };
        }
        slots[param_index] = arg;
    }
    if (vararg_param) |param_index| {
        var packed_values: std.ArrayList(Value) = .empty;
        try packed_values.appendSlice(allocator, vararg_values.items);
        slots[param_index] = try packVarargArray(allocator, f.params[param_index].ty.name, packed_values);
    }

    const defaults = funcDefaults(self, defaults_from);
    var ordered: std.ArrayList(Value) = .empty;
    defer ordered.deinit(allocator);
    for (slots, 0..) |slot, i| {
        if (slot) |value| {
            try ordered.append(allocator, value);
            continue;
        }
        const default_id: ?FuncId = if (defaults != null and i < defaults.?.len) defaults.?[i] else null;
        const id = default_id orelse
            return .{ .err = typeErr(allocator, "indexed-call omitted required parameter {d}", .{i}) };
        const default_func = funcAt(module, id) orelse
            return .{ .err = typeErr(allocator, "default-arg FuncId {d} out of range", .{id.int()}) };
        var thunk_args = try argsFromSlice(allocator, ordered.items);
        vmhost.emitPath(allocator, "call_func_indexed_thunk", default_func.fqn, id, null, ordered.items);
        const result = try ir.eval.evalWith(VmHost, allocator, module, default_func, thunk_args, self);
        _ = &thunk_args;
        switch (result) {
            .ok => |value| try ordered.append(allocator, value),
            .err => |err| return .{ .err = err },
        }
    }
    return .{ .ok = try ordered.toOwnedSlice(allocator) };
}

/// Invoke a member target by declaration parameter indices. `arg_params` is
/// parallel to the source-order user arguments; the receiver is parameter zero.
pub fn callFuncIndexed(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    func: FuncId,
    defaults_from: FuncId,
    receiver: *const Value,
    args: []const Value,
    arg_params: []const u32,
) Allocator.Error!EvalResult {
    const bound = try bindFuncIndexedArgs(self, allocator, module, func, defaults_from, receiver, args, arg_params);
    switch (bound) {
        .ok => |ordered| {
            defer allocator.free(ordered);
            return callFunc(self, allocator, module, func, ordered);
        },
        .err => |err| return .{ .err = err },
    }
}

/// A value the trailing-callable rule may bind: a closure, or a wrapped composable.
pub fn callableForTrailing(self: *VmHost, v: *const Value) bool {
    if (valueIsCallable(v)) return true;
    return v.* == .Instance and composableLambdaBlockArity(self, v) != null;
}

pub fn callFuncNamed(self: *VmHost, allocator: Allocator, module: *const Module, func_in: FuncId, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    var any_named = false;
    for (arg_names) |n| {
        if (n != null) {
            any_named = true;
            break;
        }
    }
    // The `.Call` path already re-picked by name and supplied any implicit receiver.
    const func = func_in;
    if (funcAt(module, func)) |f| {
        if (runtime.envOnce("KLIO_CFN_TRACE")) |w| {
            if (std.mem.indexOf(u8, f.name, w) != null) {
                std.debug.print("[cfn] {s}#{d} any_named={} nargs={d} params:", .{ f.fqn, func.int(), any_named, args.len });
                for (f.params) |p| std.debug.print(" {s}", .{p.name});
                std.debug.print(" names:", .{});
                for (arg_names) |n| std.debug.print(" {s}", .{n orelse "<pos>"});
                std.debug.print("\n", .{});
            }
        }
        if (any_named or hasNonFinalVararg(f.params)) {
            const params = f.params;
            var slots = try allocator.alloc(?Value, params.len);
            defer allocator.free(slots);
            for (slots) |*s| s.* = null;

            for (args, 0..) |a, i| {
                if (i < arg_names.len) {
                    if (arg_names[i]) |arg_name| {
                        for (params, 0..) |p, pos| {
                            if (applicability.paramNameMatchesArg(p.name, arg_name)) {
                                slots[pos] = a;
                                break;
                            }
                        }
                    }
                }
            }

            // A trailing positional callable binds the last function-typed
            // parameter out of sequence, leaving defaulted middles unconsumed.
            var trailing_lambda: ?usize = null;
            if (args.len > 0 and params.len > 0) {
                const last = args.len - 1;
                const last_named = last < arg_names.len and arg_names[last] != null;
                const last_param = params.len - 1;
                if (!last_named and slots[last_param] == null and
                    isFunctionType(&params[last_param].ty) and callableForTrailing(self, &args[last]))
                {
                    slots[last_param] = args[last];
                    trailing_lambda = last;
                }
                // Compose shape `(.., BLOCK, $composer = c, $changed = n)`: the
                // unnamed callable before the named pair binds the last user param.
                if (trailing_lambda == null and args.len >= 3 and params.len >= 3) {
                    const ci = args.len - 2;
                    const bi = args.len - 3;
                    const cn = if (ci < arg_names.len) arg_names[ci] else null;
                    const gn = if (last < arg_names.len) arg_names[last] else null;
                    const bn = if (bi < arg_names.len) arg_names[bi] else null;
                    const up = params.len - 3;
                    if (cn != null and gn != null and bn == null and
                        std.mem.eql(u8, cn.?, "$composer") and
                        std.mem.eql(u8, gn.?, "$changed") and
                        std.mem.eql(u8, params[params.len - 2].name, "$composer") and
                        std.mem.eql(u8, params[params.len - 1].name, "$changed") and
                        slots[up] == null and
                        isFunctionType(&params[up].ty) and
                        callableForTrailing(self, &args[bi]))
                    {
                        slots[up] = args[bi];
                        trailing_lambda = bi;
                    }
                }
            }

            var vararg_pos: ?usize = null;
            for (params, 0..) |p, pi| {
                if (p.is_vararg) {
                    vararg_pos = pi;
                    break;
                }
            }
            const walk_defaults = funcDefaults(self, func);
            var n_pos_total: usize = 0;
            for (args, 0..) |_, i| {
                const is_named = i < arg_names.len and arg_names[i] != null;
                if (is_named) continue;
                if (trailing_lambda != null and i == trailing_lambda.?) continue;
                n_pos_total += 1;
            }
            var pos_seen: usize = 0;
            var positional_idx: usize = 0;
            var vararg_acc: std.ArrayList(Value) = .empty;
            defer vararg_acc.deinit(allocator);
            var hit_vararg = false;
            for (args, 0..) |a, i| {
                const is_named = i < arg_names.len and arg_names[i] != null;
                if (is_named) continue;
                if (trailing_lambda != null and i == trailing_lambda.?) continue;
                while (positional_idx < params.len and slots[positional_idx] != null) positional_idx += 1;
                if (vararg_pos != null and positional_idx == vararg_pos.?) {
                    if (a == .Array and vararg_acc.items.len == 0) {
                        // Spread: a single Array at the vararg position passes through.
                        slots[positional_idx] = a;
                        positional_idx += 1;
                        pos_seen += 1;
                        continue;
                    }
                    // The vararg absorbs an arg only while the positionals left
                    // outnumber what the unfilled non-defaulted tail params need; a
                    // defaulted param claims none, since Kotlin passes it by name.
                    var required_tail: usize = 0;
                    // The ($composer, $changed) tail claims positionals only when
                    // the call carries the pair, a Composer instance plus an Int.
                    const tail_is_pair = args.len >= 2 and
                        args[args.len - 1] == .Int and args[args.len - 2] == .Instance and blk: {
                        const ig = args[args.len - 2].Instance.borrow();
                        defer ig.deinit();
                        const cg = ig.get().class.borrow();
                        defer cg.deinit();
                        break :blk std.mem.indexOf(u8, cg.get().name, "Composer") != null;
                    };
                    for (params[vararg_pos.? + 1 ..], vararg_pos.? + 1..) |*pp, j| {
                        if (slots[j] != null) continue;
                        if (!tail_is_pair and
                            (std.mem.eql(u8, pp.name, "$composer") or std.mem.eql(u8, pp.name, "$changed"))) continue;
                        const has_default = walk_defaults != null and j < walk_defaults.?.len and walk_defaults.?[j] != null;
                        if (!has_default) required_tail += 1;
                    }
                    if (hcfMissTraceEnv()) |w| {
                        if (std.mem.eql(u8, w, f.name))
                            std.debug.print("[vabsorb] {s} n_pos={d} seen={d} req_tail={d} defaults={}\n", .{ f.name, n_pos_total, pos_seen, required_tail, walk_defaults != null });
                    }
                    if (n_pos_total - pos_seen > required_tail) {
                        try vararg_acc.append(allocator, a);
                        hit_vararg = true;
                        pos_seen += 1;
                        continue;
                    }
                    positional_idx = vararg_pos.? + 1;
                    while (positional_idx < params.len and slots[positional_idx] != null) positional_idx += 1;
                }
                if (positional_idx < params.len) slots[positional_idx] = a;
                positional_idx += 1;
                pos_seen += 1;
            }
            if (vararg_pos) |vp| {
                const velem = params[vp].ty.name;
                if (hit_vararg) {
                    var acc: std.ArrayList(Value) = .empty;
                    try acc.appendSlice(allocator, vararg_acc.items);
                    slots[vp] = try packVarargArray(allocator, velem, acc);
                } else if (slots[vp] == null) {
                    const empty_acc: std.ArrayList(Value) = .empty;
                    slots[vp] = try packVarargArray(allocator, velem, empty_acc);
                }
            }

            const defaults = funcDefaults(self, func);
            var reordered: std.ArrayList(Value) = .empty;
            defer reordered.deinit(allocator);
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
                    vmhost.emitPath(allocator, "call_func_named_thunk", dfunc.fqn, id, null, reordered.items);
                    const r = try ir.eval.evalWith(VmHost, allocator, module, dfunc, thunk_args, self);
                    _ = &thunk_args;
                    switch (r) {
                        .ok => |v| try reordered.append(allocator, v),
                        .err => |e| return .{ .err = e },
                    }
                } else {
                    // No value and no default thunk: nothing bound past this slot is a
                    // trailing omission, handed to `callFunc` for padding, while a hole
                    // takes Null, which natives read as defaulted.
                    var later_bound = false;
                    for (slots[i + 1 ..]) |later| {
                        if (later != null) {
                            later_bound = true;
                            break;
                        }
                    }
                    if (!later_bound) break;
                    try reordered.append(allocator, Value.Null);
                }
            }
            return callFunc(self, allocator, module, func, reordered.items);
        }
    }
    return callFunc(self, allocator, module, func, args);
}

pub fn callFuncTyped(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8, type_args: []const []const u8, exact: bool) Allocator.Error!EvalResult {
    if (runtime.envOnce("KLIO_CFN_TRACE")) |w0| {
        if (funcAt(module, func)) |f0| {
            if (std.mem.indexOf(u8, f0.name, w0) != null) {
                std.debug.print("[cft] {s}#{d} nargs={d} names:", .{ f0.fqn, func.int(), args.len });
                for (arg_names) |n| std.debug.print(" {s}", .{n orelse "<pos>"});
                std.debug.print(" exact={}\n", .{exact});
            }
        }
    }
    // An unsigned literal carries its default UInt tag, so `arrayOf<ULong>(1u)`
    // retags integral args to the requested width, as kotlinc types by expectation.
    if (type_args.len == 1 and funcAt(module, func) != null) {
        const f = funcAt(module, func).?;
        if (std.mem.eql(u8, f.name, "arrayOf") and std.mem.startsWith(u8, f.fqn, "kotlin")) {
            const want: ?Value = switch (type_args[0].len) {
                0 => null,
                else => if (std.mem.eql(u8, type_args[0], "ULong"))
                    Value{ .ULong = 0 }
                else if (std.mem.eql(u8, type_args[0], "UInt"))
                    Value{ .UInt = 0 }
                else if (std.mem.eql(u8, type_args[0], "UShort"))
                    Value{ .UShort = 0 }
                else if (std.mem.eql(u8, type_args[0], "UByte"))
                    Value{ .UByte = 0 }
                else
                    null,
            };
            if (want) |w| {
                const retagged = try allocator.alloc(Value, args.len);
                defer if (runtime.freeScratch()) allocator.free(retagged);
                for (args, retagged) |v, *slot| {
                    slot.* = if (v.asU64()) |u| switch (w) {
                        .ULong => Value{ .ULong = u },
                        .UInt => Value{ .UInt = @truncate(u) },
                        .UShort => Value{ .UShort = @truncate(u) },
                        .UByte => Value{ .UByte = @truncate(u) },
                        else => v,
                    } else v;
                }
                return callFuncTypedInner(self, allocator, module, func, retagged, arg_names, type_args, exact);
            }
        }
    }
    return callFuncTypedInner(self, allocator, module, func, args, arg_names, type_args, exact);
}


/// One reified type-name global binding saved by `prepareTypedFlatCall` and
/// restored LIFO by `typedBindingsRestore` at activation teardown or park.
const TypedSaved = struct { name: []const u8, prev: ?Value };
const TypedSavedList = struct { items: []TypedSaved };

/// Resolve a plain positional typed call `f<T>(args)` into a flat-call request, as
/// `callFuncTypedInner` would. The request carries the reified bindings for restore
/// at the activation boundary; null declines to the recursive path.
pub fn prepareTypedFlatCall(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, type_args: []const []const u8, exact: bool) Allocator.Error!?ir.eval.FlatCallReq {
    const f0 = funcAt(module, func) orelse return null;
    if (std.mem.startsWith(u8, f0.fqn, "kotlin")) {
        if (std.mem.eql(u8, f0.name, "arrayOf") or std.mem.eql(u8, f0.name, "enumValues") or
            std.mem.eql(u8, f0.name, "enumValueOf") or std.mem.eql(u8, f0.name, "enumEntries") or
            std.mem.eql(u8, f0.name, "enumEntriesIntrinsic")) return null;
    }
    if (std.mem.eql(u8, f0.name, "typeOf") and std.mem.startsWith(u8, f0.fqn, "kotlin.reflect")) return null;
    const resolved: FuncId = if (exact) func else (pickOverloadCached(self, module, func, args) orelse func);
    const f = funcAt(module, resolved) orelse return null;
    if (paramIsThis(f.params) and args.len != 0 and
        extDeclRecvIsUserClass(f.params[0].ty.name) and valueIsBuiltin(&args[0])) return null;
    var plan = f.fast_call;
    if (plan == 0) {
        plan = fastCallPlan(self, module, resolved);
        @constCast(f).fast_call = plan;
    }
    const plan_arity = plan & 0x3FFF;
    if (!(plan_arity >= 2 and plan_arity - 2 == args.len)) return null;
    var call_args: std.ArrayList(Value) = .empty;
    errdefer call_args.deinit(allocator);
    try call_args.appendSlice(allocator, args);
    for (f.params, 0..) |*prm, i| {
        if (i >= call_args.items.len) break;
        narrowIntListArg(&prm.ty, &call_args.items[i]);
    }
    // Bind each type-arg name to a synth Class global; teardown or park restores.
    var names: []const []const u8 = &.{};
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.func_type_params.get(resolved)) |list| names = list.items;
    }
    var typed_saved: ?*anyopaque = null;
    if (names.len != 0) {
        var saved: std.ArrayList(TypedSaved) = .empty;
        errdefer saved.deinit(allocator);
        for (names, 0..) |type_name, idx| {
            const arg_name: []const u8 = if (idx < type_args.len) type_args[idx] else "";
            const cls_value: ?Value = if (typeArgUnbound(arg_name, names))
                (inferTypeArgFromArgs(self, allocator, f, type_name, call_args.items) orelse continue)
            else blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                if (cg.get().get(arg_name)) |c| break :blk Value{ .Class = c.clone() };
                break :blk host_globals.lookupGlobal(self, arg_name);
            };
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
        if (saved.items.len != 0) {
            const list = try allocator.create(TypedSavedList);
            list.* = .{ .items = try saved.toOwnedSlice(allocator) };
            typed_saved = list;
        } else {
            saved.deinit(allocator);
        }
    }
    const composer_pushed = flatPlainCallOpen(self, f, call_args.items);
    // The call site's type-args list dies with the exec arm while the strings
    // are module-owned, so dupe the list; the activation frees it.
    const ta_owned = try allocator.dupe([]const u8, type_args);
    return .{
        .func = f,
        .args = call_args,
        .composer_pushed = composer_pushed,
        .typed_saved = typed_saved,
        .type_args = ta_owned,
        .dst = undefined,
    };
}

/// Restore the reified type-name globals a typed flat call bound, LIFO, and free the list.
pub fn typedBindingsRestore(self: *VmHost, allocator: Allocator, ts: *anyopaque) void {
    const list: *TypedSavedList = @ptrCast(@alignCast(ts));
    var ri: usize = list.items.len;
    while (ri > 0) {
        ri -= 1;
        const sv = list.items[ri];
        const g = self.globals.borrowMut();
        defer g.deinit();
        if (sv.prev) |v| {
            g.get().define(sv.name, v) catch {};
        } else {
            g.get().removeLocal(sv.name);
        }
    }
    allocator.free(list.items);
    allocator.destroy(list);
}

/// Container element-type attachment `callFuncTypedInner` applies after the call.
pub fn typedCallBoundary(self: *VmHost, module: *const Module, func: *const ir.Func, type_args: []const []const u8, res: *EvalResult) void {
    _ = self;
    _ = module;
    if (res.* != .ok) return;
    runtime.attachDeclaredElemTypes(func.fqn, type_args, &res.ok);
}

fn callFuncTypedInner(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8, type_args: []const []const u8, exact: bool) Allocator.Error!EvalResult {
    if (hcfMissTraceEnv()) |w| {
        if (funcAt(module, func)) |tf| if (std.mem.eql(u8, w, tf.name)) {
            std.debug.print("[cfti] {s}#{d} nargs={d} nnames={d} names:", .{ tf.name, func.int(), args.len, arg_names.len });
            for (arg_names) |n| std.debug.print(" {s}", .{n orelse "-"});
            std.debug.print("\n", .{});
        };
    }
    // Compose ABI completion: a call the lowering could not see as composable arrives
    // without the ($composer, $changed) pair, completed here for non-vararg shapes.
    {
        if (funcAt(module, func)) |cf| {
            const p = cf.params;
            if (p.len >= 2 and args.len + 2 == p.len and
                std.mem.eql(u8, p[p.len - 1].name, "$changed") and
                std.mem.eql(u8, p[p.len - 2].name, "$composer"))
            {
                var no_vararg = true;
                for (p) |pp| {
                    if (pp.is_vararg) no_vararg = false;
                }
                var pair_supplied = false;
                for (arg_names) |n| {
                    if (n) |nm| {
                        if (std.mem.eql(u8, nm, "$composer")) pair_supplied = true;
                    }
                }
                if (no_vararg and !pair_supplied) {
                    if (compose.currentComposer()) |comp| {
                        const buf = try allocator.alloc(Value, args.len + 2);
                        defer if (runtime.freeScratch()) allocator.free(buf);
                        @memcpy(buf[0..args.len], args);
                        buf[args.len] = comp;
                        buf[args.len + 1] = .{ .Int = 0 };
                        const names2 = try allocator.alloc(?[]const u8, buf.len);
                        defer if (runtime.freeScratch()) allocator.free(names2);
                        for (names2, 0..) |*n2, i| n2.* = if (i < arg_names.len) arg_names[i] else null;
                        // Bind the pair by name; a positional append would misplace it.
                        names2[args.len] = "$composer";
                        names2[args.len + 1] = "$changed";
                        return callFuncTypedInner(self, allocator, module, func, buf, names2, type_args, exact);
                    }
                }
            }
        }
    }
    // Reified enum reflection served from the type argument; `enumEntries<T>()`
    // survives lowering as the bodyless `enumEntriesIntrinsic` header.
    if (funcAt(module, func)) |f| {
        if (std.mem.startsWith(u8, f.fqn, "kotlin") and
            (std.mem.eql(u8, f.name, "enumValues") or std.mem.eql(u8, f.name, "enumValueOf") or
                std.mem.eql(u8, f.name, "enumEntries") or std.mem.eql(u8, f.name, "enumEntriesIntrinsic")))
        {
            if (runtime.envOnce("KLIO_NU_TRACE") != null) {
                std.debug.print("[eev] fn={s} nta={d} ta0={s}\n", .{ f.name, type_args.len, if (type_args.len > 0) type_args[0] else "-" });
            }
            if (type_args.len > 0 and type_args[0].len != 0) {
                const tn = type_args[0];
                const cls_value: ?Value = blk: {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    if (cg.get().get(tn)) |c| break :blk Value{ .Class = c.clone() };
                    // An owner-qualified name resolves by FQN suffix: the table keys
                    // one simple-name winner.
                    if (std.mem.indexOfScalar(u8, tn, '.') != null) {
                        var it = cg.get().iterator();
                        while (it.next()) |e| {
                            const dg = e.value_ptr.borrow();
                            const fqn = dg.get().fqn;
                            const hit = std.mem.eql(u8, fqn, tn) or
                                (fqn.len > tn.len and std.mem.endsWith(u8, fqn, tn) and fqn[fqn.len - tn.len - 1] == '.');
                            dg.deinit();
                            if (hit) break :blk Value{ .Class = e.value_ptr.clone() };
                        }
                        if (cg.get().get(tn[std.mem.lastIndexOfScalar(u8, tn, '.').? + 1 ..])) |c| break :blk Value{ .Class = c.clone() };
                    }
                    break :blk host_globals.lookupGlobal(self, tn);
                };
                if (cls_value) |cv| {
                    if (cv == .Class) {
                        const cls = cv.Class;
                        const enum_cls = blk: {
                            const g = cls.borrow();
                            defer g.deinit();
                            break :blk g.get().is_enum;
                        };
                        // A reified enum intrinsic is a static use: the first inits.
                        if (enum_cls) {
                            if (try host_globals.ensureEnumInit(self, cls)) |e| return .{ .err = e };
                        }
                        const cd = cls.borrow();
                        const is_enum = cd.get().is_enum;
                        if (is_enum) {
                            if (std.mem.eql(u8, f.name, "enumValues") or
                                std.mem.eql(u8, f.name, "enumEntries") or
                                std.mem.eql(u8, f.name, "enumEntriesIntrinsic"))
                            {
                                var items: std.ArrayList(Value) = .empty;
                                for (cd.get().enum_entries) |entry| {
                                    // The container owns a reference per element;
                                    // `enum_entries` keeps its own.
                                    entry.value.retain();
                                    items.append(allocator, entry.value) catch {};
                                }
                                const want_array = std.mem.eql(u8, f.name, "enumValues");
                                cd.deinit();
                                // `enumValues<T>()` returns `Array<T>`, so a List
                                // misses array ops; `enumEntries` is a List.
                                if (want_array) {
                                    return .{ .ok = runtime.ArrayData.fromBoxedList(try ValueList.init(allocator, items)) };
                                }
                                return .{ .ok = try Value.newList(allocator, .{
                                    .items = try ValueList.init(allocator, items),
                                    .mutable = false,
                                    .enum_entries = true,
                                    .backing = null,
                                }) };
                            }
                            // enumValueOf<T>(name)
                            if (args.len > 0 and args[0] == .String) {
                                const sg = args[0].String.borrow();
                                const want = sg.get().bytes;
                                for (cd.get().enum_entries) |entry| {
                                    if (std.mem.eql(u8, entry.name, want)) {
                                        const out = entry.value;
                                        // host-returns-owned: retain the ClassDef's
                                        // singleton.
                                        out.retain();
                                        sg.deinit();
                                        cd.deinit();
                                        return .{ .ok = out };
                                    }
                                }
                                const fqn = try runtime.strInit(allocator, "kotlin.IllegalArgumentException");
                                const msg = try runtime.strInitOwned(allocator, try std.fmt.allocPrint(allocator, "No enum constant {s}.{s}", .{ cd.get().fqn, want }));
                                sg.deinit();
                                cd.deinit();
                                return .{ .err = .{ .Throw = try Value.newException(allocator, .{ .fqn = fqn, .message = .from(msg), .cause = null }) } };
                            }
                        }
                        cd.deinit();
                    }
                }
            }
        }
        // Reified `typeOf<T>()` is served here; the stdlib body only throws a placeholder.
        if (std.mem.eql(u8, f.name, "typeOf") and std.mem.startsWith(u8, f.fqn, "kotlin.reflect") and
            type_args.len == 1 and type_args[0].len != 0)
        {
            return .{ .ok = try makeKTypeValue(self, allocator, type_args[0]) };
        }
    }

    // Overload resolution, skipped for an `exact` call lowering resolved from an
    // explicit cast. Named arguments re-pick name-aware.
    const has_named = blk: {
        for (arg_names) |n| {
            if (n != null) break :blk true;
        }
        break :blk false;
    };
    const resolved: FuncId = if (exact)
        func
    else if (has_named)
        (pickNamedOverloadId(self, module, func, args, arg_names, false) orelse func)
    else
        (pickOverloadCached(self, module, func, args) orelse func);

    // Incompatible-receiver guard: a bare call baked to an extension on a user
    // class but reached with a builtin receiver re-dispatches as a member call.
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

    // Expected-type literal narrowing: kotlinc types `listOf(5)` as `List<Short>`
    // against an `Iterable<Short>` param, so default Int tags retag to fit.
    if (funcAt(module, resolved)) |f| {
        for (f.params, 0..) |*p, i| {
            if (i >= args.len) break;
            narrowIntListArg(&p.ty, &args[i]);
        }
    }

    // Bind each type-arg name to a synth Class global so reified reads resolve.
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
        const arg_full: []const u8 = if (idx < type_args.len) type_args[idx] else "";
        // A stamped spelling (`List<Int>`) binds its class by head; the full spelling
        // is for KType.
        const arg_name = if (std.mem.indexOfScalar(u8, arg_full, '<')) |lt| arg_full[0..lt] else arg_full;
        // Class table first: a type argument binds `.Class` even when its global is a
        // ctor intrinsic.
        const cls_value: ?Value = if (typeArgUnbound(arg_name, names)) blk: {
            const rf = funcAt(module, resolved) orelse break :blk null;
            break :blk inferTypeArgFromArgs(self, allocator, rf, type_name, args);
        } else blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(arg_name)) |c| break :blk Value{ .Class = c.clone() };
            break :blk host_globals.lookupGlobal(self, arg_name);
        };
        if (cls_value == null and arg_full.len == 0) continue;
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
        // The full generic spelling rides beside the class binding, which is
        // head-only, so a `typeOf<T>()` in this frame materialises arguments.
        if (arg_name.len != arg_full.len or std.mem.endsWith(u8, arg_full, "?")) {
            const key = try reifiedSpellingKey(allocator, type_name);
            const prev_sp = blk: {
                const g = self.globals.borrow();
                defer g.deinit();
                break :blk g.get().lookup(key);
            };
            try saved.append(allocator, .{ .name = key, .prev = prev_sp });
            const owned = try allocator.dupe(u8, arg_full);
            const g = self.globals.borrowMut();
            defer g.deinit();
            g.get().define(key, Value{ .String = try runtime.strInitOwned(allocator, owned) }) catch {};
        }
    }

    var result = try callFuncNamed(self, allocator, module, resolved, args, arg_names);

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
    attachDeclaredElemTypes(module, resolved, type_args, &result);
    return result;
}

/// Record the call-site type-argument heads on a container a creator just built.
fn attachDeclaredElemTypes(module: *const Module, func: FuncId, type_args: []const []const u8, result: *EvalResult) void {
    if (type_args.len == 0) return;
    if (result.* != .ok) return;
    const f = funcAt(module, func) orelse return;
    runtime.attachDeclaredElemTypes(f.fqn, type_args, &result.ok);
}

fn hasConstructibleClass(module: *const Module, name: []const u8) bool {
    const cid = module.classId(name) orelse return false;
    if (cid.int() >= module.classes.items.len) return false;
    return !module.classes.items[cid.int()].is_abstract;
}

pub fn callNamedOverload(self: *VmHost, allocator: Allocator, module: *const Module, candidate_ids: ?[]const FuncId, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, ctor_class: ?ir.ClassId, ctor_name: bool, caller_pkg: []const u8, caller_file: ?ir.FileId, synth_anchor_pkg: []const u8) Allocator.Error!MaybeValueResult {
    // An anon-object/side-module frame has no top-level func index; collect in main.
    const mg = self.module.borrow();
    defer mg.deinit();
    const bounded = candidate_ids != null;
    // Candidate ids are assigned against the assembled image, so a bounded set is
    // dereferenced there; an unbounded lookup keeps the frame module's name index.
    const eff0: *const Module = if (bounded or module.func_index.items.len == 0) mg.get() else module;
    // The package the visibility filter scopes against: `caller_pkg`, or the evaluator's
    // anchor for a synthesized frame. An empty scope lets a cross-package twin win.
    const scope_pkg: []const u8 = if (caller_pkg.len != 0) caller_pkg else synth_anchor_pkg;
    const anchored = caller_pkg.len == 0 and synth_anchor_pkg.len != 0;
    var excluded_xpkg = false;
    // Only intercept genuine overload sets: a lone top-level keeps the global-value path.
    var eff_resolved = eff0;
    const candidates = candidate_ids orelse blk: {
        const own = eff0.funcsBySimpleName(name);
        // An anon sub-module frame has its own func index, so the empty-index
        // fallback never fires, yet its bare calls resolve main-module top-levels.
        if (own.len == 0 and eff0 != mg.get()) {
            eff_resolved = mg.get();
            break :blk mg.get().funcsBySimpleName(name);
        }
        break :blk own;
    };
    const eff = eff_resolved;
    const ntrace = if (runtime.envOnce("KLIO_MISS_TRACE")) |w| std.mem.eql(u8, w, name) else false;
    if (ntrace) {
        std.debug.print("[cno] {s} bounded={} cands={d} in_fn={s} nargs={d} names:", .{
            name,
            bounded,
            candidates.len,
            if (ir.eval.currentFrameFunc()) |cf| cf.fqn else "<none>",
            args.len,
        });
        for (arg_names) |an| std.debug.print(" {s}", .{an orelse "<pos>"});
        std.debug.print("\n", .{});
    }
    if (!bounded and candidates.len < 2) {
        if (ntrace) std.debug.print("[cno] {s} cands={d} -> decline\n", .{ name, candidates.len });
        return .{ .ok = null };
    }

    // Pick the best body-carrying overload by runtime arg types. Per kotlinc an
    // overload lacking a supplied argument name is inapplicable.
    var any_named = false;
    // Safety builds 0xAA-fill the whole declared array per entry; >6 args heap.
    var shapes_buf: [6]applicability.ArgShape = undefined;
    const shapes = if (args.len <= shapes_buf.len)
        shapes_buf[0..args.len]
    else
        try allocator.alloc(applicability.ArgShape, args.len);
    defer if (args.len > shapes_buf.len) allocator.free(shapes);
    for (args, 0..) |*a, i| {
        shapes[i] = shapeOfValue(self, a);
        shapes[i].named = if (i < arg_names.len) arg_names[i] else null;
        if (shapes[i].named != null) any_named = true;
    }
    const scope = applicability.ApplicabilityScope{
        .named = any_named,
        .ctx = @ptrCast(self),
        .refine = applicRefineCb,
        .subtype = applicSubtypeCb,
        .identity_conflict = applicIdentityConflictCb,
        .exact_head = applicExactHeadCb,
        .erased_integer_widths = true,
    };
    // Per kotlinc a low-priority or deprecated-ERROR|HIDDEN overload applies only when
    // nothing ordinary does, and a same-named class constructor outranks it: with
    // either present, decline so the caller's constructor path binds.
    var best_ord: ?FuncId = null;
    var best_ord_score: i32 = 0;
    var best_low: ?FuncId = null;
    var best_low_score: i32 = 0;
    var best_scope_tier: u8 = 255;
    var best_needs_pair = false;
    for (candidates) |cand| {
        // A candidate whose declared receiver the first argument definitely is not is out.
        var is_low = false;
        var candidate_tier: u8 = 0;
        if (funcAt(eff, cand)) |cf| {
            // A bounded set comes from a CallMemberOrGlobal whose member and extension
            // candidates were already tried, so the global leg takes plain functions only.
            if (bounded and cf.kind != .plain) {
                if (ntrace) std.debug.print("[cno] {s} cand={d} kind-skip {s}\n", .{ name, cand.int(), @tagName(cf.kind) });
                continue;
            }
            if (bounded) {
                // Lowering scoped the bounded set with the call site's real file and
                // package, which this re-derivation lacks: with no caller file, trust
                // the bake.
                if (caller_file) |cfile| {
                    candidate_tier = eff.scopeTier(cf.fqn, cf.package, name, scope_pkg, cfile);
                    if (candidate_tier >= ir.Module.other_package_tier) {
                        // The frame's file need not be the call site's either, so
                        // rank an out-of-scope candidate last, never exclude it.
                        if (ntrace) std.debug.print("[cno] {s} cand={d} tier-clamp tier={d} scope_pkg={s} cfile={d}\n", .{ name, cand.int(), candidate_tier, scope_pkg, cfile.int() });
                        candidate_tier = ir.Module.other_package_tier;
                    }
                }
            }
            if (cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this") and args.len != 0 and
                host_call_member.builtinReceiverDisproven(&args[0], cf.params[0].ty.name)) continue;
            is_low = cf.low_priority;
            // A plain top-level the reference site cannot see is no target; extensions
            // stay.
            if (!bounded and scope_pkg.len != 0 and
                !(cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this")))
            {
                const cfile = caller_file orelse ir.FileId.from(std.math.maxInt(u32));
                if (eff.scopeTier(cf.fqn, cf.package, name, scope_pkg, cfile) == ir.Module.other_package_tier) {
                    excluded_xpkg = true;
                    continue;
                }
            }
        }
        var cand_needs_pair = false;
        var pts = positionalPoints(self, eff, cand, shapes, scope);
        // Compose ABI completion: score the user-visible params when the pair is missing.
        {
            if (sigViewOfFunc(self, eff, cand, shapes.len)) |sv| {
                const p = sv.params;
                if (p.len >= 2 and std.mem.eql(u8, p[p.len - 1].name, "$changed") and
                    std.mem.eql(u8, p[p.len - 2].name, "$composer") and
                    compose.currentComposer() != null)
                {
                    var sv2 = sv;
                    sv2.params = p[0 .. p.len - 2];
                    if (sv2.defaults) |d| {
                        if (d.len >= 2) sv2.defaults = d[0 .. d.len - 2];
                    }
                    // Pair-reduced scoring outranks a full score: a pairless call
                    // leaking args into the pair slots would misbind `$composer`.
                    if (applicability.applicable(&sv2, shapes, scope)) |sc2| {
                        if (pts == null or sc2.points > pts.?) {
                            pts = sc2.points;
                            cand_needs_pair = true;
                        }
                    }
                }
            }
        }
        if (ntrace) {
            const dbg_sig = sigViewOfFunc(self, eff, cand, shapes.len);
            std.debug.print("[cno] {s} cand={d} nargs={d} pts={?} np={?} has_body={?} p0={s} last_def={?} defs={?}\n", .{
                name,
                cand.int(),
                shapes.len,
                pts,
                if (dbg_sig) |s| s.params.len else null,
                if (dbg_sig) |s| s.has_body else null,
                if (dbg_sig) |s| (if (s.params.len != 0) s.params[0].name else "-") else "-",
                if (dbg_sig) |s| (if (s.params.len != 0) s.params[s.params.len - 1].has_default else false) else null,
                if (dbg_sig) |s| (if (s.defaults) |d| d.len else null) else null,
            });
            if (dbg_sig) |s| {
                if (s.defaults) |d| {
                    std.debug.print("[cno]   def-entries:", .{});
                    for (d) |e| std.debug.print(" {}", .{e != null});
                    std.debug.print("\n", .{});
                }
            }
        }
        if (pts) |total| {
            if (candidate_tier > best_scope_tier) continue;
            if (candidate_tier < best_scope_tier) {
                best_scope_tier = candidate_tier;
                best_ord = null;
                best_ord_score = 0;
                best_low = null;
                best_low_score = 0;
            }
            if (is_low) {
                if (best_low == null or total > best_low_score) {
                    best_low = cand;
                    best_low_score = total;
                }
            } else if (best_ord == null or total > best_ord_score) {
                best_ord = cand;
                best_ord_score = total;
                best_needs_pair = cand_needs_pair;
            }
        }
    }

    // Kotlin resolves a same-named class constructor together with the top-level
    // factories, most-specific winning: decline when the primary constructor binds
    // strictly better, which keeps factory-wraps-ctor working on equal signatures.
    if (best_ord != null) {
        if (ctor_class orelse mg.get().classId(name)) |ccid| {
            if (ccid.int() < mg.get().classes.items.len) {
                const class = &mg.get().classes.items[ccid.int()];
                if (!class.is_abstract) {
                    const ctor_sig = applicability.SigView{
                        .params = class.primary_params,
                        .has_body = true,
                    };
                    if (applicability.applicable(&ctor_sig, shapes, scope)) |csc| {
                        if (csc.points > best_ord_score) {
                            if (ntrace) std.debug.print("[cno] {s} ctor-decline class={d} ctor_pts={d} best={d}\n", .{ name, ccid.int(), csc.points, best_ord_score });
                            return .{ .ok = null };
                        }
                    }
                }
            }
        }
    }

    const func = best_ord orelse fallback: {
        // Fall to a low-priority overload only with no ordinary one and no same-name
        // class: `ctor_name` is the reliable signal, `classId` misses across packs.
        if (best_low) |low| {
            // The pack's classes live in the main module; `eff` may be a side
            // module whose class index misses them.
            const has_class = ctor_name or hasConstructibleClass(mg.get(), name);
            if (!has_class) break :fallback low;
        }
        return .{ .ok = null };
    };

    if (trace.enabled(name)) {
        trace.emit("global-overload {s} -> fid={d} (of {d} candidates)", .{ name, func.int(), candidates.len });
    }

    // The re-pick in `callFuncTyped` has no scope once the anchor excluded a twin.
    const exact_dispatch = bounded or (anchored and excluded_xpkg);
    // Flat handoff: stash a request for the driver; the one-shot take excludes nested
    // picks.
    if (ir.eval.takeHostFlatArm()) {
        var all_null = true;
        for (arg_names) |n| {
            if (n != null) {
                all_null = false;
                break;
            }
        }
        if (all_null) {
            if (try prepareTypedFlatCall(self, allocator, eff, func, args, &.{}, exact_dispatch)) |req| {
                ir.eval.stashHostFlatReq(req);
                return .{ .ok = Value.Unit };
            }
        }
    }
    if (best_needs_pair) {
        const comp = compose.currentComposer().?;
        const buf = try allocator.alloc(Value, args.len + 2);
        defer if (runtime.freeScratch()) allocator.free(buf);
        @memcpy(buf[0..args.len], args);
        buf[args.len] = comp;
        buf[args.len + 1] = .{ .Int = 0 };
        const names2 = try allocator.alloc(?[]const u8, buf.len);
        defer if (runtime.freeScratch()) allocator.free(names2);
        for (names2, 0..) |*n2, i| n2.* = if (i < arg_names.len) arg_names[i] else null;
        // The pair binds by name: appended positionally it lands in a free defaulted slot.
        names2[args.len] = "$composer";
        names2[args.len + 1] = "$changed";
        const rp = try callFuncTyped(self, allocator, eff, func, buf, names2, &.{}, exact_dispatch);
        return switch (rp) {
            .ok => |v| .{ .ok = v },
            .err => |e| .{ .err = e },
        };
    }
    const r = try callFuncTyped(self, allocator, eff, func, args, arg_names, &.{}, exact_dispatch);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = e },
    };
}

const testing = std.testing;

test "abstract classes do not compete with same-named factory functions" {
    const a = testing.allocator;
    var module = Module.default(a);
    defer module.deinit(a);

    _ = try module.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Factory",
        .fqn = "app.Factory",
        .package = "app",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .is_abstract = true,
        .is_interface = true,
    });
    try testing.expect(!hasConstructibleClass(&module, "Factory"));

    _ = try module.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Concrete",
        .fqn = "app.Concrete",
        .package = "app",
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try testing.expect(hasConstructibleClass(&module, "Concrete"));
}

test {
    testing.refAllDecls(@This());
}

/// Whether the declaration carries a body rather than only a native form.
pub fn funcHasBody(self: *VmHost, module: *const Module, func: FuncId) bool {
    _ = self;
    const f = funcAt(module, func) orelse return false;
    return f.hasBody();
}
