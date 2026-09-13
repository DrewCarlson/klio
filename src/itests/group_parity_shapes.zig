//! Group binary: each of these suites links the whole interpreter, and that
//! optimize cost is per binary, so folding them together turns N compiles into one.

comptime {
    _ = @import("parity_operator_edge_cases.zig");
    _ = @import("parity_properties_accessors.zig");
    _ = @import("parity_sealed_when_patterns.zig");
    _ = @import("parity_strings_numbers.zig");
    _ = @import("parity_stdlib_isolation.zig");
    _ = @import("parity_suspend_shapes.zig");
    _ = @import("parity_type_system_shapes.zig");
    _ = @import("parity_visibility_modifiers.zig");
}
