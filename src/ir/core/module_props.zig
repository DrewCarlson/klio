//! Subtype tests and virtual dispatch over the class table.

const core_ids = @import("ids.zig");

const ClassId = core_ids.ClassId;
const FuncId = core_ids.FuncId;
const MethodSlotId = core_ids.MethodSlotId;
const Module = @import("../ir.zig").Module;

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

/// The `method_dispatch` key of `slot` on `class`.
pub fn methodDispatchKey(class: ClassId, slot: MethodSlotId) u64 {
    return (@as(u64, class.int()) << 32) | slot.int();
}

/// Concrete implementation selected for `slot` on `runtime_class`.
pub fn methodSlotTarget(self: *const Module, runtime_class: ClassId, slot: MethodSlotId) ?FuncId {
    return self.method_dispatch.get(methodDispatchKey(runtime_class, slot));
}
