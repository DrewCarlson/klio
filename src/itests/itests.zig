//! Integration test suite. Each file runs through
//! the real pipeline and asserts behavior/diagnostics.
test {
    _ = @import("parity_advanced_idioms.zig");
    _ = @import("parity_array_bulk_ops.zig");
    _ = @import("parity_atomicfu_arrays.zig");
    _ = @import("parity_closures_advanced.zig");
    _ = @import("parity_closures_deep.zig");
    _ = @import("parity_collections_intensive.zig");
    _ = @import("parity_conformance.zig");
    _ = @import("parity_coroutine_smoke.zig");
    _ = @import("parity_corpus_pinned.zig");
    _ = @import("ktor_client_get.zig");
    _ = @import("parity_coroutines_realistic.zig");
    _ = @import("parity_data_class_features.zig");
    _ = @import("parity_dsl_operators.zig");
    _ = @import("parity_exceptions_and_flow.zig");
    _ = @import("parity_extension_resolution.zig");
    _ = @import("parity_functional_patterns.zig");
    _ = @import("parity_generics_advanced.zig");
    _ = @import("parity_inheritance_dispatch.zig");
    _ = @import("parity_inner_classes.zig");
    _ = @import("parity_interfaces_visibility.zig");
    _ = @import("parity_iterables_special.zig");
    _ = @import("parity_kotlinx_io_read.zig");
    _ = @import("parity_lambdas_and_dispatch.zig");
    _ = @import("parity_maps_intensive.zig");
    _ = @import("parity_named_args_defaults.zig");
    _ = @import("parity_nullability_deep.zig");
    _ = @import("parity_object_init.zig");
    _ = @import("parity_operator_edge_cases.zig");
    _ = @import("parity_properties_accessors.zig");
    _ = @import("parity_ranges_arrays.zig");
    _ = @import("parity_sealed_when_patterns.zig");
    _ = @import("parity_string_processing.zig");
    _ = @import("parity_strings_numbers.zig");
    _ = @import("parity_suspend_shapes.zig");
    _ = @import("parity_threaded_litmus.zig");
    _ = @import("parity_type_system_shapes.zig");
    _ = @import("parity_visibility_modifiers.zig");
    _ = @import("typeck_negative.zig");
    _ = @import("parser_corpus.zig");
    _ = @import("cfa_smartcast.zig");
    _ = @import("cfa_builder.zig");
    _ = @import("runtime_objref_threads.zig");
}
