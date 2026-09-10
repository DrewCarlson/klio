//! Group binary: the suites named here interpret programs IN-PROCESS, so each
//! links the whole interpreter and pays a whole-program optimize. That cost is
//! per BINARY, not per suite, so folding them together turns N compiles into
//! one; their tests are unchanged and still run under their own names.
//! Each suite also keeps its own `zig build itest-<name>` step for local runs.

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
