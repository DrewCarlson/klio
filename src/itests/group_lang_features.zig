//! Group binary: each of these suites links the whole interpreter, and that
//! optimize cost is per binary, so folding them together turns N compiles into one.

comptime {
    _ = @import("explicit_backing_fields.zig");
    _ = @import("annotation_targets.zig");
    _ = @import("context_parameters.zig");
    _ = @import("resolve_ambiguity.zig");
    _ = @import("check_examples.zig");
    _ = @import("fuzz_closures_suspend.zig");
}
