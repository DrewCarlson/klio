//! The context value a contextual frame derives from its enclosing chain when
//! no caller handed one over. Typeck enforces the ambiguity and absence rules.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const VmHost = @import("vmhost.zig").VmHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const TypeRef = ir.TypeRef;

/// The value a contextual frame no caller served takes for a context
/// parameter of `ty_name`: the innermost entry of its enclosing chain that is
/// one, a context value or a receiver alike. An empty name takes the
/// innermost context value.
pub fn contextValueOfType(self: *VmHost, allocator: Allocator, ty_name: []const u8) Allocator.Error!?Value {
    const want = TypeRef{ .name = ty_name, .nullable = false, .args = &.{} };
    // Innermost first.
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    for (entries) |e| {
        if (e.kind == .access) continue;
        if (ty_name.len == 0) {
            if (e.kind == .context or e.kind == .access_context) return e.v;
            continue;
        }
        if (self.instanceOf(&e.v, want)) return e.v;
    }
    return null;
}
