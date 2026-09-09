//! Group binary: the suites named here interpret programs IN-PROCESS, so each
//! links the whole interpreter and pays a whole-program optimize. That cost is
//! per BINARY, not per suite, so folding them together turns N compiles into
//! one; their tests are unchanged and still run under their own names.
//! Each suite also keeps its own `zig build itest-<name>` step for local runs.

comptime {
    _ = @import("parity_array_bulk_ops.zig");
    _ = @import("parity_closures_deep.zig");
    _ = @import("parity_collections_intensive.zig");
    _ = @import("parity_corpus_pinned.zig");
    _ = @import("parity_coroutines_realistic.zig");
    _ = @import("parity_data_class_features.zig");
    _ = @import("parity_dsl_operators.zig");
    _ = @import("parity_exceptions_and_flow.zig");
}
