//! Subtype tests over the class table, and the shape of a property answer.

const core_ids = @import("ids.zig");

const ClassId = core_ids.ClassId;
const FuncId = core_ids.FuncId;
const Module = @import("../ir.zig").Module;

/// How one class answers a read of one property.
pub const PropTarget = union(enum) {
    /// Run this accessor with the receiver as its only argument.
    getter: FuncId,
    /// Read this index of the receiver's field layout.
    field: u32,
};

/// Whether an instance of `sub` is also a `sup`, by identity. Callers that
/// must not mistake "no closure" for "not a subtype" use `classIsAKnown`.
pub fn classIsA(self: *const Module, sub: ClassId, sup: ClassId) bool {
    if (sub.int() >= self.class_ancestors.items.len) return false;
    const list = self.class_ancestors.items[sub.int()];
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const v = list[mid].int();
        if (v == sup.int()) return true;
        if (v < sup.int()) lo = mid + 1 else hi = mid;
    }
    return false;
}
