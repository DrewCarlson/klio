//! Enum static access: the entry table behind `Enum.values()`/`valueOf`, leaf
//! static members, and the enclosing-enum lookups a bare entry name resolves
//! through.

const std = @import("std");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const host_globals = @import("../host_globals.zig");
const Value = runtime.Value;

/// Leaf statics route backing: resolve `Owner.member` for a genre-9
/// class handle inside a leaf body. ENUM ENTRIES ONLY — an entry is an
/// eager singleton stored on the ClassDef itself (language-mandated
/// identity), so its cell is rooted for the class's lifetime and
/// borrow-safe for the leaf's duration. Anything else (companion vals,
/// computed statics) returns null and the leaf bails to the exact
/// re-run.
/// The class whose `enum_entries` describe `cls`'s entries: `cls` itself,
/// or its parent when `cls` is the subclass synthesized for an entry with a
/// body (`is_enum`, no entries of its own, an enum parent).
pub fn enumTableClass(cls: runtime.ObjRef(runtime.ClassDef)) @TypeOf(cls.borrow()) {
    const g = cls.borrow();
    if (g.get().is_enum and g.get().enum_entries.len == 0) {
        if (g.get().parent) |parent| {
            const pg = parent.borrow();
            if (pg.get().is_enum) {
                g.deinit();
                return pg;
            }
            pg.deinit();
        }
    }
    return g;
}

pub fn leafStaticMember(self: *VmHost, owner: []const u8, member: []const u8) ?Value {
    const def = blk: {
        const cg = self.classes.borrow();
        defer cg.deinit();
        break :blk cg.get().get(owner) orelse return null;
    };
    const dg = def.borrow();
    defer dg.deinit();
    if (!dg.get().is_enum) return null;
    // An enum not yet initialized has no entries to serve: the leaf bails
    // to the interpreted read, which drives the initialization.
    if (!host_globals.enumInitDone(def)) return null;
    for (dg.get().enum_entries) |*e| {
        if (std.mem.eql(u8, e.name, member)) return e.value;
    }
    return null;
}

/// The class whose `enum_entries` describe `cls`'s entries (see
/// `enumTableClass`), as an owned handle.
pub fn enumTableDef(cls: runtime.ObjRef(runtime.ClassDef)) runtime.ObjRef(runtime.ClassDef) {
    const g = cls.borrow();
    defer g.deinit();
    if (g.get().is_enum and g.get().enum_entries.len == 0) {
        if (g.get().parent) |parent| {
            const pg = parent.borrow();
            defer pg.deinit();
            if (pg.get().is_enum) return parent.clone();
        }
    }
    return cls.clone();
}

/// Whether `name` is an entry of the enum `cls` or its `entries` list —
/// the static members whose first read initializes the enum class.
pub fn enumStaticNameHits(cls: runtime.ObjRef(runtime.ClassDef), name: []const u8) bool {
    const g = cls.borrow();
    defer g.deinit();
    if (!g.get().is_enum) return false;
    if (std.mem.eql(u8, name, "entries")) return true;
    for (g.get().enum_entries) |*e| {
        if (std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

/// The entry `member` of the enum class `owner`, initializing the enum on
/// this first use. The bare-name read paths that reach here carry no
/// error channel, so a failed initializer surfaces on the next throwing
/// use of the enum instead.
pub fn enumEntryByOwner(self: *VmHost, owner: []const u8, member: []const u8) ?Value {
    const def = blk: {
        const cg = self.classes.borrow();
        defer cg.deinit();
        break :blk (cg.get().get(owner) orelse return null).clone();
    };
    defer def.deinit();
    {
        const dg = def.borrow();
        defer dg.deinit();
        if (!dg.get().is_enum) return null;
        var hit = false;
        for (dg.get().enum_entries) |*e| {
            if (std.mem.eql(u8, e.name, member)) hit = true;
        }
        if (!hit) return null;
    }
    if (!host_globals.ensureEnumInitQuiet(self, def)) return null;
    const dg = def.borrow();
    defer dg.deinit();
    for (dg.get().enum_entries) |*e| {
        if (std.mem.eql(u8, e.name, member)) return e.value;
    }
    return null;
}

/// A bare name read inside an enum's companion object, nested object, or
/// entry body resolves to the enum's entry of that name: the enum's static
/// scope encloses those bodies. `receiver` is an implicit-receiver
/// candidate of the read; the enclosing enum is found through the
/// companion link, the dotted class name, or the registry's enclosing map.
pub fn enclosingEnumEntry(self: *VmHost, receiver: *const Value, name: []const u8) ?Value {
    if (receiver.* != .Instance) return null;
    var cls_name: []const u8 = undefined;
    var linked: ?runtime.ObjRef(runtime.ClassDef) = null;
    {
        const ig = receiver.Instance.borrow();
        defer ig.deinit();
        const cg = ig.get().class.borrow();
        defer cg.deinit();
        cls_name = cg.get().name;
        const eg = cg.get().enclosing_class.borrow();
        defer eg.deinit();
        if (eg.get().*) |e| linked = e.clone();
    }
    if (linked) |e| {
        defer e.deinit();
        const eg = e.borrow();
        const owner = eg.get().name;
        eg.deinit();
        if (enumEntryByOwner(self, owner, name)) |v| return v;
    }
    return enclosingEnumEntryByOwner(self, cls_name, name);
}

/// The enum whose static scope encloses `receiver`'s class (a companion,
/// nested object or entry body of the enum), if any.
pub fn enclosingEnumDef(self: *VmHost, receiver: *const Value) ?runtime.ObjRef(runtime.ClassDef) {
    if (receiver.* != .Instance) return null;
    var current: []const u8 = undefined;
    {
        const ig = receiver.Instance.borrow();
        defer ig.deinit();
        const cg = ig.get().class.borrow();
        defer cg.deinit();
        current = cg.get().name;
        const eg = cg.get().enclosing_class.borrow();
        defer eg.deinit();
        if (eg.get().*) |e| {
            const e2 = e.borrow();
            const is_enum = e2.get().is_enum;
            e2.deinit();
            if (is_enum) return e.clone();
        }
    }
    var hops: u8 = 0;
    while (hops < 8) : (hops += 1) {
        const enclosing: []const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            if (mg.get().registry.enclosing_class.get(current)) |e| break :blk e;
            if (std.mem.lastIndexOfScalar(u8, current, '.')) |d| break :blk current[0..d];
            return null;
        };
        const def: ?runtime.ObjRef(runtime.ClassDef) = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            break :blk if (cg.get().get(enclosing)) |d| d.clone() else null;
        };
        if (def) |d| {
            const dg = d.borrow();
            const is_enum = dg.get().is_enum;
            dg.deinit();
            if (is_enum) return d;
            d.deinit();
        }
        current = enclosing;
    }
    return null;
}

/// The entry `name` of the enum whose static scope encloses the class
/// `owner` (the owner itself when it is the enum, else its enclosing
/// classes by the registry's map or the dotted class name).
pub fn enclosingEnumEntryByOwner(self: *VmHost, owner: []const u8, name: []const u8) ?Value {
    if (enumEntryByOwner(self, owner, name)) |v| return v;
    var current: []const u8 = owner;
    var hops: u8 = 0;
    while (hops < 8) : (hops += 1) {
        const enclosing: []const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            if (mg.get().registry.enclosing_class.get(current)) |e| break :blk e;
            if (std.mem.lastIndexOfScalar(u8, current, '.')) |d| break :blk current[0..d];
            return null;
        };
        if (enumEntryByOwner(self, enclosing, name)) |v| return v;
        current = enclosing;
    }
    return null;
}
