//! Primary-constructor defaults and vararg packing: the literal forms a default
//! expression serves without evaluation, and the vararg-aware arg packing.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const stdlib = @import("stdlib");

const root = @import("../../interp_ir.zig");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const host_classes = @import("../host_classes.zig");
const host_call_func = @import("../host_call_func.zig");
const host_call_member = @import("../host_call_member.zig");
const host_fields = @import("../host_fields.zig");
const host_call_value = @import("../host_call_value.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const build = @import("../../build.zig");
const FF = runtime.forest.ForestField;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ClassDef = runtime.ClassDef;
const Env = runtime.Env;
const PropertyDef = runtime.PropertyDef;
const MethodDef = runtime.MethodDef;
const SupertypeDelegate = runtime.SupertypeDelegate;
const TypeShape = runtime.TypeShape;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;
const Module = ir.Module;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const StrPair = ir.StrPair;
const StringSet = std.StringHashMap(void);
const AnonMethodEntry = root.AnonMethodEntry;
const NameValue = root.NameValue;

const ctor_select = @import("ctor_select.zig");
const scalarRetag = ctor_select.scalarRetag;
const scoreCtorHeads = ctor_select.scoreCtorHeads;
const typeHeadOfName = ctor_select.typeHeadOfName;

pub fn simpleLiteral(allocator: Allocator, e: *const ast.Expr) Allocator.Error!?Value {
    switch (e.*) {
        .IntLit => |l| return Value.newInt(l.value),
        .FloatLit => |l| return if (l.kind == .Float)
            Value{ .Float = @floatCast(l.value) }
        else
            Value{ .Double = l.value },
        .BoolLit => |l| return Value{ .Bool = l.value },
        .NullLit => return Value.Null,
        .CharLit => |l| return Value{ .Char = l.value },
        .StringTemplate => |t| {
            for (t.parts) |p| {
                if (p != .Text) return null;
            }
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            for (t.parts) |p| {
                try buf.appendSlice(allocator, p.Text);
            }
            const owned = try buf.toOwnedSlice(allocator);
            return Value{ .String = try runtime.strInitOwned(allocator, owned) };
        },
        else => return null,
    }
}

pub fn emptyList(allocator: Allocator, mutable: bool) Allocator.Error!Value {
    return try Value.newList(allocator, .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, .empty),
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
    });
}

pub fn emptySet(allocator: Allocator, mutable: bool) Allocator.Error!Value {
    return try Value.newSet(allocator, .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, .empty),
        .mutable = mutable,
        .backing = null,
    });
}

pub fn emptyMap(allocator: Allocator, mutable: bool) Allocator.Error!Value {
    return try Value.newMap(allocator, .{
        .entries = try runtime.MapEntries.init(allocator, .{}),
        .mutable = mutable,
    });
}

pub fn defaultValueForPrimary(allocator: Allocator, e: *const ast.Expr) Allocator.Error!?Value {
    if (try simpleLiteral(allocator, e)) |v| return v;
    if (e.* == .Call) {
        const c = e.Call;
        if (c.args.len != 0) return null;
        if (c.callee.* == .Path) {
            const segs = c.callee.Path.segments;
            if (segs.len == 1) {
                const nm = segs[0].name;
                const eq = std.mem.eql;
                if (eq(u8, nm, "mutableListOf") or eq(u8, nm, "arrayListOf") or eq(u8, nm, "ArrayList")) {
                    return try emptyList(allocator, true);
                }
                if (eq(u8, nm, "listOf") or eq(u8, nm, "emptyList")) {
                    return try emptyList(allocator, false);
                }
                if (eq(u8, nm, "mutableSetOf") or eq(u8, nm, "hashSetOf") or eq(u8, nm, "linkedSetOf")) {
                    return try emptySet(allocator, true);
                }
                if (eq(u8, nm, "setOf") or eq(u8, nm, "emptySet")) {
                    return try emptySet(allocator, false);
                }
                if (eq(u8, nm, "mutableMapOf") or eq(u8, nm, "hashMapOf") or eq(u8, nm, "linkedMapOf")) {
                    return try emptyMap(allocator, true);
                }
                if (eq(u8, nm, "mapOf") or eq(u8, nm, "emptyMap")) {
                    return try emptyMap(allocator, false);
                }
            }
        }
    }
    return null;
}

pub fn pathConstDefault(self: *VmHost, e: *const ast.Expr) Allocator.Error!?Value {
    if (e.* != .Path) return null;
    const segs = e.Path.segments;
    if (segs.len != 1) return null;
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    if (m.registry.class_const_inits.get(.{ .a = "", .b = segs[0].name })) |c| {
        return try ir.eval.constToValue(self.allocator, &c);
    }
    return null;
}

/// Index and element type of the primary constructor's `vararg` parameter.
/// Read from the module class; the runtime param defs drop the modifier.
pub fn primaryVarargParam(self: *VmHost, class_fqn: ?[]const u8, class_name: []const u8) struct { ?usize, []const u8 } {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    const cid = (if (class_fqn) |f| m.classIdByFqn(f) else null) orelse m.classId(class_name) orelse return .{ null, "" };
    if (cid.int() >= m.classes.items.len) return .{ null, "" };
    for (m.classes.items[cid.int()].primary_params, 0..) |ip, i| {
        if (ip.is_vararg) return .{ i, ip.ty.name };
    }
    return .{ null, "" };
}

/// Every parameter past `nargs` must have a default or be the absorbing vararg.
pub fn primaryCanTake(self: *VmHost, class_def: ObjRef(ClassDef), nargs: usize) bool {
    const dg = class_def.borrow();
    defer dg.deinit();
    const c = dg.get();
    if (!c.has_primary_ctor) return false;
    const vararg_at, _ = primaryVarargParam(self, c.fqn, c.name);
    if (nargs > c.primary_params.len) return vararg_at != null;
    var i = nargs;
    while (i < c.primary_params.len) : (i += 1) {
        if (vararg_at != null and vararg_at.? == i) continue;
        if (c.primary_params[i].default == null) return false;
    }
    return true;
}

/// `scoreCtorHeads` where parameter `vararg_at` is a `vararg`: args from there
/// score against the element type, but a lone array (a spread) scores nothing.
pub fn scoreCtorHeadsVararg(self: *VmHost, heads: []const []const u8, vararg_at: usize, args: []const Value) ?i32 {
    if (vararg_at >= heads.len) return scoreCtorHeads(self, heads, args);
    if (args.len == vararg_at + 1 and args[vararg_at] == .Array) {
        return scoreCtorHeads(self, heads[0..vararg_at], args[0..vararg_at]);
    }
    var buf: [32][]const u8 = undefined;
    if (args.len > buf.len) return scoreCtorHeads(self, heads, args);
    for (0..args.len) |i| buf[i] = if (i < vararg_at) heads[i] else heads[vararg_at];
    return scoreCtorHeads(self, buf[0..args.len], args);
}

/// Packs a `vararg` secondary constructor's trailing args into its array slot,
/// primitive-typed where the element type is. Null for a spread or no vararg.
pub fn packSecondaryVarargs(self: *VmHost, allocator: Allocator, e: root.build.SecondaryCtorEntry, args: []const Value) Allocator.Error!?[]Value {
    _ = self;
    const v = e.vararg_index orelse return null;
    if (args.len < v) return null;
    if (args.len == v + 1 and args[v] == .Array) return null;
    var out: std.ArrayList(Value) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, args[0..v]);
    var rest: std.ArrayList(Value) = .empty;
    try rest.appendSlice(allocator, args[v..]);
    // The packed array owns one reference per element.
    if (runtime.reclaimEnabled()) for (rest.items) |el| el.retain();
    const elem_head: []const u8 = if (v < e.param_type_heads.len) e.param_type_heads[v] else "";
    try out.append(allocator, try host_call_func.packVarargArray(allocator, elem_head, rest));
    return try out.toOwnedSlice(allocator);
}

/// Packs trailing positional args into the primary ctor's `vararg` slot;
/// `class_fqn` keys the module class exactly, excluding same-named classes.
pub fn packPrimaryCtorVarargs(self: *VmHost, class_fqn: ?[]const u8, class_name: []const u8, args: []Value) Allocator.Error![]Value {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    const by_fqn: ?ir.ClassId = if (class_fqn) |fq| m.classIdByFqn(fq) else null;
    const cid = by_fqn orelse m.classId(class_name) orelse return args;
    if (cid.int() >= m.classes.items.len) return args;
    const ir_cls = &m.classes.items[cid.int()];
    const params = ir_cls.primary_params;
    if (params.len == 0) return args;
    // An Int reaching a `Long`/`Short`/`Byte` parameter can only have been an
    // integer literal, so it retags before the init body and stores see it.
    for (args, 0..) |*arg, i| {
        if (i >= params.len) break;
        if (arg.* != .Int) continue;
        if (scalarRetag(typeHeadOfName(params[i].ty.name), arg.Int)) |rv| arg.* = rv;
    }
    const last = params[params.len - 1];
    if (!last.is_vararg) return args;
    const fixed = if (params.len == 0) 0 else params.len - 1;
    if (args.len == params.len and args.len > 0 and args[args.len - 1] == .Array) {
        return args;
    }
    var out: std.ArrayList(Value) = .empty;
    errdefer out.deinit(self.allocator);
    var i: usize = 0;
    while (i < fixed and i < args.len) : (i += 1) {
        try out.append(self.allocator, args[i]);
    }
    var rest: std.ArrayList(Value) = .empty;
    errdefer rest.deinit(self.allocator);
    var j: usize = fixed;
    while (j < args.len) : (j += 1) {
        try rest.append(self.allocator, args[j]);
    }
    try out.append(self.allocator, runtime.ArrayData.fromBoxedList(try ObjRef(std.ArrayList(Value)).init(self.allocator, rest)));
    self.allocator.free(args);
    return out.toOwnedSlice(self.allocator);
}
