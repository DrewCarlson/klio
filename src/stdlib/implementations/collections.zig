//! Collection stdlib intrinsics (List / Set / Map / Iterable / Array /
//! Pair / Triple / Sequence).
//!
//! Each intrinsic is a `fn(*CallCtx) std.mem.Allocator.Error!EvalResult`.
//! `Ok(v)` becomes `EvalResult{ .ok = v }` and `Err(e)` becomes
//! `EvalResult{ .err = e }`. OOM is the only Zig `error`.
//!
//! Memory model: heap-owning containers (`StringRef`, `ValueList`,
//! `MapEntries`) are created via `ctx.allocator` and never freed
//! individually — the interpreter drives an arena per eval phase instead. A
//! plain `Value` copy shares the same backing handle.

const std = @import("std");
const runtime = @import("runtime");
const text = @import("../text.zig");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const MapEntries = runtime.MapEntries;
const MapPair = runtime.MapPair;
const CollBacking = runtime.CollBacking;
const CollBackingRef = runtime.CollBackingRef;
const MapViewKind = runtime.MapViewKind;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;
const PrimBuf = runtime.PrimBuf;
const RangeKind = runtime.RangeKind;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const IntrinsicHost = runtime.IntrinsicHost;
const Output = runtime.Output;
const SeqOp = runtime.SeqOp;

const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;
const Order = std.math.Order;

// =====================================================================
// Subsystem files: each cluster re-exports its public intrinsics here,
// so every `collections.<name>` call site keeps resolving.
// =====================================================================

const common_mod = @import("collections/common.zig");
pub const bumpModCount = common_mod.bumpModCount;
pub const FROZEN_MOD_BIT = common_mod.FROZEN_MOD_BIT;
pub const modCountFrozen = common_mod.modCountFrozen;
pub const ItemsOutcome = common_mod.ItemsOutcome;
pub const iterableItems = common_mod.iterableItems;
pub const iterableItemsCtx = common_mod.iterableItemsCtx;
pub const OrderResult = common_mod.OrderResult;
pub const compareValuesPublic = common_mod.compareValuesPublic;
pub const primitive_companion_const = common_mod.primitive_companion_const;

const iterable_mod = @import("collections/iterable.zig");
pub const coll_random = iterable_mod.coll_random;
pub const coll_random_or_null = iterable_mod.coll_random_or_null;
pub const coll_shuffled = iterable_mod.coll_shuffled;
pub const array_shuffle = iterable_mod.array_shuffle;
pub const coll_mut_list_shuffle = iterable_mod.coll_mut_list_shuffle;
pub const coll_iter_filter_not_null = iterable_mod.coll_iter_filter_not_null;
pub const coll_iter_sum_of = iterable_mod.coll_iter_sum_of;
pub const coll_iter_max_of_or_null = iterable_mod.coll_iter_max_of_or_null;
pub const coll_iter_min_of_or_null = iterable_mod.coll_iter_min_of_or_null;
pub const coll_iter_distinct_by = iterable_mod.coll_iter_distinct_by;
pub const coll_iter_group_by = iterable_mod.coll_iter_group_by;
pub const coll_iter_grouping_by = iterable_mod.coll_iter_grouping_by;
pub const coll_grouping_source_iterator = iterable_mod.coll_grouping_source_iterator;
pub const coll_grouping_key_of = iterable_mod.coll_grouping_key_of;
pub const coll_grouping_each_count = iterable_mod.coll_grouping_each_count;
pub const coll_grouping_fold = iterable_mod.coll_grouping_fold;
pub const coll_grouping_reduce = iterable_mod.coll_grouping_reduce;
pub const coll_iter_associate = iterable_mod.coll_iter_associate;
pub const coll_iter_associate_by = iterable_mod.coll_iter_associate_by;
pub const coll_iter_associate_with = iterable_mod.coll_iter_associate_with;
pub const coll_iter_sorted_by = iterable_mod.coll_iter_sorted_by;
pub const coll_iter_sorted_by_desc = iterable_mod.coll_iter_sorted_by_desc;
pub const coll_iter_max_by_or_null = iterable_mod.coll_iter_max_by_or_null;
pub const coll_iter_min_by_or_null = iterable_mod.coll_iter_min_by_or_null;
pub const coll_mut_list_sort = iterable_mod.coll_mut_list_sort;
pub const mergeSortComparator = iterable_mod.mergeSortComparator;
pub const coll_mut_list_sort_with = iterable_mod.coll_mut_list_sort_with;
pub const coll_mut_list_fill = iterable_mod.coll_mut_list_fill;
pub const coll_mut_list_reverse = iterable_mod.coll_mut_list_reverse;
pub const coll_iter_sorted_with = iterable_mod.coll_iter_sorted_with;
pub const coll_iter_max_of = iterable_mod.coll_iter_max_of;
pub const coll_iter_min_of = iterable_mod.coll_iter_min_of;
pub const coll_iter_on_each = iterable_mod.coll_iter_on_each;
pub const coll_iter_map_not_null = iterable_mod.coll_iter_map_not_null;

const builders_mod = @import("collections/builders.zig");
pub const array_is_empty = builders_mod.array_is_empty;
pub const array_is_not_empty = builders_mod.array_is_not_empty;
pub const array_ctor_generic = builders_mod.array_ctor_generic;
pub const array_ctor_int = builders_mod.array_ctor_int;
pub const array_ctor_long = builders_mod.array_ctor_long;
pub const array_ctor_double = builders_mod.array_ctor_double;
pub const array_ctor_float = builders_mod.array_ctor_float;
pub const array_ctor_short = builders_mod.array_ctor_short;
pub const array_ctor_byte = builders_mod.array_ctor_byte;
pub const array_ctor_boolean = builders_mod.array_ctor_boolean;
pub const array_ctor_char = builders_mod.array_ctor_char;
pub const array_ctor_uint = builders_mod.array_ctor_uint;
pub const array_ctor_ulong = builders_mod.array_ctor_ulong;
pub const array_ctor_ushort = builders_mod.array_ctor_ushort;
pub const array_ctor_ubyte = builders_mod.array_ctor_ubyte;
pub const coll_pair_ctor = builders_mod.coll_pair_ctor;
pub const coll_to_infix = builders_mod.coll_to_infix;
pub const coll_list_of = builders_mod.coll_list_of;
pub const coll_list_of_not_null = builders_mod.coll_list_of_not_null;
pub const coll_array_of = builders_mod.coll_array_of;
pub const coll_array_of_nulls = builders_mod.coll_array_of_nulls;
pub const coll_empty_array = builders_mod.coll_empty_array;
pub const coll_int_array_of = builders_mod.coll_int_array_of;
pub const coll_long_array_of = builders_mod.coll_long_array_of;
pub const coll_short_array_of = builders_mod.coll_short_array_of;
pub const coll_byte_array_of = builders_mod.coll_byte_array_of;
pub const coll_double_array_of = builders_mod.coll_double_array_of;
pub const coll_float_array_of = builders_mod.coll_float_array_of;
pub const coll_bool_array_of = builders_mod.coll_bool_array_of;
pub const coll_char_array_of = builders_mod.coll_char_array_of;
pub const coll_uint_array_of = builders_mod.coll_uint_array_of;
pub const coll_ulong_array_of = builders_mod.coll_ulong_array_of;
pub const coll_ushort_array_of = builders_mod.coll_ushort_array_of;
pub const coll_ubyte_array_of = builders_mod.coll_ubyte_array_of;
pub const coll_mutable_list_of = builders_mod.coll_mutable_list_of;
pub const coll_array_as_array_list = builders_mod.coll_array_as_array_list;
pub const arrayAsListView = builders_mod.arrayAsListView;
pub const coll_array_as_list = builders_mod.coll_array_as_list;
pub const sharedEmptyList = builders_mod.sharedEmptyList;
pub const sharedEmptySet = builders_mod.sharedEmptySet;
pub const sharedEmptyMap = builders_mod.sharedEmptyMap;
pub const resetEmptyCollectionSingletons = builders_mod.resetEmptyCollectionSingletons;
pub const coll_empty_list = builders_mod.coll_empty_list;
pub const coll_set_of = builders_mod.coll_set_of;
pub const coll_mutable_set_of = builders_mod.coll_mutable_set_of;
pub const coll_empty_set = builders_mod.coll_empty_set;
pub const coll_map_of = builders_mod.coll_map_of;
pub const coll_mutable_map_of = builders_mod.coll_mutable_map_of;
pub const coll_empty_map = builders_mod.coll_empty_map;
pub const coll_to_typed_array = builders_mod.coll_to_typed_array;
pub const coll_set_of_not_null = builders_mod.coll_set_of_not_null;
pub const coll_sorted_set_of = builders_mod.coll_sorted_set_of;
pub const coll_sorted_map_of = builders_mod.coll_sorted_map_of;
pub const coll_array_list_ctor = builders_mod.coll_array_list_ctor;
pub const coll_hash_map_ctor = builders_mod.coll_hash_map_ctor;
pub const coll_hash_set_ctor = builders_mod.coll_hash_set_ctor;

const list_mod = @import("collections/list.zig");
pub const coll_list_size = list_mod.coll_list_size;
pub const coll_list_is_empty = list_mod.coll_list_is_empty;
pub const coll_list_is_not_empty = list_mod.coll_list_is_not_empty;
pub const coll_list_get = list_mod.coll_list_get;
pub const coll_list_contains = list_mod.coll_list_contains;
pub const coll_list_index_of = list_mod.coll_list_index_of;
pub const coll_iter_index_of_first = list_mod.coll_iter_index_of_first;
pub const coll_iter_index_of_last = list_mod.coll_iter_index_of_last;
pub const coll_list_fold_right = list_mod.coll_list_fold_right;
pub const coll_list_reduce_right = list_mod.coll_list_reduce_right;
pub const coll_list_reduce_right_or_null = list_mod.coll_list_reduce_right_or_null;
pub const coll_list_last = list_mod.coll_list_last;
pub const coll_list_last_or_null = list_mod.coll_list_last_or_null;
pub const coll_list_last_index_of = list_mod.coll_list_last_index_of;
pub const coll_list_join_to_string = list_mod.coll_list_join_to_string;
pub const coll_array_join_to_string = list_mod.coll_array_join_to_string;
pub const coll_list_to_string = list_mod.coll_list_to_string;
pub const coll_mut_list_add = list_mod.coll_mut_list_add;
pub const coll_mut_list_add_first = list_mod.coll_mut_list_add_first;
pub const coll_mut_list_remove_first = list_mod.coll_mut_list_remove_first;
pub const coll_mut_list_remove_last = list_mod.coll_mut_list_remove_last;
pub const coll_mut_list_remove_at = list_mod.coll_mut_list_remove_at;
pub const coll_mut_list_clear = list_mod.coll_mut_list_clear;
pub const coll_array_list_capacity_noop = list_mod.coll_array_list_capacity_noop;
pub const coll_list_flatten = list_mod.coll_list_flatten;
pub const coll_list_unzip = list_mod.coll_list_unzip;
pub const coll_list_contains_all = list_mod.coll_list_contains_all;
pub const coll_list_to_list = list_mod.coll_list_to_list;
pub const coll_list_to_mutable_list = list_mod.coll_list_to_mutable_list;
pub const coll_list_to_set = list_mod.coll_list_to_set;
pub const coll_list_to_mutable_set = list_mod.coll_list_to_mutable_set;
pub const coll_list_with_index = list_mod.coll_list_with_index;
pub const coll_array_with_index = list_mod.coll_array_with_index;
pub const coll_mut_list_add_all = list_mod.coll_mut_list_add_all;
pub const coll_mut_list_remove = list_mod.coll_mut_list_remove;
pub const coll_mut_list_remove_all = list_mod.coll_mut_list_remove_all;
pub const coll_mut_list_retain_all = list_mod.coll_mut_list_retain_all;
pub const coll_mut_list_set = list_mod.coll_mut_list_set;

const views_mod = @import("collections/views.zig");
pub const counterNowOf = views_mod.counterNowOf;
pub const sublistViewStale = views_mod.sublistViewStale;
pub const sublistComodGuard = views_mod.sublistComodGuard;
pub const mapEntryViewGuard = views_mod.mapEntryViewGuard;

const sequence_mod = @import("collections/sequence.zig");
pub const oneShotConsumeCheck = sequence_mod.oneShotConsumeCheck;
pub const materialiseSequence = sequence_mod.materialiseSequence;
pub const materialiseSequenceBounded = sequence_mod.materialiseSequenceBounded;
pub const mergedPullOne = sequence_mod.mergedPullOne;
pub const compare_values = sequence_mod.compare_values;
pub const seq_has_value_field = sequence_mod.seq_has_value_field;
pub const seq_value_field = sequence_mod.seq_value_field;
pub const seq_yield_iter_field = sequence_mod.seq_yield_iter_field;
pub const pinBuilderState = sequence_mod.pinBuilderState;
pub const freshBuilderState = sequence_mod.freshBuilderState;
pub const freshBuilderSeq = sequence_mod.freshBuilderSeq;
pub const materialise_sequence = sequence_mod.materialise_sequence;
pub const materialise_sequence_bounded = sequence_mod.materialise_sequence_bounded;

const list_transforms_mod = @import("collections/list_transforms.zig");
pub const coll_list_sorted = list_transforms_mod.coll_list_sorted;
pub const coll_list_sorted_descending = list_transforms_mod.coll_list_sorted_descending;
pub const coll_list_reversed = list_transforms_mod.coll_list_reversed;
pub const coll_list_indices = list_transforms_mod.coll_list_indices;
pub const coll_list_last_index = list_transforms_mod.coll_list_last_index;
pub const coll_list_sum = list_transforms_mod.coll_list_sum;
pub const coll_list_average = list_transforms_mod.coll_list_average;
pub const coll_list_max_or_null = list_transforms_mod.coll_list_max_or_null;
pub const coll_list_min_or_null = list_transforms_mod.coll_list_min_or_null;
pub const coll_list_max = list_transforms_mod.coll_list_max;
pub const coll_list_min = list_transforms_mod.coll_list_min;
pub const coll_list_to_map = list_transforms_mod.coll_list_to_map;
pub const coll_list_distinct = list_transforms_mod.coll_list_distinct;
pub const coll_list_take_last = list_transforms_mod.coll_list_take_last;
pub const coll_list_drop_last = list_transforms_mod.coll_list_drop_last;
pub const coll_mut_collection_plus_assign = list_transforms_mod.coll_mut_collection_plus_assign;
pub const coll_mut_collection_minus_assign = list_transforms_mod.coll_mut_collection_minus_assign;
pub const coll_list_slice = list_transforms_mod.coll_list_slice;
pub const coll_list_sublist = list_transforms_mod.coll_list_sublist;
pub const coll_list_plus = list_transforms_mod.coll_list_plus;
pub const coll_list_plus_element = list_transforms_mod.coll_list_plus_element;
pub const coll_iterable_minus = list_transforms_mod.coll_iterable_minus;
pub const coll_iterable_plus = list_transforms_mod.coll_iterable_plus;
pub const coll_list_minus = list_transforms_mod.coll_list_minus;
pub const coll_list_chunked = list_transforms_mod.coll_list_chunked;
pub const coll_list_windowed = list_transforms_mod.coll_list_windowed;
pub const coll_list_zip = list_transforms_mod.coll_list_zip;

const set_mod = @import("collections/set.zig");
pub const coll_set_plus = set_mod.coll_set_plus;
pub const coll_set_union = set_mod.coll_set_union;
pub const coll_set_minus = set_mod.coll_set_minus;
pub const coll_set_subtract = set_mod.coll_set_subtract;
pub const coll_set_intersect = set_mod.coll_set_intersect;
pub const coll_set_size = set_mod.coll_set_size;
pub const coll_set_is_empty = set_mod.coll_set_is_empty;
pub const coll_set_is_not_empty = set_mod.coll_set_is_not_empty;
pub const coll_set_contains = set_mod.coll_set_contains;
pub const coll_set_sorted = set_mod.coll_set_sorted;
pub const coll_set_sorted_descending = set_mod.coll_set_sorted_descending;
pub const coll_set_to_string = set_mod.coll_set_to_string;
pub const coll_mut_set_add = set_mod.coll_mut_set_add;
pub const coll_mut_set_remove = set_mod.coll_mut_set_remove;
pub const coll_mut_set_clear = set_mod.coll_mut_set_clear;
pub const coll_mut_set_remove_all = set_mod.coll_mut_set_remove_all;
pub const coll_mut_set_retain_all = set_mod.coll_mut_set_retain_all;
pub const coll_set_contains_all = set_mod.coll_set_contains_all;
pub const coll_set_to_list = set_mod.coll_set_to_list;
pub const coll_set_to_mutable_list = set_mod.coll_set_to_mutable_list;
pub const coll_set_to_set_ = set_mod.coll_set_to_set_;
pub const coll_set_to_mutable_set_ = set_mod.coll_set_to_mutable_set_;
pub const coll_set_with_index = set_mod.coll_set_with_index;
pub const coll_mut_set_add_all = set_mod.coll_mut_set_add_all;

const map_mod = @import("collections/map.zig");
pub const map_get_or_else = map_mod.map_get_or_else;
pub const map_get_or_put = map_mod.map_get_or_put;
pub const coll_map_to_mutable_map = map_mod.coll_map_to_mutable_map;
pub const coll_map_to_map = map_mod.coll_map_to_map;
pub const coll_map_plus = map_mod.coll_map_plus;
pub const coll_map_minus = map_mod.coll_map_minus;
pub const coll_map_size = map_mod.coll_map_size;
pub const coll_map_is_empty = map_mod.coll_map_is_empty;
pub const coll_map_is_not_empty = map_mod.coll_map_is_not_empty;
pub const coll_map_get = map_mod.coll_map_get;
pub const coll_map_contains_key = map_mod.coll_map_contains_key;
pub const coll_map_contains_value = map_mod.coll_map_contains_value;
pub const coll_map_keys = map_mod.coll_map_keys;
pub const coll_map_values = map_mod.coll_map_values;
pub const coll_map_entries = map_mod.coll_map_entries;
pub const coll_map_to_string = map_mod.coll_map_to_string;
pub const coll_mut_map_put = map_mod.coll_mut_map_put;
pub const coll_mut_map_remove = map_mod.coll_mut_map_remove;
pub const coll_mut_map_clear = map_mod.coll_mut_map_clear;
pub const map_merge = map_mod.map_merge;
pub const map_put_if_absent = map_mod.map_put_if_absent;
pub const map_replace = map_mod.map_replace;
pub const map_compute_if_absent = map_mod.map_compute_if_absent;
pub const map_compute_if_present = map_mod.map_compute_if_present;
pub const map_compute = map_mod.map_compute;
pub const coll_map_get_or_default = map_mod.coll_map_get_or_default;
pub const coll_map_get_value = map_mod.coll_map_get_value;
pub const coll_map_to_list = map_mod.coll_map_to_list;
pub const coll_map_to_sorted_map = map_mod.coll_map_to_sorted_map;
pub const coll_map_count_no_pred = map_mod.coll_map_count_no_pred;
pub const coll_mut_map_put_all = map_mod.coll_mut_map_put_all;
pub const coll_mut_map_set = map_mod.coll_mut_map_set;

const tuple_mod = @import("collections/tuple.zig");
pub const pair_first = tuple_mod.pair_first;
pub const pair_second = tuple_mod.pair_second;
pub const pair_to_string = tuple_mod.pair_to_string;
pub const pair_to_list = tuple_mod.pair_to_list;
pub const coll_triple_ctor = tuple_mod.coll_triple_ctor;
pub const triple_first = tuple_mod.triple_first;
pub const triple_second = tuple_mod.triple_second;
pub const triple_third = tuple_mod.triple_third;
pub const triple_to_string = tuple_mod.triple_to_string;
pub const triple_to_list = tuple_mod.triple_to_list;

const array_mod = @import("collections/array.zig");
pub const array_slice_impl = array_mod.array_slice_impl;
pub const array_content_equals = array_mod.array_content_equals;
pub const array_content_to_string = array_mod.array_content_to_string;
pub const array_content_hash_code = array_mod.array_content_hash_code;
pub const array_or_empty = array_mod.array_or_empty;
pub const array_content_deep_to_string = array_mod.array_content_deep_to_string;
pub const array_content_deep_equals = array_mod.array_content_deep_equals;
pub const array_content_deep_hash_code = array_mod.array_content_deep_hash_code;
pub const array_contains = array_mod.array_contains;
pub const array_contains_all = array_mod.array_contains_all;
pub const array_element_at = array_mod.array_element_at;
pub const array_plus = array_mod.array_plus;
pub const array_plus_element = array_mod.array_plus_element;
pub const array_copy_into = array_mod.array_copy_into;
pub const array_copy_of = array_mod.array_copy_of;
pub const array_copy_of_range = array_mod.array_copy_of_range;
pub const array_fill = array_mod.array_fill;
pub const array_as_signed_view = array_mod.array_as_signed_view;
pub const array_reverse = array_mod.array_reverse;
pub const array_sort = array_mod.array_sort;
pub const array_sort_with = array_mod.array_sort_with;
pub const array_sum_int = array_mod.array_sum_int;
pub const array_sum_unsigned = array_mod.array_sum_unsigned;
pub const array_average_impl = array_mod.array_average_impl;
pub const array_min_or_null = array_mod.array_min_or_null;
pub const array_max_or_null = array_mod.array_max_or_null;
pub const array_max = array_mod.array_max;
pub const array_min = array_mod.array_min;
pub const coll_min_with = array_mod.coll_min_with;
pub const coll_max_with = array_mod.coll_max_with;
pub const coll_min_with_or_null = array_mod.coll_min_with_or_null;
pub const coll_max_with_or_null = array_mod.coll_max_with_or_null;

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = @import("collections/tests.zig");
    inline for (.{ common_mod, iterable_mod, builders_mod, list_mod, views_mod, sequence_mod, list_transforms_mod, set_mod, map_mod, tuple_mod, array_mod }) |m| testing.refAllDecls(m);
}
