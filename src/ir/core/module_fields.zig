//! The per-class field layout table, read by class id.

const core_class = @import("class.zig");
const core_ids = @import("ids.zig");

const ClassId = core_ids.ClassId;
const FieldLayoutState = core_class.FieldLayoutState;
const FieldSlot = core_class.FieldSlot;
const Module = @import("../ir.zig").Module;

/// One class's complete field layout, base classes first.
pub const ClassFieldLayout = struct {
    /// Every slot an instance holds, in order: the chain's declared slots, then
    /// the plain constructor parameters its member bodies capture.
    slots: []const FieldSlot = &.{},
    /// How many leading `slots` are declared; the rest are captures.
    declared: u32 = 0,
    /// How many leading `slots` come from the superclass.
    base: u32 = 0,
    state: FieldLayoutState = .unpublished,
};

/// The layout of `cid`, or null when the class has none to read: an interface, an
/// object expression, a function-local class, or one no build described.
pub fn classFieldLayout(self: *const Module, cid: ClassId) ?*const ClassFieldLayout {
    if (cid.int() >= self.field_layout.items.len) return null;
    const entry = &self.field_layout.items[cid.int()];
    return if (entry.state == .ok) entry else null;
}

/// Why `cid` has no layout, for a caller that must tell "no storage" from "not
/// described". Null when the class has one, or is off the end of the table.
pub fn classFieldLayoutState(self: *const Module, cid: ClassId) ?FieldLayoutState {
    if (cid.int() >= self.field_layout.items.len) return null;
    return self.field_layout.items[cid.int()].state;
}
