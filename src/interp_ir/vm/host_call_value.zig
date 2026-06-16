//! `VmHost` value-call dispatch: invoking callable `Value`s (closures,
//! lambdas, intrinsics, bound methods), lambda construction, and the
//! capture-read / receiver-shape helpers the IR evaluator consults.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked directly by the generic IR evaluator.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const host_call_func = @import("host_call_func.zig");
const host_call_member = @import("host_call_member.zig");
const host_fields = @import("host_fields.zig");
const host_globals = @import("host_globals.zig");
const host_instances = @import("host_instances.zig");

const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ValueList = runtime.ValueList;
const ValueSlice = runtime.ValueSlice;
const InstanceData = runtime.InstanceData;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;
const RuntimeError = runtime.RuntimeError;

const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const ReceiverShape = ir.eval.ReceiverShape;
const SuspendState = ir.eval.SuspendState;

fn unsupported(name: []const u8) EvalResult {
    return .{ .err = .{ .Unsupported = name } };
}

/// Single callable-value dispatch over the value variants.
pub fn callValue(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!EvalResult {
    if (callee.* == .Intrinsic) {
        return dispatchIntrinsic(self, callee.Intrinsic.fqn, callee.Intrinsic.func, args);
    }
    // `instance()` — bound-member-reference invocation
    // (`recv::method`, `String::plus`) wins over `operator fun
    // invoke`. A `$bound_ref$` synth carries `__bound_receiver__`
    // and `__bound_name__`; dispatch through them so an unbound
    // class-method ref consumes its first arg as the receiver.
    if (callee.* == .Instance) {
        var recv: ?Value = null;
        var name_v: ?Value = null;
        {
            const snap = callee.Instance.borrow();
            defer snap.deinit();
            recv = snap.get().get("__bound_receiver__");
            name_v = snap.get().get("__bound_name__");
        }
        if (recv != null and name_v != null and name_v.? == .String) {
            const rv = recv.?;
            const name = blk: {
                const g = name_v.?.String.borrow();
                defer g.deinit();
                break :blk g.get().*;
            };
            if (rv == .Class and args.len != 0) {
                const first = args[0];
                const rest = args[1..];
                if (rest.len == 0 and root.memberIsProperty(allocator, &self.classes, &first, name)) {
                    return host_fields.getField(self, allocator, &first, name);
                }
                return host_call_member.callMember(self, allocator, &first, name, rest);
            }
            if (args.len == 0 and root.memberIsProperty(allocator, &self.classes, &rv, name)) {
                return host_fields.getField(self, allocator, &rv, name);
            }
            const r = try host_call_member.callMember(self, allocator, &rv, name, args);
            // Fallback: a bare `::name` the lowerer bound to the enclosing
            // `this` may actually target a *top-level function* — the
            // binding is lowered before the function is registered (e.g. a
            // method default-arg thunk's `::shout`), so it can't be
            // distinguished at lower time. Only when member dispatch finds
            // no such member do we retry the global callable, so a genuine
            // bound member ref (`obj::method`, even one whose name matches
            // a top-level fn) keeps dispatching the member.
            if (r == .err and r.err == .Unimplemented) {
                if (host_globals.lookupGlobal(self, name)) |callable| {
                    if (callable == .Function or callable == .IrClosure) {
                        return callValue(self, allocator, &callable, args);
                    }
                }
            }
            return r;
        }
        return host_call_member.callMember(self, allocator, callee, "invoke", args);
    }
    // Constructor-like call on a user class value
    // (`val ctor = ::Foo; ctor(1, 2)`). Falls through to a
    // direct ClassDef-based allocation when the class isn't
    // in the IR module's class_index — covers local classes
    // declared inside a fn body and registered via
    // Inst::RegisterClass.
    if (callee.* == .Class) {
        const cls = callee.Class;
        // SAM conversion: `FunInterface { lambda }` constructs a
        // synthetic instance whose single abstract method
        // dispatches the lambda body. We allocate a thin
        // InstanceData whose `fields` carry the lambda under
        // `__sam_target__`; call_member on this instance routes
        // any method call back through the lambda.
        const is_fun_interface = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().is_fun_interface;
        };
        if (is_fun_interface and args.len == 1) {
            const identity = nextInstanceId(self);
            var fields: std.ArrayList(InstanceData.Field) = .empty;
            // The SAM instance owns one ref to its target; `args[0]` is a borrow
            // of the caller's register, so retain (instance teardown releases it).
            if (runtime.reclaimEnabled()) args[0].retain();
            try fields.append(allocator, .{ .name = "__sam_target__", .value = args[0] });
            const inst = try ObjRef(InstanceData).init(allocator, .{
                .class = cls.clone(),
                .fields = fields,
                .outer = null,
                .identity = identity,
                .native_state = null,
            });
            return .{ .ok = .{ .Instance = inst } };
        }
        const cls_name = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().name;
        };
        const cls_fqn = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().fqn;
        };
        // The bound ClassDef carries the resolved FQN; the module class
        // resolves by it, so `(::Ctor)(args)` constructs the referenced
        // class even when another package declares the same simple name.
        const class_id: ?ir.ClassId = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            if (mg.get().classIdByFqn(cls_fqn)) |cid| break :blk cid;
            for (mg.get().class_index.items) |entry| {
                if (std.mem.eql(u8, entry.name, cls_name)) break :blk entry.id;
            }
            break :blk null;
        };
        if (class_id) |cid| {
            return host_instances.newInstance(self, allocator, cid, args, null);
        }
        // Direct allocation for classes that aren't in the IR
        // module index. The runtime ClassDef carries enough to
        // bind primary-param properties; init blocks + custom
        // getters land when local-class lowering grows them.
        const identity = nextInstanceId(self);
        var fields: std.ArrayList(InstanceData.Field) = .empty;
        {
            const g = cls.borrow();
            defer g.deinit();
            const cdef = g.get();
            var i: usize = 0;
            while (i < cdef.primary_params.len and i < args.len) : (i += 1) {
                if (cdef.primary_params[i].property != null) {
                    // The instance owns one ref per primary-ctor field; `args[i]`
                    // is a borrow of the caller's register, so retain.
                    if (runtime.reclaimEnabled()) args[i].retain();
                    try fields.append(allocator, .{ .name = cdef.primary_params[i].name, .value = args[i] });
                }
            }
            // Body-property defaults for runtime-registered local
            // classes — literal-only inits, since there's no
            // lowered thunk on a non-IR class.
            for (cdef.body_properties) |p| {
                if (p.init) |init_expr| {
                    const v = simpleLiteral(allocator, init_expr) orelse Value.Null;
                    try fields.append(allocator, .{ .name = p.name, .value = v });
                } else if (p.getter == null and p.delegate == null) {
                    const v = p.primitive_zero orelse Value.Null;
                    try fields.append(allocator, .{ .name = p.name, .value = v });
                }
            }
        }
        const default_outer: ?Value = blk: {
            const g = self.class_default_outer.borrow();
            defer g.deinit();
            break :blk g.get().get(cls_name);
        };
        const inst = try ObjRef(InstanceData).init(allocator, .{
            .class = cls.clone(),
            .fields = fields,
            .outer = default_outer,
            .identity = identity,
            .native_state = null,
        });
        return .{ .ok = .{ .Instance = inst } };
    }
    // Invoking a `Value::PropertyRef` (`::name`). A callable reference
    // to a top-level function (`::tag`) calls that function with the
    // args — preferred over the property reading, since a default-arg
    // thunk lowered before the function was registered records the
    // reference as a `PropertyRef` rather than a `LoadGlobal`. A
    // genuine property reference (`::prop`) invoked with one arg reads
    // the named field from that arg (`KProperty1.get(receiver)`).
    if (callee.* == .PropertyRef) {
        const name = blk: {
            const g = callee.PropertyRef.name.borrow();
            defer g.deinit();
            break :blk g.get().*;
        };
        const is_fn = blk: {
            {
                const mg = self.module.borrow();
                defer mg.deinit();
                if (mg.get().hasFuncNamed(name)) break :blk true;
            }
            if (host_globals.lookupGlobal(self, name)) |g| {
                break :blk (g == .Function or g == .IrClosure);
            }
            break :blk false;
        };
        if (is_fn) {
            if (host_globals.lookupGlobal(self, name)) |callable| {
                return callValue(self, allocator, &callable, args);
            }
        }
        if (args.len == 1) {
            return host_fields.getField(self, allocator, &args[0], name);
        }
    }
    // Bound method/property reference: synthetic instance
    // carrying a receiver + method name. Invocation forwards
    // through the captured receiver (or reads the property on
    // the first arg for unbound property refs).
    if (callee.* == .Instance) {
        var recv: ?Value = null;
        var name_v: ?Value = null;
        {
            const snap = callee.Instance.borrow();
            defer snap.deinit();
            recv = snap.get().get("__bound_receiver__");
            name_v = snap.get().get("__bound_name__");
        }
        if (recv != null and name_v != null and name_v.? == .String) {
            const rv = recv.?;
            const name = blk: {
                const g = name_v.?.String.borrow();
                defer g.deinit();
                break :blk g.get().*;
            };
            if (rv == .Class and args.len == 1) {
                return host_fields.getField(self, allocator, &args[0], name);
            }
            return host_call_member.callMember(self, allocator, &rv, name, args);
        }
    }
    if (callee.* == .IrClosure) {
        const id = callee.IrClosure.id;
        const captures = callee.IrClosure.captures;
        // Closure id indexes the closure table.
        const info = self.closures.get(@intCast(id)) orelse {
            const msg = try std.fmt.allocPrint(allocator, "unknown IrClosure id {d}", .{id});
            return .{ .err = .{ .Type = msg } };
        };
        const module_ref = self.module.clone();
        defer module_ref.deinit();
        // A closure created inside a sub-module-lowered body resolves its
        // `FuncId` against that sub-module, never the main func table.
        const module = info.module orelse module_ref.asPtr();
        if (info.body_func.int() >= module.funcs.items.len) {
            const msg = try std.fmt.allocPrint(allocator, "closure body FuncId {d} out of range", .{info.body_func.int()});
            return .{ .err = .{ .Type = msg } };
        }
        const func = &module.funcs.items[info.body_func.int()];
        // One executable form per symbol: when the wrapped top-level fn's
        // single form was resolved to a native binding at link time
        // (e.g. a closure-of `kotlinx.datetime.__kxdt_*`), dispatch that
        // binding instead of running the shim placeholder body. The form
        // was settled once by `linkResolvedForms`; this consults it by
        // `FuncId` with no per-call FQN probe. Link tables are keyed by
        // main-module ids, so sub-module closures never consult them.
        if (info.module == null) {
            host_call_func.linkAuditCheck(self, module, func.id, func, args);
            if (host_call_func.resolvedNativeForm(self, func.id)) |intrinsic| {
                return dispatchIntrinsic(self, func.fqn, intrinsic, args);
            }
        }
        // Value-style invocation of a receiver lambda
        // (`block.invoke(receiver, p)` / `block(receiver, p)` for a
        // `R.(P) -> T`): the lambda's value params are `[p]`, so being
        // called with exactly one *extra* leading arg means arg0 is the
        // extension receiver. Bind it into the closure's `this` capture
        // and re-run on this same (main-evaluator) path — which snapshots
        // frames so a suspension inside the body (`delay`) parks
        // correctly, unlike the intrinsic-host invoke. The body resolves
        // its receiver through the `this` capture slot
        // (`func.capture_order`), so overriding the closure value's
        // captures (not the side-table `info.captures`, which this path
        // ignores) is what reaches the evaluator. Valid Kotlin never
        // over-supplies a non-receiver lambda, so the `+1` arity is
        // unambiguous; vararg targets (legitimately variadic) are
        // excluded; and a `this` capture must exist (a genuine receiver
        // lambda) so a 2-param lambda invoked with 3 args isn't misread.
        const last_vararg = func.params.len != 0 and func.params[func.params.len - 1].is_vararg;
        const this_cap_idx: ?usize = blk: {
            for (info.capture_names, 0..) |n, i| {
                if (std.mem.eql(u8, n, "this")) break :blk i;
            }
            break :blk null;
        };
        if (!last_vararg and args.len == info.n_params + 1 and this_cap_idx != null) {
            const this_idx = this_cap_idx.?;
            // The closure's captured `this` (before the explicit
            // receiver overrides it) is the lexically-enclosing
            // receiver the body closed over — e.g. ktor's engine
            // interceptor lambda closes over `this@install` (the
            // `HttpClientEngine`) yet is invoked by the pipeline as
            // `interceptor.invoke(pipelineContext, subject)`. Push it
            // as an enclosing receiver so the body can still resolve
            // the engine's members, mirroring `invoke_callable_with_this`.
            const prior_this: ?Value = blk: {
                const g = captures.borrow();
                defer g.deinit();
                const slice = g.get().*;
                if (this_idx < slice.len) break :blk slice[this_idx];
                break :blk null;
            };
            const bound = bnd: {
                var new_caps: std.ArrayList(Value) = .empty;
                {
                    const g = captures.borrow();
                    defer g.deinit();
                    try new_caps.appendSlice(allocator, g.get().*);
                }
                if (this_idx >= new_caps.items.len) {
                    try new_caps.appendNTimes(allocator, Value.Null, this_idx + 1 - new_caps.items.len);
                }
                new_caps.items[this_idx] = args[0];
                // The bound closure owns one ref to each capture (its teardown
                // releases them); the copied originals and the bound receiver
                // are borrows, so retain. No-op under the arena fast path.
                if (runtime.reclaimEnabled()) for (new_caps.items) |c| c.retain();
                const slice = try new_caps.toOwnedSlice(allocator);
                const caps_ref = try ValueSlice.init(allocator, slice);
                break :bnd Value{ .IrClosure = .{ .id = id, .captures = caps_ref } };
            };
            const rest = args[1..];
            const pushed_outer = po: {
                const a0 = args[0];
                if (prior_this == null) break :po false;
                const pt = prior_this.?;
                if (pt == .Null or pt == .Unit) break :po false;
                if (pt == .Instance and a0 == .Instance) {
                    break :po !ObjRef(InstanceData).ptrEq(pt.Instance, a0.Instance);
                }
                break :po true;
            };
            if (pushed_outer) {
                if (prior_this) |p| host_call_member.pushAccessEnclosing(self, &p);
            }
            const pushed_receiver = args[0] == .Instance;
            if (pushed_receiver) {
                host_call_member.pushAccessEnclosingSubject(self, &args[0]);
            }
            const r = try callValue(self, allocator, &bound, rest);
            if (pushed_receiver) host_call_member.popAccessEnclosing(self);
            if (pushed_outer) host_call_member.popAccessEnclosing(self);
            return r;
        }
        // Fill missing positional args from the target's
        // registered default-arg thunks (an implicit-`it` lambda
        // invoked with zero args still gets its slot as Null).
        // Pack trailing vararg args into an Array when the
        // target's last param is marked vararg. The defaults table is
        // keyed by main-module ids, so sub-module closures skip it.
        const defaults: ?[]?FuncId = blk: {
            if (info.module != null) break :blk null;
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk pg.get().func_defaults.get(info.body_func.int());
        };
        // Trailing-lambda rule for a value call: `f { … }` where `f`'s last
        // parameter is function-typed and the omitted leading parameters are
        // defaulted (e.g. `runBlocking(context = …) { block }`) binds the
        // lambda to the LAST parameter, not the first. Without this the
        // closure lands in `context` and a later `context[Key]` misdispatches.
        var call_args = blk: {
            const np = info.n_params;
            if (np >= 2 and args.len < np and args.len > 0 and func.params.len >= np) {
                const last_p = &func.params[np - 1];
                if (root.isFunctionType(&last_p.ty) and root.valueIsCallable(&args[args.len - 1])) {
                    const leading = args[0 .. args.len - 1];
                    var ca = switch (try padArgsWithDefaults(self, allocator, module_ref, np, leading, defaults)) {
                        .ok => |v| v,
                        .err => |e| return .{ .err = e },
                    };
                    ca.items[np - 1] = args[args.len - 1];
                    break :blk ca;
                }
            }
            break :blk switch (try padArgsWithDefaults(self, allocator, module_ref, info.n_params, args, defaults)) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
        };
        if (func.params.len != 0) {
            const last = func.params[func.params.len - 1];
            if (last.is_vararg and args.len > info.n_params) {
                var packed_args: std.ArrayList(Value) = .empty;
                const fixed = info.n_params -| 1;
                try packed_args.appendSlice(allocator, args[fixed..]);
                const items = try ValueList.init(allocator, packed_args);
                call_args.items[info.n_params - 1] = .{ .Array = .{ .items = items, .prim = null } };
            } else if (last.is_vararg and !(call_args.items.len != 0 and call_args.items[call_args.items.len - 1] == .Array)) {
                const fixed = info.n_params -| 1;
                var packed_args: std.ArrayList(Value) = .empty;
                if (args.len > fixed) {
                    try packed_args.appendSlice(allocator, args[fixed..]);
                }
                const items = try ValueList.init(allocator, packed_args);
                call_args.items[info.n_params - 1] = .{ .Array = .{ .items = items, .prim = null } };
            }
        }
        var capture_values: std.ArrayList(Value) = .empty;
        {
            const g = captures.borrow();
            defer g.deinit();
            try capture_values.appendSlice(allocator, g.get().*);
        }
        vmhost.emitPath(allocator, "call_value_closure", func.fqn, func.id, null, args);
        return ir.eval.evalWithCapturesChained(VmHost, allocator, module, info.module, func, call_args, capture_values, info.chain, self);
    }
    const msg = try std.fmt.allocPrint(allocator, "Vm::call_value on `{s}`", .{callee.typeFqn()});
    return .{ .err = .{ .Unimplemented = msg } };
}

pub fn callValueNamed(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    _ = arg_names;
    return callValue(self, allocator, callee, args);
}

pub fn callValueWithThis(self: *VmHost, allocator: Allocator, callee: *const Value, this_value: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    _ = arg_names;
    // Explicit-receiver receiver-lambda call (`block(receiver, p)` for a
    // `R.(P) -> T`, exactly one extra leading arg): bind `this_value`
    // into the `this` capture as a fallback and dispatch on the MAIN
    // evaluator path (`call_value`). That path applies the receiver-split
    // — arg0 is the explicit receiver and overrides `this` — and snapshots
    // frames so a suspension inside a `suspend` body parks correctly. The
    // intrinsic-host invoke below does neither, which strands a captured
    // receiver-lambda call such as ktor's on(Send) handler
    // `handler(Sender(this, …), request)` (the body's bare `proceed`
    // resolves against the receiver only when it reaches the body as the
    // closure's `this`).
    if (callee.* == .IrClosure) {
        const id = callee.IrClosure.id;
        const captures = callee.IrClosure.captures;
        if (self.closures.get(@intCast(id))) |info| {
            const this_idx: ?usize = blk: {
                for (info.capture_names, 0..) |n, i| {
                    if (std.mem.eql(u8, n, "this")) break :blk i;
                }
                break :blk null;
            };
            if (this_idx) |idx| {
                // Two receiver-lambda shapes reach here, both dispatched on
                // the MAIN evaluator path (`call_value`) so a suspension
                // inside a `suspend` body snapshots frames and parks:
                //   * explicit-receiver call (`block(receiver, p)` for a
                //     `R.(P) -> T`): arg0 is the receiver and overrides
                //     `this`, the body's value params follow.
                //   * receiver-bound call (`recv.block()` where `block` is a
                //     `suspend R.() -> Unit` param/property): the receiver
                //     arrives via `this_value`, the body's value params are
                //     `args` unchanged.
                // The intrinsic-host invoke below does neither, which would
                // both strand a captured receiver-lambda's bare-member
                // resolution and flatten an `EvalError.Suspended` into a
                // "suspended outside a driver" runtime error.
                const explicit_receiver = info.n_params >= 1 and args.len == info.n_params + 1;
                const receiver: Value = if (explicit_receiver) args[0] else this_value.*;
                var body_args: []const Value = if (explicit_receiver) args[1..] else args;
                // Receiver-bound call of a closure that declares one more
                // positional param than the call supplies: the callee is a
                // plain `(T, …) -> R` lambda used where a `T.(…) -> R` is
                // expected (kotlinc: the receiver IS the underlying
                // function's first param), so the receiver is delivered
                // positionally too — `client.apply(it)` over a stored
                // `(HttpClient) -> Unit` must fill `it`'s param, not pad
                // it with Null.
                if (!explicit_receiver and args.len + 1 == info.n_params) {
                    const with_recv = try allocator.alloc(Value, args.len + 1);
                    with_recv[0] = receiver;
                    @memcpy(with_recv[1..], args);
                    body_args = with_recv;
                }

                // Bind the receiver into a fresh captures cell's `this` slot
                // (the evaluator reads the closure value's captures, not the
                // side-table). Snapshot the prior `this` to keep it reachable
                // as an enclosing receiver for the body's bare-member /
                // member-extension resolution.
                var new_caps: std.ArrayList(Value) = .empty;
                {
                    const g = captures.borrow();
                    defer g.deinit();
                    try new_caps.appendSlice(allocator, g.get().*);
                }
                const prior_this: ?Value = if (idx < new_caps.items.len) new_caps.items[idx] else null;
                if (idx >= new_caps.items.len) {
                    try new_caps.appendNTimes(allocator, Value.Null, idx + 1 - new_caps.items.len);
                }
                new_caps.items[idx] = receiver;
                // The bound closure owns one ref to each capture (its teardown
                // releases them); the copied originals and the bound receiver
                // are borrows, so retain. No-op under the arena fast path.
                if (runtime.reclaimEnabled()) for (new_caps.items) |c| c.retain();
                const slice = try new_caps.toOwnedSlice(allocator);
                const caps_ref = try ValueSlice.init(allocator, slice);
                const bound = Value{ .IrClosure = .{ .id = id, .captures = caps_ref } };

                // Keep the displaced prior `this` reachable as an outer
                // implicit receiver, and push the new receiver so a body
                // calling a member-extension declared on its class sees the
                // owner as visible — mirroring `invoke_callable_with_this`.
                const pushed_outer = po: {
                    const pt = prior_this orelse break :po false;
                    if (pt == .Null or pt == .Unit) break :po false;
                    if (pt == .Instance and receiver == .Instance) {
                        break :po !ObjRef(InstanceData).ptrEq(pt.Instance, receiver.Instance);
                    }
                    break :po true;
                };
                if (pushed_outer) {
                    if (prior_this) |p| host_call_member.pushAccessEnclosing(self, &p);
                }
                // A null subject is pushed too: it is a real receiver
                // candidate for nullable-receiver extensions
                // (`fun Thing?.show()` inside `with(t)` where `t == null`).
                const pushed_receiver = receiver == .Instance or receiver == .Null;
                if (pushed_receiver) {
                    host_call_member.pushAccessEnclosingSubject(self, &receiver);
                }
                const r = try callValue(self, allocator, &bound, body_args);
                if (pushed_receiver) host_call_member.popAccessEnclosing(self);
                if (pushed_outer) host_call_member.popAccessEnclosing(self);
                return r;
            }
            // No `this` capture: the receiver binds as the leading
            // declared `this` param when the body has one (a local
            // extension function lowered as a closure); otherwise the
            // body takes no receiver. Either way the call runs on the
            // MAIN evaluator path (the intrinsic invoke below flattens a
            // suspension into a hard error), with the receiver reachable
            // as the innermost subject for dispatch-time resolution.
            const takes_this_param = blk: {
                const module_g = self.module.borrow();
                defer module_g.deinit();
                const m = info.module orelse module_g.get();
                if (info.body_func.int() >= m.funcs.items.len) break :blk false;
                const fp = m.funcs.items[info.body_func.int()].params;
                break :blk fp.len != 0 and std.mem.eql(u8, fp[0].name, "this");
            };
            // Explicit-receiver call shape on a body that never captured
            // `this` (`handler(Context(), a, b, c)` for a
            // `Context.(A, B, C) -> R` whose body reads no receiver
            // member): arg0 is the receiver, not a positional param —
            // split it off and keep it reachable as the innermost subject.
            if (!takes_this_param and info.n_params >= 1 and args.len == info.n_params + 1) {
                const recv0 = args[0];
                const pushed = recv0 == .Instance or recv0 == .Null;
                if (pushed) host_call_member.pushAccessEnclosingSubject(self, &recv0);
                const r = try callValue(self, allocator, callee, args[1..]);
                if (pushed) host_call_member.popAccessEnclosing(self);
                return r;
            }
            // A plain `(T, …) -> R` lambda used where a `T.(…) -> R` is
            // expected declares one more positional param than the call
            // supplies; the receiver fills it (kotlinc: the receiver IS
            // the underlying function's first param).
            const recv_fills_param = !takes_this_param and args.len + 1 == info.n_params;
            var all_args: std.ArrayList(Value) = .empty;
            defer all_args.deinit(allocator);
            if (takes_this_param or recv_fills_param) try all_args.append(allocator, this_value.*);
            try all_args.appendSlice(allocator, args);
            const pushed_receiver = this_value.* == .Instance or this_value.* == .Null;
            if (pushed_receiver) {
                host_call_member.pushAccessEnclosingSubject(self, this_value);
            }
            const r = try callValue(self, allocator, callee, all_args.items);
            if (pushed_receiver) host_call_member.popAccessEnclosing(self);
            return r;
        }
    }
    var sink = self.out_sink.clone();
    defer sink.deinit();
    var intrinsic = makeIntrinsicHost(self);
    defer intrinsicHostDeinit(&intrinsic);
    var host = intrinsic.intrinsicHost();
    const r = try host.invokeCallableWithThis(callee, args, this_value, sink.output());
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| try runtimeErrToEval(allocator, e),
    };
}

pub fn buildClosure(self: *VmHost, allocator: Allocator, module: *const Module, body_func: FuncId, captures: []const Value) Allocator.Error!EvalResult {
    // Derive the lambda's param count + capture-name list from the body
    // func so `LoadCapture` reads the right snapshot per closure.
    var n_params: usize = 0;
    var capture_names: [][]const u8 = &.{};
    const i = @intFromEnum(body_func);
    if (i < module.funcs.items.len) {
        const f = &module.funcs.items[i];
        n_params = f.params.len;
        capture_names = try allocator.dupe([]const u8, f.capture_order);
    }
    // Canonical capture store for this closure (read by the HOF invoke
    // path). A captured `var` a nested closure writes is itself a shared
    // `Value.Cell` carried here, so its mutation is visible by reference.
    var cell_list: std.ArrayList(Value) = .empty;
    try cell_list.appendSlice(allocator, captures);
    const cell = try ObjRef(std.ArrayList(Value)).init(allocator, cell_list);
    const id = try self.closures.push(.{
        .body_func = body_func,
        .module = if (module == self.module.asPtr()) null else module,
        .n_params = n_params,
        .capture_names = capture_names,
        .captures = cell,
        .chain = try ir.eval.captureChainAlloc(allocator),
    });
    // The IrClosure owns one ref to each capture (its `release` recursively
    // frees them); the registry `cell` above is a non-owning view.
    if (runtime.reclaimEnabled()) for (captures) |c| c.retain();
    const caps_ref = try ValueSlice.init(allocator, try allocator.dupe(Value, captures));
    return .{ .ok = .{ .IrClosure = .{ .id = id, .captures = caps_ref } } };
}

pub fn buildAstLambdaWithFlagFuncid(self: *VmHost, allocator: Allocator, module: *const Module, params: []const []const u8, body: *const ast.Block, captured_names: []const []const u8, captures: []const Value, absorb_return: bool, body_func: ?FuncId) Allocator.Error!EvalResult {
    _ = body;
    _ = absorb_return;
    const fid = body_func orelse return .{ .err = .{ .Unimplemented = "Vm: lambda lower did not provide body_func" } };
    // Canonical capture store for this closure (read by the HOF invoke
    // path). A captured `var` a nested closure writes is itself a shared
    // `Value.Cell` carried here, so its mutation is visible by reference.
    var cell_list: std.ArrayList(Value) = .empty;
    try cell_list.appendSlice(allocator, captures);
    const cell = try ObjRef(std.ArrayList(Value)).init(allocator, cell_list);
    const id = try self.closures.push(.{
        .body_func = fid,
        .module = if (module == self.module.asPtr()) null else module,
        .n_params = params.len,
        .capture_names = try allocator.dupe([]const u8, captured_names),
        .captures = cell,
        .chain = try ir.eval.captureChainAlloc(allocator),
    });
    if (runtime.reclaimEnabled()) for (captures) |c| c.retain();
    const caps_ref = try ValueSlice.init(allocator, try allocator.dupe(Value, captures));
    return .{ .ok = .{ .IrClosure = .{ .id = id, .captures = caps_ref } } };
}

pub fn callableReceiverShape(self: *VmHost, v: *const Value) ?ReceiverShape {
    _ = self;
    _ = v;
    return null;
}

pub fn closureNeedsThisCapture(self: *VmHost, v: *const Value) bool {
    _ = self;
    _ = v;
    return false;
}

pub fn overrideClosureThis(self: *VmHost, v: *const Value, new_this: *const Value) void {
    _ = self;
    _ = v;
    _ = new_this;
}

// -------------------------------------------------------------------------
// Internal helpers used by the value-call paths above. These mirror the
// `VmHost::dispatch_intrinsic` method (`vmhost.rs`) and the `lib.rs`
// `pad_args_with_defaults` / `simple_literal` free functions; they live
// here so the value-call logic is self-contained.
// -------------------------------------------------------------------------

/// Monotonic instance identity, mirroring `instance_id_counter.fetch_add(_, Relaxed) + 1`.
fn nextInstanceId(self: *VmHost) u64 {
    const g = self.instance_id_counter.borrowMut();
    defer g.deinit();
    return g.get().fetchAdd(1, .monotonic) + 1;
}

/// Build an `IntrinsicHost` adapter sharing this host's state, so HOF
/// stdlib bindings can recursively invoke lambdas via the closure table.
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

fn intrinsicHostDeinit(h: *VmIntrinsicHost) void {
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

/// Invoke a Rust-native stdlib intrinsic, mapping its `RuntimeError`
/// control-flow signals back into the IR evaluator's `EvalError`.
fn dispatchIntrinsic(self: *VmHost, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(self.allocator, "intrinsic_call_value", fqn, null, null, args);
    var intrinsic = makeIntrinsicHost(self);
    defer intrinsicHostDeinit(&intrinsic);
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = intrinsic.intrinsicHost(),
        .allocator = self.allocator,
    };
    const r = try func(&ctx);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| try runtimeErrToEval(self.allocator, e),
    };
}

/// Map a stdlib `RuntimeError` onto an `EvalError`, preserving thrown
/// values, non-local returns, and suspension requests.
fn runtimeErrToEval(allocator: Allocator, e: RuntimeError) Allocator.Error!EvalResult {
    switch (e) {
        // Preserve the thrown Value so the IR evaluator's try/catch can
        // match the handler against the exception class.
        .Thrown => |v| return .{ .err = .{ .Throw = v } },
        .Return => |v| return .{ .err = .{ .NonLocalReturn = v } },
        // A suspending primitive (`delay` / `yield`) asked to park. Seed
        // a fresh SuspendState; each enclosing `eval` frame snapshots
        // itself as it unwinds, and the coroutine driver parks the
        // result under a token.
        .Suspend => |wake| {
            const st = try allocator.create(SuspendState);
            st.* = .{
                .token = 0,
                .frames = .empty,
                .wake_in_millis = wake,
                .pending_resume_reg = null,
            };
            return .{ .err = .{ .Suspended = st } };
        },
        // Map each error kind back to its `EvalError` counterpart, keeping
        // the carried message as the same string (the inverse of
        // `runtimeErrorFromEval`). Formatting the whole `RuntimeError` with
        // `{any}` would print its `[]const u8` payload as a raw byte array
        // and re-wrap an already-rendered message inside a second `.Type`.
        .Unbound => |s| return .{ .err = .{ .Unbound = s } },
        .Type => |s| return .{ .err = .{ .Type = s } },
        .Arity => |s| return .{ .err = .{ .Arity = s } },
        .Unimplemented => |s| return .{ .err = .{ .Unimplemented = s } },
        .CalleeFailed => |s| return .{ .err = .{ .CalleeFailed = s } },
        .LabeledReturn => |lr| return .{ .err = .{ .LabeledReturn = .{ .label = lr.label, .value = lr.value } } },
        else => {
            const msg = try std.fmt.allocPrint(allocator, "{s}", .{@tagName(e)});
            return .{ .err = .{ .Type = msg } };
        },
    }
}

/// `Result<std.ArrayList(Value), EvalError>` for `padArgsWithDefaults`.
const PadResult = union(enum) { ok: std.ArrayList(Value), err: EvalError };

/// Pad `provided` to `n_params`, evaluating each missing slot's default
/// thunk. A default-arg thunk that references the receiver records `this`
/// as a capture, so the first already-bound arg seeds the capture slot.
fn padArgsWithDefaults(
    self: *VmHost,
    allocator: Allocator,
    module_ref: ObjRef(Module),
    n_params: usize,
    provided: []const Value,
    defaults: ?[]?FuncId,
) Allocator.Error!PadResult {
    var call_args: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < n_params) : (i += 1) {
        if (i < provided.len) {
            try call_args.append(allocator, provided[i]);
            continue;
        }
        const dfid: ?FuncId = if (defaults) |d| (if (i < d.len) d[i] else null) else null;
        if (dfid) |fid| {
            // A default-arg thunk lowered inside an extension fn body that
            // references the receiver (`toIndex = size` on `IntArray.fill`)
            // records `this` as a capture, not a param. Seed the capture
            // slot with the receiver so the bare `size` resolves through it
            // instead of failing as an unresolved global.
            var captures: std.ArrayList(Value) = .empty;
            if (call_args.items.len != 0) {
                try captures.append(allocator, call_args.items[0]);
            }
            var args_copy: std.ArrayList(Value) = .empty;
            try args_copy.appendSlice(allocator, call_args.items);
            const module = module_ref.asPtr();
            if (fid.int() >= module.funcs.items.len) {
                args_copy.deinit(allocator);
                captures.deinit(allocator);
                call_args.deinit(allocator);
                const msg = try std.fmt.allocPrint(allocator, "default-arg FuncId {d} out of range", .{fid.int()});
                return .{ .err = .{ .Type = msg } };
            }
            const dfunc = &module.funcs.items[fid.int()];
            vmhost.emitPath(allocator, "default_thunk", dfunc.fqn, fid, null, provided);
            const r = try ir.eval.evalWithCaptures(VmHost, allocator, module, dfunc, args_copy, captures, self);
            switch (r) {
                .ok => |v| try call_args.append(allocator, v),
                .err => |e| {
                    call_args.deinit(allocator);
                    return .{ .err = e };
                },
            }
        } else {
            try call_args.append(allocator, Value.Null);
        }
    }
    return .{ .ok = call_args };
}

/// Literal-only constant folder for a body-property initializer on a
/// runtime-registered local class (no lowered init thunk available).
fn simpleLiteral(allocator: Allocator, e: *const ast.Expr) ?Value {
    switch (e.*) {
        .IntLit => |x| return Value.newInt(x.value),
        .FloatLit => |x| return .{ .Double = x.value },
        .BoolLit => |x| return .{ .Bool = x.value },
        .NullLit => return Value.Null,
        .CharLit => |x| return .{ .Char = x.value },
        .StringTemplate => |x| {
            for (x.parts) |p| {
                if (p != .Text) return null;
            }
            var buf: std.ArrayList(u8) = .empty;
            for (x.parts) |p| {
                buf.appendSlice(allocator, p.Text) catch return null;
            }
            const owned = buf.toOwnedSlice(allocator) catch return null;
            const ref = runtime.StringRef.initOwned(allocator, owned) catch return null;
            return .{ .String = ref };
        },
        else => return null,
    }
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}
