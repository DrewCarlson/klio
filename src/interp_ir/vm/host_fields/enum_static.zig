//! Enum static access: the entry table behind `Enum.values()`/`valueOf`, leaf
//! static members, and the enclosing-enum lookup a bare entry name takes.

const std = @import("std");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const host_globals = @import("../host_globals.zig");
const Value = runtime.Value;

/// The class whose `enum_entries` describe `cls`'s entries: `cls` itself, or
/// its parent when `cls` is the subclass synthesized for an entry with a body.
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
    // An uninitialized enum has no entries; the interpreted read initializes.
    if (!host_globals.enumInitDone(def)) return null;
    for (dg.get().enum_entries) |*e| {
        if (std.mem.eql(u8, e.name, member)) return e.value;
    }
    return null;
}

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

/// Entry of `cls` or its `entries` list; reading either initializes the enum.
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

/// The entry `member` of enum `owner`, initializing it on first use. The callers
/// have no error channel, so a failed initializer surfaces on the next use.
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

/// A bare name read inside an enum's companion, nested object or entry body
/// resolves to the enum's entry of that name, since the static scope encloses
/// those bodies. `receiver` is an implicit-receiver candidate of the read.
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

/// The enum whose static scope encloses `receiver`'s class, if any.
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
            if (std.mem.findScalarLast(u8, current, '.')) |d| break :blk current[0..d];
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

/// The entry `name` of the enum enclosing `owner`: `owner` itself when it is the
/// enum, else its enclosing classes by registry map or dotted name.
pub fn enclosingEnumEntryByOwner(self: *VmHost, owner: []const u8, name: []const u8) ?Value {
    if (enumEntryByOwner(self, owner, name)) |v| return v;
    var current: []const u8 = owner;
    var hops: u8 = 0;
    while (hops < 8) : (hops += 1) {
        const enclosing: []const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            if (mg.get().registry.enclosing_class.get(current)) |e| break :blk e;
            if (std.mem.findScalarLast(u8, current, '.')) |d| break :blk current[0..d];
            return null;
        };
        if (enumEntryByOwner(self, enclosing, name)) |v| return v;
        current = enclosing;
    }
    return null;
}
