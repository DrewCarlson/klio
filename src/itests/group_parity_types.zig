//! Group binary: each of these suites links the whole interpreter, and that
//! optimize cost is per binary, so folding them together turns N compiles into one.

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
