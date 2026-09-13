//! Bound callable references (`recv::name`): their parts, the adaptation
//! stamp a reference carries, and the `member_ref` entry point.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const Env = runtime.Env;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const EvalResult = ir.eval.EvalResult;

const common = @import("common.zig");
const ok = common.ok;
const typeHeadOf = common.typeHeadOf;

/// The parts of a bound/qualified callable reference synth
/// (`recv::name`): its name, receiver and adaptation stamp.
pub const BoundRefParts = struct { name: []const u8, receiver: Value, adapt: []const u8 };

pub fn boundRefParts(v: *const Value) ?BoundRefParts {
    if (v.* != .Instance) return null;
    const g = v.Instance.borrow();
    defer g.deinit();
    {
        const cg = g.get().class.borrow();
        defer cg.deinit();
        if (!std.mem.startsWith(u8, cg.get().name, "$bound_ref$")) return null;
    }
    const name_v = g.get().get("__bound_name__") orelse return null;
    if (name_v != .String) return null;
    const name = blk: {
        const sg = name_v.String.borrow();
        defer sg.deinit();
        break :blk sg.get().bytes;
    };
    const recv = g.get().get("__bound_receiver__") orelse Value.Null;
    const adapt: []const u8 = blk: {
        const av = g.get().get("__adapt__") orelse break :blk "";
        if (av != .String) break :blk "";
        const ag = av.String.borrow();
        defer ag.deinit();
        break :blk ag.get().bytes;
    };
    return .{ .name = name, .receiver = recv, .adapt = adapt };
}

/// A reference taken at a function-typed slot whose shape differs from the
/// target's signature (fewer values through defaults or a vararg, more
/// through a vararg, or a result coerced to Unit) is an adapted reference:
/// stamp the synth so equality tells the adaptations apart.
pub fn stampRefAdaptation(self: *VmHost, allocator: Allocator, v: *const Value, name: []const u8, exact: ?ir.FuncId, arity: i16, unit: bool, heads: ?[]const u8) Allocator.Error!void {
    if (v.* != .Instance) return;
    const parts = boundRefParts(v) orelse return;
    const bound = parts.receiver != .Class;
    var declared: ?usize = null;
    var returns_unit = true;
    var has_vararg = false;
    var vararg_at: ?usize = null;
    if (exact) |fid| {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().funcById(fid)) |f| {
            const skip: usize = if (bound and f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
            declared = f.params.len - skip;
            returns_unit = std.mem.eql(u8, typeHeadOf(f.return_ty.name), "Unit");
            for (f.params, 0..) |*prm, i| if (prm.is_vararg) {
                has_vararg = true;
                vararg_at = i - skip + @as(usize, if (bound) 0 else 1);
            };
        }
    } else {
        const cls: ?runtime.ObjRef(runtime.ClassDef) = switch (parts.receiver) {
            .Instance => |inst| blk: {
                const ig = inst.borrow();
                defer ig.deinit();
                break :blk ig.get().class.clone();
            },
            .Class => |c| c.clone(),
            else => null,
        };
        if (cls) |c| {
            defer c.deinit();
            if (runtime.ClassDef.findMethod(c, allocator, name)) |hit| {
                defer hit.class.deinit();
                const decl = hit.method.decl.get();
                declared = decl.params.len + @as(usize, if (bound) 0 else 1);
                returns_unit = if (decl.return_type) |*rt| std.mem.eql(u8, typeHeadOf(rt.name.name), "Unit") else (if (decl.body) |bd| bd == .Block else false);
                for (decl.params, 0..) |*prm, i| if (prm.is_vararg) {
                    has_vararg = true;
                    vararg_at = i + @as(usize, if (bound) 0 else 1);
                };
            } else {
                // A module class keeps its methods in the IR module: walk the
                // class chain by fqn through the member index.
                const mg = self.module.borrow();
                defer mg.deinit();
                var cur: ?runtime.ObjRef(runtime.ClassDef) = c.clone();
                while (cur) |cd| {
                    const fqn = blk: {
                        const dg = cd.borrow();
                        defer dg.deinit();
                        break :blk if (dg.get().fqn.len != 0) dg.get().fqn else dg.get().name;
                    };
                    const ids = mg.get().memberDecls(fqn, name);
                    if (ids.len != 0) {
                        if (mg.get().funcById(ids[0])) |f| {
                            const skip: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
                            declared = (f.params.len - skip) + @as(usize, if (bound) 0 else 1);
                            returns_unit = std.mem.eql(u8, typeHeadOf(f.return_ty.name), "Unit");
                            for (f.params, 0..) |*prm, i| if (prm.is_vararg) {
                                has_vararg = true;
                                vararg_at = (i - skip) + @as(usize, if (bound) 0 else 1);
                            };
                        }
                        cd.deinit();
                        break;
                    }
                    const next: ?runtime.ObjRef(runtime.ClassDef) = blk: {
                        const dg = cd.borrow();
                        defer dg.deinit();
                        break :blk if (dg.get().parent) |pp| pp.clone() else null;
                    };
                    cd.deinit();
                    cur = next;
                }
            }
        }
    }
    const want: usize = @intCast(arity);
    const decl = declared orelse return;
    // A vararg parameter adapts unless the slot expects the array itself.
    const vararg_adapts = blk: {
        const vi = vararg_at orelse break :blk false;
        const hs = heads orelse break :blk want != decl;
        var it = std.mem.splitScalar(u8, hs, '|');
        var idx: usize = 0;
        while (it.next()) |h| : (idx += 1) {
            if (idx == vi) break :blk !(std.mem.eql(u8, h, "Array") or std.mem.endsWith(u8, h, "Array"));
        }
        break :blk true;
    };
    const adapted = (want != decl and (want < decl or has_vararg)) or (unit and !returns_unit) or vararg_adapts;
    if (!adapted) return;
    const stamp = try std.fmt.allocPrint(allocator, "{d}|{s}", .{ want, if (unit and !returns_unit) "unit" else "value" });
    const g = v.Instance.borrowMut();
    defer g.deinit();
    try g.get().define(allocator, "__adapt__", .{ .String = try runtime.strInitOwned(allocator, stamp) });
}

/// Per-candidate probe for the bare-name resolver's innermost-first walk:
/// resolves only what the receiver itself owns — instance fields,
/// declared properties and their getters, applicable extension
/// properties, builtin member properties. Every global / outer-receiver /
/// companion adoption tail is disabled, so a candidate cannot "resolve" a
/// name it does not own and shadow a real member of a receiver further
/// out; the walk's own terminal arm decides the global fallback, and
/// companions ride the walk as their own candidates.
/// Does class `cn` declare property `name` as a STORED member — a body
/// `val`/`var` or a constructor-parameter property — as opposed to a custom
/// accessor? Such a declaration overrides an inherited accessor-based property,
/// so the setter walk must store the field directly rather than fall through to
/// a supertype's custom setter (`override var x = 0` shadowing `open var x
/// set(...)`).
pub fn classDeclaresStoredProp(self: *VmHost, cn: []const u8, name: []const u8) bool {
    const cg = self.classes.borrow();
    defer cg.deinit();
    const def = cg.get().get(cn) orelse return false;
    const dg = def.borrow();
    defer dg.deinit();
    for (dg.get().body_properties) |p| {
        if (std.mem.eql(u8, p.name, name)) return true;
    }
    for (dg.get().primary_params) |p| {
        if (p.property != null and std.mem.eql(u8, p.name, name)) return true;
    }
    return false;
}

/// Whether stored-field `fname` is the property a scope-qualified
/// `$sgetter$<owner>\u{1f}<prop>` read named: the full name ends with the
/// separator + the field name. Used by the (class, name) memo and the
/// GetField site memo so entries keyed by the FULL scoped name can serve a
/// stored slot whose field is stored under the bare property name.
pub fn sgetterNameMatches(full: []const u8, fname: []const u8) bool {
    if (!std.mem.startsWith(u8, full, "$sgetter$")) return false;
    if (full.len <= fname.len) return false;
    if (!std.mem.endsWith(u8, full, fname)) return false;
    return full[full.len - fname.len - 1] == '\u{1f}';
}

// -------------------------------------------------------------------------
// member_ref
// -------------------------------------------------------------------------

pub fn memberRef(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    // `X::class` is a class reference, not a member ref.
    if (std.mem.eql(u8, name, "class")) {
        if (receiver.* == .Instance) {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            return ok(.{ .Class = g.get().class.clone() });
        }
        return ok(receiver.*);
    }
    // `recv::method` -> a tiny synth Instance whose `__bound_receiver__` /
    // `__bound_name__` fields drive the call_value path.
    const identity = blk: {
        const g = self.instance_id_counter.borrowMut();
        defer g.deinit();
        break :blk g.get().fetchAdd(1, .monotonic) + 1;
    };
    const synth_name = try std.fmt.allocPrint(allocator, "$bound_ref${s}", .{name});
    const synth_class = try ObjRef(ClassDef).init(allocator, .{
        .name = synth_name,
        .fqn = synth_name,
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
        .captured_env = try ObjRef(Env).init(allocator, Env.init(allocator)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    });
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(allocator, .{ .name = "__bound_receiver__", .value = receiver.* });
    try fields.append(allocator, .{ .name = "__bound_name__", .value = .{ .String = try runtime.strInit(allocator, name) } });
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = synth_class,
        .fields = fields,
        .outer = null,
        .identity = identity,
        .native_state = null,
    });
    return ok(.{ .Instance = inst });
}
