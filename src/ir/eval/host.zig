//! Pluggable callbacks the IR evaluator delegates non-trivial dispatch
//! through.
//!
//! The Rust `Host` trait — a bag of methods most of which carry a
//! default body — becomes a `{ctx, vtable}` pair (mirroring
//! `runtime.host.IntrinsicHost`). A vtable slot is optional (`?fn`)
//! exactly when the Rust method had a default; `null` selects the
//! default behavior implemented in the wrapper method here. Slots whose
//! Rust default merely forwarded to another method are kept as wrapper
//! methods that route through the other vtable slot, so an override of
//! the base method is observed by the forwarding caller.

const std = @import("std");
const ir = @import("../ir.zig");
const ast = @import("ast");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;

const Module = ir.Module;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const TypeRef = ir.TypeRef;
const Value = runtime.Value;

/// Errors-as-data surfaced out of the IR evaluator. The full set is
/// owned here so the host surface (which constructs `Unsupported` /
/// `Type`) and the evaluator share one definition; the eval root
/// re-exports it. OOM stays a Zig `error`.
pub const EvalError = union(enum) {
    /// IR evaluator does not yet support this construct.
    Unsupported: []const u8,
    /// IR type error (owned message).
    Type: []const u8,
    /// Uncaught throw inside the IR evaluator.
    Throw: Value,
    /// `return` from a nested lambda whose target is an enclosing IR
    /// function frame. The matching fn boundary converts it to a
    /// normal return value.
    NonLocalReturn: Value,
    /// `return@label value` whose target is a named function/lambda
    /// frame, caught when the active frame's `func.name` matches the
    /// label. Owns the label string.
    LabeledReturn: struct { label: []const u8, value: Value },
    /// Arity mismatch — caller passed the wrong number of args.
    Arity: []const u8,
    /// Unbound identifier reachable through the IR.
    Unbound: []const u8,
    /// Operation not yet implemented on this value.
    Unimplemented: []const u8,
};

/// `Result<Value, EvalError>` as data. OOM stays a Zig `error`; this
/// carries the `EvalError` data path.
pub const EvalValueResult = union(enum) {
    ok: Value,
    err: EvalError,
};

/// `Result<(), EvalError>` as data.
pub const EvalUnitResult = union(enum) {
    ok: void,
    err: EvalError,
};

/// `Result<Option<Value>, EvalError>` for `call_named_overload`.
pub const EvalOptValueResult = union(enum) {
    ok: ?Value,
    err: EvalError,
};

/// `(n_params, first_param_is_this)` — a callable's dispatch shape.
pub const ReceiverShape = struct {
    n_params: usize,
    first_param_is_this: bool,
};

/// Pluggable callbacks the evaluator delegates non-trivial dispatch
/// through. The IR is intentionally agnostic about how user classes
/// and top-level functions are resolved; a real frontend supplies a
/// host implementation that ties into the interpreter's class table /
/// dispatch machinery. A default no-op `NullHost` exists for unit
/// tests.
///
/// A `{ctx, vtable}` pair: `ctx` is the concrete host instance, the
/// `allocator` produces any heap a default helper needs (the Rust
/// trait used the global allocator), and each vtable slot is optional
/// when the Rust method had a default.
pub const Host = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    allocator: Allocator,

    pub const VTable = struct {
        /// Resolve a `CallValue` invocation against a runtime value.
        /// `null` => default rejects so wiring is visible.
        call_value: ?*const fn (ctx: *anyopaque, callee: *const Value, args: []const Value) Allocator.Error!EvalValueResult = null,
        /// Same as `call_value` but with named-arg metadata. `null` =>
        /// default drops the names and routes through `call_value`.
        call_value_named: ?*const fn (ctx: *anyopaque, callee: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalValueResult = null,
        /// Resolve a `CallMember` invocation against the receiver.
        /// `null` => default rejects.
        call_member: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!EvalValueResult = null,
        /// `null` => default routes through `call_member`.
        call_member_named: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalValueResult = null,
        /// Whether `receiver`'s class (transitively over supertypes)
        /// declares a member function `name`. `null` => `false`.
        host_has_member: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8) bool = null,
        /// Construct an instance of a class referenced by ID. `null` =>
        /// default rejects.
        new_instance: ?*const fn (ctx: *anyopaque, class: ClassId, args: []const Value) Allocator.Error!EvalValueResult = null,
        /// `null` => default routes through `new_instance`.
        new_instance_named: ?*const fn (ctx: *anyopaque, class: ClassId, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalValueResult = null,
        /// Read a property on the receiver. `null` => default field
        /// lookup via `InstanceData.get`.
        get_field: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8) Allocator.Error!EvalValueResult = null,
        /// Write a property on the receiver. `null` => default writes
        /// directly to the instance backing store.
        set_field: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8, value: Value) Allocator.Error!EvalUnitResult = null,
        /// Test whether `value` is an instance of `ty`. `null` =>
        /// default primitive name-match via `Value.typeFqn`.
        instance_of: ?*const fn (ctx: *anyopaque, value: *const Value, ty: *const TypeRef) bool = null,
        /// True when `name` denotes a concrete type a checked cast can
        /// test against. `null` => default reports every name concrete.
        is_concrete_cast_target: ?*const fn (ctx: *anyopaque, name: []const u8) bool = null,
        /// Resolve a bare global identifier. `null` => default `null`.
        lookup_global: ?*const fn (ctx: *anyopaque, name: []const u8) ?Value = null,
        /// Throwing-aware variant of `lookup_global`. `null` => default
        /// forwards to `lookup_global`.
        lookup_global_throwing: ?*const fn (ctx: *anyopaque, name: []const u8) Allocator.Error!EvalOptValueResult = null,
        /// Write a top-level binding. `null` => default rejects.
        store_global: ?*const fn (ctx: *anyopaque, name: []const u8, value: Value) Allocator.Error!EvalUnitResult = null,
        /// Register a local class declaration with the host's class
        /// table. `null` => default rejects.
        register_class: ?*const fn (ctx: *anyopaque, class: *const ast.Class) Allocator.Error!EvalUnitResult = null,
        /// Register a local class with captured outer locals. `null` =>
        /// default ignores captures and routes to `register_class`.
        register_class_captured: ?*const fn (ctx: *anyopaque, class: *const ast.Class, captured_names: []const []const u8, captures: []Value) Allocator.Error!EvalUnitResult = null,
        /// Synthesise an anonymous-object instance from an `object {…}`
        /// AST node. `null` => default rejects.
        build_object: ?*const fn (ctx: *anyopaque, node: *const ast.Expr, captured_names: []const []const u8, captures: []Value) Allocator.Error!EvalValueResult = null,
        /// Invoke a callable with `this_value` bound as the implicit
        /// receiver inside the body. `null` => default rejects.
        call_value_with_this: ?*const fn (ctx: *anyopaque, callee: *const Value, this_value: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalValueResult = null,
        /// Dispatch `super.name(args)` against the parent of
        /// `owner_class`. `null` => default rejects.
        call_super: ?*const fn (ctx: *anyopaque, receiver: *const Value, owner_class: []const u8, qualifier: ?[]const u8, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalValueResult = null,
        /// Resolve `this@Qual` by walking the receiver's outer chain.
        /// `null` => default rejects.
        qualified_this: ?*const fn (ctx: *anyopaque, receiver: *const Value, qualifier: []const u8) Allocator.Error!EvalValueResult = null,
        /// Read a captured variable's current value out of a closure's
        /// env. `null` => default rejects.
        read_lambda_capture: ?*const fn (ctx: *anyopaque, lambda: *const Value, name: []const u8) Allocator.Error!EvalValueResult = null,
        /// Resolve `receiver::name` to a callable reference value.
        /// `null` => default rejects.
        member_ref: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8) Allocator.Error!EvalValueResult = null,
        /// Materialise a closure value capturing the supplied register
        /// snapshot. `null` => default rejects.
        build_closure: ?*const fn (ctx: *anyopaque, module: *const Module, body_func: FuncId, captures: []Value) Allocator.Error!EvalValueResult = null,
        /// Build a `Value.Lambda`-compatible closure from an AST block.
        /// `null` => default rejects.
        build_ast_lambda: ?*const fn (ctx: *anyopaque, params: []const []const u8, body: *const ast.Block, captured_names: []const []const u8, captures: []Value) Allocator.Error!EvalValueResult = null,
        /// Variant threading the `absorb_return` flag. `null` => default
        /// routes through `build_ast_lambda`.
        build_ast_lambda_with_flag: ?*const fn (ctx: *anyopaque, params: []const []const u8, body: *const ast.Block, captured_names: []const []const u8, captures: []Value, absorb_return: bool) Allocator.Error!EvalValueResult = null,
        /// Variant that also receives the lambda body's lowered
        /// `FuncId`. `null` => default routes through
        /// `build_ast_lambda_with_flag`.
        build_ast_lambda_with_flag_funcid: ?*const fn (ctx: *anyopaque, params: []const []const u8, body: *const ast.Block, captured_names: []const []const u8, captures: []Value, absorb_return: bool, body_func: ?FuncId) Allocator.Error!EvalValueResult = null,
        /// Resolve a function call by `FuncId`. `null` => default routes
        /// through `eval()` recursively (when the eval root is ported).
        call_func: ?*const fn (ctx: *anyopaque, module: *const Module, func: FuncId, args: []Value) Allocator.Error!EvalValueResult = null,
        /// `null` => default routes through `call_func`.
        call_func_named: ?*const fn (ctx: *anyopaque, module: *const Module, func: FuncId, args: []Value, arg_names: []const ?[]const u8) Allocator.Error!EvalValueResult = null,
        /// Variant carrying call-site type arguments. `null` => default
        /// routes through `call_func_named`.
        call_func_typed: ?*const fn (ctx: *anyopaque, module: *const Module, func: FuncId, args: []Value, arg_names: []const ?[]const u8, type_args: []const []const u8, exact: bool) Allocator.Error!EvalValueResult = null,
        /// Resolve a bare-name call against the top-level function table
        /// with runtime-argument overload selection. `null` =>
        /// default `Ok(None)`.
        call_named_overload: ?*const fn (ctx: *anyopaque, module: *const Module, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalOptValueResult = null,
        /// The lexically enclosing `this` displaced by a receiver
        /// lambda. `null` => default `None`.
        enclosing_this: ?*const fn (ctx: *anyopaque) ?Value = null,
        /// The full lexically-enclosing-`this` chain, innermost first.
        /// `null` => default: the single `enclosing_this()` collected.
        /// The returned slice is owned by the caller (`allocator`).
        enclosing_this_chain: ?*const fn (ctx: *anyopaque, allocator: Allocator) Allocator.Error![]Value = null,
        /// Report `(n_params, first_param_is_this)` for a callable.
        /// `null` => default `None`.
        callable_receiver_shape: ?*const fn (ctx: *anyopaque, v: *const Value) ?ReceiverShape = null,
        /// True when the closure carries a captured `this` slot whose
        /// current value isn't a usable receiver. `null` => `false`.
        closure_needs_this_capture: ?*const fn (ctx: *anyopaque, v: *const Value) bool = null,
        /// Override the closure's captured `this` slot for the duration
        /// of the impending invocation. `null` => no-op.
        override_closure_this: ?*const fn (ctx: *anyopaque, v: *const Value, new_this: *const Value) void = null,
        /// Resolve `name` as a *member* of `receiver` only. `null` =>
        /// default routes through `call_member_named`.
        call_member_only: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalValueResult = null,
        /// Make `v` reachable as the lexically enclosing `this` for the
        /// duration of a member access. `null` => no-op.
        push_access_enclosing: ?*const fn (ctx: *anyopaque, v: *const Value) void = null,
        /// `null` => no-op.
        pop_access_enclosing: ?*const fn (ctx: *anyopaque) void = null,
        /// Stash an outer-`this` candidate for a soon-to-be-allocated
        /// inner-class instance. `null` => no-op.
        push_inner_outer_hint: ?*const fn (ctx: *anyopaque, v: *const Value) void = null,
        /// `null` => no-op.
        pop_inner_outer_hint: ?*const fn (ctx: *anyopaque) void = null,
        /// True when `name` is bound, in the innermost scoped-global
        /// layer, to a callable value. `null` => `false`.
        is_shadowing_capture: ?*const fn (ctx: *anyopaque, name: []const u8) bool = null,
    };

    /// Resolve a `CallValue` invocation against a runtime value.
    /// Default rejects so wiring is visible.
    pub fn callValue(self: Host, callee: *const Value, args: []const Value) !EvalValueResult {
        if (self.vtable.call_value) |f| return f(self.ctx, callee, args);
        return .{ .err = .{ .Unsupported = "Host::call_value" } };
    }

    /// Same as `callValue` but with named-arg metadata. Default drops
    /// the names and routes through `callValue`.
    pub fn callValueNamed(self: Host, callee: *const Value, args: []const Value, arg_names: []const ?[]const u8) !EvalValueResult {
        if (self.vtable.call_value_named) |f| return f(self.ctx, callee, args, arg_names);
        return self.callValue(callee, args);
    }

    /// Resolve a `CallMember` invocation against the receiver.
    pub fn callMember(self: Host, receiver: *const Value, name: []const u8, args: []const Value) !EvalValueResult {
        if (self.vtable.call_member) |f| return f(self.ctx, receiver, name, args);
        return .{ .err = .{ .Unsupported = "Host::call_member" } };
    }

    pub fn callMemberNamed(self: Host, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) !EvalValueResult {
        if (self.vtable.call_member_named) |f| return f(self.ctx, receiver, name, args, arg_names);
        return self.callMember(receiver, name, args);
    }

    /// Whether `receiver`'s class (transitively over supertypes)
    /// declares a member function `name`.
    pub fn hostHasMember(self: Host, receiver: *const Value, name: []const u8) bool {
        if (self.vtable.host_has_member) |f| return f(self.ctx, receiver, name);
        return false;
    }

    /// Construct an instance of a class referenced by ID.
    pub fn newInstance(self: Host, class: ClassId, args: []const Value) !EvalValueResult {
        if (self.vtable.new_instance) |f| return f(self.ctx, class, args);
        return .{ .err = .{ .Unsupported = "Host::new_instance" } };
    }

    pub fn newInstanceNamed(self: Host, class: ClassId, args: []const Value, arg_names: []const ?[]const u8) !EvalValueResult {
        if (self.vtable.new_instance_named) |f| return f(self.ctx, class, args, arg_names);
        return self.newInstance(class, args);
    }

    /// Read a property on the receiver. Default for instances is the
    /// raw field lookup via `InstanceData.get`.
    pub fn getField(self: Host, receiver: *const Value, name: []const u8) !EvalValueResult {
        if (self.vtable.get_field) |f| return f(self.ctx, receiver, name);
        switch (receiver.*) {
            .Instance => |inst| {
                var g = inst.borrow();
                defer g.deinit();
                return .{ .ok = g.get().get(name) orelse .Null };
            },
            else => {
                const v = try receiver.display(self.allocator);
                defer self.allocator.free(v);
                const msg = try std.fmt.allocPrint(self.allocator, "GetField on non-instance: {s}", .{v});
                return .{ .err = .{ .Type = msg } };
            },
        }
    }

    /// Write a property on the receiver. Default writes directly to the
    /// instance backing store.
    pub fn setField(self: Host, receiver: *const Value, name: []const u8, value: Value) !EvalUnitResult {
        if (self.vtable.set_field) |f| return f(self.ctx, receiver, name, value);
        switch (receiver.*) {
            .Instance => |inst| {
                var g = inst.borrowMut();
                defer g.deinit();
                try g.get().define(self.allocator, name, value);
                return .{ .ok = {} };
            },
            .Null => return .{ .ok = {} },
            else => {
                const v = try receiver.display(self.allocator);
                defer self.allocator.free(v);
                const msg = try std.fmt.allocPrint(self.allocator, "SetField on non-instance: {s}", .{v});
                return .{ .err = .{ .Type = msg } };
            },
        }
    }

    /// Test whether `value` is an instance of `ty`. The default handles
    /// the primitive nominal types via `Value.typeFqn`; complex types
    /// defer to the host.
    pub fn instanceOf(self: Host, value: *const Value, ty: *const TypeRef) bool {
        if (self.vtable.instance_of) |f| return f(self.ctx, value, ty);
        // Primitive name-match suffices for the simple shapes the IR
        // evaluator can reason about standalone.
        const nominal = value.typeFqn();
        if (std.mem.eql(u8, nominal, ty.name)) return true;
        return endsWithDotName(nominal, ty.name);
    }

    /// True when `name` denotes a concrete type a checked cast can test
    /// against. The default conservatively reports every name as
    /// concrete (preserving the throwing behaviour).
    pub fn isConcreteCastTarget(self: Host, name: []const u8) bool {
        if (self.vtable.is_concrete_cast_target) |f| return f(self.ctx, name);
        return true;
    }

    /// Resolve a bare global identifier. Default returns `null`.
    pub fn lookupGlobal(self: Host, name: []const u8) ?Value {
        if (self.vtable.lookup_global) |f| return f(self.ctx, name);
        return null;
    }

    /// Throwing-aware variant of `lookupGlobal`. The default forwards
    /// to `lookupGlobal`.
    pub fn lookupGlobalThrowing(self: Host, name: []const u8) !EvalOptValueResult {
        if (self.vtable.lookup_global_throwing) |f| return f(self.ctx, name);
        return .{ .ok = self.lookupGlobal(name) };
    }

    /// Write a top-level binding. Default fails so missing wiring is
    /// visible.
    pub fn storeGlobal(self: Host, name: []const u8, value: Value) !EvalUnitResult {
        if (self.vtable.store_global) |f| return f(self.ctx, name, value);
        return .{ .err = .{ .Unsupported = "Host::store_global" } };
    }

    /// Register a local class declaration with the host's class table.
    pub fn registerClass(self: Host, class: *const ast.Class) !EvalUnitResult {
        if (self.vtable.register_class) |f| return f(self.ctx, class);
        return .{ .err = .{ .Unsupported = "Host::register_class" } };
    }

    /// Register a local class declaration with captured outer locals.
    /// Default ignores captures and routes to `registerClass`.
    pub fn registerClassCaptured(self: Host, class: *const ast.Class, captured_names: []const []const u8, captures: []Value) !EvalUnitResult {
        if (self.vtable.register_class_captured) |f| return f(self.ctx, class, captured_names, captures);
        return self.registerClass(class);
    }

    /// Synthesise an anonymous-object instance from an `object {…}` AST
    /// node.
    pub fn buildObject(self: Host, node: *const ast.Expr, captured_names: []const []const u8, captures: []Value) !EvalValueResult {
        if (self.vtable.build_object) |f| return f(self.ctx, node, captured_names, captures);
        return .{ .err = .{ .Unsupported = "Host::build_object" } };
    }

    /// Invoke a callable with `this_value` bound as the implicit
    /// receiver inside the body.
    pub fn callValueWithThis(self: Host, callee: *const Value, this_value: *const Value, args: []const Value, arg_names: []const ?[]const u8) !EvalValueResult {
        if (self.vtable.call_value_with_this) |f| return f(self.ctx, callee, this_value, args, arg_names);
        return .{ .err = .{ .Unsupported = "Host::call_value_with_this" } };
    }

    /// Dispatch `super.name(args)` on `receiver` against the parent of
    /// `owner_class`.
    pub fn callSuper(self: Host, receiver: *const Value, owner_class: []const u8, qualifier: ?[]const u8, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) !EvalValueResult {
        if (self.vtable.call_super) |f| return f(self.ctx, receiver, owner_class, qualifier, name, args, arg_names);
        return .{ .err = .{ .Unsupported = "Host::call_super" } };
    }

    /// Resolve `this@Qual` by walking the receiver's outer instance
    /// chain.
    pub fn qualifiedThis(self: Host, receiver: *const Value, qualifier: []const u8) !EvalValueResult {
        if (self.vtable.qualified_this) |f| return f(self.ctx, receiver, qualifier);
        return .{ .err = .{ .Unsupported = "Host::qualified_this" } };
    }

    /// Read a captured variable's current value out of a closure's env.
    pub fn readLambdaCapture(self: Host, lambda: *const Value, name: []const u8) !EvalValueResult {
        if (self.vtable.read_lambda_capture) |f| return f(self.ctx, lambda, name);
        return .{ .err = .{ .Unsupported = "Host::read_lambda_capture" } };
    }

    /// Resolve `receiver::name` to a callable reference value.
    pub fn memberRef(self: Host, receiver: *const Value, name: []const u8) !EvalValueResult {
        if (self.vtable.member_ref) |f| return f(self.ctx, receiver, name);
        return .{ .err = .{ .Unsupported = "Host::member_ref" } };
    }

    /// Materialise a closure value capturing the supplied register
    /// snapshot.
    pub fn buildClosure(self: Host, module: *const Module, body_func: FuncId, captures: []Value) !EvalValueResult {
        if (self.vtable.build_closure) |f| return f(self.ctx, module, body_func, captures);
        return .{ .err = .{ .Unsupported = "Host::build_closure" } };
    }

    /// Build a `Value.Lambda`-compatible closure straight from an AST
    /// block.
    pub fn buildAstLambda(self: Host, params: []const []const u8, body: *const ast.Block, captured_names: []const []const u8, captures: []Value) !EvalValueResult {
        if (self.vtable.build_ast_lambda) |f| return f(self.ctx, params, body, captured_names, captures);
        return .{ .err = .{ .Unsupported = "Host::build_ast_lambda" } };
    }

    /// Variant of `buildAstLambda` that threads the `absorb_return`
    /// flag. Default routes through `buildAstLambda`.
    pub fn buildAstLambdaWithFlag(self: Host, params: []const []const u8, body: *const ast.Block, captured_names: []const []const u8, captures: []Value, absorb_return: bool) !EvalValueResult {
        if (self.vtable.build_ast_lambda_with_flag) |f| return f(self.ctx, params, body, captured_names, captures, absorb_return);
        return self.buildAstLambda(params, body, captured_names, captures);
    }

    /// Variant that also receives the lambda body's lowered `FuncId`.
    /// Default ignores it and routes through `buildAstLambdaWithFlag`.
    pub fn buildAstLambdaWithFlagFuncid(self: Host, params: []const []const u8, body: *const ast.Block, captured_names: []const []const u8, captures: []Value, absorb_return: bool, body_func: ?FuncId) !EvalValueResult {
        if (self.vtable.build_ast_lambda_with_flag_funcid) |f| return f(self.ctx, params, body, captured_names, captures, absorb_return, body_func);
        return self.buildAstLambdaWithFlag(params, body, captured_names, captures, absorb_return);
    }

    /// Resolve a function call by `FuncId`. The default routes through
    /// `eval()` recursively so a single-module IR program stays
    /// self-contained.
    pub fn callFunc(self: Host, module: *const Module, func: FuncId, args: []Value) !EvalValueResult {
        if (self.vtable.call_func) |f| return f(self.ctx, module, func, args);
        return defaultCallFunc(module, func, args, self.allocator);
    }

    pub fn callFuncNamed(self: Host, module: *const Module, func: FuncId, args: []Value, arg_names: []const ?[]const u8) !EvalValueResult {
        if (self.vtable.call_func_named) |f| return f(self.ctx, module, func, args, arg_names);
        return self.callFunc(module, func, args);
    }

    /// Variant that carries call-site type arguments. The default
    /// ignores them and routes through `callFuncNamed`.
    pub fn callFuncTyped(self: Host, module: *const Module, func: FuncId, args: []Value, arg_names: []const ?[]const u8, type_args: []const []const u8, exact: bool) !EvalValueResult {
        if (self.vtable.call_func_typed) |f| return f(self.ctx, module, func, args, arg_names, type_args, exact);
        return self.callFuncNamed(module, func, args, arg_names);
    }

    /// Resolve a bare-name call against the top-level function table
    /// with runtime-argument overload selection. Default `Ok(None)`.
    pub fn callNamedOverload(self: Host, module: *const Module, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) !EvalOptValueResult {
        if (self.vtable.call_named_overload) |f| return f(self.ctx, module, name, args, arg_names);
        return .{ .ok = null };
    }

    /// The lexically enclosing `this` displaced by a receiver lambda.
    /// `None` outside a receiver lambda.
    pub fn enclosingThis(self: Host) ?Value {
        if (self.vtable.enclosing_this) |f| return f(self.ctx);
        return null;
    }

    /// The full lexically-enclosing-`this` chain, innermost first. The
    /// default returns the single `enclosingThis()` collected into a
    /// fresh owned slice (the caller frees it via `self.allocator`).
    pub fn enclosingThisChain(self: Host) !std.ArrayList(Value) {
        if (self.vtable.enclosing_this_chain) |f| {
            const owned = try f(self.ctx, self.allocator);
            var list: std.ArrayList(Value) = .empty;
            try list.appendSlice(self.allocator, owned);
            self.allocator.free(owned);
            return list;
        }
        var list: std.ArrayList(Value) = .empty;
        if (self.enclosingThis()) |v| try list.append(self.allocator, v);
        return list;
    }

    /// Report `(n_params, first_param_is_this)` for a callable. `None`
    /// when the callable isn't a shape the host can introspect.
    pub fn callableReceiverShape(self: Host, v: *const Value) ?ReceiverShape {
        if (self.vtable.callable_receiver_shape) |f| return f(self.ctx, v);
        return null;
    }

    /// True when the closure carries a captured `this` slot whose
    /// current value isn't a usable receiver.
    pub fn closureNeedsThisCapture(self: Host, v: *const Value) bool {
        if (self.vtable.closure_needs_this_capture) |f| return f(self.ctx, v);
        return false;
    }

    /// Override the closure's captured `this` slot with `new_this` for
    /// the duration of the impending invocation.
    pub fn overrideClosureThis(self: Host, v: *const Value, new_this: *const Value) void {
        if (self.vtable.override_closure_this) |f| f(self.ctx, v, new_this);
    }

    /// Resolve `name` as a *member* of `receiver` only — without
    /// falling back to a top-level extension, SAM dispatch, or a
    /// global. Default: the normal member call.
    pub fn callMemberOnly(self: Host, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) !EvalValueResult {
        if (self.vtable.call_member_only) |f| return f(self.ctx, receiver, name, args, arg_names);
        return self.callMemberNamed(receiver, name, args, arg_names);
    }

    /// Make `v` reachable as the lexically enclosing `this` for the
    /// duration of a member access. Default: no-op.
    pub fn pushAccessEnclosing(self: Host, v: *const Value) void {
        if (self.vtable.push_access_enclosing) |f| f(self.ctx, v);
    }
    pub fn popAccessEnclosing(self: Host) void {
        if (self.vtable.pop_access_enclosing) |f| f(self.ctx);
    }

    /// Stash an outer-`this` candidate for a soon-to-be-allocated
    /// inner-class instance. Default: no-op.
    pub fn pushInnerOuterHint(self: Host, v: *const Value) void {
        if (self.vtable.push_inner_outer_hint) |f| f(self.ctx, v);
    }
    pub fn popInnerOuterHint(self: Host) void {
        if (self.vtable.pop_inner_outer_hint) |f| f(self.ctx);
    }

    /// True when `name` is bound, in the innermost scoped-global layer,
    /// to a callable value. Default: false.
    pub fn isShadowingCapture(self: Host, name: []const u8) bool {
        if (self.vtable.is_shadowing_capture) |f| return f(self.ctx, name);
        return false;
    }
};

/// True when `fqn` ends with `".<name>"` — the suffix match the Rust
/// default `instance_of` used (`nominal.ends_with(&format!(".{name}"))`).
fn endsWithDotName(fqn: []const u8, name: []const u8) bool {
    if (fqn.len < name.len + 1) return false;
    const tail = fqn[fqn.len - name.len ..];
    if (!std.mem.eql(u8, tail, name)) return false;
    return fqn[fqn.len - name.len - 1] == '.';
}

/// The `call_func` default: look the function up by `FuncId` and run
/// its body through the eval root's `eval()`. Routed via the eval root
/// so a single-module IR program stays self-contained. While the eval
/// root is still a stub (no `eval` yet) this surfaces the same
/// unknown-id `Type` error for an out-of-range id and an `Unsupported`
/// marker for the body run, so wiring is visible until the root lands.
fn defaultCallFunc(module: *const Module, func: FuncId, args: []Value, allocator: Allocator) !EvalValueResult {
    const idx = func.int();
    if (idx >= module.funcs.items.len) {
        const msg = try std.fmt.allocPrint(allocator, "unknown FuncId {d}", .{idx});
        return .{ .err = .{ .Type = msg } };
    }
    const eval_root = @import("../eval.zig");
    if (!@hasDecl(eval_root, "eval")) {
        return .{ .err = .{ .Unsupported = "Host::call_func" } };
    }
    const f = &module.funcs.items[idx];
    return eval_root.eval(module, f, args);
}

/// No-op host for unit tests and IR-shape exercises. Every vtable slot
/// is left `null`, so each method takes its default behavior.
pub const NullHost = struct {
    /// Build a `Host` view over this `NullHost`. The `ctx` is unused by
    /// the all-default vtable, so any non-null pointer is fine; the
    /// `NullHost` value itself backs it.
    pub fn host(self: *NullHost, allocator: Allocator) Host {
        return .{ .ctx = self, .vtable = &vtable, .allocator = allocator };
    }

    const vtable: Host.VTable = .{};
};

// -------------------------------------------------------------------------
// Tests
//
// `host.rs` carries no `#[test]` blocks; these exercise the default
// vtable behaviors the wrapper methods implement so the surface is
// verified, not just type-checked.
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "null host reports unsupported for delegated dispatch" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    const callee: Value = .Unit;
    const r = try h.callValue(&callee, &.{});
    try testing.expect(r == .err);
    try testing.expect(r.err == .Unsupported);
    try testing.expectEqualStrings("Host::call_value", r.err.Unsupported);

    const m = try h.callMember(&callee, "f", &.{});
    try testing.expect(m == .err and m.err == .Unsupported);
    try testing.expectEqualStrings("Host::call_member", m.err.Unsupported);
}

test "null host has no members and no globals" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    const v: Value = .{ .Int = 1 };
    try testing.expect(!h.hostHasMember(&v, "x"));
    try testing.expect(h.lookupGlobal("y") == null);
    try testing.expect(!h.isShadowingCapture("z"));
    try testing.expect(h.callableReceiverShape(&v) == null);
    try testing.expect(!h.closureNeedsThisCapture(&v));
    try testing.expect(h.enclosingThis() == null);
}

test "instance_of default matches primitive fqn and dotted suffix" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    const i: Value = .{ .Int = 7 };
    const full = TypeRef{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try testing.expect(h.instanceOf(&i, &full));
    const simple = TypeRef{ .name = "Int", .nullable = false, .args = &.{} };
    try testing.expect(h.instanceOf(&i, &simple));
    const wrong = TypeRef{ .name = "String", .nullable = false, .args = &.{} };
    try testing.expect(!h.instanceOf(&i, &wrong));
}

test "is_concrete_cast_target default reports every name concrete" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    try testing.expect(h.isConcreteCastTarget("TBuilder"));
    try testing.expect(h.isConcreteCastTarget("Foo"));
}

test "get_field default errors on a non-instance receiver" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    const v: Value = .{ .Int = 3 };
    const r = try h.getField(&v, "name");
    try testing.expect(r == .err and r.err == .Type);
    try testing.expect(std.mem.startsWith(u8, r.err.Type, "GetField on non-instance:"));
    testing.allocator.free(r.err.Type);
}

test "set_field default is a no-op on null and errors on primitives" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    const nullv: Value = .Null;
    const ok = try h.setField(&nullv, "name", .{ .Int = 1 });
    try testing.expect(ok == .ok);

    const v: Value = .{ .Int = 3 };
    const r = try h.setField(&v, "name", .{ .Int = 1 });
    try testing.expect(r == .err and r.err == .Type);
    try testing.expect(std.mem.startsWith(u8, r.err.Type, "SetField on non-instance:"));
    testing.allocator.free(r.err.Type);
}

test "named variants forward to their unnamed defaults" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    const callee: Value = .Unit;
    const cv = try h.callValueNamed(&callee, &.{}, &.{});
    try testing.expect(cv == .err and cv.err == .Unsupported);
    try testing.expectEqualStrings("Host::call_value", cv.err.Unsupported);

    const cm = try h.callMemberNamed(&callee, "f", &.{}, &.{});
    try testing.expect(cm == .err and cm.err == .Unsupported);
    try testing.expectEqualStrings("Host::call_member", cm.err.Unsupported);

    // `call_member_only` defaults through `call_member_named`.
    const co = try h.callMemberOnly(&callee, "f", &.{}, &.{});
    try testing.expect(co == .err and co.err == .Unsupported);
    try testing.expectEqualStrings("Host::call_member", co.err.Unsupported);
}

test "lookup_global_throwing default forwards to lookup_global" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    const r = try h.lookupGlobalThrowing("x");
    try testing.expect(r == .ok and r.ok == null);
}

test "call_named_overload default reports no overload" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    const r = try h.callNamedOverload(&m, "foo", &.{}, &.{});
    try testing.expect(r == .ok and r.ok == null);
}

test "call_func default reports unknown FuncId out of range" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var args = [_]Value{};
    const r = try h.callFunc(&m, FuncId.from(0), &args);
    try testing.expect(r == .err and r.err == .Type);
    try testing.expect(std.mem.startsWith(u8, r.err.Type, "unknown FuncId"));
    testing.allocator.free(r.err.Type);
}

test "enclosing_this_chain default yields the single enclosing this" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    var chain = try h.enclosingThisChain();
    defer chain.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), chain.items.len);
}

test "stack-style hooks are no-ops on the null host" {
    var nh = NullHost{};
    const h = nh.host(testing.allocator);
    const v: Value = .Unit;
    h.pushAccessEnclosing(&v);
    h.popAccessEnclosing();
    h.pushInnerOuterHint(&v);
    h.popInnerOuterHint();
    h.overrideClosureThis(&v, &v);
}
