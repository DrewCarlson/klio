//! Group binary: the suites named here interpret programs IN-PROCESS, so each
//! links the whole interpreter and pays a whole-program optimize. That cost is
//! per BINARY, not per suite, so folding them together turns N compiles into
//! one; their tests are unchanged and still run under their own names.
//! Each suite also keeps its own `zig build itest-<name>` step for local runs.

comptime {
    _ = @import("parity_extension_resolution.zig");
    _ = @import("parity_generics_advanced.zig");
    _ = @import("parity_inheritance_dispatch.zig");
    _ = @import("parity_inner_classes.zig");
    _ = @import("parity_lambdas_and_dispatch.zig");
    _ = @import("parity_named_args_defaults.zig");
    _ = @import("parity_nullability_deep.zig");
    _ = @import("parity_object_init.zig");
}
