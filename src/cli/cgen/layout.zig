//! Class layout: a class's fields in the order the runtime lays them out, and
//! the name-to-index lookups that read them.
const std = @import("std");
const ir = @import("ir");
const Module = ir.Module;
const cgen = @import("../cgen.zig");

const ARRAY_CLS = cgen.ARRAY_CLS;
const ClassLayout = cgen.ClassLayout;
const Error = cgen.Error;
const FieldInfo = cgen.FieldInfo;
const Global = cgen.Global;
const LIST_CLS = cgen.LIST_CLS;
const Laid = cgen.Laid;
const Parent = cgen.Parent;
const Program = cgen.Program;
const STRING_CLS = cgen.STRING_CLS;
const Ty = cgen.Ty;
const ctorDefault = cgen.ctorDefault;
const eligible = cgen.eligible;
const funcCls = cgen.funcCls;
const functionTypeArity = cgen.functionTypeArity;
const isArrayTypeName = cgen.isArrayTypeName;
const layoutFor = cgen.layoutFor;
const layoutNo = cgen.layoutNo;
const layoutNoTy = cgen.layoutNoTy;
const no = cgen.no;
const refElemOf = cgen.refElemOf;
const traceOn = cgen.traceOn;
const tyOf = cgen.tyOf;

/// A class's instance fields in layout order: constructor properties, then body
/// properties. Null for a class the emitter cannot lay out.
pub fn classFields(gpa: std.mem.Allocator, m: *const Module, layouts: []const ClassLayout, cid: ir.ClassId, prev: ?*const Program, globals: []const Global, last: bool) Error!?Laid {
    return classFieldsAt(gpa, m, layouts, cid, 0, prev, globals, last);
}

pub fn classFieldsAt(gpa: std.mem.Allocator, m: *const Module, layouts: []const ClassLayout, cid: ir.ClassId, depth: u32, prev: ?*const Program, globals: []const Global, last: bool) Error!?Laid {
    if (cid.int() >= m.classes.items.len) return null;
    const c = &m.classes.items[cid.int()];
    // A cycle in the class table would recurse forever; real hierarchies are shallow.
    if (depth > 32) return layoutNo(c, "inheritance depth");
    if (c.init_block != null) return layoutNo(c, "init block");
    // An interface contributes no fields; a superclass's are laid out ahead of this
    // class's, so a field index means the same thing through either type.
    var parent_id: ?ir.ClassId = null;
    for (c.supertypes) |sid| {
        if (sid.int() >= m.classes.items.len) return layoutNo(c, "unknown supertype");
        const sup = &m.classes.items[sid.int()];
        if (sup.is_interface) continue;
        if (parent_id != null) return layoutNo(c, "several superclasses");
        parent_id = sid;
    }
    if (c.is_interface) return layoutNo(c, "interface");
    // An `object` declares no constructor: its fields are its body properties.
    if (c.is_object and c.primary_params.len != 0) return layoutNo(c, "object with constructor params");
    if (c.is_inner) return layoutNo(c, "inner class");

    var out: std.ArrayList(FieldInfo) = .empty;
    errdefer out.deinit(gpa);
    if (c.is_enum) {
        // Entry construction fills `name` and `ordinal`, not the enum's constructor.
        try out.append(gpa, .{ .name = "name", .ty = .object, .cls = STRING_CLS, .arg = null, .init = null, .preset = true });
        try out.append(gpa, .{ .name = "ordinal", .ty = .i32, .cls = null, .arg = null, .init = null, .preset = true });
    }
    var parent: ?Parent = null;
    if (parent_id) |sid| {
        // Superclass fields come first and keep their own layout, so a field read
        // through either type addresses the same slot; its initializer fills them.
        const up = (try classFieldsAt(gpa, m, layouts, sid, depth + 1, prev, globals, last)) orelse {
            out.deinit(gpa);
            return layoutNo(c, "superclass layout");
        };
        defer gpa.free(up.fields);
        const sup = &m.classes.items[sid.int()];
        const pargs: []const ir.FuncId = if (layoutFor(layouts, c)) |l| l.parent_args else &.{};
        if (pargs.len != sup.primary_params.len) {
            out.deinit(gpa);
            return layoutNo(c, "super constructor arity");
        }
        for (up.fields) |fd| {
            try out.append(gpa, .{
                .name = fd.name,
                .ty = fd.ty,
                .cls = fd.cls,
                .elem = fd.elem,
                .arg = null,
                .init = null,
                .from_parent = true,
            });
        }
        parent = .{ .cid = sid.int(), .args = pargs };
    }
    for (c.primary_params, 0..) |p, i| {
        // A constructor parameter that is not a property is an input, not a field.
        if (!p.is_property) continue;
        if (p.is_vararg) {
            out.deinit(gpa);
            return layoutNo(c, "ctor param vararg");
        }
        if (p.default != null and ctorDefault(layouts, c, i) == null) {
            out.deinit(gpa);
            return layoutNo(c, "ctor param default without a thunk");
        }
        // Generics erase: a type the module has no class for is still a reference, and
        // every use of it that needs a layout refuses on its own.
        const t = tyOf(p.ty) orelse Ty.object;
        try out.append(gpa, .{
            .name = p.name,
            .ty = t,
            .cls = if (t == .object) classIndexOfName(m, p.ty) else null,
            .elem = if (t == .object) (refElemOf(classIndexOfName(m, p.ty), p.ty) orelse .unit) else .unit,
            .arg = @intCast(i),
            .init = null,
        });
    }
    var complete = true;
    if (layoutFor(layouts, c)) |l| {
        complete = false;
        inc: for (l.props) |bp| {
            // A computed or abstract property stores nothing, so it takes no slot.
            if (!bp.has_backing or bp.is_abstract) continue;
            // A `lateinit var` reads as a throw until assigned, which needs the unset marker.
            if (bp.is_lateinit) {
                out.deinit(gpa);
                return layoutNo(c, "lateinit property");
            }
            if (bp.init == null and !bp.zero_init) {
                out.deinit(gpa);
                return layoutNo(c, "body property without an initializer");
            }
            var fcls: ?u32 = null;
            var felem: Ty = .unit;
            const t = tyOf(bp.ty) orelse blk: {
                if (bp.ty.name.len != 0) {
                    fcls = classIndexOfName(m, bp.ty);
                    break :blk Ty.object;
                }
                // An unannotated property's type is whatever its initializer computes, which
                // needs the layouts resolved so far, so the table is built to a fixed point.
                if (last and prev == null) {
                    out.deinit(gpa);
                    return layoutNoTy(c, "body property type", bp.ty);
                }
                const pv = prev orelse break :inc;
                const ifn = m.funcById(bp.init orelse break :inc) orelse break :inc;
                var ic = (try eligible(gpa, m, pv.*, ifn, globals, null, &.{})) orelse {
                    if (traceOn() and last) {
                        std.debug.print("[cgen] layout {s}: property `{s}` has no compilable initializer\n", .{ c.name, bp.name });
                    }
                    if (!last) break :inc;
                    out.deinit(gpa);
                    return layoutNoTy(c, "body property type", bp.ty);
                };
                defer ic.deinit(gpa);
                fcls = ic.ret_cls;
                felem = ic.ret_elem;
                break :blk ic.ret;
            };
            try out.append(gpa, .{
                .name = bp.name,
                .ty = t,
                .cls = if (t == .object) (fcls orelse classIndexOfName(m, bp.ty)) else null,
                .elem = if (t == .object) (refElemOf(fcls orelse classIndexOfName(m, bp.ty), bp.ty) orelse felem) else .unit,
                .arg = null,
                .init = bp.init,
            });
            continue;
        } else {
            complete = true;
        }
    }
    return .{ .fields = try out.toOwnedSlice(gpa), .parent = parent, .complete = complete };
}

/// Whether the name spells the BACKING FIELD rather than the property: the
/// lowering marks a `field` read or write inside an accessor this way. The
/// `$sgetter$<owner>` form is not one, but an ordinary property read.
pub fn isBackingAccess(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__klio_field__");
}

pub fn plainFieldName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "$sgetter$") or std.mem.startsWith(u8, name, "$ssetter$")) {
        if (std.mem.findScalarLast(u8, name, 0x1f)) |i| return name[i + 1 ..];
    }
    if (std.mem.startsWith(u8, name, "__klio_field__")) return name["__klio_field__".len..];
    return name;
}

pub fn fieldIndex(prog: Program, cid: u32, name: []const u8) ?u32 {
    const fields = prog.of(cid) orelse return null;
    const want = plainFieldName(name);
    for (fields, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, want)) return @intCast(i);
    }
    return null;
}

/// The class a declared type NAMES, without asking whether its layout exists:
/// demanding one would recurse on a class holding its own kind and would refuse
/// interface types outright. The layout is demanded where a field is read.
pub fn classIndexOfName(m: *const Module, t: ir.TypeRef) ?u32 {
    if (t.name.len == 0) return null;
    if (std.mem.eql(u8, t.name, "String") or std.mem.eql(u8, t.name, "kotlin.String")) return STRING_CLS;
    if (std.mem.eql(u8, t.name, "List") or std.mem.eql(u8, t.name, "MutableList")) return LIST_CLS;
    if (isArrayTypeName(t.name)) return ARRAY_CLS;
    if (functionTypeArity(t.name)) |ar| return funcCls(ar);
    for (m.classes.items, 0..) |*c, i| {
        if (std.mem.eql(u8, c.name, t.name) or std.mem.eql(u8, c.fqn, t.name)) return @intCast(i);
    }
    return null;
}
