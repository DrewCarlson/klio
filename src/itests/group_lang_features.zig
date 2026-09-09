//! Group binary: the suites named here interpret programs IN-PROCESS, so each
//! links the whole interpreter and pays a whole-program optimize. That cost is
//! per BINARY, not per suite, so folding them together turns N compiles into
//! one; their tests are unchanged and still run under their own names.
//! Each suite also keeps its own `zig build itest-<name>` step for local runs.

comptime {
    _ = @import("explicit_backing_fields.zig");
    _ = @import("annotation_targets.zig");
    _ = @import("context_parameters.zig");
    _ = @import("resolve_ambiguity.zig");
    _ = @import("check_examples.zig");
    _ = @import("fuzz_closures_suspend.zig");
}
