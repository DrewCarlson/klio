//! Group binary: each of these suites links the whole interpreter, and that
//! optimize cost is per binary, so folding them together turns N compiles into one.

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
