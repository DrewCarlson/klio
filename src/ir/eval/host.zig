//! The evaluator host interface and the null host used when no interpreter is driving.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const Module = ir.Module;
const TypeRef = ir.TypeRef;

const exec_call = @import("../exec_call.zig");

const declaringClassName = exec_call.declaringClassName;

const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_state = @import("state.zig");

const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const errResult = ev_flow.errResult;
const eval = ev_enter.eval;
const ok = ev_flow.ok;

/// Result of the value-returning host lookups: an absent value is `ok: null`, not an error.
pub const MaybeValueResult = union(enum) {
    ok: ?Value,
    err: EvalError,
};

pub const UnitResult = union(enum) {
    ok: void,
    err: EvalError,
};

pub const ReceiverShape = struct { n_params: usize, first_is_this: bool };

/// No-op host for ir's own tests and the default for the bare `eval` entry: every method returns the
/// trait default (`Unsupported`/`null`/`false`/empty). The evaluator is generic over the host type.
pub const NullHost = struct {
    pub fn callValue(self: *NullHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!EvalResult {
        _ = .{ self, allocator, callee, args };
        return errResult(.{ .Unsupported = "Host.call_value" });
    }

    pub fn callValueNamed(self: *NullHost, allocator: Allocator, callee: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        _ = arg_names;
        return self.callValue(allocator, callee, args);
    }

    pub fn callMember(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!EvalResult {
        _ = .{ self, allocator, receiver, name, args };
        return errResult(.{ .Unsupported = "Host.call_member" });
    }

    pub fn callMemberNamed(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        _ = arg_names;
        return self.callMember(allocator, receiver, name, args);
    }

    pub fn committedExtReceiverProven(self: *NullHost, allocator: Allocator, fid: FuncId, recv: *const Value) bool {
        _ = self;
        _ = allocator;
        _ = fid;
        _ = recv;
        return false;
    }
    pub fn committedExtReceiverDisproven(self: *NullHost, fid: FuncId, recv: *const Value) bool {
        _ = self;
        _ = fid;
        _ = recv;
        return true;
    }
    pub fn callMemberMembersOnlyLenient(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
        _ = static_recv;
        return self.callMemberNamed(allocator, receiver, name, args, arg_names);
    }
    pub fn callMemberMembersOnly(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
        _ = static_recv;
        return self.callMemberNamed(allocator, receiver, name, args, arg_names);
    }
    pub fn callMemberStrictExt(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
        _ = static_recv;
        return self.callMemberNamed(allocator, receiver, name, args, arg_names);
    }

    pub fn callMemberNamedDeclared(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, declared_recv: ?[]const u8) Allocator.Error!EvalResult {
        _ = declared_recv;
        return self.callMemberNamed(allocator, receiver, name, args, arg_names);
    }
    pub fn callMemberNamedStatic(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, static_recv: ?[]const u8) Allocator.Error!EvalResult {
        _ = static_recv;
        return self.callMemberNamed(allocator, receiver, name, args, arg_names);
    }

    pub fn hostHasMember(self: *NullHost, receiver: *const Value, name: []const u8) bool {
        _ = .{ self, receiver, name };
        return false;
    }

    pub fn hostHasProperty(self: *NullHost, receiver: *const Value, name: []const u8) bool {
        _ = .{ self, receiver, name };
        return false;
    }

    pub fn hostHasExtPropSetter(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) bool {
        _ = .{ self, allocator, receiver, name };
        return false;
    }

    pub fn companionWithMember(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?Value {
        _ = .{ self, allocator, receiver, name };
        return null;
    }

    pub fn declaringClassSimpleName(self: *NullHost, module: *const Module, fid: ir.FuncId) ?[]const u8 {
        _ = self;
        return declaringClassName(module, fid);
    }

    pub fn newInstance(self: *NullHost, allocator: Allocator, class: ClassId, args: []const Value) Allocator.Error!EvalResult {
        _ = .{ self, allocator, class, args };
        return errResult(.{ .Unsupported = "Host.new_instance" });
    }

    pub fn newInstanceNamed(self: *NullHost, allocator: Allocator, class: ClassId, args: []const Value, arg_names: []const ?[]const u8, outer_hint: ?*const Value) Allocator.Error!EvalResult {
        _ = .{ arg_names, outer_hint };
        return self.newInstance(allocator, class, args);
    }

    pub fn getMemberField(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
        _ = self;
        // Strict probe contract: a miss is an error, never a spurious `Null`/`Unit`, so the walk's candidate order stays honest.
        if (receiver.* == .Instance) {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            if (g.get().get(name)) |v| return ok(v);
        }
        const msg = try std.fmt.allocPrint(allocator, "no member `{s}`", .{name});
        return errResult(.{ .Unimplemented = msg });
    }
    pub fn getMemberFieldNoExt(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
        _ = self;
        if (receiver.* == .Instance) {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            if (g.get().get(name)) |v| return ok(v);
        }
        const msg = try std.fmt.allocPrint(allocator, "no member `{s}`", .{name});
        return errResult(.{ .Unimplemented = msg });
    }

    pub fn getField(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
        _ = self;
        switch (receiver.*) {
            .Instance => |inst| {
                const g = inst.borrow();
                defer g.deinit();
                return ok(g.get().get(name) orelse Value.Null);
            },
            else => {
                const s = receiver.display(allocator) catch "?";
                const msg = try std.fmt.allocPrint(allocator, "GetField on non-instance: {s}", .{s});
                return errResult(.{ .Type = msg });
            },
        }
    }

    /// The bare-IR host has no class table, so a `super.prop = v` write has nothing to walk past: store the field.
    pub fn setFieldFrom(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, value: Value, super_owner: ?[]const u8) Allocator.Error!UnitResult {
        _ = super_owner;
        return setField(self, allocator, receiver, name, value);
    }

    pub fn setField(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, value: Value) Allocator.Error!UnitResult {
        _ = self;
        switch (receiver.*) {
            .Instance => |inst| {
                const g = inst.borrowMut();
                defer g.deinit();
                try g.get().define(allocator, name, value);
                return .{ .ok = {} };
            },
            .Null => return .{ .ok = {} },
            else => {
                const s = receiver.display(allocator) catch "?";
                const msg = try std.fmt.allocPrint(allocator, "SetField on non-instance: {s}", .{s});
                return .{ .err = .{ .Type = msg } };
            },
        }
    }

    pub fn instanceOf(self: *NullHost, value: *const Value, ty: TypeRef) bool {
        _ = self;
        const nominal = value.typeFqn();
        if (std.mem.eql(u8, nominal, ty.name)) return true;
        if (nominal.len > ty.name.len + 1 and
            nominal[nominal.len - ty.name.len - 1] == '.' and
            std.mem.eql(u8, nominal[nominal.len - ty.name.len ..], ty.name))
        {
            return true;
        }
        return false;
    }

    pub fn isConcreteCastTarget(self: *NullHost, name: []const u8) bool {
        _ = .{ self, name };
        return true;
    }

    pub fn lookupGlobal(self: *NullHost, name: []const u8) ?Value {
        _ = .{ self, name };
        return null;
    }

    pub fn lookupGlobalThrowing(self: *NullHost, allocator: Allocator, name: []const u8) Allocator.Error!MaybeValueResult {
        _ = allocator;
        return .{ .ok = self.lookupGlobal(name) };
    }

    pub fn lookupGlobalById(self: *NullHost, allocator: Allocator, func: ?FuncId, class: ?ClassId, ctor_ref: bool) ?Value {
        _ = ctor_ref;
        _ = .{ self, allocator, func, class };
        return null;
    }

    pub fn storeGlobal(self: *NullHost, allocator: Allocator, name: []const u8, value: Value) Allocator.Error!UnitResult {
        _ = .{ self, allocator, name, value };
        return .{ .err = .{ .Unsupported = "Host.store_global" } };
    }

    pub fn registerClass(self: *NullHost, allocator: Allocator, class: *const @import("ast").Class) Allocator.Error!UnitResult {
        _ = .{ self, allocator, class };
        return .{ .err = .{ .Unsupported = "Host.register_class" } };
    }

    pub fn registerClassCaptured(self: *NullHost, allocator: Allocator, class: *const @import("ast").Class, captured_names: []const []const u8, captures: []const Value) Allocator.Error!UnitResult {
        _ = .{ captured_names, captures };
        return self.registerClass(allocator, class);
    }

    pub fn buildObject(self: *NullHost, allocator: Allocator, ast: *const @import("ast").Expr, captured_names: []const []const u8, captures: []const Value, scope_renames: []const ir.ScopeRename, scope_classes: []const ir.ScopeClassRef) Allocator.Error!EvalResult {
        _ = .{ self, allocator, ast, captured_names, captures, scope_renames, scope_classes };
        return errResult(.{ .Unsupported = "Host.build_object" });
    }

    pub fn callValueWithThis(self: *NullHost, allocator: Allocator, callee: *const Value, this_value: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        _ = .{ self, allocator, callee, this_value, args, arg_names };
        return errResult(.{ .Unsupported = "Host.call_value_with_this" });
    }

    pub fn callValueWithThisExact(self: *NullHost, allocator: Allocator, callee: *const Value, this_value: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        return self.callValueWithThis(allocator, callee, this_value, args, arg_names);
    }

    pub fn callSuper(self: *NullHost, allocator: Allocator, receiver: *const Value, owner_class: []const u8, qualifier: ?[]const u8, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        _ = .{ self, allocator, receiver, owner_class, qualifier, name, args, arg_names };
        return errResult(.{ .Unsupported = "Host.call_super" });
    }

    pub fn qualifiedThis(self: *NullHost, allocator: Allocator, receiver: *const Value, qualifier: []const u8) Allocator.Error!EvalResult {
        _ = .{ self, allocator, receiver, qualifier };
        return errResult(.{ .Unsupported = "Host.qualified_this" });
    }

    pub fn memberRef(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
        _ = .{ self, allocator, receiver, name };
        return errResult(.{ .Unsupported = "Host.member_ref" });
    }

    pub fn memberRefExact(self: *NullHost, allocator: Allocator, receiver: *const Value, name: []const u8, func: FuncId) Allocator.Error!EvalResult {
        _ = func;
        return self.memberRef(allocator, receiver, name);
    }

    pub fn buildClosure(self: *NullHost, allocator: Allocator, module: *const Module, body_func: FuncId, captures: []const Value) Allocator.Error!EvalResult {
        _ = .{ self, allocator, module, body_func, captures };
        return errResult(.{ .Unsupported = "Host.build_closure" });
    }

    pub fn buildAstLambda(self: *NullHost, allocator: Allocator, params: []const []const u8, body: *const @import("ast").Block, captured_names: []const []const u8, captures: []const Value) Allocator.Error!EvalResult {
        _ = .{ self, allocator, params, body, captured_names, captures };
        return errResult(.{ .Unsupported = "Host.build_ast_lambda" });
    }

    pub fn buildAstLambdaWithFlag(self: *NullHost, allocator: Allocator, params: []const []const u8, body: *const @import("ast").Block, captured_names: []const []const u8, captures: []const Value, absorb_return: bool) Allocator.Error!EvalResult {
        _ = absorb_return;
        return self.buildAstLambda(allocator, params, body, captured_names, captures);
    }

    pub fn buildAstLambdaWithFlagFuncid(self: *NullHost, allocator: Allocator, module: *const Module, params: []const []const u8, body: *const @import("ast").Block, captured_names: []const []const u8, captures: []const Value, absorb_return: bool, body_func: ?FuncId) Allocator.Error!EvalResult {
        _ = .{ module, body_func };
        return self.buildAstLambdaWithFlag(allocator, params, body, captured_names, captures, absorb_return);
    }

    pub fn callFunc(self: *NullHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value) Allocator.Error!EvalResult {
        _ = self;
        const f = module.funcById(func) orelse {
            const msg = try std.fmt.allocPrint(allocator, "unknown FuncId {d}", .{func.int()});
            return errResult(.{ .Type = msg });
        };
        var args_list: std.ArrayList(Value) = .empty;
        try args_list.appendSlice(allocator, args);
        return eval(allocator, module, f, args_list);
    }

    pub fn callFuncNamed(self: *NullHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
        _ = arg_names;
        return self.callFunc(allocator, module, func, args);
    }

    pub fn callFuncTyped(self: *NullHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8, type_args: []const []const u8, exact: bool) Allocator.Error!EvalResult {
        _ = .{ type_args, exact };
        return self.callFuncNamed(allocator, module, func, args, arg_names);
    }

    pub fn callNamedOverload(self: *NullHost, allocator: Allocator, module: *const Module, candidates: ?[]const FuncId, name: []const u8, args: []const Value, arg_names: []const ?[]const u8, ctor_class: ?ir.ClassId, ctor_name: bool, caller_pkg: []const u8, caller_file: ?ir.FileId, synth_anchor_pkg: []const u8) Allocator.Error!MaybeValueResult {
        _ = caller_pkg;
        _ = caller_file;
        _ = synth_anchor_pkg;
        _ = .{ self, allocator, module, candidates, name, args, arg_names, ctor_class, ctor_name };
        return .{ .ok = null };
    }

    pub fn pickNamedOverloadId(self: *NullHost, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8, recv_external: bool) ?FuncId {
        _ = .{ self, module, args, arg_names, recv_external };
        _ = func;
        return null;
    }

    pub fn bareUnsettledHeaderNoOp(self: *NullHost, module: *const Module, name: []const u8, argc: usize) bool {
        _ = .{ self, module, name, argc };
        return false;
    }

    pub fn callableAcceptsCall(self: *NullHost, v: *const Value, recv: *const Value, args2: []const Value, arg_names2: []const ?[]const u8) ?bool {
        _ = .{ self, v, recv, args2, arg_names2 };
        return null;
    }

    pub fn callableAcceptsArgs(self: *NullHost, v: *const Value, n_args: usize) ?bool {
        _ = .{ self, v, n_args };
        return null;
    }

    pub fn callValueNamedTyped(self: *NullHost, allocator: Allocator, callee: *const Value, args: []const Value, arg_names: []const ?[]const u8, type_args: []const []const u8) Allocator.Error!EvalResult {
        _ = type_args;
        return self.callValueNamed(allocator, callee, args, arg_names);
    }

    pub fn collectionsEqualHostAware(self: *NullHost, allocator: Allocator, a: *const Value, b: *const Value) ?bool {
        _ = .{ self, allocator, a, b };
        return null;
    }

    pub fn callableReceiverShape(self: *NullHost, v: *const Value) ?ReceiverShape {
        _ = .{ self, v };
        return null;
    }

    pub fn closureNeedsThisCapture(self: *NullHost, v: *const Value) bool {
        _ = .{ self, v };
        return false;
    }

    pub fn overrideClosureThis(self: *NullHost, v: *const Value, new_this: *const Value) void {
        _ = .{ self, v, new_this };
    }

    pub fn isShadowingCapture(self: *NullHost, name: []const u8) bool {
        _ = .{ self, name };
        return false;
    }
};

pub fn nullHost() NullHost {
    return .{};
}
